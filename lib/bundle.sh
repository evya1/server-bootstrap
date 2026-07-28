#!/usr/bin/env bash
# Generic bundle lifecycle: verify -> extract -> install -> record -> clean.

[[ -n "${SB_BUNDLE_LOADED:-}" ]] && return 0
SB_BUNDLE_LOADED=1

LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=core.sh
source "$LIB_DIR/core.sh"
# shellcheck source=archive.sh
source "$LIB_DIR/archive.sh"

sb_bundle_validate_name() {
    [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]] || sb_die "invalid bundle name: $1"
}

sb_bundle_materialize() {
    local source_ref="$1" expected="$2" temp_dir="$3" output_var="$4"
    local local_path output
    if [[ "$source_ref" == https://* ]]; then
        case "$source_ref" in
            *.tar.gz) output="$temp_dir/bundle.tar.gz" ;;
            *.tgz) output="$temp_dir/bundle.tgz" ;;
            *.tar.xz) output="$temp_dir/bundle.tar.xz" ;;
            *.txz) output="$temp_dir/bundle.txz" ;;
            *.zip) output="$temp_dir/bundle.zip" ;;
            *) sb_die "remote bundle URL must end with .tar.gz, .tgz, .tar.xz, .txz, or .zip" || return ;;
        esac
        sb_fetch_verified "$source_ref" "$expected" "$output" || return
    else
        local_path="${source_ref#file://}"
        [[ -f "$local_path" ]] || sb_die "bundle archive not found: $local_path" || return
        sb_verify_file "$local_path" "$expected" || return
        output="$(realpath -m -- "$local_path")"
    fi
    printf -v "$output_var" '%s' "$output"
}

sb_bundle_write_state() {
    local directory="$1" version="$2" checksum="$3" source_ref="$4" installer="$5" tmp
    mkdir -p -- "$directory"
    tmp="$(mktemp -d "$directory/.state.XXXXXX")"
    printf '%s\n' "$version" > "$tmp/version"
    printf '%s\n' "$checksum" > "$tmp/archive-sha256"
    printf '%s\n' "$source_ref" > "$tmp/source"
    printf '%s\n' "$installer" > "$tmp/installer"
    date -u +%Y-%m-%dT%H:%M:%SZ > "$tmp/installed-at"
    for file in version archive-sha256 source installer installed-at; do
        mv -f -- "$tmp/$file" "$directory/$file"
    done
    rmdir "$tmp"
}

sb_bundle_delete_local_source() {
    local source_ref="$1" sidecar="${2:-}"
    [[ "$source_ref" != https://* ]] || return 0
    local path="${source_ref#file://}"
    rm -f -- "$path"
    [[ -n "$sidecar" ]] && rm -f -- "$sidecar"
    sb_log "deleted installed archive: $path"
}

sb_install_bundle() (
    local name="$1" version="$2" source_ref="$3" expected="$4" installer="$5"
    local delete_after="$6" force="$7" state_root="$8" checksum_sidecar="$9"
    shift 9
    local -a installer_args=("$@")
    local temp_dir archive extract_dir state_dir legacy_dir actual current_version current_sha
    local -a matches=()

    sb_bundle_validate_name "$name" || return
    [[ -n "$version" ]] || sb_die "bundle version is required" || return
    [[ -n "$source_ref" ]] || sb_die "bundle source is required" || return
    sb_valid_sha256 "$expected" || sb_die "bundle SHA-256 must be 64 hexadecimal characters" || return
    [[ "$installer" != */* ]] || sb_die "installer must be a filename, not a path: $installer" || return

    temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/server-bundle.XXXXXX")"
    trap 'rm -rf -- "$temp_dir"' EXIT
    sb_bundle_materialize "$source_ref" "$expected" "$temp_dir" archive || return
    actual="$(sb_sha256 "$archive")"

    state_dir="$state_root/bundles/$name"
    legacy_dir="$state_root/addons/$name"
    current_version="$(cat "$state_dir/version" 2>/dev/null || true)"
    current_sha="$(cat "$state_dir/archive-sha256" 2>/dev/null || true)"

    if [[ -z "$current_version" && -f "$legacy_dir/version" ]]; then
        current_version="$(cat "$legacy_dir/version")"
        current_sha="$actual"
        sb_log "migrating legacy add-on state for $name"
        sb_bundle_write_state "$state_dir" "$current_version" "$current_sha" "$source_ref" "$installer"
    fi

    if [[ "$force" != 1 && "$current_version" == "$version" ]]; then
        if [[ -n "$current_sha" && "${current_sha,,}" != "${actual,,}" ]]; then
            sb_die "$name $version is already recorded with a different archive hash; use --force only after review"
            return 1
        fi
        sb_log "bundle already installed: $name $version (skipped)"
        [[ "$delete_after" == 1 ]] && sb_bundle_delete_local_source "$source_ref" "$checksum_sidecar"
        return 0
    fi

    extract_dir="$temp_dir/extracted"
    sb_extract_archive "$archive" "$extract_dir" || return
    mapfile -d '' matches < <(find "$extract_dir" -type f -name "$installer" -print0)
    (( ${#matches[@]} == 1 )) \
        || sb_die "expected exactly one '$installer' in bundle, found ${#matches[@]}" || return

    local install_file="${matches[0]}" install_root shipped_version
    install_root="$(cd -- "$(dirname -- "$install_file")" && pwd -P)"
    if [[ -f "$install_root/VERSION" ]]; then
        shipped_version="$(tr -d '[:space:]' < "$install_root/VERSION")"
        [[ "$shipped_version" == "$version" ]] \
            || sb_die "bundle VERSION=$shipped_version does not match requested version=$version" || return
    fi

    sb_log "installing bundle: $name $version"
    ( cd -- "$install_root" && bash "$install_file" "${installer_args[@]}" )
    sb_bundle_write_state "$state_dir" "$version" "$actual" "$source_ref" "$installer"
    sb_log "bundle installed: $name $version"
    [[ "$delete_after" == 1 ]] && sb_bundle_delete_local_source "$source_ref" "$checksum_sidecar"
    return 0
)
