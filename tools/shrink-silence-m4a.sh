#!/usr/bin/env bash
# =============================================================================
# shrink-silence-m4a.sh — shorten long silent regions in M4A recordings.
#
# Safety model:
# - Each source is decoded into a temporary .m4a beside the original.
# - The original is replaced only after ffmpeg succeeds and ffprobe validates
#   a non-empty output whose duration is not unexpectedly longer.
# - If the candidate is not smaller, the original is retained.
# - Names and directory locations remain unchanged.
# =============================================================================
set -Eeuo pipefail

usage() {
    cat <<'EOF_USAGE'
Usage:
  shrink-silence-m4a.sh [OPTIONS] [FILE ...]

Without FILE arguments, process all .m4a files in the current directory.
Files are safely replaced in place only after successful validation.

Options:
  -d, --directory DIR       process .m4a files in DIR instead of the current one
  -r, --recursive           include subdirectories when using directory mode
      --threshold DB        silence threshold (default: -60dB)
      --min-silence SEC     shorten silence only after SEC seconds (default: 7)
      --keep-silence SEC    retain SEC seconds total around each cut (default: 1)
      --bitrate RATE        AAC bitrate, for example 48k (default: 48k)
      --channels N          output channels: 1 or 2 (default: 1)
      --analysis-only PATH  detect silence and write the offset report to PATH;
                             never touches the input file. Requires exactly one
                             FILE argument (no --directory, no multi-file).
  -h, --help                show this help

Examples:
  shrink-silence-m4a.sh
  shrink-silence-m4a.sh recording.m4a
  shrink-silence-m4a.sh --directory /path/to/recordings
  shrink-silence-m4a.sh --recursive --directory /path/to/recordings
  shrink-silence-m4a.sh --analysis-only recording.shrink_offsets.json recording.m4a

WHY --analysis-only. The shrink below is destructive in place: once it swaps a
smaller file over the original, the exact seconds that were cut are gone unless
something persisted them. On every real shrink this script writes a permanent
<stem>.shrink_offsets.json sidecar next to the shrunk file (kept_intervals /
removed_intervals in ORIGINAL-file seconds) precisely so a downstream tool can
map a timestamp in the shrunk file back to the original timeline -- anything
that needs to correlate the shrunk audio against something keyed to the
original file's clock (an external event log, a second recording, ground-truth
annotations) breaks silently without that map. --analysis-only computes the
same report against a file WITHOUT shrinking it, which is what you want to
recover a sidecar for a file that was already shrunk before this mechanism
existed, from a surviving unshrunk copy.
EOF_USAGE
}

TARGET_DIRECTORY="."
RECURSIVE=0
SILENCE_THRESHOLD="${WHISPER_M4A_SILENCE_THRESHOLD:--60dB}"
MIN_SILENCE_SECONDS="${WHISPER_M4A_MIN_SILENCE_SECONDS:-7}"
KEEP_SILENCE_SECONDS="${WHISPER_M4A_KEEP_SILENCE_SECONDS:-1}"
AUDIO_BITRATE="${WHISPER_M4A_AUDIO_BITRATE:-48k}"
AUDIO_CHANNELS="${WHISPER_M4A_AUDIO_CHANNELS:-1}"
DIRECTORY_WAS_SET=0
ANALYSIS_ONLY_PATH=""
INPUT_FILES=()

