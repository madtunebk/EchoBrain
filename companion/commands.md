# companion commands

`--api` defaults to `http://127.0.0.1:8765` everywhere - only pass it if
`wow_bridge` runs somewhere else. `--class` and `--spec` are optional
overrides on `score`/`auto`; normally EchoTracker detects the character,
class, talent tree, and scoring role (`tank`/`dps`/`heal`) in game.

## Manual - one-shot actions, you decide

```
companion echo-auto <on|off|status> [--api URL]
```
Arm/disarm auto-execution. `auto` reads this every cycle - no restart
needed either way.

```
companion score-mode <normal|ai|status> [--api URL]
```
Live switch between pure heuristic scoring ("normal", the default) and
heuristic scoring blended with a trained ensemble's prediction ("ai" - see
`src/ai.rs`/`src/scoring.rs`'s `AiContext`/`AI_WEIGHT`). The ensemble itself
lives under `data/ai_ensemble/member_1/`, `member_2/`, etc. (each a
`metadata.json` + `model.safetensors` pair) - a pre-trained PALADIN/dps one
ships with this release; train your own or extend it to another class/spec
with `aimodel` (also included - see `aimodel/README.md`). Without an
ensemble present, `ai` mode silently behaves exactly like "normal" -
`score_card()` never fails or errors over a missing ensemble.
`auto` reads this every cycle, same as `echo-auto` - no restart needed
either way. Also settable once at `auto` startup via `--score-mode
<normal|ai>`.

```
companion board [--api URL]
```
Read-only: prints the current board's raw picks (name/quality/flags) and
charges. No `--class`/`--spec` needed - just "what's on the board right now".

```
companion score [--spec <tank|dps|heal>] [--class X] [--score-mode <normal|ai>] [--api URL]
```
Read-only: prints the current board's full per-card score breakdown plus
the recommendation. Nothing is executed. `--score-mode` overrides just this
one-shot read; otherwise inherits whatever `companion score-mode` last set
live, so this matches what `auto` would actually do right now.

```
companion select <1|2|3> [--api URL]
```
Take a board card.

```
companion reroll [--api URL]
```
Reroll the whole board.

```
companion banish <1|2|3> [--api URL]
```
Banish a board card.

```
companion freeze <1|2|3> [--api URL]
```
Freeze a board card.

```
companion echo-native <on|off|status> [--api URL]
```
Same live toggle as EchoTracker's own `/echonative` slash command (see
below), just reachable from the CLI - calls `SlashCmdList.ECHONATIVE(...)`
through the same `/api/cmd/lua` transport every other command here uses.
`status` prints its result in the game's chat frame, not the terminal - the
addon's own `print()` call, not something this command captures.

```
companion wl <status|equipped|whitelist|alert|protect|dismiss|clean> [--api URL]
companion wl add <item_id> [--api URL]
companion wl remove <item_id> [--api URL]
```
Controls for the WhitelistLiquidator addon's gear-protection watchdog (not
part of this release - see its own repo/folder). `status` shows whitelist/
protected/sell/destroy counts; `equipped` lists every tracked equip slot and
its protection tag; `whitelist` lists whitelisted item IDs/names; `alert`
shows the current in-game unequip warning if one is pending; `protect`/
`dismiss` act on that warning remotely; `add`/`remove` edit the whitelist by
item ID; `clean` runs `Clean()` (a merchant must be open in-game). All of
these read/write the same `wl_*` bridge keys the addon pushes via
`DataBridge_SendLarge` - if WhitelistLiquidator isn't installed, they just
return empty/no-op.

```
companion lua <file.lua> [--api URL]
```
Runs a Lua script file in-game, same transport as every other command here
(`/api/cmd/lua`). That endpoint has a hard **~195-byte budget** - anything
longer is silently dropped server-side (the request still returns 200 OK,
but the code never runs). `companion lua` checks this up front and refuses
loudly with the exact byte count instead of sending a payload that would
just vanish. Whether the script is otherwise valid/safe for the client's
sandbox is on you - this only enforces the transport size limit.

## Auto - the watch-and-execute loop

### Character profile and role

```
companion profile status [--api URL]
companion profile set-role <tank|dps|heal> [--api URL]
```

`profile set-role` stores a role override against the current character GUID.
Normally it is unnecessary: characters using the current Prestige system keep
their complete talent tree after Prestige, including at level 1, so EchoTracker
can detect the spec and role automatically. Use the override only for an older
pre-Prestige character whose talents are genuinely reported as `Unspent`, or
for another ambiguous/custom talent layout. Later runs reuse the saved override
automatically. `profile status` shows the detected character, talent state,
role, and saved role override. Neither command works before the character has
entered the world, preventing stale character assignment.

