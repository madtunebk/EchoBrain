//! Wire-format parsing for everything EchoTracker reports through
//! wow_bridge's key/value cache - echo_board/echo_owned_*/echo_charges/
//! echo_locked. Ported from tools/live/score_echo_board.py's parse_board/
//! parse_owned/parse_locked/parse_charges/fetch_owned (same offset
//! convention, same field order) - kept in one module since main.rs's
//! `select` needs the same board parsing scoring.rs/decide.rs need.

use crate::bridge::WowBridge;
use std::collections::HashMap;

// EchoTracker.lua sends (spellId - SPELL_ID_BASE) instead of the raw id to
// save bytes on the wire - added back here, immediately, so every
// downstream consumer (catalog lookups, SelectPerk/BanishPerk/FreezePerk)
// keeps working with the real spellId and never has to know this happened.
pub const SPELL_ID_BASE: i64 = 200000;

#[derive(Debug, Clone)]
pub struct Card {
    pub index0: usize,
    pub spell_id: String,
    pub quality: i64,
    pub frozen: bool,
    pub carried: bool,
    pub guaranteed: bool,
}

/// "id:quality:flags;id:quality:flags;..." - flags is a string of single-
/// letter codes (F=frozen, C=carried, G=guaranteed), may be empty/absent.
pub fn parse_board(raw: &str) -> Vec<Card> {
    let mut cards = Vec::new();
    for chunk in raw.split(';') {
        if chunk.is_empty() {
            continue;
        }
        let parts: Vec<&str> = chunk.split(':').collect();
        if parts.len() < 2 {
            continue;
        }
        let Ok(raw_id) = parts[0].parse::<i64>() else {
            continue;
        };
        let Ok(quality) = parts[1].parse::<i64>() else {
            continue;
        };
        let flags = parts.get(2).copied().unwrap_or("");
        cards.push(Card {
            index0: cards.len(),
            spell_id: (raw_id + SPELL_ID_BASE).to_string(),
            quality,
            frozen: flags.contains('F'),
            carried: flags.contains('C'),
            guaranteed: flags.contains('G'),
        });
    }
    cards
}

/// Resolves the real spellId (offset back by SPELL_ID_BASE) at a given
/// 0-based board position, or None if out of range/malformed. Used by
/// `select` (SelectPerk takes a spellId, not a board position).
pub fn spell_id_at(echo_board: &str, index0: usize) -> Option<i64> {
    parse_board(echo_board)
        .get(index0)
        .and_then(|card| card.spell_id.parse::<i64>().ok())
}

/// "id:count;id:count;..." -> {spellId: count}.
pub fn parse_owned(raw: &str) -> HashMap<String, i64> {
    let mut owned = HashMap::new();
    for chunk in raw.split(';') {
        if chunk.is_empty() || !chunk.contains(':') {
            continue;
        }
        let mut parts = chunk.splitn(2, ':');
        let (Some(id_str), Some(count_str)) = (parts.next(), parts.next()) else {
            continue;
        };
        let (Ok(raw_id), Ok(count)) = (id_str.parse::<i64>(), count_str.parse::<i64>()) else {
            continue;
        };
        owned.insert((raw_id + SPELL_ID_BASE).to_string(), count);
    }
    owned
}

#[derive(Debug, Clone)]
pub struct LockedEcho {
    pub spell_id: String,
    pub count: i64,
    pub quality: i64,
}

/// echo_locked: "id:stack:quality" triples ';'-joined - the subset of owned
/// echoes explicitly chosen as PERMANENT (survives a normal reset), from
/// ProjectEbonhold.PerkService.GetLockedPerks().
pub fn parse_locked(raw: &str) -> Vec<LockedEcho> {
    let mut locked = Vec::new();
    for chunk in raw.split(';') {
        if chunk.is_empty() {
            continue;
        }
        let parts: Vec<&str> = chunk.split(':').collect();
        if parts.len() < 3 {
            continue;
        }
        let (Ok(raw_id), Ok(count), Ok(quality)) = (
            parts[0].parse::<i64>(),
            parts[1].parse::<i64>(),
            parts[2].parse::<i64>(),
        ) else {
            continue;
        };
        locked.push(LockedEcho {
            spell_id: (raw_id + SPELL_ID_BASE).to_string(),
            count,
            quality,
        });
    }
    locked
}

#[derive(Debug, Clone, Default)]
pub struct Charges {
    pub reroll_used: i64,
    pub reroll_total: i64,
    pub banish_remaining: i64,
    pub freeze_used: i64,
    pub freeze_total: i64,
    /// Per-20-level-group rationing on top of the raw remaining charges -
    /// filled in by autopilot.rs's apply_group_quota, absent for a bare
    /// `companion score` read (which has no session to ration against).
    pub reroll_group_left: Option<i64>,
    pub banish_group_left: Option<i64>,
    pub freeze_group_left: Option<i64>,
}

/// "reroll:used/total;banish:remaining;freeze:used/total" (order not
/// significant - key-driven, like the Python original).
pub fn parse_charges(raw: &str) -> Charges {
    let mut parts: HashMap<&str, &str> = HashMap::new();
    for chunk in raw.split(';') {
        if let Some((key, value)) = chunk.split_once(':') {
            parts.insert(key, value);
        }
    }
    let split_used_total = |s: Option<&&str>| -> (i64, i64) {
        let Some(s) = s else { return (0, 0) };
        let (used, total) = s.split_once('/').unwrap_or((s, "0"));
        (used.parse().unwrap_or(0), total.parse().unwrap_or(0))
    };
    let (reroll_used, reroll_total) = split_used_total(parts.get("reroll"));
    let (freeze_used, freeze_total) = split_used_total(parts.get("freeze"));
    Charges {
        reroll_used,
        reroll_total,
        banish_remaining: parts
            .get("banish")
            .and_then(|s| s.parse().ok())
            .unwrap_or(0),
        freeze_used,
        freeze_total,
        reroll_group_left: None,
        banish_group_left: None,
        freeze_group_left: None,
    }
}

/// echo_owned is chunked across echo_owned_1.._N (see EchoTracker.lua's
/// SendChunked) since one joined string blows past the 220-byte single
/// addon-message cap once a character has 30+ granted echoes. Reassembles
/// them before handing off to parse_owned.
pub fn fetch_owned(bridge: &WowBridge) -> anyhow::Result<HashMap<String, i64>> {
    let count: i64 = bridge
        .get("echo_owned_count")
        .map_err(anyhow::Error::msg)?
        .and_then(|s| s.parse().ok())
        .unwrap_or(0);
    let mut joined = String::new();
    for i in 1..=count {
        if let Some(chunk) = bridge
            .get(&format!("echo_owned_{i}"))
            .map_err(anyhow::Error::msg)?
        {
            if !joined.is_empty() {
                joined.push(';');
            }
            joined.push_str(&chunk);
        }
    }
    Ok(parse_owned(&joined))
}
