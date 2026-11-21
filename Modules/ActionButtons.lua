local _, app = ...

-- Single-bar button sample (VIS-09). It only decorates the main bar's own
-- ActionButtons: icon crop, a one-pixel edge, slot backing and HotKey/Count
-- fonts. It never replaces OnClick, secure attributes, paging, drag handling or
-- the button geometry, and every member it touches is recorded first.
--
-- What is deliberately left to the client:
--   PushedTexture, CheckedTexture, HighlightTexture, Flash, NewActionTexture,
--   SpellHighlightTexture (proc glow), Border (item quality), Name,
--   AutoCastOverlay, cooldown, lossOfControlCooldown, chargeCooldown.
-- Those are the state feedback of the real button; the sample must not paint
-- over them. Only the static frame art (NormalTexture, SlotBackground, SlotArt)
-- is replaced by our own backing and edge.
--
-- Native structure baseline (12.1.5 UI source): ActionButtonTemplate is a
-- CheckButton with icon/IconMask/SlotBackground/SlotArt, NormalTexture,
-- PushedTexture, HighlightTexture, CheckedTexture, TextOverlayContainer with
-- HotKey/Count, cooldown/chargeCooldown and spell highlight. The bar carries its
-- buttons in `MainActionBar.actionButtons`; the named globals ActionButton1..12
-- are only a fallback. No draw order, anchor, attribute or click script is
-- written here.

local BAR = "MainActionBar"
local MAX_BUTTONS = 12
local JOB = "actionButtons/apply"
local ICON_CROP = { 0.08, 0.92, 0.08, 0.92 }
local HOTKEY_SIZE, COUNT_SIZE = 10, 12
local component
-- Hooks are installed once per button for the session; they only act while the
-- component is running, so a stopped sample can never keep restyling a bar.
local hooked = {}

local function isObject(value)
    local kind = type(value)
    return kind == "table" or kind == "userdata"
end

local function plain(value, expected)
    return app.Capabilities.Plain(value, expected)
end

