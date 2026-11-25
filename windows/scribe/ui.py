"""Tk windows: the floating capsule, the first-launch download window, Settings and About."""

from __future__ import annotations

import os
import tkinter as tk
from tkinter import ttk

from . import win32
from .config import HOTKEYS, Settings

KEY = "#010203"  # transparent color key for the capsule's rounded corners
FONT = ("Segoe UI", 10)
FONT_BOLD = ("Segoe UI Semibold", 10)


class Capsule:
    """Small black pill near the bottom of the screen: Listening… / Thinking… / Done."""

    W, H = 196, 40
    COLORS = {"listening": "#ff453a", "thinking": "#ffd60a", "done": "#30d158", "error": "#ff9f0a"}

    def __init__(self, root: tk.Tk):
        self.root = root
        self.win = tk.Toplevel(root)
        self.win.withdraw()
        self.win.overrideredirect(True)
        self.win.attributes("-topmost", True)
        try:
            self.win.attributes("-transparentcolor", KEY)
        except tk.TclError:
            pass
        self.win.configure(bg=KEY)
        self.canvas = tk.Canvas(self.win, width=self.W, height=self.H, bg=KEY, highlightthickness=0, bd=0)
        self.canvas.pack()
        self._pill(2, 2, self.W - 2, self.H - 2, fill="#0b0b0c", outline="#2c2c2e")
        r = 5
        self.dot = self.canvas.create_oval(20 - r, self.H / 2 - r, 20 + r, self.H / 2 + r, fill="#ff453a", width=0)
        self.text = self.canvas.create_text(36, self.H / 2, text="", fill="white", font=FONT_BOLD, anchor="w")
        self.bars = [
            self.canvas.create_rectangle(0, 0, 0, 0, fill="#8e8e93", width=0) for _ in range(5)
        ]
        self._hide_job = None
        self._state = "hidden"
        self._placed = False
        self._level_fn = None

    def _pill(self, x1, y1, x2, y2, **kw):
        r = (y2 - y1) / 2
        c = self.canvas
        c.create_oval(x1, y1, x1 + 2 * r, y2, **kw)
        c.create_oval(x2 - 2 * r, y1, x2, y2, **kw)
        c.create_rectangle(x1 + r, y1, x2 - r, y2, fill=kw.get("fill"), width=0)
        c.create_line(x1 + r, y1, x2 - r, y1, fill=kw.get("outline"))
        c.create_line(x1 + r, y2, x2 - r, y2, fill=kw.get("outline"))

    def _place(self):
        sw, sh = self.win.winfo_screenwidth(), self.win.winfo_screenheight()
        self.win.geometry(f"{self.W}x{self.H}+{(sw - self.W) // 2}+{sh - self.H - 90}")

    def show(self, state: str, message: str, hide_after_ms: int | None = None, level_fn=None):
        if self._hide_job:
            self.root.after_cancel(self._hide_job)
            self._hide_job = None
        self._state = state
        self._level_fn = level_fn
        self.canvas.itemconfigure(self.dot, fill=self.COLORS.get(state, "#ffffff"))
        self.canvas.itemconfigure(self.text, text=message)
        self._draw_bars(0.0)
        self._place()
        self.win.deiconify()
        if not self._placed:
            self.win.update_idletasks()
            win32.make_no_activate(self.win)
            self._placed = True
        self.win.lift()
        if level_fn:
            self._animate()
        if hide_after_ms:
            self._hide_job = self.root.after(hide_after_ms, self.hide)

    def _draw_bars(self, level: float):
        x0, mid = self.W - 62, self.H / 2
        for i, bar in enumerate(self.bars):
            if self._state != "listening":
                self.canvas.coords(bar, 0, 0, 0, 0)
                continue
            shape = (0.5, 0.8, 1.0, 0.8, 0.5)[i]
            h = 3 + 18 * min(1.0, level) * shape
            x = x0 + i * 9
            self.canvas.coords(bar, x, mid - h / 2, x + 4, mid + h / 2)

    def _animate(self):
        if self._state != "listening" or not self._level_fn:
            return
        self._draw_bars(self._level_fn())
        self.root.after(50, self._animate)

    def hide(self):
        self._state = "hidden"
        self._hide_job = None
        self.win.withdraw()


