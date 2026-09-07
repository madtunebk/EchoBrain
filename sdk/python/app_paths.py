"""Resolves paths relative to the real EchoBrain repo root - works both as a
plain script (`python3 tools/x.py`) and as a PyInstaller --onefile exe.

PyInstaller gotcha this exists to fix: inside a frozen --onefile exe,
`Path(__file__)` resolves into the temporary extraction folder
(`sys._MEIPASS`, something like `C:\\Users\\...\\AppData\\Local\\Temp\\...`),
NOT the real location of the .exe on disk - every tool that computed
DATA_DIR/DB_PATH via `Path(__file__).resolve().parent...` looked for
data/perk_catalog.json etc. in that temp folder instead of next to the
actual exe (confirmed live: echo_autopilot.exe failed with "missing
C:\\Users\\Nobus\\AppData\\Local\\Temp\\data\\perk_catalog.json").
`sys.frozen` (set by PyInstaller's bootloader) is the standard way to
detect this and fall back to `sys.executable`'s real directory instead.
"""

from __future__ import annotations

import sys
from pathlib import Path


def repo_root() -> Path:
    if getattr(sys, "frozen", False):
        return Path(sys.executable).resolve().parent
    # This file lives at sdk/python/app_paths.py - repo root is two parents up.
    return Path(__file__).resolve().parent.parent.parent


DATA_DIR = repo_root() / "data"
