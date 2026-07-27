#!/usr/bin/env bash
# Modular Ubuntu GPU-server foundation. Run from the extracted release archive.
set -Eeuo pipefail

SELF="$(readlink -f -- "${BASH_SOURCE[0]}")"
ROOT="$(cd -- "$(dirname -- "$SELF")" && pwd -P)"
LIB="$ROOT/lib"
for module in core archive bundle bootstrap/config bootstrap/workspace bootstrap/packages \
    bootstrap/node bootstrap/ai_cli bootstrap/uv bootstrap/python bootstrap/shell bootstrap/vscode bootstrap/runtime bootstrap/report; do
    # shellcheck source=/dev/null
    source "$LIB/$module.sh"
done

bootstrap_load_config
GSB_LOG_PREFIX=gpu-server-bootstrap
gsb_require_root
umask 022
export DEBIAN_FRONTEND=noninteractive

mkdir -p "$WORKSPACE_ROOT" "$LOG_ROOT" "$STATE_ROOT"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
LOG_FILE="$LOG_ROOT/startup-$TS.log"
SUMMARY_FILE="$LOG_ROOT/latest-summary.txt"
exec > >(tee -a "$LOG_FILE") 2>&1

STEP=startup
on_error() {
    local code=$?
    gsb_warn "failed at line ${BASH_LINENO[0]} during '$STEP': ${BASH_COMMAND} (exit $code)"
    {
        echo "STATUS: FAILED"
        echo "step: $STEP"
        echo "line: ${BASH_LINENO[0]}"
        echo "command: ${BASH_COMMAND}"
        echo "log: $LOG_FILE"
        echo "time: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } > "$SUMMARY_FILE"
    exit "$code"
}
trap on_error ERR

exec 9>"$STATE_ROOT/bootstrap.lock"
flock -w 1800 9 || gsb_die "could not acquire bootstrap lock"
gsb_log "gpu-server-bootstrap v$BOOTSTRAP_VERSION"
gsb_log "log file: $LOG_FILE"

STEP=workspace; bootstrap_workspace
STEP=packages; bootstrap_packages
STEP=runtime-tools; bootstrap_install_runtime_tools "$ROOT"
STEP=nodejs; bootstrap_nodejs
STEP=ai-cli; bootstrap_ai_cli
STEP=uv; bootstrap_uv
STEP=base-python; bootstrap_base_python
STEP=shell; bootstrap_shell
STEP=vscode-extensions; bootstrap_vscode_extensions

# Acceptance is deliberately before any optional workload/add-on.
STEP=acceptance; bootstrap_acceptance "$ROOT/gpu-accept.sh"

ADDON_RESULT=none
if [[ "$INSTALL_ADDON" == 1 ]]; then
    STEP=addon
    case "$ADDON_URL" in
        https://*) : ;;
        file://*|/*) [[ "$ADDON_ALLOW_LOCAL_FILE" == 1 ]] || gsb_die "local add-on requires ADDON_ALLOW_LOCAL_FILE=1" ;;
        *) gsb_die "ADDON_URL must be HTTPS or a trusted local path" ;;
    esac
    ADDON_ARGS=()
    [[ -z "$ADDON_INSTALL_ARGS" ]] || read -r -a ADDON_ARGS <<< "$ADDON_INSTALL_ARGS"
    gsb_install_bundle "$ADDON_NAME" "$ADDON_VERSION" "$ADDON_URL" "$ADDON_SHA256" \
        "$ADDON_INSTALLER" 0 "$ADDON_FORCE" "$STATE_ROOT" "" "${ADDON_ARGS[@]}"
    ADDON_RESULT="$ADDON_NAME $ADDON_VERSION"
fi

STEP=report; bootstrap_report
STEP=finalize
printf '%s\n' "$BOOTSTRAP_VERSION" > "$STATE_ROOT/bootstrap-version"
date -u +%Y-%m-%dT%H:%M:%SZ > "$STATE_ROOT/bootstrap-complete"
{
    echo "STATUS: OK"
    echo "bootstrap_version: $BOOTSTRAP_VERSION"
    echo "acceptance: ${ACCEPT_RESULT:-not-run}"
    echo "base_numpy: $NUMPY_VERSION"
    echo "node: $NODE_RESULT"
    echo "claude_code: $CLAUDE_RESULT"
    echo "codex: $CODEX_RESULT"
    echo "vscode_extensions: $VSCODE_EXTENSIONS_RESULT"
    echo "gpu_present: $GPU_PRESENT"
    echo "addon_installed: $ADDON_RESULT"
    echo "workspace: $WORKSPACE_ROOT"
    echo "log: $LOG_FILE"
    echo "time: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
} | tee "$SUMMARY_FILE"
gsb_log "DONE"
