local _, app = ...
local Cell = {}
app.PearlCell = Cell

-- One reusable icon cell for every LumaUI surface that shows a spell or an
-- item: cooldown groups, the action-bar sample and the style card. It owns a
-- dark base, a cropped icon, one physical-pixel edge, a client Cooldown swipe,
-- count and time text and a state ring. It never handles mouse input, so the
-- secure button that hosts it keeps every click; and it never accepts a secret
-- value: SetCooldown refuses restricted numbers and returns false, which lets
-- the caller keep the native drawing.
--
-- States are separated by shape as well as colour so they stay readable with
-- motion reduced: ready (no ring), tracking (accent ring), selected (warm white
-- ring), unavailable (dim icon, no ring glow), proc (thicker accent ring).

local PAD = 2
local SIZE = 26

local STATE_COLORS = {
    ready = nil,
    tracking = "accent",
    selected = "text",
    proc = "accent",
}

local function plainNumber(value)
    return app.Capabilities.Plain(value, "number")
end

local function plainText(value)
    return app.Capabilities.Plain(value, "string")
end

function Cell:Create(parent, size)
    size = plainNumber(size) or SIZE
    if size < 12 then size = 12 end
    local frame = CreateFrame("Frame", nil, parent)
    frame:SetSize(size, size)
    frame:EnableMouse(false)
    frame.size = size

    local base = frame:CreateTexture(nil, "BACKGROUND")
    base:SetAllPoints()
    local embedded = app.Theme.colors.embedded
    base:SetColorTexture(embedded[1] * 1.6, embedded[2] * 1.6, embedded[3] * 1.6, 1)

    local icon = frame:CreateTexture(nil, "ARTWORK")
    icon:SetPoint("TOPLEFT", PAD, -PAD)
    icon:SetPoint("BOTTOMRIGHT", -PAD, PAD)
    -- A small crop removes the client's own icon border without scaling it.
    icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    icon:Hide()

    local edge = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    edge:EnableMouse(false)
    edge:SetAllPoints()
    edge:SetBackdrop({ edgeFile = app.Theme.white, edgeSize = app.Pixel:Pixels(1, edge) })
    local line = app.Theme.colors.line
    edge:SetBackdropBorderColor(line[1], line[2], line[3], 0.85)

    -- Client-drawn sweep: the countdown is the same object the native action
    -- button uses, so no Lua ticker runs for it.
    local swipe = CreateFrame("Cooldown", nil, frame, "CooldownFrameTemplate")
    swipe:SetAllPoints(icon)
    -- The edge belongs to LumaUI; the client's own rim would double it.
    if type(swipe.SetDrawEdge) == "function" then pcall(swipe.SetDrawEdge, swipe, false) end

    local count = app.Theme:Text(frame, 10)
    count:SetPoint("BOTTOMRIGHT", -PAD - 1, PAD + 1)
    count:SetText("")

    local time = app.Theme:Text(frame, 10)
    time:SetPoint("CENTER")
    time:SetText("")

    local ring = frame:CreateTexture(nil, "OVERLAY")
    ring:SetPoint("TOPLEFT", -1, 1)
    ring:SetPoint("BOTTOMRIGHT", 1, -1)
    ring:SetColorTexture(1, 1, 1, 0)
    ring:Hide()

    frame.base, frame.icon, frame.edge, frame.swipe = base, icon, edge, swipe
    frame.count, frame.time, frame.ring = count, time, ring
    return frame
end

function Cell:SetIcon(cell, texture)
    if not cell then return false end
    texture = plainText(texture)
    if not texture then
        cell.icon:Hide()
        return false
    end
    cell.icon:SetTexture(texture)
    cell.icon:Show()
    return true
end

function Cell:SetCount(cell, count)
    if not cell then return end
    count = plainNumber(count)
    if not count or count <= 1 then
        cell.count:SetText("")
        return
    end
    cell.count:SetText(tostring(math.floor(count)))
end

-- `remaining` is seconds. The text is coarse on purpose: a cooldown cell shows
-- minutes above 60 and whole seconds below, which keeps the 10px label legible.
function Cell:SetTime(cell, remaining)
    if not cell then return end
    remaining = plainNumber(remaining)
    if not remaining or remaining <= 0 then
        cell.time:SetText("")
        return
    end
    if remaining >= 60 then
        cell.time:SetFormattedText("%d:%02d", math.floor(remaining / 60), math.floor(remaining % 60))
    elseif remaining >= 10 then
        cell.time:SetFormattedText("%d", math.floor(remaining))
    else
        cell.time:SetFormattedText("%.1f", remaining)
    end
end

-- Times are plain numbers by contract. A restricted start or duration keeps
-- the client's own swipe/timer and the own cell simply shows no sweep.
function Cell:SetCooldown(cell, start, duration)
    if not cell then return false end
    start, duration = plainNumber(start), plainNumber(duration)
    if not start or not duration or duration <= 0 then
        if type(cell.swipe.Clear) == "function" then pcall(cell.swipe.Clear, cell.swipe) end
        return false
    end
    pcall(cell.swipe.SetCooldown, cell.swipe, start, duration)
    return true
end

function Cell:Clear(cell)
    if not cell then return end
    cell.icon:Hide()
    cell.icon:SetTexture(nil)
    cell.count:SetText("")
    cell.time:SetText("")
    cell.ring:Hide()
    if type(cell.swipe.Clear) == "function" then pcall(cell.swipe.Clear, cell.swipe) end
    cell.state = nil
end

function Cell:SetState(cell, state)
    if not cell then return end
    cell.state = state
    local token = STATE_COLORS[state]
    if not token then
        cell.ring:Hide()
        cell.icon:SetDesaturated(false)
        cell.icon:SetAlpha(1)
        return
    end
    local color = token == "accent" and app.Theme:Accent() or app.Theme.colors[token]
    cell.ring:SetColorTexture(color[1], color[2], color[3], state == "proc" and 0.95 or 0.65)
    cell.ring:Show()
    -- "unavailable" also loses saturation: colour alone is not a cue.
    cell.icon:SetDesaturated(state == "unavailable")
    cell.icon:SetAlpha(state == "unavailable" and 0.55 or 1)
end

-- Writes the visible role of one cell from a plain descriptor. The descriptor
-- is LumaUI's own data (`icon`, `count`, `remaining`, `state`); a caller with a
-- restricted value leaves that field out and the cell keeps its previous text.
function Cell:Apply(cell, data)
    if not cell or type(data) ~= "table" then return false end
    if data.empty then
        self:Clear(cell)
        return true
    end
    self:SetIcon(cell, data.icon)
    self:SetCount(cell, data.count)
    self:SetTime(cell, data.remaining)
    if data.start and data.duration then
        self:SetCooldown(cell, data.start, data.duration)
    elseif data.remaining == nil then
        self:SetCooldown(cell, nil, nil)
    end
    self:SetState(cell, data.state or "ready")
    return true
end
