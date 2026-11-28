local _, app = ...
local Previews = {}
app.SettingsPreviews = Previews

-- Live preview stages for the five combat settings pages (019).
--
-- Every preview is built from the same renderer the world uses: `PearlCell` for
-- a cooldown icon, `PlateView` for a nameplate, the theme's own bar recipe for a
-- unit frame. A settings page therefore shows the real composition rather than a
-- drawing of it, and "what the slider does" can be answered without closing the
-- panel.
--
-- Nothing here touches a unit. The sample values are LumaUI's own constants, so
-- a preview can never pull a restricted number into settings code, and no
-- preview calls a combat API at all.

local L = app.L

local function plain(value, expected)
    return app.Capabilities.Plain(value, expected)
end

-- The stage: a recessed plinth under the page controls. `height` is the caller's
-- reserve; the returned frame reports it so the page can lay out the card below
-- it without a magic offset.
function Previews:Stage(parent, height, title)
    local stage = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    stage:EnableMouse(false)
    stage:SetHeight(height or 96)
    app.Surface:Plate(stage, "preview")
    stage.title = app.Type:Text(stage, "micro")
    stage.title:SetPoint("TOPLEFT", 10, -6)
    stage.title:SetText(title or L.previewTitle)
    -- A very light grid: four hairlines, so a rendered sample reads as sitting on
    -- a surface instead of floating in a rectangle. Decoration only.
    stage.grid = {}
    for index = 1, 3 do
        local line = stage:CreateTexture(nil, "ARTWORK")
        line:SetColorTexture(0.85, 0.88, 0.95, 0.035)
        line:SetHeight(1)
        stage.grid[index] = line
    end
    function stage:SetPreviewHeight(value)
        self:SetHeight(value)
        self.reserved = value
    end
    function stage:LayoutGrid()
        local width, height = self:GetWidth() or 0, self:GetHeight() or 0
        for index, line in ipairs(self.grid) do
            line:ClearAllPoints()
            line:SetPoint("TOPLEFT", 8, -math.floor(height * index / 4))
            line:SetWidth(math.max(1, width - 16))
            line:Show()
        end
    end
    stage:SetScript("OnSizeChanged", function(self) self:LayoutGrid() end)
    return stage
end

-- Cooldown block: six real cells through `PearlCell`, one tracking a cooldown,
-- one carrying charges and one in the proc state. The geometry comes from the
-- stored view options, so dragging any slider re-lays the same cells the HUD
-- would draw.
function Previews:CooldownGroup(parent)
    local stage = self:Stage(parent, 108, L.previewCooldowns)
    stage.cells = {}
    local samples = {
        { icon = 133783, state = "ready" },
        { icon = 133784, state = "tracking", remaining = 12.4 },
        { icon = 133785, state = "proc" },
        { icon = 133786, state = "ready", count = 2 },
        { icon = 133787, state = "unavailable" },
        { icon = 133788, state = "ready" },
    }
    for index, sample in ipairs(samples) do
        local cell = app.PearlCell:Create(stage, 26)
        cell:SetPoint("TOPLEFT", 14 + (index - 1) * 34, -30)
        app.PearlCell:Apply(cell, sample)
        stage.cells[index] = cell
    end
    -- The preview re-lays the cells from the stored icon size and gap instead of
    -- rebuilding them: the same objects, a new grid.
    function stage:Layout(options)
        options = options or {}
        local size = plain(options.size, "number") or 26
        local gap = plain(options.gap, "number") or 4
        local countdown = plain(options.countdownSize, "number") or 15
        if size < 12 then size = 12 end
        for index, cell in ipairs(self.cells) do
            local scale = size / (cell.size or 26)
            cell:SetSize(size, size)
            cell:ClearAllPoints()
            cell:SetPoint("TOPLEFT", 14 + (index - 1) * (size + gap), -30)
            if cell.time then
                pcall(cell.time.SetFont, cell.time,
                    app.Type and app.Type:Face() or GameFontNormal:GetFont(), countdown, "OUTLINE")
            end
            if cell.lumaSize ~= size then
                cell.lumaSize = size
                -- The crop is a fraction, so it needs no rescale; only the text
                -- positions move with the cell and the client re-anchors those.
                if scale < 0.6 then cell.count:SetAlpha(0.85) else cell.count:SetAlpha(1) end
            end
        end
        return size
    end
    return stage
