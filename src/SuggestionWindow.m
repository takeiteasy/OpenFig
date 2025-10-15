#import "SuggestionWindow.h"
#import <QuartzCore/QuartzCore.h>
#import <CoreVideo/CoreVideo.h>

@interface SuggestionWindow () {
    // Display link
    CVDisplayLinkRef _displayLink;

    NSPoint _targetTopLeft;
    BOOL _hasInitialPlacement;
    CFTimeInterval _lastTick; // seconds (host time converted)

    // Spring state
    NSPoint _velocity;
}
// Tunables
@property (nonatomic) CGFloat windowWidth;
@property (nonatomic) CGFloat windowHeight;

// Spring parameters (units: per second)
// k: stiffness (how strongly it pulls toward target)
// c: damping (how much it resists velocity). For critical damping, c ~= 2*sqrt(k)
@property (nonatomic) CGFloat stiffness;
@property (nonatomic) CGFloat damping;

// Optional speed cap to avoid huge jumps
@property (nonatomic) CGFloat maxSpeed; // points per second
@end

@implementation SuggestionWindow

- (instancetype)initWithDelegate:(id<NSWindowDelegate>)delegate {
    if (self = [super initWithContentRect:NSMakeRect(0, 0, 0, 0)
                                styleMask:NSWindowStyleMaskBorderless
                                  backing:NSBackingStoreBuffered
                                    defer:NO]) {
        [self setTitle:NSProcessInfo.processInfo.processName];
        [self setOpaque:NO];
        [self setExcludedFromWindowsMenu:NO];
        [self setBackgroundColor:[NSColor clearColor]];
        [self setIgnoresMouseEvents:YES];
        [self setHasShadow:YES];
        [self setLevel:NSFloatingWindowLevel];
        [self setCanHide:NO];
        [self setDelegate:delegate];
        [self setReleasedWhenClosed:NO];

        _displayLink = NULL;
        _hasInitialPlacement = NO;
        _lastTick = 0;
        _velocity = NSMakePoint(0, 0);

        self.windowWidth = 200.0;
        self.windowHeight = 120.0;

        // Faster, more responsive motion: higher stiffness, critically damped, no speed cap.
        self.stiffness = 320.0;                   // higher = snappier chase
        self.damping = 2.0 * sqrt(self.stiffness); // critical damping to avoid overshoot
        self.maxSpeed = 0.0;                      // 0 = no cap
    }
    return self;
}

- (void)dealloc {
    [self stopDisplayLink];
}

- (BOOL)canBecomeKeyWindow {
    return YES;
}

#pragma mark - Public API

- (void)show:(CGPoint)position {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self show:position];
        });
        return;
    }

    // Convert incoming accessibility (top-left origin) to AppKit (bottom-left)
    NSScreen *screen = [NSScreen mainScreen];
    CGFloat screenHeight = screen.frame.size.height;
    NSPoint newTopLeft = NSMakePoint(position.x, screenHeight - position.y);

    // Update target
    _targetTopLeft = newTopLeft;

    [self setOpaque:YES];
    [self setBackgroundColor:[NSColor redColor]];

    if (!self.isVisible || !self.isShowing || !_hasInitialPlacement) {
        // First time: place at the target immediately to avoid sliding in from (0,0)
        [self setFrame:NSMakeRect(0, 0, self.windowWidth, self.windowHeight) display:NO];
        [self setFrameTopLeftPoint:_targetTopLeft];
        _hasInitialPlacement = YES;
        self.showing = YES;
        _velocity = NSMakePoint(0, 0); // reset velocity on first placement
        [self orderFront:nil];
    } else {
        // Already visible: do not jump; the display link will ease toward the new target
        if (!self.isVisible) {
            [self orderFront:nil];
        }
    }

    [self startDisplayLinkIfNeeded];
}

- (void)hide {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self hide];
        });
        return;
    }
    [self stopDisplayLink];
    self.showing = NO;
    [self orderOut:nil];
}

#pragma mark - Display Link

