#!/usr/bin/env bash
# Generate and verify the ml profile's frozen, hash-checked locks.
#
#   tools/ml-lock.sh [--backend NAME] [--arch x86_64|aarch64]
#                                  resolve profiles/ml/requirements.in for each
#                                  backends.txt row and write
#                                  profiles/ml/locks/<backend>-<arch>.txt
#   tools/ml-lock.sh --verify [--require-all]
#                                  check every committed lock, offline
#   tools/ml-lock.sh --check-artifacts [--backend NAME] [--arch x86_64|aarch64]
#                                  download, into a temporary directory, the
#                                  artifact each committed lock selects for its
#                                  architecture, check its SHA-256 and its wheel
#                                  tags; installs nothing
#
#   --dir DIR    operate on another profile directory (tests)
#
# Generation and --check-artifacts need the pinned uv (lib/bootstrap/config.sh)
# and HTTPS access to https://pypi.org and https://download.pytorch.org. uv's
# --torch-backend routes the PyTorch packages (torch, torchvision, and triton
# for CUDA) to the backend's official index,
# https://download.pytorch.org/whl/<backend>, and everything else to PyPI; the
# installer routes them the same way. Every artifact is recorded with its
# SHA-256. Nothing here runs in CI or in the test suite with network access.
#
# --verify reports a declared backend and architecture without a lock as
# pending and still exits 0, unless --require-all is given. Any committed lock
# that is malformed, undeclared, unhashed or not from the official index fails.
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
PROFILE_DIR="$ROOT/profiles/ml"
MODE=generate; ONLY_BACKEND=""; ONLY_ARCH=""; REQUIRE_ALL=0

die() { printf 'ml-lock: %s\n' "$1" >&2; exit "${2:-1}"; }

while (( $# )); do
    case "$1" in
        --verify) MODE=verify; shift ;;
        --check-artifacts) MODE=artifacts; shift ;;
        --require-all) REQUIRE_ALL=1; shift ;;
        --backend) ONLY_BACKEND="${2:?--backend needs a name}"; shift 2 ;;
        --arch) ONLY_ARCH="${2:?--arch needs x86_64 or aarch64}"; shift 2 ;;
        --dir) PROFILE_DIR="$(cd -- "${2:?--dir needs a directory}" && pwd -P)"; shift 2 ;;
        -h|--help) sed -n '2,28p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "unknown argument: $1" 2 ;;
    esac
done
[[ -f "$PROFILE_DIR/backends.txt" && -f "$PROFILE_DIR/requirements.in" ]] \
    || die "no backends.txt and requirements.in in $PROFILE_DIR" 2

