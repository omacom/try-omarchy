#import <Foundation/Foundation.h>
#include <assert.h>
#include <unistd.h>

/* Controlled AppKit boundary: no window, event tap or synthetic key events. */
@interface FocusApplication : NSObject
@property BOOL active;
- (BOOL)isActive;
@end
@implementation FocusApplication
- (BOOL)isActive { return self.active; }
@end

@interface FocusWindow : NSObject
@property BOOL key;
- (BOOL)isKeyWindow;
@end
@implementation FocusWindow
- (BOOL)isKeyWindow { return self.key; }
@end

static FocusApplication *NSApp;
static BOOL full_grab_enabled;

@interface FocusProcess : NSObject
@property pid_t processIdentifier;
@end
@implementation FocusProcess
@end

@interface FocusWorkspace : NSObject
@property(strong) FocusProcess *frontmostApplication;
+ (instancetype)sharedWorkspace;
@end
@implementation FocusWorkspace
+ (instancetype)sharedWorkspace {
    static FocusWorkspace *workspace;
    if (!workspace) { workspace = [FocusWorkspace new]; }
    return workspace;
}
@end

#define NSRunningApplication FocusProcess
#define NSWorkspace FocusWorkspace

typedef const void *CGEventRef;
typedef void *CGEventTapProxy;
typedef unsigned int CGEventType;
enum { kCGEventKeyDown = 10, kCGEventKeyUp = 11,
       kCGEventTapDisabledByTimeout = 0xfffffffe,
       kCGEventTapDisabledByUserInput = 0xffffffff };
#define COCOA_DEBUG(...) ((void)0)

@interface NSEvent : NSObject
+ (instancetype)eventWithCGEvent:(CGEventRef)event;
@end
@implementation NSEvent
+ (instancetype)eventWithCGEvent:(CGEventRef)event { return [NSEvent new]; }
@end

@interface FocusView : NSObject {
@public
    BOOL isMouseGrabbed;
    BOOL guestKeysDown;
    BOOL guestButtonsDown;
    int handledEvents;
    int reenabledTaps;
}
@property(strong) FocusWindow *window;
- (BOOL)isKeyboardCaptured;
- (void)ungrabMouse;
- (void)raiseAllKeys;
- (BOOL)handleEvent:(NSEvent *)event;
- (void)reenableEventTap;
@end
@implementation FocusView
/* CAPTURE */
- (void)ungrabMouse { isMouseGrabbed = NO; guestButtonsDown = NO; }
- (void)raiseAllKeys { guestKeysDown = NO; }
- (BOOL)handleEvent:(NSEvent *)event { handledEvents++; return YES; }
- (void)reenableEventTap { reenabledTaps++; }
@end

#define QemuCocoaView FocusView
/* CALLBACK */

static FocusView *cocoaView;
@interface FocusController : NSObject
- (void)applicationDidResignActive:(NSNotification *)notification;
@end
@implementation FocusController
/* DEACTIVATE */
@end

int main(void)
{
    @autoreleasepool {
        NSApp = [FocusApplication new];
        FocusView *view = [FocusView new];
        view.window = [FocusWindow new];
        FocusProcess *foreground = [FocusProcess new];
        [FocusWorkspace sharedWorkspace].frontmostApplication = foreground;
        foreground.processIdentifier = getpid() + 1;

        /* A stale grab must never consume another application's keyboard. */
        /* Cached AppKit state can still say active while another Mac app owns
         * keyboard events. Only the foreground process may authorize capture. */
        NSApp.active = YES;
        view.window.key = YES;
        view->isMouseGrabbed = YES;
        full_grab_enabled = YES;
        assert(![view isKeyboardCaptured]);
        int event = 1;
        assert(handleTapEvent(NULL, kCGEventKeyDown, &event, view) == &event);
        assert(view->handledEvents == 0);

        [FocusWorkspace sharedWorkspace].frontmostApplication = nil;
        assert(![view isKeyboardCaptured]);
        [FocusWorkspace sharedWorkspace].frontmostApplication = foreground;

        /* A different window of the active app must also retain its input. */
        NSApp.active = YES;
        foreground.processIdentifier = getpid();
        view.window.key = NO;
        assert(![view isKeyboardCaptured]);

        /* Both windowed and full-screen guests still own focused shortcuts. */
        view.window.key = YES;
        view->isMouseGrabbed = NO;
        assert([view isKeyboardCaptured]);
        assert(handleTapEvent(NULL, kCGEventKeyDown, &event, view) == NULL);
        assert(handleTapEvent(NULL, kCGEventKeyUp, &event, view) == NULL);
        assert(view->handledEvents == 2);

        /* Observation must pass every event through even while focused. */
        setenv("TRYOMARCHY_INPUT_OBSERVE_ONLY", "1", 1);
        assert(handleTapEvent(NULL, kCGEventKeyDown, &event, view) == &event);
        assert(view->handledEvents == 2);
        unsetenv("TRYOMARCHY_INPUT_OBSERVE_ONLY");
        assert(handleTapEvent(NULL, kCGEventTapDisabledByTimeout, &event, view) == &event);
        assert(handleTapEvent(NULL, kCGEventTapDisabledByUserInput, &event, view) == &event);
        assert(view->reenabledTaps == 2);
        view->isMouseGrabbed = YES;
        assert([view isKeyboardCaptured]);

        /* Deactivation releases held input even before window focus changes.
         * Repeating cleanup (then receiving window-resign-key) is harmless. */
        cocoaView = view;
        FocusController *controller = [FocusController new];
        view->guestKeysDown = YES;
        view->guestButtonsDown = YES;
        NSApp.active = NO;
        foreground.processIdentifier = getpid() + 1;
        [controller applicationDidResignActive:nil];
        [controller applicationDidResignActive:nil];
        assert(!view->isMouseGrabbed);
        assert(!view->guestKeysDown);
        assert(!view->guestButtonsDown);
        assert(![view isKeyboardCaptured]);

        /* Losing focus and returning repeatedly needs no guest keystroke. */
        for (int cycle = 0; cycle < 20; cycle++) {
            NSApp.active = NO;
            foreground.processIdentifier = getpid() + 1;
            assert(![view isKeyboardCaptured]);
            NSApp.active = YES;
            foreground.processIdentifier = getpid();
            assert([view isKeyboardCaptured]);
        }

        /* Delayed local activation must not lose focused shortcuts either. */
        NSApp.active = NO;
        assert([view isKeyboardCaptured]);

        full_grab_enabled = NO;
        view->isMouseGrabbed = NO;
        assert(![view isKeyboardCaptured]);
        view->isMouseGrabbed = YES;
        assert([view isKeyboardCaptured]);
    }
    return 0;
}
