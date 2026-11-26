local _, app = ...

-- One LumaUI entry in the client's Esc menu.
--
-- The menu rebuilds its pooled buttons on every show, and `AddButton` overwrites
-- the button's OnEnter/OnLeave scripts. The decoration therefore never wraps the
-- whole button in a tinted panel: four hairlines are drawn on the button itself
-- and the interaction is observed with `HookScript`, attached only after
-- `AddButton` has returned the instance for this generation. A recycled button
-- that becomes another entry, or a stale listener from a previous generation,
-- exits at the first check instead of drawing on a foreign row.
--
-- The pointer already being on the button when the menu opens is not an OnEnter:
-- a single zero-delay probe asks `IsMouseOver` once, validates the same instance
-- and generation, and starts the same trace.

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

local function mouseOver(button)
    if not button or type(button.IsMouseOver) ~= "function" then return false end
    local ok, value = pcall(button.IsMouseOver, button)
    return ok and app.Capabilities.Plain(value, "boolean") == true
end

local module
module = app:RegisterComponent({ id = "gameMenu", label = "gameMenu", defaultEnabled = true,
    Supported = function()
        local menu = _G.GameMenuFrame
        return menu ~= nil and type(menu.AddButton) == "function" and menu.buttonPool ~= nil
            and type(menu.HookScript) == "function"
    end,

    -- Removes only what this component added. Bumping the generation makes every
    -- listener created for the old instance inert; the client's own scripts stay
    -- installed and the pooled button keeps working for whichever entry reuses it.
    Release = function(self)
        local button = self.button
        self.generation = (self.generation or 0) + 1
        self.button, self.probe = nil, nil
        if button and app.EdgeTrace then app.EdgeTrace:Release(button) end
    end,

    Open = function()
        pcall(function() if _G.PlaySound and _G.SOUNDKIT then PlaySound(SOUNDKIT.IG_MAINMENU_OPTION) end end)
        if type(_G.HideUIPanel) == "function" then HideUIPanel(GameMenuFrame) else GameMenuFrame:Hide() end
        if app.Settings then app.Settings:Open("overview") end
    end,

    -- Observes this generation's button. The host keeps its own OnClick, focus and
    -- hit area; Enter starts the perimeter walk, Leave reverses it, and a press
    -- only brightens the line the hover already drew.
    Decorate = function(self, button)
        local trace = app.EdgeTrace
        if not trace then return end
        self.button = button
        self.generation = (self.generation or 0) + 1
        local generation = self.generation
        local function live(host)
            return module.running == true and module.button == host and module.generation == generation
        end
        local function onEnter(host)
            if not live(host) then return end
            trace:Enter(host)
        end
        local function onLeave(host)
            if not live(host) then return end
            trace:Leave(host)
        end
        local function onDown(host)
            if not live(host) then return end
            trace:Press(host, true)
        end
        local function onUp(host)
            if not live(host) then return end
            trace:Press(host, false)
            -- The release point can be off the button: calibrate with the current
            -- cursor state instead of assuming the leave event fired.
            if not mouseOver(host) then trace:Leave(host) end
        end
        button:HookScript("OnEnter", onEnter)
        button:HookScript("OnLeave", onLeave)
        button:HookScript("OnMouseDown", onDown)
        button:HookScript("OnMouseUp", onUp)
        button.lumaTraceToken = { generation = generation, script = button:GetScript("OnEnter") }
        trace:Set(button, 0)
        -- `AddButton` can return before the menu finishes laying out. One probe
        -- covers "the menu appeared under a resting pointer"; it never polls.
        if type(C_Timer) == "table" and type(C_Timer.After) == "function" then
            local token = button.lumaTraceToken
            self.probe = token
            C_Timer.After(0, function()
                if self.probe ~= token or not live(button) then return end
                self.probe = nil
                if not button:IsShown() then return end
                local state = button.lumaTrace
                if state and (state.progress or 0) > 0 then return end
                if mouseOver(button) then trace:Enter(button) end
            end)
        end
    end,

    -- Adds the entry in front of the native add-ons entry.
    Insert = function(self)
        local menu = _G.GameMenuFrame
        if not menu or self.button then return end
        local before = {}
        for _, button in ipairs(activeButtons()) do before[button] = true end
        -- The client's AddButton returns the pooled button it just configured
        -- (verified in MainMenuFrameTemplates.lua). Use it directly; the diff of
        -- the active list stays as the fallback for a build that returns
        -- nothing.
        local mine = menu:AddButton(app.L.menuEntry, function() self:Open() end)
        local anchor
        for _, button in ipairs(activeButtons()) do
            if not before[button] and not mine then mine = button end
            if buttonText(button) == (_G.ADDONS or "AddOns") then anchor = button end
        end
        if not mine then return end
        if anchor and anchor.layoutIndex then mine.layoutIndex = anchor.layoutIndex - 0.5 end
        self:Decorate(mine)
        if app.GameMenuSkin then app.GameMenuSkin:ApplyButton(mine) end
        if type(menu.MarkDirty) == "function" then menu:MarkDirty() end
    end,

    Enable = function(self)
        local menu = _G.GameMenuFrame
        self.generation = self.generation or 0
        if not self.hooked then
            self.hooked = true
            -- Hooks stay installed (the client cannot remove them) and stay inert
            -- while the component is not running.
            hooksecurefunc(menu, "Reset", function()
                if self.running then self:Release() end
            end)
            -- `InitButtons` is the one rebuild path: OnShow, OnEvent and every
            -- status change end there. Hooking it post-return means the pooled
            -- buttons exist and are laid out, so the skin and the LumaUI entry
            -- are applied to the finished menu instead of racing its build.
            if type(menu.InitButtons) == "function" then
                hooksecurefunc(menu, "InitButtons", function()
                    if not self.running then return end
                    app:Call("gameMenu/skin", self.Skin, self)
                    app:Call("gameMenu/insert", self.Insert, self)
                end)
            end
            menu:HookScript("OnShow", function()
                if not self.running then return end
                -- A build without InitButtons still gets the skin and the entry.
                if type(menu.InitButtons) ~= "function" then self:Skin() end
                app:Call("gameMenu/insert", self.Insert, self)
            end)
            menu:HookScript("OnHide", function()
                if self.running then self:Release() end
            end)
            menu:HookScript("OnEvent", function()
                if self.running and not self.button then app:Call("gameMenu/insert", self.Insert, self) end
            end)
        end
        if menu:IsShown() then
            self:Skin()
            if not self.button then self:Insert() end
        end
    end,

    -- Re-applies LumaUI's own surface, type and button art after a theme change
    -- or a profile switch. The ring keeps its progress: this is a repaint, not a
    -- new hover.
    Skin = function(self)
        if app.GameMenuSkin then app.GameMenuSkin:Apply() end
    end,

    Refresh = function(self)
        if app.GameMenuSkin then app.GameMenuSkin:Refresh() end
        local button = self.button
        if button and app.EdgeTrace then
            -- A theme or accent change repaints the same ring; it never restarts
            -- the walk, so a hover in progress keeps its progress.
            local state = button.lumaTrace
            app.EdgeTrace:Draw(button, state and state.progress or 0)
        end
    end,

    Disable = function(self)
        self:Release()
        -- Hand the menu back before the rebuild below: border, header, button
        -- art, fonts, layout constants and width all return to the recorded
        -- client values.
        if app.GameMenuSkin then app.GameMenuSkin:Restore() end
        local menu = _G.GameMenuFrame
        if menu and menu:IsShown() and type(menu.InitButtons) == "function" then
            app:Call("gameMenu/rebuild", menu.InitButtons, menu)
        end
    end,
})
