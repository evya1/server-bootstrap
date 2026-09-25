#!/usr/bin/env bash
# Example: the complete built-in stack from one checksum-pinned server-bootstrap
# release. The foundation with every configurable installer enabled, then
# every built-in profile. The README's first install block runs this plan.
# A provision plan is a DATA file read by server-provision.sh, not a script to run.

if ! declare -F register_bootstrap >/dev/null 2>&1; then
    echo "ERROR: this is a plan (data) file for server-provision.sh, not a script to run." >&2
    echo "Run:   ./server-provision.sh --plan $0" >&2
    exit 2
fi

# Set these to the host's declared or required specification. server-accept
# checks free space under /workspace after the foundation is installed and
# before the ml profile. 30 GB is the profile's own minimum for a CUDA backend,
# which --backend auto selects on an NVIDIA host: room for the environment, its
# download cache, and a replacement built beside it during an update. The CPU
# backend needs 10 GB.
export MIN_VRAM_MIB=0
export MIN_CORES=0
export MIN_RAM_GB=0
export MIN_DISK_GB=30
export ACCEPT_POLICY=reject-stop

# Keep the verified archive beside this plan, so the same command can be run
# again: a repeat finds the foundation and the ml environment current and
# rebuilds neither.
export DELETE_ARCHIVES_AFTER_SUCCESS=0

# Every configurable built-in installer, enabled explicitly rather than left to
# the bootstrap defaults. The suite fails when lib/bootstrap/config.sh gains an
# INSTALL_* installer, or profiles/ a profile, that this plan does not enable.
# A component without a switch is installed by every bootstrap run.
# Distribution packages come from the shipped config/packages.txt, [required]
# as one batch and [optional] best effort. No tool version is restated here: a
# plan is sourced before the bootstrap runs, so a pin here would win over the
# bundle's.
export INSTALL_ZSH=1
export INSTALL_OH_MY_ZSH=1
export INSTALL_NODEJS=1
export INSTALL_CLAUDE_CODE=1
export INSTALL_CODEX=1
export INSTALL_PI=1
export INSTALL_VSCODE_EXTENSIONS=1
export INSTALL_UV=1
export INSTALL_GITHUB_CLI=1
export INSTALL_BASE_PYTHON_ENV=1
export INSTALL_RUNTIME_TOOLS=1
export INSTALL_SECRETS_FILE=1
export INSTALL_PI_MODELS_TEMPLATE=1

register_bootstrap \
  "./server-bootstrap-2.2.3.tar.gz" \
  "./server-bootstrap-2.2.3.tar.gz.sha256"

# Every built-in profile. ml ships inside that archive, with its frozen locks:
# no separate URL, version, archive or checksum. auto installs the CPU backend
# on a host without an NVIDIA GPU. On an NVIDIA host it installs the newest
# locked CUDA backend the driver supports, and fails rather than fall back to
# CPU if none does. To change backend on an installed host, name it and add
# --reconfigure, for example:
#
#   enable_profile "ml" --backend cpu --reconfigure
enable_profile "ml" --backend auto
