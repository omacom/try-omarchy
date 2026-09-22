#!/usr/bin/env python3
"""Drive the kernel module's real tob_parse() from userspace.

tob_parse() and the Python agent's format_state_line() are two independently
written halves of one wire contract, and nothing else in the suite executes
anything under guest/native-module/. This test slices the parser verbatim out
of the shipped module source, compiles it against small shims for the kernel
helpers it uses, and feeds it the exact lines the agent emits.

Nothing here is a copy of the parser: if the extraction markers stop matching,
the test fails rather than silently testing stale code.
"""

from __future__ import annotations

import importlib.util
from importlib.machinery import SourceFileLoader
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


GUEST = Path(__file__).resolve().parents[1]
MODULE_SOURCE = GUEST / "native-module/try-omarchy-battery/try-omarchy-battery.c"
HARNESS = GUEST / "tests/native-module/tob_parse_harness.c"
BRIDGE_PATH = GUEST / "native-overlay/usr/local/bin/omarchy-native-battery-bridge"

LOADER = SourceFileLoader("omarchy_native_battery_bridge", str(BRIDGE_PATH))
SPEC = importlib.util.spec_from_loader(LOADER.name, LOADER)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"cannot import {BRIDGE_PATH}")
bridge = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(bridge)


def _slice(source: str, start_marker: str, end_marker: str, *, search_back: str = "") -> str:
    """Return the verbatim source block containing start_marker."""
    anchor = source.index(start_marker)
    start = source.rindex(search_back, 0, anchor) if search_back else anchor
    end = source.index(end_marker, anchor) + len(end_marker)
    return source[start:end]


def extract_parser() -> str:
    """Slice struct tob_state, the status table and tob_parse() verbatim."""
    source = MODULE_SOURCE.read_text()
    blocks = [
        _slice(source, "struct tob_state {", "};"),
        _slice(source, "} tob_status_tokens[] = {", "};", search_back="static const struct {"),
        _slice(source, "static int tob_parse(", "\n}\n"),
    ]
    for block in blocks:
        if not block.strip():
            raise RuntimeError("tob_parse extraction produced an empty block")
    if "next->time_to_full" not in blocks[2]:
        raise RuntimeError("tob_parse extraction did not capture the whole parser")
    return "\n\n".join(blocks) + "\n"


def module_status_tokens() -> list[str]:
    """The status tokens the shipped module accepts, read from its table."""
    table = _slice(
        MODULE_SOURCE.read_text(),
        "} tob_status_tokens[] = {",
        "};",
        search_back="static const struct {",
    )
    return [
        line.split('"')[1]
        for line in table.splitlines()
        if line.lstrip().startswith("{ \"")
    ]


COMPILER = shutil.which("cc") or shutil.which("gcc") or shutil.which("clang")


