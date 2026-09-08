//! SQLite persistence for the Echo/perk draft session history - ported from
//! sdk/python/echo_session_db.py. Same schema, same migrations, same file
//! (`data/session.db`) - tools/export/export_build_report.py (still
//! Python, offline analytics only) keeps reading it unmodified.
//!
//! Unlike the Python module's global `_conn`/`_current_session_id`/
//! `_last_level`, the connection is opened once by the caller (`auto`'s
//! entry point) and threaded through explicitly; session/level tracking
//! lives in `SessionTracker` instead of hidden statics. Same behavior,
//! more idiomatic Rust.

use crate::board::LockedEcho;
use anyhow::Result;
use rusqlite::{params, Connection, OptionalExtension};
use std::collections::{HashMap, HashSet};
use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};

const SCHEMA_SQL: &str = "
CREATE TABLE IF NOT EXISTS sessions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    started_at REAL NOT NULL,
    ended_at REAL,
    reroll_total INTEGER,
    freeze_total INTEGER,
    banish_total INTEGER,
    class TEXT,
    spec TEXT,
    prestiges INTEGER,
    ash_committed INTEGER,
    ash_bonus_pct REAL,
    max_permanent_slots INTEGER,
    hardmode_tier INTEGER,
    soul_points INTEGER,
    soul_points_max INTEGER,
    character_guid TEXT,
    character_name TEXT,
    realm TEXT,
    race TEXT,
    faction TEXT,
    talent_spec TEXT,
    profile_source TEXT
);
CREATE TABLE IF NOT EXISTS character_profiles (
    character_guid TEXT PRIMARY KEY,
    character_name TEXT NOT NULL,
    realm TEXT,
    class TEXT NOT NULL,
    race TEXT,
    faction TEXT,
    talent_spec TEXT,
    role TEXT,
    role_override TEXT,
    first_seen_at REAL NOT NULL,
    last_seen_at REAL NOT NULL
);
CREATE TABLE IF NOT EXISTS owned_echoes (
    session_id INTEGER NOT NULL,
    spell_id TEXT NOT NULL,
    count INTEGER NOT NULL,
    updated_at REAL NOT NULL,
    PRIMARY KEY (session_id, spell_id)
);
CREATE TABLE IF NOT EXISTS actions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id INTEGER NOT NULL,
    at REAL NOT NULL,
    action TEXT NOT NULL,
    spell_id TEXT,
    level INTEGER,
    board TEXT
);
CREATE TABLE IF NOT EXISTS board_log (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id INTEGER NOT NULL,
    at REAL NOT NULL,
    level INTEGER,
    board TEXT,
    board_changed INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS locked_echoes (
    session_id INTEGER NOT NULL,
    spell_id TEXT NOT NULL,
    count INTEGER NOT NULL,
    quality INTEGER,
    updated_at REAL NOT NULL,
    PRIMARY KEY (session_id, spell_id)
);
CREATE TABLE IF NOT EXISTS account_locked_echoes (
    spell_id TEXT PRIMARY KEY,
    count INTEGER NOT NULL,
    quality INTEGER,
    updated_at REAL NOT NULL
);
CREATE TABLE IF NOT EXISTS account_echo_state (
    singleton INTEGER PRIMARY KEY CHECK(singleton = 1),
    max_permanent_slots INTEGER NOT NULL,
    updated_at REAL NOT NULL
);
CREATE TABLE IF NOT EXISTS fights (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id INTEGER NOT NULL,
    at REAL NOT NULL,
    level INTEGER,
    damage INTEGER NOT NULL,
    dps REAL NOT NULL,
    duration_s REAL NOT NULL
);
CREATE TABLE IF NOT EXISTS build_snapshots (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id INTEGER NOT NULL,
    at REAL NOT NULL,
    level INTEGER NOT NULL,
    trigger TEXT NOT NULL,
    owned_signature TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS build_snapshot_echoes (
    snapshot_id INTEGER NOT NULL,
    spell_id TEXT NOT NULL,
    count INTEGER NOT NULL,
    PRIMARY KEY (snapshot_id, spell_id)
);
CREATE TABLE IF NOT EXISTS character_stat_snapshots (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id INTEGER NOT NULL,
    at REAL NOT NULL,
    level INTEGER NOT NULL,
    telemetry_version INTEGER NOT NULL,
    strength REAL, agility REAL, stamina REAL, intellect REAL, spirit REAL,
    attack_power REAL, ranged_attack_power REAL, spell_power REAL, healing_power REAL,
    crit_melee REAL, crit_ranged REAL, crit_spell REAL,
    haste_melee REAL, haste_ranged REAL, haste_spell REAL,
    hit_rating REAL, expertise REAL, armor REAL, health_max REAL, mana_max REAL,
    weapon_min REAL, weapon_max REAL, weapon_speed REAL,
    signature TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS decision_events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id INTEGER NOT NULL,
    at REAL NOT NULL,
    level INTEGER NOT NULL,
    board TEXT NOT NULL,
    action TEXT NOT NULL,
    target_spell_id TEXT,
    reasons_json TEXT NOT NULL,
    scores_json TEXT NOT NULL,
    charges_json TEXT NOT NULL,
    build_before_id INTEGER,
    build_after_id INTEGER,
    stats_before_id INTEGER,
    status TEXT NOT NULL,
    confirmed_at REAL
);
CREATE INDEX IF NOT EXISTS idx_build_snapshots_session_at ON build_snapshots(session_id, at);
CREATE INDEX IF NOT EXISTS idx_decision_events_session_at ON decision_events(session_id, at);
CREATE INDEX IF NOT EXISTS idx_fights_session_at ON fights(session_id, at);
CREATE INDEX IF NOT EXISTS idx_stat_snapshots_session_at ON character_stat_snapshots(session_id, at);
CREATE TABLE IF NOT EXISTS app_migrations (
    name TEXT PRIMARY KEY,
    applied_at REAL NOT NULL
);
";

// Migration for session.db files created before these columns existed on
// `sessions` - CREATE TABLE IF NOT EXISTS above doesn't add columns to an
// already-existing table.
const MIGRATION_COLUMNS: &[(&str, &str)] = &[
    ("reroll_total", "INTEGER"),
    ("freeze_total", "INTEGER"),
    ("banish_total", "INTEGER"),
    ("class", "TEXT"),
    ("spec", "TEXT"),
    ("prestiges", "INTEGER"),
    ("ash_committed", "INTEGER"),
    ("ash_bonus_pct", "REAL"),
    ("max_permanent_slots", "INTEGER"),
    ("hardmode_tier", "INTEGER"),
    ("soul_points", "INTEGER"),
    ("soul_points_max", "INTEGER"),
    ("character_guid", "TEXT"),
    ("character_name", "TEXT"),
    ("realm", "TEXT"),
    ("race", "TEXT"),
    ("faction", "TEXT"),
    ("talent_spec", "TEXT"),
    ("profile_source", "TEXT"),
];

pub(crate) fn now() -> f64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs_f64()
}

fn compact_historical_echo_names(conn: &mut Connection) -> Result<bool> {
    const MIGRATION: &str = "compact_echo_class_qualifiers_v1";
    let already_applied: bool = conn.query_row(
        "SELECT EXISTS(SELECT 1 FROM app_migrations WHERE name=?1)",
        [MIGRATION],
        |row| row.get(0),
    )?;
    if already_applied {
        return Ok(false);
    }

    let rows: Vec<(i64, String, String)> = {
        let mut stmt = conn.prepare(
            "SELECT id, reasons_json, scores_json FROM decision_events \
             WHERE reasons_json LIKE '% - %' OR scores_json LIKE '% - %'",
        )?;
        let collected = stmt
            .query_map([], |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)))?
            .collect::<rusqlite::Result<_>>()?;
        collected
    };

    let tx = conn.transaction()?;
    let mut changed = false;
    for (id, reasons, scores) in rows {
        let compact_reasons = crate::catalog::remove_class_qualifiers(&reasons);
        let compact_scores = crate::catalog::remove_class_qualifiers(&scores);
        if compact_reasons != reasons || compact_scores != scores {
            tx.execute(
                "UPDATE decision_events SET reasons_json=?1, scores_json=?2 WHERE id=?3",
                params![compact_reasons, compact_scores, id],
            )?;
            changed = true;
        }
    }
    tx.execute(
        "INSERT INTO app_migrations(name, applied_at) VALUES(?1, ?2)",
        params![MIGRATION, now()],
    )?;
    tx.commit()?;
    Ok(changed)
}

