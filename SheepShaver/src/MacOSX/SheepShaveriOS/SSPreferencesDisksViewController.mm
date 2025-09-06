//
//  SSPreferencesDisksViewController.m
//  SheepShaver_Xcode8
//
//  Created by Tom Padula on 7/21/22.
//

#import "SSPreferencesDisksViewController.h"

#import "DiskTypeiOS.h"
#import "SSCreateDiskViewController.h"
#import "SSDiskTableHeaderView.h"
#import "SSDiskTableViewCell.h"

#import <stdio.h>
#import <unistd.h>

#if __has_include(<UniformTypeIdentifiers/UniformTypeIdentifiers.h>)
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#endif

#define int32 int32_t
#import "prefs.h"

#define DEBUG_DISK_PREFS 1

#if DEBUG_DISK_PREFS
#define NSLOG(...) NSLog(__VA_ARGS__)
#else
#define NSLOG(...)
#endif

const int kCDROMRefNum = -62;			// RefNum of driver

@interface SSPreferencesDisksViewController ()

@property (readwrite, nonatomic) NSMutableArray<DiskTypeiOS*>* diskArray;
@property (readwrite, nonatomic) SSCreateDiskViewController* createDiskViewController;

@end

@implementation SSPreferencesDisksViewController

- (void)viewDidLoad {
	[super viewDidLoad];
	// Do any additional setup after loading the view from its nib.
		
	//	[self.diskTable registerClass:[SSDiskTableViewCell class] forCellReuseIdentifier:@"diskCell"];
	
	[self _setUpDiskTableUI];
	[self _setUpBootFromUI];
	[self _setUpCreateDiskUI];
}

- (void) _setUpDiskTableUI
{
	[self _loadDiskData];
	
	self.diskTable.delegate = self;
	self.diskTable.dataSource = self;
}

- (void) _setUpBootFromUI
{
	BOOL aBootFromCDROMFirst = NO;
	if (PrefsFindInt32("bootdriver") == kCDROMRefNum) {
		aBootFromCDROMFirst = YES;
	}
	[self.bootFromCDROMFirstSwitch setOn:aBootFromCDROMFirst];
}

- (void) _setUpCreateDiskUI
{
//	self.createNewDiskButton.layer.borderColor = self.createNewDiskButton.titleLabel.textColor.CGColor;
//	self.createNewDiskButton.layer.borderWidth = 1;
//	self.createNewDiskButton.layer.cornerRadius = 4;
//	self.createNewDiskButton.contentEdgeInsets = UIEdgeInsetsMake(4, 4, 4, 4);
}

- (void) _resolveBookmarkedURLs
{
	// Bookmark resolution for external files doesn't work on iOS due to sandbox restrictions
	// The security-scoped resource access cannot persist to the Unix-level file operations
	// Users must copy external disk images into the app's Documents directory
	
	// Clean up any old bookmarks that might exist
	NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
	if ([defaults objectForKey:@"DiskImageBookmarks"]) {
		[defaults removeObjectForKey:@"DiskImageBookmarks"];
		[defaults synchronize];
	}
}

