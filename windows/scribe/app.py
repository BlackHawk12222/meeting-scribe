"""Scribe for Windows: entry point and the dictation loop.

Threads:
    main        Tk event loop (capsule, windows). Everything that touches Tk runs here.
    hook        pynput keyboard hook; only posts "down"/"up" to the queue.
    tray        pystray icon; menu clicks post to the queue.
    worker      model download / load, and each transcription.
"""

from __future__ import annotations

import argparse
import logging
import os
import queue
import sys
import threading
import time
import traceback
from pathlib import Path

from . import APP_NAME, __version__, win32
from .config import Settings, models_dir, setup_logging
from .model import Transcriber, ensure_model, read_wav

log = logging.getLogger("scribe")

ABOUT_TEXT = f"""Scribe for Windows {__version__} (preview)

Hold your dictation key, speak, and let go. Your words are typed where your cursor is.
Speech recognition runs entirely on this PC; no audio leaves it.

Speech model: NVIDIA Parakeet TDT 0.6B v2, licensed CC BY 4.0
(https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2), int8 ONNX export by the sherpa-onnx project.
Speech engine: sherpa-onnx (https://github.com/k2-fsa/sherpa-onnx), Apache License 2.0.
Full notices: NOTICE.txt in the Scribe folder."""


def make_tray_image():
    from PIL import Image, ImageDraw

    s = 64
    img = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.ellipse((2, 2, s - 2, s - 2), fill=(12, 12, 14, 255), outline=(70, 70, 74, 255), width=2)
    for i, h in enumerate((14, 26, 36, 26, 14)):
        x = 15 + i * 8
        d.rounded_rectangle((x, s / 2 - h / 2, x + 4, s / 2 + h / 2), radius=2, fill=(255, 255, 255, 255))
    return img


class ScribeApp:
    def __init__(self):
        import tkinter as tk

        from .recorder import Recorder
        from .ui import Capsule

        self.settings = Settings.load()
        self.q: "queue.Queue[tuple]" = queue.Queue()
        self.root = tk.Tk()
        self.root.withdraw()
        self.root.title(APP_NAME)
        self.capsule = Capsule(self.root)
        self.recorder = Recorder()
        self.transcriber: Transcriber | None = None
        self.hotkey = None
        self.tray = None
        self.busy = False
        self.download_window = None

    # ---- startup -----------------------------------------------------------------------------

    def run(self):
        self._start_tray()
        threading.Thread(target=self._load_model, name="worker-load", daemon=True).start()
        self.root.after(30, self._pump)
        self.root.mainloop()

    def _load_model(self):
        from .model import is_installed

        try:
            root = models_dir()
            if not is_installed(root):
                self.q.put(("download_window",))
                ensure_model(root, progress=lambda st, fr, de: self.q.put(("progress", st, fr, de)))
            self.q.put(("progress", "Loading the speech model…", None, ""))
            t = Transcriber(root / "sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8", self.settings.num_threads)
            self.q.put(("ready", t))
        except Exception as e:  # noqa: BLE001
            log.exception("model setup failed")
            self.q.put(("fatal", f"Scribe could not set up the speech model:\n\n{e}"))

    def _start_tray(self):
        try:
            import pystray

            menu = pystray.Menu(
                pystray.MenuItem(lambda _i: f"Hold {self.settings.hotkey} to dictate", None, enabled=False),
                pystray.MenuItem("Settings…", lambda: self.q.put(("settings",))),
                pystray.MenuItem("About Scribe", lambda: self.q.put(("about",))),
                pystray.MenuItem("Open log", lambda: self.q.put(("log",))),
                pystray.Menu.SEPARATOR,
                pystray.MenuItem("Quit", lambda: self.q.put(("quit",))),
            )
            self.tray = pystray.Icon("Scribe", make_tray_image(), "Scribe (starting…)", menu)
            threading.Thread(target=self.tray.run, name="tray", daemon=True).start()
        except Exception:  # noqa: BLE001
            log.exception("tray icon failed")

    # ---- events (main thread) ------------------------------------------------------------------

    def _pump(self):
        try:
            while True:
                self._handle(*self.q.get_nowait())
        except queue.Empty:
            pass
        except Exception:  # noqa: BLE001
            log.exception("event failed")
        self.root.after(30, self._pump)

    def _handle(self, kind, *args):
        from tkinter import messagebox

        from .ui import DownloadWindow, SettingsWindow

        if kind == "download_window":
            self.download_window = DownloadWindow(self.root)
        elif kind == "progress":
            if self.download_window:
                self.download_window.update(*args)
            if self.tray:
                self.tray.title = f"Scribe: {args[0]}"
        elif kind == "ready":
            self.transcriber = args[0]
            if self.download_window:
                self.download_window.close()
                self.download_window = None
            self._start_hotkey()
            if self.tray:
                self.tray.title = f"Scribe: hold {self.settings.hotkey} to dictate"
            self.capsule.show("done", f"Ready: hold {self.settings.hotkey}", hide_after_ms=2500)
        elif kind == "fatal":
            messagebox.showerror("Scribe", args[0])
            self.quit()
        elif kind == "down":
            self._begin_recording()
        elif kind == "up":
            self._end_recording()
        elif kind == "result":
            self._deliver(*args)
        elif kind == "settings":
            SettingsWindow(self.root, self.settings, self._settings_saved, str(models_dir()))
        elif kind == "about":
            messagebox.showinfo("About Scribe", ABOUT_TEXT)
        elif kind == "log":
            try:
                os.startfile(str(models_dir().parent / "scribe.log"))  # type: ignore[attr-defined]
            except Exception:  # noqa: BLE001
                pass
        elif kind == "quit":
            self.quit()

    def _start_hotkey(self):
        from .hotkey import PushToTalk

        self.hotkey = PushToTalk(self.settings.hotkey_vk, lambda: self.q.put(("down",)), lambda: self.q.put(("up",)))
        self.hotkey.start()

    def _settings_saved(self, s: Settings):
        self.settings = s
        if self.hotkey:
            self.hotkey.set_vk(s.hotkey_vk)
        if self.tray:
            self.tray.title = f"Scribe: hold {s.hotkey} to dictate"
            self.tray.update_menu()

    # ---- dictation ----------------------------------------------------------------------------

    def _begin_recording(self):
        if self.busy or self.recorder.active or self.transcriber is None:
            return
        try:
            self.recorder.start()
        except Exception:  # noqa: BLE001
            log.exception("microphone failed")
            self.capsule.show("error", "No microphone", hide_after_ms=2500)
            return
        self.capsule.show("listening", "Listening…", level_fn=lambda: self.recorder.level)

    def _end_recording(self):
        if not self.recorder.active:
            return
        audio = self.recorder.stop()
        sr = self.recorder.sample_rate
        if audio.size < sr * 0.25:
            self.capsule.hide()
            return
        self.busy = True
        self.capsule.show("thinking", "Thinking…")
        threading.Thread(target=self._transcribe, args=(audio, sr), name="worker-asr", daemon=True).start()

    def _transcribe(self, audio, sr):
        t0 = time.time()
        try:
            text = self.transcriber.transcribe(audio, sr)  # type: ignore[union-attr]
            log.info("Transcribed %.1fs of audio in %.2fs (%d chars)", audio.size / sr, time.time() - t0, len(text))
            self.q.put(("result", text, None))
        except Exception as e:  # noqa: BLE001
            log.exception("transcription failed")
            self.q.put(("result", "", str(e)))

    def _deliver(self, text: str, error):
        self.busy = False
        if error:
            self.capsule.show("error", "Something went wrong", hide_after_ms=2500)
            return
        if not text:
            self.capsule.show("error", "Didn't catch that", hide_after_ms=1500)
            return
        if self.settings.add_trailing_space:
            text += " "
        snapshot = win32.clipboard_snapshot() if self.settings.restore_clipboard else None
        if not win32.clipboard_set_text(text):
            self.capsule.show("error", "Clipboard busy", hide_after_ms=2000)
            return
        self.root.after(40, self._paste_then_restore, snapshot)

    def _paste_then_restore(self, snapshot):
        win32.send_ctrl_v()
        self.capsule.show("done", "Done", hide_after_ms=900)
        if snapshot is not None:
            # Give the target app time to read the clipboard before we put the old contents back.
            self.root.after(450, win32.clipboard_restore, snapshot)

    def quit(self):
        try:
            if self.hotkey:
                self.hotkey.stop()
            if self.tray:
                self.tray.stop()
        finally:
            self.root.quit()
            os._exit(0)


