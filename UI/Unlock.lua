local _, app = ...

-- The on-screen unlock mode. Every entry point (settings title bar, a module's
-- Position button, /luma edit, /luma layout, the minimap and tool-corner menus)
-- lands here. Handles, drags and keyboard nudges only change the draft held by
-- Layout; "Save and lock" writes it once, Cancel and Esc drop it.
local Unlock = { selected = nil }
app.Unlock = Unlock

local L = app.L

local function accent() return app.Theme:Accent() end

function Unlock:Active()
    return app.Layout.editing and app.Layout.draft ~= nil
end

----------------------------------------------------------------------
-- Grid and guides
----------------------------------------------------------------------
local function line(self, index)
    local texture = self.lines[index]
    if not texture then
        texture = self.grid:CreateTexture(nil, "BACKGROUND")
        self.lines[index] = texture
    end
    return texture
end

function Unlock:PaintGrid()
    local grid = self.grid
    if not grid then return end
    local width, height = UIParent:GetWidth(), UIParent:GetHeight()
    local step = app.Geometry.grid
    local thin = app.Pixel:Unit()
    local c = accent()
    local used = 0
    for index = 0, math.floor(width / step) do
        used = used + 1
        local texture = line(self, used)
        local x = index * step
        local centre = math.abs(x - width / 2) < 0.5
        texture:ClearAllPoints()
        texture:SetPoint("TOPLEFT", grid, "TOPLEFT", x, 0)
        texture:SetPoint("BOTTOMLEFT", grid, "BOTTOMLEFT", x, 0)
        texture:SetWidth(thin)
        if centre then texture:SetColorTexture(c[1], c[2], c[3], 0.55)
        else texture:SetColorTexture(1, 1, 1, index % 4 == 0 and 0.10 or 0.05) end
        texture:Show()
    end
    for index = 0, math.floor(height / step) do
        used = used + 1
        local texture = line(self, used)
        local y = index * step
        local centre = math.abs(y - height / 2) < 0.5
        texture:ClearAllPoints()
        texture:SetPoint("BOTTOMLEFT", grid, "BOTTOMLEFT", 0, y)
        texture:SetPoint("BOTTOMRIGHT", grid, "BOTTOMRIGHT", 0, y)
        texture:SetHeight(thin)
        if centre then texture:SetColorTexture(c[1], c[2], c[3], 0.55)
        else texture:SetColorTexture(1, 1, 1, index % 4 == 0 and 0.10 or 0.05) end
        texture:Show()
    end
    for index = used + 1, #self.lines do self.lines[index]:Hide() end
    self.gridLines = used
end

function Unlock:ApplyGrid()
    local on = app.Layout.gridOn == true
    if self.grid then self.grid:SetShown(on) end
    if on then self:PaintGrid() end
    if self.gridButton then self.gridButton.selected = on; if self.gridButton.Refresh then self.gridButton:Refresh() end end
end

function Unlock:ShowGuides(placed)
    local guides = self.guides
    if not guides then return end
    local c = accent()
    local function draw(texture, guide, vertical)
        if not guide then texture:Hide(); return end
        texture:ClearAllPoints()
        if vertical then
            texture:SetPoint("TOPLEFT", self.grid, "TOPLEFT", guide.line, 0)
            texture:SetPoint("BOTTOMLEFT", self.grid, "BOTTOMLEFT", guide.line, 0)
            texture:SetWidth(app.Pixel:Unit())
        else
            texture:SetPoint("BOTTOMLEFT", self.grid, "BOTTOMLEFT", 0, guide.line)
            texture:SetPoint("BOTTOMRIGHT", self.grid, "BOTTOMRIGHT", 0, guide.line)
            texture:SetHeight(app.Pixel:Unit())
        end
        texture:SetColorTexture(c[1], c[2], c[3], 0.9)
        texture:Show()
    end
    draw(guides.x, placed and placed.guideX, true)
    draw(guides.y, placed and placed.guideY, false)