pub fn open(path: &Path) -> Result<Connection> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let mut conn = Connection::open(path)?;
    conn.execute_batch(SCHEMA_SQL)?;

    let existing_cols: HashSet<String> = {
        let mut stmt = conn.prepare("PRAGMA table_info(sessions)")?;
        let cols = stmt
            .query_map([], |row| row.get::<_, String>(1))?
            .collect::<rusqlite::Result<_>>()?;
        cols
    };
    for (col, coltype) in MIGRATION_COLUMNS {
        if !existing_cols.contains(*col) {
            conn.execute(
                &format!("ALTER TABLE sessions ADD COLUMN {col} {coltype}"),
                [],
            )?;
        }
    }
    let profile_cols: HashSet<String> = {
        let mut stmt = conn.prepare("PRAGMA table_info(character_profiles)")?;
        let cols = stmt
            .query_map([], |row| row.get::<_, String>(1))?
            .collect::<rusqlite::Result<_>>()?;
        cols
    };
    if !profile_cols.contains("role_override") {
        conn.execute(
            "ALTER TABLE character_profiles ADD COLUMN role_override TEXT",
            [],
        )?;
    }
    let fight_cols: HashSet<String> = {
        let mut stmt = conn.prepare("PRAGMA table_info(fights)")?;
        let cols = stmt
            .query_map([], |row| row.get::<_, String>(1))?
            .collect::<rusqlite::Result<_>>()?;
        cols
    };
    if !fight_cols.contains("build_snapshot_id") {
        conn.execute(
            "ALTER TABLE fights ADD COLUMN build_snapshot_id INTEGER",
            [],
        )?;
    }
    if !fight_cols.contains("stat_snapshot_id") {
        conn.execute("ALTER TABLE fights ADD COLUMN stat_snapshot_id INTEGER", [])?;
    }
    let decision_cols: HashSet<String> = {
        let mut stmt = conn.prepare("PRAGMA table_info(decision_events)")?;
        let cols = stmt
            .query_map([], |row| row.get::<_, String>(1))?
            .collect::<rusqlite::Result<_>>()?;
        cols
    };
    if !decision_cols.contains("stats_before_id") {
        conn.execute(
            "ALTER TABLE decision_events ADD COLUMN stats_before_id INTEGER",
            [],
        )?;
    }
    if compact_historical_echo_names(&mut conn)? {
        // UPDATE frees pages internally; VACUUM returns the saved bytes to disk.
        conn.execute_batch("VACUUM")?;
    }
    Ok(conn)
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CharacterProfile {
    pub guid: String,
    pub name: String,
    pub realm: String,
    pub class: String,
    pub race: String,
    pub faction: String,
    pub talent_spec: String,
    pub role: String,
}

