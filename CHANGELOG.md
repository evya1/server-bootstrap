# Changelog

## Unreleased

Nothing merged since 2.2.3.

## 2.2.3

*Released 2026-09-12.*

A release-engineering release. Nothing about what gets installed on a server
changes except one pinned agent version — the work is in making the release
itself verifiable, and in closing the gaps that let a broken release reach a tag
in the first place.

The short version of what is now true that was not before:

- **The release file set is canonical.** One definition, resolved from the
  tracked files, feeds the checksum manifest, the tar, the source stage and the
  tests. `checksums/SHA256SUMS` is verified *exactly* — extra, missing,
  duplicate, stale, malformed and misordered entries are all rejected. An
  untracked scratch file can no longer be packed into a release archive.
- **Every pinned value is checked against every file that records it.**
  `tools/check-pins.sh` maps 13 pins across 59 recordings offline, with each
  architecture anchored to its own label, so a half-applied bump or a swapped
  x64/arm64 pair fails in CI instead of shipping.
- **The example plans inherit the bundle's uv pin** instead of restating a
  stale one. Both shipped plans had pinned uv `0.12.12` against a bundle pinned
  to `0.12.13`, so the documented quick start installed an older uv than the
  release did.
- **Pin drift has meaningful exit codes and a weekly job.** `0` nothing
  actionable, `1` a release pin is behind, `2` usage, `3` an upstream could not
  be resolved — so a run whose network broke cannot read as a clean week. A
  moved Oh My Zsh branch head is reported, not failed. A weekly workflow keeps
  **one** issue open while a pin is behind rather than filing a new one.
- **One shared release preflight.** `tools/release-preflight.sh` holds every
  pre-publication gate, and CI runs the same script on every push — once
  normally, once inside a manufactured tag-shaped checkout. There is no
  release-only code path left to discover at tag time.
- **Every GitHub Action is pinned to an immutable commit SHA** with a readable
  version comment, permissions are scoped per job, and Dependabot keeps those
  pins on an update channel. `actions/checkout` is on `v7.0.1` and
  `softprops/action-gh-release` on `v3.0.3`; this release is the first
  production run of the latter.
- **Claude Code is pinned to `2.1.269`** (from `2.1.268`). Node.js `24.21.0`,
  `gh` `2.100.0`, uv `0.12.13`, Codex `0.154.0` and pi `0.85.1` were each
  confirmed current against upstream and are unchanged.
- **Documentation says what the code does.** Three claims that had stopped being
  true were corrected, and an empty code fence that rendered as a blank box in
  the README is gone.
- **A stale checksum manifest now explains itself.** Every Dependabot pull
  request edits a tracked workflow file and cannot regenerate the manifest, so it
  arrived red in a way indistinguishable from a real incompatibility. The
  failure now names the one command that fixes it and prints the exact patch,
  without weakening any verification or granting any new permission.

### Merged after the 2.2.2 release, previously unrecorded

