local addonName, app = ...
_G.LumaUI = app
app.name = addonName
app.apiVersion = 1
app.version = C_AddOns.GetAddOnMetadata(addonName, "Version") or "dev"
app.components, app.order, app.messages, app.errors = {}, {}, {}, {}

function app:Print(message)
    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage("|cff5edbd5LumaUI|r  " .. tostring(message))
    end
end

function app:Report(context, message)
    message = tostring(message)
    for _, existing in ipairs(self.errors) do
        if existing.context == context and existing.message == message then
            existing.count = existing.count + 1
            return
        end
    end
    local record = { context = context, message = message, count = 1 }
    self.errors[#self.errors + 1] = record
    if #self.errors > 20 then table.remove(self.errors, 1) end
    self:Print(context .. ": " .. record.message)
end

function app:Call(context, fn, ...)
    local args, count = { ... }, select("#", ...)
    local ok, result = xpcall(function() return fn(unpack(args, 1, count)) end,
        function(err) return tostring(err) end)
    if not ok then self:Report(context, result) end
    return ok, result
end

function app:Subscribe(owner, message, callback)
    self:Unsubscribe(owner, message)
    local list = self.messages[message] or {}
    self.messages[message] = list
    list[#list + 1] = { owner = owner, callback = callback }
end

function app:Unsubscribe(owner, message)
    for key, list in pairs(self.messages) do
        if not message or message == key then
            for i = #list, 1, -1 do
                if list[i].owner == owner then table.remove(list, i) end
            end
        end
    end
end

function app:Publish(message, ...)
    local snapshot = {}
    for i, entry in ipairs(self.messages[message] or {}) do snapshot[i] = entry end
    for _, entry in ipairs(snapshot) do self:Call(message, entry.callback, ...) end
end
