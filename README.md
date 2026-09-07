# EchoBrain: EchoTracker, DataBridge & Companion

Components for automating and analyzing the "Echo" perk-draft system on a
World of Warcraft 3.3.5a private server (Project Ebonhold):

| Component | What it is | Runs |
|---|---|---|
| **EchoTracker** | WoW addon. Reads the live Echo board/character state and reports it. | Inside the WoW client |
| **DataBridge** | WoW addon. Generic transport - batches/whispers any addon's data out, runs Lua sent back in. | Inside the WoW client |
| **companion** | Rust CLI. Scores boards, decides Take/Reroll/Banish/Freeze, records training data, executes actions. | On your PC, as a separate process |
| **FlaskGUI** *(optional)* | Python web dashboard. Live board/reasoning/charges view plus a full run-history browser, reading the same bridge feed and `companion`'s training database. | On your PC, in a browser |

## How they fit together

```
 WoW client                              Your PC
┌─────────────────────────┐   addon    ┌──────────────┐   HTTP    ┌───────────┐
│ EchoTracker (reports)    │  message   │  a local     │  (local)  │ companion │
│ DataBridge  (transport) ─┼───whisper──┤  bridge      ├───────────┤  (Rust)   │
└─────────────────────────┘            │  process     │           └───────────┘
                                        │              │   HTTP    ┌───────────┐
                                        │              ├───────────┤ FlaskGUI  │
                                        └──────────────┘  (local)  │ (optional)│
                                                                   └───────────┘
```

FlaskGUI is just another client of the same local bridge API `companion`
uses (`/api/stream` for the live feed, `/api/cmd/lua` for its Gear Watchdog
controls) plus a read-only connection to `companion`'s own
`data/session.db`. It has no effect on scoring or decisions either way -
purely a viewer.

**Important: the bridge process itself is not included in this release.**
EchoTracker and DataBridge talk to the game via addon-message whispers;
`companion` talks over a local HTTP API on `http://127.0.0.1:8765`. Something
has to sit in the middle relaying between those two transports - in the
original project that's a small Rust proxy (`wow_bridge`) that also handles
the WoW login handshake. It isn't part of this release. To use `companion`
and these addons, you need a bridge process that implements the API
`companion` expects:

