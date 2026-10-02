#!/usr/bin/env python3
"""Consent-gated existing-guest repairs; no package or kernel upgrades."""

import base64
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import stat
import sys
import tempfile
import subprocess

sys.dont_write_bytecode = True

FILES = {
    "omarchy-native-clipboard-bridge": "usr/local/bin/omarchy-native-clipboard-bridge",
    "omarchy-screensaver": "usr/bin/omarchy-screensaver",
    "omarchy-native-screensaver-text": "usr/local/bin/omarchy-native-screensaver-text",
    "omarchy-native-cursor-restore": "usr/local/bin/omarchy-native-cursor-restore",
}
PREVIOUS = {
    "omarchy-native-clipboard-bridge": "03e3c6cf56f04c98434c32c7a4dd45a5ef1ab6dbcb4a76afbd186085c1d37bd5",
    "omarchy-screensaver": "34c480f6eaabef574b700aa7b023b2048eaf4400cfdf6e04227e642c02191ed2",
}
INVENTORY = {*FILES, "migrate.py", "try-omarchy-migrate-alacritty"}
STATE = "var/lib/try-omarchy/boot-fixes"
WRAPPER = "usr/local/bin/alacritty"
BACKUP = "usr/local/bin/.alacritty.try-omarchy-software-backup"
TARGETS = {*FILES.values(), WRAPPER, BACKUP}
COMPONENTS = ("clipboard", "screensaver", "alacritty", "power", "clock", "holds",
              "lock", "touch-id", "onepassword", "battery", "integrations", "desktop", "ghostty")
LINKS = {}
allowed_link = lambda relative, value: value == LINKS.get(relative)
MAX_FILE = 8388608
PACMAN_LOCK = b'try-omarchy-boot-fixes\n'


def components(payload):
    spec = importlib.util.spec_from_file_location("boot_components", payload / "components.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def digest(data):
    return hashlib.sha256(data).hexdigest()


def bundle_manifest(payload, create=False):
    extras = components(payload)
    inventory = INVENTORY | extras.EXTRA_FILES | {n for g in extras.GROUPS.values() for n in g}
    inventory |= {str(p.relative_to(payload)) for p in (payload / "integrations").rglob('*') if p.is_file()}
    files = {name: digest((payload / name).read_bytes()) for name in sorted(inventory)}
    value = {"schema": 1, "files": files,
             "identity": digest(json.dumps(files, sort_keys=True).encode())}
    if create:
        (payload / "fixes.json").write_text(json.dumps(value, sort_keys=True) + "\n")
    elif json.loads((payload / "fixes.json").read_text()) != value:
        raise RuntimeError("Boot fix payload verification failed")
    return value


def protected(path, root, uid):
    """Reject symlinked, shared, or untrusted destinations, including parents."""
    for entry in (path, *path.parents):
        if entry == root.parent:
            break
        if entry.is_symlink() and not (entry == path and str(path.relative_to(root)) in LINKS):
            raise RuntimeError("Unsafe boot fix destination")
        if entry.exists() or entry.is_symlink():
            info = entry.lstat()
            if info.st_uid != uid or (not stat.S_ISLNK(info.st_mode) and info.st_mode & 0o022):
                raise RuntimeError("Unprotected boot fix destination")
            if entry != path and not stat.S_ISDIR(info.st_mode):
                raise RuntimeError("Invalid boot fix directory")


def snapshot(path, root, uid):
    protected(path, root, uid)
    if path.is_symlink():
        info = path.lstat()
        return {"link": os.readlink(path), "uid": info.st_uid, "gid": info.st_gid}
    if not path.exists():
        return None
    info = path.stat()
    if (not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_size > MAX_FILE
            or info.st_mode & 0o7000):
        raise RuntimeError("Unsupported boot fix file")
    return {"data": base64.b64encode(path.read_bytes()).decode(),
            "mode": stat.S_IMODE(info.st_mode), "uid": info.st_uid, "gid": info.st_gid}


def replacement(data, uid, gid):
    return {"data": base64.b64encode(data).decode(), "mode": 0o755, "uid": uid, "gid": gid}


def sync_directory(path):
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def make_directory(path, mode):
    missing = []
    current = path
    while not current.exists():
        missing.append(current)
        current = current.parent
    for directory in reversed(missing):
        directory.mkdir(mode=mode if directory == path else 0o755)
        sync_directory(directory)
        sync_directory(directory.parent)


def write_file(path, value, root, uid):
    protected(path, root, uid)
    if value is None:
        path.unlink(missing_ok=True)
    elif "link" in value:
        make_directory(path.parent, 0o755)
        fd, temporary = tempfile.mkstemp(prefix=".try-omarchy-fix-", dir=path.parent)
        os.close(fd)
        os.unlink(temporary)
        try:
            os.symlink(value["link"], temporary)
            os.lchown(temporary, value["uid"], value["gid"])
            os.replace(temporary, path)
        finally:
            if os.path.lexists(temporary):
                os.unlink(temporary)
    else:
        make_directory(path.parent, 0o755)
        fd, temporary = tempfile.mkstemp(prefix=".try-omarchy-fix-", dir=path.parent)
        try:
            with os.fdopen(fd, "wb") as output:
                output.write(base64.b64decode(value["data"], validate=True))
                os.fchown(output.fileno(), value["uid"], value["gid"])
                os.fchmod(output.fileno(), value["mode"])
                output.flush()
                os.fsync(output.fileno())
            os.replace(temporary, path)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)
    if path.parent.exists():
        sync_directory(path.parent)


