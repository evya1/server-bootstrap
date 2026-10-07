#!/usr/bin/env bash
# Acceptance of a verified server-bootstrap candidate or published release on Ubuntu
# 24.04 host, x86_64 or aarch64, as root. Exit status: 0 only if every stage
# passed. Generalised from the PR #69 clean-host test.
#
#   bash sb-candidate-test.sh --check [--scenario S]   clean-host checks and candidate
#                                                      verification; writes evidence only
#   bash sb-candidate-test.sh [--scenario S]           the gate, then the documented
#                                                      block, stack checks, a repeat,
#                                                      and the stack checks again
#   bash sb-candidate-test.sh --after-startup [--check] [--scenario S]
#                                                      verify an install that the host's
#                                                      startup script already ran at boot
#                                                      from the real release URL, instead
#                                                      of doing a first install: the status
#                                                      file, the downloaded files, the
#                                                      stored script, the stack, then the
#                                                      same repeat as the gate
#
# Scenarios, each the copyable block exactly as the verified archive ships it,
# with only its BASE line pointed at a loopback copy of the candidate files:
#   full      README.md "## How to use"                  provision-plan.full.example.sh
#   minimal   docs/QUICKSTART.md "### Foundation-only install" provision-plan.example.sh
#   ml        docs/ML-PROFILE.md "## One-command install" provision-plan.ml.example.sh
#
# Required environment:
#   SB_CAND_SHA        commit the candidate was built from
#   SB_CAND_SUMS_SHA   sha256 of the candidate's SHA256SUMS, recorded out of band
# Optional:
#   SB_PUBLIC_TGZ_SHA  sha256 of a published archive with the same file name; the
#                      candidate must differ from it
#   SB_EXPECT_GPU=1    an NVIDIA GPU must be visible and the ml backend CUDA;
#                      without it a visible GPU stops the run
#   SB_CANDIDATE_DIR   default /root/sb-candidate
#   SB_TEST_MIN_FREE_GB, SB_TEST_PORT
#   SB_STARTUP_STATUS  --after-startup: the status file the startup script writes
#                      (default /root/sb-startup-status); its content must be exit=0
#   SB_STARTUP_SCRIPT  --after-startup: path of the startup script as the host stores
#                      it; required. Must equal the documented block plus status line.
#   SB_STARTUP_SCRIPT_SHA
#                      optional hash recorded before boot for an approved Bash shebang
#                      prefix; the entire script must otherwise equal the exact payload.
#   SB_TEST_PREINSTALL_WGET=1
#                      before the block runs (stage 4), install wget and ca-certificates
#                      (apt-get update && apt-get install -y --no-install-recommends wget
#                      ca-certificates), so the block's own wget guard is skipped and any
#                      contention lands on the bootstrap's own apt calls. The clean-host
#                      check before it is unchanged. Not valid with --after-startup.
#   SB_TEST_CONTENTION=provider
#                      right before the block runs (stage 4), start a background "provider
#                      entrypoint" as a GPU cloud provider's container entrypoint does at
#                      boot: apt-get update, then DEBIAN_FRONTEND=noninteractive apt-get
#                      install -y --no-install-recommends xz-utils nano htop openssh-server;
#                      a bounded pre-invoke hook holds its real apt lock until the block
#                      reports waiting for it. Both observed locking and waiting are required.
#                      After the block, the
#                      job is waited for and checked: its exit status, openssh-server
#                      installed, and its /var/log/apt/history.log transaction with an
#                      End-Date and no Error. A broken provider install is a FAIL even if
#                      the block succeeded. Its output goes to $LOGDIR/provider.log.
#                      Not valid with --after-startup.
#                      Both options are off by default; MODE (log directory, summary) gets
#                      +wget and +provider, e.g. full+wget+provider.
# With --after-startup SB_TEST_MIN_FREE_GB defaults to 5, not 25: the install has
# already used the space, and a repeat that rebuilds nothing needs little.
set -Euo pipefail

SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=candidate-lib.sh
source "$SELF_DIR/candidate-lib.sh"

SCENARIO=full; CHECK_ONLY=0; AFTER_STARTUP=0
while (( $# )); do
    case "$1" in
        --check) CHECK_ONLY=1; shift ;;
        --after-startup) AFTER_STARTUP=1; shift ;;
        --scenario) (( $# >= 2 )) || { echo "--scenario requires a value" >&2; exit 2; }; SCENARIO="$2"; shift 2 ;;
        *) echo "usage: bash $0 [--after-startup] [--check] [--scenario full|minimal|ml]" >&2; exit 2 ;;
    esac
done
case "$SCENARIO" in
    full)    PLAN=provision-plan.full.example.sh; DOC=README.md;          HEADING='## How to use' ;;
    minimal) PLAN=provision-plan.example.sh;      DOC=docs/QUICKSTART.md; HEADING='### Foundation-only install' ;;
    ml)      PLAN=provision-plan.ml.example.sh;   DOC=docs/ML-PROFILE.md; HEADING='## One-command install' ;;
    *) echo "unknown scenario: $SCENARIO" >&2; exit 2 ;;
esac
WANT_ML=1; [[ "$SCENARIO" == minimal ]] && WANT_ML=0

