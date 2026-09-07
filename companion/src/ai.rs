//! Live inference for the trained Paladin/dps value-ensemble (see
//! `aimodel/README.md` and `aimodel/src/main.rs`'s `train-ensemble`/
//! `features()`/`Net`/`load_net`) - mirrors that binary's forward-inference
//! path exactly. `aimodel` and `companion` are deliberately separate,
//! independently-built crates with no shared workspace (same reasoning as
//! `bridge.rs`'s `LUA_CMD_BUDGET`/token-path duplication with wow_bridge),
//! so this is a small, deliberate duplication of aimodel's inference-only
//! slice - not its training/data-loading code, which companion never needs.
//! If aimodel's feature engineering ever changes, this needs updating to
//! match, or ensemble members trained against a different feature set will
//! silently make nonsense predictions.
//!
//! Model files live under `data/ai_ensemble/member_1..N/{metadata.json,
//! model.safetensors}` - same `data/` convention every other on-disk asset
//! in this crate uses (catalog.rs's `perk_catalog.json` et al.).

use candle_core::{DType, Device, Tensor};
use candle_nn::{linear, Linear, Module, VarBuilder, VarMap};
use serde::Deserialize;
use std::path::{Path, PathBuf};

const FEATURE_COUNT: usize = 41;

// Same per-stat normalization divisors as aimodel's own `features()` -
// strength,agility,stamina,intellect,spirit,attack_power,
// ranged_attack_power,spell_power,healing_power,crit_melee,crit_ranged,
// crit_spell,haste_melee,haste_ranged,haste_spell,hit_rating,expertise,
// armor,health_max,mana_max,weapon_min,weapon_max,weapon_speed - matches
// session_db.rs's HeroStats.values field order exactly (both ultimately
// trace back to the same `hero_stats` bridge key/character_stat_snapshots
// columns).
const HERO_STAT_SCALES: [f64; 23] = [
    5000.0, 5000.0, 5000.0, 5000.0, 5000.0, 10000.0, 10000.0, 10000.0, 10000.0, 100.0, 100.0,
    100.0, 2000.0, 2000.0, 2000.0, 1000.0, 100.0, 50000.0, 100000.0, 100000.0, 5000.0, 5000.0, 5.0,
];

