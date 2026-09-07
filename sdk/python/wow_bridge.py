"""Python SDK for the wow_bridge local control API (default http://127.0.0.1:8765).

Stdlib-only (http.client/json) - no extra dependency, matching the pattern
already used elsewhere in this project (tools/push_texture.py, FlaskGUI/app.py).

    from wow_bridge import WowBridge

    bridge = WowBridge()
    bridge.set("greeting", "hello from python")
    print(bridge.get("greeting"))
    print(bridge.read("gold"))          # blocking round-trip read from the game
    bridge.run_lua("DoEmote('WAVE')")
    for key, value in bridge.stream():  # blocks, yields forever
        print(key, value)
"""

from __future__ import annotations

import http.client
import json
import urllib.parse
import urllib.request
from typing import Iterator, Optional

from app_paths import repo_root

# wow_bridge requires `Authorization: Bearer <token>` on every request (its
# API port binds 0.0.0.0 so the WoW client on the Windows host can reach it
# out of WSL, which also makes it reachable from the rest of the network -
# see wow_bridge's api.rs for the full threat model). The token rotates on
# every wow_bridge startup AND on every real WoW login, so it's re-read on
# every single request rather than cached once - a cached stale token would
# start failing with 401 the moment a new login happens. Same convention
# companion/src/bridge.rs and FlaskGUI/app.py already use: bins/api_token.txt,
# written by wow_bridge next to its own executable. This module predates that
# auth requirement and was never updated to send it - confirmed live: every
# tools/live/*.py script built on this client (deploy_script.py included)
# was silently failing every call with 401 Unauthorized.
_TOKEN_PATH = repo_root() / "bins" / "api_token.txt"


def _current_token() -> str:
    try:
        return _TOKEN_PATH.read_text().strip()
    except OSError:
        return ""


class WowBridgeError(RuntimeError):
    """Raised when the bridge API returns a non-2xx response."""


class WowBridge:
    def __init__(self, base_url: str = "http://127.0.0.1:8765", timeout: float = 5.0):
        self.base_url = base_url.rstrip("/")
        self.timeout = timeout
        parsed = urllib.parse.urlparse(self.base_url)
        self._host = parsed.hostname or "127.0.0.1"
        self._port = parsed.port or 80
        self._conn: Optional[http.client.HTTPConnection] = None

    def _get_conn(self, timeout: Optional[float]) -> http.client.HTTPConnection:
        effective_timeout = timeout or self.timeout
        if self._conn is None:
            self._conn = http.client.HTTPConnection(self._host, self._port, timeout=effective_timeout)
        elif self._conn.sock is not None:
            # A per-call timeout (read()'s longer one, for its live
            # round-trip into the game) only takes effect at connection-
            # creation time otherwise - on an already-open reused
            # connection the socket keeps whatever timeout it was first
            # created with unless explicitly reset here.
            self._conn.sock.settimeout(effective_timeout)
        return self._conn

    def _request(self, method: str, path: str, body: Optional[dict] = None, timeout: Optional[float] = None) -> dict:
        """One HTTP/1.1 connection is reused across every call on this
        WowBridge instance (the server keeps it open now - see
        api.rs's handle_conn) instead of a fresh TCP connection per call.
        echo_autopilot.py polls 8-11 keys every ~1.5s; without reuse each
        one paid a full TCP handshake to localhost for its entire runtime.
        Reconnects once, transparently, if the persistent connection was
        dropped (bridge restarted, OS-level idle timeout, etc.) - a caller
        never has to know or handle that themselves."""
        data = json.dumps(body).encode("utf-8") if body is not None else None
        headers = {"Authorization": f"Bearer {_current_token()}"}
        if data:
            headers["Content-Type"] = "application/json"

        for attempt in (1, 2):
            conn = self._get_conn(timeout)
            try:
                conn.request(method, path, body=data, headers=headers)
                response = conn.getresponse()
                payload = response.read()
                break
            except (http.client.HTTPException, OSError):
                self._conn = None
                if attempt == 2:
                    raise
        else:
            raise WowBridgeError("unreachable")  # pragma: no cover - loop always breaks or raises

        if response.status >= 400:
            try:
                message = json.loads(payload).get("error", payload.decode("utf-8", errors="replace"))
            except (json.JSONDecodeError, UnicodeDecodeError):
                message = payload.decode("utf-8", errors="replace")
            raise WowBridgeError(f"{response.status} {response.reason}: {message}")
        return json.loads(payload.decode("utf-8"))

    def get(self, key: str) -> Optional[str]:
        """Pure read of the local cache. Returns None if the key is unknown."""
        try:
            return self._request("GET", f"/api/variables/{key}")["value"]
        except WowBridgeError as exc:
            if "404" in str(exc):
                return None
            raise

    def set(self, key: str, value: str) -> None:
        """Queues `value` for delivery into the game via the next addon poll."""
        self._request("POST", f"/api/variables/{key}", {"value": str(value)})

    def read(self, key: str, timeout: float = 6.0) -> str:
        """Blocking round-trip: asks the game to report its current `key`
        global and waits for the answer. Has a live side effect (a whisper
        into the game) - not idempotent, don't retry casually."""
        return self._request("POST", f"/api/read/{key}", timeout=timeout + 1.0)["value"]

    def run_lua(self, code: str) -> None:
        """Queues arbitrary Lua for the addon to execute via
        loadstring/pcall on its next poll, via POST /api/cmd/lua."""
        self._request("POST", "/api/cmd/lua", {"value": code})

    def stream(self) -> Iterator[tuple]:
        """Yields (key, value) forever as the addon reports DATA|key=value
        updates, via GET /api/stream (Server-Sent Events). Blocks between
        events; run in its own thread if used alongside other bridge calls."""
        request = urllib.request.Request(
            f"{self.base_url}/api/stream",
            headers={"Authorization": f"Bearer {_current_token()}"},
        )
        with urllib.request.urlopen(request, timeout=None) as response:
            for raw_line in response:
                line = raw_line.decode("utf-8").strip()
                if not line.startswith("data:"):
                    continue
                payload = json.loads(line[len("data:"):].strip())
                yield payload["key"], payload["value"]


if __name__ == "__main__":
    import sys

    bridge = WowBridge()
    if len(sys.argv) == 3 and sys.argv[1] == "get":
        print(bridge.get(sys.argv[2]))
    elif len(sys.argv) == 4 and sys.argv[1] == "set":
        bridge.set(sys.argv[2], sys.argv[3])
    elif len(sys.argv) == 3 and sys.argv[1] == "read":
        print(bridge.read(sys.argv[2]))
    elif len(sys.argv) == 2 and sys.argv[1] == "stream":
        for k, v in bridge.stream():
            print(f"{k}={v}")
    else:
        print("usage: wow_bridge.py get|set|read|stream ...")
        sys.exit(1)
