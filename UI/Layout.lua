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
Layout.resourceGap = 6
Layout.resourceHeight = 11
Layout.resourceTrailingGap = 4
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
            copy[id] = { x = position.x, y = position.y, anchor = position.anchor and app.Geometry.CleanAnchor(position.anchor) or nil }
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
    local entry = self.entries[id]
    if entry and entry.absoluteScale then return self:RelativeScale(id) end
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

-- Entries usually store offsets in their own units. The action bars store
-- UIParent offsets so their centres stay fixed when individual scales change.
function Layout:Constrain(id, x, y)
    local entry = self.entries[id]
    if not entry or not validFrame(entry.frame) then return x, y end
    local scale = self:Scale(id)
    local positionScale = entry.parentCoordinates and 1 or scale
    local halfW = UIParent:GetWidth() / positionScale / 2
    local halfH = UIParent:GetHeight() / positionScale / 2
    local sizeScale = scale / positionScale
    -- A bottom bar owns the screen edge; other entries keep the window margin.
    local margin = entry.margin or self.margin
    local maxX = math.max(0, halfW - entry.frame:GetWidth() * sizeScale / 2 - margin)
    local maxY = math.max(0, halfH - entry.frame:GetHeight() * sizeScale / 2 - margin)
    x, y = math.max(-maxX, math.min(maxX, x)), math.max(-maxY, math.min(maxY, y))
    local lock = self.axisLock[id]
    if lock == "x" then x = 0 elseif lock == "y" then y = 0 end
    return x, y
end

function Layout:Apply(id)
    local entry = self.entries[id]
    if not entry or not validFrame(entry.frame) then return end
    if entry.apply then
        if not entry.hidden then entry.apply() end
        return
    end
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
    local target = saved and self:AnchorTarget(id, saved.anchor)
    if target then
        -- Anchored: the client keeps the follow relation live. The saved x/y
        -- stays as the fallback used whenever the target is missing.
        local anchor = saved.anchor
        frame:SetPoint(anchor.point, target, anchor.targetPoint, anchor.x, anchor.y)
    else
        frame:SetPoint("CENTER", UIParent, "CENTER", x, y)
    end
    app:Publish("LAYOUT_APPLIED", id)
end

-- The id -> target id map of every saved anchor, for loop detection.
function Layout:Links()
    local links = {}
    for id, position in pairs(app.Store:Profile().positions) do
        if position.anchor and position.anchor.target ~= "screen" then links[id] = position.anchor.target end
    end
    return links
end

-- The frame an anchor currently resolves to, or nil when the follow rule cannot
-- apply right now (target unknown, hidden, a loop). The component then sits at
-- its saved x/y and snaps back to the rule once the target returns.
function Layout:AnchorTarget(id, anchor)
    if not anchor then return nil end
    if anchor.target == "screen" then return UIParent end
    local target = self.entries[anchor.target]
    if not target or not validFrame(target.frame) or target.hidden then return nil end
    if not (target.frame:IsShown() or target.allowHiddenMove) then return nil end
    local links = self:Links()
    links[id] = nil
    if app.Geometry.WouldCycle(links, id, anchor.target) then return nil end
    return target.frame
end

-- The entry's centre as a saved offset (the unit Constrain and the Store use),
-- or nil while the frame has no readable rectangle.
function Layout:CenterOffset(id)
    local entry = self.entries[id]
    if not entry or not validFrame(entry.frame) then return nil end
    local x, y = entry.frame:GetCenter()
    local cx, cy = UIParent:GetCenter()
    x, y, cx, cy = app.Capabilities.Plain(x, "number"), app.Capabilities.Plain(y, "number"),
        app.Capabilities.Plain(cx, "number"), app.Capabilities.Plain(cy, "number")
    if not (x and y and cx and cy) then return nil end
    local ratio = entry.frame:GetEffectiveScale() / UIParent:GetEffectiveScale()
    local scale = entry.parentCoordinates and 1 or entry.frame:GetScale()
    return (x * ratio - cx) / scale, (y * ratio - cy) / scale
end

-- Saves a follow rule. Refused for group members (they follow their group),
-- unknown targets, a component following itself and any loop.
function Layout:SetAnchor(id, spec)
    local entry = self.entries[id]
    if not entry or entry.member then return false, "member" end
    local anchor = app.Geometry.CleanAnchor(spec)
    if not anchor then return false, "invalid" end
    if anchor.target ~= "screen" and not self.entries[anchor.target] then return false, "unknown" end
    local links = self:Links()
    links[id] = nil
    if anchor.target ~= "screen" and app.Geometry.WouldCycle(links, id, anchor.target) then return false, "cycle" end
    local position = app.Store:Profile().positions[id]
    local x, y = position and position.x or entry.x or 0, position and position.y or entry.y or 0
    if not app.Store:SetPosition(id, x, y, anchor) then return false, "readonly" end
    self:Apply(id)
    return true
end

-- Detaches a component and keeps it where it is now.
function Layout:ClearAnchor(id)
    local entry = self.entries[id]
    if not entry then return false end
    local position = app.Store:Profile().positions[id]
    if not position or not position.anchor then return true end
    local x, y = self:CenterOffset(id)
    if x then
        x, y = self:Constrain(id, x, y)
        app.Store:SetPosition(id, x, y)
    else
        app.Store:ClearAnchor(id)
    end
    self:Apply(id)
    return true
end

function Layout:ApplyAll()
    if InCombatLockdown() then return end
    for id in pairs(self.entries) do self:Apply(id) end
    if self.previewName then self:PreviewPreset(self.previewName) end
    -- While editing, a moved native frame or a changed UI scale has to move its
    -- guide too; outside editing this is a no-op.
    if self.editing then self:UpdateEdgeGuides() end
end

