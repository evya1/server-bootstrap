#!/usr/bin/env bash
# Exact pin consistency across every file that records a pinned value.
#
#   tools/check-pins.sh          check this repository
#   tools/check-pins.sh ROOT     check a copy of the pin surfaces in ROOT
#
# lib/bootstrap/config.sh is the canonical source. Every other surface --
# config.example.env, checksums/*.txt, README.md, docs/CONFIGURATION.md -- is a
# second recording of the same value, and tools/refresh-pins.sh --write writes
# all of them. This asserts that each recording is present exactly once, is
# well formed, and equals the canonical value, with every architecture anchored
# to its own label so an x64/arm64 swap fails instead of passing.
#
# Not a security boundary: anyone who can edit config.sh can edit this file. A
# wrong checksum makes the download fail closed at install time. This is the
# thing that makes a wrong or half-applied pin visible in CI rather than only in
# a diff nobody reads closely.
#
# Exit: 0 clean, 1 drift, 2 usage.
set -Eeuo pipefail

case "${1:-}" in
    -h|--help) sed -n '2,8p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
esac
(( $# <= 1 )) || { echo "usage: $0 [ROOT]" >&2; exit 2; }

ROOT="${1:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)}"
[[ -d "$ROOT" ]] || { echo "check-pins: not a directory: $ROOT" >&2; exit 2; }

SB_PIN_ROOT="$ROOT" python3 - <<'PY'
import os
import pathlib
import re
import sys

root = pathlib.Path(os.environ["SB_PIN_ROOT"])

CONFIG = "lib/bootstrap/config.sh"

# pin | file | regex with exactly one capture group, which must match exactly
# once in that file.
#
# Every architecture is anchored to its own label -- ^linux-x64 cannot match a
# linux-arm64 line, ^GH_SHA256_X64= cannot match the ARM64 assignment -- so
# swapping two values makes both rows mismatch. That is the case a substring
# search cannot see, and the reason this table is written out rather than
# generated from a "does the value appear anywhere" search.
MAP = [
    # --- canonical: lib/bootstrap/config.sh --------------------------------
    # The shapes are asserted here, so a truncated or non-hex value fails as
    # "missing or malformed" rather than becoming the canonical value that
    # every other surface is then checked against.
    ("NODE_VERSION",        CONFIG, r'^\s*NODE_VERSION="\$\{NODE_VERSION:-(\d+\.\d+\.\d+)\}"$'),
    ("NODE_SHA256_X64",     CONFIG, r'^\s*NODE_SHA256_X64="\$\{NODE_SHA256_X64:-([0-9a-f]{64})\}"$'),
    ("NODE_SHA256_ARM64",   CONFIG, r'^\s*NODE_SHA256_ARM64="\$\{NODE_SHA256_ARM64:-([0-9a-f]{64})\}"$'),
    ("GH_VERSION",          CONFIG, r'^\s*GH_VERSION="\$\{GH_VERSION:-(\d+\.\d+\.\d+)\}"$'),
    ("GH_SHA256_X64",       CONFIG, r'^\s*GH_SHA256_X64="\$\{GH_SHA256_X64:-([0-9a-f]{64})\}"$'),
    ("GH_SHA256_ARM64",     CONFIG, r'^\s*GH_SHA256_ARM64="\$\{GH_SHA256_ARM64:-([0-9a-f]{64})\}"$'),
    ("UV_VERSION",          CONFIG, r'^\s*UV_VERSION="\$\{UV_VERSION:-(\d+\.\d+\.\d+)\}"$'),
    ("UV_SHA256_X64",       CONFIG, r'^\s*UV_SHA256_X64="\$\{UV_SHA256_X64:-([0-9a-f]{64})\}"$'),
    ("UV_SHA256_ARM64",     CONFIG, r'^\s*UV_SHA256_ARM64="\$\{UV_SHA256_ARM64:-([0-9a-f]{64})\}"$'),
    ("OH_MY_ZSH_REF",       CONFIG, r'^\s*OH_MY_ZSH_REF="\$\{OH_MY_ZSH_REF:-([0-9a-f]{40})\}"$'),
    ("CLAUDE_CODE_VERSION", CONFIG, r'^\s*CLAUDE_CODE_VERSION="\$\{CLAUDE_CODE_VERSION:-(\d+\.\d+\.\d+)\}"$'),
    ("CODEX_VERSION",       CONFIG, r'^\s*CODEX_VERSION="\$\{CODEX_VERSION:-(\d+\.\d+\.\d+)\}"$'),
    ("PI_VERSION",          CONFIG, r'^\s*PI_VERSION="\$\{PI_VERSION:-(\d+\.\d+\.\d+)\}"$'),

    # --- config.example.env -------------------------------------------------
    # Exactly one leading "# " distinguishes the commented default from the
    # "#   NODE_VERSION=latest" lines in the tracking-upstream block above it.
    ("NODE_VERSION",        "config.example.env", r'^# NODE_VERSION=(\d+\.\d+\.\d+)$'),
    ("NODE_SHA256_X64",     "config.example.env", r'^# NODE_SHA256_X64=([0-9a-f]{64})$'),
    ("NODE_SHA256_ARM64",   "config.example.env", r'^# NODE_SHA256_ARM64=([0-9a-f]{64})$'),
    ("GH_VERSION",          "config.example.env", r'^# GH_VERSION=(\d+\.\d+\.\d+)$'),
    ("GH_SHA256_X64",       "config.example.env", r'^# GH_SHA256_X64=([0-9a-f]{64})$'),
    ("GH_SHA256_ARM64",     "config.example.env", r'^# GH_SHA256_ARM64=([0-9a-f]{64})$'),
    ("UV_VERSION",          "config.example.env", r'^# UV_VERSION=(\d+\.\d+\.\d+)$'),
    ("UV_SHA256_X64",       "config.example.env", r'^# UV_SHA256_X64=([0-9a-f]{64})$'),
    ("UV_SHA256_ARM64",     "config.example.env", r'^# UV_SHA256_ARM64=([0-9a-f]{64})$'),
    ("OH_MY_ZSH_REF",       "config.example.env", r'^# OH_MY_ZSH_REF=([0-9a-f]{40})$'),
    ("CLAUDE_CODE_VERSION", "config.example.env", r'^# CLAUDE_CODE_VERSION=(\d+\.\d+\.\d+)$'),
    ("CODEX_VERSION",       "config.example.env", r'^# CODEX_VERSION=(\d+\.\d+\.\d+)$'),
    ("PI_VERSION",          "config.example.env", r'^# PI_VERSION=(\d+\.\d+\.\d+)$'),

    # --- checksums/ manifests -----------------------------------------------
    ("NODE_VERSION",      "checksums/NODE_SHA256.txt", r'^Node\.js (\d+\.\d+\.\d+) official release checksums:$'),
    ("NODE_VERSION",      "checksums/NODE_SHA256.txt", r'^Source: https://nodejs\.org/en/blog/release/v(\d+\.\d+\.\d+)$'),
    ("NODE_SHA256_X64",   "checksums/NODE_SHA256.txt", r'^linux-x64 +([0-9a-f]{64})$'),
    ("NODE_SHA256_ARM64", "checksums/NODE_SHA256.txt", r'^linux-arm64 +([0-9a-f]{64})$'),

    # Both occurrences of the version on the Assets line are anchored, so a
    # half-applied edit to that line fails.
    ("GH_VERSION",      "checksums/GH_SHA256.txt", r'^# Assets: gh_(\d+\.\d+\.\d+)_linux_amd64\.tar\.gz / gh_[\d.]+_linux_arm64\.tar\.gz$'),
    ("GH_VERSION",      "checksums/GH_SHA256.txt", r'^# Assets: gh_[\d.]+_linux_amd64\.tar\.gz / gh_(\d+\.\d+\.\d+)_linux_arm64\.tar\.gz$'),
    ("GH_VERSION",      "checksums/GH_SHA256.txt", r'^# Source: https://github\.com/cli/cli/releases/download/v(\d+\.\d+\.\d+)/gh_[\d.]+_checksums\.txt$'),
    ("GH_VERSION",      "checksums/GH_SHA256.txt", r'^# Source: https://github\.com/cli/cli/releases/download/v[\d.]+/gh_(\d+\.\d+\.\d+)_checksums\.txt$'),
    ("GH_SHA256_X64",   "checksums/GH_SHA256.txt", r'^linux-amd64 +([0-9a-f]{64})$'),
    ("GH_SHA256_ARM64", "checksums/GH_SHA256.txt", r'^linux-arm64 +([0-9a-f]{64})$'),

    ("UV_VERSION",      "checksums/UV_SHA256.txt", r'^# Source: https://github\.com/astral-sh/uv/releases/download/(\d+\.\d+\.\d+)/$'),
    ("UV_SHA256_X64",   "checksums/UV_SHA256.txt", r'^x86_64-unknown-linux-gnu +([0-9a-f]{64})$'),
    ("UV_SHA256_ARM64", "checksums/UV_SHA256.txt", r'^aarch64-unknown-linux-gnu +([0-9a-f]{64})$'),

    ("OH_MY_ZSH_REF",   "checksums/OH_MY_ZSH_REF.txt", r'^([0-9a-f]{40})$'),

    ("CLAUDE_CODE_VERSION", "checksums/AI_CLI_VERSIONS.txt", r'^@anthropic-ai/claude-code (\d+\.\d+\.\d+)$'),
    ("CODEX_VERSION",       "checksums/AI_CLI_VERSIONS.txt", r'^@openai/codex (\d+\.\d+\.\d+)$'),
    ("PI_VERSION",          "checksums/AI_CLI_VERSIONS.txt", r'^@earendil-works/pi-coding-agent (\d+\.\d+\.\d+)$'),

    # --- documentation literals, kept exact for reproducibility -------------
    # README.md's "What the run installs" table. \b on the left keeps "pi" from
    # matching inside "api"; the right-hand side is bounded so a README claiming
    # "pi 0.85.10" cannot satisfy a pinned "pi 0.85.1".
    ("GH_VERSION",          "README.md", r'\bGitHub CLI (\d+\.\d+\.\d+)(?![\d.])'),
    ("NODE_VERSION",        "README.md", r'\bNode\.js (\d+\.\d+\.\d+)(?![\d.])'),
    ("CLAUDE_CODE_VERSION", "README.md", r'\bClaude Code (\d+\.\d+\.\d+)(?![\d.])'),
    ("CODEX_VERSION",       "README.md", r'\bOpenAI Codex (\d+\.\d+\.\d+)(?![\d.])'),
    ("PI_VERSION",          "README.md", r'\bpi (\d+\.\d+\.\d+)(?![\d.])'),

    # docs/CONFIGURATION.md repeats nine of them as literal env blocks. Before
    # this table existed refresh-pins.sh did not rewrite that file, and two of
    # them had already gone stale by two releases.
    ("GH_VERSION",          "docs/CONFIGURATION.md", r'^GH_VERSION=(\d+\.\d+\.\d+)$'),
    ("GH_SHA256_X64",       "docs/CONFIGURATION.md", r'^GH_SHA256_X64=([0-9a-f]{64})$'),
    ("GH_SHA256_ARM64",     "docs/CONFIGURATION.md", r'^GH_SHA256_ARM64=([0-9a-f]{64})$'),
    ("NODE_VERSION",        "docs/CONFIGURATION.md", r'^NODE_VERSION=(\d+\.\d+\.\d+)$'),
    ("NODE_VERSION",        "docs/CONFIGURATION.md", r'\bNode\.js (\d+\.\d+\.\d+) LTS binary archive\b'),
    ("NODE_SHA256_X64",     "docs/CONFIGURATION.md", r'^NODE_SHA256_X64=([0-9a-f]{64})$'),
    ("NODE_SHA256_ARM64",   "docs/CONFIGURATION.md", r'^NODE_SHA256_ARM64=([0-9a-f]{64})$'),
    ("CLAUDE_CODE_VERSION", "docs/CONFIGURATION.md", r'^CLAUDE_CODE_VERSION=(\d+\.\d+\.\d+)$'),
    ("CODEX_VERSION",       "docs/CONFIGURATION.md", r'^CODEX_VERSION=(\d+\.\d+\.\d+)$'),
    ("PI_VERSION",          "docs/CONFIGURATION.md", r'^PI_VERSION=(\d+\.\d+\.\d+)$'),
    ("OH_MY_ZSH_REF",       "docs/CONFIGURATION.md", r'^OH_MY_ZSH_REF=([0-9a-f]{40})$'),
]

# Example plans are read by server-provision.sh, which sources them and then
# runs the bootstrap as a child process -- so an exported pin in a plan beats
# the bundle default. Both shipped plans used to override uv, and both went two
# releases stale, which meant the documented quick start installed an older uv
# than the bundle pins. A plan may not carry a pin unless it is listed here.
#
# Adding an entry is deliberate: it needs a reason in the plan, its own MAP rows
# so the value is checked, and refresh-pins.sh support so a bump reaches it.
PLAN_GLOB = "examples/provision-plan*.sh"
PLAN_OVERRIDES_ALLOWED: dict[str, str] = {}

MAX_FINDINGS = 20

findings = []


def report(message: str) -> None:
    findings.append(message)


def read(rel: str) -> str | None:
    path = root / rel
    if not path.is_file():
        return None
    return path.read_text()


# ---------------------------------------------------------------------------
# Canonical values, read out of config.sh by pattern rather than by sourcing it:
# an ambient CLAUDE_CODE_VERSION in a maintainer's shell must not be mistaken
# for what the repository pins. tools/refresh-pins.sh reads it the same way.
# ---------------------------------------------------------------------------
config_text = read(CONFIG)
if config_text is None:
    print(f"check-pins: missing surface file: {CONFIG}", file=sys.stderr)
    raise SystemExit(2)

canonical: dict[str, str] = {}
for pin, rel, pattern in MAP:
    if rel != CONFIG:
        continue
    matches = re.findall(pattern, config_text, re.M)
    if len(matches) == 1:
        canonical[pin] = matches[0]
    elif not matches:
        report(f"missing or malformed: {pin} in {CONFIG}")
    else:
        report(f"duplicate: {pin} appears {len(matches)} times in {CONFIG}")

# ---------------------------------------------------------------------------
# Every mapped recording matches the canonical value exactly once.
# ---------------------------------------------------------------------------
seen_files = sorted({rel for _, rel, _ in MAP})
missing_files = set()
for rel in seen_files:
    if read(rel) is None:
        report(f"missing surface file: {rel}")
        missing_files.add(rel)

claimed: set[tuple[str, str]] = set()
for pin, rel, pattern in MAP:
    claimed.add((pin, rel))
    if rel == CONFIG or rel in missing_files:
        continue
    if pin not in canonical:
        continue  # already reported against config.sh
    text = read(rel) or ""
    matches = re.findall(pattern, text, re.M)
    if not matches:
        report(f"missing or malformed: {pin} in {rel}")
    elif len(matches) > 1:
        report(f"duplicate: {pin} appears {len(matches)} times in {rel}")
    elif matches[0] != canonical[pin]:
        report(
            f"mismatch: {rel} records {matches[0]} for {pin}, "
            f"{CONFIG} pins {canonical[pin]}"
        )

# ---------------------------------------------------------------------------
# Nothing pinned may hide from the table.
# ---------------------------------------------------------------------------
# Every pin default declared in config.sh needs at least one row, so a new
# pinned tool cannot be added without being mapped.
declared = re.findall(
    r'^\s*([A-Z0-9_]*(?:_VERSION|_SHA256(?:_X64|_ARM64)?)|OH_MY_ZSH_REF)="\$\{\1:-([^}]*)\}"',
    config_text,
    re.M,
)
for name, value in declared:
    if name in ("UV_SHA256", "OH_MY_ZSH_SHA256", "ADDON_SHA256", "ADDON_VERSION"):
        continue  # opt-in overrides, empty by default and not pins
    if name not in canonical and not any(p == name for p, r, _ in MAP if r == CONFIG):
        report(f"unmapped pin: {name} is declared in {CONFIG} but no row checks it")

# If a surface mentions a canonical value at all, a row must claim it. This is
# what stops a row being deleted: the value stays in the file, unclaimed.
for rel in seen_files:
    if rel == CONFIG or rel in missing_files:
        continue
    text = read(rel) or ""
    for pin, value in canonical.items():
        if value and value in text and (pin, rel) not in claimed:
            report(f"unclaimed: {rel} records the {pin} value but no row checks it")

# Every hash in checksums/ must belong to a pin mapped to that file, so an extra
# architecture line cannot be added without being checked.
for rel in seen_files:
    if not rel.startswith("checksums/") or rel in missing_files:
        continue
    known = {canonical[p] for p, r, _ in MAP if r == rel and p in canonical}
    for token in re.findall(r'\b[0-9a-f]{40}\b|\b[0-9a-f]{64}\b', read(rel) or ""):
        if token not in known:
            report(f"unclaimed hash in {rel}: no pin in {CONFIG} has that value")

# ---------------------------------------------------------------------------
# Example plans inherit the bundle defaults.
# ---------------------------------------------------------------------------
pin_names = sorted({p for p, _, _ in MAP})
plan_assignment = re.compile(
    r'^\s*(?:export\s+)?(%s)=' % "|".join(re.escape(n) for n in pin_names), re.M
)
for plan in sorted(root.glob(PLAN_GLOB)):
    rel = plan.relative_to(root).as_posix()
    for name in plan_assignment.findall(plan.read_text()):
        if name in PLAN_OVERRIDES_ALLOWED:
            continue
        report(
            f"unlabelled pin override: {rel} sets {name}, "
            f"which overrides the bundle default"
        )

# ---------------------------------------------------------------------------
if findings:
    for line in findings[:MAX_FINDINGS]:
        print(f"check-pins: {line}", file=sys.stderr)
    if len(findings) > MAX_FINDINGS:
        print(
            f"check-pins: ... and {len(findings) - MAX_FINDINGS} more",
            file=sys.stderr,
        )
    print(f"\ncheck-pins: {len(findings)} finding(s) in {root}", file=sys.stderr)
    raise SystemExit(1)

print(f"check-pins: clean ({len(MAP)} recordings of {len(canonical)} pins in {root})")
PY