#[derive(Debug, Clone)]
pub struct HeroStats {
    pub telemetry_version: i64,
    pub values: [f64; 23],
    pub signature: String,
}

pub fn record_hero_stats(
    conn: &Connection,
    stats: &HeroStats,
    level: i64,
    session_id: i64,
) -> Result<i64> {
    let v = &stats.values;
    conn.execute(
        "INSERT INTO character_stat_snapshots (session_id,at,level,telemetry_version,strength,agility,stamina,intellect,spirit,attack_power,ranged_attack_power,spell_power,healing_power,crit_melee,crit_ranged,crit_spell,haste_melee,haste_ranged,haste_spell,hit_rating,expertise,armor,health_max,mana_max,weapon_min,weapon_max,weapon_speed,signature) \
         VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18,?19,?20,?21,?22,?23,?24,?25,?26,?27,?28)",
        params![session_id, now(), level, stats.telemetry_version,
            v[0],v[1],v[2],v[3],v[4],v[5],v[6],v[7],v[8],v[9],v[10],v[11],
            v[12],v[13],v[14],v[15],v[16],v[17],v[18],v[19],v[20],v[21],v[22],stats.signature],
    )?;
    Ok(conn.last_insert_rowid())
}

pub fn set_profile_role_override(
    conn: &Connection,
    profile: &CharacterProfile,
    role: &str,
) -> Result<()> {
    let seen_at = now();
    conn.execute(
        "INSERT INTO character_profiles (character_guid, character_name, realm, class, race, faction, talent_spec, role, role_override, first_seen_at, last_seen_at) \
         VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?10) \
         ON CONFLICT(character_guid) DO UPDATE SET role_override=excluded.role_override, last_seen_at=excluded.last_seen_at",
        params![profile.guid, profile.name, profile.realm, profile.class, profile.race,
            profile.faction, profile.talent_spec, profile.role, role, seen_at],
    )?;
    Ok(())
}

pub fn profile_role_override(conn: &Connection, guid: &str) -> Result<Option<String>> {
    Ok(conn
        .query_row(
            "SELECT role_override FROM character_profiles WHERE character_guid=?1",
            params![guid],
            |row| row.get::<_, Option<String>>(0),
        )
        .optional()?
        .flatten())
}

fn start_session(conn: &Connection, profile: &CharacterProfile) -> Result<i64> {
    conn.execute(
        "INSERT INTO sessions (started_at, character_guid, character_name, realm, class, race, faction, talent_spec, spec, profile_source) \
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, 'observed')",
        params![now(), profile.guid, profile.name, profile.realm, profile.class,
            profile.race, profile.faction, profile.talent_spec, profile.role],
    )?;
    let id = conn.last_insert_rowid();
    println!("[session_db] started session {id}");
    Ok(id)
}

