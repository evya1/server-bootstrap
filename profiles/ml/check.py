"""Checks for the ml-workbench environment. Runs with that environment's Python.

  check.py verify --lock LOCK   before an environment is switched in: the core
                                packages import at their locked versions and a
                                small tensor operation works
  check.py doctor [--json]      diagnostics on synthetic, in-memory data, and a
                                language smoke test on files it creates itself

Nothing here downloads a model, dataset or package, and nothing is written
outside a temporary directory that is removed afterwards. Every GPU result is
one of pass, fail, skip or n/a, and says which and why.
"""

import argparse
import importlib
import json
import os
import platform
import re
import sys
import tempfile
from importlib import metadata

# Forced, not defaulted: a caller's environment must not be able to turn a
# diagnostic run into a download.
for _name in ("HF_HUB_OFFLINE", "HF_DATASETS_OFFLINE", "TRANSFORMERS_OFFLINE",
              "HF_HUB_DISABLE_TELEMETRY"):
    os.environ[_name] = "1"
os.environ["MPLBACKEND"] = "Agg"
# Quiet libraries: one line per check is the report.
for _name in ("HF_HUB_DISABLE_PROGRESS_BARS", "HF_DATASETS_DISABLE_PROGRESS_BARS", "TQDM_DISABLE"):
    os.environ[_name] = "1"
os.environ["TRANSFORMERS_VERBOSITY"] = "error"

PYTHON_SERIES = (3, 12)

# (distribution, import name) for every package requirements.in names directly.
IMPORTS = (
    ("torch", "torch"),
    ("torchvision", "torchvision"),
    ("numpy", "numpy"),
    ("scipy", "scipy"),
    ("pandas", "pandas"),
    ("scikit-learn", "sklearn"),
    ("matplotlib", "matplotlib"),
    ("pillow", "PIL"),
    ("opencv-python-headless", "cv2"),
    ("jupyterlab", "jupyterlab"),
    ("ipykernel", "ipykernel"),
    ("ipywidgets", "ipywidgets"),
    ("psutil", "psutil"),
    ("transformers", "transformers"),
    ("datasets", "datasets"),
    ("tokenizers", "tokenizers"),
    ("sentencepiece", "sentencepiece"),
    ("accelerate", "accelerate"),
    ("safetensors", "safetensors"),
    ("huggingface-hub", "huggingface_hub"),
    ("evaluate", "evaluate"),
    ("sacremoses", "sacremoses"),
    ("spacy", "spacy"),
)
CORE = ("torch", "torchvision", "numpy")


def normalize(name):
    return re.sub(r"[-_.]+", "-", name).lower()


def lock_pins(path):
    pins = {}
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            match = re.match(r"^([A-Za-z0-9][A-Za-z0-9._-]*)==(\S+)", line)
            if match:
                pins[normalize(match.group(1))] = match.group(2)
    return pins


def tensor_matmul(device="cpu"):
    """A 2x3 by 3x2 product with a known answer."""
    import torch
    a = torch.arange(6, dtype=torch.float32).reshape(2, 3).to(device)
    product = (a @ a.T).cpu().tolist()
    expected = [[5.0, 14.0], [14.0, 50.0]]
    if product != expected:
        raise AssertionError(f"expected {expected}, got {product}")


def cmd_verify(args):
    pins = lock_pins(args.lock)
    lines = [f"python=={platform.python_version()}"]
    if sys.version_info[:2] != PYTHON_SERIES:
        print(f"expected Python {PYTHON_SERIES[0]}.{PYTHON_SERIES[1]}, running "
              f"{platform.python_version()}", file=sys.stderr)
        return 1
    for dist in CORE:
        # The lock pins distributions, so the installed distribution's version
        # is what must match; importing proves it loads.
        version = metadata.version(dist)
        if version != pins.get(dist):
            print(f"{dist} is installed at {version}, the lock pins {pins.get(dist)}",
                  file=sys.stderr)
            return 1
        importlib.import_module(dict(IMPORTS)[dist])
        lines.append(f"{dist}=={version}")
    tensor_matmul("cpu")
    print("\n".join(lines))
    return 0


