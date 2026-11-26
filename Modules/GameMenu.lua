local _, app = ...

-- One LumaUI entry in the client's Esc menu. The menu rebuilds its pooled
-- buttons on every show, so the entry is re-added after each native rebuild and
-- every decoration is removed again before the client can reuse the button.
-- Without the pool API the component reports itself unsupported and the plugin
-- settings category and the minimap launcher stay the entry points.

local function pool()
    local menu = _G.GameMenuFrame
    return menu and menu.buttonPool
end

local function activeButtons()
    local list, buttons = {}, pool()
    if buttons and type(buttons.EnumerateActive) == "function" then
        for button in buttons:EnumerateActive() do list[#list + 1] = button end
    end
    return list
end

local function buttonText(button)
    if type(button.GetText) == "function" then
        local ok, text = pcall(button.GetText, button)
        if ok then return text end
    end
end

local module
module = app:RegisterComponent({ id = "gameMenu", label = "gameMenu", defaultEnabled = true,
    Supported = function()
        local menu = _G.GameMenuFrame
        return menu ~= nil and type(menu.AddButton) == "function" and menu.buttonPool ~= nil
            and type(menu.HookScript) == "function"
    end,

    -- Removes only what this component added: our scripts and the overlay.
    Release = function(self)
        local button, overlay = self.button, self.overlay
        self.button = nil
        if overlay then
            if app.Transitions then app.Transitions:Cancel(overlay, "hover") end
            overlay:SetAlpha(0)
            overlay:Hide()
        end
        if button then
            button:SetScript("OnEnter", nil)
            button:SetScript("OnLeave", nil)
            button:SetScript("OnMouseDown", nil)
            button:SetScript("OnMouseUp", nil)
            if overlay then overlay:SetParent(UIParent) end
        end
    end,

    Open = function()
        pcall(function() if _G.PlaySound and _G.SOUNDKIT then PlaySound(SOUNDKIT.IG_MAINMENU_OPTION) end end)
        if type(_G.HideUIPanel) == "function" then HideUIPanel(GameMenuFrame) else GameMenuFrame:Hide() end
        if app.Settings then app.Settings:Open("overview") end
    end,

    Decorate = function(self, button)
        if not self.overlay then
            local overlay = CreateFrame("Frame", nil, button, "BackdropTemplate")
            overlay:EnableMouse(false)
            self.overlay = overlay
        end
        local overlay = self.overlay
        overlay:SetParent(button)
        overlay:ClearAllPoints()
        overlay:SetAllPoints(button)
        overlay:SetFrameLevel(button:GetFrameLevel() + 1)
        app.Theme:Panel(overlay, false)
        overlay:SetAlpha(0)
        overlay:Show()
        self.button = button
        local function fade(alpha)
            if app.Transitions and app.Transitions.MotionEnabled() then
                app.Transitions:Fade(overlay, overlay, alpha, 0.1, nil, "hover")
            else
                if app.Transitions then app.Transitions:Cancel(overlay, "hover") end
                overlay:SetAlpha(alpha)
            end
        end
        button:SetScript("OnEnter", function() fade(1) end)
        button:SetScript("OnLeave", function() fade(0) end)
        button:SetScript("OnMouseDown", function() overlay:SetAlpha(0.7) end)
        button:SetScript("OnMouseUp", function() overlay:SetAlpha(button:IsMouseOver() and 1 or 0) end)
    end,

    -- Adds the entry in front of the native add-ons entry.
    Insert = function(self)
        local menu = _G.GameMenuFrame
        if not menu or self.button then return end
        local before = {}
        for _, button in ipairs(activeButtons()) do before[button] = true end
        menu:AddButton(app.L.menuEntry, function() self:Open() end)
        local mine, anchor
        for _, button in ipairs(activeButtons()) do
            if not before[button] then mine = button end
            if buttonText(button) == (_G.ADDONS or "AddOns") then anchor = button end
        end
        if not mine then return end
        if anchor and anchor.layoutIndex then mine.layoutIndex = anchor.layoutIndex - 0.5 end
        self:Decorate(mine)
        if type(menu.MarkDirty) == "function" then menu:MarkDirty() end
    end,

    Enable = function(self)
        local menu = GameMenuFrame
        if not self.hooked then
            self.hooked = true
            -- Hooks stay installed (the client cannot remove them) and stay
            -- inert while the component is not running.
            hooksecurefunc(menu, "Reset", function()
                if self.running then self:Release() end
            end)
            menu:HookScript("OnShow", function()
                if self.running then app:Call("gameMenu/insert", self.Insert, self) end
            end)
            menu:HookScript("OnEvent", function()
                if self.running and not self.button then app:Call("gameMenu/insert", self.Insert, self) end
            end)
        end
        if menu:IsShown() and not self.button then self:Insert() end
    end,

    Refresh = function(self)
        if self.overlay and self.button then app.Theme:Panel(self.overlay, false) end
    end,

    Disable = function(self)
        self:Release()
        local menu = _G.GameMenuFrame
        if menu and menu:IsShown() and type(menu.InitButtons) == "function" then
            app:Call("gameMenu/rebuild", menu.InitButtons, menu)
        end
    end,
})
