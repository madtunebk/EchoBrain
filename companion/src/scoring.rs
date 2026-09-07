//! Per-card scoring. Ported from tools/live/score_echo_board.py's
//! score_card()/spec_families()/stat_priority_for()/community_entry() and
//! their supporting constants - same weights, same order of components.

use crate::ai;
use crate::board::Card;
use crate::catalog::{Catalog, CommunityDb, CommunityEntry, StatEffects};
use std::collections::{HashMap, HashSet};

const QUALITY_NAMES: [&str; 5] = ["Common", "Uncommon", "Rare", "Epic", "Legendary"];

/// Session/character context for the optional AI-assisted scoring mode
/// (`companion score-mode ai`) - doesn't vary per-card on a given
/// board, unlike everything else score_card() takes. Absent entirely in
/// "normal" mode (the default): score_card() never touches ai.rs at all then.
pub struct AiContext<'a> {
    pub ensemble: &'a ai::Ensemble,
    pub level: i64,
    pub tier: i64,
    pub prestige: i64,
    pub ash_bonus_pct: f64,
    pub hero_stats: Option<&'a [f64; 23]>,
}

/// Points added per 1.0 of the AI ensemble's own normalized target-space
/// z-score (see ai.rs's predict_z doc comment) - deliberately conservative,
/// roughly on par with stat_priority's typical swing, since the model is
/// trained on a small (625-sample), PALADIN/dps-only dataset by the
/// project's own admission ("very dumb model"). A nudge on top of the
/// heuristic, not a replacement for it - that's also why this is opt-in via
/// `score-mode ai` rather than always on.
const AI_WEIGHT: f64 = 12.0;

pub fn quality_name(q: i64) -> String {
    QUALITY_NAMES
        .get(q as usize)
        .map(|s| s.to_string())
        .unwrap_or_else(|| q.to_string())
}

/// Perk "families" as they actually appear in perk_catalog.json: Tank,
/// Melee DPS, Ranged DPS, Caster DPS, Healer, Survivability. A generic
/// "dps" bucket spanning Melee/Ranged/Caster would be wrong - a given
/// class's dps spec is only ONE of those (e.g. Retribution Paladin is
/// melee-only). Only Shaman/Druid genuinely go either way depending on
/// spec, so those two keep both.
fn class_dps_families(klass: &str) -> HashSet<&'static str> {
    match klass.to_uppercase().as_str() {
        "WARRIOR" => HashSet::from(["Melee DPS"]),
        "PALADIN" => HashSet::from(["Melee DPS"]),
        "HUNTER" => HashSet::from(["Ranged DPS"]),
        "ROGUE" => HashSet::from(["Melee DPS"]),
        "PRIEST" => HashSet::from(["Caster DPS"]),
        "SHAMAN" => HashSet::from(["Melee DPS", "Caster DPS"]),
        "MAGE" => HashSet::from(["Caster DPS"]),
        "WARLOCK" => HashSet::from(["Caster DPS"]),
        "DRUID" => HashSet::from(["Melee DPS", "Caster DPS"]),
        "DEATHKNIGHT" => HashSet::from(["Melee DPS"]),
        _ => HashSet::from(["Melee DPS", "Ranged DPS", "Caster DPS"]),
    }
}

pub fn spec_families(klass: &str, spec: &str) -> HashSet<&'static str> {
    match spec {
        "tank" => HashSet::from(["Tank"]),
        "heal" => HashSet::from(["Healer"]),
        _ => class_dps_families(klass),
    }
}

// Per-(class, spec) stat priority: points added per core stat tag an echo
// grants, on top of quality/family/downside. Populated ONLY for stats a
// real person has actually confirmed for this server - every other
// (class, spec) not listed gets 0 from this component, no silent guessing.
// Shaman/Druid's "dps" spec is left out (melee Enhancement/Feral vs. caster
// Elemental/Balance is ambiguous from the single "dps" string this server
// reports) - same discipline as the Python original.
fn stat_priority_specific(klass: &str, spec: &str) -> HashMap<&'static str, f64> {
    match (klass.to_uppercase().as_str(), spec) {
        ("PALADIN", "dps") | ("WARRIOR", "dps") | ("DEATHKNIGHT", "dps") => {
            HashMap::from([("haste", 10.0), ("strength", 7.0), ("spell_power", 4.0)])
        }
        ("HUNTER", "dps") => HashMap::from([("agility", 10.0), ("hit", 7.0), ("spell_power", 4.0)]),
        ("MAGE", "dps") | ("WARLOCK", "dps") | ("PRIEST", "dps") => {
            HashMap::from([("haste", 10.0), ("intellect", 7.0), ("spell_power", 4.0)])
        }
        _ => HashMap::new(),
    }
}

// Baseline for ANY dps spec without a more specific table above: echoes on
// this server proc off spell power even for melee specs, and haste
// generalizes well across the board (both per user confirmation). A
// class's own explicit table above still wins where it sets a value.
fn dps_baseline() -> HashMap<&'static str, f64> {
    HashMap::from([("haste", 10.0), ("spell_power", 4.0)])
}

