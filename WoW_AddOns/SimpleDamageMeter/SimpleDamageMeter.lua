-- Simple personal damage meter (WoW 3.3.5a). Tracks only the player's own
-- damage: current DPS, total damage, and the last 10 fights.
--
-- Controls: left-drag to move, right-click to reset the current meter.
-- /sdm            show last 10 fights
-- /sdm reset      reset the current meter
-- /sdm clear      clear fight history
-- /dps on|off     enable/disable tracking and hide/show the frame
--
-- Optional DataBridge integration: if DataBridge is loaded, live DPS/damage
-- and each completed fight are pushed out via DataBridge_Send so external
-- tools can see them through wow_bridge's API. Fully standalone otherwise -
-- every DataBridge_Send call is guarded, nothing breaks without it.

SimpleDamageMeterDB = SimpleDamageMeterDB or {}
SimpleDamageMeterDB.history = SimpleDamageMeterDB.history or {}
if SimpleDamageMeterDB.enabled == nil then
    SimpleDamageMeterDB.enabled = true
end

local function ReportToBridge(key, value)
    if type(DataBridge_Send) == "function" then
        DataBridge_Send(key, value)
    end
end

--------------------------------------------------------------------------
-- Frame
--------------------------------------------------------------------------

local frame = CreateFrame("Frame", "SimpleDamageMeter", UIParent)
frame:SetWidth(180)
frame:SetHeight(30)
frame:SetPoint("LEFT", UIParent, "LEFT", 10, 0)
frame:SetMovable(true)
frame:EnableMouse(true)
frame:RegisterForDrag("LeftButton")
frame:SetClampedToScreen(true)

frame:SetBackdrop({
    bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true,
    tileSize = 16,
    edgeSize = 8,
    insets = {left = 2, right = 2, top = 2, bottom = 2},
})
frame:SetBackdropColor(0, 0, 0, 0.8)
if not SimpleDamageMeterDB.enabled then
    frame:Hide()
end

local text = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
text:SetPoint("CENTER", frame, "CENTER", 0, 0)
text:SetText("DPS: 0 | DMG: 0")

--------------------------------------------------------------------------
-- Combat state
--------------------------------------------------------------------------

local totalDamage = 0
local combatStartTime = nil
local inCombat = false

local function ShortNumber(n)
    if not n then
        return "0"
    end
    if n >= 1000000000 then
        return string.format("%.1fb", n / 1000000000)
    elseif n >= 1000000 then
        return string.format("%.1fm", n / 1000000)
    elseif n >= 1000 then
        return string.format("%.1fk", n / 1000)
    end
    return tostring(math.floor(n))
end

local function GetCurrentDPS()
    if not combatStartTime or totalDamage <= 0 then
        return 0
    end
    local duration = math.max(GetTime() - combatStartTime, 1)
    return totalDamage / duration
end

local function UpdateDisplay()
    local dps = GetCurrentDPS()
    text:SetText(string.format("DPS: %s | DMG: %s", ShortNumber(dps), ShortNumber(totalDamage)))
    -- No ReportToBridge here on purpose: this runs on EVERY damage log
    -- event during combat (many per second), which used to spam the bridge
    -- (and its console) with a dps_current/dps_damage report per hit for no
    -- consumer - nothing reads either key (only dps_last_fight, sent once
    -- per completed fight below, is ever used - see SaveFight and
    -- echo_autopilot.py's fight logging). Local on-screen text still
    -- updates live; only the bridge report is now end-of-fight only.
end

local function ResetMeter()
    totalDamage = 0
    combatStartTime = inCombat and GetTime() or nil
    UpdateDisplay()
end

local function SaveFight()
    if not combatStartTime or totalDamage <= 0 then
        return
    end
    local duration = math.max(GetTime() - combatStartTime, 1)
    local dps = totalDamage / duration
    local fight = {
        damage = totalDamage,
        dps = dps,
        duration = duration,
        time = date("%H:%M:%S"),
        date = date("%d/%m/%Y"),
    }
    table.insert(SimpleDamageMeterDB.history, 1, fight)
    while #SimpleDamageMeterDB.history > 10 do
        table.remove(SimpleDamageMeterDB.history)
    end
    ReportToBridge("dps_last_fight", string.format(
        "dmg=%d dps=%d duration=%.1fs", totalDamage, dps, duration
    ))
end

local function StartFight()
    totalDamage = 0
    combatStartTime = GetTime()
    inCombat = true
    UpdateDisplay()
end

local function FinishFight()
    if not inCombat then
        return
    end
    inCombat = false
    SaveFight()
    UpdateDisplay() -- keep the result visible until the next fight
end

--------------------------------------------------------------------------
-- Mouse
--------------------------------------------------------------------------

frame:SetScript("OnDragStart", function(self)
    self:StartMoving()
end)

frame:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
end)

