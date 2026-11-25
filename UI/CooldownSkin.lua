local _, app = ...

-- The Pearl skin for the client's cooldown viewer items (Cooldown Manager).
-- Every member here is one the client itself exposes on the item frame:
-- `Icon` (ARTWORK texture), `Cooldown` (a Cooldown frame with
-- SetCountdownFont) and `ChargeCount.Current` (the charge FontString). The
-- template's own `cooldownFont` key is the exact font to put back, so a build
-- that does not expose it is left entirely native instead of guessed at.
--
-- What the skin writes: the icon's texture coordinates (crop), one dark liner
-- behind the icon, a one-physical-pixel edge around the button, the cooldown
-- countdown font object and the charge font. Timers, swipe, charges, glow,
-- availability, icon variants, tooltips, clicks and the secure cooldown calls
-- stay the client's. Every value is recorded before the first write; a frame
-- whose write fails is restored immediately and stays native.
local Skin = { crop = { 0.08, 0.92, 0.08, 0.92 } }
app.CooldownSkin = Skin

local TIMER_FONT_KEY = "iconTimer"
local CHARGE_SIZE = 11
local LINER_INSET = 3
local EDGE_INSET = 1

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

local function iconOf(item)
    local icon = item.Icon
    if object(icon) and type(icon.GetTexCoord) == "function"
        and type(icon.SetTexCoord) == "function" then return icon end
    icon = item.icon
    if object(icon) and type(icon.GetTexCoord) == "function"
        and type(icon.SetTexCoord) == "function" then return icon end
end

local function chargeFontOf(item)
    local charge = item.ChargeCount
    if not object(charge) then return nil end
    local current = charge.Current
    if object(current) and type(current.GetFont) == "function"
        and type(current.SetFont) == "function" then return current end
end

-- The countdown font is set by name (a client font object), and the template's
-- own key is the only exact record of what was there before.
local function timerFontOf(item)
    local cooldown = item.Cooldown
    if not object(cooldown) or type(cooldown.SetCountdownFont) ~= "function" then return nil, nil end
    local original = plain(item.cooldownFont, "string")
    if not original or original == "" then return cooldown, nil end
    return cooldown, original
end

local function fontEntry(target)
    if not target or type(target.GetFont) ~= "function" then return nil end
    local ok, font, size, flags = pcall(target.GetFont, target)
    font = ok and plain(font, "string") or nil
    size = ok and plain(size, "number") or nil
    if not font or not size then return nil end
    return { font = font, size = size, flags = plain(flags, "string") or "" }
end

-- One dark liner and one hairline edge per button, created once and reused for
-- the life of the pooled button, exactly like the action-button sample. The
-- liner sits outside the icon so the crop reads as a slot, not a floating tile.
local function decorFor(item)
    local decor = item.lumaCooldownDecor
    if decor then return decor end
    if type(item.CreateTexture) ~= "function" then return nil end
    decor = {}
    local surface = app.Theme.colors.surface
    decor.bg = item:CreateTexture(nil, "BACKGROUND", nil, -8)
    decor.bg:SetPoint("TOPLEFT", item, "TOPLEFT", -LINER_INSET, LINER_INSET)
    decor.bg:SetPoint("BOTTOMRIGHT", item, "BOTTOMRIGHT", LINER_INSET, -LINER_INSET)
    decor.bg:SetColorTexture(surface[1], surface[2], surface[3], 0.9)
    decor.bg:Hide()
    if type(CreateFrame) == "function" then
        decor.border = CreateFrame("Frame", nil, item, "BackdropTemplate")
        decor.border:SetPoint("TOPLEFT", item, "TOPLEFT", -EDGE_INSET, EDGE_INSET)
        decor.border:SetPoint("BOTTOMRIGHT", item, "BOTTOMRIGHT", EDGE_INSET, -EDGE_INSET)
        decor.border:EnableMouse(false)
        decor.border:SetBackdrop({
            edgeFile = app.Theme.white,
            edgeSize = app.Pixel:Pixels(1, decor.border),
        })
        local line = app.Theme.colors.line
        decor.border:SetBackdropBorderColor(line[1], line[2], line[3], 0.85)
        decor.border:Hide()
        if type(decor.border.SetFrameLevel) == "function" and type(item.GetFrameLevel) == "function" then
            local ok, level = pcall(item.GetFrameLevel, item)
            level = ok and plain(level, "number") or nil
            if level then pcall(decor.border.SetFrameLevel, decor.border, level + 5) end
        end
    end
    item.lumaCooldownDecor = decor
    return decor
