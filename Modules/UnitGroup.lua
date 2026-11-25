local _, app = ...

-- Optional party preview: four watched secure buttons. Native party frames stay
-- under client control until interaction and encounter parity is validated.
-- Secure objects and private-aura anchors are configured outside combat; unit
-- values are passed to native drawing methods without secret-value operations.
-- Five client-drawn private aura slots are reserved for each visible member.

local PARTY_UNITS = { party1 = 1, party2 = 2, party3 = 3, party4 = 4 }
local ORDER = { "party1", "party2", "party3", "party4" }
local UNIT_EVENTS = { "UNIT_HEALTH", "UNIT_MAXHEALTH", "UNIT_POWER_UPDATE", "UNIT_MAXPOWER",
    "UNIT_NAME_UPDATE", "UNIT_DISPLAYPOWER", "UNIT_FLAGS", "UNIT_CONNECTION" }
local GLOBAL_EVENTS = { "GROUP_ROSTER_UPDATE", "PLAYER_ENTERING_WORLD", "PLAYER_REGEN_ENABLED" }
local BUILD_JOB = "partyFrames/build"
local NATIVE_JOB = "partyFrames/native"
-- The Pearl batch ships the party replacement enabled. Native frames are hidden
-- only while every visible member is covered by a watched LumaUI button and the
-- client has accepted all private-aura anchors; otherwise they stay untouched.
local NATIVE_PARITY_VALIDATED = true
local PRIVATE_JOB = "partyFrames/private"
-- Both client-owned party displays are reported in diagnostics.
local NATIVE_NAMES = { "PartyFrame", "CompactPartyFrame" }
local P = app.Theme.party
-- Row height has one owner: the theme's `height`. The compact row keeps the
-- name, the health bar and a hairline power bar on the left, and reserves the
-- right column for the role glyph and the native private-aura anchors.
local FRAME_WIDTH, FRAME_HEIGHT, FRAME_GAP = P.width, P.height, P.gap
local RIGHT_COLUMN = P.right or 74
-- Vertical positions inside the row, measured from its top edge.
local NAME_TOP, HEALTH_TOP, POWER_TOP = -2, -15, -25
-- The four buttons are one layout item: a plain container carries the group
-- position and scale, members keep their relative offsets. Pearl puts the party
-- block on the left edge, level with the central unit bars.
local GROUP_ID = "party"
-- Mockup proportions: the group's left edge lands at ~15.5% of the screen width
-- and the first row's top edge at ~48.5% of the screen height. Both are resolved
-- from the live screen instead of a fixed offset, so the block keeps the same
-- relative place on a 1920 wide screen and on a narrow window.
local GROUP_LEFT_RATIO = 0.155
local GROUP_ROW_TOP_RATIO = 0.485
local GROUP_WIDTH, GROUP_HEIGHT = P.width, 4 * (FRAME_HEIGHT + FRAME_GAP)
-- Private aura slots: the native compact party frame reserves five private aura
-- displays per member (CompactUnitFrameTemplate, maxPrivateAuras = 5), so the
-- replacement reserves the same five along the bottom edge of the button, in the
-- client's own priority order. They sit below the power bar; none of their
-- content is read here. Sizes come from the theme so the row height and the band
-- are one decision.
local PRIVATE = P.private or {}
local PRIVATE_SLOTS = PRIVATE.slots or 5
local PRIVATE_ICON = PRIVATE.icon or 12
local PRIVATE_STEP = -(PRIVATE.step or 14)
local PRIVATE_OPTIONS = { size = PRIVATE_ICON, point = "BOTTOMRIGHT",
    offsetX = -(PRIVATE.inset or 8), offsetY = PRIVATE.bottom or 3, step = PRIVATE_STEP }
-- UnitClass tokens are all-caps; the shipped portrait files are not. The map is
-- data, not a lookup into the client's class icons, so a missing file simply
-- hides the portrait instead of failing the row.
local CLASS_ICON = {
    WARRIOR = "Warrior", PALADIN = "Paladin", HUNTER = "Hunter", ROGUE = "Rogue",
    PRIEST = "Priest", DEATHKNIGHT = "DeathKnight", SHAMAN = "Shaman", MAGE = "Mage",
    WARLOCK = "Warlock", MONK = "Monk", DRUID = "Druid", DEMONHUNTER = "DemonHunter",
    EVOKER = "Evoker",
}
local component

