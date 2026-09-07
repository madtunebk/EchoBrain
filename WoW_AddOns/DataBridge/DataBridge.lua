local ADDON_NAME = ...
local PREFIX = "RUSTDATA"
local frame = CreateFrame("Frame")
local pollElapsed = 0
local displayFrame
local displayText

-- Outbound addon-message batching + rate limiter. Any addon built on top of
-- this bridge can end up queuing many keys in one frame; sending one whisper
-- per key floods the server's anti-spam and risks a disconnect. Each
-- throttle tick packs as many queued DATA pairs as fit in one 230-byte
-- message (joined by GROUP_SEP) instead of draining one key per message -
-- this is what actually cuts message count, the throttle interval below is
-- just a backstop against any residual burst (e.g. several oversized values
-- that can't be packed together).
local GROUP_SEP = string.char(29) -- ASCII Group Separator; not used in any value
local outboundQueue = {} -- { kind="DATA", key=, value= } or { kind="RAW", payload= }
local sendElapsed = 0
local SEND_INTERVAL = 0.15 -- ~6.7 addon whispers/sec; deliberately conservative
local MAX_QUEUE = 160

DataBridgeInbox = DataBridgeInbox or {}

local function Print(message)
    DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffDataBridge:|r " .. message)
end

-- Routine traffic (every send/receive) is already visible in wow_bridge's own
-- console ([api], [addon-data]/[addon-data->api] lines), so it's silenced in
-- the game chat by default. Errors always print regardless of this flag.
local function DebugPrint(message)
    if DataBridgeDB and DataBridgeDB.debug then
        Print(message)
    end
end

local function EnsureDisplay()
    if displayFrame then
        return
    end
    displayFrame = CreateFrame("Frame", nil, UIParent)
    displayFrame:SetWidth(300)
    displayFrame:SetHeight(60)
    displayFrame:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", -30, -120)

    local background = displayFrame:CreateTexture(nil, "BACKGROUND")
    background:SetAllPoints(displayFrame)
    background:SetTexture(0.05, 0.05, 0.05, 0.9)

    displayText = displayFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    displayText:SetPoint("CENTER", displayFrame, "CENTER", 0, 0)
    displayText:SetText(DataBridgeInbox.proxy_test or "waiting for API...")
    displayFrame:Show()
end

local function UpdateDisplay(key, value)
    if key ~= "proxy_test" then
        return
    end
    EnsureDisplay()
    displayText:SetText(value)
end

-- Always whisper the player's own character. There is no separate bot
-- character listening anymore - wow_bridge is a MITM relay that watches this
-- same self-whisper as it passes through on its way to the real server, so
-- self-targeting is both correct and the only thing that still makes sense.
local function RawSend(payload)
    local target = UnitName("player")
    SendAddonMessage(PREFIX, payload, "WHISPER", target)
    DebugPrint("sent to " .. target .. ": " .. payload)
end

local function QueueData(key, value)
    for i = #outboundQueue, 1, -1 do
        local entry = outboundQueue[i]
        if entry.kind == "DATA" and entry.key == key then
            entry.value = value
            return
        end
    end
    if #outboundQueue >= MAX_QUEUE then
        -- Prefer freshness over an ever-growing backlog. With coalescing this
        -- should only happen under pathological spam.
        table.remove(outboundQueue, 1)
    end
    table.insert(outboundQueue, {kind = "DATA", key = key, value = value})
end

local function QueueRaw(payload)
    if #outboundQueue >= MAX_QUEUE then
        table.remove(outboundQueue, 1)
    end
    table.insert(outboundQueue, {kind = "RAW", payload = payload})
end

local function Send(payload)
    payload = tostring(payload or "")
    if #payload > 230 then
        Print("payload too long (maximum 230 bytes)")
        return
    end
    QueueRaw(payload)
end

-- Pops one message worth of queued traffic off the front of outboundQueue:
-- a RAW entry (e.g. TEXT|...) is sent alone as before; a run of consecutive
-- DATA entries is packed into a single "DATA|k1=v1<GS>k2=v2..." message, as
-- many as fit under the 230-byte cap.
local function PackNextMessage()
    if #outboundQueue == 0 then
        return nil
    end
    if outboundQueue[1].kind == "RAW" then
        return table.remove(outboundQueue, 1).payload
    end

    local pieces = {}
    local length = 5 -- "DATA|"
    local count = 0
    for i = 1, #outboundQueue do
        local entry = outboundQueue[i]
        if entry.kind ~= "DATA" then
            break
        end
        local piece = entry.key .. "=" .. entry.value
        local addition = (count == 0) and #piece or (1 + #piece)
        if length + addition > 230 then
            break
        end
        length = length + addition
        count = count + 1
        table.insert(pieces, piece)
    end

    if count == 0 then
        -- A single DATA piece alone exceeds the cap. DataBridge_Send already
        -- rejects oversized values up front, so this should be unreachable;
        -- drop it rather than wedge the queue forever.
        table.remove(outboundQueue, 1)
        return nil
    end
    for _ = 1, count do
        table.remove(outboundQueue, 1)
    end
    return "DATA|" .. table.concat(pieces, GROUP_SEP)
end

-- Public API for other addons built on top of this bridge:
-- DataBridge_Send("my_key", someValue)
function DataBridge_Send(key, value)
    key = tostring(key or "value"):gsub("[|\t\r\n]", "_"):gsub(GROUP_SEP, "_")
    value = tostring(value or ""):gsub("[\t\r\n]", " "):gsub(GROUP_SEP, " ")
    if #key + 1 + #value > 220 then
        Print("value too long for " .. key .. " (dropped)")
        return
    end
    QueueData(key, value)
end

-- Lets a caller self-throttle a bulk send (e.g. EchoTracker's one-shot
-- description export) against MAX_QUEUE instead of flooding outboundQueue
-- past its cap and silently losing whatever gets evicted from the front.
function DataBridge_QueueLength()
    return #outboundQueue
end

-- Public API for any value too big for one DataBridge_Send call (a
-- whitelist, an equip loadout, an echo catalog): DataBridge_SendLarge
-- ("baseKey", {"part1","part2",...}, sep) splits `parts` into as many
-- sep-joined chunks (";" default) as fit under DataBridge_Send's own
-- ~220-byte cap, sent as baseKey_1, baseKey_2, ... plus baseKey_count so a
-- reader on the other end knows how many chunks to fetch and re-join with
-- the same separator - never splits a single part across two chunks.
-- Pulled up here after EchoTracker.lua and WhitelistLiquidator.lua both
-- independently grew (and had to debug) their own private copy of this
-- exact loop - one implementation instead of one per addon.
local SENDLARGE_CHUNK_LIMIT = 200

local function BuildLargeChunks(parts, sep)
    sep = sep or ";"
    local chunks = {}
    local current = ""
    for _, part in ipairs(parts) do
        local candidate = (current == "") and part or (current .. sep .. part)
        if #candidate > SENDLARGE_CHUNK_LIMIT and current ~= "" then
            table.insert(chunks, current)
            current = part
        else
            current = candidate
        end
    end
    if current ~= "" or #chunks == 0 then
        table.insert(chunks, current)
    end
    return chunks
end

function DataBridge_SendLarge(baseKey, parts, sep)
    local chunks = BuildLargeChunks(parts, sep)
    for i, chunk in ipairs(chunks) do
        DataBridge_Send(baseKey .. "_" .. i, chunk)
    end
    DataBridge_Send(baseKey .. "_count", #chunks)
end

function DataBridge_ShowTexture(relativePath, width, height, seconds)
    if not DataBridgeTextureFrame then
        DataBridgeTextureFrame = CreateFrame("Frame", nil, UIParent)
        DataBridgeTextureFrame:SetWidth(256)
        DataBridgeTextureFrame:SetHeight(256)
        DataBridgeTextureFrame:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 30, -120)
        DataBridgeTexture = DataBridgeTextureFrame:CreateTexture(nil, "OVERLAY")
        DataBridgeTexture:SetAllPoints(DataBridgeTextureFrame)
        DataBridgeTextureFrame:SetScript("OnUpdate", function(self, elapsed)
            if not self.clearAfter then
                return
            end
            self.clearAfter = self.clearAfter - elapsed
            if self.clearAfter <= 0 then
                self.clearAfter = nil
                DataBridgeTexture:SetTexture(nil)
                self:Hide()
            end
        end)
    end
    DataBridgeTextureFrame:SetWidth(width or 256)
    DataBridgeTextureFrame:SetHeight(height or width or 256)
    local path = "Interface\\AddOns\\DataBridge\\" .. relativePath
    -- Clear the old reference first when the same named TGA was overwritten.
    DataBridgeTexture:SetTexture(nil)
    DataBridgeTexture:SetTexture(path)
    seconds = tonumber(seconds) or 10
    if seconds > 0 then
        DataBridgeTextureFrame.clearAfter = seconds
    else
        DataBridgeTextureFrame.clearAfter = nil
    end
    DataBridgeTextureFrame:Show()
end

local function Poll(silent)
    local payload = "POLL|" .. string.rep(".", 215)
    SendAddonMessage(PREFIX, payload, "WHISPER", UnitName("player"))
    if not silent then
        Print("reverse-channel poll sent")
    end
end

-- Splits `str` on GROUP_SEP into a plain array of non-empty pieces. Used to
-- unpack a batched "SET|k1=v1<GS>k2=v2..." payload from wow_bridge.
local function SplitPairs(str)
    local parts = {}
    for piece in str:gmatch("([^" .. GROUP_SEP .. "]+)") do
        table.insert(parts, piece)
    end
    return parts
end

frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("CHAT_MSG_ADDON")
frame:SetScript("OnEvent", function(_, event, ...)
    local arg1 = ...
    if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
        DataBridgeDB = DataBridgeDB or {}
        if DataBridgeDB.autoPoll == nil then
            DataBridgeDB.autoPoll = true
        end
        DataBridgeDB.pollInterval = DataBridgeDB.pollInterval or 2
        if DataBridgeDB.debug == nil then
            DataBridgeDB.debug = false
        end
    elseif event == "PLAYER_LOGIN" then
        -- Not available on this client (a Cataclysm-era API, absent from
        -- vanilla WotLK 3.3.5a) - was erroring on every single login,
        -- aborting the rest of this handler (EnsureDisplay/the ready
        -- print) before it ever ran. Guarded rather than removed: costs
        -- nothing to keep calling it if a future client build adds it.
        if RegisterAddonMessagePrefix then
            RegisterAddonMessagePrefix(PREFIX)
        end
        -- Not called eagerly here anymore: this debug display frame (shows
        -- "waiting for API..." forever, since nothing ever sends a
        -- proxy_test value) used to be permanently hidden by the
        -- RegisterAddonMessagePrefix crash above aborting this handler
        -- before reaching this line - fixing that crash unmasked it as a
        -- dead-code visual clutter box with no real content ever shown.
        -- UpdateDisplay() already calls EnsureDisplay() lazily itself the
        -- moment a real proxy_test value ever arrives, so nothing is lost
        -- by not creating it speculatively here.
        Print("ready; whispering " .. UnitName("player"))
    elseif event == "CHAT_MSG_ADDON" then
        local prefix, message = arg1, select(2, ...)
        if prefix ~= PREFIX then
            return
        end
        local body = message:match("^SET|(.*)$")
        if not body then
            return
        end
        for _, pair in ipairs(SplitPairs(body)) do
            local key, value = pair:match("^([^=]+)=(.-)%s*$")
            if key then
                DataBridgeInbox[key] = value
                if key == "__lua" then
                    local chunk, compileError = loadstring(value)
                    if not chunk then
                        Print("Lua compile error: " .. tostring(compileError))
                    else
                        local ok, runtimeError = pcall(chunk)
                        if not ok then
                            Print("Lua runtime error: " .. tostring(runtimeError))
                        else
                            DebugPrint("Lua executed from API")
                        end
                    end
                else
                    UpdateDisplay(key, value)
                    DebugPrint("received from proxy: " .. key .. "=" .. value)
                    if type(DataBridge_OnValue) == "function" then
                        local ok, callbackError = pcall(DataBridge_OnValue, key, value)
                        if not ok then
                            Print("value callback error: " .. tostring(callbackError))
                        end
                    end
                end
            end
        end
    end
end)

frame:SetScript("OnUpdate", function(_, elapsed)
    -- Drain at most one addon message per throttle interval. Do not use a
    -- catch-up while-loop after a frame hitch: that would recreate a burst.
    sendElapsed = sendElapsed + elapsed
    if #outboundQueue > 0 and sendElapsed >= SEND_INTERVAL then
        sendElapsed = 0
        local payload = PackNextMessage()
        if payload then
            RawSend(payload)
        end
    end

    if not DataBridgeDB then
        return
    end
    if DataBridgeDB.autoPoll then
        pollElapsed = pollElapsed + elapsed
        if pollElapsed >= DataBridgeDB.pollInterval then
            pollElapsed = 0
            Poll(true)
        end
    end
end)

SLASH_DATABRIDGESEND1 = "/rustsend"
SlashCmdList.DATABRIDGESEND = function(message)
    if message == "" then
        Print("usage: /rustsend <text>")
        return
    end
    Send("TEXT|" .. message)
end

SLASH_DATABRIDGEDEBUG1 = "/rustdebug"
SlashCmdList.DATABRIDGEDEBUG = function(message)
    message = message:lower():match("^%s*(.-)%s*$")
    if message == "on" then
        DataBridgeDB.debug = true
        Print("debug ON (routine send/receive traffic will print in chat)")
    elseif message == "off" then
        DataBridgeDB.debug = false
        Print("debug OFF")
    else
        Print("usage: /rustdebug on|off (currently " .. (DataBridgeDB.debug and "on" or "off") .. ")")
    end
end

SLASH_DATABRIDGEQUEUE1 = "/rustqueue"
SlashCmdList.DATABRIDGEQUEUE = function()
    Print("outbound queue=" .. #outboundQueue .. " throttle=" .. string.format("%.2fs", SEND_INTERVAL))
end

SLASH_DATABRIDGEPOLL1 = "/rustpoll"
SlashCmdList.DATABRIDGEPOLL = function()
    Poll(false)
end

SLASH_DATABRIDGEAUTO1 = "/rustauto"
SlashCmdList.DATABRIDGEAUTO = function(message)
    local command, interval = message:match("^(%S*)%s*(%S*)$")
    command = command:lower()
    if command == "on" then
        local seconds = tonumber(interval)
        if seconds and seconds >= 0.5 then
            DataBridgeDB.pollInterval = seconds
        end
        DataBridgeDB.autoPoll = true
        pollElapsed = DataBridgeDB.pollInterval
        Print("auto poll ON every " .. DataBridgeDB.pollInterval .. "s")
    elseif command == "off" then
        DataBridgeDB.autoPoll = false
        Print("auto poll OFF")
    else
        Print("usage: /rustauto on [seconds] or /rustauto off")
    end
end

--------------------------------------------------------------------------
-- Standard Interface -> AddOns settings panel
--------------------------------------------------------------------------

local function EnsureSettingsDefaults()
    DataBridgeDB = DataBridgeDB or {}
    if DataBridgeDB.autoPoll == nil then DataBridgeDB.autoPoll = true end
    if DataBridgeDB.pollInterval == nil then DataBridgeDB.pollInterval = 2 end
    if DataBridgeDB.debug == nil then DataBridgeDB.debug = false end
end

local settingsPanel = CreateFrame("Frame", "DataBridgeSettingsPanel")
settingsPanel.name = "Data Bridge"

local settingsTitle = settingsPanel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
settingsTitle:SetPoint("TOPLEFT", 16, -16)
settingsTitle:SetText("Data Bridge")

local settingsDescription = settingsPanel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
settingsDescription:SetPoint("TOPLEFT", settingsTitle, "BOTTOMLEFT", 0, -8)
settingsDescription:SetWidth(560)
settingsDescription:SetJustifyH("LEFT")
settingsDescription:SetText("Controls communication with the local wow_bridge proxy.")

local autoPollCheck = CreateFrame(
    "CheckButton",
    "DataBridgeAutoPollCheckButton",
    settingsPanel,
    "InterfaceOptionsCheckButtonTemplate"
)
autoPollCheck:SetPoint("TOPLEFT", settingsDescription, "BOTTOMLEFT", -2, -18)
_G[autoPollCheck:GetName() .. "Text"]:SetText("Enable automatic reverse-channel polling")
autoPollCheck.tooltipText = "Periodically asks the local proxy for updated values and queued Lua actions."

local pollSlider = CreateFrame("Slider", "DataBridgePollIntervalSlider", settingsPanel, "OptionsSliderTemplate")
pollSlider:SetPoint("TOPLEFT", autoPollCheck, "BOTTOMLEFT", 26, -34)
pollSlider:SetWidth(240)
pollSlider:SetMinMaxValues(0.5, 10)
pollSlider:SetValueStep(0.5)
_G[pollSlider:GetName() .. "Low"]:SetText("0.5s")
_G[pollSlider:GetName() .. "High"]:SetText("10s")

local function SetPollSliderLabel(value)
    _G[pollSlider:GetName() .. "Text"]:SetText(string.format("Poll interval: %.1f seconds", value))
end

autoPollCheck:SetScript("OnClick", function(self)
    EnsureSettingsDefaults()
    DataBridgeDB.autoPoll = self:GetChecked() and true or false
    if DataBridgeDB.autoPoll then
        pollElapsed = DataBridgeDB.pollInterval
        pollSlider:Enable()
    else
        pollSlider:Disable()
    end
end)

pollSlider:SetScript("OnValueChanged", function(_, value)
    EnsureSettingsDefaults()
    value = math.max(0.5, math.min(10, math.floor(value * 2 + 0.5) / 2))
    DataBridgeDB.pollInterval = value
    SetPollSliderLabel(value)
end)

local debugCheck = CreateFrame(
    "CheckButton",
    "DataBridgeDebugCheckButton",
    settingsPanel,
    "InterfaceOptionsCheckButtonTemplate"
)
debugCheck:SetPoint("TOPLEFT", pollSlider, "BOTTOMLEFT", -26, -30)
_G[debugCheck:GetName() .. "Text"]:SetText("Enable debug messages in chat")
debugCheck.tooltipText = "Print routine send/receive traffic. Errors are always shown."
debugCheck:SetScript("OnClick", function(self)
    EnsureSettingsDefaults()
    DataBridgeDB.debug = self:GetChecked() and true or false
end)

local pollNowButton = CreateFrame("Button", nil, settingsPanel, "UIPanelButtonTemplate")
pollNowButton:SetSize(110, 24)
pollNowButton:SetPoint("TOPLEFT", debugCheck, "BOTTOMLEFT", 2, -22)
pollNowButton:SetText("Poll now")
pollNowButton:SetScript("OnClick", function() Poll(false) end)

local queueButton = CreateFrame("Button", nil, settingsPanel, "UIPanelButtonTemplate")
queueButton:SetSize(110, 24)
queueButton:SetPoint("LEFT", pollNowButton, "RIGHT", 10, 0)
queueButton:SetText("Queue status")
queueButton:SetScript("OnClick", function()
    Print("outbound queue=" .. #outboundQueue .. " throttle=" .. string.format("%.2fs", SEND_INTERVAL))
end)

settingsPanel:SetScript("OnShow", function()
    EnsureSettingsDefaults()
    autoPollCheck:SetChecked(DataBridgeDB.autoPoll)
    debugCheck:SetChecked(DataBridgeDB.debug)
    pollSlider:SetValue(DataBridgeDB.pollInterval)
    SetPollSliderLabel(DataBridgeDB.pollInterval)
    if DataBridgeDB.autoPoll then pollSlider:Enable() else pollSlider:Disable() end
end)

if type(InterfaceOptions_AddCategory) == "function" then
    InterfaceOptions_AddCategory(settingsPanel)
end

SLASH_DATABRIDGESETTINGS1 = "/rustsettings"
SlashCmdList.DATABRIDGESETTINGS = function()
    if type(InterfaceOptionsFrame_OpenToCategory) == "function" then
        InterfaceOptionsFrame_OpenToCategory(settingsPanel)
        InterfaceOptionsFrame_OpenToCategory(settingsPanel)
    end
end
