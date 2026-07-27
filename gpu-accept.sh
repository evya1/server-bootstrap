#!/usr/bin/env bash
# =============================================================================
# gpu-accept.sh — decide whether the box you just rented is the box you bought.
#
# Runs in under 60s on nvidia-smi + coreutils. No Python, no torch, no network
# by default. Intended as the FIRST thing after gpu-server-bootstrap, while the
# meter is running and destroying the instance is still cheap.
#
# Exit codes:  0 accept   1 reject (hard failure)   2 warn (review)   3 usage
#
# Rejects, in order of how often they actually happen on rental marketplaces:
#   - PCIe link narrower than the card supports (x16 card on an x1/x4 riser).
#     Costs you nothing at idle and 5x on every model load and H2D copy.
#   - Persistent thermal/power throttling (box in someone's garage in August).
#   - Volatile uncorrected ECC errors (walk away; do not debug).
#   - Less VRAM/RAM/vCPU than advertised.
#   - Storage slower than the model download (a 3GB model at 40MB/s is a bad day).
# =============================================================================
set -Eeuo pipefail

MIN_VRAM_MIB="${MIN_VRAM_MIB:-0}"
MIN_PCIE_WIDTH="${MIN_PCIE_WIDTH:-8}"
MIN_PCIE_GEN="${MIN_PCIE_GEN:-3}"
MIN_CORES="${MIN_CORES:-0}"
MIN_RAM_GB="${MIN_RAM_GB:-0}"
MIN_DISK_GB="${MIN_DISK_GB:-50}"
MIN_DISK_MBPS="${MIN_DISK_MBPS:-100}"
MAX_TEMP_C="${MAX_TEMP_C:-85}"
WORKSPACE="${WORKSPACE_ROOT:-/workspace}"
JSON=0

usage() {
    cat <<'EOF'
Usage: gpu-accept.sh [--json]
Thresholds are environment variables (current defaults shown by --json):
  MIN_VRAM_MIB MIN_PCIE_WIDTH MIN_PCIE_GEN MIN_CORES MIN_RAM_GB
  MIN_DISK_GB MIN_DISK_MBPS MAX_TEMP_C WORKSPACE_ROOT
Exit: 0 accept, 1 reject, 2 warn, 3 usage.
EOF
}

case "${1:-}" in
    --json) JSON=1 ;;
    -h|--help) usage; exit 0 ;;
    "") : ;;
    *) usage >&2; exit 3 ;;
esac

REJECT=0
WARN=0
declare -a FINDINGS=()

note()   { FINDINGS+=("ok|$1|$2");     (( JSON )) || printf '  ok     %-22s %s\n' "$1" "$2"; }
warn()   { FINDINGS+=("warn|$1|$2");   WARN=$((WARN+1));     (( JSON )) || printf '  WARN   %-22s %s\n' "$1" "$2"; }
reject() { FINDINGS+=("reject|$1|$2"); REJECT=$((REJECT+1)); (( JSON )) || printf '  REJECT %-22s %s\n' "$1" "$2"; }

q() {  # q FIELD  -> first GPU's value for an nvidia-smi query field
    nvidia-smi --query-gpu="$1" --format=csv,noheader,nounits 2>/dev/null \
        | head -n1 | sed 's/^ *//; s/ *$//'
}

(( JSON )) || echo "== gpu-accept =="

# ---- GPU present ------------------------------------------------------------
if ! command -v nvidia-smi >/dev/null 2>&1; then
    reject "gpu" "nvidia-smi absent — this box has no usable GPU"
else
    NAME="$(q name)"; VRAM="$(q memory.total)"; DRIVER="$(q driver_version)"
    note "gpu" "$NAME, ${VRAM}MiB, driver $DRIVER"

    if [[ "$MIN_VRAM_MIB" -gt 0 && "${VRAM:-0}" -lt "$MIN_VRAM_MIB" ]]; then
        reject "vram" "${VRAM}MiB < required ${MIN_VRAM_MIB}MiB"
    fi

    # -- PCIe. The classic rental scam and the classic false positive.
    # link.*.current downtrains to x1/gen1 at idle to save power, so reading it
    # on a quiet box tells you nothing. link.*.max is the negotiated ceiling —
    # that is the number that exposes a x16 card sitting on a x1 mining riser.
    W_MAX="$(q pcie.link.width.max)"; W_CUR="$(q pcie.link.width.current)"
    G_MAX="$(q pcie.link.gen.max)";   G_CUR="$(q pcie.link.gen.current)"
    if [[ -z "$W_MAX" || "$W_MAX" == "[N/A]" ]]; then
        warn "pcie" "not reported (vGPU/passthrough?) — cannot verify link"
    elif [[ "$W_MAX" -lt "$MIN_PCIE_WIDTH" ]]; then
        reject "pcie-width" "negotiated x${W_MAX} < required x${MIN_PCIE_WIDTH} (riser/slot limited)"
    elif [[ "${G_MAX:-0}" -lt "$MIN_PCIE_GEN" ]]; then
        reject "pcie-gen" "gen${G_MAX} < required gen${MIN_PCIE_GEN}"
    else
        note "pcie" "max x${W_MAX} gen${G_MAX} (idle now: x${W_CUR} gen${G_CUR}, expected)"
    fi

    # -- Throttling. Reported as a bitmask of reason strings.
    THROTTLE="$(nvidia-smi --query-gpu=clocks_throttle_reasons.active --format=csv,noheader 2>/dev/null | head -n1)"
    case "${THROTTLE:-}" in
        *0x0000000000000000*|"") note "throttle" "none active" ;;
        *) warn "throttle" "active: $THROTTLE (re-check under load)" ;;
    esac

    TEMP="$(q temperature.gpu)"
    if [[ -n "$TEMP" && "$TEMP" =~ ^[0-9]+$ ]]; then
        if (( TEMP > MAX_TEMP_C )); then
            reject "temp" "${TEMP}C > ${MAX_TEMP_C}C at IDLE — this box will throttle under load"
        else
            note "temp" "${TEMP}C idle"
        fi
    fi

    ECC="$(q ecc.errors.uncorrected.volatile.total)"
    case "$ECC" in
        ""|"[N/A]"|"[Not Supported]") note "ecc" "not supported on this SKU" ;;
        0) note "ecc" "0 uncorrected" ;;
        *) reject "ecc" "$ECC uncorrected volatile errors — reject, do not debug" ;;
    esac

    OTHER="$(nvidia-smi --query-compute-apps=pid,used_memory --format=csv,noheader 2>/dev/null | wc -l)"
    if [[ "${OTHER:-0}" -gt 0 ]]; then
        warn "tenancy" "$OTHER compute process(es) already on this GPU — you may be sharing"
    else
        note "tenancy" "GPU idle, no other compute apps"
    fi
