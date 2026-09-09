# Trackpad pinch zoom

The Cocoa runtime forwards macOS magnification gestures through a dedicated
`virtio-pinch-pci` device named **QEMU Virtio Pinch Touchpad**. Linux can recognize
this as an indirect touchpad and deliver pinch gestures to Wayland applications
such as Chromium and Firefox. The bridge does not send zoom keyboard shortcuts.

The existing Virtio Tablet continues to handle pointer movement, clicks, and
scrolling. The new device subscribes only to QEMU multitouch events and does not
replace the existing multitouch touchscreen device.

## Guest configuration

New factory users load `/usr/share/try-omarchy/pinch-input.lua` from their
`~/.config/hypr/input.lua`. This disables tapping and disable-while-typing for
the gesture device. Its synthetic contacts must not become tap clicks or be
suppressed after keyboard input.

App updates retain existing persistent guest disks. Before testing a rebuilt
runtime with an existing guest, add this to `~/.config/hypr/input.lua`:

```lua
hl.device({
  name = "qemu-virtio-pinch-touchpad",
  tap_to_click = false,
  disable_while_typing = false,
})
```

Save, then run `hyprctl reload` and `hyprctl configerrors`. A factory reset is
not needed. A later reset of the user's Hyprland configuration may require
restoring this override.

## Input behavior

Cocoa provides relative magnification, not raw finger positions. The bridge
reconstructs two symmetric contacts on a 100 mm virtual sensor, with a fixed
center so the gesture does not intentionally pan the pointer. Contact spacing
accumulates continuously, bounded to 0.125–3.5 times the initial spacing per
gesture to stay within the advertised sensor. Lift and pinch again to continue
beyond those bounds. libinput still applies its normal gesture recognition.

Only gestures in the focused guest view are accepted. Ending a gesture,
cancelling it, leaving the view, or losing window focus releases both contacts.
Updates after cancellation are ignored until the next begin. Non-finite and
invalid magnification values cancel the active contacts.

VM state changes clear the local gesture. Resuming also emits a release frame,
because QEMU drops normal input while stopped and a release during that time
may not have reached the guest.

This adds magnification only. Rotation, raw trackpad passthrough, and
three/four-finger gestures are outside this change. Applications must support
pinch gestures; this does not add zoom behavior to every Linux application.

## Validation

`make test` compiles and exercises the exact geometry and lifecycle header from
the runtime patch, and checks the builder's patch checksum. The runtime build
applies the patch after the existing patches without changing the upstream pin.

An optional Linux guest-ABI test uses a patched x86_64 QEMU built with TCG/qtest:

```sh
QEMU_PINCH_TEST_BINARY=/absolute/path/to/qemu-system-x86_64 \
  python3 macos/Tests/test-virtio-pinch.py
```

It creates an isolated VM with no disk and an inert ROM, reads the actual PCI
device configuration, negotiates a virtqueue, and checks contact/release events
and routing of ordinary buttons. It does not inject host input or run a guest OS.

Before marking the feature ready to merge, complete on Apple Silicon macOS:

1. Run `make test` and `make runtime`, then build/run the app.
2. Check `hyprctl devices` and `libinput list-devices` for the new touchpad and
   its gesture capability. Confirm tapping is disabled for that device.
3. Check `libinput debug-events` for pinch begin/update/end events, then verify
   continuous zoom in native Wayland Chromium and Firefox at the pointer.
4. Test short pinches, inward/outward gestures, repeated gestures, focus loss,
   leaving the guest view, and windowed/fullscreen operation. Short or cancelled
   pinches must not click; ordinary scrolling, clicking, and modifiers must work.
5. Test an existing persistent guest with the override above and a new factory
   guest. Verify cancellation around VM suspend/resume and guest reboot.

The Linux ABI and model tests do not validate AppKit event delivery or
libinput's live gesture recognition. Those remain macOS integration checks.