/// Highest level ever seen for this session, across every table that
/// records one - the closest thing to "how far this build got" since
/// `sessions` doesn't track a final level directly.
pub fn session_max_level(conn: &Connection, session_id: i64) -> Result<Option<i64>> {
    let max: Option<i64> = conn.query_row(
        "SELECT MAX(level) FROM (
            SELECT level FROM actions WHERE session_id = ?1
            UNION ALL SELECT level FROM fights WHERE session_id = ?1
            UNION ALL SELECT level FROM board_log WHERE session_id = ?1
        )",
        params![session_id],
        |row| row.get::<_, Option<i64>>(0),
    )?;
    Ok(max)
}

/// Tracks the active session across calls, reattaching to the most recent
/// still-open session on first use and closing+starting a new one if level
/// ever drops, OR the `echo_run_reset` counter ever changes. Call
/// `ensure()` once per cycle, before recording anything.
///
/// `echo_run_reset` (EchoTracker.lua's `InstallRunResetHook`) increments
/// exactly once per real `ProjectEbonhold.PlayerRunService.AcceptDeath()`
/// call - confirmed against the server addon's own source to be the one
/// thing both normal and Hardcore death funnel through, regardless of
/// whether it was triggered by running out of free revives, declining to
/// pay Soul Ashes, or a deliberate self-destruct. Deliberately NOT inferred
/// from `hardmode_tier` dropping: that's also changed by
/// `HardmodeService.SetDifficulty()` from a plain "Change Difficulty" menu
/// with zero death involved, which would have made a tier-based signal
/// misfire on a voluntary difficulty switch. Getting this right matters
/// beyond just tidy history: aimodel trains on
/// `ln(1 + mean linked fight DPS)` per confirmed decision, and mixing two
/// very different power levels into one nominal "session" corrupts that
/// signal for every decision in it, not just the ones near the reset.
pub struct SessionTracker {
    current_session_id: Option<i64>,
    last_level: Option<i64>,
    last_reset_signal: Option<i64>,
    current_guid: Option<String>,
}

impl SessionTracker {
    pub fn new() -> Self {
        Self {
            current_session_id: None,
            last_level: None,
            last_reset_signal: None,
            current_guid: None,
        }
    }

    pub fn ensure(
        &mut self,
        conn: &Connection,
        level: i64,
        reset_signal: Option<i64>,
        profile: &CharacterProfile,
    ) -> Result<i64> {
        let seen_at = now();
        conn.execute(
            "INSERT INTO character_profiles (character_guid, character_name, realm, class, race, faction, talent_spec, role, first_seen_at, last_seen_at) \
             VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?9) \
             ON CONFLICT(character_guid) DO UPDATE SET character_name=excluded.character_name, realm=excluded.realm, \
             class=excluded.class, race=excluded.race, faction=excluded.faction, talent_spec=excluded.talent_spec, \
             role=excluded.role, last_seen_at=excluded.last_seen_at",
            params![profile.guid, profile.name, profile.realm, profile.class, profile.race,
                profile.faction, profile.talent_spec, profile.role, seen_at],
        )?;
        if self.current_guid.as_deref() != Some(profile.guid.as_str()) {
            if let Some(old_id) = self.current_session_id.take() {
                conn.execute(
                    "UPDATE sessions SET ended_at = ?1 WHERE id = ?2 AND ended_at IS NULL",
                    params![now(), old_id],
                )?;
                println!("[session_db] character changed: closed session {old_id}");
            }
            self.last_level = None;
            self.last_reset_signal = None;
            self.current_guid = Some(profile.guid.clone());
        }
        if self.current_session_id.is_none() {
            let existing: Option<i64> = conn
                .query_row(
                    "SELECT id FROM sessions WHERE ended_at IS NULL AND (character_guid = ?1 OR character_guid IS NULL) \
                     ORDER BY CASE WHEN character_guid = ?1 THEN 0 ELSE 1 END, id DESC LIMIT 1",
                    params![profile.guid],
                    |row| row.get::<_, i64>(0),
                )
                .optional()?;
            match existing {
                Some(id) => {
                    self.current_session_id = Some(id);
                    // Seed from the DB's real last-known level for that
                    // session, not the live value passed in here - a level
                    // reset that happened while no process was running must
                    // still be caught on this very call, not silently
                    // merged into the old session forever. echo_run_reset
                    // has no equivalent stored history to seed from (it's
                    // not tracked per-decision anywhere), so a reset that
                    // happens in the narrow window between companion runs
                    // can be missed - trusting the live value as the
                    // baseline is the best available without a schema
                    // change, and the common case (companion running
                    // continuously through a play session) is unaffected.
                    self.last_level = Some(session_max_level(conn, id)?.unwrap_or(level));
                    self.last_reset_signal = reset_signal;
                }
                None => {
                    self.current_session_id = Some(start_session(conn, profile)?);
                    self.last_level = Some(level);
                    self.last_reset_signal = reset_signal;
                }
            }
            let id = self.current_session_id.unwrap();
            conn.execute(
                "UPDATE sessions SET character_guid=?1, character_name=?2, realm=?3, class=?4, race=?5, faction=?6, \
                 talent_spec=?7, spec=?8, profile_source='observed' WHERE id=?9",
                params![profile.guid, profile.name, profile.realm, profile.class, profile.race,
                    profile.faction, profile.talent_spec, profile.role, id],
            )?;
        }

        let session_id = self.current_session_id.unwrap();
        let level_dropped = self.last_level.is_some_and(|last| level < last);
        let reset_fired = matches!(
            (self.last_reset_signal, reset_signal),
            (Some(last), Some(current)) if current != last
        );
        if level_dropped || reset_fired {
            conn.execute(
                "UPDATE sessions SET ended_at = ?1 WHERE id = ?2",
                params![now(), session_id],
            )?;
            if level_dropped {
                println!(
                    "[session_db] level dropped {} -> {level}: closed session {session_id}",
                    self.last_level.unwrap()
                );
            }
            if reset_fired {
                println!(
                    "[session_db] echo_run_reset fired ({} -> {}): closed session {session_id}",
                    self.last_reset_signal.unwrap(),
                    reset_signal.unwrap()
                );
            }
            self.current_session_id = Some(start_session(conn, profile)?);
        }
        if let Some(r) = reset_signal {
            self.last_reset_signal = Some(r);
        }
        self.last_level = Some(level);
        Ok(self.current_session_id.unwrap())
    }
}