end

-- Action bar: the real skin on a throwaway row of twelve slots. The module's own
-- skin is reused so the preview's icon crop, backing and edge are the world's.
function Previews:ActionBar(parent)
    local stage = self:Stage(parent, 92, L.previewActionBar)
    stage.slots = {}
    for index = 1, 8 do
        local button = CreateFrame("Button", nil, stage)
        button:SetSize(30, 30)
        button:SetPoint("TOPLEFT", 14 + (index - 1) * 34, -26)
        local icon = button:CreateTexture(nil, "ARTWORK")
        icon:SetPoint("TOPLEFT", 2, -2)
        icon:SetPoint("BOTTOMRIGHT", -2, 2)
        icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        icon:SetTexture(133783 + index)
        button.icon = icon
        button.HotKey = button:CreateFontString(nil, "OVERLAY")
        button.HotKey:SetPoint("TOPLEFT", 3, -3)
        button.HotKey:SetText(tostring(index))
        button.HotKey:SetFont(app.Type:Face(), 10, "OUTLINE")
        button.Count = button:CreateFontString(nil, "OVERLAY")
        button.Count:SetPoint("BOTTOMRIGHT", -3, 3)
        button.Count:SetText(index % 3 == 0 and "12" or "")
        button.Count:SetFont(app.Type:Face(), 12, "OUTLINE")
        button.NormalTexture = button:CreateTexture(nil, "ARTWORK")
        button.SlotBackground = button:CreateTexture(nil, "BACKGROUND")
        button.SlotArt = button:CreateTexture(nil, "OVERLAY")
        stage.slots[index] = button
    end
    -- The preview applies the same skin the world uses, so a hotkey size or an
    -- icon zoom change is visible here first.
    function stage:Apply()
        local style = app.Store:Profile().ui.actionButtonStyle
        for _, button in ipairs(self.slots) do
            if app.ActionButtonSkin then app.ActionButtonSkin:Apply(button) end
            if button.HotKey and app.Capabilities and app.Capabilities.Plain then
                local font = app.Type:Face()
                if type(button.HotKey.SetFont) == "function" then
                    pcall(button.HotKey.SetFont, button.HotKey, font, style.hotkeySize or 10, "OUTLINE")
                end
                if type(button.Count.SetFont) == "function" then
                    pcall(button.Count.SetFont, button.Count, font, style.countSize or 12, "OUTLINE")
                end
                if type(button.HotKey.SetShown) == "function" then
                    button.HotKey:SetShown(style.hotkeyShow ~= false)
                end
                if type(button.Count.SetShown) == "function" then button.Count:SetShown(true) end
            end
            local zoom = plain(style.iconZoom, "number") or 0.08
            if type(button.icon.SetTexCoord) == "function" then
                pcall(button.icon.SetTexCoord, button.icon, zoom, 1 - zoom, zoom, 1 - zoom)
            end
        end
    end
    return stage
end

