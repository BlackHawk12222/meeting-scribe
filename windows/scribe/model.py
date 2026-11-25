"""Speech model: download on first launch, then transcribe with sherpa-onnx.

Model: NVIDIA Parakeet TDT 0.6B v2 (English), int8 ONNX export published by the
sherpa-onnx project. License: CC BY 4.0 (NVIDIA). sherpa-onnx: Apache 2.0.
"""

from __future__ import annotations

import hashlib
import logging
import shutil
import tarfile
import time
import urllib.request
from pathlib import Path
from typing import Callable, Optional

import numpy as np

log = logging.getLogger("scribe")

MODEL_NAME = "sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8"
MODEL_URL = (
    "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/"
    f"{MODEL_NAME}.tar.bz2"
)
MODEL_SHA256 = "6fc4426b54aa549a0019b8a75b8dea59164e71790a37ac56a045ad57f915f714"
MODEL_FILES = ("encoder.int8.onnx", "decoder.int8.onnx", "joiner.int8.onnx", "tokens.txt")

# progress(stage, fraction 0..1 or None, detail)
Progress = Optional[Callable[[str, Optional[float], str], None]]


def model_path(models_root: Path) -> Path:
    return Path(models_root) / MODEL_NAME


def is_installed(models_root: Path) -> bool:
    d = model_path(models_root)
    return all((d / f).is_file() and (d / f).stat().st_size > 0 for f in MODEL_FILES)


class _CountingReader:
    """Wraps a file so we can report how far tar extraction has read."""

    def __init__(self, f, total: int, cb: Callable[[int], None]):
        self._f, self._total, self._cb, self._n = f, total, cb, 0

    def read(self, n=-1):
        b = self._f.read(n)
        self._n += len(b)
        self._cb(self._n)
        return b

    def __getattr__(self, name):
        return getattr(self._f, name)


def ensure_model(models_root: Path, progress: Progress = None, url: str = MODEL_URL) -> Path:
    """Download and unpack the model if it is not there yet. Returns the model folder."""
    models_root = Path(models_root)
    models_root.mkdir(parents=True, exist_ok=True)
    if is_installed(models_root):
        return model_path(models_root)

    def report(stage, frac, detail=""):
        if progress:
            progress(stage, frac, detail)

    archive = models_root / f"{MODEL_NAME}.tar.bz2.part"
    log.info("Downloading model from %s", url)
    report("Downloading speech model", 0.0, "")
    req = urllib.request.Request(url, headers={"User-Agent": "Scribe-Windows"})
    sha = hashlib.sha256()
    with urllib.request.urlopen(req, timeout=60) as resp, open(archive, "wb") as out:
        total = int(resp.headers.get("Content-Length") or 0)
        done, t0, last = 0, time.time(), 0.0
        while True:
            chunk = resp.read(1 << 20)
            if not chunk:
                break
            out.write(chunk)
            sha.update(chunk)
            done += len(chunk)
            now = time.time()
            if now - last > 0.2:
                last = now
                mb = done / 1e6
                speed = mb / max(now - t0, 1e-3)
                detail = f"{mb:,.0f} / {total / 1e6:,.0f} MB  ({speed:,.1f} MB/s)" if total else f"{mb:,.0f} MB"
                report("Downloading speech model", done / total if total else None, detail)
    if url == MODEL_URL and sha.hexdigest() != MODEL_SHA256:
        archive.unlink(missing_ok=True)
        raise RuntimeError("The downloaded model file is damaged (checksum mismatch). Please try again.")

    log.info("Unpacking model")
    tmp = models_root / (MODEL_NAME + ".tmp")
    shutil.rmtree(tmp, ignore_errors=True)
    tmp.mkdir()
    size = archive.stat().st_size
    report("Unpacking (about a minute)", 0.0, "")
    with open(archive, "rb") as raw:
        reader = _CountingReader(
            raw, size, lambda n: report("Unpacking (about a minute)", n / size, f"{n / size:.0%}")
        )
        with tarfile.open(fileobj=reader, mode="r|bz2") as tf:
            for member in tf:
                name = Path(member.name)
                if name.is_absolute() or ".." in name.parts:
                    continue
                if not (member.isfile() or member.isdir()):
                    continue
                tf.extract(member, tmp)
    final = model_path(models_root)
    shutil.rmtree(final, ignore_errors=True)
    (tmp / MODEL_NAME).rename(final)
    shutil.rmtree(tmp, ignore_errors=True)
    archive.unlink(missing_ok=True)
    if not is_installed(models_root):
        raise RuntimeError("The speech model did not unpack correctly.")
    report("Ready", 1.0, "")
    return final


class Transcriber:
    """Parakeet TDT through sherpa-onnx's offline transducer recognizer."""

    def __init__(self, model_dir: Path, num_threads: int = 2):
        import sherpa_onnx  # imported lazily: it is large

        d = Path(model_dir)
        t0 = time.time()
        self._rec = sherpa_onnx.OfflineRecognizer.from_transducer(
            encoder=str(d / "encoder.int8.onnx"),
            decoder=str(d / "decoder.int8.onnx"),
            joiner=str(d / "joiner.int8.onnx"),
            tokens=str(d / "tokens.txt"),
            num_threads=num_threads,
            model_type="nemo_transducer",
            decoding_method="greedy_search",
        )
        log.info("Model loaded in %.1fs (%d threads)", time.time() - t0, num_threads)

    def transcribe(self, samples: np.ndarray, sample_rate: int) -> str:
        samples = np.asarray(samples, dtype=np.float32).reshape(-1)
        if samples.size < sample_rate * 0.2:
            return ""
        # Parakeet needs a little trailing silence or it can drop the last word.
        pad = np.zeros(int(sample_rate * 0.4), dtype=np.float32)
        stream = self._rec.create_stream()
        stream.accept_waveform(sample_rate, np.concatenate([samples, pad]))
        self._rec.decode_stream(stream)
        return stream.result.text.strip()


def read_wav(path: Path) -> tuple[np.ndarray, int]:
    """Read a 16-bit PCM wav (mono or stereo) as float32 mono."""
    import wave

    with wave.open(str(path), "rb") as w:
        sr, ch, width = w.getframerate(), w.getnchannels(), w.getsampwidth()
        raw = w.readframes(w.getnframes())
    if width != 2:
        raise ValueError("only 16-bit wav files are supported")
    a = np.frombuffer(raw, dtype=np.int16).astype(np.float32) / 32768.0
    if ch > 1:
        a = a.reshape(-1, ch).mean(axis=1)
    return a, sr
