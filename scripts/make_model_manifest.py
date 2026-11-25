#!/usr/bin/env python3
"""Writes Resources/ModelManifest.json: the list of model "components" Scribe needs,
with every file's size and hash, pinned to an exact Hugging Face commit.

Why: the app compares this manifest with what's already on disk, so it downloads
only files that are missing or changed — never a model it already has. An app
update ships a new manifest; if a model's hash didn't change, nothing is downloaded.

Run it again only when you bump FluidAudio (new model files) or want newer models:
    python3 scripts/make_model_manifest.py
Uses only the Python standard library.
"""
import hashlib, json, os, sys, urllib.request

HF = "https://huggingface.co"

# What FluidAudio 0.18.3 loads (ModelNames.swift). `fluid_revision` is what FluidAudio
# expects in its cache marker ("main" = no marker); `commit` below pins the exact files.
COMPONENTS = [
    dict(id="asr-v2", title="Speech model · English (Parakeet v2)", group="dictation",
         repo="FluidInference/parakeet-tdt-0.6b-v2-coreml", fluid_revision="main",
         required=["Preprocessor.mlmodelc", "Encoder.mlmodelc", "Decoder.mlmodelc",
                   "JointDecision.mlmodelc", "parakeet_vocab.json"]),
    dict(id="asr-v3", title="Speech model · 25 languages (Parakeet v3)", group="dictation",
         repo="FluidInference/parakeet-tdt-0.6b-v3-coreml", fluid_revision="main",
         required=["Preprocessor.mlmodelc", "Encoder.mlmodelc", "Decoder.mlmodelc",
                   "JointDecisionv3.mlmodelc", "parakeet_vocab.json"]),
    dict(id="vad", title="Voice detector (Silero VAD)", group="dictation",
         repo="FluidInference/silero-vad-coreml", fluid_revision="main",
         required=["silero-vad-unified-256ms-v6.2.1.mlmodelc"]),
    dict(id="diarizer", title="Speaker models (who spoke when)", group="meetings",
         repo="FluidInference/speaker-diarization-coreml",
         fluid_revision="df2625ac79a7ac6b65ad868fee6d80f320da4232",
         required=["Segmentation.mlmodelc", "FBank.mlmodelc", "Embedding.mlmodelc",
                   "PldaRho.mlmodelc", "plda-parameters.json"]),
    # 0.5: "Accurate" speech model option (post-trained v3, 25 languages).
    dict(id="asr-ultra", title="Speech model · Accurate (Parakeet Ultra)", group="optional",
         repo="FluidInference/parakeet-ultra-coreml", fluid_revision="main",
         required=["Preprocessor.mlmodelc", "Encoder.mlmodelc", "Decoder.mlmodelc",
                   "JointDecisionv3.mlmodelc", "parakeet_vocab.json"]),
    # 0.5: small CTC model that checks your vocabulary words against the audio.
    dict(id="ctc-110m", title="Vocabulary helper (Parakeet CTC 110M)", group="optional",
         repo="FluidInference/parakeet-ctc-110m-coreml", fluid_revision="main",
         required=["MelSpectrogram.mlmodelc", "AudioEncoder.mlmodelc", "vocab.json", "tokenizer.json"]),
    # voice-test: optional Whisper dictation engines (WhisperKit, Core ML, by Argmax). Not loaded by
    # FluidAudio: `subfolder` = take every file in that folder of the repo; `only` = just these files.
    dict(id="whisper-turbo", title="Speech model · Whisper large-v3 turbo (WhisperKit)", group="optional",
         repo="argmaxinc/whisperkit-coreml", fluid_revision="main",
         subfolder="openai_whisper-large-v3-v20240930_turbo_632MB"),
    dict(id="whisper-distil", title="Speech model · Whisper distil-large-v3 (WhisperKit)", group="optional",
         repo="argmaxinc/whisperkit-coreml", fluid_revision="main",
         subfolder="distil-whisper_distil-large-v3_594MB"),
    dict(id="whisper-tokenizer", title="Whisper tokenizer", group="optional",
         repo="openai/whisper-large-v3", fluid_revision="main",
         only=["config.json", "tokenizer.json", "tokenizer_config.json", "special_tokens_map.json", "added_tokens.json"]),
]


