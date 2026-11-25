"""Small Win32 helpers through ctypes: clipboard, Ctrl+V, no-activate windows, single instance."""

from __future__ import annotations

import ctypes
import logging
import sys
import time
from ctypes import wintypes

log = logging.getLogger("scribe")

IS_WINDOWS = sys.platform == "win32"

if IS_WINDOWS:
    user32 = ctypes.WinDLL("user32", use_last_error=True)
    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)

    HGLOBAL = wintypes.HANDLE
    user32.OpenClipboard.argtypes = [wintypes.HWND]
    user32.OpenClipboard.restype = wintypes.BOOL
    user32.CloseClipboard.restype = wintypes.BOOL
    user32.EmptyClipboard.restype = wintypes.BOOL
    user32.GetClipboardData.argtypes = [wintypes.UINT]
    user32.GetClipboardData.restype = wintypes.HANDLE
    user32.SetClipboardData.argtypes = [wintypes.UINT, wintypes.HANDLE]
    user32.SetClipboardData.restype = wintypes.HANDLE
    user32.EnumClipboardFormats.argtypes = [wintypes.UINT]
    user32.EnumClipboardFormats.restype = wintypes.UINT
    user32.RegisterClipboardFormatW.argtypes = [wintypes.LPCWSTR]
    user32.RegisterClipboardFormatW.restype = wintypes.UINT
    kernel32.GlobalAlloc.argtypes = [wintypes.UINT, ctypes.c_size_t]
    kernel32.GlobalAlloc.restype = HGLOBAL
    kernel32.GlobalLock.argtypes = [HGLOBAL]
    kernel32.GlobalLock.restype = ctypes.c_void_p
    kernel32.GlobalUnlock.argtypes = [HGLOBAL]
    kernel32.GlobalUnlock.restype = wintypes.BOOL
    kernel32.GlobalSize.argtypes = [HGLOBAL]
    kernel32.GlobalSize.restype = ctypes.c_size_t
    kernel32.GlobalFree.argtypes = [HGLOBAL]
    kernel32.GlobalFree.restype = HGLOBAL
    user32.GetWindowLongW.argtypes = [wintypes.HWND, ctypes.c_int]
    user32.GetWindowLongW.restype = ctypes.c_long
    user32.SetWindowLongW.argtypes = [wintypes.HWND, ctypes.c_int, ctypes.c_long]
    user32.SetWindowLongW.restype = ctypes.c_long
    user32.GetParent.argtypes = [wintypes.HWND]
    user32.GetParent.restype = wintypes.HWND
    kernel32.CreateMutexW.argtypes = [ctypes.c_void_p, wintypes.BOOL, wintypes.LPCWSTR]
    kernel32.CreateMutexW.restype = wintypes.HANDLE

CF_UNICODETEXT = 13
CF_DIB = 8
CF_HDROP = 15
CF_DIBV5 = 17
GMEM_MOVEABLE = 0x0002


def _open_clipboard() -> bool:
    for _ in range(25):
        if user32.OpenClipboard(None):
            return True
        time.sleep(0.02)
    return False


def _formats_to_keep() -> set[int]:
    keep = {CF_UNICODETEXT, CF_DIB, CF_DIBV5, CF_HDROP}
    for name in ("HTML Format", "Rich Text Format", "PNG"):
        fmt = user32.RegisterClipboardFormatW(name)
        if fmt:
            keep.add(fmt)
    return keep


def clipboard_snapshot(limit_bytes: int = 64 * 1024 * 1024) -> list[tuple[int, bytes]] | None:
    """Copy the clipboard's common formats (text, rich text, HTML, images, files) so we can put them back."""
    if not IS_WINDOWS or not _open_clipboard():
        return None
    saved: list[tuple[int, bytes]] = []
    try:
        keep = _formats_to_keep()
        total, fmt = 0, 0
        while True:
            fmt = user32.EnumClipboardFormats(fmt)
            if not fmt:
                break
            if fmt not in keep:
                continue
            h = user32.GetClipboardData(fmt)
            if not h:
                continue
            size = kernel32.GlobalSize(h)
            if not size or total + size > limit_bytes:
                continue
            p = kernel32.GlobalLock(h)
            if not p:
                continue
            try:
                saved.append((fmt, ctypes.string_at(p, size)))
                total += size
            finally:
                kernel32.GlobalUnlock(h)
    finally:
        user32.CloseClipboard()
    return saved


