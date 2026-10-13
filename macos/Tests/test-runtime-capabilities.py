#!/usr/bin/env python3
"""Exercise the runtime's ARM capability probe with controlled QEMU output."""

from pathlib import Path
import subprocess
import tempfile
import unittest


PREPARER = Path(__file__).resolve().parents[1] / "prepare-qemu-gpu-runtime.sh"


class RuntimeCapabilityTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # Execute the production query and validation without staging/signing
        # an entire runtime. Only the incidental QEMU executable is replaced.
        source = PREPARER.read_text()
        start = source.index('  virt_help=$("$qemu" -machine virt,help 2>&1)')
        end = source.index('  cpu_help=$(', start)
        cls.probe = source[start:end]

    def run_probe(self, help_output, query_status=0):
        with tempfile.TemporaryDirectory() as temporary:
            help_file = Path(temporary) / "help.txt"
            help_file.write_text(help_output)
            script = '''set -euo pipefail
help_file=$1
query_status=$2
die() { echo "$*" >&2; exit 1; }
fixture_qemu() {
  [[ $# == 2 && $1 == -machine && $2 == virt,help ]] || exit 2
  cat "$help_file"
  return "$query_status"
}
qemu=fixture_qemu
''' + self.probe
            return subprocess.run(
                ["/bin/bash", "-c", script, "capability-test", str(help_file), str(query_status)],
                capture_output=True,
                text=True,
                timeout=10,
            )

    def test_accepts_supported_machine(self):
        result = self.run_probe("virtualization=<bool> - Enable ARM virtualization extensions\n")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_accepts_supported_machine_with_large_trailing_help(self):
        # Exceed pipe capacity after the match so an early-exiting reader
        # cannot hide its writer's failure under pipefail.
        result = self.run_probe("virtualization=<bool>\n" + "other-property=<bool>\n" * 100000)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_rejects_missing_virtualization_property(self):
        result = self.run_probe("other-property=<bool>\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("missing the ARM virtualization-extension switch", result.stderr)

    def test_rejects_failed_query_even_when_output_contains_property(self):
        result = self.run_probe("virtualization=<bool>\n", query_status=1)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("could not inspect the ARM virt machine", result.stderr)


if __name__ == "__main__":
    unittest.main()
