#!/usr/bin/env bash
# Fast rejection tests for acceptance boundaries. Never installs host packages.
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$ROOT/validation/candidate-lib.sh"
TEMP="$(mktemp -d)"
trap 'rm -rf -- "$TEMP"' EXIT
PASS=0; FAIL=0
accept() {
    if "$@" > "$TEMP/last-output" 2>&1; then PASS=$((PASS + 1))
    else printf 'FAIL expected acceptance: %s\n' "$1"; cat "$TEMP/last-output"; FAIL=$((FAIL + 1)); fi
}
reject() {
    if "$@" > "$TEMP/last-output" 2>&1; then
        printf 'FAIL expected rejection: %s\n' "$1"; FAIL=$((FAIL + 1))
    else PASS=$((PASS + 1)); fi
}

printf 'true\n' > "$TEMP/block"
{ cat "$TEMP/block"; printf '%s\n' 'echo "exit=$?" > /root/sb-startup-status'; } > "$TEMP/script"
accept sb_startup_identity "$TEMP/block" "$TEMP/script"
reject sb_startup_identity "$TEMP/block" "$TEMP/missing"
cp "$TEMP/script" "$TEMP/original"
sed 's/true/false/' "$TEMP/original" > "$TEMP/script"
reject sb_startup_identity "$TEMP/block" "$TEMP/script"
{ printf 'exit 0\n'; cat "$TEMP/original"; } > "$TEMP/script"
reject sb_startup_identity "$TEMP/block" "$TEMP/script"
{ printf "cat <<'NEVER_RUN'\n"; cat "$TEMP/original"; printf 'NEVER_RUN\n'; } > "$TEMP/script"
reject sb_startup_identity "$TEMP/block" "$TEMP/script"
reviewed_sha="$(sha256sum "$TEMP/script" | cut -d' ' -f1)"
reject sb_startup_identity "$TEMP/block" "$TEMP/script" "$reviewed_sha"
sed 's/^/# /' "$TEMP/original" > "$TEMP/script"
reject sb_startup_identity "$TEMP/block" "$TEMP/script"
{ printf '#!/usr/bin/env bash\n'; cat "$TEMP/original"; } > "$TEMP/script"
reviewed_sha="$(sha256sum "$TEMP/script" | cut -d' ' -f1)"
accept sb_startup_identity "$TEMP/block" "$TEMP/script" "$reviewed_sha"
printf '# changed wrapper\n' >> "$TEMP/script"
reject sb_startup_identity "$TEMP/block" "$TEMP/script" "$reviewed_sha"

# Execute the same status expression after real success and failure commands.
# The path differs only to keep the fixture entirely inside its temp directory.
bash -c 'true; echo "exit=$?" > "$1"' fixture "$TEMP/status"
accept sb_startup_status "$TEMP/status"
bash -c 'false; echo "exit=$?" > "$1"' fixture "$TEMP/status"
reject sb_startup_status "$TEMP/status"
reject sb_startup_status "$TEMP/missing"
printf 'exit=0\nexit=1\n' > "$TEMP/status"
reject sb_startup_status "$TEMP/status"

mkdir "$TEMP/candidate"
printf 'candidate fixture\n' > "$TEMP/candidate/asset"
(cd "$TEMP/candidate" && sha256sum asset > SHA256SUMS)
sums_sha="$(sha256sum "$TEMP/candidate/SHA256SUMS" | cut -d' ' -f1)"
accept sb_candidate_manifest "$TEMP/candidate" "$sums_sha"
printf 'other candidate bytes\n' > "$TEMP/candidate/asset"
reject sb_candidate_manifest "$TEMP/candidate" "$sums_sha"
(cd "$TEMP/candidate" && sha256sum asset > SHA256SUMS)
reject sb_candidate_manifest "$TEMP/candidate" "$sums_sha"
sums_sha="$(sha256sum "$TEMP/candidate/SHA256SUMS" | cut -d' ' -f1)"
rm "$TEMP/candidate/asset"
ln -s ../block "$TEMP/candidate/asset"
reject sb_candidate_manifest "$TEMP/candidate" "$sums_sha"
rm "$TEMP/candidate/asset"
printf 'candidate fixture\n' > "$TEMP/candidate/asset"
(cd "$TEMP/candidate" && sha256sum asset asset > SHA256SUMS)
sums_sha="$(sha256sum "$TEMP/candidate/SHA256SUMS" | cut -d' ' -f1)"
reject sb_candidate_manifest "$TEMP/candidate" "$sums_sha"

