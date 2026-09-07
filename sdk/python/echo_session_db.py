"""SQLite persistence for the Echo/perk draft: what you own, and every
action the autopilot (or manual tools like banish_echo.py) executed -
scoped per session (a run between resets). Separate from
wow_bridge_cache.sqlite3 (that's a generic proxy KV cache) - this is
domain-specific history for the Echo pipeline.

A "session" is one run between resets: on this server, a normal-mode death
lets you keep your level (with the option to reset to 1 voluntarily,
e.g. via tools/live/banish_echo.py-style manual triggers), while hardcore mode
resets to 1 instantly on death. Either way, from what echo_level reports,
a session boundary looks the same: level suddenly drops (typically to 1).
This can't tell voluntary reset apart from a hardcore death - both look
identical in the data available here - but either way it's a clean break
between runs, so owned_echoes/actions get scoped to a new session_id
instead of mixing two different runs' history together.

    from echo_session_db import ensure_session, record_owned, record_action

    session_id = ensure_session(level)   # call once per cycle, before recording
    record_owned(owned, session_id)
    record_action(action, spell_id, level, board_raw, session_id)
"""

from __future__ import annotations

import sqlite3
import time
from typing import Iterable

from app_paths import DATA_DIR

DB_PATH = DATA_DIR / "session.db"

_conn: sqlite3.Connection | None = None
_current_session_id: int | None = None
_last_level: int | None = None


def _db() -> sqlite3.Connection:
    global _conn
    if _conn is None:
        DB_PATH.parent.mkdir(parents=True, exist_ok=True)
        _conn = sqlite3.connect(DB_PATH)
        _conn.executescript(
            """
            CREATE TABLE IF NOT EXISTS sessions (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                started_at REAL NOT NULL,
                ended_at REAL,
                reroll_total INTEGER,
                freeze_total INTEGER,
                banish_total INTEGER,
                class TEXT,
                spec TEXT,
                prestiges INTEGER,
                ash_committed INTEGER,
                ash_bonus_pct REAL,
                max_permanent_slots INTEGER,
                hardmode_tier INTEGER,
                soul_points INTEGER,
                soul_points_max INTEGER
            );
            CREATE TABLE IF NOT EXISTS owned_echoes (
                session_id INTEGER NOT NULL,
                spell_id TEXT NOT NULL,
                count INTEGER NOT NULL,
                updated_at REAL NOT NULL,
                PRIMARY KEY (session_id, spell_id)
            );
            CREATE TABLE IF NOT EXISTS actions (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                session_id INTEGER NOT NULL,
                at REAL NOT NULL,
                action TEXT NOT NULL,
                spell_id TEXT,
                level INTEGER,
                board TEXT
            );
            CREATE TABLE IF NOT EXISTS board_log (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                session_id INTEGER NOT NULL,
                at REAL NOT NULL,
                level INTEGER,
                board TEXT,
                board_changed INTEGER NOT NULL
            );
            CREATE TABLE IF NOT EXISTS locked_echoes (
                session_id INTEGER NOT NULL,
                spell_id TEXT NOT NULL,
                count INTEGER NOT NULL,
                quality INTEGER,
                updated_at REAL NOT NULL,
                PRIMARY KEY (session_id, spell_id)
            );
            CREATE TABLE IF NOT EXISTS fights (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                session_id INTEGER NOT NULL,
                at REAL NOT NULL,
                level INTEGER,
                damage INTEGER NOT NULL,
                dps REAL NOT NULL,
                duration_s REAL NOT NULL
            );
            """
        )
        _conn.commit()
        # Migration for session.db files created before reroll_total/freeze_total/
        # banish_total/class/spec existed on `sessions` - CREATE TABLE IF NOT
        # EXISTS above doesn't add columns to an already-existing table.
        existing_cols = {row[1] for row in _conn.execute("PRAGMA table_info(sessions)")}
        for col, coltype in (
            ("reroll_total", "INTEGER"), ("freeze_total", "INTEGER"), ("banish_total", "INTEGER"),
            ("class", "TEXT"), ("spec", "TEXT"),
            ("prestiges", "INTEGER"), ("ash_committed", "INTEGER"), ("ash_bonus_pct", "REAL"),
            ("max_permanent_slots", "INTEGER"), ("hardmode_tier", "INTEGER"),
            ("soul_points", "INTEGER"), ("soul_points_max", "INTEGER"),
        ):
            if col not in existing_cols:
                _conn.execute(f"ALTER TABLE sessions ADD COLUMN {col} {coltype}")
        _conn.commit()
    return _conn


