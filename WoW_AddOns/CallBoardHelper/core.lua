CallBoardHelper = CallBoardHelper or {}

-- ============================================================
-- Auto-detects wanted objectives on ProjectEbonhold's Objectives board (any
-- type -- Open World/Dungeon/Raid/Profession) and selects one automatically.
-- "Wanted" means its title/objective text contains one of YOUR whitelist
-- entries (case-insensitive substring match) -- add or remove entries
-- freely via Settings, the Quest Browser, or /callboard add|remove. Nothing
-- is hardcoded and the whitelist starts empty -- the Quest Browser
-- (Settings > Browse Quests, or /callboard browse) lists every objective
-- this character has ever seen on the board so you can pick from real,
-- exact titles instead of typing them blind. If none of the 3 offered are
-- wanted, it rerolls -- up to a safety cap, since the reroll cost is real
-- gold that scales with level (level^2*15 + level*100 copper, same formula
-- the real addon uses).
--
-- Reads/writes ONLY through ProjectEbonhold.ObjectivesService, the same
-- API the real Objectives board UI uses. Never touches any other addon's
-- saved data.
--
-- Default OFF -- this spends real gold automatically once enabled, so it
-- should be an explicit opt-in, not silent-by-default. /callboard on
-- ============================================================

-- One-time migration from the old EternalsHelper addon (renamed to
-- CallBoardHelper). Only fires the very first time this addon ever loads
-- (CallBoardHelperDB doesn't exist yet) and only if the old addon's
-- SavedVariables happen to be in memory -- which requires the old
-- EternalsHelper addon folder to still be installed/enabled for at least
-- this one login, since a different addon's SavedVariables file is only
-- ever loaded by the game if that addon itself is still present. Safe to
-- delete the old EternalsHelper folder once you've confirmed (via
-- /callboard list or the Quest Browser) that your whitelist/profiles came
-- across.
local function MigrateFromEternalsHelper()
    if CallBoardHelperDB ~= nil then return end
    if type(_G.EternalsHelperDB) ~= "table" then return end
    CallBoardHelperDB = _G.EternalsHelperDB
    DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffCallBoardHelper:|r migrated your settings/whitelist/profiles from the old EternalsHelper addon. You can delete the EternalsHelper folder now.")
end

