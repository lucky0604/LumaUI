local _, app = ...

-- Three centred bars, stacked upwards, hidden behind an alpha fade until the
-- pointer reaches the action area. The bars stay children of UIParent and are
-- never Show/Hide'd in combat: only alpha, points and parent changes are used,
-- and every protected write goes through the shared queue. This follows the
-- mechanism used by the reference action-bar modules without importing their
-- code, names or configuration.

local BARS = {
    { key = "main", frame = "MainActionBar", prefix = "ActionButton" },
    { key = "bar2", frame = "MultiBarBottomLeft", prefix = "MultiBarBottomLeftButton" },
    { key = "bar3", frame = "MultiBarBottomRight", prefix = "MultiBarBottomRightButton" },
}
local HIDDEN = { "MultiBarRight", "MultiBarLeft", "MultiBar5", "MultiBar6", "MultiBar7" }
local BOTTOM, GAP = 56, 4
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

local park
local function parked()
    if not park then
        park = CreateFrame("Frame", "LumaUIActionBarsPark", UIParent)
        park:Hide()
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
        shown = type(bar.IsShown) == "function" and bar:IsShown() or nil,
    }
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

local function styleFont(self, control)
    if not object(control) or self.styled[control] then return end
    local okFont, font, size, flags = pcall(control.GetFont, control)
    local okColor, r, g, b, a = pcall(control.GetTextColor, control)
    self.styled[control] = {
        font = okFont and font or nil,
        size = okFont and size or nil,
        flags = okFont and flags or nil,
        color = okColor and { r, g, b, a } or nil,
    }
    pcall(control.SetFont, control, app.Type:Face(), 13, "OUTLINE")
    local text = app.Theme.colors.text
    pcall(control.SetTextColor, control, text[1], text[2], text[3], 1)
end