HEAD_SHA="${SB_CAND_SHA:?SB_CAND_SHA is required}"
EXPECT_SUMS_SHA="${SB_CAND_SUMS_SHA:?SB_CAND_SUMS_SHA is required}"
[[ "$HEAD_SHA" =~ ^[0-9a-f]{40}$ ]] || { echo "SB_CAND_SHA must be a full commit" >&2; exit 2; }
PUBLIC_TGZ_SHA="${SB_PUBLIC_TGZ_SHA:-}"
EXPECT_GPU="${SB_EXPECT_GPU:-0}"
CAND="${SB_CANDIDATE_DIR:-/root/sb-candidate}"
PORT="${SB_TEST_PORT:-18230}"
MIN_FREE_GB="${SB_TEST_MIN_FREE_GB:-$(( AFTER_STARTUP ? 5 : 25 ))}"
STARTUP_STATUS="${SB_STARTUP_STATUS:-/root/sb-startup-status}"
STARTUP_SCRIPT="${SB_STARTUP_SCRIPT:-}"
STARTUP_SCRIPT_SHA="${SB_STARTUP_SCRIPT_SHA:-}"
PREINSTALL_WGET="${SB_TEST_PREINSTALL_WGET:-0}"
CONTENTION="${SB_TEST_CONTENTION:-}"
[[ "$PREINSTALL_WGET" == 0 || "$PREINSTALL_WGET" == 1 ]] || { echo "SB_TEST_PREINSTALL_WGET must be 0 or 1" >&2; exit 2; }
[[ -z "$CONTENTION" || "$CONTENTION" == provider ]] || { echo "SB_TEST_CONTENTION must be empty or provider" >&2; exit 2; }
if (( AFTER_STARTUP )) && [[ "$PREINSTALL_WGET" == 1 || -n "$CONTENTION" ]]; then
    echo "SB_TEST_PREINSTALL_WGET and SB_TEST_CONTENTION do not apply to --after-startup" >&2; exit 2
fi
MODE="$SCENARIO"
[[ "$PREINSTALL_WGET" == 1 ]] && MODE+="+wget"
[[ -n "$CONTENTION" ]] && MODE+="+$CONTENTION"
(( AFTER_STARTUP )) && MODE="after-startup-$SCENARIO"
(( CHECK_ONLY )) && MODE="check-$MODE"
FIRST_PASS=after-install; (( AFTER_STARTUP )) && FIRST_PASS=after-startup

[[ -d "$CAND" ]] || { echo "STOP: $CAND not found; it must hold the candidate files" >&2; exit 1; }
LOGDIR="$CAND/logs/$(date -u +%Y%m%dT%H%M%SZ)-$MODE"
mkdir -p "$LOGDIR" || { echo "STOP: cannot create $LOGDIR" >&2; exit 1; }
# Keep the original streams so EXIT can close both writers to tee and wait for
# its EOF. A container's PID 1 must not exit while the final result is buffered.
exec {LOG_STDOUT}>&1 {LOG_STDERR}>&2
exec > >(tee -a "$LOGDIR/test.log") 2>&1
LOG_PID=$!

SUMMARY=(); FAILED=0
stage() { printf '\n=== [%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
note()  { printf '    %s\n' "$*"; }
result() {
    SUMMARY+=("$(printf '%-5s %s' "$1" "$2")"); printf '    -> %s: %s\n' "$1" "$2"
    [[ "$1" == FAIL || "$1" == STOP ]] && FAILED=1
    return 0
}
finish() {
    printf '\n=== Summary (candidate %s, scenario %s, %s)\n' "$HEAD_SHA" "$MODE" "$(uname -m)"
    printf '    %s\n' "${SUMMARY[@]}"
    printf '    totals: %s passed, %s failed or stopped\n' \
        "$(printf '%s\n' "${SUMMARY[@]}" | grep -c '^PASS')" "$(printf '%s\n' "${SUMMARY[@]}" | grep -cE '^(FAIL|STOP)')"
    printf '    logs: %s\n' "$LOGDIR"
    if (( FAILED )); then printf '    RESULT: FAILED\n'; exit 1; fi
    printf '    RESULT: PASSED\n'; exit 0
}
stop() { result STOP "$*"; printf '\nSTOPPED before the next stage.\n'; finish; }

HTTP_PID=""
cleanup() {
    local code=$? logger_code=0
    trap - EXIT
    if [[ -n "$HTTP_PID" ]]; then
        kill "$HTTP_PID" 2>/dev/null || true
        wait "$HTTP_PID" 2>/dev/null || true
    fi
    exec 1>&"$LOG_STDOUT" 2>&"$LOG_STDERR"
    exec {LOG_STDOUT}>&- {LOG_STDERR}>&-
    wait "$LOG_PID" || logger_code=$?
    if (( logger_code != 0 )); then
        printf 'ERROR: candidate log writer failed (exit %s)\n' "$logger_code" >&2
        (( code != 0 )) || code=$logger_code
    fi
    exit "$code"
}
trap cleanup EXIT

# --- 1. Host checks: read-only ------------------------------------------------
stage "1/8 Host checks (read-only)"
. /etc/os-release 2>/dev/null || true
arch="$(uname -m)"; dpkg_arch="$(dpkg --print-architecture 2>/dev/null || echo none)"
note "OS: ${PRETTY_NAME:-unknown}   arch: $arch / dpkg $dpkg_arch   kernel: $(uname -r)"
note "virtualization: $(systemd-detect-virt 2>/dev/null || echo unknown)   CPUs: $(nproc)   RAM: $(awk '/MemTotal/ {printf "%.1f GB", $2/1048576}' /proc/meminfo 2>/dev/null)"
note "CPU: $(awk -F: '/^(model name|CPU part|Hardware)/ {print $2; exit}' /proc/cpuinfo 2>/dev/null | sed 's/^ *//')"
(( EUID == 0 )) || stop "not root; run as root, as the documented block assumes"
[[ "${ID:-}" == ubuntu && "${VERSION_ID:-}" == 24.04 ]] || stop "unsupported OS: ${PRETTY_NAME:-unknown}; needs Ubuntu 24.04"
case "$arch/$dpkg_arch" in
    x86_64/amd64|aarch64/arm64) ;;
    *) stop "unsupported architecture: $arch/$dpkg_arch" ;;
