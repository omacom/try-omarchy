# Omarchy on a Mac

Omarchy runs as it does on any computer. Try Omarchy connects it to your Mac in the following ways.

## Keyboard and language

- **Command is Super** whenever the Omarchy window is focused. For shortcuts that macOS would take first, grant Accessibility.
- **Mac layouts work as printed.** That covers ANSI, ISO and JIS keyboards. On JIS, **かな** and **英数** turn the input method on and off. On a Mac with a Korean, Chinese or Japanese input source, Omarchy's input method follows the Mac's: switching with **Caps Lock** (한/영 on Korean Macs) or 🌐 switches Omarchy too. Hold Caps Lock for capitals. Control–Space stays with Omarchy. This needs Accessibility.
- **The language comes from the Mac on first boot:** English, Chinese, Korean or Japanese. Other languages fall back to English. Later, change it inside Omarchy. Omarchy's own menus are in English only.

## Clipboard, audio and camera

- **Copy and paste work in both directions,** for text and images.
- **Audio:** Omarchy's sound controls list the Mac's speakers and microphones, plus **Mac System Default**, which follows whatever the Mac uses. Switching takes effect immediately.
- **Camera:** the Mac's camera appears in Omarchy as **Mac Camera**. Browsers and video call apps can use it like any webcam.

## Display, power and time

- **The notch:** in full screen on a MacBook with a notch, Omarchy uses the whole screen, and its bar sits beside the notch like the macOS menu bar. Turn off **Camera notch** in the launcher to keep Omarchy below the notch.
- **More displays:** in full screen, Omarchy uses every display connected to the Mac, each as its own Hyprland monitor, arranged as in System Settings. Displays are counted when Omarchy starts, so plug one in or out, then restart Omarchy. The first-boot setup and the boot messages show on the Mac's main display, the one with the menu bar in System Settings; until the desktop starts, the other displays say "Display output is not active", QEMU's sign for an output the guest has not turned on yet. macOS's **Displays have separate Spaces** has to be on, which it is by default. **View > Exit Full Screen** leaves full screen on every display at once. Turn off **All Displays** in the launcher to stay on one display.
- **Trackpad:** pinch to zoom works, and a two-finger swipe goes back or forward in browsers. After a flick, scrolling keeps gliding in apps that support it, as on a Linux laptop.
- **Battery:** the Mac's battery and charging state show in Omarchy's bar. Power profiles change nothing, because macOS manages power.
- **Time:** Omarchy follows the Mac's time zone unless you choose another one. Its clock catches up after the Mac sleeps.
- **Memory:** memory Omarchy isn't using goes back to macOS.

## Different from real hardware

- **No suspend.** Omarchy hides Suspend and Hibernate. When the Mac sleeps, the VM pauses with it.
- **Video decoding uses the CPU,** so high-resolution playback can stutter.
- **No Vulkan.** Apps that need it, such as Zed and Steam games, install but don't run.
- **Some apps draw without the GPU.** Ghostty and Kitty use software rendering. They work, just with less acceleration.
- **Nested virtualization is off.**
