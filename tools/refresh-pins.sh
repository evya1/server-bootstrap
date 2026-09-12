#!/usr/bin/env bash
# Resolve the current upstream version of every pinned tool and report or apply
# the drift. Run this instead of hand-editing pins across five files.
#
#   tools/refresh-pins.sh                 # report drift
#   tools/refresh-pins.sh --check --all   # also fail on branch-head movement
#   tools/refresh-pins.sh --write         # apply it
#
# Exit codes, which automation can rely on:
#
#   0  nothing actionable. Every release pin is CURRENT. A branch head that has
#      MOVED is reported and tolerated, unless --all is given.
#   1  at least one release pin is STALE and a human should act. With --all, a
#      MOVED branch head produces this too.
#   2  usage error.
#   3  nothing actionable was found, but at least one row is UNKNOWN, so the
#      answer is not trustworthy. Distinct from 0 on purpose: a run whose
#      network or upstream was broken must not read as a clean week.
#
# 1 outranks 3. If something is definitely stale there is definitely work,
# whether or not another row failed to resolve.
#
# Two kinds of pin, because they mean different things. Six tools resolve to a
# published release -- a git tag or an npm dist-tag -- and stay put until
# upstream cuts a new one. Oh My Zsh publishes no releases, so its pin tracks
# refs/heads/master, which moves several times a day. Treating that movement as
# staleness made exit 1 the steady state and the exit code meaningless.
#
# An upstream that cannot be resolved is UNKNOWN and is never reported as
# CURRENT. It used to fall back to the pinned value, so seven failed lookups
# printed seven "current" rows and exited 0.
#
# --write rewrites lib/bootstrap/config.sh, config.example.env, checksums/*.txt,
# README.md and docs/CONFIGURATION.md. CHANGELOG.md stays a hand edit.
# tools/check-pins.sh asserts, offline, that those files still agree.
#
# Tag discovery uses git ls-remote rather than api.github.com: no rate limit,
# no token, and it works from restricted networks.
#
# Sourcing this file defines the functions below and does nothing else: no
# network, no filesystem writes, no directory change, no shell options. That is
# what lets tests/run-tests.sh drive the decision functions offline.

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=lib/core.sh
source "$ROOT/lib/core.sh"

# ---------------------------------------------------------------------------
# Pure decisions. No network, no clock, no filesystem -- driven directly by the
# offline suite with synthetic rows.
# ---------------------------------------------------------------------------

# Which kind of upstream a row tracks. Registered here rather than special-cased
# at the call site, so any future branch-head pin gets the same treatment and
# the classification is a thing a test can assert.
refresh_pins_kind() {
    case "${1:-}" in
        nodejs|github-cli|uv|claude-code|codex|pi) printf 'release\n' ;;
        oh-my-zsh) printf 'branch-head\n' ;;
        *) printf 'unknown\n'; return 2 ;;
    esac
}

# CURRENT | STALE | MOVED | UNKNOWN, from a kind and the two values.
# An empty latest means the resolver failed, and is decided first: it must never
# become CURRENT by comparing the pinned value against itself.
refresh_pins_classify() {
    local kind="${1:-}" current="${2:-}" latest="${3:-}"
    if [[ -z "$latest" ]]; then printf 'UNKNOWN\n'; return 0; fi
    if [[ "$current" == "$latest" ]]; then printf 'CURRENT\n'; return 0; fi
    case "$kind" in
        release) printf 'STALE\n' ;;
        branch-head) printf 'MOVED\n' ;;
        *) printf 'UNKNOWN\n'; return 2 ;;
    esac
}

# Rows on stdin as name|current|latest|state|kind. MODE is default or all.
# Returns the exit code documented in the banner.
refresh_pins_exit_code() {
    local mode="${1:-default}" name current latest state kind
    local actionable=0 unknown=0
    while IFS='|' read -r name current latest state kind; do
        [[ -n "$name" ]] || continue
        case "$state" in
            STALE) actionable=1 ;;
            MOVED) [[ "$mode" != all ]] || actionable=1 ;;
            UNKNOWN) unknown=1 ;;
        esac
    done
    (( actionable == 0 )) || return 1
    (( unknown == 0 )) || return 3
    return 0
}

# ---------------------------------------------------------------------------
# Resolution, reporting and rewriting. Everything below reaches the network.
# ---------------------------------------------------------------------------

# Read the default baked into config.sh rather than sourcing it: an ambient
# CLAUDE_CODE_VERSION in the maintainer's environment must not be mistaken for
# what the repository pins.
refresh_pins_config_default() {
    local name="$1" value
    value="$(sed -n "s|^[[:space:]]*$name=\"\\\${$name:-\(.*\)}\"[[:space:]]*\$|\1|p" \
        "$ROOT/lib/bootstrap/config.sh" | head -n1)"
    [[ -n "$value" ]] || sb_die "no default for $name in lib/bootstrap/config.sh" || return
    printf '%s\n' "$value"
}

