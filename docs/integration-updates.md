# Integration updates for existing VMs

App upgrades retain existing guest disks. The integration manager delivers
reviewed guest features independently of the bundled factory image.

The [shared-folder safety mitigation](shared-folder-safety.md) is supplied
automatically by the app at boot, separately from this review workflow. It
changes the mount policy for that boot without replacing the guest kernel or
requiring installation of integration support.

## First setup

When an integration check finds updates, repairs, or no response from the VM,
the Mac launcher shows an attention notice above its settings, with the reason
and a highlighted **Review…** button.
Launch Omarchy and paste the supplied command into an Omarchy terminal. It mounts
the app's dedicated read-only 9p share at `/mnt/try-omarchy-updates` and opens a
review. The share is separate from the optional personal shared folder and needs no SSH connection.

Choose **Install/update integration support** and review replacements before
confirming. Installation asks for the Linux user's sudo authorization, retains
backups, and verifies each component before recording it as complete. Biometric
enrollment remains a separate action. Existing PAM enrollment is preserved.

The guide is then available under **Omarchy Menu > Setup > Try Omarchy
Integrations**, or with `try-omarchy-integrations` in the guest terminal.

## Features and boundaries

- sudo Touch ID: installs support; pairing is explicit and can be tested or repaired.
- Mac battery: installs the [host battery](host-battery.md) module and bridge, so
  the Mac's charge appears in the Omarchy bar. The guest builds the module with
  DKMS. VMs that already have it, including factory images that ship it, are left
  as they are.

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
report. The app does not interrupt the VM with an automatic review dialog.
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
