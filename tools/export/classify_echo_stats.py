#!/usr/bin/env python3
"""Classifies each catalog echo's tooltip description (data/perk_descriptions.json,
built by tools/export/export_perk_descriptions.py) into benefit/downside clauses, so
score_echo_board.py can penalize an echo with a real drawback - e.g. "+15%
damage dealt but -30% max health" - instead of only seeing quality/family/
ownership like it does today. This was the whole reason for extracting
tooltip text in the first place.

Deterministic regex classification, no live AI call in the draft loop - the
catalog is finite (546 entries) and the vocabulary of "Increases/Reduces X
by Y" clauses is small and well-understood once you've actually looked at
it (see the BAD_WHEN_INCREASED set below), so a live LLM call per pick would
add latency/cost/non-determinism for no real benefit here.

    python3 tools/export/classify_echo_stats.py
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent / "sdk" / "python"))
from app_paths import DATA_DIR  # noqa: E402

# Matches "Increases/Reduces/Decreases <stat> by <amount>" - <stat> is
# whatever free text sits between the verb and "by", which is exactly how
# every real clause in this catalog is phrased (confirmed by scanning all
# 546 descriptions for the verb+stat vocabulary before writing this).
CLAUSE_RE = re.compile(
    r"\b(Increases?|Reduces?|Decreases?)\s+(?:your\s+)?(.{2,45}?)\s+by\s+([\w@.+]+%?)",
    re.IGNORECASE,
)
# "consumes X% of your Y" - a resource cost, always a downside, not caught
# by CLAUSE_RE's Increases/Reduces phrasing.
COST_RE = re.compile(
    r"\bconsumes?\s+([\w@.+]+%?)\s+of\s+(?:your\s+|its\s+)?(?:base\s+|maximum\s+)?"
    r"(mana|health|energy|rage|runic power)\b",
    re.IGNORECASE,
)

# Stats where INCREASING them is the downside (reducing them is the
# benefit) - everything else CLAUSE_RE catches defaults to "increasing is
# good" (true for the vast majority: spell power, attack power, stamina,
# crit, haste, resistances, healing done, etc.). Built from actually
# reading the vocabulary of every "Increases/Reduces X by Y" clause across
# the real catalog, not guessed blind.
BAD_WHEN_INCREASED = {
    "damage taken",
    "all damage taken",
    "damage taken from area-of-effect attacks",
    "the damage they deal to you",
    "the mana cost of your spells",
    "the duration of fear effects on you",
    "the duration of disarm effects on you",
    "the duration of root effects on you",
    "the duration of stun effects on you",
    # Threat is genuinely role-dependent (a tank wants more, everyone else
    # wants less) - defaulted to "more threat = downside" since this
    # pipeline's scoring is DPS/heal-build oriented (spec_families never
    # special-cases tank threat generation elsewhere either).
    "threat generated",
}
# Keyword fallbacks for phrasing BAD_WHEN_INCREASED's exact strings can't
# all enumerate - e.g. "reduce the remaining cooldown of some random
# ability by 2 sec" and "...of all your abilities by 1 sec" are different
# stat text for the same underlying (good) effect. Caught these live: both
# were misclassified as downsides before this existed (cooldown wasn't in
# the exact-match set at all).
BAD_WHEN_INCREASED_KEYWORDS = (
    "cooldown",
    "duration of",  # combined with "on you" below - CC effects landing on the player
)


def is_bad_to_increase(stat_norm: str) -> bool:
    if stat_norm in BAD_WHEN_INCREASED:
        return True
    if "cooldown" in stat_norm:
        return True
    if "duration of" in stat_norm and "on you" in stat_norm:
        return True
    return False


# Regex noise, not real stats - formula/placeholder text CLAUSE_RE
# accidentally matches ("Current bonus: ...IncreasesLOWERintellect...").
IGNORE_STATS = {"this bonus", "its radius"}

# Canonical core-stat tags for score_echo_board.py's STAT_PRIORITY scoring -
# substring checks (not exact match) since real phrasing varies/compounds
# ("spell power and attack power" should tag both spell_power and
# attack_power). Only covers stats actually worth weighting by class/spec
# priority; not every CLAUSE_RE match needs a tag (e.g. "block value",
# "mount speed" aren't in anyone's priority list, left untagged on purpose).
# Deliberately small and grown as real, user-confirmed priorities get added
# (see STAT_PRIORITY in score_echo_board.py) - not a guess at every class's
# full stat vocabulary up front.
CORE_STAT_SUBSTRINGS = (
    ("haste", "haste"),
    ("strength", "strength"),
    ("agility", "agility"),
    ("intellect", "intellect"),
    ("spirit", "spirit"),
    ("stamina", "stamina"),
    ("spell power", "spell_power"),
    ("spell damage", "spell_power"),
    ("attack power", "attack_power"),
    ("critical strike", "crit"),
    ("hit rating", "hit"),
    ("expertise", "expertise"),
    ("armor penetration", "armor_pen"),
)


def core_stats_in(stat_norm: str) -> set:
    return {tag for needle, tag in CORE_STAT_SUBSTRINGS if needle in stat_norm}


def classify(desc: str) -> dict:
    benefits = []
    downsides = []
    stats = set()
    for verb, stat, amount in CLAUSE_RE.findall(desc):
        stat_norm = stat.strip().lower()
        if stat_norm in IGNORE_STATS:
            continue
        increasing = verb.lower().startswith("increase")
        is_benefit = increasing != is_bad_to_increase(stat_norm)
        clause = f"{verb.capitalize()} {stat.strip()} by {amount}"
        (benefits if is_benefit else downsides).append(clause)
        if is_benefit and increasing:
            stats |= core_stats_in(stat_norm)

    for amount, resource in COST_RE.findall(desc):
        downsides.append(f"Consumes {amount} of {resource}")

    return {
        "benefits": benefits,
        "downsides": downsides,
        "has_downside": bool(downsides),
        "stats": sorted(stats),
        # A "but"-joined clause directly linking a benefit to a side effect
        # is the strongest, clearest tradeoff signal in the data (e.g.
        # "Increases your damage dealt by 15% but reduces your maximum
        # health by 30%.") - flagged separately from has_downside since not
        # every downside is phrased this explicitly, and not every "but" is
        # a tradeoff (worth keeping distinct rather than conflating).
        "explicit_tradeoff": bool(benefits) and bool(re.search(r"\bbut\b", desc, re.IGNORECASE)),
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--descriptions", default=str(DATA_DIR / "perk_descriptions.json"))
    parser.add_argument("--out", default=str(DATA_DIR / "echo_stat_effects.json"))
    args = parser.parse_args()

    descs_path = Path(args.descriptions)
    if not descs_path.exists():
        raise SystemExit(f"missing {descs_path} - run tools/export/export_perk_descriptions.py first")
    descriptions = json.loads(descs_path.read_text(encoding="utf-8"))

    effects = {}
    for spell_id, desc in descriptions.items():
        result = classify(desc)
        result["description"] = desc
        effects[spell_id] = result

    out_path = Path(args.out)
    out_path.write_text(json.dumps(effects, indent=2, sort_keys=True, ensure_ascii=False), encoding="utf-8")

    with_downside = [k for k, v in effects.items() if v["has_downside"]]
    explicit = [k for k, v in effects.items() if v["explicit_tradeoff"]]
    print(f"[classify] {len(effects)} descriptions processed")
    print(f"[classify] {len(with_downside)} have at least one detected downside clause")
    print(f"[classify] {len(explicit)} are explicit \"benefit but downside\" tradeoffs")
    print(f"[classify] wrote -> {out_path}")
    print()
    print("Sample of explicit tradeoffs:")
    for spell_id in explicit[:15]:
        v = effects[spell_id]
        print(f"  {spell_id}: +{v['benefits']}  -{v['downsides']}")


if __name__ == "__main__":
    main()
