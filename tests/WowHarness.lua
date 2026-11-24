local H = {}
local function noop() end
local secretValues = setmetatable({}, { __mode = "k" })
function H.Secret(value)
    local box = {}
    secretValues[box] = value
    return setmetatable(box, {
        __add = function() error("Secret arithmetic") end,
        __sub = function() error("Secret arithmetic") end,
        __div = function() error("Secret arithmetic") end,
        __lt = function() error("Secret comparison") end,
        __le = function() error("Secret comparison") end,
        __concat = function() error("Secret concatenation") end,
        __tostring = function() error("Secret conversion") end,
    })
end
local Frame = {}
Frame.__index = Frame
local function restricted(self)
    if H.combat and self.protected then error("Protected mutation in combat") end
end
function Frame:SetSize(w, h) restricted(self); self.width, self.height = w, h end
function Frame:SetWidth(w) restricted(self); self.width = w end
function Frame:SetHeight(h) restricted(self); self.height = h end
function Frame:GetWidth() return self.width or 100 end
function Frame:GetHeight() return self.height or 30 end
function Frame:SetPoint(...) restricted(self); self.point = { ... } end
function Frame:ClearAllPoints() restricted(self); self.point = nil end
function Frame:GetPoint(index)
    if (index or 1) == 1 and self.point then return unpack(self.point) end
end
function Frame:GetParent() return self.parent end
function Frame:SetParent(parent) restricted(self); self.parent = parent end
function Frame:SetAllPoints() end
function Frame:GetCenter()
    local point = self.point
    if point and point[1] == "CENTER" and type(point[4]) == "number" then return 960 + point[4], 540 + point[5] end
    return 960, 540
