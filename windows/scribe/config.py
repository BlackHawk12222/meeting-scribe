"""Settings and file locations.

Everything lives under %LOCALAPPDATA%\\Scribe:
    config.json   settings
    scribe.log    log file (the app has no console window)
    models\\       downloaded speech model
"""

from __future__ import annotations

import json
import logging
import os
import sys
from dataclasses import asdict, dataclass, field
from pathlib import Path

log = logging.getLogger("scribe")

# Hotkeys the user can choose. Value = Windows virtual-key code.
HOTKEYS: dict[str, int] = {
    "Right Alt": 0xA5,
    "Right Ctrl": 0xA3,
    "Caps Lock": 0x14,
    "Scroll Lock": 0x91,
    "Pause": 0x13,
    "Insert": 0x2D,
    "F8": 0x77,
    "F9": 0x78,
    "F10": 0x79,
    "F13": 0x7C,
    "F14": 0x7D,
    "F15": 0x7E,
}
DEFAULT_HOTKEY = "Right Alt"


def app_dir() -> Path:
    base = os.environ.get("LOCALAPPDATA")
    if not base:  # not on Windows (development / CI on another OS)
        base = os.path.join(Path.home(), ".local", "share")
    p = Path(base) / "Scribe"
    p.mkdir(parents=True, exist_ok=True)
    return p


def models_dir() -> Path:
    p = app_dir() / "models"
    p.mkdir(parents=True, exist_ok=True)
    return p


def resource_path(name: str) -> Path:
    """A file shipped next to the app (works both from source and from the PyInstaller build)."""
    base = Path(getattr(sys, "_MEIPASS", Path(__file__).resolve().parent.parent))
    return base / name


@dataclass
class Settings:
    hotkey: str = DEFAULT_HOTKEY
    restore_clipboard: bool = True
    add_trailing_space: bool = True
    threads: int = 0  # 0 = automatic
    extra: dict = field(default_factory=dict)

    @property
    def hotkey_vk(self) -> int:
        return HOTKEYS.get(self.hotkey, HOTKEYS[DEFAULT_HOTKEY])

    @property
    def num_threads(self) -> int:
        if self.threads > 0:
            return self.threads
        return max(1, min(4, (os.cpu_count() or 2) - 1 or 1))

    @classmethod
    def load(cls) -> "Settings":
        path = app_dir() / "config.json"
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except FileNotFoundError:
            return cls()
        except Exception:  # noqa: BLE001
            log.exception("config.json unreadable, using defaults")
            return cls()
        s = cls()
        for k, v in data.items():
            if hasattr(s, k):
                setattr(s, k, v)
        if s.hotkey not in HOTKEYS:
            s.hotkey = DEFAULT_HOTKEY
        return s

    def save(self) -> None:
        path = app_dir() / "config.json"
        path.write_text(json.dumps(asdict(self), indent=2), encoding="utf-8")


def setup_logging() -> None:
    handlers: list[logging.Handler] = []
    try:
        handlers.append(logging.FileHandler(app_dir() / "scribe.log", encoding="utf-8"))
    except Exception:  # noqa: BLE001
        pass
    if sys.stderr is not None:  # windowed builds have no stderr
        handlers.append(logging.StreamHandler())
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(threadName)s: %(message)s",
        handlers=handlers,
    )
