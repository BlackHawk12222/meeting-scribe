# Benchmarks — what was actually measured

Rule: every number says where it was measured. **Nothing here was measured on a real Mac yet.**
Three places numbers come from:
- **Sandbox** = Hark's Linux box (aarch64, 2 vCPU, no Apple hardware, no Xcode). ONNX models on CPU.
- **Runner** = GitHub Actions `macos-15` runner: `Apple M1 (Virtual)`, 3 cores, 7 GB RAM, macOS 15.8.2,
  Xcode 26.3 / macOS 26.2 SDK. A virtual Mac with no (or limited) Neural Engine/GPU — speeds are a floor.
- **Expected on a real Mac** = FluidAudio's own published numbers (M4 Pro / M5 Pro). Not verified by us.

## D. Dictation (Scribe 0.2, `Scribe --selftest`, Runner)
Clip: `Resources/SelfTest/dictation_sample.wav` — two LibriSpeech test-clean sentences (CC-BY 4.0) with 1.5 s / 2 s /
1.5 s of faint hiss around them, 15.67 s total, 34 reference words. Runs the exact hotkey pipeline
(`Dictation.run`: Silero VAD trim → Parakeet TDT v2 → cleanup), minus the mic and the paste.

| | run 1 (cold) | run 2 | run 3 |
|---|---|---|---|
| Total time (VAD + ASR + cleanup), CI run 2 (commit 2810c16) | 2.78 s | 1.88 s | 1.52 s |
| Real-time factor (lower = faster) | 0.177 | 0.120 | 0.097 |
| Total time, CI run 1 (commit 90c8cb4) | 2.43 s | 1.70 s | 1.62 s |
- VAD: 15.67 s → 11.24 s of speech kept; VAD itself took 0.02–0.03 s.
- Same clip without the VAD trim (meeting path): 1.50 s (run 1) / 1.86 s (run 2). So on this virtual Mac the trim did
  **not** make a measurable speed difference on a 16 s clip (it's within run-to-run noise). Its job is mainly to keep
  silence/hiss out of the model.
- Accuracy: WER **2.9 %** (1 error in 34 words: "I had not" → "I have not"), identical with and without VAD.
  Punctuation and capitals come from Parakeet itself.
- Rule cleanup (no AI), exact outputs:
  - "Um, so I I I think, uh, we should meet on Tuesday." → "So I think we should meet on Tuesday."
  - "uh i need the robot by friday um." → "I need the robot by friday."
  - "Hmm, okay, so, uh, the the motor is, um, overheating." → "Okay, so the the motor is overheating."
    (a doubled word is kept on purpose: "that that" can be correct English)
- Apple Intelligence on the runner: **not available** ("Needs macOS 26") — the runner runs macOS 15. The Foundation
  Models code **compiles** (Xcode 26.3 SDK) but its output has **never been run or judged**.
- What you'd feel on a real Mac: "time after you let go" = 0.15 s tail + this pipeline + ~0.4 s paste/restore.
  On the runner that is ~2 s for 16 s of speech. FluidAudio reports Parakeet at ~145–155× real time on an M4 Pro
  (LibriSpeech), which would make the transcription step ~0.1 s — **expected, not measured**.

## E. Choosing the speech model (Sandbox, 42 files ≈ 18 min: 2 TED-LIUM talks + 40 LibriSpeech test-clean)
ONNX int8 on CPU, word error rate after Whisper's English normalizer (`work/score.py`).

| model | WER TED | WER Libri | WER all | RTF (lower = faster) | peak RAM |
|---|---|---|---|---|---|
| **Parakeet TDT 0.6B v2** (app default) | 3.67 % | 1.72 % | **3.25 %** | **0.057** | 1.9 GB |
| Parakeet TDT 0.6B v3 (Settings option, 25 languages) | 5.68 % | 2.38 % | 4.96 % | 0.069 | 2.0 GB |
| Whisper large-v3-turbo (faster-whisper) | 4.19 % | 1.46 % | 3.59 % | 0.582 | 1.9 GB |
| Whisper small.en (faster-whisper) | 3.19 % | 1.99 % | 2.93 % | 0.296 | 1.1 GB |
Decision: Parakeet v2. Whisper small.en scored a bit better (2.93 % vs 3.25 %, a gap within noise on 18 minutes of
audio), but Parakeet was ~5× faster than small.en and ~10× faster than large-v3-turbo, and it runs on the Neural Engine
through FluidAudio. Whisper is not shipped: slower, and it can hallucinate text on
silence. FluidAudio's own (M4 Pro) LibriSpeech numbers agree on the ranking: v2 2.1% vs v3 2.5% WER.

## F. Meeting notes (Runner)
300 s of AMI ES2004a (copy in `Tests/`, CC-BY 4.0). Transcribe + diarize: 71.8 s (≈4.2× real time).
No-AI quick notes: 0.007 s. Apple Intelligence notes: **not run** (runner is macOS 15).
Honest quality note: the quick notes are a rough draft — on this clip 6 "action items" were found, of which
roughly 2 are real tasks (it flags phrases like "I'll go first"). Exact output is in the self-test JSON.

## Test data
AMI Meeting Corpus ES2004a / ES2004b / ES2004c (CC-BY 4.0): three meetings with the **same four people**
(FEE013, FEE016, MEE014, MEO015), room-mix microphone ("Mix-Headset"), British/European English, real
overlap and laughter. Reference "who spoke when" from pyannote/AMI-diarization-setup (only_words).
"Naming" a speaker is simulated with those reference labels (as if the user clicked the right name every time).

**ID-accuracy** = share of 10 ms frames where exactly one reference person talks that carry that person's name
(unknown/unlabeled counts as wrong). **Ceiling** = same metric if every cluster were named perfectly
(limited by the diarizer). **DER** = diarization error rate, no collar, overlap scored.

## A. GitHub Actions macOS runner — the real app binary (MeetingScribe --selftest)
Machine: `Apple M1 (Virtual)`, 3 CPU cores, 7 GB RAM, macOS 15.8.2, macos-15-arm64 image.
A virtual Mac: no (or limited) Neural Engine/GPU parity with a real Mac, so speeds are a floor, not a forecast.
Models: FluidAudio 0.18.3 — Parakeet TDT 0.6B v2 (Core ML), Community-1 diarizer (Core ML), WeSpeaker embeddings.
First 300 s of each meeting. Run 3 (settings comparison, commit b7cbdbf):

| setting | ES2004a clusters / DER | ES2004b clusters / DER | ES2004c clusters / DER |
|---|---|---|---|
| FluidAudio default (Fa 0.07) | 1 / 0.239 | 2 / 0.204 | 2 / 0.175 |
| **Fa 0.2 (now the app's Auto)** | 4 / 0.192 | 5 / 0.201 | 2 / 0.175 |
| Fb 0.4 | 3 / 0.192 | 2 / 0.204 | 2 / 0.175 |
| threshold 0.4 or 0.8 | 1 / 0.239 | 2 / 0.204 | 2 / 0.175 |
| exactly 4 speakers | 4 / 0.305 | 4 / 0.211 | 4 / 0.296 |
(Reference speakers in each 300 s clip: 3, 4, 4.)

Voice library, Fa 0.2:
| test | ID-accuracy | ceiling | clusters auto-named (correct) |
|---|---|---|---|
| ES2004b, library from A | 0.457 | 0.862 | 2 (2) — 2 voices weren't in the library yet |
| ES2004c, library from A only | 0.510 | 0.932 | 1 (1) — FEE016 scored 0.51 → only "maybe FEE016?" |
| ES2004c, library from A + B | **0.932** | 0.932 | 2 (2) — FEE016 now 0.66 → auto-labeled |
That last pair is the "it learns" effect: FEE016 had 1 voice sample after meeting A and 4 after meeting B.

Similarity scores seen (Core ML embeddings, Fa 0.2 runs): same person 0.59–0.86; different person ≤ 0.35.
App thresholds: auto-label ≥ 0.55, suggest 0.40–0.55.

Speed on this virtual M1 (CPU-bound): diarization 5.8–9.0× real time; Parakeet transcription 5.1–7.4× real time
(300 s of audio in 41–59 s); model load from cache ~9–12 s; first-time model download + compile ~41 s.
FluidAudio's own docs claim ~120–190× real time for Parakeet on M4 Pro with the Neural Engine — **not measured here**.

## B. Hark sandbox (Linux, 2 vCPU, ONNX) — algorithm prototype
sherpa-onnx with pyannote segmentation-3.0 + WeSpeaker ResNet34-LM (ONNX), first 600 s per meeting.
Different runtime and clustering from the app, same voice-library logic.
- Diarization (threshold 1.0): DER 0.372 / 0.141 / 0.195, RTF 0.27–0.34 (3–3.7× real time).
- Library from A → B: ID-accuracy 0.917 (ceiling 0.927). From A → C: 0.920 (ceiling 0.920).
- Samples per person vs accuracy (51 clean turns of ES2004c, 20 random draws, closed set):
  1 → 0.854 (worst 0.686), 2 → 0.876, 4 → 0.892, 8 → 0.919 (worst 0.902), 16 → 0.922.
- Unknown speaker (each person removed from the library): 0 of 4 wrongly auto-named at thresholds 0.40–0.60.

## Not tested yet
- Live microphone recording and Apple voice processing (needs a real Mac with a mic).
- Speed on a real Apple Silicon Mac (Neural Engine / GPU).
- Real users' voices, a noisy room, cross-talk.
- Word error rate on meeting audio (Parakeet v2 was measured earlier at 3.25% WER on TED-LIUM, sandbox ONNX).
- macOS 14: FluidAudio documents a macOS 14 Core ML/BNNS crash in the diarizer; macOS 15+ is recommended.
