local _, app = ...
-- targettarget has no native counterpart, so its spec carries no native name
-- and the takeover step skips it; it sits below the target preview.
local specs = {
    { unit = "player", x = -270, y = -185, native = "PlayerFrame" },
    { unit = "target", x = 270, y = -185, native = "TargetFrame" },
    { unit = "targettarget", x = 270, y = -300, native = nil },
    { unit = "focus", x = 420, y = 60, native = "FocusFrame" },
    { unit = "pet", x = -270, y = -268, native = "PetFrame" },
}

local BASE_HEIGHT = 66
local NATIVE_JOB = "unitFrames/native"
local NATIVE_CAST_BARS = { "PlayerCastingBarFrame", "PetCastingBarFrame" }
-- A native unit frame is only replaced when every part that carries the
-- information the native frame shows is available. A client without the aura
-- API keeps its native unit frames instead of losing buffs and debuffs, and a
-- client without the cast API keeps its native cast bars.
local REPLACEMENT_PARTS = { "bars", "cast", "auras" }
local FRAME_EVENTS = { "PLAYER_ENTERING_WORLD", "PLAYER_TARGET_CHANGED", "PLAYER_FOCUS_CHANGED", "UNIT_PET" }
local component
-- Native hooks are installed once per frame for the whole session, keyed by
-- global frame name; enable/disable cycles only change the state the hook reads.
local nativeHooked = {}

-- Runs every available part in its own error-isolated call. Event payloads are
-- ignored for dispatch, so restricted unit tokens from events never reach
-- component logic, and unit values only ever touch native drawing methods
-- inside the parts. The frame height is deliberately NOT written here:
-- resizing a secure unit button is a protected change, and events fire during
-- combat, so the height only moves through the queued job below.
local function drawFrame(frame)
    local parts = component.parts
    if not parts then return end
    for _, part in ipairs(parts.active) do
        app:Call("unit/" .. frame.unitToken .. "/" .. part.id, part.draw, frame)
    end
end

-- One event only redraws the parts that subscribed to it: a health tick must
-- not rebuild the cast timer and a proc glow must not repaint the bars.
local function drawEvent(frame, event)
    local subscribed = frame.eventParts and frame.eventParts[event]
    if not subscribed then
        drawFrame(frame)
        return
    end
    for _, part in ipairs(subscribed) do
        app:Call("unit/" .. frame.unitToken .. "/" .. part.id, part.draw, frame)
    end
end

local function partsHeight(parts)
    local height = BASE_HEIGHT
    for _, part in ipairs(parts.active) do height = height + (part.height or 0) end
    return height
end

-- Resizing the secure frame is queued (per-frame key, latest intent wins), so
-- a height change from a parts-availability shift waits for the fight to end.
local function applyHeight(self, frame)
    local height = partsHeight(self.parts)
    app.Queue:Run("unitFrames/height/" .. frame.unitToken, function()
        if frame:GetHeight() ~= height then frame:SetHeight(height) end
    end)
end

local function create(spec)
    local frame = CreateFrame("Button", "LumaUIUnit_" .. spec.unit, UIParent, "SecureUnitButtonTemplate,BackdropTemplate")
    frame:Hide()
    frame:SetSize(246, BASE_HEIGHT)
    frame.unitToken = spec.unit
    frame.partsCreated = {}
    frame.events = CreateFrame("Frame")
    frame.events:SetScript("OnEvent", function(_, event)
        app:Call("unit/" .. spec.unit, drawEvent, frame, event)
    end)
    app.Layout:Register("unit_" .. spec.unit, frame, spec.x, spec.y, app.L.unitFrames .. " · " .. spec.unit)
    return frame
end

-- A part that was unavailable on a previous enable but exists now still gets
-- its controls before its events register; each part only builds once.
local function ensureParts(parts, frame)
    for _, part in ipairs(parts.active) do
        if not frame.partsCreated[part.id] then
            frame.partsCreated[part.id] = true
            part.create(frame)
        end
    end
end

