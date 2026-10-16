#!/usr/bin/env python3
"""Pins, order, naming and the main-loop QoS of the audio runtime patches."""

from __future__ import annotations

import hashlib
import os
from pathlib import Path
import re
import shlex
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
PATCHES = ROOT / "macos/patches"
BUILDER = ROOT / "macos/build-qemu-gpu-runtime.sh"
AUDIO = {
    "hda_no_catch_up_patch": "qemu-hda-no-catch-up.patch",
    "audio_capture_thread_patch": "qemu-sdl-audio-capture-thread.patch",
    "audio_playback_thread_patch": "qemu-sdl-audio-playback-thread.patch",
    "main_loop_qos_patch": "qemu-darwin-main-loop-qos.patch",
}


def apply_line(variable: str) -> str:
    return f'patch -d "$source_dir" -p1 -f -i "${variable}"'


def added(name: str) -> str:
    return "\n".join(line[1:] for line in (PATCHES / name).read_text(encoding="utf-8").splitlines()
                     if line.startswith("+") and not line.startswith("+++"))


class AudioRuntimePatchTests(unittest.TestCase):
    def test_builder_pins_each_patch(self) -> None:
        builder = BUILDER.read_text(encoding="utf-8")
        for variable, name in AUDIO.items():
            pinned = re.search(rf"^{variable}_sha256=([a-f0-9]{{64}})$", builder, re.M)
            self.assertIsNotNone(pinned, variable)
            self.assertEqual(hashlib.sha256((PATCHES / name).read_bytes()).hexdigest(), pinned.group(1), name)
            self.assertIn(f'"${variable}" "${variable}_sha256"', builder)

    def test_threading_and_pacing_follow_the_audio_route_and_recovery(self) -> None:
        builder = BUILDER.read_text(encoding="utf-8")
        order = [builder.index(apply_line(v)) for v in (
            "audio_device_patch", "audio_recovery_patch", "hda_no_catch_up_patch",
            "audio_capture_thread_patch", "audio_playback_thread_patch")]
        self.assertEqual(order, sorted(order))
        self.assertIn(apply_line("main_loop_qos_patch"), builder)

    def test_code_speaks_as_try_omarchy_and_credits_omacvm(self) -> None:
        for name in AUDIO.values():
            text = (PATCHES / name).read_text(encoding="utf-8")
            self.assertNotRegex(added(name), r"(?i)omacvm", name)
            self.assertIn("Adapted from OmacVM's patch of the same name (MIT,", text, name)
        self.assertIn('"Try Omarchy: HDA sound pacing %s"', added("qemu-hda-no-catch-up.patch"))
        self.assertIn("Try Omarchy: sound: the Mac's audio device works again", added("qemu-sdl-audio-playback-thread.patch"))

    def test_main_loop_qos_compiles_and_honours_the_opt_out(self) -> None:
        code = added("qemu-darwin-main-loop-qos.patch")
        function = code[code.index("static void tryomarchy_main_loop_qos(void)"):]
        function = function[: function.index("\n}\n") + 3]
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            source = work / "qos.c"
            # QEMU runs its main loop on a thread of its own (qemu_main), which
            # starts below user-interactive; a process's first thread doesn't.
            source.write_text(
                "#include <pthread.h>\n#include <pthread/qos.h>\n#include <stdio.h>\n#include <stdlib.h>\n"
                "#include <string.h>\n\n"
                f"{function}\n"
                "static void *qemu_main(void *opaque)\n{\n    (void)opaque;\n    tryomarchy_main_loop_qos();\n"
                "    printf(\"%d\\n\", qos_class_self() == QOS_CLASS_USER_INTERACTIVE);\n    return NULL;\n}\n\n"
                "int main(void)\n{\n    pthread_t thread;\n    pthread_attr_t attributes;\n\n"
                "    pthread_attr_init(&attributes);\n"
                "    pthread_attr_set_qos_class_np(&attributes, QOS_CLASS_DEFAULT, 0);\n"
                "    pthread_create(&thread, &attributes, qemu_main, NULL);\n"
                "    pthread_join(thread, NULL);\n    return 0;\n}\n",
                encoding="utf-8",
            )
            binary = work / "qos"
            subprocess.run(shlex.split(os.environ.get("CC", "cc")) + [
                "-Wall", "-Wextra", "-Werror", str(source), "-o", str(binary)], check=True)
            environment = {k: v for k, v in os.environ.items() if k != "TRYOMARCHY_MAIN_LOOP_QOS"}
            raised = subprocess.run([str(binary)], capture_output=True, text=True, check=True, env=environment)
            self.assertEqual(raised.stderr.strip(), "Try Omarchy: main loop QoS: user-interactive")
            self.assertEqual(raised.stdout.strip(), "1")
            kept = subprocess.run([str(binary)], capture_output=True, text=True, check=True,
                                  env={**environment, "TRYOMARCHY_MAIN_LOOP_QOS": "default"})
            self.assertEqual(kept.stderr.strip(), "Try Omarchy: main loop QoS: default")
            self.assertEqual(kept.stdout.strip(), "0")


if __name__ == "__main__":
    unittest.main()
