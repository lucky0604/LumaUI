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

local function nowSeconds()
    local ok, value = pcall(GetTime)
    return ok and plainNumber(value) or nil
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

-- A duration object from the client, or nil. These objects are the supported way
-- to hand a cooldown's timing to a client Cooldown widget: the object is passed
-- through untouched, so no start/end value is compared, subtracted or stored.
-- A secret object is not passed on either — the cell keeps its icon without a
-- sweep, which is truthful.
-- Documented shapes (checked against the 12.1.5 UI source): the cooldown form
-- takes `(spellIdentifier, ignoreGCD)`, the charge form only the identifier.
local function durationObject(spellID, charge)
    local api = _G.C_Spell
    if type(api) ~= "table" then return nil end
    local value
    if charge then
        if type(api.GetSpellChargeDuration) ~= "function" then return nil end
        local ok, result = pcall(api.GetSpellChargeDuration, spellID)
        value = ok and result or nil
    else
        if type(api.GetSpellCooldownDuration) ~= "function" then return nil end
        local ok, result = pcall(api.GetSpellCooldownDuration, spellID, true)
        value = ok and result or nil
    end
    if value == nil or app.Capabilities.IsSecret(value) then return nil end
    return value
end

-- One spell's live state. Plain numbers fill the text; the duration object, when
-- the build offers one, is handed to the client's own sweep. A restricted
-- cooldown record leaves the icon and marks the state unknown instead of
-- inventing a remaining time.
local function spellState(spellID)
    local api = _G.C_Spell
    local state = { start = nil, duration = nil, remaining = nil, charges = nil, maxCharges = nil }
    local now = nowSeconds()
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
    -- The client's own duration object, when this build has one. The cell passes
    -- it straight to `Cooldown:SetCooldownFromDurationObject`; nothing here reads
    -- a start or an end out of it.
    state.durationData = durationObject(spellID, state.charges ~= nil) or durationObject(spellID, false)
    -- Where the displayed state comes from, in plain words for the cell.
    if state.charges ~= nil then state.source = "charges"
    elseif state.unknown then state.source = "unknown"
    elseif state.remaining then state.source = "cooldown"
    elseif state.durationData then state.source = "duration"
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

-- One aura lookup for a tracked buff. Returns `state, readable`:
--   state    nil when the aura is not on the player
--   readable false when the aura API itself cannot answer, true when it can —
--            "no aura" and "cannot read auras" are different branches, and only
--            the first one means the buff is inactive.
local function buffState(spellIDs)
    local api = _G.C_UnitAuras
    if type(api) ~= "table" or type(api.GetPlayerAuraBySpellID) ~= "function" then return nil, false end
    local aura
    for _, id in ipairs(spellIDs or {}) do
        local ok, value = pcall(api.GetPlayerAuraBySpellID, id)
        if not ok then return nil, false end
        if type(value) == "table" then
            aura = value
            break
        end
    end
    if not aura then return nil, true end
    local icon = plainNumber(aura.icon)
    local expiration = plainNumber(aura.expirationTime)
    local duration = plainNumber(aura.duration)
    local applications = plainNumber(aura.applications)
    local now = nowSeconds()
    local remaining
    if expiration and now and expiration > 0 then
        remaining = math.max(0, expiration - now)
    elseif duration and duration > 0 then
        remaining = duration
    end
    -- A permanent aura reports duration 0: stacks stay, the timer stays empty.
    if remaining and remaining <= 0 then remaining = nil end
    -- The client can hand a duration object for this aura instance; it is passed
    -- straight to the cell's own Cooldown widget, never decomposed into start
    -- and duration here. A secret object is not passed on.
    local durationObject
    if type(api.GetAuraDuration) == "function" then
        local instance = plainNumber(aura.auraInstanceID)
        if instance then
            local ok, value = pcall(api.GetAuraDuration, "player", instance)
            if ok and value ~= nil and not app.Capabilities.IsSecret(value) then durationObject = value end
        end
    end
    return { icon = icon, count = applications, remaining = remaining,
        durationObject = durationObject }, true
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
local clientOrder, toSpellIDs, rawCategoryList, importableSpell

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

