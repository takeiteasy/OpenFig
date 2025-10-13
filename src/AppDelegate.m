#import "AppDelegate.h"

@implementation AppDelegate
@synthesize _window;

-(instancetype)init {
    self = [super init];
    if (self) {
        _window = [[SuggestionWindow new] initWithDelegate:self];
    }
    return self;
}
@end