# One offline validator, used on every lock this tool writes and by --verify.
verify_locks() {  # lock files to check (empty: every committed lock)
    SB_ML_PROFILE_DIR="$PROFILE_DIR" SB_ML_REQUIRE_ALL="$REQUIRE_ALL" python3 - "$@" <<'PY'
import os
import pathlib
import re
import sys

profile = pathlib.Path(os.environ["SB_ML_PROFILE_DIR"])
require_all = os.environ["SB_ML_REQUIRE_ALL"] == "1"
OFFICIAL = re.compile(r"^https://download\.pytorch\.org/whl/[a-z0-9]+$")
TORCH_INDEX = "https://download.pytorch.org/whl"
PYPI = "https://pypi.org/simple"
HASH = re.compile(r"^--hash=sha256:[0-9a-f]{64}$")
REQ = re.compile(r"^([A-Za-z0-9][A-Za-z0-9._-]*)==([A-Za-z0-9.+!_-]+)(?: \\)?$")
ARCHES = ("x86_64", "aarch64")
PAIRED = ("torch", "torchvision")
EXCLUDED = ("torchtext",)


def norm(name):
    return re.sub(r"[-_.]+", "-", name).lower()


backends = {}
for line in (profile / "backends.txt").read_text().splitlines():
    fields = line.split("#", 1)[0].split()
    if not fields:
        continue
    if len(fields) != 4:
        sys.exit(f"ml-lock: backends.txt: expected 'backend cuda architectures index': {line}")
    name, cuda, arches, index = fields
    backends[name] = {"cuda": cuda, "arches": arches.split(","), "index": index}

wanted, pins = [], {}
for line in (profile / "requirements.in").read_text().splitlines():
    spec = line.split("#", 1)[0].strip()
    if not spec:
        continue
    name = norm(re.split(r"[=<>!~\[; ]", spec, maxsplit=1)[0])
    wanted.append(name)
    if "==" in spec:
        pins[name] = spec.split("==", 1)[1].strip()

problems = []


def check(path):
    rel = path.name
    stem = rel[:-4] if rel.endswith(".txt") else rel
    backend, _, arch = stem.rpartition("-")
    lines = path.read_text().splitlines()
    header = {}
    for line in lines:
        if not line.startswith("#"):
            break
        match = re.match(r"^# ([a-z-]+): (.+)$", line)
        if match:
            header[match.group(1)] = match.group(2).strip()
    bad = lambda message: problems.append(f"{rel}: {message}")
    if not rel.endswith(".txt") or arch not in ARCHES:
        return bad("name is not <backend>-<x86_64|aarch64>.txt")
    for key in ("backend", "arch", "python", "cuda", "torch-index"):
        if key not in header:
            bad(f"header has no '{key}'")
    if header.get("backend") != backend or header.get("arch") != arch:
        bad("header backend/arch do not match the file name")
    if header.get("python") != "3.12":
        bad("header python is not 3.12")
    row = backends.get(backend)
    if row is None:
        return bad(f"backend {backend} is not declared in backends.txt")
    if arch not in row["arches"]:
        bad(f"backends.txt does not declare {arch} for {backend}")
    index = header.get("torch-index", "")
    if index != row["index"] or header.get("cuda") != row["cuda"]:
        bad("header cuda/torch-index disagree with backends.txt")
    if not OFFICIAL.match(index):
        bad(f"torch index is not an official https://download.pytorch.org/whl/ index: {index}")
    elif index != f"{TORCH_INDEX}/{backend}":
        bad(f"torch index is not {TORCH_INDEX}/{backend}, the index uv's --torch-backend {backend} uses")
    # PyPI is the only index a lock names. Another index line would reroute
    # packages at install time, where uv's --torch-backend sends the PyTorch
    # packages to the backend's index.
    if f"--index-url {PYPI}" not in lines:
        bad("does not name PyPI as its index")

    blocks, current = {}, None
    for number, line in enumerate(lines, 1):
        if not line or line.startswith("#") or line == f"--index-url {PYPI}":
            continue
        if line.startswith("-"):
            bad(f"line {number}: option not allowed in a lock: {line}")
            current = None
            continue
        if line[0].isspace():
            text = line.strip().rstrip("\\").strip()
            if current is None:
                bad(f"line {number}: continuation outside a requirement")
            elif text.startswith("--hash="):
                if not HASH.match(text):
                    bad(f"line {number}: malformed hash")
                current["hashes"] += 1
            elif text.startswith("# from "):
                current["source"] = text[len("# from "):]
            continue
        match = REQ.match(line)
        if not match:
            bad(f"line {number}: not an exact name==version pin")
            current = None
            continue
        current = {"version": match.group(2), "hashes": 0, "source": None}
        blocks[norm(match.group(1))] = current
    if not blocks:
        bad("pins no packages")
    for name, block in sorted(blocks.items()):
        if block["hashes"] == 0:
            bad(f"{name} has no SHA-256")
        if block["source"] not in (PYPI, index):
            bad(f"{name} does not record PyPI or the backend's index as its source")
    for name in PAIRED:
        block = blocks.get(name)
        if block is None:
            bad(f"does not pin {name}")
            continue
        if block["source"] != index:
            bad(f"{name} is not taken from {index}")
        if name in pins and block["version"].split("+", 1)[0] != pins[name]:
            bad(f"{name} {block['version']} does not match requirements.in ({pins[name]})")
    for name in wanted:
        if name not in blocks:
            bad(f"requirements.in names {name}, the lock does not pin it")
    for name in EXCLUDED:
        if name in blocks:
            bad(f"{name} is excluded from the default profile")


paths = [pathlib.Path(p) for p in sys.argv[1:]] or sorted((profile / "locks").glob("*"))
for path in paths:
    check(path)
if len(sys.argv) == 1:
    for name, row in sorted(backends.items()):
        for arch in row["arches"]:
            if not (profile / "locks" / f"{name}-{arch}.txt").is_file():
                message = f"{name}-{arch}.txt is declared in backends.txt but not locked yet"
                if require_all:
                    problems.append(message)
                else:
                    print(f"ml-lock: pending: {message}")
for problem in problems:
    print(f"ml-lock: {problem}", file=sys.stderr)
if problems:
    sys.exit(1)
print(f"ml-lock: {len(paths)} lock(s) verified")
PY
}