local function DB()
    MigrateFromEternalsHelper()
    CallBoardHelperDB = CallBoardHelperDB or { enabled = false, maxRerolls = 8, whitelist = {} }
    if CallBoardHelperDB.enabled == nil then CallBoardHelperDB.enabled = false end
    if CallBoardHelperDB.maxRerolls == nil then CallBoardHelperDB.maxRerolls = 8 end
    if CallBoardHelperDB.whitelist == nil then CallBoardHelperDB.whitelist = {} end
    if CallBoardHelperDB.catalog == nil then CallBoardHelperDB.catalog = {} end
    if CallBoardHelperDB.delayMin == nil then CallBoardHelperDB.delayMin = 0.20 end
    if CallBoardHelperDB.delayMax == nil then CallBoardHelperDB.delayMax = 0.70 end
    if CallBoardHelperDB.log == nil then CallBoardHelperDB.log = {} end
    if CallBoardHelperDB.debugTrace == nil then CallBoardHelperDB.debugTrace = false end
    if CallBoardHelperDB.profiles == nil then CallBoardHelperDB.profiles = {} end

    -- One-time migration: the whitelist used to live under `eternalFilter`
    -- (and before that, under bare element words like "Air" rather than
    -- full names like "Eternal Air"). Carries old enabled/disabled choices
    -- forward instead of losing them.
    if CallBoardHelperDB.eternalFilter then
        for _, short in ipairs({ "Air", "Earth", "Fire", "Water", "Shadow", "Life" }) do
            if CallBoardHelperDB.eternalFilter[short] ~= nil then
                local long = "Eternal " .. short
                if CallBoardHelperDB.eternalFilter[long] == nil then
                    CallBoardHelperDB.eternalFilter[long] = CallBoardHelperDB.eternalFilter[short]
                end
                CallBoardHelperDB.eternalFilter[short] = nil
            end
        end
        for name, v in pairs(CallBoardHelperDB.eternalFilter) do
            if CallBoardHelperDB.whitelist[name] == nil then CallBoardHelperDB.whitelist[name] = v end
        end
        CallBoardHelperDB.eternalFilter = nil
    end

    -- One-time cleanup: earlier versions auto-seeded the whitelist with bare
    -- material names ("Eternal Air", "Leather", etc.) so there'd be
    -- something to toggle before you'd seen any real quest titles. The
    -- Quest Browser replaced that need and the leftover bare-name entries
    -- just clutter the list next to real discovered titles ("Eternal Air
    -- Wanted", "Supply Run: Eternal Fire") -- remove them once, whether
    -- they're on or off. Runs only once, ever; if you deliberately re-add
    -- one of these exact names later, it's yours to keep.
    if not CallBoardHelperDB.seedEntriesRemoved then
        for _, name in ipairs({ "Eternal Air", "Eternal Earth", "Eternal Fire", "Eternal Water", "Eternal Shadow", "Eternal Life", "Leather" }) do
            CallBoardHelperDB.whitelist[name] = nil
        end
        CallBoardHelperDB.seedEntriesRemoved = true
    end

    return CallBoardHelperDB
end

-- Every Print() also gets appended to a persisted plain-text log (color
-- codes stripped), capped at the most recent 500 lines. SavedVariables only
-- flushes to the real .lua file on disk at /reload or logout -- that file
-- (WTF\Account\<account>\SavedVariables\CallBoardHelper.lua) is plain text,
-- readable in any editor, under the `log = {...}` table. For a live look
-- without waiting on a reload, use /callboard log or /callboard logview.
local function Print(msg)
    msg = tostring(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffCallBoardHelper:|r " .. msg)

    local log = DB().log
    local plain = (date and date("%H:%M:%S ") or "") .. msg:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    log[#log + 1] = plain
    if #log > 500 then table.remove(log, 1) end
end

-- Wanted = an enabled whitelist entry is a case-insensitive substring of
-- the objective's title/objective text. The whitelist IS the filter now --
-- nothing is auto-discovered or auto-enabled behind your back; if it's not
-- on your list, it's left alone. Add broad entries (e.g. "Eternal") to
-- match a whole family, or narrow ones (e.g. "Eternal Water") to match
-- just one -- plain substring, so it's your call. Never gated by quest
-- type -- a Dungeon or Raid objective can be whitelisted just as well as a
-- Profession one, it's whatever text you add.
local function IsWanted(o)
    if not o then return false end
    local text = string.lower((o.title or "") .. " " .. (o.objectiveText or ""))
    for key, enabled in pairs(DB().whitelist) do
        if enabled and text:find(string.lower(key), 1, true) then
            return true, key
        end
    end
    return false
end

-- Shared by AddWhitelistEntry's heads-up note and the Browser row tooltip:
-- is `text` already matched by some OTHER enabled whitelist entry? Returns
-- that entry's key, or nil. `excludeKey` skips comparing an entry against
-- itself (case-insensitive, since the entry and `text` are often the exact
-- same string with different casing).
local function FindCoveringEntry(text, excludeKey)
    local lowerText = string.lower(text)
    local lowerExclude = excludeKey and string.lower(excludeKey)
    for key, enabled in pairs(DB().whitelist) do
        if enabled and (not lowerExclude or string.lower(key) ~= lowerExclude) and lowerText:find(string.lower(key), 1, true) then
            return key
        end
    end
    return nil
end

local function Signature(list)
    local parts = {}
    for _, o in ipairs(list or {}) do parts[#parts + 1] = tostring(o.questId) end
    return table.concat(parts, ",")
end

-- Matches ProjectEbonhold's own questType numbering (objectives_service.lua):
-- 1 Open World, 2 Dungeon, 3 Raid, 4 Profession. Used only for the Browser's
-- kind-column labels.
local QUEST_TYPE_INFO = {
    [1] = { name = "Open World" },
    [2] = { name = "Dungeon" },
    [3] = { name = "Raid" },
    [4] = { name = "Profession" },
}

local function QuestTypeName(qt)
    return (QUEST_TYPE_INFO[qt] or QUEST_TYPE_INFO[1]).name
end

-- Single source of truth for both windows' default positions -- used at
-- creation time and by ResetWindowPositions, so the two can never drift out
-- of sync with each other again the way the overlap bug did.
local SETTINGS_DEFAULT_X, SETTINGS_DEFAULT_Y = -235, 40
local BROWSER_DEFAULT_X, BROWSER_DEFAULT_Y = 235, 20

-- The server has no static catalog of objective titles anywhere (confirmed
-- against the ProjectEbonhold client addon source -- it's server-only
-- content), so the only way to build a browsable list is to remember every
-- objective this character has ever actually been offered. Runs regardless
-- of DB().enabled -- purely local bookkeeping, never touches the server, and
-- lets you browse/whitelist things before ever turning the automation on.
local function RecordCatalog(list)
    if type(list) ~= "table" then return end
    local catalog = DB().catalog
    local now = time()
    for _, o in ipairs(list) do
        if o.title and o.title ~= "" then
            local rec = catalog[o.title]
            if not rec then
                rec = { firstSeen = now, seenCount = 0 }
                catalog[o.title] = rec
            end
            if type(rec.seenCount) ~= "number" then rec.seenCount = 0 end
            rec.questType = o.questType or 1
            rec.objectiveText = o.objectiveText or ""
            rec.questId = o.questId
            rec.normalSoulAshes = o.normalSoulAshes or 0
            rec.hc1SoulAshes = o.hc1SoulAshes or 0
            rec.hc2SoulAshes = o.hc2SoulAshes or 0
            rec.hc3SoulAshes = o.hc3SoulAshes or 0
            rec.hc4SoulAshes = o.hc4SoulAshes or 0
            rec.hc5SoulAshes = o.hc5SoulAshes or 0
            rec.normalXp = o.normalXp or 0
            rec.hc1Xp = o.hc1Xp or 0
            rec.hc2Xp = o.hc2Xp or 0
            rec.hc3Xp = o.hc3Xp or 0
            rec.hc4Xp = o.hc4Xp or 0
            rec.hc5Xp = o.hc5Xp or 0
            rec.lastSeen = now
            rec.seenCount = rec.seenCount + 1
        end
    end
end

-- Fires fn() after `sec` seconds. No C_Timer in 3.3.5a, so a small
-- self-destructing OnUpdate frame stands in for it.
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

-- Random pause before each select/reroll (default 0.20-0.70s, adjustable in
-- Settings or /callboard delay), so consecutive rolls don't fire at a
-- suspiciously identical, instant cadence.
local function RollDelay()
    local mn, mx = DB().delayMin, DB().delayMax
    if mx < mn then mx = mn end
    return mn + math.random() * (mx - mn)
end

local rerollCount = 0
local RefreshSettingsFrame -- forward-declared, assigned once the Settings sliders exist below

-- Verbose [trace] prints for every branch TrySelectOrReroll/the ticker take
-- -- off by default, toggle with /callboard trace on|off or the Settings
-- checkbox. The [error] lines from the ticker's pcall guards always print
-- regardless of this, since those are never just noise.
local DEBUG_TRACE = DB().debugTrace == true

local function SetDebugTrace(v)
    v = v and true or false
    DEBUG_TRACE = v
    DB().debugTrace = v
    Print("debug trace " .. (v and "ON" or "OFF"))
    if RefreshSettingsFrame then RefreshSettingsFrame() end
end

local function TrySelectOrReroll()
    if DEBUG_TRACE then Print("|cff888888[trace]|r TrySelectOrReroll called") end
    local pe = _G.ProjectEbonhold
    local svc = pe and pe.ObjectivesService
    if not svc then
        if DEBUG_TRACE then Print("|cff888888[trace]|r no svc, bailing") end
        return
    end

    -- Already have one locked in -- leave it alone. Reopening/closing the
    -- board with an active objective still set shouldn't re-trigger a
    -- select or reroll; that should only happen again once the active
    -- objective is cleared (completed/abandoned), same as the real board UI
    -- (which disables Select on everything else while one is active).
    if svc.GetActiveObjective and svc.GetActiveObjective() then
        if DEBUG_TRACE then Print("|cff888888[trace]|r active objective present, bailing") end
        return
    end

    local list = svc.GetCurrentObjectives()
    if type(list) ~= "table" or #list == 0 then
        if DEBUG_TRACE then Print("|cff888888[trace]|r list empty/invalid, bailing") end
        return
    end

    if DEBUG_TRACE then
        for i, o in ipairs(list) do
            local wanted, key = IsWanted(o)
            Print("|cff888888[trace]|r [" .. i .. "] \"" .. tostring(o.title) .. "\" wanted=" .. tostring(wanted) .. (key and (" via \"" .. key .. "\"") or ""))
        end
    end

    for i, o in ipairs(list) do
        if IsWanted(o) then
            -- REQUEST_SELECT_OBJECTIVE is 0-based (objectives_ui.lua builds it as
            -- i-1, confirmed against the real source) -- ipairs' i is 1-based.
            local idx, title = i - 1, o.title
            AfterDelay(RollDelay(), function()
                pe.sendToServer(pe.CS.REQUEST_SELECT_OBJECTIVE, tostring(idx))
                Print("|cff33ff66selected|r \"" .. tostring(title) .. "\"")
            end)
            rerollCount = 0
            return
        end
    end

    -- None of the 3 offered are a wanted material -- reroll, bounded by the safety cap.
    if DEBUG_TRACE then Print("|cff888888[trace]|r none wanted, rerollCount=" .. rerollCount .. " maxRerolls=" .. DB().maxRerolls) end
    if rerollCount >= DB().maxRerolls then
        Print("|cffff5555gave up|r after " .. DB().maxRerolls .. " rerolls, no wanted material was offered. (/callboard maxrerolls N to change the cap)")
        return
    end
    if svc.CanAffordReroll and not svc.CanAffordReroll() then
        Print("|cffff5555stopped|r -- can't afford the next reroll.")
        return
    end
    rerollCount = rerollCount + 1
    local n = rerollCount
    if DEBUG_TRACE then Print("|cff888888[trace]|r queuing reroll #" .. n .. " after a short delay") end
    AfterDelay(RollDelay(), function()
        Print("|cffffff00no wanted material offered|r, rerolling (" .. n .. "/" .. DB().maxRerolls .. ")...")
        svc.RequestRerollObjectives()
    end)
end

-- Scan mode -- deliberately spends real gold on N rerolls purely to build
-- the catalog faster, ignoring the whitelist entirely (never selects
-- anything). Confirmed the hard way that there's no free equivalent:
-- ProjectEbonhold.ObjectivesService.RequestObjectives() only re-syncs
-- whatever's already been rolled server-side, it doesn't generate a new
-- set -- only a real paid reroll does. Off by default, always an explicit
-- one-off action, cancellable mid-run. Recording still happens through the
-- normal ticker/RecordCatalog path once the new proposals arrive, so this
-- requires the Objectives board to actually be open.
local scanRemaining = 0
local scanSpentCopper = 0

local function ScanTick()
    if scanRemaining <= 0 then return end
    local pe = _G.ProjectEbonhold
    local svc = pe and pe.ObjectivesService
    if not svc then
        scanRemaining = 0
        return
    end

    if svc.CanAffordReroll and not svc.CanAffordReroll() then
        Print("|cffff5555scan stopped|r -- can't afford the next reroll. Spent " .. GetCoinTextureString(scanSpentCopper) .. " so far.")
        scanRemaining = 0
        return
    end

    scanSpentCopper = scanSpentCopper + (svc.GetRerollCost and svc.GetRerollCost() or 0)
    scanRemaining = scanRemaining - 1
    svc.RequestRerollObjectives()

    if scanRemaining > 0 then
        AfterDelay(RollDelay(), ScanTick)
    else
        Print("|cff33ff66scan complete|r. Spent " .. GetCoinTextureString(scanSpentCopper) .. " total building the catalog.")
    end
end

local function StartScan(n)
    n = tonumber(n)
    if not n or n <= 0 then
        Print("usage: /callboard scan <count> -- e.g. /callboard scan 20 (spends real gold, rerolling purely to discover new quests)")
        return
    end
    local pe = _G.ProjectEbonhold
    local svc = pe and pe.ObjectivesService
    if not svc then
        Print("ProjectEbonhold ObjectivesService not found.")
        return
    end
    if scanRemaining > 0 then
        Print("a scan is already running (" .. scanRemaining .. " left). /callboard scanstop to cancel it first.")
        return
    end
    scanRemaining = math.floor(n)
    scanSpentCopper = 0
    Print("|cffffff00scan started|r: " .. scanRemaining .. " rerolls to build the catalog (ignores your whitelist, spends real gold). Keep the Objectives board open. /callboard scanstop to cancel.")
    ScanTick()
end

local function StopScan()
    if scanRemaining <= 0 then
        Print("no scan running.")
        return
    end
    Print("|cffffff00scan cancelled|r after spending " .. GetCoinTextureString(scanSpentCopper) .. ".")
    scanRemaining = 0
end

-- Poll instead of hooking ProjectEbonhold.onEventReceived directly: that
-- table holds exactly ONE handler per opcode (ServerHandlers[id] = fn), and
-- objectives_service.lua already owns SEND_OBJECTIVES_PROPOSALS to refresh
-- the real board UI. Registering our own handler on the same opcode would
-- silently replace theirs and break the official Objectives window. Polling
-- GetCurrentObjectives() is non-invasive and mirrors how EchoBrain itself
-- detects board changes.
--
-- Cataloging (RecordCatalog) always runs when new proposals show up, even
-- with the addon disabled -- only the actual select/reroll behavior is
-- gated behind DB().enabled.
local browserWindow -- forward-declared, assigned once the Quest Browser frame exists below
local RefreshBrowserFrame -- forward-declared, assigned once the Quest Browser frame exists below
local lastSig, wasShown = nil, false
local ticker = CreateFrame("Frame")
local acc = 0
ticker:SetScript("OnUpdate", function(self, elapsed)
    acc = acc + elapsed
    if acc < 0.4 then return end
    acc = 0

    local frame = _G.ObjectivesMainFrame
    local shown = frame and frame:IsShown()
    if not shown then wasShown = false; return end

    local pe = _G.ProjectEbonhold
    local svc = pe and pe.ObjectivesService
    if not svc then return end
    local list = svc.GetCurrentObjectives()
    local sig = Signature(list)

    if not wasShown or sig ~= lastSig then
        wasShown = true
        lastSig = sig
        if DEBUG_TRACE then Print("|cff888888[trace]|r ticker: new sig \"" .. sig .. "\", enabled=" .. tostring(DB().enabled)) end

        -- Cataloging/Browser-refresh are non-critical -- pcall'd so an error
        -- there (surfaced instead of silently eaten) can never block the
        -- actual auto-select/reroll logic below.
        local okRC, errRC = pcall(RecordCatalog, list)
        if not okRC then Print("|cffff5555[error] RecordCatalog:|r " .. tostring(errRC)) end
        if browserWindow and browserWindow:IsShown() then
            local okBW, errBW = pcall(RefreshBrowserFrame)
            if not okBW then Print("|cffff5555[error] RefreshBrowserFrame:|r " .. tostring(errBW)) end
        end

        if DB().enabled then TrySelectOrReroll() end
    end
end)

-- Shared by the slash command and the minimap button so both stay in sync.
local UpdateMinimapIcon -- forward-declared, assigned once the button exists below
local ToggleBrowserFrame -- forward-declared, assigned once the Quest Browser frame exists below
local RefreshShareWindow -- forward-declared, assigned once the Share Whitelist window exists below
local function SetEnabled(v)
    DB().enabled = v and true or false
    rerollCount = 0
    if DB().enabled then
        -- Force a fresh evaluation on the next poll tick even if the board
        -- was already open with the same 3 proposals as last time this was
        -- turned off -- otherwise off->on while the board stays open (same
        -- signature, wasShown still true from before) silently does nothing.
        wasShown = false
    end
    if UpdateMinimapIcon then UpdateMinimapIcon() end
    Print(DB().enabled
        and ("enabled. Open the Objectives board and it'll auto-select/reroll for you (max " .. DB().maxRerolls .. " rerolls).")
        or "disabled.")
end

-- Shared by the Settings window and the slash command, same pattern as
-- SetEnabled -- one validate+apply+report path instead of two that could
-- silently diverge.
local function ApplyMaxRerolls(n)
    n = tonumber(n)
    if n and n >= 0 then
        DB().maxRerolls = math.floor(n)
        Print("max rerolls set to " .. DB().maxRerolls .. ".")
        if RefreshSettingsFrame then RefreshSettingsFrame() end
        return true
    end
    Print("invalid max rerolls -- need a non-negative number.")
    return false
end

local function ApplyDelayRange(mn, mx)
    mn, mx = tonumber(mn), tonumber(mx)
    if mn and mx and mn >= 0 and mx >= mn then
        DB().delayMin, DB().delayMax = mn, mx
        Print(string.format("reroll delay set to %.2f-%.2f sec.", mn, mx))
        if RefreshSettingsFrame then RefreshSettingsFrame() end
        return true
    end
    Print("invalid delay range -- need two numbers, min <= max.")
    return false
end

-- Shared by Settings and the slash command for managing the whitelist.
local function AddWhitelistEntry(text)
    text = tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if text == "" then
        Print("usage: /callboard add <text> -- e.g. /callboard add Thick Leather")
        return false
    end
    local whitelist = DB().whitelist
    local already = whitelist[text] ~= nil
    whitelist[text] = true
    Print((already and "|cff33ff66re-enabled|r \"" or "|cff33ff66added|r \"") .. text .. "\" to the whitelist.")

    -- Not a duplicate in any technical sense (different string keys), but if
    -- another enabled entry already matches this text, both will now match
    -- the same objectives -- worth a heads-up since two similarly-named
    -- entries otherwise look like a bug rather than an overlap.
    local covering = FindCoveringEntry(text, text)
    if covering then
        Print("|cffffff00note|r: \"" .. covering .. "\" is already enabled and already covers this -- both will work, you only need one.")
    end

    if browserWindow and browserWindow:IsShown() then RefreshBrowserFrame() end
    return true
end

local function RemoveWhitelistEntry(text)
    text = tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if text == "" then
        Print("usage: /callboard remove <text>")
        return false
    end
    local lower = string.lower(text)
    local whitelist = DB().whitelist
    for key in pairs(whitelist) do
        if string.lower(key) == lower then
            whitelist[key] = nil
            Print("|cffff5555removed|r \"" .. key .. "\" from the whitelist.")
            if browserWindow and browserWindow:IsShown() then RefreshBrowserFrame() end
            return true
        end
    end
    Print("\"" .. text .. "\" isn't on the whitelist.")
    return false
end

local function ListWhitelist()
    local whitelist = DB().whitelist
    local names = {}
    for name in pairs(whitelist) do names[#names + 1] = name end
    table.sort(names)
    if #names == 0 then
        Print("whitelist is empty -- /callboard add <text> to add something.")
        return
    end
    Print("whitelist (" .. #names .. "):")
    for _, name in ipairs(names) do
        Print((whitelist[name] and "  |cff33ff66[on]|r  " or "  |cffff5555[off]|r ") .. name)
    end
end

-- ------------------------------------------------------------
-- Named whitelist profiles (e.g. "world", "profession"), so switching what
-- kind of objectives you're hunting is one command instead of rebuilding
-- the whitelist from scratch every time.
-- ------------------------------------------------------------
-- Every destructive profile operation below (save-over-an-existing-name,
-- load, delete) goes through a StaticPopupDialogs confirmation first --
-- native Blizzard confirm dialog, matching this addon's existing
-- plain-native-Blizzard philosophy (see ProfileDropdown_Initialize's own
-- comment on the same point) instead of a custom-built popup. Confirmed
-- once here means every trigger path (slash command, minimap
-- shift-click dropdown, Share window buttons) is protected the same way --
-- none of those call sites need their own confirmation logic.
StaticPopupDialogs["CALLBOARDHELPER_PROFILE_OVERWRITE"] = {
    text = "A profile named \"%s\" already exists.\nOverwrite it with your current whitelist?",
    button1 = "Overwrite",
    button2 = "Cancel",
    OnAccept = function(self, data) data.fn(data.name) end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

StaticPopupDialogs["CALLBOARDHELPER_PROFILE_LOAD"] = {
    text = "Load profile \"%s\"?\nThis replaces your current whitelist (%d entries).",
    button1 = "Load",
    button2 = "Cancel",
    OnAccept = function(self, data) data.fn(data.name) end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

StaticPopupDialogs["CALLBOARDHELPER_PROFILE_DELETE"] = {
    text = "Delete profile \"%s\"?\nThis cannot be undone.",
    button1 = "Delete",
    button2 = "Cancel",
    OnAccept = function(self, data) data.fn(data.name) end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

local function SaveWhitelistProfileNow(name)
    local snapshot = {}
    for key, enabled in pairs(DB().whitelist) do
        snapshot[key] = enabled
    end
    DB().profiles[name] = snapshot
    local n = 0
    for _ in pairs(snapshot) do n = n + 1 end
    Print("|cff33ff66profile saved|r: \"" .. name .. "\" (" .. n .. " whitelist entries).")
    if RefreshShareWindow then RefreshShareWindow() end
end

local function SaveWhitelistProfile(name)
    name = string.lower(tostring(name or ""):gsub("^%s+", ""):gsub("%s+$", ""))
    if name == "" then
        Print("usage: /callboard profile save <name>")
        return
    end
    if DB().profiles[name] then
        StaticPopup_Show("CALLBOARDHELPER_PROFILE_OVERWRITE", name, nil, { name = name, fn = SaveWhitelistProfileNow })
        return
    end
    SaveWhitelistProfileNow(name)
end

local function LoadWhitelistProfileNow(name)
    local snapshot = DB().profiles[name]
    local whitelist = {}
    for key, enabled in pairs(snapshot) do
        whitelist[key] = enabled
    end
    DB().whitelist = whitelist
    if browserWindow and browserWindow:IsShown() then RefreshBrowserFrame() end
    if RefreshSettingsFrame then RefreshSettingsFrame() end
    local n = 0
    for _ in pairs(whitelist) do n = n + 1 end
    Print("|cff33ff66profile loaded|r: \"" .. name .. "\" (" .. n .. " whitelist entries).")
end

local function LoadWhitelistProfile(name)
    name = string.lower(tostring(name or ""):gsub("^%s+", ""):gsub("%s+$", ""))
    if not DB().profiles[name] then
        Print("no profile named \"" .. name .. "\". /callboard profile list to see saved ones.")
        return
    end
    local currentCount = 0
    for _ in pairs(DB().whitelist) do currentCount = currentCount + 1 end
    StaticPopup_Show("CALLBOARDHELPER_PROFILE_LOAD", name, currentCount, { name = name, fn = LoadWhitelistProfileNow })
end

local function DeleteWhitelistProfileNow(name)
    DB().profiles[name] = nil
    Print("|cffff5555profile deleted|r: \"" .. name .. "\".")
    if RefreshShareWindow then RefreshShareWindow() end
end

local function DeleteWhitelistProfile(name)
    name = string.lower(tostring(name or ""):gsub("^%s+", ""):gsub("%s+$", ""))
    if not DB().profiles[name] then
        Print("no profile named \"" .. name .. "\".")
        return
    end
    StaticPopup_Show("CALLBOARDHELPER_PROFILE_DELETE", name, nil, { name = name, fn = DeleteWhitelistProfileNow })
end

local function ListWhitelistProfiles()
    local names = {}
    for name in pairs(DB().profiles) do names[#names + 1] = name end
    table.sort(names)
    if #names == 0 then
        Print("no whitelist profiles saved yet -- /callboard profile save <name>.")
        return
    end
    Print("whitelist profiles (" .. #names .. "): " .. table.concat(names, ", "))
end

-- ------------------------------------------------------------
-- Profile dropdown -- native Blizzard UIDropDownMenu (already loaded by
-- FrameXML, no LoadAddOn needed), opened by shift-clicking the minimap
-- button. Kept as the stock menu widget instead of a custom popup to match
-- this addon's plain-native-Blizzard reskin philosophy elsewhere.
-- ------------------------------------------------------------
local function ProfileDropdown_Initialize(self, level)
    local names = {}
    for name in pairs(DB().profiles) do names[#names + 1] = name end
    table.sort(names)

    local title = UIDropDownMenu_CreateInfo()
    title.text = self.mode == "delete" and "Delete Profile" or "Load Profile"
    title.isTitle = true
    title.notCheckable = true
    UIDropDownMenu_AddButton(title, level)

    if #names == 0 then
        local info = UIDropDownMenu_CreateInfo()
        info.text = "(none saved)"
        info.disabled = true
        info.notCheckable = true
        UIDropDownMenu_AddButton(info, level)
        return
    end

    for _, name in ipairs(names) do
        local info = UIDropDownMenu_CreateInfo()
        info.text = name
        info.notCheckable = true
        if self.mode == "delete" then
            info.func = function() DeleteWhitelistProfile(name) end
        else
            info.func = function() LoadWhitelistProfile(name) end
        end
        UIDropDownMenu_AddButton(info, level)
    end
end

local profileDropdown = CreateFrame("Frame", "CallBoardHelperProfileDropdown", UIParent, "UIDropDownMenuTemplate")
UIDropDownMenu_Initialize(profileDropdown, ProfileDropdown_Initialize, "MENU")

local function ShowProfileDropdown(anchor, forDelete)
    profileDropdown.mode = forDelete and "delete" or "load"
    ToggleDropDownMenu(1, nil, profileDropdown, anchor, 0, 0)
end

-- ------------------------------------------------------------
-- Whitelist import/export -- portable text format, same idea as
-- CheckpointFavorites' "CPF1:" build string. Entries are arbitrary quest
-- title strings (not a fixed count of numeric IDs), so they're newline-
-- joined instead of comma-joined before Base64 encoding.
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
    local names = {}
    for name, enabled in pairs(DB().whitelist) do
        if enabled == true then names[#names + 1] = name end
    end
    table.sort(names)
    return "EHW1:" .. Base64Encode(table.concat(names, "\n"))
end

-- Parses/validates an EHW1 string with NO side effects -- callers decide
-- whether/when to actually apply it (the Share window confirms the
-- overwrite first; see CALLBOARDHELPER_IMPORT_OVERWRITE below).
local function ParseWhitelistImport(text)
    text = tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local payload = text:match("^EHW1:(.+)$")
    if not payload then
        return false, "Invalid whitelist string. Expected EHW1:..."
    end

    local ok, decoded = pcall(Base64Decode, payload)
    if not ok or not decoded then
        return false, "Could not decode whitelist string."
    end

    local whitelist = {}
    local n = 0
    for line in decoded:gmatch("[^\n]+") do
        whitelist[line] = true
        n = n + 1
    end
    return true, whitelist, n
end

-- Replaces the whole whitelist (same "load" semantics as a profile), not a
-- merge -- the actual overwrite, called only after the Share window's
-- confirmation popup is accepted.
local function ApplyImportedWhitelist(whitelist)
    DB().whitelist = whitelist
    if browserWindow and browserWindow:IsShown() then RefreshBrowserFrame() end
    if RefreshSettingsFrame then RefreshSettingsFrame() end
end

StaticPopupDialogs["CALLBOARDHELPER_IMPORT_OVERWRITE"] = {
    text = "Import %d whitelist entries?\nThis replaces your current whitelist (%d entries).",
    button1 = "Import",
    button2 = "Cancel",
    OnAccept = function(self, data)
        ApplyImportedWhitelist(data.whitelist)
        Print("|cff33ff66whitelist imported|r (" .. data.count .. " entries).")
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

-- ------------------------------------------------------------
-- Settings window. Opened via right-click on the minimap button.
-- ------------------------------------------------------------
local sf = CreateFrame("Frame", "CallBoardHelperSettingsFrame", UIParent)
sf:SetWidth(340); sf:SetHeight(316)
-- Default position computed to not overlap the Quest Browser (see below),
-- but a hardcoded default can never account for every OTHER addon's own
-- windows -- e.g. CheckpointFavorites' main window also happens to sit
-- near here by default. So the position you drag it to is remembered
-- (DB().settingsPos) and takes over permanently -- move it once, anywhere
-- that's clear on your screen, and it stays there across reloads.
if DB().settingsPos then
    sf:SetPoint(DB().settingsPos[1], UIParent, DB().settingsPos[2], DB().settingsPos[3], DB().settingsPos[4])
else
    sf:SetPoint("CENTER", UIParent, "CENTER", SETTINGS_DEFAULT_X, SETTINGS_DEFAULT_Y)
end
sf:SetFrameStrata("DIALOG")
-- Native Blizzard dialog look (the same tan-stone texture/border used by
-- StaticPopup confirmations and most stock panels) -- no custom color tint,
-- so it reads as a normal WoW window instead of a themed skin.
sf:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true, tileSize = 32, edgeSize = 32,
    insets = { left = 11, right = 12, top = 12, bottom = 11 }
})
sf:SetMovable(true); sf:EnableMouse(true); sf:RegisterForDrag("LeftButton")
sf:SetToplevel(true) -- click it and it jumps in front of the Browser, no need to care where either is positioned
sf:SetScript("OnDragStart", function() sf:StartMoving() end)
sf:SetScript("OnDragStop", function()
    sf:StopMovingOrSizing()
    local point, _, relPoint, x, y = sf:GetPoint()
    DB().settingsPos = { point, relPoint, x, y }
end)
sf:Hide()

local sfClose = CreateFrame("Button", nil, sf, "UIPanelCloseButton")
sfClose:SetPoint("TOPRIGHT", 2, 2)

local sfTitle = sf:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
sfTitle:SetPoint("TOP", sf, "TOP", 0, -16)
sfTitle:SetText("Call Board Helper")

local sfCheck = CreateFrame("CheckButton", nil, sf, "UICheckButtonTemplate")
sfCheck:SetPoint("TOPLEFT", 24, -50)
sfCheck:SetWidth(24); sfCheck:SetHeight(24)
local sfCheckLabel = sf:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
sfCheckLabel:SetPoint("LEFT", sfCheck, "RIGHT", 4, 1)
sfCheckLabel:SetText("Enabled")
sfCheck:SetScript("OnClick", function(self) SetEnabled(self:GetChecked() and true or false) end)

local sfBrowseBtn = CreateFrame("Button", nil, sf, "UIPanelButtonTemplate")
sfBrowseBtn:SetWidth(110); sfBrowseBtn:SetHeight(22)
sfBrowseBtn:SetPoint("TOPRIGHT", -20, -48)
sfBrowseBtn:SetText("Browse Quests")
sfBrowseBtn:SetScript("OnClick", function() if ToggleBrowserFrame then ToggleBrowserFrame() end end)

-- Sliders instead of free-typed numbers -- bounded, dragged not typed, so
-- there's no way to end up with something like "999" sitting in a text box.
-- The slash command path (/callboard maxrerolls|delay) stays uncapped for
-- anyone who deliberately wants a value outside the slider's range; the
-- text label always shows the true DB() value even if that's the case, the
-- slider thumb just does its best to represent it.
local sfMaxSlider = CreateFrame("Slider", "CallBoardHelperMaxRerollsSlider", sf, "OptionsSliderTemplate")
sfMaxSlider:SetPoint("TOPLEFT", 32, -98)
sfMaxSlider:SetWidth(270); sfMaxSlider:SetHeight(16)
sfMaxSlider:SetMinMaxValues(0, 50)
sfMaxSlider:SetValueStep(1)
_G["CallBoardHelperMaxRerollsSliderLow"]:SetText("0")
_G["CallBoardHelperMaxRerollsSliderHigh"]:SetText("50")

local sfDelayMinSlider = CreateFrame("Slider", "CallBoardHelperDelayMinSlider", sf, "OptionsSliderTemplate")
sfDelayMinSlider:SetPoint("TOPLEFT", 32, -148)
sfDelayMinSlider:SetWidth(270); sfDelayMinSlider:SetHeight(16)
sfDelayMinSlider:SetMinMaxValues(0, 2)
sfDelayMinSlider:SetValueStep(0.05)
_G["CallBoardHelperDelayMinSliderLow"]:SetText("0")
_G["CallBoardHelperDelayMinSliderHigh"]:SetText("2")

local sfDelayMaxSlider = CreateFrame("Slider", "CallBoardHelperDelayMaxSlider", sf, "OptionsSliderTemplate")
sfDelayMaxSlider:SetPoint("TOPLEFT", 32, -193)
sfDelayMaxSlider:SetWidth(270); sfDelayMaxSlider:SetHeight(16)
sfDelayMaxSlider:SetMinMaxValues(0, 2)
sfDelayMaxSlider:SetValueStep(0.05)
_G["CallBoardHelperDelayMaxSliderLow"]:SetText("0")
_G["CallBoardHelperDelayMaxSliderHigh"]:SetText("2")

local suppressSliderEvents = false

sfMaxSlider:SetScript("OnValueChanged", function(self, value)
    if suppressSliderEvents then return end
    value = math.floor(value + 0.5)
    DB().maxRerolls = value
    _G["CallBoardHelperMaxRerollsSliderText"]:SetText("Max rerolls per board-open: " .. value)
end)

sfDelayMinSlider:SetScript("OnValueChanged", function(self, value)
    if suppressSliderEvents then return end
    value = math.floor(value / 0.05 + 0.5) * 0.05
    if value > DB().delayMax then
        sfDelayMaxSlider:SetValue(value) -- fires the Max slider's own handler, keeps it in sync
    end
    DB().delayMin = value
    _G["CallBoardHelperDelayMinSliderText"]:SetText(string.format("Reroll delay min: %.2fs", value))
end)

sfDelayMaxSlider:SetScript("OnValueChanged", function(self, value)
    if suppressSliderEvents then return end
    value = math.floor(value / 0.05 + 0.5) * 0.05
    if value < DB().delayMin then
        sfDelayMinSlider:SetValue(value) -- fires the Min slider's own handler, keeps it in sync
    end
    DB().delayMax = value
    _G["CallBoardHelperDelayMaxSliderText"]:SetText(string.format("Reroll delay max: %.2fs", value))
end)

local sfDebugCheck = CreateFrame("CheckButton", nil, sf, "UICheckButtonTemplate")
sfDebugCheck:SetPoint("TOPLEFT", 24, -214)
sfDebugCheck:SetWidth(18); sfDebugCheck:SetHeight(18)
local sfDebugLabel = sf:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
sfDebugLabel:SetPoint("LEFT", sfDebugCheck, "RIGHT", 4, 1)
sfDebugLabel:SetText("Debug Trace (verbose chat prints)")
sfDebugCheck:SetScript("OnClick", function(self) SetDebugTrace(self:GetChecked() and true or false) end)

local sep = sf:CreateTexture(nil, "ARTWORK")
sep:SetTexture("Interface\\Tooltips\\UI-Tooltip-Background")
sep:SetPoint("TOPLEFT", 20, -240)
sep:SetPoint("TOPRIGHT", -20, -240)
sep:SetHeight(1)
sep:SetVertexColor(0.95, 0.72, 0.16, 0.55)

-- The whitelist itself is managed entirely in the Quest Browser now (it
-- covers manually /callboard add'ed entries too, not just discovered ones) --
-- this window stays a small, fixed-size settings panel instead of a list
-- that has to keep resizing itself around a growing checkbox grid.
local sfHint = sf:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
sfHint:SetPoint("TOPLEFT", 24, -252)
sfHint:SetPoint("TOPRIGHT", -24, -252)
sfHint:SetJustifyH("CENTER")
sfHint:SetWordWrap(true)
sfHint:SetText("Manage your whitelist in the Quest Browser above.\nAlso: /callboard add|remove|list")

RefreshSettingsFrame = function()
    sfCheck:SetChecked(DB().enabled)
    sfDebugCheck:SetChecked(DB().debugTrace)

    suppressSliderEvents = true
    sfMaxSlider:SetValue(math.min(DB().maxRerolls, 50))
    sfDelayMinSlider:SetValue(DB().delayMin)
    sfDelayMaxSlider:SetValue(DB().delayMax)
    suppressSliderEvents = false

    -- Always show the TRUE stored value, even if it's outside the slider's
    -- range (e.g. set via /callboard maxrerolls 999) -- the slider thumb is
    -- just a best-effort visual, the label is authoritative.
    _G["CallBoardHelperMaxRerollsSliderText"]:SetText("Max rerolls per board-open: " .. DB().maxRerolls)
    _G["CallBoardHelperDelayMinSliderText"]:SetText(string.format("Reroll delay min: %.2fs", DB().delayMin))
    _G["CallBoardHelperDelayMaxSliderText"]:SetText(string.format("Reroll delay max: %.2fs", DB().delayMax))
end
sf:SetScript("OnShow", RefreshSettingsFrame)

-- ------------------------------------------------------------
-- Quest Browser -- styled and laid out to match CheckpointFavorites' own
-- Browser window (dark charcoal/gold theme, search box, a single cycling
-- "Show:" category button + count, zebra-striped rows, Prev/Next paging)
-- so this addon's windows feel consistent with the others already
-- installed, rather than a generic Blizzard scroll list.
-- ------------------------------------------------------------
-- 18 rows @ 20px fits noticeably more of a typical catalog per page than
-- the old 12 @ 22px did (was paging at just 17 quests) without the window
-- feeling cramped -- tightened, not just shrunk (row content/fonts are
-- unchanged, only the fixed vertical padding around them is trimmed).
local QB_ROW_COUNT = 18
local QB_ROW_HEIGHT = 20
local QB_ROWS_TOP = 122
-- Zebra striping / quest-type accent colors -- the header comment above
-- has claimed "zebra-striped rows" as a design goal since this window was
-- built, but no row ever actually got a background texture; this was
-- genuinely never implemented, not a stale comment about removed code.
local QB_STRIPE_COLOR = { 1, 1, 1, 0.035 }
local QB_KIND_COLOR = {
    [1] = { 0.78, 0.78, 0.65 }, -- Open World -- neutral tan, matches the dialog's own palette
    [2] = { 0.55, 0.75, 1.0 },  -- Dungeon -- blue, matches the dungeon-difficulty icon color Blizzard uses
    [3] = { 1.0, 0.45, 0.45 },  -- Raid -- red, matches Blizzard's raid-difficulty color
    [4] = { 0.55, 0.90, 0.55 }, -- Profession -- green, matches tradeskill window accents
}
local qbFiltered = {}
local qbScrollOffset = 0
local qbCategoryMode = "ALL"

local QB_CATEGORY_CYCLE = { ALL = "OPENWORLD", OPENWORLD = "DUNGEON", DUNGEON = "RAID", RAID = "PROFESSION", PROFESSION = "ALL" }
local QB_CATEGORY_LABEL = { ALL = "All", OPENWORLD = "Open World", DUNGEON = "Dungeon", RAID = "Raid", PROFESSION = "Profession" }
local QB_CATEGORY_TYPE = { OPENWORLD = 1, DUNGEON = 2, RAID = 3, PROFESSION = 4 }

local function QBMatchesCategory(questType)
    if qbCategoryMode == "ALL" then return true end
    return questType == QB_CATEGORY_TYPE[qbCategoryMode]
end

local function QBSearchText()
    return string.lower(browserWindow and browserWindow.search:GetText() or "")
end

local function RebuildBrowseFilter()
    qbFiltered = {}
    local q = QBSearchText()
    for title, data in pairs(DB().catalog) do
        local qt = data.questType or 1
        if QBMatchesCategory(qt) and (q == "" or string.find(string.lower(title), q, 1, true)) then
            table.insert(qbFiltered, {
                title = title, questType = qt, objectiveText = data.objectiveText,
                questId = data.questId, seenCount = data.seenCount,
            })
        end
    end
    table.sort(qbFiltered, function(a, b) return string.lower(a.title) < string.lower(b.title) end)
    qbScrollOffset = math.min(qbScrollOffset, math.max(0, #qbFiltered - QB_ROW_COUNT))
end

RefreshBrowserFrame = function()
    if not browserWindow then return end
    RebuildBrowseFilter()

    browserWindow.categoryBtn:SetText("Show: " .. QB_CATEGORY_LABEL[qbCategoryMode])
    browserWindow.countText:SetText(#qbFiltered .. " quests")

    local whitelist = DB().whitelist
    for i = 1, QB_ROW_COUNT do
        local row = browserWindow.rows[i]
        local data = qbFiltered[qbScrollOffset + i]
        if data then
            row.title = data.title
            row.objectiveText = data.objectiveText
            row.seenCount = data.seenCount
            local whitelisted = whitelist[data.title] == true
            row.name:SetText(data.title)
            row.name:SetTextColor(whitelisted and 1 or 0.6, whitelisted and 1 or 0.6, whitelisted and 1 or 0.6)
            row.kind:SetText(QuestTypeName(data.questType))
            local kindColor = QB_KIND_COLOR[data.questType or 1] or QB_KIND_COLOR[1]
            row.kind:SetTextColor(kindColor[1], kindColor[2], kindColor[3])
            row.id:SetText(data.questId and ("#" .. tostring(data.questId)) or "")
            row.check:SetChecked(whitelisted)
            row:Show()
        else
            row.title = nil
            row.objectiveText = nil
            row:Hide()
        end
    end

    local totalPages = math.max(1, math.ceil(#qbFiltered / QB_ROW_COUNT))
    local page = math.floor(qbScrollOffset / QB_ROW_COUNT) + 1
    browserWindow.pageText:SetText("Page " .. page .. " / " .. totalPages)
end

local function CreateBrowserFrame()
    browserWindow = CreateFrame("Frame", "CallBoardHelperBrowserFrame", UIParent)
    browserWindow:SetWidth(560); browserWindow:SetHeight(QB_ROWS_TOP + QB_ROW_COUNT * QB_ROW_HEIGHT + 63)
    -- Default position computed to not overlap Settings, but same caveat as
    -- Settings itself: a hardcoded spot can collide with some OTHER addon's
    -- window too (as it did with CheckpointFavorites' own main window).
    -- Remembers wherever you drag it (DB().browserPos) from then on.
    if DB().browserPos then
        browserWindow:SetPoint(DB().browserPos[1], UIParent, DB().browserPos[2], DB().browserPos[3], DB().browserPos[4])
    else
        browserWindow:SetPoint("CENTER", UIParent, "CENTER", BROWSER_DEFAULT_X, BROWSER_DEFAULT_Y)
    end
    browserWindow:SetFrameStrata("DIALOG")
    browserWindow:SetMovable(true)
    browserWindow:EnableMouse(true)
    browserWindow:RegisterForDrag("LeftButton")
    browserWindow:SetToplevel(true) -- click it and it jumps in front of Settings
    browserWindow:SetClampedToScreen(true)
    browserWindow:Hide()

    -- Native Blizzard dialog look (same tan-stone texture/border as
    -- Settings and the Export/Log windows) -- no custom color tint.
    browserWindow:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 }
    })
    browserWindow:SetScript("OnDragStart", function(self) self:StartMoving() end)
    browserWindow:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, relPoint, x, y = self:GetPoint()
        DB().browserPos = { point, relPoint, x, y }
    end)

    local title = browserWindow:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 18, -14)
    title:SetText("Quest Browser")

    local subtitle = browserWindow:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    subtitle:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -3)
    subtitle:SetText("Check = whitelisted   \183   Search by title")

    local close = CreateFrame("Button", nil, browserWindow, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -5, -5)

    local divider = browserWindow:CreateTexture(nil, "ARTWORK")
    divider:SetHeight(1)
    divider:SetPoint("TOPLEFT", 14, -50)
    divider:SetPoint("TOPRIGHT", -14, -50)
    divider:SetTexture(0.55, 0.45, 0.28, 0.7)

    local search = CreateFrame("EditBox", "CallBoardHelperBrowserSearch", browserWindow, "InputBoxTemplate")
    search:SetSize(230, 22)
    search:SetPoint("TOPLEFT", 24, -62)
    search:SetAutoFocus(false)
    search:SetTextInsets(4, 4, 0, 0)
    search:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    search:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    browserWindow.search = search

    local searchGhost = browserWindow:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    searchGhost:SetPoint("LEFT", search, "LEFT", 6, 0)
    searchGhost:SetText("Search title...")
    search:SetScript("OnTextChanged", function(self)
        -- Not SetShown - this client (3.3.5a) doesn't have it at all, on
        -- any widget type (found live via EchoTracker's own crash on the
        -- identical pattern). Show()/Hide() work everywhere.
        if (self:GetText() or "") == "" then
            searchGhost:Show()
        else
            searchGhost:Hide()
        end
        qbScrollOffset = 0
        RefreshBrowserFrame()
    end)

    local categoryBtn = CreateFrame("Button", nil, browserWindow, "UIPanelButtonTemplate")
    categoryBtn:SetSize(150, 22)
    categoryBtn:SetNormalFontObject("GameFontNormalSmall")
    categoryBtn:SetHighlightFontObject("GameFontHighlightSmall")
    categoryBtn:SetPoint("TOPLEFT", search, "BOTTOMLEFT", 0, -10)
    categoryBtn:SetScript("OnClick", function()
        qbCategoryMode = QB_CATEGORY_CYCLE[qbCategoryMode]
        qbScrollOffset = 0
        RefreshBrowserFrame()
    end)
    browserWindow.categoryBtn = categoryBtn

    local countText = browserWindow:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    countText:SetPoint("LEFT", categoryBtn, "RIGHT", 12, 0)
    browserWindow.countText = countText

    browserWindow.rows = {}
    for i = 1, QB_ROW_COUNT do
        local row = CreateFrame("Button", nil, browserWindow)
        row:SetSize(516, QB_ROW_HEIGHT)
        row:SetPoint("TOPLEFT", 22, -QB_ROWS_TOP - (i - 1) * QB_ROW_HEIGHT)

        -- Native quest-log hover highlight, plus an actual zebra stripe on
        -- the even rows now (very faint -- just enough to read row
        -- boundaries at a glance across a dense 18-row list, not a themed
        -- background fill).
        row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
        if i % 2 == 0 then
            local stripe = row:CreateTexture(nil, "BACKGROUND")
            stripe:SetAllPoints(row)
            stripe:SetTexture(unpack(QB_STRIPE_COLOR))
        end

        row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.name:SetPoint("LEFT", 7, 0)
        row.name:SetWidth(300)
        row.name:SetJustifyH("LEFT")
        if row.name.SetWordWrap then row.name:SetWordWrap(false) end

        row.kind = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        row.kind:SetPoint("LEFT", 310, 0)
        row.kind:SetWidth(90)
        row.kind:SetJustifyH("LEFT")

        row.id = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        row.id:SetPoint("RIGHT", -30, 0)
        row.id:SetWidth(55)
        row.id:SetJustifyH("RIGHT")

        row.check = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
        row.check:SetSize(20, 20)
        row.check:SetPoint("RIGHT", 0, 0)
        row.check:SetScript("OnClick", function(self)
            if not row.title then return end
            if self:GetChecked() then AddWhitelistEntry(row.title)
            else RemoveWhitelistEntry(row.title) end
        end)

        row:SetScript("OnEnter", function(self)
            if not row.title then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine(row.title, 1, 1, 1)
            if row.objectiveText and row.objectiveText ~= "" then
                GameTooltip:AddLine(row.objectiveText, 0.8, 0.8, 0.8, true)
            end
            if row.seenCount then
                GameTooltip:AddLine("Seen " .. row.seenCount .. "x", 0.6, 0.6, 0.6)
            end
            local covering = FindCoveringEntry(row.title, row.title)
            if covering then
                GameTooltip:AddLine("Already auto-picked via \"" .. covering .. "\"", 0.6, 1, 0.6)
            end
            GameTooltip:AddLine("Check to add to whitelist, uncheck to remove", 0.6, 0.6, 0.6)
            GameTooltip:Show()
        end)
        row:SetScript("OnLeave", function() GameTooltip:Hide() end)

        browserWindow.rows[i] = row
    end

    local backBtn = CreateFrame("Button", nil, browserWindow, "UIPanelButtonTemplate")
    backBtn:SetSize(78, 25)
    backBtn:SetPoint("BOTTOMLEFT", 22, 14)
    backBtn:SetText("Back")
    backBtn:SetScript("OnClick", function()
        browserWindow:Hide()
        sf:Show()
    end)

    local prevBtn = CreateFrame("Button", nil, browserWindow, "UIPanelButtonTemplate")
    prevBtn:SetSize(78, 25)
    prevBtn:SetPoint("LEFT", backBtn, "RIGHT", 7, 0)
    prevBtn:SetText("< Prev")
    prevBtn:SetScript("OnClick", function()
        qbScrollOffset = math.max(0, qbScrollOffset - QB_ROW_COUNT)
        RefreshBrowserFrame()
    end)

    local nextBtn = CreateFrame("Button", nil, browserWindow, "UIPanelButtonTemplate")
    nextBtn:SetSize(78, 25)
    nextBtn:SetPoint("LEFT", prevBtn, "RIGHT", 7, 0)
    nextBtn:SetText("Next >")
    nextBtn:SetScript("OnClick", function()
        if qbScrollOffset + QB_ROW_COUNT < #qbFiltered then
            qbScrollOffset = qbScrollOffset + QB_ROW_COUNT
            RefreshBrowserFrame()
        end
    end)

    local pageText = browserWindow:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    pageText:SetPoint("LEFT", nextBtn, "RIGHT", 12, 0)
    browserWindow.pageText = pageText
end
CreateBrowserFrame()

-- Escape hatch: if either window ever ends up somewhere awkward (behind
-- another addon's frame, dragged off-screen, etc.), this clears the
-- remembered position and puts both back at their computed defaults.
local function ResetWindowPositions()
    DB().settingsPos = nil
    DB().browserPos = nil
    sf:ClearAllPoints()
    sf:SetPoint("CENTER", UIParent, "CENTER", SETTINGS_DEFAULT_X, SETTINGS_DEFAULT_Y)
    browserWindow:ClearAllPoints()
    browserWindow:SetPoint("CENTER", UIParent, "CENTER", BROWSER_DEFAULT_X, BROWSER_DEFAULT_Y)
    Print("window positions reset.")
end

ToggleBrowserFrame = function()
    if not browserWindow then return end
    if browserWindow:IsShown() then
        browserWindow:Hide()
    else
        sf:Hide() -- only one of our own windows open at a time -- can't overlap what isn't shown
        RefreshBrowserFrame()
        browserWindow:Show()
    end
end

-- ------------------------------------------------------------
-- CSV export -- WoW addons can't write files to disk, so "export" means a
-- selectable text box: click in, Ctrl+A, Ctrl+C, then paste into a .csv
-- file yourself. Exports the full catalog (everything ever seen on the
-- board, not just whitelisted entries), with a Whitelisted column so you
-- can tell which is which afterward.
-- ------------------------------------------------------------
local function CsvEscape(s)
    s = tostring(s or "")
    if s:find('[,"\n]') then
        s = '"' .. s:gsub('"', '""') .. '"'
    end
    return s
end

local function BuildCatalogCSV()
    local lines = {
        "Title,QuestId,QuestType,QuestTypeName,ObjectiveText,Whitelisted,SeenCount,FirstSeen,LastSeen,"
        .. "NormalSoulAshes,HC1SoulAshes,HC2SoulAshes,HC3SoulAshes,HC4SoulAshes,HC5SoulAshes,"
        .. "NormalXp,HC1Xp,HC2Xp,HC3Xp,HC4Xp,HC5Xp"
    }
    local catalog = DB().catalog
    local whitelist = DB().whitelist
    local titles = {}
    for title in pairs(catalog) do titles[#titles + 1] = title end
    table.sort(titles, function(a, b) return string.lower(a) < string.lower(b) end)
    for _, title in ipairs(titles) do
        local data = catalog[title]
        local qt = data.questType or 1
        local qtName = QuestTypeName(qt)
        lines[#lines + 1] = table.concat({
            CsvEscape(title),
            tostring(data.questId or 0),
            tostring(qt),
            CsvEscape(qtName),
            CsvEscape(data.objectiveText),
            whitelist[title] == true and "1" or "0",
            tostring(data.seenCount or 0),
            tostring(data.firstSeen or 0),
            tostring(data.lastSeen or 0),
            tostring(data.normalSoulAshes or 0),
            tostring(data.hc1SoulAshes or 0),
            tostring(data.hc2SoulAshes or 0),
            tostring(data.hc3SoulAshes or 0),
            tostring(data.hc4SoulAshes or 0),
            tostring(data.hc5SoulAshes or 0),
            tostring(data.normalXp or 0),
            tostring(data.hc1Xp or 0),
            tostring(data.hc2Xp or 0),
            tostring(data.hc3Xp or 0),
            tostring(data.hc4Xp or 0),
            tostring(data.hc5Xp or 0),
        }, ",")
    end
    return table.concat(lines, "\n")
end

local exportWindow
local function CreateExportFrame()
    exportWindow = CreateFrame("Frame", "CallBoardHelperExportFrame", UIParent)
    exportWindow:SetWidth(520); exportWindow:SetHeight(420)
    exportWindow:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    exportWindow:SetFrameStrata("FULLSCREEN_DIALOG")
    exportWindow:SetMovable(true)
    exportWindow:EnableMouse(true)
    exportWindow:RegisterForDrag("LeftButton")
    exportWindow:SetToplevel(true)
    exportWindow:SetClampedToScreen(true)
    exportWindow:Hide()
    exportWindow:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 }
    })
    exportWindow:SetScript("OnDragStart", function(self) self:StartMoving() end)
    exportWindow:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)

    local title = exportWindow:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -16)
    title:SetText("Export Catalog (CSV)")

    local close = CreateFrame("Button", nil, exportWindow, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -5, -5)

    local scroll = CreateFrame("ScrollFrame", "CallBoardHelperExportScroll", exportWindow, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 20, -46)
    scroll:SetPoint("BOTTOMRIGHT", -34, 44)

    local editBox = CreateFrame("EditBox", nil, scroll)
    editBox:SetMultiLine(true)
    editBox:SetFontObject(ChatFontNormal)
    editBox:SetWidth(430)
    editBox:SetAutoFocus(false)
    editBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    scroll:SetScrollChild(editBox)
    exportWindow.editBox = editBox

    local hint = exportWindow:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    hint:SetPoint("BOTTOM", 0, 16)
    hint:SetWidth(480)
    hint:SetJustifyH("CENTER")
    hint:SetText("Click inside, Ctrl+A to select all, Ctrl+C to copy -- then paste into a .csv file.")
end
CreateExportFrame()

local function ShowExportWindow()
    exportWindow.editBox:SetText(BuildCatalogCSV())
    exportWindow.editBox:SetFocus()
    exportWindow.editBox:HighlightText()
    exportWindow:Show()
end

-- ------------------------------------------------------------
-- Log viewer -- same copyable-text-box pattern as the CSV export, showing
-- every Print() this session (see DB().log). The real persisted copy only
-- reaches disk at /reload or logout (SavedVariables behavior); this window
-- always shows what's in memory right now, live.
-- ------------------------------------------------------------
local logWindow
local function CreateLogFrame()
    logWindow = CreateFrame("Frame", "CallBoardHelperLogFrame", UIParent)
    logWindow:SetWidth(560); logWindow:SetHeight(420)
    logWindow:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    logWindow:SetFrameStrata("FULLSCREEN_DIALOG")
    logWindow:SetMovable(true)
    logWindow:EnableMouse(true)
    logWindow:RegisterForDrag("LeftButton")
    logWindow:SetToplevel(true)
    logWindow:SetClampedToScreen(true)
    logWindow:Hide()
    logWindow:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 }
    })
    logWindow:SetScript("OnDragStart", function(self) self:StartMoving() end)
    logWindow:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)

    local title = logWindow:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -16)
    title:SetText("Call Board Helper Log")

    local close = CreateFrame("Button", nil, logWindow, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -5, -5)

    local scroll = CreateFrame("ScrollFrame", "CallBoardHelperLogScroll", logWindow, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 20, -46)
    scroll:SetPoint("BOTTOMRIGHT", -34, 44)

    local editBox = CreateFrame("EditBox", nil, scroll)
    editBox:SetMultiLine(true)
    editBox:SetFontObject(ChatFontNormal)
    editBox:SetWidth(430)
    editBox:SetAutoFocus(false)
    editBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    scroll:SetScrollChild(editBox)
    logWindow.editBox = editBox

    local hint = logWindow:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    hint:SetPoint("BOTTOM", 0, 16)
    hint:SetWidth(480)
    hint:SetJustifyH("CENTER")
    hint:SetText("Click inside, Ctrl+A, Ctrl+C to copy. Also written to disk at /reload: WTF\\Account\\<account>\\SavedVariables\\CallBoardHelper.lua")
end
CreateLogFrame()

local function ShowLogWindow()
    logWindow.editBox:SetText(table.concat(DB().log, "\n"))
    logWindow.editBox:SetFocus()
    logWindow.editBox:HighlightText()
    logWindow:Show()
end

-- ------------------------------------------------------------
-- Share Whitelist window -- portable EHW1 export/import string plus the
-- named-profile UI, opened from the Quest Browser since that's where the
-- whitelist itself already lives (moved out of Settings for that reason).
-- Mirrors CheckpointFavorites' own "Share Favorites" window.
-- ------------------------------------------------------------
local shareWindow
-- Fixed header section (title through the profile name/Save row) is this
-- tall; the row list below it is the only part that grows/shrinks, based on
-- how many profiles are actually saved (usually 1-3), instead of a fixed
-- window height that reserves blank space for rows nobody has yet.
local SHARE_ROWS_TOP = 168
local SHARE_ROW_H = 19
local SHARE_MAX_ROWS = 10
local SHARE_BOTTOM_MARGIN = 14

local function CreateShareFrame()
    shareWindow = CreateFrame("Frame", "CallBoardHelperShareFrame", UIParent)
    shareWindow:SetWidth(400); shareWindow:SetHeight(240)
    shareWindow:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    shareWindow:SetFrameStrata("FULLSCREEN_DIALOG")
    shareWindow:SetMovable(true)
    shareWindow:EnableMouse(true)
    shareWindow:RegisterForDrag("LeftButton")
    shareWindow:SetToplevel(true)
    shareWindow:SetClampedToScreen(true)
    shareWindow:Hide()
    shareWindow:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 }
    })
    shareWindow:SetScript("OnDragStart", function(self) self:StartMoving() end)
    shareWindow:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)

    local title = shareWindow:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -14)
    title:SetText("Share Whitelist")

    local close = CreateFrame("Button", nil, shareWindow, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -4, -4)

    local help = shareWindow:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    help:SetPoint("TOPLEFT", 18, -38)
    help:SetPoint("TOPRIGHT", -18, -38)
    help:SetJustifyH("LEFT")
    help:SetText("Copy to save/share -- paste another EHW1 string to import")

    local edit = CreateFrame("EditBox", "CallBoardHelperShareEdit", shareWindow, "InputBoxTemplate")
    edit:SetPoint("TOPLEFT", 22, -54)
    edit:SetPoint("TOPRIGHT", -22, -54)
    edit:SetHeight(24)
    edit:SetAutoFocus(false)
    edit:SetTextInsets(5, 5, 0, 0)
    edit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    edit:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)

    -- 3 equal-width buttons filling the same span as the edit box above.
    local btnW = 106
    local exportBtn = CreateFrame("Button", nil, shareWindow, "UIPanelButtonTemplate")
    exportBtn:SetWidth(btnW); exportBtn:SetHeight(21)
    exportBtn:SetPoint("TOPLEFT", 22, -82)
    exportBtn:SetText("Export")
    exportBtn:SetScript("OnClick", function()
        edit:SetText(ExportWhitelist())
        edit:SetFocus()
        edit:HighlightText()
    end)

    local importBtn = CreateFrame("Button", nil, shareWindow, "UIPanelButtonTemplate")
    importBtn:SetWidth(btnW); importBtn:SetHeight(21)
    importBtn:SetPoint("LEFT", exportBtn, "RIGHT", 6, 0)
    importBtn:SetText("Import")
    importBtn:SetScript("OnClick", function()
        local ok, whitelistOrErr, count = ParseWhitelistImport(edit:GetText())
        if not ok then
            Print("|cffff5555" .. whitelistOrErr .. "|r")
            return
        end
        edit:ClearFocus()
        local currentCount = 0
        for _ in pairs(DB().whitelist) do currentCount = currentCount + 1 end
        StaticPopup_Show("CALLBOARDHELPER_IMPORT_OVERWRITE", count, currentCount, { whitelist = whitelistOrErr, count = count })
    end)

    local selectBtn = CreateFrame("Button", nil, shareWindow, "UIPanelButtonTemplate")
    selectBtn:SetWidth(btnW); selectBtn:SetHeight(21)
    selectBtn:SetPoint("LEFT", importBtn, "RIGHT", 6, 0)
    selectBtn:SetText("Select All")
    selectBtn:SetScript("OnClick", function()
        edit:SetFocus()
        edit:HighlightText()
    end)

    local sep = shareWindow:CreateTexture(nil, "ARTWORK")
    sep:SetTexture("Interface\\Tooltips\\UI-Tooltip-Background")
    sep:SetPoint("TOPLEFT", 18, -110)
    sep:SetPoint("TOPRIGHT", -18, -110)
    sep:SetHeight(1)
    sep:SetVertexColor(0.95, 0.72, 0.16, 0.55)

    local profileLabel = shareWindow:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    profileLabel:SetPoint("TOPLEFT", 22, -118)
    profileLabel:SetText("Whitelist Profiles")

    local nameEdit = CreateFrame("EditBox", "CallBoardHelperShareProfileEdit", shareWindow, "InputBoxTemplate")
    nameEdit:SetPoint("TOPLEFT", 22, -136)
    nameEdit:SetWidth(150); nameEdit:SetHeight(20)
    nameEdit:SetAutoFocus(false)
    nameEdit:SetMaxLetters(32)
    nameEdit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

    local saveBtn = CreateFrame("Button", nil, shareWindow, "UIPanelButtonTemplate")
    saveBtn:SetWidth(btnW); saveBtn:SetHeight(20)
    saveBtn:SetPoint("LEFT", nameEdit, "RIGHT", 6, 0)
    saveBtn:SetText("Save As")
    saveBtn:SetScript("OnClick", function()
        local text = nameEdit:GetText()
        if text and text ~= "" then
            SaveWhitelistProfile(text) -- resizes/refreshes this window itself via RefreshShareWindow
            nameEdit:SetText("")
            nameEdit:ClearFocus()
        end
    end)
    nameEdit:SetScript("OnEnterPressed", function(self) self:ClearFocus(); saveBtn:Click() end)

    local emptyText = shareWindow:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    emptyText:SetPoint("TOPLEFT", 22, -SHARE_ROWS_TOP)
    emptyText:SetText("No profiles saved yet.")

    local rows = {}
    for i = 1, SHARE_MAX_ROWS do
        local row = CreateFrame("Frame", nil, shareWindow)
        row:SetWidth(356); row:SetHeight(SHARE_ROW_H)
        row:SetPoint("TOPLEFT", 22, -SHARE_ROWS_TOP - (i - 1) * SHARE_ROW_H)
        if i % 2 == 0 then
            local stripe = row:CreateTexture(nil, "BACKGROUND")
            stripe:SetAllPoints(row)
            stripe:SetTexture(unpack(QB_STRIPE_COLOR))
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
        -- Red text, same convention Blizzard's own delete-confirmation
        -- buttons use elsewhere -- a visual cue that this one's destructive
        -- (now backed by the confirmation popup added this session), not
        -- just another equal-weight action next to Load.
        row.deleteBtn:GetFontString():SetTextColor(1, 0.35, 0.35)

        row:Hide()
        rows[i] = row
    end

    local moreHint = shareWindow:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    moreHint:Hide()

    RefreshShareWindow = function()
        local names = {}
        for name in pairs(DB().profiles) do names[#names + 1] = name end
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

        -- Window only grows as tall as it needs to fit what's actually
        -- shown: at least one "row slot" (occupied by either a real row or
        -- the empty-state text), plus one more line if the overflow hint
        -- is needed.
        local shownRows = math.max(1, math.min(#names, SHARE_MAX_ROWS))
        local overflow = #names > SHARE_MAX_ROWS
        if overflow then
            moreHint:ClearAllPoints()
            moreHint:SetPoint("TOPLEFT", 22, -SHARE_ROWS_TOP - shownRows * SHARE_ROW_H - 2)
            moreHint:SetText("+" .. (#names - SHARE_MAX_ROWS) .. " more -- /callboard profile list")
            moreHint:Show()
        else
            moreHint:Hide()
        end

        shareWindow:SetHeight(SHARE_ROWS_TOP + shownRows * SHARE_ROW_H
            + (overflow and (SHARE_ROW_H + 2) or 0) + SHARE_BOTTOM_MARGIN)
    end
end
CreateShareFrame()

local function ShowShareWindow()
    RefreshShareWindow()
    shareWindow:Show()
end

local browserExportBtn = CreateFrame("Button", nil, browserWindow, "UIPanelButtonTemplate")
browserExportBtn:SetWidth(100); browserExportBtn:SetHeight(25)
browserExportBtn:SetPoint("BOTTOMRIGHT", -22, 14)
browserExportBtn:SetText("Export CSV")
browserExportBtn:SetScript("OnClick", ShowExportWindow)

local browserShareBtn = CreateFrame("Button", nil, browserWindow, "UIPanelButtonTemplate")
browserShareBtn:SetWidth(100); browserShareBtn:SetHeight(25)
browserShareBtn:SetPoint("BOTTOMRIGHT", browserExportBtn, "TOPRIGHT", 0, 6)
browserShareBtn:SetText("Share")
browserShareBtn:SetScript("OnClick", ShowShareWindow)
browserShareBtn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText("Share Whitelist")
    GameTooltip:AddLine("Export/import a portable EHW1 string, or manage named whitelist profiles.", 0.8, 0.8, 0.8, true)
    GameTooltip:Show()
end)
browserShareBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

-- ------------------------------------------------------------
-- Minimap button -- same drag-around-the-minimap pattern EchoBrain uses.
-- Left-click toggles on/off; the icon dims while off so status is visible
-- at a glance without opening a tooltip. Right-click opens Settings.
-- ------------------------------------------------------------
local mm = CreateFrame("Button", "CallBoardHelperMinimapButton", Minimap)
mm:SetWidth(32); mm:SetHeight(32)
mm:SetFrameStrata("MEDIUM")
mm:SetFrameLevel(8)
mm:RegisterForClicks("LeftButtonUp", "RightButtonUp")
mm:RegisterForDrag("LeftButton")
mm:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

local mmBorder = mm:CreateTexture(nil, "OVERLAY")
mmBorder:SetWidth(54); mmBorder:SetHeight(54)
mmBorder:SetPoint("TOPLEFT", 0, 0)
mmBorder:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")

local mmIcon = mm:CreateTexture(nil, "BACKGROUND")
mmIcon:SetWidth(20); mmIcon:SetHeight(20)
mmIcon:SetPoint("CENTER", 1, 1)
mmIcon:SetTexture("Interface\\Icons\\INV_Elemental_Primal_Water")
mmIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

UpdateMinimapIcon = function()
    if DB().enabled then mmIcon:SetVertexColor(1, 1, 1)
    else mmIcon:SetVertexColor(0.45, 0.45, 0.45) end
end

local function PlaceMinimapButton(angle)
    angle = tonumber(angle) or 200
    DB().minimapAngle = angle
    local rad = math.rad(angle)
    local radius = 80
    mm:ClearAllPoints()
    mm:SetPoint("CENTER", Minimap, "CENTER", math.cos(rad) * radius, math.sin(rad) * radius)
end

local function CursorAngle()
    local mx, my = Minimap:GetCenter()
    local scale = Minimap:GetEffectiveScale()
    local x, y = GetCursorPosition()
    x = x / scale; y = y / scale
    return math.deg(math.atan2(y - my, x - mx))
end

mm:SetScript("OnDragStart", function(self)
    self:SetScript("OnUpdate", function() PlaceMinimapButton(CursorAngle()) end)
end)
mm:SetScript("OnDragStop", function(self)
    self:SetScript("OnUpdate", nil)
end)

mm:SetScript("OnClick", function(self, button)
    if IsShiftKeyDown() then
        -- Shift-click = quick profile switch, no need to open Settings at all.
        ShowProfileDropdown(self, button == "RightButton")
        return
    end
    if button == "RightButton" then
        if sf:IsShown() then
            sf:Hide()
        else
            if browserWindow then browserWindow:Hide() end -- only one of our own windows open at a time
            sf:Show()
        end
    else
        SetEnabled(not DB().enabled)
    end
end)

mm:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:AddLine("Call Board Helper", 1, 0.82, 0)
    GameTooltip:AddLine(DB().enabled and "|cff33ff66ON|r" or "|cffff5555OFF|r", 1, 1, 1)
    GameTooltip:AddLine("Max rerolls: " .. DB().maxRerolls, 0.8, 0.8, 0.8)
    GameTooltip:AddLine(string.format("Reroll delay: %.2f-%.2fs", DB().delayMin, DB().delayMax), 0.8, 0.8, 0.8)
    GameTooltip:AddLine("Left-click: toggle on/off", 0.7, 0.7, 0.7)
    GameTooltip:AddLine("Right-click: Settings", 0.7, 0.7, 0.7)
    GameTooltip:AddLine("Shift+Left-click: load a whitelist profile", 0.7, 0.7, 0.7)
    GameTooltip:AddLine("Shift+Right-click: delete a whitelist profile", 0.7, 0.7, 0.7)
    GameTooltip:AddLine("Drag: move around minimap", 0.7, 0.7, 0.7)
    GameTooltip:Show()
end)
mm:SetScript("OnLeave", function() GameTooltip:Hide() end)

local mmInit = CreateFrame("Frame")
mmInit:RegisterEvent("PLAYER_LOGIN")
mmInit:SetScript("OnEvent", function()
    PlaceMinimapButton(DB().minimapAngle or 200)
    UpdateMinimapIcon()
end)

SLASH_CALLBOARDHELPER1 = "/callboard"
SlashCmdList.CALLBOARDHELPER = function(msg)
    -- Only the command word is case-folded here -- `arg` keeps whatever
    -- casing you typed, since add/remove display and store it as-is.
    msg = string.gsub(tostring(msg or ""), "^%s+", "")
    local cmd, arg = msg:match("^(%S*)%s*(.-)$")
    cmd = string.lower(cmd or "")
    if cmd == "on" then
        SetEnabled(true)
    elseif cmd == "off" then
        SetEnabled(false)
    elseif cmd == "maxrerolls" then
        if not ApplyMaxRerolls(arg) then Print("usage: /callboard maxrerolls <number>") end
    elseif cmd == "delay" then
        local mn, mx = arg:match("^([%d%.]+)%s+([%d%.]+)$")
        if not ApplyDelayRange(mn, mx) then
            Print("usage: /callboard delay <min> <max>  (e.g. /callboard delay 0.20 0.70)")
        end
    elseif cmd == "add" then
        AddWhitelistEntry(arg)
    elseif cmd == "remove" or cmd == "rm" then
        RemoveWhitelistEntry(arg)
    elseif cmd == "list" then
        ListWhitelist()
    elseif cmd == "profile" then
        local sub, subarg = arg:match("^(%S*)%s*(.-)$")
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
            Print("usage: /callboard profile save|load|delete <name>  or  /callboard profile list")
        end
    elseif cmd == "browse" then
        if ToggleBrowserFrame then ToggleBrowserFrame() end
    elseif cmd == "export" then
        ShowExportWindow()
    elseif cmd == "resetpos" then
        ResetWindowPositions()
    elseif cmd == "scan" then
        StartScan(arg)
    elseif cmd == "scanstop" then
        StopScan()
    elseif cmd == "debug" then
        local frame = _G.ObjectivesMainFrame
        Print("ObjectivesMainFrame exists: " .. tostring(frame ~= nil) .. ", shown: " .. tostring(frame and frame:IsShown()))
        local pe = _G.ProjectEbonhold
        local svc = pe and pe.ObjectivesService
        Print("ProjectEbonhold found: " .. tostring(pe ~= nil) .. ", ObjectivesService found: " .. tostring(svc ~= nil))
        if svc then
            local list = svc.GetCurrentObjectives()
            Print("GetCurrentObjectives() type: " .. type(list) .. ", count: " .. tostring(type(list) == "table" and #list or "n/a"))
            if type(list) == "table" then
                for i, o in ipairs(list) do
                    Print("  [" .. i .. "] " .. tostring(o.title) .. " (questId " .. tostring(o.questId) .. ", type " .. tostring(o.questType) .. ")")
                end
            end
            local active = svc.GetActiveObjective and svc.GetActiveObjective()
            Print("GetActiveObjective(): " .. tostring(active) .. (active and active.title and (" -- \"" .. tostring(active.title) .. "\"") or ""))
        end
        Print("enabled: " .. tostring(DB().enabled) .. ", lastSig: " .. tostring(lastSig) .. ", wasShown: " .. tostring(wasShown))
    elseif cmd == "log" then
        ShowLogWindow()
    elseif cmd == "logclear" then
        DB().log = {}
        Print("log cleared.")
    elseif cmd == "trace" then
        local v = string.lower(arg or "")
        if v == "on" then SetDebugTrace(true)
        elseif v == "off" then SetDebugTrace(false)
        else Print("debug trace is " .. (DEBUG_TRACE and "ON" or "OFF") .. ". Usage: /callboard trace on|off") end
    else
        Print(DB().enabled and "currently ON" or "currently OFF (default -- this spends gold automatically once on)")
        Print("/callboard on | off")
        Print("/callboard add <text> | remove <text> | list -- manage the whitelist")
        Print("/callboard profile save|load|delete <name> | profile list -- named whitelist sets (e.g. world vs profession)")
        Print("/callboard browse -- open the Quest Browser (everything seen on the board, by type)")
        Print("/callboard export -- open a copyable CSV export of everything discovered")
        Print("/callboard trace on|off -- verbose debug prints for select/reroll decisions")
        Print("/callboard log | logclear -- view or clear the persisted log (also saved to disk at /reload)")
        Print("/callboard resetpos -- reset both window positions if one ends up stuck somewhere odd")
        Print("/callboard scan <count> | scanstop -- spend gold rerolling purely to discover new quests faster")
        Print("/callboard maxrerolls <number> -- current cap: " .. DB().maxRerolls)
        Print(string.format("/callboard delay <min> <max> -- current range: %.2f-%.2f sec", DB().delayMin, DB().delayMax))
    end
end
