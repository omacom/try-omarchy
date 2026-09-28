import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

GUEST = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("build_jobs", GUEST / "scripts/select-build-jobs.py")
jobs = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(jobs)


class BuildJobsTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.proc = self.root / "proc"
        (self.proc / "self").mkdir(parents=True)
        self.write("meminfo", "MemTotal: 25165824 kB\nMemAvailable: 23068672 kB\n")
        self.mount = self.root / "cgroup"
        self.mount.mkdir()

    def write(self, name, value):
        (self.proc / name).write_text(value)

    def group(self, version=2, path="/", mount_root="/"):
        mount = str(self.mount).replace(" ", "\\040")
        if version == 2:
            self.write("self/cgroup", f"0::{path}\n")
            suffix = "cgroup2 cgroup rw"
        else:
            self.write("self/cgroup", f"4:memory:{path}\n")
            suffix = "cgroup cgroup rw,memory"
        self.write("self/mountinfo", f"1 0 0:1 {mount_root} {mount} ro - {suffix}\n")

    def test_memory_and_cpu_ceilings(self):
        self.assertEqual(jobs.choose_jobs(8, 6 * jobs.GIB), 3)
        self.assertEqual(jobs.choose_jobs(8, 8 * jobs.GIB), 4)
        self.assertEqual(jobs.choose_jobs(2, 24 * jobs.GIB), 2)
        self.assertEqual(jobs.choose_jobs(16, 0), 1)
        self.assertEqual(jobs.choose_jobs(16, None), 1)

    def test_explicit_override_and_invalid_values(self):
        self.assertEqual(jobs.choose_jobs(2, jobs.GIB, "5"), 5)
        for value in ("", "0", "-2", "1.5", " 2", "auto", "2;echo", "01"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                jobs.choose_jobs(8, 6 * jobs.GIB, value)

    def test_available_host_memory_limits_unrestricted_builds(self):
        self.assertEqual(jobs.memory_budget(self.proc), 22 * jobs.GIB)
        self.write("meminfo", "MemTotal: 8388608 kB\nMemAvailable: 2097152 kB\n")
        self.assertEqual(jobs.memory_budget(self.proc), 2 * jobs.GIB)

    def test_missing_memory_information_uses_single_job(self):
        self.write("meminfo", "")
        self.assertIsNone(jobs.memory_budget(self.proc))
        self.assertEqual(jobs.choose_jobs(8, jobs.memory_budget(self.proc)), 1)

    def test_v2_limit_and_reclaimable_cache(self):
        self.group()
        (self.mount / "memory.max").write_text(str(6 * jobs.GIB))
        (self.mount / "memory.current").write_text(str(4 * jobs.GIB))
        (self.mount / "memory.stat").write_text(f"inactive_file {3 * jobs.GIB}\n")
        self.assertEqual(jobs.memory_budget(self.proc), 5 * jobs.GIB)

    def test_v2_unlimited_and_high_pressure_boundary(self):
        self.group()
        (self.mount / "memory.max").write_text("max")
        (self.mount / "memory.high").write_text("max")
        self.assertEqual(jobs.memory_budget(self.proc), 22 * jobs.GIB)
        (self.mount / "memory.high").write_text(str(4 * jobs.GIB))
        (self.mount / "memory.current").write_text(str(5 * jobs.GIB))
        self.assertEqual(jobs.memory_budget(self.proc), 0)

    def test_nested_parent_limit_and_mount_root(self):
        self.group(path="/slice/build/child", mount_root="/slice")
        child = self.mount / "build/child"
        child.mkdir(parents=True)
        (child / "memory.max").write_text("max")
        (child.parent / "memory.max").write_text(str(6 * jobs.GIB))
        (self.mount / "memory.max").write_text(str(4 * jobs.GIB))
        self.assertEqual(jobs.memory_budget(self.proc), 4 * jobs.GIB)

    def test_v1_hierarchical_limit_and_cache(self):
        self.group(version=1)
        (self.mount / "memory.limit_in_bytes").write_text(str(6 * jobs.GIB))
        (self.mount / "memory.usage_in_bytes").write_text(str(4 * jobs.GIB))
        (self.mount / "memory.stat").write_text(f"total_inactive_file {3 * jobs.GIB}\n")
        self.assertEqual(jobs.memory_budget(self.proc), 5 * jobs.GIB)
        (self.mount / "memory.limit_in_bytes").write_text(str(2 ** 63 - 4096))
        self.assertEqual(jobs.memory_budget(self.proc), 22 * jobs.GIB)

    def test_container_override_forwarding_and_early_rejection(self):
        binary = self.root / "bin"
        binary.mkdir()
        log = self.root / "docker.jsonl"
        docker = binary / "docker"
        docker.write_text("#!/usr/bin/env python3\nimport json,os,sys\n"
                          "with open(os.environ['DOCKER_TEST_LOG'],'a') as f: f.write(json.dumps(sys.argv[1:])+'\\n')\n"
                          "if sys.argv[1:3]==['image','inspect']: print('sha256:fixture')\n")
        docker.chmod(0o755)
        env = dict(os.environ, PATH=str(binary) + os.pathsep + os.environ["PATH"], DOCKER_TEST_LOG=str(log))
        env.pop("OMARCHY_GUEST_BUILD_JOBS", None)
        command = ["/bin/bash", str(GUEST / "build-container.sh"), "--output", str(self.root / "output")]
        for value in (None, "3"):
            with self.subTest(value=value):
                if value is not None:
                    env["OMARCHY_GUEST_BUILD_JOBS"] = value
                subprocess.run(command, env=env, check=True, capture_output=True, text=True)
                invocation = json.loads(log.read_text().splitlines()[-1])
                self.assertEqual(invocation[0], "run")
                override = [item for item in invocation if item.startswith("OMARCHY_GUEST_BUILD_JOBS=")]
                self.assertEqual(override, [] if value is None else ["OMARCHY_GUEST_BUILD_JOBS=3"])
        before = log.read_bytes()
        env["OMARCHY_GUEST_BUILD_JOBS"] = "0"
        result = subprocess.run(command, env=env, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("positive integer", result.stderr)
        self.assertEqual(log.read_bytes(), before)


if __name__ == "__main__":
    unittest.main()
