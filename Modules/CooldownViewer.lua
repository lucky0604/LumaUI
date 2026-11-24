local _, app = ...

-- Native cooldown viewer placement. The client's own Cooldown Manager frames
-- (essential and utility skills, tracked buffs as icons and as bars) are moved
-- into one centred stack above the managed action area. Nothing is re-implemented:
-- the client keeps the tracked list, the cooldown engine, glow, tooltips and
-- every Edit Mode setting; this component only records and replaces the frames'
-- anchors, and puts them back on disable.
--
-- Visibility is the client's decision. A viewer the player hid (or that is
-- empty, alpha zero, or has no readable size) is skipped instead of being forced
-- on screen, so the native layout option keeps its meaning and an empty row does
-- not reserve space. A viewer whose re-anchor is refused keeps its original
-- point while the rest of the stack continues.

local STACK = {
    { id = "essential", name = "EssentialCooldownViewer" },
    { id = "utility", name = "UtilityCooldownViewer" },
    { id = "buffBar", name = "BuffBarCooldownViewer" },
    { id = "buffIcon", name = "BuffIconCooldownViewer" },
}
local CONTENT_LISTS = { "cooldownButtons", "activeButtons", "itemFrames", "buttons", "icons" }
local LAYOUT_JOB, RESTORE_JOB = "cooldownViewer/layout", "cooldownViewer/restore"

local function object(value)
    local kind = type(value)
    return kind == "table" or kind == "userdata"
end

local function inCombat()
    return type(InCombatLockdown) == "function" and InCombatLockdown()
end

local function plain(value, expected)
    return app.Capabilities.Plain(value, expected)
end

