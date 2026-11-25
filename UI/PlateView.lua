local _, app = ...
local PlateView = {}
app.PlateView = PlateView

-- LumaUI's own nameplate layer (013 geometry). One production renderer serves
-- both the live plates and the `/luma style` sample, so what the card shows is
-- what the world draws.
--
-- The layer is parented to the client's plate unit frame, so world position,
-- stacking, range fading and click selection stay the client's. It never
-- enables the mouse. Its size comes only from SPEC below: the native bar is an
-- anchor point and nothing else, so a client bar that is 525 px wide cannot make
-- this track wide, and a restricted size is never read.
--
-- Rows, top to bottom: name (left) and percentage (right) on one text row, a
-- short gap, the health track, then the optional cast row. A target gets a
-- slightly larger track and one short warm-white chip on the track's top edge,
-- never a full frame.
--
-- Restricted health is drawn without being read: `DrawUnit` hands the unit's
-- health and maximum to the layer's own StatusBar, whose SetMinMaxValues /
-- SetValue accept restricted numbers, and the percentage goes through
-- UnitHealthPercent into SetFormattedText. Nothing here compares, adds,
-- formats or stores those values.

local SPEC = {
    width = 112, height = 7,
    targetWidth = 120, targetHeight = 8,
    nameHeight = 12, nameGap = 3,
    valueReserve = 30,
    cast = 7, castGap = 2,
    chip = 14,
    nameColumns = 22,
}
PlateView.Spec = SPEC

function PlateView:Metrics()
    return { width = SPEC.width, height = SPEC.height,
        targetWidth = SPEC.targetWidth, targetHeight = SPEC.targetHeight,
        name = SPEC.nameHeight, cast = SPEC.cast, gap = SPEC.castGap }
end

local function plainNumber(value)
    return app.Capabilities.Plain(value, "number")
end

local function plainText(value)
    return app.Capabilities.Plain(value, "string")
end

-- Visible width in "columns": one for ASCII, two for a CJK or other multi-byte
-- character. A byte count would cut a Chinese name at a third of the room.
local function clip(text, columns)
    local used, index, length = 0, 1, #text
    while index <= length do
        local byte = text:byte(index)
        local step, weight = 1, 1
        if byte >= 0xF0 then step, weight = 4, 2
        elseif byte >= 0xE0 then step, weight = 3, 2
        elseif byte >= 0xC0 then step, weight = 2, 1 end
        if used + weight > columns then
            return text:sub(1, index - 1) .. "…"
        end
        used = used + weight
        index = index + step
    end
    return text
end
PlateView.Clip = clip

-- Draws the unit's health into `health` without reading it. Kept at file scope
-- and called through pcall: a client that refuses either call must not escape.
local function drawHealth(health, unit)
    health:SetMinMaxValues(0, UnitHealthMax(unit))
    health:SetValue(UnitHealth(unit))
end

-- The percentage goes from UnitHealthPercent into SetFormattedText. A plain
-- result is as welcome as a restricted one; only a missing API or a refused call
-- leaves the text empty.
local function drawPercent(control, unit)
    if type(UnitHealthPercent) ~= "function" then return "none" end
    local curve = type(CurveConstants) == "table" and CurveConstants.ScaleTo100 or nil
    local ok, percent = pcall(UnitHealthPercent, unit, true, curve)
    if not ok then return "none" end
    if not app.Capabilities.IsSecret(percent) and percent == nil then return "none" end
    if not pcall(control.SetFormattedText, control, "%.0f%%", percent) then return "none" end
    return "api"
end

local function applyColor(view, base)
    if not base then return end
    view.baseColor = { base[1], base[2], base[3] }
    app.Theme:PaintMatteBar(view.health, base)
end

-- Track size follows the target state. The frame is the track plus the name row
-- above it; the cast row hangs below and is not part of the frame's height.
local function layout(view, isTarget)
    local width = isTarget and SPEC.targetWidth or SPEC.width
    local height = isTarget and SPEC.targetHeight or SPEC.height
    if view.laidOutTarget == isTarget then return end
    view.laidOutTarget = isTarget
    view.width, view.height = width, height
    view.frame:SetSize(width, SPEC.nameHeight + SPEC.nameGap + height)
    view.health:SetSize(width, height)
    view.name:SetWidth(width - SPEC.valueReserve)
    view.cast:SetSize(width, SPEC.cast)
    view.castText:SetWidth(width - 8)
end

