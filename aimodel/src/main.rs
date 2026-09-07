use anyhow::{bail, Context, Result};
use candle_core::{DType, Device, Tensor};
use candle_nn::{linear, AdamW, Linear, Module, Optimizer, ParamsAdamW, VarBuilder, VarMap};
use rand::{rngs::StdRng, seq::SliceRandom, Rng, SeedableRng};
use rusqlite::{Connection, OptionalExtension};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::{BTreeSet, HashMap};
use std::env;
use std::fs;
use std::path::{Path, PathBuf};

const FEATURE_COUNT: usize = 41;
const FEATURE_NAMES: [&str; FEATURE_COUNT] = [
    "level",
    "hardmode_tier",
    "prestige",
    "ash_bonus",
    "quality",
    "frozen",
    "carried",
    "guaranteed",
    "owned_fraction",
    "quality_score",
    "rarity_multiplier",
    "spec_fit",
    "ownership_score",
    "community_score",
    "downside_score",
    "stat_priority",
    "heuristic_total",
    "stats_available",
    "strength",
    "agility",
    "stamina",
    "intellect",
    "spirit",
    "attack_power",
    "ranged_attack_power",
    "spell_power",
    "healing_power",
    "crit_melee",
    "crit_ranged",
    "crit_spell",
    "haste_melee",
    "haste_ranged",
    "haste_spell",
    "hit_rating",
    "expertise",
    "armor",
    "health_max",
    "mana_max",
    "weapon_min",
    "weapon_max",
    "weapon_speed",
];

#[derive(Clone, Debug)]
struct Sample {
    session_id: i64,
    name: String,
    features: Vec<f32>,
    target: f32,
    fights: usize,
}

#[derive(Debug, Deserialize)]
struct ScoreEnvelope {
    spell_id: String,
    #[serde(default)]
    name: String,
    #[serde(default)]
    quality: String,
    #[serde(default)]
    flags: Flags,
    #[serde(default)]
    owned: String,
    score: ScoreParts,
}

#[derive(Debug, Default, Deserialize)]
struct Flags {
    #[serde(default)]
    frozen: bool,
    #[serde(default)]
    carried: bool,
    #[serde(default)]
    guaranteed: bool,
}

#[derive(Debug, Deserialize)]
struct ScoreParts {
    #[serde(default)]
    quality: f32,
    #[serde(default = "one")]
    rarity_multiplier: f32,
    #[serde(default)]
    spec_fit: f32,
    #[serde(default)]
    ownership: f32,
    #[serde(default)]
    community: f32,
    #[serde(default)]
    downside: f32,
    #[serde(default)]
    stat_priority: f32,
    #[serde(default)]
    total: f32,
}

fn one() -> f32 {
    1.0
}

#[derive(Debug, Serialize, Deserialize)]
struct ModelMeta {
    schema_version: u32,
    feature_names: Vec<String>,
    hidden_size: usize,
    train_samples: usize,
    validation_samples: usize,
    train_sessions: usize,
    validation_sessions: usize,
    target: String,
    target_mean: f32,
    target_std: f32,
    class_filter: String,
    spec_filter: String,
}

struct Net {
    l1: Linear,
    l2: Linear,
}

impl Net {
    fn new(vb: VarBuilder<'_>, input_size: usize, hidden_size: usize) -> candle_core::Result<Self> {
        Ok(Self {
            l1: linear(input_size, hidden_size, vb.pp("l1"))?,
            l2: linear(hidden_size, 1, vb.pp("l2"))?,
        })
    }

    fn forward(&self, xs: &Tensor) -> candle_core::Result<Tensor> {
        self.l2.forward(&self.l1.forward(xs)?.relu()?)
    }
}

fn display_name(name: &str) -> &str {
    const CLASS_PREFIXES: &[&str] = &[
        "Warrior",
        "Paladin",
        "Hunter",
        "Rogue",
        "Priest",
        "Death Knight",
        "Shaman",
        "Mage",
        "Warlock",
        "Monk",
        "Druid",
        "Demon Hunter",
    ];

    CLASS_PREFIXES
        .iter()
        .find_map(|class| name.strip_prefix(class)?.strip_prefix(" - "))
        .unwrap_or(name)
}

fn usage() {
    eprintln!("EchoBrain Candle model (CPU)");
    eprintln!("  aimodel inspect [--database PATH] [--class PALADIN] [--spec dps]");
    eprintln!(
        "  aimodel train [--database PATH] [--out DIR] [--epochs N] [--class PALADIN] [--spec dps]"
    );
    eprintln!("  aimodel train-ensemble [--database PATH] [--out DIR] [--epochs N] [--members 5] [--seed N]");
    eprintln!("  aimodel evaluate [--database PATH] [--model DIR] [--class PALADIN] [--spec dps]");
    eprintln!("  aimodel evaluate-ensemble [--database PATH] [--model DIR] [--members 5]");
    eprintln!("  aimodel predict --decision ID [--database PATH] [--model DIR]");
    eprintln!(
        "  aimodel predict-ensemble --decision ID [--database PATH] [--model DIR] [--members 5]"
    );
    eprintln!(
        "  aimodel compare-ensemble [--database PATH] [--model DIR] [--members 5] [--limit 1500]"
    );
    eprintln!("  aimodel generate-synthetic [--database PATH] [--runs 500] [--seed 42]");
}

fn mean_std(values: &[f32]) -> (f32, f32) {
    let mean = values.iter().sum::<f32>() / values.len() as f32;
    let variance = values.iter().map(|v| (v - mean).powi(2)).sum::<f32>() / values.len() as f32;
    (mean, variance.sqrt())
}

fn member_dir(base: &Path, index: usize) -> PathBuf {
    base.join(format!("member_{}", index + 1))
}

#[derive(Debug)]
struct Args {
    command: String,
    db: PathBuf,
    model: PathBuf,
    epochs: usize,
    class_filter: String,
    spec_filter: String,
    decision_id: Option<i64>,
    runs: usize,
    seed: u64,
    members: usize,
    limit: usize,
    database_explicit: bool,
}

