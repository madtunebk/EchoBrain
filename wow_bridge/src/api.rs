//! Local HTTP control-plane API, port 8765, bound to 0.0.0.0 so it's also
//! reachable from the Windows host when this proxy runs inside WSL (the
//! Windows client-facing IP is the WSL VM's address — see
//! `PROXY_CLIENT_FACING_IP` in `auth.rs`). That reachability means anything
//! else on the network could otherwise execute arbitrary Lua in the live
//! game session via `/api/cmd/lua` - every request on every route below now
//! requires `Authorization: Bearer <token>`, checked in `handle_conn`
//! before any route is even parsed. The token lives in `data/api_token.txt`
//! and rotates on process startup and on every successful WoW login (see
//! `common.rs`'s `rotate_token()` - deliberately NOT derived from the login
//! handshake bytes themselves, which are public SRP6 values, not secrets;
//! this never touches or derives anything from the account's actual
//! password). `companion`/FlaskGUI read that same file. Strict contract:
//!
//! - `GET  /api/variables/{key}`  — pure read of the local cache. No side
//!   effects, safe to retry. `__lua` is reserved (400) — see `/api/cmd/lua`.
//! - `POST /api/variables/{key}`  — send a plain string value into the game
//!   via the next addon poll. Body: `{"value": "..."}`. `__lua` is reserved
//!   (400) — see `/api/cmd/lua`. Only for values the game client actually
//!   needs to receive (echo_auto, echo_suggested*) - see `/api/report/{key}`
//!   for anything else. A value here shares one small (~200-byte) POLL
//!   response with `__lua` and everything else queued for game delivery;
//!   an oversized one can starve real gameplay commands queued behind it.
//! - `POST /api/report/{key}`     — same shape as `POST /api/variables/{key}`
//!   but updates the local cache and the `/api/stream` feed ONLY - never
//!   queued for game delivery, so no size limit and no risk of blocking a
//!   real command. Use this for anything dashboard-only that the game
//!   itself never reads (companion's echo_reason/echo_group_budget, etc).
//! - `POST /api/cmd/lua`          — queue Lua code for the addon to run via
//!   `loadstring`/`pcall` on its next poll. Body: `{"value": "..."}`. This
//!   is a full remote-code-exec channel into the live game session.
//! - `POST /api/read/{key}`       — send a Lua snippet that reads the game's
//!   global `{key}` and whispers it back, then block for the answer. This is
//!   POST, not GET: it has a live side effect (a whisper into the game,
//!   queued the same way a `POST /api/variables` write is) and isn't
//!   idempotent — a retried GET would silently re-trigger it.
//! - `GET  /api/stream`            — Server-Sent Events feed: `data: {"key":
//!   "...","value":"..."}` lines, one per `DATA|key=value` the addon sends,
//!   emitted the moment `addon_bridge::AddonExtractor` captures it. Holds
//!   the connection open; consumers should never need to poll
//!   `/api/variables/{key}` on an interval — subscribe to this instead.
//!
//! Every response is JSON; every non-2xx response is `{"error": "..."}`.

use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::thread;
use std::time::{Duration, Instant};

use crate::addon_bridge::{self, clear_variable, get_variable, queue_variable, report_variable};

const API_BIND_ADDR: &str = "0.0.0.0:8765";

pub(crate) fn server() {
    let listener = TcpListener::bind(API_BIND_ADDR).expect("bind local API port");
    println!("[api] listening on http://{API_BIND_ADDR}");
    for stream in listener.incoming() {
        match stream {
            Ok(mut stream) => {
                thread::spawn(move || handle_conn(&mut stream));
            }
            Err(e) => eprintln!("[api] accept error: {e}"),
        }
    }
}

