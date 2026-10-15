# Japanese keyboard and input

Japanese input runs inside Omarchy through Fcitx5 and Mozc. The factory includes
Mozc, its configuration tools, GTK/Qt integration, and Noto CJK fonts. macOS IME
composition is not forwarded into Linux; use the guest's input method while the
VM is focused.

## New guests

On a JIS Mac, owner setup preselects **Japanese**. You can choose another layout;
that explicit choice is preserved. The host geometry selects `applealu_jis`, and
the selected layout determines the punctuation and direct-input keyboard. With
the default Japanese layout, `apple:jp_oadg109a` supplies backslash on ろ and
underscore on Shift+ろ, while ¥ remains a distinct yen sign. Existing keyboard
options are preserved; custom layouts, variants, keymaps, and explicit Apple
JIS backslash options are left alone.

Before Fcitx first starts, an untouched factory profile on a JIS Mac puts Mozc
before Chewing. The same Japanese default applies when the guest's initial
language is Japanese, including on ANSI/ISO keyboards. A Japanese language does
not change an ANSI/ISO keyboard into a JIS layout. Other guests keep their
existing US/Chewing order, with Mozc also available.

For JIS keyboards:

- **かな** activates the input method, which defaults to Mozc.
- **英数** deactivates it and returns to direct input.
- Repeated presses request the same state; they do not toggle it.
- Type romaji, use **Space** to convert, and **Enter** to commit. Mozc also offers
  kana input, katakana conversion, dictionaries, and other preferences through
  its configuration tools.

QEMU's pinned keymap delivers かな as Linux `KEY_HANGEUL` and 英数 as
`KEY_HANJA`. With the Mac JIS model their XKB symbols are `Hangul` and
`Hangul_Hanja`. The first-session Fcitx config binds these to activation and
deactivation and removes `Hangul` from the toggle keys. Fcitx handles the
switches in its key-event stream, avoiding subprocess races with the next
character. These keys activate the currently selected engine if you later
choose another input method.

On ANSI/ISO keyboards, use **Ctrl+Space** to toggle the selected input method.
Open **Fcitx 5 Configuration**, or run `fcitx5-configtool`, to select Mozc
and edit the input-method order, shortcuts, or Mozc's preferences. Holding Ctrl
and pressing Space again enumerates the configured methods.

The initializer only changes an exact factory profile and only creates JIS
hotkeys if no Fcitx config exists. It preserves personal profiles and shortcuts.
The optional service preflight cannot prevent Fcitx from starting if seeding
fails.

## Existing guests

Physical ANSI/ISO/JIS keyboard support is installed automatically at boot,
including when migrations are skipped. It does not require Mozc. See
[Mac keyboard](mac-keyboard.md#existing-vms).

Choose **Update and Launch → Japanese input** to add Japanese composition.
When Mozc is missing, the approved migration runs
`pacman -Syu --needed --noconfirm` with Mozc as the installation target, using
the guest's existing package repositories and signature policy. This refreshes
repository data and updates supported Linux packages, avoiding stale-download
failures. The command explicitly holds the project's kernel, headers, runtime,
and validated Hyprland stack, in addition to the guest's existing holds. The
migration waits briefly for networking and bounds the package operation to five
minutes. Existing Mozc installations are kept without a package update.

After installation, it migrates recognized stock Fcitx profiles, including
profiles saved after first login. Mozc becomes the first conversion engine on
JIS Macs or for a Japanese guest language; other guests gain Mozc after Chewing.
Korean group selection and the direct-input keyboard are preserved. Native
英数/かな shortcuts are seeded only when global Fcitx config is missing.
Personal profiles, shortcuts, and unsafe paths are preserved and reported.

Skipping performs no package installation or Japanese-profile edits. Interrupted
file changes are recovered before a retry. Package installation is a separate
pacman transaction: installed packages remain if a later file repair fails.
An active package-manager lock is preserved. Download or verification failures
are reported and normal VM boot continues; check connectivity, then retry **Update and Launch**.
Guest language, kernel, and paired boot files are retained.

For preserved personal settings, use the configuration tool to finish setup:

```sh
fcitx5-configtool
```

Add Mozc and the keyboard layout matching your physical keyboard. Keep the
keyboard item first and put Mozc before other conversion engines if Japanese
should be the default. For JIS punctuation, select the Japanese layout and set
`kb_model = "applealu_jis"` in your Hyprland input overrides, and append
`apple:jp_oadg109a` to `kb_options` for backslash/underscore on ろ, as described in
[Mac keyboard](mac-keyboard.md).

For JIS keys, configure the Fcitx global options:

- **Activate Input Method:** `Hangul` (press かな).
- **Deactivate Input Method:** `Hangul_Hanja` (press 英数).
- **Toggle Input Method:** keep Ctrl+Space; remove `Hangul`.
- Enable **Consume redundant Activate/Deactivate key** in the advanced options.

Restart the input method or log out and back in. If Chromium has no composition,
check that `~/.config/chromium-flags.conf` includes `--enable-wayland-ime` alongside
its existing flags. Native GTK4/Qt6 applications use Wayland text-input-v3; do not
force global `GTK_IM_MODULE` or `QT_IM_MODULE` overrides onto them. XWayland
applications still require `XMODIFIERS=@im=fcitx`, supplied by the factory.

## Verification

Run `make test` and `guest/test --source <pinned Omarchy checkout>`. These cover
JIS setup selection, explicit owner choices, first-session engine order, Korean
group preservation, native
hotkey configuration, preservation of user edits, locale capability handling,
and strict source/backport/package metadata.

For runtime verification, use a disposable guest. The QMP `input-send-event`
command can send `lang1` and `lang2`, which reach virtio-keyboard as Linux 122 and
123, matching the pinned Cocoa JIS keymap. This checks the real guest keyboard,
compositor, Fcitx, and application path without a physical Japanese keyboard.
It does not test physical Mac hardware or Cocoa event delivery.

Test Chromium's Wayland textarea, GTK4 and Qt6 entries, and a native Wayland terminal:
activate Japanese, type `nihongo`, convert to 日本語, commit, deactivate, and type
`abc`. Repeat each mode key to verify idempotence and type immediately after
英数 to check ordering. Check a candidate popup and capture it with guest `grim`;
QEMU OpenGL screendumps can be black. Confirm JIS `@`, `¥`, `ろ`/backslash,
Shift+ろ/underscore, and Shift+2/quote separately. Finally test real 英数/かな
presses on a physical JIS Mac and confirm the same behavior.