def get(url):
    req = urllib.request.Request(url, headers={"User-Agent": "scribe-manifest"})
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.load(r), r.headers.get("Link")


def tree(repo, commit, path):
    url = f"{HF}/api/models/{repo}/tree/{commit}/{path}?recursive=true&expand=false"
    out = []
    while url:
        data, link = get(url)
        out += data
        url = None
        if link and 'rel="next"' in link:
            url = link.split(";")[0].strip("<> ")
    return out


def main():
    root = os.path.join(os.path.dirname(__file__), "..")
    path = os.path.join(root, "Resources", "ModelManifest.json")
    # --add: keep every component already in the manifest EXACTLY as pinned (so nobody
    # re-downloads a model) and only add the ones that are missing.
    keep = {}
    if "--add" in sys.argv and os.path.exists(path):
        keep = {c["id"]: c for c in json.load(open(path))["components"]}
    comps = []
    for c in COMPONENTS:
        if c["id"] in keep:
            comps.append(keep[c["id"]])
            print(f"{c['id']:9} kept as pinned ({keep[c['id']]['version']})")
            continue
        rev = c["fluid_revision"]
        commit = get(f"{HF}/api/models/{c['repo']}/revision/{rev}")[0]["sha"]
        files = []
        if c.get("subfolder") or c.get("only"):
            if c.get("subfolder"):
                files = [i for i in tree(c["repo"], commit, c["subfolder"]) if i["type"] == "file"]
            else:
                files = [i for i in tree(c["repo"], commit, "") if i["type"] == "file" and i["path"] in c["only"]]
            c["required"] = [c["subfolder"]] if c.get("subfolder") else c["only"]
            root_items = []
        else:
            root_items = tree(c["repo"], commit, "")
        for item in root_items:
            p = item["path"]
            if item["type"] != "file" or "/" in p:
                continue
            if p in c["required"] or p.endswith((".json", ".txt")):
                files.append(item)
        for req in ([] if (c.get("subfolder") or c.get("only")) else c["required"]):
            if req.endswith((".mlmodelc", ".mlpackage")):
                files += [i for i in tree(c["repo"], commit, req) if i["type"] == "file"]
        entries = []
        for f in sorted(files, key=lambda x: x["path"]):
            lfs = f.get("lfs")
            entries.append({
                "path": f["path"],
                "size": int(f["size"]),
                # Big files: SHA-256 of the content. Small files: git's blob SHA-1.
                "sha256": lfs["oid"] if lfs else None,
                "gitSha1": None if lfs else f["oid"],
            })
        for req in c["required"]:
            if not any(e["path"] == req or e["path"].startswith(req + "/") for e in entries):
                sys.exit(f"{c['id']}: {req} not found in {c['repo']}@{commit}")
        digest = hashlib.sha256("\n".join(
            f"{e['path']} {e['size']} {e['sha256'] or e['gitSha1']}" for e in entries).encode()).hexdigest()
        comps.append({
            "id": c["id"], "title": c["title"], "group": c["group"], "repo": c["repo"],
            "fluidRevision": rev, "commit": commit,
            # The component's version = short commit + content hash. Changes only if a file changes.
            "version": commit[:10], "hash": digest,
            "totalBytes": sum(e["size"] for e in entries), "files": entries,
        })
        print(f"{c['id']:9} {commit[:10]} {len(entries):3} files {sum(e['size'] for e in entries)/1e6:8.1f} MB  hash {digest[:12]}")
    manifest = {"schema": 1, "fluidAudio": "0.18.3", "components": comps}
    with open(path, "w") as fh:
        json.dump(manifest, fh, indent=1)
        fh.write("\n")
    print("wrote", os.path.normpath(path))


if __name__ == "__main__":
    main()
