#!/usr/bin/env python3
"""EchoTracker Live — real-time web view of EchoTracker.lua's telemetry.

Was "MainDataBridge V3 Armory": a much bigger dashboard (health/power/xp/
equipment/combat) built for an addon called "MainDataBridge" that was never
actually written - none of those fields ever had real data. Stripped down to
just the one thing that's real: EchoTracker.lua's own echo_*/ash_*/
hardmode_tier/soul_points keys, which really do flow through wow_bridge's
/api/stream today.
"""
import json
import os
import sqlite3
import threading
import time
import urllib.error
import urllib.request

from flask import Flask, Response, jsonify, request
from flask_sock import Sock
from simple_websocket import ConnectionClosed

# wow_bridge binds 0.0.0.0:8765 (api.rs) on this SAME machine as this Flask
# app, so loopback always reaches it. Was hardcoded to a specific WSL guest
# IP (172.23.0.1) that only happened to be correct once - WSL2's NAT address
# for this machine shifts across sessions/reboots (observed live: this
# machine was actually 172.23.1.210, not .0.1 - a stale hardcoded address
# was the entire reason this page showed OFFLINE with both processes
# running fine). 127.0.0.1 has no such drift.
WOW_PROXY_API = os.environ.get("WOW_PROXY_API", "http://127.0.0.1:8765")
RECONNECT_BACKOFF_S = 2.0

# data/session.db lives at the repo root (companion/session_db.rs's own
# "data/session.db" is relative to ITS OWN cwd, normally the repo root too),
# not inside FlaskGUI/ - resolved from this file's own location so it works
# regardless of which directory this app is launched from.
SESSION_DB_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "data", "session.db")
DESCRIPTIONS_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "data", "perk_descriptions.json")
# {spellId: {"icon": ..., "name": ...}} for the whole catalog - built once via
# tools/export/export_perk_icons.py, same idea as DESCRIPTIONS_PATH above.
ICONS_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "data", "perk_display.json")
# companion/src/item_cache.rs's cache - arbitrary (procedurally named) item
# names WhitelistLiquidator's wl_equipped/wl_whitelist no longer send over
# the wire (see that file's own comments). companion populates this file in
# the background; this dashboard only ever reads it.
ITEM_CACHE_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "data", "cache", "items.sqlite3")
ICON_CACHE_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "assets", "icons")
ICON_REMOTE_BASE = "https://wow.zamimg.com/images/wow/icons/large"
ICON_MISS_TTL_S = 24 * 60 * 60

# wow_bridge now requires Authorization: Bearer <token> on every request
# (closes "anyone who can reach this port can run arbitrary Lua in the live
# game" - the API binds 0.0.0.0 so the WoW client on the Windows host can
# reach it out of WSL, which also makes it reachable from the rest of the
# network). The token rotates on every wow_bridge startup AND on every real
# WoW login, so this is re-read on every reconnect attempt rather than
# cached once - see companion/src/bridge.rs's current_token() for the same
# logic on that side. Anchored to bins/ (a sibling of this file's own
# directory), not a cwd-relative path, matching where wow_bridge actually
# writes it (next to its own executable) regardless of which directory
# either process happens to be launched from.
TOKEN_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "bins", "api_token.txt")


def _current_token():
    try:
        with open(TOKEN_PATH) as f:
            return f.read().strip()
    except OSError:
        return ""

app = Flask(__name__)
sock = Sock(app)
_lock = threading.Lock()
_ws_lock = threading.Lock()
_ws_clients: set = set()
_latest = {"connected": False}
_icon_cache_lock = threading.Lock()


def _apply_event(key, value):
    if not key:
        return
    _latest[key] = value


def _broadcast():
    with _lock:
        payload = json.dumps(_latest)
    dead = []
    with _ws_lock:
        clients = list(_ws_clients)
    for client in clients:
        try:
            client.send(payload)
        except Exception:
            dead.append(client)
    if dead:
        with _ws_lock:
            _ws_clients.difference_update(dead)


def _stream_loop():
    print(f"[stream] connecting to {WOW_PROXY_API}/api/stream", flush=True)
    while True:
        try:
            request = urllib.request.Request(
                f"{WOW_PROXY_API}/api/stream",
                headers={"Authorization": f"Bearer {_current_token()}"},
            )
            with urllib.request.urlopen(request, timeout=None) as response:
                with _lock:
                    _latest["connected"] = True
                _broadcast()
                for raw_line in response:
                    line = raw_line.decode("utf-8", "replace").strip()
                    if not line.startswith("data:"):
                        continue
                    event = json.loads(line[5:].strip())
                    with _lock:
                        _apply_event(event.get("key", ""), event.get("value", ""))
                    _broadcast()
            # The for-loop above is only ever supposed to end when the peer
            # actually closes the TCP connection - wow_bridge's /api/stream
            # never sends a Content-Length or chunked framing (see api.rs's
            # handle_stream), just "Connection: keep-alive" plus raw
            # "data: ...\n\n" lines forever. Some http.client versions treat
            # that combination as an already-complete zero-length body and
            # return from the for-loop immediately with NO exception - which
            # used to skip straight past the `except` block below (the only
            # place a backoff sleep lived) and reconnect instantly, forever,
            # hammering wow_bridge with a tight replay-everything loop. Now
            # falls through to the same backoff as a real error.
            print("[stream] stream ended unexpectedly, reconnecting...", flush=True)
        except Exception as exc:
            print(f"[stream] {exc!r}", flush=True)
        with _lock:
            _latest["connected"] = False
        _broadcast()
        time.sleep(RECONNECT_BACKOFF_S)


threading.Thread(target=_stream_loop, daemon=True).start()


@app.get("/status")
def status():
    with _lock:
        return dict(_latest)


# ---------------------------------------------------------------------------
# WhitelistLiquidator gear-watchdog controls. wl_status/wl_equipped/
# wl_whitelist/wl_unequip_alert already arrive for free through the same
# /api/stream -> _latest -> websocket path every other key uses (the addon
# pushes them via DataBridge_Send - see WhitelistLiquidator.lua - and
# _apply_event has no allowlist), so no new plumbing was needed to read them.
# Only the ACTION side needs new routes: a browser button can't reach
# wow_bridge's /api/cmd/lua directly (it requires the bearer token, which
# this process already reads for the /api/stream connection), so these just
# forward a short Lua call into WhitelistLiquidatorRemote - the same global
# surface companion's own `wl` subcommand calls (see companion/src/main.rs's
# wl_cmd). wow_bridge stays a dummy transport either way.
# ---------------------------------------------------------------------------
def _wl_lua_call(code):
    try:
        req = urllib.request.Request(
            f"{WOW_PROXY_API}/api/cmd/lua",
            data=json.dumps({"value": code}).encode("utf-8"),
            headers={
                "Authorization": f"Bearer {_current_token()}",
                "Content-Type": "application/json",
            },
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=5) as resp:
            resp.read()
        return True, None
    except Exception as exc:
        return False, str(exc)


def _wl_result(ok, err):
    return jsonify({"ok": ok, "error": err}), (200 if ok else 502)


def _wl_item_id():
    data = request.get_json(silent=True) or {}
    try:
        return int(data.get("id"))
    except (TypeError, ValueError):
        return None


@app.post("/api/wl/protect")
def wl_protect():
    return _wl_result(*_wl_lua_call("WhitelistLiquidatorRemote.Protect()"))


@app.post("/api/wl/dismiss")
def wl_dismiss():
    return _wl_result(*_wl_lua_call("WhitelistLiquidatorRemote.Dismiss()"))


@app.post("/api/wl/clean")
def wl_clean():
    return _wl_result(*_wl_lua_call("WhitelistLiquidatorRemote.Clean()"))


@app.post("/api/wl/add")
def wl_add():
    item_id = _wl_item_id()
    if item_id is None:
        return jsonify({"ok": False, "error": "missing/invalid id"}), 400
    return _wl_result(*_wl_lua_call(f"WhitelistLiquidatorRemote.Add({item_id})"))


@app.post("/api/wl/remove")
def wl_remove():
    item_id = _wl_item_id()
    if item_id is None:
        return jsonify({"ok": False, "error": "missing/invalid id"}), 400
    return _wl_result(*_wl_lua_call(f"WhitelistLiquidatorRemote.Remove({item_id})"))


@app.get("/api/descriptions")
def descriptions():
    """Static full Echo descriptions exported from the game.

    This avoids squeezing long tooltip text through DataBridge's small
    per-message payload. Live echo_tips_* remains a fallback for entries that
    are absent from the export.
    """
    try:
        with open(DESCRIPTIONS_PATH, encoding="utf-8") as source:
            return jsonify(json.load(source))
    except (OSError, ValueError) as exc:
        return jsonify({"error": str(exc)}), 500


@app.get("/api/perk_icons")
def perk_icons():
    """Static {spellId: {icon, name}} for the whole catalog, exported from
    the game once (see ICONS_PATH's own comment). Live echo_icons_* remains a
    fallback for the handful of currently-locked slots, in case a spellId is
    ever missing here (e.g. a catalog entry added after the last export).
    """
    try:
        with open(ICONS_PATH, encoding="utf-8") as source:
            return jsonify(json.load(source))
    except (OSError, ValueError) as exc:
        return jsonify({"error": str(exc)}), 500