-- Builds one view under `parent`. `anchors.bar` is the client's health bar when
-- the build exposes one: it is the anchor point and its size is not read.
function PlateView:Create(parent, anchors)
    if not parent or type(parent.CreateTexture) ~= "function" then return nil end
    local frame = CreateFrame("Frame", nil, parent)
    frame:EnableMouse(false)
    frame:SetSize(SPEC.width, SPEC.nameHeight + SPEC.nameGap + SPEC.height)
    local anchorBar = anchors and anchors.bar
    if anchorBar then
        frame:SetPoint("BOTTOM", anchorBar, "BOTTOM", 0, 0)
    else
        frame:SetPoint("BOTTOM", parent, "BOTTOM", 0, 2)
    end
    -- Above the client's own plate art in the same strata: no strata jump, so the
    -- layer never leaps over other UI.
    if type(parent.GetFrameLevel) == "function" and type(frame.SetFrameLevel) == "function" then
        local ok, level = pcall(parent.GetFrameLevel, parent)
        level = ok and plainNumber(level) or nil
        if level then pcall(frame.SetFrameLevel, frame, level + 30) end
    end

    local health = CreateFrame("StatusBar", nil, frame)
    health:SetSize(SPEC.width, SPEC.height)
    health:SetPoint("BOTTOM", frame, "BOTTOM", 0, 0)
    health:SetStatusBarTexture(app.Theme.media.combatFill)
    health:SetMinMaxValues(0, 1)
    health:SetValue(0)
    health.background = health:CreateTexture(nil, "BACKGROUND")
    health.background:SetAllPoints()
    local rail = app.Theme.matte.rail
    health.background:SetColorTexture(rail[1], rail[2], rail[3], rail[4])

    -- One physical-pixel hairline around the track, the edge every other LumaUI
    -- control draws.
    local edge = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    edge:EnableMouse(false)
    edge:SetPoint("TOPLEFT", health, "TOPLEFT", -1, 1)
    edge:SetPoint("BOTTOMRIGHT", health, "BOTTOMRIGHT", 1, -1)
    edge:SetBackdrop({ edgeFile = app.Theme.white, edgeSize = app.Pixel:Pixels(1, edge) })
    local line = app.Theme.colors.line
    edge:SetBackdropBorderColor(line[1], line[2], line[3], 0.9)

    -- Name row. The name takes the left side and stops short of the value column,
    -- so a long Chinese name is cut before it can touch the percentage.
    local name = app.Theme:Text(frame, 10)
    name:SetPoint("BOTTOMLEFT", health, "TOPLEFT", 0, SPEC.nameGap)
    name:SetSize(SPEC.width - SPEC.valueReserve, SPEC.nameHeight)
    name:SetJustifyH("LEFT")
    name:SetWordWrap(false)
    name:SetText("")
    if type(name.SetShadowOffset) == "function" then pcall(name.SetShadowOffset, name, 1, -1) end

    local value = app.Theme:Text(frame, 9)
    value:SetPoint("BOTTOMRIGHT", health, "TOPRIGHT", 0, SPEC.nameGap)
    value:SetSize(SPEC.valueReserve, SPEC.nameHeight)
    value:SetJustifyH("RIGHT")
    value:SetWordWrap(false)
    value:SetText("")
    if type(value.SetShadowOffset) == "function" then pcall(value.SetShadowOffset, value, 1, -1) end

    -- Target selection: one short warm-white chip on the track's top edge.
    local chip = frame:CreateTexture(nil, "OVERLAY")
    local mark = app.Theme.colors.text
    chip:SetColorTexture(mark[1], mark[2], mark[3], 0.98)
    chip:SetSize(SPEC.chip, 2)
    chip:SetPoint("BOTTOMLEFT", health, "TOPLEFT", 0, 0)
    chip:Hide()

    -- Cast row: its own bar, own text and own duration values; it never mixes
    -- with the health update and only appears while a readable cast exists.
    local cast = CreateFrame("Frame", nil, frame)
    cast:SetSize(SPEC.width, SPEC.cast)
    cast:SetPoint("TOP", health, "BOTTOM", 0, -SPEC.castGap)
    cast:Hide()
    local castBar = CreateFrame("StatusBar", nil, cast)
    castBar:SetAllPoints()
    castBar:SetStatusBarTexture(app.Theme.media.combatFill)
    castBar:SetMinMaxValues(0, 1)
    castBar:SetValue(0)
    local castBack = castBar:CreateTexture(nil, "BACKGROUND")
    castBack:SetAllPoints()
    castBack:SetColorTexture(rail[1], rail[2], rail[3], rail[4])
    local castText = app.Theme:Text(cast, 9)
    castText:SetPoint("CENTER", castBar, "CENTER", 0, 0)
    castText:SetSize(SPEC.width - 8, SPEC.cast)
    castText:SetJustifyH("CENTER")
    castText:SetWordWrap(false)

    local view = {
        frame = frame, health = health, name = name, value = value,
        chip = chip, edge = edge,
        cast = cast, castBar = castBar, castText = castText,
        parent = parent, anchors = anchors or {}, unit = nil,
        width = SPEC.width, height = SPEC.height, laidOutTarget = false,
    }
    frame.view = view
    return view
