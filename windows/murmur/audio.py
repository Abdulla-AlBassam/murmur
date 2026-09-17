"""Microphone capture, through WASAPI.

Murmur holds the microphone only while the push-to-talk key is down, so
nothing shows a recording indicator while it sits idle, and no other app is
locked out of the device.

The device is opened at whatever rate it prefers and the result is resampled
to the 16 kHz mono that speech recognition wants. Asking WASAPI for 16 kHz
directly works on most devices and fails on some; resampling ourselves works
on all of them.
"""

from __future__ import annotations

import threading
import time

import numpy as np

from .asr import SAMPLE_RATE
from .log import log


def _sounddevice():
    import sounddevice as sd

    return sd


def input_devices() -> list[dict]:
    """Every input the system will let us open, newest enumeration each
    time: USB microphones and headsets come and go."""
    try:
        sd = _sounddevice()
        devices = sd.query_devices()
        default_index = sd.default.device[0] if sd.default.device else None
    except Exception as error:
        log(f"could not enumerate microphones: {error!r}")
        return []
    listed = []
    for index, device in enumerate(devices):
        if device.get("max_input_channels", 0) < 1:
            continue
        listed.append(
            {
                "index": index,
                "name": device["name"],
                "rate": int(device.get("default_samplerate") or 48_000),
                "is_default": index == default_index,
            }
        )
    return listed


def resolve_device(preferred_name: str) -> dict | None:
    """The device to record from right now, resolving the preference
    against what is actually plugged in."""
    devices = input_devices()
    if not devices:
        return None
    if preferred_name:
        for device in devices:
            if device["name"] == preferred_name:
                return device
        log(f'"{preferred_name}" is not connected; using the default microphone')
    for device in devices:
        if device["is_default"]:
            return device
    return devices[0]


def resample_to_16k(audio: np.ndarray, rate: int) -> np.ndarray:
    if rate == SAMPLE_RATE:
        return audio
    try:
        import soxr

        return soxr.resample(audio, rate, SAMPLE_RATE).astype(np.float32)
    except ImportError:
        # Linear interpolation is audibly worse but still perfectly
        # intelligible to Whisper, and it keeps a missing wheel from
        # breaking dictation outright.
        count = int(round(audio.size * SAMPLE_RATE / rate))
        source = np.linspace(0, audio.size - 1, num=count, dtype=np.float64)
        return np.interp(source, np.arange(audio.size), audio).astype(np.float32)


class Recorder:
    """Captures to memory between start() and stop().

    Both calls are made from the hotkey thread, so neither may block for
    long: opening a stream is quick, and everything slow happens afterwards
    on the worker.
    """

    #: A dictation longer than this is almost certainly a stuck key.
    MAX_SECONDS = 300

    def __init__(self) -> None:
        self._stream = None
        self._chunks: list[np.ndarray] = []
        self._lock = threading.Lock()
        self._rate = SAMPLE_RATE
        self._started_at = 0.0
        self.last_notice: str | None = None

    @property
    def is_recording(self) -> bool:
        return self._stream is not None

    def start(self, preferred_name: str) -> None:
        sd = _sounddevice()
        device = resolve_device(preferred_name)
        if device is None:
            raise RuntimeError("no microphone found")

        with self._lock:
            self._chunks = []
        self._rate = device["rate"]
        self._started_at = time.monotonic()

        def callback(indata, _frames, _time, status):
            if status:
                # Overflows happen when the machine is briefly busy; the
                # gap is inaudible in a dictation and not worth failing on.
                self.last_notice = str(status)
            with self._lock:
                self._chunks.append(indata[:, 0].copy())

        self._stream = sd.InputStream(
            device=device["index"],
            channels=1,
            samplerate=self._rate,
            dtype="float32",
            blocksize=0,
            latency="low",
            callback=callback,
        )
        self._stream.start()
        log(f'recording from "{device["name"]}" at {self._rate} Hz')

    def stop(self) -> np.ndarray:
        """Closes the device and returns everything captured, at 16 kHz."""
        stream, self._stream = self._stream, None
        if stream is not None:
            try:
                stream.stop()
                stream.close()
            except Exception as error:
                log(f"could not close the microphone cleanly: {error!r}")

        with self._lock:
            chunks, self._chunks = self._chunks, []
        if not chunks:
            return np.zeros(0, dtype=np.float32)

        audio = np.concatenate(chunks).astype(np.float32)
        limit = self.MAX_SECONDS * self._rate
        if audio.size > limit:
            log(f"dictation ran past {self.MAX_SECONDS} s; keeping the first part only")
            audio = audio[:limit]
        return resample_to_16k(audio, self._rate)

    def abandon(self) -> None:
        """Drops the device and the audio without returning anything."""
        self.stop()