-- Native countdown strings are anchored by the action-button template; on the
-- Pearl buttons the remaining time belongs in the middle of the icon, so move
-- this one font string and remember its original points for disable.
local function centerCountdown(self, control, parent)
    if not object(control) or type(control.GetPoint) ~= "function" then return end
    styleFont(self, control)
    local entry = self.styled[control]
    if not entry then return end
    if not entry.pointsRecorded then
        entry.pointsRecorded = true
        entry.points = {}
        for index = 1, 4 do
            local ok, point, relative, relativePoint, x, y = pcall(control.GetPoint, control, index)
            if not ok or not point then break end
            entry.points[#entry.points + 1] = { point, relative, relativePoint, x, y }
        end
    end
    pcall(control.ClearAllPoints, control)
    pcall(control.SetPoint, control, "CENTER", parent, "CENTER", 0, 0)
    pcall(control.SetJustifyH, control, "CENTER")
    pcall(control.SetJustifyV, control, "MIDDLE")
    if type(control.SetDrawLayer) == "function" then
        pcall(control.SetDrawLayer, control, "OVERLAY")
    end
end

local function styleCooldown(self, button)
    for _, key in ipairs({ "cooldown", "chargeCooldown" }) do
        local cooldown = button[key]
        if object(cooldown) then
            if type(cooldown.SetHideCountdownNumbers) == "function" then
                pcall(cooldown.SetHideCountdownNumbers, cooldown, false)
            end
            if type(cooldown.SetSwipeColor) == "function" then
                if self.swipes[cooldown] == nil then
                    local ok, r, g, b, a = pcall(cooldown.GetSwipeColor, cooldown)
                    self.swipes[cooldown] = ok and { r, g, b, a } or false
                end
                pcall(cooldown.SetSwipeColor, cooldown, 0.03, 0.04, 0.06, 0.82)
            end
            local control
            if type(cooldown.GetCountdownFontString) == "function" then
                local ok, value = pcall(cooldown.GetCountdownFontString, cooldown)
                if ok then control = value end
            end
            if not object(control) and type(cooldown.GetRegions) == "function" then
                local ok, regions = pcall(function() return { cooldown:GetRegions() } end)
                if ok and type(regions) == "table" then
                    for _, region in ipairs(regions) do
                        if object(region) and type(region.GetObjectType) == "function" then
                            local isFont, kind = pcall(region.GetObjectType, region)
                            if isFont and kind == "FontString" then
                                control = region
                                break
                            end
                        end
                    end
                end
            end
            if object(control) then
                -- Both the cooldown and the charge-recharge timer use the same
                -- centred placement, so a stack never leaves one number at the
                -- corner while the other sits in the middle of the icon.
                centerCountdown(self, control, button)
            end
        end
    end
end

local function sampleRunning()
    local sample = app.components and app.components.actionButtons
    return sample ~= nil and sample.running == true
end

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

local function layout(self)
    if inCombat() then return false end
    local parkFrame = parked()
    for _, name in ipairs(HIDDEN) do
        local bar = named(name)
        if bar then
            recordBar(bar)
            if bar:GetParent() ~= parkFrame then pcall(bar.SetParent, bar, parkFrame) end
        end
    end

    local previous
    for index, def in ipairs(BARS) do
        local bar, buttons = buttonsOf(def)
        if bar then
            recordBar(bar)
            pcall(bar.SetScale, bar, 1)
            pcall(bar.Show, bar)
            pcall(bar.ClearAllPoints, bar)
            if not previous then
                pcall(bar.SetPoint, bar, "BOTTOM", UIParent, "BOTTOM", 0, BOTTOM)
            else
                pcall(bar.SetPoint, bar, "BOTTOM", previous, "TOP", 0, GAP)
            end
            pcall(bar.SetAlpha, bar, self.alpha or 0)
            self.bars[def.key] = bar
            previous = bar
            for _, button in ipairs(buttons) do styleCooldown(self, button) end
        end
    end
    skinButtons(self)
    return true
end

local function styleBars(self)
    for _, def in ipairs(BARS) do
        local _, buttons = buttonsOf(def)
        for _, button in ipairs(buttons) do styleCooldown(self, button) end
    end
end

local function apply(self)
    if not layout(self) then
        self.pending = true
        app.Queue:Run(LAYOUT_JOB, function() layout(self) end)
    end
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

local function isOver(self)
    if editModeOpen() then return true end
    for _, bar in pairs(self.bars) do
        if mouseOver(bar) then return true end
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
    end
end

local function restoreAll(self)
    releaseSkins(self)
    for _, bar in pairs(self.bars or {}) do restoreBar(bar) end
    for _, name in ipairs(HIDDEN) do
        local bar = named(name)
        if bar then restoreBar(bar) end
    end
    for control, original in pairs(self.styled or {}) do
        if original.font and object(control) then
            pcall(control.SetFont, control, original.font, original.size, original.flags)
        end
        if original.color and object(control) then
            pcall(control.SetTextColor, control, original.color[1], original.color[2],
                original.color[3], original.color[4])
        end
        if original.pointsRecorded and object(control) then
            pcall(control.ClearAllPoints, control)
            for _, point in ipairs(original.points) do
                pcall(control.SetPoint, control, point[1], point[2], point[3], point[4], point[5])
            end
        end
    end
    for cooldown, original in pairs(self.swipes or {}) do
        if original and object(cooldown) then
            pcall(cooldown.SetSwipeColor, cooldown, original[1], original[2], original[3], original[4])
        end
    end
    self.bars = {}
    self.styled = {}
    self.swipes = {}
end

app:RegisterComponent({
    id = "actionBars", label = "actionBars", defaultEnabled = true,
    Supported = function() return named("MainActionBar") ~= nil end,
    Enable = function(self)
        self.bars = self.bars or {}
        self.styled = self.styled or {}
        self.swipes = self.swipes or {}
        self.skins = self.skins or {}
        self.sampleOwned = false
        self.alpha = 0
        self.target = 0
        self.lastOver = 0
        self.pending = nil
        self.ticking = true
        apply(self)
        if type(C_Timer) == "table" and type(C_Timer.NewTicker) == "function" then
            self.ticker = C_Timer.NewTicker(FADE_STEP, function() step(self) end)
        end
        self:Listen("EDIT_MODE_LAYOUTS_UPDATED", function() apply(self) end)
        self:Listen("PLAYER_ENTERING_WORLD", function() apply(self) end)
        self:Listen("PLAYER_REGEN_ENABLED", function()
            if self.pending then apply(self) else styleBars(self) end
        end)
        -- Cooldown widgets can be created lazily by the client; restyle the
        -- first time they appear, but only outside combat.
        self:Listen("ACTIONBAR_UPDATE_COOLDOWN", function()
            if not inCombat() then styleBars(self) end
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
    end,
    Refresh = function(self) apply(self) end,
    Disable = function(self)
        self.ticking = false
        if self.ticker then
            pcall(self.ticker.Cancel, self.ticker)
            self.ticker = nil
        end
        for _, bar in pairs(self.bars or {}) do pcall(bar.SetAlpha, bar, 1) end
        if inCombat() then
            app.Queue:Run(RESTORE_JOB, function() restoreAll(self) end)
        else
            restoreAll(self)
        end
    end,
})
