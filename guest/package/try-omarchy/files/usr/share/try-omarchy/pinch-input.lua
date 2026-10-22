-- This device carries reconstructed pinch and scroll contacts, not physical
-- fingers. Keep taps and keyboard palm rejection from changing those gestures.
-- macOS has already applied its scroll direction, so the guest must not
-- reverse it again.
hl.device({
  name = "qemu-virtio-pinch-touchpad",
  tap_to_click = false,
  disable_while_typing = false,
  natural_scroll = false,
})
