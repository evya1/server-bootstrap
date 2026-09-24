#!/usr/bin/env bash
# The single definition of what release/dist holds and what a release uploads.
#
#   release/release-assets.sh built         every file the build leaves in release/dist
#   release/release-assets.sh upload        the files a release publishes
#   release/release-assets.sh standalone    first-run copies: dist name, tracked path, mode
#   release/release-assets.sh required      release files the ml profile and its example need
#   release/release-assets.sh profiles      the release manifest's "profiles" object, as JSON
#   release/release-assets.sh verify [DIR]  check DIR (default release/dist), exactly
#
#   --root DIR    operate on DIR instead of the repository root
#
# verify is the last gate before upload. It fails unless DIR holds exactly the
# built set -- nothing missing, nothing extra, only regular files -- and:
#   - each .sha256 sidecar names its archive and matches it;
#   - the release manifest names this version, records the archives' real
#     hashes, and reports tests, scan and reproducibility with known values;
#   - the tar, tar.gz and zip hold exactly the release file set under
#     server-bootstrap-VERSION/, and the source zip under server-bootstrap/, each
#     file byte-identical to the tree the release was built from;
#   - every standalone copy is byte-identical to its tracked file, with its mode;
#   - every file the ml profile needs, and every lock backends.txt declares, is
#     in the release set, and the manifest's lock digests are those of the locks
#     inside the archives.
#
# release.yml uploads by glob, and a glob such as server-bootstrap-*.tar.gz also
# matches a separate archive like server-bootstrap-ml-1.0.0.tar.gz. The exact-set
# check here, run by tools/release-preflight.sh immediately before the upload,
# is what keeps an unexpected or unverified file from being published.
#
# Exit: 0 clean, 1 a finding, 2 usage or an unusable tree.
set -Eeuo pipefail

