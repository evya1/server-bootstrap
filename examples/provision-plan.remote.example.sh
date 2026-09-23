#!/usr/bin/env bash
# Example: one checksum-pinned remote bundle. Preview-only: run it with --dry-run.
# A provision plan is a DATA file read by server-provision.sh, not a script to run.

if ! declare -F register_bootstrap >/dev/null 2>&1; then
    echo "ERROR: this is a plan (data) file for server-provision.sh, not a script to run." >&2
    echo "Run:   ./server-provision.sh --plan $0" >&2
    exit 2
fi

# server-provision.sh reads the plan before it does anything else, so refusing
# here stops a run without --dry-run before the foundation is installed, a log
# or lock is written, an archive is deleted, or anything is fetched. To use this
# file as a template, copy it, replace the placeholders below, and delete this
# block.
if [[ "${DRY_RUN:-0}" != 1 ]]; then
    echo "ERROR: this example plan is preview-only; run it with --dry-run." >&2
    echo "To install a real bundle, copy it, replace the placeholder URL and SHA-256, and delete its preview guard." >&2
    exit 2
fi

register_bootstrap \
  "./server-bootstrap-2.2.3.tar.gz" \
  "./server-bootstrap-2.2.3.tar.gz.sha256"

# The URL and SHA-256 below are placeholders for the preview. Replace both with
# the archive's published HTTPS address and the SHA-256 you reviewed. The URL
# may not carry credentials, a query string, or a fragment.
register_remote_bundle \
  "example-toolkit" \
  "1.0.0" \
  "https://example.com/example-toolkit-1.0.0.tar.gz" \
  "0000000000000000000000000000000000000000000000000000000000000000" \
  "install.sh"
