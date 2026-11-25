local _, app = ...

-- The player's main resource as its own central HUD layer: one thin continuous
-- rail above the skill rows, plus a shorter secondary rail only when the class
-- really reports a second resource (combo points, runes, soul shards, ...).
--
-- This is LumaUI's own StatusBar, so the client's values go straight into
-- SetMinMaxValues/SetValue: nothing here divides, compares, concatenates or
-- stores a health/power number. A restricted value that Lua cannot read is
-- either passed through untouched (the primary rail) or leaves the secondary
-- rail hidden, because detecting "is there a second resource" needs a readable
-- maximum.
--
-- The native personal resource display and the native cast bar stay untouched;
-- this component only adds the summary rail the mockup shows above the skills.

local RAIL_HEIGHT = 6
local SECONDARY_HEIGHT = 3
local SECONDARY_GAP = 2
-- 012 phase 08: death knight runes as six own segments. Per-rune recovery is
-- what a continuous 0..6 rail cannot express, so each rune gets its own small
-- StatusBar fed by GetRuneCooldown. The native rune row keeps drawing until the
-- player explicitly chooses the own row (`/luma runes`).
local RUNE_COUNT = 6
local RUNE_WIDTH, RUNE_HEIGHT, RUNE_GAP = 11, 7, 2
local RUNE_GAP_TOP = 2

local function classToken()
    if type(UnitClass) ~= "function" then return nil end
    local ok, _, token = pcall(UnitClass, "player")
    return ok and app.Capabilities.Plain(token, "string") or nil
end

-- Power types that read as a class resource rather than the primary bar. The
-- client exposes them through `Enum.PowerType`; the numeric fallbacks are the
-- long-standing values and are only used when the enum is missing.
local SECONDARY_TYPES = {
    "ComboPoints", "Runes", "RunicPower", "SoulShards", "Chi", "ArcaneCharges",
    "Fury", "Pain", "Essence", "Maelstrom",
}
local SECONDARY_FALLBACK = {
    ComboPoints = 4, Runes = 5, RunicPower = 6, SoulShards = 7, Chi = 12,
    ArcaneCharges = 16, Fury = 17, Pain = 13, Essence = 19, Maelstrom = 11,
}

local component

local function plain(value, expected)
    return app.Capabilities.Plain(value, expected)
end

local function secondaryType()
    local enum = _G.Enum and _G.Enum.PowerType
    local primary = UnitPowerType("player")
    primary = plain(primary, "number")
    for _, key in ipairs(SECONDARY_TYPES) do
        local kind = enum and enum[key] or SECONDARY_FALLBACK[key]
        kind = plain(kind, "number")
        if kind and kind ~= primary then
            local maximum = plain(UnitPowerMax("player", kind), "number")
            -- Only a readable maximum proves the class has this resource; a
            -- restricted value is not evidence of anything.
            if maximum and maximum > 0 then return kind end
        end
    end
end

-- Classes whose second resource already has a native per-unit display keep it.
-- Death knight runes recover one rune at a time; a continuous 0..6 rail cannot
-- show that, so drawing one would replace readable information with a worse
-- summary. The class token is read as a plain string; an unreadable token
-- keeps the generic rail path.
local NATIVE_SECONDARY = { DEATHKNIGHT = "runes" }

local function nativeSecondary()
    if type(UnitClass) ~= "function" then return nil end
    local ok, _, token = pcall(UnitClass, "player")
    token = ok and plain(token, "string") or nil
    return token and NATIVE_SECONDARY[token] or nil
end

-- Re-reads both decisions together: a native display wins, and only then is a
-- readable secondary power type worth looking for.
local function refreshKinds(self)
    self.classToken = classToken()
    self.secondaryNative = nativeSecondary()
    -- Not `a and nil or b`: that idiom always yields b. The native display has
    -- to win outright.
    if self.secondaryNative then
        self.secondaryType = nil
    else
        self.secondaryType = secondaryType()
    end
end

