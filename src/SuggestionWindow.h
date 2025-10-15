#pragma once

#import <Cocoa/Cocoa.h>

@interface SuggestionWindow : NSWindow {
    NSView *contentView;
}
@property (nonatomic, assign, getter=isShowing) BOOL showing;
- (instancetype)initWithDelegate:(id<NSWindowDelegate>)delegate;
- (void)show:(CGPoint)position;
- (void)hide;
@end
