# Changelog

## 1.4.0

- First public release.
- Fixed `gpu-provision.sh --dry-run` performing side effects before it printed anything: it created the log directory, opened a log file, and took the lock, so previewing a plan both wrote to `/workspace` and required root. A dry run is now read-only and works unprivileged. Caught by running the suite in CI, which is unprivileged; every local run had been as root.
- Trimmed the VS Code Remote-SSH manifest to 49 extensions, dropping two entries that were specific to the original author's environment rather than generally useful. Override `VSCODE_EXTENSIONS_FILE` to install your own manifest instead.
- Corrected stale `1.3.1` version headers in `config.example.env`, `checksums/OH_MY_ZSH_REF.txt`, and `checksums/UV_SHA256.txt`, which had drifted because they are neither Markdown nor shell files and were missed by the previous release bump.
- Added a version-drift fitness test so a shipped file can no longer advertise a version that disagrees with `VERSION`.
- Added `.gitignore`, `.gitattributes`, an MIT `LICENSE`, and GitHub Actions workflows for tests and tag-triggered releases.

## 1.3.2

- Fixed an `unbound variable` crash in AI CLI version verification: `bootstrap_verify_npm_package_version` referenced `$package` while it was still being assigned in the same `local` statement, so the compound word expansion saw it as unset under `set -u`. The assignment is now split into two statements.
- Fixed `gpu-accept.sh` disk-speed detection on fast NVMe: the write-throughput regex only matched `MB/s`, so a `dd` result reported in `GB/s` (or `kB/s`) made the parsing pipeline fail under `pipefail`, silently aborting acceptance before it reached a verdict and surfacing as a false hard REJECT even when every check passed. Disk speed is now parsed and normalized from kB/s, MB/s, or GB/s.

## 1.3.1

- Fixed an idempotence failure in Debian/Ubuntu command compatibility links: an existing `fd` or `bat` command no longer makes the package phase return nonzero.
- Added an explicit, testable `bootstrap_ensure_command_alias` helper for `fdfind` → `fd` and `batcat` → `bat`.
- Added behavioral regression tests for first creation, reruns, and unavailable source commands.
- Clarified that `gpu-bundle-install` is an argument-requiring add-on helper, not a continuation command for the main bootstrap.

## 1.3.0

- Added checksum-verified Node.js 24.18.0 LTS installation for Linux x64 and ARM64.
- Added exact-version Claude Code 2.1.216 and OpenAI Codex CLI 0.145.0 installation in an isolated npm prefix.
- Added the requested 51-extension VS Code Remote-SSH manifest and the persistent `gpu-vscode-extensions` installer.
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
- Added `gpu-provision.sh` for ordered local installation of the bootstrap and
  any number of workload or configuration archives.
- Added `gpu-bundle-install`, the single reusable verified bundle installer.
- Moved GPU acceptance before every workload installation.
- Added archive deletion only after successful installation and state recording.
- Added version+archive-hash state, legacy add-on state migration, dry-run, and
  explicit acceptance policies.
- Replaced remote Oh My Zsh installer execution with optional verified archive
  installation; the feature is now off by default.
- Added scoped documentation and provision-plan examples.

## 1.1.0

- Added `gpu-accept.sh` and fail-closed uv checksum configuration.