local function viewers()
    local list = {}
    for _, def in ipairs(STACK) do
        local frame = _G[def.name]
        if object(frame) and type(frame.SetPoint) == "function" then
            list[#list + 1] = frame
        end
    end
    return list
end

-- Local frame units to UIParent units, so a viewer scaled by Edit Mode still
-- lands on the shared stack instead of drifting by its own scale.
local function frameRatio(frame)
    if not object(frame) or type(frame.GetEffectiveScale) ~= "function"
        or type(UIParent.GetEffectiveScale) ~= "function" then return 1 end
    local okFrame, frameScale = pcall(frame.GetEffectiveScale, frame)
    local okParent, parentScale = pcall(UIParent.GetEffectiveScale, UIParent)
    frameScale = okFrame and plain(frameScale, "number") or nil
    parentScale = okParent and plain(parentScale, "number") or nil
    if not frameScale or not parentScale or frameScale <= 0 or parentScale <= 0 then return 1 end
    return frameScale / parentScale
end

local function shownState(frame)
    if type(frame.IsShown) ~= "function" then return nil end
    local ok, value = pcall(frame.IsShown, frame)
    if not ok or app.Capabilities.IsSecret(value) then return nil end
    return value == true
end

local function alphaState(frame)
    if type(frame.GetAlpha) ~= "function" then return nil end
    local ok, value = pcall(frame.GetAlpha, frame)
    value = ok and plain(value, "number") or nil
    return value
end

local function heightState(frame)
    if type(frame.GetHeight) ~= "function" then return nil end
    local ok, value = pcall(frame.GetHeight, frame)
    value = ok and plain(value, "number") or nil
    if not value or value ~= value then return nil end
    return value
end

local function shownChild(child)
    if not object(child) then return false end
    if type(child.IsShown) ~= "function" then return true end
    local ok, value = pcall(child.IsShown, child)
    -- An unreadable child is not evidence of an empty row: keep the viewer.
    if not ok or app.Capabilities.IsSecret(value) then return true end
    return value ~= false
end

-- true: content, false: proven empty, nil: this build exposes nothing readable.
-- A client build whose viewer fields differ therefore keeps the native frame in
-- the stack instead of being dropped on a guess.
local function contentState(frame)
    local known = false
    for _, key in ipairs(CONTENT_LISTS) do
        local list = frame[key]
        if type(list) == "table" then
            known = true
            for _, button in pairs(list) do
                if shownChild(button) then return true end
            end
        end
    end
    if known then return false end
    if type(frame.GetChildren) == "function" then
        local ok, children = pcall(function() return { frame:GetChildren() } end)
        if ok and type(children) == "table" then
            local buttons = 0
            for _, child in ipairs(children) do
                local kind = object(child) and type(child.GetObjectType) == "function"
                    and select(2, pcall(child.GetObjectType, child)) or nil
                if kind == "Button" then
                    buttons = buttons + 1
                    if shownChild(child) then return true end
                end
            end
            if buttons > 0 then return false end
        end
    end
    local height = heightState(frame)
    if height and height <= 1 then return false end
end

-- Every anchor is recorded once, before the first write. The client may anchor
-- a viewer with more than one point, so all readable points are kept and put
-- back in order. A viewer with no readable point still gets a record: restoring
-- means clearing the points LumaUI added, not inventing one.
local function record(frame)
    if frame.lumaCooldownViewerOriginal then return true end
    local original = { points = {} }
    for index = 1, 4 do
        local ok, point, relative, relativePoint, x, y = pcall(frame.GetPoint, frame, index)
        if not ok or not point then break end
        original.points[#original.points + 1] = { point, relative, relativePoint, x, y }
    end
    frame.lumaCooldownViewerOriginal = original
    return true
end

local function restorePoints(frame)
    local original = frame.lumaCooldownViewerOriginal
    if not original then return end
    pcall(frame.ClearAllPoints, frame)
    for _, point in ipairs(original.points) do
        pcall(frame.SetPoint, frame, point[1], point[2], point[3], point[4], point[5])
    end
end

local function restoreFrame(frame)
    restorePoints(frame)
    frame.lumaCooldownViewerOriginal = nil
end

local function place(self, frame, bottom)
    local offset = bottom / frameRatio(frame)
    local ok, problem = pcall(function()
        frame:ClearAllPoints()
        frame:SetPoint("BOTTOM", UIParent, "BOTTOM", 0, offset)
    end)
    if ok then return true end
    -- The write can be refused (protected or secret state). Put this control
    -- back on its old anchor and keep going: one viewer must not take the rest
    -- of the stack down with it.
    restorePoints(frame)
    if not self.refused[frame] then
        self.refused[frame] = true
        local name = type(frame.GetName) == "function" and select(2, pcall(frame.GetName, frame)) or nil
        app:Report("cooldownViewer/" .. tostring(name or "viewer"), problem)
    end
    return false
end

-- Bottom to top: skill rows stay closest to the bars, the tracked buff views
-- sit above them, which is the order of the Pearl mockup's block.
local function layout(self)
    local chosen = {}
    for _, def in ipairs(STACK) do
        local frame = _G[def.name]
        if object(frame) and type(frame.SetPoint) == "function"
            and type(frame.ClearAllPoints) == "function" then
            local shown = shownState(frame)
            local alpha = alphaState(frame)
            local content = contentState(frame)
            local size = heightState(frame)
            if shown == true and (alpha == nil or alpha > 0) and content ~= false
                and size and size > 1 and record(frame) then
                self.recorded[frame] = true
                chosen[#chosen + 1] = { id = def.id, frame = frame }
            end
        end
    end
    local central = app.Layout:CentralRows(chosen)
    self.placedRows = central.rows
    -- A refused write leaves its old anchor in place; collapse that reserved
    -- row so the rest of the stack stays contiguous instead of leaving a gap.
    local shift = 0
    for _, row in ipairs(central.rows) do
        if not place(self, row.frame, row.bottom - shift) then
            shift = shift + row.height + central.cooldown.gap
        end
    end
    -- The unit frames sit beside the visible block. Publish only after the
    -- stack is placed: the width came from this measurement, and re-entering
    -- the layout before the rows were written would leave the first pass half
    -- applied.
    if central.contentChanged then app:Publish("LAYOUT_CENTRAL_CHANGED") end
end

local function restoreAll(self)
    for frame in pairs(self.recorded or {}) do
        restoreFrame(frame)
    end
    self.recorded = {}
    self.refused = {}
    self.placedRows = {}
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
        self.refused = self.refused or {}
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
        -- 004 moves the reserved action baseline; both stacks follow the one
        -- published geometry instead of reading each other's private state.
        app:Subscribe(self, "LAYOUT_CENTRAL_CHANGED", function()
            if self.running then apply(self) end
        end)
    end,
    Refresh = function(self) apply(self) end,
    Disable = function(self)
        self.pending = nil
        if inCombat() then
            app.Queue:Run(RESTORE_JOB, function()
                if self.running then return end
                restoreAll(self)
            end)
        else
            restoreAll(self)
        end
    end,
})
