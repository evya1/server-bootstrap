#!/usr/bin/env bash
# Install or update the optional ml profile: one Python 3.12 environment at
# $VENV_ROOT/ml-workbench built from a frozen, hash-checked lock.
#
# Non-interactive and idempotent. A new environment is built beside the active
# one, verified, and only then switched in with one rename; any failure before
# the switch removes the new build and leaves the previous environment, its
# commands and the recorded state exactly as they were. A failure after the
# switch, while the state and commands are written, switches back and restores
# them. Nothing is started, and no model or dataset is downloaded.
set -Eeuo pipefail

SELF="$(readlink -f -- "${BASH_SOURCE[0]}")"
# shellcheck source=lib.sh
source "$(dirname -- "$SELF")/lib.sh"
# shellcheck source=../../lib/core.sh
source "$ML_REPO_ROOT/lib/core.sh"
SB_LOG_PREFIX="server-profile ml"

usage() {
    cat <<'USAGE'
Usage: server-profile install ml [--backend auto|NAME] [--reconfigure] [--force] [--dry-run]

  --backend NAME   auto (default) or a locked backend such as cpu
  --reconfigure    allow replacing an installed environment with another backend
  --force          rebuild even when the installed environment is up to date
  --dry-run        run the preflight checks and print the decision; change nothing
USAGE
}

REQUESTED=auto; RECONFIGURE=0; FORCE=0; DRY_RUN=0
while (($#)); do
    case "$1" in
        --backend) REQUESTED="${2:?--backend needs a value}"; shift 2 ;;
        --backend=*) REQUESTED="${1#--backend=}"; shift ;;
        --reconfigure) RECONFIGURE=1; shift ;;
        --force) FORCE=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

ml_load_config
umask 022
REPO_VERSION="$(ml_repository_version)"

# Decide what a run would do, without writing anything.
preflight_out="$(mktemp)"
trap 'rm -f -- "$preflight_out"' EXIT
preflight_ok=1
ml_preflight "$REQUESTED" defer-disk > "$preflight_out" || preflight_ok=0
sed 's/^/  /' "$preflight_out"

if [[ -e "$ML_ENV" && ! -L "$ML_ENV" ]]; then
    sb_warn "$ML_ENV exists and was not created by this profile; move it aside first"
    exit 1
fi
(( preflight_ok )) || { sb_warn "preflight failed; nothing was changed"; exit 1; }

# One installation at a time, and the recorded state is read under the lock.
# Every directory the run writes must be writable before anything is built.
if (( DRY_RUN == 0 )); then
    for target in "$VENV_ROOT" "$STATE_ROOT" "$ML_BIN_DIR"; do
        ml_writable "$target" || { sb_warn "cannot write $target; run as root"; exit 1; }
    done
    mkdir -p -- "$STATE_ROOT/profiles"
    exec 8>"$STATE_ROOT/profiles/ml.lock"
    flock -w 1800 8 || { sb_warn "another ml profile installation is running"; exit 1; }
fi
INSTALLED_BACKEND="$(ml_state backend)"
INSTALLED_SHA="$(ml_state lock-sha256)"
INSTALLED_ENV="$(ml_state environment)"

LOCK_SHA="$(sb_sha256 "$ML_LOCK")"

# The environment on disk matches the lock exactly: same pins, nothing extra.
env_matches_lock() {
    local uv freeze
    [[ -L "$ML_ENV" && -x "$ML_ENV/bin/python" ]] || return 1
    [[ "$(readlink -f -- "$ML_ENV")" == "$INSTALLED_ENV" ]] || return 1
    uv="$(ml_uv)" || return 1
    freeze="$(ml_uv_run "$uv" pip freeze --python "$ML_ENV/bin/python" 2>/dev/null)" || return 1
    [[ "$(ml_pins <<< "$freeze")" == "$(ml_pins "$ML_LOCK")" ]]
}

ACTION=install
if [[ -n "$INSTALLED_BACKEND" ]]; then
    if [[ "$INSTALLED_BACKEND" != "$ML_BACKEND" ]] && (( RECONFIGURE == 0 )); then
        sb_warn "the installed backend is $INSTALLED_BACKEND; this run resolved $ML_BACKEND"
        sb_warn "changing backend replaces the environment: rerun with --reconfigure to do that"
        exit 1
    fi
    if [[ "$INSTALLED_BACKEND" == "$ML_BACKEND" && "$INSTALLED_SHA" == "$LOCK_SHA" ]] \
        && (( FORCE == 0 )) && env_matches_lock; then
        ACTION=keep
    elif [[ "$INSTALLED_BACKEND" != "$ML_BACKEND" ]]; then
        ACTION=reconfigure
    else
        ACTION=replace
    fi
fi

# Only a run that builds needs the free space; a keep writes nothing, so a
# repeat still succeeds once the first install has used that space.
if disk_line="$(ml_disk_check)"; then
    printf '  %s\n' "$disk_line"
