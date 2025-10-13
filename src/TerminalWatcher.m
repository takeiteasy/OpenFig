//
//  TerminalWatcher.m
//  fig
//
//  Created by George Watson on 13/10/2025.
//

#import "TerminalWatcher.h"

@implementation TerminalWatcher
@synthesize _timer;
@synthesize _terminals;

static NSString *StripANSIEscapes(NSString *s) {
    if (!s) return nil;
    // Remove CSI, OSC, and other common ANSI escape sequences
    NSError *err = nil;
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:
                                  @"\\x1B\\[[0-9;?]*[ -/]*[@-~]|\\x1B\\][^\\a]*(\\a|\\x1B\\\\)|\\x1B[@-Z\\\\-_]"
                                  options:0 error:&err];
    if (err) return s;
    NSMutableString *m = [s mutableCopy];
    [regex replaceMatchesInString:m options:0 range:NSMakeRange(0, m.length) withTemplate:@""];
    return m;
}

- (NSString*)renderPromptForShell:(NSString*)shellName timeout:(NSTimeInterval)timeout {
    // Launch shell attached to a PTY and capture the initial prompt
    int masterFd = -1;
    pid_t pid = forkpty(&masterFd, NULL, NULL, NULL);
    if (pid < 0) {
        return nil;
    }

    if (pid == 0) {
        // Child: set up a minimal env and exec the shell interactively
        setenv("TERM", "xterm-256color", 1);
        setenv("LC_ALL", "C", 1);
        setenv("LANG", "C", 1);

        // Build argv
        // Defaults: interactive (-i). Skip user rc files for consistency where possible.
        // bash: --noprofile --norc -i
        // zsh: -f -i
        // fish: -i
        // csh/tcsh/ksh/sh: -i
        const char *sh = [shellName UTF8String];

        // Prepare argv vector
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
        } else if (strcmp(sh, "fish") == 0) {
            argv[idx++] = "-i";
        } else if (strcmp(sh, "tcsh") == 0 || strcmp(sh, "csh") == 0 ||
                   strcmp(sh, "ksh") == 0 || strcmp(sh, "sh") == 0) {
            argv[idx++] = "-i";
        } else {
            argv[idx++] = "-i";
        }
        argv[idx] = NULL;

        // execvp uses PATH to find the shell by name
        execvp(sh, (char * const *)argv);
        _exit(127);
    }

    // Parent: read from master pty until idle or timeout
    // Make non-blocking
    int flags = fcntl(masterFd, F_GETFL, 0);
    fcntl(masterFd, F_SETFL, flags | O_NONBLOCK);

    NSMutableData *buffer = [NSMutableData data];
    const NSTimeInterval overallDeadline = [NSDate timeIntervalSinceReferenceDate] + timeout;
    NSTimeInterval idleDeadline = [NSDate timeIntervalSinceReferenceDate] + 0.25; // 250ms idle window

    char tmp[4096];

    while (true) {
        // Compute next select timeout
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
            if (n > 0) {
                [buffer appendBytes:tmp length:(NSUInteger)n];
                // Reset idle deadline since we got data
                idleDeadline = [NSDate timeIntervalSinceReferenceDate] + 0.20;
            } else if (n == 0) {
                // EOF
                break;
            } else {
                // EAGAIN or error; continue
            }
        }

        // Stop if we've been idle for a short time and have some data
        if (buffer.length > 0 && [NSDate timeIntervalSinceReferenceDate] > idleDeadline) {
            break;
        }
    }

    // Best effort cleanup
    kill(pid, SIGKILL);
    close(masterFd);

    if (buffer.length == 0) {
        return nil;
    }

    // Convert to string and strip ANSI
    NSString *raw = [[NSString alloc] initWithData:buffer encoding:NSUTF8StringEncoding];
    if (!raw) {
        // Try ISO Latin 1 fallback
        raw = [[NSString alloc] initWithData:buffer encoding:NSISOLatin1StringEncoding];
    }
    if (!raw) return nil;

    NSString *clean = StripANSIEscapes(raw);

    // Extract the last line fragment (prompt often does not end with newline)
    // Split by newlines and take the last component
    NSArray<NSString*> *lines = [clean componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    NSString *last = lines.lastObject ?: clean;

    // Trim trailing spaces commonly used in prompts
    NSString *trimmed = [last stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"\r"]];

    // If empty, try the second-to-last (some shells print a banner before prompt)
    if (trimmed.length == 0 && lines.count >= 2) {
        trimmed = [lines[lines.count - 2] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    }

    // As a safeguard, collapse multiple spaces
    return trimmed.length > 0 ? trimmed : nil;
}