fn args() -> Result<Args> {
    let mut it = env::args().skip(1);
    let Some(command) = it.next() else {
        usage();
        bail!("missing command")
    };
    let mut out = Args {
        command,
        db: PathBuf::from("data/session.db"),
        model: PathBuf::from("aimodel/model"),
        epochs: 250,
        class_filter: "PALADIN".into(),
        spec_filter: "dps".into(),
        decision_id: None,
        runs: 500,
        seed: 42,
        members: 5,
        limit: 1500,
        database_explicit: false,
    };
    while let Some(arg) = it.next() {
        let mut value = || {
            it.next()
                .with_context(|| format!("missing value after {arg}"))
        };
        match arg.as_str() {
            "--db" | "--database" => {
                out.db = value()?.into();
                out.database_explicit = true;
            }
            "--out" | "--model" => out.model = value()?.into(),
            "--epochs" => out.epochs = value()?.parse()?,
            "--class" => out.class_filter = value()?.to_uppercase(),
            "--spec" => out.spec_filter = value()?.to_lowercase(),
            "--decision" => out.decision_id = Some(value()?.parse()?),
            "--runs" => out.runs = value()?.parse()?,
            "--seed" => out.seed = value()?.parse()?,
            "--members" => out.members = value()?.parse()?,
            "--limit" => out.limit = value()?.parse()?,
            _ => bail!("unknown argument: {arg}"),
        }
    }
    if out.command == "generate-synthetic" && !out.database_explicit {
        out.db = PathBuf::from("data/session.synthetic.db");
    }
    Ok(out)
}

const SYNTHETIC_SCHEMA: &str = "
CREATE TABLE sessions (
 id INTEGER PRIMARY KEY AUTOINCREMENT, started_at REAL NOT NULL, ended_at REAL,
 class TEXT, spec TEXT, prestiges INTEGER, ash_bonus_pct REAL, hardmode_tier INTEGER
);
CREATE TABLE build_snapshots (
 id INTEGER PRIMARY KEY AUTOINCREMENT, session_id INTEGER NOT NULL, at REAL NOT NULL,
 level INTEGER NOT NULL, trigger TEXT NOT NULL, owned_signature TEXT NOT NULL
);
CREATE TABLE build_snapshot_echoes (
 snapshot_id INTEGER NOT NULL, spell_id TEXT NOT NULL, count INTEGER NOT NULL,
 PRIMARY KEY(snapshot_id, spell_id)
);
CREATE TABLE decision_events (
 id INTEGER PRIMARY KEY AUTOINCREMENT, session_id INTEGER NOT NULL, at REAL NOT NULL,
 level INTEGER NOT NULL, board TEXT NOT NULL, action TEXT NOT NULL,
 target_spell_id TEXT, reasons_json TEXT NOT NULL, scores_json TEXT NOT NULL,
 charges_json TEXT NOT NULL, build_before_id INTEGER, build_after_id INTEGER,
 status TEXT NOT NULL, confirmed_at REAL
);
CREATE TABLE fights (
 id INTEGER PRIMARY KEY AUTOINCREMENT, session_id INTEGER NOT NULL, at REAL NOT NULL,
 level INTEGER, damage INTEGER NOT NULL, dps REAL NOT NULL, duration_s REAL NOT NULL,
 build_snapshot_id INTEGER
);
CREATE INDEX idx_synthetic_decisions ON decision_events(session_id, at);
CREATE INDEX idx_synthetic_fights_build ON fights(build_snapshot_id);
";

fn synthetic_card(spell: i64, quality: i64, owned: i64) -> Value {
    let spec_fit = if spell % 5 != 0 { 20.0 } else { 0.0 };
    let community = ((spell * 17 % 100) as f64 / 10.0).min(9.9);
    let stat_priority = if spell % 7 < 3 { 8.0 } else { 0.0 };
    let ownership = (10.0 - owned as f64 * owned as f64 * 2.0).max(-100.0);
    let rarity_multiplier = [0.85, 0.90, 0.95, 1.0, 1.05][quality as usize];
    let quality_score = quality as f64 * 15.0;
    let total = (quality_score + spec_fit + community * 0.15 + stat_priority + ownership.max(0.0))
        * rarity_multiplier
        + ownership.min(0.0);
    let quality_name = ["Common", "Uncommon", "Rare", "Epic", "Legendary"][quality as usize];
    serde_json::json!({
        "slot": 0, "spell_id": spell.to_string(),
        "name": format!("Synthetic Echo {}", spell - 200000), "quality": quality_name,
        "families": [if spec_fit > 0.0 { "Melee" } else { "Utility" }],
        "flags": {"frozen": false, "carried": false, "guaranteed": false},
        "owned": format!("{owned}/5"), "downsides": [], "stats": [],
        "score": {"quality": quality_score, "rarity_multiplier": rarity_multiplier,
          "spec_fit": spec_fit, "ownership": ownership, "community": community * 0.15,
          "downside": 0.0, "stat_priority": stat_priority, "total": total}
    })
}

fn latent_value(card: &Value) -> f64 {
    let spell = card["spell_id"].as_str().unwrap().parse::<i64>().unwrap();
    let q = quality_number(card["quality"].as_str().unwrap()) as f64;
    // Hidden ground truth is related to, but deliberately not identical to,
    // the hand-written heuristic. Spell identity contributes repeatable
    // synergy/noise so the test is not a trivial total-score copy.
    q * 0.18
        + (spell * 31 % 97) as f64 / 180.0
        + card["score"]["spec_fit"].as_f64().unwrap_or(0.0) / 80.0
        - card["owned"]
            .as_str()
            .unwrap_or("0/5")
            .bytes()
            .next()
            .unwrap_or(b'0')
            .saturating_sub(b'0') as f64
            * 0.025
}

