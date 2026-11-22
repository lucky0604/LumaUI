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
local TRACKED_MEMBERS = { "icon", "HotKey", "Count", "NormalTexture", "SlotBackground", "SlotArt" }
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

local function accessible(object)
    if not isObject(object) then return false end
    if type(object.IsForbidden) ~= "function" then return true end
    local ok, forbidden = pcall(object.IsForbidden, object)
    return ok and forbidden == false
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
    if not skin then
        skin = { hoverMix = 0 }
        button.lumaActionSkin = skin
    end
    if not skin.bg then
        local bg = button:CreateTexture(nil, "BACKGROUND", nil, -8)
        bg:Hide()
        skin.bg = bg
    end
    skin.bg:ClearAllPoints()
    skin.bg:SetPoint("TOPLEFT", 2, -2)
    skin.bg:SetPoint("BOTTOMRIGHT", -2, 2)
    local surface = app.Theme.colors.surface
    skin.bg:SetColorTexture(surface[1], surface[2], surface[3], 0.92)
    if not skin.border then
        local border = CreateFrame("Frame", nil, button, "BackdropTemplate")
        border:Hide()
        skin.border = border
    end
    skin.border:ClearAllPoints()
    skin.border:SetPoint("TOPLEFT", 1, -1)
    skin.border:SetPoint("BOTTOMRIGHT", -1, 1)
    skin.border:EnableMouse(false)
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
    if not component.running or component.failed then return end
    if not component.originals or not component.originals[button] then return end
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
    if not accessible(target) or type(target.GetFont) ~= "function" or type(target.SetFont) ~= "function" then return nil end
    local font, size, flags = target:GetFont()
    if app.Capabilities.IsSecret(flags) then return nil end
    if flags == nil then flags = "" end
    font, size, flags = plain(font, "string"), plain(size, "number"), plain(flags, "string")
    if not font or not size or not flags then return nil end
    return { target = target, font = font, size = size, flags = flags }
end

local function snapshotAlpha(target)
    if not accessible(target) or type(target.GetAlpha) ~= "function" or type(target.SetAlpha) ~= "function" then return nil end
    return plain(target:GetAlpha(), "number")
end

local function record(originals, button)
    if originals[button] then return originals[button] end
    local entry = { art = {}, members = {} }
    for _, key in ipairs(TRACKED_MEMBERS) do
        local member = button[key]
        if app.Capabilities.IsSecret(member) then error("restricted button member") end
        entry.members[key] = member
    end
    if accessible(button.icon) and type(button.icon.GetTexCoord) == "function"
        and type(button.icon.SetTexCoord) == "function" then
        local coords = { button.icon:GetTexCoord() }
        if #coords == 8 then
            local valid = true
            for index = 1, 8 do
                if not plain(coords[index], "number") then valid = false end
            end
            if valid then entry.icon = { target = button.icon, coords = coords } end
        end
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

local function membersChanged(button, entry)
    if not accessible(button) then return false end
    for _, key in ipairs(TRACKED_MEMBERS) do
        local member = button[key]
        if app.Capabilities.IsSecret(member) then error("restricted button member") end
        if entry.members[key] ~= member then return true end
    end
    return false
end

local function applyFont(target, saved, size)
    if not target or type(target.SetFont) ~= "function" then return end
    local font = saved and saved.font or (GameFontNormal and GameFontNormal:GetFont()) or "Fonts\\FRIZQT__.TTF"
    target:SetFont(font, size, "OUTLINE")
end

-- Applies the sample to one button. Every member is probed; a missing member is
-- skipped instead of failing the whole bar.
local function skinButton(self, button)
    if not accessible(button) or type(button.CreateTexture) ~= "function" or type(button.HookScript) ~= "function" then return false end
    if not accessible(button.icon) then return false end
    local entry = record(self.originals, button)
    if not entry.icon then
        self.originals[button] = nil
        return false
    end
    local skin = skinOf(button)
    skin.border:SetBackdrop({ edgeFile = app.Theme.white, edgeSize = app.Pixel:Pixels(1, skin.border) })
    installHooks(button)
    if entry.icon then
        entry.icon.target:SetTexCoord(ICON_CROP[1], ICON_CROP[2], ICON_CROP[3], ICON_CROP[4])
    end
    if entry.hotkey then applyFont(entry.hotkey.target, entry.hotkey, HOTKEY_SIZE) end
    if entry.count then applyFont(entry.count.target, entry.count, COUNT_SIZE) end
    for _, art in ipairs(entry.art) do
        art.member:SetAlpha(0)
    end
    -- A refresh keeps the current hover mix instead of dropping a visible hover.
    paintHover(button, skin.hoverMix or 0)
    skin.border:Show()
    skin.bg:Show()
    return true
