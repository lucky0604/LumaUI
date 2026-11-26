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

-- Session draft for the editor: group option overrides that are previewed live
-- but only written to the profile when applied. Never persisted.
local draft = nil

-- The stored groups with the draft laid over them, normalised, so preview,
-- render and diagnostics read one result.
local function effectiveGroups()
    local groups = Model:Normalize(profileGroups())
    if draft then
        local merged = app.Store.Clone(groups)
        for id, options in pairs(draft) do
            for key, value in pairs(options) do merged.groups[id][key] = value end
        end
        groups = Model:Normalize(merged)
    end
    return groups
end

-- Deep copy of the stored group table. Store:Set expects a complete section
-- value and normalizes it, so every mutation starts from a copy.
local function cloneGroups()
    return app.Store.Clone(profileGroups())
end

local function commit(groups)
    return app.Store:Set("ui", "cooldownGroups", groups)
end

-- The name and icon of a spell never change while it is listed, and the ticker
-- re-renders every cell ten times a second. Only complete lookups are cached: a
-- spell whose info is not available yet is retried on the next pass.
local infoCache = {}

-- The Cooldown Manager keeps one live record per entry (spell, override,
-- linked spells, equip slot). Reading it instead of guessing from the spell ID
-- is what makes an own cell show the same spell and icon as the client's item.
local function dataProvider()
    local settings = _G.CooldownViewerSettings
    if type(settings) ~= "table" or type(settings.GetDataProvider) ~= "function" then return nil end
    local ok, provider = pcall(settings.GetDataProvider, settings)
    if ok and type(provider) == "table" then return provider end
    return nil
end

local function cooldownInfo(cooldownID)
    if not cooldownID then return nil end
    local provider = dataProvider()
    if not provider or type(provider.GetCooldownInfoForID) ~= "function" then return nil end
    local ok, info = pcall(provider.GetCooldownInfoForID, provider, cooldownID)
    if ok and type(info) == "table" then return info end
    return nil
end

-- The spell the client would draw for this entry: an active override (a proc
-- that replaces the icon and the tooltip) wins over the base spell.
local function displaySpell(spellID)
    local info = cooldownInfo(spellID)
    if info then
        return plainNumber(info.overrideTooltipSpellID) or plainNumber(info.overrideSpellID) or spellID
    end
    return spellID
end

-- Name and icon are resolved independently. A cell draws the icon, the charge
-- count and the timer — it never draws the name — so a spell with an icon but no
-- readable name is still a valid cell, and requiring both turned such a spell
-- into an empty square. `originalIconID` is what the client's own viewer uses
-- for a normal spell; `iconID` may already be a form override.
local function spellInfo(spellID)
    local cached = infoCache[spellID]
    if cached then return cached end
    local api = _G.C_Spell
    local name, icon
    if type(api) == "table" then
        if type(api.GetSpellInfo) == "function" then
            local ok, info = pcall(api.GetSpellInfo, spellID)
            if ok and type(info) == "table" then
                name = app.Capabilities.Plain(info.name, "string")
                icon = plainNumber(info.iconID)
            end
        end
        if type(api.GetSpellTexture) == "function" then
            local ok, iconID, originalIconID = pcall(api.GetSpellTexture, spellID)
            if ok then icon = plainNumber(originalIconID) or plainNumber(iconID) or icon end
        end
        if not name and type(api.GetSpellName) == "function" then
            local ok, value = pcall(api.GetSpellName, spellID)
            name = ok and app.Capabilities.Plain(value, "string") or nil
        end
    end
    if not name and type(_G.GetSpellInfo) == "function" then
        local ok, fallbackName, _, fallbackIcon = pcall(_G.GetSpellInfo, spellID)
        name = ok and app.Capabilities.Plain(fallbackName, "string") or nil
        fallbackIcon = ok and plainNumber(fallbackIcon) or nil
        if fallbackIcon then icon = fallbackIcon end
    end
    if not name and not icon then return nil end
    local info = { name = name, icon = icon, texture = icon }
    if name and icon then infoCache[spellID] = info end
    return info
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
    -- A spell with charges keeps the charge clock: the plain cooldown record of
    -- such a spell can be the global cooldown, which must not overwrite it.
    if state.charges == nil and type(api) == "table" and type(api.GetSpellCooldown) == "function" then
        local ok, cooldown = pcall(api.GetSpellCooldown, spellID)
        if ok and type(cooldown) == "table" and cooldown.isEnabled ~= false then
            local start = plainNumber(cooldown.startTime)
            local duration = plainNumber(cooldown.duration)
            if start and duration then
                if duration > 0 then
                    state.start, state.duration = start, duration
                    if now then state.remaining = math.max(0, start + duration - now) end
                end
            else
                -- Restricted numbers: the icon stays, the timer is unknown.
                state.unknown = true
            end
        end
    end
    -- Proc: the client's own activation overlay for this spell. Only a plain
    -- boolean counts; a restricted or missing answer means "no proc shown".
    local overlay = type(_G.C_SpellActivationOverlay) == "table" and _G.C_SpellActivationOverlay.IsSpellOverlayed
    if type(overlay) == "function" then
        local ok, on = pcall(overlay, spellID)
        if ok and app.Capabilities.Plain(on, "boolean") == true then state.proc = true end
    end
    -- Where the displayed state comes from, in plain words for the cell.
    if state.charges ~= nil then state.source = "charges"
    elseif state.unknown then state.source = "unknown"
    elseif state.remaining then state.source = "cooldown"
    else state.source = "ready" end
    return state
end