local function screenSize()
    local okWidth, width = pcall(UIParent.GetWidth, UIParent)
    local okHeight, height = pcall(UIParent.GetHeight, UIParent)
    width = okWidth and app.Capabilities.Plain(width, "number") or nil
    height = okHeight and app.Capabilities.Plain(height, "number") or nil
    if not width or width <= 0 then width = 1920 end
    if not height or height <= 0 then height = 1080 end
    return width, height
end

-- Whole screen units: a sub-pixel offset would land in saved profiles as a
-- long decimal and make every later comparison inexact for no visible gain.
local function whole(value)
    return math.floor(value + 0.5)
end

-- Centre offset of the whole group, resolved once per build from the live screen.
local function groupOrigin()
    local width, height = screenSize()
    local x = -width / 2 + width * GROUP_LEFT_RATIO + GROUP_WIDTH / 2
    -- The first row's centre sits `height * (0.5 - ratio)` above the screen
    -- centre; the group centre is half a block lower than that.
    local y = height * (0.5 - GROUP_ROW_TOP_RATIO) - GROUP_HEIGHT / 2 + FRAME_HEIGHT / 2
    return whole(x), whole(y)
end

-- Members are anchored from the group's top edge; the default absolute value
-- mirrors what Layout:Join would derive, so a fresh profile starts with rx=0.
local function slotY(index, groupY)
    if not groupY then _, groupY = groupOrigin() end
    local top = groupY + GROUP_HEIGHT / 2 - FRAME_HEIGHT / 2
    return top - (index - 1) * (FRAME_HEIGHT + FRAME_GAP)
end

local function groupSpec()
    local x, y = groupOrigin()
    return { label = app.L.partyGroup, x = x, y = y,
        width = GROUP_WIDTH, height = GROUP_HEIGHT }
end

local function classIcon(frame, unit)
    if not frame.classIcon then return end
    -- The icon lives on a secure button. Its texture is a visual update, but the
    -- harness (and a strict client) treats that write as protected in combat, so
    -- the icon refreshes on the next out-of-combat roster/health paint.
    if type(InCombatLockdown) == "function" and InCombatLockdown() then return end
    local ok, _, token = pcall(UnitClass, unit)
    token = ok and app.Capabilities.Plain(token, "string") or nil
    if not token or not token:match("^[%u%l]+$") then
        frame.classIcon:Hide()
        return
    end
    local file = CLASS_ICON[token]
    if not file then
        frame.classIcon:Hide()
        return
    end
    local okSet = pcall(frame.classIcon.SetTexture, frame.classIcon, "Interface\\Icons\\ClassIcon_" .. file)
    if okSet then frame.classIcon:Show() else frame.classIcon:Hide() end
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
    classIcon(frame, unit)
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
    -- A quiet row plate: the portrait and the text column float on it, and the
    -- plate stops before the reserved right column so the aura anchors sit on
    -- transparent space instead of a painted band.
    local plate = frame:CreateTexture(nil, "BACKGROUND")
    plate:SetPoint("TOPLEFT", -2, 2)
    plate:SetPoint("BOTTOMRIGHT", -RIGHT_COLUMN + 2, -2)
    local surface = app.Theme.colors.surface
    plate:SetColorTexture(surface[1] * 1.6, surface[2] * 1.6, surface[3] * 1.6, 0.35)
    frame.plate = plate
    frame.classIcon = frame:CreateTexture(nil, "ARTWORK")
    frame.classIcon:SetSize(P.icon, P.icon)
    frame.classIcon:SetPoint("TOPLEFT", 2, -2)
    frame.classIcon:SetTexture("Interface\\Icons\\ClassIcon_WARRIOR")
    frame.name = app.Type:Text(frame, "body")
    frame.name:SetPoint("TOPLEFT", P.textInset, NAME_TOP)
    -- The role glyph owns the top right corner; the name stops before the
    -- reserved column so it never runs under the role or the aura anchors.
    frame.name:SetWidth(FRAME_WIDTH - P.textInset - RIGHT_COLUMN)
    frame.name:SetFont(app.Type:Face(), P.nameSize, "OUTLINE")
    if type(frame.name.SetShadowOffset) == "function" then
        pcall(frame.name.SetShadowOffset, frame.name, 1, -1)
    end
    if type(frame.name.SetShadowColor) == "function" then
        pcall(frame.name.SetShadowColor, frame.name, 0, 0, 0, 0.85)
    end
    frame.role = app.Type:Text(frame, "micro")
    frame.role:SetPoint("TOPRIGHT", -6, -3)
    frame.role:SetWidth(12)
    frame.role:SetJustifyH("RIGHT")
    frame.role:SetText("")
    frame.health = app.Theme:Bar(frame, P.health)
    frame.health:SetPoint("TOPLEFT", P.textInset, HEALTH_TOP)
    frame.health:SetPoint("TOPRIGHT", -RIGHT_COLUMN, HEALTH_TOP)
    frame.healthEdge = CreateFrame("Frame", nil, frame.health, "BackdropTemplate")
    frame.healthEdge:SetPoint("TOPLEFT", -1, 1)
    frame.healthEdge:SetPoint("BOTTOMRIGHT", 1, -1)
    frame.healthEdge:EnableMouse(false)
    frame.healthEdge:SetBackdrop({
        edgeFile = app.Theme.white,
        edgeSize = app.Pixel:Pixels(1, frame.healthEdge),
    })
    frame.healthEdge:SetBackdropBorderColor(0.02, 0.03, 0.05, 0.72)
    frame.status = app.Theme:Text(frame.health, 9)
    frame.status:SetPoint("CENTER")
    frame.status:SetText("")
    frame.power = app.Theme:Bar(frame, P.power)
    frame.power:SetPoint("TOPLEFT", P.textInset, POWER_TOP)
    frame.power:SetPoint("TOPRIGHT", -RIGHT_COLUMN, POWER_TOP)
    frame.events = CreateFrame("Frame")
    frame.events:SetScript("OnEvent", function()
        app:Call("partyFrames/" .. unit, draw, frame)
    end)
    return frame
