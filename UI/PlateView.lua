local _, app = ...
local PlateView = {}
app.PlateView = PlateView

-- LumaUI's own nameplate layer. It is parented to the client's plate unit
-- frame, so world position, stacking, range fading and click selection stay the
-- client's; everything drawn inside is LumaUI's own StatusBar, text and cast
-- row. The layer never enables mouse, so the native plate keeps every click.
--
-- The view is deliberately size-driven by its own configuration instead of the
-- native bar: the whole point of 012 phase 04 is a narrow 116 x 8 track that no
-- longer inherits the client's bar metrics. When a native bar exists it is used
-- only as an anchor and, in takeover mode, as the hit target that stays intact.
--
-- Secret values never reach this file's arithmetic. `SetHealth` refuses a
-- restricted number and reports it, so the caller keeps the native drawing
-- instead of showing a bar that silently lies.

local HEALTH_WIDTH, HEALTH_HEIGHT = 116, 8
local NAME_HEIGHT = 12
local CAST_HEIGHT = 7
local CAST_GAP = 2
local TEXT_INSET = 3
local TARGET_CHIP = 14

function PlateView:Metrics()
    return { width = HEALTH_WIDTH, height = HEALTH_HEIGHT,
        name = NAME_HEIGHT, cast = CAST_HEIGHT, gap = CAST_GAP }
end

local function plainNumber(value)
    return app.Capabilities.Plain(value, "number")
end

local function plainText(value)
    return app.Capabilities.Plain(value, "string")
end

local function applyHealthColor(view, base)
    if not base then return end
    app.Theme:PaintCombatBar(view.health, base)
end

