# Scribe

A free, native macOS app (SwiftUI, Apple Silicon, macOS 14+, **macOS 15+ recommended**) that does two things,
100% on your Mac:

1. **Dictation in any app** (a free Wispr Flow / Handy-style tool): hold **Right ⌥ Option**, talk, let go —
   your words are typed where your cursor is. Or press **⌃⌥Space** to start and again to stop. **Esc** cancels.
2. **Meeting notes**: record a meeting, get a transcript with who-said-what (it learns voices), a summary, key
   points and action items with owners. Search across every meeting.

No account, no cloud, nothing uploaded. Models download once (~500 MB), then it works offline.

## Install (unsigned app)
1. Download `Scribe.zip` (or `Scribe.dmg`) from Releases. Unzip, drag **Scribe** into **Applications**.
2. First launch: right-click Scribe → **Open** → **Open**. (Or open it once, then System Settings →
   Privacy & Security → scroll down → **Open Anyway**.) Needed because the app is ad-hoc signed, not notarized.
3. The welcome screen walks you through:
   - **Microphone** → Allow.
   - **Accessibility** → click Open Settings, switch **Scribe** on. (This lets it see the hold key while you're in
     other apps and press ⌘V for you. Without it, the toggle shortcut still works and your text lands on the
     clipboard — press ⌘V yourself.)
   - **Models** download (progress bar). Leave it online for that first time.
4. Click into any text box anywhere, hold Right ⌥, talk, let go.

**Known macOS quirk:** Accessibility permission is tied to the exact app build. After installing a *new* version
(every unsigned build looks like a different app to macOS), dictation may stop pasting. Fix: System Settings →
Privacy & Security → Accessibility → select Scribe → **–**, then turn the new one on (Scribe → Settings →
Permissions → Open Settings).

## How dictation works (Dictation/ folder)
```
hold key ─▶ MicCapture (mic → 16 kHz in memory)
release  ─▶ SpeechEngine.dictate: Silero VAD cuts silence ─▶ Parakeet TDT turns speech into text
         ─▶ TextCleanup: Apple Intelligence polish (macOS 26) or simple rules (remove um/uh, stutters)
         ─▶ TextInserter: save clipboard, put text on it, fake ⌘V, put your clipboard back
```
- `HotkeyManager.swift` — hold key via `NSEvent` global monitor (needs Accessibility); toggle shortcut via Carbon
  `RegisterEventHotKey` (needs nothing). A tap shorter than 0.3 s, or using ⌥ in a shortcut (⌥←), is ignored.
- `PillOverlay.swift` — the black pill at the bottom of the screen. A *non-activating* panel, so the app you're
  typing in keeps focus.
- `DictationController.swift` — the state machine (idle → listening → transcribing → done).
- The app is **not sandboxed**: macOS doesn't let sandboxed apps post the ⌘V keystroke into other apps.
  Hardened runtime stays on.

## Meeting notes (Notes/NotesMaker.swift)
- **Apple Intelligence** (macOS 26 + Apple Intelligence on): the on-device model fills in a Swift struct
  (summary, key points, action items with owner) — "guided generation". Long meetings are cut into ~6,000-character
  chunks (the model sees ~4,000 tokens at once) and merged ("map-reduce").
- **Otherwise** quick notes, no AI: action items = sentences with "I'll / we need to / can you / by Friday…",
  owner = who said it; key points = sentences with the meeting's most frequent topic words.
- Name your speakers first, then **Redo notes** so owners get real names. Notes are a draft: check them.

## Voice learning (Engine/VoiceLibrary.swift)
Name a speaker once; next meetings label them automatically (cosine similarity of voice embeddings: ≥ 0.55
auto-label, 0.40–0.55 "maybe …?"). Every confirmed meeting adds up to 8 fingerprints per person, so it gets steadier.

## Models — and why
| | Parakeet TDT v2 (default) | Parakeet TDT v3 | Whisper large-v3-turbo |
|---|---|---|---|
| Languages | English | 25 European | 99 |
| WER, our 42-file test set (sandbox, ONNX int8, Linux CPU) | **3.25 %** | 4.96 % | 3.59 % |
| Speed, same sandbox (lower = faster) | RTF 0.057 | RTF 0.069 | RTF 0.582 (~10× slower) |
Parakeet v2 was most accurate *and* ~10× faster than Whisper-turbo in our own test, so it's the default; v3 is in
Settings → Model for other languages. Whisper isn't included (slower, and it can invent text on silence).
Full details and where each number was measured: `BENCHMARKS.md`.

## Settings (⌘,)
Hold key (Right ⌥ / Right ⌘ / Right ⌃ / fn / off), mode (hold, toggle, both), toggle shortcut recorder,
filler removal, Apple Intelligence polish, trailing space, restore clipboard, sounds, model, AI notes,
launch at login (`SMAppService`), permissions with live status, About & licenses.

## Code tour
| Folder | What |
|---|---|
| `App/ScribeApp.swift` | Entry point, window + menu bar + settings scenes, `AppModel` (shared state) |
| `Dictation/` | Hotkeys, mic capture, pill, paste, dictation state machine, settings keys |
| `Engine/SpeechEngine.swift` | Loads models; meeting pipeline (diarize + transcribe) and dictation (VAD + transcribe) |
| `Engine/TextCleanup.swift`, `AppleIntelligence.swift` | Rule cleanup + guarded Foundation Models wrapper |
| `Notes/NotesMaker.swift` | Meeting notes (AI map-reduce or extractive) |
| `Engine/VoiceLibrary.swift` | Speaker ID "brain" |
| `Storage/Store.swift` | JSON in `~/Library/Application Support/Scribe/`, search, dictation history |
| `System/Permissions.swift` | Mic + Accessibility checks and System Settings links |
| `Views/` | Main window, meeting detail (Notes/Transcript), People, Dictation history, Settings, Onboarding, About |
| `SelfTest/SelfTest.swift` | `Scribe --selftest`: dictation clip + AMI meeting, used by CI |

## Build it yourself
```
brew install xcodegen
./scripts/build.sh        # -> dist/Scribe.zip and .dmg
```
Xcode 16 builds everything except the Apple Intelligence parts (they are behind `#if canImport(FoundationModels)`
and turn into the rule-based fallback). Xcode 26 compiles them in. CI picks the newest Xcode 26 on the runner.
Put `[release]` in a commit message to publish a GitHub Release.

## Credits / licenses
Dictation design inspired by **Handy** (MIT, © 2025 CJ Pais) — full notice in the app's About screen.
FluidAudio (Apache-2.0); Parakeet TDT v2/v3 (CC-BY-4.0, NVIDIA); Silero VAD (MIT); pyannote Community-1 +
WeSpeaker Core ML conversions (CC-BY-4.0); LibriSpeech + AMI audio used only by the self-test (CC-BY-4.0).
