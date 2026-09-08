-- Whitelist Liquidator - WoW 3.3.5a
-- Drag a bag item to toggle whitelist.
-- Open a merchant and Left Click the floating button (or /wl clean)
-- to sell everything not whitelisted and destroy unsellable items.

local ADDON = "WhitelistLiquidator"
local frame = CreateFrame("Frame")
local button
local whitelistWindow
local hooked = {}
local pendingEpicDeletes = {}
local epicConfirmFrame
local equippedSnapshot = {}
local pendingUnequipWarnings = {}
local unequipWarningFrame
local ShowNextUnequipWarning -- forward-declared, assigned once the frame exists below

local msg, ItemIDFromLink

msg = function(text)
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99WL|r: " .. text)
end

-- Best-effort export to companion/FlaskGUI via DataBridge (see
-- WoW_AddOns/DataBridge) - a no-op if DataBridge isn't loaded, so this
-- addon stays fully functional standalone in-game either way.
local function ReportToBridge(key, value)
    if type(DataBridge_Send) == "function" then
        DataBridge_Send(key, value)
    end
end

-- DataBridge_Send silently drops (with a chat warning) any single value
-- over its own ~220-byte cap - confirmed live: a whitelist of 39 items or a
-- full 19-slot equip snapshot both blow well past that as one flat string,
-- so wl_whitelist/wl_equipped were being dropped on every single push.
-- DataBridge_SendLarge (see WoW_AddOns/DataBridge/DataBridge.lua) is the
-- shared fix - same chunking EchoTracker.lua's own echo_owned/echo_icons
-- already use, pulled up into DataBridge itself instead of living as a
-- private copy in every addon that needs it. Guarded the same way
-- ReportToBridge is: a no-op (nothing sent) on an old DataBridge without
-- this function yet, or with DataBridge missing entirely.
local function SendChunked(baseKey, parts, sep)
    if type(DataBridge_SendLarge) == "function" then
        DataBridge_SendLarge(baseKey, parts, sep)
    end
end

ItemIDFromLink = function(link)
    if not link then return nil end
    return tonumber(string.match(link, "item:(%d+)"))
end

local function EnsureDB()
    if type(WhitelistLiquidatorDB) ~= "table" then
        WhitelistLiquidatorDB = {}
    end
    if type(WhitelistLiquidatorDB.items) ~= "table" then
        WhitelistLiquidatorDB.items = {}
    end
    if type(WhitelistLiquidatorDB.button) ~= "table" then
        WhitelistLiquidatorDB.button = {
            point = "CENTER",
            relativePoint = "CENTER",
            x = 0,
            y = 0,
        }
    end
    -- Quality floor for the confirm-before-touching queue -- 4 (Epic) by
    -- default, settable down to 3 (Rare) via /wl confirmquality.
    if type(WhitelistLiquidatorDB.confirmQuality) ~= "number" then
        WhitelistLiquidatorDB.confirmQuality = 4
    end
    -- Named whitelist profiles (e.g. a different protected-item set per
    -- character/spec) -- same idea as CallBoardHelper's whitelist profiles.
    if type(WhitelistLiquidatorDB.profiles) ~= "table" then
        WhitelistLiquidatorDB.profiles = {}
    end
end

local function IsWhitelisted(id)
    return id and WhitelistLiquidatorDB.items[id] ~= nil
end

-- Custom ProjectEbonhold items always get a far higher item ID than any
-- real WotLK 3.3.5a item -- confirmed from the live whitelist: real items
-- top out at 43102 (Frozen Orb) in this sample, while known custom items
-- sit at 95010 (Soul Ashes Crate) and 600614/600634 (Seismic Excavation
-- Charge, Herbalism Scissor). 70000 sits comfortably in that gap, well
-- above anything real Blizzard ever shipped for this expansion, so this
-- can't misfire on a genuine item -- unlike checking for a "Use:" effect,
-- which also caught ordinary items like Crystallized Life.
local CUSTOM_ITEM_ID_THRESHOLD = 70000
local function IsCustomItem(id)
    return id and id >= CUSTOM_ITEM_ID_THRESHOLD
end

-- Blizzard's own equip-slot range constants (Constants.lua loads before any
-- addon, so these are always already defined; the "or" fallback only
-- matters if some future client ever removes them).
local EQUIP_FIRST_SLOT = INVSLOT_FIRST_EQUIPPED or 1
local EQUIP_LAST_SLOT = INVSLOT_LAST_EQUIPPED or 19

-- Losing a weapon isn't a "will Clean() eat this" problem - it's a "you're
-- now doing near-zero damage and might not notice for a while" problem,
-- true regardless of whitelist/quality protection. Worth the loud
-- treatment on its own axis from IsSafeFromClean.
local WEAPON_SLOTS = {
    [INVSLOT_MAINHAND or 16] = true,
    [INVSLOT_OFFHAND or 17] = true,
    [INVSLOT_RANGED or 18] = true,
}

-- Field separator for the record-based wl_equipped/wl_whitelist bridge
-- exports below - ASCII Unit Separator, same convention EchoTracker.lua
-- uses for its own exports (never appears in normal item names/links, so
-- it's safe to split on without escaping).
local EXPORT_SEP = string.char(31)

local QUALITY_NAMES = { [0] = "Poor", [1] = "Common", [2] = "Uncommon", [3] = "Rare", [4] = "Epic", [5] = "Legendary", [6] = "Artifact" }
local QUALITY_BY_NAME = { poor = 0, common = 1, uncommon = 2, rare = 3, epic = 4, legendary = 5, artifact = 6 }

local function ConfirmQuality()
    return WhitelistLiquidatorDB and WhitelistLiquidatorDB.confirmQuality or 4
end

-- Single definition of "is this actually vulnerable to Clean()'s silent
-- auto-sell/destroy" - matches Clean()'s own three-part rule (custom item /
-- explicitly whitelisted / at-or-above the confirm-quality floor) exactly,
-- so nothing built on top of this (the equipped-list tag, the unequip
-- alarm) can drift out of sync with what Clean() would actually do. A
-- quality-floor item was NOT actually a false negative to warn about here -
-- Clean() already always waits for a manual confirm dialog on it too, same
-- as an explicit whitelist entry - confirmed live: unequipping a
-- non-whitelisted Epic still fired the big alarm even though it was never
-- one auto-sell away from being lost.
local function IsSafeFromClean(id, quality)
    return IsWhitelisted(id) or IsCustomItem(id) or (quality or 0) >= ConfirmQuality()
end

local RefreshWhitelistWindow -- forward-declared, assigned once the whitelist window exists below -- several functions above where it's actually built (ToggleWhitelist, and now LoadWhitelistProfileNow) call it

local function ToggleWhitelist(bag, slot)
    local link = GetContainerItemLink(bag, slot)
    if not link then return end

    local id = ItemIDFromLink(link)
    if not id then return end

    if IsWhitelisted(id) then
        WhitelistLiquidatorDB.items[id] = nil
        msg("|cffff5555REMOVED|r " .. link)
        RefreshWhitelistWindow()
    else
        local name, itemLink, _, _, _, _, _, _, _, texture = GetItemInfo(link)
        WhitelistLiquidatorDB.items[id] = {
            name = name or ("Item " .. id),
            link = itemLink or link,
            texture = texture,
        }
        msg("|cff55ff55ADDED|r " .. (itemLink or link))
        RefreshWhitelistWindow()
    end
end

local function HookBagButton(b)
    -- Deprecated intentionally: bag click modifiers are not used.
end

local function HookAllBagButtons()
    -- No bag button hooks. Use drag-and-drop whitelist window only.
end

local function WhitelistCount()
    local n = 0
    for _ in pairs(WhitelistLiquidatorDB.items) do n = n + 1 end
    return n
end

-- One bare item ID per whitelisted item - no name. Names are procedurally
-- generated per-server text ("Sanctified Lightsworn Helmet of Ironhide IV")
-- that can't be pre-baked into a static file the way echo/perk names can,
-- so companion resolves them itself via a local cache (data/cache/
-- items.sqlite3) populated lazily through WhitelistLiquidatorRemote.
-- ResolveItem below - sending id-only here means a 50+ item whitelist that
-- used to need several chunks now normally fits in one. Called from
-- RefreshWhitelistWindow, the one place every whitelist-mutating function
-- already calls after changing WhitelistLiquidatorDB.items - single
-- injection point instead of duplicating a push call at every add/remove/
-- import/profile-load/drag-and-drop site.
local function PushWhitelistState()
    local parts = {}
    for id in pairs(WhitelistLiquidatorDB.items) do
        table.insert(parts, tostring(id))
    end
    SendChunked("wl_whitelist", parts)
end

-- Split out of Status() so the same counts can also feed the periodic
-- wl_status bridge export below, instead of duplicating this whole bag scan
-- a second time or trying to scrape it back out of colored chat text.
local function ComputeStatusCounts()
    local protected, doomed, sellable, destroyable, autoProtected = 0, 0, 0, 0, 0

    for bag = 0, 4 do
        for slot = 1, GetContainerNumSlots(bag) do
            local link = GetContainerItemLink(bag, slot)
            if link then
                local id = ItemIDFromLink(link)
                if IsWhitelisted(id) then
                    protected = protected + 1
                elseif IsCustomItem(id) then
                    -- Custom server item -- completely ignored by design,
                    -- never counted toward sell/destroy at all.
                    autoProtected = autoProtected + 1
                else
                    local _, count = GetContainerItemInfo(bag, slot)
                    local _, _, quality, _, _, _, _, _, _, _, price = GetItemInfo(link)
                    if (quality or 0) >= ConfirmQuality() then
                        -- Matches Clean()'s own rule: anything at/above the
                        -- confirm-quality floor waits for manual confirmation,
                        -- so it isn't "doomed" either.
                        autoProtected = autoProtected + 1
                    else
                        doomed = doomed + 1
                        if price and price > 0 then
                            sellable = sellable + (count or 1)
                        else
                            destroyable = destroyable + (count or 1)
                        end
                    end
                end
            end
        end
    end

    return {
        protected = protected,
        doomed = doomed,
        sellable = sellable,
        destroyable = destroyable,
        autoProtected = autoProtected,
    }
