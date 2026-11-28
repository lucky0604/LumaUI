local _, app = ...
local U = app.Theme.units

-- The main health bars start at the same fraction of the screen as the mockup;
-- the frame top includes the name row above the health bar. Auxiliary units are
-- shorter, use the compact metrics below and sit in the inner half of their
-- parent's column, which keeps them away from the chat side and the action area.
local TOP_FRACTION = 0.69
local AUX_GAP = 6
local FOCUS_GAP = 6
local PLAYER_CAST_ID = "unit_player_cast"
local PLAYER_CAST_HEIGHT = 18
local PLAYER_CAST_INSET = 8

local PARTS_ALL = { bars = true, cast = true, auras = true, marks = true, interaction = true }
-- The player cast is the client's own central bar (or its edit-mode placeholder);
-- drawing another inline copy would duplicate it. The target keeps the inline
-- cast so target casts still work through the existing part.
local PARTS_PLAYER = { bars = true, auras = true, marks = true, interaction = true }
local PARTS_MINOR = { bars = true, marks = true, interaction = true }

local function metrics(style)
    if style == "minor" then
        return {
            width = U.minorWidth, nameRow = U.minorNameRow, health = U.minorHealth,
            power = U.minorPower, powerGap = U.minorPowerGap, nameSize = U.minorNameSize,
            valueWidth = 42, nameReserve = 50,
            cast = U.cast, castGap = U.castGap, aura = U.aura, auraStep = U.auraStep, auraGap = U.auraGap,
        }
    end
    return {
        width = U.width, nameRow = U.nameRow, health = U.health, power = U.power,
        powerGap = U.powerGap, nameSize = U.nameSize, valueWidth = 64, nameReserve = 72,
        cast = U.cast, castGap = U.castGap, aura = U.aura, auraStep = U.auraStep, auraGap = U.auraGap,
    }
end
local MAIN, MINOR = metrics("main"), metrics("minor")

local specs = {
    { unit = "player", style = "main", parts = PARTS_PLAYER, side = -1 },
    { unit = "target", style = "main", parts = PARTS_ALL, side = 1 },
    { unit = "targettarget", style = "minor", parts = PARTS_MINOR, side = 1, parent = "target" },
    { unit = "focus", style = "minor", parts = PARTS_MINOR, side = 1, parent = "target", above = true },
    { unit = "pet", style = "minor", parts = PARTS_MINOR, side = -1, parent = "player" },
}

-- Part availability is diagnostic only; it does not prove native parity.
local REPLACEMENT_PARTS = { "bars", "cast", "auras" }
local FRAME_EVENTS = { "PLAYER_ENTERING_WORLD", "PLAYER_TARGET_CHANGED", "PLAYER_FOCUS_CHANGED", "UNIT_PET" }
local component

-- Runs every available part in its own error-isolated call. Event payloads are
-- ignored for dispatch, so restricted unit tokens from events never reach
-- component logic, and unit values only ever touch native drawing methods
-- inside the parts. The frame height is deliberately NOT written here:
-- resizing a secure unit button is a protected change, and events fire during
-- combat, so the height only moves through the queued job below.
local function partAllowed(frame, id)
    if not frame.partsFilter or frame.partsFilter[id] ~= true then return false end
    -- Per-part switches: a part the player turned off is not drawn and does not
    -- take a row in the frame height, so the frame closes up instead of leaving
    -- a gap where the aura row used to be.
    local off = app.Store and app.Store:Profile().ui.unitParts
    if type(off) == "table" and off[id] == false and id ~= "bars" then return false end
    return true
end

local function drawFrame(frame)
    local parts = component.parts
    if not parts then return end
    for _, part in ipairs(parts.active) do
        if partAllowed(frame, part.id) then
            app:Call("unit/" .. frame.unitToken .. "/" .. part.id, part.draw, frame)
        end
    end
end

-- One event only redraws the parts that subscribed to it: a health tick must
-- not rebuild the cast timer and a proc glow must not repaint the bars.
local function drawEvent(frame, event)
    local subscribed = frame.eventParts and frame.eventParts[event]
    if not subscribed then
        drawFrame(frame)
        return
    end
    for _, part in ipairs(subscribed) do
        if partAllowed(frame, part.id) then
            app:Call("unit/" .. frame.unitToken .. "/" .. part.id, part.draw, frame)
        end
    end
