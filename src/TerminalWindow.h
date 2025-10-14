//
//  TerminalWindow.h
//  fig
//
//  Created by George Watson on 13/10/2025.
//

#pragma once

#import <ApplicationServices/ApplicationServices.h>

@interface TerminalWindow : NSObject
@property (nonatomic, assign) pid_t pid;
@property (nonatomic, strong) NSString *appName;
@property (nonatomic, strong) NSString *windowTitle;
@property (nonatomic, strong) NSString *shell;
@property (nonatomic) CGPoint cursorPosition;
@property (nonatomic) AXUIElementRef axWindow;
@property (nonatomic, strong) NSDictionary *bufferInfo; // New: terminal buffer content
@property (nonatomic, assign, getter=isFocused) BOOL focused; // New: is this the focused terminal window?
@end
