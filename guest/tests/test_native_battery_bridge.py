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

    def test_optional_charge_limit_and_legacy_host(self) -> None:
        self.assertIsNone(bridge.decode_message(state())["chargeLimit"])
        self.assertEqual(bridge.decode_message(state(chargeLimit=95))["chargeLimit"], 95)
        self.assertIsNone(bridge.decode_message(state(chargeLimit=None))["chargeLimit"])

    def test_rejects_invalid_charge_limits(self) -> None:
        for limit in (-1, 0, 100, 101, True, "95", 95.5):
            with self.subTest(limit=limit), self.assertRaises(ValueError):
                bridge.decode_message(state(chargeLimit=limit))
        with self.assertRaises(ValueError):
            bridge.decode_message(state(present=False, percentage=None, chargeLimit=95))

    def test_extra_keys_are_rejected(self) -> None:
        message = json.loads(state())
        message["extra"] = 1
        with self.assertRaises(ValueError):
            bridge.decode_message(json.dumps(message).encode())

    def test_physical_readings_validate_units_and_presence(self) -> None:
        decoded = bridge.decode_message(state(chargeFullMicroAh=4970000, cycleCount=0))
        self.assertEqual(decoded["chargeFullMicroAh"], 4970000)
        self.assertEqual(decoded["cycleCount"], 0)
        self.assertIsNone(decoded["voltageMicroV"])
        for key in bridge.DETAIL_FIELDS:
            for value in (-1, True, "213", 1.5, 2147483648):
                with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                    bridge.decode_message(state(**{key: value}))
            with self.assertRaises(ValueError):
                bridge.decode_message(state(present=False, percentage=None, **{key: 213}))
        for key in ("chargeFullMicroAh", "chargeFullDesignMicroAh", "voltageMicroV"):
            with self.assertRaises(ValueError):
                bridge.decode_message(state(**{key: 0}))


class StateLineTests(unittest.TestCase):
    def test_full_snapshot_line(self) -> None:
        decoded = bridge.decode_message(state())
        self.assertEqual(
            bridge.format_state_line(decoded),
            b"present=1 status=discharging capacity=57 ac=0 "
            b"time_to_empty=8100 time_to_full=-1 charge_limit=-1 "
            b"charge_now=-1 charge_full=-1 charge_full_design=-1 voltage_now=-1 cycle_count=-1\n",
        )

    def test_charge_limit_is_independent_of_percentage_and_ac(self) -> None:
        decoded = bridge.decode_message(state(percentage=42, chargeLimit=95))
        self.assertIn(b"capacity=42", bridge.format_state_line(decoded))
        self.assertIn(b"charge_limit=95", bridge.format_state_line(decoded))
        self.assertIn(b"charge_limit=-1", bridge.unknown_state_line(decoded))

    def test_charging_snapshot_line(self) -> None:
        decoded = bridge.decode_message(
            state(state="charging", acConnected=True,
                  timeToEmptySeconds=None, timeToFullSeconds=2700)
        )
        self.assertEqual(
            bridge.format_state_line(decoded),
            b"present=1 status=charging capacity=57 ac=1 "
            b"time_to_empty=-1 time_to_full=2700 charge_limit=-1 "
            b"charge_now=-1 charge_full=-1 charge_full_design=-1 voltage_now=-1 cycle_count=-1\n",
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
            b"time_to_empty=-1 time_to_full=-1 charge_limit=-1 "
            b"charge_now=-1 charge_full=-1 charge_full_design=-1 voltage_now=-1 cycle_count=-1\n",
        )

    def test_unknown_line_without_history_reports_absent(self) -> None:
        self.assertEqual(bridge.unknown_state_line(None), b"present=0 ac=1\n")


class RefreshTests(unittest.TestCase):
    def test_refresh_request_shape(self) -> None:
        self.assertEqual(bridge.REFRESH_LINE, b'{"type":"refresh","chargeLimit":true,"batteryDetails":true}\n')


if __name__ == "__main__":
    unittest.main()
