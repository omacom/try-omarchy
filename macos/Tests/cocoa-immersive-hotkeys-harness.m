#import <Foundation/Foundation.h>
#include <assert.h>

/* Controlled AppKit boundary: no window, event tap or real full-screen transition. */
enum { kVK_ANSI_G = 0x05, kVK_Escape = 0x35 };
enum { NSWindowStyleMaskFullScreen = 1 << 14 };
enum {
    NSEventModifierFlagShift = 1 << 17,
    NSEventModifierFlagControl = 1 << 18,
    NSEventModifierFlagOption = 1 << 19,
};
enum { NSControlStateValueOff = 0, NSControlStateValueOn = 1 };
#define info_report(...) ((void)0)

@interface HotkeyWindow : NSObject
@property NSUInteger styleMask;
@property int toggles;
- (void)toggleFullScreen:(id)sender;
@end
@implementation HotkeyWindow
- (void)toggleFullScreen:(id)sender { self.toggles++; }
@end

@interface HotkeyMenuItem : NSObject
@property NSInteger state;
@end
@implementation HotkeyMenuItem
@end

@interface HotkeyApplication : NSObject
@property int hides;
- (void)hide:(id)sender;
@end
@implementation HotkeyApplication
- (void)hide:(id)sender { self.hides++; }
@end

@interface HotkeyView : NSObject
@property(strong) HotkeyWindow *window;
@end
@implementation HotkeyView
@end

@interface HotkeyEvent : NSObject
@property unsigned short keyCode;
@property NSUInteger modifierFlags;
@property BOOL isARepeat;
@end
@implementation HotkeyEvent
@end

#define NSWindow HotkeyWindow
#define NSMenuItem HotkeyMenuItem

static NSMutableArray *mainQueue;
#define dispatch_get_main_queue() nil
#define dispatch_async(queue, block) [mainQueue addObject:[(block) copy]]

static void drain(void)
{
    NSArray *blocks = [mainQueue copy];
    [mainQueue removeAllObjects];
    for (void (^block)(void) in blocks) {
        block();
    }
}

static HotkeyApplication *NSApp;
static HotkeyView *cocoaView;
static bool immersive_mode_enabled = true;
/* STATE */

static bool handle_control_option(HotkeyEvent *event)
{
    /* KEYS */
    return false;
}

/* FUNCTIONS */

@interface HotkeyController : NSObject
@end
@implementation HotkeyController
/* DELEGATE */
@end

static HotkeyEvent *key(unsigned short code, bool shift, bool repeat)
{
    HotkeyEvent *event = [HotkeyEvent new];
    event.keyCode = code;
    event.modifierFlags = NSEventModifierFlagControl | NSEventModifierFlagOption |
                          (shift ? NSEventModifierFlagShift : 0);
    event.isARepeat = repeat;
    return event;
}

static void press(unsigned short code, bool shift)
{
    assert(handle_control_option(key(code, shift, false)));
    drain();
}

static void assert_immersive(bool enabled)
{
    assert(immersive_mode_enabled == enabled);
    assert(immersiveMenuItem.state == (enabled ? NSControlStateValueOn : NSControlStateValueOff));
}

int main(void)
{
    @autoreleasepool {
        mainQueue = [NSMutableArray new];
        NSApp = [HotkeyApplication new];
        cocoaView = [HotkeyView new];
        HotkeyWindow *window = [HotkeyWindow new];
        cocoaView.window = window;
        HotkeyController *controller = [HotkeyController new];
        immersiveMenuItem = [HotkeyMenuItem new];
        immersiveMenuItem.state = NSControlStateValueOn;
        window.styleMask = NSWindowStyleMaskFullScreen;

        assert(!handle_control_option(key(kVK_ANSI_G, false, false)));
        assert(mainQueue.count == 0);

        assert(handle_control_option(key(kVK_Escape, false, false)));
        assert(handle_control_option(key(kVK_Escape, false, true)));
        assert(handle_control_option(key(kVK_Escape, true, true)));
        assert(window.toggles == 0);
        assert(mainQueue.count == 1);
        drain();
        assert(window.toggles == 1);
        assert_immersive(false);

        [controller windowWillExitFullScreen:nil];
        press(kVK_Escape, false);
        press(kVK_Escape, true);
        assert(window.toggles == 1);
        assert(NSApp.hides == 0);
        assert_immersive(false);
        window.styleMask = 0;
        [controller windowDidExitFullScreen:nil];

        press(kVK_Escape, false);
        assert(window.toggles == 2);
        assert_immersive(true);
        [controller windowWillEnterFullScreen:nil];
        window.styleMask = NSWindowStyleMaskFullScreen;
        [controller windowDidEnterFullScreen:nil];

        [controller windowWillExitFullScreen:nil];
        [controller windowDidFailToExitFullScreen:nil];
        assert_immersive(true);

        press(kVK_Escape, false);
        assert(window.toggles == 3);
        assert_immersive(false);
        [controller windowWillExitFullScreen:nil];
        [controller windowDidFailToExitFullScreen:nil];
        assert_immersive(true);

        press(kVK_Escape, false);
        assert(window.toggles == 4);
        assert_immersive(false);
        [controller windowWillExitFullScreen:nil];
        window.styleMask = 0;
        [controller windowDidExitFullScreen:nil];

        [controller windowWillEnterFullScreen:nil];
        [controller windowDidFailToEnterFullScreen:nil];
        assert_immersive(false);

        press(kVK_Escape, false);
        assert(window.toggles == 5);
        assert_immersive(true);
        [controller windowWillEnterFullScreen:nil];
        [controller windowDidFailToEnterFullScreen:nil];
        assert_immersive(false);

        [controller windowWillEnterFullScreen:nil];
        [controller windowDidFailToEnterFullScreen:nil];
        assert_immersive(false);

        press(kVK_Escape, true);
        assert(NSApp.hides == 1);
        assert(window.toggles == 5);
        assert_immersive(false);

        [controller toggleImmersive:nil];
        assert(window.toggles == 6);
        assert_immersive(true);
    }
    return 0;
}
