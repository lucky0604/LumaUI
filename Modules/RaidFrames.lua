local _, app = ...

-- Optional raid preview: watched secure buttons are created for existing
-- members and reused on roster changes. Native raid frames remain under client
-- control until interaction and encounter parity is validated. Secure objects
-- and private-aura anchors are configured outside combat; secret unit values
-- reach native drawing methods without Lua arithmetic or persistence.

local MAX_UNITS = 40
local MAX_SUBGROUPS = 8
-- Original footprint: five columns of eight. It is kept exactly as it was for
-- every client that does not report subgroups, so the ungrouped grid and its
-- saved positions never move.
local ROWS, COLUMNS = 8, 5
local BUTTON_WIDTH, BUTTON_HEIGHT = 90, 32
local COLUMN_STEP, ROW_STEP = BUTTON_WIDTH + 6, BUTTON_HEIGHT + 4
local GRID_WIDTH = COLUMN_STEP * (COLUMNS - 1) + BUTTON_WIDTH
local GRID_HEIGHT = ROW_STEP * (ROWS - 1) + BUTTON_HEIGHT
-- Top-left corner of the grid as an offset from UIParent's centre. Columns grow
-- to the right by 96 px, rows grow downwards by 36 px. The whole grid is
-- registered with the layout system as one panel instead of 40 overlays; when
-- the subgroup layout makes it wider, its stored centre is updated and the
-- layout pass clamps it to the screen like any other panel.
local ORIGIN_X, ORIGIN_Y = 460, -60
local LAYOUT_ID = "raidFrames"
local MARK_SIZE = 12
-- The native compact raid frame reserves five private aura displays per member
-- (CompactUnitFrameTemplate, maxPrivateAuras = 5; its container layout uses an
-- 11 px debuff icon). The replacement reserves the same five single-anchor
-- slots along the bottom edge of the button, one per aura index, in the
-- client's own priority order. None of the aura content is read here.
local PRIVATE_SLOTS = 5
local PRIVATE_ICON = 10
local PRIVATE_OPTIONS = { size = PRIVATE_ICON, point = "BOTTOMRIGHT",
    offsetX = -2, offsetY = 2, step = -12 }
local MARK_TEXTURE = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_%d"
-- One path per index, built once from a plain loop counter: the draw path then
-- only picks a string, never builds one from a unit value.
local MARK_ICONS = {}
for index = 1, 8 do MARK_ICONS[index] = string.format(MARK_TEXTURE, index) end
local UNIT_EVENTS = { "UNIT_HEALTH", "UNIT_MAXHEALTH", "UNIT_NAME_UPDATE", "UNIT_FLAGS", "UNIT_CONNECTION" }
local GLOBAL_EVENTS = { "GROUP_ROSTER_UPDATE", "PLAYER_ENTERING_WORLD", "RAID_ROSTER_UPDATE" }
local TARGET_EVENT = "RAID_TARGET_UPDATE"
-- The guarded takeover path would only cover the container, not the manager.
local NATIVE_TAKEOVER = { "CompactRaidFrameContainer" }
local NATIVE_NAMES = { "CompactRaidFrameContainer", "CompactRaidFrameManager" }
local BUILD_JOB, NATIVE_JOB = "raidFrames/build", "raidFrames/native"
-- Private-aura anchors still require real encounter and interaction validation.
local NATIVE_PARITY_VALIDATED = false
local component

local function unitToken(index) return "raid" .. index end

local function unitExists(token)
    if type(UnitExists) ~= "function" then return false end
    local ok, value = pcall(UnitExists, token)
    return ok and app.Capabilities.Plain(value, "boolean") == true
end

-- The raid target index of a unit, or nil. The index may be restricted on a
-- future client, so it is pcall'ed and Plain-gated before any use; a secret
-- value is never compared, formatted or shown.
local function raidTarget(unit)
    if type(GetRaidTargetIndex) ~= "function" then return nil end
    local ok, value = pcall(GetRaidTargetIndex, unit)
    if not ok then return nil end
    local index = app.Capabilities.Plain(value, "number")
    if not index or index < 1 or index > 8 then return nil end
    return math.floor(index)
