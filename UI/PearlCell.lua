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
-- 019: the countdown is the one number a player reads mid-fight, so it gets its
-- own size and an outline instead of the shared 10 px body font. 15 reads
-- cleanly on a 26 px icon without touching the frame edge.
local COUNT_SIZE, TIME_SIZE = 11, 15

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

-- The stored view options, read on every paint. A cell therefore follows a
-- settings change without being rebuilt, and a profile switch reaches cells that
-- were created in an earlier session. A missing profile (early load) falls back
-- to the shipped defaults.
function Cell:Options()
    local profile = app.Store and app.Store:Profile()
    local ui = profile and profile.ui
    return (ui and ui.cooldownViews) or { countdownSize = TIME_SIZE, borderSize = 1,
        showSwipe = true, showProcGlow = true, desaturateUnusable = true }
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
    if type(swipe.SetHideCountdownNumbers) == "function" then
        pcall(swipe.SetHideCountdownNumbers, swipe, true)
    end

    -- Count and timer must live above the swipe. A child frame draws over its
    -- parent's own regions, so FontStrings created on `frame` sat under the dark
    -- sweep: the number was only readable where the wipe happened to uncover it,
    -- which read as "no cooldown timer at all".
    local overlay = CreateFrame("Frame", nil, frame)
    overlay:EnableMouse(false)
    overlay:SetAllPoints()
    overlay:SetFrameLevel((swipe:GetFrameLevel() or frame:GetFrameLevel() or 0) + 3)

    local count = app.Theme:Text(overlay, COUNT_SIZE)
    count:SetPoint("BOTTOMRIGHT", -PAD - 1, PAD + 1)
    count:SetText("")

    -- The timer is the readable number, so it gets the outline face and the
    -- warm-white ink: a plain body-size string on top of a dark sweep is what
    -- made the countdown look "missing" in the field screenshots.
    local time = app.Theme:Text(overlay, TIME_SIZE)
    time:SetPoint("CENTER")
    time:SetText("")
    if type(time.SetFont) == "function" then
        local font = app.Type and app.Type:Face() or GameFontNormal:GetFont()
        pcall(time.SetFont, time, font, TIME_SIZE, "OUTLINE")
    end
    if type(time.SetTextColor) == "function" then
        local warm = app.Theme.colors.pearl
        time:SetTextColor(warm[1], warm[2], warm[3], 1)
    end

    -- State edge, not a state fill: a backdrop hairline just outside the icon.
    -- A full-cell colour texture here painted a solid slab over the icon, the
    -- count and the timer for every tracked cooldown, so the state read as a
    -- rectangle instead of an outline. `proc` only thickens the same hairline.
    local ring = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    ring:EnableMouse(false)
    ring:SetPoint("TOPLEFT", -1, 1)
    ring:SetPoint("BOTTOMRIGHT", 1, -1)
    ring:SetBackdrop({ edgeFile = app.Theme.white, edgeSize = app.Pixel:Pixels(1, ring) })
    ring:SetBackdropBorderColor(1, 1, 1, 0)
    ring:Hide()

    frame.base, frame.icon, frame.edge, frame.swipe = base, icon, edge, swipe
    frame.count, frame.time, frame.ring = count, time, ring
    return frame
end

-- A texture is either a path (an item icon) or a raw fileID (a spell icon).
-- FileID is what the client's own buttons pass: it cannot break when an icon
-- moves between interface directories.
function Cell:SetIcon(cell, texture)
    if not cell then return false end
    local asset = plainText(texture) or plainNumber(texture)
    if not asset then
        cell.icon:Hide()
        return false
    end
    cell.icon:SetTexture(asset)
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
-- minutes above 60 and whole seconds below. The size is the stored countdown
-- size, so a player who needs bigger numbers can raise it without the whole HUD
-- changing scale.
function Cell:SetTime(cell, remaining)
    if not cell then return end
    local options = self:Options()
    local size = plainNumber(options.countdownSize) or TIME_SIZE
    if cell.lumaTimeSize ~= size and type(cell.time.SetFont) == "function" then
        cell.lumaTimeSize = size
        local font = app.Type and app.Type:Face() or GameFontNormal:GetFont()
        pcall(cell.time.SetFont, cell.time, font, size, "OUTLINE")
    end
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
    local options = self:Options()
    if options.showSwipe == false then
        if type(cell.swipe.Clear) == "function" then pcall(cell.swipe.Clear, cell.swipe) end
        return false
    end
    start, duration = plainNumber(start), plainNumber(duration)
    if not start or not duration or duration <= 0 then
        if type(cell.swipe.Clear) == "function" then pcall(cell.swipe.Clear, cell.swipe) end
        return false
    end
    pcall(cell.swipe.SetCooldown, cell.swipe, start, duration)
    return true
