//! The coupling point between the local HTTP API (`api.rs`) and the live
//! game session: outbound values queued here get batched into the addon's
//! next `POLL|` request as it passes through the world relay
//! (`rewrite_addon_poll`), and values the addon whispers back get parsed out
//! of the client->server byte stream (`AddonExtractor`) and stored here too.
//! Nothing outside this module ever touches the underlying state directly.
//!
//! Wire format: both directions can carry several `key=value` pairs in one
//! addon message, joined by `PAIR_DELIM` (ASCII Group Separator, 0x1D) —
//! chosen because it's not used inside any existing value (unlike `;` or
//! `\x1F`, both already meaningful to the addon's own payloads). Batching
//! multiple pairs per message is what actually cuts the whisper-message
//! count during a big status snapshot; a naive one-message-per-key sender
//! looks like whisper flooding to a private server's anti-spam and can get
//! the account disconnected.

use std::collections::{HashMap, VecDeque};
use std::sync::{Condvar, Mutex, OnceLock};
use std::time::{Duration, Instant};

use crate::cache;

const ADDON_MARKER: &[u8] = b"RUSTDATA\t";
const PAIR_DELIM: char = '\u{1D}';

// How fresh a cached value has to be for `get_variable_fresh` (used by
// `/api/read/{key}`) to serve it without triggering a live whisper
// round-trip into the game. Keeps a burst of repeated reads for the same
// key from generating a burst of whispers - most state doesn't change
// meaningfully faster than this.
pub(crate) const READ_FRESHNESS: Duration = Duration::from_secs(3);

static API_VARIABLES: OnceLock<Mutex<HashMap<String, (String, Instant)>>> = OnceLock::new();
// FIFO of writes queued via the HTTP API, waiting to be delivered into the
// game through the next `POLL` rewrite. A key already queued has its value
// replaced in place (position preserved) instead of growing the queue -
// mirrors the addon's own `QueueSend` coalescing on the other side.
static API_PENDING: OnceLock<Mutex<VecDeque<(String, String)>>> = OnceLock::new();

// Event feed for GET /api/stream (api.rs): every DATA|key=value the addon
// sends (or, since the queue_variable fix above, every value set via the
// HTTP API too) bumps the revision under STREAM_EVENT's mutex, appends the
// (key, value) to EVENT_LOG, and wakes every blocked stream handler via the
// condvar - no sleep-and-recheck loop anywhere, a handler thread is fully
// parked until an event actually happens.
//
// EVENT_LOG is a bounded ring, not a single slot - a single slot (the
// original design) silently dropped every event but the last one whenever
// two or more landed between a stream handler's wakeups, which got a lot
// more likely once companion started setting several keys back-to-back
// each cycle (echo_reason, echo_group_budget, echo_suggested, ...) on top
// of the addon's own bursts. A handler now drains every event in
// (last_seen, new_revision] on each wakeup instead of reading just the
// latest, so a burst is delivered in full as long as it fits in the ring
// before the handler catches up - generous for this app's one-or-two local
// subscribers, not meant to survive a subscriber that stalls for a very
// long time.
const EVENT_LOG_CAP: usize = 512;
static STREAM_EVENT: OnceLock<(Mutex<usize>, Condvar)> = OnceLock::new();
static EVENT_LOG: OnceLock<Mutex<VecDeque<(usize, String, String)>>> = OnceLock::new();

fn variables() -> &'static Mutex<HashMap<String, (String, Instant)>> {
    API_VARIABLES.get_or_init(|| Mutex::new(HashMap::new()))
}

fn pending() -> &'static Mutex<VecDeque<(String, String)>> {
    API_PENDING.get_or_init(|| Mutex::new(VecDeque::new()))
}

fn stream_event() -> &'static (Mutex<usize>, Condvar) {
    STREAM_EVENT.get_or_init(|| (Mutex::new(0), Condvar::new()))
}

fn event_log() -> &'static Mutex<VecDeque<(usize, String, String)>> {
    EVENT_LOG.get_or_init(|| Mutex::new(VecDeque::new()))
}

fn publish_event(key: String, value: String) {
    let (revision, ready) = stream_event();
    let mut revision = revision.lock().unwrap();
    *revision += 1;
    let rev = *revision;
    let mut log = event_log().lock().unwrap();
    log.push_back((rev, key, value));
    if log.len() > EVENT_LOG_CAP {
        log.pop_front();
    }
    drop(log);
    ready.notify_all();
}