end

-- Shows the track and its edge again after a hidden period. Idempotent.
function PlateView:ShowTrack(view)
    if not view then return end
    view.health:Show()
    view.edge:Show()
    view.value:Show()
end

function PlateView:SetUnit(view, unit)
    if not view then return end
    view.unit = unit
    applyColor(view, app.Theme:UnitColor(unit))
end

-- Draws a live unit. Returns true plus the percentage source when the track
-- accepted the values, false plus a reason otherwise. A failure leaves the
-- caller to keep the client's own drawing for this plate.
function PlateView:DrawUnit(view, unit)
    if not view then return false, "no-view" end
    if type(UnitHealth) ~= "function" or type(UnitHealthMax) ~= "function" then
        return false, "no-api"
    end
    if not pcall(drawHealth, view.health, unit) then
        view.value:SetText("")
        return false, "write-failed"
    end
    -- A readable pair gives the exact percentage with no API dependence; a
    -- restricted pair goes through UnitHealthPercent into SetFormattedText.
    local okValue, value = pcall(UnitHealth, unit)
    local okMax, maximum = pcall(UnitHealthMax, unit)
    value = okValue and plainNumber(value) or nil
    maximum = okMax and plainNumber(maximum) or nil
    if value and maximum and maximum > 0 then
        if value < 0 then value = 0 elseif value > maximum then value = maximum end
        view.value:SetText(string.format("%d%%", math.floor(value / maximum * 100 + 0.5)))
        view.percentSource = "plain"
    else
        view.percentSource = drawPercent(view.value, unit)
        if view.percentSource == "none" then view.value:SetText("") end
    end
    return true, view.percentSource
end

-- Plain-number drawing for sample data (`/luma style`) and for tests. A
-- restricted number is refused and reported instead of being used.
function PlateView:SetHealth(view, value, maximum)
    if not view then return false end
    value, maximum = plainNumber(value), plainNumber(maximum)
    if value == nil or maximum == nil or maximum <= 0 then
        view.value:SetText("")
        return false
    end
    if value < 0 then value = 0 elseif value > maximum then value = maximum end
    view.health:SetMinMaxValues(0, maximum)
    view.health:SetValue(value)
    view.value:SetText(string.format("%d%%", math.floor(value / maximum * 100 + 0.5)))
    view.value:Show()
    view.percentSource = "plain"
    return true
end

function PlateView:SetName(view, text)
    if not view then return end
    text = plainText(text)
    if not text or text == "" then
        view.name:SetText("")
        return false
    end
    view.name:SetText(clip(text, SPEC.nameColumns))
    return true
end

function PlateView:SetTarget(view, isTarget)
    if not view then return end
    isTarget = isTarget == true
    layout(view, isTarget)
    if isTarget then view.chip:Show() else view.chip:Hide() end
end

function PlateView:SetColor(view, base)
    if view and base then applyColor(view, base) end
end

local CAST_COLORS = {
    normal = { 0.92, 0.78, 0.45 },
    channel = { 0.42, 0.72, 0.95 },
    interruptible = { 0.95, 0.55, 0.30 },
    uninterruptible = { 0.58, 0.58, 0.62 },
}

-- `state` carries only plain values: { name, elapsed, duration, channel,
-- interruptible }. Unreadable numbers clear the row and the caller keeps the
-- native cast bar.
function PlateView:SetCast(view, state)
    if not view then return false end
    if type(state) ~= "table" then self:ClearCast(view); return false end
    local elapsed, duration = plainNumber(state.elapsed), plainNumber(state.duration)
    if not elapsed or not duration or duration <= 0 then
        self:ClearCast(view)
        return false
    end
    local key = state.channel and "channel" or (state.interruptible == false and "uninterruptible" or "interruptible")
    local color = CAST_COLORS[key]
    view.castBar:SetStatusBarColor(color[1], color[2], color[3], 1)
    view.castBar:SetMinMaxValues(0, duration)
    view.castBar:SetValue(elapsed)
    local label = plainText(state.name) or ""
    view.castText:SetText(clip(label, 18))
    view.cast:Show()
    return true
end

function PlateView:ClearCast(view)
    if not view then return end
    view.castStart, view.castDuration = nil, nil
    view.castText:SetText("")
    view.cast:Hide()
end

-- Back to a clean, hidden state: used when a plate is released or recycled, so
-- the next unit never inherits this one's text, fill or chip.
function PlateView:Reset(view)
    if not view then return end
    self:ClearCast(view)
    view.name:SetText("")
    view.value:SetText("")
    view.chip:Hide()
    view.unit = nil
    view.percentSource = nil
    view.frame:Hide()
end

function PlateView:Release(plate)
    if not plate then return end
    local view = plate.lumaPlateView
    if not view then return end
    plate.lumaPlateView = nil
    self:Reset(view)
end
