#!/usr/bin/env python3
"""Read-only interval CPU/memory sampling on macOS or Linux (100% = one core)."""

import argparse
from contextlib import nullcontext
import ctypes
import datetime
import json
import math
import os
from pathlib import Path
import platform
import socket
import statistics
import sys
import time


class DarwinUsage(ctypes.Structure):
    _fields_ = [("uuid", ctypes.c_uint8 * 16)] + [
        (name, ctypes.c_uint64) for name in (
            "user", "system", "idle_wakeups", "interrupt_wakeups", "pageins",
            "wired", "resident", "footprint", "start", "exit")]


class Timebase(ctypes.Structure):
    _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]


class QMPStatus:
    """Observe VM state without pausing, resuming, or changing the guest."""

    def __init__(self, path):
        self.socket = socket.socket(socket.AF_UNIX)
        self.socket.settimeout(3)
        self.stream = None
        self.sequence = 0
        try:
            self.socket.connect(str(path))
            self.stream = self.socket.makefile("rwb")
            if "QMP" not in self.message():
                raise RuntimeError("invalid QMP greeting")
            self.command("qmp_capabilities")
        except Exception:
            self.close()
            raise

    def message(self):
        line = self.stream.readline(1024 * 1024 + 1)
        if not line or len(line) > 1024 * 1024:
            raise RuntimeError("QMP disconnected or exceeded the message limit")
        try:
            message = json.loads(line)
        except (ValueError, UnicodeError) as error:
            raise RuntimeError("invalid QMP message") from error
        if not isinstance(message, dict):
            raise RuntimeError("invalid QMP message")
        return message

    def command(self, name):
        self.sequence += 1
        self.stream.write((json.dumps({"execute": name, "id": self.sequence}) + "\n").encode())
        self.stream.flush()
        # Bound unsolicited messages as well as individual blocking reads.
        deadline = time.monotonic() + 3
        for _ in range(256):
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise RuntimeError("QMP reply timed out")
            self.socket.settimeout(remaining)
            message = self.message()
            if message.get("event") in {"STOP", "RESET", "SUSPEND", "SHUTDOWN", "BLOCK_IO_ERROR", "GUEST_PANICKED"}:
                raise RuntimeError(f"VM event {message['event']} invalidated this performance sample")
            if message.get("id") == self.sequence:
                if "error" in message or "return" not in message:
                    raise RuntimeError(f"QMP {name} failed: {message.get('error')}")
                return message["return"]
        raise RuntimeError("QMP did not reply within the message limit")

    def check(self):
        status = self.command("query-status")
        if not isinstance(status, dict) or status.get("running") is not True or status.get("status") != "running":
            raise RuntimeError(f"VM is not running normally: {status}; low CPU here is not a desktop idle measurement")

    def close(self):
        if self.stream is not None:
            self.stream.close()
        self.socket.close()

    def __enter__(self):
        try:
            self.check()
        except Exception:
            self.close()
            raise
        return self

    def __exit__(self, *args):
        self.close()


def darwin_reader():
    libproc = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
    libproc.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
    libproc.proc_pid_rusage.restype = ctypes.c_int
    libsystem = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
    tb = Timebase()
    if libsystem.mach_timebase_info(ctypes.byref(tb)) or not tb.denom:
        raise RuntimeError("cannot read Mach timebase")
    # ri_user_time/ri_system_time use Mach ticks, not nanoseconds on Apple Silicon.
    seconds_per_tick = tb.numer / tb.denom / 1e9

    def read(pid):
        usage = DarwinUsage()
        if libproc.proc_pid_rusage(pid, 0, ctypes.byref(usage)):
            raise OSError(ctypes.get_errno(), f"cannot read PID {pid}")
        return {
            "identity": usage.start,
            "cpu_seconds": (usage.user + usage.system) * seconds_per_tick,
            "resident_mib": usage.resident / 2**20,
            "physical_footprint_mib": usage.footprint / 2**20,
            "package_idle_wakeups": usage.idle_wakeups,
            "pageins": usage.pageins,
        }

    return read


def linux_reader():
    ticks_per_second = os.sysconf("SC_CLK_TCK")
    page_bytes = os.sysconf("SC_PAGE_SIZE")

    def read(pid):
        root = Path(f"/proc/{pid}")
        stat = (root / "stat").read_text()
        # comm can contain spaces and parentheses. Fields after the final ')' start at 3.
        fields = stat[stat.rindex(")") + 2:].split()
        result = {
            "identity": int(fields[19]),
            "cpu_seconds": (int(fields[11]) + int(fields[12])) / ticks_per_second,
            "resident_mib": int(fields[21]) * page_bytes / 2**20,
        }
        try:
            lines = (root / "smaps_rollup").read_text().splitlines()
            memory = {line.split(":")[0]: int(line.split()[1]) / 1024
                      for line in lines if line.startswith(("Pss:", "SwapPss:"))}
            result["proportional_resident_mib"] = memory["Pss"]
            result["proportional_swap_mib"] = memory["SwapPss"]
        except PermissionError:
            # RSS is still available when Linux restricts detailed memory accounting.
            pass
        return result

    return read


