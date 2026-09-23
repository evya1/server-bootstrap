#!/usr/bin/env bash
# Example: one checksum-pinned remote bundle. Preview it with --dry-run.
# A provision plan is a DATA file read by server-provision.sh, not a script to run.

if ! declare -F register_bootstrap >/dev/null 2>&1; then
    echo "ERROR: this is a plan (data) file for server-provision.sh, not a script to run." >&2
    echo "Run:   ./server-provision.sh --plan $0" >&2
    exit 2
fi

register_bootstrap \
  "./server-bootstrap-2.2.3.tar.gz" \
  "./server-bootstrap-2.2.3.tar.gz.sha256"

# The URL and SHA-256 below are placeholders, so this entry installs nothing:
# the all-zero checksum matches no archive and a real run stops at verification.
# Replace both with the archive's published HTTPS address and the SHA-256 you
# reviewed. The URL may not carry credentials, a query string, or a fragment.
register_remote_bundle \
  "example-toolkit" \
  "1.0.0" \
  "https://example.com/example-toolkit-1.0.0.tar.gz" \
  "0000000000000000000000000000000000000000000000000000000000000000" \
  "install.sh"