end

local function partsHeight(parts, frame)
    local height = frame.baseHeight
    for _, part in ipairs(parts.active) do
        if partAllowed(frame, part.id) then height = height + (part.height or 0) end
    end
    return height
end

-- Resizing the secure frame is queued (per-frame key, latest intent wins), so
-- a height change from a parts-availability shift waits for the fight to end.
local function applyHeight(self, frame)
    local height = partsHeight(self.parts, frame)
    app.Queue:Run("unitFrames/height/" .. frame.unitToken, function()
        if frame:GetHeight() ~= height then frame:SetHeight(height) end
    end)
end

local function create(spec)
    local m = spec.style == "minor" and MINOR or MAIN
    local frame = CreateFrame("Button", "LumaUIUnit_" .. spec.unit, UIParent, "SecureUnitButtonTemplate,BackdropTemplate")
    frame:Hide()
    frame.metrics = m
    frame.partsFilter = spec.parts
    frame.baseHeight = m.nameRow + m.health + m.power + m.powerGap
    frame:SetSize(m.width, frame.baseHeight)
    frame.unitToken = spec.unit
    frame.unitSide = spec.side
    frame.unitParent = spec.parent
    frame.unitAbove = spec.above
    frame.partsCreated = {}
    frame.events = CreateFrame("Frame")
    frame.events:SetScript("OnEvent", function(_, event)
        app:Call("unit/" .. spec.unit, drawEvent, frame, event)
    end)
    app.Layout:Register("unit_" .. spec.unit, frame, 0, 0, app.L.unitFrames .. " · " .. spec.unit)
    return frame
end

-- A part that was unavailable on a previous enable but exists now still gets
-- its controls before its events register; each part only builds once.
local function ensureParts(parts, frame)
    for _, part in ipairs(parts.active) do
        if partAllowed(frame, part.id) and not frame.partsCreated[part.id] then
            frame.partsCreated[part.id] = true
            part.create(frame)
        end
    end
end

