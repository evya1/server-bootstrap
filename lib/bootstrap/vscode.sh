#!/usr/bin/env bash

bootstrap_vscode_extensions() {
    VSCODE_EXTENSIONS_RESULT="disabled"
    [[ "$INSTALL_VSCODE_EXTENSIONS" == 1 ]] || return 0
    [[ -f "$VSCODE_EXTENSIONS_FILE" ]] \
        || { gsb_die "VS Code extension manifest not found: $VSCODE_EXTENSIONS_FILE"; return; }

    local helper="$ROOT/gpu-vscode-extensions" result=0
    [[ -x "$helper" ]] || { gsb_die "VS Code extension helper is missing"; return; }
    VSCODE_EXTENSIONS_FILE="$VSCODE_EXTENSIONS_FILE" \
    VSCODE_EXTENSIONS_STRICT="$VSCODE_EXTENSIONS_STRICT" \
    VSCODE_EXTENSIONS_AUTO_RETRY_SECONDS="$VSCODE_EXTENSIONS_AUTO_RETRY_SECONDS" \
    STATE_ROOT="$STATE_ROOT" LOG_ROOT="$LOG_ROOT" \
        "$helper" --quiet || result=$?
    case "$result" in
        0) VSCODE_EXTENSIONS_RESULT="installed" ;;
        3)
            VSCODE_EXTENSIONS_RESULT="pending-first-remote-ssh-connection"
            gsb_log "VS Code extensions queued; run gpu-vscode-extensions after the first Remote-SSH connection"
            ;;
        *)
            if [[ "$VSCODE_EXTENSIONS_STRICT" == 1 ]]; then return "$result"; fi
            VSCODE_EXTENSIONS_RESULT="partial-or-failed"
            gsb_warn "VS Code extension installation was incomplete; rerun gpu-vscode-extensions"
            ;;
    esac
}
