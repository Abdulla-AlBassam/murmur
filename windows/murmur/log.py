"""Timings and diagnostics, appended to a file the user can send on.

Never whole transcripts: at most a few words, when a polish is rejected.
"""

from __future__ import annotations

import io
import sys
import threading
import time
from datetime import datetime

from .paths import LOG_FILE

_lock = threading.Lock()
_started = time.monotonic()
_handle = None


def _stream():
    global _handle
    if _handle is None:
        try:
            LOG_FILE.parent.mkdir(parents=True, exist_ok=True)
            if LOG_FILE.exists() and LOG_FILE.stat().st_size > 2_000_000:
                LOG_FILE.replace(LOG_FILE.with_suffix(".old.log"))
            _handle = LOG_FILE.open("a", encoding="utf-8", buffering=1)
        except OSError:
            _handle = io.StringIO()  # never sys.stderr: it may not exist
    return _handle


def _is_terminal() -> bool:
    """Whether there is a terminal worth echoing to.

    A windowed build has no console, so Python leaves sys.stderr as None.
    Assuming otherwise crashed the packaged app on launch, before it could
    draw anything or write a word of explanation anywhere the user would
    find it.
    """
    stream = getattr(sys, "stderr", None)
    if stream is None:
        return False
    try:
        return bool(stream.isatty())
    except (AttributeError, ValueError, OSError):
        return False


def log(message: str) -> None:
    stamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    line = f"{stamp}  Murmur: {message}"
    with _lock:
        try:
            print(line, file=_stream(), flush=True)
        except (OSError, ValueError):
            pass
    if _is_terminal():
        try:
            print(line, file=sys.stderr)
        except (OSError, ValueError):
            pass


def milestone(what: str) -> None:
    log(f"{what} at {int((time.monotonic() - _started) * 1000)} ms")


def since_start_ms() -> int:
    """Milliseconds since the process started, for the readiness timing."""
    return int((time.monotonic() - _started) * 1000)


class Stopwatch:
    def __init__(self) -> None:
        self._start = time.monotonic()

    @property
    def ms(self) -> int:
        return int((time.monotonic() - self._start) * 1000)
