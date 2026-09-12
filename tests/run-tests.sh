#!/usr/bin/env bash
set -Euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$ROOT"
PASS=0; FAIL=0
# Set by the checksums/SHA256SUMS assertion, read by the Results section. See #41.
MANIFEST_STALE=0
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
ok(){ printf '  ok:   %s\n' "$1"; PASS=$((PASS+1)); }
bad(){ printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL+1)); }
section(){ printf '\n== %s ==\n' "$1"; }
skip(){ printf '  skip: %s\n' "$1"; }

section "Syntax and structure"
while IFS= read -r file; do
    bash -n "$file" && ok "bash -n $file" || bad "syntax: $file"
done < <(find . -type f \( -name '*.sh' -o -name 'server-bundle-install' \
    -o -name 'server-vscode-extensions' -o -name 'server-secrets' \) \
    -not -path './release/dist/*' | LC_ALL=C sort)
for file in lib/core.sh lib/archive.sh lib/bundle.sh \
    lib/bootstrap/config.sh lib/bootstrap/workspace.sh lib/bootstrap/packages.sh \
    lib/bootstrap/node.sh lib/bootstrap/ai_cli.sh lib/bootstrap/vscode.sh lib/bootstrap/uv.sh lib/bootstrap/python.sh lib/bootstrap/shell.sh \
    lib/bootstrap/github_cli.sh lib/bootstrap/runtime.sh lib/bootstrap/report.sh \
    lib/secrets-load.sh lib/bootstrap/secrets.sh lib/bootstrap/pi.sh; do
    [[ -f "$file" ]] && ok "module present: $file" || bad "missing module: $file"
done
for command in server-bootstrap.sh server-provision.sh server-bundle-install server-accept.sh server-vscode-extensions server-secrets; do
    [[ -x "$command" ]] && ok "executable: $command" || bad "not executable: $command"
done