-- The tracked-buff groups show the player's own aura for a spell: icon from the
-- aura, stacks as the count, remaining from the expiration time. No aura means
-- the buff is not active, and the native viewer hides that item too.
-- A tracked buff can be applied by a linked or override spell (a trinket proc
-- applies the buff, the cooldown entry names the base spell). The client checks
-- the same chain, so the aura lookup tries every spell the entry can apply.
local function auraCandidates(spellID)
    local list = { spellID }
    local seen = { [spellID] = true }
    local function add(value)
        local id = plainNumber(value)
        if id and not seen[id] then
            seen[id] = true
            list[#list + 1] = id
        end
    end
    local info = cooldownInfo(spellID)
    if info then
        add(info.overrideSpellID)
        add(info.overrideTooltipSpellID)
        if type(info.linkedSpellIDs) == "table" then
            for _, value in ipairs(info.linkedSpellIDs) do add(value) end
        end
    end
    return list
end

local function buffState(spellIDs)
    local api = _G.C_UnitAuras
    if type(api) ~= "table" or type(api.GetPlayerAuraBySpellID) ~= "function" then return nil end
    local aura
    for _, id in ipairs(spellIDs or {}) do
        local ok, value = pcall(api.GetPlayerAuraBySpellID, id)
        if ok and type(value) == "table" then
            aura = value
            break
        end
    end
    if not aura then return nil end
    local icon = plainNumber(aura.icon)
    local expiration = plainNumber(aura.expirationTime)
    local duration = plainNumber(aura.duration)
    local applications = plainNumber(aura.applications)
    local now = type(GetTime) == "function" and select(2, pcall(GetTime)) or nil
    now = plainNumber(now)
    local remaining
    if expiration and now and expiration > 0 then
        remaining = math.max(0, expiration - now)
    elseif duration and duration > 0 then
        remaining = duration
    end
    -- A permanent aura reports duration 0: stacks stay, the timer stays empty.
    if remaining and remaining <= 0 then remaining = nil end
    return { icon = icon, count = applications, remaining = remaining }
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

-- Which client category a group mirrors, and how to read it. `clientOrder` is
-- declared here and assigned below, so the renderer can ask for the live list.
local CATEGORY_KEYS = {
    essential = { "Essential", "EssentialCooldowns" },
    utility = { "Utility", "UtilityCooldowns" },
    buffs = { "TrackedBuff", "TrackedBuffCooldowns" },
}
local clientOrder, toSpellIDs

local function categoryOf(id)
    local enum = _G.Enum and _G.Enum.CooldownViewerCategory
    local keys = CATEGORY_KEYS[id]
    if type(enum) ~= "table" or not keys then return nil end
    for _, key in ipairs(keys) do
        local value = enum[key]
        if value ~= nil then return value end
    end
    return nil
end

local function isGroupID(id)
    for _, known in ipairs(Model.GROUP_IDS) do
        if known == id then return true end
    end
    return false
end

-- The client list, cached for a moment: a counting cooldown re-renders ten times
-- a second and the provider walks every entry each call. Event-driven refreshes
-- clear the cache, so an edit in the client's CDM shows up immediately.
local orderCache = {}
local ORDER_TTL = 1
local function nowSeconds()
    local ok, value = pcall(GetTime)
    return ok and plainNumber(value) or nil
end

-- The client's own viewer for a group is the most faithful source: its item list
-- is exactly what the player sees and edits, whatever category that viewer was
-- configured with.
local GROUP_VIEWERS = {
    essential = { "EssentialCooldownViewer" },
    utility = { "UtilityCooldownViewer" },
    buffs = { "BuffIconCooldownViewer", "BuffBarCooldownViewer" },
}

local function viewerOrder(id)
    for _, name in ipairs(GROUP_VIEWERS[id] or {}) do
        local frame = rawget(_G, name)
        if frame and type(frame.GetCooldownIDs) == "function" then
            local ok, list = pcall(frame.GetCooldownIDs, frame)
            if ok and type(list) == "table" and #list > 0 then return list end
        end
    end
    return nil
end

local function clientList(id)
    if id == nil or not clientOrder then return nil end
    local now = nowSeconds()
    local cached = orderCache[id]
    if cached and now and (now - cached.time) < ORDER_TTL then return cached.list end
    local list
    local ids = viewerOrder(id)
    if ids then list = toSpellIDs(ids) end
    if not list or #list == 0 then list = clientOrder(categoryOf(id)) end
    if list == nil then return cached and cached.list or nil end
    orderCache[id] = { list = list, time = now or 0 }
    return list
end

-- A group's list: the player's own Cooldown Manager by default (`auto`), and the
-- stored copy once anything was added, removed or reordered by hand.
local function effectiveOrder(group)
    if group and group.auto then
        local list = clientList(group.id)
        if list and #list > 0 then return list end
    end
    return group and group.order or {}
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
    local width = math.max(1, plan.capacity or plan.width or container.group.size)
    local height = math.max(1, plan.height or container.group.size)
    -- Layout is written only when the plan actually changed. Routine cooldown
    -- updates re-render every cell but must contribute no SetPoint/SetSize.
    if container.placedWidth ~= width or container.placedHeight ~= height then
        holder:SetSize(width, height)
        container.placedWidth, container.placedHeight = width, height
    end
    for index, slot in ipairs(plan.slots) do
        local cell = cellFor(container, index)
        local placed = cell.lumaPlaced
        if not placed or placed.x ~= slot.x or placed.y ~= slot.y or placed.size ~= slot.size then
            cell:SetSize(slot.size, slot.size)
            cell:ClearAllPoints()
            -- Plan coordinates are centres measured from the block's left edge
            -- and bottom; the frame's CENTER anchor turns them into one grid.
            cell:SetPoint("CENTER", holder, "BOTTOM", slot.x, slot.y)
            cell.lumaPlaced = { x = slot.x, y = slot.y, size = slot.size }
        end
        cell:Show()
    end
    -- Cells the plan no longer uses are cleared, not just hidden: a hidden cell
    -- that still reports a remaining time would keep the shared ticker running.
    for index = #plan.slots + 1, #container.cells do
        local cell = container.cells[index]
        app.PearlCell:Clear(cell)
        cell:Hide()
    end
end

-- The tracked-buff block packs only the buffs that are actually on the player.
-- Planning from the full list would leave a hole for every idle entry, while
-- the client's viewer closes the row up.
-- One word per group for what is on screen and why, so "nothing drawn" is never
-- ambiguous: off, unreadable (the client's list cannot be read and no stored
-- copy exists), empty (a readable empty list), idle (buffs listed, none active),
-- unresolved (entries the client cannot name or draw), drawing.
local function groupStatus(owned, group, container, order)
    if not owned or not group.enabled then return "off" end
    if #order == 0 then
        if group.auto and clientList(group.id) == nil then return "unreadable" end
        return "empty"
    end
    if (container and container.drawn or 0) > 0 then return "drawing" end
    if group.kind == "buff" then return "idle" end
    return "unresolved"
end

local function buffRender(self, container)
    local group = container.group
    local maxWidth = math.max(80, (self.maxWidth or 400))
    local order = effectiveOrder(group)
    local active, states = {}, {}
    for _, spellID in ipairs(order) do
        local state = buffState(auraCandidates(spellID))
        if state then
            active[#active + 1] = spellID
            states[spellID] = state
        end
    end
    container.plan = Model:Plan({
        order = active, size = group.size, gap = group.gap, max = group.max,
        style = group.style, vertical = group.vertical,
    }, maxWidth)
    placeCells(container)
    container.unknown = 0
    container.inactive = #order - #active
    for index, spellID in ipairs(active) do
        local cell = container.cells[index]
        local state = states[spellID]
        if cell and state then
            app.PearlCell:Apply(cell, {
                icon = state.icon,
                count = state.count,
                remaining = state.remaining,
                state = state.remaining and "tracking" or "ready",
            })
            cell.lumaSpellID = spellID
            cell.lumaRemaining = state.remaining
        end
    end
    container.drawn = #active
end

local function renderOne(self, container)
    local group = container.group
    if group.kind == "buff" then
        buffRender(self, container)
        return
    end
    local maxWidth = math.max(80, (self.maxWidth or 400))
    -- The plan must count the same list the loop draws, or follow mode would lay
    -- out the stored copy and draw the client's.
    local order = effectiveOrder(group)
    container.plan = Model:Plan({
        order = order, size = group.size, gap = group.gap, max = group.max,
        style = group.style, vertical = group.vertical,
    }, maxWidth)
    placeCells(container)
    container.unknown = 0
    container.inactive = 0
    container.states = {}
    local drawn = 0
    for index, spellID in ipairs(order) do
        local cell = container.cells[index]
        if cell then
            -- The client's item may show an override (a proc that replaces the
            -- icon); the own cell follows the same decision.
            local shown = displaySpell(spellID)
            local info = spellInfo(shown)
            if not info then
                -- An entry that resolves to no spell leaves no cell behind: a row
                -- of empty squares over the action bar is not a display.
                app.PearlCell:Clear(cell)
                cell:Hide()
                container.unknown = container.unknown + 1
            else
                cell:Show()
                local state = spellState(shown)
                local label = state.unknown and "unknown"
                    or (state.proc and "proc")
                    or (state.remaining and "tracking" or "ready")
                container.states[label] = (container.states[label] or 0) + 1
                app.PearlCell:Apply(cell, {
                    icon = info.texture,
                    count = state.charges,
                    remaining = state.remaining,
                    start = state.start, duration = state.duration,
                    state = label,
                })
                cell.lumaSpellID = spellID
                cell.lumaRemaining = state.remaining
                drawn = drawn + 1
            end
        end
    end
    container.drawn = drawn
end

-- Gap between the two default blocks. The second group stacks above the first
-- instead of sharing its rectangle (the 013 review's shared-anchor defect).
local GROUP_GAP = 6
local layoutID = function(id) return "cdGroup_" .. id end

local function anchor(self, container)
    local central = app.Layout:Central()
    local plan = container.plan
    local height = plan and plan.height or 0
    local width = plan and (plan.capacity or plan.width) or 0
    if height <= 0 or width <= 0 then
        container.frame:Hide()
        container.visibleHeight = 0
        container.anchorSignature = nil
        return
    end
    -- The own block sits on the same baseline the native viewers use. The
    -- client's viewers stay where they are until the player turns them off in
    -- Edit Mode; `/luma cds` reports the overlap instead of hiding anything.
    -- `central.cooldown.bottom` counts up from the screen's bottom edge, and the
    -- layout entry stores its offset in the frame's own units (Layout:Apply
    -- scales the frame). Convert the screen offset once, then keep the block's
    -- own height and the stacking gap in the same unit, or the block drifts by
    -- (scale - 1) x its distance from the bottom as soon as the UI scale is not
    -- 1. Layout:CentralOffset and the utility corner convert the same way.
    local scale = app.Layout and app.Layout.Scale and app.Layout:Scale(layoutID(container.id)) or 1
    if type(scale) ~= "number" or scale <= 0 then scale = 1 end
    local bottom = (central.cooldown.bottom - central.screen.height / 2) / scale
    -- Groups are stacked in their fixed order: each one sits above the visible
    -- groups before it, so two non-empty groups never share a rectangle.
    for _, id in ipairs(Model.GROUP_IDS) do
        if id == container.id then break end
        local before = self.containers and self.containers[id]
        if before and (before.visibleHeight or 0) > 0 then
            bottom = bottom + before.visibleHeight + GROUP_GAP
        end
    end
    local y = bottom + height / 2
    container.visibleHeight = height
    -- The default goes into the layout entry; a saved position (dragged in
    -- `/luma layout`) wins inside Layout:Apply and the default stays the reset.
    -- An unchanged plan and default means nothing to write: event-driven
    -- redraws of cooldown state must not re-anchor the block.
    local signature = string.format("%.2f/%.2f/%.2f", y, height, width)
    if container.anchorSignature == signature and container.frame:IsShown() then return end
    container.anchorSignature = signature
    local entry = app.Layout.entries and app.Layout.entries[layoutID(container.id)]
    if entry then
        entry.x, entry.y = 0, y
        container.frame:Show()
        app.Layout:Apply(layoutID(container.id))
    else
        container.frame:ClearAllPoints()
        container.frame:SetPoint("CENTER", UIParent, "CENTER", 0, y)
        container.frame:Show()
    end
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
    container = { id = group.id, frame = frame, group = group, cells = {}, visibleHeight = 0 }
    if app.Layout and type(app.Layout.Register) == "function" then
        app.Layout:Register(layoutID(group.id), frame, 0, 0,
            app.L.cooldownGroups .. " · " .. group.id)
    end
    self.containers = self.containers or {}
    self.containers[group.id] = container
    return container
end

local function refreshGroup(self, container, ticking)
    if not self.running or not container then return end
    renderOne(self, container)
    if not ticking then anchor(self, container) end
end

-- Cooldown IDs are not always spell IDs (an equipped-item slot has a cooldown
-- entry of its own), and a cell can only draw a spell. Entries without a plain
-- spell ID are dropped instead of being guessed from the cooldown ID.
-- Builds before the settings provider existed still expose the mapping through
-- `C_CooldownViewer`; keep it so an older build imports the same spell IDs.
local function legacyImportSpell(cooldownID)
    local api = _G.C_CooldownViewer
    if type(api) ~= "table" or type(api.GetCooldownViewerCooldownInfo) ~= "function" then
        return cooldownID
    end
    local ok, info = pcall(api.GetCooldownViewerCooldownInfo, cooldownID)
    if not ok then return cooldownID end
    return type(info) == "table" and plainNumber(info.spellID) or nil
end

-- One importable ID per cooldown entry. The provider record is authoritative —
-- it knows the base spell, an override and the linked spells — and a trinket
-- without a base spell still has one of them. Only an entry with no spell at all
-- (a pure equip-slot entry) is skipped, and it is reported by `unresolved`.
local function importableSpell(cooldownID)
    local info = cooldownInfo(cooldownID)
    if not info then return legacyImportSpell(cooldownID) end
    local spell = plainNumber(info.spellID)
        or plainNumber(info.overrideSpellID)
        or plainNumber(info.overrideTooltipSpellID)
    if spell then return spell end
    if type(info.linkedSpellIDs) == "table" then
        for _, value in ipairs(info.linkedSpellIDs) do
            local id = plainNumber(value)
            if id then return id end
        end
    end
    return nil
end

toSpellIDs = function(ids)
    local list = {}
    for _, value in ipairs(ids or {}) do
        local cooldownID = plainNumber(value)
        if cooldownID then
            local spellID = importableSpell(cooldownID)
            if spellID then list[#list + 1] = spellID end
        end
    end
    return list
end

-- Reads the list the player actually configured. The Cooldown Manager's own
-- settings data provider is the same source its viewers render from, so an edit
-- in the client's CDM editor (order, hiding, a spell removed from the group) is
-- what `import` brings in. The documented category set is the fallback for
-- builds without the provider, and the legacy globals stay for older ones; a
-- missing source still changes nothing.
clientOrder = function(category)
    if category == nil then return nil end
    local settings = _G.CooldownViewerSettings
    if type(settings) == "table" and type(settings.GetDataProvider) == "function" then
        local okProvider, provider = pcall(settings.GetDataProvider, settings)
        if okProvider and type(provider) == "table"
            and type(provider.GetOrderedCooldownIDsForCategory) == "function" then
            local ok, list = pcall(provider.GetOrderedCooldownIDsForCategory, provider, category)
            if ok and type(list) == "table" and #list > 0 then
                local spells = toSpellIDs(list)
                if #spells > 0 then return spells end
            end
        end
    end
    local viewers = _G.C_CooldownViewer
    if type(viewers) == "table" then
        if type(viewers.GetCooldownViewerCategorySet) == "function" then
            local ok, list = pcall(viewers.GetCooldownViewerCategorySet, category, false)
            if ok and type(list) == "table" and #list > 0 then
                local spells = toSpellIDs(list)
                if #spells > 0 then return spells end
            end
        end
        if type(viewers.GetOrderedCooldownIDsForCategory) == "function" then
            local ok, list = pcall(viewers.GetOrderedCooldownIDsForCategory, category)
            if ok and type(list) == "table" and #list > 0 then
                local spells = toSpellIDs(list)
                if #spells > 0 then return spells end
            end
        end
    end
    if type(_G.GetOrderedCooldownIDsForCategory) == "function" then
        local ok, list = pcall(_G.GetOrderedCooldownIDsForCategory, category)
        if ok and type(list) == "table" and #list > 0 then
            local spells = toSpellIDs(list)
            if #spells > 0 then return spells end
        end
    end
    return nil
end

--------------------------------------------------------------------
-- Native viewer takeover (014 phase 02)
--------------------------------------------------------------------
-- The client's Essential and Utility viewers are exactly the two blocks these
-- groups replace, so they are hidden while LumaUI draws them: one stack of
-- cooldowns on screen instead of two. Nothing is disabled in the client's own
-- settings — the frames keep their state and come back the moment LumaUI stops
-- drawing them, and they stay visible whenever the player is editing them (the
-- Cooldown Manager editor or Edit Mode). That is the point of the handover: edit
-- the client's CDM, display LumaUI's.
local VIEWER_NAMES = {
    essential = "EssentialCooldownViewer",
    utility = "UtilityCooldownViewer",
    buffIcon = "BuffIconCooldownViewer",
    buffBar = "BuffBarCooldownViewer",
}

-- Which client viewer each own group replaces. The tracked buffs have two
-- renderings (icons and bars) for one list, so the buff group replaces both.
local VIEWER_GROUPS = {
    essential = { "essential" },
    utility = { "utility" },
    buffs = { "buffIcon", "buffBar" },
}

local function viewerFrame(id)
    local name = VIEWER_NAMES[id]
    return name and rawget(_G, name) or nil
end

-- True while the player is editing the client's cooldowns: the CDM settings
-- panel shows a live preview of the viewers, and Edit Mode puts them into
-- editing state so they can be dragged.
local function viewerIsBeingEdited(frame)
    if frame and type(frame.IsEditing) == "function" then
        local ok, editing = pcall(frame.IsEditing, frame)
        if ok and editing == true then return true end
    end
    local settings = rawget(_G, "CooldownViewerSettings")
    if settings and type(settings.IsVisible) == "function" then
        local ok, visible = pcall(settings.IsVisible, settings)
        if ok and visible == true then return true end
    end
    local manager = rawget(_G, "EditModeManagerFrame")
    if manager and type(manager.IsEditModeActive) == "function" then
        local ok, active = pcall(manager.IsEditModeActive, manager)
        if ok and active == true then return true end
    end
    return false
end

-- One category per group, mirroring the client's own Cooldown Manager tabs.
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
        for _, event in ipairs({ "SPELL_ACTIVATION_OVERLAY_GLOW_SHOW", "SPELL_ACTIVATION_OVERLAY_GLOW_HIDE" }) do
            pcall(self.Listen, self, event, function(current)
                app:Call(JOB, current.Refresh, current)
            end)
        end
        self:Listen("SPELLS_CHANGED", function(current)
            app:Call(JOB, current.Refresh, current)
        end)
        -- The buff group draws the player's auras, so an aura change is data:
        -- the icon, the stacks and the remaining time all move on this event.
        self:Listen("UNIT_AURA", function(current)
            app:Call(JOB, current.Refresh, current)
        end, "player")
        self:Listen("PLAYER_ENTERING_WORLD", function(current)
            app:Call(JOB, current.Refresh, current)
        end)
        self:Listen("PLAYER_REGEN_DISABLED", function(current) current:CancelDraft() end)
        app:Subscribe(self, "PROFILE_CHANGED", function(current)
            if self.running then self:CancelDraft() end
        end)
        app:Subscribe(self, "LAYOUT_CENTRAL_CHANGED", function()
            if self.running then app:Call(JOB, self.Reposition, self) end
        end)
        self:Render()
    end,
    Refresh = function(self)
        -- Every event-driven pass re-reads the client's Coolown Manager list; the
        -- ten-a-second ticker keeps using the cached copy.
        orderCache = {}
        self.maxWidth = (UIParent:GetWidth() or 1024) * MAX_WIDTH_RATIO
        self:Render()
    end,
    Disable = function(self)
        draft = nil
        stopTicker(self)
        for _, container in pairs(self.containers or {}) do
            container.frame:Hide()
            container.drawn = 0
        end
        -- Hand the client's viewers back before the component stops.
        local suppressed = {}
        for id in pairs(self.suppressed or {}) do suppressed[#suppressed + 1] = id end
        for _, id in ipairs(suppressed) do self:SuppressNativeViewer(id, false) end
        if app.Ownership then app.Ownership:Active("cooldownGroups", "native", "component-off") end
    end,
})

-- Hides the client's viewer for a group while that group is drawn, and puts it
-- back when the group stops drawing, the component stops or the player edits the
-- client's cooldowns. The client recomputes its own visibility often (edit-mode
-- layout, cvar change, combat change), so the suppression is re-applied after
-- its decision instead of writing anything into its settings.
function component:SuppressNativeViewer(id, active)
    local frame = viewerFrame(id)
    if not frame then return false end
    self.viewerHooks = self.viewerHooks or {}
    self.suppressed = self.suppressed or {}
    if active then
        if not self.viewerHooks[id] and type(frame.UpdateShownState) == "function"
            and type(hooksecurefunc) == "function" then
            self.viewerHooks[id] = true
            pcall(hooksecurefunc, frame, "UpdateShownState", function()
                if not (self.suppressed and self.suppressed[id]) then return end
                if viewerIsBeingEdited(frame) then return end
                if frame:IsShown() then pcall(frame.Hide, frame) end
            end)
        end
        self.suppressed[id] = true
        -- Only pay for the edit checks when the client just put it on screen.
        local okShown, shown = pcall(frame.IsShown, frame)
        if okShown and shown == true and not viewerIsBeingEdited(frame) then
            pcall(frame.Hide, frame)
        end
        return true
    end
    if not self.suppressed[id] then return false end
    self.suppressed[id] = nil
    -- Let the client decide again: it shows the viewer only when its own rules
    -- say so, so a CDM the player turned off stays off.
    if type(frame.UpdateShownState) == "function" then pcall(frame.UpdateShownState, frame) end
    return true
