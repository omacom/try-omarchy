#!/usr/bin/env python3

from pathlib import Path
import plistlib
import unittest


REPOSITORY = Path(__file__).resolve().parents[1]


class AppLifecycleTests(unittest.TestCase):
    def test_launcher_opts_out_of_automatic_and_sudden_termination(self) -> None:
        info = plistlib.loads((REPOSITORY / "macos/Info.plist").read_bytes())
        self.assertIs(info["NSSupportsAutomaticTermination"], False)
        self.assertIs(info["NSSupportsSuddenTermination"], False)

    def test_windowless_event_loops_disable_termination_first(self) -> None:
        main = (REPOSITORY / "macos/Sources/OmarchyVMHelper/main.swift").read_text()
        helper = main[main.index("private func keepRunningWhileWindowless()"):]
        helper = helper[:helper.index("\n}\n")]
        self.assertIn("disableAutomaticTermination(", helper)
        self.assertIn("disableSuddenTermination()", helper)
        for mode, loop in (('"--run-qemu"', "application.run()"),
                           ('"--bridge-integrations"', "bridge.run()")):
            path = main[main.index(f"arguments.first == {mode}"):]
            self.assertLess(path.index("keepRunningWhileWindowless()"), path.index(loop), mode)


if __name__ == "__main__":
    unittest.main()
