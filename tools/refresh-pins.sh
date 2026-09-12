#!/usr/bin/env bash
# Resolve the current upstream version of every pinned tool and report or apply
# the drift. Run this instead of hand-editing pins across five files.
#
#   tools/refresh-pins.sh            # report drift, exit 1 when stale
#   tools/refresh-pins.sh --write    # apply it
#
# --write rewrites lib/bootstrap/config.sh, config.example.env, checksums/*.txt,
# README.md and docs/CONFIGURATION.md. CHANGELOG.md stays a hand edit.
# tools/check-pins.sh asserts, offline, that those files still agree.
#
# Tag discovery uses git ls-remote rather than api.github.com: no rate limit,
# no token, and it works from restricted networks.
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$ROOT"
# shellcheck source=lib/core.sh
source "$ROOT/lib/core.sh"
SB_LOG_PREFIX=refresh-pins

MODE="check"
case "${1:-}" in
    ''|--check) MODE="check" ;;
    --write) MODE="write" ;;
    -h|--help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "usage: $0 [--check|--write]" >&2; exit 2 ;;
esac

# Read the default baked into config.sh rather than sourcing it: an ambient
# CLAUDE_CODE_VERSION in the maintainer's environment must not be mistaken for
# what the repository pins.
config_default() {
    local name="$1" value
    value="$(sed -n "s|^[[:space:]]*$name=\"\\\${$name:-\(.*\)}\"[[:space:]]*\$|\1|p" \
        "$ROOT/lib/bootstrap/config.sh" | head -n1)"
    [[ -n "$value" ]] || sb_die "no default for $name in lib/bootstrap/config.sh" || return
    printf '%s\n' "$value"
}

NODE_VERSION="$(config_default NODE_VERSION)"
GH_VERSION="$(config_default GH_VERSION)"
UV_VERSION="$(config_default UV_VERSION)"
CLAUDE_CODE_VERSION="$(config_default CLAUDE_CODE_VERSION)"
CODEX_VERSION="$(config_default CODEX_VERSION)"
PI_VERSION="$(config_default PI_VERSION)"
OH_MY_ZSH_REF="$(config_default OH_MY_ZSH_REF)"

npm_latest() {
    local package="$1" encoded
    encoded="${package//\//%2f}"
    sb_retry 3 curl -fsSL --proto '=https' --tlsv1.2 \
        "https://registry.npmjs.org/-/package/$encoded/dist-tags" 2>/dev/null \
        | sed -n 's/.*[{,]"latest":"\([^"]*\)".*/\1/p'
}

node_latest_lts() {
    sb_retry 3 curl -fsSL --proto '=https' --tlsv1.2 https://nodejs.org/dist/index.json 2>/dev/null \
        | tr '{' '\n' | grep -m1 '"lts":"' \
        | sed -n 's/.*"version":"v\([0-9][0-9.]*\)".*/\1/p'
}

# name|current|latest|state, filled in below and consumed twice.
ROWS=()

record() {
    local name="$1" current="$2" latest="$3"
    [[ -n "$latest" ]] || { sb_warn "could not resolve the latest $name"; latest="$current"; }
    local state=current
    [[ "$current" == "$latest" ]] || state=STALE
    ROWS+=("$name|$current|$latest|$state")
    [[ "$state" == STALE ]] && return 0 || return 0
}

sb_log "resolving upstream versions"

NODE_LATEST="$(node_latest_lts || true)"
GH_LATEST="$(sb_latest_git_tag https://github.com/cli/cli.git || true)"; GH_LATEST="${GH_LATEST#v}"
UV_LATEST="$(sb_latest_git_tag https://github.com/astral-sh/uv.git '^[0-9]+\.[0-9]+\.[0-9]+$' || true)"
CLAUDE_LATEST="$(npm_latest '@anthropic-ai/claude-code' || true)"
CODEX_LATEST="$(npm_latest '@openai/codex' || true)"
PI_LATEST="$(npm_latest '@earendil-works/pi-coding-agent' || true)"
OMZ_LATEST="$(sb_retry 3 git ls-remote https://github.com/ohmyzsh/ohmyzsh.git refs/heads/master 2>/dev/null | awk 'NR == 1 {print $1}' || true)"

