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

bootstrap_apt_optional() {
    sb_retry 2 apt-get install -y --no-install-recommends "$1" \
        || sb_warn "optional package unavailable: $1"
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
    dpkg --configure -a || true
    apt-get -f install -y || true
    sb_retry 3 apt-get update
    sb_retry 3 apt-get install -y --no-install-recommends "${required[@]}" \
        || { sb_warn "batch package install failed; retrying individually"; for package in "${required[@]}"; do bootstrap_apt_optional "$package"; done; }
    for package in "${optional[@]}"; do bootstrap_apt_optional "$package"; done
    [[ "$RUN_APT_UPGRADE" != 1 ]] || sb_retry 3 apt-get upgrade -y
    git lfs install --system >/dev/null 2>&1 || sb_warn "git-lfs initialization skipped"

    # Ubuntu/Debian intentionally rename these executables to avoid package-name
    # conflicts. Create conventional command names without letting an already
    # existing alias make the bootstrap function return a failure status.
    bootstrap_ensure_command_alias batcat bat
    bootstrap_ensure_command_alias fdfind fd
    return 0
}
