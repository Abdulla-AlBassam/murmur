"""Murmur runs in two modes, the same two as the macOS build.

With no arguments it is the tray app. With one of the flags below it is a
headless harness, so the pipeline can be exercised from a terminal and a
misbehaving machine can be diagnosed without guesswork:

    python -m murmur --transcribe recording.wav
    python -m murmur --clean "um so meet at 3 no wait 4"
    python -m murmur --clean-suite
    python -m murmur --list-inputs
    python -m murmur --record-test 5
    python -m murmur --diag

The installed build answers to the same flags: Murmur.exe --diag.
"""

from __future__ import annotations

import sys

from . import paths
from .log import log, milestone


def main(argv: list[str] | None = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    paths.ensure_directories()
    milestone("start")

    if argv:
        # A flag means a terminal is waiting for output; the windowed build
        # has to go and find it.
        from . import winapi

        winapi.attach_console()

    if "--transcribe" in argv:
        return _transcribe(argv)
    if "--clean" in argv:
        return _clean(argv)
    if "--clean-suite" in argv:
        return _clean_suite()
    if "--list-inputs" in argv:
        return _list_inputs()
    if "--record-test" in argv:
        return _record_test(argv)
    if "--diag" in argv:
        return _diagnostics()
    return _run_app()


# MARK: - The app


def _run_app() -> int:
    from . import ui, winapi
    from .app import DictationApp

    # One Murmur at a time. Two would both see the key, both open the
    # microphone and both paste.
    if not winapi.claim_single_instance():
        log("another Murmur is already running; bringing it forward and quitting")
        winapi.bring_existing_window_forward()
        return 0

    if not winapi.IS_WINDOWS:
        print("The Murmur app itself only runs on Windows. The harness flags work anywhere.")
        return 1

    app = DictationApp()
    app.start()
    ui.run(app)
    return 0


# MARK: - Harnesses


def _argument_after(argv: list[str], flag: str) -> str | None:
    index = argv.index(flag)
    return argv[index + 1] if index + 1 < len(argv) else None


def _transcribe(argv: list[str]) -> int:
    from . import asr
    from .store import Settings

    path = _argument_after(argv, "--transcribe")
    if not path:
        print("usage: --transcribe <audio file>")
        return 2
    print(asr.transcribe_file(path, Settings.load().whisper_model))
    return 0


def _load_polisher():
    """Loads the polishing model for a harness run, reporting progress on
    the terminal rather than in a window."""
    from . import polish
    from .store import Settings

    settings = Settings.load()
    model = polish.PolishModel()

    def progress(done: int, total: int) -> None:
        share = done / total if total else 0
        print(f"\r  downloading {share:6.1%} ({done / 1024**3:.2f} GB)", end="", flush=True)

    choice = polish.resolve_choice(settings.polish_model)
    if not polish.is_downloaded(choice):
        print(f"Fetching {choice.label} ({choice.approx_bytes / 1024**3:.1f} GB), once only.")
    try:
        model.ensure_loaded(settings.polish_model, progress)
    except Exception as error:
        # The harness still has something to say without the model: the
        # deterministic layers are what a rejected polish falls back to
        # anyway, so showing them is the point rather than a consolation.
        print(f"\r{model.status}{' ' * 24}")
        print(f"  ({error})")
        print("  Showing the deterministic result only.")
        return model, settings
    print(f"\r{model.status}{' ' * 24}")
    return model, settings


def _clean(argv: list[str]) -> int:
    from .cleaner import TranscriptCleaner
    from .store import Dictionary

    text = _argument_after(argv, "--clean")
    if not text:
        print('usage: --clean "the text to clean"')
        return 2
    model, settings = _load_polisher()
    outcome = TranscriptCleaner(model, settings).process(text, Dictionary.current_terms())
    print(outcome.text)
    if outcome.source != "model":
        note = f": {outcome.note}" if outcome.note else ""
        print(f"[{outcome.source}{note}]")
    return 0


def _clean_suite() -> int:
    from .suite import run

    model, settings = _load_polisher()
    print(run(model, settings))
    return 0


def _list_inputs() -> int:
    from .audio import input_devices, resolve_device
    from .store import Settings

    chosen = resolve_device(Settings.load().input_device)
    for device in input_devices():
        marker = "  <- Murmur records from this" if chosen and device["index"] == chosen["index"] else ""
        default = " (system default)" if device["is_default"] else ""
        print(f'{device["name"]}\t{device["rate"]} Hz{default}{marker}')
    return 0


def _record_test(argv: list[str]) -> int:
    """Records for a few seconds and runs the whole pipeline on it, printing
    each stage. The quickest way to tell a microphone problem from a
    recognition problem."""
    import time

    from . import asr
    from .audio import Recorder
    from .cleaner import TranscriptCleaner
    from .store import Dictionary, Settings

    seconds = float(_argument_after(argv, "--record-test") or 4)
    settings = Settings.load()
    recorder = Recorder()
    recorder.start(settings.input_device)
    print(f"Recording for {seconds:g} s. Speak now.")
    time.sleep(seconds)
    audio = recorder.stop()

    import numpy as np

    rms = float(np.sqrt(np.mean(np.square(audio)))) if audio.size else 0.0
    print(f"Captured {audio.size / asr.SAMPLE_RATE:.1f} s, loudness (rms) {rms:.5f}")
    if rms < asr.SILENCE_RMS:
        print("That is silence. Check the microphone in Settings and that Windows is not muting it.")
        return 1

    transcriber = asr.Transcriber()
    transcriber.ensure_loaded(settings.whisper_model, settings.compute_device)
    terms = Dictionary.current_terms()
    transcript = transcriber.transcribe(audio, terms)
    print(f"Transcript: {transcript}")

    model, _ = _load_polisher()
    outcome = TranscriptCleaner(model, settings).process(transcript, terms)
    print(f"Polished [{outcome.source}]: {outcome.text}")
    return 0


def _diagnostics() -> int:
    import platform

    from . import polish, winapi
    from .store import Settings

    settings = Settings.load()
    choice = polish.resolve_choice(settings.polish_model)
    print(f"Murmur on {platform.platform()}")
    print(f"Python {sys.version.split()[0]}")
    print(f"Push-to-talk key : {winapi.hotkey_for(settings.hotkey).label}")
    print(f"Cores (physical) : {polish.physical_cores()}")
    print(f"Memory           : {polish.total_memory_gb():.1f} GB")
    print(f"Speech model     : {settings.whisper_model}")
    print(f"Polishing model  : {choice.label} ({'downloaded' if polish.is_downloaded(choice) else 'not downloaded'})")
    print(f"Settings         : {paths.SETTINGS_FILE}")
    print(f"Models           : {paths.MODELS_DIR}")
    print(f"Log              : {paths.LOG_FILE}")

    for module in ("numpy", "sounddevice", "soxr", "faster_whisper", "llama_cpp", "PIL", "pystray"):
        try:
            __import__(module)
            print(f"  {module:16s} ok")
        except Exception as error:
            print(f"  {module:16s} MISSING ({error})")

    try:
        from .audio import input_devices

        devices = input_devices()
        print(f"Microphones      : {len(devices)}")
        for device in devices:
            print(f"  {device['name']}{' (default)' if device['is_default'] else ''}")
    except Exception as error:
        print(f"Microphones      : could not enumerate ({error})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