end

-- Only the third return value (subgroup) leaves the roster call: name and rank
-- never leave this wrapper even if a future client restricts them, and the
-- subgroup still takes the Plain guard before it becomes a column.
local function rosterSubgroup(index)
    local _, _, subgroup = GetRaidRosterInfo(index)
    return subgroup
end

local function subgroupOf(index)
    if type(GetRaidRosterInfo) ~= "function" then return nil end
    local ok, subgroup = pcall(rosterSubgroup, index)
    if not ok then return nil end
    local value = app.Capabilities.Plain(subgroup, "number")
    if not value or value < 1 or value > MAX_SUBGROUPS then return nil end
    return math.floor(value)
end

-- The mark is drawing only: a plain texture on a non-protected control, so the
-- update is allowed in combat. Only a plain 1..8 index ever reaches the icon
-- table; anything else (restricted, cleared, out of range) hides the mark.
local function drawMark(button)
    local mark = button.mark
    if not mark then return end
    local index = raidTarget(button.unitToken)
    if not index then
        if mark:IsShown() then mark:Hide() end
        return
    end
    mark:SetTexture(MARK_ICONS[index])
    if not mark:IsShown() then mark:Show() end
end

local function draw(button)
    local unit = button.unitToken
    if not unit or not unitExists(unit) then
        app.MemberInfo.Clear(button.role, button.status)
        return
    end
    -- A restricted name is still only ever sent to SetText.
    button.name:SetText(UnitName(unit))
    -- Secret health values go straight to engine drawing, never through Lua maths.
    button.health:SetMinMaxValues(0, UnitHealthMax(unit))
    button.health:SetValue(UnitHealth(unit))
    app.Theme:PaintBar(button.health, app.Theme:UnitColor(unit))
    app.MemberInfo.Draw(unit, button.role, button.status)
    drawMark(button)
end

local function create(index, parent)
    local unit = unitToken(index)
    local button = CreateFrame("Button", "LumaUIRaid" .. index, parent, "SecureUnitButtonTemplate")
    button:Hide()
    button:SetSize(BUTTON_WIDTH, BUTTON_HEIGHT)
    button.unitToken = unit
    button:RegisterForClicks("AnyUp")
    button:SetAttribute("unit", unit)
    button:SetAttribute("*type1", "target")
    button:SetAttribute("*type2", "togglemenu")
    -- The first point is the index grid; the queued reflow immediately replaces
    -- it with the subgroup slot when the roster reports one.
    local column, row = math.floor((index - 1) / ROWS), (index - 1) % ROWS
    button:SetPoint("TOPLEFT", parent, "TOPLEFT", column * COLUMN_STEP, -row * ROW_STEP)
    button.lumaColumn, button.lumaRow = column, row
    button.name = app.Theme:Text(button, 11)
    button.name:SetPoint("TOPLEFT", 6, -3)
    -- The name stops short of the role glyph and the mark in the top right.
    button.name:SetWidth(BUTTON_WIDTH - 36)
    -- No panel behind these: like the unit preview they are a name and a bar
    -- floating over the world, so the name carries a shadow.
    if type(button.name.SetShadowOffset) == "function" then
        pcall(button.name.SetShadowOffset, button.name, 1, -1)
    end
    if type(button.name.SetShadowColor) == "function" then
        pcall(button.name.SetShadowColor, button.name, 0, 0, 0, 0.85)
    end
    -- Raid target icon, top right. This is the whole mark section: one classic
    -- numbered icon texture per index (see the file header for the atlas
    -- fallback), 12 x 12, hidden until the member carries a raid target. The
    -- draw step owns the texture, so no placeholder icon is ever displayed.
    button.mark = button:CreateTexture(nil, "OVERLAY")
    button.mark:SetSize(MARK_SIZE, MARK_SIZE)
    button.mark:SetPoint("TOPRIGHT", -3, -3)
    button.mark:Hide()
    -- Role glyph sits between the name and the mark; cleared when unknown.
    button.role = app.Theme:Text(button, 10)
    button.role:SetPoint("TOPRIGHT", -17, -4)
    button.role:SetWidth(10)
    button.role:SetJustifyH("RIGHT")
    button.role:SetText("")
    -- No power bar: 40 buttons at 90 x 32 answer "who is about to die", and a
    -- second bar would only cost the space the name and health need.
    button.health = app.Theme:Bar(button, 12)
    button.health:SetPoint("TOPLEFT", 6, -18)
    button.health:SetPoint("TOPRIGHT", -6, -18)
    button.status = app.Theme:Text(button.health, 9)
    button.status:SetPoint("CENTER")
    button.status:SetText("")
    -- One event frame per button, registered for that button's own token: the
    -- event's unit argument never becomes a table key or a dispatch decision.
    button.events = CreateFrame("Frame")
    button.events:SetScript("OnEvent", function()
        app:Call("raidFrames/" .. unit, draw, button)
    end)
    return button