@app.get("/api/wl/item_names")
def wl_item_names():
    """{item_id: name} for every item companion's item_cache.rs has resolved
    so far - see ITEM_CACHE_PATH's own comment. Small (a whitelist's worth
    of items, not thousands), so the whole thing is returned at once rather
    than one lookup per id; an id missing here just means companion hasn't
    resolved it yet (it will, in the background, next time it's seen).
    """
    if not os.path.exists(ITEM_CACHE_PATH):
        return jsonify({})
    try:
        conn = sqlite3.connect(f"file:{ITEM_CACHE_PATH}?mode=ro", uri=True)
        try:
            rows = conn.execute("SELECT id, name FROM items").fetchall()
            return jsonify({str(item_id): name for item_id, name in rows})
        finally:
            conn.close()
    except sqlite3.Error as exc:
        return jsonify({"error": str(exc)}), 500


@app.get("/api/icon/<icon_key>")
def cached_icon(icon_key):
    """Serve an Echo icon from disk, fetching it once on first request."""
    if not icon_key or len(icon_key) > 100 or any(
        ch not in "abcdefghijklmnopqrstuvwxyz0123456789_-" for ch in icon_key
    ):
        return Response("invalid icon key", status=400, mimetype="text/plain")

    os.makedirs(ICON_CACHE_DIR, exist_ok=True)
    cached_path = os.path.join(ICON_CACHE_DIR, f"{icon_key}.jpg")
    missing_path = os.path.join(ICON_CACHE_DIR, f"{icon_key}.missing")

    # A few custom/server spell icons use client filenames that do not exist
    # on the public icon CDN. Remember a 404 for one day instead of performing
    # the same doomed external request every time History redraws.
    try:
        missing_age = time.time() - os.path.getmtime(missing_path)
        if missing_age < ICON_MISS_TTL_S:
            return Response(
                "icon unavailable",
                status=404,
                mimetype="text/plain",
                headers={"Cache-Control": "public, max-age=86400"},
            )
        os.remove(missing_path)
    except OSError:
        pass
    try:
        with open(cached_path, "rb") as source:
            data = source.read()
    except OSError:
        data = None

    if data is None:
        # Serialize misses so concurrent requests cannot leave a partial file.
        # Cache hits never take this lock.
        with _icon_cache_lock:
            try:
                with open(cached_path, "rb") as source:
                    data = source.read()
            except OSError:
                try:
                    request = urllib.request.Request(
                        f"{ICON_REMOTE_BASE}/{icon_key}.jpg",
                        headers={"User-Agent": "EchoTracker/1.0"},
                    )
                    with urllib.request.urlopen(request, timeout=10) as response:
                        data = response.read(2 * 1024 * 1024 + 1)
                    if not data or len(data) > 2 * 1024 * 1024:
                        raise ValueError("empty or oversized icon response")
                    temp_path = f"{cached_path}.tmp-{threading.get_ident()}"
                    with open(temp_path, "wb") as target:
                        target.write(data)
                    os.replace(temp_path, cached_path)
                except urllib.error.HTTPError as exc:
                    if exc.code == 404:
                        with open(missing_path, "wb") as marker:
                            marker.write(b"")
                        print(f"[icons] {icon_key}: remote icon not found (cached for 24h)", flush=True)
                        return Response(
                            "icon unavailable",
                            status=404,
                            mimetype="text/plain",
                            headers={"Cache-Control": "public, max-age=86400"},
                        )
                    print(f"[icons] {icon_key}: {exc!r}", flush=True)
                    return Response("icon unavailable", status=502, mimetype="text/plain")
                except Exception as exc:
                    print(f"[icons] {icon_key}: {exc!r}", flush=True)
                    return Response("icon unavailable", status=502, mimetype="text/plain")

    return Response(
        data,
        mimetype="image/jpeg",
        headers={"Cache-Control": "public, max-age=31536000, immutable"},
    )


@sock.route("/ws")
def ws(connection):
    with _ws_lock:
        _ws_clients.add(connection)
    with _lock:
        connection.send(json.dumps(_latest))
    try:
        while True:
            connection.receive()
    except ConnectionClosed:
        pass
    finally:
        with _ws_lock:
            _ws_clients.discard(connection)


