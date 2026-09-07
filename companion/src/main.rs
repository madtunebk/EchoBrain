// Companion: the Rust home for tools/live/*.py's live-play pipeline.
// Fully separate process from wow_bridge - talks to it only over the same
// local HTTP API sdk/python/wow_bridge.py already uses. One binary, one
// subcommand per ported tool (like `git <subcommand>`), so the end state is
// still just two executables total (wow_bridge + companion), not a growing
// pile of small binaries.
//
// Ported so far: echo-auto, banish, freeze, reroll, select (manual,
// one-shot actions) and now the real core - score_echo_board.py's
// scoring/decide engine (board.rs/catalog.rs/scoring.rs/decide.rs),
// echo_session_db.py (session_db.rs), and echo_autopilot.py's watch loop
// (autopilot.rs, the `auto` subcommand) plus a read-only `score` subcommand
// for manual play with AI guidance visible but nothing auto-executed.
// tools/live/echo_board_logger.py, deploy_script.py and toggle_addon.py
// remain Python - dev-convenience/diagnostic utilities, not part of the
// live decide/act loop.

mod ai;
mod autopilot;
mod board;
mod bridge;
mod catalog;
mod decide;
mod scoring;
mod session_db;
mod whitelist;

use board::Charges;
use bridge::WowBridge;
use std::env;
use std::process::ExitCode;

const DEFAULT_API: &str = "http://127.0.0.1:8765";

fn main() -> ExitCode {
    let args: Vec<String> = env::args().collect();
    match args.get(1).map(String::as_str) {
        Some("echo-auto") => echo_auto_cmd(&args[2..]),
        Some("echo-native") => echo_native(&args[2..]),
        Some("score-mode") => score_mode_cmd(&args[2..]),
        Some("banish") => banish(&args[2..]),
        Some("freeze") => freeze(&args[2..]),
        Some("reroll") => reroll(&args[2..]),
        Some("select") => select(&args[2..]),
        Some("board") => board_cmd(&args[2..]),
        Some("lua") => lua_cmd(&args[2..]),
        Some("score") => score(&args[2..]),
        Some("auto") => auto(&args[2..]),
        Some("profile") => profile(&args[2..]),
        Some("wl") => wl_cmd(&args[2..]),
        _ => {
            print_usage();
            ExitCode::FAILURE
        }
    }
}

fn print_usage() {
    eprintln!("usage: companion <command> [args...]");
    eprintln!();
    eprintln!("commands:");
    eprintln!("  echo-auto <on|off|status> [--api URL]           turn Echo autopilot execution on/off");
    eprintln!("  echo-native <on|off|status> [--api URL]         toggle EchoTracker's \"native server perk picker\" overlay (= /echonative in-game)");
    eprintln!("  score-mode <normal|ai|status> [--api URL]       live switch: pure heuristic scoring, or heuristic blended with the AI ensemble's prediction");
    eprintln!(
        "  banish <1|2|3> [--api URL]                     banish a board card, no confirmation"
    );
    eprintln!(
        "  freeze <1|2|3> [--api URL]                     freeze a board card, no confirmation"
    );
    eprintln!(
        "  reroll [--api URL]                             reroll the whole board, no confirmation"
    );
    eprintln!(
        "  select <1|2|3> [--api URL]                     take a board card, no confirmation"
    );
    eprintln!("  board [--api URL]                              read-only: print the current board's raw picks (id/quality/flags), no class/spec/scoring needed");
    eprintln!("  lua <file.lua> [--api URL]                     execute a Lua file in game");
    eprintln!("  score [--spec <tank|dps|heal>] [--class X] [--api URL]");
    eprintln!("                                                  read-only: print the current board's full score breakdown + recommendation");
    eprintln!("  auto [--auto <0|1>] [--api URL]");
    eprintln!("                                                  continuously collect/score; --auto 1 executes actions, --auto 0 is advisor-only");
    eprintln!("  profile set-role <tank|dps|heal> [--api URL]    persist the scoring role for the current character GUID");
    eprintln!("  profile status [--api URL]                      show the detected current profile and saved role");
    eprintln!("  wl status [--api URL]                           WhitelistLiquidator: whitelist/protected/sell/destroy counts");
    eprintln!("  wl equipped [--api URL]                         list tracked equip slots and their protection status");
    eprintln!("  wl whitelist [--api URL]                        list whitelisted item IDs/names");
    eprintln!("  wl alert [--api URL]                            show the current unequip warning, if any");
    eprintln!("  wl protect [--api URL]                          click PROTECT on the current unequip warning");
    eprintln!("  wl dismiss [--api URL]                          click DISMISS on the current unequip warning");
    eprintln!("  wl add <item_id> [--api URL]                    add an item ID to the whitelist");
    eprintln!("  wl remove <item_id> [--api URL]                 remove an item ID from the whitelist");
    eprintln!("  wl clean [--api URL]                             run Clean() (merchant must be open in-game)");
}

/// Shared `--api`/`--class`/`--spec [--class X] --spec Y` arg parsing for
/// `score`/`auto` - both take the same shape (score's --class is optional,
/// same as auto's).
struct SpecArgs {
    klass: Option<String>,
    spec: Option<String>,
    api: String,
    auto_enabled: Option<bool>,
    score_mode: Option<String>,
}

