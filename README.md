# gpu-server-bootstrap 1.4.0

A modular, workload-neutral foundation for newly rented Ubuntu GPU servers.
It prepares the host, installs persistent provisioning and developer tools,
checks the rented machine, and can then install checksum-verified workload
bundles in a declared order.

## Quick start

Paste this whole block into a freshly rented Ubuntu GPU server, as root:

```bash
V=1.4.0
BASE=https://github.com/evya1/gpu-server-bootstrap/releases/download/v$V
cd /root
wget -q --show-progress \
  "$BASE/gpu-provision.sh" \
  "$BASE/provision-plan.example.sh" \
  "$BASE/gpu-server-bootstrap-$V.tar.gz" \
  "$BASE/gpu-server-bootstrap-$V.tar.gz.sha256"
chmod +x gpu-provision.sh
./gpu-provision.sh --plan ./provision-plan.example.sh
```

That is the whole installation. It verifies the archive checksum, installs the
server foundation, and then checks that the machine you rented is the machine
you paid for. Expect roughly five minutes, most of it `apt`.

Rented GPU hosts hand you a root shell, and `sudo` is often not installed.
Prefix the last command with `sudo` only if you are not root.

Installed by the run:

- Zsh as the login shell, pinned Oh My Zsh, and `alias c='clear'`;
- checksum-verified Node.js 24.18.0 LTS for Linux x64 or ARM64;
- Claude Code 2.1.216 and OpenAI Codex CLI 0.145.0 in an isolated npm prefix;
- the 49 VS Code extensions for the Remote-SSH host;
- uv and an isolated base Python environment;
- a `gpu-accept` report on GPU, PCIe link width, thermals, RAM, CPU, and disk.

Then start the new shell and sign in to the two coding agents, which are
installed but deliberately not authenticated:

```bash
exec zsh -l
claude
codex
```

Nothing else starts on its own: no workload, model download, or public port.

## Which command do I run?

| Goal | Command |
|---|---|
| Provision a fresh server end to end | `./gpu-provision.sh --plan ./provision-plan.example.sh` |
| Re-run or repair the foundation on a box that already has it | `gpu-server-bootstrap` |
| Install one workload bundle later | `gpu-bundle-install --name … --version … --source … --sha256 …` |
| Re-check that the rented box matches spec | `gpu-accept` |
| Install or repair the VS Code extension list | `gpu-vscode-extensions` |

**Never execute a `provision-plan*.sh` file directly.** A plan is a data file,
not a program: it only calls `register_bootstrap` and `register_bundle`, which
exist for as long as `gpu-provision.sh` is reading it. Always pass a plan with
`--plan`. Running one on its own now exits with that reminder.

`gpu-server-bootstrap.sh` inside the archive is the inner foundation installer.
`gpu-provision.sh` verifies the archive, unpacks it, runs that script, runs the
acceptance check, and only then installs workload bundles in plan order — which
is why it, not the inner script, is the entry point on a new machine.

## Adding workload bundles

The shipped `provision-plan.example.sh` installs the foundation only, so it runs
green with nothing else downloaded. To add a workload, put its archive and
`.sha256` beside the plan and uncomment the `register_bundle` block inside it:

```text
gpu-provision.sh
provision-plan.example.sh
gpu-server-bootstrap-1.4.0.tar.gz
gpu-server-bootstrap-1.4.0.tar.gz.sha256
<workload>-<version>.tar.gz
<workload>-<version>.tar.gz.sha256
```

Registering a bundle whose archive is not actually present aborts the run after
the bootstrap has already installed, so add the files first.

The provisioner installs the bootstrap first, runs `gpu-accept`, installs each
registered bundle in order, and deletes local archives only after successful
installation.

## Download integrity

The archive checksum is verified before extraction. Fetching an archive and its
`.sha256` from the same origin establishes integrity, not authenticity: it
detects a truncated or corrupted transfer, but anyone able to publish to the
release can publish both files. The trust anchors are HTTPS, account 2FA, and
pinning the expected SHA-256 in your own provision plan.

There is deliberately no `curl | sh` installer; it would defeat the verified
archive model the rest of this bundle is built on.

`gpu-provision.sh` resolves plan entries as local paths, so the bootstrap
archive must be downloaded first. Workload bundles do not: `gpu-bundle-install`
accepts an `https://` source directly and enforces TLS plus an exact SHA-256.

## Commands

| Command | Purpose |
|---|---|
| `gpu-server-bootstrap` | Prepare or refresh the general server foundation |
| `gpu-provision` | Execute a local multi-bundle provisioning plan |
| `gpu-bundle-install` | Install one verified bundle archive |
| `gpu-accept` | Validate GPU, PCIe, thermals, RAM, CPU, and disk |
| `gpu-vscode-extensions` | Install or repair the Remote-SSH extension manifest |

The release archive also includes `gpu-provision.sh` as a standalone file for
the first run, before the bootstrap has installed any commands.

`gpu-bundle-install` is not a second bootstrap step. It is a generic helper for
an explicitly named, versioned, checksum-verified add-on, so running it without
arguments intentionally prints its usage.

## VS Code Remote-SSH behavior

VS Code Server normally exists only after the first Remote-SSH connection. If
its CLI is already present, the bootstrap installs the extension manifest
immediately. Otherwise it records a pending result. The generated Zsh startup
configuration launches a rate-limited background installation when the first
VS Code integrated terminal opens. You can also run this explicitly:

```bash
gpu-vscode-extensions
```

Reload the Remote-SSH window after a first-time extension installation.

## Interactive shell

The bootstrap installs Zsh, sets it as root's default login shell, installs a
pinned Oh My Zsh revision, and loads it from `/root/.zshrc`. The generated
server aliases include `c` for `clear`. Reconnect after the first bootstrap run,
or run `exec zsh -l`, to enter the new login shell immediately.

## Documentation

- `docs/QUICKSTART.md` — first installation and reruns.
- `docs/PROVISIONING.md` — plan format, ordering, deletion, and policies.
- `docs/ARCHITECTURE.md` — modules and responsibility boundaries.
- `docs/BUNDLE-CONTRACT.md` — requirements for future toolkit archives.
- `docs/CONFIGURATION.md` — bootstrap and acceptance variables.
- `docs/TROUBLESHOOTING.md` — failures and recovery.

## Safety model

- SHA-256 is checked before Node.js or bundle archive extraction.
- Archives with absolute paths, `..` traversal, or escaping symlinks are rejected.
- Remote sources and the npm registry must use HTTPS.
- Node.js, Claude Code, Codex, uv, and Oh My Zsh are version-pinned by the release.
- Oh My Zsh is fetched at an exact commit; no upstream installer script is run.
- AI CLI packages are installed into `/opt/gpu-ai-cli`, not the system npm tree.
- Installation state records versions and completion status.
- Local workload archives and checksum files are removed only after success.
- No workload, model, dataset, or public service is started automatically.
- The bootstrap never installs or replaces the NVIDIA driver.

## Compatibility

The old single-add-on environment variables remain supported by
`gpu-server-bootstrap.sh`. New multi-bundle setups should use a provision plan.