/// The most recently started still-open session, if any -
/// (id, character_name, started_at). For `companion session status`.
pub fn current_open_session(conn: &Connection) -> Result<Option<(i64, Option<String>, f64)>> {
    Ok(conn
        .query_row(
            "SELECT id, character_name, started_at FROM sessions WHERE ended_at IS NULL ORDER BY id DESC LIMIT 1",
            [],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
        )
        .optional()?)
}

/// Closes the most recently started still-open session (sets
/// `ended_at = now`). Returns its id, or None if nothing was open. For
/// `companion session end` - a manual "I'm done for now" that doesn't wait
/// for a level drop, `echo_run_reset`, or character switch to close it
/// naturally (see SessionTracker::ensure for those automatic triggers).
pub fn end_current_session(conn: &Connection) -> Result<Option<i64>> {
    let Some((id, _, _)) = current_open_session(conn)? else {
        return Ok(None);
    };
    conn.execute(
        "UPDATE sessions SET ended_at = ?1 WHERE id = ?2",
        params![now(), id],
    )?;
    Ok(Some(id))
}

/// Latest-observed-value overwrite for reroll/freeze totals (echo_charges
/// reports these directly and live, so there's never a reason to freeze a
/// stale copy). banish has no total field at all in echo_charges (only
/// remainingBanishes) - the caller estimates it each cycle as
/// remaining + spent-this-session-so-far, stored as a ratcheting MAX since
/// that estimate is only ever a lower bound that converges upward.
pub fn record_resource_totals(
    conn: &Connection,
    reroll_total: i64,
    freeze_total: i64,
    banish_total_estimate: i64,
    session_id: i64,
) -> Result<()> {
    conn.execute(
        "UPDATE sessions SET reroll_total = ?1, freeze_total = ?2, \
         banish_total = MAX(COALESCE(banish_total, 0), ?3) WHERE id = ?4",
        params![
            reroll_total,
            freeze_total,
            banish_total_estimate,
            session_id
        ],
    )?;
    Ok(())
}

/// How many times `action` was executed this session, across the WHOLE
/// run - used to estimate banish's implied total.
pub fn actions_spent_total(conn: &Connection, action: &str, session_id: i64) -> Result<i64> {
    let count: i64 = conn.query_row(
        "SELECT COUNT(*) FROM actions WHERE session_id = ?1 AND action = ?2",
        params![session_id, action],
        |row| row.get(0),
    )?;
    Ok(count)
}

/// First-call-wins, unlike record_resource_totals (class/spec genuinely
/// don't change mid-session).
pub fn set_session_class_spec_if_unset(
    conn: &Connection,
    klass: &str,
    spec: &str,
    session_id: i64,
) -> Result<()> {
    let existing: Option<String> = conn
        .query_row(
            "SELECT class FROM sessions WHERE id = ?1",
            params![session_id],
            |row| row.get::<_, Option<String>>(0),
        )
        .optional()?
        .flatten();
    if existing.is_some() {
        return Ok(());
    }
    conn.execute(
        "UPDATE sessions SET class = ?1, spec = ?2 WHERE id = ?3",
        params![klass, spec, session_id],
    )?;
    Ok(())
}

