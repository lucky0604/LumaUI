local _, app = ...

-- Party prototype (M3 plan item 6): four fixed secure unit buttons for
-- party1..party4, built exactly like the player/target preview that already
-- works in game — a SecureUnitButtonTemplate button plus RegisterUnitWatch —
-- instead of a secure group header. The group header machinery creates its
-- buttons in secured code whose attribute contract changes between builds;
-- four explicit watched buttons behave the same on every client and never
-- leave the party without frames.
--
-- Protected rules: buttons are created, sized and given their attributes out
-- of combat through the queue, and their visibility is driven by
-- RegisterUnitWatch, not by Lua. Event redraws only touch drawing methods on
-- non-protected controls. Secret rules: names go straight to SetText, unit
-- values only reach native bar methods, and nothing here does arithmetic,
-- comparison, concatenation or persistence with a restricted value.
--
-- The native party frame is hidden only while at least one party unit exists,
-- and restored as soon as the group is gone or the component stops, so a
-- failure can never leave a player with no party frames at all.
--
-- Private auras: the native party frame draws an encounter's private auras
-- through its own secure anchors, so taking it away without a replacement would
-- lose them. Each party button reserves three native display slots (aura
-- indexes 1..3) in its bottom-right corner, one per private aura the client has
-- for that member, in the client's own priority order. The icons, stacks and
-- countdowns are drawn by the client; nothing here reads or reasons about the
-- aura itself. The takeover therefore also requires the anchor API — a client
-- without it keeps the native party frame instead of a replacement that would
-- silently drop private auras.

local PARTY_UNITS = { party1 = 1, party2 = 2, party3 = 3, party4 = 4 }
local ORDER = { "party1", "party2", "party3", "party4" }
local UNIT_EVENTS = { "UNIT_HEALTH", "UNIT_MAXHEALTH", "UNIT_POWER_UPDATE", "UNIT_MAXPOWER",
    "UNIT_NAME_UPDATE", "UNIT_DISPLAYPOWER", "UNIT_FLAGS", "UNIT_CONNECTION" }
local GLOBAL_EVENTS = { "GROUP_ROSTER_UPDATE", "PLAYER_ENTERING_WORLD", "PLAYER_REGEN_ENABLED" }
local BUILD_JOB = "partyFrames/build"
local NATIVE_JOB = "partyFrames/native"
local PRIVATE_JOB = "partyFrames/private"
-- Two native party displays exist on Retail: the classic PartyFrame and the
-- raid-style CompactPartyFrame used when the player enables raid-style party
-- frames. Suppressing only PartyFrame left the raid-style block on screen next
-- to ours, so both are recorded, pressed down and restored independently.
local NATIVE_NAMES = { "PartyFrame", "CompactPartyFrame" }
local FRAME_WIDTH, FRAME_HEIGHT, FRAME_GAP = 190, 46, 4
-- The four buttons are one layout item now: a plain container carries the group
-- position and scale, members keep their relative offsets. The default centre
-- and size describe the old absolute block (-270, top -300), so upgrading keeps
-- the original on-screen position.
local GROUP_ID = "party"
local GROUP_X, GROUP_Y = -270, -375
local GROUP_WIDTH, GROUP_HEIGHT = 190, 196
-- Private aura slots: the native compact party frame reserves five private aura
-- displays per member (CompactUnitFrameTemplate, maxPrivateAuras = 5), so the
-- replacement reserves the same five along the bottom edge of the button, in the
-- client's own priority order. They overlay the bar the way the native display
-- does; none of their content is read here.
local PRIVATE_SLOTS = 5
local PRIVATE_ICON = 12
local PRIVATE_STEP = -14
local PRIVATE_OPTIONS = { size = PRIVATE_ICON, point = "BOTTOMRIGHT",
    offsetX = -8, offsetY = 8, step = PRIVATE_STEP }
local component

local function slotY(index) return -300 - (index - 1) * (FRAME_HEIGHT + FRAME_GAP) end

local function groupSpec()
    return { label = app.L.partyGroup, x = GROUP_X, y = GROUP_Y,
        width = GROUP_WIDTH, height = GROUP_HEIGHT }
end

local function draw(frame)
    local unit = frame.unitToken
    if not UnitExists(unit) then
        app.MemberInfo.Clear(frame.role, frame.status)
        return
    end
    frame.name:SetText(UnitName(unit))
    -- Secret values go straight to engine drawing, never through Lua maths.
    frame.health:SetMinMaxValues(0, UnitHealthMax(unit))
    frame.health:SetValue(UnitHealth(unit))
    frame.power:SetMinMaxValues(0, UnitPowerMax(unit))
    frame.power:SetValue(UnitPower(unit))
    app.Theme:PaintBar(frame.health, app.Theme:UnitColor(unit))
    app.Theme:PaintBar(frame.power, app.Theme:PowerColor(unit))
    -- Role and death/offline live in their own fixed areas; both disappear when
    -- the client only reports restricted values.
    app.MemberInfo.Draw(unit, frame.role, frame.status)
end

