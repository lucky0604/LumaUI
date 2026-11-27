local _, app = ...

-- 012 phase 17 / 018 Step 2: one tool entry and one shared menu for the
-- low-frequency entries. The five narrow text keys are gone: a single button
-- of at least 24 x 24 UI opens the menu that used to live in two places.
--
-- The two client tool hosts (the bag slots bar and the micro menu grid) are the
-- only native frames this component ever hides, and only out of combat, only
-- while they still sit under their own normal parents. Each host records its
-- own original visibility, is verified by reading the state back, and is handed
-- straight back when the write was refused, when Edit Mode is open, when the
-- player asks for the native layout, or when this component stops. Nothing is
-- reparented, no click handler is replaced, no bag function or key binding is
-- touched, and the queue eye and MicroMenuContainer are never the target.
--
-- Combat: hiding is done through the shared out-of-combat queue. Expanding the
-- native row during combat needs a secure entry that is pre-configured out of
-- combat; that mechanism is only opened for a host after in-game validation of
-- this build, so it stays off here and the entry reports it instead of writing
-- a protected frame from normal Lua.

local ID = "utilityCorner"
local BUTTON = 26
local ENTRY_WIDTH = 34
local NATIVE_JOB = "utilityCorner/native"

-- The two hosts this step collects. `normal` is the parent the client gives the
-- frame; anything else means another addon or the player moved it, and the host
-- stays native. `system` is true for a frame that inherits the client's
-- EditMode system template: those replace `Hide`/`SetShown` with an override
-- that breaks Edit Mode snapping, so this component calls the recorded base
-- `HideBase`/`Show` instead of the override. `MicroMenu` is the button grid and
-- is not an Edit Mode system; its container and the queue eye keep their frames.
local HOSTS = {
    { key = "bagsBar", frame = "BagsBar", normal = "UIParent", system = true },
    { key = "microMenu", frame = "MicroMenu", normal = "MicroMenuContainer" },
}

local component
local menuOwner

local function object(value)
    local kind = type(value)
    return kind == "table" or kind == "userdata"
end

local function plain(value, expected)
    return app.Capabilities.Plain(value, expected)
end

local function named(name)
    local value = _G[name]
    if object(value) then return value end
end

local function shownOf(frame)
    if not object(frame) or type(frame.IsShown) ~= "function" then return nil end
    local ok, value = pcall(frame.IsShown, frame)
    if not ok then return nil end
    -- A plain `false` is a real answer; `ok and value or nil` would collapse it.
    return plain(value, "boolean")
end

local function parentOf(frame)
    if not object(frame) or type(frame.GetParent) ~= "function" then return nil end
    local ok, value = pcall(frame.GetParent, frame)
    return ok and object(value) and value or nil
end

local function editModeOpen()
    if app.Layout and app.Layout.editing == true then return true end
    local frame = _G.EditModeManagerFrame
    if not object(frame) then return false end
    return shownOf(frame) == true
end

local function inCombat()
    return type(InCombatLockdown) == "function" and InCombatLockdown()
end

local function intentOf(key)
    local list = app.Store and app.Store:Profile().ui.nativeTools
    local value = type(list) == "table" and list[key] or nil
    return value == "client" and "client" or "collect"
end

----------------------------------------------------------------------
-- Shared tool menu
----------------------------------------------------------------------
local MENU = {
    { key = "settings", label = "drawerSettings", run = function() app.Settings:Toggle() end },
    { key = "bags", label = "drawerBags", run = function()
        local inventory = app.components and app.components.inventory
        if inventory and inventory.running then
            inventory:Toggle()
        elseif type(ToggleAllBags) == "function" then
            ToggleAllBags()
        end
    end },
    { key = "character", label = "drawerCharacter", run = function()
        local window = app.components and app.components.characterWindow
        if window and window.running then
            window:Toggle()
        elseif type(ToggleCharacter) == "function" then
            ToggleCharacter("PaperDollFrame")
        end
    end },
    { key = "layout", label = "drawerLayout", run = function() app.Unlock:Toggle() end },
    { key = "calendar", label = "drawerCalendar", run = function()
        if type(ToggleCalendar) == "function" then ToggleCalendar() end
    end },
    { key = "map", label = "drawerMap", run = function()
        if type(ToggleWorldMap) == "function" then ToggleWorldMap() end
    end },
    { key = "menu", label = "utilityMenu", run = function()
        if type(ToggleGameMenu) == "function" then ToggleGameMenu() end
    end },
}