/// Latest-observed-value overwrite - committed Soul Ashes grows through a
/// session, so each cycle's fresher number should win.
pub fn record_prestige_state(
    conn: &Connection,
    prestiges: i64,
    ash_committed: i64,
    ash_bonus_pct: f64,
    session_id: i64,
) -> Result<()> {
    conn.execute(
        "UPDATE sessions SET prestiges = ?1, ash_committed = ?2, ash_bonus_pct = ?3 WHERE id = ?4",
        params![prestiges, ash_committed, ash_bonus_pct, session_id],
    )?;
    Ok(())
}

pub fn record_hardmode_tier(conn: &Connection, tier: i64, session_id: i64) -> Result<()> {
    conn.execute(
        "UPDATE sessions SET hardmode_tier = ?1 WHERE id = ?2",
        params![tier, session_id],
    )?;
    Ok(())
}

pub fn record_soul_points(
    conn: &Connection,
    points: i64,
    points_max: i64,
    session_id: i64,
) -> Result<()> {
    conn.execute(
        "UPDATE sessions SET soul_points = ?1, soul_points_max = ?2 WHERE id = ?3",
        params![points, points_max, session_id],
    )?;
    Ok(())
}

/// Locked Echoes are account-global, not character-owned. The account tables
/// are the current source of truth. `locked_echoes(session_id, ...)` remains
/// as a temporal observation for legacy reports (what global state this run
/// saw), not as ownership attached to the character profile.
pub fn record_locked(
    conn: &Connection,
    locked: &[LockedEcho],
    max_slots: i64,
    session_id: i64,
) -> Result<()> {
    let now = now();
    conn.execute("DELETE FROM account_locked_echoes", [])?;
    for echo in locked {
        conn.execute(
            "INSERT INTO account_locked_echoes (spell_id,count,quality,updated_at) VALUES (?1,?2,?3,?4)",
            params![echo.spell_id, echo.count, echo.quality, now],
        )?;
    }
    conn.execute(
        "INSERT INTO account_echo_state(singleton,max_permanent_slots,updated_at) VALUES(1,?1,?2) \
         ON CONFLICT(singleton) DO UPDATE SET max_permanent_slots=excluded.max_permanent_slots,updated_at=excluded.updated_at",
        params![max_slots, now],
    )?;
    conn.execute(
        "DELETE FROM locked_echoes WHERE session_id = ?1",
        params![session_id],
    )?;
    for echo in locked {
        conn.execute(
            "INSERT INTO locked_echoes (session_id, spell_id, count, quality, updated_at) VALUES (?1, ?2, ?3, ?4, ?5)",
            params![session_id, echo.spell_id, echo.count, echo.quality, now],
        )?;
    }
    conn.execute(
        "UPDATE sessions SET max_permanent_slots = ?1 WHERE id = ?2",
        params![max_slots, session_id],
    )?;
    Ok(())
}

#[derive(Debug, Clone, Default)]
pub struct SessionTotals {
    pub reroll_total: Option<i64>,
    pub freeze_total: Option<i64>,
    pub banish_total: Option<i64>,
}

pub fn get_session_totals(conn: &Connection, session_id: i64) -> Result<SessionTotals> {
    let row = conn
        .query_row(
            "SELECT reroll_total, freeze_total, banish_total FROM sessions WHERE id = ?1",
            params![session_id],
            |row| {
                Ok((
                    row.get::<_, Option<i64>>(0)?,
                    row.get::<_, Option<i64>>(1)?,
                    row.get::<_, Option<i64>>(2)?,
                ))
            },
        )
        .optional()?;
    Ok(match row {
        Some((reroll_total, freeze_total, banish_total)) => SessionTotals {
            reroll_total,
            freeze_total,
            banish_total,
        },
        None => SessionTotals::default(),
    })
}

pub fn record_owned(
    conn: &Connection,
    owned: &HashMap<String, i64>,
    session_id: i64,
) -> Result<()> {
    let now = now();
    for (spell_id, count) in owned {
        conn.execute(
            "INSERT INTO owned_echoes (session_id, spell_id, count, updated_at) VALUES (?1, ?2, ?3, ?4) \
             ON CONFLICT(session_id, spell_id) DO UPDATE SET count = excluded.count, updated_at = excluded.updated_at",
            params![session_id, spell_id, count, now],
        )?;
    }
    Ok(())
}

/// Immutable, time-addressable build state used by training examples and
/// fights. Unlike `owned_echoes` (the latest/final session projection), this
/// preserves exactly which stacks were observed at this point in the run.
pub fn record_build_snapshot(
    conn: &Connection,
    owned: &HashMap<String, i64>,
    level: i64,
    trigger: &str,
    signature: &str,
    session_id: i64,
) -> Result<i64> {
    conn.execute(
        "INSERT INTO build_snapshots (session_id, at, level, trigger, owned_signature) VALUES (?1, ?2, ?3, ?4, ?5)",
        params![session_id, now(), level, trigger, signature],
    )?;
    let snapshot_id = conn.last_insert_rowid();
    for (spell_id, count) in owned {
        conn.execute(
            "INSERT INTO build_snapshot_echoes (snapshot_id, spell_id, count) VALUES (?1, ?2, ?3)",
            params![snapshot_id, spell_id, count],
        )?;
    }
    // A TAKE may be confirmed by the board changing before the independently
    // chunked owned telemetry arrives. Complete any such confirmed rows when
    // the next genuinely new build snapshot is observed.
    conn.execute(
        "UPDATE decision_events SET build_after_id = ?1 \
         WHERE session_id = ?2 AND status = 'confirmed' AND build_after_id IS NULL",
        params![snapshot_id, session_id],
    )?;
    record_owned(conn, owned, session_id)?;
    Ok(snapshot_id)
}

