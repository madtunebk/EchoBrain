//! Auth proxy: relays to the real auth server, decoding and re-encoding just
//! enough of the login protocol to rewrite the realm list's world-server
//! address to point back at our local world proxy.

use std::net::{TcpListener, TcpStream};
use std::thread;

use wow_login_messages::helper::expect_server_message;
use wow_login_messages::version_8::{
    CMD_AUTH_LOGON_CHALLENGE_Server, CMD_AUTH_LOGON_PROOF_Server, CMD_REALM_LIST_Server,
};
use wow_login_messages::ServerMessage;

use crate::common::{debug_log, elapsed_ms, ConnectionSlot, MAX_CONCURRENT_CONNECTIONS};
use crate::net::pump_logged;
use crate::world;

// Hardcoded IP, not the hostname: the hosts-file/DNS override that points
// logon.project-ebonhold.com at this machine (so the client's realmlist can
// stay unmodified) applies to this machine's own DNS resolution too, so
// resolving the hostname here would make the proxy connect to itself in an
// infinite loop instead of reaching the real server.
const REAL_AUTH_ADDR: &str = "91.134.73.169:3724";
// Bind on all interfaces so the WoW client, running on the Windows host (not
// inside WSL), can reach us via the WSL VM's IP address.
const BIND_AUTH_ADDR: &str = "0.0.0.0:3724";
// IP handed to the client in the rewritten realm list. The native Windows
// build uses loopback by default. PROXY_CLIENT_FACING_IP can override this
// when the proxy runs in WSL or on another machine.
const DEFAULT_CLIENT_FACING_IP: &str = "127.0.0.1";

pub(crate) fn run() {
    let listener = TcpListener::bind(BIND_AUTH_ADDR).expect("bind local auth port");
    println!("[auth-proxy] listening on {BIND_AUTH_ADDR}, relaying to {REAL_AUTH_ADDR}");

    for conn in listener.incoming() {
        let client = match conn {
            Ok(c) => c,
            Err(e) => {
                eprintln!("[auth-proxy] accept error: {e}");
                continue;
            }
        };
        let Some(slot) = ConnectionSlot::acquire() else {
            eprintln!(
                "[auth-proxy] at capacity ({MAX_CONCURRENT_CONNECTIONS} connections), dropping new connection \
                 (client is retrying much faster than logins normally complete)"
            );
            continue;
        };
        thread::spawn(move || {
            let _slot = slot;
            handle_auth_conn(client);
        });
    }
}

fn handle_auth_conn(mut client: TcpStream) {
    let peer = client
        .peer_addr()
        .map(|a| a.to_string())
        .unwrap_or_else(|_| "?".to_string());
    debug_log!(
        "[auth-proxy] client connected from {peer} at t={}ms",
        elapsed_ms()
    );
    let mut upstream = match TcpStream::connect(REAL_AUTH_ADDR) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("[auth-proxy] failed to connect upstream: {e}");
            return;
        }
    };

    // client -> real server: raw passthrough, logged.
    let mut client_read = client.try_clone().expect("clone client stream");
    let mut upstream_write = upstream.try_clone().expect("clone upstream stream");
    thread::spawn(move || {
        pump_logged(&mut client_read, &mut upstream_write, "auth c->s");
    });

    // real server -> client: decode just enough to rewrite the realm list.
    if let Err(e) = forward_login_responses(&mut upstream, &mut client) {
        if e.to_string().contains("failed to fill whole buffer") {
            debug_log!("[auth-proxy] server->client relay ended normally: {e}");
        } else {
            eprintln!("[auth-proxy] server->client relay error: {e}");
        }
    }
}

fn forward_login_responses(
    upstream: &mut TcpStream,
    client: &mut TcpStream,
) -> Result<(), Box<dyn std::error::Error>> {
    let client_facing_ip = std::env::var("PROXY_CLIENT_FACING_IP")
        .unwrap_or_else(|_| DEFAULT_CLIENT_FACING_IP.to_string());
    let challenge = expect_server_message::<CMD_AUTH_LOGON_CHALLENGE_Server, _>(&mut *upstream)?;
    debug_log!("[auth-proxy] server->client CMD_AUTH_LOGON_CHALLENGE_Server: {challenge:?}");
    challenge.write(&mut *client)?;

    let is_success = matches!(
        challenge.result,
        wow_login_messages::version_8::CMD_AUTH_LOGON_CHALLENGE_Server_LoginResult::Success { .. }
    );
    if !is_success {
        return Ok(());
    }

    let proof = expect_server_message::<CMD_AUTH_LOGON_PROOF_Server, _>(&mut *upstream)?;
    debug_log!("[auth-proxy] server->client CMD_AUTH_LOGON_PROOF_Server: {proof:?}");
    proof.write(&mut *client)?;

    let is_success = matches!(
        proof.result,
        wow_login_messages::version_8::CMD_AUTH_LOGON_PROOF_Server_LoginResult::Success { .. }
    );
    if !is_success {
        return Ok(());
    }

    // A real login just succeeded - mint a fresh API token for this session.
    // See common.rs's doc comment on why this is the right trigger point
    // (ties the token's lifetime to "there is currently a live logged-in
    // session", not derived from any of the handshake bytes above).
    let token = crate::common::rotate_token();
    println!("[auth] login succeeded - API token rotated (api_token.txt next to this executable)");
    debug_log!("[auth] new token: {token}");

    loop {
        let mut realms = expect_server_message::<CMD_REALM_LIST_Server, _>(&mut *upstream)?;
        debug_log!("[auth-proxy] server->client CMD_REALM_LIST_Server: {realms:?}");

        for realm in &mut realms.realms {
            let port = world::port_for(&realm.address);
            let client_facing = format!("{client_facing_ip}:{port}");
            debug_log!(
                "[auth-proxy] rewriting realm '{}' address {} -> {client_facing}",
                realm.name,
                realm.address
            );
            realm.address = client_facing;
        }

        realms.write(&mut *client)?;
    }
}
