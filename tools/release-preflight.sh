#!/usr/bin/env bash
# Every release-critical step that must pass before anything is published.
#
#   tools/release-preflight.sh [--tag CANDIDATE]
#
# .github/workflows/release.yml runs this with the pushed tag; .github/workflows/
# ci.yml runs it on every push and pull request, once in an ordinary checkout and
# once inside a manufactured tag-shaped one. There is one implementation, so
# there is no release-only code path to detect.
#
# The suite used to assert that instead: it extracted "commands" from both
# workflows with an awk program over whitespace-split YAML text and compared the
# sets. That check accepted a command named only in a step's `name:` line and a
# command inside an echoed string, and could not see /usr/bin/bash, `bash -e`,
# an interpreter held in a variable, a make target, a composite action or a
# reusable workflow. It also normalised arguments away, so
# `build-release.sh --skip-tests` counted as covering `build-release.sh`. A
# green result was not evidence of the property it named. Consolidating the
# behaviour is what makes the question unnecessary.
#
# Steps, in order:
#   1. the candidate tag matches VERSION            (only with --tag)
#   2. the pinned Gitleaks resolves and verifies
#   3. the reproducible build, which runs the suite and builds twice
#   4. the pre-upload artifact scan, descending into the archives
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$ROOT"

TAG=""
while (( $# )); do
    case "$1" in
        --tag) TAG="${2:?--tag needs a candidate}"; shift 2 ;;
        -h|--help) sed -n '2,24p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "usage: $0 [--tag CANDIDATE]" >&2; exit 2 ;;
    esac
done

if [[ -n "$TAG" ]]; then
    echo "==> Release tag"
    bash "$ROOT/tools/check-release-tag.sh" "$TAG"
fi

# Resolved once and exported so the build's scans and the artifact scan below
# reuse one verified binary instead of downloading per scan.
echo "==> Pinned secret scanner"
echo "   version: $(bash "$ROOT/tools/gitleaks.sh" version)"
GITLEAKS_BIN="$(bash "$ROOT/tools/gitleaks.sh" path)"
export GITLEAKS_BIN
echo "   verified binary: $GITLEAKS_BIN"

# Runs the full test suite, regenerates the in-bundle checksums, builds every
# archive twice and fails if the two passes are not byte-identical, then scans
# the source staging tree and every extracted archive.
echo "==> Reproducible release build"
bash "$ROOT/release/build-release.sh"

# The gate immediately before upload, deliberately independent of the build: it
# re-scans release/dist as it will be published, descending into the archives,
# and honours no skip switch.
echo "==> Pre-publication artifact scan"
bash "$ROOT/tools/gitleaks.sh" scan-artifacts release/dist "release artifacts"

printf '\nrelease-preflight: every pre-publication gate passed\n'
