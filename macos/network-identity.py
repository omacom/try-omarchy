#!/usr/bin/env python3
"""Persistent bridged identity shared by the launcher and networking editor."""
import fcntl
import json
import os
import re
import secrets
import stat
import sys
import uuid
from contextlib import ExitStack


class IdentityError(Exception):
    pass


def valid_mac(value):
    return isinstance(value, str) and re.fullmatch(r"02(?::[0-9a-f]{2}){5}", value) is not None


def new_mac():
    return "02:" + ":".join(f"{byte:02x}" for byte in secrets.token_bytes(5))


def private_fd(stack, name, parent=None, directory=False, create=False):
    flags = os.O_RDONLY if directory else os.O_RDWR
    flags |= os.O_NOFOLLOW | os.O_NONBLOCK
    if directory:
        flags |= os.O_DIRECTORY
        if create:
            try:
                os.mkdir(name, 0o700, dir_fd=parent)
            except FileExistsError:
                pass
    if create and not directory:
        try:
            fd = os.open(name, flags | os.O_CREAT | os.O_EXCL, 0o600, dir_fd=parent)
        except FileExistsError:
            fd = os.open(name, flags, dir_fd=parent)
    else:
        fd = os.open(name, flags, dir_fd=parent)
    stack.callback(os.close, fd)
    info = os.fstat(fd)
    kind = stat.S_ISDIR if directory else stat.S_ISREG
    if (not kind(info.st_mode) or info.st_uid != os.getuid()
            or stat.S_IMODE(info.st_mode) != (0o700 if directory else 0o600)
            or (not directory and info.st_nlink != 1)):
        raise IdentityError("Unsafe network identity permissions or file type.")
    return fd


def read_record(stack, directory, name):
    try:
        fd = private_fd(stack, name, directory)
    except FileNotFoundError:
        return None
    if os.fstat(fd).st_size > 4096:
        raise IdentityError("Network identity record is too large.")
    try:
        record = json.loads(os.read(fd, 4097))
        if not isinstance(record, dict) or not valid_mac(record.get("mac")):
            raise ValueError()
        if "version" in record:
            if (type(record["version"]) is not int or record["version"] != 2
                    or not isinstance(record.get("vmID"), str)
                    or str(uuid.UUID(record["vmID"])) != record["vmID"]):
                raise ValueError()
        elif (set(record) != {"disk", "mac"} or not isinstance(record["disk"], list)
              or len(record["disk"]) != 3
              or any(type(value) not in (int, float) for value in record["disk"])):
            raise ValueError()
    except (ValueError, KeyError, TypeError):
        raise IdentityError("The saved network identity is damaged or unsupported. Restore its backup; no new MAC was generated.") from None
    return record


def write_record(directory, name, record):
    temporary = name + "." + secrets.token_hex(8)
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=directory)
    try:
        with os.fdopen(fd, "w") as stream:
            json.dump(record, stream)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.rename(temporary, name, src_dir_fd=directory, dst_dir_fd=directory)
        os.fsync(directory)
    finally:
        try:
            os.unlink(temporary, dir_fd=directory)
        except FileNotFoundError:
            pass


def identity(action, root, key="current", expected=None, proposed=None):
    if not re.fullmatch(r"current|[0-9a-f]{64}", key):
        raise IdentityError("Invalid VM identity key.")
    if action not in ("show", "check", "ensure", "replace"):
        raise IdentityError("Invalid identity operation.")
    with ExitStack() as stack:
        try:
            root_fd = private_fd(stack, root, directory=True)
        except FileNotFoundError:
            if action == "show":
                return ""
            raise
        # Regeneration shares the launcher's flock, excluding running VMs and
        # concurrent launches. ensure is called with the launcher lock held.
        if action in ("check", "replace"):
            locks = private_fd(stack, "locks", root_fd, directory=True)
            workspace = private_fd(stack, key + ".lock", locks)
            try:
                fcntl.flock(workspace, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                raise IdentityError("Shut down this VM before changing its MAC address.") from None
        try:
            directory = private_fd(stack, "network-identities", root_fd, directory=True, create=action == "ensure")
        except FileNotFoundError:
            if action == "show":
                return ""
            raise
        if action in ("ensure", "replace"):
            lock = private_fd(stack, key + ".lock", directory, create=True)
            fcntl.flock(lock, fcntl.LOCK_EX)
        name = key + ".json"
        record = read_record(stack, directory, name)
        if action in ("show", "check"):
            return record["mac"] if record else ""
        original = record
        if action == "replace":
            if record is None or record["mac"] != expected:
                raise IdentityError("The MAC address changed. Reopen Networking and try again.")
            if not valid_mac(proposed) or proposed == expected:
                raise IdentityError("Invalid replacement MAC address.")
        if record is None:
            record = {"version": 2, "vmID": str(uuid.uuid4()), "mac": new_mac()}
        elif "version" not in record:
            # Preserve legacy addresses even when an upgrade replaced the disk.
            record = {"version": 2, "vmID": str(uuid.uuid4()), "mac": record["mac"]}
        if action == "replace":
            record = dict(record, mac=proposed)
        if record != original:
            if original is not None:
                write_record(directory, key + ".previous.json", original)
            write_record(directory, name, record)
        return record["mac"]


if __name__ == "__main__":
    try:
        print(identity(*sys.argv[1:]))
    except (IdentityError, OSError) as error:
        print(f"Network identity: {error}", file=sys.stderr)
        sys.exit(1)