# Matching is case-insensitive substring, so "whisper" also covers
# faster-whisper et al. and "torch" covers pytorch.
auto_terms=(whisper transcribe torch)
term_hit=0
for file in server-bootstrap.sh server-bundle-install lib/*.sh lib/bootstrap/*.sh; do
    for term in "${auto_terms[@]}"; do
        if grep -qi -- "$term" "$file"; then bad "workload term '$term' in neutral code: $file"; term_hit=1; fi
    done
done
(( term_hit == 0 )) && ok "neutral runtime code"

# A fenced block that outlives the content it was going to hold renders as an
# empty box, which reads as a command somebody forgot to write down. README.md
# carried one between the --check exit-code paragraph and the --write paragraph
# from 845389f until #43: the prose absorbed what the block was for, the fence
# stayed. Cheap and deterministic to assert, so it is asserted over every
# tracked Markdown file rather than only the one that broke.
fence_drift=0
while IFS= read -r file; do
    python3 - "$file" <<'PY' || fence_drift=1
import sys
path = sys.argv[1]
lines = open(path, encoding="utf-8").read().split("\n")
opened = None
for number, line in enumerate(lines, 1):
    if not line.startswith("```"):
        continue
    if opened is None:
        opened = number
        continue
    if not any(x.strip() for x in lines[opened:number - 1]):
        print(f"  FAIL: empty fenced code block: {path}:{opened}-{number}")
        raise SystemExit(1)
    opened = None
if opened is not None:
    print(f"  FAIL: unclosed fenced code block: {path}:{opened}")
    raise SystemExit(1)
PY
done < <(git ls-files '*.md' 2>/dev/null | LC_ALL=C sort)
(( fence_drift == 0 )) && ok "no tracked Markdown file has an empty or unclosed code fence"

section "Security and privacy guards"
# Private-use wording, credential-shaped filenames, private-key material,
# high-signal markers and tracked build output are all enforced by
# tests/privacy-guard.sh, exercised against fixtures further down.
[[ -s .gitleaks.toml ]] && ok "Gitleaks policy is present" || bad "missing Gitleaks policy"
for allowed in '/root' '/workspace' 'localhost' '127\.0\.0\.1' '::1' \
    'example\.(?:com|org|net)' 'CHANGE_ME' 'EXAMPLE_TOKEN'; do
    grep -Fq -- "$allowed" .gitleaks.toml \
        && ok "allowlist entry is explicit: $allowed" \
        || bad "missing allowlist entry: $allowed"
done
if grep -Eq '(^|[[:space:]])(paths|regexes)[[:space:]]*=.*\.\*' .gitleaks.toml; then
    bad "Gitleaks allowlist contains a broad wildcard"
else
    ok "Gitleaks allowlist has no broad wildcard"
fi
for ignored in .env .env.local config/local.env credentials/api.token \
    .ssh/id_ed25519 .aws/credentials .npmrc .kube/config state.tfstate; do
    git check-ignore --no-index -q -- "$ignored" \
        && ok "credential/config artifact is ignored: $ignored" \
        || bad "credential/config artifact is not ignored: $ignored"
done
for visible in config.example.env examples/addon.env.example; do
    git check-ignore -q -- "$visible" \
        && bad "intentional example is ignored: $visible" \
        || ok "intentional example remains visible: $visible"
done
tracked_ignored=0
while IFS= read -r file; do
    if git check-ignore -q -- "$file"; then
        bad "tracked file is now ignored: $file"
        tracked_ignored=1
    fi
done < <(git ls-files)
(( tracked_ignored == 0 )) && ok "tracked files are not hidden by ignore rules"

# The guard is only worth having if it fires, so every policy is exercised
# against a fixture built at runtime. No fixture is ever committed: the
# secret-scan job reads full history, so a committed fake token could only be
# removed by rewriting history, which SECURITY.md forbids.
guard_root="$TMP/privacy-guard"
guard_out="$TMP/privacy-guard.out"
guard_run(){ ./tests/privacy-guard.sh --dir "$guard_root" >"$guard_out" 2>&1; }

[[ -x tests/privacy-guard.sh ]] \
    && ok "executable: tests/privacy-guard.sh" || bad "not executable: tests/privacy-guard.sh"

if ./tests/privacy-guard.sh >"$guard_out" 2>&1; then
    ok "privacy guard passes on the tracked repository"
else
    bad "privacy guard reports a violation on the tracked repository"
    sed 's/^/        /' "$guard_out"
fi

mkdir -p "$guard_root/examples"
printf 'no secrets here\n' > "$guard_root/README.md"
: > "$guard_root/config.example.env"
: > "$guard_root/examples/addon.env.example"
guard_run && ok "guard passes on the approved example templates" \
    || bad "guard rejects config.example.env or examples/addon.env.example"

# Deterministic, high-entropy and obviously synthetic: assembled here, asserted
# on, then deleted. Grepping this file finds a recipe, never a token.
fixture_token="sk-$(printf 'run-tests-privacy-fixture' | sha256sum | cut -c1-40)"
printf 'api_key = "%s"\n' "$fixture_token" > "$guard_root/service.conf"
if guard_run; then
    bad "guard missed a fake high-signal token"
else
    ok "guard fails on a fake high-signal token"
    grep -q 'vendor-credential-marker' "$guard_out" \
        && ok "guard names the violated policy" || bad "guard did not name the violated policy"
    grep -qF -- "$fixture_token" "$guard_out" \
        && bad "guard printed the secret value" || ok "guard reports without printing the value"
fi
rm -f "$guard_root/service.conf"
guard_run && ok "guard passes once the token fixture is removed" \
    || bad "guard still fails after the token fixture was removed"

# A PEM header assembled from fragments, for the same reason.
pem_begin='-----BEGIN'; pem_kind='RSA PRIVATE'; pem_end='KEY-----'
printf '%s %s %s\nMIIEowIBAAKCAQEA\n' "$pem_begin" "$pem_kind" "$pem_end" > "$guard_root/host.conf"
guard_run && bad "guard missed a private-key header" \
    || { ok "guard fails on a private-key header"; grep -q 'private-key-material' "$guard_out" \
        && ok "guard names the private-key policy" || bad "guard did not name the private-key policy"; }
rm -f "$guard_root/host.conf"

: > "$guard_root/production.env"
guard_run && bad "guard missed a prohibited filename" \
    || { ok "guard fails on a prohibited filename"; grep -q 'credential-or-config-filename' "$guard_out" \
        && ok "guard names the filename policy" || bad "guard did not name the filename policy"; }
rm -f "$guard_root/production.env"

mkdir -p "$guard_root/release/dist"
: > "$guard_root/release/dist/server-bootstrap-0.0.0.tar.gz"
guard_run && bad "guard missed tracked release output" \
    || { ok "guard fails when release/dist is in the tracked set"; grep -q 'generated-artifact-tracked' "$guard_out" \
        && ok "guard names the generated-artifact policy" || bad "guard did not name the artifact policy"; }
rm -rf "$guard_root/release"

guard_run && ok "guard is clean again once every fixture is removed" \
    || bad "guard is not stable across repeated runs"

grep -q 'STEP=acceptance' server-bootstrap.sh && grep -q 'STEP=addon' server-bootstrap.sh \
    && [[ "$(grep -n 'STEP=acceptance' server-bootstrap.sh | cut -d: -f1)" -lt "$(grep -n 'STEP=addon' server-bootstrap.sh | cut -d: -f1)" ]] \
    && ok "acceptance precedes optional add-on" || bad "acceptance ordering"

section "Release scanning"
# Structural assertions: every tree that becomes a release asset is scanned, the
# gate sits between build and upload, and there is exactly one scanner pin.
while IFS='|' read -r label expect; do
    [[ -n "$label" ]] || continue
    grep -qF -- "$expect" release/build-release.sh \
        && ok "release build scans the $label" \
        || bad "release build does not scan the $label"
done <<'SCANS'
source staging tree|scan_release_tree "$source_stage" "source staging tree"
extracted tar.gz|scan_release_tree "$verify" "extracted $NAME-$VERSION.tar.gz"
extracted zip|scan_release_tree "$unpack_zip" "extracted $NAME-$VERSION.zip"
extracted source zip|scan_release_tree "$unpack_src" "extracted $NAME-$VERSION-source.zip"
release/dist sidecars, manifest and standalone files|scan_release_tree "$DIST" "release/dist staging" scan-artifacts
SCANS
grep -qF 'rm -rf "$DIST"' release/build-release.sh \
    && grep -qF 'discarding' release/build-release.sh \
    && ok "a failed scan discards the staged release" \
    || bad "a failed scan leaves release/dist in place"
grep -qF 'release archives changed during scanning' release/build-release.sh \
    && ok "archive hashes are re-verified after scanning" \
    || bad "nothing re-verifies archive bytes after the scans"
grep -qF '"release_scan": "$SCAN_STATUS"' release/build-release.sh \
    && ok "the release manifest records the scan result" \
    || bad "the release manifest does not record the scan result"

# The upload gate must still come after the build and before the publish
# action. Both moved into tools/release-preflight.sh, so the ordering is
# asserted in two parts: the preflight runs before Publish assets, and inside it
# the artifact scan runs after the build. Comment lines are stripped from both,
# so a step described in prose cannot stand in for one that runs.
release_body="$(grep -vE '^[[:space:]]*#' .github/workflows/release.yml)"
preflight_body="$(grep -vE '^[[:space:]]*#' tools/release-preflight.sh)"
preflight_at="$(grep -nF 'bash tools/release-preflight.sh' <<< "$release_body" | cut -d: -f1 | head -1)"
publish_at="$(grep -nF 'name: Publish assets' <<< "$release_body" | cut -d: -f1 | head -1)"
build_at="$(grep -nF 'release/build-release.sh' <<< "$preflight_body" | cut -d: -f1 | head -1)"
gate_at="$(grep -nF 'scan-artifacts release/dist' <<< "$preflight_body" | cut -d: -f1 | head -1)"
if [[ -n "$preflight_at" && -n "$publish_at" ]] && (( preflight_at < publish_at )); then
    ok "release.yml runs the preflight before uploading"
else
    bad "release.yml uploads without running the preflight first"
fi
if [[ -n "$build_at" && -n "$gate_at" ]] && (( build_at < gate_at )); then
    ok "the preflight scans release/dist after building it"
else
    bad "the preflight has no artifact scan after the build"
fi

# One pin, reused. A second hardcoded version or checksum is how the CI scanner
# and the release scanner silently drift apart.
grep -qE '^GITLEAKS_VERSION=[0-9]+\.[0-9]+\.[0-9]+$' tools/gitleaks.sh \
    && ok "tools/gitleaks.sh pins an exact Gitleaks version" \
    || bad "tools/gitleaks.sh does not pin an exact version"
grep -qE '^GITLEAKS_SHA256_LINUX_X64=[0-9a-f]{64}$' tools/gitleaks.sh \
    && ok "tools/gitleaks.sh pins a release checksum" \
    || bad "tools/gitleaks.sh does not pin a release checksum"
pin_drift=0
for file in .github/workflows/ci.yml .github/workflows/release.yml \
    tools/release-preflight.sh release/build-release.sh; do
    grep -qE 'gitleaks_[0-9]+\.[0-9]+\.[0-9]+_linux|GITLEAKS_SHA256' "$file" \
        && { bad "$file carries its own Gitleaks pin"; pin_drift=1; }
done
for file in .github/workflows/ci.yml tools/release-preflight.sh; do
    grep -qF 'tools/gitleaks.sh' "$file" \
        || { bad "$file does not scan through tools/gitleaks.sh"; pin_drift=1; }
done
# release.yml reaches the scanner only through the preflight. Invoking it
# directly would be a release-only path again, which is what #26 removed.
grep -qF 'tools/gitleaks.sh' .github/workflows/release.yml \
    && { bad "release.yml invokes the scanner directly instead of through the preflight"; pin_drift=1; }
(( pin_drift == 0 )) && ok "every caller reaches the scanner through the single pinned helper"
grep -qF 'tools/gitleaks.sh' release/build-release.sh \
    && ok "the release build scans through the single pinned helper" \
    || bad "the release build does not use the pinned helper"

# Functional checks, only when a matching binary is already present. Downloading
# one here would make the suite require network access, which it must not.
pinned_version="$(bash tools/gitleaks.sh version)"
gitleaks_ready=""
for candidate in "${GITLEAKS_BIN:-}" "$(command -v gitleaks 2>/dev/null || true)"; do
    [[ -n "$candidate" && -x "$candidate" ]] || continue
    [[ "$("$candidate" version 2>/dev/null)" == "$pinned_version" ]] || continue
    gitleaks_ready="$candidate"; break
done

if [[ -z "$gitleaks_ready" ]]; then
    skip "release scan behaviour (no pinned Gitleaks v$pinned_version available offline)"
else
    export GITLEAKS_BIN="$gitleaks_ready"
    scan_root="$TMP/release-scan"
    mkdir -p "$scan_root/payload"
    printf 'nothing to see\n' > "$scan_root/payload/README.md"
    bash tools/gitleaks.sh scan-dir "$scan_root/payload" "fixture" >/dev/null 2>&1 \
        && ok "release scan passes on a clean staging tree" \
        || bad "release scan fails on a clean staging tree"

    # Same fixture recipe as the privacy guard: built here, never committed.
    scan_token="sk-$(printf 'release-scan-fixture' | sha256sum | cut -c1-40)"
    printf 'api_key = "%s"\n' "$scan_token" > "$scan_root/payload/service.conf"
    bash tools/gitleaks.sh scan-dir "$scan_root/payload" "fixture" >"$TMP/scan.out" 2>&1 \
        && bad "release scan missed a fake token in a staging tree" \
        || ok "release scan fails on a fake token in a staging tree"
    grep -qF -- "$scan_token" "$TMP/scan.out" \
        && bad "release scan printed the secret value" \
        || ok "release scan reports without printing the value"

    # The pre-upload gate must see inside an archive: a flat scan of a directory
    # of tarballs reads zero bytes and would pass anything.
    mkdir -p "$scan_root/dist"
    ( cd "$scan_root" && tar -czf dist/bundle.tar.gz payload )
    rm -f "$scan_root/payload/service.conf"
    bash tools/gitleaks.sh scan-artifacts "$scan_root/dist" "fixture artifacts" >/dev/null 2>&1 \
        && bad "artifact scan missed a fake token inside an archive" \
        || ok "artifact scan fails on a fake token inside an archive"
    bash tools/gitleaks.sh scan-dir "$scan_root/dist" "fixture artifacts" >/dev/null 2>&1 \
        && ok "a flat scan cannot see inside an archive (why the gate uses scan-artifacts)" \
        || bad "flat-scan control behaved unexpectedly"
    rm -rf "$scan_root"
fi

section "Fitness: the release file set and checksums/SHA256SUMS"
# release/build-release.sh used to walk the working tree with three separate
# `find .` passes, so an untracked scratch file in a contributor's checkout was
# hashed into checksums/SHA256SUMS and packed into the tar, the zip and the
# source zip -- and every gate stayed green, because a check that only asks
# whether every tracked file is present cannot see an extra entry. The set is
# now resolved once by release/release-files.sh and consumed by all of them.
# See #24.
release_files_out="$(bash release/release-files.sh verify 2>&1)" \
    && ok "checksums/SHA256SUMS matches the release file set" \
    || { bad "release-files verify: $release_files_out"; MANIFEST_STALE=1; }
[[ "$(bash release/release-files.sh source 2>/dev/null)" == git ]] \
    && ok "a git checkout resolves the release set from the tracked files" \
    || bad "a git checkout did not resolve the release set from git"
# The generation must stay where the tests think it is: this cannot start
# passing because the manifest quietly moved to being written somewhere else.
grep -q 'release-files.sh" write' release/build-release.sh \
    && grep -q 'release-files.sh" list' release/build-release.sh \
    && ok "the release build generates the manifest and the archives from one set" \
    || bad "release/build-release.sh no longer uses the canonical release set"
grep -qE "find \. -type f -not -path './release/dist/\*'" release/build-release.sh \
    && bad "release/build-release.sh still walks the working tree for release content" \
    || ok "no working-tree walk is left in the release content path"

# Synthetic repositories, built with git init + git add: the index is what
# git ls-files reads, so no commit and no user identity is needed, and nothing
# here touches the network or the real tree. One tracked path deliberately
# contains a space, because the manifest format splits on a fixed 64-hex + two
# space prefix and a whitespace split would corrupt it.
release_fixture() {
    local dir i
    dir="$(mktemp -d "$TMP/relset.XXXXXX")"
    mkdir -p "$dir/lib" "$dir/docs"
    printf 'alpha\n' > "$dir/alpha.txt"
    printf 'beta\n' > "$dir/lib/beta.sh"
    printf 'spaced\n' > "$dir/a file with spaces.txt"
    for i in $(seq -w 1 25); do printf 'doc %s\n' "$i" > "$dir/docs/page-$i.md"; done
    git -c init.defaultBranch=main init -q "$dir"
    git -C "$dir" add -A
    bash release/release-files.sh --root "$dir" write >/dev/null
    git -C "$dir" add -A
    printf '%s\n' "$dir"
}
release_reject() {  # label, expected finding fragment, root
    local label="$1" fragment="$2" root="$3" out
    if out="$(bash release/release-files.sh --root "$root" verify 2>&1)"; then
        bad "release-files accepted $label"
        return
    fi
    grep -qF -- "$fragment" <<< "$out" \
        && ok "release-files rejects $label" \
        || bad "release-files rejected $label, but not for '$fragment': $out"
}

root="$(release_fixture)"
bash release/release-files.sh --root "$root" verify >/dev/null 2>&1 \
    && ok "a clean synthetic tree verifies" || bad "a clean synthetic tree does not verify"
grep -q '  a file with spaces\.txt$' "$root/checksums/SHA256SUMS" \
    && ok "a path containing spaces round-trips through the manifest" \
    || bad "a path containing spaces did not round-trip"

# The case this issue exists for. The file must be absent from the set, and the
# manifest must still verify -- an untracked scratch file in a contributor's
# checkout is not a release problem and must not be reported as one.
root="$(release_fixture)"
printf 'local scratch\n' > "$root/scratch-probe.tmp"
mkdir -p "$root/notes"; printf 'private\n' > "$root/notes/private-note.txt"
if bash release/release-files.sh --root "$root" list 2>/dev/null \
    | tr '\0' '\n' | grep -qE 'scratch-probe|private-note'; then
    bad "an untracked file is in the release set"
else
    ok "an untracked file is not in the release set"
fi
bash release/release-files.sh --root "$root" verify >/dev/null 2>&1 \
    && ok "an untracked file does not fail the manifest check" \
    || bad "an untracked file falsely failed the manifest check"

root="$(release_fixture)"; printf 'changed\n' >> "$root/alpha.txt"
release_reject "a modified tracked file" "stale hash: alpha.txt" "$root"

root="$(release_fixture)"; rm -- "$root/lib/beta.sh"
release_reject "a tracked file deleted from disk" "recorded but not on disk: lib/beta.sh" "$root"

root="$(release_fixture)"; sed -i '/  alpha\.txt$/d' "$root/checksums/SHA256SUMS"
release_reject "a missing manifest entry" "missing from the manifest: alpha.txt" "$root"

# Only reachable because the comparison is exact in both directions. A check
# that asks only "is every tracked file recorded" passes this.
root="$(release_fixture)"
printf '%064d  zzz-not-in-the-release.txt\n' 0 >> "$root/checksums/SHA256SUMS"
release_reject "an extra manifest entry" "not part of the release: zzz-not-in-the-release.txt" "$root"

root="$(release_fixture)"
duplicate_line="$(grep '  alpha\.txt$' "$root/checksums/SHA256SUMS")"
printf '%s\n' "$duplicate_line" >> "$root/checksums/SHA256SUMS"
release_reject "a duplicated manifest entry" "duplicate entry: alpha.txt" "$root"

root="$(release_fixture)"
sed -i "s|^[0-9a-f]\{64\}\(  alpha\.txt\)$|$(printf '%064d' 0)\1|" "$root/checksums/SHA256SUMS"
release_reject "an incorrect hash" "stale hash: alpha.txt" "$root"

root="$(release_fixture)"
python3 - "$root/checksums/SHA256SUMS" <<'SWAP'
import sys
path = sys.argv[1]
lines = open(path).read().splitlines()
lines[0], lines[1] = lines[1], lines[0]
open(path, 'w').write("".join(l + "\n" for l in lines))
SWAP
release_reject "a misordered manifest" "manifest is not sorted" "$root"

# A single bogus line must not bury the rest of the suite: 28 files means 29
# findings, and the report is capped.
root="$(release_fixture)"
printf 'deadbeef  alpha.txt\n' > "$root/checksums/SHA256SUMS"
bogus_out="$(bash release/release-files.sh --root "$root" verify 2>&1 || true)"
grep -qF 'malformed line 1' <<< "$bogus_out" \
    && grep -qF '... and ' <<< "$bogus_out" \
    && (( $(wc -l <<< "$bogus_out") <= 25 )) \
    && ok "a one-line bogus manifest fails with capped output" \
    || bad "a one-line bogus manifest was not reported as expected: $bogus_out"

# A path that GNU sha256sum would have to escape is refused rather than encoded,
# because the escaping makes the format ambiguous to every naive parser.
root="$(release_fixture)"
printf 'odd\n' > "$root/back\\slash.txt"
git -C "$root" add -A
backslash_out="$(bash release/release-files.sh --root "$root" list 2>&1 || true)"
grep -qF 'needs escaping in a checksum manifest' <<< "$backslash_out" \
    && ok "a path needing checksum escaping is refused" \
    || bad "a path with a backslash was not refused: $backslash_out"

# In source-bundle mode the manifest is an input, so it decides what gets hashed
# and packed: a path climbing out of the tree, or an empty manifest, must be
# refused rather than acted on.
root="$(release_fixture)"; rm -rf "$root/.git"
printf '%064d  ../outside-the-tree.txt\n' 0 >> "$root/checksums/SHA256SUMS"
escape_out="$(bash release/release-files.sh --root "$root" list 2>&1 || true)"
grep -qF 'release path escapes the tree' <<< "$escape_out" \
    && ok "a manifest path climbing out of the tree is refused" \
    || bad "a manifest path with .. was not refused: $escape_out"

root="$(release_fixture)"; rm -rf "$root/.git"; : > "$root/checksums/SHA256SUMS"
if bash release/release-files.sh --root "$root" list >/dev/null 2>&1; then
    bad "an empty manifest still produced a release set"
else
    ok "an empty manifest is refused"
fi

# The unpacked-source-bundle shape: no .git, so the set comes from the manifest
# the bundle already ships. It is a weaker input and says so.
root="$(release_fixture)"; rm -rf "$root/.git"
[[ "$(bash release/release-files.sh --root "$root" source 2>/dev/null)" == manifest ]] \
    && ok "a source bundle resolves the release set from the shipped manifest" \
    || bad "a source bundle did not fall back to the manifest"
bundle_out="$(bash release/release-files.sh --root "$root" verify 2>&1)"
grep -qF 'tracked-set comparison is unavailable' <<< "$bundle_out" \
    && ok "the manifest fallback is announced, not silent" \
    || bad "the manifest fallback was silent: $bundle_out"

# And with neither, it must refuse rather than fall back to walking the tree,
# which is the behaviour this whole section exists to remove.
root="$(release_fixture)"; rm -rf "$root/.git" "$root/checksums/SHA256SUMS"
if bash release/release-files.sh --root "$root" list >/dev/null 2>&1; then
    bad "a tree with no .git and no manifest still produced a release set"
else
    ok "a tree with no .git and no manifest is refused"
fi

# --- the stale-manifest remedy (#41) ---------------------------------------
# Dependabot edits a tracked workflow file and cannot run the regeneration
# command, so every one of its pull requests opens with a stale manifest and
# three red jobs. The verification is correct and is deliberately untouched
# above; what is tested here is that the failure explains itself. The hint
# script is exercised against a synthetic tree, never the real checkout, so a
# failing assertion cannot leave this repository's manifest rewritten.
hint_fixture() {  # -> a synthetic root carrying both scripts
    local dir; dir="$(release_fixture)"
    mkdir -p "$dir/tools" "$dir/release"
    cp tools/manifest-fix-hint.sh "$dir/tools/"
    cp release/release-files.sh "$dir/release/"
    git -C "$dir" add -A
    bash release/release-files.sh --root "$dir" write >/dev/null
    git -C "$dir" add -A
    printf '%s\n' "$dir"
}

root="$(hint_fixture)"
hint_out="$(bash "$root/tools/manifest-fix-hint.sh" 2>&1)"; hint_code=$?
(( hint_code == 0 )) \
    && ok "the manifest hint exits 0 on a current manifest" \
    || bad "the manifest hint exited $hint_code on a current manifest"
grep -qF 'is current' <<< "$hint_out" \
    && ok "the manifest hint says nothing is stale when nothing is stale" \
    || bad "the manifest hint did not report a current manifest: $hint_out"

# The Dependabot shape: a tracked file changes, the manifest does not.
root="$(hint_fixture)"
before="$(sha256sum "$root/checksums/SHA256SUMS" | awk '{print $1}')"
printf 'bumped\n' >> "$root/lib/beta.sh"
hint_out="$(bash "$root/tools/manifest-fix-hint.sh" 2>&1)"; hint_code=$?
(( hint_code == 0 )) \
    && ok "the manifest hint exits 0 on a stale manifest, so it is never a gate" \
    || bad "the manifest hint exited $hint_code on a stale manifest"
grep -qF 'bash release/release-files.sh write' <<< "$hint_out" \
    && ok "the manifest hint names the exact regeneration command" \
    || bad "the manifest hint did not name the command: $hint_out"
grep -qF 'stale hash: lib/beta.sh' <<< "$hint_out" \
    && ok "the manifest hint names the file that went stale" \
    || bad "the manifest hint did not name the stale file: $hint_out"
grep -qE '^\+[0-9a-f]{64}  lib/beta\.sh$' <<< "$hint_out" \
    && ok "the manifest hint prints the patch that fixes it" \
    || bad "the manifest hint printed no fixing patch: $hint_out"
# The property that makes it safe to run from CI: it regenerates to show the
# diff, then puts the file back exactly as it found it.
[[ "$(sha256sum "$root/checksums/SHA256SUMS" | awk '{print $1}')" == "$before" ]] \
    && ok "the manifest hint restores the manifest byte-for-byte" \
    || bad "the manifest hint left the manifest rewritten"
# It is a diagnostic, not a fix: the tree it ran on is still correctly rejected.
bash release/release-files.sh --root "$root" verify >/dev/null 2>&1 \
    && bad "running the hint made a stale manifest verify" \
    || ok "running the hint does not make a stale manifest verify"

# The suite's own last word. A remedy printed 300 assertions up the log is not
# where anyone looks; this asserts it is also emitted after the PASS/FAIL line.
grep -q 'MANIFEST_STALE=1' tests/run-tests.sh \
    && grep -q 'if (( MANIFEST_STALE )); then' tests/run-tests.sh \
    && ok "a stale manifest is flagged for the Results section" \
    || bad "the stale-manifest flag is no longer wired to the Results section"

section "Release rehearsal in CI"
# release.yml only runs on a tag push, so its checkout is detached, one commit
# deep, and carries a single tag. ci.yml is triggered by every push including
# that one, so it does see the shape -- but only at the moment the tag lands,
# which is after the version number has been spent and SECURITY.md forbids
# reusing it. That is how PASS: 233 FAIL: 4 reached the v2.2.1 release instead
# of a pull request. ci.yml's tag-checkout job manufactures the shape on every
# branch push and pull request; these assertions keep it from being quietly
# deleted or defanged.
#
# It rehearses the Git metadata a tag build sees. It is not a tag event: it does
# not reproduce GITHUB_REF_TYPE=tag, the event payload, the expression context
# release.yml reads github.ref_name from, the origin URL, the fetch refspec, or
# the checkout's authentication state.
#
# Every check here reads the workflows with comment lines removed. A command
# named only in a comment is not a command that runs.
rehearsal_drift=0
tag_job="$(grep -vE '^[[:space:]]*#' .github/workflows/ci.yml \
    | awk '/^  tag-checkout:$/{f=1; next} /^  [A-Za-z]/{f=0} f')"
if [[ -z "$tag_job" ]]; then
    bad "ci.yml has no tag-checkout job"
    rehearsal_drift=1
else
    while IFS='|' read -r label needle; do
        [[ -n "$label" ]] || continue
        grep -qF -- "$needle" <<< "$tag_job" \
            || { bad "the tag-checkout job does not $label"; rehearsal_drift=1; }
    done <<'REHEARSAL'
build a shallow single-tag clone|--depth 1 --branch
assert the clone is shallow|.git/shallow
run the release preflight|bash tools/release-preflight.sh
rehearse the tag check|--tag "v$(tr -d '[:space:]' < VERSION)"
REHEARSAL
    # The opt-in would hand the job every tag and hide the one shape it exists
    # to reproduce, so its absence is the assertion.
    if grep -qF -- 'SB_CHECK_PUBLISHED_TAGS' <<< "$tag_job"; then
        bad "the tag-checkout job sets SB_CHECK_PUBLISHED_TAGS, hiding the shape it tests"
        rehearsal_drift=1
    fi
fi
(( rehearsal_drift == 0 )) && ok "ci.yml rehearses the release under a tag-shaped checkout"

# What replaced the old cross-check, and why the old one is gone.
#
# It extracted "commands" from both workflows with an awk program over
# whitespace-split YAML text and asserted the release set was a subset of the CI
# set. Verified against that function on bf04bd0: it accepted
# `- name: run bash tools/gitleaks.sh path` and `run: echo "bash tools/x.sh"`,
# and could not see /usr/bin/bash, `bash -e`, an interpreter in a variable, a
# make target, a composite action or a reusable workflow. It also normalised
# arguments away, so `build-release.sh --skip-tests` counted as covering
# `build-release.sh`. A green result was not evidence of the property it named,
# and the one release-only step it could never see -- the inline tag check --
# is exactly the kind of thing it existed to catch.
#
# There is nothing left to prove by reading YAML, because there is one
# implementation: tools/release-preflight.sh. This asserts only that, and says
# so plainly. It is a guard against release.yml growing a second script, not a
# proof that CI runs everything release does. It can still be fooled by a
# preflight invocation that is echoed rather than run -- but then nothing in the
# job runs at all, which is not a subtle failure.
workflow_scripts() {  # repository scripts a workflow file names, comments aside
    grep -vE '^[[:space:]]*#' "$1" \
        | grep -oE '\b(tools|tests|release)/[A-Za-z0-9_.-]+\.sh' \
        | LC_ALL=C sort -u
}
# One function, used for the shipped file and for every fixture below, so the
# guard the suite reports on is the guard the fixtures exercise. It prints each
# violation it finds and nothing when the file is acceptable.
release_workflow_violations() {
    local file="$1" body scripts named runs uses
    body="$(grep -vE '^[[:space:]]*#' "$file")"
    scripts="$(grep -oE '\b(tools|tests|release)/[A-Za-z0-9_.-]+\.sh' <<< "$body" \
        | LC_ALL=C sort -u | tr '\n' ' ')"
    [[ "$scripts" == "tools/release-preflight.sh " ]] \
        || printf 'invokes [%s] instead of only the preflight\n' "${scripts% }"
    # A script named in a step label runs nothing. That evasion satisfied the
    # extractor this guard replaced.
    named="$(grep -E '^[[:space:]]*-?[[:space:]]*name:' <<< "$body" \
        | grep -oE '\b(tools|tests|release)/[A-Za-z0-9_.-]+\.sh' | LC_ALL=C sort -u | tr '\n' ' ')"
    [[ -z "$named" ]] || printf 'names [%s] in a step label, which runs nothing\n' "${named% }"
    # A script path is not the only way to add a release-only step: `make
    # release`, a composite action and a reusable workflow all name no .sh file.
    # Counting the steps closes that, and is a claim this file's shape supports:
    # release.yml is a checkout, one run:, and one upload.
    runs="$(grep -cE '^[[:space:]]*-?[[:space:]]*run:' <<< "$body" || true)"
    [[ "$runs" == 1 ]] || printf 'has %s run: steps; a release-only one cannot be ruled out\n' "$runs"
    uses="$(grep -oE '^[[:space:]]*-?[[:space:]]*uses:[[:space:]]*\S+' <<< "$body" \
        | sed -E 's|.*uses:[[:space:]]*||; s|@.*||' | LC_ALL=C sort -u | tr '\n' ' ')"
    [[ "$uses" == "actions/checkout softprops/action-gh-release " ]] \
        || printf 'uses [%s]; a new action is a release-only code path\n' "${uses% }"
}
release_violations="$(release_workflow_violations .github/workflows/release.yml)"
[[ -z "$release_violations" ]] \
    && ok "release.yml runs exactly one repository script, the preflight, and nothing else" \
    || bad "release.yml ${release_violations//$'\n'/; }"
workflow_scripts .github/workflows/ci.yml | grep -qFx tools/release-preflight.sh \
    && ok "ci.yml runs the same preflight script" \
    || bad "ci.yml does not run tools/release-preflight.sh"
# The inline tag check moved into a script that takes the candidate as an
# argument, so it is testable and so ci.yml can rehearse it.
grep -qF "tr -d '[:space:]' < VERSION" .github/workflows/release.yml \
    && bad "release.yml still verifies the tag inline instead of through the preflight" \
    || ok "the tag check is a script, not inline release-only shell"
# And the text extractor cannot come back: it is the thing that created false
# confidence, and a narrower version of it would create less of it, not none.
grep -qE '^workflow_commands\(\)' tests/run-tests.sh \
    && bad "the YAML command-text extractor is back in tests/run-tests.sh" \
    || ok "no YAML command-text extractor in the suite"

# The guard, against fixture workflows -- including every evasion that defeated
# its predecessor.
release_guard() {  # label, expect (accept|reject), file
    local label="$1" expect="$2" file="$3" violations
    violations="$(release_workflow_violations "$file")"
    if [[ -z "$violations" ]]; then
        [[ "$expect" == accept ]] && ok "the release-workflow guard accepts $label" \
            || bad "the release-workflow guard accepted $label"
    else
        [[ "$expect" == reject ]] && ok "the release-workflow guard rejects $label" \
            || bad "the release-workflow guard rejected $label: $violations"
    fi
}
guard_fixture="$TMP/release-fixture.yml"
restore_guard_fixture() { cp .github/workflows/release.yml "$guard_fixture"; }
restore_guard_fixture
release_guard "the shipped release.yml" accept "$guard_fixture"
printf '      - run: bash tools/other-thing.sh\n' >> "$guard_fixture"
release_guard "a second script" reject "$guard_fixture"
restore_guard_fixture
printf '      - run: /usr/bin/bash tools/other-thing.sh\n' >> "$guard_fixture"
release_guard "a second script run through an absolute interpreter path" reject "$guard_fixture"
restore_guard_fixture
printf '      - run: make release-extra\n' >> "$guard_fixture"
release_guard "a make target, which names no script" reject "$guard_fixture"
restore_guard_fixture
printf '      - uses: ./.github/actions/extra\n' >> "$guard_fixture"
release_guard "a composite action" reject "$guard_fixture"
restore_guard_fixture
printf '      - uses: ./.github/workflows/extra.yml\n' >> "$guard_fixture"
release_guard "a reusable workflow" reject "$guard_fixture"
restore_guard_fixture
sed -i '/bash tools\/release-preflight.sh/d' "$guard_fixture"
release_guard "the preflight removed" reject "$guard_fixture"
restore_guard_fixture
sed -i 's|^\( *\)run: bash tools/release-preflight.sh.*|\1name: run bash tools/release-preflight.sh|' "$guard_fixture"
release_guard "a preflight named in a step label but never run" reject "$guard_fixture"

# The tag check itself, offline, against a scratch VERSION file.
tag_check_drift=0
printf '2.2.2\n' > "$TMP/VERSION-fixture"
while IFS='|' read -r candidate expected; do
    [[ -n "$candidate" || "$expected" == 2 ]] || continue
    actual=0
    bash tools/check-release-tag.sh "$candidate" "$TMP/VERSION-fixture" >/dev/null 2>&1 || actual=$?
    [[ "$actual" == "$expected" ]] \
        || { bad "check-release-tag '$candidate' exited $actual, expected $expected"; tag_check_drift=1; }
done <<'TAGS'
v2.2.2|0
v2.2.3|1
v3.0.0|1
2.2.2|2
v2.2|2
v2.2.2.1|2
v2.2.2-rc1|2
v2.2.2+build1|2
refs/tags/v2.2.2|2
v02.2.2|2
V2.2.2|2
v2.2.2 |2
|2
TAGS
(( tag_check_drift == 0 )) && ok "the release tag check accepts only an exact, well-formed match"
# A prerelease has never been published here, and accepting one would let it
# publish as if it were the release. Keep the refusal explicit.
prerelease_out="$(bash tools/check-release-tag.sh v2.2.2-rc1 "$TMP/VERSION-fixture" 2>&1 || true)"
grep -qF 'expected v<major>.<minor>.<patch> with no suffix' <<< "$prerelease_out" \
    && ok "a prerelease tag is refused with a reason" \
    || bad "prerelease refusal message: $prerelease_out"
# And against the repository's own VERSION, which is what release.yml passes.
bash tools/check-release-tag.sh "v$(tr -d '[:space:]' < VERSION)" >/dev/null 2>&1 \
    && ok "the current VERSION has a valid release tag form" \
    || bad "v$(tr -d '[:space:]' < VERSION) is not accepted by the tag check"

# Workflow syntax is validated by a YAML-aware linter, pinned and checksum
# verified the same way the secret scanner is, rather than by regexes here.
actionlint_drift=0
grep -qF 'bash tools/actionlint.sh run' .github/workflows/ci.yml \
    || { bad "ci.yml does not run actionlint"; actionlint_drift=1; }
grep -qE '^ACTIONLINT_VERSION=[0-9]+\.[0-9]+\.[0-9]+$' tools/actionlint.sh \
    || { bad "actionlint is not pinned to an exact version"; actionlint_drift=1; }
grep -qE '^ACTIONLINT_SHA256_LINUX_X64=[0-9a-f]{64}$' tools/actionlint.sh \
    || { bad "the actionlint download is not checksum-pinned"; actionlint_drift=1; }
grep -qF 'sha256sum --check --status' tools/actionlint.sh \
    || { bad "actionlint.sh does not verify the archive it downloads"; actionlint_drift=1; }
(( actionlint_drift == 0 )) && ok "workflows are linted by a pinned, verified actionlint"

# The preflight is the thing both workflows call, so its own sequence is the
# release contract. Assert it still contains every gate rather than trusting
# that moving a step out of a workflow moved it into here.
preflight_drift=0
while IFS='|' read -r label needle; do
    [[ -n "$label" ]] || continue
    grep -qF -- "$needle" tools/release-preflight.sh \
        || { bad "the release preflight no longer $label"; preflight_drift=1; }
done <<'PREFLIGHT'
checks the candidate tag|tools/check-release-tag.sh
resolves the pinned scanner|tools/gitleaks.sh" path
runs the reproducible build|release/build-release.sh
scans the artifacts before upload|scan-artifacts release/dist
PREFLIGHT
(( preflight_drift == 0 )) && ok "the release preflight still runs every pre-publication gate"

section "Workflow supply chain: immutable action pins and least privilege"
# Every uses: in this repository pointed at a mutable major tag, including the
# two steps in the job that holds contents: write. A tag is a pointer: the owner
# -- or anyone who compromises the owner's account -- can move it to different
# code, and the next run picks that code up with no diff here and no review.
# Pinning to a commit SHA is what makes "what ran" a reviewable fact. See #27.
#
# The version comment is not decoration: it is what a reader and Dependabot both
# use to tell which release a SHA is, so a pin without one is only half a pin.
workflow_uses_violations() {
    local file="$1" line ref
    while IFS= read -r line; do
        ref="${line#*uses:}"; ref="${ref#"${ref%%[![:space:]]*}"}"; ref="${ref%%[[:space:]]*}"
        # A local action (./…) has no upstream to pin; nothing here uses one,
        # and the release-workflow guard rejects adding one.
        [[ "$ref" == ./* ]] && { printf '%s: local action %s\n' "$file" "$ref"; continue; }
        if [[ ! "$ref" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+@[0-9a-f]{40}$ ]]; then
            printf '%s: %s is not pinned to a full commit SHA\n' "$file" "$ref"
            continue
        fi
        grep -qE "uses:[[:space:]]*${ref//\//\\/}[[:space:]]+# v[0-9]" <<< "$line" \
            || printf '%s: %s has no version comment\n' "$file" "$ref"
    done < <(grep -vE '^[[:space:]]*#' "$file" | grep -E '^[[:space:]]*-?[[:space:]]*uses:' \
        | sed -E 's/^[[:space:]]*-?[[:space:]]*/  /')
}
uses_drift=0
for workflow in .github/workflows/*.yml; do
    while IFS= read -r violation; do
        [[ -n "$violation" ]] || continue
        bad "action pin: $violation"; uses_drift=1
    done < <(workflow_uses_violations "$workflow")
done
(( uses_drift == 0 )) && ok "every action is pinned to a full commit SHA with a version comment"

# The shape check against fixtures, because the assertion above passes trivially
# on a file with no uses: at all.
uses_fixture="$TMP/uses-fixture.yml"
uses_guard() {  # label, expect (accept|reject), line
    printf 'jobs:\n  j:\n    steps:\n      - uses: %s\n' "$3" > "$uses_fixture"
    if [[ -z "$(workflow_uses_violations "$uses_fixture")" ]]; then
        [[ "$2" == accept ]] && ok "the action-pin guard accepts $1" \
            || bad "the action-pin guard accepted $1"
    else
        [[ "$2" == reject ]] && ok "the action-pin guard rejects $1" \
            || bad "the action-pin guard rejected $1"
    fi
}
uses_guard "a full SHA with a version comment" accept \
    'actions/checkout@1111111111111111111111111111111111111111  # v4.4.0'
uses_guard "a mutable major tag" reject 'actions/checkout@v4'
uses_guard "a branch" reject 'actions/checkout@main'
uses_guard "a short SHA" reject 'actions/checkout@1111111  # v4.4.0'
uses_guard "a full SHA with no version comment" reject \
    'actions/checkout@1111111111111111111111111111111111111111'
uses_guard "a local composite action" reject './.github/actions/thing'

# Least privilege, per job rather than per file: a second job added to
# release.yml must start with no write access rather than inheriting it.
perm_drift=0
for workflow in .github/workflows/*.yml; do
    grep -qE '^permissions:' "$workflow" \
        && { bad "$workflow grants permissions at the workflow level"; perm_drift=1; }
    while IFS= read -r job; do
        [[ -n "$job" ]] || continue
        block="$(grep -vE '^[[:space:]]*#' "$workflow" \
            | awk -v want="  $job:" '$0 == want {f=1; next} /^  [A-Za-z]/{f=0} f')"
        grep -qE '^    permissions:' <<< "$block" \
            || { bad "$workflow job '$job' declares no permissions"; perm_drift=1; }
        if grep -qE '^      contents:[[:space:]]*write' <<< "$block"; then
            [[ "$workflow:$job" == ".github/workflows/release.yml:publish" ]] \
                || { bad "$workflow job '$job' takes contents: write"; perm_drift=1; }
        fi
    done < <(grep -vE '^[[:space:]]*#' "$workflow" \
        | awk '/^jobs:$/{f=1; next} /^[A-Za-z]/{f=0} f' \
        | sed -nE 's/^  ([A-Za-z][A-Za-z0-9_-]*):$/\1/p')
done
grep -qE '^      contents:[[:space:]]*write' .github/workflows/release.yml \
    || { bad "the publish job cannot upload without contents: write"; perm_drift=1; }
(( perm_drift == 0 )) && ok "every job declares its permissions and only publish can write"

# pull_request_target runs with the base repository's secrets and a writable
# token; combining it with a checkout of pull-request head content is the
# standard way a repository gets compromised, and actions/checkout v7 blocks
# that combination for exactly this reason. #41 considered a bot-facing
# automation that would have needed it and rejected the option. Nothing here
# uses the trigger, and this asserts nothing quietly starts.
if grep -lq 'pull_request_target' .github/workflows/*.yml 2>/dev/null; then
    bad "a workflow uses pull_request_target"
else
    ok "no workflow uses pull_request_target"
fi

# The #41 remedy step is a diagnostic, not a gate. It must stay conditional on
# failure -- promoted to an unconditional step it would run on green builds, and
# made part of the suite it could start deciding whether a run passes.
if grep -q 'bash tools/manifest-fix-hint.sh' .github/workflows/ci.yml; then
    grep -B2 'bash tools/manifest-fix-hint.sh' .github/workflows/ci.yml | grep -q 'if: failure()' \
        && ok "the stale-manifest hint runs only after a failure" \
        || bad "the stale-manifest hint is no longer conditional on failure"
else
    bad "ci.yml no longer runs the stale-manifest hint"
fi

# No job here performs an authenticated Git operation after checkout, so none
# needs the token left in .git/config. The tag-checkout job clones
# file://$GITHUB_WORKSPACE, which needs no credentials at all.
cred_drift=0
for workflow in .github/workflows/*.yml; do
    while IFS= read -r finding; do
        [[ -n "$finding" ]] || continue
        bad "$workflow: $finding"; cred_drift=1
    done < <(grep -vE '^[[:space:]]*#' "$workflow" | awk '
        /uses:[[:space:]]*actions\/checkout@/ { pending = 1; seen = 0; next }
        pending && /^[[:space:]]*-[[:space:]]/ {
            if (!seen) print "a checkout does not set persist-credentials: false"
            pending = 0
        }
        pending && /persist-credentials:[[:space:]]*false/ { seen = 1 }
        END { if (pending && !seen) print "a checkout does not set persist-credentials: false" }
    ')
done
(( cred_drift == 0 )) && ok "no checkout leaves a token in .git/config"

# The upload authenticates through its own input, which is what makes the line
# above safe to assert rather than hope about.
grep -qF 'token: ${{ secrets.GITHUB_TOKEN }}' .github/workflows/release.yml \
    && ok "the release upload names its token explicitly" \
    || bad "the release upload relies on an implicit token"

# A pin with no update channel is a pin that rots.
dependabot_drift=0
if [[ ! -f .github/dependabot.yml ]]; then
    bad "no .github/dependabot.yml, so nothing proposes action updates"
    dependabot_drift=1
else
    while IFS='|' read -r label needle; do
        [[ -n "$label" ]] || continue
        grep -qE -- "$needle" .github/dependabot.yml \
            || { bad "dependabot.yml does not $label"; dependabot_drift=1; }
    done <<'DEPENDABOT'
declare the v2 schema|^version: 2$
watch the github-actions ecosystem|package-ecosystem:[[:space:]]*["'\'']?github-actions
check on a schedule|interval:[[:space:]]*(daily|weekly|monthly)
DEPENDABOT
fi
(( dependabot_drift == 0 )) && ok "Dependabot proposes action updates against the pins"

section "Weekly pin-drift workflow"
# Pin drift is only found when somebody runs the check, and between releases
# nobody does. The weekly job could not be built on the old --check: it exited 1
# permanently because of the branch-head row, and 0 when every resolver failed.
# With the exit codes #25 established it can tell three cases apart, and the
# branch on each is a pure function driven here without a network or a token.
# See #28.
drift_opts_before="$-"
# shellcheck source=tools/pin-drift-report.sh
source tools/pin-drift-report.sh
[[ "$-" == "$drift_opts_before" ]] \
    && ok "sourcing pin-drift-report.sh does not change shell options" \
    || bad "sourcing pin-drift-report.sh changed shell options"
grep -qF '[[ "${BASH_SOURCE[0]}" != "$0" ]] || pin_drift_main "$@"' tools/pin-drift-report.sh \
    && ok "pin-drift-report.sh has a main guard, so sourcing it calls no API" \
    || bad "pin-drift-report.sh has no main guard"

# Every combination of (refresh-pins exit, is an issue already open). The two
# that matter: exit 0 with no issue files nothing at all, and exit 3 files the
# issue *and* fails the run -- a check that could not check must not show a
# green tick.
drift_drift=0
while IFS='|' read -r code has_issue expect_action expect_run; do
    [[ -n "$code" ]] || continue
    actual_run=green
    actual_action="$(pin_drift_action "$code" "$has_issue")" || actual_run=red
    [[ "$actual_action" == "$expect_action" && "$actual_run" == "$expect_run" ]] \
        || { bad "pin-drift(exit $code, issue $has_issue) = $actual_action/$actual_run, expected $expect_action/$expect_run"; drift_drift=1; }
done <<'DRIFT'
0|no|nothing|green
0|yes|close|green
1|no|create|green
1|yes|update|green
3|no|create|red
3|yes|update|red
2|no|fail|red
2|yes|fail|red
99|no|fail|red
DRIFT
(( drift_drift == 0 )) && ok "the drift workflow files one issue only for actionable release drift"

# The UNKNOWN banner is the visible half of "never a false green".
printf 'nodejs 24.21.0 unknown UNKNOWN\n' > "$TMP/drift-report.txt"
unknown_body="$(pin_drift_body 3 "$TMP/drift-report.txt")"
stale_body="$(pin_drift_body 1 "$TMP/drift-report.txt")"
grep -qF 'This report is incomplete' <<< "$unknown_body" \
    && ok "an UNKNOWN result says so at the top of the issue" \
    || bad "an UNKNOWN result is reported as an ordinary drift issue"
grep -qF 'This report is incomplete' <<< "$stale_body" \
    && bad "an ordinary drift issue carries the UNKNOWN banner" \
    || ok "an ordinary drift issue carries no UNKNOWN banner"
grep -qF 'nodejs 24.21.0 unknown UNKNOWN' <<< "$stale_body" \
    && ok "the issue body quotes the report verbatim" || bad "the issue body drops the report"

# The workflow itself. It is scheduled, it can be dispatched by hand, it holds
# only the permission it needs, and it must never rewrite a pin: a bump needs a
# CHANGELOG entry and a human reading the upstream diff.
drift_workflow=.github/workflows/pin-drift.yml
workflow_drift=0
if [[ ! -f "$drift_workflow" ]]; then
    bad "no weekly pin-drift workflow"
    workflow_drift=1
else
    drift_body="$(grep -vE '^[[:space:]]*#' "$drift_workflow")"
    while IFS='|' read -r label needle; do
        [[ -n "$label" ]] || continue
        grep -qE -- "$needle" <<< "$drift_body" \
            || { bad "the pin-drift workflow does not $label"; workflow_drift=1; }
    done <<'DRIFTWF'
run on a schedule|^[[:space:]]+- cron:
allow a manual run|^[[:space:]]*workflow_dispatch:
grant issues: write|^[[:space:]]+issues:[[:space:]]*write$
bound its runtime|^[[:space:]]+timeout-minutes:[[:space:]]*[0-9]+$
run the check|refresh-pins\.sh --check
hand the result to the reporter|pin-drift-report\.sh
DRIFTWF
    grep -qE 'refresh-pins\.sh[^|]*--write' <<< "$drift_body" \
        && { bad "the pin-drift workflow can rewrite pins"; workflow_drift=1; }
    grep -qE '^[[:space:]]+contents:[[:space:]]*write$' <<< "$drift_body" \
        && { bad "the pin-drift workflow takes contents: write"; workflow_drift=1; }
    # The report is upstream-controlled text. It reaches the issue through a
    # file, never through a command line.
    grep -qF -- '--body-file' tools/pin-drift-report.sh \
        || { bad "the drift report is interpolated into a command instead of a file"; workflow_drift=1; }
fi
(( workflow_drift == 0 )) && ok "the pin-drift workflow reports weekly and cannot write"

section "Fitness: documentation says what the code does"
# Three claims in this repository were true when written and stopped being true
# without anything noticing: the --write file list, the CHANGELOG's explanation
# of why a bug was undetectable, and what "checksum-verified" covers. See #29.

# 1. The --write file list. tools/write-pins.py is the writer, so the files it
# names are the answer; three prose lists have to agree with it. checksums/*.txt
# collapses to the directory, which is how all three write it.
doc_list_drift=0
while IFS= read -r target; do
    [[ -n "$target" ]] || continue
    [[ "$target" == checksums/* ]] && target=checksums/
    while IFS='|' read -r where file; do
        [[ -n "$where" ]] || continue
        grep -qF -- "$target" "$file" \
            || { bad "$where does not name $target, which tools/write-pins.py rewrites"; doc_list_drift=1; }
    done <<'LISTS'
README.md's --write paragraph|README.md
docs/CONFIGURATION.md|docs/CONFIGURATION.md
the refresh-pins.sh banner|tools/refresh-pins.sh
LISTS
done < <(grep -oE '"[A-Za-z0-9_./-]+\.(sh|md|env|txt|py)"' tools/write-pins.py \
    | tr -d '"' | LC_ALL=C sort -u)
(( doc_list_drift == 0 )) && ok "every file --write rewrites is named everywhere --write is documented"
# And nothing may claim the rewrite is atomic across files: it validates every
# substitution before the first write, but the writes are per file.
grep -qiF 'atomic across' tools/write-pins.py \
    && grep -qiF 'atomic across' docs/CONFIGURATION.md \
    && ok "the rewrite's guarantee is stated as validation, not atomicity" \
    || bad "the multi-file rewrite is described as atomic somewhere"

# 2. CHANGELOG. An Unreleased heading is what stops the next merged change going
# unrecorded, which is how #20, #21 and #22 came to be recorded nowhere.
changelog_drift=0
first_heading="$(grep -m1 '^## ' CHANGELOG.md)"
[[ "$first_heading" == "## Unreleased" ]] \
    || { bad "CHANGELOG.md's first section is '$first_heading', not Unreleased"; changelog_drift=1; }
declared="$(tr -d '[:space:]' < VERSION)"
grep -qF "## $declared" CHANGELOG.md \
    || { bad "CHANGELOG.md has no section for the released version $declared"; changelog_drift=1; }
# The 2.2.2 notes explain the bug by saying every CI job checks out a branch.
# #22 made that false. The sentence stays as history; the correction has to be
# next to it, or the release notes read as current fact.
if grep -qF 'Every CI job checks out a branch' CHANGELOG.md; then
    grep -qF 'Corrected 2026-09-12' CHANGELOG.md \
        || { bad "CHANGELOG.md still claims every CI job checks out a branch, uncorrected"; changelog_drift=1; }
fi
(( changelog_drift == 0 )) && ok "CHANGELOG.md has an Unreleased section and no uncorrected claim"

# 3. "Checksum-verified" covers Node.js, uv and gh, whose downloaded artifacts
# are checked against SHA-256 values pinned here. It does not cover the AI CLIs:
# lib/bootstrap/ai_cli.sh runs one npm install at exact versions and then reads
# the installed package.json back. That is a real guarantee, from npm and the
# registry, but a different one.
grep -qiE 'sha256|checksum' lib/bootstrap/ai_cli.sh \
    && bad "lib/bootstrap/ai_cli.sh now has a checksum path; the documentation split needs revisiting" \
    || ok "the AI CLI installer still has no checksum path, as the docs now say"
# A literal check, so it is brittle to rewording on purpose: each of these
# sentences claimed a repository checksum covers the npm CLIs.
claim_drift=0
while IFS='|' read -r file phrase; do
    [[ -n "$file" ]] || continue
    grep -qF -- "$phrase" "$file" \
        && { bad "$file still claims: $phrase"; claim_drift=1; }
done <<'CLAIMS'
README.md|checksum-verified before use
README.md|Tools pinned to a checksummed upstream release
docs/CONFIGURATION.md|Tools that are pinned to a checksummed upstream release
CLAIMS
grep -qF 'integrity comes from npm and the registry' README.md \
    || { bad "README.md does not say where the AI CLIs' integrity comes from"; claim_drift=1; }
grep -qF 'no SHA-256' docs/CONFIGURATION.md \
    || { bad "docs/CONFIGURATION.md does not distinguish the two guarantees"; claim_drift=1; }
(( claim_drift == 0 )) && ok "no document claims a repository checksum covers the npm CLIs"

section "History-preservation policy"
# The policy is only useful if it is discoverable and specific. These assert the
# document exists, names the operations it forbids, and is linked from the
# places a contributor actually looks.
[[ -s SECURITY.md ]] && ok "SECURITY.md is present" || bad "SECURITY.md is missing"
while IFS='|' read -r label needle; do
    [[ -n "$label" ]] || continue
    grep -Fqi -- "$needle" SECURITY.md \
        && ok "policy names $label" \
        || bad "policy does not name $label"
done <<'POLICY'
git filter-repo|filter-repo
git filter-branch|filter-branch
BFG|BFG
force-push|force-push
tag replacement|release tag
credential rotation|Rotate first
the no-key-shaped-fixture rule|Never commit a key-shaped string
POLICY
grep -Fq '](SECURITY.md)' README.md \
    && ok "README links to SECURITY.md" || bad "README does not link to SECURITY.md"
grep -Fq 'SECURITY.md' docs/SECURITY-SCANNING.md \
    && ok "the scanning guide links to SECURITY.md" \
    || bad "the scanning guide does not link to SECURITY.md"

# The policy forbids rewriting published history, so the tags that existed when
# it was written must still resolve. Opt-in, because only some checkouts can
# answer the question: a tag checkout (what release.yml does) carries exactly
# the one tag being built, and a shallow clone carries none. Presence of *a* tag
# is not evidence that the full set was fetched -- treating it as such made this
# check fail the release build for four tags the checkout was never given.
if [[ "${SB_CHECK_PUBLISHED_TAGS:-0}" == 1 ]]; then
    tag_loss=0
    for tag in v1.4.0 v2.0.0 v2.0.1 v2.1.0; do
        git rev-parse -q --verify "refs/tags/$tag" >/dev/null \
            || { bad "published tag is missing: $tag"; tag_loss=1; }
    done
    (( tag_loss == 0 )) && ok "every published release tag still resolves"
else
    skip "published tag check (set SB_CHECK_PUBLISHED_TAGS=1 in a checkout with tags)"
fi

section "Package command compatibility aliases"
# shellcheck source=/dev/null
source lib/bootstrap/packages.sh
ALIAS_FIX="$TMP/command-aliases"
mkdir -p "$ALIAS_FIX/source" "$ALIAS_FIX/bin"
cat > "$ALIAS_FIX/source/fdfind" <<'COMMAND'
#!/usr/bin/env bash
exit 0
COMMAND
chmod 0755 "$ALIAS_FIX/source/fdfind"
sb_warn(){ :; }

alias_rc_first=0
PATH="$ALIAS_FIX/bin:$ALIAS_FIX/source:/usr/bin:/bin" \
BOOTSTRAP_LOCAL_BIN_DIR="$ALIAS_FIX/bin" \
    bootstrap_ensure_command_alias fdfind fd || alias_rc_first=$?
if [[ "$alias_rc_first" == 0 && -L "$ALIAS_FIX/bin/fd" \
    && "$(readlink "$ALIAS_FIX/bin/fd")" == "$ALIAS_FIX/source/fdfind" ]]; then
    ok "fdfind compatibility alias is created"
else bad "fdfind compatibility alias creation"; fi

alias_rc_rerun=0
PATH="$ALIAS_FIX/bin:$ALIAS_FIX/source:/usr/bin:/bin" \
BOOTSTRAP_LOCAL_BIN_DIR="$ALIAS_FIX/bin" \
    bootstrap_ensure_command_alias fdfind fd || alias_rc_rerun=$?
[[ "$alias_rc_rerun" == 0 ]] \
    && ok "existing compatibility alias is idempotent" \
    || bad "existing compatibility alias rerun"

alias_rc_missing=0
PATH="$ALIAS_FIX/bin:/usr/bin:/bin" \
BOOTSTRAP_LOCAL_BIN_DIR="$ALIAS_FIX/bin" \
    bootstrap_ensure_command_alias missing-command missing-alias || alias_rc_missing=$?
[[ "$alias_rc_missing" == 0 && ! -e "$ALIAS_FIX/bin/missing-alias" ]] \
    && ok "missing alias source warns without aborting" \
    || bad "missing alias source handling"

section "Package manifest"
PKG_FIX="$TMP/packages"; mkdir -p "$PKG_FIX"
cat > "$PKG_FIX/manifest.txt" <<'MANIFEST'
# leading comment
[required]
alpha
bravo    # trailing comment

charlie

[optional]
delta
MANIFEST
[[ "$(bootstrap_read_package_section "$PKG_FIX/manifest.txt" required | tr '\n' ' ')" == "alpha bravo charlie " ]] \
    && ok "manifest [required] parsing skips comments and blanks" \
    || bad "manifest [required] parsing"
[[ "$(bootstrap_read_package_section "$PKG_FIX/manifest.txt" optional | tr '\n' ' ')" == "delta " ]] \
    && ok "manifest [optional] parsing is section-scoped" \
    || bad "manifest [optional] parsing"
[[ -z "$(bootstrap_read_package_section "$PKG_FIX/manifest.txt" nosuchsection)" ]] \
    && ok "unknown manifest section yields nothing" || bad "unknown manifest section"

# A package name is interpolated straight onto the apt command line, so the
# validator is a security boundary and not just a typo check.
pkg_name_ok=1
for name in libssl-dev g++ python3.12 p7zip-full node.js-x; do
    bootstrap_valid_package_name "$name" || { bad "valid package name rejected: $name"; pkg_name_ok=0; }
done
for name in '' 'UPPER' '-leading' 'semi;rm -rf /' 'with space' 'sub$(id)' 'under_score'; do
    bootstrap_valid_package_name "$name" && { bad "invalid package name accepted: $name"; pkg_name_ok=0; }
done
(( pkg_name_ok == 1 )) && ok "package name validation accepts and rejects correctly"

manifest_bad=0
while IFS= read -r name; do
    bootstrap_valid_package_name "$name" || { bad "invalid name in shipped manifest: $name"; manifest_bad=1; }
done < <(bootstrap_read_package_section config/packages.txt required
         bootstrap_read_package_section config/packages.txt optional)
(( manifest_bad == 0 )) && ok "shipped package manifest contains only valid names"
[[ "$( { bootstrap_read_package_section config/packages.txt required
         bootstrap_read_package_section config/packages.txt optional; } | sort | uniq -d | wc -l)" == 0 ]] \
    && ok "shipped package manifest has no duplicates" || bad "duplicate package in manifest"
[[ "$(bootstrap_read_package_section config/packages.txt required | wc -l)" -ge 40 ]] \
    && ok "shipped manifest keeps a substantial [required] set" || bad "manifest [required] shrank unexpectedly"

section "Generic bundle installation"
FIX="$TMP/fix"; mkdir -p "$FIX/src/demo-1.0.0"
printf '1.0.0\n' > "$FIX/src/demo-1.0.0/VERSION"
cat > "$FIX/src/demo-1.0.0/install.sh" <<'INSTALL'
#!/usr/bin/env bash
set -e
printf '%s\n' "$*" > "$DEMO_MARK"
INSTALL
chmod 0755 "$FIX/src/demo-1.0.0/install.sh"
tar -czf "$FIX/demo-1.0.0.tar.gz" -C "$FIX/src" demo-1.0.0
sha256sum "$FIX/demo-1.0.0.tar.gz" > "$FIX/demo.sha256"
STATE="$FIX/state"; MARK="$FIX/mark"
if DEMO_MARK="$MARK" STATE_ROOT="$STATE" ./server-bundle-install \
    --name demo --version 1.0.0 --archive "$FIX/demo-1.0.0.tar.gz" \
    --sha256-file "$FIX/demo.sha256" -- --alpha beta >/dev/null; then
    ok "valid bundle installs"
else bad "valid bundle install failed"; fi
[[ "$(cat "$MARK" 2>/dev/null)" == '--alpha beta' ]] && ok "installer args preserved" || bad "installer args"
[[ "$(cat "$STATE/bundles/demo/version" 2>/dev/null)" == 1.0.0 ]] && ok "version state" || bad "version state"
[[ -s "$STATE/bundles/demo/archive-sha256" ]] && ok "archive hash state" || bad "archive hash state"

rm -f "$MARK"
if DEMO_MARK="$MARK" STATE_ROOT="$STATE" ./server-bundle-install \
    --name demo --version 1.0.0 --archive "$FIX/demo-1.0.0.tar.gz" \
    --sha256-file "$FIX/demo.sha256" >/dev/null && [[ ! -e "$MARK" ]]; then
    ok "same version and hash is skipped"
else bad "idempotent skip"; fi

cp "$FIX/demo-1.0.0.tar.gz" "$FIX/delete-me.tar.gz"
sha256sum "$FIX/delete-me.tar.gz" > "$FIX/delete-me.sha256"
if DEMO_MARK="$FIX/delete-mark" STATE_ROOT="$FIX/delete-state" ./server-bundle-install \
    --name delete-demo --version 1.0.0 --archive "$FIX/delete-me.tar.gz" \
    --sha256-file "$FIX/delete-me.sha256" --delete-after-success >/dev/null \
    && [[ ! -e "$FIX/delete-me.tar.gz" && ! -e "$FIX/delete-me.sha256" ]]; then
    ok "archive and sidecar deleted after success"
else bad "success cleanup"; fi

cp "$FIX/demo-1.0.0.tar.gz" "$FIX/fail.tar.gz"
sha256sum "$FIX/fail.tar.gz" > "$FIX/fail.sha256"
mkdir -p "$FIX/badsrc/bad-1.0.0"; printf '1.0.0\n' > "$FIX/badsrc/bad-1.0.0/VERSION"
cat > "$FIX/badsrc/bad-1.0.0/install.sh" <<'BAD'
#!/usr/bin/env bash
exit 7
BAD
chmod +x "$FIX/badsrc/bad-1.0.0/install.sh"
tar -czf "$FIX/fail.tar.gz" -C "$FIX/badsrc" bad-1.0.0
sha256sum "$FIX/fail.tar.gz" > "$FIX/fail.sha256"
if STATE_ROOT="$FIX/fail-state" ./server-bundle-install --name fail-demo --version 1.0.0 \
    --archive "$FIX/fail.tar.gz" --sha256-file "$FIX/fail.sha256" \
    --delete-after-success >/dev/null 2>&1; then
    bad "failing installer accepted"
elif [[ -e "$FIX/fail.tar.gz" && -e "$FIX/fail.sha256" && ! -e "$FIX/fail-state/bundles/fail-demo/version" ]]; then
    ok "failed install retains archive and writes no state"
else bad "failure retention/state"; fi

section "Archive safety"
python3 - "$TMP" <<'PY'
import io, os, tarfile, sys
root=sys.argv[1]
with tarfile.open(os.path.join(root,'traversal.tar.gz'),'w:gz') as t:
    data=b'x'; info=tarfile.TarInfo('../escape'); info.size=len(data); t.addfile(info,io.BytesIO(data))
with tarfile.open(os.path.join(root,'symlink.tar.gz'),'w:gz') as t:
    d=tarfile.TarInfo('pkg'); d.type=tarfile.DIRTYPE; t.addfile(d)
    v=b'1.0.0\n'; vi=tarfile.TarInfo('pkg/VERSION'); vi.size=len(v); t.addfile(vi,io.BytesIO(v))
    i=b'#!/usr/bin/env bash\nexit 0\n'; ii=tarfile.TarInfo('pkg/install.sh'); ii.mode=0o755; ii.size=len(i); t.addfile(ii,io.BytesIO(i))
    s=tarfile.TarInfo('pkg/escape'); s.type=tarfile.SYMTYPE; s.linkname='../../etc/passwd'; t.addfile(s)
PY
mkdir -p "$TMP/xz-src/pkg"; printf 'ok\n' > "$TMP/xz-src/pkg/value.txt"
tar -cJf "$TMP/valid.tar.xz" -C "$TMP/xz-src" pkg
if bash -c 'set -e; source lib/archive.sh; sb_extract_archive "$1" "$2" >/dev/null; [[ "$(cat "$2/pkg/value.txt")" == ok ]]' _ \
    "$TMP/valid.tar.xz" "$TMP/xz-out"; then
    ok "valid tar.xz extracts safely"
else bad "tar.xz extraction"; fi

for kind in traversal symlink; do
    sha256sum "$TMP/$kind.tar.gz" > "$TMP/$kind.sha256"
    if STATE_ROOT="$TMP/$kind-state" ./server-bundle-install --name "$kind" --version 1.0.0 \
        --archive "$TMP/$kind.tar.gz" --sha256-file "$TMP/$kind.sha256" >/dev/null 2>&1; then
        bad "$kind archive accepted"
    else ok "$kind archive rejected"; fi
done

section "Provision plan parsing"
PLAN_DIR="$TMP/plan"; mkdir -p "$PLAN_DIR"
cat > "$PLAN_DIR/plan.sh" <<'PLAN'
register_bootstrap ./base.tar.gz ./base.sha256
register_bundle first 1.0.0 ./first.tar.gz ./first.sha256 install.sh --one
register_bundle second 2.0.0 ./second.tar.gz ./second.sha256 install.sh --two
PLAN
output="$(./server-provision.sh --plan "$PLAN_DIR/plan.sh" --dry-run)"
[[ "$output" == *'Bundles: 2'* ]] && ok "dry-run counts bundles" || bad "dry-run count"
first_line="$(printf '%s\n' "$output" | grep -n 'first 1.0.0' | cut -d: -f1)"
second_line="$(printf '%s\n' "$output" | grep -n 'second 2.0.0' | cut -d: -f1)"
[[ -n "$first_line" && -n "$second_line" && "$first_line" -lt "$second_line" ]] \
    && ok "plan preserves bundle order" || bad "plan order"

# A dry run is a preview and must stay read-only: no log directory, no lock,
# no root. This regressed invisibly until CI ran the suite unprivileged, where
# server-provision.sh died on mkdir /workspace/startup-logs before printing.
DRY_WS="$TMP/dryrun-workspace"
WORKSPACE_ROOT="$DRY_WS" ./server-provision.sh --plan "$PLAN_DIR/plan.sh" --dry-run >/dev/null 2>&1 \
    && [[ ! -e "$DRY_WS" ]] \
    && ok "dry run creates no workspace or log files" || bad "dry run has side effects"
if (( EUID == 0 )) && command -v setpriv >/dev/null 2>&1; then
    # mktemp -d is mode 700, so the unprivileged user needs traverse rights on
    # $TMP itself, not just on the plan directory inside it.
    chmod a+rx "$TMP" 2>/dev/null || true
    chmod -R a+rX "$PLAN_DIR" 2>/dev/null || true
    setpriv --reuid=65534 --regid=65534 --clear-groups \
        ./server-provision.sh --plan "$PLAN_DIR/plan.sh" --dry-run 2>/dev/null | grep -q 'Bundles: 2' \
        && ok "dry run works without root" || bad "dry run requires root"
else
    ok "dry run without root (already unprivileged or setpriv absent)"
fi

section "Provision integration"
if (( EUID == 0 )); then
    FULL="$TMP/full"; mkdir -p "$FULL/bin" "$FULL/bootstrap-src/base-1.2.0"
    cat > "$FULL/bootstrap-src/base-1.2.0/server-bootstrap.sh" <<'FAKEBOOT'
#!/usr/bin/env bash
set -e
printf 'bootstrap\n' >> "$PROVISION_ORDER_LOG"
cat > "$PROVISION_FAKE_BIN/server-accept" <<'ACCEPT'
#!/usr/bin/env bash
printf 'accept\n' >> "$PROVISION_ORDER_LOG"
exit 0
ACCEPT
cat > "$PROVISION_FAKE_BIN/server-bundle-install" <<'BUNDLE'
#!/usr/bin/env bash
set -e
name= archive= sha_file= delete=0
while (($#)); do
  case "$1" in
    --name) name="$2"; shift 2 ;;
    --archive) archive="$2"; shift 2 ;;
    --sha256-file) sha_file="$2"; shift 2 ;;
    --delete-after-success) delete=1; shift ;;
    --) break ;;
    *) shift ;;
  esac
done
printf 'bundle:%s\n' "$name" >> "$PROVISION_ORDER_LOG"
(( delete == 0 )) || rm -f -- "$archive" "$sha_file"
BUNDLE
chmod 0755 "$PROVISION_FAKE_BIN/server-accept" "$PROVISION_FAKE_BIN/server-bundle-install"
FAKEBOOT
    chmod +x "$FULL/bootstrap-src/base-1.2.0/server-bootstrap.sh"
    tar -czf "$FULL/base.tar.gz" -C "$FULL/bootstrap-src" base-1.2.0
    sha256sum "$FULL/base.tar.gz" > "$FULL/base.sha256"
    : > "$FULL/one.tar.gz"; sha256sum "$FULL/one.tar.gz" > "$FULL/one.sha256"
    : > "$FULL/two.tar.gz"; sha256sum "$FULL/two.tar.gz" > "$FULL/two.sha256"
    cat > "$FULL/plan.sh" <<'PLAN'
export WORKSPACE_ROOT="$PLAN_DIR/workspace"
export PATH="$PLAN_DIR/bin:$PATH"
export PROVISION_FAKE_BIN="$PLAN_DIR/bin"
export PROVISION_ORDER_LOG="$PLAN_DIR/order.log"
export ACCEPT_POLICY=reject-stop
export DELETE_ARCHIVES_AFTER_SUCCESS=1
register_bootstrap ./base.tar.gz ./base.sha256
register_bundle one 1.0.0 ./one.tar.gz ./one.sha256 install.sh
register_bundle two 2.0.0 ./two.tar.gz ./two.sha256 install.sh
PLAN
    if ./server-provision.sh --plan "$FULL/plan.sh" >/dev/null \
        && [[ "$(cat "$FULL/order.log")" == $'bootstrap\naccept\nbundle:one\nbundle:two' ]] \
        && [[ ! -e "$FULL/base.tar.gz" && ! -e "$FULL/one.tar.gz" && ! -e "$FULL/two.tar.gz" ]]; then
        ok "full provision order and cleanup"
    else
        bad "full provision integration"
    fi
else
    ok "full provision integration skipped without root"
fi

section "VS Code extension helper"
VSCODE_FIX="$TMP/vscode"; mkdir -p "$VSCODE_FIX"
cat > "$VSCODE_FIX/code" <<'FAKECODE'
#!/usr/bin/env bash
set -e
case "$1" in
  --list-extensions) printf '%s\n' 'publisher.already' ;;
  --install-extension) printf '%s\n' "$2" >> "$VSCODE_INSTALL_LOG" ;;
  *) exit 2 ;;
esac
FAKECODE
chmod +x "$VSCODE_FIX/code"
cat > "$VSCODE_FIX/extensions.txt" <<'EXT'
publisher.already
publisher.missing
EXT
if VSCODE_INSTALL_LOG="$VSCODE_FIX/install.log" STATE_ROOT="$VSCODE_FIX/state" LOG_ROOT="$VSCODE_FIX/log" \
    ./server-vscode-extensions --cli "$VSCODE_FIX/code" --manifest "$VSCODE_FIX/extensions.txt" >/dev/null \
    && [[ "$(cat "$VSCODE_FIX/install.log")" == publisher.missing ]]; then
    ok "helper installs only missing extensions"
else bad "VS Code helper idempotence"; fi
if STATE_ROOT="$VSCODE_FIX/no-cli-state" LOG_ROOT="$VSCODE_FIX/no-cli-log" \
    VSCODE_CLI=/does/not/exist ./server-vscode-extensions --manifest "$VSCODE_FIX/extensions.txt" >/dev/null 2>&1; then
    bad "missing explicit VS Code CLI accepted"
else ok "missing explicit VS Code CLI rejected"; fi
cat > "$VSCODE_FIX/code-partial" <<'FAKEPARTIAL'
#!/usr/bin/env bash
set -e
case "$1" in
  --list-extensions) exit 0 ;;
  --install-extension)
    printf '%s
' "$2" >> "$VSCODE_INSTALL_LOG"
    [[ "$2" != publisher.fail ]]
    ;;
  *) exit 2 ;;
esac
FAKEPARTIAL
chmod +x "$VSCODE_FIX/code-partial"
cat > "$VSCODE_FIX/extensions-partial.txt" <<'EXTPARTIAL'
publisher.fail
publisher.after
EXTPARTIAL
partial_rc=0
VSCODE_INSTALL_LOG="$VSCODE_FIX/partial.log" STATE_ROOT="$VSCODE_FIX/partial-state" LOG_ROOT="$VSCODE_FIX/partial-logs" \
    ./server-vscode-extensions --cli "$VSCODE_FIX/code-partial" --manifest "$VSCODE_FIX/extensions-partial.txt" >/dev/null 2>&1 || partial_rc=$?
if [[ "$partial_rc" == 4 && "$(cat "$VSCODE_FIX/partial.log")" == $'publisher.fail
publisher.after' ]]; then
    ok "helper continues after an extension failure"
else bad "VS Code helper partial-failure behavior"; fi

section "Acceptance test is accelerator-optional"
# A CPU-only box is a legitimate rental. Absent nvidia-smi must be a note, not a
# rejection, unless the caller says it paid for a GPU.
ACCEPT_FIX="$TMP/accept"; mkdir -p "$ACCEPT_FIX"
if PATH=/usr/bin:/bin command -v nvidia-smi >/dev/null 2>&1; then
    ok "accelerator-absent path skipped (this machine has nvidia-smi)"
else
    accept_rc=0
    accept_json="$(PATH=/usr/bin:/bin MIN_DISK_GB=0 MIN_DISK_MBPS=0 WORKSPACE_ROOT="$ACCEPT_FIX" \
        ./server-accept.sh --json)" || accept_rc=$?
    if [[ "$accept_rc" == 0 ]] && grep -q '"level":"ok","check":"accelerator"' <<<"$accept_json"; then
        ok "machine with no GPU is accepted by default"
    else bad "no-GPU acceptance (exit $accept_rc)"; fi

    accept_rc=0
    accept_json="$(PATH=/usr/bin:/bin REQUIRE_ACCELERATOR=1 MIN_DISK_GB=0 MIN_DISK_MBPS=0 WORKSPACE_ROOT="$ACCEPT_FIX" \
        ./server-accept.sh --json)" || accept_rc=$?
    if [[ "$accept_rc" == 1 ]] && grep -q '"level":"reject","check":"accelerator"' <<<"$accept_json"; then
        ok "REQUIRE_ACCELERATOR=1 rejects a machine with no GPU"
    else bad "REQUIRE_ACCELERATOR rejection (exit $accept_rc)"; fi
fi

section "Configuration and documentation"
grep -q 'UV_SHA256_X64="${UV_SHA256_X64:-[0-9a-fA-F]\{64\}}"' lib/bootstrap/config.sh \
    && grep -q 'UV_SHA256_ARM64="${UV_SHA256_ARM64:-[0-9a-fA-F]\{64\}}"' lib/bootstrap/config.sh \
    && ok "uv checksum pinned for both architectures" || bad "uv checksum default"
# Shape only, here and below. The values themselves are checked against every
# other surface that records them by tools/check-pins.sh, exercised in its own
# section further down. Literal versions and checksums used to live in this
# file for Node.js, Claude Code and Codex: they caught a wrong value, but they
# also failed a correct coordinated bump until somebody hand-edited this file,
# and they left uv, gh and Oh My Zsh with no value check at all. See #23.
grep -q 'INSTALL_NODEJS="${INSTALL_NODEJS:-1}"' lib/bootstrap/config.sh \
    && grep -Eq 'NODE_VERSION="\$\{NODE_VERSION:-[0-9]+\.[0-9]+\.[0-9]+\}"' lib/bootstrap/config.sh \
    && grep -Eq 'NODE_SHA256_X64="\$\{NODE_SHA256_X64:-[0-9a-fA-F]{64}\}"' lib/bootstrap/config.sh \
    && grep -Eq 'NODE_SHA256_ARM64="\$\{NODE_SHA256_ARM64:-[0-9a-fA-F]{64}\}"' lib/bootstrap/config.sh \
    && ok "Node.js LTS is enabled and checksum pinned" || bad "Node.js defaults/checksums"
grep -q 'INSTALL_CLAUDE_CODE="${INSTALL_CLAUDE_CODE:-1}"' lib/bootstrap/config.sh \
    && grep -Eq 'CLAUDE_CODE_VERSION="\$\{CLAUDE_CODE_VERSION:-[0-9]+\.[0-9]+\.[0-9]+\}"' lib/bootstrap/config.sh \
    && grep -q '@anthropic-ai/claude-code@' lib/bootstrap/ai_cli.sh \
    && grep -q 'CLAUDE_CODE_DISABLE_AUTOUPDATER="${CLAUDE_CODE_DISABLE_AUTOUPDATER:-1}"' lib/bootstrap/config.sh \
    && grep -q 'export DISABLE_AUTOUPDATER=1' lib/bootstrap/ai_cli.sh \
    && ok "Claude Code is enabled, pinned, and update-controlled" || bad "Claude Code defaults/pin"
grep -q 'INSTALL_CODEX="${INSTALL_CODEX:-1}"' lib/bootstrap/config.sh \
    && grep -Eq 'CODEX_VERSION="\$\{CODEX_VERSION:-[0-9]+\.[0-9]+\.[0-9]+\}"' lib/bootstrap/config.sh \
    && grep -q '@openai/codex@' lib/bootstrap/ai_cli.sh \
    && ok "Codex is enabled and version pinned" || bad "Codex defaults/pin"
grep -q 'INSTALL_VSCODE_EXTENSIONS="${INSTALL_VSCODE_EXTENSIONS:-1}"' lib/bootstrap/config.sh \
    && grep -q 'server-vscode-extensions --auto' lib/bootstrap/shell.sh \
    && [[ "$(awk 'NF && $1 !~ /^#/ {n++} END{print n}' config/vscode-extensions.txt)" == 49 ]] \
    && grep -q 'server-vscode-extensions" "$stage/server-vscode-extensions' lib/bootstrap/runtime.sh \
    && grep -q 'config/vscode-extensions.txt" "$stage/config/vscode-extensions.txt' lib/bootstrap/runtime.sh \
    && ok "VS Code extension manifest and deferred installer" || bad "VS Code extension configuration"
awk 'NF && $1 !~ /^#/ {print tolower($1)}' config/vscode-extensions.txt | grep -Eqv '^[a-z0-9][a-z0-9-]*\.[a-z0-9][a-z0-9._-]*$' \
    && bad "invalid VS Code extension ID" || ok "VS Code extension IDs are valid"
[[ "$(awk 'NF && $1 !~ /^#/ {print tolower($1)}' config/vscode-extensions.txt | sort | uniq -d | wc -l)" == 0 ]] \
    && ok "VS Code extension IDs are unique" || bad "duplicate VS Code extension IDs"

grep -q 'INSTALL_GITHUB_CLI="${INSTALL_GITHUB_CLI:-1}"' lib/bootstrap/config.sh \
    && grep -Eq 'GH_VERSION="\$\{GH_VERSION:-[0-9]+\.[0-9]+\.[0-9]+\}"' lib/bootstrap/config.sh \
    && grep -Eq 'GH_SHA256_X64="\$\{GH_SHA256_X64:-[0-9a-fA-F]{64}\}"' lib/bootstrap/config.sh \
    && grep -Eq 'GH_SHA256_ARM64="\$\{GH_SHA256_ARM64:-[0-9a-fA-F]{64}\}"' lib/bootstrap/config.sh \
    && grep -q 'github.com/cli/cli/releases/download' lib/bootstrap/github_cli.sh \
    && ok "GitHub CLI is enabled and checksum pinned" || bad "GitHub CLI defaults/checksums"
# gh ships as a verified tarball, so it must never also be an apt package name:
# two installers for one binary is how a pinned version silently regresses.
grep -Eq '^gh$' config/packages.txt \
    && bad "gh must be installed from the pinned release, not apt" \
    || ok "gh is not duplicated in the apt manifest"

grep -q 'INSTALL_ZSH="${INSTALL_ZSH:-1}"' lib/bootstrap/config.sh \
    && grep -Eq '^zsh$' config/packages.txt && grep -Eq '^ffmpeg$' config/packages.txt \
    && ok "Zsh installed by default" || bad "Zsh package/default"
grep -q 'INSTALL_OH_MY_ZSH="${INSTALL_OH_MY_ZSH:-1}"' lib/bootstrap/config.sh \
    && grep -Eq 'OH_MY_ZSH_REF="\$\{OH_MY_ZSH_REF:-[0-9a-fA-F]{40}\}"' lib/bootstrap/config.sh \
    && ok "Oh My Zsh enabled and pinned" || bad "Oh My Zsh default/pin"
grep -q "alias c='clear'" lib/bootstrap/shell.sh \
    && grep -q 'source "\$ZSH/oh-my-zsh.sh"' lib/bootstrap/shell.sh \
    && ok "Oh My Zsh startup and clear alias" || bad "shell startup/clear alias"
grep -q 'bootstrap_set_default_zsh' lib/bootstrap/shell.sh \
    && grep -q 'usermod --shell' lib/bootstrap/shell.sh \
    && ok "Zsh login shell enforcement" || bad "Zsh default shell enforcement"
for doc in QUICKSTART PROVISIONING ARCHITECTURE BUNDLE-CONTRACT CONFIGURATION TROUBLESHOOTING SECURITY-SCANNING; do
    [[ -s "docs/$doc.md" ]] && ok "documentation: $doc" || bad "missing documentation: $doc"
done

section "Fitness: every pinned value agrees on every surface that records it"
# lib/bootstrap/config.sh is canonical. config.example.env, checksums/*.txt,
# README.md and docs/CONFIGURATION.md are second recordings of the same
# thirteen values, and tools/refresh-pins.sh --write writes all of them.
# tools/check-pins.sh asserts each recording is present exactly once, is well
# formed, and equals the canonical value -- with every architecture anchored to
# its own label, so an x64/arm64 swap fails. Before it existed a zeroed uv
# checksum, a swapped pair, and a two-release-stale docs/CONFIGURATION.md all
# passed this suite. See #23.
#
# Not a security boundary: anyone who can edit config.sh can edit this file.
# A wrong checksum fails closed at install time. This makes it visible in CI.
check_pins_out="$(bash tools/check-pins.sh 2>&1)" \
    && ok "every pinned value agrees on every surface" \
    || bad "check-pins: $check_pins_out"

# The adversarial half. Each case copies the pin surfaces into a scratch tree,
# mutates one, and runs the real checker against it, so the tests exercise the
# shipped code rather than a paraphrase of it -- and the working tree is never
# touched. Each asserts the specific finding, not merely a non-zero exit: a
# checker that failed for some unrelated reason would otherwise look covered.
pin_surface_copy() {
    local dest file
    dest="$(mktemp -d "$TMP/pins.XXXXXX")"
    for file in VERSION README.md config.example.env lib/bootstrap/config.sh \
        docs/CONFIGURATION.md checksums/NODE_SHA256.txt checksums/GH_SHA256.txt \
        checksums/UV_SHA256.txt checksums/OH_MY_ZSH_REF.txt \
        checksums/AI_CLI_VERSIONS.txt examples/provision-plan.example.sh \
        examples/provision-plan.whisper.example.sh; do
        mkdir -p "$dest/$(dirname "$file")"
        cp -- "$file" "$dest/$file"
    done
    printf '%s\n' "$dest"
}
pin_reject() {  # label, expected finding fragment, root
    local label="$1" fragment="$2" root="$3" out
    if out="$(bash tools/check-pins.sh "$root" 2>&1)"; then
        bad "check-pins accepted $label"
        return
    fi
    grep -qF -- "$fragment" <<< "$out" \
        && ok "check-pins rejects $label" \
        || bad "check-pins rejected $label, but not for '$fragment': $out"
}

ZERO64=0000000000000000000000000000000000000000000000000000000000000000

# A wrong checksum, in either recording.
root="$(pin_surface_copy)"
sed -i "s|UV_SHA256_X64:-[0-9a-f]\{64\}|UV_SHA256_X64:-$ZERO64|" "$root/lib/bootstrap/config.sh"
pin_reject "a zeroed uv checksum in config.sh" "UV_SHA256_X64" "$root"

root="$(pin_surface_copy)"
sed -i "s|^x86_64-unknown-linux-gnu  [0-9a-f]\{64\}$|x86_64-unknown-linux-gnu  $ZERO64|" "$root/checksums/UV_SHA256.txt"
pin_reject "a zeroed uv checksum in the manifest" \
    "mismatch: checksums/UV_SHA256.txt records $ZERO64 for UV_SHA256_X64" "$root"

# The case grep -qF cannot see: both values are still present in the file, just
# recorded against the wrong architecture.
for pair in \
    'checksums/UV_SHA256.txt|x86_64-unknown-linux-gnu|aarch64-unknown-linux-gnu' \
    'checksums/NODE_SHA256.txt|linux-x64|linux-arm64' \
    'checksums/GH_SHA256.txt|linux-amd64|linux-arm64'; do
    IFS='|' read -r file x64_label arm_label <<< "$pair"
    root="$(pin_surface_copy)"
    python3 - "$root/$file" "$x64_label" "$arm_label" <<'SWAP'
import re, sys
path, x64_label, arm_label = sys.argv[1:4]
text = open(path).read()
grab = lambda label: re.search(r'^%s( +)([0-9a-f]{64})$' % re.escape(label), text, re.M)
a, b = grab(x64_label), grab(arm_label)
text = text[:a.start(2)] + b.group(2) + text[a.end(2):]
b = grab(arm_label)
text = text[:b.start(2)] + a.group(2) + text[b.end(2):]
open(path, 'w').write(text)
SWAP
    pin_reject "x64 and arm64 swapped in $file" "mismatch: $file" "$root"
done

# One-sided bumps, in each direction and on each surface.
root="$(pin_surface_copy)"
sed -i 's|NODE_VERSION:-[0-9.]*|NODE_VERSION:-99.0.0|' "$root/lib/bootstrap/config.sh"
pin_reject "a config-only Node.js bump" "for NODE_VERSION" "$root"

root="$(pin_surface_copy)"
sed -i 's|^@anthropic-ai/claude-code .*|@anthropic-ai/claude-code 99.0.0|' "$root/checksums/AI_CLI_VERSIONS.txt"
pin_reject "a manifest-only Claude Code bump" \
    "mismatch: checksums/AI_CLI_VERSIONS.txt records 99.0.0 for CLAUDE_CODE_VERSION" "$root"

root="$(pin_surface_copy)"
sed -i 's|^# UV_VERSION=.*|# UV_VERSION=0.0.1|' "$root/config.example.env"
pin_reject "a stale config.example.env" "mismatch: config.example.env" "$root"

root="$(pin_surface_copy)"
sed -i 's|^CLAUDE_CODE_VERSION=.*|CLAUDE_CODE_VERSION=0.0.1|' "$root/docs/CONFIGURATION.md"
pin_reject "a stale docs/CONFIGURATION.md" "mismatch: docs/CONFIGURATION.md" "$root"

root="$(pin_surface_copy)"
sed -i 's|Claude Code [0-9][0-9.]*|Claude Code 0.0.1|' "$root/README.md"
pin_reject "a stale README.md" "mismatch: README.md" "$root"

# The example plans: a plan is sourced before the bootstrap runs, so a pin here
# beats the bundle default. Both shipped plans carried a uv override that spent
# two releases stale, which meant the documented quick start installed uv
# 0.12.12 against a bundle pinned to 0.12.13.
root="$(pin_surface_copy)"
printf 'export UV_VERSION=0.12.12\n' >> "$root/examples/provision-plan.example.sh"
pin_reject "a re-added example-plan pin override" \
    "unlabelled pin override: examples/provision-plan.example.sh sets UV_VERSION" "$root"

# Extra, missing, duplicate and malformed recordings.
root="$(pin_surface_copy)"
printf 'riscv64-unknown-linux-gnu %s\n' "$ZERO64" >> "$root/checksums/UV_SHA256.txt"
pin_reject "an unclaimed extra hash in a manifest" \
    "unclaimed hash in checksums/UV_SHA256.txt" "$root"

root="$(pin_surface_copy)"
sed -i '/^# UV_VERSION=/d' "$root/config.example.env"
pin_reject "a recording deleted from config.example.env" \
    "missing or malformed: UV_VERSION in config.example.env" "$root"

root="$(pin_surface_copy)"
sed -n 's|^\(# PI_VERSION=.*\)$|\1|p' "$root/config.example.env" >> "$root/config.example.env"
pin_reject "a duplicated recording" "duplicate: PI_VERSION" "$root"

root="$(pin_surface_copy)"
sed -i 's|OH_MY_ZSH_REF:-\([0-9a-f]\{39\}\)[0-9a-f]|OH_MY_ZSH_REF:-\1|' "$root/lib/bootstrap/config.sh"
pin_reject "a ref truncated to 39 hex characters" \
    "missing or malformed: OH_MY_ZSH_REF in lib/bootstrap/config.sh" "$root"

root="$(pin_surface_copy)"
sed -i 's|^\( *\)GH_VERSION=|\1RUSTUP_VERSION="${RUSTUP_VERSION:-1.2.3}"\n\1GH_VERSION=|' "$root/lib/bootstrap/config.sh"
pin_reject "a new pin with no map entry" "unmapped pin: RUSTUP_VERSION" "$root"

# And the case the whole design exists for: a full coordinated bump, applied by
# the same writer refresh-pins.sh --write uses, must pass with no hand edit to
# any test file.
root="$(pin_surface_copy)"
if SB_PIN_ROOT="$root" \
    NODE_VERSION=25.1.0 NODE_SHA256_X64="${ZERO64/00/a1}" NODE_SHA256_ARM64="${ZERO64/00/a2}" \
    GH_VERSION=2.101.0 GH_SHA256_X64="${ZERO64/00/b1}" GH_SHA256_ARM64="${ZERO64/00/b2}" \
    UV_VERSION=0.13.0 UV_SHA256_X64="${ZERO64/00/c1}" UV_SHA256_ARM64="${ZERO64/00/c2}" \
    CLAUDE_CODE_VERSION=2.2.0 CODEX_VERSION=0.155.0 PI_VERSION=0.86.0 \
    OH_MY_ZSH_REF=1111111111111111111111111111111111111111 OMZ_DATE=2026-01-01 \
    python3 tools/write-pins.py >/dev/null 2>&1; then
    bash tools/check-pins.sh "$root" >/dev/null 2>&1 \
        && ok "a coordinated bump passes with no hand-edited test literal" \
        || bad "a coordinated bump written by tools/write-pins.py fails check-pins"
else
    bad "tools/write-pins.py could not apply a coordinated bump"
fi

# The reverse regression: no pin literal may creep back into this file. The
# only 40/64-hex strings allowed are the synthetic fixture that drives
# sb_sha256_from_manifest_body parsing, which is parser input and would keep
# parsing correctly if it went stale, and the all-zero probe above.
pin_literal_drift=0
while IFS= read -r hit; do
    [[ -n "$hit" ]] || continue
    bad "pin literal back in tests/run-tests.sh: $hit"
    pin_literal_drift=1
done < <(grep -noE '\b[0-9a-f]{40}\b|\b[0-9a-f]{64}\b' tests/run-tests.sh \
    | grep -vE ':(0{40}|0{64}|1{40})$' \
    | grep -vE ':(fd8e59d5a511510f6a298afb548f18c7d2b1be404d8b4a27d94fbe49f56cb2d6|6ad1325edbdb5649c379b75a237147a666c95d4f9ae8d340fef2d1575d289ad2|ab9b309d4586403f024e100abaceb396616e178a553e2500c36087d180f09509)$' \
    || true)
(( pin_literal_drift == 0 )) && ok "no pin literal in tests/run-tests.sh outside the parser fixture"

section "Fitness: example plans are safe to copy and paste"
# A plan carries a shebang and the executable bit, so it looks runnable. It is
# not: register_bootstrap only exists while server-provision.sh sources it. Running
# one used to emit 'command not found' twice and exit 127.
plan_guard_drift=0
for plan in examples/provision-plan*.sh; do
    grep -q 'declare -F register_bootstrap' "$plan" \
        || { bad "no direct-execution guard: $plan"; plan_guard_drift=1; continue; }
    guard_out="$(bash "$plan" 2>&1)"; guard_code=$?
    [[ "$guard_code" == 2 ]] \
        || { bad "$plan exited $guard_code when run directly, expected 2"; plan_guard_drift=1; }
    grep -qF -- '--plan' <<< "$guard_out" \
        || { bad "$plan guard does not name the correct command"; plan_guard_drift=1; }
done
(( plan_guard_drift == 0 )) && ok "example plans reject direct execution"

# The quick-start plan must install the foundation only. An active
# register_bundle naming an archive that ships nowhere aborts provisioning
# after the bootstrap has already installed, reporting FAILED on a box that
# was in fact provisioned.
if grep -qE '^[[:space:]]*register_bundle' examples/provision-plan.example.sh; then
    bad "provision-plan.example.sh registers a bundle; quick start would fail"
else
    ok "default example plan registers no unavailable bundle"
fi

# The README must send people through server-provision.sh, never at a plan file.
if grep -qE '^[[:space:]]*(sudo )?\./provision-plan[^[:space:]]*\.sh' README.md; then
    bad "README invokes a plan file directly"
elif grep -q 'server-provision.sh --plan' README.md; then
    ok "README quick start uses server-provision.sh --plan"
else
    bad "README quick start does not show server-provision.sh --plan"
fi

section "Fitness: README tables only name commands bootstrap actually installs"
# The Quick Reference table told people to run `server-provision.sh --plan …
# --dry-run` after install, but bootstrap_install_runtime_tools() only ever
# symlinks the bare `server-provision` onto PATH (the .sh suffix is not
# stripped uniformly — server-accept is the sole exception, keeping both
# names). Following the doc literally failed with 'command not found' (127).
# The installed-command set is derived from lib/bootstrap/runtime.sh itself,
# not hardcoded here, so this stays a docs-vs-reality check, not a snapshot.
declare -A installed_commands=()
while IFS= read -r name; do
    [[ -n "$name" ]] && installed_commands["$name"]=1
done < <(grep -oE '/usr/local/bin/[A-Za-z0-9_.-]+' lib/bootstrap/runtime.sh | sed 's#.*/##' | sort -u)