elif [[ "$ACTION" == keep ]]; then
    printf '  %s\n' "$(ml_line INFO "disk: ${ML_DISK_FREE:-unknown} GB free for $VENV_ROOT; nothing needs building, so the $ML_DISK_NEED GB a build needs is not required")"
else
    printf '  %s\n' "$disk_line"
    sb_warn "preflight failed; nothing was changed"
    exit 1
fi
if (( DRY_RUN == 0 )); then
    # What a killed run could not remove: its copy of the previous state, a
    # half-written state and a link it had not yet renamed. See the switch.
    rm -rf -- "$STATE_ROOT/profiles/".ml-state-previous.* "$ML_STATE_DIR"/.state.* "$ML_ENV".switch.*
fi

printf '  plan: %s backend %s from %s (sha256 %s)\n' "$ACTION" "$ML_BACKEND" \
    "$(basename -- "$ML_LOCK")" "$LOCK_SHA"
(( DRY_RUN == 0 )) || exit 0

install_commands() {
    local command
    mkdir -p -- "$ML_BIN_DIR"
    for command in "${ML_COMMANDS[@]}"; do
        ln -sfn "$ML_PROFILE_DIR/bin/$command" "$ML_BIN_DIR/$command"
    done
}

ML_STATE_FILES=(repository-version backend cuda arch lock lock-sha256 core-versions packages
    installed-at environment)

