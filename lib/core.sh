#!/usr/bin/env bash
# Shared, side-effect-free helpers. Entry points enable strict mode.

[[ -n "${GSB_CORE_LOADED:-}" ]] && return 0
GSB_CORE_LOADED=1

GSB_LOG_PREFIX="${GSB_LOG_PREFIX:-gpu-server-bootstrap}"

gsb_log()  { printf '%s | %s | %s\n' "$(date -u +%H:%M:%SZ)" "$GSB_LOG_PREFIX" "$*"; }
gsb_warn() { printf '%s | %s | WARN: %s\n' "$(date -u +%H:%M:%SZ)" "$GSB_LOG_PREFIX" "$*" >&2; }
gsb_die()  { gsb_warn "$*"; return 1; }

gsb_retry() {
    local attempts="$1"; shift
    local delay=5 n=1
    while true; do
        if "$@"; then return 0; fi
        if (( n >= attempts )); then
            gsb_warn "command failed after $attempts attempts: $*"
            return 1
        fi
        gsb_warn "attempt $n/$attempts failed; retry in ${delay}s"
        sleep "$delay"
        n=$((n + 1)); delay=$((delay * 2)); (( delay > 60 )) && delay=60
    done
}

gsb_require_root() {
    (( EUID == 0 )) || gsb_die "run as root (use sudo)"
}

gsb_ensure_line() {
    local file="$1" line="$2"
    grep -Fqx "$line" "$file" 2>/dev/null || printf '%s\n' "$line" >> "$file"
}

gsb_valid_sha256() { [[ "${1:-}" =~ ^[0-9a-fA-F]{64}$ ]]; }

gsb_sha256() { sha256sum -- "$1" | awk '{print $1}'; }

gsb_read_sha256_file() {
    local file="$1" value
    [[ -f "$file" ]] || gsb_die "checksum file not found: $file" || return
    value="$(grep -Eo '[0-9a-fA-F]{64}' "$file" | head -n1 || true)"
    gsb_valid_sha256 "$value" || gsb_die "no SHA-256 found in: $file" || return
    printf '%s\n' "${value,,}"
}

gsb_verify_file() {
    local file="$1" expected="$2" actual
    [[ -f "$file" ]] || gsb_die "file not found: $file" || return
    gsb_valid_sha256 "$expected" || gsb_die "invalid SHA-256: $expected" || return
    actual="$(gsb_sha256 "$file")"
    [[ "${actual,,}" == "${expected,,}" ]] \
        || gsb_die "checksum mismatch for $file: expected $expected, got $actual" || return
    gsb_log "checksum OK: $(basename -- "$file")"
}

gsb_fetch_verified() {
    local url="$1" expected="$2" destination="$3"
    [[ "$url" == https://* ]] || gsb_die "remote source must use HTTPS: $url" || return
    gsb_retry 4 curl -fL --proto '=https' --tlsv1.2 -o "$destination.part" "$url" || return
    mv -f -- "$destination.part" "$destination"
    gsb_verify_file "$destination" "$expected"
}

gsb_resolve_path() {
    local base="$1" path="$2"
    if [[ "$path" == /* ]]; then
        realpath -m -- "$path"
    else
        realpath -m -- "$base/$path"
    fi
}
