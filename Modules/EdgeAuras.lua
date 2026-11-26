local _, app = ...

-- Phase 09 (015): the player's full buffs and debuffs at the screen edge.
-- Responsibilities, kept separate on purpose:
--   regular buffs / debuffs   drawn here from plain aura data
--   tracked buffs (centre)    drawn by cooldownGroups; an aura it already draws
--                             is skipped here so nothing shows twice
--   private auras             never readable; they keep the client's own anchor
--                             mechanism (UnitFrames / UnitGroup), reported as such
-- The client's BuffFrame / DebuffFrame step aside only while this module drew a
-- complete, readable list. One restricted aura entry, a missing API or a
-- failed build keeps the client's frames, so an aura is never lost.

local ID = "edgeAuras"
local SIZE, GAP, PER_ROW, MAX = 30, 4, 12, 36
local component
local ticker

local function plain(value, kind) return app.Capabilities.Plain(value, kind) end

local function stopTicker()
    if ticker then ticker:Cancel(); ticker = nil end
end

-- Spells the centre tracked-buff group is drawing right now.
local function trackedSet()
    local groups = app.components and app.components.cooldownGroups
    if groups and type(groups.TrackedSpells) == "function" then return groups:TrackedSpells() end
    return {}
end

-- One filter's readable list. `complete` is false when any entry could not be
-- read as plain data, which keeps the client's frame in place.
local function read(filter, skip)
    local api = rawget(_G, "C_UnitAuras")
    if type(api) ~= "table" or type(api.GetAuraDataByIndex) ~= "function" then return nil, false end
    local list, complete = {}, true
    for index = 1, MAX do
        local ok, data = pcall(api.GetAuraDataByIndex, "player", index, filter)
        if not ok then return list, false end
        if data == nil then break end
        if type(data) ~= "table" then complete = false; break end
        local icon = plain(data.icon, "number") or plain(data.icon, "string")
        if icon == nil then
            complete = false
        else
            local spellID = plain(data.spellId, "number")
            if not (spellID and skip[spellID]) then
                list[#list + 1] = {
                    index = index, filter = filter, icon = icon,
                    name = plain(data.name, "string"),
                    id = plain(data.auraInstanceID, "number"),
                    count = plain(data.applications, "number") or 0,
                    duration = plain(data.duration, "number") or 0,
                    expires = plain(data.expirationTime, "number") or 0,
                }
            end
        end
    end
    return list, complete
end

local function cellFor(row, index)
    local cell = row.cells[index]
    if cell then return cell end
    cell = CreateFrame("Button", nil, row.frame, "BackdropTemplate")
    cell:SetSize(SIZE, SIZE)
    cell:RegisterForClicks("AnyUp")
    cell.icon = cell:CreateTexture(nil, "ARTWORK")
    cell.icon:SetAllPoints()
    cell.count = app.Theme:Text(cell, 11)
    cell.count:SetPoint("BOTTOMRIGHT", -1, 1)
    cell.time = app.Theme:Text(cell, 10, true)
    cell.time:SetPoint("TOP", cell, "BOTTOM", 0, -1)
    cell:SetScript("OnEnter", function(self)
        local item = self.item
        if not item or not GameTooltip then return end
        pcall(function()
            GameTooltip:SetOwner(self, "ANCHOR_BOTTOMLEFT")
            if item.id and GameTooltip.SetUnitAuraByAuraInstanceID then
                GameTooltip:SetUnitAuraByAuraInstanceID("player", item.id, item.filter)
            elseif GameTooltip.SetUnitAura then
                GameTooltip:SetUnitAura("player", item.index, item.filter)
            end
            GameTooltip:Show()
        end)
    end)
    cell:SetScript("OnLeave", function() if GameTooltip then pcall(GameTooltip.Hide, GameTooltip) end end)
    -- Only buffs cancel, and only through the client's own call, out of combat.
    cell:SetScript("OnClick", function(self, button)
        local item = self.item
        if button ~= "RightButton" or not item or item.filter ~= "HELPFUL" then return end
        if InCombatLockdown() then app:Print(app.L.edgeAuraCombat); return end
        if type(CancelSpellByName) == "function" and item.name then pcall(CancelSpellByName, item.name) end
    end)
    row.cells[index] = cell
    return cell
end

local function timeText(remaining)
    if remaining >= 3600 then return string.format("%dh", math.ceil(remaining / 3600)) end
    if remaining >= 60 then return string.format("%dm", math.ceil(remaining / 60)) end
    return string.format("%d", math.max(0, math.ceil(remaining)))
end

