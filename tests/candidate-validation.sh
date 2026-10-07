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

# The first diagnostic is the actual Ubuntu 24.04 apt-get check failure seen
# when the ARM64 provider transaction held its frontend lock in candidate CI.
for diagnostic in \
    'E: Unable to acquire the dpkg frontend lock (/var/lib/dpkg/lock-frontend), is another process using it?' \
    'Waiting for cache lock: Could not get lock /var/lib/dpkg/lock-frontend. It is held by process 42 (apt-get)' \
    'E: Could not get lock /var/lib/dpkg/lock-frontend. It is held by process 42 (apt-get)' \
    '12:00:00Z | bootstrap | waiting for another apt/dpkg process: 42 (apt-get) holds /var/lib/dpkg/lock-frontend; 42 (apt-get) holds /var/cache/apt/archives/lock'; do
    printf '%s\n' "$diagnostic" > "$TEMP/apt-output"
    accept sb_apt_contention_observed "$TEMP/apt-output"
done
for diagnostic in \
    'E: Unable to locate package missing-package' \
    'E: Could not open lock file /var/lib/dpkg/lock-frontend - open (13: Permission denied)' \
    'E: Could not get lock /var/lib/dpkg/lock-frontend - open (13: Permission denied)' \
    'E: Unable to acquire the dpkg frontend lock (/var/lib/dpkg/lock-frontend), are you root?' \
    'Waiting for cache lock: unrelated failure' \
    'E: Unable to acquire the dpkg frontend lock (/tmp/unrelated-lock), is another process using it?' \
    'Setting up openssh-server'; do
    printf '%s\n' "$diagnostic" > "$TEMP/apt-output"
    reject sb_apt_contention_observed "$TEMP/apt-output"
done
reject sb_apt_contention_observed "$TEMP/missing-apt-output"

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

# A gated tee makes fast-exit truncation deterministic. Execute the actual
# harness logging/EXIT block without touching host packages or needing root.
accept python3 - "$ROOT" <<'PY'
"""Exercise the harness's actual logging/EXIT block with a controlled reader."""
import hashlib
import os
from pathlib import Path
import select
import shutil
import signal
import subprocess
import sys
import tempfile

root = Path(sys.argv[1])
source = (root / 'validation/sb-candidate-test.sh').read_text()
start = source.index('\nexec ', source.index('mkdir -p "$LOGDIR"'))
end = source.index('\n# --- 1. Host checks:', start)
lifecycle = source[start:end]
real_tee = shutil.which('tee')
assert real_tee
with tempfile.TemporaryDirectory(prefix='candidate-logger-') as directory:
    base = Path(directory)
    binary = base / 'bin'
    binary.mkdir()
    wrapper = binary / 'tee'
    wrapper.write_text('#!' + sys.executable + '\n' + '''import os, subprocess, sys
ready = int(os.environ['FIXTURE_LOG_READY'])
release = int(os.environ['FIXTURE_LOG_RELEASE'])
os.write(ready, b'R')
os.close(ready)
if os.read(release, 1) != b'G':
    raise SystemExit(99)
os.close(release)
code = subprocess.run([os.environ['FIXTURE_REAL_TEE'], *sys.argv[1:]]).returncode
raise SystemExit(int(os.environ['FIXTURE_TEE_STATUS']) or code)
''')
    wrapper.chmod(0o755)
    script = base / 'fixture.sh'
    script.write_text('''set -Euo pipefail
LOGDIR="$1"
HEAD_SHA="$2"
MODE=logger-fixture
''' + lifecycle + '''
printf 'stdout sentinel\\n'
printf 'stderr sentinel\\n' >&2
if [[ "$FIXTURE_PATH" == finish ]]; then
    if [[ "$FIXTURE_EXIT_STATUS" == 0 ]]; then result PASS fixture
    else result FAIL fixture; fi
    printf D >&"$FIXTURE_WRITER_DONE"
    finish
fi
printf 'RESULT: %s\\n' "$([[ "$FIXTURE_EXIT_STATUS" == 0 ]] && echo PASSED || echo FAILED)"
printf D >&"$FIXTURE_WRITER_DONE"
exit "$FIXTURE_EXIT_STATUS"
''')
    cases = [('exit-success', 'exit', 0, 0, 0), ('exit-failure', 'exit', 42, 0, 42),
             ('logger-failure', 'exit', 0, 73, 73), ('both-fail', 'exit', 42, 73, 42),
             ('finish-success', 'finish', 0, 0, 0), ('finish-failure', 'finish', 1, 0, 1)]
    for name, path, original, logger_status, expected in cases:
        evidence = base / name
        evidence.mkdir()
        ready_read, ready_write = os.pipe()
        release_read, release_write = os.pipe()
        done_read, done_write = os.pipe()
        env = os.environ.copy()
        env.update(PATH=str(binary) + os.pathsep + env['PATH'], FIXTURE_REAL_TEE=real_tee,
                   FIXTURE_LOG_READY=str(ready_write), FIXTURE_LOG_RELEASE=str(release_read),
                   FIXTURE_WRITER_DONE=str(done_write), FIXTURE_PATH=path,
                   FIXTURE_EXIT_STATUS=str(original), FIXTURE_TEE_STATUS=str(logger_status))
        process = None
        try:
            with (evidence / 'console.log').open('wb') as console:
                process = subprocess.Popen(['bash', str(script), str(evidence), hashlib.sha1(b'fixture').hexdigest()],
                                           stdout=console, stderr=subprocess.STDOUT, env=env,
                                           pass_fds=(ready_write, release_read, done_write), start_new_session=True)
                for descriptor in (ready_read, done_read):
                    assert select.select([descriptor], [], [], 10)[0], name + ': missing fixture handshake'
                    assert os.read(descriptor, 1) in (b'R', b'D')
                # Both writer and logger are ready. The reader remains blocked
                # on an explicit gate, so completion before release proves loss.
                try:
                    code = process.wait(timeout=0.2)
                except subprocess.TimeoutExpired:
                    pass
                else:
                    raise AssertionError(name + ': harness exited before logger drain (exit ' + str(code) + ')')
                os.write(release_write, b'G')
                code = process.wait(timeout=10)
                assert code == expected, name + ': wrong exit status ' + str(code)
            log = (evidence / 'test.log').read_bytes()
            console = (evidence / 'console.log').read_bytes()
            for marker in (b'stdout sentinel\n', b'stderr sentinel\n',
                           b'RESULT: PASSED\n' if original == 0 else b'RESULT: FAILED\n'):
                assert marker in log and marker in console, name + ': missing final evidence in one stream'
            if logger_status == 0:
                assert console == log, name + ': stdout/stderr stream diverged from stored log'
            print('PASS logger lifecycle: ' + name)
        finally:
            if process is not None:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                process.wait()
            for descriptor in (ready_read, ready_write, release_read, release_write, done_read, done_write):
                os.close(descriptor)
print('logger lifecycle: 6 passed, 0 failed')
PY

printf 'candidate acceptance boundaries: PASS: %d FAIL: %d\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