class Report:
    LABELS = {"pass": "PASS", "fail": "FAIL", "skip": "SKIP", "n/a": "N/A"}

    def __init__(self):
        self.checks = []

    def add(self, status, name, detail):
        self.checks.append({"status": status, "name": name, "detail": detail})

    def run(self, name, function):
        """Record pass with the function's detail, or fail with its error."""
        try:
            self.add("pass", name, function())
        except Exception as error:  # a diagnostic reports, it does not crash
            self.add("fail", name, f"{type(error).__name__}: {error}")

    def counts(self):
        return {status: sum(c["status"] == status for c in self.checks)
                for status in self.LABELS}

    def emit(self, as_json):
        counts = self.counts()
        if as_json:
            print(json.dumps({"checks": self.checks, "summary": counts}, indent=2))
        else:
            for check in self.checks:
                print(f"{self.LABELS[check['status']]:<5} {check['name']}: {check['detail']}")
            print(f"ml-doctor: {counts['pass']} passed, {counts['fail']} failed, "
                  f"{counts['skip']} skipped, {counts['n/a']} not applicable")
        return 1 if counts["fail"] else 0


def check_python():
    if sys.version_info[:2] != PYTHON_SERIES:
        raise RuntimeError(f"running {platform.python_version()}, expected "
                           f"{PYTHON_SERIES[0]}.{PYTHON_SERIES[1]}")
    return f"{platform.python_version()} at {sys.executable}"


def check_import(dist, module_name):
    def run():
        module = importlib.import_module(module_name)
        version = getattr(module, "__version__", None) or metadata.version(dist)
        return f"{module_name} {version}"
    return run


def check_cpu_tensor():
    tensor_matmul("cpu")
    return "2x3 matrix product on synthetic data matches the expected result"


def check_vision():
    import torch
    from torchvision.transforms import functional
    image = torch.arange(12, dtype=torch.uint8).reshape(1, 3, 4)
    flipped = functional.hflip(image).tolist()
    expected = [[[3, 2, 1, 0], [7, 6, 5, 4], [11, 10, 9, 8]]]
    if flipped != expected:
        raise AssertionError(f"expected {expected}, got {flipped}")
    return "horizontal flip of a synthetic 3x4 image matches the expected result"


def check_kernel():
    from jupyter_client.kernelspec import KernelSpecManager
    specs = KernelSpecManager().find_kernel_specs()
    if "python3" not in specs:
        raise RuntimeError(f"no python3 kernel; found {sorted(specs) or 'none'}")
    return f"python3 kernel available ({len(specs)} kernel spec(s))"


# A few sentences are all the language checks ever read: no model, tokenizer,
# dataset or spaCy pipeline is fetched, and what they write stays in workdir.
CORPUS = (
    "the quick brown fox jumps over the lazy dog",
    "a lazy dog sleeps in the warm sun",
    "the brown fox runs past the sleeping dog",
    "quick thinking saves the day",
)


def check_tokenizer(workdir):
    from tokenizers import Tokenizer, models, pre_tokenizers, trainers
    from transformers import PreTrainedTokenizerFast
    tokenizer = Tokenizer(models.WordLevel(unk_token="[UNK]"))
    tokenizer.pre_tokenizer = pre_tokenizers.Whitespace()
    tokenizer.train_from_iterator(CORPUS, trainers.WordLevelTrainer(special_tokens=["[UNK]", "[PAD]"]))
    path = os.path.join(workdir, "tokenizer.json")
    tokenizer.save(path)
    fast = PreTrainedTokenizerFast(tokenizer_file=path, unk_token="[UNK]", pad_token="[PAD]")
    ids = fast.encode("the lazy fox", add_special_tokens=False)
    if fast.decode(ids) != "the lazy fox":
        raise AssertionError(f"round trip gave {fast.decode(ids)!r}")
    if fast.encode("zebra", add_special_tokens=False) != [fast.unk_token_id]:
        raise AssertionError("an unseen word did not map to [UNK]")
    return f"word-level tokenizer trained on {len(CORPUS)} local sentences round-trips through transformers"


