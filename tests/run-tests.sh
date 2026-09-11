#!/usr/bin/env bash
set -Euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$ROOT"
PASS=0; FAIL=0
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

# The upload gate must come after the build and before the publish action.
gate="$(grep -n 'scan-artifacts release/dist' .github/workflows/release.yml | cut -d: -f1 | head -1)"
build_at="$(grep -n 'name: Build release' .github/workflows/release.yml | cut -d: -f1 | head -1)"
publish_at="$(grep -n 'name: Publish assets' .github/workflows/release.yml | cut -d: -f1 | head -1)"
if [[ -n "$gate" && -n "$build_at" && -n "$publish_at" ]] \
    && (( build_at < gate && gate < publish_at )); then
    ok "release.yml scans release/dist between build and upload"
else
    bad "release.yml has no scan gate between build and upload"
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
for workflow in .github/workflows/ci.yml .github/workflows/release.yml; do
    grep -qE 'gitleaks_[0-9]+\.[0-9]+\.[0-9]+_linux|GITLEAKS_SHA256' "$workflow" \
        && { bad "$workflow carries its own Gitleaks pin"; pin_drift=1; }
    grep -qF 'tools/gitleaks.sh' "$workflow" \
        || { bad "$workflow does not scan through tools/gitleaks.sh"; pin_drift=1; }
done
(( pin_drift == 0 )) && ok "both workflows scan through the single pinned helper"
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

section "Release rehearsal in CI"
# release.yml only runs on a tag push, so its checkout is detached, one commit
# deep, and carries a single tag. ci.yml is triggered by every push including
# that one, so it does see the shape -- but only at the moment the tag lands,
# which is after the version number has been spent and SECURITY.md forbids
# reusing it. That is how PASS: 233 FAIL: 4 reached the v2.2.1 release instead
# of a pull request: ci.yml's release-build job failed with it three seconds
# before the release job did, and both were too late. ci.yml's tag-checkout job
# manufactures the shape on every branch push and pull request; these assertions
# keep it from being quietly deleted or defanged.
# Every check in this section reads the workflows with comment lines removed. A
# command named only in a comment is not a command that runs, and an assertion a
# comment can satisfy asserts nothing: commenting out the whole scan-artifacts
# step once left the check below still reporting that ci.yml ran it, and the
# job's own prose saying it does not set SB_CHECK_PUBLISHED_TAGS once failed the
# check for setting it. Whole-line stripping is enough -- every comment in these
# files, including the shell comments inside run: blocks, is on its own line.
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
run the test suite|bash tests/run-tests.sh
run the release build|bash release/build-release.sh
REHEARSAL
    # The opt-in would hand the job every tag and hide the one shape it exists
    # to reproduce, so its absence is the assertion.
    if grep -qF -- 'SB_CHECK_PUBLISHED_TAGS' <<< "$tag_job"; then
        bad "the tag-checkout job sets SB_CHECK_PUBLISHED_TAGS, hiding the shape it tests"
        rehearsal_drift=1
    fi
fi
(( rehearsal_drift == 0 )) && ok "ci.yml rehearses the release under a tag-shaped checkout"

