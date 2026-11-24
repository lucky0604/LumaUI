local _, app = ...

-- A decorative panel behind the game's own action bars. The 0.4.0 attempt to
-- restyle the buttons themselves was reverted after it looked broken in game,
-- so this version only draws a LumaUI backing: one panel behind each bar, in
-- the bar's own frame level minus one. Buttons, bindings, paging and drag all
-- stay exactly as the game draws them, and disabling just hides the panels.
--
-- The panels are anchored to their bar, so Edit Mode moves and scales them
-- with it without LumaUI ever writing into the native layout.

local BARS = {
    "MainActionBar",
    "MultiBarBottomLeft",
    "MultiBarBottomRight",
    "MultiBar5",
    "MultiBar6",
    "MultiBar7",
    "PetActionBar",
    "StanceBar",
}
local PAD = 4
local JOB = "actionPanel/apply"
local STRATA = { BACKGROUND = true, LOW = true, MEDIUM = true, HIGH = true,
    DIALOG = true, FULLSCREEN = true, FULLSCREEN_DIALOG = true, TOOLTIP = true }

local component
local refresh

local function barFrame(name)
    local frame = _G[name]
    if frame and type(frame.SetPoint) == "function" then
        if type(frame.IsForbidden) == "function" then
            local ok, value = pcall(frame.IsForbidden, frame)
            if not ok or value then return nil end
        end
        return frame
    end
    return nil
end

local function visible(bar)
    local method = bar.IsVisible or bar.IsShown
    if type(method) ~= "function" then return false end
    local ok, result = pcall(method, bar)
    return ok and result == true
end

local function updateLayer(panel, bar)
    local strata
    if type(bar.GetFrameStrata) == "function" then
        local ok, value = pcall(bar.GetFrameStrata, bar)
        value = ok and app.Capabilities.Plain(value, "string") or nil
        if value and STRATA[value] then strata = value end
    end
    local level
    if type(bar.GetFrameLevel) == "function" then
        local ok, value = pcall(bar.GetFrameLevel, bar)
        value = ok and app.Capabilities.Plain(value, "number") or nil
        if value then level = value end
    end
    -- A panel at the same level can cover button art unpredictably. If the
    -- actual strata or a strictly lower level cannot be established, leave
    -- this bar undecorated until a later refresh can establish both.
    if not strata or not level or level < 1 then
        panel.lumaLayerSafe = false
        return false
    end
    panel:SetFrameStrata(strata)
    panel:SetFrameLevel(level - 1)
    panel.lumaLayerSafe = true
    return true
end

local function sync()
    if component.running then
        refresh(component)
    else
        component.activeBars = {}
        for _, panel in pairs(component.panels or {}) do panel:Hide() end
        component.failedBars = {}
    end
end

-- The bars stay on screen at alpha 0; a separate backing would otherwise hang
-- behind buttons that are visually gone. Reading the bar component's published
-- fade keeps one driver and leaves the panels opaque when the bars component is
-- off (the native bars are then fully visible and still need their backing).
local function barAlpha()
    local bars = app.components.actionBars
    if bars and bars.running then
        local alpha = app.Capabilities.Plain(bars.alpha, "number")
        if alpha then return math.max(0, math.min(1, alpha)) end
    end
    return 1
end

local function applyAlpha(self)
    local alpha = barAlpha()
    self.panelAlpha = alpha
    for _, panel in pairs(self.panels or {}) do pcall(panel.SetAlpha, panel, alpha) end
end

-- Creation and painting are separate: a panel that already exists must still
-- follow profile, theme and opacity changes, so refresh never skips a cached
-- panel. Anchoring to the bar keeps movement and Edit Mode scaling native.
local function panelFor(self, bar)
    local panel = self.panels[bar]
    if panel then return panel end
    panel = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    panel:Hide()
    panel:EnableMouse(false)
    panel:SetPoint("TOPLEFT", bar, "TOPLEFT", -PAD, PAD)
    panel:SetPoint("BOTTOMRIGHT", bar, "BOTTOMRIGHT", PAD, -PAD)
    updateLayer(panel, bar)
    app.Theme:PaintSurface(panel, "hud")
    self.panels[bar] = panel
    -- Follow the bar's own visibility.
    if type(bar.HookScript) == "function" then
        bar:HookScript("OnShow", function()
            if component.running and component.panels[bar] == panel
                and component.activeBars and component.activeBars[bar] then
                -- Its level may have changed while hidden. Re-check instead of
                -- showing on the strength of an earlier layer measurement.
                app.Queue:Run(JOB, sync)
            end
        end)
        bar:HookScript("OnHide", function() panel:Hide() end)
    end
    if type(hooksecurefunc) == "function" and type(bar.UpdateFrameStrata) == "function" then
        pcall(hooksecurefunc, bar, "UpdateFrameStrata", function()
            if component.running and component.panels[bar] == panel
                and component.activeBars and component.activeBars[bar] then
                app.Queue:Run(JOB, sync)
            end
        end)
    end
    return panel
end

