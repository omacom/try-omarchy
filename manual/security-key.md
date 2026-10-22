# A USB security key connected to the Mac

This experimental command-line feature forwards one USB FIDO security key to the Omarchy guest. It is off by default. The selected FIDO interface belongs to the VM while forwarding runs, so the Mac cannot use it for FIDO authentication at the same time. Other key interfaces are not forwarded.

Use a guest you trust with the key's FIDO interface. The bridge forwards reports without logging them. It does not limit the guest to browser authentication.

## Select and enable

Quit an already-running Try Omarchy VM first. List the keys with the helper in your app, adjusting the app path if needed:

```sh
app="/Applications/Try Omarchy.app"
"$app/Contents/MacOS/omarchy-vm-helper" --list-fido-devices
```

Choose the `id` of one entry whose `supported` field is `true`. The listing does not take ownership of the key. Start the app with that exact ID:

```sh
open -n --env "OMARCHY_QEMU_GPU_FIDO_DEVICE=0xYOUR_SELECTED_ID" "$app"
```

For a development build, pass the same variable to `make run`. Do not enable experimental whole-device USB passthrough for the same session. This first version supports USB FIDO interfaces with unnumbered 64-byte reports, regardless of vendor.

The guest's integration package must include FIDO support. The app offers its bundled package at boot as usual. After the guest connects, use the key from the guest browser and touch it when prompted.

## Stop and reconnect

Quitting the VM releases the interface. To stop forwarding while the VM stays open, run this inside the guest:

```sh
sudo systemctl stop omarchy-native-fido-bridge.service
```

The guest's virtual device closes immediately. The Mac may retain the interface until its ten-second lease expires after the last guest activity. Allow for release before trying host authentication again; physical-key recovery still needs validation on the target builds.

For a later session without forwarding, launch Try Omarchy normally without the environment variable. The selection is not saved as a preference. After unplugging a key, list devices again and explicitly choose its new ID before launching another session. The app never substitutes another key for a missing selection.

See [FIDO bridge design and remaining hardware acceptance](../docs/fido.md) for current limits. Physical registration, authentication, recovery and cross-vendor compatibility must be validated on the target app and guest builds.

Forwarding requires matching protocol-2 app and guest helpers (guest package `0.1.0-35` or newer). Older experimental protocol-1 helpers use a different port and cannot connect to a protocol-2 peer. Stop any already-running legacy forwarding session before updating. Update both components and restart the VM; a mismatch leaves the VM usable but FIDO forwarding unavailable.
