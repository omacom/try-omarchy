#!/usr/bin/env python3
"""Install only the app's settings entry points, from its read-only boot share."""

import os
from pathlib import Path
import pwd
import subprocess
import sys
import tempfile


FILES = {
    "omarchy-native-settings": ("usr/local/bin/omarchy-native-settings", 0o755),
    "92-omarchy-native-settings.rules": ("etc/udev/rules.d/92-omarchy-native-settings.rules", 0o644),
    "try-omarchy-settings.desktop": ("usr/share/applications/try-omarchy-settings.desktop", 0o644),
}
MENU = ".config/omarchy/extensions/omarchy-menu.jsonc"


def install_file(source, destination, mode):
    destination.parent.mkdir(parents=True, exist_ok=True)
    if (destination.is_file() and not destination.is_symlink()
            and destination.read_bytes() == source.read_bytes()
            and destination.stat().st_mode & 0o777 == mode):
        return
    descriptor, temporary = tempfile.mkstemp(prefix=".try-omarchy-", dir=destination.parent)
    try:
        with os.fdopen(descriptor, "wb") as output:
            output.write(source.read_bytes())
            os.fchmod(output.fileno(), mode)
        os.replace(temporary, destination)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def install_menu(source, home):
    """Never replace a user's extension file. The desktop entry always exists."""
    destination = home / MENU
    destination.parent.mkdir(parents=True, exist_ok=True)
    try:
        descriptor = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)
    except FileExistsError:
        return
    with os.fdopen(descriptor, "wb") as output:
        output.write(source.read_bytes())


def install_system(payload, root):
    for name, (relative, mode) in FILES.items():
        install_file(payload / name, root / relative, mode)
    install_menu(payload / "omarchy-menu.jsonc", root / "etc/skel")


def main():
    payload = Path(__file__).resolve().parent
    if sys.argv[1:] == ["--user-menu"]:
        install_menu(payload / "omarchy-menu.jsonc", Path(pwd.getpwuid(os.getuid()).pw_dir))
        return
    if sys.argv[1:] or os.geteuid() != 0:
        raise SystemExit("Run the bundled installer as root, without arguments")
    install_system(payload, Path("/"))
    subprocess.run(["udevadm", "control", "--reload-rules"], check=True)
    subprocess.run(["udevadm", "trigger", "--subsystem-match=virtio-ports"], check=True)
    # Run home-directory operations as their owner, never with root privileges.
    # Existing custom menus remain untouched and can use the searchable app entry.
    for user in pwd.getpwall():
        if 1000 <= user.pw_uid < 65534 and Path(user.pw_dir).is_dir():
            subprocess.run([
                "runuser", "-u", user.pw_name, "--", "python3", str(payload / "install.py"), "--user-menu"
            ], check=False)
    print("Try Omarchy settings integration installed", flush=True)


if __name__ == "__main__":
    main()
