local _, app = ...

-- LumaUI's own player cast bar (012 phase 08). It is a separate component from
-- the cooldown groups and from the unit frames: the player's cast has its own
-- position, its own lifetime and its own failure path.
--
-- The client's own cast frame is never hidden here. The replacement is opt-in
-- (`ui.playerCastOwned`), because the contract requires ordinary, channeled and
-- empower casts to be equally covered on the live build before the native bar
-- may step aside, and that evidence does not exist yet. When the own bar is on
-- and a cast tuple is readable, it draws; a restricted tuple hides it and the
-- client's bar keeps its place, so a cast is never lost.
--
-- Nothing secret is formatted or compared. Times are converted to plain numbers
-- first; a value Lua cannot read ends the own update instead of freezing it.

local ID = "playerCast"
local HEIGHT = 16
local component
local ticker

local function plainNumber(value)
    return app.Capabilities.Plain(value, "number")
end

local function owned()
    return app.Store:Profile().ui.playerCastOwned == true
end

local function stopTicker()
    if ticker then ticker:Cancel(); ticker = nil end
end

-- 12.1.5 duration objects. When the build exposes `UnitCastingDuration` the
-- client hands back an object that already knows how much time is left, so the
-- StatusBar can drive itself from it (`SetTimerDuration`) and Lua never computes
-- a remaining second. A restricted object is reported as "secret" and the own
-- bar declines rather than doing arithmetic on it.
--
-- "No object" is not the same as "no cast": a build (or a test scene) that has
-- the API but no live cast answers nil from every reader, which is exactly what
-- the tuple path already handles. Only a real object selects this channel.
local function durationFor(unit)
    if type(UnitCastingDuration) ~= "function" then return nil, "unavailable" end
    local ok, duration = pcall(UnitCastingDuration, unit)
    local kind = "cast"
    if ok and duration == nil then
        -- A channel or an empowered cast has its own reader; ask each in turn so
        -- a build that only knows one still draws that one.
        if type(UnitChannelDuration) == "function" then
            local called, value = pcall(UnitChannelDuration, unit)
            if called then duration, kind = value, "channel" end
        end
        if duration == nil and type(UnitEmpoweredChannelDuration) == "function" then
            local called, value = pcall(UnitEmpoweredChannelDuration, unit, true)
            if called then duration, kind = value, "empower" end
        end
    end
    if duration == nil then return nil, "idle" end
    if app.Capabilities.IsSecret(duration) then return nil, "secret" end
    if type(duration.GetRemainingDuration) ~= "function" then return nil, "unavailable" end
    return duration, nil, kind
end

local function formatRemaining(seconds)
    seconds = plainNumber(seconds)
    if not seconds then return end
    if seconds >= 10 then
        return math.floor(seconds + 0.5)
    end
    return math.floor(seconds * 10 + 0.5) / 10
end

local function readState()
    local now = type(GetTime) == "function" and select(2, pcall(GetTime)) or nil
    now = plainNumber(now)
    if not now then return nil end
    if type(UnitCastingInfo) == "function" then
        local ok, name, text, texture, startTime, endTime, _, _, notInterruptible =
            pcall(UnitCastingInfo, "player")
        if ok and name then
            startTime, endTime = plainNumber(startTime), plainNumber(endTime)
            if not startTime or not endTime or endTime <= startTime then return nil end
            return { name = app.Capabilities.Plain(text, "string") or app.Capabilities.Plain(name, "string"),
                icon = app.Capabilities.Plain(texture, "string"),
                elapsed = math.max(0, now * 1000 - startTime), duration = endTime - startTime,
                channel = false, interruptible = not (notInterruptible == true) }
        end
    end
    if type(UnitChannelInfo) == "function" then
        local ok, name, text, texture, startTime, endTime, _, notInterruptible, _, empowered, stages =
            pcall(UnitChannelInfo, "player")
        if ok and name then
            startTime, endTime = plainNumber(startTime), plainNumber(endTime)
            if not startTime or not endTime or endTime <= startTime then return nil end
            return { name = app.Capabilities.Plain(text, "string") or app.Capabilities.Plain(name, "string"),
                icon = app.Capabilities.Plain(texture, "string"),
                elapsed = math.max(0, now * 1000 - startTime), duration = endTime - startTime,
                channel = true, interruptible = not (notInterruptible == true),
                empower = app.Capabilities.Plain(empowered, "boolean") == true,
                stages = app.Capabilities.Plain(stages, "number") }
        end
    end