def journal_path(root, uid):
    path = root / STATE / "journal.json"
    protected(path, root, uid)
    make_directory(path.parent, 0o700)
    return path


def recover(root, uid, fallback=None):
    path = journal_path(root, uid)
    if not path.exists():
        if fallback is None:
            release_package_lock(root, uid)
            return
        changes = fallback
    else:
        if path.stat().st_size > 67108864:
            raise RuntimeError("Oversized boot fix journal")
        if not path.is_file() or path.stat().st_nlink != 1:
            raise RuntimeError("Unsafe boot fix journal")
        changes = json.loads(path.read_text())
    runtime = {}
    if isinstance(changes, dict):
        if set(changes) != {"changes", "runtime"}:
            raise RuntimeError("Invalid boot fix journal")
        runtime = changes["runtime"]
        changes = changes["changes"]
        allowed_services = {"systemd-timesyncd.service", "try-omarchy-clock-recovery.timer",
                            "omarchy-native-battery-bridge.service", "upower.service", "try-omarchy-integrations.service"}
        if (not isinstance(runtime, dict) or runtime and (set(runtime) != {"services", "battery-loaded"}
                or not isinstance(runtime["services"], dict) or set(runtime["services"]) - allowed_services
                or any(type(v) is not bool for v in runtime["services"].values())
                or runtime["battery-loaded"] is not None and type(runtime["battery-loaded"]) is not bool)):
            raise RuntimeError("Invalid boot fix runtime journal")
    if (not isinstance(changes, list) or len(changes) > len(TARGETS)
            or any(not isinstance(c, dict) or set(c) != {"path", "before", "after"}
                   or c["path"] not in TARGETS for c in changes)
            or len({c["path"] for c in changes}) != len(changes)):
        raise RuntimeError("Invalid boot fix journal")
    for change in changes:
        for value in (change["before"], change["after"]):
            if value is None:
                continue
            if isinstance(value, dict) and "link" in value:
                if (set(value) != {"link", "uid", "gid"} or value["uid"] != uid
                        or type(value["gid"]) is not int or value["gid"] < 0
                        or not allowed_link(change["path"], value["link"])):
                    raise RuntimeError("Invalid boot fix enablement backup")
                continue
            if (not isinstance(value, dict) or set(value) != {"data", "mode", "uid", "gid"}
                    or value["uid"] != uid or not isinstance(value["gid"], int) or value["gid"] < 0
                    or not isinstance(value["mode"], int) or not 0 <= value["mode"] <= 0o777
                    or value["mode"] & 0o022 or not isinstance(value["data"], str)
                    or len(base64.b64decode(value["data"], validate=True)) > MAX_FILE):
                raise RuntimeError("Invalid boot fix backup")
    # Preflight every path before restoring any. Never overwrite later edits.
    for change in changes:
        current = snapshot(root / change["path"], root, uid)
        if current not in (change["before"], change["after"]):
            raise RuntimeError("Boot fix recovery conflicts with a changed file")
    for change in reversed(changes):
        write_file(root / change["path"], change["before"], root, uid)
        if snapshot(root / change["path"], root, uid) != change["before"]:
            raise RuntimeError("Boot fix recovery verification failed")
    # DKMS inventories version directories, even when their source receipt is
    # gone. Remove empty directories from a newly introduced battery version
    # so rollback does not leave a phantom "broken" module registration.
    for change in changes:
        if change['before'] is not None:
            continue
        bases = ('var/lib/dkms/try-omarchy-battery', 'usr/src/try-omarchy-battery-1.2.0')
        base = next((root / b for b in bases if change['path'].startswith(b + '/')), None)
        if base is None:
            continue
        directory = (root / change['path']).parent
        while directory.is_relative_to(base):
            protected(directory, root, uid)
            try:
                directory.rmdir()
            except FileNotFoundError:
                pass
            except OSError:
                break  # Never remove a nonempty existing/custom directory.
            else:
                sync_directory(directory.parent)
            directory = directory.parent
    if runtime:
        # The caller sets this to the verified component implementation.
        restore_runtime(runtime, restoring=True)
    write_file(path, None, root, uid)
    release_package_lock(root, uid)