-- Unit frame: the real matte bar recipe at the stored proportions, with a name
-- line, the chosen health format and the power rail. `unit` picks which stored
-- profile is shown so a page can preview the frame it is editing.
function Previews:UnitFrame(parent)
    local stage = self:Stage(parent, 96, L.previewUnitFrame)
    local frame = CreateFrame("Frame", nil, stage)
    frame:SetPoint("CENTER", 0, -8)
    local name = app.Theme:Text(frame, 11)
    name:SetPoint("TOPLEFT", 0, 0)
    name:SetText(L.previewUnitName)
    local value = app.Theme:Text(frame, 11)
    value:SetPoint("TOPRIGHT", 0, 0)
    value:SetText("68%")
    local health = app.Theme:Bar(frame, 14)
    health:SetPoint("TOPLEFT", 0, -16)
    health:SetPoint("TOPRIGHT", 0, -16)
    app.Theme:PaintMatteBar(health, app.Theme:Accent())
    local power = app.Theme:Bar(frame, 3)
    power:SetPoint("TOPLEFT", 0, -34)
    power:SetPoint("TOPRIGHT", 0, -34)
    app.Theme:PaintMatteBar(power, app.Theme:PowerColor("player"))
    stage.frame, stage.name, stage.value = frame, name, value
    stage.health, stage.power = health, power
    function stage:Apply(unit)
        local config = app.Store:Profile().ui.unitFrames
        local spec = config and config[unit or "player"] or {}
        local width = plain(spec.width, "number") or 180
        local healthHeight = plain(spec.healthHeight, "number") or 14
        local powerHeight = plain(spec.powerHeight, "number") or 3
        local nameSize = plain(spec.nameSize, "number") or 11
        self.unit = unit or "player"
        self.frame:SetWidth(width)
        self.name:SetWidth(math.max(30, width - 44))
        self.health:SetHeight(healthHeight)
        self.health:ClearAllPoints()
        self.health:SetPoint("TOPLEFT", 0, -16)
        self.health:SetPoint("TOPRIGHT", 0, -16)
        self.power:SetHeight(powerHeight)
        self.power:ClearAllPoints()
        self.power:SetPoint("TOPLEFT", 0, -(16 + healthHeight + 2))
        self.power:SetPoint("TOPRIGHT", 0, -(16 + healthHeight + 2))
        self.frame:SetHeight(16 + healthHeight + powerHeight + 8)
        local font = app.Type:Face()
        if type(self.name.SetFont) == "function" then pcall(self.name.SetFont, self.name, font, nameSize, "") end
        if type(self.value.SetFont) == "function" then pcall(self.value.SetFont, self.value, font, nameSize, "") end
        -- The bar values are the sample's own numbers; they never come from a
        -- unit, so a restricted health read can never reach this code.
        self.health:SetMinMaxValues(0, 100)
        self.health:SetValue(68)
        self.power:SetMinMaxValues(0, 100)
        self.power:SetValue(42)
        local format = spec.healthFormat or "percent"
        self.value:SetText(format == "none" and "" or (format == "value" and "68"
            or (format == "both" and "68 / 100" or "68%")))
        self.label = self.unit
    end
    return stage
end

-- Resource and cast: the layered energy rail with six rune segments next to the
-- player cast bar, plus the three preview buttons. The buttons drive the real
-- cast bar (through `playerCast:StartPreview`) so the page and the screen show
-- the identical state.
function Previews:ResourceCast(parent)
    local stage = self:Stage(parent, 118, L.previewResourceCast)
    local rail = CreateFrame("Frame", nil, stage)
    rail:SetPoint("TOPLEFT", 14, -30)
    rail:SetWidth(220)
    rail.primary = app.Theme:Bar(rail, 10)
    rail.primary:SetPoint("TOPLEFT", 0, 0)
    rail.primary:SetPoint("TOPRIGHT", 0, 0)
    app.Theme:PaintMatteBar(rail.primary, app.Theme:PowerColor("player"))
    rail.primary:SetMinMaxValues(0, 100)
    rail.primary:SetValue(64)
    rail.runes = {}
    for index = 1, 6 do
        local segment = CreateFrame("StatusBar", nil, rail)
        segment:SetSize(13, 8)
        segment:SetPoint("TOPLEFT", (index - 1) * 15, -14)
        segment:SetStatusBarTexture(app.Theme.media.combatFill)
        segment:SetMinMaxValues(0, 1)
        segment:SetValue(index > 2 and 1 or 0.35)
        segment.background = segment:CreateTexture(nil, "BACKGROUND")
        segment.background:SetAllPoints()
        local dark = app.Theme.colors.embedded
        segment.background:SetColorTexture(dark[1], dark[2], dark[3], 1)
        local accent = app.Theme:Accent()
        segment:SetStatusBarColor(index > 2 and accent[1] or accent[1] * 0.42,
            index > 2 and accent[2] or accent[2] * 0.42, index > 2 and accent[3] or accent[3] * 0.42, 1)
        rail.runes[index] = segment
    end
    local cast = CreateFrame("Frame", nil, stage, "BackdropTemplate")
    cast:SetPoint("TOPLEFT", 14, -46)
    cast:SetSize(220, 16)
    local dark = app.Theme.colors.embedded
    cast:SetBackdrop({ bgFile = app.Theme.media.panel, edgeFile = app.Theme.white,
        edgeSize = app.Pixel:Pixels(1, cast), insets = { left = 1, right = 1, top = 1, bottom = 1 } })
    cast:SetBackdropColor(dark[1] * 2.1, dark[2] * 2.1, dark[3] * 2.1, 0.94)
    local line = app.Theme.colors.line
    cast:SetBackdropBorderColor(line[1], line[2], line[3], 0.85)
    cast.fill = CreateFrame("StatusBar", nil, cast)
    cast.fill:SetPoint("TOPLEFT", 2, -2)
    cast.fill:SetPoint("BOTTOMRIGHT", -2, 2)
    cast.fill:SetStatusBarTexture(app.Theme.media.combatFill)
    cast.fill:SetMinMaxValues(0, 1)
    cast.fill:SetValue(0.42)
    local accent = app.Theme:Accent()
    cast.fill:SetStatusBarColor(accent[1], accent[2], accent[3], 1)
    cast.label = app.Theme:Text(cast, 10)
    cast.label:SetPoint("LEFT", 6, 0)
    cast.label:SetText(L.previewCastName)
    stage.rail, stage.cast = rail, cast
    -- Three pill buttons. They call the live component rather than drawing a
    -- second synthetic bar, so the preview and the real bar can never disagree.
    stage.buttons = {}
    for index, spec in ipairs({ { "cast", L.previewCast }, { "channel", L.previewChannel },
        { "empower", L.previewEmpower } }) do
        local button = app.Controls:Button(stage, spec[2], 86, function()
            local castComponent = app.components and app.components.playerCast
            if not castComponent or not castComponent.running then return end
            local current = castComponent.previewing
            if current == spec[1] then
                castComponent:StopPreview()
            else
                castComponent:StartPreview(spec[1])
            end
        end, { height = 20 })
        button:SetPoint("TOPLEFT", 14 + (index - 1) * 94, -68)
        stage.buttons[index] = button
    end
    return stage
