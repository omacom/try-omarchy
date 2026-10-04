# Integration updates for existing VMs

App upgrades retain existing guest disks. The integration manager delivers
reviewed guest features independently of the bundled factory image.

The [shared-folder safety mitigation](shared-folder-safety.md) is supplied
automatically by the app at boot, separately from this review workflow. It
changes the mount policy for that boot without replacing the guest kernel or
requiring installation of integration support.

## Updates at launch

Compatible repairs have an **Update and Launch** action at the bottom of the
Mac launcher on the first app open with an existing disk that has no check for
the current fix bundle, or when a matching check found unfinished work.
No preliminary VM boot is needed. Automatic startup (Skip Launcher) shows the
launcher when that bundle needs its first review, then resumes normally on
later opens. A missing disk or a VM with a current result keeps **Launch Omarchy**.

**Update and Launch** opens a review of the supported existing-VM repairs listed below. Choose
**Update and Launch**, **Skip**, or **Cancel**. Skip requires a second
**Skip and Launch** confirmation and leaves the fixes available for manual retry.
The review appears automatically only once per disk and fix bundle, including
after a skip, cancellation, failure, or interrupted update. Skip Launcher then
continues to start normally. The launcher's **Update and Launch** action remains available
while fixes are pending; click it while the VM is shut down to explicitly retry.
That action still requires approval before applying changes. Older failed or
unconfirmed attempts also stay manual. The existing settings, timezone integration, and shared-folder safety
payload still run; Skip applies only to the reviewed repairs.

The review list comes from the shared [migration catalog](../guest/migrations/catalog.json).
It lists the full set of supported repairs, rather than a pre-boot inspection of
the selected disk. The guest determines which files are current, need updating,
or must be preserved when it boots. Catalog revisions describe components;
approval and review reminders remain tied to the complete bundle's content hash.

Approval is limited to the reviewed bundle and selected disk's file identity,
rechecked under the workspace lock. The existing temporary boot service runs
the repairs before graphical login, without command pasting or a Linux
password prompt. It does not require an integration agent in the old VM.

Stock integrations are replaced only when their current or reviewed historical
contents match. Customized files, unsafe paths, unsupported dependencies, and
explicit service overrides are preserved and reported as skipped. Hold-list
repair adds only missing compatibility names while preserving existing entries
and comments; pinch setup appends its scoped device rule without replacing the
user's other input settings. Existing lock-screen PAM policies are preserved.
The runner saves a root-private journal before changing any file, verifies the
entire change set, and restores original bytes, ownership, and permissions if
an update or service activation fails. Service activity and the loaded battery
module are restored along with their original files. An interrupted transaction is restored on the next boot,
even if that launch skips updates. Successful backups remain under
`/var/lib/try-omarchy/boot-fixes/backup-*.json`. This is recovery for the listed
file changes and listed service/module activation, not a full-disk snapshot or
rollback of arbitrary commands. User files have a separate journal under
`~/.local/state/try-omarchy/boot-fixes`; these steps run as their desktop user.
Earlier successful components can remain applied when a later user step fails.
If recovery itself cannot finish, the result explicitly reports that recovery
needs attention; it never claims the original files were restored.

After an approved update, the Mac app shows one brief result message: the update
finished, or it could not be completed or confirmed. Results do not add a
persistent report or notice to the launcher. No report or no response establishes
success.
Results are scoped to that VM disk and fix bundle; another disk or reset does
not inherit completion. A missing result offers review before boot;
an unconfirmed approved update leaves a manual retry available through **Update and Launch**.

<a id="manual-upgrade-commands-covered-by-update"></a>

### Manual upgrade commands covered by Update and Launch

| Previous manual step | Automatic migration |
| --- | --- |
| Clipboard/screensaver fixes and Alacritty wrapper retirement | Recognized stock scripts, verified and backed up. |
| Power panel/menu plugin fixes | Exact reviewed QML and command patches, now included in the journal and result. |
| `systemctl enable --now systemd-timesyncd` and clock-recovery installer | Install the recovery helper/units and enable time synchronization and the recovery timer. An explicitly disabled existing recovery timer is preserved. |
| `repair-update-holds.py --apply` | Add compatibility holds to both pacman configurations under the pacman transaction lock; no package operation. |
| `omarchy-apply-lock` | Seed only the missing pinned password policy; preserve existing PAM and fingerprint policies. |
| Integration bootstrap/setup command | Install the verified support bundle, menu entry, setup command, and status service automatically. |
| Ghostty installer from an updated checkout | Update recognized stock Ghostty installer files, verification pins, and the terminal-menu hook; Ghostty is installed later through **Install → Terminal → Ghostty**. |
| Battery retrofit/update installer | Build privately against the running kernel with existing tools and headers; journal sources, module, DKMS receipts, service enablement, and bridge files before activation. |
| Existing 1Password integration update | Update recognized installed helpers/unit without enabling a new integration or changing enrollment. |
| 1Password installer desktop-entry fix | Update the recognized stock installer to support current and legacy desktop filenames, independently of Touch ID setup. After an interrupted installation, rerun **Install → Service → 1Password**. |
| Pinch input snippet and Alacritty `--launcher` cleanup | Run as each desktop user; keep other input settings and remove only the exact stale launcher when Alacritty is absent. |

