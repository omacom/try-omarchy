#!/usr/bin/env python3
import importlib.machinery
import importlib.util
import os
from pathlib import Path
import socket
import struct
import subprocess
import tempfile
import threading
from types import SimpleNamespace
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / 'try-omarchy/files/usr/lib/try-omarchy/fido-bridge'
loader = importlib.machinery.SourceFileLoader('fido_bridge', str(HELPER))
spec = importlib.util.spec_from_loader(loader.name, loader)
bridge = importlib.util.module_from_spec(spec)
loader.exec_module(bridge)


def read_exact(peer, count):
    result = bytearray()
    while len(result) < count:
        part = peer.recv(count - len(result))
        if not part:
            raise ConnectionError('Synthetic peer disconnected')
        result.extend(part)
    return bytes(result)


def output_event(report):
    return struct.pack('<I', 6) + report.ljust(4096, b'\0') + struct.pack('<HB', len(report), 1)


class FIDOFrames(unittest.TestCase):
    def test_greeting_and_every_transport_split(self):
        self.assertEqual(bridge.message(bridge.HELLO), b'TOFD\x01\x01\0\0')
        packets = [(bridge.READY, b''), (bridge.REPORT, bytes(range(64))), (bridge.PONG, b'')]
        stream = b''.join(bridge.message(*packet) for packet in packets)
        for split in range(len(stream) + 1):
            reader = bridge.FrameReader()
            self.assertEqual(reader.feed(stream[:split]) + reader.feed(stream[split:]), packets)
            reader.finish()

    def test_invalid_headers_fail_without_waiting_for_the_payload(self):
        for value in (b'XXXX\x01\x01\0\0', b'TOFD\x02\x01\0\0', b'TOFD\x01\x07\0\0',
                      b'TOFD\x01\x03\xff\xff', b'TOFD\x01\x03\0\x3f', b'TOFD\x01\x01\0\x01'):
            with self.assertRaises(ValueError):
                bridge.FrameReader().feed(value)
        reader = bridge.FrameReader()
        reader.feed(b'TOFD')
        with self.assertRaises(ConnectionError):
            reader.finish()

    def test_reports_normalize_only_the_unnumbered_hid_layout(self):
        packet = bytes(range(64))
        self.assertEqual(bridge.output_report(output_event(packet)), packet)
        self.assertEqual(bridge.output_report(output_event(b'\0' + packet)), packet)
        for bad in (output_event(bytes(63)), output_event(b'\x01' + packet), output_event(packet)[:-1]):
            with self.assertRaises(ValueError):
                bridge.output_report(bad)

    def test_uhid_writes_are_complete_events(self):
        with patch.object(bridge.os, 'write', return_value=1):
            with self.assertRaisesRegex(OSError, 'Short UHID'):
                bridge.emit(12, 11, b'payload')


class FIDORelay(unittest.TestCase):
    def test_real_socket_transport_negotiates_before_kernel_reports(self):
        host, port = socket.socketpair()
        kernel, uhid = socket.socketpair()
        host.settimeout(2)
        kernel.settimeout(2)
        port.setblocking(False)
        failures = []

        original_read = bridge.os.read

        def read_device(fd, count):
            if fd == uhid.fileno():
                return read_exact(uhid, 4103)
            return original_read(fd, count)

        def run():
            try:
                with patch.object(bridge.os, "read", side_effect=read_device):
                    bridge.relay(port.fileno(), uhid.fileno())
            except BaseException as error:
                failures.append(error)

        worker = threading.Thread(target=run, daemon=True)
        worker.start()
        try:
            self.assertEqual(read_exact(host, 8), bridge.message(bridge.HELLO))
            packet = bytes(range(64))
            kernel.send(output_event(b'\0' + packet))
            host.sendall(bridge.message(bridge.READY)[:3])
            host.sendall(bridge.message(bridge.READY)[3:])
            self.assertEqual(read_exact(host, 72), bridge.message(bridge.REPORT, packet))
            frame = bridge.message(bridge.REPORT, packet)
            host.sendall(frame[:13])
            host.sendall(frame[13:] + frame)
            for _ in range(2):
                self.assertEqual(read_exact(kernel, 70), struct.pack('<IH', 12, 64) + packet)
            host.sendall(bridge.message(bridge.BYE))
            worker.join(2)
            self.assertFalse(worker.is_alive())
            self.assertEqual(len(failures), 1)
            self.assertIsInstance(failures[0], ConnectionError)
        finally:
            host.close()
            worker.join(2)
            port.close()
            kernel.close()
            uhid.close()

    def test_reports_before_ready_are_not_injected_into_the_kernel(self):
        with patch.object(bridge.os, 'read', return_value=bridge.message(bridge.REPORT, bytes(64))), \
                patch.object(bridge, 'emit') as emit:
            with self.assertRaisesRegex(ValueError, 'negotiate'):
                bridge.relay(10, 11, wait=lambda *args: ([10], [], []))
            emit.assert_not_called()

    def test_guest_heartbeats_and_expires_a_silent_host(self):
        now = [0.0]
        iterations = [0]
        writes = []

        def wait(*_):
            iterations[0] += 1
            if iterations[0] == 1:
                return [10], [], []
            now[0] = 2.1 if iterations[0] == 2 else 11.0
            return [], [10], []

        def write(fd, data):
            writes.append(bytes(data))
            return len(data)

        with patch.object(bridge.os, 'read', return_value=bridge.message(bridge.READY)), \
                patch.object(bridge.os, 'write', side_effect=write):
            with self.assertRaisesRegex(TimeoutError, 'lease'):
                bridge.relay(10, 11, clock=lambda: now[0], wait=wait)
        self.assertEqual(writes, [bridge.message(bridge.HELLO), bridge.message(bridge.PING)])

    def test_host_backpressure_is_bounded(self):
        event = output_event(bytes(64))
        with patch.object(bridge.os, 'read', side_effect=[bridge.message(bridge.READY)] + [event] * 240):
            reads = [0]

            def wait(*_):
                reads[0] += 1
                return ([10] if reads[0] == 1 else [11]), [], []

            with self.assertRaises(BufferError):
                bridge.relay(10, 11, clock=lambda: 0, wait=wait)


