local _, app = ...
local Layout = { entries = {}, groups = {}, editing = false, presets = {}, margin = 8 }
app.Layout = Layout

-- Layout keeps one list of placements: independent panels, group containers and
-- group members. A group member is anchored to its container, so moving or
-- scaling the group once carries every member with it and members never become
-- their own rows in the layout page.
--
-- Coordinates keep their historical meaning: a centre offset in the frame's own
-- units, rendered with appearance.scale (a group adds no extra scale). Old
-- absolute member positions are converted once into relative offsets and the
-- original absolute keys are never deleted.

local function validFrame(frame)
    return frame and type(frame.SetPoint) == "function" and type(frame.GetWidth) == "function"
end

local function clonePositions(positions)
    local copy = {}
    for id, position in pairs(positions or {}) do
        if type(id) == "string" and type(position) == "table" then
            copy[id] = { x = position.x, y = position.y }
        end
    end
    return copy
end
Layout.ClonePositions = clonePositions

-- `scale` is the panel's own relative scale (a number or a function returning
-- one). It is a property of the entry, never a second writer: Apply is the only
-- place that turns appearance.scale and this relative value into a frame scale,
-- so a window that wants its own size cannot fight the global one.
function Layout:Register(id, frame, x, y, label, scale)
    local entry = self.entries[id]
    if entry and entry.member then
        -- A member becoming independent again: drop the relative anchor.
        entry.member, entry.groupId, entry.rx, entry.ry = nil, nil, nil, nil
    end
    entry = entry or {}
    entry.frame, entry.x, entry.y = frame, x, y
    entry.label = label or id
    entry.scale = scale
    self.entries[id] = entry
    return entry
end

function Layout:RegisterGroup(id, frame, x, y, label)
    local created = false
    if not validFrame(frame) then
        frame = CreateFrame("Frame", "LumaUIGroup_" .. id, UIParent)
        frame:Show()
        created = true
    end
    local entry = { frame = frame, x = x, y = y, label = label or id, group = true, members = {} }
    self.entries[id] = entry
    self.groups[id] = entry
    return entry
end

-- Creates the group container when the module has not supplied one. The spec
-- carries the label, default centre and the container size used for clamping.
function Layout:EnsureGroup(id, spec)
    local entry = self.entries[id]
    if entry and entry.group then return entry end
    spec = spec or {}
    local frame = CreateFrame("Frame", "LumaUIGroup_" .. id, UIParent)
    frame:SetSize(math.max(1, spec.width or 1), math.max(1, spec.height or 1))
    frame:Show()
    return self:RegisterGroup(id, frame, spec.x or 0, spec.y or 0, spec.label or id)
end

function Layout:GroupOf(id)
    local entry = self.entries[id]
    if not entry then return nil end
    if entry.group then return entry end
    if entry.groupId then return self.entries[entry.groupId] end
end