readme_cmd_drift=0
while IFS= read -r token; do
    [[ -n "$token" ]] || continue
    [[ "$token" == server-* ]] || continue
    [[ -n "${installed_commands[$token]:-}" ]] \
        || { bad "README table names '$token', which runtime.sh never symlinks onto PATH"; readme_cmd_drift=1; }
done < <(grep '^|' README.md | grep -oE '`[^`]+`' | sed -E 's/^`//; s/`$//' | awk '{print $1}')
(( readme_cmd_drift == 0 )) && ok "README command tables match commands bootstrap installs"

section "API key file: parsing"
# One fixture drives every parsing rule. The point of most of these cases is
# that the file is parsed, not sourced.
KEYS_FIXTURE="$TMP/secrets.env"
cat > "$KEYS_FIXTURE" <<'FIXTURE'
# a comment
ANTHROPIC_API_KEY=fixture-anthropic-value-1234
   # an indented comment

  OPENAI_API_KEY = name-with-space-is-invalid
OPENAI_API_KEY=fixture-openai-value-9c11
export OPENROUTER_API_KEY=fixture-openrouter-value-4de0
DOUBLE_QUOTED="fixture-double-quoted"
SINGLE_QUOTED='fixture-single-quoted'
EMPTY_KEY=
INJECTED=`id`$(id);echo pwned
WITH_EQUALS=a=b=c
TRAILING=fixture-with-trailing-space   
9BADNAME=x
BAD-NAME=y
no_equals_line
FIXTURE
chmod 600 "$KEYS_FIXTURE"

