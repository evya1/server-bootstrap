#!/usr/bin/env bash
# Deterministic repository privacy and secret guards (SECURITY-PREVENTION-01.5).
#
#   tests/privacy-guard.sh              guard this repository's tracked files
#   tests/privacy-guard.sh --dir DIR    guard an arbitrary tree (test fixtures)
#
# These run before CI or release scanning and catch the cheap cases locally:
# credential-shaped filenames, private-key material, high-signal credential
# assignments, generated artifacts that should never be tracked, private-use
# wording, and an allowlist that has quietly grown.
#
# Properties the tests depend on: no network, no clock, no account lookup, no
# entropy sampling, and output that names the violated policy and the location
# but never reprints the matching text. Scope comes from git ls-files (or an
# explicit directory), so the result does not depend on the checkout path or on
# untracked scratch files.
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
MODE=repo
TARGET="$ROOT"

while (( $# )); do
    case "$1" in
        --dir) MODE=dir; TARGET="${2:?--dir needs a directory}"; shift 2 ;;
        -h|--help) sed -n '2,8p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) printf 'privacy-guard: unknown argument: %s\n' "$1" >&2; exit 2 ;;
    esac
done

violations=0
report() {
    printf 'VIOLATION: %s: %s\n' "$1" "$2"
    violations=$((violations + 1))
}

# ---------------------------------------------------------------------------
# Scope
# ---------------------------------------------------------------------------
files=()
if [[ "$MODE" == repo ]]; then
    while IFS= read -r -d '' f; do files+=("$f"); done \
        < <(git -C "$TARGET" ls-files -z)
else
    [[ -d "$TARGET" ]] || { printf 'privacy-guard: not a directory: %s\n' "$TARGET" >&2; exit 2; }
    TARGET="$(cd -- "$TARGET" && pwd -P)"
    while IFS= read -r -d '' f; do files+=("${f#./}"); done \
        < <(cd -- "$TARGET" && find . -type f -print0 | LC_ALL=C sort -z)
fi

# ---------------------------------------------------------------------------
# Policy: credential, private-key, secret-store, and local-config filenames
# ---------------------------------------------------------------------------
# Deliberately mirrors .gitignore. A file matching one of these should have been
# ignored; finding one in the tracked set means an ignore rule was bypassed.
forbidden_names='(^|/)(\.env(\..+)?|.+\.env(\..+)?|.+\.(pem|key|p12|pfx|jks|keystore|token|tokens|tfstate(\..+)?)|id_(rsa|dsa|ecdsa|ed25519)|\.?(npmrc|pypirc|netrc)|credentials|kubeconfig.*|.*\.kubeconfig)$'
# The two example templates .gitignore re-includes on purpose, and nothing else.
approved_examples='^(config\.example\.env|examples/[^/]+\.env\.example)$'

for f in "${files[@]}"; do
    [[ "$f" =~ $forbidden_names ]] || continue
    [[ "$f" =~ $approved_examples ]] && continue
    report "credential-or-config-filename" "$f"
done

