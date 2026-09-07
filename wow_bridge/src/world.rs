//! World proxy: a dumb byte-for-byte relay to the real world server, one
//! dedicated local port per distinct real realm address (so which realm the
//! player picks in-game determines which real server we relay to).

use std::collections::HashMap;
use std::net::{TcpListener, TcpStream};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Mutex, OnceLock};
use std::thread;

use crate::common::{debug_log, ConnectionSlot, MAX_CONCURRENT_CONNECTIONS};
use crate::net::{pump_logged, pump_logged_extract_addon};

// Each distinct real world server gets its own local port starting here, so
// that which realm the player picks in-game determines which real server we
// relay to (a single shared port can't tell realms apart).
const FIRST_WORLD_PORT: u16 = 8085;

// real world server address -> local port relaying to it.
static WORLD_PORTS: OnceLock<Mutex<HashMap<String, u16>>> = OnceLock::new();
static NEXT_WORLD_PORT: OnceLock<Mutex<u16>> = OnceLock::new();
static ACTIVE_WORLD_CONNECTIONS: AtomicUsize = AtomicUsize::new(0);

struct WorldConnectionGuard;

impl WorldConnectionGuard {
    fn connected() -> Self {
        if ACTIVE_WORLD_CONNECTIONS.fetch_add(1, Ordering::SeqCst) == 0 {
            crate::addon_bridge::set_world_connected(true);
        }
        Self
    }
}

impl Drop for WorldConnectionGuard {
    fn drop(&mut self) {
        if ACTIVE_WORLD_CONNECTIONS.fetch_sub(1, Ordering::SeqCst) == 1 {
            crate::addon_bridge::set_world_connected(false);
        }
    }
}

/// Returns the local port relaying to `real_addr`, starting a dedicated
/// world-proxy listener for it the first time it's seen.
pub(crate) fn port_for(real_addr: &str) -> u16 {
    let ports = WORLD_PORTS.get_or_init(|| Mutex::new(HashMap::new()));
    let mut ports = ports.lock().unwrap();
    if let Some(&port) = ports.get(real_addr) {
        return port;
    }

    let next_port = NEXT_WORLD_PORT.get_or_init(|| Mutex::new(FIRST_WORLD_PORT));
    let mut next_port = next_port.lock().unwrap();
    let port = *next_port;
    *next_port += 1;

    ports.insert(real_addr.to_string(), port);
    let real_addr = real_addr.to_string();
    thread::spawn(move || world_proxy(port, real_addr));
    port
}

fn world_proxy(port: u16, real_addr: String) {
    let bind_addr = format!("0.0.0.0:{port}");
    let listener = TcpListener::bind(&bind_addr).expect("bind local world port");
    debug_log!("[world-proxy] listening on {bind_addr}, relaying to {real_addr}");

    for conn in listener.incoming() {
        let client = match conn {
            Ok(c) => c,
            Err(e) => {
                eprintln!("[world-proxy] accept error: {e}");
                continue;
            }
        };
        let Some(slot) = ConnectionSlot::acquire() else {
            eprintln!("[world-proxy] at capacity ({MAX_CONCURRENT_CONNECTIONS} connections), dropping new connection");
            continue;
        };
        let real_addr = real_addr.clone();
        thread::spawn(move || {
            let _slot = slot;
            handle_world_conn(client, real_addr);
        });
    }
}

fn handle_world_conn(mut client: TcpStream, real_addr: String) {
    debug_log!("[world-proxy] client connected, relaying to real world server {real_addr}");

    let mut upstream = match TcpStream::connect(&real_addr) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("[world-proxy] failed to connect upstream {real_addr}: {e}");
            return;
        }
    };
    let _world_connection = WorldConnectionGuard::connected();

    let mut client_read = client.try_clone().expect("clone client stream");
    let mut upstream_write = upstream.try_clone().expect("clone upstream stream");
    let c2s = thread::spawn(move || {
        pump_logged_extract_addon(&mut client_read, &mut upstream_write, "world c->s");
    });

    pump_logged(&mut upstream, &mut client, "world s->c");
    let _ = c2s.join();
}