// Tank priority = whatever that class's dps table would weigh (the same
// spell-power/haste proc reasoning still applies) plus Stamina on top for
// survivability.
fn tank_stamina_bonus() -> HashMap<&'static str, f64> {
    HashMap::from([("stamina", 10.0)])
}

fn merge(
    mut base: HashMap<&'static str, f64>,
    overlay: HashMap<&'static str, f64>,
) -> HashMap<&'static str, f64> {
    base.extend(overlay);
    base
}

pub fn stat_priority_for(klass: &str, spec: &str) -> HashMap<&'static str, f64> {
    let specific = stat_priority_specific(klass, spec);
    match spec {
        "dps" => merge(dps_baseline(), specific),
        "tank" => merge(
            merge(stat_priority_for(klass, "dps"), tank_stamina_bonus()),
            specific,
        ),
        _ => specific,
    }
}

pub fn community_entry<'a>(
    community_db: &'a CommunityDb,
    klass: &str,
    spell_id: &str,
    group_id: Option<i64>,
) -> Option<&'a CommunityEntry> {
    let class_data = community_db.get(&klass.to_uppercase())?;
    if let Some(entry) = class_data.by_spell.get(spell_id) {
        return Some(entry);
    }
    let gid = group_id?;
    class_data.by_group.get(&gid.to_string())
}

/// Points subtracted per detected downside clause (classify_echo_stats.py's
/// `downsides` list) - enough to meaningfully outweigh a Rare's quality
/// bonus without automatically vetoing the card outright.
const DOWNSIDE_PENALTY_PER_CLAUSE: f64 = -8.0;

fn round1(x: f64) -> f64 {
    (x * 10.0).round() / 10.0
}

#[derive(Debug, Clone)]
pub struct ScoreBreakdown {
    pub quality: f64,
    /// Multiplier applied to positive value. Low-rarity cards must prove
    /// substantially more useful than an Epic instead of clearing the same
    /// absolute TAKE threshold from spec-fit alone.
    pub rarity_multiplier: f64,
    pub spec_fit: f64,
    pub ownership: f64,
    pub community: f64,
    pub downside: f64,
    pub stat_priority: f64,
    /// The AI ensemble's own normalized z-score (see ai.rs's predict_z),
    /// None in "normal" mode or when the ensemble doesn't cover this class/
    /// spec. Kept separate from `ai_component` (which is this times
    /// AI_WEIGHT) so callers can show the raw model signal, not just its
    /// scaled contribution.
    pub ai_z: Option<f64>,
    pub ai_component: f64,
    pub total: f64,
}

#[derive(Debug, Clone)]
pub struct ScoredCard {
    pub index0: usize,
    pub spell_id: String,
    pub name: String,
    pub quality_name: String,
    pub families: Vec<String>,
    pub frozen: bool,
    pub carried: bool,
    pub guaranteed: bool,
    pub owned: String,
    pub downsides: Vec<String>,
    #[allow(dead_code)]
    // carried for parity with the Python dict; already folded into score.stat_priority
    pub stats: Vec<String>,
    pub score: ScoreBreakdown,
}

#[derive(Debug, Clone)]
pub struct CatalogMiss {
    pub spell_id: String,
    pub error: String,
}

