# Scribe for Windows (preview)

A small, separate Windows app for Scribe's **dictation**: hold a key, speak, let go, and the text is
pasted into whatever app has focus. The Mac app (SwiftUI, in `Sources/`) does not run on Windows;
this folder is a new Python app and shares no code with it.

| Piece | How |
| --- | --- |
| Push-to-talk | Low-level keyboard hook (pynput). Default **Right Alt**, configurable in Settings. The key is swallowed so apps never see it (otherwise a lone Alt opens their menu bar). |
| Microphone | sounddevice (PortAudio), device's native rate |
| Speech to text | sherpa-onnx + NVIDIA Parakeet TDT 0.6B v2 int8 ONNX, on the CPU |
| Model | Downloaded on first launch (~480 MB, ~650 MB unpacked, SHA-256 checked) into `%LOCALAPPDATA%\Scribe\models`, with a progress window |
| Insert text | Clipboard + Ctrl+V (SendInput), then the previous clipboard (text, rich text, HTML, images, files) is put back |
| UI | Black always-on-top capsule (Listening… / Thinking… / Done) that never takes focus; tray icon (pystray) with Settings, About, Open log, Quit |
| Package | PyInstaller folder build zipped as `Scribe-Windows.zip`; unsigned |

## Run from source (Windows, Python 3.10+)

```powershell
cd windows
pip install -r requirements.txt
python run_scribe.py
```

Settings live in `%LOCALAPPDATA%\Scribe\config.json`, the log in `%LOCALAPPDATA%\Scribe\scribe.log`.

## Test and build

```powershell
python tests\test_transcribe.py ..\Resources\SelfTest\dictation_sample.wav ..\Resources\SelfTest\dictation_sample.txt --model-dir models
pip install pyinstaller
powershell -ExecutionPolicy Bypass -File packaging\build.ps1      # -> dist\Scribe\Scribe.exe, Scribe-Windows.zip
dist\Scribe\Scribe.exe --selftest ..\Resources\SelfTest\dictation_sample.wav --model-dir models --out selftest.txt
```

CI: `.github/workflows/windows.yml` (push to the `windows` branch or run by hand) runs the engine test,
builds the zip, runs the packaged `--selftest`, does a short smoke run of the packaged app, and uploads
the `Scribe-Windows` artifact.

## Not in this preview

Meetings (long recordings, speaker identification, summaries), the Tachys speed engine, dictation styles,
custom vocabulary / learning from fixes, history, auto-update, code signing, other languages.

## Credits

NVIDIA Parakeet TDT 0.6B v2, CC BY 4.0. sherpa-onnx, Apache 2.0. See `NOTICE.txt`.
