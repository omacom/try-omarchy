# Trackpad scrolling

Two-finger trackpad scrolling reaches the guest as touchpad finger scrolling on the **QEMU Virtio Pinch Touchpad**, the device [pinch zoom](pinch-zoom.md) uses. libinput then reports finger scrolling with a scroll stop at the end, so applications can recognize swipe navigation and start their own kinetic scrolling. Chrome's two-finger swipe back and forward is the main case.

## Which path a scroll takes

| Scroll | Path |
| --- | --- |
| Precise, in the focused guest view, from a scroll that began there | Two touchpad contacts moving together |
| macOS momentum after such a scroll | Dropped: the guest scrolls kinetically by itself, as on real hardware |
| Momentum after any other scroll | High-resolution wheel on the tablet |
| A discrete mouse wheel | Wheel on the tablet |
| Outside the guest view, or with the window in the background | Wheel on the tablet |

## Input behavior

The contacts land when AppKit begins a scroll, move with each precise delta, and lift when it ends or is cancelled. Focus loss, leaving the view, a pinch, invalid deltas and VM state changes also lift them. Pinch and scrolling share the touchpad's two slots, so a new gesture of one kind ends the other.

Each landing uses new tracking IDs. If a full guest queue drops a release frame, the next gesture reads as a new touch rather than as the old contacts jumping.

The contacts move as libinput's default, non-natural finger scrolling expects. The guest therefore scrolls in the direction macOS chose, including its natural scrolling setting. The guest package turns off natural scrolling for this device, so turning it on for touchpads in Omarchy doesn't reverse it again.

The touchpad is a 3.3 m square sensor at 10 units/mm, so one gesture can travel about 10,000 points before it reaches an edge. A scroll that still reaches an edge lifts and lands again at the opposite edge. Contacts stay 12.5% inside every edge, clear of libinput's palm and thumb zones.

## Speed

macOS sets how many points each scroll event carries, including its own acceleration and the trackpad scrolling speed in System Settings. A fast scroll moves the contacts 0.12 mm per point. Slower scrolls move them less, down to 0.45 times as far below 4 points per event, rising smoothly to the full distance at 40 points per event. Normal scrolling is calmer, and flicks keep their reach. The guest's touchpad settings then tune the speed, as on real hardware: Omarchy sets `touchpad.scroll_factor` to 0.4 and adjusts some terminals with `scroll_touchpad`.

## Differences from the wheel path

libinput starts a two-finger scroll only once both touches have moved 1.5 mm, and discards that movement. So the first move of every landing moves the contacts 1.6 mm in the scroll's direction, in a frame of its own, before the real movement. Scrolling then starts at once and no movement is lost, even on a short flick.

libinput also locks finger scrolling to one axis until both axes are clearly in use.

## Touch jumps

libinput discards a touch that moves more than 20 mm in 12 ms, or speeds up by more than 7 mm in one frame, as a hardware glitch. macOS scroll deltas cross those limits on any fast swipe, and a VM's frame timing makes them worse, so fast swipes would not scroll. The guest package's libinput quirk, `/usr/share/libinput/90-try-omarchy.quirks`, turns jump detection off for this device only. libinput has no generic setting for it, so the quirk uses the model flag whose only effect is that ([libinput#506](https://gitlab.freedesktop.org/libinput/libinput/-/issues/506)).

## Validation

`make test` compiles the gesture header from the runtime patch and checks its geometry, lifecycle, momentum handling and tracking IDs, the AppKit routing contract, and the builder's checksum and patch order. The pinch tests check the sensor size. The optional guest-ABI test in [pinch zoom](pinch-zoom.md#validation) checks the device's capabilities.

In the guest, check:

1. `libinput debug-events` shows `POINTER_SCROLL_FINGER` on the pinch touchpad, ending with a zero scroll.
2. A two-finger horizontal swipe in Chrome shows the back arrow and goes back.
3. A flick keeps scrolling after the fingers lift, once, with no second push.
4. A fast swipe on a long page scrolls far, and `journalctl -b | grep -i "touch jump"` stays empty.
5. Pinch zoom, a mouse wheel, focus loss mid-scroll, and scrolling a background window still work.