def release_package_lock(root, uid):
    path = root / 'var/lib/pacman/db.lck'
    if path.is_file() and not path.is_symlink():
        info = path.stat()
        if info.st_uid == uid and info.st_nlink == 1 and info.st_size == len(PACMAN_LOCK) and path.read_bytes() == PACMAN_LOCK:
            path.unlink()
            sync_directory(path.parent)


def restore_runtime(runtime, restoring=False):
    raise RuntimeError("Runtime recovery implementation unavailable")


def plan(payload, root, uid, cmdline):
    changes = []
    outcomes = {}
    for component, names in (("clipboard", ["omarchy-native-clipboard-bridge"]),
                              ("screensaver", ["omarchy-native-screensaver-text",
                                               "omarchy-native-cursor-restore", "omarchy-screensaver"])):
        caller = root / FILES[names[-1]]
        if not caller.exists() and not caller.is_symlink():
            outcomes[component] = "current"
            continue
        group = []
        try:
            for name in names:
                before = snapshot(root / FILES[name], root, uid)
                source = (payload / name).read_bytes()
                if before is not None:
                    content = base64.b64decode(before["data"])
                    if content != source and digest(content) != PREVIOUS.get(name):
                        raise RuntimeError("Customized native helper")
                after = replacement(source, uid, before["gid"] if before else os.getgid())
                if before != after:
                    group.append({"path": FILES[name], "before": before, "after": after})
            changes.extend(group)
            outcomes[component] = "pending" if group else "current"
        except (OSError, RuntimeError):
            outcomes[component] = "preserved"

    # The extensionless helper needs an explicit loader.
    from importlib.machinery import SourceFileLoader
    spec = importlib.util.spec_from_loader("alacritty_fix", SourceFileLoader("alacritty_fix", str(payload / "try-omarchy-migrate-alacritty")))
    helper = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(helper)
    try:
        before = snapshot(root / WRAPPER, root, uid)
        if before is None:
            outcomes["alacritty"] = "current"
        elif digest(base64.b64decode(before["data"])) != helper.WRAPPER_SHA256:
            outcomes["alacritty"] = "preserved"
        elif os.access(root / "usr/bin/alacritty", os.X_OK) and helper.MARKER not in cmdline.split():
            outcomes["alacritty"] = "unavailable"
        elif (root / BACKUP).exists() or (root / BACKUP).is_symlink():
            outcomes["alacritty"] = "preserved"
        else:
            protected(root / BACKUP, root, uid)
            changes.extend([{"path": BACKUP, "before": None, "after": before},
                            {"path": WRAPPER, "before": before, "after": None}])
            outcomes["alacritty"] = "pending"
    except (OSError, RuntimeError):
        outcomes["alacritty"] = "preserved"
    return changes, outcomes


