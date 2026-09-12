#!/usr/bin/env bash
# Ready example for the current bootstrap and Whisper toolkit releases.
# A provision plan is a DATA file read by server-provision.sh, not a script to run.

if ! declare -F register_bootstrap >/dev/null 2>&1; then
    echo "ERROR: this is a plan (data) file for server-provision.sh, not a script to run." >&2
    echo "Run:   ./server-provision.sh --plan $0" >&2
    exit 2
fi

# Set these to the specifications promised by the rental provider.
export MIN_VRAM_MIB=0
export MIN_CORES=0
export MIN_RAM_GB=0
export MIN_DISK_GB=50
export ACCEPT_POLICY=reject-stop
export DELETE_ARCHIVES_AFTER_SUCCESS=1

# Whisper installation uses uv. Nothing here requires a different uv from the
# one the bundle pins and checksum-verifies, so this plan does not restate the
# version: a second copy is a second thing to bump, and this one went stale.
export INSTALL_UV=1

register_bootstrap \
  "./server-bootstrap-2.2.3.tar.gz" \
  "./server-bootstrap-2.2.3.tar.gz.sha256"

register_bundle \
  "whisper-toolkit" \
  "3.1.0" \
  "./whisper-toolkit-3.1.0.tar.gz" \
  "./whisper-toolkit-3.1.0.tar.gz.sha256" \
  "install.sh" \
  --force --replace-settings --replace-prompt

# Add future bundles here. A personal configuration bundle should usually be last.