fn is_live_telemetry(key: &str) -> bool {
    key.starts_with("echo_")
        || key.starts_with("dps_")
        || key.starts_with("ash_")
        || key.starts_with("soul_")
        || key == "hardmode_tier"
        || key == "hero_stats"
        || key == "bridge_world_connected"
}

/// Process-local transport truth. This is intentionally never persisted:
/// restoring yesterday's world connection as online would let stale addon
/// telemetry drive automation while WoW is closed.
pub(crate) fn set_world_connected(connected: bool) {
    let value = if connected { "1" } else { "0" }.to_string();
    variables().lock().unwrap().insert(
        "bridge_world_connected".to_string(),
        (value.clone(), Instant::now()),
    );
    publish_event("bridge_world_connected".to_string(), value);
    if !connected {
        let removed = {
            let mut vars = variables().lock().unwrap();
            let keys = vars
                .keys()
                .filter(|key| {
                    is_live_telemetry(key)
                        && key.as_str() != "bridge_world_connected"
                        && key.as_str() != "echo_auto"
                })
                .cloned()
                .collect::<Vec<_>>();
            for key in &keys {
                vars.remove(key);
            }
            keys
        };
        for key in removed {
            publish_event(key, String::new());
        }
    }
}

pub(crate) fn stream_revision() -> usize {
    *stream_event().0.lock().unwrap()
}

/// Blocks until the stream revision moves past `last_seen`, then returns
/// every event published in (last_seen, new_revision] (in order) plus that
/// new revision, so the caller's next call picks up exactly where this one
/// left off. No polling: parked on the condvar the whole time, woken only by
/// `publish_event`.
pub(crate) fn wait_for_events(last_seen: usize) -> (usize, Vec<(String, String)>) {
    let (revision, ready) = stream_event();
    let guard = revision.lock().unwrap();
    let guard = ready.wait_while(guard, |rev| *rev == last_seen).unwrap();
    let new_seen = *guard;
    drop(guard);
    let log = event_log().lock().unwrap();
    let events = log
        .iter()
        .filter(|(rev, _, _)| *rev > last_seen && *rev <= new_seen)
        .map(|(_, k, v)| (k.clone(), v.clone()))
        .collect();
    (new_seen, events)
}

/// Snapshot of every known key/value pair, for a new `/api/stream` subscriber
/// to replay on connect - otherwise a key that hasn't changed since the
/// subscriber connected would never appear, since the stream only emits new
/// events going forward.
pub(crate) fn all_variables() -> Vec<(String, String)> {
    variables()
        .lock()
        .unwrap()
        .iter()
        .map(|(k, (v, _))| (k.clone(), v.clone()))
        .collect()
}

/// Updates the always-fresh `variables()` cache and publishes to the
/// /api/stream event feed - shared by `report_variable` (dashboard-only, no
/// game delivery) and `queue_variable` (also queues for game delivery).
///
/// The /api/stream publish was found missing while adding companion's
/// echo_reason/echo_group_budget: a value set via the HTTP API updated this
/// cache fine, so a direct GET /api/variables/{key} always saw it, but
/// NEVER reached a live /api/stream subscriber, since only the addon's own
/// inbound DATA| whispers called publish_event(). A stream subscriber would
/// only ever pick up an API-set key via the one-time "replay everything
/// known so far" a fresh connection gets on connect - invisible after that
/// unless the value happened to also get echoed back out by the addon
/// itself. This was masked all session by FlaskGUI dev restarts, each of
/// which re-triggers that replay.
fn update_and_publish(key: String, value: String) {
    variables()
        .lock()
        .unwrap()
        .insert(key.clone(), (value.clone(), Instant::now()));
    cache::persist(&key, &value);
    publish_event(key, value);
}

