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

local function draw(self)
    local bar = self.primary
    if not bar then return end
    local maximum = UnitPowerMax("player")
    bar:SetMinMaxValues(0, maximum)
    bar:SetValue(UnitPower("player"))
    app.Theme:PaintBar(bar, app.Theme:PowerColor("player"))

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
-- The rail is a plain addon frame, so its own anchor write is not a protected
-- operation and can follow a geometry change in combat. Nothing reads or writes
-- a native frame here.
local function position(self)
    local central = app.Layout:Central()
    local rail = self.rail
    rail:ClearAllPoints()
    rail:SetPoint("BOTTOM", UIParent, "BOTTOM", 0, central.cooldown.top + RAIL_GAP)
    rail:SetWidth(math.max(60, central.content.width))
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
        self.secondaryType = secondaryType()
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
            current.secondaryType = secondaryType()
            draw(current)
            position(current)
        end)
        self:Listen("PLAYER_ENTERING_WORLD", function(current)
            current.secondaryType = secondaryType()
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
        self.secondaryType = secondaryType()
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
    return string.format("playerResource: rail=%s", self.secondaryType
        and app.L.resourceSecondary or app.L.resourcePrimary)
end

-- `/luma hud` addition: the rail's rectangle and whether a second resource was
-- detected, so a missing rail can be told apart from a class without one.
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
    app:Print(string.format("playerResource: status=%s running=%s secondary=%s width=%s bottom=%s",
        tostring(self.status), yes(self.running), self.secondaryType and "yes" or "no",
        width, bottom))
end
