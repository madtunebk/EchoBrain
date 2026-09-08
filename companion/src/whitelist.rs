//! Parsing for the WhitelistLiquidator addon's `wl_*` bridge exports
//! (WoW_AddOns/WhitelistLiquidator/WhitelistLiquidator.lua) - flat delimited
//! strings pushed via `DataBridge_Send`, read back through the same generic
//! `/api/variables/{key}` cache every other companion command already uses.
//! wow_bridge itself knows nothing about these keys - see bridge.rs's own
//! doc comment on why that separation is deliberate.

const FIELD_SEP: char = '\u{1f}'; // ASCII Unit Separator - matches the Lua side's EXPORT_SEP

#[derive(Debug, Default)]
pub struct StatusCounts {
    pub whitelist: i64,
    pub protected: i64,
    pub auto: i64,
    pub sell_qty: i64,
    pub destroy_qty: i64,
}

/// `"whitelist=N;protected=N;auto=N;sellQty=N;destroyQty=N"` - plain
/// key=value pairs, order not guaranteed, unknown keys ignored (forward
/// compatible with a field added on the Lua side later).
pub fn parse_status(raw: &str) -> StatusCounts {
    let mut s = StatusCounts::default();
    for pair in raw.split(';') {
        let Some((k, v)) = pair.split_once('=') else {
            continue;
        };
        let v: i64 = v.parse().unwrap_or(0);
        match k {
            "whitelist" => s.whitelist = v,
            "protected" => s.protected = v,
            "auto" => s.auto = v,
            "sellQty" => s.sell_qty = v,
            "destroyQty" => s.destroy_qty = v,
            _ => {}
        }
    }
    s
}

pub struct EquippedItem {
    pub slot: i64,
    pub id: String,
    /// "P" (whitelisted), "A" (auto-protected custom item), or "U"
    /// (unprotected - what FlagUnequippedItem would actually alarm on).
    pub tag: String,
}

/// Records joined by `;`, fields within a record joined by `FIELD_SEP`:
/// `slot<FS>id<FS>tag`. Empty input means no equipped-item data has been
/// pushed yet, not zero equipped items. No name field - item names are
/// server-generated procedural text that can't be pre-baked into a static
/// file, so they're resolved separately through item_cache.rs instead of
/// sent over the wire (see WhitelistLiquidator.lua's own comment on this).
pub fn parse_equipped(raw: &str) -> Vec<EquippedItem> {
    if raw.is_empty() {
        return Vec::new();
    }
    raw.split(';')
        .filter_map(|rec| {
            let mut parts = rec.split(FIELD_SEP);
            Some(EquippedItem {
                slot: parts.next()?.parse().ok()?,
                id: parts.next()?.to_string(),
                tag: parts.next()?.to_string(),
            })
        })
        .collect()
}

/// A bare item ID, `;`-joined - see parse_equipped's doc comment for why
/// there's no name here either.
pub fn parse_whitelist(raw: &str) -> Vec<String> {
    if raw.is_empty() {
        return Vec::new();
    }
    raw.split(';').map(str::to_string).collect()
}

pub struct UnequipAlert {
    pub id: String,
    pub name: String,
    pub slot: String,
}

/// A single `id<FS>name<FS>slot` record, or an empty string when nothing is
/// currently pending/shown in-game.
pub fn parse_unequip_alert(raw: &str) -> Option<UnequipAlert> {
    if raw.is_empty() {
        return None;
    }
    let mut parts = raw.split(FIELD_SEP);
    Some(UnequipAlert {
        id: parts.next()?.to_string(),
        name: parts.next().unwrap_or("").to_string(),
        slot: parts.next().unwrap_or("").to_string(),
    })
}

pub fn tag_label(tag: &str) -> &'static str {
    match tag {
        "P" => "protected",
        "A" => "auto",
        _ => "UNPROTECTED",
    }
}
