# Working on Try Omarchy

Read [CONTRIBUTING.md](CONTRIBUTING.md) before making changes. It covers the
contributor workflow; the instructions below add verification guidance for
coding agents.

## Project orientation

- The product is a native Apple Silicon macOS app running pinned upstream
  Omarchy in a project-built ARM64 guest with QEMU/HVF.
- Read [docs/architecture.md](docs/architecture.md) for component boundaries
  and the relevant component README before changing its behavior.
- `macos/` owns the native app, runtime patches, and host integration; `guest/`
  owns the image, package lock, and guest contracts. Use the root `Makefile`
  for builds and tests.

## Preparing contributions

- Keep changes focused. Small fixes do not need an issue first; discuss large
  behavioral or architecture changes before implementation.
- Use the short [PR template](.github/pull_request_template.md), including when
  supplying a body through a CLI or API. Omit details that do not apply.
- For code changes, run focused tests while working and `make test` before
  finishing. For documentation-only changes, check links, template metadata,
  and `git diff --check`; an app build or full test run is unnecessary.
- If build inputs change, run the relevant component build and review pins,
  checksums, and their associated validation together.
- Report exact verification commands and results, including failures and
  checks not run. Full native verification requires macOS; explain platform
  limitations rather than reporting skipped checks as passing.

## Visual verification

- Verify visual changes in the running app or guest, and inspect captures for
  regressions. Compare before/after states for layout or appearance changes;
  review a short recording when motion or interaction is what changed.
- Attach captures to the PR when they help explain the change. Use the actual
  app or guest, not generated mockups, and upload PR-only media to GitHub rather
  than committing it. Remove secrets and unrelated personal information.
- If runtime verification is unavailable, say what remains unchecked.
