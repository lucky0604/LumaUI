local _, app = ...
local Model = app.CooldownModel

-- LumaUI's own cooldown groups (012 phase 06/07). Two groups, each with its own
-- ordered spell list, icon size, gap and per-row cap. The renderer uses the same
-- icon cell as the style card and the same geometry planner as the native
-- viewer placement, so both paths share one look and one layout rule.
--
-- This is a real renderer, not a preview: cells read C_Spell and show the
-- client's live cooldown or charge values. Every value that enters the widget
-- is checked with `Capabilities.Plain` first; a restricted value leaves the
-- cell without a sweep or timer instead of guessing. The groups are empty by
-- default, so nothing is drawn until the player imports or adds a spell, and
-- the client's own viewers are never hidden here.
--
-- Identity is the spell ID. Order lives in the profile, not in a frame or in the
-- client's pool, so a recycled button or a changed display name can never
-- reorder the player's list.

local component
local CONTAINER_PREFIX = "LumaUICooldownOwn_"
local JOB = "cooldownGroups/render"
local MAX_WIDTH_RATIO = 0.46

local function plainNumber(value)
    return app.Capabilities.Plain(value, "number")
end

local function profileGroups()
    return app.Store:Profile().ui.cooldownGroups
end

-- Deep copy of the stored group table. Store:Set expects a complete section
-- value and normalizes it, so every mutation starts from a copy.
local function cloneGroups()
    return app.Store.Clone(profileGroups())
end

local function commit(groups)
    return app.Store:Set("ui", "cooldownGroups", groups)
end

local function spellInfo(spellID)
    local api = _G.C_Spell
    local name, icon
    if type(api) == "table" and type(api.GetSpellInfo) == "function" then
        local ok, info = pcall(api.GetSpellInfo, spellID)
        if ok and type(info) == "table" then
            name = app.Capabilities.Plain(info.name, "string")
            local iconID = plainNumber(info.iconID)
            if iconID then icon = iconID end
        end
    end
    if not name and type(_G.GetSpellInfo) == "function" then
        local ok, fallbackName, _, fallbackIcon = pcall(_G.GetSpellInfo, spellID)
        name = ok and app.Capabilities.Plain(fallbackName, "string") or nil
        fallbackIcon = ok and plainNumber(fallbackIcon) or nil
        if fallbackIcon then icon = fallbackIcon end
    end
    if not name then return nil end
    return { name = name, icon = icon,
        texture = icon and ("Interface\\Icons\\" .. tostring(icon)) or nil }
end

-- One spell's live state, in plain numbers only. A restricted cooldown table
-- returns an empty state: the caller then draws the icon without a sweep, which
-- is truthful, instead of a frozen remaining time.
local function spellState(spellID)
    local api = _G.C_Spell
    local state = { start = nil, duration = nil, remaining = nil, charges = nil, maxCharges = nil }
    local now = type(GetTime) == "function" and select(2, pcall(GetTime)) or nil
    now = plainNumber(now)
    if type(api) == "table" and type(api.GetSpellCharges) == "function" then
        local ok, charges = pcall(api.GetSpellCharges, spellID)
        if ok and type(charges) == "table" then
            local current = plainNumber(charges.currentCharges)
            local max = plainNumber(charges.maxCharges)
            local start = plainNumber(charges.cooldownStartTime)
            local duration = plainNumber(charges.cooldownDuration)
            if current and max then
                state.charges, state.maxCharges = current, max
                state.start, state.duration = start, duration
                if current < max and start and duration and now and duration > 0 then
                    state.remaining = math.max(0, start + duration - now)
                end
            end
        end
    end
    if type(api) == "table" and type(api.GetSpellCooldown) == "function" then
        local ok, cooldown = pcall(api.GetSpellCooldown, spellID)
        if ok and type(cooldown) == "table" and cooldown.isEnabled ~= false then
            local start = plainNumber(cooldown.startTime)
            local duration = plainNumber(cooldown.duration)
            if start and duration and duration > 0 then
                state.start, state.duration = start, duration
                if now then state.remaining = math.max(0, start + duration - now) end
            end
        end
    end
    return state
end

local function anyActive(container)
    for _, cell in ipairs(container.cells or {}) do
        local remaining = cell.lumaRemaining
        if remaining and remaining > 0.05 then return true end
    end
end

local function stopTicker(self)
    if self.ticker then
        self.ticker:Cancel()
        self.ticker = nil
    end