local function create(unit)
    local index = PARTY_UNITS[unit]
    local frame = CreateFrame("Button", "LumaUIParty" .. index, UIParent, "SecureUnitButtonTemplate")
    frame:Hide()
    frame:SetSize(FRAME_WIDTH, FRAME_HEIGHT)
    frame.unitToken = unit
    frame:RegisterForClicks("AnyUp")
    frame:SetAttribute("unit", unit)
    frame:SetAttribute("*type1", "target")
    frame:SetAttribute("*type2", "togglemenu")
    frame.name = app.Theme:Text(frame, 11)
    frame.name:SetPoint("TOPLEFT", 8, -4)
    -- The role glyph owns the top right corner; the name stops before it.
    frame.name:SetWidth(FRAME_WIDTH - 30)
    if type(frame.name.SetShadowOffset) == "function" then
        pcall(frame.name.SetShadowOffset, frame.name, 1, -1)
    end
    if type(frame.name.SetShadowColor) == "function" then
        pcall(frame.name.SetShadowColor, frame.name, 0, 0, 0, 0.85)
    end
    frame.role = app.Theme:Text(frame, 10)
    frame.role:SetPoint("TOPRIGHT", -8, -4)
    frame.role:SetWidth(12)
    frame.role:SetJustifyH("RIGHT")
    frame.role:SetText("")
    frame.health = app.Theme:Bar(frame, 16)
    frame.health:SetPoint("TOPLEFT", 8, -20)
    frame.health:SetPoint("TOPRIGHT", -8, -20)
    frame.status = app.Theme:Text(frame.health, 10)
    frame.status:SetPoint("CENTER")
    frame.status:SetText("")
    frame.power = app.Theme:Bar(frame, 4)
    frame.power:SetPoint("TOPLEFT", 8, -40)
    frame.power:SetPoint("TOPRIGHT", -8, -40)
    frame.events = CreateFrame("Frame")
    frame.events:SetScript("OnEvent", function()
        app:Call("partyFrames/" .. unit, draw, frame)
    end)
    return frame
end

-- The native party frame is secure: every Show/Hide goes through the queue,
-- the state it had before the takeover is recorded once per enable cycle, and
-- an OnShow hook presses it back down while the prototype runs. The hook is
-- installed once for the session (guarded on the native frame itself), so
-- stop/start cycles never stack hooks.
local function nativeFrame(name)
    local frame = _G[name]
    if frame and type(frame.Hide) == "function" and type(frame.Show) == "function" then return frame end
end

