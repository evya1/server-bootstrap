#!/usr/bin/env bash

bootstrap_acceptance() {
    ACCEPT_RESULT="not-run"
    [[ "$RUN_ACCEPT_TEST" != 0 ]] || return 0
    local accept_script="$1" result=0
    [[ -x "$accept_script" ]] || { sb_warn "acceptance script not found: $accept_script"; return 0; }
    "$accept_script" 2>&1 | tee "$LOG_ROOT/accept-$TS.txt" || result=${PIPESTATUS[0]}
    case "$result" in
        0) ACCEPT_RESULT="accept" ;;
        1) ACCEPT_RESULT="reject" ;;
        2) ACCEPT_RESULT="warn" ;;
        *) sb_warn "acceptance script failed with exit $result"; return "$result" ;;
    esac
    if [[ "$RUN_ACCEPT_TEST" == strict && "$result" != 0 ]]; then
        sb_die "acceptance policy is strict; verdict=$ACCEPT_RESULT"
    fi
}

bootstrap_report() {
    ACCEL_PRESENT=0
    echo "hostname:   $(hostname)"
    echo "os:         $(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME" || uname -sr)"
    echo "cpu:        $(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2- | sed 's/^ //' || echo unknown) (cores: $(nproc))"
    echo "ram:        $(free -h | awk '/^Mem:/{print $2}')"
    echo "disk free:  $(df -h "$WORKSPACE_ROOT" | awk 'NR==2{print $4" free of "$2}')"
    echo "python:     $(python3 --version 2>&1)"
    echo "node:       ${NODE_RESULT:-not-run}"
    echo "claude:     ${CLAUDE_RESULT:-not-run}"
    echo "codex:      ${CODEX_RESULT:-not-run}"
    echo "vscode ext: ${VSCODE_EXTENSIONS_RESULT:-not-run}"
    echo "uv:         $(command -v uv >/dev/null 2>&1 && uv --version || echo absent)"
    echo "gh:         ${GITHUB_CLI_RESULT:-not-run}"
    echo "base numpy: $NUMPY_VERSION"
    if command -v nvidia-smi >/dev/null 2>&1; then
        ACCEL_PRESENT=1
        nvidia-smi -pm 1 >/dev/null 2>&1 || true
        nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader 2>/dev/null \
            | while IFS= read -r line; do echo "gpu:        $line"; done
        echo "gpu procs:  $(nvidia-smi --query-compute-apps=pid --format=csv,noheader 2>/dev/null | wc -l)"
    else
        echo "gpu:        none detected (this is not an error)"
    fi
}