-- Merges every available part's events into frame.events: unit events are
-- registered per unit, global events once per frame. Parts without their
-- client API contribute nothing.
local function attachEvents(parts, frame, unit)
    frame.eventParts = {}
    for _, part in ipairs(parts.active) do
        for _, event in ipairs(part.events or {}) do
            -- A single event name the current build lacks must not fail the
            -- whole component; the handler simply never fires.
            pcall(frame.events.RegisterUnitEvent, frame.events, event, unit)
            local list = frame.eventParts[event]
            if not list then list = {}; frame.eventParts[event] = list end
            list[#list + 1] = part
        end
        for _, event in ipairs(part.globalEvents or {}) do
            pcall(frame.events.RegisterEvent, frame.events, event)
            local list = frame.eventParts[event]
            if not list then list = {}; frame.eventParts[event] = list end
            list[#list + 1] = part
        end
    end
    for _, event in ipairs(FRAME_EVENTS) do
        pcall(frame.events.RegisterEvent, frame.events, event)
    end
end

-- Disabled frames must release everything at once: events, the unit watch,
-- any cast ticker and any part control a previous cycle left on screen.
local function hidePartControls(frame)
    if frame.cast then
        if frame.cast.updater then frame.cast.updater:Cancel(); frame.cast.updater = nil end
        if frame.cast:IsShown() then frame.cast:Hide() end
    end
    if frame.auraTicker then frame.auraTicker:Cancel(); frame.auraTicker = nil end
    for _, icon in ipairs(frame.auraIcons or {}) do
        if icon.count then icon.count:SetText("") end
        if icon.time then icon.time:SetText("") end
        if icon:IsShown() then icon:Hide() end
    end
    if frame.statusText then frame.statusText:SetText("") end
    if frame.mark and frame.mark:IsShown() then frame.mark:Hide() end
end

-- Native takeover, reversed on disable. Each frame records whether it was shown
-- before the takeover, so releasing it restores exactly that state and never
-- guesses. Reads are safe during combat, but these are secure frames, so every
-- Show or Hide goes through the combat queue (same key, latest intent wins).
local function nativeFrame(name)
    local frame = _G[name]
    if frame and type(frame.Hide) == "function" and type(frame.Show) == "function" then return frame end
end

local function nativeTaken(name)
    local state = component and component.native and component.native[name]
    return state ~= nil and state.taken == true
end

-- The hook only queues, so it stays safe when the client re-shows a frame
-- during combat (Edit Mode, vehicle, targeting).
local function suppressNative(name)
    if not component or not component.running or not nativeTaken(name) then return end
    app.Queue:Run(NATIVE_JOB, function()
        if not component or not component.running or not nativeTaken(name) then return end
        local frame = nativeFrame(name)
        if frame and frame:IsShown() then pcall(frame.Hide, frame) end
    end)
end

local function takeNative(name)
    local frame = nativeFrame(name)
    if not frame then return false end
    component.native = component.native or {}
    local state = component.native[name]
    if not state then
        state = { shown = frame:IsShown() and true or false }
        component.native[name] = state
    end
    state.taken = true
    if not nativeHooked[name] then
        nativeHooked[name] = true
        if type(frame.HookScript) == "function" then
            frame:HookScript("OnShow", function() suppressNative(name) end)
        end
    end
    suppressNative(name)
    return true
end

-- Gives one native frame back without touching the others: the record of what
-- the client showed before is consumed, and the frame is only re-shown when it
-- was shown before the takeover. A re-enable in the meantime keeps the frame.
local function giveNative(name)
    local state = component.native and component.native[name]
    if not state then return end
    state.taken = nil
    if not state.shown then
        component.native[name] = nil
        return
    end
    app.Queue:Run(NATIVE_JOB, function()
        if nativeTaken(name) then return end
        local frame = nativeFrame(name)
        if frame and not frame:IsShown() then pcall(frame.Show, frame) end
        if component.native then component.native[name] = nil end
    end)
end

-- Restores every recorded frame in one queued job (one queue key, so a burst of
-- state changes still touches the protected frames once, after combat).
local function releaseNatives()
    local names = {}
    for name, state in pairs(component.native or {}) do
        state.taken = nil
        names[#names + 1] = name
    end
    if #names == 0 then return end
    app.Queue:Run(NATIVE_JOB, function()
        if component.running then return end
        for index = 1, #names do
            local name = names[index]
            local state = component.native and component.native[name]
            if state and state.shown then
                local frame = nativeFrame(name)
                if frame and not frame:IsShown() then pcall(frame.Show, frame) end
            end
            if component.native then component.native[name] = nil end
        end
    end)
end

local function missingParts(parts)
    local missing = {}
    for _, id in ipairs(REPLACEMENT_PARTS) do
        local part = parts and parts[id]
        if not part or part.available ~= true then missing[#missing + 1] = id end
    end
    return missing
end

local function activePartIds(parts)
    local set = {}
    for _, part in ipairs(parts.active) do set[part.id] = true end
    return set
end

-- Decides the takeover from actual capability: no native frame is hidden while
-- the part that would have to replace it is missing. The decision is recorded
-- so `/luma status` can explain it.
local function applyTakeover(self)
    local parts = self.parts
    local missing = missingParts(parts)
    local castPart = parts ~= nil and parts.cast ~= nil and parts.cast.available == true
    self.takeover = { units = #missing == 0, cast = castPart, missing = missing }
    for _, spec in ipairs(specs) do
        if spec.native then
            if self.takeover.units then takeNative(spec.native) else giveNative(spec.native) end
        end
    end
    for _, name in ipairs(NATIVE_CAST_BARS) do
        if castPart then takeNative(name) else giveNative(name) end
    end
    if #missing > 0 and not self.warnedMissing then
        -- Once per enable cycle: a profile change must not repeat the message.
        self.warnedMissing = true
        app:Print(string.format(app.L.unitTakeoverKept, table.concat(missing, ", ")))
    end
end

component = app:RegisterComponent({ id = "unitFrames", label = "unitFrames",
    Supported = function(_, caps) return caps.units end,
    Enable = function(self)
        self.parts = app.UnitParts.Build()
        self.activeParts = activePartIds(self.parts)
        self.warnedMissing = nil
        self.frames = self.frames or {}
        self.native = {}
        for _, spec in ipairs(specs) do
            local frame = self.frames[spec.unit]
            if not frame then
                frame = create(spec)
                self.frames[spec.unit] = frame
            end
            ensureParts(self.parts, frame)
            attachEvents(self.parts, frame, spec.unit)
            RegisterUnitWatch(frame)
            drawFrame(frame)
            applyHeight(self, frame)
        end
        applyTakeover(self)
    end,
    Refresh = function(self)
        -- Re-evaluates the parts so a client that lost an API mid-session keeps
        -- its native frames instead of showing a partial replacement.
        local previous = self.activeParts or {}
        self.parts = app.UnitParts.Build()
        self.activeParts = activePartIds(self.parts)
        local lost = false
        for id in pairs(previous) do
            if not self.activeParts[id] then lost = true end
        end
        for _, frame in pairs(self.frames) do
            -- A part that disappeared leaves its controls behind; clear them
            -- before the remaining parts redraw themselves.
            if lost then hidePartControls(frame) end
            ensureParts(self.parts, frame)
            -- Registration is a set operation, so re-attaching is safe and lets a
            -- part that became available after login start receiving events.
            attachEvents(self.parts, frame, frame.unitToken)
            drawFrame(frame)
            applyHeight(self, frame)
        end
        applyTakeover(self)
    end,
    Disable = function(self)
        for _, frame in pairs(self.frames or {}) do
            frame.events:UnregisterAllEvents()
            UnregisterUnitWatch(frame)
            hidePartControls(frame)
            frame:Hide()
        end
        releaseNatives()
    end,
})

-- One diagnostic line for the components page inside `/luma status`: it says
-- which native frames the preview took over and which ones it kept because a
-- part is missing.
function component:Describe()
    if not self.running then return nil end
    local takeover = self.takeover or { units = false, cast = false, missing = {} }
    local units = takeover.units and app.L.nativeTaken or app.L.nativeKept
    local cast = takeover.cast and app.L.nativeTaken or app.L.nativeKept
    local text = string.format("unitFrames: %s=%s, %s=%s",
        app.L.nativeUnits, units, app.L.nativeCast, cast)
    local missing = takeover.missing or {}
    if #missing > 0 then
        text = text .. ", " .. app.L.nativeMissing .. ": " .. table.concat(missing, ",")
    end
    return text .. " · " .. app.L.unitCoverage
end
