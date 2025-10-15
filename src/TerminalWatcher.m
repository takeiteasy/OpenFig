//
//  TerminalWatcher.m
//  fig
//
//  Created by George Watson on 13/10/2025.
//

#import "TerminalWatcher.h"

NSString* const TerminalWatcherDidUpdateTerminalsNotification = @"TerminalWatcherDidUpdateTerminalsNotification";
NSString* const TerminalWatcherTerminalDidUpdateNotification = @"TerminalWatcherTerminalDidUpdateNotification";
NSString* const TerminalWatcherFocusedTerminalDidChangeNotification = @"TerminalWatcherFocusedTerminalDidChangeNotification";

@interface TerminalWatcher ()
// Internal mutable storage and timer
@property (nonatomic, strong) NSTimer *_timer;
@property (nonatomic, strong) NSMutableDictionary<NSNumber*, TerminalWindow*> *_terminals;
@property (nonatomic, strong) NSDictionary *_shellPrompts;

// Expose read-only copy via the public property
@property (nonatomic, strong, readwrite) NSDictionary<NSNumber*, TerminalWindow*> *terminals;
@end

@implementation TerminalWatcher
@synthesize _timer;
@synthesize _terminals;
@synthesize _shellPrompts;
@synthesize terminals = _publicTerminals;

static NSString *StripANSIEscapes(NSString *s) {
    if (!s)
        return nil;
    NSError *err = nil;
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"\\x1B\\[[0-9;?]*[ -/]*[@-~]|\\x1B\\][^\\a]*(\\a|\\x1B\\\\)|\\x1B[@-Z\\\\-_]"
                                                                           options:0
                                                                             error:&err];
    if (err)
        return s;
    NSMutableString *m = [s mutableCopy];
    [regex replaceMatchesInString:m options:0 range:NSMakeRange(0, m.length) withTemplate:@""];
    return m;
}

