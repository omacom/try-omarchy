<p align="center">
  <img src="macos/OmarchyIcon.svg" width="128" height="128" alt="Try Omarchy logo">
</p>

<h1 align="center">Try Omarchy</h1>

<p align="center">The best way to run <a href="https://omarchy.org">Omarchy</a> on an Apple Silicon Mac.</p>

Try Omarchy is a Mac app that runs stock Omarchy in a fast virtual machine and bridges it to macOS. That includes the Retina display, the Mac keyboard, clipboard, audio, camera, battery, a shared folder and Touch ID. Omarchy itself is left untouched, so it behaves and updates like any other Omarchy install.

<img width="1920" height="1173" alt="Try Omarchy on a MacBook Pro" src="https://github.com/user-attachments/assets/44f67c59-ba85-4819-8905-71b188bc02fe" />

## Get started

1. Download the latest `.dmg` from [Releases](https://github.com/omacom/try-omarchy/releases).
2. Drag **Try Omarchy** to **Applications** and open it.
3. Choose **Launch Omarchy**.

The first launch downloads the Omarchy image (about 3 GB). If the download is interrupted, it resumes where it left off.

You need an Apple Silicon Mac with macOS 15 or newer and about 15 GB of free space.

## How it works

- **Omarchy is stock.** The VM runs the official `aarch64` Omarchy from Omarchy's own repositories. Try Omarchy adds one package, `try-omarchy`, and changes no file that Omarchy owns.
- **Omarchy updates itself.** Run `omarchy update`, or use **Update → Omarchy**, whenever you like. Each update takes a snapshot first, so you can roll back from the boot menu.
- **The app updates the Mac integrations.** Each app release brings a newer `try-omarchy` package, which the VM installs at its next boot.
- **Edge channel for now.** Omarchy publishes for ARM on `edge` only. Once Omarchy releases its Mac image on `stable`, Try Omarchy will use `stable` too.

## What you get

- Native CPU speed through Apple's Hypervisor framework, and GPU-accelerated graphics
- A full-screen or windowed desktop that follows your display's resolution and scaling
- Command works as Super. Mac keyboard layouts (ANSI, ISO and JIS) are mapped correctly
- Two-way clipboard for text and images
- Mac audio output and microphone, with live device switching
- The Mac camera, available to Omarchy as a webcam
- The Mac's battery in the Omarchy bar
- One shared Mac folder, under the same name (`~/Work` stays `~/Work`)
- Touch ID for `sudo` and 1Password
- Port forwarding, SSH, bridged networking and USB passthrough (experimental)

**Limitations:**

- Video decoding uses the CPU, so high-resolution playback can stutter.
- Vulkan is not available.
- Nested virtualization is opt-in.

## Manual

Settings live in the launcher. Once Omarchy is running, open them with **Setup → Try Omarchy Settings**.

The [manual](manual/README.md) covers what's specific to running Omarchy in Try Omarchy:

- [Getting started](manual/getting-started.md)
- [Omarchy on a Mac](manual/omarchy-on-a-mac.md)
- [Files, network and devices](manual/files-network-devices.md)
- [Touch ID](manual/touch-id.md)
- [Updates and your data](manual/updates-and-data.md)
- [Troubleshooting](manual/troubleshooting.md)

For Omarchy itself, see [the Omarchy manual](https://learn.omacom.io/2/the-omarchy-manual).

## Help

- **Problems with Try Omarchy:** see [troubleshooting](manual/troubleshooting.md), or open an [issue](https://github.com/omacom/try-omarchy/issues).
- **Problems in Omarchy itself:** if it also happens on real hardware, report it to [Omarchy](https://github.com/omacom/omarchy).
- **Security issues:** follow [SECURITY.md](SECURITY.md).

## Power users and contributors

- [Architecture](docs/architecture.md): how the app, QEMU, the image and the guest package fit together.
- [Contributing](CONTRIBUTING.md): principles, building from source, tests and CI.
- [AGENTS.md](AGENTS.md): instructions for coding agents.
- [docs/](docs/README.md): how each part works.

## License

[MIT](LICENSE). Created by [Eduardo Martinez](https://x.com/martiano). Omarchy and bundled components keep their own licenses; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). The Omarchy mark comes from the [official brand kit](https://omarchy.org/brand/) and remains subject to Omarchy's trademark rights.