def migrate(payload, root, approved, cmdline, emit=lambda _: None, uid=None, users=False):
    global TARGETS, LINKS, restore_runtime, allowed_link
    uid = os.getuid() if uid is None else uid
    identity = bundle_manifest(payload)["identity"]
    extras = components(payload)
    TARGETS = {*FILES.values(), WRAPPER, BACKUP} | extras.targets(payload)
    LINKS = extras.LINKS
    allowed_link = extras.allowed_link
    restore_runtime = extras.activate
    def report(state, outcomes):
        if users and state != 'running':
            import pwd
            states = {'complete': 0, 'skipped': 1, 'unconfirmed': 2, 'failed': 3, 'recovery-required': 4}
            outcomes_order = {'current': 0, 'applied': 1, 'preserved': 2, 'pending': 3}
            for user in pwd.getpwall():
                if not 1000 <= user.pw_uid < 65534 or not Path(user.pw_dir).is_dir():
                    continue
                try:
                    process = subprocess.run(['runuser', '-u', user.pw_name, '--', '/usr/bin/python3', '-I',
                        str(payload / 'user-fixes.py'), '--apply' if approved and state == 'complete' else '--check'],
                        check=True, capture_output=True, text=True, timeout=20)
                    result = json.loads(process.stdout.splitlines()[-1])
                    if (set(result) != {'state', 'outcome'} or result['state'] not in states
                            or result['outcome'] not in outcomes_order):
                        raise ValueError('Invalid user fix result')
                    if states[result['state']] > states[state]:
                        state = result['state']
                    if outcomes_order[result['outcome']] > outcomes_order[outcomes.get('desktop', 'current')]:
                        outcomes['desktop'] = result['outcome']
                except (OSError, ValueError, KeyError, subprocess.SubprocessError):
                    if states[state] < states['unconfirmed']:
                        state = 'unconfirmed'
                    outcomes['desktop'] = 'pending'
        value = {"schema": 1, "type": "boot-fixes", "identity": identity,
                 "state": state, "components": outcomes}
        emit(value)
        return value
    try:
        recover(root, uid)
    except (OSError, RuntimeError, ValueError, KeyError, subprocess.SubprocessError):
        return report("recovery-required", dict.fromkeys(COMPONENTS, "pending"))
    if approved:
        report("running", dict.fromkeys(COMPONENTS, "pending"))
    changes, outcomes = plan(payload, root, uid, cmdline)
    extra_changes, extra_outcomes = extras.plan(sys.modules[__name__] if __name__ in sys.modules else _self(), payload, root, uid)
    changes.extend(extra_changes)
    outcomes.update(extra_outcomes)
    outcomes['desktop'] = 'current'
    preparation_failed = False
    if approved and outcomes.get('battery') == 'pending':
        try:
            extras.build_battery(sys.modules[__name__] if __name__ in sys.modules else _self(), payload, root, uid, changes)
        except (OSError, RuntimeError, ValueError, subprocess.SubprocessError) as error:
            battery_targets = {p for p, _ in extras.GROUPS['battery'].values()} | {
                'etc/systemd/system/multi-user.target.wants/omarchy-native-battery-bridge.service',
                'var/lib/dkms/try-omarchy-battery/1.2.0/source'}
            changes = [c for c in changes if c['path'] not in battery_targets]
            if isinstance(error, extras.BatteryUnavailable):
                outcomes['battery'] = 'unavailable'
            elif isinstance(error, extras.BatteryPreserved):
                outcomes['battery'] = 'preserved'
            else:
                preparation_failed, outcomes['battery'] = True, 'failed'
            print('Try Omarchy battery preparation: ' + str(error), file=sys.stderr, flush=True)
    if not changes and not any(v == 'pending' for v in outcomes.values()):
        return report("failed" if preparation_failed else "complete", outcomes)
    if not approved:
        return report("skipped", outcomes)
    report("running", outcomes)
    runtime = extras.runtime_before(outcomes, root)
    state = apply_transaction(changes, root, uid, runtime, extras.activate)
    if state == 'complete':
        outcomes = {k: 'applied' if v == 'pending' else v for k, v in outcomes.items()}
        if preparation_failed:
            state = 'failed'
    return report(state, outcomes)