- (void) _loadDiskData
{
	self.diskArray = [NSMutableArray new];
	
	// First, resolve any bookmarked URLs for external disk images
	[self _resolveBookmarkedURLs];

	// First we scan for all available disks in the Documents directory. Then we reconcile that
	// with the "disk" prefs, eliminating any existing prefs that we can't find in the Documents
	// directory. This we use to populate diskArray.
	const char *dsk;
	int index = 0;
	while ((dsk = PrefsFindString("disk", index++)) != NULL) {
		DiskTypeiOS *disk = [DiskTypeiOS new];
		NSString *diskPath = [NSString stringWithUTF8String: dsk];
		[disk setPath:diskPath];
		[disk setIsCDROM:NO];
		
		NSLOG(@"%s Found disk in prefs: %@", __PRETTY_FUNCTION__, diskPath);
		[self.diskArray addObject:disk];
	}
	
	/* Fetch all CDROMs */
	index = 0;
	while ((dsk = PrefsFindString("cdrom", index++)) != NULL) {
		NSString *path = [NSString stringWithUTF8String: dsk ];
		if (![path hasPrefix:@"/dev/"]) {
			DiskTypeiOS *disk = [DiskTypeiOS new];
			[disk setPath:[NSString stringWithUTF8String: dsk ]];
			[disk setIsCDROM:YES];
			
			[self.diskArray addObject:disk];
		}
	}
	
	NSLOG (@"%s Array from cdrom prefs: %@", __PRETTY_FUNCTION__, self.diskArray);

	// Ok, we have a list of disks that the prefs know about. Get the actual files in the Documents directory.
	
	NSString* aDocsDirectory = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
	NSError* anError = nil;
	NSArray* anAllElements = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:aDocsDirectory error:&anError];
	if (anError) {
		NSLOG (@"%s contents of directory at path: %@ returned error: %@", __PRETTY_FUNCTION__, aDocsDirectory, anError);
		
		// Should we clear the list completely here?
		
		return;
	}
	NSLOG (@"%s All elements in directory: %@\n%@", __PRETTY_FUNCTION__, aDocsDirectory, anAllElements);

	NSMutableArray<NSString*>* aDiskCandidateFiles = [NSMutableArray new];
	for (NSString* anElementName in anAllElements) {
		NSString* anElementPath = [aDocsDirectory stringByAppendingPathComponent:anElementName];
		BOOL aIsDirectory = NO;
		if (![[NSFileManager defaultManager] fileExistsAtPath:anElementPath isDirectory:&aIsDirectory] || (aIsDirectory)) {
			NSLOG (@"%s File doesn't exist or is a directory, continuing: %@", __PRETTY_FUNCTION__, anElementName);
			continue;
		}

		// Ok, we have a file (as opposed to a directory) and it exists. See if it has an extension that's not a disk file.
		if (anElementPath.pathExtension.length > 0) {
			NSString* extension = [anElementPath.pathExtension lowercaseString];
			if ([extension isEqualToString:@"dsk"] ||
			    [extension isEqualToString:@"dmg"] ||
			    [extension isEqualToString:@"cdr"] ||
			    [extension isEqualToString:@"iso"] ||
			    [extension isEqualToString:@"img"]) {
				[aDiskCandidateFiles addObject:anElementPath];
			} else {
				NSLOG (@"%s Extension %@ is unknown: %@", __PRETTY_FUNCTION__, anElementPath.pathExtension, anElementName);
			}
		}
	}
	
	NSLOG (@"%s Disk candidate files: %@", __PRETTY_FUNCTION__, aDiskCandidateFiles);

	// Compare the lists. For any disk that we have that doesn't actually exist, eliminate it from the disks list.
	// For any disk that actually exists that we don't already know about, create an entry but mark it disabled.
	// Note that we compare last path components only, because the path to the file may change as installations
	// on devices change.
	
	// First look for the ones in the prefs that don't actually exist. Since we will be eliminating things from the
	// array, we have to be careful not to invalidate iterators.
	int aDiskArrayIndex = 0;
	while (aDiskArrayIndex < self.diskArray.count) {
		// Starting at the top, search for a path in the disk array from within the disk files. If something doesn't
		// match, we can eliminate it. Otherwise, bump the index and continue.
		DiskTypeiOS* aSearchDisk = [self.diskArray objectAtIndex:aDiskArrayIndex];
		NSString* aSearchPath = [aSearchDisk path];
		
		BOOL aFoundIt = NO;
		
		// Check if it's an absolute path (external disk)
		if ([aSearchPath hasPrefix:@"/"]) {
			// For absolute paths, check if the file exists
			aFoundIt = [[NSFileManager defaultManager] fileExistsAtPath:aSearchPath];
		} else {
			// For relative paths, look in the Documents directory
			for (int aDiskCandidateIndex = 0; aDiskCandidateIndex < aDiskCandidateFiles.count; aDiskCandidateIndex++) {
				if ([aSearchPath.lastPathComponent compare:[aDiskCandidateFiles objectAtIndex:aDiskCandidateIndex].lastPathComponent options:NSCaseInsensitiveSearch] == NSOrderedSame) {
					aFoundIt = YES;
					break;
				}
			}
		}
		
		if (aFoundIt) {
			aDiskArrayIndex++;
		} else {
			[self.diskArray removeObjectAtIndex:aDiskArrayIndex];		// note do not increment index.
		}
	}
	
	NSLOG (@"%s Disk array after eliminating phantoms: %@", __PRETTY_FUNCTION__, self.diskArray);

	// Ok, now self.diskArray contains only things that actually exist, let's see if there is anything else to add to it,
	// that is, files that exist that aren't already accounted for.
	int aDiskCandidateIndex = 0;
	while (aDiskCandidateIndex < aDiskCandidateFiles.count) {
		NSString* anExistingDiskPath = [aDiskCandidateFiles objectAtIndex:aDiskCandidateIndex];
		BOOL aFoundIt = NO;
		for (aDiskArrayIndex = 0; aDiskArrayIndex < self.diskArray.count; aDiskArrayIndex++) {
			DiskTypeiOS* aSearchDisk = [self.diskArray objectAtIndex:aDiskArrayIndex];
			NSString* aSearchPath = [aSearchDisk path];
			// For files in Documents directory, we need to handle both absolute and relative paths
			if ([aSearchPath isEqualToString:anExistingDiskPath] ||
			    [aSearchPath.lastPathComponent compare:anExistingDiskPath.lastPathComponent options:NSCaseInsensitiveSearch] == NSOrderedSame) {
				aFoundIt = YES;
				break;
			}
		}
		if (!aFoundIt) {
			DiskTypeiOS *disk = [DiskTypeiOS new];
			[disk setPath:anExistingDiskPath];
			NSString* extension = [anExistingDiskPath.pathExtension lowercaseString];
			if ([extension isEqualToString:@"cdr"] || [extension isEqualToString:@"iso"]) {
				[disk setIsCDROM:YES];
			} else {
				[disk setIsCDROM:NO];
			}
			[disk setDisable:YES];
			
			[self.diskArray addObject:disk];
		}
		aDiskCandidateIndex++;
	}
	
	// If there is but one disk, make sure it is enabled.
	if (self.diskArray.count == 1) {
		self.diskArray.firstObject.disable = NO;
	}
		
	NSLOG (@"%s Disk array after adding disabled real disks: %@", __PRETTY_FUNCTION__, self.diskArray);
}