def system_reader(system):
    if system == "Linux":
        def read():
            # Exclude guest/guest_nice: Linux already includes them in user/nice.
            ticks = list(map(int, Path("/proc/stat").read_text().splitlines()[0].split()[1:9]))
            return ticks, ticks[3] + ticks[4]
        return read, None
    libsystem = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
    libsystem.mach_host_self.restype = ctypes.c_uint32
    libsystem.host_statistics.argtypes = [ctypes.c_uint32, ctypes.c_int,
                                         ctypes.POINTER(ctypes.c_uint32),
                                         ctypes.POINTER(ctypes.c_uint32)]
    host = libsystem.mach_host_self()

    def read():
        ticks = (ctypes.c_uint32 * 4)()
        count = ctypes.c_uint32(4)
        # HOST_CPU_LOAD_INFO: user, system, idle, nice; counters wrap at 32 bits.
        if libsystem.host_statistics(host, 3, ticks, ctypes.byref(count)):
            raise RuntimeError("cannot read host CPU counters")
        return list(ticks), ticks[2]
    return read, 2**32


def system_percent(before, after, counter_modulus):
    deltas = [end - start for start, end in zip(before[0], after[0])]
    idle = after[1] - before[1]
    if counter_modulus:
        deltas = [delta % counter_modulus for delta in deltas]
        idle %= counter_modulus
    total = sum(deltas)
    return 100 * (total - idle) / total if total else None


def positive(value):
    number = float(value)
    if not math.isfinite(number) or number <= 0:
        raise argparse.ArgumentTypeError("must be a finite positive number")
    return number


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pid", type=int, action="append", required=True,
                        help="repeat to include QEMU and its integration helpers")
    parser.add_argument("--seconds", type=positive, default=30)
    parser.add_argument("--interval", type=positive, default=1)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--qmp", type=Path, help="reject samples if this QEMU stops, resets, or reports an I/O error")
    args = parser.parse_args()
    if any(pid <= 0 for pid in args.pid) or len(set(args.pid)) != len(args.pid):
        parser.error("PIDs must be positive and unique")
    system = platform.system()
    if system not in ("Darwin", "Linux"):
        parser.error("requires macOS or Linux")
    with QMPStatus(args.qmp) if args.qmp else nullcontext() as monitor:
        result = collect(args, system, monitor)
    text = json.dumps(result, indent=2) + "\n"
    if args.output:
        args.output.write_text(text)
    print(text, end="")


def collect(args, system, monitor):
    read = darwin_reader() if system == "Darwin" else linux_reader()
    read_system, counter_modulus = system_reader(system)
    started = time.monotonic()
    first = {pid: read(pid) for pid in args.pid}
    first_system = read_system()
    previous, previous_time = first, started
    previous_system = first_system
    samples = []
    deadline = started + args.seconds
    next_sample = min(deadline, started + args.interval)
    while True:
        time.sleep(max(0, next_sample - time.monotonic()))
        if monitor is not None:
            monitor.check()
        current = {pid: read(pid) for pid in args.pid}
        current_system = read_system()
        timestamp = time.monotonic()
        for pid in args.pid:
            if current[pid]["identity"] != first[pid]["identity"]:
                raise RuntimeError(f"PID {pid} was reused during sampling")
        cpu = sum(current[pid]["cpu_seconds"] - previous[pid]["cpu_seconds"]
                  for pid in args.pid)
        samples.append({
            "elapsed_seconds": timestamp - started,
            "cpu_one_core_percent": 100 * cpu / (timestamp - previous_time),
            "system_cpu_busy_percent": system_percent(previous_system, current_system, counter_modulus),
            "processes": current,
        })
        previous, previous_time = current, timestamp
        previous_system = current_system
        if timestamp >= deadline:
            break
        next_sample = min(deadline, next_sample + args.interval)
    elapsed = previous_time - started
    mean_cpu = 100 * sum(previous[pid]["cpu_seconds"] - first[pid]["cpu_seconds"]
                         for pid in args.pid) / elapsed
    result = {
        "utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "platform": system,
        "architecture": platform.machine(),
        "logical_cpu_count": os.cpu_count(),
        "seconds": elapsed,
        "cpu_one_core_percent": mean_cpu,
        "cpu_host_capacity_percent": mean_cpu / os.cpu_count(),
        "system_cpu_busy_percent": system_percent(first_system, previous_system, counter_modulus),
        "median_interval_cpu_one_core_percent": statistics.median(
            sample["cpu_one_core_percent"] for sample in samples),
        "memory_note": "macOS footprint includes compressed memory; Linux PSS and RSS are different metrics",
        "system_cpu_note": "includes every process and kernel work; cannot attribute background activity to the selected PIDs",
        "qmp_state_checked": monitor is not None,
        "samples": samples,
    }
    return result


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError) as error:
        sys.exit(f"profile-process: {error}")
