#!/usr/bin/env python3
import itertools
import json
from pathlib import Path
import random
import struct
import unittest
from unittest.mock import call, patch

from test_fido import bridge, output_event, NONCE


SEED = 0xF1D020261021
VECTORS = Path(__file__).resolve().parents[3] / "tests/fixtures/fido-wire-vectors.json"


def generated_frames(generator, reports):
    return ([(bridge.HELLO, NONCE), (bridge.READY, NONCE), (bridge.PING, b"")]
            + [(bridge.REPORT, generator.randbytes(64)) for _ in range(reports)]
            + [(bridge.PONG, b""), (bridge.BYE, b"")])


class FIDOSimulatedFrames(unittest.TestCase):
    def test_restart_greeting_discards_every_partial_escaped_report(self):
        report = bytes((0x7d, 0x7e, 0x7f)[index % 3] for index in range(64))
        old = bridge.message(bridge.REPORT, report)
        greeting = bridge.message(bridge.HELLO, bytes(reversed(NONCE)))
        for cut in range(1, len(old)):
            for split in range(len(greeting) + 1):
                reader = bridge.FrameReader()
                self.assertEqual(reader.feed(old[:cut]), [])
                self.assertEqual(reader.feed(greeting[:split]) + reader.feed(greeting[split:]),
                                 [(bridge.HELLO, bytes(reversed(NONCE)))])
                reader.finish()

    def test_restart_markers_are_data_inside_every_hid_byte_range(self):
        for start in range(0, 256, 64):
            report = bytes(range(start, start + 64))
            wire = bridge.message(bridge.REPORT, report)
            for cut in range(len(wire) + 1):
                reader = bridge.FrameReader()
                self.assertEqual(reader.feed(wire[:cut]) + reader.feed(wire[cut:]),
                                 [(bridge.REPORT, report)])
                reader.finish()

    def test_independent_golden_vectors(self):
        vectors = json.loads(VECTORS.read_text())
        for vector in vectors:
            payload = bytes.fromhex(vector["payload_hex"])
            wire = bytes.fromhex(vector["wire_hex"])
            self.assertEqual(bridge.message(vector["kind"], payload), wire)
            reader = bridge.FrameReader()
            self.assertEqual(reader.feed(wire), [(vector["kind"], payload)])
            reader.finish()
        self.assertEqual(len(vectors), 13)
        print(f"FIDO_SIM_CASES guest_golden_vectors={len(vectors)}")

    def test_seeded_streams_survive_splits_coalescing_and_empty_reads(self):
        generator = random.Random(SEED)
        splits = chunks = 0
        for index in range(64):
            packets = generated_frames(generator, 1 + index % 8)
            wire = b"".join(bridge.message(*packet) for packet in packets)
            reader = bridge.FrameReader()
            self.assertEqual(reader.feed(wire), packets)
            reader.finish()
            if index < 16:
                for cut in range(len(wire) + 1):
                    reader = bridge.FrameReader()
                    self.assertEqual(reader.feed(wire[:cut]) + reader.feed(wire[cut:]), packets)
                    reader.finish()
                    splits += 1
            for _ in range(8):
                reader = bridge.FrameReader()
                result, offset = [], 0
                while offset < len(wire):
                    size = min(len(wire) - offset, generator.randrange(1, 98))
                    result.extend(reader.feed(wire[offset:offset + size]))
                    self.assertEqual(reader.feed(b""), [])
                    offset += size
                reader.finish()
                self.assertEqual(result, packets)
                chunks += 1
        self.assertGreater(splits, 5840)
        self.assertEqual(chunks, 512)
        print(f"FIDO_SIM_CASES guest_every_split={splits} guest_seeded_chunks={chunks} guest_coalesced=64")

    def test_invalid_header_bytes_reject_without_advertised_payload(self):
        headers = []
        hello = bytearray(b"TOFD\x02\x01\0\x10")
        for offset in range(5):
            for value in range(256):
                if value != hello[offset]:
                    header = hello.copy()
                    header[offset] = value
                    headers.append(header)
        for kind in set(range(256)) - set(range(1, 7)):
            header = hello.copy()
            header[5] = kind
            headers.append(header)
        for kind in range(1, 7):
            expected = 16 if kind <= 2 else 64 if kind == 3 else 0
            original = bytearray(b"TOFD" + bytes([2, kind, 0, expected]))
            for value in range(256):
                for offset, valid in ((6, 0), (7, expected)):
                    if value != valid:
                        header = original.copy()
                        header[offset] = value
                        headers.append(header)
        for header in headers:
            with self.assertRaises(ValueError):
                bridge.FrameReader().feed(bridge.record(header))
        self.assertEqual(len(headers), 4585)
        print(f"FIDO_SIM_CASES guest_invalid_headers={len(headers)}")

    def test_eof_and_read_limit_boundaries(self):
        packets = generated_frames(random.Random(SEED), 3)
        wire = b"".join(bridge.message(*packet) for packet in packets)
        complete, total = {0}, 0
        for packet in packets:
            total += len(bridge.message(*packet))
            complete.add(total)
        for cut in range(len(wire) + 1):
            reader = bridge.FrameReader()
            decoded = reader.feed(wire[:cut])
            accepted = b"".join(bridge.message(*packet) for packet in decoded)
            self.assertEqual(accepted, wire[:len(accepted)])
            if cut in complete:
                reader.finish()
            else:
                with self.assertRaises(ConnectionError):
                    reader.finish()
        reader = bridge.FrameReader()
        at_limit = bridge.message(bridge.PING) * 407 + bridge.message(bridge.HELLO, NONCE)
        self.assertEqual(reader.feed(at_limit), [(bridge.PING, b"")] * 407 + [(bridge.HELLO, NONCE)])
        reader.finish()
        with self.assertRaises(ValueError):
            reader.feed(at_limit + b"T")
        reader.finish()
        print(f"FIDO_SIM_CASES guest_eof_prefixes={len(wire) + 1} guest_read_limit_positive=1 guest_read_limit_negative=1")


