"""Make a small synthetic dataset with macOS `say`: one voice, ~60 training clips and
10 held-out clips. Every sentence carries 1-2 domain terms (app names, dev jargon) that a
general speech model tends to mangle. Held-out sentences reuse the terms in NEW carrier
sentences, so the after-training WER says whether the adapter learned the words, not the
sentences.

Output: out/data/{train,heldout}.jsonl + out/data/wav/*.wav (16 kHz mono 16-bit).
"""
import json
import os
import random
import subprocess
import sys

from common import DATA, write_json

TERMS = [
    "Tachys", "FluidAudio", "Parakeet", "Supabase", "kubectl", "Zustand", "Vite", "pnpm",
    "SwiftUI", "Xcode", "MLX", "LoRA", "Core ML", "Grafana", "Prisma", "nginx",
    "OAuth", "Svelte", "Tailwind", "safetensors", "Diarizer", "voiceprint", "notarytool", "Homebrew",
]

TRAIN_ONE = [
    "Open {a} and check the logs.",
    "I pushed a fix for {a} this morning.",
    "Can you restart {a} before the demo?",
    "The {a} build failed again.",
    "Please update {a} to the latest version.",
    "Send me the {a} notes after lunch.",
    "Turn on {a} in the dev branch.",
    "Write a short test for {a}.",
]
TRAIN_TWO = [
    "Let's compare {a} with {b} tomorrow.",
    "We moved the settings from {a} to {b}.",
    "Does {a} work with {b} yet?",
    "Install {a} with {b} first.",
]
HELDOUT = [
    "Yesterday the {a} dashboard showed errors from {b}.",
    "My plan is to ship {a} once {b} is stable.",
    "Remind me to read about {a} and {b} tonight.",
    "Ask the team why {a} is slower than {b}.",
    "Before Friday, migrate {a} and clean up {b}.",
    "I think {a} broke when we touched {b}.",
    "The new laptop still needs {a} and {b}.",
    "Our notes mention {a} next to {b}.",
    "Nobody remembers who added {a} or {b}.",
    "Show me a quick example of {a} with {b}.",
]


def pick_voice() -> str:
    want = os.environ.get("SAY_VOICE", "Samantha")
    out = subprocess.run(["say", "-v", "?"], capture_output=True, text=True).stdout
    names = [l.split()[0] for l in out.splitlines() if l.strip()]
    en = [l.split()[0] for l in out.splitlines() if "en_US" in l]
    if want in names:
        return want
    if en:
        return en[0]
    raise SystemExit("no en_US voice found for `say`:\n" + out)


def say(text: str, voice: str, rate: int, path):
    subprocess.run(["say", "-v", voice, "-r", str(rate), "-o", str(path),
                    "--file-format=WAVE", "--data-format=LEI16@16000", text], check=True)


def main():
    if sys.platform != "darwin":
        raise SystemExit("01_make_dataset.py needs macOS `say`")
    rng = random.Random(7)
    voice = pick_voice()
    (DATA / "wav").mkdir(parents=True, exist_ok=True)

    train = []
    # 24 terms x 1 single-term sentence + 36 two-term sentences = 60 clips; every term
    # appears at least 3 times in training.
    for i, t in enumerate(TERMS):
        train.append((TRAIN_ONE[i % len(TRAIN_ONE)].format(a=t), [t]))
    for i in range(36):
        a, b = TERMS[i % len(TERMS)], TERMS[(i * 7 + 5) % len(TERMS)]
        if a == b:
            b = TERMS[(i + 1) % len(TERMS)]
        train.append((TRAIN_TWO[i % len(TRAIN_TWO)].format(a=a, b=b), [a, b]))

    held = []
    for i, tpl in enumerate(HELDOUT):
        a, b = TERMS[(i * 5) % len(TERMS)], TERMS[(i * 11 + 3) % len(TERMS)]
        held.append((tpl.format(a=a, b=b), [a, b]))

    rates = [165, 175, 185, 195]
    for split, rows in (("train", train), ("heldout", held)):
        items = []
        for i, (text, terms) in enumerate(rows):
            cid = f"{split}_{i:03d}"
            rate = 180 if split == "heldout" else rng.choice(rates)
            say(text, voice, rate, DATA / "wav" / f"{cid}.wav")
            items.append({"id": cid, "wav": f"wav/{cid}.wav", "text": text, "terms": terms, "rate": rate})
        (DATA / f"{split}.jsonl").write_text("\n".join(json.dumps(x) for x in items) + "\n")
        print(f"{split}: {len(items)} clips")
    write_json(DATA / "dataset_info.json", {"voice": voice, "terms": TERMS,
                                             "train": len(train), "heldout": len(held)})
    print("voice:", voice)


if __name__ == "__main__":
    main()