end

local function Status()
    local c = ComputeStatusCounts()
    msg("Whitelist: |cffffffff" .. WhitelistCount() ..
        "|r  Protected slots: |cff55ff55" .. c.protected ..
        "|r  Auto-protected: |cff55ff55" .. c.autoProtected ..
        "|r  Sell qty: |cffffcc00" .. c.sellable ..
        "|r  Destroy qty: |cffff5555" .. c.destroyable .. "|r")
end

-- Periodic (not event-driven) since a full bag scan on every single
-- BAG_UPDATE would be wasteful when several fire back to back (e.g. a big
-- Clean() sell batch) - statusDirty just marks "something happened since
-- the last push", and the OnUpdate ticker below drains it at most once
-- every STATUS_PUSH_INTERVAL.
local statusDirty = true
local statusPushElapsed = 0
local STATUS_PUSH_INTERVAL = 2.0

local function PushStatusState()
    local c = ComputeStatusCounts()
    ReportToBridge("wl_status", table.concat({
        "whitelist=" .. WhitelistCount(),
        "protected=" .. c.protected,
        "auto=" .. c.autoProtected,
        "sellQty=" .. c.sellable,
        "destroyQty=" .. c.destroyable,
    }, ";"))
end

local function ShowNextEpicWarning()
    if not epicConfirmFrame or epicConfirmFrame:IsShown() then return end

    local data = table.remove(pendingEpicDeletes, 1)
    if not data then return end

    local link = GetContainerItemLink(data.bag, data.slot)
    if not link or ItemIDFromLink(link) ~= data.itemID then
        ShowNextEpicWarning()
        return
    end

    epicConfirmFrame.data = data
    epicConfirmFrame.itemText:SetText(link)
    epicConfirmFrame.icon:SetTexture(data.texture or "Interface\\Icons\\INV_Misc_QuestionMark")

    if data.isEpic then
        -- Named after the item's ACTUAL quality, not just the configured
        -- floor -- if the floor is Rare but this particular item is
        -- Legendary, the dialog should say Legendary, not Rare.
        local qName = string.upper(QUALITY_NAMES[data.quality] or "HIGH-QUALITY")
        epicConfirmFrame.title:SetText("|cffff5555" .. qName .. "+ WARNING|r")
        if data.sellable then
            epicConfirmFrame.warning:SetText(qName .. " item is NOT whitelisted.\nSell it?")
            epicConfirmFrame.action:SetText("SELL")
        else
            epicConfirmFrame.warning:SetText(qName .. " item is NOT whitelisted.\nIt cannot be sold. DELETE it?")
            epicConfirmFrame.action:SetText("DELETE")
        end
    else
        -- Fail-safe for every plain destroy candidate too, not just Epic+ --
        -- these have no vendor value and aren't whitelisted, so Clean()
        -- would otherwise delete them with zero confirmation.
        epicConfirmFrame.title:SetText("|cffffaa00DELETE CONFIRMATION|r")
        epicConfirmFrame.warning:SetText("This item has no vendor value and isn't whitelisted.\nDelete it?")
        epicConfirmFrame.action:SetText("DELETE")
    end

    epicConfirmFrame:Show()
end

local function CreateEpicConfirmFrame()
    epicConfirmFrame = CreateFrame("Frame", "WhitelistLiquidatorEpicWarning", UIParent)
    epicConfirmFrame:SetWidth(360)
    epicConfirmFrame:SetHeight(150)
    epicConfirmFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 120)
    epicConfirmFrame:SetFrameStrata("FULLSCREEN_DIALOG")
    epicConfirmFrame:SetToplevel(true)
    epicConfirmFrame:EnableMouse(true)
    epicConfirmFrame:Hide()

    epicConfirmFrame:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 }
    })

    local title = epicConfirmFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -16)
    title:SetText("|cffff5555EPIC+ WARNING|r")
    epicConfirmFrame.title = title

    local icon = epicConfirmFrame:CreateTexture(nil, "ARTWORK")
    icon:SetWidth(36)
    icon:SetHeight(36)
    icon:SetPoint("TOPLEFT", 24, -42)
    epicConfirmFrame.icon = icon

    local itemText = epicConfirmFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    itemText:SetPoint("LEFT", icon, "RIGHT", 8, 0)
    itemText:SetWidth(270)
    itemText:SetJustifyH("LEFT")
    epicConfirmFrame.itemText = itemText

    -- Hover the icon/name to see the item's real tooltip (stats, Use effect,
    -- sell price) -- important for a Sell/Keep decision, not just the name.
    local hoverZone = CreateFrame("Button", nil, epicConfirmFrame)
    hoverZone:SetPoint("TOPLEFT", icon, "TOPLEFT", 0, 0)
    hoverZone:SetPoint("BOTTOMRIGHT", itemText, "BOTTOMRIGHT", 0, 0)
    hoverZone:SetScript("OnEnter", function(self)
        local link = epicConfirmFrame.data and epicConfirmFrame.data.link
        if not link then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetHyperlink(link)
        GameTooltip:Show()
    end)
    hoverZone:SetScript("OnLeave", function() GameTooltip:Hide() end)

    local warning = epicConfirmFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    warning:SetPoint("TOP", 0, -84)
    warning:SetWidth(320)
    warning:SetJustifyH("CENTER")
    epicConfirmFrame.warning = warning

    local action = CreateFrame("Button", nil, epicConfirmFrame, "UIPanelButtonTemplate")
    action:SetWidth(110)
    action:SetHeight(24)
    action:SetPoint("BOTTOMLEFT", 58, 18)
    epicConfirmFrame.action = action

    local keep = CreateFrame("Button", nil, epicConfirmFrame, "UIPanelButtonTemplate")
    keep:SetWidth(110)
    keep:SetHeight(24)
    keep:SetPoint("BOTTOMRIGHT", -58, 18)
    keep:SetText("KEEP")

    action:SetScript("OnClick", function()
        local data = epicConfirmFrame.data
        epicConfirmFrame:Hide()
        epicConfirmFrame.data = nil

        if data then
            local link = GetContainerItemLink(data.bag, data.slot)
            if link and ItemIDFromLink(link) == data.itemID then
                local tag = data.isEpic and (string.upper(QUALITY_NAMES[data.quality] or "HIGH-QUALITY") .. "+") or "item"
                if data.sellable then
                    if MerchantFrame and MerchantFrame:IsShown() then
                        UseContainerItem(data.bag, data.slot)
                        msg("|cffffcc00SOLD " .. tag .. "|r " .. link)
                    else
                        msg("|cffff5555Merchant closed.|r " .. (data.isEpic and "Epic" or "Item") .. " kept.")
                    end
                else
                    ClearCursor()
                    PickupContainerItem(data.bag, data.slot)
                    if CursorHasItem() then
                        DeleteCursorItem()
                        msg("|cffff5555DELETED " .. tag .. "|r " .. link)
                    else
                        msg("|cffffaa00Could not pick up item.|r Kept.")
                    end
                end
            else
                msg("|cffffaa00Item moved or changed.|r Skipped.")
            end
        end

        ShowNextEpicWarning()
    end)

    keep:SetScript("OnClick", function()
        local data = epicConfirmFrame.data
        epicConfirmFrame:Hide()
        epicConfirmFrame.data = nil
        if data and data.link then
            msg("|cff55ff55KEPT|r " .. data.link)
        end
        ShowNextEpicWarning()
    end)
end

