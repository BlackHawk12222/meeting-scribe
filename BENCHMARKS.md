# Benchmarks — what was actually measured

Rule: every number says where it was measured. **Nothing here was measured on a real Mac yet.**
Three places numbers come from:
- **Sandbox** = Hark's Linux box (aarch64, 2 vCPU, no Apple hardware, no Xcode). ONNX models on CPU.
- **Runner** = GitHub Actions `macos-15` runner: `Apple M1 (Virtual)`, 3 cores, 7 GB RAM, macOS 15.8.2,
  Xcode 26.3 / macOS 26.2 SDK. A virtual Mac with no (or limited) Neural Engine/GPU — speeds are a floor.
- **Expected on a real Mac** = FluidAudio's own published numbers (M4 Pro / M5 Pro). Not verified by us.

## H. Noisy room: voice detection, "who spoke when" and names in a crowd (Runner) — 0.6 dev, 2026-11-23/24
**GitHub Actions macOS runner numbers. Measured on a GitHub Actions `macos-15` runner: `Apple M1 (Virtual)`, 3 cores, 7 GB RAM, macOS 15.8.2,
Xcode 26.3 — a virtual Mac with no Neural Engine. Not a real Mac, and not a real noisy room:** the noise was
mixed in by software (DEMAND crowd noise, CC BY-SA 3.0, into AMI meeting audio, CC BY 4.0). Runs 45324120424 (commit 730b758), 45329926142 (commit 1002573) and, for names/enrollment, 45494655920 (commit 428513d), branch v0.6-dev,
`Scribe --selftest --suite noisy` (Sources/Scribe/SelfTest/NoisyBench.swift). The baseline numbers were identical
in both runs (the pipeline is deterministic).

**Test set.** AMI ES2004a/b/c, first 300 s each (CC BY 4.0, same 4 people, room-mix mic) + crowd noise from DEMAND
(busy cafeteria + university restaurant, 184 s, CC BY-SA 3.0, `Tests/noise/`), mixed at SNR 10, 5 and 0 dB
(SNR = how much louder the talkers are than the crowd; speech level measured only where someone talks).
AMI already has real overlapping speech: 2.7–8.7 % of the reference speech in these clips.
DER = missed speech + false alarm + speaker confusion, % of reference speech, no collar, overlap scored.

**Baseline (Scribe 0.5 as shipped: pyannote Community-1 + WeSpeaker + VBx, Fa 0.2, one speaker at a time),
mean of the 3 meetings — DER (missed / false alarm / confusion):**

| | clean | 10 dB | 5 dB | 0 dB |
|---|---|---|---|---|
| DER | **18.9 %** (11.6 / 5.1 / 2.3) | **30.5 %** (17.9 / 8.3 / 4.4) | **53.8 %** (35.4 / 6.8 / 11.6) | **70.0 %** (61.4 / 3.7 / 4.9) |
| DER without overlap frames | 16.5 % | 28.5 % | 52.1 % | 69.1 % |
| diarizer's own speech detection: missed / false alarm (of non-speech) | 8.7 / 8.3 % | 15.1 / 13.1 % | 33.2 / 10.6 % | 60.1 / 6.3 % |

What goes wrong: mostly **missed speech**. As the crowd gets louder the model decides the meeting voices are part
of the background (missed speech 12 % → 61 %). Overlap is a small part of the error (DER with and without overlap
frames differ by ~1–2 points). Per meeting it varies a lot (5 dB: 67.8 / 55.3 / 38.2 %).

**What was tried (one at a time, same mixed audio). DER %, mean of 3 meetings:**