def _set_formats(items: list[tuple[int, bytes]]) -> bool:
    if not _open_clipboard():
        return False
    try:
        user32.EmptyClipboard()
        for fmt, data in items:
            h = kernel32.GlobalAlloc(GMEM_MOVEABLE, max(len(data), 1))
            if not h:
                continue
            p = kernel32.GlobalLock(h)
            ctypes.memmove(p, data, len(data))
            kernel32.GlobalUnlock(h)
            if not user32.SetClipboardData(fmt, h):
                kernel32.GlobalFree(h)
        return True
    finally:
        user32.CloseClipboard()


def clipboard_set_text(text: str) -> bool:
    if not IS_WINDOWS:
        return False
    return _set_formats([(CF_UNICODETEXT, (text + "\0").encode("utf-16-le"))])


def clipboard_restore(snapshot: list[tuple[int, bytes]] | None) -> None:
    if not IS_WINDOWS or snapshot is None:
        return
    if not snapshot:
        if _open_clipboard():
            user32.EmptyClipboard()
            user32.CloseClipboard()
        return
    _set_formats(snapshot)


# ---- keyboard input -------------------------------------------------------------------------

INPUT_KEYBOARD = 1
KEYEVENTF_KEYUP = 0x0002
VK_CONTROL = 0x11
VK_V = 0x56


class KEYBDINPUT(ctypes.Structure):
    _fields_ = [
        ("wVk", wintypes.WORD),
        ("wScan", wintypes.WORD),
        ("dwFlags", wintypes.DWORD),
        ("time", wintypes.DWORD),
        ("dwExtraInfo", ctypes.c_size_t),
    ]


class MOUSEINPUT(ctypes.Structure):
    _fields_ = [
        ("dx", wintypes.LONG),
        ("dy", wintypes.LONG),
        ("mouseData", wintypes.DWORD),
        ("dwFlags", wintypes.DWORD),
        ("time", wintypes.DWORD),
        ("dwExtraInfo", ctypes.c_size_t),
    ]


class _INPUTUNION(ctypes.Union):
    _fields_ = [("ki", KEYBDINPUT), ("mi", MOUSEINPUT)]


class INPUT(ctypes.Structure):
    _fields_ = [("type", wintypes.DWORD), ("u", _INPUTUNION)]


def _key(vk: int, up: bool) -> INPUT:
    i = INPUT()
    i.type = INPUT_KEYBOARD
    i.u.ki = KEYBDINPUT(vk, 0, KEYEVENTF_KEYUP if up else 0, 0, 0)
    return i


def send_ctrl_v() -> None:
    if not IS_WINDOWS:
        return
    seq = (INPUT * 4)(_key(VK_CONTROL, False), _key(VK_V, False), _key(VK_V, True), _key(VK_CONTROL, True))
    sent = user32.SendInput(4, seq, ctypes.sizeof(INPUT))
    if sent != 4:
        log.warning("SendInput sent %s of 4 events (error %s)", sent, ctypes.get_last_error())


# ---- windows ---------------------------------------------------------------------------------

GWL_EXSTYLE = -20
WS_EX_TOOLWINDOW = 0x00000080
WS_EX_TOPMOST = 0x00000008
WS_EX_NOACTIVATE = 0x08000000


def make_no_activate(tk_window) -> None:
    """Keep a Tk window from ever taking keyboard focus (so the paste goes to the user's app)."""
    if not IS_WINDOWS:
        return
    try:
        hwnd = user32.GetParent(tk_window.winfo_id()) or tk_window.winfo_id()
        style = user32.GetWindowLongW(hwnd, GWL_EXSTYLE)
        user32.SetWindowLongW(hwnd, GWL_EXSTYLE, style | WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW | WS_EX_TOPMOST)
    except Exception:  # noqa: BLE001
        log.exception("could not set no-activate style")


def enable_dpi_awareness() -> None:
    if not IS_WINDOWS:
        return
    try:
        ctypes.windll.shcore.SetProcessDpiAwareness(1)
    except Exception:  # noqa: BLE001
        try:
            user32.SetProcessDPIAware()
        except Exception:  # noqa: BLE001
            pass


_mutex = None


def single_instance(name: str = "Local\\ScribeWindowsDictation") -> bool:
    """True if this is the only running copy."""
    global _mutex
    if not IS_WINDOWS:
        return True
    _mutex = kernel32.CreateMutexW(None, False, name)
    return ctypes.get_last_error() != 183  # ERROR_ALREADY_EXISTS
