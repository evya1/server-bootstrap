# Provisioning plans

A plan is a small Bash data file sourced by `server-provision.sh`. It should contain
configuration exports plus registration calls; it should not perform downloads
or installation itself.

## Bootstrap registration

```bash
register_bootstrap \
  "./server-bootstrap-2.3.2.tar.gz" \
  "./server-bootstrap-2.3.2.tar.gz.sha256"
```

Only one bootstrap may be registered.

## Bundle registration

```bash
register_bundle \
  "toolkit-name" \
  "1.0.0" \
  "./toolkit-name-1.0.0.tar.gz" \
  "./toolkit-name-1.0.0.tar.gz.sha256" \
  "install.sh" \
  --installer-option
```

Bundles run strictly in registration order. Put a shared runtime before bundles
that reuse it, and put personal configuration bundles last.

Paths may be absolute or relative to the plan file.

## Remote bundle registration

A bundle can also be fetched over HTTPS and pinned to its SHA-256:

```bash
register_remote_bundle \
  "toolkit-name" \
  "1.0.0" \
  "https://example.com/toolkit-name-1.0.0.tar.gz" \
  "<64 hexadecimal characters>" \
  "install.sh" \
  --installer-option
```

- The URL must be a plain `https://host[:port]/path` naming a `.tar.gz`,
  `.tgz`, `.tar.xz`, `.txz`, or `.zip` archive. Credentials, a query string, or
  a fragment are rejected, so none can reach a log or the installation state.
- The SHA-256 must be exactly 64 hexadecimal characters. Either case is
  accepted; it is compared and recorded in lowercase.
- Both are checked while the plan is read, so an invalid entry stops the run,
  `--dry-run` included, before anything is fetched.
- The entry runs in plan order through
  `server-bundle-install --source URL --sha256 SHA256`, with the installer name
  and arguments passed through unchanged.
- If the recorded state already holds the same version and checksum, the bundle
  is skipped without a download. The same version with a different checksum
  stops the run before downloading; only `server-bundle-install --force`, after
  review, installs over it.
- The download lives in a temporary directory removed after the run. Archive
  deletion applies to local files only.

`examples/provision-plan.remote.example.sh` holds one placeholder entry and is
preview-only:

```bash
./server-provision.sh --plan ./examples/provision-plan.remote.example.sh --dry-run
```

A dry run needs no root, writes no files, and makes no network request. Without
`--dry-run` the example stops while the plan is read, before the foundation is
installed or anything is written, deleted, or fetched. To use it as a template,
copy it, replace the placeholders, and delete its preview guard.

## Built-in profiles

An optional profile that ships inside the bootstrap archive is enabled by name:

```bash
enable_profile "ml" --backend auto
```

- A profile brings no URL, archive, or checksum of its own: it is part of the
  verified bootstrap archive.
- The only options are `--backend NAME` and `--reconfigure`. Anything else, an
  invalid name, or the same profile enabled twice stops the run while the plan
  is read, `--dry-run` included.
- After the archive is extracted and before the foundation is installed, the
  run stops if the archive does not carry the profile.
- Enabled profiles install after `server-accept` and before bundles, through
  `server-profile install NAME [options]`. A repeat run leaves an up-to-date
  profile as it is.

