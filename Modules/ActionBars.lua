local _, app = ...

-- Three movable bars with independent profile scales. Unmoved bars start in a
-- central stack, and all three share the fade. Secure button behaviour and
-- protected layout writes stay with the client and the out-of-combat queue.
--
-- Bars 4–8 (`MultiBarRight`, `MultiBarLeft`, `MultiBar5–7`) are **not** touched.
-- Earlier iterations reparented them into a hidden parking frame so the central
-- HUD looked tidy, which also hid bars the player had enabled in Edit Mode; the
-- client's own layout and visibility are the authority for every bar this
-- component does not manage. A bar parked by an older session is put back from
-- its recorded parent/anchors once, then left alone.

local BARS = {
    { key = "main", frame = "MainActionBar", prefix = "ActionButton" },
    { key = "bar2", frame = "MultiBarBottomLeft", prefix = "MultiBarBottomLeftButton" },
    { key = "bar3", frame = "MultiBarBottomRight", prefix = "MultiBarBottomRightButton" },
}
-- Bars this component only observes. The catalog is the one definition of their
-- slot ranges and binding prefixes; it is never used to move or hide them.
local OBSERVED = { "MultiBarRight", "MultiBarLeft", "MultiBar5", "MultiBar6", "MultiBar7" }
local GAP = 4
local FADE_STEP, HIDE_DELAY, HOVER_PAD = 0.05, 0.9, 22
local LAYOUT_JOB, RESTORE_JOB = "actionBars/layout", "actionBars/restore"

local function object(value)
    local kind = type(value)
    return kind == "table" or kind == "userdata"
end

local function named(name)
    local value = _G[name]
    if object(value) then return value end
end

local function inCombat()
    return type(InCombatLockdown) == "function" and InCombatLockdown()
end

-- The parking frame from earlier sessions. It is only used to hand a bar back:
-- nothing is parented into it any more.
local park
local function parked()
    if not park then
        park = _G.LumaUIActionBarsPark
        if not park then
            park = CreateFrame("Frame", "LumaUIActionBarsPark", UIParent)
            park:Hide()
        end
    end
    return park
end

