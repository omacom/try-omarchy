# Multiple displays

In immersive mode, every display connected to the Mac becomes one of Omarchy's outputs, arranged as macOS arranges them. This is how the app, QEMU and the guest package share that work.

```text
Mac displays (System Settings)          QEMU                           Omarchy
  built-in 1512x982 @2x, main  ──►  head 0, window on the panel   ──►  Virtual-1 at 250x1080
  external 1920x1080 @1x       ──►  head 1, window on the display ──►  Virtual-2 at 0x0
                                     one keyboard, one pointer
```

## One head per display

The launcher asks `omarchy-vm-helper --host-display-layout` for the arrangement: one `Virtual-N:XxY` token per display, the Mac's main display first, so Omarchy's first output, its boot messages and its first-boot setup are where macOS keeps its menu bar. The position is where the display sits from the top-left corner of the rectangle enclosing every display, in points. A head's scale follows its display's backing scale, so the Mac's points are Hyprland's logical pixels and the arrangement carries over as it is. With **Camera notch** off, full screen on the built-in panel stays below the camera strip, and the panel counts without it. `run-qemu-gpu.sh` starts `virtio-gpu-gl-pci` with one head per display, sends the line to the guest as `tryomarchy.display_layout` in the `tryomarchy.host` credential, and to QEMU as `TRYOMARCHY_DISPLAY_LAYOUT`. `omarchy-vm-helper --host-display-panel` names the built-in panel's output, sent as `tryomarchy.display_panel`, so the [camera housing](camera-notch.md) stays with the panel wherever it is in the order.

QEMU's Cocoa display (`qemu-cocoa-multi-display.patch`) keeps one `QemuCocoaHead` per head: its console, listener, surface, window and GL scanout. Head N-1 shows output Virtual-N in a window on the display at that place, found by its offset from the Mac's main display, which the helper lists first. The windows enter full screen one after another, since AppKit runs one transition at a time; the first request goes out as soon as the window exists, whether or not the app is active yet, and one that produced no transition, say at a locked Mac or one AppKit drops while starting, is repeated once the app is active. **View > Enter Full Screen** and **Exit Full Screen** act on every window together.

In the guest, `host-config` writes the arrangement to `/run/try-omarchy/display-layout`, and `omarchy-native-display-sync` gives each connected output its own rule, with its mode from the EDID and its position from that file. An output the person configured themselves in `monitors.lua` is left to them, and a chosen scale leaves placement to Hyprland, since the logical sizes no longer match the Mac's points.

A window, the launcher's **All Displays** setting off, one display, or macOS with **Displays have separate Spaces** off keep one head, as before.

## One keyboard, one pointer

The input devices stay as they were: one keyboard, one absolute tablet, one pinch touchpad. Keys go to the first head's view, which keeps the keyboard state for all of them. The pointer is placed on the guest desktop from where it falls on its window's output, in screen coordinates, so a drag that leaves a window or crosses to the next display keeps its button. Gestures and wheels go to the window under them. In full screen the pointer, a pinch and a two-finger scroll belong to the window they are over, key or not, so hovering, the first click and a gesture on another display reach the guest without a click to choose the window first; the keyboard moving between the VM's windows does not let go of the pointer's buttons, and a change of the Mac's input source reaches Omarchy whichever of its windows has the keyboard.

## The desktop joins the other displays

Linux sizes its console to the smallest connected display when it probes the GPU and keeps that size. If the second head were connected from the start, first-boot setup would be drawn in a corner of the main display. So the first head starts alone, at the main display's size (`xres`/`yres` from `omarchy-vm-helper --host-display-pixels`), and the other heads join once a guest client creates a virgl rendering context, which the console and the firmware never do and a compositor does: virtio-gpu raises `dpy_gl_context_created` for the first head's console, the Cocoa display sends the other heads their sizes, and the guest sees them plugged in. A guest reset takes them away again until the next compositor, so a reboot's console keeps the main display's size too.

## Limits

- The heads are fixed at launch. A display connected later needs the VM restarted; a display disconnected while the VM runs leaves its output in Omarchy until then.
- Full screen on every display needs macOS's **Displays have separate Spaces** (on by default). With it off, Omarchy uses one display.
- The pointer follows the Mac's arrangement. A scale chosen in `monitors.lua` leaves placement to Hyprland, and a monitor rule written there can move an output; on a display Omarchy places differently from the Mac, the pointer lands elsewhere than the Mac's cursor.
- The camera housing is described for the built-in panel's output only.
- Up to four displays.
