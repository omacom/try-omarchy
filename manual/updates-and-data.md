# Updates and your data

## How updates work

Three things update separately, and none of them needs a new VM.

| What | How |
| --- | --- |
| Omarchy | Inside Omarchy: **Update → Omarchy**, or `omarchy update`. It takes a snapshot first, so you can roll back from the boot menu |
| The app | The launcher checks for new releases once a day, or use **Check for Updates…**. To update, quit the app and replace it with the new download. Your VM stays as it is |
| The Mac integrations | Each app release brings a newer `try-omarchy` package. Omarchy installs it automatically at its next boot |

Omarchy publishes for ARM on its `edge` channel only, so that's the channel Try Omarchy uses. Once Omarchy releases its Mac image on `stable`, Try Omarchy will move to `stable` too.

## Where your VM lives

The VM lives in `~/Library/Application Support/Try Omarchy/VM/v1`. Deleting or updating the app leaves it in place.

To manage it, shut down Omarchy and open **Manage…** in the launcher's **Virtual Machine** pane. From there you can:

- **switch** to a VM in another folder;
- **move** the VM to another folder or drive. The copy is checked before the original goes to the Trash;
- **create** a separate VM in an empty folder;
- **delete** the VM. It goes to the Trash, so **Put Back** undoes it.

Each VM keeps its settings in its own folder, so they move with it, and switching to another VM switches to its settings.

The VM's drive must be APFS. Don't unplug an external drive while Omarchy is running.

## Resources

Set CPU cores, memory and the maximum disk size in **Resources → Configure…**. Changes apply at the next launch.

- **Memory** defaults to 8 GiB on Macs with 16 GiB or more, and 4 GiB otherwise. At least 4 GiB always stays with macOS. Memory Omarchy isn't using goes back to macOS.
- **Disk** defaults to 64 GiB. It takes space on the Mac only as Omarchy fills it. You can make it bigger later, but not smaller.

## Starting over

- **Reset settings:** **Virtual Machine → Reset Settings…** returns every setting to its default. The VM is not touched.
- **Fresh Omarchy:** delete the VM in **Manage VMs**. The next launch creates a new one from the latest image, with default settings.

## Moving to a native install

When the Omarchy installer runs your VM, you can move your files from it to Omarchy installed on this Mac. Try Omarchy on its own doesn't offer this.

1. Start Omarchy from the Omarchy installer. In the Omarchy menu, choose **Setup → Move to Native Install**.
2. Choose a transfer passphrase of at least 12 characters. Keep it: Omarchy asks for it on the native install, and it can't be recovered.
3. Shut down Omarchy when the command says the export is ready.
4. In the Omarchy installer, choose **Migrate to Native**. It finds the export and checks it before the install.

The export holds your files, projects and settings. SSH and GPG keys, saved logins and tokens, browser data, and the VM's own display and keyboard settings stay behind. It is encrypted with your passphrase, and the VM is left as it was.

Exports are kept in `~/Library/Application Support/Try Omarchy/Exports`.

## VMs from older versions

Versions of the app before 1.0 used a different kind of VM, which this version can't launch. Your old VM's files stay where they were, and the new VM can read them. To copy your files and packages over, choose **Setup → Import Previous VM** in the Omarchy menu, or run `try-omarchy-import-previous --dry-run` to see what would be copied.
