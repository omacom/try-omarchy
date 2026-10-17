# Contributing

Thanks for helping improve Try Omarchy. The project has one product target: a
native Apple Silicon macOS app that runs stock upstream Omarchy for `aarch64`
in a virtual machine, with the Mac integrations in one guest package.

## Pull requests

Small fixes and documentation improvements are welcome without an issue first.
For large behavioral or architecture changes, open an issue to discuss the idea
before starting work.

Keep each PR focused and explain what changed, why, and how you tested it. Run
relevant tests when you can (`make test` runs the full suite on macOS), and say
what you could not check. Documentation-only changes do not need an app build
or the full test suite. Screenshots or a short video are helpful when they make
UI changes easier to review.

Update documentation when usage or requirements change. If you change build
inputs, review their pins and checksums and run the relevant component build;
explain any validation you could not complete. See the details below.

## Reporting issues

Before opening a report or proposal, search open and closed issues for the same
problem or idea. Add useful details to an existing issue, or link related issues
in your new report.

Tell us what happened, what you expected, and whether it happens in the Mac app
or inside Omarchy. Include your app version, macOS version, Apple chip, and
steps to reproduce if known. Logs, screenshots, and recordings are optional;
remove secrets and unrelated personal information before sharing them.

You can open a report even if you cannot reliably reproduce the problem or do
not know every system detail. For change proposals, describe the problem and
what you would like to improve; a full implementation plan is not needed.

Report suspected vulnerabilities through [SECURITY.md](SECURITY.md), not public
issues. Coding agents should also read [AGENTS.md](AGENTS.md).

## Build inputs and local state

The QEMU supply chain and the builder's keys are deliberately pinned. Do not
update a URL, commit, archive, or checksum independently of its associated
validation code. The factory installs from Omarchy's live repositories; its
`dist/guest/factory.json` records the database digest it resolved against.

Generated files in `dist/` and build caches in `macos/.build/` are not
committed. Use `make clean` to remove project build
artifacts and caches. `make clean-all` additionally destroys persistent local
VM data and should only be used when a complete reset is intended.

Component builds use content-hashed state under `.build/state/`. A state file is
published only after the build succeeds and its output passes validation. Use
`FORCE=1` when reviewing reproducibility or when an intentionally unchanged
input must be rebuilt; do not work around the cache by editing generated state.

## Updating Omarchy and the guest package

The guest updates itself with `omarchy update`, so there is no Omarchy pin to
move. The factory is cached by its own inputs, not by upstream: after each
`make build` a check compares Omarchy's edge index with the one the factory
was built from and says how old the factory is and which installed packages
are newer upstream. `make refresh` rebuilds the factory from the latest
Omarchy, then builds. `make release` rebuilds it unless every repository and
the Node.js release it was built from still match upstream (`FORCE=1` always
rebuilds). Review
`dist/guest/factory.json` and `dist/guest/packages.txt` afterwards.

Mac integrations in the guest live in the `try-omarchy` package
([guest/package](guest/package/README.md)). Bump its `pkgrel` (or `pkgver`)
whenever its contents change, so existing VMs take the new package at their
next boot; the guest installs the app's package only when it is newer. Keep
host-guest protocols compatible in both directions: a newer app must work with
an older package, and the reverse. Run `make guest-package` and `make test`.

## Tests

`make test` runs the complete suite with up to four independent suites at once.
The Swift build and tests finish before any shell suite uses the native helper.
Use `make test TEST_JOBS=1` for serial output when debugging, or set `TEST_JOBS`
to another positive integer to bound concurrency. Individual groups are available
as `make test-contracts`, `make test-guest` (the guest package), `make test-swift`,
and `make test-shell`.

PR checks run all tests and full runtime builds in separate, concurrent jobs on
both macOS 15 and 26, labeled `Tests` and `Build`. Beside them, three Linux
arm64 jobs check the guest the way a user meets it:

- `Guest contracts` runs `make test-guest` on GNU tools, the guest scripts
  through ShellCheck, and `make test-upstream`, which checks the package's menu
  rows, commands, unit drop-ins and paths against the Omarchy the factory
  installs today.
- `Guest package install` installs the package with its dependencies from
  Omarchy's live repositories, builds its DKMS modules, upgrades from the base
  revision's package (whose version must be lower when the package changed)
  and removes it (`make test-guest-install`).
- `Guest desktop` boots the factory's userland with systemd-nspawn, offers the
  change's package the way the app offers its bundled one, and checks
  first-boot setup, the system and package units, Omarchy's desktop session on
  a vkms virtual display, its keybindings, the browser, screen recording, a
  theme switch, the factory's apps, and Ghostty, Kitty and 1Password installed
  the way Omarchy's Install menu does
  ([guest/tests/desktop/run.sh](guest/tests/desktop/run.sh)). It boots the
  nightly factory unless the change touches the factory's own inputs, which
  then build here. Screenshots and logs are kept with the run.

No suites or runtime checks are skipped based on changed paths or cached test
results; the builder image, package downloads and the nightly factory are
cached.

Outside pull requests:

- **Guest desktop** (nightly, or by hand from the Actions tab) builds a new
  factory from Omarchy's live repositories and runs the same checks with VS
  Code and Signal added. Its factory is the one pull requests boot the next
  day.
- **`make e2e`** (on an Apple Silicon Mac, with Docker running) boots a
  disposable VM in the built app's own runtime and adds what only a Mac has:
  HVF, VirGL on the Mac's GPU, Omarchy's keybindings on the VM's keyboard, the
  bridges, the shared folder, shutdown and a second boot ([tests/e2e/run.sh](tests/e2e/run.sh)). Run it before opening a
  pull request that changes the app, the runtime, the launcher or the bridges
  (the template's checklist asks), and before a release.

Tests should describe a user-visible behavior, policy, data contract, or
process boundary. Keep presentation and edit rules in deterministic models that
can be exercised without opening AppKit windows. Do not make CI depend on pixel
coordinates, font metrics, display size, global window lookup, fixed run-loop
delays, or an assumed free network port.

Platform integration tests are appropriate when the operating-system boundary
is itself the contract. Use isolated temporary state, inject controllable
probes where the real resource is incidental, and use bounded readiness checks
instead of fixed settling delays.

By contributing, you agree that your contribution is licensed under the MIT
License in this repository.
