local _, app = ...
local Transitions = { tasks = {}, count = 0, generation = 0 }
app.Transitions = Transitions

-- Transition contract:
--   owner    the component or frame that owns the transition (any table/string)
--   channel  one property of that owner ("open", "page", "hover", ...)
--   token    a per-start generation, so a completion callback can never belong
--            to a request that was already replaced
-- One owner/channel pair holds at most one task: a new request replaces the old
-- one and continues from the value that is on screen right now. Replaced tasks
-- never run their callback; settled tasks apply the target state and do run it,
-- so a closed window can never stay clickable at alpha 0.
--
-- Alpha uses the client's own AnimationGroup (native interpolation, no Lua per
-- frame). Value channels (for example a decorative colour mix) use one shared
-- ticker that only exists while at least one such task is active; it cancels
-- itself when the queue is empty, so an idle client has no transition driver.
-- Combat data (health, casts, cooldowns) must never be routed through here.

local STEP = 0.016
local paintTasks = {}
local driver

local function appearance()
    local store = app.Store
    if not store or not store.data then return nil end
    local ok, profile = pcall(store.Profile, store)
    if not ok or not profile then return nil end
    return profile.appearance
end

local function motionWanted()
    local look = appearance()
    if not look then return false end
    if look.motion ~= true then return false end
    if look.reduceMotion == true then return false end
    return true
end
Transitions.MotionEnabled = motionWanted

local function stopDriver()
    if not driver then return end
    if type(driver.Cancel) == "function" then driver:Cancel() end
    driver = nil
end

-- Transitions only ever drive LumaUI's own decoration. A forbidden frame is
-- never touched: no alpha write, no animation group, no completion callback.
local function isForbidden(frame)
    if not frame or type(frame.IsForbidden) ~= "function" then return false end
    local ok, value = pcall(frame.IsForbidden, frame)
    return ok and value == true
end

local function startDriver()
    if driver then return end
    if type(C_Timer) ~= "table" or type(C_Timer.NewTicker) ~= "function" then return end
    driver = C_Timer.NewTicker(STEP, function()
        if Transitions.count == 0 then stopDriver(); return end
        app:Call("transitions/step", Transitions.Step, Transitions, STEP)
    end)
end

function Transitions:HasDriver()
    return driver ~= nil
end

function Transitions:Count()
    return self.count
end

local function removeTask(task)
    if not task or task.dead then return end
    task.dead = true
    -- A frame owns one alpha group; only stop it when it is still ours, so one
    -- owner settling never stops another owner's fade on the same frame.
    if task.group and task.group.lumaTask == task then
        pcall(task.group.Stop, task.group)
    end
    task.group = nil
    local set = Transitions.tasks[task.owner]
    if set and set[task.channel] == task then
        set[task.channel] = nil
        if next(set) == nil then Transitions.tasks[task.owner] = nil end
    end
    task.owner = nil
    task.apply = nil
    task.onDone = nil
    Transitions.count = math.max(0, Transitions.count - 1)
end

-- Immediate final state without a callback: used when a request is replaced.
local function dropTask(task)
    removeTask(task)
end

local function finishTask(task)
    if not task or task.dead then return end
    local onDone = task.onDone
    if task.kind == "alpha" then
        if task.frame and type(task.frame.SetAlpha) == "function" then
            pcall(task.frame.SetAlpha, task.frame, task.to)
        end
    elseif task.apply then
        -- One reporting context for every paint call, so a failing callback is
        -- counted once instead of once per step plus once for the final value.
        app:Call("transitions/apply", task.apply, task.to, 1)
    end
    removeTask(task)
    if onDone then app:Call("transitions/done", onDone, true) end
end

function Transitions:_startFade(task)
    local frame = task.frame
    if not frame or type(frame.CreateAnimationGroup) ~= "function" then
        return finishTask(task)
    end
    local ok, current = pcall(frame.GetAlpha, frame)
    local from = ok and app.Capabilities.Plain(current, "number") or task.from or 1
    task.from = from
    if from == task.to then return finishTask(task) end
    local group = frame.lumaFade
    if not group then
        group = frame:CreateAnimationGroup()
        group.lumaAnchor = frame
        group:SetScript("OnFinished", function(self)
            local active = self.lumaTask
            if not active or active.dead then return end
            if active.generation ~= self.lumaToken then return end
            finishTask(active)
        end)
        frame.lumaFade = group
    end
    if type(group.Stop) == "function" then pcall(group.Stop, group) end
    local anim = group.lumaAlpha
    if not anim then
        anim = group:CreateAnimation("Alpha")
        group.lumaAlpha = anim
    end
    anim:SetFromAlpha(from)
    anim:SetToAlpha(task.to)
    anim:SetDuration(task.duration)
    anim:SetSmoothing(task.easing == "linear" and "NONE" or "OUT")
    group.lumaTask = task
    group.lumaToken = task.generation
    task.group = group
    group:Play()
end

