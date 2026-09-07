#!/usr/bin/env python3
"""One-shot live export of every catalog echo's tooltip description text -
the stat-priority classification data perk_catalog.json can't carry (it has
family/quality/classMask, not WHICH STAT an echo grants). GetSpellDescription()
doesn't exist on this client (confirmed live); the real source is the
tooltip, read via SetHyperlink("spell:"..id) + GameTooltipTextLeft2.

Triggers WoW_AddOns/EchoTracker/EchoTracker.lua's EchoTracker_ExportDescriptions()
(a short one-line /api/cmd/lua call - the actual 546-spell loop lives in the
addon file itself, not sent over the wire, since /api/cmd/lua's injected code
has a hard ~210-byte budget). Results come back chunked across echo_desc_1..N
+ echo_desc_count, each part "spellId<GS>description" joined by <RS> (ASCII
Record/Group Separators - chosen so free-form tooltip text can never collide
with the delimiter, unlike ";"/":" used elsewhere in this project).

The addon drip-feeds chunks into DataBridge's outbound queue one per frame
(gated on DataBridge_QueueLength()) instead of dumping them all at once -
DataBridge.lua's queue silently evicts its oldest entry once full
(MAX_QUEUE=160), which used to make most of a ~430-chunk burst vanish before
ever being sent. echo_desc_count now arrives immediately (sent first), and
every chunk after it is genuinely in flight - this script no longer needs to
guess whether a slow arrival means "still queued" vs "lost".

A description longer than one addon message's byte budget (~195 bytes) is
split into several consecutive same-id parts on the addon side and
concatenated back together here (see the ID_SEP-repeat handling below) -
NOT truncated, so long tooltips come through in full. One consequence: if a
chunk in the MIDDLE of a multi-piece description's run is ever skipped (the
WARNING case below), the pieces on either side of the gap still get
concatenated together with no marker - producing text that silently reads
as spliced/wrong rather than erroring. Not expected in practice now that
the queue-eviction bug is fixed, but worth knowing if a description ever
looks garbled.

    python3 tools/export/export_perk_descriptions.py
    python3 tools/export/export_perk_descriptions.py --out data/perk_descriptions.json
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

ID_SEP = chr(31)   # ASCII Unit Separator - matches EchoTracker.lua's EXPORT_ID_SEP (NOT chr(29):
                    # that's DataBridge.lua's own GROUP_SEP, stripped from every value in transit)
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
    parser.add_argument("--out", default=str(DATA_DIR / "perk_descriptions.json"))
    parser.add_argument("--timeout", type=float, default=30.0, help="seconds to wait for each chunk to arrive")
    args = parser.parse_args()

    bridge = WowBridge(args.api)

    print("[export] triggering EchoTracker_ExportDescriptions() in-game...")
    bridge.run_lua("EchoTracker_ExportDescriptions()")

    count_raw = wait_for(bridge, "echo_desc_count", args.timeout)
    if count_raw is None:
        raise SystemExit(
            "no echo_desc_count arrived - is EchoTracker loaded and logged in? "
            "(check the wow_bridge terminal for [addon-data] lines)"
        )
    count = int(count_raw)
    print(f"[export] expecting {count} chunk(s)...")

    descriptions: dict[str, str] = {}
    for i in range(1, count + 1):
        chunk = wait_for(bridge, f"echo_desc_{i}", args.timeout)
        if chunk is None:
            print(f"[export] WARNING: chunk {i}/{count} never arrived, skipping")
            continue
        for part in chunk.split(PART_SEP):
            if not part or ID_SEP not in part:
                continue
            spell_id, piece = part.split(ID_SEP, 1)
            # A description longer than one addon message arrives as
            # several consecutive same-id parts (EchoTracker.lua's
            # PIECE_LEN split) - concatenate rather than overwrite so the
            # full text survives instead of only the last piece.
            descriptions[spell_id] = descriptions.get(spell_id, "") + piece
        print(f"[export] chunk {i}/{count} ok ({len(descriptions)} total so far)")

    out_path = Path(args.out)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(descriptions, indent=2, sort_keys=True, ensure_ascii=False), encoding="utf-8")
    print(f"[export] wrote {len(descriptions)} descriptions -> {out_path}")


if __name__ == "__main__":
    main()
