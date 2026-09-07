//! Shared plumbing used by every other module in this binary: debug logging,
//! a monotonic clock for log timestamps, and the connection-count guard.

macro_rules! debug_log {
    ($($arg:tt)*) => {
        if cfg!(debug_assertions) {
            println!($($arg)*);
        }
    };
}
pub(crate) use debug_log;

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::OnceLock;
use std::time::Instant;

static START: OnceLock<Instant> = OnceLock::new();

pub(crate) fn elapsed_ms() -> u128 {
    START.get_or_init(Instant::now).elapsed().as_millis()
}

// Caps concurrent proxied connections so a client stuck in a fast reconnect
// loop exhausts a bounded number of file descriptors/threads instead of
// crashing the whole proxy (thread::spawn panics if the OS can't create a
// new thread, which would otherwise take the whole process down).
pub(crate) const MAX_CONCURRENT_CONNECTIONS: usize = 64;
static ACTIVE_CONNECTIONS: AtomicUsize = AtomicUsize::new(0);

/// RAII guard that reserves one of the `MAX_CONCURRENT_CONNECTIONS` slots,
/// releasing it on drop. `acquire` returns `None` if the proxy is already at
/// capacity, in which case the caller should refuse the connection.
pub(crate) struct ConnectionSlot;

impl ConnectionSlot {
    pub(crate) fn acquire() -> Option<Self> {
        let mut current = ACTIVE_CONNECTIONS.load(Ordering::Relaxed);
        loop {
            if current >= MAX_CONCURRENT_CONNECTIONS {
                return None;
            }
            match ACTIVE_CONNECTIONS.compare_exchange_weak(
                current,
                current + 1,
                Ordering::Relaxed,
                Ordering::Relaxed,
            ) {
                Ok(_) => return Some(ConnectionSlot),
                Err(observed) => current = observed,
            }
        }
    }
}

impl Drop for ConnectionSlot {
    fn drop(&mut self) {
        ACTIVE_CONNECTIONS.fetch_sub(1, Ordering::Relaxed);
    }
}

// ---------------------------------------------------------------------------
// API bearer token - closes the "anyone who can reach this port can execute
// arbitrary Lua in the live game" hole (`/api/cmd/lua` binds 0.0.0.0 so the
// WoW client, running on the Windows host out of WSL, can reach the proxy;
// that same reachability means anything else on the network could too).
//
// Not derived from the WoW login handshake bytes themselves (`B`/salt in
// `CMD_AUTH_LOGON_CHALLENGE_Server`) - those are the server's PUBLIC SRP6
// values, sent in the clear, so using them as token material would give zero
// extra security over plain randomness (anyone who could see that traffic
// could reconstruct the same "secret"). SRP6 is specifically designed so a
// passive/relaying observer - which is all this proxy is here, since it
// never sees the account password or the client's private ephemeral value -
// can't derive the real session key either.
//
// Instead: real OS randomness (/dev/urandom), regenerated at two points -
// once at process startup (so the API is never unprotected) and again every
// time `auth.rs` observes a successful login (`CMD_AUTH_LOGON_PROOF_Server`
// succeeding) - tying the token's lifetime to "there is currently a live
// logged-in session" the way the user actually wanted, without needing any
// of WoW's own SRP6 crypto. A stale token from a previous session stops
// working the moment a new login happens, which also directly helps the
// separate "stale persisted state can drive automation" concern - a client
// still holding yesterday's token can't silently keep acting once a fresh
// session has started.
static API_TOKEN: OnceLock<std::sync::Mutex<String>> = OnceLock::new();

/// Anchored to THIS EXECUTABLE'S OWN directory, not a `data/`-relative path
/// off the current working directory - wow_bridge and companion are
/// launched from inconsistent cwds in practice (`bins/` vs the repo root),
/// which would otherwise resolve to two different files and silently break
/// this entirely. Both binaries are always deployed side by side into the
/// same `bins/` directory, so anchoring to `current_exe()`'s parent reaches
/// the same file regardless of which directory either process happens to be
/// launched from.
fn token_file_path() -> std::path::PathBuf {
    std::env::current_exe()
        .ok()
        .and_then(|p| p.parent().map(|d| d.join("api_token.txt")))
        .unwrap_or_else(|| std::path::PathBuf::from("api_token.txt"))
}

fn random_token() -> String {
    use std::io::Read;
    let mut bytes = [0u8; 32];
    std::fs::File::open("/dev/urandom")
        .and_then(|mut f| f.read_exact(&mut bytes))
        .expect("read /dev/urandom for API token");
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn persist_token(token: &str) {
    if let Some(parent) = token_file_path().parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    if let Err(e) = std::fs::write(token_file_path(), token) {
        eprintln!(
            "[auth] warning: failed to persist API token to {}: {e}",
            token_file_path().display()
        );
    }
}

/// Generates and stores a brand new token, persisting it to `data/api_token.txt`
/// for `companion`/FlaskGUI to read - call once at process startup and again
/// on every successful login.
pub(crate) fn rotate_token() -> String {
    let token = random_token();
    let slot = API_TOKEN.get_or_init(|| std::sync::Mutex::new(String::new()));
    *slot.lock().unwrap() = token.clone();
    persist_token(&token);
    token
}

/// True if `presented` matches the current token via constant-time
/// comparison (a plain `==` on secrets is a real, if minor, timing-attack
/// surface - cheap to avoid).
pub(crate) fn check_token(presented: &str) -> bool {
    let slot = API_TOKEN.get_or_init(|| std::sync::Mutex::new(String::new()));
    let expected = slot.lock().unwrap();
    if expected.is_empty() || presented.len() != expected.len() {
        return false;
    }
    let mut diff = 0u8;
    for (a, b) in expected.bytes().zip(presented.bytes()) {
        diff |= a ^ b;
    }
    diff == 0
}
