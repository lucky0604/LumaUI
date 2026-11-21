local _, app = ...

-- Unit display is split into parts. Each part declares:
--   available()    client capability probe, evaluated on every enable
--   height         extra frame height the part needs (optional)
--   events         unit-scoped event names, merged into frame.events
--   globalEvents   global event names, registered on every frame
--   create(frame)  builds the part controls, hidden by default
--   draw(frame)    refreshes the controls from the current unit
-- A part whose capability is missing stays unavailable: its events are not
-- registered, its draw never runs and its controls are never created, while
-- the unitFrames component keeps running. Native unit frames, cast bars and
-- private auras are never hidden or replaced by any part.
--
-- Secret rules: unit values and API payloads reach native drawing methods
-- directly (SetText/SetFormattedText/SetTexture/SetColorTexture/SetTexCoord/
-- SetStatusBarColor/SetVertexColor/SetMinMaxValues/SetValue). Restricted
-- values never take part in Lua arithmetic, ordering comparisons,
-- concatenation or persistence here; Plain() guards every value a decision
-- depends on. Visibility changes only happen when the state actually flips,
-- so resting controls are never touched again.

local AURA_LIMIT = 10
local AURA_SCAN = 24
-- Dispel types are public strings on the aura data; they colour the icon's
-- border so a removable debuff is obvious at a glance.
local DISPEL_COLORS = {
    Magic = { 0.25, 0.62, 1.00 },
    Curse = { 0.62, 0.40, 1.00 },
    Disease = { 0.72, 0.52, 0.22 },
    Poison = { 0.35, 0.90, 0.42 },
}
local CAST_LOCKED_COLOR = { 0.90, 0.28, 0.25 }
local CHANNEL_COLOR = { 0.30, 0.80, 0.45 }
-- Empower ("press and hold") casts get their own fill so a charged cast is not
-- mistaken for a normal one.
local EMPOWER_COLOR = { 1, 0.68, 0.32 }

--------------------------------------------------------------------
-- bars: name, health and power (migrated from the previous draw step)
--------------------------------------------------------------------

local function barsAvailable()
    return type(UnitHealth) == "function" and type(UnitHealthMax) == "function"
        and type(UnitPower) == "function" and type(UnitPowerMax) == "function"
end

-- One writer for the unit value texts. Restricted values keep the plain
-- engine path: SetFormattedText never lets the number into Lua. Public values
-- go through the client's own localizing formatter ("148万" style) when the
-- build provides it — the formatter never receives a restricted value — and
-- fall back to the plain "%d" path when it is missing or fails.
local function writeValue(control, value)
    if not control then return end
    if app.Capabilities.IsSecret(value) then
        control:SetFormattedText("%d", value)
        return
    end
    local abbreviate = _G.AbbreviateLargeNumbers
    if type(abbreviate) == "function" then
        local ok, text = pcall(abbreviate, value)
        if ok and text ~= nil then
            control:SetText(text)
            return
        end
    end
    control:SetFormattedText("%d", value)
end

