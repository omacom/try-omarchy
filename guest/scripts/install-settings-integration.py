#!/usr/bin/env python3
"""Install settings and compatible stock-script fixes from the app's boot share."""

import hashlib
import json
import os
from pathlib import Path
import pwd
import re
import subprocess
import sys
import tempfile


FILES = {
    "power-profile-hooks.json": ("usr/local/share/try-omarchy/power-profile-hooks.json", 0o644),
    "install-power-profile.py": ("usr/local/lib/try-omarchy/install-power-profile.py", 0o644),
    "omarchy-native-settings": ("usr/local/bin/omarchy-native-settings", 0o755),
    "92-omarchy-native-settings.rules": ("etc/udev/rules.d/92-omarchy-native-settings.rules", 0o644),
    "try-omarchy-settings.desktop": ("usr/share/applications/try-omarchy-settings.desktop", 0o644),
    "try-omarchy-timezone": ("usr/local/bin/try-omarchy-timezone", 0o755),
    "timezone-setup.sh": ("usr/local/share/try-omarchy/timezone-setup.sh", 0o644),
    "timezone-menu-hooks.json": ("usr/local/share/try-omarchy/timezone-menu-hooks.json", 0o644),
    "install-timezone-menus.py": ("usr/local/lib/try-omarchy/install-timezone-menus.py", 0o644),
    "tzupdate": ("usr/local/bin/tzupdate", 0o755),
    "try-omarchy-timezone.service": ("usr/lib/systemd/system/try-omarchy-timezone.service", 0o644),
    "96-try-omarchy-timezone.rules": ("etc/udev/rules.d/96-try-omarchy-timezone.rules", 0o644),
    "try-omarchy-follow-timezone.desktop": ("usr/share/applications/try-omarchy-follow-timezone.desktop", 0o644),
}
NATIVE_FIX_FILES = {
    "omarchy-native-clipboard-bridge": "usr/local/bin/omarchy-native-clipboard-bridge",
    "omarchy-screensaver": "usr/bin/omarchy-screensaver",
    "omarchy-native-screensaver-text": "usr/local/bin/omarchy-native-screensaver-text",
    "omarchy-native-cursor-restore": "usr/local/bin/omarchy-native-cursor-restore",
}
# Exact previously shipped scripts, before the large-selection and small-window
# fixes. Unknown versions and user edits must not be replaced at boot.
PREVIOUS_NATIVE_HASHES = {
    "omarchy-native-clipboard-bridge": "03e3c6cf56f04c98434c32c7a4dd45a5ef1ab6dbcb4a76afbd186085c1d37bd5",
    "omarchy-screensaver": "34c480f6eaabef574b700aa7b023b2048eaf4400cfdf6e04227e642c02191ed2",
}
MENU = ".config/omarchy/extensions/omarchy-menu.jsonc"
DESKTOP = ".local/share/applications/try-omarchy-settings.desktop"
LEGACY_ENTRY = {
    "icon": "",
    "label": "Try Omarchy Settings",
    "description": "Open the Mac app settings",
    "action": "omarchy-native-settings",
    "when": "test -w /dev/virtio-ports/dev.tryomarchy.settings",
}


def menu_entries(text):
    # Match the JSONC subset accepted by upstream MenuModel.js.
    stripped = re.sub(r"^\s*//[^\n]*(\n|$)", "", text, flags=re.MULTILINE)
    stripped = re.sub(r",(\s*[}\]])", r"\1", stripped)
    try:
        entries = json.loads(stripped)
    except ValueError:
        return {}
    if not isinstance(entries, dict):
        return {}
    entries = entries.get("items", entries)
    return entries if isinstance(entries, dict) else {}


def install_file(source, destination, mode):
    install_bytes(source.read_bytes(), destination, mode)


def install_bytes(data, destination, mode):
    destination.parent.mkdir(parents=True, exist_ok=True)
    if (destination.is_file() and not destination.is_symlink()
            and destination.read_bytes() == data
            and destination.stat().st_mode & 0o777 == mode):
        return
    descriptor, temporary = tempfile.mkstemp(prefix=".try-omarchy-", dir=destination.parent)
    try:
        with os.fdopen(descriptor, "wb") as output:
            output.write(data)
            os.fchmod(output.fileno(), mode)
        os.replace(temporary, destination)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def install_menu(source, home):
    """Update only our unchanged legacy entry; preserve all custom menu content."""
    destination = home / MENU
    destination.parent.mkdir(parents=True, exist_ok=True)
    try:
        descriptor = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)
    except FileExistsError:
        if destination.is_symlink() or not destination.is_file():
            return
        text = destination.read_text()
        if menu_entries(text).get("setup.try-omarchy") == LEGACY_ENTRY:
            pattern = r'"setup\.try-omarchy"\s*:\s*\{[^{}]*\}'
            replacement = re.search(pattern, source.read_text())
            original = re.search(pattern, text)
            if replacement and original:
                updated = text[:original.start()] + replacement.group() + text[original.end():]
                install_bytes(updated.encode(), destination, destination.stat().st_mode & 0o777)
        return
    with os.fdopen(descriptor, "wb") as output:
        output.write(source.read_bytes())