if [[ "$MODE" == verify ]]; then
    verify_locks
    exit
fi

# --- Online modes: the pinned uv, and nothing from the caller that picks an index
# shellcheck source=../lib/bootstrap/config.sh
source "$ROOT/lib/bootstrap/config.sh"
bootstrap_load_config
UV_BIN="${SB_UV:-$(command -v uv 2>/dev/null || true)}"
[[ -n "$UV_BIN" && -x "$UV_BIN" ]] || die "uv $UV_VERSION is required; set SB_UV to its path"
uv_version="$("$UV_BIN" --version 2>/dev/null | awk 'NR == 1 { print $2 }')"
[[ "$uv_version" == "$UV_VERSION" ]] \
    || die "uv $UV_VERSION is pinned; $UV_BIN is ${uv_version:-unknown}"

# The result depends on the command line and the indexes alone: no uv
# configuration file, and no index, strategy or backend from the environment.
uv_clean() {
    env -u UV_INDEX -u UV_DEFAULT_INDEX -u UV_INDEX_URL -u UV_EXTRA_INDEX_URL \
        -u UV_FIND_LINKS -u UV_NO_INDEX -u UV_INDEX_STRATEGY -u UV_CONSTRAINT -u UV_OVERRIDE \
        -u UV_TORCH_BACKEND "$UV_BIN" "$@"
}

cd "$PROFILE_DIR"