-- Joins one frame to a group. The default absolute position and the group spec
-- are only used the first time: an old absolute position is converted into a
-- relative offset and persisted under "<group>|<id>", so a later group move can
-- never be mistaken for a new member-level move.
function Layout:Join(groupId, id, frame, defaultX, defaultY, spec)
    if not validFrame(frame) then return false end
    if InCombatLockdown() then return false end
    if id == groupId or self.groups[id] then return false end
    -- A group container may not become a member of another group: that would
    -- multiply two scales and let one group's move silently move the other.
    for _, group in pairs(self.groups) do
        if group.frame == frame then return false end
    end
    local group = self:EnsureGroup(groupId, spec)
    local profile = app.Store:Profile()
    local offsetKey = groupId .. "|" .. id
    local savedOffset = profile.positions[offsetKey]
    local rx, ry
    if savedOffset then
        rx, ry = savedOffset.x, savedOffset.y
    else
        local savedAbs = profile.positions[id]
        local baseX = savedAbs and savedAbs.x or (defaultX or 0)
        local baseY = savedAbs and savedAbs.y or (defaultY or 0)
        rx, ry = baseX - (group.x or 0), baseY - (group.y or 0)
        if savedAbs and not app.Store.readonly then
            app.Store:SetPosition(offsetKey, rx, ry)
        end
    end
    local entry = self.entries[id]
    if entry and entry.member == groupId and entry.frame == frame then
        entry.rx, entry.ry = rx, ry
        return true
    end
    if not entry then
        entry = { frame = frame, x = defaultX or 0, y = defaultY or 0, label = id }
        self.entries[id] = entry
    end
    entry.frame, entry.groupId = frame, groupId
    entry.member = true
    entry.x, entry.y = defaultX or 0, defaultY or 0
    entry.rx, entry.ry = rx, ry
    -- Reparenting and re-anchoring a member are protected operations in combat;
    -- Join refuses above, so this only ever runs out of combat.
    pcall(frame.SetParent, frame, group.frame)
    frame:SetScale(1)
    frame:ClearAllPoints()
    frame:SetPoint("CENTER", group.frame, "CENTER", rx, ry)
    local seen = false
    for _, memberId in ipairs(group.members) do
        if memberId == id then seen = true end
    end
    if not seen then group.members[#group.members + 1] = id end
    return true
end

function Layout:SetGroupSize(id, width, height)
    local group = self.entries[id]
    if not group or not group.group or not validFrame(group.frame) then return end
    group.frame:SetSize(math.max(1, width), math.max(1, height))
end

-- Recomputes member offsets from the current profile. Joining only happens when
-- a component enables, so a profile switch needs this to keep members on the
-- positions saved in the newly selected profile.
function Layout:RefreshMembers()
    local profile = app.Store:Profile()
    for id, entry in pairs(self.entries) do
        if entry.member then
            local group = self.entries[entry.groupId]
            if group then
                local savedOffset = profile.positions[entry.groupId .. "|" .. id]
                local savedAbs = profile.positions[id]
                if savedOffset then
                    entry.rx, entry.ry = savedOffset.x, savedOffset.y
                elseif savedAbs then
                    entry.rx, entry.ry = savedAbs.x - (group.x or 0), savedAbs.y - (group.y or 0)
                else
                    entry.rx, entry.ry = (entry.x or 0) - (group.x or 0), (entry.y or 0) - (group.y or 0)
                end
            end
        end
    end
end

-- Public replacement for writing Layout.entries[id].x directly (the raid grid
-- needs its default centre to follow a size change without bypassing the API).
function Layout:SetEntryDefault(id, x, y)
    local entry = self.entries[id]
    if not entry then return end
    entry.x, entry.y = x, y
end

function Layout:RelativeScale(id)
    local entry = self.entries[id]
    if not entry or not entry.scale then return 1 end
    local value = entry.scale
    if type(value) == "function" then
        local ok, result = pcall(value)
        value = ok and result or nil
    end
    if type(value) ~= "number" or value ~= value or value <= 0 then return 1 end
    return math.max(0.5, math.min(2, value))
end

function Layout:Scale(id)
    return app.Store:Profile().appearance.scale * self:RelativeScale(id)
end

function Layout:IDs()
    local ids = {}
    for id, entry in pairs(self.entries) do
        if not entry.member then ids[#ids + 1] = id end
    end
    table.sort(ids)
    return ids
end

-- A placeholder is LumaUI's own outline region for third-party UI. It never
-- looks up, moves, hides or reads the third-party frame: the player reserves
-- space, and the outline is only visible while positions are being edited.
function Layout:RegisterPlaceholder(id, label, x, y, width, height)
    local frame = CreateFrame("Frame", "LumaUIPlaceholder_" .. id, UIParent, "BackdropTemplate")
    frame:SetSize(math.max(40, width or 200), math.max(20, height or 60))
    frame:EnableMouse(false)
    frame:SetBackdrop({ bgFile = app.Theme.white, edgeFile = app.Theme.white,
        edgeSize = app.Pixel:Pixels(1), insets = { left = 1, right = 1, top = 1, bottom = 1 } })
    frame:SetBackdropColor(0, 0, 0, 0.15)
    local line = app.Theme.colors.line
    frame:SetBackdropBorderColor(line[1], line[2], line[3], 0.6)
    frame.label = app.Theme:Text(frame, 11, true)
    frame.label:SetPoint("CENTER")
    frame.label:SetText(label or id)
    frame:Hide()
    local entry = self:Register(id, frame, x or 0, y or 0, label or id)
    entry.placeholder = true
    return entry
end

function Layout:UpdatePlaceholders()
    for _, entry in pairs(self.entries) do
        if entry.placeholder and validFrame(entry.frame) then
            entry.frame:SetShown(self.editing == true)
        end
    end
end

-- Positions use the entry's own units. Both preview and application use the
-- same bounds so their outlines represent where the frame will actually land.
function Layout:Constrain(id, x, y)
    local entry = self.entries[id]
    if not entry or not validFrame(entry.frame) then return x, y end
    local scale = self:Scale(id)
    local halfW = UIParent:GetWidth() / scale / 2
    local halfH = UIParent:GetHeight() / scale / 2
    local maxX = math.max(0, halfW - entry.frame:GetWidth() / 2 - self.margin)
    local maxY = math.max(0, halfH - entry.frame:GetHeight() / 2 - self.margin)
    return math.max(-maxX, math.min(maxX, x)), math.max(-maxY, math.min(maxY, y))
end

function Layout:Apply(id)
    local entry = self.entries[id]
    if not entry or not validFrame(entry.frame) then return end
    local frame = entry.frame
    local group = entry.groupId and self.entries[entry.groupId]
    if entry.member and group and validFrame(group.frame) then
        -- Members inherit the group's scale; only the relative anchor is written.
        frame:SetScale(1)
        frame:ClearAllPoints()
        frame:SetPoint("CENTER", group.frame, "CENTER", entry.rx or 0, entry.ry or 0)
        return
    end
    -- Independent entry, or a member whose group disappeared: fall back to the
    -- absolute placement it had before joining, without failing the layout pass.
    local profile = app.Store:Profile()
    local scale = self:Scale(id)
    frame:SetScale(scale)
    local saved = profile.positions[id]
    local x, y = entry.x or 0, entry.y or 0
    if saved then x, y = saved.x, saved.y end
    x, y = self:Constrain(id, x, y)
    frame:ClearAllPoints()
    frame:SetPoint("CENTER", UIParent, "CENTER", x, y)
    app:Publish("LAYOUT_APPLIED", id)
end

function Layout:ApplyAll()
    if InCombatLockdown() then return end
    for id in pairs(self.entries) do self:Apply(id) end
    if self.previewName then self:PreviewPreset(self.previewName) end
end

function Layout:Overlay(id, entry)
    if entry.overlay then return entry.overlay end
    local overlay = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    overlay:SetFrameStrata("DIALOG")
    overlay:SetMovable(true)
    overlay:SetClampedToScreen(true)
    overlay:EnableMouse(true)
    overlay:RegisterForDrag("LeftButton")
    app.Theme:PaintSurface(overlay, "window")
    local c = app.Theme:Accent()
    overlay:SetBackdropBorderColor(c[1], c[2], c[3], 1)
    local title = app.Theme:Text(overlay, 12)
    title:SetPoint("CENTER")
    title:SetText(entry.label .. " · " .. app.L.drag)
    overlay:SetScript("OnDragStart", function(self)
        if not InCombatLockdown() then self:StartMoving() end
    end)
    overlay:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        if InCombatLockdown() then return end
        local x, y = self:GetCenter()
        local cx, cy = UIParent:GetCenter()
        local ratio = self:GetEffectiveScale() / UIParent:GetEffectiveScale()
        x, y = x * ratio - cx, y * ratio - cy
        local scale = entry.frame:GetScale()
        x, y = math.floor(x / scale / 4 + 0.5) * 4, math.floor(y / scale / 4 + 0.5) * 4
        app.Store:SetPosition(id, x, y)
        self:ClearAllPoints()
        self:SetPoint("CENTER", UIParent, "CENTER", x * scale, y * scale)
        Layout:Apply(id)
    end)
    entry.overlay = overlay
    return overlay
end

function Layout:CreateEscape()
    if self.escape then return self.escape end
    local frame = CreateFrame("Frame", "LumaUILayoutEscape", UIParent)
    frame:Hide()
    frame:SetScript("OnHide", function() if self.editing then self:SetEditing(false) end end)
    UISpecialFrames[#UISpecialFrames + 1] = "LumaUILayoutEscape"
    self.escape = frame
    return frame
end

function Layout:SetEditing(wanted)
    if wanted and (InCombatLockdown() or app.Store.readonly) then
        app:Print(app.Store.readonly and app.L.readonly or app.L.layoutCombat)
        return false
    end
    if wanted then self:CreateEscape() end
    self.editing = wanted
    -- Placeholder outlines are only ever visible while editing positions.
    self:UpdatePlaceholders()
    if wanted and app.Settings.frame then app.Settings.frame:Hide() end
    for id, entry in pairs(self.entries) do
        if entry.member then
            -- Members move with their group; they never get their own drag box.
            if entry.overlay then entry.overlay:Hide() end
        elseif wanted and validFrame(entry.frame) and (entry.frame:IsShown() or entry.allowHiddenMove) then
            local overlay = self:Overlay(id, entry)
            local frame = entry.frame
            local scale = frame:GetEffectiveScale() / UIParent:GetEffectiveScale()
            local x, y = frame:GetCenter()
            local cx, cy = UIParent:GetCenter()
            if not (app.Capabilities.Plain(x, "number") and app.Capabilities.Plain(y, "number")
                and app.Capabilities.Plain(cx, "number") and app.Capabilities.Plain(cy, "number")) then
                local saved = app.Store:Profile().positions[id]
                local px, py = saved and saved.x or entry.x or 0, saved and saved.y or entry.y or 0
                px, py = self:Constrain(id, px, py)
                x, y, cx, cy = px, py, 0, 0
            end
            overlay:SetSize(frame:GetWidth() * scale, frame:GetHeight() * scale)
            overlay:ClearAllPoints()
            overlay:SetPoint("CENTER", UIParent, "CENTER", x * scale - cx, y * scale - cy)
            overlay:Show()
        elseif entry.overlay then
            entry.overlay:StopMovingOrSizing()
            entry.overlay:Hide()
        end
    end
    if self.escape then self.escape:SetShown(wanted) end
    return true
end

function Layout:Toggle()
    return self:SetEditing(not self.editing)
end

----------------------------------------------------------------------
-- 16:9 preset, preview and snapshot
----------------------------------------------------------------------
-- Fractions of the screen size: x is a fraction of the width, y of the height,
-- positive up. Positions are computed in the entry's own units with its current
-- scale, so a preset lands at the same place on any resolution.
Layout.presets = {
    default16x9 = {
        label = "preset16x9",
        entries = {
            topInfo = { 0.00, 0.435 },
            party = { -0.27, -0.34 },
            raidFrames = { 0.25, -0.06 },
            questList = { -0.355, 0.15 },
            inventory = { 0.00, -0.04 },
            characterWindow = { 0.25, 0.10 },
            unit_player = { -0.16, -0.18 },
            unit_target = { 0.16, -0.18 },
            unit_focus = { 0.24, 0.06 },
            unit_pet = { -0.16, -0.26 },
            unit_targettarget = { 0.16, -0.29 },
        },
    },
    combat = {
        label = "presetCombat",
        entries = {
            topInfo = { 0.00, 0.45 },
            party = { -0.33, -0.12 },
            raidFrames = { -0.29, -0.10 },
            questList = { 0.37, 0.06 },
            unit_player = { -0.17, -0.23 },
            unit_target = { 0.17, -0.23 },
            unit_focus = { 0.29, -0.13 },
            unit_pet = { -0.17, -0.31 },
            unit_targettarget = { 0.17, -0.31 },
        },
    },
}
Layout.presetOverlays = {}
local COMBAT_COLUMNS, COMBAT_ROWS = 12, 2
local COMBAT_BUTTON_SIZE, COMBAT_BUTTON_GAP = 40, 4
local COMBAT_ACTION_WIDTH = COMBAT_COLUMNS * COMBAT_BUTTON_SIZE + (COMBAT_COLUMNS - 1) * COMBAT_BUTTON_GAP
local COMBAT_GAP = 24
local COMBAT_SIDES = { unit_player = -1, unit_pet = -1, unit_target = 1, unit_targettarget = 1 }

local function combatActionWidth()
    return COMBAT_ACTION_WIDTH
end

function Layout:Presets()
    local list = {}
    for id, preset in pairs(self.presets) do
        list[#list + 1] = { id = id, label = preset.label }
    end
    table.sort(list, function(a, b) return a.id < b.id end)
    return list
end

function Layout:PresetOffset(id, spec, presetName)
    local scale = self:Scale(id)
    local x = (spec[1] or 0) * UIParent:GetWidth() / scale
    local side = presetName == "combat" and COMBAT_SIDES[id]
    local entry = self.entries[id]
    if side and entry and validFrame(entry.frame) then
        local halfFrame = entry.frame:GetWidth() * scale / 2
        x = side * (combatActionWidth() / 2 + COMBAT_GAP + halfFrame) / scale
    end
    return x, (spec[2] or 0) * UIParent:GetHeight() / scale
end

local function presetOverlay(id)
    local overlay = Layout.presetOverlays[id]
    if overlay then return overlay end
    overlay = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    overlay:SetFrameStrata("DIALOG")
    overlay:EnableMouse(false)
    app.Theme:PaintSurface(overlay, "window")
    local accent = app.Theme:Accent()
    overlay:SetBackdropBorderColor(accent[1], accent[2], accent[3], 1)
    overlay:SetBackdropColor(accent[1], accent[2], accent[3], 0.12)
    overlay.label = app.Theme:Text(overlay, 11, true)
    overlay.label:SetPoint("CENTER")
    Layout.presetOverlays[id] = overlay
    return overlay
end

-- A static illustration only. It does not inspect, move, or create native
-- buttons; the player configures the real bars through the game's Edit Mode.
local function paintActionGuide(overlay)
    overlay.label:ClearAllPoints()
    overlay.label:SetPoint("BOTTOM", overlay, "TOP", 0, 6)
    overlay.slots = overlay.slots or {}
    local line = app.Theme.colors.line
    for row = 0, COMBAT_ROWS - 1 do
        for column = 0, COMBAT_COLUMNS - 1 do
            local index = row * COMBAT_COLUMNS + column + 1
            local slot = overlay.slots[index]
            if not slot then
                slot = overlay:CreateTexture(nil, "ARTWORK")
                slot:SetSize(COMBAT_BUTTON_SIZE, COMBAT_BUTTON_SIZE)
                slot:SetPoint("TOPLEFT", overlay, "TOPLEFT",
                    column * (COMBAT_BUTTON_SIZE + COMBAT_BUTTON_GAP),
                    -8 - row * (COMBAT_BUTTON_SIZE + COMBAT_BUTTON_GAP))
                overlay.slots[index] = slot
            end
            slot:SetColorTexture(line[1], line[2], line[3], 0.25)
        end
    end
end

-- Draws outlines at the target positions without moving anything.
function Layout:PreviewPreset(name)
    local preset = self.presets[name or "default16x9"]
    if not preset then return 0 end
    self:CancelPresetPreview()
    self.previewName = name or "default16x9"
    local shown, rectangles = 0, {}
    for id, spec in pairs(preset.entries) do
        local entry = self.entries[id]
        if entry and not entry.member and validFrame(entry.frame) then
            local overlay = presetOverlay(id)
            local scale = self:Scale(id)
            local width = math.max(20, (entry.frame:GetWidth() or 100) * scale)
            local height = math.max(14, (entry.frame:GetHeight() or 30) * scale)
            local x, y = self:PresetOffset(id, spec, name)
            x, y = self:Constrain(id, x, y)
            overlay:SetSize(width, height)
            overlay:ClearAllPoints()
            overlay:SetPoint("CENTER", UIParent, "CENTER", x * scale, y * scale)
            overlay.label:SetText(entry.label)
            overlay:Show()
            rectangles[#rectangles + 1] = { id = id, overlay = overlay, label = entry.label,
                x = x * scale, y = y * scale, width = width, height = height }
            shown = shown + 1
        end
    end
    if name == "combat" then
        local overlay = presetOverlay("nativeActionArea")
        overlay:SetSize(combatActionWidth(), 100)
        overlay:ClearAllPoints()
        overlay:SetPoint("CENTER", UIParent, "BOTTOM", 0, UIParent:GetHeight() * 0.16)
        paintActionGuide(overlay)
        overlay.label:SetText(app.L.nativeActionArea)
        overlay:Show()
        rectangles[#rectangles + 1] = { id = "nativeActionArea", overlay = overlay,
            label = app.L.nativeActionArea, x = 0, y = -UIParent:GetHeight() * 0.34,
            width = combatActionWidth(), height = 100 }
        shown = shown + 1
    end
    -- Rectangles are in UIParent units, including the same clamping and scale
    -- used for application. The action area is a guide, not a native readback.
    local warnings = {}
    local halfScreenW, halfScreenH = UIParent:GetWidth() / 2, UIParent:GetHeight() / 2
    for i, rect in ipairs(rectangles) do
        if math.abs(rect.x) + rect.width / 2 > halfScreenW
            or math.abs(rect.y) + rect.height / 2 > halfScreenH then
            warnings[rect.id] = true
        end
        for j = i + 1, #rectangles do
            local other = rectangles[j]
            if math.abs(rect.x - other.x) < (rect.width + other.width) / 2
                and math.abs(rect.y - other.y) < (rect.height + other.height) / 2 then
                warnings[rect.id], warnings[other.id] = true, true
            end
        end
    end
    local accent = app.Theme:Accent()
    for _, rect in ipairs(rectangles) do
        if warnings[rect.id] then
            rect.overlay:SetBackdropBorderColor(1, 0.37, 0.28, 1)
            rect.overlay.label:SetText(rect.label .. " · " .. app.L.presetOverlapShort)
        else
            rect.overlay:SetBackdropBorderColor(accent[1], accent[2], accent[3], 1)
        end
    end
    self.previewWarnings = warnings
    return shown
end

function Layout:CancelPresetPreview()
    self.previewName = nil
    self.previewWarnings = nil
    for _, overlay in pairs(self.presetOverlays) do overlay:Hide() end
end

local function applyPresetNow(name)
    local preset = Layout.presets[name or "default16x9"]
    if not preset or app.Store.readonly then return false end
    local positions = app.Store:Profile().positions
    local snapshot = { name = name or "default16x9", positions = {}, touched = {} }
    for id, spec in pairs(preset.entries) do
        local entry = Layout.entries[id]
        if entry and not entry.member then
            snapshot.touched[id] = true
            if positions[id] then
                snapshot.positions[id] = { x = positions[id].x, y = positions[id].y }
            end
            local x, y = Layout:PresetOffset(id, spec, name)
            app.Store:SetPosition(id, x, y)
        end
    end
    Layout.presetSnapshot = snapshot
    Layout:CancelPresetPreview()
    Layout:ApplyAll()
    return true
end

-- Applying is explicit and never happens on load; the snapshot is what "undo"
-- restores, and it never removes positions it did not see.
function Layout:ApplyPreset(name)
    app.Queue:Run("layout/preset", function() applyPresetNow(name) end)
end

local function undoPresetNow()
    if not Layout.presetSnapshot or app.Store.readonly then return false end
    local positions = clonePositions(app.Store:Profile().positions)
    for id in pairs(Layout.presetSnapshot.touched) do
        positions[id] = Layout.presetSnapshot.positions[id]
    end
    app.Store:SetPositions(positions)
    Layout.presetSnapshot = nil
    Layout:ApplyAll()
    return true
end

function Layout:UndoPreset()
    app.Queue:Run("layout/preset/undo", undoPresetNow)
end

function Layout:ClearPresetSnapshot()
    self.presetSnapshot = nil
end
