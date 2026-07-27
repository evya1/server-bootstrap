#!/usr/bin/env bash

bootstrap_verify_npm_package_version() {
    local package="$1" expected="$2"
    local package_json="$AI_CLI_PREFIX/lib/node_modules/$package/package.json"
    [[ -f "$package_json" ]] || { gsb_die "npm package missing after install: $package"; return; }
    local actual
    actual="$(node -e 'const p=require(process.argv[1]); process.stdout.write(p.version)' "$package_json")"
    [[ "$actual" == "$expected" ]] \
        || { gsb_die "version mismatch for $package: expected $expected, got $actual"; return; }
}

bootstrap_ai_cli() {
    CLAUDE_RESULT="disabled"
    CODEX_RESULT="disabled"
    [[ "$INSTALL_CLAUDE_CODE" == 1 || "$INSTALL_CODEX" == 1 ]] || return 0

    command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1 \
        || { gsb_die "Node.js and npm are required for AI CLI installation"; return; }
    [[ "$NPM_REGISTRY" == https://* ]] \
        || { gsb_die "NPM_REGISTRY must use HTTPS"; return; }

    local -a packages=()
    [[ "$INSTALL_CLAUDE_CODE" != 1 ]] || packages+=("@anthropic-ai/claude-code@$CLAUDE_CODE_VERSION")
    [[ "$INSTALL_CODEX" != 1 ]] || packages+=("@openai/codex@$CODEX_VERSION")

    mkdir -p "$AI_CLI_PREFIX"
    NPM_CONFIG_REGISTRY="$NPM_REGISTRY" \
    NPM_CONFIG_AUDIT=false \
    NPM_CONFIG_FUND=false \
    NPM_CONFIG_UPDATE_NOTIFIER=false \
        gsb_retry 3 npm install --global --prefix "$AI_CLI_PREFIX" --no-audit --no-fund "${packages[@]}"

    if [[ "$INSTALL_CLAUDE_CODE" == 1 ]]; then
        bootstrap_verify_npm_package_version '@anthropic-ai/claude-code' "$CLAUDE_CODE_VERSION"
        [[ -x "$AI_CLI_PREFIX/bin/claude" ]] || { gsb_die "Claude Code executable missing"; return; }
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
        CLAUDE_RESULT="$(claude --version 2>/dev/null || printf '%s' "$CLAUDE_CODE_VERSION")"
        printf '%s\n' "$CLAUDE_CODE_VERSION" > "$STATE_ROOT/claude-code-version"
    fi

    if [[ "$INSTALL_CODEX" == 1 ]]; then
        bootstrap_verify_npm_package_version '@openai/codex' "$CODEX_VERSION"
        [[ -x "$AI_CLI_PREFIX/bin/codex" ]] || { gsb_die "Codex executable missing"; return; }
        ln -sfn "$AI_CLI_PREFIX/bin/codex" /usr/local/bin/codex
        CODEX_RESULT="$(codex --version 2>/dev/null || printf '%s' "$CODEX_VERSION")"
        printf '%s\n' "$CODEX_VERSION" > "$STATE_ROOT/codex-version"
    fi

    gsb_log "installed requested AI CLI tools"
}
