"""Push-to-talk key: a low-level keyboard hook (pynput) that sees the chosen key go down and up.

The key itself is swallowed, so other apps never see it. That matters for Alt: if the focused
app saw Alt pressed and released on its own, it would open its menu bar and our Ctrl+V would
land in the menu instead of the text.
"""

from __future__ import annotations

import logging
from typing import Callable

log = logging.getLogger("scribe")

WM_KEYDOWN, WM_KEYUP, WM_SYSKEYDOWN, WM_SYSKEYUP = 0x100, 0x101, 0x104, 0x105
LLKHF_INJECTED = 0x10


class PushToTalk:
    def __init__(self, vk: int, on_down: Callable[[], None], on_up: Callable[[], None]):
        self.vk = vk
        self._on_down, self._on_up = on_down, on_up
        self._down = False
        self._listener = None

    def start(self) -> None:
        from pynput import keyboard

        self._listener = keyboard.Listener(win32_event_filter=self._filter)
        self._listener.daemon = True
        self._listener.start()
        log.info("Hotkey hook started (vk=0x%02X)", self.vk)

    def stop(self) -> None:
        if self._listener is not None:
            self._listener.stop()

    def set_vk(self, vk: int) -> None:
        self._down = False
        self.vk = vk

    def _filter(self, msg, data) -> bool:
        # Runs on the hook thread for every key on the system: keep it tiny.
        if data.flags & LLKHF_INJECTED or data.vkCode != self.vk:
            return True
        if msg in (WM_KEYDOWN, WM_SYSKEYDOWN):
            if not self._down:  # ignore auto-repeat
                self._down = True
                self._safe(self._on_down)
        elif msg in (WM_KEYUP, WM_SYSKEYUP):
            if self._down:
                self._down = False
                self._safe(self._on_up)
        self._listener.suppress_event()  # raises inside pynput; the key never reaches other apps
        return False

    @staticmethod
    def _safe(fn) -> None:
        try:
            fn()
        except Exception:  # noqa: BLE001
            log.exception("hotkey callback failed")
