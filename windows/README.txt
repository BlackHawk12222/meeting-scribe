Scribe for Windows (preview)
============================

Hold a key, talk, let go: your words are typed where your cursor is.
Speech recognition runs on this PC. No audio leaves it.

First run
  1. Unzip this folder anywhere (for example Documents\Scribe). Keep all files together.
  2. Double-click Scribe.exe.
     Windows may say "Windows protected your PC" because this preview is not signed yet.
     Click "More info", then "Run anyway".
  3. Scribe downloads its speech model once (about 480 MB, about 650 MB unpacked) into
     %LOCALAPPDATA%\Scribe\models. A window shows the progress.
  4. When the black capsule says "Ready", click into any text box (Notepad, a browser,
     Word...), hold Right Alt, speak, and let go. "Thinking..." then the text appears.

Tray icon (bottom-right, maybe under the ^ arrow)
  Settings...   choose the dictation key, clipboard and spacing options
  About Scribe  version and credits
  Open log      %LOCALAPPDATA%\Scribe\scribe.log, useful if something goes wrong
  Quit

Good to know
  - If Windows asks to let Scribe use the microphone, allow it. If nothing is heard, check
    Settings > Privacy & security > Microphone > "Let desktop apps access your microphone".
  - Scribe pastes with Ctrl+V and then puts your previous clipboard back.
  - Text will not paste into apps running as administrator unless Scribe is too.
  - On keyboards that use AltGr for accented letters, pick another key in Settings.
  - English only in this preview.

Credits: NVIDIA Parakeet TDT 0.6B v2 (CC BY 4.0) and sherpa-onnx (Apache 2.0).
See NOTICE.txt.
