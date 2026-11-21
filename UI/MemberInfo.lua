local _, app = ...
local MemberInfo = {}
app.MemberInfo = MemberInfo

-- Shared read-only member facts for the party and raid buttons. Everything is
-- pcall'd and passed through Plain: a restricted role, death or connection flag
-- yields nil and the caller simply draws nothing.

local ROLE_TEXT = {
    TANK = "roleTank",
    HEALER = "roleHealer",
    DAMAGER = "roleDamage",
}
local ROLE_COLORS = {
    TANK = { 0.42, 0.68, 1.00 },
    HEALER = { 0.30, 0.90, 0.55 },
    DAMAGER = { 0.95, 0.45, 0.40 },
}

-- Returns the one-letter role, its colour and the key that names it, or nil
-- when the client does not report a plain role for this unit.
function MemberInfo.Role(unit)
    if type(UnitGroupRolesAssigned) ~= "function" then return nil end
    local ok, value = pcall(UnitGroupRolesAssigned, unit)
    if not ok then return nil end
    local role = app.Capabilities.Plain(value, "string")
    local letterKey = role and ROLE_TEXT[role]
    if not letterKey then return nil end
    local color = ROLE_COLORS[role]
    return app.L[letterKey], color, letterKey
end

-- "dead" / "offline" / nil. Plain booleans only; a restricted flag is unknown,
-- not "alive".
function MemberInfo.State(unit)
    if type(UnitIsDeadOrGhost) == "function" then
        local ok, value = pcall(UnitIsDeadOrGhost, unit)
        if ok and app.Capabilities.Plain(value, "boolean") == true then return "dead" end
    elseif type(UnitIsDead) == "function" then
        local ok, value = pcall(UnitIsDead, unit)
        if ok and app.Capabilities.Plain(value, "boolean") == true then return "dead" end
    end
    if type(UnitIsConnected) == "function" then
        local ok, value = pcall(UnitIsConnected, unit)
        if ok and app.Capabilities.Plain(value, "boolean") == false then return "offline" end
    end
    return nil
end

-- Writes the role glyph and the death/offline label into controls the caller
-- owns. Both are cleared when the unit reports nothing plain.
function MemberInfo.Draw(unit, roleText, statusText)
    local letter, color = MemberInfo.Role(unit)
    if roleText then
        if letter then
            roleText:SetText(letter)
            roleText:SetTextColor(color[1], color[2], color[3], 1)
        else
            roleText:SetText("")
        end
    end
    if statusText then
        local state = MemberInfo.State(unit)
        if state == "dead" then
            statusText:SetText(app.L.unitDead)
            statusText:SetTextColor(0.95, 0.45, 0.42, 1)
        elseif state == "offline" then
            statusText:SetText(app.L.unitOffline)
            local muted = app.Theme.colors.muted
            statusText:SetTextColor(muted[1], muted[2], muted[3], 1)
        else
            statusText:SetText("")
        end
    end
end

function MemberInfo.Clear(roleText, statusText)
    if roleText then roleText:SetText("") end
    if statusText then statusText:SetText("") end
end