- (NSString*)renderPromptForShell:(NSString*)shellName timeout:(NSTimeInterval)timeout {
    int masterFd = -1;
    pid_t pid = forkpty(&masterFd, NULL, NULL, NULL);
    if (pid < 0)
        return nil;

    if (pid == 0) {
        setenv("TERM", "xterm-256color", 1);
        setenv("LC_ALL", "C", 1);
        setenv("LANG", "C", 1);

        const char *sh = [shellName UTF8String];

        const char *argv[8] = {0};
        int idx = 0;
        argv[idx++] = sh;

        if (strcmp(sh, "bash") == 0) {
            argv[idx++] = "--noprofile";
            argv[idx++] = "--norc";
            argv[idx++] = "-i";
        } else if (strcmp(sh, "zsh") == 0) {
            argv[idx++] = "-f";
            argv[idx++] = "-i";
        } else {
            argv[idx++] = "-i";
        }
        argv[idx] = NULL;

        execvp(sh, (char * const *)argv);
        _exit(127);
    }

    int flags = fcntl(masterFd, F_GETFL, 0);
    fcntl(masterFd, F_SETFL, flags | O_NONBLOCK);

    NSMutableData *buffer = [NSMutableData data];
    const NSTimeInterval overallDeadline = [NSDate timeIntervalSinceReferenceDate] + timeout;
    NSTimeInterval idleDeadline = [NSDate timeIntervalSinceReferenceDate] + 0.25;

    char tmp[4096];
    while (true) {
        NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
        if (now > overallDeadline) break;

        struct timeval tv;
        NSTimeInterval remaining = MIN(overallDeadline - now, 0.25);
        tv.tv_sec = (int)remaining;
        tv.tv_usec = (int)((remaining - tv.tv_sec) * 1e6);

        fd_set rfds;
        FD_ZERO(&rfds);
        FD_SET(masterFd, &rfds);

        int sel = select(masterFd + 1, &rfds, NULL, NULL, &tv);
        if (sel > 0 && FD_ISSET(masterFd, &rfds)) {
            ssize_t n = read(masterFd, tmp, sizeof(tmp));
            if (n == 0) break;
            if (n > 0) {
                [buffer appendBytes:tmp length:(NSUInteger)n];
                idleDeadline = [NSDate timeIntervalSinceReferenceDate] + 0.20;
            }
        }

        if (buffer.length > 0 && [NSDate timeIntervalSinceReferenceDate] > idleDeadline)
            break;
    }

    kill(pid, SIGKILL);
    close(masterFd);

    if (buffer.length == 0)
        return nil;

    NSString *raw = [[NSString alloc] initWithData:buffer encoding:NSUTF8StringEncoding];
    if (!raw)
        if (!(raw = [[NSString alloc] initWithData:buffer encoding:NSISOLatin1StringEncoding]))
            return nil;

    NSString *clean = StripANSIEscapes(raw);
    NSArray<NSString*> *lines = [clean componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    NSString *last = lines.lastObject ?: clean;
    NSString *trimmed = [last stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"\r"]];
    if (trimmed.length == 0 && lines.count >= 2)
        trimmed = [lines[lines.count - 2] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

    return trimmed.length > 0 ? trimmed : nil;
}

- (NSString*)ExecuteShellCommand:(NSString*)command {
    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:@"/bin/sh"];
    [task setArguments:@[@"-c", command]];

    NSPipe *pipe = [NSPipe pipe];
    [task setStandardOutput:pipe];
    [task setStandardError:[NSPipe pipe]];

    @try {
        [task launch];
        [task waitUntilExit];

        if ([task terminationStatus] == 0) {
            NSData *data = [[pipe fileHandleForReading] readDataToEndOfFile];
            NSString *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            return [output stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        }
    } @catch (NSException *exception) {
        NSLog(@"Error executing command: %@", exception);
    }

    return nil;
}

- (NSString*)GetShellPrompt:(NSString*)shellName
         withPromptVariable:(NSString*)promptVariable {
    NSString *rendered = [self renderPromptForShell:shellName timeout:1.0];
    if (rendered && rendered.length > 0)
        return rendered;

    if ([shellName isEqualToString:@"fish"]) {
        NSString *command = [NSString stringWithFormat:@"%@ -i -c 'fish_prompt'", shellName];
        NSString *out = [self ExecuteShellCommand:command];
        return out ?: @"";
    }

    if ([shellName isEqualToString:@"zsh"]) {
        NSString *command = [NSString stringWithFormat:@"%@ -i -c 'print -P \"$PROMPT\"'", shellName];
        NSString *out = [self ExecuteShellCommand:command];
        return out ?: @"";
    }

    NSString *command = [NSString stringWithFormat:@"%@ -i -c 'echo \"$%@\"'", shellName, promptVariable];
    return [self ExecuteShellCommand:command] ?: @"";
}

- (BOOL)ShellExists:(NSString*)shellName {
    NSString *command = [NSString stringWithFormat:@"which %@", shellName];

    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:@"/bin/sh"];
    [task setArguments:@[@"-c", command]];

    NSPipe *pipe = [NSPipe pipe];
    [task setStandardOutput:pipe];
    [task setStandardError:[NSPipe pipe]];

    @try {
        [task launch];
        [task waitUntilExit];

        NSData *data = [[pipe fileHandleForReading] readDataToEndOfFile];
        NSString *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];

        return [task terminationStatus] == 0 && output.length > 0;
    } @catch (NSException *exception) {
        return NO;
    }
}

- (NSArray*)GetAvailableShells {
    NSArray *allShells = @[@"bash", @"zsh", @"fish", @"tcsh", @"csh", @"sh", @"ksh"];
    NSMutableArray *available = [NSMutableArray array];
    for (NSString *shell in allShells)
        if ([self ShellExists:shell])
            [available addObject:shell];
    return [available copy];
}

- (instancetype)init {
    if (self = [super init]) {
        _terminals = [NSMutableDictionary dictionary];
        self.terminals = @{}; // start with empty immutable view

        NSArray *availableShells = [self GetAvailableShells];
        if ([availableShells count] == 0) {
            NSLog(@"Unable to find any available shells!\n");
            return nil;
        }
        NSDictionary *promptVars = @{
            @"bash": @"PS1",
            @"zsh": @"PS1",
            @"fish": @"fish_prompt",
            @"tcsh": @"prompt",
            @"csh": @"prompt",
            @"sh": @"PS1",
            @"ksh": @"PS1"
        };
        NSMutableDictionary *prompts = [NSMutableDictionary new];
        for (NSString *shell in [promptVars allKeys]) {
            if (![availableShells containsObject:shell])
                continue;
            prompts[shell] = [self GetShellPrompt:shell withPromptVariable:promptVars[shell]] ?: @"";
        }
        _shellPrompts = [prompts copy];

        [self updateAllTerminals];

        _timer = [NSTimer scheduledTimerWithTimeInterval:0.1
                                                  target:self
                                                selector:@selector(updateAllTerminals)
                                                userInfo:nil
                                                 repeats:YES];
    }
    return self;
}

