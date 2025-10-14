#pragma once

#import "SuggestionWindow.h"
#import "TerminalWatcher.h"

@interface AppDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate> {
    BOOL isRunning;
}
@property (nonatomic, strong) SuggestionWindow *_window;
@property (nonatomic, strong) TerminalWatcher *_watcher;
-(instancetype)init;
@end