end

local function ensureEvents(button)
    if button.lumaEvents then return end
    for _, event in ipairs(UNIT_EVENTS) do
        pcall(button.events.RegisterUnitEvent, button.events, event, button.unitToken)
    end
    button.lumaEvents = true
end

-- RegisterUnitWatch is the only thing that decides whether a watched button is
-- shown; Lua never shows or hides it while its unit exists.
local function watch(button)
    if button.lumaWatched then return end
    -- A client that rejects the watch keeps this member on the native frame.
    local watched = pcall(RegisterUnitWatch, button)
    button.lumaWatched = watched or nil
end

local function release(button)
    if button.lumaWatched then
        UnregisterUnitWatch(button)
        button.lumaWatched = nil
    end
    app.PrivateAuras.Release(button)
    app.MemberInfo.Clear(button.role, button.status)
    if button:IsShown() then button:Hide() end
end

-- The grid anchor: one plain frame owns the layout entry and the buttons are
-- its children, so moving the panel moves the whole raid block.
local function container(self)
    if self.container then return self.container end
    local frame = CreateFrame("Frame", "LumaUIRaidFrames", UIParent)
    frame:SetSize(GRID_WIDTH, GRID_HEIGHT)
    -- Layout:ApplyAll owns the final anchor; this first point only means the
    -- grid is never visible at the parent's origin if that pass is skipped.
    frame:SetPoint("CENTER", UIParent, "CENTER", ORIGIN_X + GRID_WIDTH / 2, ORIGIN_Y - GRID_HEIGHT / 2)
    app.Layout:RegisterGroup(LAYOUT_ID, frame, ORIGIN_X + GRID_WIDTH / 2, ORIGIN_Y - GRID_HEIGHT / 2,
        app.L.raidFrames)
    self.container = frame
    return frame
end

-- Reads the live roster once: which indices exist, their subgroup and whether
-- every one of them reported one. Nothing here reads health or any other unit
-- value — the layout depends on the roster and only on the roster.
local function readRoster()
    local exists, subgroups = {}, {}
    local members, grouped = 0, true
    for index = 1, MAX_UNITS do
        if unitExists(unitToken(index)) then
            exists[index] = true
            members = members + 1
            subgroups[index] = subgroupOf(index)
            if not subgroups[index] then grouped = false end
        end
    end
    return exists, subgroups, grouped and members > 0
end

