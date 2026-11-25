local _, app = ...
local Model = app.BarModel

-- LumaUI's own action buttons for bars 1–3 (012 phase 10/11).
--
-- Scope and honesty: this is a real secure action bar. Buttons use
-- SecureActionButtonTemplate with the client's documented action IDs and both
-- mouse buttons, so clicks perform the same action the native button would.
-- Key bindings are **not** taken over: native bindings still drive the native
-- buttons, which is why the native bar is only hidden after the own bar for
-- that action range has been built and every button carries its action.
--
-- Paging (stance/stealth/vehicle/override) is not implemented here. The own bar
-- always shows the base page, and `/luma ownedbars` says so; the client's main
-- bar remains the paging authority. Until that is validated in game the whole
-- feature is opt-in and the native bars stay the default.
--
-- Nothing is created or re-anchored in combat: Enable/Render run through the
-- existing out-of-combat queue, and a disable inside combat defers the native
-- restore to the same queue.

local component
local RANGE = Model.SLOT_RANGES
local HIDE_JOB = "ownedBars/native"
local TICK = 0.15

local function config()
    return app.Store:Profile().ui.ownedBars
end

local function plainNumber(value)
    return app.Capabilities.Plain(value, "number")
end

local function plainString(value)
    return app.Capabilities.Plain(value, "string")
end

local function actionTexture(slot)
    if type(GetActionTexture) ~= "function" then return nil end
    local ok, texture = pcall(GetActionTexture, slot)
    return ok and plainString(texture) or nil
end

local function actionCount(slot)
    if type(GetActionCount) ~= "function" then return nil end
    local ok, count = pcall(GetActionCount, slot)
    return ok and plainNumber(count) or nil
end

local function hasAction(slot)
    if type(HasAction) ~= "function" then return true end
    local ok, value = pcall(HasAction, slot)
    return ok and app.Capabilities.Plain(value, "boolean") ~= false
end

local function actionCooldown(slot)
    if type(GetActionCooldown) ~= "function" then return nil end
    local ok, start, duration, enabled = pcall(GetActionCooldown, slot)
    start, duration = ok and plainNumber(start) or nil, ok and plainNumber(duration) or nil
    enabled = ok and app.Capabilities.Plain(enabled, "boolean") or nil
    if not start or not duration or duration <= 0 or enabled == false then return nil end
    return start, duration
end

local function setAction(button, slot, available)
    if not button then return end
    if available then
        pcall(button.SetAttribute, button, "type1", "action")
        pcall(button.SetAttribute, button, "action1", slot)
        pcall(button.SetAttribute, button, "type2", "action")
        pcall(button.SetAttribute, button, "action2", slot)
        button.lumaActionID = slot
    else
        pcall(button.SetAttribute, button, "type1", nil)
        pcall(button.SetAttribute, button, "action1", nil)
        pcall(button.SetAttribute, button, "type2", nil)
        pcall(button.SetAttribute, button, "action2", nil)
        button.lumaActionID = nil
    end
end

local function stopTicker(self)
    if self.ticker then self.ticker:Cancel(); self.ticker = nil end
end

local function anyCounting(self)
    for _, bar in ipairs(self.bars or {}) do
        for _, button in ipairs(bar.buttons) do
            local remaining = button.lumaRemaining
            if remaining and remaining > 0.05 then return true end
        end
    end
    return false
end

local function ensureTicker(self)
    if not anyCounting(self) then stopTicker(self); return end
    if self.ticker or type(C_Timer) ~= "table" or type(C_Timer.NewTicker) ~= "function" then return end
    self.ticker = C_Timer.NewTicker(TICK, function()
        if not self.running then stopTicker(self); return end
        self:Paint()
        ensureTicker(self)
    end)
end

local function updateButton(button, slot)
    local available = hasAction(slot)
    setAction(button, slot, available)
    if not available then
        button.icon:SetTexture(nil)
        button.icon:Hide()
        button.count:SetText("")
        button.time:SetText("")
        button.lumaRemaining = nil
        if type(button.swipe.Clear) == "function" then pcall(button.swipe.Clear, button.swipe) end
        button:SetAlpha(0.35)
        return
    end
    local texture = actionTexture(slot)
    if texture then
        button.icon:SetTexture(texture)
        button.icon:Show()
    else
        -- The texture may be restricted; an empty cell is truthful, a guessed
        -- icon is not.
        button.icon:Hide()
    end
    local count = actionCount(slot)
    button.count:SetText(count and count > 1 and tostring(count) or "")
    local start, duration = actionCooldown(slot)
    if start and duration then
        pcall(button.swipe.SetCooldown, button.swipe, start, duration)
        local now = type(GetTime) == "function" and select(2, pcall(GetTime)) or nil
        now = plainNumber(now)
        button.lumaRemaining = now and math.max(0, start + duration - now) or nil
        if button.lumaRemaining and button.lumaRemaining >= 60 then
            button.time:SetFormattedText("%d:%02d", math.floor(button.lumaRemaining / 60),
                math.floor(button.lumaRemaining % 60))
        elseif button.lumaRemaining and button.lumaRemaining > 0 then
            button.time:SetFormattedText("%d", math.ceil(button.lumaRemaining))
        else
            button.time:SetText("")
        end
    else
        if type(button.swipe.Clear) == "function" then pcall(button.swipe.Clear, button.swipe) end
        button.time:SetText("")
        button.lumaRemaining = nil
    end
    button:SetAlpha(1)
