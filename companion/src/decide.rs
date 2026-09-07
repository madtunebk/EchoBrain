//! The take/reroll/banish/freeze decision engine. Ported from
//! tools/live/score_echo_board.py's bracket_for()/group_allocation()/
//! decide() - same 5-step priority order, same integer-percent math.
//!
//! Two behaviors here were bugs found and fixed live in the Python original
//! this session, ported in already-fixed:
//!   1. An empty `scored` list (every offered card a catalog miss) returns
//!      TAKE with target=None - callers MUST check for that before treating
//!      target as present (echo_autopilot.py used to crash here).
//!   2. FREEZE is capped at SIMULTANEOUS_FREEZE_CAP already-frozen cards on
//!      the board - the server accepts at most ~2 simultaneous freezes even
//!      though the client-side call has no such check, and a 3rd request
//!      silently no-ops, stalling a caller that only re-decides once the
//!      board string changes.

use crate::board::Charges;
use crate::scoring::{CatalogMiss, ScoredCard};
use serde::Deserialize;

#[derive(Debug, Clone)]
pub struct Bracket {
    pub name: String,
    pub reserve_pct: i64,
    pub take_threshold: i64,
}

// Level-bracket reserve schedule, reused from the old EchoBrain addon's
// already live-tested ResourceBudget.lua. Integer percent (not a float
// fraction) so the budget math below stays exact integer arithmetic. These
// are DEFAULTS only now - see DecideConfig below, which a
// data/decide_config.json can override without a recompile (TODO item:
// "tune take_threshold (55/45/35), the banish score cutoff (<15), and
// FREEZE_PROTECT_FRACTION (0.8) against real play" - this is exactly what
// made that tunable).
const DEFAULT_BRACKETS: [(i64, &str, i64, i64); 4] = [
    (21, "LOCKED", 100, 999), // reserve=100% -> reroll budget is always 0, so this always forces TAKE
    (49, "SPARING", 80, 55),
    (70, "MODERATE", 60, 45),
    (80, "OPEN", 25, 35),
];

const DEFAULT_FREEZE_PROTECT_FRACTION: f64 = 0.8;
const DEFAULT_SIMULTANEOUS_FREEZE_CAP: i64 = 2;
const DEFAULT_JUNK_SCORE_CUTOFF: f64 = 15.0;

#[derive(Debug, Clone, Deserialize)]
pub struct BracketConfig {
    pub max_level: i64,
    pub name: String,
    pub reserve_pct: i64,
    pub take_threshold: i64,
}

/// Everything decide() tunes, loadable from data/decide_config.json so
/// these can be adjusted against real play without a recompile. Any field
/// (or the whole file) missing falls back to the exact defaults that used
/// to be hardcoded consts - `DecideConfig::default()` reproduces the
/// original behavior byte-for-byte.
#[derive(Debug, Clone, Deserialize)]
#[serde(default)]
pub struct DecideConfig {
    pub brackets: Vec<BracketConfig>,
    pub freeze_protect_fraction: f64,
    pub simultaneous_freeze_cap: i64,
    pub junk_score_cutoff: f64,
}

impl Default for DecideConfig {
    fn default() -> Self {
        DecideConfig {
            brackets: DEFAULT_BRACKETS
                .iter()
                .map(
                    |(max_level, name, reserve_pct, take_threshold)| BracketConfig {
                        max_level: *max_level,
                        name: name.to_string(),
                        reserve_pct: *reserve_pct,
                        take_threshold: *take_threshold,
                    },
                )
                .collect(),
            freeze_protect_fraction: DEFAULT_FREEZE_PROTECT_FRACTION,
            simultaneous_freeze_cap: DEFAULT_SIMULTANEOUS_FREEZE_CAP,
            junk_score_cutoff: DEFAULT_JUNK_SCORE_CUTOFF,
        }
    }
}

/// Loads data/decide_config.json if present; missing file (the common case
/// - nobody has to create one) or a parse error both fall back to
/// DecideConfig::default() with a one-line log, never a hard failure - a
/// typo'd tuning file must never stop the whole autopilot from starting.
pub fn load_config(path: &std::path::Path) -> DecideConfig {
    match std::fs::read_to_string(path) {
        Ok(text) => match serde_json::from_str(&text) {
            Ok(cfg) => {
                println!("[decide] loaded tuning overrides from {}", path.display());
                cfg
            }
            Err(e) => {
                println!(
                    "[decide] {} failed to parse ({e}), using defaults",
                    path.display()
                );
                DecideConfig::default()
            }
        },
        Err(_) => DecideConfig::default(),
    }
}