- `GET  /api/variables/{key}` - read a cached value
- `POST /api/variables/{key}` - queue a value for delivery into the game
- `POST /api/report/{key}` - update the cache only, never delivered to the game
- `POST /api/cmd/lua` - queue a Lua string for the addon to run via
  `loadstring`/`pcall` on its next poll (**hard ~195-byte budget per call** -
  see `companion/src/bridge.rs`'s `LUA_CMD_BUDGET`)
- `POST /api/read/{key}` - ask the game to report a global variable's current
  value and block for the answer
- `GET  /api/stream` - Server-Sent Events feed of every `key=value` DataBridge
  reports, for anything that wants to watch the data live instead of polling

Every request needs `Authorization: Bearer <token>` - see
`companion/src/bridge.rs`'s `current_token()` for how `companion` expects to
find the token file (`api_token.txt` next to its own executable). On the
addon side, `DataBridge.lua`'s wire format is `DATA|k1=v1<0x1D>k2=v2...`
(0x1D = ASCII Group Separator) sent as an addon-message whisper to yourself,
and `SET|...` in the same format for values pushed back into the game. See
`DataBridge.lua`'s own comments for the exact framing.

## Requirements

- WoW 3.3.5a client, playing on a server with the `ProjectEbonhold` Echo/perk
  system (the addons and `companion`'s scoring both assume its specific
  API/perk data - see [Data files](#data-files) below)
- Rust toolchain (stable) to build `companion`
- A bridge process implementing the API above (not included - see above)
- Python 3, stdlib only, for the `tools/export/` scripts; Python 3 +
  `pip install -r FlaskGUI/requirements.txt` (Flask, flask-sock,
  simple-websocket) only if you want the optional dashboard

## Installing the addons

Copy each folder into your WoW client's `Interface/AddOns/` directory:

```
Interface/AddOns/EchoTracker/    <- WoW_AddOns/EchoTracker/*
Interface/AddOns/DataBridge/     <- WoW_AddOns/DataBridge/*
```

Both are enabled from the in-game AddOns list at the character-select
screen, same as any other addon. EchoTracker declares `DataBridge` as an
optional dependency in its `.toc`, so load order takes care of itself.

## Building companion

```bash
cd companion
cargo build --release
# binary at target/release/companion
```

Run it from a directory containing a `data/` folder (see below) - it
resolves `data/perk_catalog.json` etc. as plain relative paths from the
current working directory, not from its own executable location. The
simplest layout is to run it from this release's root:

```bash
./companion/target/release/companion score --spec dps
```

## Running FlaskGUI (optional)

```bash
cd FlaskGUI
pip install -r requirements.txt
python3 app.py
# open http://127.0.0.1:5000
```

Its `data/session.db`/`data/perk_descriptions.json` paths are resolved
relative to `app.py`'s own location (one level up, `../data/...`), not the
current directory, so it finds this release's `data/` folder regardless of
where you run it from. It also needs the same bridge process `companion`
does (`WOW_PROXY_API` env var, defaults to `http://127.0.0.1:8765`) and
reads that bridge's token from `../bins/api_token.txt` (relative to
`app.py` the same way) - edit `TOKEN_PATH` at the top of `app.py` if your
bridge writes it somewhere else. With no bridge connected it just shows
"OFFLINE" on the Live tab; the History tab still works off `data/session.db`
alone once `companion auto` has actually recorded a session into it.

## Data files

`data/perk_catalog.json`, `data/community_db.json`, and
`data/echo_stat_effects.json` are point-in-time exports of Project
Ebonhold's own perk/Echo definitions and a community pick-frequency
snapshot - static reference data `companion`'s scoring reads at startup,
not something it modifies. `perk_catalog.json` is a hard requirement
(`companion` errors without it); `community_db.json` too; `echo_stat_effects.json`
degrades gracefully if missing or incomplete.

`data/ai_ensemble/` is a trained 5-member value-model ensemble (see
`companion/src/ai.rs`) for **PALADIN/dps only** - `companion score-mode ai`
blends its prediction into the heuristic score. It was trained on a small,
personal dataset (a few hundred confirmed picks from one player's actual
runs), so treat it as a experimental nudge on top of the heuristic, not a
verified oracle - see `companion/commands.md`'s `score-mode` entry for how
the blend actually works and how conservatively it's weighted. Any other
class/spec silently scores as pure "normal" regardless of this setting,
since the ensemble has never seen one. Retraining or extending it to other
classes needs `aimodel`, the Candle-based training tool - not included in
this release; `data/ai_ensemble/`'s `metadata.json` files document the
exact feature/schema format it expects if you want to build your own.

`data/decide_config.example.json` shows every tunable in `companion`'s
decision engine (per-level-bracket take thresholds, banish cutoff, freeze
protect fraction, simultaneous-freeze cap). Copy it to `data/decide_config.json`
and edit to override any of it without recompiling; nothing is required
unless you want to change the defaults.

### Regenerating the data files

`tools/export/` (Python 3, stdlib only) has the scripts that originally
produced the JSON above, included so the pipeline can be adapted rather
than only the static output:

- `export_perk_catalog.py` - reads `perks_data.lua` directly from a live
  Project Ebonhold client install (`ProjectEbonhold/modules/perks/`,
  path overridable via the `EBON_ADDONS_DIR` env var). No live game
  session needed, just the file on disk.
- `export_community_db.py` - reads `SVaddon/EchoBrain/OfflineCommunityDB.lua`
  (included), a static per-class pick-frequency snapshot from an earlier
  standalone addon iteration of this project.
- `export_perk_descriptions.py` - needs a **live** game session and a
  running bridge process (see [How they fit together](#how-they-fit-together)):
  it triggers EchoTracker's own in-game description export and reads the
  results back over the bridge API.
- `export_build_report.py` - reads `data/session.db` (a real `companion`
  training-data database - not included, it's per-player gameplay history)
  and writes a human-readable build report.
- `classify_echo_stats.py` - derives `echo_stat_effects.json`'s
  stat/downside classification from `perk_catalog.json`'s descriptions.

All of them import `sdk/python/app_paths.py` (repo-root-relative path
resolution) and, where needed, `sdk/python/echo_session_db.py` /
`sdk/python/wow_bridge.py` (also included).

## Full command reference

See **[`companion/commands.md`](companion/commands.md)** for every `companion`
subcommand (manual one-shot actions, the `auto` watch-and-execute loop,
character-profile/role handling, the `score-mode`/AI-assisted-scoring
toggle, the WhitelistLiquidator-only `wl` commands) and every in-game
EchoTracker/DataBridge slash command.

## What's *not* in this release

- **The bridge process** (`wow_bridge` in the original project) - see
  [How they fit together](#how-they-fit-together). `companion` and these
  two addons need one; it isn't included.
- **The AI training tool** (`aimodel`) - the trained PALADIN/dps ensemble
  itself IS included (`data/ai_ensemble/`, see [Data files](#data-files)),
  but the Candle-based Rust tool that trained it, and the `data/session.db`
  training data it trained on, are not. Bring your own trainer (the
  `metadata.json` files document the exact feature schema) if you want to
  retrain it or extend it to another class/spec.
- **WhitelistLiquidator** - `companion`'s `wl` subcommand and the
  `wl_*` bridge keys it reads exist for a separate bag-management addon
  that isn't part of this release. Those commands simply return empty/no-op
  without it; everything else in `companion` is unaffected.
- **`ProjectEbonhold/modules/perks/perks_data.lua`** - `export_perk_catalog.py`
  reads this directly from a live server install; it's the server's own
  datapack file, not something this repo can ship a copy of.
- **A `companion` training-data database** (`data/session.db`) - real
  per-player gameplay history, never shared publicly. `export_build_report.py`
  needs one to run; `companion auto` creates one from scratch on first use.
