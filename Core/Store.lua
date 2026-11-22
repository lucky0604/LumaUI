local _, app = ...
local Store = { schema = 1 }
app.Store = Store
Store.defaults = {
    -- `opacity` is the legacy single value still used by compatibility panels.
    -- windowOpacity/hudOpacity/chatOpacity/chatActiveOpacity are the semantic
    -- roles added in 0.15.0: a window, a HUD support and an idle/active chat
    -- backdrop no longer share one number.
    appearance = { scale = 1, opacity = 0.9, windowOpacity = 0.96, hudOpacity = 0.62,
        chatOpacity = 0.25, chatActiveOpacity = 0.75, motion = true, reduceMotion = false,
        accent = "ocean", tooltipQuality = true },
    modules = { launcher = true, minimap = true, questTracker = true, questList = true, dataStrip = true, experience = true, chat = true, chatTabs = true, tooltip = true, inventory = true, unitFrames = false },
    ui = { questFilter = "all", questFolds = { groups = {}, quests = {} }, windowScale = 1,
        clickCast = {}, auraFilter = "all", takeoverUnitFrames = false,
        -- One clock by default. The strip is the default owner; the minimap
        -- panel is the alternative, and the choice persists per profile.
        clock = "strip", stripCompact = true },
    positions = {},
}