end

local function colorFor(state)
    if state.hold == "interrupted" then return { 0.86, 0.3, 0.3 } end
    if state.hold == "failed" then return { 0.58, 0.58, 0.62 } end
    if state.empower then return { 0.72, 0.52, 0.95 } end
    if state.channel then return { 0.42, 0.72, 0.95 } end
    if state.interruptible == false then return { 0.58, 0.58, 0.62 } end
    return { 0.92, 0.78, 0.45 }
end

-- The spark is a two-pixel vertical line pinned to the fill's leading edge. It
-- is re-anchored to the StatusBar texture rather than positioned by a number, so
-- the client's own tween carries it and no Lua frame has to move it.
local function placeSpark(self)
    local fill = self.fill
    if not fill or not self.spark or type(fill.GetStatusBarTexture) ~= "function" then return end
    local texture = fill:GetStatusBarTexture()
    if not texture then return end
    self.spark:ClearAllPoints()
    self.spark:SetPoint("CENTER", texture, "TOPRIGHT", 0, 0)
    self.spark:SetPoint("CENTER", texture, "BOTTOMRIGHT", 0, 0)
end

local function draw(self, state)
    if not self.bar then return end
    if not state then
        self.bar:Hide()
        self.state = nil
        stopTicker()
        return
    end
    local color = colorFor(state)
    self.fill:SetStatusBarColor(color[1], color[2], color[3], 1)
    -- The timer text is a formatted number the caller already made plain; a nil
    -- just leaves the previous reading instead of printing "nil".
    if state.remaining ~= nil then
        self.timer:SetFormattedText(state.remaining >= 10 and "%.0f" or "%.1f", state.remaining)
    elseif state.elapsed and state.duration and state.duration > 0 then
        local left = (state.duration - state.elapsed) / 1000
        if left >= 0 then self.timer:SetFormattedText(left >= 10 and "%.0f" or "%.1f", left) end
    end
    if state.durationObject then
        -- The client owns the fill and the countdown from its own object: no
        -- Lua arithmetic, no per-second Decimal work.
        self.fill:SetMinMaxValues(0, 1)
        if type(self.fill.SetTimerDuration) == "function" then
            pcall(self.fill.SetTimerDuration, self.fill, state.durationObject,
                _G.Enum and _G.Enum.StatusBarInterpolation
                    and _G.Enum.StatusBarInterpolation.ExponentialEaseOut or nil, nil)
        end
        self.fill:SetValue(1)
    else
        self.fill:SetMinMaxValues(0, state.duration)
        self.fill:SetValue(state.elapsed)
    end
    placeSpark(self)
    -- The spark is a progress cue, so it only shows while a cast is actually
    -- running: a held interrupt or a preview does not need a moving leading edge.
    if self.spark then
        if state.hold or state.preview then self.spark:Hide() else self.spark:Show() end
    end
    local label = state.name or ""
    if #label > 28 then label = label:sub(1, 27) .. "…" end
    self.label:SetText(label)
    if state.icon then
        self.icon:SetTexture(state.icon)
        self.icon:Show()
        self.iconFrame:Show()
    else
        self.icon:Hide()
        self.iconFrame:Hide()
    end
    -- Empower stages: short hairlines at each stage boundary, so a charged cast
    -- reads as two or three segments instead of one long anonymous bar.
    for index, divider in ipairs(self.stageLines) do
        local percent = state.stages and state.stagePercentages and state.stagePercentages[index]
        if percent then
            divider:Show()
            divider:ClearAllPoints()
            divider:SetPoint("LEFT", self.bar, "LEFT", self.bar:GetWidth() * percent, 0)
        else
            divider:Hide()
        end
    end
    self.bar:Show()
    self.state = state
