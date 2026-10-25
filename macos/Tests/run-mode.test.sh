#!/bin/bash
#
# The helper's run mode (--run-vm) as a real process, driven over its
# standard input and output the way an embedding app drives it. The kit is
# built from the test build's helper, its factory is served from a loopback
# server, and its launcher serves QMP but runs no VM. Checks the download,
# the progress and ready events, shutdown over QMP from the command and from
# the end of input, the stored settings winning over the configuration, the
# launcher's errors as stable codes, signals, bridged networking from the
# configuration, and the configurations the run mode refuses. Needs no hypervisor and no network.

set -euo pipefail
macos_dir=$(cd "$(dirname "$0")/.." && pwd -P)
helper="$macos_dir/.build/debug/omarchy-vm-helper"
[[ -x $helper ]] || { echo 'run-mode.test: build the helper with swift build first' >&2; exit 1; }
scratch=$(mktemp -d '/private/tmp/omarchy-run-mode.XXXXXX')
trap 'rm -rf "$scratch"' EXIT

PYTHONDONTWRITEBYTECODE=1 python3 - "$helper" "$scratch" <<'PY'
import hashlib
import http.server
import json
import os
from pathlib import Path
import plistlib
import queue
import shutil
import signal
import subprocess
import sys
import threading
import time

helper, scratch = Path(sys.argv[1]), Path(sys.argv[2])


def fail(message):
    print(f"run-mode.test: {message}", file=sys.stderr)
    sys.exit(1)


# The kit: the built helper, the launcher below, and a factory to download.
kit = scratch / "TryOmarchyKit.bundle"
contents = kit / "Contents"
for folder in ("MacOS", "Resources/scripts", "Resources/guest"):
    (contents / folder).mkdir(parents=True)
(contents / "Info.plist").write_bytes(plistlib.dumps({
    "CFBundleExecutable": "omarchy-vm-helper",
    "CFBundlePackageType": "BNDL",
    "LSUIElement": True,
    "NSHighResolutionCapable": True,
}))
shutil.copy2(helper, contents / "MacOS/omarchy-vm-helper")

image = os.urandom(3 << 20)
image_sha = hashlib.sha256(image).hexdigest()
identity = hashlib.sha256(b"run-mode-test-disk").hexdigest()
release = scratch / "release"
release.mkdir()
part_bytes = 2 << 20
parts = [image[offset:offset + part_bytes] for offset in range(0, len(image), part_bytes)]
for index, data in enumerate(parts, 1):
    (release / f"omarchy.img.zst.{index:03d}").write_bytes(data)
(contents / "Resources/guest/factory.json").write_text(json.dumps({
    "format": 1, "kind": "upstream-shell-factory", "boot": "uefi-limine",
    "disk": {"path": "omarchy.img", "bytes": 8 << 20, "sha256": identity},
    "compressed": {"path": "omarchy.img.zst", "sha256": image_sha},
}))


class Release(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *arguments, **keywords):
        super().__init__(*arguments, directory=str(release), **keywords)

    def log_message(self, *arguments):
        pass


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Release)
threading.Thread(target=server.serve_forever, daemon=True).start()
base_url = f"http://127.0.0.1:{server.server_address[1]}/"
(contents / "Resources/guest/download.json").write_text(json.dumps({
    "format": 1, "kind": "try-omarchy-factory-download", "identity": identity,
    "image": {"bytes": len(image), "sha256": image_sha},
    "parts": [{"url": f"{base_url}omarchy.img.zst.{index:03d}", "bytes": len(data),
               "sha256": hashlib.sha256(data).hexdigest()} for index, data in enumerate(parts, 1)],
}))