local bars = {
    id = "bars",
    available = barsAvailable,
    events = { "UNIT_HEALTH", "UNIT_MAXHEALTH", "UNIT_POWER_UPDATE", "UNIT_MAXPOWER", "UNIT_NAME_UPDATE",
        "UNIT_DISPLAYPOWER", "UNIT_FLAGS", "UNIT_CONNECTION" },
    create = function(frame)
        frame.name = app.Theme:Text(frame, 13)
        frame.name:SetPoint("TOPLEFT", 12, -10)
        frame.name:SetWidth(146)
        -- Without a panel behind it the name floats over the world; a shadow
        -- keeps it readable on bright ground.
        if type(frame.name.SetShadowOffset) == "function" then
            pcall(frame.name.SetShadowOffset, frame.name, 1, -1)
        end
        if type(frame.name.SetShadowColor) == "function" then
            pcall(frame.name.SetShadowColor, frame.name, 0, 0, 0, 0.85)
        end
        frame.health = app.Theme:Bar(frame, 19)
        frame.health:SetPoint("TOPLEFT", 10, -31)
        frame.health:SetPoint("TOPRIGHT", -10, -31)
        frame.value = app.Theme:Text(frame.health, 11)
        frame.value:SetPoint("RIGHT", -4, 0)
        -- Death and disconnection are part of the native frame; the preview says
        -- so on the bar instead of silently showing a full health bar.
        frame.statusText = app.Theme:Text(frame.health, 11)
        frame.statusText:SetPoint("CENTER")
        frame.statusText:SetText("")
        frame.power = app.Theme:Bar(frame, 4)
        frame.power:SetPoint("TOPLEFT", 10, -54)
        frame.power:SetPoint("TOPRIGHT", -10, -54)
        frame.power:SetStatusBarColor(0.40, 0.58, 0.84)
        frame.powerValue = app.Theme:Text(frame.power, 10)
        frame.powerValue:SetPoint("RIGHT", -4, 0)
    end,
    draw = function(frame)
        local unit = frame.unitToken
        if not UnitExists(unit) then return end
        frame.name:SetText(UnitName(unit))
        -- Secret values go straight to native drawing methods, without Lua arithmetic.
        frame.health:SetMinMaxValues(0, UnitHealthMax(unit))
        frame.health:SetValue(UnitHealth(unit))
        writeValue(frame.value, UnitHealth(unit))
        -- Health fills with the unit's class or reaction pair; the power bar
        -- with its power type's pair. Both bases come from public unit
        -- identity APIs, never from the secret health or power values.
        app.Theme:PaintBar(frame.health, app.Theme:UnitColor(unit))
        frame.power:SetMinMaxValues(0, UnitPowerMax(unit))
        frame.power:SetValue(UnitPower(unit))
        writeValue(frame.powerValue, UnitPower(unit))
        app.Theme:PaintBar(frame.power, app.Theme:PowerColor(unit))
        -- Death/offline: only plain booleans become text; a restricted flag
        -- leaves the status empty instead of guessing.
        local dead = false
        if type(UnitIsDeadOrGhost) == "function" then
            local ok, value = pcall(UnitIsDeadOrGhost, unit)
            dead = ok and app.Capabilities.Plain(value, "boolean") == true
        elseif type(UnitIsDead) == "function" then
            local ok, value = pcall(UnitIsDead, unit)
            dead = ok and app.Capabilities.Plain(value, "boolean") == true
        end
        local connected = true
        if type(UnitIsConnected) == "function" then
            local ok, value = pcall(UnitIsConnected, unit)
            connected = not (ok and app.Capabilities.Plain(value, "boolean") == false)
        end
        if dead then
            frame.statusText:SetText(app.L.unitDead)
            frame.statusText:SetTextColor(0.95, 0.45, 0.42, 1)
        elseif not connected then
            frame.statusText:SetText(app.L.unitOffline)
            local muted = app.Theme.colors.muted
            frame.statusText:SetTextColor(muted[1], muted[2], muted[3], 1)
        else
            frame.statusText:SetText("")
        end
    end,
}

--------------------------------------------------------------------
-- cast: spell name and remaining seconds, red when not interruptible
--------------------------------------------------------------------

local function castAvailable()
    return type(UnitCastingInfo) == "function" and type(UnitChannelInfo) == "function"
end

-- Reads the active cast or channel into a plain table. Documented return order
-- (12.1.5 baseline): UnitCastingInfo = name, displayName, texture, startMs,
-- endMs, isTradeskill, castID, notInterruptible, spellID, castBarID, delayMs;
-- UnitChannelInfo = ..., notInterruptible, spellID, isEmpowered, numStages,
-- castBarID. The name may be restricted and is only ever handed to SetText.
-- Cast times are public, so they may be compared through Plain.
local function isEmpoweredSpell(spellID)
    if type(C_Spell) ~= "table" or type(C_Spell.IsPressHoldReleaseSpell) ~= "function" then return false end
    local id = app.Capabilities.Plain(spellID, "number")
    if not id then return false end
    local ok, value = pcall(C_Spell.IsPressHoldReleaseSpell, id)
    return ok and value == true
end

local function readCast(unit)
    if type(UnitCastingInfo) == "function" then
        local ok, name, _, _, startTime, endTime, _, _, notInterruptible, spellID =
            pcall(UnitCastingInfo, unit)
        if ok and name then
            return {
                name = name, startTime = startTime, endTime = endTime,
                notInterruptible = notInterruptible, channel = false,
                empowered = isEmpoweredSpell(spellID),
            }
        end
    end
    if type(UnitChannelInfo) == "function" then
        local ok, name, _, _, startTime, endTime, _, notInterruptible, _, isEmpowered =
            pcall(UnitChannelInfo, unit)
        if ok and name then
            return {
                name = name, startTime = startTime, endTime = endTime,
                notInterruptible = notInterruptible, channel = true,
                empowered = app.Capabilities.Plain(isEmpowered, "boolean") == true,
            }
        end
    end
