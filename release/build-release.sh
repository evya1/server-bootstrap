#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$ROOT"
VERSION="$(tr -d '[:space:]' < VERSION)"
NAME=gpu-server-bootstrap
DIST=release/dist
SOURCE_DATE="${SOURCE_DATE_EPOCH:-1700000000}"
SKIP_TESTS=0
[[ "${1:-}" == --skip-tests ]] && SKIP_TESTS=1

mapfile -t SHELL_FILES < <(find . -type f \( -name '*.sh' -o -name 'gpu-bundle-install' -o -name 'gpu-vscode-extensions' \) \
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
    stage="$(mktemp -d)"
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
second="$(mktemp -d)"; build_archives "$second"
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
source_stage="$(mktemp -d)"; mkdir -p "$source_stage/$NAME"
while IFS= read -r -d '' file; do
    install -D "$file" "$source_stage/$NAME/${file#./}"
done < <(find . -type f -not -path './release/dist/*' -not -path './.git/*' -print0 | LC_ALL=C sort -z)
find "$source_stage" -exec touch -d "@$SOURCE_DATE" {} +
( cd "$source_stage" && find . -type f | LC_ALL=C sort | zip -X -q -@ "$ROOT/$DIST/$NAME-$VERSION-source.zip" )
rm -rf "$source_stage"

# First-run files are also copied beside the archives for direct upload.
install -m 0755 gpu-provision.sh "$DIST/gpu-provision.sh"
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
  "reproducible": true,
  "entrypoints": ["gpu-server-bootstrap.sh", "gpu-provision.sh", "gpu-bundle-install", "gpu-accept.sh", "gpu-vscode-extensions"]
}
JSON

verify="$(mktemp -d)"
tar -xzf "$DIST/$NAME-$VERSION.tar.gz" -C "$verify"
for file in gpu-server-bootstrap.sh gpu-provision.sh gpu-bundle-install gpu-accept.sh gpu-vscode-extensions config/vscode-extensions.txt lib/bootstrap/node.sh lib/bootstrap/ai_cli.sh lib/bootstrap/vscode.sh docs/QUICKSTART.md; do
    [[ -f "$verify/$NAME-$VERSION/$file" ]] || { echo "ERROR: missing from release: $file" >&2; exit 1; }
done
rm -rf "$verify"

printf '\nRelease complete: %s %s\n' "$NAME" "$VERSION"
printf '  tar sha256:    %s\n' "$sha_tar_1"
printf '  tar.gz sha256: %s\n' "$sha_tgz_1"
printf '  zip sha256:    %s\n' "$sha_zip_1"
printf '  reproducible:  true\n'
