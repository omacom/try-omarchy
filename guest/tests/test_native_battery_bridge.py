#!/usr/bin/env python3
"""Behavior tests for the guest side of macOS battery mirroring."""

from __future__ import annotations

import importlib.util
from importlib.machinery import SourceFileLoader
import json
from pathlib import Path
import unittest


BRIDGE_PATH = (
    Path(__file__).resolve().parents[1]
    / "native-overlay/usr/local/bin/omarchy-native-battery-bridge"
)
LOADER = SourceFileLoader("omarchy_native_battery_bridge", str(BRIDGE_PATH))
SPEC = importlib.util.spec_from_loader(LOADER.name, LOADER)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"cannot import {BRIDGE_PATH}")
bridge = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(bridge)


def state(**overrides) -> bytes:
    message = {
        "type": "state",
        "present": True,
        "percentage": 57,
        "state": "discharging",
        "acConnected": False,
        "timeToEmptySeconds": 8100,
        "timeToFullSeconds": None,
    }
    message.update(overrides)
    return json.dumps(message).encode()


class DecodeTests(unittest.TestCase):
    def test_accepts_a_complete_snapshot(self) -> None:
        decoded = bridge.decode_message(state())
        self.assertEqual(decoded["percentage"], 57)
        self.assertEqual(decoded["state"], "discharging")

    def test_accepts_a_desktop_mac_snapshot(self) -> None:
        decoded = bridge.decode_message(
            state(present=False, percentage=None, state="unknown",
                  acConnected=True, timeToEmptySeconds=None)
        )
        self.assertFalse(decoded["present"])
        self.assertTrue(decoded["acConnected"])

    def test_rejects_malformed_messages(self) -> None:
        for line in (
            b"[]",
            b'{"type":"refresh"}',
            state(percentage=101),
            state(percentage="57"),
            state(state="melting"),
            state(timeToEmptySeconds=-5),
            json.dumps({"type": "state", "present": True}).encode(),
            state() + b"garbage",
        ):
            with self.assertRaises(ValueError):
                bridge.decode_message(line)

    def test_extra_keys_are_rejected(self) -> None:
        message = json.loads(state())
        message["extra"] = 1
        with self.assertRaises(ValueError):
            bridge.decode_message(json.dumps(message).encode())


class StateLineTests(unittest.TestCase):
    def test_full_snapshot_line(self) -> None:
        decoded = bridge.decode_message(state())
        self.assertEqual(
            bridge.format_state_line(decoded),
            b"present=1 status=discharging capacity=57 ac=0 "
            b"time_to_empty=8100 time_to_full=-1\n",
        )

    def test_charging_snapshot_line(self) -> None:
        decoded = bridge.decode_message(
            state(state="charging", acConnected=True,
                  timeToEmptySeconds=None, timeToFullSeconds=2700)
        )
        self.assertEqual(
            bridge.format_state_line(decoded),
            b"present=1 status=charging capacity=57 ac=1 "
            b"time_to_empty=-1 time_to_full=2700\n",
        )

    def test_desktop_mac_omits_battery_keys(self) -> None:
        decoded = bridge.decode_message(
            state(present=False, percentage=None, state="unknown",
                  acConnected=True, timeToEmptySeconds=None)
        )
        self.assertEqual(bridge.format_state_line(decoded), b"present=0 ac=1\n")

    def test_unknown_line_preserves_last_snapshot(self) -> None:
        decoded = bridge.decode_message(state())
        self.assertEqual(
            bridge.unknown_state_line(decoded),
            b"present=1 status=unknown capacity=57 ac=0 "
            b"time_to_empty=-1 time_to_full=-1\n",
        )

    def test_unknown_line_without_history_reports_absent(self) -> None:
        self.assertEqual(bridge.unknown_state_line(None), b"present=0 ac=1\n")


class RefreshTests(unittest.TestCase):
    def test_refresh_request_shape(self) -> None:
        self.assertEqual(bridge.REFRESH_LINE, b'{"type":"refresh"}\n')


if __name__ == "__main__":
    unittest.main()
