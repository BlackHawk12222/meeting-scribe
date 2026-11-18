# Meeting Scribe

A native macOS app (SwiftUI, Apple Silicon, macOS 14+, **macOS 15+ recommended**) that records
team meetings, transcribes them offline, and learns who is talking by their voice.

- One-click recording from the Mac mic, with Apple's voice processing for noise cleanup
- Offline speech-to-text: NVIDIA Parakeet TDT 0.6B v2 (English) via FluidAudio / Core ML
- "Who spoke when" (diarization): pyannote Community-1 + WeSpeaker embeddings + VBx via FluidAudio
- A voice library: name a speaker once, and the app recognizes them in later meetings, getting steadier
  every time you confirm someone
- "People talking" control to fix merged/split speakers without re-transcribing
- Export .txt, .srt (subtitles) and Markdown notes
- 100% on-device after a one-time ~600 MB model download. Nothing is uploaded.

## Install (unsigned app)
1. Download `MeetingScribe.dmg` from Releases, open it, drag **MeetingScribe** onto **Applications**.
2. First launch: right-click the app → **Open** → **Open**. (Or try to open it once, then
   System Settings → Privacy & Security → scroll down → **Open Anyway**.) This is needed because the app is
   ad-hoc signed, not notarized by Apple.
3. Leave it open with internet for the first launch while it downloads the models (yellow bar at the top).
4. Press **Record** (⌘R). macOS asks for the microphone the first time: click **Allow**.
   If you clicked Don't Allow: System Settings → Privacy & Security → Microphone → turn on Meeting Scribe.

## How to use
1. Record → Stop. The meeting is processed automatically (transcript + speakers).
2. Click a speaker chip ("Speaker 2") → **Play a sample** to hear them → pick a name or **New person…**.
3. Next meeting, people you've named get labeled automatically. A ✓ means you confirmed it; "maybe Taylor?" means
   the app isn't sure — click it and choose "Yes, this is Taylor" to teach it.
4. If two people got merged into one speaker, set **People talking** to the right number.
5. Export → .txt / .srt / .md.

## How the voice learning works
The speaker model turns a few seconds of someone talking into a list of 256 numbers (an *embedding*) — a voice
fingerprint. Clips of the same person point in almost the same direction; different people point in different
directions. The app measures that with *cosine similarity* (1.0 = identical direction).

When you name a speaker, the app saves fingerprints from that person's 8 longest turns in the meeting.
Next time, each new speaker is compared to everyone in the library (average of the 5 closest fingerprints).
Score ≥ 0.55 → auto-label. 0.40–0.55 → "maybe …?". Each person can only be auto-assigned once per meeting.
The model itself never changes; what improves is the library — more fingerprints from more meetings
(different moods, mic distances, noise) means fewer bad-luck misses. See `Engine/VoiceLibrary.swift`.

## Code tour
| File | What it does |
|---|---|
| `App/MeetingScribeApp.swift` | Entry point; `--selftest` runs the headless test instead of the window |
| `Audio/Recorder.swift` | AVAudioEngine mic capture, voice processing, 16 kHz WAV writing, level meter |
| `Engine/SpeechEngine.swift` | Loads models, diarizes, transcribes, glues words to speakers |
| `Engine/VoiceLibrary.swift` | Cosine similarity, matching, learning (the "brain" of speaker ID) |
| `Storage/Store.swift` | Saves meetings + voices as JSON in the app's Application Support folder |
| `Views/*` | SwiftUI screens (sidebar, meeting, people) |
| `Export/Exporter.swift` | .txt / .srt / .md |
| `SelfTest/SelfTest.swift` | Benchmark on public AMI meetings, used by CI |

## Build it yourself
```
brew install xcodegen
./scripts/build.sh        # -> dist/MeetingScribe.dmg and .zip
```
Or `xcodegen generate` and open `MeetingScribe.xcodeproj` in Xcode 16+.
CI: `.github/workflows/build.yml` builds on a GitHub macOS 15 runner, runs the self-test, uploads the app.
Put `[release]` in a commit message to publish a Release.

## Measured numbers
See `BENCHMARKS.md` (what was measured, on which machine). Nothing in this README is a promise about your Mac.

## Credits / licenses
FluidAudio (Apache-2.0); Parakeet TDT v2 (CC-BY-4.0, NVIDIA); pyannote Community-1 Core ML conversion (CC-BY-4.0);
AMI Meeting Corpus used only by the self-test (CC-BY-4.0).
