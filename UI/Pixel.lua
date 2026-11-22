local _, app = ...
local Pixel = {}
app.Pixel = Pixel

-- One physical screen pixel expressed in UI units at the current effective
-- scale. Every call reads the live scale: a UI scale change (or a window with
-- its own scale) needs no cached value, and LumaUI never writes UIParent's
-- scale to get a crisp edge.
function Pixel:Scale(frame)
    local parent = frame or _G.UIParent
    local scale = parent and type(parent.GetEffectiveScale) == "function"
        and parent:GetEffectiveScale()
    scale = app.Capabilities.Plain(scale, "number")
    if not scale or scale <= 0 then return 1 end
    return scale
end

function Pixel:Unit()
    return self:Pixels(1)
end

-- A count of physical pixels expressed in UI units: exact, no rounding (one
-- pixel is already on the grid by definition).
function Pixel:Pixels(count, frame)
    local value = app.Capabilities.Plain(count, "number") or 0
    if value <= 0 then return 0 end
    return value / self:Scale(frame)
end

-- Snap a size to whole physical pixels. A positive size is never smaller than
-- one pixel, so a hairline stays visible at 1x, 1.5x and 2x; zero stays zero so
-- "no edge" is still expressible.
function Pixel:Size(units)
    local value = app.Capabilities.Plain(units, "number") or 0
    if value <= 0 then return 0 end
    local scale = self:Scale()
    local snapped = math.floor(value * scale + 0.5) / scale
    local minimum = 1 / scale
    if snapped < minimum then snapped = minimum end
    return snapped
end

-- Snap an offset, keeping its sign; an exact zero stays zero.
function Pixel:Offset(units)
    local value = app.Capabilities.Plain(units, "number") or 0
    if value == 0 then return 0 end
    local scale = self:Scale()
    local snapped = math.floor(math.abs(value) * scale + 0.5) / scale
    local minimum = 1 / scale
    if snapped < minimum then snapped = minimum end
    return value < 0 and -snapped or snapped
end
