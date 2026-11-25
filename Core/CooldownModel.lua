local _, app = ...
local Model = {}
app.CooldownModel = Model

-- Pure data for LumaUI's own cooldown groups. Nothing here reads a spell or a
-- frame: it validates the stored shape and turns one group into a layout plan.
-- Identity of an entry is the client's spell ID, never a display name, a frame
-- reference or a pool index, so a renamed spell or a recycled button cannot
-- change what the player configured.
--
-- Two groups ship enabled but empty. An empty group draws nothing, so the
-- default screen is unchanged; the groups only become visible after the player
-- explicitly imports the client's order or adds spells.

Model.GROUP_IDS = { "essential", "utility" }
Model.maxEntries = 24
Model.sizeRange = { 18, 40 }
Model.gapRange = { 0, 8 }
Model.maxRange = { 1, 15 }

local GROUP_DEFAULTS = {
    essential = { max = 9, style = "essential" },
    utility = { max = 7, style = "utility" },
}

local function finite(value)
    return type(value) == "number" and value == value and value > -math.huge and value < math.huge
end

local function bounded(value, fallback, low, high)
    if not finite(value) then return fallback end
    return math.max(low, math.min(high, value))
end

local function whole(value, fallback, low, high)
    return math.floor(bounded(value, fallback, low, high) + 0.5)
end

-- Spell IDs are positive integers. A secret or malformed entry is dropped
-- instead of being coerced, because an unknown ID must not produce a guessed
-- icon or a second entry for the same spell.
function Model:SanitizeOrder(ids)
    local list, seen = {}, {}
    if type(ids) ~= "table" then return list end
    for _, value in ipairs(ids) do
        local id = app.Capabilities.Plain(value, "number")
        if id and id > 0 and id == math.floor(id) and not seen[id]
            and #list < self.maxEntries then
            seen[id] = true
            list[#list + 1] = id
        end
    end
    return list
end

function Model:Normalize(input)
    input = type(input) == "table" and input or {}
    local result = { owned = input.owned == true, groups = {} }
    local groups = type(input.groups) == "table" and input.groups or {}
    for _, id in ipairs(self.GROUP_IDS) do
        local defaults = GROUP_DEFAULTS[id]
        local source = type(groups[id]) == "table" and groups[id] or {}
        result.groups[id] = {
            id = id,
            order = self:SanitizeOrder(source.order),
            enabled = source.enabled ~= false,
            size = whole(source.size, 26, self.sizeRange[1], self.sizeRange[2]),
            gap = whole(source.gap, 4, self.gapRange[1], self.gapRange[2]),
            max = whole(source.max, defaults.max, self.maxRange[1], self.maxRange[2]),
            style = defaults.style,
        }
    end
    return result
end

function Model:Source(input)
    -- Accepts either the whole `ui.cooldownGroups` table or one group.
    if type(input) ~= "table" then return nil end
    if input.groups then return input.groups end
    return input
end

function Model:Get(input, id)
    local groups = self:Source(input)
    return groups and id and groups[id] or nil
end

-- Pure geometry for one group at a given available width. Reuses CentralGrid so
-- the icon size, gap and per-row capacity follow the same rules as the native
-- viewer placement instead of a second layout algorithm.
function Model:Plan(group, maxWidth)
    if type(group) ~= "table" then
        return app.CentralGrid:Plan({ count = 0, size = 0 })
    end
    return app.CentralGrid:Plan({
        count = #(group.order or {}), size = group.size, gap = group.gap,
        max = group.max, style = group.style, maxWidth = maxWidth,
    })
end

-- Applies an imported client order. An append keeps the player's existing
-- entries first and adds the imported IDs that are missing; a replace is only
-- used when the player explicitly asks for it. A shorter import never removes
-- entries the player added by hand.
function Model:ApplyOrder(group, ids, replace)
    if type(group) ~= "table" then return 0, 0 end
    local incoming = self:SanitizeOrder(ids)
    if #incoming == 0 then return 0, 0 end
    if replace then
        local previous = #(group.order or {})
        group.order = incoming
        return #incoming, previous
    end
    local seen, added = {}, 0
    for _, id in ipairs(group.order or {}) do seen[id] = true end
    for _, id in ipairs(incoming) do
        if not seen[id] and #(group.order or {}) < self.maxEntries then
            seen[id] = true
            group.order = group.order or {}
            group.order[#group.order + 1] = id
            added = added + 1
        end
    end
    return added, 0
end

function Model:Remove(group, spellID)
    if type(group) ~= "table" or type(group.order) ~= "table" then return false end
    for index = #group.order, 1, -1 do
        if group.order[index] == spellID then
            table.remove(group.order, index)
            return true
        end
    end
    return false
end
