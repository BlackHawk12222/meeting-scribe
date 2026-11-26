"""Step-two dataset: does the adapter hurt normal English?

Splits (out/data/*.jsonl, 16 kHz mono 16-bit WAV in out/data/wav/):
  train            60 domain clips, training voice (Samantha) - same sentences as step one
  heldout_same     10 domain held-out clips, training voice (same as step one, for reference)
  heldout_unseen   10 domain held-out clips, spoken by voices NOT used in training
  regression       20 everyday dictation sentences, voices NOT used in training
  replay           40 other everyday sentences, training voice (used only by config C)
  libri            up to 20 LibriSpeech test-clean utterances (public, real speech), optional

Voices: the training voice is fixed; unseen voices are picked from a preference list of
English voices that macOS ships, skipping novelty voices. Everything is synthetic except libri.
"""
import io
import json
import os
import random
import re
import subprocess
import sys
import tarfile
import urllib.request
import wave

import numpy as np

from common import DATA, write_json

sys.path.insert(0, os.path.dirname(__file__))
ds1 = __import__("01_make_dataset")
TERMS, TRAIN_ONE, TRAIN_TWO, HELDOUT = ds1.TERMS, ds1.TRAIN_ONE, ds1.TRAIN_TWO, ds1.HELDOUT

TRAIN_VOICE = os.environ.get("SAY_VOICE", "Samantha")
UNSEEN_PREF = ["Daniel", "Karen", "Moira", "Rishi", "Tessa", "Alex", "Allison", "Ava", "Tom", "Susan",
               "Eddy (English (US))", "Flo (English (US))", "Reed (English (US))", "Sandy (English (US))",
               "Shelley (English (US))", "Rocko (English (US))", "Fred", "Ralph", "Kathy"]
NOVELTY = {"Albert", "Bad News", "Bahh", "Bells", "Boing", "Bubbles", "Cellos", "Good News", "Jester",
           "Organ", "Superstar", "Trinoids", "Whisper", "Wobble", "Zarvox", "Junior", "Grandma", "Grandpa"}

# 20 everyday dictation sentences (never trained on). No digits, so number formatting can't skew WER.
REGRESSION = [
    "Can you pick up milk and bread on the way home?",
    "I'm running about ten minutes late, so start without me.",
    "Let's meet at the coffee shop near the library tomorrow morning.",
    "Please remind me to call the dentist after lunch.",
    "The weather looks cold this weekend, so bring a warm jacket.",
    "Thanks for dinner last night, it was really good.",
    "I left my keys on the kitchen counter again.",
    "We should plan a trip to the lake before summer ends.",
    "Could you send me the photos from the birthday party?",
    "My phone battery is almost dead, so I'll text you later.",
    "Don't forget to feed the dog before you leave.",
    "The meeting moved to Thursday afternoon because of the holiday.",
    "I finished the book you lent me and loved the ending.",
    "Let me know if you need a ride to practice.",
    "The store was out of apples, so I bought oranges instead.",
    "Turn left at the next light and park behind the building.",
    "I think it's going to rain, so take an umbrella.",
    "Happy birthday, I hope you have a wonderful day.",
    "Can we move our call to later this evening?",
    "The movie starts at seven, so let's eat early.",
]
# 40 other everyday sentences for replay (config C). Disjoint from REGRESSION.
REPLAY = [
    "I need to wash the car this weekend.", "She said the package should arrive on Monday.",
    "Let's grab lunch somewhere quiet today.", "The kids are playing outside in the snow.",
    "Please close the window before you go to bed.", "I'll be at the gym until six.",
    "Do you want pizza or tacos for dinner?", "The garden needs water every morning.",
    "My sister is visiting us next week.", "Remember to bring your library card.",
    "The bus was late again this morning.", "Can you help me move the couch later?",
    "I made a list of things we need from the store.", "We watched a funny movie last night.",
    "The printer is out of paper again.", "Let's take the long way home through the park.",
    "I lost my headphones somewhere in the house.", "Grandma called to say hello.",
    "The coffee is too hot to drink right now.", "Please turn the music down a little.",
    "I can't find the charger for my laptop.", "We're going camping if the weather stays nice.",
    "The baby finally fell asleep.", "Text me when you get to the airport.",
    "I really like the new paint color in the hallway.", "Our neighbors have a very friendly cat.",
    "Put the leftovers in the fridge, please.", "The game was canceled because of the storm.",
    "I want to learn how to play the guitar.", "Could you water the plants while I'm away?",
    "The road is closed, so take the detour.", "He forgot his lunch on the table.",
    "Let's clean the garage on Saturday.", "My shoes are still wet from the rain.",
    "Please sign the form and bring it back tomorrow.", "The sunset over the field was beautiful.",
    "We ran out of eggs and butter.", "I'm going to bed early tonight.",
    "The teacher moved the test to Friday.", "Thanks for helping me with the dishes.",
]

LIBRI_URLS = ["https://www.openslr.org/resources/12/test-clean.tar.gz",
              "https://us.openslr.org/resources/12/test-clean.tar.gz"]


def list_voices():
    out = subprocess.run(["say", "-v", "?"], capture_output=True, text=True).stdout
    voices = []
    for line in out.splitlines():
        m = re.match(r"^(.*?)\s+([a-z]{2,3}_[A-Z0-9]{2,3})\s+#", line)
        if m:
            voices.append((m.group(1).strip(), m.group(2)))
    return voices, out


