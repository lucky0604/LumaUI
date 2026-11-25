local _, app = ...

-- Nameplate styling, first pass: the target's nameplate health bar gets the
-- LumaUI gradient fill. Nothing else is touched — no pooling, no unit binding,
-- no friendly/enemy logic, no reading of health values. The game keeps
-- ownership of the nameplate and we only repaint one bar it already draws.
--
-- Why only the target plate: nameplates are restricted objects in instances
-- (friendly nameplates cannot be manipulated), and the target plate is the one
-- unit whose identity is always public. Starting there keeps the component
-- safe by construction, and the scope can grow once this is verified in game.
--
-- Bar lookup follows the client's real frame shape. Retail's name plate unit
-- frame nests the bar under `HealthBarsContainer`; older builds and several
-- test doubles expose it directly on `UnitFrame`. The modern field wins, the
-- legacy field is only tried when the modern one is missing or unusable, and a
-- restricted modern field is never bypassed by reaching for the older path.
--
-- Ownership is one active bar at a time. Switching target, losing the plate and
-- stopping the component all go through the same restore path: the bar recorded
-- before the paint is put back (colour and fill texture) and its record dropped,
-- so a recycled plate never keeps another unit's styling. A forbidden bar is
-- never painted or restored, and a bar whose colour cannot be read is decorated
-- only, because a paint that cannot be undone is worse than a plain bar.

local component

local SOURCE_MODERN = "HealthBarsContainer.healthBar"
local SOURCE_LEGACY = "healthBar"

local function object(value)
    local kind = type(value)
    return kind == "table" or kind == "userdata"
end

local function plateFor(unit)
    local api = _G.C_NamePlate
    if type(api) ~= "table" or type(api.GetNamePlateForUnit) ~= "function" then
        return nil, "no-api"
    end
    local ok, plate = pcall(api.GetNamePlateForUnit, unit)
    if not ok then return nil, "no-api" end
    if not object(plate) then return nil, "no-plate" end
    return plate, nil
end

local function isForbidden(value)
    if not value or type(value.IsForbidden) ~= "function" then return false end
    local ok, forbidden = pcall(value.IsForbidden, value)
    return ok and forbidden == true
end

-- A bar is usable when this build exposes at least one way to draw it. Some
-- builds paint a nameplate health bar with a plain texture instead of a
-- StatusBar; those still get the LumaUI plate and hairline, only the fill is
-- left alone because there is no status-bar colour to record and put back.
local function usable(bar)
    return object(bar) and (type(bar.SetStatusBarColor) == "function"
        or type(bar.SetColorTexture) == "function")
end

-- One candidate field: missing, restricted, unsupported (present but without a
-- drawing method) or ok. A restricted candidate must not be replaced by the
-- other path: the client has told us the object is off limits.
local function candidate(bar)
    if not object(bar) then return nil, "missing" end
    if isForbidden(bar) then return nil, "restricted" end
    if not usable(bar) then return nil, "unsupported" end
    return bar
end

-- Resolves one unit into the plate, the unit frame, both candidate states and
-- the bar that may be painted. `reason` is nil only when a bar was resolved.
local function resolve(unit)
    local plate, reason = plateFor(unit)
    if not plate then return { unit = unit, reason = reason } end
    local frame = plate.UnitFrame
    if not object(frame) then
        return { unit = unit, plate = plate, reason = "no-unit-frame" }
    end
    local container = frame.HealthBarsContainer
    local modernBar = object(container) and container.healthBar or nil
    local legacyBar = frame.healthBar
    local modern, modernState = candidate(modernBar)
    local legacy, legacyState = candidate(legacyBar)
    local resolved = {
        unit = unit, plate = plate, frame = frame,
        modern = modernState or "ok", legacy = legacyState or "ok",
        containerReady = object(container),
    }
    if modern then
        resolved.bar, resolved.source = modern, SOURCE_MODERN
        return resolved
    end
    if modernState == "restricted" then
        resolved.reason = "restricted"
        resolved.source = SOURCE_MODERN
        return resolved
    end
    if legacy then
        resolved.bar, resolved.source = legacy, SOURCE_LEGACY
        return resolved
    end
    if legacyState == "restricted" then
        resolved.reason = "restricted"
        resolved.source = SOURCE_LEGACY
        return resolved
    end
    if modernState == "unsupported" or legacyState == "unsupported" then
        resolved.reason = "unsupported"
    else
        resolved.reason = "no-health-bar"
    end
    resolved.source = modernState == "unsupported" and SOURCE_MODERN or nil
    return resolved
end

-- A dark track, one hairline and an accent stripe make the native bar read as a
-- Pearl element without resizing or reparenting the plate. All of them belong to
-- the bar we record, and are hidden again when the plate is released or the
-- component stops. Only decorations are created: the bar's own size, texture and
-- colour stay the client's until `paint` records and replaces them.
--
-- The track sits one unit further out than the hairline, so the bar reads as a
-- dark block with a lit edge rather than a flat outline. The stripe marks the
-- leading edge, and the target gets a short accent chip on its top edge: that is
-- the whole selection cue, so the client's own name/health text is untouched and
-- never duplicated. Health values are not read at all here — the native bar
-- draws them.
local TRACK = 3
local EDGE = 2
local CHIP_WIDTH = 18

-- Where the decorations are created. A StatusBar can hold textures and child
-- frames, so the bar hosts them itself and the dark plate sits at BACKGROUND,
-- under the client's fill. A build that draws the health bar with a plain texture
-- cannot parent anything: the four regions would fail and take the whole
-- component down. Those bars get one holder frame in the bar's parent, below the
-- bar's level, so the plate still reads as a plate instead of covering the fill.
local function decorationParent(bar)
    if type(bar.CreateTexture) == "function" then return bar end
    local holder = bar.lumaNameplateHolder
    if holder then return holder end
    local okParent, parent = pcall(bar.GetParent, bar)
    if not okParent or not object(parent) then parent = UIParent end
    holder = CreateFrame("Frame", nil, parent)
    holder:EnableMouse(false)
    holder:SetAllPoints(bar)
    local okLevel, level = pcall(bar.GetFrameLevel, bar)
    level = okLevel and app.Capabilities.Plain(level, "number") or nil
    if level and level > 1 then holder:SetFrameLevel(level - 1) end
    bar.lumaNameplateHolder = holder
    return holder
end