class FIDOSetup(unittest.TestCase):
    def test_setup_drops_privileges_before_handling_the_peer_and_always_releases_fds(self):
        calls = []
        identity = [0]
        account = SimpleNamespace(pw_uid=65534, pw_gid=65534)

        def setuid(uid):
            identity[0] = uid
            calls.append(('setuid', uid))

        def relay(*args):
            self.assertEqual(identity[0], 65534)
            self.assertEqual(calls, [('create', 12), ('groups', []), ('setgid', 65534), ('setuid', 65534)])
            raise ConnectionError('synthetic end')

        with patch.object(bridge.os, 'geteuid', side_effect=lambda: identity[0]), \
                patch.object(bridge.os, 'getuid', side_effect=lambda: identity[0]), \
                patch.object(bridge.pwd, 'getpwnam', return_value=account), \
                patch.object(bridge.os, 'open', side_effect=[11, 12]), \
                patch.object(bridge, 'create_device', side_effect=lambda fd: calls.append(('create', fd))), \
                patch.object(bridge.os, 'setgroups', side_effect=lambda groups: calls.append(('groups', groups))), \
                patch.object(bridge.os, 'setgid', side_effect=lambda gid: calls.append(('setgid', gid))), \
                patch.object(bridge.os, 'setuid', side_effect=setuid), \
                patch.object(bridge, 'relay', side_effect=relay), \
                patch.object(bridge.os, 'write') as write, patch.object(bridge.os, 'close') as close:
            with self.assertRaises(ConnectionError):
                bridge.main()
            write.assert_called_once_with(11, bridge.message(bridge.BYE))
            self.assertEqual([call.args[0] for call in close.call_args_list], [12, 11])

    def test_only_the_upgrade_that_introduces_fido_presets_the_new_service(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            calls = root / 'calls'
            (root / 'systemctl').write_text('#!/bin/bash\nprintf "%s\\n" "$*" >>"$FIDO_TEST_CALLS"\n'
                                           '[[ $1 == --global && $2 == is-enabled ]] && echo disabled\nexit 0\n')
            (root / 'vercmp').write_text('#!/bin/bash\n'
                                        'if [[ $1 == 0.1.0-30 && $2 == 0.1.0-31 ]]; then echo -1; else echo 0; fi\n')
            for program in ('systemctl', 'vercmp'):
                (root / program).chmod(0o755)
            install = ROOT / 'try-omarchy/try-omarchy.install'
            for old in ('0.1.0-30', '0.1.0-31'):
                calls.write_text('')
                subprocess.run(['/bin/bash', '-c', 'source "$1"; post_upgrade 0.1.0-31 "$2"',
                                'bash', str(install), old], check=True, capture_output=True,
                               env={**os.environ, 'PATH': str(root) + os.pathsep + os.environ['PATH'],
                                    'FIDO_TEST_CALLS': str(calls)})
                self.assertEqual('preset omarchy-native-fido-bridge.service' in calls.read_text().splitlines(),
                                 old == '0.1.0-30')

    def test_unprivileged_invocation_does_not_open_a_device(self):
        with patch.object(bridge.os, 'geteuid', return_value=1000), patch.object(bridge.os, 'open') as opened:
            with self.assertRaises(PermissionError):
                bridge.main()
            opened.assert_not_called()


if __name__ == '__main__':
    unittest.main()
