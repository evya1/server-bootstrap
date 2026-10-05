# server-bootstrap

Turn a fresh Ubuntu server, VM or container into a pinned development environment.
Hardware acceptance runs before profiles and bundles. No workload, model download
or public service starts automatically.

## How to use

Run as **root** on **Ubuntu 24.04**, **x86-64 or ARM64**, with outbound HTTPS
and access to apt mirrors (HTTP on stock Ubuntu). After the foundation installs,
the ML build needs **10 GB free for CPU or 30 GB for CUDA**. Open a root shell
with `sudo -i` first if needed, then paste the complete block:

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
  "$BASE/provision-plan.full.example.sh" \
  "$BASE/server-bootstrap-$V.tar.gz" \
  "$BASE/server-bootstrap-$V.tar.gz.sha256" \
  && sha256sum -c "server-bootstrap-$V.tar.gz.sha256" \
  && chmod +x server-provision.sh \
  && ./server-provision.sh --plan ./provision-plan.full.example.sh
```

This enables every configurable installer and built-in profile. It works in a
root terminal or as a boot startup script, waits for other apt processes within
a bounded budget, and verifies the archive before extraction.

On an NVIDIA host, automatic ML selection requires **x86-64**, a working driver
reporting **CUDA 13.0 or newer**, and every GPU at **compute capability 7.5 or
newer**. NVIDIA hosts never fall back to CPU automatically; an unsupported GPU
or driver leaves the foundation installed and exits with an error. See the
[requirements and recovery options](docs/QUICKSTART.md#requirements).

For the foundation alone, use the
[foundation-only install](docs/QUICKSTART.md#foundation-only-install).
For a custom plan or the separate ML plan, see
[Quick start](docs/QUICKSTART.md#installation-options).

## After installation

Reconnect over SSH or enter the new login shell:

```bash
exec zsh -l
```

Authentication is optional. Run `claude`, `codex` or `pi` to sign in interactively,
or use `server-secrets set NAME` for an API key you already use. Supported keys
include `ANTHROPIC_API_KEY`, `OPENAI_API_KEY` and `OPENROUTER_API_KEY`;
`server-secrets status` shows a masked list. API keys take precedence over
interactive sign-in. `aikeys off` clears them from the current shell and
`aikeys on` reloads them. See [authentication](docs/QUICKSTART.md#authentication).

To repeat the complete install, use its retained archive from `/root`:

```bash
./server-provision.sh --plan ./provision-plan.full.example.sh
```

An up-to-date ML environment is kept. Use `server-bootstrap` to repair just the
foundation. Connect with VS Code Remote-SSH and open an integrated terminal to
finish any pending extension installation. More commands and rerun details are
in [Quick start](docs/QUICKSTART.md).

## What gets installed

| Area | Component |
| --- | --- |
| Shell | Zsh, pinned Oh My Zsh and server aliases |
| CLI toolkit | [Apt package manifest](config/packages.txt): search, navigation, network and build tools, plus `git`, `git-lfs` and `rclone` |
| Git and tunnels | Checksum-verified GitHub CLI 2.102.0 (`gh`) and ngrok 3.39.11 CLI |
| Node | Checksum-verified Node.js 24.21.0 LTS for x64 or ARM64 |
| Coding agents | Claude Code 2.1.289, OpenAI Codex 0.160.0 and pi 1.0.2, isolated in `/opt/ai-cli` |
| Python and ML | uv, an isolated base environment, and the full plan's locked Python 3.12 ML environment for PyTorch, vision, Jupyter and language tooling |
| Editor and keys | 49 VS Code Remote-SSH extensions and a root-only API key file managed by `server-secrets` |
| Hardware | `server-accept`: CPU, RAM, disk and available GPU checks before profiles or bundles |

Downloaded Node.js, uv, `gh` and ngrok artifacts are verified against SHA-256
values recorded in this repository. The AI CLIs use exact-version npm installs:
their integrity comes from npm and the registry. Their installed versions are
checked after installation. Authentication, transfers and tunnels are set up
only when you request them.

## Documentation

| Guide | Covers |
| --- | --- |
| [Quick start](docs/QUICKSTART.md) | Requirements, installation options, authentication, commands and reruns |
| [Provisioning](docs/PROVISIONING.md) | Plan format, ordering, archive retention and acceptance policies |
| [ML profile](docs/ML-PROFILE.md) | Backends, locks, GPU compatibility and the `ml-*` commands |
| [Configuration](docs/CONFIGURATION.md) | Installer switches, paths, package manifests and pin maintenance |
| [Architecture](docs/ARCHITECTURE.md) | Modules and responsibility boundaries |
| [Bundle contract](docs/BUNDLE-CONTRACT.md) | Requirements for workload archives |
| [Troubleshooting](docs/TROUBLESHOOTING.md) | Failures and recovery |
| [Changelog](CHANGELOG.md) | Release changes |

[CI checks](https://github.com/evya1/server-bootstrap/actions/workflows/ci.yml)
and [release downloads](https://github.com/evya1/server-bootstrap/releases).

## Security

Archives are checked before extraction and unsafe paths are rejected. Checksum
verification detects corruption; [Security](SECURITY.md) explains the trust
assumptions, credential handling and private reporting process. See
[Security scanning](docs/SECURITY-SCANNING.md) for release and history checks.

## License

[MIT](LICENSE)