for f in "${files[@]}"; do
    case "$f" in
        credentials/*|secrets/*|*/credentials/*|*/secrets/*|config/*.local|config/*.local.*|config/*.secret|config/*.secret.*)
            report "credential-or-config-filename" "$f" ;;
    esac
done

# ---------------------------------------------------------------------------
# Policy: generated artifacts must not be tracked
# ---------------------------------------------------------------------------
# checksums/SHA256SUMS is generated too, but it ships inside the archive and is
# refreshed by release/build-release.sh, so it is intentionally tracked.
for f in "${files[@]}"; do
    case "$f" in
        release/dist/*|*.tar|*.tar.gz|*.tgz|*.tar.xz|*.txz|*.zip|*.log)
            report "generated-artifact-tracked" "$f" ;;
    esac
done

# ---------------------------------------------------------------------------
# Content policies
# ---------------------------------------------------------------------------
# Written as character classes so the patterns themselves are not key-shaped:
# the secret scanner reads this file too, and a literal example would have to be
# removed by rewriting history, which SECURITY-PREVENTION-01.9 forbids.

# PEM private-key headers. "-----BEGIN" here is followed by "[", which the
# scanner's own private-key rule cannot match, so this line is inert.
private_key_header='-----BEGIN[ A-Za-z0-9]*PRIVATE KEY( BLOCK)?-----'

# A credential-ish name assigned a long, token-shaped value. Placeholders, empty
# values, and variable references are excluded below rather than in the regex.
credential_assignment='(api[_-]?key|secret[_-]?(key|token)?|access[_-]?key|auth[_-]?token|[a-z]*token|password|passwd)["'"'"']?[[:space:]]*[:=][[:space:]]*["'"'"']?[A-Za-z0-9_+/=~.-]{20,}'

# Vendor prefixes with a length floor. Each prefix is followed by a character
# class, so none of these lines is itself a well-formed token.
vendor_token='(sk-[A-Za-z0-9_-]{24,}|ghp_[A-Za-z0-9]{30,}|gho_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}|xox[baprs]-[A-Za-z0-9-]{20,}|AIza[A-Za-z0-9_-]{30,}|ya29\.[A-Za-z0-9_-]{30,})'

# Credentials embedded in a URL. Loopback and example hosts are still flagged:
# a password belongs in neither.
url_credentials='[a-zA-Z][a-zA-Z0-9+.-]*://[^/[:space:]:"'"'"']+:[^/[:space:]@"'"'"']+@'

# Values the repository has approved as non-secret examples. Kept in step with
# the .gitleaks.toml allowlist reviewed under SECURITY-PREVENTION-01.7.
placeholder='(CHANGE_ME|EXAMPLE_TOKEN|YOUR_[A-Z_]+|<[^>]+>|\$\{?[A-Za-z_][A-Za-z0-9_]*\}?|x{8,}|X{8,}|0{16,}|\.{3,})'

scan_content() {
    local file="$1" rel="$2" pattern="$3" policy="$4" line
    # -I skips binary files; only the line number is ever reported.
    while IFS=: read -r line _; do
        [[ -n "$line" ]] || continue
        report "$policy" "$rel:$line"
    done < <(grep -nIE -- "$pattern" "$file" 2>/dev/null || true)
}

for f in "${files[@]}"; do
    path="$TARGET/$f"
    [[ -f "$path" ]] || continue
    scan_content "$path" "$f" "$private_key_header" "private-key-material"
    scan_content "$path" "$f" "$url_credentials" "url-embedded-credentials"
    scan_content "$path" "$f" "$vendor_token" "vendor-credential-marker"

    # The assignment rule is the noisy one, so drop lines whose value is an
    # approved placeholder or an unset variable before reporting.
    while IFS=: read -r line text; do
        [[ -n "$line" ]] || continue
        [[ "$text" =~ $placeholder ]] && continue
        report "credential-assignment" "$f:$line"
    done < <(grep -nIE -- "$credential_assignment" "$path" 2>/dev/null || true)
done

# ---------------------------------------------------------------------------
# Policy: no private-use wording in the acceptance script
# ---------------------------------------------------------------------------
# server-accept.sh is read by whoever is evaluating a rented machine; wording
# that assumes the reader personally rented it leaks how this repo is used.
if [[ -f "$TARGET/server-accept.sh" ]]; then
    while IFS= read -r phrase; do
        [[ -n "$phrase" ]] || continue
        if grep -Fqi -- "$phrase" "$TARGET/server-accept.sh"; then
            report "private-use-wording" "server-accept.sh ($phrase)"
        fi
    done <<'PHRASES'
box you just rented
box you bought
while the meter is running
rental scam
someone's garage
destroy this instance and rent another
PHRASES
fi

# ---------------------------------------------------------------------------
# Policy: the scanner allowlist stays exactly as approved
# ---------------------------------------------------------------------------
# A broad allowlist is the usual way a preserved finding gets silenced instead of
# remediated, which SECURITY-PREVENTION-01.9 rules out.
if [[ -f "$TARGET/.gitleaks.toml" ]]; then
    approved_allowlist=$'^/root(?:/.*)?$\n^/workspace(?:/.*)?$\n^localhost(?::[0-9]+)?$\n^127\\.0\\.0\\.1(?::[0-9]+)?$\n^::1(?::[0-9]+)?$\n^example\\.(?:com|org|net)$\n^(?:CHANGE_ME|EXAMPLE_TOKEN)$'
    while IFS= read -r entry; do
        [[ -n "$entry" ]] || continue
        grep -Fqx -- "$entry" <<<"$approved_allowlist" \
            || report "allowlist-not-approved" ".gitleaks.toml ($entry)"
    done < <(sed -n "s/^  '''\(.*\)''',\?$/\1/p" "$TARGET/.gitleaks.toml")

    if grep -qE '(^|[[:space:]])(paths|regexes|commits|stopwords)[[:space:]]*=.*\.\*' "$TARGET/.gitleaks.toml"; then
        report "allowlist-too-broad" ".gitleaks.toml"
    fi
fi

# ---------------------------------------------------------------------------
if (( violations > 0 )); then
    printf '\nprivacy-guard: %d violation(s) in %s\n' "$violations" "$TARGET" >&2
    exit 1
fi
printf 'privacy-guard: clean (%d files checked in %s)\n' "${#files[@]}" "$TARGET"
