local _, app = ...

-- Native cooldown viewer placement. The client's own Cooldown Manager frames
-- (essential and utility skills, tracked buffs as icons and as bars) are moved
-- into one centred stack above the action bar stack. Nothing is re-implemented:
-- the client keeps the tracked list, the cooldown engine, glow, tooltips and
-- every Edit Mode setting; this component only records and replaces the frames'
-- anchors, and puts them back on disable. An originally hidden viewer is shown
-- while the component runs, because the mockup's block is part of the HUD.

local STACK = {
    "EssentialCooldownViewer",
    "UtilityCooldownViewer",
    "BuffBarCooldownViewer",
    "BuffIconCooldownViewer",
}
local GAP, FALLBACK_Y = 4, 240
local LAYOUT_JOB, RESTORE_JOB = "cooldownViewer/layout", "cooldownViewer/restore"

local function object(value)
    local kind = type(value)
    return kind == "table" or kind == "userdata"
end

local function inCombat()
    return type(InCombatLockdown) == "function" and InCombatLockdown()
end

local function viewers()
    local list = {}
    for _, name in ipairs(STACK) do
        local frame = _G[name]
        if object(frame) and type(frame.SetPoint) == "function" then
            list[#list + 1] = frame
        end
    end
    return list
end

-- Every anchor is recorded once, before the first write. The client may anchor
-- a viewer with more than one point, so all readable points are kept and put
-- back in order.
local function record(frame)
    if frame.lumaCooldownViewerOriginal then return end
    local original = { points = {} }
    if type(frame.IsShown) == "function" then
        local ok, shown = pcall(frame.IsShown, frame)
        -- Keep a plain false: "was hidden" is the state that has to come back.
        if ok then original.shown = shown end
    end
    for index = 1, 4 do
        local ok, point, relative, relativePoint, x, y = pcall(frame.GetPoint, frame, index)
        if not ok or not point then break end
        original.points[#original.points + 1] = { point, relative, relativePoint, x, y }
    end
    frame.lumaCooldownViewerOriginal = original
end

local function restoreFrame(frame)
    local original = frame.lumaCooldownViewerOriginal
    if not original then return end
    pcall(frame.ClearAllPoints, frame)
    for _, point in ipairs(original.points) do
        pcall(frame.SetPoint, frame, point[1], point[2], point[3], point[4], point[5])
    end
    if original.shown == false then pcall(frame.Hide, frame) end
    frame.lumaCooldownViewerOriginal = nil
end

-- Bottom to top: skill rows stay closest to the bars, the tracked buff views
-- sit above them, which is the order of the Pearl mockup's block.
local function layout(self)
    local bar = _G.MultiBarBottomRight
    if not object(bar) then bar = _G.MainActionBar end
    local previous = object(bar) and bar or nil
    self.recorded = self.recorded or {}
    for _, frame in ipairs(viewers()) do
        record(frame)
        self.recorded[frame] = true
        pcall(frame.Show, frame)
        pcall(frame.ClearAllPoints, frame)
        if previous then
            pcall(frame.SetPoint, frame, "BOTTOM", previous, "TOP", 0, GAP)
        else
            pcall(frame.SetPoint, frame, "BOTTOM", UIParent, "BOTTOM", 0, FALLBACK_Y)
        end
        previous = frame
    end
end

local function restoreAll(self)
    for frame in pairs(self.recorded or {}) do
        restoreFrame(frame)
    end
    self.recorded = {}
    self.pending = nil
end

local function apply(self)
    if inCombat() then
        self.pending = true
        app.Queue:Run(LAYOUT_JOB, function()
            if not self.running then return end
            self.pending = nil
            layout(self)
        end)
        return
    end
    self.pending = nil
    layout(self)
end

app:RegisterComponent({
    id = "cooldownViewer", label = "cooldownViewer", defaultEnabled = true,
    Supported = function()
        -- The viewers can load after login on some builds; the API existing is
        -- enough to run, and every layout pass simply skips missing frames.
        return #viewers() > 0 or type(C_CooldownViewer) == "table"
    end,
    Enable = function(self)
        self.recorded = self.recorded or {}
        self.pending = nil
        apply(self)
        self:Listen("PLAYER_ENTERING_WORLD", function(current) apply(current) end)
        -- Edit Mode and a spec change both re-anchor the native viewers; put the
        -- stack back once the client is done with its own layout.
        self:Listen("EDIT_MODE_LAYOUTS_UPDATED", function(current) apply(current) end)
        self:Listen("PLAYER_SPECIALIZATION_CHANGED", function(current) apply(current) end)
        self:Listen("PLAYER_REGEN_ENABLED", function(current)
            if current.pending then apply(current) end
        end)
    end,
    Refresh = function(self) apply(self) end,
    Disable = function(self)
        if inCombat() then
            app.Queue:Run(RESTORE_JOB, function() restoreAll(self) end)
        else
            restoreAll(self)
        end
    end,
})