| variant | clean | 10 dB | 5 dB | 0 dB | verdict |
|---|---|---|---|---|---|
| baseline (0.5) | 18.9 | 30.5 | 53.8 | 70.0 | |
| keep overlapping speakers (`exclusiveSegments = false`) | 18.4 | 30.7 | 54.2 | 70.0 | ≈ same; not worth it (words need one speaker anyway) |
| Silero VAD gate on the diarizer output, threshold 0.3 / 0.5 | 19.4 / 19.3 | 37.2 / 38.0 | 61.5 / 64.8 | 81.2 / 82.5 | **worse**: removes false alarms but misses much more speech |
| LocalVQE v1.2 (5.5 MB) denoiser first | 22.7 | 55.7 | 77.6 | 88.0 | **much worse** |
| LocalVQE v1.3 (19.6 MB) denoiser first | 21.8 | 61.8 | 75.4 | 88.6 | **much worse** |
| Sortformer offline fp16 (242 MB) instead of pyannote | 35.0 | 65.0 | 66.3 | 72.2 | **worse** |
| Sortformer offline palettized (92 MB) | 30.8 | 72.3 | 68.6 | 73.5 | **worse** |
| clustering Fa 0.07 / Fa 0.3 | 20.6 / 19.4 | 29.2 / 41.5 | 59.5 / 71.6 | 72.6 / 83.1 | no consistent gain |
| clustering threshold 0.5 | 18.9 | 30.5 | 52.6 | 70.1 | ≈ same (one meeting better, one worse) |
| "exactly 4 people" | 23.3 | 31.1 | 60.4 | 73.2 | worse |
| voice-library merge / re-score (library from clean ES2004a; b + c only) | 18.8 vs 18.8 | 29.8 vs 29.8 | 46.7 vs 46.7 | 63.5 vs 63.5 | DER unchanged (see names below) |

Why they hurt, simply: a speech denoiser trained for calls treats far-away meeting voices like the crowd and
turns them down too (false alarms drop to ~0 %, missed speech jumps to 47–87 %). The VAD gate does the same thing
more crudely. Sortformer is trained to *ignore* background talkers, and on this room-mix audio it ignores real
talkers too (missed 27 % even when clean). Speed on the runner (300 s): diarization 13–40 s; LocalVQE v1.2 17–29 s,
v1.3 46–74 s extra; Sortformer 9–14 s.

**Names (voice library, enrolled from the clean first meeting).** ES2004c, frames with the right name:
0.5 rule (auto-name only ≥ 0.55) 51.0 / 50.4 / 32.0 / 0.0 % at clean / 10 / 5 / 0 dB. Also naming the
"maybe …?" suggestions (0.40–0.55): 93.2 / 92.5 / 74.2 / 42.2 %, with wrong names 1.5 / 1.4 / 0.2 / 1.9 % (same as
the 0.5 rule except +1.9 at 0 dB; measured in the enrollment run below). Auto-merging split clusters (≥ 0.55 for an
already-named person) changed nothing on this data. ES2004b stays low (45.7 % clean, ~0 % in noise) because the
first 300 s of ES2004a only had 3 of the 4 people and 1 sample for two of them — see guided enrollment below.

**Dictation in a crowd** (20 LibriSpeech sentences with 1.5 s of room before/after, 386 words, Parakeet v2): WER

| VAD trimming | clean | 10 dB | 5 dB | 0 dB |
|---|---|---|---|---|
| none | 1.6 % | 2.3 % | 3.4 % | 9.1 % |
| **Silero 0.75 (0.5 default)** | **1.6 %** | **0.8 %** | **2.6 %** | **8.0 %** |
| Silero 0.5 | 1.8 % | 0.8 % | 2.8 % | 8.8 % |
| Silero 0.3 | 1.8 % | 1.6 % | 3.1 % | 8.8 % |
The shipped trimming already helps in noise (it cuts the crowd before and after you talk), and lowering the
threshold does not help. Kept at 0.75. (1 word = 0.26 % here, so small differences are noise.) On far-field meeting
audio Silero at 0.75 (dictation segmentation) missed 6 / 31 / 55 / 80 % of speech — fine for close-mic dictation,
not usable as a meeting VAD.

**Guided enrollment ("Add person") and the naming rule — run 45494655920, commit 428513d, 2026-11-24.**
Same runner type (GitHub `macos-15`, virtual M1, 3 cores, no Neural Engine), same software-mixed noise (DEMAND
CC BY-SA 3.0 crowd into AMI CC BY 4.0 room-mix audio). `--suite noisy --variants enroll`
(Sources/Scribe/SelfTest/EnrollBench.swift).

