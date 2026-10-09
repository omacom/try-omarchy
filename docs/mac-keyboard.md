# Mac keyboard geometry

Try Omarchy maps the host Mac keyboard class (ANSI / ISO / JIS) into the
guest. That corrects the ISO Section / extra-ISO key inversion for every
layout. For xkeyboard-config Mac vendor layouts (`ch de dk fi fr gb is it
latam nl no pt se us` with an empty variant) it also selects Macintosh
legends.

## Host

`omarchy-vm-helper --host-keyboard-geometry` reports `ansi`, `iso`, or
`jis`. Unknown Carbon classes fail the launch. The launcher exports
`TRYOMARCHY_KEYBOARD` and appends `tryomarchy.keyboard=` on a normal boot
only. Cocoa swaps `KEY_GRAVE` and `KEY_102ND` only when that value is
`iso`. Recovery unsets the env. `--reset-storage-only` skips the probe.

## Guest

New users load `/usr/share/try-omarchy/apple-keyboard-input.lua`, which
sets only `kb_model = "applealu_" .. geometry`. Layout and variant stay
whatever Omarchy setup chose. A missing token is a no-op.

## Existing VMs

App upgrade applies the Cocoa ISO keycode swap immediately. That uninverts
`@#` / `<>` on ISO boards without changing `kb_model`. **Remove any local
`frmac` (or similar) TLDE/LSGT symbol swap first**, or those keys invert
again.

Macintosh legends still need `kb_model`. If a rebuilt guest image installed
`/usr/share/try-omarchy/apple-keyboard-input.lua`, add this to
`~/.config/hypr/input.lua`:

```lua
dofile("/usr/share/try-omarchy/apple-keyboard-input.lua")
```

Otherwise set the model yourself (do not `dofile` a missing path):

```lua
hl.config({
  input = {
    kb_model = "applealu_iso", -- or applealu_ansi / applealu_jis
  },
})
```

Save, then run `hyprctl reload` and `hyprctl configerrors`.

## Dedicated keys

In its default mode an Apple keyboard sends the dedicated keys as plain
key events with their own keycodes, not as F-keys, and the exact codes
differ by keyboard:

| Key | Built-in M1 Max | Magic Keyboard A1843 |
|---|---|---|
| Brightness down/up (F1/F2) | system-defined events, never reach QEMU's key path | 145 / 144 |
| Mission Control (F3) | 160 | 160 |
| Spotlight / Launchpad (F4) | 177 | 131 |
| Dictation / Siri (F5) | 176 | plain F5 |
| Do Not Disturb (F6) | 178 | plain F6 |

Built-in Mac keyboards send brightness as `NX_SYSDEFINED` system-defined
events that always stay with macOS; there is no keycode to route. Full
grab would otherwise swallow the rest, so the launcher passes the ones the
Keyboard setting leaves with macOS to QEMU as
`-display cocoa,host-keys=131:144:145:160:176:177:178`, and the Cocoa tap
hands those straight back to macOS. The setting is stored under
`keyboardRoutingPreferences` and published as `OMARCHY_QEMU_GPU_HOST_KEYS`
(comma-separated; unset means the defaults, empty means none). With "Use
F1, F2, etc. as standard function keys" on, the same caps arrive as F-keys
and always reach Omarchy.

Media transport keys arrive as `NX_SYSDEFINED` aux-control events, which
full grab's tap does not capture by default. When the Keyboard setting
sends them to Omarchy, the launcher publishes `OMARCHY_QEMU_GPU_MEDIA_KEYS=1`
and passes `media-keys=on` to QEMU, whose tap then also takes previous,
play/pause and next while the guest has the keyboard and sends them as
`audioprev`, `audioplay` and `audionext`; Omarchy's Hyprland bindings pass
them to `omarchy-shell media`. QEMU's held-key release lifts a media key
held when focus leaves. Volume, mute, brightness and backlight events
always pass through. Like the other rows, the setting applies on the next
launch.

## Validation

`make test` checksums the Cocoa patch, compiles the ISO swap helper, and
runs the guest Lua overlay. The upstream QEMU pin is unchanged. Review
`iso_swap_patch_sha256` in `macos/build-qemu-gpu-runtime.sh` against
`macos/patches/qemu-cocoa-iso-section-grave-swap.patch`. `make runtime`
applies the patch after the existing Cocoa series.
