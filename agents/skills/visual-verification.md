# Visual verification

Read this before finishing any change with a visual effect: the launcher, the VM window, full screen and the notch, or anything Try Omarchy changes on the Omarchy desktop.

## Do

- **Check the real app or guest.** Tests are not enough, and neither are mockups.
- **Capture before and after.** Compare them for clipping, overlap, spacing, stale state and focus.
- **Record motion.** If the change is about animation, a transition or timing, review a short recording of it.

## Capture

- **On the Mac,** use `screencapture -x <file>.png` for a still and `screencapture -v -V<seconds> <file>.mov` for a recording. Make sure the Try Omarchy window is the one in front.
- **Inside the guest,** use `grim` as the desktop user. Windows drawn by the GPU can come out black in `grim`, so check those on the Mac instead.
- **Without a person present,** use a disposable VM ([test VMs](test-vms.md)). Never take over a Mac someone is using.

## Share

Attach captures to the PR when they help a reviewer understand the change. Upload them to GitHub; never commit them. Remove secrets and personal information first.