end

-- A single slow ticker serves both groups and exists only while at least one
-- drawn cell is counting down; an idle HUD keeps no timer.
local function ensureTicker(self)
    local active = false
    for _, container in pairs(self.containers or {}) do
        if anyActive(container) then active = true; break end
    end
    if not active then stopTicker(self); return end
    if self.ticker or type(C_Timer) ~= "table" or type(C_Timer.NewTicker) ~= "function" then return end
    self.ticker = C_Timer.NewTicker(0.1, function()
        if not self.running then stopTicker(self); return end
        for _, container in pairs(self.containers or {}) do
            app:Call("cooldownGroups/tick", component.RefreshGroup, component, container, true)
        end
        ensureTicker(self)
    end)
end

local function cellFor(container, index)
    local cell = container.cells[index]
    if cell then return cell end
    cell = app.PearlCell:Create(container.frame, container.group.size)
    container.cells[index] = cell
    return cell
end

local function placeCells(container)
    local plan = container.plan
    local holder = container.frame
    holder:SetSize(math.max(1, plan.capacity or plan.width or container.group.size),
        math.max(1, plan.height or container.group.size))
    for index, slot in ipairs(plan.slots) do
        local cell = cellFor(container, index)
        cell:SetSize(slot.size, slot.size)
        cell:ClearAllPoints()
        -- Plan coordinates are centres measured from the block's left edge and
        -- bottom; the frame's CENTER anchor turns them into one grid.
        cell:SetPoint("CENTER", holder, "BOTTOM", slot.x, slot.y)
        cell:Show()
    end
    for index = #plan.slots + 1, #container.cells do container.cells[index]:Hide() end
end

local function renderOne(self, container)
    local group = container.group
    local maxWidth = math.max(80, (self.maxWidth or 400))
    container.plan = Model:Plan(group, maxWidth)
    placeCells(container)
    container.unknown = 0
    local drawn = 0
    for index, spellID in ipairs(group.order) do
        local cell = container.cells[index]
        if cell then
            local info = spellInfo(spellID)
            if not info then
                app.PearlCell:Clear(cell)
                container.unknown = (container.unknown or 0) + 1
            else
                local state = spellState(spellID)
                app.PearlCell:Apply(cell, {
                    icon = info.texture,
                    count = state.charges,
                    remaining = state.remaining,
                    start = state.start, duration = state.duration,
                    state = state.remaining and "tracking"
                        or ((state.charges or 0) > 1 and "proc" or "ready"),
                })
                cell.lumaSpellID = spellID
                cell.lumaRemaining = state.remaining
                drawn = drawn + 1
            end
        end
    end
    container.drawn = drawn
end

local function anchor(self, container)
    local central = app.Layout:Central()
    local plan = container.plan
    local height = plan and plan.height or 0
    local width = plan and (plan.capacity or plan.width) or 0
    if height <= 0 or width <= 0 then
        container.frame:Hide()
        return
    end
    -- The own block sits on the same baseline the native viewers use. The
    -- client's viewers stay where they are until the player turns them off in
    -- Edit Mode; `/luma cds` reports the overlap instead of hiding anything.
    local bottom = central.cooldown.bottom
    local y = bottom + height / 2 - central.screen.height / 2
    container.frame:ClearAllPoints()
    container.frame:SetPoint("CENTER", UIParent, "CENTER", 0, y)
    container.frame:Show()
end

local function ensureContainer(self, group)
    local name = CONTAINER_PREFIX .. group.id
    local container = self.containers and self.containers[group.id]
    if container then
        container.group = group
        return container
    end
    local frame = _G[name] or CreateFrame("Frame", name, UIParent)
    frame:EnableMouse(false)
    frame:SetFrameStrata("LOW")
    container = { id = group.id, frame = frame, group = group, cells = {} }
    self.containers = self.containers or {}
    self.containers[group.id] = container
    return container
end

local function refreshGroup(self, container, ticking)
    if not self.running or not container then return end
    renderOne(self, container)
    if not ticking then anchor(self, container) end
end