keys_probe() {
    # A subshell so exported fixture values never reach the rest of the suite.
    ( set +u
      # shellcheck source=/dev/null
      . ./lib/secrets-load.sh
      server_secrets_load "$KEYS_FIXTURE" >/dev/null 2>&1
      eval "printf '%s' \"\${$1-__UNSET__}\"" )
}

[[ "$(keys_probe ANTHROPIC_API_KEY)" == 'fixture-anthropic-value-1234' ]] \
    && ok "plain KEY=VALUE is exported" || bad "plain KEY=VALUE"
[[ "$(keys_probe OPENROUTER_API_KEY)" == 'fixture-openrouter-value-4de0' ]] \
    && ok "an export prefix is stripped" || bad "export prefix handling"
[[ "$(keys_probe DOUBLE_QUOTED)" == 'fixture-double-quoted' ]] \
    && ok "double quotes are stripped" || bad "double-quote handling"
[[ "$(keys_probe SINGLE_QUOTED)" == 'fixture-single-quoted' ]] \
    && ok "single quotes are stripped" || bad "single-quote handling"
[[ "$(keys_probe WITH_EQUALS)" == 'a=b=c' ]] \
    && ok "only the first = splits the line" || bad "value containing ="
[[ "$(keys_probe TRAILING)" == 'fixture-with-trailing-space' ]] \
    && ok "trailing whitespace is trimmed" || bad "trailing whitespace"