- (NSString*)GetDefaultShell {
    // Try environment variable first
    const char *shellEnv = getenv("SHELL");
    if (shellEnv != NULL) {
        NSString *shellPath = [NSString stringWithUTF8String:shellEnv];
        // Extract just the shell name from the path
        return [shellPath lastPathComponent];
    }

    // Fallback: try to get from dscl
    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:@"/usr/bin/dscl"];
    [task setArguments:@[@".", @"-read", NSHomeDirectory(), @"UserShell"]];

    NSPipe *pipe = [NSPipe pipe];
    [task setStandardOutput:pipe];
    [task setStandardError:[NSPipe pipe]];

    [task launch];
    [task waitUntilExit];

    if ([task terminationStatus] == 0) {
        NSData *data = [[pipe fileHandleForReading] readDataToEndOfFile];
        NSString *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];

        // Output format: "UserShell: /bin/zsh"
        NSArray *components = [output componentsSeparatedByString:@": "];
        if (components.count > 1) {
            NSString *shellPath = [components[1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            return [shellPath lastPathComponent];
        }
    }
    return nil;
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

// Get the prompt string for a specific shell (rendered)
- (NSString*)GetShellPrompt:(NSString*)shellName
         withPromptVariable:(NSString*)promptVariable {
    // Use PTY-based rendering so backslash/percent escapes are expanded by the shell itself
    // A short timeout is enough to capture the initial prompt
    NSString *rendered = [self renderPromptForShell:shellName timeout:1.0];
    if (rendered && rendered.length > 0) {
        return rendered;
    }

    // Fallbacks if PTY fails for any reason
    if ([shellName isEqualToString:@"fish"]) {
        NSString *command = [NSString stringWithFormat:@"%@ -i -c 'fish_prompt'", shellName];
        NSString *out = [self ExecuteShellCommand:command];
        return out ?: @"";
    }

    if ([shellName isEqualToString:@"zsh"]) {
        // zsh can render PROMPT with print -P
        NSString *command = [NSString stringWithFormat:@"%@ -i -c 'print -P \"$PROMPT\"'", shellName];
        NSString *out = [self ExecuteShellCommand:command];
        return out ?: @"";
    }

    // As a last resort, echo the prompt variable (may be unexpanded)
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
        _timer = [NSTimer scheduledTimerWithTimeInterval:0.5
                                                  target:self
                                                selector:@selector(updateAllTerminals)
                                                userInfo:nil
                                                 repeats:YES];
        NSString *defaultShell = [self GetDefaultShell];
        if (!defaultShell) {
            NSLog(@"Unable to find default shell!\n");
            return nil;
        }
        NSArray *availableShells = [self GetAvailableShells];
        if ([availableShells count] == 0) {
            NSLog(@"Unable to find any available shells!\n");
            return nil;
        }
        for (NSString *shell in availableShells) {
            NSLog(@"%@\n", shell);
        }
        NSDictionary *promptVars = @{
            @"bash": @"PS1",
            @"zsh": @"PS1",
            @"fish": @"fish_prompt",  // fish uses a function instead
            @"tcsh": @"prompt",
            @"csh": @"prompt",
            @"sh": @"PS1",
            @"ksh": @"PS1"
        };
        NSMutableDictionary *prompts = [NSMutableDictionary new];
        for (NSString *shell in [promptVars allKeys]) {
            if (![availableShells containsObject:shell])
                continue;
            prompts[shell] = [self GetShellPrompt:shell
                               withPromptVariable:promptVars[shell]];
        }
        for (NSString *shell in [prompts allKeys]) {
            NSLog(@"%@: %@\n", shell, prompts[shell]);
        }
        [self updateAllTerminals];
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

    // Check if this element has cursor information
    CFTypeRef selectedRange = NULL;
    AXError rangeError = AXUIElementCopyAttributeValue(element,
                                                     kAXSelectedTextRangeAttribute,
                                                     &selectedRange);

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

    // Recursively search children
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
    // Try to find text areas by recursively searching the UI hierarchy
    CGPoint cursorPosition = [self findCursorInElement:window depth:0 maxDepth:4];
    if (CGPointEqualToPoint(cursorPosition, CGPointZero)) {
        // Fallback: get window position
        CFTypeRef windowPos = NULL;
        AXError error = AXUIElementCopyAttributeValue(window,
                                                      kAXPositionAttribute,
                                                      &windowPos);
        if (error == kAXErrorSuccess && windowPos) {
            AXValueGetValue((AXValueRef)windowPos, kAXValueCGPointType, &cursorPosition);
            CFRelease(windowPos);
        }
    }
    return cursorPosition;
}

- (void)collectBufferInfo:(AXUIElementRef)element depth:(int)depth maxDepth:(int)maxDepth into:(NSMutableArray*)buffers {
    if (depth > maxDepth) {
        return;
    }

    // Debug: Check element role and other attributes
    CFTypeRef role = NULL;
    AXUIElementCopyAttributeValue(element, kAXRoleAttribute, (CFTypeRef*)&role);
    NSString *roleStr = role ? (__bridge NSString*)role : @"(null)";

    CFTypeRef description = NULL;
    AXUIElementCopyAttributeValue(element, kAXDescriptionAttribute, (CFTypeRef*)&description);
    NSString *descStr = description ? (__bridge NSString*)description : @"(null)";

    if (depth <= 2) { // Only log top levels to avoid spam
        printf("DEBUG: Depth %d - Role: %s, Desc: %s\n", depth, roleStr.UTF8String, descStr.UTF8String);
    }

    if (description) CFRelease(description);
    if (role) CFRelease(role);

    // Check if this element has text content
    CFTypeRef value = NULL;
    AXError valueError = AXUIElementCopyAttributeValue(element, kAXValueAttribute, &value);

    do {
        if (valueError != kAXErrorSuccess || !value)
            break;
        // Check if it's a string value (text content)
        if (CFGetTypeID(value) != CFStringGetTypeID())
            break;

        CFStringRef textValue = (CFStringRef)value;
        NSString *text = (__bridge NSString*)textValue;
        // Look for elements that might contain terminal buffer text
        if (text.length == 0)
            break;

        // Check if this looks like current command line input
        CFTypeRef selectedRange = NULL;
        AXError rangeError = AXUIElementCopyAttributeValue(element,
                                                           kAXSelectedTextRangeAttribute,
                                                           &selectedRange);
        if (rangeError != kAXErrorSuccess || !selectedRange)
            break;

        // Get the range details
        CFRange range;
        AXValueGetValue((AXValueRef)selectedRange, kAXValueCFRangeType, &range);

        // Check if cursor is at the end of the text (typical for command line input)
        BOOL cursorAtEnd = (range.location == text.length);

        // Check if text ends with a shell prompt pattern
        NSRegularExpression *promptRegex = [NSRegularExpression regularExpressionWithPattern:@"[\\$%#>]$" options:0 error:nil];
        NSTextCheckingResult *promptMatch = [promptRegex firstMatchInString:text options:0 range:NSMakeRange(0, text.length)];
        BOOL hasPrompt = (promptMatch != nil);

        NSDictionary *bufferInfo = @{
            @"text": text,
            @"cursorLocation": @(range.location),
            @"selectionLength": @(range.length),
            @"cursorAtEnd": @(cursorAtEnd),
            @"hasPrompt": @(hasPrompt),
            @"isCommandLine": @((cursorAtEnd && hasPrompt) || text.length < 200), // Shorter text more likely to be current command
            @"role": roleStr
        };

        [buffers addObject:bufferInfo];
        CFRelease(selectedRange);
        CFRelease(value);
    } while(0);

    // Recursively search children
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

    // Find the best buffer (prioritize AXStaticText over other roles, then command line input)
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
        // Prioritize AXTextArea over other roles - this is most likely the editable terminal buffer
        BOOL currentIsTextArea = [currentRole isEqualToString:@"AXTextArea"];
        BOOL bestIsTextArea = [bestRole isEqualToString:@"AXTextArea"];
        // Prefer AXTextArea over other roles
        if (currentIsTextArea && !bestIsTextArea)
            bestBuffer = buffer;
        else if (currentIsTextArea == bestIsTextArea) {
            // Both are same role type, prefer command line input over scrollback
            if (currentIsCommandLine && !bestIsCommandLine)
                bestBuffer = buffer;
            else if (currentIsCommandLine == bestIsCommandLine) {
                // If both are same type, prefer longer text for TextArea (more complete buffer)
                // or shorter text for command line (more likely to be current input)
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
                     appName:(NSString*)appName {

    NSNumber *key = @(pid);
    TerminalWindow *termWindow = _terminals[key];

    if (!termWindow) {
        termWindow = [[TerminalWindow alloc] init];
        termWindow.pid = pid;
        termWindow.appName = appName;
        termWindow.axWindow = window;
        CFRetain(window);
        _terminals[key] = termWindow;
    }

    // Update window title
    CFTypeRef titleValue = NULL;
    AXError error = AXUIElementCopyAttributeValue(window,
                                                  kAXTitleAttribute,
                                                  &titleValue);
    if (error == kAXErrorSuccess && titleValue) {
        termWindow.windowTitle = [(__bridge NSString*)titleValue copy];
        CFRelease(titleValue);
    }

    // Update cursor position for focused window
    termWindow.cursorPosition = [self getCursorPositionForWindow:window];
    NSDictionary *d = [self getTerminalBufferInfo:termWindow.axWindow];

    // Debug output for cursor position changes
    static CGPoint lastCursorPos = {-1, -1};
    if (!CGPointEqualToPoint(termWindow.cursorPosition, lastCursorPos)) {
        printf("Cursor position changed for %s: (%.0f, %.0f) -> (%.0f, %.0f)\n",
               appName.UTF8String, lastCursorPos.x, lastCursorPos.y,
               termWindow.cursorPosition.x, termWindow.cursorPosition.y);
        lastCursorPos = termWindow.cursorPosition;
    }
}

- (void)updateAllTerminals {
    NSArray<NSRunningApplication*> *apps = [[NSWorkspace sharedWorkspace] runningApplications];
    NSMutableSet *currentPIDs = [NSMutableSet set];

    for (NSRunningApplication *app in apps) {
        NSString *bundleId = app.bundleIdentifier;
        // Check if it's a terminal application
        if (![self isTerminalApplication:bundleId])
            continue;
        
        pid_t pid = app.processIdentifier;
        [currentPIDs addObject:@(pid)];
        // Create AX element for this app
        AXUIElementRef appElement = AXUIElementCreateApplication(pid);
        // Get all windows for this app
        CFArrayRef windowList = NULL;
        AXError error = AXUIElementCopyAttributeValue(appElement,
                                                     kAXWindowsAttribute,
                                                     (CFTypeRef*)&windowList);
        if (error == kAXErrorSuccess && windowList) {
            CFIndex windowCount = CFArrayGetCount(windowList);
            for (CFIndex i = 0; i < windowCount; i++) {
                AXUIElementRef window = CFArrayGetValueAtIndex(windowList, i);
                // Create or update terminal window info
                [self updateTerminalWindow:window
                                       pid:pid
                                   appName:app.localizedName];
            }
            CFRelease(windowList);
        }
        CFRelease(appElement);
    }

    // Remove terminals that are no longer open
    for (NSNumber *pidNum in [_terminals allKeys])
        if (![currentPIDs containsObject:pidNum])
            [_terminals removeObjectForKey:pidNum];
}
@end