refresh = function(self)
    local seen = {}
    local active, skipped = {}, {}
    self.failedBars = self.failedBars or {}
    for _, name in ipairs(BARS) do
        local bar = barFrame(name)
        if bar and not self.failedBars[bar] then
            local ok, problem = pcall(function()
                local panel = panelFor(self, bar)
                app.Theme:PaintSurface(panel, "hud")
                local safe = updateLayer(panel, bar)
                if safe and visible(bar) then panel:Show() else panel:Hide() end
                if not safe then skipped[#skipped + 1] = name end
                seen[panel] = true
                active[bar] = true
            end)
            if not ok then
                local panel = self.panels[bar]
                if panel then pcall(panel.Hide, panel) end
                self.panels[bar] = nil
                self.failedBars[bar] = true
                app:Report("actionPanel/" .. name, problem)
            end
        end
    end
    -- A panel whose bar is gone still follows the current theme, so it is not
    -- stale if the client builds that bar again later.
    for _, panel in pairs(self.panels or {}) do
        if not seen[panel] then
            app.Theme:PaintSurface(panel, "hud")
            panel:Hide()
        end
    end
    self.activeBars = active
    self.skippedBars = skipped
    applyAlpha(self)
end

component = app:RegisterComponent({ id = "actionPanel", label = "actionPanel", defaultEnabled = false,
    Supported = function() return type(_G.MainActionBar) ~= "nil" end,
    Enable = function(self)
        self.panels = self.panels or {}
        self:Listen("EDIT_MODE_LAYOUTS_UPDATED", function() app.Queue:Run(JOB, sync) end)
        app:Subscribe(self, "ACTION_BARS_ALPHA", function()
            if self.running then applyAlpha(self) end
        end)
        app.Queue:Run(JOB, sync)
    end,
    Refresh = function(self)
        app.Queue:Run(JOB, sync)
    end,
    Disable = function(self)
        app.Queue:Run(JOB, sync)
    end,
})

function component:Describe()
    if not self.running or not self.skippedBars or #self.skippedBars == 0 then return nil end
    return "actionPanel: " .. app.L.actionPanelLayerUnavailable .. " · " .. table.concat(self.skippedBars, ", ")
end

-- `/luma bars`: a read-only ownership report for the action area. Edit Mode
-- owns every native bar's position, visibility and scale; LumaUI never writes
-- them, so the report only reads what the client itself recorded: which bars
-- exist, whether they are on screen, where their anchor sits and whether the
-- client still considers them at the default layout position. This gives the
-- /fstack answer ("which frame is that row?") without touching anything.
-- The Edit Mode system index names (MainBar, Bar2, Extra1...) come from the
-- client's own XML KeyValue wiring, so the report speaks Edit Mode's terms.
local REPORT_BARS = {
    { name = "MainActionBar", system = "MainBar" },
    { name = "MultiBarBottomLeft", system = "Bar2" },
    { name = "MultiBarBottomRight", system = "Bar3" },
    { name = "MultiBarRight", system = "Right1" },
    { name = "MultiBarLeft", system = "Right2" },
    { name = "MultiBar5", system = "Extra1" },
    { name = "MultiBar6", system = "Extra2" },
    { name = "MultiBar7", system = "Extra3" },
    { name = "StanceBar", system = "Stance" },
    { name = "PetActionBar", system = "Pet" },
}

-- Top-left corners of the bars already reported as visible, used to flag two
-- bars sitting on the same spot. Reset per report so repeated runs stay honest.
local shownPlaces = {}

local function reportLine(entry)
    local frame = barFrame(entry.name)
    if not frame then
        return string.format("  %-18s absent", entry.name)
    end
    local function yes(value) return value and "yes" or "no" end
    local shown = false
    local okShown, visible = pcall(frame.IsVisible or frame.IsShown, frame)
    shown = okShown and visible == true
    -- Alpha 0 still reports IsShown; the fade leaves the bars hit-testable and
    -- only the report's alpha column tells a faded bar from a visible one.
    local alphaText = "?"
    if type(frame.GetAlpha) == "function" then
        local okAlpha, alpha = pcall(frame.GetAlpha, frame)
        alpha = okAlpha and app.Capabilities.Plain(alpha, "number") or nil
        if alpha then alphaText = string.format("%.2f", alpha) end
    end
    -- GetRect returns scaled screen coordinates already (left, bottom, width,
    -- height); they are plain numbers, so formatting them is safe. A client
    -- that reports no rect keeps the "?" placeholder instead of guessing.
    local place = "?"
    local left, bottom
    local okRect, rectLeft, rectBottom = pcall(frame.GetRect, frame)
    if okRect and app.Capabilities.Plain(rectLeft, "number") and app.Capabilities.Plain(rectBottom, "number") then
        left, bottom = rectLeft, rectBottom
        place = string.format("x=%.0f y=%.0f", left, bottom)
    end
    local atDefault = "?"
    if type(frame.IsInDefaultPosition) == "function" then
        local okDefault, value = pcall(frame.IsInDefaultPosition, frame)
        if okDefault then atDefault = yes(value == true) end
    end
    local count = 0
    if type(frame.actionButtons) == "table" then
        for _, button in ipairs(frame.actionButtons) do
            local okButton, shownButton = pcall(button.IsShown, button)
            if okButton and shownButton then count = count + 1 end
        end
    end
    local line = string.format("  %-18s shown=%s alpha=%s %s default=%s buttons=%d",
        entry.name, yes(shown), alphaText, place, atDefault, count)
    -- Two visible bars at the same top-left corner are stacked on each other;
    -- naming the overlap turns "the screen is messy" into "these two bars".
    if left and bottom and shown then
        for otherName, otherPlace in pairs(shownPlaces) do
            if otherName ~= entry.name and otherPlace.left == left and otherPlace.bottom == bottom then
                line = line .. string.format(" · %s %s", app.L.barsOverlapAt, otherName)
            end
        end
    end
    if shown and left then
        shownPlaces[entry.name] = { left = left, bottom = bottom }
    end
    return line
end

function component:Diagnose()
    local running = self.running and "running" or tostring(self.status)
    shownPlaces = {}
    app:Print(app.L.barsReportHeader)
    app:Print(string.format("actionPanel: status=%s", running))
    for _, entry in ipairs(REPORT_BARS) do
        local line = reportLine(entry)
        if line then app:Print(line) end
    end
end