-- Builds one view under `parent`. `anchors.bar` is the client's health bar when
-- the build exposes one: the view lines its own track up with that bar without
-- reading its size. Without a bar the view centres itself on the unit frame.
function PlateView:Create(parent, anchors)
    if not parent or type(parent.CreateTexture) ~= "function" then return nil end
    local frame = CreateFrame("Frame", nil, parent)
    frame:EnableMouse(false)
    -- Cover the client's plate art instead of drawing a small bar inside it.
    -- The native plate's dark panel is wider/taller than its 8px track; leaving
    -- it visible made the own layer look like an untouched native plate with a
    -- small green strip. The frame takes the native unit frame's size when it is
    -- readable and paints its own opaque plate over it; the native frame stays
    -- the click/world host underneath.
    local anchorBar = anchors and anchors.bar
    local width = HEALTH_WIDTH
    local barHeight = HEALTH_HEIGHT
    if anchorBar and type(anchorBar.GetWidth) == "function" then
        local ok, value = pcall(anchorBar.GetWidth, anchorBar)
        value = ok and plainNumber(value) or nil
        if value and value > 0 then width = math.max(96, math.min(180, value)) end
    end
    if anchorBar and type(anchorBar.GetHeight) == "function" then
        local ok, value = pcall(anchorBar.GetHeight, anchorBar)
        value = ok and plainNumber(value) or nil
        if value and value > 0 then barHeight = math.max(4, math.min(16, value)) end
    end
    -- A cut-out overlay, on its own stratum above the client plate. The dark
    -- strips frame a transparent window over the native bar: the fill stays the
    -- client's (truthful even when restricted), the name sits on the top band,
    -- and nothing can be hidden behind the client's panel because this layer is
    -- above it. A full card would cover the fill; a small strip behind it stayed
    -- behind the panel (the repeated "no change" report).
    local TOP_H, BOTTOM_H = NAME_HEIGHT, 2
    if type(parent.GetWidth) == "function" then
        local ok, value = pcall(parent.GetWidth, parent)
        value = ok and plainNumber(value) or nil
        if value and value > width then width = math.max(96, math.min(200, value)) end
    end
    local height = TOP_H + barHeight + BOTTOM_H
    frame:SetSize(width, height)
    if type(frame.SetFrameStrata) == "function" then pcall(frame.SetFrameStrata, frame, "HIGH") end
    if anchorBar and type(frame.SetPoint) == "function" then
        frame:SetPoint("BOTTOM", anchorBar, "BOTTOM", 0, -BOTTOM_H)
    else
        frame:SetPoint("BOTTOM", parent, "BOTTOM", 0, 2)
    end
    if type(parent.GetFrameLevel) == "function" and type(frame.SetFrameLevel) == "function" then
        local ok, level = pcall(parent.GetFrameLevel, parent)
        level = ok and plainNumber(level) or nil
        if level then pcall(frame.SetFrameLevel, frame, level + 30) end
    end
    local surface = app.Theme.colors.surface
    frame.backdrop = frame:CreateTexture(nil, "BACKGROUND")
    frame.backdrop:SetPoint("TOPLEFT", 0, 0)
    frame.backdrop:SetPoint("TOPRIGHT", 0, 0)
    frame.backdrop:SetHeight(TOP_H)
    frame.backdrop:SetColorTexture(surface[1], surface[2], surface[3], 0.95)
    local bottomStrip = frame:CreateTexture(nil, "BACKGROUND")
    bottomStrip:SetPoint("BOTTOMLEFT", 0, 0)
    bottomStrip:SetPoint("BOTTOMRIGHT", 0, 0)
    bottomStrip:SetHeight(BOTTOM_H)
    bottomStrip:SetColorTexture(surface[1], surface[2], surface[3], 0.95)
    -- Side strips fill the width between the panel edge and the bar window.
    local windowWidth = anchorBar and select(2, pcall(anchorBar.GetWidth, anchorBar)) or nil
    windowWidth = plainNumber(windowWidth) or width
    windowWidth = math.max(20, math.min(width, windowWidth))
    side = (width - windowWidth) / 2
    if side > 0 then
        local left = frame:CreateTexture(nil, "BACKGROUND")
        left:SetPoint("BOTTOMLEFT", 0, BOTTOM_H)
        left:SetWidth(side)
        left:SetHeight(barHeight)
        left:SetColorTexture(surface[1], surface[2], surface[3], 0.95)
        local right = frame:CreateTexture(nil, "BACKGROUND")
        right:SetPoint("BOTTOMRIGHT", 0, BOTTOM_H)
        right:SetWidth(side)
        right:SetHeight(barHeight)
        right:SetColorTexture(surface[1], surface[2], surface[3], 0.95)
    end
    local rule = frame:CreateTexture(nil, "ARTWORK")
    rule:SetPoint("BOTTOMLEFT", frame.backdrop, "BOTTOMLEFT", 0, 0)
    rule:SetPoint("BOTTOMRIGHT", frame.backdrop, "BOTTOMRIGHT", 0, 0)
    rule:SetHeight(app.Pixel:Pixels(1, rule))
    local ruleColor = app.Theme.colors.line
    rule:SetColorTexture(ruleColor[1], ruleColor[2], ruleColor[3], 0.85)
    frame.edge = rule

    local health = CreateFrame("StatusBar", nil, frame)
    health:SetSize(windowWidth, HEALTH_HEIGHT)
    health:SetPoint("CENTER", frame, "BOTTOM", 0, BOTTOM_H + barHeight / 2)
    health:SetStatusBarTexture(app.Theme.media.combatFill)
    health:SetMinMaxValues(0, 1)
    health:SetValue(0)
    health.background = health:CreateTexture(nil, "BACKGROUND")
    health.background:SetAllPoints()
    local dim = app.Theme.colors.surface
    health.background:SetColorTexture(dim[1], dim[2], dim[3], 0.92)
    -- Tint over the native fill in restricted mode. The client resets its own
    -- bar texture/colour on updates, so writing those was overwritten; a tint
    -- above the fill is our texture and survives while keeping the true length.
    local tint = frame:CreateTexture(nil, "OVERLAY")
    tint:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", side, BOTTOM_H)
    tint:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -side, BOTTOM_H)
    tint:SetHeight(barHeight)
    tint:SetColorTexture(0, 0, 0, 0)
    tint:Hide()
    -- One hairline around the track: the same physical-pixel edge every other
    -- LumaUI control draws, so the plate reads as part of the suite.
    local edge = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    edge:EnableMouse(false)
    edge:SetPoint("TOPLEFT", health, "TOPLEFT", -1, 1)
    edge:SetPoint("BOTTOMRIGHT", health, "BOTTOMRIGHT", 1, -1)
    edge:SetBackdrop({ edgeFile = app.Theme.white, edgeSize = app.Pixel:Pixels(1, edge) })
    local line = app.Theme.colors.line
    edge:SetBackdropBorderColor(line[1], line[2], line[3], 0.9)

    local name = app.Theme:Text(frame, 10)
    name:SetPoint("CENTER", frame.backdrop, "CENTER", 0, 0)
    name:SetSize(width - 6, NAME_HEIGHT)
    name:SetJustifyH("CENTER")
    name:SetWordWrap(false)
    name:SetText("")

    -- A short right-aligned percentage on the track. It only ever receives a
    -- plain number computed outside; `SetHealth` hides it for restricted units.
    local value = app.Theme:Text(frame, 9)
    value:SetPoint("RIGHT", health, "RIGHT", -TEXT_INSET, 0)
    value:SetText("")

    -- Target selection: one warm-white chip above the track, away from the
    -- name so a long Chinese name is never covered.
    local chip = frame:CreateTexture(nil, "OVERLAY")
    chip:SetColorTexture(1, 0.97, 0.9, 0.95)
    chip:SetSize(TARGET_CHIP, 2)
    chip:SetPoint("BOTTOM", frame, "TOP", 0, 1)
    chip:Hide()

    local accent = frame:CreateTexture(nil, "OVERLAY")
    local color = app.Theme:Accent()
    accent:SetColorTexture(color[1], color[2], color[3], 0.85)
    accent:SetPoint("TOPLEFT", health, "TOPLEFT", -3, 2)
    accent:SetPoint("BOTTOMLEFT", health, "BOTTOMLEFT", -3, -2)
    accent:SetWidth(app.Pixel:Pixels(2, accent))

    -- Cast row: its own bar, own text and own duration values; it never mixes
    -- with the health update and only appears while a readable cast exists.
    local cast = CreateFrame("Frame", nil, frame)
    cast:SetSize(HEALTH_WIDTH, CAST_HEIGHT)
    cast:SetPoint("TOP", health, "BOTTOM", 0, -CAST_GAP)
    cast:Hide()
    local castBar = CreateFrame("StatusBar", nil, cast)
    castBar:SetAllPoints()
    castBar:SetStatusBarTexture(app.Theme.media.combatFill)
    castBar:SetMinMaxValues(0, 1)
    castBar:SetValue(0)
    local castBack = castBar:CreateTexture(nil, "BACKGROUND")
    castBack:SetAllPoints()
    local dark = app.Theme.colors.embedded
    castBack:SetColorTexture(dark[1], dark[2], dark[3], 0.9)
    local castText = app.Theme:Text(cast, 9)
    castText:SetPoint("CENTER", castBar, "CENTER", 0, 0)
    castText:SetSize(HEALTH_WIDTH - 8, CAST_HEIGHT)
    castText:SetJustifyH("CENTER")
    castText:SetWordWrap(false)

    local view = {
        frame = frame, health = health, name = name, value = value, tint = tint,
        chip = chip, accent = accent, edge = edge,
        cast = cast, castBar = castBar, castText = castText,
        parent = parent, anchors = anchors or {}, unit = nil,
        width = HEALTH_WIDTH, height = HEALTH_HEIGHT, trackHeight = height,
        chromeHeight = TOP_H + HEALTH_HEIGHT + BOTTOM_H,
    }
    frame.view = view
    -- The cast row is advanced by its owner's slow ticker (one per active
    -- cast), not an OnUpdate loop: an idle frame must not keep a per-frame
    -- handler alive after the cast ends.
    return view
