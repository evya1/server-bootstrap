#!/usr/bin/env bash

bootstrap_wait_for_apt() {
    local waited=0
    while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 \
        || fuser /var/lib/apt/lists/lock >/dev/null 2>&1; do
        (( waited == 0 )) && gsb_log "waiting for another apt/dpkg process"
        sleep 3; waited=$((waited + 3))
        (( waited < 600 )) || { gsb_warn "apt lock held longer than 600s"; return 1; }
    done
}

bootstrap_apt_optional() {
    gsb_retry 2 apt-get install -y --no-install-recommends "$1" \
        || gsb_warn "optional package unavailable: $1"
}

bootstrap_ensure_command_alias() {
    local source_name="$1" alias_name="$2" source_path destination
    local bin_dir="${BOOTSTRAP_LOCAL_BIN_DIR:-/usr/local/bin}"

    if command -v "$alias_name" >/dev/null 2>&1; then
        return 0
    fi

    source_path="$(command -v "$source_name" 2>/dev/null || true)"
    if [[ -z "$source_path" ]]; then
        gsb_warn "command '$source_name' is unavailable; could not create '$alias_name' compatibility alias"
        return 0
    fi

    mkdir -p "$bin_dir"
    destination="$bin_dir/$alias_name"
    ln -sfn "$source_path" "$destination"
    [[ -x "$destination" ]] \
        || gsb_warn "compatibility alias was not executable: $destination"
    return 0
}

bootstrap_packages() {
    local -a required=(ca-certificates curl wget git git-lfs rsync tmux tree unzip zip jq
        zsh ffmpeg xz-utils python3 python3-pip python3-venv python3-dev build-essential
        pkg-config nano vim less htop lsof procps psmisc iproute2 net-tools
        openssh-client ripgrep aria2 parallel ncdu file util-linux fd-find bat)
    bootstrap_wait_for_apt
    dpkg --configure -a || true
    apt-get -f install -y || true
    gsb_retry 3 apt-get update
    gsb_retry 3 apt-get install -y --no-install-recommends "${required[@]}" \
        || { gsb_warn "batch package install failed; retrying individually"; local p; for p in "${required[@]}"; do bootstrap_apt_optional "$p"; done; }
    bootstrap_apt_optional btop
    [[ "$RUN_APT_UPGRADE" != 1 ]] || gsb_retry 3 apt-get upgrade -y
    git lfs install --system >/dev/null 2>&1 || gsb_warn "git-lfs initialization skipped"

    # Ubuntu/Debian intentionally rename these executables to avoid package-name
    # conflicts. Create conventional command names without letting an already
    # existing alias make the bootstrap function return a failure status.
    bootstrap_ensure_command_alias batcat bat
    bootstrap_ensure_command_alias fdfind fd
    return 0
}