end

----------------------------------------------------------------------
-- Selection and inspector
----------------------------------------------------------------------
local function number(text)
    local value = tonumber(text)
    if value and value == value and math.abs(value) < 20000 then return value end
end

function Unlock:RefreshInspector()
    local id, bar = self.selected, self.bar
    if not bar then return end
    local entry = id and app.Layout.entries[id]
    bar.name:SetText(entry and entry.label or L.unlockNone)
    local x, y, anchor, reset = 0, 0, nil, false
    if entry then x, y, anchor, reset = app.Layout:DraftPosition(id) end
    bar.inputX:SetText(entry and tostring(math.floor(x + 0.5)) or "")
    bar.inputY:SetText(entry and tostring(math.floor(y + 0.5)) or "")
    local note = L.unlockHint
    if entry and anchor then
        local target = anchor.target == "screen" and L.unlockScreen
            or (app.Layout.entries[anchor.target] and app.Layout.entries[anchor.target].label) or anchor.target
        note = string.format(L.unlockFollowing, target)
    elseif entry and reset then
        note = L.unlockResetNote
    end
    bar.note:SetText(note)
    for _, control in ipairs({ bar.inputX, bar.inputY, bar.follow, bar.detach, bar.reset }) do
        if control.SetEnabled then control:SetEnabled(entry ~= nil) end
    end
    for other, otherEntry in pairs(app.Layout.entries) do
        if otherEntry.overlay then otherEntry.overlay:SetAlpha(id == nil or other == id and 1 or 0.65) end
    end
end

function Unlock:Select(id)
    if id ~= nil and not app.Layout.entries[id] then id = nil end
    self.selected = id
    self:RefreshInspector()
end

function Unlock:Nudge(dx, dy)
    local id = self.selected
    if not id then return false end
    local x, y = app.Layout:DraftPosition(id)
    return app.Layout:SetDraft(id, x + dx, y + dy)
end

-- Follows the nearest other handle: the facing edges are chosen from the
-- dominant direction, and the current gap becomes the offset.
function Unlock:FollowNearest()
    local id, layout = self.selected, app.Layout
    local entry = id and layout.entries[id]
    if not entry or entry.member then return false end
    local rect = layout:OverlayRect(entry.overlay)
    if not rect then return false end
    local G = app.Geometry
    local cx, cy = G.Center(rect)
    local best, bestDistance
    for _, target in ipairs(layout:SnapTargets(id)) do
        local tx, ty = G.Center(target.rect)
        local distance = (tx - cx) ^ 2 + (ty - cy) ^ 2
        if not bestDistance or distance < bestDistance then best, bestDistance = target, distance end
    end
    if not best then return false end
    local links = layout:Links()
    links[id] = nil
    if G.WouldCycle(links, id, best.id) then app:Print(L.unlockCycle); return false end
    local tx, ty = G.Center(best.rect)
    local point, targetPoint
    if math.abs(cx - tx) >= math.abs(cy - ty) then
        if cx > tx then point, targetPoint = "LEFT", "RIGHT" else point, targetPoint = "RIGHT", "LEFT" end
    else
        if cy > ty then point, targetPoint = "BOTTOM", "TOP" else point, targetPoint = "TOP", "BOTTOM" end
    end
    local ox, oy = G.AnchorOffset(rect, point, best.rect, targetPoint)
    local scale = entry.parentCoordinates and 1 or entry.frame:GetScale()
    local x, y = layout:DraftPosition(id)
    return layout:SetDraft(id, x, y, { target = best.id, point = point, targetPoint = targetPoint,
        x = ox / scale, y = oy / scale })
end

function Unlock:Detach()
    local id, layout = self.selected, app.Layout
    if not id then return false end
    local x, y = layout:CenterOffset(id)
    if not x then x, y = layout:DraftPosition(id) end
    return layout:SetDraft(id, x, y, nil)
end

