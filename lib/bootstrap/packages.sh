#!/usr/bin/env bash

bootstrap_wait_for_apt() {
    local waited=0
    while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 \
        || fuser /var/lib/apt/lists/lock >/dev/null 2>&1; do
        (( waited == 0 )) && sb_log "waiting for another apt/dpkg process"
        sleep 3; waited=$((waited + 3))
        (( waited < 600 )) || { sb_warn "apt lock held longer than 600s"; return 1; }
    done
}

# --- NVIDIA driver and CUDA packages ---------------------------------------
# The bootstrap does not run an apt transaction whose plan would upgrade,
# downgrade, reinstall, reconfigure, or remove an NVIDIA driver or CUDA package
# that is already on the host. Every attempt is simulated first and refused if
# its plan would; a driver that a resolver swaps out unattended leaves a GPU
# host without a working driver. Another apt process can still change the plan
# between a simulation and the attempt that follows it.
# Fresh installs of such a package are not refused: they change nothing that is
# installed, and one that replaced an installed package would show as a Remv.
BOOTSTRAP_APT_PROTECTED_PATTERN='^(nvidia|libnvidia|cuda|libcuda|cudnn|libcudnn|libnccl|libcublas|libcufft|libcurand|libcusolver|libcusparse|libnpp|libnvjpeg|libnvrtc|libnvjitlink|libcupti|libnvtoolsext|libcudart|nsight-)|-nvidia(-|$)'
# Returned when a transaction is refused; the refused attempt is not run.
BOOTSTRAP_APT_REFUSED=3

bootstrap_apt_protected_name() { [[ "$1" =~ $BOOTSTRAP_APT_PROTECTED_PATTERN ]]; }

# Reads `apt-get -s` output; prints each protected package the plan would
# change. "Inst NAME [OLD] (NEW ...)" replaces an installed version, Remv and
# Purg remove one, and a Conf with no Inst before it configures one dpkg
# already has unpacked. A fresh "Inst NAME (NEW ...)" changes nothing installed.
bootstrap_apt_protected_changes() {
    local name
    awk '
        $1 !~ /^(Inst|Remv|Purg|Conf)$/ { next }
        { name = $2; sub(/:.*/, "", name) }
        $1 == "Inst" { fresh[name] = ($3 !~ /^\[/); if (!fresh[name]) print name; next }
        $1 == "Remv" || $1 == "Purg" { print name; next }
        $1 == "Conf" && !(name in fresh) { print name }
    ' | LC_ALL=C sort -u | while IFS= read -r name; do
        if bootstrap_apt_protected_name "$name"; then printf '%s\n' "$name"; fi
    done
}

# bootstrap_apt_guarded ATTEMPTS APT-GET-ARGUMENTS...
# Runs the transaction, retrying a failed attempt up to ATTEMPTS in all with
# sb_retry's backoff. Each attempt is simulated afresh and runs only if that
# simulation succeeded and changes no installed NVIDIA driver or CUDA package: a
# failed attempt can leave apt with a different plan for the next one. A
# refusal or a failed simulation ends the retries before the real attempt.
# Returns BOOTSTRAP_APT_REFUSED for a refusal and 1 for any other failure.
bootstrap_apt_guarded() {
    local attempts="$1" plan changes n=1 delay=5; shift
    while true; do
        if ! plan="$(apt-get -s "$@" 2>&1)"; then
            sb_warn "apt-get $* cannot be resolved:"
            printf '%s\n' "$plan" | grep -E '^(E|W):' | head -n 5 >&2 || true
            return 1
        fi
        changes="$(printf '%s\n' "$plan" | bootstrap_apt_protected_changes)"
        if [[ -n "$changes" ]]; then
            sb_warn "refused apt-get $*: it would change installed NVIDIA driver or CUDA packages: ${changes//$'\n'/ }"
            return "$BOOTSTRAP_APT_REFUSED"
        fi
        if apt-get "$@"; then return 0; fi
        if (( n >= attempts )); then
            sb_warn "command failed after $attempts attempts: apt-get $*"
            return 1
        fi
        sb_warn "attempt $n/$attempts failed; retry in ${delay}s"
        sleep "$delay"
        n=$((n + 1)); delay=$(( delay * 2 > 60 ? 60 : delay * 2 ))
    done
}

bootstrap_apt_optional() {
    bootstrap_apt_guarded 2 install -y --no-install-recommends "$1" \
        || sb_warn "optional package not installed: $1"
}

# An interrupted dpkg run is finished only when none of the packages it left
# unconfigured is protected; configuring one would complete a driver change.
bootstrap_dpkg_recover() {
    local pending
    pending="$(dpkg-query -W -f='${Package} ${Status}\n' 2>/dev/null \
        | awk '$4 != "" && $4 != "installed" && $4 != "not-installed" && $4 != "config-files" { print $1 }' \
        | while IFS= read -r name; do
            if bootstrap_apt_protected_name "$name"; then printf '%s ' "$name"; fi
        done)"
    if [[ -n "$pending" ]]; then
        sb_warn "skipped dpkg --configure -a: it would finish configuring NVIDIA driver or CUDA packages: $pending"
        return 0
    fi
    dpkg --configure -a || sb_warn "dpkg --configure -a failed; continuing"
}

