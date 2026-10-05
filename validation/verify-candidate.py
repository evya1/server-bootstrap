#!/usr/bin/env python3
"""Independently compare a downloaded CI candidate with an exact Git tree."""
import argparse
import gzip
import hashlib
import io
import json
import pathlib
import re
import subprocess
import tarfile
import zipfile


def digest(data):
    return hashlib.sha256(data).hexdigest()


parser = argparse.ArgumentParser()
parser.add_argument("--repo", required=True)
parser.add_argument("--sha", required=True)
parser.add_argument("--candidate", required=True)
parser.add_argument("--manifest-sha256", required=True)
args = parser.parse_args()
repo, directory = pathlib.Path(args.repo).resolve(), pathlib.Path(args.candidate)
assert re.fullmatch(r"[0-9a-f]{40}", args.sha), "candidate commit must be a full Git SHA"
assert re.fullmatch(r"[0-9a-f]{64}", args.manifest_sha256), "invalid out-of-band manifest digest"
sha = subprocess.check_output(["git", "-C", str(repo), "rev-parse", "HEAD"]).decode().strip()
assert sha == args.sha, "checkout does not match the candidate commit"


def git_blob(path):
    return subprocess.check_output(["git", "-C", str(repo), "show", f"{sha}:{path}"])


entries = subprocess.check_output(["git", "-C", str(repo), "ls-tree", "-r", "-z", sha]).split(b"\0")
tree, modes = {}, {}
for entry in entries:
    if not entry:
        continue
    metadata, path = entry.split(b"\t", 1)
    path = path.decode()
    mode, kind, _ = metadata.decode().split()
    assert kind == "blob" and mode in ("100644", "100755"), f"unsupported tree entry: {path}"
    modes[path] = 0o755 if mode == "100755" else 0o644
    tree[path] = git_blob(path)

version = tree["VERSION"].decode().strip()
base = f"server-bootstrap-{version}"
# Asset membership comes from the canonical definition in this exact checkout;
# archive membership and modes come from the Git tree, never a hard-coded count.
for path in ("VERSION", "release/release-assets.sh"):
    assert (repo / path).read_bytes() == tree[path], f"modified verification input: {path}"

def asset_list(command):
    return subprocess.check_output(["bash", str(repo / "release/release-assets.sh"),
                                    "--root", str(repo), command], text=True).splitlines()

standalone = {row.split("\t")[0]: row.split("\t")[1] for row in asset_list("standalone")}
expected_assets = set(asset_list("upload"))
present = {p.name for p in directory.iterdir()}
assert present == expected_assets | {"SHA256SUMS"}, f"unexpected candidate membership: {present ^ (expected_assets | {'SHA256SUMS'})}"
for path in directory.iterdir():
    assert path.is_file() and not path.is_symlink(), f"nonregular candidate member: {path.name}"

out_manifest = (directory / "SHA256SUMS").read_bytes()
assert digest(out_manifest) == args.manifest_sha256, "candidate SHA256SUMS differs from the out-of-band frozen digest"
recorded = {}
for line in out_manifest.decode().splitlines():
    assert re.fullmatch("[0-9a-f]{64}  [^/]+", line), "malformed candidate SHA256SUMS line"
    value, path = line.split("  ", 1)
    assert path not in recorded, f"duplicate candidate manifest entry: {path}"
    recorded[path] = value
assert set(recorded) == expected_assets, "candidate checksum manifest does not cover the exact published asset set"
asset = {name: (directory / name).read_bytes() for name in expected_assets}
for name, value in recorded.items():
    assert digest(asset[name]) == value, f"candidate hash mismatch: {name}"
for suffix in ("tar.gz", "zip"):
    name = f"{base}.{suffix}"
    assert asset[f"{name}.sha256"] == f"{digest(asset[name])}  {name}\n".encode(), f"invalid archive sidecar: {name}"

uncompressed_tar = gzip.decompress(asset[f"{base}.tar.gz"])
manifest = json.loads(asset[f"{base}-release-manifest.json"])
assert manifest["name"] == "server-bootstrap" and manifest["version"] == version
assert manifest["tests"] == "passed" and manifest["release_scan"] == "passed" and manifest["reproducible"] is True
assert manifest["tar_sha256"] == digest(uncompressed_tar)
for key, name in (("tar_gz_sha256", f"{base}.tar.gz"), ("zip_sha256", f"{base}.zip"), ("source_zip_sha256", f"{base}-source.zip")):
    assert manifest[key] == digest(asset[name]), f"release-manifest hash mismatch: {key}"


def check_archive(label, prefix, rows):
    contents, recorded_modes = {}, {}
    for name, mode, data in rows:
        assert name.startswith(prefix), f"unexpected archive prefix: {label}: {name}"
        path = name[len(prefix):]
        assert path not in contents, f"duplicate archive member: {label}: {path}"
        contents[path], recorded_modes[path] = data, mode
    assert set(contents) == set(tree), f"archive tree membership differs: {label}"
    for path, data in contents.items():
        assert data == tree[path], f"archive bytes differ from frozen Git tree: {label}: {path}"
        assert recorded_modes[path] == modes[path], f"archive mode differs from Git flags: {label}: {path}"
    print(f"{label}: exact {len(contents)}-file Git tree; bytes and modes match")


def tar_rows(data):
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:") as archive:
        for member in archive.getmembers():
            assert member.isfile(), f"nonregular tar member: {member.name}"
            assert member.uid == 0 and member.gid == 0, f"noncanonical tar owner: {member.name}"
            yield member.name, member.mode, archive.extractfile(member).read()


def zip_rows(data):
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        for member in archive.infolist():
            assert not member.is_dir(), f"unexpected zip directory: {member.filename}"
            assert (member.external_attr >> 16) & 0o170000 == 0o100000, f"nonregular zip member: {member.filename}"
            yield member.filename, (member.external_attr >> 16) & 0o7777, archive.read(member)


check_archive(f"{base}.tar.gz (and its uncompressed tar)", f"{base}/", tar_rows(uncompressed_tar))
check_archive(f"{base}.zip", f"{base}/", zip_rows(asset[f"{base}.zip"]))
check_archive(f"{base}-source.zip", "server-bootstrap/", zip_rows(asset[f"{base}-source.zip"]))
for name, path in standalone.items():
    assert asset[name] == tree[path], f"standalone asset differs from frozen Git tree: {name}"

entries = []
for raw in tree["profiles/ml/backends.txt"].decode().splitlines():
    fields = raw.split("#", 1)[0].split()
    if not fields:
        continue
    backend, cuda, arches, index = fields
    for arch in arches.split(","):
        path = f"profiles/ml/locks/{backend}-{arch}.txt"
        entries.append({"backend": backend, "arch": arch, "cuda": cuda, "torch_index": index, "lock": path, "lock_sha256": digest(tree[path])})
expected_profiles = {"ml": {"install": "server-profile install ml", "backends": sorted(entries, key=lambda x: (x["backend"], x["arch"]))}}
assert manifest["profiles"] == expected_profiles, "release-manifest ML metadata differs from frozen Git tree"
assert all(path in tree for path in manifest["entrypoints"]), "manifest entrypoint missing from frozen tree"
print(f"Reviewed frozen SHA: {sha}")
print(f"Candidate SHA256SUMS: {digest(out_manifest)}")
print(f"Independent candidate verification: {len(expected_assets)} published assets; {len(standalone)} standalone copies; all hashes, membership, package locks, archive bytes and modes match")