pub fn score_card(
    card: &Card,
    catalog: &Catalog,
    community_db: &CommunityDb,
    stat_effects: &StatEffects,
    klass: &str,
    spec: &str,
    owned: &HashMap<String, i64>,
    ai_context: Option<&AiContext>,
) -> Result<ScoredCard, CatalogMiss> {
    let spell_id = card.spell_id.clone();
    let Some(info) = catalog.get(&spell_id) else {
        return Err(CatalogMiss {
            spell_id: spell_id.clone(),
            error: "not found in perk_catalog.json".to_string(),
        });
    };

    let families: HashSet<&str> = info.families.iter().map(String::as_str).collect();
    let max_stack = info.max_stack;
    let current_stack = *owned.get(&spell_id).unwrap_or(&0);

    let quality_component = (card.quality * 15) as f64;
    // This is deliberately monotonic and fairly conservative. Quality
    // already contributes flat points above; this second signal prevents a
    // Common with generic family/stat tags from looking equal to a genuinely
    // strong high-tier offering. Legendary gets only a small premium because
    // its flat quality component is already large.
    let rarity_multiplier = match card.quality {
        i64::MIN..=-1 => 0.85,
        0 => 0.85, // Common
        1 => 0.90, // Uncommon
        2 => 0.95, // Rare
        3 => 1.00, // Epic
        _ => 1.05, // Legendary or future higher tiers
    };

    // Computed here (ahead of spec_component below) rather than down by
    // downside_component where this used to live, because spec_component
    // now needs stat_priority_component to detect a family/stat mismatch.
    let effects = stat_effects.get(&spell_id);
    let stats_granted = effects.map(|e| e.stats.clone()).unwrap_or_default();
    let priority = stat_priority_for(klass, spec);
    let stat_priority_component: f64 = stats_granted
        .iter()
        .map(|s| *priority.get(s.as_str()).unwrap_or(&0.0))
        .sum();

    let wanted = spec_families(klass, spec);
    let family_match = families.iter().any(|&f| wanted.contains(f));
    // A family tag like "Melee DPS" bundles both Strength- and
    // Agility-scaling classes together, so an echo can match a class's
    // wanted family while granting a stat that class's own
    // stat_priority table rates at zero (e.g. "Agility Boost" tagged
    // generically "Melee DPS" even though pure Agility does nothing for
    // a Strength-scaling Retribution Paladin - confirmed live: it was
    // the 2nd-most-picked echo in early testing purely off this +20
    // plus community_score, despite stat_priority correctly scoring it
    // 0). Only suppress the family bonus when the echo actually grants a
    // plain stat and none of those stats have ANY priority weight for
    // this class/spec - an ability/proc with no `stats` entry at all
    // still gets full family credit, since there's no stat mismatch to
    // detect for those.
    let stat_mismatch = !stats_granted.is_empty() && stat_priority_component == 0.0;
    let spec_component = if family_match && !stat_mismatch {
        20.0
    } else if families.contains("Survivability") {
        8.0
    } else {
        0.0
    };

    let ownership_component = if max_stack <= 1 {
        if current_stack >= 1 {
            -100.0
        } else {
            0.0
        }
    } else if current_stack >= max_stack {
        -100.0
    } else {
        // First copy receives the full novelty bonus. Repeated copies then
        // get a quadratic opportunity-cost penalty: stack 2 is only a light
        // warning, while offers for stack 3/4 become progressively hard to
        // justify unless the Echo is exceptional. The future model can learn
        // exceptions from fight-linked build snapshots.
        let novelty = (1.0 - current_stack as f64 / max_stack as f64) * 10.0;
        let repeats_after_first = (current_stack - 1).max(0) as f64;
        round1(novelty - 2.0 * repeats_after_first.powi(2))
    };

    let community = community_entry(community_db, klass, &spell_id, info.group_id);
    let community_component = community.map(|c| round1(c.score * 0.15)).unwrap_or(0.0);

    let downsides = effects.map(|e| e.downsides.clone()).unwrap_or_default();
    let downside_component = DOWNSIDE_PENALTY_PER_CLAUSE * downsides.len() as f64;

    // Rarity discounts upside, never penalties. Multiplying the entire sum
    // would accidentally make duplicate/downside penalties weaker on a
    // Common card, exactly the opposite of the intended behavior.
    let positive = quality_component
        + spec_component
        + community_component
        + stat_priority_component
        + ownership_component.max(0.0);
    let penalties = downside_component + ownership_component.min(0.0);
    let heuristic_total = positive * rarity_multiplier + penalties;

    let quality_name_str = quality_name(card.quality);

    // Only used in "ai" score-mode (see main.rs's score-mode command)
    // and only for the exact class/spec the ensemble was actually trained
    // on - everything else silently gets ai_z=None/ai_component=0.0 and
    // total falls back to the pure heuristic, same as "normal" mode.
    let (ai_z, ai_component) = match ai_context {
        Some(ctx) if ctx.ensemble.applies_to(klass, spec) => {
            let input = ai::AiInput {
                quality_name: &quality_name_str,
                frozen: card.frozen,
                carried: card.carried,
                guaranteed: card.guaranteed,
                owned_fraction: if max_stack > 0 {
                    current_stack as f32 / max_stack as f32
                } else {
                    0.0
                },
                quality_score: quality_component,
                rarity_multiplier,
                spec_fit: spec_component,
                ownership: ownership_component,
                community: community_component,
                downside: downside_component,
                stat_priority: stat_priority_component,
                heuristic_total,
                level: ctx.level,
                tier: ctx.tier,
                prestige: ctx.prestige,
                ash_bonus_pct: ctx.ash_bonus_pct,
                hero_stats: ctx.hero_stats,
            };
            match ctx.ensemble.predict_z(&input) {
                Some(z) => (Some(z as f64), z as f64 * AI_WEIGHT),
                None => (None, 0.0),
            }
        }
        _ => (None, 0.0),
    };
    let total = heuristic_total + ai_component;

    let mut families_sorted: Vec<String> = info.families.clone();
    families_sorted.sort();
    if families_sorted.is_empty() {
        families_sorted = vec!["(none)".to_string()];
    }

    Ok(ScoredCard {
        index0: card.index0,
        spell_id,
        name: info
            .comment
            .as_deref()
            .map(crate::catalog::display_name)
            .unwrap_or("?")
            .to_string(),
        quality_name: quality_name_str,
        families: families_sorted,
        frozen: card.frozen,
        carried: card.carried,
        guaranteed: card.guaranteed,
        owned: format!("{current_stack}/{max_stack}"),
        downsides,
        stats: stats_granted,
        score: ScoreBreakdown {
            quality: quality_component,
            rarity_multiplier,
            spec_fit: spec_component,
            ownership: ownership_component,
            community: community_component,
            downside: downside_component,
            stat_priority: stat_priority_component,
            ai_z,
            ai_component: round1(ai_component),
            total: round1(total),
        },
    })
}