end

-- Interrupted and failed casts stay on the bar for a moment, in their own
-- colour and word, instead of vanishing like a finished cast. A newer cast or
-- a stop of the component ends the hold at once.
local HOLD = 0.6
local function hold(self, kind)
    if not self.running or not owned() or not self.bar then return end
    if readState() then return end
    stopTicker()
    self.holdToken = (self.holdToken or 0) + 1
    local token = self.holdToken
    draw(self, { hold = kind, duration = 1, elapsed = 1, interruptible = true,
        name = kind == "interrupted" and app.L.castInterrupted or app.L.castFailed })
    C_Timer.After(HOLD, function()
        if self.holdToken == token and self.running then
            self.holdToken = nil
            if self.state and self.state.hold then draw(self, nil) end
        end
    end)
end

-- The own bar has two data channels, in order of preference:
--   1. 12.1.5 duration objects (`UnitCastingDuration` and friends). The object
--      goes straight into `StatusBar:SetTimerDuration`, which is why a
--      restricted cast still draws: no Lua ever reads the seconds.
--   2. `UnitCastingInfo` / `UnitChannelInfo` with plain millisecond tuples, for a
--      build without the duration API or a test scene that only has those.
-- A restricted tuple from either channel ends the own update and the client's
-- bar keeps its place; nothing is frozen at a guessed value.
local function buildState(self)
    local duration, problem, kind = durationFor("player")
    if duration then
        local icon = nil
        if type(UnitCastingInfo) == "function" then
            local ok, name, text, texture = pcall(UnitCastingInfo, "player")
            if ok and name then
                icon = app.Capabilities.Plain(texture, "string")
                self.castName = app.Capabilities.Plain(text, "string") or app.Capabilities.Plain(name, "string")
            end
        end
        if not icon and type(UnitChannelInfo) == "function" then
            local ok, name, text, texture = pcall(UnitChannelInfo, "player")
            if ok and name then
                icon = app.Capabilities.Plain(texture, "string")
                self.castName = app.Capabilities.Plain(text, "string") or app.Capabilities.Plain(name, "string")
            end
        end
        local remaining = nil
        if type(duration.GetRemainingDuration) == "function" then
            local ok, value = pcall(duration.GetRemainingDuration, duration)
            remaining = ok and app.Capabilities.Plain(value, "number") or nil
        end
        local percentages
        if kind == "empower" and type(UnitEmpoweredStagePercentages) == "function" then
            local ok, list = pcall(function()
                local results = { UnitEmpoweredStagePercentages("player", true) }
                return results
            end)
            if ok and type(list) == "table" and #list > 0 then percentages = list end
        end
        return {
            durationObject = duration,
            remaining = remaining,
            name = self.castName,
            icon = icon,
            channel = kind == "channel",
            empower = kind == "empower",
            stages = percentages and #percentages or nil,
            stagePercentages = percentages,
            interruptible = true,
        }
    end
    if problem == "secret" then return nil, "secret" end
    -- "idle"/"unavailable" from the duration reader means "this build has no
    -- object for the current cast", not "no cast": the tuple path decides.
    return readState(), problem
end

