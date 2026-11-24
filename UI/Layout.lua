local _, app = ...
local Layout = { entries = {}, groups = {}, editing = false, presets = {}, margin = 8 }
app.Layout = Layout

-- A HUD band spans the screen edge: the top information row (experience or
-- watched reputation) keeps its centre on the screen axis. A stale saved centre
-- or an accidental drag can therefore never leave the bar half off the window;
-- vertical movement, scaling and the preset heights still apply.
Layout.axisLock = { topInfo = "x" }

-- Layout keeps one list of placements: independent panels, group containers and
-- group members. A group member is anchored to its container, so moving or
-- scaling the group once carries every member with it and members never become
-- their own rows in the layout page.
--
-- Coordinates keep their historical meaning: a centre offset in the frame's own
-- units, rendered with appearance.scale (a group adds no extra scale). Old
-- absolute member positions are converted once into relative offsets and the
-- original absolute keys are never deleted.

-- Central HUD geometry. The action bar stack, the cooldown viewer stack, the
-- preset preview and the side boundaries offered to the unit frames all read
-- this one measurement. Sizes are UIParent units. Vertical `bottom`/`top` values
-- are distances from the screen bottom (the space a native frame's BOTTOM point
-- uses); `units.rowTopY`/`rowCenterY` are the same rows as centre offsets for
-- the unit-frame layout API, and the preview converts once with `screen.height`.
--
-- `actionBottom` is the distance from the screen bottom to the first bar's
-- bottom edge. It stays a runtime value on purpose: the bottom strip iteration
-- (004) can move the reserved baseline once instead of teaching every component
-- its own number. Native bar widths/heights are measured when readable; the
-- preview marks a fallback estimate so a missing bar cannot silently look like
-- a measured layout.
--
-- The unit frames flank the *visible cooldown block*, not the wider action bar
-- stack: the mockup places the player/target bars almost against the tracked
-- icons while the three action bars stay below them. `contentWidth` is that
-- measured block; until a viewer row is readable the mockup's ~300 UI unit
-- block is used, so the first layout is already in the right place.
Layout.actionBottom = 56
Layout.actionGap = 4
Layout.cooldownGap = 8
Layout.centralGap = 24
Layout.fallbackActionWidth = 524
Layout.fallbackActionHeight = 40
Layout.fallbackContentWidth = 300
-- Reference proportions from the mockup (1672 wide artwork): the centre block
-- is about 8.7% of the screen width and a unit frame almost touches it, roughly
-- a 0.3% hairline. A wider live measurement still wins so a dense row cannot
-- overlap the frames.
Layout.mockupContentRatio = 0.087
Layout.mockupUnitGapRatio = 0.003
Layout.actionBarNames = { "MainActionBar", "MultiBarBottomLeft", "MultiBarBottomRight" }

local function validFrame(frame)
    return frame and type(frame.SetPoint) == "function" and type(frame.GetWidth) == "function"
end

-- Group members follow the container. A locked axis also pins the member offset,
-- so an old per-member position cannot reintroduce the drift the container just
-- dropped.
local function lockMemberOffset(self, groupId, rx, ry)
    local lock = self.axisLock[groupId]
    if lock == "x" then rx = 0 elseif lock == "y" then ry = 0 end
    return rx, ry
end

local function object(value)
    local kind = type(value)
    return kind == "table" or kind == "userdata"
end

local function plainNumber(value)
    return app.Capabilities.Plain(value, "number")
end

-- Stores the measured cooldown block width without publishing. `CentralRows`
-- calls this while it is still building the row table, so the caller publishes
-- after its placement loop instead of re-entering itself. A `nil` width means
-- "no readable viewer": the fallback takes over again.
local function storeContentWidth(self, width)
    width = plainNumber(width)
    if not width or width <= 0 then width = nil end
    local current = self.contentWidth
    if width == current then return false end
    if width and current and math.abs(width - current) < 0.5 then return false end
    self.contentWidth = width
    return true
end

-- Public setter for diagnostics and tests. Components that measure a central
-- block can call it; the cooldown component uses `CentralRows` instead so the
-- width and the rows come from the same measurement.
function Layout:SetContentWidth(width)
    if not storeContentWidth(self, width) then return false end
    app:Publish("LAYOUT_CENTRAL_CHANGED")
    return true
