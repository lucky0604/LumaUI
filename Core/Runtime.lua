local _, app = ...
local Queue = { jobs = {}, order = {} }
app.Queue = Queue

function Queue:Run(key, callback)
    if not InCombatLockdown() then
        app:Call(key, callback)
        return true
    end
    if not self.jobs[key] then
        if #self.order >= 256 then app:Report("queue", "Capacity reached"); return false end
        self.order[#self.order + 1] = key
    end
    self.jobs[key] = callback
    return false
end

function Queue:Flush()
    if InCombatLockdown() then return end
    local jobs, order = self.jobs, self.order
    self.jobs, self.order = {}, {}
    for _, key in ipairs(order) do self:Run(key, jobs[key]) end
end

function Queue:Count() return #self.order end

local Component = {}
function Component:Listen(event, callback, unit)
    if not self.events then
        self.events = CreateFrame("Frame")
        self.handlers = {}
        self.events:SetScript("OnEvent", function(_, name, ...)
            local fn = self.handlers[name]
            if self.running and fn then app:Call(self.id .. "/" .. name, fn, self, name, ...) end
        end)
    end
    self.handlers[event] = callback
    -- RegisterEvent throws on event names the current build lacks; a single
    -- unknown event must not fail the whole component enable, so the
    -- registration is guarded and the handler simply never fires.
    if unit then
        pcall(self.events.RegisterUnitEvent, self.events, event, unit)
    else
        pcall(self.events.RegisterEvent, self.events, event)
    end
end

function Component:Every(seconds, callback)
    local timer = C_Timer.NewTicker(seconds, function()
        if self.running then app:Call(self.id .. "/timer", callback, self) end
    end)
    self.timers = self.timers or {}
    self.timers[#self.timers + 1] = timer
    return timer
end

function Component:Cleanup()
    if self.events then self.events:UnregisterAllEvents(); self.handlers = {} end
    for _, timer in ipairs(self.timers or {}) do timer:Cancel() end
    self.timers = {}
    app:Unsubscribe(self)
end

function app:RegisterComponent(spec)
    assert(type(spec.id) == "string" and spec.id:match("^[%a][%w_]*$"), "Invalid component id")
    assert(not self.components[spec.id], "Duplicate component id: " .. spec.id)
    assert(type(spec.Enable) == "function" and type(spec.Disable) == "function", "Lifecycle methods required")
    setmetatable(spec, { __index = Component })
    spec.status = "disabled"
    self.components[spec.id] = spec
    self.order[#self.order + 1] = spec.id
    if self.Store.defaults.modules[spec.id] == nil then self.Store.defaults.modules[spec.id] = spec.defaultEnabled == true end
    if self.ready then
        for _, profile in pairs(self.Store.data.profiles) do
            if profile.modules[spec.id] == nil then profile.modules[spec.id] = spec.defaultEnabled == true end
        end
        self:Reconcile()
    end
    return spec
end

function app:StopComponent(component)
    component.running = false
    self:Call(component.id .. "/disable", component.Disable, component)
    component:Cleanup()
end

function app:Reconcile()
    if not self.ready then return end
    self.Queue:Run("runtime/reconcile", function()
        if self.Layout.editing then self.Layout:SetEditing(false) end
        local profile, visiting, resolved = self.Store:Profile(), {}, {}
        local function activate(id)
            if resolved[id] ~= nil then return resolved[id] end
            local component = self.components[id]
            if not component then return false end
            local wanted = profile.modules[id] == true
            local status = wanted and "running" or "disabled"
            if visiting[id] then
                self:Report(id, "Dependency cycle")
                return false
            end
            visiting[id] = true
            if wanted and component.Supported then
                local ok, supported = self:Call(id .. "/capability", component.Supported, component, self.Capabilities.Snapshot())
                if not ok or not supported then wanted, status = false, ok and "unsupported" or "failed" end
            end
            if wanted then
                for _, dependency in ipairs(component.requires or {}) do
                    if not activate(dependency) then wanted, status = false, "dependency"; break end
                end
            end
            visiting[id] = nil
            if wanted then
                if not component.running then
                    component.running = true
                    local ok = self:Call(id .. "/enable", component.Enable, component)
                    if not ok then self:StopComponent(component); status = "failed" end
                end
                if component.running and component.Refresh then
                    local ok = self:Call(id .. "/refresh", component.Refresh, component)
                    if not ok then self:StopComponent(component); status = "failed" end
                end
            elseif component.running then
                self:StopComponent(component)
            end
            component.status = status
            resolved[id] = component.running == true
            return resolved[id]
        end
        for _, id in ipairs(self.order) do activate(id) end
        self.Layout:ApplyAll()
        self:Publish("RUNTIME_UPDATED")
    end)
end