end

-- Restricted-health mode: the client keeps drawing the fill, so the own track
-- and its dark plate stay hidden; only the parts that need no health value are
-- drawn (name, target chip). This still changes the plate's typography and
-- leaves the native bar as the truthful source. `ShowTrack` restores the full
-- layer when readable health comes back.
function PlateView:SetChrome(view, text, isTarget)
    if not view then return false end
    view.health:Hide()
    view.value:Hide()
    view.edge:Hide()
    view.accent:Hide()
    view.cast:Hide()
    -- The strips are the plate; only the numeric track and its decorations go.
    -- The cut-out window keeps showing the native fill.
    if view.plate then view.plate:Show() end
    if view.chromeHeight then view.frame:SetHeight(view.chromeHeight) end
    view.frame:Show()
    local named = self:SetName(view, text)
    self:SetTarget(view, isTarget == true)
    return named
end

function PlateView:ShowTrack(view)
    if not view then return end
    if view.trackHeight then view.frame:SetHeight(view.trackHeight) end
    if view.plate then view.plate:Show() end
    if view.frame.backdrop then view.frame.backdrop:Show() end
    if view.frame.edge then view.frame.edge:Show() end
    view.health:Show()
    view.edge:Show()
    view.accent:Show()
    view.value:Show()
    if view.tint then view.tint:Hide() end
