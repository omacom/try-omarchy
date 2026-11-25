#!/usr/bin/env python3
"""Update a built app with Sparkle for real, from a local feed.

Copies a production app into two versions signed with a throwaway update key,
serves the newer one as a DMG, chooses the update in the older one and checks
that it was replaced and reopened. Then checks that updates that must not
install leave the app alone: another key's signature, a changed DMG, an
interrupted download, a release for a newer macOS, an app opened from a
read-only disk image, and one with another instance open. The copies have their own identity, preferences and
storage folder. Windows open on this Mac while it runs.

    tests/app-updates/install.py APP
    tests/app-updates/install.py APP --vm STATE
    tests/app-updates/install.py APP --sign-identity "Developer ID Application: …"

With an identity, APP must be signed by its team, and replacing a lost update
key is checked too. STATE is the storage folder of a disposable VM, which `make e2e
E2E_ARGS=--prepare-only` makes. It boots in the app, and the update must wait
for its clean shutdown and then boot the same disk again.
"""

from __future__ import annotations

import argparse
import functools
import http.server
import json
import os
from pathlib import Path
import plistlib
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time

REPOSITORY = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPOSITORY / "scripts"))
import appcast  # noqa: E402

BUNDLE = "dev.tryomarchy.native.update-test"
EXECUTABLE = "Contents/MacOS/omarchy-vm-helper"


def run(*arguments: object) -> str:
    return subprocess.run([str(argument) for argument in arguments], check=True, capture_output=True, text=True).stdout


def fail(message: str) -> None:
    raise SystemExit(f"app-update-test: {message}")


