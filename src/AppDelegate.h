#pragma once

#import "SuggestionWindow.h"

@interface AppDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate> {
    BOOL isRunning;
}
@property (nonatomic, strong) SuggestionWindow *_window;
-(instancetype)init;
@end