-- Merges every available part's events into frame.events: unit events are
-- registered per unit, global events once per frame. Parts without their
-- client API contribute nothing.
local function attachEvents(parts, frame, unit)
    frame.eventParts = {}
    for _, part in ipairs(parts.active) do
        if partAllowed(frame, part.id) then
            for _, event in ipairs(part.events or {}) do
                -- A single event name the current build lacks must not fail the
                -- whole component; the handler simply never fires.
                pcall(frame.events.RegisterUnitEvent, frame.events, event, unit)
                local list = frame.eventParts[event]
                if not list then list = {}; frame.eventParts[event] = list end
                list[#list + 1] = part
            end
            for _, event in ipairs(part.globalEvents or {}) do
                pcall(frame.events.RegisterEvent, frame.events, event)
                local list = frame.eventParts[event]
                if not list then list = {}; frame.eventParts[event] = list end
                list[#list + 1] = part
            end
        end
    end
    for _, event in ipairs(FRAME_EVENTS) do
        pcall(frame.events.RegisterEvent, frame.events, event)
    end
end

-- Disabled frames must release everything at once: events, the unit watch,
-- any cast ticker and any part control a previous cycle left on screen.
local function hidePartControls(frame)
    if frame.cast then
        if frame.cast.updater then frame.cast.updater:Cancel(); frame.cast.updater = nil end
        if frame.cast:IsShown() then frame.cast:Hide() end
    end
    if frame.auraTicker then frame.auraTicker:Cancel(); frame.auraTicker = nil end
    for _, icon in ipairs(frame.auraIcons or {}) do
        if icon.count then icon.count:SetText("") end
        if icon.time then icon.time:SetText("") end
        if icon:IsShown() then icon:Hide() end
    end
    if frame.statusText then frame.statusText:SetText("") end
    if frame.mark and frame.mark:IsShown() then frame.mark:Hide() end
end

local function missingParts(parts)
    local missing = {}
    for _, id in ipairs(REPLACEMENT_PARTS) do
        local part = parts and parts[id]
        if not part or part.available ~= true then missing[#missing + 1] = id end
    end
    return missing
end

local function activePartIds(parts)
    local set = {}
    for _, part in ipairs(parts.active) do set[part.id] = true end
    return set
end

-- Capability probes establish what the replacement can draw. The Pearl batch
-- enables the takeover by default; the per-profile switch stays reversible
-- (/luma takeover), and a missing replacement part or private-aura API always
-- wins the native frame back instead of leaving two copies on screen.
local TAKEOVER_FRAMES = { "PlayerFrame", "TargetFrame", "FocusFrame", "PetFrame", "TargetFrameToT" }

local function nativeFrameOf(name)
    local frame = _G[name]
    if frame and type(frame.Hide) == "function" and type(frame.Show) == "function" then return frame end
end

local function frameShown(frame)
    if not frame or type(frame.IsShown) ~= "function" then return false end
    local ok, shown = pcall(frame.IsShown, frame)
    return ok and shown == true
end

local function suppressNativeFrames(self)
    if not self.nativeShown then
        self.nativeShown = {}
        for _, name in ipairs(TAKEOVER_FRAMES) do
            local frame = nativeFrameOf(name)
            if frame then
                self.nativeShown[name] = { shown = frameShown(frame) }
                -- Target/player frames are re-shown by the client on target
                -- changes. A one-shot Hide leaves a second copy behind; the
                -- hook keeps them down until takeover is switched off.
                if not frame.lumaUnitHideHook and type(frame.HookScript) == "function" then
                    frame.lumaUnitHideHook = true
                    pcall(frame.HookScript, frame, "OnShow", function(shownFrame)
                        local owner = component
                        if not (owner and owner.running and owner.takeover
                            and owner.takeover.units == true) then return end
                        local function hide()
                            if owner.running and owner.takeover
                                and owner.takeover.units == true then
                                pcall(shownFrame.Hide, shownFrame)
                            end
                        end
                        if type(InCombatLockdown) == "function" and InCombatLockdown() then
                            app.Queue:Run("unitFrames/native", hide)
                        else
                            hide()
                        end
                    end)
                end
            end
        end
    end
    self.nativeSuppressed = true
    app.Queue:Run("unitFrames/native", function()
        if not component.running or not component.nativeSuppressed then return end
        for _, name in ipairs(TAKEOVER_FRAMES) do
            local state = component.nativeShown and component.nativeShown[name]
            if state and state.shown then
                local frame = nativeFrameOf(name)
                if frame and frameShown(frame) then pcall(frame.Hide, frame) end
            end
        end
    end)
end

local function restoreNativeFrames(self)
    local shown = self.nativeShown
    self.nativeSuppressed = nil
    self.nativeShown = nil
    if not shown then return end
    app.Queue:Run("unitFrames/native", function()
        if component.running and component.nativeSuppressed then return end
        for _, name in ipairs(TAKEOVER_FRAMES) do
            if shown[name] and shown[name].shown then
                local frame = nativeFrameOf(name)
                if frame and not frameShown(frame) then pcall(frame.Show, frame) end
            end
        end
    end)
end

local function applyTakeover(self)
    local missing = missingParts(self.parts)
    -- The switch reads the profile every evaluation, so /luma takeover applies
    -- without an enable cycle. Missing parts or an unavailable private-aura
    -- anchor API keep every native frame: without anchors an encounter's
    -- private auras would have nowhere to draw.
    -- The native buff/debuff frames keep drawing the player's private auras;
    -- the client anchors them to PlayerFrame.unit, not to anything this
    -- preview draws, so hiding the player frame does not orphan them.
    local wanted = app.Store:Profile().ui.takeoverUnitFrames == true
    local anchored = app.PrivateAuras.Available()
    local units = wanted and anchored and #missing == 0
    -- The target's inline cast bar rides on the same part set, while the
    -- player's own cast bar stays the client's in every mode. Recording both
    -- under one flag is what made the old report look like it claimed the
    -- player cast too (012 phase 00).
    local cast = wanted and anchored and #missing == 0
    self.takeover = { units = units, cast = cast, playerCast = false, missing = missing }
    if app.Ownership then
        local reason
        if not wanted then reason = "profile-native"
        elseif not anchored then reason = "no-private-aura-api"
        elseif #missing > 0 then reason = "missing-parts" end
        app.Ownership:Set("unitFrames", {
            intent = wanted and "owned" or "native",
            active = units and "owned" or "native",
            evidence = "simulated", reason = reason,
        })
        -- Player cast ownership is its own row: native in every mode until a
        -- replacement is validated on the live client.
        app.Ownership:Set("unitFrames.playerCast", {
            intent = "native", active = "native", evidence = "none",
        })
        app.Ownership:Set("unitFrames.targetCast", {
            intent = wanted and "owned" or "native",
            active = cast and "owned" or "native",
            evidence = "none", reason = cast and "awaiting-validation" or reason,
        })
        -- Aura layers are separate owners: the unit frames draw the normal
        -- rows, the client draws the full buff row and every private anchor.
        -- Reporting them apart is what stops "auras are native" from hiding
        -- the fact that a unit frame replaced its own two rows (012 phase 09).
        app.Ownership:Set("unitFrames.auras", {
            intent = wanted and "owned" or "native",
            active = units and "owned" or "native",
            evidence = "simulated", reason = reason,
        })
        -- 015 phase 10: every drawn part reports on its own (bars, cast, auras,
        -- marks, interaction), so a part the client still owns is visible.
        local absent = {}
        for _, id in ipairs(missing) do absent[id] = true end
        for _, part in ipairs(self.parts and self.parts.active or {}) do
            if type(part.id) == "string" and part.id:match("^[%a][%w_]*$") then
                local gone = absent[part.id] == true
                app.Ownership:Set("unitFrames.part." .. part.id, {
                    intent = wanted and "owned" or "native",
                    active = (units and not gone) and "owned" or "native",
                    evidence = "simulated",
                    reason = gone and "missing-parts" or (not units) and reason or nil,
                })
            end
        end
        app.Ownership:Set("auraEdge", { intent = "native", active = "native",
            evidence = "none", reason = "client-buffs-kept" })
        app.Ownership:Set("auraPrivate", { intent = "native", active = "native",
            evidence = "none", reason = "client-anchored" })
    end
    if units then
        suppressNativeFrames(self)
    else
        restoreNativeFrames(self)
    end
    -- When takeover was requested but a part or the private-aura API is
    -- missing, the preview must step aside instead of drawing a second set of
    -- unit frames next to the native ones.
    for _, frame in pairs(self.frames or {}) do
        if wanted and not units then
            if frame.lumaUnitWatched then
                pcall(UnregisterUnitWatch, frame)
                frame.lumaUnitWatched = nil
            end
            if frame:IsShown() then pcall(frame.Hide, frame) end
        elseif not frame.lumaUnitWatched then
            frame.lumaUnitWatched = pcall(RegisterUnitWatch, frame) or nil
        end
    end
    if #missing > 0 and not self.warnedMissing then
        self.warnedMissing = true
        app:Print(string.format(app.L.unitTakeoverKept, table.concat(missing, ", ")))
    end
end

-- The player cast stays the client's own bar. This outline only reserves the
-- agreed central rectangle in edit mode; it never moves or hides the native
-- cast frame, so a build without a confirmed cast-frame name keeps working.
local function playerCastPlaceholder(self)
    local entry = self.playerCastEntry
    if entry then
        entry.placeholder = true
        return entry
    end
    entry = app.Layout:RegisterPlaceholder(PLAYER_CAST_ID, app.L.playerCastArea, 0, 0, 240, PLAYER_CAST_HEIGHT)
    self.playerCastEntry = entry
    return entry
end

local function positionPlayerCast(self, central)
    local entry = self.playerCastEntry
    if not entry or not entry.frame then return end
    local scale = app.Layout:Scale(PLAYER_CAST_ID)
    if not scale or scale <= 0 then scale = 1 end
    local width = math.max(160, math.min(380, central.action.width * 0.62))
    local height = PLAYER_CAST_HEIGHT
    local bottom = central.action.bottom - PLAYER_CAST_INSET
    local center = bottom - (height * scale) / 2 - central.screen.height / 2
    entry.frame:SetSize(width / scale, height)
    app.Layout:SetEntryDefault(PLAYER_CAST_ID, 0, center / scale)
    app.Layout:Apply(PLAYER_CAST_ID)
end

-- Main health bars share the same screen top; auxiliary frames use the compact
-- metrics and the inner half of their parent's column. Only the entry default is
-- updated here: Layout:Apply still gives a saved manual position precedence.
--
-- 019: the reference line is the *health* bar's top edge, not the frame's. The
-- frame's own top is the name row, so a frame placed by its centre without the
-- name row in the sum sat one text line low. `healthTop` below is that edge and
-- the entry's centre is derived back from it, which is what makes the pair level
-- with the first skill row instead of merely near it.
local function healthEdgeTop(frame)
    -- The health bar's top offset inside the frame is the name row.
    return frame.metrics.nameRow
end

local function updateDefaults(self)
    if not self.frames then return end
    local central = app.Layout:Central()
    local screenHeight = central.screen.height
    -- The main bars align their health top with the applied main skill row
    -- (essential/utility), so the columns read as one block; the mockup
    -- fraction is the fallback until a viewer row is measured.
    local healthTop = screenHeight * (0.5 - TOP_FRACTION)
    local mainTop = central.cooldown.mainTop
    if central.cooldown.applied and mainTop and mainTop > central.cooldown.bottom then
        healthTop = mainTop - screenHeight / 2
    end
    local rows = {}
    for _, spec in ipairs(specs) do
        local frame = self.frames[spec.unit]
        if frame then
            local id = "unit_" .. spec.unit
            local scale = app.Layout:Scale(id)
            if not scale or scale <= 0 then scale = 1 end
            local height = partsHeight(self.parts, frame)
            local width = frame.metrics.width
            local parent = spec.parent and rows[spec.parent]
            local x, top
            if spec.style == "main" then
                x = app.Layout:CentralOffset(id, spec.side)
                -- 015 phase 10 (simulated, default off): on a narrow screen the
                -- left main bar keeps its outer edge clear of the chat column.
                if app.Store:Profile().ui.unitNarrowAvoid == true and spec.side < 0 then
                    local limit = -(central.screen.width / 2 - 360) / scale + width / 2
                    if x < limit then x = limit end
                end
                top = healthTop / scale + frame.metrics.nameRow
            elseif spec.above then
                x = parent and parent.x or app.Layout:CentralOffset(id, spec.side)
                top = (parent and parent.top or (healthTop / scale + frame.metrics.nameRow))
                    + FOCUS_GAP + height
            else
                local mainX = parent and parent.x or app.Layout:CentralOffset(id, spec.side)
                local mainWidth = parent and parent.width or width
                local mainTop = parent and parent.top or (healthTop / scale + frame.metrics.nameRow)
                local mainHeight = parent and parent.height or 0
                x = mainX - spec.side * ((mainWidth - width) / 2)
                top = mainTop - mainHeight - AUX_GAP
            end
            rows[spec.unit] = { x = x, top = top, width = width, height = height }
            -- The entry stores a centre. For the main pair the health edge (not
            -- the frame top) is the anchor, so the centre is the edge minus the
            -- name row and half the frame.
            local centre = top - height / 2
            if spec.style == "main" then
                centre = (healthTop / scale) + healthEdgeTop(frame) - height / 2
            end
            app.Layout:SetEntryDefault(id, x, centre)
            -- A preset writes positions, but the main bars are driven by the
            -- measured block. Follow a new boundary only while the saved centre
            -- still equals the previous automatic one, so a deliberate drag
            -- keeps precedence over the geometry.
            if spec.style == "main" then
                local previous = frame.lumaAutoX
                frame.lumaAutoX = x
                local saved = app.Store:Profile().positions[id]
                if previous and saved and not app.Store.readonly
                    and math.abs(saved.x - previous) < 0.5 and math.abs(x - previous) >= 0.5 then
                    app.Store:SetPosition(id, x, saved.y)
                end
            end
        end
    end
    for _, spec in ipairs(specs) do
        if self.frames[spec.unit] then app.Layout:Apply("unit_" .. spec.unit) end
    end
    -- The preset asks the component for the pair's exact centre instead of
    -- keeping a second fraction of its own. Only the main pair is geometry-owned:
    -- the auxiliary frames keep their presets' deliberate offsets.
    self.centres = self.centres or {}
    for _, spec in ipairs(specs) do
        local row = rows[spec.unit]
        if row then
            self.centres[spec.unit] = { x = row.x, y = row.top - row.height / 2 }
        end
    end
    positionPlayerCast(self, central)
end

-- 019: the stored per-unit appearance. Width, bar heights, name size, aura size,
-- the health format and the colour mode are all read here so the settings page
-- and this renderer share one model; a profile that never opened the page reads
-- the shipped defaults, which equal the constants above.
local function unitConfig(unit)
    local profile = app.Store and app.Store:Profile()
    local list = profile and profile.ui and profile.ui.unitFrames
    return list and list[unit]
end

component = app:RegisterComponent({ id = "unitFrames", label = "unitFrames", defaultEnabled = true,
    Supported = function(_, caps) return caps.units end,
    Enable = function(self)
        self.parts = app.UnitParts.Build()
        self.activeParts = activePartIds(self.parts)
        self.warnedMissing = nil
        self.frames = self.frames or {}
        for _, spec in ipairs(specs) do
            local frame = self.frames[spec.unit]
            if not frame then
                frame = create(spec)
                self.frames[spec.unit] = frame
            end
            ensureParts(self.parts, frame)
            attachEvents(self.parts, frame, spec.unit)
            frame.lumaUnitWatched = pcall(RegisterUnitWatch, frame) or nil
            self:ApplyUnitConfig(spec.unit)
            drawFrame(frame)
            applyHeight(self, frame)
        end
        local castEntry = playerCastPlaceholder(self)
        castEntry.hidden = nil
        updateDefaults(self)
        -- The main pair answers the preset with the centre it just computed, so
        -- "apply preset" and the running geometry can never disagree by a
        -- fraction that then gets saved as a real position.
        app.Layout:OwnGeometry("unit_player", function()
            local centre = component.centres and component.centres.player
            return centre and centre.x, centre and centre.y
        end)
        app.Layout:OwnGeometry("unit_target", function()
            local centre = component.centres and component.centres.target
            return centre and centre.x, centre and centre.y
        end)
        applyTakeover(self)
        app:Subscribe(self, "LAYOUT_CENTRAL_CHANGED", function()
            if not self.running then return end
            app.Queue:Run("unitFrames/layout", function()
                if self.running then updateDefaults(self) end
            end)
        end)
        -- ActionBars loads later in the TOC and normalizes the native scale; one
        -- post-reconcile pass keeps the unit defaults aligned with that geometry.
        app:Subscribe(self, "RUNTIME_UPDATED", function()
            if not self.running then return end
            app.Queue:Run("unitFrames/layout", function()
                if self.running then updateDefaults(self) end
            end)
        end)
    end,
    Refresh = function(self)
        -- Re-evaluates the parts so a client that lost an API mid-session keeps
        -- its native frames instead of showing a partial replacement.
        local previous = self.activeParts or {}
        self.parts = app.UnitParts.Build()
        self.activeParts = activePartIds(self.parts)
        local lost = false
        for id in pairs(previous) do
            if not self.activeParts[id] then lost = true end
        end
        for _, frame in pairs(self.frames) do
            -- A part that disappeared leaves its controls behind; clear them
            -- before the remaining parts redraw themselves.
            if lost then hidePartControls(frame) end
            ensureParts(self.parts, frame)
            -- Registration is a set operation, so re-attaching is safe and lets a
            -- part that became available after login start receiving events.
            attachEvents(self.parts, frame, frame.unitToken)
            self:ApplyUnitConfig(frame.unitToken)
            drawFrame(frame)
            applyHeight(self, frame)
        end
        playerCastPlaceholder(self)
        updateDefaults(self)
        applyTakeover(self)
    end,
    Disable = function(self)
        if self.playerCastEntry then
            self.playerCastEntry.placeholder = false
            self.playerCastEntry.hidden = true
            if self.playerCastEntry.frame then self.playerCastEntry.frame:Hide() end
        end
        for _, frame in pairs(self.frames or {}) do
            frame.events:UnregisterAllEvents()
            UnregisterUnitWatch(frame)
            frame.lumaUnitWatched = nil
            hidePartControls(frame)
            frame:Hide()
        end
        -- The native frames come back even though the component stops: the
        -- restore job runs after the stop, so the guard inside checks nothing.
        restoreNativeFrames(self)
        -- A stopped component no longer owns a slot: a preset must fall back to
        -- its own fraction instead of reading the last frame's centre.
        app.Layout:OwnGeometry("unit_player", nil)
        app.Layout:OwnGeometry("unit_target", nil)
        self.centres = nil
        if app.Ownership then
            app.Ownership:Active("unitFrames", "native", "component-off")
            app.Ownership:Active("unitFrames.targetCast", "native", "component-off")
            app.Ownership:Active("unitFrames.auras", "native", "component-off")
        end
    end,
})

-- Re-applies the stored geometry to one frame. Width and the health height are
-- protected changes on a secure unit button, so the size write goes through the
-- queue; the fonts, the format and the colour are plain region writes and land
-- immediately.
function component:ApplyUnitConfig(unit)
    local frame = self.frames and self.frames[unit]
    local spec = unitConfig(unit)
    if not frame or not spec then return false end
    local m = frame.metrics
    local width = app.Capabilities.Plain(spec.width, "number") or m.width
    local health = app.Capabilities.Plain(spec.healthHeight, "number") or m.health
    local power = app.Capabilities.Plain(spec.powerHeight, "number") or m.power
    local nameSize = app.Capabilities.Plain(spec.nameSize, "number") or m.nameSize
    m.width, m.health, m.power, m.nameSize = width, health, power, nameSize
    frame.baseHeight = m.nameRow + m.health + m.power + m.powerGap
    -- Points are protected: queue them and let the height job coalesce with the
    -- next layout pass.
    app.Queue:Run("unitFrames/size/" .. unit, function()
        if not frame or not frame.metrics then return end
        frame:SetSize(frame.metrics.width, frame.baseHeight)
        frame.health:SetHeight(frame.metrics.health)
        frame.health:ClearAllPoints()
        frame.health:SetPoint("TOPLEFT", 0, -frame.metrics.nameRow)
        frame.health:SetPoint("TOPRIGHT", 0, -frame.metrics.nameRow)
        frame.power:SetHeight(frame.metrics.power)
        frame.power:ClearAllPoints()
        frame.power:SetPoint("TOPLEFT", 0, -(frame.metrics.nameRow + frame.metrics.health + frame.metrics.powerGap))
        frame.power:SetPoint("TOPRIGHT", 0, -(frame.metrics.nameRow + frame.metrics.health + frame.metrics.powerGap))
        frame.name:SetWidth(math.max(36, frame.metrics.width - (frame.metrics.nameReserve or 72)))
    end)
    local font = app.Type:Face()
    if type(frame.name.SetFont) == "function" then
        pcall(frame.name.SetFont, frame.name, font, nameSize, "OUTLINE")
    end
    local valueSize = math.max(8, nameSize - 1)
    if type(frame.value.SetFont) == "function" then
        pcall(frame.value.SetFont, frame.value, font, valueSize, "OUTLINE")
    end
    frame.healthFormat = spec.healthFormat or "percent"
    frame.colorMode = spec.colorMode or "auto"
    return true
end

-- One diagnostic line for the components page inside `/luma status`: it says
-- which native frames the preview took over and which ones it kept because a
-- part is missing. The player's own cast bar is never taken over — the preview
-- only reserves an edit-mode outline — so it is reported separately instead of
-- riding on the target-cast part's flag (010 plan P0).
function component:Describe()
    if not self.running then return nil end
    local takeover = self.takeover or { units = false, cast = false, missing = {} }
    local units = takeover.units and app.L.nativeTaken or app.L.nativeKept
    local cast = takeover.cast and app.L.nativeTaken or app.L.nativeKept
    local text = string.format("unitFrames: %s=%s, %s=%s · %s",
        app.L.nativeUnits, units, app.L.nativeTargetCast, cast, app.L.playerCastNative)
    local missing = takeover.missing or {}
    if #missing > 0 then
        text = text .. ", " .. app.L.nativeMissing .. ": " .. table.concat(missing, ",")
    end
    text = text .. " · " .. app.L.nativeAwaitingValidation .. " · " .. app.L.unitCoverage
    -- What the absorb and prediction strips did on the last draw: plain,
    -- restricted (the value went straight into the StatusBar), empty or
    -- unavailable (the client has no such API). Plain words only, no values.
    local parts = {}
    for _, unit in ipairs({ "player", "target" }) do
        local frame = self.frames and self.frames[unit]
        if frame and (frame.absorbState or frame.predictionState) then
            parts[#parts + 1] = string.format("%s absorb=%s prediction=%s", unit,
                tostring(frame.absorbState or "-"), tostring(frame.predictionState or "-"))
        end
    end
    if #parts > 0 then text = text .. " · " .. table.concat(parts, ", ") end
    return text
end

-- `/luma unit`: the shared block width and each frame's actual centre, so "the
-- frames did not move" can be attributed to a saved position, a missing viewer
-- measurement or a disabled component instead of guessed at.
local function frameCentre(frame)
    if type(frame.GetCenter) ~= "function" then return nil, nil end
    local ok, x, y = pcall(frame.GetCenter, frame)
    if not ok then return nil, nil end
    return app.Capabilities.Plain(x, "number"), app.Capabilities.Plain(y, "number")
end

-- A rectangle in the report's own units, or "unknown" when the client does not
-- report one. Reads only.
local function diagnosticRect(frame)
    if type(frame.GetRect) ~= "function" then return "unknown" end
    local ok, left, bottom, width, height = pcall(frame.GetRect, frame)
    left = ok and app.Capabilities.Plain(left, "number") or nil
    bottom = ok and app.Capabilities.Plain(bottom, "number") or nil
    width = ok and app.Capabilities.Plain(width, "number") or nil
    height = ok and app.Capabilities.Plain(height, "number") or nil
    if not left or not bottom or not width or not height then return "unknown" end
    return string.format("%.0fx%.0f@%.0f,%.0f", width, height, left, bottom)
end

local function frameVisible(frame)
    if not frame or type(frame.IsVisible) ~= "function" then return "?" end
    local ok, visible = pcall(frame.IsVisible, frame)
    visible = ok and app.Capabilities.Plain(visible, "boolean") or nil
    if visible == nil then return "?" end
    if visible == false then return "no" end
    -- Alpha zero draws nothing even when IsVisible reports true.
    local alpha = type(frame.GetAlpha) == "function"
        and app.Capabilities.Plain(select(2, pcall(frame.GetAlpha, frame)), "number") or nil
    if alpha ~= nil and alpha <= 0.01 then return "no" end
    return "yes"
end

function component:Diagnose()
    local content = app.Layout:ContentWidth()
    local measured = app.Layout.contentWidth ~= nil
    local central = app.Layout:Central()
    app:Print(string.format("unitFrames: status=%s running=%s block=%.0f (%s) action=%.0f",
        tostring(self.status), self.running and "yes" or "no", content,
        measured and "measured" or "fallback", central.action.width))
    local cooldown = app.components.cooldownViewer
    local rows = cooldown and cooldown.placedRows or {}
    if #rows > 0 then
        local parts = {}
        for _, row in ipairs(rows) do
            parts[#parts + 1] = string.format("%s=%.0f", tostring(row.id), row.width or 0)
        end
        app:Print("  rows: " .. table.concat(parts, " "))
    end
    -- The player cast bar's owner, visibility and rectangle are independent of
    -- the takeover intent: the bar is the client's, and the flag below only says
    -- the preview could take the other frames over.
    local castBar = _G.PlayerCastingBarFrame
    local castShown = "?"
    if castBar and type(castBar.IsShown) == "function" then
        local ok, shown = pcall(castBar.IsShown, castBar)
        castShown = ok and shown == true and "yes" or "no"
    end
    app:Print(string.format("  cast: owner=native shown=%s vis=%s rect=%s takeover=%s",
        castShown, frameVisible(castBar), diagnosticRect(castBar),
        (self.takeover and self.takeover.cast) and "possible" or "off"))
    local positions = app.Store:Profile().positions
    for _, spec in ipairs(specs) do
        local frame = self.frames and self.frames[spec.unit]
        if frame then
            local x, y = frameCentre(frame)
            local ok, shown = pcall(frame.IsShown, frame)
            app:Print(string.format("  %s: shown=%s vis=%s size=%.0fx%.0f center=%s,%s saved=%s",
                spec.unit, ok and shown == true and "yes" or "no", frameVisible(frame),
                frame:GetWidth(), frame:GetHeight(),
                x and string.format("%.1f", x) or "?",
                y and string.format("%.1f", y) or "?",
                positions["unit_" .. spec.unit] and "yes" or "no"))
        end
    end
end
