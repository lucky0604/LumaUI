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
local RAIL_GAP = 6

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
    self.secondaryNative = nativeSecondary()
    -- Not `a and nil or b`: that idiom always yields b. The native display has
    -- to win outright.
    if self.secondaryNative then
        self.secondaryType = nil
    else
        self.secondaryType = secondaryType()
    end
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
    if self.secondaryNative then
        if self.secondary and self.secondary:IsShown() then self.secondary:Hide() end
        self.rail:SetHeight(RAIL_HEIGHT)
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
            self.rail:SetHeight(RAIL_HEIGHT + SECONDARY_GAP + SECONDARY_HEIGHT)
            return
        end
    end
    if self.secondary and self.secondary:IsShown() then self.secondary:Hide() end
    self.rail:SetHeight(RAIL_HEIGHT)
end

-- Anchored above the whole central stack, centred, as wide as the main skill
-- block. Saved positions never apply: this is a HUD layer that follows the
-- measured geometry instead of a movable panel.
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

local function position(self)
    local central = app.Layout:Central()
    local rail = self.rail
    local y = central.cooldown.top + RAIL_GAP
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
            self.rail, self.primary, self.secondary = rail, rail.primary, rail.secondary
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
        if self.rail then self.rail:Hide() end
        if self.primary then self.primary:SetValue(0) end
        if self.secondary then self.secondary:Hide() end
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
        self.secondaryNative or "-", width, bottom, app.Layout:Central().cooldown.top + RAIL_GAP))
end
