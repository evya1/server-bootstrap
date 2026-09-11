#!/usr/bin/env bash
# The single source of truth for the Gitleaks pin. CI, the release build, and the
# release workflow all scan through this script, so there is exactly one version
# and one checksum to review rather than a pin per caller.
#
#   tools/gitleaks.sh path                 print a verified binary's path
#   tools/gitleaks.sh version              print the pinned version
#   tools/gitleaks.sh scan-dir DIR [LABEL] scan a filesystem tree (no git history)
#   tools/gitleaks.sh scan-artifacts DIR   scan a tree, descending into archives
#   tools/gitleaks.sh scan-history [REPO]  scan every reachable commit
#
# Every scan is redacted and fails closed: a finding, a missing binary, or a
# checksum mismatch all exit non-zero so the caller cannot proceed.
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"

# Bumping these two lines is the only supported way to change the scanner. A
# floating "latest" binary would silently change what CI enforces, and an
# unverified download would let a compromised mirror disable the gate.
GITLEAKS_VERSION=8.30.1
GITLEAKS_SHA256_LINUX_X64=551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb

CONFIG="$ROOT/.gitleaks.toml"

die() { printf 'ERROR: %s\n' "$1" >&2; exit 1; }

# Resolve a Gitleaks binary whose self-reported version matches the pin. Prefers
# a binary that is already present so CI and repeated release scans do not
# re-download, and verifies the archive checksum before trusting a download.
gitleaks_path() {
    local candidate cache archive
    for candidate in "${GITLEAKS_BIN:-}" "$(command -v gitleaks 2>/dev/null || true)"; do
        [[ -n "$candidate" && -x "$candidate" ]] || continue
        [[ "$("$candidate" version 2>/dev/null)" == "$GITLEAKS_VERSION" ]] || continue
        printf '%s\n' "$candidate"
        return 0
    done

    cache="${GITLEAKS_CACHE_DIR:-${TMPDIR:-/tmp}/gitleaks-$GITLEAKS_VERSION}"
    if [[ -x "$cache/gitleaks" ]] \
        && [[ "$("$cache/gitleaks" version 2>/dev/null)" == "$GITLEAKS_VERSION" ]]; then
        printf '%s\n' "$cache/gitleaks"
        return 0
    fi

    [[ "$(uname -s)" == Linux && "$(uname -m)" == x86_64 ]] \
        || die "no pinned Gitleaks build for $(uname -s)/$(uname -m); point GITLEAKS_BIN at a verified v$GITLEAKS_VERSION binary"

    mkdir -p "$cache"
    archive="$cache/gitleaks.tar.gz"
    curl --fail --silent --show-error --location --output "$archive" \
        "https://github.com/gitleaks/gitleaks/releases/download/v$GITLEAKS_VERSION/gitleaks_${GITLEAKS_VERSION}_linux_x64.tar.gz" \
        || die "could not download the pinned Gitleaks release; set GITLEAKS_BIN instead"
    printf '%s  %s\n' "$GITLEAKS_SHA256_LINUX_X64" "$archive" | sha256sum --check --status \
        || die "checksum mismatch on the downloaded Gitleaks archive; refusing to run it"
    tar -xzf "$archive" -C "$cache" gitleaks
    rm -f "$archive"
    printf '%s\n' "$cache/gitleaks"
}

# Filesystem scan. Staging trees and unpacked archives have no history of their
# own, so --no-git is correct there and --log-opts would have no effect.
scan_dir() {
    local target="$1" label="${2:-$1}" bin
    [[ -d "$target" ]] || die "scan target is not a directory: $target"
    bin="$(gitleaks_path)"
    printf '==> Secret scan (%s): %s\n' "$label" "$target"
    "$bin" detect --source "$target" --no-git \
        --config "$CONFIG" --redact --exit-code 1 --no-banner \
        || die "secret scan found a finding in $label; refusing to continue"
}

# Artifact scan. Same as scan-dir but descends into archives. release/dist is
# mostly tar/zip, and a flat scan of it reads zero bytes -- it would pass a
# directory whose every archive contained a credential. Depth 4 is headroom;
# this project nests no archives.
scan_artifacts() {
    local target="$1" label="${2:-$1}" bin
    [[ -d "$target" ]] || die "scan target is not a directory: $target"
    bin="$(gitleaks_path)"
    printf '==> Secret scan (%s, archives included): %s\n' "$label" "$target"
    "$bin" detect --source "$target" --no-git --max-archive-depth 4 \
        --config "$CONFIG" --redact --exit-code 1 --no-banner \
        || die "secret scan found a finding in $label; refusing to continue"
}

# History scan. --log-opts=--all reaches every commit on every ref, which is the
# whole point: a secret removed in a later commit is still reachable and still
# has to be found. Assert the checkout is not shallow first, so a missing
# fetch-depth cannot quietly shrink what "all" means.
scan_history() {
    local target="${1:-$ROOT}" bin shallow commits
    bin="$(gitleaks_path)"
    shallow="$(git -C "$target" rev-parse --is-shallow-repository)"
    [[ "$shallow" == false ]] \
        || die "refusing to scan a shallow checkout; the scan would miss older commits"
    commits="$(git -C "$target" rev-list --all --count)"
    printf '==> Secret scan (complete history): %s commit(s), non-shallow checkout\n' "$commits"
    "$bin" detect --source "$target" \
        --config "$CONFIG" --log-opts='--all' --redact --exit-code 1 --no-banner \
        || die "secret scan found a finding in the repository history; refusing to continue"
}

case "${1:-}" in
    path)         gitleaks_path ;;
    version)      printf '%s\n' "$GITLEAKS_VERSION" ;;
    scan-dir)     shift; [[ $# -ge 1 ]] || die "scan-dir needs a directory"; scan_dir "$@" ;;
    scan-artifacts) shift; [[ $# -ge 1 ]] || die "scan-artifacts needs a directory"; scan_artifacts "$@" ;;
    scan-history) shift; scan_history "$@" ;;
    *)            die "usage: tools/gitleaks.sh {path|version|scan-dir DIR [LABEL]|scan-artifacts DIR [LABEL]|scan-history [REPO]}" ;;
esac
