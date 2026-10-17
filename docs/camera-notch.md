# Camera notch

On a MacBook with a camera notch, Try Omarchy's full screen uses the whole
panel, the strip beside the housing included, and Omarchy's own bar sits in
that strip like the macOS menu bar does. Nothing in Omarchy is patched: the
guest describes the Mac's housing in the file Omarchy already reads for
notched laptops, and Omarchy's bar keeps out of it.

```text
Mac (QEMU Cocoa)                        guest (try-omarchy package)
full screen covers the whole panel  ->  Hyprland output at the panel's size
helper measures the housing         ->  /run/try-omarchy/display-cutouts.json
  (tryomarchy.display_cutouts)          <- /usr/share/omarchy-platform/display-cutouts.json
                                        Omarchy's bar: as tall as the housing,
                                        its center beside the right section
```

## The Mac side

AppKit puts a full-screen window below the housing and leaves the strip to the
menu bar: the window server's `Menubar` window (level 24) paints it black,
even when the menu bar is hidden. `macos/patches/qemu-cocoa-notch.patch`
changes that:

- AppKit asks its full-screen content controller whether to reserve the
  strip for the menu bar. On a screen with a housing the answer becomes no,
  so AppKit itself gives the window the whole display, and gives it again
  after a Space switch, a display mode change or a lock. This is the
  patch's one private piece,
  `-[_NSFullScreenContentController reservesSpaceForMenuBarInFullScreen]`,
  looked up at start and checked against its signature; without it full
  screen stays below the housing, as before. Public AppKit has no
  equivalent: a frame the app sets itself (a window subclass widening
  AppKit's tile) holds only until the window server tiles the Space again,
  which every Space switch does. UTM and OmacVM hook AppKit's full-screen
  machinery for the same reason, more widely.
- While the window covers the strip and has the keyboard, it sits at
  `NSStatusWindowLevel`, just above the black strip. An alert, a menu,
  another app taking the keyboard, and the way out of full screen put it back
  at the normal level, so nothing of macOS ends up behind it.
- With **Immersive** off, macOS keeps its auto-hidden menu bar and Dock in
  full screen. They slide out under the raised window, so the window steps
  down while the pointer is at the top edge or the Dock's edge and comes back
  once the pointer moves on past them. With macOS's "Always show the menu
  bar in full screen" on, non-immersive full screen stays below the housing,
  where that menu bar lives.
- The guest is offered the whole display's backing size, so the Hyprland
  output follows the window (see [guest display synchronization](architecture.md#guest-display-synchronization)).

Screens without a housing report no safe-area inset and keep QEMU's
behaviour: external displays, Macs without a notch, and the built-in panel's
modes below the camera (the 16:10 ones, such as 1512 x 945 on a 14-inch
MacBook Pro). QEMU's log says when full screen covers the strip.

## The launcher setting

On a Mac with a notch the launcher shows **Camera notch**, on by default. Off,
full screen stays below the notch like other Mac apps and the guest gets no
cutouts, so Omarchy's bar is its usual self: the launcher passes
`OMARCHY_QEMU_GPU_NOTCH=0`, and `run-qemu-gpu.sh` leaves out
`tryomarchy.display_cutouts` and gives QEMU `TRYOMARCHY_NOTCH=0`. It applies
from the next start, like **Immersive**. Macs without a notch never show it.

## Telling the guest

`omarchy-vm-helper --host-display-cutouts` measures the housing on the
built-in panel (`NSScreen.safeAreaInsets` at the backing scale) and scales it
to every mode of the panel that reaches its top edge, in pixels:

```text
3600x2338:77,3024x1964:64,2704x1756:58,2294x1490:49,2048x1330:44
```

The housing is one physical size and each such mode's pixels span the whole
panel, so one measurement describes every resolution the user can pick. When
it can't measure (the lid closed, a mode below the camera) it repeats its last
measurement. The launcher passes the line as `tryomarchy.display_cutouts` in
the `tryomarchy.host` credential; a Mac without a notch passes nothing.

In the guest, `try-omarchy-host-config.service` writes it as Omarchy's
cutout schema to `/run/try-omarchy/display-cutouts.json`, one entry per mode
for QEMU's `Virtual-1` output:

```json
{ "panels": [
  {"connector": "Virtual-1", "width": 3024, "height": 1964, "top": 64}
] }
```

An existing VM gets this package from the app at its next boot, after the
old `host-config` has already run; the upgrade runs the new one again, before
the desktop starts, so that boot has the cutouts too.

The package links `/usr/share/omarchy-platform/display-cutouts.json`, the
fixed path Omarchy's bar reads, to that file. Plain `aarch64` registers no
platform package, so this one link is the package's only file in Omarchy's
platform root.

## What Omarchy does with it

Omarchy's bar matches a screen whose connector starts with `connector` and
whose mode is `width` x `height` (within 4 pixels), and on it:

- grows to at least the housing's height, so tiled and maximized windows
  start below the housing;
- moves its center section beside the right one, so the clock and the other
  center items are not under the camera;
- tells notifications and popups its real height, so they open below it.

The entry matches only while the VM fills the panel. A window, normal full
screen below the housing and external displays have other sizes, and keep
Omarchy's usual bar. Changing the Mac's resolution changes the mode to
another entry. The bar reads the file at the shell's start and whenever it
changes.

### Keeping the bar's mode current

Omarchy's bar takes a screen's mode from Quickshell's Hyprland monitor
objects, which Quickshell reads again only when an output comes or goes, on a
config reload, or when one of Omarchy's overlays (a menu, the OSD) opens. On a
MacBook the mode never changes under the bar, but a VM's does, every time the
window enters or leaves full screen, and the mode `omarchy-native-display-sync`
sets brings none of those events. Left alone, the bar keeps the previous
mode's layout: in a window, the clock beside the right section; back in full
screen, a normal bar with the clock under the camera.

So `omarchy-native-display-sync` passes each mode it applies to
`/usr/lib/try-omarchy/notch-refresh`. When the mode enters, leaves or moves
between the cutouts' modes, it creates a headless output and removes it at
once, which makes Quickshell read every monitor again. A window being resized
and a Mac without a notch never trigger it. The lasting fix belongs in
Omarchy's bar: refresh Hyprland's monitors when a bar's screen changes size,
as its overlays already do for scale changes. Tested in the VM, that fix alone
keeps the bar right on every change, and `notch-refresh` can then go.

## Limits

- Omarchy knows the housing's height, not where it is across the panel. A
  left or right section crowded enough to reach the middle of the bar (many
  workspaces, many tray icons) can still run under the housing. The fix
  belongs in Omarchy's cutout schema (optional left and right edges), where
  it would serve bare-metal MacBooks too.
- Real full screen (`Super + F`) and the hidden bar (`Super + Shift + Space`)
  give the strip to the window or the wallpaper, behind the camera, as on a
  MacBook running Omarchy natively.
- With **Immersive** off, the window steps down under macOS's menu bar and
  Dock while they are out. The menu bar's black strip then covers Omarchy's
  bar until the pointer moves on; only a private SkyLight call could make
  that strip see-through.
- Omarchy reads cutouts from about October 2026 on (`omarchy-dev` built from
  `quattro`). An older guest shows its usual bar in the strip, partly under
  the housing, until `omarchy update`.
- Whether a virtual platform may own a file in Omarchy's platform root is an
  open question for upstream (see the [shell plan](shell-plan.md)).
