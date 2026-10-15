# Japanese keyboard and input

Japanese, Chinese and Korean input run inside Omarchy through Fcitx5. macOS IME
composition is not forwarded into Linux; use the guest's input method while the
VM is focused.

Omarchy owns the input-method setup. Its first-boot form asks for the keyboard
layout. Choosing **Japanese** selects the `jp` layout and Mozc, and Omarchy
writes the Fcitx profile, hotkeys and CJK font preference
(`omarchy-input-method`). Change it later with **Super+I** (switch input method)
or **Setup > Input** in the Omarchy menu. Try Omarchy does not seed or migrate
Fcitx profiles.

The `try-omarchy` package adds only what the Mac and the VM need:

- **Packages:** it depends on `fcitx5-mozc`, `fcitx5-chewing`, `fcitx5-hangul`
  and `noto-fonts-cjk`, so the engines Omarchy offers stay installed.
- **Mac keyboard model:** the host geometry selects `applealu_jis` (or the ANSI
  or ISO model) in Hyprland; see [Mac keyboard](mac-keyboard.md).
- **英数 and かな:** QEMU delivers かな as Linux `KEY_HANGEUL` and 英数 as
  `KEY_HANJA`, whose XKB symbols are `Hangul` and `Hangul_Hanja`. On a Mac JIS
  keyboard, `try-omarchy-input-init` runs once per user before Fcitx starts
  (an `omarchy-fcitx5.service` drop-in). It adds `Hangul` to **Activate Input
  Method** and `Hangul_Hanja` to **Deactivate Input Method**, removes `Hangul`
  from the toggle keys, and turns on **Consume redundant Activate/Deactivate
  key**. Omarchy's other keys (変換, 無変換, 半角/全角, Super+I) stay as they
  are. A marker in `~/.local/state/try-omarchy/fcitx-jis-v1` keeps later edits.
- **Chromium:** `/etc/chromium-flags.conf` adds `--enable-wayland-ime`, which
  Chromium's launcher reads before `~/.config/chromium-flags.conf`.
- **XWayland:** `XMODIFIERS=@im=fcitx` comes from the package's
  `environment.d` file. Native GTK4 and Qt6 applications use Wayland
  text-input-v3; do not force `GTK_IM_MODULE` or `QT_IM_MODULE` onto them.

With JIS keys:

- **かな** turns the input method on (Mozc when it is the selected engine).
- **英数** turns it off and returns to direct input.
- Repeated presses request the same state; they do not toggle it.

## Verification

`make test-guest` covers the hotkey edit, its once-only marker and the
Chromium flag file.

For runtime verification, use a disposable guest. The QMP `input-send-event`
command can send `lang1` and `lang2`, which reach virtio-keyboard as Linux 122
and 123, matching the Cocoa JIS keymap. This checks the guest keyboard,
compositor, Fcitx and application path without a physical Japanese keyboard.

Test Chromium's Wayland text area, GTK4 and Qt6 entries, and a native Wayland
terminal: turn Japanese on, type `nihongo`, convert to 日本語, commit, turn it
off and type `abc`. Repeat each mode key to check it does not toggle, and type
right after 英数 to check ordering. Capture candidate popups with guest `grim`;
QEMU OpenGL screendumps can be black. Finally press the real 英数 and かな keys
on a physical JIS Mac.
