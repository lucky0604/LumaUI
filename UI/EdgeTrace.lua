local _, app = ...

-- A hover trace for buttons LumaUI only decorates. It differs from EdgePulse on
-- purpose: the pulse grows four short lines and then vanishes, which is a
-- notification; the trace walks the whole perimeter from 0 to 1 and stays there
-- while the pointer rests on the control, so it can carry a persistent hover
-- state. Leaving reverses from the progress that is on screen, so a quick
-- in-and-out never flashes a full ring or restarts from zero.
--
-- Geometry (perimeter walk): with `d = progress * (W + H)`, the first path draws
-- the top edge, then the right edge downwards; the second path draws the left
-- edge downwards, then the bottom edge to the right. Each segment is anchored at
-- the corner the walk starts from, so a growing segment never moves the others.
--
-- Only LumaUI's own textures and its shared transition driver are used. The
-- host's scripts, text, size and hit area are never touched.

local Trace = { enterDuration = 0.16, leaveDuration = 0.10 }
app.EdgeTrace = Trace

local SEGMENTS = { "top", "right", "bottom", "left" }

local function plain(value, fallback)
    value = app.Capabilities.Plain(value, "number")
    if not value or value ~= value or value == math.huge or value == -math.huge then return fallback end
    return value
end

local function hostSize(frame)
    local okWidth, width = pcall(frame.GetWidth, frame)
    local okHeight, height = pcall(frame.GetHeight, frame)
    width = okWidth and plain(width, 0) or 0
    height = okHeight and plain(height, 0) or 0
    return math.max(0, width), math.max(0, height)
end

local function ensureTextures(frame)
    local state = frame.lumaTrace
    if type(state) == "table" and state.segments then return state end
    local segments = {}
    for index, key in ipairs(SEGMENTS) do
        local texture = frame:CreateTexture(nil, "OVERLAY", nil, 7)
        texture:SetColorTexture(1, 1, 1, 0)
        texture:Hide()
        segments[key] = texture
        segments[index] = texture
    end
    -- Anchors are written once. Each edge grows away from the corner the walk
    -- starts at: top and left from the top-left, right from the top-right, bottom
    -- from the bottom-left.
    segments.top:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
    segments.right:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
    segments.bottom:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 0, 0)
    segments.left:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
    state = { segments = segments, progress = 0, generation = (state and state.generation or 0) + 1 }
    frame.lumaTrace = state
    return state
end

-- Per-edge lengths for a progress value. Returned so a test can assert the walk
-- formula without asking the client to render anything.
function Trace:Lengths(width, height, progress)
    progress = math.max(0, math.min(1, plain(progress, 0)))
    local distance = progress * (width + height)
    local function clamp(value, low, high)
        if value < low then return low end
        if value > high then return high end
        return value
    end
    -- Path 1: top, then the right edge downwards. Path 2: left edge downwards,
    -- then the bottom edge to the right.
    return {
        top = math.min(distance, width),
        right = clamp(distance - width, 0, height),
        left = math.min(distance, height),
        bottom = clamp(distance - height, 0, width),
    }
end

-- Draws the edges at `progress`; the state is the single source for the next
-- reversal. Zero-length segments are hidden, not left as a 0-size shader.
function Trace:Draw(frame, progress, color)
    if not frame or type(frame.lumaTrace) ~= "table" then return nil end
    local state = frame.lumaTrace
    progress = math.max(0, math.min(1, plain(progress, 0)))
    state.progress = progress
    local width, height = hostSize(frame)
    if width <= 0 or height <= 0 then
        for _, key in ipairs(SEGMENTS) do state.segments[key]:Hide() end
        return nil
    end
    local lengths = self:Lengths(width, height, progress)
    local thickness = app.Pixel:Pixels(1, frame)
    if thickness <= 0 then thickness = 1 end
    color = color or state.color or app.Theme:Accent()
    state.color = color
    local alpha = state.alpha or 0.9
    for _, key in ipairs(SEGMENTS) do
        local texture = state.segments[key]
        local length = lengths[key]
        if length > 0.01 then
            if key == "top" or key == "bottom" then
                texture:SetSize(length, thickness)
            else
                texture:SetSize(thickness, length)
            end
            texture:SetColorTexture(color[1], color[2], color[3], alpha)
            texture:Show()
        else
            texture:Hide()
        end
    end
    return lengths
end

local function animate(frame, target, duration)
    local state = frame and frame.lumaTrace
    if not state then return end
    local function apply(value)
        if frame.lumaTrace ~= state then return end
        -- Reduce motion switched on mid-run: settle at the requested end state
        -- instead of finishing the walk.
        if not app.Transitions.MotionEnabled() then
            app.Transitions:Cancel(state, "trace")
            return Trace:Draw(frame, target)
        end
        Trace:Draw(frame, value)
    end
    -- Start from the value on screen, never from the requested target: a fast
    -- leave during the entrance has to keep the part already drawn.
    app.Transitions:Animate(state, "trace", {
        from = state.progress or 0, to = target, duration = duration, apply = apply,
    })
end

-- Mouse entered: grow to a full ring (or draw it at once with motion off) and
-- keep it. A repeated enter for the same state is a no-op.
function Trace:Enter(frame, color, instant)
    if not frame then return end
    local state = ensureTextures(frame)
    if color then state.color = color end
    if instant or not app.Transitions.MotionEnabled() then
        return self:Draw(frame, 1)
    end
    if state.progress >= 1 then return self:Draw(frame, 1) end
    animate(frame, 1, self.enterDuration)
end

-- Mouse left: reverse from the current progress. The final draw at 0 hides
-- every edge, which is the only cleanup a resting pointer needs.
function Trace:Leave(frame)
    if not frame or type(frame.lumaTrace) ~= "table" then return end
    local state = frame.lumaTrace
    state.alpha = 0.9
    local accent = app.Theme:Accent()
    state.color = accent
    if not app.Transitions.MotionEnabled() then
        app.Transitions:Cancel(state, "trace")
        return self:Draw(frame, 0)
    end
    if state.progress <= 0 then return self:Draw(frame, 0) end
    animate(frame, 0, self.leaveDuration)
end

-- Static line for the current state, used for focus and reduce-motion.
function Trace:Set(frame, progress, color)
    if not frame then return end
    ensureTextures(frame)
    return self:Draw(frame, progress, color)
end

-- Drops everything this class created for `frame`: the transition, the visible
-- edges, the remembered progress and the colour. A pooled host that becomes a
-- different menu entry must not inherit a half-drawn ring.
function Trace:Release(frame)
    if not frame then return end
    local state = frame.lumaTrace
    if type(state) ~= "table" then return end
    app.Transitions:Cancel(state, "trace")
    if state.segments then
        for _, key in ipairs(SEGMENTS) do state.segments[key]:Hide() end
    end
    frame.lumaTrace = nil
end

-- Pressed feedback: the same drawn ring in a brighter colour, no progress change.
function Trace:Press(frame, pressed)
    local state = frame and frame.lumaTrace
    if not state then return end
    local accent = app.Theme:Accent()
    state.alpha = pressed and 1 or 0.9
    self:Draw(frame, state.progress or 0, pressed and { math.min(1, accent[1] * 1.35),
        math.min(1, accent[2] * 1.35), math.min(1, accent[3] * 1.35) } or accent)
end