frame:SetScript("OnMouseUp", function(self, button)
    if button == "RightButton" then
        ResetMeter()
    end
end)

--------------------------------------------------------------------------
-- Combat log
--------------------------------------------------------------------------

frame:RegisterEvent("PLAYER_REGEN_DISABLED")
frame:RegisterEvent("PLAYER_REGEN_ENABLED")
frame:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")

-- select() index for the damage-amount arg differs by sub-event: melee swings
-- put it at arg 9 (no spell-info block ahead of it), spell/DoT/ranged/shield
-- events put it at arg 12 (spellId/spellName/spellSchool precede it).
local DAMAGE_ARG_INDEX = {
    SWING_DAMAGE = 9,
    SPELL_DAMAGE = 12,
    SPELL_PERIODIC_DAMAGE = 12,
    RANGE_DAMAGE = 12,
    DAMAGE_SHIELD = 12,
}

frame:SetScript("OnEvent", function(self, event, ...)
    if not SimpleDamageMeterDB.enabled then
        return
    end
    if event == "PLAYER_REGEN_DISABLED" then
        StartFight()
        return
    end
    if event == "PLAYER_REGEN_ENABLED" then
        FinishFight()
        return
    end
    if event ~= "COMBAT_LOG_EVENT_UNFILTERED" then
        return
    end

    local _, subEvent, sourceGUID = ...
    if sourceGUID ~= UnitGUID("player") then
        return -- only the player's own damage, no pet/party/raid
    end

    local argIndex = DAMAGE_ARG_INDEX[subEvent]
    if not argIndex then
        return
    end
    local amount = select(argIndex, ...)
    if not amount or amount <= 0 then
        return
    end

    if not combatStartTime then
        combatStartTime = GetTime()
    end
    totalDamage = totalDamage + amount
    UpdateDisplay()
end)

--------------------------------------------------------------------------
-- Slash command
--------------------------------------------------------------------------

SLASH_SIMPLEDAMAGEMETERTOGGLE1 = "/dps"
SlashCmdList.SIMPLEDAMAGEMETERTOGGLE = function(msg)
    msg = string.lower(msg or ""):gsub("^%s*(.-)%s*$", "%1")
    if msg == "on" then
        SimpleDamageMeterDB.enabled = true
        frame:Show()
        print("|cffffcc00Simple Damage Meter:|r ON")
    elseif msg == "off" then
        SimpleDamageMeterDB.enabled = false
        frame:Hide()
        print("|cffffcc00Simple Damage Meter:|r OFF")
    else
        print("usage: /dps on|off (currently " .. (SimpleDamageMeterDB.enabled and "on" or "off") .. ")")
    end
end

SLASH_SIMPLEDAMAGEMETER1 = "/sdm"
SlashCmdList.SIMPLEDAMAGEMETER = function(msg)
    msg = string.lower(msg or ""):gsub("^%s*(.-)%s*$", "%1")

    if msg == "clear" then
        SimpleDamageMeterDB.history = {}
        print("|cffffcc00Simple Damage Meter:|r history cleared.")
        return
    end
    if msg == "reset" then
        ResetMeter()
        print("|cffffcc00Simple Damage Meter:|r current meter reset.")
        return
    end

    print("|cffffcc00Simple Damage Meter - Last 10 fights|r")
    if #SimpleDamageMeterDB.history == 0 then
        print("|cffaaaaaaNo fights recorded yet.|r")
        return
    end
    for i, fight in ipairs(SimpleDamageMeterDB.history) do
        print(string.format(
            "|cffffffff#%d|r  DPS: |cff00ff00%s|r  DMG: |cffffcc00%s|r  Duration: %.1fs  |cff888888[%s]|r",
            i, ShortNumber(fight.dps), ShortNumber(fight.damage), fight.duration or 0, fight.time or "?"
        ))
    end
end
