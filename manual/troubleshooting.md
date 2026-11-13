# Troubleshooting

## Common problems

| Problem | What to do |
| --- | --- |
| Command-Space and similar shortcuts go to macOS | Grant Accessibility in the launcher |
| The camera or microphone doesn't work | Grant the permission in the launcher, or in **System Settings → Privacy & Security** |
| Something broke after `omarchy update` | Restart and pick the snapshot from before the update in the boot menu |
| The desktop stays black after `omarchy update` | See [black desktop after an update](#black-desktop-after-an-update) |
| Omarchy doesn't boot, or hangs | Read the console log: `~/Library/Application Support/Try Omarchy/VM/v1/shell/console.log`. The previous launch's log is `console.log.1` |
| Touch ID falls back to a password | Bring the Omarchy window to the front. If it keeps happening, check that `timedatectl` reports a synchronized clock |
| SSH warns that the host key changed | A new VM has a new key. Run `ssh-keygen -R '[127.0.0.1]:2222'` |
| The VM's external drive isn't connected | Connect it again, or switch back to the default folder when the app offers to |

## Black desktop after an update

Omarchy's update to Hyprland 0.57 can leave the VM's desktop black: no bar, no wallpaper, no windows. Newer versions of the app fix it at Omarchy's next boot. Until you have one, fix it over SSH:

1. Quit the app. In the launcher's **Port Forwarding**, choose **Add SSH** and save it. Then start Omarchy.
2. In the Mac's Terminal, connect with `ssh -p 2222 <user>@127.0.0.1` and run:

   ```sh
   mkdir -p ~/.config/uwsm/env.d
   echo 'export AQ_NO_ATOMIC=1' > ~/.config/uwsm/env.d/60-vm-display
   sudo reboot
   ```

To undo the update instead, pick the snapshot from before it in the boot menu. Avoid `snapper rollback` from a shell: in the VM it can leave Omarchy unable to boot.

## Report a problem

- **If it also happens on Omarchy on real hardware,** report it to [Omarchy](https://github.com/omacom/omarchy/issues).
- **Otherwise,** open an [issue](https://github.com/omacom/try-omarchy/issues). Include your app version, macOS version and Mac model. Attach the console log if Omarchy failed to boot, after you've checked it for personal information.
- **Security problems** go through [SECURITY.md](../SECURITY.md), not a public issue.
