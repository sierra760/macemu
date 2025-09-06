//
//  ViewController.m
//  SheepShaveriOS
//
//  Created by Tom Padula on 5/9/22.
//

#import "ViewController.h"

@interface ViewController ()

@end

@implementation ViewController

- (void)viewDidLoad {
	[super viewDidLoad];
	// Do any additional setup after loading the view.
}

- (BOOL)canPerformAction:(SEL)action withSender:(id)sender {
	if (action == NSSelectorFromString(@"_performClose:")) {
		// Blocks Command-W from closing all of SheepShaver
		return NO;
	}
	return [super canPerformAction:action withSender:sender];
}


@end