class DownloadWindow:
    """First-launch window that shows the model download and unpack progress."""

    def __init__(self, root: tk.Tk):
        self.win = tk.Toplevel(root)
        self.win.title("Scribe: getting ready")
        self.win.resizable(False, False)
        self.win.protocol("WM_DELETE_WINDOW", lambda: os._exit(0))
        frm = ttk.Frame(self.win, padding=18)
        frm.pack(fill="both", expand=True)
        ttk.Label(frm, text="Setting up Scribe", font=("Segoe UI Semibold", 13)).pack(anchor="w")
        ttk.Label(
            frm,
            text="Scribe turns speech into text on this PC. It needs a one-time download of\n"
            "the speech model (about 480 MB, about 650 MB once unpacked).",
            font=FONT,
            justify="left",
        ).pack(anchor="w", pady=(4, 12))
        self.stage = ttk.Label(frm, text="Starting…", font=FONT_BOLD)
        self.stage.pack(anchor="w")
        self.bar = ttk.Progressbar(frm, length=420, mode="determinate", maximum=1000)
        self.bar.pack(fill="x", pady=6)
        self.detail = ttk.Label(frm, text="", font=FONT, foreground="#666")
        self.detail.pack(anchor="w")
        self.win.update_idletasks()
        w, h = self.win.winfo_reqwidth(), self.win.winfo_reqheight()
        sw, sh = self.win.winfo_screenwidth(), self.win.winfo_screenheight()
        self.win.geometry(f"+{(sw - w) // 2}+{(sh - h) // 3}")

    def update(self, stage: str, frac, detail: str):
        self.stage.configure(text=stage)
        if frac is None:
            self.bar.configure(mode="indeterminate")
            self.bar.start(15)
        else:
            self.bar.stop()
            self.bar.configure(mode="determinate", value=int(frac * 1000))
        self.detail.configure(text=detail)

    def close(self):
        self.win.destroy()


class SettingsWindow:
    _open: "SettingsWindow | None" = None

    def __init__(self, root: tk.Tk, settings: Settings, on_save, models_path: str):
        if SettingsWindow._open is not None:
            SettingsWindow._open.win.lift()
            return
        SettingsWindow._open = self
        self.settings, self.on_save = settings, on_save
        self.win = tk.Toplevel(root)
        self.win.title("Scribe Settings")
        self.win.resizable(False, False)
        self.win.attributes("-topmost", True)
        self.win.protocol("WM_DELETE_WINDOW", self.close)
        frm = ttk.Frame(self.win, padding=18)
        frm.pack(fill="both", expand=True)

        ttk.Label(frm, text="Hold to dictate", font=FONT_BOLD).grid(row=0, column=0, sticky="w")
        self.hotkey = tk.StringVar(value=settings.hotkey)
        ttk.Combobox(frm, textvariable=self.hotkey, values=list(HOTKEYS), state="readonly", width=18).grid(
            row=0, column=1, sticky="w", padx=(12, 0)
        )
        ttk.Label(
            frm,
            text="Hold the key, speak, let go. The text is pasted where your cursor is.\n"
            "The key is reserved for Scribe while it runs (on keyboards that use AltGr\n"
            "for accented letters, pick a different key).",
            font=FONT,
            foreground="#555",
            justify="left",
        ).grid(row=1, column=0, columnspan=2, sticky="w", pady=(4, 12))

        self.restore = tk.BooleanVar(value=settings.restore_clipboard)
        ttk.Checkbutton(frm, text="Put my clipboard back after pasting", variable=self.restore).grid(
            row=2, column=0, columnspan=2, sticky="w"
        )
        self.space = tk.BooleanVar(value=settings.add_trailing_space)
        ttk.Checkbutton(frm, text="Add a space after each dictation", variable=self.space).grid(
            row=3, column=0, columnspan=2, sticky="w", pady=(4, 12)
        )
        ttk.Label(frm, text=f"Speech model folder:\n{models_path}", font=FONT, foreground="#555").grid(
            row=4, column=0, columnspan=2, sticky="w"
        )
        btns = ttk.Frame(frm)
        btns.grid(row=5, column=0, columnspan=2, sticky="e", pady=(16, 0))
        ttk.Button(btns, text="Cancel", command=self.close).pack(side="right")
        ttk.Button(btns, text="Save", command=self.save).pack(side="right", padx=(0, 8))

    def save(self):
        self.settings.hotkey = self.hotkey.get()
        self.settings.restore_clipboard = bool(self.restore.get())
        self.settings.add_trailing_space = bool(self.space.get())
        self.settings.save()
        self.on_save(self.settings)
        self.close()

    def close(self):
        SettingsWindow._open = None
        self.win.destroy()
