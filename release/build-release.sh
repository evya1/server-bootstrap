#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$ROOT"
VERSION="$(tr -d '[:space:]' < VERSION)"
NAME=server-bootstrap
DIST=release/dist
SOURCE_DATE="${SOURCE_DATE_EPOCH:-1700000000}"
SKIP_TESTS=0
[[ "${1:-}" == --skip-tests ]] && SKIP_TESTS=1

# Secret scanning runs on by default. SB_RELEASE_SCAN=0 exists for offline
# development only: it is recorded in the release manifest, and the release
# workflow re-scans release/dist itself before upload, so it cannot be used to
# sneak an unscanned artifact onto a GitHub Release.
RELEASE_SCAN="${SB_RELEASE_SCAN:-1}"
SCAN_STATUS=passed
[[ "$RELEASE_SCAN" == 0 ]] && SCAN_STATUS=skipped

# One scratch root for every temporary tree this script makes, removed on any
# exit including a failed scan. Kept well outside release/dist so a scan target
# can never become a release asset. scratch_dir runs in a command substitution,
# so it must not rely on state that a subshell would discard -- hence a single
# parent whose removal takes the children with it.
SCRATCH_ROOT="$(mktemp -d)"
trap 'rm -rf "$SCRATCH_ROOT"' EXIT
scratch_dir() { mktemp -d -p "$SCRATCH_ROOT"; }

# Staging trees and unpacked archives are filesystem trees with no history of
# their own, so this is the --no-git pass; tools/gitleaks.sh holds the same
# version and checksum pin the CI secret-scan job uses.
scan_release_tree() {
    local target="$1" label="$2"
    if [[ "$RELEASE_SCAN" == 0 ]]; then
        printf '   WARNING: SB_RELEASE_SCAN=0 - skipping the %s scan\n' "$label" >&2
        return 0
    fi
    if ! bash "$ROOT/tools/gitleaks.sh" "${3:-scan-dir}" "$target" "$label"; then
        # Archives built before the finding are discarded rather than left
        # behind: a later upload, by hand or by a rerun of the publish step,
        # must not be able to pick up an artifact that failed the gate.
        printf 'ERROR: secret scan failed for %s; discarding %s\n' "$label" "$DIST" >&2
        rm -rf "$DIST"
        exit 1
    fi
}

mapfile -t SHELL_FILES < <(find . -type f \( -name '*.sh' -o -name 'server-bundle-install' \
    -o -name 'server-vscode-extensions' -o -name 'server-secrets' \) \
    -not -path './release/dist/*' | LC_ALL=C sort)

echo "==> Bash syntax"
for file in "${SHELL_FILES[@]}"; do bash -n "$file"; done
if command -v shellcheck >/dev/null 2>&1; then
    echo "==> shellcheck (warning level; non-fatal)"
    shellcheck -S warning "${SHELL_FILES[@]}" || echo "   shellcheck findings noted"
fi

if (( SKIP_TESTS == 0 )); then
    echo "==> Tests"
    bash tests/run-tests.sh
fi

echo "==> Refreshing in-bundle checksums"
mkdir -p checksums "$DIST"
(
    find . -type f \
        -not -path './checksums/SHA256SUMS' \
        -not -path './release/dist/*' \
        -not -path './.git/*' \
        | LC_ALL=C sort | sed 's|^\./||' | xargs sha256sum > checksums/SHA256SUMS
)

build_archives() {
    local output="$1" outdir stage
    outdir="$(mkdir -p "$output" && cd "$output" && pwd -P)"
    mapfile -d '' files < <(find . -type f -not -path './release/dist/*' -not -path './.git/*' -print0 | LC_ALL=C sort -z)
    tar --sort=name --mtime="@$SOURCE_DATE" --owner=0 --group=0 --numeric-owner \
        --transform "s,^\./,$NAME-$VERSION/," -cf "$outdir/$NAME-$VERSION.tar" \
        --null -T <(printf '%s\0' "${files[@]}")
    gzip -n -9 -c "$outdir/$NAME-$VERSION.tar" > "$outdir/$NAME-$VERSION.tar.gz"
    stage="$(scratch_dir)"
    tar -xf "$outdir/$NAME-$VERSION.tar" -C "$stage"
    find "$stage" -exec touch -d "@$SOURCE_DATE" {} +
    ( cd "$stage" && find . -type f | LC_ALL=C sort | zip -X -q -@ "$outdir/$NAME-$VERSION.zip" )
    rm -rf "$stage"
}

rm -rf "$DIST"; mkdir -p "$DIST"
echo "==> Reproducible archives, pass 1"
build_archives "$DIST"
sha_tar_1="$(sha256sum "$DIST/$NAME-$VERSION.tar" | awk '{print $1}')"
sha_tgz_1="$(sha256sum "$DIST/$NAME-$VERSION.tar.gz" | awk '{print $1}')"
sha_zip_1="$(sha256sum "$DIST/$NAME-$VERSION.zip" | awk '{print $1}')"