-- Rune rows are only meaningful for a death knight and only when the own row
-- was chosen. Every value is a plain number; a restricted rune keeps its last
-- readable segment instead of resetting to zero.
local function runesWanted(self)
    return app.Store:Profile().ui.resourceRunes == "owned"
        and (self.classToken or classToken()) == "DEATHKNIGHT"
        and type(GetRuneCooldown) == "function"
end

local function stopRuneTicker(self)
    if self.runeTicker then self.runeTicker:Cancel(); self.runeTicker = nil end
end

local function drawRunes(self)
    local runes = self.runes
    if not runes then return 0 end
    if not runesWanted(self) then
        if runes:IsShown() then runes:Hide() end
        stopRuneTicker(self)
        return 0
    end
    local now = type(GetTime) == "function" and select(2, pcall(GetTime)) or nil
    now = plain(now, "number")
    local recovering = false
    for index = 1, RUNE_COUNT do
        local bar = runes.bars[index]
        local ok, start, duration, ready = pcall(GetRuneCooldown, index)
        start, duration = ok and plain(start, "number") or nil, ok and plain(duration, "number") or nil
        ready = ok and plain(ready, "boolean") or nil
        if bar then
            if ready == true then
                bar:SetValue(1)
                local accent = app.Theme:Accent()
                bar:SetStatusBarColor(accent[1], accent[2], accent[3], 1)
            elseif start and duration and duration > 0 and now then
                local elapsed = math.max(0, math.min(duration, now - start))
                bar:SetValue(elapsed / duration)
                local dark = app.Theme.colors.muted
                bar:SetStatusBarColor(dark[1], dark[2], dark[3], 1)
                if elapsed < duration then recovering = true end
            else
                bar:SetValue(0)
                local dark = app.Theme.colors.tapped
                bar:SetStatusBarColor(dark[1], dark[2], dark[3], 1)
            end
        end
    end
    runes:Show()
    if recovering and not self.runeTicker and type(C_Timer) == "table"
        and type(C_Timer.NewTicker) == "function" then
        self.runeTicker = C_Timer.NewTicker(0.2, function()
            if not self.running or not runesWanted(self) then stopRuneTicker(self); return end
            app:Call("playerResource/runes", drawRunes, self)
            self.rail:SetHeight(self.railHeight or RAIL_HEIGHT)
            app.Layout:SetResourceHeight(math.max(11, self.railHeight or RAIL_HEIGHT))
        end)
    elseif not recovering then
        stopRuneTicker(self)
    end
    return RUNE_HEIGHT + RUNE_GAP_TOP
end

local function draw(self)
    local bar = self.primary
    if not bar then return end
    local maximum = UnitPowerMax("player")
    bar:SetMinMaxValues(0, maximum)
    bar:SetValue(UnitPower("player"))
    app.Theme:PaintBar(bar, app.Theme:PowerColor("player"))

    -- A class with a native per-unit display (death knight runes) keeps it:
    -- the summary rail is not drawn rather than replacing per-rune recovery.
    -- The own rune row, when chosen, replaces that summary instead.
    if self.secondaryNative then
        if self.secondary and self.secondary:IsShown() then self.secondary:Hide() end
        local extra = drawRunes(self)
        local height = extra > 0 and (RAIL_HEIGHT + RUNE_GAP_TOP + RUNE_HEIGHT) or RAIL_HEIGHT
        self.railHeight = height
        self.rail:SetHeight(height)
        app.Layout:SetResourceHeight(math.max(11, height))
        return
    end

    -- No rune row on this path: the summary rail is the whole display.
    if self.runes and self.runes:IsShown() then self.runes:Hide() end
    stopRuneTicker(self)
    local kind = self.secondaryType
    if kind then
        local secondMax = plain(UnitPowerMax("player", kind), "number")
        if secondMax and secondMax > 0 then
            local secondary = self.secondary
            secondary:SetMinMaxValues(0, secondMax)
            secondary:SetValue(UnitPower("player", kind))
            app.Theme:PaintBar(secondary, app.Theme:PowerColor("player"))
            secondary:Show()
            local height = RAIL_HEIGHT + SECONDARY_GAP + SECONDARY_HEIGHT
            self.railHeight = height
            self.rail:SetHeight(height)
            app.Layout:SetResourceHeight(math.max(11, height))
            return
        end
    end
    if self.secondary and self.secondary:IsShown() then self.secondary:Hide() end
    self.railHeight = RAIL_HEIGHT
    self.rail:SetHeight(RAIL_HEIGHT)
    app.Layout:SetResourceHeight(11)