local function clone(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, child in pairs(value) do result[key] = clone(child) end
    return result
end
Store.Clone = clone

local function finite(value)
    return type(value) == "number" and value == value and value > -math.huge and value < math.huge
end

local function bounded(value, fallback, low, high)
    if not finite(value) then return fallback end
    return math.max(low, math.min(high, value))
end

function Store:ValidName(name)
    if type(name) ~= "string" then return false end
    local chars = 0
    for _ in name:gmatch("[^\128-\191]") do chars = chars + 1 end
    return chars >= 1 and chars <= 40 and name:find("%S") ~= nil and not name:find("[%c|]")
end

function Store:Normalize(input)
    local result = clone(self.defaults)
    if type(input) ~= "table" then return result end
    local look = type(input.appearance) == "table" and input.appearance or {}
    result.appearance.scale = bounded(look.scale, 1, 0.7, 1.5)
    result.appearance.opacity = bounded(look.opacity, 0.9, 0.45, 1)
    -- Semantic surface opacities. A profile written before these fields existed
    -- receives the defaults instead of being migrated to the legacy value, so
    -- nothing turns transparent or opaque on the first login.
    result.appearance.windowOpacity = bounded(look.windowOpacity, 0.96, 0.45, 1)
    result.appearance.hudOpacity = bounded(look.hudOpacity, 0.62, 0.15, 1)
    result.appearance.chatOpacity = bounded(look.chatOpacity, 0.25, 0, 1)
    result.appearance.chatActiveOpacity = bounded(look.chatActiveOpacity, 0.75, 0.2, 1)
    if type(look.motion) == "boolean" then result.appearance.motion = look.motion end
    -- Reduced motion settles every transition at once without a reload; it is
    -- stored next to the motion switch so both share one validated profile.
    if type(look.reduceMotion) == "boolean" then result.appearance.reduceMotion = look.reduceMotion end
    if type(look.tooltipQuality) == "boolean" then result.appearance.tooltipQuality = look.tooltipQuality end
    if look.accent == "ember" then result.appearance.accent = "ember" end
    local ui = type(input.ui) == "table" and input.ui or {}
    if ui.questFilter == "tracked" or ui.questFilter == "zone" or ui.questFilter == "all" then
        result.ui.questFilter = ui.questFilter
    end
    -- Aura row filter: everything, or only debuffs the player can dispel.
    if ui.auraFilter == "dispel" then result.ui.auraFilter = "dispel" end
    -- Native unit-frame takeover is an explicit per-profile opt-in; anything
    -- but true keeps the game's frames on screen.
    result.ui.takeoverUnitFrames = ui.takeoverUnitFrames == true
    -- One clock. "strip" (default), "minimap" or "off"; anything else keeps
    -- the default, so a damaged value can never hide the time entirely.
    if ui.clock == "minimap" or ui.clock == "off" then result.ui.clock = ui.clock end
    if type(ui.stripCompact) == "boolean" then result.ui.stripCompact = ui.stripCompact end
    -- Scale of LumaUI's own windows (the character window uses it today).
    result.ui.windowScale = bounded(ui.windowScale, 1, 0.8, 1.3)
    -- Click-casting bindings: "modifier-button" -> spell name. Only plain
    -- strings with a known shape are kept, so a damaged save cannot inject
    -- arbitrary secure attributes.
    result.ui.clickCast = {}
    if type(ui.clickCast) == "table" then
        local count = 0
        for key, spell in pairs(ui.clickCast) do
            if count < 24 and type(key) == "string" and type(spell) == "string"
                and key:match("^[%l%-]+$") and #key <= 24 and spell ~= ""
                and #spell <= 60 and not spell:find("[%c|]") then
                result.ui.clickCast[key] = spell
                count = count + 1
            end
        end
    end
    -- Quest panel fold state: only collapsed entries are kept, with plain
    -- string keys ("g:<group name>", "q:<quest id>") and a hard entry cap so a
    -- damaged database can never grow unbounded.
    result.ui.questFolds = { groups = {}, quests = {} }
    if type(ui.questFolds) == "table" then
        for _, kind in ipairs({ "groups", "quests" }) do
            local source = ui.questFolds[kind]
            if type(source) == "table" then
                local count = 0
                for key, collapsed in pairs(source) do
                    if count < 256 and collapsed == true and type(key) == "string"
                        and #key >= 1 and #key <= 96 and not key:find("[%c]") then
                        result.ui.questFolds[kind][key] = true
                        count = count + 1
                    end
                end
            end
        end
    end
    local modules = type(input.modules) == "table" and input.modules or {}
    -- Keep switches for optional extensions even while those addons are absent.
    for id, value in pairs(modules) do
        if type(id) == "string" and id:match("^[%a][%w_]*$") and type(value) == "boolean" then result.modules[id] = value end
    end
    for id in pairs(result.modules) do
        if type(modules[id]) == "boolean" then result.modules[id] = modules[id] end
    end
    if type(input.positions) == "table" then
        for id, position in pairs(input.positions) do
            if type(id) == "string" and type(position) == "table" and finite(position.x) and finite(position.y) then
                result.positions[id] = { x = bounded(position.x, 0, -20000, 20000), y = bounded(position.y, 0, -20000, 20000) }
            end
        end
    end
    return result
end

function Store:Open(character)
    local saved = _G.LumaUIDB
    if type(saved) == "table" and type(saved.schema) == "number" and saved.schema > self.schema then
        self.readonly = true
        self.money = {}
        self.data = { schema = self.schema, profiles = { Default = clone(self.defaults) }, characters = {} }
    else
        self.readonly = false
        saved = type(saved) == "table" and saved or {}
        local profiles = {}
        if type(saved.profiles) == "table" then
            for name, profile in pairs(saved.profiles) do
                if self:ValidName(name) then profiles[name] = self:Normalize(profile) end
            end
        end
        if not next(profiles) then profiles.Default = clone(self.defaults) end
        -- The quest list preview went from opt-in to opt-out. Profiles written by
        -- earlier builds carry the old default as an explicit false, so enable it
        -- once; the flag keeps a later opt-out from being overridden again.
        local migrations = {
            questListDefault = type(saved.migrations) == "table" and saved.migrations.questListDefault == true,
        }
        if not migrations.questListDefault then
            for _, profile in pairs(profiles) do
                if profile.modules.questList == false then profile.modules.questList = true end
            end
            migrations.questListDefault = true
        end
        self.data = { schema = self.schema, profiles = profiles, characters = {}, migrations = migrations }
        if type(saved.characters) == "table" then
            for name, selected in pairs(saved.characters) do
                if type(name) == "string" and type(selected) == "string" and profiles[selected] then self.data.characters[name] = selected end
            end
        end
        -- Account-wide money ledger: values are recorded from this account's own
        -- characters only, so the tooltip never needs a restricted API.
        local money = {}
        if type(saved.money) == "table" then
            for key, amount in pairs(saved.money) do
                if type(key) == "string" and self:ValidName(key) and finite(amount) and amount >= 0 then
                    money[key] = math.floor(math.min(amount, 1000000000000))
                end
            end
        end
        self.money = money
        self.data.money = money
        _G.LumaUIDB = self.data
    end
    self.character = character
    local current = self.data.characters[character]
    if not current or not self.data.profiles[current] then
        current = self.data.profiles.Default and "Default" or self:Names()[1]
        self.data.characters[character] = current
    end
    self.current = current
end

function Store:Profile() return self.data.profiles[self.current] end

function Store:Names()
    local list = {}
    for name in pairs(self.data.profiles) do list[#list + 1] = name end
    table.sort(list)
    return list
end

function Store:Changed()
    app:Publish("PROFILE_CHANGED", self.current)
end

function Store:Set(section, key, value)
    if self.readonly then return false, app.L.readonly end
    if section ~= "appearance" and section ~= "modules" and section ~= "ui" then return false end
    local profile = clone(self:Profile())
    if profile[section][key] == nil then return false end
    profile[section][key] = value
    self.data.profiles[self.current] = self:Normalize(profile)
    self:Changed()
    return true
end

function Store:SetPosition(id, x, y)
    if self.readonly or not finite(x) or not finite(y) then return false end
    self:Profile().positions[id] = { x = bounded(x, 0, -20000, 20000), y = bounded(y, 0, -20000, 20000) }
    return true
end

-- Replaces the whole position table. Used by the layout preset undo: the
-- snapshot is restored as a set, so keys the preset added disappear and keys it
-- did not touch keep their values.
function Store:SetPositions(positions)
    if self.readonly then return false, app.L.readonly end
    if type(positions) ~= "table" then return false end
    local profile = self:Profile()
    profile.positions = {}
    for id, position in pairs(positions) do
        if type(id) == "string" and type(position) == "table"
            and finite(position.x) and finite(position.y) then
            profile.positions[id] = { x = bounded(position.x, 0, -20000, 20000),
                y = bounded(position.y, 0, -20000, 20000) }
        end
    end
    return true
end

function Store:SetMoney(character, amount)    if self.readonly or type(character) ~= "string" then return false end
    amount = finite(amount) and math.floor(amount) or nil
    if not amount or amount < 0 then return false end
    amount = math.min(amount, 1000000000000)
    self.money[character] = amount
    if self.data.money ~= self.money then self.data.money = self.money end
    return true
end

function Store:Create(name, copyCurrent)
    if self.readonly then return false, app.L.readonly end
    name = type(name) == "string" and name:match("^%s*(.-)%s*$") or name
    if not self:ValidName(name) then return false, app.L.invalidName end
    if self.data.profiles[name] then return false, app.L.exists end
    self.data.profiles[name] = copyCurrent and clone(self:Profile()) or clone(self.defaults)
    return self:Select(name)
end

function Store:Select(name)
    if self.readonly then return false, app.L.readonly end
    if not self.data.profiles[name] then return false, app.L.unknownProfile end
    self.current, self.data.characters[self.character] = name, name
    self:Changed()
    return true
end

function Store:Delete(name)
    if self.readonly then return false, app.L.readonly end
    if not self.data.profiles[name] then return false, app.L.unknownProfile end
    if #self:Names() == 1 then return false, app.L.lastProfile end
    self.data.profiles[name] = nil
    local fallback = self:Names()[1]
    for character, current in pairs(self.data.characters) do
        if current == name then self.data.characters[character] = fallback end
    end
    self.current = self.data.characters[self.character]
    self:Changed()
    return true
end

function Store:Reset(layoutOnly)
    if self.readonly then return false, app.L.readonly end
    if layoutOnly then self:Profile().positions = {} else self.data.profiles[self.current] = clone(self.defaults) end
    self:Changed()
    return true
end
