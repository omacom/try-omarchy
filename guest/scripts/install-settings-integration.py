#!/usr/bin/env python3
"""Install only the app's settings entry points, from its read-only boot share."""

import json
import os
from pathlib import Path
import pwd
import re
import subprocess
import sys
import tempfile


FILES = {
    "omarchy-native-settings": ("usr/local/bin/omarchy-native-settings", 0o755),
    "92-omarchy-native-settings.rules": ("etc/udev/rules.d/92-omarchy-native-settings.rules", 0o644),
    "try-omarchy-settings.desktop": ("usr/share/applications/try-omarchy-settings.desktop", 0o644),
    "try-omarchy-timezone": ("usr/local/bin/try-omarchy-timezone", 0o755),
    "tzupdate": ("usr/local/bin/tzupdate", 0o755),
    "try-omarchy-timezone.service": ("usr/lib/systemd/system/try-omarchy-timezone.service", 0o644),
    "96-try-omarchy-timezone.rules": ("etc/udev/rules.d/96-try-omarchy-timezone.rules", 0o644),
    "try-omarchy-follow-timezone.desktop": ("usr/share/applications/try-omarchy-follow-timezone.desktop", 0o644),
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


def install_system(payload, root):
    for name, (relative, mode) in FILES.items():
        install_file(payload / name, root / relative, mode)
    install_menu(payload / "omarchy-menu.jsonc", root / "etc/skel")


def main():
    payload = Path(__file__).resolve().parent
    if sys.argv[1:] == ["--user-menu"]:
        install_user(payload, Path(pwd.getpwuid(os.getuid()).pw_dir))
        return
    if sys.argv[1:] or os.geteuid() != 0:
        raise SystemExit("Run the bundled installer as root, without arguments")
    install_system(payload, Path("/"))
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
