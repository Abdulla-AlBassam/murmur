"""Test setup.

The profile directories are redirected before murmur.paths is imported, so
that a test run never reads or writes the real settings, history or
dictionary of whoever is running it.
"""

import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import os

_sandbox = Path(tempfile.mkdtemp(prefix="murmur-tests-"))
os.environ["APPDATA"] = str(_sandbox / "roaming")
os.environ["LOCALAPPDATA"] = str(_sandbox / "local")