# The launcher: it prepares the VM folder as run-qemu-gpu.sh does, reports its
# phases, and serves QMP until Omarchy is asked to power down. FAKE_LAUNCHER
# names a failure to report instead.
launcher = contents / "Resources/scripts/run-qemu-gpu.sh"
launcher.write_text("#!/usr/bin/env python3\n" + r'''
import hashlib, json, os, random, shutil, signal, socket, string, sys, threading, time
from pathlib import Path

log = Path(os.environ["FAKE_LAUNCHER_LOG"])
def record(entry):
    with log.open("a") as output:
        output.write(json.dumps(entry) + "\n")
def say(line):
    print(f"[qemu-gpu] {line}", file=sys.stderr, flush=True)

record({"environment": {key: value for key, value in os.environ.items()
                        if key.startswith(("OMARCHY_", "TRYOMARCHY_"))}})
say("Launch phase: checking")
failure = os.environ.get("FAKE_LAUNCHER", "")
if failure:
    print(f"run-qemu-gpu: {failure}", file=sys.stderr, flush=True)
    sys.exit(1)

root = Path(os.environ["OMARCHY_QEMU_GPU_STATE_ROOT"])
root.mkdir(mode=0o700, parents=True, exist_ok=True)
marker = root / ".omarchy-qemu-storage"
if not marker.exists():
    marker.write_text("omarchy-qemu-storage-root-v1\n")
    marker.chmod(0o600)
(root / "shell").mkdir(mode=0o700, exist_ok=True)
disk = root / "shell/disk.img"
if not disk.exists():
    factory = Path(os.environ["OMARCHY_QEMU_GPU_FACTORY_IMAGE"])
    record({"factory": hashlib.sha256(factory.read_bytes()).hexdigest()})
    say("Launch phase: preparing")
    disk.write_bytes(b"\0" * 4096)

token = "".join(random.choice(string.ascii_letters + string.digits) for _ in range(6))
run = Path(f"/private/tmp/omarchy-qemu-gpu.{token}")
run.mkdir(mode=0o700)
signal.signal(signal.SIGTERM, lambda *_: (shutil.rmtree(run, ignore_errors=True), os._exit(143)))
monitor = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
monitor.bind(str(run / "qmp.sock"))
monitor.listen(8)
powered_down = threading.Event()

def serve(client):
    with client, client.makefile("rb") as stream:
        client.sendall(b'{"QMP": {"version": {}, "capabilities": []}}\r\n')
        for line in stream:
            request = json.loads(line)
            command = request.get("execute")
            record({"qmp": command})
            answer = {"status": "running", "running": True} if command == "query-status" else {}
            response = {"return": answer}
            if "id" in request:
                response["id"] = request["id"]
            client.sendall(json.dumps(response).encode() + b"\r\n")
            if command == "system_powerdown" and not os.environ.get("FAKE_LINUX_KEEPS_RUNNING"):
                powered_down.set()

def accept():
    while True:
        client, _ = monitor.accept()
        threading.Thread(target=serve, args=(client,), daemon=True).start()

threading.Thread(target=accept, daemon=True).start()
say("Launch phase: starting")
say(f"Ready. QMP: /tmp/omarchy-qemu-gpu.{token}/qmp.sock")
powered_down.wait()
time.sleep(0.2)
shutil.rmtree(run, ignore_errors=True)
sys.exit(0)
''')
launcher.chmod(0o755)

vm = scratch / "vm"
log = scratch / "launcher.log"
base_environment = {
    key: os.environ[key] for key in ("PATH", "HOME", "TMPDIR", "USER", "LANG") if key in os.environ
}
base_environment.update({
    "OMARCHY_QEMU_GPU_STATE_ROOT": str(vm),
    "OMARCHY_VM_RUN_TEST_SKIP_PREFLIGHT": "1",
    # Keeps the run mode's storage-location.json out of the person's
    # Application Support.
    "CFFIXED_USER_HOME": str(scratch / "home"),
    "FAKE_LAUNCHER_LOG": str(log),
})
(scratch / "home").mkdir()


class RunMode:
    def __init__(self, configuration, **environment):
        self.process = subprocess.Popen(
            [str(contents / "MacOS/omarchy-vm-helper"), "--run-vm"],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            env={**base_environment, **environment})
        self.events = queue.Queue()
        self.seen = []
        self.stderr = []
        threading.Thread(target=self._read, daemon=True).start()
        threading.Thread(target=lambda: self.stderr.extend(self.process.stderr), daemon=True).start()
        line = configuration if isinstance(configuration, str) else json.dumps(configuration)
        self.process.stdin.write(line.encode() + b"\n")
        self.process.stdin.flush()

    def _read(self):
        for line in self.process.stdout:
            try:
                event = json.loads(line)
            except ValueError:
                event = {"unreadable": line.decode(errors="replace")}
            self.events.put(event)
        self.events.put(None)

    def diagnostics(self):
        return f"events {self.seen}; helper said:\n" + b"".join(self.stderr).decode(errors="replace")[-4000:]

    def next(self, timeout=30):
        try:
            event = self.events.get(timeout=timeout)
        except queue.Empty:
            fail(f"no event within {timeout} s; {self.diagnostics()}")
        if event is None:
            fail(f"the run mode closed its output early; {self.diagnostics()}")
        self.seen.append(event)
        if event.get("version") != 1 or "event" not in event:
            fail(f"not a protocol event: {event}")
        return event

    def until(self, name):
        while True:
            event = self.next()
            if event["event"] == name:
                return event
            if event["event"] in ("error", "exited"):
                fail(f"expected {name}; {self.diagnostics()}")

    def send(self, command):
        self.process.stdin.write(json.dumps({"version": 1, "command": command}).encode() + b"\n")
        self.process.stdin.flush()

    def close_input(self):
        self.process.stdin.close()

    def finish(self, status):
        event = self.next()
        if event != {"version": 1, "event": "exited", "status": status}:
            fail(f"expected exited {status}; {self.diagnostics()}")
        try:
            code = self.process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            self.process.kill()
            fail(f"the run mode kept running after exited; {self.diagnostics()}")
        if self.events.get(timeout=5) is not None:
            fail(f"an event followed exited; {self.diagnostics()}")
        return code

    def phases(self):
        return [event.get("phase") for event in self.seen if event["event"] == "progress"]