while (($#)); do
    case "$1" in
        -d|--directory)
            [[ $# -ge 2 ]] || { echo "ERROR: $1 requires a directory." >&2; exit 2; }
            TARGET_DIRECTORY="$2"
            DIRECTORY_WAS_SET=1
            shift 2
            ;;
        -r|--recursive)
            RECURSIVE=1
            shift
            ;;
        --threshold)
            [[ $# -ge 2 ]] || { echo "ERROR: --threshold requires a value." >&2; exit 2; }
            SILENCE_THRESHOLD="$2"
            shift 2
            ;;
        --min-silence)
            [[ $# -ge 2 ]] || { echo "ERROR: --min-silence requires a value." >&2; exit 2; }
            MIN_SILENCE_SECONDS="$2"
            shift 2
            ;;
        --keep-silence)
            [[ $# -ge 2 ]] || { echo "ERROR: --keep-silence requires a value." >&2; exit 2; }
            KEEP_SILENCE_SECONDS="$2"
            shift 2
            ;;
        --bitrate)
            [[ $# -ge 2 ]] || { echo "ERROR: --bitrate requires a value." >&2; exit 2; }
            AUDIO_BITRATE="$2"
            shift 2
            ;;
        --channels)
            [[ $# -ge 2 ]] || { echo "ERROR: --channels requires a value." >&2; exit 2; }
            AUDIO_CHANNELS="$2"
            shift 2
            ;;
        --analysis-only)
            [[ $# -ge 2 ]] || { echo "ERROR: --analysis-only requires a PATH." >&2; exit 2; }
            ANALYSIS_ONLY_PATH="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --)
            shift
            while (($#)); do INPUT_FILES+=("$1"); shift; done
            ;;
        -*)
            echo "ERROR: unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
        *)
            INPUT_FILES+=("$1")
            shift
            ;;
    esac
done

if (( DIRECTORY_WAS_SET == 1 && ${#INPUT_FILES[@]} > 0 )); then
    echo "ERROR: use either --directory or explicit FILE arguments, not both." >&2
    exit 2
fi

if [[ -n "$ANALYSIS_ONLY_PATH" ]]; then
    (( DIRECTORY_WAS_SET == 0 )) || {
        echo "ERROR: --analysis-only requires a single FILE argument, not --directory." >&2
        exit 2
    }
    (( ${#INPUT_FILES[@]} == 1 )) || {
        echo "ERROR: --analysis-only requires exactly one FILE argument." >&2
        exit 2
    }
fi

for command_name in ffmpeg ffprobe python3 find sort stat awk mv rm chmod touch; do
    command -v "$command_name" >/dev/null 2>&1 || {
        echo "ERROR: required command not found: $command_name" >&2
        exit 1
    }
done

[[ "$SILENCE_THRESHOLD" =~ ^-[0-9]+([.][0-9]+)?dB$ ]] || {
    echo "ERROR: invalid threshold '$SILENCE_THRESHOLD' (example: -60dB)." >&2
    exit 2
}

for pair in \
    "minimum silence:$MIN_SILENCE_SECONDS" \
    "kept silence:$KEEP_SILENCE_SECONDS"
do
    label="${pair%%:*}"
    value="${pair#*:}"
    awk -v value="$value" 'BEGIN { exit !(value ~ /^[0-9]+([.][0-9]+)?$/ && value >= 0) }' || {
        echo "ERROR: invalid $label value: $value" >&2
        exit 2
    }
done

awk -v keep="$KEEP_SILENCE_SECONDS" -v minimum="$MIN_SILENCE_SECONDS" \
    'BEGIN { exit !(minimum > 0 && keep < minimum) }' || {
    echo "ERROR: --keep-silence must be smaller than --min-silence, and minimum must be positive." >&2
    exit 2
}

[[ "$AUDIO_BITRATE" =~ ^[0-9]+k$ ]] || {
    echo "ERROR: invalid bitrate '$AUDIO_BITRATE' (example: 48k)." >&2
    exit 2
}

[[ "$AUDIO_CHANNELS" == "1" || "$AUDIO_CHANNELS" == "2" ]] || {
    echo "ERROR: --channels must be 1 or 2." >&2
    exit 2
}

if (( ${#INPUT_FILES[@]} == 0 )); then
    [[ -d "$TARGET_DIRECTORY" ]] || {
        echo "ERROR: directory does not exist: $TARGET_DIRECTORY" >&2
        exit 1
    }

    if (( RECURSIVE )); then
        mapfile -d '' INPUT_FILES < <(
            find "$TARGET_DIRECTORY" \
                -type f \
                -iname '*.m4a' \
                ! -name '.whisper-m4a-shrink.*' \
                -print0 | sort -z
        )
    else
        mapfile -d '' INPUT_FILES < <(
            find "$TARGET_DIRECTORY" \
                -maxdepth 1 \
                -type f \
                -iname '*.m4a' \
                ! -name '.whisper-m4a-shrink.*' \
                -print0 | sort -z
        )
    fi
fi

if (( ${#INPUT_FILES[@]} == 0 )); then
    echo "No .m4a files found."
    exit 0
fi

SCRIPT_DIRECTORY="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
FILTER_BUILDER="$SCRIPT_DIRECTORY/build-silence-filter.py"
[[ -x "$FILTER_BUILDER" ]] || {
    echo "ERROR: missing silence filter builder: $FILTER_BUILDER" >&2
    exit 1
}

probe_duration() {
    ffprobe \
        -v error \
        -show_entries format=duration \
        -of default=noprint_wrappers=1:nokey=1 \
        -- "$1"
}

is_positive_number() {
    awk -v value="$1" \
        'BEGIN { exit !(value ~ /^[0-9]+([.][0-9]+)?$/ && value > 0) }'
}

add_numbers() {
    awk -v first="$1" -v second="$2" \
        'BEGIN { printf "%.6f", first + second }'
}

subtract_nonnegative() {
    awk -v before="$1" -v after="$2" '
        BEGIN {
            difference = before - after
            if (difference < 0) difference = 0
            printf "%.6f", difference
        }
    '
}

format_duration() {
    awk -v total="$1" '
        BEGIN {
            if (total < 0) total = 0
            hours = int(total / 3600)
            total -= hours * 3600
            minutes = int(total / 60)
            seconds = total - minutes * 60
            printf "%02d:%02d:%06.3f", hours, minutes, seconds
        }
    '
}

format_bytes() {
    awk -v bytes="$1" '
        BEGIN {
            split("B KiB MiB GiB TiB", units, " ")
            unit = 1
            while (bytes >= 1024 && unit < 5) {
                bytes /= 1024
                unit++
            }
            printf "%.2f %s", bytes, units[unit]
        }
    '
}

percentage_saved() {
    awk -v before="$1" -v after="$2" '
        BEGIN {
            if (before <= 0 || after >= before) printf "0.00"
            else printf "%.2f", 100 * (before - after) / before
        }
    '
}

# Enrich a build-silence-filter.py report with provenance fields and write it
# to a permanent sidecar path. kept_intervals/removed_intervals are already in
# original-file seconds, so this is pure persistence -- no time math here.
write_offset_sidecar() {
    local report_path="$1" out_path="$2" source_label="$3"
    mkdir -p -- "$(dirname -- "$out_path")"
    python3 - "$report_path" "$out_path" "$source_label" \
        "$SILENCE_THRESHOLD" "$MIN_SILENCE_SECONDS" "$KEEP_SILENCE_SECONDS" <<'PY_SIDECAR'
import json
import sys
import time

report_path, out_path, source_label, threshold_db, min_silence, keep_silence = sys.argv[1:7]
with open(report_path, encoding="utf-8") as handle:
    payload = json.load(handle)

payload["schema_version"] = 1
payload["generated_at_unix"] = time.time()
payload["source"] = source_label
payload["threshold_db"] = threshold_db
payload["min_silence_seconds"] = float(min_silence)
payload["keep_silence_seconds"] = float(keep_silence)

with open(out_path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2)
    handle.write("\n")
PY_SIDECAR
}

files_discovered="${#INPUT_FILES[@]}"
files_replaced=0
files_unchanged=0
files_failed=0
files_analyzed=0
total_before_duration="0"
total_after_duration="0"
total_before_bytes=0
total_after_bytes=0
current_tmp=""
current_detect_log=""
current_filter_script=""
current_analysis_report=""

cleanup() {
    for path in \
        "${current_tmp:-}" \
        "${current_detect_log:-}" \
        "${current_filter_script:-}" \
        "${current_analysis_report:-}"
    do
        if [[ -n "$path" && -e "$path" ]]; then
            rm -f -- "$path"
        fi
    done
}

reset_current_paths() {
    current_tmp=""
    current_detect_log=""
    current_filter_script=""
    current_analysis_report=""
}

cleanup_and_reset() {
    cleanup
    reset_current_paths
}

trap cleanup EXIT
trap 'exit 130' INT TERM

printf 'M4A in-place silence shrinking\n'
printf 'Files discovered:  %d\n' "$files_discovered"
printf 'Minimum silence:   %ss\n' "$MIN_SILENCE_SECONDS"
printf 'Silence retained:  %ss\n' "$KEEP_SILENCE_SECONDS"
printf 'Threshold:         %s\n' "$SILENCE_THRESHOLD"
printf 'Output audio:      AAC %s, %s channel(s)\n' "$AUDIO_BITRATE" "$AUDIO_CHANNELS"
printf 'Safety:            temporary output + validation before replacement\n'

for file in "${INPUT_FILES[@]}"; do
    if [[ ! -f "$file" ]]; then
        printf '\nFAILED: not a regular file: %s\n' "$file" >&2
        files_failed=$((files_failed + 1))
        continue
    fi

    case "${file,,}" in
        *.m4a) ;;
        *)
            printf '\nFAILED: not an .m4a file: %s\n' "$file" >&2
            files_failed=$((files_failed + 1))
            continue
            ;;
    esac

    filename="${file##*/}"
    directory="${file%/*}"
    [[ "$directory" != "$file" ]] || directory="."

    before_duration="$(probe_duration "$file" 2>/dev/null || true)"
    before_bytes="$(stat -c '%s' -- "$file" 2>/dev/null || true)"

    if ! is_positive_number "$before_duration" || \
       [[ ! "$before_bytes" =~ ^[0-9]+$ ]] || \
       (( before_bytes <= 0 )); then
        printf '\nFAILED: could not read duration or size: %s\n' "$file" >&2
        files_failed=$((files_failed + 1))
        continue
    fi

    total_before_duration="$(add_numbers "$total_before_duration" "$before_duration")"
    total_before_bytes=$((total_before_bytes + before_bytes))

    temporary_prefix="${directory}/.whisper-m4a-shrink.$$.${RANDOM}.${filename}"
    current_tmp="${temporary_prefix}.m4a"
    current_detect_log="${temporary_prefix}.silencedetect.log"
    current_filter_script="${temporary_prefix}.filter.txt"
    current_analysis_report="${temporary_prefix}.analysis.json"
    rm -f -- \
        "$current_tmp" \
        "$current_detect_log" \
        "$current_filter_script" \
        "$current_analysis_report"

    printf '\n============================================================\n'
    printf 'Processing:        %s\n' "$file"
    printf 'Original duration: %s\n' "$(format_duration "$before_duration")"
    printf 'Original size:     %s\n' "$(format_bytes "$before_bytes")"

    printf 'Analyzing long silence...\n'
    if ! ffmpeg \
        -hide_banner \
        -nostdin \
        -loglevel info \
        -i "$file" \
        -af "silencedetect=noise=${SILENCE_THRESHOLD}:d=${MIN_SILENCE_SECONDS}" \
        -f null - \
        > /dev/null 2> "$current_detect_log"
    then
        printf 'FAILED: silence analysis did not complete. Original retained.\n' >&2
        cleanup_and_reset
        total_after_duration="$(add_numbers "$total_after_duration" "$before_duration")"
        total_after_bytes=$((total_after_bytes + before_bytes))
        files_failed=$((files_failed + 1))
        continue
    fi

    if ! python3 "$FILTER_BUILDER" \
        --log-file "$current_detect_log" \
        --duration "$before_duration" \
        --keep-silence "$KEEP_SILENCE_SECONDS" \
        --filter-script "$current_filter_script" \
        --report "$current_analysis_report"
    then
        printf 'FAILED: could not construct safe silence cuts. Original retained.\n' >&2
        cleanup_and_reset
        total_after_duration="$(add_numbers "$total_after_duration" "$before_duration")"
        total_after_bytes=$((total_after_bytes + before_bytes))
        files_failed=$((files_failed + 1))
        continue
    fi

    estimated_removed="$(python3 - "$current_analysis_report" <<'PY_REPORT'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as handle:
    print(f"{json.load(handle)['estimated_removed_seconds']:.6f}")
PY_REPORT
)"
    printf 'Detected removable silence: %s\n' "$(format_duration "$estimated_removed")"

    if [[ -n "$ANALYSIS_ONLY_PATH" ]]; then
        write_offset_sidecar "$current_analysis_report" "$ANALYSIS_ONLY_PATH" "analysis_only"
        cleanup_and_reset
        total_after_duration="$(add_numbers "$total_after_duration" "$before_duration")"
        total_after_bytes=$((total_after_bytes + before_bytes))
        files_analyzed=$((files_analyzed + 1))
        printf 'Report written:    %s\n' "$ANALYSIS_ONLY_PATH"
        printf 'Original file:     UNCHANGED (analysis-only)\n'
        continue
    fi

    printf 'Encoding validated candidate...\n'

    if ! ffmpeg \
        -hide_banner \
        -nostdin \
        -loglevel warning \
        -stats \
        -y \
        -i "$file" \
        -filter_complex_script "$current_filter_script" \
        -map '[outa]' \
        -map_metadata 0 \
        -vn \
        -c:a aac \
        -ac "$AUDIO_CHANNELS" \
        -b:a "$AUDIO_BITRATE" \
        -movflags +faststart \
        "$current_tmp"
    then
        printf 'FAILED: FFmpeg did not complete successfully. Original retained.\n' >&2
        cleanup_and_reset
        total_after_duration="$(add_numbers "$total_after_duration" "$before_duration")"
        total_after_bytes=$((total_after_bytes + before_bytes))
        files_failed=$((files_failed + 1))
        continue
    fi

    after_duration="$(probe_duration "$current_tmp" 2>/dev/null || true)"
    after_bytes="$(stat -c '%s' -- "$current_tmp" 2>/dev/null || true)"

    if ! is_positive_number "$after_duration" || \
       [[ ! "$after_bytes" =~ ^[0-9]+$ ]] || \
       (( after_bytes <= 0 )); then
        printf 'FAILED: candidate did not pass basic validation. Original retained.\n' >&2
        cleanup_and_reset
        total_after_duration="$(add_numbers "$total_after_duration" "$before_duration")"
        total_after_bytes=$((total_after_bytes + before_bytes))
        files_failed=$((files_failed + 1))
        continue
    fi

    if ! awk -v before="$before_duration" -v after="$after_duration" \
        'BEGIN { exit !(after <= before + 1.0) }'; then
        printf 'FAILED: candidate is unexpectedly longer. Original retained.\n' >&2
        cleanup_and_reset
        total_after_duration="$(add_numbers "$total_after_duration" "$before_duration")"
        total_after_bytes=$((total_after_bytes + before_bytes))
        files_failed=$((files_failed + 1))
        continue
    fi

    removed_duration="$(subtract_nonnegative "$before_duration" "$after_duration")"

    if (( after_bytes >= before_bytes )); then
        printf 'UNCHANGED: candidate was not smaller, so the original was retained.\n'
        printf 'Candidate duration: %s\n' "$(format_duration "$after_duration")"
        printf 'Candidate size:     %s\n' "$(format_bytes "$after_bytes")"
        cleanup_and_reset
        total_after_duration="$(add_numbers "$total_after_duration" "$before_duration")"
        total_after_bytes=$((total_after_bytes + before_bytes))
        files_unchanged=$((files_unchanged + 1))
        continue
    fi

    saved_bytes=$((before_bytes - after_bytes))
    saved_percentage="$(percentage_saved "$before_bytes" "$after_bytes")"

    chmod --reference="$file" "$current_tmp" 2>/dev/null || true
    touch -r "$file" "$current_tmp" 2>/dev/null || true
    rm -f -- "$current_detect_log" "$current_filter_script"
    current_detect_log=""
    current_filter_script=""

    if ! mv -f -- "$current_tmp" "$file"; then
        printf 'FAILED: could not replace the original. Original retained.\n' >&2
        cleanup_and_reset
        total_after_duration="$(add_numbers "$total_after_duration" "$before_duration")"
        total_after_bytes=$((total_after_bytes + before_bytes))
        files_failed=$((files_failed + 1))
        continue
    fi
    current_tmp=""

    # Persist the cut list as a permanent sidecar -- without it, a timestamp in
    # THIS shrunk file can never be mapped back to the original file's
    # timeline. Written only now that the shrunk file is actually live, so a
    # sidecar never outlives a swap that didn't happen.
    offsets_sidecar="${directory}/${filename%.*}.shrink_offsets.json"
    write_offset_sidecar "$current_analysis_report" "$offsets_sidecar" "shrink"
    rm -f -- "$current_analysis_report"
    current_analysis_report=""

    total_after_duration="$(add_numbers "$total_after_duration" "$after_duration")"
    total_after_bytes=$((total_after_bytes + after_bytes))
    files_replaced=$((files_replaced + 1))

    printf 'Updated in place:   %s\n' "$file"
    printf 'New duration:       %s\n' "$(format_duration "$after_duration")"
    printf 'Time removed:       %s\n' "$(format_duration "$removed_duration")"
    printf 'New size:           %s\n' "$(format_bytes "$after_bytes")"
    printf 'Storage saved:      %s (%s%%)\n' \
        "$(format_bytes "$saved_bytes")" "$saved_percentage"
    printf 'Offsets sidecar:    %s\n' "$offsets_sidecar"
done

total_removed_duration="$(subtract_nonnegative "$total_before_duration" "$total_after_duration")"
total_saved_bytes=$((total_before_bytes - total_after_bytes))
(( total_saved_bytes >= 0 )) || total_saved_bytes=0
total_saved_percentage="$(percentage_saved "$total_before_bytes" "$total_after_bytes")"

printf '\n============================================================\n'
printf 'FINAL SUMMARY\n'
printf '============================================================\n'
printf 'Files discovered:     %d\n' "$files_discovered"
printf 'Files replaced:       %d\n' "$files_replaced"
printf 'Files unchanged:      %d\n' "$files_unchanged"
printf 'Files failed:         %d\n' "$files_failed"
(( files_analyzed == 0 )) || printf 'Files analyzed-only:  %d\n' "$files_analyzed"
printf '\n'
printf 'Duration before:      %s\n' "$(format_duration "$total_before_duration")"
printf 'Duration after:       %s\n' "$(format_duration "$total_after_duration")"
printf 'Total time removed:   %s\n' "$(format_duration "$total_removed_duration")"
printf '\n'
printf 'Storage before:       %s\n' "$(format_bytes "$total_before_bytes")"
printf 'Storage after:        %s\n' "$(format_bytes "$total_after_bytes")"
printf 'Total storage saved:  %s (%s%%)\n' \
    "$(format_bytes "$total_saved_bytes")" "$total_saved_percentage"

(( files_failed == 0 ))
