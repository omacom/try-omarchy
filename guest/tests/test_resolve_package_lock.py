import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch


GUEST = Path(__file__).resolve().parents[1]
MODULE = importlib.util.spec_from_file_location(
    "resolve_package_lock", GUEST / "scripts/resolve-package-lock.py"
)
resolver = importlib.util.module_from_spec(MODULE)
MODULE.loader.exec_module(resolver)


class ResolvePackageLockTests(unittest.TestCase):
    def test_dependency_failure_preserves_both_diagnostic_streams(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            packages = root / "packages.txt"
            packages.write_text("hyprland\n")
            output = root / "lock.json"
            result = subprocess.CompletedProcess(
                args=["pacman"],
                returncode=1,
                stderr="error: could not satisfy dependencies\n",
                stdout=":: unable to satisfy dependency 'missing-library'\n",
            )
            with patch("sys.argv", [
                "resolve-package-lock.py", "--config", str(root / "pacman.conf"),
                "--dbpath", str(root / "db"), "--packages", str(packages),
                "--output", str(output),
            ]), patch.object(resolver.subprocess, "run", return_value=result):
                with self.assertRaises(SystemExit) as failure:
                    resolver.main()
            self.assertIn("could not satisfy dependencies", str(failure.exception))
            self.assertIn("missing-library", str(failure.exception))
            self.assertFalse(output.exists())


if __name__ == "__main__":
    unittest.main()
