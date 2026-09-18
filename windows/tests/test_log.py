"""Logging has to survive having nowhere to write.

A windowed PyInstaller build has no console, so Python sets sys.stdout and
sys.stderr to None. The first packaged build crashed on launch for exactly
this reason, inside log(), before the window appeared or a single line of
explanation reached anywhere the user would look.

The streams are replaced inside each test body rather than from a fixture.
pytest reassigns sys.stdout and sys.stderr to its capture objects at the
start of every test phase, so anything a fixture sets during setup is
quietly undone before the test runs, and these tests passed against the
broken code when they were written that way.
"""

import contextlib
import io
import sys

from murmur import log as log_module


@contextlib.contextmanager
def no_standard_streams():
    """What a windowed build looks like: no standard streams at all."""
    saved = sys.stdout, sys.stderr
    sys.stdout = sys.stderr = None
    try:
        yield
    finally:
        sys.stdout, sys.stderr = saved


@contextlib.contextmanager
def stderr_replaced_by(stream):
    saved = sys.stderr
    sys.stderr = stream
    try:
        yield
    finally:
        sys.stderr = saved


def test_logging_survives_absent_standard_streams():
    with no_standard_streams():
        log_module.log("a line with nowhere obvious to go")
        log_module.milestone("start")


def test_the_terminal_check_is_false_without_a_stream():
    with no_standard_streams():
        assert log_module._is_terminal() is False


def test_the_terminal_check_is_false_for_a_stream_that_refuses():
    class Closed:
        def isatty(self):
            raise ValueError("I/O operation on closed file")

    with stderr_replaced_by(Closed()):
        assert log_module._is_terminal() is False


def test_the_terminal_check_is_false_for_a_redirected_stream():
    with stderr_replaced_by(io.StringIO()):
        assert log_module._is_terminal() is False


def test_the_log_file_still_receives_the_line(tmp_path, monkeypatch):
    monkeypatch.setattr(log_module, "LOG_FILE", tmp_path / "Murmur.log", raising=False)
    monkeypatch.setattr(log_module, "_handle", None, raising=False)
    with no_standard_streams():
        log_module.log("written even with no console")
    log_module._handle.flush()
    assert "written even with no console" in (tmp_path / "Murmur.log").read_text(encoding="utf-8")


def test_an_unwritable_log_file_does_not_raise(tmp_path, monkeypatch):
    # A read-only or unreachable profile directory must not take the app down.
    monkeypatch.setattr(log_module, "LOG_FILE", tmp_path / "no" / "\0" / "bad.log", raising=False)
    monkeypatch.setattr(log_module, "_handle", None, raising=False)
    with no_standard_streams():
        log_module.log("nowhere to write this")


def test_the_entry_point_replaces_missing_streams():
    # run_murmur.py does this before importing anything else, so that every
    # print in the program has somewhere to go.
    import importlib.util
    from pathlib import Path

    spec = importlib.util.spec_from_file_location(
        "run_murmur_under_test", Path(__file__).resolve().parents[1] / "run_murmur.py"
    )
    module = importlib.util.module_from_spec(spec)

    with no_standard_streams():
        spec.loader.exec_module(module)
        assert sys.stdout is not None
        assert sys.stderr is not None
        print("this would have raised AttributeError before the fix")
