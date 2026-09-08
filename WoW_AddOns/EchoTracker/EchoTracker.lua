-- Minimal reporter + optional manual picker for ProjectEbonhold's
-- Echo/perk draft.
--
-- Reports live board/owned/resource state through DataBridge_Send so
-- external tools can see it via wow_bridge's API - purely observational
-- for everything except the small card-icon buttons below, which call
-- PerkService.SelectPerk ONLY when NOT in auto mode (a manual click, gated
-- on the locally-observed echo_auto value being off, so it never races
-- echo_autopilot.py's own SelectPerk calls while auto mode is on - see
-- DataBridge_OnValue; echo_auto is controlled ONLY by companion/
-- echo_toggle.py now, this addon never writes it, just reads it). Never
-- calls RequestReroll/BanishPerk/FreezePerk - those stay external-tool-only.
-- Does not touch ProjectEbonhold's own perk-choice UI or its
-- onEventReceived registrations (those allow only ONE handler per opcode -
-- see perks_service.lua's own comment on SEND_PLAYER_PERK_SELECTION_RESULT;
-- registering here would silently break the real board UI). Instead this
-- just polls the same public getters ProjectEbonhold's own UI reads.
--
-- UI footprint: one small status line + up to 3 small clickable card icons
-- with real tooltips (own frames, not the game's PerkChoice1/2/3, which
-- stay untouched) - draggable, position persists, /echodisplay on|off.

local frame = CreateFrame("Frame")
local pollElapsed = 0
local PlayerProfile

local function ReportToBridge(key, value)
    if type(DataBridge_Send) == "function" then
        DataBridge_Send(key, value)
    end
end

--------------------------------------------------------------------------
-- echo_auto state - REDESIGNED 2026-09-02, per explicit user request
-- ("sa fie activat doar din companion"). Used to be addon-owned
-- (EchoTrackerDB.autoEnabled persisted, /echoauto slash command,
-- periodic heartbeat re-asserting it every 120s) - that heartbeat was
-- built specifically to survive the bridge's old cache TTL sweep, which
-- has since been REMOVED ENTIRELY from wow_bridge (addon_bridge.rs). With
-- the TTL gone, that heartbeat became not just unnecessary but actively
-- WRONG: it would silently overwrite whatever companion/echo_toggle.py
-- had just set, back to this addon's own stale local value, any time
-- more than 120s passed between an external toggle and the next
-- heartbeat tick. Now this addon is a PURE OBSERVER of echo_auto - no
-- local write path, no slash command, no persistence, no re-assertion.
-- The only source of truth is companion's `echo-toggle`
-- (or tools/live/echo_toggle.py) - see DataBridge_OnValue below for how
-- this addon learns the current value.
--------------------------------------------------------------------------

-- Name of the last echo actually TAKEN (auto via echo_autopilot.py's
-- EchoTracker_Notify call, or manual via a card icon click) - shown in
-- the status box instead of a bare "-" placeholder when no board is
-- currently offered. Persisted (EchoTrackerDB.lastPickLabel) - a level-80
-- character stops getting new boards from leveling entirely, so a
-- session-local-only version would just stay blank forever with nothing
-- to naturally refill it.
local lastPickLabel = nil

-- Whichever spellId echo_autopilot.py's decide() currently recommends -
-- session-local only, comes from Python every cycle via DataBridge_OnValue
-- (see below), no reason to persist across /reload. UpdateCardButtons
-- checks this to show the aura on the matching icon.
local suggestedSpellId = nil
local suggestedAction = nil

