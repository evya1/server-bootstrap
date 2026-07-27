# Provisioning plans

A plan is a small Bash data file sourced by `gpu-provision.sh`. It should contain
configuration exports plus registration calls; it should not perform downloads
or installation itself.

## Bootstrap registration

```bash
register_bootstrap \
  "./gpu-server-bootstrap-1.4.0.tar.gz" \
  "./gpu-server-bootstrap-1.4.0.tar.gz.sha256"
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
sudo ./gpu-provision.sh --keep-archives
```

## GPU acceptance policy

```bash
GPU_ACCEPT_POLICY=reject-stop   # default
GPU_ACCEPT_POLICY=warn-stop
GPU_ACCEPT_POLICY=off
```

- `reject-stop`: continue on warnings, stop on a hard rejection.
- `warn-stop`: continue only on a clean acceptance.
- `off`: skip the acceptance test.

Thresholds such as `MIN_VRAM_MIB`, `MIN_RAM_GB`, and `MIN_CORES` can be exported
in the plan and are inherited by `gpu-accept`.

## Direct one-bundle installation

After the bootstrap is installed:

```bash
gpu-bundle-install \
  --name toolkit-name \
  --version 1.0.0 \
  --archive ./toolkit-name-1.0.0.tar.gz \
  --sha256-file ./toolkit-name-1.0.0.tar.gz.sha256 \
  --delete-after-success \
  -- --installer-option
```