-- Starts (or replaces) one channel. Returns the task, or nil when the change
-- was applied immediately (motion off, zero duration or no visible difference).
function Transitions:Start(owner, channel, spec)
    if owner == nil then return nil end
    channel = type(channel) == "string" and channel or "alpha"
    spec = spec or {}
    if isForbidden(spec.frame) then return nil end
    local set = self.tasks[owner]
    if set and set[channel] then dropTask(set[channel]) end
    local duration = app.Capabilities.Plain(spec.duration, "number") or 0
    if not motionWanted() or duration <= 0 then
        if spec.kind == "alpha" and spec.frame and type(spec.frame.SetAlpha) == "function" then
            pcall(spec.frame.SetAlpha, spec.frame, spec.to)
        elseif spec.apply then
            app:Call("transitions/apply", spec.apply, spec.to, 1)
        end
        if spec.onDone then app:Call("transitions/done", spec.onDone, true) end
        return nil
    end
    self.generation = self.generation + 1
    local task = {
        owner = owner, channel = channel, generation = self.generation,
        kind = spec.kind == "alpha" and "alpha" or "value",
        frame = spec.frame, from = spec.from, to = spec.to, duration = duration,
        elapsed = 0, apply = spec.apply, onDone = spec.onDone,
        easing = spec.easing or "out",
    }
    set = self.tasks[owner]
    if not set then set = {}; self.tasks[owner] = set end
    set[channel] = task
    self.count = self.count + 1
    if task.kind == "alpha" then
        self:_startFade(task)
    else
        paintTasks[#paintTasks + 1] = task
        startDriver()
    end
    return task
end

-- Alpha helper: fades a frame to `toAlpha` from its current value.
function Transitions:Fade(owner, frame, toAlpha, duration, onDone, channel)
    local from = 1
    if frame and type(frame.GetAlpha) == "function" then
        local ok, value = pcall(frame.GetAlpha, frame)
        from = ok and app.Capabilities.Plain(value, "number") or 1
    end
    return self:Start(owner, channel or "alpha", {
        kind = "alpha", frame = frame, from = from, to = toAlpha,
        duration = duration, onDone = onDone,
    })
end

-- Value helper: interpolates from -> to and calls apply(value, progress) each
-- step. Only for public decoration; never for combat numbers.
function Transitions:Animate(owner, channel, spec)
    spec = spec or {}
    spec.kind = "value"
    return self:Start(owner, channel, spec)
end

-- Advances the value-channel queue. The driver calls this; tests advance the
-- same way, so completion and cancellation are exercised, not mocked away.
function Transitions:Step(seconds)
    local dt = app.Capabilities.Plain(seconds, "number") or 0
    if dt <= 0 then return end
    local finished
    for _, task in ipairs(paintTasks) do
        if not task.dead then
            task.elapsed = task.elapsed + dt
            local progress = task.duration > 0 and math.min(1, task.elapsed / task.duration) or 1
            local eased = task.easing == "linear" and progress or (1 - (1 - progress) ^ 3)
            local value = task.from + (task.to - task.from) * eased
            if task.apply then app:Call("transitions/apply", task.apply, value, progress) end
            if progress >= 1 then
                finished = finished or {}
                finished[#finished + 1] = task
            end
        end
    end
    if finished then
        for _, task in ipairs(finished) do finishTask(task) end
    end
    local keep = {}
    for _, task in ipairs(paintTasks) do
        if not task.dead then keep[#keep + 1] = task end
    end
    paintTasks = keep
    if #paintTasks == 0 then stopDriver() end
end

-- Applies the target state now and runs the completion callback. Used for
-- hide, disable, profile switches and "reduce motion".
function Transitions:Settle(owner, channel)
    local set = owner ~= nil and self.tasks[owner]
    if not set then return end
    local list = {}
    for name, task in pairs(set) do
        if not channel or name == channel then list[#list + 1] = task end
    end
    for _, task in ipairs(list) do finishTask(task) end
end

function Transitions:Cancel(owner, channel)
    local set = owner ~= nil and self.tasks[owner]
    if not set then return end
    local list = {}
    for name, task in pairs(set) do
        if not channel or name == channel then list[#list + 1] = task end
    end
    for _, task in ipairs(list) do dropTask(task) end
end

function Transitions:SettleAll()
    local owners = {}
    for owner in pairs(self.tasks) do owners[#owners + 1] = owner end
    for _, owner in ipairs(owners) do self:Settle(owner) end
end

-- Compatibility adapter for the previous one-shot reveal: the inventory, bank
-- and settings windows call it on show. Motion off means an immediate final
-- state, never a frame left at zero alpha.
function Transitions:Reveal(frame)
    if not frame or isForbidden(frame) then return end
    if not motionWanted() then
        if type(frame.SetAlpha) == "function" then frame:SetAlpha(1) end
        return
    end
    frame:SetAlpha(0)
    self:Fade(frame, frame, 1, 0.16, nil, "reveal")
end
