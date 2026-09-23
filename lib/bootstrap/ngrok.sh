#!/usr/bin/env bash

# The ngrok agent CLI comes from the publisher's own apt repository, as one
# pinned and checksummed package file per architecture, rather than by adding
# that repository to apt. The package holds a single static binary at
# /usr/local/bin/ngrok and no maintainer scripts, so extracting that file is the
# whole installation: no apt source, no signing key, and nothing a later apt
# run can move. The SHA-256 values are the ones the repository's Packages index
# records for each package file.
#
# Only the CLI is installed. Nothing here asks for or writes a credential,
# writes an ngrok configuration file, starts a tunnel, or registers a service.

bootstrap_ngrok_arch() {
    case "$(uname -m)" in
        x86_64|amd64) printf 'amd64\n' ;;
        aarch64|arm64) printf 'arm64\n' ;;
        *) sb_die "unsupported ngrok architecture: $(uname -m) (supported: x86_64, aarch64)" ;;
    esac
}

bootstrap_ngrok_checksum() {
    case "$1" in
        amd64) printf '%s\n' "$NGROK_SHA256_X64" ;;
        arm64) printf '%s\n' "$NGROK_SHA256_ARM64" ;;
        *) sb_die "unsupported ngrok architecture token: $1" ;;
    esac
}

# ngrok documents the "buster" suite for every Debian-based system, and every
# package file in its pool carries the Debian revision -0.
bootstrap_ngrok_index_url() {
    printf 'https://ngrok-agent.s3.amazonaws.com/dists/buster/main/binary-%s/Packages\n' "$1"
}

bootstrap_ngrok_package_url() {
    printf 'https://ngrok-agent.s3.amazonaws.com/pool/main/n/ngrok/ngrok_%s-0_%s.deb\n' "$1" "$2"
}

# "<version> <sha256>" for one ngrok package in the text of an apt Packages
# index, or for the newest one when VERSION is "latest". Pure, so it is tested
# offline.
bootstrap_ngrok_index_entry() {
    local body="$1" want="$2" arch="$3" entry
    entry="$(printf '%s\n' "$body" | awk -v arch="$arch" '
        BEGIN { RS = ""; FS = "\n" }
        {
            package = version = architecture = sha = ""
            for (i = 1; i <= NF; i++) {
                if ($i ~ /^Package: /) package = substr($i, 10)
                else if ($i ~ /^Version: /) version = substr($i, 10)
                else if ($i ~ /^Architecture: /) architecture = substr($i, 15)
                else if ($i ~ /^SHA256: /) sha = substr($i, 9)
            }
            if (package == "ngrok" && architecture == arch) print version, sha
        }' | if [[ "$want" == latest ]]; then sort -V -k1,1 | tail -n1; else awk -v want="$want" '$1 == want' | head -n1; fi)"
    [[ "${entry%% *}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    sb_valid_sha256 "${entry#* }" || return 1
    printf '%s\n' "${entry,,}"
}

bootstrap_ngrok_lookup() {
    local want="$1" arch="$2" url body entry
    url="$(bootstrap_ngrok_index_url "$arch")"
    body="$(sb_retry 4 curl -fsSL --proto '=https' --tlsv1.2 "$url" 2>/dev/null || true)"
    [[ -n "$body" ]] || sb_die "could not fetch the ngrok package index: $url" || return
    entry="$(bootstrap_ngrok_index_entry "$body" "$want" "$arch")" \
        || sb_die "no ngrok $want package for $arch in $url" || return
    printf '%s\n' "$entry"
}

bootstrap_ngrok_installed_version() {
    [[ -x "$1" ]] || return 0
    "$1" version 2>/dev/null | awk 'NR == 1 && $1 == "ngrok" && $2 == "version" { print $3 }'
}

# Install into BIN_DIR, /usr/local/bin by default. The binary is staged beside
# its final path, checked, and renamed into place, so a failed download, a
# checksum mismatch, or a package that is not the pinned version leaves either
# the previous binary or nothing -- never a partial file.
bootstrap_ngrok() {
    NGROK_RESULT="not-installed"
    local bin_dir="${1:-/usr/local/bin}" arch entry checksum url temp package binary staged

    arch="$(bootstrap_ngrok_arch)" || return

    if sb_is_latest "$NGROK_VERSION"; then
        entry="$(bootstrap_ngrok_lookup latest "$arch")" || return
        NGROK_VERSION="${entry%% *}"
        NGROK_SHA256_X64=""
        NGROK_SHA256_ARM64=""
        sb_log "resolved latest ngrok: $NGROK_VERSION"
    fi
    [[ "$NGROK_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
        || { sb_die "invalid ngrok version: $NGROK_VERSION"; return; }

    if [[ "$(bootstrap_ngrok_installed_version "$bin_dir/ngrok")" == "$NGROK_VERSION" ]]; then
        NGROK_RESULT="ngrok $NGROK_VERSION"
        sb_log "ngrok $NGROK_VERSION already installed"
        return 0
    fi

    if [[ -n "${entry:-}" ]]; then
        checksum="${entry#* }"
    else
        checksum="$(bootstrap_ngrok_checksum "$arch")" || return
        if [[ -z "$checksum" ]]; then
            entry="$(bootstrap_ngrok_lookup "$NGROK_VERSION" "$arch")" || return
            checksum="${entry#* }"
        fi
    fi
    sb_valid_sha256 "$checksum" || { sb_die "invalid ngrok checksum for $arch"; return; }

    url="$(bootstrap_ngrok_package_url "$NGROK_VERSION" "$arch")"
    temp="$(mktemp -d)" || { sb_die "could not create a temporary directory"; return; }
    package="$temp/ngrok_${NGROK_VERSION}_$arch.deb"
    binary="$temp/root/usr/local/bin/ngrok"
    sb_log "installing ngrok $NGROK_VERSION ($arch, checksum-verified)"
    if ! sb_fetch_verified "$url" "$checksum" "$package"; then
        rm -rf -- "$temp"
        return 1
    fi
    if ! mkdir -p "$temp/root" \
        || ! dpkg-deb --fsys-tarfile "$package" > "$temp/data.tar" \
        || ! tar --no-same-owner --no-same-permissions -xf "$temp/data.tar" \
            -C "$temp/root" ./usr/local/bin/ngrok \
        || [[ ! -f "$binary" || -L "$binary" ]]; then
        rm -rf -- "$temp"
        sb_die "ngrok package does not contain usr/local/bin/ngrok"
        return
    fi

    if ! mkdir -p "$bin_dir" || ! staged="$(mktemp "$bin_dir/.ngrok.XXXXXX")"; then
        rm -rf -- "$temp"
        sb_die "could not stage ngrok in $bin_dir"
        return
    fi
    if ! install -m 0755 "$binary" "$staged" \
        || [[ "$(bootstrap_ngrok_installed_version "$staged")" != "$NGROK_VERSION" ]] \
        || ! mv -f -- "$staged" "$bin_dir/ngrok"; then
        rm -f -- "$staged"
        rm -rf -- "$temp"
        sb_die "ngrok version verification failed"
        return
    fi
    rm -rf -- "$temp"

    NGROK_RESULT="ngrok $NGROK_VERSION"
    printf '%s\n' "$NGROK_VERSION" > "$STATE_ROOT/ngrok-version"
    sb_log "installed ngrok $NGROK_VERSION ($arch)"
}
