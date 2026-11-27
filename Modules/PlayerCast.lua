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

local function readState()
    local now = type(GetTime) == "function" and select(2, pcall(GetTime)) or nil
    now = plainNumber(now)
    if not now then return nil end
    if type(UnitCastingInfo) == "function" then
        local ok, name, text, _, startTime, endTime, _, _, notInterruptible = pcall(UnitCastingInfo, "player")
        if ok and name then
            startTime, endTime = plainNumber(startTime), plainNumber(endTime)
            if not startTime or not endTime or endTime <= startTime then return nil end
            return { name = app.Capabilities.Plain(text, "string") or app.Capabilities.Plain(name, "string"),
                elapsed = math.max(0, now * 1000 - startTime), duration = endTime - startTime,
                channel = false, interruptible = not (notInterruptible == true) }
        end
    end
    if type(UnitChannelInfo) == "function" then
        local ok, name, text, _, startTime, endTime, _, notInterruptible, _, empowered, stages =
            pcall(UnitChannelInfo, "player")
        if ok and name then
            startTime, endTime = plainNumber(startTime), plainNumber(endTime)
            if not startTime or not endTime or endTime <= startTime then return nil end
            return { name = app.Capabilities.Plain(text, "string") or app.Capabilities.Plain(name, "string"),
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

local function draw(self, state)
    if not self.bar then return end
    if not state then
        self.bar:Hide()
        self.state = nil
        stopTicker()
        return
    end
    local color = colorFor(state)
    self.fill:SetMinMaxValues(0, state.duration)
    self.fill:SetValue(state.elapsed)
    self.fill:SetStatusBarColor(color[1], color[2], color[3], 1)
    local label = state.name or ""
    if #label > 28 then label = label:sub(1, 27) .. "…" end
    self.label:SetText(label)
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

local function update(self)
    if not self.running or not owned() then
        if self.bar then self.bar:Hide() end
        self.holdToken = nil
        stopTicker()
        return
    end
    self.holdToken = nil
    local state = readState()
    draw(self, state)
    if state and not ticker then
        ticker = C_Timer.NewTicker(0.1, function()
            if not self.running or not owned() then stopTicker(); return end
            local current = readState()
            if current then draw(self, current) else draw(self, nil) end
        end)
    end
end

local function position(self)
    local central = app.Layout:Central()
    local scale = app.Layout:Scale(ID)
    if not scale or scale <= 0 then scale = 1 end
    local width = math.max(160, math.min(380, central.action.width * 0.62))
    self.bar:SetSize(width / scale, HEIGHT)
    -- The bar's centre sits on the shared cast line (~77% from the top), clear
    -- of the action bars so a taller or hidden bar never moves it.
    local center = app.Layout:CastLine() - central.screen.height / 2
    app.Layout:SetEntryDefault(ID, 0, center / scale)
    app.Layout:Apply(ID)
end

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

component = app:RegisterComponent({ id = "playerCast", label = "playerCast", defaultEnabled = true,
    Supported = function()
        return type(UnitCastingInfo) == "function" or type(UnitChannelInfo) == "function"
    end,
    Enable = function(self)
        if not self.bar then
            local bar = CreateFrame("Frame", "LumaUIPlayerCast", UIParent, "BackdropTemplate")
            bar:EnableMouse(false)
            bar:SetBackdrop({ bgFile = app.Theme.media.panel, edgeFile = app.Theme.white,
                edgeSize = app.Pixel:Pixels(1, bar),
                insets = { left = 1, right = 1, top = 1, bottom = 1 } })
            local edge = app.Theme.colors.line
            bar:SetBackdropBorderColor(edge[1], edge[2], edge[3], 1)
            local dark = app.Theme.colors.embedded
            bar:SetBackdropColor(dark[1] * 2.1, dark[2] * 2.1, dark[3] * 2.1, 0.94)
            local fill = CreateFrame("StatusBar", nil, bar)
            fill:SetPoint("TOPLEFT", 2, -2)
            fill:SetPoint("BOTTOMRIGHT", -2, 2)
            fill:SetStatusBarTexture(app.Theme.media.combatFill)
            fill:SetMinMaxValues(0, 1)
            fill:SetValue(0)
            local label = app.Theme:Text(bar, 10)
            label:SetPoint("CENTER")
            label:SetSize(200, 12)
            label:SetJustifyH("CENTER")
            label:SetWordWrap(false)
            bar:Hide()
            self.bar, self.fill, self.label = bar, fill, label
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
        self:Listen("PLAYER_ENTERING_WORLD", function(current) update(current) end)
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