fn generate_synthetic(path: &Path, runs: usize, seed: u64) -> Result<()> {
    if runs == 0 {
        bail!("--runs must be greater than zero");
    }
    if path.ends_with("session.db") {
        bail!("refusing to use the real session.db for synthetic data");
    }
    if path.exists() {
        bail!(
            "{} already exists; choose a new path or move it aside first",
            path.display()
        );
    }
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let mut conn = Connection::open(path)?;
    conn.execute_batch(SYNTHETIC_SCHEMA)?;
    let tx = conn.transaction()?;
    let mut rng = StdRng::seed_from_u64(seed);
    let mut decision_count = 0usize;
    let mut fight_count = 0usize;
    for run in 0..runs {
        let start = 1_800_000_000.0 + run as f64 * 5000.0;
        let prestige = rng.gen_range(0..100_i64);
        let tier = rng.gen_range(1..=6_i64);
        let ash = 2000.0 + prestige as f64 * 12.0;
        tx.execute("INSERT INTO sessions(started_at,ended_at,class,spec,prestiges,ash_bonus_pct,hardmode_tier) VALUES(?1,?2,'PALADIN','dps',?3,?4,?5)",
            rusqlite::params![start,start+3600.0,prestige,ash,tier])?;
        let session_id = tx.last_insert_rowid();
        let mut owned: HashMap<i64, i64> = HashMap::new();
        let mut build_power = 0.0;
        let decisions = rng.gen_range(45..=75);
        for step in 0..decisions {
            let at = start + step as f64 * 45.0;
            let level = 1 + ((step * 79) / decisions) as i64;
            let before_sig = owned
                .iter()
                .map(|(s, c)| format!("{s}:{c}"))
                .collect::<Vec<_>>()
                .join(";");
            tx.execute("INSERT INTO build_snapshots(session_id,at,level,trigger,owned_signature) VALUES(?1,?2,?3,'synthetic_before',?4)",rusqlite::params![session_id,at,level,before_sig])?;
            let before_id = tx.last_insert_rowid();
            for (spell, count) in &owned {
                tx.execute("INSERT INTO build_snapshot_echoes(snapshot_id,spell_id,count) VALUES(?1,?2,?3)",rusqlite::params![before_id,spell.to_string(),count])?;
            }
            let mut cards = Vec::new();
            for _ in 0..3 {
                let spell = 200001 + rng.gen_range(0..180_i64);
                let roll = rng.gen_range(0..100);
                let quality = match roll {
                    0..=49 => 0,
                    50..=74 => 1,
                    75..=89 => 2,
                    90..=97 => 3,
                    _ => 4,
                };
                cards.push(synthetic_card(
                    spell,
                    quality,
                    *owned.get(&spell).unwrap_or(&0),
                ));
            }
            // Exploration matters: mostly take a strong option, sometimes a
            // random one, so outcomes exist outside the old policy's path.
            let target_idx = if rng.gen_bool(0.70) {
                (0..3)
                    .max_by(|a, b| latent_value(&cards[*a]).total_cmp(&latent_value(&cards[*b])))
                    .unwrap()
            } else {
                rng.gen_range(0..3)
            };
            let target = cards[target_idx]["spell_id"]
                .as_str()
                .unwrap()
                .parse::<i64>()
                .unwrap();
            *owned.entry(target).or_default() += 1;
            build_power += latent_value(&cards[target_idx]);
            let after_sig = owned
                .iter()
                .map(|(s, c)| format!("{s}:{c}"))
                .collect::<Vec<_>>()
                .join(";");
            tx.execute("INSERT INTO build_snapshots(session_id,at,level,trigger,owned_signature) VALUES(?1,?2,?3,'synthetic_after',?4)",rusqlite::params![session_id,at+0.1,level,after_sig])?;
            let after_id = tx.last_insert_rowid();
            for (spell, count) in &owned {
                tx.execute("INSERT INTO build_snapshot_echoes(snapshot_id,spell_id,count) VALUES(?1,?2,?3)",rusqlite::params![after_id,spell.to_string(),count])?;
            }
            let board = cards
                .iter()
                .map(|c| {
                    format!(
                        "{}:{}:",
                        c["spell_id"].as_str().unwrap().parse::<i64>().unwrap() - 200000,
                        quality_number(c["quality"].as_str().unwrap()) as i64
                    )
                })
                .collect::<Vec<_>>()
                .join(";");
            tx.execute("INSERT INTO decision_events(session_id,at,level,board,action,target_spell_id,reasons_json,scores_json,charges_json,build_before_id,build_after_id,status,confirmed_at) VALUES(?1,?2,?3,?4,'TAKE',?5,'[]',?6,'{}',?7,?8,'confirmed',?9)",
                rusqlite::params![session_id,at,level,board,target.to_string(),serde_json::to_string(&cards)?,before_id,after_id,at+0.2])?;
            decision_count += 1;
            let fight_n = rng.gen_range(1..=3);
            for f in 0..fight_n {
                let noise = rng.gen_range(0.88..1.12);
                let base = 6000.0 + level as f64 * 950.0 + tier as f64 * 4500.0 + ash * 7.0;
                let dps = (base * (1.0 + build_power / 55.0) * noise).max(100.0);
                let duration = rng.gen_range(8.0..35.0);
                tx.execute("INSERT INTO fights(session_id,at,level,damage,dps,duration_s,build_snapshot_id) VALUES(?1,?2,?3,?4,?5,?6,?7)",rusqlite::params![session_id,at+1.0+f as f64,level,dps.mul_add(duration,0.0) as i64,dps,duration,after_id])?;
                fight_count += 1;
            }
        }
    }
    tx.commit()?;
    println!(
        "generated {runs} synthetic runs, {decision_count} TAKE decisions, {fight_count} fights"
    );
    println!("database: {}", path.display());
    println!("synthetic data is for pipeline tests only; never merge it into session.db");
    Ok(())
}

fn quality_number(name: &str) -> f32 {
    match name.to_ascii_lowercase().as_str() {
        "common" => 0.0,
        "uncommon" => 1.0,
        "rare" => 2.0,
        "epic" => 3.0,
        "legendary" => 4.0,
        _ => 0.0,
    }
}

fn owned_fraction(raw: &str) -> f32 {
    let mut p = raw.split('/').filter_map(|v| v.parse::<f32>().ok());
    match (p.next(), p.next()) {
        (Some(a), Some(b)) if b > 0.0 => a / b,
        _ => 0.0,
    }
}

