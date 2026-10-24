# Docs

How Try Omarchy works, for contributors. User guides are in the [manual](../manual/README.md).

## How it works

- [Architecture](architecture.md)
- Guest specifics: [Ghostty](ghostty.md), [Japanese input](japanese-input.md), [Touch ID for 1Password](onepassword-touch-id.md)
- [App updates](app-updates.md) and [integration updates](integration-updates.md)
- Integrations:
  - [audio continuity](audio-continuity.md)
  - [camera notch](camera-notch.md)
  - [host battery](host-battery.md)
  - [USB FIDO keys](fido.md)
  - [time zone](host-timezone.md)
  - [clock recovery](guest-clock-recovery.md)
  - [Mac keyboard](mac-keyboard.md)
  - [pinch zoom](pinch-zoom.md)
  - [trackpad scrolling](trackpad-scrolling.md)
  - [memory reclamation](memory-reclamation.md)
  - [shared-folder safety](shared-folder-safety.md)
- Networking: [ICMP replies](nat-icmp-reply-matching.md) and [UDP replies](nat-udp-reply-translation.md)

## Working on it

- [Known VM issues and backlog](vm-issues.md)
- [Performance](performance.md)
- [Runtime validation](runtime-validation.md)
- [Releasing](releasing.md)
- [Shell plan](shell-plan.md): the design record behind the move to stock Omarchy
- [One app plan](one-app.md): Omarchy Installer as the one app, with Install and Try modes, on the kit this repository builds
- [The VM kit and run mode](vm-kit.md): how another app embeds and runs the VM