Battery builds are bounded to three minutes with two compiler jobs. The boot
service allows five minutes; an approved host check waits up to six minutes
before reporting an unconfirmed result. Missing DKMS, build tools, matching
headers, or an unsupported module location produce a skipped battery result;
no dependency is downloaded or installed. The kernel and paired boot kit stay
unchanged. The battery source, build receipt, and active DKMS link are published
with the verified module, so normal DKMS status and future explicit maintenance
continue to recognize it.

This flow does not install or upgrade packages, replace the kernel, update the
graphics stack, enable biometrics, or reproduce every factory change. Installing
new optional applications and first-time 1Password enablement remain explicit
setup choices. An enrolled older Touch ID protocol requiring enrollment/PAM
migration is preserved for the guest review below; its password fallback is not
changed by Update and Launch. Customized or unsupported steps are reported, not forced.

## Optional guest review and manual fallback

The normal supported setup is **Update and Launch**, without pasting a command.
The guest review remains available for opt-in pairing and unsupported/custom
repairs under **Omarchy Menu > Setup > Try Omarchy Integrations**. The Mac
launcher uses the launch-time Update and Launch action and per-fix results for routine
updates; it does not show a separate manual-install banner or menu-bar prompt.

If the guest menu entry is missing and the launch-time update cannot install it,
launch Omarchy and paste this fallback command into an Omarchy terminal:

```sh
sudo mkdir -p /mnt/try-omarchy-updates && (mountpoint -q /mnt/try-omarchy-updates || sudo mount -t 9p -o trans=virtio,version=9p2000.L,ro tryomarchy-updates /mnt/try-omarchy-updates) && bash /mnt/try-omarchy-updates/setup
```

It mounts the app's dedicated read-only 9p share and opens a review. The share is
separate from the optional personal shared folder and needs no SSH connection.

Choose **Manually install/repair integration support (fallback)** and review replacements before
confirming. Installation asks for the Linux user's sudo authorization, retains
backups, and verifies each component before recording it as complete. Biometric
enrollment remains a separate action. Existing PAM enrollment is preserved.

The guide is then available under **Omarchy Menu > Setup > Try Omarchy
Integrations**, or with `try-omarchy-integrations` in the guest terminal.

## Features and boundaries

- sudo Touch ID: installs support; pairing is explicit and can be tested or repaired.
- Mac battery: installs the [host battery](host-battery.md) module and bridge, so
  the Mac's charge appears in the Omarchy bar. The guest builds the module with
  DKMS. VMs with the current integration are left as they are; older installed
  versions are upgraded by the launcher's **Update and Launch** flow on their next approved
  boot. Manual installation remains available for skipped or unsupported repairs.

The bundle contains upstream sudo Touch ID support and the Mac battery mirror.
Additional integrations can be added after their own upstream review. The manager does not
replace the kernel, upgrade the graphics stack, repair package holds, install
1Password integration, or reproduce every change in a newer factory image. Ordinary package
updates remain with Omarchy Update. No VM reset is required for these integrations.

## Status

A dedicated virtio port carries bounded status reports to the host every ten
seconds. Every VM launch starts a new check. After 120 seconds without a valid
report the host shows that setup or repair may be needed and continues listening.
A component that cannot be installed in this VM reports `disabled` rather than
needing repair: the battery module needs DKMS and headers for the running kernel,
which images before v0.3.0 lack and which are missing after a kernel update until
Omarchy restarts. The review names the reason, and installation skips the battery
without failing the other integrations.
An older, slow, or stopped guest agent cannot be distinguished by silence alone.

When setup, updates, or repairs may be needed, an attention icon appears in the
Mac menu bar with the status and a review action. It disappears after a healthy
report. The status bridge runs silently and does not show a separate review prompt.
Checks still run on every launch.

The launcher shows a compact attention notice only when the last check for the
selected persistent disk needs attention. It stays hidden before the first check,
while a check is incomplete, and for current integrations. Optional Touch ID
pairing and an unsupported battery module do not trigger a notice; pairing remains
available inside Omarchy. New VMs already include the integration manager.
A report of current components means installed files, including the setup command
and reporting service definition, passed inspection;
it does not attest that Touch ID was successfully used. Status messages never
execute commands or authorize host or guest installation.

## Failure and retry

An installed bundle with additional integrations is not replaced by this smaller
bundle. Use an app that supports those integrations; their files and enrollment
are left intact.

The updater verifies the exact bundle inventory and hashes before installation,
then stages a root-private copy. The app signature covers the bundle and manifest;
hashes detect corruption and do not independently establish trust in an app.

Previous files, the previous installed bundle, and progress are retained under
`/var/lib/try-omarchy/integrations`. Before sudo support is installed, its backup
also retains any existing sudo PAM policy, Touch ID enrollment state, and account
default menu extension, with their file permissions. These backups remain private
to root even if migration fails. A component is marked complete only after
verification. Rerunning skips a previously completed step only when its managed
files still match. This is resumable installation, not a transactional
rollback of all PAM or systemd effects. A failed step prints its error and leaves
progress and backups available for repair.

Installation lists existing integration files that differ before asking to
replace them. Unrelated menu entries and package-configuration settings are
preserved. Unsupported or unsafe paths stop the operation. Close Omarchy Update
before installing integrations. An active package transaction blocks installation.

Guest status diagnostics:

```sh
systemctl status try-omarchy-integrations.service --no-pager
sudo journalctl -u try-omarchy-integrations.service -b -n 40 --no-pager
```
