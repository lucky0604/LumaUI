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

-- Three groups mirror the client's Cooldown Manager: the essential block, the
-- utility block, and the tracked buffs. Each one is its own layout entry with
-- its own size, gap, per-row cap and column mode, so all three can be moved and
-- resized independently.
Model.GROUP_IDS = { "essential", "utility", "buffs" }
Model.maxEntries = 24
Model.sizeRange = { 18, 40 }
Model.gapRange = { 0, 8 }
Model.maxRange = { 1, 15 }

-- `kind` says where a group's live state comes from: "cooldown" groups read the
-- spell's cooldown/charges, "buff" reads the player's aura. It is not a style
-- flag, so it lives here with the data instead of in the renderer.
local GROUP_DEFAULTS = {
    essential = { max = 9, style = "essential", size = 26, gap = 4, kind = "cooldown" },
    utility = { max = 7, style = "utility", size = 26, gap = 4, kind = "cooldown" },
    buffs = { max = 10, style = "buffIcon", size = 24, gap = 4, kind = "buff" },
}

function Model:Kind(id)
    local defaults = GROUP_DEFAULTS[id]
    return defaults and defaults.kind or "cooldown"
end

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
    -- `hideBuffViewers` covers the client's tracked-buff viewers, the two blocks
    -- LumaUI does not replace. On by default: turning the own groups on is the
    -- player asking for one cooldown display, not two. The switch is next to the
    -- groups so it can be turned off again without a reload.
    -- Everything is on by default: the own blocks are the display and the
    -- client's viewers step aside. `auto` means each group follows the player's
    -- own Cooldown Manager list (order, hidden entries) instead of a stored copy,
    -- so editing the client's CDM is the only thing a player ever has to do.
    local result = { owned = input.owned ~= false, hideBuffViewers = input.hideBuffViewers ~= false,
        groups = {} }
    local groups = type(input.groups) == "table" and input.groups or {}
    for _, id in ipairs(self.GROUP_IDS) do
        local defaults = GROUP_DEFAULTS[id]
        local source = type(groups[id]) == "table" and groups[id] or {}
        result.groups[id] = {
            id = id,
            order = self:SanitizeOrder(source.order),
            enabled = source.enabled ~= false,
            size = whole(source.size, defaults.size, self.sizeRange[1], self.sizeRange[2]),
            gap = whole(source.gap, defaults.gap, self.gapRange[1], self.gapRange[2]),
            max = whole(source.max, defaults.max, self.maxRange[1], self.maxRange[2]),
            vertical = source.vertical == true,
            -- `auto` is the shipped mode; a manual add/remove/reorder turns it
            -- off, and `import` turns it back on (a copy no longer follows).
            auto = source.auto ~= false,
            style = defaults.style,
            kind = defaults.kind,
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
        vertical = group.vertical == true,
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

-- Moves one spell between groups (or within one, to `position`). Identity is
-- the spell ID; a spell already in the target is only reordered, and a full
-- target refuses instead of dropping an entry. Returns true when anything moved.
function Model:Move(groups, spellID, targetID, position)
    local target = groups and groups[targetID]
    if type(target) ~= "table" or not spellID then return false end
    local source
    for _, id in ipairs(self.GROUP_IDS) do
        local group = groups[id]
        for _, current in ipairs(group.order) do
            if current == spellID then source = group end
        end
    end
    if not source then return false end
    if source ~= target and #target.order >= self.maxEntries then return false end
    self:Remove(source, spellID)
    position = math.max(1, math.min(#target.order + 1, math.floor(tonumber(position) or (#target.order + 1))))
    table.insert(target.order, position, spellID)
    return true
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