end

function Layout:ContentWidth()
    if self.contentWidth and self.contentWidth > 0 then return self.contentWidth end
    return self.fallbackContentWidth
end

-- Centre block width and the hairline gutter to a unit frame, taken from the
-- mockup proportions instead of a fixed 300/24 pair. `measured` is the widest
-- visible row; the mockup width is a floor, never a cap.
function Layout:BlockMetrics(measured)
    local ok, screenWidth = pcall(UIParent.GetWidth, UIParent)
    screenWidth = ok and plainNumber(screenWidth) or nil
    if not screenWidth or screenWidth <= 0 then screenWidth = 1024 end
    measured = plainNumber(measured) or 0
    local content = math.max(measured, screenWidth * self.mockupContentRatio)
    local gap = math.min(8, math.max(2, screenWidth * self.mockupUnitGapRatio))
    return content, gap
end

-- Local frame units to UIParent units. A frame's SetPoint offsets are scaled by
-- the frame, so every measured size and every target position goes through this
-- ratio instead of assuming the native frame shares LumaUI's scale.
local function frameRatio(frame)
    if not object(frame) or type(frame.GetEffectiveScale) ~= "function"
        or type(UIParent.GetEffectiveScale) ~= "function" then return 1 end
    local okFrame, frameScale = pcall(frame.GetEffectiveScale, frame)
    local okParent, parentScale = pcall(UIParent.GetEffectiveScale, UIParent)
    frameScale = okFrame and plainNumber(frameScale) or nil
    parentScale = okParent and plainNumber(parentScale) or nil
    if not frameScale or not parentScale or frameScale <= 0 or parentScale <= 0 then return 1 end
    return frameScale / parentScale
end

local function frameSize(frame)
    if not object(frame) or type(frame.GetWidth) ~= "function"
        or type(frame.GetHeight) ~= "function" then return nil end
    local okWidth, width = pcall(frame.GetWidth, frame)
    local okHeight, height = pcall(frame.GetHeight, frame)
    width = okWidth and plainNumber(width) or nil
    height = okHeight and plainNumber(height) or nil
    if not width or not height or width <= 0 or height <= 0 then return nil end
    local ratio = frameRatio(frame)
    return width * ratio, height * ratio
end

