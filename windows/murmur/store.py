"""Settings, dictation history and the personal dictionary.

All three are plain files under %APPDATA%\\Murmur that the user can open,
edit or delete. Nothing is sent anywhere.
"""

from __future__ import annotations

import json
import threading
from dataclasses import asdict, dataclass, fields
from datetime import datetime

from . import paths
from .log import log

#: Held whenever a store writes, so a dictation finishing while the window
#: is open cannot interleave with a save from the UI thread.
_lock = threading.RLock()


@dataclass
class Settings:
    #: Which key is held to dictate. See winapi.HOTKEYS for the choices.
    #: The Mac build uses fn, which Windows keyboards handle in firmware and
    #: never report to software, so Right Ctrl is the closest equivalent.
    hotkey: str = "right_ctrl"
    #: Empty means "system default input".
    input_device: str = ""
    #: A faster-whisper model name. small.en is the accuracy/speed sweet
    #: spot on a laptop CPU; base.en is roughly twice as fast and noticeably
    #: worse with names.
    whisper_model: str = "small.en"
    #: "auto" picks CUDA when a usable GPU is present, otherwise CPU.
    compute_device: str = "auto"
    #: The polishing model. "auto" picks the 4B on a capable PC and the
    #: 1.5B otherwise; see polish.MODELS for the explicit choices.
    polish_model: str = "auto"
    #: How long a polish may take before Murmur gives up on it and inserts
    #: the transcript as recognised. Generous, because a cold cache on a
    #: slow machine is slower than the steady state.
    polish_timeout_seconds: float = 30.0
    launch_at_login: bool = False
    #: Held for less than this, a press is treated as an accidental tap.
    min_hold_seconds: float = 0.3

    @classmethod
    def load(cls) -> "Settings":
        try:
            raw = json.loads(paths.SETTINGS_FILE.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return cls()
        known = {f.name for f in fields(cls)}
        return cls(**{k: v for k, v in raw.items() if k in known})

    def save(self) -> None:
        with _lock:
            try:
                paths.SETTINGS_FILE.parent.mkdir(parents=True, exist_ok=True)
                paths.SETTINGS_FILE.write_text(
                    json.dumps(asdict(self), indent=2), encoding="utf-8"
                )
            except OSError as error:
                log(f"could not save settings: {error}")


@dataclass
class Entry:
    date: str
    text: str  # what was inserted
    raw: str | None = None  # the transcript, only when polishing changed it


class History:
    """The last 100 dictations, newest first. A safety net for the times a
    paste lands in a field that swallows it."""

    CAPACITY = 100

    def __init__(self) -> None:
        self.entries: list[Entry] = []
        self._load()

    def add(self, text: str, raw: str | None) -> None:
        with _lock:
            self.entries.insert(
                0, Entry(date=datetime.now().isoformat(timespec="seconds"), text=text, raw=raw)
            )
            del self.entries[self.CAPACITY :]
            self._save()

    def clear(self) -> None:
        with _lock:
            self.entries = []
            self._save()

    def _load(self) -> None:
        try:
            raw = json.loads(paths.HISTORY_FILE.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return
        self.entries = [
            Entry(date=e.get("date", ""), text=e.get("text", ""), raw=e.get("raw"))
            for e in raw
            if isinstance(e, dict)
        ]

    def _save(self) -> None:
        try:
            paths.HISTORY_FILE.parent.mkdir(parents=True, exist_ok=True)
            paths.HISTORY_FILE.write_text(
                json.dumps([asdict(e) for e in self.entries], indent=1), encoding="utf-8"
            )
        except OSError as error:
            log(f"could not save history: {error}")


class Dictionary:
    """Exact spellings of names and jargon the recogniser tends to fumble.
    Plain text, one term per line."""

    def __init__(self) -> None:
        self.text = self._read()

    @property
    def terms(self) -> list[str]:
        return [line.strip() for line in self.text.splitlines() if line.strip()]

    def set_text(self, text: str) -> None:
        with _lock:
            self.text = text
            try:
                paths.DICTIONARY_FILE.parent.mkdir(parents=True, exist_ok=True)
                paths.DICTIONARY_FILE.write_text(text, encoding="utf-8")
            except OSError as error:
                log(f"could not save the dictionary: {error}")

    @staticmethod
    def _read() -> str:
        try:
            return paths.DICTIONARY_FILE.read_text(encoding="utf-8")
        except OSError:
            return ""

    @classmethod
    def current_terms(cls) -> list[str]:
        return [line.strip() for line in cls._read().splitlines() if line.strip()]
