# Guidance for coding agents

These rules apply to the whole repository. A more specific `AGENTS.md` in a
subdirectory, if one is ever added, extends them for the files beneath it; read
it before editing there. For anything not covered here, follow the linked docs
rather than restating them.

## Purpose and scope

`server-bootstrap` turns a fresh Ubuntu 24.04 host, run as root on x86-64 or
ARM64, into a pinned and verified development environment. It checks the
hardware before any workload and starts nothing on its own: no workload, model
download, or public port. Maintainer tooling needs Bash and Python 3; the
pinned Gitleaks and actionlint binaries are Linux x86-64 only.

Details: [README](README.md), [ARCHITECTURE](docs/ARCHITECTURE.md),
[CONFIGURATION](docs/CONFIGURATION.md), [PROVISIONING](docs/PROVISIONING.md),
[BUNDLE-CONTRACT](docs/BUNDLE-CONTRACT.md),
[TROUBLESHOOTING](docs/TROUBLESHOOTING.md), [SECURITY](SECURITY.md),
[SECURITY-SCANNING](docs/SECURITY-SCANNING.md), [CHANGELOG](CHANGELOG.md).

## Entry points

| Path | Role |
| --- | --- |
| `server-provision.sh` | First run: verify and extract the archive, bootstrap, accept, then bundles in plan order |
| `server-bootstrap.sh` | Inner foundation installer; also the rerun and repair command |
| `server-bundle-install` | Install one named, versioned, checksum-verified bundle |
| `server-accept.sh` | Hardware acceptance report and policy |
| `server-vscode-extensions`, `server-secrets` | Extension installer; API key file manager |
| `release/build-release.sh`, `tools/release-preflight.sh` | Reproducible build; every pre-publication gate |

A `provision-plan*.sh` file is data read through `server-provision.sh --plan`.
Never execute one directly.

## Layout

- `lib/` shared shell: `core.sh` (logging, verified downloads), `archive.sh`
  (safe extraction), `bundle.sh`. `lib/bootstrap/` holds one module per
  subsystem; `lib/bootstrap/config.sh` is the canonical source of the toolchain
  pins. The scanner and linter pins live in `tools/gitleaks.sh` and
  `tools/actionlint.sh`.
- `config/` apt package and VS Code extension manifests.
- `checksums/` pinned upstream checksums and `SHA256SUMS`, the release manifest.
- `examples/` shipped plans and templates; `docs/` user guides.
- `release/` the canonical file set and the build; `release/dist/` is output.
- `tests/` the suite and the privacy guard; `tools/` pin, scanner, linter and
  preflight scripts; `.github/workflows/` CI, release and pin drift.

## Before editing

- One issue, one branch, one pull request per change. Do not fold in unrelated
  fixes.
- Run `git status` first. Changes already in the worktree belong to the user:
  keep them, and do not reset, stash, clean, or overwrite them unless asked.
- Read the linked issue and any nested `AGENTS.md` for the files you touch.

## Security boundaries

- A new download must be pinned to an exact version and verified, over HTTPS,
  against a SHA-256 recorded in this repository before it is used or extracted,
  as Node.js, uv, `gh`, Gitleaks and actionlint already are (`lib/core.sh`,
  `tools/gitleaks.sh`). The npm-installed AI CLIs are exact versions without a
  repository checksum; do not describe them as checksum-verified. No
  `curl | sh`, and `latest` is a user opt-in, never a default.
- GitHub Actions are pinned to a full commit SHA with a version comment.
- Secrets never enter fixtures, logs, commits, issue or pull request text, or
  history. Tests that need a key-shaped value build it at runtime in a temporary
  directory; see [the fixture rule](SECURITY.md#fixture-and-test-data-rule).
  Never broaden the `.gitleaks.toml` allowlist.
- If you find a credential, stop, do not repeat its value, and tell the owner.
  Rotation comes first; the fix is an ordinary new commit ([SECURITY](SECURITY.md)).

## Release invariants

- The release file set is `git ls-files`. After changing any tracked file, run
  `bash release/release-files.sh write` and commit `checksums/SHA256SUMS`.
- Never commit `release/dist/`, archives, or logs.
- Change toolchain pins with `tools/refresh-pins.sh --write`, never by hand in
  one file. `CHANGELOG.md` is a hand edit that keeps `## Unreleased` first.
- A file the installed runtime needs is registered in `lib/bootstrap/runtime.sh`
  and in the verify list in `release/build-release.sh`.
- Release gates live in `tools/release-preflight.sh`; `.github/workflows/release.yml`
  runs only that script.
- A release tag is exactly `v` plus `VERSION`. A version is spent once tagged: a
  tag is never reused, moved, or deleted.

## Validation

Run these before every push and report the pass/fail totals:

```bash
bash release/release-files.sh verify   # manifest matches the tracked files
bash tests/run-tests.sh                # full suite, including the privacy guard
bash tests/privacy-guard.sh            # credential names, key material, tracked output
bash tools/check-pins.sh               # every pin recording agrees, offline
bash tools/release-preflight.sh        # pinned Gitleaks, double build, artifact scan
```

Also run `bash tools/actionlint.sh run` when a workflow changes, and
`bash tools/refresh-pins.sh --check` (needs network) when a pin changes. Never
skip, weaken, or disable a check to get green: no `--skip-tests`, and no
`SB_RELEASE_SCAN=0` outside offline development.

## Owner approval required

Do none of these without the repository owner's explicit approval for that
specific action:

- merge a pull request;
- change repository metadata or settings: description, topics, labels, branch
  protection, secrets, or Actions settings;
- create, push, move, or delete a tag, or publish, edit, or delete a release;
- force-push (`--force`, `--force-with-lease`) or otherwise force-overwrite a ref;
- rewrite history: amend, rebase, or reset pushed commits, or run
  `git filter-repo`, `git filter-branch`, or BFG.

[SECURITY](SECURITY.md#history-preservation-and-remediation) forbids force
pushes, tag reuse, and history rewrites as remediation; any exception is the
owner's decision alone.
