#import <Foundation/Foundation.h>

#include <assert.h>
#include <stdbool.h>

enum { kVK_Tab = 48, kVK_Command = 55, kVK_RightCommand = 54,
       kVK_Shift = 56, kVK_RightShift = 60 };
typedef unsigned short CGKeyCode;
typedef NSUInteger NSEventModifierFlags;
enum {
    NSEventModifierFlagShift = 1 << 17,
    NSEventModifierFlagCommand = 1 << 20,
    NSEventTypeFlagsChanged = 12,
    NSEventTypeMagnify = 30,
    NSEventTypeScrollWheel = 22,
    kCGEventFlagsChanged = 12,
    kCGKeyboardEventKeycode = 9,
};
typedef struct { CGKeyCode key; bool down; } NativeEvent;
typedef NativeEvent *CGEventRef;

@interface NSEvent : NSObject
@property CGEventRef nativeEvent;
+ (instancetype)eventWithCGEvent:(CGEventRef)event;
- (NSUInteger)type;
- (CGKeyCode)keyCode;
- (id)window;
@end

@implementation NSEvent
+ (instancetype)eventWithCGEvent:(CGEventRef)nativeEvent {
    NSEvent *event = [[self alloc] init];
    event.nativeEvent = nativeEvent;
    return event;
}
- (NSUInteger)type { return NSEventTypeFlagsChanged; }
- (CGKeyCode)keyCode { return self.nativeEvent->key; }
- (id)window { return nil; }
@end

typedef struct {
    CGKeyCode keycode;
    NSEventModifierFlags modifiers;
} CocoaHostShortcut;

static CocoaHostShortcut cocoa_host_shortcuts[] = {
    {kVK_Tab, NSEventModifierFlagCommand},
    {kVK_Tab, NSEventModifierFlagCommand | NSEventModifierFlagShift},
};
static unsigned cocoa_host_shortcut_count = 2;
#include "share-modifier.inc"

static CGKeyCode CGEventGetIntegerValueField(CGEventRef event, int field) {
    assert(field == kCGKeyboardEventKeycode);
    return event->key;
}

static bool CGEventTapIsEnabled(bool enabled) { return enabled; }

@interface QemuCocoaView : NSObject {
@public
    bool eventsTap;
    bool captured;
    unsigned guestDeliveries;
    bool guestShiftDown;
}
- (BOOL)isKeyboardCaptured;
- (BOOL)appSwitcherTapHandlesModifiers;
- (BOOL)capsLockTapHandlesKeys;
- (bool)handleEvent:(NSEvent *)event;
@end

@implementation QemuCocoaView
- (BOOL)isKeyboardCaptured { return captured; }
- (BOOL)capsLockTapHandlesKeys { return NO; }
- (bool)handleEvent:(NSEvent *)event {
    guestDeliveries++;
    if (event.keyCode == kVK_Shift) {
        // QEMU toggles Shift on a press. A second delivery turns it off.
        guestShiftDown = event.nativeEvent->down && !guestShiftDown;
    }
    return true;
}
#include "tap-availability.inc"
@end

static QemuCocoaView *cocoaView;
static bool cocoa_caps_lock_key_event(NSEvent *event) { return false; }
static QemuCocoaView *cocoa_view_of_window(id window) { return cocoaView; }
#define COCOA_DEBUG(...)

@interface AppKit : NSObject
@property unsigned hostDeliveries;
- (void)sendEvent:(NSEvent *)event;
@end

@implementation AppKit
- (void)sendEvent:(NSEvent *)event { self.hostDeliveries++; }
@end

@interface QemuApplication : AppKit
@end

@implementation QemuApplication
#include "send-event.inc"
@end

static CGEventRef dispatchTapModifier(QemuCocoaView *view, CGEventRef cgEvent) {
    int type = kCGEventFlagsChanged;
#include "tap-modifier.inc"
    if (!getenv("TRYOMARCHY_INPUT_OBSERVE_ONLY") && [view isKeyboardCaptured]) {
        [view handleEvent:[NSEvent eventWithCGEvent:cgEvent]];
        return NULL;
    }
    return cgEvent;
}

static void sendModifier(QemuApplication *app, CGKeyCode key, bool down,
                         unsigned expectedGuestDeliveries) {
    NativeEvent nativeEvent = {key, down};
    CGEventRef event = &nativeEvent;
    unsigned guestBefore = cocoaView->guestDeliveries;
    unsigned hostBefore = app.hostDeliveries;
    if (cocoaView->eventsTap) {
        assert(dispatchTapModifier(cocoaView, event) == event);
    }
    [app sendEvent:[NSEvent eventWithCGEvent:event]];
    assert(app.hostDeliveries == hostBefore + 1);
    assert(cocoaView->guestDeliveries == guestBefore + expectedGuestDeliveries);
}

int main(void) {
    @autoreleasepool {
        unsetenv("TRYOMARCHY_INPUT_OBSERVE_ONLY");
        cocoaView = [[QemuCocoaView alloc] init];
        QemuApplication *app = [[QemuApplication alloc] init];

        cocoaView->captured = true;
        cocoaView->eventsTap = true;
        sendModifier(app, kVK_Command, true, 1);
        sendModifier(app, kVK_Shift, true, 1);
        assert(cocoaView->guestShiftDown);
        sendModifier(app, kVK_Shift, false, 1);
        assert(!cocoaView->guestShiftDown);
        sendModifier(app, kVK_Command, false, 1);

        cocoaView->eventsTap = false;
        sendModifier(app, kVK_Shift, true, 1);
        sendModifier(app, kVK_Shift, false, 1);

        cocoaView->eventsTap = true;
        setenv("TRYOMARCHY_INPUT_OBSERVE_ONLY", "1", 1);
        sendModifier(app, kVK_Command, true, 1);
        sendModifier(app, kVK_Command, false, 1);
        unsetenv("TRYOMARCHY_INPUT_OBSERVE_ONLY");

        cocoaView->captured = false;
        sendModifier(app, kVK_Shift, true, 0);
        sendModifier(app, kVK_Shift, false, 0);
    }
}
