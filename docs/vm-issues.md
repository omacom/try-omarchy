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
| Empty bar, menus, OSD and notifications on Qt 6.12. Qt 6.12 adds a QtQuick `Color` singleton that shadows the shell's `qs.Commons` `Color` | Omarchy's ARM mirror serves `qt6-declarative 6.12.0-1`; edge `omarchy 4.0.4` (built 2026-10-10) has 52 shell files with a bare `Color` and an unqualified `qs.Commons` import. Upstream `quattro` fixed it (`docs/omarchy-shell.md`: use `Commons.Color`); edge has not shipped it. OmacVM's workaround: `src/guest/shell-colors.py` (TS #35) | verify; the shell fix is a new edge Omarchy build, not a patch |
| Suspend leaves the VM looking frozen: no wake source | Upstream shows Suspend unless `/etc/systemd/sleep.conf.d/omarchy-sleep-disabled.conf` exists (`bin/omarchy-sleep-disabled`) | fixed: the package ships that switch |
| NTP may be off. The old guest enabled `systemd-timesyncd`; nothing in the factory, package or upstream does now | `guest-clock-recover` only try-restarts it; host-timezone.md assumes it is enabled | fixed: the package enables it once |

## Graphics

| Issue | Evidence | Status |
| --- | --- | --- |
| Ghostty exits at start: needs desktop OpenGL 4.3 | [Ghostty](ghostty.md) | fixed: software-renderer wrapper |
| Kitty may exit at start: needs desktop OpenGL 3.1+, no GLES fallback | The old guest wrapped it with `LIBGL_ALWAYS_SOFTWARE=1` (#173) when VirGL ran on ANGLE (desktop GL 2.1). The native Apple GL path's desktop GL version is unrecorded | verify: `eglinfo -B` and launching Kitty |
| 1Password may draw blank or crash: Electron EGL context | The old guest ran it with software GL and `--disable-gpu`; stock edge `1password` has no wrapper | verify |
| 1Password Quick Access shortcut (Ctrl+Shift+Space) gone | Old `1password-arm64-installer.patch`; upstream binds only Super+Shift+/ | open |
| Vulkan-only apps install, then fail: Zed, Steam and games | No Vulkan driver in the guest; edge aarch64 carries `zed`, `steam`, `omarchy-steam-fex` | open; real fix is Venus (below) |
| Screen recording: `gpu-screen-recorder` refuses VirGL and the `wf-recorder` fallback is missing | `bin/omarchy-capture-screenrecording` header; upstream installs `wf-recorder` on Apple Silicon | fixed: package depends on `wf-recorder` |
| Lost GPU context leaves a permanent black desktop or black Chrome | VirGL treats Apple 4.1 core refusals (GLSL < 3.30, core-feature extension lines, 32 samplers, framebuffers without attachments) as fatal. OmacVM ADR 0019 and its gpu-robust patches; our `virgl-native-opengl.patch` has none | open; host VirGL patches |
| Night light may do nothing on virtio-gpu (no colour transform) | `bin/omarchy-toggle-nightlight` has no guard | verify: `hyprctl hyprsunset temperature 4000` |
| Browser screen sharing over the portal on VirGL buffers is untested | | verify |
| Screenshot freeze and recording stall the VM and audio: hyprpicker redraws every frame; full-screen uploads through the main loop | OmacVM TS #32 (rebuilt hyprpicker, `virgl-transfer-upload-pbo.patch`) | verify |
| OpenGL above 4.1 on the GPU | Apple OpenGL is frozen at 4.1. Venus + KosmicKrisp (macOS 26) gives Vulkan; Zink on it gives only GL 2.1 today (OmacVM ADR 0013, 0035) | limit; Venus is the next graphics project |
| Light GL throughput limited by 1 ms fence polling | OmacVM async fences: glmark2 1,000–1,500 → 2,800–3,700 (ADR 0011, 0017) | open; performance |

## Audio (host side)

| Issue | Evidence | Status |
| --- | --- | --- |
| VM freezes when the microphone starts: QEMU opens SDL capture on a vCPU thread holding the BQL; CoreAudio can block for minutes | Our `qemu-sdl-audio-device-selection.patch` defers capture to that path. OmacVM: `qemu-sdl-audio-capture-thread.patch`, `-playback-thread.patch` (TS #22, #26) | open |
| Crackling under GPU or CPU load | No main-loop QoS; RTKit's canary demotes PipeWire after a QEMU stall. OmacVM: `qemu-darwin-main-loop-qos.patch`, `qemu-hda-no-catch-up.patch`, `rtkit-no-canary.conf`; 365 → 50 breaks per 10 min (ADR 0036) | open |
| Video audio leads the picture | QEMU buffers (110–150 ms, plus our 4096 quantum) and Mac output latency are unknown to PipeWire. OmacVM sets a sink latency offset from the host (TS #28) | open |
| WirePlumber can stall on a V4L2 node that is not ready yet | OmacVM TS #29; check the camera bridge's device timing | verify |

## Mac integration, displays and power

| Issue | Evidence | Status |
| --- | --- | --- |
| VM slows to 2–20 % while hidden, on another Space or with the Mac locked (App Nap) | No App Nap handling in QEMU or the app. OmacVM `omacvm-cocoa-no-app-nap.patch` (TS #31) | open |
| Screensaver after 150 s and lock after 300 s while the user works in macOS; the screensaver costs CPU and the user unlocks on every return | `shell/plugins/services/idle/Service.qml` defaults | open; host-driven idle inhibit or user default |
| Instant resume and guest hibernation | QEMU: "virgl is not yet migratable" (OmacVM ADR 0037) | limit |
| 120 Hz frame pacing: frames dropped or repeated | OmacVM ADR 0020, 0023 | verify |
| Power profiles show but change nothing; "Managed by macOS" presentation dropped | [Host battery](host-battery.md), [shell plan](shell-plan.md) | open |
| Battery panel may show Holding while charging (stock heuristic) | [Host battery](host-battery.md) | verify |
| Battery percentage toggle hidden: `omarchy-hw-laptop` finds no lid | `menu.jsonc` `when` | open |

## Menus and features

| Issue | Evidence | Status |
| --- | --- | --- |
| Setup → Direct Boot would bypass Limine and its snapshot menu | Guarded only by `! omarchy-hw-aarch64-apple` | fixed: hidden in the VM |
| Update → Firmware installs fwupd with nothing to update | No guard | fixed: hidden in the VM |
| GeForce NOW, Battle.net and Lutris rows offered on aarch64 | The old guest refused them; upstream guards only some x86 rows | verify which fail |
| Wi-Fi, Bluetooth and Trackpad restart rows do nothing | Harmless | open, low |
| Notifications show over the screensaver | Old `notification-screen-privacy.patch`; no upstream equivalent | open; upstream |
| US-International (dead keys) layout missing | Old `keyboard-us-acentos.patch` | open; upstream |
| Project wallpaper gone | Old skel wallpaper (#88) | open, low |

## Suggested order

1. Guest package: the fixed rows above, then Kitty and 1Password once checked,
   and idle behaviour.
2. Host QEMU: microphone threading, audio QoS and RTKit, App Nap, A/V latency.
3. VirGL robustness from OmacVM's Apple-profile patches, then Venus.
