//! Typed loaders for the three data/*.json reference files scoring.rs reads.
//! Shapes below were sampled directly from the real files (not guessed):
//!   perk_catalog.json:      {"<spellId>": CatalogEntry}
//!   community_db.json:      {"<CLASS>": ClassCommunity}
//!   echo_stat_effects.json: {"<spellId>": StatEffect}

use serde::Deserialize;
use std::collections::HashMap;
use std::fs;
use std::path::Path;

#[derive(Debug, Clone, Deserialize)]
pub struct CatalogEntry {
    #[serde(rename = "maxStack", default = "default_max_stack")]
    pub max_stack: i64,
    #[serde(rename = "groupId")]
    pub group_id: Option<i64>,
    #[serde(default)]
    pub comment: Option<String>,
    #[serde(default)]
    pub families: Vec<String>,
}

fn default_max_stack() -> i64 {
    1
}

pub type Catalog = HashMap<String, CatalogEntry>;

/// Catalog comments sometimes qualify class-specific spell variants as
/// "Paladin - Echo Name - Rare". The spell id already identifies the variant,
/// so keep that qualifier out of user-facing names.
pub fn display_name(comment: &str) -> &str {
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
        .find_map(|class| comment.strip_prefix(class)?.strip_prefix(" - "))
        .unwrap_or(comment)
}

pub fn remove_class_qualifiers(text: &str) -> String {
    const CLASS_PREFIXES: &[&str] = &[
        "Warrior - ",
        "Paladin - ",
        "Hunter - ",
        "Rogue - ",
        "Priest - ",
        "Death Knight - ",
        "Shaman - ",
        "Mage - ",
        "Warlock - ",
        "Monk - ",
        "Druid - ",
        "Demon Hunter - ",
    ];

    CLASS_PREFIXES
        .iter()
        .fold(text.to_string(), |value, prefix| value.replace(prefix, ""))
}

#[derive(Debug, Clone, Deserialize)]
pub struct CommunityEntry {
    #[allow(dead_code)]
    pub builds: i64,
    #[allow(dead_code)]
    pub frequency: f64,
    #[serde(rename = "avgQuality")]
    #[allow(dead_code)]
    pub avg_quality: f64,
    #[serde(rename = "avgStacks")]
    #[allow(dead_code)]
    pub avg_stacks: f64,
    pub score: f64,
}

#[derive(Debug, Clone, Deserialize)]
pub struct ClassCommunity {
    #[allow(dead_code)]
    #[serde(default)]
    pub samples: i64,
    #[serde(default)]
    pub by_group: HashMap<String, CommunityEntry>,
    #[serde(default)]
    pub by_spell: HashMap<String, CommunityEntry>,
}

pub type CommunityDb = HashMap<String, ClassCommunity>;

#[derive(Debug, Clone, Deserialize)]
pub struct StatEffect {
    #[serde(default)]
    pub downsides: Vec<String>,
    #[serde(default)]
    pub stats: Vec<String>,
}

pub type StatEffects = HashMap<String, StatEffect>;

/// Mirrors score_echo_board.py's load_json - hard error (with the same
/// "run the exporter first" hint) if the file is missing.
pub fn load_json<T: for<'de> Deserialize<'de>>(path: &Path) -> anyhow::Result<T> {
    if !path.exists() {
        anyhow::bail!(
            "missing {} - run tools/export/export_perk_catalog.py / export_community_db.py first",
            path.display()
        );
    }
    let text = fs::read_to_string(path)?;
    Ok(serde_json::from_str(&text)?)
}

/// Mirrors load_json_optional - {} instead of erroring when the file is
/// simply not there yet (echo_stat_effects.json is a nice-to-have, not a
/// hard requirement - scoring still works without it, minus the downside
/// penalty / stat-priority bonus).
pub fn load_json_optional<T: Default + for<'de> Deserialize<'de>>(
    path: &Path,
) -> anyhow::Result<T> {
    if !path.exists() {
        return Ok(T::default());
    }
    let text = fs::read_to_string(path)?;
    Ok(serde_json::from_str(&text)?)
}

#[cfg(test)]
mod tests {
    use super::{display_name, remove_class_qualifiers};

    #[test]
    fn removes_catalog_class_qualifier() {
        assert_eq!(
            display_name("Paladin - Stonefist Barrage - Common"),
            "Stonefist Barrage - Common"
        );
        assert_eq!(display_name("Accelerated Spirit"), "Accelerated Spirit");
        assert_eq!(
            remove_class_qualifiers("TAKE: Paladin - Stonefist Barrage - Common"),
            "TAKE: Stonefist Barrage - Common"
        );
    }
}