-- The client's own viewer for a group is the most faithful source: its item list
-- is exactly what the player sees and edits, whatever category that viewer was
-- configured with.
local GROUP_VIEWERS = {
    essential = { "EssentialCooldownViewer" },
    utility = { "UtilityCooldownViewer" },
    buffs = { "BuffIconCooldownViewer", "BuffBarCooldownViewer" },
}

-- One read of one viewer. `nil` means "this viewer could not answer" (absent,
-- threw, or is not a list); an empty table is a real answer: the player has no
-- entries configured there. Conflating those two is what made a confirmed empty
-- group and a transient read failure take the same branch.
local function readViewer(name)
    local frame = name and rawget(_G, name)
    if not frame or type(frame.GetCooldownIDs) ~= "function" then return nil, "absent" end
    local ok, list = pcall(frame.GetCooldownIDs, frame)
    if not ok then return nil, "error" end
    if type(list) ~= "table" then return nil, "no-list" end
    return list, nil
end

-- The provider fallback. It answers for a category, not for a viewer, so it is
-- the second choice: a build without viewers can still read the same order.
local function providerList(id)
    if not rawCategoryList then return nil end
    local list = rawCategoryList(categoryOf(id))
    if type(list) == "table" then return list end
    return nil
end

----------------------------------------------------------------------
-- Session manifest
----------------------------------------------------------------------
-- The saved group configuration and the client's live list are different
-- objects and live in different places:
--
--   * profile     what the player configured (`order`, `max`, `limit`, ...)
--   * manifest    what the client currently says, read on identity and source
--                 changes, cached as the last complete readable copy
--   * live state  per-cell cooldown/charge/aura values, re-read on their events
--
-- An ordinary cooldown or aura tick no longer touches the manifest. A provider
-- that blinks out for one event therefore keeps the last complete list instead
-- of dropping the group back to the client's viewer, while a confirmed empty
-- list still clears the display.
local manifest = { identity = nil, groups = {} }

local function identity()
    local spec
    if type(GetSpecialization) == "function" then
        local ok, value = pcall(GetSpecialization)
        spec = ok and plainNumber(value) or nil
    end
    return { profile = app.Store.current, spec = spec or 0 }
end

local function sameIdentity(a, b)
    return type(a) == "table" and type(b) == "table"
        and a.profile == b.profile and a.spec == b.spec
end

