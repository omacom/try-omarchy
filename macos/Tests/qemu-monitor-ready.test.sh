#!/bin/bash

# Exercise the shipped command against QEMU-like Unix sockets, including a
# full listen backlog during initialization. Python is test infrastructure;
# the helper itself runs with an unusable Python on PATH.
set -euo pipefail
macos_dir=$(cd "$(dirname "$0")/.." && pwd -P)
helper="$macos_dir/.build/debug/omarchy-vm-helper"
[[ -x $helper ]] || { echo 'Build the native helper with swift build first' >&2; exit 1; }
scratch=$(mktemp -d '/private/tmp/qmp-ready.XXXXXX')
trap 'rm -rf "$scratch"' EXIT

python3 - "$helper" "$scratch" <<'PY'
import contextlib
import os
from pathlib import Path
import subprocess
import sys
import time

helper, scratch = sys.argv[1], Path(sys.argv[2])
# Match the launcher's standardized public /tmp pathname; Foundation strips
# the /private prefix, and QMPConnection rejects nonstandard socket paths.
scratch = Path("/tmp") / scratch.name
python_log = scratch / "python.log"
python_shim = scratch / "python3"
python_shim.write_text(f'#!/bin/bash\nprintf unexpected > "{python_log}"\nexit 127\n')
python_shim.chmod(0o755)
environment = dict(os.environ, PATH=str(scratch))

server_code = r'''
import json, os, socket, sys, threading, time
path, delay, mode, log = sys.argv[1:]
server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.bind(path)
server.listen(1)
if mode == "exit":
    threading.Timer(0.3, lambda: os._exit(0)).start()
time.sleep(float(delay))
rejected = False
while True:
    client, _ = server.accept()
    with client:
        client.settimeout(2)
        try:
            if mode == "exit":
                time.sleep(2)
                continue
            # Split the greeting across writes to exercise stream parsing.
            client.sendall(b'{"Q')
            time.sleep(0.01)
            client.sendall(b'MP": {"version": {}, "capabilities": []}}\r\n')
            with client.makefile("rb") as stream:
                request = json.loads(stream.readline())
            assert request["execute"] == "qmp_capabilities"
            if mode == "retry" and not rejected:
                rejected = True
                response = {"error": {"desc": "initializing"}, "id": request["id"]}
            else:
                response = {"return": {}, "id": request["id"]}
            # QMP may interleave events with command responses.
            client.sendall(b'{"event": "RESUME"}\r\n')
            client.sendall(json.dumps(response).encode() + b"\r\n")
            assert client.recv(1) == b"", "readiness probe did not close"
            if "return" in response:
                with open(log, "a") as output:
                    output.write("negotiated and closed\n")
        except (OSError, ValueError):
            # Probes queued during init can have timed out before accept().
            pass
'''

@contextlib.contextmanager
def monitor(name, delay=0, mode="ready"):
    path = scratch / (name + ".sock")
    log = scratch / (name + ".log")
    process = subprocess.Popen([sys.executable, "-c", server_code, str(path), str(delay), mode, str(log)])
    try:
        deadline = time.monotonic() + 10
        while not path.is_socket():
            assert process.poll() is None, "monitor exited before binding"
            assert time.monotonic() < deadline, "monitor did not bind"
            time.sleep(0.01)
        yield process, path, log
    finally:
        if process.poll() is None:
            process.terminate()
        process.wait(timeout=3)

for name, delay, mode in [("slow", 0.8, "ready"), ("fast", 0, "ready"), ("retry", 0, "retry")]:
    with monitor(name, delay, mode) as (process, path, log):
        result = subprocess.run([helper, "--wait-for-qmp", str(process.pid), str(path)],
                                env=environment, capture_output=True, text=True, timeout=10)
        assert result.returncode == 0, (name, result.stderr)
        # The handshake transcript proves readiness and connection cleanup;
        # elapsed wall time also includes unrelated CI scheduling delays.
        deadline = time.monotonic() + 10
        while not log.exists() and time.monotonic() < deadline:
            time.sleep(0.01)
        assert log.exists(), "probe did not negotiate capabilities and release its connection"

with monitor("exit", mode="exit") as (process, path, _):
    result = subprocess.run([helper, "--wait-for-qmp", str(process.pid), str(path)],
                            env=environment, capture_output=True, text=True, timeout=10)
    assert result.returncode == 1, result
    assert "QEMU exited" in result.stderr, result.stderr

assert not python_log.exists(), "native readiness command invoked Python"
print("qemu-monitor-ready.test: PASS")
PY
