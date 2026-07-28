#!/usr/bin/env bash

bootstrap_node_arch() {
    case "$(uname -m)" in
        x86_64|amd64) printf 'x64\n' ;;
        aarch64|arm64) printf 'arm64\n' ;;
        *) sb_die "unsupported Node.js architecture: $(uname -m)" ;;
    esac
}

bootstrap_node_checksum() {
    case "$1" in
        x64) printf '%s\n' "$NODE_SHA256_X64" ;;
        arm64) printf '%s\n' "$NODE_SHA256_ARM64" ;;
        *) sb_die "unsupported Node.js architecture token: $1" ;;
    esac
}

bootstrap_nodejs() {
    NODE_RESULT="disabled"
    if [[ "$INSTALL_NODEJS" != 1 ]]; then
        if [[ "$INSTALL_CLAUDE_CODE" == 1 || "$INSTALL_CODEX" == 1 ]]; then
            command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1 \
                || { sb_die "Claude Code or Codex requires Node.js/npm; enable INSTALL_NODEJS or provide them"; return; }
        fi
        return 0
    fi

    local arch checksum name url temp archive extracted install_dir current
    arch="$(bootstrap_node_arch)" || return
    checksum="$(bootstrap_node_checksum "$arch")" || return
    sb_valid_sha256 "$checksum" || { sb_die "invalid Node.js checksum for $arch"; return; }

    name="node-v$NODE_VERSION-linux-$arch"
    install_dir="$NODE_INSTALL_ROOT/$name"
    current="$NODE_INSTALL_ROOT/current"

    if [[ ! -x "$install_dir/bin/node" || ! -x "$install_dir/bin/npm" ]]; then
        temp="$(mktemp -d)"
        archive="$temp/$name.tar.xz"
        extracted="$temp/extracted"
        url="https://nodejs.org/dist/v$NODE_VERSION/$name.tar.xz"
        if ! sb_fetch_verified "$url" "$checksum" "$archive"; then
            rm -rf -- "$temp"
            return 1
        fi
        if ! sb_extract_archive "$archive" "$extracted"; then
            rm -rf -- "$temp"
            return 1
        fi
        [[ -x "$extracted/$name/bin/node" && -x "$extracted/$name/bin/npm" ]] \
            || { rm -rf -- "$temp"; sb_die "Node.js archive is incomplete"; return; }
        mkdir -p "$NODE_INSTALL_ROOT"
        rm -rf -- "$install_dir"
        mv -- "$extracted/$name" "$install_dir"
        rm -rf -- "$temp"
    fi

    rm -rf -- "$current"
    ln -s "$install_dir" "$current"
    local command
    for command in node npm npx corepack; do
        [[ -e "$current/bin/$command" ]] || continue
        ln -sfn "$current/bin/$command" "/usr/local/bin/$command"
    done

    [[ "$(node --version 2>/dev/null)" == "v$NODE_VERSION" ]] \
        || { sb_die "Node.js version verification failed"; return; }
    NODE_RESULT="$(node --version) / npm $(npm --version)"
    printf '%s\n' "$NODE_VERSION" > "$STATE_ROOT/node-version"
    sb_log "installed Node.js $NODE_VERSION ($arch)"
}
