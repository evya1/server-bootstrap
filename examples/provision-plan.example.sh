#!/usr/bin/env bash
# A provision plan is a DATA file read by gpu-provision.sh, not a script to run.
# Paths are resolved relative to this plan file.

if ! declare -F register_bootstrap >/dev/null 2>&1; then
    echo "ERROR: this is a plan (data) file for gpu-provision.sh, not a script to run." >&2
    echo "Run:   ./gpu-provision.sh --plan $0" >&2
    exit 2
fi

# Optional server requirements checked before workload installation.
# Set these to the specifications promised by the rental provider.
export MIN_VRAM_MIB=0
export MIN_CORES=0
export MIN_RAM_GB=0
export MIN_DISK_GB=50
export GPU_ACCEPT_POLICY=reject-stop
export DELETE_ARCHIVES_AFTER_SUCCESS=1

# Optional pinned uv installation. Leave INSTALL_UV=0 until both values are set.
export INSTALL_UV=1
export UV_VERSION=0.9.2
export UV_SHA256=b775bb84c72210c6c0b9670cfaad0ac2e3953f12a2947d52b57603b4fbae3798

register_bootstrap \
  "./gpu-server-bootstrap-1.4.0.tar.gz" \
  "./gpu-server-bootstrap-1.4.0.tar.gz.sha256"

# As shipped this plan installs the server foundation only, so it runs green on
# a fresh box with nothing else downloaded. Uncomment and edit the block below
# once you actually have a workload archive and its .sha256 sitting beside this
# file; a register_bundle line naming an archive that is not present aborts the
# run after the bootstrap has already installed.
#
# register_bundle \
#   "example-toolkit" \
#   "1.0.0" \
#   "./example-toolkit-1.0.0.tar.gz" \
#   "./example-toolkit-1.0.0.tar.gz.sha256" \
#   "install.sh"
#
# Bundles install in registration order. Put a shared runtime before anything
# that reuses it, and a personal configuration bundle last.
