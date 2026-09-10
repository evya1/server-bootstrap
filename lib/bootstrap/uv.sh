#!/usr/bin/env bash

bootstrap_uv_arch() {
    case "$(uname -m)" in
        x86_64|amd64) printf 'x86_64-unknown-linux-gnu\n' ;;
        aarch64|arm64) printf 'aarch64-unknown-linux-gnu\n' ;;
        *) sb_die "unsupported uv architecture: $(uname -m)" ;;
    esac
}

bootstrap_uv_checksum() {
    case "$1" in
        x86_64-unknown-linux-gnu) printf '%s\n' "$UV_SHA256_X64" ;;
        aarch64-unknown-linux-gnu) printf '%s\n' "$UV_SHA256_ARM64" ;;
        *) sb_die "unsupported uv architecture token: $1" ;;
    esac
}

bootstrap_uv_installed_version() {
    local binary="${1:-uv}"
    command -v "$binary" >/dev/null 2>&1 || return 0
    "$binary" --version 2>/dev/null | awk 'NR == 1 { print $2 }'
}

bootstrap_uv() {
    [[ "$INSTALL_UV" == 1 ]] || return 0

    local target checksum name url temp archive binary found
    target="$(bootstrap_uv_arch)" || return

    if sb_is_latest "$UV_VERSION"; then
        UV_VERSION="$(sb_latest_git_tag https://github.com/astral-sh/uv.git '^[0-9]+\.[0-9]+\.[0-9]+$')" || return
        sb_log "resolved latest uv: $UV_VERSION"
        UV_SHA256_X64=""
        UV_SHA256_ARM64=""
    fi

    # Presence alone is not enough: a pinned bump has to actually upgrade.
    if [[ "$(bootstrap_uv_installed_version)" == "$UV_VERSION" ]]; then
        sb_log "uv $UV_VERSION already installed"
        return 0
    fi

    name="uv-$target"
    url="https://github.com/astral-sh/uv/releases/download/$UV_VERSION/$name.tar.gz"
    checksum="$(bootstrap_uv_checksum "$target")" || return
    if [[ -z "$checksum" ]]; then
        checksum="$(sb_checksum_from_manifest "$url.sha256" "$name.tar.gz")" || return
    fi
    if ! sb_valid_sha256 "$checksum"; then
        sb_warn "no verified checksum for uv $UV_VERSION ($target); refusing an unverified install"
        sb_warn "set UV_SHA256_X64 and UV_SHA256_ARM64, use UV_VERSION=latest, or set INSTALL_UV=0"
        return 0
    fi

    temp="$(mktemp -d)"; archive="$temp/$name.tar.gz"
    trap 'rm -rf -- "$temp"' RETURN
    sb_log "installing uv $UV_VERSION ($target, checksum-verified)"
    sb_fetch_verified "$url" "$checksum" "$archive" || return
    sb_extract_archive "$archive" "$temp/extracted" || return
    for binary in uv uvx; do
        found="$(find "$temp/extracted" -type f -name "$binary" -print -quit)"
        [[ -n "$found" ]] || { sb_warn "$binary not found in uv archive"; continue; }
        install -m 0755 "$found" "/usr/local/bin/$binary"
    done

    [[ "$(bootstrap_uv_installed_version /usr/local/bin/uv)" == "$UV_VERSION" ]] \
        || { sb_die "uv version verification failed"; return; }
    printf '%s\n' "$UV_VERSION" > "$STATE_ROOT/uv-version"
    sb_log "installed uv $UV_VERSION ($target)"
}
