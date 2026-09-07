#!/usr/bin/env python3
"""One-shot export of ProjectEbonhold's real perk/Echo catalog to JSON.

perks_data.lua is a static Lua table literal (ProjectEbonhold.PerkDatabase),
one entry per line: [spellId] = { maxStack=, classMask=, minLevel=,
quality=, groupId=, requiredSpell=, comment=, families={...} }. This reads
it directly off disk - no live game query, no addon involvement - so a
future external scorer has family/quality/class-restriction context without
asking the game for it.

    python3 tools/export/export_perk_catalog.py
    python3 tools/export/export_perk_catalog.py --out data/perk_catalog.json
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent / "sdk" / "python"))
from app_paths import DATA_DIR  # noqa: E402

DEFAULT_SOURCE = Path(os.environ.get(
    "EBON_ADDONS_DIR",
    "/mnt/c/Users/Nobus/AppData/Local/Ebonhold/Interface/AddOns",
)) / "ProjectEbonhold" / "modules" / "perks" / "perks_data.lua"

ENTRY_RE = re.compile(r'^\s*\[(?P<id>\d+)\]\s*=\s*\{(?P<body>.*)\},?\s*$')
PAIR_RE = re.compile(r'(\w+)\s*=\s*("(?:[^"\\]|\\.)*"|\{[^}]*\}|-?\d+)')
STRING_RE = re.compile(r'"((?:[^"\\]|\\.)*)"')


def parse_value(raw: str):
    if raw.startswith('"'):
        return STRING_RE.match(raw).group(1).replace('\\"', '"').replace("\\\\", "\\")
    if raw.startswith("{"):
        return STRING_RE.findall(raw)
    return int(raw)


def parse_entry(body: str) -> dict:
    return {key: parse_value(value) for key, value in PAIR_RE.findall(body)}


def parse_catalog(source: Path) -> dict:
    catalog = {}
    for line in source.read_text(encoding="utf-8").splitlines():
        match = ENTRY_RE.match(line)
        if not match:
            continue
        catalog[match.group("id")] = parse_entry(match.group("body"))
    return catalog


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--source", type=Path, default=DEFAULT_SOURCE)
    parser.add_argument("--out", type=Path, default=DATA_DIR / "perk_catalog.json")
    args = parser.parse_args()

    if not args.source.exists():
        raise SystemExit(f"perks_data.lua not found: {args.source}")

    catalog = parse_catalog(args.source)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(catalog, indent=2, ensure_ascii=False), encoding="utf-8")
    print(f"wrote {len(catalog)} perks to {args.out}")


if __name__ == "__main__":
    main()
