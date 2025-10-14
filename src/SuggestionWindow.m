#import "SuggestionWindow.h"

@implementation SuggestionWindow

- (instancetype)initWithDelegate:(id<NSWindowDelegate>)delegate {
    if (self = [super initWithContentRect:NSMakeRect(0, 0, 0, 0)
                                styleMask:NSWindowStyleMaskBorderless
                                  backing:NSBackingStoreBuffered
                                    defer:NO]) {
        [self setTitle:NSProcessInfo.processInfo.processName];
        [self setOpaque:NO];
        [self setExcludedFromWindowsMenu:NO];
        [self setBackgroundColor:[NSColor clearColor]];
        [self setIgnoresMouseEvents:YES];
        [self makeKeyAndOrderFront:self];
        [self setLevel:NSFloatingWindowLevel];
        [self setCanHide:NO];
        [self setDelegate:delegate];
        [self setReleasedWhenClosed:NO];
    }
    return self;
}

- (BOOL)canBecomeKeyWindow {
    return YES;
}
@end