local function decorate(bar, isTarget)
    local host = decorationParent(bar)
    local bg = bar.lumaNameplateBg
    if not bg then
        bg = host:CreateTexture(nil, "BACKGROUND", nil, -7)
        bar.lumaNameplateBg = bg
    end
    bg:ClearAllPoints()
    bg:SetPoint("TOPLEFT", bar, "TOPLEFT", -TRACK, TRACK)
    bg:SetPoint("BOTTOMRIGHT", bar, "BOTTOMRIGHT", TRACK, -TRACK)
    local color = app.Theme.colors.surface
    bg:SetColorTexture(color[1], color[2], color[3], 0.86)
    bg:Show()

    local edge = bar.lumaNameplateEdge
    if not edge then
        edge = CreateFrame("Frame", nil, host, "BackdropTemplate")
        edge:EnableMouse(false)
        bar.lumaNameplateEdge = edge
    end
    edge:ClearAllPoints()
    edge:SetPoint("TOPLEFT", bar, "TOPLEFT", -EDGE, EDGE)
    edge:SetPoint("BOTTOMRIGHT", bar, "BOTTOMRIGHT", EDGE, -EDGE)
    edge:SetBackdrop({ edgeFile = app.Theme.white, edgeSize = app.Pixel:Pixels(1, edge) })
    local line = app.Theme.colors.line
    edge:SetBackdropBorderColor(line[1], line[2], line[3], 0.9)
    edge:Show()

    local accent = app.Theme:Accent()
    local mark = bar.lumaNameplateMark
    if not mark then
        mark = host:CreateTexture(nil, "OVERLAY")
        bar.lumaNameplateMark = mark
    end
    mark:ClearAllPoints()
    mark:SetPoint("TOPLEFT", bar, "TOPLEFT", -TRACK - 1, TRACK)
    mark:SetPoint("BOTTOMLEFT", bar, "BOTTOMLEFT", -TRACK - 1, -TRACK)
    mark:SetWidth(app.Pixel:Pixels(2, mark))
    mark:SetColorTexture(accent[1], accent[2], accent[3], isTarget and 0.98 or 0.55)
    mark:Show()

    local chip = bar.lumaNameplateTarget
    if not chip then
        chip = host:CreateTexture(nil, "OVERLAY", nil, 1)
        bar.lumaNameplateTarget = chip
    end
    chip:ClearAllPoints()
    chip:SetPoint("TOPLEFT", bar, "TOPLEFT", -TRACK, TRACK + 1)
    chip:SetSize(CHIP_WIDTH, 2)
    -- The selection cue is warm white, not the amber chrome: it marks the one
    -- plate the player is acting on, so it must read against every bar colour.
    local mark = app.Theme.colors.text
    chip:SetColorTexture(mark[1], mark[2], mark[3], 0.98)
    if isTarget then chip:Show() else chip:Hide() end
    if bar.lumaNameplateHolder then bar.lumaNameplateHolder:Show() end
end

-- Decoration must never be able to fail the component: one plate whose build
-- differs would otherwise leave every other plate unstyled. The failure is
-- reported once per plate and the plate keeps its native look.
local function decorateSafely(bar, isTarget)
    local ok, problem = pcall(decorate, bar, isTarget)
    if ok then return true end
    if not bar.lumaNameplateWarned then
        bar.lumaNameplateWarned = true
        app:Report("nameplates/decorate", tostring(problem))
    end
    return false
end

-- A confirmed hostile bar gets the Pearl combat fill: one fixed colour with an
-- 8% vertical light drop instead of the horizontal gradient, which keeps a
-- short 104–130 wide nameplate bar saturated. The unit's own colour still comes
-- from the game (class/reaction); the texture replacement is recorded and put
-- back with the colour on release.
local function paint(bar, unit, record, isTarget, enemy)
    if not bar then return false end
    if enemy and record and record.paintable and type(bar.SetStatusBarColor) == "function"
        and not isForbidden(bar) then
        app.Theme:PaintCombatBar(bar, app.Theme:UnitColor(unit))
    end
    return decorateSafely(bar, isTarget)
end

----------------------------------------------------------------------
-- 012 phase 04/05: LumaUI's own visible layer
----------------------------------------------------------------------
-- The own layer is opt-in (`ui.plateOwned`) and is a real renderer, not a mock:
-- its own StatusBar, name, percentage, target chip and cast row live under the
-- client's plate unit frame, so world position, stacking and click selection
-- stay native. When a value the layer needs is restricted it stays hidden and
-- the native drawing keeps its place; nothing is frozen or guessed.
local function plainNumber(value)
    return app.Capabilities.Plain(value, "number")
end

local function unitName(unit)
    if type(UnitName) ~= "function" then return nil end
    local ok, name = pcall(UnitName, unit)
    return ok and app.Capabilities.Plain(name, "string") or nil
end

local function unitHealth(unit)
    if type(UnitHealth) ~= "function" or type(UnitHealthMax) ~= "function" then return nil, nil end
    local okValue, value = pcall(UnitHealth, unit)
    local okMax, maximum = pcall(UnitHealthMax, unit)
    return okValue and value or nil, okMax and maximum or nil
end

-- Native parts are only dimmed after the own layer has something to draw. The
-- original alpha and name visibility are recorded once per plate and come back
-- together with the view, so a recycled plate never keeps another unit's state.
local function setNativeBarAlpha(record, visible)
    local bar = record.bar
    if not bar or isForbidden(bar) or type(bar.SetAlpha) ~= "function" then return end
    if record.nativeBarAlpha == nil then
        if type(bar.GetAlpha) ~= "function" then return end
        local ok, alpha = pcall(bar.GetAlpha, bar)
        alpha = ok and plainNumber(alpha) or nil
        if alpha == nil then return end
        record.nativeBarAlpha = alpha
    end
    pcall(bar.SetAlpha, bar, visible and record.nativeBarAlpha or 0)
end

local function setNativeNameShown(record, shown)
    local frame = record.frame
    local name = frame and frame.name
    -- No native name object means there is nothing to duplicate.
    if not object(name) or type(name.SetShown) ~= "function" then return true end
    if record.nativeNameShown == nil then
        local ok, value = pcall(name.IsShown, name)
        -- `false` is a real answer (the client already hides this name); an
        -- `and/or` chain would turn it into nil and report a failed hide.
        if ok then value = app.Capabilities.Plain(value, "boolean") else value = nil end
        if value == nil then return false end
        record.nativeNameShown = value
    end
    if not shown then
        if record.nativeNameAlpha == nil and type(name.GetAlpha) == "function" then
            local okAlpha, value = pcall(name.GetAlpha, name)
            value = okAlpha and app.Capabilities.Plain(value, "number") or nil
            if value then record.nativeNameAlpha = value end
        end
        if record.nativeNameAlpha and type(name.SetAlpha) == "function" then
            pcall(name.SetAlpha, name, 0)
        end
    elseif record.nativeNameAlpha and type(name.SetAlpha) == "function" then
        pcall(name.SetAlpha, name, record.nativeNameAlpha)
        record.nativeNameAlpha = nil
    end
    return (pcall(name.SetShown, name, shown and record.nativeNameShown or false))
end

-- Whether the own name row really has visible ink: text present and, when the
-- build can measure it, a non-zero width. A build without GetStringWidth keeps
-- the text test only, so the check can never block drawing on its own.
local function ownNameHasInk(name)
    if not object(name) then return false end
    local okText, text = pcall(name.GetText, name)
    text = okText and app.Capabilities.Plain(text, "string") or nil
    if not text or text == "" then return false end
    if type(name.GetStringWidth) ~= "function" then return true end
    local okWidth, width = pcall(name.GetStringWidth, name)
    width = okWidth and plainNumber(width) or nil
    return width ~= nil and width > 0
end

local function ensureView(record)
    if not (record.plate and record.frame) then return nil end
    local view = record.plate.lumaPlateView
    if not view then
        view = app.PlateView:Create(record.frame, { bar = record.bar })
        if view then record.plate.lumaPlateView = view end
    end
    return view
end

