# Mac app version tracking and updates

The Mac app, its bundled factory image, and an existing guest have separate
versions. Package updates inside the guest do not update the Mac app or QEMU.
Replacing the app preserves the existing VM; the guest keeps updating itself
with `omarchy update`. The app offers its bundled `try-omarchy` package at the
next boot (see [integration updates](integration-updates.md)).

## Finding a release

The launcher checks once every 24 hours by default, when the app starts. Opting out is preserved, and a manual check ignores the limit. Failed attempts count toward it. The last release found is kept, so the link in the launcher keeps saying **Update Available…** across launches.

A newer release is offered once, in a sheet on the launcher or the settings window, when that window is active and idle. Checks that finish during guest use, launch, shutdown, a permission request or another dialog wait. **Skip** leaves the link and manual updates available. Failures stay quiet.

`AppReleaseChecker` owns that schedule for every build, so there is one automatic checker. Where it looks depends on the build:

- **Releases** ask Sparkle, which reads the [appcast](releasing.md#the-appcast) and offers only releases with a higher build number that support this macOS.
- **Development builds and builds without an update feed** ask GitHub for the latest stable release, and open its page instead of installing it. `TryOmarchyBuildDescribe` must equal `v` followed by `CFBundleShortVersionString` for versions to be compared.

## Installing it

Releases install updates with [Sparkle 2](https://sparkle-project.org/documentation/), pinned in `macos/Package.swift`. `macos/build-app.sh` embeds `Sparkle.framework` in `Contents/Frameworks`, without the XPC services meant for sandboxed apps, and signs its updater inside out. The kit drops the framework, since the app embedding it owns its updates, and the helper links Sparkle weakly so it runs without it. `--ephemeral` sessions do not update the app, which would discard their VM.

Sparkle is on when `Info.plist` names both `SUFeedURL` and `SUPublicEDKey` and the build is a release (`AppUpdater.swift`). `build-app.sh` removes both from development builds.

The person agrees once, in the launcher's sheet or with **Update…** in the updates window. Sparkle's own questions are answered for them (`AppUpdateDriver`); its windows show progress and errors. Nothing is downloaded before that, and nothing is installed in the background: Sparkle's own schedule is refused, and its feed is the bundle's even when a preference names another.

What happens to the VM first (`AppUpdateStep`):

- **Nothing runs:** the update starts.
- **Omarchy runs:** the app asks to shut it down, sends ACPI power-off as **Shut Down** in the settings does, and starts the update once QEMU has exited cleanly. There is no forced timer: if the guest never shuts down, nothing is downloaded or replaced. If QEMU exits with an error, the app says so and does not update.
- **Omarchy is starting or stopping, its image is downloading, its files are being moved, or another instance of the app is open:** the app asks to try again later. Sparkle would quit every instance.

While an update is under way, Omarchy does not start and its storage cannot be moved or deleted. Should anything still be running when Sparkle is ready to replace the app, the replacement is postponed until it ends.

Sparkle verifies the DMG's Ed25519 signature before opening it (`SUVerifyUpdateBeforeExtraction`), and the app's code signature before replacing anything. VM storage, boot files and settings are outside the app and are not touched. The new version opens, and offers its `try-omarchy` package at the VM's next boot as any new version does.

The first release with a feed has to be installed by hand.

## Testing

- `make test`: the steps above, the configuration and the prompts, and the appcast with real signatures (`tests/test-appcast.py`).
- `make test-app-updates`: the framework in a built app.
- `make test-app-install`: two versions of an ad hoc production app signed with a throwaway key. Sparkle installs one over the other and reopens it, and refuses another key's signature, a changed DMG, an interrupted download, a release for a newer macOS, an app opened from a disk image, and a second open instance. CI runs it.
- `make test-app-install APP_UPDATE_VM=DIR`: the same, and an update while a disposable VM runs ([test VMs](../agents/skills/test-vms.md#update-the-app-while-a-vm-runs)). CI cannot boot the VM.
- `make test-app-install APP_UPDATE_IDENTITY=…`: the same with Developer ID signatures, and replacing a lost update key ([a signed rehearsal](releasing.md#a-signed-rehearsal)).
- Two published releases, from the app, for what only they show: notarization, GitHub's redirects and the quarantine flag.