local function buildMenu()
    local frame = CreateFrame("Frame", "LumaUIToolMenu", UIParent, "BackdropTemplate")
    frame:SetFrameStrata("DIALOG")
    frame:SetClampedToScreen(true)
    frame:EnableMouse(true)
    app.Surface:Plate(frame, "window")
    frame.buttons = {}
    local count, width = #MENU + 2, 200
    frame:SetSize(width, 8 + count * 24)
    for index, entry in ipairs(MENU) do
        local button = app.Controls:Button(frame, app.L[entry.label] or entry.label, width - 12, entry.run,
            { height = 20, size = 11 })
        button:SetPoint("TOPLEFT", 6, -4 - (index - 1) * 24)
        frame.buttons[entry.key] = button
    end
    -- The one entry that brings the native row back. It stays in the same menu
    -- as everything else, so a player who collected the hosts still has one
    -- reachable place to recover them.
    local native = app.Controls:Button(frame, app.L.nativeToolsExpand, width - 12, function()
        if component then component:ToggleNative() end
        if menuOwner then menuOwner:Hide() end
    end, { height = 20, size = 11 })
    native:SetPoint("TOPLEFT", 6, -4 - (#MENU) * 24)
    frame.nativeButton = native
    frame:SetScript("OnHide", function() end)
    frame:Hide()
    UISpecialFrames[#UISpecialFrames + 1] = "LumaUIToolMenu"
    return frame
end

local function menuFrame()
    if not menuOwner then menuOwner = buildMenu() end
    return menuOwner
end

-- One menu for both entries. `anchor` is the button that opened it, so the
-- minimap's own drawer entry can reuse it without a second list.
local function toggleMenu(anchor)
    local menu = menuFrame()
    if menu:IsShown() then
        menu:Hide()
        return
    end
    local host = object(anchor) and anchor or (component and component.frame)
    menu:ClearAllPoints()
    if object(host) then
        menu:SetPoint("TOPRIGHT", host, "TOPLEFT", -4, 0)
    else
        menu:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    end
    if menu.nativeButton then
        menu.nativeButton:SetText(component and component.expanded and app.L.nativeToolsCollapse
            or app.L.nativeToolsExpand)
    end
    menu:Show()
end

app.ToolMenu = { Toggle = toggleMenu, Frame = menuFrame,
    Hide = function() if menuOwner then menuOwner:Hide() end end }

----------------------------------------------------------------------
-- Native host adapters
----------------------------------------------------------------------
-- Visibility writes for a host. An Edit Mode system frame exposes the client's
-- original `Hide` as `HideBase`; using the override would break the frame's
-- snapping, which is a layout decision the player owns. `Show` is never
-- overridden, so bringing the host back is always the plain method.
local function hideHost(record)
    local frame = record.frame
    local hide = record.system and type(frame.HideBase) == "function" and frame.HideBase or frame.Hide
    pcall(hide, frame)
end

local function showHost(record)
    pcall(record.frame.Show, record.frame)
end

local function releaseHost(record)
    if not record or not record.frame then return end
    if not record.hidden then return end
    -- The client's own state is what comes back: a host that was already hidden
    -- stays hidden.
    if record.shown == false then hideHost(record) else showHost(record) end
    record.hidden = false
end

local function normalHost(host, frame)
    local parent = parentOf(frame)
    if not parent then return false, "unreadable" end
    if parent ~= named(host.normal) then return false, "foreign-parent" end
    if host.key == "microMenu" then
        local container = named("MicroMenuContainer")
        if not container or parentOf(container) ~= UIParent then return false, "foreign-parent" end
    end
    return true
end

local function collect(record)
    local frame = record.frame
    local shown = shownOf(frame)
    if shown == nil then return false, "unreadable" end
    if not record.hidden then
        record.shown = shown
        hideHost(record)
        record.hidden = true
    end
    local after = shownOf(frame)
    if after == true then
        -- A refused or re-driven visibility: hand the host back and say so.
        releaseHost(record)
        record.refused = true
        return false, "refused"
    end
    record.refused = nil
    return true, "collected"
end

local function applyHosts(self)
    self.hosts = self.hosts or {}
    self.hostStatus = self.hostStatus or {}
    local reveal = self.expanded == true or editModeOpen()
    for _, host in ipairs(HOSTS) do
        local frame = named(host.frame)
        local record = self.hosts[host.key]
        local intent, state, reason
        if not frame then
            self.hosts[host.key] = nil
            self.hostStatus[host.key] = "absent"
            intent = intentOf(host.key)
            state, reason = "native", "absent"
        else
            if record and record.frame ~= frame then
                -- The client rebuilt the host: hand the old instance back before
                -- recording the new one.
                releaseHost(record)
                record = nil
            end
            record = record or { frame = frame, shown = nil, hidden = false, system = host.system == true }
            record.system = host.system == true
            self.hosts[host.key] = record
            intent = intentOf(host.key)
            local normal, why = normalHost(host, frame)
            if not normal then
                releaseHost(record)
                record.refused = nil
                self.hostStatus[host.key] = why
                state, reason = "native", why
            elseif intent ~= "collect" then
                releaseHost(record)
                record.refused = nil
                self.hostStatus[host.key] = "client"
                state, reason = "native", "client-intent"
            elseif reveal then
                releaseHost(record)
                self.hostStatus[host.key] = self.expanded and "expanded" or "edit-mode"
                state, reason = "native", self.hostStatus[host.key]
            else
                local ok, result = collect(record)
                self.hostStatus[host.key] = result
                state, reason = ok and "owned" or "native", ok and nil or result
            end
        end
        if app.Ownership then
            app.Ownership:Set("utilityCorner." .. host.key, {
                intent = intent == "collect" and "owned" or "native",
                active = state, evidence = "simulated", reason = reason,
            })
        end
    end
end

local function schedule(self)
    if not self.running then return end
    if inCombat() then
        app.Queue:Run(NATIVE_JOB, function()
            if not self.running then return end
            applyHosts(self)
        end)
        return
    end
    applyHosts(self)
end

----------------------------------------------------------------------
-- Entry
----------------------------------------------------------------------
local function ensureFrame(self)
    if self.frame then return self.frame end
    local frame = CreateFrame("Frame", "LumaUIUtilityCorner", UIParent, "BackdropTemplate")
    frame:SetSize(ENTRY_WIDTH, BUTTON)
    app.Surface:Plate(frame, "hud")
    frame.buttons = {}
    local button = app.Controls:Button(frame, app.L.toolEntry, ENTRY_WIDTH, function()
        toggleMenu(frame)
    end, { height = 22, size = 10 })
    button:SetPoint("CENTER", 0, 0)
    frame.buttons.tools = button
    frame:Show()
    app.Layout:Register(ID, frame, 0, 0, app.L.utilityCorner)
    self.frame = frame
    return frame
end

-- Default position: above the reserved meter block on the right edge. The
-- saved position still wins; this only sets the fallback.
local function position(self)
    local width = UIParent:GetWidth() or 1024
    local height = UIParent:GetHeight() or 768
    local scale = app.Layout:Scale(ID)
    if not scale or scale <= 0 then scale = 1 end
    local x = width / 2 - 60
    local y = -height / 2 + 46 + height * 0.16 + 12
    self.frame:SetSize(ENTRY_WIDTH / scale, BUTTON)
    app.Layout:SetEntryDefault(ID, x / scale, y / scale)
    app.Layout:Apply(ID)
end

local function syncNativeButton(self)
    if menuOwner and menuOwner.nativeButton then
        menuOwner.nativeButton:SetText(self.expanded and app.L.nativeToolsCollapse or app.L.nativeToolsExpand)
    end
end

component = app:RegisterComponent({ id = "utilityCorner", label = "utilityCorner", defaultEnabled = true,
    Enable = function(self)
        self.expanded = false
        self.entryFailed = nil
        local built, problem = pcall(ensureFrame, self)
        if not built then
            -- No entry means no way back: the native hosts are left exactly as
            -- they are instead of being collected behind a missing door.
            self.entryFailed = true
            app:Report("utilityCorner", problem)
        end
        if self.frame then position(self) else self.entryFailed = true end
        syncNativeButton(self)
        self:Listen("DISPLAY_SIZE_CHANGED", function(current) position(current) end)
        self:Listen("UI_SCALE_CHANGED", function(current) position(current) end)
        -- Edit Mode moves the two hosts; sample their state again afterwards.
        self:Listen("EDIT_MODE_LAYOUTS_UPDATED", function(current) schedule(current) end)
        self:Listen("PLAYER_ENTERING_WORLD", function(current) schedule(current) end)
        app:Subscribe(self, "LAYOUT_CENTRAL_CHANGED", function()
            if self.running then position(self) end
        end)
        app:Subscribe(self, "RUNTIME_UPDATED", function()
            if self.running then syncNativeButton(self) end
        end)
        if app.Ownership then
            app.Ownership:Set("utilityCorner", { intent = "owned", active = "owned",
                evidence = "simulated" })
        end
        app:Publish("TOOL_ENTRY_CHANGED")
        if not self.entryFailed then schedule(self) end
    end,
    Refresh = function(self)
        local built = pcall(ensureFrame, self)
        if not built or not self.frame then self.entryFailed = true end
        if self.frame then position(self) end
        syncNativeButton(self)
        app:Publish("TOOL_ENTRY_CHANGED")
        if not self.entryFailed then schedule(self) end
    end,
    Disable = function(self)
        if self.frame then self.frame:Hide() end
        if menuOwner then menuOwner:Hide() end
        self.expanded = false
        for _, host in ipairs(HOSTS) do
            releaseHost(self.hosts and self.hosts[host.key])
            if self.hosts then self.hosts[host.key] = nil end
            if app.Ownership then
                app.Ownership:Set("utilityCorner." .. host.key, {
                    intent = intentOf(host.key) == "collect" and "owned" or "native",
                    active = "native", evidence = "none", reason = "component-off",
                })
            end
        end
        if app.Ownership then app.Ownership:Active("utilityCorner", "native", "component-off") end
        app:Publish("TOOL_ENTRY_CHANGED")
    end,
})

function component:ToggleNative()
    if inCombat() then
        app:Print(app.L.nativeToolsCombat)
        return false
    end
    self.expanded = not self.expanded
    syncNativeButton(self)
    schedule(self)
    app:Print(self.expanded and app.L.nativeToolsShown or app.L.nativeToolsCollected)
    return true
end

function component:SetHost(key, mode)
    mode = mode == "client" and "client" or "collect"
    -- Dot call: `Store:Clone(x)` would clone the Store itself.
    local list = app.Store.Clone(app.Store:Profile().ui.nativeTools or {})
    list[key] = mode
    local ok = app.Store:Set("ui", "nativeTools", list)
    if not ok then app:Print(app.L.readonly) end
    schedule(self)
    return ok
end

function component:Command(rest)
    local action, argument = "", ""
    if type(rest) == "string" then
        action, argument = rest:match("^%s*(%S*)%s*(.-)%s*$")
        action, argument = action or "", argument or ""
    end
    action = action:lower()
    if action == "show" then
        if not self.expanded and self:ToggleNative() then return end
        self:Diagnose()
    elseif action == "hide" then
        if self.expanded and self:ToggleNative() then return end
        self:Diagnose()
    elseif action == "bags" or action == "micro" then
        local key = action == "bags" and "bagsBar" or "microMenu"
        local mode = argument == "client" and "client" or "collect"
        self:SetHost(key, mode)
        self:Diagnose()
    else
        self:Diagnose()
    end
end

function component:Describe()
    if not self.running then return nil end
    local parts = {}
    for _, host in ipairs(HOSTS) do
        parts[#parts + 1] = string.format("%s=%s", host.key, self.hostStatus and self.hostStatus[host.key] or "?")
    end
    return string.format("utilityCorner: entry=%dx%d %s", ENTRY_WIDTH, BUTTON, table.concat(parts, " "))
end

function component:Diagnose()
    app:Print(string.format("utilityCorner: expanded=%s entry=%dx%d",
        self.expanded and "yes" or "no", ENTRY_WIDTH, BUTTON))
    for _, host in ipairs(HOSTS) do
        local frame = named(host.frame)
        local record = self.hosts and self.hosts[host.key]
        app:Print(string.format("  %-9s intent=%s state=%s shown=%s recorded=%s",
            host.key, intentOf(host.key), self.hostStatus and self.hostStatus[host.key] or "?",
            frame and (shownOf(frame) and "yes" or "no") or "absent",
            record and record.shown ~= nil and tostring(record.shown) or "-"))
    end
    app:Print("  " .. app.L.nativeToolsNote)
end
