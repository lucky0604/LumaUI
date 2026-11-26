local _, app = ...

-- Placement rules that need no frame: rectangles in UIParent units with the
-- origin at the bottom-left corner of the screen, `{ left, bottom, right, top }`.
-- The unlock mode previews with these functions and the commit writes their
-- result, so a preview can never differ from the placement that is saved.
local Geometry = { grid = 16, range = 8 }
app.Geometry = Geometry

local floor, abs = math.floor, math.abs

function Geometry.Rect(centerX, centerY, width, height)
    return { centerX - width / 2, centerY - height / 2, centerX + width / 2, centerY + height / 2 }
end

function Geometry.Size(rect) return rect[3] - rect[1], rect[4] - rect[2] end

function Geometry.Center(rect) return (rect[1] + rect[3]) / 2, (rect[2] + rect[4]) / 2 end

-- Centre offset from the screen centre, the shape every saved position uses.
function Geometry.ToOffset(rect, screen)
    local x, y = Geometry.Center(rect)
    return x - screen.width / 2, y - screen.height / 2
end

function Geometry.FromOffset(x, y, width, height, screen)
    return Geometry.Rect(screen.width / 2 + x, screen.height / 2 + y, width, height)
end

function Geometry.Move(rect, dx, dy)
    return { rect[1] + dx, rect[2] + dy, rect[3] + dx, rect[4] + dy }
end

-- Keeps the rectangle inside the screen with a margin; a rectangle larger than
-- the space is centred instead of flipping sides.
function Geometry.Clamp(rect, screen, margin)
    margin = margin or 0
    local width, height = Geometry.Size(rect)
    local function axis(low, size, limit)
        local minimum, maximum = margin, limit - margin - size
        if maximum < minimum then return (limit - size) / 2 end
        return math.max(minimum, math.min(maximum, low))
    end
    local left, bottom = axis(rect[1], width, screen.width), axis(rect[2], height, screen.height)
    return { left, bottom, left + width, bottom + height }
end

function Geometry.Outside(rect, screen)
    return rect[1] < 0 or rect[2] < 0 or rect[3] > screen.width or rect[4] > screen.height
end

function Geometry.Overlap(a, b)
    return a[1] < b[3] and b[1] < a[3] and a[2] < b[4] and b[2] < a[4]
end

-- Rounds a UI-unit value onto a whole physical pixel. `scale` is the frame's
-- effective scale; the rounding happens once, on the final coordinate.
function Geometry.Pixel(value, scale)
    if not scale or scale <= 0 then return value end
    return floor(value * scale + 0.5) / scale
end

local RANK = { rect = 1, screen = 2, grid = 3 }

local function lines(rect, axis)
    if axis == "x" then return { rect[1], (rect[1] + rect[3]) / 2, rect[3] } end
    return { rect[2], (rect[2] + rect[4]) / 2, rect[4] }
end

local function candidates(rect, axis, others, screen, grid)
    local list, own = {}, lines(rect, axis)
    local limit = axis == "x" and screen.width or screen.height
    for index, value in ipairs(own) do
        local function add(line, kind, id)
            list[#list + 1] = { delta = line - value, line = line, kind = kind, id = id or "", own = index }
        end
        add(0, "screen"); add(limit / 2, "screen"); add(limit, "screen")
        for _, other in ipairs(others or {}) do
            if other.rect and other.visible ~= false then
                for _, line in ipairs(lines(other.rect, axis)) do add(line, "rect", other.id) end
            end
        end
        if grid and grid > 0 then
            local base = floor(value / grid) * grid
            add(base, "grid"); add(base + grid, "grid")
        end
    end
    return list
end

local function better(a, b)
    local da, db = abs(a.delta), abs(b.delta)
    if da ~= db then return da < db end
    if RANK[a.kind] ~= RANK[b.kind] then return RANK[a.kind] < RANK[b.kind] end
    if a.id ~= b.id then return a.id < b.id end
    if a.line ~= b.line then return a.line < b.line end
    return a.own < b.own
end

-- Chooses the closest guide on each axis inside `range`. Ties break by kind
-- (another component, then the screen, then the grid), then id, line and edge,
-- so the same input always yields the same placement. Returns the offset to add
-- plus the guides that explain it.
function Geometry.Snap(rect, opts)
    opts = opts or {}
    local screen = opts.screen
    local range = opts.range or Geometry.range
    local result = { dx = 0, dy = 0 }
    for _, axis in ipairs({ "x", "y" }) do
        local best
        for _, candidate in ipairs(candidates(rect, axis, opts.others, screen, opts.grid)) do
            if abs(candidate.delta) <= range and (not best or better(candidate, best)) then best = candidate end
        end
        if best then
            result[axis == "x" and "dx" or "dy"] = best.delta
            result[axis == "x" and "guideX" or "guideY"] = { line = best.line, kind = best.kind, id = best.id }
        end
    end
    return result
end

local POINTS = {
    TOPLEFT = { 0, 1 }, TOP = { 0.5, 1 }, TOPRIGHT = { 1, 1 },
    LEFT = { 0, 0.5 }, CENTER = { 0.5, 0.5 }, RIGHT = { 1, 0.5 },
    BOTTOMLEFT = { 0, 0 }, BOTTOM = { 0.5, 0 }, BOTTOMRIGHT = { 1, 0 },
}
Geometry.points = POINTS

function Geometry.ValidPoint(point) return POINTS[point] ~= nil end

function Geometry.PointOf(rect, point)
    local factor = POINTS[point] or POINTS.CENTER
    return rect[1] + (rect[3] - rect[1]) * factor[1], rect[2] + (rect[4] - rect[2]) * factor[2]
end

-- The offset that makes `point` of `rect` sit at `targetPoint` of `target` plus
-- (x, y); the inverse of `Place`.
function Geometry.AnchorOffset(rect, point, target, targetPoint)
    local sx, sy = Geometry.PointOf(rect, point)
    local tx, ty = Geometry.PointOf(target, targetPoint)
    return sx - tx, sy - ty
end

-- Where a rectangle of `width` x `height` lands when its `point` is anchored to
-- `targetPoint` of `target` with an offset.
function Geometry.Place(width, height, point, target, targetPoint, x, y)
    local tx, ty = Geometry.PointOf(target, targetPoint)
    local factor = POINTS[point] or POINTS.CENTER
    local left = tx + (x or 0) - width * factor[1]
    local bottom = ty + (y or 0) - height * factor[2]
    return { left, bottom, left + width, bottom + height }
end

-- `links` maps an id to the id it follows. A new link from `id` to `target` is
-- refused when it points at itself or would close a loop.
function Geometry.WouldCycle(links, id, target)
    if id == target then return true end
    local seen, step = { [id] = true }, target
    while step do
        if seen[step] then return true end
        seen[step] = true
        step = links[step]
    end
    return false
end

-- Spec shape saved with a position: `target` is a layout id or "screen".
function Geometry.CleanAnchor(spec)
    if type(spec) ~= "table" or type(spec.target) ~= "string" or spec.target == "" then return nil end
    local function number(value)
        if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then return nil end
        return math.max(-20000, math.min(20000, value))
    end
    local point, targetPoint = spec.point or "CENTER", spec.targetPoint or "CENTER"
    if not POINTS[point] or not POINTS[targetPoint] then return nil end
    return { target = spec.target, point = point, targetPoint = targetPoint,
        x = number(spec.x) or 0, y = number(spec.y) or 0 }
end