local function recordBar(bar)
    if bar.lumaActionBarsOriginal then return end
    local original = {
        points = {},
        scale = bar:GetScale(),
        alpha = bar:GetAlpha(),
        parent = bar:GetParent(),
    }
    if type(bar.IsShown) == "function" then
        original.shown = app.Capabilities.Plain(bar:IsShown(), "boolean")
    end
    if type(bar.GetPoint) == "function" then
        for index = 1, 4 do
            local ok, point, relative, relativePoint, x, y = pcall(bar.GetPoint, bar, index)
            if not ok or not point then break end
            original.points[#original.points + 1] = { point, relative, relativePoint, x, y }
        end
    end
    bar.lumaActionBarsOriginal = original
end

local function restoreBar(bar)
    local original = bar.lumaActionBarsOriginal
    if not original then return end
    pcall(bar.SetAlpha, bar, original.alpha or 1)
    pcall(bar.SetScale, bar, original.scale or 1)
    if original.parent then pcall(bar.SetParent, bar, original.parent) end
    pcall(bar.ClearAllPoints, bar)
    for _, point in ipairs(original.points) do
        pcall(bar.SetPoint, bar, point[1], point[2], point[3], point[4], point[5])
    end
    if original.shown == false then pcall(bar.Hide, bar)
    elseif original.shown == true then pcall(bar.Show, bar) end
    bar.lumaActionBarsOriginal = nil
end

local function buttonsOf(def)
    local bar = named(def.frame)
    if not bar then return nil, {} end
    local list, seen = {}, {}
    local pool = bar.actionButtons
    if type(pool) == "table" then
        for index = 1, 12 do
            local button = pool[index]
            if object(button) and not seen[button] then
                seen[button] = true
                list[#list + 1] = button
            end
        end
    end
    if #list == 0 then
        for index = 1, 12 do
            local button = _G[def.prefix .. index]
            if object(button) and not seen[button] then
                seen[button] = true
                list[#list + 1] = button
            end
        end
    end
    return bar, list
end

local function sampleRunning()
    local sample = app.components and app.components.actionButtons
    return sample ~= nil and sample.running == true
end

-- Native action-button cooldown objects are never written. In 12.x the button's
-- cooldown update passes secret start/duration values to `Cooldown:SetCooldown`
-- and those are only accepted during untainted execution; writing anything on
-- the cooldown frame (swipe colour, hidden numbers, the countdown FontString)
-- taints the object and turns every later cooldown tick into
-- `... Secret values are only allowed during untainted execution ...`
-- (010 field report: MultiBarBottomRightButton3Cooldown, 2743 repeats).
-- The Pearl countdown look therefore stays at the client's own draw path.

-- Releases only the entries this component still owns. A button whose skin was
-- replaced or already released elsewhere is forgotten instead of rewritten,
-- so a later owner's recording stays the client's own values.
local function releaseSkins(self)
    local skin = app.ActionButtonSkin
    for button, entry in pairs(self.skins or {}) do
        if skin and button.lumaActionBarSkin == entry then
            pcall(skin.Restore, skin, button)
        end
    end
    self.skins = {}
end

local function skinButtons(self)
    -- The optional single-bar sample already owns the main bar; do not let two
    -- LumaUI skins fight over the same button.
    if sampleRunning() then
        self.sampleOwned = true
        releaseSkins(self)
        return
    end
    local skin = app.ActionButtonSkin
    if not skin then return end
    for _, def in ipairs(BARS) do
        local _, buttons = buttonsOf(def)
        for _, button in ipairs(buttons) do
            if not self.skins[button] then
                local ok, applied = pcall(skin.Apply, skin, button)
                local entry = ok and applied and button.lumaActionBarSkin or nil
                if entry then self.skins[button] = entry end
            end
        end
    end
    self.sampleOwned = false
end

local function publishAlpha(self)
    local alpha = self.alpha or 0
    if self.publishedAlpha == alpha then return end
    self.publishedAlpha = alpha
    app:Publish("ACTION_BARS_ALPHA", alpha)
end

local function anchor(bar, point, relative, relativePoint, x, y)
    local ok, p, r, rp, px, py = pcall(bar.GetPoint, bar, 1)
    if ok and p == point and r == relative and rp == relativePoint
        and app.Capabilities.Plain(px, "number") == x
        and app.Capabilities.Plain(py, "number") == y then return true end
    return pcall(function()
        bar:ClearAllPoints()
        bar:SetPoint(point, relative, relativePoint, x, y)
    end)
end

-- Hands every observed bar back to the client. Only a bar this session (or an
-- older build) actually parked is written: a bar the client still owns is not
-- touched at all, so its Edit Mode parent, anchors and shown state stay.
local function releaseObserved()
    local parkFrame = parked()
    for _, name in ipairs(OBSERVED) do
        local bar = named(name)
        if bar then
            local parkedHere = parkFrame and bar:GetParent() == parkFrame
            if bar.lumaActionBarsOriginal then
                restoreBar(bar)
            elseif parkedHere then
                -- Parked by a build that kept no record (a session older than
                -- this one): hand the frame back to the client, which owns its
                -- anchors and re-applies them on the next layout update.
                pcall(bar.SetParent, bar, UIParent)
            end
        end
    end
end

-- Per-bar display owner. Bars LumaUI positions are published by the placement
-- loop; the observed ones say "the client draws this" with the reason, so
-- `/luma ownership` never claims a bar that was left alone.
local function publishObserved()
    if not app.Ownership then return end
    local model = app.BarModel
    for _, name in ipairs(OBSERVED) do
        local entry = model and model:NativeByFrame(name)
        if entry then
            local frame = named(name)
            app.Ownership:Set("actionBars." .. entry.key, {
                intent = "native", active = "native", evidence = "none",
                reason = frame and "client-managed" or "absent",
            })
        end
    end
end

----------------------------------------------------------------------
-- Fixed-bar layout overrides (Phase 07)
----------------------------------------------------------------------
-- The client's bars keep their buttons, bindings, paging and click handling.
-- An explicit override only rearranges those same buttons: capacity, rows, size
-- and gap, plus a supported visibility rule. The client's own sizes and anchors
-- are recorded once and written back when the override is cleared, so a player
-- who never opens the page sees no difference at all. Every write happens out of
-- combat through the same queued pass as the anchor layout.
local VISIBILITY_RULES = {
    always = "show",
    combat = "[combat] show; hide",
    outofcombat = "[combat] hide; show",
}

local function fixedSpec(slot)
    local layouts = app.Store:Profile().ui.actionBarLayout
    return layouts and layouts[slot]
end

-- Records the client's own button geometry once per bar. A second override
-- never records the first override as "native".
local function recordFixed(bar, buttons)
    if bar.lumaButtonLayout then return bar.lumaButtonLayout end
    local width = app.Capabilities.Plain(bar:GetWidth(), "number")
    local height = app.Capabilities.Plain(bar:GetHeight(), "number")
    -- A bar the client has not laid out yet reports 0; recording that would
    -- restore the bar to zero size later. Only a real measurement is recorded.
    local record = { buttons = {}, width = width and width > 0 and width or nil,
        height = height and height > 0 and height or nil }
    for _, button in ipairs(buttons) do
        local points = {}
        for index = 1, 4 do
            local ok, point, relative, relativePoint, x, y = pcall(button.GetPoint, button, index)
            if not ok or not point then break end
            points[#points + 1] = { point, relative, relativePoint, x, y }
        end
        record.buttons[button] = {
            width = button:GetWidth(), height = button:GetHeight(),
            shown = app.Capabilities.Plain(button:IsShown(), "boolean"), points = points,
        }
    end
    bar.lumaButtonLayout = record
    return record
end

local function restoreFixed(bar)
    local record = bar and bar.lumaButtonLayout
    if not record then return end
    bar.lumaButtonLayout = nil
    if type(UnregisterStateDriver) == "function" then pcall(UnregisterStateDriver, bar, "visibility") end
    for button, state in pairs(record.buttons) do
        pcall(button.SetSize, button, state.width, state.height)
        pcall(button.ClearAllPoints, button)
        for _, point in ipairs(state.points) do
            pcall(button.SetPoint, button, point[1], point[2], point[3], point[4], point[5])
        end
        if state.shown == false then pcall(button.Hide, button) else pcall(button.Show, button) end
    end
    if record.width and record.height then pcall(bar.SetSize, bar, record.width, record.height) end
end

local function applyVisibility(bar, mode)
    mode = VISIBILITY_RULES[mode] and mode or "always"
    if type(UnregisterStateDriver) == "function" then pcall(UnregisterStateDriver, bar, "visibility") end
    if mode == "hidden" then
        pcall(bar.Hide, bar)
        return "hidden"
    end
    if type(RegisterStateDriver) == "function" and pcall(RegisterStateDriver, bar, "visibility", VISIBILITY_RULES[mode]) then
        return mode
    end
    -- No state driver on this build: show the bar and say the rule is not
    -- enforced instead of pretending the condition works.
    pcall(bar.Show, bar)
    return mode .. "-unavailable"
end

local function applyFixed(self, entry, bar)
    local spec = fixedSpec(entry.id)
    local _, buttons = buttonsOf({ frame = entry.frame, prefix = entry.prefix })
    if #buttons == 0 then return nil end
    if not app.BarModel:LayoutActive(spec) then
        restoreFixed(bar)
        return nil
    end
    local record = recordFixed(bar, buttons)
    local first = buttons[1]
    local fallback = record and record.buttons[first] and record.buttons[first].width or 30
    local plan = app.BarModel:LayoutPlan(spec, #buttons, fallback)
    for index, button in ipairs(buttons) do
        local cell = plan.cells[index]
        if cell then
            pcall(button.Show, button)
            if plan.size > 0 then
                pcall(button.SetSize, button, plan.size, plan.size)
                pcall(button.ClearAllPoints, button)
                pcall(button.SetPoint, button, "BOTTOMLEFT", bar, "BOTTOMLEFT", cell.x, cell.y)
            end
        else
            -- Capacity is a display decision: a hidden button keeps its action
            -- and its binding, so the key still performs it.
            pcall(button.Hide, button)
        end
    end
    if plan.sized then pcall(bar.SetSize, bar, plan.width, plan.height) end
    return applyVisibility(bar, spec.visible or "always"), plan
end

-- Contextual bars (Phase 08) are not re-numbered like the fixed bars and are
-- not moved by LumaUI: the pet bar follows the pet, the stance bar the
-- shapeshift slots, and the extra/zone buttons belong to the encounter. They are
-- registered as placeholders so the layout editor can show and reserve their
-- measured area, and their ownership says "the client draws this" instead of
-- pretending a takeover exists.
local CONTEXTUAL_KINDS = { pet = true, stance = true, extra = true, zone = true }

local function registerContextual()
    local model = app.BarModel
    for _, entry in ipairs(model.native) do
        if CONTEXTUAL_KINDS[entry.kind] then
            if not app.Layout.entries[entry.key] then
                local frame = named(entry.frame)
                local width, height = 220, 30
                if frame then
                    local okW, w = pcall(frame.GetWidth, frame)
                    local okH, h = pcall(frame.GetHeight, frame)
                    width = okW and app.Capabilities.Plain(w, "number") or width
                    height = okH and app.Capabilities.Plain(h, "number") or height
                end
                -- A placeholder reserves and outlines the area in the layout
                -- editor; it never moves the client's frame.
                app.Layout:RegisterPlaceholder(entry.key, entry.kind, 0, -300, width, height)
            end
            if app.Ownership then
                app.Ownership:Set("actionBars." .. entry.key, {
                    intent = "native", active = "native", evidence = "none", reason = "client-managed",
                })
            end
        end
    end
end

local function layoutFixed(self)
    self.fixed = self.fixed or {}
    for _, entry in ipairs(app.BarModel:NativeFixed()) do
        if entry.id >= 2 then
            local bar = named(entry.frame)
            if bar then
                local activeSpec = app.BarModel:LayoutActive(fixedSpec(entry.id))
                local mode, plan = applyFixed(self, entry, bar)
                self.fixed[entry.id] = { bar = bar, visible = mode,
                    buttons = plan and plan.buttons or nil, rows = plan and plan.rows or nil,
                    active = activeSpec }
                if activeSpec and app.Ownership then
                    local active = "owned"
                    -- A visibility rule the build cannot enforce is not an owned
                    -- display: the client still decides what is on screen.
                    if mode and mode:find("-unavailable", 1, true) then active = "native" end
                    app.Ownership:Set("actionBars." .. entry.key, {
                        intent = "owned", active = active, evidence = "simulated",
                        reason = active == "native" and mode or nil,
                    })
                end
            end
        end
    end
end

local function layout(self)
    if inCombat() then return false end
    releaseObserved()
    publishObserved()

    local layoutService, profile = app.Layout, app.Store:Profile()
    for index, def in ipairs(BARS) do
        local bar = named(def.frame)
        local id = "actionBar" .. index
        local entry = layoutService.entries[id]
        if bar then
            recordBar(bar)
            if not entry or entry.frame ~= bar then
                local slot = index
                entry = layoutService:Register(id, bar, 0, 0, string.format(app.L.actionBarLabel, slot),
                    function() return app.Store:Profile().ui.actionBarScales[slot] end)
                entry.apply, entry.absoluteScale = self.applyLayout, true
                entry.parentCoordinates = true
            end
            entry.hidden = nil
            local scale = layoutService:Scale(id)
            if app.Capabilities.Plain(bar:GetScale(), "number") ~= scale then pcall(bar.SetScale, bar, scale) end
            if type(bar.IsShown) ~= "function" or not app.Capabilities.Plain(bar:IsShown(), "boolean") then
                pcall(bar.Show, bar)
            end
            self.bars[def.key] = bar
        elseif entry then
            entry.hidden, entry.detached = true, nil
        end
    end
    local old = self.geometry and self.geometry.action
    local bottom = layoutService:ActionAreaBottom()
    local gap = layoutService.actionGap or GAP
    local previous
    for index, def in ipairs(BARS) do
        local bar = named(def.frame)
        if bar then
            local id = "actionBar" .. index
            local entry = layoutService.entries[id]
            local position = profile.positions[id]
            local scale = app.Capabilities.Plain(bar:GetEffectiveScale(), "number")
            local parentScale = app.Capabilities.Plain(UIParent:GetEffectiveScale(), "number")
            local ratio = scale and parentScale and scale > 0 and parentScale > 0 and scale / parentScale or 1
            entry.detached = nil
            if position then
                local x, y = layoutService:Constrain(id, position.x, position.y)
                entry.detached = anchor(bar, "CENTER", UIParent, "CENTER", x / ratio, y / ratio) or nil
            end
            local placed = entry.detached
            if not placed then
                placed = anchor(bar, "BOTTOM", previous or UIParent, previous and "TOP" or "BOTTOM",
                    0, (previous and gap or bottom) / ratio)
                if placed then previous = bar end
            end
            if placed then
                pcall(bar.SetAlpha, bar, self.alpha or 0)
            else
                restoreBar(bar)
                entry.hidden = true
                self.bars[def.key] = nil
            end
            if app.Ownership then
                app.Ownership:Set("actionBars.actionBar" .. index, {
                    intent = "owned", active = placed and "owned" or "native",
                    evidence = "simulated", reason = placed and nil or "placement-failed",
                })
            end
        end
    end
    layoutFixed(self)
    registerContextual()
    self.geometry = layoutService:Central()
    skinButtons(self)
    self.pending = nil
    publishAlpha(self)
    local current = self.geometry.action
    if not old or old.top ~= current.top or old.width ~= current.width then
        app:Publish("LAYOUT_CENTRAL_CHANGED")
    end
    return true
end

local function apply(self)
    if self.layingOut then return end
    if inCombat() then
        self.pending = true
        app.Queue:Run(LAYOUT_JOB, function()
            if not self.running then return end
            apply(self)
        end)
        return
    end
    self.layingOut = true
    app:Call("actionBars/layout", layout, self)
    self.layingOut = nil
end

local function mouseOver(region)
    if not object(region) then return false end
    if type(MouseIsOver) == "function" then
        local ok, value = pcall(MouseIsOver, region, HOVER_PAD, HOVER_PAD, HOVER_PAD, HOVER_PAD)
        if ok and not app.Capabilities.IsSecret(value) and value == true then return true end
    end
    if type(region.IsMouseOver) == "function" then
        local ok, value = pcall(region.IsMouseOver, region)
        if ok and not app.Capabilities.IsSecret(value) and value == true then return true end
    end
    -- Mouse focus is the fallback for clients where the predicate is unavailable
    -- on protected buttons; it also catches a child button whose parent moved.
    if type(GetMouseFocus) == "function" then
        local ok, focus = pcall(GetMouseFocus)
        if ok and object(focus) then
            if focus == region then return true end
            if type(focus.IsDescendantOf) == "function" then
                local descendant, inside = pcall(focus.IsDescendantOf, focus, region)
                if descendant and not app.Capabilities.IsSecret(inside) and inside == true then
                    return true
                end
            end
        end
    end
    return false
end

local function editModeOpen()
    local frame = _G.EditModeManagerFrame
    if not object(frame) or type(frame.IsShown) ~= "function" then return false end
    local ok, shown = pcall(frame.IsShown, frame)
    return ok and not app.Capabilities.IsSecret(shown) and shown == true
end

-- The hover area is the measured action rectangle, not each bar's own hit box:
-- a fade at alpha 0 keeps hit testing, but an explicit rectangle keeps the
-- reveal limited to the reserved area and away from the bottom strip (zero
-- bottom padding). Returns nil when the client exposes no cursor readback so
-- the caller can fall back to the native mouse predicates.
local function cursorInside(geometry)
    if not geometry or not geometry.action then return nil end
    if #geometry.action.rows == 0 then return false end
    if type(GetCursorPosition) ~= "function" or type(UIParent.GetCenter) ~= "function" then return nil end
    local okPos, rawX, rawY = pcall(GetCursorPosition)
    local okCenter, rawCX, rawCY = pcall(UIParent.GetCenter, UIParent)
    local okScale, rawScale = pcall(UIParent.GetEffectiveScale, UIParent)
    local x = okPos and app.Capabilities.Plain(rawX, "number") or nil
    local y = okPos and app.Capabilities.Plain(rawY, "number") or nil
    local cx = okCenter and app.Capabilities.Plain(rawCX, "number") or nil
    local cy = okCenter and app.Capabilities.Plain(rawCY, "number") or nil
    local scale = okScale and app.Capabilities.Plain(rawScale, "number") or nil
    if not x or not y or not cx or not cy or not scale or scale <= 0 then return nil end
    -- GetCursorPosition is in physical pixels; GetCenter already reports in
    -- UIParent units, so only the cursor is divided by the effective scale.
    local dx, dy = x / scale - cx, y / scale - cy
    local half = geometry.action.width / 2 + HOVER_PAD
    return dx >= -half and dx <= half
        and dy >= geometry.action.bottomY and dy <= geometry.action.topY + HOVER_PAD
end

-- Chat sits in front of part of the action area on narrow screens. Excluding a
-- focused ChatFrame (or one of its children) keeps typing from summoning the
-- bars; other overlapping windows need their own evidence and follow-up.
local function chatFocused()
    if type(GetMouseFocus) ~= "function" then return false end
    local ok, focus = pcall(GetMouseFocus)
    if not ok or not object(focus) then return false end
    local name = type(focus.GetName) == "function" and select(2, pcall(focus.GetName, focus)) or nil
    name = app.Capabilities.Plain(name, "string")
    return name ~= nil and name:find("^ChatFrame") ~= nil
end

local function isOver(self)
    if editModeOpen() then return true end
    if chatFocused() then return false end
    local inside = cursorInside(self.geometry)
    if inside then return true end
    for index, def in ipairs(BARS) do
        local entry = app.Layout.entries["actionBar" .. index]
        if (inside == nil or (entry and entry.detached)) and mouseOver(self.bars[def.key]) then
            return true
        end
    end
    return false
end

local function step(self)
    if not self.ticking then return end
    local now = type(GetTime) == "function" and GetTime() or 0
    local over = isOver(self)
    if over then
        self.lastOver = now
        self.target = 1
    elseif self.target == 1 and now - (self.lastOver or 0) > HIDE_DELAY then
        self.target = 0
    end
    local alpha = self.alpha or 0
    if alpha ~= self.target then
        alpha = alpha + (self.target - alpha) * 0.45
        if math.abs(self.target - alpha) < 0.02 then alpha = self.target end
        self.alpha = alpha
        for _, bar in pairs(self.bars) do pcall(bar.SetAlpha, bar, alpha) end
        publishAlpha(self)
    end
end

local function restoreAll(self)
    releaseSkins(self)
    for _, bar in pairs(self.bars or {}) do restoreBar(bar) end
    for _, entry in ipairs(app.BarModel:NativeFixed()) do
        local bar = named(entry.frame)
        if bar and bar.lumaButtonLayout then restoreFixed(bar) end
    end
    releaseObserved()
    self.bars = {}
    self.fixed = {}
end

app:RegisterComponent({
    id = "actionBars", label = "actionBars", defaultEnabled = true,
    Supported = function() return named("MainActionBar") ~= nil end,
    Enable = function(self)
        self.bars = self.bars or {}
        self.skins = self.skins or {}
        self.sampleOwned = false
        self.alpha = 0
        self.target = 0
        self.lastOver = 0
        self.pending = nil
        self.geometry = nil
        self.publishedAlpha = nil
        self.ticking = true
        self.applyLayout = self.applyLayout or function()
            if self.running then apply(self) end
        end
        apply(self)
        if type(C_Timer) == "table" and type(C_Timer.NewTicker) == "function" then
            self.ticker = C_Timer.NewTicker(FADE_STEP, function() step(self) end)
        end
        self:Listen("EDIT_MODE_LAYOUTS_UPDATED", function() apply(self) end)
        self:Listen("PLAYER_ENTERING_WORLD", function() apply(self) end)
        self:Listen("PLAYER_REGEN_ENABLED", function()
            if self.pending then apply(self) end
        end)
        -- Cooldown widgets can be created lazily by the client; re-skin the
        -- static button art the first time they appear, but only outside
        -- combat. The native cooldown object itself is never written (see the
        -- secret-value note above), so this only touches icon/font art.
        self:Listen("ACTIONBAR_UPDATE_COOLDOWN", function()
            if not inCombat() then skinButtons(self) end
        end)
        -- The sample may be toggled while this component keeps running; hand
        -- the buttons over or take them back exactly once per change.
        app:Subscribe(self, "RUNTIME_UPDATED", function()
            if not self.running then return end
            local owned = sampleRunning()
            if owned == self.sampleOwned then return end
            self.sampleOwned = owned
            if owned then
                releaseSkins(self)
            else
                apply(self)
            end
        end)
        -- The bottom strip owns the reserved baseline. Re-layout when it moves
        -- instead of keeping a private copy of the old bottom offset.
        app:Subscribe(self, "LAYOUT_CENTRAL_CHANGED", function()
            if self.running then apply(self) end
        end)
    end,
    Refresh = function(self) apply(self) end,
    Disable = function(self)
        self.ticking = false
        if self.ticker then
            pcall(self.ticker.Cancel, self.ticker)
            self.ticker = nil
        end
        for _, bar in pairs(self.bars or {}) do pcall(bar.SetAlpha, bar, 1) end
        -- The backing panels follow this published value; returning to 1 here
        -- keeps them useful if only the bars are switched off.
        self.alpha = 1
        publishAlpha(self)
        self.geometry = nil
        for index in ipairs(BARS) do
            local entry = app.Layout.entries["actionBar" .. index]
            if entry then
                entry.hidden, entry.detached = true, nil
                if entry.overlay then entry.overlay:Hide() end
            end
        end
        if inCombat() then
            app.Queue:Run(RESTORE_JOB, function()
                if self.running then return end
                restoreAll(self)
            end)
        else
            restoreAll(self)
        end
    end,
})
