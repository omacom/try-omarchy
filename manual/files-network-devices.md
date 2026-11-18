# Files, network and devices

## Shared folder

Share one Mac folder from the launcher's **Sharing** pane. It shows up in Omarchy's home folder under the same name: `~/Work` on the Mac is `~/Work` in Omarchy.

- Omarchy can read and write it, so share only what Linux apps may change.
- You can't share your whole home folder, `~/Library` or system folders.
- Keep databases and apps that memory-map files on Omarchy's own disk. See [shared-folder safety](../docs/shared-folder-safety.md).

## Reaching services

- **From Omarchy to the Mac:** connect to `10.0.2.2:<port>`.
- **From the Mac to Omarchy:** add a port forward in the launcher's **Network** pane. Forwards listen only on the Mac's `127.0.0.1`, so other devices can't reach them. The service in Omarchy must listen on `0.0.0.0`, not only on localhost.

## SSH

1. Finish Omarchy's first-boot setup.
2. In **Port Forwarding**, choose **Add SSH** and save it. That forwards Mac port `2222` to Omarchy's port `22`.
3. Connect with your Omarchy username and password: `ssh -p 2222 <user>@127.0.0.1`. Then add a key with `ssh-copy-id -p 2222 <user>@127.0.0.1` if you want one.

To shorten the command, add this to `~/.ssh/config`. It then works for `ssh omarchy`, `scp`, `rsync`, Git and VS Code Remote SSH:

```text
Host omarchy
  HostName 127.0.0.1
  Port 2222
  User <user>
```

A new VM has a new host key. If SSH warns that the key changed, run `ssh-keygen -R '[127.0.0.1]:2222'`.

## Bridged networking

By default, Omarchy shares the Mac's connection (NAT). **Bridged** gives Omarchy its own address on your network instead.

- The first time, approve the networking helper in System Settings.
- Port forwards don't apply in bridged mode. Services are reachable on Omarchy's own address. SSH from the network is a separate opt-in.
- Omarchy keeps the same MAC address across updates and moves, so you can reserve its IP in your router.
- If you copy a VM to run beside the original, generate a new MAC address for the copy first.
- Only one bridged VM can run at a time.

## USB devices (experimental)

Choose one USB device in the launcher's **Sharing** pane, and Omarchy gets it at the next launch.

- **Only devices with no macOS driver work.** These are things like SDR receivers, debug probes and custom boards. macOS keeps drives, keyboards, audio interfaces and docks.
- **Hubs can't be passed through.**
- **The device is tied to its port.** If you move it to another port, choose it again.
- **Keep it plugged in while Omarchy runs.** Unplugging it can freeze the window for up to 30 seconds.