-- Unfold from 86% to the full width when a cast begins. The host clips its own
-- children, so a narrow first frame never spills outside the bar; the animation
-- is the client's, and a refused or missing group leaves the final width on the
-- frame instead of a bar stuck at 86%.
local function unfold(self)
    if not self.bar or not self.fullWidth then return end
    if not app.Transitions or not app.Transitions.MotionEnabled() then
        self.bar:SetWidth(self.fullWidth)
        return
    end
    if type(self.bar.SetClipsChildren) == "function" then
        pcall(self.bar.SetClipsChildren, self.bar, true)
    end
    app.Transitions:Animate(self, "unfold", {
        from = 0.86, to = 1, duration = 0.15,
        apply = function(value) self.bar:SetWidth(self.fullWidth * value) end,
    })
end

local function update(self)
    if not self.running or not owned() then
        if self.bar then self.bar:Hide() end
        self.holdToken, self.previewing = nil, nil
        stopTicker()
        return
    end
    self.holdToken = nil
    -- A live cast always outranks a preview: the preview is a settings aid, and
    -- leaving it on while a real cast draws would show two states on one bar.
    if self.previewing then self.previewing = nil end
    local state, problem = buildState(self)
    if state then unfold(self) end
    draw(self, state)
    -- The ticker exists only while a cast is live. A duration-object cast still
    -- needs it for the remaining-seconds text (the object has no event), but it
    -- stops with the cast and never runs while idle.
    local needsClock = state and (state.remaining ~= nil or state.durationObject == nil)
    if needsClock and not ticker then
        ticker = C_Timer.NewTicker(0.05, function()
            if not self.running or not owned() then stopTicker(); return end
            local current = buildState(self)
            if current then draw(self, current) else draw(self, nil) end
        end)
    elseif not needsClock and ticker then
        stopTicker()
    end
    if problem == "secret" then self.castReason = "secret" end
end

local function position(self)
    local central = app.Layout:Central()
    local scale = app.Layout:Scale(ID)
    if not scale or scale <= 0 then scale = 1 end
    local width = math.max(160, math.min(380, central.action.width * 0.62))
    self.fullWidth = width / scale
    self.bar:SetSize(self.fullWidth, self.height or BAR_HEIGHT)
    -- The bar's centre sits on the shared cast line (~77% from the top), clear
    -- of the action bars so a taller or hidden bar never moves it.
    local center = app.Layout:CastLine() - central.screen.height / 2
    app.Layout:SetEntryDefault(ID, 0, center / scale)
    app.Layout:Apply(ID)
end

-- The three preview kinds share one shape: a synthetic state drawn through the
-- same `draw` the live bar uses, so the preview can never look different from a
-- real cast. A preview stops at combat start (`PLAYER_REGEN_DISABLED`) and is
-- always cleared before a real cast can draw.
local PREVIEWS = {
    cast = { name = "LumaUI", duration = 1, elapsed = 0.42, icon = 134400 },
    channel = { name = "LumaUI", duration = 1, elapsed = 0.62, icon = 134400, channel = true },
    empower = { name = "LumaUI", duration = 1, elapsed = 0.55, icon = 134400, empower = true,
        stages = 3, stagePercentages = { 0.33, 0.66 } },
}

-- Native path. The client's own PlayerCastingBarFrame keeps drawing the cast
-- (timing, empower stages, interrupt state); Luma only moves it onto the shared
-- cast line. It is moved out of combat and outside Edit Mode, the old points are
-- recorded once, the new anchor is read back, and anything refused or odd hands
-- the frame back where it was. The own bar takes over only when the player
-- chose it (/luma cast).
local function editModeActive()
    local manager = _G.EditModeManagerFrame
    if not manager then return false end
    if type(manager.IsEditModeActive) == "function" then
        local ok, active = pcall(manager.IsEditModeActive, manager)
        if ok then return active == true end
    end
    if type(manager.IsShown) == "function" then
        local ok, shown = pcall(manager.IsShown, manager)
        return ok and shown == true
    end
    return false
end

local function nativeFrame()
    local frame = _G.PlayerCastingBarFrame
    if frame and type(frame.SetPoint) == "function" and type(frame.GetPoint) == "function"
        and type(frame.ClearAllPoints) == "function" then
        return frame
    end
