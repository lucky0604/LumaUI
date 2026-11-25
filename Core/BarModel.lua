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
