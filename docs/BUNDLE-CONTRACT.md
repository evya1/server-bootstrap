# Bundle contract

A compatible workload or configuration bundle is a `.tar.gz`, `.tgz`, `.tar.xz`, `.txz`, or `.zip`
archive containing exactly one configured installer filename, normally
`install.sh`.

Recommended layout:

```text
toolkit-name-1.0.0/
├── VERSION
├── README.md
├── install.sh
└── ...
```

## Installer requirements

The installer should:

- run non-interactively as root;
- be idempotent;
- use isolated environments for language packages;
- preserve user configuration unless an explicit replacement flag is supplied;
- return nonzero on failure;
- perform a lightweight post-install check;
- avoid starting long workloads or exposing public ports automatically.

If `VERSION` exists beside the installer, `server-bundle-install` requires it to
match the registered version.

## State and upgrades

Successful installations record:

```text
/workspace/.setup-state/bundles/<name>/version
/workspace/.setup-state/bundles/<name>/archive-sha256
/workspace/.setup-state/bundles/<name>/source
/workspace/.setup-state/bundles/<name>/installer
/workspace/.setup-state/bundles/<name>/installed-at
```

A version change is treated as an upgrade. Reusing the same version with changed
bytes is blocked by default because it is not a reproducible release.

## Archive safety

The shared extractor rejects absolute member names, parent traversal, backslash
paths, absolute symlinks, and symlinks resolving outside the extraction root.
The exact SHA-256 is verified before extraction.
