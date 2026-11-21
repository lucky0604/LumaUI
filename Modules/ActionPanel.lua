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

local component

local function barFrame(name)
    local frame = _G[name]
    if frame and type(frame.SetPoint) == "function" then return frame end
    return nil
end

-- Creation and painting are separate: a panel that already exists must still
-- follow profile, theme and opacity changes, so refresh never skips a cached
-- panel. Anchoring to the bar keeps movement and Edit Mode scaling native.
local function panelFor(self, bar)
    local panel = self.panels[bar]
    if panel then return panel end
    panel = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    panel:EnableMouse(false)
    panel:SetPoint("TOPLEFT", bar, "TOPLEFT", -PAD, PAD)
    panel:SetPoint("BOTTOMRIGHT", bar, "BOTTOMRIGHT", PAD, -PAD)
    local level = 1
    if type(bar.GetFrameLevel) == "function" then
        local ok, value = pcall(bar.GetFrameLevel, bar)
        if ok and type(value) == "number" then level = value end
    end
    panel:SetFrameLevel(math.max(0, level - 1))
    app.Theme:PaintSurface(panel, "hud")
    self.panels[bar] = panel
    -- Follow the bar's own visibility.
    if type(bar.HookScript) == "function" then
        bar:HookScript("OnShow", function()
            if component.running then panel:Show() end
        end)
        bar:HookScript("OnHide", function() panel:Hide() end)
    end
    return panel
end

local function refresh(self)
    local seen = {}
    for _, name in ipairs(BARS) do
        local bar = barFrame(name)
        if bar then
            local panel = panelFor(self, bar)
            seen[panel] = true
            -- Repaint every cached panel so an opacity or accent change reaches
            -- bars that were created earlier in the session.
            app.Theme:PaintSurface(panel, "hud")
            if bar:IsShown() then panel:Show() else panel:Hide() end
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
end

component = app:RegisterComponent({ id = "actionPanel", label = "actionPanel", defaultEnabled = false,
    Supported = function() return type(_G.MainActionBar) ~= "nil" end,
    Enable = function(self)
        self.panels = self.panels or {}
        app.Queue:Run("actionPanel/apply", function()
            if self.running then refresh(self) end
        end)
    end,
    Refresh = function(self)
        refresh(self)
    end,
    Disable = function(self)
        for _, panel in pairs(self.panels or {}) do panel:Hide() end
    end,
})