fn features(
    card: &ScoreEnvelope,
    level: i64,
    tier: i64,
    prestige: i64,
    ash: f64,
    hero_stats: Option<&[f64; 23]>,
) -> Vec<f32> {
    let mut out = vec![
        level as f32 / 80.0,
        tier as f32 / 10.0,
        (prestige as f32).ln_1p() / 5.0,
        (ash as f32 / 3000.0).clamp(0.0, 5.0),
        quality_number(&card.quality) / 4.0,
        card.flags.frozen as u8 as f32,
        card.flags.carried as u8 as f32,
        card.flags.guaranteed as u8 as f32,
        owned_fraction(&card.owned),
        card.score.quality / 60.0,
        card.score.rarity_multiplier,
        card.score.spec_fit / 20.0,
        card.score.ownership / 100.0,
        card.score.community / 20.0,
        card.score.downside / 50.0,
        card.score.stat_priority / 20.0,
        card.score.total / 100.0,
        hero_stats.is_some() as u8 as f32,
    ];
    let scales = [
        5000.0, 5000.0, 5000.0, 5000.0, 5000.0, 10000.0, 10000.0, 10000.0, 10000.0, 100.0, 100.0,
        100.0, 2000.0, 2000.0, 2000.0, 1000.0, 100.0, 50000.0, 100000.0, 100000.0, 5000.0, 5000.0,
        5.0,
    ];
    for (i, scale) in scales.iter().enumerate() {
        out.push(hero_stats.map(|s| (s[i] / scale) as f32).unwrap_or(0.0));
    }
    debug_assert_eq!(out.len(), FEATURE_COUNT);
    out
}

fn has_column(conn: &Connection, table: &str, column: &str) -> Result<bool> {
    let mut stmt = conn.prepare(&format!("PRAGMA table_info({table})"))?;
    let names = stmt
        .query_map([], |row| row.get::<_, String>(1))?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    Ok(names.iter().any(|name| name == column))
}

fn load_decision_stats(conn: &Connection, decision_id: i64) -> Result<Option<[f64; 23]>> {
    if !has_column(conn, "decision_events", "stats_before_id")?
        || !has_column(conn, "character_stat_snapshots", "strength")?
    {
        return Ok(None);
    }
    let mut stmt = conn.prepare(
        "SELECT st.strength,st.agility,st.stamina,st.intellect,st.spirit,
                st.attack_power,st.ranged_attack_power,st.spell_power,st.healing_power,
                st.crit_melee,st.crit_ranged,st.crit_spell,
                st.haste_melee,st.haste_ranged,st.haste_spell,st.hit_rating,st.expertise,
                st.armor,st.health_max,st.mana_max,st.weapon_min,st.weapon_max,st.weapon_speed
         FROM decision_events d
         JOIN character_stat_snapshots st ON st.id=d.stats_before_id
         WHERE d.id=?1",
    )?;
    Ok(stmt
        .query_row([decision_id], |r| {
            let mut stats = [0.0; 23];
            for (i, slot) in stats.iter_mut().enumerate() {
                *slot = r.get::<_, Option<f64>>(i)?.unwrap_or(0.0);
            }
            Ok(stats)
        })
        .optional()?)
}

fn load_samples(conn: &Connection, class_filter: &str, spec_filter: &str) -> Result<Vec<Sample>> {
    let stats_available = has_column(conn, "decision_events", "stats_before_id")?
        && has_column(conn, "character_stat_snapshots", "strength")?;
    let stats_select = if stats_available {
        ",st.strength,st.agility,st.stamina,st.intellect,st.spirit,st.attack_power,st.ranged_attack_power,st.spell_power,st.healing_power,st.crit_melee,st.crit_ranged,st.crit_spell,st.haste_melee,st.haste_ranged,st.haste_spell,st.hit_rating,st.expertise,st.armor,st.health_max,st.mana_max,st.weapon_min,st.weapon_max,st.weapon_speed"
    } else {
        ",NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL"
    };
    let stats_join = if stats_available {
        " LEFT JOIN character_stat_snapshots st ON st.id=d.stats_before_id "
    } else {
        ""
    };
    let sql = format!(
        "SELECT d.id,d.session_id,d.target_spell_id,d.scores_json,d.level,\
                COALESCE(s.hardmode_tier,0),COALESCE(s.prestiges,0),COALESCE(s.ash_bonus_pct,0),\
                AVG(f.dps),COUNT(f.id) {stats_select} \
         FROM decision_events d \
         JOIN sessions s ON s.id=d.session_id \
         JOIN fights f ON f.build_snapshot_id=d.build_after_id {stats_join} \
         WHERE d.status='confirmed' AND d.action='TAKE' \
           AND UPPER(COALESCE(s.class,''))=?1 AND LOWER(COALESCE(s.spec,''))=?2 \
         GROUP BY d.id HAVING COUNT(f.id)>0"
    );
    let mut stmt = conn.prepare(&sql)?;
    let rows = stmt.query_map([class_filter, spec_filter], |r| {
        let mut stats = [0.0; 23];
        let mut has_stats = false;
        for (i, slot) in stats.iter_mut().enumerate() {
            if let Some(value) = r.get::<_, Option<f64>>(10 + i)? {
                *slot = value;
                has_stats = true;
            }
        }
        Ok((
            r.get::<_, i64>(0)?,
            r.get::<_, i64>(1)?,
            r.get::<_, Option<String>>(2)?,
            r.get::<_, String>(3)?,
            r.get::<_, i64>(4)?,
            r.get::<_, i64>(5)?,
            r.get::<_, i64>(6)?,
            r.get::<_, f64>(7)?,
            r.get::<_, f64>(8)?,
            r.get::<_, i64>(9)?,
            has_stats.then_some(stats),
        ))
    })?;
    let mut samples = Vec::new();
    for row in rows {
        let (
            _id,
            session_id,
            target_id,
            scores,
            level,
            tier,
            prestige,
            ash,
            avg_dps,
            fights,
            stats,
        ) = row?;
        let Some(target_id) = target_id else { continue };
        let cards: Vec<ScoreEnvelope> = match serde_json::from_str(&scores) {
            Ok(v) => v,
            Err(_) => continue,
        };
        let Some(card) = cards.into_iter().find(|c| c.spell_id == target_id) else {
            continue;
        };
        samples.push(Sample {
            session_id,
            name: card.name.clone(),
            features: features(&card, level, tier, prestige, ash, stats.as_ref()),
            target: (avg_dps as f32).ln_1p(),
            fights: fights as usize,
        });
    }
    Ok(samples)
}