write_state() {  # environment, core-versions file, freeze file
    local tmp file
    mkdir -p -- "$ML_STATE_DIR"
    tmp="$(mktemp -d "$ML_STATE_DIR/.state.XXXXXX")"
    printf '%s\n' "$REPO_VERSION" > "$tmp/repository-version"
    printf '%s\n' "$ML_BACKEND" > "$tmp/backend"
    printf '%s\n' "$ML_BACKEND_CUDA" > "$tmp/cuda"
    printf '%s\n' "$ML_ARCH" > "$tmp/arch"
    basename -- "$ML_LOCK" > "$tmp/lock"
    printf '%s\n' "$LOCK_SHA" > "$tmp/lock-sha256"
    printf '%s\n' "$1" > "$tmp/environment"
    cp -- "$2" "$tmp/core-versions"
    cp -- "$3" "$tmp/packages"
    date -u +%Y-%m-%dT%H:%M:%SZ > "$tmp/installed-at"
    chmod 0644 "$tmp"/*
    # environment goes last: until it names the new build, a rerun sees that
    # the link and the state disagree and rebuilds rather than keeping.
    for file in "${ML_STATE_FILES[@]}"; do
        mv -f -- "$tmp/$file" "$ML_STATE_DIR/$file"
    done
    rmdir -- "$tmp"
}

if [[ "$ACTION" == keep ]]; then
    install_commands
    # A newer release that ships the same lock changes nothing on disk.
    if [[ "$(ml_state repository-version)" != "$REPO_VERSION" ]]; then
        printf '%s\n' "$REPO_VERSION" > "$ML_STATE_DIR/repository-version"
    fi
    sb_log "already installed: backend $ML_BACKEND, lock sha256 $LOCK_SHA; nothing to rebuild"
    exit 0
fi

UV="$(ml_uv)"
export UV_CACHE_DIR="${UV_CACHE_DIR:-$CACHE_ROOT/uv}"
mkdir -p -- "$ML_ENV_STORE" "$UV_CACHE_DIR"
NEW_ENV="$ML_ENV_STORE/$ML_BACKEND-${LOCK_SHA:0:12}-$(date -u +%Y%m%dT%H%M%SZ)-$$"
SWITCHED=0; COMMITTED=0; PREVIOUS=""; STATE_COPY=""
declare -A PREVIOUS_COMMANDS=()

# Undo the switch: point the link back at the previous environment (or remove
# it after a first install), and restore the recorded state and the command
# links from what was there before.
restore_previous() {
    local file command current ok=0
    if [[ -n "$PREVIOUS" ]]; then
        ln -sfn -- "$PREVIOUS" "$ML_ENV.switch.$$" && mv -Tf -- "$ML_ENV.switch.$$" "$ML_ENV" || ok=1
    else
        rm -f -- "$ML_ENV" "$ML_ENV.switch.$$" || ok=1
    fi
    for file in "${ML_STATE_FILES[@]}"; do
        if [[ -f "$STATE_COPY/$file" ]]; then
            cp -p -- "$STATE_COPY/$file" "$ML_STATE_DIR/$file" || ok=1
        else
            rm -f -- "$ML_STATE_DIR/$file" || ok=1
        fi
    done
    rm -rf -- "$ML_STATE_DIR"/.state.*
    [[ -n "$PREVIOUS" ]] || rmdir -- "$ML_STATE_DIR" 2>/dev/null || true
    for command in "${ML_COMMANDS[@]}"; do
        current="$(readlink -- "$ML_BIN_DIR/$command" 2>/dev/null || true)"
        if [[ -n "${PREVIOUS_COMMANDS[$command]:-}" ]]; then
            [[ "$current" == "${PREVIOUS_COMMANDS[$command]}" ]] \
                || ln -sfn -- "${PREVIOUS_COMMANDS[$command]}" "$ML_BIN_DIR/$command" || ok=1
        elif [[ "$current" == "$ML_PROFILE_DIR/bin/$command" ]]; then
            rm -f -- "$ML_BIN_DIR/$command" || ok=1
        fi
    done
    return "$ok"
}

cleanup_failed_build() {
    local code=$?
    rm -f -- "$preflight_out"
    if (( SWITCHED == 1 && COMMITTED == 0 )); then
        if restore_previous; then
            if [[ -n "$PREVIOUS" ]]; then
                sb_warn "installation failed after the switch; the previous environment, its state and commands were restored"
            else
                sb_warn "installation failed after the switch; the new environment, its state and commands were removed"
            fi
        else
            sb_warn "installation failed after the switch, and restoring the previous environment failed; run: server-profile install ml --force"
        fi
    fi
    if (( COMMITTED == 0 )) && [[ -n "${NEW_ENV:-}" && -d "$NEW_ENV" ]]; then
        rm -rf -- "$NEW_ENV"
        (( code == 0 || SWITCHED == 1 )) \
            || sb_warn "installation failed; the new build was removed and the previous environment is unchanged"
    fi
    [[ -z "$STATE_COPY" ]] || rm -rf -- "$STATE_COPY"
}
trap cleanup_failed_build EXIT

sb_log "building backend $ML_BACKEND from $(basename -- "$ML_LOCK") into $NEW_ENV"
ml_uv_run "$UV" venv --python "$ML_PYTHON" --no-python-downloads --no-config "$NEW_ENV"
# The lock names PyPI; --torch-backend takes the PyTorch packages from the
# backend's official index, as when the lock was resolved. uv retries transient
# network errors itself; a hash mismatch is final.
ml_uv_run "$UV" pip sync --python "$NEW_ENV/bin/python" --require-hashes --no-build \
    --strict --no-config --torch-backend "$ML_BACKEND" "$ML_LOCK"

# Verify before switching: the interpreter, the locked versions of the core
# packages, and one small tensor operation.
core_versions="$NEW_ENV.core-versions"; packages="$NEW_ENV.packages"
trap 'cleanup_failed_build; rm -f -- "$core_versions" "$packages"' EXIT
"$NEW_ENV/bin/python" "$ML_PROFILE_DIR/check.py" verify --lock "$ML_LOCK" > "$core_versions"
ml_uv_run "$UV" pip freeze --python "$NEW_ENV/bin/python" > "$packages"
[[ "$(ml_pins "$packages")" == "$(ml_pins "$ML_LOCK")" ]] \
    || { sb_warn "the built environment does not match the lock exactly"; exit 1; }

# The switch: one rename of a symlink. Before it nothing the user relies on has
# changed. From it until the state and commands are written, a failure puts
# back what was there, from what is recorded here.
[[ ! -L "$ML_ENV" ]] || PREVIOUS="$(readlink -f -- "$ML_ENV")"
[[ -z "$PREVIOUS" || -d "$PREVIOUS" ]] || PREVIOUS=""
STATE_COPY="$(mktemp -d "$STATE_ROOT/profiles/.ml-state-previous.XXXXXX")"
for file in "${ML_STATE_FILES[@]}"; do
    [[ ! -f "$ML_STATE_DIR/$file" ]] || cp -p -- "$ML_STATE_DIR/$file" "$STATE_COPY/$file"
done
for command in "${ML_COMMANDS[@]}"; do
    PREVIOUS_COMMANDS[$command]="$(readlink -- "$ML_BIN_DIR/$command" 2>/dev/null || true)"
done
ln -sfn -- "$NEW_ENV" "$ML_ENV.switch.$$"
SWITCHED=1
mv -Tf -- "$ML_ENV.switch.$$" "$ML_ENV"
write_state "$NEW_ENV" "$core_versions" "$packages"
install_commands
COMMITTED=1

# The store holds only what this profile built: everything but the live
# environment, including anything an interrupted run left, is removed. The
# new environment is already live, so a failure here is only reported.
for old in "$ML_ENV_STORE"/*; do
    [[ -e "$old" && "$old" != "$NEW_ENV" && "$old" != "$NEW_ENV".* ]] || continue
    rm -rf -- "$old" || sb_warn "could not remove $old; remove it by hand"
done
[[ -z "$PREVIOUS" || "$PREVIOUS" == "$NEW_ENV" ]] || sb_log "removed the previous environment $PREVIOUS"
sb_log "ml profile ready: backend $ML_BACKEND ($ACTION), environment $ML_ENV"
sed 's/^/  /' "$core_versions"