[[ "$(keys_probe EMPTY_KEY)" == '__UNSET__' ]] \
    && ok "an empty value is not exported" || bad "empty value was exported"
# Probed through the loaded-name list: "9BADNAME" is not a valid parameter
# name, so ${9BADNAME-...} would be a syntax error rather than a test.
loaded_names="$( set +u
    # shellcheck source=/dev/null
    . ./lib/secrets-load.sh
    server_secrets_load "$KEYS_FIXTURE" >/dev/null 2>&1
    printf ' %s ' "$SERVER_SECRETS_LOADED" )"
[[ "$loaded_names" != *' 9BADNAME '* \
    && "$loaded_names" != *' BAD-NAME '* \
    && "$loaded_names" != *' no_equals_line '* \
    && "$loaded_names" == *' ANTHROPIC_API_KEY '* ]] \
    && ok "invalid names and non-assignments are skipped" || bad "invalid line handling"
# The decisive one: command substitution in a value must survive as text.
[[ "$(keys_probe INJECTED)" == '`id`$(id);echo pwned' ]] \
    && ok "the keys file is parsed, not sourced" || bad "value was evaluated instead of parsed"

# The generated loader must behave identically in the shell that actually runs
# it. Zsh does not word-split unquoted expansions, which is easy to get wrong.
if command -v zsh >/dev/null 2>&1; then
    zsh_probe="$(zsh -c '
        . ./lib/secrets-load.sh
        server_secrets_load "'"$KEYS_FIXTURE"'" >/dev/null 2>&1
        printf "%s|%s" "$ANTHROPIC_API_KEY" "$SERVER_SECRETS_LOADED"
        server_secrets_unload
        printf "|%s" "${ANTHROPIC_API_KEY-__UNSET__}"' 2>/dev/null)"
    [[ "$zsh_probe" == 'fixture-anthropic-value-1234|'*'|__UNSET__' ]] \
        && ok "Zsh loads and unloads the same way Bash does" || bad "Zsh parity: $zsh_probe"
