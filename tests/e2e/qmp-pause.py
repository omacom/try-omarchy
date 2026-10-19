#!/usr/bin/python3 -I
"""Pause the VM through QEMU's QMP socket and continue it, as the app does
across a Mac sleep.

    qmp-pause.py SOCKET SECONDS
"""

import json
import socket
import sys
import time


def main():
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    connection = socket.socket(socket.AF_UNIX)
    connection.connect(sys.argv[1])
    stream = connection.makefile("rw")
    stream.readline()

    def call(command):
        stream.write(json.dumps({"execute": command}) + "\n")
        stream.flush()
        while True:
            reply = json.loads(stream.readline())
            if "return" in reply:
                return
            if "error" in reply:
                raise SystemExit(f"qmp-pause: {command}: {reply['error']}")

    call("qmp_capabilities")
    call("stop")
    time.sleep(float(sys.argv[2]))
    call("cont")


if __name__ == "__main__":
    main()
