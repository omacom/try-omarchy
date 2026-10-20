# Agent instructions

How to work on Try Omarchy. It's written for coding agents, and it works for
people too.

Try Omarchy runs stock Omarchy in a virtual machine on an Apple Silicon Mac, and
bridges it to macOS so it feels native. It aims to be the best way to run
Omarchy on a Mac.

## Principles

The full version is in [CONTRIBUTING.md](CONTRIBUTING.md#principles).

- **A shell, not a distribution.** The guest is stock Omarchy. We don't modify
  Omarchy or its packages.
- **Do the minimum.** Change only what Omarchy needs to work well in a VM on a
  Mac. A fix that real hardware also needs belongs upstream.
- **Two places.** Everything inside the guest is one package, `try-omarchy`.
  Everything on the Mac is the app and its VM runtime.
- **Independent updates.** Omarchy updates itself. The app updates separately,
  and brings a newer `try-omarchy` package with it. Each version of the app must
  work with older and newer versions of the package.
- **Follow Omarchy's channel.** We use `edge` today and move to `stable` when
  Omarchy releases its Mac image there.

## Before you start

- **Read the docs for the area you're changing:** first
  [docs/architecture.md](docs/architecture.md), then the component's README.
  For how it works, read the code.
- **Looking for work?** Look at the open
  [issues](https://github.com/omacom/try-omarchy/issues) and the backlog in
  [docs/vm-issues.md](docs/vm-issues.md).

## Rules

- **Never edit files owned by Omarchy or other packages.** Extend Omarchy
  through the `try-omarchy` package, using the mechanisms Omarchy and systemd
  provide.
- **Package upgrades must work offline.** Everything the package needs must
  already be in the image.
- **Treat the guest as untrusted.** Validate everything the Mac side receives
  from it.
- **Version every package change,** so existing VMs pick it up.
- **Leave the person's setup alone.** Never reset, delete or launch over their
  VM, and never take over a Mac someone is using. Test in a disposable VM.
- **Some steps belong to a person.** Stop and ask for:
  - granting macOS permissions;
  - anything involving signing, notarization or credentials;
  - releases, and anything that asks for a password or a confirmation.

  Don't work around these steps.
- **No secrets or personal data** in code, logs, captures or commits.
- **Use `make`** for builds and tests. `make help` lists the targets.

## Workflow

1. **Branch from an up-to-date `main`,** with one concern per branch.
2. **Read** the relevant docs.
3. **Change the code, its tests and its docs together.**
4. **Commit at sensible checkpoints.** Each subject says what changes for the
   user, for example `Keep audio playing after the Mac sleeps`.
5. **Check that the change is [done](#done-means).**
6. **Open a PR** with `gh pr create` and the
   [template](.github/pull_request_template.md). PRs are squash-merged, so write
   the title as a commit subject.
7. **Watch CI and fix failures.** A maintainer reviews and merges.
8. **Update the backlog.** Mark any entry you fixed or disproved.

## Testing

| Level | Where | Covers |
| --- | --- | --- |
| `make test` | Any Mac, and CI | Unit and contract tests for the app, scripts and package |
| Guest checks | CI (Linux) | The package installed on today's Omarchy, and the desktop booted on a virtual display |
| `make e2e` | An Apple Silicon Mac | The real VM: hardware virtualization, the GPU, the Mac bridges, a second boot |

CI cannot boot the VM. A change to the app, the runtime or the bridges needs
`make e2e`, or the PR must say it wasn't run.

## Done means

- The change has one concern, and its tests and docs are updated.
- `make test` passes. For a docs-only change, `git diff --check` passes and the
  links resolve.
- Changes to the VM, the app or the bridges pass `make e2e`.
- Visual changes were checked in the real app or guest, with before and after
  captures (no mockups). PR media is uploaded to GitHub, not committed.
- The PR lists the exact commands, their results, and what wasn't checked.
- Your test VMs are shut down and deleted.

## Writing

- **No code comments.** Make the code clear through names and structure.
- **Keep docs, commits and PRs short and plain.** Say what something does, not
  how good it is. Use one idea per sentence.
- **Docs describe intent and behaviour,** not implementation; that's in the
  code. History belongs in git.