fn parse_spec_args(args: &[String], _usage: &str) -> Result<SpecArgs, ExitCode> {
    let mut klass: Option<String> = None;
    let mut spec: Option<String> = None;
    let mut api = DEFAULT_API.to_string();
    let mut auto_enabled = None;
    let mut score_mode: Option<String> = None;

    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--api" => {
                i += 1;
                if let Some(v) = args.get(i) {
                    api = v.clone();
                }
            }
            "--class" => {
                i += 1;
                if let Some(v) = args.get(i) {
                    klass = Some(v.clone());
                }
            }
            "--spec" => {
                i += 1;
                match args.get(i).map(String::as_str) {
                    Some(s @ ("tank" | "dps" | "heal")) => spec = Some(s.to_string()),
                    other => {
                        eprintln!("invalid --spec: {other:?} (must be tank, dps, or heal)");
                        return Err(ExitCode::FAILURE);
                    }
                }
            }
            "--auto" => {
                i += 1;
                match args.get(i).map(String::as_str) {
                    Some("1") => auto_enabled = Some(true),
                    Some("0") => auto_enabled = Some(false),
                    other => {
                        eprintln!("invalid --auto: {other:?} (must be 0 or 1)");
                        return Err(ExitCode::FAILURE);
                    }
                }
            }
            "--score-mode" => {
                i += 1;
                match args.get(i).map(String::as_str) {
                    Some(m @ ("normal" | "ai")) => score_mode = Some(m.to_string()),
                    other => {
                        eprintln!("invalid --score-mode: {other:?} (must be normal or ai)");
                        return Err(ExitCode::FAILURE);
                    }
                }
            }
            other => {
                eprintln!("unknown argument: {other}");
                return Err(ExitCode::FAILURE);
            }
        }
        i += 1;
    }

    Ok(SpecArgs {
        klass,
        spec,
        api,
        auto_enabled,
        score_mode,
    })
}

fn data_path(name: &str) -> std::path::PathBuf {
    std::path::Path::new("data").join(name)
}

fn profile(args: &[String]) -> ExitCode {
    let mut api = DEFAULT_API.to_string();
    let mut command: Option<String> = None;
    let mut role: Option<String> = None;
    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--api" => {
                i += 1;
                if let Some(v) = args.get(i) {
                    api = v.clone();
                }
            }
            value if command.is_none() => command = Some(value.to_string()),
            value if role.is_none() => role = Some(value.to_string()),
            other => {
                eprintln!("unknown argument: {other}");
                return ExitCode::FAILURE;
            }
        }
        i += 1;
    }
    let bridge = WowBridge::new(&api);
    if bridge
        .get("bridge_world_connected")
        .ok()
        .flatten()
        .as_deref()
        != Some("1")
        || bridge.get("echo_in_world").ok().flatten().as_deref() != Some("1")
    {
        eprintln!("no character in world; enter the game and /reload first");
        return ExitCode::FAILURE;
    }
    let current = match autopilot::read_profile(&bridge) {
        Ok(Some(p)) => p,
        Ok(None) => {
            eprintln!("character profile is not ready yet");
            return ExitCode::FAILURE;
        }
        Err(e) => {
            eprintln!("error: {e}");
            return ExitCode::FAILURE;
        }
    };
    let conn = match session_db::open(&data_path("session.db")) {
        Ok(c) => c,
        Err(e) => {
            eprintln!("error opening session DB: {e}");
            return ExitCode::FAILURE;
        }
    };
    match command.as_deref() {
        Some("set-role") => {
            let Some(role) = role.filter(|r| matches!(r.as_str(), "tank" | "dps" | "heal")) else {
                eprintln!("usage: companion profile set-role <tank|dps|heal> [--api URL]");
                return ExitCode::FAILURE;
            };
            if let Err(e) = session_db::set_profile_role_override(&conn, &current, &role) {
                eprintln!("error: {e}");
                return ExitCode::FAILURE;
            }
            println!(
                "profile {} ({}, {}) saved role={role}",
                current.name, current.class, current.guid
            );
            ExitCode::SUCCESS
        }
        Some("status") => {
            let saved = session_db::profile_role_override(&conn, &current.guid)
                .ok()
                .flatten()
                .unwrap_or_else(|| "not set".to_string());
            println!(
                "{} — {} {} / {} / detected role={} / saved role={saved}",
                current.name, current.race, current.class, current.talent_spec, current.role
            );
            ExitCode::SUCCESS
        }
        _ => {
            eprintln!("usage: companion profile <set-role ROLE|status> [--api URL]");
            ExitCode::FAILURE
        }
    }
}