fn split(samples: &[Sample]) -> (Vec<Sample>, Vec<Sample>) {
    let mut sessions: Vec<i64> = samples
        .iter()
        .map(|s| s.session_id)
        .collect::<BTreeSet<_>>()
        .into_iter()
        .collect();
    sessions.shuffle(&mut StdRng::seed_from_u64(0xEC40_BA11));
    let validation_n = ((sessions.len() as f32 * 0.2).ceil() as usize)
        .max(1)
        .min(sessions.len());
    let validation: BTreeSet<i64> = sessions.iter().take(validation_n).copied().collect();
    let (valid, train): (Vec<_>, Vec<_>) = samples
        .iter()
        .cloned()
        .partition(|s| validation.contains(&s.session_id));
    (train, valid)
}

fn tensors(
    samples: &[Sample],
    device: &Device,
    target_norm: Option<(f32, f32)>,
    feature_count: usize,
) -> Result<(Tensor, Tensor)> {
    if feature_count == 0 || feature_count > FEATURE_COUNT {
        bail!(
            "model expects {feature_count} features, but this binary supports 1..={FEATURE_COUNT}"
        );
    }
    let x: Vec<f32> = samples
        .iter()
        .flat_map(|s| s.features.iter().take(feature_count).copied())
        .collect();
    let y: Vec<f32> = samples
        .iter()
        .map(|s| match target_norm {
            Some((mean, std)) => (s.target - mean) / std,
            None => s.target,
        })
        .collect();
    Ok((
        Tensor::from_vec(x, (samples.len(), feature_count), device)?,
        Tensor::from_vec(y, (samples.len(), 1), device)?,
    ))
}

fn metrics(
    net: &Net,
    samples: &[Sample],
    device: &Device,
    target_mean: f32,
    target_std: f32,
    feature_count: usize,
) -> Result<(f32, f32)> {
    if samples.is_empty() {
        return Ok((f32::NAN, f32::NAN));
    }
    let (x, y) = tensors(samples, device, None, feature_count)?;
    let pred = ((net.forward(&x)? * target_std as f64)? + target_mean as f64)?;
    let mae_log = (&pred - &y)?.abs()?.mean_all()?.to_scalar::<f32>()?;
    let p = pred.flatten_all()?.to_vec1::<f32>()?;
    let actual = y.flatten_all()?.to_vec1::<f32>()?;
    let mae_pct = p
        .iter()
        .zip(actual)
        .map(|(a, b)| (a.exp() - b.exp()).abs() / b.exp().max(1.0))
        .sum::<f32>()
        / p.len() as f32;
    Ok((mae_log, mae_pct * 100.0))
}

fn load_net(dir: &Path, device: &Device) -> Result<(VarMap, Net, ModelMeta)> {
    let meta: ModelMeta = serde_json::from_slice(&fs::read(dir.join("metadata.json"))?)?;
    let feature_count = meta.feature_names.len();
    if feature_count == 0 || feature_count > FEATURE_COUNT {
        bail!(
            "model metadata declares {feature_count} features, but this binary supports 1..={FEATURE_COUNT}"
        );
    }
    let mut vars = VarMap::new();
    let vb = VarBuilder::from_varmap(&vars, DType::F32, device);
    let net = Net::new(vb, feature_count, meta.hidden_size)?;
    vars.load(dir.join("model.safetensors"))?;
    Ok((vars, net, meta))
}

fn train_model(
    train_source: &[Sample],
    valid: &[Sample],
    out: &Path,
    epochs: usize,
    class_filter: &str,
    spec_filter: &str,
    bootstrap_seed: Option<u64>,
) -> Result<(f32, f32)> {
    let train = if let Some(seed) = bootstrap_seed {
        let mut rng = StdRng::seed_from_u64(seed);
        (0..train_source.len())
            .map(|_| train_source[rng.gen_range(0..train_source.len())].clone())
            .collect::<Vec<_>>()
    } else {
        train_source.to_vec()
    };
    let device = Device::Cpu;
    let vars = VarMap::new();
    let net = Net::new(
        VarBuilder::from_varmap(&vars, DType::F32, &device),
        FEATURE_COUNT,
        32,
    )?;
    let mut opt = AdamW::new(
        vars.all_vars(),
        ParamsAdamW {
            lr: 1e-3,
            ..Default::default()
        },
    )?;
    let target_mean = train.iter().map(|s| s.target).sum::<f32>() / train.len() as f32;
    let target_std = (train
        .iter()
        .map(|s| (s.target - target_mean).powi(2))
        .sum::<f32>()
        / train.len() as f32)
        .sqrt()
        .max(1e-6);
    let (x, y) = tensors(
        &train,
        &device,
        Some((target_mean, target_std)),
        FEATURE_COUNT,
    )?;
    for epoch in 1..=epochs {
        let loss = candle_nn::loss::mse(&net.forward(&x)?, &y)?;
        opt.backward_step(&loss)?;
        if epoch == 1 || epoch % 25 == 0 || epoch == epochs {
            println!("epoch {epoch:4} train_mse={:.6}", loss.to_scalar::<f32>()?);
        }
    }
    fs::create_dir_all(out)?;
    vars.save(out.join("model.safetensors"))?;
    let meta = ModelMeta {
        schema_version: 2,
        feature_names: FEATURE_NAMES.iter().map(|s| (*s).into()).collect(),
        hidden_size: 32,
        train_samples: train.len(),
        validation_samples: valid.len(),
        train_sessions: train_source
            .iter()
            .map(|s| s.session_id)
            .collect::<BTreeSet<_>>()
            .len(),
        validation_sessions: valid
            .iter()
            .map(|s| s.session_id)
            .collect::<BTreeSet<_>>()
            .len(),
        target: "ln(1 + mean DPS for fights linked to build_after)".into(),
        target_mean,
        target_std,
        class_filter: class_filter.to_string(),
        spec_filter: spec_filter.to_string(),
    };
    fs::write(out.join("metadata.json"), serde_json::to_vec_pretty(&meta)?)?;
    metrics(&net, valid, &device, target_mean, target_std, FEATURE_COUNT)
}

