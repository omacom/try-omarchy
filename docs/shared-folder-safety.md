# Shared-folder safety

The Mac share at `/mnt/mac` uses `cache=readahead`. It enables read-ahead file
caching without `CACHE_WRITEBACK`, avoiding the writeback path implicated in
[issue #281](https://github.com/omacom/try-omarchy/issues/281).
[Linux's 9p documentation](https://www.kernel.org/doc/html/latest/filesystems/9p.html)
defines `readahead` as cache mask `0x1`, while `mmap` is `0x5` and includes
writeback. This policy applies regardless of the guest kernel version.

## Why a factory update is insufficient

The issue reports zero-length metadata and NUL-filled reads that can be written
back over host files on an affected kernel with `cache=mmap`. Its reproduction
rate, workload compatibility, and performance measurements are reporter results;
the project's contract tests do not reproduce kernel corruption.

The [Linux 7.2.8 changelog](https://www.kernel.org/pub/linux/kernel/v7.x/ChangeLog-7.2.8)
contains stable commit `9cd92e3392bd`, upstream `c60ae98c5aa6`, which updates
`i_size` and `remote_i_size` after a 9p write extends the server file.
Main's transaction lock already pins `linux-aarch64` and matching headers to
`7.2.8-1`. The v0.4.1 transaction lock pinned `linux-aarch64 7.2.5-1`; the issue's reported
`linux-aarch64 7.2.6-1` is not that source pin. Check the actual running kernel
with `uname -r` rather than inferring it from the Mac app version.

An existing persistent VM keeps its disk and paired kernel/initramfs when the
Mac app changes. Kernel packages are held deliberately to preserve that pairing.
Ordinary Omarchy Update and the integration review do not migrate it to the
current factory kernel. Do not remove those holds or manually replace only the
host's kernel file to address this issue.

## Existing guests

A build containing this mitigation masks the older guest's mount unit for each
QEMU launch with sharing enabled. The existing boot payload service
runs the bundled safe helper from the app's separate read-only payload before
installing settings and before the display manager starts. It does not replace the old guest helper, kernel, initramfs, package holds, or user data.
No factory reset or integration-review installation is needed.

If the safety payload is missing or boot arguments would exceed ARM64's
2,048-byte limit, the launcher refuses to start with sharing enabled. If mounting
the payload or personal share fails inside Linux, the payload service
fails and the share remains unavailable; it never retries using `cache=mmap`.
The existing home-directory link service still uses the selected folder's name.

Close applications using the share, shut down Linux cleanly, and launch it again
from the updated Mac app. An app update does not change a currently mounted
share. **Restart Omarchy…** also starts a new QEMU process; merely rebooting
Linux inside an old QEMU process retains that process's original boot arguments.
Returning to an older app also restores that app's old policy unless the guest
helper was separately mitigated.

Verify in an Omarchy terminal before resuming shared-folder work:

```sh
findmnt -n -t 9p -o SOURCE,TARGET,OPTIONS /mnt/mac
systemctl status try-omarchy-settings.service --no-pager
systemctl show -p LoadState -p FragmentPath omarchy-native-mac-share.service
```

The mount should report source `mac` and `cache=readahead` or `cache=0x1`, never
`cache=mmap` or `cache=0x5`. The older mount unit should report
`LoadState=masked` with a fragment under
`/run/systemd/generator.early/`. The completed boot payload service is normally
inactive after it unmounts its read-only payload.
If it does not, turn sharing off and perform a full shutdown and app relaunch.

## Mitigation while using an older app

The simplest option is **Shared folder > Turn Off**, followed by a clean Linux
shutdown and a new app launch. Copy projects to the guest's local disk while
sharing is disabled. Turning it off only affects the next launch.

For an unmodified stock guest helper, this narrow guest-side edit also persists
across older-app launches. Close every application using the share first:

```sh
sudo cp -p /usr/local/bin/omarchy-native-mac-share /usr/local/bin/omarchy-native-mac-share.before-281
sudo sed -i 's/cache=mmap/cache=readahead/g' /usr/local/bin/omarchy-native-mac-share
```

Review the change, then shut down Linux cleanly and relaunch the Mac app. Use the
mount verification above; the stock unit will remain under `/usr/lib/systemd/`.
If the helper was customized or has no `cache=mmap` mount option, review it
manually instead. Do not remount an active share, force-unmount it, or run a
corruption probe on personal files. Retain the backup for review; restoring its
old mount policy would reintroduce exposure on affected kernels.

## Compatibility and release verification

Writes use the synchronous path, so bulk sequential writes may be slower.
Writable `MAP_SHARED` mappings are unavailable in this mode. Keep SQLite WAL
databases and mmap-based IPC on the guest's local disk. The issue reports Git
and read-only/private mmap compatibility, but those results are not an app-level
validation of every application.

Before release, boot a disposable copy of an older guest with its original boot
kit and a fresh temporary host folder. Confirm the old mount unit is masked and
the boot payload mounts the personal share before login, the mount reports cache
mask `0x1`, and payload failure leaves the personal share unmounted. Test repeated extending writes, immediate
stat/read-back, concurrent reads, host-side byte/hash verification, Git operations,
and mmap behavior only in that temporary folder. Repeat against a newly built
factory and inspect its installed packages and paired boot artifacts. Contract
tests cover mount arguments and launcher delivery; they do not prove the kernel
race is fixed or validate the shipped package contents.
