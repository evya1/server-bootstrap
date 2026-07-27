#!/usr/bin/env bash

bootstrap_workspace() {
    local directory
    for directory in projects data models outputs logs tools venvs startup-logs .cache .setup-state; do
        mkdir -p "$WORKSPACE_ROOT/$directory"
    done
    mkdir -p "$CACHE_ROOT"/{uv,pip,huggingface/hub} "$TOOLS_ROOT" "$VENV_ROOT"
    mkdir -p "$PROJECTS_ROOT" "$DATA_ROOT" "$MODELS_ROOT" "$OUTPUTS_ROOT"
    if [[ -L /root/workspace || ! -e /root/workspace ]]; then
        ln -sfn "$WORKSPACE_ROOT" /root/workspace
    fi

    CACHE_ENV=/etc/profile.d/zz-workspace-cache.sh
    cat > "$CACHE_ENV" <<CACHEEOF
export UV_CACHE_DIR=$CACHE_ROOT/uv
export PIP_CACHE_DIR=$CACHE_ROOT/pip
export HF_HOME=$CACHE_ROOT/huggingface
export HUGGINGFACE_HUB_CACHE=$CACHE_ROOT/huggingface/hub
export XDG_CACHE_HOME=$CACHE_ROOT
CACHEEOF
    # shellcheck source=/dev/null
    source "$CACHE_ENV"
}
