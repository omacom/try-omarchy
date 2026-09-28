#!/usr/bin/env python3
"""Compile the patched hvf_set_phys_mem() against a fake HVF and replay mappings."""
from pathlib import Path
import hashlib
import os
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
PATCH = ROOT / 'macos/patches/qemu-hvf-mapped-sections.patch'
BUILDER = ROOT / 'macos/build-qemu-gpu-runtime.sh'

# Stand-ins for the QEMU and Hypervisor.framework pieces the function uses.
# The fake HVF refuses to unmap a range it does not hold, which macOS 26
# turns into EXC_GUARD (DEALLOC_GAP), and reports whether the flash range is
# mapped after each step: while pflash is out of romd_mode it must trap.
HARNESS = r'''
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Just enough of GLib's hash table for a set of 64-bit keys, so the test
 * needs no GLib development files. */
typedef void *gpointer;
typedef const void *gconstpointer;
typedef unsigned int guint;
typedef int gboolean;
typedef size_t gsize;
typedef guint (*GHashFunc)(gconstpointer);
typedef gboolean (*GEqualFunc)(gconstpointer, gconstpointer);
typedef void (*GDestroyNotify)(gpointer);
typedef struct GHashTable {
    gpointer keys[64];
    int count;
    GEqualFunc equal;
    GDestroyNotify destroy;
} GHashTable;

static guint g_int64_hash(gconstpointer v) { return (guint)*(const uint64_t *)v; }
static gboolean g_int64_equal(gconstpointer a, gconstpointer b)
{
    return *(const uint64_t *)a == *(const uint64_t *)b;
}
static void g_free(gpointer p) { free(p); }
static gpointer g_memdup2(gconstpointer mem, gsize size)
{
    gpointer copy = malloc(size);
    memcpy(copy, mem, size);
    return copy;
}
static GHashTable *g_hash_table_new_full(GHashFunc hash, GEqualFunc equal,
                                         GDestroyNotify key_destroy, GDestroyNotify value_destroy)
{
    GHashTable *table = calloc(1, sizeof(*table));
    table->equal = equal;
    table->destroy = key_destroy;
    return table;
}
static gboolean g_hash_table_add(GHashTable *table, gpointer key)
{
    table->keys[table->count++] = key;
    return 1;
}
static gboolean g_hash_table_remove(GHashTable *table, gconstpointer key)
{
    for (int i = 0; i < table->count; i++) {
        if (table->equal(table->keys[i], key)) {
            table->destroy(table->keys[i]);
            table->keys[i] = table->keys[--table->count];
            return 1;
        }
    }
    return 0;
}

typedef int hv_return_t;
typedef uint64_t hv_memory_flags_t;
#define HV_SUCCESS 0
#define HV_ERROR 1
#define HV_MEMORY_READ 1
#define HV_MEMORY_WRITE 2
#define HV_MEMORY_EXEC 4
#define QEMU_IS_ALIGNED(n, m) (((n) % (m)) == 0)
#define int128_get64(v) (v)
#define trace_hvf_vm_unmap(...)
#define trace_hvf_vm_map(...)

typedef struct MemoryRegion {
    bool ram, readonly, rom_device, romd_mode;
    char backing[4096];
} MemoryRegion;

typedef struct MemoryRegionSection {
    MemoryRegion *mr;
    uint64_t offset_within_address_space, offset_within_region, size;
} MemoryRegionSection;

static bool memory_region_is_ram(MemoryRegion *mr) { return mr->ram; }
static bool memory_region_is_romd(MemoryRegion *mr) { return mr->rom_device && mr->romd_mode; }
static void *memory_region_get_ram_ptr(MemoryRegion *mr) { return mr->backing; }
static uint64_t qemu_real_host_page_size(void) { return 16384; }

#define MAX_MAPPINGS 8
static uint64_t mapped_gpa[MAX_MAPPINGS];
static int mapped_count;
static int failures;

static int find_mapping(uint64_t gpa)
{
    for (int i = 0; i < mapped_count; i++) {
        if (mapped_gpa[i] == gpa) {
            return i;
        }
    }
    return -1;
}

static hv_return_t hv_vm_map(void *mem, uint64_t gpa, uint64_t size, hv_memory_flags_t flags)
{
    mapped_gpa[mapped_count++] = gpa;
    return HV_SUCCESS;
}

static hv_return_t hv_vm_unmap(uint64_t gpa, uint64_t size)
{
    int i = find_mapping(gpa);
    if (i < 0) {
        printf("UNMAP-UNMAPPED ");
        return HV_ERROR;
    }
    mapped_gpa[i] = mapped_gpa[--mapped_count];
    return HV_SUCCESS;
}

static void assert_hvf_ok(hv_return_t ret)
{
    failures += ret != HV_SUCCESS;
}

@@FUNCTION@@

static void step(const char *name, MemoryRegionSection *section, bool add)
{
    hvf_set_phys_mem(section, add);
    printf("%s:%s ", name, find_mapping(section->offset_within_address_space) >= 0 ? "mapped" : "trap");
}

int main(void)
{
    /* virt's pflash at guest address 0: a 64 MiB ROM device. */
    MemoryRegion flash = { .rom_device = true, .readonly = true, .romd_mode = true };
    MemoryRegionSection flash_section = { .mr = &flash, .size = 64 << 20 };

    step("boot", &flash_section, true);
    /* A write command leaves romd_mode before the flat view is updated. */
    flash.romd_mode = false;
    step("del-romd", &flash_section, false);
    step("add-io", &flash_section, true);
    /* A read-array command returns to romd_mode the same way. */
    flash.romd_mode = true;
    step("del-io", &flash_section, false);
    step("add-romd", &flash_section, true);
    /* Removing the device unmaps the ROMD mapping. */
    step("remove", &flash_section, false);

    /* A RAM section that is not page aligned is never mapped. */
    MemoryRegion ram = { .ram = true };
    MemoryRegionSection odd = { .mr = &ram, .offset_within_address_space = 0x1000, .size = 0x1000 };
    step("add-unaligned", &odd, true);
    step("del-unaligned", &odd, false);

    printf("failures=%d\n", failures);
    return 0;
}
'''


