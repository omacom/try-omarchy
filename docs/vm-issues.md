# Known VM issues and backlog

Issues found on 2026-10-16 while auditing the thin-shell guest: stock Omarchy
features that misbehave in the VM, behaviour the earlier patched guest had and
the shell dropped, and host-side problems that
[OmacVM](https://github.com/gillesgoetsch/OmacVM) (MIT, a similar QEMU/HVF/VirGL
Mac app) found and fixed. Most entries come from reading code, not from a
running guest; each says how sure it is. Update an entry's status when it is
fixed or disproved, and record runtime checks in
[runtime validation](runtime-validation.md).

Status: **fixed** (in the package or app), **open**, **verify** (plausible,
needs a check in a running guest first), **limit** (a design constraint).

## Check first

| Issue | Evidence | Status |
| --- | --- | --- |
| Empty bar, menus, OSD and notifications on Qt 6.12. Qt 6.12 adds a QtQuick `Color` singleton that shadows the shell's `qs.Commons` `Color` | Omarchy's ARM mirror serves `qt6-declarative 6.12.0-1`. The stable `omarchy 4.0.4` package still has 52 shell files with a bare `Color`, but the factory installs `omarchy-dev`, whose edge build `4.0.0.r7026.g51bfd1d` uses `Commons.Color` throughout (no bare uses). OmacVM's workaround for stable: `src/guest/shell-colors.py` (TS #35) | not an issue on `omarchy-dev`: no `Color` errors in the session log on the new factory |
| Suspend leaves the VM looking frozen: no wake source | Upstream shows Suspend unless `/etc/systemd/sleep.conf.d/omarchy-sleep-disabled.conf` exists (`bin/omarchy-sleep-disabled`) | fixed: the package ships that switch; verified logind `CanSuspend` "no" |
| NTP may be off. The old guest enabled `systemd-timesyncd`; nothing in the factory, package or upstream does now | `guest-clock-recover` only try-restarts it; host-timezone.md assumes it is enabled | fixed: the package enables it once; verified enabled and synchronized |

## Graphics