def apply_transaction(changes, root, uid, runtime=None, activate=lambda _: None):
    runtime = runtime or {}
    transaction = {"changes": changes, "runtime": runtime}
    path = journal_path(root, uid)
    locked = False
    try:
        if any(c['path'] in ('etc/pacman.conf', 'usr/share/try-omarchy/pacman.conf')
               or c['path'].startswith(('usr/lib/modules/', 'var/lib/dkms/')) for c in changes):
            lock = root / 'var/lib/pacman/db.lck'
            protected(lock, root, uid)
            make_directory(lock.parent, 0o755)
            fd = os.open(lock, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(fd, 'wb') as output:
                output.write(PACMAN_LOCK)
                output.flush()
                os.fsync(output.fileno())
            locked = True
        # Persist all original bytes/metadata before touching any managed file.
        data = json.dumps(transaction, sort_keys=True).encode()
        if len(data) > 67108864:
            raise RuntimeError('Boot fix journal exceeds recovery limit')
        write_file(path, {"data": base64.b64encode(data).decode(), "mode": 0o600,
                          "uid": uid, "gid": os.getgid()}, root, uid)
        for change in changes:
            target = root / change["path"]
            if snapshot(target, root, uid) != change["before"]:
                raise RuntimeError("Boot fix file changed after review")
            write_file(target, change["after"], root, uid)
        for change in changes:
            if snapshot(root / change["path"], root, uid) != change["after"]:
                raise RuntimeError("Boot fix verification failed")
        activate(runtime)
        # Keep a root-private copy for inspection/manual recovery after success.
        fd, backup = tempfile.mkstemp(prefix="backup-", suffix=".json", dir=path.parent)
        with os.fdopen(fd, "wb") as output:
            output.write(data)
            output.flush()
            os.fsync(output.fileno())
        # Unlinking the journal is the durable commit. Before it, recovery
        # restores the entire file group, including when consent was skipped.
        write_file(path, None, root, uid)
    except (OSError, RuntimeError, ValueError, subprocess.SubprocessError):
        try:
            # If the commit unlink succeeded but its directory flush failed,
            # the originals are still available in memory and retained backup.
            recover(root, uid, fallback=transaction)
        except (OSError, RuntimeError, ValueError, KeyError, subprocess.SubprocessError):
            return "recovery-required"
        return "failed"
    finally:
        if locked:
            release_package_lock(root, uid)
    return "complete"


def _self():
    # importlib callers used by the installer and fixtures need not register a
    # module in sys.modules. Expose only the file-transaction helpers.
    from types import SimpleNamespace
    return SimpleNamespace(**{name: globals()[name] for name in
        ('snapshot', 'replacement', 'digest', 'journal_path')})


def boot(payload):
    identity = None
    def emit(value):
        print("Try Omarchy boot fixes: " + json.dumps(value), flush=True)
        try:
            fd = os.open("/dev/virtio-ports/dev.tryomarchy.settings", os.O_WRONLY | os.O_NONBLOCK)
            try:
                os.write(fd, json.dumps(value, separators=(",", ":")).encode() + b"\n")
            finally:
                os.close(fd)
        except OSError:
            pass  # A missing host listener never grants consent or changes success.
    try:
        cmdline = Path("/proc/cmdline").read_text()
        identity = bundle_manifest(payload)["identity"]
        approved = f"tryomarchy.fixes={identity}" in cmdline.split()
        return migrate(payload, Path("/"), approved, cmdline, emit, uid=0, users=True)
    except (OSError, RuntimeError, ValueError, KeyError, IndexError, subprocess.SubprocessError):
        print("Try Omarchy boot fix checking or recovery did not finish; completion was not recorded", flush=True)
        if identity is not None:
            emit({"schema": 1, "type": "boot-fixes", "identity": identity,
                  "state": "unconfirmed", "components": dict.fromkeys(COMPONENTS, "pending")})


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "--manifest":
        bundle_manifest(Path(sys.argv[2]), create=True)
    else:
        raise SystemExit("This runner is invoked by the app's boot settings payload")
