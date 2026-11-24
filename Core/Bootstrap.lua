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

-- Runs a chat report into a list instead of the chat frame. Used by
-- `/luma dump`, which writes the same text into SavedVariables so a reader (a
-- person or a tool) can open one file instead of copying chat lines. The original
-- printer is restored even when the callback fails.
function app:Collect(callback)
    local lines = {}
    local previous = self.Print
    self.Print = function(_, message) lines[#lines + 1] = tostring(message) end
    local ok, problem = pcall(callback)
    self.Print = previous
    if not ok then lines[#lines + 1] = "error: " .. tostring(problem) end
    return lines
end

-- `/luma dump` copies the diagnostics page text and the HUD geometry report into
-- SavedVariables (`LumaUIDB.diagnostics`), so a reader can open the file instead
-- of copying chat lines. The client flushes SavedVariables on /reload or logout,
-- and the confirmation names that step. A newer-schema database is never written.
function app:WriteDiagnostics()
    local store = self.Store
    if not store or type(store.data) ~= "table" then self:Print(self.L.notReady); return end
    if store.readonly then self:Print(self.L.readonly); return end
    local lines = self:Collect(function()
        local settings = self.Settings
        if settings and not settings.frame then settings:Build() end
        local page = settings and settings.pages and settings.pages.diagnostics
        if page then
            page.Update()
            local function append(text)
                if type(text) ~= "string" then return end
                for line in text:gmatch("[^\r\n]+") do self:Print(line) end
            end
            self:Print(self.L.diagStatus)
            append(page.bodies.status and page.bodies.status:GetText())
            self:Print(self.L.diagNative)
            append(page.bodies.native and page.bodies.native:GetText())
            self:Print(self.L.diagCoexistence)
            append(page.bodies.coexistence and page.bodies.coexistence:GetText())
            self:Print(self.L.diagErrors)
            append(page.bodies.errors and page.bodies.errors:GetText())
            self:Print("")
        end
        self.Layout:Diagnose()
    end)
    store.data.diagnostics = { version = self.version, lines = lines }
    self:Print(self.L.diagnosticsSaved)
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
