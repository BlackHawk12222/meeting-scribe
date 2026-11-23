# Scribe

A free, native macOS app (SwiftUI, Apple Silicon, macOS 14+, **macOS 15+ recommended**) that does two things,
100% on your Mac:

1. **Dictation in any app** (a free Wispr Flow / Handy-style tool): hold **Right ⌥ Option**, talk, let go —
   your words are typed where your cursor is. Or press **⌃⌥Space** to start and again to stop. **Esc** cancels.
2. **Meeting notes**: record a meeting, get a transcript with who-said-what (it learns voices), a summary, key
   points and action items with owners. Search across every meeting.

No account, no cloud, nothing uploaded. Models download once (~490 MB), then it works offline.

**v0.4 look:** plain macOS. System fonts and colors (light and dark), standard materials, SF Symbols and one
quiet indigo accent. The icon is a single fountain-pen nib. While you talk, a small capsule shows level bars and a
timer; you choose where it sits (Settings › Dictation › Overlay) or drag it anywhere.

## Install (unsigned app)
1. Download `Scribe.zip` (or `Scribe.dmg`) from Releases. Unzip, drag **Scribe** into **Applications**.
2. First launch: double-click Scribe (macOS says it can't check it), then System Settings → Privacy & Security →
   scroll down → **Open Anyway** → Open. (On macOS 15+ the old right-click → Open trick no longer works.) Needed
   because the app is ad-hoc signed, not notarized. Updates installed from inside Scribe don't need this again.
3. The welcome window opens with a glowing ring around its edge. **The models start downloading right away**
   (dictation first, then the speaker models) and the ring fills as they come in; the bottom line shows the
   model, MB, speed and time left. While it downloads you flip through cards (← →, swipe, or the arrows):
   - **Microphone** → Allow.
   - **Accessibility** → click Open Settings, switch **Scribe** on. (This lets it see the hold key while you're in
     other apps and press ⌘V for you. Without it, the toggle shortcut still works and your text lands on the
     clipboard — press ⌘V yourself.)
   - **Your talk key**, a **Try it** box, what Scribe can do, and a mini-game (**Quill Dash**: Space to jump).
   Setup and download don't wait for each other. When everything's in, press **Start using Scribe**.
4. Click into any text box anywhere, hold Right ⌥, talk, let go.

**Known macOS quirk:** Accessibility permission is tied to the exact app build. After installing a *new* version
(every unsigned build looks like a different app to macOS), dictation may stop pasting. Fix: System Settings →
Privacy & Security → Accessibility → select Scribe → **–**, then turn the new one on (Scribe → Settings →
Permissions → Open Settings).

## How dictation works (Dictation/ folder)
```
hold key ─▶ MicCapture (mic → 16 kHz in memory) ──▶ every 256 ms slice also goes through Silero VAD *live*
release  ─▶ SpeechEngine.dictate: only the last slice is left for VAD ─▶ Parakeet TDT turns speech into text
         ─▶ TextCleanup: Apple Intelligence polish (macOS 26) or simple rules (remove um/uh, stutters)
         ─▶ TextInserter: save clipboard, put text on it, fake ⌘V, put your clipboard back
```
- `HotkeyManager.swift` — hold key via `NSEvent` global monitor (needs Accessibility); toggle shortcut via Carbon
  `RegisterEventHotKey` (needs nothing). A tap shorter than 0.3 s, or using ⌥ in a shortcut (⌥←), is ignored.
- `RecordingOverlay.swift` — the ~140 × 32 pt capsule (dark HUD): mic-level bars + timer while listening, a
  spinner while transcribing, a red dot for meetings. Six positions (bottom center by default) on the screen with
  the active window, inside the visible frame (clear of menu bar and Dock); drag it and it remembers the spot per
  display. A *non-activating* panel, so the app you're typing in keeps focus.
- `DictationController.swift` — the state machine (idle → listening → transcribing → done).

**Why it's faster in 0.3 ("the voice detector takes too long"):**
- Parakeet + Silero are loaded **once** at launch and **prewarmed** (run once on silence) so Core ML finishes its
  one-time setup before your first dictation, then stay in memory.
- The voice detector runs **while you talk** (streaming, same results as before), so at key release the trim is done.
- Clips under 3 s skip the voice detector.
- Meetings: processing runs in the background with a live status line ("Finding speakers 40%…"), and the speaker
  models are downloaded and loaded at launch instead of on the first meeting. (Running speaker detection and
  transcription at the same time was tried and was slower on the CI Mac, so they still run one after the other.)
- Timing logs for every stage: `log stream --predicate 'subsystem == "com.blackhawk12222.Scribe"' --level info`
  (or Console.app; signposts in Instruments → Points of Interest).
- The app is **not sandboxed**: macOS doesn't let sandboxed apps post the ⌘V keystroke into other apps.
  Hardened runtime stays on.

## Meeting notes (Notes/NotesMaker.swift)
- **Apple Intelligence** (macOS 26 + Apple Intelligence on): the on-device model fills in a Swift struct
  (summary, key points, action items with owner) — "guided generation". Long meetings are cut into ~6,000-character
  chunks (the model sees ~4,000 tokens at once) and merged ("map-reduce").
- **Otherwise** quick notes, no AI: action items = sentences with "I'll / we need to / can you / by Friday…",
  owner = who said it; key points = sentences with the meeting's most frequent topic words.
- Name your speakers first, then **Redo notes** so owners get real names. Notes are a draft: check them.

## Models: downloaded once, never again (Engine/ModelStore.swift, ModelDownloader.swift)
Think of it like an app store for the app's own parts:
- **Components.** Each model is a separate *component* (speech model v2, v3, voice detector, speaker models).
  `Resources/ModelManifest.json` lists every file of every component with its **size and hash**, pinned to an exact
  Hugging Face commit. `scripts/make_model_manifest.py` writes it (run it again only when FluidAudio is bumped).
- **Not in the app.** Models live in `~/Library/Application Support/FluidAudio/Models/`. Updating, reinstalling or
  deleting the app doesn't touch them.
- **Receipt.** After a component installs, Scribe saves its hash and each file's hash in
  `~/Library/Application Support/Scribe/models-installed.json`.
- **Every launch:** manifest ↔ receipt ↔ disk (each file exists with the exact size). Present and current → nothing
  downloads. A new manifest where one file's hash changed → only that file downloads. Models from an older Scribe
  are adopted (sizes match) instead of downloaded again.
- **Fast download:** the big file (the 445 MB speech encoder) is cut into 8 MB pieces and **8 download at once**
  (HTTP Range requests); small files go in parallel too. Each finished piece is noted on disk, so a dropped
  connection or quitting **resumes** where it stopped; pieces retry 5× with growing pauses. Every new file is
  checked against its SHA-256 before it's used. FluidAudio then finds the files and only *loads* them.
- **Dictation first:** Parakeet + VAD download first (dictation works as soon as they're in), then the 22 MB
  speaker models right after.
- **Settings → Model** shows each component: Downloaded / Update available / Missing, with **Verify** (re-hash every
  byte; damaged files are deleted and re-fetched alone).

## Updates (System/Updater.swift)
Updates come from this repo's own releases (the repo is public): the app reads
`https://api.github.com/repos/BlackHawk12222/meeting-scribe/releases/latest`, set as `ScribeReleasesURL` in
`project.yml`.

**Settings → General → “Update automatically”** (on by default): Scribe checks when it opens and every 6 hours,
downloads **only `Scribe.zip`** (~15 MB, never the models) in the background, checks its **SHA-256**
(`Scribe.zip.sha256` in the release), its code signature and its version, then shows a small **“Update ready —
Restart”** row in the menu bar panel. It installs when you press Restart or the next time Scribe quits. It never
restarts by itself, and the Restart button is disabled while a meeting records or you dictate. Each release also
carries `components.json` (the model manifest); models download again only if a hash in it changed.

**Publishing:** every `[release]` build creates the release here (zip, dmg, `Scribe.zip.sha256`, `SHA256SUMS.txt`,
`components.json`). No extra token or mirror repo is needed.

## Signing (keeps Accessibility across updates)
Builds are **ad-hoc signed** by default. macOS then identifies Scribe by the exact build, so after every update the
Accessibility switch can look on while macOS no longer trusts it → remove Scribe (–) and add it again (+). With a
**stable self-signed certificate**, every build has the same identity and macOS keeps the permission.

Make the certificate once, on your Mac:
1. Open **Keychain Access** → menu **Keychain Access › Certificate Assistant › Create a Certificate…**
2. Name: `Scribe Signing` · Identity Type: **Self Signed Root** · Certificate Type: **Code Signing** → Create.
3. In Keychain Access (login keychain, *My Certificates*), right-click **Scribe Signing** → **Export “Scribe Signing”…**
   → format **Personal Information Exchange (.p12)** → save as `scribe-signing.p12` and choose a password.
4. In Terminal: `base64 -i ~/Desktop/scribe-signing.p12 | pbcopy` (copies it).
5. At https://github.com/BlackHawk12222/meeting-scribe/settings/secrets/actions add two secrets:
   **`SIGNING_CERT_P12`** = paste · **`SIGNING_CERT_PASSWORD`** = the password from step 3.

The next build signs with it (the CI log says “SIGNED with the stable self-signed certificate”); if anything fails it
falls back to ad-hoc. The first update to a certificate-signed build changes the identity one last time (remove + re-add
Scribe in Accessibility once); after that the permission sticks. It is still not notarized (that needs a paid Apple
Developer account), so the very first open still needs *Open Anyway*.

## Voice learning (Engine/VoiceLibrary.swift)
Name a speaker once; next meetings label them automatically (cosine similarity of voice embeddings: ≥ 0.55
auto-label, 0.40–0.55 "maybe …?"). Every confirmed meeting adds up to 8 fingerprints per person, so it gets steadier.

## Models — and why
| | Parakeet TDT v2 (default) | Parakeet TDT v3 | Whisper large-v3-turbo |
|---|---|---|---|
| Languages | English | 25 European | 99 |
| WER, our 42-file test set (sandbox, ONNX int8, Linux CPU) | **3.25 %** | 4.96 % | 3.59 % |
| Speed, same sandbox (lower = faster) | RTF 0.057 | RTF 0.069 | RTF 0.582 (~10× slower) |
In our own test Parakeet v2 beat Whisper-turbo on accuracy and was ~10× faster; Whisper small.en was slightly more
accurate (2.93 %) but ~5× slower. So v2 is the default; v3 is in Settings → Model for other languages. Whisper isn't included (slower, and it can invent text on silence).
Full details and where each number was measured: `BENCHMARKS.md`.

## Settings (⌘,)
Hold key (Right ⌥ / Right ⌘ / Right ⌃ / fn / off), mode (hold, toggle, both), toggle shortcut recorder,
filler removal, Apple Intelligence polish, trailing space, restore clipboard, sounds, model, AI notes,
launch at login (`SMAppService`), permissions with live status, About & licenses.

## Code tour
| Folder | What |
|---|---|
| `App/ScribeApp.swift` | Entry point, window + menu bar + settings scenes, `AppModel` (shared state) |
| `Dictation/` | Hotkeys, mic capture, recording overlay, paste, dictation state machine, settings keys |
| `Engine/ModelStore.swift`, `ModelDownloader.swift` | Model manifest check + parallel resumable downloads |
| `System/Updater.swift` | Check for Updates (app zip only; model changes from components.json) |
| `Views/Theme.swift` | Accent + spacing, the nib shape, app icon view, menu bar glyph |
| `Views/RunnerGame.swift` | Quill Dash, the first-run mini-game |
| `Engine/SpeechEngine.swift` | Loads models; meeting pipeline (diarize + transcribe) and dictation (VAD + transcribe) |
| `Engine/TextCleanup.swift`, `AppleIntelligence.swift` | Rule cleanup + guarded Foundation Models wrapper |
| `Notes/NotesMaker.swift` | Meeting notes (AI map-reduce or extractive) |
| `Engine/VoiceLibrary.swift` | Speaker ID "brain" |
| `Storage/Store.swift` | JSON in `~/Library/Application Support/Scribe/`, search, dictation history |
| `System/Permissions.swift` | Mic + Accessibility checks and System Settings links |
| `Views/` | Main window, meeting detail (Notes/Transcript), People, Dictation history, Settings, first-run window, About |
| `SelfTest/SelfTest.swift` | `Scribe --selftest`: dictation clip + AMI meeting, used by CI |

## Build it yourself
```
brew install xcodegen
./scripts/build.sh        # -> dist/Scribe.zip and .dmg
```
Xcode 16 builds everything except the Apple Intelligence parts (they are behind `#if canImport(FoundationModels)`
and turn into the rule-based fallback). Xcode 26 compiles them in. CI picks the newest Xcode 26 on the runner.
Put `[release]` in a commit message to publish a GitHub Release (tag `v0.3.<build>`, assets Scribe.zip, Scribe.dmg,
components.json). The **ui-screenshots** workflow (Actions tab, manual) runs `Scribe --snapshot` and uploads PNGs of
every screen, the recording overlay and the icons.

## Credits / licenses
Dictation design inspired by **Handy** (MIT, © 2025 CJ Pais) — full notice in the app's About screen.
FluidAudio (Apache-2.0); Parakeet TDT v2/v3 (CC-BY-4.0, NVIDIA); Silero VAD (MIT); pyannote Community-1 +
WeSpeaker Core ML conversions (CC-BY-4.0); LibriSpeech + AMI audio used only by the self-test (CC-BY-4.0).