end

-- A client duration object handed to the widget's own supported entry point.
-- The object is passed as-is (never decomposed into start/end), and a build
-- without the method returns false so the caller can keep plain numbers.
function Cell:SetDuration(cell, duration)
    if not cell or duration == nil then return false end
    -- `SetCooldownFromDurationObject` is documented as a protected function with
    -- `SecretArguments = AllowedWhenUntainted`. LumaUI's cells are not secure
    -- frames, but the conservative rule is the same as everywhere else: only
    -- hand the object over outside combat, otherwise keep the plain numbers.
    if type(InCombatLockdown) == "function" and InCombatLockdown() then return false end
    local swipe = cell.swipe
    if not swipe or type(swipe.SetCooldownFromDurationObject) ~= "function" then return false end
    local ok, result = pcall(swipe.SetCooldownFromDurationObject, swipe, duration, true)
    return ok and result ~= false
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
    cell.lumaState = nil
    -- The caller's own bookkeeping goes with the drawing: a cell that no longer
    -- shows a spell must not keep reporting a remaining time, or the shared
    -- cooldown ticker would run for it forever.
    cell.lumaRemaining = nil
    cell.lumaSpellID = nil
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
    local options = self:Options()
    -- Proc is a thicker outline of the same accent, so the cue survives both a
    -- colour-blind player and a reduced-motion session. The stored border width
    -- is a floor: a proc still earns one extra pixel, because the shape is the
    -- cue that survives a monochrome screen.
    local baseWidth = plainNumber(options.borderSize) or 1
    local thickness = (state == "proc" and baseWidth + 1) or baseWidth
    if cell.ringThickness ~= thickness then
        cell.ringThickness = thickness
        cell.ring:SetBackdrop({ edgeFile = app.Theme.white, edgeSize = app.Pixel:Pixels(thickness, cell.ring) })
    end
    -- The proc glow is an explicit switch: a player who reads the icon art better
    -- than the ring can turn the extra emphasis off without losing the outline.
    if state == "proc" and options.showProcGlow == false then
        cell.ring:Hide()
    else
        cell.ring:SetBackdropBorderColor(color[1], color[2], color[3], state == "proc" and 0.95 or 0.65)
        cell.ring:Show()
    end
    -- "unavailable" also loses saturation: colour alone is not a cue. The switch
    -- keeps a dimmed alpha either way, so the state never reads as "ready".
    local fade = options.desaturateUnusable ~= false
    cell.icon:SetDesaturated(state == "unavailable" and fade)
    cell.icon:SetAlpha(state == "unavailable" and 0.55 or 1)
    -- A proc earns one short scale pulse on the way in. It is a transition on the
    -- cell's own frame, so six proccing cells do not share a driver and an idle
    -- cell never animates. Only the arrival animates: the renderer repaints every
    -- cell on every beat, and a pulse per repaint would be a permanent jitter.
    if state == "proc" and cell.lumaState ~= "proc" and app.Transitions then
        app.Transitions:Bump(cell, cell, 1.08)
    end
    cell.lumaState = state
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
    if data.durationObject and self:SetDuration(cell, data.durationObject) then
        -- The client draws the sweep from its own object.
    elseif data.start and data.duration then
        self:SetCooldown(cell, data.start, data.duration)
    elseif data.remaining == nil then
        self:SetCooldown(cell, nil, nil)
    end
    self:SetState(cell, data.state or "ready")
    return true
end
