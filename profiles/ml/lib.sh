#!/usr/bin/env bash
# Shared by the ml profile installer and its commands. Sourced, never run.
#
# Everything the profile decides -- where the environment lives, which locked
# backend fits this host, what the recorded state says -- is answered here, so
# the installer, ml-preflight and ml-status cannot disagree about it.

[[ -n "${SB_ML_LIB_LOADED:-}" ]] && return 0
SB_ML_LIB_LOADED=1

ML_PROFILE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ML_REPO_ROOT="$(cd -- "$ML_PROFILE_DIR/../.." && pwd -P)"
# The profile always builds on the distribution's own Python 3.12.
ML_PYTHON_SERIES=3.12

ml_load_config() {
    WORKSPACE_ROOT="${WORKSPACE_ROOT:-/workspace}"
    VENV_ROOT="${VENV_ROOT:-$WORKSPACE_ROOT/venvs}"
    STATE_ROOT="${STATE_ROOT:-$WORKSPACE_ROOT/.setup-state}"
    CACHE_ROOT="${CACHE_ROOT:-$WORKSPACE_ROOT/.cache}"
    # The stable path is a symlink to one fully built environment under the
    # store, so a replacement is a single rename and a failed one changes
    # nothing. A virtual environment cannot be moved once built.
    ML_ENV="$VENV_ROOT/ml-workbench"
    ML_ENV_STORE="$VENV_ROOT/.ml-workbench"
    ML_STATE_DIR="$STATE_ROOT/profiles/ml"
    ML_LOCK_DIR="${ML_LOCK_DIR:-$ML_PROFILE_DIR/locks}"
    ML_PYTHON="${ML_PYTHON:-/usr/bin/python$ML_PYTHON_SERIES}"
    ML_BIN_DIR="${ML_BIN_DIR:-/usr/local/bin}"
    # Test seams: a fake /sys for PCI device discovery, a stand-in nvidia-smi.
    ML_SYSFS_ROOT="${ML_SYSFS_ROOT:-/sys}"
    ML_NVIDIA_SMI="${ML_NVIDIA_SMI:-nvidia-smi}"
    ML_COMMANDS=(ml-env ml-status ml-doctor ml-preflight ml-jupyter)
}

ml_repository_version() {
    tr -d '[:space:]' < "$ML_REPO_ROOT/VERSION" 2>/dev/null || printf 'unknown'
}

ml_arch() {
    case "$(uname -m)" in
        x86_64|amd64) printf 'x86_64\n' ;;
        aarch64|arm64) printf 'aarch64\n' ;;
        *) return 1 ;;
    esac
}

# The pinned uv the bootstrap installs, read from the path it was installed to
# rather than from PATH, which may lead to another copy. ML_UV overrides it.
ml_uv() {
    if [[ -n "${ML_UV:-}" ]]; then
        printf '%s\n' "$ML_UV"
    elif [[ -x /usr/local/bin/uv ]]; then
        printf '/usr/local/bin/uv\n'
    else
        command -v uv 2>/dev/null
    fi
}

ml_python_version() {  # interpreter -> X.Y.Z
    "$1" -c 'import sys; print("%d.%d.%d" % sys.version_info[:3])' 2>/dev/null
}

