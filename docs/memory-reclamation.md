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

An end-to-end smoke test, `macos/Tests/hvf-memory-reclaim-smoke.py`, booted
the earlier direct-boot factory into a shell, touched and released 768 MiB
three times, and measured the QEMU process's physical footprint. An Apple
Silicon run on macOS 27.0 returned 728.3, 742.3, and 718.3 MiB across the
three cycles with reporting enabled; the same runtime with reporting disabled
returned 0.0, 0.0, and 0.2 MiB. These measurements validate that host and
workload; they are not a promise of a fixed reclaim ratio for desktop
workloads. That test has not been ported to the UEFI factory yet. The current
guest's `linux-omarchy` kernel enables balloon page reporting, but reclamation
has not been measured with it. EL2 remains unverified.
