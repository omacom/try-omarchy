#!/usr/bin/python3 -I
"""Press keys on the VM's keyboard through QEMU's QMP socket (send-key), the
path a Mac keyboard takes into the guest.

    qmp-keys.py SOCKET COMBO...       COMBO: qcodes joined by +, e.g. meta_l+ret
    qmp-keys.py SOCKET --text TEXT    TEXT: letters, digits, space and - . / > _
"""

import json
import socket
import sys
import time

SHIFTED = {">": "dot", "_": "minus"}
PLAIN = {" ": "spc", "-": "minus", ".": "dot", "/": "slash"}


def qcodes_for(character):
    if character.isascii() and (character.isalpha() and character.islower() or character.isdigit()):
        return [character]
    if character in PLAIN:
        return [PLAIN[character]]
    if character in SHIFTED:
        return ["shift", SHIFTED[character]]
    raise SystemExit(f"qmp-keys: cannot type {character!r}")


def main():
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)
    connection = socket.socket(socket.AF_UNIX)
    connection.connect(sys.argv[1])
    stream = connection.makefile("rw")

    def call(command, **arguments):
        stream.write(json.dumps({"execute": command, **({"arguments": arguments} if arguments else {})}) + "\n")
        stream.flush()
        while True:
            reply = json.loads(stream.readline())
            if "return" in reply:
                return
            if "error" in reply:
                raise SystemExit(f"qmp-keys: {reply['error'].get('desc', reply['error'])}")

    json.loads(stream.readline())
    call("qmp_capabilities")
    if sys.argv[2] == "--text":
        combos = [qcodes_for(character) for character in " ".join(sys.argv[3:])]
    else:
        combos = [combo.split("+") for combo in sys.argv[2:]]
    # QEMU releases a combination after its hold time; the next one waits for
    # that, or its keys are lost.
    for combo in combos:
        call("send-key", keys=[{"type": "qcode", "data": key} for key in combo], **{"hold-time": 40})
        time.sleep(0.12)


if __name__ == "__main__":
    main()
