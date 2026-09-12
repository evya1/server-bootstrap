#!/usr/bin/env bash
# The single definition of which files are part of a release.
#
#   release/release-files.sh list      NUL-separated canonical paths
#   release/release-files.sh write     regenerate checksums/SHA256SUMS
#   release/release-files.sh verify    compare the committed manifest, exactly
#   release/release-files.sh source    print where the set came from
#
#   --root DIR    operate on DIR instead of the repository root
#
# release/build-release.sh used to walk the working tree with find, so an
# untracked scratch file in a contributor's checkout entered checksums/SHA256SUMS
# and all three archives while every gate stayed green. The set is resolved here
# once and consumed by manifest generation, tar creation, the source stage and
# the tests, so there is nothing left to keep in step.
#
# Two execution contexts are supported, in this order:
#
#   git       a normal checkout. The set is `git ls-files`, so untracked files,
#             ignored artifacts and .git itself are excluded by construction
#             rather than by a list of find exclusions that has to grow.
#   manifest  an unpacked source bundle with no .git. The set is the path list
#             already recorded in checksums/SHA256SUMS, plus the manifest. The
#             mode is announced, never silent: it is a weaker input, because the
#             manifest defines the set it is then checked against.
#
# Exit: 0 clean, 1 drift, 2 usage or an unusable tree.
set -Eeuo pipefail

usage() { sed -n '2,9p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

release_files_main() {
    local action="" root=""
    while (( $# )); do
        case "$1" in
            --root) root="${2:?--root needs a directory}"; shift 2 ;;
            -h|--help) usage; return 0 ;;
            list|write|verify|source)
                [[ -z "$action" ]] || { echo "release-files: one action at a time" >&2; return 2; }
                action="$1"; shift ;;
            *) printf 'release-files: unknown argument: %s\n' "$1" >&2; usage >&2; return 2 ;;
        esac
    done
    [[ -n "$action" ]] || { usage >&2; return 2; }
    if [[ -z "$root" ]]; then
        root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
    fi
    [[ -d "$root" ]] || { printf 'release-files: not a directory: %s\n' "$root" >&2; return 2; }

    SB_RELEASE_ROOT="$root" SB_RELEASE_ACTION="$action" python3 - <<'PY'
import hashlib
import os
import pathlib
import subprocess
import sys

root = pathlib.Path(os.environ["SB_RELEASE_ROOT"]).resolve()
action = os.environ["SB_RELEASE_ACTION"]

MANIFEST = "checksums/SHA256SUMS"
MAX_FINDINGS = 20


def die(message: str, code: int = 2):
    print(f"release-files: {message}", file=sys.stderr)
    raise SystemExit(code)


# A sha256sum line is <64 hex><two spaces><path>. GNU sha256sum escapes a path
# containing a backslash or a newline by prefixing the line with "\" and
# encoding the character, which makes the format ambiguous to anything that has
# not implemented the decoding. Rather than implement it, both directions refuse
# such a path: the repository has none, and a loud refusal beats a manifest
# whose meaning depends on a rule nobody remembers. A path containing spaces is
# fine and is parsed correctly, because the split is on the fixed prefix.
def reject_unsafe(paths):
    for path in paths:
        if "\\" in path or "\n" in path:
            die(f"path needs escaping in a checksum manifest, refusing: {path!r}")
        # A manifest is an input in source-bundle mode, so it decides what gets
        # hashed and packed. An absolute path or one climbing out of the tree
        # would reach outside it; server-provision.sh refuses the same shapes in
        # an archive listing, for the same reason.
        if path.startswith("/") or path.split("/")[0] == ".." or "/../" in path:
            die(f"release path escapes the tree, refusing: {path!r}")
        if not path or path.startswith("./"):
            die(f"release path is not normalised, refusing: {path!r}")


def git_set():
    """Tracked paths, or None when this is not a usable git checkout."""
    if not (root / ".git").exists():
        return None
    try:
        top = subprocess.run(
            ["git", "-C", str(root), "rev-parse", "--show-toplevel"],
            capture_output=True, text=True, check=True).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        return None
    if pathlib.Path(top).resolve() != root:
        return None
    out = subprocess.run(
        ["git", "-C", str(root), "ls-files", "-z"],
        capture_output=True, check=True).stdout
    return [p.decode() for p in out.split(b"\0") if p]