end

local cast = {
    id = "cast",
    available = castAvailable,
    height = 14,
    events = {
        "UNIT_SPELLCAST_START", "UNIT_SPELLCAST_STOP", "UNIT_SPELLCAST_FAILED", "UNIT_SPELLCAST_DELAYED",
        "UNIT_SPELLCAST_INTERRUPTED", "UNIT_SPELLCAST_FAILED_QUIET",
        "UNIT_SPELLCAST_INTERRUPTIBLE", "UNIT_SPELLCAST_NOT_INTERRUPTIBLE",
        "UNIT_SPELLCAST_CHANNEL_START", "UNIT_SPELLCAST_CHANNEL_UPDATE", "UNIT_SPELLCAST_CHANNEL_STOP",
        "UNIT_SPELLCAST_EMPOWER_START", "UNIT_SPELLCAST_EMPOWER_UPDATE", "UNIT_SPELLCAST_EMPOWER_STOP",
    },
    create = function(frame)
        frame.cast = app.Theme:Bar(frame, 6)
        frame.cast:SetPoint("TOPLEFT", 10, -62)
        frame.cast:SetPoint("TOPRIGHT", -10, -62)
        frame.castName = app.Theme:Text(frame.cast, 10)
        frame.castName:SetPoint("LEFT", 4, 0)
        frame.castTime = app.Theme:Text(frame.cast, 10)
        frame.castTime:SetPoint("RIGHT", -4, 0)
        frame.cast:Hide()
    end,
    draw = function(frame)
        local unit = frame.unitToken
        local cast = frame.cast
        if not cast then return end
        local function stopUpdates()
            if cast.updater then cast.updater:Cancel(); cast.updater = nil end
        end
        local function hideCast()
            stopUpdates()
            cast.signature = nil
            if cast:IsShown() then cast:Hide() end
        end
        if not UnitExists(unit) then hideCast(); return end
        local info = readCast(unit)
        if not info then hideCast(); return end
        -- Even a restricted spell name is only ever sent to SetText.
        frame.castName:SetText(info.name)
        -- Progress and remaining time are public cast times; restricted or
        -- missing numbers leave the bar empty with only the spell name.
        local startValue = app.Capabilities.Plain(info.startTime, "number")
        local endValue = app.Capabilities.Plain(info.endTime, "number")
        local now = app.Capabilities.Plain(GetTime(), "number")
        local channel = info.channel == true
        local empowered = info.empowered == true
        local span = (startValue and endValue and endValue > startValue) and (endValue - startValue) or nil
        local signature
        if span then
            -- Identity of the running cast: the same times mean "same cast", so
            -- state events (interruptible toggles, health ticks) never recreate
            -- the ticker. The spell name is never part of this key (it may be
            -- restricted and must not be compared).
            signature = string.format("%.0f:%.0f:%s:%s", startValue, endValue,
                channel and "c" or "s", empowered and "e" or "-")
        end
        cast:SetMinMaxValues(0, 1)
        cast:SetValue(span and now and math.max(0, math.min(1, (now * 1000 - startValue) / span)) or 0)
        if endValue and now then
            frame.castTime:SetFormattedText(app.L.castSeconds, math.max(0, (endValue - now * 1000) / 1000))
        else
            frame.castTime:SetText("")
        end
        -- The fill runs the accent pair; locked casts the red pair, empowers the
        -- amber one and channels the green one. Bases are theme constants.
        if app.Capabilities.Plain(info.notInterruptible) == true then
            app.Theme:PaintBar(cast, CAST_LOCKED_COLOR)
        elseif empowered then
            app.Theme:PaintBar(cast, EMPOWER_COLOR)
        elseif channel then
            app.Theme:PaintBar(cast, CHANNEL_COLOR)
        else
            app.Theme:PaintBar(cast, app.Theme:Accent())
        end
        if not cast:IsShown() then cast:Show() end
        if signature and cast.signature == signature and cast.updater then
            -- Same cast: keep the running ticker and only refresh name/colours.
            return
        end
        -- A new cast (or the first one): one short ticker, cancelled the moment
        -- it ends; never a permanent loop and never one per unit redraw.
        -- The client also documents StatusBar:SetTimerDuration(LuaDurationObject,
        -- interpolation, direction); creating that duration object reliably is
        -- left for an in-game follow-up, so the ticker stays the tested path.
        stopUpdates()
        cast.signature = signature
        if span and type(C_Timer) == "table" and type(C_Timer.NewTicker) == "function" then
            cast.updater = C_Timer.NewTicker(0.05, function()
                local tick = app.Capabilities.Plain(GetTime(), "number")
                if not tick or not cast.updater then return end
                cast:SetValue(math.max(0, math.min(1, (tick * 1000 - startValue) / span)))
                if endValue then
                    frame.castTime:SetFormattedText(app.L.castSeconds, math.max(0, (endValue - tick * 1000) / 1000))
                end
            end)
        end
    end,
}

