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

The contacts move as libinput's default, non-natural finger scrolling expects. The guest therefore scrolls in the direction macOS chose, including its natural scrolling setting. Omarchy leaves the guest's natural scrolling off; turning it on reverses scrolling.

The touchpad is an 800 mm square sensor, so one contact can carry a whole swipe. A scroll that still reaches an edge lifts and lands again at the opposite edge. Contacts stay 100 mm inside every edge, clear of libinput's palm zones.

## Speed

One point of macOS scrolling moves the contacts 0.12 mm. The guest's touchpad settings tune the speed, as on real hardware: Omarchy sets `touchpad.scroll_factor` to 0.4 and adjusts some terminals with `scroll_touchpad`.

## Differences from the wheel path

These follow from libinput treating the scroll as a real touchpad:

- A scroll starts after about 1.5 mm of movement, roughly 12 points, and a slow scroll can take up to 150 ms to start. Smaller nudges do not scroll.
- libinput locks finger scrolling to one axis until both axes are clearly in use.
- libinput discards a contact movement over 20 mm in 12 ms, about 160 points, or one that grows by more than 7 mm between frames, and logs a touch jump. Very fast flicks can lose that movement.

## Validation

`make test` compiles the gesture header from the runtime patch and checks its geometry, lifecycle, momentum handling and tracking IDs, the AppKit routing contract, and the builder's checksum and patch order. The pinch tests check the sensor size. The optional guest-ABI test in [pinch zoom](pinch-zoom.md#validation) checks the device's capabilities.

In the guest, check:

1. `libinput debug-events` shows `POINTER_SCROLL_FINGER` on the pinch touchpad, ending with a zero scroll.
2. A two-finger horizontal swipe in Chrome shows the back arrow and goes back.
3. A flick keeps scrolling after the fingers lift, once, with no second push.
4. `journalctl -b | grep -i "touch jump"` stays empty after fast flicks.
5. Pinch zoom, a mouse wheel, focus loss mid-scroll, and scrolling a background window still work.
