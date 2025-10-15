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

#pragma mark - Helpers

// Find the NSScreen that contains the given point in global (Quartz/AX) coordinates
// (origin at top-left). Falls back to mainScreen if none match.
- (NSScreen *)screenContainingTopLeftOriginPoint:(CGPoint)topLeftPoint {
    // Convert to AppKit coordinates (origin bottom-left) for hit-testing screens.
    NSScreen *main = [NSScreen mainScreen];
    CGFloat screenHeight = main.frame.size.height;
    NSPoint appKitPoint = NSMakePoint(topLeftPoint.x, screenHeight - topLeftPoint.y);

    for (NSScreen *screen in [NSScreen screens])
        if (NSPointInRect(appKitPoint, screen.frame))
            return screen;
    return main;
}

// Clamp desired top-left to stay fully within visibleFrame, with an initial preference
// to place the window just below the cursor with a small gap. If there isn't enough
// room below, flip above the cursor (also with a gap).
- (NSPoint)clampedTopLeftForCursorPoint:(CGPoint)cursorPointTopLeftOrigin
                                 screen:(NSScreen *)screen
                          windowPadding:(CGFloat)padding
                             gapFromRow:(CGFloat)gap {
    // Convert the incoming top-left-origin point to AppKit top-left y.
    CGFloat screenHeight = screen.frame.size.height;
    CGFloat desiredTopYAtCursor = screenHeight - cursorPointTopLeftOrigin.y;

    NSRect vis = screen.visibleFrame;

    // Start by aligning the window directly under the cursor
    CGFloat topY = desiredTopYAtCursor;

    // Horizontal placement: try to align left edge to cursor X.
    CGFloat leftX = cursorPointTopLeftOrigin.x;

    // Clamp horizontally within visibleFrame.
    CGFloat minX = NSMinX(vis);
    CGFloat maxX = NSMaxX(vis) - self.windowWidth;
    leftX = MIN(MAX(leftX, minX), maxX);

    // Check if there's enough room below (i.e., bottom >= visible minY).
    CGFloat bottomY = topY - self.windowHeight;
    CGFloat minY = NSMinY(vis);
    CGFloat maxY = NSMaxY(vis);

    if (bottomY < minY) {
        // Not enough space below; flip above the cursor line with the same gap.
        topY = desiredTopYAtCursor + self.windowHeight + gap + padding;
    } else {
        // Enough space below; offset down by gap so we sit below the row.
        topY = desiredTopYAtCursor - padding;
    }

    // Final clamp to visibleFrame vertically.
    topY = MIN(MAX(topY, minY + self.windowHeight), maxY);

    return NSMakePoint(leftX, topY);
}

#pragma mark - Public API

- (void)show:(CGPoint)position {
    // Backward-compatible default gap if caller doesn't provide one.
    [self showAtPosition:position gap:0];
}

- (void)showAtPosition:(CGPoint)position gap:(CGFloat)gap {
    if (![NSThread isMainThread]) {
        CGFloat capturedGap = gap;
        dispatch_async(dispatch_get_main_queue(), ^{
            [self showAtPosition:position gap:capturedGap];
        });
        return;
    }

    // Choose the screen that contains the incoming accessibility (top-left origin) point.
    NSScreen *screen = [self screenContainingTopLeftOriginPoint:position];
    if (!screen) screen = [NSScreen mainScreen];

    // Compute a clamped target top-left that keeps the window fully on-screen and
    // does not overlap the terminal input row (use a dynamic gap).
    NSPoint clampedTopLeft = [self clampedTopLeftForCursorPoint:position
                                                         screen:screen
                                                  windowPadding:5
                                                     gapFromRow:gap];

    // Update target used by the spring animation.
    _targetTopLeft = clampedTopLeft;

    [self setOpaque:YES];
    [self setBackgroundColor:[NSColor redColor]];

    if (!self.isVisible || !self.isShowing || !_hasInitialPlacement) {
        // Ensure correct size before positioning.
        [self setFrame:NSMakeRect(0, 0, self.windowWidth, self.windowHeight) display:NO];
        // First time: place at the clamped target immediately.
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
