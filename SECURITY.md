# Security policy

## Reporting a vulnerability

Report suspected vulnerabilities or exposed credentials privately through
GitHub's [security advisory][advisory] form rather than in a public issue or
pull request. Please do not include the credential value itself in the report:
a reference to the file, commit, or release asset is enough to act on.

[advisory]: https://github.com/evya1/server-bootstrap/security/advisories/new

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
| Allowlist scope | `.gitleaks.toml`, `docs/SECURITY-SCANNING.md` |

The scanner allowlist is deliberately small and holds only exact, reviewed
example values. Adding to it requires a specific value, a deterministic test,
and a review note — never a file, directory, URL class, IP range, or
environment-variable class. See `docs/SECURITY-SCANNING.md`.