def _start_session(conn: sqlite3.Connection) -> int:
    cur = conn.execute("INSERT INTO sessions (started_at) VALUES (?)", (time.time(),))
    conn.commit()
    print(f"[session_db] started session {cur.lastrowid}")
    return cur.lastrowid


def ensure_session(level: int) -> int:
    """Call once per cycle with the current echo_level, before recording
    anything. Returns the active session_id - starts one on first call
    (reattaching to the most recent still-open session if the process
    restarted), and closes+starts a new one if level dropped since the last
    call (a reset).

    Bug fixed 2026-09-02: on reattachment, _last_level used to be seeded
    from the CURRENT live level (the level argument passed to this very
    call), not the reattached session's actual last-known level - so a
    reset that happened while no process was running (or between restarts)
    was silently invisible: the very next ensure_session() call just
    treated "level" as the new baseline and kept merging everything into
    the old still-open session forever, no split, no warning. Seen live:
    a full new 1->6 run got absorbed into a session whose recorded max was
    already 49. Fixed by seeding _last_level from session_max_level() (the
    DB's real last-known level for that session) instead, and falling
    through to the normal drop-check below on the same call, so a reset
    that already happened before this process started still gets caught
    immediately instead of on some later, arbitrary future drop."""
    global _current_session_id, _last_level
    conn = _db()

    if _current_session_id is None:
        row = conn.execute(
            "SELECT id FROM sessions WHERE ended_at IS NULL ORDER BY id DESC LIMIT 1"
        ).fetchone()
        if row:
            _current_session_id = row[0]
            _last_level = session_max_level(_current_session_id) or level
        else:
            _current_session_id = _start_session(conn)
            _last_level = level

    if _last_level is not None and level < _last_level:
        conn.execute(
            "UPDATE sessions SET ended_at = ? WHERE id = ?", (time.time(), _current_session_id)
        )
        conn.commit()
        print(f"[session_db] level dropped {_last_level} -> {level}: closed session {_current_session_id}")
        _current_session_id = _start_session(conn)

    _last_level = level
    return _current_session_id


def record_resource_totals(reroll_total: int, freeze_total: int, banish_total_estimate: int, session_id: int) -> None:
    """Bug fixed 2026-09-02: this used to be set_session_totals_if_unset,
    seeding reroll/freeze/banish totals ONCE (first-call-wins) and freezing
    them for the rest of the session. That's wrong if the server grants
    MORE charges as you level (unverified either way from source - the
    values are server-authoritative, no client-side formula to check) -
    a first-call-wins seed captured at session start would stay stuck at
    that number forever, making the per-20-level-group quota system
    (score_echo_board.py's group_allocation) increasingly wrong for later
    groups regardless of the real answer, since it can't self-correct.

    reroll_total/freeze_total: now a plain latest-observed-value overwrite,
    called every cycle - echo_charges reports these directly and live, so
    there was never a reason to freeze a stale copy in the first place.
    Safe either way: constant totals overwrite with the same value every
    time (no-op in effect), growing totals get picked up immediately.

    banish_total_estimate: banish has NO total field in echo_charges at
    all (only remainingBanishes) - the caller estimates it each cycle as
    remaining + spent-this-session-so-far. Stored as a RATCHET (MAX, never
    decreases) since that estimate is only ever a lower bound - a call
    early in the session, before much banishing has happened, would
    underestimate; later cycles with more spending data converge upward
    toward the truth, and the ratchet keeps whatever's highest so far."""
    conn = _db()
    conn.execute(
        "UPDATE sessions SET reroll_total = ?, freeze_total = ?, "
        "banish_total = MAX(COALESCE(banish_total, 0), ?) WHERE id = ?",
        (reroll_total, freeze_total, banish_total_estimate, session_id),
    )
    conn.commit()


def actions_spent_total(action: str, session_id: int) -> int:
    """How many times `action` was executed this session, across the WHOLE
    run (no level-range filter, unlike actions_spent_in_range) - used to
    estimate banish's implied total (remaining + spent-so-far), which
    needs the full-session count, not just one level group's slice."""
    conn = _db()
    row = conn.execute(
        "SELECT COUNT(*) FROM actions WHERE session_id = ? AND action = ?", (session_id, action)
    ).fetchone()
    return row[0] if row else 0


