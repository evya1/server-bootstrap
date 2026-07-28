#!/usr/bin/env bash
# One-command local provisioning: bootstrap first, acceptance second, bundles in plan order.
set -Eeuo pipefail

PLAN="${PROVISION_PLAN:-./provision-plan.sh}"
DRY_RUN=0
KEEP_ARCHIVES=0

usage() {
    cat <<'USAGE'
Usage: sudo ./server-provision.sh [--plan FILE] [--dry-run] [--keep-archives]

The plan is a Bash data file that calls:
  register_bootstrap ARCHIVE SHA256_FILE [BOOTSTRAP_SCRIPT]
  register_bundle NAME VERSION ARCHIVE SHA256_FILE [INSTALLER] [INSTALLER_ARGS...]
USAGE
}
while (($#)); do
    case "$1" in
        --plan) PLAN="${2:?missing value}"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        --keep-archives) KEEP_ARCHIVES=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done
PLAN="$(realpath -m -- "$PLAN")"
[[ -f "$PLAN" ]] || { echo "ERROR: plan not found: $PLAN" >&2; exit 1; }
PLAN_DIR="$(cd -- "$(dirname -- "$PLAN")" && pwd -P)"

BOOTSTRAP_ARCHIVE=""; BOOTSTRAP_SHA_FILE=""; BOOTSTRAP_SCRIPT=server-bootstrap.sh
BUNDLE_NAMES=(); BUNDLE_VERSIONS=(); BUNDLE_ARCHIVES=(); BUNDLE_SHA_FILES=(); BUNDLE_INSTALLERS=()

