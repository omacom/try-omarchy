# Mac keyboard geometry

Try Omarchy maps the host Mac keyboard class (ANSI / ISO / JIS) into the
guest. That corrects the ISO Section / extra-ISO key inversion for every
layout. For xkeyboard-config Mac vendor layouts (`ch de dk fi fr gb is it
latam nl no pt se us` with an empty variant) it also selects Macintosh
legends.

## Host

`omarchy-vm-helper --host-keyboard-geometry` reports `ansi`, `iso`, or
`jis`. Unknown Carbon classes fail the launch. The launcher exports
`TRYOMARCHY_KEYBOARD` to QEMU and adds `tryomarchy.keyboard=` to the
`tryomarchy.host` credential. Cocoa swaps `KEY_GRAVE` and `KEY_102ND` only
when that value is `iso`. `--reset-storage-only` skips the probe.

## Guest

The `try-omarchy` package's Hyprland profile loads
`/usr/share/try-omarchy/apple-keyboard-input.lua` on every configuration
reload. It sets only `kb_model = "applealu_" .. geometry`. Layout and variant
stay whatever Omarchy setup chose. A missing token is a no-op. The profile
loads after the user's own configuration, so no user file is edited.

**Remove any local `frmac` (or similar) TLDE/LSGT symbol swap**, or the ISO
keys invert again on top of the Cocoa swap.

Omarchy's setup form asks for the keyboard layout and input method; it does
not preselect Japanese on JIS Macs. Native 英数/かな mode keys are described
in [Japanese input](japanese-input.md).

## Focus and keyboard capture

Command reaches the guest as Super while macOS identifies QEMU as the foreground
process and its VM window is key, in both windowed and full-screen presentation. A stale
mouse grab cannot authorize global keyboard capture after switching to a Mac
app. App deactivation and window focus loss both release the guest's held keys
and mouse buttons; returning to the VM does not require typing to reset capture.

If input appears stuck while using an older runtime, focus the VM and press
Control–Option–G to release its mouse grab, then select the Mac application.
Quit the VM if host input still does not recover.

For diagnosis, `TRYOMARCHY_INPUT_TRACE=1` logs foreground PID, local activation,
window-key state and capture decisions, without recording key contents.
`TRYOMARCHY_INPUT_OBSERVE_ONLY=1` makes the global tap pass every event through;
it observes the capture decision without forwarding or suppressing the event.
These variables apply to the QEMU process and are unset during normal use.

## Validation

`make test` checksums the Cocoa patch and compiles the ISO swap helper. The upstream QEMU pin is unchanged. Review
`iso_swap_patch_sha256` in `macos/build-qemu-gpu-runtime.sh` against
`macos/patches/qemu-cocoa-iso-section-grave-swap.patch`. `make runtime`
applies the patch after the existing Cocoa series.
The native focus regression compiles the capture and deactivation methods from
the full-grab patch against controlled application/window state, without
installing a global event tap or generating keyboard events.
