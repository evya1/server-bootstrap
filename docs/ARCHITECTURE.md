# Architecture

The bootstrap is split by responsibility rather than kept as one large script.

```text
server-bootstrap.sh           orchestration of the base host setup
server-provision.sh           first-run and multi-bundle orchestration
server-bundle-install         one-bundle command-line interface
server-accept.sh              rented-machine validation
server-vscode-extensions      idempotent Remote-SSH extension installer
config/packages.txt           required and optional apt package manifest
config/vscode-extensions.txt  requested extension manifest
lib/core.sh                   logging, retries, checksums, verified downloads
lib/archive.sh                safe gzip/xz tar and zip inspection/extraction
lib/bundle.sh                 generic bundle lifecycle and state
lib/bootstrap/config.sh       configuration defaults
lib/bootstrap/workspace.sh    directories and caches
lib/bootstrap/packages.sh     apt manifest parsing and command aliases
lib/bootstrap/node.sh         pinned, verified Node.js binary installation
lib/bootstrap/ai_cli.sh       isolated Claude Code and Codex npm installation
lib/bootstrap/uv.sh           optional pinned uv installation
lib/bootstrap/github_cli.sh   pinned, verified GitHub CLI binary installation
lib/bootstrap/python.sh       isolated base Python environment
lib/bootstrap/shell.sh        Zsh, Oh My Zsh, aliases, VS Code startup hook
lib/bootstrap/vscode.sh       immediate-or-deferred extension orchestration
lib/bootstrap/runtime.sh      persistent command and manifest installation
lib/bootstrap/report.sh       acceptance policy and system report
```

## Execution order

`server-provision.sh` uses this order:

```text
verify bootstrap archive
→ extract bootstrap safely
→ install server foundation
→ run server-accept
→ install registered bundles in plan order
→ write one provisioning summary
```

`server-bootstrap.sh` itself uses this order:

```text
workspace → apt packages → persistent tools → Node.js → Claude/Codex
→ uv → GitHub CLI → base Python → shell → VS Code extensions
→ acceptance → optional legacy add-on → report → state
```

The acceptance test therefore still runs before every optional workload bundle.
The coding-agent CLIs and editor manifest are treated as part of the reusable
host developer environment, not as a project workload.

## Deferred VS Code installation

Remote-SSH owns the VS Code Server lifecycle, so the bootstrap does not install
a desktop VS Code package or fabricate a server installation. The extension
module uses an existing server CLI when available. Otherwise the persistent
helper and manifest are installed, and the generated Zsh hook invokes the helper
only from a VS Code terminal. A lock, completion marker, and retry interval make
that path idempotent.

## Why the provisioner is partly self-contained

Before the bootstrap is installed, no shared bootstrap library exists on the
server. The standalone provisioner contains only the minimal code needed to
verify and extract the bootstrap archive. Every later workload archive is
handled by the installed shared bundle module, avoiding duplicated installer
logic.