def patched_source() -> str:
    lines = PATCH.read_text().split('\n@@', 1)[1].splitlines()
    source = '\n'.join(line[1:] for line in lines if line[:1] in (' ', '+'))
    start = source.index('static GHashTable *hvf_mapped_sections;')
    end = source.index('\n}\n', source.index('static void hvf_set_phys_mem(')) + 3
    return source[start:end]


class MappedSectionsTests(unittest.TestCase):
    def test_pinned_and_applied_after_memory_reclaim(self):
        builder = BUILDER.read_text()
        digest = re.search(r'^mapped_sections_patch_sha256=([a-f0-9]{64})$', builder, re.M)
        self.assertEqual(hashlib.sha256(PATCH.read_bytes()).hexdigest(), digest[1])
        self.assertIn('"$mapped_sections_patch" "$mapped_sections_patch_sha256"', builder)
        reclaim = builder.index('patch -d "$source_dir" -p1 -f -i "$memory_reclaim_patch"')
        mapped = builder.index('patch -d "$source_dir" -p1 -f -i "$mapped_sections_patch"')
        self.assertLess(reclaim, mapped)

    def test_only_mapped_sections_are_unmapped(self):
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            (work / 'hvf.c').write_text(HARNESS.replace('@@FUNCTION@@', patched_source()))
            subprocess.run([os.environ.get('CC', 'cc'), '-Wall', '-Werror', '-Wno-unused-parameter',
                            '-o', str(work / 'hvf'), str(work / 'hvf.c')], check=True)
            output = subprocess.run([str(work / 'hvf')], check=True, capture_output=True,
                                    text=True).stdout.strip()
        self.assertEqual(
            output,
            'boot:mapped del-romd:trap add-io:trap del-io:trap add-romd:mapped remove:trap '
            'add-unaligned:trap del-unaligned:trap failures=0',
        )


if __name__ == '__main__':
    unittest.main()
