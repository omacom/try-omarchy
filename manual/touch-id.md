# Touch ID

Use the Mac's Touch ID inside Omarchy. Both integrations are off until you turn them on.

## sudo

1. Choose **Setup → Security → Touch ID for sudo** in the Omarchy menu, or run `try-omarchy-touch-id`.
2. Enter your Omarchy password once, then confirm with Touch ID.

After that, `sudo` asks for Touch ID while the Omarchy window is in front. If Touch ID is cancelled or unavailable, `sudo` asks for your password as usual. The same menu can test, re-pair or turn it off.

Re-pair after you start a new VM, move the VM to another Mac or macOS account, or change your enrolled fingerprints.

## 1Password

1. Turn on Touch ID for `sudo` first.
2. Install 1Password (**Install → Service → 1Password**), sign in, and turn on **Settings → Security → Unlock using system authentication**.
3. Choose **Setup → Security → Touch ID for 1Password**.

Then use 1Password's fingerprint button to unlock it with the Mac's Touch ID. 1Password still asks for your account password after a restart. See [Touch ID for 1Password](../docs/onepassword-touch-id.md) for the details.