PAGE = r'''<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>EchoTracker Live</title>
<style>
:root{--bg:#06080c;--text:#edf4ff;--muted:#7e91aa;--line:#28374b;--gold:#f3c65a;--green:#42df91;--red:#ff6374;--class:#8b98aa}
*{box-sizing:border-box}html,body{margin:0;min-height:100%;background:var(--bg);color:var(--text);font-family:Inter,system-ui,-apple-system,"Segoe UI",sans-serif}
body{padding:16px}.shell{max-width:1100px;margin:auto}
.top{display:flex;align-items:center;justify-content:space-between;height:38px;margin-bottom:6px}
.brand{font:800 11px ui-monospace,monospace;letter-spacing:.18em;text-transform:uppercase;color:#b4c1d2}.brand b{color:var(--gold)}
.live{display:flex;gap:8px;align-items:center;font:800 10px ui-monospace,monospace;color:var(--muted);letter-spacing:.12em}
.dot{width:8px;height:8px;border-radius:50%;background:var(--red);box-shadow:0 0 15px var(--red)}.dot.up{background:var(--green);box-shadow:0 0 15px var(--green)}
.idbar{display:flex;gap:12px;align-items:center;font:800 11px ui-monospace,monospace;margin-bottom:14px;color:var(--muted)}
.idbar .badge{border:1px solid color-mix(in srgb,var(--class) 60%,var(--line));background:color-mix(in srgb,var(--class) 18%,#0b1119);color:#fff;border-radius:999px;padding:5px 12px;letter-spacing:.1em}
.idbar b{color:var(--gold)}
.layout{display:grid;grid-template-columns:minmax(0,1.05fr) minmax(320px,.95fr);gap:10px}
.col{display:grid;gap:10px;align-content:start}
.card{border:1px solid var(--line);border-radius:16px;background:linear-gradient(180deg,#0f1721,#0a0f16);padding:14px;min-width:0}
.ct{display:flex;justify-content:space-between;align-items:center;color:var(--muted);font-size:9px;text-transform:uppercase;letter-spacing:.14em;margin-bottom:11px}
.ct strong{color:#c3d0e0;font-size:9px}
.quick{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:8px}
.q{background:#080d14;border:1px solid #1d2938;border-radius:11px;padding:9px;min-width:0}
.q small{display:block;color:var(--muted);font-size:8px;text-transform:uppercase;letter-spacing:.08em}
.q b{display:block;margin-top:4px;font:900 13px ui-monospace,monospace;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.gearcol{display:grid;gap:6px}
.boardgrid{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:8px}
.boardgrid .slot{grid-template-columns:56px minmax(0,1fr) auto;min-width:0}
.boardgrid .slot .ico{width:54px;height:54px}
.boardgrid.processed .slot{opacity:.72;filter:saturate(.72)}
.slot{display:grid;grid-template-columns:42px minmax(0,1fr) auto;gap:8px;align-items:center;min-height:53px;padding:6px 8px;background:#080d14;border:1px solid #1c2938;border-radius:11px;position:relative;overflow:hidden}
.slot:after{content:"";position:absolute;left:0;bottom:0;height:2px;width:100%;background:var(--qc,#425166);opacity:.8}
.slot .ico{width:40px;height:40px;border-radius:8px;border:1px solid var(--qc,#425166);display:grid;place-items:center;font:900 10px ui-monospace,monospace;color:var(--qc,#90a0b5);background:#0e1620;position:relative;overflow:hidden}
.slot .ico img{width:100%;height:100%;object-fit:cover;display:block}
.slot .ico .fallback{position:absolute;inset:0;display:grid;place-items:center;background:#0e1620}
.slot .ico.hasimg .fallback{display:none}
.slot .sn{min-width:0}.slot .sn b{display:block;font-size:11px;color:var(--qc,#aab8ca);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.slot .sn small{display:block;color:#657892;font-size:8px;margin-top:3px}
.slot .ilvl{font:800 10px ui-monospace,monospace;color:#91a5be}
.empty{color:#647790;font-size:11px}
.iconstrip{display:grid;grid-template-columns:repeat(6,minmax(0,1fr));gap:12px;justify-items:center;align-items:center}
.tile{width:clamp(56px,7vw,80px);aspect-ratio:1;height:auto;border-radius:12px;border:2px solid var(--qc,#425166);position:relative;overflow:hidden;background:#0e1620;cursor:default}
.tile:hover{border-color:color-mix(in srgb,var(--qc,#425166) 78%,#fff);box-shadow:0 0 0 1px color-mix(in srgb,var(--qc,#425166) 28%,transparent),0 6px 18px #0008}
.tile img{width:100%;height:100%;object-fit:cover;display:block}
.tile .fallback{position:absolute;inset:0;display:grid;place-items:center;font:900 8px ui-monospace,monospace;color:var(--qc,#90a0b5);background:#0e1620}
.tile.hasimg .fallback{display:none}
.tile .stack{position:absolute;bottom:1px;right:3px;font:900 9px ui-monospace,monospace;color:#fff;text-shadow:0 1px 3px #000}
.footer{display:flex;justify-content:space-between;color:#41536d;font:700 8px ui-monospace,monospace;margin:10px 2px}
.reasontext{font-size:11px;color:#c3d0e0;line-height:1.5}
.reasontext .rline{padding:5px 0;border-bottom:1px solid #1a232f}
.reasontext .rline:last-child{border-bottom:none}
.reasonstate{font-weight:900}
.reasonstate.active{color:var(--green)}
.reasonstate.processed{color:var(--gold)}
.reasonstate.idle{color:#647790}
.budgethead{font-size:8px;color:var(--muted);text-transform:uppercase;letter-spacing:.1em;margin:12px 0 6px}
.budgetrow{display:grid;grid-template-columns:52px minmax(0,1fr) 54px;gap:8px;align-items:center;margin-top:6px}
.budgetrow label{font-size:9px;color:var(--muted);text-transform:uppercase;letter-spacing:.06em}
.budgettrack{height:8px;border-radius:999px;background:#05080d;border:1px solid #1f2b3a;overflow:hidden}
.budgetfill{height:100%;border-radius:999px}
.budgetrow b{font:800 10px ui-monospace,monospace;text-align:right}
.rawfeed{max-height:360px;overflow:auto;display:grid;gap:2px;font:11px ui-monospace,monospace}
.rawrow{display:grid;grid-template-columns:220px minmax(0,1fr);gap:10px;padding:4px 6px;border-radius:6px}
.rawrow:nth-child(odd){background:#0a0f16}
.rawrow .k{color:var(--muted);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.rawrow .v{color:#d7e2f0;white-space:pre-wrap;word-break:break-all}
.histtable-wrap{overflow-x:auto}
.histtable{width:100%;border-collapse:collapse;font:11px ui-monospace,monospace;white-space:nowrap}
.histtable th{text-align:left;color:var(--muted);font-size:8px;text-transform:uppercase;letter-spacing:.08em;padding:6px 8px;border-bottom:1px solid var(--line)}
.histtable td{padding:6px 8px;border-bottom:1px solid #141b26;color:#c3d0e0}
.histtable tr:hover td{background:#0c131d}
.tabs{display:flex;gap:6px;margin:0 0 12px}.tabbtn{border:1px solid var(--line);border-radius:999px;background:#090f17;color:var(--muted);padding:7px 16px;font:800 9px ui-monospace,monospace;letter-spacing:.12em;cursor:pointer}.tabbtn.active{border-color:var(--gold);color:var(--gold);background:#17150d}.tabpane{display:none}.tabpane.active{display:block}
.histtable tbody tr{cursor:pointer}.histtable tbody tr.selected td{background:#152030;color:#fff}
.decisionlist{display:grid;gap:8px}.decision{border:1px solid #1d2a3a;border-radius:12px;background:#080d14;overflow:hidden}.decision summary{list-style:none;display:grid;grid-template-columns:64px 72px minmax(120px,1fr) 90px;gap:10px;align-items:center;padding:11px 12px;cursor:pointer;font:800 10px ui-monospace,monospace}.decision summary::-webkit-details-marker{display:none}.decision .act{font-weight:950}.decision .TAKE{color:var(--green)}.decision .FREEZE{color:#2699ff}.decision .BANISH{color:var(--red)}.decision .REROLL{color:var(--gold)}.decision .status{text-align:right;color:var(--muted);font-size:8px;text-transform:uppercase}.decisionbody{padding:0 12px 12px;border-top:1px solid #172231}.decisioncards{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:7px;margin-top:10px}.dcard{border:1px solid var(--qc,#354459);border-radius:9px;padding:9px;min-width:0}.dcard b{display:block;color:var(--qc,#fff);white-space:nowrap;overflow:hidden;text-overflow:ellipsis;font-size:10px}.dcard small{display:flex;justify-content:space-between;color:var(--muted);margin-top:5px;font:8px ui-monospace,monospace}.dcard.target{box-shadow:0 0 0 2px color-mix(in srgb,var(--qc,#fff) 65%,transparent)}.dreasons{margin-top:9px;color:#bac9da;font-size:10px;line-height:1.5}.dreason{padding:4px 0;border-bottom:1px solid #15202d}.dmeta{margin-top:8px;color:#647790;font:8px ui-monospace,monospace;word-break:break-word}
.dcard{display:grid;grid-template-columns:42px minmax(0,1fr);gap:8px;align-items:center;padding:7px;cursor:default}.dicon{width:40px;height:40px;border:1px solid var(--qc,#354459);border-radius:7px;background:#0e1620;display:grid;place-items:center;overflow:hidden;color:var(--muted);font:7px ui-monospace,monospace}.dicon img{width:100%;height:100%;object-fit:cover}.dinfo{min-width:0}
@media(max-width:820px){.layout{grid-template-columns:1fr}.quick{grid-template-columns:1fr 1fr}.rawrow{grid-template-columns:1fr}.iconstrip{grid-template-columns:repeat(3,minmax(0,1fr))}.boardgrid{grid-template-columns:1fr}}
.slot{cursor:default}.slot:hover{border-color:color-mix(in srgb,var(--qc,#425166) 78%,#fff);background:#0c131d;box-shadow:0 0 0 1px color-mix(in srgb,var(--qc,#425166) 28%,transparent),0 10px 30px #0008}
#wowtip{position:fixed;z-index:9999;width:min(280px,calc(100vw - 24px));pointer-events:none;display:none;padding:10px 12px;border:1px solid #6f5e33;border-radius:5px;background:linear-gradient(180deg,rgba(10,10,12,.98),rgba(3,4,6,.98));box-shadow:0 14px 45px #000,inset 0 0 0 1px #000;color:#fff;font:12px/1.35 Arial,sans-serif;text-shadow:1px 1px #000}
#wowtip .tiptitle{font-size:14px;font-weight:700;margin-bottom:2px}
#wowtip .tipsub{color:#ffd100;font-size:11px;margin-bottom:4px}
#wowtip .tipline{color:#e2ddce;white-space:pre-wrap}
#wowtip .tipid{color:#666f7b;margin-top:6px;font-size:9px;border-top:1px solid #252a31;padding-top:5px}
.wlalert{position:fixed;top:14px;left:50%;transform:translateX(-50%);z-index:10000;display:none;gap:14px;align-items:center;background:linear-gradient(180deg,#2a0a0a,#170505);border:2px solid #ff3d3d;border-radius:14px;padding:10px 16px;box-shadow:0 0 20px #ff3d3d55;animation:wlpulse 1s infinite}
@keyframes wlpulse{0%,100%{box-shadow:0 0 20px #ff3d3d55}50%{box-shadow:0 0 36px #ff3d3dcc}}
.wlalert-text{font:800 12px ui-monospace,monospace;color:#ffdada}
.wlalert-text b{color:#ff5959}
.wlalert-actions{display:flex;gap:8px}
.wlalert-actions button{border:1px solid #ff6374;background:#1a0808;color:#fff;border-radius:8px;padding:6px 12px;font:800 10px ui-monospace,monospace;cursor:pointer;letter-spacing:.06em}
.wlalert-actions button:hover{background:#2a0d0d}
.wlsub{display:flex;justify-content:space-between;align-items:center;color:var(--muted);font-size:9px;text-transform:uppercase;letter-spacing:.12em;margin:14px 0 6px}
.wladdform{display:flex;gap:6px;text-transform:none;letter-spacing:0}
.wladdform input{width:90px;background:#080d14;border:1px solid #1c2938;border-radius:6px;color:var(--text);font:11px ui-monospace,monospace;padding:4px 6px}
.wladdform button{border:1px solid var(--line);background:#0f1721;color:var(--text);border-radius:6px;padding:4px 10px;font:800 9px ui-monospace,monospace;cursor:pointer}
.wlrows{display:grid;gap:4px;font:11px ui-monospace,monospace;max-height:220px;overflow:auto}
.wlrow{display:flex;justify-content:space-between;align-items:center;gap:8px;padding:5px 8px;border-radius:8px;background:#080d14;border:1px solid #1c2938}
.wlrow .wltag{font:800 8px ui-monospace,monospace;padding:2px 7px;border-radius:999px;letter-spacing:.06em;white-space:nowrap}
.wlrow .wltag.P,.wlrow .wltag.A{background:#0d2b1c;color:#42df91}
.wlrow .wltag.U{background:#2b0d0d;color:#ff6374}
.wlrow button{border:1px solid var(--line);background:#0f1721;color:#ff9d9d;border-radius:6px;padding:2px 8px;font:800 9px ui-monospace,monospace;cursor:pointer;flex-shrink:0}
</style></head><body><main class="shell">
<div id="wlAlertBanner" class="wlalert"><div class="wlalert-text"><b>GEAR UNEQUIPPED</b> <span id="wlAlertItem"></span></div><div class="wlalert-actions"><button id="wlProtectBtn">PROTECT</button><button id="wlDismissBtn">DISMISS</button></div></div>
<div class="top"><div class="brand"><b>EchoTracker</b> // Live</div><div class="live"><span id="dot" class="dot"></span><span id="conn">CONNECTING</span></div></div>
<nav class="tabs"><button class="tabbtn active" data-tab="liveTab">LIVE</button><button class="tabbtn" data-tab="historyTab">HISTORY</button></nav>
<div id="liveTab" class="tabpane active">
<div class="idbar"><span class="badge" id="classBadge">Unknown Class</span><span>Level <b id="echoLevel">--</b></span></div>
<div class="layout"><div class="col">
<section class="card"><div class="ct"><span>Current Board</span><strong id="boardState" class="reasonstate idle">IDLE</strong></div><div class="boardgrid" id="echoBoard"></div></section>
<section class="card"><div class="ct"><span>AI Reasoning</span><strong id="reasonState" class="reasonstate idle">IDLE</strong></div><div id="echoReasonText" class="reasontext"><div class="empty">No decision recorded yet.</div></div></section>
<section class="card"><div class="ct"><span>Locked (Permanent)</span><strong id="echoLockedMax">0/0</strong></div><div class="iconstrip" id="echoLocked"></div></section>
</div><div class="col">
<section class="card"><div class="ct"><span>Charges</span><strong>THIS RUN</strong></div><div class="quick">
<div class="q"><small>Reroll</small><b id="echoReroll">0/0</b></div>
<div class="q"><small>Banish Left</small><b id="echoBanish">0</b></div>
<div class="q"><small>Freeze</small><b id="echoFreeze">0/0</b></div>
</div><div id="budgetGroup"></div></section>
<section class="card"><div class="ct"><span>Progression</span><strong>PRESTIGE / TORMENT</strong></div><div class="quick">
<div class="q"><small>Prestiges</small><b id="ashPrestiges">0</b></div>
<div class="q"><small>Ash Bonus</small><b id="ashBonus">0%</b></div>
<div class="q"><small>Hardmode Tier</small><b id="hardmodeTier">1</b></div>
<div class="q"><small>Soul Points</small><b id="soulPoints">0</b></div>
<div class="q"><small>Owned (distinct)</small><b id="echoOwnedDistinct">0</b></div>
<div class="q"><small>Owned (stacks)</small><b id="echoOwnedStacks">0</b></div>
</div></section>
</div></div>
<section class="card" style="margin-top:10px"><div class="ct"><span>Gear Watchdog</span><strong id="wlWhitelistCount">0 whitelisted</strong></div>
<div class="quick">
<div class="q"><small>Protected in bags</small><b id="wlProtectedQty">0</b></div>
<div class="q"><small>Auto-protected</small><b id="wlAutoQty">0</b></div>
<div class="q"><small>Sell qty</small><b id="wlSellQty">0</b></div>
<div class="q"><small>Destroy qty</small><b id="wlDestroyQty">0</b></div>
</div>
<div class="wlsub">Equipped Slots</div>
<div id="wlEquippedList" class="wlrows"><div class="empty">No equipped-item data yet.</div></div>
<div class="wlsub">Whitelist<span class="wladdform"><input id="wlAddInput" placeholder="item id" inputmode="numeric"><button id="wlAddBtn">Add</button></span></div>
<div id="wlWhitelistList" class="wlrows"><div class="empty">Whitelist is empty.</div></div>
</section>
<section class="card" style="margin-top:10px"><div class="ct"><span>Raw wow_bridge Feed</span><strong id="rawCount">0 keys</strong></div><div id="rawFeed" class="rawfeed"></div></section>
</div>
<div id="historyTab" class="tabpane">
<section class="card"><div class="ct"><span>Run History</span><strong id="historyCount">0 sessions</strong></div><div class="histtable-wrap"><table class="histtable"><thead><tr><th>#</th><th>Character</th><th>Started</th><th>Duration</th><th>Class / Spec</th><th>Level</th><th>Take</th><th>Banish</th><th>Freeze</th><th>Reroll</th><th>Fights</th><th>Avg DPS</th><th>Max DPS</th><th>Prestige</th><th>Tier</th></tr></thead><tbody id="historyBody"></tbody></table></div></section>
<section class="card" style="margin-top:10px"><div class="ct"><span>Decision Timeline</span><strong id="decisionCount">SELECT A RUN</strong></div><div id="decisionList" class="decisionlist"><div class="empty">Select a session above to inspect every board and choice.</div></div></section>
</div>
<div class="footer"><span>Lua → Rust SSE → Flask WS · event driven</span><span id="stamp">waiting for telemetry…</span></div>
</main><div id="wowtip"></div>
<script>
const C={DEATHKNIGHT:'#c41e3a',DRUID:'#ff7c0a',HUNTER:'#aad372',MAGE:'#3fc7eb',PALADIN:'#f48cba',PRIEST:'#ffffff',ROGUE:'#fff468',SHAMAN:'#0070dd',WARLOCK:'#8788ee',WARRIOR:'#c69b6d'};
// Echo quality is NOT Blizzard's standard item-quality scale (which has a
// leading gray "Poor" tier at 0) - this project's own scale starts one tier
// later: 0=Common(white) 1=Uncommon(green) 2=Rare(blue) 3=Epic(purple)
// 4=Legendary(orange), no Poor tier at all (matches EchoTracker.lua's own
// ECHO_QUALITY_COLORS exactly). Reusing the Blizzard array here rendered
// every quality-3 (Epic) echo as blue (Rare in the WRONG scale) instead of
// purple - confirmed live: this account's 6 locked echoes are all quality 3
// and all showed blue.
const Q=['#ffffff','#1eff00','#0070dd','#a335ee','#ff8000'];
const $=x=>document.getElementById(x);
const fmt=x=>Number(x||0).toLocaleString();
document.querySelectorAll('.tabbtn').forEach(btn=>btn.addEventListener('click',()=>{
  document.querySelectorAll('.tabbtn').forEach(b=>b.classList.toggle('active',b===btn));
  document.querySelectorAll('.tabpane').forEach(p=>p.classList.toggle('active',p.id===btn.dataset.tab));
  if(btn.dataset.tab==='historyTab')loadHistory();
}));
function text(id,v,f='-'){
  let e=$(id);if(!e)return;
  let next=String((v===null||v===undefined||v==='')?f:v);
  if(e.textContent!==next)e.textContent=next;
}
function esc(v){return String(v??'').replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]))}
// Raw feed: `d` already carries EVERY key wow_bridge has ever broadcast (not
// just the curated echo_*/ash_* ones rendered above) - this just dumps all
// of it, sorted, so you can watch DataBridge's actual wire traffic live
// (any addon, any key) instead of only what this page bothered to parse.
// esc() matters here specifically: some values are arbitrary game/addon
// text (e.g. `__lua` holds a whole Lua statement) rendered via innerHTML.
// Patch rows in place instead of replacing the complete feed on every push.
// The websocket carries a full snapshot, but normally only one key differs;
// recreating all rows made the large debug feed visibly flash and reset its
// scroll/render state several times during one telemetry burst.
const rawRows=new Map(),rawValues=new Map();
function rawString(v){return v!==null&&typeof v==='object'?JSON.stringify(v):String(v??'')}
function renderRaw(d){
  let keys=Object.keys(d).filter(k=>k!=='connected').sort(),feed=$('rawFeed');
  text('rawCount',keys.length+' keys');
  for(const k of keys){
    let value=rawString(d[k]);
    if(rawValues.get(k)===value)continue;
    rawValues.set(k,value);
    let row=rawRows.get(k);
    if(!row){
      row=document.createElement('div');row.className='rawrow';
      let key=document.createElement('span');key.className='k';key.textContent=k;
      let val=document.createElement('span');val.className='v';
      row.append(key,val);rawRows.set(k,row);
      let before=[...feed.children].find(el=>el.firstChild&&el.firstChild.textContent>k);
      feed.insertBefore(row,before||null);
    }
    row.lastChild.textContent=value;
  }
  for(const [k,row] of rawRows){if(!Object.prototype.hasOwnProperty.call(d,k)){row.remove();rawRows.delete(k);rawValues.delete(k)}}
}
const ECHO_SPELL_BASE=200000;
function echoCards(raw,kind){if(!raw)return [];return String(raw).split(';').filter(Boolean).map(p=>{let parts=p.split(':');if(kind==='locked')return {spellId:Number(parts[0]||0)+ECHO_SPELL_BASE,stack:Number(parts[1]||1),quality:Number(parts[2]||0),flags:''};return {spellId:Number(parts[0]||0)+ECHO_SPELL_BASE,quality:Number(parts[1]||0),flags:parts[2]||''}})}
function echoCharges(raw){let out={reroll:'0/0',banish:'0',freeze:'0/0'};if(!raw)return out;String(raw).split(';').forEach(p=>{let i=p.indexOf(':');if(i>0)out[p.slice(0,i)]=p.slice(i+1)});return out}
function echoOwnedTotals(d){let n=Number(d.echo_owned_count||0),distinct=0,stacks=0;for(let i=1;i<=n;i++){let chunk=d['echo_owned_'+i];if(!chunk)continue;chunk.split(';').filter(Boolean).forEach(p=>{let stack=Number(p.split(':')[1]||0);distinct+=1;stacks+=stack})}return {distinct,stacks}}
// echo_reason: companion's decide() reasoning trail for the current
// suggestion/action, "|"-joined (plain text - these are our own generated
// strings, never raw game text, so no exotic separator needed).
const REASON_STORAGE_KEY='echotracker.lastReason.v1';
let lastReason='';
try{lastReason=localStorage.getItem(REASON_STORAGE_KEY)||''}catch(_e){}
let reasonSig='\0';
function setReasonState(state){
  let el=$('reasonState');
  if(!el)return;
  let cls='reasonstate '+state;
  if(el.className!==cls)el.className=cls;
  let label=state.toUpperCase();
  if(el.textContent!==label)el.textContent=label;
}
function renderReason(d){
  let raw=d.echo_reason||'';
  if(raw){
    lastReason=raw;
    try{localStorage.setItem(REASON_STORAGE_KEY,raw)}catch(_e){}
  }
  let shown=raw||lastReason;
  let state=raw?'active':(shown?'processed':'idle');
  let nextSig=state+'\0'+shown;
  if(nextSig===reasonSig)return;
  reasonSig=nextSig;
  setReasonState(state);
  let el=$('echoReasonText');
  if(!shown){el.innerHTML='<div class="empty">No decision recorded yet.</div>';return}
  el.innerHTML=shown.split(' | ').map(r=>`<div class="rline">${esc(r)}</div>`).join('');
}
// echo_group_budget: "<lo+1>-<hi>|reroll:spent/alloc;banish:...;freeze:..."
// - this 20-level group's charge burn rate, from companion's
// apply_group_quota. Missing resources (alloc not yet known this session)
// are simply absent from the string.
function echoGroupBudget(raw){
  if(!raw)return null;
  let bar=raw.indexOf('|');
  if(bar<0)return null;
  let out={range:raw.slice(0,bar)};
  raw.slice(bar+1).split(';').filter(Boolean).forEach(p=>{
    let [res,sa]=p.split(':');
    let [spent,alloc]=(sa||'0/0').split('/').map(Number);
    out[res]={spent,alloc};
  });
  return out;
}
function budgetBarHTML(label,b){
  if(!b)return '';
  let pct=b.alloc>0?Math.min(100,b.spent/b.alloc*100):0;
  let left=b.alloc-b.spent;
  let color=left<=0?'#ff6374':(pct>=75?'#f3c65a':'#42df91');
  return `<div class="budgetrow"><label>${esc(label)}</label><div class="budgettrack"><div class="budgetfill" style="width:${pct}%;background:${color}"></div></div><b>${b.spent}/${b.alloc}</b></div>`;
}
let budgetSig='\0';
function renderBudget(d){
  let raw=d.echo_group_budget||'';
  if(raw===budgetSig)return;
  budgetSig=raw;
  let b=echoGroupBudget(raw);
  let el=$('budgetGroup');
  if(!b){el.innerHTML='';return}
  el.innerHTML=`<div class="budgethead">Group Lv ${esc(b.range)} Budget</div>`+budgetBarHTML('Reroll',b.reroll)+budgetBarHTML('Banish',b.banish)+budgetBarHTML('Freeze',b.freeze);
}
// WhitelistLiquidator's wl_* exports (WoW_AddOns/WhitelistLiquidator/
// WhitelistLiquidator.lua) - same record(";")/field(unit separator 0x1f)
// convention as echo_tips above. Still used by wl_equipped (slot/id/tag)
// and wl_unequip_alert (id/name/slot - that one's a single record, no
// bandwidth concern, so it still carries a name directly); wl_whitelist is
// now just bare ids with no field separator at all, see loadWlItemNames.
const WL_FS=String.fromCharCode(31);
const WL_TAG_LABEL={P:'protected',A:'auto',U:'UNPROTECTED'};
function wlParseStatus(raw){
  let s={whitelist:0,protected:0,auto:0,sellQty:0,destroyQty:0};
  if(!raw)return s;
  raw.split(';').forEach(p=>{let i=p.indexOf('=');if(i<0)return;let k=p.slice(0,i);if(k in s)s[k]=Number(p.slice(i+1))||0});
  return s;
}
function wlParseRecords(raw){return raw?raw.split(';').filter(Boolean).map(r=>r.split(WL_FS)):[]}
// Generic reassembly for anything the addon side sent via
// DataBridge_SendLarge (WoW_AddOns/DataBridge/DataBridge.lua): <key>_1,
// <key>_2, ... <key>_count - used whenever a single value would exceed
// DataBridge_Send's own ~220-byte cap (wl_equipped/wl_whitelist today,
// echo_owned/echo_icons on the EchoTracker side use the same convention).
// Joining chunks back with ";" reproduces the original list: a chunk never
// splits a record in half. Any future chunked key can reuse this directly.
function chunked(d,baseKey){
  let n=Number(d[baseKey+'_count']||0),parts=[];
  for(let i=1;i<=n;i++){let c=d[baseKey+'_'+i];if(c)parts.push(c)}
  return parts.join(';');
}
// Item names no longer travel over the wire at all (wl_equipped/
// wl_whitelist send bare ids now - see WhitelistLiquidator.lua's own
// comments on why: procedurally-generated per-server text can't be
// pre-baked into a static file the way echo names can). companion resolves
// them in the background into data/cache/items.sqlite3; this just reads
// that cache via /api/wl/item_names. Refreshed periodically since the
// cache fills in slowly, one item at a time - a name arriving after the
// initial render still needs to update the already-drawn rows.
let wlItemNames={};
function wlItemName(id){return wlItemNames[id]||('Item #'+id)}
function loadWlItemNames(){
  fetch('/api/wl/item_names').then(r=>r.ok?r.json():{}).then(names=>{
    if(!names||typeof names!=='object'||names.error)return;
    wlItemNames=names;
    wlEquippedSig='';wlWhitelistSig=''; // force a redraw with any newly-resolved names
    if(latestSnapshot)scheduleRender(latestSnapshot);
  }).catch(()=>{});
}
loadWlItemNames();
setInterval(loadWlItemNames,10000);

let wlEquippedSig='',wlWhitelistSig='';
function renderWatchdog(d){
  let s=wlParseStatus(d.wl_status||'');
  text('wlWhitelistCount',s.whitelist+' whitelisted');
  text('wlProtectedQty',s.protected);
  text('wlAutoQty',s.auto);
  text('wlSellQty',s.sellQty);
  text('wlDestroyQty',s.destroyQty);

  let equippedRaw=chunked(d,'wl_equipped');
  if(equippedRaw!==wlEquippedSig){
    wlEquippedSig=equippedRaw;
    let rows=wlParseRecords(equippedRaw);
    $('wlEquippedList').innerHTML=rows.length?rows.map(([slot,id,tag])=>
      `<div class="wlrow"><span>${esc(wlItemName(id))}</span><span class="wltag ${esc(tag)}">${esc(WL_TAG_LABEL[tag]||tag)}</span></div>`
    ).join(''):'<div class="empty">No equipped-item data yet.</div>';
  }

  let whitelistRaw=chunked(d,'wl_whitelist');
  if(whitelistRaw!==wlWhitelistSig){
    wlWhitelistSig=whitelistRaw;
    let ids=whitelistRaw?whitelistRaw.split(';').filter(Boolean):[];
    $('wlWhitelistList').innerHTML=ids.length?ids.map(id=>
      `<div class="wlrow"><span>${esc(wlItemName(id))} <span style="color:var(--muted)">[${esc(id)}]</span></span><button data-wl-remove="${esc(id)}">Remove</button></div>`
    ).join(''):'<div class="empty">Whitelist is empty.</div>';
  }

  let alertRaw=d.wl_unequip_alert||'',banner=$('wlAlertBanner');
  if(alertRaw){
    let [id,name]=alertRaw.split(WL_FS);
    banner.style.display='flex';
    text('wlAlertItem',(name||('Item '+id))+' is unprotected in your bags');
  } else {
    banner.style.display='none';
  }
}
function wlPost(url,body){
  return fetch(url,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body||{})}).catch(()=>{});
}
$('wlProtectBtn').addEventListener('click',()=>wlPost('/api/wl/protect'));
$('wlDismissBtn').addEventListener('click',()=>wlPost('/api/wl/dismiss'));
$('wlAddBtn').addEventListener('click',()=>{
  let id=Number($('wlAddInput').value);
  if(!id)return;
  wlPost('/api/wl/add',{id}).then(()=>{$('wlAddInput').value=''});
});
$('wlWhitelistList').addEventListener('click',e=>{
  let btn=e.target.closest('[data-wl-remove]');
  if(btn)wlPost('/api/wl/remove',{id:Number(btn.dataset.wlRemove)});
});
// echo_icons_N/_count: a separate chunked key (EchoTracker.lua's PackIcons/
// SendChunked) carrying spellId:iconkey:name triples - kept deliberately OUT
// of echo_board/echo_locked's own fields (those feed companion's live
// decide/auto loop and are already near DataBridge_Send's byte cap; icon
// keys/names are just for this page). Split on the first TWO colons only,
// greedily keeping everything after as the name - a name is never assumed
// colon-free. As of 2026-09-08 this only ever covers the handful of
// currently-locked slots (board icon/name never varies with context, so
// it's covered entirely by the static /api/perk_icons fetch below instead -
// see PackIcons's own comment on the addon side). Chunks are not an atomic
// snapshot: EchoTracker deliberately sends at most four changed keys per
// refresh, so a lock-state change can temporarily expose a mix of old and
// new icon chunks. Keep every resolved spell asset by ID instead of making
// a transient missing chunk erase an icon we already loaded.
const ICON_STORAGE_KEY='echotracker.knownIcons.v1';
const knownIcons={};
try{Object.assign(knownIcons,JSON.parse(localStorage.getItem(ICON_STORAGE_KEY)||'{}'))}catch(_e){}
let iconSaveTimer=0,historyAssetTimer=0;
function persistKnownIcons(){
  if(iconSaveTimer)return;
  iconSaveTimer=setTimeout(()=>{iconSaveTimer=0;try{localStorage.setItem(ICON_STORAGE_KEY,JSON.stringify(knownIcons))}catch(_e){}},500);
}
const catalogIcons={};
function echoIconMap(d){let n=Number(d.echo_icons_count||0),changed=false;for(let i=1;i<=n;i++){let chunk=d['echo_icons_'+i];if(!chunk)continue;chunk.split(';').filter(Boolean).forEach(p=>{let a=p.indexOf(':');if(a<0)return;let b=p.indexOf(':',a+1);if(b<0)return;let id=Number(p.slice(0,a))+ECHO_SPELL_BASE,next={icon:p.slice(a+1,b),name:p.slice(b+1)},old=knownIcons[id];if(!old||old.icon!==next.icon||old.name!==next.name){knownIcons[id]=next;changed=true}})}if(changed){persistKnownIcons();if(selectedSessionId!==null&&!historyAssetTimer){historyAssetTimer=setTimeout(()=>{historyAssetTimer=0;if($('historyTab').classList.contains('active'))loadDecisions(selectedSessionId)},600)}}return Object.assign({},knownIcons,catalogIcons)}
const failedIcons=new Set();
function iconURL(key){return key&&!failedIcons.has(key)?`/api/icon/${encodeURIComponent(key)}`:''}
function iconFailed(img){
  try{failedIcons.add(decodeURIComponent(new URL(img.src,location.href).pathname.split('/').pop()))}catch(_e){}
  img.remove();
}
// echo_tips_N/_count: description text, chunked like echo_icons above but
// using ASCII control chars (0x1f/0x1e) instead of ":"/";" as separators -
// EchoTracker.lua's own comment explains why: real spell description text
// can contain literal ":" or ";" (e.g. "Increases X by 10%; also reduces
// Y"), which would silently corrupt naive colon/semicolon splitting the
// moment one did. Same trick this addon already uses for its full-catalog
// description export. As of 2026-09-08 this only ever covers the handful of
// currently-locked slots - board tips are always computed at stacks=1,
// which is exactly what the static /api/descriptions catalog already has,
// so sending it live again for board choices was pure duplicate traffic.
// Locked echoes genuinely need this live path since their description
// depends on the actual stack count, which the static export can't know.
const TIP_ID_SEP=String.fromCharCode(31), TIP_PART_SEP=String.fromCharCode(30);
const knownTips={};
const catalogTips={};
function echoTipMap(d){let n=Number(d.echo_tips_count||0);for(let i=1;i<=n;i++){let chunk=d['echo_tips_'+i];if(!chunk)continue;chunk.split(TIP_PART_SEP).filter(Boolean).forEach(p=>{let idx=p.indexOf(TIP_ID_SEP);if(idx<0)return;let id=Number(p.slice(0,idx))+ECHO_SPELL_BASE;knownTips[id]=p.slice(idx+1)})}return Object.assign({},knownTips,catalogTips)}
const QNAMES=['Common','Uncommon','Rare','Epic','Legendary'];
// Shared between the full-detail row (.slot, Current Board) and the compact
// icon tile (.tile, Locked/Permanent) - same underlying data, two different
// amounts of on-card detail (the tile relies entirely on the hover tooltip).
function echoDisplayInfo(c,iconMap,tipMap){
  let tagMap={F:'Frozen',C:'Carried',G:'Guaranteed'};
  let tags=(c.flags||'').split('').map(f=>tagMap[f]).filter(Boolean).join(' · ');
  let info=iconMap&&iconMap[c.spellId];
  let name=(info&&info.name)||('Echo #'+c.spellId);
  let url=iconURL(info&&info.icon);
  let qname=QNAMES[Math.min(c.quality,QNAMES.length-1)]||'Unknown';
  let tipSub=tags?(qname+' · '+tags):qname;
  let desc=(tipMap&&tipMap[c.spellId])||'';
  return {tags,name,url,tipSub,desc};
}
function echoCardHTML(c,iconMap,tipMap){
  let qc=Q[Math.min(c.quality,Q.length-1)]||'#425166';
  let info=echoDisplayInfo(c,iconMap,tipMap);
  let sub=c.stack?('x'+c.stack):(info.tags||'—');
  let img=info.url?`<img src="${info.url}" alt="" onload="this.parentNode.classList.add('hasimg')" onerror="iconFailed(this)">`:'';
  return `<div class="slot" style="--qc:${qc}" data-tip-name="${esc(info.name)}" data-tip-sub="${esc(info.tipSub)}" data-tip-desc="${esc(info.desc)}" data-tip-id="${c.spellId}"><div class="ico">${img}<span class="fallback">#${c.spellId}</span></div><div class="sn"><b>${esc(info.name)}</b><small>${sub}</small></div><div class="ilvl">Q${c.quality}</div></div>`
}
function echoTileHTML(c,iconMap,tipMap){
  let qc=Q[Math.min(c.quality,Q.length-1)]||'#425166';
  let info=echoDisplayInfo(c,iconMap,tipMap);
  let img=info.url?`<img src="${info.url}" alt="" onload="this.parentNode.classList.add('hasimg')" onerror="iconFailed(this)">`:'';
  let stack=c.stack&&c.stack>1?`<span class="stack">${c.stack}</span>`:'';
  return `<div class="tile" style="--qc:${qc}" data-tip-name="${esc(info.name)}" data-tip-sub="${esc(info.tipSub)}" data-tip-desc="${esc(info.desc)}" data-tip-id="${c.spellId}">${img}<span class="fallback">#${c.spellId}</span>${stack}</div>`
}
// Delegated (not per-element) listeners: .slot elements are replaced wholesale
// on every render() via innerHTML, so anything bound directly to them would
// need re-binding after every single update - listening on document instead
// survives re-renders for free.
function placeTip(e){let t=$('wowtip'),pad=14,x=e.clientX+18,y=e.clientY+18;let w=t.offsetWidth||280,h=t.offsetHeight||80;if(x+w>innerWidth-pad)x=e.clientX-w-18;if(y+h>innerHeight-pad)y=e.clientY-h-18;t.style.left=Math.max(pad,x)+'px';t.style.top=Math.max(pad,y)+'px'}
let hoveredSlot=null;
document.addEventListener('mouseover',e=>{
  let s=e.target.closest('.slot,.tile,.dcard');
  if(!s||!s.dataset.tipId)return;
  hoveredSlot=s;
  let t=$('wowtip');
  // dataset.* comes back HTML-DECODED (the browser undoes the esc() used to
  // build the attribute in the first place) - re-escaping here before this
  // second innerHTML insertion, not trusting the round-trip.
  let desc=s.dataset.tipDesc?`<div class="tipline">${esc(s.dataset.tipDesc)}</div>`:'';
  t.innerHTML=`<div class="tiptitle" style="color:${s.style.getPropertyValue('--qc')||'#fff'}">${esc(s.dataset.tipName)}</div><div class="tipsub">${esc(s.dataset.tipSub)}</div>${desc}<div class="tipid">Echo #${esc(s.dataset.tipId)}</div>`;
  t.style.display='block';
  placeTip(e);
});
document.addEventListener('mousemove',e=>{if(hoveredSlot)placeTip(e)});
document.addEventListener('mouseout',e=>{let s=e.target.closest('.slot,.tile,.dcard');if(s&&(!e.relatedTarget||!s.contains(e.relatedTarget))){hoveredSlot=null;$('wowtip').style.display='none'}});
// Board/locked signatures - a websocket push fires on ANY key changing (e.g.
// dps_last_fight ticking every second), which used to rebuild these two
// innerHTML blocks - and every <img> inside them - on every single push,
// even when the actual board/locked content hadn't changed at all. Browsers
// re-fetch/re-decode a freshly-created <img> even with an identical src,
// which is exactly what read as constant flicker. Only rebuild when the
// underlying signature actually changes. Each section includes only assets
// for the spell IDs it renders: the shared icon/tooltip chunks also contain
// the current board, so using the entire maps here made an unrelated board
// update destroy and recreate all permanent-icon <img> elements.
const BOARD_STORAGE_KEY='echotracker.lastBoard.v1';
let lastBoard=null;
try{lastBoard=JSON.parse(localStorage.getItem(BOARD_STORAGE_KEY)||'null')}catch(_e){}
let lastBoardStored=lastBoard?JSON.stringify(lastBoard):'';
let boardSig='',lockedSig='';
function setBoardState(state){
  let label=$('boardState'),grid=$('echoBoard');
  let cls='reasonstate '+state;
  if(label.className!==cls)label.className=cls;
  let value=state.toUpperCase();
  if(label.textContent!==value)label.textContent=value;
  let gridClass='boardgrid '+state;
  if(grid.className!==gridClass)grid.className=gridClass;
}
function saveBoard(cards,iconMap,tipMap){
  let icons={},tips={};
  for(const c of cards){
    if(iconMap[c.spellId])icons[c.spellId]=iconMap[c.spellId];
    if(tipMap[c.spellId])tips[c.spellId]=tipMap[c.spellId];
  }
  let next={cards,icons,tips},serialized=JSON.stringify(next);
  lastBoard=next;
  if(serialized===lastBoardStored)return;
  lastBoardStored=serialized;
  try{localStorage.setItem(BOARD_STORAGE_KEY,serialized)}catch(_e){}
}
function cardAssetsSig(cards,iconMap,tipMap){
  return JSON.stringify(cards.map(c=>{
    let info=iconMap[c.spellId]||{};
    return [c.spellId,c.quality,c.stack||0,c.flags||'',info.icon||'',info.name||'',tipMap[c.spellId]||''];
  }));
}
function render(d){
  let dotClass='dot'+(d.connected?' up':'');
  if($('dot').className!==dotClass)$('dot').className=dotClass;
  text('conn',d.connected?'LIVE':'OFFLINE');
  let ck=String(d.echo_class||'').toUpperCase();
  let classColor=C[ck]||'#8b98aa';
  if(document.documentElement.style.getPropertyValue('--class')!==classColor)document.documentElement.style.setProperty('--class',classColor);
  text('classBadge',d.echo_class,'Unknown Class');
  text('echoLevel',d.echo_level,'--');
  let iconMap=echoIconMap(d);
  let tipMap=echoTipMap(d);
  let board=echoCards(d.echo_board,'board');
  let boardState=board.length?'active':(lastBoard&&lastBoard.cards&&lastBoard.cards.length?'processed':'idle');
  if(board.length)saveBoard(board,iconMap,tipMap);
  let shownBoard=board.length?board:(boardState==='processed'?lastBoard.cards:[]);
  let shownIcons=board.length?iconMap:Object.assign({},(lastBoard&&lastBoard.icons)||{},iconMap);
  let shownTips=board.length?tipMap:Object.assign({},(lastBoard&&lastBoard.tips)||{},tipMap);
  let boardSigNew=boardState+'\0'+cardAssetsSig(shownBoard,shownIcons,shownTips);
  if(boardSigNew!==boardSig){
    boardSig=boardSigNew;
    setBoardState(boardState);
    $('echoBoard').innerHTML=shownBoard.length?shownBoard.map(c=>echoCardHTML(c,shownIcons,shownTips)).join(''):'<div class="empty">No board recorded yet.</div>';
  }
  let locked=echoCards(d.echo_locked,'locked');
  let lockedSigNew=cardAssetsSig(locked,iconMap,tipMap);
  if(lockedSigNew!==lockedSig){
    lockedSig=lockedSigNew;
    $('echoLocked').innerHTML=locked.length?locked.map(c=>echoTileHTML(c,iconMap,tipMap)).join(''):'<div class="empty">No permanent echoes locked yet.</div>';
  }
  text('echoLockedMax',locked.length+' / '+(d.echo_locked_max||0));
  let ch=echoCharges(d.echo_charges);
  text('echoReroll',ch.reroll);
  text('echoBanish',ch.banish);
  text('echoFreeze',ch.freeze);
  let owned=echoOwnedTotals(d);
  text('echoOwnedDistinct',owned.distinct);
  text('echoOwnedStacks',owned.stacks);
  text('ashPrestiges',fmt(d.ash_prestiges));
  text('ashBonus',(d.ash_bonus_pct||0)+'%');
  text('hardmodeTier',d.hardmode_tier,'1');
  text('soulPoints',fmt(d.soul_points));
  renderReason(d);
  renderBudget(d);
  renderWatchdog(d);
  renderRaw(d);
  updateStamp();
}
let lastStampSecond=-1;
function updateStamp(){let now=new Date(),second=Math.floor(now.getTime()/1000);if(second===lastStampSecond)return;lastStampSecond=second;text('stamp','updated '+now.toLocaleTimeString())}
// A single game update often arrives as several SSE/WS messages. Keep only
// the newest full snapshot and paint once on the next animation frame.
let pendingFrame=0,pendingData=null,latestSnapshot=null;
function scheduleRender(d){latestSnapshot=d;pendingData=d;if(pendingFrame)return;pendingFrame=requestAnimationFrame(()=>{pendingFrame=0;let next=pendingData;pendingData=null;render(next)})}
function connect(){let p=location.protocol==='https:'?'wss:':'ws:';let w=new WebSocket(p+'//'+location.host+'/ws');w.onmessage=e=>{try{scheduleRender(JSON.parse(e.data))}catch(err){console.error(err)}};w.onclose=()=>{text('conn','RECONNECTING');$('dot').className='dot';setTimeout(connect,1200)};w.onerror=()=>w.close()}
connect();
// Full exported descriptions are static and fetched once. They take priority
// over the deliberately 150-character live tooltip preview. Reset section
// signatures once they arrive so visible tooltips receive the full text
// without waiting for another game event.
fetch('/api/descriptions').then(r=>r.ok?r.json():Promise.reject(r.status)).then(rows=>{
  if(!rows||typeof rows!=='object'||rows.error)return;
  Object.assign(catalogTips,rows);
  boardSig='';lockedSig='';
  if(latestSnapshot)scheduleRender(latestSnapshot);
  if(selectedSessionId!==null)loadDecisions(selectedSessionId);
}).catch(err=>console.warn('full descriptions unavailable; using live previews',err));
// Static icon/name catalog, same "fetch once, take priority over live" deal
// as descriptions above - covers board cards, which no longer report
// echo_icons_* live at all (see PackIcons's own comment on the addon side).
fetch('/api/perk_icons').then(r=>r.ok?r.json():Promise.reject(r.status)).then(rows=>{
  if(!rows||typeof rows!=='object'||rows.error)return;
  Object.assign(catalogIcons,rows);
  boardSig='';lockedSig='';
  if(latestSnapshot)scheduleRender(latestSnapshot);
  if(selectedSessionId!==null)loadDecisions(selectedSessionId);
}).catch(err=>console.warn('full icon catalog unavailable; using live-seen icons only',err));
// Session history - a separate on-demand fetch (not part of the live
// telemetry stream, since it's a database read, not a wow_bridge key) with
// its own light periodic refresh. Sessions change rarely (only on a level
// reset), so 30s is plenty responsive without hammering sqlite.
function fmtDuration(started,ended){
  if(!started)return '—';
  let end=ended||(Date.now()/1000);
  let secs=Math.max(0,end-started);
  let h=Math.floor(secs/3600),m=Math.floor((secs%3600)/60);
  return h>0?`${h}h ${m}m`:`${m}m`;
}
function fmtWhen(ts){
  if(!ts)return '—';
  return new Date(ts*1000).toLocaleString([],{month:'short',day:'numeric',hour:'2-digit',minute:'2-digit'});
}
function historyRowHTML(s){
  let a=s.actions||{};
  let live=s.ended_at?'':' <span style="color:#42df91">●</span>';
  let selected=s.id===selectedSessionId?' class="selected"':'';
  let character=s.character_name?(s.character_name+(s.realm?' · '+s.realm:'')):'Legacy / unassigned';
  let buildSpec=s.talent_spec||s.spec||'—';
  return `<tr data-session="${s.id}"${selected}><td>#${s.id}${live}</td><td>${esc(character)}</td><td>${fmtWhen(s.started_at)}</td><td>${fmtDuration(s.started_at,s.ended_at)}</td><td>${esc(s.class||'—')} (${esc(buildSpec)})</td><td>${s.level??'—'}</td><td>${a.TAKE||0}</td><td>${a.BANISH||0}</td><td>${a.FREEZE||0}</td><td>${a.REROLL||0}</td><td>${s.fights||0}</td><td>${fmt(Math.round(s.avg_dps||0))}</td><td>${fmt(Math.round(s.max_dps||0))}</td><td>${s.prestiges??'—'}</td><td>${s.hardmode_tier??'—'}</td></tr>`;
}
const QUALITY_COLOR={Common:Q[0],Uncommon:Q[1],Rare:Q[2],Epic:Q[3],Legendary:Q[4]};
let historySig='',selectedSessionId=null,decisionRequest=0;
function decisionCardHTML(c,target){
  let asset=catalogIcons[c.spell_id]||knownIcons[c.spell_id]||{},name=c.name||asset.name||('Echo #'+c.spell_id),desc=catalogTips[c.spell_id]||knownTips[c.spell_id]||'';
  let icon=asset.icon&&iconURL(asset.icon)?`<img src="${iconURL(asset.icon)}" alt="" onerror="iconFailed(this)">`:`#${esc(c.spell_id)}`;
  if(c.error)return `<div class="dcard" data-tip-name="${esc(name)}" data-tip-sub="Catalog miss" data-tip-desc="${esc(desc)}" data-tip-id="${esc(c.spell_id)}"><div class="dicon">${icon}</div><div class="dinfo"><b>${esc(name)}</b><small><span>catalog miss</span></small></div></div>`;
  let score=c.score||{},qc=QUALITY_COLOR[c.quality]||'#7e91aa';
  let cls=String(c.spell_id)===String(target)?'dcard target':'dcard';
  return `<div class="${cls}" style="--qc:${qc}" data-tip-name="${esc(name)}" data-tip-sub="${esc(c.quality||'Echo')} · owned ${esc(c.owned||'—')}" data-tip-desc="${esc(desc)}" data-tip-id="${esc(c.spell_id)}"><div class="dicon">${icon}</div><div class="dinfo"><b>${esc(name)}</b><small><span>${esc(c.quality||'—')} · owned ${esc(c.owned||'—')}</span><strong>${Number(score.total||0).toFixed(1)}</strong></small><div class="dmeta">quality ${score.quality??0} × ${score.rarity_multiplier??1} · spec ${score.spec_fit??0} · owned ${score.ownership??0} · community ${score.community??0} · stats ${score.stat_priority??0} · downside ${score.downside??0}</div></div></div>`;
}
function decisionHTML(d){
  let scores=Array.isArray(d.scores)?d.scores:[],reasons=Array.isArray(d.reasons)?d.reasons:[];
  let target=scores.find(c=>String(c.spell_id)===String(d.target_spell_id));
  let targetName=target&&target.name?target.name:(d.target_spell_id?('Echo #'+d.target_spell_id):'whole board');
  return `<details class="decision"><summary><span>Lv ${d.level}</span><span>${fmtWhen(d.at).split(', ').pop()}</span><span class="act ${esc(d.action)}">${esc(d.action)} · ${esc(targetName)}</span><span class="status">${esc(d.status)}</span></summary><div class="decisionbody"><div class="decisioncards">${scores.map(c=>decisionCardHTML(c,d.target_spell_id)).join('')}</div><div class="dreasons">${reasons.map(r=>`<div class="dreason">${esc(r)}</div>`).join('')}</div><div class="dmeta">charges: ${esc(d.charges&&d.charges.raw||'—')} · build before #${d.build_before_id??'—'} · build after #${d.build_after_id??'—'}</div></div></details>`;
}
function loadDecisions(sessionId){
  selectedSessionId=Number(sessionId);decisionRequest++;
  document.querySelectorAll('#historyBody tr').forEach(r=>r.classList.toggle('selected',Number(r.dataset.session)===selectedSessionId));
  let request=decisionRequest;text('decisionCount','LOADING…');
  fetch('/api/history/'+selectedSessionId+'/decisions').then(r=>r.json()).then(rows=>{
    if(request!==decisionRequest||!Array.isArray(rows))return;
    text('decisionCount',rows.length+' decision'+(rows.length===1?'':'s'));
    $('decisionList').innerHTML=rows.length?rows.map(decisionHTML).join(''):'<div class="empty">No decisions recorded for this run.</div>';
  }).catch(()=>{if(request===decisionRequest)text('decisionCount','LOAD ERROR')});
}
$('historyBody').addEventListener('click',e=>{let row=e.target.closest('tr[data-session]');if(row)loadDecisions(row.dataset.session)});
function loadHistory(){
  fetch('/api/history').then(r=>r.json()).then(rows=>{
    if(!Array.isArray(rows))return;
    if(selectedSessionId===null&&rows.length){selectedSessionId=Number(rows[0].id);loadDecisions(selectedSessionId)}
    let sig=JSON.stringify(rows);
    if(sig===historySig)return;
    historySig=sig;
    text('historyCount',rows.length+' session'+(rows.length===1?'':'s'));
    $('historyBody').innerHTML=rows.length?rows.map(historyRowHTML).join(''):'<tr><td colspan="15" class="empty">No sessions recorded yet.</td></tr>';
  }).catch(()=>{});
}
loadHistory();
setInterval(loadHistory,30000);
</script></body></html>'''