-- The resource rail's own height. `CentralRows` reserves this lane between the
-- main skill row and an auxiliary row above it; a taller rune row therefore
-- moves the reserved space instead of drawing into the buff row (012 phase 08).
function Layout:SetResourceHeight(height)
    height = plainNumber(height)
    if not height or height <= 0 then return false end
    height = math.max(3, math.min(48, height))
    if math.abs(height - self.resourceHeight) < 0.25 then return false end
    self.resourceHeight = height
    app:Publish("LAYOUT_CENTRAL_CHANGED")
    return true
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
    local rows, stack, measured = {}, {}, 0
    for index, name in ipairs(self.actionBarNames) do
        local bar = _G[name]
        local width, height = frameSize(bar)
        if width and height then
            measured = measured + 1
            local entry = self.entries["actionBar" .. index]
            local detached = entry and not entry.hidden and entry.detached
            -- A detached bar still reserves its row in the central stack. The
            -- player moved the buttons, not the HUD: collapsing the stack made
            -- the cooldown blocks fall to the bottom strip the moment the bars
            -- left the centre. Height stays, width does not (the unit frames
            -- must not hug a bar that lives somewhere else).
            stack[#stack + 1] = { height = height, detached = detached or nil }
            if not detached then
                rows[#rows + 1] = { name = name, frame = bar, width = width, height = height }
            end
        end
    end
    local estimated = false
    if measured == 0 then
        estimated = true
        for _ = 1, 3 do
            stack[#stack + 1] = { height = self.fallbackActionHeight, estimated = true }
        end
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
    if width <= 0 and #stack > 0 then
        width = self.fallbackActionWidth
        estimated = true
    end
    local height = 0
    for index, row in ipairs(stack) do
        height = height + row.height
        if index < #stack then height = height + self.actionGap end
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
        -- `top` equals `bottom` until CentralRows has placed real rows, so a
        -- consumer (resource rail, diagnostics) never reads a nil edge.
        cooldown = { bottom = top + self.cooldownGap, top = top + self.cooldownGap,
            width = width, gap = self.cooldownGap },
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
    -- replaces these with the actual main row once the component runs, and the
    -- last applied rows are merged back in below so every consumer (resource
    -- rail, unit frames, presets, report) reads one applied result.
    central.units.rowTop = central.cooldown.bottom
    central.units.rowCenter = central.cooldown.bottom
    central.units.rowTopY = central.cooldown.bottomY
    central.units.rowCenterY = central.cooldown.bottomY
    -- `Central()` rebuilds a fresh table (the action area can move at any
    -- time), and only `CentralRows` measures the real skill-block top. Without
    -- this merge the cooldown top would always equal the block bottom here, so
    -- a rail anchored to it landed inside the first skill row (010 plan P0).
    local applied = self.appliedRows
    if applied and applied.top and applied.top > central.cooldown.top then
        central.cooldown.top = applied.top
        central.cooldown.topY = applied.top - screenHeight / 2
        central.cooldown.rows = applied.rows
        central.cooldown.applied = true
        -- The top of the main skill rows (essential/utility), which the main
        -- unit bars align their health top with.
        central.cooldown.mainTop = applied.mainTop
        local rowTop = applied.rowTop or applied.top
        central.units.rowTop = rowTop
        central.units.rowTopY = rowTop - screenHeight / 2
    end
    return central
end

-- Fallback width when no row is marked as a main skill row. The primary rule is
-- "widest main row" (see CentralRows): an auxiliary buff row above the skills
-- must not widen the distance between the health bars.
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
    local resource = app.components and app.components.playerResource
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
            local main = type(item) == "table" and item.main == true
            local previous = rows[#rows]
            if not main and previous and previous.main and resource and resource.running then
                y = previous.top + self.resourceGap + self.resourceHeight + self.resourceTrailingGap
            end
            rows[#rows + 1] = {
                id = id, frame = frame, width = width, height = height,
                main = main,
                bottom = y, top = y + height, center = y + height / 2,
            }
            y = y + height + self.cooldownGap
        end
    end
    central.rows = rows
    central.cooldown.top = #rows > 0 and rows[#rows].top or central.cooldown.bottom
    central.cooldown.topY = central.cooldown.top - central.screen.height / 2
    central.mainRow = rows[1]
    -- Main rows (essential and utility skills) define the block the unit frames
    -- flank. An auxiliary row above them may be wider without pushing the health
    -- bars apart, because those rows sit above the frames' top edge. A HUD with
    -- no main row (only tracked buffs) still uses its widest visible row so the
    -- boundary stays meaningful.
    local mainWidth, mainTop, mainBottom, mainCount = 0, nil, nil, 0
    for _, row in ipairs(rows) do
        if row.main then
            mainCount = mainCount + 1
            mainTop = row.top
            mainBottom = mainBottom or row.bottom
            if row.width and row.width > mainWidth then mainWidth = row.width end
        end
    end
    local measured = mainWidth > 0 and mainWidth or contentRowWidth(rows)
    local content, gap = self:BlockMetrics(measured > 0 and measured or nil)
    local contentChanged = storeContentWidth(self, content)
    local boundary = content / 2 + gap
    central.content.width = content
    central.content.left, central.content.right = -boundary, boundary
    central.content.gap = gap
    central.content.measured = self.contentWidth ~= nil
    central.content.mainOnly = mainWidth > 0
    central.units.left, central.units.right = -boundary, boundary
    central.units.width = content + gap * 2
    central.units.gap = gap
    central.mainTop, central.mainBottom = mainTop, mainBottom
    central.mainCount = mainCount
    central.contentChanged = contentChanged or nil
    local halfHeight = central.screen.height / 2
    -- The unit frames read the main row's outer edge: with two main rows that is
    -- the top of the upper skill row, and a buff row above it does not move the
    -- health bars.
    local rowTop = mainTop or central.cooldown.top
    central.units.rowTop = rowTop
    central.units.rowCenter = rows[1] and rows[1].center or central.cooldown.bottom
    central.units.rowTopY = rowTop - halfHeight
    central.units.rowCenterY = central.units.rowCenter - halfHeight
    -- The applied result every later `Central()` read merges in. A change of
    -- the block top (a same-width row getting taller, a row joining or falling
    -- back) is a geometry change for the rail and the report even when the
    -- content width did not move, so it is reported separately from
    -- `contentChanged`. The comparison is against the previous *planned* top:
    -- a refused row keeps its native anchor, and comparing the planned top with
    -- that corrected value would publish again on every beat.
    local previous = self.appliedRows
    local plannedTop = central.cooldown.top
    local topChanged = previous == nil or previous.top == nil
        or math.abs((previous.plannedTop or previous.top) - plannedTop) >= 0.5
    self.appliedRows = {
        rows = rows, top = plannedTop, plannedTop = plannedTop,
        -- The placer's final top is carried across passes; without it a refused
        -- row would read as a new change on every beat and publish forever.
        finalTop = previous and previous.finalTop or nil,
        finalMainTop = previous and previous.finalMainTop or nil,
        rowTop = rowTop,
        mainTop = mainTop, mainBottom = mainBottom, mainCount = mainCount,
        width = central.content.width,
    }
    central.topChanged = topChanged or nil
    -- Kept for `/luma hud` only; layout always recomputes from live frames.
    self.lastCentral = central
    return central
end

-- Keep the final stack edge and the main skill edge separately. A refused
-- anchor can collapse a row or leave it at a readable native position.
function Layout:SetAppliedTop(top, mainTop)
    top = plainNumber(top)
    if not top then return false end
    local applied = self.appliedRows
    if not applied then return false end
    local previous, previousMain = applied.finalTop, applied.finalMainTop
    applied.top, applied.finalTop = top, top
    applied.mainTop, applied.finalMainTop = mainTop, mainTop
    applied.rowTop = mainTop or top
    local mainChanged = previousMain ~= mainTop
        and (not previousMain or not mainTop or math.abs(previousMain - mainTop) >= 0.5)
    return previous == nil or math.abs(previous - top) >= 0.5 or mainChanged
end

-- Called when the cooldown component stops: with no applied rows the resource
-- rail falls back to the reserved baseline above the action area instead of
-- holding a top edge nothing draws at any more.
function Layout:ClearAppliedRows()
    if not self.appliedRows then return false end
    self.appliedRows = nil
    app:Publish("LAYOUT_CENTRAL_CHANGED")
    return true
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

function Layout:StopDragTicker()
    if self.dragTicker and type(self.dragTicker.Cancel) == "function" then self.dragTicker:Cancel() end
    self.dragTicker = nil
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
    overlay:SetScript("OnMouseDown", function()
        if Layout.onSelect then app:Call("layout/select", Layout.onSelect, id) end
    end)
    overlay:SetScript("OnDragStart", function(self)
        if InCombatLockdown() then return end
        self:StartMoving()
        -- Guides are refreshed by a short-lived ticker that only exists for the
        -- length of one drag; no frame carries a permanent update loop.
        if Layout.draft and type(C_Timer) == "table" and type(C_Timer.NewTicker) == "function" then
            Layout:StopDragTicker()
            Layout.dragTicker = C_Timer.NewTicker(0.03, function()
                if Layout.onDrag then app:Call("layout/drag", Layout.onDrag, id, self) end
            end)
        end
    end)
    overlay:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        Layout:StopDragTicker()
        if InCombatLockdown() then return end
        if Layout.draft then
            Layout:DraftDrop(id, self)
            return
        end
        local x, y = self:GetCenter()
        local cx, cy = UIParent:GetCenter()
        local ratio = self:GetEffectiveScale() / UIParent:GetEffectiveScale()
        x, y = x * ratio - cx, y * ratio - cy
        local scale = entry.parentCoordinates and 1 or entry.frame:GetScale()
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

----------------------------------------------------------------------
-- Unlock session draft (015 phase 05)
----------------------------------------------------------------------
-- While `Layout.draft` exists every drop is held in it and only the overlay
-- moves; the frames and the saved profile stay untouched until Commit, so a
-- cancel, an Esc or a combat start has nothing to undo.

-- An overlay as a UIParent-unit rectangle, or nil while it has no readable
-- centre.
function Layout:OverlayRect(overlay)
    if not overlay then return nil end
    local x, y = overlay:GetCenter()
    local ratio = overlay:GetEffectiveScale() / UIParent:GetEffectiveScale()
    x, y = app.Capabilities.Plain(x, "number"), app.Capabilities.Plain(y, "number")
    if not (x and y) then return nil end
    return app.Geometry.Rect(x * ratio, y * ratio, overlay:GetWidth() * ratio, overlay:GetHeight() * ratio)
end

local function uiScreen()
    return { width = UIParent:GetWidth(), height = UIParent:GetHeight() }
end

-- Rectangles of the other visible handles: the snap targets.
function Layout:SnapTargets(excludeId)
    local list = {}
    for id, entry in pairs(self.entries) do
        if id ~= excludeId and entry.overlay and entry.overlay:IsShown() then
            local rect = self:OverlayRect(entry.overlay)
            if rect then list[#list + 1] = { id = id, rect = rect } end
        end
    end
    table.sort(list, function(a, b) return a.id < b.id end)
    return list
end

-- The one placement function: the guide preview and the final drop both call it.
function Layout:SnapRect(id, rect, free)
    local G, screen = app.Geometry, uiScreen()
    local result = { rect = rect }
    if not free then
        local snap = G.Snap(rect, { screen = screen, grid = self.gridOn and G.grid or nil, range = G.range,
            others = self:SnapTargets(id) })
        result.rect = G.Move(rect, snap.dx, snap.dy)
        result.guideX, result.guideY = snap.guideX, snap.guideY
    end
    return result
end

-- Converts a landing rectangle to the saved offset of the entry, within the
-- entry's own limits (screen margin and locked axis).
function Layout:RectToOffset(id, rect)
    local entry = self.entries[id]
    local G, screen = app.Geometry, uiScreen()
    local x, y = G.ToOffset(rect, screen)
    local scale = entry.parentCoordinates and 1 or entry.frame:GetScale()
    return self:Constrain(id, G.Pixel(x / scale, UIParent:GetEffectiveScale() * scale),
        G.Pixel(y / scale, UIParent:GetEffectiveScale() * scale))
end

function Layout:ShowDraft(id, x, y)
    local entry = self.entries[id]
    local overlay = entry and entry.overlay
    if not overlay then return end
    local scale = entry.parentCoordinates and 1 or entry.frame:GetScale()
    overlay:ClearAllPoints()
    overlay:SetPoint("CENTER", UIParent, "CENTER", x * scale, y * scale)
end

function Layout:DraftDrop(id, overlay)
    local rect = self:OverlayRect(overlay)
    if not rect then return end
    local free = type(IsShiftKeyDown) == "function" and IsShiftKeyDown()
    local placed = self:SnapRect(id, rect, free)
    local x, y = self:RectToOffset(id, placed.rect)
    self.draft[id] = { x = x, y = y }
    self:ShowDraft(id, x, y)
    if self.onDraft then app:Call("layout/draft", self.onDraft, id) end
end

-- Sets a draft position directly (inspector fields, arrow keys).
function Layout:SetDraft(id, x, y, anchor)
    if not self.draft or not self.entries[id] then return false end
    x, y = self:Constrain(id, x, y)
    self.draft[id] = { x = x, y = y, anchor = anchor }
    self:ShowDraft(id, x, y)
    if self.onDraft then app:Call("layout/draft", self.onDraft, id) end
    return true
end

-- The draft or saved position of an entry in its own units.
function Layout:DraftPosition(id)
    local draft = self.draft and self.draft[id]
    if draft then return draft.x or 0, draft.y or 0, draft.anchor, draft.reset == true end
    local saved = app.Store:Profile().positions[id]
    local entry = self.entries[id]
    if saved then return saved.x, saved.y, saved.anchor end
    return entry and entry.x or 0, entry and entry.y or 0, nil
end

-- Writes every held placement at once and ends the session.
function Layout:Commit()
    local draft = self.draft
    if not draft then return false end
    if app.Store.readonly then return false end
    local refused = {}
    for id, held in pairs(draft) do
        if held.reset then
            app.Store:Profile().positions[id] = nil
        else
            app.Store:SetPosition(id, held.x, held.y)
            if held.anchor then
                local ok, reason = self:SetAnchor(id, held.anchor)
                if not ok then refused[#refused + 1] = id .. ":" .. tostring(reason) end
            end
        end
        self:Apply(id)
    end
    self.committed = true
    self:SetEditing(false)
    return true, refused
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
    -- Native region outlines use the same rule: display-only, edit-mode only.
    self:UpdateEdgeGuides()
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
                if entry.parentCoordinates then px, py = px / scale, py / scale end
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
    if not wanted then
        self:StopDragTicker()
        local committed = self.committed == true
        self.draft, self.committed = nil, nil
        if self.onEditEnd then app:Call("layout/editEnd", self.onEditEnd, committed) end
    end
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
    -- 012 phase 02: the two Pearl compositions. Both leave the centre to combat
    -- and give each screen edge one job; they only write the entries they list,
    -- so a panel the player never moved keeps its own default and a profile that
    -- never applies a preset is untouched.
    --
    -- City: the map column owns the right edge (objectives under it, bag and
    -- character windows on the right half), the party stays a short column on
    -- the left, chat and strip sit at the bottom, and the centre stays empty
    -- except for the unit pair beside the skill block.
    pearlCity = {
        label = "presetPearlCity",
        entries = {
            topInfo = { 0.00, 0.435 },
            bottomBar = { 0.00, -0.5 },
            party = { -0.355, -0.20 },
            -- Right column reads top to bottom: map, objectives, meter reserve.
            questList = { 0.345, 0.175 },
            damageMeterArea = { 0.345, -0.315 },
            utilityCorner = { 0.395, -0.325 },
            inventory = { 0.235, -0.14 },
            characterWindow = { 0.245, 0.095 },
            raidFrames = { -0.29, -0.06 },
            unit_player = { 0.00, -0.213 },
            unit_target = { 0.00, -0.213 },
            unit_focus = { 0.265, 0.05 },
            unit_pet = { -0.175, -0.275 },
            unit_targettarget = { 0.175, -0.295 },
        },
    },
    -- Combat: the party and raid grids own the left edge, the objective column
    -- the right edge, the meter the bottom-right corner, and the centre holds
    -- only the skill block, the resource rail and the player/target pair.
    pearlCombat = {
        label = "presetPearlCombat",
        entries = {
            topInfo = { 0.00, 0.45 },
            bottomBar = { 0.00, -0.5 },
            party = { -0.345, -0.135 },
            raidFrames = { -0.305, -0.10 },
            questList = { 0.365, 0.075 },
            damageMeterArea = { 0.355, -0.345 },
            utilityCorner = { 0.40, -0.355 },
            inventory = { 0.30, -0.19 },
            characterWindow = { 0.295, 0.16 },
            unit_player = { 0.00, -0.23 },
            unit_target = { 0.00, -0.23 },
            unit_focus = { 0.285, -0.135 },
            unit_pet = { -0.17, -0.315 },
            unit_targettarget = { 0.17, -0.315 },
        },
    },
    -- Blood Death Knight starting point: key buffs stay above the skill block
    -- (their native viewer is not moved), the two own groups form a compact
    -- two-row block, the cast bar reserves the space below, and the unit pair
    -- flanks it. Resource and rune rails follow the central block on their own.
    -- Only the entries listed are written; applying is explicit and undoable.
    pearlBloodDK = {
        label = "presetPearlBloodDK",
        entries = {
            topInfo = { 0.00, 0.435 },
            bottomBar = { 0.00, -0.5 },
            cdGroup_essential = { 0.00, -0.105 },
            cdGroup_utility = { 0.00, -0.165 },
            playerCast = { 0.00, -0.26 },
            party = { -0.355, -0.20 },
            questList = { 0.345, 0.175 },
            unit_player = { 0.00, -0.213 },
            unit_target = { 0.00, -0.213 },
            unit_focus = { 0.265, 0.05 },
            unit_pet = { -0.175, -0.275 },
            unit_targettarget = { 0.175, -0.295 },
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

-- Separators follow the measured rows that still use the default stack.
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
    local action = name == "combat" and self:Central().action
    if action and #action.rows > 0 then
        -- The guide is the geometry every participant will read: measured bar
        -- rows when available, otherwise a labelled fallback estimate.
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
                snapshot.positions[id] = { x = positions[id].x, y = positions[id].y,
                    anchor = positions[id].anchor and app.Geometry.CleanAnchor(positions[id].anchor) or nil }
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

----------------------------------------------------------------------
-- Native region ownership
----------------------------------------------------------------------
-- Each screen region has exactly one owner. Sampling reads the client's own
-- rectangle when the build reports one; a region whose frame is missing stays
-- nil instead of being given a guessed boundary, so a client without (say) a
-- damage meter cannot have its edges reset by a placeholder. The samples feed
-- the `/luma hud` overlap line and the edit-mode guides; nothing here moves a
-- native frame.
-- Local read of a frame's visibility. The `/luma hud` helpers are declared
-- further down with the report, so the sampler keeps its own copy.
local function regionShown(frame)
    if type(frame.IsShown) ~= "function" then return false end
    local ok, shown = pcall(frame.IsShown, frame)
    return ok and shown == true
end

-- Effective visibility, not the raw IsShown flag: the client's IsVisible also
-- walks the parent chain, and a frame at zero alpha is drawn by nobody even
-- when it reports shown. A value this Lua cannot read stays nil so a restricted
-- answer is reported as unknown instead of being flattened to "hidden".
local function frameAlpha(frame)
    if type(frame.GetAlpha) ~= "function" then return nil end
    local ok, value = pcall(frame.GetAlpha, frame)
    return ok and plainNumber(value) or nil
end

local function effectiveAlpha(frame)
    local alpha, current, depth = 1, frame, 0
    while object(current) and depth < 12 do
        local value = frameAlpha(current)
        if value == nil then return nil end
        alpha = alpha * value
        if type(current.GetParent) ~= "function" then break end
        local ok, parent = pcall(current.GetParent, current)
        current = ok and parent or nil
        depth = depth + 1
    end
    return alpha
end

local function visibleState(frame)
    local shown
    if type(frame.IsVisible) == "function" then
        local ok, value = pcall(frame.IsVisible, frame)
        if ok and not app.Capabilities.IsSecret(value) then shown = value == true end
    end
    if shown == nil then
        local ok, value = pcall(frame.IsShown, frame)
        if ok and not app.Capabilities.IsSecret(value) then shown = value == true end
    end
    if shown == nil then return nil end
    if shown == false then return false end
    local alpha = effectiveAlpha(frame)
    if alpha ~= nil and alpha <= 0.01 then return false end
    return true
end

-- One region, one owner, one family. A family groups frames that belong to the
-- same control (`ChatFrame1` and LumaUI's own chat plate both draw the chat
-- window), so their overlap is design, not a layout conflict. Different owners
-- under one family still report: two unit frames overlapping is a real bug.
Layout.regions = {
    map = { names = { "MinimapCluster", "Minimap" }, owner = "minimap", family = "map" },
    mapDrawer = { names = { "LumaUIMinimapDrawer" }, owner = "minimap", family = "mapDrawer" },
    utility = { names = { "LumaUIUtilityCorner" }, owner = "utilityCorner", family = "utility" },
    tracker = { names = { "ObjectiveTrackerFrame" }, owner = "questTracker", family = "tracker" },
    chat = { names = { "ChatFrame1" }, owner = "chat", family = "chat" },
    chatPlate = { names = { "LumaUIChatFrame1Plate" }, owner = "chat", family = "chat" },
    cast = { names = { "PlayerCastingBarFrame" }, owner = "native", family = "cast" },
    extra = { names = { "ExtraActionButton1" }, owner = "native", family = "extra" },
    meter = { names = { "LumaUIDamageMeter" }, owner = "damageMeter", family = "meter" },
    resource = { names = { "LumaUIPlayerResource" }, owner = "playerResource", family = "resource" },
    unitPlayer = { names = { "LumaUIUnit_player" }, owner = "unitFrames", family = "unitPlayer" },
    unitTarget = { names = { "LumaUIUnit_target" }, owner = "unitFrames", family = "unitTarget" },
    questList = { names = { "LumaUIQuestList" }, owner = "questList", family = "questList" },
    -- The own cooldown groups: a player who drags one onto another region gets
    -- the overlap line in `/luma hud` instead of a silent stack.
    cdEssential = { names = { "LumaUICooldownOwn_essential" }, owner = "cooldownGroups", family = "cdEssential" },
    cdUtility = { names = { "LumaUICooldownOwn_utility" }, owner = "cooldownGroups", family = "cdUtility" },
    cdBuffs = { names = { "LumaUICooldownOwn_buffs" }, owner = "cooldownGroups", family = "cdBuffs" },
    strip = { names = { "LumaUIDataStrip" }, owner = "dataStrip", family = "strip" },
}

-- Rectangle in UIParent units, or nil when the frame reports none. A frame at a
-- different effective scale is converted with its own ratio, the same way the
-- cooldown stack measures native frames.
function Layout:Sample(id)
    local region = self.regions[id]
    if not region then return nil end
    for _, name in ipairs(region.names) do
        local frame = _G[name]
        if object(frame) then
            local scale = 1
            if type(frame.GetEffectiveScale) == "function" then
                local value = plainNumber(select(2, pcall(frame.GetEffectiveScale, frame)))
                local base = plainNumber(select(2, pcall(UIParent.GetEffectiveScale, UIParent)))
                if value and base and value > 0 and base > 0 then scale = value / base end
            end
            if scale <= 0 then scale = 1 end
            local sample = {
                id = id, name = name, frame = frame, owner = region.owner,
                family = region.family or id, reserved = region.reserved == true,
                scale = scale, shown = regionShown(frame), visible = visibleState(frame),
                alpha = effectiveAlpha(frame),
            }
            if type(frame.GetRect) == "function" then
                local ok, left, bottom, width, height = pcall(frame.GetRect, frame)
                left, bottom = ok and plainNumber(left) or nil, ok and plainNumber(bottom) or nil
                width, height = ok and plainNumber(width) or nil, ok and plainNumber(height) or nil
                if left and bottom and width and height then
                    sample.left, sample.bottom = left / scale, bottom / scale
                    sample.width, sample.height = width / scale, height / scale
                    sample.measured = true
                end
            end
            if not sample.measured and type(frame.GetSize) == "function" then
                -- Size without a position: enough to describe the region, not
                -- enough to claim where it sits.
                local ok, width, height = pcall(frame.GetSize, frame)
                width, height = ok and plainNumber(width) or nil, ok and plainNumber(height) or nil
                if width and height then
                    sample.width, sample.height = width / scale, height / scale
                end
            end
            return sample
        end
    end
end

-- Pairs of owned regions whose measured rectangles intersect. Native-owned
-- samples are excluded: the client is allowed to overlap its own cast bar, and
-- a reserved outline is not drawn at all. Two regions of the same control
-- family (the native chat frame and LumaUI's plate under it) are one surface,
-- not a conflict; everything else with a real intersection is reported.
function Layout:Overlaps()
    -- Sorted ids make the family representative deterministic: "chat" wins over
    -- "chatPlate" for the chat window, so one control yields one rectangle and
    -- a real conflict is reported once.
    local ids = {}
    for id in pairs(self.regions) do ids[#ids + 1] = id end
    table.sort(ids)
    local samples, families = {}, {}
    for _, id in ipairs(ids) do
        local sample = self:Sample(id)
        if sample and sample.measured and sample.visible == true
            and sample.owner ~= "native" and not sample.reserved
            and not families[sample.family] then
            families[sample.family] = true
            samples[#samples + 1] = sample
        end
    end
    local list = {}
    for index = 1, #samples do
        for other = index + 1, #samples do
            local a, b = samples[index], samples[other]
            local width = math.min(a.left + a.width, b.left + b.width) - math.max(a.left, b.left)
            local height = math.min(a.bottom + a.height, b.bottom + b.height) - math.max(a.bottom, b.bottom)
            if width > 1 and height > 1 then
                list[#list + 1] = {
                    a = a.id, b = b.id, ownerA = a.owner, ownerB = b.owner,
                    width = width, height = height,
                }
            end
        end
    end
    return list
end

-- Read-only layout result for the whole screen. Every known region reports its
-- owner, whether the rectangle was measured or is only a size, whether the
-- player can currently see it, and whether it is a reservation rather than a
-- drawn frame. Unknown positions stay nil: a region without a readable rect is
-- reported as unknown instead of being placed at zero (012 phase 02).
function Layout:RegionLayout()
    local screenWidth, screenHeight = uiSize()
    local ids = {}
    for id in pairs(self.regions) do ids[#ids + 1] = id end
    table.sort(ids)
    local regions = {}
    for _, id in ipairs(ids) do
        local region = self.regions[id]
        local sample = self:Sample(id)
        regions[#regions + 1] = {
            id = id, owner = region.owner, family = region.family,
            reserved = region.reserved == true,
            measured = sample and sample.measured or false,
            shown = sample and sample.shown or nil,
            visible = sample and sample.visible or nil,
            left = sample and sample.left or nil,
            bottom = sample and sample.bottom or nil,
            width = sample and sample.width or nil,
            height = sample and sample.height or nil,
            source = sample and sample.measured and "client" or "unknown",
        }
    end
    return { screen = { width = screenWidth, height = screenHeight }, regions = regions }
end

function Layout:CreateEdgeGuides()
    if self.edgeGuides then return self.edgeGuides end
    local guides = {}
    self.edgeGuides = guides
    return guides
end

-- The edit-mode guides are the only place the sampled rectangles become
-- visible. They are display-only, created once and never anchored to the
-- frames they describe, so hiding them restores nothing.
function Layout:UpdateEdgeGuides()
    local guides = self:CreateEdgeGuides()
    for id in pairs(self.regions) do
        local guide = guides[id]
        if not self.editing then
            if guide then guide:Hide() end
        else
            local sample = self:Sample(id)
            if not sample then
                if guide then guide:Hide() end
            else
                if not guide then
                    guide = CreateFrame("Frame", "LumaUIEdgeGuide_" .. id, UIParent, "BackdropTemplate")
                    guide:EnableMouse(false)
                    guide:SetFrameStrata("DIALOG")
                    guide:SetBackdrop({ edgeFile = app.Theme.white, edgeSize = app.Pixel:Pixels(1, guide) })
                    guide.label = app.Theme:Text(guide, 10, true)
                    guide.label:SetPoint("TOPLEFT", 4, -3)
                    guides[id] = guide
                end
                local accent = app.Theme:Accent()
                guide:SetBackdropBorderColor(accent[1], accent[2], accent[3],
                    sample.measured and 0.75 or 0.3)
                guide:ClearAllPoints()
                guide.label:SetText(string.format("%s · %s · %s", sample.name, sample.owner,
                    sample.measured and app.L.hudMeasured or app.L.hudEstimate))
                if sample.measured then
                    guide:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", sample.left, sample.bottom)
                    guide:SetSize(math.max(4, sample.width), math.max(4, sample.height))
                else
                    guide:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
                    guide:SetSize(sample.width or 120, sample.height or 24)
                end
                guide:Show()
            end
        end
    end
end

----------------------------------------------------------------------
-- Read-only geometry report (`/luma hud`)
----------------------------------------------------------------------
-- One sampling point for 01 and 03: the central measurement, the four cooldown
-- viewers with their pools, the managed action bars and the native frames the
-- edge layout has to avoid. Everything here is a read; a frame that does not
-- report a rectangle is printed as unknown instead of being given a guess, and
-- nothing is walked beyond this fixed list.
-- Viewer global name to the skin record's id, so the report can show how many
-- icons of each viewer carry the Pearl skin.
local VIEWER_IDS = {
    EssentialCooldownViewer = "essential", UtilityCooldownViewer = "utility",
    BuffBarCooldownViewer = "buffBar", BuffIconCooldownViewer = "buffIcon",
}
local HUD_SAMPLES = {
    { key = "viewer", owner = "cooldownViewer", names = {
        "EssentialCooldownViewer", "UtilityCooldownViewer",
        "BuffBarCooldownViewer", "BuffIconCooldownViewer" } },
    { key = "bar", owner = "actionBars", names = {
        "MainActionBar", "MultiBarBottomLeft", "MultiBarBottomRight" } },
    { key = "map", owner = "minimap", names = { "Minimap", "MinimapCluster" } },
    { key = "tracker", owner = "questTracker", names = { "ObjectiveTrackerFrame" } },
    { key = "chat", owner = "chat", names = { "ChatFrame1" } },
    { key = "chatPlate", owner = "chat", names = { "LumaUIChatFrame1Plate" } },
    { key = "cast", owner = "native", names = { "PlayerCastingBarFrame" } },
    -- The edit-mode cast outline is reserved space, not a drawn frame: the
    -- report says so instead of counting it as a hidden bar.
    { key = "castArea", owner = "layout", reserved = true,
        names = { "LumaUIPlaceholder_unit_player_cast" } },
    -- LumaUI's own cooldown group containers and its own cast bar: a group that
    -- is not enabled has no frame, which the report prints as a missing object
    -- instead of guessing a position. Two groups sharing one rectangle is the
    -- 012 defect this line makes visible.
    { key = "ownGroup", owner = "cooldownGroups", names = {
        "LumaUICooldownOwn_essential", "LumaUICooldownOwn_utility", "LumaUICooldownOwn_buffs" } },
    { key = "ownCast", owner = "playerCast", names = { "LumaUIPlayerCast" } },
    { key = "extra", owner = "native", names = { "ExtraActionButton1", "PersonalResourceDisplayFrame" } },
    { key = "resource", owner = "playerResource", names = { "LumaUIPlayerResource" } },
    { key = "unit", owner = "unitFrames", names = { "LumaUIUnit_player", "LumaUIUnit_target" } },
    { key = "questList", owner = "questList", names = { "LumaUIQuestList" } },
    { key = "strip", owner = "dataStrip", names = { "LumaUIDataStrip" } },
}

-- GetRect reports a frame in its own scaled units, so two frames only compare
-- after both rectangles are moved into UIParent units (the space the central
-- rows use). The ratio is the same one the layout applies when reading sizes.
local function rectText(frame)
    if not object(frame) or type(frame.GetRect) ~= "function" then return "unknown" end
    local ok, left, bottom, width, height = pcall(frame.GetRect, frame)
    left, bottom = ok and plainNumber(left) or nil, ok and plainNumber(bottom) or nil
    width, height = ok and plainNumber(width) or nil, ok and plainNumber(height) or nil
    if not left or not bottom or not width or not height then return "unknown" end
    local ratio = frameRatio(frame)
    return string.format("%.0fx%.0f@%.0f,%.0f",
        width * ratio, height * ratio, left * ratio, bottom * ratio)
end

local function shownText(frame)
    if not object(frame) or type(frame.IsShown) ~= "function" then return "?" end
    local ok, shown = pcall(frame.IsShown, frame)
    if not ok or app.Capabilities.IsSecret(shown) then return "?" end
    return shown == true and "yes" or "no"
end

-- Effective visibility: the parent chain and a readable alpha explain a hidden
-- frame, so an off-screen parent or a faded window is not reported as "LumaUI
-- hid it". An unreadable answer stays "?" instead of being flattened.
local function visibleText(frame)
    local visible = visibleState(frame)
    if visible == nil then return "?" end
    return visible and "yes" or "no"
end

local function activeCount(frame)
    local pool = frame and frame.itemFramePool
    if not object(pool) or type(pool.EnumerateActive) ~= "function" then return nil end
    local count = 0
    pcall(function() for _ in pool:EnumerateActive() do count = count + 1 end end)
    return count
end

-- Rendered block of a viewer's own buttons, in UIParent units, when the build
-- exposes readable icon rectangles. Each rectangle is scaled by its own frame
-- ratio first: GetRect already divides by that frame's effective scale, so
-- dividing the union by UIParent's scale alone would report every button that
-- shares UIParent's scale as 1/scale too large. Reported as a size, never used
-- for layout.
local function iconBlock(frame)
    if not object(frame) then return nil end
    local minLeft, maxRight, minBottom, maxTop = nil, nil, nil, nil
    local pool = frame.itemFramePool
    local function add(button)
        if not object(button) or type(button.GetRect) ~= "function" then return end
        local ok, left, bottom, width, height = pcall(button.GetRect, button)
        left, bottom = ok and plainNumber(left) or nil, ok and plainNumber(bottom) or nil
        width, height = ok and plainNumber(width) or nil, ok and plainNumber(height) or nil
        if not left or not bottom or not width or not height then return end
        local ratio = frameRatio(button)
        left, bottom = left * ratio, bottom * ratio
        width, height = width * ratio, height * ratio
        minLeft = minLeft and math.min(minLeft, left) or left
        maxRight = maxRight and math.max(maxRight, left + width) or (left + width)
        minBottom = minBottom and math.min(minBottom, bottom) or bottom
        maxTop = maxTop and math.max(maxTop, bottom + height) or (bottom + height)
    end
    if object(pool) and type(pool.EnumerateActive) == "function" then
        pcall(function() for button in pool:EnumerateActive() do add(button) end end)
    end
    if not minLeft or not maxRight or maxRight <= minLeft then return nil end
    return maxRight - minLeft, (maxTop or 0) - (minBottom or 0)
end

function Layout:Diagnose()
    local screenWidth, screenHeight = uiSize()
    local scale = plainNumber(select(2, pcall(UIParent.GetEffectiveScale, UIParent))) or 1
    app:Print(string.format("%s: screen=%dx%d scale=%.2f",
        app.L.hudHeader, screenWidth, screenHeight, scale))
    local central = self:Central()
    local estimated = central.action.estimated and app.L.hudEstimate or app.L.hudMeasured
    app:Print(string.format("  action: bottom=%.0f top=%.0f width=%.0f rows=%d %s=%s owner=actionBars",
        central.action.bottom, central.action.top, central.action.width, #central.action.rows,
        app.L.hudMeasured, estimated))
    app:Print(string.format("  content: width=%.0f gap=%.1f measured=%s boundary=%.0f/%.0f owner=layout",
        central.content.width, central.content.gap or 0,
        central.content.measured and "yes" or "no", central.content.left, central.content.right))
    local last = self.lastCentral
    local rows = last and last.rows or {}
    local main = last and last.mainRow
    local profile = app.Store and app.Store:Profile()
    local look = profile and profile.appearance
    -- `top` is the applied skill-block top every consumer reads (the rail sits
    -- RAIL_GAP above it); `rows` names what this run planned, bottom to top.
    local topText = central.cooldown.applied and string.format("%.0f", central.cooldown.top) or "?"
    app:Print(string.format("  cooldown: bottom=%.0f top=%s rows=%d main=%s slots=%s",
        central.cooldown.bottom, topText, #rows, main and tostring(main.id or "row1") or "none",
        (look and look.perIconSlots == true) and "on" or "off"))
    -- The rows LumaUI actually planned, bottom to top. Two runs (login and an
    -- instance) can be compared line by line instead of by screenshot: a row that
    -- is present in one and absent in the other names the viewer responsible.
    for index, row in ipairs(rows) do
        app:Print(string.format("  row%d %s: w=%.0f h=%.0f bottom=%.0f main=%s", index,
            tostring(row.id or "?"), row.width or 0, row.height or 0, row.bottom or 0,
            row.main and "yes" or "no"))
    end
    for _, sample in ipairs(HUD_SAMPLES) do
        for _, name in ipairs(sample.names) do
            local frame = _G[name]
            if object(frame) then
                local line = string.format("  %s %s: shown=%s vis=%s rect=%s owner=%s",
                    sample.key, name, shownText(frame), visibleText(frame), rectText(frame), sample.owner)
                local alpha = effectiveAlpha(frame)
                if alpha ~= nil and alpha < 0.995 then
                    line = string.format("%s alpha=%.2f", line, alpha)
                end
                if sample.reserved then line = line .. " reserved=yes" end
                if sample.key == "viewer" then
                    local active = activeCount(frame)
                    local blockWidth, blockHeight = iconBlock(frame)
                    local block = blockWidth
                        and string.format("%.0fx%.0f", blockWidth, blockHeight or 0) or "unknown"
                    line = string.format("%s icons=%s block=%s", line,
                        active and tostring(active) or "?", block)
                    -- How many of this viewer's visible icons carry the Pearl
                    -- skin this run, so a native-looking icon has a named
                    -- cause instead of a screenshot to compare.
                    local component = app.components and app.components.cooldownViewer
                    local counts = component and component.skinStats
                        and component.skinStats[VIEWER_IDS[name]]
                    if counts then
                        line = string.format("%s skin=%d/%d", line, counts.applied,
                            counts.applied + counts.unknown)
                    end
                end
                app:Print(line)
            else
                app:Print(string.format("  %s %s: %s owner=%s", sample.key, name,
                    app.L.hudUnknown, sample.owner))
            end
        end
    end
    -- Two owned regions under one rectangle is a real layout conflict: the
    -- report names both owners so the next step is not a guess.
    local overlaps = self:Overlaps()
    if #overlaps == 0 then
        app:Print("  overlap: none")
    else
        for _, pair in ipairs(overlaps) do
            app:Print(string.format("  overlap: %s/%s %.0fx%.0f", pair.a, pair.b,
                pair.width, pair.height))
        end
    end
end
