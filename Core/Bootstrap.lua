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
        local page = settings and settings:EnsurePage("diagnostics")
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
        -- The two reports a reader most often needs next to the geometry: which
        -- control draws what, and the cooldown handover state. One dump then
        -- answers "two HUDs?" without three separate copies.
        self:Print("")
        local ownership = self.Ownership and self.Ownership:Lines() or {}
        if #ownership == 0 then
            self:Print(self.L.ownNone)
        else
            self:Print(self.L.ownHeader)
            for _, line in ipairs(ownership) do self:Print("  " .. line) end
        end
        local cooldowns = self.components and self.components.cooldownGroups
        if cooldowns and cooldowns.running and type(cooldowns.Diagnose) == "function" then
            self:Call("dump/cooldowns", cooldowns.Diagnose, cooldowns)
        end
        -- The plate inventory uses the same wording as `/luma plates`, so a
        -- dump and a chat report can be compared line by line (010 phase 06).
        local plates = self.components and self.components.nameplates
        if plates and plates.running and type(plates.Diagnose) == "function" then
            self:Call("dump/nameplates", plates.Diagnose, plates, 40)
        end
    end)
    store.data.diagnostics = { version = self.version, lines = lines }
    self:Print(self.L.diagnosticsSaved)
end

-- Writes one collected report into SavedVariables so it can be copied out of the
-- file instead of the chat frame. `key` names the slot under
-- `LumaUIDB.reports`, so several reports can be kept side by side and the newest
-- of each replaces the old one. SavedVariables flush on /reload or logout, which
-- the confirmation names, and a newer-schema database is never written.
function app:WriteReport(key, callback, title)
    local store = self.Store
    if not store or type(store.data) ~= "table" then self:Print(self.L.notReady); return false end
    if store.readonly then self:Print(self.L.readonly); return false end
    if type(key) ~= "string" or key == "" then return false end
    local lines = self:Collect(callback)
    store.data.reports = type(store.data.reports) == "table" and store.data.reports or {}
    store.data.reports[key] = {
        version = self.version,
        title = title or key,
        lines = lines,
    }
    self:Print(string.format(self.L.reportSaved, key))
    return true
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
