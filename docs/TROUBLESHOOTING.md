# Troubleshooting

## Claude or Codex is installed but asks for login

That is expected. Authentication is user-specific and is not placed in the
bundle. Run `claude` or `codex` interactively and follow the browser/device flow.

## `claude` or `codex` is missing

Check the pinned installation and launchers:

```bash
node --version
npm --version
ls -l /opt/gpu-ai-cli/bin /usr/local/bin/claude /usr/local/bin/codex
cat /workspace/.setup-state/claude-code-version
cat /workspace/.setup-state/codex-version
```

Rerun `gpu-server-bootstrap`. A failed exact-version npm install stops the
bootstrap rather than silently using another version.

## VS Code extensions are pending

A new host does not have VS Code Server until the first Remote-SSH connection.
Connect once, open an integrated terminal, and either allow the generated
background hook to run or execute:

```bash
gpu-vscode-extensions
```

Then reload the Remote-SSH window.

## One or more VS Code extensions failed

The helper continues through the full manifest and logs failed IDs under:

```text
/workspace/startup-logs/vscode-extensions-*.log
```

Retry later with `gpu-vscode-extensions`. Use `--strict` when you want a nonzero
exit if any Marketplace item cannot be installed. An extension may have been
removed, renamed, made incompatible with the server architecture, or may need a
later VS Code Server release.

## Node.js checksum mismatch

Do not bypass it. Confirm that `NODE_VERSION` and the architecture-specific
checksum belong to the same official Node.js release. The defaults cover Linux
x64 and ARM64. Unsupported architectures fail explicitly.

## Provisioning stopped before workloads

Read:

```bash
cat /workspace/startup-logs/latest-provision-summary.txt
```

A GPU rejection intentionally stops before workload bundles. Review the
`gpu-accept` findings and destroy the rented instance when the advertised
hardware is not present.

## Checksum mismatch for a workload bundle

Confirm that the archive and `.sha256` file belong to the same release. Failed
archives are retained, so replacing the incorrect file and rerunning is enough.

## Same version, different hash

This usually means an archive was rebuilt without a version change. Prefer a
new version. Use `gpu-bundle-install --force` only after intentionally reviewing
the changed artifact.


## `gpu-bundle-install` says required arguments are missing

That command is a generic installer for a separate verified add-on; it is not the
next stage of `gpu-server-bootstrap`. Running it with no arguments intentionally
prints usage. To continue or retry the server setup, run:

```bash
sudo gpu-server-bootstrap
```

or rerun `gpu-server-bootstrap.sh` from the extracted release directory.

## Bootstrap stopped on `command -v fd`

Version 1.3.0 had an idempotence bug in the Debian/Ubuntu `fdfind` to `fd`
compatibility-link step. Version 1.3.1 replaces the conditional chain with an
explicit helper that succeeds when the alias already exists and safely warns when
the source command is unavailable. Upgrade to 1.3.1 and rerun the bootstrap.

## apt or dpkg is locked

The bootstrap waits for existing package operations and attempts interrupted
`dpkg` recovery. If the timeout is reached, identify the holder with:

```bash
fuser /var/lib/dpkg/lock-frontend
```
