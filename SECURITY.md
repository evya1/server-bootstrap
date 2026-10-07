# Security policy

## Reporting a vulnerability

Report suspected vulnerabilities or exposed credentials privately through
GitHub's [security advisory][advisory] form rather than in a public issue or
pull request. Please do not include the credential value itself in the report:
a reference to the file, commit, or release asset is enough to act on.

[advisory]: https://github.com/evya1/server-bootstrap/security/advisories/new

## Installation trust

The archive checksum is verified before extraction. Downloading an archive and
its `.sha256` from the same origin establishes integrity, not authenticity:
it detects a truncated or corrupted transfer, but someone who can publish a
release can replace both. Trust depends on HTTPS and control of the publishing
account, including account 2FA. Pin an independently reviewed expected SHA-256
in your own provision plan for remote bundles.

Pinned Node.js, uv, `gh` and ngrok downloads are checked against SHA-256 values
recorded in this repository before use. The AI CLIs are exact-version npm
installs whose integrity comes from npm and the registry; their installed
versions are read back and verified. Oh My Zsh is fetched at an exact commit
and Git `HEAD` is checked. No upstream installer script is run.

Choosing `latest` is an explicit opt-in. For binary artifacts, the expected
hash then comes from the publisher's checksum manifest fetched over HTTPS at
run time, so it carries the same integrity and authenticity limits as an
archive and sidecar from one origin. Pinned versions remain the default.

## Installation guarantees

- Archives with absolute paths, parent traversal or escaping symlinks are
  rejected. Remote bundle sources and the npm registry must use HTTPS; a
  remote bundle names an exact version and SHA-256.
- API keys live in one root-owned file at mode 0600. It is parsed, never
  sourced, so command-shaped text in a value remains data. Empty keys are
  not exported. See [API key configuration](docs/CONFIGURATION.md#api-keys).
- AI CLI packages are isolated in `/opt/ai-cli`. Installation state records
  versions and completion. Local archives and sidecars are removed only
  after their own installation succeeds, according to the plan's retention
  policy; see [archive deletion](docs/PROVISIONING.md#archive-deletion).
- Hardware acceptance runs before profiles and workload bundles. No workload
  or public service starts automatically, and no model or dataset is
  downloaded. File transfers and tunnels require explicit configuration.
- Package names are validated before reaching apt. Each real apt attempt is
  simulated and refused if it would change an installed NVIDIA driver or CUDA
  package. Another apt process can still change the plan between simulation
  and execution; see [driver protection](docs/CONFIGURATION.md#nvidia-driver-and-cuda-packages).
- Release archives and their manifest are built twice and compared byte for
  byte. File modes are normalised to 0644 or 0755 from Git's executable flags,
  so checkout permissions and the builder's umask do not change archive bytes.
  See [Security scanning](docs/SECURITY-SCANNING.md) for the release scans and
  exact asset checks before publication.

## History preservation and remediation

**Security fixes in this repository are additive. Published Git history is never
rewritten.** Scanning only works if the commits it scans still exist, so
remediation adds commits rather than removing evidence.

### Not permitted for security remediation

- `git filter-repo`, `git filter-branch`, or BFG Repo-Cleaner.
- `git reset` or `git rebase` of commits that have already been published.
- Force-pushing any branch (`--force`, `--force-with-lease`).
- Replacing, moving, or deleting an existing release tag.
- Deleting published release assets or GitHub Releases as a substitute for
  remediation.
- Broadening the scanner allowlist so that a preserved finding stops failing
  the build.

The last two are the tempting ones. Deleting an asset hides the artifact but not
the credential, and a wildcard allowlist entry silences the finding everywhere,
including for the next real one.

### Required instead

1. **Rotate first, out of band.** If a real credential is found, revoke and
   reissue it through the owning service immediately. Do this before any commit,
   issue comment, or release note is written. Exposure ends when the credential
   stops working, not when the file is deleted.
2. **Remediate with a new commit.** Remove the credential from the working tree
   and land it as an ordinary commit on a branch, through the normal pull
   request and CI path.
3. **Record the incident without republishing the secret.** Reference the commit
   or asset. Never paste the value into an issue, a commit message, a log, a
   release note, or a test fixture.
4. **Leave the affected commits and tags in place.** They remain reachable so
   the full-history scan keeps covering them and so anyone auditing the incident
   can see what actually happened.

### Why an exposed credential is not deleted from history

Rewriting history to remove a leaked credential changes every commit ID after
the rewrite, invalidates existing clones and forks, breaks published tags and
release provenance, and still does not recover the secret: anyone who fetched
the repository, and any mirror or cache, already has it. The credential has to
be treated as compromised regardless. Given that, the honest move is to rotate
it and keep the history intact and scannable.

An owner-approved incident process may reach a different conclusion for a
specific incident. That decision belongs to the repository owner, is recorded in
the advisory, and is not the default path this document describes.

## Fixture and test-data rule

Never commit a key-shaped string, including as a test fixture or documentation
example. The `secret-scan` CI job is blocking and reads complete history, so a
committed fake token fails every subsequent build and could only be removed by
rewriting history, which this policy forbids.

Tests that need a credential-shaped value build it at runtime in a temporary
directory, assert against it, and delete it. See `tests/run-tests.sh` and
`tools/verify-history-scan.sh` for the pattern.

## How this is enforced

| Control | Where |
| --- | --- |
| Complete-history secret scan, fails closed | `.github/workflows/ci.yml` (`secret-scan`) |
| Proof that an older-commit secret is caught | `tools/verify-history-scan.sh` |
| One pinned, checksum-verified scanner | `tools/gitleaks.sh` |
| Credential filenames, private keys, tracked build output | `tests/privacy-guard.sh` |
| Release staging and extracted-archive scans | `release/build-release.sh` |
| Final artifact scan before upload | `.github/workflows/release.yml` |
| `release/dist` holds exactly the verified release assets before upload | `release/release-assets.sh` |
| Allowlist scope | `.gitleaks.toml`, `docs/SECURITY-SCANNING.md` |

The scanner allowlist is deliberately small and holds only exact, reviewed
example values. Adding to it requires a specific value, a deterministic test,
and a review note — never a file, directory, URL class, IP range, or
environment-variable class. See `docs/SECURITY-SCANNING.md`.