local function nativeFrames()
    local frames = {}
    for _, name in ipairs(NATIVE_NAMES) do
        local frame = nativeFrame(name)
        if frame then frames[#frames + 1] = frame end
    end
    return frames
end

local function suppressNative()
    if not component.running or not component.nativeHidden then return end
    app.Queue:Run(NATIVE_JOB, function()
        if not component.running or not component.nativeHidden then return end
        for _, frame in ipairs(nativeFrames()) do
            if frame:IsShown() then pcall(frame.Hide, frame) end
        end
    end)
end

-- A unit counts as covered only while our own watched button for it is actually
-- on screen. A button that was never registered, failed to show or was released
-- is not a reason to take the native frame away.
local function memberCovered(unit)
    local frame = component.frames and component.frames[unit]
    if not frame or not frame.lumaWatched then return false end
    local ok, shown = pcall(frame.IsShown, frame)
    return ok and shown == true
end

local function anyPartyMember()
    for _, unit in ipairs(ORDER) do
        if UnitExists(unit) and memberCovered(unit) then return true end
    end
    return false
end

local function hideNative(self)
    local frames = nativeFrames()
    if #frames == 0 then return end
    if self.nativeShown == nil then
        self.nativeShown = {}
        for _, frame in ipairs(frames) do
            self.nativeShown[frame] = frame:IsShown() and true or false
        end
    end
    self.nativeHidden = true
    for _, frame in ipairs(frames) do
        if not frame.lumaPartySuppress then
            frame.lumaPartySuppress = true
            if type(frame.HookScript) == "function" then
                frame:HookScript("OnShow", function() suppressNative() end)
            end
        end
    end
    suppressNative()
end

local function restoreNative(self)
    self.nativeHidden = nil
    local shown = self.nativeShown
    self.nativeShown = nil
    if not shown then return end
    app.Queue:Run(NATIVE_JOB, function()
        if component.running and component.nativeHidden then return end
        for _, frame in ipairs(nativeFrames()) do
            if shown[frame] and not frame:IsShown() then pcall(frame.Show, frame) end
        end
    end)
end

-- Decides the takeover from what is actually on screen: with party members the
-- native frame is hidden, without them it is given back. Private auras are part
-- of the native frame's job, so the replacement only counts as complete when
-- every button holds its native anchor slots; otherwise the native frame stays.
local function privateCovered(self)
    if not app.PrivateAuras.Available() then return false end
    for _, unit in ipairs(ORDER) do
        local frame = self.frames and self.frames[unit]
        if memberCovered(unit) and not (frame and frame.lumaPrivateComplete) then return false end
    end
    return true
end

-- Attaches the native slots for members the client reports and releases them
-- for members that left, so a reused button never shows another member's
-- private aura. Runs from the queue only: the slots live on secure buttons.
local function syncPrivate(self)
    for _, unit in ipairs(ORDER) do
        local frame = self.frames and self.frames[unit]
        if frame then
            if UnitExists(unit) and memberCovered(unit) then
                app.PrivateAuras.Attach(frame, unit, PRIVATE_SLOTS, PRIVATE_OPTIONS)
            else
                app.PrivateAuras.Release(frame)
            end
        end
    end
end

local function syncNative(self)
    if anyPartyMember() and privateCovered(self) then hideNative(self) else restoreNative(self) end
end

local function drawAll(self)
    for _, unit in ipairs(ORDER) do
        local frame = self.frames and self.frames[unit]
        if frame then app:Call("partyFrames/draw/" .. unit, draw, frame) end
    end
end

component = app:RegisterComponent({ id = "partyFrames", label = "partyFrames", defaultEnabled = false,
    Supported = function(_, caps) return caps.units end,
    Enable = function(self)
        self.frames = self.frames or {}
        -- Building secure buttons and registering their watches is protected:
        -- the whole job waits for combat to end.
        app.Queue:Run(BUILD_JOB, function()
            if not self.running then return end
            for _, unit in ipairs(ORDER) do
                local frame = self.frames[unit]
                if not frame then
                    frame = create(unit)
                    self.frames[unit] = frame
                end
                -- The four buttons join one group; moving or scaling the group
                -- is one layout item, members keep their relative offsets.
                app.Layout:Join(GROUP_ID, "party_" .. unit, frame, -270, slotY(PARTY_UNITS[unit]), groupSpec())
                for _, event in ipairs(UNIT_EVENTS) do
                    pcall(frame.events.RegisterUnitEvent, frame.events, event, unit)
                end
                -- No panel behind these: like the player/target preview they
                -- are a name and two bars floating over the world.
                local watched = pcall(RegisterUnitWatch, frame)
                frame.lumaWatched = watched or nil
                draw(frame)
            end
            syncPrivate(self)
            syncNative(self)
        end)
        for _, event in ipairs(GLOBAL_EVENTS) do
            self:Listen(event, function(current)
                drawAll(current)
                -- Anchor slots follow the members: a member who left releases
                -- its slots, a new one gets its own. Queued so a roster change
                -- in combat re-points the secure anchors after the fight.
                app.Queue:Run(PRIVATE_JOB, function()
                    if not current.running then return end
                    syncPrivate(current)
                    syncNative(current)
                end)
            end)
        end
    end,
    Refresh = function(self)
        drawAll(self)
        app.Queue:Run(PRIVATE_JOB, function()
            if not self.running then return end
            syncPrivate(self)
            syncNative(self)
        end)
    end,
    Disable = function(self)
        for _, frame in pairs(self.frames or {}) do
            frame.events:UnregisterAllEvents()
            UnregisterUnitWatch(frame)
            frame.lumaWatched = nil
            app.PrivateAuras.Release(frame)
            app.MemberInfo.Clear(frame.role, frame.status)
            frame:Hide()
        end
        app.Queue:Run(NATIVE_JOB, function() restoreNative(self) end)
    end,
})

-- Diagnostics for `/luma status`: which native frame the prototype took over.
-- When the native frame stays because private aura anchors are unavailable, the
-- coverage line still names them, so the state is not misread as full parity.
function component:Describe()
    if not self.running then return nil end
    local state = self.nativeHidden and app.L.nativeTaken or app.L.nativeKept
    return string.format("partyFrames: %s (%s) · %s", state, app.L.partyFrames, app.L.partyCoverage)
end

-- `/luma party`: prints what the party prototype actually sees, so a report
-- like "no party frames" can be diagnosed without guessing.
function component:Diagnose()
    local function yes(value) return value and "yes" or "no" end
    local inGroup = type(IsInGroup) == "function" and IsInGroup() == true
    app:Print(string.format("partyFrames: status=%s running=%s inGroup=%s",
        tostring(self.status), yes(self.running), yes(inGroup)))
    for _, name in ipairs(NATIVE_NAMES) do
        local native = nativeFrame(name)
        app:Print(string.format("  native %s: exists=%s shown=%s",
            name, yes(native ~= nil), yes(native and native.IsShown and native:IsShown())))
    end
    for _, unit in ipairs(ORDER) do
        local frame = self.frames and self.frames[unit]
        local shown, left, top = nil, nil, nil
        if frame then
            if frame.IsShown then local ok, v = pcall(frame.IsShown, frame); shown = ok and v or nil end
            if frame.GetLeft then local ok, v = pcall(frame.GetLeft, frame); left = ok and v or nil end
            if frame.GetTop then local ok, v = pcall(frame.GetTop, frame); top = ok and v or nil end
        end
        app:Print(string.format("  %s: exists=%s frame=%s shown=%s at=%s,%s",
            unit, yes(UnitExists(unit) == true), yes(frame ~= nil), yes(shown),
            tostring(left or "?"), tostring(top or "?")))
    end
end
