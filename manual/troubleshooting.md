# Troubleshooting

## Common problems

| Problem | What to do |
| --- | --- |
| Command-Space and similar shortcuts go to macOS | Grant Accessibility in the launcher |
| The camera or microphone doesn't work | Grant the permission in the launcher, or in **System Settings → Privacy & Security** |
| Something broke after `omarchy update` | Restart and pick the snapshot from before the update in the boot menu |
| Omarchy doesn't boot, or hangs | Read the console log: `~/Library/Application Support/Try Omarchy/VM/v1/shell/console.log`. The previous launch's log is `console.log.1` |
| Touch ID falls back to a password | Bring the Omarchy window to the front. If it keeps happening, check that `timedatectl` reports a synchronized clock |
| SSH warns that the host key changed | A new VM has a new key. Run `ssh-keygen -R '[127.0.0.1]:2222'` |
| The VM's external drive isn't connected | Connect it again, or switch back to the default folder when the app offers to |

## Bootloader confirmation

New factory images hand their temporary boot entry to the VM's unique identity before first-boot setup. This prevents a stale kernel hash from stopping later boots at a Limine confirmation. Existing images without the factory ownership marker are left unchanged; an update inside Linux cannot repair a VM that is already stopped before Linux starts.

## Report a problem

- **If it also happens on Omarchy on real hardware,** report it to [Omarchy](https://github.com/omacom/omarchy/issues).
- **Otherwise,** open an [issue](https://github.com/omacom/try-omarchy/issues). Include your app version, macOS version and Mac model. Attach the console log if Omarchy failed to boot, after you've checked it for personal information.
- **Security problems** go through [SECURITY.md](../SECURITY.md), not a public issue.