end
function Frame:SetScale(scale) restricted(self); self.scale = scale end
function Frame:GetScale() return self.scale or 1 end
-- GetRect mirrors the client contract: left/bottom in parent-scaled screen
-- coordinates. Frames start with no rect: the client always has one, but a
-- fabricated default would imply screen positions (e.g. two frames "over-
-- lapping") that no test asked for; a read-only report treats nil as "client
-- did not report a rect". Tests that need geometry set frame.rect directly.
function Frame:GetRect()
    if not self.rect then return nil end
    return self.rect.left, self.rect.bottom, self.rect.width, self.rect.height
end
function Frame:GetEffectiveScale() return self:GetScale() * (self.parent and self.parent:GetEffectiveScale() or 1) end
function Frame:GetName() return self.name end
function Frame:GetChildren() return self.children or {} end
function Frame:SetParent(parent)
    if self.parent and self.parent.children then
        for index = #self.parent.children, 1, -1 do
            if self.parent.children[index] == self then table.remove(self.parent.children, index) end
        end
    end
    self.parent = parent
    if parent then
        parent.children = parent.children or {}
        parent.children[#parent.children + 1] = self
    end
end
function Frame:GetTexCoord()
    local coords = self.texCoord or { 0, 0, 0, 0, 1, 1, 1, 1 }
    return unpack(coords)
end
function Frame:SetTexCoord(...) self.texCoord = { ... } end
function Frame:GetTextColor()
    local color = self.textColor or { 1, 1, 1, 1 }
    return unpack(color)
end
function Frame:SetTextColor(red, green, blue, alpha) self.textColor = { red, green, blue, alpha } end
function Frame:SetScript(event, fn) self.scripts[event] = fn end
function Frame:GetScript(event) return self.scripts[event] end
function Frame:HookScript(event, fn)
    local previous = self.scripts[event]
    self.scripts[event] = function(...)
        if previous then previous(...) end
        fn(...)
    end
    self.hookCount = (self.hookCount or 0) + 1
end
function Frame:Show()
    restricted(self)
    if self.shown then return end
    self.shown = true
    if self.scripts.OnShow then self.scripts.OnShow(self) end
end
function Frame:Hide()
    restricted(self)
    if not self.shown then return end
    self.shown = false
    if self.scripts.OnHide then self.scripts.OnHide(self) end
end
function Frame:SetShown(wanted) if wanted then self:Show() else self:Hide() end end
function Frame:IsShown() return self.shown end
function Frame:IsVisible() return self.shown and (not self.parent or self.parent:IsVisible()) end
function Frame:RegisterEvent(event) self.events[event] = true end
function Frame:RegisterUnitEvent(event, unit) self.events[event] = unit end
function Frame:UnregisterAllEvents() self.events = {} end
function Frame:SetAttribute(key, value) restricted(self); self.attributes[key] = value end
function Frame:GetAttribute(key) return self.attributes[key] end
function Frame:IsForbidden() return self.forbidden == true end
function Frame:GetFrameLevel() return self.level or 1 end
function Frame:SetFrameLevel(level) self.level = level end
function Frame:GetFrameStrata() return self.strata or "MEDIUM" end
function Frame:SetFrameStrata(strata) self.strata = strata end
function Frame:EnableMouse(enabled) self.mouseEnabled = enabled == true end
function Frame:IsMouseEnabled() return self.mouseEnabled == true end
function Frame:EnableMouseWheel(enabled) self.mouseWheelEnabled = enabled == true end
function Frame:IsMouseWheelEnabled() return self.mouseWheelEnabled == true end
function Frame:SetText(value) self.text = value end
function Frame:GetText() return self.text or "" end
function Frame:GetItem() return self.itemName, self.itemLink end
function Frame:SetFormattedText(format, ...)
    local args = { ... }
    for i = 1, select("#", ...) do if secretValues[args[i]] ~= nil then args[i] = secretValues[args[i]] end end
    self.text = string.format(format, unpack(args))
end
function Frame:SetFont(font, size, flags) self.font, self.fontSize, self.fontFlags = font, size, flags end
function Frame:GetFont() return self.font or "Fonts/Mock.ttf", self.fontSize or 13, self.fontFlags or "" end
function Frame:SetWordWrap(value) self.wordWrap = value ~= false end
-- Approximation of FontString:GetStringHeight for wrapped text. A font string
-- without a width (or with wrapping off) is one line; CJK code points count as
-- a full em, ASCII as a little over half. The real client returns the exact
-- laid-out height; tests only need the same ordering and sensible wrapping.
local function stringPixelWidth(text, size)
    local width, index, length = 0, 1, #text
    while index <= length do
        local byte = text:byte(index)
        local step, advance = 1, size * 0.55
        if byte >= 0xF0 then step, advance = 4, size
        elseif byte >= 0xE0 then step, advance = 3, size
        elseif byte >= 0xC0 then step, advance = 2, size * 0.6 end
        width = width + advance
        index = index + step
    end
    return width
end
function Frame:GetStringHeight()
    local value = self.text
    if type(value) ~= "string" or value == "" then return 0 end
    local size = self.fontSize or 13
    local lineHeight = size * 1.32
    local width = self.width
    if self.wordWrap == false or not width or width <= 0 then return lineHeight end
    local lines = math.max(1, math.ceil(stringPixelWidth(value, size) / width))
    return lines * lineHeight
end
function Frame:SetValue(value)
    self.value = value
    if self.scripts.OnValueChanged then self.scripts.OnValueChanged(self, value) end
end
function Frame:GetValue() return self.value end
function Frame:SetMinMaxValues(minimum, maximum) self.minimum, self.maximum = minimum, maximum end
function Frame:SetBackdrop(spec) self.backdrop = spec end
function Frame:SetBackdropColor(...) self.backgroundColor = { ... } end
function Frame:SetBackdropBorderColor(...) self.borderColor = { ... } end
function Frame:SetAlpha(alpha) self.alpha = alpha end
function Frame:GetAlpha() return self.alpha or 1 end
function Frame:SetDrawLayer(layer) self.drawLayer = layer end
function Frame:SetTexture(texture) self.texture = texture; self.atlas = nil end
function Frame:SetAtlas(atlas, useAtlasSize) self.atlas = atlas; self.texture = nil; self.atlasSize = useAtlasSize end
function Frame:SetColorTexture(...) self.color = { ... } end
function Frame:SetDesaturated(value) self.desaturated = value end
function Frame:IsDesaturated() return self.desaturated == true end
function Frame:GetVertexColor()
    local color = self.vertexColor or { 1, 1, 1, 1 }
    return unpack(color)
end
function Frame:SetVertexColor(...) self.vertexColor = { ... } end
function Frame:SetMaskTexture(texture) self.maskTexture = texture end
function Frame:SetStatusBarColor(...) self.barColor = { ... } end
function Frame:CreateTexture(name, layer)
    local texture = H.NewFrame(name, self)
    texture.drawLayer = layer
    return texture
end
function Frame:CreateFontString(name, layer)
    local font = H.NewFrame(name, self)
    font.drawLayer = layer
    return font
end
-- Animation groups behave like a minimal client implementation: Play starts the
-- group, Stop cancels it without firing OnFinished, and H.Advance moves time,
-- applies the interpolated alpha and fires OnFinished exactly once. A stub that
-- leaves Play/Stop as noops cannot prove a transition lifecycle.
function Frame:CreateAnimationGroup()
    local group = { owner = self, animations = {}, scripts = {} }
    function group:Play()
        self.playing, self.stopped, self.elapsed = true, false, 0
        H.groups[#H.groups + 1] = self
    end
    function group:Stop()
        self.playing, self.stopped = false, true
    end
    function group:SetScript(event, fn) self.scripts[event] = fn end
    function group:GetScript(event) return self.scripts[event] end
    function group:Finish()
        if not self.playing then return end
        self.playing = false
        if self.scripts.OnFinished then self.scripts.OnFinished(self) end
    end
    function group:CreateAnimation(kind)
        local anim = { kind = kind }
        function anim:SetFromAlpha(value) self.from = value end
        function anim:SetToAlpha(value) self.to = value end
        function anim:SetDuration(value) self.duration = value end
        function anim:SetSmoothing(value) self.smoothing = value end
        function anim:SetOffset(x, y) self.offset = { x, y } end
        self.animations[#self.animations + 1] = anim
        return anim
    end
    return group
end
for _, name in ipairs({ "SetClampedToScreen", "SetMovable", "RegisterForDrag", "StartMoving", "StopMovingOrSizing", "SetJustifyH", "SetJustifyV", "SetStatusBarTexture", "SetOrientation", "SetValueStep", "SetObeyStepOnDrag", "SetThumbTexture", "SetAutoFocus", "SetMaxLetters", "RegisterForClicks", "SetBagItem", "SetTextInsets" }) do Frame[name] = noop end
-- A real EditBox fires OnEditFocusLost from ClearFocus; the settings input
-- relies on that chain to leave its focus state, and HasFocus must agree.
function Frame:ClearFocus()
    self.focused = false
    if self.scripts and self.scripts.OnEditFocusLost then self.scripts.OnEditFocusLost(self) end
end
function Frame:SetScrollChild(child) self.scrollChild = child end
function Frame:GetScrollChild() return self.scrollChild end
function Frame:SetVerticalScroll(value) self.scrollValue = value end
function Frame:GetVerticalScroll() return self.scrollValue or 0 end
function Frame:SetOwner(owner) self.owner = owner end
function Frame:IsOwned(owner) return self.owner == owner end
function Frame:AddLine(message) self.lines = self.lines or {}; self.lines[#self.lines + 1] = message end
function Frame:AddTexture() return H.NewFrame(nil, self) end
function Frame:GetFontString() return self.fontString end
function H.NewFrame(name, parent, template)
    local frame = setmetatable({ name = name, scripts = {}, events = {}, attributes = {}, parent = parent, shown = true,
        protected = (template and template:find("Secure") ~= nil) or (parent and parent.protected) or false }, Frame)
    H.frames[#H.frames + 1] = frame
    if parent then
        parent.children = parent.children or {}
        parent.children[#parent.children + 1] = frame
    end
    if name then _G[name] = frame end
    return frame
end

function H.Fire(event, ...)
    local snapshot = {}
    for i, frame in ipairs(H.frames) do snapshot[i] = frame end
    for _, frame in ipairs(snapshot) do
        if frame.events[event] and frame.scripts.OnEvent then frame.scripts.OnEvent(frame, event, ...) end
    end
end

-- Moves simulated time forward: playing animation groups interpolate their alpha
-- and fire OnFinished when their duration is reached; C_Timer tickers fire once
-- per elapsed interval. This is the minimum needed to test completion and
-- cancellation without claiming the visuals were really rendered.
function H.Advance(seconds)
    seconds = tonumber(seconds) or 0
    if seconds <= 0 then return end
    -- Advancing the clock is part of advancing time: caches keyed on GetTime
    -- (the shared performance sample, cast and aura remainders) must expire
    -- exactly as they would in the client.
    H.now = (H.now or 0) + seconds
    local groups = {}
    for i, group in ipairs(H.groups or {}) do groups[i] = group end
    for _, group in ipairs(groups) do
        if group.playing then
            local duration = 0
            for _, anim in ipairs(group.animations) do
                if (anim.duration or 0) > duration then duration = anim.duration end
            end
            group.elapsed = (group.elapsed or 0) + seconds
            for _, anim in ipairs(group.animations) do
                if anim.kind == "Alpha" and group.owner and (anim.duration or 0) > 0 then
                    local progress = math.min(1, group.elapsed / anim.duration)
                    local from = anim.from or 0
                    local to = anim.to or 1
                    group.owner:SetAlpha(from + (to - from) * progress)
                end
            end
            if group.elapsed >= duration then group:Finish() end
        end
    end
    local timers = {}
    for i, timer in ipairs(H.timers or {}) do timers[i] = timer end
    for _, timer in ipairs(timers) do
        if timer.callback and (timer.interval or 0) > 0 and not timer.cancelled and not timer.fired then
            timer.elapsed = (timer.elapsed or 0) + seconds
            local steps = math.floor(timer.elapsed / timer.interval)
            if steps > 0 then
                timer.elapsed = timer.elapsed - steps * timer.interval
                for _ = 1, math.min(steps, 500) do
                    if timer.cancelled then break end
                    timer.callback()
                    -- A one-shot fires once, ever.
                    if timer.after then timer.fired = true; break end
                end
            end
        end
    end
end

function H.Combat(wanted)
    H.combat = wanted
    H.Fire(wanted and "PLAYER_REGEN_DISABLED" or "PLAYER_REGEN_ENABLED")
end

function H.Click(frame, button)
    local script = frame and frame.scripts and frame.scripts.OnClick
    if script then script(frame, button or "LeftButton") end
end

function H.Load(saved)
    H.frames, H.timers, H.messages, H.combat = {}, {}, {}, false
    H.groups = {}
    H.calls, H.modifiedClicks = {}, {}
    H.money, H.savedInstances, H.savedWorldBosses, H.warbandMoney = nil, nil, nil, nil
    H.subZone, H.selectedDockFrame, H.raidRequested = nil, nil, nil
    H.watchedFaction, H.maxLevel, H.durability = nil, nil, nil
    H.shiftDown, H.superTracked = false, nil
    H.bankType, H.bankView, H.bankUsable, H.bankTabs = nil, nil, nil, nil
    H.privateAnchorRefuse = nil
    -- A scene with LumaUI alone loaded; a test that needs another addon in the
    -- census replaces H.addons before loading the app.
    H.addons = {
        { name = "LumaUI", title = "LumaUI", loadable = true, reason = "", security = "INSECURE", loaded = true },
    }
    -- The legacy quest-panel tests drive the component directly, so the shared
    -- fixture opts in explicitly. The production default (off) is asserted by
    -- its own test instead of being implied by this fixture.
    _G.LumaUIDB = saved or {
        schema = 1,
        profiles = { Default = {
            -- The stock fixture stays on the pre-Pearl baseline so individual
            -- tests can opt into the visual replacements explicitly; the
            -- default-on policy is covered by its own test.
            modules = { questList = true, unitFrames = false, partyFrames = false,
                nameplates = false, actionBars = false },
            ui = { takeoverUnitFrames = false },
        } },
        migrations = { pearlBatch = true, questListDefault = true, visualModules = true,
            actionBars = true },
    }
    _G.unpack = table.unpack or unpack
    _G.WOW_PROJECT_ID, _G.WOW_PROJECT_MAINLINE = 1, 1
    _G.UISpecialFrames, _G.SlashCmdList = {}, {}
    _G.CreateFrame = function(_, name, parent, template) return H.NewFrame(name, parent, template) end
    _G.hooksecurefunc = function(target, name, fn)
        -- The live client accepts ("GlobalName", hook) for a global function and
        -- (table, "method", hook) for a table method. The two-argument string
        -- form passes the hook as `name`, not as `fn`.
        if type(target) == "string" then
            local key, original, hook = target, _G[target], name
            _G[key] = function(...)
                local results = { pcall(original, ...) }
                if hook then hook(...) end
                if not results[1] then error(results[2], 2) end
                return unpack(results, 2)
            end
            return
        end
        local original = target[name]
        target[name] = function(...)
            local results = { pcall(original, ...) }
            fn(...)
            if not results[1] then error(results[2], 2) end
            return unpack(results, 2)
        end
    end
    _G.UIParent = H.NewFrame("UIParent")
    UIParent.width, UIParent.height = 1920, 1080
    -- The client's own experience/reputation bar. It starts shown like a fresh
    -- login so the replacement's takeover and release can be observed.
    _G.MainStatusTrackingBarContainer = H.NewFrame("MainStatusTrackingBarContainer", UIParent)
    MainStatusTrackingBarContainer:Show()
    _G.MinimapCluster = H.NewFrame("MinimapCluster", UIParent)
    _G.Minimap = H.NewFrame("Minimap", MinimapCluster)
    Minimap.width, Minimap.height = 198, 198
    _G.MinimapCompassTexture = H.NewFrame(nil, MinimapCluster)
    _G.MinimapZoneText = H.NewFrame(nil, MinimapCluster)
    MinimapZoneText.textColor = { 1, 0.82, 0 }
    MinimapCluster.BorderTop = H.NewFrame(nil, MinimapCluster)
    local borderRegions = { H.NewFrame(nil, MinimapCluster.BorderTop), H.NewFrame(nil, MinimapCluster.BorderTop) }
    MinimapCluster.BorderTop.GetRegions = function() return borderRegions[1], borderRegions[2] end
    MinimapCluster.MinimapContainer = { PlayerCoords = H.NewFrame(nil, MinimapCluster) }
    -- A new session starts without the bars a previous test created. Leaving
    -- those globals behind made the shared central geometry read another test's
    -- bar sizes instead of this scene's.
    _G.MultiBarBottomLeft, _G.MultiBarBottomRight = nil, nil
    _G.MultiBarRight, _G.MultiBarLeft = nil, nil
    _G.MultiBar5, _G.MultiBar6, _G.MultiBar7 = nil, nil
    _G.PetActionBar, _G.StanceBar = nil, nil
    _G.MainActionBar = H.NewFrame("MainActionBar", UIParent)
    -- A real main bar spans twelve buttons; the shared central geometry reads
    -- this size, so the fixture gives it the same measured shape.
    MainActionBar.width, MainActionBar.height = 524, 40
    MainActionBar.actionButtons = {}
    -- The client's Cooldown Manager viewers exist on the supported builds; the
    -- placement component only moves them. The 300-wide block matches the
    -- mockup's visible icon stack, which now also sets the unit-frame boundary.
    for _, name in ipairs({ "EssentialCooldownViewer", "UtilityCooldownViewer",
        "BuffIconCooldownViewer", "BuffBarCooldownViewer" }) do
        local viewer = H.NewFrame(name, UIParent)
        viewer:SetWidth(300)
    end
    MainActionBar.BorderArt = H.NewFrame("MainActionBarBorderArt", MainActionBar)
    local endCaps = H.NewFrame("MainActionBarEndCaps", MainActionBar)
    endCaps.LeftEndCap = H.NewFrame("MainActionBarLeftEndCap", endCaps)
    endCaps.RightEndCap = H.NewFrame("MainActionBarRightEndCap", endCaps)
    MainActionBar.EndCaps = endCaps
    local actionButton = H.NewFrame("ActionButton1", MainActionBar)
    actionButton.icon = H.NewFrame(nil, actionButton)
    actionButton.NormalTexture = H.NewFrame(nil, actionButton)
    actionButton.SlotBackground = H.NewFrame(nil, actionButton)
    actionButton.SlotArt = H.NewFrame(nil, actionButton)
    actionButton.TextOverlayContainer = H.NewFrame(nil, actionButton)
    actionButton.HotKey = H.NewFrame(nil, actionButton.TextOverlayContainer)
    actionButton.Count = H.NewFrame(nil, actionButton.TextOverlayContainer)
    actionButton.TextOverlayContainer.HotKey = actionButton.HotKey
    actionButton.TextOverlayContainer.Count = actionButton.Count
    MainActionBar.actionButtons[1] = actionButton
    _G.GameTooltip = H.NewFrame("GameTooltip", UIParent)
    GameTooltip.shown = false
    GameTooltip.NineSlice = H.NewFrame(nil, GameTooltip)
    GameTooltip.NineSlice.shown = true
    GameTooltip.ClearLines = function(self) self.lines = {} end
    _G.ItemRefTooltip = H.NewFrame("ItemRefTooltip", UIParent)
    ItemRefTooltip.shown = false
    ItemRefTooltip.NineSlice = H.NewFrame(nil, ItemRefTooltip)
    _G.ShoppingTooltip1 = H.NewFrame("ShoppingTooltip1", UIParent)
    ShoppingTooltip1.shown = false
    ShoppingTooltip1.NineSlice = H.NewFrame(nil, ShoppingTooltip1)
    _G.ShoppingTooltip2 = H.NewFrame("ShoppingTooltip2", UIParent)
    ShoppingTooltip2.shown = false
    ShoppingTooltip2.NineSlice = H.NewFrame(nil, ShoppingTooltip2)
    -- ==== TRACK: VIS-19 TOOLTIP — append harness stubs inside H.Load above this line ====
    -- The client's own backdrop writer. It re-shows and re-lays the NineSlice on
    -- every hide and on every tooltip data style (azerite, corrupted), which is
    -- exactly what the adapter has to survive; the stub keeps the same side
    -- effects so a test can prove the native art does not come back.
    local tooltips = { GameTooltip, ItemRefTooltip, ShoppingTooltip1, ShoppingTooltip2 }
    for _, tooltip in ipairs(tooltips) do
        tooltip.GetObjectType = function() return "GameTooltip" end
    end
    H.tooltipStyleCalls = 0
    _G.SharedTooltip_SetBackdropStyle = function(tooltip, style, isEmbedded)
        H.tooltipStyleCalls = H.tooltipStyleCalls + 1
        tooltip.style = style
        if isEmbedded or tooltip.IsEmbedded then
            tooltip.NineSlice:Hide()
        else
            tooltip.NineSlice:Show()
        end
        tooltip.padding = style and style.padding or nil
    end
    -- ==== TRACK: VIS-19 TOOLTIP — append harness stubs above this line ====
    _G.NUM_CHAT_WINDOWS = 4
    _G.GENERAL_CHAT_DOCK = {}
    _G.FCFDock_GetSelectedWindow = function(dock) return H.selectedDockFrame or ChatFrame1 end
    -- The client's own unread state. FCF_StartAlertFlash/StopAlertFlash flip it.
    H.alertingTabs = {}
    _G.ChatFrameUtil = {
        IsTabAlerting = function(tab) return H.alertingTabs[tab] == true end,
        SetTabAlerting = function(tab, value) H.alertingTabs[tab] = value == true end,
    }
    _G.CHAT_FRAMES = {}
    -- The client's alert entry points; modules hook them to repaint the tab.
    _G.FCF_StartAlertFlash = function(frame)
        ChatFrameUtil.SetTabAlerting(_G[frame:GetName() .. "Tab"], true)
    end
    _G.FCF_StopAlertFlash = function(frame)
        ChatFrameUtil.SetTabAlerting(_G[frame:GetName() .. "Tab"], false)
    end
    -- The client re-shows its own selected-tab art and resets the tab alpha on
    -- every dock update; a repaint must follow those writes, not precede them.
    _G.FCFTab_UpdateColors = function(tab, selected)
        for _, key in ipairs({ "ActiveLeft", "ActiveMiddle", "ActiveRight" }) do
            if tab[key] then tab[key]:SetShown(selected == true); tab[key]:SetAlpha(1) end
        end
    end
    _G.FCFTab_UpdateAlpha = function(frame)
        local tab = _G[frame:GetName() .. "Tab"]
        if tab then tab:SetAlpha(0.4) end
    end
    for index = 1, 4 do
        local chat = H.NewFrame("ChatFrame" .. index, UIParent)
        chat.isDocked = true
        chat.spacing = 0
        chat.GetSpacing = function(self) return self.spacing end
        chat.SetSpacing = function(self, value) self.spacing = value end
        _G.CHAT_FRAMES[#CHAT_FRAMES + 1] = "ChatFrame" .. index
        local editBox = H.NewFrame("ChatFrame" .. index .. "EditBox", UIParent)
        editBox.shown = false
        -- Focus, not visibility, is what the client reports while typing.
        editBox.focused = false
        editBox.HasFocus = function(self) return self.focused == true end
        editBox.SetFocus = function(self)
            if self.focused then return end
            self.focused = true
            if self.scripts.OnEditFocusGained then self.scripts.OnEditFocusGained(self) end
        end
        chat.editBox = editBox
        local background = H.NewFrame("ChatFrame" .. index .. "Background", chat)
        chat.Background = background
        for _, suffix in ipairs({ "TopLeftTexture", "TopRightTexture", "BottomLeftTexture", "BottomRightTexture", "LeftTexture", "RightTexture", "TopTexture", "BottomTexture" }) do
            H.NewFrame("ChatFrame" .. index .. suffix, chat)
        end
        local tab = H.NewFrame("ChatFrame" .. index .. "Tab", chat)
        tab.alpha = 0.4
        tab.fontString = H.NewFrame(nil, tab)
        tab.fontString.textColor = { 1, 0.82, 0 }
        for _, key in ipairs({ "Left", "Right", "Middle", "ActiveLeft", "ActiveMiddle", "ActiveRight", "HighlightLeft", "HighlightMiddle", "HighlightRight" }) do
            tab[key] = H.NewFrame(nil, tab)
        end
        if index > 1 then chat.shown = false end
    end
    _G.ObjectiveTrackerFrame = H.NewFrame("ObjectiveTrackerFrame", UIParent)
    ObjectiveTrackerFrame.width, ObjectiveTrackerFrame.height = 250, 400
    ObjectiveTrackerFrame.Update = function() H.trackerUpdates = (H.trackerUpdates or 0) + 1 end
    -- The real container keeps a module list; individual modules can be
    -- removed and added back. LumaUI takes over only the quest modules and
    -- leaves scenario/dungeon/achievement modules with the client.
    ObjectiveTrackerFrame.modules = {}
    function ObjectiveTrackerFrame:HasModule(module)
        for _, item in ipairs(self.modules) do if item == module then return true end end
        return false
    end
    function ObjectiveTrackerFrame:AddModule(module)
        if not self:HasModule(module) then self.modules[#self.modules + 1] = module end
    end
    function ObjectiveTrackerFrame:RemoveModule(module)
        for index = #self.modules, 1, -1 do
            if self.modules[index] == module then table.remove(self.modules, index) end
        end
    end
    _G.QuestObjectiveTracker = H.NewFrame("QuestObjectiveTracker", ObjectiveTrackerFrame)
    QuestObjectiveTracker.protected = true
    QuestObjectiveTracker.usedBlocks = {}
    local function questBlock(id)
        local block = H.NewFrame(nil, QuestObjectiveTracker)
        block.id = id
        block.isHighlighted = false
        block.HeaderText = H.NewFrame(nil, block)
        block.HeaderText.textColor = { 1, 0.82, 0, 1 }
        block.UpdateHighlight = function(current)
            if current.isHighlighted then
                current.HeaderText:SetTextColor(1, 1, 1, 1)
            else
                current.HeaderText:SetTextColor(1, 0.82, 0, 1)
            end
        end
        return block
    end
    QuestObjectiveTracker.usedBlocks[1] = { [101] = questBlock(101), [102] = questBlock(102) }
    -- Campaign quests are a separate module; exercise its enumeration fallback.
    _G.CampaignQuestObjectiveTracker = H.NewFrame("CampaignQuestObjectiveTracker", ObjectiveTrackerFrame)
    CampaignQuestObjectiveTracker.protected = true
    local campaignBlock = questBlock(104)
    H.campaignBlock = campaignBlock
    CampaignQuestObjectiveTracker.EnumerateActiveBlocks = function(_, callback) callback(campaignBlock) end
    -- World quests are their own module in the live client; LumaUI replaces it
    -- together with the regular quest module.
    _G.WorldQuestObjectiveTracker = H.NewFrame("WorldQuestObjectiveTracker", ObjectiveTrackerFrame)
    WorldQuestObjectiveTracker.protected = true
    WorldQuestObjectiveTracker.usedBlocks = {}
    -- A module the quest panel does not cover: it must stay registered and
    -- visible while the quest modules are replaced.
    _G.ScenarioObjectiveTracker = H.NewFrame("ScenarioObjectiveTracker", ObjectiveTrackerFrame)
    ScenarioObjectiveTracker.protected = true
    ObjectiveTrackerFrame.modules[1] = QuestObjectiveTracker
    ObjectiveTrackerFrame.modules[2] = CampaignQuestObjectiveTracker
    ObjectiveTrackerFrame.modules[3] = WorldQuestObjectiveTracker
    ObjectiveTrackerFrame.modules[4] = ScenarioObjectiveTracker
    _G.EditModeManagerFrame = H.NewFrame("EditModeManagerFrame", UIParent)
    EditModeManagerFrame:Hide()
    _G.ShowUIPanel = function(frame) H.shownPanel = frame end
    _G.DEFAULT_CHAT_FRAME = { AddMessage = function(_, text) H.messages[#H.messages + 1] = text end }
    _G.GameFontNormal = H.NewFrame("GameFontNormal")
    _G.C_AddOns = { GetAddOnMetadata = function() return "0.4.0" end }
    -- The coexistence probe enumerates the session's addons through the same
    -- H.addons list that H.Load resets (a test replaces the list to stage a
    -- session with other addons installed or loaded).
    _G.C_AddOns.GetNumAddOns = function() return #H.addons end
    _G.C_AddOns.GetAddOnInfo = function(index)
        local entry = H.addons[index]
        if not entry then return nil end
        return entry.name, entry.title, entry.notes or "", entry.loadable and true or false,
            entry.reason or "", entry.security or "INSECURE"
    end
    _G.C_AddOns.IsAddOnLoaded = function(name)
        for _, entry in ipairs(H.addons) do
            if entry.name == name then return entry.loaded == true, entry.loaded == true end
        end
        return false, false
    end
    _G.C_Timer = {
        NewTicker = function(interval, callback)
            local timer = { interval = interval, callback = callback, Cancel = function(self) self.cancelled = true end }
            H.timers[#H.timers + 1] = timer
            return timer
        end,
        -- A one-shot: H.Advance fires it exactly once when its delay elapses,
        -- and Cancel stops it like a ticker's.
        After = function(delay, callback)
            local timer = { interval = delay, callback = callback, after = true,
                Cancel = function(self) self.cancelled = true end }
            H.timers[#H.timers + 1] = timer
            return timer
        end,
    }
    _G.GetLocale = function() return H.locale or "zhCN" end
    _G.GetBuildInfo = function() return "12.1.5", "12345", "", 120105 end
    _G.InCombatLockdown = function() return H.combat end
    _G.IsLoggedIn = function() return false end
    _G.issecretvalue = function(value) return secretValues[value] ~= nil end
    _G.UnitFullName = function() return "Tester", "Realm" end
    _G.GetRealmName = function() return "Realm" end
    _G.GetRealZoneText = function() return "Test Zone" end
    _G.GetGameTime = function() return 12, 34 end
    _G.GetNetStats = function() return 0, 0, 30, 40 end
    _G.GetFramerate = function() return 120 end
    _G.GetMoney = function() return H.money or 123456 end
    _G.GetMoneyString = function(amount) return (amount or 0) .. "c" end
    _G.RequestRaidInfo = function() H.raidRequested = true end
    _G.GetNumSavedInstances = function() return #(H.savedInstances or {}) end
    _G.GetSavedInstanceInfo = function(index)
        local entry = (H.savedInstances or {})[index]
        if not entry then return nil end
        return entry.name, entry.id, entry.reset, entry.difficulty, entry.locked, entry.extended,
            entry.id, entry.isRaid, entry.maxPlayers, entry.difficultyName
    end
    _G.GetNumSavedWorldBosses = function() return #(H.savedWorldBosses or {}) end
    _G.GetSavedWorldBossInfo = function(index)
        local entry = (H.savedWorldBosses or {})[index]
        if not entry then return nil end
        return entry.name, entry.id, entry.reset
    end
    _G.SecondsToTime = function(seconds)
        seconds = tonumber(seconds) or 0
        local days = math.floor(seconds / 86400)
        if days > 0 then return days .. (days == 1 and " day" or " days") end
        local hours = math.floor(seconds / 3600)
        if hours > 0 then return hours .. (hours == 1 and " hour" or " hours") end
        local minutes = math.max(1, math.floor(seconds / 60))
        return minutes .. (minutes == 1 and " min" or " mins")
    end
    _G.GetSubZoneText = function() return H.subZone or "Test Subzone" end
    _G.C_Bank = {
        -- H.bankView (table keyed by BankType) is the precise control; the older
        -- H.bankType scalar keeps its meaning (only that type is viewable).
        CanViewBank = function(kind)
            if type(H.bankView) == "table" then return H.bankView[kind] == true end
            if H.bankType ~= nil then return kind == H.bankType end
            return kind == Enum.BankType.Character or kind == Enum.BankType.Account
        end,
        CanUseBank = function(kind)
            local usable = H.bankUsable
            if usable == nil then return true end
            if type(usable) == "table" then return usable[kind] == true end
            return usable == true
        end,
        FetchDepositedMoney = function() return H.warbandMoney or 0 end,
        -- Purchased tab container ids per bank type. nil for a type means the
        -- client has no tab list for it (no tabs purchased / no account bank).
        FetchPurchasedBankTabIDs = function(kind)
            if H.bankTabs == false then return H.bankTabs end
            local tabs = (type(H.bankTabs) == "table" and H.bankTabs[kind]) or {}
            local copy = {}
            for _, id in ipairs(tabs) do copy[#copy + 1] = id end
            return copy
        end,
    }
    _G.Enum = _G.Enum or {}
    _G.Enum.BankType = _G.Enum.BankType or { Character = 1, Account = 2 }
    _G.UnitXP = function() return 30 end
    _G.UnitXPMax = function() return 100 end
    _G.GetXPExhaustion = function() return 25 end
    _G.IsXPUserDisabled = function() return false end
    _G.UnitExists = function() return true end
    _G.UnitName = function() return H.Secret("Unit") end
    _G.UnitHealth = function() return H.Secret(42) end
    _G.UnitHealthMax = function() return H.Secret(100) end
    _G.UnitHealthPercent = function() return H.Secret(42) end
    _G.UnitPower = function() return H.Secret(10) end
    _G.UnitPowerMax = function() return H.Secret(100) end
    _G.RegisterUnitWatch = function(frame) restricted(frame); frame.watched = true; frame:Show() end
    _G.UnregisterUnitWatch = function(frame) restricted(frame); frame.watched = false end
    _G.ChatEdit_InsertLink = function(link) H.inserted = link; return true end
    _G.ChatFrame_OpenChat = function(link) H.inserted = link end
    _G.IsModifiedClick = function(which)
        if which then return H.modifiedClicks[which] == true end
        return next(H.modifiedClicks) ~= nil
    end
    _G.IsShiftKeyDown = function() return H.shiftDown == true end
    _G.C_SuperTrack = {
        GetSuperTrackedQuestID = function() return H.superTracked or 0 end,
        SetSuperTrackedQuestID = function(questID) H.superTracked = (questID and questID ~= 0) and questID or nil end,
    }
    _G.ITEM_QUALITY_COLORS = {
        [0] = { r = 0.62, g = 0.62, b = 0.62 }, [2] = { r = 0.2, g = 0.8, b = 0.2 },
        [3] = { r = 0.0, g = 0.44, b = 0.87 }, [4] = { r = 0.64, g = 0.21, b = 0.93 },
    }
    -- Private aura anchors (C_UnitAuras.AddPrivateAuraAnchor /
    -- RemovePrivateAuraAnchor). The harness records every call so tests can
    -- assert create/remove counts and reuse, and mirrors the documented
    -- contract: the call returns a nilable anchor id, and removing an unknown
    -- id is an error (the real client rejects it, addons must guard).
    H.privateAnchors = { nextID = 0, live = {}, liveCount = 0, added = 0, removed = 0, refused = 0,
        args = {}, removedIDs = {} }
    _G.C_UnitAuras = {
        AddPrivateAuraAnchor = function(args)
            if H.privateAnchorRefuse then H.privateAnchors.refused = H.privateAnchors.refused + 1; return nil end
            H.privateAnchors.nextID = H.privateAnchors.nextID + 1
            local id = H.privateAnchors.nextID
            H.privateAnchors.live[id] = args
            H.privateAnchors.liveCount = H.privateAnchors.liveCount + 1
            H.privateAnchors.added = H.privateAnchors.added + 1
            H.privateAnchors.args[#H.privateAnchors.args + 1] = args
            return id
        end,
        RemovePrivateAuraAnchor = function(id)
            if not H.privateAnchors.live[id] then error("unknown private aura anchor " .. tostring(id), 2) end
            H.privateAnchors.live[id] = nil
            H.privateAnchors.liveCount = H.privateAnchors.liveCount - 1
            H.privateAnchors.removed = H.privateAnchors.removed + 1
            H.privateAnchors.removedIDs[#H.privateAnchors.removedIDs + 1] = id
        end,
    }
    _G.NUM_TOTAL_EQUIPPED_BAG_SLOTS = 5
    _G.C_Container = {
        GetContainerNumSlots = function() return 2 end,
        GetContainerNumFreeSlots = function() return 1 end,
        GetContainerItemInfo = function(bag, slot)
            if slot == 2 then return nil end
            return { hyperlink = "|Hitem:123|h[Test item " .. bag .. "]|h", itemName = "Test item " .. bag,
                itemID = 123, stackCount = 2, iconFileID = 134400, quality = 2, isLocked = false }
        end,
        UseContainerItem = function(bag, slot) H.calls.use = { bag = bag, slot = slot }; H.calls.useCount = (H.calls.useCount or 0) + 1 end,
        PickupContainerItem = function(bag, slot) H.calls.pickup = { bag = bag, slot = slot }; H.calls.pickupCount = (H.calls.pickupCount or 0) + 1 end,
        SplitContainerItem = function(bag, slot, amount) H.calls.split = { bag = bag, slot = slot, amount = amount } end,
        SortBags = function() H.calls.sort = true end,
    }
    _G.C_Item = {
        GetItemInfo = function(link)
            if link == "|Hitem:999|h[Quality item]|h" then return "Quality item", link, 3 end
            return "Test item", link, 2
        end,
        GetItemQualityColor = function(quality)
            local color = ITEM_QUALITY_COLORS[quality]
            if not color then return 1, 1, 1, "" end
            return color.r, color.g, color.b, ""
        end,
    }
    _G.C_Map = {
        GetBestMapForUnit = function() return 1 end,
        GetPlayerMapPosition = function() return { GetXY = function() return 0.5, 0.25 end } end,
    }
    H.questLevels = { [101] = 5, [102] = 80, [104] = 15 }
    H.questLog = {
        entries = {
            { title = "Campaign", isHeader = true },
            { title = "First quest", questID = 101, level = 5 },
            { title = "Second quest", questID = 102, level = 80 },
        },
        objectives = {
            [101] = { { text = "Slay 8 boars" }, { text = "Return to town" } },
            [102] = { { text = "Talk to the scout" } },
        },
        watch = { [101] = 1 },
        ready = {},
        failed = {},
        map = {},
    }
    _G.GetQuestDifficultyColor = function(level)
        if type(level) ~= "number" then return nil end
        if level <= 10 then return { r = 0.5, g = 0.5, b = 0.5 } end
        if level <= 20 then return { r = 0, g = 1, b = 0 } end
        return { r = 1, g = 0.82, b = 0 }
    end
    _G.C_QuestLog = {
        GetNumQuestLogEntries = function() return #H.questLog.entries, 2 end,
        GetInfo = function(index) return H.questLog.entries[index] end,
        GetQuestObjectives = function(questID) return H.questLog.objectives[questID] end,
        GetQuestWatchType = function(questID) return H.questLog.watch[questID] end,
        GetQuestDifficultyLevel = function(questID) return H.questLevels[questID] end,
        GetNumQuestWatches = function()
            local count = 0
            for _ in pairs(H.questLog.watch) do count = count + 1 end
            return count
        end,
        GetQuestIDForQuestWatchIndex = function(index)
            local ids = {}
            for questID in pairs(H.questLog.watch) do ids[#ids + 1] = questID end
            table.sort(ids)
            return ids[index]
        end,
        AddQuestWatch = function(questID) H.questLog.watch[questID] = H.questLog.watch[questID] or 1; return true end,
        RemoveQuestWatch = function(questID)
            local had = H.questLog.watch[questID] ~= nil
            H.questLog.watch[questID] = nil
            return had
        end,
        IsComplete = function(questID) return H.questLog.ready[questID] == true end,
        ReadyForTurnIn = function(questID) return H.questLog.ready[questID] == true end,
        IsFailed = function(questID) return H.questLog.failed[questID] == true end,
        GetTitleForQuestID = function(questID)
            for _, entry in ipairs(H.questLog.entries) do
                if entry.questID == questID then return entry.title end
            end
            return nil
        end,
        GetQuestsOnMap = function() return H.questLog.map end,
    }
    _G.Settings = {
        RegisterCanvasLayoutCategory = function() return { ID = 1 } end,
        RegisterAddOnCategory = noop,
    }
    -- Party quest sync stubs: session state is driven by the tests.
    H.questSession = { exists = false, state = 0 }
    H.menu = nil
    _G.Enum.QuestSessionEnterState = { None = 0, Entered = 1 }
    _G.C_QuestSession = {
        Exists = function() return H.questSession.exists end,
        GetSessionEnterState = function() return H.questSession.state end,
        RequestSessionEnter = function() H.calls.sessionEnter = (H.calls.sessionEnter or 0) + 1 end,
        RequestSessionLeave = function() H.calls.sessionLeave = (H.calls.sessionLeave or 0) + 1 end,
    }
    -- Quest log special item stubs for the tracker item buttons.
    H.questLog.itemIndex = {}
    H.questLog.items = {}
    C_QuestLog.GetLogIndexForQuestID = function(questID) return H.questLog.itemIndex[questID] end
    _G.GetQuestLogSpecialItemInfo = function(index)
        local info = H.questLog.items[index]
        if not info then return nil end
        return info.link, info.charges or 0
    end
    -- Instant item info keeps the documented tuple shape (itemID, itemType,
    -- itemSubType, itemEquipLoc, icon, classID, subclassID): the icon is the
    -- FIFTH value. A stub that copied the older eleven-value GetItemInfo shape
    -- is what let a wrong return position pass in the old suite.
    _G.GetItemInfoInstant = function(link)
        local id = tonumber(tostring(link):match("item:(%d+)")) or 0
        local class = 13
        if H.itemClasses and H.itemClasses[id] then class = H.itemClasses[id] end
        return id, "Misc", "Misc", "", 134400, class, 0
    end
    -- Menu stub: records the generated entries for assertions.
    _G.MenuUtil = { CreateContextMenu = function(owner, generator)
        H.menu = { owner = owner, entries = {} }
        local root = {}
        function root:CreateTitle(text) H.menu.entries[#H.menu.entries + 1] = { kind = "title", text = text } end
        function root:CreateButton(text, fn) H.menu.entries[#H.menu.entries + 1] = { kind = "button", text = text, fn = fn } end
        function root:CreateDivider() H.menu.entries[#H.menu.entries + 1] = { kind = "divider" } end
        generator(owner, root)
        return root
    end }
    _G.QuestMapFrame_OpenToQuest = function(questID) H.calls.openQuest = questID end
    _G.QuestMapFrame_AbandonQuest = function() H.calls.abandon = (H.calls.abandon or 0) + 1 end
    C_QuestLog.SetSelectedQuest = function(questID) H.calls.selectedQuest = questID end
    -- ==== TRACK: QUEST PANEL — append harness stubs inside H.Load above this line ====
    -- Unit frame part stubs: cast state (times in ms), aura data, raid marks
    -- and hover tooltips. GetTime is driven by H.now.
    H.cast, H.now = {}, 0
    _G.GetTime = function() return H.now end
    _G.UnitCastingInfo = function(unit)
        local info = H.cast[unit]
        if not info or info.channel or info.gone then return nil end
        return info.name, info.text or info.name, info.texture, info.startTime, info.endTime, false, "cast-1", info.notInterruptible, 15125
    end
    _G.UnitChannelInfo = function(unit)
        local info = H.cast[unit]
        if not info or not info.channel then return nil end
        -- Documented order: ..., notInterruptible(7), spellID(8), isEmpowered(9),
        -- numEmpowerStages(10), castBarID(11).
        return info.name, info.text or info.name, info.texture, info.startTime, info.endTime, false,
            info.notInterruptible, 15125, info.isEmpowered == true, 3, nil
    end
    H.unitState = { dead = {}, offline = {} }
    H.roles = {}
    H.empowerSpells = {}
    _G.UnitGroupRolesAssigned = function(unit) return H.roles[unit] or "NONE" end
    _G.UnitIsDead = function(unit) return H.unitState.dead[unit] == true end
    _G.UnitIsDeadOrGhost = function(unit) return H.unitState.dead[unit] == true end
    _G.UnitIsConnected = function(unit) return H.unitState.offline[unit] ~= true end
    _G.C_Spell = _G.C_Spell or {}
    _G.C_Spell.IsPressHoldReleaseSpell = function(id) return H.empowerSpells[id] == true end
    H.unitAuras, H.raidTargets, H.tooltipUnit = {}, {}, nil
    -- Gradient bar stubs: the fill texture behind a status bar, SetGradient
    -- recording, and the unit identity APIs the pair lookup probes. A plain
    -- color set after a gradient clears it, like the real fill texture.
    _G.CreateColor = function(r, g, b, a) return { r = r, g = g, b = b, a = a or 1 } end
    function Frame:GetStatusBarTexture()
        if not self.statusFill then self.statusFill = H.NewFrame(nil, self) end
        return self.statusFill
    end
    function Frame:SetGradient(orientation, lo, hi)
        self.gradient = { orientation = orientation, lo = { lo.r, lo.g, lo.b }, hi = { hi.r, hi.g, hi.b } }
    end
    local setBarColor = Frame.SetStatusBarColor
    Frame.SetStatusBarColor = function(self, ...)
        if self.statusFill then self.statusFill.gradient = nil end
        return setBarColor(self, ...)
    end
    H.unitInfo = {
        player = { isPlayer = true, class = "MONK" },
        pet = { reaction = 5 },
        target = { reaction = 3 },
        focus = { reaction = 2 },
    }
    _G.UnitIsPlayer = function(unit)
        local info = H.unitInfo[unit]
        if not info then return false end
        return info.isPlayer == true
    end
    _G.UnitClass = function(unit)
        local info = H.unitInfo[unit]
        if info and info.class then return "Class", info.class, 1 end
        return nil
    end
    _G.UnitIsTapDenied = function(unit)
        local info = H.unitInfo[unit]
        return info ~= nil and info.tapped == true
    end
    _G.UnitReaction = function(unit)
        local info = H.unitInfo[unit]
        if info and info.reaction then return info.reaction end
        return nil
    end
    H.powerTokens = { MANA = 0, RAGE = 1, FOCUS = 2, ENERGY = 3 }
    _G.UnitPowerType = function(unit)
        local info = H.unitInfo[unit]
        local key = info and info.power or "MANA"
        return H.powerTokens[key], key
    end
    _G.RAID_CLASS_COLORS = {
        MONK = { r = 0, g = 1, b = 0.59 },
        WARRIOR = { r = 0.78, g = 0.61, b = 0.43 },
    }
    _G.PowerBarColor = {
        MANA = { r = 0, g = 0.45, b = 0.85 },
        RAGE = { r = 1, g = 0, b = 0 },
        FOCUS = { r = 1, g = 0.5, b = 0.25 },
        ENERGY = { r = 1, g = 0.95, b = 0.15 },
    }
    -- The Blizzard frames the preview replaces: secure like the real client,
    -- so their visibility is protected during combat. Target and focus start
    -- unshown, the player, pet and cast bars start shown.
    _G.PlayerFrame = H.NewFrame("PlayerFrame", UIParent, "SecureUnitButtonTemplate")
    _G.TargetFrame = H.NewFrame("TargetFrame", UIParent, "SecureUnitButtonTemplate")
    TargetFrame.shown = false
    _G.FocusFrame = H.NewFrame("FocusFrame", UIParent, "SecureUnitButtonTemplate")
    FocusFrame.shown = false
    _G.PetFrame = H.NewFrame("PetFrame", UIParent, "SecureUnitButtonTemplate")
    _G.PlayerCastingBarFrame = H.NewFrame("PlayerCastingBarFrame", UIParent, "SecureUnitButtonTemplate")
    _G.PetCastingBarFrame = H.NewFrame("PetCastingBarFrame", UIParent, "SecureUnitButtonTemplate")
    C_UnitAuras.GetAuraDataByIndex = function(unit, index, filter)
        local set = H.unitAuras and H.unitAuras[unit]
        if not set then return nil end
        local list = (filter == "HARMFUL") and set.harmful or set.helpful
        local item = list and list[index]
        if not item then return nil end
        return { icon = item.icon, name = item.name, applications = item.applications,
            duration = item.duration, expirationTime = item.expirationTime, dispelName = item.dispelName }
    end
    _G.GetRaidTargetIndex = function(unit) return H.raidTargets[unit] end
    GameTooltip.SetUnit = function(self, unit) H.tooltipUnit = unit end
    -- ==== TRACK: UNIT FRAMES — append harness stubs inside H.Load above this line ====
    -- World quest info keeps the documented four-value shape (title, factionID,
    -- capped, displayAsObjective). The remaining time comes from its own
    -- namespace: H.taskInfo holds seconds, H.taskMinutes holds the fallback
    -- minutes call. Time text therefore has to be read from the dedicated API.
    H.taskInfo, H.taskMinutes = {}, {}
    _G.C_TaskQuest = {
        GetQuestInfoByQuestID = function(questID)
            if H.taskInfo[questID] == nil and H.taskMinutes[questID] == nil then return nil end
            return "任务名", 108, false, true
        end,
        GetQuestTimeLeftSeconds = function(questID) return H.taskInfo[questID] end,
        GetQuestTimeLeftMinutes = function(questID) return H.taskMinutes[questID] end,
    }
    -- ==== TRACK-P2: QUEST POLISH — append harness stubs inside H.Load above this line ====
    -- Unit group track stubs: the localized number formatter the value texts
    -- use, and the 12.x centralized party frame (secure, starts shown). The
    -- secure group header machinery itself is not simulated — the component's
    -- exposed entry points (header attributes + drawChild) are driven directly
    -- by the tests, with pseudo children added to the header's children list.
    _G.AbbreviateLargeNumbers = function(value) if value >= 10000 then return string.format("%.0f万", value / 10000) end return tostring(value) end
    _G.PartyFrame = H.NewFrame("PartyFrame", UIParent, "SecureUnitButtonTemplate")
    -- ==== TRACK-P2: UNIT GROUPS — append harness stubs inside H.Load above this line ====
    -- Bag track stubs: item class ids per item id, a control-key flag and bank
    -- containers driven by H.bankSlots[bag] (any bag id, including the legacy
    -- BANK_CONTAINER). GetItemInfoInstant is wrapped around the quest stub above
    -- instead of replacing it: the wrapped original keeps every return, and only
    -- the class slot (sixth value) is overridden when the link carries a
    -- parseable item id.
    H.itemClasses, H.bankSlots, H.ctrlDown = {}, {}, false
    _G.BANK_CONTAINER = -1
    _G.IsControlKeyDown = function() return H.ctrlDown == true end
    local containerSlots = C_Container.GetContainerNumSlots
    C_Container.GetContainerNumSlots = function(bag)
        local bank = H.bankSlots[bag]
        if bank then return #bank end
        if bag == BANK_CONTAINER then return 0 end
        return containerSlots(bag)
    end
    local containerInfo = C_Container.GetContainerItemInfo
    C_Container.GetContainerItemInfo = function(bag, slot)
        local bank = H.bankSlots[bag]
        if bank or bag == BANK_CONTAINER then
            local entry = (bank or {})[slot]
            if not entry then return nil end
            return { hyperlink = entry.link or (entry.itemID and "|Hitem:" .. entry.itemID .. "|h[Bank item]|h"),
                itemName = entry.name or "Bank item", itemID = entry.itemID, stackCount = entry.stack or 1,
                iconFileID = entry.icon or 134400, quality = entry.quality or 2,
                isLocked = entry.isLocked == true, hasNoValue = entry.hasNoValue == true }
        end
        return containerInfo(bag, slot)
    end
    -- The bag track drives the item class id per item id. Both namespaces expose
    -- the same documented instant-info tuple, so the class slot (sixth) follows
    -- H.itemClasses and the icon stays the fifth value.
    if type(C_Item) == "table" then C_Item.GetItemInfoInstant = _G.GetItemInfoInstant end
    -- ==== TRACK-P2: BAGS — append harness stubs inside H.Load above this line ====
    -- Character window stub for the system window adapters: three texture
    -- regions, one title FontString region and the NineSlice art container.
    -- H.NewFrame objects have no region type concept, so every region is
    -- tagged with kind (and isFontString) for the adapter to branch on.
    -- CharacterFrame has no Secure template, so texture Show/Hide stays
    -- unprotected in combat, like the real window. Texture 2 starts hidden
    -- natively, so restore has to return it to its own hidden state.
    _G.CharacterFrame = H.NewFrame("CharacterFrame", UIParent)
    local regions = {}
    for index = 1, 3 do
        local region = H.NewFrame(nil, CharacterFrame)
        region.kind = "texture"
        region.isFontString = false
        regions[index] = region
    end
    regions[2].shown = false
    regions[4] = H.NewFrame(nil, CharacterFrame)
    regions[4].kind = "fontstring"
    regions[4].isFontString = true
    CharacterFrame.GetRegions = function() return regions[1], regions[2], regions[3], regions[4] end
    CharacterFrame.NineSlice = H.NewFrame(nil, CharacterFrame)
    H.characterRegions = regions
    H.slotQuality = nil
    -- Slots listed here report no item at all, which is how a Retail character
    -- looks in the ranged slot and how an empty inventory reads.
    H.emptySlots = { 18 }
    local function slotEmpty(slotID)
        for _, id in ipairs(H.emptySlots) do
            if id == slotID then return true end
        end
        return false
    end
    _G.GetInventoryItemQuality = function(unit, slotID)
        if slotEmpty(slotID) then return nil end
        return H.slotQuality
    end
    Frame.GetAtlas = function(self) return self.atlas end
    -- Character window sources: item buttons, the player model and the public
    -- stat getters the window reads.
    Frame.SetInventoryItem = function(self, unit, slotID) self.itemUnit, self.itemSlot = unit, slotID end
    Frame.SetUnit = function(self, unit) self.modelUnit = unit end
    Frame.SetRotation = function(self, angle) self.rotation = angle end
    _G.GetInventoryItemTexture = function(unit, slotID)
        if slotEmpty(slotID) then return nil end
        return 134400 + (slotID or 0)
    end
    _G.GetInventoryItemID = function(unit, slotID)
        if slotEmpty(slotID) then return nil end
        return 1000 + (slotID or 0)
    end
    _G.GetInventoryItemLink = function(unit, slotID)
        if slotEmpty(slotID) then return nil end
        return "|Hitem:" .. (2000 + (slotID or 0)) .. "|h[Slot " .. tostring(slotID) .. "]|h"
    end
    _G.GetItemInfo = function(link)
        local id = tonumber(link:match("item:(%d+)")) or 0
        return "Item", link, 2, 10, 0, "Armor", "Cloth", 1, "INVTYPE_HEAD", 134500 + id, 100
    end
    _G.PickupInventoryItem = function(slotID) H.calls.inventoryPickup = slotID end
    _G.UseInventoryItem = function(slotID) H.calls.inventoryUse = slotID end
    _G.GetAverageItemLevel = function() return 287, 300 end
    _G.UnitStat = function(unit, index) return 800 + index * 10 end
    _G.UnitArmor = function() return 2650 end
    _G.UnitLevel = function() return 80 end
    _G.GetSpecialization = function() return 1 end
    -- specID, name, description, icon, role, primaryStat (strength).
    _G.GetSpecializationInfo = function(index) return 269, "Windwalker", "Melee", 1267277, "DAMAGER", 1 end
    _G.GetCritChance = function() return 13.4 end
    _G.GetHaste = function() return 20.2 end
    _G.GetMasteryEffect = function() return 20.1 end
    _G.GetVersatilityBonus = function() return 7.6 end
    _G.ToggleCharacter = function()
        CharacterFrame:SetShown(not CharacterFrame:IsShown())
    end
    -- Optional system window adapters.
    _G.MailFrame = H.NewFrame("MailFrame", UIParent)
    _G.MailFrame.NineSlice = H.NewFrame(nil, MailFrame)
    local mailArt = H.NewFrame(nil, MailFrame)
    mailArt.kind = "texture"
    MailFrame.GetRegions = function() return mailArt end
    H.mailArt = mailArt
    -- Equipment sets: the documented GetEquipmentSetIDs + nine-value
    -- GetEquipmentSetInfo shape, plus the real swap call and its lock query.
    -- The first set is equipped; the second is not and reports 3/4 items.
    H.equipmentSets = {
        { id = 11, name = "Raid", icon = 134400, equipped = true, items = 16, equippedItems = 16,
            inInventory = 16, lost = 0, ignored = 0, locked = false },
        { id = 22, name = "Mythic", icon = 134401, equipped = false, items = 4, equippedItems = 3,
            inInventory = 3, lost = 1, ignored = 0, locked = false },
    }
    H.equipmentSetUsed = nil
    local function equipmentSetByID(id)
        for _, set in ipairs(H.equipmentSets) do
            if set.id == id then return set end
        end
        return nil
    end
    _G.C_EquipmentSet = {
        GetNumEquipmentSets = function() return #H.equipmentSets end,
        GetEquipmentSetIDs = function()
            local ids = {}
            for index, set in ipairs(H.equipmentSets) do ids[index] = set.id end
            return ids
        end,
        GetEquipmentSetInfo = function(id)
            local set = equipmentSetByID(id)
            if not set then return nil end
            return set.name, set.icon, set.id, set.equipped, set.items, set.equippedItems,
                set.inInventory, set.lost, set.ignored
        end,
        UseEquipmentSet = function(id)
            H.equipmentSetUsed = id
            return false
        end,
        EquipmentSetContainsLockedItems = function(id)
            local set = equipmentSetByID(id)
            return set ~= nil and set.locked == true
        end,
    }
    _G.CR_CRIT_MELEE, _G.CR_HASTE_MELEE = 9, 18
    _G.CR_MASTERY, _G.CR_VERSATILITY_DAMAGE_DONE = 26, 29
    _G.GetCombatRating = function(kind) return 420 end
    _G.GetCombatRatingBonus = function(kind) return 12.5 end
    _G.IsControlKeyDown = function() return H.ctrlDown == true end
    -- Reputation and currency pages.
    H.factions = {
        { name = "Argent Dawn", standing = 5 },
        { name = "Ravenholdt", standing = 3 },
    }
    _G._FACTION_STANDING_LABEL = { [5] = "Friendly", [3] = "Neutral" }
    _G.FACTION_STANDING_LABEL5 = "Friendly"
    _G.FACTION_STANDING_LABEL3 = "Neutral"
    _G.GetNumFactions = function() return #H.factions end
    _G.GetFactionInfo = function(index)
        local faction = H.factions[index]
        if not faction then return nil end
        -- name, description, standingID, barMin, barMax, barValue, atWarWith,
        -- canToggleAtWar, isHeader, isCollapsed
        return faction.name, nil, faction.standing, 0, 21000, 4300, false, false, faction.header, false
    end
    H.currencies = {
        { name = "Valor", quantity = 1200, iconFileID = 134945, isHeader = false },
        { name = "Honor", quantity = 350, iconFileID = 132481, isHeader = false },
    }
    _G.C_CurrencyInfo = {
        GetCurrencyListSize = function() return #H.currencies end,
        GetCurrencyListInfo = function(index) return H.currencies[index] end,
    }
    -- Mail pane stubs for the dedicated mail adapter, shaped like the live
    -- client: an inbox pane with MailItem rows (each row frame carrying a
    -- check Button with its own icon), a page button, a send pane with an
    -- attachment slot and an input field, and a separate toplevel letter.
    _G.SendMailFrame = H.NewFrame("SendMailFrame", MailFrame)
    SendMailFrame.NineSlice = H.NewFrame(nil, SendMailFrame)
    local sendArt = H.NewFrame(nil, SendMailFrame)
    sendArt.kind = "texture"
    SendMailFrame.GetRegions = function() return sendArt end
    H.mailSendArt = sendArt
    local sendButton = H.NewFrame("SendMailMailButton", SendMailFrame)
    local sendLabel = H.NewFrame(nil, sendButton)
    sendLabel.kind = "fontstring"
    sendLabel.textColor = { 1, 0.82, 0, 1 }
    sendButton.GetRegions = function() return sendLabel end
    H.mailSendButton, H.mailSendLabel = sendButton, sendLabel
    -- A text field keeps its native box: the client draws focus and the caret.
    _G.SendMailSubjectEditBox = H.NewFrame("SendMailSubjectEditBox", SendMailFrame)
    local editBoxArt = H.NewFrame(nil, SendMailSubjectEditBox)
    editBoxArt.kind = "texture"
    SendMailSubjectEditBox.GetRegions = function() return editBoxArt end
    H.mailEditBoxArt = editBoxArt
    _G.SendMailAttachment1 = H.NewFrame("SendMailAttachment1", SendMailFrame)
    local attachmentIcon = H.NewFrame(nil, SendMailAttachment1)
    attachmentIcon.kind = "texture"
    SendMailAttachment1.Icon = attachmentIcon
    SendMailAttachment1.NormalTexture = H.NewFrame(nil, SendMailAttachment1)
    SendMailAttachment1.NormalTexture.kind = "texture"
    SendMailAttachment1.IconBorder = H.NewFrame(nil, SendMailAttachment1)
    SendMailAttachment1.IconBorder.kind = "texture"
    SendMailAttachment1.GetRegions = function() return attachmentIcon end
    H.mailAttachment = SendMailAttachment1
    _G.InboxFrame = H.NewFrame("InboxFrame", MailFrame)
    InboxFrame.NineSlice = H.NewFrame(nil, InboxFrame)
    local inboxArt = H.NewFrame(nil, InboxFrame)
    inboxArt.kind = "texture"
    InboxFrame.GetRegions = function() return inboxArt end
    H.mailInboxArt = inboxArt
    H.mailRows = {}
    for index = 1, 3 do
        local row = H.NewFrame("MailItem" .. index, InboxFrame)
        local rowArt = H.NewFrame(nil, row)
        rowArt.kind = "texture"
        -- The client's read/unread state lives on these labels; the skin must
        -- never recolor them.
        local sender = H.NewFrame(nil, row)
        sender.kind = "fontstring"
        sender.textColor = { 0.75, 0.75, 0.75, 1 }
        local subject = H.NewFrame(nil, row)
        subject.kind = "fontstring"
        subject.textColor = { 0.75, 0.75, 0.75, 1 }
        row.Sender, row.Subject = sender, subject
        row.GetRegions = function() return rowArt end
        -- The row's item: a check Button carrying the mail's first item icon.
        local check = H.NewFrame("MailItem" .. index .. "Button", row)
        row.Button = check
        check.Icon = H.NewFrame(nil, check)
        check.Icon.kind = "texture"
        check.IconBorder = H.NewFrame(nil, check)
        check.IconBorder.kind = "texture"
        check.GetRegions = function() return check.Icon end
        check.checked = false
        check.GetChecked = function(self) return self.checked end
        check.SetChecked = function(self, wanted) self.checked = wanted end
        H.mailRows[index] = row
    end
    -- The page arrow's art is the game's disabled state, so it is left native.
    _G.InboxPrevPageButton = H.NewFrame("InboxPrevPageButton", InboxFrame)
    local pageArt = H.NewFrame(nil, InboxPrevPageButton)
    pageArt.kind = "texture"
    InboxPrevPageButton.GetRegions = function() return pageArt end
    H.mailPageArt = pageArt
    _G.MailFrameTab1 = H.NewFrame("MailFrameTab1", MailFrame)
    MailFrameTab1.GetRegions = function() return H.mailTabArt end
    H.mailTabArt = H.NewFrame(nil, MailFrameTab1)
    H.mailTabArt.kind = "texture"
    -- The opened letter is its own toplevel window whose controls still belong
    -- to the mail adapter; it carries a stationery backdrop and a take button.
    _G.OpenMailFrame = H.NewFrame("OpenMailFrame", UIParent)
    local letterArt = H.NewFrame(nil, OpenMailFrame)
    letterArt.kind = "texture"
    OpenMailFrame.GetRegions = function() return letterArt end
    H.mailLetterArt = letterArt
    _G.OpenStationeryBackgroundLeft = H.NewFrame("OpenStationeryBackgroundLeft", OpenMailFrame)
    OpenStationeryBackgroundLeft.kind = "texture"
    H.letterStationery = OpenStationeryBackgroundLeft
    local letterButton = H.NewFrame("OpenMailTakeAttachmentsButton", OpenMailFrame)
    local letterLabel = H.NewFrame(nil, letterButton)
    letterLabel.kind = "fontstring"
    letterLabel.textColor = { 1, 0.82, 0, 1 }
    letterButton.GetRegions = function() return letterLabel end
    H.mailLetterButton, H.mailLetterLabel = letterButton, letterLabel
    _G.OpenMailAttachmentButton1 = H.NewFrame("OpenMailAttachmentButton1", OpenMailFrame)
    OpenMailAttachmentButton1.Icon = H.NewFrame(nil, OpenMailAttachmentButton1)
    OpenMailAttachmentButton1.Icon.kind = "texture"
    OpenMailAttachmentButton1.GetRegions = function() return OpenMailAttachmentButton1.Icon end
    H.mailLetterAttachment = OpenMailAttachmentButton1
    -- The client's inbox refresh; the skin hooks it to follow row state.
    _G.InboxFrame_Update = function() end
    -- Spellbook stubs: on 11.x the window is PlayerSpellsFrame (SpellBookFrame
    -- is absent), with a tab that keeps its label, a spell button that keeps its
    -- icon and a title strip whose art fades.
    _G.PlayerSpellsFrame = H.NewFrame("PlayerSpellsFrame", UIParent)
    PlayerSpellsFrame.NineSlice = H.NewFrame(nil, PlayerSpellsFrame)
    local spellFrameArt = H.NewFrame(nil, PlayerSpellsFrame)
    spellFrameArt.kind = "texture"
    PlayerSpellsFrame.GetRegions = function() return spellFrameArt end
    H.spellFrameArt = spellFrameArt
    PlayerSpellsFrame.Title = H.NewFrame(nil, PlayerSpellsFrame)
    local spellTitleArt = H.NewFrame(nil, PlayerSpellsFrame.Title)
    spellTitleArt.kind = "texture"
    PlayerSpellsFrame.Title.GetRegions = function() return spellTitleArt end
    H.spellTitleArt = spellTitleArt
    _G.SpellBookFrameTabButton1 = H.NewFrame("SpellBookFrameTabButton1", PlayerSpellsFrame)
    local spellTabArt = H.NewFrame(nil, SpellBookFrameTabButton1)
    spellTabArt.kind = "texture"
    local spellTabText = H.NewFrame(nil, SpellBookFrameTabButton1)
    spellTabText.kind = "fontstring"
    SpellBookFrameTabButton1.GetRegions = function() return spellTabArt, spellTabText end
    H.spellTabArt, H.spellTabText = spellTabArt, spellTabText
    _G.SpellButton1 = H.NewFrame("SpellButton1", PlayerSpellsFrame)
    SpellButton1.Icon = H.NewFrame(nil, SpellButton1)
    SpellButton1.Icon.kind = "texture"
    SpellButton1.NormalTexture = H.NewFrame(nil, SpellButton1)
    SpellButton1.NormalTexture.kind = "texture"
    SpellButton1.GetRegions = function() return SpellButton1.Icon end
    H.spellButton = SpellButton1
    -- The 11.x spellbook in its live shape: the window hosts a spellbook pane
    -- (CategoryTabSystem, SearchBox, SettingsDropdown, PagedSpellsFrame) next to
    -- hidden talent and specialisation pages. The paged grid hands out pooled
    -- rows through EnumerateFrames, so that is how the rows are created here.
    _G.PlayerSpellsFrame.SpellBookFrame = H.NewFrame(nil, PlayerSpellsFrame)
    local pane = PlayerSpellsFrame.SpellBookFrame
    H.spellPane = pane
    pane.TopBar = H.NewFrame(nil, pane); pane.TopBar.kind = "texture"
    pane.BookCornerFlipbook = H.NewFrame(nil, pane); pane.BookCornerFlipbook.kind = "texture"
    H.spellChrome = { pane.TopBar, pane.BookCornerFlipbook }
    pane.SearchBox = H.NewFrame(nil, pane)
    local searchArt = H.NewFrame(nil, pane.SearchBox); searchArt.kind = "texture"
    pane.SearchBox.GetRegions = function() return searchArt end
    H.spellSearchArt = searchArt
    pane.SettingsDropdown = H.NewFrame(nil, pane)
    local settingsArt = H.NewFrame(nil, pane.SettingsDropdown); settingsArt.kind = "texture"
    pane.SettingsDropdown.GetRegions = function() return settingsArt end
    H.spellSettingsArt = settingsArt
    -- Category tabs come from the pane's own tab system and carry no name.
    pane.CategoryTabSystem = H.NewFrame(nil, pane)
    pane.selectedTab = 1
    pane.GetTab = function() return pane.selectedTab end
    -- The window's page switch; the adapter hooks it to follow tab changes.
    PlayerSpellsFrame.SetTab = function(self, tabID) pane.selectedTab = tabID or 1 end
    H.spellTabs = {}
    pane.CategoryTabSystem.tabs = {}
    for index = 1, 2 do
        local tab = H.NewFrame(nil, pane.CategoryTabSystem)
        local art = H.NewFrame(nil, tab); art.kind = "texture"
        local label = H.NewFrame(nil, tab); label.kind = "fontstring"
        tab.GetRegions = function() return art, label end
        tab.GetID = function() return index end
        H.spellTabs[index] = { tab = tab, art = art, label = label }
        pane.CategoryTabSystem.tabs[index] = tab
    end
    -- A spell item row: row fields plus the button that carries the icon and
    -- the client's learned / unlearned border.
    local function spellItem()
        local item = H.NewFrame(nil, nil)
        item.Backplate = H.NewFrame(nil, item); item.Backplate.kind = "texture"
        item.Name = H.NewFrame(nil, item); item.Name.kind = "fontstring"; item.Name.textColor = { 1, 1, 1, 1 }
        item.Name.alpha = 0.6
        item.SubName = H.NewFrame(nil, item); item.SubName.kind = "fontstring"
        item.RequiredLevel = H.NewFrame(nil, item); item.RequiredLevel.kind = "fontstring"
        item.GetRegions = function() return item.Backplate end
        item.Button = H.NewFrame(nil, item)
        item.Button.Icon = H.NewFrame(nil, item.Button); item.Button.Icon.kind = "texture"
        item.Button.Border = H.NewFrame(nil, item.Button); item.Button.Border.kind = "texture"
        item.Button.BorderShadow = H.NewFrame(nil, item.Button); item.Button.BorderShadow.kind = "texture"
        item.Button.GetRegions = function() return item.Button.Icon, item.Button.Border end
        return item
    end
    local header = H.NewFrame(nil, nil)
    header.Backplate = H.NewFrame(nil, header); header.Backplate.kind = "texture"
    header.Text = H.NewFrame(nil, header); header.Text.kind = "fontstring"
    header.GetRegions = function() return header.Backplate, header.Text end
    H.spellHeader = header
    H.spellItems = { spellItem(), spellItem() }
    local paged = H.NewFrame(nil, pane)
    paged.viewFrames = {}
    paged.rows = { header, H.spellItems[1], H.spellItems[2] }
    paged.EnumerateFrames = function()
        local index = 0
        return function()
            index = index + 1
            local row = paged.rows[index]
            if row then return index, row end
        end
    end
    paged.DisplayViewsForCurrentPage = function() end
    paged.PagingControls = H.NewFrame(nil, paged)
    local prevArt = H.NewFrame(nil, paged.PagingControls); prevArt.kind = "texture"
    paged.PagingControls.GetRegions = function() return prevArt end
    H.spellPagingArt = prevArt
    pane.PagedSpellsFrame = paged
    H.spellPaged = paged
    -- The sibling pages share the window; their art must stay exactly as drawn.
    for _, key in ipairs({ "SpecFrame", "TalentsFrame" }) do
        local page = H.NewFrame(nil, PlayerSpellsFrame)
        local art = H.NewFrame(nil, page); art.kind = "texture"
        page.GetRegions = function() return art end
        page.specArt = art
        PlayerSpellsFrame[key] = page
        if key == "SpecFrame" then H.spellSpecArt = art end
    end
    -- ==== TRACK-P2: SYSTEM WINDOWS — append harness stubs inside H.Load above this line ====
    -- Raid track stubs: the two secure frames the prototype takes over (both
    -- start shown, like the client's own raid frames), the group state its
    -- diagnostic reads, and a member count derived from whatever UnitExists
    -- currently answers so a test can drive the roster through one override.
    H.inRaid = false
    _G.CompactRaidFrameContainer = H.NewFrame("CompactRaidFrameContainer", UIParent, "SecureUnitButtonTemplate")
    _G.CompactRaidFrameManager = H.NewFrame("CompactRaidFrameManager", UIParent, "SecureUnitButtonTemplate")
    _G.IsInRaid = function() return H.inRaid == true end
    _G.GetNumGroupMembers = function()
        local members = 0
        for index = 1, 40 do
            if UnitExists("raid" .. index) then members = members + 1 end
        end
        return members > 0 and members or 1
    end
    -- ==== TRACK-P3: RAID — append harness stubs inside H.Load above this line ====
    -- ==== TRACK-P3: MISC — append harness stubs inside H.Load above this line ====
    -- NPC window stubs shaped like the live client (GossipFrame's
    -- GreetingPanel is a ScrollBoxList of pooled greeting/quest/option rows,
    -- MerchantItem1 is a MerchantItemTemplate frame around an ItemButton with
    -- a quality-colored name, QuestFrame is parchment panels with QuestInfo
    -- reward buttons).
    _G.GossipFrame = H.NewFrame("GossipFrame", UIParent)
    GossipFrame.NineSlice = H.NewFrame(nil, GossipFrame)
    local gossipArt = H.NewFrame(nil, GossipFrame)
    gossipArt.kind = "texture"
    GossipFrame.GetRegions = function() return gossipArt end
    H.gossipArt = gossipArt
    GossipFrame.GreetingPanel = H.NewFrame(nil, GossipFrame)
    GossipFrame.GreetingPanel.NineSlice = H.NewFrame(nil, GossipFrame.GreetingPanel)
    local greetingBg = H.NewFrame(nil, GossipFrame.GreetingPanel)
    greetingBg.kind = "texture"
    GossipFrame.GreetingPanel.GetRegions = function() return greetingBg end
    H.greetingBg = greetingBg
    H.gossipScrollBox = H.NewFrame(nil, GossipFrame.GreetingPanel)
    GossipFrame.GreetingPanel.ScrollBox = H.gossipScrollBox
    GossipFrame.GreetingPanel.ScrollBar = H.NewFrame(nil, GossipFrame.GreetingPanel)
    -- Rows: greeting text, a spacer, two quest titles and two options, in the
    -- order the client inserts them into its DataProvider.
    H.gossipScrollRows = {}
    local function gossipRow()
        local row = H.NewFrame(nil, H.gossipScrollBox)
        H.gossipScrollRows[#H.gossipScrollRows + 1] = row
        return row
    end
    local greet = gossipRow()
    local greetText = H.NewFrame(nil, greet)
    greetText.kind = "fontstring"
    greetText.textColor = { 0.9, 0.8, 0.65, 1 }
    greet.GreetingText = greetText
    greet.GetRegions = function() return greetText end
    H.gossipText = greetText
    local spacer = gossipRow()
    spacer.GetRegions = function() return end
    local function titleRow(iconAtlas)
        local row = gossipRow()
        local icon = H.NewFrame(nil, row)
        icon.kind = "texture"
        icon.atlas = iconAtlas
        row.Icon = icon
        local label = H.NewFrame(nil, row)
        label.kind = "fontstring"
        label.textColor = { 1, 1, 1, 1 }
        row.GetRegions = function() return icon, label end
        row.GetFontString = function() return label end
        row.GetHighlightTexture = function() return nil end
        return row, icon, label
    end
    local questRow, questIcon, questLabel = titleRow("QuestNormal")
    local questRow2 = titleRow("QuestNormal")
    local optionRow, optionIcon, optionLabel = titleRow(nil)
    local optionRow2 = titleRow(nil)
    H.gossipQuestIcon, H.gossipQuestLabel = questIcon, questLabel
    H.gossipOptionIcon, H.gossipOptionLabel = optionIcon, optionLabel
    H.gossipScrollBox.ForEachFrame = function(self, fn)
        for _, row in ipairs(H.gossipScrollRows) do fn(row) end
    end
    -- The friendship bar is window state (the rep bar), never skinned.
    GossipFrame.FriendshipStatusBar = H.NewFrame(nil, GossipFrame)
    local friendshipArt = H.NewFrame(nil, GossipFrame.FriendshipStatusBar)
    friendshipArt.kind = "texture"
    GossipFrame.FriendshipStatusBar.GetRegions = function() return friendshipArt end
    H.friendshipArt = friendshipArt
    _G.GossipFrameCloseButton = H.NewFrame("GossipFrameCloseButton", GossipFrame)
    _G.MerchantFrame = H.NewFrame("MerchantFrame", UIParent)
    MerchantFrame.NineSlice = H.NewFrame(nil, MerchantFrame)
    local merchantArt = H.NewFrame(nil, MerchantFrame)
    merchantArt.kind = "texture"
    MerchantFrame.GetRegions = function() return merchantArt end
    H.merchantArt = merchantArt
    -- A vendor slot: the plate frame, the label frame and the quality-colored
    -- name, around an item button with its icon, quality border and quest bang.
    _G.MerchantItem1 = H.NewFrame("MerchantItem1", MerchantFrame)
    local merchantSlotArt = H.NewFrame(nil, MerchantItem1)
    merchantSlotArt.kind = "texture"
    local merchantLabelFrame = H.NewFrame(nil, MerchantItem1)
    merchantLabelFrame.kind = "texture"
    local merchantItemName = H.NewFrame(nil, MerchantItem1)
    merchantItemName.kind = "fontstring"
    merchantItemName.textColor = { 0.2, 0.6, 1, 1 }
    MerchantItem1.Name = merchantItemName
    MerchantItem1.GetRegions = function() return merchantSlotArt, merchantLabelFrame, merchantItemName end
    local merchantButton = H.NewFrame(nil, MerchantItem1)
    local merchantIcon = H.NewFrame(nil, merchantButton)
    merchantIcon.kind = "texture"
    merchantButton.Icon = merchantIcon
    local merchantIconBorder = H.NewFrame(nil, merchantButton)
    merchantIconBorder.kind = "texture"
    merchantButton.IconBorder = merchantIconBorder
    merchantButton.GetRegions = function() return merchantIcon, merchantIconBorder end
    MerchantItem1.ItemButton = merchantButton
    _G.MerchantItem1MoneyFrame = H.NewFrame("MerchantItem1MoneyFrame", MerchantItem1)
    local merchantCoin = H.NewFrame(nil, MerchantItem1MoneyFrame)
    merchantCoin.kind = "texture"
    MerchantItem1MoneyFrame.GetRegions = function() return merchantCoin end
    _G.MerchantMoneyFrame = H.NewFrame("MerchantMoneyFrame", MerchantFrame)
    local playerCoin = H.NewFrame(nil, MerchantMoneyFrame)
    playerCoin.kind = "texture"
    MerchantMoneyFrame.GetRegions = function() return playerCoin end
    -- The action tiles carry an icon atlas on a 36px button.
    local function actionButton(name)
        local button = H.NewFrame(name, MerchantFrame)
        local icon = H.NewFrame(nil, button)
        icon.kind = "texture"
        icon.atlas = "SpellIcon-256x256"
        button.Icon = icon
        button.GetRegions = function() return icon end
        return button, icon
    end
    local _, sellIcon = actionButton("MerchantSellAllJunkButton")
    H.merchantSellIcon = sellIcon
    -- Page arrows draw a greyscale Disabled texture at the ends of the list.
    local prevPage = H.NewFrame("MerchantPrevPageButton", MerchantFrame)
    local prevArt = H.NewFrame(nil, prevPage)
    prevArt.kind = "texture"
    prevPage.GetRegions = function() return prevArt end
    H.merchantPrevArt = prevArt
    _G.MerchantBuyBackItem = H.NewFrame("MerchantBuyBackItem", MerchantFrame)
    MerchantBuyBackItem.GetRegions = function() return end
    H.merchantIcon, H.merchantCoin, H.playerCoin = merchantIcon, merchantCoin, playerCoin
    H.merchantSlotArt, H.merchantItemName, H.merchantIconBorder = merchantSlotArt, merchantItemName, merchantIconBorder
    _G.QuestFrame = H.NewFrame("QuestFrame", UIParent)
    QuestFrame.NineSlice = H.NewFrame(nil, QuestFrame)
    local questArt = H.NewFrame(nil, QuestFrame)
    questArt.kind = "texture"
    QuestFrame.GetRegions = function() return questArt end
    H.questArt = questArt
    QuestFrame.QuestFrameDetailPanel = H.NewFrame(nil, QuestFrame)
    QuestFrame.QuestFrameDetailPanel.Bg = H.NewFrame(nil, QuestFrame.QuestFrameDetailPanel)
    QuestFrame.QuestFrameDetailPanel.Bg.kind = "texture"
    local questBody = H.NewFrame(nil, QuestFrame.QuestFrameDetailPanel)
    questBody.kind = "fontstring"
    questBody.textColor = { 0.12, 0.08, 0.04, 1 }
    QuestFrame.QuestFrameDetailPanel.GetRegions = function() return QuestFrame.QuestFrameDetailPanel.Bg, questBody end
    questBody.IsFixedColor = true
    _G.QuestDetailScrollChildFrame = H.NewFrame("QuestDetailScrollChildFrame", QuestFrame.QuestFrameDetailPanel)
    _G.QuestFrameDetailPanel = QuestFrame.QuestFrameDetailPanel
    -- A reward button, named "<RewardsFrame>QuestInfoItemN", parented onto the
    -- scroll child like the live QuestInfo_Display does.
    QuestFrame.QuestFrameRewardPanel = H.NewFrame(nil, QuestFrame)
    QuestFrame.QuestFrameRewardPanel.SealMaterialBG = H.NewFrame(nil, QuestFrame.QuestFrameRewardPanel)
    QuestFrame.QuestFrameRewardPanel.SealMaterialBG.kind = "texture"
    QuestFrame.QuestFrameRewardPanel.GetRegions = function() return QuestFrame.QuestFrameRewardPanel.SealMaterialBG end
    _G.QuestRewardScrollChildFrame = H.NewFrame("QuestRewardScrollChildFrame", QuestFrame.QuestFrameRewardPanel)
    local rewardFrame = H.NewFrame("QuestInfoRewardsFrame", QuestRewardScrollChildFrame)
    _G.QuestInfoRewardsFrame = rewardFrame
    _G.QuestInfoRewardsFrameQuestInfoItem1 = H.NewFrame("QuestInfoRewardsFrameQuestInfoItem1", rewardFrame)
    local rewardButton = QuestInfoRewardsFrameQuestInfoItem1
    local rewardIcon = H.NewFrame(nil, rewardButton)
    rewardIcon.kind = "texture"
    rewardButton.Icon = rewardIcon
    local rewardBorder = H.NewFrame(nil, rewardButton)
    rewardBorder.kind = "texture"
    rewardButton.IconBorder = rewardBorder
    local rewardName = H.NewFrame(nil, rewardButton)
    rewardName.kind = "fontstring"
    rewardName.textColor = { 0.64, 0.21, 0.93, 1 }
    rewardButton.Name = rewardName
    rewardButton.GetRegions = function() return rewardIcon, rewardBorder, rewardName end
    QuestFrame.QuestFrameGreetingPanel = H.NewFrame(nil, QuestFrame)
    _G.QuestGreetingScrollChildFrame = H.NewFrame("QuestGreetingScrollChildFrame", QuestFrame.QuestFrameGreetingPanel)
    -- Pooled greeting title buttons carry a quest icon and a label.
    local greetingButton = H.NewFrame(nil, QuestGreetingScrollChildFrame)
    local greetingIcon = H.NewFrame(nil, greetingButton)
    greetingIcon.kind = "texture"
    greetingButton.Icon = greetingIcon
    local greetingLabel = H.NewFrame(nil, greetingButton)
    greetingLabel.kind = "fontstring"
    greetingButton.GetRegions = function() return greetingIcon, greetingLabel end
    greetingButton.GetFontString = function() return greetingLabel end
    H.greetingButton, H.greetingIcon = greetingButton, greetingIcon
    _G.QuestFrameAcceptButton = H.NewFrame("QuestFrameAcceptButton", QuestFrame)
    local questOptionArt = H.NewFrame(nil, QuestFrameAcceptButton)
    questOptionArt.kind = "texture"
    QuestFrameAcceptButton.GetRegions = function() return questOptionArt end
    H.questOptionArt = questOptionArt
    H.questBody, H.rewardIcon, H.rewardButton, H.rewardName = questBody, rewardIcon, rewardButton, rewardName
    H.rewardBorder = rewardBorder
    _G.QuestModelScene = H.NewFrame("QuestModelScene", UIParent)
    _G.QuestNPCModelText = H.NewFrame("QuestNPCModelText", QuestModelScene)
    QuestNPCModelText.kind = "fontstring"
    local modelArt = H.NewFrame(nil, QuestModelScene)
    modelArt.kind = "texture"
    QuestModelScene.GetRegions = function() return modelArt end
    H.questModelArt = modelArt
    -- Social window stubs: three friend rows (each with a status icon the skin
    -- must keep), an invite button whose art stays, a page tab that only keeps
    -- its label and a protected action button that may only be recolored.
    _G.FriendsFrame = H.NewFrame("FriendsFrame", UIParent)
    FriendsFrame.NineSlice = H.NewFrame(nil, FriendsFrame)
    local friendsArt = H.NewFrame(nil, FriendsFrame)
    friendsArt.kind = "texture"
    local friendsTitle = H.NewFrame(nil, FriendsFrame)
    friendsTitle.kind = "fontstring"
    friendsTitle.textColor = { 1, 0.82, 0, 1 }
    FriendsFrame.GetRegions = function() return friendsArt, friendsTitle end
    H.friendsArt, H.friendsTitle = friendsArt, friendsTitle
    FriendsFrame.FriendsListFrame = H.NewFrame(nil, FriendsFrame)
    H.socialRows = {}
    -- The live client's social rows are pooled inside a scroll box rather than
    -- named globals, and each row carries its content in named fields:
    -- background (the online/offline plate), status (the AFK/DND/offline icon),
    -- gameIcon, name and info FontStrings the client writes its own colors to,
    -- and a favourite star. The ScrollBox stub enumerates rows the way
    -- ScrollBoxListMixin's ForEachFrame does; tests append to `frames` to
    -- simulate the client acquiring a recycled row.
    H.friendsScrollBox = H.NewFrame(nil, FriendsFrame.FriendsListFrame)
    H.friendsScrollBox.frames = {}
    H.friendsScrollBox.ForEachFrame = function(self, fn)
        for _, row in ipairs(self.frames) do fn(row) end
    end
    FriendsFrame.FriendsListFrame.ScrollBox = H.friendsScrollBox
    local function friendRow(index)
        local row = H.NewFrame(nil, H.friendsScrollBox)
        local background = H.NewFrame(nil, row)
        background.kind = "texture"
        local status = H.NewFrame(nil, row)
        status.kind = "texture"
        local gameIcon = H.NewFrame(nil, row)
        gameIcon.kind = "texture"
        local favorite = H.NewFrame(nil, row)
        favorite.kind = "texture"
        local name = H.NewFrame(nil, row)
        name.kind = "fontstring"
        name.textColor = { 1, 0.82, 0, 1 }
        local info = H.NewFrame(nil, row)
        info.kind = "fontstring"
        info.textColor = { 0.486, 0.518, 0.541, 1 }
        local highlight = H.NewFrame(nil, row)
        highlight.kind = "texture"
        row.background, row.status, row.gameIcon, row.Favorite = background, status, gameIcon, favorite
        row.name, row.info, row.Highlight = name, info, highlight
        row.GetHighlightTexture = function() return highlight end
        row.GetRegions = function() return background, status, gameIcon, favorite, name, info, highlight end
        H.socialRows[index] = row
        H.friendsScrollBox.frames[index] = row
        if index == 1 then
            H.socialRowName, H.socialRowStatus, H.socialRowPlate = name, status, background
            H.socialRowInfo, H.socialRowHighlight, H.socialRowGameIcon = info, highlight, gameIcon
        end
        return row
    end
    for index = 1, 3 do friendRow(index) end
    H.friendRow = friendRow
    _G.FriendsList_Update = function() end
    _G.FriendsFrameInviteButton = H.NewFrame("FriendsFrameInviteButton", FriendsFrame)
    local inviteArt = H.NewFrame(nil, FriendsFrameInviteButton)
    inviteArt.kind = "texture"
    local inviteText = H.NewFrame(nil, FriendsFrameInviteButton)
    inviteText.kind = "fontstring"
    inviteText.textColor = { 1, 0.82, 0, 1 }
    FriendsFrameInviteButton.GetRegions = function() return inviteArt, inviteText end
    H.inviteArt, H.inviteText = inviteArt, inviteText
    _G.FriendsFrameTab1 = H.NewFrame("FriendsFrameTab1", FriendsFrame)
    local friendsTabArt = H.NewFrame(nil, FriendsFrameTab1)
    friendsTabArt.kind = "texture"
    local friendsTabText = H.NewFrame(nil, FriendsFrameTab1)
    friendsTabText.kind = "fontstring"
    friendsTabText.textColor = { 1, 0.82, 0, 1 }
    FriendsFrameTab1.GetRegions = function() return friendsTabArt, friendsTabText end
    H.friendsTabArt, H.friendsTabText = friendsTabArt, friendsTabText
    -- Who pane and ignore list in their live shapes: a scroll box of pooled
    -- anonymous rows (Name/Variable/Level/Class labels plus the hover highlight),
    -- the sortable column headers, the search field, the sort dropdown and the
    -- result totals line. The controls whose own state is their art are checked
    -- by the tests to stay native.
    _G.WhoFrame = H.NewFrame("WhoFrame", FriendsFrame)
    FriendsFrame.WhoFrame = WhoFrame
    H.whoScrollBox = H.NewFrame(nil, WhoFrame)
    H.whoScrollBox.frames = {}
    H.whoScrollBox.ForEachFrame = function(self, fn)
        for _, row in ipairs(self.frames) do fn(row) end
    end
    WhoFrame.ScrollBox = H.whoScrollBox
    local function whoRow(index)
        local row = H.NewFrame(nil, H.whoScrollBox)
        local highlight = H.NewFrame(nil, row)
        highlight.kind = "texture"
        local name = H.NewFrame(nil, row)
        name.kind = "fontstring"
        name.textColor = { 1, 0.82, 0, 1 }
        local variable = H.NewFrame(nil, row)
        variable.kind = "fontstring"
        variable.textColor = { 1, 0.82, 0, 1 }
        local level = H.NewFrame(nil, row)
        level.kind = "fontstring"
        local class = H.NewFrame(nil, row)
        class.kind = "fontstring"
        class.textColor = { 0.41, 0.8, 0.94, 1 }
        row.Highlight, row.Name, row.Variable, row.Level, row.Class = highlight, name, variable, level, class
        row.GetHighlightTexture = function() return highlight end
        row.GetRegions = function() return highlight, name, variable, level, class end
        H.whoRows = H.whoRows or {}
        H.whoRows[index] = row
        H.whoScrollBox.frames[index] = row
        if index == 1 then H.whoName, H.whoClass, H.whoHighlight = name, class, highlight end
        return row
    end
    for index = 1, 2 do whoRow(index) end
    H.whoRow = whoRow
    _G.WhoFrameColumnHeader1 = H.NewFrame("WhoFrameColumnHeader1", WhoFrame)
    H.whoHeaderArt = H.NewFrame(nil, WhoFrameColumnHeader1)
    H.whoHeaderArt.kind = "texture"
    WhoFrameColumnHeader1.GetRegions = function() return H.whoHeaderArt end
    _G.WhoFrameEditBox = H.NewFrame("WhoFrameEditBox", WhoFrame)
    H.whoEditArt = H.NewFrame(nil, WhoFrameEditBox)
    H.whoEditArt.kind = "texture"
    WhoFrameEditBox.GetRegions = function() return H.whoEditArt end
    _G.WhoFrameDropdown = H.NewFrame("WhoFrameDropdown", WhoFrame)
    _G.WhoFrameTotals = H.NewFrame("WhoFrameTotals", WhoFrame)
    H.whoTotals = H.NewFrame(nil, WhoFrameTotals)
    H.whoTotals.kind = "fontstring"
    H.whoTotals.textColor = { 1, 0.82, 0, 1 }
    WhoFrameTotals.GetRegions = function() return H.whoTotals end
    -- The ignore list is a small window frame of its own, anchored beside the
    -- main window, with a pooled row list and an unignore button whose disabled
    -- state lives in its art.
    _G.IgnoreListWindow = H.NewFrame("IgnoreListWindow", FriendsFrame)
    FriendsFrame.IgnoreListWindow = IgnoreListWindow
    H.ignoreScrollBox = H.NewFrame(nil, IgnoreListWindow)
    H.ignoreScrollBox.frames = {}
    H.ignoreScrollBox.ForEachFrame = function(self, fn)
        for _, row in ipairs(self.frames) do fn(row) end
    end
    IgnoreListWindow.ScrollBox = H.ignoreScrollBox
    local ignoreRow = H.NewFrame(nil, H.ignoreScrollBox)
    local ignoreName = H.NewFrame(nil, ignoreRow)
    ignoreName.kind = "fontstring"
    ignoreName.textColor = { 1, 0.82, 0, 1 }
    ignoreRow.name = ignoreName
    ignoreRow.GetRegions = function() return ignoreName end
    H.ignoreRow, H.ignoreName = ignoreRow, ignoreName
    H.ignoreScrollBox.frames[1] = ignoreRow
    _G.IgnoreListWindowUnignorePlayerButton = H.NewFrame("IgnoreListWindowUnignorePlayerButton", IgnoreListWindow)
    IgnoreListWindow.UnignorePlayerButton = IgnoreListWindowUnignorePlayerButton
    H.unignoreArt = H.NewFrame(nil, IgnoreListWindowUnignorePlayerButton)
    H.unignoreArt.kind = "texture"
    IgnoreListWindowUnignorePlayerButton.GetRegions = function() return H.unignoreArt end
    -- ==== TRACK-P4: SYSTEM — append harness stubs inside H.Load above this line ====
    -- Subgroup layout stub for the raid frames: GetRaidRosterInfo answers only
    -- when a test fills H.raidSubgroups, so every other test keeps the
    -- index-based grid. Name and rank are plain values; the component reads only
    -- the third return value (subgroup).
    H.raidSubgroups = {}
    _G.GetRaidRosterInfo = function(index)
        local subgroup = H.raidSubgroups[index]
        if subgroup == nil then return nil end
        return "Member" .. index, 0, subgroup
    end
    -- GetRaidTargetIndex is already stubbed above and reads H.raidTargets, so it
    -- is left untouched instead of being wrapped around itself.
    -- ==== TRACK-P5: RAID — append harness stubs inside H.Load above this line ====
    -- Floating combat text stub: the game's own root frame with two FontString
    -- children. Each font string records the full SetFont argument list (font,
    -- size, flags), which the base harness Frame stub drops, and starts with
    -- its own font, size and color so a restore can be verified.
    _G.FloatingCombatText = H.NewFrame("FloatingCombatText", UIParent)
    H.combatText = {}
    local function combatTextFont(parent, size, color)
        local text = parent:CreateFontString(nil, "OVERLAY")
        text.kind = "fontstring"
        text.font, text.fontSize, text.fontFlags = "Fonts/Original.ttf", size, ""
        text.textColor = color
        text.GetFont = function(self) return self.font, self.fontSize, self.fontFlags end
        text.SetFont = function(self, font, size, flags) self.font, self.fontSize, self.fontFlags = font, size, flags end
        H.combatText[#H.combatText + 1] = text
        return text
    end
    combatTextFont(FloatingCombatText, 22, { 0.2, 0.4, 0.6, 1 })
    combatTextFont(FloatingCombatText, 16, { 0.9, 0.9, 0.1, 1 })
    -- ==== TRACK-P5: COMBATTEXT — append harness stubs inside H.Load above this line ====
    -- ==== TRACK: VIS-16 MAP, STRIP, EXPERIENCE — append harness stubs inside H.Load above this line ====
    -- Reputation replaces the experience bar when a faction is watched. The
    -- default is "nothing watched", so existing experience tests keep an XP bar.
    H.watchedFaction = nil
    _G.GetWatchedFactionInfo = function()
        local faction = H.watchedFaction
        if not faction then return nil end
        return faction.name, faction.reaction, faction.minimum, faction.maximum, faction.current
    end
    _G.GetMaxLevelForPlayerExpansion = function() return H.maxLevel or 90 end
    _G.GetInventoryItemDurability = function(slot)
        local values = H.durability and H.durability[slot]
        if not values then return nil end
        return values[1], values[2]
    end
    -- Native minimap shortcuts: the calendar entry exists, tracking and the
    -- addon compartment are optional, and the world map button is the cluster's
    -- own child. LumaUI only reads that they exist.
    _G.GameTimeFrame = H.NewFrame("GameTimeFrame", MinimapCluster)
    _G.MiniMapTracking = H.NewFrame("MiniMapTracking", MinimapCluster)
    MinimapCluster.ToggleMinimapButton = H.NewFrame("MiniMapWorldMapButton", MinimapCluster)
    -- ==== TRACK-P5: MISC — append harness stubs inside H.Load above this line ====
    H.nameplates = {}
    _G.C_NamePlate = {
        GetNamePlateForUnit = function(unit) return H.nameplates[unit] end,
    }
    local function nameplateBar()
        local bar = H.NewFrame(nil, UIParent)
        bar.barColor = { 0.8, 0.1, 0.1, 1 }
        bar.GetStatusBarColor = function(self) return unpack(self.barColor) end
        return bar
    end
    local plate = H.NewFrame("NamePlate1", UIParent)
    plate.UnitFrame = H.NewFrame(nil, plate)
    plate.UnitFrame.healthBar = nameplateBar()
    H.nameplates.target = plate
    H.targetPlate = plate
    local app = {}
    local files = _G.LUMA_TEST_FILES or {}
    if not _G.LUMA_TEST_FILES then
        for line in io.lines("LumaUI.toc") do
            if line:match("%.lua%s*$") then files[#files + 1] = line:gsub("\\", "/"):gsub("\r", "") end
        end
    end
    for _, file in ipairs(files) do
        assert(loadfile(file))("LumaUI", app)
    end
    return app
end
return H
