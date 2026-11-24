local _, app = ...

-- Native cooldown viewer placement. The client's own Cooldown Manager frames
-- (essential and utility skills, tracked buffs as icons and as bars) are moved
-- into one centred stack above the managed action area. Nothing is re-implemented:
-- the client keeps the tracked list, the cooldown engine, glow, tooltips and
-- every Edit Mode setting; this component only records and replaces the frames'
-- anchors, and puts them back on disable.
--
-- Visibility is the client's decision. A viewer the player hid (or that is
-- empty, alpha zero, or has no readable size) is skipped instead of being forced
-- on screen, so the native layout option keeps its meaning and an empty row does
-- not reserve space. A viewer whose re-anchor is refused keeps its original
-- point while the rest of the stack continues.

local BUFF_ICON = "BuffIconCooldownViewer"
local STACK = {
    { id = "essential", name = "EssentialCooldownViewer" },
    { id = "utility", name = "UtilityCooldownViewer" },
    { id = "buffBar", name = "BuffBarCooldownViewer" },
    { id = "buffIcon", name = BUFF_ICON },
}
local CONTENT_LISTS = { "cooldownButtons", "activeButtons", "itemFrames", "buttons", "icons" }
local LAYOUT_JOB, RESTORE_JOB = "cooldownViewer/layout", "cooldownViewer/restore"

local function object(value)
    local kind = type(value)
    return kind == "table" or kind == "userdata"
end

local function inCombat()
    return type(InCombatLockdown) == "function" and InCombatLockdown()
end

local function plain(value, expected)
    return app.Capabilities.Plain(value, expected)
end

