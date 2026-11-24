local _, app = ...

-- Click casting for LumaUI's own unit buttons. Bindings are stored per profile
-- as "modifier-button" -> spell name (for example "shift-left" -> "Flash Heal")
-- and applied to the secure unit buttons as secure attributes, which is the
-- only way the client allows a click to cast: plain Lua cannot cast in combat.
--
-- Only modifier + button combinations are used, so a plain left click keeps its
-- normal targeting behaviour. The attributes are written out of combat through
-- the queue; nothing here runs during combat except a deferred re-apply.
--
-- The buttons are found by their global names (LumaUIUnit_*, LumaUIParty*,
-- LumaUIRaid*), so this module never has to reach into the other components.

local BUTTON_PREFIXES = { "LumaUIUnit_", "LumaUIParty", "LumaUIRaid" }
local UNITS = { "player", "target", "focus", "pet", "targettarget" }
local MODIFIERS = { "shift", "ctrl", "alt" }
local BUTTONS = { left = 1, right = 2 }
local JOB = "clickCast/apply"

local component

-- "shift-left" -> modifier prefix "shift", button index 1.
local function parse(key)
    if type(key) ~= "string" then return nil end
    local modifiers, button = key:match("^(.-)%-([%l]+)$")
    if not button or not BUTTONS[button] then return nil end
    local prefix = ""
    for _, modifier in ipairs(MODIFIERS) do
        if modifiers:find(modifier, 1, true) then prefix = prefix .. modifier end
    end
    if prefix == "" and modifiers ~= "" then return nil end
    return prefix, BUTTONS[button]
end

local function candidateButtons()
    local buttons = {}
    for _, unit in ipairs(UNITS) do
        local frame = _G["LumaUIUnit_" .. unit]
        if frame then buttons[#buttons + 1] = frame end
    end
    for index = 1, 4 do
        local frame = _G["LumaUIParty" .. index]
        if frame then buttons[#buttons + 1] = frame end
    end
    for index = 1, 40 do
        local frame = _G["LumaUIRaid" .. index]
        if frame then buttons[#buttons + 1] = frame end
    end
    return buttons
end

-- Clears every click-cast attribute we may have written, then writes the
-- current bindings. Runs out of combat only.
local function applyBindings()
    local profile = app.Store:Profile()
    local bindings = (profile and profile.ui and profile.ui.clickCast) or {}
    for _, button in ipairs(candidateButtons()) do
        if type(button.SetAttribute) == "function" then
            -- Clear what we set before.
            for _, modifier in ipairs(MODIFIERS) do
                for _, index in ipairs({ 1, 2 }) do
                    local prefix = "*" .. modifier .. "-type" .. index
                    pcall(button.SetAttribute, button, prefix, nil)
                    pcall(button.SetAttribute, button, "*" .. modifier .. "-spell" .. index, nil)
                end
            end
            for key, spell in pairs(bindings) do
                local prefix, index = parse(key)
                if prefix and spell and spell ~= "" then
                    pcall(button.SetAttribute, button, "*" .. prefix .. "-type" .. index, "spell")
                    pcall(button.SetAttribute, button, "*" .. prefix .. "-spell" .. index, spell)
                end
            end
        end
    end
end

local function schedule()
    app.Queue:Run(JOB, function()
        if component.running then applyBindings() end
    end)
end

component = app:RegisterComponent({ id = "clickCast", label = "clickCast", defaultEnabled = false,
    Supported = function() return type(RegisterUnitWatch) == "function" end,
    Enable = function(self)
        schedule()
        -- Party and raid buttons are created on demand, so a roster change can
        -- introduce new buttons that still need the attributes.
        for _, event in ipairs({ "GROUP_ROSTER_UPDATE", "RAID_ROSTER_UPDATE", "PLAYER_ENTERING_WORLD" }) do
            self:Listen(event, function() schedule() end)
        end
        -- Buttons can be created later (party/raid rebuilt); one extra pass
        -- shortly after enabling catches them without any permanent timer.
        if type(C_Timer) == "table" and type(C_Timer.After) == "function" then
            C_Timer.After(1.5, function()
                if self.running then schedule() end
            end)
        end
    end,
    Refresh = function() schedule() end,
    Disable = function(self)
        app.Queue:Run(JOB, function()
            for _, button in ipairs(candidateButtons()) do
                if type(button.SetAttribute) == "function" then
                    for _, modifier in ipairs(MODIFIERS) do
                        for _, index in ipairs({ 1, 2 }) do
                            pcall(button.SetAttribute, button, "*" .. modifier .. "-type" .. index, nil)
                            pcall(button.SetAttribute, button, "*" .. modifier .. "-spell" .. index, nil)
                        end
                    end
                end
            end
        end)
    end,
})

-- `/luma cc <key> <spell>` binds, `/luma cc <key> off` clears one binding,
-- `/luma cc list` prints them and `/luma cc clear` removes them all.
function component:Bind(key, spell)
    local prefix, index = parse(key)
    if not prefix then app:Print(app.L.clickCastUsage); return false end
    if prefix == "" and (index == 1 or index == 2) then
        app:Print(app.L.clickCastNeedsModifier)
        return false
    end
    local profile = app.Store:Profile()
    local bindings = {}
    for existing, value in pairs(profile.ui.clickCast or {}) do bindings[existing] = value end
    if spell == nil or spell == "" or spell:lower() == "off" then
        bindings[key] = nil
    else
        bindings[key] = spell
    end
    local ok = app.Store:Set("ui", "clickCast", bindings)
    if ok then schedule() end
    return ok
end

function component:List()
    local bindings = app.Store:Profile().ui.clickCast or {}
    local keys = {}
    for key in pairs(bindings) do keys[#keys + 1] = key end
    table.sort(keys)
    if #keys == 0 then app:Print(app.L.clickCastEmpty); return end
    for _, key in ipairs(keys) do
        app:Print(key .. " -> " .. bindings[key])
    end
end

function component:Clear()
    if app.Store:Set("ui", "clickCast", {}) then
        schedule()
        app:Print(app.L.clickCastCleared)
    end
end