end

function PlateView:SetUnit(view, unit)
    if not view then return end
    view.unit = unit
    applyHealthColor(view, app.Theme:UnitColor(unit))
end

-- Both numbers must be readable plain values. A restricted unit keeps the
-- native bar: the caller sees `false` and leaves its own layer hidden for that
-- update instead of freezing a stale value on screen.
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
    return true
end

function PlateView:SetName(view, text)
    if not view then return end
    text = plainText(text)
    if not text then
        view.name:SetText("")
        return false
    end
    -- The plate is narrow by design: a long name is cut with a plain ellipsis
    -- rather than widening the bar or shrinking the text below 9.
    if #text > 22 then text = text:sub(1, 21) .. "…" end
    view.name:SetText(text)
    return true
end

function PlateView:SetTarget(view, isTarget)
    if not view then return end
    if isTarget then view.chip:Show() else view.chip:Hide() end
end

function PlateView:SetColor(view, base)
    if view and base then applyHealthColor(view, base) end
end

-- A translucent tint above the native fill (restricted health). `tint` is
-- { r, g, b, a }; nil hides it. It never reads or writes the health value.
function PlateView:SetTint(view, tint)
    if not view or not view.tint then return end
    if tint then
        view.tint:SetColorTexture(tint[1], tint[2], tint[3], tint[4] or 0.42)
        view.tint:Show()
    else
        view.tint:Hide()
    end
end

local CAST_COLORS = {
    normal = { 0.92, 0.78, 0.45 },
    channel = { 0.42, 0.72, 0.95 },
    interruptible = { 0.95, 0.55, 0.30 },
    uninterruptible = { 0.58, 0.58, 0.62 },
}

-- `state` carries only plain values: { name, elapsed, duration, channel,
-- interruptible }. Unreadable numbers clear the row and the caller keeps the
-- native cast bar. The bar uses its own min/max so a channel fills backwards
-- without any Lua arithmetic on the value the client reports.
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
    if #label > 18 then label = label:sub(1, 17) .. "…" end
    view.castText:SetText(label)
    view.cast:Show()
    return true
end

function PlateView:ClearCast(view)
    if not view then return end
    view.castStart, view.castDuration = nil, nil
    view.castText:SetText("")
    view.cast:Hide()
end

function PlateView:Release(plate)
    if not plate then return end
    local view = plate.lumaPlateView
    if not view then return end
    plate.lumaPlateView = nil
    if view.plate then view.plate:Hide() end
    if view.frame then view.frame:Hide() end
end
