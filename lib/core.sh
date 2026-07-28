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
