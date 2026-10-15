# Runtime validation

## 2026-10-16: stock Omarchy factory and integration package

Tested on an Apple M2 Pro Mac with 16 GiB RAM, running macOS 27.0.1.
The guest ran stock Omarchy `4.0.0.r7024.g246f33a-1`, Hyprland `0.56.2`,
Mesa `26.2.4-arch1.1`, and `linux-omarchy 7.2.8-11`.

The Mac became locked after the launcher was inspected with computer use.
Further checks used an isolated APFS clone of the sealed factory, the signed
app's real QEMU/HVF/Cocoa/VirGL runtime and host bridges, and a temporary SSH
key reachable only at `127.0.0.1:2229`. The test VM used 4 CPUs, 4 GiB RAM,
a 32 GiB disk, and a dedicated test share. The original VM was not reset or
provisioned.

The test clone seeded answers into Omarchy's own owner-provisioning functions;
it did not exercise the interactive setup form. Later cold boots used autologin
only in the disposable VM. Desktop readiness below means that the guest's
graphical session and its services became active; it does not establish visual
smoothness on the locked host.

| Check | Result |
| --- | --- |
| First-boot hardware and owner provisioning | Completed; systemd reported 67.0 s through graphical.target, including keyring initialization and boot-image rebuilds |
| Fresh rebuilt factory | A second private clone, already carrying `0.1.0-10`, completed the same provisioning pipeline in 31.3 s; all three desktop bridges started without retries, and the rendering smoke test passed |
| Three subsequent cold launches | Graphical session and integrations ready in 19.2, 17.9 and 18.7 s measured from launcher invocation; systemd boot totals 10.35, 10.40 and 10.32 s |
| User-state persistence | A marker in the guest home survived all launches; owner provisioning stayed complete |
| Integration update | The normal credential and read-only package share upgraded `0.1.0-9` to `0.1.0-10` before login |
| No downgrade | Offering the older `0.1.0-9` archive on all three cold boots left `0.1.0-10` installed and reported `current` |
| Rebuilt app with an existing VM | The newly signed app, carrying a newly rebuilt factory, reused the older VM and its home marker; the graphical session became ready in 14.0 s with all three bridges active and zero restarts |
| Stock Omarchy updater | `omarchy-update -y` completed as the regular QA user with normal sudo authentication; it created a Snapper snapshot, checked system/AUR/mise updates, reloaded the shell and passed boot verification; no package upgrades were available |
| Cold boot after stock update | Graphical session ready in 14.6 s, preserved home marker, current integration package, and all three bridges active with zero restarts |
| Service health | No failed system or desktop user units; audio, camera and clipboard each active with zero restarts after the lifecycle fix |
| Graphics | Hyprland reported no configuration errors; actual GLES3 rendering used `virgl (Apple M2 Pro)` and passed the 4× MSAA pixel check below |
| Battery | Real Mac percentage, AC state, capacities, cycle count and charge limit reached sysfs and UPower; UPower reported critical action `Ignore` |
| Battery state changes | Controlled messages through the disposable VM's battery socket exercised discharge at 42%, critical charge at 5%, and no internal battery; the VM stayed running, and real Mac readings returned afterward |
| Time zone | Real `Asia/Tokyo` followed the Mac; controlled socket messages tested a changed host zone, manual guest opt-out, and `--follow-mac`; the real Mac zone was restored |
| Shared folder | Mounted at `/mnt/mac`, linked in the guest home, and exchanged test files in both directions as uid 1000 |
| Network | NAT, loopback SSH forwarding and guest outbound HTTPS (`https://omarchy.org`, HTTP 200) worked |
| Audio | Native host endpoint remaps became the PipeWire defaults; a quiet one-second tone played through `pw-play`; one second of microphone data reached FFmpeg and was discarded |
| Camera | `Mac Camera` appeared in PipeWire and V4L2 at 1280×720 NV12; on-demand capture delivered 90 frames, discarded without saving images |
| Virtual input | Keyboard, tablet and pinch touchpad enumerated; the guest cursor remained configured invisible |
| Authentication defaults | Touch ID remained opt-in and disabled; no biometric enrollment was created |