enum Route<'a> {
    Read(&'a str),
    Variable(&'a str),
    Report(&'a str),
    RunLua,
    Unknown,
}

fn parse_route(path: &str) -> Route<'_> {
    if path == "/api/cmd/lua" {
        Route::RunLua
    } else if let Some(key) = path.strip_prefix("/api/read/") {
        Route::Read(key)
    } else if let Some(key) = path.strip_prefix("/api/variables/") {
        Route::Variable(key)
    } else if let Some(key) = path.strip_prefix("/api/report/") {
        Route::Report(key)
    } else {
        Route::Unknown
    }
}

/// Reads a full HTTP/1.1 request off `stream`: loops until the header block
/// (`\r\n\r\n`) has arrived, then — if `Content-Length` is present — loops
/// again until that many body bytes have arrived too. A single `read()` call
/// is not enough: TCP can (and, observed in practice with small POST bodies
/// like ours, does) deliver headers and body in separate chunks, which would
/// otherwise truncate the JSON body and fail with a spurious 400.
fn read_full_request(stream: &mut TcpStream) -> Option<Vec<u8>> {
    let mut buf = Vec::with_capacity(4096);
    let mut chunk = [0_u8; 4096];

    let header_end = loop {
        if let Some(pos) = buf.windows(4).position(|w| w == b"\r\n\r\n") {
            break pos + 4;
        }
        if buf.len() > 65536 {
            return None;
        }
        let n = stream.read(&mut chunk).ok()?;
        if n == 0 {
            return None;
        }
        buf.extend_from_slice(&chunk[..n]);
    };

    let content_length: usize = String::from_utf8_lossy(&buf[..header_end])
        .lines()
        .find_map(|line| {
            let (name, value) = line.split_once(':')?;
            name.eq_ignore_ascii_case("content-length")
                .then(|| value.trim().parse().ok())
                .flatten()
        })
        .unwrap_or(0);

    while buf.len() < header_end + content_length {
        let n = stream.read(&mut chunk).ok()?;
        if n == 0 {
            break;
        }
        buf.extend_from_slice(&chunk[..n]);
    }

    Some(buf)
}

/// Streams `data: {"key":...,"value":...}\n\n` lines as `addon_bridge`
/// publishes new events, until the peer disconnects. No sleep-and-recheck
/// loop: `addon_bridge::wait_for_events` parks this thread on a condvar and
/// only wakes it when an actual event happens — zero work while idle, not
/// even an in-memory check. Drains every event since this handler's own
/// last-seen revision on each wakeup (not just the latest) - see
/// `addon_bridge`'s EVENT_LOG comment for why that matters.
fn handle_stream(stream: &mut TcpStream) {
    let headers = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: keep-alive\r\nAccess-Control-Allow-Origin: *\r\n\r\n";
    if stream.write_all(headers.as_bytes()).is_err() {
        return;
    }

    // Replay everything known so far before switching to live events - a key
    // that hasn't changed since this subscriber connected would otherwise
    // never appear.
    for (key, value) in addon_bridge::all_variables() {
        let payload = serde_json::json!({"key": key, "value": value}).to_string();
        if stream
            .write_all(format!("data: {payload}\n\n").as_bytes())
            .is_err()
        {
            return;
        }
    }

    let mut last_seen = addon_bridge::stream_revision();
    loop {
        let (new_seen, events) = addon_bridge::wait_for_events(last_seen);
        last_seen = new_seen;
        for (key, value) in events {
            let payload = serde_json::json!({"key": key, "value": value}).to_string();
            if stream
                .write_all(format!("data: {payload}\n\n").as_bytes())
                .is_err()
            {
                return;
            }
        }
    }
}

/// Loops over requests on the SAME connection (HTTP/1.1 keep-alive) rather
/// than handling exactly one and returning - each accepted connection gets
/// its own thread (see `server()` below), so looping here just keeps that
/// one thread alive across a client's repeated polls instead of tearing
/// down and re-establishing a fresh TCP connection (and spawning a fresh
/// thread) for every single request. Was `Connection: close` before,
/// forcing every `WowBridge.get()` call from Python to pay a full TCP
/// handshake - with echo_autopilot.py polling 8-11 keys every 1.5s, that
/// was real, avoidable overhead on both sides. Safe to loop without
/// implementing HTTP pipelining: read_full_request only ever consumes
/// exactly one request's bytes off the stream, and the only client here
/// (sdk/python/wow_bridge.py) sends requests one at a time, waiting for
/// each response before the next - never pipelines - so there's never a
/// second request's bytes sitting in the stream when we go back to read.
/// Pulls the bearer token out of an `Authorization: Bearer <token>` header,
/// if present - case-insensitive header name, matching HTTP's own rules.
fn extract_bearer_token(request: &str) -> Option<&str> {
    request.lines().find_map(|line| {
        let (name, value) = line.split_once(':')?;
        name.eq_ignore_ascii_case("authorization")
            .then(|| value.trim().strip_prefix("Bearer "))
            .flatten()
    })
}

fn is_authorized(request: &str) -> bool {
    extract_bearer_token(request).is_some_and(crate::common::check_token)
}

fn write_unauthorized(stream: &mut TcpStream) {
    let body = serde_json::json!({"error": "unauthorized - missing or invalid Authorization: Bearer <token> (see api_token.txt next to this executable)"}).to_string();
    let response = format!(
        "HTTP/1.1 401 Unauthorized\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
        body.len()
    );
    let _ = stream.write_all(response.as_bytes());
}

fn handle_conn(stream: &mut TcpStream) {
    loop {
        let Some(buf) = read_full_request(stream) else {
            return;
        };
        let request = String::from_utf8_lossy(&buf);
        let mut lines = request.lines();
        let Some(first) = lines.next() else { return };
        let mut parts = first.split_whitespace();
        let method = parts.next().unwrap_or("");
        let path = parts.next().unwrap_or("");

        // Every route requires the current bearer token - see common.rs's
        // rotate_token() doc comment for why (this port is reachable from
        // outside this machine on purpose, so the WoW client on the Windows
        // host can reach it out of WSL; that same reachability otherwise
        // means anything else on the network could execute arbitrary Lua in
        // the live game via /api/cmd/lua).
        if !is_authorized(&request) {
            write_unauthorized(stream);
            return;
        }

        if method == "GET" && path == "/api/stream" {
            handle_stream(stream);
            return;
        }

        let body = request.split("\r\n\r\n").nth(1).unwrap_or("");

        let (status, response_body) = route(method, parse_route(path), body);

        let response = format!(
            "HTTP/1.1 {status}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: keep-alive\r\n\r\n{response_body}",
            response_body.len()
        );
        if stream.write_all(response.as_bytes()).is_err() {
            return;
        }
    }
}

/// The only place route -> verb -> handler mapping is decided. Adding a verb
/// to a route, or a route entirely, means touching this match — nothing else
/// in this module inspects `method`/`path` again.
fn route(method: &str, r: Route, body: &str) -> (&'static str, String) {
    match (r, method) {
        (Route::Read(key), "POST") => handle_read(key),
        (Route::Read(_), _) => method_not_allowed("POST"),
        (Route::RunLua, "POST") => handle_run_lua(body),
        (Route::RunLua, _) => method_not_allowed("POST"),
        (Route::Variable(key), "GET") => handle_get_variable(key),
        (Route::Variable(key), "POST") => handle_post_variable(key, body),
        (Route::Variable(_), _) => method_not_allowed("GET, POST"),
        (Route::Report(key), "POST") => handle_post_report(key, body),
        (Route::Report(_), _) => method_not_allowed("POST"),
        (Route::Unknown, _) => not_found(),
    }
}

fn ok_json(key: &str, value: &str) -> (&'static str, String) {
    (
        "200 OK",
        serde_json::json!({"key": key, "value": value}).to_string(),
    )
}

fn err(status: &'static str, message: &str) -> (&'static str, String) {
    (status, serde_json::json!({"error": message}).to_string())
}

fn not_found() -> (&'static str, String) {
    err("404 Not Found", "not found")
}

fn method_not_allowed(allowed: &str) -> (&'static str, String) {
    err(
        "405 Method Not Allowed",
        &format!("method not allowed, expected {allowed}"),
    )
}

/// True if `key` is safe to splice directly into generated Lua source as a
/// bare identifier, and safe to embed in the in-game `SET|key=value` wire
/// payload without corrupting its framing. Applied to every route that takes
/// a `{key}`, not just `/api/read/`.
fn is_lua_identifier(key: &str) -> bool {
    let mut chars = key.chars();
    matches!(chars.next(), Some(c) if c.is_ascii_alphabetic() || c == '_')
        && chars.all(|c| c.is_ascii_alphanumeric() || c == '_')
}

fn bad_key() -> (&'static str, String) {
    err(
        "400 Bad Request",
        "key must be a plain Lua identifier (letters, digits, underscore)",
    )
}

fn reserved_key() -> (&'static str, String) {
    err(
        "400 Bad Request",
        "__lua is reserved - use POST /api/cmd/lua to run Lua",
    )
}

fn handle_get_variable(key: &str) -> (&'static str, String) {
    if key == "__lua" {
        return reserved_key();
    }
    if !is_lua_identifier(key) {
        return bad_key();
    }
    match get_variable(key) {
        Some(value) => ok_json(key, &value),
        None => not_found(),
    }
}

fn handle_post_variable(key: &str, body: &str) -> (&'static str, String) {
    if key == "__lua" {
        return reserved_key();
    }
    if !is_lua_identifier(key) {
        return bad_key();
    }
    match serde_json::from_str::<serde_json::Value>(body)
        .ok()
        .and_then(|v| v.get("value")?.as_str().map(str::to_string))
    {
        Some(value) => {
            queue_variable(key.to_string(), value.clone());
            println!("[api] set {key}={value:?}");
            ok_json(key, &value)
        }
        None => err("400 Bad Request", "expected JSON string value"),
    }
}

/// Like `handle_post_variable`, but for a value the game client has no
/// reason to ever receive - updates the cache and the live /api/stream feed
/// only, via `report_variable` (see its doc comment for the real bug this
/// split fixes: a dashboard-only value sharing the same delivery queue as
/// real gameplay Lua commands could - and did - permanently jam them if it
/// was ever too big to fit in one POLL response). `__lua` doesn't need its
/// own reserved-key check here the way `handle_post_variable` has one -
/// nothing should ever report through this path with that name, and if it
/// somehow did, "reported but never delivered" is a safe failure mode for
/// this endpoint (unlike accidentally queuing arbitrary code for delivery).
fn handle_post_report(key: &str, body: &str) -> (&'static str, String) {
    if !is_lua_identifier(key) {
        return bad_key();
    }
    match serde_json::from_str::<serde_json::Value>(body)
        .ok()
        .and_then(|v| v.get("value")?.as_str().map(str::to_string))
    {
        Some(value) => {
            report_variable(key.to_string(), value.clone());
            ok_json(key, &value)
        }
        None => err("400 Bad Request", "expected JSON string value"),
    }
}

/// Queues `body.value` as Lua for the addon to run via `loadstring`/`pcall`
/// on its next poll - the dedicated, explicit entry point for what is
/// otherwise a full remote-code-exec channel into the live game session.
fn handle_run_lua(body: &str) -> (&'static str, String) {
    match serde_json::from_str::<serde_json::Value>(body)
        .ok()
        .and_then(|v| v.get("value")?.as_str().map(str::to_string))
    {
        Some(code) => {
            queue_variable("__lua".to_string(), code.clone());
            println!("[api] queued lua: {code:?}");
            ok_json("lua", &code)
        }
        None => err("400 Bad Request", "expected JSON string value"),
    }
}

/// Generates the Lua needed to read the global variable named `key` and
/// whisper it back to the player's own character (always a valid whisper
/// target, no addon-side setup beyond DataBridge being loaded), queues it
/// for the next poll, then blocks until the answer comes back through
/// `addon_bridge::AddonExtractor` or a timeout elapses. This is the "just
/// give me the value" endpoint — no manual `SendAddonMessage` required from
/// the caller.
fn handle_read(key: &str) -> (&'static str, String) {
    if !is_lua_identifier(key) {
        return bad_key();
    }
    if let Some(value) = addon_bridge::get_variable_fresh(key, addon_bridge::READ_FRESHNESS) {
        return ok_json(key, &value);
    }
    clear_variable(key);

    let lua = format!(
        r#"SendAddonMessage("RUSTDATA", "DATA|{key}="..tostring({key}), "WHISPER", UnitName("player"))"#
    );
    queue_variable("__lua".to_string(), lua);
    println!("[api] reading {key} from game...");

    let deadline = Instant::now() + Duration::from_secs(6);
    loop {
        if let Some(value) = get_variable(key) {
            return ok_json(key, &value);
        }
        if Instant::now() >= deadline {
            return err(
                "504 Gateway Timeout",
                "no response from game (is DataBridge loaded and logged in?)",
            );
        }
        thread::sleep(Duration::from_millis(100));
    }
}