- (void) _writePrefs
{
	// Clear the prefs and rewrite them. If there is but one real disk and no remaining prefs disks, we should just
	// set the one as the prefs disk without bothering the user.
	while (PrefsFindString("disk") != 0) {
		PrefsRemoveItem("disk");
	}
	while (PrefsFindString("cdrom") != 0) {
		PrefsRemoveItem("cdrom");
	}
	
	// Update the paths with the current documents directory. This isn't normally a big deal, but during development the identity of
	// the document directory can change.
	NSString* aDocsDirectory = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
	if (self.diskArray.count == 1) {
		// Check if the path is already absolute (for external disks)
		NSString* diskPath = self.diskArray.firstObject.path;
		if (![diskPath hasPrefix:@"/"]) {
			// Relative path - prepend documents directory
			diskPath = [aDocsDirectory stringByAppendingPathComponent:diskPath];
		}
		PrefsAddString(self.diskArray.firstObject.isCDROM ? "cdrom" : "disk", [diskPath UTF8String]);		// even if it is disabled, since it's the only one
	} else {
		for (DiskTypeiOS* aDiskType in self.diskArray) {
			if (aDiskType.disable == NO) {
				// Check if the path is already absolute (for external disks)
				NSString* diskPath = aDiskType.path;
				if (![diskPath hasPrefix:@"/"]) {
					// Relative path - prepend documents directory
					diskPath = [aDocsDirectory stringByAppendingPathComponent:diskPath];
				}
				PrefsAddString(aDiskType.isCDROM ? "cdrom" : "disk", [diskPath UTF8String]);
			}
		}
	}
	
	// Ensure that /dev/poll/cdrom is present exactly once.
	const char* aPollCDROM = nil;
	int anIndex = 0;
	do {
		aPollCDROM = PrefsFindString("cdrom", anIndex++);
		if (!aPollCDROM) {
			break;
		}
		if (strlen(aPollCDROM) != strlen("/dev/poll/cdrom")) {
			continue;
		}
	}
	while (strncmp (aPollCDROM, "/dev/poll/cdrom", strlen(aPollCDROM)) != 0);
	if (!aPollCDROM) {
		PrefsAddString("cdrom", "/dev/poll/cdrom");		// This is also added in sys_unix.cpp.
	}
	
	NSLOG (@"%s write %lu new disk paths:", __PRETTY_FUNCTION__, (unsigned long)self.diskArray.count);
	for (DiskTypeiOS* aDiskType in self.diskArray) {
		NSLOG (@"    %@", aDiskType.path);
	}
}

