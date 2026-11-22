local _, app = ...
-- The target-of-target preview sits below the target preview.
local specs = {
    { unit = "player", x = -270, y = -185, native = "PlayerFrame" },
    { unit = "target", x = 270, y = -185, native = "TargetFrame" },
    { unit = "targettarget", x = 270, y = -300, native = nil },
    { unit = "focus", x = 420, y = 60, native = "FocusFrame" },
    { unit = "pet", x = -270, y = -268, native = "PetFrame" },
}

local BASE_HEIGHT = 66
-- Part availability is diagnostic only; it does not prove native parity.
local REPLACEMENT_PARTS = { "bars", "cast", "auras" }
local FRAME_EVENTS = { "PLAYER_ENTERING_WORLD", "PLAYER_TARGET_CHANGED", "PLAYER_FOCUS_CHANGED", "UNIT_PET" }
local component

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

-- Capability probes establish what the preview can draw, but they do not
-- establish parity with the native frame (including private encounter auras).
-- The takeover switch is an explicit per-profile choice (/luma takeover), never
-- a default: hiding native unit frames is opt-in and reversible, and a missing
-- replacement part always wins back the native frame regardless of the switch.
local TAKEOVER_FRAMES = { "PlayerFrame", "TargetFrame", "FocusFrame", "PetFrame", "TargetFrameToT" }

local function nativeFrameOf(name)
    local frame = _G[name]
    if frame and type(frame.Hide) == "function" and type(frame.Show) == "function" then return frame end
end

local function frameShown(frame)
    if not frame or type(frame.IsShown) ~= "function" then return false end
    local ok, shown = pcall(frame.IsShown, frame)
    return ok and shown == true
end

local function suppressNativeFrames(self)
    if not self.nativeShown then
        self.nativeShown = {}
        for _, name in ipairs(TAKEOVER_FRAMES) do
            local frame = nativeFrameOf(name)
            if frame then self.nativeShown[name] = { shown = frameShown(frame) } end
        end
    end
    self.nativeSuppressed = true
    app.Queue:Run("unitFrames/native", function()
        if not component.running or not component.nativeSuppressed then return end
        for _, name in ipairs(TAKEOVER_FRAMES) do
            local state = component.nativeShown and component.nativeShown[name]
            if state and state.shown then
                local frame = nativeFrameOf(name)
                if frame and frameShown(frame) then pcall(frame.Hide, frame) end
            end
        end
    end)
end

local function restoreNativeFrames(self)
    local shown = self.nativeShown
    self.nativeSuppressed = nil
    self.nativeShown = nil
    if not shown then return end
    app.Queue:Run("unitFrames/native", function()
        if component.running and component.nativeSuppressed then return end
        for _, name in ipairs(TAKEOVER_FRAMES) do
            if shown[name] and shown[name].shown then
                local frame = nativeFrameOf(name)
                if frame and not frameShown(frame) then pcall(frame.Show, frame) end
            end
        end
    end)
end

local function applyTakeover(self)
    local missing = missingParts(self.parts)
    -- The switch reads the profile every evaluation, so /luma takeover applies
    -- without an enable cycle. Parts missing or the private-aura anchor API
    -- unavailable keep every native frame regardless of the switch: without
    -- anchors an encounter's private auras would have nowhere to draw.
    -- The native buff/debuff frames keep drawing the player's private auras;
    -- the client anchors them to PlayerFrame.unit, not to anything this
    -- preview draws, so hiding the player frame does not orphan them.
    local wanted = app.Store:Profile().ui.takeoverUnitFrames == true
    local anchored = app.PrivateAuras.Available()
    local units = wanted and anchored and #missing == 0
    local cast = wanted and anchored and #missing == 0
    self.takeover = { units = units, cast = cast, missing = missing }
    if units then
        suppressNativeFrames(self)
    else
        restoreNativeFrames(self)
    end
    if #missing > 0 and not self.warnedMissing then
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
        -- The native frames come back even though the component stops: the
        -- restore job runs after the stop, so the guard inside checks nothing.
        restoreNativeFrames(self)
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
    return text .. " · " .. app.L.nativeAwaitingValidation .. " · " .. app.L.unitCoverage
end
