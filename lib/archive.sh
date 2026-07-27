#!/usr/bin/env bash
# Safe archive inspection and extraction for .tar.gz/.tgz/.tar.xz/.zip bundles.

[[ -n "${GSB_ARCHIVE_LOADED:-}" ]] && return 0
GSB_ARCHIVE_LOADED=1

# shellcheck source=core.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/core.sh"

gsb_archive_type() {
    case "$1" in
        *.tar.gz|*.tgz) printf 'tar-gz\n' ;;
        *.tar.xz|*.txz) printf 'tar-xz\n' ;;
        *.zip) printf 'zip\n' ;;
        *) gsb_die "unsupported archive type: $1 (expected .tar.gz, .tgz, .tar.xz, .txz, or .zip)" ;;
    esac
}

gsb_member_name_is_safe() {
    local name="$1" part
    [[ -n "$name" && "$name" != /* && "$name" != *'\\'* ]] || return 1
    IFS='/' read -r -a parts <<< "$name"
    for part in "${parts[@]}"; do
        [[ "$part" != '..' ]] || return 1
    done
}

gsb_validate_archive_names() {
    local archive="$1" type="$2" name
    case "$type" in
        tar-gz)
            while IFS= read -r name; do
                gsb_member_name_is_safe "$name" \
                    || gsb_die "unsafe archive member: $name" || return
            done < <(tar -tzf "$archive")
            ;;
        tar-xz)
            while IFS= read -r name; do
                gsb_member_name_is_safe "$name" \
                    || gsb_die "unsafe archive member: $name" || return
            done < <(tar -tJf "$archive")
            ;;
        zip)
            while IFS= read -r name; do
                gsb_member_name_is_safe "$name" \
                    || gsb_die "unsafe archive member: $name" || return
            done < <(unzip -Z1 "$archive")
            ;;
    esac
}

gsb_validate_extracted_tree() {
    local destination="$1" root entry target resolved
    root="$(cd -- "$destination" && pwd -P)"
    while IFS= read -r -d '' entry; do
        resolved="$(realpath -m -- "$entry")"
        case "$resolved/" in "$root/"*) : ;; *) gsb_die "extracted path escapes root: $entry" || return ;; esac
        if [[ -L "$entry" ]]; then
            target="$(readlink -- "$entry")"
            [[ "$target" != /* ]] || gsb_die "absolute symlink in archive: $entry -> $target" || return
            resolved="$(realpath -m -- "$(dirname -- "$entry")/$target")"
            case "$resolved/" in "$root/"*) : ;; *) gsb_die "symlink escapes root: $entry -> $target" || return ;; esac
        fi
    done < <(find "$destination" -mindepth 1 -print0)
}

gsb_extract_archive() {
    local archive="$1" destination="$2" type
    [[ -f "$archive" ]] || gsb_die "archive not found: $archive" || return
    type="$(gsb_archive_type "$archive")" || return
    gsb_validate_archive_names "$archive" "$type" || return
    mkdir -p -- "$destination"
    case "$type" in
        tar-gz) tar --no-same-owner --no-same-permissions -xzf "$archive" -C "$destination" ;;
        tar-xz) tar --no-same-owner --no-same-permissions -xJf "$archive" -C "$destination" ;;
        zip) unzip -q -o "$archive" -d "$destination" ;;
    esac
    gsb_validate_extracted_tree "$destination"
}