esac
result PASS "Ubuntu 24.04 $arch, root, scenario $SCENARIO"

gpu=""
command -v nvidia-smi >/dev/null 2>&1 && gpu+="nvidia-smi "
compgen -G '/dev/nvidia*' >/dev/null && gpu+="/dev/nvidia* "
[[ -e /proc/driver/nvidia ]] && gpu+="/proc/driver/nvidia "
for dev in /sys/bus/pci/devices/*; do
    [[ "$(cat "$dev/vendor" 2>/dev/null)" == 0x10de && "$(cat "$dev/class" 2>/dev/null)" == 0x03* ]] \
        && gpu+="pci:${dev##*/} "
done
if [[ "$EXPECT_GPU" == 1 ]]; then
    [[ -n "$gpu" ]] || stop "SB_EXPECT_GPU=1 but no NVIDIA GPU is visible"
    note "NVIDIA GPU visible (${gpu% })"
    note "$(nvidia-smi --query-gpu=name,driver_version,compute_cap --format=csv,noheader 2>/dev/null | head -n1)"
    sb_nvidia_fingerprint > "$LOGDIR/nvidia-before.txt" || stop "cannot record working NVIDIA driver state"
    result PASS "GPU host run: --backend auto must take its CUDA path"
elif [[ -z "$gpu" ]]; then
    result PASS "no NVIDIA GPU visible: this is a CPU-host run"
else
    stop "NVIDIA GPU visible (${gpu% }) on a CPU-host run; set SB_EXPECT_GPU=1 for a GPU host"
fi

missing=""
for c in bash apt-get dpkg sha256sum chmod perl tar gzip awk sed diff grep stat find xargs \
         readlink df timeout sort wc tee flock cmp; do
    command -v "$c" >/dev/null 2>&1 || missing+="$c "
done
[[ -z "$missing" ]] || stop "missing command(s): ${missing% }"
result PASS "every command this test needs is present"

free_target=/; [[ -d /workspace ]] && free_target=/workspace
free_gb="$(df -Pk "$free_target" 2>/dev/null | awk 'NR==2 {print int($4/1048576)}')"
note "free space on $free_target: ${free_gb:-unknown} GB (test needs ${MIN_FREE_GB} GB)"
[[ "$free_gb" =~ ^[0-9]+$ ]] || stop "cannot read free space on $free_target"
(( free_gb >= MIN_FREE_GB )) || stop "only ${free_gb} GB free on $free_target"
result PASS "${free_gb} GB free"

if (( AFTER_STARTUP )); then
# The install was done at boot by the startup script, so the host is not clean;
# what matters is that the script said it finished successfully.
sb_startup_status "$STARTUP_STATUS" || stop "startup status is missing or is not exactly exit=0"
[[ -n "$STARTUP_SCRIPT" ]] || stop "SB_STARTUP_SCRIPT is required for stored-script verification"
result PASS "startup script finished: exit=0 ($STARTUP_STATUS)"
provider_status="$(dpkg-query -W -f='${Status}' openssh-server 2>/dev/null || true)"
sb_provider_history /var/log/apt/history.log "$provider_status" \
    || stop "provider openssh-server transaction is incomplete, failed, or not installed"
[[ -z "$(dpkg --audit)" ]] || stop "dpkg reports unfinished package configuration"
result PASS "provider openssh-server transaction has End-Date, no Error, and installed status"
if [[ "$EXPECT_GPU" == 1 ]]; then
    : > "$LOGDIR/apt-complete-history.txt"
    for history in /var/log/apt/history.log*; do
        [[ -f "$history" ]] || continue
        if [[ "$history" == *.gz ]]; then gzip -cd -- "$history"
        else cat -- "$history"; fi
        printf '\n'
    done > "$LOGDIR/apt-complete-history.txt"
    [[ -s "$LOGDIR/apt-complete-history.txt" ]] || stop "apt history is missing"
    sb_no_driver_changes "$LOGDIR/apt-complete-history.txt" || stop "apt history records NVIDIA/CUDA package changes"
    result PASS "full apt history records no NVIDIA/CUDA package changes; driver is working"
fi
newest_log="$(find /workspace/startup-logs -type f -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -n1 | cut -d' ' -f2-)"
note "newest startup log: ${newest_log:-none in /workspace/startup-logs}"
dups="$(compgen -G '/root/*.1' | tr '\n' ' ')"
note "wget duplicates (/root/*.1): ${dups:-none}"
else
# Earlier server-bootstrap state, tools it would replace, and user files it would
# change. Any one of them stops the test before it changes anything.
found=""
for p in /usr/local/lib/server-bootstrap /usr/local/bin/server-bootstrap /usr/local/bin/server-profile \
         /usr/local/bin/ml-status /usr/local/bin/gh /usr/local/bin/uv /usr/local/bin/node \
         /usr/local/bin/ngrok /usr/local/bin/claude /usr/local/bin/codex /usr/local/bin/pi \
         /usr/local/bin/base-python /workspace/.setup-state /workspace/startup-logs /workspace/venvs \
         /opt/ai-cli /opt/nodejs /root/.oh-my-zsh /root/.zshrc /root/.config/zsh \
         /root/.config/server-bootstrap /root/.pi /root/server-provision.sh /root/"$PLAN"; do
    [[ -e "$p" || -L "$p" ]] && found+="$p "