/// New - no Python equivalent existed (score_echo_board.py always required
/// --class/--spec to do full scoring). Read-only, no action taken: just
/// resolves the current board's raw picks to names/quality/flags, for a
/// quick look without the scoring ceremony `score` needs. Catalog lookup
/// is best-effort (load_json_optional) - a missing/stale catalog entry
/// just falls back to "?" instead of failing the whole command.
fn board_cmd(args: &[String]) -> ExitCode {
    let mut api = DEFAULT_API.to_string();
    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--api" => {
                i += 1;
                if let Some(v) = args.get(i) {
                    api = v.clone();
                }
            }
            other => {
                eprintln!("unknown argument: {other}");
                return ExitCode::FAILURE;
            }
        }
        i += 1;
    }

    let bridge = WowBridge::new(&api);
    let catalog: catalog::Catalog =
        catalog::load_json_optional(&data_path("perk_catalog.json")).unwrap_or_default();

    let level: i64 = bridge
        .get("echo_level")
        .ok()
        .flatten()
        .and_then(|s| s.parse().ok())
        .unwrap_or(1);

    let board_raw = match bridge.get("echo_board") {
        Ok(v) => v.unwrap_or_default(),
        Err(e) => {
            eprintln!("error: {e}");
            return ExitCode::FAILURE;
        }
    };

    if board_raw.is_empty() {
        println!("no board offered right now (level {level})");
        return ExitCode::SUCCESS;
    }

    println!("=== Echo board, level {level} ===");
    for card in board::parse_board(&board_raw) {
        let name = catalog
            .get(&card.spell_id)
            .and_then(|e| e.comment.as_deref())
            .map(catalog::display_name)
            .unwrap_or("?");
        let flags = [
            ("frozen", card.frozen),
            ("carried", card.carried),
            ("guaranteed", card.guaranteed),
        ]
        .into_iter()
        .filter(|(_, v)| *v)
        .map(|(f, _)| f)
        .collect::<Vec<_>>()
        .join(",");
        let flags = if flags.is_empty() {
            "-".to_string()
        } else {
            flags
        };
        println!(
            "{}. {} [{}]  quality={}  flags={flags}",
            card.index0 + 1,
            name,
            card.spell_id,
            scoring::quality_name(card.quality)
        );
    }

    let charges_raw = bridge
        .get("echo_charges")
        .ok()
        .flatten()
        .unwrap_or_default();
    let charges = board::parse_charges(&charges_raw);
    println!(
        "\ncharges: reroll {}/{}  banish {} left  freeze {}/{}",
        charges.reroll_used,
        charges.reroll_total,
        charges.banish_remaining,
        charges.freeze_used,
        charges.freeze_total
    );

    ExitCode::SUCCESS
}

/// New - no Python equivalent existed. Reads a .lua file and queues it via
/// /api/cmd/lua, same transport execute() uses for real Take/Reroll/Banish/
/// Freeze calls. Enforces bridge::LUA_CMD_BUDGET up front and refuses
/// (loud, exact byte count) rather than sending a payload that would just
/// silently vanish server-side - past that size the POST still returns
/// 200 OK, but the code never reaches loadstring (see bridge.rs). Whether
/// the script is safe/valid Lua for this client's sandbox is on the
/// caller - this only enforces the transport size limit, nothing about
/// script content.
fn lua_cmd(args: &[String]) -> ExitCode {
    let mut api = DEFAULT_API.to_string();
    let mut path: Option<String> = None;

    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--api" => {
                i += 1;
                if let Some(v) = args.get(i) {
                    api = v.clone();
                }
            }
            other => {
                if path.is_some() {
                    eprintln!("unknown argument: {other}");
                    return ExitCode::FAILURE;
                }
                path = Some(other.to_string());
            }
        }
        i += 1;
    }

    let Some(path) = path else {
        eprintln!("usage: companion lua <file.lua> [--api URL]");
        return ExitCode::FAILURE;
    };

    let code = match std::fs::read_to_string(&path) {
        Ok(c) => c,
        Err(e) => {
            eprintln!("error reading {path}: {e}");
            return ExitCode::FAILURE;
        }
    };
    let trimmed = code.trim();

    if trimmed.is_empty() {
        eprintln!("{path} is empty - nothing to run");
        return ExitCode::FAILURE;
    }
    if trimmed.len() > bridge::LUA_CMD_BUDGET {
        eprintln!(
            "error: {path} is {} bytes, over the {}-byte budget /api/cmd/lua silently enforces \
             (the request would return 200 OK but the code would never reach loadstring in-game). \
             Shorten the script - long-bracket macro text, comments, and indentation all count.",
            trimmed.len(),
            bridge::LUA_CMD_BUDGET
        );
        return ExitCode::FAILURE;
    }

    let bridge = WowBridge::new(&api);
    match bridge.run_lua(trimmed) {
        Ok(()) => {
            println!("queued {} bytes of Lua from {path}", trimmed.len());
            ExitCode::SUCCESS
        }
        Err(e) => {
            eprintln!("error: {e}");
            ExitCode::FAILURE
        }
    }
}