# apt-get -f install resolves broken dependencies by whatever means the
# resolver finds, including removing packages, and on a GPU host those are
# usually the driver. It stays best effort, but runs only when its plan leaves
# every installed driver and CUDA package alone. When it is refused, a host
# whose dependencies really are broken fails at the required install instead.
bootstrap_apt_repair() {
    local status=0
    bootstrap_apt_guarded 1 -f install -y || status=$?
    case "$status" in
        0) ;;
        "$BOOTSTRAP_APT_REFUSED") sb_warn "skipped apt-get -f install; repair those packages by hand" ;;
        *) sb_warn "apt-get -f install failed; continuing" ;;
    esac
    return 0
}

# Debian policy allows lowercase alphanumerics plus "+", "-", and "." only.
# Rejecting anything else keeps a typo or a stray shell metacharacter in the
# manifest from reaching the apt command line.
bootstrap_valid_package_name() {
    [[ "${1:-}" =~ ^[a-z0-9][a-z0-9+.-]*$ ]]
}

# bootstrap_read_package_section FILE SECTION -> one package name per line
bootstrap_read_package_section() {
    local file="$1" section="$2"
    awk -v want="$section" '
        { sub(/#.*/, "") }
        { gsub(/^[[:space:]]+|[[:space:]]+$/, "") }
        $0 == "" { next }
        /^\[.+\]$/ { current = substr($0, 2, length($0) - 2); next }
        current == want { print $1 }
    ' "$file"
}

bootstrap_ensure_command_alias() {
    local source_name="$1" alias_name="$2" source_path destination
    local bin_dir="${BOOTSTRAP_LOCAL_BIN_DIR:-/usr/local/bin}"

    if command -v "$alias_name" >/dev/null 2>&1; then
        return 0
    fi

    source_path="$(command -v "$source_name" 2>/dev/null || true)"
    if [[ -z "$source_path" ]]; then
        sb_warn "command '$source_name' is unavailable; could not create '$alias_name' compatibility alias"
        return 0
    fi

    mkdir -p "$bin_dir"
    destination="$bin_dir/$alias_name"
    ln -sfn "$source_path" "$destination"
    [[ -x "$destination" ]] \
        || sb_warn "compatibility alias was not executable: $destination"
    return 0
}

bootstrap_packages() {
    local manifest="${PACKAGES_FILE:-}"
    [[ -n "$manifest" && -f "$manifest" ]] \
        || { sb_die "package manifest not found: ${manifest:-<unset>}"; return; }

    local -a manifest_required=() manifest_optional=() required=() optional=()
    mapfile -t manifest_required < <(bootstrap_read_package_section "$manifest" required)
    mapfile -t manifest_optional < <(bootstrap_read_package_section "$manifest" optional)

    # EXTRA_PACKAGES and SKIP_PACKAGES are space-separated lists, so the word
    # splitting on both is the interface rather than an oversight.
    local package
    # shellcheck disable=SC2206
    manifest_required+=( ${EXTRA_PACKAGES:-} )
    local -A skip=()
    for package in ${SKIP_PACKAGES:-}; do skip["$package"]=1; done

    for package in "${manifest_required[@]}"; do
        bootstrap_valid_package_name "$package" \
            || { sb_warn "ignoring invalid package name: $package"; continue; }
        [[ -z "${skip[$package]:-}" ]] \
            || { sb_log "skipping package on request: $package"; continue; }
        required+=("$package")
    done
    for package in "${manifest_optional[@]}"; do
        bootstrap_valid_package_name "$package" \
            || { sb_warn "ignoring invalid package name: $package"; continue; }
        [[ -z "${skip[$package]:-}" ]] || continue
        optional+=("$package")
    done

    (( ${#required[@]} > 0 )) \
        || { sb_die "package manifest has no [required] entries: $manifest"; return; }
    sb_log "packages: ${#required[@]} required, ${#optional[@]} optional (from $manifest)"

    bootstrap_wait_for_apt
    bootstrap_dpkg_recover
    bootstrap_apt_repair
    sb_retry 3 apt-get update

    # Every required package must end up installed. The per-package pass after
    # a failed batch installs what it can and names exactly what is missing.
    local -a missing=()
    if ! bootstrap_apt_guarded 3 install -y --no-install-recommends "${required[@]}"; then
        sb_warn "batch package install failed; retrying individually"
        for package in "${required[@]}"; do
            bootstrap_apt_guarded 2 install -y --no-install-recommends "$package" || missing+=("$package")
        done
    fi
    (( ${#missing[@]} == 0 )) \
        || { sb_die "required packages could not be installed: ${missing[*]}"; return; }

    for package in "${optional[@]}"; do bootstrap_apt_optional "$package"; done
    if [[ "$RUN_APT_UPGRADE" == 1 ]]; then
        bootstrap_apt_guarded 3 upgrade -y \
            || { sb_die "RUN_APT_UPGRADE=1: apt-get upgrade failed or was refused"; return; }
    fi
    git lfs install --system >/dev/null 2>&1 || sb_warn "git-lfs initialization skipped"

    # Ubuntu/Debian intentionally rename these executables to avoid package-name
    # conflicts. Create conventional command names without letting an already
    # existing alias make the bootstrap function return a failure status.
    bootstrap_ensure_command_alias batcat bat
    bootstrap_ensure_command_alias fdfind fd
    return 0
}