-- The column and row of every existing member, plus how many columns and rows
-- are in use. Grouped: one column per subgroup, top to bottom in raid index
-- order. Ungrouped: the original five-by-eight index grid and its footprint.
local function computeSlots()
    local exists, subgroups, grouped = readRoster()
    local slots, placed = {}, {}
    local columns, rows = 0, 0
    for index = 1, MAX_UNITS do
        if exists[index] then
            local column, row
            if grouped then
                column = subgroups[index] - 1
                placed[column] = (placed[column] or 0) + 1
                -- A raid has eight subgroups of at most five members, so eight
                -- rows always suffice; a hypothetical ninth on the same column
                -- wraps onto the first row instead of opening a ninth column.
                row = (placed[column] - 1) % ROWS
            else
                column, row = math.floor((index - 1) / ROWS), (index - 1) % ROWS
            end
            slots[index] = { column = column, row = row }
            if column + 1 > columns then columns = column + 1 end
            if row + 1 > rows then rows = row + 1 end
        end
    end
    if not grouped then columns, rows = COLUMNS, ROWS end
    return slots, grouped, columns, rows
end

-- Places the existing buttons and sizes the grid around them. Called from the
-- queue only: SetPoint on a secured button is protected, so a subgroup change
-- in combat is remembered and replayed once combat ends.
local function arrange(self, parent)
    local slots, grouped, columns, rows = computeSlots()
    self.layoutMode = grouped and "subgroups" or "index"
    for index = 1, MAX_UNITS do
        local button = self.frames and self.frames[index]
        local slot = slots[index]
        if button and slot and (button.lumaColumn ~= slot.column or button.lumaRow ~= slot.row) then
            button:SetPoint("TOPLEFT", parent, "TOPLEFT", slot.column * COLUMN_STEP, -slot.row * ROW_STEP)
            button.lumaColumn, button.lumaRow = slot.column, slot.row
        end
    end
    local width = COLUMN_STEP * (columns - 1) + BUTTON_WIDTH
    local height = ROW_STEP * (rows - 1) + BUTTON_HEIGHT
    if parent:GetWidth() == width and parent:GetHeight() == height then return end
    parent:SetSize(width, height)
    -- The layout entry stores the grid's centre, so a new size moves its
    -- top-left corner. Updating the default centre through the public API keeps
    -- that corner at the same origin, and the layout pass then clamps the wider
    -- grid to the screen exactly like a saved panel position.
    app.Layout:SetEntryDefault(LAYOUT_ID, ORIGIN_X + width / 2, ORIGIN_Y - height / 2)
    app.Layout:Apply(LAYOUT_ID)
end

local function nativeFrame(name)
    local frame = _G[name]
    if frame and type(frame.Hide) == "function" and type(frame.Show) == "function" then return frame end
end

local function nativeShown(frame)
    if not frame or type(frame.IsShown) ~= "function" then return false end
    local ok, shown = pcall(function() return frame:IsShown() and true or false end)
    return ok and shown == true
end

-- The native raid frames are secure: every hide goes through the non-combat
-- queue, which is why the OnShow hook only queues instead of hiding directly.
local function suppressNative()
    if not component.running or not component.native then return end
    for _, name in ipairs(NATIVE_TAKEOVER) do
        local state = component.native[name]
        if state and state.hidden then
            local frameName = name
            app.Queue:Run(NATIVE_JOB .. "/" .. frameName, function()
                if not component.running then return end
                local live = component.native and component.native[frameName]
                if not live or not live.hidden then return end
                local frame = nativeFrame(frameName)
                if frame and nativeShown(frame) then pcall(frame.Hide, frame) end
            end)
        end
    end
end

local function hideNative(name)
    local frame = nativeFrame(name)
    if not frame then return end
    component.native = component.native or {}
    local state = component.native[name]
    if not state then
        -- Remember what the client had on screen before the takeover; the
        -- restore puts it back to exactly that state.
        state = { shown = nativeShown(frame) }
        component.native[name] = state
    end
    state.hidden = true
    if not frame.lumaRaidSuppress then
        frame.lumaRaidSuppress = true
        if type(frame.HookScript) == "function" then
            frame:HookScript("OnShow", function() suppressNative() end)
        end
    end
    suppressNative()
end

