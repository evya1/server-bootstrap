#!/usr/bin/env bash
set -Euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$ROOT"
PASS=0; FAIL=0
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
ok(){ printf '  ok:   %s\n' "$1"; PASS=$((PASS+1)); }
bad(){ printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL+1)); }
section(){ printf '\n== %s ==\n' "$1"; }

section "Syntax and structure"
while IFS= read -r file; do
    bash -n "$file" && ok "bash -n $file" || bad "syntax: $file"
done < <(find . -type f \( -name '*.sh' -o -name 'gpu-bundle-install' -o -name 'gpu-vscode-extensions' \) | LC_ALL=C sort)
for file in lib/core.sh lib/archive.sh lib/bundle.sh \
    lib/bootstrap/config.sh lib/bootstrap/workspace.sh lib/bootstrap/packages.sh \
    lib/bootstrap/node.sh lib/bootstrap/ai_cli.sh lib/bootstrap/vscode.sh lib/bootstrap/uv.sh lib/bootstrap/python.sh lib/bootstrap/shell.sh \
    lib/bootstrap/runtime.sh lib/bootstrap/report.sh; do
    [[ -f "$file" ]] && ok "module present: $file" || bad "missing module: $file"
done
for command in gpu-server-bootstrap.sh gpu-provision.sh gpu-bundle-install gpu-accept.sh gpu-vscode-extensions; do
    [[ -x "$command" ]] && ok "executable: $command" || bad "not executable: $command"
done

