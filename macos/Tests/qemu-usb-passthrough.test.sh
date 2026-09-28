#!/bin/bash

set -euo pipefail

test_dir=$(cd "$(dirname "$0")" && pwd -P)
macos_dir=$(cd "$test_dir/.." && pwd -P)
launcher="$macos_dir/run-qemu-gpu.sh"
wrapper="$macos_dir/open-qemu-gpu.sh"
runtime_manifest="$macos_dir/runtime-files.txt"
runtime_builder="$macos_dir/build-qemu-gpu-runtime.sh"
bottles="$macos_dir/pinned-runtime-bottles.sh"

fail() {
  printf 'qemu-usb-passthrough.test: %s\n' "$*" >&2
  exit 1
}

# Passthrough must stay strictly opt-in: the unconditional argument list that
# every Mac boots stays free of any USB controller or host device.
qemu_arguments=$(sed -n '/^qemu_args=(/,/^)/p' "$launcher")
[[ -n $qemu_arguments ]] || fail 'could not find the QEMU argument list'
[[ $qemu_arguments != *usb* ]] || {
  fail 'the default VM must not attach a USB controller or host device'
}

# The opt-in adds exactly one xHCI controller and one host device, both bound
# to the value of the documented variable.
grep -Fxq 'usb_host_properties=${OMARCHY_QEMU_GPU_USB_HOST:-}' "$launcher" || {
  fail 'the launcher must read the passthrough opt-in from OMARCHY_QEMU_GPU_USB_HOST'
}
grep -Fxq "    -device 'qemu-xhci,id=omarchy-usb,streams=off'" "$launcher" || {
  fail 'the opt-in must add one xHCI controller without bulk streams'
}
grep -Fxq \
  '    -device "usb-host,bus=omarchy-usb.0,id=omarchy-usb-host,$usb_host_properties"' \
  "$launcher" || {
  fail 'the opt-in must attach the host device to that controller'
}

# An unvalidated value would smuggle arbitrary QEMU options onto the command
# line, so the launcher rejects anything but usb-host properties.
grep -Fq '^[a-z]+=[0-9A-Fa-fx.]+(,[a-z]+=[0-9A-Fa-fx.]+)*$' "$launcher" || {
  fail 'the launcher must validate OMARCHY_QEMU_GPU_USB_HOST before using it'
}

# The opt-in is useless unless the staged QEMU actually carries libusb.
grep -Fxq '      --enable-libusb \' "$runtime_builder" || {
  fail 'the runtime build must enable libusb'
}
grep -Fq 'PINNED_LIBUSB_ARCHIVE=libusb--1.0.30.arm64_sequoia.bottle.tar.gz' "$bottles" || {
  fail 'the pinned bottle set must carry libusb'
}
grep -Fxq 'lib/libusb-1.0.0.dylib' "$runtime_manifest" || {
  fail 'the runtime manifest must stage libusb beside QEMU'
}

# The app pins hostbus=0 for devices behind the first controller, which
# upstream QEMU would read as "any bus"; the patch and its launch check go
# together.
grep -Fxq 'patch -d "$source_dir" -p1 -f -i "$usb_exact_bus_patch"' "$runtime_builder" || {
  fail 'the runtime build must apply the USB exact-bus patch'
}
grep -Fq "grep -aFq 'exact bus 0 matching'" "$launcher" || {
  fail 'the launcher must refuse a QEMU without exact USB bus matching'
}
grep -Fq 'hostbus out of range (exact bus 0 matching)' \
  "$macos_dir/patches/qemu-usb-host-exact-bus.patch" || {
  fail 'the exact-bus patch must carry the marker the launcher checks'
}

# `open` hands the app the launchd environment, so the wrapper must forward the
# opt-in explicitly or `make run` would silently ignore it.
grep -Fxq '  usb_environment=(--env "OMARCHY_QEMU_GPU_USB_HOST=$OMARCHY_QEMU_GPU_USB_HOST")' \
  "$wrapper" || {
  fail 'the development wrapper must forward the passthrough opt-in'
}

printf 'qemu-usb-passthrough.test: opt-in host USB passthrough contract: PASS\n'