- (BOOL)isTerminalApplication:(NSString*)bundleIdentifier {
    static NSArray *terminalBundleIds = @[
        // @"com.apple.Terminal",
        @"com.googlecode.iterm2",
        // @"com.microsoft.VSCode",
        // @"com.jetbrains.intellij",
        // @"com.jetbrains.pycharm",
        // @"com.jetbrains.WebStorm",
        // @"com.github.wez.wezterm",
        // @"net.kovidgoyal.kitty",
        // @"co.zeit.hyper"
    ];
    return [terminalBundleIds containsObject:bundleIdentifier];
}

- (CGPoint)findCursorInElement:(AXUIElementRef)element depth:(int)depth maxDepth:(int)maxDepth {
    if (depth > maxDepth) {
        return CGPointZero;
    }

    CFTypeRef selectedRange = NULL;
    AXError rangeError = AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute, &selectedRange);

    if (rangeError == kAXErrorSuccess && selectedRange) {
        CFTypeRef boundsForRange = NULL;
        AXError boundsError = AXUIElementCopyParameterizedAttributeValue(element,
                                                                        kAXBoundsForRangeParameterizedAttribute,
                                                                        selectedRange,
                                                                        &boundsForRange);

        if (boundsError == kAXErrorSuccess && boundsForRange) {
            CGRect bounds;
            AXValueGetValue((AXValueRef)boundsForRange, kAXValueCGRectType, &bounds);
            CGPoint cursorPos = CGPointMake(bounds.origin.x + bounds.size.width,
                                            bounds.origin.y + bounds.size.height);
            CFRelease(boundsForRange);
            CFRelease(selectedRange);
            return cursorPos;
        }
        CFRelease(selectedRange);
    }

    CFArrayRef children = NULL;
    AXError error = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute, (CFTypeRef*)&children);

    if (error == kAXErrorSuccess && children) {
        for (CFIndex i = 0; i < CFArrayGetCount(children); i++) {
            AXUIElementRef child = (AXUIElementRef)CFArrayGetValueAtIndex(children, i);

            CGPoint childCursor = [self findCursorInElement:child depth:depth+1 maxDepth:maxDepth];
            if (!CGPointEqualToPoint(childCursor, CGPointZero)) {
                CFRelease(children);
                return childCursor;
            }
        }
        CFRelease(children);
    }

    return CGPointZero;
}

- (CGPoint)getCursorPositionForWindow:(AXUIElementRef)window {
    CGPoint cursorPosition = [self findCursorInElement:window depth:0 maxDepth:4];
    if (CGPointEqualToPoint(cursorPosition, CGPointZero)) {
        CFTypeRef windowPos = NULL;
        AXError error = AXUIElementCopyAttributeValue(window, kAXPositionAttribute, &windowPos);
        if (error == kAXErrorSuccess && windowPos) {
            AXValueGetValue((AXValueRef)windowPos, kAXValueCGPointType, &cursorPosition);
            CFRelease(windowPos);
        }
    }
    return cursorPosition;
}

- (void)collectBufferInfo:(AXUIElementRef)element depth:(int)depth maxDepth:(int)maxDepth into:(NSMutableArray*)buffers {
    if (depth > maxDepth) return;

    CFTypeRef role = NULL;
    AXUIElementCopyAttributeValue(element, kAXRoleAttribute, (CFTypeRef*)&role);
    NSString *roleStr = role ? (__bridge NSString*)role : @"(null)";

    CFTypeRef description = NULL;
    AXUIElementCopyAttributeValue(element, kAXDescriptionAttribute, (CFTypeRef*)&description);
    NSString *descStr = description ? (__bridge NSString*)description : @"(null)";
    if (description) CFRelease(description);
    if (role) CFRelease(role);

    CFTypeRef value = NULL;
    AXError valueError = AXUIElementCopyAttributeValue(element, kAXValueAttribute, &value);

    do {
        if (valueError != kAXErrorSuccess || !value) break;
        if (CFGetTypeID(value) != CFStringGetTypeID()) break;

        CFStringRef textValue = (CFStringRef)value;
        NSString *text = (__bridge NSString*)textValue;
        if (text.length == 0) break;

        CFTypeRef selectedRange = NULL;
        AXError rangeError = AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute, &selectedRange);
        if (rangeError != kAXErrorSuccess || !selectedRange) break;

        CFRange range;
        AXValueGetValue((AXValueRef)selectedRange, kAXValueCFRangeType, &range);

        BOOL cursorAtEnd = (range.location == text.length);

        NSRegularExpression *promptRegex = [NSRegularExpression regularExpressionWithPattern:@"[\\$%#>]$" options:0 error:nil];
        NSTextCheckingResult *promptMatch = [promptRegex firstMatchInString:text options:0 range:NSMakeRange(0, text.length)];
        BOOL hasPrompt = (promptMatch != nil);

        NSDictionary *bufferInfo = @{
            @"text": text,
            @"cursorLocation": @(range.location),
            @"selectionLength": @(range.length),
            @"cursorAtEnd": @(cursorAtEnd),
            @"hasPrompt": @(hasPrompt),
            @"isCommandLine": @((cursorAtEnd && hasPrompt) || text.length < 200),
            @"role": roleStr
        };

        [buffers addObject:bufferInfo];
        CFRelease(selectedRange);
    } while(0);

    if (value) CFRelease(value);

    CFArrayRef children = NULL;
    AXError error = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute, (CFTypeRef*)&children);
    if (error == kAXErrorSuccess && children) {
        for (CFIndex i = 0; i < CFArrayGetCount(children); i++) {
            AXUIElementRef child = (AXUIElementRef)CFArrayGetValueAtIndex(children, i);
            [self collectBufferInfo:child depth:depth+1 maxDepth:maxDepth into:buffers];
        }
        CFRelease(children);
    }
}

