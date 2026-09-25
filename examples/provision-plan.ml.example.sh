#!/usr/bin/env bash
# Example: the server foundation and its built-in ml profile, from one
# checksum-pinned server-bootstrap release.
# A provision plan is a DATA file read by server-provision.sh, not a script to run.

if ! declare -F register_bootstrap >/dev/null 2>&1; then
    echo "ERROR: this is a plan (data) file for server-provision.sh, not a script to run." >&2
    echo "Run:   ./server-provision.sh --plan $0" >&2
    exit 2
fi

# Set these to the host's declared or required specification. The ml
# profile's own free space is not declared here: the profile checks it before
# any run that builds, 30 GB for a CUDA backend and 10 GB for CPU, and not on a
# repeat that keeps its environment. server-accept checks MIN_DISK_GB on every
# run, a repeat included, so a value here would reject a repeat once the first
# install had used that space. Raise it for the host's own data.
export MIN_VRAM_MIB=0
export MIN_CORES=0
export MIN_RAM_GB=0
export MIN_DISK_GB=0
export ACCEPT_POLICY=reject-stop

# Keep the verified archive beside this plan, so the same command can be run
# again: a repeat finds the foundation and the ml environment current and
# rebuilds neither.
export DELETE_ARCHIVES_AFTER_SUCCESS=0

# The ml profile builds its environment with the uv this bundle pins and
# checksum-verifies. This plan does not restate its version.
export INSTALL_UV=1

register_bootstrap \
  "./server-bootstrap-2.2.3.tar.gz" \
  "./server-bootstrap-2.2.3.tar.gz.sha256"

# The ml profile ships inside that archive, with its frozen locks: no separate
# URL, version, archive or checksum. auto installs the CPU backend on a host
# without an NVIDIA GPU. On an NVIDIA host it installs the newest locked CUDA
# backend the driver supports, and fails rather than fall back to CPU if none
# does. To change backend on an installed host, name it and add --reconfigure,
# for example:
#
#   enable_profile "ml" --backend cpu --reconfigure
enable_profile "ml" --backend auto
