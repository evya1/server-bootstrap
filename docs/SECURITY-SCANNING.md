# Security scanning

CI scans the complete Git history with Gitleaks and a pinned v8.30.1 release.
Release work must also scan staged and unpacked artifacts before publication.

The repository allowlist is intentionally small and covers only harmless example
values already used by the project: `/root`, `/workspace`, `localhost`, loopback
addresses (`127.0.0.1` and `::1`), example domains, and clearly labeled values
such as `CHANGE_ME` and `EXAMPLE_TOKEN`. It is not a substitute for reviewing a
new finding.

Future additions should be rare and narrowly scoped. A typical use case is a new
documentation example that needs a non-secret local path or loopback endpoint.
Add the exact value, a deterministic test, and a review note; never allow an
entire file, directory, URL class, IP range, or environment-variable class.
