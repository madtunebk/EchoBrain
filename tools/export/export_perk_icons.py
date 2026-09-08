#!/usr/bin/env python3
"""One-shot live export of every catalog echo's icon texture key + display
name - the other half of perk_catalog.json's static data that only lives in
the client (GetSpellInfo), same idea as export_perk_descriptions.py.

Board choices' icon/name never depend on stacks or any other live context
(unlike description text, which can for locked echoes), so this one static
file covers every card FlaskGUI will ever need to show, board or locked -
see WoW_AddOns/EchoTracker/EchoTracker.lua's PackIcons for why echo_icons_N
itself now only ever covers the handful of currently-locked slots live.

Triggers EchoTracker.lua's EchoTracker_ExportIcons() (a short one-line
/api/cmd/lua call - the actual catalog-wide loop lives in the addon file
itself). Results come back chunked across echo_icon_1..N + echo_icon_count,
each part "spellId<US>iconKey<US>name" joined by <RS> - same ASCII Unit/
Record Separator scheme as export_perk_descriptions.py, for the same reason
(a stray ":" or ";" in a display name must never corrupt parsing).

    python3 tools/export/export_perk_icons.py
    python3 tools/export/export_perk_icons.py --out data/perk_display.json
"""

from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent / "sdk" / "python"))
from wow_bridge import WowBridge  # noqa: E402
from app_paths import DATA_DIR  # noqa: E402

ID_SEP = chr(31)   # ASCII Unit Separator - matches EchoTracker.lua's EXPORT_ID_SEP
PART_SEP = chr(30)  # ASCII Record Separator - matches EchoTracker.lua's EXPORT_PART_SEP


def wait_for(bridge: WowBridge, key: str, timeout: float) -> str | None:
    deadline = time.time() + timeout
    while time.time() < deadline:
        value = bridge.get(key)
        if value is not None:
            return value
        time.sleep(1.0)
    return None


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--api", default="http://127.0.0.1:8765")
    parser.add_argument("--out", default=str(DATA_DIR / "perk_display.json"))
    parser.add_argument("--timeout", type=float, default=30.0, help="seconds to wait for each chunk to arrive")
    args = parser.parse_args()

    bridge = WowBridge(args.api)

    print("[export] triggering EchoTracker_ExportIcons() in-game...")
    bridge.run_lua("EchoTracker_ExportIcons()")

    count_raw = wait_for(bridge, "echo_icon_count", args.timeout)
    if count_raw is None:
        raise SystemExit(
            "no echo_icon_count arrived - is EchoTracker loaded and logged in? "
            "(check the wow_bridge terminal for [addon-data] lines)"
        )
    count = int(count_raw)
    print(f"[export] expecting {count} chunk(s)...")

    display: dict[str, dict[str, str]] = {}
    for i in range(1, count + 1):
        chunk = wait_for(bridge, f"echo_icon_{i}", args.timeout)
        if chunk is None:
            print(f"[export] WARNING: chunk {i}/{count} never arrived, skipping")
            continue
        for part in chunk.split(PART_SEP):
            if not part:
                continue
            fields = part.split(ID_SEP, 2)
            if len(fields) != 3:
                continue
            spell_id, icon, name = fields
            display[spell_id] = {"icon": icon, "name": name}
        print(f"[export] chunk {i}/{count} ok ({len(display)} total so far)")

    out_path = Path(args.out)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(display, indent=2, sort_keys=True, ensure_ascii=False), encoding="utf-8")
    print(f"[export] wrote {len(display)} entries -> {out_path}")


if __name__ == "__main__":
    main()
