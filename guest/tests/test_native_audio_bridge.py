#!/usr/bin/env python3
"""Behavior tests for the guest side of native macOS audio routing."""

from __future__ import annotations

import importlib.util
from importlib.machinery import SourceFileLoader
from pathlib import Path
import subprocess
import unittest
from unittest import mock


BRIDGE_PATH = (
    Path(__file__).resolve().parents[1]
    / "native-overlay/usr/local/bin/omarchy-native-audio-bridge"
)
LOADER = SourceFileLoader("omarchy_native_audio_bridge", str(BRIDGE_PATH))
SPEC = importlib.util.spec_from_loader(LOADER.name, LOADER)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"cannot import {BRIDGE_PATH}")
bridge = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(bridge)


class PactlStub:
    """Small pactl model that records the graph built by PipeWireMirror."""

    transport_sink = "alsa_output.platform-4010000000.pci-generic.analog-stereo"
    transport_source = "alsa_input.platform-4010000000.pci-generic.analog-stereo"

    def __init__(self) -> None:
        self.calls: list[tuple[tuple[str, ...], bool]] = []
        self.next_module_id = 100
        self.loaded_modules: dict[str, str] = {}
        self.default_sink = self.transport_sink
        self.default_source = self.transport_source

    def __call__(self, *arguments: str, check: bool = True) -> str:
        self.calls.append((arguments, check))
        if arguments == ("list", "short", "sinks"):
            return f"10\t{self.transport_sink}\tmodule-alsa-card.c\ts16le 2ch 48000Hz\tRUNNING\n"
        if arguments == ("list", "short", "sources"):
            return f"11\t{self.transport_source}\tmodule-alsa-card.c\ts16le 2ch 48000Hz\tRUNNING\n"
        if arguments == ("list", "short", "modules"):
            return "\n".join(f"{module_id}\t{record}" for module_id, record in self.loaded_modules.items())
        if arguments and arguments[0] == "load-module":
            module_id = str(self.next_module_id)
            self.next_module_id += 1
            self.loaded_modules[module_id] = f"{arguments[1]}\t{' '.join(arguments[2:])}"
            return module_id
        if len(arguments) == 2 and arguments[0] == "unload-module":
            self.loaded_modules.pop(arguments[1], None)
            return ""
        if len(arguments) == 2 and arguments[0] == "set-default-sink":
            if not any(f"sink_name={arguments[1]} " in record for record in self.loaded_modules.values()):
                raise RuntimeError("pactl set-default-sink: No such entity")
            self.default_sink = arguments[1]
            return ""
        if len(arguments) == 2 and arguments[0] == "set-default-source":
            if not any(f"source_name={arguments[1]} " in record for record in self.loaded_modules.values()):
                raise RuntimeError("pactl set-default-source: No such entity")
            self.default_source = arguments[1]
            return ""
        if arguments == ("get-default-sink",):
            return self.default_sink
        if arguments == ("get-default-source",):
            return self.default_source
        raise AssertionError(f"unexpected pactl call: {arguments!r}, check={check!r}")

    def matching_calls(self, command: str) -> list[tuple[str, ...]]:
        return [arguments for arguments, _ in self.calls if arguments[0] == command]


def catalog_message() -> dict[str, object]:
    return {
        "type": "catalog",
        "outputs": [
            {"deviceUID": "macbook-output", "name": "MacBook Pro Speakers"},
            {"deviceUID": "studio-output", "name": "Studio Display Speakers"},
        ],
        "inputs": [
            {"deviceUID": "macbook-input", "name": "MacBook Pro Microphone"},
            {"deviceUID": "studio-input", "name": 'Studio Display \\"Microphone\\"'},
        ],
        "selectedOutputUID": "studio-output",
        "selectedInputUID": "macbook-input",
    }


def decode_quoted_value(value: str) -> str:
    """Decode the quote/backslash syntax used by pactl module arguments."""
    if len(value) < 2 or value[0] != '"' or value[-1] != '"':
        raise AssertionError(f"expected one quoted value, got {value!r}")
    decoded: list[str] = []
    index = 1
    while index < len(value) - 1:
        character = value[index]
        if character == "\\":
            index += 1
            if index >= len(value) - 1:
                raise AssertionError(f"unterminated escape in {value!r}")
            decoded.append(value[index])
        elif character == '"':
            raise AssertionError(f"unescaped nested quote in {value!r}")
        else:
            decoded.append(character)
        index += 1
    return "".join(decoded)