end

local function recordNative(frame)
    if frame.lumaCastOriginal then return true end
    local count = type(frame.GetNumPoints) == "function" and frame:GetNumPoints() or 1
    count = plainNumber(count) or 0
    local points = {}
    for index = 1, count do
        local ok, point, relative, relativePoint, x, y = pcall(frame.GetPoint, frame, index)
        if not ok or not point then return false end
        x, y = plainNumber(x), plainNumber(y)
        if not x or not y then return false end
        points[#points + 1] = { point, relative, relativePoint, x, y }
    end
    if #points == 0 then return false end
    frame.lumaCastOriginal = points
    return true
end

local function restoreNative(self)
    local frame = nativeFrame()
    if not frame or not frame.lumaCastOriginal then return end
    if InCombatLockdown() or editModeActive() then
        -- Try again when the lock ends; the record stays until it is replayed.
        self.restorePending = true
        return
    end
    local points = frame.lumaCastOriginal
    pcall(frame.ClearAllPoints, frame)
    for _, saved in ipairs(points) do
        pcall(frame.SetPoint, frame, saved[1], saved[2], saved[3], saved[4], saved[5])
    end
    frame.lumaCastOriginal = nil
    self.restorePending = nil
    self.nativeMoved = nil
end

local function adaptNative(self)
    local frame = nativeFrame()
    if not frame then self.nativeMoved = nil; return end
    if owned() or self.nativeRejected then
        restoreNative(self)
        return
    end
    if InCombatLockdown() or editModeActive() then return end
    if not recordNative(frame) then self.nativeRejected = true; return end
    local central = app.Layout:Central()
    local centre = app.Layout:CastLine() - central.screen.height / 2
    pcall(frame.ClearAllPoints, frame)
    local ok = pcall(frame.SetPoint, frame, "CENTER", UIParent, "CENTER", 0, centre)
    local _, _, _, x, y = frame:GetPoint(1)
    x, y = plainNumber(x), plainNumber(y)
    if not ok or not x or not y or math.abs(x) > 0.5 or math.abs(y - centre) > 0.5 then
        -- The read-back disagrees: put it back and leave it to the client.
        self.nativeRejected = true
        restoreNative(self)
        return
    end
    self.nativeMoved = true
end

-- 019 rebuilt cast bar. The 012 version was a single 16 px rail with a centred
-- name; the visual target wants a two-layer read: a clipped square spell icon on
-- the left, the name on the bar, the remaining seconds right-aligned, a bright
-- leading spark, and — for an empowered cast — the stage boundaries drawn on the
-- fill. The host clips its children, which is also what lets the whole bar
-- unfold from 86% to full width on a cast start without a per-frame tween.
local BAR_HEIGHT = 16
local ICON_SIZE = 16
local SPARK_WIDTH = 2

component = app:RegisterComponent({ id = "playerCast", label = "playerCast", defaultEnabled = true,
    Supported = function()
        return type(UnitCastingInfo) == "function" or type(UnitChannelInfo) == "function"
            or type(UnitCastingDuration) == "function"
    end,
    Enable = function(self)
        if not self.bar then
            local bar = CreateFrame("Frame", "LumaUIPlayerCast", UIParent, "BackdropTemplate")
            bar:EnableMouse(false)
            bar:SetBackdrop({ bgFile = app.Theme.media.panel, edgeFile = app.Theme.white,
                edgeSize = app.Pixel:Pixels(1, bar),
                insets = { left = 1, right = 1, top = 1, bottom = 1 } })
            local edge = app.Theme.colors.line
            bar:SetBackdropBorderColor(edge[1], edge[2], edge[3], 0.85)
            local dark = app.Theme.colors.embedded
            bar:SetBackdropColor(dark[1] * 2.1, dark[2] * 2.1, dark[3] * 2.1, 0.94)
            -- The fill is the whole inner rectangle; the icon, the name and the
            -- countdown are drawn on top and own their own pixels.
            local fill = CreateFrame("StatusBar", nil, bar)
            fill:SetPoint("TOPLEFT", 2, -2)
            fill:SetPoint("BOTTOMRIGHT", -2, 2)
            fill:SetStatusBarTexture(app.Theme.media.combatFill)
            fill:SetMinMaxValues(0, 1)
            fill:SetValue(0)
            local spark = bar:CreateTexture(nil, "OVERLAY", nil, 4)
            spark:SetColorTexture(0.99, 0.98, 0.93, 0.95)
            spark:SetWidth(SPARK_WIDTH)
            spark:SetHeight(BAR_HEIGHT + 2)
            spark:Hide()
            -- Icon: its own small frame so the dark slot backing and the cropped
            -- texture can be drawn without touching the fill.
            local iconFrame = CreateFrame("Frame", nil, bar)
            iconFrame:SetSize(ICON_SIZE, ICON_SIZE)
            iconFrame:SetPoint("LEFT", bar, "LEFT", 2, 0)
            local iconBack = iconFrame:CreateTexture(nil, "BACKGROUND")
            iconBack:SetAllPoints()
            iconBack:SetColorTexture(0.02, 0.03, 0.05, 0.95)
            local icon = iconFrame:CreateTexture(nil, "ARTWORK")
            icon:SetPoint("TOPLEFT", 1, -1)
            icon:SetPoint("BOTTOMRIGHT", -1, 1)
            icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
            iconFrame:Hide()
            local label = app.Theme:Text(bar, 10)
            label:SetPoint("LEFT", iconFrame, "RIGHT", 6, 0)
            label:SetPoint("RIGHT", bar, "RIGHT", -42, 0)
            label:SetJustifyH("LEFT")
            label:SetWordWrap(false)
            local timer = app.Theme:Text(bar, 10)
            timer:SetPoint("RIGHT", bar, "RIGHT", -5, 0)
            timer:SetWidth(34)
            timer:SetJustifyH("RIGHT")
            timer:SetWordWrap(false)
            -- Two stage dividers cover a three-stage empowered cast; a build that
            -- reports more is clamped, not silently misaligned.
            local stageLines = {}
            for index = 1, 3 do
                local line = bar:CreateTexture(nil, "OVERLAY", nil, 3)
                line:SetWidth(1)
                line:SetPoint("TOP", bar, "TOP", 0, -2)
                line:SetPoint("BOTTOM", bar, "BOTTOM", 0, 2)
                line:SetColorTexture(0.99, 0.98, 0.93, 0.55)
                line:Hide()
                stageLines[index] = line
            end
            bar:Hide()
            self.bar, self.fill, self.label, self.timer = bar, fill, label, timer
            self.icon, self.iconFrame, self.spark, self.stageLines = icon, iconFrame, spark, stageLines
            app.Layout:Register(ID, bar, 0, 0, app.L.playerCastOwn)
        end
        self:Listen("UNIT_SPELLCAST_START", function(current, _, unit)
            if unit == "player" then update(current) end
        end)
        self:Listen("UNIT_SPELLCAST_CHANNEL_START", function(current, _, unit)
            if unit == "player" then update(current) end
        end)
        for kind, event in pairs({ interrupted = "UNIT_SPELLCAST_INTERRUPTED", failed = "UNIT_SPELLCAST_FAILED" }) do
            self:Listen(event, function(current, _, unit)
                if unit ~= "player" then return end
                if readState() then update(current) else hold(current, kind) end
            end)
        end
        for _, event in ipairs({ "UNIT_SPELLCAST_EMPOWER_START", "UNIT_SPELLCAST_EMPOWER_UPDATE",
            "UNIT_SPELLCAST_EMPOWER_STOP" }) do
            self:Listen(event, function(current, _, unit)
                if unit == "player" then update(current) end
            end)
        end
        for _, event in ipairs({ "UNIT_SPELLCAST_STOP", "UNIT_SPELLCAST_CHANNEL_STOP",
            "UNIT_SPELLCAST_CHANNEL_UPDATE", "UNIT_SPELLCAST_INTERRUPTIBLE",
            "UNIT_SPELLCAST_NOT_INTERRUPTIBLE" }) do
            self:Listen(event, function(current, _, unit)
                if unit == "player" then update(current) end
            end)
        end
        self:Listen("PLAYER_ENTERING_WORLD", function(current)
            if current.previewing then current:StopPreview() end
            update(current)
        end)
        -- A preview is a settings aid, so entering combat ends it at once: the
        -- live bar must not be showing a synthetic cast when a real one starts.
        self:Listen("PLAYER_REGEN_DISABLED", function(current)
            if current.previewing then current:StopPreview() end
        end)
        app:Subscribe(self, "LAYOUT_CENTRAL_CHANGED", function()
            if self.running then
                app:Call("playerCast/position", position, self)
                app:Call("playerCast/native", adaptNative, self)
            end
        end)
        self:Listen("PLAYER_REGEN_ENABLED", function(current)
            if current.restorePending then restoreNative(current) end
            adaptNative(current)
        end)
        position(self)
        adaptNative(self)
        update(self)
        if app.Ownership then
            app.Ownership:Set("playerCast", {
                intent = owned() and "owned" or "native",
                active = "native", evidence = "none",
                reason = "awaiting-native-parity",
            })
        end
    end,
    Refresh = function(self)
        position(self)
        adaptNative(self)
        update(self)
        if app.Ownership then
            app.Ownership:Set("playerCast", {
                intent = owned() and "owned" or "native",
                active = "native", evidence = "none",
                reason = "awaiting-native-parity",
            })
        end
    end,
    Disable = function(self)
        self.holdToken = nil
        restoreNative(self)
        stopTicker()
        if self.bar then
            self.bar:Hide()
            app.Layout.entries[ID] = nil
        end
        if app.Ownership then app.Ownership:Active("playerCast", "native", "component-off") end
    end,
})

function component:Toggle()
    local wanted = not owned()
    if not app.Store:Set("ui", "playerCastOwned", wanted) then
        app:Print(app.L.readonly)
        return
    end
    app:Print(wanted and app.L.playerCastOn or app.L.playerCastOff)
    if self.running then self:Refresh() end
end

-- Preview entry points for the settings page. `kind` is "cast", "channel" or
-- "empower"; anything else is refused instead of drawing a half state.
function component:StartPreview(kind)
    if not self.running or not self.bar then return false end
    local spec = PREVIEWS[kind]
    if not spec then return false end
    local state = {}
    for key, value in pairs(spec) do state[key] = value end
    state.preview = true
    self.previewing = kind
    unfold(self)
    draw(self, state)
    return true
end

function component:StopPreview()
    if not self.previewing then return false end
    self.previewing = nil
    draw(self, nil)
    return true
end

function component:Diagnose()
    local native = _G.PlayerCastingBarFrame
    local nativeShown = "?"
    if native and type(native.IsShown) == "function" then
        local ok, shown = pcall(native.IsShown, native)
        nativeShown = ok and (shown and "yes" or "no") or "?"
    end
    local ownShown = self.bar and self.bar:IsShown() and "yes" or "no"
    local state = self.state
    app:Print(string.format("playerCast: running=%s owned=%s drawn=%s native=%s",
        self.running and "yes" or "no", owned() and "yes" or "no", ownShown, nativeShown))
    if state then
        app:Print(string.format("  state: channel=%s interruptible=%s duration=%.0fms",
            state.channel and "yes" or "no", state.interruptible == false and "no" or "yes",
            state.duration))
    else
        app:Print("  " .. app.L.playerCastIdle)
    end
end
