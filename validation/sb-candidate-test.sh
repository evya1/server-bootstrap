#!/usr/bin/env bash
# Test of a server-bootstrap TEST CANDIDATE (not a release) on a clean Ubuntu
# 24.04 host, x86_64 or aarch64, as root. Exit status: 0 only if every stage
# passed. Generalised from the PR #69 clean-host test.
#
#   bash sb-candidate-test.sh --check [--scenario S]   clean-host checks and candidate
#                                                      verification; changes nothing
#   bash sb-candidate-test.sh [--scenario S]           the gate, then the documented
#                                                      block, stack checks, a repeat,
#                                                      and the stack checks again
#
# Scenarios, each the copyable block exactly as the verified archive ships it,
# with only its BASE line pointed at a loopback copy of the candidate files:
#   full      README.md "## Install"                     provision-plan.full.example.sh
#   minimal   README.md "### Foundation-only install"    provision-plan.example.sh
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
set -Euo pipefail

SCENARIO=full; CHECK_ONLY=0
while (( $# )); do
    case "$1" in
        --check) CHECK_ONLY=1; shift ;;
        --scenario) SCENARIO="${2:-}"; shift 2 ;;
        *) echo "usage: bash $0 [--check] [--scenario full|minimal|ml]" >&2; exit 2 ;;
    esac
done
case "$SCENARIO" in
    full)    PLAN=provision-plan.full.example.sh; DOC=README.md;          HEADING='## Install' ;;
    minimal) PLAN=provision-plan.example.sh;      DOC=README.md;          HEADING='### Foundation-only install' ;;
    ml)      PLAN=provision-plan.ml.example.sh;   DOC=docs/ML-PROFILE.md; HEADING='## One-command install' ;;
    *) echo "unknown scenario: $SCENARIO" >&2; exit 2 ;;
esac
WANT_ML=1; [[ "$SCENARIO" == minimal ]] && WANT_ML=0

HEAD_SHA="${SB_CAND_SHA:?SB_CAND_SHA is required}"
EXPECT_SUMS_SHA="${SB_CAND_SUMS_SHA:?SB_CAND_SUMS_SHA is required}"
PUBLIC_TGZ_SHA="${SB_PUBLIC_TGZ_SHA:-}"
EXPECT_GPU="${SB_EXPECT_GPU:-0}"
CAND="${SB_CANDIDATE_DIR:-/root/sb-candidate}"
PORT="${SB_TEST_PORT:-18230}"
MIN_FREE_GB="${SB_TEST_MIN_FREE_GB:-25}"
MODE="$SCENARIO"; (( CHECK_ONLY )) && MODE="check-$SCENARIO"

[[ -d "$CAND" ]] || { echo "STOP: $CAND not found; it must hold the candidate files" >&2; exit 1; }
LOGDIR="$CAND/logs/$(date -u +%Y%m%dT%H%M%SZ)-$MODE"
mkdir -p "$LOGDIR" || { echo "STOP: cannot create $LOGDIR" >&2; exit 1; }
exec > >(tee -a "$LOGDIR/test.log") 2>&1

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
cleanup() { [[ -z "$HTTP_PID" ]] || kill "$HTTP_PID" 2>/dev/null || true; }
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
note "wget: $(command -v wget >/dev/null 2>&1 && echo present || echo absent)   CA bundle: $([[ -s /etc/ssl/certs/ca-certificates.crt ]] && echo present || echo absent)"
result PASS "no earlier installation, and no file the install would change"

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
sha256sum -c SHA256SUMS | sed 's/^/    /' || stop "a candidate file does not match SHA256SUMS"
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
for f in "$DOC" lib/bootstrap/config.sh "examples/$PLAN"; do
    mkdir -p "$LOGDIR/archive/$(dirname "$f")"
    tar -xzf "$TGZ" -O "server-bootstrap-$V/$f" > "$LOGDIR/archive/$f" 2>/dev/null || stop "$f missing from the archive"
done
cmp -s "$PLAN" "$LOGDIR/archive/examples/$PLAN" || stop "the standalone $PLAN differs from the archive's copy"
result PASS "candidate $HEAD_SHA verified: version $V, archive sha256 $tgz_sha"
(( CHECK_ONLY )) && finish

