# ML profile

`ml` is an optional profile built into `server-bootstrap`. It installs one
Python 3.12 environment for PyTorch, torchvision, scientific and data work,
image processing, Jupyter, and language and transformer tooling, at:

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
of its artifacts. The PyTorch packages (`torch`, `torchvision`, and `triton`
for CUDA) come from the backend's official PyTorch index,
`https://download.pytorch.org/whl/<backend>`; everything else, including
NVIDIA's CUDA libraries, comes from PyPI. uv's `--torch-backend <backend>`
does this routing, both when the lock is resolved and when it is installed, so
the lock itself names only PyPI. The PyTorch index also carries old copies of
some PyPI packages, such as `requests` and `certifi`; they are never used. The
installer runs `uv pip sync --require-hashes --no-build --torch-backend
<backend>`, so an artifact whose hash is not in the lock is refused and nothing
is built from source. uv index settings in the caller's environment, such as
`UV_EXTRA_INDEX_URL`, are ignored.

A backend is offered only once its lock is committed. `backends.txt` declares
the backends that may be locked. `tools/ml-lock.sh --verify` checks every
committed lock offline and lists any declared backend that has no lock yet.
These locks are committed, for `torch` 2.14.0 and `torchvision` 0.29.0 on
Python 3.12:

| Backend | Architectures | Needs | Validated on |
| --- | --- | --- | --- |
| `cpu` | x86-64, ARM64 | nothing | x86-64: installed and diagnosed. ARM64: every artifact downloaded and hash-checked; not run on ARM64 hardware |
| `cu130` | x86-64 | an NVIDIA driver that reports CUDA 13.0 or newer; a GPU of compute capability 7.5 or newer | GeForce RTX 3060 (compute capability 8.6), driver 595.91.07 |

The `cu130` build also carries code for Hopper and Blackwell GPUs (`sm_90`,
`sm_100`, `sm_120`). It has not been run on them, and passing on the RTX 3060
says nothing about those GPUs; run `ml-doctor` on such a host before relying
on it. No CUDA backend is locked for ARM64.

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
- If writing the state or linking the commands fails after the switch, the
  link is switched back, the recorded state and the command links are restored
  from a copy taken just before the switch, and the new build is deleted. After
  a failed first install nothing is left installed. A run killed at that point
  cannot restore anything itself; the state then still names the previous
  environment, so `ml-status` reports the mismatch and the next run rebuilds.
- A repeat run with the same backend and lock, on an intact environment,
  rebuilds nothing. The environment is exactly its lock: if packages were
  added, removed, or changed in it, the next run rebuilds it from the lock.
  Keep your own extra packages in a project environment.
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
| `ml-doctor` | Check imports, a CPU tensor operation, a vision transform, notebook kernel discovery, and the language stack on synthetic data, then check the GPU. `--json` is available |
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
tools/ml-lock.sh --check-artifacts   # online; downloads each lock's artifacts for its architecture
```

Generation and `--check-artifacts` need the pinned uv (set `SB_UV` to its path
if it is not first on `PATH`) and HTTPS access to `pypi.org` and
`download.pytorch.org`. Generation resolves `requirements.in` for Python 3.12
on `manylinux_2_39`, which Ubuntu 24.04 satisfies. A lock that fails
verification is not written. A lock records the hashes of every file of each
pinned version, for all platforms, so `--verify` cannot tell whether an
architecture is covered. `--check-artifacts` answers that: it downloads, into a
scratch directory, the file each pin selects for the lock's architecture,
routed as the installer routes it, and fails unless every one matches a hash
in the lock and carries that architecture's or a pure-Python wheel tag.
Nothing is installed or run.

A `backends.txt` index must be `https://download.pytorch.org/whl/<backend>`,
the index uv's `--torch-backend` uses. To add a CUDA backend, add its row,
generate its locks, run `--check-artifacts`, and validate it with a real
install and `ml-doctor` on an NVIDIA host for each architecture it lists.

