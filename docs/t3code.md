# T3 Code

Choose **Install → AI → T3 Code** to download the official ARM64 AppImage.
The installer sets up FUSE 2, the launcher, and the Omarchy theme. The app and
its `t3` command live in `~/.local/share/try-omarchy/t3code`.

Use **T3 Code’s settings** to update or switch to nightly. Omarchy never
replaces the installed version or channel.

Once installed, the menu offers **Remove → AI → T3 Code** instead. It deletes
the app, configuration, and workspaces, and keeps agent state such as
`~/.claude.json`.

## Existing VMs

Existing VM disks keep their original Omarchy menu. From a checkout containing
this change, run inside the guest:

```sh
./guest/native-overlay/usr/local/lib/try-omarchy/install-t3code-arm64 --from-checkout "$PWD"
```

This installs the app and its launcher without the Omarchy theme or menu
entries. Add `--remove` to uninstall it.