# Pins come from the verified archive itself, so the checks follow the candidate.
pin() { sed -nE "s/.*\b$1=\"\\\$\{$1:-([^}]*)\}\".*/\1/p" "$LOGDIR/archive/lib/bootstrap/config.sh" | head -n1; }
NODE_V="$(pin NODE_VERSION)"; UV_V="$(pin UV_VERSION)"; GH_V="$(pin GH_VERSION)"; NGROK_V="$(pin NGROK_VERSION)"
CLAUDE_V="$(pin CLAUDE_CODE_VERSION)"; CODEX_V="$(pin CODEX_VERSION)"; PI_V="$(pin PI_VERSION)"
note "pins in the archive: node $NODE_V, uv $UV_V, gh $GH_V, ngrok $NGROK_V, claude-code $CLAUDE_V, codex $CODEX_V, pi $PI_V"
for x in "$NODE_V" "$UV_V" "$GH_V" "$NGROK_V" "$CLAUDE_V" "$CODEX_V" "$PI_V"; do
    [[ "$x" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || stop "could not read every pin from the archive's config.sh"
done

# --- 3. The documented block on a loopback test URL ---------------------------
stage "3/8 $DOC \"$HEADING\" block, BASE pointed at a loopback test URL"
awk -v h="$HEADING" '$0 == h {s=1; next} s && /^```bash$/ {b=1; next} b && /^```$/ {exit} b' "$LOGDIR/archive/$DOC" \
    > "$LOGDIR/block.original.sh"
[[ -s "$LOGDIR/block.original.sh" ]] || stop "no bash block under \"$HEADING\" in $DOC"
[[ "$(grep -c '^BASE=' "$LOGDIR/block.original.sh")" == 1 ]] || stop "expected exactly one BASE= line in the block"
grep -qxF "V=$V" "$LOGDIR/block.original.sh" || stop "the block does not set V=$V"
grep -qF "\$BASE/$PLAN\"" "$LOGDIR/block.original.sh" || stop "the block does not download $PLAN"
sed "s|^BASE=.*|BASE=http://127.0.0.1:$PORT|" "$LOGDIR/block.original.sh" > "$LOGDIR/block.test.sh"
diff "$LOGDIR/block.original.sh" "$LOGDIR/block.test.sh" > "$LOGDIR/block.diff"
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

# --- 4. First install ---------------------------------------------------------
stage "4/8 Run the block (first install)"
t0=$SECONDS
( cd /root && bash "$LOGDIR/block.test.sh" ) 2>&1 | tee "$LOGDIR/install-1.log"
code=${PIPESTATUS[0]}
note "exit $code after $(( (SECONDS - t0) / 60 )) min; files served: $(grep -c '^200 GET' "$LOGDIR/http.log")"
kill "$HTTP_PID" 2>/dev/null; HTTP_PID=""
(( code == 0 )) || stop "first install failed (exit $code); see $LOGDIR/install-1.log and /workspace/startup-logs"
result PASS "first install succeeded"

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
    check "ngrok $NGROK_V"       "ngrok version | grep -F 'version $NGROK_V'"
    check "gh $GH_V"             "gh --version | head -n1 | grep -F 'gh version $GH_V '"
    check "node $NODE_V"         "test \"\$(node --version)\" = v$NODE_V && node --version"
    check "uv $UV_V"             "uv --version | grep -E '^uv $UV_V( |\$)'"
    check "claude-code $CLAUDE_V" "claude --version | grep -F '$CLAUDE_V'"
    check "codex $CODEX_V"       "codex --version | grep -F '$CODEX_V'"
    check "pi $PI_V"             "command -v pi && test \"\$(node -p \"require('/opt/ai-cli/lib/node_modules/@earendil-works/pi-coding-agent/package.json').version\")\" = $PI_V"
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
            check "ml backend is CUDA" "b=\$(cat /workspace/.setup-state/profiles/ml/backend) && [[ \$b == cu* ]] && echo \$b"
        else
            check "ml backend is cpu" "test \"\$(cat /workspace/.setup-state/profiles/ml/backend)\" = cpu && echo cpu"
        fi
        check "ml-status"         "ml-status"
        check "ml-preflight"      "ml-preflight"
        check "ml-doctor"         "ml-doctor"
        check "kernel discovery"  "ml-env jupyter kernelspec list"
        check "CPU tensor op"     "ml-env python -c 'import platform, torch; torch.manual_seed(0); a = torch.randn(256, 256); b = a @ a.T; assert torch.isfinite(b).all() and torch.allclose(b, b.T, atol=1e-4); print(\"torch\", torch.__version__, platform.machine(), \"cpu tensor ok\", tuple(b.shape))'"
        if [[ "$EXPECT_GPU" == 1 ]]; then
            check "CUDA tensor op" "ml-env python -c 'import torch; assert torch.cuda.is_available(); d = torch.device(\"cuda\"); x = torch.empty(64 * 2**20, dtype=torch.float32, device=d); torch.manual_seed(0); a = torch.randn(1024, 1024); g = (a.to(d) @ a.to(d).T).cpu(); assert torch.allclose(g, a @ a.T, rtol=1e-3, atol=1e-2); print(torch.cuda.get_device_name(0), \"cuda\", torch.version.cuda, \"256 MiB alloc + matmul ok\")'"
        fi
    else
        check "no ml command"     "! command -v ml-status && ! command -v ml-env && echo absent"
        check "no ml profile state" "test ! -e /workspace/.setup-state/profiles/ml && echo absent"
    fi
    if (( stack_fail == 0 )); then result PASS "all $stack_n stack checks, $pass (details: stack-checks-$pass.log)"
    else result FAIL "$stack_fail of $stack_n stack checks, $pass; see $LOGDIR/stack-checks-$pass.log"; fi
}
stage "5/8 Check the installed stack (login shell)"
stack_checks after-install

# --- 6. Repeat ----------------------------------------------------------------
fingerprint() {  # built and downloaded tools, the ml environment and apt, then recorded state
    local p
    echo "## installed files (inode, mtime, size)"
    for p in /usr/local/bin/ngrok /usr/local/bin/gh /usr/local/bin/uv /usr/bin/rclone \
             /usr/local/bin/base-python \
             "$(readlink -f /usr/local/bin/node 2>/dev/null)" \
             /workspace/venvs/base-python/pyvenv.cfg /root/.oh-my-zsh/oh-my-zsh.sh \
             $(find /opt/ai-cli/lib/node_modules -mindepth 2 -maxdepth 3 -name package.json \
                   -not -path '*/node_modules/*/node_modules/*' 2>/dev/null | sort); do
        [[ -n "$p" && -e "$p" ]] && stat -c '%n inode=%i mtime=%Y size=%s' "$p"
    done
    echo "## ml environment build"
    printf 'ml-workbench -> %s\n' "$(readlink -f /workspace/venvs/ml-workbench 2>/dev/null)"
    stat -c '%n inode=%i mtime=%Y' /workspace/venvs/ml-workbench/pyvenv.cfg 2>/dev/null
    echo "## apt"
    printf 'apt transactions: %s\n' "$(grep -c '^Start-Date' /var/log/apt/history.log 2>/dev/null || echo 0)"
    echo "## recorded state"
    find /workspace/.setup-state -type f -print0 2>/dev/null | sort -z | xargs -0r sha256sum
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
fingerprint > "$LOGDIR/fingerprint-before.txt"
apt_before="$(wc -l < /var/log/apt/history.log 2>/dev/null || echo 0)"
t0=$SECONDS
./server-provision.sh --plan "./$PLAN" < /dev/null 2>&1 | tee "$LOGDIR/install-2.log"
code=${PIPESTATUS[0]}
note "exit $code after $(( (SECONDS - t0) / 60 )) min"
fingerprint > "$LOGDIR/fingerprint-after.txt"
if (( code == 0 )); then result PASS "repeat install succeeded"; else result FAIL "repeat install failed (exit $code)"; fi

# --- 7. What the repeat changed -----------------------------------------------
stage "7/8 What the repeat changed"
section() { awk -v s="$1" '/^## / {on = ($0 == "## " s)} on' "$2"; }
rebuilt=0; n=0
for s in "installed files (inode, mtime, size)" "ml environment build" "apt"; do
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
    note "recorded state files that changed (timestamps are expected):"; sed 's/^/      /' "$LOGDIR/changed-state.diff"
fi
tail -n +"$(( apt_before + 1 ))" /var/log/apt/history.log 2>/dev/null \
    | grep -E '^(Start-Date|Commandline|Install|Upgrade|Remove):' > "$LOGDIR/apt-during-repeat.txt" || true
note "apt during the repeat: $(grep -c '^Start-Date' "$LOGDIR/apt-during-repeat.txt") transaction(s)"

# --- 8. The stack still works after the repeat --------------------------------
stage "8/8 Check the installed stack again, after the repeat"
stack_checks after-repeat
finish