-- Explicit list: the bar's own array first, the classic named globals second.
-- No recursion into child frames and no guessed fields.
local function buttonList()
    local list, seen = {}, {}
    local bar = _G[BAR]
    local pool = isObject(bar) and bar.actionButtons
    if type(pool) == "table" then
        for index = 1, MAX_BUTTONS do
            local button = pool[index]
            if isObject(button) and not seen[button] then
                seen[button] = true
                list[#list + 1] = button
            end
        end
    end
    if #list == 0 then
        for index = 1, MAX_BUTTONS do
            local button = _G["ActionButton" .. index]
            if isObject(button) and not seen[button] then
                seen[button] = true
                list[#list + 1] = button
            end
        end
    end
    return list
end

local function skinOf(button)
    local skin = button.lumaActionSkin
    if skin then return skin end
    skin = {}
    local bg = button:CreateTexture(nil, "BACKGROUND", nil, -8)
    bg:SetPoint("TOPLEFT", 2, -2)
    bg:SetPoint("BOTTOMRIGHT", -2, 2)
    local surface = app.Theme.colors.surface
    bg:SetColorTexture(surface[1], surface[2], surface[3], 0.92)
    skin.bg = bg
    local border = CreateFrame("Frame", nil, button, "BackdropTemplate")
    border:SetPoint("TOPLEFT", 1, -1)
    border:SetPoint("BOTTOMRIGHT", -1, 1)
    border:EnableMouse(false)
    border:SetBackdrop({ edgeFile = app.Theme.white, edgeSize = app.Pixel:Pixels(1) })
    local line = app.Theme.colors.line
    border:SetBackdropBorderColor(line[1], line[2], line[3], 1)
    skin.border = border
    skin.hoverMix = 0
    button.lumaActionSkin = skin
    return skin
end

local function paintHover(button, mix)
    local skin = button.lumaActionSkin
    if not skin or not skin.border then return end
    skin.hoverMix = mix
    local line, accent = app.Theme.colors.line, app.Theme:Accent()
    skin.border:SetBackdropBorderColor(
        line[1] + (accent[1] - line[1]) * mix,
        line[2] + (accent[2] - line[2]) * mix,
        line[3] + (accent[3] - line[3]) * mix, 1)
end

-- A light accent fade on our own edge only; no native geometry or state art is
-- animated, and the completion callback is replaced like every other channel.
local function hoverTo(button, target)
    if not component.running then return end
    local skin = button.lumaActionSkin
    if not skin then return end
    app.Transitions:Animate(button, "hover", {
        from = skin.hoverMix or 0,
        to = target,
        duration = 0.09,
        apply = function(value) paintHover(button, value) end,
    })
end

local function installHooks(button)
    if hooked[button] then return end
    hooked[button] = true
    button:HookScript("OnEnter", function()
        if not component.running then return end
        hoverTo(button, 1)
    end)
    button:HookScript("OnLeave", function()
        if not component.running then return end
        hoverTo(button, 0)
    end)
    button:HookScript("OnHide", function()
        if app.Transitions then app.Transitions:Cancel(button, "hover") end
    end)
end

local function snapshotFont(target)
    if not target or type(target.GetFont) ~= "function" then return nil end
    local font, size, flags = target:GetFont()
    return { font = plain(font, "string"), size = plain(size, "number"), flags = flags }
end

local function snapshotAlpha(target)
    if not target or type(target.GetAlpha) ~= "function" then return nil end
    return plain(target:GetAlpha(), "number")
end

local function record(originals, button)
    if originals[button] then return originals[button] end
    local entry = { art = {} }
    if type(button.icon) ~= "nil" and type(button.icon.GetTexCoord) == "function" then
        local coords = { button.icon:GetTexCoord() }
        if #coords == 8 then entry.icon = coords end
    end
    entry.hotkey = snapshotFont(button.HotKey)
    entry.count = snapshotFont(button.Count)
    for _, key in ipairs({ "NormalTexture", "SlotBackground", "SlotArt" }) do
        local member = button[key]
        local alpha = snapshotAlpha(member)
        if alpha ~= nil then entry.art[#entry.art + 1] = { member = member, alpha = alpha } end
    end
    originals[button] = entry
    return entry
end

local function applyFont(target, saved, size)
    if not target or type(target.SetFont) ~= "function" then return end
    local font = saved and saved.font or (GameFontNormal and GameFontNormal:GetFont()) or "Fonts\\FRIZQT__.TTF"
    target:SetFont(font, size, "OUTLINE")
end

-- Applies the sample to one button. Every member is probed; a missing member is
-- skipped instead of failing the whole bar.
local function skinButton(self, button)
    if not isObject(button) or type(button.CreateTexture) ~= "function" then return false end
    if not isObject(button.icon) then return false end
    local entry = record(self.originals, button)
    local skin = skinOf(button)
    installHooks(button)
    if entry.icon then
        button.icon:SetTexCoord(ICON_CROP[1], ICON_CROP[2], ICON_CROP[3], ICON_CROP[4])
    end
    applyFont(button.HotKey, entry.hotkey, HOTKEY_SIZE)
    applyFont(button.Count, entry.count, COUNT_SIZE)
    for _, art in ipairs(entry.art) do
        art.member:SetAlpha(0)
    end
    -- A refresh keeps the current hover mix instead of dropping a visible hover.
    paintHover(button, skin.hoverMix or 0)
    skin.border:Show()
    skin.bg:Show()
    return true
end

local function restoreAll(self)
    for button, entry in pairs(self.originals or {}) do
        local skin = button.lumaActionSkin
        if app.Transitions then app.Transitions:Cancel(button, "hover") end
        if entry.icon then
            button.icon:SetTexCoord(entry.icon[1], entry.icon[2], entry.icon[3], entry.icon[4],
                entry.icon[5], entry.icon[6], entry.icon[7], entry.icon[8])
        end
        if entry.hotkey and isObject(button.HotKey) then
            button.HotKey:SetFont(entry.hotkey.font or "Fonts\\FRIZQT__.TTF",
                entry.hotkey.size or 10, entry.hotkey.flags or "")
        end
        if entry.count and isObject(button.Count) then
            button.Count:SetFont(entry.count.font or "Fonts\\FRIZQT__.TTF",
                entry.count.size or 12, entry.count.flags or "")
        end
        for _, art in ipairs(entry.art) do art.member:SetAlpha(art.alpha) end
        if skin then
            skin.hoverMix = 0
            if skin.bg then skin.bg:Hide() end
            if skin.border then skin.border:Hide() end
        end
    end
    self.originals = {}
end

local function applyAll(self)
    self.originals = self.originals or {}
    local total, skinned = 0, 0
    for _, button in ipairs(buttonList()) do
        total = total + 1
        if skinButton(self, button) then skinned = skinned + 1 end
    end
    self.skinned, self.total = skinned, total
end

local function sync()
    if component.running then applyAll(component) else restoreAll(component) end
end

component = app:RegisterComponent({ id = "actionButtons", label = "actionButtons", defaultEnabled = false,
    Supported = function()
        local bar = _G[BAR]
        if not isObject(bar) then return false end
        for _, button in ipairs(buttonList()) do
            if isObject(button.icon) then return true end
        end
        return false
    end,
    Enable = function(self)
        -- Everything touches protected buttons/regions: one queue key, latest
        -- intent wins, and nothing happens during combat.
        app.Queue:Run(JOB, sync)
    end,
    Refresh = function(self)
        app.Queue:Run(JOB, sync)
    end,
    Disable = function(self)
        app.Queue:Run(JOB, sync)
    end,
})

-- Diagnostics for `/luma status`: how many buttons of the one sample bar were
-- actually skinned, and that the sample is a preview rather than a takeover.
function component:Describe()
    if not self.running then return nil end
    return string.format("actionButtons: %d/%d (%s)", self.skinned or 0, self.total or 0, app.L.actionButtons)
end
