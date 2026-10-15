# Shared-folder safety

The Mac share at `/mnt/mac` uses `cache=readahead`. It enables read-ahead file
caching without `CACHE_WRITEBACK`, avoiding the writeback path implicated in
[issue #281](https://github.com/omacom/try-omarchy/issues/281).
[Linux's 9p documentation](https://www.kernel.org/doc/html/latest/filesystems/9p.html)
defines `readahead` as cache mask `0x1`, while `mmap` is `0x5` and includes
writeback. This policy applies regardless of the guest kernel version.

## Background

The issue reports zero-length metadata and NUL-filled reads that can be written
back over host files on an affected kernel with `cache=mmap`. Its reproduction
rate, workload compatibility, and performance measurements are reporter results;
the project's contract tests do not reproduce kernel corruption.

The [Linux 7.2.8 changelog](https://www.kernel.org/pub/linux/kernel/v7.x/ChangeLog-7.2.8)
contains stable commit `9cd92e3392bd`, upstream `c60ae98c5aa6`, which updates
`i_size` and `remote_i_size` after a 9p write extends the server file. The
guest runs Omarchy's own `linux-omarchy` kernel and updates it with
`omarchy update`, so check the running kernel with `uname -r` rather than
inferring it from the Mac app version. The mount policy does not depend on it.

## How the share is mounted

`omarchy-native-mac-share.service` from the `try-omarchy` package mounts the
share before the display manager starts, only when the launcher exported one
(9p mount tag `mac`):

```sh
mount -t 9p -o trans=virtio,version=9p2000.L,msize=1048576,cache=readahead mac /mnt/mac
```

It never retries with `cache=mmap`. A user unit,
`omarchy-native-mac-share-link.service`, links `~/<folder name>` to the
mount at login. The folder name travels in the `tryomarchy.host` credential
as `omarchy.shared_folder_name=<base64url>`.

Verify in an Omarchy terminal:

```sh
findmnt -n -t 9p -o SOURCE,TARGET,OPTIONS /mnt/mac
systemctl status omarchy-native-mac-share.service --no-pager
```

The mount should report source `mac` and `cache=readahead` or `cache=0x1`,
never `cache=mmap` or `cache=0x5`.

**Shared folder > Turn Off** applies to the next launch. Close applications
using the share and shut down Linux cleanly first. An app update does not
change a currently mounted share.

## Compatibility and verification

Writes use the synchronous path, so bulk sequential writes may be slower.
Writable `MAP_SHARED` mappings are unavailable in this mode. Keep SQLite WAL
databases and mmap-based IPC on the guest's local disk. The issue reports Git
and read-only/private mmap compatibility, but those results are not an app-level
validation of every application.

The shared folder has not been verified in the current UEFI guest yet. To
verify it, use a fresh temporary host folder: test repeated extending writes,
immediate stat/read-back, concurrent reads, host-side byte/hash verification,
Git operations, and mmap behavior only in that folder. Contract tests cover the
mount arguments and the launcher's validation of the folder; they do not prove
the kernel race is fixed.