# Matching is case-insensitive substring, so "whisper" also covers
# faster-whisper et al. and "torch" covers pytorch.
auto_terms=(whisper transcribe torch)
term_hit=0
for file in gpu-server-bootstrap.sh gpu-bundle-install lib/*.sh lib/bootstrap/*.sh; do
    for term in "${auto_terms[@]}"; do
        if grep -qi -- "$term" "$file"; then bad "workload term '$term' in neutral code: $file"; term_hit=1; fi
    done
done
(( term_hit == 0 )) && ok "neutral runtime code"

grep -q 'STEP=acceptance' gpu-server-bootstrap.sh && grep -q 'STEP=addon' gpu-server-bootstrap.sh \
    && [[ "$(grep -n 'STEP=acceptance' gpu-server-bootstrap.sh | cut -d: -f1)" -lt "$(grep -n 'STEP=addon' gpu-server-bootstrap.sh | cut -d: -f1)" ]] \
    && ok "acceptance precedes optional add-on" || bad "acceptance ordering"

section "Package command compatibility aliases"
# shellcheck source=/dev/null
source lib/bootstrap/packages.sh
ALIAS_FIX="$TMP/command-aliases"
mkdir -p "$ALIAS_FIX/source" "$ALIAS_FIX/bin"
cat > "$ALIAS_FIX/source/fdfind" <<'COMMAND'
#!/usr/bin/env bash
exit 0
COMMAND
chmod 0755 "$ALIAS_FIX/source/fdfind"
gsb_warn(){ :; }

alias_rc_first=0
PATH="$ALIAS_FIX/bin:$ALIAS_FIX/source:/usr/bin:/bin" \
BOOTSTRAP_LOCAL_BIN_DIR="$ALIAS_FIX/bin" \
    bootstrap_ensure_command_alias fdfind fd || alias_rc_first=$?
if [[ "$alias_rc_first" == 0 && -L "$ALIAS_FIX/bin/fd" \
    && "$(readlink "$ALIAS_FIX/bin/fd")" == "$ALIAS_FIX/source/fdfind" ]]; then
    ok "fdfind compatibility alias is created"
else bad "fdfind compatibility alias creation"; fi

alias_rc_rerun=0
PATH="$ALIAS_FIX/bin:$ALIAS_FIX/source:/usr/bin:/bin" \
BOOTSTRAP_LOCAL_BIN_DIR="$ALIAS_FIX/bin" \
    bootstrap_ensure_command_alias fdfind fd || alias_rc_rerun=$?
[[ "$alias_rc_rerun" == 0 ]] \
    && ok "existing compatibility alias is idempotent" \
    || bad "existing compatibility alias rerun"

alias_rc_missing=0
PATH="$ALIAS_FIX/bin:/usr/bin:/bin" \
BOOTSTRAP_LOCAL_BIN_DIR="$ALIAS_FIX/bin" \
    bootstrap_ensure_command_alias missing-command missing-alias || alias_rc_missing=$?
[[ "$alias_rc_missing" == 0 && ! -e "$ALIAS_FIX/bin/missing-alias" ]] \
    && ok "missing alias source warns without aborting" \
    || bad "missing alias source handling"

section "Generic bundle installation"
FIX="$TMP/fix"; mkdir -p "$FIX/src/demo-1.0.0"
printf '1.0.0\n' > "$FIX/src/demo-1.0.0/VERSION"
cat > "$FIX/src/demo-1.0.0/install.sh" <<'INSTALL'
#!/usr/bin/env bash
set -e
printf '%s\n' "$*" > "$DEMO_MARK"
INSTALL
chmod 0755 "$FIX/src/demo-1.0.0/install.sh"
tar -czf "$FIX/demo-1.0.0.tar.gz" -C "$FIX/src" demo-1.0.0
sha256sum "$FIX/demo-1.0.0.tar.gz" > "$FIX/demo.sha256"
STATE="$FIX/state"; MARK="$FIX/mark"
if DEMO_MARK="$MARK" STATE_ROOT="$STATE" ./gpu-bundle-install \
    --name demo --version 1.0.0 --archive "$FIX/demo-1.0.0.tar.gz" \
    --sha256-file "$FIX/demo.sha256" -- --alpha beta >/dev/null; then
    ok "valid bundle installs"
else bad "valid bundle install failed"; fi
[[ "$(cat "$MARK" 2>/dev/null)" == '--alpha beta' ]] && ok "installer args preserved" || bad "installer args"
[[ "$(cat "$STATE/bundles/demo/version" 2>/dev/null)" == 1.0.0 ]] && ok "version state" || bad "version state"
[[ -s "$STATE/bundles/demo/archive-sha256" ]] && ok "archive hash state" || bad "archive hash state"

rm -f "$MARK"
if DEMO_MARK="$MARK" STATE_ROOT="$STATE" ./gpu-bundle-install \
    --name demo --version 1.0.0 --archive "$FIX/demo-1.0.0.tar.gz" \
    --sha256-file "$FIX/demo.sha256" >/dev/null && [[ ! -e "$MARK" ]]; then
    ok "same version and hash is skipped"
else bad "idempotent skip"; fi

cp "$FIX/demo-1.0.0.tar.gz" "$FIX/delete-me.tar.gz"
sha256sum "$FIX/delete-me.tar.gz" > "$FIX/delete-me.sha256"
if DEMO_MARK="$FIX/delete-mark" STATE_ROOT="$FIX/delete-state" ./gpu-bundle-install \
    --name delete-demo --version 1.0.0 --archive "$FIX/delete-me.tar.gz" \
    --sha256-file "$FIX/delete-me.sha256" --delete-after-success >/dev/null \
    && [[ ! -e "$FIX/delete-me.tar.gz" && ! -e "$FIX/delete-me.sha256" ]]; then
    ok "archive and sidecar deleted after success"
else bad "success cleanup"; fi

cp "$FIX/demo-1.0.0.tar.gz" "$FIX/fail.tar.gz"
sha256sum "$FIX/fail.tar.gz" > "$FIX/fail.sha256"
mkdir -p "$FIX/badsrc/bad-1.0.0"; printf '1.0.0\n' > "$FIX/badsrc/bad-1.0.0/VERSION"
cat > "$FIX/badsrc/bad-1.0.0/install.sh" <<'BAD'
#!/usr/bin/env bash
exit 7
BAD
chmod +x "$FIX/badsrc/bad-1.0.0/install.sh"
tar -czf "$FIX/fail.tar.gz" -C "$FIX/badsrc" bad-1.0.0
sha256sum "$FIX/fail.tar.gz" > "$FIX/fail.sha256"
if STATE_ROOT="$FIX/fail-state" ./gpu-bundle-install --name fail-demo --version 1.0.0 \
    --archive "$FIX/fail.tar.gz" --sha256-file "$FIX/fail.sha256" \
    --delete-after-success >/dev/null 2>&1; then
    bad "failing installer accepted"
elif [[ -e "$FIX/fail.tar.gz" && -e "$FIX/fail.sha256" && ! -e "$FIX/fail-state/bundles/fail-demo/version" ]]; then
    ok "failed install retains archive and writes no state"
else bad "failure retention/state"; fi

section "Archive safety"
python3 - "$TMP" <<'PY'
import io, os, tarfile, sys
root=sys.argv[1]
with tarfile.open(os.path.join(root,'traversal.tar.gz'),'w:gz') as t:
    data=b'x'; info=tarfile.TarInfo('../escape'); info.size=len(data); t.addfile(info,io.BytesIO(data))
with tarfile.open(os.path.join(root,'symlink.tar.gz'),'w:gz') as t:
    d=tarfile.TarInfo('pkg'); d.type=tarfile.DIRTYPE; t.addfile(d)
    v=b'1.0.0\n'; vi=tarfile.TarInfo('pkg/VERSION'); vi.size=len(v); t.addfile(vi,io.BytesIO(v))
    i=b'#!/usr/bin/env bash\nexit 0\n'; ii=tarfile.TarInfo('pkg/install.sh'); ii.mode=0o755; ii.size=len(i); t.addfile(ii,io.BytesIO(i))
    s=tarfile.TarInfo('pkg/escape'); s.type=tarfile.SYMTYPE; s.linkname='../../etc/passwd'; t.addfile(s)
PY
mkdir -p "$TMP/xz-src/pkg"; printf 'ok\n' > "$TMP/xz-src/pkg/value.txt"
tar -cJf "$TMP/valid.tar.xz" -C "$TMP/xz-src" pkg
if bash -c 'set -e; source lib/archive.sh; gsb_extract_archive "$1" "$2" >/dev/null; [[ "$(cat "$2/pkg/value.txt")" == ok ]]' _ \
    "$TMP/valid.tar.xz" "$TMP/xz-out"; then
    ok "valid tar.xz extracts safely"
else bad "tar.xz extraction"; fi

for kind in traversal symlink; do
    sha256sum "$TMP/$kind.tar.gz" > "$TMP/$kind.sha256"
    if STATE_ROOT="$TMP/$kind-state" ./gpu-bundle-install --name "$kind" --version 1.0.0 \
        --archive "$TMP/$kind.tar.gz" --sha256-file "$TMP/$kind.sha256" >/dev/null 2>&1; then
        bad "$kind archive accepted"
    else ok "$kind archive rejected"; fi
done

section "Provision plan parsing"
PLAN_DIR="$TMP/plan"; mkdir -p "$PLAN_DIR"
cat > "$PLAN_DIR/plan.sh" <<'PLAN'
register_bootstrap ./base.tar.gz ./base.sha256
register_bundle first 1.0.0 ./first.tar.gz ./first.sha256 install.sh --one
register_bundle second 2.0.0 ./second.tar.gz ./second.sha256 install.sh --two
PLAN
output="$(./gpu-provision.sh --plan "$PLAN_DIR/plan.sh" --dry-run)"
[[ "$output" == *'Bundles: 2'* ]] && ok "dry-run counts bundles" || bad "dry-run count"
first_line="$(printf '%s\n' "$output" | grep -n 'first 1.0.0' | cut -d: -f1)"
second_line="$(printf '%s\n' "$output" | grep -n 'second 2.0.0' | cut -d: -f1)"
[[ -n "$first_line" && -n "$second_line" && "$first_line" -lt "$second_line" ]] \
    && ok "plan preserves bundle order" || bad "plan order"

section "Provision integration"
if (( EUID == 0 )); then
    FULL="$TMP/full"; mkdir -p "$FULL/bin" "$FULL/bootstrap-src/base-1.2.0"
    cat > "$FULL/bootstrap-src/base-1.2.0/gpu-server-bootstrap.sh" <<'FAKEBOOT'
#!/usr/bin/env bash
set -e
printf 'bootstrap\n' >> "$PROVISION_ORDER_LOG"
cat > "$PROVISION_FAKE_BIN/gpu-accept" <<'ACCEPT'
#!/usr/bin/env bash
printf 'accept\n' >> "$PROVISION_ORDER_LOG"
exit 0
ACCEPT
cat > "$PROVISION_FAKE_BIN/gpu-bundle-install" <<'BUNDLE'
#!/usr/bin/env bash
set -e
name= archive= sha_file= delete=0
while (($#)); do
  case "$1" in
    --name) name="$2"; shift 2 ;;
    --archive) archive="$2"; shift 2 ;;
    --sha256-file) sha_file="$2"; shift 2 ;;
    --delete-after-success) delete=1; shift ;;
    --) break ;;
    *) shift ;;
  esac
done
printf 'bundle:%s\n' "$name" >> "$PROVISION_ORDER_LOG"
(( delete == 0 )) || rm -f -- "$archive" "$sha_file"
BUNDLE
chmod 0755 "$PROVISION_FAKE_BIN/gpu-accept" "$PROVISION_FAKE_BIN/gpu-bundle-install"
FAKEBOOT
    chmod +x "$FULL/bootstrap-src/base-1.2.0/gpu-server-bootstrap.sh"
    tar -czf "$FULL/base.tar.gz" -C "$FULL/bootstrap-src" base-1.2.0
    sha256sum "$FULL/base.tar.gz" > "$FULL/base.sha256"
    : > "$FULL/one.tar.gz"; sha256sum "$FULL/one.tar.gz" > "$FULL/one.sha256"
    : > "$FULL/two.tar.gz"; sha256sum "$FULL/two.tar.gz" > "$FULL/two.sha256"
    cat > "$FULL/plan.sh" <<'PLAN'
export WORKSPACE_ROOT="$PLAN_DIR/workspace"
export PATH="$PLAN_DIR/bin:$PATH"
export PROVISION_FAKE_BIN="$PLAN_DIR/bin"
export PROVISION_ORDER_LOG="$PLAN_DIR/order.log"
export GPU_ACCEPT_POLICY=reject-stop
export DELETE_ARCHIVES_AFTER_SUCCESS=1
register_bootstrap ./base.tar.gz ./base.sha256
register_bundle one 1.0.0 ./one.tar.gz ./one.sha256 install.sh
register_bundle two 2.0.0 ./two.tar.gz ./two.sha256 install.sh
PLAN
    if ./gpu-provision.sh --plan "$FULL/plan.sh" >/dev/null \
        && [[ "$(cat "$FULL/order.log")" == $'bootstrap\naccept\nbundle:one\nbundle:two' ]] \
        && [[ ! -e "$FULL/base.tar.gz" && ! -e "$FULL/one.tar.gz" && ! -e "$FULL/two.tar.gz" ]]; then
        ok "full provision order and cleanup"
    else
        bad "full provision integration"
    fi
else
    ok "full provision integration skipped without root"
fi

section "VS Code extension helper"
VSCODE_FIX="$TMP/vscode"; mkdir -p "$VSCODE_FIX"
cat > "$VSCODE_FIX/code" <<'FAKECODE'
#!/usr/bin/env bash
set -e
case "$1" in
  --list-extensions) printf '%s\n' 'publisher.already' ;;
  --install-extension) printf '%s\n' "$2" >> "$VSCODE_INSTALL_LOG" ;;
  *) exit 2 ;;
esac
FAKECODE
chmod +x "$VSCODE_FIX/code"
cat > "$VSCODE_FIX/extensions.txt" <<'EXT'
publisher.already
publisher.missing
EXT
if VSCODE_INSTALL_LOG="$VSCODE_FIX/install.log" STATE_ROOT="$VSCODE_FIX/state" LOG_ROOT="$VSCODE_FIX/log" \
    ./gpu-vscode-extensions --cli "$VSCODE_FIX/code" --manifest "$VSCODE_FIX/extensions.txt" >/dev/null \
    && [[ "$(cat "$VSCODE_FIX/install.log")" == publisher.missing ]]; then
    ok "helper installs only missing extensions"
else bad "VS Code helper idempotence"; fi
if STATE_ROOT="$VSCODE_FIX/no-cli-state" LOG_ROOT="$VSCODE_FIX/no-cli-log" \
    VSCODE_CLI=/does/not/exist ./gpu-vscode-extensions --manifest "$VSCODE_FIX/extensions.txt" >/dev/null 2>&1; then
    bad "missing explicit VS Code CLI accepted"
else ok "missing explicit VS Code CLI rejected"; fi
cat > "$VSCODE_FIX/code-partial" <<'FAKEPARTIAL'
#!/usr/bin/env bash
set -e
case "$1" in
  --list-extensions) exit 0 ;;
  --install-extension)
    printf '%s
' "$2" >> "$VSCODE_INSTALL_LOG"
    [[ "$2" != publisher.fail ]]
    ;;
  *) exit 2 ;;
esac
FAKEPARTIAL
chmod +x "$VSCODE_FIX/code-partial"
cat > "$VSCODE_FIX/extensions-partial.txt" <<'EXTPARTIAL'
publisher.fail
publisher.after
EXTPARTIAL
partial_rc=0
VSCODE_INSTALL_LOG="$VSCODE_FIX/partial.log" STATE_ROOT="$VSCODE_FIX/partial-state" LOG_ROOT="$VSCODE_FIX/partial-logs" \
    ./gpu-vscode-extensions --cli "$VSCODE_FIX/code-partial" --manifest "$VSCODE_FIX/extensions-partial.txt" >/dev/null 2>&1 || partial_rc=$?
if [[ "$partial_rc" == 4 && "$(cat "$VSCODE_FIX/partial.log")" == $'publisher.fail
publisher.after' ]]; then
    ok "helper continues after an extension failure"
else bad "VS Code helper partial-failure behavior"; fi

section "Configuration and documentation"
grep -q 'UV_SHA256="${UV_SHA256:-[0-9a-fA-F]\{64\}}"' lib/bootstrap/config.sh \
    && ok "uv checksum pinned" || bad "uv checksum default"
grep -q 'INSTALL_NODEJS="${INSTALL_NODEJS:-1}"' lib/bootstrap/config.sh \
    && grep -q 'NODE_VERSION="${NODE_VERSION:-24.18.0}"' lib/bootstrap/config.sh \
    && grep -q '55aa7153f9d88f28d765fcdad5ae6945b5c0f98a36881703817e4c450fa76742' lib/bootstrap/config.sh \
    && grep -q '58c9520501f6ae2b52d5b210444e24b9d0c029a58c5011b797bc1fe7105886f6' lib/bootstrap/config.sh \
    && ok "Node.js LTS is enabled and checksum pinned" || bad "Node.js defaults/checksums"
grep -q 'INSTALL_CLAUDE_CODE="${INSTALL_CLAUDE_CODE:-1}"' lib/bootstrap/config.sh \
    && grep -q 'CLAUDE_CODE_VERSION="${CLAUDE_CODE_VERSION:-2.1.216}"' lib/bootstrap/config.sh \
    && grep -q '@anthropic-ai/claude-code@' lib/bootstrap/ai_cli.sh \
    && grep -q 'CLAUDE_CODE_DISABLE_AUTOUPDATER="${CLAUDE_CODE_DISABLE_AUTOUPDATER:-1}"' lib/bootstrap/config.sh \
    && grep -q 'export DISABLE_AUTOUPDATER=1' lib/bootstrap/ai_cli.sh \
    && ok "Claude Code is enabled, pinned, and update-controlled" || bad "Claude Code defaults/pin"
grep -q 'INSTALL_CODEX="${INSTALL_CODEX:-1}"' lib/bootstrap/config.sh \
    && grep -q 'CODEX_VERSION="${CODEX_VERSION:-0.145.0}"' lib/bootstrap/config.sh \
    && grep -q '@openai/codex@' lib/bootstrap/ai_cli.sh \
    && ok "Codex is enabled and version pinned" || bad "Codex defaults/pin"
grep -q 'INSTALL_VSCODE_EXTENSIONS="${INSTALL_VSCODE_EXTENSIONS:-1}"' lib/bootstrap/config.sh \
    && grep -q 'gpu-vscode-extensions --auto' lib/bootstrap/shell.sh \
    && [[ "$(awk 'NF && $1 !~ /^#/ {n++} END{print n}' config/vscode-extensions.txt)" == 49 ]] \
    && grep -q 'gpu-vscode-extensions" "$stage/gpu-vscode-extensions' lib/bootstrap/runtime.sh \
    && grep -q 'config/vscode-extensions.txt" "$stage/config/vscode-extensions.txt' lib/bootstrap/runtime.sh \
    && ok "VS Code extension manifest and deferred installer" || bad "VS Code extension configuration"
awk 'NF && $1 !~ /^#/ {print tolower($1)}' config/vscode-extensions.txt | grep -Eqv '^[a-z0-9][a-z0-9-]*\.[a-z0-9][a-z0-9._-]*$' \
    && bad "invalid VS Code extension ID" || ok "VS Code extension IDs are valid"
[[ "$(awk 'NF && $1 !~ /^#/ {print tolower($1)}' config/vscode-extensions.txt | sort | uniq -d | wc -l)" == 0 ]] \
    && ok "VS Code extension IDs are unique" || bad "duplicate VS Code extension IDs"

grep -q 'INSTALL_ZSH="${INSTALL_ZSH:-1}"' lib/bootstrap/config.sh \
    && grep -q 'zsh ffmpeg' lib/bootstrap/packages.sh \
    && ok "Zsh installed by default" || bad "Zsh package/default"
grep -q 'INSTALL_OH_MY_ZSH="${INSTALL_OH_MY_ZSH:-1}"' lib/bootstrap/config.sh \
    && grep -Eq 'OH_MY_ZSH_REF="\$\{OH_MY_ZSH_REF:-[0-9a-fA-F]{40}\}"' lib/bootstrap/config.sh \
    && ok "Oh My Zsh enabled and pinned" || bad "Oh My Zsh default/pin"
grep -q "alias c='clear'" lib/bootstrap/shell.sh \
    && grep -q 'source "\$ZSH/oh-my-zsh.sh"' lib/bootstrap/shell.sh \
    && ok "Oh My Zsh startup and clear alias" || bad "shell startup/clear alias"
grep -q 'bootstrap_set_default_zsh' lib/bootstrap/shell.sh \
    && grep -q 'usermod --shell' lib/bootstrap/shell.sh \
    && ok "Zsh login shell enforcement" || bad "Zsh default shell enforcement"
for doc in QUICKSTART PROVISIONING ARCHITECTURE BUNDLE-CONTRACT CONFIGURATION TROUBLESHOOTING; do
    [[ -s "docs/$doc.md" ]] && ok "documentation: $doc" || bad "missing documentation: $doc"
done

section "Fitness: example plans are safe to copy and paste"
# A plan carries a shebang and the executable bit, so it looks runnable. It is
# not: register_bootstrap only exists while gpu-provision.sh sources it. Running
# one used to emit 'command not found' twice and exit 127.
plan_guard_drift=0
for plan in examples/provision-plan*.sh; do
    grep -q 'declare -F register_bootstrap' "$plan" \
        || { bad "no direct-execution guard: $plan"; plan_guard_drift=1; continue; }
    guard_out="$(bash "$plan" 2>&1)"; guard_code=$?
    [[ "$guard_code" == 2 ]] \
        || { bad "$plan exited $guard_code when run directly, expected 2"; plan_guard_drift=1; }
    grep -qF -- '--plan' <<< "$guard_out" \
        || { bad "$plan guard does not name the correct command"; plan_guard_drift=1; }
done
(( plan_guard_drift == 0 )) && ok "example plans reject direct execution"

# The quick-start plan must install the foundation only. An active
# register_bundle naming an archive that ships nowhere aborts provisioning
# after the bootstrap has already installed, reporting FAILED on a box that
# was in fact provisioned.
if grep -qE '^[[:space:]]*register_bundle' examples/provision-plan.example.sh; then
    bad "provision-plan.example.sh registers a bundle; quick start would fail"
else
    ok "default example plan registers no unavailable bundle"
fi

# The README must send people through gpu-provision.sh, never at a plan file.
if grep -qE '^[[:space:]]*(sudo )?\./provision-plan[^[:space:]]*\.sh' README.md; then
    bad "README invokes a plan file directly"
elif grep -q 'gpu-provision.sh --plan' README.md; then
    ok "README quick start uses gpu-provision.sh --plan"
else
    bad "README quick start does not show gpu-provision.sh --plan"
fi

section "Fitness: shipped version strings match VERSION"
# 1.3.2 shipped headers still advertising 1.3.1 because config.example.env and
# checksums/*.txt are neither Markdown nor shell and were missed by a bump that
# only grepped those. A file may not claim a version that VERSION disagrees with.
# CHANGELOG.md and docs/TROUBLESHOOTING.md are excluded: they cite history.
declared="$(tr -d '[:space:]' < VERSION)"
version_drift=0
grep -q "BOOTSTRAP_VERSION=\"$declared\"" lib/bootstrap/config.sh \
    || { bad "BOOTSTRAP_VERSION does not match VERSION ($declared)"; version_drift=1; }
grep -qF "V=$declared" README.md \
    || { bad "README download snippet does not pin V=$declared"; version_drift=1; }
while IFS= read -r hit; do
    [[ -n "$hit" ]] || continue
    bad "stale version string: $hit"
    version_drift=1
done < <(grep -rnoE 'gpu-server-bootstrap[ -]v?[0-9]+\.[0-9]+\.[0-9]+' \
    README.md config.example.env checksums/*.txt docs/PROVISIONING.md examples/*.sh 2>/dev/null \
    | grep -vF "gpu-server-bootstrap $declared" \
    | grep -vF "gpu-server-bootstrap-$declared" || true)
(( version_drift == 0 )) && ok "shipped version strings match VERSION"

section "Results"
printf 'PASS: %d   FAIL: %d\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