fn main() -> Result<()> {
    let a = args()?;
    if a.command == "generate-synthetic" {
        return generate_synthetic(&a.db, a.runs, a.seed);
    }
    let conn = Connection::open(&a.db).with_context(|| format!("open {}", a.db.display()))?;
    let samples = load_samples(&conn, &a.class_filter, &a.spec_filter)?;
    match a.command.as_str() {
        "inspect" => {
            let sessions = samples
                .iter()
                .map(|s| s.session_id)
                .collect::<BTreeSet<_>>()
                .len();
            let fights: usize = samples.iter().map(|s| s.fights).sum();
            let mut spells: HashMap<&str, usize> = HashMap::new();
            for s in &samples {
                *spells.entry(&s.name).or_default() += 1;
            }
            let mut top: Vec<_> = spells.into_iter().collect();
            top.sort_by_key(|x| std::cmp::Reverse(x.1));
            println!("usable TAKE samples: {}", samples.len());
            println!("sessions: {sessions}; linked fight observations: {fights}; distinct picked echoes: {}", top.len());
            println!(
                "most represented: {}",
                top.into_iter()
                    .take(10)
                    .map(|(n, c)| format!("{n} ({c})"))
                    .collect::<Vec<_>>()
                    .join(", ")
            );
        }
        "train" => {
            if samples.len() < 50 {
                bail!(
                    "only {} usable samples; refusing to train below 50",
                    samples.len()
                );
            }
            let (train, valid) = split(&samples);
            if train.is_empty() || valid.is_empty() {
                bail!("need at least two sessions for a leakage-safe split");
            }
            let device = Device::Cpu;
            let vars = VarMap::new();
            let net = Net::new(
                VarBuilder::from_varmap(&vars, DType::F32, &device),
                FEATURE_COUNT,
                32,
            )?;
            let mut opt = AdamW::new(
                vars.all_vars(),
                ParamsAdamW {
                    lr: 1e-3,
                    ..Default::default()
                },
            )?;
            let target_mean = train.iter().map(|s| s.target).sum::<f32>() / train.len() as f32;
            let target_std = (train
                .iter()
                .map(|s| (s.target - target_mean).powi(2))
                .sum::<f32>()
                / train.len() as f32)
                .sqrt()
                .max(1e-6);
            let (x, y) = tensors(
                &train,
                &device,
                Some((target_mean, target_std)),
                FEATURE_COUNT,
            )?;
            for epoch in 1..=a.epochs {
                let loss = candle_nn::loss::mse(&net.forward(&x)?, &y)?;
                opt.backward_step(&loss)?;
                if epoch == 1 || epoch % 25 == 0 || epoch == a.epochs {
                    println!("epoch {epoch:4} train_mse={:.6}", loss.to_scalar::<f32>()?);
                }
            }
            fs::create_dir_all(&a.model)?;
            vars.save(a.model.join("model.safetensors"))?;
            let meta = ModelMeta {
                schema_version: 1,
                feature_names: FEATURE_NAMES.iter().map(|s| (*s).into()).collect(),
                hidden_size: 32,
                train_samples: train.len(),
                validation_samples: valid.len(),
                train_sessions: train
                    .iter()
                    .map(|s| s.session_id)
                    .collect::<BTreeSet<_>>()
                    .len(),
                validation_sessions: valid
                    .iter()
                    .map(|s| s.session_id)
                    .collect::<BTreeSet<_>>()
                    .len(),
                target: "ln(1 + mean DPS for fights linked to build_after)".into(),
                target_mean,
                target_std,
                class_filter: a.class_filter,
                spec_filter: a.spec_filter,
            };
            fs::write(
                a.model.join("metadata.json"),
                serde_json::to_vec_pretty(&meta)?,
            )?;
            let (mae, pct) = metrics(
                &net,
                &valid,
                &device,
                target_mean,
                target_std,
                FEATURE_COUNT,
            )?;
            println!("saved {}", a.model.display());
            println!("validation: log-MAE={mae:.4}, approximate DPS-MAE={pct:.1}% (experimental; not autopilot-ready)");
        }
        "train-ensemble" => {
            if samples.len() < 50 {
                bail!(
                    "only {} usable samples; refusing to train below 50",
                    samples.len()
                );
            }
            if a.members < 2 {
                bail!("--members must be at least 2");
            }
            let (train, valid) = split(&samples);
            if train.is_empty() || valid.is_empty() {
                bail!("need at least two sessions for a leakage-safe split");
            }
            println!(
                "training {} bootstrap members: train={} validation={} (shared session split)",
                a.members,
                train.len(),
                valid.len()
            );
            for member in 0..a.members {
                let seed = a.seed.wrapping_add(member as u64 * 10_007);
                let out = member_dir(&a.model, member);
                println!(
                    "\n=== member {}/{} seed={} ===",
                    member + 1,
                    a.members,
                    seed
                );
                let (mae, pct) = train_model(
                    &train,
                    &valid,
                    &out,
                    a.epochs,
                    &a.class_filter,
                    &a.spec_filter,
                    Some(seed),
                )?;
                println!(
                    "member {} validation: log-MAE={mae:.4}, approximate DPS-MAE={pct:.1}%",
                    member + 1
                );
            }
            println!(
                "saved {} ensemble members under {}",
                a.members,
                a.model.display()
            );
        }
        "evaluate-ensemble" => {
            if a.members < 2 {
                bail!("--members must be at least 2");
            }
            let (_, valid) = split(&samples);
            if valid.is_empty() {
                bail!("validation split is empty");
            }
            let device = Device::Cpu;
            let mut ensemble_logs = vec![0.0f32; valid.len()];
            for member in 0..a.members {
                let dir = member_dir(&a.model, member);
                let (_vars, net, meta) = load_net(&dir, &device)?;
                let feature_count = meta.feature_names.len();
                let (mae, pct) = metrics(
                    &net,
                    &valid,
                    &device,
                    meta.target_mean,
                    meta.target_std,
                    feature_count,
                )?;
                let (x, _) = tensors(&valid, &device, None, feature_count)?;
                let normalized = net.forward(&x)?.flatten_all()?.to_vec1::<f32>()?;
                for (sum, prediction) in ensemble_logs.iter_mut().zip(normalized) {
                    *sum += prediction * meta.target_std + meta.target_mean;
                }
                println!(
                    "member {}: log-MAE={mae:.4} approximate DPS-MAE={pct:.1}%",
                    member + 1
                );
            }
            for prediction in &mut ensemble_logs {
                *prediction /= a.members as f32;
            }
            let actual: Vec<f32> = valid.iter().map(|s| s.target).collect();
            let log_mae = ensemble_logs
                .iter()
                .zip(&actual)
                .map(|(p, y)| (p - y).abs())
                .sum::<f32>()
                / actual.len() as f32;
            let dps_mae = ensemble_logs
                .iter()
                .zip(&actual)
                .map(|(p, y)| (p.exp() - y.exp()).abs() / y.exp().max(1.0))
                .sum::<f32>()
                / actual.len() as f32
                * 100.0;
            println!(
                "ensemble mean: samples={} log-MAE={log_mae:.4} approximate DPS-MAE={dps_mae:.1}%",
                valid.len()
            );
        }
        "evaluate" => {
            let device = Device::Cpu;
            let (_vars, net, meta) = load_net(&a.model, &device)?;
            let (_, valid) = split(&samples);
            let (mae, pct) = metrics(
                &net,
                &valid,
                &device,
                meta.target_mean,
                meta.target_std,
                meta.feature_names.len(),
            )?;
            println!(
                "validation samples={} log-MAE={mae:.4} approximate DPS-MAE={pct:.1}%",
                valid.len()
            );
        }
        "compare-ensemble" => {
            if a.members < 2 || a.limit == 0 {
                bail!("--members must be at least 2 and --limit must be greater than zero");
            }
            let device = Device::Cpu;
            let mut models = Vec::with_capacity(a.members);
            for member in 0..a.members {
                let dir = member_dir(&a.model, member);
                models.push(load_net(&dir, &device).with_context(|| {
                    format!("load ensemble member {} from {}", member + 1, dir.display())
                })?);
            }
            let mut stmt = conn.prepare(
                "SELECT d.id,d.level,COALESCE(s.hardmode_tier,0),COALESCE(s.prestiges,0),\
                        COALESCE(s.ash_bonus_pct,0),d.scores_json \
                 FROM decision_events d JOIN sessions s ON s.id=d.session_id \
                 WHERE UPPER(COALESCE(s.class,''))=?1 AND LOWER(COALESCE(s.spec,''))=?2 \
                 ORDER BY d.id DESC LIMIT ?3",
            )?;
            let rows = stmt.query_map(
                rusqlite::params![a.class_filter, a.spec_filter, a.limit as i64],
                |r| {
                    Ok((
                        r.get::<_, i64>(0)?,
                        r.get::<_, i64>(1)?,
                        r.get::<_, i64>(2)?,
                        r.get::<_, i64>(3)?,
                        r.get::<_, f64>(4)?,
                        r.get::<_, String>(5)?,
                    ))
                },
            )?;
            let rows = rows.collect::<rusqlite::Result<Vec<_>>>()?;
            let mut compared = 0usize;
            let mut unanimous = 0usize;
            let mut strong = 0usize;
            let mut heuristic_agreement = 0usize;
            let mut uncertain = Vec::new();
            for (id, level, tier, prestige, ash, json) in rows {
                let values: Vec<Value> = match serde_json::from_str(&json) {
                    Ok(values) => values,
                    Err(_) => continue,
                };
                let cards: Vec<ScoreEnvelope> = values
                    .into_iter()
                    .filter_map(|value| serde_json::from_value(value).ok())
                    .collect();
                if cards.len() < 2 {
                    continue;
                }
                let hero_stats = load_decision_stats(&conn, id)?;
                let mut predictions = vec![Vec::<f32>::new(); cards.len()];
                let mut votes = vec![0usize; cards.len()];
                for (_vars, net, meta) in &models {
                    let feature_count = meta.feature_names.len();
                    let mut member_values = Vec::with_capacity(cards.len());
                    for card in &cards {
                        let mut f = features(card, level, tier, prestige, ash, hero_stats.as_ref());
                        f.truncate(feature_count);
                        let x = Tensor::from_vec(f, (1, feature_count), &device)?;
                        let normalized = net.forward(&x)?.flatten_all()?.to_vec1::<f32>()?[0];
                        member_values
                            .push((normalized * meta.target_std + meta.target_mean).exp() - 1.0);
                    }
                    let winner = member_values
                        .iter()
                        .enumerate()
                        .max_by(|a, b| a.1.total_cmp(b.1))
                        .map(|(index, _)| index)
                        .unwrap();
                    votes[winner] += 1;
                    for (index, value) in member_values.into_iter().enumerate() {
                        predictions[index].push(value);
                    }
                }
                let means: Vec<f32> = predictions.iter().map(|v| mean_std(v).0).collect();
                let winner = means
                    .iter()
                    .enumerate()
                    .max_by(|a, b| a.1.total_cmp(b.1))
                    .map(|(index, _)| index)
                    .unwrap();
                let heuristic = cards
                    .iter()
                    .enumerate()
                    .max_by(|a, b| a.1.score.total.total_cmp(&b.1.score.total))
                    .map(|(index, _)| index)
                    .unwrap();
                let winner_votes = votes[winner];
                compared += 1;
                unanimous += usize::from(winner_votes == a.members);
                strong += usize::from(winner_votes * 5 >= a.members * 4);
                heuristic_agreement += usize::from(winner == heuristic);
                if winner_votes < a.members {
                    let (_, std) = mean_std(&predictions[winner]);
                    uncertain.push((
                        winner_votes,
                        std / means[winner].abs().max(1.0),
                        id,
                        display_name(&cards[winner].name).to_string(),
                    ));
                }
            }
            uncertain.sort_by(|a, b| a.0.cmp(&b.0).then_with(|| b.1.total_cmp(&a.1)));
            println!("boards compared: {compared} (requested limit {})", a.limit);
            if compared > 0 {
                println!(
                    "unanimous: {unanimous} ({:.1}%)",
                    unanimous as f32 * 100.0 / compared as f32
                );
                println!(
                    "strong agreement (>=80%): {strong} ({:.1}%)",
                    strong as f32 * 100.0 / compared as f32
                );
                println!(
                    "ensemble agrees with heuristic: {heuristic_agreement} ({:.1}%)",
                    heuristic_agreement as f32 * 100.0 / compared as f32
                );
                println!("most uncertain decisions:");
                for (votes, relative_std, id, name) in uncertain.into_iter().take(10) {
                    println!(
                        "  #{id}: {votes}/{} votes, relative_std={relative_std:.2} winner={name}",
                        a.members
                    );
                }
            }
        }
        "predict-ensemble" => {
            let id = a
                .decision_id
                .context("predict-ensemble requires --decision ID")?;
            let row: Option<(i64, i64, i64, f64, String)> = conn
                .query_row(
                    "SELECT d.level,COALESCE(s.hardmode_tier,0),COALESCE(s.prestiges,0),COALESCE(s.ash_bonus_pct,0),d.scores_json FROM decision_events d JOIN sessions s ON s.id=d.session_id WHERE d.id=?1",
                    [id],
                    |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?)),
                )
                .optional()?;
            let (level, tier, prestige, ash, json) = row.context("decision not found")?;
            let hero_stats = load_decision_stats(&conn, id)?;
            let values: Vec<Value> = serde_json::from_str(&json)?;
            let cards: Vec<ScoreEnvelope> = values
                .into_iter()
                .filter_map(|value| serde_json::from_value(value).ok())
                .collect();
            if cards.is_empty() {
                bail!("decision has no scoreable cards");
            }
            let device = Device::Cpu;
            let mut predictions = vec![Vec::<f32>::new(); cards.len()];
            let mut votes = vec![0usize; cards.len()];
            for member in 0..a.members {
                let dir = member_dir(&a.model, member);
                let (_vars, net, meta) = load_net(&dir, &device).with_context(|| {
                    format!("load ensemble member {} from {}", member + 1, dir.display())
                })?;
                let feature_count = meta.feature_names.len();
                let mut member_values = Vec::with_capacity(cards.len());
                for card in &cards {
                    let mut f = features(card, level, tier, prestige, ash, hero_stats.as_ref());
                    f.truncate(feature_count);
                    let x = Tensor::from_vec(f, (1, feature_count), &device)?;
                    let normalized = net.forward(&x)?.flatten_all()?.to_vec1::<f32>()?[0];
                    let log = normalized * meta.target_std + meta.target_mean;
                    member_values.push(log.exp() - 1.0);
                }
                let winner = member_values
                    .iter()
                    .enumerate()
                    .max_by(|a, b| a.1.total_cmp(b.1))
                    .map(|(index, _)| index)
                    .unwrap();
                votes[winner] += 1;
                for (index, value) in member_values.into_iter().enumerate() {
                    predictions[index].push(value);
                }
            }
            let mut ranked: Vec<(usize, f32, f32)> = predictions
                .iter()
                .enumerate()
                .map(|(index, values)| {
                    let (mean, std) = mean_std(values);
                    (index, mean, std)
                })
                .collect();
            ranked.sort_by(|a, b| b.1.total_cmp(&a.1));
            for (rank, (index, mean, std)) in ranked.iter().enumerate() {
                let card = &cards[*index];
                let member_values = predictions[*index]
                    .iter()
                    .map(|v| format!("{v:.0}"))
                    .collect::<Vec<_>>()
                    .join(",");
                println!(
                    "{}. {:<32} mean={:>10.0} std={:>10.0} votes={}/{} heuristic={:>6.1} [{}] models=[{}]",
                    rank + 1,
                    display_name(&card.name),
                    mean,
                    std,
                    votes[*index],
                    a.members,
                    card.score.total,
                    card.spell_id,
                    member_values
                );
            }
        }
        "predict" => {
            let id = a.decision_id.context("predict requires --decision ID")?;
            let row: Option<(i64,i64,i64,f64,String)> = conn.query_row(
                "SELECT d.level,COALESCE(s.hardmode_tier,0),COALESCE(s.prestiges,0),COALESCE(s.ash_bonus_pct,0),d.scores_json FROM decision_events d JOIN sessions s ON s.id=d.session_id WHERE d.id=?1",
                [id], |r| Ok((r.get(0)?,r.get(1)?,r.get(2)?,r.get(3)?,r.get(4)?))).optional()?;
            let (level, tier, prestige, ash, json) = row.context("decision not found")?;
            let hero_stats = load_decision_stats(&conn, id)?;
            let cards: Vec<Value> = serde_json::from_str(&json)?;
            let device = Device::Cpu;
            let (_vars, net, meta) = load_net(&a.model, &device)?;
            let feature_count = meta.feature_names.len();
            let mut ranked = Vec::new();
            for value in cards {
                if let Ok(card) = serde_json::from_value::<ScoreEnvelope>(value) {
                    let mut f = features(&card, level, tier, prestige, ash, hero_stats.as_ref());
                    f.truncate(feature_count);
                    let x = Tensor::from_vec(f, (1, feature_count), &device)?;
                    let normalized = net.forward(&x)?.flatten_all()?.to_vec1::<f32>()?[0];
                    let log = normalized * meta.target_std + meta.target_mean;
                    ranked.push((log.exp() - 1.0, card));
                }
            }
            ranked.sort_by(|a, b| b.0.total_cmp(&a.0));
            for (i, (dps, c)) in ranked.iter().enumerate() {
                println!(
                    "{}. {:<32} predicted_dps={:>10.0} heuristic={:>6.1} [{}]",
                    i + 1,
                    display_name(&c.name),
                    dps,
                    c.score.total,
                    c.spell_id
                );
            }
        }
        _ => {
            usage();
            bail!("unknown command: {}", a.command);
        }
    }
    Ok(())
}