def set_session_class_spec_if_unset(klass: str, spec: str, session_id: int) -> None:
    """First-call-wins, unlike record_resource_totals below (class/spec
    genuinely don't change mid-session, unlike resource totals which
    might grow with level - no reason for this one to self-correct). The
    autopilot's --class/--spec are constant for a session, but a bare
    ensure_session(level) call has no reason to know them, so this is set
    lazily the first time the caller (echo_autopilot.py) has them handy."""
    conn = _db()
    row = conn.execute("SELECT class FROM sessions WHERE id = ?", (session_id,)).fetchone()
    if row and row[0] is not None:
        return
    conn.execute("UPDATE sessions SET class = ?, spec = ? WHERE id = ?", (klass, spec, session_id))
    conn.commit()


def record_prestige_state(prestiges: int, ash_committed: int, ash_bonus_pct: float, session_id: int) -> None:
    """Latest-observed-value overwrite (not first-call-wins like totals
    above) - committed Soul Ashes grows through a session as the skill tree
    gets spent into, so each cycle's fresher number should win, ending on
    whatever it was at session close."""
    conn = _db()
    conn.execute(
        "UPDATE sessions SET prestiges = ?, ash_committed = ?, ash_bonus_pct = ? WHERE id = ?",
        (prestiges, ash_committed, ash_bonus_pct, session_id),
    )
    conn.commit()


def record_hardmode_tier(tier: int, session_id: int) -> None:
    """Latest-observed-value overwrite - Torment/Hardcore difficulty tier
    (1=Normal, 2-6=Hardcore, HARDMODE_REWARDS in hardmode_service.lua)
    doesn't change mid-session in practice but is reported this way for
    consistency with prestige state, and to survive not being known yet
    right after a fresh /reload (EchoTracker only reports it once
    IsDifficultyKnown() is true)."""
    conn = _db()
    conn.execute("UPDATE sessions SET hardmode_tier = ? WHERE id = ?", (tier, session_id))
    conn.commit()


def record_soul_points(points: int, points_max: int, session_id: int) -> None:
    """Latest-observed-value overwrite. This RUN's earned-but-not-yet-
    committed soul points (what "Accept Death" grants) - distinct from
    ash_committed (the skill tree's cumulative committed pool) and
    prestiges/ash_bonus_pct (the separate, rarer, deliberate Prestige
    action) - see EchoTracker.lua's Refresh() comment for the full
    Accept-Death-vs-Prestige distinction, confirmed live 2026-09-02."""
    conn = _db()
    conn.execute(
        "UPDATE sessions SET soul_points = ?, soul_points_max = ? WHERE id = ?",
        (points, points_max, session_id),
    )
    conn.commit()


def record_locked(locked: list, max_slots: int, session_id: int) -> None:
    """locked: list of {spellId, count, quality} from parse_locked - the
    PERMANENT echo slots (level-gated count, max_slots) the player has
    explicitly chosen, distinct from the full owned_echoes pool. Replaces
    the whole set each call (small, single digits) rather than upserting
    like record_owned, so unlocking an echo is reflected too."""
    conn = _db()
    now = time.time()
    conn.execute("DELETE FROM locked_echoes WHERE session_id = ?", (session_id,))
    conn.executemany(
        "INSERT INTO locked_echoes (session_id, spell_id, count, quality, updated_at) VALUES (?, ?, ?, ?, ?)",
        [(session_id, e["spellId"], e["count"], e["quality"], now) for e in locked],
    )
    conn.execute("UPDATE sessions SET max_permanent_slots = ? WHERE id = ?", (max_slots, session_id))
    conn.commit()


def locked_for_session(session_id: int) -> Iterable[sqlite3.Row]:
    conn = _db()
    conn.row_factory = sqlite3.Row
    return conn.execute(
        "SELECT * FROM locked_echoes WHERE session_id = ? ORDER BY spell_id ASC", (session_id,)
    ).fetchall()


def get_session_totals(session_id: int) -> dict:
    conn = _db()
    row = conn.execute(
        "SELECT reroll_total, freeze_total, banish_total FROM sessions WHERE id = ?", (session_id,)
    ).fetchone()
    if not row:
        return {}
    return {"reroll_total": row[0], "freeze_total": row[1], "banish_total": row[2]}


def actions_spent_in_range(action: str, level_gt: int, level_le: int, session_id: int) -> int:
    """How many times `action` (REROLL/BANISH/FREEZE) was already executed
    this session at a level in (level_gt, level_le] - i.e. within one
    20-level group. Used to enforce that group's quota can't be exceeded by
    spending already recorded in `actions`."""
    conn = _db()
    row = conn.execute(
        "SELECT COUNT(*) FROM actions WHERE session_id = ? AND action = ? AND level > ? AND level <= ?",
        (session_id, action, level_gt, level_le),
    ).fetchone()
    return row[0] if row else 0


