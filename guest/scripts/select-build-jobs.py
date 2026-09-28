#!/usr/bin/env python3
"""Choose Hyprland compiler parallelism within the Linux builder's memory budget."""

import argparse
import os
from pathlib import Path
import re
import sys

GIB = 1024 ** 3
RESERVE = GIB
PER_JOB = 3 * GIB // 2


def read_text(path):
    try:
        return path.read_text()
    except OSError:
        return ""


def number(path):
    value = read_text(path).strip()
    return int(value) if value.isdecimal() else None


def cgroup_directories(proc):
    groups = {}
    for line in read_text(proc / "self/cgroup").splitlines():
        _, controllers, group = line.split(":", 2)
        for controller in controllers.split(","):
            groups[controller] = group
    for line in read_text(proc / "self/mountinfo").splitlines():
        before, after = line.split(" - ", 1)
        fields, filesystem = before.split(), after.split()
        if filesystem[0] == "cgroup2" and "" in groups:
            version, group = 2, groups[""]
        elif filesystem[0] == "cgroup" and "memory" in filesystem[2].split(",") and "memory" in groups:
            version, group = 1, groups["memory"]
        else:
            continue
        root, mount = (Path(re.sub(r"\\([0-7]{3})", lambda m: chr(int(m[1], 8)), field))
                       for field in fields[3:5])
        try:
            relative = Path(group).relative_to(root)
        except ValueError:
            continue
        current = mount / relative
        while True:
            yield current, version
            if current == mount:
                break
            current = current.parent


def memory_budget(proc=Path("/proc")):
    memory = {}
    for line in read_text(proc / "meminfo").splitlines():
        fields = line.split()
        if len(fields) == 3 and fields[2] == "kB" and fields[1].isdecimal():
            memory[fields[0].rstrip(":")] = int(fields[1]) * 1024
    budgets = [memory[key] for key in ("MemTotal", "MemAvailable") if key in memory]
    for directory, version in cgroup_directories(proc):
        limits = ("memory.max", "memory.high") if version == 2 else ("memory.limit_in_bytes",)
        usage = number(directory / ("memory.current" if version == 2 else "memory.usage_in_bytes"))
        stats = dict(line.split() for line in read_text(directory / "memory.stat").splitlines())
        reclaimable = int(stats.get("inactive_file" if version == 2 else "total_inactive_file", "0"))
        for name in limits:
            limit = number(directory / name)
            if limit is not None:
                budgets.append(max(0, limit - max(0, usage - reclaimable)) if usage is not None else limit)
    return min(budgets) if budgets else None


def choose_jobs(cpus, budget, override=None):
    if override is not None:
        if not re.fullmatch(r"[1-9][0-9]*", override):
            raise ValueError("OMARCHY_GUEST_BUILD_JOBS must be a positive integer")
        return int(override)
    return min(cpus, max(1, (budget - RESERVE) // PER_JOB)) if budget is not None else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cpus", type=int, required=True)
    args = parser.parse_args()
    if args.cpus < 1:
        parser.error("CPU count must be positive")
    budget = memory_budget()
    override = os.environ.get("OMARCHY_GUEST_BUILD_JOBS")
    try:
        jobs = choose_jobs(args.cpus, budget, override)
    except ValueError as error:
        parser.error(str(error))
    available = f"{budget / GIB:.2f} GiB" if budget is not None else "unknown"
    policy = "explicit override" if override is not None else "1 GiB reserve, 1.5 GiB/job; minimum 1 job"
    print(f"Hyprland build: {jobs} jobs; {args.cpus} CPUs; memory budget {available}; {policy}", file=sys.stderr)
    if budget is not None and budget < RESERVE + PER_JOB:
        print("Hyprland build: low memory; even one compiler job may exhaust this budget. Increase builder memory if killed.", file=sys.stderr)
    print(jobs)


if __name__ == "__main__":
    main()
