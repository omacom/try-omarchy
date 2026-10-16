#import <Foundation/Foundation.h>
#include <assert.h>

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

@interface FocusView : NSObject {
@public
    BOOL isMouseGrabbed;
    BOOL guestKeysDown;
    BOOL guestButtonsDown;
}
@property(strong) FocusWindow *window;
- (BOOL)isKeyboardCaptured;
- (void)ungrabMouse;
- (void)raiseAllKeys;
@end
@implementation FocusView
/* CAPTURE */
- (void)ungrabMouse { isMouseGrabbed = NO; guestButtonsDown = NO; }
- (void)raiseAllKeys { guestKeysDown = NO; }
@end

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

        /* A stale grab must never consume another application's keyboard. */
        NSApp.active = NO;
        view.window.key = YES;
        view->isMouseGrabbed = YES;
        full_grab_enabled = YES;
        assert(![view isKeyboardCaptured]);

        /* A different window of the active app must also retain its input. */
        NSApp.active = YES;
        view.window.key = NO;
        assert(![view isKeyboardCaptured]);

        /* Both windowed and full-screen guests still own focused shortcuts. */
        view.window.key = YES;
        view->isMouseGrabbed = NO;
        assert([view isKeyboardCaptured]);
        view->isMouseGrabbed = YES;
        assert([view isKeyboardCaptured]);

        /* Deactivation releases held input even before window focus changes.
         * Repeating cleanup (then receiving window-resign-key) is harmless. */
        cocoaView = view;
        FocusController *controller = [FocusController new];
        view->guestKeysDown = YES;
        view->guestButtonsDown = YES;
        NSApp.active = NO;
        [controller applicationDidResignActive:nil];
        [controller applicationDidResignActive:nil];
        assert(!view->isMouseGrabbed);
        assert(!view->guestKeysDown);
        assert(!view->guestButtonsDown);
        assert(![view isKeyboardCaptured]);

        /* Losing focus and returning repeatedly needs no guest keystroke. */
        for (int cycle = 0; cycle < 20; cycle++) {
            NSApp.active = NO;
            assert(![view isKeyboardCaptured]);
            NSApp.active = YES;
            assert([view isKeyboardCaptured]);
        }

        full_grab_enabled = NO;
        view->isMouseGrabbed = NO;
        assert(![view isKeyboardCaptured]);
        view->isMouseGrabbed = YES;
        assert([view isKeyboardCaptured]);
    }
    return 0;
}