# The general form of that bug: a command whose first execution is the release.
# Every script release.yml invokes must also be invoked by some ci.yml job, so a
# release-only code path cannot be introduced without this failing.
#
# Each invocation is normalised to "<repo-relative path> <subcommand>" so that
# spelling is not part of the key: bash tools/x.sh, sh ./tools/x.sh and
# bash "$ROOT/tools/x.sh" are one command and must not be able to hide from each
# other. A .sh path counts only where something actually runs it, which is what
# keeps release.yml's files: list -- it names .sh release assets -- from being
# read as a set of commands.
workflow_commands() {
    grep -vE '^[[:space:]]*#' "$1" | tr -s '[:space:]' '\n' | awk '
        {
            t = $0
            gsub(/^["\047(]+/, "", t); gsub(/["\047)]+$/, "", t)
            if (pending != "") {
                if (t ~ /^[A-Za-z][A-Za-z0-9_-]*$/ && t !~ /\.sh$/) print pending " " t
                else print pending
                pending = ""
            }
            if (t ~ /\.sh$/ && (prev == "bash" || prev == "sh" || prev == "source" \
                || prev == "." || prev ~ /\$\((bash|sh|source)$/ || t ~ /^\.\//)) {
                sub(/^\.\//, "", t)
                sub(/^\$\{?[A-Za-z_][A-Za-z0-9_]*\}?\//, "", t)
                pending = t
            }
            prev = t
        }
        END { if (pending != "") print pending }
    ' | LC_ALL=C sort -u
}
ci_commands="$(workflow_commands .github/workflows/ci.yml)"
while IFS= read -r command; do
    [[ -n "$command" ]] || continue
    # -x, not a substring match: "gitleaks.sh scan" must not be satisfied by
    # "gitleaks.sh scan-history".
    grep -qFx -- "$command" <<< "$ci_commands" \
        && ok "ci.yml also runs '$command'" \
        || bad "release.yml runs '$command' but no ci.yml job does"
done < <(workflow_commands .github/workflows/release.yml)

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
grep -q 'INSTALL_NODEJS="${INSTALL_NODEJS:-1}"' lib/bootstrap/config.sh \
    && grep -q 'NODE_VERSION="${NODE_VERSION:-24.21.0}"' lib/bootstrap/config.sh \
    && grep -q 'fd8e59d5a511510f6a298afb548f18c7d2b1be404d8b4a27d94fbe49f56cb2d6' lib/bootstrap/config.sh \
    && grep -q '6ad1325edbdb5649c379b75a237147a666c95d4f9ae8d340fef2d1575d289ad2' lib/bootstrap/config.sh \
    && ok "Node.js LTS is enabled and checksum pinned" || bad "Node.js defaults/checksums"
grep -q 'INSTALL_CLAUDE_CODE="${INSTALL_CLAUDE_CODE:-1}"' lib/bootstrap/config.sh \
    && grep -q 'CLAUDE_CODE_VERSION="${CLAUDE_CODE_VERSION:-2.1.268}"' lib/bootstrap/config.sh \
    && grep -q '@anthropic-ai/claude-code@' lib/bootstrap/ai_cli.sh \
    && grep -q 'CLAUDE_CODE_DISABLE_AUTOUPDATER="${CLAUDE_CODE_DISABLE_AUTOUPDATER:-1}"' lib/bootstrap/config.sh \
    && grep -q 'export DISABLE_AUTOUPDATER=1' lib/bootstrap/ai_cli.sh \
    && ok "Claude Code is enabled, pinned, and update-controlled" || bad "Claude Code defaults/pin"
grep -q 'INSTALL_CODEX="${INSTALL_CODEX:-1}"' lib/bootstrap/config.sh \
    && grep -q 'CODEX_VERSION="${CODEX_VERSION:-0.154.0}"' lib/bootstrap/config.sh \
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

section "Fitness: README tool versions match the pinned defaults"
# README.md's "What the run installs" table names five tool versions that
# lib/bootstrap/config.sh also pins. tools/refresh-pins.sh --write rewrites the
# config and the checksum files; before this test existed the README was left to
# a log line, so a pin bump made the README quietly wrong. Same failure mode as
# the VERSION drift above: a second copy of a value with nothing asserting the
# two agree. The default is read out of config.sh by pattern, not by sourcing
# it, so an ambiguous variable in the maintainer's environment cannot be
# mistaken for what the repository pins -- the same reason refresh-pins.sh
# reads it that way.
readme_pin_drift=0
while IFS='|' read -r label var; do
    [[ -n "$label" ]] || continue
    declared="$(sed -n "s|^[[:space:]]*$var=\"\\\${$var:-\(.*\)}\"[[:space:]]*\$|\1|p" \
        lib/bootstrap/config.sh | head -n1)"
    if [[ -z "$declared" ]]; then
        bad "no default for $var in lib/bootstrap/config.sh"; readme_pin_drift=1; continue
    fi
    # Dots are escaped and the right-hand side is bounded, so a README claiming
    # "pi 0.85.10" cannot satisfy a pinned "pi 0.85.1". \b on the left keeps
    # "pi" from matching inside "api".
    label_re="${label//./\\.}"
    version_re="${declared//./\\.}"
    grep -qE "\b$label_re $version_re([^0-9.]|\$)" README.md \
        || { bad "README does not name the pinned $label ($declared)"; readme_pin_drift=1; }
    # The forward check alone passes a README that names the pinned version and
    # a stale one elsewhere, so every version this label carries must agree.
    while IFS= read -r hit; do
        [[ -n "$hit" ]] || continue
        bad "README says '$hit' but config.sh pins $label $declared"
        readme_pin_drift=1
    done < <(grep -oE "\b$label_re [0-9]+\.[0-9]+\.[0-9]+" README.md \
        | grep -vFx "$label $declared" || true)
done <<'PINS'
GitHub CLI|GH_VERSION
Node.js|NODE_VERSION
Claude Code|CLAUDE_CODE_VERSION
OpenAI Codex|CODEX_VERSION
pi|PI_VERSION
PINS
(( readme_pin_drift == 0 )) && ok "README tool versions match the pinned defaults"

section "Results"
printf 'PASS: %d   FAIL: %d\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