end

local function createButton(parent, index)
    local name = "LumaUIOwnedActionButton" .. index
    local button = CreateFrame("CheckButton", name, parent, "SecureActionButtonTemplate")
    -- Press, not both press and release: two registrations would run the same
    -- action twice per click.
    button:RegisterForClicks("AnyDown")
    button:SetSize(30, 30)
    local base = button:CreateTexture(nil, "BACKGROUND")
    base:SetAllPoints()
    local dark = app.Theme.colors.embedded
    base:SetColorTexture(dark[1] * 1.6, dark[2] * 1.6, dark[3] * 1.6, 1)
    local icon = button:CreateTexture(nil, "ARTWORK")
    icon:SetPoint("TOPLEFT", 2, -2)
    icon:SetPoint("BOTTOMRIGHT", -2, 2)
    icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    icon:Hide()
    local edge = CreateFrame("Frame", nil, button, "BackdropTemplate")
    edge:EnableMouse(false)
    edge:SetAllPoints()
    edge:SetBackdrop({ edgeFile = app.Theme.white, edgeSize = app.Pixel:Pixels(1, edge) })
    local line = app.Theme.colors.line
    edge:SetBackdropBorderColor(line[1], line[2], line[3], 0.85)
    local swipe = CreateFrame("Cooldown", nil, button, "CooldownFrameTemplate")
    swipe:SetAllPoints(icon)
    if type(swipe.SetDrawEdge) == "function" then pcall(swipe.SetDrawEdge, swipe, false) end
    local count = app.Theme:Text(button, 10)
    count:SetPoint("BOTTOMRIGHT", -4, 3)
    count:SetText("")
    local time = app.Theme:Text(button, 10)
    time:SetPoint("CENTER")
    time:SetText("")
    button.icon, button.count, button.time, button.swipe = icon, count, time, swipe
    button:SetAlpha(0.35)
    return button
end