pub fn bracket_for(level: i64, config: &DecideConfig) -> Bracket {
    for b in &config.brackets {
        if level <= b.max_level {
            return Bracket {
                name: b.name.clone(),
                reserve_pct: b.reserve_pct,
                take_threshold: b.take_threshold,
            };
        }
    }
    // Same fallback the old hardcoded version had if every bracket's
    // max_level is somehow below the given level (e.g. a hand-edited config
    // missing the final OPEN-style entry).
    config
        .brackets
        .last()
        .map(|b| Bracket {
            name: b.name.clone(),
            reserve_pct: b.reserve_pct,
            take_threshold: b.take_threshold,
        })
        .unwrap_or(Bracket {
            name: "OPEN".to_string(),
            reserve_pct: 40,
            take_threshold: 35,
        })
}

const LEVEL_GROUPS: [i64; 4] = [20, 40, 60, 80]; // upper bound (inclusive) of each group

fn group_allocation_pct(resource: &str) -> [i64; 4] {
    match resource {
        // Early offers are plentiful and generally lower-value; preserve
        // half of these board-changing resources for levels 61-80 where a
        // bad forced pick is much more expensive to the finished build.
        "reroll" | "banish" => [10, 15, 25, 50],
        // Freeze preserves a good card rather than destroying the board, so
        // it can remain more evenly available through the run.
        "freeze" => [20, 25, 25, 30],
        other => unreachable!("unknown resource {other}"),
    }
}

fn group_index_for(level: i64) -> usize {
    for (i, &upper) in LEVEL_GROUPS.iter().enumerate() {
        if level <= upper {
            return i;
        }
    }
    LEVEL_GROUPS.len() - 1
}

/// (lower_exclusive, upper_inclusive) level bounds of level's group.
pub fn group_range(level: i64) -> (i64, i64) {
    let i = group_index_for(level);
    let lower = if i > 0 { LEVEL_GROUPS[i - 1] } else { 0 };
    (lower, LEVEL_GROUPS[i])
}

/// This group's fixed slice of `total`, using GROUP_ALLOCATION_PCT -
/// integer percent math, remainder folded into the last group so the four
/// slices always sum to exactly `total`, never more.
pub fn group_allocation(total: i64, resource: &str, level: i64) -> i64 {
    let pcts = group_allocation_pct(resource);
    let i = group_index_for(level);
    if i == pcts.len() - 1 {
        let spent_by_earlier: i64 = pcts[..pcts.len() - 1].iter().map(|p| total * p / 100).sum();
        total - spent_by_earlier
    } else {
        total * pcts[i] / 100
    }
}

