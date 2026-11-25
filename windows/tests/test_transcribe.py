"""Headless check: transcribe a known clip with the real model and compare to its transcript.

    python tests/test_transcribe.py <wav> <expected.txt> [--model-dir DIR] [--max-wer 0.15]
"""
import argparse
import re
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from scribe.model import Transcriber, ensure_model, read_wav  # noqa: E402


def words(s: str) -> list[str]:
    return re.sub(r"[^a-z0-9' ]+", " ", s.lower()).split()


def wer(ref: list[str], hyp: list[str]) -> float:
    d = list(range(len(hyp) + 1))
    for i, r in enumerate(ref, 1):
        prev, d[0] = d[0], i
        for j, h in enumerate(hyp, 1):
            cur = min(d[j] + 1, d[j - 1] + 1, prev + (r != h))
            prev, d[j] = d[j], cur
    return d[len(hyp)] / max(1, len(ref))


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("wav")
    p.add_argument("expected")
    p.add_argument("--model-dir", default="models")
    p.add_argument("--max-wer", type=float, default=0.15)
    a = p.parse_args()

    model = ensure_model(Path(a.model_dir), progress=lambda st, fr, de: None)
    t0 = time.time()
    tr = Transcriber(model, num_threads=2)
    print(f"model load: {time.time() - t0:.1f}s")
    audio, sr = read_wav(Path(a.wav))
    t0 = time.time()
    text = tr.transcribe(audio, sr)
    dt = time.time() - t0
    expected = Path(a.expected).read_text(encoding="utf-8").strip()
    score = wer(words(expected), words(text))
    print(f"audio: {audio.size / sr:.1f}s  decode: {dt:.2f}s  (RTF {dt / (audio.size / sr):.3f})")
    print(f"expected:   {expected}")
    print(f"transcript: {text}")
    print(f"WER: {score:.3f} (limit {a.max_wer})")
    if not text.strip():
        print("FAIL: empty transcript")
        return 1
    if score > a.max_wer:
        print("FAIL: transcript too far from expected text")
        return 1
    print("PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