/// Ported from tools/live/score_echo_board.py's main() - read-only, no
/// action taken anywhere. --class is optional (auto-detected from
/// echo_class), --spec is required.
fn score(args: &[String]) -> ExitCode {
    let parsed = match parse_spec_args(
        args,
        "usage: companion score [--spec <tank|dps|heal>] [--class X] [--api URL]",
    ) {
        Ok(p) => p,
        Err(code) => return code,
    };
    if parsed.auto_enabled.is_some() {
        eprintln!("--auto is only valid with `companion auto`");
        return ExitCode::FAILURE;
    }

    let catalog = match catalog::load_json(&data_path("perk_catalog.json")) {
        Ok(c) => c,
        Err(e) => {
            eprintln!("error: {e}");
            return ExitCode::FAILURE;
        }
    };
    let community_db = match catalog::load_json(&data_path("community_db.json")) {
        Ok(c) => c,
        Err(e) => {
            eprintln!("error: {e}");
            return ExitCode::FAILURE;
        }
    };
    let stat_effects = match catalog::load_json_optional(&data_path("echo_stat_effects.json")) {
        Ok(c) => c,
        Err(e) => {
            eprintln!("error: {e}");
            return ExitCode::FAILURE;
        }
    };

    let bridge = WowBridge::new(&parsed.api);

    if bridge
        .get("bridge_world_connected")
        .ok()
        .flatten()
        .as_deref()
        != Some("1")
        || bridge.get("echo_in_world").ok().flatten().as_deref() != Some("1")
    {
        eprintln!("player is not in world yet; waiting telemetry is not available for scoring");
        return ExitCode::FAILURE;
    }

    let klass = match parsed.klass {
        Some(k) => k,
        None => match bridge.get("echo_class") {
            Ok(Some(k)) if !k.is_empty() => k,
            Ok(_) => {
                eprintln!("no --class given and echo_class not available yet - pass --class or wait for EchoTracker to report it");
                return ExitCode::FAILURE;
            }
            Err(e) => {
                eprintln!("error: {e}");
                return ExitCode::FAILURE;
            }
        },
    };
    let spec = match parsed.spec {
        Some(s) => s,
        None => match bridge.get("echo_role") {
            Ok(Some(s)) if matches!(s.as_str(), "tank" | "dps" | "heal") => s,
            _ => {
                eprintln!(
                    "automatic role is not available yet; wait for EchoTracker or pass --spec"
                );
                return ExitCode::FAILURE;
            }
        },
    };

    let board_raw = match bridge.get("echo_board") {
        Ok(v) => v.unwrap_or_default(),
        Err(e) => {
            eprintln!("error: {e}");
            return ExitCode::FAILURE;
        }
    };
    let charges_raw = bridge
        .get("echo_charges")
        .ok()
        .flatten()
        .unwrap_or_default();
    let level: i64 = bridge
        .get("echo_level")
        .ok()
        .flatten()
        .and_then(|s| s.parse().ok())
        .unwrap_or(1);

    if board_raw.is_empty() {
        println!("no board offered right now (level {level})");
        return ExitCode::SUCCESS;
    }

    let cards = board::parse_board(&board_raw);
    let owned = match board::fetch_owned(&bridge) {
        Ok(o) => o,
        Err(e) => {
            eprintln!("error: {e}");
            return ExitCode::FAILURE;
        }
    };
    let charges: Charges = board::parse_charges(&charges_raw);

    // `--score-mode` overrides for just this one-shot read; otherwise
    // inherits whatever `companion score-mode` last set live (same value
    // `companion auto` checks every cycle), so a manual `score` matches
    // what auto would actually do right now.
    let score_mode = parsed.score_mode.clone().unwrap_or_else(|| {
        bridge
            .get("echo_score_mode")
            .ok()
            .flatten()
            .unwrap_or_else(|| "normal".to_string())
    });
    let ai_ensemble = if score_mode == "ai" {
        match ai::Ensemble::load(&data_path("ai_ensemble")) {
            Ok(e) => e,
            Err(e) => {
                eprintln!("warning: failed to load data/ai_ensemble ({e}) - scoring without it");
                None
            }
        }
    } else {
        None
    };
    let hero_stats_values: Option<[f64; 23]> = bridge
        .get("hero_stats")
        .ok()
        .flatten()
        .and_then(|raw| autopilot::parse_hero_stats(&raw))
        .map(|s| s.values);
    let ai_context = ai_ensemble.as_ref().map(|ensemble| scoring::AiContext {
        ensemble,
        level,
        tier: bridge
            .get("hardmode_tier")
            .ok()
            .flatten()
            .and_then(|s| s.parse().ok())
            .unwrap_or(0),
        prestige: bridge
            .get("ash_prestiges")
            .ok()
            .flatten()
            .and_then(|s| s.parse().ok())
            .unwrap_or(0),
        ash_bonus_pct: bridge
            .get("ash_bonus_pct")
            .ok()
            .flatten()
            .and_then(|s| s.parse().ok())
            .unwrap_or(0.0),
        hero_stats: hero_stats_values.as_ref(),
    });

    println!(
        "=== Echo board, level {level}, {klass} ({}), score-mode={score_mode} ===",
        spec
    );
    let results: Vec<_> = cards
        .iter()
        .map(|c| {
            scoring::score_card(
                c,
                &catalog,
                &community_db,
                &stat_effects,
                &klass,
                &spec,
                &owned,
                ai_context.as_ref(),
            )
        })
        .collect();
    for (i, result) in results.iter().enumerate() {
        match result {
            Err(miss) => println!("{}. {}: {}", i + 1, miss.spell_id, miss.error),
            Ok(r) => {
                let flags = [
                    ("frozen", r.frozen),
                    ("carried", r.carried),
                    ("guaranteed", r.guaranteed),
                ]
                .into_iter()
                .filter(|(_, v)| *v)
                .map(|(f, _)| f)
                .collect::<Vec<_>>()
                .join(",");
                let flags = if flags.is_empty() {
                    "-".to_string()
                } else {
                    flags
                };
                println!(
                    "{}. {} [{}]  quality={}  families={}  owned={}  flags={flags}",
                    i + 1,
                    r.name,
                    r.spell_id,
                    r.quality_name,
                    r.families.join("/"),
                    r.owned
                );
                let s = &r.score;
                println!(
                    "   score: quality={:.1} x rarity={:.2}  spec_fit={:.1}  ownership={:.1}  community={:.1}  downside={:.1}  stat_priority={:.1}  => total={:.1}",
                    s.quality, s.rarity_multiplier, s.spec_fit, s.ownership, s.community, s.downside, s.stat_priority, s.total
                );
                if let Some(ai_z) = s.ai_z {
                    println!(
                        "   ai: z={ai_z:.2} (ensemble's own normalized signal) contributed {:.1} pts",
                        s.ai_component
                    );
                }
                if !r.downsides.is_empty() {
                    println!("   downsides: {}", r.downsides.join(", "));
                }
            }
        }
    }

    println!(
        "\ncharges: reroll {}/{}  banish {} left  freeze {}/{}",
        charges.reroll_used,
        charges.reroll_total,
        charges.banish_remaining,
        charges.freeze_used,
        charges.freeze_total
    );

    let decide_config = decide::load_config(&data_path("decide_config.json"));
    let decision = decide::decide(&results, level, &charges, &decide_config);
    let target_desc = decision
        .target
        .as_ref()
        .map(|t| format!(" -> {} [{}] (slot {})", t.name, t.spell_id, t.index0 + 1))
        .unwrap_or_default();
    println!(
        "\n=== Recommendation (info only, nothing executed): {}{target_desc} ===",
        decision.action.as_str()
    );
    for reason in &decision.reasons {
        println!("  - {reason}");
    }

    ExitCode::SUCCESS
}

