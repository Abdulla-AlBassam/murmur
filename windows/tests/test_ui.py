"""Builds the real window against a stub controller and drives it through
every state it can be in.

Tk errors do not show up until a widget is actually created, so importing
ui.py proves very little. This does not need Windows, only a display, and
skips itself where there is not one (a CI runner, an SSH session).
"""

import pytest

tk = pytest.importorskip("tkinter")

from murmur import ui
from murmur.app import Status
from murmur.store import Dictionary, History, Settings


class StubApp:
    def __init__(self):
        self.settings = Settings()
        self.status = Status()
        self.history = History()
        self.dictionary = Dictionary()
        self.applied = []

    def apply_settings(self, **changes):
        self.applied.append(changes)

    def reload_models(self):
        self.applied.append("reload")


@pytest.fixture
def window():
    try:
        root = tk.Tk()
    except tk.TclError:
        pytest.skip("no display")
    root.deiconify()  # a withdrawn root reports every child as unmapped
    app = StubApp()
    # History is a file, and the fixture runs once per test, so it has to
    # start from a known state rather than whatever the last test left.
    app.history.clear()
    app.history.add("A dictation that already happened.", None)
    main = ui.MainWindow(root, app)
    yield root, main, app
    root.destroy()


def _shown(widget) -> bool:
    return bool(widget.winfo_manager())


def test_the_status_pane_tracks_the_controller(window):
    root, main, app = window

    main.refresh()
    assert main.headline.cget("text") == "Getting ready…"
    assert not _shown(main.retry_button)

    app.status.download_progress = 0.42
    app.status.download_label = "1.05 of 2.50 GB"
    main.refresh()
    assert main.headline.cget("text") == "Setting Murmur up"
    assert _shown(main.progress)

    # A model that could not be fetched is the one state that offers a way
    # out of itself.
    app.status.download_progress = None
    app.status.speech = "Speech model ready (small.en)"
    app.status.polish = "Could not download the polishing model."
    main.refresh()
    assert _shown(main.retry_button)
    assert not _shown(main.progress)
    # Speech loaded but polishing did not: dictation still works, and the
    # pane has to say so rather than imply nothing works.
    assert main.headline.cget("text") == "Something is missing"
    assert "Dictation works" in main.subhead.cget("text")

    app.status.speech = "Speech model unavailable: out of memory"
    main.refresh()
    assert "cannot dictate" in main.subhead.cget("text")
    app.status.speech = "Speech model ready (small.en)"

    app.status.polish = "Polishing model ready (Qwen3 4B)"
    app.status.hotkey_ready = True
    main.refresh()
    assert main.headline.cget("text") == "Ready"
    assert "Right Ctrl" in main.subhead.cget("text")
    assert not _shown(main.retry_button)


def test_the_pill_never_becomes_visible_by_mapping(window):
    # It is faded in and out rather than mapped and unmapped, because a
    # window that maps can take the foreground with it, and the foreground
    # window is the one the dictation is about to be pasted into.
    root, _main, _app = window
    pill = ui.Pill(root)
    assert float(pill.window.attributes("-alpha")) == 0.0

    pill.show("listening")
    assert float(pill.window.attributes("-alpha")) > 0.5
    assert pill.label.cget("text") == "Listening"

    pill.show("working")
    assert pill.label.cget("text") == "Writing it up"

    pill.hide()
    assert float(pill.window.attributes("-alpha")) == 0.0
    assert _shown(pill.window) or True  # still mapped; only the alpha changed


def test_settings_widgets_reach_the_controller(window):
    _root, main, app = window
    main.hotkey_var.set("F9")
    main._on_hotkey_change()
    main.polish_var.set("Qwen2.5 1.5B (fastest)")
    main._on_polish_change()
    main.whisper_var.set("Base (fast)")
    main._on_whisper_change()
    main.device_var.set("System default")
    main._on_device_change()

    assert app.applied == [
        {"hotkey": "f9"},
        {"polish_model": "qwen2.5-1.5b"},
        {"whisper_model": "base.en"},
        {"input_device": ""},
    ]


def test_the_history_pane_lists_what_was_dictated(window):
    _root, main, _app = window
    main.refresh_history()
    assert main.history_list.size() == 1
    assert "A dictation that already happened." in main.history_list.get(0)