-- Purely observed from the bridge (DataBridge_OnValue below) - never
-- written locally, never persisted. Gates the manual card-click path
-- (won't fire SelectPerk if auto is on, avoiding a race with
-- echo_autopilot.py's own picks).
local autoEnabled = false

local function EnsureAutoState()
    EchoTrackerDB = EchoTrackerDB or {}
    if lastPickLabel == nil then
        lastPickLabel = EchoTrackerDB.lastPickLabel
    end
end

local function SetLastPick(label)
    lastPickLabel = label
    EchoTrackerDB = EchoTrackerDB or {}
    EchoTrackerDB.lastPickLabel = label
end

--------------------------------------------------------------------------
-- Status display - draggable (position persists across /reload and relog
-- via EchoTrackerDB), backdrop styling matches SimpleDamageMeter.lua's
-- already-proven pattern (plain SetBackdrop works fine on this WotLK
-- client with no "BackdropTemplate" needed - that's a Retail-only
-- requirement). /echodisplay on|off hides/shows it independently of
-- whether echo_auto itself is on - a purely visual toggle.
--------------------------------------------------------------------------

local displayFrame, displayText

-- Moved up here (was declared right before EnsureCardButtons) since
-- EnsureDisplay() now also needs it to size the (now invisible) anchor
-- frame - Lua locals aren't visible to a function defined before them in
-- the file, so it has to live above every function that uses it.
local ICON_SIZE = math.max(28, math.min(80, tonumber(EchoTrackerDB and EchoTrackerDB.iconSize) or 56))

local function SaveDisplayPosition()
    if not displayFrame then
        return
    end
    local point, _, relPoint, x, y = displayFrame:GetPoint()
    EchoTrackerDB.displayPoint = point
    EchoTrackerDB.displayRelPoint = relPoint
    EchoTrackerDB.displayX = x
    EchoTrackerDB.displayY = y
end

local function EnsureDisplay()
    if displayFrame then
        return
    end
    -- EnsureDisplay() is called before EnsureAutoState() in the login
    -- handler below, so EchoTrackerDB may still be nil here on a
    -- brand-new character's first-ever load.
    EchoTrackerDB = EchoTrackerDB or {}
    -- Text bar (backdrop + displayText) removed per user request ("bara
    -- de desupra ar mere stearsa, sa apara doar icoanele") - displayFrame
    -- itself stays, invisible, as the drag anchor + parent for the card
    -- icons below (they're positioned relative to its BOTTOMLEFT), sized
    -- to match the icon row exactly instead of the old dynamic
    -- text-width sizing (nothing to size around anymore).
    displayFrame = CreateFrame("Frame", "EchoTrackerDisplay", UIParent)
    displayFrame:SetWidth(ICON_SIZE * 3 + 4)
    displayFrame:SetHeight(4)
    displayFrame:SetPoint(
        EchoTrackerDB.displayPoint or "TOPRIGHT",
        UIParent,
        EchoTrackerDB.displayRelPoint or EchoTrackerDB.displayPoint or "TOPRIGHT",
        EchoTrackerDB.displayX or -30,
        EchoTrackerDB.displayY or -190
    )

    displayFrame:SetMovable(true)
    displayFrame:EnableMouse(true)
    displayFrame:RegisterForDrag("LeftButton")
    displayFrame:SetClampedToScreen(true)
    displayFrame:SetScript("OnDragStart", function(self)
        if EchoTrackerDB and EchoTrackerDB.positionLocked then
            return
        end
        self:StartMoving()
    end)
    displayFrame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        SaveDisplayPosition()
    end)

    -- displayText still exists (SetStatus keeps writing to it) so the
    -- R/F/B/#rolls data is still computed and available, just not shown -
    -- easy to bring back visually later without touching the data side.
    displayText = displayFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    displayText:SetText("Echo: -")
    displayText:Hide()

    if EchoTrackerDB.displayShown == false then
        displayFrame:Hide()
    end
end

local function SetStatus(text)
    EnsureDisplay()
    if displayText then
        -- displayText is hidden now (see EnsureDisplay - text bar
        -- removed, icons only) so this just keeps the underlying R/F/B/
        -- #rolls data current, not visible. No longer resizes
        -- displayFrame to fit the text (that would shift the icon row,
        -- now anchored to a fixed-width invisible displayFrame instead
        -- of one that tracked text width).
        displayText:SetText(text)
    end
end

--------------------------------------------------------------------------
-- Board card icons - small, compact clickable icons (with real spell
-- tooltips) for whatever's currently offered, parented to displayFrame so
-- /echodisplay on|off hides/shows them together with the status box.
-- Click-to-select only fires when NOT in auto mode (EchoTrackerDB.
-- autoEnabled == false) - while auto mode is on, echo_autopilot.py is the
-- one calling SelectPerk, so a manual click here would race it; the
-- button still shows/tooltips either way, just doesn't act on click.
--------------------------------------------------------------------------

--------------------------------------------------------------------------
-- Wishlist - up to 6 echoes (matching the real permanent-lock slot cap),
-- warns when one appears on the board. NOT built as a duplicate browser
-- window (the real Echo Journal's own search grid already does that, and
-- rebuilding it would be a lot of surface for zero real benefit). Instead,
-- one keybind toggles the wishlist for WHATEVER ECHO IS CURRENTLY UNDER
-- YOUR MOUSE - works while hovering the real Journal's search grid, its
-- granted-perks row, its permanent-slot row, or our own board/lock-slot
-- icons below, since all of those set a `.spellId` field on the tooltip's
-- owner button (confirmed against echo_journal.lua's ShowEchoTooltip and
-- our own EnsureCardButtons/EnsureLockButtons) - GameTooltip:GetOwner()
-- hands that same button back to us the moment any tooltip is shown,
-- completely independent of which addon actually owns that button.
-- Locking itself still only happens in the real Journal, same as before -
-- this only tracks what you WANT, it never calls LockPerk/UnlockPerk.
--------------------------------------------------------------------------

local WISHLIST_MAX_SIZE = 6

local function EnsureWishlist()
    EchoTrackerDB = EchoTrackerDB or {}
    EchoTrackerDB.wishlist = EchoTrackerDB.wishlist or {}
end

local function IsWishlisted(spellId)
    EnsureWishlist()
    return spellId ~= nil and EchoTrackerDB.wishlist[spellId] == true
end

local function WishlistCount()
    EnsureWishlist()
    local n = 0
    for _ in pairs(EchoTrackerDB.wishlist) do n = n + 1 end
    return n
end

local function WishlistLabel(spellId)
    local PE = _G.ProjectEbonhold
    local info = PE and PE.PerkDatabase and PE.PerkDatabase[spellId]
    return (info and info.comment) or ("Echo #" .. tostring(spellId))
end

-- Whatever echo is currently under the mouse, tracked via the GameTooltip
-- hooks below - nil whenever no echo-flagged button currently owns the
-- tooltip (an item tooltip, a unit frame, etc. never set `.spellId`, so
-- this correctly stays nil for anything that isn't an echo icon).
local hoveredSpellId = nil

GameTooltip:HookScript("OnShow", function(self)
    local owner = self:GetOwner()
    hoveredSpellId = owner and owner.spellId or nil
end)
GameTooltip:HookScript("OnHide", function()
    hoveredSpellId = nil
end)

-- Bindable via the standard Key Bindings UI (see Bindings.xml) - toggles
-- the wishlist for whichever echo is currently hovered, anywhere.
-- Debounce state - a single physical keypress of the bound combo was
-- observed live to invoke this function TWICE in immediate succession
-- (toggle on, then right back off, netting to nothing) - a WoW/this
-- client's keybinding quirk with the multi-modifier combo, not anything
-- under this addon's control. Rather than chase that down, just ignore a
-- second call for the SAME echo within a fraction of a second - real
-- back-to-back toggles of the same echo (intentionally add, then
-- immediately remove again) aren't a realistic use case to lose.
local lastToggleSpellId, lastToggleTime = nil, 0
local TOGGLE_DEBOUNCE_S = 0.4

function EchoTracker_ToggleWishlistHovered()
    if not hoveredSpellId then
        print("|cffffcc00EchoTracker:|r hover an echo icon first (the real Journal's grid, or the icons below) before using this.")
        return
    end
    local spellId = hoveredSpellId
    local now = GetTime()
    if spellId == lastToggleSpellId and (now - lastToggleTime) < TOGGLE_DEBOUNCE_S then
        return
    end
    lastToggleSpellId, lastToggleTime = spellId, now
    local label = WishlistLabel(spellId)
    EnsureWishlist()
    if EchoTrackerDB.wishlist[spellId] then
        EchoTrackerDB.wishlist[spellId] = nil
        print("|cffff5555EchoTracker:|r removed from wishlist: " .. label)
    else
        if WishlistCount() >= WISHLIST_MAX_SIZE then
            print("|cffffcc00EchoTracker:|r wishlist is full (" .. WISHLIST_MAX_SIZE .. " max, matching your permanent slot cap) - remove one first.")
            return
        end
        EchoTrackerDB.wishlist[spellId] = true
        print("|cff33ff66EchoTracker:|r added to wishlist: " .. label)
    end
end

SLASH_ECHOTRACKERWISHLIST1 = "/echowish"
SlashCmdList.ECHOTRACKERWISHLIST = function()
    EnsureWishlist()
    local names = {}
    for spellId in pairs(EchoTrackerDB.wishlist) do
        table.insert(names, WishlistLabel(spellId))
    end
    table.sort(names)
    if #names == 0 then
        print("|cffffcc00EchoTracker:|r wishlist is empty. Hover any echo icon and use your Wishlist Toggle keybind (Key Bindings > EchoTracker).")
    else
        print("|cffffcc00EchoTracker:|r wishlist (" .. #names .. "/" .. WISHLIST_MAX_SIZE .. "): " .. table.concat(names, ", "))
    end
end

-- Display strings for the standard Key Bindings UI - the technical
-- binding name (Bindings.xml's <Binding name="...">) must match the
-- BINDING_NAME_<name> suffix exactly.
BINDING_HEADER_ECHOTRACKER = "Echo Tracker"
BINDING_NAME_ECHOTRACKER_WISHLIST_TOGGLE = "Toggle Wishlist (hovered echo)"

local cardButtons = {}

local function EnsureCardButtons()
    if cardButtons[1] then
        return
    end
    for i = 1, 3 do
        local btn = CreateFrame("Button", "EchoTrackerCard" .. i, displayFrame)
        btn:SetWidth(ICON_SIZE)
        btn:SetHeight(ICON_SIZE)
        btn:SetPoint("TOPLEFT", displayFrame, "BOTTOMLEFT", (i - 1) * (ICON_SIZE + 2), -2)

        btn:SetBackdrop({
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            edgeSize = 8,
        })

        local icon = btn:CreateTexture(nil, "ARTWORK")
        icon:SetPoint("TOPLEFT", btn, "TOPLEFT", 2, -2)
        icon:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", -2, 2)
        btn.icon = icon

        -- Strong advisory marker for the card companion would act on. A
        -- single stock border was too easy to miss against the server's
        -- dark offer panels, especially at 1440p, so this combines a large
        -- pulsing halo, a bright border, and an explicit label.
        local glow = btn:CreateTexture(nil, "OVERLAY")
        glow:SetPoint("TOPLEFT", btn, "TOPLEFT", -11, 11)
        glow:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", 11, -11)
        glow:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
        glow:SetBlendMode("ADD")
        glow:SetVertexColor(1, 0.72, 0)
        glow:Hide()
        btn.glow = glow

        local pickLabel = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        pickLabel:SetPoint("BOTTOM", btn, "TOP", 0, 7)
        pickLabel:SetText("AI PICK")
        pickLabel:SetShadowOffset(1, -1)
        pickLabel:Hide()
        btn.pickLabel = pickLabel

        -- Old-client-safe pulse: no animation API assumptions. OnUpdate is
        -- active only for the one suggested card and removed immediately
        -- when the recommendation changes.
        btn.pulseSuggested = function(self)
            local pulse = 0.68 + 0.32 * math.sin(GetTime() * 5)
            self.glow:SetAlpha(pulse)
            self.pickLabel:SetAlpha(0.82 + 0.18 * math.sin(GetTime() * 5))
        end

        -- Wishlist warning - a second, wider ring in a color that can't be
        -- confused with the gold "suggested" aura above, so a card that's
        -- BOTH the AI's pick AND on your wishlist shows two distinct
        -- concentric rings instead of one blended color.
        local wishGlow = btn:CreateTexture(nil, "OVERLAY")
        wishGlow:SetPoint("TOPLEFT", btn, "TOPLEFT", -10, 10)
        wishGlow:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", 10, -10)
        wishGlow:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
        wishGlow:SetBlendMode("ADD")
        wishGlow:SetVertexColor(1, 0.15, 0.6)
        wishGlow:Hide()
        btn.wishGlow = wishGlow

        btn:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")

        btn:RegisterForClicks("LeftButtonUp")
        btn:SetScript("OnEnter", function(self)
            if not self.spellId then
                return
            end
            -- Bug fixed 2026-09-02, from a screenshot: two problems.
            -- (1) ANCHOR_RIGHT overlapped the real board UI awkwardly
            -- whenever the icon row sat near where the game's own cards
            -- render (position is user-draggable, could be anywhere) -
            -- ANCHOR_CURSOR always follows the mouse instead, avoiding
            -- fixed-position overlap regardless of where the row is.
            -- (2) GameTooltip:SetHyperlink shows the RAW unresolved
            -- formula ("@flat200+lvl4@"), not a real number - same
            -- distinction already learned the hard way for the
            -- description export: GameTooltip's own tooltip pipeline
            -- never resolves @formula@ tokens, only utils.
            -- GetSpellDescription does (via CalculateStatFormula). Now
            -- builds a custom tooltip with resolved text, same call this
            -- addon's export already uses successfully for these IDs.
            GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
            local utils = _G.utils
            local desc = (utils and utils.GetSpellDescription and utils.GetSpellDescription(self.spellId, 500, 1)) or ""
            desc = desc:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
            GameTooltip:SetText(self.label or "?", 1, 1, 1)
            if desc ~= "" then
                GameTooltip:AddLine(desc, 1, 0.82, 0, true)
            end
            GameTooltip:Show()
        end)
        btn:SetScript("OnLeave", function()
            GameTooltip:Hide()
        end)
        btn:SetScript("OnClick", function(self)
            if not self.spellId then
                return
            end
            if EchoTrackerDB and EchoTrackerDB.manualIconClicks == false then
                print("|cffffcc00EchoTracker:|r manual icon clicks are disabled in /echosettings")
                return
            end
            if autoEnabled then
                print("|cffffcc00EchoTracker:|r auto mode is ON (--auto 0 to use assisted manual clicks)")
                return
            end
            local PE = _G.ProjectEbonhold
            local service = PE and PE.PerkService
            if not service then
                return
            end
            local action = suggestedAction or "TAKE"
            if action == "REROLL" and service.RequestReroll then
                -- Reroll targets the whole offer, so every gray card acts as
                -- the same large click target while in assisted-manual mode.
                service.RequestReroll()
            elseif suggestedSpellId and not self.isSuggested then
                return
            elseif action == "FREEZE" and service.FreezePerk then
                if PE.Perks then PE.Perks.pendingFreezeIndex = nil end
                service.FreezePerk(self.choiceIndex)
            elseif action == "BANISH" and service.BanishPerk then
                if PE.Perks then PE.Perks.pendingBanishIndex = nil end
                service.BanishPerk(self.choiceIndex)
            elseif action == "TAKE" and service.SelectPerk then
                service.SelectPerk(self.spellId)
                if self.label then
                    SetLastPick(self.label)
                end
            end
        end)

        btn:Hide()
        cardButtons[i] = btn
    end
end

-- Bug fixed 2026-09-02, caught live from a screenshot (colors didn't
-- match the real card glow): this used to index the real client global
-- ITEM_QUALITY_COLORS directly by card.quality, but that global's scale
-- is WoW's own (0=Poor, 1=Common, 2=Uncommon, 3=Rare, 4=Epic...) while
-- this server's card.quality/QUALITY_NAMES scale starts a tier earlier
-- (0=Common, 1=Uncommon, 2=Rare, 3=Epic, 4=Legendary, no "Poor" tier at
-- all) - a one-tier offset, so a Rare card (quality=2 here) rendered
-- with Uncommon's green instead of Rare's blue. Own table now, matching
-- QUALITY_NAMES exactly (score_echo_board.py) instead of relying on
-- WoW's differently-indexed one.
local ECHO_QUALITY_COLORS = {
    [0] = {1.00, 1.00, 1.00}, -- Common (white)
    [1] = {0.12, 1.00, 0.00}, -- Uncommon (green)
    [2] = {0.00, 0.44, 0.87}, -- Rare (blue)
    [3] = {0.64, 0.21, 0.93}, -- Epic (purple)
    [4] = {1.00, 0.50, 0.00}, -- Legendary (orange)
}

-- Fires once per DISTINCT board (not every poll tick while the same board
-- sits there) when at least one offered card is on the wishlist - a chat
-- print + a stock alert sound, so you don't have to be looking directly at
-- the icon row to notice. The wishGlow ring on the card itself (set in
-- UpdateCardButtons) is the persistent visual; this is just the one-time
-- "hey, look" nudge.
local lastWishlistAlertBoard = nil

local function AlertWishlistMatches(choices)
    if not choices or #choices == 0 then
        lastWishlistAlertBoard = nil
        return
    end
    local sigParts, matches = {}, {}
    for _, card in ipairs(choices) do
        sigParts[#sigParts + 1] = tostring(card.spellId)
        if IsWishlisted(card.spellId) then
            matches[#matches + 1] = WishlistLabel(card.spellId)
        end
    end
    local signature = table.concat(sigParts, ",")
    if signature == lastWishlistAlertBoard then
        return
    end
    lastWishlistAlertBoard = signature
    if #matches > 0 then
        print("|cffff2699EchoTracker:|r wishlist echo on the board! " .. table.concat(matches, ", "))
        PlaySound("RaidWarning")
    end
end

local function UpdateCardButtons(choices)
    EnsureCardButtons()
    local PE = _G.ProjectEbonhold
    for i = 1, 3 do
        local btn = cardButtons[i]
        local card = choices and choices[i]
        if card and card.spellId then
            btn.spellId = card.spellId
            btn.choiceIndex = i - 1
            btn.isSuggested = suggestedAction ~= "REROLL" and suggestedSpellId and tostring(card.spellId) == tostring(suggestedSpellId)
            -- Real display name, from the static catalog (perks_data.lua,
            -- ProjectEbonhold.PerkDatabase[spellId].comment - same field
            -- tools/export/export_perk_catalog.py extracts) - the live
            -- choice data itself has no name field, only
            -- spellId/quality/flags. Used for lastPickLabel when this
            -- card gets manually clicked/taken.
            local info = PE and PE.PerkDatabase and PE.PerkDatabase[card.spellId]
            btn.label = info and info.comment or nil
            -- NOT GetSpellTexture(spellId) - returned nil live for these
            -- custom server spellIds (empty icon boxes, confirmed live:
            -- the button/border rendered fine, just no texture inside).
            -- GetSpellInfo's 3rd return value is the icon instead - known
            -- to work for these IDs already (utils.GetSpellDescription
            -- uses GetSpellInfo's 1st return, name, successfully).
            local _, _, iconTexture = GetSpellInfo(card.spellId)
            btn.icon:SetTexture(iconTexture)
            local color = ECHO_QUALITY_COLORS[card.quality]
            if color then
                btn:SetBackdropBorderColor(color[1], color[2], color[3])
            else
                btn:SetBackdropBorderColor(1, 1, 1)
            end
            local showRecommendation = not EchoTrackerDB or EchoTrackerDB.showAIColors ~= false
            if btn.isSuggested and showRecommendation then
                btn.icon:SetVertexColor(1, 1, 1)
                local actionColors = {
                    TAKE = {0.10, 1.00, 0.25, "|cff20ff40AI PICK|r"},
                    FREEZE = {0.10, 0.55, 1.00, "|cff2699ffAI FREEZE|r"},
                    BANISH = {1.00, 0.12, 0.12, "|cffff3030AI BANISH|r"},
                }
                local marker = actionColors[suggestedAction] or {1.00, 0.82, 0.00, "|cffffd100AI PICK|r"}
                btn.glow:SetVertexColor(marker[1], marker[2], marker[3])
                btn.pickLabel:SetText(marker[4])
                btn.glow:Show()
                btn.pickLabel:Show()
                btn:SetScript("OnUpdate", btn.pulseSuggested)
                btn:SetBackdropBorderColor(marker[1], marker[2], marker[3])
            else
                -- Once companion has made a recommendation, every other
                -- option becomes a visibly disabled context card. Keep
                -- mouse input for tooltips, but OnClick above refuses it.
                if showRecommendation and (suggestedSpellId or suggestedAction == "REROLL") then
                    btn.icon:SetVertexColor(0.30, 0.30, 0.30)
                    btn:SetBackdropBorderColor(0.28, 0.28, 0.28)
                else
                    btn.icon:SetVertexColor(1, 1, 1)
                end
                btn.glow:Hide()
                if showRecommendation and suggestedAction == "REROLL" and i == 2 then
                    btn.pickLabel:SetText("|cffffd100AI REROLL|r")
                    btn.pickLabel:SetAlpha(1)
                    btn.pickLabel:Show()
                else
                    btn.pickLabel:Hide()
                end
                btn.glow:SetAlpha(1)
                btn:SetScript("OnUpdate", nil)
            end
            if IsWishlisted(card.spellId) then
                btn.wishGlow:Show()
            else
                btn.wishGlow:Hide()
            end
            btn:Show()
        else
            btn.spellId = nil
            btn.choiceIndex = nil
            btn.isSuggested = false
            btn:SetScript("OnUpdate", nil)
            btn.glow:Hide()
            btn.pickLabel:Hide()
            btn:Hide()
        end
    end
    AlertWishlistMatches(choices)
end

-- LOCK_ICON_SIZE: shared sizing for the wishlist row below (there used to
-- be a separate locked-permanent-slots row at this same size, showing the
-- real GetLockedPerks() list one-for-one - removed per user feedback: it
-- visually duplicated the wishlist row (the same echo could appear in
-- both, once as "wanted" and once as "locked"), and the wishlist row's own
-- green checkmark (see IsLocked/IsAcquired below) already conveys "this
-- wanted one is now locked" without needing a second physical row for it.
-- An echo that's locked but was NEVER wishlisted has no dedicated status
-- display anymore - the real Echo Journal's own top row is still the
-- place to see the full 6 slots regardless of wishlist status.
local LOCK_ICON_SIZE = 24

--------------------------------------------------------------------------
-- Wishlist icon row - same visual pattern as the locked-slot row above,
-- one row down, so the wishlist is actually visible somewhere instead of
-- only reachable via /echowish or the pink glow (which only shows a match
-- while it happens to be on the current board). Adding is still only via
-- the hover+keybind toggle (nothing else to click to pick a NEW echo from
-- here), but removing is also just a click away on the row itself now -
-- no need to go re-hover the original echo somewhere else just to take it
-- back off the list.
--------------------------------------------------------------------------

local wishButtons = {}

-- Forward-declared: the popup's OnAccept below refreshes the manager
-- window immediately (so a removed row disappears right away instead of
-- waiting for the window to be closed/reopened), but RefreshWishManager
-- itself is only defined further down, next to the window it belongs to -
-- without this local existing first, that closure would compile a GLOBAL
-- lookup and silently do nothing at runtime (same class of bug as
-- CheckpointFavorites' ROW_COUNT crash earlier this session).
local RefreshWishManager

StaticPopupDialogs["ECHOTRACKER_WISHLIST_REMOVE"] = {
    text = "Remove \"%s\" from your wishlist?",
    button1 = "Remove",
    button2 = "Cancel",
    OnAccept = function(self, data)
        EnsureWishlist()
        EchoTrackerDB.wishlist[data.spellId] = nil
        print("|cffff5555EchoTracker:|r removed from wishlist: " .. (data.label or ("Echo #" .. data.spellId)))
        if RefreshWishManager then
            RefreshWishManager()
        end
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

local function EnsureWishButtons()
    if wishButtons[1] then
        return
    end
    for i = 1, WISHLIST_MAX_SIZE do
        local btn = CreateFrame("Frame", "EchoTrackerWishSlot" .. i, displayFrame)
        btn:SetWidth(LOCK_ICON_SIZE)
        btn:SetHeight(LOCK_ICON_SIZE)
        -- One fixed row below the board-card row (ICON_SIZE=56 tall,
        -- starting 2px below displayFrame) - never wraps, so this can't
        -- reproduce the multi-line-wrap overflow bug the earlier
        -- Settings-window Meta Echo attempt had.
        btn:SetPoint("TOPLEFT", displayFrame, "BOTTOMLEFT", (i - 1) * (LOCK_ICON_SIZE + 2), -2 - ICON_SIZE - 4)

        btn:SetBackdrop({
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            edgeSize = 6,
        })
        btn:SetBackdropBorderColor(1, 0.15, 0.6) -- matches the board-icon wishGlow color

        local icon = btn:CreateTexture(nil, "ARTWORK")
        icon:SetPoint("TOPLEFT", btn, "TOPLEFT", 1, -1)
        icon:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", -1, 1)
        btn.icon = icon

        -- Green ready-check mark, bottom-right corner - shown when this
        -- wishlist echo is already among GetGrantedPerks() this run (owned,
        -- whether or not it's one of the 6 permanently locked ones).
        local check = btn:CreateTexture(nil, "OVERLAY")
        check:SetSize(LOCK_ICON_SIZE * 0.6, LOCK_ICON_SIZE * 0.6)
        check:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", 2, -2)
        check:SetTexture("Interface\\RaidFrame\\ReadyCheck-Ready")
        check:Hide()
        btn.check = check

        btn:EnableMouse(true)
        btn:SetScript("OnEnter", function(self)
            if not self.spellId then
                return
            end
            GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
            GameTooltip:SetText(self.label or "?", 1, 1, 1)
            local status = "On your wishlist - not yet acquired"
            if self.locked then
                status = "On your wishlist - already locked (permanent)"
            elseif self.acquired then
                status = "On your wishlist - acquired this run, not locked"
            end
            GameTooltip:AddLine(status, 1, 0.4, 0.7)
            GameTooltip:AddLine("Right-click the Wishlist button below to manage/remove", 0.6, 0.6, 0.6)
            GameTooltip:Show()
        end)
        btn:SetScript("OnLeave", function()
            GameTooltip:Hide()
        end)
        -- Deliberately NOT clickable here - a small 24px icon sitting right
        -- below the fast-moving board row is too easy to hit by accident
        -- during normal play, for echoes that can be very hard to get back
        -- (user's own words: "they are drop very very very hard good
        -- echos"). Removal only happens through the Wishlist Manager
        -- window below, a genuinely deliberate action.

        btn:Hide()
        wishButtons[i] = btn
    end
end

-- granted: same shape UpdateCardButtons/PackOwned already consume - a
-- table keyed by spell NAME, each value an array of one entry per owned
-- stack, {spellId=...}. Keyed by name rather than id (server-side quirk,
-- see PackOwned's own comment), so matching by id means scanning every
-- stack rather than a direct lookup - fine, at most a few dozen entries.
-- granted and locked are MUTUALLY EXCLUSIVE on the real server addon
-- (perks_service.lua: a perk with the locked=1 flag goes into
-- Perks.lockedPerks INSTEAD OF Perks.grantedPerks, never both) - confirmed
-- live: a wishlist entry already locked into a permanent slot showed "not
-- yet acquired" here despite the locked-slot row showing it as owned,
-- because this only checked `granted`. An echo counts as acquired if it
-- appears in EITHER list.
local function IsAcquired(spellId, granted, locked)
    if not spellId then
        return false
    end
    if locked then
        for _, entry in ipairs(locked) do
            if entry.spellId == spellId then
                return true
            end
        end
    end
    if granted then
        for _, stacks in pairs(granted) do
            for _, entry in ipairs(stacks) do
                if entry.spellId == spellId then
                    return true
                end
            end
        end
    end
    return false
end

local function IsLocked(spellId, locked)
    if not locked or not spellId then
        return false
    end
    for _, entry in ipairs(locked) do
        if entry.spellId == spellId then
            return true
        end
    end
    return false
end

local function UpdateWishSlots(granted, locked)
    EnsureWishButtons()
    EnsureWishlist()
    local PE = _G.ProjectEbonhold
    local ids = {}
    for spellId in pairs(EchoTrackerDB.wishlist) do
        ids[#ids + 1] = spellId
    end
    table.sort(ids)

    for i = 1, WISHLIST_MAX_SIZE do
        local btn = wishButtons[i]
        local spellId = ids[i]
        if spellId then
            btn.spellId = spellId
            local info = PE and PE.PerkDatabase and PE.PerkDatabase[spellId]
            btn.label = info and info.comment or nil
            local _, _, iconTexture = GetSpellInfo(spellId)
            btn.icon:SetTexture(iconTexture)
            btn.icon:Show()
            btn.acquired = IsAcquired(spellId, granted, locked)
            btn.locked = IsLocked(spellId, locked)
            -- Not SetShown: works fine elsewhere in this file/other addons
            -- on FontStrings, but errors here ("attempt to call method
            -- 'SetShown' (a nil value)") - btn.check is a plain Texture
            -- (CreateTexture), the one widget type on this client that
            -- doesn't have it. Show()/Hide() exist on every widget type.
            if btn.acquired then
                btn.check:Show()
            else
                btn.check:Hide()
            end
            btn:Show()
        else
            btn.spellId = nil
            btn.acquired = nil
            btn.locked = nil
            btn:Hide()
        end
    end
end

--------------------------------------------------------------------------
-- Wishlist Manager window - the ONLY place wishlist entries can be
-- removed from. A deliberate window + a clearly-labeled "Remove" button +
-- the same confirmation popup the small icons used to trigger accidentally
-- - three real steps instead of one stray click, for echoes that can be
-- very hard to get a second time. Same native DialogBox look as
-- CallBoardHelper/WhitelistLiquidator/CheckpointFavorites' own windows,
-- for visual consistency across all four addons.
--------------------------------------------------------------------------

local WISH_ROW_H = 26
local wishManagerFrame, wishManagerRows

RefreshWishManager = function()
    if not wishManagerFrame then
        return
    end
    EnsureWishlist()
    local PE = _G.ProjectEbonhold
    local ids = {}
    for spellId in pairs(EchoTrackerDB.wishlist) do
        ids[#ids + 1] = spellId
    end
    table.sort(ids)

    for i = 1, WISHLIST_MAX_SIZE do
        local row = wishManagerRows[i]
        local spellId = ids[i]
        if spellId then
            local info = PE and PE.PerkDatabase and PE.PerkDatabase[spellId]
            local label = info and info.comment or ("Echo #" .. spellId)
            local _, _, iconTexture = GetSpellInfo(spellId)
            row.icon:SetTexture(iconTexture)
            row.text:SetText(label)
            row.spellId = spellId
            row.label = label
            row.removeBtn:Show()
            row:Show()
        else
            row.spellId = nil
            row:Hide()
        end
    end
    -- Not SetShown - same finding as UpdateWishSlots above: this client
    -- (3.3.5a) doesn't have SetShown at all, on any widget type. The one
    -- FontString-only theory drawn from CallBoardHelper/WhitelistLiquidator
    -- never actually crashing was wrong - those call sites just hadn't been
    -- exercised live yet, not proof the method exists here.
    if #ids == 0 then
        wishManagerFrame.emptyText:Show()
    else
        wishManagerFrame.emptyText:Hide()
    end
    wishManagerFrame.title:SetText("Echo Wishlist (" .. #ids .. "/" .. WISHLIST_MAX_SIZE .. ")")
end

local function CreateWishManager()
    wishManagerFrame = CreateFrame("Frame", "EchoTrackerWishlistManager", UIParent)
    wishManagerFrame:SetWidth(280)
    wishManagerFrame:SetHeight(60 + WISHLIST_MAX_SIZE * WISH_ROW_H + 20)
    wishManagerFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    wishManagerFrame:SetFrameStrata("DIALOG")
    wishManagerFrame:SetMovable(true)
    wishManagerFrame:EnableMouse(true)
    wishManagerFrame:RegisterForDrag("LeftButton")
    wishManagerFrame:SetClampedToScreen(true)
    wishManagerFrame:Hide()
    wishManagerFrame:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 }
    })
    wishManagerFrame:SetScript("OnDragStart", function(self) self:StartMoving() end)
    wishManagerFrame:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)

    local title = wishManagerFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -16)
    title:SetText("Echo Wishlist")
    wishManagerFrame.title = title

    local close = CreateFrame("Button", nil, wishManagerFrame, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -5, -5)

    local emptyText = wishManagerFrame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    emptyText:SetPoint("TOP", 0, -44)
    emptyText:SetText("Empty. Hover any echo and use your Wishlist Toggle keybind to add one.")
    emptyText:SetWidth(240)
    emptyText:SetJustifyH("CENTER")
    wishManagerFrame.emptyText = emptyText

    wishManagerRows = {}
    for i = 1, WISHLIST_MAX_SIZE do
        local row = CreateFrame("Frame", nil, wishManagerFrame)
        row:SetWidth(248)
        row:SetHeight(WISH_ROW_H)
        row:SetPoint("TOPLEFT", 16, -40 - (i - 1) * WISH_ROW_H)

        local icon = row:CreateTexture(nil, "ARTWORK")
        icon:SetSize(20, 20)
        icon:SetPoint("LEFT", 0, 0)
        row.icon = icon

        local text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        text:SetPoint("LEFT", icon, "RIGHT", 6, 0)
        text:SetWidth(150)
        text:SetJustifyH("LEFT")
        row.text = text

        local removeBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
        removeBtn:SetSize(64, 20)
        removeBtn:SetPoint("RIGHT", 0, 0)
        removeBtn:SetText("Remove")
        removeBtn:GetFontString():SetTextColor(1, 0.35, 0.35) -- same red-for-destructive convention used in the other 3 addons' Share windows
        removeBtn:SetScript("OnClick", function()
            if not row.spellId then
                return
            end
            StaticPopup_Show("ECHOTRACKER_WISHLIST_REMOVE", row.label, nil, { spellId = row.spellId, label = row.label })
        end)
        row.removeBtn = removeBtn

        row:Hide()
        wishManagerRows[i] = row
    end
end

local function ToggleWishManager()
    if not wishManagerFrame then
        CreateWishManager()
    end
    if wishManagerFrame:IsShown() then
        wishManagerFrame:Hide()
    else
        RefreshWishManager()
        wishManagerFrame:Show()
    end
end

-- Small trigger button, anchored to the right of the wishlist row - the
-- only clickable entry point into the manager window. A plain book icon
-- (no special asset needed), tooltip explains it since nothing else in
-- this addon has ever had a persistent button before.
-- Separate floating, draggable button (own frame, own saved position) -
-- NOT glued into the wishlist row, matching how CallBoardHelper/
-- WhitelistLiquidator/CheckpointFavorites all expose their management
-- window through one persistent floating/minimap button rather than an
-- icon embedded in a status row. The wishlist row itself stays pure
-- display (hover-only, no click), same as the board-card icons above it.
-- 36x36 - was 28, noticeably smaller than CallBoardHelper/
-- WhitelistLiquidator/CheckpointFavorites' own floating trigger buttons
-- (all 36x36) when seen stacked together on screen. Matched to those.
local wishManagerBtn = CreateFrame("Button", "EchoTrackerWishlistButton", UIParent)
wishManagerBtn:SetWidth(36)
wishManagerBtn:SetHeight(36)
wishManagerBtn:SetFrameStrata("MEDIUM")
wishManagerBtn:SetMovable(true)
wishManagerBtn:EnableMouse(true)
wishManagerBtn:RegisterForDrag("LeftButton")
wishManagerBtn:SetClampedToScreen(true)
wishManagerBtn:SetPoint(
    EchoTrackerDB and EchoTrackerDB.wishBtnPoint or "CENTER",
    UIParent,
    EchoTrackerDB and (EchoTrackerDB.wishBtnRelPoint or EchoTrackerDB.wishBtnPoint) or "CENTER",
    EchoTrackerDB and EchoTrackerDB.wishBtnX or 0,
    EchoTrackerDB and EchoTrackerDB.wishBtnY or -260
)

-- Same layer construction as CheckpointFavorites' quick-teleport button
-- and WhitelistLiquidator's floating button (bg fill, inset+cropped icon,
-- full-size border, inset ADD-blend highlight) - one shared visual "type"
-- across all three own-addons' floating triggers instead of three
-- independently-built styles.
local wishBtnBg = wishManagerBtn:CreateTexture(nil, "BACKGROUND")
wishBtnBg:SetPoint("TOPLEFT", 2, -2)
wishBtnBg:SetPoint("BOTTOMRIGHT", -2, 2)
wishBtnBg:SetTexture(0.018, 0.020, 0.026, 0.95)

local wishBtnIcon = wishManagerBtn:CreateTexture(nil, "ARTWORK")
wishBtnIcon:SetPoint("TOPLEFT", 2, -2)
wishBtnIcon:SetPoint("BOTTOMRIGHT", -2, 2)
wishBtnIcon:SetTexture("Interface\\Icons\\INV_Misc_Book_09")
wishBtnIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

local wishBtnBorder = wishManagerBtn:CreateTexture(nil, "OVERLAY")
wishBtnBorder:SetAllPoints(wishManagerBtn)
wishBtnBorder:SetTexture("Interface\\Buttons\\UI-Quickslot2")

local wishBtnHl = wishManagerBtn:CreateTexture(nil, "HIGHLIGHT")
wishBtnHl:SetPoint("TOPLEFT", 2, -2)
wishBtnHl:SetPoint("BOTTOMRIGHT", -2, 2)
wishBtnHl:SetTexture("Interface\\Buttons\\ButtonHilight-Square")
wishBtnHl:SetBlendMode("ADD")

wishManagerBtn:SetScript("OnClick", ToggleWishManager)
wishManagerBtn:SetScript("OnDragStart", function(self)
    if EchoTrackerDB and EchoTrackerDB.positionLocked then
        return
    end
    self:StartMoving()
end)
wishManagerBtn:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    EchoTrackerDB = EchoTrackerDB or {}
    local point, _, relPoint, x, y = self:GetPoint()
    EchoTrackerDB.wishBtnPoint = point
    EchoTrackerDB.wishBtnRelPoint = relPoint
    EchoTrackerDB.wishBtnX = x
    EchoTrackerDB.wishBtnY = y
end)
wishManagerBtn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:SetText("Echo Wishlist Manager", 1, 1, 1)
    GameTooltip:AddLine("Click to view/remove wishlist entries", 0.8, 0.8, 0.8)
    GameTooltip:AddLine("Drag to move", 0.6, 0.6, 0.6)
    GameTooltip:Show()
end)
wishManagerBtn:SetScript("OnLeave", function()
    GameTooltip:Hide()
end)

SLASH_ECHOTRACKERDISPLAY1 = "/echodisplay"
SlashCmdList.ECHOTRACKERDISPLAY = function(msg)
    msg = string.lower(msg or ""):gsub("^%s*(.-)%s*$", "%1")
    EnsureDisplay()
    if msg == "on" then
        EchoTrackerDB.displayShown = true
        displayFrame:Show()
        print("|cffffcc00EchoTracker:|r display ON")
    elseif msg == "off" then
        EchoTrackerDB.displayShown = false
        displayFrame:Hide()
        print("|cffffcc00EchoTracker:|r display OFF")
    else
        print("usage: /echodisplay on|off (currently " .. (EchoTrackerDB.displayShown == false and "off" or "on") .. ") - left-drag the box to move it")
    end
end

--------------------------------------------------------------------------
-- Action notification - a small custom banner, since RaidBossEmoteFrame
-- turned out not to actually have an AddMessage method on this client
-- (attempt to call method 'AddMessage' (a nil value) - so it isn't the
-- MessageFrame widget assumed). Same fade-out pattern as
-- DataBridge_ShowTexture's clearAfter already used elsewhere in this addon
-- set. Called from outside (echo_autopilot.py, via /api/cmd/lua) right
-- alongside the actual PerkService call, so it reports exactly what was
-- executed.
--------------------------------------------------------------------------

local NOTIFY_COLORS = {
    TAKE = {0.2, 1, 0.2},
    REROLL = {1, 1, 0.2},
    BANISH = {1, 0.3, 0.3},
    FREEZE = {0.3, 0.8, 1},
}

local notifyFrame, notifyText
local roleFrame, roleRequestGuid, roleRequestName

local function EnsureRoleFrame()
    if roleFrame then return end
    roleFrame = CreateFrame("Frame", "EchoTrackerRoleSelection", UIParent)
    roleFrame:SetWidth(360)
    roleFrame:SetHeight(145)
    roleFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 120)
    roleFrame:SetFrameStrata("DIALOG")
    roleFrame:SetBackdrop({
        bgFile="Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile="Interface\\DialogFrame\\UI-DialogBox-Border", edgeSize=24,
        insets={left=8,right=8,top=8,bottom=8}
    })
    roleFrame:EnableMouse(true)
    roleFrame:SetMovable(true)
    roleFrame:RegisterForDrag("LeftButton")
    roleFrame:SetScript("OnDragStart", function(self) self:StartMoving() end)
    roleFrame:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
    local title=roleFrame:CreateFontString(nil,"OVERLAY","GameFontNormalLarge")
    title:SetPoint("TOP",0,-22); title:SetText("EchoBrain: select scoring role")
    roleFrame.message=roleFrame:CreateFontString(nil,"OVERLAY","GameFontHighlight")
    roleFrame.message:SetPoint("TOP",title,"BOTTOM",0,-10)
    local close=CreateFrame("Button",nil,roleFrame,"UIPanelCloseButton")
    close:SetPoint("TOPRIGHT",-5,-5)
    local roles={
        {"Tank","tank","TANK",{0,0.296875,0,0.3125}},
        {"DPS","dps","DAMAGER",{0.625,0.921875,0,0.3125}},
        {"Heal","heal","HEALER",{0.3125,0.609375,0,0.3125}}
    }
    for i,entry in ipairs(roles) do
        local roleLabel,roleValue,roleToken,fallback=entry[1],entry[2],entry[3],entry[4]
        local button=CreateFrame("Button",nil,roleFrame)
        button:SetWidth(82); button:SetHeight(66)
        button:SetPoint("BOTTOMLEFT",34+(i-1)*105,10)
        button.role=roleValue
        local icon=button:CreateTexture(nil,"ARTWORK")
        icon:SetTexture("Interface\\LFGFrame\\UI-LFG-ICON-PORTRAITROLES")
        icon:SetWidth(44); icon:SetHeight(44); icon:SetPoint("TOP",0,0)
        local left,right,top,bottom
        if GetTexCoordsForRoleSmallCircle then
            left,right,top,bottom=GetTexCoordsForRoleSmallCircle(roleToken)
        end
        if not left then left,right,top,bottom=unpack(fallback) end
        icon:SetTexCoord(left,right,top,bottom)
        local highlight=button:CreateTexture(nil,"HIGHLIGHT")
        highlight:SetTexture("Interface\\Buttons\\ButtonHilight-Square")
        highlight:SetBlendMode("ADD")
        highlight:SetWidth(48); highlight:SetHeight(48); highlight:SetPoint("CENTER",icon,"CENTER")
        local label=button:CreateFontString(nil,"OVERLAY","GameFontNormal")
        label:SetPoint("TOP",icon,"BOTTOM",0,-1); label:SetText(roleLabel)
        button:SetScript("OnEnter",function(self)
            GameTooltip:SetOwner(self,"ANCHOR_RIGHT")
            GameTooltip:SetText(roleLabel .. " scoring",1,0.82,0)
            GameTooltip:AddLine("Save this role for " .. (roleRequestName or "this character"),1,1,1)
            GameTooltip:Show()
        end)
        button:SetScript("OnLeave",function() GameTooltip:Hide() end)
        button:SetScript("OnClick",function(self)
            local profile=PlayerProfile()
            if not profile or profile.guid ~= roleRequestGuid then
                print("|cffff5555EchoTracker:|r character changed; role was not saved")
                roleFrame:Hide(); return
            end
            ReportToBridge("echo_role_choice", roleRequestGuid .. string.char(31) .. self.role)
            print("|cff55ff55EchoTracker:|r " .. roleRequestName .. " role selected: " .. self.role)
            roleFrame:Hide()
        end)
    end
    roleFrame:Hide()
end

local function ShowRoleSelection(value)
    local sep=string.char(31)
    local pos=value and string.find(value,sep,1,true)
    if not pos then return end
    local guid=string.sub(value,1,pos-1)
    local name=string.sub(value,pos+1)
    local profile=PlayerProfile()
    if not profile or profile.guid ~= guid then return end
    roleRequestGuid,roleRequestName=guid,(name ~= "" and name or profile.name)
    EnsureRoleFrame()
    roleFrame.message:SetText("Talents are ambiguous for " .. roleRequestName .. ". Choose once:")
    roleFrame:Show()
end

local function EnsureNotify()
    if notifyFrame then
        return
    end
    notifyFrame = CreateFrame("Frame", nil, UIParent)
    notifyFrame:SetWidth(400)
    notifyFrame:SetHeight(40)
    notifyFrame:SetPoint("TOP", UIParent, "TOP", 0, -100)
    notifyFrame:Hide()

    notifyText = notifyFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    notifyText:SetPoint("CENTER", notifyFrame, "CENTER", 0, 0)

    notifyFrame:SetScript("OnUpdate", function(self, elapsed)
        if not self.clearAfter then
            return
        end
        self.clearAfter = self.clearAfter - elapsed
        if self.clearAfter <= 0 then
            self.clearAfter = nil
            self:Hide()
        end
    end)
end

-- DataBridge_OnValue is DataBridge.lua's inbound callback (a single global
-- function, called whenever a Python bridge.set(key, ...) reaches this
-- client - see DataBridge.lua's own poll handler) - not previously used by
-- anything in this addon set (confirmed no other definition exists
-- anywhere in WoW_AddOns/, safe to define here). Only handles
-- "echo_suggested" - just updates the tracked spellId; the next natural
-- Refresh()/UpdateCardButtons cycle (every 0.2-0.75s, OnUpdate-driven)
-- picks up the change and shows/hides the glow, no need to force an
-- immediate re-render from here.
function DataBridge_OnValue(key, value)
    if key == "echo_suggested" then
        suggestedSpellId = (value and value ~= "") and value or nil
    elseif key == "echo_suggested_action" then
        suggestedAction = (value and value ~= "") and string.upper(value) or nil
    elseif key == "echo_auto" then
        autoEnabled = (value == "on")
    elseif key == "echo_role_request" then
        if value and value ~= "" then
            ShowRoleSelection(value)
        elseif roleFrame then
            roleFrame:Hide()
        end
    end
end

SLASH_ECHOROLE1 = "/echorole"
SlashCmdList["ECHOROLE"] = function()
    if roleRequestGuid then
        ShowRoleSelection(roleRequestGuid .. string.char(31) .. (roleRequestName or ""))
    else
        print("|cffffcc00EchoTracker:|r no pending role selection")
    end
end

function EchoTracker_Notify(action, label)
    EnsureNotify()
    local color = NOTIFY_COLORS[action] or {1, 1, 1}
    local text = tostring(label or "") ~= "" and (action .. ": " .. tostring(label)) or action
    notifyText:SetTextColor(color[1], color[2], color[3])
    notifyText:SetText(text)
    notifyFrame.clearAfter = 4
    notifyFrame:Show()

    if action == "TAKE" and label and label ~= "" then
        SetLastPick(label)
    end
end

--------------------------------------------------------------------------
-- Native server picker suppression
--
-- ProjectEbonhold is delivered from patch-4.MPQ rather than the normal
-- AddOns directory, but its PerkService resolves PerkUI.Show dynamically.
-- Wrapping that table entry here lets the compact EchoTracker picker replace
-- the large native overlay without modifying/repacking the MPQ. Choice data
-- and PerkService remain fully active for telemetry and actions.
--------------------------------------------------------------------------

local nativePerkShowOriginal = nil
local nativePerkHideOriginal = nil
local nativePerkHookInstalled = false

local function IsNativePickerEnabled()
    EchoTrackerDB = EchoTrackerDB or {}
    if EchoTrackerDB.nativePickerEnabled == nil then
        EchoTrackerDB.nativePickerEnabled = true
    end
    return EchoTrackerDB.nativePickerEnabled ~= false
end

local function HardSuppressNativePicker()
    if nativePerkHideOriginal then
        pcall(nativePerkHideOriginal)
    end
    for _, name in ipairs({
        "ProjectEbonholdPerkFrame",
        "PerkChooseButton",
        "PerkHideButton",
        "PerkFamilyHintFrame",
        "PerkChoice1",
        "PerkChoice2",
        "PerkChoice3",
    }) do
        local frame = _G[name]
        if frame then
            frame:EnableMouse(false)
            frame:SetAlpha(0)
            frame:Hide()
        end
    end
end

local function InstallNativePickerHook()
    local ui = ProjectEbonhold and ProjectEbonhold.PerkUI
    if nativePerkHookInstalled or not ui or type(ui.Show) ~= "function" then
        return nativePerkHookInstalled
    end
    nativePerkShowOriginal = ui.Show
    nativePerkHideOriginal = ui.Hide
    ui.Show = function(...)
        if IsNativePickerEnabled() then
            return nativePerkShowOriginal(...)
        end
        HardSuppressNativePicker()
    end
    nativePerkHookInstalled = true
    if not IsNativePickerEnabled() then
        HardSuppressNativePicker()
    end
    return true
end

-- Reports the single unambiguous "a run actually ended" moment: both
-- normal and Hardcore death both funnel through this exact same function
-- (confirmed against the server addon's own source) regardless of WHY it
-- fired - out of free revives, declined to pay Soul Ashes, or a deliberate
-- hardcore self-destruct. Deliberately NOT inferred from hardmode_tier
-- dropping - that's also changed by HardmodeService.SetDifficulty() from a
-- plain "Change Difficulty" menu with zero death involved, which would
-- have made a tier-based signal fire on a voluntary difficulty switch too.
-- Persisted (EchoTrackerDB.runResetCount) rather than reset to 0 each
-- reload, since companion treats any CHANGE in this counter as "a new run
-- started" - restarting from 0 after every /reload would misfire on the
-- next reload itself, not just a real reset.
local runResetHookInstalled = false

local function InstallRunResetHook()
    local service = ProjectEbonhold and ProjectEbonhold.PlayerRunService
    if runResetHookInstalled or not service or type(service.AcceptDeath) ~= "function" then
        return runResetHookInstalled
    end
    local original = service.AcceptDeath
    service.AcceptDeath = function(...)
        EchoTrackerDB = EchoTrackerDB or {}
        EchoTrackerDB.runResetCount = (EchoTrackerDB.runResetCount or 0) + 1
        ReportToBridge("echo_run_reset", tostring(EchoTrackerDB.runResetCount))
        return original(...)
    end
    runResetHookInstalled = true
    return true
end

local function SetNativePickerEnabled(enabled)
    EchoTrackerDB = EchoTrackerDB or {}
    EchoTrackerDB.nativePickerEnabled = enabled and true or false
    InstallNativePickerHook()
    if not enabled then
        HardSuppressNativePicker()
    elseif ProjectEbonhold and ProjectEbonhold.PerkService and ProjectEbonhold.PerkService.RequestChoice then
        ProjectEbonhold.PerkService.RequestChoice()
    end
end

SLASH_ECHONATIVE1 = "/echonative"
SlashCmdList.ECHONATIVE = function(msg)
    local command = tostring(msg or ""):lower():match("^%s*(.-)%s*$")
    if command == "off" then
        SetNativePickerEnabled(false)
        print("|cff42df91EchoTracker:|r native server picker disabled; compact picker remains active")
    elseif command == "on" then
        SetNativePickerEnabled(true)
        print("|cff42df91EchoTracker:|r native server picker enabled")
    elseif command == "status" or command == "" then
        print("|cff42df91EchoTracker:|r native server picker is " .. (IsNativePickerEnabled() and "ON" or "OFF"))
    else
        print("|cff42df91EchoTracker:|r usage: /echonative on|off|status")
    end
end

local settingsPanel = CreateFrame("Frame", "EchoTrackerSettingsPanel")
settingsPanel.name = "EchoTracker"

local settingsTitle = settingsPanel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
settingsTitle:SetPoint("TOPLEFT", 16, -16)
settingsTitle:SetText("EchoTracker")

local settingsDescription = settingsPanel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
settingsDescription:SetPoint("TOPLEFT", settingsTitle, "BOTTOMLEFT", 0, -8)
settingsDescription:SetWidth(560)
settingsDescription:SetJustifyH("LEFT")
settingsDescription:SetText("Controls the compact EchoTracker display and the native server perk overlay. The server datapack is not modified.")

local nativePickerCheck = CreateFrame(
    "CheckButton",
    "EchoTrackerNativePickerCheckButton",
    settingsPanel,
    "InterfaceOptionsCheckButtonTemplate"
)
nativePickerCheck:SetPoint("TOPLEFT", settingsDescription, "BOTTOMLEFT", -2, -18)
_G[nativePickerCheck:GetName() .. "Text"]:SetText("Show native server perk picker")
nativePickerCheck.tooltipText = "Show the large ProjectEbonhold perk-choice overlay."
nativePickerCheck.tooltipRequirement = "When disabled, EchoTracker, companion, telemetry, and autopilot remain active."
nativePickerCheck:SetScript("OnClick", function(self)
    SetNativePickerEnabled(self:GetChecked() and true or false)
end)

local nativePickerHelp = settingsPanel:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
nativePickerHelp:SetPoint("TOPLEFT", nativePickerCheck, "BOTTOMLEFT", 26, -4)
nativePickerHelp:SetWidth(520)
nativePickerHelp:SetJustifyH("LEFT")
nativePickerHelp:SetText("Disable this to remove the large picker and its invisible clickable cards while keeping EchoTracker's compact picker working.")

local function CreateSettingsCheck(name, label, anchor, offsetY, tooltip)
    local check = CreateFrame("CheckButton", name, settingsPanel, "InterfaceOptionsCheckButtonTemplate")
    check:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, offsetY)
    _G[name .. "Text"]:SetText(label)
    check.tooltipText = tooltip
    return check
end

local compactDisplayCheck = CreateSettingsCheck(
    "EchoTrackerCompactDisplayCheckButton",
    "Show compact EchoTracker icons",
    nativePickerHelp,
    -18,
    "Show the compact three-card picker and wishlist row."
)
compactDisplayCheck:SetScript("OnClick", function(self)
    EnsureDisplay()
    EchoTrackerDB.displayShown = self:GetChecked() and true or false
    if EchoTrackerDB.displayShown then displayFrame:Show() else displayFrame:Hide() end
end)

local positionLockCheck = CreateSettingsCheck(
    "EchoTrackerPositionLockCheckButton",
    "Lock frame positions",
    compactDisplayCheck,
    -8,
    "Prevents dragging the compact picker and Wishlist button."
)
positionLockCheck:SetScript("OnClick", function(self)
    EchoTrackerDB.positionLocked = self:GetChecked() and true or false
end)

local aiColorsCheck = CreateSettingsCheck(
    "EchoTrackerAIColorsCheckButton",
    "Show AI recommendation colors",
    positionLockCheck,
    -8,
    "Show TAKE, FREEZE, BANISH, and REROLL recommendation colors and labels."
)
aiColorsCheck:SetScript("OnClick", function(self)
    EchoTrackerDB.showAIColors = self:GetChecked() and true or false
    local PE = _G.ProjectEbonhold
    local choices = PE and PE.PerkService and PE.PerkService.GetCurrentChoice and PE.PerkService.GetCurrentChoice()
    UpdateCardButtons(choices)
end)

local manualClicksCheck = CreateSettingsCheck(
    "EchoTrackerManualClicksCheckButton",
    "Enable manual icon clicks",
    aiColorsCheck,
    -8,
    "Allows the compact icons to execute the displayed recommendation while companion auto mode is off."
)
manualClicksCheck:SetScript("OnClick", function(self)
    EchoTrackerDB.manualIconClicks = self:GetChecked() and true or false
end)

local iconSizeSlider = CreateFrame(
    "Slider",
    "EchoTrackerIconSizeSlider",
    settingsPanel,
    "OptionsSliderTemplate"
)
iconSizeSlider:SetPoint("TOPLEFT", manualClicksCheck, "BOTTOMLEFT", 24, -32)
iconSizeSlider:SetWidth(240)
iconSizeSlider:SetMinMaxValues(28, 80)
iconSizeSlider:SetValueStep(4)
_G[iconSizeSlider:GetName() .. "Low"]:SetText("28")
_G[iconSizeSlider:GetName() .. "High"]:SetText("80")

local function ApplyIconSize(value)
    value = math.max(28, math.min(80, math.floor((tonumber(value) or 56) / 4 + 0.5) * 4))
    ICON_SIZE = value
    EchoTrackerDB.iconSize = value
    EnsureDisplay()
    displayFrame:SetWidth(ICON_SIZE * 3 + 4)
    for i, btn in ipairs(cardButtons) do
        btn:SetWidth(ICON_SIZE)
        btn:SetHeight(ICON_SIZE)
        btn:ClearAllPoints()
        btn:SetPoint("TOPLEFT", displayFrame, "BOTTOMLEFT", (i - 1) * (ICON_SIZE + 2), -2)
    end
    for i, btn in ipairs(wishButtons) do
        btn:ClearAllPoints()
        btn:SetPoint("TOPLEFT", displayFrame, "BOTTOMLEFT", (i - 1) * (LOCK_ICON_SIZE + 2), -2 - ICON_SIZE - 4)
    end
    _G[iconSizeSlider:GetName() .. "Text"]:SetText("Icon size: " .. value .. " px")
end

iconSizeSlider:SetScript("OnValueChanged", function(self, value)
    ApplyIconSize(value)
end)

settingsPanel:SetScript("OnShow", function()
    nativePickerCheck:SetChecked(IsNativePickerEnabled())
    EchoTrackerDB = EchoTrackerDB or {}
    compactDisplayCheck:SetChecked(EchoTrackerDB.displayShown ~= false)
    positionLockCheck:SetChecked(EchoTrackerDB.positionLocked == true)
    aiColorsCheck:SetChecked(EchoTrackerDB.showAIColors ~= false)
    manualClicksCheck:SetChecked(EchoTrackerDB.manualIconClicks ~= false)
    iconSizeSlider:SetValue(ICON_SIZE)
    ApplyIconSize(ICON_SIZE)
end)

if type(InterfaceOptions_AddCategory) == "function" then
    InterfaceOptions_AddCategory(settingsPanel)
end

SLASH_ECHOSETTINGS1 = "/echosettings"
SlashCmdList.ECHOSETTINGS = function()
    if type(InterfaceOptionsFrame_OpenToCategory) == "function" then
        -- The first call selects the AddOns category on older WotLK clients;
        -- the second reliably opens the requested child panel.
        InterfaceOptionsFrame_OpenToCategory(settingsPanel)
        InterfaceOptionsFrame_OpenToCategory(settingsPanel)
    end
end

local nativeHookFrame = CreateFrame("Frame")
nativeHookFrame:SetScript("OnUpdate", function(self)
    if InstallNativePickerHook() then
        self:SetScript("OnUpdate", nil)
    end
end)

local runResetHookFrame = CreateFrame("Frame")
runResetHookFrame:SetScript("OnUpdate", function(self)
    if InstallRunResetHook() then
        self:SetScript("OnUpdate", nil)
    end
end)

--------------------------------------------------------------------------
-- Packing helpers (compact strings for the DataBridge wire)
--------------------------------------------------------------------------

local function FlagsOf(choice)
    local flags = ""
    -- isFrozen: this card arrived already-frozen from a previous session.
    -- justFrozen: this card was frozen THIS session, via FreezePerk - set by
    -- SEND_FREEZE_PERK_RESULT's handler (perks_service.lua), a DIFFERENT
    -- field from isFrozen. Without checking both, echo_board stays
    -- byte-identical after a freeze we just executed (isFrozen alone never
    -- changes), which looks like "nothing changed" to the autopilot's
    -- anti-loop check and gets it stuck refusing to re-evaluate the board.
    if choice.isFrozen or choice.justFrozen then flags = flags .. "F" end
    if choice.isCarried then flags = flags .. "C" end
    if choice.isGuaranteed then flags = flags .. "G" end
    return flags
end

-- Every Echo spellId observed is in [200000, 201428] (perk_catalog.json) -
-- sending (spellId - SPELL_ID_BASE) instead of the raw id saves 2 bytes per
-- occurrence, every time, for free. The Python side adds this back
-- (score_echo_board.py's SPELL_ID_BASE) before touching the catalog or
-- calling SelectPerk/BanishPerk/FreezePerk, so nothing downstream needs to
-- know this shortening happened.
local SPELL_ID_BASE = 200000

-- choices: array of {spellId, quality, isFrozen, isCarried, isGuaranteed},
-- from ProjectEbonhold.PerkService.GetCurrentChoice(). nil/empty = no board.
local function PackBoard(choices)
    if not choices or #choices == 0 then
        return ""
    end
    local parts = {}
    for _, choice in ipairs(choices) do
        table.insert(parts, (choice.spellId - SPELL_ID_BASE) .. ":" .. choice.quality .. ":" .. FlagsOf(choice))
    end
    return table.concat(parts, ";")
end

-- granted: table keyed by spell NAME (not id) -> array of one entry per
-- stack, each {spellId=...}, from ProjectEbonhold.PerkService.GetGrantedPerks().
-- Re-keyed here to spellId:count, sorted for stable output (pairs() order
-- isn't stable, and we only want to report when something actually changed).
-- Returns a plain array of "spellId:count" pieces, NOT a joined string - by
-- level 50+ a paladin can have 30+ granted echoes, and joining them all into
-- one value blows past the 220-byte single-message cap (DataBridge_Send
-- silently drops anything over that). SendChunked below splits this array
-- across as many echo_owned_N keys as needed instead.
local function PackOwned(granted)
    if not granted then
        return {}
    end
    local parts = {}
    for _, stacks in pairs(granted) do
        local first = stacks[1]
        if first and first.spellId then
            table.insert(parts, (first.spellId - SPELL_ID_BASE) .. ":" .. #stacks)
        end
    end
    table.sort(parts)
    return parts
end

-- locked: array of {spellId, stack, maxStack, quality} from
-- ProjectEbonhold.PerkService.GetLockedPerks() - the small subset of owned
-- echoes the player has explicitly chosen as PERMANENT (survives a normal
-- reset; how many slots are available is level-gated,
-- GetMaximumPermanentEchoes() - e.g. 1 slot early, up to 6 by end-game,
-- confirmed live). Small (max = the slot cap, single digits), unlike
-- echo_owned's full list - no chunking needed, one joined SendChanged.
local function PackLocked(locked)
    if not locked or #locked == 0 then
        return ""
    end
    local parts = {}
    for _, entry in ipairs(locked) do
        table.insert(parts, (entry.spellId - SPELL_ID_BASE) .. ":" .. (entry.stack or 1) .. ":" .. (entry.quality or 0))
    end
    return table.concat(parts, ";")
end

-- Icon keys for FlaskGUI's display only - deliberately NOT appended onto
-- echo_board/echo_locked's own fields. Those two keys aren't chunked (unlike
-- echo_owned) and are already close to DataBridge_Send's ~220-byte single-
-- message cap with up to 6 locked entries - an icon key string
-- ("spell_holy_prayerofhealing" etc, 15-30 bytes each) tacked onto every
-- entry would risk silently dropping the whole value past that cap. Since
-- companion's actual live decide/auto loop reads echo_board/echo_locked for
-- real gameplay actions, that's not a risk worth taking for a dashboard
-- nice-to-have. A brand new chunked key (same pattern as echo_owned)
-- sidesteps this entirely: FlaskGUI is the only consumer, and companion
-- never reads it at all.
--
-- Board choices are NOT covered here anymore (2026-09-08) - name/icon are
-- both fixed per spellId (never vary with stacks/context), so the one-time
-- EchoTracker_ExportIcons() catalog-wide dump (below) plus
-- data/perk_display.json already covers every board card FlaskGUI will ever
-- show. This only still exists at all as a safety net for the ~6 locked
-- slots, in case a spellId is ever missing from that static export (e.g. a
-- catalog entry added after the last export run).
local iconKeyCache = {}
local nameCache = {}

-- Also caches the display name (GetSpellInfo's 1st return, same call as the
-- icon lookup - no reason to call it twice per spellId). Name goes out as a
-- 3rd, trailing field so FlaskGUI can show "Contagion" instead of
-- "Echo #201262" - the id-based fallback stays in the JS for any spellId
-- this hasn't reported a name for yet (e.g. right after login, before the
-- first cache fill).
local function SpellDisplayInfo(spellId)
    if iconKeyCache[spellId] ~= nil and nameCache[spellId] ~= nil then
        return iconKeyCache[spellId], nameCache[spellId]
    end
    local name, _, icon = GetSpellInfo(spellId)
    local key = nil
    if icon then
        local base = tostring(icon):match("([^\\/]+)$") or tostring(icon)
        base = base:gsub("%.%a+$", "")
        key = base:lower():gsub("[^%w_]", "")
        iconKeyCache[spellId] = key
    end
    if name then
        nameCache[spellId] = name
    end
    return key, name
end

-- Only the LOCKED spellIds actually visible right now (at most 6) - see the
-- "board choices are NOT covered here anymore" note above. Field order is
-- "id:iconkey:name" - name is last and NOT length-limited or sanitized
-- against ":" the way the id/iconkey fields are, since echo names are
-- simple text (no colons/semicolons observed in the catalog), but is still
-- last specifically so a stray ":" in some future name can never shift the
-- fixed-position id/iconkey fields - only a greedy split on the FIRST two
-- colons should ever be used to parse this.
local function PackIcons(locked)
    local parts, seen = {}, {}
    local function addSpell(spellId)
        if not spellId or seen[spellId] then
            return
        end
        seen[spellId] = true
        local key, name = SpellDisplayInfo(spellId)
        if key and key ~= "" then
            table.insert(parts, (spellId - SPELL_ID_BASE) .. ":" .. key .. ":" .. (name or ""))
        end
    end
    if locked then
        for _, l in ipairs(locked) do
            addSpell(l.spellId)
        end
    end
    return parts
end

-- Tooltip description text - same "separate, non-critical, chunked key"
-- treatment as PackIcons above, for the same reason: this is dashboard-only,
-- companion never reads it, so it can never affect real gameplay. Unlike
-- icon keys/names, description text is free-form game text that genuinely
-- CAN contain literal ":" or ";" (e.g. "Increases X by 10%; also reduces Y")
-- - using those as field/record separators here (like PackIcons does) would
-- silently corrupt parsing the moment one contains either. Uses the same
-- ASCII control-char separator trick EchoTracker_ExportDescriptions already
-- proved out below for this exact problem (own locals, not the same
-- variables, since those are defined later in the file and this only needs
-- the same byte values, not the same binding).
--
-- Board choices are NOT covered here anymore (2026-09-08) - a board card's
-- description is always computed at stacks=1
-- (utils.GetSpellDescription(spellId, _, 1), see DescriptionOf/PackTips
-- below), which is exactly what the one-time
-- EchoTracker_ExportDescriptions() catalog-wide dump already captured into
-- data/perk_descriptions.json - sending it again live on every board
-- refresh was pure duplicate traffic. Locked echoes are different: their
-- description genuinely depends on the live stack count
-- (utils.GetSpellDescription(spellId, _, entry.stack)), which the static
-- export can't know in advance, so those (at most 6) still export live.
local TIP_ID_SEP = string.char(31)   -- ASCII Unit Separator - never appears in real game text
local TIP_PART_SEP = string.char(30) -- ASCII Record Separator - joins id/desc records within a chunk

local descCache = {}

-- maxLength=150 (not the export feature's fuller 195-2048) - keeps a single
-- record comfortably under DataBridge_Send's ~220-byte single-message cap
-- even with the id prefix and separator, without needing this feature's own
-- multi-part continuation scheme (the export feature needs that because it
-- covers the full 546-entry catalog's occasionally-long descriptions; this
-- only ever covers the <=9 spellIds currently visible on the board/locked).
local function DescriptionOf(spellId, stacks)
    local cacheKey = spellId .. ":" .. (stacks or 1)
    local cached = descCache[cacheKey]
    if cached then
        return cached
    end
    local utils = _G.utils
    local desc = (utils and utils.GetSpellDescription and utils.GetSpellDescription(spellId, 150, stacks or 1)) or ""
    desc = desc:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    descCache[cacheKey] = desc
    return desc
end

local function PackTips(locked)
    local parts, seen = {}, {}
    local function addSpell(spellId, stacks)
        if not spellId or seen[spellId] then
            return
        end
        seen[spellId] = true
        local desc = DescriptionOf(spellId, stacks)
        if desc ~= "" then
            table.insert(parts, (spellId - SPELL_ID_BASE) .. TIP_ID_SEP .. desc)
        end
    end
    if locked then
        for _, l in ipairs(locked) do
            addSpell(l.spellId, l.stack or 1)
        end
    end
    return parts
end

-- data: from ProjectEbonhold.PlayerRunService.GetCurrentData().
local function PackCharges(data)
    if not data then
        return ""
    end
    return string.format(
        "reroll:%d/%d;banish:%d;freeze:%d/%d",
        data.usedRerolls or 0, data.totalRerolls or 0,
        data.remainingBanishes or 0,
        data.usedFreezes or 0, data.totalFreezes or 0
    )
end

--------------------------------------------------------------------------
-- Refresh: read the real API, report only what changed
--------------------------------------------------------------------------

local lastSent = {}
local lastHeroStatsContext = nil

-- Caps how many DISTINCT KEYS can be newly queued in one Refresh() call - a
-- mass-change moment (e.g. a full level/prestige reset touching board,
-- several echo_owned_N chunks, charges and level all at once) would
-- otherwise dump a burst of entries into DataBridge's outbound queue in one
-- shot. Since lastSent isn't updated for anything skipped, a deferred key
-- is simply picked up again on the very next poll tick (0.2-0.75s later)
-- instead - spreads a burst across a couple of cycles instead of one.
local REFRESH_SEND_BUDGET = 4
local sendBudgetRemaining = REFRESH_SEND_BUDGET

local function SendChanged(key, value)
    value = tostring(value or "")
    if lastSent[key] ~= value then
        if sendBudgetRemaining <= 0 then
            return false
        end
        sendBudgetRemaining = sendBudgetRemaining - 1
        lastSent[key] = value
        ReportToBridge(key, value)
    end
    return true
end

PlayerProfile = function()
    local guid = UnitGUID("player")
    local name = UnitName("player")
    if not guid or not name then return nil end
    local _, classToken = UnitClass("player")
    local _, raceToken = UnitRace("player")
    local faction = UnitFactionGroup("player") or ""
    local realm = (GetRealmName and GetRealmName()) or ""
    local bestTab, bestPoints, talentName, tied = 0, -1, "Unknown", false
    for tab = 1, (GetNumTalentTabs and GetNumTalentTabs() or 3) do
        local tabName, _, points = GetTalentTabInfo(tab)
        points = tonumber(points) or 0
        if points > bestPoints then
            bestTab, bestPoints, talentName, tied = tab, points, tabName or "Unknown", false
        elseif points == bestPoints then
            tied = true
        end
    end
    local roles = {
        WARRIOR={"dps","dps","tank"}, PALADIN={"heal","tank","dps"},
        HUNTER={"dps","dps","dps"}, ROGUE={"dps","dps","dps"},
        PRIEST={"heal","heal","dps"}, DEATHKNIGHT={"dps","dps","dps"},
        SHAMAN={"dps","dps","heal"}, MAGE={"dps","dps","dps"},
        WARLOCK={"dps","dps","dps"}, DRUID={"dps","dps","heal"},
    }
    local role = (roles[classToken or ""] and roles[classToken][bestTab]) or "unknown"
    if bestPoints <= 0 then talentName, role = "Unspent", "unknown"
    elseif tied then talentName, role = "Hybrid/Unknown", "unknown" end
    return {
        guid=guid, name=name, realm=realm, class=classToken or "",
        race=raceToken or "", faction=faction, talent=talentName, role=role,
    }
end

-- Telemetry v2, fixed positional schema kept compact enough for one
-- DataBridge message. These are effective live character values and work
-- for every class; irrelevant stats naturally remain zero. Field order is
-- mirrored by companion::autopilot::parse_hero_stats.
local function PackHeroStats()
    local stats = {}
    for i = 1, 5 do
        local _, effective = UnitStat("player", i)
        stats[#stats + 1] = effective or 0
    end
    local apBase, apPos, apNeg = UnitAttackPower("player")
    stats[#stats + 1] = (apBase or 0) + (apPos or 0) + (apNeg or 0)
    local rapBase, rapPos, rapNeg = UnitRangedAttackPower("player")
    stats[#stats + 1] = (rapBase or 0) + (rapPos or 0) + (rapNeg or 0)
    local spellPower = 0
    if GetSpellBonusDamage then
        for school = 2, 7 do spellPower = math.max(spellPower, GetSpellBonusDamage(school) or 0) end
    end
    stats[#stats + 1] = spellPower
    stats[#stats + 1] = (GetSpellBonusHealing and GetSpellBonusHealing()) or 0
    stats[#stats + 1] = (GetCritChance and GetCritChance()) or 0
    stats[#stats + 1] = (GetRangedCritChance and GetRangedCritChance()) or 0
    stats[#stats + 1] = (GetSpellCritChance and GetSpellCritChance(2)) or 0
    local function Rating(constant)
        return (constant and GetCombatRating and GetCombatRating(constant)) or 0
    end
    stats[#stats + 1] = Rating(_G.CR_HASTE_MELEE)
    stats[#stats + 1] = Rating(_G.CR_HASTE_RANGED)
    stats[#stats + 1] = Rating(_G.CR_HASTE_SPELL)
    stats[#stats + 1] = Rating(_G.CR_HIT_MELEE)
    stats[#stats + 1] = (GetExpertise and GetExpertise()) or 0
    local _, armor = UnitArmor("player")
    stats[#stats + 1] = armor or 0
    stats[#stats + 1] = UnitHealthMax("player") or 0
    stats[#stats + 1] = UnitManaMax("player") or 0
    local weaponMin, weaponMax = UnitDamage("player")
    stats[#stats + 1] = weaponMin or 0
    stats[#stats + 1] = weaponMax or 0
    local mainSpeed = UnitAttackSpeed("player")
    stats[#stats + 1] = mainSpeed or 0
    local packed = {"2"}
    for _, value in ipairs(stats) do packed[#packed + 1] = string.format("%.4g", value or 0) end
    return table.concat(packed, ":")
end

-- Packs `parts` (an array of small strings, e.g. from PackOwned) into as few
-- `sep`-joined chunks as fit under CHUNK_LIMIT bytes each, sent as
-- <baseKey>_1, <baseKey>_2, ... plus <baseKey>_count so the reader on the
-- other end knows how many chunks to concatenate. Each chunk still goes
-- through SendChanged, so an unchanged chunk isn't re-sent. `sep` defaults
-- to ";" (echo_owned's format); callers whose parts might contain a literal
-- ";" (e.g. free-form tooltip text, see EchoTracker_ExportDescriptions)
-- should pass a control character instead, e.g. string.char(30), that can
-- never appear in real game text.
local CHUNK_LIMIT = 200

local function BuildChunks(parts, sep)
    sep = sep or ";"
    local chunks = {}
    local current = ""
    for _, part in ipairs(parts) do
        local candidate = (current == "") and part or (current .. sep .. part)
        if #candidate > CHUNK_LIMIT and current ~= "" then
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

local function SendChunked(baseKey, parts, sep)
    local chunks = BuildChunks(parts, sep)
    for i, chunk in ipairs(chunks) do
        SendChanged(baseKey .. "_" .. i, chunk)
    end
    SendChanged(baseKey .. "_count", #chunks)
end

--------------------------------------------------------------------------
-- Echo Journal search-box focus fix - root cause of TODO item #1 (wishlist
-- keybind doing nothing while hovering the Journal's Search/catalog grid,
-- even though it works everywhere else). Not an EchoTracker bug at all:
-- stock WoW never delivers a bound keypress to Bindings.xml while ANY
-- EditBox has keyboard focus (the box eats it as text input instead) - the
-- same reason "Screenshot" does nothing while you're typing in chat.
-- ProjectEbonholdEchoJournalSearchBox (echo_journal.lua, global-named frame)
-- never clears its own focus when the mouse leaves it, so after typing a
-- filter and moving onto a matching result, the box is STILL focused and
-- silently swallows the keybind - confirmed via source read, not a guess:
-- both the "My Echoes" and catalog/search grids share the exact same
-- CreateGridButton/UpdateGridButton/ShowEchoTooltip code (echo_journal.lua),
-- so a per-button difference was never plausible; only the search tab
-- routes you through typing into an EditBox first. Fix: drop the box's
-- focus the instant the mouse leaves it, so it can never still be focused
-- by the time you've moved over an echo to hover+toggle it. We don't own
-- that frame (it's the real ProjectEbonhold addon's), so this hooks the
-- global by name once it exists rather than editing that addon's files.
local searchBoxFocusFixed = false

local function HookJournalSearchBoxFocusFix()
    if searchBoxFocusFixed then
        return
    end
    local box = _G.ProjectEbonholdEchoJournalSearchBox
    if not box then
        return
    end
    searchBoxFocusFixed = true
    box:HookScript("OnLeave", function(self)
        if self:HasFocus() then
            self:ClearFocus()
        end
    end)
end

local function Refresh()
    HookJournalSearchBoxFocusFix()
    local PE = _G.ProjectEbonhold
    if not (PE and PE.PerkService) then
        return
    end
    sendBudgetRemaining = REFRESH_SEND_BUDGET

    local choices = PE.PerkService.GetCurrentChoice()
    local packedBoard = PackBoard(choices)
    SendChanged("echo_board", packedBoard)
    UpdateCardButtons(choices)

    local granted = PE.PerkService.GetGrantedPerks and PE.PerkService.GetGrantedPerks()
    local packedOwned = PackOwned(granted)
    SendChunked("echo_owned", packedOwned)

    local locked = PE.PerkService.GetLockedPerks and PE.PerkService.GetLockedPerks()
    SendChanged("echo_locked", PackLocked(locked))
    local maxLockSlots = PE.PerkService.GetMaximumPermanentEchoes and PE.PerkService.GetMaximumPermanentEchoes() or 0
    SendChanged("echo_locked_max", maxLockSlots)
    UpdateWishSlots(granted, locked)
    SendChunked("echo_icons", PackIcons(locked))
    SendChunked("echo_tips", PackTips(locked), TIP_PART_SEP)

    local charges = PE.PlayerRunService and PE.PlayerRunService.GetCurrentData
        and PE.PlayerRunService.GetCurrentData()
    SendChanged("echo_charges", PackCharges(charges))

    -- Status line replaced 2026-09-02 per user request ("in loc de 3 sa
    -- punem r,f,b status si cate board mai sunt") - R/F/B remaining
    -- charges + rolls left (GetPendingRollsCount - a real API, "Rolls
    -- left = (level - 1) - picksMade") instead of the current board's
    -- card count, since that's already obvious from how many icons are
    -- showing. This is persistent character state, shown regardless of
    -- whether a board is currently open.
    -- `charges` can be a non-nil but EMPTY table (e.g. right at login/
    -- reload, before PlayerRunService has synced real data from the
    -- server yet) - the `charges and (...)` guard only protects against
    -- charges itself being nil, not against individual fields being
    -- missing from an otherwise-present table. Default each field to 0.
    local rerollLeft = charges and ((charges.totalRerolls or 0) - (charges.usedRerolls or 0)) or 0
    local freezeLeft = charges and ((charges.totalFreezes or 0) - (charges.usedFreezes or 0)) or 0
    local banishLeft = charges and (charges.remainingBanishes or 0) or 0
    local rollsLeft = PE.PerkService.GetPendingRollsCount and PE.PerkService.GetPendingRollsCount() or 0
    SetStatus(string.format("R:%d F:%d B:%d #%d", rerollLeft, freezeLeft, banishLeft, rollsLeft))

    -- soulPoints/soulPointsMax are THIS RUN's earned-but-not-yet-committed
    -- soul points - the number "Accept Death" grants and the death screen
    -- shows (confirmed live: matched the 4,162,209 the user saw exactly).
    -- Distinct from PrestigeService's ash_committed (the SKILL TREE's
    -- cumulative committed pool, spent into specific nodes) and from real
    -- Prestige (ash_prestiges/ash_bonus_pct) - "Accept Death" is a
    -- routine per-run reset (PlayerRunService.AcceptDeath ->
    -- REQUEST_ACCEPT_DEATH) and does NOT increment ash_prestiges, which
    -- only moves on an actual PrestigeService.DoPrestige() (a separate,
    -- rarer, deliberately-triggered milestone action, REQUEST_DO_PRESTIGE)
    -- - confirmed live 2026-09-02 after ash_prestiges stayed at 40 across
    -- what looked like another prestige but was actually just another
    -- Accept Death reset.
    if charges then
        SendChanged("soul_points", charges.soulPoints or 0)
        SendChanged("soul_points_max", charges.soulPointsMax or 0)
    end

    local heroLevel = UnitLevel("player") or 0
    SendChanged("echo_level", heroLevel)
    -- Effective stats fluctuate constantly during combat because of short
    -- buffs/procs. Sending every fluctuation adds bridge traffic and DB rows
    -- without improving a board-decision model. Sample once when the actual
    -- decision context changes: character, level, offered board, or owned
    -- build. This still captures login, every new board, every pick, and
    -- every level while ignoring transient combat noise.
    local heroStatsContext = table.concat({
        UnitGUID("player") or "", tostring(heroLevel), packedBoard,
        table.concat(packedOwned, ";")
    }, "|")
    if heroStatsContext ~= lastHeroStatsContext then
        if SendChanged("hero_stats", PackHeroStats()) then
            lastHeroStatsContext = heroStatsContext
        end
    end

    -- Skill Tree / Prestige: a whole separate permanent-progression system
    -- (Soul Ashes spent on skill tree nodes, wiped by Prestige along with
    -- the run but grandfathering permanent/INFINITE nodes and granting a
    -- permanent ash-earn-rate bonus) that build_reports.json had zero
    -- visibility into - two very different sessions' DPS can't be compared
    -- as "which echoes were better" without knowing this too. No clean
    -- public getter exists for WHICH nodes are unlocked (skillTree.lua's
    -- nodeRanks/lastValidatedState are file-local Lua closures, not
    -- reachable from another addon without hooking ProjectEbonhold's own
    -- UI code - out of scope for a read-only reporter), but
    -- PrestigeService is a real public service (like PerkService) with
    -- exactly the totals that matter for build comparison.
    local PS = PE.PrestigeService
    if PS then
        SendChanged("ash_prestiges", PS.GetTotalPrestiges and PS.GetTotalPrestiges() or 0)
        SendChanged("ash_committed", PS.GetCommittedSoulAshes and PS.GetCommittedSoulAshes() or 0)
        local bonusPct = PS.GetPrestigeBonusPct and PS.GetPrestigeBonusPct() or 0
        SendChanged("ash_bonus_pct", string.format("%.1f", bonusPct * 100))
    end

    -- Class self-report: UnitClass is a plain stock Blizzard global, not a
    -- ProjectEbonhold API - closes half of "tools shouldn't need --class
    -- typed manually every run". Second return value is the locale-
    -- independent token (e.g. "PALADIN"), which is what score_echo_board.py
    -- expects on the command line - the localized display name (first
    -- return) is NOT used for this reason.
    local profile = PlayerProfile()
    if profile then
        SendChanged("echo_character_guid", profile.guid)
        SendChanged("echo_character_name", profile.name)
        SendChanged("echo_realm", profile.realm)
        SendChanged("echo_class", profile.class)
        SendChanged("echo_race", profile.race)
        SendChanged("echo_faction", profile.faction)
        SendChanged("echo_talent_spec", profile.talent)
        SendChanged("echo_role", profile.role)
        SendChanged("echo_profile", table.concat({profile.guid, profile.name,
            profile.realm, profile.class, profile.race, profile.faction,
            profile.talent, profile.role}, string.char(31)))
    end

    -- Hardmode/Torment difficulty tier (1=Normal, 2-6=Hardcore tiers, each
    -- with gold/xp/loot/soul-ash multipliers - HARDMODE_REWARDS in
    -- hardmode_service.lua). Tags each session with real difficulty
    -- context so DPS comparisons aren't apples-to-oranges (harder tier =
    -- harder mobs AND more soul ash income, not just "a better build"),
    -- and dying in tier 2+ forces the same Accept-Death/prestige flow that
    -- tier 1 only offers voluntarily. IsDifficultyKnown() guards against
    -- the stale tier-1 placeholder that persists until the server answers
    -- RequestHardmodeData after a /reload (per the module's own comment).
    local HS = PE.HardmodeService
    if HS and HS.IsDifficultyKnown and HS.IsDifficultyKnown() then
        SendChanged("hardmode_tier", HS.GetCurrentDifficulty and HS.GetCurrentDifficulty() or 1)
    end
end

--------------------------------------------------------------------------
-- One-time export: every catalog echo's tooltip description text, for
-- offline stat-priority classification (perks_data.lua's static
-- ProjectEbonhold.PerkDatabase carries family/quality/classMask but not
-- WHICH STAT an echo grants - that only lives in the tooltip, e.g.
-- "Increases Spirit by ..."). Uses utils.GetSpellDescription(spellId,
-- maxLength, stacks) - a real ProjectEbonhold global, gives back the
-- description with every @formula@ placeholder already resolved against
-- live player stats (real numbers, not raw formula text). Earlier version
-- of this used a bare global `GetSpellDescription()` that genuinely
-- doesn't exist on this client, then a GameTooltip-scraping workaround
-- that only captured the raw unresolved formula text - utils.lua's
-- namespaced version was found later and is strictly better than both.
--
-- Triggered via a short /api/cmd/lua call ("EchoTracker_ExportDescriptions()")
-- rather than sending the whole loop as one inbound command: /api/cmd/lua's
-- injected code has a hard ~210-byte budget (DataBridge's POLL request is a
-- fixed 220 bytes, and the SET reply is capped to match - anything longer
-- silently never delivers, no error, found live while testing single
-- tooltip lookups this way). A real function living in this file has no
-- such limit - only the trigger call needs to be short.
--
-- Results go out through BuildChunks/SendChunked's existing chunking (no
-- outbound size limit, already proven at echo_owned), but called directly
-- via ReportToBridge here instead of SendChanged - this is a deliberate
-- one-shot bulk action, not routine per-cycle chatter, so it intentionally
-- bypasses REFRESH_SEND_BUDGET (which exists to stop routine gameplay
-- events from bursting DataBridge's queue, not a one-time explicit export).
-- DataBridge's own outbound queue still paces the actual network sends
-- across polls regardless of how many keys get queued at once.
--------------------------------------------------------------------------

-- NOT string.char(29) (ASCII Group Separator) - that's DataBridge.lua's own
-- GROUP_SEP, and DataBridge_Send strips every occurrence of it out of a
-- value's payload before sending (gsub(GROUP_SEP, " ")), since it uses that
-- byte at the wire layer to pack multiple key=value pairs into one addon
-- message. Using it here too meant every id<GS>desc separator silently
-- turned into a space in transit - found live: every chunk arrived "ok"
-- but produced zero parseable id/desc pairs (0 total after 78+ chunks).
local EXPORT_ID_SEP = string.char(31)   -- ASCII Unit Separator - untouched by DataBridge_Send's sanitizer
local EXPORT_PART_SEP = string.char(30) -- ASCII Record Separator - joins id/desc parts within a chunk (not ";", since free-form tooltip text could contain one)

-- DataBridge's outboundQueue is a bounded FIFO (MAX_QUEUE=160,
-- DataBridge.lua) that silently EVICTS the oldest unsent entry once full,
-- rather than blocking or growing - fine for routine telemetry where a
-- stale dropped value doesn't matter, but a one-shot bulk export that needs
-- every chunk to survive can't just dump ~200-270 chunks into it at once
-- (seen live: only the LAST ~160 of 431 single-part chunks ever arrived,
-- everything queued before the cap silently vanished). Fix: drip-feed one
-- chunk per OnUpdate tick, gated on DataBridge_QueueLength() staying under
-- EXPORT_QUEUE_HEADROOM - keeps the queue from ever approaching MAX_QUEUE,
-- with room to spare for Refresh()'s own routine traffic running
-- concurrently. Total time is still bounded by DataBridge's real drain rate
-- (SEND_INTERVAL=0.15s), just paced instead of bursted.
local EXPORT_QUEUE_HEADROOM = 100
local exportState = nil

function EchoTracker_ExportDescriptions()
    local PE = _G.ProjectEbonhold
    if not (PE and PE.PerkDatabase) then
        print("|cffffcc00EchoTracker:|r ProjectEbonhold.PerkDatabase not available")
        return
    end
    if type(DataBridge_QueueLength) ~= "function" then
        print("|cffffcc00EchoTracker:|r DataBridge is out of date (no DataBridge_QueueLength) - redeploy it before exporting, or the queue cap will silently drop chunks")
        return
    end
    if exportState then
        print("|cffffcc00EchoTracker:|r export already in progress (" .. (exportState.nextIndex - 1) .. "/" .. #exportState.chunks .. "), not restarting")
        return
    end

    -- PIECE_LEN is the per-MESSAGE cap, just under DataBridge_Send's real
    -- ceiling (#key + 1 + #value <= 220; key is "echo_desc_NNN", ~13
    -- bytes) - one addon message can never carry more than this regardless
    -- of description length, so a description longer than PIECE_LEN gets
    -- split into multiple consecutive parts (same spellId, in order) that
    -- tools/export/export_perk_descriptions.py concatenates back together on
    -- read. Earlier versions truncated instead of splitting (85, then 195)
    -- and lost real tooltip text past the cap - splitting removes that
    -- limit entirely, at the cost of a few extra chunks for the rare long
    -- description. TOTAL_CAP is just a sanity ceiling against something
    -- pathological (a tooltip that's actually megabytes), not expected to
    -- ever trigger in practice.
    local PIECE_LEN = 195
    local TOTAL_CAP = 2048

    -- utils.GetSpellDescription(spellId, maxLength, stacks) - a genuine
    -- ProjectEbonhold global (utils.lua:7, "utils = {}", no `local`), used
    -- all over the real addon's own tooltips (perks.lua, echo_journal.lua,
    -- player_run_ui.lua). Resolves every @formula@ placeholder against the
    -- player's LIVE stats via CalculateStatFormula (e.g. "Increases
    -- Strength by 64.2", not the raw "@flat10+lvl0.2@" GameTooltipTextLeft2
    -- scraping used to capture) - real numbers, scaled to this character,
    -- not a formula string. Uses its own self-contained hidden tooltip
    -- frame internally, so no GameTooltip:SetOwner/Hide needed here at all
    -- (previously required for the old scrape method). stacks=1 since this
    -- is describing a catalog-wide BOARD OFFER, not an owned stack count.
    local utils = _G.utils
    local parts = {}
    for spellId in pairs(PE.PerkDatabase) do
        local desc = (utils and utils.GetSpellDescription and utils.GetSpellDescription(spellId, TOTAL_CAP, 1)) or ""
        -- Strip WoW color escape codes (|cffRRGGBB...|r) GetSpellDescription
        -- wraps around each resolved value - the regex classifier
        -- downstream (classify_echo_stats.py) expects plain text like
        -- "Increases Strength by 64.2", not "...by |cff2cfe3264.2|r".
        desc = desc:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
        if #desc > TOTAL_CAP then
            desc = string.sub(desc, 1, TOTAL_CAP)
        end
        if #desc == 0 then
            table.insert(parts, spellId .. EXPORT_ID_SEP .. "")
        else
            local pos = 1
            while pos <= #desc do
                table.insert(parts, spellId .. EXPORT_ID_SEP .. string.sub(desc, pos, pos + PIECE_LEN - 1))
                pos = pos + PIECE_LEN
            end
        end
    end

    local chunks = BuildChunks(parts, EXPORT_PART_SEP)
    -- Count sent FIRST (not last, as before) so a reader polling for it
    -- (tools/export/export_perk_descriptions.py) knows immediately how many
    -- chunks to expect. The chunks themselves are NOT sent here - see
    -- exportState/EXPORT_QUEUE_HEADROOM above, drained one per OnUpdate
    -- tick by the main OnUpdate handler below.
    ReportToBridge("echo_desc_count", #chunks)
    exportState = {chunks = chunks, nextIndex = 1, keyPrefix = "echo_desc_", label = "description"}
    print("|cffffcc00EchoTracker:|r exporting " .. #parts .. " descriptions across " .. #chunks .. " chunk(s), draining in background...")
end

-- One-time export: every catalog echo's icon key + display name, the same
-- catalog-wide sweep as EchoTracker_ExportDescriptions above, feeding
-- data/perk_display.json (tools/export/export_perk_icons.py) instead of
-- data/perk_descriptions.json. Board choices' icon/name never vary with
-- context (unlike description text, which can depend on stack count for
-- locked echoes) so this one static file, re-run only when the catalog
-- itself changes, is all FlaskGUI needs for board+locked icon/name display -
-- see PackIcons's own comment on why echo_icons_N now only covers the ~6
-- locked slots live.
function EchoTracker_ExportIcons()
    local PE = _G.ProjectEbonhold
    if not (PE and PE.PerkDatabase) then
        print("|cffffcc00EchoTracker:|r ProjectEbonhold.PerkDatabase not available")
        return
    end
    if type(DataBridge_QueueLength) ~= "function" then
        print("|cffffcc00EchoTracker:|r DataBridge is out of date (no DataBridge_QueueLength) - redeploy it before exporting, or the queue cap will silently drop chunks")
        return
    end
    if exportState then
        print("|cffffcc00EchoTracker:|r export already in progress (" .. (exportState.nextIndex - 1) .. "/" .. #exportState.chunks .. "), not restarting")
        return
    end

    local parts = {}
    for spellId in pairs(PE.PerkDatabase) do
        local name, _, icon = GetSpellInfo(spellId)
        local key = ""
        if icon then
            local base = tostring(icon):match("([^\\/]+)$") or tostring(icon)
            base = base:gsub("%.%a+$", "")
            key = base:lower():gsub("[^%w_]", "")
        end
        table.insert(parts, spellId .. EXPORT_ID_SEP .. key .. EXPORT_ID_SEP .. (name or ""))
    end

    local chunks = BuildChunks(parts, EXPORT_PART_SEP)
    ReportToBridge("echo_icon_count", #chunks)
    exportState = {chunks = chunks, nextIndex = 1, keyPrefix = "echo_icon_", label = "icon"}
    print("|cffffcc00EchoTracker:|r exporting " .. #parts .. " icons across " .. #chunks .. " chunk(s), draining in background...")
end

-- Callable from outside via /api/cmd/lua ("EchoTracker_ForceRefresh()") to
-- recover if the bridge's server-side cache ever gets out of sync with what
-- EchoTracker last legitimately sent - e.g. POST /api/read/<key> whispering
-- a bogus tostring(<nonexistent global>) into the same key namespace
-- EchoTracker reports through, which SendChanged has no way to detect since
-- it only compares against its OWN last-sent value, not the server's cache.
function EchoTracker_ForceRefresh()
    lastSent = {}
    Refresh()
end

--------------------------------------------------------------------------
-- Polling. A board present is polled faster since state can change quickly
-- (reroll/select), otherwise a slower idle poll is plenty - this only reads
-- local tables ProjectEbonhold already maintains, no server round-trip.
--------------------------------------------------------------------------

-- One-time default keybind for the wishlist toggle (CTRL-SHIFT-NUMPAD0 -
-- unlikely to collide with anything else). There's no "default key" field
-- in Bindings.xml on this client, unlike retail - an addon has to actually
-- call SetBinding() itself. Only ever does this ONCE per account
-- (EchoTrackerDB.wishlistDefaultBindSet) - if the player rebinds or
-- explicitly clears it afterward, this must never fight back and reassert
-- the default on a later login.
local function EnsureDefaultWishlistBinding()
    EchoTrackerDB = EchoTrackerDB or {}
    if EchoTrackerDB.wishlistDefaultBindSet then
        return
    end
    EchoTrackerDB.wishlistDefaultBindSet = true
    if not GetBindingKey("ECHOTRACKER_WISHLIST_TOGGLE") then
        SetBinding("CTRL-SHIFT-NUMPAD0", "ECHOTRACKER_WISHLIST_TOGGLE")
        SaveBindings(GetCurrentBindingSet())
        print("|cffffcc00EchoTracker:|r default keybind set: CTRL+SHIFT+Numpad0 = Toggle Wishlist (hovered echo). Change it anytime in Key Bindings > Echo Tracker.")
    end
end

frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("PLAYER_LEAVING_WORLD")
frame:RegisterEvent("PLAYER_LEVEL_UP")
local playerInWorld = false
frame:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_LEAVING_WORLD" then
        playerInWorld = false
        ReportToBridge("echo_in_world", "0")
        return
    elseif event == "PLAYER_ENTERING_WORLD" then
        playerInWorld = true
        ReportToBridge("echo_in_world", "1")
    end
    EnsureDisplay()
    EnsureAutoState()
    EnsureDefaultWishlistBinding()
    if playerInWorld then Refresh() end
end)

frame:SetScript("OnUpdate", function(self, elapsed)
    pollElapsed = pollElapsed + elapsed
    local PE = _G.ProjectEbonhold
    local hasBoard = PE and PE.PerkService and PE.PerkService.GetCurrentChoice and PE.PerkService.GetCurrentChoice()
    local interval = hasBoard and 0.20 or 0.75
    if playerInWorld and pollElapsed >= interval then
        pollElapsed = 0
        Refresh()
    end

    if exportState and DataBridge_QueueLength() < EXPORT_QUEUE_HEADROOM then
        local i = exportState.nextIndex
        if i <= #exportState.chunks then
            ReportToBridge(exportState.keyPrefix .. i, exportState.chunks[i])
            exportState.nextIndex = i + 1
        else
            print("|cffffcc00EchoTracker:|r " .. exportState.label .. " export complete (" .. #exportState.chunks .. " chunk(s))")
            exportState = nil
        end
    end
end)

-- No /echoauto slash command anymore - removed 2026-09-02, per explicit
-- user request ("sa fie activat doar din companion"). echo_auto is now
-- controllable ONLY via `companion echo-toggle on|off`
-- (or tools/live/echo_toggle.py) - see DataBridge_OnValue above for how
-- this addon learns the value, purely as an observer.