- **[#20][]** — `README.md`'s five tool versions are asserted against the pinned
  defaults in `lib/bootstrap/config.sh`, and `tools/refresh-pins.sh --write`
  rewrites them. Before it, a pin bump left the README quietly wrong.
- **[#21][]** — three stale pins refreshed: uv `0.12.12` → `0.12.13`, Claude
  Code `2.1.267` → `2.1.268`, and the Oh My Zsh ref `cd320b55` → `c6e66ede`.
- **[#22][]** — `ci.yml`'s `tag-checkout` job. `release.yml` runs only on a tag
  push, so its checkout is detached, one commit deep, and carries one tag; CI
  saw that shape only on the tag push itself, which is after the version number
  has been spent. The job manufactures it on every push and pull request. It
  rehearses the Git *metadata* a tag build sees, not the tag event.

[#20]: https://github.com/evya1/server-bootstrap/pull/20
[#21]: https://github.com/evya1/server-bootstrap/pull/21

### Added

- **`tools/check-pins.sh`** — one exact, keyed map of every pinned value against
  every file that records it: `lib/bootstrap/config.sh` (canonical),
  `config.example.env`, `checksums/*.txt`, `README.md` and
  `docs/CONFIGURATION.md`. Each recording must be present exactly once, be well
  formed, and equal the canonical value, with every architecture anchored to its
  own label. Before it, a zeroed uv checksum, a swapped x64/arm64 pair, a
  manifest-only edit and a two-release-stale `docs/CONFIGURATION.md` all passed
  the suite, while a *correct* coordinated bump of Node.js, Claude Code or Codex
  failed it until somebody hand-edited a test literal. ([#23])

### Changed

- **`actions/checkout` upgraded to `v7.0.1`**
  (`3d3c42e5aac5ba805825da76410c181273ba90b1`), from `v4.4.0`, in all three
  workflows. The three intervening majors are a runtime move and two hardening
  changes, none of which touches how this repository uses the action: `v5.0.0`
  moved the runtime from Node 20 to Node 24; `v6.0.0` persists credentials to a
  separate file, a path every job here opts out of with
  `persist-credentials: false`; `v7.0.0` blocks checking out fork PRs for
  `pull_request_target` and `workflow_run`, neither of which appears in any
  workflow here. Every input, default and output is byte-identical between the
  two versions — the only `action.yml` change is `using: node20` →
  `using: node24`. GitHub already forces the old pin onto Node 24 and warns that
  Node 20 is deprecated, so this aligns the declared runtime with what has been
  executing. ([#36])
- **`softprops/action-gh-release` upgraded to `v3.0.3`**
  (`efb35369e0ad2afab669f228072c1b0d510eae64`), from `v2.6.2`, in the release
  workflow's one `Publish assets` step. The SHA is the peeled commit of the
  annotated `v3.0.3` tag (`refs/tags/v3.0.3^{}`), confirmed against upstream
  rather than against the pull request body. As with `actions/checkout`, the
  only `action.yml` difference across the three majors is `using: node20` →
  `using: node24`: every input, default, `required:` flag and output is
  byte-identical, and `contents: write` remains the only permission either
  version documents. The glob resolver `paths()` in `src/util.ts` is unchanged,
  so the eight `files:` patterns match exactly what they matched before, and
  `token` still takes the explicit input this workflow passes.

  The substantial change is in `src/github.ts`, where release creation, draft
  reuse and asset replacement were refactored, plus a new `finalizeRelease()`.
  That function returns immediately when `release.draft === false`, which is
  this workflow's case — it sets no `draft` input — so the new draft-reuse and
  tag-creation-blocked paths are unreachable here. `v2.6.2` was upstream's last
  Node 20 release and is no longer maintained; `v3.0.2` also carries *"upload
  small checksum assets reliably"*, which is the shape of the four `.sha256`
  sidecars this workflow uploads. No security advisory is published against
  either version.

  This cannot be exercised without publishing a real release, and this
  repository must not create a throwaway tag to try, so the first production
  execution is the release cut immediately after this merge. ([#35])
- **Claude Code pinned to `2.1.269`**, from `2.1.268`. Applied with
  `tools/refresh-pins.sh --write`, which rewrote all five surfaces that record
  it: `lib/bootstrap/config.sh`, `config.example.env`,
  `checksums/AI_CLI_VERSIONS.txt`, `README.md` and `docs/CONFIGURATION.md`.
  Nothing else moved — Node.js `24.21.0`, `gh` `2.100.0`, uv `0.12.13`, Codex
  `0.154.0` and pi `0.85.1` were each confirmed current against their own
  upstream, and the Oh My Zsh branch head was deliberately left at `c6e66ede`
  even though it has moved to `be8da5c7`: it is a `branch-head` pin, so
  movement is reported and not actioned, and `--write` was run without `--all`.

  What that pin buys, stated precisely: Claude Code is an **exact-version npm
  install**, so its integrity comes from the npm registry — `npm` resolves
  `@anthropic-ai/claude-code@2.1.269` and checks the downloaded tarball against
  the SHA-512 `dist.integrity` the registry publishes for that exact version.
  **No SHA-256 in this repository covers it**, unlike the Node.js, uv and `gh`
  archives. What the bootstrap adds on top is a post-install check:
  `bootstrap_verify_npm_package_version()` reads the installed `package.json`
  back and fails the run if npm did not install the exact version requested.
  ([#38])
- **The example plans no longer restate the uv pin.** A plan is sourced by
  `server-provision.sh` before the bootstrap runs, so an exported `UV_VERSION`
  in a plan beats the bundle default. Both shipped plans pinned uv `0.12.12`
  with its checksums against a bundle pinned to `0.12.13`, which meant the
  documented quick start installed an older uv than the release. Neither plan
  needed its own pin; both now inherit the bundle's. If a plan ever does need an
  independent pin, `tools/check-pins.sh` requires it to be declared, mapped and
  covered by the updater. ([#23])
- **`tools/refresh-pins.sh --write` also rewrites `docs/CONFIGURATION.md`**, and
  the rewrite logic moved to `tools/write-pins.py` so a coordinated bump can be
  tested offline against a scratch tree. Its documented file list was wrong in
  three places — `README.md`, `docs/CONFIGURATION.md` and the script's own
  `--help` — all of which had said "config.sh, config.example.env, checksums/"
  since #20 taught it to rewrite `README.md` too. ([#23])
- **`tests/run-tests.sh` no longer hardcodes any pinned value.** The literal
  Node.js, Claude Code and Codex assertions became shape assertions; the value
  check now lives in the map. The `README` pin section is subsumed by it and was
  removed. A standing assertion fails if a 40- or 64-hex literal reappears in
  the suite outside the synthetic manifest-parser fixture. ([#23])

- **`release/release-files.sh`** — one canonical definition of which files are
  part of a release, used by the checksum manifest, the tar, the source stage
  and the tests. It resolves the set from `git ls-files` in a checkout, and from
  the shipped `checksums/SHA256SUMS` in an unpacked source bundle with no
  `.git`, announcing which. `verify` compares the committed manifest exactly and
  distinguishes extra, missing, duplicate, stale, malformed and misordered
  entries, capped at 20 findings. ([#24])

- **`tools/release-preflight.sh`** — every release-critical pre-publication
  step in one script: the tag check, the pinned Gitleaks, the reproducible
  build, and the pre-upload artifact scan. `release.yml` and two `ci.yml` jobs
  call it, so there is no release-only code path left to detect. ([#26])
- **`tools/check-release-tag.sh`** — the "Verify tag matches VERSION" logic,
  moved out of inline workflow shell into a script that takes the candidate tag
  as an argument. It accepts only `v<major>.<minor>.<patch>` with no leading
  zeros and no prerelease or build-metadata suffix. ([#26])
- **`tools/actionlint.sh`** — a pinned, checksum-verified workflow linter, in
  the shape of `tools/gitleaks.sh`, run as a blocking CI step. ([#26])

- **`.github/workflows/pin-drift.yml`** — a weekly, manually dispatchable check
  that keeps **one** issue open while a pinned release is behind, editing it
  rather than filing a new one each week, and closing it when the pins are
  current again. A moved Oh My Zsh branch head never opens it. A week where an
  upstream could not be resolved files the issue with an explicit "this report
  is incomplete" banner **and fails the run**, because a check that could not
  check must not show a green tick. The branch decision lives in
  `tools/pin-drift-report.sh` as a pure function the offline suite drives
  through all ten (exit code, issue open) combinations. ([#28])
- **`.github/dependabot.yml`** — weekly `github-actions` updates, so a SHA pin
  has an update channel instead of quietly rotting. ([#27])
- **`tools/manifest-fix-hint.sh`** — when a run fails because
  `checksums/SHA256SUMS` is stale, this prints the single command that repairs
  it and the exact patch that command produces. Every Dependabot pull request
  opens in that state: it edits a tracked `.github/workflows/*.yml`, which is
  part of the canonical release set, and it has no way to run a repository
  command. The verification is correct, but three red jobs and a bare
  `PASS: n FAIL: 1` are indistinguishable at a glance from a real
  incompatibility.

  Deliberately the smallest thing that removes the ambiguity. It is read-only:
  it restores the manifest byte-for-byte before returning, never commits or
  pushes, and always exits `0`, so it cannot become a gate. `ci.yml` runs it as
  an `if: failure()` step in the existing `shell` job — no new action pin, no
  new secret, and every job keeps `contents: read`. `tests/run-tests.sh` also
  repeats the remedy after its `PASS/FAIL` line, which is where a reader
  actually looks.

  What was considered and rejected: uploading the patch as a build artifact
  (needs a new third-party action pin — more Dependabot churn, which is the
  problem this addresses), and a privileged bot-facing job that pushes the
  regenerated manifest itself (needs `contents: write` on a branch an author can
  edit). Zero-touch was never the goal; the extra commit is fine, the extra
  commit being mysterious was not. Manifest verification itself is untouched and
  still rejects extra, missing, duplicate, stale, malformed and misordered
  entries. ([#41])
- **`README.md` no longer renders an empty code box.** An opening ```` ```bash ````
  immediately followed by its closing fence sat between the `--check`
  exit-code paragraph and the `--write` paragraph, left behind by `845389f` when
  the prose absorbed what the block was going to show. It rendered as an empty
  box that reads as a command somebody forgot to write down. The two lines are
  gone and nothing else in the README moved.

  A full sweep of the README's tag, badge, release-reference and Markdown/HTML
  correctness found only that one defect; the clean results are recorded in #43
  so the audit is not repeated. `tests/run-tests.sh` now asserts that no tracked
  Markdown file has an empty or unclosed code fence — a few lines of Bash over
  the eleven tracked files, rather than a Markdown linter added for one fence.
  ([#43])

- **Every GitHub Action is pinned to a full commit SHA** with a version comment,
  replacing the mutable `actions/checkout@v4` and
  `softprops/action-gh-release@v2`. A tag is a pointer: its owner can move it to
  different code and the next run picks that up with no diff here and no review.
  The two most exposed were the two steps in the job that holds
  `contents: write`. This pins what already runs — `v4` was `v4.4.0` and `v2`
  was `v2.6.2` — and deliberately does not upgrade; Dependabot proposes that
  separately, as a reviewable diff. ([#27])
- **`contents: write` moved from the release workflow onto its `publish` job**,
  and every `ci.yml` job now declares `contents: read`. A second job added to
  `release.yml` starts with no write access rather than inheriting it. ([#27])
- **Every checkout sets `persist-credentials: false`.** No job performs an
  authenticated Git operation after checkout, and the `tag-checkout` job clones
  `file://$GITHUB_WORKSPACE`, which needs no credentials. The release upload
  authenticates through an explicit `token:` input, which is now written in the
  file rather than left implicit. ([#27])
- **`tools/refresh-pins.sh` distinguishes two kinds of pin.** Node.js, `gh`, uv,
  Claude Code, Codex and pi resolve to a published release and are `CURRENT` or
  `STALE`. Oh My Zsh publishes no releases, so its pin tracks a branch head that
  moves several times a day; that is now `MOVED`, reported but not failed.
  `--check --all` opts into failing on it. `--write` leaves a branch head alone
  unless `--all` is given, so moving it is a deliberate act. ([#25])
- **`--check` exit codes are a documented contract:** `0` nothing actionable,
  `1` a release pin is behind, `2` usage error, `3` at least one upstream could
  not be resolved. `1` outranks `3`. Documented in `README.md`,
  `docs/CONFIGURATION.md` and the script's own banner. ([#25])
- **`tools/refresh-pins.sh` can be sourced without side effects.** Resolution,
  reporting and rewriting moved behind a main guard, and the two decisions —
  classify a row, turn rows into an exit code — are pure functions the offline
  suite drives with synthetic rows. Sourcing it changes no shell options, which
  matters because it sets `-Eeuo pipefail` and the suite deliberately does not.
  ([#25])

- **The release-command assertion in `tests/run-tests.sh` is gone.** It
  extracted commands from workflow YAML with an `awk` program over
  whitespace-split text and claimed every release command also ran in CI.
  Verified: it accepted a command named only in a step's `name:` line and one
  inside an echoed string, and could not see `/usr/bin/bash`, `bash -e`, an
  interpreter held in a variable, a `make` target, a composite action or a
  reusable workflow. It also normalised arguments away, so `--skip-tests`
  counted as covering a full build. What replaced it asserts only that
  `release.yml` is a checkout, one `run:` invoking the preflight, and one
  upload — a narrow claim with a real remedy, and one whose own fixtures cover
  every evasion above. ([#26])
- **The `tag-checkout` job is described accurately.** It rehearses the *Git
  metadata* a tag build sees — detached HEAD, one commit, one tag, a shallow
  clone. It does not reproduce `GITHUB_REF_TYPE=tag`, the tag event payload, the
  expression context, the origin URL, the fetch refspec, or the checkout's
  authentication state. It now runs the whole preflight, including the tag
  check, inside that shape. ([#26])

### Fixed

- **Three documentation claims that had stopped being true.** `README.md`,
  `docs/CONFIGURATION.md` and the `refresh-pins.sh` banner all listed the
  `--write` targets as "config.sh, config.example.env, checksums/" — wrong since
  #20 added `README.md`, and wrong again once `docs/CONFIGURATION.md` joined
  them. The 2.2.2 notes explained a bug by saying every CI job checks out a
  branch, which #22 made false; the sentence stays as history with a dated
  correction beside it. And `README.md` claimed every pinned version is
  "checksum-verified before use": true for Node.js, uv and `gh`, whose
  downloaded artifacts are checked against SHA-256 values pinned here, but not
  for the AI CLIs, which are exact-version npm installs whose integrity comes
  from npm and the registry. A fitness section now derives the `--write` list
  from `tools/write-pins.py` itself and fails if any of the three prose lists
  disagrees. ([#29])
- **`tools/refresh-pins.sh` printed `tr: write error: Broken pipe`** on every
  run: `grep -m1` exits on the first match and SIGPIPEs the `tr` feeding it.
  Harmless on a terminal, but the weekly workflow captures stderr into the issue
  body, so it reached a reader as an apparent error. ([#29])
- **`tools/refresh-pins.sh` reported an unreachable upstream as `CURRENT` and
  exited 0.** An empty resolution fell back to the pinned value, which then
  compared equal to itself. With failing `curl` and `git` on `PATH`, all seven
  rows printed `current` and the tool said "every pin is current". Those rows
  are now `UNKNOWN`, the `LATEST` column says `unknown`, the exit code is `3`,
  and `--write` refuses rather than writing a value it could not resolve.
  ([#25])
- **`--check` could not exit 0.** The Oh My Zsh row was `STALE` within hours of
  any bump, so exit 1 was the steady state and could not distinguish "Node.js is
  behind" from "it is Tuesday". ([#25])
- **`release/build-release.sh` packaged untracked working-tree files.** It
  walked the tree with `find`, so a scratch file or a personal note sitting in a
  contributor's checkout was hashed into `checksums/SHA256SUMS` and packed into
  the tar, the zip *and* the source zip, with every gate green. Release content
  now comes from the canonical set, so an untracked file is excluded by
  construction. For a clean checkout the archives are byte-identical to before.
  ([#24])
- **Nothing verified the committed `checksums/SHA256SUMS`.** Replacing all 64
  lines with one meaningless line passed the suite, the privacy guard and the
  release build. `release/release-files.sh verify` runs in the suite and fails
  on any divergence. ([#24])
- **The source zip gave every file mode 0755**, because the staging copy used
  `install -D` with no mode. Modes are copied from the tree, which also makes a
  rebuild from an unpacked source bundle byte-identical to a rebuild from a
  checkout. ([#24])
- **`docs/CONFIGURATION.md` named two superseded pins**: Claude Code `2.1.267`
  and Oh My Zsh `cd320b55`, both superseded by #21. Nothing rewrote or checked
  that file. ([#23])

[#23]: https://github.com/evya1/server-bootstrap/issues/23
[#24]: https://github.com/evya1/server-bootstrap/issues/24
[#25]: https://github.com/evya1/server-bootstrap/issues/25
[#26]: https://github.com/evya1/server-bootstrap/issues/26
[#27]: https://github.com/evya1/server-bootstrap/issues/27
[#28]: https://github.com/evya1/server-bootstrap/issues/28
[#29]: https://github.com/evya1/server-bootstrap/issues/29
[#38]: https://github.com/evya1/server-bootstrap/issues/38
[#36]: https://github.com/evya1/server-bootstrap/pull/36
[#35]: https://github.com/evya1/server-bootstrap/pull/35
[#41]: https://github.com/evya1/server-bootstrap/issues/41
[#43]: https://github.com/evya1/server-bootstrap/issues/43

## 2.2.2

Fixes a bug in the 2.2.1 history-preservation check that made the release build
fail under a tag checkout. **There is no 2.2.1 release**: the `v2.2.1` tag
exists and points at the commit carrying that bug, so the release workflow
failed at the build gate and published nothing. The tag is left in place rather
than moved or deleted, because SECURITY.md forbids tag replacement — which is
exactly the situation that policy is written for.

### Fixed

- **The published-tag check no longer assumes a checkout has every tag.** It
  gated on `git tag -l` being non-empty. A tag checkout — what
  `.github/workflows/release.yml` performs — carries exactly the one tag being
  built, so the gate opened and then failed on the four historical tags the
  checkout was never given. Presence of *a* tag was never evidence that the full
  set had been fetched.

  It is now opt-in via `SB_CHECK_PUBLISHED_TAGS=1`, matching the existing
  `SB_TEST_NETWORK=1` convention, and the CI job that checks out with
  `fetch-depth: 0` sets it. Every other checkout shape reports an explicit
  `skip:` line instead of a false pass or a false failure. A genuinely missing
  tag still fails the check where it runs.

  Every CI job checks out a branch, so no CI job could reproduce this; only the
  tag-triggered release workflow could.

  > **Corrected 2026-09-12.** That was true when 2.2.2 shipped and is why the bug
  > escaped, so it is left standing rather than rewritten. It is no longer true:
  > [#22][] added `ci.yml`'s `tag-checkout` job, which manufactures a detached,
  > depth-1, single-tag checkout on every push and pull request. See the
  > `Unreleased` section above.

[#22]: https://github.com/evya1/server-bootstrap/pull/22

## 2.2.1

Security hardening only. No behaviour on a provisioned server changes: nothing
in `lib/bootstrap/`, and no entrypoint, was touched.

> **Note:** 2.2.0 was bumped on `main` but never tagged, so no 2.2.0 release
> exists. Upgrading from v2.1.0 therefore also picks up everything listed under
> 2.2.0 below — the pi coding agent, the single API-key file, and the refreshed
> pins. The 2.2.1 diff itself is security work alone.

### Added

- **One pinned scanner.** `tools/gitleaks.sh` holds the only Gitleaks version
  and release checksum in the repository. CI, `release/build-release.sh` and the
  release workflow all scan through it, so the gate that blocks a pull request
  and the gate that blocks a publication cannot drift apart. The download is
  checksum-verified before extraction and the script refuses to run on a
  mismatch.
- **Proof that full-history scanning works.** `tools/verify-history-scan.sh`
  runs in CI against a throwaway repository where a credential is added in one
  commit and the file deleted in the next, and asserts that a working-tree-only
  scan misses it while the full-history scan finds it. The scan also refuses to
  run against a shallow checkout, so a missing `fetch-depth` cannot quietly
  shrink what it covers.
- **Deterministic privacy guards.** `tests/privacy-guard.sh` checks the tracked
  set for credential-shaped filenames, private-key material, high-signal
  credential markers, credentials embedded in URLs, tracked build output,
  private-use wording in `server-accept.sh`, and an allowlist that has grown
  beyond the reviewed values. It runs offline, reports the violated policy and
  location without reprinting the matching text, and every policy is exercised
  against a fixture that must fail.
- **Release staging and artifact scanning.** The release build scans the source
  staging tree, each extracted archive, and `release/dist` itself; the release
  workflow scans `release/dist` again immediately before upload. The final pass
  descends into archives, because a flat scan of a directory of tarballs reads
  zero bytes. A finding discards the staged release so a later upload cannot
  pick up an artifact that failed the gate, and the archive hashes are
  re-verified afterwards to prove scanning did not touch the published bytes.
  The release manifest records `release_scan`.
- **`SECURITY.md`.** Private reporting, and the history-preservation policy the
  rest of this work follows: rotate an exposed credential out of band, remediate
  with new commits, never rewrite published history, never delete release assets
  or tags in place of remediation, and never broaden the allowlist to silence a
  preserved finding. It also records the rule that no key-shaped string is ever
  committed, not even as a fixture.

### Changed

- The test suite grows from 188 to 234 tests. The release-scan behaviour checks
  skip rather than download when no pinned scanner is present, so the suite
  still runs offline from a clean checkout.
- The `shell` CI job fetches tags, so the check that published release tags
  still resolve runs instead of skipping.

### History

No history was rewritten to produce this release. No force-push, no rebase or
amend of a published commit, no tag replacement, and no release asset deleted.
The tags `v1.4.0`, `v2.0.0`, `v2.0.1` and `v2.1.0` resolve to the same commits
they always did, and CI scans the complete preserved history on every push.

## 2.2.0

### Added

- **pi coding agent.** `@earendil-works/pi-coding-agent` 0.85.1 installs beside
  Claude Code and Codex in `/opt/ai-cli` and is linked as `pi`. Disable it with
  `INSTALL_PI=0`. The generated Zsh configuration exports `PI_TELEMETRY=0` and
  `PI_SKIP_VERSION_CHECK=1`, so a release-pinned pi does not phone home.
- **A models.json template** at `examples/pi-models.example.json`, installed to
  `/root/.pi/agent/models.json` only when that file does not already exist. It
  covers custom providers only — pi ships built-in catalogs for Anthropic,
  OpenAI and OpenRouter — and stores no secret: its OpenRouter entry reads
  `$OPENROUTER_API_KEY` from the environment.
- **One place for API keys.** `/root/.config/server-bootstrap/secrets.env`,
  mode 0600, seeded from `examples/secrets.env.example` and loaded by every
  login shell. The file is parsed, never sourced, so a backtick or `$(...)` in
  a pasted value is data rather than a command, and an empty value is not
  exported.
- **`server-secrets`** to manage that file: `status` (masked), `set NAME`
  (prompts, so nothing reaches shell history), `edit`, `check`, `path`, `init`.
- **`aikeys on|off|status`** in the interactive shell. `aikeys off` clears the
  keys from the current shell, which is what returns `claude` and `codex` to
  Claude Pro/Max and ChatGPT subscription login.
- **`latest` as a version.** `NODE_VERSION`, `GH_VERSION`, `UV_VERSION`,
  `CLAUDE_CODE_VERSION`, `CODEX_VERSION`, `PI_VERSION` and `OH_MY_ZSH_REF` now
  accept the literal `latest`. The resolved artifact is still checksum-verified
  before extraction, using the publisher's own manifest. Pinned stays the
  default: an upstream manifest proves integrity, not authenticity.
- **`tools/refresh-pins.sh`** to report (`--check`, non-zero when stale) or
  apply (`--write`) upstream drift across `lib/bootstrap/config.sh`,
  `config.example.env` and `checksums/`. Tag discovery uses `git ls-remote`
  rather than the GitHub API, so it needs no token.

### Changed

- Refreshed every pin: Node.js 24.18.0 to 24.21.0, GitHub CLI 2.96.0 to
  2.100.0, uv 0.9.2 to 0.12.12, Claude Code 2.1.216 to 2.1.267, Codex 0.145.0
  to 0.154.0, and Oh My Zsh to commit `cd320b55`.
- uv installs on ARM64. It previously refused anything but x86_64, so
  `UV_SHA256` became `UV_SHA256_X64` and `UV_SHA256_ARM64`; the old name still
  works as an x86_64 override.
- uv upgrades on rerun. It previously skipped whenever any `uv` was on `PATH`,
  which meant a version bump never took effect; it now compares versions the
  way the GitHub CLI module already did.

### Fixed

- A host with its own Node, `gh` or `uv` earlier in `PATH` no longer breaks the
  run. Post-install version checks used a bare command name, so a preinstalled
  Node satisfied the lookup and failed the comparison, aborting the whole
  bootstrap at the `nodejs` step. Each check now verifies the binary it just
  installed, and the pinned Node leads `PATH` for the npm steps that follow, so
  the coding-agent CLIs can no longer be installed against an unpinned runtime.
  Found by a full provisioning run on Ubuntu 24.04, not by the unit tests.
- `bootstrap_nodejs` now also refuses to skip Node.js when only pi is enabled.

## 2.1.0

- **Added `tools/shrink-silence-m4a.sh`.** A standalone utility, not wired into
  the provisioning flow: shortens long silent regions in M4A recordings in
  place via ffmpeg. Persists the exact cut list as a permanent
  `<stem>.shrink_offsets.json` sidecar next to the shrunk file, so a
  downstream consumer can map a timestamp in the shrunk audio back to the
  original file's timeline — a naive silence-trim throws that mapping away,
  which desyncs anything keyed to the original recording's clock. Its
  `--analysis-only <path>` mode recovers that sidecar for a file already
  shrunk before this existed, from a surviving unshrunk copy, without
  touching either file. Ships with its Python helper,
  `tools/build-silence-filter.py`.

## 2.0.1

- **Fixed a broken command in the README.** The "Which command do I run?"
  table told people to preview a plan with `server-provision.sh --plan …
  --dry-run` after install, but the bootstrap only ever symlinks the bare
  `server-provision` onto `PATH` — running the documented line literally
  failed with `command not found`. Corrected to `server-provision --plan …
  --dry-run`.
- **Added a fitness test** (`tests/run-tests.sh`) that derives the real
  installed-command set from `lib/bootstrap/runtime.sh` and checks every
  `server-*` command named in a README table against it, so a doc/reality
  mismatch like this fails CI instead of shipping silently.

## 2.0.0

Breaking: the project is no longer GPU-specific in name or behaviour. Nothing in
the bootstrap ever installed an NVIDIA driver or CUDA — the GPU framing was
naming around a general-purpose server setup, and it made the tool look
inapplicable to the CPU-only machines it already supported.

- **Renamed every command.** `gpu-server-bootstrap` → `server-bootstrap`,
  `gpu-provision` → `server-provision`, `gpu-bundle-install` →
  `server-bundle-install`, `gpu-accept` → `server-accept`,
  `gpu-vscode-extensions` → `server-vscode-extensions`. No compatibility
  symlinks are installed: the old names are gone. Existing machines should be
  re-bootstrapped from the 2.0.0 archive, which removes
  `/usr/local/lib/gpu-server-bootstrap` only if you delete it by hand — the new
  runtime installs alongside it at `/usr/local/lib/server-bootstrap`.
- **Renamed the shared code prefix** from `gsb_`/`GSB_` to `sb_`/`SB_`, the
  acceptance policy variable from `GPU_ACCEPT_POLICY` to `ACCEPT_POLICY`, the
  reported `gpu_present` field to `accelerator_present`, and the AI CLI prefix
  from `/opt/gpu-ai-cli` to `/opt/ai-cli`. Plans that export `GPU_ACCEPT_POLICY`
  must be updated; the old name is silently ignored.
- **`server-accept` no longer rejects a machine that has no GPU.** CPU, RAM, and
  disk are checked everywhere; the `nvidia-smi` section is skipped with a note
  when no accelerator is present. Previously a CPU-only box was a hard rejection,
  which made the tool unusable on exactly the hosts this release targets. Set
  `REQUIRE_ACCELERATOR=1` to restore the old behaviour when a missing GPU really
  is a failed delivery.
- **Moved the apt package set out of shell code** into `config/packages.txt`,
  which was the only install layer in the project without a configuration knob.
  The manifest has `[required]` and `[optional]` sections; optional packages
  whose availability varies by release now warn instead of being absent with no
  explanation. `EXTRA_PACKAGES` and `SKIP_PACKAGES` adjust it without editing the
  file, and names are validated against Debian's rules before reaching the apt
  command line.
- **Expanded the package set from 41 to 96**, adding network and diagnostic
  tooling (`dnsutils`, `mtr-tiny`, `iperf3`, `tcpdump`, `nmap`, `socat`,
  `speedtest-cli`), shell ergonomics (`fzf`, `zoxide`, `direnv`, `tldr`),
  archive and compression tools (`zstd`, `pigz`, `pv`), the headers needed to
  build Python versions and native wheels, and `sqlite3`, `strace`, `sysstat`,
  `screen`, and `bash-completion`.
- **Added the GitHub CLI** (`gh` 2.96.0) as a pinned, SHA-256-verified upstream
  release rather than an apt package or a third-party apt repository, matching
  how Node.js and uv are already installed. Disable with `INSTALL_GITHUB_CLI=0`.

## 1.4.0

- First public release.
- Fixed `server-provision.sh --dry-run` performing side effects before it printed anything: it created the log directory, opened a log file, and took the lock, so previewing a plan both wrote to `/workspace` and required root. A dry run is now read-only and works unprivileged. Caught by running the suite in CI, which is unprivileged; every local run had been as root.
- Trimmed the VS Code Remote-SSH manifest to 49 extensions, dropping two entries that were specific to the original author's environment rather than generally useful. Override `VSCODE_EXTENSIONS_FILE` to install your own manifest instead.
- Corrected stale `1.3.1` version headers in `config.example.env`, `checksums/OH_MY_ZSH_REF.txt`, and `checksums/UV_SHA256.txt`, which had drifted because they are neither Markdown nor shell files and were missed by the previous release bump.
- Added a version-drift fitness test so a shipped file can no longer advertise a version that disagrees with `VERSION`.
- Added `.gitignore`, `.gitattributes`, an MIT `LICENSE`, and GitHub Actions workflows for tests and tag-triggered releases.

## 1.3.2

- Fixed an `unbound variable` crash in AI CLI version verification: `bootstrap_verify_npm_package_version` referenced `$package` while it was still being assigned in the same `local` statement, so the compound word expansion saw it as unset under `set -u`. The assignment is now split into two statements.
- Fixed `server-accept.sh` disk-speed detection on fast NVMe: the write-throughput regex only matched `MB/s`, so a `dd` result reported in `GB/s` (or `kB/s`) made the parsing pipeline fail under `pipefail`, silently aborting acceptance before it reached a verdict and surfacing as a false hard REJECT even when every check passed. Disk speed is now parsed and normalized from kB/s, MB/s, or GB/s.

## 1.3.1

- Fixed an idempotence failure in Debian/Ubuntu command compatibility links: an existing `fd` or `bat` command no longer makes the package phase return nonzero.
- Added an explicit, testable `bootstrap_ensure_command_alias` helper for `fdfind` → `fd` and `batcat` → `bat`.
- Added behavioral regression tests for first creation, reruns, and unavailable source commands.
- Clarified that `server-bundle-install` is an argument-requiring add-on helper, not a continuation command for the main bootstrap.

## 1.3.0

- Added checksum-verified Node.js 24.18.0 LTS installation for Linux x64 and ARM64.
- Added exact-version Claude Code 2.1.216 and OpenAI Codex CLI 0.145.0 installation in an isolated npm prefix.
- Added the requested 51-extension VS Code Remote-SSH manifest and the persistent `server-vscode-extensions` installer.
- Added immediate installation when VS Code Server already exists and a rate-limited background Zsh hook for the first fresh Remote-SSH terminal.
- Added per-extension continuation, strict mode, retry state, logs, and idempotence tests.
- Added safe `.tar.xz` and `.txz` archive extraction for verified upstream binaries.
- Expanded reports, configuration, quick-start, architecture, and troubleshooting documentation.

## 1.2.1

- Restored Zsh as an explicit default bootstrap feature and strengthened login-shell verification.
- Enabled Oh My Zsh by default at a pinned upstream commit and load it from the generated Zsh startup configuration.
- Preserved and tested the `c` alias for `clear`, loaded after Oh My Zsh so it remains authoritative.
- Added theme/plugin configuration, pinned-reference metadata, and shell setup documentation.

## 1.2.0

- Split the bootstrap into focused modules for configuration, workspace, apt,
  runtime tools, uv, base Python, shell setup, reporting, archives, and bundles.
- Added `server-provision.sh` for ordered local installation of the bootstrap and
  any number of workload or configuration archives.
- Added `server-bundle-install`, the single reusable verified bundle installer.
- Moved GPU acceptance before every workload installation.
- Added archive deletion only after successful installation and state recording.
- Added version+archive-hash state, legacy add-on state migration, dry-run, and
  explicit acceptance policies.
- Replaced remote Oh My Zsh installer execution with optional verified archive
  installation; the feature is now off by default.
- Added scoped documentation and provision-plan examples.

## 1.1.0

- Added `server-accept.sh` and fail-closed uv checksum configuration.
