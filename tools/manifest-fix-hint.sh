#!/usr/bin/env bash
# Explain, and show the patch for, a stale checksums/SHA256SUMS.
#
#   tools/manifest-fix-hint.sh
#
# The workflow files are tracked, so they are part of the canonical release set
# and are covered by checksums/SHA256SUMS. Dependabot edits one of them and has
# no way to run this repository's regeneration command, so an otherwise-valid
# bot pull request arrives with a stale manifest and three red jobs. The failure
# is correct -- see #41 -- but from the outside it is indistinguishable from a
# real incompatibility.
#
# This closes that gap without touching what the manifest guarantees: it names
# the single command that fixes it and prints the exact patch that command
# produces, so the maintainer commit is mechanical rather than a guess.
#
# What it deliberately does not do:
#
#   * It never commits, pushes, or writes anything outside this checkout.
#   * It restores checksums/SHA256SUMS byte-for-byte before returning, so
#     running it leaves the working tree exactly as it found it.
#   * It always exits 0. It is a diagnostic, not a gate: ci.yml runs it as an
#     `if: failure()` step, after the suite has already decided the run is red,
#     and nothing it prints can change that conclusion.
#
# Exit: always 0.
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$ROOT"

MANIFEST=checksums/SHA256SUMS

# Nothing to explain when the manifest is current. This is the common case: the
# step is reached whenever the job failed, which is usually for some other
# reason entirely.
if verify_out="$(bash release/release-files.sh verify 2>&1)"; then
    printf '%s is current; this run failed for some other reason.\n' "$MANIFEST"
    exit 0
fi

printf '==> %s is stale\n\n%s\n\n' "$MANIFEST" "$verify_out"

if [[ ! -f "$MANIFEST" ]]; then
    printf '==> Regenerate it with:\n\n    bash release/release-files.sh write\n\n'
    exit 0
fi

# Saved before regenerating and restored unconditionally, including on an error
# or an interrupt part-way through the write. A diagnostic that leaves a
# rewritten manifest behind would be a worse problem than the one it reports.
BACKUP="$(mktemp)"
cp -p -- "$MANIFEST" "$BACKUP"
restore() {
    cp -p -- "$BACKUP" "$MANIFEST"
    rm -f -- "$BACKUP"
}
trap restore EXIT

printf '==> Fix it with one command:\n\n    bash release/release-files.sh write\n\n'

if ! write_out="$(bash release/release-files.sh write 2>&1)"; then
    printf '==> That command does not currently succeed here:\n\n%s\n\n' "$write_out"
    printf 'Something other than a stale hash is wrong with the release set.\n'
    exit 0
fi

printf '==> The patch that command produces:\n\n'
if command -v git >/dev/null 2>&1 && git rev-parse --git-dir >/dev/null 2>&1; then
    # --no-pager and --exit-code so this works the same in a runner as it does
    # in a terminal; a zero diff means the write was a no-op, which would be a
    # contradiction worth printing rather than hiding.
    if git --no-pager diff --exit-code -- "$MANIFEST"; then
        printf '(no change -- the manifest was already what the tracked set produces)\n'
    fi
else
    printf '(no git checkout here; showing the regenerated file instead)\n\n'
    cat -- "$MANIFEST"
fi

printf '\n==> Commit that one file. Nothing else in the release set changed.\n'
exit 0
