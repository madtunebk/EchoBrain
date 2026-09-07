//! `companion auto` - the continuous watch-and-execute loop. Ported from
//! tools/live/echo_autopilot.py's main()/execute()/apply_group_quota()/
//! parse_fight() - same cadence, same gating, same session-db bookkeeping.

use crate::ai;
use crate::board::{self, Charges};
use crate::bridge::{WowBridge, LUA_CMD_BUDGET};
use crate::catalog::{Catalog, CommunityDb, StatEffects};
use crate::decide::{self, Action, Decision};
use crate::scoring;
use crate::session_db::{self, CharacterProfile, SessionTracker};
use regex::Regex;
use rusqlite::Connection;
use std::collections::HashMap;
use std::path::Path;
use std::sync::OnceLock;
use std::time::{Duration, Instant};

const POLL_INTERVAL: f64 = 1.5;

// How long to wait for the board to actually change after firing an action
// before giving up on it - see PendingAction below. A few poll cycles'
// worth (POLL_INTERVAL=1.5s), generous enough for a normal server
// round-trip, short enough that a genuinely stuck/failed request doesn't
// block real play for long.
const PENDING_TIMEOUT_S: f64 = 4.5;

// How long a role read has to stay ambiguous before the in-game role
// selector actually pops up. GetTalentTabInfo() (read fresh every cycle by
// EchoTracker.lua's PlayerProfile()) can briefly report a tie or zero points
// while talent points are actively being spent (routine on a fast-leveling
// server where every level or two adds another point) - without this grace
// period, a character with no saved role override (profile_role_override)
// would flash the popup on that single bad read and self-clear a cycle
// later once the real distribution settles, annoying but harmless for
// scoring since self.spec only actually changes if the ambiguity persists.
const ROLE_AMBIGUOUS_GRACE_S: f64 = 4.5;

// How much of a level-bracket's unused reroll/banish/freeze allowance can
// carry into the NEXT bracket, as a multiple of that next bracket's own
// slice - see apply_group_quota's doc comment. 1.0 would forfeit every
// unused charge the moment a bracket is crossed (the original behavior,
// punishing fast leveling - e.g. hc5 - that blows through a 20-level group
// before there's time to actually spend its slice); an uncapped carry would
// let someone deliberately hoard every reroll through level 60 and then
// burst-spend the entire run's budget in the last bracket alone. 2.0 is the
// chosen middle ground: recovers most of what fast leveling would otherwise
// waste without enabling a full-run hoard-and-burst.
const GROUP_QUOTA_CARRY_MULTIPLIER: i64 = 2;

// This cap (see bridge.rs's LUA_CMD_BUDGET doc comment for why) is a
// defensive guard here: if it's ever hit, drop the cosmetic notification
// and send the bare action alone instead - the real game action must never
// be silently lost just because a notification string pushed the combined
// payload over budget.

pub struct AutoArgs {
    pub klass: Option<String>,
    pub spec: Option<String>,
    pub api: String,
    /// If supplied by --auto 0/1, publish the desired execution state once
    /// at startup. Afterwards echo_auto remains live-toggleable through the
    /// bridge without restarting this long-running collector.
    pub initial_auto: Option<bool>,
    /// Same idea as `initial_auto`, for `echo_score_mode` (normal|ai) -
    /// see `companion score-mode` for the live-toggle equivalent.
    pub initial_score_mode: Option<String>,
}

/// Long-bracket Lua string literal - avoids quote-escaping issues since
/// echo names/comments can contain apostrophes (e.g. "Crusader's Surge").
fn lua_string(text: &str) -> String {
    format!("[[{}]]", text.replace("]]", "] ]"))
}

struct Fight {
    damage: i64,
    dps: f64,
    duration: f64,
}

/// Parses SimpleDamageMeter's dps_last_fight ("dmg=1234 dps=567
/// duration=2.2s"). None on anything that doesn't match - a stray
/// malformed value should never crash the loop over it.
fn parse_fight(raw: &str) -> Option<Fight> {
    static RE: OnceLock<Regex> = OnceLock::new();
    let re = RE.get_or_init(|| Regex::new(r"^dmg=(\d+)\s+dps=(\d+)\s+duration=([\d.]+)s").unwrap());
    let caps = re.captures(raw)?;
    Some(Fight {
        damage: caps[1].parse().ok()?,
        dps: caps[2].parse().ok()?,
        duration: caps[3].parse().ok()?,
    })
}