--------------------------------------------------------------------
-- auras: debuffs first, then buffs, one 16px icon row
--------------------------------------------------------------------

local function aurasAvailable()
    return type(C_UnitAuras) == "table" and type(C_UnitAuras.GetAuraDataByIndex) == "function"
end

-- Fills icon slots from one filter until the API returns nil, the scan cap or
-- the icon limit is reached. AuraData.icon is documented as a fileID on current
-- builds and has historically also been a texture path, so both a plain number
-- and a plain string are legitimate inputs for SetTexture. Stack counts and
-- remaining times are public values and become text.
local function auraIcon(aura)
    local icon = aura.icon
    -- A restricted icon is never compared, converted or concatenated; it simply
    -- stays off the Lua drawing path, which is the documented safe behaviour.
    if app.Capabilities.IsSecret(icon) then return nil end
    if type(icon) == "number" or type(icon) == "string" then return icon end
    return nil
end

-- Collects one filter into a plain list first, so ordering can be decided
-- before slots are painted. The profile filter only hides harmful auras whose
-- school has no dispel type; it never claims this character can dispel them.
local function auraList(unit, filter, onlyDispel)
    local read = C_UnitAuras and C_UnitAuras.GetAuraDataByIndex
    if type(read) ~= "function" then return nil end
    local list = {}
    for index = 1, AURA_SCAN do
        local ok, aura = pcall(read, unit, index, filter)
        if not ok or type(aura) ~= "table" then break end
        local texture = auraIcon(aura)
        if texture then
            local dispel = app.Capabilities.Plain(aura.dispelName, "string")
            if not (onlyDispel and filter == "HARMFUL" and not DISPEL_COLORS[dispel]) then
                list[#list + 1] = {
                    icon = texture, dispel = dispel, harmful = filter == "HARMFUL",
                    applications = app.Capabilities.Plain(aura.applications, "number"),
                    expiration = app.Capabilities.Plain(aura.expirationTime, "number"),
                    duration = app.Capabilities.Plain(aura.duration, "number"),
                }
            end
        end
    end
    return list
end

-- Sorts by remaining time only when every visible aura exposes a plain
-- expiration. One restricted value keeps the client's own order: comparing a
-- secret is not allowed and a partial sort would look arbitrary.
local function sortAuras(list)
    if #list < 2 then return list end
    for _, aura in ipairs(list) do
        if not aura.expiration then return list end
    end
    local sorted = {}
    for index, aura in ipairs(list) do sorted[index] = aura end
    table.sort(sorted, function(a, b) return a.expiration < b.expiration end)
    return sorted
end

local function paintAura(aura, icon)
    icon:SetTexture(aura.icon)
    -- Keep the spell art: tinting every icon by harmful/helpful made the whole
    -- row read as coloured blocks. The school colour belongs to the border.
    if type(icon.SetVertexColor) == "function" then icon:SetVertexColor(1, 1, 1, 1) end
    -- A dispel-type school gets its colour border; that is a visual hint, not a
    -- statement about the player's own dispel abilities.
    local border = icon.border
    if border then
        local color = aura.harmful and DISPEL_COLORS[aura.dispel]
        if color then
            border:SetBackdropBorderColor(color[1], color[2], color[3], 1)
            if not border:IsShown() then border:Show() end
        elseif border:IsShown() then
            border:Hide()
        end
    end
    icon.count:SetText(aura.applications and aura.applications > 1 and tostring(aura.applications) or "")
    -- Permanent auras report expiration 0; treating that as a timer printed a
    -- "0" over every icon and started the ticker for no reason.
    icon.expiration = (aura.expiration and aura.expiration > 0) and aura.expiration or nil
    icon.duration = aura.duration
    icon.time:SetText("")
    if not icon:IsShown() then icon:Show() end