The runtime check found that audio and camera user services originally started
under `default.target`, including during owner provisioning and root SSH
sessions. Those processes retried permission failures or competed with the
desktop for exclusive virtio ports. Package `0.1.0-10` moves them to
`graphical-session.target` and stops them with the session. Its upgrade hook
rebuilds enabled global links and preserves disabled or masked choices. The
actual boot-time upgrade and subsequent cold boots verified the migration.

### Rendering smoke test

Copy [virgl-smoke.c](../guest/package/tests/virgl-smoke.c) into a disposable
running guest. Compile and run there, as the desktop user:

```sh
cc -O2 -Wall -Wextra virgl-smoke.c -o /tmp/virgl-smoke -lEGL -lGLESv2
/tmp/virgl-smoke
```

This creates an off-screen EGL/GLES3 context, requires a VirGL renderer rather
than a software fallback, clears a four-sample framebuffer, resolves it, and
checks the exact RGBA value. It does not require an unlocked Mac screen.
The observed output was:

```text
renderer: virgl (Apple M2 Pro)
version: OpenGL ES 3.0 Mesa 26.2.4-arch1.1
max samples: 4
resolved RGBA: 51 102 153 255
PASS: hardware VirGL GLES3 and 4x multisample color resolve
```

### Build and automated verification

- `make test`: passed with native OS access, including 408 Swift tests and
  all guest, shell, graphics-contract, compatibility and relocation suites.
  The initial sandboxed run failed nine OS-boundary assertions involving
  sockets and power notifications; the native run passed. The full suite was
  rerun after the lifecycle fix and passed.
- `make test-guest`: passed, 33 tests, including service lifecycle and
  enabled/disabled/masked upgrade behavior.
- `make guest-package`: passed; produced `try-omarchy-0.1.0-10-aarch64.pkg.tar.zst`.
- `make app`: passed, rebuilding the factory and app and reusing the current
  validated runtime. Earlier attempts hit a Docker loop-device node that had
  not appeared inside the container, then a transient resource-directory
  `Operation not permitted` error during app assembly. The final attempt with
  the test VM stopped completed.
- `codesign --verify --deep --strict --verbose=2 'dist/app.noindex/Try Omarchy.app'`
  and `macos/verify-macos-compatibility.sh "$PWD/dist/app.noindex/Try Omarchy.app"`:
  passed; 22 Mach-O images validated for the macOS 15.0 deployment target.
  An initial standalone compatibility invocation used a relative path, which
  the script rejected; the absolute-path invocation passed.
- `git diff --check`: passed.

### Remaining checks

Computer use confirmed the host was locked and could not resume visual testing.
Before treating the refactor as fully signed off, verify the interactive setup
form, resize/full-screen transitions, cursor and physical shortcuts, scrolling
and pinch motion, bar/power-panel layout, and real text/PNG copy-and-paste in
both directions on an unlocked Mac. The clipboard agent was running, but this
session did not perform an end-to-end pasteboard round trip.

The media checks establish transport and device availability, not subjective
audio quality or video-call behavior. FFmpeg emitted timestamp warnings during
the probes. Raw V4L2 timestamps were strictly increasing across 90 packets,
with an initially cached frame preceding the on-demand stream; the Pulse probe
had two backward timestamp steps at startup and none in its remaining 47
intervals. Check startup and sustained capture in a real browser call before
claiming smooth conferencing or synchronized recording.

Physical charger changes, lid sleep/wake, Touch ID approval and password
fallback, 1Password unlock, real USB devices, and bridged networking were not
exercised in this session. A kernel-version upgrade and selecting a rollback
snapshot from Limine still need testing; the stock updater found no upgrades
during this run. Nested virtualization was unavailable on this M2
host, as expected; `/dev/kvm` still needs an eligible M3-or-newer Mac. The
compatibility audit is not a live run on macOS 15 or 26.

The console also emitted an encryption-hook warning for the unencrypted root,
and QEMU logged a port-8 add warning even though the time-zone device appeared
and passed transport tests. Neither blocked these boots; neither warning was
fixed in this change.