| Issue | Evidence | Status |
| --- | --- | --- |
| Ghostty exits at start: needs desktop OpenGL 4.3 | [Ghostty](ghostty.md) | fixed and verified: software-renderer wrapper |
| Ghostty's D-Bus-activated service fails under systemd 262: "lacks handler for reload signal USR2" | Stock `/usr/bin/ghostty` fails the same way; affects any Omarchy machine with systemd 262 | worked around with `Type=dbus` in the package drop-in; report upstream (Ghostty / omarchy-pkgs) |
| A Ghostty entry with a generic icon was listed before Ghostty was installed, and did nothing | Our wrapper's desktop entry has `TryExec=/usr/bin/ghostty`, but Omarchy's `shell/services/hidden-entries.sh` checks only `Hidden`, `NoDisplay`, `OnlyShowIn` and `NotShowIn` | fixed: pacman hooks link the entry only while Ghostty is installed; report upstream (`TryExec` in the hidden-entry scan) |
| After pairing Touch ID, 1Password Touch ID could not be enabled and the time zone picker lost its Same as macOS preselection | The broker set `/var/lib/try-omarchy` to `0700`, so the desktop user could neither check for the pairing nor read `timezone.json` (found by a Codex review) | fixed: the broker keeps the root-owned directory `0755` (the pairing file stays `0600`), and `tmpfiles.d` repairs VMs paired earlier |
| Kitty draws nothing on VirGL although a GL 3.3 core context succeeds | The old guest wrapped it (#173) when VirGL ran on ANGLE (desktop GL 2.1). An EGL probe on 2026-10-16: VirGL now gives desktop OpenGL 4.1 core and compatibility (GLSL 4.10) and ES 3.0; a 3.3 core request succeeds, 4.3 fails | fixed and verified: Kitty 0.49.2 on VirGL opens an empty, transparent window (only Hyprland's border); the package's `kitty` wrapper runs it on llvmpipe and its text renders |
| 1Password may draw blank or crash: Electron EGL context | The old guest ran it with software GL and `--disable-gpu`; stock edge `1password` 8.12.40 has no wrapper | not an issue: the Welcome window renders on the GPU (seen on the Mac's screen; in-guest `grim` captures of it are black) |
| 1Password Quick Access shortcut (Ctrl+Shift+Space) gone | Old `1password-arm64-installer.patch`; upstream binds only Super+Shift+/ | open |
| Vulkan-only apps install, then fail: Zed, Steam and games | No Vulkan driver in the guest; edge aarch64 carries `zed`, `steam`, `omarchy-steam-fex` | open; real fix is Venus (below) |
| Screen recording: `gpu-screen-recorder` refuses VirGL and the `wf-recorder` fallback is missing | `gpu-screen-recorder` exits: no h264/hevc/av1 encoder (no VA-API) | fixed and verified: Omarchy's script recorded a correct 3024×1900 H.264 file through `wf-recorder` |
| Lost GPU context leaves a permanent black desktop or black Chrome | VirGL treats Apple 4.1 core refusals (GLSL < 3.30, core-feature extension lines, 32 samplers, framebuffers without attachments) as fatal. OmacVM ADR 0019 and its gpu-robust patches; our `virgl-native-opengl.patch` has none | open: the next graphics project. OmacVM forked this runtime and carries about 60 interdependent VirGL patches, each proven with dEQP and WebGL runs; the robustness subset (ADR 0019 GLSL and limits, shader-failure containment, context-loss reporting) needs those runs here before it ships |
| Night light may do nothing on virtio-gpu (no colour transform) | Hyprland logs "connector Virtual-1 crtc doesn't support CTM"; a guest capture at 2500 K is unchanged (captures miss display-level transforms) | likely broken; confirm by eye, then hide the rows or ask upstream for a fallback |
| Browser screen sharing over the portal on VirGL buffers is untested | | verify |
| Screenshot freeze and recording stall the VM and audio: hyprpicker redraws every frame; full-screen uploads through the main loop | OmacVM TS #32 (rebuilt hyprpicker, `virgl-transfer-upload-pbo.patch`) | verify |
| OpenGL above 4.1 on the GPU | Apple OpenGL is frozen at 4.1. Venus + KosmicKrisp (macOS 26) gives Vulkan; Zink on it gives only GL 2.1 today (OmacVM ADR 0013, 0035) | limit; Venus is the next graphics project |
| Light GL throughput limited by 1 ms fence polling | OmacVM async fences: glmark2 1,000–1,500 → 2,800–3,700 (ADR 0011, 0017) | open; performance |

## Audio (host side)

| Issue | Evidence | Status |
| --- | --- | --- |
| VM freezes when the microphone starts: QEMU opens SDL capture on a vCPU thread holding the BQL; CoreAudio can block for minutes | Our `qemu-sdl-audio-device-selection.patch` defers capture to that path. OmacVM: `qemu-sdl-audio-capture-thread.patch`, `-playback-thread.patch` (TS #22, #26) | fixed: both adapted ([audio continuity](audio-continuity.md#stalls-slow-devices-and-mac-sleep)); a wedged device not reproduced here |
| Crackling under GPU or CPU load | No main-loop QoS; RTKit's canary demotes PipeWire after a QEMU stall, which is what pausing the VM for Mac sleep looks like. OmacVM: `qemu-darwin-main-loop-qos.patch`, `qemu-hda-no-catch-up.patch`, `rtkit-no-canary.conf`; 365 → 50 breaks per 10 min (ADR 0036) | fixed: all three adapted; OmacVM's measurements, not repeated here |
| Video audio leads the picture | QEMU buffers (110–150 ms in OmacVM's build) and Mac output latency are unknown to PipeWire. OmacVM sets a sink latency offset from the host (TS #28) | open, designed: add each Mac output's CoreAudio latency (device, safety offset, stream, buffer) plus QEMU's share to the audio bridge's catalog; the guest bridge sets it as the HDA output port's latency offset when the route changes. Not built: QEMU's share is an estimate, and a wrong offset makes sync worse, so it needs a lip-sync measurement first |
| WirePlumber can stall on a V4L2 node that is not ready yet | OmacVM TS #29 | not seen: WirePlumber responsive, no restarts, `Mac Camera` listed (one boot) |

## Mac integration, displays and power

| Issue | Evidence | Status |
| --- | --- | --- |
| VM slows to 2–20 % while hidden, on another Space or with the Mac locked (App Nap) | No App Nap handling in QEMU or the app. OmacVM `omacvm-cocoa-no-app-nap.patch` (TS #31) | fixed: `qemu-cocoa-no-app-nap.patch` ([performance](performance.md#app-nap)); the activity is held (QEMU's log) and the guest ran at full speed out of sight. A napped baseline from this build (`TRYOMARCHY_APP_NAP=1`) is not measured yet |
| Screensaver after 150 s and lock after 300 s while the user works in macOS; the screensaver costs CPU and the user unlocks on every return | `shell/plugins/services/idle/Service.qml` defaults | fixed: `idle-defaults` sets both to 0 in `~/.config/omarchy/shell.json` once, only while they are Omarchy's defaults; the Mac's lock protects the VM, and Omarchy's settings turn them back on |
| Firmware logo and `BdsDxe` lines, then boot and shutdown text, show in the VM window. The window appears when QEMU starts, before the firmware | The firmware is QEMU's prebuilt `edk2-aarch64-code.fd`; it has no runtime switch for its logo on ARM. Proposed: a cover in QEMU's Cocoa window until the first GL scanout (Hyprland), revealed at the kernel on a VM's first boot for the setup form, with a timeout, and covering again on shutdown | open; deferred by choice |
| Instant resume and guest hibernation | QEMU: "virgl is not yet migratable" (OmacVM ADR 0037) | limit |
| 120 Hz frame pacing: frames dropped or repeated | OmacVM ADR 0020, 0023 | verify |
| Power profiles show but change nothing; "Managed by macOS" presentation dropped | [Host battery](host-battery.md), [shell plan](shell-plan.md) | open: the power panel is Omarchy's QML, so a "Managed by macOS" state needs an upstream hook (a platform that reports no CPU frequency control); not patched |
| Battery panel may show Holding while charging (stock heuristic) | Holding when charging at ≤ 0.2 W or ≥ 8 h to full (`panels/power/Model.js`) | not seen: plugged in read charging 38 W, 1.1 h to full; on battery 8.9 W, 1.9 h left. A brief Holding right after plugging in (UPower's 10 s rate blackout) is possible |
| Battery percentage toggle hidden: `omarchy-hw-laptop` finds no lid | `menu.jsonc` `when` | fixed: the menu extension also shows it when a `BAT*` power supply exists |

## Menus and features

| Issue | Evidence | Status |
| --- | --- | --- |
| Setup → Direct Boot would bypass Limine and its snapshot menu | Guarded only by `! omarchy-hw-aarch64-apple` | fixed: hidden in the VM (row in the menu extension; menu not viewed) |
| Update → Firmware installs fwupd with nothing to update | No guard | fixed: hidden in the VM (row in the menu extension; menu not viewed) |
| GeForce NOW, Battle.net and Lutris rows offered on aarch64 | Lutris and Battle.net need `wine-staging` and `umu-launcher`, not in any aarch64 repository; GeForce NOW's installer is, as far as known, x86_64 only | fixed locally: hidden with `omarchy-hw-x86`, as Omarchy does for Minecraft and Heroic; worth the same guard upstream for every ARM machine |
| Menu extension rows that change one of Omarchy's rows lost its label, icon and action: Timezone showed as `update.timezone`, and the rows that only added a condition became empty | Omarchy's `normalizeItem` fills every field a row leaves out with a default before `mergeMenuSources` copies it over, although `docs/menu.md` says only declared fields are replaced | fixed: `menu-entries` writes Omarchy's complete row with our change, rebuilt from the installed Omarchy at each login, and repairs the rows earlier packages wrote; report upstream |
| Wi-Fi, Bluetooth and Trackpad restart rows do nothing | Harmless | fixed for Wi-Fi and Bluetooth (hidden in a VM). Trackpad kept: the VM has a virtual touchpad, and whether a restart affects it is unchecked |
| Notifications show over the screensaver | Old `notification-screen-privacy.patch`; no upstream equivalent | open; upstream (rarely visible now that the VM's idle screensaver is off by default) |
| US-International (dead keys) layout missing | Old `keyboard-us-acentos.patch` | open; upstream |
| Project wallpaper gone | Old skel wallpaper (#88) | fixed as an option: Tokyo Night's background switcher offers it beside Omarchy's own; the default background is unchanged |

## Suggested order

1. Guest package: the fixed rows above, then Kitty and 1Password once checked,
   and idle behaviour.
2. Host QEMU: microphone threading, audio QoS and RTKit, App Nap, A/V latency.
3. VirGL robustness from OmacVM's Apple-profile patches, then Venus.