printf 'Start-Date: fixture\nCommandline: apt-get install openssh-server\nEnd-Date: fixture\n' > "$TEMP/history"
accept sb_provider_transaction "$TEMP/history" 'install ok installed' 0
reject sb_provider_transaction "$TEMP/history" 'install ok installed' 1
reject sb_provider_transaction "$TEMP/history" 'install ok unpacked' 0
printf 'Error: fixture failure\n' >> "$TEMP/history"
reject sb_provider_transaction "$TEMP/history" 'install ok installed' 0
sed '/^End-Date:/d; /^Error:/d' "$TEMP/history" > "$TEMP/incomplete-history"
reject sb_provider_transaction "$TEMP/incomplete-history" 'install ok installed' 0
reject sb_provider_history "$TEMP/incomplete-history" 'install ok installed'
printf 'Install: nano:amd64 (1.0), openssh-server:amd64 (1.0)\n' > "$TEMP/driver-history"
accept sb_no_driver_changes "$TEMP/driver-history"
printf 'Upgrade: nvidia-utils-580:amd64 (1.0, 1.1)\n' >> "$TEMP/driver-history"
reject sb_no_driver_changes "$TEMP/driver-history"
printf 'Remove: linux-modules-nvidia-580-generic:amd64 (1.0)\n' > "$TEMP/driver-history"
reject sb_no_driver_changes "$TEMP/driver-history"
printf 'Install: libcuda1:amd64 (1.0)\n' > "$TEMP/driver-history"
reject sb_no_driver_changes "$TEMP/driver-history"

# Source archives deliberately have no .git directory. The rejection fixture
# owns its Git metadata so this check runs in a checkout and an unpacked bundle.
mkdir "$TEMP/git-fixture"
git -C "$TEMP/git-fixture" init -q
git -C "$TEMP/git-fixture" -c user.name=fixture -c user.email=fixture@localhost \
    -c commit.gpgsign=false commit -q --allow-empty -m 'candidate verification fixture'
other_commit="$(git -C "$TEMP/git-fixture" rev-parse HEAD)"
if [[ "$other_commit" == 0* ]]; then other_commit="1${other_commit:1}"
else other_commit="0${other_commit:1}"; fi
reject python3 "$ROOT/validation/verify-candidate.py" --repo "$TEMP/git-fixture" --sha "$other_commit" \
    --candidate "$TEMP/candidate" --manifest-sha256 "$sums_sha"
cp "$TEMP/last-output" "$TEMP/commit-rejection"
accept grep -qF 'checkout does not match the candidate commit' "$TEMP/commit-rejection"

accept env PYTHONDONTWRITEBYTECODE=1 python3 - "$ROOT" <<'PY'
import copy
import importlib.util
from pathlib import Path
import sys
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("check_installed", Path(sys.argv[1]) / "validation/check-installed.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

def rejected(function, *args):
    try:
        function(*args)
    except AssertionError:
        return
    raise AssertionError("acceptance boundary accepted invalid evidence")

report = {"checks": [{"name": f"check-{i}", "status": "pass"} for i in range(36)] +
          [{"name": "cuda", "status": "n/a"}],
          "summary": {"pass": 36, "fail": 0, "skip": 0, "n/a": 1}}
module.check_doctor(report, False)
rejected(module.check_doctor, report, True)
partial = copy.deepcopy(report)
partial["checks"].pop(0)
rejected(module.check_doctor, partial, False)
skipped = copy.deepcopy(report)
skipped["checks"][0]["status"] = "skip"
skipped["summary"].update({"pass": 35, "skip": 1})
rejected(module.check_doctor, skipped, False)
duplicated = copy.deepcopy(report)
duplicated["checks"][1]["name"] = duplicated["checks"][0]["name"]
rejected(module.check_doctor, duplicated, False)
with patch.object(module.metadata, "version", return_value="1.2.3"):
    assert module.check_versions("example==1.2.3\n") == 1
    rejected(module.check_versions, "example==1.2.30\n")
    rejected(module.check_versions, "# no pins\n")
print("doctor completeness, CPU/GPU counts, skipped checks and exact package versions checked")
PY

printf 'candidate acceptance boundaries: PASS: %d FAIL: %d\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
