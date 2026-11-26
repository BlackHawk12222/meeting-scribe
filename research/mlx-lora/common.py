"""Shared helpers for the MLX LoRA feasibility test (Scribe 0.7.6 research, step one).

Model:   mlx-community/parakeet-tdt-0.6b-v2 (NVIDIA Parakeet TDT 0.6B v2, converted for MLX)
Runtime: parakeet-mlx (Apache-2.0) for the network definition + greedy TDT decoding.
Added here: a WAV loader (no ffmpeg), a SentencePiece tokenizer, LoRA wrappers,
a pure-MLX TDT (token-and-duration transducer) loss, WER, and memory probes.

This is research code. Nothing here ships in Scribe.app.
"""
from __future__ import annotations

import json
import math
import os
import platform
import re
import resource
import sys
import time
import wave
from pathlib import Path

import mlx.core as mx
import mlx.nn as nn
import numpy as np

HERE = Path(__file__).resolve().parent
OUT = Path(os.environ.get("MLX_LORA_OUT", HERE / "out")).resolve()
DATA = OUT / "data"
MODEL_ID = os.environ.get("PARAKEET_MODEL", "mlx-community/parakeet-tdt-0.6b-v2")
LABEL = "GitHub runner (virtual M1, synthetic voice)"


# ---------------------------------------------------------------- device / memory
def setup_device() -> str:
    """MLX_DEVICE=cpu forces the CPU. Default: GPU (Metal) when MLX reports it."""
    want = os.environ.get("MLX_DEVICE", "").lower()
    if want == "cpu":
        mx.set_default_device(mx.cpu)
    return str(mx.default_device())


def metal_available() -> bool:
    try:
        return bool(mx.metal.is_available())
    except Exception:
        return False


def peak_mlx_bytes() -> int:
    for fn in ("get_peak_memory",):
        if hasattr(mx, fn):
            return int(getattr(mx, fn)())
    try:
        return int(mx.metal.get_peak_memory())
    except Exception:
        return -1


def reset_peak():
    try:
        if hasattr(mx, "reset_peak_memory"):
            mx.reset_peak_memory()
        else:
            mx.metal.reset_peak_memory()
    except Exception:
        pass


def rss_peak_bytes() -> int:
    r = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    return int(r if sys.platform == "darwin" else r * 1024)  # macOS: bytes, Linux: KiB


def env_info() -> dict:
    import importlib.metadata as md

    def ver(p):
        try:
            return md.version(p)
        except Exception:
            return None

    return {
        "label": LABEL,
        "python": platform.python_version(),
        "platform": platform.platform(),
        "machine": platform.machine(),
        "mlx": ver("mlx"),
        "parakeet_mlx": ver("parakeet-mlx"),
        "metal_available": metal_available(),
        "device": str(mx.default_device()),
        "model": MODEL_ID,
    }


# ---------------------------------------------------------------- model / audio / tokens
def load_model(dtype=None):
    from parakeet_mlx import from_pretrained

    dt = dtype or (mx.float32 if os.environ.get("MLX_FP32") == "1" else mx.bfloat16)
    t0 = time.time()
    model = from_pretrained(MODEL_ID, dtype=dt)
    return model, time.time() - t0


def model_dir() -> Path:
    from huggingface_hub import snapshot_download

    return Path(snapshot_download(MODEL_ID, allow_patterns=["config.json", "tokenizer.model", "model.safetensors"]))


def load_tokenizer(model):
    import sentencepiece as spm

    sp = spm.SentencePieceProcessor(model_file=str(model_dir() / "tokenizer.model"))
    vocab = model.vocabulary
    same = sum(sp.id_to_piece(i) == vocab[i] for i in range(len(vocab)))
    if sp.get_piece_size() != len(vocab) or same != len(vocab):
        raise RuntimeError(f"tokenizer.model does not match joint vocabulary ({same}/{len(vocab)})")
    return sp


def read_wav(path: Path, sr: int = 16000) -> mx.array:
    with wave.open(str(path), "rb") as w:
        if w.getframerate() != sr or w.getsampwidth() != 2:
            raise ValueError(f"{path}: need {sr} Hz 16-bit PCM, got {w.getframerate()} Hz {8*w.getsampwidth()}-bit")
        n = w.getnchannels()
        a = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).astype(np.float32) / 32768.0
        if n > 1:
            a = a.reshape(-1, n).mean(axis=1)
    return mx.array(a)