function Unlock:ResetSelected()
    local id, layout = self.selected, app.Layout
    local entry = id and layout.entries[id]
    if not entry then return false end
    layout.draft[id] = { reset = true, x = entry.x or 0, y = entry.y or 0 }
    layout:ShowDraft(id, entry.x or 0, entry.y or 0)
    self:RefreshInspector()
    return true
end

----------------------------------------------------------------------
-- Frames
----------------------------------------------------------------------
function Unlock:Build()
    if self.bar then return end
    local grid = CreateFrame("Frame", nil, UIParent)
    grid:SetAllPoints(UIParent)
    grid:SetFrameStrata("DIALOG")
    grid:SetFrameLevel(1)
    grid:EnableMouse(false)
    grid:Hide()
    self.grid, self.lines = grid, {}
    local guideLayer = CreateFrame("Frame", nil, grid)
    guideLayer:SetAllPoints(grid)
    guideLayer:SetFrameLevel(2)
    self.guides = { x = guideLayer:CreateTexture(nil, "OVERLAY"), y = guideLayer:CreateTexture(nil, "OVERLAY") }

    local bar = CreateFrame("Frame", "LumaUIUnlockBar", UIParent, "BackdropTemplate")
    bar:SetSize(560, 112)
    bar:SetPoint("TOP", UIParent, "TOP", 0, -40)
    bar:SetFrameStrata("FULLSCREEN_DIALOG")
    bar:EnableMouse(true)
    app.Theme:PaintSurface(bar, "window")
    bar.name = app.Theme:Text(bar, 14)
    bar.name:SetPoint("TOPLEFT", 14, -12)
    bar.note = app.Theme:Text(bar, 11, true)
    bar.note:SetPoint("TOPLEFT", 14, -34)
    bar.note:SetWidth(530)
    local function field(label, x)
        local title = app.Theme:Text(bar, 11, true)
        title:SetPoint("TOPLEFT", x, -58)
        title:SetText(label)
        local input = app.Controls:Input(bar, 56, { height = 24, maxLetters = 6 })
        input:SetPoint("LEFT", title, "RIGHT", 6, 0)
        return input
    end
    bar.inputX, bar.inputY = field("X", 14), field("Y", 110)
    local function commit()
        local id = self.selected
        if not id then return end
        local x, y = number(bar.inputX:GetText()), number(bar.inputY:GetText())
        if x and y then app.Layout:SetDraft(id, x, y, nil) else self:RefreshInspector() end
    end
    for _, input in ipairs({ bar.inputX, bar.inputY }) do
        local previous = input:GetScript("OnEnterPressed")
        input:SetScript("OnEnterPressed", function(self2) commit(); if previous then previous(self2) end end)
    end
    bar.follow = app.Controls:Button(bar, L.unlockFollow, 96, function() self:FollowNearest() end, { height = 24 })
    bar.follow:SetPoint("TOPLEFT", 206, -56)
    bar.detach = app.Controls:Button(bar, L.unlockDetach, 80, function() self:Detach() end, { height = 24 })
    bar.detach:SetPoint("LEFT", bar.follow, "RIGHT", 6, 0)
    bar.reset = app.Controls:Button(bar, L.unlockReset, 72, function() self:ResetSelected() end, { height = 24 })
    bar.reset:SetPoint("LEFT", bar.detach, "RIGHT", 6, 0)
    self.gridButton = app.Controls:Button(bar, L.unlockGrid, 64, function()
        app.Layout.gridOn = not app.Layout.gridOn
        self:ApplyGrid()
    end, { height = 24 })
    self.gridButton:SetPoint("LEFT", bar.reset, "RIGHT", 6, 0)
    bar.cancel = app.Controls:Button(bar, L.unlockCancel, 96, function() self:Cancel() end, { height = 28 })
    bar.cancel:SetPoint("BOTTOMRIGHT", -14, 10)
    bar.save = app.Controls:Button(bar, L.unlockSave, 140, function() self:Save() end, { height = 28, kind = "primary" })
    bar.save:SetPoint("RIGHT", bar.cancel, "LEFT", -8, 0)
    -- Arrow keys nudge the selection by one unit while no field has focus.
    bar:EnableKeyboard(true)
    bar:SetScript("OnKeyDown", function(frame, key)
        local delta = ({ UP = { 0, 1 }, DOWN = { 0, -1 }, LEFT = { -1, 0 }, RIGHT = { 1, 0 } })[key]
        local focused = app.Controls.focused
        if delta and self.selected and not focused then
            if frame.SetPropagateKeyboardInput then frame:SetPropagateKeyboardInput(false) end
            self:Nudge(delta[1], delta[2])
        elseif frame.SetPropagateKeyboardInput then
            frame:SetPropagateKeyboardInput(true)
        end
    end)
    bar:Hide()
    self.bar = bar
