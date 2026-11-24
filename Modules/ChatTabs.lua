local _, app = ...
local module

local nativeArt = {
    "Left", "Right", "Middle",
    "ActiveLeft", "ActiveMiddle", "ActiveRight",
    "HighlightLeft", "HighlightMiddle", "HighlightRight",
}

local function windowLimit()
    local limit = app.Capabilities.Plain(NUM_CHAT_WINDOWS, "number") or 10
    return math.max(1, math.min(12, math.floor(limit)))
end

local function forbidden(frame)
    if not frame or type(frame.IsForbidden) ~= "function" then return false end
    local ok, value = pcall(frame.IsForbidden, frame)
    return ok and value == true
end

local function tabFor(index)
    return _G["ChatFrame" .. index .. "Tab"]
end

-- Every window the client registered, including floating, temporary and
-- whisper windows whose names go beyond NUM_CHAT_WINDOWS. Reading the client's
-- own list means a reused or brand-new temporary window is styled as soon as
-- it exists, without a poll.
local function windowNames()
    local names, seen = {}, {}
    local function add(value)
        local name = app.Capabilities.Plain(value, "string")
        if name and not seen[name] then seen[name] = true; names[#names + 1] = name end
    end
    if type(CHAT_FRAMES) == "table" then
        pcall(function() for _, name in ipairs(CHAT_FRAMES) do add(name) end end)
    end
    for index = 1, windowLimit() do add("ChatFrame" .. index) end
    return names
end

local function isActive(frame)
    if not frame.isDocked then return true end
    if type(FCFDock_GetSelectedWindow) == "function" and GENERAL_CHAT_DOCK then
        local ok, selected = pcall(FCFDock_GetSelectedWindow, GENERAL_CHAT_DOCK)
        if ok and selected then return selected == frame end
    end
    return SELECTED_CHAT_FRAME == frame
end

-- Unread is the client's own alert state: FCF_StartAlertFlash sets it when a
-- window receives a message the player has not seen, FCF_StopAlertFlash clears
-- it when the window is shown. Reading it keeps the semantic identical instead
-- of inventing a second notion of "unread".
local function isAlerting(tab)
    local util = _G.ChatFrameUtil
    if type(util) ~= "table" or type(util.IsTabAlerting) ~= "function" then return false end
    local ok, alerting = pcall(util.IsTabAlerting, tab)
    return ok and alerting == true
end

local function ensureDecor(tab)
    local decor = {}
    decor.bg = tab:CreateTexture(nil, "BORDER")
    decor.bg:SetPoint("TOPLEFT", tab, "TOPLEFT", -2, 4)
    decor.bg:SetPoint("BOTTOMRIGHT", tab, "BOTTOMRIGHT", 2, -2)
    decor.hover = tab:CreateTexture(nil, "BORDER", nil, 1)
    decor.hover:SetAllPoints(decor.bg)
    decor.hover:Hide()
    decor.rule = tab:CreateTexture(nil, "BORDER", nil, 2)
    decor.rule:SetPoint("BOTTOMLEFT", decor.bg, "BOTTOMLEFT", 0, 0)
    decor.rule:SetPoint("BOTTOMRIGHT", decor.bg, "BOTTOMRIGHT", 0, 0)
    decor.rule:SetHeight(app.Pixel:Pixels(1, tab))
    decor.rule:Hide()
    return decor
end

local function hideNative(tab)
    tab.nativeArt = tab.nativeArt or {}
    if tab.nativeAlpha == nil then tab.nativeAlpha = tab:GetAlpha() end
    -- The template ships the whole tab at 0.4 alpha; LumaUI draws its own
    -- surface and text colors, so the tab itself must be fully opaque.
    tab:SetAlpha(1)
    for _, key in ipairs(nativeArt) do
        local region = tab[key]
        if region and region.Hide then
            if tab.nativeArt[region] == nil then
                -- Alpha zero survives the client re-showing its own tab art on
                -- every dock update; restoring the saved alpha brings it back.
                tab.nativeArt[region] = { shown = region:IsShown(), alpha = region:GetAlpha() }
            end
            region:SetAlpha(0)
            region:Hide()
        end
    end
end

local function restoreNative(tab)
    for region, state in pairs(tab.nativeArt or {}) do
        region:SetAlpha(state.alpha)
        if state.shown then region:Show() else region:Hide() end
    end
    tab.nativeArt = nil
    if tab.nativeAlpha ~= nil then
        tab:SetAlpha(tab.nativeAlpha)
        tab.nativeAlpha = nil
    end
end

local function fontFor(tab)
    if type(tab.GetFontString) == "function" then
        local ok, font = pcall(tab.GetFontString, tab)
        if ok and font then return font end
    end
    local name = type(tab.GetName) == "function" and tab:GetName()
    return name and _G[name .. "Text"] or nil
end

-- Four states with one meaning each, so a tab is never ambiguous:
--   selected  raised surface, accent rule, full-strength label
--   unread    quiet surface with the accent rule, as the client flashes it
--   hover     quiet surface with a lit hover band (any tab, including unread)
--   idle      quiet surface, no rule, muted label
local function applyLook(entry)
    local decor, tab = entry.decor, entry.tab
    if not decor or not tab then return end
    local colors = app.Theme.colors
    local accent = app.Theme:Accent()
    local selected = entry.selected == true
    local unread = entry.unread == true
    -- Pearl tabs are text with one amber underline, never pills: the backing
    -- stays transparent and only the selected/unread rule carries state.
    decor.bg:SetColorTexture(0, 0, 0, 0)
    decor.bg:Show()
    local rule = selected and accent or colors.line
    decor.rule:SetHeight(app.Pixel:Pixels(1, tab))
    decor.rule:SetColorTexture(rule[1], rule[2], rule[3], selected and 1 or (unread and 0.7 or 0))
    decor.rule:SetShown(selected or unread == true)
    decor.hover:SetColorTexture(colors.line[1], colors.line[2], colors.line[3], entry.hovering and 0.18 or 0)
    decor.hover:SetShown(entry.hovering == true and not selected)
    local font = entry.font
    if font then
        local color = selected and accent or (unread and colors.text or colors.muted)
        font:SetTextColor(color[1], color[2], color[3])
    end
end

local function paintTab(entry)
    local tab, frame = entry.tab, entry.frame
    if not tab or not frame or forbidden(tab) then return end
    hideNative(tab)
    entry.decor = entry.decor or ensureDecor(tab)
    if not entry.font then
        entry.font = fontFor(tab)
        if entry.font and not entry.fontColor then entry.fontColor = { entry.font:GetTextColor() } end
    end
    entry.selected = isActive(frame) == true
    -- Unread is the client's own alert flag; the selected window is by
    -- definition read, so its rule always wins over the unread one.
    entry.unread = not entry.selected and isAlerting(tab)
    -- Tabs are state, not motion: a click, a hover or an unread flag settles in
    -- the same frame. Only the chat backing fades, so no ticker is ever owed to
    -- a tab and a fast dock switch can never leave a half-painted one.
    applyLook(entry)
end

local function paintAll(self)
    for _, entry in pairs(self.tabs or {}) do paintTab(entry) end
end

-- Two client entry points write state we must follow, and neither is an event
-- an addon can observe reliably: FCF_StartAlertFlash/StopAlertFlash set the
-- unread flag, and FCFTab_UpdateColors/UpdateAlpha re-show the native art and
-- re-set the tab alpha on every dock update. Hooking them proves our repaint
-- runs after the client's write instead of racing its event handler. There is
-- no native unhook, so each callback checks the component state instead.
local clientHooked = false
local function hookClient()
    if clientHooked or type(hooksecurefunc) ~= "function" then return end
    local names = {
        "FCF_StartAlertFlash", "FCF_StopAlertFlash",
        "FCFTab_UpdateColors", "FCFTab_UpdateAlpha",
    }
    local available = {}
    for _, name in ipairs(names) do
        if type(_G[name]) == "function" then available[#available + 1] = name end
    end
    if #available == 0 then return end
    clientHooked = true
    local function repaint()
        if module and module.running then app:Call("chatTabs/client", paintAll, module) end
    end
    for _, name in ipairs(available) do hooksecurefunc(name, repaint) end
end

local function hookTab(entry)
    local tab = entry.tab
    if not tab then return end
    if not entry.hooked then
        tab:HookScript("OnClick", function()
            if module.running then app:Call("chatTabs/click", paintAll, module) end
        end)
        tab:HookScript("OnEnter", function()
            if module.running then entry.hovering = true; app:Call("chatTabs/hover", paintTab, entry) end
        end)
        tab:HookScript("OnLeave", function()
            entry.hovering = false
            if module.running then app:Call("chatTabs/leave", paintTab, entry) end
        end)
        -- Dock selection can change without a tab click (slash commands,
        -- whispers, login); the selected window is shown at that moment.
        entry.frame:HookScript("OnShow", function()
            if module.running then app:Call("chatTabs/show", paintAll, module) end
        end)
        entry.hooked = true
    end
    hookClient()
end

local function detachEntry(entry)
    if not entry then return end
    entry.hovering, entry.selected, entry.unread = nil, nil, nil
    restoreNative(entry.tab)
    if entry.decor then
        entry.decor.bg:Hide()
        entry.decor.rule:Hide()
        entry.decor.hover:Hide()
    end
    if entry.font and entry.fontColor then entry.font:SetTextColor(unpack(entry.fontColor)) end
end

local function attach(self)
    self.tabs = self.tabs or {}
    local live = {}
    for _, name in ipairs(windowNames()) do
        local index = tonumber(name:match("^ChatFrame(%d+)$"))
        local tab = index and tabFor(index) or nil
        local frame = index and _G[name] or nil
        if tab and frame and not forbidden(tab) then
            local entry = self.tabs[index]
            if entry and (entry.tab ~= tab or entry.frame ~= frame) then
                detachEntry(entry)
                entry = nil
            end
            if not entry then
                entry = { tab = tab, frame = frame }
                self.tabs[index] = entry
            end
            hookTab(entry)
            paintTab(entry)
            live[index] = true
        end
    end
    for index, entry in pairs(self.tabs) do
        if not live[index] then
            detachEntry(entry)
            self.tabs[index] = nil
        end
    end
end

module = app:RegisterComponent({ id = "chatTabs", label = "chatTabs",
    Supported = function() return _G.ChatFrame1Tab ~= nil end,
    Enable = function(self)
        attach(self)
        self:Listen("UPDATE_CHAT_WINDOWS", attach)
        self:Listen("UPDATE_FLOATING_CHAT_WINDOWS", attach)
        self:Listen("PLAYER_ENTERING_WORLD", attach)
    end,
    Refresh = attach,
    Disable = function(self)
        for _, entry in pairs(self.tabs or {}) do detachEntry(entry) end
    end,
})