local function paintRow(row, list)
    local now = type(GetTime) == "function" and plain(GetTime(), "number") or 0
    local timed = false
    for index, item in ipairs(list) do
        local cell = cellFor(row, index)
        cell.item = item
        cell:ClearAllPoints()
        local col, line = (index - 1) % PER_ROW, math.floor((index - 1) / PER_ROW)
        cell:SetPoint("TOPRIGHT", row.frame, "TOPRIGHT", -col * (SIZE + GAP), -line * (SIZE + GAP + 12))
        cell.icon:SetTexture(item.icon)
        cell.count:SetText(item.count > 1 and tostring(item.count) or "")
        if item.duration > 0 and item.expires > 0 then
            timed = true
            cell.time:SetText(timeText(item.expires - now))
        else
            cell.time:SetText("")
        end
        cell:Show()
    end
    for index = #list + 1, #row.cells do
        row.cells[index].item = nil
        row.cells[index]:Hide()
    end
    row.frame:SetShown(#list > 0)
    return timed
end

local function suppressNative(self, active)
    for _, name in ipairs({ "BuffFrame", "DebuffFrame" }) do
        local frame = rawget(_G, name)
        if frame then
            self.native = self.native or {}
            if active then
                if not self.native[name] then
                    self.native[name] = { alpha = frame:GetAlpha(), mouse = frame.IsMouseEnabled and frame:IsMouseEnabled() or false }
                end
                pcall(frame.SetAlpha, frame, 0)
                if frame.EnableMouse then pcall(frame.EnableMouse, frame, false) end
            elseif self.native[name] then
                local saved = self.native[name]
                self.native[name] = nil
                pcall(frame.SetAlpha, frame, saved.alpha)
                if frame.EnableMouse then pcall(frame.EnableMouse, frame, saved.mouse) end
            end
        end
    end
end

local function update(self)
    if not self.running or not self.buffs then return end
    local skip = trackedSet()
    local buffs, buffsOK = read("HELPFUL", skip)
    local debuffs, debuffsOK = read("HARMFUL", {})
    local readable = buffs ~= nil and debuffs ~= nil and buffsOK and debuffsOK
    local timed = false
    if buffs then timed = paintRow(self.buffs, buffs) or timed end
    if debuffs then timed = paintRow(self.debuffs, debuffs) or timed end
    suppressNative(self, readable and (rawget(_G, "BuffFrame") ~= nil or rawget(_G, "DebuffFrame") ~= nil))
    self.drawn = (buffs and #buffs or 0) + (debuffs and #debuffs or 0)
    self.readable = readable
    app.Ownership:Set("edgeAuras", {
        intent = "owned", active = readable and "owned" or "native",
        evidence = "simulated", reason = (not readable) and "unreadable" or nil,
    })
    -- Private auras are engine-drawn at their own anchors, not here.
    app.Ownership:Set("edgeAuras.private", { intent = "native", active = "native",
        evidence = "simulated", reason = "native-anchor" })
    -- A clock is owed only while some aura has a countdown on screen.
    if timed and not ticker then
        ticker = C_Timer.NewTicker(1, function()
            if not self.running then stopTicker(); return end
            app:Call("edgeAuras/tick", update, self)
        end)
    elseif not timed then
        stopTicker()
    end
end

local function build(self)
    local function row(name, y)
        local frame = CreateFrame("Frame", name, UIParent)
        frame:SetSize(PER_ROW * (SIZE + GAP), SIZE)
        frame:EnableMouse(false)
        frame:Hide()
        return { frame = frame, cells = {} }
    end
    self.buffs = row("LumaUIEdgeBuffs")
    self.debuffs = row("LumaUIEdgeDebuffs")
    app.Layout:Register("edgeBuffs", self.buffs.frame, UIParent:GetWidth() / 2 - 230, -60, app.L.edgeBuffs)
    app.Layout:Register("edgeDebuffs", self.debuffs.frame, UIParent:GetWidth() / 2 - 230, -150, app.L.edgeDebuffs)
end

component = app:RegisterComponent({ id = ID, label = "edgeAuras", defaultEnabled = false,
    Supported = function()
        return type(rawget(_G, "C_UnitAuras")) == "table" and type(C_UnitAuras.GetAuraDataByIndex) == "function"
    end,
    Enable = function(self)
        if not self.buffs then
            if not pcall(build, self) then
                self.buffs, self.debuffs = nil, nil
                app.Ownership:Set("edgeAuras", { intent = "owned", active = "native",
                    evidence = "simulated", reason = "build" })
                return
            end
        end
        self:Listen("UNIT_AURA", function(current, _, unit)
            if unit == "player" then update(current) end
        end)
        self:Listen("PLAYER_ENTERING_WORLD", update)
        self:Listen("UNIT_ENTERED_VEHICLE", function(current, _, unit) if unit == "player" then update(current) end end)
        self:Listen("UNIT_EXITED_VEHICLE", function(current, _, unit) if unit == "player" then update(current) end end)
        update(self)
    end,
    Refresh = function(self) update(self) end,
    Disable = function(self)
        stopTicker()
        suppressNative(self, false)
        for _, row in ipairs({ self.buffs or {}, self.debuffs or {} }) do
            if row.frame then row.frame:Hide() end
        end
        app.Ownership:Clear("edgeAuras")
        app.Ownership:Clear("edgeAuras.private")
    end,
})

function component:Describe()
    if not self.running then return nil end
    return string.format("edgeAuras: drawn=%d readable=%s", self.drawn or 0, self.readable and "yes" or "no")
end
