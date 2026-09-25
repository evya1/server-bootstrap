#!/usr/bin/env bash
# Shared, side-effect-free helpers. Entry points enable strict mode.

[[ -n "${SB_CORE_LOADED:-}" ]] && return 0
SB_CORE_LOADED=1

SB_LOG_PREFIX="${SB_LOG_PREFIX:-server-bootstrap}"

sb_log()  { printf '%s | %s | %s\n' "$(date -u +%H:%M:%SZ)" "$SB_LOG_PREFIX" "$*"; }
sb_warn() { printf '%s | %s | WARN: %s\n' "$(date -u +%H:%M:%SZ)" "$SB_LOG_PREFIX" "$*" >&2; }
sb_die()  { sb_warn "$*"; return 1; }

sb_retry() {
    local attempts="$1"; shift
    local delay=5 n=1
    while true; do
        if "$@"; then return 0; fi
        if (( n >= attempts )); then
            sb_warn "command failed after $attempts attempts: $*"
            return 1
        fi
        sb_warn "attempt $n/$attempts failed; retry in ${delay}s"
        sleep "$delay"
        n=$((n + 1)); delay=$((delay * 2)); (( delay > 60 )) && delay=60
    done
}

sb_require_root() {
    (( EUID == 0 )) || sb_die "run as root (use sudo)"
}

# --- Supported platform ----------------------------------------------------
# Ubuntu 24.04 on x86-64 or ARM64, with a matching dpkg architecture: a 32-bit
# userland on a 64-bit kernel would take apt packages for one architecture and
# checksummed binaries for the other. server-provision.sh is downloaded on its
# own, so it carries a standalone copy of this check; the test suite runs both
# over the same hosts.

# sb_os_release_value FILE KEY -> the value, without its quotes
sb_os_release_value() {
    sed -n "s/^$2=//p" "$1" 2>/dev/null | head -n1 | sed -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'\$/\1/"
}

# sb_platform_problem OS_RELEASE_FILE MACHINE DPKG_ARCH
# Prints why the host is unsupported; prints nothing when it is supported.
sb_platform_problem() {
    local file="$1" machine="$2" dpkg_arch="$3" id version
    [[ -r "$file" ]] || { echo "cannot read $file (supported: Ubuntu 24.04)"; return; }
    id="$(sb_os_release_value "$file" ID)"
    version="$(sb_os_release_value "$file" VERSION_ID)"
    [[ "$id" == ubuntu && "$version" == 24.04 ]] \
        || { echo "unsupported operating system: ${id:-unknown} ${version:-unknown} (supported: Ubuntu 24.04)"; return; }
    case "$machine:$dpkg_arch" in
        x86_64:amd64|aarch64:arm64) ;;
        x86_64:*|aarch64:*) echo "dpkg architecture ${dpkg_arch:-unknown} does not match $machine (supported: amd64 on x86_64, arm64 on aarch64)" ;;
        *) echo "unsupported architecture: ${machine:-unknown} (supported: x86_64, aarch64)" ;;
    esac
}

# Runs before anything is created or installed. SB_OS_RELEASE_FILE is a test
# seam for the suite's fixtures, not a supported setting.
sb_require_supported_platform() {
    local problem
    problem="$(sb_platform_problem "${SB_OS_RELEASE_FILE:-/etc/os-release}" "$(uname -m)" \
        "$(dpkg --print-architecture 2>/dev/null || true)")"
    [[ -z "$problem" ]] || sb_die "$problem; nothing was installed or created"
}

sb_ensure_line() {
    local file="$1" line="$2"
    grep -Fqx "$line" "$file" 2>/dev/null || printf '%s\n' "$line" >> "$file"
}

sb_valid_sha256() { [[ "${1:-}" =~ ^[0-9a-fA-F]{64}$ ]]; }

sb_sha256() { sha256sum -- "$1" | awk '{print $1}'; }

