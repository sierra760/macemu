//
//  SSGestureRecognizerManager.m
//  SheepShaveriOS
//
//  Created by Tom Padula on 8/2/22.
//

#import "SSGestureRecognizerManager.h"

#import "SSPreferencesViewController.h"
#import <objc/runtime.h>

SSGestureRecognizerManager* gGestureRecognizer;
UIWindow* gInitialPrefsWindow;
UIWindow* gSDLWindow;

// Category for SDL view controller to add canPerformAction method
@interface UIViewController (CommandWBlocking)
@end

@implementation UIViewController (CommandWBlocking)

+ (void)load {
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		Class class = [self class];
		
		SEL originalSelector = @selector(canPerformAction:withSender:);
		SEL swizzledSelector = @selector(ss_canPerformAction:withSender:);
		
		Method originalMethod = class_getInstanceMethod(class, originalSelector);
		Method swizzledMethod = class_getInstanceMethod(class, swizzledSelector);
		
		BOOL didAddMethod = class_addMethod(class,
											originalSelector,
											method_getImplementation(swizzledMethod),
											method_getTypeEncoding(swizzledMethod));
		
		if (didAddMethod) {
			class_replaceMethod(class,
								swizzledSelector,
								method_getImplementation(originalMethod),
								method_getTypeEncoding(originalMethod));
		} else {
			method_exchangeImplementations(originalMethod, swizzledMethod);
		}
	});
}

- (BOOL)ss_canPerformAction:(SEL)action withSender:(id)sender {
	if (action == NSSelectorFromString(@"_performClose:")) {
		// Blocks Command-W from closing SheepShaver
		// Return YES to indicate we CAN perform the action (but we won't actually do it)
		return YES;
	}
	// Call original implementation
	return [self ss_canPerformAction:action withSender:sender];
}

@end

@interface SSGestureRecognizerManager()

@property (readwrite, nonatomic) UISwipeGestureRecognizer* preferencesGesture;
@property (readwrite, nonatomic) UISwipeGestureRecognizer* keyboardGesture;

@end

@implementation SSGestureRecognizerManager

+ (void) initGestureRecognizers
{
	[SSGestureRecognizerManager gestureRecognizerManager];
}

+ (instancetype) gestureRecognizerManager
{
	if (!gGestureRecognizer) {
		gGestureRecognizer = [SSGestureRecognizerManager new];
	}
	return gGestureRecognizer;
}

- (instancetype) init
{
	if (self == [super init]) {
		
		// This is a hack to attach our gesture recognizers to the main SDL window. We are initially called
		// while the prefs window is still up so we can make note of it.
		// It appears to work most of the time. We should make it smarter to see what the current main view is
		// so that we can check if it has changed (or become nil) in order to attach to it when it eventually appears.

		UIWindow* aMainWindow = [[[UIApplication sharedApplication] windows] firstObject];
		if (!gInitialPrefsWindow) {
			gInitialPrefsWindow = aMainWindow;
			[self performSelector:@selector(_initGestures) withObject:nil afterDelay:1.0];
		}
		
	}
	return self;
}

- (void) _initGestures
{
	UIWindow* aMainWindow = [[[UIApplication sharedApplication] windows] firstObject];
	if (gSDLWindow == aMainWindow) {
		return;
	}
	
	// Have we switched to the SDL window yet?
	if ((!gSDLWindow) && ((!aMainWindow) || (aMainWindow == gInitialPrefsWindow))) {
		[self performSelector:@selector(_initGestures) withObject:nil afterDelay:1.0];
		return;
	}
	
	// Ok, so the main window is not nil and it's not the initial prefs window. Go ahead and attach
	// the gesture recognizers.
	if (aMainWindow.rootViewController) {
		self.preferencesGesture = [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(_preferencesGestureTriggered:)];
		self.preferencesGesture.numberOfTouchesRequired = 3;
		self.preferencesGesture.direction = UISwipeGestureRecognizerDirectionDown;
		self.preferencesGesture.delaysTouchesBegan = YES;
		
		self.keyboardGesture = [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(_keyboardGestureGestureTriggered:)];
		self.keyboardGesture.numberOfTouchesRequired = 3;
		self.keyboardGesture.direction = UISwipeGestureRecognizerDirectionUp;
		self.keyboardGesture.delaysTouchesBegan = YES;		// These don't help.
		self.keyboardGesture.delaysTouchesEnded = YES;
		
		[aMainWindow.rootViewController.view addGestureRecognizer:self.preferencesGesture];
		[aMainWindow.rootViewController.view addGestureRecognizer:self.keyboardGesture];
		[aMainWindow.rootViewController.view setUserInteractionEnabled:YES];
		
		gSDLWindow = aMainWindow;
		
		NSLog (@"Added gesture recognizers to main view.");
	}
}

- (void) _preferencesGestureTriggered:(UIGestureRecognizer*) inGestureRecognizer
{
	NSLog (@"_preferencesGestureTriggered");
	SS_ShowiOSPreferences();
}

- (void) _keyboardGestureGestureTriggered:(UIGestureRecognizer*) inGestureRecognizer
{
	NSLog (@"_keyboardGestureGestureTriggered");
}

@end