refresh_pins_npm_latest() {
    local package="$1" encoded
    encoded="${package//\//%2f}"
    sb_retry 3 curl -fsSL --proto '=https' --tlsv1.2 \
        "https://registry.npmjs.org/-/package/$encoded/dist-tags" 2>/dev/null \
        | sed -n 's/.*[{,]"latest":"\([^"]*\)".*/\1/p'
}

refresh_pins_node_latest_lts() {
    # grep -m1 exits on the first match and SIGPIPEs tr, which prints "tr: write
    # error: Broken pipe" to stderr. Harmless, but the weekly workflow captures
    # stderr into the issue body, so it reached a reader as an apparent error.
    sb_retry 3 curl -fsSL --proto '=https' --tlsv1.2 https://nodejs.org/dist/index.json 2>/dev/null \
        | { tr '{' '\n' 2>/dev/null; } | grep -m1 '"lts":"' \
        | sed -n 's/.*"version":"v\([0-9][0-9.]*\)".*/\1/p'
}

# The reference file records the commit date, which needs the commit itself.
refresh_pins_omz_commit_date() {
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

refresh_pins_main() {
    set -Eeuo pipefail
    cd "$ROOT"
    SB_LOG_PREFIX=refresh-pins

    local mode="check" strict="default"
    while (( $# )); do
        case "$1" in
            --check) mode="check"; shift ;;
            --write) mode="write"; shift ;;
            --all) strict="all"; shift ;;
            -h|--help) sed -n '2,42p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; return 0 ;;
            *) echo "usage: $0 [--check|--write] [--all]" >&2; return 2 ;;
        esac
    done

    local NODE_VERSION GH_VERSION UV_VERSION CLAUDE_CODE_VERSION CODEX_VERSION
    local PI_VERSION OH_MY_ZSH_REF
    NODE_VERSION="$(refresh_pins_config_default NODE_VERSION)"
    GH_VERSION="$(refresh_pins_config_default GH_VERSION)"
    UV_VERSION="$(refresh_pins_config_default UV_VERSION)"
    CLAUDE_CODE_VERSION="$(refresh_pins_config_default CLAUDE_CODE_VERSION)"
    CODEX_VERSION="$(refresh_pins_config_default CODEX_VERSION)"
    PI_VERSION="$(refresh_pins_config_default PI_VERSION)"
    OH_MY_ZSH_REF="$(refresh_pins_config_default OH_MY_ZSH_REF)"

    sb_log "resolving upstream versions"

    local NODE_LATEST GH_LATEST UV_LATEST CLAUDE_LATEST CODEX_LATEST PI_LATEST OMZ_LATEST
    NODE_LATEST="$(refresh_pins_node_latest_lts || true)"
    GH_LATEST="$(sb_latest_git_tag https://github.com/cli/cli.git || true)"; GH_LATEST="${GH_LATEST#v}"
    UV_LATEST="$(sb_latest_git_tag https://github.com/astral-sh/uv.git '^[0-9]+\.[0-9]+\.[0-9]+$' || true)"
    CLAUDE_LATEST="$(refresh_pins_npm_latest '@anthropic-ai/claude-code' || true)"
    CODEX_LATEST="$(refresh_pins_npm_latest '@openai/codex' || true)"
    PI_LATEST="$(refresh_pins_npm_latest '@earendil-works/pi-coding-agent' || true)"
    OMZ_LATEST="$(sb_retry 3 git ls-remote https://github.com/ohmyzsh/ohmyzsh.git refs/heads/master 2>/dev/null | awk 'NR == 1 {print $1}' || true)"

    # name|current|latest|state|kind, built once and consumed three times.
    local -a ROWS=()
    local name current latest kind state
    record() {
        name="$1"; current="$2"; latest="$3"
        kind="$(refresh_pins_kind "$name")"
        state="$(refresh_pins_classify "$kind" "$current" "$latest")"
        [[ "$state" != UNKNOWN ]] || sb_warn "could not resolve the latest $name"
        ROWS+=("$name|$current|$latest|$state|$kind")
    }
    record nodejs "$NODE_VERSION" "$NODE_LATEST"
    record github-cli "$GH_VERSION" "$GH_LATEST"
    record uv "$UV_VERSION" "$UV_LATEST"
    record claude-code "$CLAUDE_CODE_VERSION" "$CLAUDE_LATEST"
    record codex "$CODEX_VERSION" "$CODEX_LATEST"
    record pi "$PI_VERSION" "$PI_LATEST"
    record oh-my-zsh "$OH_MY_ZSH_REF" "$OMZ_LATEST"

    # Release rows first, then branch heads under their own heading, so a MOVED
    # row cannot be mistaken for something to act on.
    local row want_kind stale_count=0 moved_count=0 unknown_count=0
    printf '\n%-14s %-42s %-42s %s\n' TOOL CURRENT LATEST STATE
    for want_kind in release branch-head; do
        [[ "$want_kind" != branch-head ]] \
            || printf -- '-- branch heads: upstream publishes no releases, so movement is reported, not failed --\n'
        for row in "${ROWS[@]}"; do
            IFS='|' read -r name current latest state kind <<< "$row"
            [[ "$kind" == "$want_kind" ]] || continue
            printf '%-14s %-42s %-42s %s\n' "$name" "$current" "${latest:-unknown}" "$state"
        done
    done
    for row in "${ROWS[@]}"; do
        IFS='|' read -r name current latest state kind <<< "$row"
        case "$state" in
            STALE) stale_count=$((stale_count + 1)) ;;
            MOVED) moved_count=$((moved_count + 1)) ;;
            UNKNOWN) unknown_count=$((unknown_count + 1)) ;;
        esac
    done
    printf '\n'
    sb_log "$stale_count stale, $moved_count moved, $unknown_count unknown"

    local code=0
    printf '%s\n' "${ROWS[@]}" | refresh_pins_exit_code "$strict" || code=$?

    if [[ "$mode" == check ]]; then
        case "$code" in
            0) sb_log "nothing actionable" ;;
            1) sb_warn "a pinned release is behind; rerun with --write to apply" ;;
            3) sb_warn "could not resolve $unknown_count upstream(s); this result is not trustworthy" ;;
        esac
        return "$code"
    fi

    # --write. A branch head moves only when asked: making it deliberate is the
    # whole point of separating the two kinds, and the ref is still verified by
    # rev-parse HEAD in lib/bootstrap/shell.sh either way.
    local target_omz="$OH_MY_ZSH_REF"
    [[ "$strict" != all || -z "$OMZ_LATEST" ]] || target_omz="$OMZ_LATEST"

    # Refuse to guess. Writing a fabricated value is worse than not writing:
    # every release row feeds a checksum lookup, and an empty version builds a
    # URL like https://nodejs.org/dist/v/SHASUMS256.txt that fails later with an
    # error naming the URL rather than the cause.
    local unresolved=()
    for row in "${ROWS[@]}"; do
        IFS='|' read -r name current latest state kind <<< "$row"
        [[ "$state" == UNKNOWN ]] || continue
        # In default mode the branch head keeps its current value, so failing to
        # resolve it does not block a release bump.
        [[ "$kind" != branch-head || "$strict" == all ]] || continue
        unresolved+=("$name")
    done
    if (( ${#unresolved[@]} > 0 )); then
        sb_warn "refusing to write: could not resolve ${unresolved[*]}"
        return 3
    fi
    if (( code == 0 )); then
        sb_log "nothing to write"
        return 0
    fi

    # Checksums come from each publisher's own manifest, alongside the artifact.
    sb_log "resolving checksums for the new versions"
    local NEW_NODE_X64 NEW_NODE_ARM64 GH_MANIFEST NEW_GH_X64 NEW_GH_ARM64
    local UV_BASE NEW_UV_X64 NEW_UV_ARM64
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
    OH_MY_ZSH_REF="$target_omz" OMZ_DATE="$(refresh_pins_omz_commit_date "$target_omz")" \
    NODE_SHA256_X64="$NEW_NODE_X64" NODE_SHA256_ARM64="$NEW_NODE_ARM64" \
    GH_SHA256_X64="$NEW_GH_X64" GH_SHA256_ARM64="$NEW_GH_ARM64" \
    UV_SHA256_X64="$NEW_UV_X64" UV_SHA256_ARM64="$NEW_UV_ARM64" \
    python3 "$ROOT/tools/write-pins.py"

    # CHANGELOG.md is still a hand edit: it records what a bump means, which no
    # pattern can write. The grep shows where the superseded versions are still
    # named, using the values as they were before the rewrite above.
    sb_log "pins updated; review the diff, then update CHANGELOG.md by hand"
    grep -rn --include=CHANGELOG.md -E "$(printf '%s|%s|%s' "$NODE_VERSION" "$GH_VERSION" "$CLAUDE_CODE_VERSION")" . 2>/dev/null | head -n 20 || true
}

[[ "${BASH_SOURCE[0]}" != "$0" ]] || refresh_pins_main "$@"