@unittest.skipIf(COMPILER is None, "no C compiler available to build the tob_parse harness")
class TobParseTests(unittest.TestCase):
    binary: Path
    _directory: tempfile.TemporaryDirectory

    @classmethod
    def setUpClass(cls) -> None:
        cls._directory = tempfile.TemporaryDirectory()
        workspace = Path(cls._directory.name)
        (workspace / "tob_parse_extract.c").write_text(extract_parser())
        cls.binary = workspace / "tob_parse_harness"
        subprocess.run(
            [
                COMPILER, "-std=gnu11", "-Wall", "-Wextra", "-Werror",
                "-D_GNU_SOURCE", "-I", str(workspace),
                str(HARNESS), "-o", str(cls.binary),
            ],
            check=True,
        )

    @classmethod
    def tearDownClass(cls) -> None:
        cls._directory.cleanup()

    def parse(self, line: bytes) -> str:
        completed = subprocess.run(
            [str(self.binary)], input=line, stdout=subprocess.PIPE, check=True
        )
        return completed.stdout.decode().strip()

    def assertRejected(self, line: bytes) -> None:
        self.assertEqual(self.parse(line), "ERR 22", f"expected -EINVAL for {line!r}")

    def fields(self, line: bytes) -> dict[str, int]:
        result = self.parse(line)
        self.assertTrue(result.startswith("OK "), result)
        return {
            key: int(value)
            for key, value in (pair.split("=") for pair in result.split()[1:])
        }

    # The two line forms the agent actually emits.

    def test_accepts_the_agents_present_line(self) -> None:
        message = bridge.decode_message(
            b'{"type":"state","present":true,"percentage":57,"state":"discharging",'
            b'"acConnected":false,"timeToEmptySeconds":8100,"timeToFullSeconds":null}'
        )
        parsed = self.fields(bridge.format_state_line(message))
        self.assertEqual(parsed["present"], 1)
        self.assertEqual(parsed["capacity"], 57)
        self.assertEqual(parsed["ac"], 0)
        self.assertEqual(parsed["time_to_empty"], 8100)
        self.assertEqual(parsed["time_to_full"], -1)

    def test_accepts_the_agents_absent_line(self) -> None:
        message = bridge.decode_message(
            b'{"type":"state","present":false,"percentage":null,"state":"unknown",'
            b'"acConnected":true,"timeToEmptySeconds":null,"timeToFullSeconds":null}'
        )
        parsed = self.fields(bridge.format_state_line(message))
        self.assertEqual(parsed["present"], 0)
        self.assertEqual(parsed["ac"], 1)

    def test_accepts_the_agents_disconnect_line(self) -> None:
        last = bridge.decode_message(
            b'{"type":"state","present":true,"percentage":42,"state":"charging",'
            b'"acConnected":true,"timeToEmptySeconds":null,"timeToFullSeconds":600}'
        )
        parsed = self.fields(bridge.unknown_state_line(last))
        self.assertEqual(parsed["capacity"], 42)
        self.assertEqual(parsed["time_to_empty"], -1)
        self.assertEqual(parsed["time_to_full"], -1)

    # The status-token table is written twice, once per language.

    def test_module_and_agent_agree_on_the_status_tokens(self) -> None:
        self.assertEqual(sorted(module_status_tokens()), sorted(bridge.STATES))

    def test_every_status_token_parses_to_a_distinct_value(self) -> None:
        values = {}
        for token in bridge.STATES:
            line = f"present=1 status={token} capacity=50 ac=0\n".encode()
            values[token] = self.fields(line)["status"]
        self.assertEqual(len(set(values.values())), len(bridge.STATES), values)

    def test_rejects_an_unknown_status_token(self) -> None:
        self.assertRejected(b"present=1 status=melting capacity=50 ac=0\n")

    # Malformed input is rejected whole.

    def test_rejects_an_unknown_key(self) -> None:
        self.assertRejected(b"present=1 status=full capacity=50 ac=1 voltage=12\n")

    def test_rejects_a_token_without_an_equals_sign(self) -> None:
        self.assertRejected(b"present=1 status=full capacity ac=1\n")

    def test_rejects_missing_required_keys(self) -> None:
        self.assertRejected(b"status=full capacity=50 ac=1\n")
        self.assertRejected(b"present=1 status=full capacity=50\n")
        self.assertRejected(b"present=1 ac=1\n")
        self.assertRejected(b"present=1 capacity=50 ac=1\n")
        self.assertRejected(b"present=1 status=full ac=1\n")

    def test_rejects_out_of_range_capacity(self) -> None:
        self.assertRejected(b"present=1 status=full capacity=101 ac=1\n")
        self.assertRejected(b"present=1 status=full capacity=-1 ac=1\n")
        self.assertRejected(b"present=1 status=full capacity=abc ac=1\n")

    def test_rejects_times_below_minus_one(self) -> None:
        self.assertRejected(
            b"present=1 status=discharging capacity=50 ac=0 time_to_empty=-2\n"
        )
        self.assertRejected(
            b"present=1 status=charging capacity=50 ac=1 time_to_full=-2\n"
        )

    def test_accepts_minus_one_times(self) -> None:
        parsed = self.fields(
            b"present=1 status=unknown capacity=50 ac=1 time_to_empty=-1 time_to_full=-1\n"
        )
        self.assertEqual(parsed["time_to_empty"], -1)
        self.assertEqual(parsed["time_to_full"], -1)

    def test_absent_battery_needs_neither_status_nor_capacity(self) -> None:
        parsed = self.fields(b"present=0 ac=0\n")
        self.assertEqual(parsed["present"], 0)
        self.assertEqual(parsed["ac"], 0)


if __name__ == "__main__":
    unittest.main()
