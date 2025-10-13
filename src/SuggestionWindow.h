#pragma once

#import <Cocoa/Cocoa.h>
#import "TerminalWatcher.h"

@interface SuggestionWindow : NSWindow {
    NSView *contentView;
}
@property (nonatomic, strong) TerminalWatcher *_watcher;
-(instancetype)initWithDelegate:(id<NSWindowDelegate>)delegate;
@end
