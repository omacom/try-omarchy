# Touch ID for 1Password in the guest

This opt-in integration unlocks 1Password for Linux using Touch ID on the Mac.
1Password continues to manage the vault and passkeys in the guest. It does not
forward credentials to the Mac or create a separate passkey store.

## Requirements and setup

Use a host helper with the `onepassword-unlock` operation, an already paired
Touch ID guest, and 1Password installed at `/opt/1Password/1password`. The guest
needs Python GObject bindings, GTK 3, and PolkitAgent introspection. The installer
checks these dependencies and does not install packages automatically.

Sign in to 1Password in the guest, enable **Unlock using system authentication**,
then lock and unlock once with the account password. Keep the app running.
1Password's own policy still requires the account password after app restart and
when its password-confirmation interval expires.

From this checkout in the guest, run:

```sh
sudo guest/scripts/install-onepassword-touch-id.sh "$USER"
```

Then lock 1Password and use its fingerprint button. Focus the VM while approving
the Mac's **Unlock 1Password in the focused Try Omarchy guest** prompt.
If Touch ID is denied or unavailable, a guest password dialog uses the standard
polkit PAM session. The 1Password account-password option remains available.

The fallback asks for the guest Linux user's password, not the 1Password account
password. It follows the guest's normal PAM lockout policy. Repeated failed or
abandoned authentication attempts can temporarily block this path even while the
1Password account password still works. Check the guest's authentication journal
and `faillock --user "$USER"` before retrying repeatedly; this integration does
not disable or bypass password lockouts.

Disable the integration without changing PAM or deleting enrollment:

```sh
sudo systemctl disable --now "try-omarchy-onepassword-touch-id@$USER.service"
```

The installer retains replaced files in a root-private directory under
`/var/lib/try-omarchy/onepassword-backup.*`. A host update and guest installation
are both required. Updating only the host does not update an existing guest.

## Authorization boundary

A root-owned agent registers with polkit for the main, installed 1Password
process belonging to the configured guest account. It does not replace the
session-wide agent. Executable ownership, permissions, process start time,
UID, and the active local display session are checked. The installed executable
and its parent directories must be root-owned and not group/other-writable.

Only `BeginAuthentication` from the current system-bus owner of polkit is
accepted. Only `com.1password.1Password.unlock` with the exact guest-user
identity can request Touch ID. CLI, SSH-agent, and other authentication requests
for that process use the normal PAM password path in an unprivileged GTK dialog.
Other processes remain with their existing desktop authentication agents.

The Mac signs a versioned, nonce-bearing request with the dedicated unlock
operation, service, and matching user identities. The guest verifies the pinned
key, signature, request binding, and expiry, then rechecks process, session, and
cancellation before responding to polkit's original cookie. The cookie is not
sent to the Mac. Passwords are handled only by the unprivileged dialog and the
standard polkit authentication helper; a successful dialog exit cannot itself
create an authorization response.

A nonblocking exclusive lock serializes requests on the shared authentication
port. Contention uses password fallback. Closing or disabling the agent removes
its process registrations; the desktop agent remains intact. No blanket `YES`
polkit rules or shared PAM changes are installed.

This is a root-trusting VM design: a compromised root user can change the guest's
authentication policy. Touch ID approval does not attest the guest application or
make a compromised guest trustworthy. Passkeys remain subject to 1Password's
normal guest-side security boundary.
