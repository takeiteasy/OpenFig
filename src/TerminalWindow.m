//
//  TerminalWindow.c
//  fig
//
//  Created by George Watson on 13/10/2025.
//

#import "TerminalWindow.h"

@implementation TerminalWindow
- (void)dealloc {
    if (_axWindow) {
        CFRelease(_axWindow);
    }
}
@end
