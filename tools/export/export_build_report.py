#!/usr/bin/env python3
"""One-shot export of every session's full build + measured combat
performance to JSON - the calibration dataset for an offline AI/analysis
pass ("which build actually got the best late-80 DPS"), not something read
live during a run.

Joins data already being recorded for other reasons, nothing new is
queried live from the game:
  - sessions: class/spec, reroll/freeze/banish totals, started/ended
    (sdk/python/echo_session_db.py, populated by echo_autopilot.py)
  - owned_echoes: final build, resolved against data/perk_catalog.json for
    name/quality/family (tools/export/export_perk_catalog.py's output)
  - actions: every TAKE/REROLL/BANISH/FREEZE this run, in order
  - fights: every completed fight's damage/dps/duration, logged by
    echo_autopilot.py from SimpleDamageMeter's dps_last_fight bridge key
    (WoW_AddOns/SimpleDamageMeter/SimpleDamageMeter.lua) - this is what
    makes "which build had the best avg DPS" answerable at all, since nothing
    else in this pipeline ever measured actual combat output before.
  - locked_echoes + max_permanent_slots: the level-gated permanent-echo
    slots (ProjectEbonhold.PerkService.GetLockedPerks()/
    GetMaximumPermanentEchoes()) - a small, explicitly-chosen subset of
    owned_echoes that survives a normal reset.
  - prestige: Soul Ashes committed to the skill tree, total prestiges, and
    the permanent ash-earn-rate bonus prestiging grants
    (ProjectEbonhold.PrestigeService) - a whole separate progression system
    from Echoes that heavily affects a session's measured DPS.

    python3 tools/export/export_build_report.py
    python3 tools/export/export_build_report.py --session 4
    python3 tools/export/export_build_report.py --out data/build_reports.json
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent / "sdk" / "python"))
from echo_session_db import (  # noqa: E402
    all_sessions, owned_for_session, fights_for_session, recent_actions, session_max_level,
    locked_for_session,
)
from app_paths import DATA_DIR  # noqa: E402


def load_json(path: Path) -> dict:
    if not path.exists():
        return {}
    return json.loads(path.read_text(encoding="utf-8"))


def build_report(session_row, catalog: dict) -> dict:
    session_id = session_row["id"]

    owned = []
    for row in owned_for_session(session_id):
        entry = catalog.get(row["spell_id"], {})
        owned.append({
            "spellId": row["spell_id"],
            "count": row["count"],
            "name": entry.get("comment"),
            "quality": entry.get("quality"),
            "families": entry.get("families"),
        })

    locked = []
    for row in locked_for_session(session_id):
        entry = catalog.get(row["spell_id"], {})
        locked.append({
            "spellId": row["spell_id"],
            "count": row["count"],
            "quality": row["quality"],
            "name": entry.get("comment"),
            "families": entry.get("families"),
        })

    fights = [
        {"level": row["level"], "damage": row["damage"], "dps": row["dps"], "duration_s": row["duration_s"]}
        for row in fights_for_session(session_id)
    ]
    dps_values = [f["dps"] for f in fights]

    actions = [
        {"action": row["action"], "spellId": row["spell_id"], "level": row["level"], "at": row["at"]}
        for row in reversed(list(recent_actions(limit=10_000, session_id=session_id)))
    ]

    return {
        "session_id": session_id,
        "class": session_row["class"],
        "spec": session_row["spec"],
        # 1=Normal, 2-6=Hardcore tiers (ProjectEbonhold.HardmodeService) -
        # tags DPS comparisons with real difficulty context, since a higher
        # tier means both harder mobs and better rewards, not just "a
        # better build". null until EchoTracker's IsDifficultyKnown() is
        # true (unknown right after a fresh /reload).
        "hardmode_tier": session_row["hardmode_tier"],
        "started_at": session_row["started_at"],
        "ended_at": session_row["ended_at"],
        "final_level": session_max_level(session_id),
        "resource_totals": {
            "reroll": session_row["reroll_total"],
            "freeze": session_row["freeze_total"],
            "banish": session_row["banish_total"],
        },
        # Skill Tree / Prestige: a separate permanent-progression system
        # (Soul Ashes spent into skill tree nodes, reset by Prestige along
        # with the run but granting a permanent ash-earn-rate bonus) that
        # explains build-to-build DPS variance the Echo data alone can't -
        # e.g. session 3 vs 4 below both being PALADIN/dps but wildly
        # different avg DPS turned out to be exactly this, not the echoes.
        "prestige": {
            "prestiges": session_row["prestiges"],
            "ash_committed": session_row["ash_committed"],
            "ash_bonus_pct": session_row["ash_bonus_pct"],
        },
        # This RUN's earned-but-not-yet-committed soul points, from the
        # routine "Accept Death" reset (PlayerRunService) - NOT the same
        # system as "prestige" above. Confirmed live 2026-09-02: Accept
        # Death sends REQUEST_ACCEPT_DEATH and does NOT increment
        # prestiges/ash_bonus_pct - only an actual, separate, deliberate
        # PrestigeService.DoPrestige() (REQUEST_DO_PRESTIGE) does that.
        "soul_points": {
            "current": session_row["soul_points"],
            "max": session_row["soul_points_max"],
        },
        "owned_echoes": owned,
        # Permanent slots (level-gated count, sessions.max_permanent_slots)
        # the player explicitly locked in - a subset of owned_echoes, from
        # ProjectEbonhold.PerkService.GetLockedPerks()/GetMaximumPermanentEchoes().
        "locked_echoes": locked,
        "max_permanent_slots": session_row["max_permanent_slots"],
        "actions": actions,
        "fights": {
            "count": len(fights),
            "avg_dps": (sum(dps_values) / len(dps_values)) if dps_values else None,
            "best_dps": max(dps_values) if dps_values else None,
            "log": fights,
        },
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--session", type=int, default=None, help="export just this session id (default: all)")
    parser.add_argument("--out", default=str(DATA_DIR / "build_reports.json"))
    args = parser.parse_args()

    catalog = load_json(DATA_DIR / "perk_catalog.json")
    sessions = [s for s in all_sessions() if args.session is None or s["id"] == args.session]
    if not sessions:
        raise SystemExit(f"no session found" + (f" with id {args.session}" if args.session else " in session.db"))

    reports = [build_report(row, catalog) for row in sessions]

    out_path = Path(args.out)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(reports, indent=2, sort_keys=False, ensure_ascii=False), encoding="utf-8")
    print(f"[export] wrote {len(reports)} session build report(s) -> {out_path}")
    for r in reports:
        best = r["fights"]["best_dps"]
        avg = r["fights"]["avg_dps"]
        p = r["prestige"]
        prestige_note = f", prestige {p['prestiges']} (ash committed {p['ash_committed']}, +{p['ash_bonus_pct']}% earn rate)" if p["prestiges"] is not None else ""
        print(
            (
                f"  session {r['session_id']}: {r['class']}/{r['spec']} lvl {r['final_level']} - "
                f"{len(r['owned_echoes'])} echoes, {r['fights']['count']} fights, "
                f"avg dps {avg:.0f}" if avg else f"  session {r['session_id']}: {r['class']}/{r['spec']} - no fights logged"
            ) + prestige_note
        )


if __name__ == "__main__":
    main()