# True when $1 <= $2 as dotted versions.
ml_version_le() {
    [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" == "$1" ]]
}

# --- Host GPU ----------------------------------------------------------------
# ML_GPU_STATE is one of:
#   none             no NVIDIA display or 3D controller and no nvidia-smi
#   nvidia           nvidia-smi lists at least one GPU and reports a CUDA version
#   nvidia-unusable  NVIDIA hardware or nvidia-smi is present, but the driver
#                    does not answer with a GPU and a CUDA version
# ML_DRIVER_CUDA is the highest CUDA version the driver supports, as nvidia-smi
# prints it in its header. ML_GPU_SUMMARY is one line for people.

ml_nvidia_pci_count() {
    local device vendor class count=0
    for device in "$ML_SYSFS_ROOT"/bus/pci/devices/*; do
        [[ -r "$device/vendor" && -r "$device/class" ]] || continue
        vendor="$(<"$device/vendor")"; class="$(<"$device/class")"
        [[ "${vendor,,}" == 0x10de && "$class" == 0x03* ]] && count=$((count + 1))
    done
    printf '%s\n' "$count"
}

ml_detect_gpu() {
    local pci smi_out names
    ML_GPU_STATE=none; ML_DRIVER_CUDA=""; ML_GPU_COUNT=0; ML_GPU_SUMMARY="no NVIDIA GPU detected"
    pci="$(ml_nvidia_pci_count)"
    if ! command -v "$ML_NVIDIA_SMI" >/dev/null 2>&1; then
        if (( pci > 0 )); then
            ML_GPU_STATE=nvidia-unusable
            ML_GPU_SUMMARY="$pci NVIDIA controller(s) on the PCI bus, but nvidia-smi is not installed"
        fi
        return 0
    fi
    smi_out="$("$ML_NVIDIA_SMI" 2>/dev/null)" || smi_out=""
    names="$("$ML_NVIDIA_SMI" -L 2>/dev/null | grep -E '^GPU [0-9]+' || true)"
    ML_GPU_COUNT="$(grep -c . <<< "$names" || true)"
    [[ -n "$names" ]] || ML_GPU_COUNT=0
    if [[ "$smi_out" =~ CUDA\ Version:\ *([0-9]+\.[0-9]+) ]] && (( ML_GPU_COUNT > 0 )); then
        ML_GPU_STATE=nvidia
        ML_DRIVER_CUDA="${BASH_REMATCH[1]}"
        ML_GPU_SUMMARY="$ML_GPU_COUNT NVIDIA GPU(s), driver supports CUDA $ML_DRIVER_CUDA"
    else
        ML_GPU_STATE=nvidia-unusable
        ML_GPU_SUMMARY="nvidia-smi is present but reports no GPU and CUDA version"
    fi
}

# --- Locks ---------------------------------------------------------------------
# A lock is profiles/ml/locks/<backend>-<arch>.txt, written by tools/ml-lock.sh.
# Its first lines are "# key: value" metadata; the rest is a uv-compiled
# requirements file with a SHA-256 for every artifact.

ml_lock_field() {  # lock file, key
    awk -v key="# $2:" '
        /^[^#]/ { exit }
        index($0, key) == 1 { value = substr($0, length(key) + 1); gsub(/^[ \t]+|[ \t]+$/, "", value); print value; exit }
    ' "$1"
}

ml_lock_path() { printf '%s/%s-%s.txt\n' "$ML_LOCK_DIR" "$1" "$2"; }

ml_locked_backends() {  # arch -> one backend per line
    local lock name
    for lock in "$ML_LOCK_DIR"/*-"$1".txt; do
        [[ -f "$lock" ]] || continue
        name="$(basename -- "$lock" "-$1.txt")"
        [[ "$(ml_lock_field "$lock" backend)" == "$name" && "$(ml_lock_field "$lock" arch)" == "$1" ]] \
            || continue
        printf '%s\n' "$name"
    done
}

# name==version for every pinned requirement, names normalised as in PEP 503.
# Reads a lock or `uv pip freeze` output alike.
ml_pins() {
    awk '/^[A-Za-z0-9]/ && $1 ~ /==/ {
        split($1, part, "=="); name = tolower(part[1]); gsub(/[-_.]+/, "-", name)
        print name "==" part[2]
    }' "$@" | LC_ALL=C sort
}

# --- Backend selection ---------------------------------------------------------
# Sets ML_BACKEND, ML_LOCK, ML_BACKEND_CUDA and ML_SELECTION_REASON, or prints
# why no backend fits and returns 1. `auto` never falls back to CPU on a host
# with NVIDIA hardware: CPU is only chosen there when asked for by name.
ml_select_backend() {
    local requested="$1" arch best="" best_cuda="" backend cuda locked
    ML_BACKEND=""; ML_LOCK=""; ML_BACKEND_CUDA=""; ML_SELECTION_REASON=""
    [[ "$requested" =~ ^[a-z0-9]+$ ]] \
        || { echo "invalid backend name: $requested" >&2; return 1; }
    arch="$(ml_arch)" || { echo "unsupported architecture: $(uname -m)" >&2; return 1; }
    ML_ARCH="$arch"
    [[ -n "${ML_GPU_STATE:-}" ]] || ml_detect_gpu
    locked="$(ml_locked_backends "$arch" | paste -sd' ' -)"

    if [[ "$requested" == auto ]]; then
        case "$ML_GPU_STATE" in
            none)
                requested=cpu
                ML_SELECTION_REASON="auto: no NVIDIA GPU detected" ;;
            nvidia)
                for backend in $locked; do
                    cuda="$(ml_lock_field "$(ml_lock_path "$backend" "$arch")" cuda)"
                    [[ "$cuda" =~ ^[0-9]+\.[0-9]+$ ]] || continue
                    ml_version_le "$cuda" "$ML_DRIVER_CUDA" || continue
                    if [[ -z "$best" ]] || ! ml_version_le "$cuda" "$best_cuda"; then
                        best="$backend"; best_cuda="$cuda"
                    fi
                done
                if [[ -z "$best" ]]; then
                    echo "NVIDIA GPU detected (driver supports CUDA $ML_DRIVER_CUDA), but no locked CUDA backend for $arch runs on it" >&2
                    echo "locked backends for $arch: ${locked:-none}" >&2
                    echo "auto does not fall back to CPU on a GPU host; pass --backend cpu to install the CPU backend deliberately" >&2
                    return 1
                fi
                requested="$best"
                ML_SELECTION_REASON="auto: newest locked CUDA backend the driver supports (CUDA $ML_DRIVER_CUDA)" ;;
            *)
                echo "NVIDIA hardware is present but unusable: $ML_GPU_SUMMARY" >&2
                echo "auto does not fall back to CPU on a GPU host; fix the driver, or pass --backend cpu to install the CPU backend deliberately" >&2
                return 1 ;;
        esac
    else
        ML_SELECTION_REASON="requested by name"
    fi

    ML_LOCK="$(ml_lock_path "$requested" "$arch")"
    if [[ ! -f "$ML_LOCK" || " $locked " != *" $requested "* ]]; then
        echo "backend '$requested' has no lock for $arch; locked backends for $arch: ${locked:-none}" >&2
        return 1
    fi
    ML_BACKEND="$requested"
    ML_BACKEND_CUDA="$(ml_lock_field "$ML_LOCK" cuda)"
    if [[ "$ML_BACKEND_CUDA" != none && "$ML_GPU_STATE" == nvidia ]] \
        && ! ml_version_le "$ML_BACKEND_CUDA" "$ML_DRIVER_CUDA"; then
        echo "backend $ML_BACKEND needs CUDA $ML_BACKEND_CUDA, but the driver supports CUDA $ML_DRIVER_CUDA" >&2
        return 1
    fi
    return 0
}

# Minimum free space, in GB, on the file system holding the environments.
ml_min_free_gb() {
    if [[ -n "${ML_MIN_FREE_GB:-}" ]]; then
        printf '%s\n' "$ML_MIN_FREE_GB"
    elif [[ "${1:-none}" == none ]]; then
        printf '10\n'
    else
        printf '30\n'
    fi
}

ml_writable() {  # path -> true if it, or the nearest existing ancestor, is writable
    local path="$1"
    while [[ ! -e "$path" && "$path" != / ]]; do path="$(dirname -- "$path")"; done
    [[ -d "$path" && -w "$path" ]]
}

ml_free_gb() {  # path -> whole GB available on its file system (nearest existing ancestor)
    local path="$1"
    while [[ ! -e "$path" && "$path" != / ]]; do path="$(dirname -- "$path")"; done
    df -Pk -- "$path" 2>/dev/null | awk 'NR == 2 { print int($4 / 1048576) }'
}

# --- Checks shared by ml-preflight and the installer -----------------------------
ml_line() { printf '%-5s %s\n' "$1" "$2"; }

# Prints one line per check and returns 1 if any failed. Selection results are
# left in ML_BACKEND and friends, so the caller can act on them.
ml_preflight() {
    local requested="$1" failed=0 arch uv version free need errors line

    if arch="$(ml_arch)"; then ml_line PASS "architecture: $arch"
    else ml_line FAIL "architecture: $(uname -m) is not supported"; failed=1; fi

    version="$(ml_python_version "$ML_PYTHON" || true)"
    if [[ "$version" == "$ML_PYTHON_SERIES".* ]]; then
        ml_line PASS "python: $ML_PYTHON ($version)"
    else
        ml_line FAIL "python: $ML_PYTHON is not a Python $ML_PYTHON_SERIES interpreter${version:+ (found $version)}"
        failed=1
    fi

    if uv="$(ml_uv)" && [[ -n "$uv" && -x "$uv" ]]; then
        ml_line PASS "uv: $uv ($("$uv" --version 2>/dev/null | awk 'NR == 1 { print $2 }'))"
    else
        ml_line FAIL "uv: not found; the bootstrap installs it unless INSTALL_UV=0"
        failed=1
    fi

    ml_detect_gpu
    ml_line INFO "gpu: $ML_GPU_SUMMARY"

    errors="$(mktemp)"
    if ml_select_backend "$requested" 2>"$errors"; then
        ml_line PASS "backend: $ML_BACKEND ($ML_SELECTION_REASON), lock $(basename -- "$ML_LOCK")"
        if [[ "$ML_BACKEND_CUDA" != none && "$ML_GPU_STATE" != nvidia ]]; then
            ml_line WARN "backend: $ML_BACKEND targets CUDA $ML_BACKEND_CUDA, but no usable NVIDIA GPU is present; GPU checks will be skipped"
        elif [[ "$ML_BACKEND_CUDA" == none && "$ML_GPU_STATE" != none ]]; then
            ml_line WARN "backend: the CPU backend was requested on a host with NVIDIA hardware; the GPU will not be used"
        fi
        free="$(ml_free_gb "$VENV_ROOT")"; need="$(ml_min_free_gb "$ML_BACKEND_CUDA")"
        if [[ -n "$free" ]] && (( free >= need )); then
            ml_line PASS "disk: ${free} GB free for $VENV_ROOT (needs $need)"
        else
            ml_line FAIL "disk: ${free:-unknown} GB free for $VENV_ROOT, needs $need (set ML_MIN_FREE_GB to override)"
            failed=1
        fi
    else
        while IFS= read -r line; do ml_line FAIL "backend: $line"; done < "$errors"
        failed=1
    fi
    rm -f -- "$errors"
    (( failed == 0 ))
}

# --- Recorded state --------------------------------------------------------------
ml_state() { cat -- "$ML_STATE_DIR/$1" 2>/dev/null || true; }

ml_installed() {
    [[ -n "$(ml_state backend)" && -L "$ML_ENV" && -x "$ML_ENV/bin/python" ]]
}

ml_require_installed() {
    ml_installed && return 0
    echo "The ml profile is not installed. Install it with: server-profile install ml" >&2
    exit 1
}
