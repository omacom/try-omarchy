# Guest memory reclamation

The selected memory remains the guest's RAM capacity. The launcher enables
`virtio-balloon-pci,free-page-reporting=on`; it does not inflate the balloon or
change Linux's memory limit. Linux's page-reporting worker temporarily removes
free blocks from its allocator and returns them after QEMU acknowledges the
report. A guest kernel without this feature can still boot but cannot reclaim
host memory through this path.

On Darwin, QEMU's usual `MADV_DONTNEED` does not release guest-dirtied memory.
The checksum-pinned `qemu-hvf-free-page-reclaim.patch` handles these reports in
HVF using public APIs:

1. Validate the complete range against the system memory map and host page size.
2. Remove its stage-2 mapping with `hv_vm_unmap`.
3. Replace the host backing at the same address with private anonymous
   demand-zero memory using `mmap(MAP_FIXED)`.
4. Restore the stage-2 mapping before acknowledging the report to Linux.

This retains the host virtual addresses used by QEMU and lets the guest fault
in new physical pages on demand. It avoids Darwin's private
`MADV_FREE_REUSABLE` advice and its persistent reusable-accounting state.
The tradeoff is host VM-map fragmentation and fault-in cost when memory is
reused. Linux batches reports into free blocks rather than sending every small
allocation/free operation to the host.

The implementation requires the QEMU global lock and accepts only writable,
QEMU-owned, private anonymous RAM. It skips file-backed, shared, external,
device, ROM, unaligned, partial, and dirty-logged mappings, and reports through
an intervening IOMMU. The existing virtio checks also inhibit reporting while
memory cannot be discarded or nonzero page poisoning is active. Once backing
replacement begins, failures abort rather than resuming a guest with a broken
memory mapping. Runtime staging and launch reject binaries without this fix.

Reclamation is asynchronous. Linux file cache, allocated application memory,
and fragmented free pages can remain resident. The VM also has host-side device
and graphics overhead. Therefore `selected RAM - guest used RAM` is not an
exact prediction of macOS memory returned, and host-memory allocation limits
remain in place. The feature needs an updated runtime and a VM restart, not a
new guest disk.

## Validation

`make test` compiles the actual patched reclaim function with controlled
hypervisor calls and real anonymous mappings. It checks excluded mappings,
operation ordering, neighboring data, repeated reuse, and failure handling.
The launcher contract checks that reporting is enabled and stale runtimes are
rejected.

For an end-to-end test on Apple Silicon, build the runtime and use an existing
factory artifact directory:

```sh
python3 macos/Tests/hvf-memory-reclaim-smoke.py \
  --qemu macos/.build/qemu-gpu-runtime/bin/qemu-system-aarch64 \
  --guest-dir dist/guest
```

The test uses a 3 GiB headless VM and QEMU's disposable disk snapshot mode. It
boots a shell instead of the desktop, without networking or host shares, and
never opens a persistent user VM. A guest Python process touches and verifies
768 MiB, releases it, and repeats three times while retaining a live sentinel.
The host measures `proc_pid_rusage` physical footprint and requires at least
512 MiB returned after each burst within 20 seconds. Add `--reporting off` for
a control run; the control prints measurements without requiring reclamation.
On a Mac supporting nested virtualization, add `--nested` to exercise the
production EL2 configuration as well.

An Apple Silicon run on macOS 27.0 returned 728.3, 742.3, and 718.3 MiB across
the three cycles with reporting enabled. The same runtime with reporting
disabled returned 0.0, 0.0, and 0.2 MiB over the 20-second observation windows.
All guest data checks passed. These measurements validate this host and workload;
they are not a promise of a fixed reclaim ratio for desktop workloads.
The test host does not support nested virtualization, so EL2 remains unverified.