def _session_history(limit=15):
    """Read-only summary of the most recent sessions from
    data/session.db - the same file companion/src/session_db.rs writes and
    tools/export/export_build_report.py already reads offline. Opened
    read-only (uri mode=ro) each call - this file is written by companion
    while this reads it, and sqlite handles concurrent readers/one writer
    fine as long as neither side holds a long-lived write transaction,
    which companion never does (each record_* call is its own statement).
    """
    if not os.path.exists(SESSION_DB_PATH):
        return []
    conn = sqlite3.connect(f"file:{SESSION_DB_PATH}?mode=ro", uri=True)
    conn.row_factory = sqlite3.Row
    try:
        sessions = conn.execute(
            "SELECT id, started_at, ended_at, class, spec, prestiges, hardmode_tier, "
            "character_guid, character_name, realm, race, faction, talent_spec "
            "FROM sessions ORDER BY id DESC LIMIT ?",
            (limit,),
        ).fetchall()
        out = []
        for s in sessions:
            sid = s["id"]
            level_row = conn.execute(
                "SELECT MAX(level) AS lvl FROM ("
                " SELECT level FROM actions WHERE session_id = ?"
                " UNION ALL SELECT level FROM fights WHERE session_id = ?"
                " UNION ALL SELECT level FROM board_log WHERE session_id = ?"
                " UNION ALL SELECT level FROM decision_events WHERE session_id = ?"
                " UNION ALL SELECT level FROM build_snapshots WHERE session_id = ?"
                ")",
                (sid, sid, sid, sid, sid),
            ).fetchone()
            action_counts = {
                row["action"]: row["n"]
                for row in conn.execute(
                    "SELECT action, COUNT(*) AS n FROM actions WHERE session_id = ? GROUP BY action", (sid,)
                ).fetchall()
            }
            fight_row = conn.execute(
                "SELECT COUNT(*) AS n, AVG(dps) AS avg_dps, MAX(dps) AS max_dps FROM fights WHERE session_id = ?",
                (sid,),
            ).fetchone()
            out.append(
                {
                    "id": sid,
                    "started_at": s["started_at"],
                    "ended_at": s["ended_at"],
                    "class": s["class"],
                    "spec": s["spec"],
                    "level": level_row["lvl"] if level_row else None,
                    "prestiges": s["prestiges"],
                    "hardmode_tier": s["hardmode_tier"],
                    "character_guid": s["character_guid"],
                    "character_name": s["character_name"],
                    "realm": s["realm"],
                    "race": s["race"],
                    "faction": s["faction"],
                    "talent_spec": s["talent_spec"],
                    "actions": action_counts,
                    "fights": fight_row["n"] or 0 if fight_row else 0,
                    "avg_dps": fight_row["avg_dps"] if fight_row else None,
                    "max_dps": fight_row["max_dps"] if fight_row else None,
                }
            )
        return out
    finally:
        conn.close()


