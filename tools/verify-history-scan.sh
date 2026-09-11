#!/usr/bin/env bash
# Proves the CI scan configuration catches a secret that exists only in an older
# reachable commit -- exactly the case a shallow checkout or a working-tree-only
# scan misses. Acceptance evidence for SECURITY-PREVENTION-01.4.
#
# The fixture repository lives in a temp directory and the fake token is
# assembled at runtime from a fixed seed, so no key-shaped string is ever
# written into this repository or its history. That matters: the secret-scan job
# reads full history, so a committed fixture could only be removed by rewriting
# history, which SECURITY-PREVENTION-01.9 forbids.
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
BIN="$("$ROOT/tools/gitleaks.sh" path)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

repo="$WORK/history-fixture"
mkdir -p "$repo"
git -C "$repo" init --quiet --initial-branch=main
git -C "$repo" config user.email "history-scan@example.com"
git -C "$repo" config user.name "History Scan Fixture"

# Deterministic, high-entropy, and obviously synthetic. Reconstructed on every
# run rather than stored, so grepping this file finds a recipe, not a token.
token="sk-$(printf 'server-bootstrap-history-scan-fixture' | sha256sum | cut -c1-40)"

printf 'api_key = "%s"\n' "$token" > "$repo/service.conf"
git -C "$repo" add service.conf
git -C "$repo" commit --quiet -m "Older commit that introduced a credential"
old_commit="$(git -C "$repo" rev-parse --short HEAD)"

git -C "$repo" rm --quiet service.conf
git -C "$repo" commit --quiet -m "Later commit that deleted the file"
head_commit="$(git -C "$repo" rev-parse --short HEAD)"

printf '==> Fixture: secret added in %s, file deleted in %s (HEAD)\n' "$old_commit" "$head_commit"

# 1. A working-tree-only scan must MISS it. This is the control: it shows the
#    finding below comes from history and not from the checked-out files.
if "$BIN" detect --source "$repo" --no-git \
    --config "$ROOT/.gitleaks.toml" --redact --exit-code 1 --no-banner >/dev/null 2>&1; then
    printf '  ok:   working-tree-only scan finds nothing (the secret is not in HEAD)\n'
else
    printf '  FAIL: working-tree-only scan reported a finding; fixture is not testing history\n' >&2
    exit 1
fi

# 2. The scan CI actually runs must FIND it.
report="$WORK/history-findings.txt"
if "$BIN" detect --source "$repo" \
    --config "$ROOT/.gitleaks.toml" --log-opts='--all' --redact --exit-code 1 --no-banner \
    >"$report" 2>&1; then
    printf '  FAIL: full-history scan missed a secret in an older reachable commit\n' >&2
    exit 1
fi
printf '  ok:   full-history scan detects the secret in older commit %s\n' "$old_commit"

# 3. The finding must be reported without reprinting the credential.
if grep -qF -- "$token" "$report"; then
    printf '  FAIL: scan output contains the unredacted secret value\n' >&2
    exit 1
fi
printf '  ok:   the finding is reported redacted, not as a literal value\n'

grep -E 'RuleID|Commit' "$report" | sed 's/^/        /' || true
printf '\nFull-history scanning verified against the pinned Gitleaks v%s.\n' \
    "$("$ROOT/tools/gitleaks.sh" version)"
