"""The polishing model: a small instruction-tuned LLM running in-process
through llama.cpp.

This is the Windows stand-in for Apple Intelligence on the Mac, and it is
part of the pipeline rather than an add-on: no server to install, no
account, no network once the weights are on disk. The weights are fetched
once on first run and cached under %LOCALAPPDATA%\\Murmur\\models.

Two things make it fast enough to sit in a push-to-talk loop. The prompt
prefix (instructions plus nine worked examples) is identical on every
dictation, so llama.cpp reuses its KV cache for it and only evaluates the
new transcript. And generation is capped, both in tokens and by a wall-clock
deadline, so a slow machine degrades into the deterministic fallback rather
than leaving the user waiting.
"""

from __future__ import annotations

import os
import shutil
import threading
import time
import urllib.request
from dataclasses import dataclass
from pathlib import Path

from . import paths
from .log import Stopwatch, log


@dataclass(frozen=True)
class ModelChoice:
    key: str
    label: str
    repo: str
    filename: str
    approx_bytes: int
    #: Context window. The shared prefix is around 1,000 tokens; the rest is
    #: the dictation and its cleaned form.
    n_ctx: int = 2560


#: Qwen3-4B-Instruct-2507 is the default: Apache 2.0, non-thinking, and a
#: strong enough instruction follower at 4B that the guardrails rarely have
#: to reject it. The 1.5B is there for machines where the 4B cannot keep up.
MODELS: dict[str, ModelChoice] = {
    "qwen3-4b": ModelChoice(
        "qwen3-4b",
        "Qwen3 4B (best quality)",
        "unsloth/Qwen3-4B-Instruct-2507-GGUF",
        "Qwen3-4B-Instruct-2507-Q4_K_M.gguf",
        2_500_000_000,
    ),
    "qwen2.5-1.5b": ModelChoice(
        "qwen2.5-1.5b",
        "Qwen2.5 1.5B (fastest)",
        "bartowski/Qwen2.5-1.5B-Instruct-GGUF",
        "Qwen2.5-1.5B-Instruct-Q4_K_M.gguf",
        1_100_000_000,
    ),
}

DEFAULT_MODEL = "qwen3-4b"
SMALL_MODEL = "qwen2.5-1.5b"