@app.get("/api/history")
def history():
    try:
        return jsonify(_session_history())
    except Exception as exc:
        return jsonify({"error": str(exc)}), 500


@app.get("/api/history/<int:session_id>/decisions")
def decision_history(session_id):
    """Complete scored board timeline for one run.

    JSON blobs are decoded here so the browser receives structured data and
    never needs to understand SQLite's storage representation.
    """
    if not os.path.exists(SESSION_DB_PATH):
        return jsonify([])
    try:
        conn = sqlite3.connect(f"file:{SESSION_DB_PATH}?mode=ro", uri=True)
        conn.row_factory = sqlite3.Row
        try:
            rows = conn.execute(
                "SELECT id, at, level, board, action, target_spell_id, "
                "reasons_json, scores_json, charges_json, build_before_id, "
                "build_after_id, status, confirmed_at "
                "FROM decision_events WHERE session_id = ? ORDER BY at DESC, id DESC",
                (session_id,),
            ).fetchall()
            out = []
            for row in rows:
                item = dict(row)
                for source, target, fallback in (
                    ("reasons_json", "reasons", []),
                    ("scores_json", "scores", []),
                    ("charges_json", "charges", {}),
                ):
                    try:
                        item[target] = json.loads(item.pop(source))
                    except (TypeError, ValueError):
                        item[target] = fallback
                out.append(item)
            return jsonify(out)
        finally:
            conn.close()
    except Exception as exc:
        return jsonify({"error": str(exc)}), 500


@app.get("/")
def index():
    return Response(PAGE, mimetype="text/html")


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000, debug=False)