local function restoreNative(name)
    local state = component.native and component.native[name]
    if not state then return end
    component.native[name] = nil
    local frame = nativeFrame(name)
    if not frame or not state.shown or nativeShown(frame) then return end
    app.Queue:Run(NATIVE_JOB .. "/" .. name, function()
        if component.running and component.native and component.native[name] then return end
        local live = nativeFrame(name)
        if live and not nativeShown(live) then pcall(live.Show, live) end
    end)
end

-- A button counts only while its unit watch is registered and the button is
-- actually on screen: a button that was never watched, failed to show or was
-- released is not a reason to take the native raid frames away.
local function memberCovered(button)
    if not button or not button.lumaWatched then return false end
    local ok, shown = pcall(button.IsShown, button)
    return ok and shown == true
end

-- Every covered member must hold its native private-aura slots: the native raid
-- frame is the only other thing that draws private auras for the raid, so a
-- client without the anchor API keeps it.
local function privateCovered(self)
    if not app.PrivateAuras.Available() then return false end
    for index = 1, MAX_UNITS do
        local button = self.frames and self.frames[index]
        if button and memberCovered(button) and not button.lumaPrivateComplete then return false end
    end
    return true
end

-- Attaches the native slots for members the client reports and releases them for
-- members that left, so a reused button never shows another member's private
-- aura. Queue-only: the slots live on secure buttons.
local function syncPrivate(self)
    for index = 1, MAX_UNITS do
        local button = self.frames and self.frames[index]
        if button then
            if memberCovered(button) and unitExists(button.unitToken) then
                app.PrivateAuras.Attach(button, button.unitToken, PRIVATE_SLOTS,
                    PRIVATE_OPTIONS)
            else
                app.PrivateAuras.Release(button)
            end
        end
    end
end

-- Native takeover remains gated until encounter and interaction validation.
local function syncNative(self)
    local taken = false
    for index = 1, MAX_UNITS do
        local button = self.frames and self.frames[index]
        if button and memberCovered(button) and unitExists(button.unitToken) then taken = true; break end
    end
    -- Raid has its own switch; validating the party layout must never enable
    -- the raid takeover (012 phase 13).
    if taken then
        taken = NATIVE_PARITY_VALIDATED and privateCovered(self)
            and app.Store:Profile().ui.raidTakeover == true
    end
    for _, name in ipairs(NATIVE_TAKEOVER) do
        if taken then hideNative(name) else restoreNative(name) end
    end
end

-- Builds missing buttons, registers their watch and unit events, refreshes the
-- drawing, reflows the grid and decides the native takeover. Only ever called
-- from the queue.
local function sync(self)
    local parent = container(self)
    if not parent:IsShown() then parent:Show() end
    self.frames = self.frames or {}
    for index = 1, MAX_UNITS do
        local unit = unitToken(index)
        local exists = unitExists(unit)
        local button = self.frames[index]
        if exists and not button then
            button = create(index, parent)
            self.frames[index] = button
        end
        if button then
            if exists then
                ensureEvents(button)
                watch(button)
                draw(button)
            else
                release(button)
            end
        end
    end
    arrange(self, parent)
    syncPrivate(self)
    syncNative(self)
end

local function drawAll(self)
    for index = 1, MAX_UNITS do
        local button = self.frames and self.frames[index]
        if button then app:Call("raidFrames/draw/" .. button.unitToken, draw, button) end
    end
end

-- RAID_TARGET_UPDATE only repaints marks; an icon is a plain texture, so this
-- is drawing-only work that never needs the queue.
local function drawMarks(self)
    for index = 1, MAX_UNITS do
        local button = self.frames and self.frames[index]
        if button then drawMark(button) end
    end
end

local function rebuild()
    if not component.running then return end
    sync(component)
end

