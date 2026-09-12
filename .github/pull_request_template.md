## What and why

<!-- A paragraph. What changes, and the reason it changes. -->

## Verification

- [ ] `bash tests/run-tests.sh`
- [ ] `bash release/build-release.sh` — passes and reports `reproducible: true`
- [ ] Ran it on a real Ubuntu host — or state why that isn't applicable
- [ ] Installed from the built archive the way the README tells users to:
      download the four release assets, `sha256sum -c` the sidecar, then
      `./server-provision.sh --plan ...`. Building the archive is not the same
      as installing from it.

## Release bookkeeping

- [ ] `VERSION` and `CHANGELOG.md` updated, or: nothing user-facing shipped
- [ ] Pins touched? `tools/check-pins.sh` is clean, and `tools/refresh-pins.sh --check` reports no actionable drift
- [ ] New file? registered in `lib/bootstrap/runtime.sh` **and** the verify list in `release/build-release.sh`

## Security model

- [ ] No key-shaped strings anywhere in the diff
- [ ] Any new download is checksum-verified before it is used or extracted