local function viewers()
    local list = {}
    for _, def in ipairs(STACK) do
        local frame = _G[def.name]
        if object(frame) and type(frame.SetPoint) == "function" then
            list[#list + 1] = frame
        end
    end
    return list
end

-- Local frame units to UIParent units, so a viewer scaled by Edit Mode still
-- lands on the shared stack instead of drifting by its own scale.
local function frameRatio(frame)
    if not object(frame) or type(frame.GetEffectiveScale) ~= "function"
        or type(UIParent.GetEffectiveScale) ~= "function" then return 1 end
    local okFrame, frameScale = pcall(frame.GetEffectiveScale, frame)
    local okParent, parentScale = pcall(UIParent.GetEffectiveScale, UIParent)
    frameScale = okFrame and plain(frameScale, "number") or nil
    parentScale = okParent and plain(parentScale, "number") or nil
    if not frameScale or not parentScale or frameScale <= 0 or parentScale <= 0 then return 1 end
    return frameScale / parentScale
end

local function shownState(frame)
    if type(frame.IsShown) ~= "function" then return nil end
    local ok, value = pcall(frame.IsShown, frame)
    if not ok or app.Capabilities.IsSecret(value) then return nil end
    return value == true
end

local function alphaState(frame)
    if type(frame.GetAlpha) ~= "function" then return nil end
    local ok, value = pcall(frame.GetAlpha, frame)
    value = ok and plain(value, "number") or nil
    return value
end

local function heightState(frame)
    if type(frame.GetHeight) ~= "function" then return nil end
    local ok, value = pcall(frame.GetHeight, frame)
    value = ok and plain(value, "number") or nil
    if not value or value ~= value then return nil end
    return value
end

local function shownChild(child)
    if not object(child) then return false end
    if type(child.IsShown) ~= "function" then return true end
    local ok, value = pcall(child.IsShown, child)
    -- An unreadable child is not evidence of an empty row: keep the viewer.
    if not ok or app.Capabilities.IsSecret(value) then return true end
    return value ~= false
end

-- Direct children as a list. The client returns one value per child; a stub
-- that hands back the whole list as a single table is accepted too, so a scene
-- cannot silently see "no children" and skip the scan.
local function childrenOf(frame)
    if type(frame.GetChildren) ~= "function" then return nil end
    local ok, list = pcall(function()
        local first, second = frame:GetChildren()
        if type(first) == "table" and second == nil then return first end
        return { frame:GetChildren() }
    end)
    if not ok or type(list) ~= "table" then return nil end
    return list
end

-- true: content, false: proven empty, nil: this build exposes nothing readable.
-- A client build whose viewer fields differ therefore keeps the native frame in
-- the stack instead of being dropped on a guess.
local function contentState(frame)
    local known = false
    for _, key in ipairs(CONTENT_LISTS) do
        local list = frame[key]
        if type(list) == "table" then
            known = true
            for _, button in pairs(list) do
                if shownChild(button) then return true end
            end
        end
    end
    if known then return false end
    local children = childrenOf(frame)
    if children then
        local buttons = 0
        for _, child in ipairs(children) do
            local kind = object(child) and type(child.GetObjectType) == "function"
                and select(2, pcall(child.GetObjectType, child)) or nil
            if kind == "Button" then
                buttons = buttons + 1
                if shownChild(child) then return true end
            end
        end
        if buttons > 0 then return false end
    end
    local height = heightState(frame)
    if height and height <= 1 then return false end
end

-- The tracked-buff viewer arrives as a native grid aligned to its left edge.
-- The Pearl mockup centres every row, so each visible row is shifted as a whole
-- after the client lays it out. Only the horizontal offsets change: order,
-- size, spacing, tooltips and the client's tracked list stay native.
local function iconButtonsOf(frame)
    local list, seen = {}, {}
    local function add(button)
        if object(button) and not seen[button] and shownChild(button) then
            seen[button] = true
            list[#list + 1] = button
        end
    end
    for _, key in ipairs(CONTENT_LISTS) do
        local group = frame[key]
        if type(group) == "table" then
            for _, button in pairs(group) do add(button) end
        end
    end
    -- Current builds hold the pooled buttons on the viewer itself; this is the
    -- same list the client and EllesmereUI enumerate, so it is the primary
    -- source instead of the older named tables above.
    local pool = frame.itemFramePool
    if object(pool) and type(pool.EnumerateActive) == "function" then
        pcall(function()
            for button in pool:EnumerateActive() do add(button) end
        end)
    end
    if #list == 0 then
        local children = childrenOf(frame)
        if children then
            for _, child in ipairs(children) do add(child) end
        end
    end
    return list
end

local function rectOf(frame)
    if type(frame.GetRect) ~= "function" then return nil end
    local ok, left, bottom, width, height = pcall(frame.GetRect, frame)
    left = ok and plain(left, "number") or nil
    bottom = ok and plain(bottom, "number") or nil
    width = ok and plain(width, "number") or nil
    height = ok and plain(height, "number") or nil
    if not left or not bottom or not width or not height or width <= 0 then return nil end
    return left, bottom, width, height
end

-- Every icon as a screen rectangle. Rows are rebuilt from these boxes instead
-- of the client's own grouping: the grid is repacked on each aura change and
-- the group tables do not follow the rendered layout.
local function iconBoxesOf(frame)
    local boxes = {}
    for _, button in ipairs(iconButtonsOf(frame)) do
        local left, bottom, width, height = rectOf(button)
        if left and width and width > 0 then
            height = height or 0
            boxes[#boxes + 1] = {
                button = button, left = left, right = left + width,
                bottom = bottom, top = bottom + height, height = height,
            }
        end
    end
    return boxes
end

-- Groups boxes into rows by their top edge. The tolerance stays well below one
-- row pitch so two rows are never merged, but wide enough that icons which
-- differ by a pixel share a row instead of each being centred on its own.
local function rowsOf(boxes)
    local sorted = {}
    for _, box in ipairs(boxes) do sorted[#sorted + 1] = box end
    table.sort(sorted, function(a, b)
        if a.top ~= b.top then return a.top > b.top end
        return a.left < b.left
    end)
    local rows, row, rowTop, rowHeight = {}, nil, nil, 0
    for _, box in ipairs(sorted) do
        local tolerance = math.max(2, rowHeight * 0.35)
        if row and math.abs(box.top - rowTop) <= tolerance then
            row[#row + 1] = box
            if box.height > rowHeight then rowHeight = box.height end
        else
            row = { box }
            rows[#rows + 1] = row
            rowTop, rowHeight = box.top, box.height
        end
    end
    return rows
end

-- Shifts one row as a group. The write is idempotent: a row that is already
-- centred moves by less than half a pixel and is left alone. Nothing is cached
-- as "already applied", so a client repack can never leave the rows aligned to
-- the viewer's left edge for the rest of the session.
local function shiftRow(row, center, frame)
    local left, right, members = nil, nil, {}
    for _, box in ipairs(row) do
        left = left and math.min(left, box.left) or box.left
        right = right and math.max(right, box.right) or box.right
        members[box.button] = true
    end
    if not left or not right or right <= left then return end
    local shift = center - (left + right) / 2
    if math.abs(shift) < 0.5 then return end
    local originals = frame.lumaIconOriginals
    if not originals then
        originals = {}
        frame.lumaIconOriginals = originals
    end
    for _, box in ipairs(row) do
        local button = box.button
        local okPoint, point, relative, relativePoint, x, y = pcall(button.GetPoint, button, 1)
        if okPoint and point and type(x) == "number" then
            -- A button anchored to a sibling of the same row follows that
            -- sibling; shifting it again would apply the offset twice.
            local follows = object(relative) and relative ~= frame and members[relative]
            local okScale, scale = pcall(button.GetEffectiveScale, button)
            scale = okScale and plain(scale, "number") or nil
            if not follows and scale and scale > 0 then
                -- The first offset is kept and every later pass aims at the same
                -- absolute target, so a pass that runs before the client has
                -- reported the new rect cannot shift the row a second time.
                local origin = originals[button]
                if not origin then
                    origin = { point, relative, relativePoint, x, y }
                    originals[button] = origin
                end
                local targetX = origin[4] + shift / scale
                if math.abs(x - targetX) >= 0.5 then
                    pcall(button.SetPoint, button, point, relative, relativePoint, targetX, y)
                end
            end
        end
    end
end

-- Rendered block size of the given boxes in UIParent units.
local function blockSize(boxes)
    local minLeft, maxRight, minBottom, maxTop
    for _, box in ipairs(boxes) do
        minLeft = minLeft and math.min(minLeft, box.left) or box.left
        maxRight = maxRight and math.max(maxRight, box.right) or box.right
        minBottom = minBottom and math.min(minBottom, box.bottom) or box.bottom
        maxTop = maxTop and math.max(maxTop, box.top) or box.top
    end
    if not minLeft or not maxRight or maxRight <= minLeft then return nil end
    local okScale, scale = pcall(UIParent.GetEffectiveScale, UIParent)
    scale = okScale and plain(scale, "number") or nil
    if not scale or scale <= 0 then return nil end
    return (maxRight - minLeft) / scale, (maxTop - minBottom) / scale
end

-- The rendered width of a viewer's buttons, free of the Edit Mode frame's empty
-- area. Returns nil when the build exposes no readable buttons, so the caller
-- keeps the frame width for progress rows without icons.
local function measure(frame)
    local minLeft, maxRight
    for _, button in ipairs(iconButtonsOf(frame)) do
        local bl, _, bw = rectOf(button)
        if bl then
            minLeft = minLeft and math.min(minLeft, bl) or bl
            maxRight = maxRight and math.max(maxRight, bl + bw) or (bl + bw)
        end
    end
    if not minLeft or not maxRight or maxRight <= minLeft then return nil end
    local okScale, scale = pcall(UIParent.GetEffectiveScale, UIParent)
    scale = okScale and plain(scale, "number") or nil
    if not scale or scale <= 0 then return nil end
    return (maxRight - minLeft) / scale
end

-- Centres each visible icon row inside the viewer and returns the rendered
-- width/height in UIParent units, so the unit-frame boundary and the stack row
-- follow the icons rather than the viewer's wider Edit Mode frame. A viewer
-- with no readable rectangle is centred on the screen axis, which is where the
-- stack puts it anyway.
local function reflow(frame)
    local boxes = iconBoxesOf(frame)
    if #boxes < 1 then return nil end
    local center
    local left, _, width = rectOf(frame)
    if left then
        center = left + width / 2
    else
        local screenLeft, _, screenWidth = rectOf(UIParent)
        if not screenLeft then return nil end
        center = screenLeft + screenWidth / 2
    end
    for _, row in ipairs(rowsOf(boxes)) do shiftRow(row, center, frame) end
    local moved = iconBoxesOf(frame)
    return blockSize(#moved > 0 and moved or boxes)
end

-- Puts the icon offsets recorded by the first shift back, so disabling the
-- component restores the client's own left-aligned grid.
local function restoreIcons(frame)
    local originals = frame and frame.lumaIconOriginals
    if not originals then return end
    for button, point in pairs(originals) do
        pcall(button.SetPoint, button, point[1], point[2], point[3], point[4], point[5])
    end
    frame.lumaIconOriginals = nil
end

-- Every anchor is recorded once, before the first write. The client may anchor
-- a viewer with more than one point, so all readable points are kept and put
-- back in order. A viewer with no readable point still gets a record: restoring
-- means clearing the points LumaUI added, not inventing one.
local function record(frame)
    if frame.lumaCooldownViewerOriginal then return true end
    local original = { points = {} }
    for index = 1, 4 do
        local ok, point, relative, relativePoint, x, y = pcall(frame.GetPoint, frame, index)
        if not ok or not point then break end
        original.points[#original.points + 1] = { point, relative, relativePoint, x, y }
    end
    frame.lumaCooldownViewerOriginal = original
    return true
end

local function restorePoints(frame)
    local original = frame.lumaCooldownViewerOriginal
    if not original then return end
    pcall(frame.ClearAllPoints, frame)
    for _, point in ipairs(original.points) do
        pcall(frame.SetPoint, frame, point[1], point[2], point[3], point[4], point[5])
    end
end

local function restoreFrame(frame)
    restorePoints(frame)
    frame.lumaCooldownViewerOriginal = nil
end

-- The stack is re-checked on a slow beat, so a write that would not move the
-- frame is skipped instead of clearing and setting the same anchor again.
local function atTarget(frame, offset)
    local ok, point, relative, _, x, y = pcall(frame.GetPoint, frame, 1)
    if not ok or point ~= "BOTTOM" or (relative ~= nil and relative ~= UIParent) then return false end
    x = plain(x, "number")
    y = plain(y, "number")
    return x ~= nil and y ~= nil and math.abs(x) < 0.5 and math.abs(y - offset) < 0.5
end

local function place(self, frame, bottom)
    local offset = bottom / frameRatio(frame)
    if atTarget(frame, offset) then return true end
    local ok, problem = pcall(function()
        frame:ClearAllPoints()
        frame:SetPoint("BOTTOM", UIParent, "BOTTOM", 0, offset)
    end)
    if ok then return true end
    -- The write can be refused (protected or secret state). Put this control
    -- back on its old anchor and keep going: one viewer must not take the rest
    -- of the stack down with it.
    restorePoints(frame)
    if not self.refused[frame] then
        self.refused[frame] = true
        local name = type(frame.GetName) == "function" and select(2, pcall(frame.GetName, frame)) or nil
        app:Report("cooldownViewer/" .. tostring(name or "viewer"), problem)
    end
    return false
end

-- Bottom to top: skill rows stay closest to the bars, the tracked buff views
-- sit above them, which is the order of the Pearl mockup's block.
local function layout(self)
    -- The tracked-buff grid is centred even when the viewer itself is filtered
    -- out of the stack: a build that reports no readable height, or whose own
    -- button tables still point at pooled frames, must not silently keep the
    -- client's left-aligned grid.
    local iconViewer = _G[BUFF_ICON]
    local iconWidth, iconHeight
    if object(iconViewer) and type(iconViewer.SetPoint) == "function"
        and shownState(iconViewer) ~= false then
        iconWidth, iconHeight = reflow(iconViewer)
    end
    local chosen = {}
    for _, def in ipairs(STACK) do
        local frame = _G[def.name]
        if object(frame) and type(frame.SetPoint) == "function"
            and type(frame.ClearAllPoints) == "function" then
            local shown = shownState(frame)
            local alpha = alphaState(frame)
            local content = contentState(frame)
            local size = heightState(frame)
            -- The icon extent is what is rendered; for the tracked grid it
            -- replaces the viewer's own width and height, so both the stack row
            -- and the block the unit frames flank follow the visible icons.
            local contentWidth = def.id == "buffIcon" and iconWidth or measure(frame)
            local contentHeight = def.id == "buffIcon" and iconHeight or nil
            local readable = contentWidth ~= nil or contentHeight ~= nil
            local sized = (size and size > 1) or (contentHeight and contentHeight > 1)
            if shown == true and (alpha == nil or alpha > 0)
                and (readable or content ~= false) and sized and record(frame) then
                self.recorded[frame] = true
                chosen[#chosen + 1] = {
                    id = def.id, frame = frame,
                    contentWidth = contentWidth, contentHeight = contentHeight,
                }
            end
        end
    end
    local central = app.Layout:CentralRows(chosen)
    self.placedRows = central.rows
    -- A refused write leaves its old anchor in place; collapse that reserved
    -- row so the rest of the stack stays contiguous instead of leaving a gap.
    local shift = 0
    for _, row in ipairs(central.rows) do
        if not place(self, row.frame, row.bottom - shift) then
            shift = shift + row.height + central.cooldown.gap
        end
    end
    -- The unit frames sit beside the visible block. Publish only after the
    -- stack is placed: the width came from this measurement, and re-entering
    -- the layout before the rows were written would leave the first pass half
    -- applied.
    if central.contentChanged then app:Publish("LAYOUT_CENTRAL_CHANGED") end
end

local function restoreAll(self)
    for frame in pairs(self.recorded or {}) do
        restoreFrame(frame)
    end
    -- The tracked grid is centred even when the viewer stayed out of the stack,
    -- so its icon offsets are restored on their own.
    restoreIcons(_G[BUFF_ICON])
    self.recorded = {}
    self.refused = {}
    self.placedRows = {}
    self.pending = nil
end

local function apply(self)
    if inCombat() then
        self.pending = true
        app.Queue:Run(LAYOUT_JOB, function()
            if not self.running then return end
            self.pending = nil
            layout(self)
        end)
        return
    end
    self.pending = nil
    layout(self)
end

app:RegisterComponent({
    id = "cooldownViewer", label = "cooldownViewer", defaultEnabled = true,
    Supported = function()
        -- The viewers can load after login on some builds; the API existing is
        -- enough to run, and every layout pass simply skips missing frames.
        return #viewers() > 0 or type(C_CooldownViewer) == "table"
    end,
    Enable = function(self)
        self.recorded = self.recorded or {}
        self.refused = self.refused or {}
        self.pending = nil
        apply(self)
        self:Listen("PLAYER_ENTERING_WORLD", function(current) apply(current) end)
        -- Edit Mode and a spec change both re-anchor the native viewers; put the
        -- stack back once the client is done with its own layout.
        self:Listen("EDIT_MODE_LAYOUTS_UPDATED", function(current) apply(current) end)
        self:Listen("PLAYER_SPECIALIZATION_CHANGED", function(current) apply(current) end)
        -- Tracked buffs come and go outside the layout events; re-run the pass
        -- so every row is centred again after the client lays the grid out.
        self:Listen("UNIT_AURA", function(current, _, unit)
            if unit == "player" and not inCombat() then apply(current) end
        end)
        self:Listen("PLAYER_REGEN_ENABLED", function(current)
            if current.pending then apply(current) end
        end)
        -- The client repacks the tracked grid and re-anchors the viewers on its
        -- own beats, which can happen after the events above. A slow pass keeps
        -- the stack and the centred rows where the player expects them; every
        -- write below is idempotent, so a settled layout only costs a few reads.
        self:Every(1, function(current)
            -- Combat keeps the queued restore/layout path authoritative, so the
            -- slow pass stays out of it instead of queueing a job every second.
            if current.running and not inCombat() then apply(current) end
        end)
        -- 004 moves the reserved action baseline; both stacks follow the one
        -- published geometry instead of reading each other's private state.
        app:Subscribe(self, "LAYOUT_CENTRAL_CHANGED", function()
            if self.running then apply(self) end
        end)
    end,
    Refresh = function(self) apply(self) end,
    Disable = function(self)
        self.pending = nil
        if inCombat() then
            app.Queue:Run(RESTORE_JOB, function()
                if self.running then return end
                restoreAll(self)
            end)
        else
            restoreAll(self)
        end
    end,
})
