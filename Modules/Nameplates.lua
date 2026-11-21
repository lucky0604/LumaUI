local _, app = ...

-- Nameplate styling, first pass: the target's nameplate health bar gets the
-- LumaUI gradient fill. Nothing else is touched — no pooling, no unit binding,
-- no friendly/enemy logic, no reading of health values. The game keeps
-- ownership of the nameplate and we only repaint one bar it already draws.
--
-- Why only the target plate: nameplates are restricted objects in instances
-- (friendly nameplates cannot be manipulated), and the target plate is the one
-- unit whose identity is always public. Starting there keeps the component
-- safe by construction, and the scope can grow once this is verified in game.
--
-- Ownership is one active bar at a time. Switching target, losing the plate and
-- stopping the component all go through the same restore path: the bar recorded
-- before the paint is put back (colour and fill texture) and its record dropped,
-- so a recycled plate never keeps another unit's styling. A forbidden bar is
-- never painted or restored.

local component

local function plateFor(unit)
    local api = _G.C_NamePlate
    if type(api) ~= "table" or type(api.GetNamePlateForUnit) ~= "function" then return nil end
    local ok, plate = pcall(api.GetNamePlateForUnit, unit)
    if not ok then return nil end
    if type(plate) ~= "table" and type(plate) ~= "userdata" then return nil end
    return plate
end

local function healthBarOf(plate)
    local frame = plate and plate.UnitFrame
    local bar = frame and frame.healthBar
    if bar and type(bar.SetStatusBarColor) == "function" then return bar end
    return nil
end

local function isForbidden(object)
    if not object or type(object.IsForbidden) ~= "function" then return false end
    local ok, forbidden = pcall(object.IsForbidden, object)
    return ok and forbidden == true
end

-- Repaints the target plate's bar with the unit's gradient pair.
local function paint(bar)
    if not bar then return end
    app.Theme:PaintBar(bar, app.Theme:UnitColor("target"))
end

local function remember(self, bar)
    if not bar or self.originals[bar] then return end
    local original = {}
    if type(bar.GetStatusBarColor) == "function" then
        local ok, red, green, blue, alpha = pcall(bar.GetStatusBarColor, bar)
        if ok and red then original.color = { red, green, blue, alpha } end
    end
    if type(bar.GetStatusBarTexture) == "function" then
        local ok, texture = pcall(bar.GetStatusBarTexture, bar)
        if ok then original.texture = texture end
    end
    self.originals[bar] = original
end

-- Puts one recorded bar back. Only the properties that were actually changed
-- are restored; a restricted object is skipped instead of being written to.
local function restore(self, bar)
    local original = bar and self.originals[bar]
    if not original then return end
    self.originals[bar] = nil
    if isForbidden(bar) then return end
    if type(bar.SetStatusBarTexture) == "function" and original.texture then
        pcall(bar.SetStatusBarTexture, bar, original.texture)
    end
    if type(bar.SetStatusBarColor) == "function" and original.color then
        pcall(bar.SetStatusBarColor, bar, original.color[1], original.color[2],
            original.color[3], original.color[4])
    end
end

local function restoreAll(self)
    for bar in pairs(self.originals or {}) do
        restore(self, bar)
    end
    self.originals = {}
    self.active = nil
end

local function apply(self)
    local bar = healthBarOf(plateFor("target"))
    if self.active and self.active ~= bar then
        -- The old target's plate is still a live frame: give it its own look
        -- back before the new target is painted.
        restore(self, self.active)
        self.active = nil
    end
    if not bar then return end
    if isForbidden(bar) then return end
    remember(self, bar)
    paint(bar)
    self.active = bar
end

component = app:RegisterComponent({ id = "nameplates", label = "nameplates", defaultEnabled = false,
    Supported = function()
        local api = _G.C_NamePlate
        return type(api) == "table" and type(api.GetNamePlateForUnit) == "function"
    end,
    Enable = function(self)
        self.originals = self.originals or {}
        -- PLAYER_TARGET_CHANGED moves the paint, NAME_PLATE_UNIT_REMOVED restores
        -- a plate that is about to be recycled, and the entering-world event
        -- covers a reload with a target already selected.
        for _, event in ipairs({ "PLAYER_TARGET_CHANGED", "PLAYER_ENTERING_WORLD",
            "NAME_PLATE_UNIT_ADDED", "NAME_PLATE_UNIT_REMOVED" }) do
            self:Listen(event, function(current)
                app.Queue:Run("nameplates/apply", function()
                    if current.running then apply(current) end
                end)
            end)
        end
        app.Queue:Run("nameplates/apply", function()
            if self.running then apply(self) end
        end)
    end,
    Refresh = function(self)
        app.Queue:Run("nameplates/apply", function()
            if self.running then apply(self) end
        end)
    end,
    Disable = function(self)
        restoreAll(self)
    end,
})

-- Diagnostics for `/luma status`: one painted bar at most, and the record of
-- its native look is the only state kept.
function component:Describe()
    if not self.running then return nil end
    local count = 0
    for _ in pairs(self.originals or {}) do count = count + 1 end
    return string.format("nameplates: %s=%d", app.L.nativePlatesPainted, count)
end