end

-- Native display lookup supports diagnostics and the currently gated takeover
-- path. If that path is ever validated, its protected writes use the queue.
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

-- Reports whether every visible member has a complete set of private anchors.
local function privateCovered(self)
    if not app.PrivateAuras.Available() then return false end
    for _, unit in ipairs(ORDER) do
        -- A member that exists but whose button was not accepted is not
        -- covered: the native display must stay for that member.
        if UnitExists(unit) then
            if not memberCovered(unit) then return false end
            local frame = self.frames and self.frames[unit]
            if not (frame and frame.lumaPrivateComplete) then return false end
        end
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

-- The layout switch is separate from the code's parity constant: a player can
-- keep the own party rows while the client's frames stay on screen (012 phase
-- 13). The default keeps the existing behaviour.
local function takeoverWanted()
    return app.Store:Profile().ui.partyTakeover ~= false
end

local function syncNative(self)
    if NATIVE_PARITY_VALIDATED and takeoverWanted() and anyPartyMember() and privateCovered(self) then
        hideNative(self)
    else
        restoreNative(self)
    end
end

local function drawAll(self)
    for _, unit in ipairs(ORDER) do
        local frame = self.frames and self.frames[unit]
        if frame then app:Call("partyFrames/draw/" .. unit, draw, frame) end
    end
end

component = app:RegisterComponent({ id = "partyFrames", label = "partyFrames", defaultEnabled = true,
    Supported = function(_, caps) return caps.units end,
    Enable = function(self)
        self.frames = self.frames or {}
        -- Building secure buttons and registering their watches is protected:
        -- the whole job waits for combat to end.
        app.Queue:Run(BUILD_JOB, function()
            if not self.running then return end
            local groupX, groupY = groupOrigin()
            for _, unit in ipairs(ORDER) do
                local frame = self.frames[unit]
                if not frame then
                    frame = create(unit)
                    self.frames[unit] = frame
                end
                -- The four buttons join one group; moving or scaling the group
                -- is one layout item, members keep their relative offsets.
                app.Layout:Join(GROUP_ID, "party_" .. unit, frame, groupX,
                    slotY(PARTY_UNITS[unit], groupY), groupSpec())
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
    return string.format("partyFrames: %s (%s) · %s · %s", state, app.L.partyFrames,
        app.L.nativeAwaitingValidation, app.L.partyCoverage)
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
