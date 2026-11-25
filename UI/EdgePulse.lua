local _, app = ...
local Pulse = { active = {} }
app.EdgePulse = Pulse

-- One shared edge animation for every control that wants it: four hairlines grow
-- from the centre of each edge outward, fast and short, then disappear and leave
-- the static ring to hold the state. Settings buttons, the quest indicator and
-- any future dialog use this one class instead of three copies of an OnUpdate.
--
-- The class owns a single driver frame. It keeps no state on the control beyond
-- its four textures, and `Hide` cancels an in-flight run, so a disabled or
-- hidden control never keeps ticking. Everything is display-only: no anchors of
-- the host frame are touched, only the segments' own sizes.
Pulse.duration = 0.12
Pulse.thickness = 1
Pulse.segments = { "top", "bottom", "left", "right" }

local function number(value, fallback)
    value = app.Capabilities.Plain(value, "number")
    return value or fallback
end

local function frameSize(frame)
    local width = number(select(2, pcall(frame.GetWidth, frame)), 1)
    local height = number(select(2, pcall(frame.GetHeight, frame)), 1)
    return math.max(1, width), math.max(1, height)
end

local function segmentsOf(frame)
    local segments = frame.lumaEdgePulse
    if segments then return segments end
    segments = {}
    for _, key in ipairs(Pulse.segments) do
        local texture = frame:CreateTexture(nil, "OVERLAY", nil, 6)
        texture:SetColorTexture(1, 1, 1, 1)
        texture:Hide()
        segments[key] = texture
    end
    -- Anchors are written once; the animation only changes sizes.
    segments.top:SetPoint("BOTTOM", frame, "TOP", 0, 0)
    segments.bottom:SetPoint("TOP", frame, "BOTTOM", 0, 0)
    segments.left:SetPoint("RIGHT", frame, "LEFT", 0, 0)
    segments.right:SetPoint("LEFT", frame, "RIGHT", 0, 0)
    frame.lumaEdgePulse = segments
    return segments
end

-- Ease-out cubic: the fastest change is at the start, so the eye reads the
-- outline snapping outward instead of sliding.
function Pulse:Sample(t)
    t = tonumber(t) or 0
    if t <= 0 then return 0 end
    if t >= 1 then return 1 end
    local inverse = 1 - t
    return 1 - inverse * inverse * inverse
end

-- Size of each segment at `progress`, in the host frame's units. Returned so a
-- test can assert the geometry without asking the client to render.
function Pulse:Layout(frame, progress)
    local segments = frame.lumaEdgePulse
    if not segments then return nil end
    local width, height = frameSize(frame)
    local amount = math.max(0, math.min(1, tonumber(progress) or 0))
    local sizes = {
        top = width * amount, bottom = width * amount,
        left = height * amount, right = height * amount,
    }
    segments.top:SetSize(math.max(0, sizes.top), self.thickness)
    segments.bottom:SetSize(math.max(0, sizes.bottom), self.thickness)
    segments.left:SetSize(self.thickness, math.max(0, sizes.left))
    segments.right:SetSize(self.thickness, math.max(0, sizes.right))
    return sizes
end

-- The driver is a short-lived ticker, not a frame script: it only exists while
-- something is animating, and it cancels itself on the last run. `Tick` stays a
-- pure method so a test can advance an explicit clock without a client timer.
Pulse.step = 1 / 60

function Pulse:EnsureDriver()
    if self.driver then return self.driver end
    if type(C_Timer) ~= "table" or type(C_Timer.NewTicker) ~= "function" then return nil end
    self.driver = C_Timer.NewTicker(self.step, function()
        local running = app.EdgePulse:Tick(GetTime())
        if not running then app.EdgePulse:StopDriver() end
    end)
    return self.driver
end

function Pulse:StopDriver()
    if not self.driver then return end
    if type(self.driver.Cancel) == "function" then pcall(self.driver.Cancel, self.driver) end
    self.driver = nil
end

-- Reduce motion (or motion off) means no run at all: the host keeps its static
-- state and no segment, run record or ticker is created.
local function motionAllowed()
    local transitions = app.Transitions
    return transitions and type(transitions.MotionEnabled) == "function" and transitions.MotionEnabled()
end

function Pulse:Show(frame, color)
    if not frame or type(frame.CreateTexture) ~= "function" then return false end
    if not motionAllowed() then
        self:Hide(frame)
        return false
    end
    local segments = segmentsOf(frame)
    color = color or app.Theme:Accent()
    for _, key in ipairs(self.segments) do
        segments[key]:SetColorTexture(color[1], color[2], color[3], 0.9)
        segments[key]:Show()
    end
    self:Layout(frame, 0)
    self.active[frame] = { started = GetTime(), duration = self.duration }
    self:EnsureDriver()
    return true
end

function Pulse:Hide(frame)
    if not frame then return end
    self.active[frame] = nil
    local segments = frame.lumaEdgePulse
    if segments then
        for _, key in ipairs(self.segments) do segments[key]:Hide() end
    end
    if next(self.active) == nil then self:StopDriver() end
end

-- Named for the lifecycle: a component stopping calls this and the frame is left
-- with no visible layer and no pending tick.
function Pulse:Release(frame)
    self:Hide(frame)
end

function Pulse:Stop()
    for frame in pairs(self.active) do self:Hide(frame) end
    self:StopDriver()
end

-- Advances every run. Returns whether anything is still animating, which the
-- driver uses to stop itself. Tests call this with an explicit clock.
function Pulse:Tick(now)
    now = tonumber(now) or 0
    -- Reduce motion switched on mid-run: converge at once instead of finishing.
    if next(self.active) ~= nil and not motionAllowed() then
        self:Stop()
        return false
    end
    local any = false
    local finished = nil
    for frame, state in pairs(self.active) do
        local progress = (now - state.started) / state.duration
        if progress >= 1 then
            finished = finished or {}
            finished[#finished + 1] = frame
        else
            self:Layout(frame, self:Sample(progress))
            any = true
        end
    end
    for _, frame in ipairs(finished or {}) do self:Hide(frame) end
    return any
end