static CVReturn DisplayLinkCallback(CVDisplayLinkRef link,
                                    const CVTimeStamp *now,
                                    const CVTimeStamp *outputTime,
                                    CVOptionFlags flagsIn,
                                    CVOptionFlags *flagsOut,
                                    void *context) {
    SuggestionWindow *self = (__bridge SuggestionWindow *)context;

    // Convert hostTime to seconds with high precision
    double hostFreq = CVGetHostClockFrequency();
    double nowSeconds = (hostFreq > 0.0 && outputTime->hostTime != 0)
                        ? ((double)outputTime->hostTime / hostFreq)
                        : CACurrentMediaTime();

    // Hop to main thread to perform AppKit updates and physics step
    dispatch_async(dispatch_get_main_queue(), ^{
        [self displayLinkTickWithHostTime:nowSeconds];
    });

    return kCVReturnSuccess;
}

- (void)startDisplayLinkIfNeeded {
    if (_displayLink) return;

    CVReturn r = CVDisplayLinkCreateWithActiveCGDisplays(&_displayLink);
    if (r != kCVReturnSuccess || !_displayLink) {
        NSLog(@"CVDisplayLinkCreateWithActiveCGDisplays failed: %d", r);
        _displayLink = NULL;
        return;
    }

    CVDisplayLinkSetOutputCallback(_displayLink, DisplayLinkCallback, (__bridge void *)self);

    // Associate with the main display; optional, but explicit.
    CGDirectDisplayID mainDisplay = CGMainDisplayID();
    CVDisplayLinkSetCurrentCGDisplay(_displayLink, mainDisplay);

    _lastTick = 0; // will be initialized on first callback
    CVDisplayLinkStart(_displayLink);
}

- (void)stopDisplayLink {
    if (_displayLink) {
        CVDisplayLinkStop(_displayLink);
        CVDisplayLinkRelease(_displayLink);
        _displayLink = NULL;
    }
}

#pragma mark - Animation step

- (NSPoint)currentTopLeftPoint {
    NSRect f = self.frame;
    return NSMakePoint(NSMinX(f), NSMaxY(f));
}

- (void)displayLinkTickWithHostTime:(double)nowSeconds {
    if (!self.isVisible || !self.isShowing) {
        [self stopDisplayLink];
        return;
    }

    if (_lastTick == 0) {
        _lastTick = nowSeconds;
        return;
    }

    CFTimeInterval dt = nowSeconds - _lastTick;
    _lastTick = nowSeconds;

    // Clamp dt to handle pauses or timer hiccups
    dt = MAX(0.0, MIN(0.05, dt));

    NSPoint current = [self currentTopLeftPoint];
    NSPoint target = _targetTopLeft;

    // Spring dynamics (critically damped by default):
    // x' = v
    // v' = k*(target - x) - c*v
    CGFloat dx = target.x - current.x;
    CGFloat dy = target.y - current.y;

    CGFloat ax = self.stiffness * dx - self.damping * _velocity.x;
    CGFloat ay = self.stiffness * dy - self.damping * _velocity.y;

    // Integrate velocity and position (semi-implicit Euler for stability)
    _velocity.x += ax * dt;
    _velocity.y += ay * dt;

    // Optional speed cap (disabled when maxSpeed <= 0)
    if (self.maxSpeed > 0.0) {
        CGFloat speed = hypot(_velocity.x, _velocity.y);
        if (speed > self.maxSpeed) {
            CGFloat scale = self.maxSpeed / MAX(speed, 1e-6);
            _velocity.x *= scale;
            _velocity.y *= scale;
        }
    }

    CGFloat newX = current.x + _velocity.x * dt;
    CGFloat newY = current.y + _velocity.y * dt;

    // Snap when close and slow to avoid micro-jitter
    const CGFloat posTolerance = 0.2; // points (slightly tighter)
    const CGFloat velTolerance = 8.0; // points/sec (allow faster settle without visible lag)
    BOOL nearTarget = (fabs(target.x - newX) <= posTolerance &&
                       fabs(target.y - newY) <= posTolerance);
    BOOL slowEnough = (fabs(_velocity.x) <= velTolerance &&
                       fabs(_velocity.y) <= velTolerance);
    if (nearTarget && slowEnough) {
        [self setFrameTopLeftPoint:target];
        _velocity = NSMakePoint(0, 0);
        return;
    }

    // Ensure size is correct (in case something resized the window)
    if (self.frame.size.width != self.windowWidth || self.frame.size.height != self.windowHeight) {
        [self setFrame:NSMakeRect(0, 0, self.windowWidth, self.windowHeight) display:NO];
    }

    [self setFrameTopLeftPoint:NSMakePoint(newX, newY)];
}

@end