-- Which client viewer answers for a group right now, in priority order. The
-- tracked-buff group has two renderings for one list; they are reported apart.
local function readGroupManifest(id)
    local viewers = GROUP_VIEWERS[id] or {}
    local reasons = {}
    for _, name in ipairs(viewers) do
        local list, problem = readViewer(name)
        if list then
            local entries, unmapped = {}, 0
            for _, value in ipairs(list) do
                local cooldownID = plainNumber(value)
                if cooldownID then
                    local spell = importableSpell(cooldownID)
                    if spell then
                        entries[#entries + 1] = { cooldownID = cooldownID, spellID = spell, viewer = name }
                    else
                        unmapped = unmapped + 1
                        entries[#entries + 1] = { cooldownID = cooldownID, viewer = name }
                    end
                end
            end
            return {
                status = (#entries == 0 and "empty") or (unmapped > 0 and "partial") or "complete",
                entries = entries, viewer = name, unmapped = unmapped, source = "viewer",
            }
        end
        if problem then reasons[#reasons + 1] = name .. ":" .. problem end
    end
    local list = providerList(id)
    if list then
        local entries, unmapped = {}, 0
        for _, value in ipairs(list) do
            local cooldownID = plainNumber(value)
            if cooldownID then
                -- The provider record is authoritative for the mapping; the
                -- cooldown ID itself is never used as a spell ID.
                local spell = importableSpell(cooldownID)
                if spell then
                    entries[#entries + 1] = { cooldownID = cooldownID, spellID = spell, source = "provider" }
                else
                    unmapped = unmapped + 1
                    entries[#entries + 1] = { cooldownID = cooldownID, source = "provider" }
                end
            end
        end
        return {
            status = (#entries == 0 and "empty") or (unmapped > 0 and "partial") or "complete",
            entries = entries, viewer = "provider", unmapped = unmapped, source = "provider",
        }
    end
    return { status = "unreadable", entries = {}, reason = table.concat(reasons, ","), source = nil }
end

-- Re-reads one group's source and replaces the cache. A readable answer (even an
-- empty one) is authoritative; an unreadable one keeps the last readable copy
-- for the same profile/spec, so a source that blinks for one event does not
-- drop the group back to the client's viewer. Without any copy the status stays
-- "unreadable" and the caller hands that group back.
local function readManifest(group)
    local id = group.id
    local current = identity()
    if not sameIdentity(manifest.identity, current) then
        -- A different profile or specialization invalidates every cached list:
        -- reusing them would show another character's skills.
        manifest.identity, manifest.groups = current, {}
    end
    local previous = manifest.groups[id]
    local read = readGroupManifest(id)
    local entry = previous or { id = id }
    entry.pending = nil
    if read.status ~= "unreadable" then
        entry.status, entry.entries, entry.snapshot = read.status, read.entries, true
        entry.source, entry.viewer, entry.reason = read.source, read.viewer, read.reason
        entry.unmapped = read.unmapped or 0
        entry.empty = read.status == "empty"
        entry.stale = nil
        entry.time = nowSeconds() or 0
    else
        entry.unmapped = 0
        if not entry.snapshot then
            entry.status, entry.entries = "unreadable", entry.entries or {}
            entry.source, entry.reason = nil, read.reason
        else
            -- With a snapshot the status stays whatever that snapshot said; the
            -- blink is reported in `stale` instead of changing the display.
            entry.stale = true
        end
    end
    manifest.groups[id] = entry
    return entry
end

-- The cached manifest, read once per identity/source change. The cooldown
-- ticker and every ordinary refresh go through here: they never walk the
-- client's provider.
local function manifestFor(group)
    if not group then return { status = "unreadable", entries = {} } end
    local current = identity()
    if not sameIdentity(manifest.identity, current) then
        manifest.identity, manifest.groups = current, {}
    end
    local entry = manifest.groups[group.id]
    -- An entry that never produced a list is retried: the client can load its
    -- viewers late. An entry with a snapshot is not re-read here unless a source
    -- event marked it.
    if entry and not entry.pending and (entry.snapshot or entry.status ~= "unreadable") then return entry end
    return readManifest(group)
end

-- A source or identity change marks the cached lists for a re-read on the next
-- render. The previous readable copy is kept so one unreadable event cannot
-- erase what is on screen. Ordinary cooldown, charge and aura events do not
-- call this.
local function invalidateManifest(id)
    for key, entry in pairs(manifest.groups) do
        if not id or key == id then entry.pending = true end
    end
end

-- Spell ids a group draws right now, with the manifest status that produced
-- them. `unmapped` counts entries the client listed but this build cannot name
-- as a spell; they leave a reported gap instead of an empty square.
local function groupList(group, entries)
    entries = entries or manifestFor(group)
    local list, unmapped = {}, entries.unmapped or 0
    if entries.status == "unreadable" then return list, entries, unmapped end
    for _, item in ipairs(entries.entries or {}) do
        if item.spellID then list[#list + 1] = item.spellID end
    end
    return list, entries, unmapped
end

-- A group's list: the player's own Cooldown Manager by default (`auto`), and the
-- stored copy once anything was added, removed or reordered by hand.
local function effectiveOrder(group, entries)
    if group and group.auto then
        local list, status = groupList(group, entries)
        return list, status
    end
    if not group then return {}, nil end
    -- A stored copy is the player's explicit list; it has no source to be
    -- unreadable from, though entries may still fail to resolve.
    return group.order or {}, { status = "manual", entries = {}, source = "manual" }
end

-- The total display cap. `max` keeps its historical meaning (icons per row);
-- `limit` is how many entries of the list are shown at all. Trimming happens
-- before the row plan so the geometry follows the number actually drawn.
local function cappedList(list, group)
    local limit = group and plainNumber(group.limit) or nil
    if not limit or limit >= #list then return list end
    local trimmed = {}
    for index = 1, math.max(0, math.floor(limit)) do trimmed[index] = list[index] end
    return trimmed
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

-- One word per group for what is on screen and why, so "nothing drawn" is never
-- ambiguous:
--   off          the group is switched off or the own mode is off
--   unreadable   the client's list cannot be read and no complete copy exists
--   stale        the source blinked; the last complete copy is being drawn
--   partial      the list was read but some entries cannot be named as spells
--   empty        a readable empty list
--   idle         tracked buffs are listed but none is active
--   unresolved   entries are listed but none can be drawn
--   drawing      at least one cell is drawn
local function groupStatus(owned, group, container, order, entries)
    if not owned or not group.enabled then return "off" end
    local status = entries and entries.status or (group.auto and "unreadable" or "manual")
    if group.kind == "buff" and entries and entries.readable == false then return "unreadable" end
    if group.auto and status == "unreadable" then return "unreadable" end
    if (container and container.drawn or 0) > 0 then
        if group.auto and entries and entries.stale then return "stale" end
        if group.auto and status == "partial" then return "partial" end
        return "drawing"
    end
    if #order == 0 then
        if group.auto and status == "unreadable" then return "unreadable" end
        return "empty"
    end
    if group.kind == "buff" then return "idle" end
    return "unresolved"
end

local function buffRender(self, container)
    local group = container.group
    local maxWidth = math.max(80, (self.maxWidth or 400))
    local order, entries = effectiveOrder(group)
    order = cappedList(order, group)
    local active, states, readable = {}, {}, true
    for _, spellID in ipairs(order) do
        local state, canRead = buffState(auraCandidates(spellID))
        if canRead == false then readable = false end
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
                durationObject = state.durationObject,
                state = (state.remaining or state.durationObject) and "tracking" or "ready",
            })
            cell.lumaSpellID = spellID
            cell.lumaRemaining = state.remaining
        end
    end
    container.drawn = #active
    -- Auras the client cannot read at all keep the native buff viewers: nothing
    -- on screen may silently replace them with an empty block.
    container.auraReadable = readable
    if entries then entries.readable = readable end
end

local function renderOne(self, container)
    local group = container.group
    if group.kind == "buff" then
        buffRender(self, container)
        return
    end
    local maxWidth = math.max(80, (self.maxWidth or 400))
    -- The plan must count the same list the loop draws, or follow mode would lay
    -- out the stored copy and draw the client's. The total cap is applied before
    -- the row plan, so the geometry follows the number of icons on screen.
    local order, entries = effectiveOrder(group)
    order = cappedList(order, group)
    container.manifest = entries
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
                    or (state.remaining and "tracking" or (state.durationData and "tracking" or "ready"))
                container.states[label] = (container.states[label] or 0) + 1
                app.PearlCell:Apply(cell, {
                    icon = info.texture,
                    count = state.charges,
                    remaining = state.remaining,
                    start = state.start, duration = state.duration,
                    durationObject = state.durationData,
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
importableSpell = function(cooldownID)
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

-- The raw cooldown-ID list the player configured, in the client's order. The
-- Cooldown Manager's own settings data provider is the same source its viewers
-- render from, so an edit in the client's CDM editor (order, hiding, a spell
-- removed from the group) is what the manifest sees. The documented category set
-- is the fallback for builds without the provider, and the legacy globals stay
-- for older ones.
--
-- A table is always an answer, even an empty one: `{}` means "the player has
-- nothing configured here", `nil` means "this source could not answer". An empty
-- answer with `#list == 0` used to fall through to the next source, which is how
-- a confirmed empty group became indistinguishable from an unreadable one.
rawCategoryList = function(category)
    if category == nil then return nil end
    local settings = _G.CooldownViewerSettings
    if type(settings) == "table" and type(settings.GetDataProvider) == "function" then
        local okProvider, provider = pcall(settings.GetDataProvider, settings)
        if okProvider and type(provider) == "table"
            and type(provider.GetOrderedCooldownIDsForCategory) == "function" then
            local ok, list = pcall(provider.GetOrderedCooldownIDsForCategory, provider, category)
            if ok and type(list) == "table" then return list end
        end
    end
    local viewers = _G.C_CooldownViewer
    if type(viewers) == "table" then
        if type(viewers.GetCooldownViewerCategorySet) == "function" then
            local ok, list = pcall(viewers.GetCooldownViewerCategorySet, category, false)
            if ok and type(list) == "table" then return list end
        end
        if type(viewers.GetOrderedCooldownIDsForCategory) == "function" then
            local ok, list = pcall(viewers.GetOrderedCooldownIDsForCategory, category)
            if ok and type(list) == "table" then return list end
        end
    end
    if type(_G.GetOrderedCooldownIDsForCategory) == "function" then
        local ok, list = pcall(_G.GetOrderedCooldownIDsForCategory, category)
        if ok and type(list) == "table" then return list end
    end
    return nil
end

-- The same list as spell IDs, for callers that only need drawable spells.
-- Entries the client lists but this build cannot name are skipped here; the
-- manifest counts them separately.
clientOrder = function(category)
    local list = rawCategoryList(category)
    if list == nil then return nil end
    return toSpellIDs(list)
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
        -- Live state events: they re-read the cells, never the client's list.
        -- This is what keeps a counting cooldown from walking the manifest ten
        -- times a second and from dropping the block when the provider blinks.
        local function stateEvent(event)
            self:Listen(event, function(current)
                app:Call(JOB, current.Refresh, current)
            end)
        end
        stateEvent("SPELL_UPDATE_COOLDOWN")
        stateEvent("SPELL_UPDATE_CHARGES")
        stateEvent("SPELL_ACTIVATION_OVERLAY_GLOW_SHOW")
        stateEvent("SPELL_ACTIVATION_OVERLAY_GLOW_HIDE")
        -- `UNIT_AURA` for the player is state too: the buff group draws the
        -- aura's icon, stacks and remaining time.
        self:Listen("UNIT_AURA", function(current)
            app:Call(JOB, current.Refresh, current)
        end, "player")
        -- Source events: the client's list itself changed. These are the only
        -- places that rebuild the manifest.
        local function sourceEvent(event)
            self:Listen(event, function(current)
                app:Call(JOB, current.RefreshSource, current)
            end)
        end
        sourceEvent("SPELLS_CHANGED")
        sourceEvent("PLAYER_ENTERING_WORLD")
        for _, event in ipairs({ "PLAYER_SPECIALIZATION_CHANGED", "TRAIT_CONFIG_UPDATED",
            "PLAYER_EQUIPMENT_CHANGED", "COOLDOWN_VIEWER_SETTINGS_CHANGED",
            "EDIT_MODE_LAYOUTS_UPDATED" }) do
            pcall(self.Listen, self, event, function(current)
                app:Call(JOB, current.RefreshSource, current)
            end)
        end
        self:Listen("PLAYER_REGEN_DISABLED", function(current) current:CancelDraft() end)
        app:Subscribe(self, "PROFILE_CHANGED", function(current)
            if self.running then self:CancelDraft() end
        end)
        app:Subscribe(self, "LAYOUT_CENTRAL_CHANGED", function()
            if self.running then app:Call(JOB, self.Reposition, self) end
        end)
        self:Render()
    end,
    -- Live-state pass: keeps the manifest and the applied geometry, re-reads the
    -- cells. Ordinary cooldown, charge, proc and aura events land here.
    Refresh = function(self)
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

-- Requests the client's viewer to be hidden and reads the effective state back.
-- `pcall(Hide)` returning true only means the call did not throw; a refused
-- write leaves the viewer on screen and the group must not claim to own it.
-- Returns hidden:boolean, problem:string|nil.
function component:ApplyViewerHidden(id, frame)
    frame = frame or viewerFrame(id)
    if not frame then return false, "absent" end
    self.hidden = self.hidden or {}
    if viewerIsBeingEdited(frame) then
        self.hidden[id] = nil
        return false, "editing"
    end
    local okShown, shown = pcall(frame.IsShown, frame)
    if not okShown then
        self.hidden[id] = nil
        return false, "unreadable"
    end
    if shown == true then
        local okCall = pcall(frame.Hide, frame)
        local okRead, after = pcall(frame.IsShown, frame)
        if not okCall or not okRead or after ~= false then
            self.hidden[id] = nil
            return false, "hide-refused"
        end
    end
    -- A hidden child of a hidden parent is not "visible"; IsVisible covers the
    -- parent chain where the build has it. A viewer left at alpha 0 is also not
    -- on screen, and reading that is the third check the client offers.
    local okVisible, visible = pcall(frame.IsVisible, frame)
    if okVisible and visible == true then
        local okAlpha, alpha = pcall(frame.GetAlpha, frame)
        alpha = okAlpha and plainNumber(alpha) or nil
        if not alpha or alpha > 0.01 then
            self.hidden[id] = nil
            return false, "still-visible"
        end
    end
    self.hidden[id] = true
    return true
end

-- Hides the client's viewer for a group while that group is drawn, and puts it
-- back when the group stops drawing, the component stops or the player edits the
-- client's cooldowns. The client recomputes its own visibility often (edit-mode
-- layout, cvar change, combat change), so the suppression is re-applied after
-- its decision instead of writing anything into its settings.
-- The returned flag is the read-back result, not "the call was made".
function component:SuppressNativeViewer(id, active)
    local frame = viewerFrame(id)
    self.viewerHooks = self.viewerHooks or {}
    self.suppressed = self.suppressed or {}
    self.hidden = self.hidden or {}
    if active then
        -- No frame at all means the client has no such display in this session
        -- (the viewers load with their own addon). Nothing can be on screen, so
        -- the own layer is the only display; report the absence instead of
        -- dropping our block for a viewer that does not exist.
        if not frame then
            self.suppressed[id] = true
            self.hidden[id] = true
            return true, "absent"
        end
        if not self.viewerHooks[id] and type(frame.UpdateShownState) == "function"
            and type(hooksecurefunc) == "function" then
            self.viewerHooks[id] = true
            pcall(hooksecurefunc, frame, "UpdateShownState", function()
                if not (self.suppressed and self.suppressed[id]) then return end
                if viewerIsBeingEdited(frame) then return end
                if frame:IsShown() then pcall(frame.Hide, frame) end
                -- Re-read after the client's own decision so the ownership record
                -- never says "hidden" while the viewer is on screen.
                if component.running then component:ApplyViewerHidden(id, frame) end
            end)
        end
        self.suppressed[id] = true
        return self:ApplyViewerHidden(id, frame)
    end
    if not self.suppressed[id] then return false, "not-suppressed" end
    self.suppressed[id] = nil
    self.hidden[id] = nil
    -- Let the client decide again: it shows the viewer only when its own rules
    -- say so, so a CDM the player turned off stays off.
    if frame and type(frame.UpdateShownState) == "function" then pcall(frame.UpdateShownState, frame) end
    return true, "released"
end

-- The spell ids the centre tracked-buff group is drawing right now, so the edge
-- aura rows can leave those out and no aura shows twice.
function component:TrackedSpells()
    local set = {}
    local container = self.running and self.containers and self.containers.buffs
    if container and (container.drawn or 0) > 0 and container.group then
        local list = effectiveOrder(container.group)
        for _, spellID in ipairs(list) do set[spellID] = true end
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
        local order, entries = effectiveOrder(group)
        order = cappedList(order, group)
        local drew = false
        local drawnNow = false
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
        -- be drawn for the buffs the player expects to see, and an unreadable
        -- aura list must never replace them either.
        local status = groupStatus(owned, group, container, order, entries)
        local suppress
        if group.kind == "buff" then
            suppress = owned and group.enabled and drew and container.auraReadable ~= false
        elseif group.auto then
            -- Automatic lists replace the block only when the client's list was
            -- read. `partial` keeps the native block: an entry that cannot be
            -- named here is still drawn by the client, and hiding it would lose
            -- a trinket or an equip-slot cooldown. `empty` is a confirmed answer
            -- and does replace it.
            suppress = owned and group.enabled
                and (entries and (entries.status == "complete" or entries.status == "empty"))
                and (drew or #order == 0)
        else
            -- A stored copy is the player's own list; there is no source to wait
            -- for. Entries that resolve to nothing hand the block back.
            suppress = owned and group.enabled and (drew or #order == 0)
        end
        -- Handover per viewer: hide, read the result back, and only then claim
        -- the block. A refused hide disables this group's own layer instead of
        -- leaving two displays on screen.
        local verified, problem = false, nil
        for _, viewer in ipairs(VIEWER_GROUPS[id] or {}) do
            local keepBuff = (viewer == "buffIcon" or viewer == "buffBar")
                and groups.hideBuffViewers == false
            if suppress and not keepBuff then
                local hidden, why = self:SuppressNativeViewer(viewer, true)
                if hidden then
                    verified = true
                else
                    problem = problem or why
                end
            else
                self:SuppressNativeViewer(viewer, false)
            end
        end
        if suppress and not verified then
            -- Nothing could be handed over: drop our layer for this group so the
            -- client's own viewer is the only display, and name the reason.
            container.frame:Hide()
            container.visibleHeight = 0
            container.anchorSignature = nil
            container.drawn = 0
            for _, cell in ipairs(container.cells or {}) do
                app.PearlCell:Clear(cell)
                cell:Hide()
            end
            status = "handover-" .. tostring(problem or "unknown")
        elseif suppress and problem then
            -- At least one viewer of a two-viewer group stayed visible; the
            -- block is still owned and the exception is reported.
            status = "partial"
        end
        container.status = status
        container.source = entries and entries.source
        container.stale = entries and entries.stale == true
        if app.Ownership then
            app.Ownership:Set("cooldownGroups." .. id, {
                intent = owned and "owned" or "native",
                active = (suppress and verified) and "owned" or "native",
                evidence = "simulated",
                reason = status ~= "drawing" and status or nil,
            })
        end
        -- Per-viewer records live under their own namespace: a group id and one
        -- viewer id can be the same word ("utility"), and one must never
        -- overwrite the other's record.
        for _, viewer in ipairs(VIEWER_GROUPS[id] or {}) do
            local groupRecord = app.Ownership and app.Ownership:Get("cooldownGroups." .. id)
            if groupRecord then
                local hiddenNow = self.hidden and self.hidden[viewer]
                app.Ownership:Set("cooldownGroups.viewer." .. viewer, {
                    intent = groupRecord.intent,
                    active = hiddenNow and "owned" or "native",
                    evidence = "simulated",
                    reason = hiddenNow and nil
                        or ((self.suppressed and self.suppressed[viewer]) and "hide-refused" or "client-managed"),
                })
            end
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

-- Source pass: the client's own list changed (spells, specialization, talents,
-- equipment, a Cooldown Manager edit). Only this path rebuilds the manifest.
function component:RefreshSource()
    if not self.running then return end
    invalidateManifest()
    self:Refresh()
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
    -- The viewer's own list is what the player arranged; the category lookup is
    -- the fallback for a build without that viewer. Entries the client lists but
    -- this build cannot name are counted, not silently dropped into the copy.
    local read = readGroupManifest(id)
    local order, unmapped = {}, 0
    if read.status ~= "unreadable" then
        for _, item in ipairs(read.entries) do
            if item.spellID then order[#order + 1] = item.spellID else unmapped = unmapped + 1 end
        end
    end
    if #order == 0 then
        local fallback = clientOrder(categoryOf(id))
        if fallback then order = fallback end
    end
    if read.status == "unreadable" and #order == 0 then
        app:Print(app.L.cdsNoSource)
        return false
    end
    if unmapped > 0 then
        app:Print(string.format(app.L.cdsImportUnmapped, unmapped))
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
        -- Readback state, not the request: `hidden` means the frame reported
        -- itself off screen after the write.
        local state = "kept"
        if self.hidden and self.hidden[id] then state = "hidden"
        elseif self.suppressed and self.suppressed[id] then state = "refused" end
        viewers[#viewers + 1] = string.format("%s=%s", id, state)
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
        local manifest = manifest.groups[id]
        app:Print(string.format("  %s: status=%s", id, container and container.status or "off"))
        app:Print(string.format("  %s: entries=%d%s enabled=%s size=%d gap=%d max=%d limit=%d rows=%d perRow=%d drawn=%s%s",
            id, #order, group.auto and " (auto)" or "", yes(group.enabled), group.size, group.gap, group.max,
            group.limit, #plan.rows, plan.perRow or 0, container and tostring(container.drawn or 0) or "-", idle))
        -- Where the list came from and whether the last read worked. No timing
        -- values, no entry names: a reader can tell a stale snapshot from an
        -- unreadable source without seeing a single restricted number.
        app:Print(string.format("    source=%s snapshot=%s stale=%s unmapped=%d",
            tostring(manifest and manifest.source or "-"), yes(manifest and manifest.snapshot),
            yes(manifest and manifest.stale), manifest and manifest.unmapped or 0))
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