end

-- Nameplates: two real `PlateView` plates, the left one a non-target enemy and
-- the right one the current target with a cast row. Exactly what the world draws,
-- including the target chip and the cast colours.
function Previews:Nameplates(parent)
    local stage = self:Stage(parent, 96, L.previewNameplates)
    local left = CreateFrame("Frame", nil, stage)
    left:SetPoint("TOPLEFT", 16, -30)
    local right = CreateFrame("Frame", nil, stage)
    right:SetPoint("TOPLEFT", 160, -30)
    stage.left = app.PlateView:Create(left)
    stage.right = app.PlateView:Create(right)
    stage.leftHost, stage.rightHost = left, right
    if stage.left then
        app.PlateView:SetName(stage.left, L.previewPlateEnemy)
        app.PlateView:SetHealth(stage.left, 42, 100)
        app.PlateView:SetTarget(stage.left, false)
        app.PlateView:SetColor(stage.left, app.Theme.colors.hostile)
    end
    if stage.right then
        app.PlateView:SetName(stage.right, L.previewPlateTarget)
        app.PlateView:SetHealth(stage.right, 76, 100)
        app.PlateView:SetTarget(stage.right, true)
        app.PlateView:SetColor(stage.right, app.Theme.colors.hostile)
        app.PlateView:SetCast(stage.right, { name = L.previewCastName, elapsed = 0.6, duration = 1.2,
            channel = false, interruptible = true })
    end
    function stage:Apply()
        local spec = app.Store:Profile().ui.nameplates or {}
        local leftWidth = spec.width or 112
        local targetWidth = spec.targetWidth or 124
        self.leftHost:SetSize(leftWidth, 40)
        self.rightHost:SetSize(targetWidth, 40)
        -- The frames themselves keep the renderer's own metrics; only the host
        -- rectangle changes here so the page shows the width difference at once.
        if self.left then self.left.frame:SetWidth(leftWidth) end
        if self.right then self.right.frame:SetWidth(targetWidth) end
    end
    return stage
end

-- One resolver the five pages share: the stage for a module id, laid out from the
-- stored options. A page that has no preview returns nil rather than an empty
-- plinth.
local BUILDERS = {
    cooldowns = "CooldownGroup",
    actionBars = "ActionBar",
    unitFrames = "UnitFrame",
    resources = "ResourceCast",
    nameplates = "Nameplates",
}

function Previews:For(pageID)
    return BUILDERS[pageID] and self[BUILDERS[pageID]] or nil
end

function Previews:Build(pageID, parent, height)
    local factory = self:For(pageID)
    if not factory then return nil end
    local stage = factory(self, parent)
    if height then stage:SetPreviewHeight(height) end
    return stage
end
