//
//  TerminalWatcher.h
//  fig
//
//  Created by George Watson on 13/10/2025.
//

#pragma once

#import "TerminalWindow.h"
#import <Cocoa/Cocoa.h>
#import <util.h>
#import <termios.h>
#import <sys/select.h>
#import <sys/ioctl.h>
#import <signal.h>
#import <fcntl.h>
#import <unistd.h>

// Notifications AppDelegate (and others) can observe.
extern NSString * const TerminalWatcherDidUpdateTerminalsNotification;          // userInfo: nil
extern NSString * const TerminalWatcherTerminalDidUpdateNotification;           // userInfo: @{ @"pid": NSNumber, @"terminal": TerminalWindow* }
extern NSString * const TerminalWatcherFocusedTerminalDidChangeNotification;    // userInfo: @{ @"pid": NSNumber (or NSNull), @"terminal": TerminalWindow* (or NSNull) }

// New granular add/remove notifications.
extern NSString * const TerminalWatcherTerminalDidOpenNotification;             // userInfo: @{ @"pid": NSNumber, @"terminal": TerminalWindow* }
extern NSString * const TerminalWatcherTerminalDidCloseNotification;            // userInfo: @{ @"pid": NSNumber, @"terminal": TerminalWindow* }

@interface TerminalWatcher : NSObject

// Read-only snapshot of terminals keyed by app PID.
@property (nonatomic, strong, readonly) NSDictionary<NSNumber*, TerminalWindow*> *terminals;

- (void)updateAllTerminals;

@end