class Feed(http.server.SimpleHTTPRequestHandler):
    served: list[str] = []
    interrupt = False

    def log_message(self, *arguments: object) -> None:
        pass

    def do_GET(self) -> None:
        self.served.append(self.path)
        if self.interrupt and self.path.endswith(".dmg"):
            data = Path(self.translate_path(self.path)).read_bytes()
            self.send_response(200)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data[:len(data) // 2])
            return
        super().do_GET()


class Rehearsal:
    def __init__(self, app: Path, scratch: Path, state: Path, identity: str) -> None:
        self.identity = identity
        self.app = app
        self.entitlements = scratch / "entitlements.plist"
        self.write_entitlements()
        self.scratch = scratch
        self.site = scratch / "site"
        self.site.mkdir()
        self.installed = scratch / "Applications/Try Omarchy.app"
        self.state = state
        self.key_tool = scratch / "update-key"
        run("xcrun", "swiftc", REPOSITORY / "tests/app-updates/update-key.swift", "-o", self.key_tool)
        self.chooser = scratch / "choose-update.dylib"
        run("xcrun", "clang", "-dynamiclib", "-fobjc-arc", "-mmacosx-version-min=15.0", "-framework", "AppKit",
            REPOSITORY / "tests/app-updates/choose-update.m", "-o", self.chooser)
        self.seed, self.public_key = self.new_key()
        server = http.server.ThreadingHTTPServer(
            ("127.0.0.1", 0), functools.partial(Feed, directory=str(self.site)))
        threading.Thread(target=server.serve_forever, daemon=True).start()
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            self.ssh_port = listener.getsockname()[1]
        self.environment = {"OMARCHY_QEMU_GPU_STATE_ROOT": str(self.state)}
        self.url = f"http://127.0.0.1:{server.server_port}"
        self.old = self.version("9.0.0", "1", self.public_key)
        self.new = self.version("9.0.1", "2", self.public_key)
        self.dmg = self.image(self.new, self.site / "TryOmarchy.dmg")

    def new_key(self) -> list[str]:
        return run(self.key_tool, "generate").split()

    def write_entitlements(self) -> None:
        entitlements = plistlib.loads((REPOSITORY / "macos/omarchy-vm-helper.entitlements").read_bytes())
        if self.identity != "-":
            # The hardened runtime would refuse the test's library.
            entitlements |= {"com.apple.security.cs.allow-dyld-environment-variables": True,
                             "com.apple.security.cs.disable-library-validation": True}
        self.entitlements.write_bytes(plistlib.dumps(entitlements))

    def codesign(self, path: Path, *options: object) -> None:
        hardening = [] if self.identity == "-" else ["--options", "runtime", "--timestamp=none"]
        run("codesign", "--force", "--sign", self.identity, *hardening, *options, path)

    def version(self, version: str, build: str, public_key: str, name: str | None = None) -> Path:
        copy = self.scratch / (name or version) / "Try Omarchy.app"
        copy.parent.mkdir()
        run("cp", "-cR", self.app, copy)
        plist = copy / "Contents/Info.plist"
        info = plistlib.loads(plist.read_bytes())
        info |= {
            "CFBundleIdentifier": BUNDLE, "CFBundleShortVersionString": version, "CFBundleVersion": build,
            "TryOmarchyBuildDescribe": f"v{version}", "SUFeedURL": f"{self.url}/appcast.xml",
            "SUPublicEDKey": public_key, "NSAppTransportSecurity": {"NSAllowsLocalNetworking": True},
            # Sparkle reopens the app through Launch Services.
            "LSEnvironment": self.environment,
        }
        plist.write_bytes(plistlib.dumps(info))
        self.codesign(copy, "--identifier", BUNDLE, "--entitlements", self.entitlements)
        return copy

    def image(self, app: Path, dmg: Path) -> Path:
        source = self.scratch / f"{dmg.stem}-source"
        source.mkdir()
        run("cp", "-cR", app, source / "Try Omarchy.app")
        run("hdiutil", "create", "-quiet", "-volname", "Try Omarchy", "-srcfolder", source, "-format", "UDZO", dmg)
        self.codesign(dmg)
        return dmg

    def offer(self, seed: str, minimum: str = "15.0") -> None:
        key = self.scratch / "seed"
        key.write_text(seed)
        os.environ["RELEASE_UPDATE_KEY_FILE"] = str(key)
        fields = appcast.fields(appcast.app_info(self.new), "v9.0.1", self.dmg)
        fields |= {"url": f"{self.url}/TryOmarchy.dmg", "minimumSystemVersion": minimum}
        appcast.write(self.site / "appcast.xml", fields, appcast.sign(REPOSITORY, self.dmg))

    def installed_version(self) -> str:
        return appcast.app_info(self.installed)["CFBundleShortVersionString"]

    def processes(self) -> list[int]:
        result = subprocess.run(["pgrep", "-f", f"^{self.installed}/{EXECUTABLE}"], capture_output=True, text=True)
        return [int(pid) for pid in result.stdout.split()]

    def stop(self) -> None:
        # Sparkle's installer first, or it would replace and reopen the app.
        subprocess.run(["pkill", "-KILL", "-f", str(Path.home() / f"Library/Caches/{BUNDLE}")], capture_output=True)
        for pid in self.processes():
            os.kill(pid, signal.SIGKILL)
        wait(lambda: not self.processes(), 10)

    def install_old(self) -> None:
        self.stop()
        shutil.rmtree(self.installed.parent, ignore_errors=True)
        self.installed.parent.mkdir()
        run("cp", "-cR", self.old, self.installed)

    def open_old(self, choose: bool = True) -> tuple[subprocess.Popen, Path]:
        self.stop()
        forget()
        run("defaults", "write", BUNDLE, "LauncherPermissionPromptShown", "-bool", "true")
        run("defaults", "write", BUNDLE, "appReleaseAutomaticChecks", "-bool", "false")
        Feed.served.clear()
        app, log = self.launch()
        if choose:
            time.sleep(3)
            self.trigger.touch()
        return app, log

    def launch(self) -> tuple[subprocess.Popen, Path]:
        launch = time.monotonic_ns()
        log = self.scratch / f"app-{launch}.log"
        # Only the instance launched last chooses the update.
        self.trigger = self.scratch / f"update-{launch}"
        app = subprocess.Popen(
            [str(self.installed / EXECUTABLE)], stderr=log.open("w"), stdout=subprocess.DEVNULL,
            env=os.environ | {"DYLD_INSERT_LIBRARIES": str(self.chooser), "UPDATE_TEST_TRIGGER": str(self.trigger)}
            | self.environment)
        return app, log

    def installs(self, name: str) -> None:
        self.install_old()
        app, log = self.open_old()
        self.updated(app, log)
        print(f"app-update-test: installed 9.0.1 over 9.0.0 and reopened it, {name}", flush=True)

    def replaces_a_lost_key(self) -> None:
        new, dmg = self.new, self.dmg
        seed, public_key = self.new_key()
        self.new = self.version("9.0.1", "2", public_key, name="rotated")
        source = self.image(self.new, self.scratch / "Rotated.dmg")
        kept = self.scratch / "kept.dmg"
        dmg.rename(kept)
        source.rename(dmg)
        self.offer(seed)
        self.installs("with a new update key")
        dmg.unlink()
        kept.rename(dmg)
        self.new = new

    def updated(self, app: subprocess.Popen, log: Path) -> None:
        def replaced() -> bool:
            app.poll()
            return self.installed.exists() and self.installed_version() == "9.0.1"
        if not wait(replaced, 120):
            fail(f"the update was not installed\n{log.read_text()}")
        if not wait(lambda: [pid for pid in self.processes() if pid != app.pid], 60):
            fail(f"the updated app did not reopen\n{log.read_text()}")
        run("codesign", "--verify", "--deep", "--strict", self.installed)

    def virtual_machines(self) -> list[str]:
        """The command lines of QEMU processes that use this VM's disk."""
        processes = run("ps", "-axo", "command").splitlines()
        return [line for line in processes if "/runtime/bin/Try Omarchy -name " in line and str(self.state) in line]

    def write_settings(self, name: str, settings: dict) -> None:
        path = self.state / name
        path.write_text(json.dumps({"schemaVersion": 1, **settings}))
        path.chmod(0o600)

    def guest(self, command: str) -> str:
        ssh = ["ssh", "-i", str(self.state.parent / "ssh-key"), "-p", str(self.ssh_port), "-o", "IdentitiesOnly=yes",
               "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null", "-o", "LogLevel=ERROR",
               "-o", "ConnectTimeout=5", "-o", "BatchMode=yes", "root@127.0.0.1"]
        if not wait(lambda: subprocess.run([*ssh, "true"], capture_output=True).returncode == 0, 420):
            fail("the VM does not answer over SSH")
        return run(*ssh, command)

    def waits_for_the_vm(self) -> None:
        disk = self.state / "shell/disk.img"
        status = self.state / "shell/guest-status.json"
        identity = disk.stat().st_ino
        self.write_settings("launcher-settings.json", {"startAutomatically": True})
        self.write_settings("settings.json", {"settings": {"portForwardingPreferences": {
            "schemaVersion": 1, "mappings": [{"hostPort": self.ssh_port, "guestPort": 22, "protocol": "tcp"}]}}})
        self.offer(self.seed)
        self.install_old()

        def boots(since: float, executable: Path) -> bool:
            return wait(lambda: status.exists() and status.stat().st_mtime > since
                        and any(str(executable) in line for line in self.virtual_machines()), 420)
        started = time.time()
        app, log = self.open_old(choose=False)
        if not boots(started, self.installed):
            fail(f"Omarchy did not boot\n{log.read_text()}")
        # As for anyone, a power request before the guest is up is ignored.
        self.guest("systemctl is-system-running --wait >/dev/null; echo kept > /root/update-marker")
        boot = self.guest("cat /proc/sys/kernel/random/boot_id")
        print("app-update-test: Omarchy runs in 9.0.0", flush=True)
        self.trigger.touch()
        if not wait(lambda: "[Shut Down and Update]" in log.read_text(), 30):
            fail(f"the app did not ask to shut Omarchy down\n{log.read_text()}")
        # The app may only be replaced once QEMU is gone.
        while self.virtual_machines():
            if self.installed_version() != "9.0.0" or Feed.served.count("/TryOmarchy.dmg"):
                fail("the update started while Omarchy was running")
            if time.time() - started > 900:
                fail(f"Omarchy did not shut down\n{log.read_text()}")
            time.sleep(0.2)
        stopped = time.time()
        self.updated(app, log)
        if not boots(stopped, self.installed):
            fail("the updated app did not boot Omarchy again")
        if disk.stat().st_ino != identity:
            fail("the updated app uses another disk")
        if self.guest("cat /proc/sys/kernel/random/boot_id") == boot:
            fail("Omarchy was not restarted")
        if self.guest("cat /root/update-marker") != "kept\n":
            fail("a file in the VM did not survive the update")
        journal = self.guest(f"journalctl -b {boot.strip().replace('-', '')} -o cat")
        # The journal itself stops once the file systems are being unmounted.
        if not ("Power key pressed" in journal and "Unmounting /home" in journal):
            fail(f"Omarchy did not shut down by itself\n{journal[-12000:]}")
        print("app-update-test: waited for Omarchy to shut down, updated, and booted the same VM", flush=True)
        for pid in self.processes():
            os.kill(pid, signal.SIGTERM)
        wait(lambda: not self.virtual_machines(), 60)

    def refuses_from_a_disk_image(self) -> None:
        self.stop()
        image = self.image(self.old, self.scratch / "Old.dmg")
        volume = self.scratch / "volume"
        run("hdiutil", "attach", "-quiet", "-readonly", "-nobrowse", "-mountpoint", volume, image)
        installed, self.installed = self.installed, volume / "Try Omarchy.app"
        try:
            self.refuses("an app opened from a disk image", "read-only", download=False, reinstall=False)
        finally:
            self.stop()
            run("hdiutil", "detach", "-force", volume)
            self.installed = installed

    def refuses(self, name: str, expected: str, download: bool = True, reinstall: bool = True) -> tuple[subprocess.Popen, Path]:
        if reinstall:
            self.install_old()
        app, log = self.open_old()
        if not wait(lambda: expected in log.read_text(), 90):
            fail(f"{name}: the app did not say {expected!r}\n{log.read_text()}")
        time.sleep(3)
        if app.poll() is not None or self.installed_version() != "9.0.0":
            fail(f"{name}: the app was replaced or stopped\n{log.read_text()}")
        if ("/TryOmarchy.dmg" in Feed.served) != download:
            fail(f"{name}: served {Feed.served}")
        print(f"app-update-test: refused {name}", flush=True)
        return app, log

    def interrupted_download(self) -> None:
        Feed.interrupt = True
        app, log = self.refuses("an interrupted download", "Update Error")
        Feed.interrupt = False
        self.trigger.touch()
        self.updated(app, log)
        print("app-update-test: installed the update when chosen again", flush=True)

    def another_instance(self) -> None:
        self.install_old()
        other, _ = self.open_old(choose=False)
        time.sleep(3)
        app, log = self.launch()
        time.sleep(3)
        self.trigger.touch()
        if not wait(lambda: "quit other copies" in log.read_text(), 30):
            fail(f"another instance: the app did not ask to quit it\n{log.read_text()}")
        if other.poll() is not None or app.poll() is not None or Feed.served:
            fail("another instance: it was interrupted")
        print("app-update-test: refused while another instance runs", flush=True)


def wait(condition, seconds: float) -> bool:
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if condition():
            return True
        time.sleep(0.5)
    return False


def forget() -> None:
    subprocess.run(["defaults", "delete", BUNDLE], capture_output=True)
    for path in (f"Caches/{BUNDLE}", f"HTTPStorages/{BUNDLE}", f"Saved Application State/{BUNDLE}.savedState"):
        shutil.rmtree(Path.home() / "Library" / path, ignore_errors=True)
    (Path.home() / f"Library/Preferences/{BUNDLE}.plist").unlink(missing_ok=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("app", type=Path)
    parser.add_argument("--vm", type=Path, metavar="STATE")
    parser.add_argument("--sign-identity", default="-")
    arguments = parser.parse_args()
    app, vm = arguments.app.resolve(), arguments.vm and arguments.vm.resolve()
    if vm and not (vm / "shell/disk.img").is_file():
        fail(f"no VM in {vm}")
    adhoc = "Signature=adhoc" in subprocess.run(["codesign", "-dv", str(app)], capture_output=True, text=True).stderr
    if adhoc != (arguments.sign_identity == "-"):
        fail("sign the app and its copies alike: an ad hoc app, or --sign-identity with the app's identity")
    scratch = Path(tempfile.mkdtemp(prefix="omarchy-app-update.", dir="/private/tmp"))
    rehearsal = None
    try:
        if vm:
            (scratch / "vm").mkdir()
            rehearsal = Rehearsal(app, scratch / "vm", vm, arguments.sign_identity)
            rehearsal.waits_for_the_vm()
            rehearsal.stop()
        (scratch / "app").mkdir()
        rehearsal = Rehearsal(app, scratch / "app", scratch / "app/state", arguments.sign_identity)
        rehearsal.offer(rehearsal.seed)
        rehearsal.installs("with the same update key")
        if arguments.sign_identity != "-":
            rehearsal.replaces_a_lost_key()
        rehearsal.offer(rehearsal.seed)
        rehearsal.interrupted_download()
        rehearsal.another_instance()
        rehearsal.refuses_from_a_disk_image()
        rehearsal.offer(rehearsal.new_key()[0])
        rehearsal.refuses("an update signed with a key no app carries", "improperly signed")
        rehearsal.offer(rehearsal.seed)
        data = bytearray(rehearsal.dmg.read_bytes())
        data[len(data) // 2] ^= 1
        rehearsal.dmg.write_bytes(data)
        rehearsal.refuses("a DMG changed after signing", "improperly signed")
        rehearsal.offer(rehearsal.seed, minimum="99.0")
        rehearsal.refuses("a release for a newer macOS", "99.0", download=False)
    finally:
        if rehearsal:
            rehearsal.stop()
        forget()
        shutil.rmtree(scratch, ignore_errors=True)
    print("app-update-test: PASS")


if __name__ == "__main__":
    main()