end

local function membersChanged(item, entry)
    return item.Icon ~= entry.icon or item.Cooldown ~= entry.cooldown
        or (item.ChargeCount and item.ChargeCount.Current) ~= entry.charge
end

local function record(item)
    local icon = iconOf(item)
    if not icon or not accessible(icon) then return nil end
    local ok, a, b, c, d, e, f, g, h = pcall(icon.GetTexCoord, icon)
    if not ok then return nil end
    local coords = { a, b, c, d, e, f, g, h }
    for index = 1, 8 do
        if not plain(coords[index], "number") then return nil end
    end
    local cooldown, timerOriginal = timerFontOf(item)
    if cooldown and not accessible(cooldown) then cooldown = nil end
    local charge = chargeFontOf(item)
    if charge and not accessible(charge) then charge = nil end
    return {
        icon = item.Icon, cooldown = item.Cooldown, charge = item.ChargeCount and item.ChargeCount.Current,
        iconCoords = coords,
        timer = cooldown and timerOriginal and { target = cooldown, font = timerOriginal } or nil,
        chargeFont = fontEntry(charge),
        chargeTarget = charge,
    }
end

-- Applies the skin to one item frame. Returns true when this item carries the
-- skin (now or from an earlier pass), false when this build does not expose
-- the members or refuses a write — in which case nothing of ours is left on it.
function Skin:Apply(item)
    if not accessible(item) then
        self:Restore(item)
        return false
    end
    local existing = item.lumaCooldownSkin
    if existing and not membersChanged(item, existing) then
        local decor = item.lumaCooldownDecor
        if decor and decor.bg then decor.bg:Show() end
        if decor and decor.border then decor.border:Show() end
        return true
    end
    if existing then self:Restore(item) end
    local entry = record(item)
    if not entry then return false end
    local decor = decorFor(item)
    item.lumaCooldownSkin = entry
    local ok = pcall(entry.icon.SetTexCoord, entry.icon,
        self.crop[1], self.crop[2], self.crop[3], self.crop[4])
    if ok and entry.timer then
        local font = app.Theme.fontObjects and app.Theme.fontObjects[TIMER_FONT_KEY]
        if font then
            ok = pcall(entry.timer.target.SetCountdownFont, entry.timer.target, font)
        end
    end
    if ok and entry.chargeFont and entry.chargeTarget then
        local face = app.Type:Face()
        if face then
            ok = pcall(entry.chargeTarget.SetFont, entry.chargeTarget, face, CHARGE_SIZE, "OUTLINE")
        end
    end
    if not ok then
        self:Restore(item)
        return false
    end
    if decor and decor.bg then decor.bg:Show() end
    if decor and decor.border then decor.border:Show() end
    return true
end

-- Puts every written member back. A frame that refused a write keeps whatever
-- the client put there; the restore only touches values this skin recorded.
function Skin:Restore(item)
    local entry = item and item.lumaCooldownSkin
    if not entry then return true end
    item.lumaCooldownSkin = nil
    local restored = true
    if object(entry.icon) and type(entry.icon.SetTexCoord) == "function" then
        local coords = entry.iconCoords
        local ok = pcall(entry.icon.SetTexCoord, entry.icon,
            coords[1], coords[2], coords[3], coords[4],
            coords[5], coords[6], coords[7], coords[8])
        restored = restored and ok
    end
    if entry.timer and object(entry.timer.target) then
        local ok = pcall(entry.timer.target.SetCountdownFont, entry.timer.target, entry.timer.font)
        restored = restored and ok
    end
    if entry.chargeFont and object(entry.chargeTarget) then
        local ok = pcall(entry.chargeTarget.SetFont, entry.chargeTarget,
            entry.chargeFont.font, entry.chargeFont.size, entry.chargeFont.flags)
        restored = restored and ok
    end
    local decor = item.lumaCooldownDecor
    if decor and decor.bg then pcall(decor.bg.Hide, decor.bg) end
    if decor and decor.border then pcall(decor.border.Hide, decor.border) end
    return restored
end

return Skin
