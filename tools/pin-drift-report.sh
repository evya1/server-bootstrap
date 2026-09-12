#!/usr/bin/env bash
# Turn a tools/refresh-pins.sh --check result into exactly one GitHub issue.
#
#   tools/pin-drift-report.sh DRIFT_EXIT REPORT_FILE
#
# Called by .github/workflows/pin-drift.yml. DRIFT_EXIT is refresh-pins.sh's
# exit code and REPORT_FILE is its captured output.
#
#   0  nothing actionable   -> close the open drift issue, if any. Otherwise do
#                              nothing at all: a quiet week files nothing.
#   1  a release pin is stale -> open the drift issue, or edit the existing one.
#                              The run stays green; the issue is the signal.
#   3  an upstream could not be resolved -> open or edit the issue with an
#                              UNKNOWN banner AND fail the run. A check that
#                              could not check is not a clean week, and a green
#                              tick is exactly how that becomes invisible.
#   anything else -> fail. An unexpected code is not a clean week either.
#
# One issue, found by its label and reused. A new issue every week would be read
# for about a month, and then nothing it filed would be read at all -- including
# the row that mattered. Oh My Zsh moves several times a day and is classified
# branch-head by refresh-pins.sh, so it never reaches exit 1 and never opens
# anything; it is reported inside the body when the issue exists for another
# reason.
#
# Sourcing this file defines the functions and does nothing else, so the offline
# suite can drive the decision without a network or a token.

ISSUE_LABEL=pin-drift
ISSUE_TITLE="Pinned dependencies have drifted"

# The whole branch decision, as a pure function: no network, no token, no clock.
# Prints the action; returns 0 when the workflow run should be green and 1 when
# it must be red.
pin_drift_action() {
    local drift_exit="${1:-}" has_issue="${2:-no}"
    case "$drift_exit" in
        0) [[ "$has_issue" == yes ]] && printf 'close\n' || printf 'nothing\n'; return 0 ;;
        1) [[ "$has_issue" == yes ]] && printf 'update\n' || printf 'create\n'; return 0 ;;
        3) [[ "$has_issue" == yes ]] && printf 'update\n' || printf 'create\n'; return 1 ;;
        *) printf 'fail\n'; return 1 ;;
    esac
}

# The issue body. The report is inserted from a file and never interpolated into
# a command line: it is upstream-controlled text, and gh takes --body-file for
# exactly this reason.
pin_drift_body() {
    local drift_exit="$1" report="$2" run_url="${3:-}"
    if [[ "$drift_exit" == 3 ]]; then
        cat <<'BANNER'
> **This report is incomplete.** At least one upstream could not be resolved, so
> the pins below marked `UNKNOWN` were not actually checked. Treat this as a
> broken check, not as a clean result.

BANNER
    fi
    printf 'One or more pinned dependencies are behind their upstream release.\n\n'
    printf '```text\n'
    cat -- "$report"
    printf '```\n\n'
    printf 'Refresh with `tools/refresh-pins.sh --write`, then confirm with\n'
    printf '`tools/check-pins.sh` and update `CHANGELOG.md` by hand.\n\n'
    printf 'Rows under **branch heads** track an upstream that publishes no releases.\n'
    printf 'They move constantly and are reported, not actioned; moving one is a\n'
    printf 'deliberate choice made with `--all`.\n'
    [[ -z "$run_url" ]] || printf '\nFiled by %s\n' "$run_url"
}

pin_drift_main() {
    set -Eeuo pipefail
    local drift_exit="${1:?usage: $0 DRIFT_EXIT REPORT_FILE}"
    local report="${2:?usage: $0 DRIFT_EXIT REPORT_FILE}"
    [[ -f "$report" ]] || { echo "pin-drift: no report file: $report" >&2; exit 2; }

    local existing has_issue action red=0
    existing="$(gh issue list --state open --label "$ISSUE_LABEL" \
        --limit 1 --json number --jq '.[0].number // empty')"
    has_issue=no
    [[ -z "$existing" ]] || has_issue=yes

    action="$(pin_drift_action "$drift_exit" "$has_issue")" || red=1
    printf 'pin-drift: exit %s, open issue: %s -> %s\n' "$drift_exit" "$has_issue" "$action"

    case "$action" in
        nothing) ;;
        close)
            gh issue close "$existing" \
                --comment "Every pinned release is current again; closed automatically." ;;
        create|update)
            local body="${RUNNER_TEMP:-/tmp}/pin-drift-body.md"
            pin_drift_body "$drift_exit" "$report" "${RUN_URL:-}" > "$body"
            # The label has to exist before an issue can carry it, and it is how
            # the single issue is found again next week.
            gh label create "$ISSUE_LABEL" --color BFD4F2 \
                --description "Automated pinned-dependency drift report" >/dev/null 2>&1 || true
            if [[ "$action" == create ]]; then
                gh issue create --title "$ISSUE_TITLE" --label "$ISSUE_LABEL" --body-file "$body"
            else
                gh issue edit "$existing" --body-file "$body"
            fi ;;
        fail)
            echo "pin-drift: refresh-pins.sh exited $drift_exit, which is not a result this understands" >&2 ;;
    esac

    (( red == 0 )) || exit 1
}

[[ "${BASH_SOURCE[0]}" != "$0" ]] || pin_drift_main "$@"