pub struct DecisionRecord<'a> {
    pub session_id: i64,
    pub level: i64,
    pub board: &'a str,
    pub action: &'a str,
    pub target_spell_id: Option<&'a str>,
    pub reasons_json: &'a str,
    pub scores_json: &'a str,
    pub charges_json: &'a str,
    pub build_before_id: Option<i64>,
    pub stats_before_id: Option<i64>,
    pub status: &'a str,
}

pub fn record_decision(conn: &Connection, record: &DecisionRecord<'_>) -> Result<i64> {
    conn.execute(
        "INSERT INTO decision_events (session_id, at, level, board, action, target_spell_id, reasons_json, scores_json, charges_json, build_before_id, stats_before_id, status) \
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)",
        params![record.session_id, now(), record.level, record.board, record.action, record.target_spell_id,
            record.reasons_json, record.scores_json, record.charges_json, record.build_before_id,
            record.stats_before_id, record.status],
    )?;
    Ok(conn.last_insert_rowid())
}

pub fn mark_decision_sent(conn: &Connection, decision_id: i64) -> Result<()> {
    conn.execute(
        "UPDATE decision_events SET status = 'sent' WHERE id = ?1 AND status = 'observed'",
        params![decision_id],
    )?;
    Ok(())
}

pub fn resolve_decision(
    conn: &Connection,
    decision_id: i64,
    status: &str,
    build_after_id: Option<i64>,
) -> Result<()> {
    conn.execute(
        "UPDATE decision_events SET status = ?1, build_after_id = ?2, confirmed_at = ?3 WHERE id = ?4",
        params![status, build_after_id, now(), decision_id],
    )?;
    Ok(())
}

pub fn record_action(
    conn: &Connection,
    action: &str,
    spell_id: Option<&str>,
    level: i64,
    board: &str,
    session_id: i64,
) -> Result<()> {
    conn.execute(
        "INSERT INTO actions (session_id, at, action, spell_id, level, board) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
        params![session_id, now(), action, spell_id, level, board],
    )?;
    Ok(())
}