component = app:RegisterComponent({ id = "raidFrames", label = "raidFrames", defaultEnabled = false,
    Supported = function(_, caps) return caps.units end,
    Enable = function(self)
        self.frames = self.frames or {}
        -- Creating secure buttons, setting their attributes, registering their
        -- watches, pointing them at their slots and hiding the native frames are
        -- all protected: the whole job waits for combat to end, and one queue
        -- key coalesces the burst of roster events that follows a group change.
        app.Queue:Run(BUILD_JOB, rebuild)
        for _, event in ipairs(GLOBAL_EVENTS) do
            self:Listen(event, function() app.Queue:Run(BUILD_JOB, rebuild) end)
        end
        -- A new target is a drawing change only: the marks repaint immediately,
        -- including in combat, without touching a secured object.
        self:Listen(TARGET_EVENT, function(current)
            app:Call("raidFrames/targets", drawMarks, current)
        end)
    end,
    Refresh = function(self)
        -- Drawing only: no protected object is created or changed here.
        drawAll(self)
    end,
    Disable = function(self)
        for _, button in pairs(self.frames or {}) do
            button.events:UnregisterAllEvents()
            button.lumaEvents = nil
            release(button)
        end
        app.Queue:Run(NATIVE_JOB, function()
            for _, name in ipairs(NATIVE_TAKEOVER) do restoreNative(name) end
            if self.container and self.container:IsShown() then self.container:Hide() end
        end)
    end,
})

-- Diagnostics for `/luma status`: which native raid frames the prototype took
-- over. `native` keeps one record per suppressed frame; the manager entry is
-- reported as kept because the native raid actions stay reachable through it.
function component:Describe()
    if not self.running then return nil end
    local states = {}
    for _, name in ipairs(NATIVE_NAMES) do
        local state = self.native and self.native[name]
        local taken = state ~= nil and state.hidden == true
        states[#states + 1] = name .. "=" .. (taken and app.L.nativeTaken or app.L.nativeKept)
    end
    return "raidFrames: " .. table.concat(states, ", ") .. " · " .. app.L.nativeAwaitingValidation
        .. " · " .. app.L.raidCoverage
end

-- `/luma raid`: prints what the raid prototype actually sees, so a report like
-- "no raid frames" can be diagnosed without guessing. Reached through the core
-- command table (Core/Startup.lua) like the party diagnostic.
function component:Diagnose()
    local function yes(value) return value and "yes" or "no" end
    local inRaid = false
    if type(IsInRaid) == "function" then
        local ok, value = pcall(IsInRaid)
        inRaid = ok and app.Capabilities.Plain(value, "boolean") == true
    end
    local members = 0
    for index = 1, MAX_UNITS do
        if unitExists(unitToken(index)) then members = members + 1 end
    end
    local group = "?"
    if type(GetNumGroupMembers) == "function" then
        local ok, value = pcall(GetNumGroupMembers)
        value = ok and app.Capabilities.Plain(value, "number") or nil
        if value then group = tostring(value) end
    end
    local layout = self.layoutMode == "subgroups" and app.L.raidLayoutGroups or app.L.raidLayoutIndex
    app:Print(string.format("raidFrames: status=%s running=%s inRaid=%s members=%d group=%s layout=%s",
        tostring(self.status), yes(self.running), yes(inRaid), members, group, tostring(layout)))
    for _, name in ipairs(NATIVE_NAMES) do
        local frame = nativeFrame(name)
        app:Print(string.format("  native %s: exists=%s shown=%s taken=%s", name, yes(frame ~= nil),
            yes(frame and nativeShown(frame)), yes(self.native ~= nil and self.native[name] ~= nil)))
    end
    for index = 1, MAX_UNITS do
        local unit = unitToken(index)
        local exists = unitExists(unit)
        local button = self.frames and self.frames[index]
        if exists or button then
            local shown = nil
            if button then
                local ok, value = pcall(button.IsShown, button)
                shown = ok and value or nil
            end
            app:Print(string.format("  %s: exists=%s button=%s watched=%s shown=%s subgroup=%s", unit, yes(exists),
                yes(button ~= nil), yes(button and button.lumaWatched), yes(shown),
                tostring(subgroupOf(index) or "?")))
        end
    end
    app:Print(app.L.raidHint)
end