def record_owned(owned: dict, session_id: int) -> None:
    """owned: {spellId: count} as returned by fetch_owned/parse_owned."""
    conn = _db()
    now = time.time()
    conn.executemany(
        "INSERT INTO owned_echoes (session_id, spell_id, count, updated_at) VALUES (?, ?, ?, ?) "
        "ON CONFLICT(session_id, spell_id) DO UPDATE SET count = excluded.count, updated_at = excluded.updated_at",
        [(session_id, spell_id, count, now) for spell_id, count in owned.items()],
    )
    conn.commit()


def record_action(action: str, spell_id: str | None, level: int, board: str, session_id: int) -> None:
    conn = _db()
    conn.execute(
        "INSERT INTO actions (session_id, at, action, spell_id, level, board) VALUES (?, ?, ?, ?, ?, ?)",
        (session_id, time.time(), action, spell_id, level, board),
    )
    conn.commit()


def record_board_observation(level: int, board: str, board_changed: bool, session_id: int) -> None:
    """Passive log entry - no action taken, just what echo_board/echo_level
    read at this moment. Used by tools/live/echo_board_logger.py to reconstruct
    the full level-by-level history of what was offered, without ever
    picking/rerolling/banishing/freezing anything."""
    conn = _db()
    conn.execute(
        "INSERT INTO board_log (session_id, at, level, board, board_changed) VALUES (?, ?, ?, ?, ?)",
        (session_id, time.time(), level, board, 1 if board_changed else 0),
    )
    conn.commit()


def board_log_for_session(session_id: int) -> Iterable[sqlite3.Row]:
    conn = _db()
    conn.row_factory = sqlite3.Row
    return conn.execute(
        "SELECT * FROM board_log WHERE session_id = ? ORDER BY id ASC", (session_id,)
    ).fetchall()


def record_fight(damage: int, dps: float, duration_s: float, level: int, session_id: int) -> None:
    """One completed fight (SimpleDamageMeter's dps_last_fight, parsed) tied
    to whatever build was owned at the time - lets a later export correlate
    "this build" with "this measured DPS", not just log damage numbers on
    their own."""
    conn = _db()
    conn.execute(
        "INSERT INTO fights (session_id, at, level, damage, dps, duration_s) VALUES (?, ?, ?, ?, ?, ?)",
        (session_id, time.time(), level, damage, dps, duration_s),
    )
    conn.commit()


def fights_for_session(session_id: int) -> Iterable[sqlite3.Row]:
    conn = _db()
    conn.row_factory = sqlite3.Row
    return conn.execute(
        "SELECT * FROM fights WHERE session_id = ? ORDER BY id ASC", (session_id,)
    ).fetchall()


def owned_for_session(session_id: int) -> Iterable[sqlite3.Row]:
    conn = _db()
    conn.row_factory = sqlite3.Row
    return conn.execute(
        "SELECT * FROM owned_echoes WHERE session_id = ? ORDER BY spell_id ASC", (session_id,)
    ).fetchall()


def session_max_level(session_id: int) -> int | None:
    """Highest level ever seen for this session, across every table that
    records one - the closest thing to "how far this build got" since
    sessions doesn't track a final level directly (ensure_session only
    watches for a DROP, to detect a reset)."""
    conn = _db()
    row = conn.execute(
        """
        SELECT MAX(level) FROM (
            SELECT level FROM actions WHERE session_id = ?
            UNION ALL SELECT level FROM fights WHERE session_id = ?
            UNION ALL SELECT level FROM board_log WHERE session_id = ?
        )
        """,
        (session_id, session_id, session_id),
    ).fetchone()
    return row[0] if row else None


def all_sessions() -> Iterable[sqlite3.Row]:
    conn = _db()
    conn.row_factory = sqlite3.Row
    return conn.execute("SELECT * FROM sessions ORDER BY id ASC").fetchall()


def latest_session_id() -> int | None:
    conn = _db()
    row = conn.execute("SELECT id FROM sessions ORDER BY id DESC LIMIT 1").fetchone()
    return row[0] if row else None


def recent_actions(limit: int = 20, session_id: int | None = None) -> Iterable[sqlite3.Row]:
    conn = _db()
    conn.row_factory = sqlite3.Row
    if session_id is not None:
        return conn.execute(
            "SELECT * FROM actions WHERE session_id = ? ORDER BY id DESC LIMIT ?", (session_id, limit)
        ).fetchall()
    return conn.execute("SELECT * FROM actions ORDER BY id DESC LIMIT ?", (limit,)).fetchall()