local function createBar(self, id)
    local rangeStart = RANGE[id][1]
    local bar = self.barsById[id]
    if not bar then
        local frame = CreateFrame("Frame", "LumaUIOwnedBar" .. id:sub(4), UIParent)
        frame:EnableMouse(false)
        bar = { id = id, frame = frame, buttons = {} }
        for index = 1, 12 do
            bar.buttons[index] = createButton(frame, (rangeStart + index - 1))
        end
        self.barsById[id] = bar
        self.bars[#self.bars + 1] = bar
    end
    return bar
end

local function place(self, bar, cfg, originY)
    local plan = Model:Plan(cfg)
    bar.plan = plan
    bar.frame:SetSize(plan.width, plan.height)
    bar.frame:ClearAllPoints()
    bar.frame:SetPoint("BOTTOM", UIParent, "BOTTOM", 0, originY)
    for index, button in ipairs(bar.buttons) do
        local slot = plan.slots[index]
        button:SetSize(cfg.size, cfg.size)
        button:ClearAllPoints()
        button:SetPoint("BOTTOMLEFT", bar.frame, "BOTTOMLEFT", slot.x - cfg.size / 2, slot.y - cfg.size / 2)
    end
    bar.frame:SetScale(1)
    return plan.height
end

local function render(self)
    if not self.running then return end
    local owned = config()
    local normalized = Model:Normalize(owned)
    if not normalized.enabled then
        self:HideBars()
        return
    end
    local originY = app.Layout:ActionAreaBottom()
    for _, id in ipairs(Model.BARS) do
        local bar = createBar(self, id)
        local cfg = normalized.bars[id]
        originY = originY + place(self, bar, cfg, originY) + 4
        bar.frame:Show()
        for index = 1, 12 do
            app:Call("ownedBars/update", updateButton, bar.buttons[index],
                RANGE[id][1] + index - 1)
        end
        self:HideNative(id)
    end
    ensureTicker(self)
    if app.Ownership then
        app.Ownership:Set("ownedBars", {
            intent = "owned", active = "owned", evidence = "simulated",
            reason = "clicks-only-bindings-native",
        })
    end
end

-- Registered after the renderer closure so Enable can call it, and before the
-- remaining methods so `component:` is always a real table when they load.
component = app:RegisterComponent({ id = "ownedBars", label = "ownedBars", defaultEnabled = true,
    Enable = function(self)
        self.bars, self.barsById = {}, {}
        self:Listen("ACTIONBAR_SLOT_CHANGED", function(current)
            if config().enabled then app:Call("ownedBars/paint", render, current) end
        end)
        self:Listen("ACTIONBAR_UPDATE_COOLDOWN", function(current)
            if config().enabled then app:Call("ownedBars/paint", current.Paint, current) end
        end)
        self:Listen("ACTIONBAR_UPDATE_STATE", function(current)
            if config().enabled then app:Call("ownedBars/paint", current.Paint, current) end
        end)
        self:Listen("PLAYER_ENTERING_WORLD", function(current)
            if config().enabled then app:Call("ownedBars/render", render, current) end
        end)
        render(self)
    end,
    Refresh = function(self) render(self) end,
    Disable = function(self)
        self:HideBars()
        for _, bar in ipairs(self.bars or {}) do
            for _, button in ipairs(bar.buttons) do setAction(button, nil, false) end
        end
    end,
})

function component:HideBars()
    for _, bar in ipairs(self.bars or {}) do bar.frame:Hide() end
    stopTicker(self)
    self:RestoreNative()
    if app.Ownership then
        app.Ownership:Set("ownedBars", { intent = config().enabled and "owned" or "native",
            active = "native", evidence = "none" })
    end
end

-- Hiding a native bar is a protected write, so it goes through the queue and
-- is recorded per bar before the first hide. A bar that refuses to hide is
-- reported and the own bar for that range is not shown either.
local function nativeName(id)
    if id == "bar1" then return "MainActionBar" end
    if id == "bar2" then return "MultiBarBottomLeft" end
    return "MultiBarBottomRight"
end

function component:HideNative(id)
    local name = nativeName(id)
    local frame = _G[name]
    if not frame then return end
    self.native = self.native or {}
    if self.native[id] then return end
    self.native[id] = { frame = frame, shown = frame:IsShown() }
    app.Queue:Run(HIDE_JOB .. "/" .. id, function()
        if not self.running then return end
        if not (app.Store:Profile().ui.ownedBars.enabled == true) then return end
        pcall(frame.Hide, frame)
    end)
end

function component:RestoreNative()
    -- Clear the record before scheduling: the queue may run immediately, and a
    -- job that still sees its own entry would skip the restore.
    local pending = self.native
    self.native = nil
    for id, record in pairs(pending or {}) do
        local frame = record.frame
        if frame and record.shown then
            app.Queue:Run(HIDE_JOB .. "/" .. id, function()
                if self.native and self.native[id] then return end
                pcall(frame.Show, frame)
            end)
        end
    end
end

function component:Paint()
    if not self.running then return end
    for _, bar in ipairs(self.bars or {}) do
        local rangeStart = RANGE[bar.id][1]
        for index, button in ipairs(bar.buttons) do
            app:Call("ownedBars/update", updateButton, button, rangeStart + index - 1)
        end
    end
    ensureTicker(self)
end

function component:SetOption(key, value)
    local ok = app.Store:Set("ui", "ownedBars", (function()
        local nextValue = Model:Normalize(config())
        if key == "enabled" then
            nextValue.enabled = value
        elseif key == "size" or key == "columns" then
            for _, id in ipairs(Model.BARS) do nextValue.bars[id][key] = value end
        end
        return nextValue
    end)())
    if not ok then app:Print(app.L.readonly) end
    if self.running then render(self) end
    return ok
end

function component:Diagnose()
    local cfg = Model:Normalize(config())
    app:Print(string.format("ownedBars: running=%s enabled=%s bindings=native paging=native",
        self.running and "yes" or "no", cfg.enabled and "yes" or "no"))
    for _, id in ipairs(Model.BARS) do
        local bar = cfg.bars[id]
        local plan = Model:Plan(bar)
        local native = _G[nativeName(id)]
        local nativeShown = native and native:IsShown() and "yes" or "no"
        app:Print(string.format("  %s: slots=%d-%d columns=%d size=%d gap=%d rows=%d ownShown=%s nativeShown=%s",
            id, RANGE[id][1], RANGE[id][2], bar.columns, bar.size, bar.gap, plan.rows,
            self.barsById and self.barsById[id] and self.barsById[id].frame:IsShown() and "yes" or "no",
            nativeShown))
    end
    app:Print("  " .. app.L.ownedBarsNote)
end

function component:Command(rest)
    local action, argument = "", ""
    if type(rest) == "string" then
        action, argument = rest:match("^%s*(%S*)%s*(.-)%s*$")
        action, argument = action or "", argument or ""
    end
    action = action:lower()
    if action == "on" then
        self:SetOption("enabled", true)
        app:Print(app.L.ownedBarsOn)
    elseif action == "off" then
        self:SetOption("enabled", false)
        app:Print(app.L.ownedBarsOff)
    elseif action == "size" then
        self:SetOption("size", tonumber(argument) or 30)
    elseif action == "columns" then
        self:SetOption("columns", tonumber(argument) or 12)
    else
        self:Diagnose()
    end
end
