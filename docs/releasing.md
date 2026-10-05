# Releasing

Releases are Apple Silicon-only and require macOS 15 or newer.

## Build and verify

```sh
make doctor
make test
make release
```

`make release` asks for the version in the terminal, suggesting the next patch
after the latest local release tag (or `0.1.0` for the first release). To choose
the version explicitly, including in scripts, use:

```sh
make release VERSION=X.Y.Z
```

Both `X.Y.Z` and `vX.Y.Z` are accepted. Without an interactive terminal, `VERSION`
is required. The checkout must be clean, including untracked files; ignored
build output does not make it dirty. New versions must be newer than the local
release tags. Fetch any missing tags before choosing a version; this command
does not check GitHub for published versions.

The command builds guest and runtime artifacts only when needed, rechecks the
checkout, creates an annotated `vX.Y.Z` tag on the commit being packaged, and
builds the signed and notarized app and DMG. The tag must exist before packaging
so the app and DMG receive the correct version. Tests and the runtime release
checklist below remain separate verification steps.

If packaging or notarization fails, the local tag remains. Retry with
`make release VERSION=X.Y.Z`; an existing tag is reused only when it points to
HEAD, and is never moved. The terminal prompt defaults to that existing version
when HEAD is already tagged. A commit with a release tag cannot be given a
second release version through this command, which keeps app version stamping
unambiguous.

`make package` remains available for an already-tagged clean checkout. It
neither prompts nor creates a tag.

After verifying the DMG, push the tag with `git push origin vX.Y.Z`, then create
the GitHub release manually using that existing tag and attach
`dist/TryOmarchy-vX.Y.Z.dmg`. The filename uses the version stamped into the
app from the release tag (for example, `v0.4.0` produces
`TryOmarchy-v0.4.0.dmg`). `make release` creates the local tag; pushing it,
creating the GitHub release, and uploading the DMG remain manual.

Older app release checkers recognize only `TryOmarchy.dmg`. To keep a release
discoverable by those clients, also upload a copy under that legacy asset name.

When the release updates Omarchy itself, first run:

```sh
make update-omarchy OMARCHY_RELEASE=x.y.z
```

Review both the upstream source change and the regenerated ARM64 package lock
before continuing with the normal build and verification sequence.

Outputs are written to:

- `dist/release.noindex/Try Omarchy.app` (production)
- `dist/TryOmarchy-vX.Y.Z.dmg`
- `dist/guest/`

`make package` and `make release` both create distributable builds: they sign
the app and DMG with Developer ID, submit the DMG to Apple's notarization
service, and staple the resulting tickets. Neither command falls back to an
unnotarized build. Both commands first ensure the content-hashed guest and
runtime artifacts are current; packaging and signing themselves always run
freshly. Development stays at `dist/app.noindex/Try Omarchy.app` with a separate
bundle ID and privacy grants, so production permission flows can be tested
independently. Another maintainer can override the release defaults:

```sh
make release VERSION=X.Y.Z \
  RELEASE_SIGN_IDENTITY="Developer ID Application: Example (TEAMID)" \
  RELEASE_NOTARY_PROFILE=example-profile
```

## Release checklist

1. Confirm `main` is clean and all pinned inputs have reviewable provenance.
2. Run all tests and perform a first-boot provisioning test on a clean Mac user.
3. Verify networking, display scaling, keyboard/mouse, microphone and camera permission,
   on-demand FaceTime HD capture, audio-device changes, clipboard sharing in both
   directions, a shared folder read and written from both sides, persistence,
   reset, and ephemeral mode. Exercise the SSH preset with a provisioned guest:
   confirm the listener is bound only to `127.0.0.1`, normal and ephemeral TCP
   mappings to guest port 22 work, UDP port 22 does not request sshd, a normal
   restart preserves the persistent VM, and the documented endpoint-specific
   host-key recovery works after Reset/ephemeral replacement. Inspect the
   factory image to confirm it contains no SSH host private keys.
4. Install the release over a provisioned VM created by a different guest
   build. Confirm launch preserves its disk and user data, selects the saved
   boot kit instead of the release's bundled kernel/initramfs, and does not
   materialize or charge free space for the new factory disk. For a schema-2 VM
   without a boot kit, confirm the one-time read-only `/boot` export completes,
   but only after the pre-launch dialog appears. Confirm **Cancel** starts no
   QEMU process and changes no disk contents; confirm **Continue** performs the
   recovery, the environment powers off without entering the old userspace,
   and later launches do not repeat it. Separately confirm that new, reset, and
   ephemeral VMs use the current factory.
5. Verify the app and DMG signatures with Apple's tools and confirm notarization.
6. Audit `THIRD_PARTY_NOTICES.md`, the bundle's license material, the guest
   package lock, and QEMU corresponding-source obligations.
7. State in release notes that installing the app preserves existing VM
   contents. Do not claim that the built-in updater reproduces factory changes:
   the direct-boot kernel and headers, `try-omarchy-runtime`, and reviewed
   backports remain pinned until an explicit in-guest migration channel exists.
8. Record SHA-256 digests for the final app archive/DMG and publish them with the
   release notes.

Never publish generated artifacts from an unreviewed or locally modified build
input.

The saved boot-kit ABI is a compatibility boundary. Do not change it or remove
support for an existing value without a reviewed preserving migration or an
explicitly confirmed reset path.

## macOS compatibility validation

Run `make test` and `make runtime` on macOS 15 and 26 (both covered by CI).
The runtime build runs the pinned VirGL dual-source shader
and blend-state regression tests and rejects bundled Mach-O files targeting a
version newer than 15.0 or strongly importing `strchrnul` (introduced in 15.4).
These binary checks do not replace testing on the supported operating systems.

Before publishing, boot the release app on macOS 15.0–15.3 and macOS 26. Verify
Alacritty uses accelerated rendering and correctly draws text while resizing,
check desktop rendering, and test both new and existing guests. macOS 15 must
use EL1 without probing nested virtualization; on macOS 26, verify the existing
EL2 probe and fallback on supported and unsupported hardware respectively.
