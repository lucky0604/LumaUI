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

local RAIL_HEIGHT = 8
local SECONDARY_HEIGHT = 10
local SECONDARY_GAP = 3
-- 012 phase 08: death knight runes as six own segments. Per-rune recovery is
-- what a continuous 0..6 rail cannot express, so each rune gets its own small
-- StatusBar fed by GetRuneCooldown. The native rune row keeps drawing until the
-- player explicitly chooses the own row (`/luma runes`).
local RUNE_COUNT = 6
local RUNE_WIDTH, RUNE_HEIGHT, RUNE_GAP = 11, 10, 2
local RUNE_GAP_TOP = 3
-- 017 phase 05: Vengeance demon hunter soul fragments. The count comes from
-- C_Spell.GetSpellCastCount(228477) (a hypothesis to verify in the client). It
-- can be a restricted value, so it goes untouched into one StatusBar; Lua never
-- compares, adds or stores it. The capacity (6) only places fixed dividers and
-- is not read from the count.
-- Optional arc: six short segments on a shallow arc, each placed and rotated
-- independently. It is drawn only from plain, readable values (rune recovery);
-- a restricted value keeps the straight row, so the arc never has to compare a
-- secret to decide how a segment looks.
local ARC_RADIUS, ARC_SPREAD, ARC_HEIGHT = 40, 0.9, 16
local FRAGMENT_SPELL = 228477
local FRAGMENT_SPEC = 581
local FRAGMENT_CAPACITY = 6
local FRAGMENT_HEIGHT = 10

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
        if self.runeArc and self.runeArc:IsShown() then self.runeArc:Hide() end
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
    local arc = self.runeArc
    local useArc = arc ~= nil and app.Store:Profile().ui.resourceStyle == "arc"
    self.runeStyle = useArc and "arc" or "line"
    if useArc then
        for index = 1, RUNE_COUNT do
            local bar, segment = runes.bars[index], arc.segments[index]
            local value = bar and bar.value
            -- The straight bar already holds the plain value; mirror it in the
            -- segment's colour/alpha instead of reading the source twice.
            local r, g, b = 1, 1, 1
            if bar and bar.GetStatusBarColor then r, g, b = bar:GetStatusBarColor() end
            segment:SetColorTexture(r or 1, g or 1, b or 1, 0.35 + 0.65 * (type(value) == "number" and value or 0))
        end
        runes:Hide()
        arc:Show()
    else
        arc:Hide()
        runes:Show()
    end
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
    return (useArc and ARC_HEIGHT or RUNE_HEIGHT) + RUNE_GAP_TOP
end

local function specID()
    local api = _G.C_SpecializationInfo
    local getIndex = api and api.GetSpecialization or _G.GetSpecialization
    local getInfo = api and api.GetSpecializationInfo or _G.GetSpecializationInfo
    if type(getIndex) ~= "function" or type(getInfo) ~= "function" then return nil end
    local ok, index = pcall(getIndex)
    index = ok and plain(index, "number") or nil
    if not index then return nil end
    local okInfo, id = pcall(getInfo, index)
    return okInfo and plain(id, "number") or nil
end

local function fragmentsSupported(self)
    return (self.classToken or classToken()) == "DEMONHUNTER"
        and specID() == FRAGMENT_SPEC
        and type(_G.C_Spell) == "table" and type(_G.C_Spell.GetSpellCastCount) == "function"
end

local function fragmentsWanted(self)
    return app.Store:Profile().ui.resourceFragments == "owned" and fragmentsSupported(self)
end

