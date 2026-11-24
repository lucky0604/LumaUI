local _, app = ...
local Grid = {}
app.CentralGrid = Grid

-- Pure geometry for the central HUD. Nothing here touches a frame: given a
-- count of icons, their measured size and the space available, it answers where
-- each row starts and where each icon sits. The cooldown component feeds the
-- result to native buttons, the preset preview draws the same rectangles, and
-- the tests assert on the numbers instead of on a mocked frame.
--
-- Rules taken from the mockup:
--   * every row is centred on its own axis, so a short last row is not left
--     aligned with the full row above it;
--   * a row holds at most `max` icons (essential 9, utility 7);
--   * when the available width cannot hold that many, the per-row capacity
--     shrinks to whole icons and the overflow becomes continuation rows of the
--     same size instead of a wider row;
--   * zero icons produce no rows at all, and one icon is still centred.
--
-- Coordinates are UIParent units: `x` is the centre offset from the block axis,
-- `y` the centre offset from the block's bottom edge.
Grid.styles = {
    essential = { max = 9, gap = 4, rowGap = 4, widthRatio = 0.17 },
    utility = { max = 7, gap = 4, rowGap = 4, widthRatio = 0.17 },
    buffIcon = { max = 12, gap = 3, rowGap = 3, widthRatio = 0.17 },
    buffBar = { max = 1, gap = 4, rowGap = 3, widthRatio = 0.17 },
}

local function number(value, fallback)
    value = app.Capabilities.Plain(value, "number")
    if value == nil or value ~= value then return fallback end
    return value
end

function Grid:Style(id)
    return self.styles[id] or self.styles.utility
end

-- Row layout for `count` icons of `size`. `maxWidth` is the width the row may
-- not exceed; `max` still caps it. Returns an empty plan for zero or negative
-- counts and for an unreadable size, so a caller never divides by zero.
function Grid:Plan(spec)
    spec = spec or {}
    local count = math.floor(number(spec.count, 0))
    local size = number(spec.size, 0)
    local style = self:Style(spec.style)
    local gap = math.max(0, number(spec.gap, style.gap))
    local rowGap = math.max(0, number(spec.rowGap, style.rowGap))
    local maxPerRow = math.max(1, math.floor(number(spec.max, style.max)))
    local maxWidth = number(spec.maxWidth, 0)
    local plan = { count = 0, rows = {}, slots = {}, width = 0, height = 0, perRow = 0 }
    if count < 1 or size <= 0 then return plan end
    if maxWidth > 0 then
        local fits = math.floor((maxWidth + gap) / (size + gap))
        if fits < 1 then fits = 1 end
        if fits < maxPerRow then maxPerRow = fits end
    end
    plan.count = count
    plan.perRow = maxPerRow
    -- Width of a full row at this capacity. A viewer with two active skills
    -- still reserves the row a full grid would use, so the unit frames do not
    -- drift every time a cooldown comes up.
    plan.capacity = maxPerRow * size + (maxPerRow - 1) * gap
    local rowCount = math.ceil(count / maxPerRow)
    local x = 0
    for column = 1, count do
        local rowIndex = math.floor((column - 1) / maxPerRow) + 1
        local row = plan.rows[rowIndex]
        if not row then
            local first = (rowIndex - 1) * maxPerRow + 1
            row = { index = rowIndex, first = first, count = math.min(maxPerRow, count - first + 1) }
            row.width = row.count * size + (row.count - 1) * gap
            row.left = -row.width / 2
            row.y = (rowIndex - 1) * (size + rowGap)
            plan.rows[rowIndex] = row
        end
        local columnIndex = (column - 1) % maxPerRow
        x = row.left + columnIndex * (size + gap) + size / 2
        plan.slots[column] = {
            index = column, row = rowIndex, column = columnIndex + 1,
            size = size, x = x, y = row.y + size / 2,
        }
        if row.width > plan.width then plan.width = row.width end
    end
    plan.height = rowCount * size + (rowCount - 1) * rowGap
    return plan
end

-- Rectangles for a list of groups, stacked bottom to top from `bottom`. Each
-- item is `{ id, plan }` (a group of icons) or `{ id, width, height }` (a
-- measured native frame). Used by the geometry report and the preset preview so
-- every participating area is described by the same numbers.
function Grid:Stack(items, gap, bottom)
    gap = math.max(0, number(gap, 0))
    local y = number(bottom, 0)
    local placed = {}
    for _, item in ipairs(items or {}) do
        local plan = item.plan
        local height = number(item.height, plan and plan.height or 0)
        local width = number(item.width, plan and plan.width or 0)
        if height and height > 0 then
            placed[#placed + 1] = {
                id = item.id, plan = plan, width = width, height = height,
                bottom = y, top = y + height, center = y + height / 2,
            }
            y = y + height + gap
        end
    end
    return { items = placed, bottom = number(bottom, 0), top = #placed > 0 and placed[#placed].top or number(bottom, 0) }
end

-- The widest row of a plan, or 0. Kept explicit so callers do not re-walk rows
-- with subtly different rules.
function Grid:Width(plan)
    return plan and number(plan.width, 0) or 0
end