end

-- The spell ids the centre tracked-buff group is drawing right now, so the edge
-- aura rows can leave those out and no aura shows twice.
function component:TrackedSpells()
    local set = {}
    local container = self.running and self.containers and self.containers.buffs
    if container and (container.drawn or 0) > 0 and container.group then
        for _, spellID in ipairs(effectiveOrder(container.group)) do set[spellID] = true end
    end
    return set
end

function component:Render()
    if not self.running then return end
    -- Read-only databases hand back the raw defaults table, which never went
    -- through Store:Normalize; normalizing here is a pure read and keeps the
    -- renderer from indexing a missing group.
    local groups = effectiveGroups()
    local owned = groups.owned == true
    for _, id in ipairs(Model.GROUP_IDS) do
        local group = groups.groups[id]
        local container = self.containers[id] or ensureContainer(self, group)
        container.group = group
        local order = effectiveOrder(group)
        local drew = false
        if owned and group.enabled and #order > 0 then
            refreshGroup(self, container, false)
            drew = (container.drawn or 0) > 0
            -- A tracked-buff block with nothing active collapses completely: the
            -- rows below it move up instead of leaving a hole the size of the
            -- buff list that happens to be idle right now.
            if group.kind == "buff" and not drew then
                container.frame:Hide()
                container.visibleHeight = 0
                container.anchorSignature = nil
            end
        else
            container.frame:Hide()
            container.visibleHeight = 0
            container.anchorSignature = nil
            container.drawn = 0
            -- A block that stops drawing drops what its cells still report,
            -- otherwise the ticker keeps ticking for an invisible group.
            for _, cell in ipairs(container.cells or {}) do
                app.PearlCell:Clear(cell)
                cell:Hide()
            end
            container.plan = Model:Plan(group, self.maxWidth)
            -- An enabled but empty group stays invisible in play, yet keeps one
            -- icon-sized box so the layout editor can still select and drag it.
            local entry = app.Layout and app.Layout.entries and app.Layout.entries[layoutID(id)]
            local editable = owned and group.enabled and #order == 0
            if entry then entry.allowHiddenMove = editable or nil end
            -- The empty-group box is a size like any other: write it once, not on
            -- every cooldown event, or routine updates would re-layout the HUD.
            if editable and (container.placedWidth ~= group.size or container.placedHeight ~= group.size) then
                container.frame:SetSize(group.size, group.size)
                container.placedWidth, container.placedHeight = group.size, group.size
            end
        end
        -- The client's matching viewer steps aside whenever the own groups are
        -- the display: while this group draws, and while it is deliberately
        -- empty (enabling own groups means "replace the client's block", even
        -- before the first import). A group with entries that none resolve keeps
        -- the client's block instead of leaving an empty hole on screen.
        -- An empty cooldown group still replaces the client's block (that is the
        -- point of the takeover), but an empty buff list must not: nothing would
        -- be drawn for the buffs the player expects to see.
        local suppress
        if group.kind == "buff" then
            suppress = owned and group.enabled and drew
        else
            -- An unreadable source with no stored copy hands the block back.
            suppress = owned and group.enabled
                and (drew or (#order == 0 and groupStatus(owned, group, container, order) ~= "unreadable"))
        end
        local status = groupStatus(owned, group, container, order)
        container.status = status
        if app.Ownership then
            app.Ownership:Set("cooldownGroups." .. id, {
                intent = owned and "owned" or "native",
                active = (suppress and "owned") or "native",
                evidence = "simulated",
                reason = status ~= "drawing" and status or nil,
            })
        end
        for _, viewer in ipairs(VIEWER_GROUPS[id] or {}) do
            local keepBuff = (viewer == "buffIcon" or viewer == "buffBar")
                and groups.hideBuffViewers == false
            self:SuppressNativeViewer(viewer, suppress and not keepBuff)
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

-- Draft editing. `SetDraft` previews one option at once; `ApplyDraft` writes
-- every pending option in a single Store commit; `CancelDraft` restores the
-- applied look. Combat, a profile change, read-only and disabling discard it.
function component:HasDraft()
    return draft ~= nil
end

function component:DraftValue(id, key)
    local groups = effectiveGroups()
    return groups.groups[id] and groups.groups[id][key]
end

function component:SetDraft(id, key, value)
    if not isGroupID(id) or value == nil then return false end
    if InCombatLockdown() or app.Store.readonly then return false end
    draft = draft or {}
    draft[id] = draft[id] or {}
    draft[id][key] = value
    if self.running then self:Render() end
    return true
end

function component:ApplyDraft()
    if not draft then return false end
    local pending = draft
    local ok = self:Edit(function(groups)
        local changed = false
        for id, options in pairs(pending) do
            for key, value in pairs(options) do
                if groups.groups[id][key] ~= value then
                    groups.groups[id][key] = value
                    changed = true
                end
            end
        end
        return changed
    end)
    draft = nil
    if self.running then self:Render() end
    return ok
end

function component:CancelDraft()
    if not draft then return false end
    draft = nil
    if self.running then self:Render() end
    return true
end

function component:Reposition()
    if not self.running then return end
    for _, id in ipairs(Model.GROUP_IDS) do
        local container = self.containers and self.containers[id]
        if container and container.frame:IsShown() then anchor(self, container) end
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
    id = isGroupID(id) and id or "essential"
    local order = clientOrder(categoryOf(id))
    if not order then
        app:Print(app.L.cdsNoSource)
        return false
    end
    local added, replaced = 0, 0
    local ok = self:Edit(function(groups)
        local group = groups.groups and groups.groups[id]
        if not group then return false end
        group.auto = false
        added, replaced = Model:ApplyOrder(group, order, replace)
        return added > 0 or replaced > 0
    end)
    if ok then
        app:Print(string.format(app.L.cdsImported, id, added, replaced))
    elseif added == 0 and replaced == 0 then
        -- The list was read but held nothing new. Silence here reads as "the
        -- button does nothing", which is exactly the 013 report.
        app:Print(string.format(app.L.cdsImportUpToDate, id))
    end
    return ok
end

function component:Add(spellID, id)
    spellID = tonumber(spellID)
    if not spellID then
        app:Print(app.L.cdsUsage)
        return false
    end
    id = isGroupID(id) and id or "essential"
    local added = false
    local ok = self:Edit(function(groups)
        local group = groups.groups and groups.groups[id]
        if not group then return false end
        for _, current in ipairs(group.order) do
            if current == spellID then return false end
        end
        if #group.order >= Model.maxEntries then return false end
        group.auto = false
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
            local group = groups.groups[id]
            if Model:Remove(group, spellID) then
                group.auto = false
                removed = true
            end
        end
        return removed
    end)
    if removed then
        app:Print(string.format(app.L.cdsRemoved, spellID))
    else
        app:Print(app.L.cdsNotPresent)
    end
end

-- The mode switch, not a layout tweak: an owned group is what makes the own
-- cells (and therefore the proc state) draw at all. It is written at once
-- because the editor's Apply/Cancel draft only covers geometry.
function component:SetOwned(wanted)
    if InCombatLockdown() then return false end
    local owned = wanted == true
    if (profileGroups().owned == true) == owned then return true end
    return self:Edit(function(groups)
        groups.owned = owned
        return true
    end)
end

-- The tracked-buff viewers are not replaced by LumaUI, so hiding them is a
-- separate switch. Written at once for the same reason as `owned`.
function component:SetHideBuffViewers(wanted)
    if InCombatLockdown() then return false end
    wanted = wanted ~= false
    if (profileGroups().hideBuffViewers ~= false) == wanted then return true end
    return self:Edit(function(groups)
        groups.hideBuffViewers = wanted
        return true
    end)
end

-- Follow mode for one group: back to the client's Cooldown Manager list after a
-- manual add/remove/reorder turned the group into a stored copy.
function component:SetFollow(id, wanted)
    if InCombatLockdown() then return false end
    if not isGroupID(id) then return false end
    wanted = wanted ~= false
    local group = Model:Normalize(profileGroups()).groups[id]
    if group and (group.auto ~= false) == wanted then return true end
    return self:Edit(function(groups)
        local target = groups.groups and groups.groups[id]
        if not target then return false end
        target.auto = wanted
        return true
    end)
end

-- One numeric or boolean option of one group (`vertical`, `max`, `size`, `gap`),
-- validated by Model:Normalize on the way back in, so an out-of-range number is
-- clamped instead of stored.
function component:SetGroupOption(id, key, value)
    if not isGroupID(id) or value == nil then
        app:Print(app.L.cdsUsage)
        return false
    end
    return self:Edit(function(groups)
        local group = groups.groups[id]
        if group[key] == value then return false end
        group[key] = value
        return true
    end)
end

function component:MoveSpell(spellID, id, position)
    if not spellID or not isGroupID(id) then
        app:Print(app.L.cdsUsage)
        return false
    end
    local moved = self:Edit(function(groups)
        local ok = Model:Move(groups.groups, spellID, id, position)
        if ok then
            for _, groupID in ipairs(Model.GROUP_IDS) do groups.groups[groupID].auto = false end
        end
        return ok
    end)
    if not moved then app:Print(app.L.cdsNotPresent) end
    return moved
end

-- Drops the saved drag position so the group returns to its stacked default.
function component:ResetPosition(id)
    if not isGroupID(id) or not (app.Layout and app.Layout.entries) then
        app:Print(app.L.cdsUsage)
        return false
    end
    if InCombatLockdown() then return false end
    local key = layoutID(id)
    local positions = app.Store:Profile().positions
    if positions[key] == nil then return false end
    local copy = {}
    for name, value in pairs(positions) do if name ~= key then copy[name] = value end end
    if not app.Store:SetPositions(copy) then app:Print(app.L.readonly); return false end
    local container = self.containers and self.containers[id]
    if container then container.anchorSignature = nil end
    self:Reposition()
    return true
end

function component:Describe()
    if not self.running then return nil end
    local groups = Model:Normalize(profileGroups())
    local counts = {}
    for _, id in ipairs(Model.GROUP_IDS) do
        local container = self.containers and self.containers[id]
        counts[#counts + 1] = string.format("%s=%d/%d", id, container and container.drawn or 0,
            #effectiveOrder(groups.groups[id]))
    end
    return string.format("cooldownGroups: mode=%s %s", groups.owned and "owned" or "native",
        table.concat(counts, " "))
end

function component:Diagnose()
    local function yes(value) return value and "yes" or "no" end
    local groups = Model:Normalize(profileGroups())
    local viewers = {}
    for _, id in ipairs({ "essential", "utility", "buffIcon", "buffBar" }) do
        viewers[#viewers + 1] = string.format("%s=%s", id,
            self.suppressed and self.suppressed[id] and "hidden" or "kept")
    end
    app:Print(string.format("cooldownGroups: running=%s owned=%s buff-viewers=%s native-viewers=%s",
        yes(self.running), yes(groups.owned), groups.hideBuffViewers and "hide" or "keep",
        table.concat(viewers, ",")))
    for _, id in ipairs(Model.GROUP_IDS) do
        local group = groups.groups[id]
        local container = self.containers and self.containers[id]
        local order = effectiveOrder(group)
        local plan = container and container.plan or Model:Plan(group, self.maxWidth)
        local idle = ""
        if group.kind == "buff" then
            idle = string.format(" idle=%d", container and container.inactive or 0)
        end
        app:Print(string.format("  %s: status=%s", id, container and container.status or "off"))
        app:Print(string.format("  %s: entries=%d%s enabled=%s size=%d gap=%d max=%d rows=%d perRow=%d drawn=%s%s",
            id, #order, group.auto and " (auto)" or "", yes(group.enabled), group.size, group.gap, group.max,
            #plan.rows, plan.perRow or 0, container and tostring(container.drawn or 0) or "-", idle))
        if #order > 0 then
            local ids, unresolved = {}, 0
            for index, spellID in ipairs(order) do
                if not spellInfo(spellID) then unresolved = unresolved + 1 end
                if index <= 8 then ids[#ids + 1] = tostring(spellID) end
            end
            app:Print(string.format("    order: %s", table.concat(ids, " ")))
            local tally = {}
            for _, key in ipairs({ "tracking", "proc", "unknown", "ready" }) do
                local value = container and container.states and container.states[key]
                if value and value > 0 then tally[#tally + 1] = string.format("%s:%d", key, value) end
            end
            if #tally > 0 then app:Print("    states: " .. table.concat(tally, " ")) end
            -- One or two live probes: whether the client hands an addon plain
            -- numbers is what decides between a timer and an unknown cell.
            if group.kind == "buff" then
                local found = 0
                for _, spellID in ipairs(order) do
                    if buffState(auraCandidates(spellID)) then found = found + 1 end
                end
                app:Print(string.format("    auras: %d active", found))
            else
                for index = 1, math.min(2, #order) do
                    local spellID = order[index]
                    local api = _G.C_Spell
                    local ok, info = false, nil
                    if type(api) == "table" and type(api.GetSpellCooldown) == "function" then
                        ok, info = pcall(api.GetSpellCooldown, spellID)
                    end
                    local text
                    if not ok then text = "error"
                    elseif type(info) ~= "table" then text = "nil"
                    elseif plainNumber(info.startTime) == nil or plainNumber(info.duration) == nil then
                        text = "restricted"
                    else
                        text = string.format("start=%.1f dur=%.1f",
                            plainNumber(info.startTime) or 0, plainNumber(info.duration) or 0)
                    end
                    app:Print(string.format("    probe: %s %s", tostring(spellID), text))
                end
            end
            -- A listed spell the client cannot name or give an icon for is the
            -- reason a group draws nothing; say how many and which ones.
            if unresolved > 0 then
                local missing = {}
                for _, spellID in ipairs(order) do
                    if not spellInfo(spellID) and #missing < 4 then missing[#missing + 1] = tostring(spellID) end
                end
                app:Print(string.format("    unresolved: %d (%s)", unresolved, table.concat(missing, " ")))
            end
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
    elseif action == "buffs" then
        -- The tracked-buff viewers are not replaced, so this is its own switch.
        local wanted = not (profileGroups().hideBuffViewers ~= false)
        if self:SetHideBuffViewers(wanted) then
            app:Print(wanted and app.L.cdsBuffsHidden or app.L.cdsBuffsKept)
        end
    elseif action == "import" then
        local id, mode = argument:match("^(%S*)%s*(%S*)$")
        self:Import(id ~= "" and id or "essential", mode == "replace")
    elseif action == "add" then
        local id, group = argument:match("^(%S*)%s*(%S*)$")
        self:Add(id, group)
    elseif action == "remove" or action == "rm" then
        self:Remove(argument)
    elseif action == "layout" then
        local id, mode = argument:match("^(%S+)%s+(%S+)$")
        self:SetGroupOption(id, "vertical", mode and (mode:lower() == "v" or mode:lower() == "vertical"))
    elseif action == "max" or action == "size" or action == "gap" then
        local id, value = argument:match("^(%S+)%s+(%-?%d+)$")
        self:SetGroupOption(id, action, tonumber(value))
    elseif action == "move" then
        local spell, id, position = argument:match("^(%d+)%s+(%S+)%s*(%d*)$")
        self:MoveSpell(tonumber(spell), id, tonumber(position))
    elseif action == "reset" then
        self:ResetPosition(argument)
    elseif action == "clear" then
        local id = argument ~= "" and argument or nil
        self:Edit(function(groups)
            local changed = false
            for _, groupID in ipairs(Model.GROUP_IDS) do
                local group = groups.groups[groupID]
                if (not id or id == groupID) and #group.order > 0 then
                    group.order = {}
                    group.auto = false
                    changed = true
                end
            end
            return changed
        end)
    else
        self:Diagnose()
    end
end