def mel_for(model, path: Path) -> mx.array:
    from parakeet_mlx.audio import get_logmel

    audio = read_wav(path, model.preprocessor_config.sample_rate)
    mel = get_logmel(audio.astype(mx.float32), model.preprocessor_config)  # (1, frames, 128)
    return mel


def transcribe(model, path: Path) -> str:
    mel = mel_for(model, path).astype(model.encoder.pre_encode.out.weight.dtype)
    res = model.generate(mel)[0]
    return res.text.strip()


# ---------------------------------------------------------------- dataset
def load_split(name: str) -> list[dict]:
    p = DATA / f"{name}.jsonl"
    return [json.loads(l) for l in p.read_text().splitlines() if l.strip()]


# ---------------------------------------------------------------- WER
_punct = re.compile(r"[^\w\s']")


def normalize(s: str) -> list[str]:
    s = s.lower().replace("-", " ")
    s = _punct.sub(" ", s)
    return s.split()


def edit_distance(a: list[str], b: list[str]) -> int:
    d = list(range(len(b) + 1))
    for i in range(1, len(a) + 1):
        prev, d[0] = d[0], i
        for j in range(1, len(b) + 1):
            cur = d[j]
            d[j] = min(d[j] + 1, d[j - 1] + 1, prev + (a[i - 1] != b[j - 1]))
            prev = cur
    return d[len(b)]


def term_hit(term: str, hyp: str) -> bool:
    t = " ".join(normalize(term))
    h = " " + " ".join(normalize(hyp)) + " "
    return f" {t} " in h


def evaluate(model, items: list[dict]) -> dict:
    errs = words = hits = terms = 0
    rows = []
    t0 = time.time()
    for it in items:
        hyp = transcribe(model, DATA / it["wav"])
        ref = it["text"]
        e = edit_distance(normalize(ref), normalize(hyp))
        n = len(normalize(ref))
        errs += e
        words += n
        th = [term_hit(t, hyp) for t in it["terms"]]
        hits += sum(th)
        terms += len(th)
        rows.append({"id": it["id"], "ref": ref, "hyp": hyp, "word_errors": e, "words": n,
                     "terms": it["terms"], "terms_hit": th})
    return {
        "wer": errs / max(words, 1),
        "word_errors": errs,
        "words": words,
        "term_accuracy": hits / max(terms, 1),
        "terms_hit": hits,
        "terms_total": terms,
        "clips": len(items),
        "seconds": round(time.time() - t0, 2),
        "rows": rows,
    }


# ---------------------------------------------------------------- LoRA
class LoRALinear(nn.Module):
    """y = W x + (alpha/r) * B(A(x)); W frozen, A/B trainable (B starts at zero)."""

    def __init__(self, base: nn.Linear, r: int = 8, alpha: float = 16.0):
        super().__init__()
        out_dim, in_dim = base.weight.shape
        self.base = base
        s = 1.0 / math.sqrt(in_dim)
        self.lora_a = mx.random.uniform(low=-s, high=s, shape=(in_dim, r))
        self.lora_b = mx.zeros((r, out_dim))
        self.scale = alpha / r

    def __call__(self, x):
        y = self.base(x)
        z = (x.astype(mx.float32) @ self.lora_a) @ self.lora_b
        return y + (self.scale * z).astype(y.dtype)


DEFAULT_TARGETS = ("self_attn.linear_q", "self_attn.linear_k", "self_attn.linear_v", "self_attn.linear_out")


def apply_lora(model, r: int, alpha: float, targets=None, layers=None) -> int:
    """Freeze everything, then wrap the named Linear layers of the chosen encoder blocks."""
    targets = tuple(targets or DEFAULT_TARGETS)
    model.freeze()
    n_layers = len(model.encoder.layers)
    idx = list(range(n_layers)) if layers is None else list(layers)
    count = 0
    for i in idx:
        block = model.encoder.layers[i]
        for t in targets:
            parent_name, leaf = t.rsplit(".", 1) if "." in t else ("", t)
            parent = block
            for p in filter(None, parent_name.split(".")):
                parent = getattr(parent, p)
            base = getattr(parent, leaf)
            if not isinstance(base, nn.Linear):
                raise TypeError(f"layer {i} {t} is {type(base).__name__}, not Linear")
            setattr(parent, leaf, LoRALinear(base, r=r, alpha=alpha))
            count += 1
    return count


def lora_params(model) -> dict:
    from mlx.utils import tree_flatten

    return dict(tree_flatten(model.trainable_parameters()))


def parse_layers(spec: str | None, n: int):
    """'all' | 'last:8' | '0,1,2'"""
    if not spec or spec == "all":
        return None
    if spec.startswith("last:"):
        k = int(spec.split(":")[1])
        return list(range(n - k, n))
    return [int(x) for x in spec.split(",")]


