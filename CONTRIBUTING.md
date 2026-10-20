# Contributing

Try Omarchy runs stock Omarchy on an Apple Silicon Mac and bridges it to macOS.
Read the principles before you change anything. [AGENTS.md](AGENTS.md) covers
the workflow and rules. It is written for coding agents, and it works for people
too.

## Principles

1. **Don't modify Omarchy.** The guest is a stock `aarch64` Omarchy install. We
   never edit, fork, pin or replace Omarchy or its packages.
2. **Do the minimum.** Change only what Omarchy needs to work well in a VM on a
   Mac. If a change would also make sense on real hardware, it belongs
   upstream.
3. **Two places.** Everything inside the guest is one package, `try-omarchy`.
   Everything on the Mac is the app and its VM runtime.
4. **Independent updates.**
   - Omarchy updates itself, at any time.
   - The app updates from releases, and brings a newer `try-omarchy` package
     with it.

   No version may assume another one moved with it. The app and the package
   must work with each other's older and newer versions.
5. **Follow Omarchy's channel.** The image uses `edge`, the only channel Omarchy
   publishes for ARM today. It moves to `stable` when Omarchy releases its Mac
   image there.
6. **Fix upstream when you can.** Report bugs to Omarchy, its packages, QEMU or
   VirGL. Carry a local fix only until upstream has its own.

## Where things belong

| Problem | Where |
| --- | --- |
| It also happens on real hardware | [Omarchy](https://github.com/omacom/omarchy) |
| A missing or broken `aarch64` package | [omarchy-pkgs](https://github.com/omacom/omarchy-pkgs) |
| The VM, its devices or the app | `macos/` |
| Making Omarchy aware of the Mac | `guest/package/` |
| Building the Omarchy image | `guest/factory/` |

## Pull requests

- **One concern per PR.** A fix and a cleanup are two PRs. Small fixes don't
  need an issue. For larger behavioural or architecture changes, open an issue
  first.
- **Commit subjects and PR titles say what changes for the user.**
- **Use the [PR template](.github/pull_request_template.md).** Say what you
  tested, and what you couldn't.
- **Update the docs** when behaviour or requirements change.
- **Coding agents are welcome.** You still own every line they write, and you
  must have tested it.

## Writing

- No code comments. Make the code clear through names and structure.
- Keep docs, commits and PRs short and plain. Say what something does, not how
  good it is.
- Docs explain intent and behaviour. Implementation lives in the code.

## Build from source

You need an Apple Silicon Mac with macOS 15 or newer and these tools:

- Xcode command-line tools;
- Python 3;
- `pkg-config`;
- Docker;
- about 40 GB of free space.

```sh
make build run   # first build, then launch
make run         # rebuild what changed, then launch
make help        # every target
```

- **Builds are incremental and pinned.** Update a pinned input together with its
  validation.
- **`make clean` removes build output.** `make clean-all` also deletes your VMs.
- **Releases** follow [docs/releasing.md](docs/releasing.md).

## Tests and CI

| Level | Where | Covers |
| --- | --- | --- |
| `make test` | Any Mac, and CI on macOS 15 and 26 | Unit and contract tests. CI also builds the runtime |
| Guest checks | CI on Linux | The package on today's Omarchy: install, upgrade, and the desktop on a virtual display |
| Nightly | CI on Linux | The same guest checks on a fresh image from live Omarchy, which catches upstream changes early |
| `make e2e` | An Apple Silicon Mac | The real VM, which CI cannot boot: the GPU, the bridges, the shared folder, a second boot |

Run `make e2e` before opening a PR that changes the app, the VM or the bridges.
Tests check behaviour, never pixels or timing.

## Issues and security

Search existing issues first. Say whether the problem is in the Mac app or
inside Omarchy, and include your app version, your macOS version and your Mac.
Report vulnerabilities privately through [SECURITY.md](SECURITY.md).

By contributing, you agree to license your contribution under the
[MIT License](LICENSE).