end

-- The main skills own this edge. Tracked buff viewers sit above the reserved
-- lane and can grow without pulling the rail or health frames up the screen.
-- Without a main viewer, use the existing stack or action baseline.
--
-- The top comes from the applied row geometry (`Layout:Central()` merges the
-- last `CentralRows` result), not from a bare bottom edge, so the rail sits
-- above the real skill block even before this component enables: on the field
-- export below it read `cooldown.bottom + 6` and crossed the lowest skills.
--
-- The rail is a plain addon frame, so its own anchor write is not a protected
-- operation and can follow a geometry change in combat. Nothing reads or writes
-- a native frame here. A settled rail writes nothing, so the one-second layout
-- beat costs reads only.
local function atTarget(rail, x, y)
    local ok, point, relative, _, px, py = pcall(rail.GetPoint, rail, 1)
    if not ok or point ~= "BOTTOM" or (relative ~= nil and relative ~= UIParent) then return false end
    px, py = plain(px, "number"), plain(py, "number")
    return px ~= nil and py ~= nil and math.abs(px - x) < 0.25 and math.abs(py - y) < 0.25
end

local function resourceBottom(central)
    return (central.cooldown.mainTop or central.cooldown.top) + app.Layout.resourceGap
end

local function position(self)
    local central = app.Layout:Central()
    local rail = self.rail
    local y = resourceBottom(central)
    local width = math.max(60, central.content.width)
    if not atTarget(rail, 0, y) then
        rail:ClearAllPoints()
        rail:SetPoint("BOTTOM", UIParent, "BOTTOM", 0, y)
    end
    local okWidth, current = pcall(rail.GetWidth, rail)
    current = okWidth and plain(current, "number") or nil
    if not current or math.abs(current - width) >= 0.5 then rail:SetWidth(width) end
end

