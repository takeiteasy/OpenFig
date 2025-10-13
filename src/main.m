#import "AppDelegate.h"

static AppDelegate *app = nil;

static BOOL hasAccessibilityPermissions(void) {
    NSDictionary *options = @{(__bridge id)kAXTrustedCheckOptionPrompt: @YES};
    return AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options);
}

int main(int argc, const char * argv[]) {
    if (!hasAccessibilityPermissions()) {
        printf("Please grant permissions in:\n");
        printf("System Preferences > Security & Privacy > Privacy > Accessibility\n\n");
        printf("Add this app to the list and check the box to enable it.\n");
        return 1;
    }
    
    @autoreleasepool {
        app = [AppDelegate new];
        NSLog(@"* APP DELEGATE CREATED");
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        [NSApp setDelegate:app];
        [NSApp activateIgnoringOtherApps:YES];
        [NSApp run];
    }
    return 0;
}