/// Dashboard-only write: updates the cache and the live stream, but is
/// NEVER queued for delivery into the game. Use this for anything the game
/// client itself has no reason to ever receive (companion's echo_reason/
/// echo_group_budget - EchoTracker.lua never reads either).
///
/// This split exists because of a real, live bug (09-05): `queue_variable`
/// used to be the ONLY write path, so a value like echo_reason (a full
/// multi-clause reasoning string, easily 220+ bytes) ended up sharing the
/// SAME `pending()` FIFO queue as `__lua` (real gameplay commands -
/// SelectPerk/BanishPerk/etc). `take_set_response` below stops dead the
/// moment it hits a queued pair too big to fit in one POLL response - it
/// does NOT skip an oversized item and keep trying smaller ones behind it,
/// and never removes it from the queue either. One oversized echo_reason
/// value landing at the front of that queue silently and PERMANENTLY
/// blocked every real gameplay command queued after it, every single poll,
/// until the process was restarted - with zero error anywhere (not even a
/// Lua compile/runtime error client-side, since the `__lua` payload never
/// even reached the client to be tried). Reproduced live: real Select/
/// Banish/Freeze/Reroll actions stopped taking effect entirely the moment
/// echo_reason started being reported, on an otherwise perfectly healthy
/// connection.
pub(crate) fn report_variable(key: String, value: String) {
    update_and_publish(key, value);
}

/// Stores `value` under `key` and ALSO queues it for delivery to the game
/// via the next addon poll - use only for values the game itself needs to
/// receive (echo_auto, __lua, echo_suggested/echo_suggested_action). See
/// `report_variable` above for anything dashboard-only. A key already
/// waiting in the queue has its value replaced in place rather than
/// growing the queue.
pub(crate) fn queue_variable(key: String, value: String) {
    update_and_publish(key.clone(), value.clone());

    let mut pending = pending().lock().unwrap();
    match pending.iter_mut().find(|(k, _)| *k == key) {
        Some(entry) => entry.1 = value,
        None => pending.push_back((key, value)),
    }
}

pub(crate) fn get_variable(key: &str) -> Option<String> {
    variables().lock().unwrap().get(key).map(|(v, _)| v.clone())
}

/// Like `get_variable`, but only returns a value updated within `max_age` -
/// used by `/api/read/{key}` to skip triggering a live whisper round-trip
/// when a recent-enough answer is already cached.
pub(crate) fn get_variable_fresh(key: &str, max_age: Duration) -> Option<String> {
    let vars = variables().lock().unwrap();
    let (value, updated) = vars.get(key)?;
    (updated.elapsed() <= max_age).then(|| value.clone())
}

pub(crate) fn clear_variable(key: &str) {
    variables().lock().unwrap().remove(key);
}

/// Seeds the in-memory cache from the SQLite-backed store at startup, so a
/// `wow_bridge` restart doesn't come up with an empty cache. Loaded values
/// are backdated past `READ_FRESHNESS` on purpose - we don't actually know
/// how stale they are relative to current game state, so `/api/read/{key}`
/// should still do one live round-trip to confirm the first time it's asked,
/// rather than serving a possibly-months-old value as if it were current.
pub(crate) fn load_persisted() {
    let backdated = Instant::now()
        .checked_sub(READ_FRESHNESS + Duration::from_secs(1))
        .unwrap_or_else(Instant::now);
    let mut vars = variables().lock().unwrap();
    let mut count = 0;
    for (key, value) in cache::load_all() {
        if is_live_telemetry(&key) {
            continue;
        }
        vars.insert(key, (value, backdated));
        count += 1;
    }
    if count > 0 {
        println!(
            "[cache] loaded {count} persisted variable(s) from {}",
            cache::display_path().display()
        );
    }
}

/// Pops as many queued writes as fit into a `SET|...` response of at most
/// `max_len` bytes, joined by `PAIR_DELIM`, and returns it - `"NOP|"` if
/// nothing fits (including an empty queue). Holds the pending-queue lock for
/// the whole build-then-pop so a concurrent `queue_variable` can't observe or
/// create an inconsistent partial pop.
fn take_set_response(max_len: usize) -> String {
    let mut pending = pending().lock().unwrap();
    if pending.is_empty() {
        return "NOP|".to_string();
    }

    // Defense in depth (09-05): this used to `break` on the first pair too
    // big to fit, which - combined with an oversized value ever reaching
    // this queue at all (the real bug, now fixed at the source: see
    // `report_variable` vs `queue_variable` above) - meant one oversized
    // item sitting anywhere in the queue permanently jammed every real
    // gameplay command queued behind it, forever, with no error anywhere.
    // `continue` instead of `break` so an oversized item can never again
    // block smaller ones behind it, no matter how it got here - it's
    // simply skipped and left in the queue for a future, larger POLL
    // payload (or forever, if it's genuinely too big for any POLL, but at
    // least it can never take anything else down with it again).
    let mut body = String::new();
    let mut consumed_indices = Vec::new();
    for (i, (key, value)) in pending.iter().enumerate() {
        let piece_len = key.len() + 1 + value.len() + if body.is_empty() { 0 } else { 1 };
        if "SET|".len() + body.len() + piece_len > max_len {
            continue;
        }
        if !body.is_empty() {
            body.push(PAIR_DELIM);
        }
        body.push_str(key);
        body.push('=');
        body.push_str(value);
        consumed_indices.push(i);
    }

    if consumed_indices.is_empty() {
        return "NOP|".to_string();
    }
    // Reverse order so removing an earlier index doesn't shift the
    // still-to-be-removed later ones out from under us.
    for &i in consumed_indices.iter().rev() {
        pending.remove(i);
    }
    format!("SET|{body}")
}

