"""Orchestrates the whole dictation loop:
key down → record → key up → transcribe → polish → insert text.

Threads, and why there are this many. The keyboard hook callback has about
300 ms before Windows decides the hook is misbehaving and quietly removes
it, so it only puts an event on a queue. A control thread picks those up and
opens or closes the microphone, which is quick. Everything slow
(transcription, polishing) goes to a worker thread, so that pressing the key
again while the last dictation is still being processed still starts
recording immediately.
"""

from __future__ import annotations

import queue
import threading
import time
from dataclasses import dataclass

from . import asr, audio, cleaner, inserter, polish, winapi
from .log import Stopwatch, log, milestone, since_start_ms
from .store import Dictionary, History, Settings

IDLE, RECORDING, PROCESSING = "idle", "recording", "processing"


@dataclass
class Status:
    """Everything the window shows. Read from the UI thread, written from
    the worker; plain assignment of immutable values, so no lock."""

    state: str = IDLE
    hotkey_ready: bool = False
    speech: str = "Starting…"
    polish: str = "Starting…"
    microphone: str = "Not checked yet"
    download_progress: float | None = None
    download_label: str = ""
    last_problem: str | None = None
    ready_after_ms: int | None = None

    @property
    def is_ready(self) -> bool:
        return self.hotkey_ready and self.speech.startswith("Speech model ready") and self.polish.startswith("Polishing model ready")