resolve_plan_path() { [[ "$1" == /* ]] && realpath -m -- "$1" || realpath -m -- "$PLAN_DIR/$1"; }
register_bootstrap() {
    [[ -z "$BOOTSTRAP_ARCHIVE" ]] || { echo "ERROR: bootstrap registered twice" >&2; return 2; }
    BOOTSTRAP_ARCHIVE="$(resolve_plan_path "$1")"
    BOOTSTRAP_SHA_FILE="$(resolve_plan_path "$2")"
    BOOTSTRAP_SCRIPT="${3:-server-bootstrap.sh}"
}
register_bundle() {
    local index="${#BUNDLE_NAMES[@]}"
    BUNDLE_NAMES+=("$1"); BUNDLE_VERSIONS+=("$2")
    BUNDLE_ARCHIVES+=("$(resolve_plan_path "$3")")
    BUNDLE_SHA_FILES+=("$(resolve_plan_path "$4")")
    BUNDLE_INSTALLERS+=("${5:-install.sh}")
    shift $(( $# >= 5 ? 5 : 4 ))
    declare -g -a "BUNDLE_ARGS_$index=()"
    local -n args_ref="BUNDLE_ARGS_$index"
    args_ref=("$@")
}

# shellcheck source=/dev/null
source "$PLAN"
[[ -n "$BOOTSTRAP_ARCHIVE" ]] || { echo "ERROR: plan did not register a bootstrap" >&2; exit 1; }

WORKSPACE_ROOT="${WORKSPACE_ROOT:-/workspace}"
LOG_ROOT="${LOG_ROOT:-$WORKSPACE_ROOT/startup-logs}"

# A dry run is a preview: it must not create the log directory, open a log
# file, or take the lock, and it must not need root. Previewing a plan is
# exactly what you want to do before provisioning, often as an ordinary user.
if (( DRY_RUN )); then
    printf 'Provision plan: %s\n' "$PLAN"
    printf 'Bootstrap: %s\n' "$BOOTSTRAP_ARCHIVE"
    printf 'Bundles: %d\n' "${#BUNDLE_NAMES[@]}"
    for i in "${!BUNDLE_NAMES[@]}"; do
        printf '  %d. %s %s <- %s\n' "$((i+1))" "${BUNDLE_NAMES[i]}" "${BUNDLE_VERSIONS[i]}" "${BUNDLE_ARCHIVES[i]}"
    done
    exit 0
fi

mkdir -p "$LOG_ROOT"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
LOG_FILE="$LOG_ROOT/provision-$TS.log"
SUMMARY_FILE="$LOG_ROOT/latest-provision-summary.txt"
exec > >(tee -a "$LOG_FILE") 2>&1
exec 9>"${TMPDIR:-/tmp}/server-provision.lock"
flock -w 1800 9 || { echo "ERROR: another provision run is active" >&2; exit 1; }

STEP=initialize
PROVISION_COMPLETE=0
TEMP_DIR=""
on_exit() {
    local code=$?
    [[ -z "$TEMP_DIR" ]] || rm -rf -- "$TEMP_DIR"
    if (( code != 0 && PROVISION_COMPLETE == 0 )); then
        {
            echo "STATUS: FAILED"
            echo "step: $STEP"
            echo "exit_code: $code"
            echo "plan: $PLAN"
            echo "log: $LOG_FILE"
            echo "time: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
            echo "archives: retained unless their own installation had already succeeded"
        } > "$SUMMARY_FILE"
    fi
}
trap on_exit EXIT

read_sha() { local value; value="$(grep -Eo '[0-9a-fA-F]{64}' "$1" | head -n1 || true)"; [[ "$value" =~ ^[0-9a-fA-F]{64}$ ]] || return 1; printf '%s\n' "${value,,}"; }
verify() { local expected actual; expected="$(read_sha "$2")" || { echo "ERROR: invalid checksum file: $2" >&2; return 1; }; actual="$(sha256sum "$1" | awk '{print $1}')"; [[ "$actual" == "$expected" ]] || { echo "ERROR: checksum mismatch: $1" >&2; return 1; }; }
safe_name() { local n part; while IFS= read -r n; do [[ -n "$n" && "$n" != /* && "$n" != *'\\'* ]] || return 1; IFS=/ read -r -a ps <<< "$n"; for part in "${ps[@]}"; do [[ "$part" != '..' ]] || return 1; done; done; }
extract_bootstrap() {
    local archive="$1" destination="$2"
    case "$archive" in
        *.tar.gz|*.tgz) tar -tzf "$archive" | safe_name || return 1; tar --no-same-owner --no-same-permissions -xzf "$archive" -C "$destination" ;;
        *.zip) unzip -Z1 "$archive" | safe_name || return 1; unzip -q "$archive" -d "$destination" ;;
        *) echo "ERROR: unsupported bootstrap archive: $archive" >&2; return 1 ;;
    esac
}
cleanup_pair() { rm -f -- "$1" "$2"; }

DELETE_ARCHIVES_AFTER_SUCCESS="${DELETE_ARCHIVES_AFTER_SUCCESS:-1}"
(( KEEP_ARCHIVES == 0 )) || DELETE_ARCHIVES_AFTER_SUCCESS=0
ACCEPT_POLICY="${ACCEPT_POLICY:-reject-stop}"

printf 'Provision plan: %s\n' "$PLAN"
printf 'Bootstrap: %s\n' "$BOOTSTRAP_ARCHIVE"
printf 'Bundles: %d\n' "${#BUNDLE_NAMES[@]}"

(( EUID == 0 )) || { echo "ERROR: run as root" >&2; exit 1; }
STEP=verify-bootstrap
verify "$BOOTSTRAP_ARCHIVE" "$BOOTSTRAP_SHA_FILE"
STEP=extract-bootstrap
TEMP_DIR="$(mktemp -d)"
extract_bootstrap "$BOOTSTRAP_ARCHIVE" "$TEMP_DIR"
mapfile -d '' bootstrap_matches < <(find "$TEMP_DIR" -type f -name "$BOOTSTRAP_SCRIPT" -print0)
(( ${#bootstrap_matches[@]} == 1 )) || { echo "ERROR: expected one $BOOTSTRAP_SCRIPT, found ${#bootstrap_matches[@]}" >&2; exit 1; }

echo "==> Installing server foundation"
STEP=bootstrap
RUN_ACCEPT_TEST=0 bash "${bootstrap_matches[0]}"
command -v server-bundle-install >/dev/null 2>&1 || { echo "ERROR: bootstrap did not install server-bundle-install" >&2; exit 1; }
(( DELETE_ARCHIVES_AFTER_SUCCESS == 0 )) || cleanup_pair "$BOOTSTRAP_ARCHIVE" "$BOOTSTRAP_SHA_FILE"

ACCEPTANCE=not-run
if [[ "$ACCEPT_POLICY" != off ]]; then
    STEP=acceptance
    echo "==> Checking rented server"
    result=0; server-accept || result=$?
    case "$result" in 0) ACCEPTANCE=accept ;; 1) ACCEPTANCE=reject ;; 2) ACCEPTANCE=warn ;; *) echo "ERROR: server-accept failed: $result" >&2; exit "$result" ;; esac
    [[ "$ACCEPT_POLICY" != reject-stop || "$result" != 1 ]] || { echo "ERROR: server rejected; workloads were not installed" >&2; exit 1; }
    [[ "$ACCEPT_POLICY" != warn-stop || "$result" == 0 ]] || { echo "ERROR: acceptance was not clean; workloads were not installed" >&2; exit 1; }
fi

INSTALLED=0
for i in "${!BUNDLE_NAMES[@]}"; do
    name="${BUNDLE_NAMES[i]}"; version="${BUNDLE_VERSIONS[i]}"
    archive="${BUNDLE_ARCHIVES[i]}"; sha_file="${BUNDLE_SHA_FILES[i]}"; installer="${BUNDLE_INSTALLERS[i]}"
    local_delete=(); (( DELETE_ARCHIVES_AFTER_SUCCESS == 0 )) || local_delete=(--delete-after-success)
    declare -n args_ref="BUNDLE_ARGS_$i"
    STEP="bundle:$name"
    echo "==> Installing $name $version"
    server-bundle-install --name "$name" --version "$version" --archive "$archive" \
        --sha256-file "$sha_file" --installer "$installer" "${local_delete[@]}" -- "${args_ref[@]}"
    INSTALLED=$((INSTALLED + 1))
done

STEP=finalize
{
    echo "STATUS: OK"
    echo "bootstrap: installed"
    echo "acceptance: $ACCEPTANCE"
    echo "bundles_installed: $INSTALLED"
    echo "archives_deleted: $DELETE_ARCHIVES_AFTER_SUCCESS"
    echo "plan: $PLAN"
    echo "log: $LOG_FILE"
    echo "time: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
} | tee "$SUMMARY_FILE"
PROVISION_COMPLETE=1
echo "Provisioning complete."