# ---- command line -------------------------------------------------------------------------------


def selftest(wav: str, model_root: str | None, out: str | None) -> int:
    """Headless check used by CI: transcribe a wav and write the text (works in the windowed .exe)."""
    lines = []
    code = 1
    try:
        root = Path(model_root) if model_root else models_dir()
        d = ensure_model(root, progress=lambda st, fr, de: None)
        t0 = time.time()
        tr = Transcriber(d, Settings().num_threads)
        lines.append(f"load_seconds={time.time() - t0:.2f}")
        audio, sr = read_wav(Path(wav))
        t0 = time.time()
        text = tr.transcribe(audio, sr)
        lines.append(f"audio_seconds={audio.size / sr:.2f}")
        lines.append(f"decode_seconds={time.time() - t0:.2f}")
        lines.append(f"text={text}")
        code = 0 if text else 2
    except Exception:  # noqa: BLE001
        lines.append("error=" + traceback.format_exc().replace("\n", " | "))
    report = "\n".join(lines) + "\n"
    if out:
        Path(out).write_text(report, encoding="utf-8")
    if sys.stdout is not None:
        sys.stdout.write(report)
    return code


def main(argv=None) -> int:
    p = argparse.ArgumentParser(prog="Scribe")
    p.add_argument("--selftest", metavar="WAV", help="transcribe a wav file and exit")
    p.add_argument("--model-dir", help="folder that holds (or will hold) the speech model")
    p.add_argument("--out", help="write --selftest results to this file")
    p.add_argument("--download-model", action="store_true", help="download the speech model and exit")
    args = p.parse_args(argv)

    setup_logging()
    if args.download_model:
        ensure_model(Path(args.model_dir) if args.model_dir else models_dir(),
                     progress=lambda st, fr, de: print(f"\r{st} {de}      ", end="", flush=True) if sys.stdout else None)
        return 0
    if args.selftest:
        return selftest(args.selftest, args.model_dir, args.out)

    if not win32.single_instance():
        import tkinter as tk
        from tkinter import messagebox

        r = tk.Tk()
        r.withdraw()
        messagebox.showinfo("Scribe", "Scribe is already running. Look for its icon in the system tray.")
        return 0
    win32.enable_dpi_awareness()
    log.info("Scribe %s starting", __version__)
    ScribeApp().run()
    return 0
