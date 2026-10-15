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

## Validation

`make test` checksums the Cocoa patch and compiles the ISO swap helper. The upstream QEMU pin is unchanged. Review
`iso_swap_patch_sha256` in `macos/build-qemu-gpu-runtime.sh` against
`macos/patches/qemu-cocoa-iso-section-grave-swap.patch`. `make runtime`
applies the patch after the existing Cocoa series.
