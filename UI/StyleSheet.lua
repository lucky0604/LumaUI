local _, app = ...
local StyleSheet = {}
app.StyleSheet = StyleSheet

-- One card that paints every surface role, type role, bar role and control state
-- side by side. Restyling real components before looking at this would be guessing:
-- the whole point is to compare the palette, the corners and the type scale against
-- a reference screenshot on a single frame, then decide numbers once.
local WIDTH, HEIGHT, PAD = 660, 580, 18
local COLUMNS = 3

local TILES = {
    { role = "card", label = "card" },
    { role = "raised", label = "raised" },
    { role = "inset", label = "inset" },
}

local TYPE_ROLES = { "display", "title", "body", "label", "micro" }

local BAR_EXAMPLES = {
    { color = { 0.30, 0.62, 0.95 }, value = 0.78 },
    { color = { 0.34, 0.80, 0.72 }, value = 0.52 },
    { color = { 0.92, 0.66, 0.32 }, value = 0.31 },
}

function StyleSheet:Create()
    if self.frame then return self.frame end
    local frame = CreateFrame("Frame", "LumaUIStyleSheet", UIParent)
    frame:SetSize(WIDTH, HEIGHT)
    frame:SetPoint("CENTER")
    frame:SetFrameStrata("DIALOG")
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function(self) self:StartMoving() end)
    frame:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
    app.Surface:Plate(frame, "card")
    self.frame = frame
    if type(UISpecialFrames) == "table" then table.insert(UISpecialFrames, "LumaUIStyleSheet") end
    -- Repaint on a profile change; Subscribe replaces the entry for this owner, so
    -- registering it once here is enough and cannot stack duplicates.
    app:Subscribe(self, "PROFILE_CHANGED", function() self:Paint() end)

    local title = app.Type:Text(frame, "display")
    title:SetPoint("TOPLEFT", PAD, -PAD)
    title:SetText(app.L.style)

    local close = app.Controls:Button(frame, "×", 24, function() self:Toggle(false) end, { height = 24, size = 14 })
    close:SetPoint("TOPRIGHT", -PAD, -PAD)

    local hint = app.Type:Text(frame, "micro")
    hint:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -4)
    hint:SetPoint("RIGHT", close, "LEFT", -12, 0)
    hint:SetText(app.L.styleHint)
    if type(hint.SetWordWrap) == "function" then hint:SetWordWrap(true) end

    -- Diagnostics: the two capabilities that decide how the build looks. If the
    -- slice is unavailable the cards are square and the user should know why
    -- instead of filing it as "the corner is broken".
    local diag = app.Type:Text(frame, "label")
    diag:SetPoint("TOPLEFT", hint, "BOTTOMLEFT", 0, -8)
    self.diag = diag

    local y = -104
    y = self:PaintSurfaces(frame, y)
    y = self:PaintType(frame, y)
    y = self:PaintBars(frame, y)
    y = self:PaintControls(frame, y)
    self:PaintCorners(frame, y)
    self:Paint()
    return frame
end

function StyleSheet:Heading(parent, y, text)
    local label = app.Type:Text(parent, "label")
    label:SetPoint("TOPLEFT", PAD, y)
    label:SetText(text)
    local rule = app.Surface:HLine(parent, 0.35)
    rule:SetPoint("LEFT", label, "RIGHT", 10, 0)
    rule:SetPoint("RIGHT", parent, "RIGHT", -PAD, 0)
    return y - 20
end

function StyleSheet:PaintSurfaces(frame, y)
    y = self:Heading(frame, y, app.L.styleSurface)
    local width = (WIDTH - (PAD * 2) - (12 * (COLUMNS - 1))) / COLUMNS
    self.tiles = {}
    for index, tile in ipairs(TILES) do
        local card = CreateFrame("Frame", nil, frame)
        card:SetSize(width, 62)
        card:SetPoint("TOPLEFT", PAD + (index - 1) * (width + 12), y)
        app.Surface:Plate(card, tile.role)
        self.tiles[index] = card
        local label = app.Type:Text(card, "micro")
        label:SetPoint("BOTTOMLEFT", 10, 8)
        label:SetText(tile.label)
    end
    return y - 62 - 18
end