fi

# ---- CPU / RAM --------------------------------------------------------------
CORES="$(nproc)"
RAM_GB="$(awk '/MemTotal/{printf "%d", $2/1048576}' /proc/meminfo)"
if [[ "$MIN_CORES" -gt 0 && "$CORES" -lt "$MIN_CORES" ]]; then
    reject "cpu" "$CORES cores < advertised $MIN_CORES"
else
    note "cpu" "$CORES cores"
fi
if [[ "$MIN_RAM_GB" -gt 0 && "$RAM_GB" -lt "$MIN_RAM_GB" ]]; then
    reject "ram" "${RAM_GB}GB < advertised ${MIN_RAM_GB}GB"
else
    note "ram" "${RAM_GB}GB"
fi

# ---- Disk capacity + speed --------------------------------------------------
mkdir -p "$WORKSPACE" 2>/dev/null || true
if [[ -d "$WORKSPACE" ]]; then
    FREE_GB="$(df -BG --output=avail "$WORKSPACE" 2>/dev/null | tail -n1 | tr -dc '0-9')"
    if [[ "${FREE_GB:-0}" -lt "$MIN_DISK_GB" ]]; then
        reject "disk-free" "${FREE_GB}GB free < ${MIN_DISK_GB}GB (model + lectures will not fit)"
    else
        note "disk-free" "${FREE_GB}GB free at $WORKSPACE"
    fi

    PROBE="$WORKSPACE/.accept-probe.$$"
    if DD_OUT="$(dd if=/dev/zero of="$PROBE" bs=1M count=512 oflag=direct 2>&1)" \
       || DD_OUT="$(dd if=/dev/zero of="$PROBE" bs=1M count=512 conv=fdatasync 2>&1)"; then
        # dd reports speed in kB/s, MB/s, or GB/s depending on drive throughput;
        # fast NVMe routinely hits GB/s. Normalize to MB/s and never let a
        # non-match abort the script under pipefail (no match is not an error).
        RAW_SPEED="$(printf '%s' "$DD_OUT" | grep -oE '[0-9.]+ [kKMG]B/s' | tail -n1 || true)"
        MBPS=""
        if [[ -n "$RAW_SPEED" ]]; then
            MBPS="$(awk -v raw="$RAW_SPEED" 'BEGIN{
                split(raw, a, " "); v = a[1]; u = a[2];
                if (u == "GB/s") v *= 1024;
                else if (u == "kB/s" || u == "KB/s") v /= 1024;
                printf "%d", v;
            }')"
        fi
        if [[ -n "$MBPS" && "$MBPS" -lt "$MIN_DISK_MBPS" ]]; then
            warn "disk-speed" "${MBPS}MB/s write < ${MIN_DISK_MBPS}MB/s — model pull and video render will crawl"
        else
            note "disk-speed" "${MBPS:-?}MB/s sequential write"
        fi
    else
        warn "disk-speed" "probe failed; skipped"
    fi
    rm -f "$PROBE"
fi

# ---- verdict ----------------------------------------------------------------
if (( JSON )); then
    printf '{\n  "verdict": "%s",\n  "rejects": %d,\n  "warns": %d,\n  "findings": [\n' \
        "$( (( REJECT )) && echo reject || { (( WARN )) && echo warn || echo accept; } )" \
        "$REJECT" "$WARN"
    for i in "${!FINDINGS[@]}"; do
        IFS='|' read -r lvl key msg <<< "${FINDINGS[$i]}"
        printf '    {"level":"%s","check":"%s","detail":"%s"}%s\n' \
            "$lvl" "$key" "${msg//\"/\\\"}" "$([[ $i -lt $((${#FINDINGS[@]}-1)) ]] && echo ,)"
    done
    printf '  ]\n}\n'
else
    echo
    if (( REJECT )); then
        echo "VERDICT: REJECT ($REJECT hard, $WARN warn) — destroy this instance and rent another."
    elif (( WARN )); then
        echo "VERDICT: WARN ($WARN) — usable, but read the warnings before a long batch."
    else
        echo "VERDICT: ACCEPT — box matches spec."
    fi
fi

(( REJECT )) && exit 1
(( WARN )) && exit 2
exit 0