else
    ok "Zsh parity skipped (zsh not installed)"
fi

mask_out="$( set +u; . ./lib/secrets-load.sh; server_secrets_mask 'fixture-anthropic-value-1234' )"
[[ "$mask_out" == 'fixture...1234' ]] \
    && ok "masking keeps only the ends" || bad "masking output: $mask_out"
[[ "$( set +u; . ./lib/secrets-load.sh; server_secrets_mask 'short' )" == '********' ]] \
    && ok "a short value is masked completely" || bad "short-value masking"

section "API key file: server-secrets"
KEYS_HOME="$TMP/keyshome"; mkdir -p "$KEYS_HOME"
export SERVER_SECRETS_FILE="$KEYS_HOME/secrets.env"

./server-secrets check >/dev/null 2>&1 \
    && bad "check passed with no keys set" || ok "check fails before any key is set"
./server-secrets init >/dev/null 2>&1 \
    && [[ -f "$SERVER_SECRETS_FILE" ]] || bad "init did not create the keys file"
[[ "$(stat -c '%a' "$SERVER_SECRETS_FILE")" == 600 ]] \
    && ok "keys file is created mode 0600" || bad "keys file mode"
[[ "$(stat -c '%a' "$KEYS_HOME")" == 700 ]] \
    && ok "keys directory is 0700" || bad "keys directory mode"

