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
| `INSTALL_GITHUB_CLI` | `1` | install pinned, checksum-verified `gh` |
| `INSTALL_BASE_PYTHON_ENV` | `1` | create isolated base Python environment |
| `BASE_PYTHON_PACKAGES` | `numpy` | packages installed in that environment |
| `RUN_ACCEPT_TEST` | `1` | bootstrap-local acceptance; provisioner runs it separately |

## Distribution packages

The apt package set lives in `config/packages.txt` rather than in shell code, so
changing it never means editing a script. The manifest has two sections:

- `[required]` is installed as one apt batch. If the batch fails, each package
  is retried individually so a single unavailable name cannot block the rest.
- `[optional]` is best effort. These are packages whose availability genuinely
  varies across Ubuntu and Debian releases, so a miss is a warning, never a
  failure.

Blank lines, `#` comments, and trailing comments are ignored. Package names are
validated against Debian's naming rules before they reach the apt command line.

| Variable | Default | Meaning |
|---|---:|---|
| `PACKAGES_FILE` | `<root>/config/packages.txt` | manifest to read |
| `EXTRA_PACKAGES` | *(empty)* | space-separated names appended to `[required]` |
| `SKIP_PACKAGES` | *(empty)* | space-separated names removed from both sections |

```bash
EXTRA_PACKAGES="postgresql-client redis-tools"
SKIP_PACKAGES="nmap tcpdump"
```

Tools that are pinned to a checksummed upstream release — Node.js, uv, `gh`,
and the AI CLIs — are deliberately absent from the manifest. Adding one of them
to it would install a second, unpinned copy.

## GitHub CLI

`gh` is installed from its pinned upstream release archive and verified by
SHA-256 per architecture, then linked at `/usr/local/bin/gh` with its man pages:

```bash
GH_VERSION=2.96.0
GH_SHA256_X64=83d5c2ccad5498f58bf6368acb1ab32588cf43ab3a4b1c301bf36328b1c8bd60
GH_SHA256_ARM64=06f86ec7103d41993b76cd78072f43595c34aaa56506d971d9860e67140bf909
```

The distribution package lags upstream by many minor versions and is missing
entirely on older releases, and the vendor's own instructions add a third-party
apt repository plus a signing key — more trust than one verified tarball needs.
Reruns are idempotent: an already-matching `gh --version` short-circuits the
download. Authentication is interactive and never stored in the bundle:

```bash
gh auth login
```

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
AI_CLI_PREFIX=/opt/ai-cli
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
server-vscode-extensions
```

If VS Code Server does not exist during bootstrap, the result is marked pending.
The generated Zsh configuration starts `server-vscode-extensions --auto` in the
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
the same shared bundle engine as `server-bundle-install` and execute after hardware
acceptance. New setups should prefer a provision plan.