def launcher_log():
    entries = [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
    log.unlink(missing_ok=True)
    return entries


configuration = {"version": 1, "productName": "Run Mode Test", "bridges": ["clipboard"],
                 "network": "shared", "memoryMiB": 4096, "cpus": 4}

# A first start downloads the image, starts the launcher and reports it ready;
# the shutdown command powers Omarchy down over QMP.
run = RunMode(configuration)
run.until("ready")
phases = run.phases()
for phase in ("downloading", "verifying-download", "checking", "starting"):
    if phase not in phases:
        fail(f"no {phase} progress; {run.diagnostics()}")
if phases.index("verifying-download") > phases.index("checking"):
    fail(f"the launcher started before the download was verified: {phases}")
run.send("shutdown")
if run.next()["event"] != "stopping":
    fail(f"shutdown did not report stopping; {run.diagnostics()}")
if run.finish(0) != 0:
    fail("the run mode did not exit cleanly after a shutdown")
entries = launcher_log()
environment = entries[0]["environment"]
expected = {
    "OMARCHY_PRODUCT_NAME": "Run Mode Test",
    "OMARCHY_QEMU_GPU_BRIDGES": "clipboard settings",
    "OMARCHY_QEMU_GPU_MEMORY_MIB": "4096",
    "OMARCHY_QEMU_GPU_CPUS": "4",
    "OMARCHY_QEMU_GPU_STATE_ROOT": str(vm),
    "OMARCHY_QEMU_GPU_IMMERSIVE": "1",
}
for key, value in expected.items():
    if environment.get(key) != value:
        fail(f"the launcher got {key}={environment.get(key)!r}, not {value!r}")
if "OMARCHY_QEMU_GPU_NATIVE_EXPORTS" in environment:
    fail("a configuration that did not ask for native exports offered them")
if "OMARCHY_QEMU_GPU_DRY_RUN" in environment or "OMARCHY_QEMU_GPU_INSPECT_ONLY" in environment:
    fail("the run mode passed the launcher's test settings on")
if {"factory": image_sha} not in entries:
    fail(f"the launcher did not get the downloaded image: {entries}")
if {"qmp": "system_powerdown"} not in entries:
    fail(f"shutdown did not reach QMP: {entries}")

# A second start finds the VM, so it downloads nothing, and takes the
# settings stored in the VM's folder over the configuration's. The end of
# input shuts Omarchy down too.
settings = vm / "settings.json"
settings.write_text(json.dumps({"schemaVersion": 1, "settings": {
    "fullscreenPreferences": {"schemaVersion": 1, "isImmersive": False, "usesNotch": True}}}))
settings.chmod(0o600)
run = RunMode(configuration)
run.until("ready")
if {"downloading", "verifying-download"} & set(run.phases()):
    fail(f"a VM that exists downloaded the image again: {run.phases()}")
run.close_input()
if run.next()["event"] != "stopping":
    fail(f"the end of input did not report stopping; {run.diagnostics()}")
run.finish(0)
entries = launcher_log()
if entries[0]["environment"].get("OMARCHY_QEMU_GPU_IMMERSIVE") != "0":
    fail("the stored Immersive Mode setting did not reach the launcher")
if {"qmp": "system_powerdown"} not in entries:
    fail(f"the end of input did not reach QMP: {entries}")

# Only a configuration that asks for native exports gets the outbox.
run = RunMode({**configuration, "nativeExports": True})
run.until("ready")
run.send("shutdown")
run.until("exited")
run.process.wait(timeout=10)
if launcher_log()[0]["environment"].get("OMARCHY_QEMU_GPU_NATIVE_EXPORTS") != "1":
    fail("a configuration that asked for native exports did not get the outbox")

# A stored bridged choice that cannot start says so in a notice, then starts
# with shared networking. A kit asks the daemon its embedding app registered,
# through the kit's client, before it starts anything.
def stored_bridged_start(**environment):
    settings.write_text(json.dumps({"schemaVersion": 1, "settings": {"networkPreferences": {
        "version": 1, "preferences": {"mode": "bridged", "interface": "en0",
                                      "wifiCompatibility": False, "bridgedSSH": False}}}}))
    settings.chmod(0o600)
    run = RunMode(configuration, **environment)
    run.until("ready")
    notices = [event for event in run.seen if event["event"] == "notice"]
    run.send("shutdown")
    run.until("exited")
    run.process.wait(timeout=10)
    mode = launcher_log()[0]["environment"].get("OMARCHY_NETWORK_MODE")
    return notices, mode, run


notices, mode, run = stored_bridged_start()
if mode != "nat" or [notice["code"] for notice in notices] != ["bridged-network-unavailable"]:
    fail(f"a kit without a networking runtime started {mode} with {notices}; {run.diagnostics()}")
if run.seen[0]["event"] != "notice" or "Run Mode Test" not in notices[0]["message"]:
    fail(f"the notice did not come first or name the product: {run.seen}")

network = contents / "Resources/network"
network.mkdir()
(network / "launchd.plist").write_bytes(plistlib.dumps({"Label": "dev.tryomarchy.kit.network"}))
(contents / "MacOS/omarchy-network-daemon").write_text("")
client = network / "omarchy-network-client"
client.write_text("""#!/bin/bash
[[ $1 == check && $2 == */Contents/Resources ]] || exit 64
echo "$2" >"$FAKE_NETWORK_CHECKED"
[[ $FAKE_NETWORK == slow ]] && exec sleep 20
[[ $FAKE_NETWORK == approved ]] && exit 0
echo 'Networking service unavailable or this app build is not authorized.' >&2
exit 1
""")
client.chmod(0o755)
checked = scratch / "network-checked"
notices, mode, run = stored_bridged_start(FAKE_NETWORK="missing", FAKE_NETWORK_CHECKED=str(checked))
if mode != "nat" or [notice["code"] for notice in notices] != ["bridged-network-unavailable"]:
    fail(f"an unregistered kit daemon started {mode} with {notices}; {run.diagnostics()}")
if not checked.exists() or b"not authorized" not in b"".join(run.stderr):
    fail(f"the run mode did not ask the kit's client or log its answer; {run.diagnostics()}")
notices, mode, run = stored_bridged_start(FAKE_NETWORK="approved", FAKE_NETWORK_CHECKED=str(checked))
if mode != "bridged" or notices:
    fail(f"a registered kit daemon started {mode} with {notices}; {run.diagnostics()}")

# A daemon that is slow to answer never holds up a shutdown.
settings.write_text(json.dumps({"schemaVersion": 1, "settings": {"networkPreferences": {
    "version": 1, "preferences": {"mode": "bridged", "interface": "en0",
                                  "wifiCompatibility": False, "bridgedSSH": False}}}}))
settings.chmod(0o600)
checked.unlink(missing_ok=True)
run = RunMode(configuration, FAKE_NETWORK="slow", FAKE_NETWORK_CHECKED=str(checked))
deadline = time.monotonic() + 10
while not checked.exists() and time.monotonic() < deadline:
    time.sleep(0.05)
if not checked.exists():
    fail(f"the run mode did not ask the slow client; {run.diagnostics()}")
asked = time.monotonic()
run.send("shutdown")
if run.finish(0) != 0 or time.monotonic() - asked > 5:
    fail(f"a slow networking check held up the shutdown; {run.diagnostics()}")
if launcher_log():
    fail("the launcher started after a shutdown during the networking check")
settings.unlink()

# Bridged networking in the configuration, with nothing stored, uses the first
# adapter the Networking settings list, which they select when none is chosen.
supervisor = network / "omarchy-network-supervisor"
supervisor.write_text("#!/bin/bash\n[[ $1 == --interfaces ]] || exit 64\nprintf '%s\\n' $FAKE_INTERFACES\n")
supervisor.chmod(0o755)
bridged = {**configuration, "network": "bridged"}
run = RunMode(bridged, FAKE_NETWORK="approved", FAKE_NETWORK_CHECKED=str(checked), FAKE_INTERFACES="en7 en0")
run.until("ready")
run.send("shutdown")
run.until("exited")
run.process.wait(timeout=10)
environment = launcher_log()[0]["environment"]
if (environment.get("OMARCHY_NETWORK_MODE"), environment.get("OMARCHY_NETWORK_INTERFACE")) != ("bridged", "en7"):
    fail(f"bridged from the configuration started {environment.get('OMARCHY_NETWORK_MODE')} on "
         f"{environment.get('OMARCHY_NETWORK_INTERFACE')!r}, not on en7; {run.diagnostics()}")
run = RunMode(bridged, FAKE_NETWORK="approved", FAKE_NETWORK_CHECKED=str(checked), FAKE_INTERFACES="")
event = run.next()
if event["event"] != "error" or event["code"] != "bridged-network-unavailable":
    fail(f"bridged with no adapter to bridge gave {event}; {run.diagnostics()}")
run.finish(1)
if launcher_log():
    fail("the launcher started with no adapter to bridge")

# A first signal shuts Omarchy down and waits for it. Two signals, as
# VMRunClient.terminate() sends them, stop it at once, whether they arrive
# together or apart.
def wait_exited(run, within):
    deadline = time.monotonic() + within
    while True:
        event = run.next(timeout=max(0.1, deadline - time.monotonic()))
        if event["event"] == "exited":
            run.process.wait(timeout=10)
            return
        if event["event"] == "error":
            fail(f"a forced stop reported an error; {run.diagnostics()}")


run = RunMode(configuration, FAKE_LINUX_KEEPS_RUNNING="1")
run.until("ready")
run.process.send_signal(signal.SIGTERM)
if run.next()["event"] != "stopping":
    fail(f"a signal did not report stopping; {run.diagnostics()}")
time.sleep(2)
if run.process.poll() is not None:
    fail(f"one signal stopped Omarchy without waiting for it; {run.diagnostics()}")
if {"qmp": "system_powerdown"} not in launcher_log():
    fail("a signal did not ask Omarchy to shut down")
run.process.send_signal(signal.SIGTERM)
wait_exited(run, 5)

run = RunMode(configuration, FAKE_LINUX_KEEPS_RUNNING="1")
run.until("ready")
os.kill(run.process.pid, signal.SIGTERM)
os.kill(run.process.pid, signal.SIGTERM)
if run.next()["event"] != "stopping":
    fail(f"two signals did not report stopping; {run.diagnostics()}")
wait_exited(run, 5)
launcher_log()

# The launcher's own explanation becomes a stable error code.
for explanation, code in [("this VM is already open", "vm-already-open"),
                          ("the Omarchy VM requires an APFS volume; /Volumes/X is on exfat", "volume-not-apfs"),
                          ("not enough free space for the Omarchy VM", "not-enough-space")]:
    run = RunMode(configuration, FAKE_LAUNCHER=explanation)
    while True:
        event = run.next()
        if event["event"] == "error":
            break
        if event["event"] != "progress":
            fail(f"expected progress before the error; {run.diagnostics()}")
    if event["code"] != code or not event["message"]:
        fail(f"{explanation!r} gave {event}, not {code}")
    if run.finish(1) != 1:
        fail("a failed launch did not exit with status 1")
    launcher_log()

# Configurations the run mode refuses before it starts anything.
for line, code, status in [
    ('{"version":1}', "invalid-configuration", 64),
    ("not json", "invalid-configuration", 64),
    (json.dumps({**configuration, "version": 2}), "invalid-configuration", 64),
    (json.dumps({**configuration, "network": "wifi"}), "invalid-configuration", 64),
    (json.dumps({key: value for key, value in configuration.items() if key != "network"}), "invalid-configuration", 64),
    (json.dumps({**configuration, "network": "bridged"}), "bridged-network-unavailable", 1),
]:
    run = RunMode(line)
    event = run.next()
    if event["event"] != "error" or event["code"] != code:
        fail(f"{line} gave {event}, not {code}")
    if run.finish(status) != status:
        fail(f"{line} exited with an unexpected status")
    if log.exists():
        fail(f"{line} started the launcher")

server.shutdown()
print("run-mode.test: PASS")
PY