class FIDOSimulatedRelay(unittest.TestCase):
    def test_wrong_direction_messages_never_inject_kernel_reports(self):
        cases = [(False, kind) for kind in (1, 4)] + [(True, kind) for kind in (1, 2, 4)]
        for ready, kind in cases:
            reads = ([bridge.message(bridge.READY, NONCE)] if ready else [])
            reads.append(bridge.message(kind, NONCE if kind in (bridge.HELLO, bridge.READY) else bytes(64) if kind == bridge.REPORT else b""))
            with self.subTest(ready=ready, kind=kind), \
                    patch.object(bridge.os, "read", side_effect=reads), patch.object(bridge, "emit") as emit:
                with self.assertRaises(ValueError):
                    bridge.relay(10, 11, nonce=NONCE, clock=lambda: 0, wait=lambda *_: ([10], [], []))
                emit.assert_not_called()
        print(f"FIDO_SIM_CASES guest_wrong_directions={len(cases)}")

    def test_fragmented_host_reports_reach_only_the_uhid_input_path(self):
        generator = random.Random(SEED)
        forwarded = 0
        for count in range(1, 9):
            reports = [generator.randbytes(64) for _ in range(count)]
            wire = (bridge.message(bridge.READY, NONCE)
                    + b"".join(bridge.message(bridge.REPORT, report) for report in reports)
                    + bridge.message(bridge.PONG) + bridge.message(bridge.BYE))
            chunks, offset = [], 0
            while offset < len(wire):
                size = min(len(wire) - offset, generator.randrange(1, 34))
                chunks.append(wire[offset:offset + size])
                offset += size
            with patch.object(bridge.os, "read", side_effect=chunks), patch.object(bridge, "emit") as emit:
                with self.assertRaisesRegex(ConnectionError, "released"):
                    bridge.relay(10, 11, nonce=NONCE, clock=lambda: 0, wait=lambda *_: ([10], [], []))
                self.assertEqual(emit.call_args_list, [call(11, 12, struct.pack("<H", 64) + report)
                                                      for report in reports])
            forwarded += count
        print(f"FIDO_SIM_CASES guest_relay_streams=8 guest_reports_forwarded={forwarded}")

    def test_uhid_normalizes_only_unnumbered_reports(self):
        generator = random.Random(SEED)
        for _ in range(64):
            report = generator.randbytes(64)
            self.assertEqual(bridge.output_report(output_event(report)), report)
            self.assertEqual(bridge.output_report(output_event(b"\0" + report)), report)
        report = bytes(range(64))
        for report_id in range(1, 256):
            with self.assertRaises(ValueError):
                bridge.output_report(output_event(bytes([report_id]) + report))
        for size in range(130):
            if size not in (64, 65):
                with self.assertRaises(ValueError):
                    bridge.output_report(output_event(bytes(size)))
        for report_type in (0, 2, 3, 255):
            event = output_event(report)[:-1] + bytes([report_type])
            with self.assertRaises(ValueError):
                bridge.output_report(event)
        print("FIDO_SIM_CASES guest_normalization_positive=128 guest_report_id_negative=255 guest_report_size_negative=128 guest_report_type_negative=4")

    def test_uhid_retry_preserves_whole_events_and_stops_at_its_deadline(self):
        event = struct.pack("<I", 12) + struct.pack("<H", 64) + bytes(range(64))
        cases = 0
        for count in range(1, 4):
            for errors in itertools.product((BlockingIOError, InterruptedError), repeat=count):
                with patch.object(bridge.time, "monotonic", return_value=0), \
                        patch.object(bridge.select, "select"), \
                        patch.object(bridge.os, "write", side_effect=[error() for error in errors] + [len(event)]) as write:
                    bridge.emit(11, 12, event[4:])
                    self.assertEqual(write.call_args_list, [call(11, event)] * (count + 1))
                cases += 1
        with patch.object(bridge.time, "monotonic", side_effect=[0, .5, 1, 2]), \
                patch.object(bridge.select, "select"), \
                patch.object(bridge.os, "write", side_effect=BlockingIOError()) as write:
            with self.assertRaises(TimeoutError):
                bridge.emit(11, 12, event[4:])
            self.assertEqual(write.call_args_list, [call(11, event)] * 3)
        self.assertEqual(cases, 14)
        print(f"FIDO_SIM_CASES guest_uhid_retry_sequences={cases} guest_uhid_retry_deadline=1")


if __name__ == "__main__":
    unittest.main()