def physical_cores() -> int:
    """A guess at physical cores. llama.cpp is slower, not faster, when it
    is given hyperthreads as well."""
    count = os.cpu_count() or 4
    return max(1, count // 2)


def total_memory_gb() -> float:
    if os.name == "nt":
        import ctypes
        from ctypes import wintypes

        class MEMORYSTATUSEX(ctypes.Structure):
            _fields_ = [
                ("dwLength", wintypes.DWORD),
                ("dwMemoryLoad", wintypes.DWORD),
                ("ullTotalPhys", ctypes.c_ulonglong),
                ("ullAvailPhys", ctypes.c_ulonglong),
                ("ullTotalPageFile", ctypes.c_ulonglong),
                ("ullAvailPageFile", ctypes.c_ulonglong),
                ("ullTotalVirtual", ctypes.c_ulonglong),
                ("ullAvailVirtual", ctypes.c_ulonglong),
                ("ullAvailExtendedVirtual", ctypes.c_ulonglong),
            ]

        status = MEMORYSTATUSEX()
        status.dwLength = ctypes.sizeof(MEMORYSTATUSEX)
        ctypes.windll.kernel32.GlobalMemoryStatusEx(ctypes.byref(status))
        return status.ullTotalPhys / 1024**3
    try:
        return os.sysconf("SC_PAGE_SIZE") * os.sysconf("SC_PHYS_PAGES") / 1024**3
    except (ValueError, OSError, AttributeError):
        return 8.0


def resolve_choice(key: str) -> ModelChoice:
    """Turns the setting into a model, including "auto".

    The 4B wants roughly 3 GB of resident memory and enough cores to produce
    a sentence in a couple of seconds. Below that the 1.5B is the better
    experience, even though its output is rejected by the guardrails more
    often.
    """
    if key in MODELS:
        return MODELS[key]
    capable = physical_cores() >= 4 and total_memory_gb() >= 15.0
    return MODELS[DEFAULT_MODEL if capable else SMALL_MODEL]


class DownloadFailed(RuntimeError):
    """The weights could not be fetched. Almost always the connection."""


# MARK: - Weights on disk


def model_path(choice: ModelChoice) -> Path:
    return paths.MODELS_DIR / choice.filename


def is_downloaded(choice: ModelChoice) -> bool:
    path = model_path(choice)
    # A partial file left by a killed download is smaller than the real one.
    return path.exists() and path.stat().st_size > choice.approx_bytes * 0.9


def download(choice: ModelChoice, on_progress=None) -> Path:
    """Fetches the weights once, to a .part file that is only moved into
    place when the whole thing has arrived."""
    destination = model_path(choice)
    if is_downloaded(choice):
        return destination
    paths.MODELS_DIR.mkdir(parents=True, exist_ok=True)
    partial = destination.with_suffix(destination.suffix + ".part")
    url = f"https://huggingface.co/{choice.repo}/resolve/main/{choice.filename}?download=true"
    log(f"downloading {choice.filename} from {choice.repo}")

    request = urllib.request.Request(url, headers={"User-Agent": "Murmur"})
    try:
        with urllib.request.urlopen(request, timeout=60) as response, partial.open("wb") as handle:
            total = int(response.headers.get("Content-Length") or choice.approx_bytes)
            written = 0
            last_report = 0.0
            while chunk := response.read(1024 * 512):
                handle.write(chunk)
                written += len(chunk)
                now = time.monotonic()
                if on_progress and now - last_report > 0.5:
                    last_report = now
                    on_progress(written, total)
    except Exception as error:
        # Half a model is worse than none: it would load and produce
        # nonsense. Start again next time rather than resume.
        partial.unlink(missing_ok=True)
        raise DownloadFailed(str(error)) from error

    if on_progress:
        on_progress(written, written)
    shutil.move(str(partial), str(destination))
    log(f"downloaded {choice.filename} ({written / 1024**3:.2f} GB)")
    return destination


# MARK: - The model


class PolishModel:
    """Holds the loaded model. One instance for the life of the app; all
    calls are serialised, since llama.cpp keeps per-context state."""

    def __init__(self) -> None:
        self._llama = None
        self._choice: ModelChoice | None = None
        self._lock = threading.Lock()
        self.status = "not loaded"
        self.ready = False

    @property
    def choice(self) -> ModelChoice | None:
        return self._choice

    def ensure_loaded(self, key: str, on_progress=None) -> None:
        """Downloads the weights if needed and loads them. Safe to call
        again; reloads only when the chosen model changed."""
        choice = resolve_choice(key)
        with self._lock:
            if self._llama is not None and self._choice == choice:
                return
            self._unload_locked()
            self.ready = False
            try:
                if not is_downloaded(choice):
                    self.status = f"Downloading {choice.label}…"
                    download(choice, on_progress)
                self.status = f"Loading {choice.label}…"
                self._llama = self._load(choice)
                self._choice = choice
                self.ready = True
                self.status = f"Polishing model ready ({choice.label})"
            except DownloadFailed as error:
                self._llama = None
                self._choice = None
                self.status = (
                    "Could not download the polishing model. Check the internet "
                    "connection and press Try again."
                )
                log(f"polish model download failed: {error}")
                raise
            except Exception as error:
                self._llama = None
                self._choice = None
                self.status = f"Polishing model unavailable: {error}"
                log(f"polish model could not be loaded: {error!r}")
                raise

    @staticmethod
    def _load(choice: ModelChoice):
        from llama_cpp import Llama

        clock = Stopwatch()
        llama = Llama(
            model_path=str(model_path(choice)),
            n_ctx=choice.n_ctx,
            n_threads=physical_cores(),
            n_batch=512,
            verbose=False,
        )
        log(f"loaded {choice.filename} in {clock.ms} ms")
        return llama

    def _unload_locked(self) -> None:
        if self._llama is not None:
            try:
                self._llama.close()
            except Exception:
                pass
            self._llama = None

    def unload(self) -> None:
        with self._lock:
            self._unload_locked()
            self.ready = False
            self.status = "not loaded"

    def warm(self, messages: list[dict]) -> None:
        """Evaluates the shared prefix once so that the first real dictation
        is as quick as the rest. Generates a single token and throws it
        away; what matters is the KV cache it leaves behind."""
        if not self.ready:
            return
        clock = Stopwatch()
        try:
            self.complete(messages, max_tokens=1, deadline_seconds=60)
            log(f"polishing model warm in {clock.ms} ms")
        except Exception as error:
            log(f"could not warm the polishing model: {error!r}")

    def complete(
        self, messages: list[dict], *, max_tokens: int = 400, deadline_seconds: float = 30.0
    ) -> str:
        """One greedy completion, bounded by tokens and by wall-clock time.

        Greedy sampling is the shipped setting on the Mac too: for an editing
        task, anything else invents wording the speaker did not use.
        """
        with self._lock:
            if self._llama is None:
                raise RuntimeError("the polishing model is not loaded")
            deadline = time.monotonic() + deadline_seconds

            def out_of_time(_input_ids, _logits) -> bool:
                return time.monotonic() > deadline

            response = self._llama.create_chat_completion(
                messages=messages,
                temperature=0.0,
                top_k=1,
                max_tokens=max_tokens,
                stop=["</transcript>", "<transcript>"],
                stopping_criteria=_criteria(out_of_time),
            )
            return response["choices"][0]["message"]["content"] or ""


def _criteria(function):
    from llama_cpp import StoppingCriteriaList

    return StoppingCriteriaList([function])