end

local function restoreButton(button, entry)
    local skin = button.lumaActionSkin
    if app.Transitions then app.Transitions:Cancel(button, "hover") end
    local restored = true
    local function restore(target, method, ...)
        local args = { ... }
        local ok = accessible(target) and pcall(function() target[method](target, unpack(args)) end)
        if not ok then restored = false end
    end
    if entry.icon then
        local coords = entry.icon.coords
        restore(entry.icon.target, "SetTexCoord", coords[1], coords[2], coords[3], coords[4],
            coords[5], coords[6], coords[7], coords[8])
    end
    if entry.hotkey then
        restore(entry.hotkey.target, "SetFont", entry.hotkey.font, entry.hotkey.size, entry.hotkey.flags)
    end
    if entry.count then
        restore(entry.count.target, "SetFont", entry.count.font, entry.count.size, entry.count.flags)
    end
    for _, art in ipairs(entry.art) do restore(art.member, "SetAlpha", art.alpha) end
    if skin then
        skin.hoverMix = 0
        if skin.bg then restore(skin.bg, "Hide") end
        if skin.border then restore(skin.border, "Hide") end
    end
    return restored
end

local function restoreSafely(button, entry)
    local ok, restored = pcall(restoreButton, button, entry)
    return ok and restored == true
end

local function restoreAll(self)
    for button, entry in pairs(self.originals or {}) do
        if restoreSafely(button, entry) then
            self.originals[button] = nil
        else
            app:Report("actionButtons/restore", "Could not restore an action button")
        end
    end
end

local function applyAll(self)
    self.originals = self.originals or {}
    local total, skinned, seen = 0, 0, {}
    local buttons = buttonList()
    for _, button in ipairs(buttons) do seen[button] = true end
    for button, entry in pairs(self.originals) do
        if not seen[button] then
            if restoreSafely(button, entry) then
                self.originals[button] = nil
            else
                app:Report("actionButtons/restore", "Could not restore an action button")
                restoreAll(self)
                self.failed = true
                self.skinned, self.total = 0, #buttons
                return
            end
        end
    end
    for _, button in ipairs(buttons) do
        total = total + 1
        local entry = self.originals[button]
        local checked, changed = true, false
        if entry then checked, changed = pcall(membersChanged, button, entry) end
        if not checked then
            app:Report("actionButtons/apply", "Could not inspect a button member")
            restoreAll(self)
            self.failed = true
            self.skinned, self.total = 0, total
            return
        end
        if entry and changed then
            if not restoreSafely(button, entry) then
                app:Report("actionButtons/restore", "Could not restore a replaced button member")
                restoreAll(self)
                self.failed = true
                self.skinned, self.total = 0, total
                return
            end
            self.originals[button] = nil
            entry = nil
        end
        local ok, result = pcall(skinButton, self, button)
        if not ok then
            app:Report("actionButtons/apply", result)
            restoreAll(self)
            self.failed = true
            self.skinned, self.total = 0, total
            return
        end
        if not result and entry then
            -- A previously decorated button became unavailable. Restore what
            -- is still accessible and hide our overlay instead of leaving a
            -- partial skin over the client's state art.
            app:Report("actionButtons/apply", "A skinned button became inaccessible")
            restoreAll(self)
            self.failed = true
            self.skinned, self.total = 0, total
            return
        end
        if result then skinned = skinned + 1 end
    end
    self.skinned, self.total = skinned, total
end

local function sync()
    if component.running and not component.failed then
        applyAll(component)
    elseif not component.running then
        restoreAll(component)
        component.failed = nil
    end
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
        self:Listen("EDIT_MODE_LAYOUTS_UPDATED", function()
            app.Queue:Run(JOB, sync)
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

-- Diagnostics for `/luma status`: how many buttons of the one sample bar were
-- actually skinned, and that the sample is a preview rather than a takeover.
function component:Describe()
    if not self.running then return nil end
    if self.failed then return "actionButtons: failed (see session errors)" end
    return string.format("actionButtons: %d/%d (%s)", self.skinned or 0, self.total or 0, app.L.actionButtons)
end
