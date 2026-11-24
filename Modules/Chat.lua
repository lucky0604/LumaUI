local _, app = ...
local module
local refreshEntry

-- Matches CHAT_FRAME_FADE_TIME: the client uses this beat when it fades its
-- own chat support in and out, so LumaUI's backing moves at the same speed.
local FADE = 0.15

local nativeSuffixes = {
    "Background", "TopLeftTexture", "TopRightTexture", "BottomLeftTexture", "BottomRightTexture",
    "LeftTexture", "RightTexture", "TopTexture", "BottomTexture",
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

local function editBoxFor(frame)
    if frame.editBox then return frame.editBox end
    local name = frame.GetName and frame:GetName()
    return name and _G[name .. "EditBox"] or nil
end

-- Every frame the client has registered: the numbered windows plus floating,
-- temporary and whisper windows, which get names beyond NUM_CHAT_WINDOWS.
-- Registration is the client's own list, so a window appears here as soon as
-- it exists instead of waiting for a poll.
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

-- Screen rectangle of a frame, used to measure the gap above the message area.
-- A frame that reports no rect simply lifts nothing.
local function screenRect(frame)
    if not frame or type(frame.GetRect) ~= "function" then return nil end
    local ok, left, bottom, width, height = pcall(frame.GetRect, frame)
    left = ok and app.Capabilities.Plain(left, "number") or nil
    bottom = ok and app.Capabilities.Plain(bottom, "number") or nil
    width = ok and app.Capabilities.Plain(width, "number") or nil
    height = ok and app.Capabilities.Plain(height, "number") or nil
    if not left or not bottom or not width or not height then return nil end
    return left, bottom, width, height
end

-- The tab row sits above the message area, so a plate anchored to the native
-- background stops one row short and leaves the tabs floating on their own rule.
-- Lifting the top edge to the tab's bottom edge makes the tab row and the
-- conversation one surface; the lift is capped so a misreported tab cannot drag
-- the plate over the whole window.
local MAX_TAB_LIFT = 40

local function tabLift(entry)
    local frame, tab = entry.frame, entry.tab
    if not frame or not tab then return 0 end
    if type(tab.IsShown) == "function" then
        local okShown, shown = pcall(tab.IsShown, tab)
        if okShown and shown ~= true then return 0 end
    end
    local _, tabBottom = screenRect(tab)
    local _, frameBottom, _, frameHeight = screenRect(frame)
    if not tabBottom or not frameBottom or not frameHeight then return 0 end
    local gap = tabBottom - (frameBottom + frameHeight)
    if gap <= 0 then return 0 end
    local okScale, scale = pcall(frame.GetEffectiveScale, frame)
    scale = okScale and app.Capabilities.Plain(scale, "number") or nil
    if not scale or scale <= 0 then return 0 end
    -- One extra unit so the tab's own rule lands on the plate edge instead of
    -- leaving a hairline of background between them.
    return math.min(MAX_TAB_LIFT, gap / scale + 1)
end

local function nativeRegions(entry)
    local regions = entry.nativeRegions
    if regions then return regions end
    regions = {}
    local name = entry.frame.GetName and entry.frame:GetName()
    if name then
        for _, suffix in ipairs(nativeSuffixes) do
            local region = _G[name .. suffix]
            if region then regions[#regions + 1] = region end
        end
    end
    entry.nativeRegions = regions
    return regions
end

local restoreNative

local function hideNative(entry)
    entry.nativeShown = entry.nativeShown or {}
    for _, region in ipairs(nativeRegions(entry)) do
        if entry.nativeShown[region] == nil then entry.nativeShown[region] = region:IsShown() end
        if not pcall(region.Hide, region) then
            -- Someone else refuses these writes (a protected region or another
            -- addon that owns this frame's art): give the window back instead
            -- of fighting it every paint.
            restoreNative(entry)
            entry.conflict = true
            return false
        end
    end
    return true
end

restoreNative = function(entry)
    for region, shown in pairs(entry.nativeShown or {}) do
        pcall(function() if shown then region:Show() else region:Hide() end end)
    end
    entry.nativeShown = nil
end

local function backgroundFor(entry, key)
    local background = entry[key]
    if not background then
        -- UIParent keeps these decorations independent from the chat frame's own
        -- locked/docked state; they never intercept mouse input or chat text.
        background = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
        background:SetFrameStrata("BACKGROUND")
        background:EnableMouse(false)
        entry[key] = background
    end
    return background
end

local function frameFont(frame)
    if type(frame.GetFont) ~= "function" then return nil end
    local ok, file, height, flags = pcall(frame.GetFont, frame)
    file = ok and app.Capabilities.Plain(file, "string") or nil
    height = ok and app.Capabilities.Plain(height, "number") or nil
    if not file or not height then return nil end
    return { file = file, height = height, flags = app.Capabilities.Plain(flags, "string") or "" }
end

-- The line the player types should read in the same face and size as the
-- messages above it, and one line of chat gets the same leading the messages
-- use. Font size itself stays with the client's own chat menu (FCF_SetChatWindowFontSize):
-- this only re-syncs the input box whenever that setting moves, and every
-- original value is captured before the first write so disable restores it.
local function style(entry)
    local frame = entry.frame
    if not frame then return end
    local style = entry.style
    if not style then style = {}; entry.style = style end
    local font = frameFont(frame)
    if not font then return end
    local box = entry.editBox
    if box and type(box.SetFont) == "function" then
        local current
        if type(box.GetFont) == "function" then
            local ok, file, height, flags = pcall(box.GetFont, box)
            if ok then
                current = {
                    file = app.Capabilities.Plain(file, "string"),
                    height = app.Capabilities.Plain(height, "number"),
                    flags = app.Capabilities.Plain(flags, "string") or "",
                }
            end
        end
        if current and current.file and current.height
            and (current.file ~= font.file or current.height ~= font.height or current.flags ~= font.flags) then
            if not style.boxFont then style.boxFont = current end
            pcall(box.SetFont, box, font.file, font.height, font.flags)
        end
    end
    if type(frame.GetSpacing) == "function" and type(frame.SetSpacing) == "function" then
        local ok, spacing = pcall(frame.GetSpacing, frame)
        spacing = ok and app.Capabilities.Plain(spacing, "number") or nil
        if spacing then
            -- The native scrolling frame places each line after the preceding
            -- line's bounds, then adds this spacing. It is an extra gap.
            local target = math.max(1, math.floor(font.height / 6))
            if spacing ~= target then
                if not style.spacing then style.spacing = spacing end
                pcall(frame.SetSpacing, frame, target)
            end
        end
    end
end

local function restoreStyle(entry)
    local style = entry.style
    entry.style = nil
    if not style then return end
    local frame = entry.frame
    if style.spacing and frame and type(frame.SetSpacing) == "function" then
        pcall(frame.SetSpacing, frame, style.spacing)
    end
    local box = entry.editBox
    if style.boxFont and box and type(box.SetFont) == "function" then
        pcall(box.SetFont, box, style.boxFont.file, style.boxFont.height, style.boxFont.flags or "")
    end
end

-- Two support grades: quiet while reading, stronger while the input has focus.
-- Only LumaUI's own backing moves; native text, scroll and input never fade.
local function fadeEdit(entry, to)
    local background = entry.editBackground
    if not background then return end
    local function done()
        entry.editFading = false
        if not entry.focused then
            background:SetAlpha(0)
            background:Hide()
        end
    end
    if to > 0 then background:Show() end
    local task = app.Transitions:Animate(entry, "focus", {
        from = background:GetAlpha(), to = to, duration = FADE,
        apply = function(value) background:SetAlpha(value) end,
        onDone = done,
    })
    entry.editFading = task ~= nil
end

local function syncEdit(entry)
    local background = entry.editBackground
    if not background or entry.editFading then return end
    local focused = entry.focused == true and entry.frame ~= nil and entry.frame:IsVisible()
    if focused then
        background:Show()
        background:SetAlpha(1)
    else
        background:SetAlpha(0)
        background:Hide()
    end
end

local function setFocus(entry, active)
    entry.focused = active == true
    if module.running ~= true then return end
    local background = entry.editBackground
    if not background then return end
    if not (entry.frame and entry.frame:IsVisible()) then
        -- Nothing to fade towards while the window is hidden; settle so no
        -- task outlives the frame it decorates.
        app.Transitions:Cancel(entry, "focus")
        entry.editFading = false
        background:SetAlpha(0)
        background:Hide()
        return
    end
    fadeEdit(entry, entry.focused and 1 or 0)
end

-- Focus is the reliable signal: with the "im" chat style the box stays on
-- screen while deactivated, and a component enabled mid-typing never saw the
-- focus event. HasFocus answers for the current moment.
local function refreshFocus(entry)
    local box = entry.editBox
    if box and type(box.HasFocus) == "function" then
        local ok, has = pcall(box.HasFocus, box)
        if ok then entry.focused = has == true end
    end
end

local function paint(entry)
    local frame = entry.frame
    if not frame or forbidden(frame) then return end
    if not hideNative(entry) then
        -- The window kept its native art: show none of ours over it.
        if entry.background then entry.background:Hide() end
        if entry.editBackground then
            app.Transitions:Cancel(entry, "focus")
            entry.editFading = false
            entry.editBackground:SetAlpha(0)
            entry.editBackground:Hide()
        end
        return
    end
    entry.conflict = nil
    style(entry)
    refreshFocus(entry)
    local background = backgroundFor(entry, "background")
    background:ClearAllPoints()
    -- The native ChatFrame background already has the correct bounds below the
    -- tab row and above the edit box. The plate keeps those edges and adds the
    -- tab row on top, so the labels sit on the same surface as the messages
    -- instead of hovering above it with a gap.
    local native = frame.Background
    local lift = tabLift(entry)
    entry.tabLift = lift
    if native then
        background:SetPoint("TOPLEFT", native, "TOPLEFT", -2, 2 + lift)
        background:SetPoint("BOTTOMRIGHT", native, "BOTTOMRIGHT", 2, -2)
    else
        background:SetPoint("TOPLEFT", frame, "TOPLEFT", -2, 3 + lift)
        background:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 2, -6)
    end
    app.Surface:Plate(background, "chat")
    background:SetShown(frame:IsVisible())

    local box = entry.editBox
    if box then
        local editBackground = backgroundFor(entry, "editBackground")
        editBackground:ClearAllPoints()
        -- One padding rule on every side, so the input reads as a field inside
        -- the conversation rather than a strip glued under it. The inset stays
        -- smaller than the message plate's own edge so the two surfaces read as
        -- one block. The text inset itself stays with ChatEdit_UpdateHeader,
        -- which owns the channel header.
        editBackground:SetPoint("TOPLEFT", box, "TOPLEFT", -4, 4)
        editBackground:SetPoint("BOTTOMRIGHT", box, "BOTTOMRIGHT", 4, -4)
        app.Surface:Plate(editBackground, "chatActive")
        syncEdit(entry)
    end
end

local function hook(entry, box)
    local frame = entry.frame
    if not entry.windowHooked then
        frame:HookScript("OnShow", function()
            if module.running and entry.attached then app:Call("chat/window-show", refreshEntry, entry) end
        end)
        frame:HookScript("OnHide", function()
            if not entry.attached then return end
            if entry.background then entry.background:Hide() end
            if entry.editBackground then
                app.Transitions:Cancel(entry, "focus")
                entry.editFading = false
                entry.editBackground:SetAlpha(0)
                entry.editBackground:Hide()
            end
        end)
        entry.windowHooked = true
    end
    entry.editHooked = entry.editHooked or {}
    if box and not entry.editHooked[box] then
        -- Focus, not visibility: with the "im" chat style the box stays on
        -- screen while deactivated, and only focus proves the player is typing.
        box:HookScript("OnEditFocusGained", function()
            if module.running and entry.attached and entry.editBox == box then
                app:Call("chat/focus", setFocus, entry, true)
            end
        end)
        box:HookScript("OnEditFocusLost", function()
            if module.running and entry.attached and entry.editBox == box then
                app:Call("chat/blur", setFocus, entry, false)
            end
        end)
        entry.editHooked[box] = true
    end
end

refreshEntry = function(entry)
    hook(entry, entry.editBox)
    paint(entry)
end

local function detachEntry(entry)
    if not entry then return end
    entry.attached = false
    app.Transitions:Cancel(entry, "focus")
    entry.editFading = nil
    entry.focused = nil
    restoreStyle(entry)
    restoreNative(entry)
    if entry.background then entry.background:Hide() end
    if entry.editBackground then
        entry.editBackground:SetAlpha(0)
        entry.editBackground:Hide()
    end
end

local function attach(self)
    self.windows = self.windows or {}
    local live = {}
    for _, name in ipairs(windowNames()) do
        local index = tonumber(name:match("^ChatFrame(%d+)$"))
        local frame = index and _G[name] or nil
        if frame and not forbidden(frame) then
            local entry = self.windows[index]
            if entry and entry.frame ~= frame then
                detachEntry(entry)
                entry = nil
            end
            if not entry then
                entry = { frame = frame }
                self.windows[index] = entry
            end
            -- The tab row is part of the same surface: its position decides how
            -- far the plate reaches above the message area. A window without a
            -- tab (floating, temporary) simply keeps the native background edge.
            entry.tab = _G[name .. "Tab"]
            local box = editBoxFor(frame)
            if entry.editBox ~= box then
                app.Transitions:Cancel(entry, "focus")
                entry.editFading, entry.focused = nil, nil
                if entry.editBackground then
                    entry.editBackground:SetAlpha(0)
                    entry.editBackground:Hide()
                end
                restoreStyle(entry)
                entry.editBox = box
            end
            entry.attached = true
            refreshEntry(entry)
            live[index] = true
        end
    end
    for index, entry in pairs(self.windows) do
        if not live[index] then
            detachEntry(entry)
            self.windows[index] = nil
        end
    end
end

module = app:RegisterComponent({ id = "chat", label = "chat",
    Enable = function(self)
        attach(self)
        self:Listen("UPDATE_CHAT_WINDOWS", attach)
        self:Listen("UPDATE_FLOATING_CHAT_WINDOWS", attach)
        self:Listen("PLAYER_ENTERING_WORLD", attach)
    end,
    Refresh = attach,
    Disable = function(self)
        for _, entry in pairs(self.windows or {}) do detachEntry(entry) end
    end,
})