## Language tooling

Every lock must pin `transformers`, `datasets`, `tokenizers`, `sentencepiece`,
`accelerate`, `safetensors`, `huggingface-hub`, `evaluate`, `sacremoses`, and
the `spacy` library, each with a SHA-256; `tools/ml-lock.sh --verify` enforces
this. They never choose the PyTorch build: `torch` and `torchvision` stay
pinned in `requirements.in` and come from the backend's official index. No
model, tokenizer, dataset, metric, or spaCy language model is included.

`ml-doctor` checks this stack using only files it creates in a temporary
directory, which it then removes:

- it trains a word-level tokenizer and a SentencePiece model on four
  sentences;
- it saves a one-layer configuration with random weights as safetensors and
  reloads it;
- it maps an in-memory dataset and tokenizes with Moses and a blank spaCy
  pipeline;
- it confirms that no spaCy language model and no `torchtext` are installed.

It forces the Hugging Face offline switches on for the run.

To try the stack yourself without any download:

```bash
HF_HUB_OFFLINE=1 ml-env python - <<'PY'
import tempfile
from tokenizers import Tokenizer, models, pre_tokenizers, trainers
from transformers import AutoConfig, BertConfig, PreTrainedTokenizerFast

with tempfile.TemporaryDirectory() as workdir:
    tokenizer = Tokenizer(models.WordLevel(unk_token="[UNK]"))
    tokenizer.pre_tokenizer = pre_tokenizers.Whitespace()
    tokenizer.train_from_iterator(["hello local world"], trainers.WordLevelTrainer(special_tokens=["[UNK]"]))
    tokenizer.save(f"{workdir}/tokenizer.json")
    fast = PreTrainedTokenizerFast(tokenizer_file=f"{workdir}/tokenizer.json", unk_token="[UNK]")
    print(fast.decode(fast.encode("hello world", add_special_tokens=False)))
    BertConfig(hidden_size=16, num_hidden_layers=1, num_attention_heads=2).save_pretrained(workdir)
    print(AutoConfig.from_pretrained(workdir, local_files_only=True).hidden_size)
PY
```

It prints `hello world` and `16`.

### Caches and downloads

Models and datasets are downloaded only when you ask for one: for example
`from_pretrained("<model id>")`, `load_dataset("<name>")`, `hf download`, or
`python -m spacy download <model>`. Installation and `ml-doctor` never download
one. Login shells on a bootstrapped host keep every cache under `/workspace`:

| Cache | Location |
| --- | --- |
| Hugging Face models, tokenizers and Hub files | `/workspace/.cache/huggingface/hub` (`HF_HOME`, `HUGGINGFACE_HUB_CACHE`) |
| Hugging Face datasets and `evaluate` metrics | `/workspace/.cache/huggingface/datasets`, `.../metrics`, `.../evaluate` |
| PyTorch Hub | `/workspace/.cache/torch/hub` (`XDG_CACHE_HOME=/workspace/.cache`) |
| Package downloads | `/workspace/.cache/uv` |

A spaCy language model is a Python package, so `python -m spacy download`
adds it to the environment, and the next `server-profile install ml` rebuilds
the environment without it. Export `HF_HUB_OFFLINE=1` in a shell to keep the
Hugging Face libraries offline there too.

### Compatibility boundary

The default profile targets current PyTorch and current transformer APIs.
`torchtext` is not installed: it is no longer developed, and its last release
(0.18.0, April 2024) was built for PyTorch 2.3. Code that needs it belongs in
a separate, opt-in compatibility profile with its own lock. Such a profile
will be added only when a concrete legacy target exists; none ships today.

## Not included

Model weights, datasets, checkpoints, credentials, a notebook or inference
service, the NVIDIA driver, a system CUDA toolkit, a spaCy language model, and
`torchtext`.

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