# ---------------------------------------------------------------- TDT loss (pure MLX)
NEG = -1e30


def tdt_loss(joint: mx.array, targets: list[list[int]], t_lens: list[int], u_lens: list[int],
             blank: int, durations: list[int], sigma: float = 0.0) -> mx.array:
    """Negative log-likelihood of each target under a Token-and-Duration Transducer.

    joint:   (B, T, U+1, V+1+D) raw joint logits (V tokens + blank, then D duration logits)
    Follows NeMo's TDT recursion (Xu et al. 2023): a token may advance 0..max frames,
    a blank advances >=1 frame; the path must end with a blank landing exactly on frame T.
    The duration-0 token chain inside one frame is solved in closed form with a masked
    cumulative log-sum-exp, so the Python loop is over frames only.
    Returns per-utterance NLL, shape (B,).
    """
    B, T, U1, _ = joint.shape
    U = U1 - 1
    nv = blank + 1
    joint = joint.astype(mx.float32)
    tok = nn.log_softmax(joint[..., :nv], axis=-1) - sigma  # (B,T,U1,V+1)
    dur = nn.log_softmax(joint[..., nv:], axis=-1)  # (B,T,U1,D)
    lb = tok[..., blank]  # (B,T,U1)
    if U > 0:
        tgt = mx.array([row + [0] * (U - len(row)) for row in targets], dtype=mx.int32)
        ly = mx.take_along_axis(tok[:, :, :U, :], mx.broadcast_to(tgt[:, None, :, None], (B, T, U, 1)), axis=3)[..., 0]
    else:
        ly = mx.zeros((B, T, 0))
    i0 = durations.index(0) if 0 in durations else None
    tri = mx.tril(mx.ones((U1, U1), dtype=mx.bool_))  # tri[u, k] = k <= u
    negcol = mx.full((B, 1), NEG)

    alphas = []
    for t in range(T):
        if t == 0:
            A = mx.concatenate([mx.zeros((B, 1)), mx.full((B, U), NEG)], axis=1) if U > 0 else mx.zeros((B, 1))
        else:
            terms = []
            for i, d in enumerate(durations):
                if d == 0 or t - d < 0:
                    continue
                prev = alphas[t - d]
                terms.append(prev + lb[:, t - d, :] + dur[:, t - d, :, i])
                if U > 0:
                    terms.append(mx.concatenate([negcol, prev[:, :U] + ly[:, t - d, :] + dur[:, t - d, :U, i]], axis=1))
            A = mx.logsumexp(mx.stack(terms, axis=0), axis=0)
        if i0 is not None and U > 0:
            step = ly[:, t, :] + dur[:, t, :U, i0]  # (B,U) cost of (t,j)->(t,j+1)
            C = mx.concatenate([mx.zeros((B, 1)), mx.cumsum(step, axis=1)], axis=1)  # (B,U1)
            M = (A - C)[:, None, :] + C[:, :, None]  # M[b,u,k] = A[k] + sum_{j=k}^{u-1} step[j]
            A = mx.logsumexp(mx.where(tri[None], M, NEG), axis=2)
        alphas.append(A)

    out = []
    for b in range(B):
        Tb, Ub = t_lens[b], u_lens[b]
        fin = []
        for i, d in enumerate(durations):
            if d == 0 or Tb - d < 0:
                continue
            fin.append(alphas[Tb - d][b, Ub] + lb[b, Tb - d, Ub] + dur[b, Tb - d, Ub, i])
        out.append(-mx.logsumexp(mx.stack(fin)))
    return mx.stack(out)


def forward_joint(model, mel: mx.array, tokens: list[int]):
    """Encoder (with any LoRA) -> prediction net (frozen, teacher forced) -> joint logits."""
    feats, lens = model.encoder(mel)
    blank = len(model.vocabulary)
    y = mx.array([[blank] + tokens], dtype=mx.int32)  # blank_as_pad: blank = SOS = zero vector
    emb = model.decoder.prediction["embed"](y)
    emb = mx.where((y == blank)[..., None], 0.0, emb)
    pred, _ = model.decoder.prediction["dec_rnn"](emb.astype(feats.dtype))
    pred = mx.stop_gradient(pred.astype(feats.dtype))
    joint = model.joint(feats, pred)  # (1,T,U+1,V+1+D)
    return joint, int(lens[0])


def write_json(path: Path, obj):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(obj, indent=2))