`examples/provision-plan.ml.example.sh`, also published beside each release,
installs the foundation and enables the `ml` profile. See
[ML-PROFILE](ML-PROFILE.md#one-command-install).

`examples/provision-plan.full.example.sh`, also published beside each release,
is the complete built-in stack and the README's first install path. It
exports every configurable installer switch the bootstrap defines as `1` (see
[CONFIGURATION](CONFIGURATION.md); the legacy `INSTALL_ADDON` is not a
built-in installer) and enables every built-in profile, today
`enable_profile "ml" --backend auto`. It installs no external bundle and sets
up no credential or service. A plan's exports win over the caller's
environment, so to leave a component out, edit its line in a copy of the plan.
The suite fails when an installer switch or a profile is added without a line
in this plan.

## Archive deletion

The default is:

```bash
DELETE_ARCHIVES_AFTER_SUCCESS=1
```

For each local archive, both the archive and its checksum sidecar are deleted
after installation and state recording succeed. A bundle archive remains in
place after any failure of its own installation or of an earlier stage. The
bootstrap archive is deleted as soon as the bootstrap succeeds, before the
acceptance check, so an acceptance (policy) rejection leaves it deleted; a
checksum, extraction or bootstrap failure leaves it in place.

For one debugging run:

```bash
sudo ./server-provision.sh --keep-archives
```

## Hardware acceptance policy

```bash
ACCEPT_POLICY=reject-stop   # default
ACCEPT_POLICY=warn-stop
ACCEPT_POLICY=off
```

- `reject-stop`: continue on warnings, stop on a hard rejection.
- `warn-stop`: continue only on a clean acceptance.
- `off`: skip the acceptance test.

Thresholds such as `MIN_RAM_GB`, `MIN_CORES`, `MIN_DISK_GB`, and `MIN_VRAM_MIB`
can be exported in the plan and are inherited by `server-accept`.

CPU, RAM, and disk are checked on every machine. The accelerator checks run only
when `nvidia-smi` is present, because a CPU-only host is a valid configuration.
Set `REQUIRE_ACCELERATOR=1` in the plan when the declared specification requires
a GPU, so that a machine without one is rejected.

## Direct one-bundle installation

After the bootstrap is installed:

```bash
server-bundle-install \
  --name toolkit-name \
  --version 1.0.0 \
  --archive ./toolkit-name-1.0.0.tar.gz \
  --sha256-file ./toolkit-name-1.0.0.tar.gz.sha256 \
  --delete-after-success \
  -- --installer-option
```

## Maintainer candidate validation

The `candidate-install` jobs in `.github/workflows/ci.yml` run after
`release-build`. Each uses its candidate commit, artifact ID and SHA-256 of the
candidate's `SHA256SUMS` as workflow outputs. Every scenario below runs in a
fresh Ubuntu 24.04 container on both x86-64 and ARM64: ten installation jobs.

| Scenario | Harness arguments and environment |
| --- | --- |
| Complete installation | `--scenario full` |
| Foundation only | `--scenario minimal` |
| Foundation and ML | `--scenario ml` |
| Complete installation with apt contention | `--scenario full`, `SB_TEST_CONTENTION=provider` |
| Same, with wget already installed | `--scenario full`, `SB_TEST_CONTENTION=provider`, `SB_TEST_PREINSTALL_WGET=1` |

For a release decision, download the artifact from the successful **branch-push
run** for the exact candidate commit; a pull-request run tests its synthetic
merge commit. Record the commit, run ID, artifact ID and manifest digest outside
the downloaded artifact. Export `SB_CAND_SHA` as that full commit,
`SB_CAND_SUMS_SHA` as the digest recorded by `release-build`, and
`SB_CANDIDATE_DIR` as the downloaded artifact directory. Do not obtain the
expected digest from the artifact being checked or commit candidate values to
the source tree.

From a checkout at that commit, verify the downloaded files before adding logs
to their directory:

```bash
python3 validation/verify-candidate.py --repo . --sha "$SB_CAND_SHA" \
  --candidate "$SB_CANDIDATE_DIR" --manifest-sha256 "$SB_CAND_SUMS_SHA"
```

This checks the exact published asset set, sidecars, standalone plans, ML locks,
and every archived file's bytes and mode against Git. Copy the verified files
and that commit's `validation/` scripts to a fresh test host. As root, export
the same provenance variables, with `SB_CANDIDATE_DIR` pointing to the host's
copy (default `/root/sb-candidate`), then run the appropriate scenario:

```bash
bash /validation/sb-candidate-test.sh --check --scenario full
bash /validation/sb-candidate-test.sh --scenario full
```

`--check` is a precheck only. Full acceptance runs the documented installation
block with only `BASE` changed to the verified candidate's loopback URL, checks
the stack, repeats the same plan and requires unchanged installed tools,
environment and stable state. Contention cases require an observed real apt
lock and wait, successful provider exit, installed `openssh-server`, and its
completed apt transaction without an error. Retain `RESULT: PASSED` and logs
from both stack checks; the required counts are:

| Host and plan | Stack checks before and after repeat | `ml-doctor` |
| --- | --- | --- |
| CPU full or ML | 29/29 | 36 passed, 0 failed, 0 skipped, 1 N/A |
| CPU foundation only | 20/20 | ML commands, environment and state absent |
| One-GPU full | 30/30 | 37 passed, 0 failed, 0 skipped, 0 N/A |

For a fresh GPU candidate test, set `SB_EXPECT_GPU=1` and run the full scenario.
It requires `cu130`, exact locked package versions, a 256 MiB CUDA allocation
and a matrix multiplication, including after the repeat.

After publication, use another fresh GPU host. Its boot payload must be the
exact Bash block under the tagged README's `## How to use`, retaining the
literal public `BASE` URL, with only this status line appended:

```bash
echo "exit=$?" > /root/sb-startup-status
```

Review the payload and its transport encoding before creating the host. Let
boot perform the installation and wait for the real status file. Set
`SB_STARTUP_SCRIPT` to the host's actual stored script path, then run
`SB_EXPECT_GPU=1 bash /validation/sb-candidate-test.sh --after-startup --scenario full`
with the verified candidate provenance and files. This requires `exit=0`,
stored-script identity, downloaded-file identity, stack checks and the repeat;
`--after-startup --check` alone is not full acceptance. If the host prepends
`#!/bin/bash` or `#!/usr/bin/env bash`, review and approve the complete stored
script before boot and supply its out-of-band SHA-256 as
`SB_STARTUP_SCRIPT_SHA`. That mode permits only the exact payload, optionally
preceded by one of those shebangs; arbitrary wrappers are rejected even when
hashed. Keep private wrapper contents out of logs.
Also verify the host's provider apt transaction completed without errors,
SSH transport works and the NVIDIA drivers are intact. Preserve candidate
provenance when comparing PR-head, main and public assets; carry GPU evidence
forward only after all published assets compare byte for byte.
