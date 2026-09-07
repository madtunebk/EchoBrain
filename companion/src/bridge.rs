//! HTTP client for wow_bridge's local control API - the Rust equivalent of
//! sdk/python/wow_bridge.py's WowBridge class. wow_bridge itself knows
//! nothing about this crate or Companion at all - this is just a client of
//! the SAME generic public HTTP API Python already uses (GET/POST
//! /api/variables/{key}, POST /api/cmd/lua), deliberately kept that way so
//! the transport layer stays fully decoupled from Echo-specific logic (see
//! the project's own "wow_bridge stays dummy" architectural decision).

use serde_json::Value;

// /api/cmd/lua's injected code has a hard ~210-byte budget - anything
// longer is silently dropped, no error, never reaches loadstring (see
// wow_bridge's addon_bridge.rs take_set_response: the "__lua" value shares
// the same size-capped POLL-response queue every other queued write does).
// Established ground truth this session, live-tested against the real
// notification payload in autopilot.rs's execute(). Every caller that
// sends Lua through this client (autopilot's execute(), the `lua`
// subcommand) must check against this before sending, not after - past
// this size the call still "succeeds" (200 OK) but nothing ever runs.
pub const LUA_CMD_BUDGET: usize = 195;

/// wow_bridge now requires `Authorization: Bearer <token>` on every request
/// (closes "anyone who can reach this port can run arbitrary Lua in the
/// live game" - the API binds 0.0.0.0 so the WoW client on the Windows host
/// can reach it out of WSL, which also makes it reachable from the rest of
/// the network). The token rotates on every wow_bridge startup AND on every
/// real WoW login, so this re-reads the file on every single call rather
/// than caching it - a cached stale token would start failing with 401 the
/// moment a new login happens.
///
/// Anchored to THIS EXECUTABLE'S OWN directory, not a cwd-relative path -
/// `companion` and `wow_bridge` are launched from inconsistent working
/// directories in practice (repo root vs `bins/`), but both binaries are
/// always deployed side by side into the same `bins/` directory, so
/// `current_exe()`'s parent reaches the same file wow_bridge wrote
/// regardless of which directory either process happens to be launched
/// from (see wow_bridge's `common.rs::token_file_path` - same logic, kept
/// in sync deliberately since there's no shared crate between the two
/// binaries to put this in once).
fn current_token() -> String {
    std::env::current_exe()
        .ok()
        .and_then(|p| p.parent().map(|d| d.join("api_token.txt")))
        .and_then(|p| std::fs::read_to_string(p).ok())
        .map(|s| s.trim().to_string())
        .unwrap_or_default()
}

pub struct WowBridge {
    base_url: String,
    agent: ureq::Agent,
}

impl WowBridge {
    pub fn new(base_url: &str) -> Self {
        WowBridge {
            base_url: base_url.trim_end_matches('/').to_string(),
            agent: ureq::AgentBuilder::new()
                .timeout(std::time::Duration::from_secs(5))
                .build(),
        }
    }

    fn auth_header(&self) -> String {
        format!("Bearer {}", current_token())
    }

    /// Pure read of the local cache. Returns None if the key is unknown
    /// (404) - matches wow_bridge.py's WowBridge.get() behavior exactly.
    pub fn get(&self, key: &str) -> Result<Option<String>, String> {
        let url = format!("{}/api/variables/{}", self.base_url, key);
        match self
            .agent
            .get(&url)
            .set("Authorization", &self.auth_header())
            .call()
        {
            Ok(response) => {
                let body: Value = response.into_json().map_err(|e| e.to_string())?;
                Ok(body
                    .get("value")
                    .and_then(|v| v.as_str())
                    .map(str::to_string))
            }
            Err(ureq::Error::Status(404, _)) => Ok(None),
            Err(e) => Err(e.to_string()),
        }
    }

    /// Queues `value` for delivery into the game via the next addon poll.
    /// Only for values the game client actually needs to receive
    /// (echo_auto, echo_suggested/echo_suggested_action) - see `report()`
    /// for anything dashboard-only. This shares one small (~200-byte) POLL
    /// response with every other queued write AND with `/api/cmd/lua` -
    /// found live (09-05) that an oversized value sent through here can
    /// permanently jam every real gameplay command queued behind it, with
    /// no error anywhere, since wow_bridge's response-packing used to give
    /// up entirely on the first pair too big to fit.
    pub fn set(&self, key: &str, value: &str) -> Result<(), String> {
        let url = format!("{}/api/variables/{}", self.base_url, key);
        self.agent
            .post(&url)
            .set("Authorization", &self.auth_header())
            .send_json(serde_json::json!({ "value": value }))
            .map_err(|e| e.to_string())?;
        Ok(())
    }

    /// Updates wow_bridge's cache and /api/stream feed only - NEVER queued
    /// for delivery into the game, so no size limit and no risk of ever
    /// blocking a real gameplay command the way `set()` can. Use this for
    /// anything the game itself never reads (echo_reason, echo_group_budget
    /// - EchoTracker.lua has no code path that consumes either).
    pub fn report(&self, key: &str, value: &str) -> Result<(), String> {
        let url = format!("{}/api/report/{}", self.base_url, key);
        self.agent
            .post(&url)
            .set("Authorization", &self.auth_header())
            .send_json(serde_json::json!({ "value": value }))
            .map_err(|e| e.to_string())?;
        Ok(())
    }

    /// Reassembles a value an addon sent via DataBridge_SendLarge (see
    /// WoW_AddOns/DataBridge/DataBridge.lua) - `<base_key>_1, <base_key>_2,
    /// ... <base_key>_count`, used whenever a single value would be too big
    /// for DataBridge_Send's own ~220-byte cap (a whitelist, an equip
    /// loadout, an echo catalog). Joining chunks with ";" reproduces the
    /// original list exactly: DataBridge_SendLarge only ever breaks a chunk
    /// between whole parts, never through the middle of one. Pure read of
    /// the local cache, same as `get()` - no side effects, safe to retry.
    pub fn get_chunked(&self, base_key: &str) -> String {
        let count: usize = self
            .get(&format!("{base_key}_count"))
            .ok()
            .flatten()
            .and_then(|s| s.parse().ok())
            .unwrap_or(0);
        let mut chunks = Vec::with_capacity(count);
        for i in 1..=count {
            if let Ok(Some(chunk)) = self.get(&format!("{base_key}_{i}")) {
                chunks.push(chunk);
            }
        }
        chunks.join(";")
    }

    /// Queues arbitrary Lua for the addon to execute via loadstring/pcall
    /// on its next poll, via POST /api/cmd/lua.
    pub fn run_lua(&self, code: &str) -> Result<(), String> {
        let url = format!("{}/api/cmd/lua", self.base_url);
        self.agent
            .post(&url)
            .set("Authorization", &self.auth_header())
            .send_json(serde_json::json!({ "value": code }))
            .map_err(|e| e.to_string())?;
        Ok(())
    }
}
