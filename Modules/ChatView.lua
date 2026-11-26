local _, app = ...
local module

-- Phase 06 (015): LumaUI's own message area. The client still formats, filters
-- and routes every line; this module only listens to the final line a native
-- chat window is handed (AddMessage) and draws it in its own scrolling frame.
-- Input stays with the client's edit box, links go through SetItemRef, and the
-- combat log keeps its own window. A window is taken over only when its view was
-- built and back-filled; any failure keeps that one window native.
--
-- Secret lines are handed to the drawing call untouched: nothing here reads,
-- compares, concatenates, stores or counts their content.

local HISTORY = 500
local THIRD_PARTY = { "Prat-3.0", "Chatter", "Chattynator", "ElvUI", "Glass", "WIM" }

local function forbidden(frame)
    if not frame or type(frame.IsForbidden) ~= "function" then return false end
    local ok, value = pcall(frame.IsForbidden, frame)
    return ok and value == true
end

local function windowNames()
    local names, seen = {}, {}
    local function add(value)
        local name = app.Capabilities.Plain(value, "string")
        if name and not seen[name] then seen[name] = true; names[#names + 1] = name end
    end
    if type(CHAT_FRAMES) == "table" then
        pcall(function() for _, name in ipairs(CHAT_FRAMES) do add(name) end end)
    end
    local limit = app.Capabilities.Plain(NUM_CHAT_WINDOWS, "number") or 10
    for index = 1, math.max(1, math.min(12, math.floor(limit))) do add("ChatFrame" .. index) end
    return names
end

local function thirdParty()
    local api = _G.C_AddOns
    local loaded = api and api.IsAddOnLoaded
    if type(loaded) ~= "function" then return nil end
    for _, name in ipairs(THIRD_PARTY) do
        local ok, value = pcall(loaded, name)
        if ok and value then return name end
    end
end

local function wanted()
    return module.running == true and app.Store:Profile().ui.chatTakeover == true
end

local function publish(entry, active, reason)
    entry.reason = reason
    app.Ownership:Set("chat.view" .. entry.index, {
        intent = wanted() and "owned" or "styled",
        active = active and "owned" or "native",
        evidence = "simulated",
        reason = reason,
    })
end

local function atBottom(view)
    if type(view.AtBottom) ~= "function" then return true end
    local ok, value = pcall(view.AtBottom, view)
    return not ok or value == true
end

local function refreshButton(entry)
    local button = entry.toBottom
    if not button then return end
    local show = entry.active == true and not atBottom(entry.view)
    button:SetShown(show)
    if show then
        local count = entry.unread or 0
        button:SetText(count > 0 and string.format(app.L.chatViewUnread, count) or app.L.chatViewBottom)
    end
end

local function toBottom(entry)
    entry.unread = 0
    if entry.view and type(entry.view.ScrollToBottom) == "function" then
        pcall(entry.view.ScrollToBottom, entry.view)
    end
    refreshButton(entry)
end

local function buildView(entry)
    if entry.view then return entry.view end
    local ok, view = pcall(CreateFrame, "ScrollingMessageFrame", "LumaUIChatView" .. entry.index, UIParent)
    if not ok or not view or type(view.AddMessage) ~= "function" then return nil end
    view:SetFrameStrata("LOW")
    if type(view.SetMaxLines) == "function" then view:SetMaxLines(HISTORY) end
    if type(view.SetFading) == "function" then view:SetFading(false) end
    if type(view.SetJustifyH) == "function" then view:SetJustifyH("LEFT") end
    if type(view.SetHyperlinksEnabled) == "function" then view:SetHyperlinksEnabled(true) end
    view:EnableMouse(true)
    view:EnableMouseWheel(true)
    view:SetScript("OnMouseWheel", function(self, delta)
        if module.running ~= true then return end
        local up = delta > 0
        if IsControlKeyDown and IsControlKeyDown() then
            local jump = up and self.ScrollToTop or self.ScrollToBottom
            if jump then jump(self) end
        elseif IsShiftKeyDown and IsShiftKeyDown() then
            local page = up and self.PageUp or self.PageDown
            if page then page(self) end
        else
            local line = up and self.ScrollUp or self.ScrollDown
            if line then line(self); line(self) end
        end
        refreshButton(entry)
    end)
    -- Links keep the client's behaviour: item/spell/player/community links, report
    -- and ignore all go through SetItemRef; tooltips come from GameTooltip.
    view:SetScript("OnHyperlinkClick", function(self, link, text, button)
        if type(SetItemRef) == "function" then pcall(SetItemRef, link, text, button, self) end
    end)
    view:SetScript("OnHyperlinkEnter", function(self, link)
        if GameTooltip and GameTooltip.SetOwner and GameTooltip.SetHyperlink then
            pcall(function()
                GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
                GameTooltip:SetHyperlink(link)
                GameTooltip:Show()
            end)
        end
    end)
    view:SetScript("OnHyperlinkLeave", function()
        if GameTooltip and GameTooltip.Hide then pcall(GameTooltip.Hide, GameTooltip) end
    end)
    local button = CreateFrame("Button", nil, view)
    button:SetSize(96, 20)
    button:SetPoint("BOTTOMRIGHT", view, "BOTTOMRIGHT", -4, 4)
    button:SetText(app.L.chatViewBottom)
    button:SetScript("OnClick", function() toBottom(entry) end)
    button:Hide()
    entry.toBottom = button
    entry.view = view
    return view
end

-- One line from the client. `quiet` is the first-buffer back-fill, which never
-- counts as unread.
local function feed(entry, quiet, text, r, g, b, id)
    local view = entry.view
    if not view or entry.active ~= true then return end
    local secret = app.Capabilities.IsSecret(text)
    if not secret then
        -- The same final line can arrive twice from one source (a rebuild that
        -- replays it in the same tick): collapse it by text and line id.
        local now = type(GetTime) == "function" and GetTime() or 0
        local key = tostring(text) .. "\0" .. tostring(id)
        if entry.lastKey == key and entry.lastTime == now and not quiet then return end
        entry.lastKey, entry.lastTime = key, now
    end
    local reading = not atBottom(view)
    if not pcall(view.AddMessage, view, text, r, g, b, id) then return end
    if quiet then return end
    -- A reader scrolled into history is never moved: only the count and the
    -- button change. A hidden window counts too.
    if reading or not (entry.frame.IsShown and entry.frame:IsShown()) then
        entry.unread = (entry.unread or 0) + 1
    end
    refreshButton(entry)
end

local function backfill(entry)
    local frame = entry.frame
    if type(frame.GetNumMessages) ~= "function" or type(frame.GetMessageInfo) ~= "function" then return true end
    local ok, count = pcall(frame.GetNumMessages, frame)
    count = ok and app.Capabilities.Plain(count, "number") or 0
    for index = 1, count do
        local got, text, r, g, b, id = pcall(frame.GetMessageInfo, frame, index)
        if not got then return false end
        feed(entry, true, text, r, g, b, id)
    end
    return true
end

local function syncShown(entry)
    if not entry.view then return end
    local shown = entry.active == true and entry.frame.IsShown and entry.frame:IsShown()
    entry.view:SetShown(shown == true)
    if shown then
        entry.unread = 0
        refreshButton(entry)
    end
end

local function release(entry)
    if not entry.active and not entry.saved then return end
    entry.active = false
    local saved = entry.saved
    entry.saved = nil
    if entry.view then entry.view:Hide() end
    if entry.toBottom then entry.toBottom:Hide() end
    if saved and entry.frame then
        pcall(entry.frame.SetAlpha, entry.frame, saved.alpha)
        if type(entry.frame.EnableMouse) == "function" then pcall(entry.frame.EnableMouse, entry.frame, saved.mouse) end
        if type(entry.frame.EnableMouseWheel) == "function" then
            pcall(entry.frame.EnableMouseWheel, entry.frame, saved.wheel)
        end
    end
end

local function hookWindow(entry)
    if entry.hooked then return end
    local frame = entry.frame
    if type(hooksecurefunc) ~= "function" or type(frame.AddMessage) ~= "function" then return end
    entry.hooked = true
    hooksecurefunc(frame, "AddMessage", function(_, text, r, g, b, id)
        if module.running == true and entry.active == true then
            app:Call("chatView/message", feed, entry, false, text, r, g, b, id)
        end
    end)
    frame:HookScript("OnShow", function()
        if module.running == true then app:Call("chatView/show", syncShown, entry) end
    end)
    frame:HookScript("OnHide", function()
        if entry.view and entry.active then entry.view:Hide() end
    end)
end

local function take(entry)
    local frame = entry.frame
    if not wanted() then release(entry); publish(entry, false, "off"); return end
    if _G.COMBATLOG == frame then release(entry); publish(entry, false, "combatlog"); return end
    local other = thirdParty()
    if other then release(entry); publish(entry, false, "thirdparty"); return end
    hookWindow(entry)
    if not entry.hooked then release(entry); publish(entry, false, "nohook"); return end
    local view = buildView(entry)
    if not view then release(entry); publish(entry, false, "noview"); return end
    if not entry.active then
        view:ClearAllPoints()
        view:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
        view:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
        if type(frame.GetFont) == "function" and type(view.SetFont) == "function" then
            local ok, file, height, flags = pcall(frame.GetFont, frame)
            file = ok and app.Capabilities.Plain(file, "string") or nil
            height = ok and app.Capabilities.Plain(height, "number") or nil
            if file and height then pcall(view.SetFont, view, file, height, app.Capabilities.Plain(flags, "string") or "") end
        end
        if type(view.Clear) == "function" then pcall(view.Clear, view) end
        entry.active = true
        if not backfill(entry) then
            entry.active = false
            view:Hide()
            publish(entry, false, "backfill")
            return
        end
        entry.saved = {
            alpha = frame:GetAlpha(),
            mouse = frame.IsMouseEnabled and frame:IsMouseEnabled() or false,
            wheel = frame.IsMouseWheelEnabled and frame:IsMouseWheelEnabled() or false,
        }
        -- Native text stays alive (it keeps the buffer, resize and docking); only
        -- its picture and mouse capture are given up, and only now that the
        -- replacement holds the same lines.
        pcall(frame.SetAlpha, frame, 0)
        if frame.EnableMouse then pcall(frame.EnableMouse, frame, false) end
        if frame.EnableMouseWheel then pcall(frame.EnableMouseWheel, frame, false) end
    end
    syncShown(entry)
    publish(entry, true, nil)
end

local function attach(self)
    self.windows = self.windows or {}
    for _, name in ipairs(windowNames()) do
        local index = tonumber(name:match("^ChatFrame(%d+)$"))
        local frame = index and _G[name] or nil
        if frame and not forbidden(frame) then
            local entry = self.windows[index]
            if entry and entry.frame ~= frame then release(entry); entry = nil end
            if not entry then
                entry = { index = index, frame = frame, unread = 0 }
                self.windows[index] = entry
            end
            app:Call("chatView/take", take, entry)
        end
    end
end

module = app:RegisterComponent({ id = "chatView", label = "chatView",
    Supported = function() return _G.ChatFrame1 ~= nil end,
    Enable = function(self)
        attach(self)
        self:Listen("UPDATE_CHAT_WINDOWS", attach)
        self:Listen("UPDATE_FLOATING_CHAT_WINDOWS", attach)
        self:Listen("PLAYER_ENTERING_WORLD", attach)
    end,
    Refresh = attach,
    Disable = function(self)
        for _, entry in pairs(self.windows or {}) do
            release(entry)
            app.Ownership:Clear("chat.view" .. entry.index)
        end
    end,
})

-- One writer for the switch, shared by the settings page and `/luma chat view`.
function module:SetTakeover(value)
    value = value == true
    if not app.Store:Set("ui", "chatTakeover", value) then
        app:Print(app.L.readonly)
        return false
    end
    attach(self)
    app:Print(value and app.L.chatViewOn or app.L.chatViewOff)
    return true
end

function module:ToBottom(index)
    local entry = self.windows and self.windows[index or 1]
    if entry then toBottom(entry) end
end
