local _, app = ...

-- Shared static skin for native action buttons. It changes only the frame art
-- (icon crop, slot backing, a one-pixel Pearl edge and the two small fonts) and
-- never touches OnClick, secure attributes, paging, drag handling, cooldowns or
-- any state texture. Every member is recorded before the first write and the
-- original values are restored when the caller releases the button.
--
-- The skinnable members are deliberately explicit: icon, HotKey, Count,
-- NormalTexture, SlotBackground and SlotArt. Pushed/Checked/Highlight/Flash,
-- proc glow, item-quality border, name, autocast and cooldown widgets stay the
-- client's own feedback.
local Skin = { crop = { 0.08, 0.92, 0.08, 0.92 } }
app.ActionButtonSkin = Skin

local TRACKED = { "icon", "HotKey", "Count", "NormalTexture", "SlotBackground", "SlotArt" }
local HOTKEY_SIZE, COUNT_SIZE = 10, 12

local function object(value)
    local kind = type(value)
    return kind == "table" or kind == "userdata"
end

local function accessible(value)
    if not object(value) then return false end
    if type(value.IsForbidden) ~= "function" then return true end
    local ok, forbidden = pcall(value.IsForbidden, value)
    return ok and forbidden == false
end

local function plain(value, expected)
    return app.Capabilities.Plain(value, expected)
end

local function setFont(target, entry, size)
    if not accessible(target) or type(target.SetFont) ~= "function" then return end
    local font = entry and entry.font or app.Type:Face()
    if not font then return end
    pcall(target.SetFont, target, font, size, "OUTLINE")
end

local function fontEntry(target)
    if not accessible(target) or type(target.GetFont) ~= "function" then return end
    local ok, font, size, flags = pcall(target.GetFont, target)
    font, size, flags = ok and plain(font, "string") or nil,
        ok and plain(size, "number") or nil,
        ok and plain(flags, "string") or nil
    if not font or not size then return end
    return { font = font, size = size, flags = flags }
end

local function alphaOf(target)
    if not accessible(target) or type(target.GetAlpha) ~= "function" then return end
    local ok, alpha = pcall(target.GetAlpha, target)
    return ok and plain(alpha, "number") or nil
end

local function record(button)
    local entry = { art = {} }
    for _, key in ipairs(TRACKED) do
        local member = button[key]
        if app.Capabilities.IsSecret(member) then return nil end
        entry[key] = member
    end
    if not accessible(button.icon) or type(button.icon.GetTexCoord) ~= "function" then return nil end
    local ok, a, b, c, d, e, f, g, h = pcall(button.icon.GetTexCoord, button.icon)
    if not ok then return nil end
    local coords = { a, b, c, d, e, f, g, h }
    for index = 1, 8 do
        if not plain(coords[index], "number") then return nil end
    end
    entry.iconCoords = coords
    entry.hotkey = fontEntry(button.HotKey)
    entry.count = fontEntry(button.Count)
    for _, key in ipairs({ "NormalTexture", "SlotBackground", "SlotArt" }) do
        local member = button[key]
        local alpha = alphaOf(member)
        if alpha ~= nil then entry.art[#entry.art + 1] = { target = member, alpha = alpha } end
    end
    return entry
end

local function changed(button, entry)
    for _, key in ipairs(TRACKED) do
        if button[key] ~= entry[key] then return true end
    end
    return false
end

local function createDecoration(button)
    local skin = button.lumaActionBarDecor
    if skin then return skin end
    skin = {}
    skin.bg = button:CreateTexture(nil, "BACKGROUND", nil, -8)
    skin.bg:SetPoint("TOPLEFT", 2, -2)
    skin.bg:SetPoint("BOTTOMRIGHT", -2, 2)
    local surface = app.Theme.colors.surface
    skin.bg:SetColorTexture(surface[1], surface[2], surface[3], 0.92)
    skin.bg:Hide()
    skin.border = CreateFrame("Frame", nil, button, "BackdropTemplate")
    skin.border:SetPoint("TOPLEFT", 1, -1)
    skin.border:SetPoint("BOTTOMRIGHT", -1, 1)
    skin.border:EnableMouse(false)
    skin.border:SetBackdrop({
        edgeFile = app.Theme.white,
        edgeSize = app.Pixel:Pixels(1, skin.border),
    })
    local line = app.Theme.colors.line
    skin.border:SetBackdropBorderColor(line[1], line[2], line[3], 1)
    skin.border:Hide()
    if type(skin.border.SetFrameLevel) == "function" and type(button.GetFrameLevel) == "function" then
        local ok, level = pcall(button.GetFrameLevel, button)
        if ok and type(level) == "number" then pcall(skin.border.SetFrameLevel, skin.border, level + 5) end
    end
    button.lumaActionBarDecor = skin
    return skin
end

-- Applies the static skin to one button. Returns true when the button is
-- decorated; a missing or forbidden member simply leaves the button native.
function Skin:Apply(button)
    if not accessible(button) or type(button.CreateTexture) ~= "function" then return false end
    local existing = button.lumaActionBarSkin
    if existing and not changed(button, existing) then return true end
    if existing then self:Restore(button) end
    local entry = record(button)
    if not entry then return false end
    local skin = createDecoration(button)
    button.lumaActionBarSkin = entry
    pcall(button.icon.SetTexCoord, button.icon,
        self.crop[1], self.crop[2], self.crop[3], self.crop[4])
    setFont(entry.hotkey and entry.hotkey.target or button.HotKey,
        entry.hotkey, HOTKEY_SIZE)
    setFont(entry.count and entry.count.target or button.Count,
        entry.count, COUNT_SIZE)
    for _, art in ipairs(entry.art) do
        pcall(art.target.SetAlpha, art.target, 0)
    end
    skin.bg:Show()
    skin.border:Show()
    return true
end

function Skin:Restore(button)
    local entry = button and button.lumaActionBarSkin
    if not entry then return true end
    local skin = button.lumaActionBarDecor
    local restored = true
    if entry then
        if entry.icon and type(entry.icon.SetTexCoord) == "function" then
            local coords = entry.iconCoords
            local ok = pcall(entry.icon.SetTexCoord, entry.icon,
                coords[1], coords[2], coords[3], coords[4],
                coords[5], coords[6], coords[7], coords[8])
            restored = restored and ok
        end
        if entry.hotkey then
            local target = entry.hotkey.target or entry.HotKey
            local ok = pcall(target.SetFont, target, entry.hotkey.font,
                entry.hotkey.size, entry.hotkey.flags)
            restored = restored and ok
        end
        if entry.count then
            local target = entry.count.target or entry.Count
            local ok = pcall(target.SetFont, target, entry.count.font,
                entry.count.size, entry.count.flags)
            restored = restored and ok
        end
        for _, art in ipairs(entry.art) do
            local ok = pcall(art.target.SetAlpha, art.target, art.alpha)
            restored = restored and ok
        end
    end
    if skin and skin.bg then pcall(skin.bg.Hide, skin.bg) end
    if skin and skin.border then pcall(skin.border.Hide, skin.border) end
    button.lumaActionBarSkin = nil
    return restored
end

return Skin
