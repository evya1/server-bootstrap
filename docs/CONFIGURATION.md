# Configuration

All bootstrap settings are environment variables. A provision plan is the most
convenient place to export them.

## Common bootstrap settings

| Variable | Default | Meaning |
|---|---:|---|
| `WORKSPACE_ROOT` | `/workspace` | workspace root |
| `RUN_APT_UPGRADE` | `0` | run full apt upgrade |
| `INSTALL_ZSH` | `1` | configure Zsh and set it as root's login shell |
| `INSTALL_OH_MY_ZSH` | `1` | install and load pinned Oh My Zsh |
| `INSTALL_NODEJS` | `1` | install checksum-verified Node.js LTS |
| `INSTALL_CLAUDE_CODE` | `1` | install the pinned Claude Code CLI |
| `INSTALL_CODEX` | `1` | install the pinned OpenAI Codex CLI |
| `INSTALL_VSCODE_EXTENSIONS` | `1` | install or queue the Remote-SSH extension manifest |
| `INSTALL_UV` | `1` | install pinned, checksum-verified uv |
| `INSTALL_BASE_PYTHON_ENV` | `1` | create isolated base Python environment |
| `BASE_PYTHON_PACKAGES` | `numpy` | packages installed in that environment |
| `RUN_ACCEPT_TEST` | `1` | bootstrap-local acceptance; provisioner runs it separately |

## Node.js and coding-agent CLIs

The release installs the official Node.js 24.18.0 LTS binary archive and checks
the architecture-specific SHA-256 before extraction:

```bash
NODE_VERSION=24.18.0
NODE_SHA256_X64=55aa7153f9d88f28d765fcdad5ae6945b5c0f98a36881703817e4c450fa76742
NODE_SHA256_ARM64=58c9520501f6ae2b52d5b210444e24b9d0c029a58c5011b797bc1fe7105886f6
NODE_INSTALL_ROOT=/opt/nodejs
```

The stable symlink is `/opt/nodejs/current`; `node`, `npm`, `npx`, and
`corepack` are exposed through `/usr/local/bin`.

Claude Code and Codex are installed at exact npm versions into an isolated
system prefix:

```bash
AI_CLI_PREFIX=/opt/gpu-ai-cli
NPM_REGISTRY=https://registry.npmjs.org/
CLAUDE_CODE_VERSION=2.1.216
CLAUDE_CODE_DISABLE_AUTOUPDATER=1
CODEX_VERSION=0.145.0
```

The bootstrap invokes npm directly while already running as root; it does not
run `sudo npm`. Package versions are verified from their installed
`package.json` files, and the resulting `claude` and `codex` launchers are
linked into `/usr/local/bin`. Claude Code automatic updates are disabled by the generated launcher by default so rerunning the bundle remains the version-control mechanism. Set `CLAUDE_CODE_DISABLE_AUTOUPDATER=0` to allow Claude Code to manage its own updates.

Set either install flag to `0` to omit that CLI. If Node installation is
disabled while an AI CLI is enabled, a usable preinstalled `node` and `npm` are
required.

Authentication is intentionally interactive and is never stored in the bundle:

```bash
claude
codex
```

## VS Code Remote-SSH extensions

The default manifest is:

```text
config/vscode-extensions.txt
```

It contains the 49 extension IDs requested for the SSH host. Configure with:

```bash
INSTALL_VSCODE_EXTENSIONS=1
VSCODE_EXTENSIONS_FILE=/path/to/custom-manifest.txt
VSCODE_EXTENSIONS_STRICT=0
VSCODE_EXTENSIONS_AUTO_RETRY_SECONDS=21600
```

The helper searches for `code`, `code-insiders`, and installed VS Code Server
remote CLIs. Existing extensions are skipped. Every missing extension is
attempted even if an earlier one fails. With strict mode disabled, failures are
reported and can be retried later:

```bash
gpu-vscode-extensions
```

If VS Code Server does not exist during bootstrap, the result is marked pending.
The generated Zsh configuration starts `gpu-vscode-extensions --auto` in the
background on a VS Code integrated-terminal startup. Automatic attempts are
rate-limited and stop after the full manifest succeeds.

## Zsh and Oh My Zsh

The default run installs the Ubuntu `zsh` package, ensures the executable is
listed in `/etc/shells`, and sets it as root's login shell. It generates:

```text
/root/.zshrc
/root/.config/zsh/bootstrap-init.zsh
/root/.config/zsh/server-common.zsh
```

The common aliases include `alias c='clear'`. The generated init file loads Oh
My Zsh first and then the server aliases, so the bundle aliases take precedence.
Reconnect after installation, or run `exec zsh -l`.

Oh My Zsh is pinned by default:

```bash
OH_MY_ZSH_REF=677a4592b18c08ddea737f8aca70bac0e9fc9313
OH_MY_ZSH_SHA256=
OH_MY_ZSH_THEME=robbyrussell
OH_MY_ZSH_PLUGINS=git
```

With an empty archive checksum, the bootstrap fetches only the exact commit and
verifies Git `HEAD`. Automatic Oh My Zsh updates are disabled because the
bootstrap owns the pinned revision.

## uv and base Python

The release pins both `UV_VERSION` and its matching x86_64 Linux archive
checksum. A mismatched checksum aborts, and the bootstrap never falls back to a
remote installer script. The base Python environment can be created with
`python -m venv` when uv is disabled.

## Legacy one-add-on interface

`INSTALL_ADDON` and the existing `ADDON_*` variables remain accepted. They use
the same shared bundle engine as `gpu-bundle-install` and execute after GPU
acceptance. New setups should prefer a provision plan.
