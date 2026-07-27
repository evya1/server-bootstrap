#!/usr/bin/env bash

bootstrap_uv() {
    [[ "$INSTALL_UV" == 1 ]] || return 0
    command -v uv >/dev/null 2>&1 && { uv --version; return 0; }
    [[ "$(uname -m)" == x86_64 ]] || { gsb_warn "automatic uv install currently supports x86_64 only"; return 0; }
    if [[ -z "$UV_SHA256" ]]; then
        gsb_warn "UV_SHA256 is empty; refusing an unverified uv install"
        gsb_warn "set UV_VERSION and UV_SHA256, or set INSTALL_UV=0"
        return 0
    fi
    local temp archive
    temp="$(mktemp -d)"; archive="$temp/uv.tar.gz"
    trap 'rm -rf -- "$temp"' RETURN
    gsb_log "installing uv $UV_VERSION (pinned and checksum-verified)"
    gsb_fetch_verified \
        "https://github.com/astral-sh/uv/releases/download/$UV_VERSION/uv-x86_64-unknown-linux-gnu.tar.gz" \
        "$UV_SHA256" "$archive" || return
    gsb_extract_archive "$archive" "$temp/extracted"
    local binary
    for binary in uv uvx; do
        local found
        found="$(find "$temp/extracted" -type f -name "$binary" -print -quit)"
        [[ -n "$found" ]] || { gsb_warn "$binary not found in uv archive"; continue; }
        install -m 0755 "$found" "/usr/local/bin/$binary"
    done
    uv --version
}