# The reference file records the commit date, which needs the commit itself.
omz_commit_date() {
    local commit="$1" temp date
    temp="$(mktemp -d)"
    git init -q "$temp"
    git -C "$temp" remote add origin https://github.com/ohmyzsh/ohmyzsh.git
    if sb_retry 3 git -C "$temp" fetch -q --depth 1 origin "$commit" >/dev/null 2>&1; then
        date="$(git -C "$temp" log -1 --format='%cd' --date=short FETCH_HEAD 2>/dev/null || true)"
    fi
    rm -rf -- "$temp"
    printf '%s\n' "${date:-unknown}"
}

record nodejs "$NODE_VERSION" "$NODE_LATEST"
record github-cli "$GH_VERSION" "$GH_LATEST"
record uv "$UV_VERSION" "$UV_LATEST"
record claude-code "$CLAUDE_CODE_VERSION" "$CLAUDE_LATEST"
record codex "$CODEX_VERSION" "$CODEX_LATEST"
record pi "$PI_VERSION" "$PI_LATEST"
record oh-my-zsh "$OH_MY_ZSH_REF" "$OMZ_LATEST"

printf '\n%-14s %-42s %-42s %s\n' TOOL CURRENT LATEST STATE
stale=0
for row in "${ROWS[@]}"; do
    IFS='|' read -r name current latest state <<< "$row"
    printf '%-14s %-42s %-42s %s\n' "$name" "$current" "$latest" "$state"
    [[ "$state" == STALE ]] && stale=1
done
printf '\n'

if (( stale == 0 )); then
    sb_log "every pin is current"
    exit 0
fi
if [[ "$MODE" == check ]]; then
    sb_warn "pins are stale; rerun with --write to apply"
    exit 1
fi

# Checksums come from each publisher's own manifest, alongside the artifact.
sb_log "resolving checksums for the new versions"
NEW_NODE_X64="$(sb_checksum_from_manifest "https://nodejs.org/dist/v$NODE_LATEST/SHASUMS256.txt" "node-v$NODE_LATEST-linux-x64.tar.xz")"
NEW_NODE_ARM64="$(sb_checksum_from_manifest "https://nodejs.org/dist/v$NODE_LATEST/SHASUMS256.txt" "node-v$NODE_LATEST-linux-arm64.tar.xz")"
GH_MANIFEST="https://github.com/cli/cli/releases/download/v$GH_LATEST/gh_${GH_LATEST}_checksums.txt"
NEW_GH_X64="$(sb_checksum_from_manifest "$GH_MANIFEST" "gh_${GH_LATEST}_linux_amd64.tar.gz")"
NEW_GH_ARM64="$(sb_checksum_from_manifest "$GH_MANIFEST" "gh_${GH_LATEST}_linux_arm64.tar.gz")"
UV_BASE="https://github.com/astral-sh/uv/releases/download/$UV_LATEST"
NEW_UV_X64="$(sb_checksum_from_manifest "$UV_BASE/uv-x86_64-unknown-linux-gnu.tar.gz.sha256" 'uv-x86_64-unknown-linux-gnu.tar.gz')"
NEW_UV_ARM64="$(sb_checksum_from_manifest "$UV_BASE/uv-aarch64-unknown-linux-gnu.tar.gz.sha256" 'uv-aarch64-unknown-linux-gnu.tar.gz')"

NODE_VERSION="$NODE_LATEST" GH_VERSION="$GH_LATEST" UV_VERSION="$UV_LATEST" \
CLAUDE_CODE_VERSION="$CLAUDE_LATEST" CODEX_VERSION="$CODEX_LATEST" PI_VERSION="$PI_LATEST" \
OH_MY_ZSH_REF="$OMZ_LATEST" OMZ_DATE="$(omz_commit_date "$OMZ_LATEST")" \
NODE_SHA256_X64="$NEW_NODE_X64" NODE_SHA256_ARM64="$NEW_NODE_ARM64" \
GH_SHA256_X64="$NEW_GH_X64" GH_SHA256_ARM64="$NEW_GH_ARM64" \
UV_SHA256_X64="$NEW_UV_X64" UV_SHA256_ARM64="$NEW_UV_ARM64" \
python3 "$ROOT/tools/write-pins.py"

# CHANGELOG.md is still a hand edit: it records what a bump means, which no
# pattern can write. The grep shows where the superseded versions are still
# named, using the values as they were before the rewrite above.
sb_log "pins updated; review the diff, then update CHANGELOG.md by hand"
grep -rn --include=CHANGELOG.md -E "$(printf '%s|%s|%s' "$NODE_VERSION" "$GH_VERSION" "$CLAUDE_CODE_VERSION")" . 2>/dev/null | head -n 20 || true
