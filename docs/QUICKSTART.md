# Quick start

## 1. Prepare a directory

Copy the standalone provisioner, one plan, the bootstrap archive, and every
workload archive into the same directory. Keep each `.sha256` sidecar beside its
archive.

## 2. Edit the plan

Start from `examples/provision-plan.example.sh`. Register the bootstrap once,
then register bundles in the exact installation order you want.

## 3. Preview

```bash
sudo ./gpu-provision.sh --plan ./provision-plan.sh --dry-run
```

## 4. Install

```bash
sudo ./gpu-provision.sh --plan ./provision-plan.sh
```

A successful run writes its summary and log under:

```text
/workspace/startup-logs/
```

## 5. Start the shell and authenticate

Open a new SSH session or run:

```bash
exec zsh -l
```

Oh My Zsh and the generated aliases, including `c` for `clear`, load
automatically. Then authenticate the installed coding agents:

```bash
claude
codex
```

The bundle does not embed API keys or account tokens.

## 6. Finish Remote-SSH extension setup

When VS Code Server already existed, the bootstrap attempted the extension list
immediately. On a fresh server, first connect with VS Code Remote-SSH and open an
integrated terminal. The generated Zsh hook starts the installation in the
background. You can run it explicitly and watch the result:

```bash
gpu-vscode-extensions
```

Reload the VS Code window after first-time installation. The manifest is at
`/usr/local/lib/gpu-server-bootstrap/config/vscode-extensions.txt`.

## Reruns

To resume after any corrected or transient bootstrap failure, rerun the main
entrypoint from the extracted archive or run the installed command:

```bash
sudo ./gpu-server-bootstrap.sh
# or, after runtime tools were installed:
sudo gpu-server-bootstrap
```

Do not run `gpu-bundle-install` by itself; it requires the name, version, source,
and checksum of a separate add-on bundle.

The bootstrap is safe to rerun. Node.js and the AI CLI versions are verified,
existing VS Code extensions are skipped, and missing or previously failed
extensions are retried.

For workload bundles, the same version and archive hash are skipped. A newer
version is installed. The same version with a different hash is rejected unless
explicitly forced after review.
