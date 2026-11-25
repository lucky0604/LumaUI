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
        value = ok and app.Capabilities.Plain(value, "boolean") or nil
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

-- The client's plate panel is a separate texture/frame behind the health bar.
-- Covering it with a tall own card looked like a black block; instead hide the
-- candidates while LumaUI owns the plate and put them back on release. Only
-- recorded, shown objects are touched, so an unknown build simply keeps its
-- panel.
local PANEL_FIELDS = { "Background", "background", "healthBarBackground" }

local function hideNativePanel(record)
    if record.nativePanel ~= nil then return end
    record.nativePanel = {}
    local frame = record.frame
    local list = {}
    for _, field in ipairs(PANEL_FIELDS) do
        list[#list + 1] = frame[field]
    end
    local container = frame.HealthBarsContainer
    if object(container) then
        list[#list + 1] = container.Background
        list[#list + 1] = container.background
    end
    -- 12.1.5 (Blizzard_NamePlates.xml): the visible plate border is
    -- healthBar.bgTexture and the uns elected dim is healthBar.deselectedOverlay.
    -- These are the real fields, not guesses from field names.
    local bar = record.bar
    if object(bar) then
        list[#list + 1] = bar.bgTexture
        list[#list + 1] = bar.deselectedOverlay
    end
    for _, panel in ipairs(list) do
        if object(panel) and type(panel.IsShown) == "function" and type(panel.SetShown) == "function" then
            local ok, shown = pcall(panel.IsShown, panel)
            shown = ok and app.Capabilities.Plain(shown, "boolean") or nil
            if shown ~= nil then
                local alpha
                if type(panel.GetAlpha) == "function" then
                    local okAlpha, value = pcall(panel.GetAlpha, panel)
                    alpha = okAlpha and app.Capabilities.Plain(value, "number") or nil
                end
                record.nativePanel[#record.nativePanel + 1] = { object = panel, shown = shown, alpha = alpha }
                pcall(panel.SetShown, panel, false)
                -- Alpha 0 survives the client re-showing deselectedOverlay on a
                -- target change; SetShown(false) alone does not.
                if alpha and type(panel.SetAlpha) == "function" then
                    pcall(panel.SetAlpha, panel, 0)
                end
            end
        end
    end
end

local function restoreNativePanel(record)
    for _, entry in ipairs(record.nativePanel or {}) do
        if object(entry.object) then
            if entry.alpha and type(entry.object.SetAlpha) == "function" then
                pcall(entry.object.SetAlpha, entry.object, entry.alpha)
            end
            pcall(entry.object.SetShown, entry.object, entry.shown)
        end
    end
    record.nativePanel = nil
end

-- Overlay tints that survive the client's own bar updates. The native fill is
-- the only truthful health source when UnitHealth is secret; a translucent own
-- texture above it changes the palette without touching the value.
local RESTRICTED_TINTS = {
    hostile = { 0.32, 0.04, 0.04, 0.46 },
    neutral = { 0.26, 0.20, 0.03, 0.42 },
    friendly = { 0.03, 0.22, 0.08, 0.40 },
}
local restrictedSkin

-- Restyle the client's own name text instead of drawing a second FontString.
-- Hiding the native name was what made the field report's plates look nameless
-- when the own overlay was not visible.
local function styleName(record)
    local name = record.frame and record.frame.name
    if not object(name) then return end
    if not record.nameStyle then
        local style = {}
        if type(name.GetFont) == "function" then
            local ok, path, size, flags = pcall(name.GetFont, name)
            if ok and path then style.path, style.size, style.flags = path, size, flags end
        end
        if type(name.GetTextColor) == "function" then
            local ok, red, green, blue = pcall(name.GetTextColor, name)
            if ok and red ~= nil then style.color = { red, green, blue } end
        end
        record.nameStyle = style
    end
    if type(name.SetFont) == "function" then
        pcall(name.SetFont, name, app.Type:Face(), 10, "OUTLINE")
    end
    local text = app.Theme.colors.text
    if type(name.SetTextColor) == "function" then
        pcall(name.SetTextColor, name, text[1], text[2], text[3])
    end
    if type(name.SetShadowOffset) == "function" then pcall(name.SetShadowOffset, name, 1, -1) end
end

local function restoreName(record)
    local name = record.frame and record.frame.name
    local style = record.nameStyle
    if not object(name) or not style then return end
    if style.path and type(name.SetFont) == "function" then
        pcall(name.SetFont, name, style.path, style.size, style.flags)
    end
    if style.color and type(name.SetTextColor) == "function" then
        pcall(name.SetTextColor, name, style.color[1], style.color[2], style.color[3])
    end
    record.nameStyle = nil
end

local function updateView(self, unit)
    local record = self.plates and self.plates[unit]
    if not record then return end
    local view = record.view
    if not self.owned then
        if view then app.PlateView:ClearCast(view); view.frame:Hide() end
        stopCastTicker(record)
        setNativeBarAlpha(record, true)
        setNativeNameShown(record, true)
        restoreNativePanel(record)
        record.viewActive = nil
        return
    end
    view = view or ensureView(record)
    record.view = view
    if not view then
        record.viewReason = "view-unavailable"
        return
    end
    app.PlateView:ShowTrack(view)
    app.PlateView:SetTint(view, nil)
    local health, maximum = unitHealth(unit)
    if not app.PlateView:SetHealth(view, health, maximum) then
        -- Restricted health: no truthful own fill and no own text layer. Keep
        -- the client's fill and name, restyle both in place, and drop the
        -- client's plate border/dim. The hooks reapply after the client's own
        -- update functions reset the bar.
        app.PlateView:ClearCast(view)
        view.frame:Hide()
        restrictedSkin(self, record)
        styleName(record)
        hideNativePanel(record)
        setNativeBarAlpha(record, true)
        setNativeNameShown(record, true)
        record.viewActive = nil
        record.viewReason = "restricted-health"
        return
    end
    record.viewReason = nil
    record.viewActive = true
    app.PlateView:SetUnit(view, unit)
    -- Keep the client's reaction colour for the own track. UnitColor is only a
    -- fallback: a neutral NPC can be drawn green by the client, and the own
    -- layer must not turn the same plate yellow just because the numeric
    -- reaction reads "neutral".
    local original = self.originals[record.bar]
    if original and original.color then app.PlateView:SetColor(view, original.color) end
    local named = app.PlateView:SetName(view, unitName(unit))
    if named and not setNativeNameShown(record, false) then
        app.PlateView:SetName(view, nil)
        named = false
    end
    app.PlateView:SetTarget(view, record.target == true)
    view.frame:Show()
    hideNativePanel(record)
    -- Only the parts the own layer actually drew are dimmed.
    setNativeBarAlpha(record, false)
    setNativeNameShown(record, not named)
    updateCast(self, unit)
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
-- even when no colour was available.
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
    if type(bar.GetHeight) == "function" then
        local ok, height = pcall(bar.GetHeight, bar)
        height = ok and plainNumber(height) or nil
        if height and height > 0 then original.height = height end
    end
    self.originals[bar] = original
    return original
end

-- Fallback when the client restricts the health payload: the own layer cannot
-- draw a truthful number, but the native bar can still lose the client's glossy
-- texture and oversized height. Only recorded properties are rewritten, so the
-- client's look comes back with the same release path.
-- Reapply after the client's own update functions. Hooks are global, but only
-- bars/frames marked with the current record are touched, and only while the
-- component is running and the own style is enabled.
local function reskin(record)
    if not record or not component or not component.running or not component.owned then return end
    restrictedSkin(component, record, true)
    styleName(record)
    hideNativePanel(record)
end

local function reskinBar(bar)
    reskin(bar and bar.lumaNameplateRecord)
end

local function reskinName(frame)
    reskin(frame and frame.lumaNameplateRecord)
end

-- The fallback also owns a muted palette: the client's bright yellow/green
-- neutral fill looked like a raw bar glued to the dark plate. The colour is a
-- fixed constant per classification, never derived from health, and is only
-- written when the original colour was readable and recorded.
local RESTRICTED_COLORS = {
    hostile = { 0.62, 0.26, 0.24 },
    neutral = { 0.62, 0.55, 0.28 },
    friendly = { 0.35, 0.60, 0.42 },
}
restrictedSkin = function(self, record, force)
    if record.restrictedSkin and not force then return end
    local bar = record.bar
    local original = bar and self.originals[bar]
    if not original or isForbidden(bar) then return end
    record.restrictedSkin = true
    if original.texture and type(bar.SetStatusBarTexture) == "function" then
        pcall(bar.SetStatusBarTexture, bar, app.Theme.media.combatFill)
    end
    if original.height and original.height > 9 and type(bar.SetHeight) == "function" then
        pcall(bar.SetHeight, bar, 8)
    end
    local color = RESTRICTED_COLORS[record.class]
    if original.color and color and type(bar.SetStatusBarColor) == "function" then
        pcall(bar.SetStatusBarColor, bar, color[1], color[2], color[3], 1)
    end
end

-- Puts one recorded bar back. Only the properties that were actually changed
-- are restored; a restricted object is skipped instead of being written to.
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
    if type(bar.SetHeight) == "function" and original.height then
        pcall(bar.SetHeight, bar, original.height)
    end
    if bar.lumaNameplateBg then bar.lumaNameplateBg:Hide() end
    if bar.lumaNameplateEdge then bar.lumaNameplateEdge:Hide() end
    if bar.lumaNameplateMark then bar.lumaNameplateMark:Hide() end
    if bar.lumaNameplateTarget then bar.lumaNameplateTarget:Hide() end
    if bar.lumaNameplateHolder then bar.lumaNameplateHolder:Hide() end
end

local function restoreAll(self)
    for _, record in pairs(self.plates or {}) do
        stopCastTicker(record)
        setNativeBarAlpha(record, true)
        setNativeNameShown(record, true)
        restoreName(record)
        if record.bar and record.bar.lumaNameplateRecord == record then record.bar.lumaNameplateRecord = nil end
        if record.frame and record.frame.lumaNameplateRecord == record then record.frame.lumaNameplateRecord = nil end
        restoreNativePanel(record)
        if record.view then
            app.PlateView:ClearCast(record.view)
            record.view.frame:Hide()
        end
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
        enemy = ok and app.Capabilities.Plain(enemy, "boolean") or nil
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
    stopCastTicker(record)
    setNativeBarAlpha(record, true)
    setNativeNameShown(record, true)
    restoreName(record)
    restoreNativePanel(record)
    if record.view then
        app.PlateView:ClearCast(record.view)
        record.view.frame:Hide()
    elseif record.plate and record.plate.lumaPlateView then
        record.plate.lumaPlateView.frame:Hide()
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
    local record = remember(self, bar)
    local target = isTargetUnit(unit)
    local enemy = hostile(unit)
    local decorated = paint(bar, unit, record, target, enemy)
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
    state.painted = enemy and record.paintable
        and type(bar.SetStatusBarColor) == "function"
    self.plates[unit] = state
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
            if not isForbidden(record.bar) then decorateSafely(record.bar, target) end
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
        -- The client resets barTexture/bgTexture in UpdateAnchors and the fill
        -- colour in UpdateHealthColor (12.1.5 source). Reapply after those
        -- functions for our marked bars only; this is why the earlier direct
        -- writes never stayed on screen.
        if not self.hooksInstalled and type(hooksecurefunc) == "function" then
            self.hooksInstalled = true
            local barMixin = _G.NamePlateHealthBarMixin
            if type(barMixin) == "table" then
                for _, method in ipairs({ "UpdateHealthColor", "UpdateSelectionBorder" }) do
                    if type(barMixin[method]) == "function" then
                        pcall(hooksecurefunc, barMixin, method, function(bar) reskinBar(bar) end)
                    end
                end
            end
            local frameMixin = _G.NamePlateUnitFrameMixin
            if type(frameMixin) == "table" and type(frameMixin.UpdateAnchors) == "function" then
                pcall(hooksecurefunc, frameMixin, "UpdateAnchors", function(frame)
                    local bar = frame and frame.HealthBarsContainer and frame.HealthBarsContainer.healthBar
                    reskinBar(bar)
                end)
            end
            if type(_G.CompactUnitFrame_UpdateName) == "function" then
                pcall(hooksecurefunc, "CompactUnitFrame_UpdateName", function(frame) reskinName(frame) end)
            end
        end
        scan(self)
        attachTarget(self)
        if app.Ownership then
            app.Ownership:Set("nameplates", { intent = "styled", active = "styled",
                evidence = "simulated", reason = self.lastReason })
        end
    end,
    Refresh = function(self)
        local ui = app.Store:Profile().ui
        self.owned = ui.plateOwned == true
        self.plateCast = ui.plateCast == true
        scan(self)
        attachTarget(self)
        for unit in pairs(self.plates or {}) do updateView(self, unit) end
    end,
    Disable = function(self)
        restoreAll(self)
        if app.Ownership then
            app.Ownership:Active("nameplates", "native", "component-off")
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

function component:Diagnose()
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
        views = 0, casts = 0, restrictedViews = 0 }
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
                if record.viewReason then stats.restrictedViews = stats.restrictedViews + 1 end
            end
            if #found < 5 then
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
    app:Print(string.format("  view: mode=%s active=%d cast=%d restricted=%d",
        self.owned and "owned" or "native", stats.views, stats.casts, stats.restrictedViews))
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
        end
    end
    if type(GetCVar) == "function" then
        app:Print(string.format("  nameplateShowEnemies=%s", enemies or "?"))
        app:Print(string.format("  nameplateShowFriends=%s", friends or "?"))
    end
    if not info.plate and available then app:Print("  " .. app.L.nameplatesMissing) end
end
