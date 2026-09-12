#!/usr/bin/env python3
"""Apply a resolved set of pins to every file that records one.

Invoked by tools/refresh-pins.sh --write with each pin's new value in the
environment; run directly only to test it. SB_PIN_ROOT selects the tree to
rewrite and defaults to the repository root, which is what lets the offline
suite drive a coordinated bump against a scratch copy.

Every substitution is resolved before any file is written, so a file whose
patterns no longer fit aborts the run before the first write rather than after
some of them. The writes themselves are per file and are NOT atomic across
files: an I/O failure between two of them leaves the tree partly updated. The
remedy is to rerun, not to hand-finish the rest.
"""
import os
import pathlib
import re

names = [
    "NODE_VERSION", "NODE_SHA256_X64", "NODE_SHA256_ARM64",
    "GH_VERSION", "GH_SHA256_X64", "GH_SHA256_ARM64",
    "UV_VERSION", "UV_SHA256_X64", "UV_SHA256_ARM64",
    "CLAUDE_CODE_VERSION", "CODEX_VERSION", "PI_VERSION", "OH_MY_ZSH_REF",
]
values = {n: os.environ[n] for n in names}
ROOT = pathlib.Path(os.environ.get("SB_PIN_ROOT", pathlib.Path(__file__).resolve().parent.parent))

SEMVER = r"\d+\.\d+\.\d+"
HEX64 = r"[0-9a-f]{64}"
HEX40 = r"[0-9a-f]{40}"


def env_block(name, shape):
    """A bare NAME=value line inside a fenced documentation block."""
    return (r"^%s=%s$" % (re.escape(name), shape), "%s=%%s" % name)


# Every substitution this tool performs, as
# (file, pin, regex, replacement template taking one %s, expected match count).
#
# tools/check-pins.sh asserts the same set of recordings from the other side:
# if a surface is added there and not here it goes stale on the next bump, and
# if it is added here and not there the rewrite is unchecked. Keep the two in
# step.
EDITS = [
    ("lib/bootstrap/config.sh", n,
     r'^(\s*%s=")\$\{%s:-[^}]*(\}")$' % (n, n), None, 1) for n in names
]

# README.md's "What the run installs" table names five of these versions in
# prose. A second copy of a value that a tool updates only half of is how
# documentation goes stale, so they are rewritten here rather than left to the
# maintainer.
for label, name in (
    ("GitHub CLI", "GH_VERSION"),
    ("Node.js", "NODE_VERSION"),
    ("Claude Code", "CLAUDE_CODE_VERSION"),
    ("OpenAI Codex", "CODEX_VERSION"),
    ("pi", "PI_VERSION"),
):
    EDITS.append(("README.md", name,
                  r"\b%s %s(?![\d.])" % (re.escape(label), SEMVER),
                  "%s %%s" % label, 1))

# config.example.env keeps a commented copy of every default. Exactly one
# leading "# " distinguishes it from the "#   NAME=latest" tracking block.
for name in names:
    shape = HEX40 if name == "OH_MY_ZSH_REF" else (HEX64 if "SHA256" in name else SEMVER)
    EDITS.append(("config.example.env", name,
                  r"^# %s=%s$" % (re.escape(name), shape),
                  "# %s=%%s" % name, 1))

# docs/CONFIGURATION.md repeats nine of them as literal environment blocks.
# Until they were added here, --write left that file alone and two of its
# values were two releases behind what the bundle actually pinned.
for name, shape in (
    ("GH_VERSION", SEMVER), ("GH_SHA256_X64", HEX64), ("GH_SHA256_ARM64", HEX64),
    ("NODE_VERSION", SEMVER), ("NODE_SHA256_X64", HEX64), ("NODE_SHA256_ARM64", HEX64),
    ("CLAUDE_CODE_VERSION", SEMVER), ("CODEX_VERSION", SEMVER), ("PI_VERSION", SEMVER),
    ("OH_MY_ZSH_REF", HEX40),
):
    pattern, template = env_block(name, shape)
    EDITS.append(("docs/CONFIGURATION.md", name, pattern, template, 1))