How it was simulated (we can't record people reading prompts on a CI runner): the "enrollment" clips are real
speech of the same 4 people from a DIFFERENT meeting, the whole clean ES2004a (17.5 min). For each person, 6
stretches of 2.5–8 s where only they are heard (other people's words cut out), picked from quietest to loudest
as a stand-in for the 6 speaking styles. Tested on ES2004b and ES2004c (first 300 s, clean and crowd at 10/5/0 dB).
- **today** = what 0.5 does: library learned from the diarizer's clusters in the clean first 300 s of ES2004a
  (only 3 of the 4 people talk there; one has 8 samples, two have 1).
- **single clip** = one ~5 s clip per person → 1 voice sample.
- **one 30 s clip** = the same 6 clips glued → 1 voice sample (27–38 s).
- **multi-style (6 prompts)** = the 6 clips → 6 voice samples (what the app's "Add person" saves).

Scored on every 10 ms where exactly one person talks: **right** = labelled with that person's name,
**wrong** = labelled with someone else's name, the rest has no name (unknown speaker or speech the diarizer
missed). **Strict** = the 0.5 rule (name only if the match is ≥ 0.55). **Loose** = also name the 0.40–0.55
"maybe …?" match. DER is after merging clusters that got the same name. Mean of ES2004b + ES2004c.

| library, rule | clean: right / wrong | 10 dB | 5 dB | 0 dB |
|---|---|---|---|---|
| today, strict (0.5) | 48.3 / 0.9 % | 25.2 / 0.7 % | 16.0 / 0.1 % | 0.0 / 0.0 % |
| today, loose | 69.4 / 0.9 % | 47.3 / 0.7 % | 38.1 / 0.1 % | 21.1 / 1.0 % |
| single 5 s clip, strict | 89.6 / 1.0 % | 66.9 / 0.8 % | 57.8 / 0.3 % | 0.0 / 0.0 % |
| one 30 s clip, strict | 89.6 / 1.0 % | 67.9 / 0.9 % | 57.8 / 0.3 % | 17.4 / 0.2 % |
| multi-style (6 prompts), strict | 89.6 / 1.0 % | 67.9 / 0.9 % | 57.8 / 0.3 % | 0.0 / 0.0 % |
| any enrollment, loose | 89.6 / 1.0 % | 67.9 / 0.9 % | 58.8 / 0.4 % | 38.5 / 1.2 % |
| DER (every row; names don't change it here) | 18.8 % | 29.8 % | 46.7 % | 63.5 % |

Per meeting (right names, multi-style, loose): ES2004b 86.0 / 43.2 / 43.4 / 34.8 %, ES2004c 93.2 / 92.5 / 74.2 /
42.2 %. On ES2004c every library tops out at the same 93.2 % (the rest is speech the diarizer missed, or overlap).
Single turns (every stretch ≥ 1.5 s with one talker, 41 turns, closed set of 4): best-match accuracy today 82 /
74 / 69 / 47 %, multi-style 98 / 85 / 62 / 48 %; a WRONG name above 0.40 happened 0 times in any row.

What this means, simply:
- **Enrolling helps a lot.** Knowing everyone's voice from a different meeting roughly doubles the speech with
  the right name (48 → 90 % clean, 25 → 68 % at 10 dB, 16 → 58 % at 5 dB), and wrong names stay about 1 %.
  That 1 % is not a mix-up of people: it is a few words of one person landing inside another person's speaker
  turn (a diarizer error), and it is the same with or without names.
- **Six styles vs one clip: no measurable difference here.** All three enrollment kinds name the same clusters.
  The 6 clips only differ in loudness (meeting speech, not real "loud"/"question"/"quiet" reading), so this test
  can't show what real style variety does. At 0 dB, 6 separate samples score a bit lower than one glued 30 s
  sample (0.51 vs 0.56 for the same cluster), because the score averages the 5 closest samples.
- **The loose rule helps and costs almost nothing.** It adds 21–22 points of right names in every noise level
  for the meeting-learned library and 21–38 points at 0 dB for enrolled people; wrong names: +0 points clean, 10 and
  5 dB, +1 point at 0 dB. The one person missing from the "today" library was not given someone else's name (wrong names ≤ 0.2 % in
  the meeting where they talk).
- **Names never changed DER** on this data (no two clusters were given the same person).
- **Quality gate** (on the bundled 15.7 s close-mic dictation clip): clean clip accepted (speech −22.8 dBFS,
  43 dB above the room); crowd at 10 / 5 / 0 dB rejected as too noisy (12.0 / 7.9 / 5.2 dB above the room, gate 15
  dB); clipped copy rejected (0.67 % of samples at full scale); 2 s cut rejected (0.3 s of speech). An AMI room-mix
  turn is rejected as too quiet (−44.5 dBFS): far-away meeting audio is not what enrollment expects.

**Decision (v0.6-dev):** the loose rule is the default now (`VoiceMatcher.nameLikelyMatches = true`: a speaker's
best match ≥ 0.40 gets the name, one person per speaker, strongest pairs first; a split cluster's second match
stays a "maybe …?" suggestion because that case never happened in this test). Guided enrollment stays on (the
Add person button on the People page in v0.6) and keeps 6 prompts: 6 clips cost nothing over one 30 s clip here.

Limits: 2 test meetings × 300 s, the same 4 people (3–4 talk in each), no stranger who is completely unknown
to every library except the one person missing from "today"; noise mixed by software; a virtual Mac. Real
enrollment (someone reading the prompts on a real Mac mic, then a real noisy meeting) is still untested.

## G. Scribe 0.5 self-test (Runner) — GitHub Actions run 45111200196, commit dc5a21a, 2026-11-23
**Measured on a GitHub Actions `macos-15` runner: `Apple M1 (Virtual)`, 3 cores, 7 GB RAM, macOS 15.8.2,
Xcode 26.3. A virtual Mac with no Neural Engine — not a real Mac.** Parakeet pads every call to a 15 s window and
runs on CPU there, so a real Apple Silicon Mac should be much faster. Nothing below was measured on a real Mac.

**Accuracy — 40 LibriSpeech test-clean clips (287.8 s, 753 words), corpus WER, simple normalizer:**

| model | WER | key release → text, mean / median | RTF |
|---|---|---|---|
| Fast · Parakeet v2 (default) | **1.59 %** | 1496 / 1437 ms | 0.208 |
| Parakeet v2 + vocabulary acoustic helper (CTC 110M) | 1.99 % | 2492 / 2407 ms | 0.346 |
| Accurate · Parakeet Ultra | 1.73 % | 1866 / 1612 ms | 0.259 |

- **"Accurate" (Parakeet Ultra) stays hidden**: on the runner it was both less accurate (1.73 % vs 1.59 %) and slower
  (1866 vs 1496 ms mean) than v2 on LibriSpeech. (On the single 15.7 s dictation clip both had 2.9 % WER; Ultra took
  1978 ms vs v2 2844 ms in that one comparison.)
- **Vocabulary acoustic helper is now OFF by default**: on real speech it inserted "CAD" into ordinary sentences
  ("I will practise it" → "I will CAD it") and added ~1 s. The text pass alone (default) fixed every term in the
  vocabulary test.

**Dictation clip** (`dictation_sample.wav`, 15.67 s, 34 words): WER 2.9 % (1 error) on all 3 runs; total 2.28 / 1.85 /
2.11 s (RTF 0.146 / 0.118 / 0.135).

**Latency** (key release → final text, excl. 150 ms post-roll and the paste): 2 s clip cold 3332 ms, warm 2828 / 1733 /
1875 ms; 5 s warm 2057 / 2567 / 1631 ms; 15 s warm 1681 / 1594 / 1677 ms.

**Pause test** (LibriSpeech sentence with a 2.5 s pause inserted at 5.1 s, 15.2 s clip): PASS. With "I pause while
thinking" on: one sentence, 0 sentence breaks inside, 0 stray mid-sentence capitals, WER 0 %, release → text 4888 ms.
For comparison the 0.4-style stitch of the same halves produced "…was not contemptible. a more exact plan…".

**Back-to-back paste logic**: PASS — after two quick dictations the clipboard held sentence 2 (WER 5 % vs sentence 2),
not sentence 1. **Paste-logic checks**: 20 / 21 passed (focus classification, ⌘V events, overlay never key/main,
target never Scribe, chunk joining, stray capitals, numbers, vocabulary). The one failure is **"typing into
TextEdit"**: on the runner Scribe pressed ⌘V into TextEdit but the text did not land. Not yet known whether that is a
runner limitation or a real bug — needs a check on a real Mac.

**Vocabulary** (3 sentences spoken by macOS `say`, a synthetic voice — not a person; 11 terms): raw model 8 / 11,
after the text pass 11 / 11, with the acoustic helper 11 / 11. Cleanup + vocabulary on ~200 words: 4.6 ms.

**Meetings** (AMI ES2004 a/b/c, 300 s each): transcription 42.9 / 50.7 / 38.9 s (5.9–7.7× real time); speaker DER
19.2 % / 20.1 % / 17.5 % (auto setting).

**Setup** (runner): dictation models 465.5 MB downloaded in 12.2 s (38 MB/s, data-center network); dictation model
load 8.7 s.

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
