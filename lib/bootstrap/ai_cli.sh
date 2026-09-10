#!/usr/bin/env bash

bootstrap_installed_npm_version() {
    local package="$1"
    local package_json="$AI_CLI_PREFIX/lib/node_modules/$package/package.json"
    [[ -f "$package_json" ]] || { sb_die "npm package missing after install: $package"; return; }
    node -e 'const p=require(process.argv[1]); process.stdout.write(p.version)' "$package_json"
}

# Prints the version npm actually installed. A pinned request must match it
# exactly; a "latest" request accepts whatever the registry resolved to and
# reports it, so the run still records a concrete version.
bootstrap_verify_npm_package_version() {
    local package="$1" expected="$2" actual
    actual="$(bootstrap_installed_npm_version "$package")" || return
    [[ -n "$actual" ]] || { sb_die "could not read the installed version of $package"; return; }
    if ! sb_is_latest "$expected"; then
        [[ "$actual" == "$expected" ]] \
            || { sb_die "version mismatch for $package: expected $expected, got $actual"; return; }
    fi
    printf '%s\n' "$actual"
}

bootstrap_ai_cli() {
    CLAUDE_RESULT="disabled"
    CODEX_RESULT="disabled"
    PI_RESULT="disabled"
    [[ "$INSTALL_CLAUDE_CODE" == 1 || "$INSTALL_CODEX" == 1 || "$INSTALL_PI" == 1 ]] || return 0

    command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1 \
        || { sb_die "Node.js and npm are required for AI CLI installation"; return; }
    [[ "$NPM_REGISTRY" == https://* ]] \
        || { sb_die "NPM_REGISTRY must use HTTPS"; return; }

    # "latest" is a real npm dist-tag, so a resolved and a pinned request share
    # one install command; only the version check afterwards differs.
    local -a packages=()
    [[ "$INSTALL_CLAUDE_CODE" != 1 ]] || packages+=("@anthropic-ai/claude-code@$CLAUDE_CODE_VERSION")
    [[ "$INSTALL_CODEX" != 1 ]] || packages+=("@openai/codex@$CODEX_VERSION")
    [[ "$INSTALL_PI" != 1 ]] || packages+=("@earendil-works/pi-coding-agent@$PI_VERSION")

    mkdir -p "$AI_CLI_PREFIX"
    NPM_CONFIG_REGISTRY="$NPM_REGISTRY" \
    NPM_CONFIG_AUDIT=false \
    NPM_CONFIG_FUND=false \
    NPM_CONFIG_UPDATE_NOTIFIER=false \
        sb_retry 3 npm install --global --prefix "$AI_CLI_PREFIX" --no-audit --no-fund "${packages[@]}"

    local resolved
    if [[ "$INSTALL_CLAUDE_CODE" == 1 ]]; then
        resolved="$(bootstrap_verify_npm_package_version '@anthropic-ai/claude-code' "$CLAUDE_CODE_VERSION")" || return
        [[ -x "$AI_CLI_PREFIX/bin/claude" ]] || { sb_die "Claude Code executable missing"; return; }
        rm -f -- /usr/local/bin/claude
        if [[ "$CLAUDE_CODE_DISABLE_AUTOUPDATER" == 1 ]]; then
            cat > /usr/local/bin/claude <<CLAUDEWRAPPER
#!/usr/bin/env bash
export DISABLE_AUTOUPDATER=1
exec "$AI_CLI_PREFIX/bin/claude" "\$@"
CLAUDEWRAPPER
            chmod 0755 /usr/local/bin/claude
        else
            ln -sfn "$AI_CLI_PREFIX/bin/claude" /usr/local/bin/claude
        fi
        CLAUDE_RESULT="$("$AI_CLI_PREFIX/bin/claude" --version 2>/dev/null || printf '%s' "$resolved")"
        printf '%s\n' "$resolved" > "$STATE_ROOT/claude-code-version"
    fi

    if [[ "$INSTALL_CODEX" == 1 ]]; then
        resolved="$(bootstrap_verify_npm_package_version '@openai/codex' "$CODEX_VERSION")" || return
        [[ -x "$AI_CLI_PREFIX/bin/codex" ]] || { sb_die "Codex executable missing"; return; }
        ln -sfn "$AI_CLI_PREFIX/bin/codex" /usr/local/bin/codex
        CODEX_RESULT="$("$AI_CLI_PREFIX/bin/codex" --version 2>/dev/null || printf '%s' "$resolved")"
        printf '%s\n' "$resolved" > "$STATE_ROOT/codex-version"
    fi

    # pi needs no wrapper: its update check and telemetry are governed by the
    # PI_* variables the generated Zsh configuration exports, not by a flag.
    if [[ "$INSTALL_PI" == 1 ]]; then
        resolved="$(bootstrap_verify_npm_package_version '@earendil-works/pi-coding-agent' "$PI_VERSION")" || return
        [[ -x "$AI_CLI_PREFIX/bin/pi" ]] || { sb_die "pi executable missing"; return; }
        ln -sfn "$AI_CLI_PREFIX/bin/pi" /usr/local/bin/pi
        PI_RESULT="$resolved"
        printf '%s\n' "$resolved" > "$STATE_ROOT/pi-version"
    fi

    sb_log "installed requested AI CLI tools"
}