end

-- "12", "1m", "1h": remaining time in the compact form used by aura rows.
-- A non-positive value is "no countdown", not "0".
local function timeText(seconds)
    seconds = math.floor(seconds)
    if seconds <= 0 then return "" end
    if seconds < 60 then return string.format("%d", seconds) end
    if seconds < 3600 then return string.format("%dm", math.floor(seconds / 60)) end
    return string.format("%dh", math.floor(seconds / 3600))
end

-- Refreshes the remaining-time labels of the visible icons.
local function updateAuraTimes(frame)
    local now = app.Capabilities.Plain(GetTime(), "number")
    if not now then return end
    for _, icon in ipairs(frame.auraIcons or {}) do
        if icon:IsShown() and icon.expiration and icon.expiration > 0 then
            icon.time:SetText(timeText(icon.expiration - now))
        end
    end
end

-- A one-second ticker only while at least one visible aura is time based.
local function syncAuraTicker(frame, anyTimed)
    if anyTimed then
        if not frame.auraTicker and type(C_Timer) == "table" and type(C_Timer.NewTicker) == "function" then
            frame.auraTicker = C_Timer.NewTicker(1, function()
                if frame.auraTicker then updateAuraTimes(frame) end
            end)
        end
        updateAuraTimes(frame)
    elseif frame.auraTicker then
        frame.auraTicker:Cancel()
        frame.auraTicker = nil
    end
end

local auras = {
    id = "auras",
    available = aurasAvailable,
    height = 26,
    events = { "UNIT_AURA" },
    create = function(frame)
        frame.auraIcons = {}
        -- Below the cast bar when that part exists, otherwise below power.
        local anchor = frame.cast and -72 or -62
        for index = 1, AURA_LIMIT do
            local icon = frame:CreateTexture(nil, "ARTWORK")
            icon:SetSize(16, 16)
            icon:SetPoint("TOPLEFT", 12 + (index - 1) * 18, anchor)
            icon:SetTexture(app.Theme.white)
            icon:Hide()
            -- A border frame in the debuff's dispel colour, hidden by default.
            local border = CreateFrame("Frame", nil, frame, "BackdropTemplate")
            border:SetBackdrop({ edgeFile = app.Theme.white, edgeSize = 1,
                insets = { left = 1, right = 1, top = 1, bottom = 1 } })
            border:SetPoint("TOPLEFT", icon, "TOPLEFT", -1, 1)
            border:SetPoint("BOTTOMRIGHT", icon, "BOTTOMRIGHT", 1, -1)
            border:EnableMouse(false)
            border:Hide()
            icon.border = border
            icon.count = app.Theme:Text(frame, 10, false)
            icon.count:SetPoint("BOTTOMRIGHT", icon, "BOTTOMRIGHT", 2, -1)
            icon.count:SetText("")
            -- The countdown is small and clipped to the icon so a "59m" never
            -- runs into the next icon.
            icon.time = app.Theme:Text(frame, 8, false)
            icon.time:SetPoint("TOP", icon, "TOP", 0, -1)
            icon.time:SetWidth(18)
            icon.time:SetJustifyH("CENTER")
            icon.time:SetText("")
            frame.auraIcons[index] = icon
        end
    end,
    draw = function(frame)
        local icons = frame.auraIcons
        if not icons then return end
        local unit = frame.unitToken
        local shown = 0
        -- The capability is re-checked here so a mid-session API loss simply
        -- empties the row instead of erroring.
        if UnitExists(unit) and aurasAvailable() then
            local onlyDispel = app.Store:Profile().ui.auraFilter == "dispel"
            local harmful = sortAuras(auraList(unit, "HARMFUL", onlyDispel) or {})
            local helpful = sortAuras(auraList(unit, "HELPFUL", onlyDispel) or {})
            for _, aura in ipairs(harmful) do
                if shown >= AURA_LIMIT then break end
                shown = shown + 1
                paintAura(aura, icons[shown])
            end
            for _, aura in ipairs(helpful) do
                if shown >= AURA_LIMIT then break end
                shown = shown + 1
                paintAura(aura, icons[shown])
            end
        end
        local anyTimed = false
        for index = 1, #icons do
            local icon = icons[index]
            if index <= shown then
                if icon.expiration and icon.expiration > 0 then anyTimed = true end
            elseif icon:IsShown() then
                icon:Hide()
                icon.count:SetText("")
                icon.time:SetText("")
                icon.expiration = nil
                icon.duration = nil
                if icon.border then icon.border:Hide() end
            end
        end
        syncAuraTicker(frame, anyTimed)
    end,
}

