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
    chip:SetColorTexture(accent[1], accent[2], accent[3], 0.98)
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

-- Repaints a hostile bar with the unit's gradient pair when the previous colour
-- was readable, then always adds the decorations. A friendly bar keeps the
-- client's reaction colour, and a bar whose colour cannot be read keeps its
-- native fill: the record could not put it back.
local function paint(bar, unit, record, isTarget, enemy)
    if not bar then return end
    if enemy and record and record.paintable and type(bar.SetStatusBarColor) == "function"
        and not isForbidden(bar) then
        if type(bar.SetStatusBarTexture) == "function" then
            pcall(bar.SetStatusBarTexture, bar, app.Theme.media.bar)
        end
        app.Theme:PaintBar(bar, app.Theme:UnitColor(unit))
    end
    decorateSafely(bar, isTarget)
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
    self.originals[bar] = original
    return original
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
    if bar.lumaNameplateBg then bar.lumaNameplateBg:Hide() end
    if bar.lumaNameplateEdge then bar.lumaNameplateEdge:Hide() end
    if bar.lumaNameplateMark then bar.lumaNameplateMark:Hide() end
    if bar.lumaNameplateTarget then bar.lumaNameplateTarget:Hide() end
    if bar.lumaNameplateHolder then bar.lumaNameplateHolder:Hide() end
end

local function restoreAll(self)
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

-- Only a confirmed hostile plate is touched. `UnitIsEnemy` is a cheap plain
-- boolean; a restricted answer is not proof of hostility, so the plate keeps its
-- native look.
local function hostile(unit)
    if type(UnitIsEnemy) ~= "function" then return false end
    local ok, enemy = pcall(UnitIsEnemy, "player", unit)
    enemy = ok and app.Capabilities.Plain(enemy, "boolean") or nil
    return enemy == true
end

local attach, retry

local function releaseUnit(self, unit)
    local record = self.plates[unit]
    if not record then return end
    self.plates[unit] = nil
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
    paint(bar, unit, record, target, enemy)
    self.lastReason = "ok"
    -- A styled plate clears its attempt count, so a later appearance of the same
    -- unit token gets a fresh pair of retries instead of inheriting failures.
    if self.retries then self.retries[unit] = nil end
    self.plates[unit] = {
        unit = unit, bar = bar, source = info.source, target = target, enemy = enemy,
    }
    return true
end

-- Reasons that only mean "not ready yet". A restricted or unsupported bar is a
-- real limitation of this build and is never retried.
local TRANSIENT = { ["no-plate"] = true, ["no-unit-frame"] = true, ["no-health-bar"] = true }

-- One short retry per unit and plate appearance. The timer is one-shot, checks
-- `running` and whether the plate is already owned, so a discontinued component
-- or a plate that vanished in the meantime costs nothing. The callback runs
-- outside the combat queue: it only reads and decorates, never a protected frame.
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
    C_Timer.After(0.25, function()
        if not self.running or self.plates[unit] then return end
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

component = app:RegisterComponent({ id = "nameplates", label = "nameplates", defaultEnabled = true,
    Supported = function()
        local api = _G.C_NamePlate
        return type(api) == "table" and type(api.GetNamePlateForUnit) == "function"
    end,
    Enable = function(self)
        self.originals = self.originals or {}
        self.plates = self.plates or {}
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
            attach(current, "target")
            markTarget(current)
        end)
        self:Listen("PLAYER_ENTERING_WORLD", function(current)
            scan(current)
            attach(current, "target")
            markTarget(current)
        end)
        scan(self)
        attach(self, "target")
        markTarget(self)
    end,
    Refresh = function(self)
        scan(self)
        attach(self, "target")
        markTarget(self)
    end,
    Disable = function(self)
        restoreAll(self)
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
    return string.format("nameplates: %s=%d hostile=%d last=%s",
        app.L.nativePlatesPainted, count, hostileCount, tostring(self.lastReason or "none"))
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
    -- Plate inventory, independent of the target: this is the line that answers
    -- "is there anything on screen to style at all". Three plates are enough to
    -- tell a field-name mismatch from an empty scene.
    local found = {}
    for index = 1, 40 do
        local unit = "nameplate" .. index
        if plateFor(unit) then found[#found + 1] = unit end
        if #found >= 3 then break end
    end
    if #found == 0 then
        app:Print("  " .. app.L.nameplatesNoVisible)
    else
        for _, unit in ipairs(found) do
            local unitInfo = resolve(unit)
            app:Print(string.format("  %s: frame=%s modern=%s legacy=%s bar=%s", unit,
                yes(unitInfo.frame ~= nil), stateWord(unitInfo.modern),
                stateWord(unitInfo.legacy),
                unitInfo.bar and (unitInfo.source or "ok") or tostring(unitInfo.reason or "?")))
        end
    end
    if type(GetCVar) == "function" then
        app:Print(string.format("  nameplateShowEnemies=%s", enemies or "?"))
        app:Print(string.format("  nameplateShowFriends=%s", friends or "?"))
    end
    if not info.plate and available then app:Print("  " .. app.L.nameplatesMissing) end
end
