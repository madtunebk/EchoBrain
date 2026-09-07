// Diagnostic MITM relay: sits between the real WoW client and the real
// Ebonhold servers so we can see exactly what a real client sends, without
// needing Wireshark, and so the DataBridge addon can exchange data with
// external tools through it. Point the client's realmlist.wtf at 127.0.0.1
// and log in normally.
//
// Auth proxy (127.0.0.1:3724) relays to the real auth server, decoding and
// re-encoding just enough of the login protocol to rewrite each realm's
// world-server address to point back at our local world proxy.
//
// World proxy (127.0.0.1:8085+) is a byte-for-byte relay to the real world
// server, logging every byte in both directions with a direction tag.
//
// See `api.rs` for the local HTTP control-plane API, `addon_bridge.rs` for
// how it talks to the in-game addon, `auth.rs`/`world.rs` for the two relay
// halves, and `net.rs`/`common.rs` for shared plumbing.

mod addon_bridge;
mod api;
mod auth;
mod cache;
mod common;
mod net;
mod world;

fn main() {
    addon_bridge::load_persisted();
    addon_bridge::set_world_connected(false);
    let token = common::rotate_token();
    println!("[auth] API token written next to this executable as api_token.txt (rotates again on next login)");
    println!("[auth] token: {token}");
    std::thread::spawn(api::server);
    auth::run();
}
