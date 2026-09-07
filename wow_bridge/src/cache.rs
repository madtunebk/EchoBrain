//! Durable backing store for the variable cache in `addon_bridge.rs`. Every
//! value the bridge learns (from the game or from an API write) is mirrored
//! here so it survives a `wow_bridge` restart - `main.rs` loads this table
//! back into the in-memory map on startup instead of coming up empty.
//!
//! Bundled SQLite (no system libsqlite3 dependency, works the same on the
//! WSL dev box and the cross-compiled Windows build). One row per key, last
//! write wins - this is a snapshot cache, not a history log.

use rusqlite::{params, Connection};
use std::sync::{Mutex, OnceLock};
use std::time::{SystemTime, UNIX_EPOCH};

const LEGACY_DB_PATH: &str = "wow_bridge_cache.sqlite3";

fn db_path() -> std::path::PathBuf {
    if let Ok(exe) = std::env::current_exe() {
        if let Some(bin_dir) = exe.parent() {
            if bin_dir.file_name().and_then(|v| v.to_str()) == Some("bins") {
                if let Some(root) = bin_dir.parent() {
                    return root.join("data/wow_bridge_cache.sqlite3");
                }
            }
        }
    }
    std::path::PathBuf::from("data/wow_bridge_cache.sqlite3")
}

static DB: OnceLock<Mutex<Connection>> = OnceLock::new();

fn db() -> &'static Mutex<Connection> {
    DB.get_or_init(|| {
        let path = db_path();
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent).expect("create cache data directory");
        }
        let legacy = std::path::Path::new(LEGACY_DB_PATH);
        if !path.exists() && legacy.exists() {
            match std::fs::rename(legacy, &path) {
                Ok(()) => println!(
                    "[cache] migrated {} -> {}",
                    legacy.display(),
                    path.display()
                ),
                Err(e) => eprintln!(
                    "[cache] could not migrate {} to {}: {e}",
                    legacy.display(),
                    path.display()
                ),
            }
        }
        let conn = Connection::open(&path).expect("open sqlite cache");
        conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS variables (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL,
                updated_at INTEGER NOT NULL
            );",
        )
        .expect("init sqlite schema");
        Mutex::new(conn)
    })
}

pub(crate) fn display_path() -> std::path::PathBuf {
    db_path()
}

/// Upserts `key`/`value`. Best-effort: a write failure is logged, not
/// propagated - the in-memory cache (the actual source of truth while the
/// process is running) already has the value either way.
pub(crate) fn persist(key: &str, value: &str) {
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0);
    let conn = db().lock().unwrap();
    if let Err(e) = conn.execute(
        "INSERT INTO variables (key, value, updated_at) VALUES (?1, ?2, ?3)
         ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at",
        params![key, value, now],
    ) {
        eprintln!("[cache] failed to persist {key}: {e}");
    }
}

/// Every persisted key/value pair, for `main.rs` to seed the in-memory cache
/// with at startup.
pub(crate) fn load_all() -> Vec<(String, String)> {
    let conn = db().lock().unwrap();
    let mut stmt = match conn.prepare("SELECT key, value FROM variables") {
        Ok(stmt) => stmt,
        Err(e) => {
            eprintln!("[cache] failed to read persisted variables: {e}");
            return Vec::new();
        }
    };
    let rows = match stmt.query_map([], |row| {
        Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
    }) {
        Ok(rows) => rows,
        Err(e) => {
            eprintln!("[cache] failed to read persisted variables: {e}");
            return Vec::new();
        }
    };
    rows.filter_map(Result::ok).collect()
}
