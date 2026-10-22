# Native install export

A person moving from Try Omarchy to a native Omarchy install on the same Mac exports their home from the VM. The Omarchy installer on the Mac finds the export and brings it across after Omarchy starts. Only ciphertext and a receipt ever reach the Mac.

## Flow

1. In Omarchy, Menu › Setup › **Move to Native Install** opens `try-omarchy-export-home` in a terminal. The row shows only when the app offers the export shares.
2. The command asks for a transfer passphrase of at least 12 characters. The passphrase stays in the guest.
3. Through `sudo`, `/usr/lib/try-omarchy/export-home` takes a read-only btrfs snapshot of `/home` and bind-mounts it read-only. The exporter refuses a home that is not on a read-only mount, so the running desktop can't change files during the export.
4. The exporter, `omarchy-migration export`, runs as the owner and encrypts with a pinned `age`. Its scratch stays in `/tmp`.
5. `bundle.age` and `receipt.json` go to the outbox share, assembled in a hidden folder and renamed to `<export id>/` when complete. The snapshot is then deleted.
6. While the VM is stopped, `macos/publish-migration-exports.sh` checks each outbox entry: the exact layout, the receipt, the size and the SHA-256. It publishes a valid export into `~/Library/Application Support/Try Omarchy/Exports/<export id>/` through a hidden folder and a rename, never replacing one, and empties the outbox.

## Shares

| Mount tag | Mac side | Guest access | Holds |
| --- | --- | --- | --- |
| `tryomarchy-migration` | the app's exporter | read-only | `omarchy-migration/`, `age`, `age.sha256` |
| `tryomarchy-export` | the VM's outbox | read-write | finished exports, `<export id>/bundle.age` and `receipt.json` |

The guest is untrusted. The Mac publishes nothing it has not checked, and the Omarchy installer verifies each export against its receipt again.

## Not done yet

- The launcher does not offer the two shares or run the publish script yet.
- The app does not bundle `omarchy-migration` and `age` yet.
- The start menu has no row for it yet.