/// Total amount unlocked through the current 20-level group. Unlike action
/// rows in session.db, this can be compared directly with the game's live
/// used counters, so assisted-manual clicks and process restarts cannot
/// bypass resource rationing.
pub fn cumulative_group_allocation(total: i64, resource: &str, level: i64) -> i64 {
    let current = group_index_for(level);
    (0..=current)
        .map(|i| group_allocation(total, resource, LEVEL_GROUPS[i]))
        .sum()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cumulative_budget_accounts_for_earlier_groups() {
        assert_eq!(group_allocation(19, "reroll", 20), 1);
        assert_eq!(cumulative_group_allocation(19, "reroll", 20), 1);
        assert_eq!(cumulative_group_allocation(19, "reroll", 40), 3);
        assert_eq!(cumulative_group_allocation(19, "reroll", 60), 7);
        assert_eq!(cumulative_group_allocation(19, "reroll", 80), 19);
    }

    #[test]
    fn freeze_keeps_a_more_even_schedule() {
        assert_eq!(cumulative_group_allocation(9, "freeze", 20), 1);
        assert_eq!(cumulative_group_allocation(9, "freeze", 40), 3);
        assert_eq!(cumulative_group_allocation(9, "freeze", 60), 5);
        assert_eq!(cumulative_group_allocation(9, "freeze", 80), 9);
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Action {
    Take,
    Reroll,
    Banish,
    Freeze,
}

impl Action {
    pub fn as_str(&self) -> &'static str {
        match self {
            Action::Take => "TAKE",
            Action::Reroll => "REROLL",
            Action::Banish => "BANISH",
            Action::Freeze => "FREEZE",
        }
    }
}

#[derive(Debug, Clone)]
pub struct Decision {
    pub action: Action,
    /// None only for REROLL (no single card target) and for the
    /// "no scoreable cards" TAKE fallback - callers must check before use.
    pub target: Option<ScoredCard>,
    pub reasons: Vec<String>,
}

/// Bypasses the normal priority order entirely: just TAKE whatever scored
/// highest. For breaking out of a stuck retry loop (see autopilot.rs's
/// MAX_STUCK_RETRIES) where the same FREEZE/BANISH keeps timing out - a
/// documented client-side failure mode (a stuck pending*Index flag) that a
/// same-action retry can never fix, since it silently no-ops regardless of
/// how many times it's resent. TAKE always resolves the board (no
/// pending-flag guard on the client side for it), so it's the one action
/// guaranteed to make progress instead of looping forever.
pub fn force_take_best(results: &[Result<ScoredCard, CatalogMiss>]) -> Decision {
    let best = results
        .iter()
        .filter_map(|r| r.as_ref().ok())
        .max_by(|a, b| a.score.total.partial_cmp(&b.score.total).unwrap());
    match best {
        Some(card) => Decision {
            action: Action::Take,
            target: Some(card.clone()),
            reasons: vec![format!(
                "FORCED TAKE: {} [{}] score={:.1} - repeated FREEZE/BANISH retries kept timing out on this board, taking the best available instead of looping forever",
                card.name, card.spell_id, card.score.total
            )],
        },
        None => Decision {
            action: Action::Take,
            target: None,
            reasons: vec!["FORCED TAKE: no scoreable cards (catalog miss) either - nothing else to do".to_string()],
        },
    }
}

/// Returns exactly ONE next action - a caller re-evaluates after every
/// board change anyway (banish/freeze/take/reroll all change the board).
///
/// Priority:
/// 1. FREEZE a second "keeper" if 2+ cards already meet the take threshold
///    at once (more than one great pick on the same board).
/// 2. TAKE immediately if the best card already clears the take threshold.
/// 3. Otherwise: BANISH the worst card if it's genuinely useless.
/// 4. FREEZE a near-threshold card before rerolling.
/// 5. REROLL if below threshold and budget remains, else TAKE the best
///    available anyway.
pub fn decide(
    results: &[Result<ScoredCard, CatalogMiss>],
    level: i64,
    charges: &Charges,
    config: &DecideConfig,
) -> Decision {
    let mut scored: Vec<&ScoredCard> = results.iter().filter_map(|r| r.as_ref().ok()).collect();
    scored.sort_by(|a, b| b.score.total.partial_cmp(&a.score.total).unwrap());

    if scored.is_empty() {
        return Decision {
            action: Action::Take,
            target: None,
            reasons: vec!["no scoreable cards (catalog miss) - nothing else to do".to_string()],
        };
    }

    let bracket = bracket_for(level, config);
    let mut reroll_remaining = charges.reroll_total - charges.reroll_used;
    let mut freeze_remaining = charges.freeze_total - charges.freeze_used;
    let mut banish_remaining = charges.banish_remaining;

    // Hard per-20-level-group rationing - only applied when the caller
    // supplied it (autopilot.rs fills these in from session.db; a bare
    // `companion score` read does not, since it has no session to ration
    // against). Whichever cap is tighter wins.
    if let Some(g) = charges.reroll_group_left {
        reroll_remaining = reroll_remaining.min(g);
    }
    if let Some(g) = charges.freeze_group_left {
        freeze_remaining = freeze_remaining.min(g);
    }
    if let Some(g) = charges.banish_group_left {
        banish_remaining = banish_remaining.min(g);
    }

    let frozen_on_board = scored.iter().filter(|r| r.frozen).count() as i64;
    freeze_remaining =
        freeze_remaining.min((config.simultaneous_freeze_cap - frozen_on_board).max(0));

    let reroll_budget_now = reroll_remaining * (100 - bracket.reserve_pct) / 100;

    let mut reasons = vec![format!(
        "bracket={} (level {level}) reserve={}% reroll_budget_now={reroll_budget_now}/{reroll_remaining} take_threshold={}",
        bracket.name, bracket.reserve_pct, bracket.take_threshold
    )];
    if let Some(g) = charges.reroll_group_left {
        let (lo, hi) = group_range(level);
        let banish_left = charges
            .banish_group_left
            .map(|v| v.to_string())
            .unwrap_or_else(|| "?".to_string());
        let freeze_left = charges
            .freeze_group_left
            .map(|v| v.to_string())
            .unwrap_or_else(|| "?".to_string());
        reasons.push(format!(
            "group {}-{hi}: reroll_left={g} banish_left={banish_left} freeze_left={freeze_left}",
            lo + 1
        ));
    }

    let freezable = |r: &ScoredCard| !r.frozen && !r.carried;

    // A "keeper" must actually fit the spec - a card that only clears the
    // score threshold via quality/ownership/community with zero
    // spec-family fit is not "the best for this class", it just looks
    // like it numerically.
    let keepers: Vec<&ScoredCard> = scored
        .iter()
        .copied()
        .filter(|r| {
            r.score.total >= bracket.take_threshold as f64 && r.score.spec_fit > 0.0 && freezable(r)
        })
        .collect();

    // Used to also require draws_left >= 1 (freeze needs a later board to
    // redeem the frozen card, and level 80 was assumed to be the last board
    // ever). Confirmed live that assumption is wrong on this server: boards
    // keep being offered indefinitely at level 80 (an hours-long farming
    // session there is normal, not exceptional), so there is always a later
    // board to redeem a level-80 freeze on too - removed the level-80
    // special case entirely.
    if keepers.len() >= 2 && freeze_remaining > 0 {
        let target = keepers[1].clone();
        reasons.push(format!(
            "FREEZE (double-best, protect the second one): {} [{}] score={:.1} - {} cards already clear the take threshold ({freeze_remaining} freeze(s) left)",
            target.name, target.spell_id, target.score.total, keepers.len()
        ));
        return Decision {
            action: Action::Freeze,
            target: Some(target),
            reasons,
        };
    }

    let best = scored[0].clone();
    if best.score.total >= bracket.take_threshold as f64 {
        reasons.push(format!(
            "TAKE: best score {:.1} >= threshold - taking now, skipping banish (the other cards on this board are discarded anyway)",
            best.score.total
        ));
        return Decision {
            action: Action::Take,
            target: Some(best),
            reasons,
        };
    }

    // Never banish something frozen/carried, or a server-guaranteed card.
    // Scan ALL banishable cards for ones that actually qualify as junk
    // first, then pick the worst-scoring one AMONG those - not just the
    // single worst-scoring card overall (that missed off-class cards that
    // happened not to be the absolute lowest scorer).
    let banishable: Vec<&ScoredCard> = scored
        .iter()
        .copied()
        .filter(|r| freezable(r) && !r.guaranteed)
        .collect();
    let junk_candidates: Vec<&ScoredCard> = banishable
        .iter()
        .copied()
        .filter(|r| {
            (r.quality_name == "Common" && r.score.total < config.junk_score_cutoff)
                || r.score.spec_fit == 0.0
        })
        .collect();
    let worst = junk_candidates
        .iter()
        .copied()
        .min_by(|a, b| a.score.total.partial_cmp(&b.score.total).unwrap());

    if let Some(worst) = worst {
        if banish_remaining > 0 {
            let is_white_trash =
                worst.quality_name == "Common" && worst.score.total < config.junk_score_cutoff;
            let why = if is_white_trash {
                "white/Common junk"
            } else {
                "off-class (no spec-family fit)"
            };
            let target = worst.clone();
            reasons.push(format!(
                "BANISH ({why}): {} [{}] score={:.1}, {banish_remaining} banish(es) left this group",
                target.name, target.spell_id, target.score.total
            ));
            return Decision {
                action: Action::Banish,
                target: Some(target),
                reasons,
            };
        }
    }

    let should_reroll = reroll_budget_now > 0;
    if should_reroll {
        // A card doesn't have to clear the FULL take_threshold to be worth
        // protecting before gambling on a reroll - only the LOWER
        // FREEZE_PROTECT_FRACTION bar.
        let protectable: Vec<&ScoredCard> = scored
            .iter()
            .copied()
            .filter(|r| {
                r.score.total >= bracket.take_threshold as f64 * config.freeze_protect_fraction
                    && r.score.spec_fit > 0.0
                    && freezable(r)
            })
            .collect();
        // A protected card can always be redeemed on a later board, level 80
        // included - see the double-keeper branch above for why the old
        // "no later board at 80" gate was removed.
        if !protectable.is_empty() && freeze_remaining > 0 {
            let target = protectable[0].clone();
            reasons.push(format!(
                "FREEZE (protect near-threshold card before reroll gamble): {} [{}] score={:.1} (threshold {}, protect bar {:.0}) ({freeze_remaining} freeze(s) left)",
                target.name,
                target.spell_id,
                target.score.total,
                bracket.take_threshold,
                bracket.take_threshold as f64 * config.freeze_protect_fraction
            ));
            return Decision {
                action: Action::Freeze,
                target: Some(target),
                reasons,
            };
        }

        reasons.push(format!(
            "REROLL: best score {:.1} < threshold, budget available",
            best.score.total
        ));
        return Decision {
            action: Action::Reroll,
            target: None,
            reasons,
        };
    }

    reasons.push(format!(
        "TAKE: best score {:.1} >= threshold, or no eligible/budgeted FREEZE, REROLL, or BANISH remains",
        best.score.total
    ));
    Decision {
        action: Action::Take,
        target: Some(best),
        reasons,
    }
}
