# One app plan

Status: proposed on 2026-10-22. It replaces the installer trial plan of the same day, whose first part is built: this repository's [VM kit and run mode](vm-kit.md), and the installer's trial screens on top of them.

## Summary

[Omarchy Installer](https://github.com/omacom/omarchy-mac-installer) becomes the one app for Omarchy on a Mac. It has two modes, **Install** and **Try**. Install puts Omarchy on the Mac's own hardware. Try runs it in a virtual machine, in a window beside macOS.

- The first page offers both, side by side: **Install on this Mac** and **Try in a VM**.
- On a Mac it cannot install on, and on a Mac with Omarchy already installed, Install stays on the page, unavailable, with the reason under it. Whatever the installer can still do for that Mac stays in its menu.
- Once a VM exists, the one app opens straight into Try and starts Omarchy, and **Install on this Mac** becomes **Migrate to Native**.

Shells all the way down: Try is a shell for Omarchy, and the installer is a shell for Try. This repository is the source of Try: the kit, the client that starts it, and the `try-omarchy` guest package. The installer embeds one kit and fetches newer ones, so Try updates without an installer release. Try Omarchy as its own download ends once the one app ships with the kit's settings ([retiring the full app](#retiring-the-full-app)).

| | Install | Try |
| --- | --- | --- |
| For | Omarchy on the Mac's own hardware | Omarchy beside macOS, for an hour or for good |
| Macs | The models the catalog enables, on macOS 15 or newer | Any Apple Silicon Mac on macOS 15 or newer |
| Runs through | The pinned Asahi engine and the privileged helper | The kit's run mode |
| Permissions | None | Accessibility, Microphone and Camera, all optional |
| Settings | The size of Omarchy's partition | The kit's own, opened from inside Omarchy |

## First launch

1. The one app inspects the Mac, as the installer does today.
2. The first page is the landing page: this Mac in a line, then two buttons side by side, **Install on this Mac** on the left and **Try in a VM** on the right, each with a line under it.
3. Install continues into the plan the installer shows today. While the Mac is checked, Install is unavailable and says so.
4. On a Mac Omarchy cannot be installed on, Install stays unavailable, with the reason under it, **Details** and **Check again**. A Mac that fails only the disk check can still try Omarchy, because the VM needs free space, not a partition.
5. On a Mac with Omarchy already installed natively, Install is unavailable, with a line saying Omarchy is installed. **Remove Omarchy…** stays in the Installation menu, as today.
6. **Try in a VM** is always available. It opens the Try page, whose **Back** returns to the landing page.

The Try page is the trial's Try screen as built: Accessibility, so Command works as Super, the microphone and the camera, all optional, the space the VM needs and the space free, and **Download and start**. The free space in the header and on the Try page is one reading, so the same disk shows the same number on both.

## Try

Starting downloads the image once, unpacks it, and boots Omarchy in its own window, as the trial does today. While Omarchy runs, the page shows its state, **Shut Down** and, on a supported Mac, **Migrate to Native** ([install from Try](#install-from-try)). The page also lists any permission still not granted, with **Allow**; a grant takes effect at the next start.

A VM is the remembered choice, in the default folder or in the folder chosen in Try Omarchy ([finding the VM](vm-kit.md#finding-the-vm)). Every later launch:

- starts Omarchy at once, with the page showing its state, when the one app has every permission the Try page offers or has started Omarchy before;
- otherwise shows the landing page, with **Migrate to Native** and **Try in a VM**, and Try opens the Try page with **Allow** and **Start**, as on the first launch after Try Omarchy 1.2;
- still inspects the Mac in the background, so Migrate to Native knows whether this Mac is supported;
- offers **Migrate to Native…** in the Installation menu, beside **Remove Omarchy…**.

**Delete Virtual Machine…** in the same menu removes a VM in the default folder, after a confirmation that names the space it frees, and returns the one app to the landing page. A VM in a folder chosen in Try Omarchy is Try Omarchy's to move or delete.

Shut Down, quitting the app and closing the Omarchy window shut Omarchy down over QMP, wait up to a minute, and then stop QEMU, as today. The app shows **Shutting down** until the VM has exited and quits only then.

### Settings

The one app has no settings page of its own. Settings live in the kit: the launcher window Try Omarchy has today, with its sharing, network, virtual machine and storage sections. The run mode serves the settings bridge, so Omarchy's Setup menu keeps its settings row, and choosing it opens the kit's launcher window beside the Omarchy window, named after the one app. Changes apply at the next start, as in Try Omarchy.

The run mode reads the same stored settings the launcher writes, so memory and CPUs, networking, port forwarding, the shared folder, USB devices and the storage folder all take effect in Try without the one app knowing them. The run-mode configuration keeps only what the app knows: the product name and the optional bridges.

The settings move out of the app's preferences domain into a file in the VM's folder, where the startup choice already lives. Any kit then reads the same settings, whichever bundle it runs from and whichever kit version it is.

## Install from Try

Once a VM exists, **Install on this Mac** reads **Migrate to Native**, on the landing page, on the running page and in the Installation menu. It is available when Install would be, and unavailable for the same reasons. On an unsupported Mac the menu item opens the reason instead, with **Check again**.

Migrate to Native brings the VM's home folder along ([native install export](native-install-export.md)). Omarchy exports it from inside the VM with **Setup → Move to Native Install**, which only VMs the installer runs offer, and the launcher publishes the export when the VM stops. Migrate to Native opens a sheet that offers the newest export, checked against its receipt, with **Install with These Files**; offers **Shut Down Omarchy** while a finished export waits in the running VM; or says how to export. **Install Without Migrating** and **Cancel**, the default button, stay in every case. Both install buttons shut Omarchy down if it runs and continue into the plan. Staging the export onto the native disk and importing it there are not built yet.

The plan review counts the space the VM's folder actually uses against free space, as the trial does today. The native install leaves the VM in place. Whether the review offers to delete it first stays an [open question](#open-questions).

## One VM

The one app and Try Omarchy open the same VM, in the `Try Omarchy` folder under Application Support or the folder chosen in Try Omarchy, with the same settings. Until the person updates Try Omarchy 1.2, the one app reads 1.2's settings at every start ([settings](vm-kit.md#settings)). The lock on the VM folder stops both from running it at once; the run mode reports `vm-already-open`, the one app says that Omarchy is open in Try Omarchy, and Try Omarchy says that it is open in another app, such as Omarchy Installer. Either app can boot a VM the other made, and the `try-omarchy` package only upgrades ([integration updates](integration-updates.md)), so an older kit never downgrades the guest.

The trial's **Open in Try Omarchy** handoff goes away: the one app always runs the VM itself.

## One identity

Everything in Try runs as the installer. The kit's binaries carry the installer's bundle identifier and name, are signed with the installer's identity and notarized with the installer, and macOS asks for Accessibility, Microphone and Camera in the installer's name and records the grants against it. The QEMU window's Dock name, icon and menus are the installer's too.

The kit is a helper bundle inside the installer's `Contents/Helpers`, with no bundle identifier or name of its own, so the installer's build signs and notarizes it like its other helpers ([no identity](vm-kit.md#no-identity)). A bundle identifier is what macOS files preferences, permission grants and Launch Services registration under, which is why the kit has none. It stays a bundle so its signature seals its scripts and resources.

A kit the installer fetches cannot be signed as the installer. It is signed and notarized by this repository's release identity, and the installer accepts a kit whose signature chains to either team, this repository's or its own, with the hardened runtime and the kit's identifier. One team for both is the end state, and then the list shrinks to one. The grants still belong to the installer, because macOS attributes a helper's permissions to the app that started it, whoever signed the helper. The installer's Info.plist carries the usage descriptions for the camera and microphone.

The kit has no permissions of its own, so the flattening above is for tidiness: one notarized unit, and no second name in the Dock or in System Settings. Permissions work the same as long as the installer starts the kit as a child process.

## Fetching kits

The installer embeds the kit it was built with, so Try works offline and on first launch. It also fetches newer kits from this repository's releases, so a fix to the VM reaches people without an installer release.

- A release here publishes `TryOmarchyKit.zip`, its digest, and the image parts. The kit's version is the release's.
- The installer checks for a newer kit when Try starts, no more than once a day, and downloads it to its own Application Support folder, following its rules for cellular and Low Data Mode connections. The next start of Try uses it. A download that fails leaves the current kit in use.
- Before using a fetched kit the installer verifies its digest and its signature, and that its version is newer than the kit it has. It never runs a kit older than the embedded one, so a downgrade never reaches the guest.
- A kit is signed by one team as a whole. The hardened runtime refuses libraries signed by another team, so the installer re-signs all of the embedded kit, as it does today, and a fetched kit is used as signed.
- The installer downloads kits without the quarantine attribute, as it downloads its other assets, so Gatekeeper never asks anyone to approve a helper they never opened.
- The run mode's configuration and events are versioned, so an installer works with the kits that come after it. A kit that needs a newer installer says so in its release, and the installer keeps the newest kit it understands.

The kit's image parts and manifest stay on this repository's releases, which are never deleted, because an installer may still pin or hold an old kit.

## Retiring the full app

Once the one app ships with the kit's settings window, Try Omarchy's download ends. This repository then:

- publishes the kit, the client and the image parts with each release, and no DMG;
- keeps `make app` and `make e2e` as the way to develop and test Try on a Mac;
- keeps the `Try Omarchy` folder under Application Support, so existing VMs and settings stay where they are;
- moves what the manual says about Try to the one app's documentation, and keeps here what is about the VM itself.

The one app's own updates are the installer's matter, outside this plan.

## Work

Done, on the installer trial branches:

- This repository: the session shared by the full app and the run mode, the run mode, the client library, `make kit` and its release assets.
- The installer: the embedded and signed kit, the Try screen, the running page, shutdown from every place, and the space line in the plan review.

Next, in this repository:

1. Done: the settings bridge and the launcher window in the run mode, named after the product.
2. Done: settings stored in the VM's folder, and the run mode reading them.
3. Done: the kit as a helper bundle without a bundle identity, and the product name, icon and menus in the QEMU window.
4. Done: the kit signed and notarized by its release, and a version the installer can compare, in the kit's manifest.
5. Done: the kit's own bridged-networking daemon, which the embedding app registers as itself ([bridged networking](vm-kit.md#bridged-networking)). Bridged networking from a fetched kit remains.
6. When the one app ships with settings: stop publishing the DMG, and move the manual.

Next, in the installer:

1. Done: the landing page, with **Install on this Mac** and **Try in a VM** side by side on every Mac, and **Migrate to Native** once a VM exists.
2. Done: the remembered choice: a VM in the default folder opens Try and starts Omarchy, with the inspection in the background.
3. Done: **Install on this Mac…** and **Delete Virtual Machine…** in the Installation menu, and the Allow rows on the running page.
4. Done: the **Open in Try Omarchy** handoff is gone, and `vm-already-open` names Try Omarchy.
5. Done: the kit built into the installer's bundle under its identity.
6. Done: fetching, verifying and switching to newer kits.
7. Done: registering the kit's networking daemon as the installer, offered on the `bridged-network-unavailable` notice ([what the embedding app does](vm-kit.md#what-the-embedding-app-does)).

## Testing

- This repository: `make test` keeps the client's contract tests against the run mode and starts the run mode as a real process, CI builds and checks the kit, and `make e2e` boots the app's VM through the run mode. The settings window in the run mode is checked by hand from Omarchy's Setup menu.
- The installer: `TrialSessionTests` cover the landing page in every state of the inspection, Install's reasons, Try and Back, Migrate to Native and its sheet in each case, the remembered choice, the menu items and the two free-space numbers. The assembly test checks the kit's signature under the installer's identity. Kit fetching gets tests for the digest, signature and version checks against fixtures.
- By hand on a Mac: the landing page on a supported Mac, an unsupported one and one with Omarchy installed; a second launch with a VM; Migrate to Native from the landing page, the running page and the menu, before and after an export; the settings window from the Setup menu and a setting that applies at the next start; a fetched kit taking over at the next start; Delete Virtual Machine; and the lock error with Try Omarchy running.

Neither repository's CI can boot the VM.

## Open questions

- Whether the one app keeps the name Omarchy Installer. It reads fine for both modes. The alternative is Omarchy, with the installer's identity kept.
- Whether the plan review offers to delete the VM before a native install, since the install leaves 9 GB or more in Application Support that the person may not use again.
- Whether a Touch ID enrollment made in Try Omarchy works in the one app. Both read keys from the same folder, and Secure Enclave keys are bound to the Mac, so it should. It needs a test.
- Whether fetched kits should come through the installer's signed catalog instead of this repository's releases, once the catalog host exists.