done
compgen -G '/root/server-bootstrap-*' >/dev/null && found+="/root/server-bootstrap-* "
[[ -z "$found" ]] || stop "not a clean host, or files the install would change exist: ${found% }"
fi
note "wget: $(command -v wget >/dev/null 2>&1 && echo present || echo absent)   CA bundle: $([[ -s /etc/ssl/certs/ca-certificates.crt ]] && echo present || echo absent)"
(( AFTER_STARTUP )) || result PASS "no earlier installation, and no file the install would change"

net_ok=1
for target in archive.ubuntu.com:80 ports.ubuntu.com:80 github.com:443 nodejs.org:443 registry.npmjs.org:443 \
              pypi.org:443 files.pythonhosted.org:443 download.pytorch.org:443 ngrok-agent.s3.amazonaws.com:443; do
    [[ "$target" == archive.ubuntu.com:80 && "$arch" == aarch64 ]] && continue
    [[ "$target" == ports.ubuntu.com:80 && "$arch" == x86_64 ]] && continue
    if timeout 15 bash -c "exec 3<>/dev/tcp/${target%:*}/${target#*:}" 2>/dev/null; then note "reachable: $target"
    else note "NOT reachable: $target"; net_ok=0; fi
done
(( net_ok )) || stop "the install needs these official download hosts"
result PASS "download hosts reachable"