printf 'user-edit-must-survive\n' >> "$SERVER_SECRETS_FILE"
./server-secrets init >/dev/null 2>&1
grep -q 'user-edit-must-survive' "$SERVER_SECRETS_FILE" \
    && ok "init is idempotent and never clobbers an edited file" || bad "init overwrote the keys file"

printf 'suite-openrouter-value-0001\n' | ./server-secrets set OPENROUTER_API_KEY >/dev/null 2>&1
printf 'suite-openrouter-value-0002\n' | ./server-secrets set OPENROUTER_API_KEY >/dev/null 2>&1
[[ "$(grep -c '^OPENROUTER_API_KEY=' "$SERVER_SECRETS_FILE")" == 1 ]] \
    && grep -q '^OPENROUTER_API_KEY=suite-openrouter-value-0002$' "$SERVER_SECRETS_FILE" \
    && ok "set replaces in place instead of appending duplicates" || bad "set duplicate handling"
printf 'x\n' | ./server-secrets set 'BAD-NAME' >/dev/null 2>&1 \
    && bad "set accepted an invalid variable name" || ok "set rejects an invalid variable name"

# Status must describe the file, not the ambient environment: reporting an
# unrelated inherited token would leak a credential this file does not own.
GITHUB_TOKEN='ambient-value-must-not-appear' ./server-secrets status 2>/dev/null \
    | grep -q 'ambient-value-must-not-appear' \
    && bad "status leaked a value from the environment" \
    || ok "status reports the file, not the environment"
./server-secrets status 2>/dev/null | grep -q 'suite-openrouter-value-0002' \
    && bad "status printed a key in full" || ok "status never prints a key in full"
unset SERVER_SECRETS_FILE

grep -q 'server_secrets_load' lib/bootstrap/secrets.sh \
    && grep -q 'aikeys()' lib/bootstrap/secrets.sh \
    && grep -q 'server-secrets.zsh' lib/bootstrap/shell.sh \
    && ok "the generated Zsh startup file loads keys and defines aikeys" || bad "Zsh key wiring"
grep -q 'chmod 0700 "$SECRETS_DIR"' lib/bootstrap/secrets.sh \
    && grep -q 'chmod 0600 "$SECRETS_FILE"' lib/bootstrap/secrets.sh \
    && ok "bootstrap enforces key file permissions" || bad "key file permission enforcement"
# Comments may explain why not; no executable line may actually go there.
grep -v '^[[:space:]]*#' lib/bootstrap/secrets.sh | grep -q 'profile\.d' \
    && bad "keys are written to world-readable /etc/profile.d" \
    || ok "keys stay out of world-readable /etc/profile.d"
grep -Eq '^(ANTHROPIC|OPENAI|OPENROUTER)_API_KEY=$' examples/secrets.env.example \
    && ok "the shipped key template is empty" || bad "key template placeholders"
grep -Eq '^[A-Za-z_][A-Za-z0-9_]*=.+' examples/secrets.env.example \
    && bad "the shipped key template contains a value" || ok "no value is committed in the key template"

section "pi coding agent"
grep -q 'INSTALL_PI="${INSTALL_PI:-1}"' lib/bootstrap/config.sh \
    && grep -qE 'PI_VERSION="\$\{PI_VERSION:-[0-9]+\.[0-9]+\.[0-9]+\}"' lib/bootstrap/config.sh \
    && grep -q '@earendil-works/pi-coding-agent@' lib/bootstrap/ai_cli.sh \
    && ok "pi is enabled and version pinned" || bad "pi defaults/pin"
grep -q 'ln -sfn "$AI_CLI_PREFIX/bin/pi" /usr/local/bin/pi' lib/bootstrap/ai_cli.sh \
    && ok "pi is linked into /usr/local/bin" || bad "pi link"
grep -q 'PI_TELEMETRY=0' lib/bootstrap/shell.sh \
    && grep -q 'PI_SKIP_VERSION_CHECK=1' lib/bootstrap/shell.sh \
    && ok "pi telemetry and version check are disabled" || bad "pi network defaults"
python3 -m json.tool examples/pi-models.example.json >/dev/null 2>&1 \
    && ok "the pi model template is valid JSON" || bad "pi model template is not valid JSON"
grep -q '"\$OPENROUTER_API_KEY"' examples/pi-models.example.json \
    && ok "the pi model template reads the key from the environment" || bad "pi template key reference"
grep -Eq '"(apiKey|key)"[[:space:]]*:[[:space:]]*"sk-' examples/pi-models.example.json \
    && bad "the pi model template contains a literal key" || ok "no literal key in the pi model template"
grep -q 'e "$target"' lib/bootstrap/pi.sh && grep -q 'kept existing pi model configuration' lib/bootstrap/pi.sh \
    && ok "an existing models.json is never overwritten" || bad "models.json overwrite guard"

