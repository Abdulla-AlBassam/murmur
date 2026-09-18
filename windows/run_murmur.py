"""PyInstaller entry point. Kept separate from murmur/__main__.py because a
frozen build has no -m.

The standard streams are dealt with before anything else is imported. A
windowed build has no console, so Python sets sys.stdout and sys.stderr to
None, and any code that touches them dies before the window can appear.
Pointing them at nowhere is cheaper than auditing every print in the
program, and it makes the packaged app behave like the source one.
"""

import io
import multiprocessing
import os
import sys


def _ensure_streams() -> None:
    for name in ("stdout", "stderr", "stdin"):
        if getattr(sys, name, None) is None:
            mode = "r" if name == "stdin" else "w"
            try:
                setattr(sys, name, open(os.devnull, mode, encoding="utf-8"))
            except OSError:
                setattr(sys, name, io.StringIO())


_ensure_streams()

from murmur.__main__ import main  # noqa: E402  (must follow _ensure_streams)

if __name__ == "__main__":
    multiprocessing.freeze_support()
    sys.exit(main())
