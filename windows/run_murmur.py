"""PyInstaller entry point. Kept separate from murmur/__main__.py because a
frozen build has no -m."""

import multiprocessing
import sys

from murmur.__main__ import main

if __name__ == "__main__":
    multiprocessing.freeze_support()
    sys.exit(main())
