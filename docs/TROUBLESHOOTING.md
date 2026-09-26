# Troubleshooting

## Claude or Codex is installed but asks for login

That is expected. Authentication is user-specific and is not placed in the
bundle. Run `claude` or `codex` interactively and follow the browser/device flow.

## API keys are not loaded in my shell

The loader is sourced from `/root/.zshrc`, and Zsh reads `.zshrc` only for
**interactive** shells. An SSH session or `exec zsh -l` gets it; `zsh -l -c '...'`
does not, so a non-interactive check reports the keys as unset even when the
setup is correct. Check with an interactive shell:

```bash
zsh -i -l -c 'aikeys status'
```

If that is empty too, inspect the file itself with `server-secrets status`.

## `claude` or `codex` is missing

Check the pinned installation and launchers:

```bash
node --version
npm --version
ls -l /opt/ai-cli/bin /usr/local/bin/claude /usr/local/bin/codex
cat /workspace/.setup-state/claude-code-version
cat /workspace/.setup-state/codex-version
```

Rerun `server-bootstrap`. A failed exact-version npm install stops the
bootstrap rather than silently using another version.

## A version other than the pinned one was installed

Every setting is an environment override (`VAR="${VAR:-default}"`), so a
variable already exported in the calling environment beats the release pin.
Some tooling exports these: a Claude Code session sets `CLAUDE_CODE_VERSION`,
and the bootstrap honours it. The state files record what was actually
installed, not what was pinned:

```bash
cat /workspace/.setup-state/claude-code-version
```

Provision from a clean environment when you want the pinned defaults:

```bash
env -u CLAUDE_CODE_VERSION server-bootstrap
```

## VS Code extensions are pending

A new host does not have VS Code Server until the first Remote-SSH connection.
Connect once, open an integrated terminal, and either allow the generated
background hook to run or execute:

```bash
server-vscode-extensions
```

Then reload the Remote-SSH window.

## One or more VS Code extensions failed

The helper continues through the full manifest and logs failed IDs under:

```text
/workspace/startup-logs/vscode-extensions-*.log
```

Retry later with `server-vscode-extensions`. Use `--strict` when you want a nonzero
exit if any Marketplace item cannot be installed. An extension may have been
removed, renamed, made incompatible with the server architecture, or may need a
later VS Code Server release.

## Node.js checksum mismatch

Do not bypass it. Confirm that `NODE_VERSION` and the architecture-specific
checksum belong to the same official Node.js release. The defaults cover Linux
x64 and ARM64. Unsupported architectures fail explicitly.

## ngrok download or checksum failure

ngrok is part of every bootstrap run, so a failed download stops the bootstrap.
The host needs HTTPS access to `ngrok-agent.s3.amazonaws.com`. Do not bypass a
checksum mismatch: confirm that `NGROK_VERSION` and the architecture-specific
checksum name the same package in ngrok's `Packages` index. A failed attempt
leaves any previously installed `/usr/local/bin/ngrok` untouched. Only x86-64
and ARM64 are supported; other architectures fail explicitly.

## Provisioning stopped before workloads

Read:

```bash
cat /workspace/startup-logs/latest-provision-summary.txt
```

An acceptance rejection intentionally stops before workload bundles. Review the
`server-accept` findings. When the host does not meet its declared
specification, correct or replace it before you rerun provisioning.

## Checksum mismatch for a workload bundle

Confirm that the archive and `.sha256` file belong to the same release. Failed
archives are retained, so replacing the incorrect file and rerunning is enough.

## Same version, different hash

This usually means an archive was rebuilt without a version change. Prefer a
new version. Use `server-bundle-install --force` only after intentionally reviewing
the changed artifact.


## `server-bundle-install` says required arguments are missing

That command is a generic installer for a separate verified add-on; it is not the
next stage of `server-bootstrap`. Running it with no arguments intentionally
prints usage. To continue or retry the server setup, run:

```bash
sudo server-bootstrap
```

or rerun `server-bootstrap.sh` from the extracted release directory.

## Bootstrap stopped on `command -v fd`

Version 1.3.0 had an idempotence bug in the Debian/Ubuntu `fdfind` to `fd`
compatibility-link step. Version 1.3.1 replaces the conditional chain with an
explicit helper that succeeds when the alias already exists and safely warns when
the source command is unavailable. Upgrade to 1.3.1 and rerun the bootstrap.

## Bootstrap says the host is unsupported

`server-provision.sh` and `server-bootstrap.sh` run only on Ubuntu 24.04, on
x86-64 (`amd64`) or ARM64 (`arm64`). On any other release, distribution, or
architecture, or when `dpkg --print-architecture` does not match `uname -m`,
both stop before they create the workspace, a log file, or a lock, and before
apt runs. Nothing needs cleaning up; use a supported host. A
`server-provision.sh --dry-run` preview still works anywhere.

## Bootstrap refused an apt transaction that changes NVIDIA or CUDA packages

The bootstrap does not change an installed NVIDIA driver or CUDA package
([CONFIGURATION](CONFIGURATION.md#nvidia-driver-and-cuda-packages)). The warning
names the packages and the transaction. See the plan for yourself with, for
example:

```bash
apt-get -s -f install
apt-get -s upgrade
```

Bring the driver or CUDA packages to a consistent state yourself, or set
`RUN_APT_UPGRADE=0`, then rerun the bootstrap. A refused `[required]` package or
upgrade fails the run; a refused repair or `[optional]` package only warns.

## A required package could not be installed

The run fails with `required packages could not be installed:` followed by the
names. Every other required package has already been installed. Check the
package sources with `apt-get update` and `apt-cache policy NAME`, or move the
name to `[optional]`, drop it with `SKIP_PACKAGES`, and rerun.

## apt or dpkg is locked

The bootstrap waits for existing package operations and attempts interrupted
`dpkg` recovery. If the timeout is reached, identify the holder with:

```bash
fuser /var/lib/dpkg/lock-frontend
```

## CI fails with `release-files: stale hash`

The tracked files are the canonical release set, and `checksums/SHA256SUMS`
records a hash for each one. Change a tracked file without regenerating the
manifest and `release-files verify` fails — correctly. Three of the four CI jobs
go red, because two of them run the same suite through
`tools/release-preflight.sh`.

This is the normal state of a fresh Dependabot pull request: it bumps a pinned
action SHA inside `.github/workflows/*.yml`, which are tracked and therefore
covered by the manifest, and it has no way to run a repository command.

**It is not an incompatibility in the change under review.** One command fixes
it, from the pull request's branch:

```bash
bash release/release-files.sh write
```

Then commit `checksums/SHA256SUMS` alone. Nothing else needs to change.

To see the exact patch before committing, run:

```bash
bash tools/manifest-fix-hint.sh
```

It prints the failing entries, the command above, and the diff that command
produces, then restores the file — it never commits, pushes, or leaves the
working tree modified. CI runs the same script automatically when a job fails,
so the patch is already in the run log.

Applying it stays a deliberate maintainer action: no workflow here has write
access to repository contents outside the tag-triggered release job.