def check_config_and_weights(workdir):
    import torch
    from transformers import AutoConfig, AutoModel, BertConfig, BertModel
    config = BertConfig(vocab_size=32, hidden_size=16, num_hidden_layers=1, num_attention_heads=2,
                        intermediate_size=32, max_position_embeddings=16)
    torch.manual_seed(0)
    model = BertModel(config).eval()
    path = os.path.join(workdir, "tiny-model")
    model.save_pretrained(path)
    if not os.path.exists(os.path.join(path, "model.safetensors")):
        raise AssertionError("save_pretrained wrote no model.safetensors")
    loaded = AutoConfig.from_pretrained(path, local_files_only=True)
    if (loaded.hidden_size, loaded.num_hidden_layers) != (16, 1):
        raise AssertionError("the configuration did not round-trip")
    reloaded = AutoModel.from_pretrained(path, local_files_only=True).eval()
    ids = torch.tensor([[1, 2, 3, 4]])
    with torch.no_grad():
        first = model(input_ids=ids).last_hidden_state
        second = reloaded(input_ids=ids).last_hidden_state
    if tuple(first.shape) != (1, 4, 16) or not torch.allclose(first, second):
        raise AssertionError("the reloaded model gives a different output")
    return "a 1-layer configuration and random weights saved as safetensors reload locally with the same output"


def check_sentencepiece():
    import io
    import sentencepiece
    model = io.BytesIO()
    sentencepiece.SentencePieceTrainer.train(
        sentence_iterator=iter(CORPUS), model_writer=model, vocab_size=40,
        hard_vocab_limit=False, minloglevel=2)
    processor = sentencepiece.SentencePieceProcessor(model_proto=model.getvalue())
    decoded = processor.decode(processor.encode("the lazy fox"))
    if decoded != "the lazy fox":
        raise AssertionError(f"round trip gave {decoded!r}")
    return f"model trained in memory ({processor.get_piece_size()} pieces) round-trips"


def check_moses():
    from sacremoses import MosesTokenizer
    tokens = MosesTokenizer(lang="en").tokenize("Hello, world!")
    if tokens != ["Hello", ",", "world", "!"]:
        raise AssertionError(f"got {tokens}")
    return "Moses tokenizer splits punctuation with its bundled rules"


def check_datasets():
    from datasets import Dataset
    counts = Dataset.from_dict({"text": list(CORPUS)}).map(
        lambda row: {"words": len(row["text"].split())})["words"]
    if list(counts) != [len(text.split()) for text in CORPUS]:
        raise AssertionError(f"got {counts}")
    return "an in-memory dataset maps without a cache file"


def check_spacy():
    import spacy
    tokens = [token.text for token in spacy.blank("en")("Hello, world!")]
    if tokens != ["Hello", ",", "world", "!"]:
        raise AssertionError(f"got {tokens}")
    models = spacy.util.get_installed_models()
    if models:
        raise AssertionError(f"a spaCy language model is installed: {', '.join(sorted(models))}")
    return "blank English pipeline tokenizes; no language model is installed"


def check_hub_offline():
    from huggingface_hub import constants
    if not constants.HF_HUB_OFFLINE:
        raise AssertionError("the Hugging Face Hub is not in offline mode")
    return "Hugging Face Hub offline mode is on for this run"


def check_no_torchtext():
    import importlib.util
    if importlib.util.find_spec("torchtext") is not None:
        raise AssertionError("torchtext is installed; it is not part of the default profile")
    return "torchtext is not installed"


def language_checks(report):
    """Local-only checks of the language stack, in a directory removed afterwards."""
    with tempfile.TemporaryDirectory(prefix="ml-doctor-") as workdir:
        report.run("language tokenizer", lambda: check_tokenizer(workdir))
        report.run("language model files", lambda: check_config_and_weights(workdir))
        report.run("sentencepiece", check_sentencepiece)
        report.run("sacremoses", check_moses)
        report.run("datasets", check_datasets)
        if "spacy" in dict(IMPORTS):
            report.run("spacy", check_spacy)
        report.run("hub offline", check_hub_offline)
        report.run("torchtext", check_no_torchtext)