class DictationApp:
    def __init__(self) -> None:
        from . import paths

        #: True the first time Murmur runs on this PC, which is when the
        #: window opens by itself to show the model download.
        self.first_run = not paths.SETTINGS_FILE.exists()
        self.settings = Settings.load()
        self.history = History()
        self.dictionary = Dictionary()
        self.status = Status()

        self.recorder = audio.Recorder()
        self.transcriber = asr.Transcriber()
        self.polisher = polish.PolishModel()
        self.cleaner = cleaner.TranscriptCleaner(self.polisher, self.settings)

        self.listener = winapi.HotkeyListener(self._on_key_down, self._on_key_up)
        self.listener.set_hotkey(self.settings.hotkey)

        #: Called on any change worth redrawing. The UI sets this and is
        #: responsible for hopping to its own thread.
        self.on_change = None
        #: Called with "listening", "working" or None for the floating pill.
        self.on_pill = None

        self._events: queue.Queue = queue.Queue()
        self._work: queue.Queue = queue.Queue()
        self._recording_started = 0.0
        self._stopping = False

    # MARK: - Lifecycle

    def start(self) -> None:
        threading.Thread(target=self._control_loop, name="murmur-control", daemon=True).start()
        threading.Thread(target=self._work_loop, name="murmur-work", daemon=True).start()
        threading.Thread(target=self._load_models, name="murmur-load", daemon=True).start()
        self.listener.start()
        self.status.hotkey_ready = True
        self._changed()

    def shutdown(self) -> None:
        self._stopping = True
        self.listener.stop()
        self.recorder.abandon()
        self.polisher.unload()

    def _changed(self) -> None:
        if self.on_change:
            try:
                self.on_change()
            except Exception as error:
                log(f"a status listener failed: {error!r}")

    def _pill(self, mode) -> None:
        if self.on_pill:
            try:
                self.on_pill(mode)
            except Exception as error:
                log(f"the pill failed: {error!r}")

    # MARK: - Models

    def _load_models(self) -> None:
        """Loads both models in the background so the window can open
        immediately and show what is still missing."""

        def progress(done: int, total: int) -> None:
            self.status.download_progress = done / total if total else None
            self.status.download_label = f"{done / 1024**3:.2f} of {total / 1024**3:.2f} GB"
            self._changed()

        try:
            self.status.speech = "Downloading the speech model…"
            self._changed()
            self.transcriber.ensure_loaded(
                self.settings.whisper_model, self.settings.compute_device
            )
        except Exception:
            pass
        self.status.speech = self.transcriber.status
        self._changed()

        try:
            self.polisher.ensure_loaded(self.settings.polish_model, progress)
        except Exception:
            pass
        self.status.polish = self.polisher.status
        self.status.download_progress = None
        self._changed()

        # Both warm-ups are slow and neither blocks the user, so they happen
        # after the window has already said "ready".
        self.transcriber.warm()
        self.polisher.warm(cleaner.warm_messages(self.dictionary.terms))
        if self.status.is_ready and self.status.ready_after_ms is None:
            self.status.ready_after_ms = since_start_ms()
            milestone("ready to dictate")
        self._changed()

    def reload_models(self) -> None:
        """After a settings change. Runs in the background."""
        threading.Thread(target=self._load_models, name="murmur-reload", daemon=True).start()

    # MARK: - Hotkey

    def _on_key_down(self) -> None:
        self._events.put("down")

    def _on_key_up(self) -> None:
        self._events.put("up")

    def _control_loop(self) -> None:
        while not self._stopping:
            try:
                event = self._events.get(timeout=0.5)
            except queue.Empty:
                continue
            try:
                if event == "down":
                    self._begin()
                elif event == "up":
                    self._end()
            except Exception as error:
                log(f"dictation control failed: {error!r}")
                self.status.last_problem = str(error)
                self.status.state = IDLE
                self._pill(None)
                self._changed()

    def _begin(self) -> None:
        if self.status.state != IDLE:
            return
        if not self.transcriber.ready:
            self.status.last_problem = "Still getting ready. " + self.status.speech
            self._changed()
            return
        self.status.last_problem = None
        try:
            self.recorder.start(self.settings.input_device)
        except Exception as error:
            self.status.last_problem = f"Could not open the microphone: {error}"
            self.status.microphone = "Could not be opened"
            self._changed()
            return
        self.status.microphone = "Recording"
        self.status.state = RECORDING
        self._recording_started = time.monotonic()
        self._pill("listening")
        self._changed()

    def _end(self) -> None:
        if self.status.state != RECORDING:
            return
        held = time.monotonic() - self._recording_started
        audio_data = self.recorder.stop()
        self.status.microphone = "Idle"

        # A quick tap is an accident, not a dictation.
        if held < self.settings.min_hold_seconds:
            self.status.state = IDLE
            self._pill(None)
            self._changed()
            return

        self.status.state = PROCESSING
        self._pill("working")
        self._changed()
        self._work.put((audio_data, held))

    # MARK: - Processing

    def _work_loop(self) -> None:
        while not self._stopping:
            try:
                audio_data, held = self._work.get(timeout=0.5)
            except queue.Empty:
                continue
            try:
                self._process(audio_data, held)
            except Exception as error:
                log(f"dictation failed: {error!r}")
                self.status.last_problem = f"Dictation failed: {error}"
            finally:
                self.status.state = IDLE
                self._pill(None)
                self._changed()

    def _process(self, audio_data, held: float) -> None:
        clock = Stopwatch()
        terms = self.dictionary.terms
        transcript = self.transcriber.transcribe(audio_data, terms).strip()
        if not transcript:
            log(f"nothing recognised in {held:.1f} s of audio, nothing inserted")
            self.status.last_problem = "Nothing was recognised. Is the right microphone selected?"
            return

        outcome = self.cleaner.process(transcript, terms)
        inserter.insert(outcome.text)
        self.history.add(
            text=outcome.text, raw=None if outcome.text == transcript else transcript
        )
        if outcome.source != "model":
            self.status.last_problem = f"Inserted without polishing ({outcome.note})"
        log(f"text inserted {clock.ms} ms after the key came up")

    # MARK: - Settings

    def apply_settings(self, **changes) -> None:
        reload_needed = False
        for name, value in changes.items():
            if getattr(self.settings, name, None) == value:
                continue
            setattr(self.settings, name, value)
            if name in ("whisper_model", "polish_model", "compute_device"):
                reload_needed = True
            if name == "hotkey":
                self.listener.set_hotkey(value)
            if name == "launch_at_login":
                winapi.set_launch_at_login(value)
        self.settings.save()
        if reload_needed:
            self.reload_models()
        self._changed()