#[derive(Debug, Deserialize)]
struct ModelMeta {
    feature_names: Vec<String>,
    hidden_size: usize,
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

struct Member {
    // Kept alive alongside `net` - Net's Linear layers borrow their weight
    // tensors from this VarMap's storage.
    _vars: VarMap,
    net: Net,
    feature_count: usize,
}

/// Everything score_card() needs to hand this module in order to build the
/// exact same 41-feature vector aimodel trained on - the card's own
/// heuristic breakdown (already computed by score_card() itself) plus the
/// session/character context that doesn't vary per-card on a given board.
pub struct AiInput<'a> {
    pub quality_name: &'a str,
    pub frozen: bool,
    pub carried: bool,
    pub guaranteed: bool,
    pub owned_fraction: f32,
    pub quality_score: f64,
    pub rarity_multiplier: f64,
    pub spec_fit: f64,
    pub ownership: f64,
    pub community: f64,
    pub downside: f64,
    pub stat_priority: f64,
    pub heuristic_total: f64,
    pub level: i64,
    pub tier: i64,
    pub prestige: i64,
    pub ash_bonus_pct: f64,
    pub hero_stats: Option<&'a [f64; 23]>,
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

fn build_features(input: &AiInput) -> [f32; FEATURE_COUNT] {
    let mut out = [0f32; FEATURE_COUNT];
    let head = [
        input.level as f32 / 80.0,
        input.tier as f32 / 10.0,
        (input.prestige as f32).ln_1p() / 5.0,
        (input.ash_bonus_pct as f32 / 3000.0).clamp(0.0, 5.0),
        quality_number(input.quality_name) / 4.0,
        input.frozen as u8 as f32,
        input.carried as u8 as f32,
        input.guaranteed as u8 as f32,
        input.owned_fraction,
        (input.quality_score / 60.0) as f32,
        input.rarity_multiplier as f32,
        (input.spec_fit / 20.0) as f32,
        (input.ownership / 100.0) as f32,
        (input.community / 20.0) as f32,
        (input.downside / 50.0) as f32,
        (input.stat_priority / 20.0) as f32,
        (input.heuristic_total / 100.0) as f32,
        input.hero_stats.is_some() as u8 as f32,
    ];
    out[..head.len()].copy_from_slice(&head);
    for (i, scale) in HERO_STAT_SCALES.iter().enumerate() {
        out[head.len() + i] = input.hero_stats.map(|s| (s[i] / scale) as f32).unwrap_or(0.0);
    }
    out
}

fn member_dir(base: &Path, index: usize) -> PathBuf {
    base.join(format!("member_{}", index + 1))
}

pub struct Ensemble {
    members: Vec<Member>,
    class_filter: String,
    spec_filter: String,
}

impl Ensemble {
    /// Loads every `member_N/` subdirectory under `dir` (e.g.
    /// `data/ai_ensemble`), stopping at the first missing index. Returns
    /// `Ok(None)` if `dir` doesn't exist or has no members at all - the AI
    /// score is opt-in, never a hard requirement to run companion at all
    /// (same graceful-degrade philosophy as catalog::load_json_optional).
    pub fn load(dir: &Path) -> anyhow::Result<Option<Self>> {
        if !dir.is_dir() {
            return Ok(None);
        }
        let device = Device::Cpu;
        let mut members = Vec::new();
        let mut class_filter = String::new();
        let mut spec_filter = String::new();
        for i in 0.. {
            let member_path = member_dir(dir, i);
            if !member_path.is_dir() {
                break;
            }
            let meta: ModelMeta =
                serde_json::from_slice(&std::fs::read(member_path.join("metadata.json"))?)?;
            let feature_count = meta.feature_names.len();
            if feature_count == 0 || feature_count > FEATURE_COUNT {
                anyhow::bail!(
                    "{} declares {feature_count} features, companion's ai.rs supports 1..={FEATURE_COUNT}",
                    member_path.display()
                );
            }
            let mut vars = VarMap::new();
            let vb = VarBuilder::from_varmap(&vars, DType::F32, &device);
            let net = Net::new(vb, feature_count, meta.hidden_size)?;
            vars.load(member_path.join("model.safetensors"))?;
            class_filter = meta.class_filter;
            spec_filter = meta.spec_filter;
            members.push(Member {
                _vars: vars,
                net,
                feature_count,
            });
        }
        if members.is_empty() {
            return Ok(None);
        }
        Ok(Some(Ensemble {
            members,
            class_filter,
            spec_filter,
        }))
    }

    pub fn member_count(&self) -> usize {
        self.members.len()
    }

    pub fn class_filter(&self) -> &str {
        &self.class_filter
    }

    pub fn spec_filter(&self) -> &str {
        &self.spec_filter
    }

    /// True only for the exact (class, spec) this ensemble was trained on -
    /// the current one is PALADIN/dps-only. Using it for any other class or
    /// spec would be extrapolating on a distribution it never saw a single
    /// sample of.
    pub fn applies_to(&self, klass: &str, spec: &str) -> bool {
        self.class_filter.eq_ignore_ascii_case(klass) && self.spec_filter.eq_ignore_ascii_case(spec)
    }

    /// Mean of the ensemble members' RAW network output - i.e. the
    /// normalized target-space z-score (`(ln(1+dps) - target_mean) /
    /// target_std)`), deliberately NOT denormalized back into raw predicted
    /// DPS the way aimodel's own `predict-ensemble` does for human-readable
    /// output. A handful of members disagreeing on a multi-million-DPS
    /// prediction is a terrible thing to add directly onto a ~100-point
    /// heuristic total, but a z-score (typically -2..+2 for anything
    /// resembling the training distribution) is exactly the right shape to
    /// blend in as one more scoring component alongside quality/spec_fit/
    /// community/etc. Returns None only on a genuine tensor-shape/inference
    /// error, not as a normal "no data" outcome.
    pub fn predict_z(&self, input: &AiInput) -> Option<f32> {
        let device = Device::Cpu;
        let full = build_features(input);
        let mut total = 0.0f32;
        let mut count = 0u32;
        for member in &self.members {
            let x = Tensor::from_vec(
                full[..member.feature_count].to_vec(),
                (1, member.feature_count),
                &device,
            )
            .ok()?;
            let z = member
                .net
                .forward(&x)
                .ok()?
                .flatten_all()
                .ok()?
                .to_vec1::<f32>()
                .ok()?[0];
            total += z;
            count += 1;
        }
        (count > 0).then(|| total / count as f32)
    }
}
