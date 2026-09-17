"""First stage of the pipeline: microphone audio becomes a transcript.

The Mac uses SpeechAnalyzer, which streams and returns unpunctuated text.
Whisper is not a streaming recogniser, but push-to-talk does not need one:
the whole utterance is in hand the moment the key comes up. In exchange the
transcript arrives already punctuated and capitalised, which is a large part
of what the polishing stage has to do on the Mac.

Whisper's one real vice is hallucinating on silence: a clip with no speech
in it comes back as "Thank you." or "you", confidently. Three things keep
that out of the user's document: the voice-activity filter, a loudness gate
before the model is asked at all, and a blocklist for the handful of stock
phrases it produces from noise.
"""

from __future__ import annotations

import os
import threading

import numpy as np

from . import paths
from .log import Stopwatch, log

SAMPLE_RATE = 16_000

#: Below this RMS the clip is silence or room tone, whatever Whisper says.
SILENCE_RMS = 0.004

#: What Whisper produces from silence. Rejected only when they are the whole
#: transcript, so a dictation that really is "thank you" still works.
HALLUCINATIONS = {
    "you", "thank you", "thanks for watching", "thank you for watching",
    "thanks for watching!", "bye", "bye.", "so", ".", "peace", "okay",
    "please subscribe", "subtitles by the amara.org community",
    "transcription by castingwords", "thank you very much",
}

MODELS = {
    "tiny.en": "Tiny (fastest, least accurate)",
    "base.en": "Base (fast)",
    "small.en": "Small (recommended)",
    "medium.en": "Medium (most accurate, slowest)",
}


def _normalise(text: str) -> str:
    return " ".join(text.lower().strip().split())


class Transcriber:
    """Wraps one loaded faster-whisper model. All calls are serialised."""

    def __init__(self) -> None:
        self._model = None
        self._name: str | None = None
        self._lock = threading.Lock()
        self.status = "not loaded"
        self.ready = False

    def ensure_loaded(self, name: str, device: str = "auto") -> None:
        with self._lock:
            if self._model is not None and self._name == name:
                return
            self.ready = False
            self.status = f"Loading the {name} speech model…"
            try:
                self._model = self._load(name, device)
                self._name = name
                self.ready = True
                self.status = f"Speech model ready ({name})"
            except Exception as error:
                self._model = None
                self.status = f"Speech model unavailable: {error}"
                log(f"speech model could not be loaded: {error!r}")
                raise

    @staticmethod
    def _load(name: str, device: str):
        from faster_whisper import WhisperModel

        clock = Stopwatch()
        resolved, compute = ("cuda", "float16") if device == "cuda" else ("cpu", "int8")
        if device == "auto":
            resolved, compute = "cpu", "int8"
        model = WhisperModel(
            name,
            device=resolved,
            compute_type=compute,
            download_root=str(paths.MODELS_DIR),
            cpu_threads=max(1, (os.cpu_count() or 4) // 2),
        )
        log(f"loaded the {name} speech model on {resolved} in {clock.ms} ms")
        return model

    def warm(self) -> None:
        """Runs a second of silence through the model so the first real
        dictation does not pay for the lazy initialisation inside it."""
        if not self.ready:
            return
        clock = Stopwatch()
        try:
            self.transcribe(np.zeros(SAMPLE_RATE, dtype=np.float32), gate=False)
            log(f"speech model warm in {clock.ms} ms")
        except Exception as error:
            log(f"could not warm the speech model: {error!r}")

    def transcribe(
        self, audio: np.ndarray, dictionary: list[str] | None = None, gate: bool = True
    ) -> str:
        with self._lock:
            if self._model is None:
                raise RuntimeError("the speech model is not loaded")

            if gate:
                rms = float(np.sqrt(np.mean(np.square(audio)))) if audio.size else 0.0
                if rms < SILENCE_RMS:
                    log(f"clip is silent (rms {rms:.5f}), nothing transcribed")
                    return ""

            clock = Stopwatch()
            segments, _info = self._model.transcribe(
                audio,
                language="en",
                beam_size=5,
                vad_filter=True,
                vad_parameters={"min_silence_duration_ms": 300},
                condition_on_previous_text=False,
                # The dictionary biases spelling the same way contextual
                # strings do on the Mac.
                initial_prompt=(", ".join(dictionary) if dictionary else None),
            )
            text = "".join(segment.text for segment in segments).strip()

            duration = audio.size / SAMPLE_RATE
            if gate and duration < 4.0 and _normalise(text) in HALLUCINATIONS:
                log(f'discarded a likely hallucination: "{text}"')
                return ""
            log(f"transcribed {duration:.1f} s of audio in {clock.ms} ms")
            return text

    def transcribe_path(self, path: str) -> str:
        """Transcribes a file on disk rather than captured audio."""
        with self._lock:
            if self._model is None:
                raise RuntimeError("the speech model is not loaded")
            segments, _info = self._model.transcribe(path, language="en", beam_size=5)
            return "".join(segment.text for segment in segments).strip()


def transcribe_file(path: str, name: str = "small.en") -> str:
    """The --transcribe harness. faster-whisper decodes the file itself, so
    any format PyAV can open will do."""
    transcriber = Transcriber()
    transcriber.ensure_loaded(name)
    return transcriber.transcribe_path(path)
