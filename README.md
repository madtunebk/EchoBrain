# EchoBrain: wow_bridge, EchoTracker, DataBridge & Companion

Components for automating and analyzing the "Echo" perk-draft system on a
World of Warcraft 3.3.5a private server (Project Ebonhold):

| Component | What it is | Runs |
|---|---|---|
| **wow_bridge** | Rust MITM proxy. Sits between the WoW client and the real server, relaying the login handshake and giving addons an HTTP control-plane API. | On your PC, as a separate process |
| **EchoTracker** | WoW addon. Reads the live Echo board/character state and reports it. | Inside the WoW client |
| **DataBridge** | WoW addon. Generic transport - batches/whispers any addon's data out, runs Lua sent back in. | Inside the WoW client |
| **companion** | Rust CLI. Scores boards, decides Take/Reroll/Banish/Freeze, records training data, executes actions. | On your PC, as a separate process |
| **FlaskGUI** *(optional)* | Python web dashboard. Live board/reasoning/charges view plus a full run-history browser, reading the same bridge feed and `companion`'s training database. | On your PC, in a browser |
| **aimodel** *(optional)* | Rust/Candle training tool. Trains the small value-model ensemble `companion score-mode ai` can blend into scoring. | On your PC, one-off training runs |

**Source only - no prebuilt binaries are published or should be trusted.**
`wow_bridge` sits in the middle of your login traffic; the only responsible
way to run something like that is to build it yourself from the Rust source
above, so you (or anyone) can read every line first. See
[Building](#building) below.

## How they fit together

```
              Your PC                                    Your PC
┌─────────────┐  TCP   ┌─────────────┐  addon   ┌──────────────┐   HTTP    ┌───────────┐
│  real WoW    │◄──────►│  wow_bridge  │◄message──┤ EchoTracker/ │           │ companion │
│  client      │        │  (Rust MITM) │  whisper │ DataBridge   │           │  (Rust)   │
└─────────────┘        └──────┬───────┘  (in-game)└──────────────┘           └─────┬─────┘
                               │ HTTP :8765                                        │
                               └────────────────────────────────────────────────────┤
                               │ HTTP :8765                                  HTTP   │
                               └──────────────────────────────────┬─────────────────┘
                                                              ┌────┴──────┐
                                                              │ FlaskGUI  │
                                                              │ (optional)│
                                                              └───────────┘
```

`wow_bridge` relays your real login/world traffic byte-for-byte to the real
server (`realmlist.wtf` points at `127.0.0.1` instead of the real server;
`wow_bridge` forwards everything on to the real address hardcoded in
`wow_bridge/src/auth.rs`) and separately exposes a local HTTP API on
`http://127.0.0.1:8765` that `companion` and FlaskGUI both talk to.
EchoTracker/DataBridge talk to `wow_bridge` from *inside* the game via
addon-message whispers, not HTTP - `wow_bridge` is the only piece that
bridges those two transports.

**wow_bridge never touches your account password or SRP6 private values**
(see `wow_bridge/src/common.rs`'s comments) - the API's bearer token is
pure OS randomness, only *triggered* (not derived from anything
login-related) on each successful auth. Read `wow_bridge/src/auth.rs` and
`api.rs` yourself before trusting this claim; that's the whole point of
shipping source only.

### The local HTTP API (`wow_bridge/src/api.rs`)

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

Every request needs `Authorization: Bearer <token>` - `wow_bridge` writes
the current one to `api_token.txt` next to its own executable (rotating it
on every startup and every successful login); `companion`/FlaskGUI both
read that same file. On the addon side, `DataBridge.lua`'s wire format is
`DATA|k1=v1<0x1D>k2=v2...` (0x1D = ASCII Group Separator) sent as an
addon-message whisper to yourself, and `SET|...` in the same format for
values pushed back into the game - see `DataBridge.lua`'s own comments for
the exact framing.

FlaskGUI is just another client of the same API (`/api/stream` for the live
feed, `/api/cmd/lua` for its Gear Watchdog controls) plus a read-only
connection to `companion`'s own `data/session.db`. It has no effect on
scoring or decisions either way - purely a viewer.

## Requirements

- WoW 3.3.5a client, playing on a server with the `ProjectEbonhold` Echo/perk
  system (the addons and `companion`'s scoring both assume its specific
  API/perk data - see [Data files](#data-files) below)
- Rust toolchain (stable) to build `wow_bridge` and `companion`
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

### Bonus addons

Three smaller, fully optional addons from the same project, each usable on
its own (none of them require EchoTracker/DataBridge/companion to function,
though WhitelistLiquidator and SimpleDamageMeter get extra features when
DataBridge is also loaded):

```
Interface/AddOns/CallBoardHelper/     <- WoW_AddOns/CallBoardHelper/*
Interface/AddOns/WhitelistLiquidator/ <- WoW_AddOns/WhitelistLiquidator/*
Interface/AddOns/SimpleDamageMeter/   <- WoW_AddOns/SimpleDamageMeter/*
```

- **CallBoardHelper** - auto-detects and selects wanted objectives on
  Project Ebonhold's Objectives board (whitelist managed via the in-game
  Quest Browser, minimap toggle + Settings panel); rerolls with a randomized
  delay and a gold-safe cap when none of the 3 offered are wanted. Fully
  standalone, no optional dependency at all.
- **WhitelistLiquidator** - a bag-management watchdog: whitelist items you
  want to keep, everything else gets sold or destroyed with confirmation
  (floor configurable via `/wl confirmquality`); custom server items
  (ID 70000+) are auto-ignored. Warns loudly if a whitelisted/protected item
  somehow ends up unequipped. Reports through DataBridge if it's loaded,
  which is what makes `companion`'s `wl` subcommand and FlaskGUI's "Gear
  Watchdog" card work (see [Full command reference](#full-command-reference));
  fully usable on its own without either.
- **SimpleDamageMeter** - a personal DPS/damage tracker. Reports through
  DataBridge if it's loaded (`companion` records it as `dps_last_fight`,
  visible in FlaskGUI and the training database); fully usable on its own
  without DataBridge too.

## Building

`wow_bridge`, `companion`, and `aimodel` are three independent Cargo
packages - build each from its own folder:

```bash
cd wow_bridge && cargo build --release   # binary at target/release/wow_bridge
cd ../companion && cargo build --release # binary at target/release/companion
cd ../aimodel && cargo build --release   # binary at target/release/aimodel (optional - see aimodel/README.md)
```

Put both built binaries in one folder of your choice (not tracked by git -
see `.gitignore`) so `api_token.txt` (written by `wow_bridge` next to its
own executable) is where `companion`/FlaskGUI both expect to find it:

```bash
mkdir -p bins
cp wow_bridge/target/release/wow_bridge companion/target/release/companion bins/
```

Point your WoW client's `realmlist.wtf` at `127.0.0.1`, then run
`wow_bridge` first (it needs to be up before you log in) and log in
normally:

```bash
./bins/wow_bridge
```

`companion` resolves `data/perk_catalog.json` etc. as plain relative paths
from the current working directory, not its own executable's location - run
it from this release's root (or copy `data/` alongside wherever you put
`bins/`):

```bash
./bins/companion score --spec dps
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
runs), so treat it as an experimental nudge on top of the heuristic, not a
verified oracle - see `companion/commands.md`'s `score-mode` entry for how
the blend actually works and how conservatively it's weighted. Any other
class/spec silently scores as pure "normal" regardless of this setting,
since the ensemble has never seen one.

`aimodel/` is the Candle-based Rust tool that trained it (also included -
see `aimodel/README.md`). It needs a `data/session.db` to train against,
which this release does **not** ship (real per-player gameplay history) -
`companion auto` builds one from scratch as you play. Retrain the
PALADIN/dps ensemble on your own data, or point it at a different
`--class`/`--spec` to extend coverage to another class - see
`aimodel/README.md`'s `train-ensemble` docs.

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
- `export_perk_icons.py` - same live-session requirement as the description
  export above, same idea: triggers EchoTracker's in-game icon/name export
  and writes `perk_display.json`. Together with `perk_descriptions.json`
  this is why board cards need zero live per-refresh traffic for their
  name/icon/tooltip text - only the ~6 currently-locked slots still report
  those live (their tooltip text depends on stack count).
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

- **`ProjectEbonhold/modules/perks/perks_data.lua`** - `export_perk_catalog.py`
  reads this directly from a live server install; it's the server's own
  datapack file, not something this repo can ship a copy of.
- **A `companion` training-data database** (`data/session.db`) - real
  per-player gameplay history, never shared publicly. `export_build_report.py`
  needs one to run; `companion auto` creates one from scratch on first use.