EDITS.append(("docs/CONFIGURATION.md", "NODE_VERSION",
              r"\bNode\.js %s LTS binary archive\b" % SEMVER,
              "Node.js %s LTS binary archive", 1))

# Every substitution is resolved before any file is written, so a file whose
# patterns no longer fit aborts the run before the first write rather than
# after some of them. The writes themselves are per file and are not atomic
# across files: an I/O failure between two of them leaves the tree partly
# updated, and the fix is to rerun, not to hand-edit the remainder.
pending = {}
for path, name, pattern, template, expected in EDITS:
    file = ROOT / path
    text = pending.get(path, file.read_text())
    value = values[name]
    if template is None:
        # config.sh keeps its ${NAME:-...} shape, so the groups are the frame.
        replacement = lambda m, v=value, n=name: m.group(1) + "${%s:-" % n + v + m.group(2)
        text, count = re.compile(pattern, re.M).subn(replacement, text)
    else:
        text, count = re.compile(pattern, re.M).subn(template % value, text)
    if count != expected:
        raise SystemExit(
            "expected %d occurrence(s) of %s in %s, found %d"
            % (expected, name, path, count))
    pending[path] = text

for path, text in pending.items():
    (ROOT / path).write_text(text)

bundle = (ROOT / "VERSION").read_text().strip()
values["BUNDLE"] = bundle
values["OMZ_DATE"] = os.environ.get("OMZ_DATE", "unknown")

(ROOT / "checksums/NODE_SHA256.txt").write_text(
    "Node.js %(NODE_VERSION)s official release checksums:\n"
    "linux-x64  %(NODE_SHA256_X64)s\n"
    "linux-arm64 %(NODE_SHA256_ARM64)s\n"
    "Source: https://nodejs.org/en/blog/release/v%(NODE_VERSION)s\n" % values)

(ROOT / "checksums/GH_SHA256.txt").write_text(
    "# Pinned GitHub CLI release used by server-bootstrap %(BUNDLE)s.\n"
    "# Assets: gh_%(GH_VERSION)s_linux_amd64.tar.gz / gh_%(GH_VERSION)s_linux_arm64.tar.gz\n"
    "# Source: https://github.com/cli/cli/releases/download/v%(GH_VERSION)s/gh_%(GH_VERSION)s_checksums.txt\n"
    "linux-amd64 %(GH_SHA256_X64)s\n"
    "linux-arm64 %(GH_SHA256_ARM64)s\n" % values)

(ROOT / "checksums/UV_SHA256.txt").write_text(
    "# Pinned uv release used by server-bootstrap %(BUNDLE)s.\n"
    "# Assets: uv-x86_64-unknown-linux-gnu.tar.gz / uv-aarch64-unknown-linux-gnu.tar.gz\n"
    "# Source: https://github.com/astral-sh/uv/releases/download/%(UV_VERSION)s/\n"
    "x86_64-unknown-linux-gnu  %(UV_SHA256_X64)s\n"
    "aarch64-unknown-linux-gnu %(UV_SHA256_ARM64)s\n" % values)

(ROOT / "checksums/OH_MY_ZSH_REF.txt").write_text(
    "# Pinned Oh My Zsh commit used by server-bootstrap %(BUNDLE)s.\n"
    "# Upstream commit date: %(OMZ_DATE)s.\n"
    "%(OH_MY_ZSH_REF)s\n" % values)

(ROOT / "checksums/AI_CLI_VERSIONS.txt").write_text(
    "@anthropic-ai/claude-code %(CLAUDE_CODE_VERSION)s\n"
    "@openai/codex %(CODEX_VERSION)s\n"
    "@earendil-works/pi-coding-agent %(PI_VERSION)s\n" % values)
print("updated lib/bootstrap/config.sh, config.example.env, checksums/, "
      "README.md and docs/CONFIGURATION.md")