def install_user(payload, home):
    install_menu(payload / "omarchy-menu.jsonc", home)
    menu = home / MENU
    entries = menu_entries(menu.read_text()) if menu.is_file() else {}
    has_settings = any(isinstance(entry, dict) and entry.get("action") == "omarchy-native-settings"
                       for entry in entries.values())
    # Setup already participates in global search. Show the Apps fallback only
    # for users whose custom menu omits it, using a per-user desktop override.
    desktop = (payload / "try-omarchy-settings.desktop").read_bytes()
    visible_desktop = desktop.replace(b"NoDisplay=true", b"NoDisplay=false")
    destination = home / DESKTOP
    if destination.is_symlink():
        return
    if destination.exists() and destination.read_bytes() not in (desktop, visible_desktop):
        return
    install_bytes(desktop if has_settings else visible_desktop, destination, 0o644)


def matches_managed_file(path, source, previous=None, allow_absent=False):
    if path.is_symlink():
        return False
    if not path.exists():
        return allow_absent
    if not path.is_file():
        return False
    contents = path.read_bytes()
    return contents == source or hashlib.sha256(contents).hexdigest() == previous


def install_native_fixes(payload, root):
    for name, previous in PREVIOUS_NATIVE_HASHES.items():
        destination = root / NATIVE_FIX_FILES[name]
        if not destination.exists() and not destination.is_symlink():
            continue
        source = (payload / name).read_bytes()
        if not matches_managed_file(destination, source, previous):
            print(f"Keeping customized or unsupported {name}", flush=True)
            continue
        helpers = (
            ("omarchy-native-screensaver-text", "omarchy-native-cursor-restore")
            if name == "omarchy-screensaver" else ()
        )
        # A customized helper must not be combined with a new caller. Check all
        # dependencies before writing any part of the screensaver update.
        if any(not matches_managed_file(root / NATIVE_FIX_FILES[helper],
                                        (payload / helper).read_bytes(), allow_absent=True)
               for helper in helpers):
            print("Keeping screensaver with customized native helpers", flush=True)
            continue
        for helper in helpers:
            install_file(payload / helper, root / NATIVE_FIX_FILES[helper], 0o755)
        install_bytes(source, destination, 0o755)


def install_system(payload, root):
    for name, (relative, mode) in FILES.items():
        install_file(payload / name, root / relative, mode)
    install_menu(payload / "omarchy-menu.jsonc", root / "etc/skel")
    install_native_fixes(payload, root)


def main():
    payload = Path(__file__).resolve().parent
    if sys.argv[1:] == ["--user-menu"]:
        install_user(payload, Path(pwd.getpwuid(os.getuid()).pw_dir))
        return
    if sys.argv[1:] or os.geteuid() != 0:
        raise SystemExit("Run the bundled installer as root, without arguments")
    install_system(payload, Path("/"))
    subprocess.run(["python3", "/usr/local/lib/try-omarchy/install-power-profile.py"], check=True)
    subprocess.run(["python3", "/usr/local/lib/try-omarchy/install-timezone-menus.py"], check=True)
    # Run before owner provisioning, including in older unprovisioned factories.
    # The live service starts after provisioning so a different setup selection
    # is recognized as a manual override rather than overwritten.
    subprocess.run(["/usr/local/bin/try-omarchy-timezone", "--initialize"], check=True)
    subprocess.run(["systemctl", "daemon-reload"], check=True)
    subprocess.run(["systemctl", "enable", "try-omarchy-timezone.service"], check=True)
    subprocess.run(["systemctl", "--no-block", "start", "try-omarchy-timezone.service"], check=True)
    subprocess.run(["udevadm", "control", "--reload-rules"], check=True)
    subprocess.run(["udevadm", "trigger", "--subsystem-match=virtio-ports"], check=True)
    # Run home-directory operations as their owner, never with root privileges.
    # Custom menu content is preserved and gets a searchable app fallback.
    for user in pwd.getpwall():
        if 1000 <= user.pw_uid < 65534 and Path(user.pw_dir).is_dir():
            subprocess.run([
                "runuser", "-u", user.pw_name, "--", "python3", str(payload / "install.py"), "--user-menu"
            ], check=False)
    print("Try Omarchy settings integration installed", flush=True)


if __name__ == "__main__":
    main()
