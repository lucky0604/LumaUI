local _, app = ...
local Model = {}
app.BarModel = Model

-- Configuration and pure geometry for LumaUI's own action bars (012 phase
-- 10/11). The model knows which game action slots a bar owns and how those
-- twelve slots divide into columns and rows. It never creates a button, hides a
-- native bar or touches a binding: those decisions belong to the renderer and
-- its out-of-combat queue.
--
-- The slot ranges are the client's documented action IDs, not a guess from the
-- display order: bar 1 is 1..12, bar 2 is 61..72, bar 3 is 49..60. A build that
-- disagrees can be corrected here once verified, without touching the renderer.

Model.BARS = { "bar1", "bar2", "bar3" }
Model.SLOT_RANGES = {
    bar1 = { 1, 12 },
    bar2 = { 61, 72 },
    bar3 = { 49, 60 },
}

-- The client's own action bars, one definition per bar. This is the single
-- catalog the mover, the settings pages, the report and the ownership records
-- read: display number, host frame, action slot range, binding prefix and role.
--
-- Slot ranges and binding prefixes are the client's own, not derived from the
-- display position: bar 2 is the bottom-left bar with actions 61–72 and the
-- `MULTIACTIONBAR1BUTTON` prefix even though it is the second bar a player sees.
-- A build that disagrees can be corrected here without touching a renderer.
--
-- `manageable` marks the bars LumaUI sizes and positions through its own layout
-- entries (1–3 today). Every other bar keeps the client's own Edit Mode layout
-- and visibility; Phase 03 removed the unconditional parking, and Phase 07 adds
-- the verified adapter for bars 4–8.
Model.native = {
    { id = 1, key = "actionBar1", display = 1, frame = "MainActionBar", prefix = "ActionButton",
      slots = { 1, 12 }, binding = "ACTIONBUTTON", kind = "main", manageable = true },
    { id = 2, key = "actionBar2", display = 2, frame = "MultiBarBottomLeft", prefix = "MultiBarBottomLeftButton",
      slots = { 61, 72 }, binding = "MULTIACTIONBAR1BUTTON", kind = "fixed", manageable = true },
    { id = 3, key = "actionBar3", display = 3, frame = "MultiBarBottomRight", prefix = "MultiBarBottomRightButton",
      slots = { 49, 60 }, binding = "MULTIACTIONBAR2BUTTON", kind = "fixed", manageable = true },
    { id = 4, key = "actionBar4", display = 4, frame = "MultiBarRight", prefix = "MultiBarRightButton",
      slots = { 25, 36 }, binding = "MULTIACTIONBAR3BUTTON", kind = "fixed", manageable = false },
    { id = 5, key = "actionBar5", display = 5, frame = "MultiBarLeft", prefix = "MultiBarLeftButton",
      slots = { 37, 48 }, binding = "MULTIACTIONBAR4BUTTON", kind = "fixed", manageable = false },
    { id = 6, key = "actionBar6", display = 6, frame = "MultiBar5", prefix = "MultiBar5Button",
      slots = { 145, 156 }, binding = "MULTIACTIONBAR5BUTTON", kind = "fixed", manageable = false },
    { id = 7, key = "actionBar7", display = 7, frame = "MultiBar6", prefix = "MultiBar6Button",
      slots = { 157, 168 }, binding = "MULTIACTIONBAR6BUTTON", kind = "fixed", manageable = false },
    { id = 8, key = "actionBar8", display = 8, frame = "MultiBar7", prefix = "MultiBar7Button",
      slots = { 169, 180 }, binding = "MULTIACTIONBAR7BUTTON", kind = "fixed", manageable = false },
    -- Contextual bars. Their slots and drivers are the client's own: the pet bar
    -- follows the pet's action list, the stance bar the shapeshift slots, and the
    -- extra/zone buttons carry their own actions. They are never numbered like
    -- the fixed bars.
    { id = 9, key = "petBar", display = 0, frame = "PetActionBar", prefix = "PetActionButton",
      binding = "PETACTIONBUTTON", kind = "pet", manageable = false },
    { id = 10, key = "stanceBar", display = 0, frame = "StanceBar", prefix = "StanceButton",
      binding = "SHAPESHIFTBUTTON", kind = "stance", manageable = false },
    { id = 11, key = "extraBar", display = 0, frame = "ExtraActionBarFrame", prefix = "ExtraActionButton",
      binding = "EXTRAACTIONBUTTON", kind = "extra", manageable = false },
    { id = 12, key = "zoneAbility", display = 0, frame = "ZoneAbilityFrame", prefix = "ZoneAbility",
      binding = nil, kind = "zone", manageable = false },
}
Model.defaults = {
    enabled = false,
    bars = {
        bar1 = { columns = 12, size = 30, gap = 4, direction = "right" },
        bar2 = { columns = 12, size = 30, gap = 4, direction = "right" },
        bar3 = { columns = 12, size = 30, gap = 4, direction = "right" },
    },
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

function Model:Normalize(input)
    input = type(input) == "table" and input or {}
    local result = { enabled = input.enabled == true, bars = {} }
    local bars = type(input.bars) == "table" and input.bars or {}
    for _, id in ipairs(self.BARS) do
        local source = type(bars[id]) == "table" and bars[id] or {}
        result.bars[id] = {
            columns = math.floor(bounded(source.columns, 12, 1, 12) + 0.5),
            size = math.floor(bounded(source.size, 30, 20, 50) + 0.5),
            gap = math.floor(bounded(source.gap, 4, 0, 10) + 0.5),
            direction = source.direction == "left" and "left" or "right",
        }
    end
    return result
end

function Model:Get(input, id)
    if type(input) ~= "table" or type(input.bars) ~= "table" then return nil end
    return input.bars[id]
end

-- Twelve slots in reading order, with the configured direction mirrored per
-- row. Returns centres measured from the block's bottom-left corner plus the
-- block size, so the renderer only has to place one origin.
function Model:Plan(bar)
    if type(bar) ~= "table" then return { slots = {}, width = 0, height = 0 } end
    local columns = bar.columns or 12
    local rows = math.ceil(12 / columns)
    local size, gap = bar.size or 30, bar.gap or 4
    local slots = {}
    for index = 1, 12 do
        local row = math.floor((index - 1) / columns)
        local column = (index - 1) % columns
        if bar.direction == "left" then column = columns - 1 - column end
        slots[index] = {
            index = index, row = row, column = column,
            x = column * (size + gap) + size / 2,
            y = row * (size + gap) + size / 2,
        }
    end
    local width = columns * size + (columns - 1) * gap
    local height = rows * size + (rows - 1) * gap
    -- The last row is centred on its own axis, like the skill rows, so a bar
    -- with 5 columns does not leave two slots dangling on the left.
    local lastCount = 12 - (rows - 1) * columns
    if lastCount < columns then
        local shift = (columns - lastCount) * (size + gap) / 2
        for index = (rows - 1) * columns + 1, 12 do
            slots[index].x = slots[index].x + shift
        end
    end
    return { slots = slots, width = width, height = height, rows = rows, columns = columns }
end

function Model:SlotRange(id)
    local range = self.SLOT_RANGES[id]
    if not range then return nil end
    return range[1], range[2]
end

-- Catalog lookups. `Native(id)` takes the display number (1–8) or a layout key;
-- the contextual bars only answer to their key.
function Model:Native(idOrKey)
    for _, entry in ipairs(self.native) do
        if entry.id == idOrKey or entry.key == idOrKey then return entry end
    end
end

function Model:NativeByFrame(name)
    if type(name) ~= "string" then return nil end
    for _, entry in ipairs(self.native) do
        if entry.frame == name then return entry end
    end
end

function Model:NativeFixed()
    local list = {}
    for _, entry in ipairs(self.native) do
        if entry.kind == "main" or entry.kind == "fixed" then list[#list + 1] = entry end
    end
    return list
end

-- The client action id a button index of this bar drives, or nil when the bar's
-- slots come from another driver (pet, stance, extra).
-- Per-bar layout overrides for the client-hosted bars (Phase 07). `buttons` and
-- `rows` are 0 when the player has not configured them; `size` 0 keeps the
-- client's own button size. Nothing here writes a frame: the renderer applies a
-- plan out of combat and restores the recorded state when the override is
-- cleared.
Model.layoutDefaults = { buttons = 0, rows = 0, size = 0, gap = 4, visible = "always" }
Model.visibleModes = { always = true, combat = true, outofcombat = true, hidden = true }

-- True when a bar's override asks for anything: the renderer then records the
-- client's own state before writing.
function Model:LayoutActive(spec)
    if type(spec) ~= "table" then return false end
    return (spec.buttons or 0) > 0 or (spec.rows or 0) > 0 or (spec.size or 0) > 0
        or (spec.visible or "always") ~= "always"
end

function Model:NormalizeLayout(input)
    local result = {}
    if type(input) ~= "table" then return result end
    for _, bar in ipairs(self.native) do
        local source = input[bar.id]
        if type(source) == "table" then
            local visible = self.visibleModes[source.visible] and source.visible or "always"
            result[bar.id] = {
                buttons = whole(source.buttons, 0, 0, 12),
                rows = whole(source.rows, 0, 0, 12),
                size = whole(source.size, 0, 0, 60),
                gap = whole(source.gap, 4, 0, 12),
                visible = visible,
            }
        end
    end
    return result
end

-- Button capacity per row for `buttons` buttons in `rows` rows: every row gets
-- floor(buttons/rows), and the first `buttons % rows` rows get one more. 8 two
-- rows is 4+4; 7 five rows is 2+2+1+1+1.
function Model:RowCounts(buttons, rows)
    buttons = math.max(1, math.min(12, math.floor(buttons)))
    rows = math.max(1, math.min(buttons, math.floor(rows)))
    local base, extra = math.floor(buttons / rows), buttons % rows
    local counts = {}
    for index = 1, rows do counts[index] = base + (index <= extra and 1 or 0) end
    return counts
end

-- Placement for one bar override. Rows fill bottom-up like the client's own
-- action bars: the first button stays where it was and the extra rows stack
-- above it, so a player's muscle memory for the first row survives. A shorter
-- row is centred on the widest one, as the skill rows are. Coordinates are
-- offsets from the bar's bottom-left corner in the bar's own units.
-- `fallbackSize` is the measured button size used when the player did not set
-- one.
function Model:LayoutPlan(spec, slotCount, fallbackSize)
    spec = type(spec) == "table" and spec or {}
    slotCount = math.max(1, math.min(12, math.floor(slotCount or 12)))
    local buttons = (spec.buttons or 0) > 0 and spec.buttons or slotCount
    if buttons > slotCount then buttons = slotCount end
    local rows = (spec.rows or 0) > 0 and spec.rows or 1
    local size = (spec.size or 0) > 0 and spec.size or (fallbackSize or 0)
    local gap = math.max(0, spec.gap or 4)
    local counts = self:RowCounts(buttons, rows)
    rows = #counts
    local widest = 0
    for _, count in ipairs(counts) do if count > widest then widest = count end end
    local cells, index = {}, 0
    for row = 1, rows do
        local count = counts[row]
        local rowWidth = count * size + (count - 1) * gap
        local fullWidth = widest * size + (widest - 1) * gap
        for column = 1, count do
            index = index + 1
            cells[index] = {
                row = row, column = column, index = index,
                x = (fullWidth - rowWidth) / 2 + (column - 1) * (size + gap),
                y = (row - 1) * (size + gap),
            }
        end
    end
    local anySize = size > 0
    return {
        buttons = buttons, rows = rows, counts = counts, size = size, gap = gap,
        width = anySize and (widest * size + (widest - 1) * gap) or 0,
        height = anySize and (rows * size + (rows - 1) * gap) or 0,
        cells = cells, sized = anySize,
    }
end

function Model:ActionSlot(idOrKey, index)
    local entry = self:Native(idOrKey)
    if not entry or not entry.slots or type(index) ~= "number" then return nil end
    local slot = entry.slots[1] + index - 1
    if slot > entry.slots[2] then return nil end
    return slot
end