When an `Unspent`/ambiguous profile has no saved override, a running
`companion auto` now opens an EchoTracker role selector in game. Clicking
Tank, DPS, or Heal sends the GUID-bound choice back and companion persists it
automatically. `/echorole` reopens the pending selector. The CLI command remains
available as a fallback.

`set-role` is a `profile` subcommand, not an option to `auto`. This is correct:

```bash
bins/companion profile set-role dps
```

This is not valid:

```bash
bins/companion auto --set-role dps
```

Normal startup after entering the world:

```bash
bins/companion auto --auto 1
```

Only when startup reports `role is unknown`, inspect and set the fallback once:

```bash
bins/companion profile status
bins/companion profile set-role dps
bins/companion auto --auto 1
```

For a tank or healer, replace `dps` with `tank` or `heal`. The override is
stored by character GUID, so setting Kaeos does not set Myrodrolan (and vice
versa). `Unspent` on an old pre-Prestige character is the exceptional fallback
case, not expected behavior for a normal Prestige character.

```
companion auto [--auto <0|1>] [--api URL]
```
Waits without opening a session or acting until `PLAYER_ENTERING_WORLD` and
a complete character profile are reported. It also requires the current
`wow_bridge` process to observe a live world-server TCP connection; persisted
addon cache can never satisfy this guard. If WoW is closed, companion remains
at `waiting...` and cannot replay a stale profile, board, or fight. It then scores/records every
board in a session belonging to that character GUID. Switching characters
closes the old context and creates/resumes a separate profile session.
Class and spec/role are detected from the active character profile; they do
not need to be supplied on the command line.
`--auto 1` enables
Take/Reroll/Banish/Freeze execution immediately; `--auto 0` starts in
advisor/collector-only mode. If omitted, the existing live `echo_auto`
state is preserved. `echo-auto` remains available as a runtime emergency
switch, but is no longer a required second startup command. With auto off,
the process still reports the AI's suggestion
(`echo_suggested`/`echo_suggested_action`, drives the in-game glow) but
executes nothing itself.

Telemetry v2 records class-independent effective hero stats (attributes,
attack/ranged/spell/healing power, crit, haste, hit, expertise, armor,
health/mana, and main-hand damage/speed). Companion snapshots them when they
change and links the current snapshot to every decision and fight. Existing
pre-v2 rows remain intact and are explicitly marked as missing stats by the
trainer rather than interpreted as real zero values.

## In-game EchoTracker commands

```
/echonative off
/echonative on
/echonative status
/echosettings
/echorole
```

Controls the large native ProjectEbonhold perk picker loaded by the server
datapack. `off` hides it and disables its clickable frames while keeping the
underlying PerkService active, so EchoTracker, companion, telemetry, and
autopilot continue to work. `on` restores the native picker, and `status`
prints the current setting. The setting persists across reloads/restarts.
This is implemented as a runtime EchoTracker hook; it does not modify or
repack `patch-4.MPQ`. `/echosettings` opens the same persistent toggle in
the standard `Interface -> AddOns -> EchoTracker` settings panel. That panel
also controls compact-icon visibility, icon size (28-80 px), frame-position
locking, AI recommendation colors, and manual icon clicks.

## In-game DataBridge settings

```
/rustsettings
```

Opens `Interface -> AddOns -> Data Bridge`, with controls for automatic
reverse-channel polling, its interval (0.5-10 seconds), and debug chat
messages. It also provides `Poll now` and `Queue status` buttons. Existing
`/rustauto`, `/rustdebug`, `/rustpoll`, and `/rustqueue` commands remain
available.

Also reports, regardless of `echo_auto`, straight into `wow_bridge`'s
variable store (no addon-message byte budget involved - these never touch
DataBridge, `bridge.set()` is a plain HTTP write) so FlaskGUI's dashboard
can show them live:
- `echo_reason` - the decide() engine's own reasoning trail for whatever it
  just suggested/executed, joined with `" | "`. Also printed to console
  whenever it changes.
- `echo_group_budget` - this 20-level group's reroll/banish/freeze
  spent/allocated, as `"<lo+1>-<hi>|reroll:spent/alloc;banish:...;freeze:..."`.
  Updates every cycle (not just when a board is up) since the budget is a
  persistent per-session stat.

### Tuning without a recompile

`score`/`auto` both load `data/decide_config.json` if present (see
`data/decide_config.example.json` for the exact shape - copy it to
`decide_config.json` and edit). Missing file, or any field missing from it,
falls back to the exact hardcoded defaults (`take_threshold` 55/45/35 per
bracket, banish junk cutoff `<15`, `freeze_protect_fraction` 0.8,
`simultaneous_freeze_cap` 2) - nothing to create unless you actually want to
change something.