--------------------------------------------------------------------
-- marks: the raid target icon, top right, classic 4x2 grid
--------------------------------------------------------------------

local function marksAvailable()
    return type(GetRaidTargetIndex) == "function"
end

local marks = {
    id = "marks",
    available = marksAvailable,
    events = {},
    globalEvents = { "RAID_TARGET_UPDATE" },
    create = function(frame)
        frame.mark = frame:CreateTexture(nil, "ARTWORK")
        -- Atlas path and grid math to be confirmed during in-game validation.
        frame.mark:SetTexture("Interface\\RaidFrame\\Raid-TargetIcons")
        frame.mark:SetSize(18, 18)
        frame.mark:SetPoint("TOPRIGHT", -4, -4)
        frame.mark:Hide()
    end,
    draw = function(frame)
        if not frame.mark then return end
        local unit = frame.unitToken
        local index
        if type(GetRaidTargetIndex) == "function" and UnitExists(unit) then
            local ok, value = pcall(GetRaidTargetIndex, unit)
            if ok then index = app.Capabilities.Plain(value, "number") end
        end
        -- Only plain numbers in 1..8 map to the icon grid; anything else,
        -- including restricted values, hides the mark.
        if not index or index < 1 or index > 8 then
            if frame.mark:IsShown() then frame.mark:Hide() end
            return
        end
        local column = (index - 1) % 4
        local row = math.floor((index - 1) / 4)
        local left = column * 0.25
        local top = row * 0.25
        frame.mark:SetTexCoord(left, left + 0.25, top, top + 0.25)
        if not frame.mark:IsShown() then frame.mark:Show() end
    end,
}

--------------------------------------------------------------------
-- interaction: secure click attributes and hover unit tooltip
--------------------------------------------------------------------

local interaction = {
    id = "interaction",
    events = {},
    create = function(frame)
        local unit = frame.unitToken
        frame:RegisterForClicks("AnyUp")
        frame:SetAttribute("unit", unit)
        frame:SetAttribute("*type1", "target")
        frame:SetAttribute("*type2", "togglemenu")
        frame:SetScript("OnEnter", function(self)
            local tooltip = GameTooltip
            if tooltip and type(tooltip.SetUnit) == "function" and not tooltip:IsForbidden() then
                pcall(function()
                    tooltip:SetUnit(self.unitToken)
                    tooltip:Show()
                end)
            end
        end)
        frame:SetScript("OnLeave", function()
            local tooltip = GameTooltip
            if tooltip and type(tooltip.ClearLines) == "function" and not tooltip:IsForbidden() then
                pcall(function()
                    tooltip:ClearLines()
                    tooltip:Hide()
                end)
            end
        end)
    end,
    draw = function() end,
}

app.UnitParts = { bars = bars, cast = cast, auras = auras, marks = marks, interaction = interaction }

local order = { "bars", "cast", "auras", "marks", "interaction" }

-- Builds the per-enable part table: every part carries the result of its
-- capability probe and active lists the parts the component should create,
-- register and draw, in layout order.
function app.UnitParts.Build()
    local built = { active = {} }
    for _, id in ipairs(order) do
        local part = app.UnitParts[id]
        local available = true
        if type(part.available) == "function" then
            local ok, result = pcall(part.available)
            available = ok and result == true
        end
        built[id] = {
            id = id,
            available = available,
            height = part.height,
            events = part.events,
            globalEvents = part.globalEvents,
            create = part.create,
            draw = part.draw,
        }
        if available then built.active[#built.active + 1] = built[id] end
    end
    return built
end