echo "==> Reproducible archives, pass 2"
second="$(scratch_dir)"; build_archives "$second"
sha_tar_2="$(sha256sum "$second/$NAME-$VERSION.tar" | awk '{print $1}')"
sha_tgz_2="$(sha256sum "$second/$NAME-$VERSION.tar.gz" | awk '{print $1}')"
sha_zip_2="$(sha256sum "$second/$NAME-$VERSION.zip" | awk '{print $1}')"
[[ "$sha_tar_1" == "$sha_tar_2" && "$sha_tgz_1" == "$sha_tgz_2" && "$sha_zip_1" == "$sha_zip_2" ]] \
    || { echo "ERROR: release archives are not reproducible" >&2; exit 1; }
rm -rf "$second"

( cd "$DIST" && sha256sum "$NAME-$VERSION.tar" > "$NAME-$VERSION.tar.sha256" \
    && sha256sum "$NAME-$VERSION.tar.gz" > "$NAME-$VERSION.tar.gz.sha256" \
    && sha256sum "$NAME-$VERSION.zip" > "$NAME-$VERSION.zip.sha256" )

# Source zip uses a stable top-level directory and excludes built releases.
source_stage="$(scratch_dir)"; mkdir -p "$source_stage/$NAME"
while IFS= read -r -d '' file; do
    install -D "$file" "$source_stage/$NAME/${file#./}"
done < <(find . -type f -not -path './release/dist/*' -not -path './.git/*' -print0 | LC_ALL=C sort -z)
find "$source_stage" -exec touch -d "@$SOURCE_DATE" {} +
# Scanned before the zip is written: a finding must stop the build rather than
# produce an artifact that is then quarantined.
scan_release_tree "$source_stage" "source staging tree"
( cd "$source_stage" && find . -type f | LC_ALL=C sort | zip -X -q -@ "$ROOT/$DIST/$NAME-$VERSION-source.zip" )
rm -rf "$source_stage"

# First-run files are also copied beside the archives for direct upload.
install -m 0755 server-provision.sh "$DIST/server-provision.sh"
install -m 0644 examples/provision-plan.example.sh "$DIST/provision-plan.example.sh"
install -m 0644 examples/provision-plan.whisper.example.sh "$DIST/provision-plan.whisper.example.sh"

cat > "$DIST/$NAME-$VERSION-release-manifest.json" <<JSON
{
  "name": "$NAME",
  "version": "$VERSION",
  "tar_sha256": "$sha_tar_1",
  "tar_gz_sha256": "$sha_tgz_1",
  "zip_sha256": "$sha_zip_1",
  "tests": "passed",
  "release_scan": "$SCAN_STATUS",
  "reproducible": true,
  "entrypoints": ["server-bootstrap.sh", "server-provision.sh", "server-bundle-install", "server-accept.sh", "server-vscode-extensions", "server-secrets"]
}
JSON

verify="$(scratch_dir)"
tar -xzf "$DIST/$NAME-$VERSION.tar.gz" -C "$verify"
for file in server-bootstrap.sh server-provision.sh server-bundle-install server-accept.sh server-vscode-extensions server-secrets config/vscode-extensions.txt config/packages.txt lib/secrets-load.sh lib/bootstrap/node.sh lib/bootstrap/ai_cli.sh lib/bootstrap/pi.sh lib/bootstrap/secrets.sh lib/bootstrap/github_cli.sh lib/bootstrap/vscode.sh examples/secrets.env.example examples/pi-models.example.json docs/QUICKSTART.md; do
    [[ -f "$verify/$NAME-$VERSION/$file" ]] || { echo "ERROR: missing from release: $file" >&2; exit 1; }
done
scan_release_tree "$verify" "extracted $NAME-$VERSION.tar.gz"

# Each archive is unpacked into its own scratch tree and scanned. Extraction is
# read-only with respect to release/dist, so the bytes hashed above are the
# bytes published.
unpack_zip="$(scratch_dir)"
unzip -q "$DIST/$NAME-$VERSION.zip" -d "$unpack_zip"
scan_release_tree "$unpack_zip" "extracted $NAME-$VERSION.zip"

unpack_src="$(scratch_dir)"
unzip -q "$DIST/$NAME-$VERSION-source.zip" -d "$unpack_src"
scan_release_tree "$unpack_src" "extracted $NAME-$VERSION-source.zip"

# The directory that is uploaded, exactly as it will be uploaded: sidecar
# checksums, the release manifest, the standalone first-run files, and the
# archives' contents. A flat scan of release/dist reads zero bytes, because
# almost everything in it is an archive, so this pass descends into them.
scan_release_tree "$DIST" "release/dist staging" scan-artifacts

# Publication is only safe if the scans left the artifacts alone.
[[ "$(sha256sum "$DIST/$NAME-$VERSION.tar" | awk '{print $1}')" == "$sha_tar_1" \
    && "$(sha256sum "$DIST/$NAME-$VERSION.tar.gz" | awk '{print $1}')" == "$sha_tgz_1" \
    && "$(sha256sum "$DIST/$NAME-$VERSION.zip" | awk '{print $1}')" == "$sha_zip_1" ]] \
    || { echo "ERROR: release archives changed during scanning" >&2; exit 1; }

printf '\nRelease complete: %s %s\n' "$NAME" "$VERSION"
printf '  tar sha256:    %s\n' "$sha_tar_1"
printf '  tar.gz sha256: %s\n' "$sha_tgz_1"
printf '  zip sha256:    %s\n' "$sha_zip_1"
printf '  reproducible:  true\n'
printf '  secret scan:   %s\n' "$SCAN_STATUS"