// UITableViewDataSource
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
	return self.diskArray.count;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
	return 1;
}

- (BOOL) tableView:(UITableView *)tableView shouldHighlightRowAtIndexPath:(NSIndexPath *)indexPath
{
	return NO;
}

// This should never be hit, selection is turned off.
- (void) tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
	NSLOG (@"%s selected row at index path: %@", __PRETTY_FUNCTION__, indexPath);
	NSLOG (@"    tableView.visibleCells: %@", tableView.visibleCells);
}

// Row display. Implementers should *always* try to reuse cells by setting each cell's reuseIdentifier and querying for available reusable cells with dequeueReusableCellWithIdentifier:
// Cell gets various attributes set automatically based on table (separators) and data source (accessory views, editing controls)
//
// This table is rarely updated while the app is running and is small. There is little chance that any cell would actually be reused
// and IB (Xcode 12.4) is having indigestion again. So we do it the old way.
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
	NSLOG (@"%s index path row: %ld", __PRETTY_FUNCTION__, (long)indexPath.row);
	if (indexPath.row >= self.diskArray.count) {
		return nil;
	}
	
	SSDiskTableViewCell* aCell = nil;
	
//	aCell = [tableView dequeueReusableCellWithIdentifier:@"diskCell" forIndexPath:indexPath];
	if (!aCell) {
		aCell = [[SSDiskTableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"diskCell"];
	}
	aCell.disksViewController = self;
	aCell.disk = [self.diskArray objectAtIndex:indexPath.row];
	
	if (tableView.rowHeight == UITableViewAutomaticDimension) {
		tableView.rowHeight = 44;
	}
	CGRect aFrame = CGRectMake(0, 0, tableView.contentSize.width, tableView.rowHeight);
	[aCell.contentView setFrame:aFrame];
	[aCell setFrame:aFrame];
	
	NSLOG (@"%s SSDiskTableViewCell frame: %@", __PRETTY_FUNCTION__, NSStringFromCGRect(aFrame));
	
	// No need to show the whole path.
	DiskTypeiOS* aDisk = [self.diskArray objectAtIndex:indexPath.row];
	[aCell.diskNameLabel setText:[aDisk.path lastPathComponent]];
	[aCell.isCDROMSwitch setOn:aDisk.isCDROM];
	[aCell.diskMountEnableSwitch setOn:!aDisk.disable];
	
	NSLOG (@"    aCell: %@", aCell);
	NSLOG (@"    aCell.diskNameLabel: %@", aCell.diskNameLabel);
	NSLOG (@"    aCell.isCDROMSwitch: %@", aCell.isCDROMSwitch);
	NSLOG (@"    aCell.diskMountEnableSwitch: %@", aCell.diskMountEnableSwitch);
	NSLOG (@"    aCell.contentView: %@", aCell.contentView);
	NSLOG (@"    aCell.contentView.subviews: %@", aCell.contentView.subviews);

	[aCell setSelectionStyle:UITableViewCellSelectionStyleNone];
	[aCell setUserInteractionEnabled:YES];
	
	return aCell;
}

