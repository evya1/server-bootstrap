# Provisioning plans

A plan is a small Bash data file sourced by `server-provision.sh`. It should contain
configuration exports plus registration calls; it should not perform downloads
or installation itself.

## Bootstrap registration

```bash
register_bootstrap \
  "./server-bootstrap-2.0.1.tar.gz" \
  "./server-bootstrap-2.0.1.tar.gz.sha256"
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