/// `companion auto` - starts the profile-aware collection and decision loop.
fn auto(args: &[String]) -> ExitCode {
    let parsed = match parse_spec_args(
        args,
        "usage: companion auto [--auto <0|1>] [--score-mode <normal|ai>] [--api URL]",
    ) {
        Ok(p) => p,
        Err(code) => return code,
    };
    if let Err(e) = autopilot::run(autopilot::AutoArgs {
        klass: parsed.klass,
        spec: parsed.spec,
        api: parsed.api,
        initial_auto: parsed.auto_enabled,
        initial_score_mode: parsed.score_mode,
    }) {
        eprintln!("error: {e:?}");
        return ExitCode::FAILURE;
    }
    ExitCode::SUCCESS
}

/// NEW - no Python equivalent existed. EchoTracker.lua's own
/// `SetNativePickerEnabled`/`IsNativePickerEnabled` are file-local, not
/// reachable from a `/api/cmd/lua` payload's plain global environment - but
/// its `/echonative on|off|status` slash command IS reachable, since
/// `SlashCmdList.ECHONATIVE` (a real global WoW builds for every registered
/// slash command) holds a reference to that same local closure. Calling it
/// this way is exactly equivalent to typing `/echonative on|off|status`
/// in-game. "status" has no CLI-visible output of its own (EchoTracker
/// prints it to the in-game chat frame, not back over the bridge) - it's
/// included anyway so the option exists without needing a raw `companion
/// lua` one-off file just to check.
fn echo_native(args: &[String]) -> ExitCode {
    let mut state: Option<&str> = None;
    let mut api = DEFAULT_API.to_string();

    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--api" => {
                i += 1;
                if let Some(v) = args.get(i) {
                    api = v.clone();
                }
            }
            "on" | "off" | "status" => state = Some(args[i].as_str()),
            other => {
                eprintln!("unknown argument: {other}");
                return ExitCode::FAILURE;
            }
        }
        i += 1;
    }

    let Some(state) = state else {
        eprintln!("usage: companion echo-native <on|off|status> [--api URL]");
        return ExitCode::FAILURE;
    };

    let bridge = WowBridge::new(&api);
    match bridge.run_lua(&format!("SlashCmdList.ECHONATIVE(\"{state}\")")) {
        Ok(()) => {
            if state == "status" {
                println!("sent - check the in-game chat frame for the result");
            } else {
                println!("native server perk picker: {state}");
            }
            ExitCode::SUCCESS
        }
        Err(e) => {
            eprintln!("error: {e}");
            ExitCode::FAILURE
        }
    }
}

/// Ported from tools/live/echo_toggle.py - same behavior: "status" is a
/// pure cache read (no side effect), "on"/"off" queues the value for the
/// addon's next poll. echo_autopilot.py checks this every cycle, so no
/// restart is needed on either side for a toggle to take effect. Named
/// after the `echo_auto` variable it controls (was `echo-toggle` - "toggle"
/// reads as "flip the current state," but this always sets an explicit
/// on/off/status, never flips blindly).
fn echo_auto_cmd(args: &[String]) -> ExitCode {
    let mut state: Option<&str> = None;
    let mut api = DEFAULT_API.to_string();

    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--api" => {
                i += 1;
                if let Some(v) = args.get(i) {
                    api = v.clone();
                }
            }
            "on" | "off" | "status" => state = Some(args[i].as_str()),
            other => {
                eprintln!("unknown argument: {other}");
                return ExitCode::FAILURE;
            }
        }
        i += 1;
    }

    let Some(state) = state else {
        eprintln!("usage: companion echo-auto <on|off|status> [--api URL]");
        return ExitCode::FAILURE;
    };

    let bridge = WowBridge::new(&api);

    let result = if state == "status" {
        bridge.get("echo_auto").map(|current| {
            println!(
                "echo_auto = {}",
                current.unwrap_or_else(|| "off".to_string())
            );
        })
    } else {
        bridge.set("echo_auto", state).map(|()| {
            println!("echo_auto = {state}");
        })
    };

    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("error: {e}");
            ExitCode::FAILURE
        }
    }
}