def parse_proplist(value: str) -> dict[str, str]:
    """Parse the small Pulse property-list grammar emitted by the bridge."""
    properties: dict[str, str] = {}
    index = 0
    while index < len(value):
        while index < len(value) and value[index] == " ":
            index += 1
        if index == len(value):
            break
        equals = value.find("=", index)
        if equals < 0:
            raise AssertionError(f"property has no value in {value!r}")
        name = value[index:equals]
        index = equals + 1
        if index < len(value) and value[index] == '"':
            end = index + 1
            escaped = False
            while end < len(value):
                if escaped:
                    escaped = False
                elif value[end] == "\\":
                    escaped = True
                elif value[end] == '"':
                    break
                end += 1
            if end >= len(value):
                raise AssertionError(f"unterminated property value in {value!r}")
            decoded = decode_quoted_value(value[index:end + 1])
            index = end + 1
        else:
            end = value.find(" ", index)
            if end < 0:
                end = len(value)
            decoded = value[index:end]
            index = end
        if not name or name in properties:
            raise AssertionError(f"invalid duplicate property {name!r}")
        properties[name] = decoded
        if index < len(value) and value[index] != " ":
            raise AssertionError(f"properties are not space-separated in {value!r}")
    return properties


class PipeWireMirrorTests(unittest.TestCase):
    def make_mirror(self) -> tuple[object, PactlStub, list[dict[str, object]]]:
        sent: list[dict[str, object]] = []
        pactl = PactlStub()
        mirror = bridge.PipeWireMirror(sent.append)
        self.pactl_patch = mock.patch.object(bridge, "run_pactl", side_effect=pactl)
        self.pactl_patch.start()
        self.addCleanup(self.pactl_patch.stop)
        self.addCleanup(mirror.close)
        return mirror, pactl, sent

    def test_outputs_are_playable_remaps_of_the_hda_transport(self) -> None:
        """A chooser sink must carry audio, not merely update the host route."""
        mirror, pactl, _ = self.make_mirror()

        mirror.apply(catalog_message())

        loads = pactl.matching_calls("load-module")
        output_loads = [call for call in loads if call[1] == "module-remap-sink"]
        self.assertEqual(len(output_loads), 3)
        self.assertFalse(any(call[1] in {"module-null-sink", "module-loopback"} for call in loads))
        for call in output_loads:
            self.assertIn(f"master={pactl.transport_sink}", call)
            self.assertTrue(any(argument.startswith("sink_name=omarchy_host_output_") for argument in call))

        studio_endpoint = bridge.endpoint_name("output", "studio-output")
        self.assertEqual(pactl.default_sink, studio_endpoint)

    def test_every_virtual_endpoint_loads_with_its_friendly_node_description(self) -> None:
        """Quick Settings reads the nested node.description passed at module load."""
        mirror, pactl, _ = self.make_mirror()

        mirror.apply(catalog_message())

        expected_outputs = {
            bridge.endpoint_name("output", None): "Mac System Default",
            bridge.endpoint_name("output", "macbook-output"): "MacBook Pro Speakers",
            bridge.endpoint_name("output", "studio-output"): "Studio Display Speakers",
        }
        expected_inputs = {
            bridge.endpoint_name("input", None): "Mac System Default",
            bridge.endpoint_name("input", "macbook-input"): "MacBook Pro Microphone",
            bridge.endpoint_name("input", "studio-input"): 'Studio Display \\"Microphone\\"',
        }

        self.assert_friendly_loads(
            pactl,
            module="module-remap-sink",
            endpoint_argument="sink_name",
            properties_argument="sink_properties",
            expected=expected_outputs,
            icon="audio-card",
        )
        self.assert_friendly_loads(
            pactl,
            module="module-remap-source",
            endpoint_argument="source_name",
            properties_argument="source_properties",
            expected=expected_inputs,
            icon="audio-input-microphone",
        )

        unsupported = [
            call for call, _ in pactl.calls
            if call[0] in {"update-sink-proplist", "update-source-proplist"}
        ]
        self.assertEqual(unsupported, [])

    def test_selecting_each_endpoint_sends_its_stable_host_uid(self) -> None:
        mirror, pactl, sent = self.make_mirror()
        mirror.apply(catalog_message())
        sent.clear()
        mirror.last_health_check = float("inf")

        pactl.default_sink = bridge.endpoint_name("output", "macbook-output")
        pactl.default_source = bridge.endpoint_name("input", "studio-input")
        mirror.poll_selection()

        self.assertEqual(
            sent,
            [
                {"type": "select", "direction": "output", "deviceUID": "macbook-output"},
                {"type": "select", "direction": "input", "deviceUID": "studio-input"},
            ],
        )

    def test_catalog_retry_recovers_when_pipewire_restarts_during_selection(self) -> None:
        for command in ("set-default-sink", "set-default-source"):
            with self.subTest(command=command):
                mirror, pactl, _ = self.make_mirror()
                restarted = False

                def restart_during_selection(*arguments: str, check: bool = True) -> str:
                    nonlocal restarted
                    if arguments[0] == command and not restarted:
                        restarted = True
                        pactl.loaded_modules.clear()
                        raise RuntimeError(f"pactl {command}: timed out")
                    return pactl(*arguments, check=check)

                with mock.patch.object(bridge, "run_pactl", side_effect=restart_during_selection):
                    with self.assertRaisesRegex(RuntimeError, "timed out"):
                        mirror.apply(catalog_message())
                    mirror.apply(catalog_message())

                self.assertEqual(len(pactl.loaded_modules), 6)
                self.assertEqual(pactl.default_sink, bridge.endpoint_name("output", "studio-output"))
                self.assertEqual(pactl.default_source, bridge.endpoint_name("input", "macbook-input"))
                mirror.close()

    def test_catalog_retry_keeps_healthy_endpoints_after_selection_timeout(self) -> None:
        mirror, pactl, _ = self.make_mirror()
        timed_out = False

        def slow_selection(*arguments: str, check: bool = True) -> str:
            nonlocal timed_out
            if arguments[0] == "set-default-sink" and not timed_out:
                timed_out = True
                raise RuntimeError("pactl set-default-sink: timed out")
            return pactl(*arguments, check=check)

        with mock.patch.object(bridge, "run_pactl", side_effect=slow_selection):
            with self.assertRaisesRegex(RuntimeError, "timed out"):
                mirror.apply(catalog_message())
            original_modules = set(pactl.loaded_modules)
            mirror.apply(catalog_message())

        self.assertEqual(set(pactl.loaded_modules), original_modules)
        self.assertEqual(pactl.matching_calls("unload-module"), [])
        self.assertEqual(pactl.default_sink, bridge.endpoint_name("output", "studio-output"))
        self.assertEqual(pactl.default_source, bridge.endpoint_name("input", "macbook-input"))

    def test_rebuild_unloads_remaps_left_by_an_earlier_bridge(self) -> None:
        """A restarted bridge must not stack a second set of host endpoints."""
        mirror, pactl, _ = self.make_mirror()
        pactl.loaded_modules = {
            "7": "module-alsa-card\tdevice_id=0",
            "8": f"module-remap-sink\tmaster={pactl.transport_sink} sink_name=other_remap",
            "40": f"module-remap-sink\tmaster={pactl.transport_sink} sink_name={bridge.endpoint_name('output', None)}",
            "41": f"module-remap-source\tmaster={pactl.transport_source} source_name={bridge.endpoint_name('input', None)}",
        }

        mirror.apply(catalog_message())

        self.assertEqual(
            [call[1] for call in pactl.matching_calls("unload-module")],
            ["40", "41"],
        )
        self.assertIn("7", pactl.loaded_modules)
        self.assertIn("8", pactl.loaded_modules)
        self.assertEqual(len(pactl.loaded_modules), 2 + 6)

    def test_pactl_timeout_is_a_retryable_error(self) -> None:
        """A slow pactl must not kill the bridge and trigger a restart loop."""
        timeout = subprocess.TimeoutExpired(["pactl", "get-default-sink"], 10)
        with mock.patch.object(bridge.subprocess, "run", side_effect=timeout):
            with self.assertRaisesRegex(RuntimeError, "timed out"):
                bridge.run_pactl("get-default-sink", check=False)

    def test_close_unloads_every_module_when_one_unload_times_out(self) -> None:
        mirror, pactl, _ = self.make_mirror()
        mirror.apply(catalog_message())
        loaded = list(mirror.module_ids)

        def slow_first_unload(*arguments: str, check: bool = True) -> str:
            if arguments == ("unload-module", loaded[-1]):
                raise RuntimeError("pactl unload-module: timed out")
            return pactl(*arguments, check=check)

        with mock.patch.object(bridge, "run_pactl", side_effect=slow_first_unload):
            mirror.close()

        self.assertEqual(set(pactl.loaded_modules), {loaded[-1]})
        self.assertEqual(mirror.module_ids, [])

    def assert_friendly_loads(
        self,
        pactl: PactlStub,
        module: str,
        endpoint_argument: str,
        properties_argument: str,
        expected: dict[str, str],
        icon: str,
    ) -> None:
        loads = [call for call in pactl.matching_calls("load-module") if call[1] == module]
        self.assertEqual(len(loads), len(expected))
        seen: set[str] = set()
        for call in loads:
            endpoint_values = [
                argument.removeprefix(f"{endpoint_argument}=")
                for argument in call[2:]
                if argument.startswith(f"{endpoint_argument}=")
            ]
            property_values = [
                argument.removeprefix(f"{properties_argument}=")
                for argument in call[2:]
                if argument.startswith(f"{properties_argument}=")
            ]
            self.assertEqual(len(endpoint_values), 1)
            self.assertEqual(len(property_values), 1)
            endpoint = endpoint_values[0]
            self.assertIn(endpoint, expected)
            seen.add(endpoint)

            # pactl joins load-module argv before PipeWire parses them. These
            # outer quotes are therefore required to preserve the inner list.
            self.assertTrue(property_values[0].startswith('"'))
            self.assertTrue(property_values[0].endswith('"'))
            properties = parse_proplist(decode_quoted_value(property_values[0]))
            self.assertEqual(
                properties,
                {
                    "node.virtual": "true",
                    "node.description": expected[endpoint],
                    "device.description": expected[endpoint],
                    "device.icon_name": icon,
                },
            )
        self.assertEqual(seen, set(expected))


if __name__ == "__main__":
    unittest.main()
