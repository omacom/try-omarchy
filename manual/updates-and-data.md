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

## VMs from older versions

Versions of the app before 1.0 used a different kind of VM, which this version can't launch. Your old VM's files stay where they were, and the new VM can read them. To copy your files and packages over, choose **Setup → Import Previous VM** in the Omarchy menu, or run `try-omarchy-import-previous --dry-run` to see what would be copied.

### Removing the old VM

Once you have everything you need, delete the old VM to free its disk space. Until then, the new VM keeps attaching it read-only.

1. In the new VM, check that your files are there. The import copies your home folder's files and a few settings, but not the rest of `~/.config` or anything outside your home. Run `try-omarchy-import-previous --open` to browse the old VM and copy anything else you need, then `--close`. `try-omarchy-import-previous --packages --dry-run` lists any packages the old VM had that you haven't installed yet.
2. Shut down Omarchy.
3. In Finder, choose **Go → Go to Folder…** and open the VM folder: `~/Library/Application Support/Try Omarchy/VM/v1`, or the folder shown in **Manage…**. Move the `disks`, `boot` and `locks` folders to the Trash. They belong only to the old VM. Leave everything else alone: `shell`, `shell-factory` and `settings.json` are your new VM.
4. Empty the Trash to free the space. Until then, you can put the folders back.

To delete them permanently from the Terminal instead, for the default folder:

```sh
rm -rf ~/Library/"Application Support/Try Omarchy/VM/v1"/{disks,boot,locks}
```

To see how much space they use first, run `du -sh ~/Library/"Application Support/Try Omarchy/VM/v1"/{disks,boot,locks}`.
