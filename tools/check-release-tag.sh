#!/usr/bin/env bash
# Verify a candidate release tag against VERSION.
#
#   tools/check-release-tag.sh CANDIDATE [VERSION_FILE]
#
# This was four lines of inline shell in .github/workflows/release.yml, which
# meant it ran for the first time on a tag push -- after the version number had
# been spent, and SECURITY.md forbids reusing one. As a script it takes the
# candidate as an argument, so the suite can drive every case offline and
# ci.yml can rehearse the real one.
#
# Accepted: v<major>.<minor>.<patch>, each component without a leading zero.
# Refused: a bare version, a two-component tag, a refs/tags/ prefix, and any
# prerelease or build-metadata suffix. This repository has never published a
# prerelease, and accepting v2.2.2-rc1 here would let one publish as if it were
# the release.
#
# Exit: 0 the candidate matches VERSION, 1 it is well formed but does not match,
# 2 it is malformed or the arguments are wrong.
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"

usage() { echo "usage: $0 CANDIDATE [VERSION_FILE]" >&2; }

case "${1:-}" in
    -h|--help) sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
esac
(( $# >= 1 && $# <= 2 )) || { usage; exit 2; }

candidate="$1"
version_file="${2:-$ROOT/VERSION}"

[[ -n "$candidate" ]] || { echo "check-release-tag: empty candidate tag" >&2; exit 2; }
[[ -f "$version_file" ]] || { echo "check-release-tag: no VERSION file: $version_file" >&2; exit 2; }

# 0|[1-9][0-9]* per component: v02.2.2 is refused rather than silently read as
# v2.2.2, because the tag and the VERSION string have to be the same text.
if [[ ! "$candidate" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
    printf 'check-release-tag: malformed tag %q; expected v<major>.<minor>.<patch> with no suffix\n' \
        "$candidate" >&2
    exit 2
fi

declared="$(tr -d '[:space:]' < "$version_file")"
[[ -n "$declared" ]] || { echo "check-release-tag: $version_file is empty" >&2; exit 2; }

if [[ "${candidate#v}" != "$declared" ]]; then
    printf 'check-release-tag: tag %s does not match VERSION %s\n' "${candidate#v}" "$declared" >&2
    exit 1
fi
printf 'check-release-tag: %s matches VERSION %s\n' "$candidate" "$declared"
