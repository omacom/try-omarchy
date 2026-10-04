#!/usr/bin/env python3
"""Opt-in real-kernel battery and UPower test in a disposable factory snapshot.

python3 macos/Tests/battery-upower-smoke.py \
  --qemu macos/.build/qemu-gpu-runtime/bin/qemu-system-aarch64 \
  --guest-dir dist/guest

Builds the current battery module against the factory's matching kernel headers,
then checks sysfs and UPower's battery and display devices. Requires Apple Silicon
macOS/HVF plus a built factory with gcc, dbus, python-dbus and UPower. The factory
image is opened with snapshot=on; no user VM, network or personal shares are used.
"""
import argparse
import os
from pathlib import Path
import re
import select
import shutil
import subprocess
import tempfile
import time


GUEST_TEST = r"""#!/usr/bin/env python3
import dbus
import json
import math
import pathlib
import time

state_path = pathlib.Path('/sys/devices/platform/try-omarchy-battery/state')
bus = dbus.SystemBus()
service = 'org.freedesktop.UPower'
prefix = '/org/freedesktop/UPower/devices/'


def props(path):
    interface = dbus.Interface(bus.get_object(service, path), 'org.freedesktop.DBus.Properties')
    return dict(interface.GetAll('org.freedesktop.UPower.Device'))


def snapshot(status='discharging', capacity=57, ac=0, current=1000000):
    return dict(present=1, status=status, capacity=capacity, ac=ac,
                time_to_empty=-1, time_to_full=-1, charge_limit=80,
                charge_now=capacity * 50000, charge_full=5000000,
                charge_full_design=6000000, voltage_now=12000000,
                cycle_count=213, current_now=current)


def apply(name, state, expected_state, watts):
    started = time.monotonic()
    state_path.write_text(' '.join(f'{key}={value}' for key, value in state.items()) + '\n')
    status = pathlib.Path('/sys/class/power_supply/BAT0/status').read_text().strip()
    statuses = {'charging': 'Charging', 'discharging': 'Discharging',
                'not-charging': 'Not charging', 'full': 'Full'}
    assert status == statuses[state['status']], status
    current = int(pathlib.Path('/sys/class/power_supply/BAT0/current_now').read_text())
    assert current == state['current_now'], current

    # UPower 1.91.4 suppresses energy-rate for ten seconds after an AC change,
    # then refreshes on the next event or poll (up to thirty seconds later).
    # State and percentage must still arrive promptly during that interval.
    deadline = started + 45
    last = None
    state_latency = None
    while time.monotonic() < deadline:
        try:
            battery = props(prefix + 'battery_BAT0')
            display = props(prefix + 'DisplayDevice')
            mains = props(prefix + 'line_power_ADP0')
            state_matches = (
                all(int(device.get('State', 0)) == expected_state and
                    int(device.get('Percentage', 0)) == state['capacity']
                    for device in (battery, display)) and
                bool(mains.get('Online')) == bool(state['ac']))
            if state_matches and state_latency is None:
                state_latency = time.monotonic() - started
                assert state_latency < 2, (name, 'state update took too long', state_latency)
                print(json.dumps({'case': name, 'state_latency_seconds': round(state_latency, 3),
                                  'power_pending': float(battery.get('EnergyRate', -1))}), flush=True)
            if state_matches and all(
                math.isclose(float(device.get('EnergyRate', -1)), watts, abs_tol=0.001)
                for device in (battery, display)
            ):
                print(json.dumps({'case': name, 'latency_seconds': round(time.monotonic() - started, 3),
                                  'sysfs_status': status, 'upower_state': int(battery['State']),
                                  'percentage': float(battery['Percentage']),
                                  'watts': float(battery['EnergyRate']),
                                  'ac': bool(mains['Online'])}), flush=True)
                return
            last = {'battery': battery, 'display': display, 'mains': mains}
        except dbus.exceptions.DBusException as error:
            last = str(error)
        time.sleep(0.02)
    raise AssertionError(f'{name}: expected state={expected_state} watts={watts}, observed {last}')


apply('discharging_unknown_time', snapshot(), 2, 12)
apply('adapter_connected_same_percentage', snapshot('not-charging', ac=1, current=0), 5, 0)
apply('charging_begins_same_percentage', snapshot('charging', ac=1, current=3000000), 1, 36)
apply('charge_level_changes', snapshot('charging', capacity=58, ac=1, current=3000000), 1, 36)
apply('charging_power_changes', snapshot('charging', capacity=58, ac=1, current=2000000), 1, 24)
apply('charger_unplugged', snapshot('discharging', capacity=58, ac=0, current=1000000), 2, 12)
apply('charging_held', snapshot('not-charging', capacity=58, ac=1, current=0), 5, 0)
apply('full', snapshot('full', capacity=100, ac=1, current=0), 4, 0)
state_path.write_text('present=0 ac=1\n')
deadline = time.monotonic() + 5
while time.monotonic() < deadline:
    if not pathlib.Path('/sys/class/power_supply/BAT0').exists():
        break
    time.sleep(0.02)
else:
    raise AssertionError('Battery was not removed')
apply('battery_reappears', snapshot(), 2, 12)
print('BATTERY_TRANSITIONS_PASS', flush=True)
"""


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--qemu', required=True, type=Path)
    parser.add_argument('--guest-dir', required=True, type=Path)
    args = parser.parse_args()
    guest = args.guest_dir.resolve()
    repository = Path(__file__).resolve().parents[2]
    module_source = repository / 'guest/native-module/try-omarchy-battery'
    for name in ('rootfs.ext4', 'vmlinuz-linux', 'initramfs-linux.img'):
        if not (guest / name).is_file():
            parser.error(f'Factory artifact is missing: {guest / name}')

    with tempfile.TemporaryDirectory(prefix='omarchy-battery-smoke-') as scratch:
        # Only these copied test inputs are visible through the read-only share.
        stage = Path(scratch) / 'sources'
        shutil.copytree(module_source, stage)
        (stage / 'test.py').write_text(GUEST_TEST)
        command = [str(args.qemu.resolve()), '-machine', 'virt,gic-version=3',
                   '-accel', 'hvf', '-cpu', 'host,pmu=off', '-smp', '2', '-m', '2048M',
                   '-nodefaults', '-display', 'none', '-monitor', 'none', '-serial', 'stdio',
                   '-kernel', str(guest / 'vmlinuz-linux'),
                   '-initrd', str(guest / 'initramfs-linux.img'),
                   '-append', 'root=/dev/vda rw rootwait console=ttyAMA0 init=/bin/bash loglevel=4',
                   '-drive', f'if=none,id=root,file={guest / "rootfs.ext4"},format=raw,snapshot=on',
                   '-device', 'virtio-blk-pci,drive=root',
                   '-fsdev', f'local,id=source,path={stage},security_model=none,readonly=on',
                   '-device', 'virtio-9p-pci,fsdev=source,mount_tag=battery-source,romfile=']
        process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                   stderr=subprocess.STDOUT, env={**os.environ, 'TMPDIR': scratch},
                                   bufsize=0)
        pending = bytearray()
        transcript = bytearray()

        def wait_for(token, timeout=60):
            deadline = time.monotonic() + timeout
            while True:
                plain = re.sub(rb'\x1b\[[0-?]*[ -/]*[@-~]', b'', pending).replace(b'\r', b'')
                if token in plain:
                    pending.clear()
                    return plain.decode(errors='replace')
                if time.monotonic() >= deadline or process.poll() is not None:
                    raise RuntimeError(f'VM did not reach {token!r}:\n' +
                                       transcript[-16000:].decode(errors='replace'))
                ready, _, _ = select.select([process.stdout], [], [], 0.2)
                if ready:
                    data = os.read(process.stdout.fileno(), 65536)
                    pending.extend(data)
                    transcript.extend(data)

        def run(command, timeout=60):
            marker = f'BATTERY_SMOKE_STEP_{time.monotonic_ns()}'
            # A subshell keeps commands ending in & valid and propagates failure.
            line = f'({command}); status=$?; echo {marker}:$status; echo {marker}_END'
            process.stdin.write(line.encode() + b'\n')
            process.stdin.flush()
            result = wait_for(('\n' + marker + '_END\n').encode(), timeout)
            if f'\n{marker}:0\n' not in result:
                raise RuntimeError(f'Guest command failed:\n{result}')
            return result

        try:
            wait_for(b']# ')
            run('mount -t proc proc /proc && mount -t sysfs sysfs /sys && '
                'mount -t tmpfs tmpfs /run && '
                'mkdir -p /run/dbus /mnt/battery-source /tmp/battery-module && '
                'mount -t 9p -o trans=virtio,version=9p2000.L,ro battery-source /mnt/battery-source && '
                'cp /mnt/battery-source/* /tmp/battery-module/')
            build = run('export PATH=/usr/bin:/usr/sbin:/bin:/sbin; '
                        'make -C /usr/lib/modules/$(uname -r)/build M=/tmp/battery-module modules && '
                        'insmod /tmp/battery-module/try_omarchy_battery.ko && '
                        'uname -r && cat /sys/module/try_omarchy_battery/version', timeout=120)
            print(build, flush=True)
            run('/usr/lib/systemd/systemd-udevd --daemon && dbus-daemon --system --fork')
            run('/usr/lib/upowerd --verbose > /tmp/upower.log 2>&1 &')
            result = run('python3 /mnt/battery-source/test.py', timeout=300)
            if 'BATTERY_TRANSITIONS_PASS' not in result:
                raise AssertionError(f'Battery transition test did not finish:\n{result}')
            print(result, flush=True)
        except Exception:
            try:
                print(run('tail -100 /tmp/upower.log; dmesg | tail -20', timeout=5), flush=True)
            except Exception:
                pass
            raise
        finally:
            process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()


if __name__ == '__main__':
    main()