usage() { sed -n '2,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

root=""; action=""; target=""
while (( $# )); do
    case "$1" in
        --root) root="${2:?--root needs a directory}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        built|upload|standalone|required|profiles|verify)
            [[ -z "$action" ]] || { echo "release-assets: one action at a time" >&2; exit 2; }
            action="$1"; shift ;;
        *)
            if [[ "$action" == verify && -z "$target" ]]; then target="$1"; shift
            else printf 'release-assets: unknown argument: %s\n' "$1" >&2; usage >&2; exit 2; fi ;;
    esac
done
[[ -n "$action" ]] || { usage >&2; exit 2; }
[[ -n "$root" ]] || root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
[[ -d "$root" ]] || { printf 'release-assets: not a directory: %s\n' "$root" >&2; exit 2; }
root="$(cd -- "$root" && pwd -P)"
target="${target:-$root/release/dist}"

release_list=""
if [[ "$action" == verify || "$action" == required ]]; then
    release_list="$(mktemp)"
    trap 'rm -f -- "$release_list"' EXIT
    bash "$root/release/release-files.sh" --root "$root" list > "$release_list" \
        || { echo "release-assets: cannot resolve the release file set" >&2; exit 2; }
fi

SB_ROOT="$root" SB_ACTION="$action" SB_TARGET="$target" SB_RELEASE_LIST="$release_list" python3 - <<'PY'
import hashlib
import io
import json
import os
import pathlib
import re
import stat
import sys
import tarfile
import zipfile

root = pathlib.Path(os.environ["SB_ROOT"])
action = os.environ["SB_ACTION"]
NAME = "server-bootstrap"
VERSION = (root / "VERSION").read_text().strip()
BASE = f"{NAME}-{VERSION}"

# The first-run files published beside the archives: dist name, tracked path,
# mode. The build installs exactly these, and verify holds it to them.
STANDALONE = (
    ("server-provision.sh", "server-provision.sh", 0o755),
    ("provision-plan.example.sh", "examples/provision-plan.example.sh", 0o644),
    ("provision-plan.whisper.example.sh", "examples/provision-plan.whisper.example.sh", 0o644),
    ("provision-plan.ml.example.sh", "examples/provision-plan.ml.example.sh", 0o644),
)
ARCHIVES = (f"{BASE}.tar", f"{BASE}.tar.gz", f"{BASE}.zip", f"{BASE}-source.zip")
SIDECARS = {f"{BASE}.tar.sha256": f"{BASE}.tar", f"{BASE}.tar.gz.sha256": f"{BASE}.tar.gz",
            f"{BASE}.zip.sha256": f"{BASE}.zip"}
MANIFEST = f"{BASE}-release-manifest.json"
UPLOAD = (f"{BASE}.tar.gz", f"{BASE}.tar.gz.sha256", f"{BASE}.zip", f"{BASE}.zip.sha256",
          f"{BASE}-source.zip", MANIFEST) + tuple(name for name, _, _ in STANDALONE)
# The uncompressed tar and its sidecar are built, hashed and scanned, but only
# the tar.gz is published.
BUILT = UPLOAD + (f"{BASE}.tar", f"{BASE}.tar.sha256")
# What the ml profile needs at runtime, and the example that enables it. The
# locks are added from backends.txt.
PROFILE_FILES = (
    "server-profile", "profiles/ml/install.sh", "profiles/ml/lib.sh", "profiles/ml/check.py",
    "profiles/ml/backends.txt", "profiles/ml/requirements.in", "profiles/ml/bin/ml-env",
    "profiles/ml/bin/ml-status", "profiles/ml/bin/ml-doctor", "profiles/ml/bin/ml-preflight",
    "profiles/ml/bin/ml-jupyter", "examples/provision-plan.ml.example.sh",
)
TEST_STATES = ("passed", "skipped")
SCAN_STATES = ("passed", "skipped")


def fail(message, code=2):
    print(f"release-assets: {message}", file=sys.stderr)
    raise SystemExit(code)


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def declared_locks(backends_text):
    """(backend, cuda, arch, index, lock path) for each backends.txt row and architecture."""
    rows = []
    for line in backends_text.splitlines():
        fields = line.split("#", 1)[0].split()
        if not fields:
            continue
        if len(fields) != 4:
            fail(f"profiles/ml/backends.txt: expected 'backend cuda architectures index': {line}")
        backend, cuda, arches, index = fields
        for arch in arches.split(","):
            rows.append((backend, cuda, arch, index, f"profiles/ml/locks/{backend}-{arch}.txt"))
    return sorted(rows)


def profiles_object(read):
    """The manifest's profiles object, from files read through read(path) -> bytes or None."""
    backends = read("profiles/ml/backends.txt")
    if backends is None:
        fail("profiles/ml/backends.txt is missing")
    entries = []
    for backend, cuda, arch, index, lock in declared_locks(backends.decode()):
        data = read(lock)
        if data is None:
            fail(f"{lock} is declared in backends.txt but missing; a release ships every declared lock")
        entries.append({"backend": backend, "arch": arch, "cuda": cuda, "torch_index": index,
                        "lock": lock, "lock_sha256": sha256(data)})
    return {"ml": {"install": "server-profile install ml", "backends": entries}}


def read_tree(rel):
    path = root / rel
    return path.read_bytes() if path.is_file() else None


def release_set():
    raw = pathlib.Path(os.environ["SB_RELEASE_LIST"]).read_bytes()
    return [p.decode() for p in raw.split(b"\0") if p]


def required(paths):
    backends = read_tree("profiles/ml/backends.txt")
    locks = [row[4] for row in declared_locks(backends.decode())] if backends else []
    return list(PROFILE_FILES) + locks


if action == "built":
    print("\n".join(BUILT))
elif action == "upload":
    print("\n".join(UPLOAD))
elif action == "standalone":
    for name, path, mode in STANDALONE:
        print(f"{name}\t{path}\t{mode:04o}")
elif action == "profiles":
    print(json.dumps(profiles_object(read_tree), sort_keys=True, separators=(", ", ": ")))
elif action == "required":
    paths = set(release_set())
    missing = [p for p in required(paths) if p not in paths]
    for path in missing:
        print(f"release-assets: required by the ml profile but not in the release set: {path}",
              file=sys.stderr)
    if missing:
        raise SystemExit(1)
    print("\n".join(required(paths)))
else:
    dist = pathlib.Path(os.environ["SB_TARGET"])
    if not dist.is_dir():
        fail(f"not a directory: {dist}")
    findings = []
    bad = findings.append

    # 1. Exactly the built set, as regular files.
    present = {entry.name: entry for entry in dist.iterdir()}
    for name in sorted(present):
        entry = present[name]
        if name not in BUILT:
            bad(f"unexpected file, not a release asset: {name}")
        elif entry.is_symlink() or not stat.S_ISREG(entry.lstat().st_mode):
            bad(f"not a regular file: {name}")
    for name in BUILT:
        if name not in present:
            bad(f"missing release asset: {name}")
    if findings:
        for line in findings:
            print(f"release-assets: {line}", file=sys.stderr)
        raise SystemExit(1)
    blob = {name: (dist / name).read_bytes() for name in BUILT}
    digest = {name: sha256(blob[name]) for name in ARCHIVES}

    # 2. Sidecars, in sha256sum's own format.
    for sidecar, archive in SIDECARS.items():
        if blob[sidecar].decode(errors="replace") != f"{digest[archive]}  {archive}\n":
            bad(f"{sidecar} does not record the sha256 of {archive}")

    # 3. The release manifest.
    try:
        manifest = json.loads(blob[MANIFEST])
    except ValueError as error:
        manifest = {}
        bad(f"{MANIFEST} is not valid JSON: {error}")
    if manifest.get("name") != NAME or manifest.get("version") != VERSION:
        bad(f"{MANIFEST} does not name {NAME} {VERSION}")
    for key, archive in (("tar_sha256", f"{BASE}.tar"), ("tar_gz_sha256", f"{BASE}.tar.gz"),
                         ("zip_sha256", f"{BASE}.zip"), ("source_zip_sha256", f"{BASE}-source.zip")):
        if manifest.get(key) != digest[archive]:
            bad(f"{MANIFEST} {key} does not match {archive}")
    if manifest.get("tests") not in TEST_STATES:
        bad(f"{MANIFEST} reports tests as {manifest.get('tests')!r}")
    if manifest.get("release_scan") not in SCAN_STATES:
        bad(f"{MANIFEST} reports release_scan as {manifest.get('release_scan')!r}")
    if manifest.get("reproducible") is not True:
        bad(f"{MANIFEST} does not report the archives as reproducible")

    # 4. Every archive holds exactly the release set, byte-identical to the tree.
    paths = release_set()
    tree = {}
    for rel in paths:
        data = read_tree(rel)
        if data is None:
            bad(f"in the release set but not on disk: {rel}")
        else:
            tree[rel] = data

    def check_members(label, members, prefix):
        found = {}
        for member, data in members:
            if not member.startswith(prefix):
                bad(f"{label}: member outside {prefix}: {member}")
                continue
            found[member[len(prefix):]] = data
        for rel in sorted(set(found) - set(tree)):
            bad(f"{label}: not part of the release: {rel}")
        for rel in sorted(set(tree) - set(found)):
            bad(f"{label}: missing {rel}")
        for rel in sorted(set(tree) & set(found)):
            if found[rel] != tree[rel]:
                bad(f"{label}: {rel} differs from the tree it was built from")
        return found

    def tar_members(data, mode):
        with tarfile.open(fileobj=io.BytesIO(data), mode=mode) as archive:
            for info in archive.getmembers():
                if info.isfile():
                    yield info.name, archive.extractfile(info).read()
                elif not info.isdir():
                    bad(f"tar member is not a file or directory: {info.name}")

    def zip_members(data):
        with zipfile.ZipFile(io.BytesIO(data)) as archive:
            for info in archive.infolist():
                if not info.is_dir():
                    yield info.filename, archive.read(info)

    shipped = check_members(f"{BASE}.tar.gz", tar_members(blob[f"{BASE}.tar.gz"], "r:gz"), f"{BASE}/")
    check_members(f"{BASE}.tar", tar_members(blob[f"{BASE}.tar"], "r:"), f"{BASE}/")
    check_members(f"{BASE}.zip", zip_members(blob[f"{BASE}.zip"]), f"{BASE}/")
    check_members(f"{BASE}-source.zip", zip_members(blob[f"{BASE}-source.zip"]), f"{NAME}/")

    # 5. Standalone copies: the tracked bytes, with the documented mode.
    for name, rel, mode in STANDALONE:
        if blob[name] != tree.get(rel):
            bad(f"{name} is not byte-identical to {rel}")
        actual = stat.S_IMODE((dist / name).stat().st_mode)
        if actual != mode:
            bad(f"{name} has mode {actual:04o}, expected {mode:04o}")

    # 6. The ml profile: present in the release set, and described truthfully.
    for rel in required(set(paths)):
        if rel not in tree:
            bad(f"required by the ml profile but not in the release set: {rel}")
    expected = profiles_object(lambda rel: shipped.get(rel))
    if manifest.get("profiles") != expected:
        bad(f"{MANIFEST} profiles do not match the backends and locks in {BASE}.tar.gz")
    for entrypoint in manifest.get("entrypoints", []):
        if entrypoint not in tree:
            bad(f"{MANIFEST} names an entrypoint the release does not ship: {entrypoint}")

    if findings:
        for line in findings[:30]:
            print(f"release-assets: {line}", file=sys.stderr)
        if len(findings) > 30:
            print(f"release-assets: ... and {len(findings) - 30} more", file=sys.stderr)
        raise SystemExit(1)
    locks = len(expected["ml"]["backends"])
    print(f"release-assets: {dist.name} holds exactly the {len(BUILT)} built files; "
          f"{len(UPLOAD)} are published. Every archive carries the {len(paths)} release files, "
          f"including the ml profile and its {locks} lock(s).")
PY
