#!/usr/bin/env bash
# The single source of truth for the actionlint pin, in the shape of
# tools/gitleaks.sh: one version, one checksum, verified before it runs.
#
#   tools/actionlint.sh path      print a verified binary's path
#   tools/actionlint.sh version   print the pinned version
#   tools/actionlint.sh run       lint every workflow in .github/workflows
#
# The workflows used to be validated by hand-rolled regexes in the test suite,
# which is how a step `name:` came to satisfy an assertion about a command that
# runs. A YAML-aware linter is the right tool for the shape of a workflow file.
#
# A missing binary, a checksum mismatch or any finding all exit non-zero, so a
# caller cannot proceed on an unvalidated workflow.
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"

# Bumping these two lines is the only supported way to change the linter. A
# floating "latest" would silently change what CI enforces, and an unverified
# download would let a compromised mirror disable the gate.
ACTIONLINT_VERSION=1.7.12
ACTIONLINT_SHA256_LINUX_X64=8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8

die() { printf 'ERROR: %s\n' "$1" >&2; exit 1; }

actionlint_path() {
    local candidate cache archive
    for candidate in "${ACTIONLINT_BIN:-}" "$(command -v actionlint 2>/dev/null || true)"; do
        [[ -n "$candidate" && -x "$candidate" ]] || continue
        [[ "$("$candidate" -version 2>/dev/null | head -n1)" == "$ACTIONLINT_VERSION" ]] || continue
        printf '%s\n' "$candidate"
        return 0
    done

    cache="${ACTIONLINT_CACHE_DIR:-${TMPDIR:-/tmp}/actionlint-$ACTIONLINT_VERSION}"
    if [[ -x "$cache/actionlint" ]] \
        && [[ "$("$cache/actionlint" -version 2>/dev/null | head -n1)" == "$ACTIONLINT_VERSION" ]]; then
        printf '%s\n' "$cache/actionlint"
        return 0
    fi

    [[ "$(uname -s)" == Linux && "$(uname -m)" == x86_64 ]] \
        || die "no pinned actionlint build for $(uname -s)/$(uname -m); point ACTIONLINT_BIN at a verified v$ACTIONLINT_VERSION binary"

    mkdir -p "$cache"
    archive="$cache/actionlint.tar.gz"
    curl --fail --silent --show-error --location --output "$archive" \
        "https://github.com/rhysd/actionlint/releases/download/v$ACTIONLINT_VERSION/actionlint_${ACTIONLINT_VERSION}_linux_amd64.tar.gz" \
        || die "could not download the pinned actionlint release; set ACTIONLINT_BIN instead"
    printf '%s  %s\n' "$ACTIONLINT_SHA256_LINUX_X64" "$archive" | sha256sum --check --status \
        || die "checksum mismatch on the downloaded actionlint archive; refusing to run it"
    tar -xzf "$archive" -C "$cache" actionlint
    rm -f "$archive"
    printf '%s\n' "$cache/actionlint"
}

lint() {
    local bin
    bin="$(actionlint_path)"
    printf '==> Workflow lint (actionlint v%s)\n' "$ACTIONLINT_VERSION"
    # -shellcheck= disables actionlint's own shellcheck pass: the repository
    # already runs shellcheck over its scripts, and the inline snippets here are
    # short. Keeping it off means the pin is the only thing that decides what
    # this gate enforces.
    ( cd "$ROOT" && "$bin" -color -shellcheck= .github/workflows/*.yml ) \
        || die "actionlint reported a finding; refusing to continue"
    printf '   no findings\n'
}

case "${1:-}" in
    path)    actionlint_path ;;
    version) printf '%s\n' "$ACTIONLINT_VERSION" ;;
    run)     lint ;;
    -h|--help) sed -n '2,8p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' ;;
    *) die "usage: $0 {path|version|run}" ;;
esac