component = app:RegisterComponent({
    id = "playerResource", label = "playerResource", defaultEnabled = true,
    Supported = function()
        return type(UnitPower) == "function" and type(UnitPowerMax) == "function"
            and type(UnitPowerType) == "function"
    end,
    Enable = function(self)
        if not self.rail then
            local rail = CreateFrame("Frame", "LumaUIPlayerResource", UIParent)
            rail:SetHeight(RAIL_HEIGHT)
            rail:SetWidth(200)
            rail.primary = app.Theme:Bar(rail, RAIL_HEIGHT)
            -- The primary fill spans the whole rail; the secondary rail hangs
            -- under it at the same width, so the two read as one block.
            rail.primary:SetPoint("TOPLEFT", 0, 0)
            rail.primary:SetPoint("TOPRIGHT", 0, 0)
            rail.secondary = app.Theme:Bar(rail, SECONDARY_HEIGHT)
            rail.secondary:SetPoint("TOPLEFT", 0, -(RAIL_HEIGHT + SECONDARY_GAP))
            rail.secondary:SetPoint("TOPRIGHT", 0, -(RAIL_HEIGHT + SECONDARY_GAP))
            rail.secondary:Hide()
            -- Six own rune segments, hidden until the class and the option both
            -- ask for them.
            local runes = CreateFrame("Frame", "LumaUIPlayerRunes", rail)
            runes:SetSize(RUNE_COUNT * RUNE_WIDTH + (RUNE_COUNT - 1) * RUNE_GAP, RUNE_HEIGHT)
            runes:SetPoint("TOPLEFT", 0, -(RAIL_HEIGHT + RUNE_GAP_TOP))
            runes.bars = {}
            for index = 1, RUNE_COUNT do
                local segment = CreateFrame("StatusBar", nil, runes)
                segment:SetSize(RUNE_WIDTH, RUNE_HEIGHT)
                segment:SetPoint("LEFT", runes, "LEFT", (index - 1) * (RUNE_WIDTH + RUNE_GAP), 0)
                segment:SetStatusBarTexture(app.Theme.media.combatFill)
                segment:SetMinMaxValues(0, 1)
                segment:SetValue(0)
                segment.background = segment:CreateTexture(nil, "BACKGROUND")
                segment.background:SetAllPoints()
                local dark = app.Theme.colors.embedded
                segment.background:SetColorTexture(dark[1], dark[2], dark[3], 1)
                runes.bars[index] = segment
            end
            runes:Hide()
            rail.runes = runes
            self.rail, self.primary, self.secondary = rail, rail.primary, rail.secondary
            self.runes = runes
        end
        self.rail:Show()
        refreshKinds(self)
        position(self)
        draw(self)
        for _, event in ipairs({ "UNIT_POWER_UPDATE", "UNIT_MAXPOWER", "UNIT_DISPLAYPOWER" }) do
            self:Listen(event, function(current, _, unit)
                if unit == "player" then draw(current) end
            end)
        end
        -- A spec change can add or remove a class resource; re-read the type
        -- instead of carrying a stale rail.
        self:Listen("PLAYER_SPECIALIZATION_CHANGED", function(current)
            refreshKinds(current)
            draw(current)
            position(current)
        end)
        self:Listen("PLAYER_ENTERING_WORLD", function(current)
            refreshKinds(current)
            draw(current)
            position(current)
        end)
        self:Listen("RUNE_POWER_UPDATE", function(current) draw(current) end)
        self:Listen("PLAYER_DEAD", function(current)
            stopRuneTicker(current)
        end)
        -- Only this component's own rail moves; the protected consumers keep
        -- their own queue keys, so a geometry change does not add a job here.
        app:Subscribe(self, "LAYOUT_CENTRAL_CHANGED", function()
            if self.running then app:Call("playerResource/position", position, self) end
        end)
    end,
    Refresh = function(self)
        refreshKinds(self)
        draw(self)
        position(self)
    end,
    Disable = function(self)
        stopRuneTicker(self)
        if self.runes then self.runes:Hide() end
        if self.rail then self.rail:Hide() end
        if self.primary then self.primary:SetValue(0) end
        if self.secondary then self.secondary:Hide() end
        app.Layout:SetResourceHeight(11)
    end,
})

function component:Describe()
    if not self.running then return nil end
    local label = self.secondaryType and app.L.resourceSecondary
        or (self.secondaryNative and app.L.resourceNative) or app.L.resourcePrimary
    return string.format("playerResource: rail=%s", label)
end

-- `/luma hud` addition: the rail's rectangle and whether a second resource was
-- detected, so a missing rail can be told apart from a class without one. The
-- expected bottom comes from the same applied geometry the rail follows; a
-- mismatch there is what "the rail crosses the skills" looks like in a report.
function component:Diagnose()
    local function yes(value) return value and "yes" or "no" end
    local rail = self.rail
    local width, bottom = "?", "?"
    if rail then
        local okWidth, value = pcall(rail.GetWidth, rail)
        width = okWidth and tostring(value) or "?"
        local okPoint, _, _, _, _, y = pcall(rail.GetPoint, rail, 1)
        bottom = okPoint and tostring(y) or "?"
    end
    app:Print(string.format("playerResource: status=%s running=%s secondary=%s native=%s width=%s bottom=%s expected=%.0f",
        tostring(self.status), yes(self.running), self.secondaryType and "yes" or "no",
        self.secondaryNative or "-", width, bottom, resourceBottom(app.Layout:Central())))
end
