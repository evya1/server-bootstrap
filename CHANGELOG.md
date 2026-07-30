# Changelog

## 2.0.1

- **Fixed a broken command in the README.** The "Which command do I run?"
  table told people to preview a plan with `server-provision.sh --plan …
  --dry-run` after install, but the bootstrap only ever symlinks the bare
  `server-provision` onto `PATH` — running the documented line literally
  failed with `command not found`. Corrected to `server-provision --plan …
  --dry-run`.
- **Added a fitness test** (`tests/run-tests.sh`) that derives the real
  installed-command set from `lib/bootstrap/runtime.sh` and checks every
  `server-*` command named in a README table against it, so a doc/reality
  mismatch like this fails CI instead of shipping silently.

## 2.0.0

Breaking: the project is no longer GPU-specific in name or behaviour. Nothing in
the bootstrap ever installed an NVIDIA driver or CUDA — the GPU framing was
naming around a general-purpose server setup, and it made the tool look
inapplicable to the CPU-only machines it already supported.

- **Renamed every command.** `gpu-server-bootstrap` → `server-bootstrap`,
  `gpu-provision` → `server-provision`, `gpu-bundle-install` →
  `server-bundle-install`, `gpu-accept` → `server-accept`,
  `gpu-vscode-extensions` → `server-vscode-extensions`. No compatibility
  symlinks are installed: the old names are gone. Existing machines should be
  re-bootstrapped from the 2.0.0 archive, which removes
  `/usr/local/lib/gpu-server-bootstrap` only if you delete it by hand — the new
  runtime installs alongside it at `/usr/local/lib/server-bootstrap`.
- **Renamed the shared code prefix** from `gsb_`/`GSB_` to `sb_`/`SB_`, the
  acceptance policy variable from `GPU_ACCEPT_POLICY` to `ACCEPT_POLICY`, the
  reported `gpu_present` field to `accelerator_present`, and the AI CLI prefix
  from `/opt/gpu-ai-cli` to `/opt/ai-cli`. Plans that export `GPU_ACCEPT_POLICY`
  must be updated; the old name is silently ignored.
- **`server-accept` no longer rejects a machine that has no GPU.** CPU, RAM, and
  disk are checked everywhere; the `nvidia-smi` section is skipped with a note
  when no accelerator is present. Previously a CPU-only box was a hard rejection,
  which made the tool unusable on exactly the hosts this release targets. Set
  `REQUIRE_ACCELERATOR=1` to restore the old behaviour when a missing GPU really
  is a failed delivery.
- **Moved the apt package set out of shell code** into `config/packages.txt`,
  which was the only install layer in the project without a configuration knob.
  The manifest has `[required]` and `[optional]` sections; optional packages
  whose availability varies by release now warn instead of being absent with no
  explanation. `EXTRA_PACKAGES` and `SKIP_PACKAGES` adjust it without editing the
  file, and names are validated against Debian's rules before reaching the apt
  command line.
- **Expanded the package set from 41 to 96**, adding network and diagnostic
  tooling (`dnsutils`, `mtr-tiny`, `iperf3`, `tcpdump`, `nmap`, `socat`,
  `speedtest-cli`), shell ergonomics (`fzf`, `zoxide`, `direnv`, `tldr`),
  archive and compression tools (`zstd`, `pigz`, `pv`), the headers needed to
  build Python versions and native wheels, and `sqlite3`, `strace`, `sysstat`,
  `screen`, and `bash-completion`.
- **Added the GitHub CLI** (`gh` 2.96.0) as a pinned, SHA-256-verified upstream
  release rather than an apt package or a third-party apt repository, matching
  how Node.js and uv are already installed. Disable with `INSTALL_GITHUB_CLI=0`.

## 1.4.0

