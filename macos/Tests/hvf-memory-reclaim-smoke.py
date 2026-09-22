#!/usr/bin/env python3
"""Opt-in Apple Silicon integration test using a disposable factory-disk snapshot.

python3 macos/Tests/hvf-memory-reclaim-smoke.py \
  --qemu macos/.build/qemu-gpu-runtime/bin/qemu-system-aarch64 \
  --guest-dir dist/guest

Repeat with --reporting off as a control. Never boots or modifies a user's VM.
"""
import argparse
import ctypes
import json
import os
from pathlib import Path
import re
import select
import subprocess
import tempfile
import time


class Usage(ctypes.Structure):
    _fields_ = [('uuid', ctypes.c_uint8 * 16)] + [
        (name, ctypes.c_uint64) for name in (
            'user', 'system', 'idle_wakeups', 'interrupt_wakeups', 'pageins',
            'wired', 'resident', 'footprint', 'start', 'exit')]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--qemu', required=True, type=Path)
    parser.add_argument('--guest-dir', required=True, type=Path)
    parser.add_argument('--reporting', choices=('on', 'off'), default='on')
    parser.add_argument('--nested', action='store_true', help='Test EL2 on a Mac supporting nested virtualization')
    args = parser.parse_args()
    guest = args.guest_dir.resolve()
    libproc = ctypes.CDLL('/usr/lib/libproc.dylib', use_errno=True)
    libproc.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
    libproc.proc_pid_rusage.restype = ctypes.c_int

    # PID 1 is only a shell. No provisioning, desktop, networking or host shares.
    machine = 'virt,gic-version=3' + (',virtualization=on' if args.nested else '')
    command = [str(args.qemu.resolve()), '-machine', machine,
               '-accel', 'hvf', '-cpu', 'host,pmu=off', '-smp', '4', '-m', '3072M',
               '-nodefaults', '-display', 'none', '-monitor', 'none', '-serial', 'stdio',
               '-kernel', str(guest / 'vmlinuz-linux'),
               '-initrd', str(guest / 'initramfs-linux.img'),
               '-append', 'root=/dev/vda rw rootwait console=ttyAMA0 init=/bin/bash loglevel=4',
               '-drive', f'if=none,id=root,file={guest / "rootfs.ext4"},format=raw,snapshot=on',
               '-device', 'virtio-blk-pci,drive=root',
               '-device', f'virtio-balloon-pci,free-page-reporting={args.reporting}']
    with tempfile.TemporaryDirectory(prefix='omarchy-memory-smoke-') as scratch:
        env = {**os.environ, 'TMPDIR': scratch}
        process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                   stderr=subprocess.STDOUT, env=env, bufsize=0)
        pending = bytearray()
        transcript = bytearray()

        def wait_for(token, timeout=60):
            nonlocal pending
            deadline = time.monotonic() + timeout
            token = token.replace(b'\r', b'')
            while True:
                plain = re.sub(rb'\x1b\[[0-?]*[ -/]*[@-~]', b'', pending).replace(b'\r', b'')
                if token in plain:
                    pending.clear()
                    return
                if time.monotonic() >= deadline or process.poll() is not None:
                    raise RuntimeError(f'VM did not reach {token!r}:\n' + transcript[-12000:].decode(errors='replace'))
                readable, _, _ = select.select([process.stdout], [], [], 0.2)
                if readable:
                    data = os.read(process.stdout.fileno(), 65536)
                    pending.extend(data)
                    transcript.extend(data)

        def send(text):
            process.stdin.write(text.encode() + b'\n')
            process.stdin.flush()

        def footprint():
            usage = Usage()
            if libproc.proc_pid_rusage(process.pid, 0, ctypes.byref(usage)):
                raise OSError(ctypes.get_errno(), 'proc_pid_rusage')
            return usage.footprint / 1024**2

        try:
            wait_for(b']# ')
            send('mount -t proc proc /proc; mount -t sysfs sysfs /sys; modprobe virtio_balloon; echo READY_FOR_MEMORY_TEST')
            # Match a whole output line, not the echoed command.
            wait_for(b'\r\nREADY_FOR_MEMORY_TEST\r\n')
            workload = '''import mmap,sys
sentinel=bytearray(b'z'*(32*1024*1024))
print('BASELINE',flush=True)
sys.stdin.readline()
for cycle in range(3):
 m=mmap.mmap(-1,768*1024*1024,flags=mmap.MAP_PRIVATE|mmap.MAP_ANONYMOUS)
 block=bytes([cycle+65])*(1024*1024)
 for offset in range(0,len(m),len(block)): m[offset:offset+len(block)]=block
 for offset in range(0,len(m),len(block)): assert m[offset:offset+len(block)]==block
 assert sentinel==b'z'*len(sentinel)
 print('TOUCHED'+str(cycle),flush=True)
 sys.stdin.readline()
 m.close()
 print('FREED'+str(cycle),flush=True)
 sys.stdin.readline()
assert sentinel==b'z'*len(sentinel)
print('MEMORY_TEST_PASS',flush=True)
'''
            send('python3 -u -c "exec(bytes.fromhex(\'' + workload.encode().hex() + '\'))"')
            wait_for(b'\r\nBASELINE\r\n')
            results = {'reporting': args.reporting, 'nested': args.nested,
                       'baseline_mib': round(footprint(), 1), 'cycles': []}
            for cycle in range(3):
                send('')
                wait_for(f'\r\nTOUCHED{cycle}\r\n'.encode())
                peak = footprint()
                send('')
                wait_for(f'\r\nFREED{cycle}\r\n'.encode())
                # Kernel page reporting is asynchronous. Use a bounded condition,
                # with a minimum observation period for the disabled control.
                deadline = time.monotonic() + 20
                released = footprint()
                while time.monotonic() < deadline:
                    released = min(released, footprint())
                    if args.reporting == 'on' and peak - released >= 512:
                        break
                    time.sleep(0.2)
                result = {'peak_mib': round(peak, 1), 'freed_mib': round(released, 1),
                          'reclaimed_mib': round(peak - released, 1)}
                results['cycles'].append(result)
                print(json.dumps({'cycle': cycle, **result}), flush=True)
                if args.reporting == 'on' and peak - released < 512:
                    raise AssertionError(f'Expected at least 512 MiB returned from a 768 MiB burst: {result}')
            send('')
            wait_for(b'\r\nMEMORY_TEST_PASS\r\n')
            print(json.dumps(results, indent=2))
        finally:
            process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()


if __name__ == '__main__':
    main()