- (NSDictionary*)getTerminalBufferInfo:(AXUIElementRef)window {
    NSMutableArray *allBuffers = [NSMutableArray array];
    [self collectBufferInfo:window depth:0 maxDepth:4 into:allBuffers];

    NSDictionary *bestBuffer = nil;
    for (NSDictionary *buffer in allBuffers) {
        if (!bestBuffer) {
            bestBuffer = buffer;
            continue;
        }
        NSString *currentRole = buffer[@"role"];
        NSString *bestRole = bestBuffer[@"role"];
        BOOL currentIsCommandLine = [buffer[@"isCommandLine"] boolValue];
        BOOL bestIsCommandLine = [bestBuffer[@"isCommandLine"] boolValue];
        BOOL currentIsTextArea = [currentRole isEqualToString:@"AXTextArea"];
        BOOL bestIsTextArea = [bestRole isEqualToString:@"AXTextArea"];
        if (currentIsTextArea && !bestIsTextArea)
            bestBuffer = buffer;
        else if (currentIsTextArea == bestIsTextArea) {
            if (currentIsCommandLine && !bestIsCommandLine)
                bestBuffer = buffer;
            else if (currentIsCommandLine == bestIsCommandLine) {
                if (currentIsTextArea) {
                    if ([buffer[@"text"] length] > [bestBuffer[@"text"] length])
                        bestBuffer = buffer;
                } else {
                    if ([buffer[@"text"] length] < [bestBuffer[@"text"] length])
                        bestBuffer = buffer;
                }
            }
        }
    }
    return bestBuffer;
}

- (NSString*)getWorkingDirectoryForPID:(pid_t)pid
                                  appName:(NSString*)appName
                               windowTitle:(NSString*)windowTitle {
    // TODO
    return NSHomeDirectory();
}

- (void)updateTerminalWindow:(AXUIElementRef)window
                         pid:(pid_t)pid
                     appName:(NSString*)appName
                     focused:(BOOL)isFocused {
    NSNumber *key = @(pid);
    TerminalWindow *termWindow = _terminals[key];
    if (!termWindow) {
        termWindow = [[TerminalWindow alloc] init];
        termWindow.pid = pid;
        termWindow.appName = appName;
        termWindow.axWindow = window;
        termWindow.shell = nil;
        termWindow.focused = NO;
        CFRetain(window);
        _terminals[key] = termWindow;
    }

    // Update window title
    CFTypeRef titleValue = NULL;
    AXError error = AXUIElementCopyAttributeValue(window, kAXTitleAttribute, &titleValue);
    if (error == kAXErrorSuccess && titleValue) {
        termWindow.windowTitle = [(__bridge NSString*)titleValue copy];
        CFRelease(titleValue);
    }

    CGPoint lastPoint = termWindow.cursorPosition;
    termWindow.cursorPosition = [self getCursorPositionForWindow:window];
    if (lastPoint.x != termWindow.cursorPosition.x || lastPoint.y != termWindow.cursorPosition.y) {
        [[NSNotificationCenter defaultCenter] postNotificationName:TerminalWatcherTerminalDidUpdateNotification
                                                            object:self
                                                          userInfo:@{@"terminal": termWindow}];
    }
    termWindow.bufferInfo = [self getTerminalBufferInfo:termWindow.axWindow];
    termWindow.focused = isFocused;

    // Buffer text safety
    NSString *bufferText = [termWindow.bufferInfo objectForKey:@"text"];
    if (![bufferText isKindOfClass:[NSString class]] || bufferText.length == 0) {
        termWindow.terminalInput = nil;
        return;
    }

    NSArray *lines = [bufferText componentsSeparatedByString:@"\n"];

    // Detect shell once
    if (termWindow.shell == nil) {
        for (NSString *line in lines) {
            for (NSString *shell in _shellPrompts) {
                NSString *promptStr = _shellPrompts[shell];
                if (promptStr.length > 0 && [line containsString:promptStr]) {
                    termWindow.shell = shell;
                    break;
                }
            }
            if (termWindow.shell != nil) break;
        }
    }

    termWindow.terminalInput = nil;
    NSString *lastLine = [lines lastObject] ?: @"";
    NSString *prompt = termWindow.shell ? _shellPrompts[termWindow.shell] : nil;
    if (lastLine.length == 0 || prompt.length == 0)
        return;

    if (![lastLine containsString:prompt])
        return;

    // Keep your search logic but protect against nil
    for (int i = 0; i < (int)lastLine.length; i++) {
        if (i + (int)prompt.length >= (int)lastLine.length) break;
        if ([lastLine characterAtIndex:i] == [prompt characterAtIndex:0]) {
            BOOL match = YES;
            for (int j = 0; j < (int)prompt.length; j++) {
                if ([lastLine characterAtIndex:i + j] != [prompt characterAtIndex:j]) {
                    match = NO;
                    break;
                }
            }
            if (match) {
                termWindow.terminalInput = [lastLine substringWithRange:NSMakeRange(i, prompt.length)];
                break;
            }
        }
    }
}