-- Reads a cast state as plain numbers only. The client reports times in
-- milliseconds; if any of the tuple values is restricted this returns nil and
-- the native cast bar stays visible for that cast.
local function readCast(unit)
    local now = type(GetTime) == "function" and select(2, pcall(GetTime)) or nil
    now = plainNumber(now)
    if not now then return nil end
    if type(UnitCastingInfo) == "function" then
        local ok, name, text, _, startTime, endTime, _, _, notInterruptible = pcall(UnitCastingInfo, unit)
        if ok and name then
            startTime, endTime = plainNumber(startTime), plainNumber(endTime)
            if not startTime or not endTime or endTime <= startTime then return nil end
            return { name = app.Capabilities.Plain(text, "string") or app.Capabilities.Plain(name, "string"),
                elapsed = math.max(0, now * 1000 - startTime), duration = endTime - startTime,
                channel = false,
                interruptible = not (notInterruptible == true) }
        end
    end
    if type(UnitChannelInfo) == "function" then
        local ok, name, text, _, startTime, endTime, _, notInterruptible = pcall(UnitChannelInfo, unit)
        if ok and name then
            startTime, endTime = plainNumber(startTime), plainNumber(endTime)
            if not startTime or not endTime or endTime <= startTime then return nil end
            return { name = app.Capabilities.Plain(text, "string") or app.Capabilities.Plain(name, "string"),
                elapsed = math.max(0, now * 1000 - startTime), duration = endTime - startTime,
                channel = true,
                interruptible = not (notInterruptible == true) }
        end
    end
end

-- The progress row advances on a slow ticker that exists only while a cast is
-- live. A finished cast cancels it, so an idle plate has no timer at all.
local function stopCastTicker(record)
    if record and record.castTicker then
        record.castTicker:Cancel()
        record.castTicker = nil
    end
end

local function updateCast(self, unit)
    local record = self.plates and self.plates[unit]
    local view = record and record.view
    if not view then return end
    if not (self.plateCast and record.viewActive) then
        app.PlateView:ClearCast(view)
        stopCastTicker(record)
        record.castActive = nil
        return
    end
    local state = readCast(unit)
    if not state then
        app.PlateView:ClearCast(view)
        stopCastTicker(record)
        record.castActive = nil
        record.castReason = "restricted"
        return
    end
    app.PlateView:SetCast(view, state)
    record.castActive = true
    record.castReason = nil
    if not record.castTicker and type(C_Timer) == "table"
        and type(C_Timer.NewTicker) == "function" then
        record.castTicker = C_Timer.NewTicker(0.1, function()
            if not self.running or not record.castActive or not record.view then
                stopCastTicker(record)
                return
            end
            local current = readCast(unit)
            if current then
                app.PlateView:SetCast(record.view, current)
            else
                app.PlateView:ClearCast(record.view)
                record.castActive = nil
                stopCastTicker(record)
            end
        end)
    end
end

-- 013 phase 02: native hand-over, part by part.
--
-- While the own layer draws a plate, the client's matching parts step aside:
-- the health fill (alpha), the plate panel (`bgTexture` and the Background
-- fields), the unselected dim (`deselectedOverlay`), the selection border
-- (`selectedBorder`) and the name. Each part is recorded with its original
-- shown state and alpha, written once, read back, and restored one object at a
-- time. `false` is a real recorded value, not "missing". `plateNative = "keep"`
-- leaves every part alone, and any own-draw failure puts all of them back.
--
-- 12.1.5 (Blizzard_NamePlates): the visible plate border is
-- `healthBar.selectedBorder` (positioned from `bgTexture`), the panel is
-- `healthBar.bgTexture`, the unselected dim is `healthBar.deselectedOverlay`.
-- Hiding `bgTexture` does not hide `selectedBorder`, which is why the border is
-- its own part.
local PANEL_FIELDS = { "Background", "background", "healthBarBackground" }
local HANDOFF_PARTS = { "panel", "dim", "border" }