local function uiSize()
    local okWidth, width = pcall(UIParent.GetWidth, UIParent)
    local okHeight, height = pcall(UIParent.GetHeight, UIParent)
    width = okWidth and plainNumber(width) or nil
    height = okHeight and plainNumber(height) or nil
    return width and width > 0 and width or 1024, height and height > 0 and height or 768
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
    local savedAbs = profile.positions[id]
    if savedOffset then
        rx, ry = savedOffset.x, savedOffset.y
    else
        local baseX = savedAbs and savedAbs.x or (defaultX or 0)
        local baseY = savedAbs and savedAbs.y or (defaultY or 0)
        rx, ry = baseX - (group.x or 0), baseY - (group.y or 0)
    end
    rx, ry = lockMemberOffset(self, groupId, rx, ry)
    -- Write the corrected offset back so the next profile load reads the same
    -- centred value instead of migrating the stale one again.
    if (savedOffset or savedAbs) and not app.Store.readonly then
        app.Store:SetPosition(offsetKey, rx, ry)
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
                entry.rx, entry.ry = lockMemberOffset(self, entry.groupId, entry.rx, entry.ry)
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
        if not entry.member and not entry.hidden then ids[#ids + 1] = id end
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
        if entry.placeholder and not entry.hidden and validFrame(entry.frame) then
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
    -- A bottom bar owns the screen edge; other entries keep the window margin.
    local margin = entry.margin or self.margin
    local maxX = math.max(0, halfW - entry.frame:GetWidth() / 2 - margin)
    local maxY = math.max(0, halfH - entry.frame:GetHeight() / 2 - margin)
    x, y = math.max(-maxX, math.min(maxX, x)), math.max(-maxY, math.min(maxY, y))
    local lock = self.axisLock[id]
    if lock == "x" then x = 0 elseif lock == "y" then y = 0 end
    return x, y
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

function Layout:ActionAreaBottom()
    return self.actionBottom
end

-- The bottom strip iteration (004) owns the reserved baseline. Publishing one
-- message keeps the bars, the cooldown stack and the preset preview on the same
-- number without a component reading another component's private state.
function Layout:SetActionAreaBottom(bottom)
    bottom = plainNumber(bottom)
    if not bottom or bottom ~= bottom then return false end
    bottom = math.max(0, bottom)
    if self.actionBottom == bottom then return false end
    self.actionBottom = bottom
    -- No geometry payload: subscribers recompute after combat, so this message
    -- itself never reads protected sizes in the middle of a fight.
    app:Publish("LAYOUT_CENTRAL_CHANGED")
    return true
end

-- One measurement of the managed action area. `action.rows` follows the actual
-- stack (present bars only); when no bar can be measured the three fallback rows
-- are explicit estimates. `content.width` is the visible cooldown block the unit
-- frames sit beside; `units.left/right` use that same boundary. `cooldown.bottom`
-- is the shared central anchor.
function Layout:Central()
    local screenWidth, screenHeight = uiSize()
    local rows, measured = {}, 0
    for _, name in ipairs(self.actionBarNames) do
        local bar = _G[name]
        local width, height = frameSize(bar)
        if width and height then
            rows[#rows + 1] = { name = name, frame = bar, width = width, height = height }
            measured = measured + 1
        end
    end
    local estimated = false
    if #rows == 0 then
        estimated = true
        for _ = 1, 3 do
            rows[#rows + 1] = { height = self.fallbackActionHeight, estimated = true }
        end
    elseif measured < #self.actionBarNames then
        estimated = true
    end
    local width = 0
    for _, row in ipairs(rows) do
        if row.width and row.width > width then width = row.width end
    end
    if width <= 0 then
        width = self.fallbackActionWidth
        estimated = true
    end
    local height = 0
    for index, row in ipairs(rows) do
        height = height + row.height
        if index < #rows then height = height + self.actionGap end
    end
    local bottom = math.max(0, self.actionBottom)
    local top = bottom + height
    local contentWidth, unitGap = self:BlockMetrics(self.contentWidth)
    local contentBoundary = contentWidth / 2 + unitGap
    local central = {
        screen = { width = screenWidth, height = screenHeight },
        action = {
            bottom = bottom, top = top, height = height, width = width,
            gap = self.actionGap, rows = rows, estimated = estimated,
        },
        cooldown = { bottom = top + self.cooldownGap, top = nil, width = width, gap = self.cooldownGap },
        content = {
            width = contentWidth, left = -contentBoundary, right = contentBoundary,
            gap = unitGap, measured = self.contentWidth ~= nil,
        },
        units = {
            left = -contentBoundary, right = contentBoundary,
            width = contentWidth + unitGap * 2, gap = unitGap,
        },
        anchor = { x = 0 },
        estimated = estimated,
    }
    central.action.bottomY = bottom - screenHeight / 2
    central.action.topY = top - screenHeight / 2
    central.cooldown.bottomY = central.cooldown.bottom - screenHeight / 2
    central.anchor.y = central.cooldown.bottom
    central.anchor.centreY = central.cooldown.bottomY
    -- A stable row interface before any viewer is measured. CentralRows
    -- replaces these with the actual main row once the component runs.
    central.units.rowTop = central.cooldown.bottom
    central.units.rowCenter = central.cooldown.bottom
    central.units.rowTopY = central.cooldown.bottomY
    central.units.rowCenterY = central.cooldown.bottomY
    return central
end

-- The unit boundary follows the widest visible row. A tracked-buff row can be
-- wider than the skill rows; using only the skills let the icons overlap the
-- player/target frames in game. An empty stack falls back to the mockup width.
local function contentRowWidth(rows)
    local width = 0
    for _, row in ipairs(rows) do
        if row.width and row.width > width then width = row.width end
    end
    return width
end

-- Rows are fed in visual order (bottom to top) by the cooldown component. Sizes
-- are converted to UIParent units here, so a viewer with its own Edit Mode scale
-- still lands in the shared stack. Frames whose size cannot be read are skipped
-- and keep their native anchor.
function Layout:CentralRows(entries)
    local central = self:Central()
    local y = central.cooldown.bottom
    local rows = {}
    for _, item in ipairs(entries or {}) do
        local frame = type(item) == "table" and item.frame or item
        local id = type(item) == "table" and item.id or nil
        local width, height = frameSize(frame)
        -- A caller may measure the rendered content (for example the buff icons
        -- inside a wider viewer frame); the smaller readable width wins so the
        -- unit frames do not reserve the viewer's empty Edit Mode area.
        local measured = type(item) == "table" and item.contentWidth or nil
        measured = plainNumber(measured)
        if measured and measured > 0 and (not width or measured < width) then width = measured end
        -- A viewer that reports no usable height (a grid that sizes itself from
        -- its icons) still reserves the rendered height, otherwise its row would
        -- collapse and the next viewer would overlap it.
        local rendered = type(item) == "table" and plainNumber(item.contentHeight) or nil
        if rendered and rendered > 0 and (not height or rendered > height) then height = rendered end
        if frame and height then
            rows[#rows + 1] = {
                id = id, frame = frame, width = width, height = height,
                bottom = y, top = y + height, center = y + height / 2,
            }
            y = y + height + self.cooldownGap
        end
    end
    central.rows = rows
    central.cooldown.top = #rows > 0 and rows[#rows].top or central.cooldown.bottom
    central.mainRow = rows[1]
    -- The widest visible row defines the block the unit frames flank. Storing
    -- the width here keeps the unit boundary and the stack from two
    -- measurements; the caller publishes after placing the rows so this pass
    -- does not re-enter itself. No readable row falls back to the mockup width.
    local measured = contentRowWidth(rows)
    local content, gap = self:BlockMetrics(measured > 0 and measured or nil)
    local contentChanged = storeContentWidth(self, content)
    local boundary = content / 2 + gap
    central.content.width = content
    central.content.left, central.content.right = -boundary, boundary
    central.content.gap = gap
    central.content.measured = self.contentWidth ~= nil
    central.units.left, central.units.right = -boundary, boundary
    central.units.width = content + gap * 2
    central.units.gap = gap
    central.contentChanged = contentChanged or nil
    local halfHeight = central.screen.height / 2
    central.units.rowTop = central.cooldown.top
    central.units.rowCenter = rows[1] and rows[1].center or central.cooldown.bottom
    central.units.rowTopY = central.cooldown.top - halfHeight
    central.units.rowCenterY = central.units.rowCenter - halfHeight
    return central
end

-- Centre offset in an entry's own units for a frame that should sit beside the
-- visible cooldown block. 002 uses this for the player/target main row; the
-- presets use the same call so their outline and the applied position agree.
function Layout:CentralOffset(id, side)
    local central = self:Central()
    local entry = self.entries[id]
    local scale = self:Scale(id)
    local width = 0
    if entry and validFrame(entry.frame) then
        local ok, value = pcall(entry.frame.GetWidth, entry.frame)
        value = ok and plainNumber(value) or nil
        if value and value > 0 then width = value end
    end
    local boundary = central.content.width / 2 + (central.content.gap or self.centralGap)
    return (side or 1) * (boundary / scale + width / 2)
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
        -- A locked axis writes the same centre the next apply will use, so the
        -- overlay cannot briefly settle outside the band it is pinned to.
        x, y = Layout:Constrain(id, x, y)
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
        elseif wanted and not entry.hidden and validFrame(entry.frame) and (entry.frame:IsShown() or entry.allowHiddenMove) then
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
-- scale, so a preset lands at the same place on any resolution. The main unit
-- frames ignore the x fraction: their centre comes from the measured action
-- area (see `UNIT_MAIN_SIDES`), so only y is listed for them.
Layout.presets = {
    default16x9 = {
        label = "preset16x9",
        entries = {
            topInfo = { 0.00, 0.435 },
            -- Half a band height above the bottom; Constrain turns the screen
            -- edge into the flush position once the band owns the margin.
            bottomBar = { 0.00, -0.5 },
            party = { -0.27, -0.34 },
            raidFrames = { 0.25, -0.06 },
            questList = { -0.355, 0.15 },
            inventory = { 0.00, -0.04 },
            characterWindow = { 0.25, 0.10 },
            unit_player = { 0.00, -0.213 },
            unit_target = { 0.00, -0.213 },
            unit_focus = { 0.24, 0.06 },
            unit_pet = { -0.16, -0.26 },
            unit_targettarget = { 0.16, -0.29 },
        },
    },
    combat = {
        label = "presetCombat",
        entries = {
            topInfo = { 0.00, 0.45 },
            bottomBar = { 0.00, -0.5 },
            party = { -0.33, -0.12 },
            raidFrames = { -0.29, -0.10 },
            questList = { 0.37, 0.06 },
            unit_player = { 0.00, -0.23 },
            unit_target = { 0.00, -0.23 },
            unit_focus = { 0.29, -0.13 },
            unit_pet = { -0.17, -0.31 },
            unit_targettarget = { 0.17, -0.31 },
        },
    },
}
Layout.presetOverlays = {}
-- The player and target main bars flank the measured action area in every
-- preset; auxiliary frames keep their own preset offset so they can sit inside
-- the main columns without a preset-only 12x2 shape or a hardcoded width.
local UNIT_MAIN_SIDES = { unit_player = -1, unit_target = 1 }

function Layout:Presets()
    local list = {}
    for id, preset in pairs(self.presets) do
        list[#list + 1] = { id = id, label = preset.label }
    end
    table.sort(list, function(a, b) return a.id < b.id end)
    return list
end

function Layout:PresetOffset(id, spec)
    local scale = self:Scale(id)
    local x = (spec[1] or 0) * UIParent:GetWidth() / scale
    local side = UNIT_MAIN_SIDES[id]
    if side then
        x = self:CentralOffset(id, side)
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
-- Separators follow the measured bar rows, so the outline is the same rectangle
-- the bars will occupy instead of an unrelated 12x2 grid.
local function paintActionGuide(overlay, action)
    overlay.label:ClearAllPoints()
    overlay.label:SetPoint("BOTTOM", overlay, "TOP", 0, 6)
    overlay.rowLines = overlay.rowLines or {}
    local color = app.Theme.colors.line
    local used, offset = 0, 0
    for index, row in ipairs(action.rows or {}) do
        offset = offset + (row.height or 0)
        if index < #action.rows then
            offset = offset + (action.gap or 0)
            used = used + 1
            local line = overlay.rowLines[used]
            if not line then
                line = overlay:CreateTexture(nil, "ARTWORK")
                line:SetHeight(1)
                overlay.rowLines[used] = line
            end
            line:SetColorTexture(color[1], color[2], color[3], 0.35)
            line:ClearAllPoints()
            line:SetPoint("TOPLEFT", overlay, "TOPLEFT", 0, -offset)
            line:SetPoint("TOPRIGHT", overlay, "TOPRIGHT", 0, -offset)
            line:Show()
        end
    end
    for index = used + 1, #overlay.rowLines do overlay.rowLines[index]:Hide() end
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
            local x, y = self:PresetOffset(id, spec)
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
        -- The guide is the geometry every participant will read: measured bar
        -- rows when available, otherwise a labelled fallback estimate.
        local central = self:Central()
        local action = central.action
        local overlay = presetOverlay("nativeActionArea")
        local centerY = action.bottomY + action.height / 2
        overlay:SetSize(action.width, action.height)
        overlay:ClearAllPoints()
        overlay:SetPoint("CENTER", UIParent, "CENTER", 0, centerY)
        paintActionGuide(overlay, action)
        local label = app.L.nativeActionArea
        if action.estimated then label = label .. " · " .. app.L.presetEstimate end
        overlay.label:SetText(label)
        overlay:Show()
        rectangles[#rectangles + 1] = { id = "nativeActionArea", overlay = overlay,
            label = label, x = 0, y = centerY, width = action.width, height = action.height }
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
            local x, y = Layout:PresetOffset(id, spec)
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