sb_read_sha256_file() {
    local file="$1" value
    [[ -f "$file" ]] || sb_die "checksum file not found: $file" || return
    value="$(grep -Eo '[0-9a-fA-F]{64}' "$file" | head -n1 || true)"
    sb_valid_sha256 "$value" || sb_die "no SHA-256 found in: $file" || return
    printf '%s\n' "${value,,}"
}

sb_verify_file() {
    local file="$1" expected="$2" actual
    [[ -f "$file" ]] || sb_die "file not found: $file" || return
    sb_valid_sha256 "$expected" || sb_die "invalid SHA-256: $expected" || return
    actual="$(sb_sha256 "$file")"
    [[ "${actual,,}" == "${expected,,}" ]] \
        || sb_die "checksum mismatch for $file: expected $expected, got $actual" || return
    sb_log "checksum OK: $(basename -- "$file")"
}

sb_fetch_verified() {
    local url="$1" expected="$2" destination="$3"
    [[ "$url" == https://* ]] || sb_die "remote source must use HTTPS: $url" || return
    sb_retry 4 curl -fL --proto '=https' --tlsv1.2 -o "$destination.part" "$url" || return
    mv -f -- "$destination.part" "$destination"
    sb_verify_file "$destination" "$expected"
}

sb_resolve_path() {
    local base="$1" path="$2"
    if [[ "$path" == /* ]]; then
        realpath -m -- "$path"
    else
        realpath -m -- "$base/$path"
    fi
}

# --- Upstream version resolution -------------------------------------------
# Used only when a version variable is set to the literal "latest". The
# resolved checksum still goes through sb_fetch_verified, so the download path
# and its sb_valid_sha256 gate are identical to a pinned install.

sb_is_latest() { [[ "${1:-}" == latest ]]; }

# Newest tag of a remote Git repository, without the GitHub API: no rate limit,
# no token, and reachable wherever plain Git over HTTPS is.
sb_latest_git_tag() {
    local url="$1" pattern="${2:-^v?[0-9]+\.[0-9]+\.[0-9]+$}" tag
    [[ "$url" == https://* ]] || sb_die "remote source must use HTTPS: $url" || return
    tag="$(sb_retry 4 git ls-remote --tags --refs "$url" 2>/dev/null \
        | awk '{print $2}' | sed 's|^refs/tags/||' \
        | grep -E "$pattern" | sort -V | tail -n1 || true)"
    [[ -n "$tag" ]] || sb_die "no tag matching $pattern at $url" || return
    printf '%s\n' "$tag"
}

# Pull one file's SHA-256 out of the text of an upstream checksum manifest.
# Handles both shapes publishers use: a "<hash>  <filename>" table and a bare
# sidecar. Kept separate from the fetch so it can be tested without a network.
sb_sha256_from_manifest_body() {
    local body="$1" filename="$2" value lines
    value="$(printf '%s\n' "$body" \
        | awk -v want="$filename" '{ for (i = 1; i <= NF; i++) if ($i == want || $i == "*" want) { print $1; exit } }')"
    if [[ -z "$value" ]]; then
        lines="$(printf '%s\n' "$body" | grep -c . || true)"
        (( lines == 1 )) && value="$(printf '%s\n' "$body" | awk '{print $1}')"
    fi
    sb_valid_sha256 "$value" || return 1
    printf '%s\n' "${value,,}"
}

sb_checksum_from_manifest() {
    local url="$1" filename="$2" body value
    [[ "$url" == https://* ]] || sb_die "remote source must use HTTPS: $url" || return
    body="$(sb_retry 4 curl -fsSL --proto '=https' --tlsv1.2 "$url" 2>/dev/null || true)"
    [[ -n "$body" ]] || sb_die "empty checksum manifest: $url" || return
    value="$(sb_sha256_from_manifest_body "$body" "$filename")" \
        || sb_die "no SHA-256 for $filename in manifest: $url" || return
    printf '%s\n' "$value"
}