local function partObjects(record, part)
    local frame, bar = record.frame, record.bar
    local list = {}
    if not object(frame) or isForbidden(frame) then return list end
    if part == "panel" then
        for _, field in ipairs(PANEL_FIELDS) do list[#list + 1] = frame[field] end
        local container = frame.HealthBarsContainer
        if object(container) then
            list[#list + 1] = container.Background
            list[#list + 1] = container.background
        end
        if object(bar) then list[#list + 1] = bar.bgTexture end
    elseif part == "dim" then
        if object(bar) then list[#list + 1] = bar.deselectedOverlay end
    elseif part == "border" then
        if object(bar) then list[#list + 1] = bar.selectedBorder end
    end
    return list
end

local function plainBool(call, target)
    local ok, value = pcall(call, target)
    if not ok then return nil end
    return app.Capabilities.Plain(value, "boolean")
end

-- Hides one part once. Re-entry keeps the first recording, so a second pass can
-- never capture the already-hidden state as the original.
local function hidePart(record, part)
    record.handoff = record.handoff or {}
    if record.handoff[part] then return end
    local entries = {}
    record.handoff[part] = entries
    for _, target in ipairs(partObjects(record, part)) do
        if object(target) and not isForbidden(target)
            and type(target.IsShown) == "function" and type(target.SetShown) == "function" then
            local shown = plainBool(target.IsShown, target)
            if shown ~= nil then
                local alpha
                if type(target.GetAlpha) == "function" then
                    local okAlpha, value = pcall(target.GetAlpha, target)
                    if okAlpha then alpha = plainNumber(value) end
                end
                local entry = { object = target, shown = shown, alpha = alpha }
                entries[#entries + 1] = entry
                pcall(target.SetShown, target, false)
                -- Alpha 0 survives the client re-showing the object on a target
                -- change; SetShown(false) alone does not.
                if alpha and type(target.SetAlpha) == "function" then
                    pcall(target.SetAlpha, target, 0)
                end
                entry.hidden = plainBool(target.IsShown, target) == false
            end
        end
    end
end

-- Re-applies the hidden state after a client update shows an object again.
local function reapplyParts(record)
    for _, entries in pairs(record.handoff or {}) do
        for _, entry in ipairs(entries) do
            if object(entry.object) and not isForbidden(entry.object) then
                pcall(entry.object.SetShown, entry.object, false)
                if entry.alpha and type(entry.object.SetAlpha) == "function" then
                    pcall(entry.object.SetAlpha, entry.object, 0)
                end
            end
        end
    end
end

local function restoreParts(record)
    for _, entries in pairs(record.handoff or {}) do
        for _, entry in ipairs(entries) do
            if object(entry.object) and not isForbidden(entry.object) then
                if entry.alpha and type(entry.object.SetAlpha) == "function" then
                    pcall(entry.object.SetAlpha, entry.object, entry.alpha)
                end
                pcall(entry.object.SetShown, entry.object, entry.shown)
            end
        end
    end
    record.handoff = nil
end

-- The state word of one part for diagnostics: `hidden(n)` counts the objects
-- whose hidden state was read back, `unverified(n)` those that were not, and
-- `absent` means this build has no such object.
local function partState(record, part)
    local entries = record.handoff and record.handoff[part]
    if not entries then return record.viewActive and "kept" or "native" end
    if #entries == 0 then return "absent" end
    local confirmed = 0
    for _, entry in ipairs(entries) do
        if entry.hidden then confirmed = confirmed + 1 end
    end
    if confirmed == #entries then return string.format("hidden(%d)", confirmed) end
    return string.format("unverified(%d/%d)", confirmed, #entries)
end

-- The fill colour comes from the client's own bar when it can be read as plain
-- numbers (it carries the reaction/class colour the client chose), otherwise
-- from the unit's public identity.
local function nativeBarColor(bar)
    if not object(bar) or type(bar.GetStatusBarColor) ~= "function" then return nil end
    local ok, red, green, blue = pcall(bar.GetStatusBarColor, bar)
    if not ok then return nil end
    red, green, blue = plainNumber(red), plainNumber(green), plainNumber(blue)
    if red and green and blue then return { red, green, blue } end
end

-- Puts every native part back and hides the own layer. One path for a plate
-- that leaves, a mode that switches, a failed own draw and component stop.
local function releaseOwn(record)
    stopCastTicker(record)
    record.castActive = nil
    setNativeBarAlpha(record, true)
    setNativeNameShown(record, true)
    restoreParts(record)
    if record.view then app.PlateView:Reset(record.view) end
    record.viewActive = nil
end

local function updateView(self, unit)
    local record = self.plates and self.plates[unit]
    if not record then return end
    if not self.owned then
        releaseOwn(record)
        record.viewReason = nil
        return
    end
    local view = record.view or ensureView(record)
    record.view = view
    if not view then
        releaseOwn(record)
        record.viewReason = "view-unavailable"
        return
    end
    -- With direct drawing off, restricted health keeps the client's own plate.
    if not self.direct then
        local health, maximum = unitHealth(unit)
        if plainNumber(health) == nil or plainNumber(maximum) == nil then
            releaseOwn(record)
            record.viewReason = "restricted-health"
            return
        end
    end
    app.PlateView:ShowTrack(view)
    local ok, detail = app.PlateView:DrawUnit(view, unit)
    if not ok then
        releaseOwn(record)
        record.viewReason = detail
        return
    end
    record.viewReason = nil
    record.viewActive = true
    record.healthPath = "direct"
    record.percentSource = detail
    app.PlateView:SetUnit(view, unit)
    local color = nativeBarColor(record.bar)
    if color then app.PlateView:SetColor(view, color) end
    local hide = self.nativeMode == "hide"
    local named = hide and app.PlateView:SetName(view, unitName(unit)) or false
    record.nameState = hide and "native:unreadable" or "keep"
    -- A successful SetText is not proof the glyphs are on screen: the string can
    -- be empty, clipped to nothing, or drawn by a control this build cannot
    -- measure. The native name only steps aside once the own row reports ink,
    -- otherwise a render failure would leave the plate with no name at all.
    if named and not ownNameHasInk(view.name) then
        app.PlateView:SetName(view, nil)
        named = false
        record.nameState = "native:own-empty"
    end
    if named then
        if setNativeNameShown(record, false) then
            record.nameState = object(record.frame and record.frame.name) and "luma" or "luma:no-native-object"
        else
            app.PlateView:SetName(view, nil)
            named = false
            record.nameState = "native:hide-failed"
        end
    end
    app.PlateView:SetTarget(view, record.target == true)
    view.frame:Show()
    if hide then
        for _, part in ipairs(HANDOFF_PARTS) do hidePart(record, part) end
        setNativeBarAlpha(record, false)
        setNativeNameShown(record, not named)
    else
        restoreParts(record)
        setNativeBarAlpha(record, true)
        setNativeNameShown(record, true)
    end
    updateCast(self, unit)
end

-- Records who draws each plate piece under the shared Ownership vocabulary.
-- This is the mode's intent: a plate that falls back to native says so in the
-- per-plate `draw:` line, and nothing here claims live-client validation.
local OWNERSHIP_IDS = { "nameplates.health", "nameplates.border", "nameplates.name" }

local function recordOwnership(self)
    if not app.Ownership then return end
    local owned = self.owned == true
    local hide = self.nativeMode == "hide"
    local function set(id, ownedHere, reason)
        app.Ownership:Set(id, {
            intent = ownedHere and "owned" or "native",
            active = ownedHere and "owned" or "native",
            evidence = ownedHere and "simulated" or "none",
            reason = reason or (ownedHere and "awaiting-validation" or "native-kept"),
        })
    end
    set("nameplates.health", owned, owned and not self.direct and "restricted-native" or nil)
    set("nameplates.border", owned and hide)
    set("nameplates.name", owned and hide)
end

-- Called on health/name/cast events. Only the plate that owns the unit is
-- updated, so one unit's tick cannot repaint every visible plate.
local function updateUnit(self, unit)
    if type(unit) ~= "string" then return end
    if not (self.plates and self.plates[unit]) then return end
    app:Call("nameplates/view/" .. unit, updateView, self, unit)
end

-- The snapshot is taken once per bar, before the first write. Only a readable
-- colour counts as paintable; the texture is recorded separately and restored
-- even when no colour was available. Only the native-repaint mode (own layer
-- off) records and writes a bar.
local function remember(self, bar)
    local existing = self.originals[bar]
    if existing then return existing end
    local original = { paintable = false }
    if type(bar.GetStatusBarColor) == "function" then
        local ok, red, green, blue, alpha = pcall(bar.GetStatusBarColor, bar)
        if ok and red ~= nil then
            local record = { red, green, blue, alpha }
            local plain = true
            for index = 1, 4 do
                if app.Capabilities.Plain(record[index], "number") == nil then plain = false end
            end
            if plain then
                original.color = record
                original.paintable = true
            end
        end
    end
    if type(bar.GetStatusBarTexture) == "function" then
        local ok, texture = pcall(bar.GetStatusBarTexture, bar)
        if ok and texture ~= nil then original.texture = texture end
    end
    self.originals[bar] = original
    return original
end

-- Hooks only re-apply the hidden state after the client's own update functions
-- show a part again. They are installed once on the mixin tables and once per
-- bar/frame instance (an instance copied its methods when it was created, so a
-- mixin hook alone never sees it), and they return at once unless the component
-- is running with the own layer on and the plate is currently drawn.
local function reapply(record)
    if not record or not component or not component.running or not component.owned then return end
    if not record.viewActive or component.nativeMode ~= "hide" then return end
    reapplyParts(record)
    setNativeBarAlpha(record, false)
end

local function reapplyBar(bar)
    reapply(bar and bar.lumaNameplateRecord)
end

local function reapplyFrame(frame)
    reapply(frame and frame.lumaNameplateRecord)
end

local BAR_METHODS = { "UpdateHealthColor", "UpdateSelectionBorder" }
local FRAME_METHODS = { "UpdateAnchors" }

-- Hooks one instance method and reports the real outcome. `hooked[key]` is true
-- only when `hooksecurefunc` accepted the call.
local function hookInstance(target, methods, callback, hooked)
    if type(hooksecurefunc) ~= "function" or not object(target) or isForbidden(target) then return end
    for _, method in ipairs(methods) do
        local key = method
        if type(target[method]) == "function" and not (target.lumaNameplateHooked and target.lumaNameplateHooked[key]) then
            local ok = pcall(hooksecurefunc, target, method, callback)
            target.lumaNameplateHooked = target.lumaNameplateHooked or {}
            target.lumaNameplateHooked[key] = ok
            hooked[#hooked + 1] = method .. ":" .. (ok and "ok" or "fail")
        end
    end
end

local function hookRecord(record)
    record.hooks = record.hooks or {}
    hookInstance(record.bar, BAR_METHODS, reapplyBar, record.hooks)
    hookInstance(record.frame, FRAME_METHODS, reapplyFrame, record.hooks)
end

-- Puts one recorded bar back (native-repaint mode only). Only the properties
-- that were actually changed are restored; a restricted object is skipped
-- instead of being written to.
local function restore(self, bar)
    local original = bar and self.originals[bar]
    if not original then return end
    self.originals[bar] = nil
    if isForbidden(bar) then return end
    if type(bar.SetStatusBarTexture) == "function" and original.texture then
        pcall(bar.SetStatusBarTexture, bar, original.texture)
    end
    if type(bar.SetStatusBarColor) == "function" and original.color then
        pcall(bar.SetStatusBarColor, bar, original.color[1], original.color[2],
            original.color[3], original.color[4])
    end
    if bar.lumaNameplateBg then bar.lumaNameplateBg:Hide() end
    if bar.lumaNameplateEdge then bar.lumaNameplateEdge:Hide() end
    if bar.lumaNameplateMark then bar.lumaNameplateMark:Hide() end
    if bar.lumaNameplateTarget then bar.lumaNameplateTarget:Hide() end
    if bar.lumaNameplateHolder then bar.lumaNameplateHolder:Hide() end
end

local function restoreAll(self)
    for _, record in pairs(self.plates or {}) do
        releaseOwn(record)
        if record.bar and record.bar.lumaNameplateRecord == record then record.bar.lumaNameplateRecord = nil end
        if record.frame and record.frame.lumaNameplateRecord == record then record.frame.lumaNameplateRecord = nil end
    end
    for bar in pairs(self.originals or {}) do
        restore(self, bar)
    end
    self.originals = {}
    self.plates = {}
    self.retries = {}
    self.last = nil
end

-- Ownership is per unit: `plates[unit]` holds the bar that unit's plate owns, so
-- a recycled plate is always restored through the unit that painted it. A bar is
-- only ever owned by one unit; if the client hands the same bar to another unit
-- the previous owner is restored first.
local function barOwner(self, bar)
    for unit, record in pairs(self.plates) do
        if record.bar == bar then return unit end
    end
end

local function isTargetUnit(unit)
    if type(UnitIsUnit) ~= "function" then return false end
    local ok, same = pcall(UnitIsUnit, unit, "target")
    return ok and same == true
end

-- One classification for the paint gate and the diagnostics. Reaction is the
-- most precise plain answer (it tells friendly from neutral); the hostile
-- boolean covers builds that report no reaction. An unreadable answer is
-- "unknown" and is never treated as hostility, so a restricted plate keeps its
-- native look.
local function classify(unit)
    if type(UnitReaction) == "function" then
        local ok, reaction = pcall(UnitReaction, unit, "player")
        reaction = ok and app.Capabilities.Plain(reaction, "number") or nil
        if reaction then
            if reaction <= 3 then return "hostile" end
            if reaction == 4 then return "neutral" end
            return "friendly"
        end
    end
    if type(UnitIsEnemy) == "function" then
        local ok, enemy = pcall(UnitIsEnemy, "player", unit)
        if ok then enemy = app.Capabilities.Plain(enemy, "boolean") else enemy = nil end
        if enemy == true then return "hostile" end
        if enemy == false then return "friendly" end
    end
    return "unknown"
end

-- Only a confirmed hostile plate gets its fill replaced.
local function hostile(unit)
    return classify(unit) == "hostile"
end

local attach, retry

local function releaseUnit(self, unit)
    local record = self.plates[unit]
    if not record then return end
    self.plates[unit] = nil
    if record.bar and record.bar.lumaNameplateRecord == record then record.bar.lumaNameplateRecord = nil end
    if record.frame and record.frame.lumaNameplateRecord == record then record.frame.lumaNameplateRecord = nil end
    releaseOwn(record)
    if not record.view and record.plate and record.plate.lumaPlateView then
        app.PlateView:Reset(record.plate.lumaPlateView)
    end
    restore(self, record.bar)
end

-- Every readable plate is decorated, not just hostile ones: in a city or a
-- friendly camp the plates a player actually sees are friendly, and an
-- enemy-only gate makes the whole layer look broken. What stays hostile-only is
-- the health fill: a friendly bar keeps the client's reaction colour instead of
-- being repainted, so "green means friendly" still reads at a glance.
attach = function(self, unit)
    if not unit then return false end
    local info = resolve(unit)
    self.last = info
    local bar = info.bar
    local existing = self.plates[unit]
    if not bar then
        -- The plate exists but this build exposes no paintable bar: keep the
        -- native look rather than guessing, and drop any previous record.
        releaseUnit(self, unit)
        self.lastReason = info.reason
        -- NAME_PLATE_UNIT_ADDED can arrive before the plate's unit frame or its
        -- health bar exists; that is transient, not "this build cannot do it".
        -- One short retry turns a permanently native-looking plate into the
        -- styled one a moment later.
        retry(self, unit)
        return false
    end
    local owner = barOwner(self, bar)
    if owner and owner ~= unit then releaseUnit(self, owner) end
    if existing and existing.bar ~= bar then releaseUnit(self, unit) end
    -- The two looks are exclusive: with the own layer on, nothing is painted or
    -- decorated on the native bar (a leftover record from the repaint mode is
    -- put back first); with it off, the native bar gets the reversible repaint.
    local record
    if self.owned then
        if self.originals[bar] then restore(self, bar) end
    else
        record = remember(self, bar)
    end
    local target = isTargetUnit(unit)
    local enemy = hostile(unit)
    local decorated = false
    if record then decorated = paint(bar, unit, record, target, enemy) end
    self.lastReason = "ok"
    -- A styled plate clears its attempt count, so a later appearance of the same
    -- unit token gets a fresh pair of retries instead of inheriting failures.
    if self.retries then self.retries[unit] = nil end
    -- Re-attaching the same unit/bar updates the existing record instead of
    -- replacing it: the view, its ticker and the recorded native alpha/name
    -- state belong to that plate and must survive a scan pass. A fresh table
    -- would capture the already-dimmed alpha as "original" and never restore it.
    local state = existing or {}
    state.unit, state.bar, state.source = unit, bar, info.source
    state.target, state.enemy = target, enemy
    state.class, state.decorated = classify(unit), decorated == true
    state.plate, state.frame = info.plate, info.frame
    bar.lumaNameplateRecord = state
    if state.frame then state.frame.lumaNameplateRecord = state end
    -- "painted" means the LumaUI fill really replaced the client's: a hostile
    -- plate with a readable colour. Everything else kept the client's own fill
    -- and is reported as such.
    state.painted = record ~= nil and enemy and record.paintable
        and type(bar.SetStatusBarColor) == "function" or false
    self.plates[unit] = state
    hookRecord(state)
    updateView(self, unit)
    return true
end

-- Reasons that only mean "not ready yet". A restricted or unsupported bar is a
-- real limitation of this build and is never retried.
local TRANSIENT = { ["no-plate"] = true, ["no-unit-frame"] = true, ["no-health-bar"] = true }

-- One short retry per unit and plate appearance. The timer is one-shot, checks
-- `running`, whether the plate is already owned, and that the unit still points
-- at the same plate the attempt started with, so a discontinued component, a
-- plate that vanished or a plate recycled for another unit costs nothing. The
-- callback runs outside the combat queue: it only reads and decorates, never a
-- protected frame.
retry = function(self, unit)
    if not self.running or not TRANSIENT[self.lastReason or ""] then return end
    -- Only a real nameplate token is worth a second look. "target" has no plate
    -- of its own and a client that answers nothing would otherwise keep a timer
    -- chain alive for the whole session.
    if type(unit) ~= "string" or not unit:match("^nameplate%d+$") then return end
    if type(C_Timer) ~= "table" or type(C_Timer.After) ~= "function" then return end
    self.retries = self.retries or {}
    local attempts = self.retries[unit] or 0
    if attempts >= 2 then return end
    self.retries[unit] = attempts + 1
    local expected = self.last and self.last.plate or nil
    C_Timer.After(0.25, function()
        if not self.running or self.plates[unit] then return end
        if expected then
            local plate = plateFor(unit)
            if plate ~= expected then return end
        end
        app:Call("nameplates/retry", attach, self, unit)
    end)
end

-- Moves only the selection cue. Repainting every plate on a target change would
-- also re-write textures the client may have just reset.
local function markTarget(self)
    for unit, record in pairs(self.plates) do
        local target = isTargetUnit(unit)
        if target ~= record.target then
            record.target = target
            if not self.owned and not isForbidden(record.bar) then decorateSafely(record.bar, target) end
            if record.view and record.viewActive then
                app.PlateView:SetTarget(record.view, target)
            end
        end
    end
end

-- Scans the plates that already exist on enable (a reload or a config change
-- with mobs around). Bounded: the client exposes at most 40 nameplate units. A
-- nameplate unit can exist without a plate frame, so the plate is the gate: a
-- scan must not schedule work for 40 units that have nothing to draw.
local function scan(self)
    for index = 1, 40 do
        local unit = "nameplate" .. index
        if plateFor(unit) then attach(self, unit) end
    end
end

-- The target alias only contributes the selection mark (010 phase 06). When the
-- target's plate is one of the client's own nameplateN tokens — the normal
-- case — that token owns the bar and the alias never records it, so `target`
-- and `nameplateN` cannot both hold (and later restore) the same plate. The
-- alias record exists only for a build that answers the target plate through
-- the alias alone, and is dropped as soon as the target changes or a real
-- token takes the bar over.
local function targetPlate(self)
    local plate = plateFor("target")
    if not plate then return nil end
    for index = 1, 40 do
        local unit = "nameplate" .. index
        if plateFor(unit) == plate then
            if not self.plates[unit] then attach(self, unit) end
            return unit
        end
    end
    return nil
end

local function attachTarget(self)
    local unit = targetPlate(self)
    local fallback = self.plates["target"]
    if unit then
        if fallback then releaseUnit(self, "target") end
        markTarget(self)
        return
    end
    local info = resolve("target")
    if fallback and fallback.bar ~= info.bar then releaseUnit(self, "target") end
    if info.bar then attach(self, "target") end
    markTarget(self)
end

component = app:RegisterComponent({ id = "nameplates", label = "nameplates", defaultEnabled = true,
    Supported = function()
        local api = _G.C_NamePlate
        return type(api) == "table" and type(api.GetNamePlateForUnit) == "function"
    end,
    Enable = function(self)
        self.originals = self.originals or {}
        self.plates = self.plates or {}
        local ui = app.Store:Profile().ui
        self.owned = ui.plateOwned == true
        self.plateCast = ui.plateCast == true
        self.direct = ui.plateDirect ~= false
        self.nativeMode = ui.plateNative == "keep" and "keep" or "hide"
        -- Safe draw updates run immediately: a colour/texture write on a plate we
        -- own is not a protected action, and delaying a target change until after
        -- combat is what made the old pass look late. Creation stays here, in
        -- Enable, which the runtime already runs outside combat.
        -- Handlers receive (component, eventName, ...), so the unit token is the
        -- third argument.
        self:Listen("NAME_PLATE_UNIT_ADDED", function(current, _, unit)
            if type(unit) == "string" then attach(current, unit) end
        end)
        self:Listen("NAME_PLATE_UNIT_REMOVED", function(current, _, unit)
            if type(unit) == "string" then releaseUnit(current, unit) end
        end)
        self:Listen("PLAYER_TARGET_CHANGED", function(current)
            attachTarget(current)
        end)
        self:Listen("PLAYER_ENTERING_WORLD", function(current)
            scan(current)
            attachTarget(current)
        end)
        -- Own-layer updates: only the plate that owns the unit is touched. Name
        -- and health cannot change the cast row and vice versa, so the two sets
        -- stay separate events.
        for _, event in ipairs({ "UNIT_HEALTH", "UNIT_HEALTH_FREQUENT",
            "UNIT_MAXHEALTH", "UNIT_NAME_UPDATE" }) do
            self:Listen(event, function(current, _, unit) updateUnit(current, unit) end)
        end
        for _, event in ipairs({ "UNIT_SPELLCAST_START", "UNIT_SPELLCAST_STOP",
            "UNIT_SPELLCAST_FAILED", "UNIT_SPELLCAST_INTERRUPTED",
            "UNIT_SPELLCAST_CHANNEL_START", "UNIT_SPELLCAST_CHANNEL_STOP",
            "UNIT_SPELLCAST_CHANNEL_UPDATE", "UNIT_SPELLCAST_INTERRUPTIBLE",
            "UNIT_SPELLCAST_NOT_INTERRUPTIBLE" }) do
            self:Listen(event, function(current, _, unit) updateUnit(current, unit) end)
        end
        -- The client re-shows `selectedBorder`/`bgTexture` in UpdateAnchors and
        -- UpdateSelectionBorder and resets the fill colour in
        -- UpdateHealthColor (12.1.5 source). The mixin tables are hooked once;
        -- every attached bar and frame is additionally hooked as an instance,
        -- because an instance copied the methods when the client created it.
        -- Each hook outcome is kept for `/luma plates`.
        if not self.hookStates and type(hooksecurefunc) == "function" then
            self.hookStates = {}
            local barMixin = _G.NamePlateHealthBarMixin
            if type(barMixin) == "table" then
                for _, method in ipairs(BAR_METHODS) do
                    if type(barMixin[method]) == "function" then
                        local ok = pcall(hooksecurefunc, barMixin, method, function(bar) reapplyBar(bar) end)
                        self.hookStates[#self.hookStates + 1] = "bar." .. method .. ":" .. (ok and "ok" or "fail")
                    end
                end
            end
            local frameMixin = _G.NamePlateUnitFrameMixin
            if type(frameMixin) == "table" and type(frameMixin.UpdateAnchors) == "function" then
                local ok = pcall(hooksecurefunc, frameMixin, "UpdateAnchors", function(frame)
                    local container = frame and frame.HealthBarsContainer
                    reapplyBar(object(container) and container.healthBar or nil)
                end)
                self.hookStates[#self.hookStates + 1] = "frame.UpdateAnchors:" .. (ok and "ok" or "fail")
            end
        end
        scan(self)
        attachTarget(self)
        if app.Ownership then
            app.Ownership:Set("nameplates", { intent = "styled", active = "styled",
                evidence = "simulated", reason = self.lastReason })
        end
        recordOwnership(self)
    end,
    Refresh = function(self)
        local ui = app.Store:Profile().ui
        self.owned = ui.plateOwned == true
        self.plateCast = ui.plateCast == true
        self.direct = ui.plateDirect ~= false
        self.nativeMode = ui.plateNative == "keep" and "keep" or "hide"
        scan(self)
        attachTarget(self)
        recordOwnership(self)
        for unit in pairs(self.plates or {}) do updateView(self, unit) end
    end,
    Disable = function(self)
        restoreAll(self)
        if app.Ownership then
            app.Ownership:Active("nameplates", "native", "component-off")
            for _, id in ipairs(OWNERSHIP_IDS) do app.Ownership:Active(id, "native", "component-off") end
        end
    end,
})

-- Diagnostics for `/luma status`: how many plates LumaUI currently owns, which
-- is also how many native looks it is holding to put back.
function component:Describe()
    if not self.running then return nil end
    local count, hostileCount = 0, 0
    for _, record in pairs(self.plates or {}) do
        count = count + 1
        if record.enemy then hostileCount = hostileCount + 1 end
    end
    -- `last=` is the outcome of the most recent attach: it is how a player can
    -- tell "no plate nearby" from "the bar this build exposes is restricted".
    local views, casts = 0, 0
    for _, record in pairs(self.plates or {}) do
        if record.viewActive then views = views + 1 end
        if record.castActive then casts = casts + 1 end
    end
    return string.format("nameplates: %s=%d hostile=%d last=%s view=%s/%d cast=%d",
        app.L.nativePlatesPainted, count, hostileCount, tostring(self.lastReason or "none"),
        self.owned and "owned" or "native", views, casts)
end

-- Field states stay ASCII tokens: they are the same vocabulary as
-- `status=running` and can be compared between reports. Prose lines below them
-- are localized.
local function stateWord(state)
    if state == "ok" then return "ok" end
    if state == "restricted" then return "restricted" end
    if state == "unsupported" then return "unsupported" end
    return "missing"
end

local function reasonWord(reason)
    if reason == "no-api" then return app.L.platesNoApi end
    if reason == "no-plate" then return app.L.platesNoPlate end
    if reason == "no-unit-frame" then return app.L.platesNoUnitFrame end
    if reason == "restricted" then return app.L.platesRestricted end
    if reason == "unsupported" then return app.L.platesUnsupported end
    return app.L.platesNoBar
end

-- `/luma plates`: tells "the component cannot see a plate" apart from "the
-- client draws no plate at all", and distinguishes the modern nested bar from
-- the legacy direct field. LumaUI only repaints a bar the client already draws,
-- so the client's own nameplate settings decide whether there is anything to
-- repaint. Those values are read here and never written.
local function cvar(name)
    if type(GetCVar) ~= "function" then return nil end
    local ok, value = pcall(GetCVar, name)
    return ok and app.Capabilities.Plain(value, "string") or nil
end

-- Explicit, player-requested change of the client's own nameplate setting. The
-- component never writes a CVar on its own: "LumaUI shows no nameplates" is
-- almost always this setting being off, and the player decides whether to turn
-- it on again.
function component:Command(argument)
    local wanted = type(argument) == "string" and argument:lower():match("^%s*(%a+)") or nil
    -- The own layer and its cast row are explicit opt-ins. The client's own
    -- nameplate setting above stays a separate, player-requested switch.
    if wanted == "owned" or wanted == "cast" then
        local key = wanted == "owned" and "plateOwned" or "plateCast"
        local value = not (app.Store:Profile().ui[key] == true)
        if not app.Store:Set("ui", key, value) then
            app:Print(app.L.readonly)
            return
        end
        if wanted == "owned" then
            app:Print(value and app.L.platesOwnedOn or app.L.platesOwnedOff)
        else
            app:Print(value and app.L.platesCastOn or app.L.platesCastOff)
        end
        if self.running then self:Refresh() end
        return
    end
    -- 013 trial switches. `direct` lets restricted health go straight into the
    -- own StatusBar; `native` chooses whether the client's matching parts step
    -- aside (`hide`, default) or stay visible under the own layer (`keep`).
    if wanted == "direct" then
        local value = not (app.Store:Profile().ui.plateDirect ~= false)
        if not app.Store:Set("ui", "plateDirect", value) then
            app:Print(app.L.readonly)
            return
        end
        app:Print(value and app.L.platesDirectOn or app.L.platesDirectOff)
        if self.running then self:Refresh() end
        return
    end
    if wanted == "native" then
        local keep = app.Store:Profile().ui.plateNative ~= "keep"
        if not app.Store:Set("ui", "plateNative", keep and "keep" or "hide") then
            app:Print(app.L.readonly)
            return
        end
        app:Print(keep and app.L.platesNativeKeep or app.L.platesNativeHide)
        if self.running then self:Refresh() end
        return
    end
    if wanted ~= "on" and wanted ~= "off" and wanted ~= "friends" then
        self:Diagnose()
        return
    end
    if type(SetCVar) ~= "function" then
        app:Print(app.L.platesNoCvar)
        return
    end
    local enemies = wanted == "off" and "0" or "1"
    local friends = (wanted == "friends" or wanted == "off") and enemies or nil
    local ok = pcall(SetCVar, "nameplateShowEnemies", enemies)
    if ok and friends then ok = pcall(SetCVar, "nameplateShowFriends", friends) end
    if not ok then
        app:Print(app.L.platesNoCvar)
        return
    end
    app:Print(wanted == "off" and app.L.platesTurnedOff or app.L.platesTurnedOn)
    -- The client announces the plates it starts drawing; ask for one pass anyway
    -- so a plate that already existed is picked up in the same tick.
    if self.running then scan(self) end
end

-- A readable "WxH@scale" for one frame. Every unreadable number is "?" and a
-- restricted object is never asked: diagnostics stay plain and read-only.
local function rectWord(target)
    if not object(target) or isForbidden(target) then return "?" end
    local function read(method)
        if type(target[method]) ~= "function" then return nil end
        local ok, value = pcall(target[method], target)
        return ok and plainNumber(value) or nil
    end
    local width, height, scale = read("GetWidth"), read("GetHeight"), read("GetEffectiveScale")
    return string.format("%s x %s @%s",
        width and string.format("%.0f", width) or "?",
        height and string.format("%.0f", height) or "?",
        scale and string.format("%.2f", scale) or "?")
end

local function objectKind(target)
    if not object(target) or type(target.GetObjectType) ~= "function" then return "?" end
    local ok, kind = pcall(target.GetObjectType, target)
    return ok and app.Capabilities.Plain(kind, "string") or "?"
end

function component:Diagnose(limit)
    limit = tonumber(limit) or 5
    local function yes(value) return value and "yes" or "no" end
    local api = _G.C_NamePlate
    local available = type(api) == "table" and type(api.GetNamePlateForUnit) == "function"
    app:Print(string.format("nameplates: status=%s running=%s api=%s",
        tostring(self.status), yes(self.running), yes(available)))
    -- The leading answer when there is nothing to style at all: the client is
    -- not drawing plates, which no amount of repainting can change.
    local enemies, friends = cvar("nameplateShowEnemies"), cvar("nameplateShowFriends")
    if enemies == "0" and friends == "0" then
        app:Print("  " .. string.format(app.L.platesNothingDrawn,
            enemies, friends))
    end
    local info = resolve("target")
    self.last = info
    local painted, owned = 0, 0
    for _ in pairs(self.originals or {}) do painted = painted + 1 end
    for _ in pairs(self.plates or {}) do owned = owned + 1 end
    app:Print(string.format("  target: plate=%s frame=%s modern=%s legacy=%s",
        yes(info.plate ~= nil), yes(info.frame ~= nil),
        stateWord(info.modern), stateWord(info.legacy)))
    if info.bar then
        app:Print(string.format("  bar=ok · source=%s · units=%d · %s=%d",
            info.source or "?", owned, app.L.nativePlatesPainted, painted))
    else
        app:Print(string.format("  %s · units=%d · %s=%d", reasonWord(info.reason),
            owned, app.L.nativePlatesPainted, painted))
    end
    -- Per-plate inventory and one totals line, independent of the target. This
    -- is what turns the 17:42 export's `hostile=0` from a mystery into a
    -- count: it says how many plates exist, how many expose a readable bar, and
    -- how many were classified each way, so "no plates drawn" and "plates drawn
    -- but not classified" cannot be confused.
    local stats = { bases = 0, readable = 0, friendly = 0, neutral = 0,
        hostile = 0, unknown = 0, decorated = 0, paintedFill = 0, keptFill = 0,
        views = 0, casts = 0, fallbacks = 0, restricted = 0 }
    local found = {}
    for index = 1, 40 do
        local unit = "nameplate" .. index
        if plateFor(unit) then
            stats.bases = stats.bases + 1
            local unitInfo = resolve(unit)
            local class = classify(unit)
            stats[class] = stats[class] + 1
            local record = self.plates and self.plates[unit]
            if unitInfo.bar then
                stats.readable = stats.readable + 1
                if record and record.decorated then stats.decorated = stats.decorated + 1 end
                if record and record.painted then stats.paintedFill = stats.paintedFill + 1
                elseif record then stats.keptFill = stats.keptFill + 1 end
            end
            if record then
                if record.viewActive then stats.views = stats.views + 1 end
                if record.castActive then stats.casts = stats.casts + 1 end
                if record.viewReason then stats.fallbacks = stats.fallbacks + 1 end
            end
            local hp, hpMax = unitHealth(unit)
            if not (app.Capabilities.Plain(hp, "number") and app.Capabilities.Plain(hpMax, "number")) then
                stats.restricted = stats.restricted + 1
            end
            if #found < limit then
                found[#found + 1] = { unit = unit, info = unitInfo, class = class, record = record }
            end
        end
    end
    app:Print(string.format(
        "  plates: bases=%d readable=%d friendly=%d neutral=%d hostile=%d unknown=%d decorated=%d painted=%d keptFill=%d",
        stats.bases, stats.readable, stats.friendly, stats.neutral, stats.hostile,
        stats.unknown, stats.decorated, stats.paintedFill, stats.keptFill))
    -- The own layer is reported next to the repaint: a plate can be repainted
    -- and still show the native text, and only this line says which one the
    -- player is looking at.
    app:Print(string.format("  view: mode=%s active=%d cast=%d restricted=%d fallback=%d direct=%s native=%s",
        self.owned and "owned" or "native", stats.views, stats.casts, stats.restricted, stats.fallbacks,
        self.direct and "on" or "off", tostring(self.nativeMode or "hide")))
    app:Print("  hooks: " .. (self.hookStates and #self.hookStates > 0
        and table.concat(self.hookStates, ",") or "none"))
    if stats.bases == 0 then
        app:Print("  " .. app.L.nameplatesNoVisible)
    else
        for _, entry in ipairs(found) do
            local unitInfo = entry.info
            local health, maximum = unitHealth(entry.unit)
            health = app.Capabilities.Plain(health, "number")
            maximum = app.Capabilities.Plain(maximum, "number")
            local healthState = health and maximum and "plain" or "restricted"
            app:Print(string.format(
                "  %s: class=%s owner=%s frame=%s modern=%s legacy=%s bar=%s decorated=%s fill=%s health=%s target=%s",
                entry.unit, entry.class,
                entry.record and "luma" or "native",
                yes(unitInfo.frame ~= nil), stateWord(unitInfo.modern),
                stateWord(unitInfo.legacy),
                unitInfo.bar and (unitInfo.source or "ok") or tostring(unitInfo.reason or "?"),
                yes(entry.record and entry.record.decorated),
                entry.record and (entry.record.painted and "luma" or "native") or "-",
                healthState,
                yes(isTargetUnit(entry.unit))))
            local record = entry.record
            app:Print(string.format("    view=%s cast=%s",
                record and record.viewActive and "luma" or (record and record.viewReason or "native"),
                record and record.castActive and "luma" or "native"))
            -- Where each visible piece comes from, and the real rectangles. The
            -- own rectangle is the layer's frame; the native one is the bar the
            -- client sizes. "?" means the number was not readable.
            local drawn = record and record.viewActive
            app:Print(string.format("    rect=%s native=%s kind=%s",
                rectWord(record and record.view and record.view.frame),
                rectWord(unitInfo.bar), objectKind(unitInfo.bar)))
            local nativeName = record and record.frame and record.frame.name
            local nameShown = "none"
            if object(nativeName) and not isForbidden(nativeName) and type(nativeName.IsShown) == "function" then
                local okShown, shown = pcall(nativeName.IsShown, nativeName)
                shown = okShown and app.Capabilities.Plain(shown, "boolean")
                nameShown = shown == true and "shown" or (shown == false and "hidden" or "?")
            end
            -- The own name's real state: shown, text length (a count, never
            -- the text), measured width and effective alpha, plus the rail's.
            local ownName = record and record.view and record.view.name
            local ownInfo = "none"
            if object(ownName) then
                local function plainCall(method)
                    if type(ownName[method]) ~= "function" then return nil end
                    local okCall, value = pcall(ownName[method], ownName)
                    return okCall and app.Capabilities.Plain(value) or nil
                end
                local text = plainCall("GetText")
                local width, alpha = plainCall("GetStringWidth"), plainCall("GetEffectiveAlpha")
                ownInfo = string.format("shown=%s len=%s width=%s alpha=%s",
                    tostring(plainCall("IsShown")), type(text) == "string" and #text or "?",
                    width and string.format("%.0f", width) or "?",
                    alpha and string.format("%.2f", alpha) or "?")
            end
            app:Print("    nativeName=" .. nameShown .. " ownName: " .. ownInfo)
            app:Print(string.format("    draw: health=%s name=%s pct=%s fill=%s panel=%s dim=%s border=%s hooks=%s",
                drawn and (record.healthPath or "direct") or "native",
                drawn and tostring(record.nameState or "?") or "native",
                drawn and tostring(record.percentSource or "none") or "-",
                drawn and self.nativeMode == "hide" and "hidden" or "native",
                record and partState(record, "panel") or "native",
                record and partState(record, "dim") or "native",
                record and partState(record, "border") or "native",
                record and record.hooks and #record.hooks > 0 and table.concat(record.hooks, ",") or "-"))
        end
    end
    if type(GetCVar) == "function" then
        app:Print(string.format("  nameplateShowEnemies=%s", enemies or "?"))
        app:Print(string.format("  nameplateShowFriends=%s", friends or "?"))
    end
    if not info.plate and available then app:Print("  " .. app.L.nameplatesMissing) end
end