/// Rewrites an addon `POLL|...` payload in place (client->server bytes, as
/// they pass through the world relay) into a batched `SET|...` response for
/// as many queued API writes as fit, or `NOP|` if nothing's pending.
/// Space-padded to the original payload length since this is a byte-for-byte
/// relay that can't change the packet size; silently gives up if even one
/// `SET|k=v` pair doesn't fit (falls back to `NOP|`, which always fits).
pub(crate) fn rewrite_addon_poll(bytes: &mut [u8]) {
    let Some(marker_start) = bytes
        .windows(ADDON_MARKER.len())
        .position(|window| window == ADDON_MARKER)
    else {
        return;
    };
    let payload_start = marker_start + ADDON_MARKER.len();
    let Some(relative_end) = bytes[payload_start..].iter().position(|byte| *byte == 0) else {
        return;
    };
    let payload_end = payload_start + relative_end;
    let payload = &mut bytes[payload_start..payload_end];
    if !payload.starts_with(b"POLL|") {
        return;
    }

    let response = take_set_response(payload.len());
    if response.len() > payload.len() {
        return;
    }
    payload.fill(b' ');
    payload[..response.len()].copy_from_slice(response.as_bytes());
    if response != "NOP|" {
        println!("[addon-data->game] {response}");
    }
}

/// Scans client->server bytes for `RUSTDATA\t...` addon-message payloads
/// (byte stream may be chunked arbitrarily by TCP, so this buffers across
/// `push` calls). A `DATA|...` payload may carry several `PAIR_DELIM`-joined
/// `key=value` pairs; each is stored so `GET /api/variables/{key}` can read
/// it back and `/api/stream` subscribers see it live.
#[derive(Default)]
pub(crate) struct AddonExtractor {
    pending: Vec<u8>,
}

impl AddonExtractor {
    pub(crate) fn push(&mut self, bytes: &[u8]) {
        self.pending.extend_from_slice(bytes);

        loop {
            let Some(start) = self
                .pending
                .windows(ADDON_MARKER.len())
                .position(|window| window == ADDON_MARKER)
            else {
                let keep = ADDON_MARKER.len().saturating_sub(1);
                if self.pending.len() > keep {
                    self.pending.drain(..self.pending.len() - keep);
                }
                return;
            };
            let payload_start = start + ADDON_MARKER.len();
            let Some(relative_end) = self.pending[payload_start..]
                .iter()
                .position(|byte| *byte == 0)
            else {
                if start > 0 {
                    self.pending.drain(..start);
                }
                if self.pending.len() > 4096 {
                    self.pending.clear();
                }
                return;
            };
            let end = payload_start + relative_end;
            let payload = String::from_utf8_lossy(&self.pending[payload_start..end]);
            if !payload.starts_with("NOP|") {
                println!("[addon-data] {payload}");
            }
            if let Some(data) = payload.strip_prefix("DATA|") {
                for pair in data.split(PAIR_DELIM) {
                    let Some((key, value)) = pair.split_once('=') else {
                        continue;
                    };
                    variables()
                        .lock()
                        .unwrap()
                        .insert(key.to_string(), (value.to_string(), Instant::now()));
                    cache::persist(key, value);
                    publish_event(key.to_string(), value.to_string());
                    println!("[addon-data->api] {key}={value:?}");
                }
            }
            self.pending.drain(..=end);
        }
    }
}
