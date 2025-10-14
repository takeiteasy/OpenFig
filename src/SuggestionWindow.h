#pragma once

#import <Cocoa/Cocoa.h>

@interface SuggestionWindow : NSWindow {
    NSView *contentView;
}
- (instancetype)initWithDelegate:(id<NSWindowDelegate>)delegate;
@end