// These are belt-and-suspenders, they should default to NO anyway.
- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath
{
	return NO;
}

- (BOOL)tableView:(UITableView *)tableView canMoveRowAtIndexPath:(NSIndexPath *)indexPath
{
	return NO;
}

- (nullable NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
	return nil;
}

- (nullable NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
	return nil;
}

- (IBAction)createNewDiskButtonHit:(id)sender
{
	self.createDiskViewController.disksViewController = self;
	[self presentViewController:self.createDiskViewController animated:YES completion:^(void){
		
	}];
}

- (IBAction)bootFromCDROMFirstSwitchHit:(id)sender
{
	if (self.bootFromCDROMFirstSwitch.isOn) {
		PrefsReplaceInt32("bootdriver", kCDROMRefNum);
	} else {
		PrefsReplaceInt32("bootdriver", 0);
	}
}

- (IBAction)addExistingDiskButtonHit:(id)sender
{
	if (@available(iOS 14.0, *)) {
		// Create an array of UTTypes for disk images
		NSMutableArray<UTType*>* diskTypes = [NSMutableArray array];
		
		// Add disk image type using identifier instead of constant
		UTType* diskImageType = [UTType typeWithIdentifier:@"public.disk-image"];
		if (diskImageType) [diskTypes addObject:diskImageType];
		
		// Add specific disk image formats
		UTType* dskType = [UTType typeWithFilenameExtension:@"dsk"];
		UTType* dmgType = [UTType typeWithFilenameExtension:@"dmg"];
		UTType* cdrType = [UTType typeWithFilenameExtension:@"cdr"];
		UTType* imgType = [UTType typeWithFilenameExtension:@"img"];
		UTType* isoType = [UTType typeWithFilenameExtension:@"iso"];
		
		if (dskType) [diskTypes addObject:dskType];
		if (dmgType) [diskTypes addObject:dmgType];
		if (cdrType) [diskTypes addObject:cdrType];
		if (imgType) [diskTypes addObject:imgType];
		if (isoType) [diskTypes addObject:isoType];
		
		UIDocumentPickerViewController* picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:diskTypes];
		picker.delegate = self;
		picker.allowsMultipleSelection = YES;
		[self presentViewController:picker animated:YES completion:nil];
	} else {
		// Fallback for older iOS versions
		NSArray<NSString*>* documentTypes = @[@"public.disk-image", @"com.apple.disk-image-dmg", 
											   @"public.iso-image", @"public.data"];
		UIDocumentPickerViewController* picker = [[UIDocumentPickerViewController alloc] 
												  initWithDocumentTypes:documentTypes 
												  inMode:UIDocumentPickerModeOpen];
		picker.delegate = self;
		picker.allowsMultipleSelection = YES;
		[self presentViewController:picker animated:YES completion:nil];
	}
}

#pragma mark - UIDocumentPickerDelegate

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls
{
	NSLOG(@"%s Picked documents: %@", __PRETTY_FUNCTION__, urls);
	
	NSString* aDocsDirectory = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
	
	// Ask user if they want to copy or reference the files
	if (urls.count > 0) {
		// Check if any files are from external locations (iCloud, etc)
		BOOL hasExternalFiles = NO;
		for (NSURL* url in urls) {
			if (![[url path] hasPrefix:aDocsDirectory]) {
				hasExternalFiles = YES;
				break;
			}
		}
		
		if (hasExternalFiles) {
			// For external files, we must copy them due to iOS sandbox restrictions
			UIAlertController* importAlert = [UIAlertController alertControllerWithTitle:@"Import Disk Images" 
																				message:@"External disk images (from iCloud Drive, etc.) must be copied to SheepShaver's storage due to iOS security restrictions. The app cannot access external files during emulation."
																		 preferredStyle:UIAlertControllerStyleAlert];
			
			[importAlert addAction:[UIAlertAction actionWithTitle:@"Copy to SheepShaver" 
															style:UIAlertActionStyleDefault 
														  handler:^(UIAlertAction * _Nonnull action) {
				[self _copyDiskImages:urls toDirectory:aDocsDirectory];
			}]];
			
			[importAlert addAction:[UIAlertAction actionWithTitle:@"Cancel" 
															style:UIAlertActionStyleCancel 
														  handler:nil]];
			
			[self presentViewController:importAlert animated:YES completion:nil];
		} else {
			// Files are already in our Documents directory, just add them
			[self _copyDiskImages:urls toDirectory:aDocsDirectory];
		}
	}
}