/// NEW - no Python equivalent existed. Live switch between pure heuristic
/// scoring ("normal", the default and only mode that ever existed before
/// this) and heuristic scoring blended with the AI ensemble's prediction
/// ("ai" - see scoring.rs's AiContext/AI_WEIGHT and ai.rs). Same
/// bridge-cache pattern as echo-auto/echo-native: `companion auto` checks
/// `echo_score_mode` fresh every cycle, so flipping this takes effect
/// immediately without a restart. Falls back to pure normal scoring for any
/// class/spec the ensemble wasn't trained on, regardless of this setting.
fn score_mode_cmd(args: &[String]) -> ExitCode {
    let mut state: Option<&str> = None;
    let mut api = DEFAULT_API.to_string();

    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--api" => {
                i += 1;
                if let Some(v) = args.get(i) {
                    api = v.clone();
                }
            }
            "normal" | "ai" | "status" => state = Some(args[i].as_str()),
            other => {
                eprintln!("unknown argument: {other}");
                return ExitCode::FAILURE;
            }
        }
        i += 1;
    }

    let Some(state) = state else {
        eprintln!("usage: companion score-mode <normal|ai|status> [--api URL]");
        return ExitCode::FAILURE;
    };

    let bridge = WowBridge::new(&api);

    let result = if state == "status" {
        bridge.get("echo_score_mode").map(|current| {
            println!(
                "echo_score_mode = {}",
                current.unwrap_or_else(|| "normal".to_string())
            );
        })
    } else {
        bridge.set("echo_score_mode", state).map(|()| {
            println!("echo_score_mode = {state}");
        })
    };

    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("error: {e}");
            ExitCode::FAILURE
        }
    }
}

/// Ported from tools/live/banish_echo.py - MANUAL, EXPLICIT ACTION: calls
/// the real ProjectEbonhold.PerkService.BanishPerk(index) in-game via
/// /api/cmd/lua. Nothing else in this pipeline calls this on its own -
/// permanently consumes one banish charge and replaces that card, no undo.
fn banish(args: &[String]) -> ExitCode {
    let mut index: Option<i32> = None;
    let mut api = DEFAULT_API.to_string();

    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--api" => {
                i += 1;
                if let Some(v) = args.get(i) {
                    api = v.clone();
                }
            }
            other => match other.parse::<i32>() {
                Ok(n) if (1..=3).contains(&n) => index = Some(n),
                _ => {
                    eprintln!("invalid card index: {other} (must be 1, 2, or 3)");
                    return ExitCode::FAILURE;
                }
            },
        }
        i += 1;
    }

    let Some(index) = index else {
        eprintln!("usage: companion banish <1|2|3> [--api URL]");
        return ExitCode::FAILURE;
    };

    let bridge = WowBridge::new(&api);

    let before = match bridge.get("echo_board") {
        Ok(v) => v.unwrap_or_default(),
        Err(e) => {
            eprintln!("error: {e}");
            return ExitCode::FAILURE;
        }
    };
    println!("current board: {before}");

    let index0 = index - 1;
    let lua = format!(
        "local ok = ProjectEbonhold.PerkService.BanishPerk({index0}) DataBridge_Send(\"echo_banish_result\", tostring(ok))"
    );
    if let Err(e) = bridge.run_lua(&lua) {
        eprintln!("error: {e}");
        return ExitCode::FAILURE;
    }
    println!("banish request sent, waiting for server response...");
    std::thread::sleep(std::time::Duration::from_secs_f64(2.0));

    let result = bridge.get("echo_banish_result").ok().flatten();
    let after = bridge.get("echo_board").ok().flatten().unwrap_or_default();
    let charges = bridge
        .get("echo_charges")
        .ok()
        .flatten()
        .unwrap_or_default();

    println!(
        "client-side accepted request: {}",
        result.unwrap_or_else(|| "?".to_string())
    );
    println!("board after:  {after}");
    println!("charges after: {charges}");
    if after == before {
        println!(
            "board unchanged - banish likely failed (already pending request, \
             card was server-flagged guaranteed, or no banishes left) or hasn't landed yet"
        );
    }

    ExitCode::SUCCESS
}

