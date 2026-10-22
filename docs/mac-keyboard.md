# Mac keyboard geometry

Try Omarchy maps the host Mac keyboard class (ANSI / ISO / JIS) into the
guest. That corrects the ISO Section / extra-ISO key inversion for every
layout. For xkeyboard-config Mac vendor layouts (`ch de dk fi fr gb is it
latam nl no pt se us` with an empty variant) it also selects Macintosh
legends, except for Italian: XKB's Macintosh Italian is the QZERTY
typewriter layout of keyboards Apple no longer sells, so the guest uses the
QWERTY Italian layout of current Apple keyboards instead.

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

For Italian, the package ships `/etc/xkb/symbols/macintosh_vndr/it`, which
libxkbcommon reads before xkeyboard-config's copy. It is the standard
`it(basic)` layout, so an Apple model with Italian types QWERTY in any
position of a multi-layout list, and `kb_variant` stays what Omarchy set (its
keyboard layout picker reads it back). `kb_variant = "mac"` still selects
QZERTY.

**Remove any local `frmac` (or similar) TLDE/LSGT symbol swap**, or the ISO
keys invert again on top of the Cocoa swap.

Omarchy's setup form asks for the keyboard layout and input method; it does
not preselect Japanese on JIS Macs. Native 英数/かな mode keys are described
in [Japanese input](japanese-input.md).

## Korean Caps Lock

On a Mac with a Korean input source and **Use Caps Lock to switch input sources** on, Caps Lock is the 한/영 key. A short press switches between Korean and English, and a long press locks capitals. With the VM focused, the same keys do the same in the guest.

### Behaviour

- `omarchy-vm-helper --host-caps-lock-input` reports `hangul` when an enabled input source starts with `com.apple.inputmethod.Korean`. The launcher then exports `TRYOMARCHY_CAPS_LOCK=hangul` to QEMU, except on JIS Macs, which keep かな and 英数. Without it, nothing changes.
- The guest's input method follows the Mac input source with absolute keys: `KEY_HENKAN` to Korean and `KEY_MUHENKAN` to direct input. Omarchy's Fcitx profile already activates the input method on `Henkan` and deactivates it on `Muhenkan`, and XKB maps both keys on every layout through `inet(evdev)`, so the guest needs no change. Cocoa sends the Mac's side when macOS reports that the selected input source changed while the VM window is key, at the next key event after the window becomes key, and again before a space, return, tab, escape or arrow key at most every two seconds. The Mac's input source is the reference: switching only the guest, with Super+I or a lone Shift, is undone by the next repeat. Fcitx passes a redundant `Henkan` on to the engine, so repeats wait for a key that ends a Hangul syllable anyway.
- Locking capitals moves the Mac to ABC, and unlocking can move it back. The guest follows both.
- The guest's Caps Lock follows the Mac's Caps Lock lock state (IOHIDSystem, the state the keyboard light shows). It is compared with the Caps Lock light the guest reports through virtio-input, not with a count of the presses QEMU sent. The comparison happens at key and modifier events, after the press is decided, and the Caps Lock press reaches the guest before the key that needed it. Events from the Caps Lock key itself never change it.
- While the key is down, macOS locks Caps Lock provisionally. A press is decided when the lock state reads unlocked again, when macOS confirms a long press, or after one second. Letters typed while the key is down stay lowercase.
- The full-grab event tap handles the Caps Lock events and passes them on, and `-sendEvent:` hands them to AppKit. Each event is handled once in QEMU. Consuming them kept macOS from locking capitals with the VM focused.

### Why it works this way

Apple does not document how macOS reports the 한/영 switch, so the design follows what macOS 26 was measured to do:

- A short press arrives as one `flagsChanged` event with `keyCode` 0xff, without a `kVK_CapsLock` event for the switch. Only an HID event tap sees it; AppKit drops it before `-sendEvent:`. QEMU's Cocoa display forwarded Caps Lock only as a flag change, so the guest saw nothing.
- During a press, the Caps Lock flag of individual events, `+[NSEvent modifierFlags]` and the IOHIDSystem lock state all flicker. Syncing from any of them typed capitals in the guest.
- The input source read while handling a Caps Lock event can be the value before or after the switch, so it is read at the change notification and at ordinary key events.
- A toggle cannot keep the guest in step. Fcitx keeps an input method state per window, a lone Shift also toggles it, and a key sent before Fcitx runs at boot is lost. Absolute keys, repeated, recover from all three.
- A long press is confirmed by a 0xff event that carries the Caps Lock flag while the lock state is set.

The tests replay event sequences recorded on a Korean Mac.

### Known limits

- If the guest's input method changes another way, such as Super+I, a lone Shift or a new window, it follows the Mac again at the next space, return, tab, escape or arrow key after two seconds.
- The 0xff event reaches QEMU only through the full-grab event tap, which needs the Accessibility permission. Without it, Caps Lock behaves as before.
- The keys work only when the guest's Fcitx profile activates on `Henkan` and deactivates on `Muhenkan`. Omarchy writes these for profiles it creates fresh since October 2026; it leaves the hotkeys of older or edited profiles alone, where Fcitx's defaults (`Hangul_Hanja`, `Hangul_Romaja`) or the user's own keys may remain. Then the guest's input method does not follow the Mac, and nothing is inverted.
- `Henkan` and `Muhenkan` reach the focused application when Fcitx does not handle them, for example in a window without text input, or a redundant `Henkan` reaching the engine. Whether an application reacts to them was not checked. With Mozc in the same group, `Henkan` is also Mozc's conversion key.

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
