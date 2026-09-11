# Security scanning

CI scans the complete Git history with Gitleaks. The version and its release
checksum are pinned in `tools/gitleaks.sh`, which is the only pin in the
repository: CI, `release/build-release.sh`, and the release workflow all scan
through it, so the scanner cannot drift between them.

The release build scans the source staging tree and every extracted archive, and
the release workflow scans `release/dist` again immediately before upload. That
last pass descends into the archives — a flat scan of a directory of tarballs
reads zero bytes and would pass anything.

Findings are remediated with new commits. Published history is never rewritten
and the allowlist is never broadened to silence a preserved finding; see
[SECURITY.md](../SECURITY.md).

The repository allowlist is intentionally small and covers only harmless example
values already used by the project: `/root`, `/workspace`, `localhost`, loopback
addresses (`127.0.0.1` and `::1`), example domains, and clearly labeled values
such as `CHANGE_ME` and `EXAMPLE_TOKEN`. It is not a substitute for reviewing a
new finding.

Future additions should be rare and narrowly scoped. A typical use case is a new
documentation example that needs a non-secret local path or loopback endpoint.
Add the exact value, a deterministic test, and a review note; never allow an
entire file, directory, URL class, IP range, or environment-variable class.
