# Releasing

Releases are Apple Silicon-only and require macOS 15 or newer.

## Build and verify

```sh
make doctor
make test
make release
```

`make release` lets you choose **patch**, **minor**, or **major**, or type a
version directly in the terminal. Each increment shows its resulting `vX.Y.Z`
tag, calculated from the latest local release tag (or `v0.0.0` when no release
tags exist). There is no default increment: Enter asks you to select a version.
You can also type a custom tag directly. Before building or creating a tag, an
interactive run shows the exact release tag and commit and asks for confirmation
with **No** as the default. Only `y` or `yes` proceeds, including when rebuilding
an existing tag. To choose the version explicitly, including in scripts, use:

```sh
make release VERSION=vX.Y.Z
```

All created tags use `vX.Y.Z`. Custom input and `VERSION` accept `vX.Y.Z` or
`X.Y.Z`, which is normalized to the same tag format. Without an interactive
terminal, `VERSION` is required. The checkout must be clean, including untracked
files; ignored build output does not make it dirty. New versions must be newer
than the local release tags. Fetch any missing tags before choosing a version;
this command does not check GitHub for published versions.

Noninteractive runs with `VERSION` skip confirmation; supplying the version is
the explicit instruction to build that release.

The command builds guest and runtime artifacts only when needed, rechecks the
checkout, creates an annotated `vX.Y.Z` tag on the commit being packaged, and
builds the signed and notarized app and DMG. The tag must exist before packaging
so the app and DMG receive the correct version. Tests and the runtime release
checklist below remain separate verification steps.

If packaging or notarization fails, the local tag remains. Retry with
`make release VERSION=vX.Y.Z`; an existing tag is reused only when it points to
HEAD, and is never moved. The terminal prompt defaults to that existing version
when HEAD is already tagged. A commit with a release tag cannot be given a
second release version through this command, which keeps app version stamping
unambiguous.

`make package` remains available for an already-tagged clean checkout. It
neither prompts nor creates a tag.

After verifying the DMG, run:

```sh
make publish
```

It reads the version from the built app, checks that the DMG exists and that
the app's download manifest points at that tag's parts in `dist/factory/`, and
pushes the tag first, so the release
points at the commit that was built rather than one GitHub would create from
the draft's target branch. It refuses if origin already has the tag on another
commit. It then uploads the DMG and the factory parts to the draft release with
that tag, replacing earlier uploads; a draft named `vX.Y.Z` with no tag yet gets
the tag selected. Without a draft it creates one. A published release is never
changed. Review the draft on GitHub and publish it yourself: until then its
assets are private and the app cannot download the image.

The filename stays the same for every release; the app inside is stamped with
the version from the release tag.

The compressed factory image is over GitHub's 2 GiB asset limit, so it is not
inside the DMG. Production builds split it into 1 GiB parts in `dist/factory/`
(`scripts/split-factory-image.py`) and give the app a manifest with each part's
URL, size and SHA-256 digest. The URLs point at
`https://github.com/omacom/try-omarchy/releases/download/vX.Y.Z/`, so the parts
must be uploaded to the release with the same tag, under their generated names,
before the release is published. A release without them cannot create a new
VM; existing VMs are unaffected.

Always upload the DMG as `TryOmarchy.dmg` so older app release checkers and the
website's stable download link continue to work:
<https://github.com/omacom/try-omarchy/releases/latest/download/TryOmarchy.dmg>.

The factory installs whatever Omarchy's `edge` repositories serve when it is
built, and development builds reuse it until its own inputs change. A release
ships a factory that matches what upstream serves now without rebuilding one
that already does: `make release` asks `scripts/factory-freshness.py --check`
to compare every repository database the factory was built from (`[omarchy]`,
`[core]`, `[extra]`, `[alarm]` and `[aur]`) and the Node.js release it bundles
with upstream's current ones. It reuses the cached factory only when all of
them match, so a second release minutes after the first skips the factory
build; otherwise, or when the check cannot reach upstream, it rebuilds it.
`make release FORCE=1` rebuilds it regardless. Review
`dist/guest/factory.json` and `dist/guest/packages.txt` before publishing.
Existing VMs update themselves with `omarchy update` either way.

Outputs are written to:

- `dist/release.noindex/Try Omarchy.app` (production)
- `dist/TryOmarchy.dmg`
- `dist/guest/`

`make package` and `make release` both create distributable builds: they sign
the app and DMG with Developer ID, submit the DMG to Apple's notarization
service, and staple the resulting tickets. Neither command falls back to an
unnotarized build. Both commands first ensure the content-hashed guest,
runtime and firmware artifacts are current; packaging and signing themselves always run
freshly. Development stays at `dist/app.noindex/Try Omarchy.app` with a separate
bundle ID and privacy grants, so production permission flows can be tested
independently. Another maintainer can override the release defaults:

```sh
make release VERSION=vX.Y.Z \
  RELEASE_SIGN_IDENTITY="Developer ID Application: Example (TEAMID)" \
  RELEASE_NOTARY_PROFILE=example-profile
```

## Release checklist

1. Confirm `main` is clean and all pinned inputs have reviewable provenance.
   Record the factory's `[omarchy]` database digest and Omarchy version from
   `dist/guest/factory.json`.
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
4. Install the release over a provisioned VM created by an earlier release.
   Confirm launch preserves its disk and user data, the guest takes the
   bundled `try-omarchy` package when it is newer (start menu **Omarchy** row),
   and `omarchy update` still completes. Separately confirm that new, reset,
   and ephemeral VMs use the current factory.
5. Verify the app and DMG signatures with Apple's tools and confirm notarization.
6. Audit `THIRD_PARTY_NOTICES.md`, the bundle's license material, the
   factory's `packages.txt`, and QEMU and edk2 corresponding-source obligations.
7. State in release notes that installing the app preserves existing VM
   contents and that Omarchy inside the VM updates through `omarchy update`.
   VMs created by earlier direct-boot releases are not launched by
   this version; their disks stay in the storage folder, and **Setup > Import
   Previous VM** copies their files into the new VM.
8. Record SHA-256 digests for the final app archive/DMG and publish them with the
   release notes.

Never publish generated artifacts from an unreviewed or locally modified build
input.

The guest protocols are a compatibility boundary: the host credential tokens,
every `dev.tryomarchy.*` port, and the guest status report. Older guest
packages must keep working with a newer app, and the reverse.

## macOS compatibility validation

Run `make test` and `make runtime` on macOS 15 and 26 (both covered by CI).
The runtime build runs the pinned VirGL dual-source shader
and blend-state regression tests and rejects bundled Mach-O files targeting a
version newer than 15.0 or strongly importing `strchrnul` (introduced in 15.4).
These binary checks do not replace testing on the supported operating systems.

Before publishing, boot the release app on macOS 15.0–15.3 and macOS 26. Verify
the default terminal draws text correctly while resizing, check desktop
rendering, and test both new and existing guests. By default every Mac must
use EL1 without probing nested virtualization. Turn EL2 back on by default
only after an M3-or-newer Mac boots to the desktop at EL2.
