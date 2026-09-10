#!/usr/bin/env bash

# pi itself is installed with the other coding-agent CLIs in ai_cli.sh. This
# module only prepares its configuration directory.

bootstrap_pi_config() {
    [[ "$INSTALL_PI" == 1 ]] || return 0

    mkdir -p "$PI_CONFIG_DIR"
    chmod 0700 "$PI_CONFIG_DIR"

    [[ "$INSTALL_PI_MODELS_TEMPLATE" == 1 ]] || return 0

    local target="$PI_CONFIG_DIR/models.json"
    if [[ -e "$target" ]]; then
        sb_log "kept existing pi model configuration: $target"
        return 0
    fi
    if [[ ! -f "$PI_MODELS_TEMPLATE" ]]; then
        sb_warn "pi model template not found: $PI_MODELS_TEMPLATE"
        return 0
    fi
    # A malformed template would make every pi model unavailable, so check it
    # before it lands where pi will read it.
    if command -v node >/dev/null 2>&1; then
        node -e 'JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"))' "$PI_MODELS_TEMPLATE" \
            || { sb_warn "pi model template is not valid JSON; skipping"; return 0; }
    fi

    # Custom providers only: pi ships built-in catalogs for Anthropic, OpenAI
    # and OpenRouter, and this file never overwrites one you have edited.
    install -m 0600 "$PI_MODELS_TEMPLATE" "$target"
    sb_log "installed pi model template: $target"
}