section "Upstream version resolution"
# shellcheck source=lib/core.sh
source lib/core.sh
manifest_table="$(printf '%s\n%s\n' \
    'fd8e59d5a511510f6a298afb548f18c7d2b1be404d8b4a27d94fbe49f56cb2d6  node-v24.21.0-linux-x64.tar.xz' \
    '6ad1325edbdb5649c379b75a237147a666c95d4f9ae8d340fef2d1575d289ad2  node-v24.21.0-linux-arm64.tar.xz')"
[[ "$(sb_sha256_from_manifest_body "$manifest_table" node-v24.21.0-linux-arm64.tar.xz)" \
    == '6ad1325edbdb5649c379b75a237147a666c95d4f9ae8d340fef2d1575d289ad2' ]] \
    && ok "a checksum table resolves the requested file" || bad "manifest table parsing"
[[ "$(sb_sha256_from_manifest_body 'ab9b309d4586403f024e100abaceb396616e178a553e2500c36087d180f09509  uv-x86_64-unknown-linux-gnu.tar.gz' uv-x86_64-unknown-linux-gnu.tar.gz)" \
    == 'ab9b309d4586403f024e100abaceb396616e178a553e2500c36087d180f09509' ]] \
    && ok "a bare sidecar resolves" || bad "sidecar parsing"
sb_sha256_from_manifest_body "$manifest_table" 'node-v24.21.0-linux-ppc64le.tar.xz' >/dev/null 2>&1 \
    && bad "a missing filename returned a checksum" || ok "a filename absent from the manifest fails"
sb_sha256_from_manifest_body 'not-a-checksum  some-file.tar.gz' some-file.tar.gz >/dev/null 2>&1 \
    && bad "a malformed manifest returned a checksum" || ok "a malformed manifest fails"
sb_sha256_from_manifest_body '' anything >/dev/null 2>&1 \
    && bad "an empty manifest returned a checksum" || ok "an empty manifest fails"
sb_checksum_from_manifest 'http://example.com/checksums.txt' file >/dev/null 2>&1 \
    && bad "a plain-HTTP manifest was accepted" || ok "a manifest URL must use HTTPS"

# Resolution must feed the same verification gate as a pin, never bypass it.
resolution_guard=0
for module in lib/bootstrap/node.sh lib/bootstrap/github_cli.sh lib/bootstrap/uv.sh; do
    grep -q 'sb_is_latest' "$module" || { bad "no latest support in $module"; resolution_guard=1; }
    grep -q 'sb_valid_sha256' "$module" || { bad "no checksum gate in $module"; resolution_guard=1; }
done
(( resolution_guard == 0 )) && ok "every resolved download still passes sb_valid_sha256"
grep -q 'sb_is_latest' lib/bootstrap/ai_cli.sh \
    && ok "the npm CLIs accept latest" || bad "npm latest support"
grep -q 'git ls-remote' lib/core.sh \
    && ok "tag discovery avoids the rate-limited GitHub API" || bad "tag discovery method"

if [[ "${SB_TEST_NETWORK:-0}" == 1 ]]; then
    # shellcheck source=lib/bootstrap/node.sh
    source lib/bootstrap/node.sh
    live_node="$(bootstrap_node_resolve_latest 2>/dev/null || true)"
    [[ "$live_node" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
        && ok "live: Node.js LTS resolves to $live_node" || bad "live Node.js LTS resolution"
    live_sha="$(sb_checksum_from_manifest "https://nodejs.org/dist/v$live_node/SHASUMS256.txt" \
        "node-v$live_node-linux-x64.tar.xz" 2>/dev/null || true)"
    sb_valid_sha256 "$live_sha" \
        && ok "live: the published manifest yields a valid SHA-256" || bad "live checksum resolution"
else
    ok "live upstream resolution skipped (set SB_TEST_NETWORK=1 to run it)"
fi

section "Pin drift classification and exit semantics"
# tools/refresh-pins.sh --check could not exit 0 and could not be trusted when
# it did. The Oh My Zsh row tracks refs/heads/master, which moves several times
# a day, so treating that movement as staleness made exit 1 the steady state;
# and an upstream that failed to resolve fell back to the pinned value, so seven
# failed lookups printed seven "current" rows and exited 0. See #25.
#
# The decision now lives in two pure functions with no network, no clock and no
# filesystem, so the whole thing is driven here with synthetic rows. Sourcing
# the script must therefore be free of side effects -- including shell options:
# it sets -Eeuo pipefail inside its main function, and setting -e in this suite
# would abort it at the first intentionally failing probe.
shell_opts_before="$-"
# shellcheck source=tools/refresh-pins.sh
source tools/refresh-pins.sh
[[ "$-" == "$shell_opts_before" ]] \
    && ok "sourcing refresh-pins.sh does not change shell options" \
    || bad "sourcing refresh-pins.sh changed shell options: $shell_opts_before -> $-"
grep -qF '[[ "${BASH_SOURCE[0]}" != "$0" ]] || refresh_pins_main "$@"' tools/refresh-pins.sh \
    && ok "refresh-pins.sh has a main guard, so sourcing it resolves nothing" \
    || bad "refresh-pins.sh has no main guard; sourcing it would hit the network"
for fn in refresh_pins_kind refresh_pins_classify refresh_pins_exit_code; do
    declare -F "$fn" >/dev/null \
        && ok "sourcing defines $fn" || bad "sourcing did not define $fn"
done

# The classification itself, so it cannot silently flip. Oh My Zsh is the one
# branch head; every other pin resolves to a published release.
kind_drift=0
while IFS='|' read -r tool expected_kind; do
    [[ -n "$tool" ]] || continue
    [[ "$(refresh_pins_kind "$tool")" == "$expected_kind" ]] \
        || { bad "refresh-pins classifies $tool as $(refresh_pins_kind "$tool"), expected $expected_kind"; kind_drift=1; }
done <<'KINDS'
nodejs|release
github-cli|release
uv|release
claude-code|release
codex|release
pi|release
oh-my-zsh|branch-head
KINDS
(( kind_drift == 0 )) && ok "six release pins and one branch head, as registered"
[[ "$(refresh_pins_kind not-a-tool 2>/dev/null || true)" == unknown ]] \
    && ok "an unregistered tool is not silently classified" || bad "unregistered tool classification"

# UNKNOWN is decided before the equality test, so a failed resolution can never
# become CURRENT by comparing the pinned value against itself.
classify_drift=0
while IFS='|' read -r kind current latest expected; do
    [[ -n "$kind" ]] || continue
    actual="$(refresh_pins_classify "$kind" "$current" "$latest" 2>/dev/null || true)"
    [[ "$actual" == "$expected" ]] \
        || { bad "classify($kind, '$current', '$latest') = $actual, expected $expected"; classify_drift=1; }
done <<'CLASSIFY'
release|1.0.0|1.0.0|CURRENT
release|1.0.0|1.0.1|STALE
branch-head|aaaaaaa|aaaaaaa|CURRENT
branch-head|aaaaaaa|bbbbbbb|MOVED
release|1.0.0||UNKNOWN
branch-head|aaaaaaa||UNKNOWN
CLASSIFY
(( classify_drift == 0 )) && ok "every state is reached from the values that produce it"

# And the exit code, which is the thing automation reads. Rows are synthetic:
# nothing here contacts an upstream, which is what tests/run-tests.sh requires.
exit_code_drift=0
probe_exit_code() {  # mode, expected, rows...
    local mode="$1" expected="$2"; shift 2
    local actual=0
    printf '%s\n' "$@" | refresh_pins_exit_code "$mode" || actual=$?
    [[ "$actual" == "$expected" ]] && return 0
    bad "exit code $actual for [$mode: $*], expected $expected"
    exit_code_drift=1
}
CURRENT_ROWS=("nodejs|24.21.0|24.21.0|CURRENT|release" "oh-my-zsh|aaa|aaa|CURRENT|branch-head")
# The regression case this issue exists for: a moved branch head alone must not
# make --check non-zero. The obvious later simplification is to collapse the two
# kinds back into one, and the noise that reintroduces is invisible until the
# weekly job has been crying wolf for a month.
MOVED_ROWS=("nodejs|24.21.0|24.21.0|CURRENT|release" "oh-my-zsh|aaa|bbb|MOVED|branch-head")
probe_exit_code default 0 "${CURRENT_ROWS[@]}"
probe_exit_code all     0 "${CURRENT_ROWS[@]}"
probe_exit_code default 0 "${MOVED_ROWS[@]}"
probe_exit_code all     1 "${MOVED_ROWS[@]}"
probe_exit_code default 1 "nodejs|24.21.0|24.22.0|STALE|release"
probe_exit_code default 1 "nodejs|24.21.0|24.22.0|STALE|release" "oh-my-zsh|aaa|bbb|MOVED|branch-head"
# UNKNOWN is its own result, never 0: a run whose upstream was unreachable is
# not a clean week. And a definite stale pin outranks it, because there is
# definitely work either way.
probe_exit_code default 3 "nodejs|24.21.0||UNKNOWN|release" "uv|0.12.13|0.12.13|CURRENT|release"
probe_exit_code all     3 "nodejs|24.21.0||UNKNOWN|release" "oh-my-zsh|aaa||UNKNOWN|branch-head"
probe_exit_code default 1 "nodejs|24.21.0||UNKNOWN|release" "uv|0.12.13|0.13.0|STALE|release"
probe_exit_code default 3 "oh-my-zsh|aaa||UNKNOWN|branch-head"
probe_exit_code default 0 ""
(( exit_code_drift == 0 )) && ok "every documented exit code is produced by the state that means it"

# The exit codes are a published interface now, so they have to be written down.
exit_doc_drift=0
for code_line in \
    '#   0  nothing actionable' \
    '#   1  at least one release pin is STALE' \
    '#   2  usage error' \
    '#   3  nothing actionable was found, but at least one row is UNKNOWN'; do
    grep -qF -- "$code_line" tools/refresh-pins.sh \
        || { bad "refresh-pins.sh does not document: $code_line"; exit_doc_drift=1; }
done
grep -qF 'refresh-pins.sh --check --all' README.md \
    || { bad "README does not document --all"; exit_doc_drift=1; }
grep -qF 'exit 3' docs/CONFIGURATION.md \
    || { bad "docs/CONFIGURATION.md does not document the UNKNOWN exit code"; exit_doc_drift=1; }
(( exit_doc_drift == 0 )) && ok "the exit-code contract is documented where it is used"

section "Version checks survive a shadowing PATH"
# A machine with its own node/gh/uv earlier in PATH must not break the run, and
# must not silently satisfy a check with the wrong binary. Found by an
# end-to-end run on a host carrying a preinstalled Node.
grep -q '"$current/bin/node" --version' lib/bootstrap/node.sh \
    && ! grep -qE '\[\[ "\$\(node --version' lib/bootstrap/node.sh \
    && ok "Node is verified through the path it was installed to" \
    || bad "Node verification still resolves node through PATH"
grep -q 'export PATH="$current/bin:$PATH"' lib/bootstrap/node.sh \
    && ok "the pinned Node leads PATH for the npm steps that follow" \
    || bad "later steps may npm-install against an unpinned Node"
grep -q 'bootstrap_github_cli_installed_version /usr/local/bin/gh' lib/bootstrap/github_cli.sh \
    && ok "gh is verified through the path it was installed to" || bad "gh post-install verification"
grep -q 'bootstrap_uv_installed_version /usr/local/bin/uv' lib/bootstrap/uv.sh \
    && ok "uv is verified through the path it was installed to" || bad "uv post-install verification"
# The run summary is how an operator learns what is on the box, so it must
# never report a version read from a binary the bootstrap did not install.
grep -q '"$AI_CLI_PREFIX/bin/claude" --version' lib/bootstrap/ai_cli.sh \
    && grep -q '"$AI_CLI_PREFIX/bin/codex" --version' lib/bootstrap/ai_cli.sh \
    && ok "the summary reports the agent launchers that were installed" \
    || bad "agent versions in the summary still come from PATH"
grep -q '/usr/local/bin/uv --version' lib/bootstrap/report.sh \
    && ! grep -qE '\(command -v uv >/dev/null 2>&1 && uv --version' lib/bootstrap/report.sh \
    && ok "the report reads uv from the path it was installed to" \
    || bad "the uv report line still resolves uv through PATH"
# The pre-install short-circuit is meant to stay PATH-based: it asks whether a
# suitable binary is already usable, which is a different question.
grep -q 'if \[\[ "$(bootstrap_github_cli_installed_version)" == "$GH_VERSION" \]\]' lib/bootstrap/github_cli.sh \
    && ok "the gh already-installed short-circuit stays PATH-based" || bad "gh short-circuit changed"

section "Runtime installation of the new files"
for entry in 'server-secrets" "$stage/server-secrets' \
    'lib/secrets-load.sh" "$stage/lib/secrets-load.sh' \
    'examples/secrets.env.example" "$stage/examples/secrets.env.example' \
    'examples/pi-models.example.json" "$stage/examples/pi-models.example.json'; do
    grep -qF -- "$entry" lib/bootstrap/runtime.sh \
        && ok "runtime installs $(printf '%s' "$entry" | cut -d'"' -f1)" \
        || bad "runtime.sh does not install $entry"
done
grep -q 'ln -sfn "$destination/server-secrets" /usr/local/bin/server-secrets' lib/bootstrap/runtime.sh \
    && ok "server-secrets is linked into PATH" || bad "server-secrets link"
grep -q 'STEP=secrets; bootstrap_secrets' server-bootstrap.sh \
    && grep -q 'STEP=pi-config; bootstrap_pi_config' server-bootstrap.sh \
    && ok "the entrypoint runs the new steps" || bad "entrypoint wiring"

section "Fitness: shipped version strings match VERSION"
# 1.3.2 shipped headers still advertising 1.3.1 because config.example.env and
# checksums/*.txt are neither Markdown nor shell and were missed by a bump that
# only grepped those. A file may not claim a version that VERSION disagrees with.
# CHANGELOG.md and docs/TROUBLESHOOTING.md are excluded: they cite history.
declared="$(tr -d '[:space:]' < VERSION)"
version_drift=0
grep -q "BOOTSTRAP_VERSION=\"$declared\"" lib/bootstrap/config.sh \
    || { bad "BOOTSTRAP_VERSION does not match VERSION ($declared)"; version_drift=1; }
grep -qF "V=$declared" README.md \
    || { bad "README download snippet does not pin V=$declared"; version_drift=1; }
while IFS= read -r hit; do
    [[ -n "$hit" ]] || continue
    bad "stale version string: $hit"
    version_drift=1
done < <(grep -rnoE 'server-bootstrap[ -]v?[0-9]+\.[0-9]+\.[0-9]+' \
    README.md config.example.env checksums/*.txt docs/PROVISIONING.md examples/*.sh 2>/dev/null \
    | grep -vF "server-bootstrap $declared" \
    | grep -vF "server-bootstrap-$declared" || true)
(( version_drift == 0 )) && ok "shipped version strings match VERSION"

section "Results"
printf 'PASS: %d   FAIL: %d\n' "$PASS" "$FAIL"
# A stale manifest is the one failure here that is routine, mechanical, and not
# a defect in the change under test: a bot edits a tracked workflow file and
# cannot run the regeneration command. See #41. The message exists further up in
# release-files' own output, but the last line of a 300-assertion run is what
# anyone actually reads, so the remedy is repeated where it will be seen.
if (( MANIFEST_STALE )); then
    printf '\n%s\n' "----------------------------------------------------------------"
    printf 'checksums/SHA256SUMS is stale. Regenerate and commit it:\n\n'
    printf '    bash release/release-files.sh write\n\n'
    printf 'The workflow files are tracked, so they are part of the canonical\n'
    printf 'release set and the manifest covers them. This is not an\n'
    printf 'incompatibility in the change under test.\n'
    printf '%s\n' "----------------------------------------------------------------"
fi
(( FAIL == 0 ))