-- Reads the client's own ordered list for one category when this build exposes
-- it. The function name has moved between builds, so both the table method and
-- the global are probed; a missing entry reports `no-source` and the player's
-- list stays unchanged.
local function clientOrder(category)
    local viewers = _G.C_CooldownViewer
    if type(viewers) == "table" and type(viewers.GetOrderedCooldownIDsForCategory) == "function" then
        local ok, list = pcall(viewers.GetOrderedCooldownIDsForCategory, category)
        if ok and type(list) == "table" then return list end
    end
    if type(_G.GetOrderedCooldownIDsForCategory) == "function" then
        local ok, list = pcall(_G.GetOrderedCooldownIDsForCategory, category)
        if ok and type(list) == "table" then return list end
    end
    return nil
end

local function categoryOf(id)
    local enum = _G.Enum and _G.Enum.CooldownViewerCategory
    if type(enum) == "table" then
        if id == "essential" then return enum.Essential or enum.EssentialCooldowns end
        if id == "utility" then return enum.Utility or enum.UtilityCooldowns end
    end
    return nil
end

component = app:RegisterComponent({ id = "cooldownGroups", label = "cooldownGroups", defaultEnabled = true,
    Enable = function(self)
        self.containers = self.containers or {}
        local screenWidth = UIParent:GetWidth() or 1024
        self.maxWidth = screenWidth * MAX_WIDTH_RATIO
        self:Listen("SPELL_UPDATE_COOLDOWN", function(current)
            app:Call(JOB, current.Refresh, current)
        end)
        self:Listen("SPELL_UPDATE_CHARGES", function(current)
            app:Call(JOB, current.Refresh, current)
        end)
        self:Listen("SPELLS_CHANGED", function(current)
            app:Call(JOB, current.Refresh, current)
        end)
        self:Listen("PLAYER_ENTERING_WORLD", function(current)
            app:Call(JOB, current.Refresh, current)
        end)
        app:Subscribe(self, "LAYOUT_CENTRAL_CHANGED", function()
            if self.running then app:Call(JOB, self.Reposition, self) end
        end)
        self:Render()
    end,
    Refresh = function(self)
        self.maxWidth = (UIParent:GetWidth() or 1024) * MAX_WIDTH_RATIO
        self:Render()
    end,
    Disable = function(self)
        stopTicker(self)
        for _, container in pairs(self.containers or {}) do
            container.frame:Hide()
        end
        if app.Ownership then app.Ownership:Active("cooldownGroups", "native", "component-off") end
    end,
})

function component:Render()
    if not self.running then return end
    -- Read-only databases hand back the raw defaults table, which never went
    -- through Store:Normalize; normalizing here is a pure read and keeps the
    -- renderer from indexing a missing group.
    local groups = Model:Normalize(profileGroups())
    local owned = groups.owned == true
    for _, id in ipairs(Model.GROUP_IDS) do
        local group = groups.groups[id]
        local container = self.containers[id] or ensureContainer(self, group)
        container.group = group
        if owned and group.enabled and #group.order > 0 then
            refreshGroup(self, container, false)
        else
            container.frame:Hide()
            container.plan = Model:Plan(group, self.maxWidth)
        end
    end
    ensureTicker(self)
    if app.Ownership then
        app.Ownership:Set("cooldownGroups", {
            intent = owned and "owned" or "native",
            active = owned and "owned" or "native",
            evidence = "simulated",
        })
    end
end

function component:Reposition()
    if not self.running then return end
    for _, container in pairs(self.containers or {}) do
        if container.frame:IsShown() then anchor(self, container) end
    end
end

function component:RefreshGroup(container, ticking)
    refreshGroup(self, container, ticking)
end

-- Deep-copies the profile, hands it to `mutator`, and only stores the result
-- when the mutator reports a change. A read-only profile refuses the write and
-- the caller prints the reason.
function component:Edit(mutator)
    local groups = Model:Normalize(cloneGroups())
    local changed = mutator(groups)
    if not changed then return false end
    if not commit(groups) then
        app:Print(app.L.readonly)
        return false
    end
    if self.running then self:Render() end
    return true
end

function component:Import(id, replace)
    id = id == "utility" and "utility" or "essential"
    local order = clientOrder(categoryOf(id))
    if not order then
        app:Print(app.L.cdsNoSource)
        return false
    end
    local added, replaced = 0, 0
    local ok = self:Edit(function(groups)
        local group = groups.groups and groups.groups[id]
        if not group then return false end
        added, replaced = Model:ApplyOrder(group, order, replace)
        return added > 0 or replaced > 0
    end)
    if ok then
        app:Print(string.format(app.L.cdsImported, id, added, replaced))
    end
    return ok
