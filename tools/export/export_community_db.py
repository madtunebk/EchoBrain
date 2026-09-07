#!/usr/bin/env python3
"""Export EchoBrain's OfflineCommunityDB.lua (aggregated per-class pick
frequency/score snapshot, e.g. "231 Paladin builds sampled") to JSON.

Source is a static Lua table, one class per block, one perk-family/spell
entry per line - reference-only data bundled with the old EchoBrain addon
(SVaddon/EchoBrain/), read directly off disk, no addon/game involvement.
Keys come in two flavors: "g101" (perk-group/family id) and "s201398"
(spell id) - split into by_group/by_spell in the JSON output, with the
numeric id as an actual int key, instead of the raw prefixed string.

    python3 tools/export/export_community_db.py
    python3 tools/export/export_community_db.py --class PALADIN
    python3 tools/export/export_community_db.py --out data/community_paladin.json --class PALADIN
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent / "sdk" / "python"))
from app_paths import DATA_DIR, repo_root  # noqa: E402

DEFAULT_SOURCE = repo_root() / "SVaddon" / "EchoBrain" / "OfflineCommunityDB.lua"

CLASS_START_RE = re.compile(r'^\s*(\w+)=\{samples=(\d+),families=\{\s*$')
ENTRY_RE = re.compile(
    r'^\s*\["([a-z])(\d+)"\]=\{builds=(\d+),frequency=([\d.]+),avgQuality=([\d.]+),avgStacks=([\d.]+),score=(\d+)\},?\s*$'
)
CLASS_END_RE = re.compile(r'^\s*\}\},?\s*$')


def parse_community_db(source: Path) -> dict:
    classes: dict = {}
    current = None
    for line in source.read_text(encoding="utf-8").splitlines():
        start = CLASS_START_RE.match(line)
        if start:
            name, samples = start.groups()
            current = {"samples": int(samples), "by_group": {}, "by_spell": {}}
            classes[name] = current
            continue
        if current is not None and CLASS_END_RE.match(line):
            current = None
            continue
        entry = ENTRY_RE.match(line) if current is not None else None
        if entry:
            kind, id_str, builds, frequency, avg_quality, avg_stacks, score = entry.groups()
            bucket = current["by_group"] if kind == "g" else current["by_spell"]
            bucket[id_str] = {
                "builds": int(builds),
                "frequency": float(frequency),
                "avgQuality": float(avg_quality),
                "avgStacks": float(avg_stacks),
                "score": int(score),
            }
    return classes


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--source", type=Path, default=DEFAULT_SOURCE)
    parser.add_argument("--out", type=Path, default=DATA_DIR / "community_db.json")
    parser.add_argument("--class", dest="class_name", help="export only this class (e.g. PALADIN)")
    args = parser.parse_args()

    if not args.source.exists():
        raise SystemExit(f"OfflineCommunityDB.lua not found: {args.source}")

    classes = parse_community_db(args.source)

    if args.class_name:
        name = args.class_name.upper()
        if name not in classes:
            raise SystemExit(f"class {name!r} not found; available: {', '.join(sorted(classes))}")
        classes = {name: classes[name]}

    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(classes, indent=2, ensure_ascii=False), encoding="utf-8")

    for name, data in classes.items():
        print(f"{name}: samples={data['samples']} groups={len(data['by_group'])} spells={len(data['by_spell'])}")
    print(f"wrote {args.out}")


if __name__ == "__main__":
    main()