- First public release.
- Fixed `server-provision.sh --dry-run` performing side effects before it printed anything: it created the log directory, opened a log file, and took the lock, so previewing a plan both wrote to `/workspace` and required root. A dry run is now read-only and works unprivileged. Caught by running the suite in CI, which is unprivileged; every local run had been as root.
- Trimmed the VS Code Remote-SSH manifest to 49 extensions, dropping two entries that were specific to the original author's environment rather than generally useful. Override `VSCODE_EXTENSIONS_FILE` to install your own manifest instead.
- Corrected stale `1.3.1` version headers in `config.example.env`, `checksums/OH_MY_ZSH_REF.txt`, and `checksums/UV_SHA256.txt`, which had drifted because they are neither Markdown nor shell files and were missed by the previous release bump.
- Added a version-drift fitness test so a shipped file can no longer advertise a version that disagrees with `VERSION`.
- Added `.gitignore`, `.gitattributes`, an MIT `LICENSE`, and GitHub Actions workflows for tests and tag-triggered releases.

## 1.3.2

- Fixed an `unbound variable` crash in AI CLI version verification: `bootstrap_verify_npm_package_version` referenced `$package` while it was still being assigned in the same `local` statement, so the compound word expansion saw it as unset under `set -u`. The assignment is now split into two statements.
- Fixed `server-accept.sh` disk-speed detection on fast NVMe: the write-throughput regex only matched `MB/s`, so a `dd` result reported in `GB/s` (or `kB/s`) made the parsing pipeline fail under `pipefail`, silently aborting acceptance before it reached a verdict and surfacing as a false hard REJECT even when every check passed. Disk speed is now parsed and normalized from kB/s, MB/s, or GB/s.

## 1.3.1

- Fixed an idempotence failure in Debian/Ubuntu command compatibility links: an existing `fd` or `bat` command no longer makes the package phase return nonzero.
- Added an explicit, testable `bootstrap_ensure_command_alias` helper for `fdfind` → `fd` and `batcat` → `bat`.
- Added behavioral regression tests for first creation, reruns, and unavailable source commands.
- Clarified that `server-bundle-install` is an argument-requiring add-on helper, not a continuation command for the main bootstrap.

## 1.3.0

- Added checksum-verified Node.js 24.18.0 LTS installation for Linux x64 and ARM64.
- Added exact-version Claude Code 2.1.216 and OpenAI Codex CLI 0.145.0 installation in an isolated npm prefix.
- Added the requested 51-extension VS Code Remote-SSH manifest and the persistent `server-vscode-extensions` installer.
- Added immediate installation when VS Code Server already exists and a rate-limited background Zsh hook for the first fresh Remote-SSH terminal.
- Added per-extension continuation, strict mode, retry state, logs, and idempotence tests.
- Added safe `.tar.xz` and `.txz` archive extraction for verified upstream binaries.
- Expanded reports, configuration, quick-start, architecture, and troubleshooting documentation.

## 1.2.1

- Restored Zsh as an explicit default bootstrap feature and strengthened login-shell verification.
- Enabled Oh My Zsh by default at a pinned upstream commit and load it from the generated Zsh startup configuration.
- Preserved and tested the `c` alias for `clear`, loaded after Oh My Zsh so it remains authoritative.
- Added theme/plugin configuration, pinned-reference metadata, and shell setup documentation.

## 1.2.0

- Split the bootstrap into focused modules for configuration, workspace, apt,
  runtime tools, uv, base Python, shell setup, reporting, archives, and bundles.
- Added `server-provision.sh` for ordered local installation of the bootstrap and
  any number of workload or configuration archives.
- Added `server-bundle-install`, the single reusable verified bundle installer.
- Moved GPU acceptance before every workload installation.
- Added archive deletion only after successful installation and state recording.
- Added version+archive-hash state, legacy add-on state migration, dry-run, and
  explicit acceptance policies.
- Replaced remote Oh My Zsh installer execution with optional verified archive
  installation; the feature is now off by default.
- Added scoped documentation and provision-plan examples.

## 1.1.0

- Added `server-accept.sh` and fail-closed uv checksum configuration.
