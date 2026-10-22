# Getting started

## Install

You need an Apple Silicon Mac with macOS 15 or newer and about 15 GB free.

1. Download the latest `.dmg` from [Releases](https://github.com/omacom/try-omarchy/releases).
2. Drag **Try Omarchy** to **Applications** and open it.
3. Choose **Launch Omarchy**.

The first launch downloads the Omarchy image (about 3 GB). An interrupted download resumes where it stopped. The launcher then verifies and unpacks the image, and shows each step and its progress.

On first boot, Omarchy's setup asks for your account, keyboard and time zone. **Same as macOS** is preselected for the time zone, and the language follows the Mac's.

## The launcher

The launcher opens every time you open the app. It holds the VM's settings: resources, sharing, network, permissions and display.

- **Skip launcher** starts Omarchy straight away with your saved settings. To see the launcher again, hold **Option** while opening the app.
- **Inside Omarchy,** open the same settings with **Setup → Try Omarchy Settings**. Most changes apply at the next launch; **Restart Omarchy** applies them now. Save your work first.
- **Shut Down** from the settings gives you **Manage VMs**, where you can move, switch or delete a VM.

Restarting from inside Omarchy reboots it in the app. Shutting down Omarchy closes the app.

## Full screen or a window

**Immersive** is on by default: Omarchy opens full screen and hides the Mac's menu bar and Dock. Turn it off to use a resizable window. Either way, Omarchy follows the window's size and the display's scaling.

**All Displays**, on by default with Immersive, puts Omarchy on every display connected to the Mac, arranged as in System Settings. See [Omarchy on a Mac](omarchy-on-a-mac.md#display-power-and-time).

## Permissions

All of these are optional. Omarchy starts without any of them.

| Permission | What it's for |
| --- | --- |
| Accessibility | Lets Command shortcuts that macOS would take, such as Command-Space, reach Omarchy |
| Microphone | Lets Omarchy apps record. The Mac's microphone turns on only while one is recording |
| Camera | Shows the Mac's camera to Omarchy. It turns on only while an app is using it |
| Networking helper | Needed only for bridged networking. You approve it once in System Settings |
