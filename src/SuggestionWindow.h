#pragma once

#import <Cocoa/Cocoa.h>

@interface SuggestionWindow : NSWindow {
    NSView *contentView;
}
@property (nonatomic, assign, getter=isShowing) BOOL showing;
- (instancetype)initWithDelegate:(id<NSWindowDelegate>)delegate;
- (void)show:(CGPoint)position;
- (void)showAtPosition:(CGPoint)position gap:(CGFloat)gap; // New: dynamic vertical gap
- (void)hide;
@end