# --- 2. Candidate verification: nothing from the candidate runs before this ---
stage "2/8 Verify the candidate files in $CAND"
cd "$CAND" || stop "cannot enter $CAND"
got="$(sha256sum SHA256SUMS 2>/dev/null | awk '{print $1}')"
[[ "$got" == "$EXPECT_SUMS_SHA" ]] || stop "SHA256SUMS is ${got:-missing}, not the recorded $EXPECT_SUMS_SHA"
note "SHA256SUMS matches the recorded sha256 $got"
sb_candidate_manifest "$CAND" "$EXPECT_SUMS_SHA" | sed 's/^/    /' || stop "candidate manifest or file verification failed"
mapfile -t tgzs < <(awk '$2 ~ /^server-bootstrap-[0-9]+\.[0-9]+\.[0-9]+\.tar\.gz$/ {print $2}' SHA256SUMS)
(( ${#tgzs[@]} == 1 )) || stop "expected exactly one server-bootstrap-<version>.tar.gz in SHA256SUMS, found ${#tgzs[@]}"
TGZ="${tgzs[0]}"; V="${TGZ#server-bootstrap-}"; V="${V%.tar.gz}"
BLOCK_FILES=(server-provision.sh "$PLAN" "$TGZ" "$TGZ.sha256")
for f in "${BLOCK_FILES[@]}"; do
    [[ "$(awk -v f="$f" '$2 == f' SHA256SUMS | grep -c .)" == 1 ]] || stop "SHA256SUMS does not list $f exactly once"
done
sha256sum -c "$TGZ.sha256" || stop "the archive does not match its sidecar"
tgz_sha="$(sha256sum "$TGZ" | awk '{print $1}')"
[[ -z "$PUBLIC_TGZ_SHA" || "$tgz_sha" != "$PUBLIC_TGZ_SHA" ]] || stop "this is the PUBLISHED archive, not the candidate"
tar -xzf "$TGZ" -O "server-bootstrap-$V/VERSION" > "$LOGDIR/VERSION" 2>/dev/null || stop "VERSION missing from the archive"
[[ "$(tr -d '[:space:]' < "$LOGDIR/VERSION")" == "$V" ]] || stop "the archive's VERSION is not $V"
LOCK_BACKEND=cpu; [[ "$EXPECT_GPU" == 1 ]] && LOCK_BACKEND=cu130
LOCK="profiles/ml/locks/$LOCK_BACKEND-$arch.txt"
for f in "$DOC" lib/bootstrap/config.sh lib/bootstrap/packages.sh "examples/$PLAN" "$LOCK"; do
    mkdir -p "$LOGDIR/archive/$(dirname "$f")"
    tar -xzf "$TGZ" -O "server-bootstrap-$V/$f" > "$LOGDIR/archive/$f" 2>/dev/null || stop "$f missing from the archive"
done
cmp -s "$PLAN" "$LOGDIR/archive/examples/$PLAN" || stop "the standalone $PLAN differs from the archive's copy"
result PASS "candidate $HEAD_SHA verified: version $V, archive sha256 $tgz_sha"
if (( AFTER_STARTUP )); then
    # What the startup script downloaded into /root must be the frozen candidate files.
    # The foundation-only plan deletes the archive and its sidecar after success.
    cmp_files=("${BLOCK_FILES[@]}")
    if [[ "$SCENARIO" == minimal ]]; then
        cmp_files=(server-provision.sh "$PLAN")
        if [[ -e "/root/$TGZ" || -e "/root/$TGZ.sha256" ]]; then
            result FAIL "the foundation-only plan kept /root/$TGZ or its .sha256; it should delete both"
        else result PASS "the foundation-only plan deleted the archive after success"; fi
    fi
    for f in "${cmp_files[@]}"; do
        [[ -f "/root/$f" ]] || stop "/root/$f is missing; the startup script should have downloaded it"
        cmp -s "/root/$f" "$CAND/$f" || stop "/root/$f differs from the frozen candidate file"
        note "/root/$f sha256 $(sha256sum "/root/$f" | awk '{print $1}')"
    done
    result PASS "the files the startup script downloaded into /root are the frozen candidate files"
fi

# Pins come from the verified archive itself, so the checks follow the candidate.
pin() { sed -nE "s/.*\b$1=\"\\\$\{$1:-([^}]*)\}\".*/\1/p" "$LOGDIR/archive/lib/bootstrap/config.sh" | head -n1; }
NODE_V="$(pin NODE_VERSION)"; UV_V="$(pin UV_VERSION)"; GH_V="$(pin GH_VERSION)"; NGROK_V="$(pin NGROK_VERSION)"
CLAUDE_V="$(pin CLAUDE_CODE_VERSION)"; CODEX_V="$(pin CODEX_VERSION)"; PI_V="$(pin PI_VERSION)"
note "pins in the archive: node $NODE_V, uv $UV_V, gh $GH_V, ngrok $NGROK_V, claude-code $CLAUDE_V, codex $CODEX_V, pi $PI_V"
for x in "$NODE_V" "$UV_V" "$GH_V" "$NGROK_V" "$CLAUDE_V" "$CODEX_V" "$PI_V"; do
    [[ "$x" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || stop "could not read every pin from the archive's config.sh"
done

# --- 3. The documented block on a loopback test URL ---------------------------
if (( AFTER_STARTUP )); then stage "3/8 $DOC \"$HEADING\" block, against the startup script"
else stage "3/8 $DOC \"$HEADING\" block, BASE pointed at a loopback test URL"; fi
awk -v h="$HEADING" '$0 == h {s=1; next} s && /^```bash$/ {b=1; next} b && /^```$/ {exit} b' "$LOGDIR/archive/$DOC" \
    > "$LOGDIR/block.original.sh"
[[ -s "$LOGDIR/block.original.sh" ]] || stop "no bash block under \"$HEADING\" in $DOC"
[[ "$(grep -c '^BASE=' "$LOGDIR/block.original.sh")" == 1 ]] || stop "expected exactly one BASE= line in the block"
grep -qxF "V=$V" "$LOGDIR/block.original.sh" || stop "the block does not set V=$V"
grep -qF "\$BASE/$PLAN\"" "$LOGDIR/block.original.sh" || stop "the block does not download $PLAN"
if (( AFTER_STARTUP )); then
    # The block carries the literal text v$V; the startup script runs it as it is.
    grep -qxF 'BASE=https://github.com/evya1/server-bootstrap/releases/download/v$V' "$LOGDIR/block.original.sh" \
        || stop "the block's BASE= line is not the real release URL"
    note "block from the verified archive:"
    sed 's/^/      | /' "$LOGDIR/block.original.sh"
    bash -n "$LOGDIR/block.original.sh" || stop "the block is not valid Bash"
    sb_startup_identity "$LOGDIR/block.original.sh" "$STARTUP_SCRIPT" "$STARTUP_SCRIPT_SHA" \
        || stop "stored startup script differs from the approved documented payload"
    note "stored startup script sha256: $(sha256sum "$STARTUP_SCRIPT" | cut -d' ' -f1)"
    result PASS "stored startup script matches the approved payload; wrapper content withheld"
    (( CHECK_ONLY )) && finish
    # No loopback server here: the startup script used the real release URL.
else
(( CHECK_ONLY )) && finish
sed "s|^BASE=.*|BASE=http://127.0.0.1:$PORT|" "$LOGDIR/block.original.sh" > "$LOGDIR/block.test.sh"
diff "$LOGDIR/block.original.sh" "$LOGDIR/block.test.sh" > "$LOGDIR/block.diff" || [[ "$?" == 1 ]] || stop "block comparison failed"
[[ "$(grep -c '^[<>]' "$LOGDIR/block.diff")" == 2 ]] || stop "the test block differs by more than the BASE line"
note "block from the verified archive (the only change is BASE):"
sed 's/^/      | /' "$LOGDIR/block.original.sh"
bash -n "$LOGDIR/block.test.sh" || stop "the test block is not valid Bash"
mkdir -p "$CAND/serve" && for f in "${BLOCK_FILES[@]}"; do cp -p -- "$f" "$CAND/serve/$f"; done
# perl-base is the one scripting runtime a bare image ships; this serves the
# four verified files, and nothing else, on 127.0.0.1 only.
cat > "$LOGDIR/serve.pl" <<'PERL'
use strict; use warnings; use IO::Socket::INET;
my ($port, $dir) = @ARGV;
my $s = IO::Socket::INET->new(LocalAddr => "127.0.0.1", LocalPort => $port, Listen => 5, ReuseAddr => 1)
    or die "listen on 127.0.0.1:$port: $!\n";
while (my $c = $s->accept) {
    binmode $c; my $req = <$c> // "";
    while (my $l = <$c>) { last if $l =~ /^\r?\n$/ }
    my ($m, $p) = $req =~ m{^(GET|HEAD) /([A-Za-z0-9._-]+) HTTP/};
    my $f = defined $p ? "$dir/$p" : "";
    if ($m && -f $f && open(my $fh, "<:raw", $f)) {
        printf $c "HTTP/1.0 200 OK\r\nContent-Length: %d\r\nConnection: close\r\n\r\n", -s $f;
        if ($m eq "GET") { local $/ = \65536; while (my $b = <$fh>) { print $c $b } }
        close $fh; print STDERR "200 $m $p\n";
    } else {
        print $c "HTTP/1.0 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
        print STDERR "404 ", ($p // "?"), "\n";
    }
    close $c;
}
PERL
perl "$LOGDIR/serve.pl" "$PORT" "$CAND/serve" > "$LOGDIR/http.log" 2>&1 &
HTTP_PID=$!
for _ in $(seq 1 20); do (exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null && break; sleep 0.5; done
(exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null || stop "the loopback test URL did not come up"
result PASS "block extracted, BASE rewritten, served on 127.0.0.1:$PORT"
fi

# --- 4. First install ---------------------------------------------------------
if (( AFTER_STARTUP )); then
stage "4/8 First install: done at boot by the startup script"
result PASS "first install: run by the startup script at boot (exit=0)"
else
stage "4/8 Run the block (first install)"
if [[ "$PREINSTALL_WGET" == 1 ]]; then
    note "SB_TEST_PREINSTALL_WGET=1: installing wget and ca-certificates first; the block's wget guard will be skipped"
    ( apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends wget ca-certificates ) \
        > "$LOGDIR/preinstall-wget.log" 2>&1 || stop "pre-installing wget failed; see $LOGDIR/preinstall-wget.log"
    note "wget: $(command -v wget >/dev/null 2>&1 && echo present || echo absent)"
fi
PROVIDER_PID=""
if [[ "$CONTENTION" == provider ]]; then
    note "SB_TEST_CONTENTION=provider: starting a provider-style entrypoint (apt update, then apt install) in the background, then the block"
    # The hook runs inside a real apt transaction, with its frontend lock held.
    # It releases only after the installer has actually observed contention.
    cat > "$LOGDIR/provider-hook.sh" <<'HOOK'
#!/usr/bin/env bash
set -eu
source "$SB_PROVIDER_HELPERS"
: > "$SB_PROVIDER_EVIDENCE/provider-ready"
for (( attempt=0; attempt<120; attempt++ )); do
    if sb_apt_contention_observed "$SB_PROVIDER_EVIDENCE/install-1.log" 2>/dev/null; then
        : > "$SB_PROVIDER_EVIDENCE/provider-overlap"
        exit 0
    fi
    sleep 1
done
printf '%s\n' 'installer did not observe the provider apt lock' >&2
exit 1
HOOK
    export SB_PROVIDER_EVIDENCE="$LOGDIR"
    export SB_PROVIDER_HELPERS="$SELF_DIR/candidate-lib.sh"
    (
        apt-get update &&
        DEBIAN_FRONTEND=noninteractive apt-get -o "DPkg::Pre-Invoke::=bash $LOGDIR/provider-hook.sh" \
            install -y --no-install-recommends xz-utils nano htop openssh-server
    ) > "$LOGDIR/provider.log" 2>&1 &
    PROVIDER_PID=$!
    for (( attempt=0; attempt<300; attempt++ )); do
        [[ ! -f "$LOGDIR/provider-ready" ]] || break
        kill -0 "$PROVIDER_PID" 2>/dev/null || stop "provider apt exited before taking its installation lock"
        sleep 1
    done
    [[ -f "$LOGDIR/provider-ready" ]] || stop "provider apt never reached its locked installation phase"
    # Query kernel fcntl locks, not a PID's mere existence or an open lock file.
    source "$LOGDIR/archive/lib/bootstrap/packages.sh"
    bootstrap_apt_lock_holders > "$LOGDIR/provider-locks.txt"
    grep -qE '\(apt-get\) holds /var/lib/dpkg/lock-frontend$' "$LOGDIR/provider-locks.txt" \
        || stop "the provider apt process is not holding the frontend lock"
    result PASS "observed real provider apt frontend lock before starting installation"
fi
t0=$SECONDS
# Capture the actual exit status immediately after the documented block.
( cat "$LOGDIR/block.test.sh"; printf '%s\n' 'echo "exit=$?" > /root/sb-startup-status' ) > "$LOGDIR/startup.executed.sh"
( cd /root && bash "$LOGDIR/startup.executed.sh" ) 2>&1 | tee "$LOGDIR/install-1.log"
code=${PIPESTATUS[0]}
note "exit $code after $(( (SECONDS - t0) / 60 )) min; files served: $(grep -c '^200 GET' "$LOGDIR/http.log")"
kill "$HTTP_PID" 2>/dev/null; HTTP_PID=""
if [[ -n "$PROVIDER_PID" ]]; then
    wait "$PROVIDER_PID"; pcode=$?
    note "provider-style job exit $pcode; output: $LOGDIR/provider.log"
    sed 's/^/      | /' "$LOGDIR/provider.log" | tail -n 15
    pstat="$(dpkg-query -W -f='${Status}' openssh-server 2>/dev/null || echo missing)"
    # The provider's transaction: the newest history.log record whose command line installs openssh-server.
    ptx="$(awk 'BEGIN {RS=""; ORS="\n\n"} /Commandline:[^\n]*openssh-server/ {r=$0} END {print r}' /var/log/apt/history.log 2>/dev/null)"
    note "openssh-server status: $pstat"
    note "provider transaction in history.log: ${ptx:-none}"
    if sb_provider_transaction /var/log/apt/history.log "$pstat" "$pcode" && [[ -f "$LOGDIR/provider-overlap" ]]; then
        for package in xz-utils nano htop openssh-server; do
            [[ "$(dpkg-query -W -f='${Status}' "$package" 2>/dev/null)" == 'install ok installed' ]] \
                || stop "provider package did not finish installation: $package"
        done
        [[ -z "$(dpkg --audit)" ]] || stop "provider left unfinished package configuration"
        result PASS "observed apt contention and an intact provider openssh-server transaction"
    else
        result FAIL "provider install or observed contention failed; see provider.log"
    fi
fi
(( code == 0 )) || stop "first install failed (exit $code); see $LOGDIR/install-1.log and /workspace/startup-logs"
sb_startup_status /root/sb-startup-status || stop "the documented block returned a failure status"
sb_startup_identity "$LOGDIR/block.test.sh" "$LOGDIR/startup.executed.sh" || stop "executed startup script changed"
result PASS "first install succeeded with actual exit=0 and exact stored script identity"
fi
if [[ "$EXPECT_GPU" == 1 ]]; then
    sb_nvidia_fingerprint > "$LOGDIR/nvidia-after-install.txt" || stop "NVIDIA driver stopped working"
    cmp -s "$LOGDIR/nvidia-before.txt" "$LOGDIR/nvidia-after-install.txt" || stop "installation changed NVIDIA driver state"
    result PASS "NVIDIA driver identity and installed driver packages are unchanged"
fi

# --- 5. Stack checks ----------------------------------------------------------
stack_checks() {  # pass label
    local pass="$1"
    stack_fail=0; stack_n=0
    check() {  # label, command run in a login shell; a pipeline fails if any part fails
        local label="$1" cmd="$2" out rc
        stack_n=$((stack_n + 1))
        out="$(bash -lc "set -o pipefail; $cmd" 2>&1 < /dev/null)"; rc=$?
        printf '\n--- %s (exit %s)\n$ %s\n%s\n' "$label" "$rc" "$cmd" "$out" >> "$LOGDIR/stack-checks-$pass.log"
        if (( rc == 0 )); then note "PASS  $label: $(head -n1 <<< "$out")"
        else note "FAIL  $label (exit $rc): $(tail -n1 <<< "$out")"; stack_fail=$((stack_fail + 1)); fi
    }
    check "rclone"               "rclone version | head -n1"
    check "ngrok $NGROK_V"       "test \"\$(ngrok version)\" = 'ngrok version $NGROK_V' && ngrok version"
    check "gh $GH_V"             "gh --version | head -n1 | grep -F 'gh version $GH_V '"
    check "node $NODE_V"         "test \"\$(node --version)\" = v$NODE_V && node --version"
    check "uv $UV_V"             "test \"\$(uv --version | cut -d' ' -f2)\" = $UV_V && uv --version"
    check "claude-code $CLAUDE_V" "test \"\$(claude --version | cut -d' ' -f1)\" = $CLAUDE_V && claude --version"
    check "codex $CODEX_V"       "test \"\$(codex --version)\" = 'codex-cli $CODEX_V' && codex --version"
    check "pi $PI_V"             "command -v pi && test \"\$(node -p \"require('/opt/ai-cli/lib/node_modules/@earendil-works/pi-coding-agent/package.json').version\")\" = $PI_V"
    check "pi --version runs"    "test \"\$(PI_SKIP_VERSION_CHECK=1 timeout 60 pi --version)\" = $PI_V && echo $PI_V"
    check "zsh / Oh My Zsh"      "zsh --version && test -d /root/.oh-my-zsh"
    check "base-python numpy"    "base-python -c 'import sys, numpy; assert sys.prefix != sys.base_prefix, \"system interpreter: \" + sys.prefix; print(sys.prefix, \"numpy\", numpy.__version__)'"
    local c
    for c in server-bootstrap server-provision server-accept server-profile server-secrets \
             server-bundle-install server-vscode-extensions; do
        check "command $c" "command -v $c"
    done
    if (( WANT_ML )); then
        for c in ml-env ml-status ml-doctor ml-preflight ml-jupyter; do
            check "command $c" "command -v $c"
        done
        if [[ "$EXPECT_GPU" == 1 ]]; then
            check "ml backend is CUDA" "test \"\$(cat /workspace/.setup-state/profiles/ml/backend)\" = cu130 && echo cu130"
        else
            check "ml backend is cpu" "test \"\$(cat /workspace/.setup-state/profiles/ml/backend)\" = cpu && echo cpu"
        fi
        check "ml-status"         "ml-status"
        check "ml-preflight"      "ml-preflight"
        local gpu_flag=""
        [[ "$EXPECT_GPU" == 1 ]] && gpu_flag=--gpu
        check "ml-doctor and exact lock versions" "ml-doctor --json > '$LOGDIR/doctor-$pass.json' && ml-env python '$SELF_DIR/check-installed.py' --doctor '$LOGDIR/doctor-$pass.json' --lock '$LOGDIR/archive/$LOCK' $gpu_flag"
        check "kernel discovery"  "ml-env jupyter kernelspec list"
        check "CPU tensor op"     "ml-env python -c 'import platform, torch; torch.manual_seed(0); a = torch.randn(256, 256); b = a @ a.T; assert torch.isfinite(b).all() and torch.allclose(b, b.T, atol=1e-4); print(\"torch\", torch.__version__, platform.machine(), \"cpu tensor ok\", tuple(b.shape))'"
        if [[ "$EXPECT_GPU" == 1 ]]; then
            check "CUDA tensor op" "ml-env python -c 'import torch; assert torch.cuda.is_available(); d = torch.device(\"cuda\"); x = torch.empty(64 * 2**20, dtype=torch.float32, device=d); torch.manual_seed(0); a = torch.randn(1024, 1024); g = (a.to(d) @ a.to(d).T).cpu(); assert torch.allclose(g, a @ a.T, rtol=1e-3, atol=1e-2); print(torch.cuda.get_device_name(0), \"cuda\", torch.version.cuda, \"256 MiB alloc + matmul ok\")'"
        fi
    else
        check "no ml commands"    "for c in ml-env ml-status ml-doctor ml-preflight ml-jupyter; do if command -v \$c; then exit 1; fi; done; echo absent"
        check "no ml environment or state" "test ! -e /workspace/.setup-state/profiles/ml && test ! -e /workspace/venvs/ml-workbench && test ! -e /workspace/venvs/.ml-workbench && echo absent"
    fi
    local expected_checks=20
    if (( WANT_ML )); then expected_checks=29; [[ "$EXPECT_GPU" == 1 ]] && expected_checks=30; fi
    if (( stack_n != expected_checks )); then
        result FAIL "stack check count changed: $stack_n, expected $expected_checks"
    fi
    if (( stack_fail == 0 )); then result PASS "all $stack_n stack checks, $pass (details: stack-checks-$pass.log)"
    else result FAIL "$stack_fail of $stack_n stack checks, $pass; see $LOGDIR/stack-checks-$pass.log"; fi
}
stage "5/8 Check the installed stack (login shell)"
stack_checks "$FIRST_PASS"

# --- 6. Repeat ----------------------------------------------------------------
fingerprint() {  # built and downloaded tools, the ml environment and apt, then recorded state
    local p
    echo "## installed files (inode, mtime, size)"
    for p in /usr/local/bin/ngrok /usr/local/bin/gh /usr/local/bin/uv /usr/bin/rclone \
             "$(readlink -f /usr/local/bin/node 2>/dev/null)" \
             /workspace/venvs/base-python/pyvenv.cfg /root/.oh-my-zsh/oh-my-zsh.sh \
             $(find /opt/ai-cli/lib/node_modules -mindepth 2 -maxdepth 3 -name package.json \
                   -not -path '*/node_modules/*/node_modules/*' 2>/dev/null | sort); do
        [[ -n "$p" && -e "$p" ]] && stat -c '%n inode=%i mtime=%Y size=%s' "$p"
    done
    # The base-python launcher is a 72-byte script each run renames into place;
    # identical content is what "unchanged" means for it.
    printf 'base-python launcher sha256 %s\n' "$(sha256sum < /usr/local/bin/base-python 2>/dev/null | cut -d' ' -f1)"
    echo "## ml environment build"
    printf 'ml-workbench -> %s\n' "$(readlink -f /workspace/venvs/ml-workbench 2>/dev/null)"
    stat -c '%n inode=%i mtime=%Y' /workspace/venvs/ml-workbench/pyvenv.cfg 2>/dev/null
    echo "## apt"
    printf 'apt transactions: %s\n' "$(grep -c '^Start-Date' /var/log/apt/history.log 2>/dev/null || echo 0)"
    echo "## recorded state"
    # These two files intentionally record the latest attempt time. All other
    # state, including the ML installed-at value, must remain byte-identical.
    find /workspace/.setup-state -type f \
        ! -path /workspace/.setup-state/bootstrap-complete \
        ! -path /workspace/.setup-state/vscode-extensions-last-attempt -print0 2>/dev/null | sort -z | xargs -0r sha256sum
    echo "## NVIDIA drivers"
    [[ "$EXPECT_GPU" != 1 ]] || sb_nvidia_fingerprint
}
stage "6/8 Repeat the identical plan from /root"
cd /root || stop "cannot enter /root"
if [[ "$SCENARIO" == minimal ]]; then
    # The foundation-only plan deletes the archive after a successful run, as its
    # section says. A repeat needs it back: restore the verified candidate copies.
    if [[ -e "/root/$TGZ" ]]; then result FAIL "the foundation-only plan kept /root/$TGZ; it should delete it"
    else result PASS "the foundation-only plan deleted the archive after success"; fi
    cp -p -- "$CAND/$TGZ" "$CAND/$TGZ.sha256" /root/
fi
for f in "${BLOCK_FILES[@]}"; do cmp -s "/root/$f" "$CAND/$f" || stop "/root/$f is not the verified candidate file"; done
fingerprint > "$LOGDIR/fingerprint-before.txt" || stop "cannot fingerprint the installed state"
apt_before="$(wc -l < /var/log/apt/history.log 2>/dev/null || echo 0)"
t0=$SECONDS
./server-provision.sh --plan "./$PLAN" < /dev/null 2>&1 | tee "$LOGDIR/install-2.log"
code=${PIPESTATUS[0]}
note "exit $code after $(( (SECONDS - t0) / 60 )) min"
fingerprint > "$LOGDIR/fingerprint-after.txt" || stop "cannot fingerprint the repeated state"
if (( code == 0 )); then result PASS "repeat install succeeded"; else result FAIL "repeat install failed (exit $code)"; fi

# --- 7. What the repeat changed -----------------------------------------------
stage "7/8 What the repeat changed"
section() { awk -v s="$1" '/^## / {on = ($0 == "## " s)} on' "$2"; }
rebuilt=0; n=0
for s in "installed files (inode, mtime, size)" "ml environment build" "apt" "NVIDIA drivers"; do
    n=$((n + 1))
    if ! diff <(section "$s" "$LOGDIR/fingerprint-before.txt") <(section "$s" "$LOGDIR/fingerprint-after.txt") \
        > "$LOGDIR/changed-$n.diff"; then
        note "changed by the repeat ($s):"; sed 's/^/      /' "$LOGDIR/changed-$n.diff"; rebuilt=1
    fi
done
if (( rebuilt )); then result FAIL "the repeat rebuilt or reinstalled the items above"
else result PASS "tools, the ml environment build and apt history unchanged by the repeat"; fi
if ! diff <(section "recorded state" "$LOGDIR/fingerprint-before.txt") <(section "recorded state" "$LOGDIR/fingerprint-after.txt") \
    > "$LOGDIR/changed-state.diff"; then
    result FAIL "stable recorded state changed during repeat"; sed 's/^/      /' "$LOGDIR/changed-state.diff"
else
    result PASS "stable recorded state is identical after repeat"
fi
tail -n +"$(( apt_before + 1 ))" /var/log/apt/history.log 2>/dev/null \
    | grep -E '^(Start-Date|Commandline|Install|Upgrade|Remove):' > "$LOGDIR/apt-during-repeat.txt" || true
note "apt during the repeat: $(grep -c '^Start-Date' "$LOGDIR/apt-during-repeat.txt") transaction(s)"

# --- 8. The stack still works after the repeat --------------------------------
stage "8/8 Check the installed stack again, after the repeat"
stack_checks after-repeat
finish
