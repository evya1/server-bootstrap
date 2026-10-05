# Quick start

## Requirements

Run on Ubuntu 24.04, as root, on x86-64 or ARM64. The provisioner checks these
before installing anything. A fresh host or container may already provide a
root shell; otherwise run `sudo -i`. Downloads need outbound HTTPS and apt needs
access to the configured mirrors. Stock Ubuntu, including `ubuntu:24.04`, uses
HTTP for `archive.ubuntu.com`, `security.ubuntu.com` and `ports.ubuntu.com`.

| Installation | Disk and accelerator requirements |
| --- | --- |
| Complete built-in stack or ML plan, CPU backend | 10 GB free where the ML environment will be built; `auto` selects it on hosts without NVIDIA hardware |
| Complete built-in stack or ML plan, CUDA backend | 30 GB free; x86-64; a working NVIDIA driver reporting CUDA 13.0 or newer; every GPU at compute capability 7.5 or newer |
| Foundation only | 50 GB free at `/workspace`, enforced by the example plan's `MIN_DISK_GB=50` acceptance policy |

The full and ML plans use `--backend auto`: CPU on a host without NVIDIA
hardware, and the locked CUDA backend on a supported NVIDIA host. There is no
CUDA backend for ARM64 and no automatic CPU fallback on NVIDIA hardware.
Missing or failing `nvidia-smi`, an older driver, or an unsupported GPU stops
ML installation with a non-zero exit and leaves the foundation installed.
After a failed first ML install, you can edit the plan to use
`enable_profile "ml" --backend cpu` and rerun it. No `--reconfigure` is needed
when the failed run installed no backend. See [ML compatibility](ML-PROFILE.md#backends-and-locks).

ML free space is checked before a build; a repeat that rebuilds nothing does
not need that space. A foundation-only host that fails its disk policy is
rejected after the foundation installs, and the provisioner exits non-zero.
An NVIDIA driver is optional and is never installed by the bootstrap. Apt
transactions that would change an installed NVIDIA driver or CUDA package are
refused; see [driver protection](CONFIGURATION.md#nvidia-driver-and-cuda-packages).

## Installation options

### Complete built-in stack

Use the copyable block in [README: How to use](../README.md#how-to-use). It
downloads the standalone provisioner, full plan, archive and checksum sidecar,
verifies the archive, and runs `provision-plan.full.example.sh`.

The full plan enables every configurable installer and every built-in profile.
Its exports override the caller's environment, so to omit a component, edit
its line in your copy of the plan. ngrok is part of every bootstrap run.
The plan installs no external bundle, downloads no model or dataset, and
starts no workload or service.

### Foundation-only install

`provision-plan.example.sh` installs the foundation without the ML profile. It
uses the 50 GB acceptance policy above and deletes the bootstrap archive and
sidecar once the foundation has installed:

```bash
V=2.3.2
BASE=https://github.com/evya1/server-bootstrap/releases/download/v$V
cd /root
command -v wget >/dev/null && [ -s /etc/ssl/certs/ca-certificates.crt ] || { tries=0; \
  until apt-get -o DPkg::Lock::Timeout=10 check >/dev/null && apt-get update; do tries=$((tries + 1)); [ "$tries" -lt 40 ] || break; sleep 5; done \
  && [ "$tries" -lt 40 ] \
  && plan="$(apt-get -s install --no-install-recommends --no-remove wget ca-certificates)" \
  && printf '%s\n' "$plan" | awk -v p='^(nvidia|libnvidia|cuda|libcuda|cudnn|libcudnn|libnccl|libcublas|libcufft|libcurand|libcusolver|libcusparse|libnpp|libnvjpeg|libnvrtc|libnvjitlink|libcupti|libnvtoolsext|libcudart|nsight-)|-nvidia(-|$)' \
    '/^(Inst|Remv|Purg|Conf) / { n = $2; sub(/:.*/, "", n); if (n ~ p) { print "not installing wget: apt would also change " n; s = 1 } } END { exit s }' \
  && DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=600 install -y --no-install-recommends --no-remove wget ca-certificates; } \
  && wget -q --show-progress \
  "$BASE/server-provision.sh" \
  "$BASE/provision-plan.example.sh" \
  "$BASE/server-bootstrap-$V.tar.gz" \
  "$BASE/server-bootstrap-$V.tar.gz.sha256" \
  && sha256sum -c "server-bootstrap-$V.tar.gz.sha256" \
  && chmod +x server-provision.sh \
  && ./server-provision.sh --plan ./provision-plan.example.sh
```

### Foundation and ML

Use the [ML one-command install](ML-PROFILE.md#one-command-install) for
`provision-plan.ml.example.sh`, which enables the foundation and ML profile.
It keeps its verified archive, as the full plan does.

### What the download blocks do

Each command runs only after the preceding command succeeds. On a bare image
without `wget` or a CA bundle, the guard installs only `wget` and
`ca-certificates`. It simulates that install first, refuses a plan touching
NVIDIA or CUDA packages, and uses `--no-remove`.

The blocks can run as boot startup scripts while the host's own package setup
is busy. Before each update attempt, `apt-get check` waits up to 10 seconds for
dpkg's lock; a failed check or update is retried after 5 seconds, for at most
40 attempts, about ten minutes. The install then waits up to ten minutes for
dpkg's lock. Apt may print `Could not get lock` while waiting. The bootstrap
also waits before its own apt transactions within one 600-second budget.

The foundation typically takes about five minutes, mainly apt. ML then adds
its package download, several gigabytes for CUDA. SHA-256 is checked before
extraction. For the integrity and authenticity distinction, see
[installation trust](../SECURITY.md#installation-trust).

### Custom plans and workload bundles

Copy `server-provision.sh`, a plan, the bootstrap archive and its `.sha256`
sidecar into one directory. Start with the full, foundation-only or ML example
and edit a copy. Register the bootstrap once, then list any workload bundles
in the order you want them installed. A plan is data: pass it with `--plan`,
and never execute `provision-plan*.sh` directly.

Put each local workload archive and sidecar beside the plan before registering
it. A missing registered workload archive stops the run after the foundation
has already installed. A typical directory contains:

```text
server-provision.sh
provision-plan.sh
server-bootstrap-2.3.2.tar.gz
server-bootstrap-2.3.2.tar.gz.sha256
<workload>-<version>.tar.gz
<workload>-<version>.tar.gz.sha256
```

Preview without root or changes, then install from a root shell:

```bash
./server-provision.sh --plan ./provision-plan.sh --dry-run
./server-provision.sh --plan ./provision-plan.sh
```

Acceptance runs after the foundation and before profiles or workloads. A
rejected host keeps the foundation installed. Its report covers CPU, RAM and
disk speed, plus PCIe link width, thermals and ECC when an NVIDIA GPU is
available. CPU-only hosts are valid;
set `REQUIRE_ACCELERATOR=1` in the plan when a GPU is required. Successful runs
write their summary and log under `/workspace/startup-logs/`.
See [Provisioning](PROVISIONING.md) for remote bundles, ordering and policies,
and [Configuration](CONFIGURATION.md) for installer switches and packages.

## After installation

### Start the shell

Reconnect over SSH or run:

```bash
exec zsh -l
```

Zsh is root's default login shell. The pinned Oh My Zsh revision and aliases
load from `/root/.zshrc`, including `c` for `clear`, `disk` and `mem`, plus
`gpu` and `gpu-watch` when `nvidia-smi` is available.

### Authentication

The coding agents are installed without authentication. Choose interactive
sign-in by running the agent you use:

```bash
claude
codex
pi
```

Alternatively, store only the API keys you use. The optional key file is
`/root/.config/server-bootstrap/secrets.env`, root-owned at mode 0600, and is
loaded by each login shell:

```bash
server-secrets set ANTHROPIC_API_KEY     # prompts; nothing reaches shell history
server-secrets set OPENAI_API_KEY
server-secrets set OPENROUTER_API_KEY
server-secrets status                    # masked list of what is set
```

`server-secrets edit` opens the file in `$EDITOR`, and `server-secrets path`
prints its location. Start a new shell or run `aikeys on` after changes.
API keys take precedence over interactive sign-in. Use `aikeys off` to clear
keys from the current shell before signing in interactively, and `aikeys on`
to reload them. `aikeys status` shows a masked list.

### VS Code Remote-SSH

If VS Code Server already exists, the bootstrap attempts the extension list
immediately. On a fresh host, connect with Remote-SSH and open an integrated
terminal; the Zsh hook starts a rate-limited background installation. To run
it explicitly:

```bash
server-vscode-extensions
```

Reload the window after the first installation. The installed manifest is
`/usr/local/lib/server-bootstrap/config/vscode-extensions.txt`. See
[extension configuration](CONFIGURATION.md#vs-code-remote-ssh-extensions) to
supply a different list.

### Custom pi models

To use a local vLLM or Ollama server, edit `/root/.pi/agent/models.json`.
The bootstrap seeds it from a template only when it does not already exist.
See [pi model configuration](CONFIGURATION.md#pi-model-configuration).

## Reruns

The full and ML plans keep the verified archive and sidecar. From `/root`,
repeat the complete install with:

```bash
./server-provision.sh --plan ./provision-plan.full.example.sh
```

Use the corresponding ML plan command for an ML-only plan. An up-to-date ML
environment is kept. Pasting the entire download block again produces extra
copies that wget saves with `.1` suffixes; repeat the provisioner command
instead.

The foundation-only plan uses the default archive deletion policy. The archive
is removed immediately after the foundation succeeds, before acceptance. To
keep it for a custom plan, set `DELETE_ARCHIVES_AFTER_SUCCESS=0` or use
`--keep-archives`; see [archive deletion](PROVISIONING.md#archive-deletion).

To repair just the foundation, run the installed command as root:

```bash
server-bootstrap
```

Or run `./server-bootstrap.sh` from an extracted archive. Node.js and AI CLI
versions are verified on rerun. Existing VS Code extensions are skipped and
missing or failed ones are retried. For workload bundles, the same version and
hash are skipped, a newer version is installed, and the same version with a
different hash is rejected unless forced after review.

## Command reference

| Goal | Command |
| --- | --- |
| Complete install or repeat | `./server-provision.sh --plan ./provision-plan.full.example.sh` |
| Foundation-only first install | `./server-provision.sh --plan ./provision-plan.example.sh` |
| Foundation and ML first install or repeat | `./server-provision.sh --plan ./provision-plan.ml.example.sh` |
| Repair the foundation | `server-bootstrap` |
| Check host acceptance | `server-accept` |
| Preview a plan | `./server-provision.sh --plan ./provision-plan.sh --dry-run` |
| Install one verified workload bundle | `server-bundle-install --name … --version … --source … --sha256 …` |
| Add the built-in ML profile | `server-profile install ml` |
| Install or repair editor extensions | `server-vscode-extensions` |
| Manage API keys | `server-secrets` |

`server-provision` is the installed form of the standalone `server-provision.sh`.
`server-bundle-install` needs a bundle name, version, source and checksum;
running it without arguments prints usage. The legacy one-add-on environment
interface remains supported; see [Configuration](CONFIGURATION.md#legacy-one-add-on-interface).
