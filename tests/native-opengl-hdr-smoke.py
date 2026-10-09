#!/usr/bin/env python3
"""Exercise the built Cocoa HDR/SDR runtime with diskless paused HVF machines."""
import argparse
import json
import pathlib
import socket
import subprocess
import tempfile
import time

root = pathlib.Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--qemu', type=pathlib.Path, default=root / 'macos/.build/qemu-gpu-runtime/bin/qemu-system-aarch64')
args = parser.parse_args()
for hdr in (True, False):
    with tempfile.TemporaryDirectory(prefix='omarchy-cgl-smoke-') as temporary:
        directory = pathlib.Path(temporary)
        endpoint = directory / 'qmp.sock'
        logfile = directory / 'qemu.log'
        display = 'cocoa,gl=on,hdr=' + ('on' if hdr else 'off')
        command = [str(args.qemu), '-machine', 'virt', '-accel', 'hvf', '-cpu', 'host',
                   '-m', '128', '-S', '-nodefaults',
                   '-device', 'virtio-gpu-gl-pci,x-omarchy-hdr=' + ('on' if hdr else 'off'),
                   '-display', display, '-qmp', f'unix:{endpoint},server=on,wait=off']
        with logfile.open('w') as output:
            process = subprocess.Popen(command, stdout=output, stderr=subprocess.STDOUT)
        try:
            deadline = time.monotonic() + 15
            client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            while True:
                if process.poll() is not None:
                    raise RuntimeError(f'QEMU exited during startup: {logfile.read_text()}')
                try:
                    client.connect(str(endpoint))
                    break
                except (FileNotFoundError, ConnectionRefusedError):
                    if time.monotonic() >= deadline:
                        raise TimeoutError('QMP startup')
                    time.sleep(0.02)
            client.settimeout(5)
            stream = client.makefile('rwb', buffering=0)
            assert 'QMP' in json.loads(stream.readline())
            def execute(name):
                stream.write((json.dumps({'execute': name}) + '\n').encode())
                while True:
                    reply = json.loads(stream.readline())
                    if 'return' in reply:
                        return reply['return']
                    if 'error' in reply:
                        raise RuntimeError(reply)
            execute('qmp_capabilities')
            assert execute('query-status')['status'] == 'prelaunch'
            if hdr:
                while 'native OpenGL layer: 16-bit float' not in logfile.read_text():
                    if process.poll() is not None or time.monotonic() >= deadline:
                        raise RuntimeError(f'Float layer not ready: {logfile.read_text()}')
                    time.sleep(0.02)
            execute('quit')
            assert process.wait(timeout=10) == 0, logfile.read_text()
            stream.close()
            client.close()
            content = logfile.read_text()
            if hdr:
                assert 'native OpenGL HDR initialized' in content
                assert 'requires gl=es' not in content
            else:
                assert 'native OpenGL HDR initialized' not in content
            print(f'{display}: startup, QMP status, clean exit PASS')
            for line in content.splitlines():
                if '[cocoa-gl-hdr]' in line:
                    print(line)
        finally:
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=10)