/// NEW - no Python equivalent existed (only echo_autopilot.py's execute()
/// called FreezePerk internally, as part of the automated decision loop,
/// never as a standalone manual tool). Built directly following banish's
/// exact pattern: MANUAL, EXPLICIT ACTION, real
/// ProjectEbonhold.PerkService.FreezePerk(index) via /api/cmd/lua, no undo
/// (consumes a freeze charge - the card then carries over to the next
/// board instead of being lost, per this server's freeze mechanic).
fn freeze(args: &[String]) -> ExitCode {
    let mut index: Option<i32> = None;
    let mut api = DEFAULT_API.to_string();

    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--api" => {
                i += 1;
                if let Some(v) = args.get(i) {
                    api = v.clone();
                }
            }
            other => match other.parse::<i32>() {
                Ok(n) if (1..=3).contains(&n) => index = Some(n),
                _ => {
                    eprintln!("invalid card index: {other} (must be 1, 2, or 3)");
                    return ExitCode::FAILURE;
                }
            },
        }
        i += 1;
    }

    let Some(index) = index else {
        eprintln!("usage: companion freeze <1|2|3> [--api URL]");
        return ExitCode::FAILURE;
    };

    let bridge = WowBridge::new(&api);

    let before = match bridge.get("echo_board") {
        Ok(v) => v.unwrap_or_default(),
        Err(e) => {
            eprintln!("error: {e}");
            return ExitCode::FAILURE;
        }
    };
    println!("current board: {before}");

    let index0 = index - 1;
    let lua = format!(
        "local ok = ProjectEbonhold.PerkService.FreezePerk({index0}) DataBridge_Send(\"echo_freeze_result\", tostring(ok))"
    );
    if let Err(e) = bridge.run_lua(&lua) {
        eprintln!("error: {e}");
        return ExitCode::FAILURE;
    }
    println!("freeze request sent, waiting for server response...");
    std::thread::sleep(std::time::Duration::from_secs_f64(2.0));

    let result = bridge.get("echo_freeze_result").ok().flatten();
    let after = bridge.get("echo_board").ok().flatten().unwrap_or_default();
    let charges = bridge
        .get("echo_charges")
        .ok()
        .flatten()
        .unwrap_or_default();

    println!(
        "client-side accepted request: {}",
        result.unwrap_or_else(|| "?".to_string())
    );
    println!("board after:  {after}");
    println!("charges after: {charges}");
    if after == before {
        println!(
            "board unchanged - freeze likely failed (already pending request, \
             card was server-flagged guaranteed, or no freezes left) or hasn't landed yet. \
             On success the card's flags gain \"F\" (justFrozen) even though it's the same \
             card still sitting in the same slot - EchoTracker.lua's FlagsOf() checks this \
             specifically so echo_board does change on a real success, same as banish."
        );
    }

    ExitCode::SUCCESS
}

/// NEW - no Python equivalent existed. MANUAL, EXPLICIT ACTION: calls
/// ProjectEbonhold.PerkService.RequestReroll() via /api/cmd/lua - rerolls
/// the WHOLE board, no per-card index (unlike banish/freeze/select).
fn reroll(args: &[String]) -> ExitCode {
    let mut api = DEFAULT_API.to_string();
    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--api" => {
                i += 1;
                if let Some(v) = args.get(i) {
                    api = v.clone();
                }
            }
            other => {
                eprintln!("unknown argument: {other}");
                return ExitCode::FAILURE;
            }
        }
        i += 1;
    }

    let bridge = WowBridge::new(&api);

    let before = match bridge.get("echo_board") {
        Ok(v) => v.unwrap_or_default(),
        Err(e) => {
            eprintln!("error: {e}");
            return ExitCode::FAILURE;
        }
    };
    println!("current board: {before}");

    if let Err(e) = bridge.run_lua("ProjectEbonhold.PerkService.RequestReroll()") {
        eprintln!("error: {e}");
        return ExitCode::FAILURE;
    }
    println!("reroll request sent, waiting for server response...");
    std::thread::sleep(std::time::Duration::from_secs_f64(2.0));

    let after = bridge.get("echo_board").ok().flatten().unwrap_or_default();
    let charges = bridge
        .get("echo_charges")
        .ok()
        .flatten()
        .unwrap_or_default();
    println!("board after:  {after}");
    println!("charges after: {charges}");
    if after == before {
        println!(
            "board unchanged - reroll likely failed (no reroll budget left) or hasn't landed yet"
        );
    }

    ExitCode::SUCCESS
}

/// NEW - no Python equivalent existed. MANUAL, EXPLICIT ACTION: calls
/// ProjectEbonhold.PerkService.SelectPerk(spellId) via /api/cmd/lua - the
/// real API takes a spellId, not a board position, so this reads the
/// current echo_board first and resolves the position (1-3, matching
/// banish/freeze's convention) to the real spellId before calling it.
/// Taking a card RESOLVES THE WHOLE BOARD - the other two cards are
/// discarded, this is not undoable.
fn select(args: &[String]) -> ExitCode {
    let mut index: Option<i32> = None;
    let mut api = DEFAULT_API.to_string();

    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--api" => {
                i += 1;
                if let Some(v) = args.get(i) {
                    api = v.clone();
                }
            }
            other => match other.parse::<i32>() {
                Ok(n) if (1..=3).contains(&n) => index = Some(n),
                _ => {
                    eprintln!("invalid card index: {other} (must be 1, 2, or 3)");
                    return ExitCode::FAILURE;
                }
            },
        }
        i += 1;
    }

    let Some(index) = index else {
        eprintln!("usage: companion select <1|2|3> [--api URL]");
        return ExitCode::FAILURE;
    };

    let bridge = WowBridge::new(&api);

    let before = match bridge.get("echo_board") {
        Ok(Some(v)) if !v.is_empty() => v,
        Ok(_) => {
            eprintln!("no board currently offered (echo_board is empty)");
            return ExitCode::FAILURE;
        }
        Err(e) => {
            eprintln!("error: {e}");
            return ExitCode::FAILURE;
        }
    };
    println!("current board: {before}");

    let index0 = (index - 1) as usize;
    let Some(spell_id) = board::spell_id_at(&before, index0) else {
        eprintln!("could not resolve card {index} on the current board (fewer than {index} cards offered?)");
        return ExitCode::FAILURE;
    };
    println!("resolved position {index} -> spellId {spell_id}");

    let lua = format!("ProjectEbonhold.PerkService.SelectPerk({spell_id})");
    if let Err(e) = bridge.run_lua(&lua) {
        eprintln!("error: {e}");
        return ExitCode::FAILURE;
    }
    println!("select request sent, waiting for server response...");
    std::thread::sleep(std::time::Duration::from_secs_f64(2.0));

    let after = bridge.get("echo_board").ok().flatten().unwrap_or_default();
    println!("board after:  {after}");
    if after == before {
        println!("board unchanged - select likely failed or hasn't landed yet");
    } else {
        println!("board changed - looks like it landed (next board, or empty if none pending)");
    }

    ExitCode::SUCCESS
}