- (void)updateAllTerminals {
    static NSNumber *lastFocusedPID = nil;
    NSNumber *currentFocusedPID = nil;

    AXUIElementRef focusedWindow = NULL;
    NSRunningApplication *frontmostApp = [[NSWorkspace sharedWorkspace] frontmostApplication];
    if (frontmostApp) {
        AXUIElementRef appElement = AXUIElementCreateApplication(frontmostApp.processIdentifier);
        if (appElement) {
            AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute, (CFTypeRef*)&focusedWindow);
            CFRelease(appElement);
        }
    }

    NSArray<NSRunningApplication*> *apps = [[NSWorkspace sharedWorkspace] runningApplications];
    NSMutableSet *currentPIDs = [NSMutableSet set];

    for (NSRunningApplication *app in apps) {
        NSString *bundleId = app.bundleIdentifier;
        if (![self isTerminalApplication:bundleId])
            continue;

        pid_t pid = app.processIdentifier;
        [currentPIDs addObject:@(pid)];

        AXUIElementRef appElement = AXUIElementCreateApplication(pid);
        CFArrayRef windowList = NULL;
        AXError error = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute, (CFTypeRef*)&windowList);
        if (error == kAXErrorSuccess && windowList) {
            CFIndex windowCount = CFArrayGetCount(windowList);
            for (CFIndex i = 0; i < windowCount; i++) {
                AXUIElementRef window = (AXUIElementRef)CFArrayGetValueAtIndex(windowList, i);
                CFRetain(window);

                BOOL isFocused = NO;
                if (focusedWindow) {
                    isFocused = CFEqual(window, focusedWindow);
                    if (isFocused)
                        currentFocusedPID = @(pid);
                }

                [self updateTerminalWindow:window pid:pid appName:app.localizedName focused:isFocused];
                CFRelease(window);
            }
            CFRelease(windowList);
        }
        CFRelease(appElement);
    }
    if (focusedWindow) CFRelease(focusedWindow);

    for (NSNumber *pidNum in [_terminals allKeys])
        if (![currentPIDs containsObject:pidNum])
            [_terminals removeObjectForKey:pidNum];

    self.terminals = [_terminals copy];

    [[NSNotificationCenter defaultCenter] postNotificationName:TerminalWatcherDidUpdateTerminalsNotification
                                                        object:self
                                                      userInfo:nil];

    BOOL focusedChanged = (lastFocusedPID == nil && currentFocusedPID != nil) ||
                          (lastFocusedPID != nil && currentFocusedPID == nil) ||
                          (lastFocusedPID != nil && currentFocusedPID != nil && ![lastFocusedPID isEqualToNumber:currentFocusedPID]);

    if (focusedChanged) {
        TerminalWindow *focusedTW = currentFocusedPID ? _terminals[currentFocusedPID] : nil;
        [[NSNotificationCenter defaultCenter] postNotificationName:TerminalWatcherFocusedTerminalDidChangeNotification
                                                            object:self
                                                          userInfo:@{
                                                              @"pid": currentFocusedPID ?: (id)[NSNull null],
                                                              @"terminal": focusedTW ?: (id)[NSNull null]
                                                          }];
        lastFocusedPID = currentFocusedPID;
    }
}
@end
