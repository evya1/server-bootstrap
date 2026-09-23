# Provisioning plans

A plan is a small Bash data file sourced by `server-provision.sh`. It should contain
configuration exports plus registration calls; it should not perform downloads
or installation itself.

## Bootstrap registration

```bash
register_bootstrap \
  "./server-bootstrap-2.2.3.tar.gz" \
  "./server-bootstrap-2.2.3.tar.gz.sha256"
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

## Archive deletion

The default is:

```bash
DELETE_ARCHIVES_AFTER_SUCCESS=1
```

For each local archive, both the archive and its checksum sidecar are deleted
after installation and state recording succeed. They remain in place after a
checksum, extraction, installer, or policy failure.

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
when `nvidia-smi` is present, because a CPU-only box is a legitimate rental. Set
`REQUIRE_ACCELERATOR=1` in the plan when you are paying for a GPU and a machine
without one is a failed delivery.

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