def manifest_set():
    """The path list the shipped manifest already records, plus the manifest."""
    text = read_manifest()
    if text is None:
        return None
    paths = []
    for number, line in enumerate(text.splitlines(), 1):
        if not line:
            continue
        if len(line) < 67 or line[64:66] != "  ":
            die(f"malformed line {number} in {MANIFEST}; cannot derive the release set")
        paths.append(line[66:])
    if not paths:
        die(f"{MANIFEST} records no files; cannot derive the release set")
    return paths + [MANIFEST]


def read_manifest():
    path = root / MANIFEST
    if not path.is_file():
        return None
    return path.read_text()


def resolve():
    paths = git_set()
    if paths is not None:
        return "git", paths
    paths = manifest_set()
    if paths is not None:
        return "manifest", paths
    die("no .git and no checksums/SHA256SUMS: cannot determine the release set")


def canonical():
    origin, paths = resolve()
    reject_unsafe(paths)
    seen = sorted(set(paths), key=lambda p: p.encode())
    if len(seen) != len(paths):
        die(f"the {origin} release set contains a duplicate path")
    return origin, seen


def sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def build_manifest(paths):
    """The manifest as it should be: every release file except the manifest."""
    lines = []
    for rel in paths:
        if rel == MANIFEST:
            continue
        target = root / rel
        if not target.is_file():
            die(f"in the release set but not on disk: {rel}", 1)
        lines.append(f"{sha256(target)}  {rel}")
    return "".join(line + "\n" for line in lines)


origin, paths = canonical()

if action == "source":
    print(origin)
    raise SystemExit(0)

if action == "list":
    sys.stdout.buffer.write(b"".join(p.encode() + b"\0" for p in paths))
    raise SystemExit(0)

if action == "write":
    (root / MANIFEST).parent.mkdir(parents=True, exist_ok=True)
    (root / MANIFEST).write_text(build_manifest(paths))
    print(f"release-files: wrote {MANIFEST} from the {origin} release set "
          f"({len(paths) - 1} files)")
    raise SystemExit(0)

# --- verify ----------------------------------------------------------------
findings = []


def report(message):
    findings.append(message)


text = read_manifest()
if text is None:
    die(f"missing {MANIFEST}", 1)

recorded = {}
order = []
for number, line in enumerate(text.splitlines(), 1):
    if not line:
        report(f"malformed line {number}: blank")
        continue
    if len(line) < 67 or line[64:66] != "  " or not all(
            c in "0123456789abcdef" for c in line[:64]):
        report(f"malformed line {number}: expected <64 hex><two spaces><path>")
        continue
    digest, rel = line[:64], line[66:]
    if rel in recorded:
        report(f"duplicate entry: {rel}")
        continue
    recorded[rel] = digest
    order.append(rel)

for index in range(1, len(order)):
    if order[index].encode() < order[index - 1].encode():
        report(f"manifest is not sorted at line {index + 1}: "
               f"{order[index]} follows {order[index - 1]}")
        break

expected = [p for p in paths if p != MANIFEST]
expected_set = set(expected)

# The class the containment check this replaces cannot see: an entry recorded
# for something that is not part of the release. That is exactly what an
# untracked scratch file looked like once build-release.sh had hashed it.
if origin == "git":
    for rel in order:
        if rel not in expected_set:
            report(f"not part of the release: {rel}")

for rel in expected:
    if rel not in recorded:
        report(f"missing from the manifest: {rel}")
        continue
    target = root / rel
    if not target.is_file():
        report(f"recorded but not on disk: {rel}")
        continue
    if recorded[rel] != sha256(target):
        report(f"stale hash: {rel}")

if origin != "git":
    print(f"release-files: verifying against the {origin} release set; the "
          f"tracked-set comparison is unavailable without .git", file=sys.stderr)

if findings:
    for line in findings[:MAX_FINDINGS]:
        print(f"release-files: {line}", file=sys.stderr)
    if len(findings) > MAX_FINDINGS:
        print(f"release-files: ... and {len(findings) - MAX_FINDINGS} more",
              file=sys.stderr)
    print(f"\nrelease-files: {len(findings)} finding(s) in {MANIFEST}; "
          f"regenerate with 'bash release/release-files.sh write'", file=sys.stderr)
    raise SystemExit(1)

print(f"release-files: {MANIFEST} matches the {origin} release set "
      f"({len(expected)} files)")
PY
}

[[ "${BASH_SOURCE[0]}" != "$0" ]] || release_files_main "$@"