-- Returns the extra height the row needs (0 when hidden). `nil` from the source
-- or a refused call means "unavailable" and hides the row; it is never drawn as
-- an empty row of zero, because 0 is a confirmed answer and nil is not.
local function drawFragments(self)
    local row = self.fragments
    if not row then return 0 end
    if not fragmentsWanted(self) then
        if row:IsShown() then row:Hide() end
        self.fragmentState = self.fragmentState and "off" or nil
        return 0
    end
    local ok, count = pcall(_G.C_Spell.GetSpellCastCount, FRAGMENT_SPELL)
    if not ok or type(count) == "nil" then
        row:Hide()
        self.fragmentState = "unavailable"
        return 0
    end
    row.bar:SetMinMaxValues(0, FRAGMENT_CAPACITY)
    -- Raw hand-over to the native drawing method; a secret stays a secret.
    pcall(row.bar.SetValue, row.bar, count)
    local accent = app.Theme:Accent()
    row.bar:SetStatusBarColor(accent[1], accent[2], accent[3], 1)
    row:Show()
    self.fragmentState = "shown"
    return FRAGMENT_HEIGHT + SECONDARY_GAP
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
        drawFragments(self)
        if self.secondary and self.secondary:IsShown() then self.secondary:Hide() end
        local extra = drawRunes(self)
        local height = extra > 0 and (RAIL_HEIGHT + extra) or RAIL_HEIGHT
        self.railHeight = height
        self.rail:SetHeight(height)
        app.Layout:SetResourceHeight(math.max(11, height))
        return
    end

    -- No rune row on this path: the summary rail is the whole display.
    if self.runes and self.runes:IsShown() then self.runes:Hide() end
    stopRuneTicker(self)
    local fragmentExtra = drawFragments(self)
    if fragmentExtra > 0 then
        if self.secondary and self.secondary:IsShown() then self.secondary:Hide() end
        local height = RAIL_HEIGHT + fragmentExtra
        self.railHeight = height
        self.rail:SetHeight(height)
        app.Layout:SetResourceHeight(math.max(11, height))
        return
    end
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
    -- One plan decides the width: the rail may not be wider than the block the
    -- player sees, and an empty or hidden row never carries it.
    local width = app.Layout:ResourceWidth()
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
            local arc = CreateFrame("Frame", "LumaUIPlayerRuneArc", rail)
            arc:SetSize(2 * ARC_RADIUS, ARC_HEIGHT)
            arc:SetPoint("TOP", rail, "TOP", 0, -(RAIL_HEIGHT + RUNE_GAP_TOP))
            arc.segments = {}
            for index = 1, RUNE_COUNT do
                local segment = arc:CreateTexture(nil, "ARTWORK")
                segment:SetSize(RUNE_WIDTH, 5)
                local t = (index - 1) / (RUNE_COUNT - 1) * 2 - 1
                local angle = t * ARC_SPREAD
                -- Centre of the arc sits below the row, so the ends curve down.
                segment:SetPoint("CENTER", arc, "BOTTOM", math.sin(angle) * ARC_RADIUS,
                    ARC_HEIGHT - 3 - (1 - math.cos(angle)) * ARC_RADIUS)
                if type(segment.SetRotation) == "function" then pcall(segment.SetRotation, segment, -angle) end
                segment:SetColorTexture(1, 1, 1, 1)
                arc.segments[index] = segment
            end
            arc:Hide()
            self.runeArc = arc
            -- One continuous bar with fixed dividers: the count is handed to it
            -- raw, the dividers only mark the plain capacity.
            local fragments = CreateFrame("Frame", "LumaUIPlayerFragments", rail)
            fragments:SetHeight(FRAGMENT_HEIGHT)
            fragments:SetPoint("TOPLEFT", 0, -(RAIL_HEIGHT + SECONDARY_GAP))
            fragments:SetPoint("TOPRIGHT", 0, -(RAIL_HEIGHT + SECONDARY_GAP))
            fragments.bar = CreateFrame("StatusBar", nil, fragments)
            fragments.bar:SetAllPoints()
            fragments.bar:SetStatusBarTexture(app.Theme.media.combatFill)
            fragments.bar:SetMinMaxValues(0, FRAGMENT_CAPACITY)
            fragments.bar:SetValue(0)
            fragments.back = fragments:CreateTexture(nil, "BACKGROUND")
            fragments.back:SetAllPoints()
            local base = app.Theme.colors.embedded
            fragments.back:SetColorTexture(base[1], base[2], base[3], 1)
            fragments.dividers = {}
            for index = 1, FRAGMENT_CAPACITY - 1 do
                local divider = fragments.bar:CreateTexture(nil, "OVERLAY")
                divider:SetWidth(1)
                divider:SetPoint("TOP", fragments.bar, "TOPLEFT", 0, 0)
                divider:SetPoint("BOTTOM", fragments.bar, "BOTTOMLEFT", 0, 0)
                divider:SetColorTexture(0, 0, 0, 0.85)
                fragments.dividers[index] = divider
            end
            fragments:SetScript("OnSizeChanged", function(box, width)
                width = plain(width, "number")
                if not width or width <= 0 then return end
                for index, divider in ipairs(box.dividers) do
                    divider:ClearAllPoints()
                    divider:SetPoint("TOP", box.bar, "TOPLEFT", width * index / FRAGMENT_CAPACITY, 0)
                    divider:SetPoint("BOTTOM", box.bar, "BOTTOMLEFT", width * index / FRAGMENT_CAPACITY, 0)
                end
            end)
            fragments:Hide()
            rail.fragments = fragments
            self.fragments = fragments
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
        -- The first-choice event for the soul fragment count; it only redraws
        -- the row when it is wanted.
        self:Listen("SPELL_UPDATE_USES", function(current)
            if app.Store:Profile().ui.resourceFragments == "owned" then draw(current) end
        end)
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
        if self.fragments then self.fragments:Hide() end
        if self.runeArc then self.runeArc:Hide() end
        if self.rail then self.rail:Hide() end
        if self.primary then self.primary:SetValue(0) end
        if self.secondary then self.secondary:Hide() end
        app.Layout:SetResourceHeight(11)
    end,
})

function component:Describe()
    if not self.running then return nil end
    local label = self.fragmentState == "shown" and "fragments"
        or self.secondaryType and app.L.resourceSecondary
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