function StyleSheet:PaintType(frame, y)
    y = self:Heading(frame, y, app.L.styleType)
    self.typeLines = {}
    for index, role in ipairs(TYPE_ROLES) do
        local row = y - (index - 1) * 21
        local tag = app.Type:Text(frame, "micro")
        tag:SetPoint("TOPLEFT", PAD, row)
        tag:SetText(role)
        local sample = app.Type:Text(frame, role)
        sample:SetPoint("LEFT", tag, "RIGHT", 58, 0)
        sample:SetText(app.L.styleMixed)
        self.typeLines[index] = sample
    end
    return y - (#TYPE_ROLES * 21) - 12
end

function StyleSheet:PaintBars(frame, y)
    y = self:Heading(frame, y, app.L.styleBars)
    self.bars = {}
    for index, example in ipairs(BAR_EXAMPLES) do
        local bar = app.Theme:Bar(frame, 8)
        bar:SetPoint("TOPLEFT", PAD, y - (index - 1) * 16)
        bar:SetPoint("RIGHT", frame, "RIGHT", -PAD - 70, 0)
        bar:SetMinMaxValues(0, 1)
        bar:SetValue(example.value)
        app.Surface:Track(bar, "inset")
        app.Theme:PaintBar(bar, example.color)
        self.bars[index] = bar
    end
    -- Clicking the last bar asks the client itself to ease toward the new value.
    -- Doing that here proves the native interpolation path the HUD is going to use,
    -- instead of shipping a Lua ticker and hoping it feels the same.
    local demo = self.bars[#BAR_EXAMPLES]
    if demo then
        demo:EnableMouse(true)
        local target = BAR_EXAMPLES[#BAR_EXAMPLES].value
        demo:SetScript("OnMouseUp", function()
            target = target > 0.6 and 0.3 or 0.9
            local eased = pcall(demo.SetValue, demo, target, "ExponentialEaseOut")
            if not eased then demo:SetValue(target) end
        end)
    end
    return y - (#BAR_EXAMPLES * 16) - 12
end

function StyleSheet:PaintControls(frame, y)
    y = self:Heading(frame, y, app.L.styleControls)
    -- Anchor to the previous button's TOPRIGHT, not its RIGHT: "RIGHT" resolves to
    -- the middle of that edge, so each button would sit half a row lower than the
    -- last and the row would cascade down the card.
    self.primary = self.primary or app.Controls:Button(frame, app.L.styleEmphasis, 116, nil, { kind = "primary" })
    self.primary:ClearAllPoints()
    self.primary:SetPoint("TOPLEFT", PAD, y)

    self.secondary = self.secondary or app.Controls:Button(frame, "secondary", 116, nil)
    self.secondary:ClearAllPoints()
    self.secondary:SetPoint("TOPLEFT", self.primary, "TOPRIGHT", 10, 0)

    self.disabled = self.disabled or app.Controls:Button(frame, "disabled", 116, nil)
    self.disabled:ClearAllPoints()
    self.disabled:SetPoint("TOPLEFT", self.secondary, "TOPRIGHT", 10, 0)
    self.disabled:SetEnabled(false)

    self.selected = self.selected or app.Controls:Button(frame, "selected", 116, nil)
    self.selected:ClearAllPoints()
    self.selected:SetPoint("TOPLEFT", self.disabled, "TOPRIGHT", 10, 0)
    self.selected:SetSelected(true)
    return y - 44
end

function StyleSheet:PaintCorners(frame, y)
    y = self:Heading(frame, y, app.L.styleRadius)
    -- Same corner radius at three different sizes. If a nine-slice margin is too
    -- small the small card is where it shows first, so the row is the cheapest
    -- visual regression test the panel offers.
    local widths, heights = { 140, 220, 230 }, { 44, 36, 30 }
    self.corners = {}
    local offset = 0
    for index, width in ipairs(widths) do
        local card = CreateFrame("Frame", nil, frame)
        card:SetSize(width, heights[index])
        card:SetPoint("TOPLEFT", PAD + offset, y)
        app.Surface:Plate(card, "inset")
        self.corners[index] = card
        offset = offset + width + 12
    end
end

-- The one-line capability summary. Shared by the panel's header and the slash
-- command so a rendering problem can never hide the answer to "does this client
-- accept our textures at all".
function StyleSheet:Describe()
    local diagnostics = app.Type:Diagnostics()
    local surface = app.Surface:Diagnostics()
    local slice = surface.slice and app.L.styleSliceOn or app.L.styleSliceOff
    local texture = surface.texture and app.L.styleTextureOn or app.L.styleTextureOff
    return string.format("%s: %s   ·   %s   ·   %s", app.L.styleFont, diagnostics.face, slice, texture)
end

-- Repaint everything that depends on the palette, the accent or the type scale.
function StyleSheet:Paint()
    if not self.frame then return end
    app.Surface:Refresh(self.frame)
    for _, card in ipairs(self.tiles or {}) do app.Surface:Refresh(card) end
    for _, card in ipairs(self.corners or {}) do app.Surface:Refresh(card) end
    for _, bar in ipairs(self.bars or {}) do app.Surface:Refresh(bar) end
    if self.diag then self.diag:SetText(self:Describe()) end
end

function StyleSheet:Toggle(show)
    local frame = self:Create()
    local wanted = show
    if wanted == nil then wanted = not frame:IsShown() end
    if wanted then
        frame:Show()
        self:Paint()
    else
        frame:Hide()
    end
    return frame
end