/// One completed fight (SimpleDamageMeter's dps_last_fight, parsed) tied
/// to whatever build was owned at the time.
pub fn record_fight(
    conn: &Connection,
    damage: i64,
    dps: f64,
    duration_s: f64,
    level: i64,
    session_id: i64,
    build_snapshot_id: Option<i64>,
    stat_snapshot_id: Option<i64>,
) -> Result<()> {
    conn.execute(
        "INSERT INTO fights (session_id, at, level, damage, dps, duration_s, build_snapshot_id, stat_snapshot_id) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
        params![session_id, now(), level, damage, dps, duration_s, build_snapshot_id, stat_snapshot_id],
    )?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn training_records_keep_build_decision_and_fight_relationships() -> Result<()> {
        let path = std::env::temp_dir().join(format!(
            "echobrain-session-test-{}-{}.sqlite3",
            std::process::id(),
            now()
        ));
        let conn = open(&path)?;
        conn.execute(
            "INSERT INTO sessions (started_at) VALUES (?1)",
            params![now()],
        )?;
        let session_id = conn.last_insert_rowid();

        let owned = HashMap::from([("200001".to_string(), 2), ("200020".to_string(), 1)]);
        let snapshot_id =
            record_build_snapshot(&conn, &owned, 42, "test", "200001:2;200020:1", session_id)?;
        let stat_snapshot_id = record_hero_stats(
            &conn,
            &HeroStats {
                telemetry_version: 2,
                values: [42.0; 23],
                signature: "test-stats".to_string(),
            },
            42,
            session_id,
        )?;
        let decision_id = record_decision(
            &conn,
            &DecisionRecord {
                session_id,
                level: 42,
                board: "1:2:;20:1:;30:0:",
                action: "TAKE",
                target_spell_id: Some("200001"),
                reasons_json: r#"["best"]"#,
                scores_json: r#"[{"spell_id":"200001","score":{"total":70}}]"#,
                charges_json: r#"{"reroll_total":10}"#,
                build_before_id: Some(snapshot_id),
                stats_before_id: Some(stat_snapshot_id),
                status: "sent",
            },
        )?;
        resolve_decision(&conn, decision_id, "confirmed", Some(snapshot_id))?;
        record_fight(
            &conn,
            1000,
            500.0,
            2.0,
            42,
            session_id,
            Some(snapshot_id),
            Some(stat_snapshot_id),
        )?;

        let echo_count: i64 = conn.query_row(
            "SELECT COUNT(*) FROM build_snapshot_echoes WHERE snapshot_id = ?1",
            params![snapshot_id],
            |row| row.get(0),
        )?;
        assert_eq!(echo_count, 2);
        let status: String = conn.query_row(
            "SELECT status FROM decision_events WHERE id = ?1",
            params![decision_id],
            |row| row.get(0),
        )?;
        assert_eq!(status, "confirmed");
        let fight_snapshot: Option<i64> = conn.query_row(
            "SELECT build_snapshot_id FROM fights WHERE session_id = ?1",
            params![session_id],
            |row| row.get(0),
        )?;
        assert_eq!(fight_snapshot, Some(snapshot_id));
        let decision_stats: Option<i64> = conn.query_row(
            "SELECT stats_before_id FROM decision_events WHERE id=?1",
            params![decision_id],
            |row| row.get(0),
        )?;
        assert_eq!(decision_stats, Some(stat_snapshot_id));

        drop(conn);
        let _ = std::fs::remove_file(path);
        Ok(())
    }

    #[test]
    fn migration_preserves_legacy_fights_and_adds_snapshot_link() -> Result<()> {
        let path = std::env::temp_dir().join(format!(
            "echobrain-legacy-migration-test-{}-{}.sqlite3",
            std::process::id(),
            now()
        ));
        {
            let legacy = Connection::open(&path)?;
            legacy.execute_batch(
                "CREATE TABLE fights (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    session_id INTEGER NOT NULL,
                    at REAL NOT NULL,
                    level INTEGER,
                    damage INTEGER NOT NULL,
                    dps REAL NOT NULL,
                    duration_s REAL NOT NULL
                 );
                 INSERT INTO fights (session_id, at, level, damage, dps, duration_s)
                 VALUES (7, 1.0, 80, 1234, 617.0, 2.0);",
            )?;
        }

        let conn = open(&path)?;
        let legacy_count: i64 =
            conn.query_row("SELECT COUNT(*) FROM fights", [], |row| row.get(0))?;
        assert_eq!(legacy_count, 1);
        let has_new_column: bool = {
            let mut stmt = conn.prepare("PRAGMA table_info(fights)")?;
            let cols = stmt
                .query_map([], |row| row.get::<_, String>(1))?
                .collect::<rusqlite::Result<Vec<_>>>()?;
            cols.iter().any(|name| name == "build_snapshot_id")
        };
        assert!(has_new_column);

        drop(conn);
        let _ = std::fs::remove_file(path);
        Ok(())
    }

    #[test]
    fn character_change_creates_a_separate_profile_and_session() -> Result<()> {
        let path = std::env::temp_dir().join(format!(
            "echobrain-profile-test-{}-{}.sqlite3",
            std::process::id(),
            now()
        ));
        let conn = open(&path)?;
        let paladin = CharacterProfile {
            guid: "0xPALADIN".into(),
            name: "Kaeos".into(),
            realm: "Ebonhold".into(),
            class: "PALADIN".into(),
            race: "BloodElf".into(),
            faction: "Horde".into(),
            talent_spec: "Retribution".into(),
            role: "dps".into(),
        };
        let mage = CharacterProfile {
            guid: "0xMAGE".into(),
            name: "Firetest".into(),
            realm: "Ebonhold".into(),
            class: "MAGE".into(),
            race: "BloodElf".into(),
            faction: "Horde".into(),
            talent_spec: "Fire".into(),
            role: "dps".into(),
        };
        let mut tracker = SessionTracker::new();
        let paladin_session = tracker.ensure(&conn, 79, None, &paladin)?;
        let mage_session = tracker.ensure(&conn, 10, None, &mage)?;
        assert_ne!(paladin_session, mage_session);
        let paladin_ended: Option<f64> = conn.query_row(
            "SELECT ended_at FROM sessions WHERE id=?1",
            params![paladin_session],
            |r| r.get(0),
        )?;
        assert!(paladin_ended.is_some());
        let profiles: i64 =
            conn.query_row("SELECT COUNT(*) FROM character_profiles", [], |r| r.get(0))?;
        assert_eq!(profiles, 2);
        let mage_guid: String = conn.query_row(
            "SELECT character_guid FROM sessions WHERE id=?1",
            params![mage_session],
            |r| r.get(0),
        )?;
        assert_eq!(mage_guid, mage.guid);
        drop(conn);
        let _ = std::fs::remove_file(path);
        Ok(())
    }
}
