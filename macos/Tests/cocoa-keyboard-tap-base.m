/* QEMU Cocoa event-tap callback at c3d48b7d1e89604920e5b81b91140c2ad39a1943.
 * Copyright (c) 2008 Mike Kronenberg. MIT license, as in ui/cocoa.m. */
static CGEventRef handleTapEvent(CGEventTapProxy proxy, CGEventType type, CGEventRef cgEvent, void *userInfo)
{
    QemuCocoaView *view = userInfo;
    NSEvent *event = [NSEvent eventWithCGEvent:cgEvent];
    if ([view isMouseGrabbed] && [view handleEvent:event]) {
        COCOA_DEBUG("Global events tap: qemu handled the event, capturing!\n");
        return NULL;
    }
    COCOA_DEBUG("Global events tap: qemu did not handle the event, letting it through...\n");
    return cgEvent;
}
