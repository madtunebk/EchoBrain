//! Generic byte-for-byte TCP relay used by both the auth and world proxies.

use std::io::{Read, Write};
use std::net::{Shutdown, TcpStream};

use crate::addon_bridge::{self, AddonExtractor};
use crate::common::debug_log;

/// Raw byte relay from `src` to `dst`, printing every chunk read with a
/// direction tag so we can see exactly what went over the wire.
///
/// When `src` closes or errors, `dst` is shut down too so the peer on that
/// side (which may be blocked reading, waiting for a reply that will never
/// come) sees the closure immediately instead of hanging forever on a
/// half-relayed connection.
pub(crate) fn pump_logged(src: &mut TcpStream, dst: &mut TcpStream, tag: &str) {
    pump_logged_inner(src, dst, tag, None);
}

/// Same relay as `pump_logged`, but also rewrites addon `POLL|` payloads in
/// transit and extracts `DATA|key=value` payloads — see `addon_bridge`.
pub(crate) fn pump_logged_extract_addon(src: &mut TcpStream, dst: &mut TcpStream, tag: &str) {
    let mut extractor = AddonExtractor::default();
    pump_logged_inner(src, dst, tag, Some(&mut extractor));
}

fn pump_logged_inner(
    src: &mut TcpStream,
    dst: &mut TcpStream,
    tag: &str,
    mut extractor: Option<&mut AddonExtractor>,
) {
    let mut buf = [0u8; 4096];
    loop {
        let n = match src.read(&mut buf) {
            Ok(0) => {
                debug_log!("[{tag}] connection closed");
                let _ = dst.shutdown(Shutdown::Both);
                return;
            }
            Ok(n) => n,
            Err(e) => {
                eprintln!("[{tag}] read error: {e}");
                let _ = dst.shutdown(Shutdown::Both);
                return;
            }
        };
        debug_log!("[{tag}] {n} bytes: {:02x?}", &buf[..n]);
        if let Some(extractor) = extractor.as_mut() {
            addon_bridge::rewrite_addon_poll(&mut buf[..n]);
            extractor.push(&buf[..n]);
        }
        if let Err(e) = dst.write_all(&buf[..n]) {
            eprintln!("[{tag}] write error: {e}");
            let _ = src.shutdown(Shutdown::Both);
            return;
        }
    }
}
