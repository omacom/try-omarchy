# Releasing

Read this before preparing a release. [docs/releasing.md](../../docs/releasing.md) has the details.

1. **List what changed** since the last release tag: `git log --oneline vX.Y.Z..origin/main`.
2. **Pick the version.** Features people notice make a minor release. Fixes only make a patch release.
3. **Update [What's New](../../docs/releasing.md#whats-new)** if the release has something people would notice. Leave it unchanged for a fixes-only release, and it won't show. Change it in a PR and merge it before tagging.
4. **Build from an up-to-date `main`:** `make doctor`, `make test`, then `make release VERSION=vX.Y.Z`.
5. **Upload to a draft:** `make publish`. Write the notes in the format of the previous release.
6. **Stop at the draft.** A person reviews and publishes it. Signing, notarization and credentials also belong to a person: if they fail, stop and ask.
