#import "AppDelegate.h"
#import "TerminalWatcher.h"

@interface AppDelegate ()
@end

@implementation AppDelegate
@synthesize _window;
@synthesize _watcher;

- (instancetype)init {
    self = [super init];
    if (self) {
        _window = [[SuggestionWindow alloc] initWithDelegate:self];
        _watcher = [[TerminalWatcher new] init];
    }
    return self;
}

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserver:self selector:@selector(terminalsUpdated:) name:TerminalWatcherDidUpdateTerminalsNotification object:_watcher];
    [nc addObserver:self selector:@selector(terminalUpdated:) name:TerminalWatcherTerminalDidUpdateNotification object:_watcher];
    [nc addObserver:self selector:@selector(focusedTerminalChanged:) name:TerminalWatcherFocusedTerminalDidChangeNotification object:_watcher];
}

- (void)terminalsUpdated:(NSNotification *)note {
    NSDictionary<NSNumber*, TerminalWindow*> *snapshot = _watcher.terminals;
    // React to bulk changes (added/removed terminals)
}

- (void)terminalUpdated:(NSNotification *)note {
    id terminalObj = note.userInfo[@"terminal"];
    TerminalWindow *tw = nil;
    if ([terminalObj isKindOfClass:[TerminalWindow class]])
        tw = (TerminalWindow*)terminalObj;
    if (tw) {
        [_window show:tw.cursorPosition];
        NSLog(@"Updated terminal %@ (%f, %f) focused=%d", tw.appName, tw.cursorPosition.x, tw.cursorPosition.y, tw.isFocused);
    }
}

- (void)focusedTerminalChanged:(NSNotification *)note {
    id terminalObj = note.userInfo[@"terminal"];
    TerminalWindow *focused = nil;
    if ([terminalObj isKindOfClass:[TerminalWindow class]])
        focused = (TerminalWindow*)terminalObj;
    NSLog(@"Focused terminal changed: %@", focused ? focused.appName : @"(none)");
}

@end
