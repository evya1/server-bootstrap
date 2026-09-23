# ML profile

`ml` is an optional profile built into `server-bootstrap`. It installs one
Python 3.12 environment for PyTorch, torchvision, scientific and data work,
image processing, and Jupyter, at:

```text
/workspace/venvs/ml-workbench
```

Nothing is installed unless you enable it. A foundation-only plan creates no
environment, no profile state, and no `ml-*` command. The profile does not
touch the system Python, the NVIDIA driver, or a system CUDA installation. It
downloads no model or dataset and starts no service.

## Enable it

In a provision plan, after `register_bootstrap`:

```bash
enable_profile "ml" --backend auto
```

The profile ships inside the bootstrap archive, so this line names no URL,
archive, or checksum. It is checked when the plan is read and again after the
archive is extracted, before anything is installed. Enabled profiles install
after `server-accept` and before bundles. `--dry-run` lists them.

On a host that already has the foundation:

```bash
server-profile install ml --dry-run     # preflight and the decision; changes nothing
server-profile install ml               # --backend auto is the default
```

## Backends and locks

Each backend is installed from a frozen lock, one per architecture:

```text
profiles/ml/locks/<backend>-<x86_64|aarch64>.txt
```

A lock pins every package to an exact version and records a SHA-256 for each
of its artifacts. `torch` and `torchvision` come from the backend's official
PyTorch index, `https://download.pytorch.org/whl/<backend>`; everything else
comes from PyPI. The installer runs `uv pip sync --require-hashes --no-build`,
so an artifact whose hash is not in the lock is refused and nothing is built
from source.

A backend is offered only once its lock is committed. `backends.txt` declares
the backends that may be locked. `tools/ml-lock.sh --verify` checks every
committed lock offline and lists any declared backend that has no lock yet.

`--backend auto` chooses:

| Host | Result |
| --- | --- |
| No NVIDIA GPU | `cpu` |
| NVIDIA GPU with a working driver | the locked CUDA backend with the highest CUDA version not above the one `nvidia-smi` reports |
| NVIDIA GPU, but no locked CUDA backend fits the driver | fails |
| NVIDIA hardware, but `nvidia-smi` is missing or failing | fails |

`auto` never falls back to CPU on a host with NVIDIA hardware. To install the
CPU backend there, ask for it by name: `--backend cpu`. A CUDA backend
requested by name still fails if the driver is too old for it.

A CUDA backend is listed only after it has been validated on real hardware.

## Install, repeat, change

- A new environment is built beside the active one, under
  `/workspace/venvs/.ml-workbench/`. It is then verified: the Python version,
  the locked versions of `torch`, `torchvision` and `numpy`, one small tensor
  operation, and an exact match with the lock. Only then does `/workspace/venvs/ml-workbench` switch to
  it, in one rename, and the previous build is removed.
- If any step before the switch fails, the new build is deleted. The previous
  environment, its commands and the recorded state stay as they were.
- A repeat run with the same backend and lock, on an intact environment,
  rebuilds nothing.
- When a newer release ships a changed lock, the next
  `server-profile install ml` builds the new environment and switches to it.
- Changing backend replaces the environment, so it needs `--reconfigure`.
  Without it, the run stops and changes nothing, even if `auto` would now
  resolve to another backend. `--force` rebuilds an up-to-date environment.
- Downloads are cached in `/workspace/.cache/uv`. Restart a running notebook
  after an update.

State is recorded under `/workspace/.setup-state/profiles/ml/`. It holds
`repository-version`, `backend`, `cuda`, `arch`, `lock`, `lock-sha256`,
`environment`, `core-versions` (Python, `torch`, `torchvision`, `numpy`),
`packages` (every installed pin), and `installed-at`. Bundles record their
state under `bundles/` and never use these paths.

## Commands

The installation links five commands into `/usr/local/bin`:

| Command | Purpose |
| --- | --- |
| `ml-env` | Open a shell with the environment active, or run one command in it: `ml-env python train.py` |
| `ml-status` | Show the recorded backend, lock, and versions, and whether this release ships a different lock. Reads state only |
| `ml-doctor` | Check imports, a CPU tensor operation, a vision transform, and notebook kernel discovery on synthetic data, then check the GPU. `--json` is available |
| `ml-preflight` | Check architecture, Python 3.12, uv, the GPU and driver, the backend that would be used, and free disk space. Changes nothing |
| `ml-jupyter` | Run JupyterLab in the foreground on `127.0.0.1:8888` |

`ml-doctor` reports every GPU check as `PASS`, `FAIL`, `SKIP`, or `N/A`, with
the reason. A CUDA backend on a host without a GPU is skipped, not passed. The
CPU backend on a host without a GPU is not applicable. It forces
`HF_HUB_OFFLINE`, `HF_DATASETS_OFFLINE`, and `TRANSFORMERS_OFFLINE` on and
downloads nothing. It exits 1 if any check failed.

## Jupyter over SSH

`ml-jupyter` binds to `127.0.0.1` unless told otherwise, so it is reachable
only through a tunnel:

```bash
ssh -N -L 8888:127.0.0.1:8888 root@<host>
```

Then open the URL, with its token, that `ml-jupyter` prints. `ML_JUPYTER_PORT`
changes the port. `ML_JUPYTER_IP`, or an explicit `--ip`, changes the address,
and a non-loopback address prints a warning. Nothing starts Jupyter for you.

## Settings

| Variable | Default | Meaning |
|---|---:|---|
| `ML_PYTHON` | `/usr/bin/python3.12` | base interpreter; must be Python 3.12 |
| `ML_MIN_FREE_GB` | `10` CPU, `30` CUDA | free space required on the file system that holds the environments |
| `ML_JUPYTER_IP` | `127.0.0.1` | address `ml-jupyter` listens on |
| `ML_JUPYTER_PORT` | `8888` | port `ml-jupyter` listens on |

`WORKSPACE_ROOT`, `VENV_ROOT`, `STATE_ROOT`, and `CACHE_ROOT` move the paths
above as they do for the foundation.

## Maintaining the locks

```bash
tools/ml-lock.sh                     # every backend and architecture in backends.txt
tools/ml-lock.sh --backend cpu --arch x86_64
tools/ml-lock.sh --verify            # offline; --require-all also fails on a pending backend
```

Generation needs the pinned uv and HTTPS access to `pypi.org` and
`download.pytorch.org`. It resolves `requirements.in` for Python 3.12 on
`manylinux_2_39`, which Ubuntu 24.04 satisfies. A lock that fails verification
is not written. To add a CUDA backend, add its row to `backends.txt`, generate
its locks, and validate it on a real NVIDIA host before listing it.

## Not included

Model weights, datasets, checkpoints, credentials, a notebook or inference
service, the NVIDIA driver, a system CUDA toolkit, and `torchtext`.

## Troubleshooting

- **`auto` fails on a GPU host.** Either no locked CUDA backend fits the
  driver, or the driver does not answer. Run `ml-preflight`, fix the driver, or
  install the CPU backend deliberately with `--backend cpu`.
- **`... exists and was not created by this profile`.** Something else is at
  `/workspace/venvs/ml-workbench`. Move it aside, then run the installer again.
- **The disk check fails.** Free space, or set `ML_MIN_FREE_GB` if you know the
  build fits.
- **`ml-status` says the lock differs.** This release ships a newer lock. Run
  `server-profile install ml` to update.