if [[ "$MODE" == artifacts ]]; then
    verify_locks >/dev/null || die "a committed lock fails verification; run tools/ml-lock.sh --verify"
    checked=0
    for lock in locks/*.txt; do
        [[ -f "$lock" ]] || continue
        stem="$(basename -- "$lock" .txt)"; backend="${stem%-*}"; arch="${stem##*-}"
        [[ -z "$ONLY_BACKEND" || "$backend" == "$ONLY_BACKEND" ]] || continue
        [[ -z "$ONLY_ARCH" || "$arch" == "$ONLY_ARCH" ]] || continue
        target="$(mktemp -d)"
        echo "==> downloading every artifact $lock selects for $arch"
        # Routed as the installer routes it, downloaded afresh, refused unless
        # its SHA-256 is in the lock, and unpacked into a scratch directory.
        # Nothing is run.
        if ! uv_clean pip install --target "$target" --python-version 3.12 \
            --python-platform "$arch-manylinux_2_39" --torch-backend "$backend" \
            --require-hashes --no-deps --no-build --no-config --no-cache --quiet -r "$lock"; then
            rm -rf -- "$target"
            die "$lock: an artifact is missing for $arch or does not match its SHA-256"
        fi
        # Every pin arrived as one wheel, built for this architecture or for any.
        if ! python3 - "$target" "$arch" "$lock" <<'PY'
import pathlib
import re
import sys

target, arch, lock = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]
norm = lambda name: re.sub(r"[-_.]+", "-", name).lower()
pins = {norm(m.group(1)) for m in re.finditer(r"(?m)^([A-Za-z0-9][A-Za-z0-9._-]*)==", pathlib.Path(lock).read_text())}
seen, problems = set(), []
for wheel in target.glob("*.dist-info/WHEEL"):
    meta = (wheel.parent / "METADATA").read_text(errors="replace")
    name = norm(re.search(r"(?m)^Name: *(\S+)", meta).group(1))
    seen.add(name)
    platforms = {tag.split("-")[-1] for tag in re.findall(r"(?m)^Tag: *(\S+)", wheel.read_text())}
    if not platforms or not all(p == "any" or p.endswith("_" + arch) for p in platforms):
        problems.append(f"{name}: wheel platform {', '.join(sorted(platforms)) or 'unknown'} is not {arch}")
for name in sorted(pins - seen):
    problems.append(f"{name}: pinned, but no wheel was installed")
for problem in problems:
    print(f"ml-lock: {lock}: {problem}", file=sys.stderr)
if problems:
    sys.exit(1)
print(f"   {len(seen)} artifacts for {arch} downloaded, matched their SHA-256, and carry {arch} or pure-Python wheel tags")
PY
        then
            rm -rf -- "$target"
            die "$lock: the downloaded artifacts do not all fit $arch"
        fi
        rm -rf -- "$target"
        checked=$((checked + 1))
    done
    (( checked > 0 )) || die "no committed lock matched"
    exit 0
fi

# --- Generation ------------------------------------------------------------------
mkdir -p locks
written=0
while read -r backend cuda arches index; do
    [[ -n "$backend" && "$backend" != \#* ]] || continue
    [[ -z "$ONLY_BACKEND" || "$backend" == "$ONLY_BACKEND" ]] || continue
    # uv's --torch-backend derives the index from the backend's name.
    [[ "$index" == "https://download.pytorch.org/whl/$backend" ]] \
        || die "backends.txt: $backend must use https://download.pytorch.org/whl/$backend, not $index"
    IFS=, read -r -a arch_list <<< "$arches"
    for arch in "${arch_list[@]}"; do
        [[ -z "$ONLY_ARCH" || "$arch" == "$ONLY_ARCH" ]] || continue
        target="locks/$backend-$arch.txt"
        # Staged under its final name, so the validator sees exactly what lands.
        body="$(mktemp)"; stage_dir="$(mktemp -d -p locks .staging.XXXXXX)"
        staged="$stage_dir/$backend-$arch.txt"
        echo "==> resolving $target: PyTorch packages from $index, everything else from PyPI"
        uv_clean pip compile requirements.in \
            --python-version 3.12 --python-platform "$arch-manylinux_2_39" \
            --torch-backend "$backend" --default-index https://pypi.org/simple \
            --generate-hashes --emit-index-url --emit-index-annotation --no-build --no-config \
            --custom-compile-command "tools/ml-lock.sh --backend $backend --arch $arch" \
            --quiet --output-file "$body"
        {
            printf '# ml profile lock, generated by tools/ml-lock.sh. Do not edit by hand.\n'
            printf '# backend: %s\n# arch: %s\n# python: 3.12\n# cuda: %s\n' "$backend" "$arch" "$cuda"
            printf '# torch-index: %s\n# resolver: uv %s\n' "$index" "$uv_version"
            cat -- "$body"
        } > "$staged"
        rm -f -- "$body"
        verify_locks "$staged" >/dev/null 2>&1 || {
            verify_locks "$staged" || true
            rm -rf -- "$stage_dir"
            die "the resolved lock for $backend-$arch failed verification; nothing was written"
        }
        chmod 0644 "$staged"
        mv -f -- "$staged" "$target"
        rmdir -- "$stage_dir"
        written=$((written + 1))
        echo "   wrote $target ($(sha256sum -- "$target" | cut -c1-64))"
    done
done < backends.txt
(( written > 0 )) || die "no backends.txt row matched"
