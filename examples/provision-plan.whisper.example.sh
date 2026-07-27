#!/usr/bin/env bash
# Ready example for the current bootstrap and Whisper toolkit releases.
# A provision plan is a DATA file read by gpu-provision.sh, not a script to run.

if ! declare -F register_bootstrap >/dev/null 2>&1; then
    echo "ERROR: this is a plan (data) file for gpu-provision.sh, not a script to run." >&2
    echo "Run:   ./gpu-provision.sh --plan $0" >&2
    exit 2
fi

# Set these to the specifications promised by the rental provider.
export MIN_VRAM_MIB=0
export MIN_CORES=0
export MIN_RAM_GB=0
export MIN_DISK_GB=50
export GPU_ACCEPT_POLICY=reject-stop
export DELETE_ARCHIVES_AFTER_SUCCESS=1

# Whisper installation uses this pinned and checksum-verified uv release.
export INSTALL_UV=1
export UV_VERSION=0.9.2
export UV_SHA256=b775bb84c72210c6c0b9670cfaad0ac2e3953f12a2947d52b57603b4fbae3798

register_bootstrap \
  "./gpu-server-bootstrap-1.4.0.tar.gz" \
  "./gpu-server-bootstrap-1.4.0.tar.gz.sha256"

register_bundle \
  "whisper-toolkit" \
  "3.1.0" \
  "./whisper-toolkit-3.1.0.tar.gz" \
  "./whisper-toolkit-3.1.0.tar.gz.sha256" \
  "install.sh" \
  --force --replace-settings --replace-prompt

# Add future bundles here. A personal configuration bundle should usually be last.
