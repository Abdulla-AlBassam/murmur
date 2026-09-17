"""Where Murmur keeps its files.

Settings, history and the dictionary live in the roaming profile so they
follow the user between machines; the log and the speech model live in the
local one, since neither is worth syncing.
"""

from __future__ import annotations

import os
from pathlib import Path


def _appdata(variable: str, fallback: str) -> Path:
    value = os.environ.get(variable)
    if value:
        return Path(value)
    return Path.home() / fallback


DATA_DIR = _appdata("APPDATA", "AppData/Roaming") / "Murmur"
CACHE_DIR = _appdata("LOCALAPPDATA", "AppData/Local") / "Murmur"

SETTINGS_FILE = DATA_DIR / "settings.json"
HISTORY_FILE = DATA_DIR / "history.json"
DICTIONARY_FILE = DATA_DIR / "dictionary.txt"
LOG_FILE = CACHE_DIR / "Logs" / "Murmur.log"
MODELS_DIR = CACHE_DIR / "models"


def ensure_directories() -> None:
    for directory in (DATA_DIR, CACHE_DIR, LOG_FILE.parent, MODELS_DIR):
        directory.mkdir(parents=True, exist_ok=True)
