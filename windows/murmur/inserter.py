"""Puts text into whichever window currently has keyboard focus.

The standard trick, and the same one the Mac build uses: put the text on the
clipboard, synthesise Ctrl+V, then quietly put back whatever the user had
copied before. Typing the text out character by character is the obvious
alternative and a worse one, since it takes seconds for a paragraph and
drops characters in applications that are slow to read the input queue.

Unlike the Mac, only text is preserved across the paste. Windows clipboard
formats are owned by the application that put them there, and faithfully
round-tripping an arbitrary one (a spreadsheet range, a picture) means
re-rendering it. Text covers what people actually lose.
"""

from __future__ import annotations

import threading

from . import winapi
from .log import log

#: How long the focused window gets to service the paste before the previous
#: clipboard goes back.
RESTORE_DELAY = 0.6


def insert(text: str) -> None:
    if not text:
        return
    saved = winapi.get_clipboard_text()
    if not winapi.set_clipboard_text(text):
        log("could not place the dictation on the clipboard")
        return
    ours = winapi.clipboard_sequence()
    winapi.send_ctrl_v()

    if saved is None:
        return

    def restore() -> None:
        # If the user copied something in the meantime, that is theirs; leave
        # it alone.
        if winapi.clipboard_sequence() != ours:
            return
        winapi.set_clipboard_text(saved)

    timer = threading.Timer(RESTORE_DELAY, restore)
    timer.daemon = True
    timer.start()