end

function component:Add(spellID, id)
    spellID = tonumber(spellID)
    if not spellID then
        app:Print(app.L.cdsUsage)
        return false
    end
    id = id == "utility" and "utility" or "essential"
    local added = false
    local ok = self:Edit(function(groups)
        local group = groups.groups and groups.groups[id]
        if not group then return false end
        for _, current in ipairs(group.order) do
            if current == spellID then return false end
        end
        if #group.order >= Model.maxEntries then return false end
        group.order[#group.order + 1] = spellID
        added = true
        return true
    end)
    if ok and added then
        app:Print(string.format(app.L.cdsAdded, spellID, id))
        return true
    end
    if not added then app:Print(app.L.cdsAddFailed) end
    return false
end

function component:Remove(spellID)
    spellID = tonumber(spellID)
    if not spellID then self:Diagnose(); return end
    local removed = false
    self:Edit(function(groups)
        for _, id in ipairs(Model.GROUP_IDS) do
            if Model:Remove(groups.groups[id], spellID) then removed = true end
        end
        return removed
    end)
    if removed then
        app:Print(string.format(app.L.cdsRemoved, spellID))
    else
        app:Print(app.L.cdsNotPresent)
    end
end

function component:Describe()
    if not self.running then return nil end
    local groups = Model:Normalize(profileGroups())
    local counts = {}
    for _, id in ipairs(Model.GROUP_IDS) do
        local container = self.containers and self.containers[id]
        counts[#counts + 1] = string.format("%s=%d/%d", id, container and container.drawn or 0,
            #groups.groups[id].order)
    end
    return string.format("cooldownGroups: mode=%s %s", groups.owned and "owned" or "native",
        table.concat(counts, " "))
end

function component:Diagnose()
    local function yes(value) return value and "yes" or "no" end
    local groups = Model:Normalize(profileGroups())
    app:Print(string.format("cooldownGroups: running=%s owned=%s native-viewers=kept",
        yes(self.running), yes(groups.owned)))
    for _, id in ipairs(Model.GROUP_IDS) do
        local group = groups.groups[id]
        local container = self.containers and self.containers[id]
        local plan = container and container.plan or Model:Plan(group, self.maxWidth)
        app:Print(string.format("  %s: entries=%d enabled=%s size=%d gap=%d max=%d rows=%d perRow=%d drawn=%s",
            id, #group.order, yes(group.enabled), group.size, group.gap, group.max,
            #plan.rows, plan.perRow or 0, container and tostring(container.drawn or 0) or "-"))
        if #group.order > 0 then
            local ids = {}
            for index, spellID in ipairs(group.order) do
                if index > 8 then ids[#ids + 1] = "…"; break end
                ids[#ids + 1] = tostring(spellID)
            end
            app:Print("    order: " .. table.concat(ids, " "))
        end
    end
    app:Print("  " .. app.L.cdsNativeNote)
end

function component:Command(rest)
    -- Separate statement on purpose: `local a, b = cond and s:match(...)` keeps
    -- only the first capture, which silently emptied the argument.
    local action, argument = "", ""
    if type(rest) == "string" then
        action, argument = rest:match("^%s*(%S*)%s*(.-)%s*$")
        action, argument = action or "", argument or ""
    end
    action = action:lower()
    if action == "" then
        self:Diagnose()
    elseif action == "owned" then
        local wanted = not (profileGroups().owned == true)
        if self:Edit(function(groups) groups.owned = wanted; return true end) then
            app:Print(wanted and app.L.cdsOwnedOn or app.L.cdsOwnedOff)
        end
    elseif action == "import" then
        local id, mode = argument:match("^(%S*)%s*(%S*)$")
        self:Import(id ~= "" and id or "essential", mode == "replace")
    elseif action == "add" then
        local id, group = argument:match("^(%S*)%s*(%S*)$")
        self:Add(id, group)
    elseif action == "remove" or action == "rm" then
        self:Remove(argument)
    elseif action == "clear" then
        local id = argument ~= "" and argument or nil
        self:Edit(function(groups)
            local changed = false
            for _, groupID in ipairs(Model.GROUP_IDS) do
                local group = groups.groups[groupID]
                if (not id or id == groupID) and #group.order > 0 then
                    group.order = {}
                    changed = true
                end
            end
            return changed
        end)
    else
        self:Diagnose()
    end
end
