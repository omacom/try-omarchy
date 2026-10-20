# Test VMs

Use this guide to run, enter or inspect a VM without touching the person's own VM.

## Pick a VM

- **`make run-ephemeral`** opens the built app with a throwaway VM. The VM is discarded when the app quits. Use it to look at a change by hand.
- **`make e2e`** boots a disposable VM in the built app's runtime and runs every check, from first boot through a second boot. It needs Docker and takes about 10 minutes. Use it before a PR that changes the app, the runtime or the bridges.

Set `E2E_ARGS` to pass options to [tests/e2e/run.sh](../../tests/e2e/run.sh):

- `--package FILE` tests a guest package without rebuilding the app.
- `--no-installs` skips the app installs, for a faster run.
- `--keep` keeps the VM and its SSH key in `.build/e2e/vm-<time>/`.

Each run's results, screenshots and logs are in `.build/e2e/<time>/`.

## Get into a kept VM

1. Start the kept VM with the built app's launcher. Point it at the VM's folder and forward a free port to SSH:

   ```sh
   OMARCHY_QEMU_GPU_STATE_ROOT=<vm>/state OMARCHY_QEMU_GPU_PORT_FORWARDS=tcp:<port>:22 \
     "dist/app.noindex/Try Omarchy.app/Contents/Resources/scripts/run-qemu-gpu.sh"
   ```

2. Log in as root: `ssh -i <vm>/ssh-key -p <port> root@127.0.0.1`.
3. To run a command as the desktop user, use `runuser -u <user> -- env XDG_RUNTIME_DIR=/run/user/<uid> DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/<uid>/bus <command>`.
4. To press keys on the VM's keyboard, run `tests/e2e/qmp-keys.py <socket>`. The launch log prints the socket as `[qemu-gpu] Ready. QMP: <path>`.

## Read the logs

- **Boot problems:** the guest console log is `console.log` in the VM's folder.
- **Inside the guest:** `journalctl -b` for the system, and `journalctl --user -b` for the desktop user.
- **To see what the launcher would run:** `OMARCHY_QEMU_GPU_DRY_RUN=1` prints the QEMU command and the host settings without starting anything.

## Clean up

When you're done, shut down your test VMs and delete their folders.