- (void)_copyDiskImages:(NSArray<NSURL*>*)urls toDirectory:(NSString*)aDocsDirectory
{
	for (NSURL* url in urls) {
		// Start accessing security-scoped resource
		BOOL startAccessing = [url startAccessingSecurityScopedResource];
		if (!startAccessing) {
			NSLOG(@"%s Failed to start accessing security scoped resource: %@", __PRETTY_FUNCTION__, url);
			continue;
		}
		
		NSError* error = nil;
		NSString* fileName = [url lastPathComponent];
		NSString* destinationPath = [aDocsDirectory stringByAppendingPathComponent:fileName];
		
		// Check if file already exists
		if ([[NSFileManager defaultManager] fileExistsAtPath:destinationPath]) {
			// Create a unique filename
			NSString* nameWithoutExtension = [fileName stringByDeletingPathExtension];
			NSString* extension = [fileName pathExtension];
			int counter = 1;
			do {
				fileName = [NSString stringWithFormat:@"%@_%d.%@", nameWithoutExtension, counter, extension];
				destinationPath = [aDocsDirectory stringByAppendingPathComponent:fileName];
				counter++;
			} while ([[NSFileManager defaultManager] fileExistsAtPath:destinationPath]);
		}
		
		// Copy the file to Documents directory
		BOOL success = [[NSFileManager defaultManager] copyItemAtURL:url toURL:[NSURL fileURLWithPath:destinationPath] error:&error];
		
		// Stop accessing security-scoped resource
		[url stopAccessingSecurityScopedResource];
		
		if (success) {
			NSLOG(@"%s Successfully copied disk image to: %@", __PRETTY_FUNCTION__, destinationPath);
			
			// Add to disk prefs
			NSString* extension = [[destinationPath pathExtension] lowercaseString];
			BOOL isCDROM = [extension isEqualToString:@"cdr"] || [extension isEqualToString:@"iso"];
			PrefsAddString(isCDROM ? "cdrom" : "disk", [destinationPath UTF8String]);
			
			// Add to our disk array immediately
			DiskTypeiOS *disk = [DiskTypeiOS new];
			[disk setPath:destinationPath];
			[disk setIsCDROM:isCDROM];
			[disk setDisable:NO];
			[self.diskArray addObject:disk];
		} else {
			NSLOG(@"%s Failed to copy disk image: %@", __PRETTY_FUNCTION__, error);
			
			// Show an alert to the user
			UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"Import Failed" 
																		   message:[NSString stringWithFormat:@"Failed to import %@: %@", fileName, error.localizedDescription]
																	preferredStyle:UIAlertControllerStyleAlert];
			[alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
			[self presentViewController:alert animated:YES completion:nil];
		}
	}
	
	// Save preferences to persist the changes
	SavePrefs();
	
	// Just reload the table, don't reload disk data as we've already added them
	[self.diskTable reloadData];
}

// This method is no longer used - external disk references don't work on iOS due to sandbox restrictions
// Keeping for potential future use if iOS adds better file provider support
/*
- (void)_referenceDiskImages:(NSArray<NSURL*>*)urls
{
	// This approach doesn't work on iOS because security-scoped resource access
	// is only valid within the app session and cannot persist across app launches
	// or be used by the Unix-level file operations in the emulator
}
*/

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller
{
	NSLOG(@"%s Document picker was cancelled", __PRETTY_FUNCTION__);
}

- (void)viewWillDisappear:(BOOL)animated
{
	[super viewWillDisappear:animated];
	
	// Save any changes to preferences
	[self _writePrefs];
	SavePrefs();
}

- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator
{
	NSLOG (@"%s new size: %@", __PRETTY_FUNCTION__, NSStringFromCGSize(size));

	[super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
	
	[self.diskTable performSelectorOnMainThread:@selector(reloadData) withObject:nil waitUntilDone:NO];
}

- (SSCreateDiskViewController*)createDiskViewController
{
	if (!_createDiskViewController) {
		_createDiskViewController = [SSCreateDiskViewController new];
	}
	return _createDiskViewController;
}

- (void) _createDiskWithName:(NSString*)inName size:(int)inSizeInMB
{
	NSLOG (@"%s Name: %@, size: %d MB", __PRETTY_FUNCTION__, inName, inSizeInMB);
	
	NSString* aDocsDirectory = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
	NSString* aFilePath = [aDocsDirectory stringByAppendingPathComponent:inName];
	
	// If this file already exists, give the user the option to replace it. For now, just do nothing.
	if ([[NSFileManager defaultManager] fileExistsAtPath:aFilePath isDirectory:nil]) {
		NSLOG (@"%s Name %@ already exists, bailing out.", __PRETTY_FUNCTION__, inName);
		return;
	}
	
	// Use the file manager to create the file, then use truncate to set the length.
	char aBytes[1024];
	bzero (aBytes, 1024);
	NSData* aData = [NSData dataWithBytes:aBytes length:1024];
	BOOL aSuccess = [[NSFileManager defaultManager] createFileAtPath:aFilePath contents:aData attributes:@{NSFileType: NSFileTypeRegular, NSFileSize: @(inSizeInMB << 20)}];
	NSLOG (@" aSuccess: %@", aSuccess ? @"YES" : @"NO");
			
	off_t aLength = inSizeInMB << 20;
	int aFileDescriptor = truncate(aFilePath.UTF8String, aLength);
	NSLOG(@"%s truncate file: %s, descriptor: %d", __PRETTY_FUNCTION__, aFilePath.UTF8String, aFileDescriptor);
	if (aFileDescriptor < 0) {
		NSLOG (@"    error: %d, %s", errno, strerror(errno));
	}
	
	// Force a rebuild of the disk list.
	[self _loadDiskData];
	[self.diskTable performSelectorOnMainThread:@selector(reloadData) withObject:nil waitUntilDone:NO];
}

- (void)deleteDisk:(DiskTypeiOS*)disk
{
	NSString* diskName = [disk.path lastPathComponent];
	NSString* message = [NSString stringWithFormat:@"Are you sure you want to delete '%@'? This action cannot be undone.", diskName];
	
	UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"Delete Disk" 
																   message:message
															preferredStyle:UIAlertControllerStyleAlert];
	
	[alert addAction:[UIAlertAction actionWithTitle:@"Cancel" 
											  style:UIAlertActionStyleCancel 
											handler:nil]];
	
	[alert addAction:[UIAlertAction actionWithTitle:@"Delete" 
											  style:UIAlertActionStyleDestructive 
											handler:^(UIAlertAction * _Nonnull action) {
		[self _performDiskDeletion:disk];
	}]];
	
	[self presentViewController:alert animated:YES completion:nil];
}

- (void)_performDiskDeletion:(DiskTypeiOS*)disk
{
	// Remove from array
	[self.diskArray removeObject:disk];
	
	// Check if it's a file in Documents directory that should be deleted
	NSString* docsDirectory = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
	if ([disk.path hasPrefix:docsDirectory]) {
		// It's in our Documents directory, safe to delete the actual file
		NSError* error = nil;
		[[NSFileManager defaultManager] removeItemAtPath:disk.path error:&error];
		if (error) {
			NSLOG(@"%s Failed to delete file: %@", __PRETTY_FUNCTION__, error);
		}
	} else {
		// External disk - this shouldn't happen anymore since we only copy files
		NSLOG(@"%s Attempted to delete external disk at path: %@", __PRETTY_FUNCTION__, disk.path);
	}
	
	// Update preferences and save
	[self _writePrefs];
	SavePrefs();
	
	// Reload table
	[self.diskTable reloadData];
}

@end
