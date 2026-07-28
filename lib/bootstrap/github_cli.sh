#!/usr/bin/env bash

# The GitHub CLI is installed from a pinned, checksummed upstream release rather
# than from apt. The distribution packages lag by many minor versions and are
# missing entirely on older releases, and the vendor's own instructions add a
# third-party apt repository plus a signing key, which is more trust than a
# single verified tarball needs.

bootstrap_github_cli_arch() {
    case "$(uname -m)" in
        x86_64|amd64) printf 'amd64\n' ;;
        aarch64|arm64) printf 'arm64\n' ;;
        *) sb_die "unsupported GitHub CLI architecture: $(uname -m)" ;;
    esac
}

bootstrap_github_cli_checksum() {
    case "$1" in
        amd64) printf '%s\n' "$GH_SHA256_X64" ;;
        arm64) printf '%s\n' "$GH_SHA256_ARM64" ;;
        *) sb_die "unsupported GitHub CLI architecture token: $1" ;;
    esac
}

bootstrap_github_cli_installed_version() {
    gh --version 2>/dev/null | awk 'NR == 1 { print $3 }'
}

bootstrap_github_cli() {
    GITHUB_CLI_RESULT="disabled"
    [[ "$INSTALL_GITHUB_CLI" == 1 ]] || return 0

    if [[ "$(bootstrap_github_cli_installed_version)" == "$GH_VERSION" ]]; then
        GITHUB_CLI_RESULT="gh $GH_VERSION"
        sb_log "GitHub CLI $GH_VERSION already installed"
        return 0
    fi

    local arch checksum name url temp archive extracted
    arch="$(bootstrap_github_cli_arch)" || return
    checksum="$(bootstrap_github_cli_checksum "$arch")" || return
    sb_valid_sha256 "$checksum" || { sb_die "invalid GitHub CLI checksum for $arch"; return; }

    name="gh_${GH_VERSION}_linux_${arch}"
    temp="$(mktemp -d)"
    archive="$temp/$name.tar.gz"
    extracted="$temp/extracted"
    url="https://github.com/cli/cli/releases/download/v$GH_VERSION/$name.tar.gz"

    if ! sb_fetch_verified "$url" "$checksum" "$archive"; then
        rm -rf -- "$temp"
        return 1
    fi
    if ! sb_extract_archive "$archive" "$extracted"; then
        rm -rf -- "$temp"
        return 1
    fi
    if [[ ! -x "$extracted/$name/bin/gh" ]]; then
        rm -rf -- "$temp"
        sb_die "GitHub CLI archive is incomplete"
        return
    fi

    install -m 0755 "$extracted/$name/bin/gh" /usr/local/bin/gh
    if [[ -f "$extracted/$name/share/man/man1/gh.1" ]]; then
        mkdir -p /usr/local/share/man/man1
        install -m 0644 "$extracted/$name"/share/man/man1/gh*.1 /usr/local/share/man/man1/ \
            || sb_warn "GitHub CLI man pages were not installed"
    fi
    rm -rf -- "$temp"

    [[ "$(bootstrap_github_cli_installed_version)" == "$GH_VERSION" ]] \
        || { sb_die "GitHub CLI version verification failed"; return; }
    GITHUB_CLI_RESULT="gh $GH_VERSION"
    printf '%s\n' "$GH_VERSION" > "$STATE_ROOT/github-cli-version"
    sb_log "installed GitHub CLI $GH_VERSION ($arch)"
}
