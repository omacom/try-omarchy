#!/usr/bin/env python3
"""Exercise the shipped reclaim function with real mmap and controlled HVF calls."""
from pathlib import Path
import hashlib
import os
import re
import shlex
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
PATCH = ROOT / 'macos/patches/qemu-hvf-free-page-reclaim.patch'


class MemoryReclaimTests(unittest.TestCase):
    def test_pinned_patch(self):
        builder = (ROOT / 'macos/build-qemu-gpu-runtime.sh').read_text()
        digest = re.search(r'^memory_reclaim_patch_sha256=([a-f0-9]{64})$', builder, re.M)
        self.assertEqual(hashlib.sha256(PATCH.read_bytes()).hexdigest(), digest[1])
        self.assertIn('"$memory_reclaim_patch" "$memory_reclaim_patch_sha256"', builder)
        self.assertIn('patch -d "$source_dir" -p1 -f -i "$memory_reclaim_patch"', builder)

    def test_reclaims_only_reported_private_ram_and_preserves_neighbors(self):
        added = '\n'.join(line[1:] for line in PATCH.read_text().splitlines()
                          if line.startswith('+') and not line.startswith('+++'))
        # The first occurrence is the non-HVF stub; compile the actual implementation.
        start = added.index('void hvf_report_free_pages(hwaddr gpa, void *host, size_t size)\n{\n    MemoryRegionSection')
        end = added.index('    memory_region_unref(mr);', added.index('    assert_hvf_ok(hv_vm_map(', start))
        function = added[start:end] + '    memory_region_unref(mr);\n}\n'
        source = r'''
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <sys/mman.h>
#include <unistd.h>
typedef uint64_t hwaddr;
typedef unsigned hv_memory_flags_t;
enum { HV_MEMORY_READ = 1, HV_MEMORY_WRITE = 2, HV_MEMORY_EXEC = 4,
       RAM_SHARED = 1, RAM_PREALLOC = 2 };
typedef struct { int fd; unsigned flags; } RAMBlock;
typedef struct {
    bool ram, readonly, rom_device, device;
    unsigned dirty;
    RAMBlock *ram_block;
    char *host;
} MemoryRegion;
typedef struct {
    MemoryRegion *mr;
    uint64_t size, offset_within_region, offset_within_address_space;
} MemoryRegionSection;
static RAMBlock block = { .fd = -1 };
static MemoryRegion region = { .ram = true, .ram_block = &block };
static MemoryRegionSection section;
static unsigned calls, refs;
static int failure;
static void *expected_host;
static size_t expected_size;
static hwaddr expected_gpa = 0x40200000;
#define QEMU_IS_ALIGNED(value, alignment) (((value) & ((alignment) - 1)) == 0)
#define int128_get64(value) (value)
#define assert_hvf_ok(value) assert((value) == 0)
#define error_report(...) fprintf(stderr, __VA_ARGS__)
static bool bql_locked(void) { return true; }
static size_t qemu_real_host_page_size(void) { return (size_t)getpagesize(); }
static MemoryRegion *get_system_memory(void) { return &region; }
static MemoryRegionSection memory_region_find(MemoryRegion *mr, hwaddr gpa, size_t size)
{ (void)mr; (void)gpa; (void)size; if (section.mr) refs++; return section; }
static void memory_region_unref(MemoryRegion *mr) { assert(mr && refs); refs--; }
static bool memory_region_is_ram(MemoryRegion *mr) { return mr->ram; }
static bool memory_region_is_ram_device(MemoryRegion *mr) { return mr->device; }
static unsigned memory_region_get_dirty_log_mask(MemoryRegion *mr) { return mr->dirty; }
static void *memory_region_get_ram_ptr(MemoryRegion *mr) { return mr->host; }
static int hv_vm_unmap(hwaddr gpa, size_t size)
{
    assert(calls == 0 && gpa == expected_gpa && size == expected_size);
    calls++;
    return failure == 1 ? -1 : 0;
}
static int hv_vm_map(void *host, hwaddr gpa, size_t size, hv_memory_flags_t flags)
{
    assert(calls == 1 && gpa == expected_gpa && host == expected_host);
    assert(size == expected_size && flags == 7);
    /* Backing must already be zeroed before it becomes guest-accessible. */
    for (size_t i = 0; i < size; i++) assert(((char *)host)[i] == 0);
    calls++;
    return failure == 2 ? -1 : 0;
}
static void *reclaim_mmap(void *host, size_t size, int prot, int flags, int fd, off_t offset)
{
    assert(calls == 1); /* The old stage-2 mapping must be gone first. */
    if (failure == 3) { errno = ENOMEM; return MAP_FAILED; }
    return mmap(host, size, prot, flags, fd, offset);
}
#define mmap reclaim_mmap
FUNCTION
#undef mmap
static void rejected(void)
{
    hvf_report_free_pages(expected_gpa, expected_host, expected_size);
    assert(calls == 0 && refs == 0);
    assert(((unsigned char *)expected_host)[0] == 0xa5);
}
int main(int argc, char **argv)
{
    size_t page = getpagesize();
    char *ram = mmap(NULL, page * 4, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    assert(ram != MAP_FAILED);
    memset(ram, 0xa5, page * 4);
    region.host = ram;
    expected_host = ram + page;
    expected_size = page * 2;
    section = (MemoryRegionSection){ &region, expected_size, page, expected_gpa };
    if (argc == 2) failure = atoi(argv[1]);
    if (!failure) {
        hvf_report_free_pages(expected_gpa, expected_host, 0);
        hvf_report_free_pages(expected_gpa + 1, expected_host, expected_size);
        hvf_report_free_pages(expected_gpa, (char *)expected_host + 1, expected_size);
        hvf_report_free_pages(expected_gpa, expected_host, expected_size - 1);
        assert(calls == 0 && refs == 0);
        section.mr = NULL; rejected(); section.mr = &region;
        region.ram = false; rejected(); region.ram = true;
        region.readonly = true; rejected(); region.readonly = false;
        region.rom_device = true; rejected(); region.rom_device = false;
        region.device = true; rejected(); region.device = false;
        region.dirty = 1; rejected(); region.dirty = 0;
        region.ram_block = NULL; rejected(); region.ram_block = &block;
        block.fd = 3; rejected(); block.fd = -1;
        block.flags = RAM_SHARED; rejected(); block.flags = RAM_PREALLOC; rejected(); block.flags = 0;
        section.size -= page; rejected(); section.size += page;
        section.offset_within_address_space += page; rejected(); section.offset_within_address_space -= page;
        section.offset_within_region = 0; rejected(); section.offset_within_region = page;
    }
    for (int cycle = 0; cycle < 8; cycle++) {
        calls = 0;
        hvf_report_free_pages(expected_gpa, expected_host, expected_size);
        assert(calls == 2 && refs == 0);
        for (size_t i = 0; i < page; i++) {
            assert((unsigned char)ram[i] == 0xa5);
            assert((unsigned char)ram[page * 3 + i] == 0xa5);
        }
        /* The full range can be reused after every report. */
        memset(expected_host, 0xa5, expected_size);
    }
    assert(munmap(ram, page * 4) == 0);
    return 0;
}
'''.replace('FUNCTION', function)
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            c = work / 'reclaim.c'
            binary = work / 'reclaim'
            c.write_text(source)
            subprocess.run(shlex.split(os.environ.get('CC', 'cc')) + [
                '-std=gnu11', '-Wall', '-Wextra', '-Werror', str(c), '-o', str(binary)
            ], check=True)
            subprocess.run([str(binary)], check=True)
            for failure in ('1', '2', '3'):
                result = subprocess.run([str(binary), failure], capture_output=True)
                self.assertLess(result.returncode, 0, 'A broken backing/mapping must fail closed')


if __name__ == '__main__':
    unittest.main()
