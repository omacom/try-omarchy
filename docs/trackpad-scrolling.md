# Trackpad scrolling

Two-finger trackpad scrolling reaches the guest as touchpad finger scrolling on the **QEMU Virtio Pinch Touchpad**, the device [pinch zoom](pinch-zoom.md) uses. libinput then reports finger scrolling with a scroll stop at the end, so applications can recognize swipe navigation. Chrome's two-finger swipe back and forward is the main case.

## Which path a scroll takes

| Scroll | Path |
| --- | --- |
| Precise, non-momentum, in the focused guest view, from a scroll that began there | Two touchpad contacts moving together |
| macOS momentum after the fingers lift | High-resolution wheel on the tablet |
| A discrete mouse wheel | Wheel on the tablet |
| Outside the guest view, or with the window in the background | Wheel on the tablet |

## Input behavior

The contacts land when AppKit begins a scroll, move with each precise delta, and lift when it ends or is cancelled. Focus loss, leaving the view, a pinch, invalid deltas and VM state changes also lift them. Pinch and scrolling share the touchpad's two slots, so a new gesture of one kind ends the other.

The contacts move as libinput's default, non-natural finger scrolling expects. The guest therefore scrolls in the direction macOS chose, including its natural scrolling setting. Turning on natural scrolling for this device in the guest reverses it.

The touchpad is an 800 mm square sensor, so one contact can carry a whole swipe. A scroll that still reaches an edge lifts and lands again at the opposite edge. Contacts stay 12.5% inside every edge, clear of libinput's palm zones. Pinch geometry keeps its size in millimetres.

The touchpad also advertises `BTN_TOOL_TRIPLETAP`. Nothing sends three contacts yet.

## Speed

One point of macOS scrolling moves the contacts 0.12 mm. Under Omarchy's touchpad scroll factor this is meant to match the earlier wheel speed. To tune it without a rebuild, set a factor from 0.1 to 10 and restart the app:

```sh
launchctl setenv TRYOMARCHY_TRACKPAD_SCROLL_SPEED 1.5
```

Very fast flicks can exceed libinput's touch jump limit, about 20 mm in 12 ms. libinput then drops that one movement and logs a touch jump.

## Validation

`make test` compiles the gesture header from the runtime patch and checks its geometry and lifecycle, the AppKit routing contract, the touchpad's resolution and keys, and the builder's checksum and patch order. The optional guest-ABI test in [pinch zoom](pinch-zoom.md#validation) checks the device's capabilities.

In the guest, check:

1. `libinput debug-events` shows `POINTER_SCROLL_FINGER` on the pinch touchpad, ending with a zero scroll.
2. A two-finger horizontal swipe in Chrome shows the back arrow and goes back.
3. Vertical scrolling feels as fast as before, momentum continues after a flick, and a mouse wheel still scrolls.
4. Pinch zoom, focus loss mid-scroll, and scrolling a background window still work.
