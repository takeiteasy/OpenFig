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

@interface TerminalWatcher : NSObject
@property (nonatomic, strong) NSTimer *_timer;
@property (nonatomic, strong) NSMutableDictionary<NSNumber*, TerminalWindow*> *_terminals;
@end