/// Adds reroll_group_left/banish_group_left/freeze_group_left to `charges`.
/// The allowance is compared with the game's LIVE used/remaining counters,
/// not only companion-recorded actions, so assisted-manual clicks count too.
/// Banish has no live total; its initial total is retained as a ratcheting
/// session maximum and consumption is derived from total - remaining.
///
/// Also returns the (resource, spent, alloc) triples used to fill
/// *_group_left - previously computed and thrown away, now reported to the
/// bridge by the caller as a burn-rate indicator (feature: "charge-burn-
/// rate isn't visible until it's a problem" - this is what would have made
/// the BANISH-too-early bug from 09-05 obvious immediately instead of only
/// after the fact).
fn apply_group_quota(
    conn: &Connection,
    mut charges: Charges,
    level: i64,
    session_id: i64,
) -> anyhow::Result<(Charges, Vec<(&'static str, i64, i64)>)> {
    let banish_estimate =
        charges.banish_remaining + session_db::actions_spent_total(conn, "BANISH", session_id)?;
    session_db::record_resource_totals(
        conn,
        charges.reroll_total,
        charges.freeze_total,
        banish_estimate,
        session_id,
    )?;
    let totals = session_db::get_session_totals(conn, session_id)?;
    let mut budget = Vec::new();
    for (resource, total, used_live) in [
        ("reroll", totals.reroll_total, Some(charges.reroll_used)),
        (
            "banish",
            totals.banish_total,
            totals
                .banish_total
                .map(|total| (total - charges.banish_remaining).max(0)),
        ),
        ("freeze", totals.freeze_total, Some(charges.freeze_used)),
    ] {
        let Some(total) = total else { continue };
        let alloc = decide::group_allocation(total, resource, level);
        let cumulative = decide::cumulative_group_allocation(total, resource, level);
        let used = used_live.unwrap_or(0);
        // Debt from overspending an earlier group reduces this group's
        // allowance. Unused earlier allowance carries forward, up to
        // GROUP_QUOTA_CARRY_MULTIPLIER times this group's own slice -
        // bounded so a fast-leveling run that blows through a bracket
        // before it can spend that bracket's allotment doesn't just forfeit
        // it, while still stopping a full-run hoard-and-burst.
        let left_now = (cumulative - used).max(0).min(alloc * GROUP_QUOTA_CARRY_MULTIPLIER);
        // Floored at 0 for the burn-rate report only (echo_group_budget) -
        // left_now can now legitimately exceed `alloc` via carry-forward,
        // which would otherwise make this negative. decide() itself uses
        // `left` below, not `spent`, so the real carried-forward budget is
        // never clamped away - only this cosmetic "spent so far" number is.
        let spent = (alloc - left_now).max(0);
        let left = Some(left_now);
        match resource {
            "reroll" => charges.reroll_group_left = left,
            "banish" => charges.banish_group_left = left,
            "freeze" => charges.freeze_group_left = left,
            _ => unreachable!(),
        }
        budget.push((resource, spent, alloc));
    }
    Ok((charges, budget))
}

/// Fires the Lua for `decision` at the client - and ONLY that. Does not
/// touch session_db at all: that used to happen unconditionally right here,
/// immediately after `run_lua()`, with zero confirmation the action ever
/// actually took effect. Found live (09-05) that this is a real gap: the
/// real game's `BanishPerk`/`FreezePerk` client functions each guard on a
/// `pending*Index` flag and silently return `false` (no server request sent
/// at all) if a previous request never got a clearing response - the flag
/// can get stuck (server dropped/rejected the response for whatever
/// reason), and every subsequent banish/freeze attempt then silently no-ops
/// forever while the old code kept recording each one as spent anyway,
/// draining the session's tracked charge budget for actions that never
/// happened. The caller (`State::cycle`) now only calls session_db's
/// record once the board is CONFIRMED to have actually changed - see
/// `PendingAction` below.
///
/// Returns `Ok(true)` if a command was actually sent, `Ok(false)` if this
/// decision has no real target to act on (catalog miss) and nothing was
/// sent at all - the caller should not start tracking a pending action for
/// the latter.
fn send_action(bridge: &WowBridge, decision: &Decision) -> anyhow::Result<bool> {
    let action = decision.action;
    let target = &decision.target;

    // decide() falls back to {action: TAKE, target: None} when every card
    // on the board is a catalog miss - there is nothing to click here.
    // Skip instead of touching a target that doesn't exist.
    if matches!(action, Action::Take | Action::Banish | Action::Freeze) && target.is_none() {
        println!(
            "[autopilot] {} has no target (catalog miss on every offered card) - \
             skipping this board, pick manually or re-run tools/export/export_perk_catalog.py",
            action.as_str()
        );
        return Ok(false);
    }

    // Every one of the real client's Select/Banish/Freeze/Reroll functions
    // (perks_service.lua) guards on its own "pick already in flight" flag
    // (pendingSelectSpellId/pendingBanishIndex/pendingFreezeIndex/
    // pendingReroll) and silently returns false - no server request sent at
    // all - if that flag is already set. Found live (09-05) that this flag
    // can get stuck forever if the server's clearing response never
    // arrives, permanently no-oping every future attempt of that action
    // type for the rest of the session (reproduced even on a completely
    // fresh login). Since `companion` only ever has ONE of its own attempts
    // outstanding at a time (see PendingAction/self.pending), it's always
    // safe to force-clear the flag immediately before every attempt - by
    // definition any earlier attempt from `companion` itself has already
    // been resolved (confirmed or timed out) before a new one is sent.
    // This doesn't just work around a stuck flag reactively, it prevents
    // the whole bug class from ever blocking retries again.
    let (clear_pending, lua) = match action {
        Action::Take => (
            "ProjectEbonhold.Perks.pendingSelectSpellId=nil ",
            format!(
                "ProjectEbonhold.PerkService.SelectPerk({})",
                target.as_ref().unwrap().spell_id
            ),
        ),
        Action::Reroll => (
            "ProjectEbonhold.Perks.pendingReroll=nil ",
            "ProjectEbonhold.PerkService.RequestReroll()".to_string(),
        ),
        Action::Banish => (
            "ProjectEbonhold.Perks.pendingBanishIndex=nil ",
            format!(
                "ProjectEbonhold.PerkService.BanishPerk({})",
                target.as_ref().unwrap().index0
            ),
        ),
        Action::Freeze => (
            "ProjectEbonhold.Perks.pendingFreezeIndex=nil ",
            format!(
                "ProjectEbonhold.PerkService.FreezePerk({})",
                target.as_ref().unwrap().index0
            ),
        ),
    };
    let lua = format!("{clear_pending}{lua}");

    match target {
        Some(t) => println!(
            "[autopilot] EXECUTING {} -> {} [{}]",
            action.as_str(),
            t.name,
            t.spell_id
        ),
        None => println!("[autopilot] EXECUTING {}", action.as_str()),
    }

    let label = target.as_ref().map(|t| t.name.as_str()).unwrap_or("");
    let notify = format!(
        "if EchoTracker_Notify then EchoTracker_Notify(\"{}\", {}) end",
        action.as_str(),
        lua_string(label)
    );
    let mut combined = format!("{lua} {notify}");
    if combined.len() > LUA_CMD_BUDGET {
        println!(
            "[autopilot] WARNING: combined payload {} bytes > {LUA_CMD_BUDGET} budget - dropping notification, sending action alone",
            combined.len()
        );
        combined = lua;
    }
    bridge.run_lua(&combined).map_err(anyhow::Error::msg)?;
    Ok(true)
}

/// An action sent to the client but not yet confirmed - `State::cycle`
/// holds at most one of these at a time (no new action is sent while one is
/// outstanding) and resolves it on a later cycle once the board actually
/// changes (success - record it) or PENDING_TIMEOUT_S passes with no change
/// (treat as failed/dropped - don't record it, let decide() try again).
struct PendingAction {
    board_before: String,
    action: Action,
    spell_id: Option<String>,
    level: i64,
    sent_at: Instant,
    decision_id: i64,
    build_before_id: Option<i64>,
}

struct State {
    klass: String,
    spec: String,
    profile: CharacterProfile,
    class_override: Option<String>,
    cli_role_override: Option<String>,
    decide_config: decide::DecideConfig,
    tracker: SessionTracker,
    pending: Option<PendingAction>,
    last_fight_raw: Option<String>,
    last_suggested_spell: Option<String>,
    last_suggested_action: Option<String>,
    last_reason: Option<String>,
    last_group_budget: Option<String>,
    was_on: bool,
    snapshot_session_id: Option<i64>,
    latest_build_signature: Option<String>,
    latest_build_snapshot_id: Option<i64>,
    latest_stat_signature: Option<String>,
    latest_stat_snapshot_id: Option<i64>,
    observed_board: Option<String>,
    observed_decision_id: Option<i64>,
    waiting_role_guid: Option<String>,
    ambiguous_since: Option<Instant>,
    /// Confirmed TAKE count for the current session - "board N of
    /// BOARDS_PER_FULL_RUN" in the console log. Seeded from session_db (not
    /// reset to 0) whenever the session changes, including a same-session
    /// reattach after a restart - see that call site's comment.
    boards_taken: i64,
    /// (board, action, target spell id) of the last action that timed out,
    /// plus how many CONSECUTIVE times in a row that exact combo has timed
    /// out - resets the moment a different action/board/target is attempted
    /// or one actually succeeds. Confirmed live (09-07): FREEZE (and in
    /// principle BANISH) can get stuck on a server/client-side flag that
    /// makes every subsequent identical request silently no-op forever -
    /// retrying the SAME action can never fix that, only recognizing the
    /// pattern and doing something ELSE can. See MAX_STUCK_RETRIES.
    stuck_signature: Option<(String, String, Option<String>)>,
    stuck_retries: i64,
}

// How many consecutive identical-action timeouts on the same board before
// giving up on that action and forcing a plain TAKE instead (see
// decide::force_take_best). 3 retries * PENDING_TIMEOUT_S (4.5s) is a bit
// over 13 seconds of a completely stuck autopilot before it breaks out -
// long enough to rule out an ordinary one-off server hiccup, short enough
// that a genuinely stuck client flag doesn't stall play indefinitely (the
// observed live failure looped forever with no bound at all).
const MAX_STUCK_RETRIES: i64 = 3;

/// A full 1->80 leveling run offers roughly one board per level, so ~79
/// TAKEs is the typical total for a complete run - used only to give the
/// console log's "board N of BOARDS_PER_FULL_RUN" a human-meaningful
/// denominator, not as a hard limit or a correctness assumption anywhere
/// else (a session that reattaches mid-run, resets prestige, or otherwise
/// starts above level 1 will simply read as "board N of 79" with N already
/// past what a level-1 start would show at the same real progress).
const BOARDS_PER_FULL_RUN: i64 = 79;

fn owned_signature(owned: &HashMap<String, i64>) -> String {
    let mut entries: Vec<_> = owned.iter().collect();
    entries.sort_by(|a, b| a.0.cmp(b.0));
    entries
        .into_iter()
        .map(|(id, count)| format!("{id}:{count}"))
        .collect::<Vec<_>>()
        .join(";")
}

pub(crate) fn parse_hero_stats(raw: &str) -> Option<session_db::HeroStats> {
    let fields: Vec<&str> = raw.split(':').collect();
    if fields.len() != 24 {
        return None;
    }
    let telemetry_version = fields[0].parse().ok()?;
    let mut values = [0.0; 23];
    for (slot, raw_value) in values.iter_mut().zip(fields.iter().skip(1)) {
        *slot = raw_value.parse().ok()?;
    }
    Some(session_db::HeroStats {
        telemetry_version,
        values,
        signature: raw.to_string(),
    })
}

fn consume_role_choice(
    bridge: &WowBridge,
    conn: &Connection,
    profile: &CharacterProfile,
) -> anyhow::Result<Option<String>> {
    let Some(raw) = bridge.get("echo_role_choice").map_err(anyhow::Error::msg)? else {
        return Ok(None);
    };
    let Some((guid, role)) = raw.split_once('\u{1f}') else {
        return Ok(None);
    };
    if guid != profile.guid || !matches!(role, "tank" | "dps" | "heal") {
        return Ok(None);
    }
    session_db::set_profile_role_override(conn, profile, role)?;
    bridge
        .report("echo_role_choice", "")
        .map_err(anyhow::Error::msg)?;
    bridge
        .set("echo_role_request", "")
        .map_err(anyhow::Error::msg)?;
    println!(
        "[autopilot] saved in-game role selection for {}: {}",
        profile.name, role
    );
    Ok(Some(role.to_string()))
}

fn request_role_in_game(bridge: &WowBridge, profile: &CharacterProfile) -> anyhow::Result<()> {
    bridge
        .set(
            "echo_role_request",
            &format!("{}\u{1f}{}", profile.guid, profile.name),
        )
        .map_err(anyhow::Error::msg)
}

impl State {
    fn cycle(
        &mut self,
        bridge: &WowBridge,
        conn: &Connection,
        catalog: &Catalog,
        community_db: &CommunityDb,
        stat_effects: &StatEffects,
        ai_ensemble: Option<&ai::Ensemble>,
    ) -> anyhow::Result<()> {
        if bridge
            .get("bridge_world_connected")
            .map_err(anyhow::Error::msg)?
            .as_deref()
            != Some("1")
        {
            return Ok(());
        }
        if bridge
            .get("echo_in_world")
            .map_err(anyhow::Error::msg)?
            .as_deref()
            != Some("1")
        {
            return Ok(());
        }
        let profile =
            read_profile(bridge)?.ok_or_else(|| anyhow::anyhow!("player profile not ready"))?;
        if profile.guid != self.profile.guid {
            println!(
                "[autopilot] character changed: {} -> {}",
                self.profile.name, profile.name
            );
            self.pending = None;
            self.last_fight_raw = None;
            self.ambiguous_since = None;
            self.klass = self
                .class_override
                .clone()
                .unwrap_or_else(|| profile.class.clone());
        }
        // Refresh on every cycle, not only when talent telemetry changes:
        // `profile set-role` writes SQLite from a separate process and must
        // wake this already-running collector without requiring a restart.
        let in_game_choice = consume_role_choice(bridge, conn, &profile)?;
        self.spec = self
            .cli_role_override
            .clone()
            .or(in_game_choice)
            .or(session_db::profile_role_override(conn, &profile.guid)?)
            .unwrap_or_else(|| profile.role.clone());
        self.profile = profile;
        if !matches!(self.spec.as_str(), "tank" | "dps" | "heal") {
            let ambiguous_for = self
                .ambiguous_since
                .get_or_insert_with(Instant::now)
                .elapsed()
                .as_secs_f64();
            if ambiguous_for >= ROLE_AMBIGUOUS_GRACE_S
                && self.waiting_role_guid.as_deref() != Some(self.profile.guid.as_str())
            {
                println!(
                    "[autopilot] waiting for role selection for {} ({}); choose in game or run `companion profile set-role <tank|dps|heal>`",
                    self.profile.name, self.profile.talent_spec
                );
                request_role_in_game(bridge, &self.profile)?;
                self.waiting_role_guid = Some(self.profile.guid.clone());
            }
            self.pending = None;
            return Ok(());
        }
        self.ambiguous_since = None;
        if self.waiting_role_guid.take().is_some() {
            bridge
                .set("echo_role_request", "")
                .map_err(anyhow::Error::msg)?;
            println!(
                "[autopilot] role resolved for {}: {}; resuming collection",
                self.profile.name, self.spec
            );
        }
        let auto_on = bridge
            .get("echo_auto")
            .map_err(anyhow::Error::msg)?
            .as_deref()
            == Some("on");
        if auto_on != self.was_on {
            println!(
                "[autopilot] echo_auto is now {}",
                if auto_on { "ON" } else { "OFF" }
            );
            self.was_on = auto_on;
        }

        // Fight logging runs regardless of auto_on - build/DPS correlation
        // shouldn't depend on the picker being switched on.
        let level: i64 = bridge
            .get("echo_level")
            .map_err(anyhow::Error::msg)?
            .and_then(|s| s.parse().ok())
            .unwrap_or(1);
        let session_id = self.tracker.ensure(conn, level, &self.profile)?;
        if self.snapshot_session_id != Some(session_id) {
            self.snapshot_session_id = Some(session_id);
            self.latest_build_signature = None;
            self.latest_build_snapshot_id = None;
            self.latest_stat_signature = None;
            self.latest_stat_snapshot_id = None;
            self.observed_board = None;
            self.observed_decision_id = None;
            self.stuck_signature = None;
            self.stuck_retries = 0;
            // Seeded from the real recorded count, not reset to 0 - a
            // restart mid-session reattaching to the SAME session_id must
            // not make the board counter appear to start over.
            self.boards_taken = session_db::actions_spent_total(conn, "TAKE", session_id)?;
        }
        session_db::set_session_class_spec_if_unset(conn, &self.klass, &self.spec, session_id)?;

        if let Some(raw) = bridge.get("hero_stats").map_err(anyhow::Error::msg)? {
            if self.latest_stat_signature.as_deref() != Some(raw.as_str()) {
                if let Some(stats) = parse_hero_stats(&raw) {
                    self.latest_stat_snapshot_id = Some(session_db::record_hero_stats(
                        conn, &stats, level, session_id,
                    )?);
                    self.latest_stat_signature = Some(raw);
                }
            }
        }

        let (locked, locked_ready) = match (
            bridge.get("echo_locked").map_err(anyhow::Error::msg)?,
            bridge.get("echo_locked_max").map_err(anyhow::Error::msg)?,
        ) {
            (Some(raw), Some(max_raw)) => {
                let locked = board::parse_locked(&raw);
                session_db::record_locked(conn, &locked, max_raw.parse().unwrap_or(0), session_id)?;
                (locked, true)
            }
            _ => (Vec::new(), false),
        };
        if !locked_ready {
            return Ok(());
        }

        // Capture immutable build states independently of whether a board is
        // open or auto mode is enabled. This makes the last pick and builds
        // used by fights observable; the old owned_echoes table only kept a
        // mutable final projection and was updated before actions.
        let current_owned = if bridge
            .get("echo_owned_count")
            .map_err(anyhow::Error::msg)?
            .is_some()
        {
            let mut owned = board::fetch_owned(bridge)?;
            // The server stores permanent/account-locked Echoes separately
            // from granted perks. Merge them into the effective build used
            // by duplicate scoring and training snapshots, but use max (not
            // addition) defensively in case a future server version reports
            // the same stack in both APIs.
            for echo in &locked {
                owned
                    .entry(echo.spell_id.clone())
                    .and_modify(|count| *count = (*count).max(echo.count))
                    .or_insert(echo.count);
            }
            let signature = owned_signature(&owned);
            if self.latest_build_signature.as_deref() != Some(&signature) {
                let id = session_db::record_build_snapshot(
                    conn,
                    &owned,
                    level,
                    "telemetry_change",
                    &signature,
                    session_id,
                )?;
                self.latest_build_signature = Some(signature);
                self.latest_build_snapshot_id = Some(id);
            }
            Some(owned)
        } else {
            None
        };

        if let Some(prestiges_raw) = bridge.get("ash_prestiges").map_err(anyhow::Error::msg)? {
            let prestiges: i64 = prestiges_raw.parse().unwrap_or(0);
            let ash_committed: i64 = bridge
                .get("ash_committed")
                .map_err(anyhow::Error::msg)?
                .and_then(|s| s.parse().ok())
                .unwrap_or(0);
            let ash_bonus_pct: f64 = bridge
                .get("ash_bonus_pct")
                .map_err(anyhow::Error::msg)?
                .and_then(|s| s.parse().ok())
                .unwrap_or(0.0);
            session_db::record_prestige_state(
                conn,
                prestiges,
                ash_committed,
                ash_bonus_pct,
                session_id,
            )?;
        }

        if let Some(tier_raw) = bridge.get("hardmode_tier").map_err(anyhow::Error::msg)? {
            session_db::record_hardmode_tier(conn, tier_raw.parse().unwrap_or(0), session_id)?;
        }

        if let Some(soul_points_raw) = bridge.get("soul_points").map_err(anyhow::Error::msg)? {
            let points: i64 = soul_points_raw.parse().unwrap_or(0);
            let points_max: i64 = bridge
                .get("soul_points_max")
                .map_err(anyhow::Error::msg)?
                .and_then(|s| s.parse().ok())
                .unwrap_or(0);
            session_db::record_soul_points(conn, points, points_max, session_id)?;
        }

        if let Some(raw) = bridge.get("dps_last_fight").map_err(anyhow::Error::msg)? {
            if !raw.is_empty() && Some(raw.as_str()) != self.last_fight_raw.as_deref() {
                if let Some(fight) = parse_fight(&raw) {
                    session_db::record_fight(
                        conn,
                        fight.damage,
                        fight.dps,
                        fight.duration,
                        level,
                        session_id,
                        self.latest_build_snapshot_id,
                        self.latest_stat_snapshot_id,
                    )?;
                    println!(
                        "[autopilot] fight logged: dmg={} dps={:.0} dur={:.1}s",
                        fight.damage, fight.dps, fight.duration
                    );
                }
                self.last_fight_raw = Some(raw);
            }
        }

        // Charges + group-quota computed every cycle now, regardless of
        // whether a board is currently offered - previously only ran inside
        // the board branch below, so the burn-rate report (echo_group_budget)
        // would go stale/blank the moment the board disappeared, even though
        // the underlying budget is a persistent per-session stat, not
        // something tied to any one board.
        let charges_raw = bridge
            .get("echo_charges")
            .map_err(anyhow::Error::msg)?
            .unwrap_or_default();
        let charges = board::parse_charges(&charges_raw);
        let (charges, budget) = apply_group_quota(conn, charges, level, session_id)?;
        let charges_json = serde_json::json!({
            "raw": charges_raw,
            "reroll_used": charges.reroll_used,
            "reroll_total": charges.reroll_total,
            "banish_remaining": charges.banish_remaining,
            "freeze_used": charges.freeze_used,
            "freeze_total": charges.freeze_total,
            "reroll_group_left": charges.reroll_group_left,
            "banish_group_left": charges.banish_group_left,
            "freeze_group_left": charges.freeze_group_left
        })
        .to_string();

        let (group_lo, group_hi) = decide::group_range(level);
        let budget_str = budget
            .iter()
            .map(|(r, spent, alloc)| format!("{r}:{spent}/{alloc}"))
            .collect::<Vec<_>>()
            .join(";");
        let group_budget_report = format!("{}-{}|{}", group_lo + 1, group_hi, budget_str);
        if !budget.is_empty() && Some(&group_budget_report) != self.last_group_budget.as_ref() {
            bridge
                .report("echo_group_budget", &group_budget_report)
                .map_err(anyhow::Error::msg)?;
            self.last_group_budget = Some(group_budget_report);
        }

        // Suggestion computed and reported regardless of auto_on, so
        // EchoTracker can show an advisory glow on the recommended card
        // even with auto off. Uses the exact same score_card/decide() the
        // autopilot itself would act on - computed once and reused below
        // for the actual execution too.
        let board_raw = bridge.get("echo_board").map_err(anyhow::Error::msg)?;
        let board_present = board_raw.as_deref().filter(|s| !s.is_empty());

        // Resolve any outstanding action before the board-observation logic
        // below decides whether this board needs a new decision_events row.
        // Must run BEFORE that check, not after: it's the only thing that
        // clears self.observed_board/self.observed_decision_id when a
        // pending action times out on an otherwise-unchanged board. Doing it
        // after (as this used to) meant a same-cycle retry send would find
        // observed_decision_id already nulled with no fresh row recorded to
        // replace it (the observation check above only fires on a board
        // STRING change, and a timeout by definition means the board string
        // didn't change) - `mark_decision_sent` then had nothing to write
        // to and the whole cycle errored out ("missing decision event for
        // current board"), silently dropping that retry's tracking (the
        // resend itself still reached the game) instead of wrapping it in a
        // fresh PendingAction.
        //
        // See PendingAction's doc comment for why this confirm/timeout
        // dance exists at all (found live: the real client's
        // BanishPerk/FreezePerk silently no-op if a previous request's
        // pending flag never got cleared, and the old code recorded every
        // attempt as spent regardless of whether it actually took effect).
        let mut force_take = false;
        if auto_on {
            if let Some(pending) = self.pending.take() {
                let current_board = board_raw.as_deref().unwrap_or("");
                if current_board != pending.board_before {
                    // A real success - whatever stuck streak was building
                    // is over.
                    self.stuck_signature = None;
                    self.stuck_retries = 0;
                    println!(
                        "[autopilot] CONFIRMED {} (board changed) - recording",
                        pending.action.as_str()
                    );
                    if pending.action == Action::Take {
                        self.boards_taken += 1;
                        println!(
                            "[autopilot] board {} of {BOARDS_PER_FULL_RUN} taken (level {})",
                            self.boards_taken, pending.level
                        );
                    }
                    session_db::record_action(
                        conn,
                        pending.action.as_str(),
                        pending.spell_id.as_deref(),
                        pending.level,
                        &pending.board_before,
                        session_id,
                    )?;
                    session_db::resolve_decision(
                        conn,
                        pending.decision_id,
                        "confirmed",
                        if pending.action == Action::Take {
                            self.latest_build_snapshot_id
                                .filter(|id| Some(*id) != pending.build_before_id)
                        } else {
                            self.latest_build_snapshot_id
                        },
                    )?;
                } else if pending.sent_at.elapsed().as_secs_f64() > PENDING_TIMEOUT_S {
                    println!(
                        "[autopilot] {} never took effect after {PENDING_TIMEOUT_S}s (board unchanged) - \
                         NOT recording it as spent, will retry",
                        pending.action.as_str()
                    );
                    session_db::resolve_decision(
                        conn,
                        pending.decision_id,
                        "timed_out",
                        self.latest_build_snapshot_id,
                    )?;
                    self.observed_board = None;
                    self.observed_decision_id = None;

                    let signature = (
                        pending.board_before.clone(),
                        pending.action.as_str().to_string(),
                        pending.spell_id.clone(),
                    );
                    if self.stuck_signature.as_ref() == Some(&signature) {
                        self.stuck_retries += 1;
                    } else {
                        self.stuck_signature = Some(signature);
                        self.stuck_retries = 1;
                    }
                    if self.stuck_retries >= MAX_STUCK_RETRIES {
                        println!(
                            "[autopilot] {} has now timed out {} times in a row on this exact board \
                             - likely a stuck client-side pending flag a same-action retry can never \
                             fix on its own. Forcing a plain TAKE of the best card instead to break out.",
                            pending.action.as_str(),
                            self.stuck_retries
                        );
                        force_take = true;
                        self.stuck_signature = None;
                        self.stuck_retries = 0;
                    }
                } else {
                    // Still within the confirmation window - keep waiting,
                    // don't fire a new action this cycle.
                    self.pending = Some(pending);
                }
            }
        }

        let mut decision: Option<Decision> = None;
        let mut owned: Option<HashMap<String, i64>> = None;

        if let Some(board) = board_present {
            let owned_map = current_owned.clone().unwrap_or_else(HashMap::new);
            let cards = board::parse_board(board);

            // Live-toggleable, checked fresh every cycle (same pattern as
            // echo_auto) - `companion score-mode ai|normal` flips this
            // without restarting `auto`. Only actually blends the AI signal
            // when an ensemble is loaded AND it applies to this class/spec
            // (see AiContext/score_card in scoring.rs) - anything else
            // silently behaves exactly like "normal" mode.
            let score_mode = bridge
                .get("echo_score_mode")
                .ok()
                .flatten()
                .unwrap_or_else(|| "normal".to_string());
            let hero_stats_values: Option<[f64; 23]> = bridge
                .get("hero_stats")
                .ok()
                .flatten()
                .and_then(|raw| parse_hero_stats(&raw))
                .map(|s| s.values);
            // Confirmed live (09-07): defaulting a failed tier/prestige/ash
            // read to 0 via unwrap_or is actively dangerous, not just
            // "slightly stale" - a single transient bridge-read miss on any
            // one of these fed the model a real=75/read-as-0 prestige (or
            // similar), swinging every card's ai_z on the board by ~19
            // points inside one cycle even though nothing in the game
            // actually changed (same board, identical heuristic scores,
            // identical hero_stats). That instability is what let the
            // autopilot abandon a card it had just frozen two seconds
            // earlier. hero_stats alone is still allowed to gracefully be
            // None - the model was explicitly trained with a
            // stats_available flag for that case - but tier/prestige/ash
            // have no such "unavailable" signal, so a failed read for any
            // of them now skips the AI blend for this cycle entirely
            // (falls back to pure heuristic) instead of guessing a value
            // that can actively mislead the model.
            let ai_context = if score_mode == "ai" {
                let tier: Option<i64> = bridge
                    .get("hardmode_tier")
                    .ok()
                    .flatten()
                    .and_then(|s| s.parse().ok());
                let prestige: Option<i64> = bridge
                    .get("ash_prestiges")
                    .ok()
                    .flatten()
                    .and_then(|s| s.parse().ok());
                let ash_bonus_pct: Option<f64> = bridge
                    .get("ash_bonus_pct")
                    .ok()
                    .flatten()
                    .and_then(|s| s.parse().ok());
                match (ai_ensemble, tier, prestige, ash_bonus_pct) {
                    (Some(ensemble), Some(tier), Some(prestige), Some(ash_bonus_pct)) => {
                        Some(scoring::AiContext {
                            ensemble,
                            level,
                            tier,
                            prestige,
                            ash_bonus_pct,
                            hero_stats: hero_stats_values.as_ref(),
                        })
                    }
                    _ => None,
                }
            } else {
                None
            };

            let results: Vec<_> = cards
                .iter()
                .map(|c| {
                    scoring::score_card(
                        c,
                        catalog,
                        community_db,
                        stat_effects,
                        &self.klass,
                        &self.spec,
                        &owned_map,
                        ai_context.as_ref(),
                    )
                })
                .collect();
            let decision_scores_json = serde_json::Value::Array(results.iter().map(|result| match result {
                Ok(r) => serde_json::json!({
                    "slot": r.index0,
                    "spell_id": r.spell_id,
                    "name": r.name,
                    "quality": r.quality_name,
                    "families": r.families,
                    "flags": {"frozen": r.frozen, "carried": r.carried, "guaranteed": r.guaranteed},
                    "owned": r.owned,
                    "downsides": r.downsides,
                    "stats": r.stats,
                    "score": {
                        "quality": r.score.quality, "rarity_multiplier": r.score.rarity_multiplier,
                        "spec_fit": r.score.spec_fit,
                        "ownership": r.score.ownership, "community": r.score.community,
                        "downside": r.score.downside, "stat_priority": r.score.stat_priority,
                        "ai_z": r.score.ai_z, "ai_component": r.score.ai_component,
                        "total": r.score.total
                    }
                }),
                Err(miss) => serde_json::json!({"spell_id": miss.spell_id, "error": miss.error}),
            }).collect()).to_string();
            let d = if force_take {
                decide::force_take_best(&results)
            } else {
                decide::decide(&results, level, &charges, &self.decide_config)
            };

            // One immutable training row for every board observed, even when
            // auto mode is off. If automation later acts on this board the
            // same row moves observed -> sent -> confirmed/timed_out.
            if self.observed_board.as_deref() != Some(board) {
                let reasons_json = serde_json::to_string(&d.reasons)?;
                let record = session_db::DecisionRecord {
                    session_id,
                    level,
                    board,
                    action: d.action.as_str(),
                    target_spell_id: d.target.as_ref().map(|t| t.spell_id.as_str()),
                    reasons_json: &reasons_json,
                    scores_json: &decision_scores_json,
                    charges_json: &charges_json,
                    build_before_id: self.latest_build_snapshot_id,
                    stats_before_id: self.latest_stat_snapshot_id,
                    status: "observed",
                };
                self.observed_decision_id = Some(session_db::record_decision(conn, &record)?);
                self.observed_board = Some(board.to_string());
            }

            let suggested_spell = d
                .target
                .as_ref()
                .map(|t| t.spell_id.clone())
                .unwrap_or_default();
            let suggested_action = d.action.as_str().to_string();
            if Some(&suggested_spell) != self.last_suggested_spell.as_ref()
                || Some(&suggested_action) != self.last_suggested_action.as_ref()
            {
                bridge
                    .set("echo_suggested", &suggested_spell)
                    .map_err(anyhow::Error::msg)?;
                bridge
                    .set("echo_suggested_action", &suggested_action)
                    .map_err(anyhow::Error::msg)?;
                self.last_suggested_spell = Some(suggested_spell);
                self.last_suggested_action = Some(suggested_action);
            }

            // Feature: decision reasoning visible somewhere other than
            // console output that scrolls away - reported through the
            // bridge (no addon-message byte budget at all here; this is a
            // direct HTTP write straight into wow_bridge's variable store,
            // read by FlaskGUI's /api/stream same as everything else) so it
            // survives on the dashboard, and printed to console whenever it
            // actually changes (not gated on auto_on/execution - a manual
            // player deserves to see WHY just as much as an unattended one).
            let reason_text = d.reasons.join(" | ");
            if Some(&reason_text) != self.last_reason.as_ref() {
                for reason in &d.reasons {
                    println!("[autopilot]   {reason}");
                }
                bridge
                    .report("echo_reason", &reason_text)
                    .map_err(anyhow::Error::msg)?;
                self.last_reason = Some(reason_text);
            }

            owned = Some(owned_map);
            decision = Some(d);
        } else if self.last_suggested_spell.is_some() || self.last_suggested_action.is_some() {
            bridge
                .set("echo_suggested", "")
                .map_err(anyhow::Error::msg)?;
            bridge
                .set("echo_suggested_action", "")
                .map_err(anyhow::Error::msg)?;
            bridge
                .report("echo_reason", "")
                .map_err(anyhow::Error::msg)?;
            self.last_suggested_spell = None;
            self.last_suggested_action = None;
            self.last_reason = None;
            self.observed_board = None;
            self.observed_decision_id = None;
        }

        if auto_on {
            if self.pending.is_none() {
                if let Some(board) = board_present {
                    let decision = decision
                        .as_ref()
                        .expect("decision computed whenever a board is present");
                    if let Some(owned_map) = &owned {
                        session_db::record_owned(conn, owned_map, session_id)?;
                    }
                    // Reasons already printed above (whenever the reason
                    // text changed) - not reprinted here to avoid double
                    // console spam for the exact same decision.
                    if send_action(bridge, decision)? {
                        let decision_id = self.observed_decision_id.ok_or_else(|| {
                            anyhow::anyhow!("missing decision event for current board")
                        })?;
                        session_db::mark_decision_sent(conn, decision_id)?;
                        self.pending = Some(PendingAction {
                            board_before: board.to_string(),
                            action: decision.action,
                            spell_id: decision.target.as_ref().map(|t| t.spell_id.clone()),
                            level,
                            sent_at: Instant::now(),
                            decision_id,
                            build_before_id: self.latest_build_snapshot_id,
                        });
                    }
                }
            }
        }

        Ok(())
    }
}

pub(crate) fn read_profile(bridge: &WowBridge) -> anyhow::Result<Option<CharacterProfile>> {
    let Some(raw) = bridge.get("echo_profile").map_err(anyhow::Error::msg)? else {
        return Ok(None);
    };
    let fields: Vec<&str> = raw.split('\x1f').collect();
    if fields.len() != 8 || fields[0].is_empty() || fields[1].is_empty() || fields[3].is_empty() {
        return Ok(None);
    }
    Ok(Some(CharacterProfile {
        guid: fields[0].to_string(),
        name: fields[1].to_string(),
        realm: fields[2].to_string(),
        class: fields[3].to_string(),
        race: fields[4].to_string(),
        faction: fields[5].to_string(),
        talent_spec: fields[6].to_string(),
        role: fields[7].to_string(),
    }))
}

pub fn run(args: AutoArgs) -> anyhow::Result<()> {
    let catalog: Catalog = crate::catalog::load_json(Path::new("data/perk_catalog.json"))?;
    let community_db: CommunityDb = crate::catalog::load_json(Path::new("data/community_db.json"))?;
    let stat_effects: StatEffects =
        crate::catalog::load_json_optional(Path::new("data/echo_stat_effects.json"))?;
    // Opt-in and non-fatal: a missing data/ai_ensemble directory just means
    // "ai" score-mode has nothing to blend in (score_card falls back
    // to pure heuristic scoring either way), and a genuine load error
    // (corrupt safetensors, etc.) shouldn't take down the whole autopilot
    // over what is, by design, an optional nudge on top of the real scorer.
    let ai_ensemble = match ai::Ensemble::load(Path::new("data/ai_ensemble")) {
        Ok(ensemble) => ensemble,
        Err(e) => {
            eprintln!(
                "[autopilot] warning: failed to load data/ai_ensemble ({e}) - \
                 AI-assisted scoring unavailable this run, falling back to normal mode"
            );
            None
        }
    };
    if let Some(ensemble) = &ai_ensemble {
        println!(
            "[autopilot] AI ensemble loaded: {} members, trained for {}/{} - `companion score-mode ai` to enable",
            ensemble.member_count(),
            ensemble.class_filter(),
            ensemble.spec_filter()
        );
    }
    let decide_config = decide::load_config(Path::new("data/decide_config.json"));
    let bridge = WowBridge::new(&args.api);
    let conn = session_db::open(Path::new("data/session.db"))?;

    println!("[autopilot] waiting for PLAYER_ENTERING_WORLD and character profile...");
    let mut waiting_role_guid: Option<String> = None;
    let (initial_profile, klass, spec) = loop {
        let world_connected = bridge
            .get("bridge_world_connected")
            .map_err(anyhow::Error::msg)?
            .as_deref()
            == Some("1");
        let in_world = bridge
            .get("echo_in_world")
            .map_err(anyhow::Error::msg)?
            .as_deref()
            == Some("1");
        if world_connected && in_world {
            if let Some(profile) = read_profile(&bridge)? {
                let in_game_choice = consume_role_choice(&bridge, &conn, &profile)?;
                let klass = args.klass.clone().unwrap_or_else(|| profile.class.clone());
                let spec = args
                    .spec
                    .clone()
                    .or(in_game_choice)
                    .or(session_db::profile_role_override(&conn, &profile.guid)?)
                    .unwrap_or_else(|| profile.role.clone());
                if matches!(spec.as_str(), "tank" | "dps" | "heal") {
                    if waiting_role_guid.is_some() {
                        bridge
                            .set("echo_role_request", "")
                            .map_err(anyhow::Error::msg)?;
                    }
                    break (profile, klass, spec);
                }
                if waiting_role_guid.as_deref() != Some(profile.guid.as_str()) {
                    println!(
                        "[autopilot] waiting for role selection for {} ({}); choose in game or run `companion profile set-role <tank|dps|heal>`",
                        profile.name, profile.talent_spec
                    );
                    request_role_in_game(&bridge, &profile)?;
                    waiting_role_guid = Some(profile.guid.clone());
                }
            }
        }
        std::thread::sleep(Duration::from_secs_f64(POLL_INTERVAL));
    };

    if let Some(enabled) = args.initial_auto {
        let value = if enabled { "on" } else { "off" };
        bridge.set("echo_auto", value).map_err(anyhow::Error::msg)?;
        println!("[autopilot] startup mode: echo_auto={value}");
    }
    if let Some(mode) = &args.initial_score_mode {
        bridge
            .set("echo_score_mode", mode)
            .map_err(anyhow::Error::msg)?;
        println!("[autopilot] startup mode: echo_score_mode={mode}");
    }

    println!(
        "[autopilot] detected {} — {} {} ({}, {}); collecting continuously",
        initial_profile.name, initial_profile.race, klass, initial_profile.talent_spec, spec
    );

    let mut state = State {
        klass,
        spec,
        profile: initial_profile,
        class_override: args.klass,
        cli_role_override: args.spec,
        decide_config,
        tracker: SessionTracker::new(),
        pending: None,
        ambiguous_since: None,
        // Overwritten on the very first cycle by the session-attach block's
        // real seeded value (session_id starts as None-equivalent, so that
        // block always runs at least once) - 0 here is just a placeholder.
        boards_taken: 0,
        stuck_signature: None,
        stuck_retries: 0,
        last_fight_raw: None,
        last_suggested_spell: None,
        last_suggested_action: None,
        last_reason: None,
        last_group_budget: None,
        was_on: false,
        snapshot_session_id: None,
        latest_build_signature: None,
        latest_build_snapshot_id: None,
        latest_stat_signature: None,
        latest_stat_snapshot_id: None,
        observed_board: None,
        observed_decision_id: None,
        waiting_role_guid: None,
    };

    loop {
        // A long-running unattended loop must never die silently on a
        // transient hiccup (wow_bridge restarted, a malformed value from
        // the game, a catalog miss) - log and retry next cycle instead of
        // ever exiting.
        if let Err(e) = state.cycle(
            &bridge,
            &conn,
            &catalog,
            &community_db,
            &stat_effects,
            ai_ensemble.as_ref(),
        ) {
            println!("[autopilot] ERROR this cycle, will retry: {e:?}");
        }
        std::thread::sleep(Duration::from_secs_f64(POLL_INTERVAL));
    }
}