def check_build(backend_cuda):
    import torch
    built = torch.version.cuda
    if backend_cuda == "none":
        if built:
            raise RuntimeError(f"the CPU backend is recorded, but torch was built for CUDA {built}")
        return "CPU build of torch, as the recorded backend expects"
    if not built or not str(built).startswith(backend_cuda):
        raise RuntimeError(f"backend expects CUDA {backend_cuda}, torch reports {built or 'no CUDA'}")
    return f"torch built for CUDA {built}, as the recorded backend expects"


def build_runs_on(arch_list, major, minor):
    """True when a build's architectures include code this device can run.

    A cubin for sm_XY runs on devices of the same major version and a minor of
    at least Y; PTX (compute_XY) is compiled for any device at least XY. An
    architecture-specific cubin such as sm_90a runs only on that exact device.
    """
    for arch in arch_list:
        kind, _, digits = arch.partition("_")
        exact = digits[-1:].isalpha()
        digits = digits.rstrip("abcdefghijklmnopqrstuvwxyz")
        if kind not in ("sm", "compute") or len(digits) < 2 or not digits.isdigit():
            continue
        built = (int(digits[:-1]), int(digits[-1]))
        if exact:
            if kind == "sm" and built == (major, minor):
                return True
        elif kind == "sm" and built[0] == major and built[1] <= minor:
            return True
        elif kind == "compute" and built <= (major, minor):
            return True
    return False


def check_gpu(report, backend_cuda, host_gpu):
    """Every outcome is stated: pass and fail only for checks that ran."""
    name = "gpu"
    if backend_cuda == "none":
        if host_gpu == "none":
            report.add("n/a", name, "CPU backend on a host with no NVIDIA GPU")
        else:
            report.add("skip", name, "CPU backend installed; the NVIDIA GPU is not used or checked")
        return
    import torch
    if not torch.cuda.is_available():
        if host_gpu == "none":
            report.add("skip", name, "no NVIDIA GPU on this host; nothing to check")
        else:
            report.add("fail", name, f"torch cannot use the GPU (host GPU state: {host_gpu})")
        return
    arch_list = set(torch.cuda.get_arch_list())
    for index in range(torch.cuda.device_count()):
        label = f"gpu {index}"

        def run(index=index):
            device = torch.device("cuda", index)
            major, minor = torch.cuda.get_device_capability(index)
            if not build_runs_on(arch_list, major, minor):
                raise RuntimeError(f"compute capability {major}.{minor} is not in this build "
                                   f"({', '.join(sorted(arch_list))})")
            block = torch.empty(16 * 1024 * 1024, dtype=torch.uint8, device=device)
            del block
            tensor_matmul(device)
            torch.cuda.synchronize(device)
            return (f"{torch.cuda.get_device_name(index)} (sm_{major}{minor}): allocation "
                    f"and 2x3 matrix product match the CPU result")
        report.run(label, run)


def cmd_doctor(args):
    report = Report()
    report.run("python", check_python)
    for dist, module_name in IMPORTS:
        report.run(f"import {dist}", check_import(dist, module_name))
    report.run("cpu tensor", check_cpu_tensor)
    report.run("vision", check_vision)
    report.run("notebook kernel", check_kernel)
    language_checks(report)
    report.run("torch build", lambda: check_build(args.backend_cuda))
    try:
        check_gpu(report, args.backend_cuda, args.host_gpu)
    except Exception as error:
        report.add("fail", "gpu", f"{type(error).__name__}: {error}")
    return report.emit(args.json)


def main(argv=None):
    parser = argparse.ArgumentParser(prog="check.py")
    commands = parser.add_subparsers(dest="command", required=True)
    verify = commands.add_parser("verify")
    verify.add_argument("--lock", required=True)
    doctor = commands.add_parser("doctor")
    doctor.add_argument("--json", action="store_true")
    doctor.add_argument("--backend-cuda", default="none")
    doctor.add_argument("--host-gpu", default="none",
                        choices=("none", "nvidia", "nvidia-unusable"))
    args = parser.parse_args(argv)
    return cmd_verify(args) if args.command == "verify" else cmd_doctor(args)


if __name__ == "__main__":
    sys.exit(main())