def say(text, voice, rate, path):
    subprocess.run(["say", "-v", voice, "-r", str(rate), "-o", str(path),
                    "--file-format=WAVE", "--data-format=LEI16@16000", text], check=True)


def write_wav(path, audio, sr=16000):
    pcm = (np.clip(audio, -1, 1) * 32767).astype(np.int16)
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(sr)
        w.writeframes(pcm.tobytes())


def fetch_libri(n=20, per_chapter=2, max_sec=12.0):
    """Stream test-clean.tar.gz and keep the first n short utterances, at most per_chapter per chapter."""
    import soundfile as sf

    for url in LIBRI_URLS:
        try:
            trans, audio = {}, {}
            per = {}
            with urllib.request.urlopen(url, timeout=60) as r:
                with tarfile.open(fileobj=r, mode="r|gz") as tf:
                    for m in tf:
                        if not m.isfile():
                            continue
                        name = m.name.rsplit("/", 1)[-1]
                        if name.endswith(".trans.txt"):
                            for line in tf.extractfile(m).read().decode().splitlines():
                                uid, txt = line.split(" ", 1)
                                trans[uid] = txt
                        elif name.endswith(".flac"):
                            uid = name[:-5]
                            chap = uid.rsplit("-", 1)[0]
                            if per.get(chap, 0) >= per_chapter:
                                continue
                            a, sr = sf.read(io.BytesIO(tf.extractfile(m).read()), dtype="float32")
                            if sr != 16000 or len(a) / sr > max_sec or len(a) / sr < 3:
                                continue
                            audio[uid] = a
                            per[chap] = per.get(chap, 0) + 1
                        ready = [u for u in audio if u in trans]
                        if len(ready) >= n:
                            break
            ready = sorted(u for u in audio if u in trans)[:n]
            return [(u, trans[u], audio[u]) for u in ready], url
        except Exception as e:  # optional set: report and move on
            print("libri fetch failed from", url, ":", repr(e))
    return [], None


def main():
    if sys.platform != "darwin":
        raise SystemExit("11_make_dataset_v2.py needs macOS `say`")
    voices, raw = list_voices()
    print("say voices available:\n" + raw)
    names = {v for v, _ in voices}
    en = {v for v, loc in voices if loc.startswith("en_")}
    if TRAIN_VOICE not in names:
        raise SystemExit(f"training voice {TRAIN_VOICE} not installed")
    unseen = [v for v in UNSEEN_PREF if v in en and v != TRAIN_VOICE]
    if not unseen:
        unseen = sorted(v for v in en if v != TRAIN_VOICE and v.split(" (")[0] not in NOVELTY)
    unseen = unseen[:5]
    if not unseen:
        raise SystemExit("no unseen English voice available for the regression set")
    print("training voice:", TRAIN_VOICE, "| unseen voices:", unseen)

    rng = random.Random(7)
    wav = DATA / "wav"
    wav.mkdir(parents=True, exist_ok=True)

    train = []
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
    plan = {
        "train": [(t, terms, TRAIN_VOICE, rng.choice(rates)) for t, terms in train],
        "heldout_same": [(t, terms, TRAIN_VOICE, 180) for t, terms in held],
        "heldout_unseen": [(t, terms, unseen[i % len(unseen)], 180) for i, (t, terms) in enumerate(held)],
        "regression": [(t, [], unseen[i % len(unseen)], 180) for i, t in enumerate(REGRESSION)],
        "replay": [(t, [], TRAIN_VOICE, rng.choice(rates)) for t in REPLAY],
    }
    counts = {}
    for split, rows in plan.items():
        items = []
        for i, (text, terms, voice, rate) in enumerate(rows):
            cid = f"{split}_{i:03d}"
            say(text, voice, rate, wav / f"{cid}.wav")
            items.append({"id": cid, "wav": f"wav/{cid}.wav", "text": text, "terms": terms,
                          "voice": voice, "rate": rate})
        (DATA / f"{split}.jsonl").write_text("\n".join(json.dumps(x) for x in items) + "\n")
        counts[split] = len(items)
        print(f"{split}: {len(items)} clips")
    # run1 scripts read heldout.jsonl; keep it pointing at the same-voice set
    (DATA / "heldout.jsonl").write_text((DATA / "heldout_same.jsonl").read_text())

    libri_url = None
    if os.environ.get("LIBRI", "1") == "1":
        rows, libri_url = fetch_libri()
        items = []
        for uid, text, a in rows:
            write_wav(wav / f"libri_{uid}.wav", a)
            items.append({"id": f"libri_{uid}", "wav": f"wav/libri_{uid}.wav", "text": text.lower(),
                          "terms": [], "voice": "LibriSpeech test-clean (real speech)"})
        if items:
            (DATA / "libri.jsonl").write_text("\n".join(json.dumps(x) for x in items) + "\n")
        counts["libri"] = len(items)
        print("libri:", len(items), "clips from", libri_url)

    write_json(DATA / "dataset_info.json", {"train_voice": TRAIN_VOICE, "unseen_voices": unseen,
                                             "terms": TERMS, "counts": counts, "libri_source": libri_url})


if __name__ == "__main__":
    main()
