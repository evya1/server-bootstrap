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
| `INSTALL_PI` | `1` | install the pinned pi coding agent |
| `INSTALL_VSCODE_EXTENSIONS` | `1` | install or queue the Remote-SSH extension manifest |
| `INSTALL_UV` | `1` | install pinned, checksum-verified uv |
| `INSTALL_GITHUB_CLI` | `1` | install pinned, checksum-verified `gh` |
| `INSTALL_BASE_PYTHON_ENV` | `1` | create isolated base Python environment |
| `INSTALL_SECRETS_FILE` | `1` | create the API keys file and its shell loader |
| `INSTALL_PI_MODELS_TEMPLATE` | `1` | seed `models.json` when pi has none |
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

Tools the bootstrap installs at a pinned version — Node.js, uv, `gh`,
and the AI CLIs — are deliberately absent from the manifest. Adding one of them
to it would install a second, unpinned copy.

## GitHub CLI

`gh` is installed from its pinned upstream release archive and verified by
SHA-256 per architecture, then linked at `/usr/local/bin/gh` with its man pages:

```bash
GH_VERSION=2.100.0
GH_SHA256_X64=e4d4bb4498e8d007abe545b6568926793ace1b6447da598294a610018cb164be
GH_SHA256_ARM64=ea4e7a581a32ccad6cc7923cb1576ac5859ba4b9a16ab22eb8f8a96e78e2e961
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

The release installs the official Node.js 24.21.0 LTS binary archive and checks
the architecture-specific SHA-256 before extraction:

```bash
NODE_VERSION=24.21.0
NODE_SHA256_X64=fd8e59d5a511510f6a298afb548f18c7d2b1be404d8b4a27d94fbe49f56cb2d6
NODE_SHA256_ARM64=6ad1325edbdb5649c379b75a237147a666c95d4f9ae8d340fef2d1575d289ad2
NODE_INSTALL_ROOT=/opt/nodejs
```

The stable symlink is `/opt/nodejs/current`; `node`, `npm`, `npx`, and
`corepack` are exposed through `/usr/local/bin`.

Claude Code, Codex and pi are installed at exact npm versions into an isolated
system prefix, in one npm transaction:

```bash
AI_CLI_PREFIX=/opt/ai-cli
NPM_REGISTRY=https://registry.npmjs.org/
CLAUDE_CODE_VERSION=2.1.269
CLAUDE_CODE_DISABLE_AUTOUPDATER=1
CODEX_VERSION=0.154.0
PI_VERSION=0.85.1
```

These are exact-version npm installs. Unlike Node.js, uv and `gh`, no SHA-256
in this repository covers them: their integrity comes from npm and the registry.
What the bootstrap adds is a check that npm installed the version it was asked
for, read back from the installed `package.json`.

The bootstrap invokes npm directly while already running as root; it does not
run `sudo npm`. Package versions are verified from their installed
`package.json` files, and the resulting `claude` and `codex` launchers are
linked into `/usr/local/bin`. Claude Code automatic updates are disabled by the generated launcher by default so rerunning the bundle remains the version-control mechanism. Set `CLAUDE_CODE_DISABLE_AUTOUPDATER=0` to allow Claude Code to manage its own updates.

Set any install flag to `0` to omit that CLI. If Node installation is
disabled while an AI CLI is enabled, a usable preinstalled `node` and `npm` are
required. pi needs Node 22.19 or newer, which the pinned Node satisfies.

pi needs no update wrapper: the generated Zsh configuration exports
`PI_TELEMETRY=0` and `PI_SKIP_VERSION_CHECK=1`, so a release-pinned pi performs
no startup network call of its own.

Authentication is interactive, or comes from the API keys file below:

```bash
claude
codex
pi
```

### pi model configuration

pi ships built-in catalogs for Anthropic, OpenAI, OpenRouter and a dozen more
providers, so `models.json` is needed only for providers it does not know
about — a local vLLM or Ollama server, or a proxy.

```bash
PI_CONFIG_DIR=/root/.pi/agent
INSTALL_PI_MODELS_TEMPLATE=1
PI_MODELS_TEMPLATE=/usr/local/lib/server-bootstrap/examples/pi-models.example.json
```

The template is installed to `$PI_CONFIG_DIR/models.json` **only when that file
does not exist**, so your edits are never replaced. It contains no secret: its
OpenRouter entry uses pi's `"$OPENROUTER_API_KEY"` interpolation, which reads
the value the shell already exported. pi re-reads the file every time you open
`/model`, so an edit needs no restart.

## API keys

One root-owned file holds every provider key, and the generated Zsh startup
configuration loads it into each login shell:

```bash
SECRETS_DIR=/root/.config/server-bootstrap
SECRETS_FILE=/root/.config/server-bootstrap/secrets.env
SECRETS_TEMPLATE=/usr/local/lib/server-bootstrap/examples/secrets.env.example
```

The directory is `0700` and the file is `0600`. It is deliberately not in
`/etc/profile.d`, which is world-readable and applies to every user.

The file is **parsed, never sourced**. Only `NAME=VALUE` lines are accepted, an
optional `export ` prefix and one layer of matching quotes are stripped, and a
name that is not `[A-Za-z_][A-Za-z0-9_]*` is reported and skipped. A backtick
or `$(...)` inside a value is exported literally, not executed. An empty value
is not exported at all, so an untouched placeholder is never mistaken for a
configured credential.

Manage it with `server-secrets`:

| Command | Purpose |
|---|---|
| `server-secrets status` | masked list of every key the file names |
| `server-secrets set NAME` | prompt for one value; nothing reaches shell history |
| `server-secrets edit` | open the file in `$EDITOR`, then recheck permissions |
| `server-secrets check` | exit non-zero when no key is set |
| `server-secrets path` | print the file path |
| `server-secrets init` | create the file from the template if it is missing |

Inside an interactive shell, `aikeys status`, `aikeys off` and `aikeys on`
show, clear and reload the keys. `aikeys off` is what returns `claude` and
`codex` to Claude Pro/Max and ChatGPT subscription login, because both prefer
an API key whenever one is present.

`SERVER_SECRETS_FILE` overrides the path for a single shell or command, which
is what the test suite uses.

## Tracking upstream versions

Every version variable also accepts the literal `latest`:

| Variable | Resolved from |
|---|---|
| `NODE_VERSION` | newest LTS in `nodejs.org/dist/index.json`, then `SHASUMS256.txt` |
| `GH_VERSION` | newest `cli/cli` tag, then `gh_<version>_checksums.txt` |
| `UV_VERSION` | newest `astral-sh/uv` tag, then the `.sha256` sidecar |
| `CLAUDE_CODE_VERSION`, `CODEX_VERSION`, `PI_VERSION` | the npm `latest` dist-tag |
| `OH_MY_ZSH_REF` | current `master` commit, then the existing exact-commit verify |

The download path does not change: the resolved SHA-256 goes through the same
`sb_fetch_verified` gate as a pinned one, and a manifest that yields no valid
hash is a hard failure. What changes is where the expectation comes from — the
publisher's manifest, fetched from the same origin as the artifact. That proves
integrity, not authenticity, so pinned versions stay the default.

Tag discovery uses `git ls-remote`, not `api.github.com`: no rate limit, no
token, and it works from restricted networks.

To refresh the pins themselves rather than resolve at run time:

```bash
tools/refresh-pins.sh            # report drift
tools/refresh-pins.sh --check --all   # also fail on branch-head movement
tools/refresh-pins.sh --write    # rewrite every file that records a pin
tools/check-pins.sh              # assert those files still agree, offline
```

`--write` rewrites every file that records a pinned value: `lib/bootstrap/config.sh`,
`config.example.env`, `checksums/*.txt`, `README.md` and `docs/CONFIGURATION.md`.
`CHANGELOG.md` stays a hand edit, because it records what a bump means. Every
substitution is resolved before any file is written, so a file whose patterns no
longer fit aborts the run before the first write — but the writes themselves are
per file and are not atomic across files: an I/O failure between two of them
leaves the tree partly updated, and the remedy is to rerun.

`--check` exit codes, which automation can rely on:

| Exit | Meaning |
| --- | --- |
| `0` | nothing actionable. Every release pin is `CURRENT`; a branch head that has `MOVED` is reported and tolerated. |
| `1` | a pinned release is `STALE`. With `--all`, a `MOVED` branch head produces this too. |
| `2` | usage error. |
| `3` | nothing actionable was found, but at least one row is `UNKNOWN`, so the answer is not trustworthy. |

`1` outranks `exit 3`: a definitely stale pin is work whether or not another row
failed to resolve. An upstream that cannot be resolved is never reported as
`CURRENT`, and `--write` refuses to write a value it could not resolve.

Node.js, `gh`, uv, Claude Code, Codex and pi resolve to a published release — a
git tag or an npm `dist-tag` — and stay put until upstream cuts a new one. Oh My
Zsh publishes no releases, so its pin tracks `refs/heads/master`, which moves
several times a day. Moving it is a deliberate act: `--write` leaves it alone
unless `--all` is given.

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

plus `/root/.config/zsh/server-secrets.zsh`, which loads the API keys file and
defines `aikeys`.

The common aliases include `alias c='clear'`. The generated init file loads Oh
My Zsh first, then the server aliases, then the keys, so the bundle aliases
take precedence. Reconnect after installation, or run `exec zsh -l`.

Oh My Zsh is pinned by default:

```bash
OH_MY_ZSH_REF=c6e66edee824d83e84473ec666917b58323630df
OH_MY_ZSH_SHA256=
OH_MY_ZSH_THEME=robbyrussell
OH_MY_ZSH_PLUGINS=git
```

With an empty archive checksum, the bootstrap fetches only the exact commit and
verifies Git `HEAD`. Automatic Oh My Zsh updates are disabled because the
bootstrap owns the pinned revision.

## uv and base Python

The release pins `UV_VERSION` and a matching archive checksum per architecture,
`UV_SHA256_X64` and `UV_SHA256_ARM64`. The older single-value `UV_SHA256` is
still accepted and overrides the x86_64 entry. A mismatched checksum aborts,
and the bootstrap never falls back to a remote installer script.

uv is reinstalled when the installed version differs from the pinned one, so a
version bump takes effect on rerun. The base Python environment can be created
with `python -m venv` when uv is disabled.

## Legacy one-add-on interface

`INSTALL_ADDON` and the existing `ADDON_*` variables remain accepted. They use
the same shared bundle engine as `server-bundle-install` and execute after hardware
acceptance. New setups should prefer a provision plan.
