-- This device carries reconstructed pinch contacts, not physical fingers.
-- Keep taps and keyboard palm rejection from changing those gestures.
hl.device({
  name = "qemu-virtio-pinch-touchpad",
  tap_to_click = false,
  disable_while_typing = false,
})