-- ------------------------------------------------------------
-- Equipped-gear watchdog. Whitelist entries protect an item ID from Clean(),
-- but gear you're actually wearing was never added to that list -- nobody
-- whitelists their own helmet, it's equipped, it can't get sold. That
-- assumption breaks the moment something unequips it into your bags (gear
-- swap macro, a "Use" trinket effect, a GM/server bug, simple misclick) --
-- it's now sitting there as plain unprotected loot waiting for the next
-- Clean(). This watches every equip slot and fires a hard-to-miss alarm the
-- instant that happens, instead of relying on the player noticing it in the
-- Epic+ confirm queue (or worse, a non-Epic piece that wouldn't even queue).
-- ------------------------------------------------------------

-- Mirrors the popup's current contents out to companion/FlaskGUI: the
-- item currently shown (id/name/slot), or an empty string once the queue
-- drains and nothing is left to show. Single call site for this push
-- (inside ShowNextUnequipWarning below) keeps it from drifting out of sync
-- with what's actually on screen.
local function PushUnequipAlertState(item)
    if item then
        ReportToBridge("wl_unequip_alert", table.concat(
            { item.id or "", (item.name or ""):gsub("[;\n\r]", " "), item.slot or "" },
            EXPORT_SEP
        ))
    else
        ReportToBridge("wl_unequip_alert", "")
    end
end

ShowNextUnequipWarning = function()
    if not unequipWarningFrame or unequipWarningFrame:IsShown() then return end

    local item = table.remove(pendingUnequipWarnings, 1)
    if not item then
        PushUnequipAlertState(nil)
        return
    end

    unequipWarningFrame.data = item
    unequipWarningFrame.itemText:SetText(item.link or item.name or ("item:" .. tostring(item.id)))
    unequipWarningFrame.icon:SetTexture(item.texture or "Interface\\Icons\\INV_Misc_QuestionMark")
    unequipWarningFrame:Show()
    PushUnequipAlertState(item)
end

local function CreateUnequipWarningFrame()
    unequipWarningFrame = CreateFrame("Frame", "WhitelistLiquidatorUnequipWarning", UIParent)
    unequipWarningFrame:SetWidth(360)
    unequipWarningFrame:SetHeight(150)
    -- Offset below center (not the same spot as epicConfirmFrame at +120) so
    -- an unequip-during-vendoring can show both dialogs at once without one
    -- covering the other.
    unequipWarningFrame:SetPoint("CENTER", UIParent, "CENTER", 0, -80)
    unequipWarningFrame:SetFrameStrata("FULLSCREEN_DIALOG")
    unequipWarningFrame:SetToplevel(true)
    unequipWarningFrame:EnableMouse(true)
    unequipWarningFrame:Hide()

    unequipWarningFrame:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 }
    })
    unequipWarningFrame:SetBackdropBorderColor(1, 0.15, 0.15, 1)

    local title = unequipWarningFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -16)
    title:SetText("|cffff0000GEAR UNEQUIPPED|r")

    local icon = unequipWarningFrame:CreateTexture(nil, "ARTWORK")
    icon:SetWidth(36)
    icon:SetHeight(36)
    icon:SetPoint("TOPLEFT", 24, -42)
    unequipWarningFrame.icon = icon

    local itemText = unequipWarningFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    itemText:SetPoint("LEFT", icon, "RIGHT", 8, 0)
    itemText:SetWidth(270)
    itemText:SetJustifyH("LEFT")
    unequipWarningFrame.itemText = itemText

    -- Hover to see the item's real tooltip, same as the Epic+ confirm dialog.
    local hoverZone = CreateFrame("Button", nil, unequipWarningFrame)
    hoverZone:SetPoint("TOPLEFT", icon, "TOPLEFT", 0, 0)
    hoverZone:SetPoint("BOTTOMRIGHT", itemText, "BOTTOMRIGHT", 0, 0)
    hoverZone:SetScript("OnEnter", function(self)
        local link = unequipWarningFrame.data and unequipWarningFrame.data.link
        if not link then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetHyperlink(link)
        GameTooltip:Show()
    end)
    hoverZone:SetScript("OnLeave", function() GameTooltip:Hide() end)

    local warning = unequipWarningFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    warning:SetPoint("TOP", 0, -84)
    warning:SetWidth(320)
    warning:SetJustifyH("CENTER")
    warning:SetText("This was just unequipped and isn't whitelisted.\nClean() will sell/destroy it. Protect it now?")

    local protectBtn = CreateFrame("Button", nil, unequipWarningFrame, "UIPanelButtonTemplate")
    protectBtn:SetWidth(110)
    protectBtn:SetHeight(24)
    protectBtn:SetPoint("BOTTOMLEFT", 58, 18)
    protectBtn:SetText("PROTECT")

    local dismissBtn = CreateFrame("Button", nil, unequipWarningFrame, "UIPanelButtonTemplate")
    dismissBtn:SetWidth(110)
    dismissBtn:SetHeight(24)
    dismissBtn:SetPoint("BOTTOMRIGHT", -58, 18)
    dismissBtn:SetText("DISMISS")

    protectBtn:SetScript("OnClick", function()
        local data = unequipWarningFrame.data
        unequipWarningFrame:Hide()
        unequipWarningFrame.data = nil
        if data and data.id then
            WhitelistLiquidatorDB.items[data.id] = {
                name = data.name,
                link = data.link,
                texture = data.texture,
            }
            msg("|cff55ff55PROTECTED|r " .. (data.link or data.name or ("item:" .. data.id)))
            RefreshWhitelistWindow()
        end
        ShowNextUnequipWarning()
    end)

    dismissBtn:SetScript("OnClick", function()
        unequipWarningFrame:Hide()
        unequipWarningFrame.data = nil
        ShowNextUnequipWarning()
    end)
end