end

----------------------------------------------------------------------
-- Session
----------------------------------------------------------------------
function Unlock:Enter(opts)
    opts = opts or {}
    local layout, settings = app.Layout, app.Settings
    if layout.draft then return true end
    local reopen = opts.page
    if not reopen and settings.frame and settings.frame:IsShown() and settings.wantsOpen then
        reopen = settings.active
    end
    layout.draft = {}
    layout.committed = nil
    if layout.gridOn == nil then layout.gridOn = true end
    if not layout:SetEditing(true) then
        layout.draft = nil
        return false
    end
    self:Build()
    self.returnPage, self.noReturn = reopen, nil
    layout.onSelect = function(id) self:Select(id) end
    layout.onDrag = function(id, overlay)
        local rect = layout:OverlayRect(overlay)
        if rect then self:ShowGuides(layout:SnapRect(id, rect, type(IsShiftKeyDown) == "function" and IsShiftKeyDown())) end
    end
    layout.onDraft = function(id)
        self:ShowGuides(nil)
        if id == self.selected then self:RefreshInspector() end
    end
    layout.onEditEnd = function(committed) self:Teardown(committed) end
    app:Subscribe(self, "PROFILE_CHANGED", function() self.noReturn = true; layout:SetEditing(false) end)
    self.bar:Show()
    self:ApplyGrid()
    local pick = opts.select
    if type(pick) == "string" and layout.entries[pick] and layout.entries[pick].overlay then self:Select(pick)
    else self:Select(nil) end
    return true
end

-- A display or UI scale change: the grid is rebuilt for the new size and the
-- held placements are shown again on the re-measured handles.
function Unlock:Refresh()
    local layout = app.Layout
    if not self:Active() then return end
    layout:SetEditing(true)
    for id, held in pairs(layout.draft) do layout:ShowDraft(id, held.x or 0, held.y or 0) end
    self:ApplyGrid()
    self:RefreshInspector()
end

function Unlock:Toggle(opts)
    if self:Active() then return self:Cancel() end
    return self:Enter(opts)
end

function Unlock:Teardown()
    local layout = app.Layout
    app:Unsubscribe(self, "PROFILE_CHANGED")
    layout.onSelect, layout.onDrag, layout.onDraft, layout.onEditEnd = nil, nil, nil, nil
    if self.bar then self.bar:Hide() end
    if self.grid then self.grid:Hide() end
    self:ShowGuides(nil)
    for _, entry in pairs(layout.entries) do
        if entry.overlay then entry.overlay:SetAlpha(1) end
    end
    self.selected = nil
    local page = self.returnPage
    self.returnPage = nil
    if page and not self.noReturn and not InCombatLockdown() then app.Settings:Open(page) end
end

function Unlock:Save()
    if not self:Active() then return false end
    local ok, refused = app.Layout:Commit()
    if ok and refused and #refused > 0 then app:Print(L.unlockRefused .. " " .. table.concat(refused, ", ")) end
    return ok
end

function Unlock:Cancel()
    if not app.Layout.editing then return false end
    return app.Layout:SetEditing(false)
end
