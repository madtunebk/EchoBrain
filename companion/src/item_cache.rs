//! Local cache for arbitrary WoW item names/quality/texture, keyed by item
//! ID - `data/cache/items.sqlite3`. Exists because WhitelistLiquidator.lua's
//! `wl_whitelist`/`wl_equipped` exports send item IDs only now (see that
//! file's own comments): item names are server-generated procedural text
//! ("Sanctified Lightsworn Helmet of Ironhide IV") that can't be pre-baked
//! into a static file the way `data/perk_catalog.json`'s echo names can.
//!
//! Populated lazily: a cache miss queues
//! `WhitelistLiquidatorRemote.ResolveItem(id)` through the bridge (see
//! `resolve_pending`/`start_resolve` in autopilot.rs) and the answer is
//! cached forever, so the game is only ever asked once per item ID no
//! matter how many times companion/FlaskGUI display it afterward.

use rusqlite::{params, Connection, OptionalExtension};
use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};

pub struct CachedItem {
    pub name: String,
    pub quality: Option<i64>,
    pub texture: Option<String>,
}

fn now() -> f64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs_f64()
}

/// Opens (creating the file/directory/table as needed) the item cache at
/// `path` - e.g. `data/cache/items.sqlite3`.
pub fn open(path: &Path) -> anyhow::Result<Connection> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let conn = Connection::open(path)?;
    conn.execute(
        "CREATE TABLE IF NOT EXISTS items (
            id INTEGER PRIMARY KEY,
            name TEXT NOT NULL,
            quality INTEGER,
            texture TEXT,
            cached_at REAL NOT NULL
        )",
        [],
    )?;
    Ok(conn)
}

pub fn get(conn: &Connection, id: i64) -> anyhow::Result<Option<CachedItem>> {
    Ok(conn
        .query_row(
            "SELECT name, quality, texture FROM items WHERE id = ?1",
            params![id],
            |row| {
                Ok(CachedItem {
                    name: row.get(0)?,
                    quality: row.get(1)?,
                    texture: row.get(2)?,
                })
            },
        )
        .optional()?)
}

pub fn set(
    conn: &Connection,
    id: i64,
    name: &str,
    quality: Option<i64>,
    texture: Option<&str>,
) -> anyhow::Result<()> {
    conn.execute(
        "INSERT INTO items (id, name, quality, texture, cached_at) VALUES (?1,?2,?3,?4,?5) \
         ON CONFLICT(id) DO UPDATE SET name=excluded.name, quality=excluded.quality, \
         texture=excluded.texture, cached_at=excluded.cached_at",
        params![id, name, quality, texture, now()],
    )?;
    Ok(())
}

/// Parses the `wl_item_resolved` bridge value WhitelistLiquidatorRemote.
/// ResolveItem reports: `id<FS>name<FS>quality<FS>texture` (name/quality/
/// texture may be empty - GetItemInfo can legitimately return nil if the
/// client hasn't cached this item yet). Returns None on a genuinely
/// unresolved lookup (empty name) so the caller knows to retry later
/// instead of caching a permanent blank.
pub fn parse_resolved(raw: &str) -> Option<(i64, CachedItem)> {
    const FS: char = '\u{1f}';
    let mut parts = raw.split(FS);
    let id: i64 = parts.next()?.parse().ok()?;
    let name = parts.next().unwrap_or("");
    if name.is_empty() {
        return None;
    }
    let quality = parts.next().and_then(|s| s.parse().ok());
    let texture = parts.next().filter(|s| !s.is_empty()).map(str::to_string);
    Some((
        id,
        CachedItem {
            name: name.to_string(),
            quality,
            texture,
        },
    ))
}

/// Blocking resolve for one-shot CLI use (`companion wl equipped`/
/// `whitelist`) - queues the lookup and polls for up to `timeout` before
/// giving up. Never used from the `auto` cycle loop, which can't afford to
/// block the whole decide loop on a single item lookup - see autopilot.rs's
/// own non-blocking one-at-a-time resolver instead.
pub fn resolve_blocking(
    bridge: &crate::bridge::WowBridge,
    conn: &Connection,
    id: i64,
    timeout: std::time::Duration,
) -> anyhow::Result<Option<CachedItem>> {
    if let Some(cached) = get(conn, id)? {
        return Ok(Some(cached));
    }
    bridge
        .run_lua(&format!("WhitelistLiquidatorRemote.ResolveItem({id})"))
        .map_err(anyhow::Error::msg)?;
    let deadline = std::time::Instant::now() + timeout;
    while std::time::Instant::now() < deadline {
        if let Ok(Some(raw)) = bridge.get("wl_item_resolved") {
            if let Some((resolved_id, item)) = parse_resolved(&raw) {
                if resolved_id == id {
                    set(conn, id, &item.name, item.quality, item.texture.as_deref())?;
                    return Ok(Some(item));
                }
            }
        }
        std::thread::sleep(std::time::Duration::from_millis(200));
    }
    Ok(None)
}