-- Only alarms for gear that's actually vulnerable -- if it's already
-- whitelisted or a custom server item, Clean() was never going to touch it,
-- so raising a "disturbing" alert for it would just be noise the player
-- learns to ignore (defeating the point the next time it's a real item).
local function FlagUnequippedItem(item)
    if not item or not item.id then return end

    local label = item.link or item.name or ("item:" .. item.id)

    if IsSafeFromClean(item.id, item.quality) then
        -- Full banner+sound treatment for every unequip now, protected or
        -- not - "will Clean() eat this" and "do you want to know this came
        -- off" turned out to be two different questions. Only the PROTECT
        -- popup stays reserved for the genuinely-unprotected branch below:
        -- there's nothing to protect this one from, so a popup with a
        -- PROTECT button here would just be a dead click.
        local weaponTag = WEAPON_SLOTS[item.slot] and "WEAPON " or ""
        if RaidNotice_AddMessage and RaidWarningFrame then
            RaidNotice_AddMessage(RaidWarningFrame, weaponTag .. "UNEQUIPPED: " .. label, ChatTypeInfo and ChatTypeInfo["RAID_WARNING"])
        end
        PlaySound("RaidWarning")
        msg("|cffffaa00!!! " .. weaponTag .. "UNEQUIPPED !!!|r " .. label .. " |cff888888(protected -- Clean() won't touch it)|r")
        return
    end

    -- Big center-screen banner (same widget Blizzard uses for raid warnings)
    -- plus an alarm sound plus a red chat line -- three channels so it's
    -- caught whether the player is looking at the middle of the screen,
    -- listening, or only reading chat.
    if RaidNotice_AddMessage and RaidWarningFrame then
        RaidNotice_AddMessage(RaidWarningFrame, "UNEQUIPPED & UNPROTECTED: " .. label, ChatTypeInfo and ChatTypeInfo["RAID_WARNING"])
    end
    PlaySound("RaidWarning")
    msg("|cffff0000!!! UNEQUIPPED !!!|r " .. label .. " |cffff0000is now sitting in your bags UNPROTECTED -- Clean() will sell/destroy it.|r")

    table.insert(pendingUnequipWarnings, item)
    ShowNextUnequipWarning()
end

-- One record per equipped slot: slot, item id, protection tag
-- (P=whitelisted, A=auto-protected custom item, U=unprotected - what
-- FlagUnequippedItem would actually alarm on). No name/link/hyperlink text
-- in the export - names are procedurally generated per-server text that
-- can't be pre-baked into a static file, so companion resolves them itself
-- via a local cache (WhitelistLiquidatorRemote.ResolveItem below); sending
-- them here would just be the same redundant bandwidth PushWhitelistState
-- used to spend, now avoided the same way.
local function PushEquippedState()
    local parts = {}
    for slot = EQUIP_FIRST_SLOT, EQUIP_LAST_SLOT do
        local item = equippedSnapshot[slot]
        if item then
            -- "A" covers both a custom item AND an unlisted item that's
            -- already above the confirm-quality floor - both are equally
            -- safe from Clean() (see IsSafeFromClean), just for different
            -- reasons than an explicit "P" whitelist entry.
            local tag
            if IsWhitelisted(item.id) then
                tag = "P"
            elseif IsCustomItem(item.id) or (item.quality or 0) >= ConfirmQuality() then
                tag = "A"
            else
                tag = "U"
            end
            table.insert(parts, table.concat({ slot, item.id or "", tag }, EXPORT_SEP))
        end
    end
    SendChunked("wl_equipped", parts)
end

local function SnapshotEquipped()
    for slot = EQUIP_FIRST_SLOT, EQUIP_LAST_SLOT do
        local link = GetInventoryItemLink("player", slot)
        if link then
            local id = ItemIDFromLink(link)
            local name, _, quality, _, _, _, _, _, _, texture = GetItemInfo(link)
            equippedSnapshot[slot] = {
                slot = slot,
                id = id,
                link = link,
                name = name,
                quality = quality,
                texture = texture,
            }
        else
            equippedSnapshot[slot] = nil
        end
    end
    PushEquippedState()
end

-- Compares against the previous snapshot rather than trusting the event's
-- own hasItem arg -- a direct gear swap (drag a new ring onto an occupied
-- slot) fires this with hasItem=true for the NEW item, but the OLD item
-- still silently left the slot and landed in bags in the same instant.
-- Comparing item IDs catches both that case and a plain unequip-to-empty.
local function OnEquipmentSlotChanged(slotID)
    if not slotID or slotID < EQUIP_FIRST_SLOT or slotID > EQUIP_LAST_SLOT then return end

    local previous = equippedSnapshot[slotID]
    local link = GetInventoryItemLink("player", slotID)
    local newID = link and ItemIDFromLink(link)

    if previous and previous.id and previous.id ~= newID then
        FlagUnequippedItem(previous)
    end

    if link then
        local name, _, quality, _, _, _, _, _, _, texture = GetItemInfo(link)
        equippedSnapshot[slotID] = {
            slot = slotID,
            id = newID,
            link = link,
            name = name,
            quality = quality,
            texture = texture,
        }
    else
        equippedSnapshot[slotID] = nil
    end
    PushEquippedState()
end

local function ListEquipped()
    msg("Currently tracked equipped items:")
    local any = false
    for slot = EQUIP_FIRST_SLOT, EQUIP_LAST_SLOT do
        local item = equippedSnapshot[slot]
        if item then
            any = true
            local tag
            if IsWhitelisted(item.id) then
                tag = "|cff55ff55[protected]|r"
            elseif IsCustomItem(item.id) or (item.quality or 0) >= ConfirmQuality() then
                tag = "|cff55ff55[auto]|r"
            else
                tag = "|cffff5555[UNPROTECTED]|r"
            end
            msg("  " .. (item.link or item.name or ("item:" .. tostring(item.id))) .. " " .. tag)
        end
    end
    if not any then msg("  (nothing equipped?)") end
end

-- No C_Timer in 3.3.5a; a small self-destructing OnUpdate frame stands in.
local function AfterDelay(sec, fn)
    local d = CreateFrame("Frame")
    local t = 0
    d:SetScript("OnUpdate", function(self, elapsed)
        t = t + elapsed
        if t >= sec then
            self:SetScript("OnUpdate", nil)
            fn()
        end
    end)
end

-- Vendor sells were previously fired back-to-back in the same scan loop --
-- fine for a couple items, but a big cleanup (20-30 junk items) meant that
-- many sell requests hitting the server in a single Lua tick with zero
-- pacing, unlike every other server call this addon/its siblings make (this
-- is what caused the disconnect). Selling in small batches with a pause
-- between batches keeps it fast without going back to one big burst.
local SELL_PACE = 0.15
local SELL_BATCH_SIZE = 10

local function ProcessSellQueue(queue, index)
    index = index or 1
    if not queue[index] then return end
    for i = index, math.min(index + SELL_BATCH_SIZE - 1, #queue) do
        local item = queue[i]
        -- Re-check the slot still holds what we saw during the scan -- the
        -- pacing delay gives the player a window to move/use items themselves.
        if GetContainerItemLink(item.bag, item.slot) then
            UseContainerItem(item.bag, item.slot)
        end
    end
    local nextIndex = index + SELL_BATCH_SIZE
    if queue[nextIndex] then
        AfterDelay(SELL_PACE, function() ProcessSellQueue(queue, nextIndex) end)
    end
end

local function Clean()
    if not MerchantFrame or not MerchantFrame:IsShown() then
        msg("|cffff5555Open a merchant first.|r Nothing touched.")
        return
    end

    if epicConfirmFrame and epicConfirmFrame:IsShown() then
        msg("|cffffaa00Finish the current Epic+ warning first.|r")
        return
    end

    local sold = 0
    local warned = 0
    local autoProtected = 0
    local autoProtectedNames = {}
    local sellQueue = {}
    pendingEpicDeletes = {}

    for bag = 4, 0, -1 do
        for slot = GetContainerNumSlots(bag), 1, -1 do
            local link = GetContainerItemLink(bag, slot)
            if link then
                local id = ItemIDFromLink(link)

                if id and not IsWhitelisted(id) then
                    local texture, count, locked = GetContainerItemInfo(bag, slot)
                    if not locked then
                        local name, _, quality, _, _, _, _, _, _, _, price = GetItemInfo(link)
                        quality = quality or 0
                        price = price or 0

                        -- Custom server item -- completely ignored, full stop.
                        -- Checked before anything else so it can never fall
                        -- through to the Epic+ queue or the sell/destroy path.
                        if IsCustomItem(id) then
                            autoProtected = autoProtected + (count or 1)
                            local label = (name or link) .. " [" .. tostring(id) .. "]"
                            if not autoProtectedNames[label] then
                                autoProtectedNames[label] = true
                                table.insert(autoProtectedNames, label)
                            end

                        -- IMPORTANT: anything at/above the confirm-quality
                        -- floor (Epic by default, settable to Rare) is NEVER
                        -- automatic.
                        elseif quality >= ConfirmQuality() then
                            table.insert(pendingEpicDeletes, {
                                bag = bag,
                                slot = slot,
                                itemID = id,
                                link = link,
                                texture = texture,
                                sellable = price > 0,
                                isEpic = true,
                                quality = quality,
                            })
                            warned = warned + 1

                        elseif price > 0 then
                            table.insert(sellQueue, { bag = bag, slot = slot })
                            sold = sold + (count or 1)

                        else
                            -- Fail-safe: every plain destroy candidate also
                            -- waits for a manual confirm now, not just
                            -- Epic+ -- nothing gets deleted with zero
                            -- confirmation, custom-item or not.
                            table.insert(pendingEpicDeletes, {
                                bag = bag,
                                slot = slot,
                                itemID = id,
                                link = link,
                                texture = texture,
                                sellable = false,
                                isEpic = false,
                            })
                            warned = warned + 1
                        end
                    end
                end
            end
        end
    end

    msg("Cleanup: |cffffcc00" .. sold .. " sold|r, |cffff66ff" .. warned ..
        " waiting for delete confirmation|r (Epic+ and plain junk alike -- nothing deletes without you confirming it), |cff55ff55" ..
        autoProtected .. " auto-protected|r (custom server item).")
    if #autoProtectedNames > 0 then
        msg("Auto-protected: " .. table.concat(autoProtectedNames, ", "))
    end

    if #sellQueue > 0 then
        ProcessSellQueue(sellQueue)
    end

    ShowNextEpicWarning()
end

local function ListWhitelist()
    msg("Protected item IDs:")
    local found = false
    for id, name in pairs(WhitelistLiquidatorDB.items) do
        found = true
        local link = select(2, GetItemInfo(id))
        msg("  " .. tostring(id) .. " - " .. (link or tostring(name)))
    end
    if not found then msg("  |cffff5555EMPTY|r") end
end


local function ListWhitelistChat()
    msg("Whitelist:")
    local rows = {}
    for id, saved in pairs(WhitelistLiquidatorDB.items) do
        local name, link = GetItemInfo(id)
        if type(saved) == "table" then
            name = name or saved.name
            link = link or saved.link
        elseif type(saved) == "string" then
            name = name or saved
        end
        name = name or ("Item "..id)
        table.insert(rows, {id=id, name=name, sortKey=string.lower(name), link=link})
    end
    -- Precompute each row's lowercase sort key once instead of recomputing
    -- string.lower on both sides of every single comparison table.sort
    -- makes (O(n log n) calls instead of O(n)) - only matters once the
    -- whitelist has dozens of entries, but costs nothing to do right.
    table.sort(rows, function(a,b) return a.sortKey < b.sortKey end)
    if #rows == 0 then
        msg("  |cffff5555EMPTY|r")
        return
    end
    for _, data in ipairs(rows) do
        msg("  " .. (data.link or data.name) .. " |cff888888[" .. data.id .. "]|r")
    end
end

local function AddByArgument(arg)
    local id = tonumber(arg) or ItemIDFromLink(arg)
    if not id then
        msg("Usage: /wl add ITEM_ID or shift-click an item link after '/wl add '.")
        return
    end
    local name, link, _, _, _, _, _, _, _, texture = GetItemInfo(id)
    WhitelistLiquidatorDB.items[id] = {
        name = name or ("Item " .. id),
        link = link,
        texture = texture,
    }
    msg("|cff55ff55ADDED|r " .. (link or ("item:" .. id)))
    RefreshWhitelistWindow()
end

local function RemoveByArgument(arg)
    local id = tonumber(arg) or ItemIDFromLink(arg)
    if not id then
        msg("Usage: /wl remove ITEM_ID")
        return
    end
    WhitelistLiquidatorDB.items[id] = nil
    msg("|cffff5555REMOVED|r item:" .. id)
    RefreshWhitelistWindow()
end

-- ------------------------------------------------------------
-- Named whitelist profiles. Every destructive operation (overwriting an
-- existing profile, loading one, deleting one) goes through a native
-- StaticPopupDialogs confirmation first, same pattern as CallBoardHelper's
-- whitelist profiles -- confirmed once here means the slash command, the
-- Profiles window's buttons, and any future trigger path are all protected
-- the same way without duplicating popup logic at each call site.
-- ------------------------------------------------------------
local RefreshProfilesWindow -- forward-declared, assigned once the Profiles frame exists below

StaticPopupDialogs["WHITELISTLIQUIDATOR_PROFILE_OVERWRITE"] = {
    text = "A profile named \"%s\" already exists.\nOverwrite it with your current whitelist?",
    button1 = "Overwrite",
    button2 = "Cancel",
    OnAccept = function(self, data) data.fn(data.name) end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

StaticPopupDialogs["WHITELISTLIQUIDATOR_PROFILE_LOAD"] = {
    text = "Load profile \"%s\"?\nThis replaces your current whitelist (%d entries).",
    button1 = "Load",
    button2 = "Cancel",
    OnAccept = function(self, data) data.fn(data.name) end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

StaticPopupDialogs["WHITELISTLIQUIDATOR_PROFILE_DELETE"] = {
    text = "Delete profile \"%s\"?\nThis cannot be undone.",
    button1 = "Delete",
    button2 = "Cancel",
    OnAccept = function(self, data) data.fn(data.name) end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

-- ------------------------------------------------------------
-- Whitelist import/export -- portable text string, same idea as
-- CallBoardHelper's "EHW1:" whitelist string (own "WLI1:" prefix so the two
-- addons' strings can never be cross-pasted into each other by mistake).
-- Entries here are numeric item IDs (this whitelist is keyed by item ID,
-- not by name text like CallBoardHelper's), newline-joined before Base64.
-- ------------------------------------------------------------
local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local function Base64Encode(data)
    return ((data:gsub(".", function(x)
        local r, byte = "", string.byte(x)
        for i = 8, 1, -1 do
            r = r .. (byte % 2^i - byte % 2^(i-1) > 0 and "1" or "0")
        end
        return r
    end) .. "0000"):gsub("%d%d%d?%d?%d?%d?", function(x)
        if #x < 6 then return "" end
        local c = 0
        for i = 1, 6 do
            c = c + (x:sub(i,i) == "1" and 2^(6-i) or 0)
        end
        return B64:sub(c+1,c+1)
    end) .. ({ "", "==", "=" })[#data % 3 + 1])
end

local function Base64Decode(data)
    data = data:gsub("[^" .. B64 .. "=]", "")
    return (data:gsub(".", function(x)
        if x == "=" then return "" end
        local r, f = "", (B64:find(x, 1, true) or 1) - 1
        for i = 6, 1, -1 do
            r = r .. (f % 2^i - f % 2^(i-1) > 0 and "1" or "0")
        end
        return r
    end):gsub("%d%d%d?%d?%d?%d?%d?%d?", function(x)
        if #x ~= 8 then return "" end
        local c = 0
        for i = 1, 8 do
            c = c + (x:sub(i,i) == "1" and 2^(8-i) or 0)
        end
        return string.char(c)
    end))
end

local function ExportWhitelist()
    local ids = {}
    for id in pairs(WhitelistLiquidatorDB.items) do ids[#ids + 1] = id end
    table.sort(ids)
    local strs = {}
    for i, id in ipairs(ids) do strs[i] = tostring(id) end
    return "WLI1:" .. Base64Encode(table.concat(strs, "\n"))
end

-- Parses/validates a WLI1 string with NO side effects -- the Share window
-- confirms the overwrite (CALLBOARDHELPER-style) before actually applying.
local function ParseWhitelistImport(text)
    text = tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local payload = text:match("^WLI1:(.+)$")
    if not payload then
        return false, "Invalid whitelist string. Expected WLI1:..."
    end

    local ok, decoded = pcall(Base64Decode, payload)
    if not ok or not decoded then
        return false, "Could not decode whitelist string."
    end

    local items = {}
    local n = 0
    for line in decoded:gmatch("[^\n]+") do
        local id = tonumber(line)
        if id then
            local name, link, _, _, _, _, _, _, _, texture = GetItemInfo(id)
            items[id] = { name = name or ("Item " .. id), link = link, texture = texture }
            n = n + 1
        end
    end
    return true, items, n
end

-- Replaces the whole whitelist, not a merge -- called only after the Share
-- window's confirmation popup is accepted.
local function ApplyImportedWhitelist(items)
    WhitelistLiquidatorDB.items = items
    RefreshWhitelistWindow()
end

StaticPopupDialogs["WHITELISTLIQUIDATOR_IMPORT_OVERWRITE"] = {
    text = "Import %d whitelisted items?\nThis replaces your current whitelist (%d items).",
    button1 = "Import",
    button2 = "Cancel",
    OnAccept = function(self, data)
        ApplyImportedWhitelist(data.items)
        msg("|cff55ff55whitelist imported|r (" .. data.count .. " items).")
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

local function WhitelistEntryCount()
    local n = 0
    for _ in pairs(WhitelistLiquidatorDB.items) do n = n + 1 end
    return n
end

local function DeepCopyItems(items)
    local copy = {}
    for id, data in pairs(items) do
        if type(data) == "table" then
            copy[id] = { name = data.name, link = data.link, texture = data.texture }
        else
            copy[id] = data
        end
    end
    return copy
end

local function SaveWhitelistProfileNow(name)
    WhitelistLiquidatorDB.profiles[name] = DeepCopyItems(WhitelistLiquidatorDB.items)
    msg("|cff55ff55profile saved|r: \"" .. name .. "\" (" .. WhitelistEntryCount() .. " items).")
    if RefreshProfilesWindow then RefreshProfilesWindow() end
end

local function SaveWhitelistProfile(name)
    name = tostring(name or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if name == "" then
        msg("Usage: /wl profile save <name>")
        return
    end
    if WhitelistLiquidatorDB.profiles[name] then
        StaticPopup_Show("WHITELISTLIQUIDATOR_PROFILE_OVERWRITE", name, nil, { name = name, fn = SaveWhitelistProfileNow })
        return
    end
    SaveWhitelistProfileNow(name)
end

local function LoadWhitelistProfileNow(name)
    WhitelistLiquidatorDB.items = DeepCopyItems(WhitelistLiquidatorDB.profiles[name])
    RefreshWhitelistWindow()
    msg("|cff55ff55profile loaded|r: \"" .. name .. "\" (" .. WhitelistEntryCount() .. " items).")
end

local function LoadWhitelistProfile(name)
    name = tostring(name or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if not WhitelistLiquidatorDB.profiles[name] then
        msg("no profile named \"" .. name .. "\". /wl profile list to see saved ones.")
        return
    end
    StaticPopup_Show("WHITELISTLIQUIDATOR_PROFILE_LOAD", name, WhitelistEntryCount(), { name = name, fn = LoadWhitelistProfileNow })
end

local function DeleteWhitelistProfileNow(name)
    WhitelistLiquidatorDB.profiles[name] = nil
    msg("|cffff5555profile deleted|r: \"" .. name .. "\".")
    if RefreshProfilesWindow then RefreshProfilesWindow() end
end

local function DeleteWhitelistProfile(name)
    name = tostring(name or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if not WhitelistLiquidatorDB.profiles[name] then
        msg("no profile named \"" .. name .. "\".")
        return
    end
    StaticPopup_Show("WHITELISTLIQUIDATOR_PROFILE_DELETE", name, nil, { name = name, fn = DeleteWhitelistProfileNow })
end

local function ListWhitelistProfiles()
    local names = {}
    for name in pairs(WhitelistLiquidatorDB.profiles) do names[#names + 1] = name end
    table.sort(names)
    if #names == 0 then
        msg("no whitelist profiles saved yet -- /wl profile save <name>.")
        return
    end
    msg("whitelist profiles (" .. #names .. "): " .. table.concat(names, ", "))
end


local WHITELIST_VISIBLE_ROWS = 14
local WHITELIST_ROW_HEIGHT = 24
local whitelistRowsCache = {}

local function BuildWhitelistRows()
    local rows = {}

    for id, saved in pairs(WhitelistLiquidatorDB.items) do
        local name, link, _, quality, _, _, _, _, _, texture = GetItemInfo(id)

        local savedName, savedLink, savedTexture
        if type(saved) == "table" then
            savedName = saved.name
            savedLink = saved.link
            savedTexture = saved.texture
        elseif type(saved) == "string" then
            savedName = saved
        end

        local resolvedName = name or savedName or ("Item " .. id)
        table.insert(rows, {
            id = id,
            name = resolvedName,
            sortKey = string.lower(resolvedName),
            link = link or savedLink,
            texture = texture or savedTexture or "Interface\\Icons\\INV_Misc_QuestionMark",
            quality = quality,
        })
    end

    -- Same reasoning as ListWhitelistChat's identical fix: a precomputed
    -- sort key beats recomputing string.lower(a.name)/string.lower(b.name)
    -- on every single comparison table.sort makes.
    table.sort(rows, function(a, b) return a.sortKey < b.sortKey end)

    return rows
end

RefreshWhitelistWindow = function()
    PushWhitelistState()
    -- A currently-equipped item's P/U tag in wl_equipped depends on whether
    -- it's whitelisted, so a manual whitelist edit here can flip that tag
    -- for gear still being worn - keep both exports in sync.
    PushEquippedState()
    -- Everything below here (a GetItemInfo call per whitelisted item, a
    -- sort, updating 14 row widgets + the scrollbar) only matters while the
    -- window is actually visible on screen. This function now runs on
    -- every add/remove/import/profile-load AND once at login (see the
    -- PLAYER_LOGIN/PLAYER_ENTERING_WORLD handler below) - most of those
    -- happen with the window closed, so skip the redraw entirely then.
    -- ToggleWhitelistWindow calls :Show() BEFORE calling this, so opening
    -- the window still gets a fresh build right here.
    if not whitelistWindow or not whitelistWindow:IsShown() then return end

    whitelistRowsCache = BuildWhitelistRows()
    local total = #whitelistRowsCache
    local offset = 0

    if whitelistWindow.scrollFrame then
        offset = FauxScrollFrame_GetOffset(whitelistWindow.scrollFrame) or 0
        FauxScrollFrame_Update(
            whitelistWindow.scrollFrame,
            total,
            WHITELIST_VISIBLE_ROWS,
            WHITELIST_ROW_HEIGHT
        )
    end

    for i = 1, WHITELIST_VISIBLE_ROWS do
        local row = whitelistWindow.rows[i]
        local data = whitelistRowsCache[offset + i]

        if data then
            row.itemID = data.id
            row.link = data.link
            row.icon:SetTexture(data.texture)
            row.text:SetText(data.name .. "  |cff888888[" .. data.id .. "]|r")
            row:Show()
        else
            row.itemID = nil
            row.link = nil
            row:Hide()
        end
    end

    whitelistWindow.title:SetText("Whitelist (" .. total .. ")")
end

local ToggleProfilesWindow -- forward-declared, assigned once the Profiles frame exists below

local function CreateWhitelistWindow()
    whitelistWindow = CreateFrame("Frame", "WhitelistLiquidatorListFrame", UIParent)
    whitelistWindow:SetWidth(450)
    whitelistWindow:SetHeight(470)
    whitelistWindow:SetPoint("CENTER", UIParent, "CENTER", 220, 0)
    whitelistWindow:SetFrameStrata("DIALOG")
    whitelistWindow:SetMovable(true)
    whitelistWindow:EnableMouse(true)
    whitelistWindow:RegisterForDrag("LeftButton")
    whitelistWindow:EnableMouseWheel(true)
    whitelistWindow:SetClampedToScreen(true)
    whitelistWindow:Hide()

    whitelistWindow:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 }
    })

    whitelistWindow:SetScript("OnDragStart", function(self) self:StartMoving() end)
    whitelistWindow:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)

    local title = whitelistWindow:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -16)
    title:SetText("Whitelist")
    whitelistWindow.title = title

    local close = CreateFrame("Button", nil, whitelistWindow, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -5, -5)

    local profilesBtn = CreateFrame("Button", nil, whitelistWindow, "UIPanelButtonTemplate")
    profilesBtn:SetWidth(90); profilesBtn:SetHeight(20)
    profilesBtn:SetPoint("TOPLEFT", 16, -13)
    profilesBtn:SetText("Share")
    profilesBtn:SetScript("OnClick", function() if ToggleProfilesWindow then ToggleProfilesWindow() end end)

    -- Scrollable item area.
    local scroll = CreateFrame(
        "ScrollFrame",
        "WhitelistLiquidatorScrollFrame",
        whitelistWindow,
        "FauxScrollFrameTemplate"
    )
    scroll:SetPoint("TOPLEFT", 18, -43)
    scroll:SetPoint("BOTTOMRIGHT", -32, 88)
    whitelistWindow.scrollFrame = scroll

    whitelistWindow:SetScript("OnMouseWheel", function(self, delta)
        local current = FauxScrollFrame_GetOffset(scroll) or 0
        local total = #whitelistRowsCache
        local maxOffset = math.max(0, total - WHITELIST_VISIBLE_ROWS)
        local nextOffset = current - delta * 3

        if nextOffset < 0 then nextOffset = 0 end
        if nextOffset > maxOffset then nextOffset = maxOffset end

        FauxScrollFrame_SetOffset(scroll, nextOffset)
        RefreshWhitelistWindow()
    end)

    scroll:SetScript("OnVerticalScroll", function(self, offset)
        FauxScrollFrame_OnVerticalScroll(
            self,
            offset,
            WHITELIST_ROW_HEIGHT,
            RefreshWhitelistWindow
        )
    end)

    whitelistWindow.rows = {}

    for i = 1, WHITELIST_VISIBLE_ROWS do
        local row = CreateFrame("Button", nil, whitelistWindow)
        row:SetWidth(392)
        row:SetHeight(WHITELIST_ROW_HEIGHT)
        row:SetPoint("TOPLEFT", 20, -45 - ((i - 1) * WHITELIST_ROW_HEIGHT))

        local icon = row:CreateTexture(nil, "ARTWORK")
        icon:SetWidth(18)
        icon:SetHeight(18)
        icon:SetPoint("LEFT", 0, 0)
        row.icon = icon

        local text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        text:SetPoint("LEFT", icon, "RIGHT", 5, 0)
        text:SetWidth(320)
        text:SetJustifyH("LEFT")
        if text.SetWordWrap then text:SetWordWrap(false) end
        row.text = text

        local remove = CreateFrame("Button", nil, row)
        remove:SetWidth(18)
        remove:SetHeight(18)
        remove:SetPoint("RIGHT", 0, 0)
        remove:SetNormalTexture("Interface\\Buttons\\UI-GroupLoot-Pass-Up")
        remove:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square")

        remove:SetScript("OnClick", function()
            if row.itemID then
                local id = row.itemID
                local link = select(2, GetItemInfo(id))
                WhitelistLiquidatorDB.items[id] = nil
                msg("|cffff5555REMOVED|r " .. (link or ("item:" .. id)))
                RefreshWhitelistWindow()
            end
        end)

        row:SetScript("OnEnter", function(self)
            if self.itemID then
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                if self.link then
                    GameTooltip:SetHyperlink(self.link)
                else
                    GameTooltip:SetHyperlink("item:" .. self.itemID)
                end
                GameTooltip:Show()
            end
        end)

        row:SetScript("OnLeave", function()
            GameTooltip:Hide()
        end)

        whitelistWindow.rows[i] = row
    end

    -- Drop target remains fixed below the scrolling list.
    -- Must clear row 14 (the deepest possible row, at y=-381 from the
    -- window's top -- this frame is fixed regardless of window height) with
    -- a real gap, or a fully-populated whitelist visually crams this box
    -- against the last row.
    local drop = CreateFrame("Button", nil, whitelistWindow)
    drop:SetWidth(390)
    drop:SetHeight(36)
    drop:SetPoint("BOTTOM", 0, 39)
    drop:EnableMouse(true)
    drop:RegisterForDrag("LeftButton")
    drop:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 }
    })
    drop:SetBackdropColor(0.08, 0.08, 0.08, 0.95)

    local dropText = drop:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    dropText:SetPoint("CENTER")
    dropText:SetText("DROP ITEM HERE TO WHITELIST")

    local function AddCursorItemToWhitelist()
        local kind, itemID, itemLink = GetCursorInfo()
        if kind ~= "item" or not itemID then
            return
        end

        itemID = tonumber(itemID)
        local name, link, _, _, _, _, _, _, _, texture = GetItemInfo(itemID)

        WhitelistLiquidatorDB.items[itemID] = {
            name = name or ("Item " .. itemID),
            link = link or itemLink,
            texture = texture,
        }

        ClearCursor()
        msg("|cff55ff55ADDED|r " .. (link or itemLink or ("item:" .. itemID)))
        RefreshWhitelistWindow()
    end

    drop:SetScript("OnReceiveDrag", AddCursorItemToWhitelist)
    drop:SetScript("OnMouseUp", function()
        if CursorHasItem() then
            AddCursorItemToWhitelist()
        end
    end)

    local hint = whitelistWindow:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    hint:SetPoint("BOTTOM", 0, 19)
    hint:SetWidth(390)
    hint:SetJustifyH("CENTER")
    hint:SetText("Mouse wheel / scrollbar to browse whitelist")
end

local function ToggleWhitelistWindow()
    if not whitelistWindow then return end
    if whitelistWindow:IsShown() then
        whitelistWindow:Hide()
    else
        -- Show() BEFORE Refresh(): RefreshWhitelistWindow now skips its
        -- expensive row rebuild while the window is hidden (see its own
        -- comment), so it needs IsShown() to already read true here.
        whitelistWindow:Show()
        RefreshWhitelistWindow()
    end
end

-- ------------------------------------------------------------
-- Profiles window -- name entry + Save As, plus a list of saved profiles
-- with Load/Delete per row. Same layout pattern as CallBoardHelper's Share
-- Whitelist window (grows only as tall as the actual row count needs,
-- zebra-striped rows, red Delete button), kept as a separate small window
-- rather than crammed into the whitelist window's already-fixed layout
-- (title/scroll area/drop target there are all fixed-position).
-- ------------------------------------------------------------
local profilesWindow
local PROFILES_ROWS_TOP = 168
local PROFILES_ROW_H = 19
local PROFILES_MAX_ROWS = 10
local PROFILES_BOTTOM_MARGIN = 14
local PROFILES_STRIPE_COLOR = { 1, 1, 1, 0.035 }

local function CreateProfilesWindow()
    profilesWindow = CreateFrame("Frame", "WhitelistLiquidatorProfilesFrame", UIParent)
    profilesWindow:SetWidth(400); profilesWindow:SetHeight(240)
    profilesWindow:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    profilesWindow:SetFrameStrata("FULLSCREEN_DIALOG")
    profilesWindow:SetMovable(true)
    profilesWindow:EnableMouse(true)
    profilesWindow:RegisterForDrag("LeftButton")
    profilesWindow:SetToplevel(true)
    profilesWindow:SetClampedToScreen(true)
    profilesWindow:Hide()
    profilesWindow:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 }
    })
    profilesWindow:SetScript("OnDragStart", function(self) self:StartMoving() end)
    profilesWindow:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)

    local title = profilesWindow:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -14)
    title:SetText("Share Whitelist")

    local close = CreateFrame("Button", nil, profilesWindow, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -4, -4)

    local help = profilesWindow:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    help:SetPoint("TOPLEFT", 18, -38)
    help:SetPoint("TOPRIGHT", -18, -38)
    help:SetJustifyH("LEFT")
    help:SetText("Copy to save/share -- paste another WLI1 string to import")

    local edit = CreateFrame("EditBox", "WhitelistLiquidatorShareEdit", profilesWindow, "InputBoxTemplate")
    edit:SetPoint("TOPLEFT", 22, -54)
    edit:SetPoint("TOPRIGHT", -22, -54)
    edit:SetHeight(24)
    edit:SetAutoFocus(false)
    edit:SetTextInsets(5, 5, 0, 0)
    edit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    edit:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)

    -- 3 equal-width buttons filling the same span as the edit box above --
    -- same layout CallBoardHelper's Share Whitelist window uses.
    local btnW = 106
    local exportBtn = CreateFrame("Button", nil, profilesWindow, "UIPanelButtonTemplate")
    exportBtn:SetWidth(btnW); exportBtn:SetHeight(21)
    exportBtn:SetPoint("TOPLEFT", 22, -82)
    exportBtn:SetText("Export")
    exportBtn:SetScript("OnClick", function()
        edit:SetText(ExportWhitelist())
        edit:SetFocus()
        edit:HighlightText()
    end)

    local importBtn = CreateFrame("Button", nil, profilesWindow, "UIPanelButtonTemplate")
    importBtn:SetWidth(btnW); importBtn:SetHeight(21)
    importBtn:SetPoint("LEFT", exportBtn, "RIGHT", 6, 0)
    importBtn:SetText("Import")
    importBtn:SetScript("OnClick", function()
        local ok, itemsOrErr, count = ParseWhitelistImport(edit:GetText())
        if not ok then
            msg("|cffff5555" .. itemsOrErr .. "|r")
            return
        end
        edit:ClearFocus()
        StaticPopup_Show("WHITELISTLIQUIDATOR_IMPORT_OVERWRITE", count, WhitelistEntryCount(), { items = itemsOrErr, count = count })
    end)

    local selectBtn = CreateFrame("Button", nil, profilesWindow, "UIPanelButtonTemplate")
    selectBtn:SetWidth(btnW); selectBtn:SetHeight(21)
    selectBtn:SetPoint("LEFT", importBtn, "RIGHT", 6, 0)
    selectBtn:SetText("Select All")
    selectBtn:SetScript("OnClick", function()
        edit:SetFocus()
        edit:HighlightText()
    end)

    local sep = profilesWindow:CreateTexture(nil, "ARTWORK")
    sep:SetTexture("Interface\\Tooltips\\UI-Tooltip-Background")
    sep:SetPoint("TOPLEFT", 18, -110)
    sep:SetPoint("TOPRIGHT", -18, -110)
    sep:SetHeight(1)
    sep:SetVertexColor(0.95, 0.72, 0.16, 0.55)

    local profileLabel = profilesWindow:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    profileLabel:SetPoint("TOPLEFT", 22, -118)
    profileLabel:SetText("Whitelist Profiles")

    local nameEdit = CreateFrame("EditBox", "WhitelistLiquidatorProfileNameEdit", profilesWindow, "InputBoxTemplate")
    nameEdit:SetPoint("TOPLEFT", 22, -136)
    nameEdit:SetWidth(150); nameEdit:SetHeight(20)
    nameEdit:SetAutoFocus(false)
    nameEdit:SetMaxLetters(32)
    nameEdit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

    local saveBtn = CreateFrame("Button", nil, profilesWindow, "UIPanelButtonTemplate")
    saveBtn:SetWidth(btnW); saveBtn:SetHeight(20)
    saveBtn:SetPoint("LEFT", nameEdit, "RIGHT", 6, 0)
    saveBtn:SetText("Save As")
    saveBtn:SetScript("OnClick", function()
        local text = nameEdit:GetText()
        if text and text ~= "" then
            SaveWhitelistProfile(text) -- resizes/refreshes this window itself via RefreshProfilesWindow
            nameEdit:SetText("")
            nameEdit:ClearFocus()
        end
    end)
    nameEdit:SetScript("OnEnterPressed", function(self) self:ClearFocus(); saveBtn:Click() end)

    local emptyText = profilesWindow:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    emptyText:SetPoint("TOPLEFT", 22, -PROFILES_ROWS_TOP)
    emptyText:SetText("No profiles saved yet.")

    local rows = {}
    for i = 1, PROFILES_MAX_ROWS do
        local row = CreateFrame("Frame", nil, profilesWindow)
        row:SetWidth(356); row:SetHeight(PROFILES_ROW_H)
        row:SetPoint("TOPLEFT", 22, -PROFILES_ROWS_TOP - (i - 1) * PROFILES_ROW_H)
        if i % 2 == 0 then
            local stripe = row:CreateTexture(nil, "BACKGROUND")
            stripe:SetAllPoints(row)
            stripe:SetTexture(unpack(PROFILES_STRIPE_COLOR))
        end

        row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.text:SetPoint("LEFT", 0, 0)
        row.text:SetWidth(224)
        row.text:SetJustifyH("LEFT")

        row.loadBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
        row.loadBtn:SetWidth(56); row.loadBtn:SetHeight(17)
        row.loadBtn:SetPoint("RIGHT", row, "RIGHT", -62, 0)
        row.loadBtn:SetText("Load")

        row.deleteBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
        row.deleteBtn:SetWidth(56); row.deleteBtn:SetHeight(17)
        row.deleteBtn:SetPoint("LEFT", row.loadBtn, "RIGHT", 6, 0)
        row.deleteBtn:SetText("Delete")
        row.deleteBtn:GetFontString():SetTextColor(1, 0.35, 0.35)

        row:Hide()
        rows[i] = row
    end

    local moreHint = profilesWindow:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    moreHint:Hide()

    RefreshProfilesWindow = function()
        local names = {}
        for name in pairs(WhitelistLiquidatorDB.profiles) do names[#names + 1] = name end
        table.sort(names)

        -- Not SetShown - doesn't exist on this client (3.3.5a), any widget
        -- type (found live via EchoTracker's identical pattern crashing).
        if #names == 0 then
            emptyText:Show()
        else
            emptyText:Hide()
        end

        for i, row in ipairs(rows) do
            local name = names[i]
            if name then
                row.text:SetText(name)
                row.loadBtn:SetScript("OnClick", function() LoadWhitelistProfile(name) end)
                row.deleteBtn:SetScript("OnClick", function() DeleteWhitelistProfile(name) end)
                row:Show()
            else
                row:Hide()
            end
        end

        local shownRows = math.max(1, math.min(#names, PROFILES_MAX_ROWS))
        local overflow = #names > PROFILES_MAX_ROWS
        if overflow then
            moreHint:ClearAllPoints()
            moreHint:SetPoint("TOPLEFT", 22, -PROFILES_ROWS_TOP - shownRows * PROFILES_ROW_H - 2)
            moreHint:SetText("+" .. (#names - PROFILES_MAX_ROWS) .. " more -- /wl profile list")
            moreHint:Show()
        else
            moreHint:Hide()
        end

        profilesWindow:SetHeight(PROFILES_ROWS_TOP + shownRows * PROFILES_ROW_H
            + (overflow and (PROFILES_ROW_H + 2) or 0) + PROFILES_BOTTOM_MARGIN)
    end
end

ToggleProfilesWindow = function()
    if not profilesWindow then return end
    if profilesWindow:IsShown() then
        profilesWindow:Hide()
    else
        RefreshProfilesWindow()
        profilesWindow:Show()
    end
end

-- Same construction as CheckpointFavorites' quick-teleport button and
-- EchoTracker's wishlist button (bg fill, inset+cropped icon, full-size
-- border, inset ADD-blend highlight texture) - all three own-addon
-- floating triggers now share one visual "type" instead of three
-- independently-built button styles that happened to end up different
-- sizes/insets.
local function CreateButton()
    button = CreateFrame("Button", "WhitelistLiquidatorButton", UIParent)
    button:SetWidth(36)
    button:SetHeight(36)
    button:SetFrameStrata("MEDIUM")
    button:SetClampedToScreen(true)
    button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    button:RegisterForDrag("LeftButton")
    button:SetMovable(true)

    local bg = button:CreateTexture(nil, "BACKGROUND")
    bg:SetPoint("TOPLEFT", 2, -2)
    bg:SetPoint("BOTTOMRIGHT", -2, 2)
    bg:SetTexture(0.018, 0.020, 0.026, 0.95)

    -- Built-in WoW icon; no external texture files required. Inset 2px
    -- with the same 0.08-0.92 texcoord crop CheckpointFavorites uses,
    -- which trims each icon's own built-in border pixels so the ring
    -- texture below reads as the only border.
    local icon = button:CreateTexture(nil, "ARTWORK")
    icon:SetPoint("TOPLEFT", 2, -2)
    icon:SetPoint("BOTTOMRIGHT", -2, 2)
    icon:SetTexture("Interface\\Icons\\INV_Misc_Coin_01")
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    button.icon = icon

    local border = button:CreateTexture(nil, "OVERLAY")
    border:SetTexture("Interface\\Buttons\\UI-Quickslot2")
    border:SetAllPoints(button)

    local hl = button:CreateTexture(nil, "HIGHLIGHT")
    hl:SetPoint("TOPLEFT", 2, -2)
    hl:SetPoint("BOTTOMRIGHT", -2, 2)
    hl:SetTexture("Interface\\Buttons\\ButtonHilight-Square")
    hl:SetBlendMode("ADD")

    local p = WhitelistLiquidatorDB.button
    button:SetPoint(p.point or "CENTER", UIParent, p.relativePoint or "CENTER",
                    p.x or 0, p.y or 0)

    button:SetScript("OnDragStart", function(self)
        self:StartMoving()
    end)

    button:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, relativePoint, x, y = self:GetPoint(1)
        WhitelistLiquidatorDB.button.point = point
        WhitelistLiquidatorDB.button.relativePoint = relativePoint
        WhitelistLiquidatorDB.button.x = x
        WhitelistLiquidatorDB.button.y = y
    end)

    button:SetScript("OnClick", function(self, mouseButton)
        if mouseButton == "LeftButton" then
            Clean()
        else
            if IsShiftKeyDown() then
                Status()
            else
                ToggleWhitelistWindow()
            end
        end
    end)

    button:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Whitelist Liquidator", 1, 1, 1)
        GameTooltip:AddLine("Left Click: CLEAN", 1, .82, 0)
        GameTooltip:AddLine("Right Click: WHITELIST", .7, .9, 1)
        GameTooltip:AddLine("Shift + Right Click: STATUS", .7, .7, .7)
        GameTooltip:AddLine("Drag: move button", .8, .8, .8)
        GameTooltip:AddLine("Drag bag item into whitelist window", .3, 1, .6)
        GameTooltip:AddLine("Drag bag item to DROP HERE: protect", .3, 1, .6)
        GameTooltip:Show()
    end)

    button:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
end

-- ------------------------------------------------------------
-- Remote-control surface for companion/FlaskGUI. Everything above this
-- point is `local` (by design - this file has no other addon-facing API),
-- so this is the one deliberate set of real globals a `/api/cmd/lua`
-- payload can call from outside the game (see wow_bridge's api.rs and
-- companion's bridge.rs - that endpoint queues a short Lua string for
-- `loadstring`/`pcall`, run against the game's normal global environment,
-- which has no access to this file's own upvalues except through globals
-- like this one). Every call here is short enough (well under
-- bridge.rs's ~195-byte LUA_CMD_BUDGET) to fit in a single queued command.
-- ------------------------------------------------------------
WhitelistLiquidatorRemote = {}

function WhitelistLiquidatorRemote.Protect()
    if unequipWarningFrame and unequipWarningFrame:IsShown() and unequipWarningFrame.data then
        local data = unequipWarningFrame.data
        unequipWarningFrame:Hide()
        unequipWarningFrame.data = nil
        WhitelistLiquidatorDB.items[data.id] = {
            name = data.name,
            link = data.link,
            texture = data.texture,
        }
        msg("|cff55ff55PROTECTED|r " .. (data.link or data.name or ("item:" .. data.id)) .. " (via companion)")
        RefreshWhitelistWindow()
        ShowNextUnequipWarning()
    end
end

function WhitelistLiquidatorRemote.Dismiss()
    if unequipWarningFrame and unequipWarningFrame:IsShown() then
        unequipWarningFrame:Hide()
        unequipWarningFrame.data = nil
        ShowNextUnequipWarning()
    end
end

function WhitelistLiquidatorRemote.Add(id)
    id = tonumber(id)
    if not id then return end
    local name, link, _, _, _, _, _, _, _, texture = GetItemInfo(id)
    WhitelistLiquidatorDB.items[id] = { name = name or ("Item " .. id), link = link, texture = texture }
    msg("|cff55ff55ADDED|r " .. (link or ("item:" .. id)) .. " (via companion)")
    RefreshWhitelistWindow()
end

function WhitelistLiquidatorRemote.Remove(id)
    id = tonumber(id)
    if not id then return end
    WhitelistLiquidatorDB.items[id] = nil
    msg("|cffff5555REMOVED|r item:" .. id .. " (via companion)")
    RefreshWhitelistWindow()
end

function WhitelistLiquidatorRemote.Clean()
    Clean()
end

-- On-demand name/quality/texture lookup for companion's local item cache
-- (data/cache/items.sqlite3) - called via /api/cmd/lua as
-- WhitelistLiquidatorRemote.ResolveItem(12345) for exactly one id at a
-- time, since a plain numeric argument keeps every call trivially under
-- bridge.rs's ~195-byte LUA_CMD_BUDGET regardless of how many ids
-- companion eventually needs. GetItemInfo can legitimately return nil if
-- the client's own item cache hasn't seen this item yet (rare for
-- something already equipped or whitelisted, since both imply the player
-- already interacted with it) - reports an empty name in that case rather
-- than erroring, so companion knows to retry later instead of caching a
-- permanent blank.
function WhitelistLiquidatorRemote.ResolveItem(id)
    id = tonumber(id)
    if not id then return end
    local name, _, quality, _, _, _, _, _, _, texture = GetItemInfo(id)
    ReportToBridge("wl_item_resolved", table.concat({
        id,
        (name or ""):gsub("[;\n\r]", " "),
        quality or "",
        texture or "",
    }, EXPORT_SEP))
end

SLASH_WHITELISTLIQUIDATOR1 = "/wl"
SlashCmdList["WHITELISTLIQUIDATOR"] = function(input)
    EnsureDB()
    input = input or ""

    local cmd, rest = string.match(input, "^(%S*)%s*(.-)$")
    cmd = string.lower(cmd or "")

    if cmd == "clean" then
        Clean()
    elseif cmd == "status" then
        Status()
    elseif cmd == "list" then
        ToggleWhitelistWindow()
    elseif cmd == "listchat" then
        ListWhitelistChat()
    elseif cmd == "equipped" then
        ListEquipped()
    elseif cmd == "add" then
        AddByArgument(rest)
    elseif cmd == "remove" or cmd == "del" then
        RemoveByArgument(rest)
    elseif cmd == "show" then
        button:Show()
    elseif cmd == "hide" then
        button:Hide()
    elseif cmd == "confirmquality" then
        local v = string.lower(rest or "")
        if v == "" then
            msg("Confirm-before-touching floor: " .. string.upper(QUALITY_NAMES[ConfirmQuality()] or "?") ..
                "+. Usage: /wl confirmquality rare|uncommon|epic|legendary")
        else
            local q = QUALITY_BY_NAME[v] or tonumber(v)
            if q and QUALITY_NAMES[q] then
                WhitelistLiquidatorDB.confirmQuality = q
                msg("Confirm-before-touching floor set to |cffffcc00" .. QUALITY_NAMES[q] .. "+|r -- " ..
                    "anything that quality or higher now waits for your confirmation instead of being auto-sold/destroyed.")
            else
                msg("Unknown quality \"" .. rest .. "\". Try: uncommon, rare, epic, or legendary.")
            end
        end
    elseif cmd == "profile" then
        local sub, subarg = string.match(rest, "^(%S*)%s*(.-)$")
        sub = string.lower(sub or "")
        if sub == "save" then
            SaveWhitelistProfile(subarg)
        elseif sub == "load" then
            LoadWhitelistProfile(subarg)
        elseif sub == "delete" then
            DeleteWhitelistProfile(subarg)
        elseif sub == "list" then
            ListWhitelistProfiles()
        else
            msg("usage: /wl profile save|load|delete <name>  or  /wl profile list")
        end
    else
        msg("/wl clean | status | list | listchat | equipped | add ID | remove ID | show | hide")
        msg("/wl profile save|load|delete <name> | profile list -- named whitelist sets, or use the Share button in the whitelist window")
        msg("/wl confirmquality rare|epic|... -- set the quality floor that always waits for confirmation (default Epic)")
        msg("Open whitelist window, drag items onto DROP ITEM HERE, and scroll to browse")
        msg("Drag floating button = move")
        msg("Unequipping a non-whitelisted item now triggers an automatic warning -- /wl equipped to see what's tracked")
    end
end

frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("BAG_UPDATE")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")

frame:SetScript("OnEvent", function(self, event, arg1, arg2)
    if event == "ADDON_LOADED" and arg1 == ADDON then
        EnsureDB()
        CreateWhitelistWindow()
        CreateProfilesWindow()
        CreateEpicConfirmFrame()
        CreateUnequipWarningFrame()
        CreateButton()
        -- No login print - the floating button appearing is already
        -- visible proof the addon loaded, same as CallBoardHelper/
        -- CheckpointFavorites' minimap buttons don't announce themselves
        -- in chat either.
    elseif event == "PLAYER_LOGIN" or event == "PLAYER_ENTERING_WORLD" then
        -- GetInventoryItemLink can transiently return nil for every slot
        -- right after a loading screen (the local item cache hasn't caught
        -- up yet) - confirmed live: the very first post-reload snapshot came
        -- back completely empty and nothing ever re-triggered it afterward
        -- since no gear was actually touched that session. Retries a few
        -- times, a beat apart, until it sees at least one equipped item or
        -- gives up (a genuinely bare frame - character creation screen,
        -- ghost form - stops retrying instead of looping forever).
        local function trySnapshot(attempt)
            SnapshotEquipped()
            local hasAny = false
            for slot = EQUIP_FIRST_SLOT, EQUIP_LAST_SLOT do
                if equippedSnapshot[slot] then
                    hasAny = true
                    break
                end
            end
            if not hasAny and attempt < 5 then
                AfterDelay(1.5, function() trySnapshot(attempt + 1) end)
            end
        end
        trySnapshot(1)
        -- Also pushes wl_whitelist once at login - otherwise a whitelist
        -- nobody edits/opens this session (RefreshWhitelistWindow's only
        -- other call sites are add/remove/import/opening the window) would
        -- never get its first push at all, even though it's non-empty.
        RefreshWhitelistWindow()
    elseif event == "PLAYER_EQUIPMENT_CHANGED" then
        OnEquipmentSlotChanged(arg1)
    elseif event == "BAG_UPDATE" then
        -- No bag-button hooks required in v1.8. Still marks wl_status dirty
        -- so the next OnUpdate tick reflects the new bag contents.
        statusDirty = true
    end
end)

-- Drains the wl_status dirty flag on its own throttle (see
-- STATUS_PUSH_INTERVAL above) - a full bag scan on every BAG_UPDATE would
-- be wasteful when several fire back to back (e.g. a Clean() sell batch).
frame:SetScript("OnUpdate", function(self, elapsed)
    if not statusDirty then return end
    statusPushElapsed = statusPushElapsed + elapsed
    if statusPushElapsed >= STATUS_PUSH_INTERVAL then
        statusPushElapsed = 0
        statusDirty = false
        PushStatusState()
    end
end)