/// NEW - no Python equivalent (WhitelistLiquidator has never had a CLI).
/// Every subcommand here is a pure client of the same generic bridge every
/// other command in this file uses: the read subcommands just re-read the
/// `wl_*` values WhitelistLiquidator.lua already pushes via `DataBridge_Send`
/// on its own (see whitelist.rs's doc comment), and the action subcommands
/// queue a short call into the `WhitelistLiquidatorRemote` global the addon
/// exposes for exactly this - no wow_bridge changes needed either way.
fn wl_cmd(args: &[String]) -> ExitCode {
    let mut api = DEFAULT_API.to_string();
    let mut sub: Option<String> = None;
    let mut arg: Option<String> = None;

    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--api" => {
                i += 1;
                if let Some(v) = args.get(i) {
                    api = v.clone();
                }
            }
            other if sub.is_none() => sub = Some(other.to_string()),
            other if arg.is_none() => arg = Some(other.to_string()),
            other => {
                eprintln!("unknown argument: {other}");
                return ExitCode::FAILURE;
            }
        }
        i += 1;
    }

    let bridge = WowBridge::new(&api);

    match sub.as_deref() {
        Some("status") => {
            let raw = bridge.get("wl_status").ok().flatten().unwrap_or_default();
            if raw.is_empty() {
                println!(
                    "no wl_status yet - is WhitelistLiquidator loaded and DataBridge running?"
                );
                return ExitCode::SUCCESS;
            }
            let s = whitelist::parse_status(&raw);
            println!("whitelist entries: {}", s.whitelist);
            println!(
                "protected in bags: {}   auto-protected: {}",
                s.protected, s.auto
            );
            println!("sell qty: {}   destroy qty: {}", s.sell_qty, s.destroy_qty);
            ExitCode::SUCCESS
        }
        Some("equipped") => {
            let raw = bridge.get_chunked("wl_equipped");
            let items = whitelist::parse_equipped(&raw);
            if items.is_empty() {
                println!("no equipped-item data yet");
                return ExitCode::SUCCESS;
            }
            for item in items {
                println!(
                    "slot {:>2}  [{}]  {} ({})",
                    item.slot,
                    whitelist::tag_label(&item.tag),
                    item.name,
                    item.id
                );
            }
            ExitCode::SUCCESS
        }
        Some("whitelist") => {
            let raw = bridge.get_chunked("wl_whitelist");
            let entries = whitelist::parse_whitelist(&raw);
            if entries.is_empty() {
                println!("whitelist is empty");
                return ExitCode::SUCCESS;
            }
            for e in entries {
                println!("{}  [{}]", e.name, e.id);
            }
            ExitCode::SUCCESS
        }
        Some("alert") => {
            let raw = bridge
                .get("wl_unequip_alert")
                .ok()
                .flatten()
                .unwrap_or_default();
            match whitelist::parse_unequip_alert(&raw) {
                Some(a) => println!(
                    "UNEQUIPPED & UNPROTECTED: {} [{}] (slot {}) -- `companion wl protect` or `companion wl dismiss`",
                    a.name, a.id, a.slot
                ),
                None => println!("no pending unequip alert"),
            }
            ExitCode::SUCCESS
        }
        Some("protect") => wl_run_remote(&bridge, "WhitelistLiquidatorRemote.Protect()", "protect"),
        Some("dismiss") => wl_run_remote(&bridge, "WhitelistLiquidatorRemote.Dismiss()", "dismiss"),
        Some("clean") => wl_run_remote(&bridge, "WhitelistLiquidatorRemote.Clean()", "clean"),
        Some("add") => {
            let Some(id) = arg.as_deref().and_then(|s| s.parse::<i64>().ok()) else {
                eprintln!("usage: companion wl add <item_id> [--api URL]");
                return ExitCode::FAILURE;
            };
            wl_run_remote(
                &bridge,
                &format!("WhitelistLiquidatorRemote.Add({id})"),
                "add",
            )
        }
        Some("remove") => {
            let Some(id) = arg.as_deref().and_then(|s| s.parse::<i64>().ok()) else {
                eprintln!("usage: companion wl remove <item_id> [--api URL]");
                return ExitCode::FAILURE;
            };
            wl_run_remote(
                &bridge,
                &format!("WhitelistLiquidatorRemote.Remove({id})"),
                "remove",
            )
        }
        _ => {
            eprintln!("usage: companion wl <status|equipped|whitelist|alert|protect|dismiss|clean|add ID|remove ID> [--api URL]");
            ExitCode::FAILURE
        }
    }
}

fn wl_run_remote(bridge: &WowBridge, lua: &str, label: &str) -> ExitCode {
    match bridge.run_lua(lua) {
        Ok(()) => {
            println!("{label} sent");
            ExitCode::SUCCESS
        }
        Err(e) => {
            eprintln!("error: {e}");
            ExitCode::FAILURE
        }
    }
}
