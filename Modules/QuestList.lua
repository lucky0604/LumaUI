local _, app = ...
local L, Plain = app.L, app.Capabilities.Plain

local WIDTH, MIN_HEIGHT, MAX_HEIGHT = 300, 84, 430
local BODY_WIDTH = 258
local HEADER_HEIGHT, QUEST_HEIGHT, LINE_HEIGHT = 24, 20, 16
local QUEST_INDENT = 24
local MAX_ROWS = 250
local MAX_TEXT_LINES = 12
local TASK_TICK = 30
local NATIVE_JOB = "questList/native"
-- The native takeover removes only the quest modules; scenario/dungeon and any
-- other module stay with the client. It was gated while the panel was a preview.
-- 003 turns it on by product decision: the LumaUI panel replaces the Blizzard
-- quest block, with folding, quest items and world quests still needing their
-- own in-game regression. Set this back to false to hand quests back to the
-- native tracker without disabling the panel.
local NATIVE_PARITY_VALIDATED = true
local ITEM_JOB = "questList/items"
local BANNER_HEIGHT = 20
local component
local scheduleOverlap

local FILTERS = { "tracked", "zone", "all" }
local FILTER_TEXT = { tracked = "questListTracked", zone = "questListZone", all = "questListAll" }
local FILTER_OFFSETS = { tracked = -96, zone = -54, all = -12 }

local ICONS = {
    ready = "Interface\\GossipFrame\\ActiveQuestIcon",
    active = "Interface\\GossipFrame\\AvailableQuestIcon",
}
-- Blizzard's own in-progress marker for quest pins; plain textures would need
-- separate files for every quest classification, so use the shared atlas.
local ACTIVE_ATLAS = "SideInProgressquesticon"

-- Quest panel: grouping, folding and tracking are independent of the native
-- tracker. The takeover below replaces only the quest modules; scenario,
-- dungeon, achievement and other objectives remain under client control.

local function callQuest(name, ...)
    local log = _G.C_QuestLog
    local fn = type(log) == "table" and log[name]
    if type(fn) ~= "function" then return nil end
    local ok, value = pcall(fn, ...)
    if not ok then return nil end
    return value
end

local function inCombat()
    local fn = _G.InCombatLockdown
    return type(fn) == "function" and fn() == true
end

-- Quest items usable from the tracker: resolve the log index first, then the
-- special item link. Every step is optional and fails silently.
local function questItemLink(questID)
    local log = _G.C_QuestLog
    if type(log) ~= "table" or type(log.GetLogIndexForQuestID) ~= "function" then return nil end
    local ok, index = pcall(log.GetLogIndexForQuestID, questID)
    if not ok then return nil end
    index = Plain(index, "number")
    if not index then return nil end
    local special = _G.GetQuestLogSpecialItemInfo
    if type(special) ~= "function" then return nil end
    local called, link = pcall(special, index)
    if not called then return nil end
    return Plain(link, "string")
end

-- Icon of a quest item link. The instant-info call is documented as
-- (itemID, itemType, itemSubType, itemEquipLoc, icon, classID, subclassID), so
-- the icon is the FIFTH return value in both the C_Item and the legacy global
-- namespace. The full GetItemInfo call keeps the older eleven-value shape and
-- serves as a last fallback when the instant call has no icon (uncached item).
local function itemIconID(link)
    local cItem = _G.C_Item
    local instant = type(cItem) == "table" and cItem.GetItemInfoInstant or nil
    if type(instant) == "function" then
        local ok, _, _, _, _, icon = pcall(instant, link)
        if ok then
            icon = Plain(icon, "number")
            if icon then return icon end
        end
    end
    local legacyInstant = _G.GetItemInfoInstant
    if type(legacyInstant) == "function" and legacyInstant ~= instant then
        local ok, _, _, _, _, icon = pcall(legacyInstant, link)
        if ok then
            icon = Plain(icon, "number")
            if icon then return icon end
        end
    end
    local info = type(cItem) == "table" and cItem.GetItemInfo or _G.GetItemInfo
    if type(info) == "function" then
        local ok, _, _, _, _, _, _, _, _, _, texture = pcall(info, link)
        if ok then
            texture = Plain(texture, "number")
            if texture then return texture end
        end
    end
end

local function questState(questID)
    if Plain(callQuest("IsFailed", questID), "boolean") == true then return "failed" end
    if Plain(callQuest("ReadyForTurnIn", questID), "boolean") == true then return "ready" end
    if Plain(callQuest("IsComplete", questID), "boolean") == true then return "ready" end
    return "active"
end

-- Remaining world-quest time in seconds. The dedicated time-left API is the
-- documented source; GetQuestInfoByQuestID returns title, factionID, capped and
-- displayAsObjective only. A client without the seconds call falls back to the
-- documented minutes call, and without either the row simply shows no time.
local function taskTimeLeft(questID)
    local tasks = _G.C_TaskQuest
    if type(tasks) ~= "table" then return nil end
    local secondsFn = tasks.GetQuestTimeLeftSeconds
    if type(secondsFn) == "function" then
        local ok, seconds = pcall(secondsFn, questID)
        seconds = ok and Plain(seconds, "number") or nil
        if seconds and seconds > 0 then return seconds end
    end
    local minutesFn = tasks.GetQuestTimeLeftMinutes
    if type(minutesFn) == "function" then
        local ok, minutes = pcall(minutesFn, questID)
        minutes = ok and Plain(minutes, "number") or nil
        if minutes and minutes > 0 then return minutes * 60 end
    end
    return nil
end

local function paintQuestIcon(icon, state)
    icon:SetVertexColor(1, 1, 1)
    if state == "ready" then
        icon:SetTexture(ICONS.ready)
        return
    end
    -- The gold question mark means "ready to turn in" in the gossip UI; an
    -- in-progress quest uses the map's own in-progress atlas instead.
    if type(icon.SetAtlas) == "function" then
        icon:SetAtlas(ACTIVE_ATLAS, false)
    else
        icon:SetTexture(ICONS.active)
    end
    if state == "failed" then icon:SetVertexColor(1, 0.35, 0.35) end
end

local function superTracked()
    local track = _G.C_SuperTrack
    if type(track) ~= "table" or type(track.GetSuperTrackedQuestID) ~= "function" then return nil end
    local ok, value = pcall(track.GetSuperTrackedQuestID)
    if not ok then return nil end
    return Plain(value, "number")
end

-- Party quest sync: the banner only appears when the client exposes every
-- function it needs; a missing API keeps the whole block silent.
local function sessionSupported()
    local session = _G.C_QuestSession
    return type(session) == "table"
        and type(session.Exists) == "function"
        and type(session.GetSessionEnterState) == "function"
        and type(session.RequestSessionEnter) == "function"
        and type(session.RequestSessionLeave) == "function"
end

local function sessionActive()
    if not sessionSupported() then return false end
    local ok, exists = pcall(_G.C_QuestSession.Exists)
    return ok and Plain(exists, "boolean") == true
end

local function sessionEntered()
    if not sessionSupported() then return false end
    local ok, state = pcall(_G.C_QuestSession.GetSessionEnterState)
    if not ok then return false end
    state = Plain(state, "number")
    if not state then return false end
    local states = type(_G.Enum) == "table" and _G.Enum.QuestSessionEnterState
    if type(states) == "table" then
        local entered = Plain(states.Entered, "number")
        if entered then return state == entered end
    end
    return false
end

local function watchData(entries)
    local watched, order = {}, {}
    local log = _G.C_QuestLog
    if type(log) == "table" and type(log.GetNumQuestWatches) == "function"
        and type(log.GetQuestIDForQuestWatchIndex) == "function" then
        local count = Plain(callQuest("GetNumQuestWatches"), "number") or 0
        for index = 1, count do
            local questID = Plain(callQuest("GetQuestIDForQuestWatchIndex", index), "number")
            if questID and not watched[questID] then
                watched[questID] = true
                order[#order + 1] = questID
            end
        end
    else
        for questID in pairs(entries) do
            if Plain(callQuest("GetQuestWatchType", questID), "number") ~= nil then
                watched[questID] = true
                order[#order + 1] = questID
            end
        end
        table.sort(order, function(a, b) return (entries[a].index or 0) < (entries[b].index or 0) end)
    end
    return watched, order
end

local function zoneData()
    local names, ids = {}, {}
    for _, getter in ipairs({ "GetRealZoneText", "GetZoneText", "GetSubZoneText" }) do
        local fn = _G[getter]
        if type(fn) == "function" then
            local ok, value = pcall(fn)
            if ok then
                local name = Plain(value, "string")
                if name and name ~= "" then names[name] = true end
            end
        end
    end
    local mapID
    local best = _G.C_Map and _G.C_Map.GetBestMapForUnit
    if type(best) == "function" then
        local ok, value = pcall(best, "player")
        if ok then mapID = Plain(value, "number") end
    end
    local quests = mapID and callQuest("GetQuestsOnMap", mapID)
    if type(quests) == "table" then
        for _, entry in ipairs(quests) do
            local questID = type(entry) == "table" and Plain(entry.questID, "number")
            if questID then ids[questID] = true end
        end
    end
    return names, ids
end

local function collect(mode)
    local entries, headerRank, headers = {}, {}, {}
    local count = Plain(callQuest("GetNumQuestLogEntries"), "number") or 0
    local header = nil
    for index = 1, count do
        local info = callQuest("GetInfo", index)
        if type(info) == "table" then
            local title = Plain(info.title, "string")
            local hidden = Plain(info.isHidden, "boolean")
            if Plain(info.isHeader, "boolean") == true then
                header = nil
                if title and title ~= "" and not hidden then
                    header = title
                    if not headerRank[title] then
                        headerRank[title] = #headers + 1
                        headers[#headers + 1] = title
                    end
                end
            elseif not hidden and title and title ~= "" then
                local questID = Plain(info.questID, "number")
                local isTask = Plain(info.isTask, "boolean") == true
                if questID and not entries[questID] then
                    entries[questID] = {
                        id = questID,
                        title = title,
                        level = Plain(info.level, "number") or Plain(info.questLevel, "number"),
                        header = header or L.questListOther,
                        index = index,
                        -- World quests (tasks) are in the log but never join the
                        -- watch list; the game tracks them by focusing.
                        isTask = isTask,
                        -- Remaining world-quest time, queried once per entry
                        -- here so paintRow never calls the API per row.
                        timeLeft = isTask and taskTimeLeft(questID) or nil,
                    }
                end
            end
        end
    end

    local watched, watchOrder = watchData(entries)
    for _, questID in ipairs(watchOrder) do
        if not entries[questID] then
            local title = Plain(callQuest("GetTitleForQuestID", questID), "string")
            if title and title ~= "" then
                entries[questID] = {
                    id = questID,
                    title = title,
                    level = Plain(callQuest("GetQuestDifficultyLevel", questID), "number"),
                    header = L.questListOther,
                    index = 0,
                }
            end
        end
    end
    local watchPos = {}
    for position, questID in ipairs(watchOrder) do watchPos[questID] = position end

    local zoneNames, zoneIDs = zoneData()
    local focus = superTracked()
    local list = {}
    if mode == "tracked" then
        for _, questID in ipairs(watchOrder) do
            if entries[questID] then list[#list + 1] = entries[questID] end
        end
        -- The game's own tracker shows the focused quest on top and every
        -- world task of the current zone without any manual tracking, so the
        -- panel's tracked view does the same.
        if focus and entries[focus] and not watched[focus] then list[#list + 1] = entries[focus] end
        for _, quest in pairs(entries) do
            if quest.isTask and quest.id ~= focus and not watched[quest.id] and zoneIDs[quest.id] then
                list[#list + 1] = quest
            end
        end
    elseif mode == "zone" then
        for id, quest in pairs(entries) do
            if zoneIDs[id] or zoneNames[quest.header] then list[#list + 1] = quest end
        end
    else
        for _, quest in pairs(entries) do list[#list + 1] = quest end
    end

    table.sort(list, function(a, b)
        local aWatched, bWatched = watched[a.id] == true, watched[b.id] == true
        if aWatched ~= bWatched then return aWatched end
        if mode == "tracked" then
            if aWatched then return (watchPos[a.id] or 0) < (watchPos[b.id] or 0) end
            local aFocus, bFocus = a.id == focus, b.id == focus
            if aFocus ~= bFocus then return aFocus end
            return (a.index or 0) < (b.index or 0)
        end
        if a.header == b.header then return a.index < b.index end
        return (headerRank[a.header] or #headers + 1) < (headerRank[b.header] or #headers + 1)
    end)

    local groups, order = {}, {}
    for _, quest in ipairs(list) do
        quest.state = quest.state or questState(quest.id)
        quest.itemLink = questItemLink(quest.id)
        local group = groups[quest.header]
        if not group then
            group = { name = quest.header, quests = {}, rank = headerRank[quest.header] or #headers + 1 }
            groups[quest.header] = group
            order[#order + 1] = group
        end
        group.quests[#group.quests + 1] = quest
    end
    table.sort(order, function(a, b)
        local aHere, bHere = zoneNames[a.name] == true, zoneNames[b.name] == true
        if aHere ~= bHere then return aHere end
        return a.rank < b.rank
    end)

    return { groups = order, quests = #list, watched = watched, here = zoneNames }
end

local function objectives(quest)
    if quest.state == "ready" then return {} end
    local list, lines = callQuest("GetQuestObjectives", quest.id), {}
    if type(list) == "table" then
        for _, objective in ipairs(list) do
            if type(objective) == "table" then
                local text = Plain(objective.text, "string")
                if text and text ~= "" then
                    lines[#lines + 1] = { text = text, done = Plain(objective.finished, "boolean") == true }
                end
            end
        end
    end
    return lines
end

local function readFilter()
    local profile = app.Store:Profile()
    local value = profile and profile.ui and profile.ui.questFilter
    if value == "tracked" or value == "zone" or value == "all" then return value end
    return "all"
end

local function paintFilters(self)
    if not self.filterButtons then return end
    local accent, muted = app.Theme:Accent(), app.Theme.colors.muted
    for _, key in ipairs(FILTERS) do
        local button = self.filterButtons[key]
        if button then
            local active = self.filter == key
            button.label:SetTextColor(active and accent[1] or muted[1], active and accent[2] or muted[2],
                active and accent[3] or muted[3], 1)
            button.bar:SetColorTexture(accent[1], accent[2], accent[3], active and 1 or 0)
        end
    end
end

local function hideTooltip()
    local tooltip = _G.GameTooltip
    if type(tooltip) == "table" and type(tooltip.Hide) == "function" then pcall(tooltip.Hide, tooltip) end
end

local function showTooltip(owner, lines)
    local tooltip = _G.GameTooltip
    if type(tooltip) ~= "table" then return end
    if type(tooltip.SetOwner) == "function" then pcall(tooltip.SetOwner, tooltip, owner, "ANCHOR_RIGHT") end
    if type(tooltip.ClearLines) == "function" then pcall(tooltip.ClearLines, tooltip) end
    if type(tooltip.AddLine) == "function" then
        for _, line in ipairs(lines) do pcall(tooltip.AddLine, tooltip, line) end
    end
    if type(tooltip.Show) == "function" then pcall(tooltip.Show, tooltip) end
end

-- Quest item buttons show the real item tooltip plus a usage hint line.
local function showItemTooltip(button, link)
    local tooltip = _G.GameTooltip
    if type(tooltip) ~= "table" or type(tooltip.SetHyperlink) ~= "function" then return end
    if type(tooltip.SetOwner) == "function" then pcall(tooltip.SetOwner, tooltip, button, "ANCHOR_RIGHT") end
    if not pcall(tooltip.SetHyperlink, tooltip, link) then
        hideTooltip()
        return
    end
    if type(tooltip.AddLine) == "function" then pcall(tooltip.AddLine, tooltip, L.questItemHint) end
    if type(tooltip.Show) == "function" then pcall(tooltip.Show, tooltip) end
end

local refresh, row, paintRow, requestSync, releaseRow, rowFeedback, clearFeedback

-- Title ink carries the state hierarchy: the focused quest reads strongest, a
-- turn-in or a failure gets its semantic tone, a watched quest is normal ink
-- and a quest that is merely listed recedes. Difficulty no longer tints every
-- title; it moves to the two-pixel mark at the row's left edge.
local function titleInk(self, quest, text)
    if self.superNow == quest.id then
        return text[1], text[2], text[3], 1, "OUTLINE"
    end
    if quest.state == "ready" then return 0.95, 0.8, 0.42, 1, "" end
    if quest.state == "failed" then return 0.9, 0.4, 0.38, 1, "" end
    local watched = self.watchedNow and self.watchedNow[quest.id] == true
    return text[1], text[2], text[3], watched and 1 or 0.78, ""
end

-- Wrapped rows take their height from the font string's own measurement.
-- A client that cannot measure (nil, zero or an implausible value) falls back
-- to the single-line height, and a very long string is capped at the maximum
-- line count so one row cannot swallow the panel.
local function textHeight(label, minimum, size)
    local ok, value = pcall(label.GetStringHeight, label)
    value = ok and Plain(value, "number") or nil
    if not value or value <= 0 then return minimum end
    local cap = math.ceil((size or 13) * 1.32 * MAX_TEXT_LINES) + 2
    return math.min(cap, math.max(minimum, math.ceil(value) + 2))
end

-- In combat a row that hosts a secure item button is protected, and so are its
-- ancestors. Geometry, visibility and attributes then belong to the
-- end-of-fight reflow; only text, colours and textures are repainted here, and
-- only into rows whose kind already matches so the anchors stay valid.
local function paintLocked(self, current, entry)
    local frame, label, icon = current.frame, current.label, current.icon
    if not frame:IsShown() then return end
    local previous = frame.entry
    if not previous or previous.kind ~= entry.kind then return end
    -- A secure item button retains its attributes until combat ends. Keep the
    -- row's original quest and text together with that button if the list is
    -- reordered or the item changes while protected geometry is locked.
    if entry.kind == "quest" and (previous.quest.id ~= entry.quest.id
        or current.itemLink ~= entry.quest.itemLink) then return end
    frame.entry = entry
    frame.iconButton.entry = entry
    local muted, text = app.Theme.colors.muted, app.Theme.colors.text
    local accent = app.Theme:Accent()
    if entry.kind == "group" then
        label:SetText(entry.name)
        label:SetFont(app.Type:Face(), 12, "")
        label:SetTextColor(accent[1], accent[2], accent[3], 1)
        frame.arrow:SetText(self.folds[entry.key] and "+" or "-")
        frame.right:SetFormattedText("%d", entry.count)
        frame.right:SetTextColor(muted[1], muted[2], muted[3], 1)
    elseif entry.kind == "quest" then
        local quest = entry.quest
        current.itemLink = quest.itemLink
        local red, green, blue, alpha, flags = titleInk(self, quest, text)
        label:SetText(quest.title)
        label:SetFont(app.Type:Face(), 13, flags)
        label:SetTextColor(red, green, blue, alpha)
        paintQuestIcon(icon, quest.state)
        local timeLeft = quest.isTask and quest.timeLeft
        if timeLeft then
            frame.right:SetText(timeLeft >= 3600
                and string.format(L.taskTimeHours, math.floor(timeLeft / 3600))
                or string.format(L.taskTimeMinutes, math.max(1, math.floor(timeLeft / 60))))
            frame.right:SetTextColor(0.95, 0.8, 0.42, 1)
        else
            frame.right:SetText(quest.isTask and "" or (self.folds[entry.key] and "+" or ""))
            frame.right:SetTextColor(muted[1], muted[2], muted[3], 1)
        end
        -- The track dot is a texture on the row, not a frame, so focusing and
        -- watching from inside a fight still feed back immediately.
        if self.superNow == quest.id then
            frame.dot:SetSize(7, 7)
            frame.dot:SetColorTexture(accent[1], accent[2], accent[3], 1)
            frame.dot:Show()
        elseif self.watchedNow and self.watchedNow[quest.id] then
            frame.dot:SetSize(4, 4)
            frame.dot:SetColorTexture(muted[1], muted[2], muted[3], 1)
            frame.dot:Show()
        else
            frame.dot:Hide()
        end
    elseif entry.kind == "line" then
        local red, green, blue, alpha = muted[1], muted[2], muted[3], 1
        if entry.done then alpha = 0.55 end
        if entry.color == "ready" then red, green, blue, alpha = 0.95, 0.8, 0.42, 1
        elseif entry.color == "failed" then red, green, blue, alpha = 0.9, 0.4, 0.38, 1 end
        label:SetText(entry.text)
        label:SetFont(app.Type:Face(), 11, "")
        label:SetTextColor(red, green, blue, alpha)
    else
        label:SetText(L.questListEmpty)
        label:SetFont(app.Type:Face(), 11, "")
        label:SetTextColor(muted[1], muted[2], muted[3], 1)
    end
end

-- One secure item-use button per quest row, created lazily outside combat so
-- protected sizing and attributes never touch the combat lock. Once any row
-- has one, the whole list is a protected ancestor during combat.
local function ensureItemButton(self, current)
    if current.itemButton then return current.itemButton end
    if inCombat() then return nil end
    local frame = CreateFrame("Button", nil, current.frame, "SecureActionButtonTemplate")
    frame:SetSize(18, 18)
    frame:SetPoint("RIGHT", -14, 0)
    frame:SetFrameLevel(current.frame:GetFrameLevel() + 2)
    local icon = frame:CreateTexture(nil, "ARTWORK")
    icon:SetAllPoints(frame)
    frame.icon = icon
    frame:SetScript("OnEnter", function(button)
        if type(button.itemLink) == "string" then showItemTooltip(button, button.itemLink) end
    end)
    frame:SetScript("OnLeave", function() hideTooltip() end)
    frame:Hide()
    current.itemButton = frame
    self.secureSpawned = true
    return frame
end

local function applyItemRow(self, current)
    local link = current.itemLink
    -- Rows without a link only need attention when a pooled button exists.
    if not link and not current.itemButton then return end
    local button = ensureItemButton(self, current)
    if not button then return end
    button.itemLink = link
    if link then
        button:SetAttribute("type", "item")
        button:SetAttribute("item", link)
        -- Without icon data the button still works; it just draws no texture
        -- until GET_ITEM_INFO_RECEIVED reports the item.
        local icon = itemIconID(link)
        button.icon:SetTexture(icon)
        button.iconID = icon
        button:Show()
    else
        button.itemLink = nil
        button:Hide()
    end
end

local function applyItemRows(self)
    for _, current in ipairs(self.rows or {}) do applyItemRow(self, current) end
end

-- The item cache fills in after a row is painted; re-apply only the texture
-- that became known instead of rebuilding the list.
local function refreshItemIcons(self)
    if not self.running then return end
    for _, current in ipairs(self.rows or {}) do
        local button = current.itemButton
        if button and button:IsShown() and type(button.itemLink) == "string" then
            local icon = itemIconID(button.itemLink)
            if icon and icon ~= button.iconID then
                button.iconID = icon
                button.icon:SetTexture(icon)
            end
        end
    end
end

-- Remaining world-quest time is printed as hours or whole minutes. A slow tick
-- keeps that text honest without a per-frame timer; the list is rebuilt only
-- when the printed bucket changes, and never during combat, where the reflow
-- waits.
local function timeBucket(seconds)
    if not seconds then return nil end
    if seconds >= 3600 then return math.floor(seconds / 3600) end
    return math.max(1, math.floor(seconds / 60))
end

local function refreshTaskTimes(self)
    if not self.running or inCombat() then return end
    for _, current in ipairs(self.rows or {}) do
        local entry = current.frame.entry
        local quest = entry and entry.kind == "quest" and entry.quest
        if current.frame:IsShown() and quest and quest.isTask then
            if timeBucket(taskTimeLeft(quest.id)) ~= timeBucket(quest.timeLeft) then
                refresh(self)
                return
            end
        end
    end
end

-- Party quest sync banner pinned above the quest rows; the frame is reused and
-- only exposed through self.sessionBanner while it is visible.
local function ensureBanner(self)
    if self.banner then return self.banner end
    local frame = CreateFrame("Frame", nil, self.body)
    frame:SetHeight(BANNER_HEIGHT)
    local label = app.Theme:Text(frame, 11, true)
    label:SetPoint("LEFT", 0, 0)
    local button = CreateFrame("Button", nil, frame)
    button:SetSize(44, 14)
    button:SetPoint("RIGHT", 0, 0)
    local text = app.Theme:Text(button, 11, true)
    text:SetPoint("CENTER")
    button.text = text
    button:SetScript("OnClick", function()
        local session = _G.C_QuestSession
        if type(session) ~= "table" or not self.running then return end
        local fn = sessionEntered() and session.RequestSessionLeave or session.RequestSessionEnter
        if type(fn) == "function" then pcall(fn) end
        refresh(self)
    end)
    self.banner = { frame = frame, label = label, button = button }
    return self.banner
end

-- Row feedback. Identity is the quest id (and objective index): a row that was
-- not there on the previous paint fades in, and a quest or objective that goes
-- from unfinished to finished is emphasised once. The first paint, locked
-- (combat) paints and unstable rows are applied at once. The visuals are only
-- alpha and the shared edge pulse on the row's own frame; they carry no input.
local ENTER_SECONDS = 0.14
function releaseRow(current)
    if not current then return end
    app.Transitions:Cancel(current.frame, "enter")
    app.Transitions:Cancel(current.frame, "shift")
    current.visualY = nil
    current.frame:SetAlpha(1)
    if app.EdgePulse then app.EdgePulse:Release(current.frame) end
end

-- Leaving rows: a short-lived, input-free copy of the old text fades out where
-- the row was. It has no secure attributes, no mouse and no item button, and
-- at most GHOST_MAX exist at once.
local GHOST_MAX = 4
local function spawnGhost(self, info)
    self.ghosts = self.ghosts or {}
    local ghost
    for _, candidate in ipairs(self.ghosts) do
        if not candidate.busy then ghost = candidate; break end
    end
    if not ghost then
        if #self.ghosts >= GHOST_MAX then return end
        local frame = CreateFrame("Frame", nil, self.body)
        frame:EnableMouse(false)
        frame:SetSize(BODY_WIDTH, LINE_HEIGHT)
        local text = app.Theme:Text(frame, 11, true)
        text:SetPoint("LEFT", QUEST_INDENT, 0)
        ghost = { frame = frame, text = text }
        self.ghosts[#self.ghosts + 1] = ghost
    end
    ghost.busy = true
    ghost.text:SetText(info.text or "")
    ghost.frame:ClearAllPoints()
    ghost.frame:SetPoint("TOPLEFT", self.body, "TOPLEFT", 0, -(info.y or 0))
    ghost.frame:SetAlpha(1)
    ghost.frame:Show()
    local function done()
        ghost.busy = false
        ghost.frame:Hide()
        ghost.frame:SetAlpha(1)
    end
    if not app.Transitions:Fade(ghost.frame, ghost.frame, 0, ENTER_SECONDS, done, "ghost") then done() end
end

function rowFeedback(self, rows)
    local previous, ready = self.seenRows, self.seenReady
    local previousInfo = self.seenInfo or {}
    local seen, info = {}, {}
    for index, entry in ipairs(rows) do
        local current = self.rows[index]
        local key = entry.key
        local state
        if entry.kind == "quest" then state = entry.quest.state == "ready" or entry.quest.state == "complete" or false
        elseif entry.kind == "line" then state = entry.done == true end
        if current then
            -- A pooled row that now shows another identity drops the old run.
            if current.identity ~= key then releaseRow(current) end
            current.identity = key
            if key then
                -- Reflow: a row whose slot moved glides from where it was
                -- drawn. Rows carrying the secure item button, combat and
                -- motion off snap, so the hit area never lags the drawing.
                local oldInfo = previousInfo[key]
                local target = current.paintY
                local from = current.visualY or (oldInfo and oldInfo.y)
                if ready and from and target and from ~= target and not current.itemLink
                    and not inCombat() and app.Transitions.MotionEnabled() then
                    local frame = current.frame
                    frame:ClearAllPoints()
                    frame:SetPoint("TOPLEFT", self.body, "TOPLEFT", 0, -from)
                    current.visualY = from
                    app.Transitions:Animate(frame, "shift", {
                        from = from, to = target, duration = 0.14,
                        apply = function(value, progress)
                            if inCombat() then value, progress = target, 1 end
                            frame:ClearAllPoints()
                            frame:SetPoint("TOPLEFT", self.body, "TOPLEFT", 0, -value)
                            current.visualY = progress < 1 and value or nil
                        end,
                    })
                end
                seen[key] = state == true
                info[key] = { text = current.label:GetText(), y = current.paintY }
                if ready and previous and previous[key] == nil then
                    current.frame:SetAlpha(0)
                    app.Transitions:Fade(current.frame, current.frame, 1, ENTER_SECONDS, nil, "enter")
                elseif ready and previous and previous[key] == false and state == true and app.EdgePulse then
                    app.EdgePulse:Show(current.frame)
                end
            end
        end
    end
    -- Rows that were visible and are gone now leave a ghost, except the whole
    -- list being rebuilt (first paint) which is applied at once.
    if ready and previous then
        local spawned = 0
        for key, old in pairs(previousInfo) do
            if seen[key] == nil and spawned < GHOST_MAX then
                spawned = spawned + 1
                spawnGhost(self, old)
            end
        end
    end
    self.seenRows, self.seenInfo, self.seenReady = seen, info, true
end

function clearFeedback(self)
    for _, ghost in ipairs(self.ghosts or {}) do
        app.Transitions:Cancel(ghost.frame, "ghost")
        ghost.busy = false
        ghost.frame:Hide()
        ghost.frame:SetAlpha(1)
    end
    self.seenInfo = nil
    for _, current in ipairs(self.rows or {}) do
        releaseRow(current)
        current.identity = nil
    end
    self.seenRows, self.seenReady = nil, nil
end

refresh = function(self)
    if not self.frame then return end
    local accent = app.Theme:Accent()
    self.rule:SetColorTexture(accent[1], accent[2], accent[3], 1)
    self.filter = self.filter or readFilter()
    local data = collect(self.filter)
    self.watchedNow = data.watched
    self.superNow = superTracked()
    self.title:SetFormattedText("%s  %d", L.questListTitle, data.quests)
    paintFilters(self)

    -- Once any row has received a secure item button, the panel is a protected
    -- ancestor in combat: paint text only and defer every geometry, visibility
    -- and attribute change to PLAYER_REGEN_ENABLED.
    local locked = inCombat() and self.secureSpawned == true
    self.lockedPaint = locked
    if locked then self.pendingReflow = true else self.pendingReflow = nil end

    local rows, used = {}, 0
    for _, group in ipairs(data.groups) do
        local key = "g:" .. group.name
        if used < MAX_ROWS then
            rows[#rows + 1] = { kind = "group", key = key, name = group.name, count = #group.quests }
            used = used + 1
        end
        if not self.folds[key] then
            for _, quest in ipairs(group.quests) do
                if used < MAX_ROWS then
                    rows[#rows + 1] = { kind = "quest", key = "q:" .. quest.id, quest = quest }
                    used = used + 1
                end
                if not self.folds["q:" .. quest.id] then
                    if quest.state == "ready" then
                        if used < MAX_ROWS then
                            rows[#rows + 1] = { kind = "line", text = L.questListReady, color = "ready", key = "s:" .. quest.id .. ":ready" }
                            used = used + 1
                        end
                    elseif quest.state == "failed" then
                        if used < MAX_ROWS then
                            rows[#rows + 1] = { kind = "line", text = L.questListFailed, color = "failed", key = "s:" .. quest.id .. ":failed" }
                            used = used + 1
                        end
                    end
                    if quest.state ~= "ready" then
                        for lineIndex, line in ipairs(objectives(quest)) do
                            if used < MAX_ROWS then
                                rows[#rows + 1] = { kind = "line", text = line.text, done = line.done,
                                    key = "o:" .. quest.id .. ":" .. lineIndex }
                                used = used + 1
                            end
                        end
                    end
                end
            end
        end
    end
    if #rows == 0 then rows[1] = { kind = "empty" } end

    local y = 0
    if locked then
        -- The banner keeps its geometry and only updates its ink. A banner that
        -- is not there yet waits for the reflow rather than being built mid-fight.
        if self.sessionBanner and sessionActive() then
            self.sessionBanner.label:SetText(L.questSyncLabel)
            self.sessionBanner.button.text:SetText(sessionEntered() and L.questSyncLeave or L.questSyncJoin)
            self.sessionBanner.button.text:SetTextColor(accent[1], accent[2], accent[3], 1)
            y = y + BANNER_HEIGHT
        end
    else
        -- The party sync banner is pinned above the quest rows while a session
        -- exists; hiding it moves every row back up.
        if sessionActive() then
            local banner = ensureBanner(self)
            banner.frame:ClearAllPoints()
            banner.frame:SetPoint("TOPLEFT", self.body, "TOPLEFT", 0, -y)
            banner.frame:SetWidth(BODY_WIDTH)
            banner.label:SetText(L.questSyncLabel)
            banner.button.text:SetText(sessionEntered() and L.questSyncLeave or L.questSyncJoin)
            banner.button.text:SetTextColor(accent[1], accent[2], accent[3], 1)
            banner.frame:Show()
            self.sessionBanner = banner
            y = y + BANNER_HEIGHT
        elseif self.sessionBanner then
            self.sessionBanner.frame:Hide()
            self.sessionBanner = nil
        end
    end

    if locked then
        for index, entry in ipairs(rows) do
            local current = (self.rows or {})[index]
            if not current then break end
            paintLocked(self, current, entry)
        end
        -- Surplus rows keep their identity until their secure item buttons can
        -- be hidden in the deferred layout pass.
    else
        for index, entry in ipairs(rows) do
            local current = row(self, index)
            local height = paintRow(self, current, entry, y)
            y = y + height
        end
        for index = #rows + 1, #(self.rows or {}) do
            local current = self.rows[index]
            current.itemLink = nil
            releaseRow(current)
            current.frame:Hide()
        end
        rowFeedback(self, rows)
    end

    -- Secure attributes and visibility change outside combat; during combat
    -- the same-key queue keeps only the latest intent for after the fight.
    if inCombat() then
        app.Queue:Run(ITEM_JOB, function()
            if self.running then applyItemRows(self) end
        end)
    else
        applyItemRows(self)
    end

    if not locked then
        local height = math.min(MAX_HEIGHT, math.max(MIN_HEIGHT, y + 48))
        local body = math.max(y, height - 48)
        self.frame:SetHeight(height)
        self.body:SetSize(BODY_WIDTH, body)
        if not self.overlapHidden then self.frame:Show() end
        -- Shrinking content can leave the scroll view past its new range.
        local overflow = math.max(0, body - (height - 50))
        local offset = self.scroll.GetVerticalScroll and self.scroll:GetVerticalScroll() or 0
        if offset > overflow then self.scroll:SetVerticalScroll(overflow) end
    end
    -- Track whether the panel contains quest rows for diagnostics and takeover.
    self.hasContent = data.quests > 0
    requestSync(self)
    scheduleOverlap(self)
end

local function setFilter(self, key)
    if self.filter == key then return end
    self.filter = key
    app.Store:Set("ui", "questFilter", key)
    paintFilters(self)
    refresh(self)
end

local function focusQuest(self, questID, isTask)
    local track = _G.C_SuperTrack
    if type(track) ~= "table" or type(track.SetSuperTrackedQuestID) ~= "function" then return end
    if superTracked() == questID then
        pcall(track.SetSuperTrackedQuestID, 0)
        return
    end
    -- Regular quests draw their super-track arrow only when also watched, so
    -- the watch happens first, like clicking the quest's pin on the world map.
    -- Tasks cannot join the watch list at all; focusing is the whole action.
    if not isTask and not (self.watchedNow and self.watchedNow[questID]) then
        callQuest("AddQuestWatch", questID)
    end
    pcall(track.SetSuperTrackedQuestID, questID)
end

local function toggleWatch(self, quest)
    if quest.isTask then return focusQuest(self, quest.id, true) end
    local questID = quest.id
    if self.watchedNow and self.watchedNow[questID] then
        callQuest("RemoveQuestWatch", questID)
    else
        callQuest("AddQuestWatch", questID)
    end
    refresh(self)
end

-- Fold state is session memory mirrored into the current profile, so a reload
-- or profile switch restores it; Store drops invalid keys on normalize.
local function persistFolds(self)
    if not self.running then return end
    local groups, quests = {}, {}
    for key, collapsed in pairs(self.folds) do
        if collapsed == true and type(key) == "string" and #key > 2 then
            local name = key:sub(3)
            if key:sub(1, 2) == "g:" then
                groups[name] = true
            elseif key:sub(1, 2) == "q:" then
                quests[name] = true
            end
        end
    end
    app.Store:Set("ui", "questFolds", { groups = groups, quests = quests })
end

local function toggleFold(self, key)
    if self.folds[key] then
        self.folds[key] = nil
    else
        self.folds[key] = true
    end
    persistFolds(self)
    refresh(self)
end

-- Rebuild the session fold set from the current profile; returns whether the
-- visible fold state changed so PROFILE_CHANGED can skip redundant repaints.
local function seedFolds(self)
    local folds = {}
    local profile = app.Store:Profile()
    local saved = profile and profile.ui and profile.ui.questFolds
    if type(saved) == "table" then
        for _, kind in ipairs({ "groups", "quests" }) do
            local source = saved[kind]
            if type(source) == "table" then
                local prefix = kind == "groups" and "g:" or "q:"
                for key in pairs(source) do
                    if type(key) == "string" and #key > 0 and #key <= 96 and not key:find("[%c]") then
                        folds[prefix .. key] = true
                    end
                end
            end
        end
    end
    local before, changed, count = self.folds or {}, false, 0
    for key in pairs(folds) do
        if before[key] ~= true then changed = true end
        count = count + 1
    end
    local previous = 0
    for _ in pairs(before) do previous = previous + 1 end
    if count ~= previous then changed = true end
    self.folds = folds
    return changed
end

-- Right-click menu for quest rows; every MenuUtil call is defensive so a
-- missing or changed menu API stays silent.
local function menuEntry(root, method, ...)
    local fn = type(root) == "table" and root[method]
    if type(fn) ~= "function" then return false end
    return pcall(fn, root, ...)
end

local function openMenu(self, frame, entry)
    local menu = _G.MenuUtil
    if type(menu) ~= "table" or type(menu.CreateContextMenu) ~= "function" then return end
    local quest = entry.quest
    local function generator(owner, rootDescription)
        menuEntry(rootDescription, "CreateTitle", quest.title)
        local watched = self.watchedNow ~= nil and self.watchedNow[quest.id] == true
        if not quest.isTask then
            menuEntry(rootDescription, "CreateButton", watched and L.questMenuUntrack or L.questMenuTrack, function()
                if self.running then app:Call("questList/menuWatch", toggleWatch, self, quest) end
            end)
        end
        local focused = superTracked() == quest.id
        menuEntry(rootDescription, "CreateButton", focused and L.questMenuUnfocus or L.questMenuFocus, function()
            if self.running then
                app:Call("questList/menuFocus", function()
                    focusQuest(self, quest.id, quest.isTask)
                    refresh(self)
                end)
            end
        end)
        if type(_G.QuestMapFrame_OpenToQuest) == "function" then
            menuEntry(rootDescription, "CreateButton", L.questMenuLog, function()
                pcall(_G.QuestMapFrame_OpenToQuest, quest.id)
            end)
        end
        menuEntry(rootDescription, "CreateDivider")
        local log = _G.C_QuestLog
        if type(log) == "table" and type(log.SetSelectedQuest) == "function"
            and type(_G.QuestMapFrame_AbandonQuest) == "function" then
            menuEntry(rootDescription, "CreateButton", L.questMenuAbandon, function()
                -- Select the quest, then let the native confirm dialog run; the
                -- lossy abandon flow itself stays with the game UI.
                pcall(log.SetSelectedQuest, quest.id)
                pcall(_G.QuestMapFrame_AbandonQuest)
            end)
        end
    end
    pcall(menu.CreateContextMenu, frame, generator)
end

local function onClick(self, frame, mouseButton)
    local entry = frame.entry
    if not entry then return end
    if mouseButton == "RightButton" then
        -- Quest rows open the native context menu; groups stay click-only.
        if entry.kind == "quest" then openMenu(self, frame, entry) end
        return
    end
    if entry.kind == "group" then
        toggleFold(self, entry.key)
    elseif entry.kind == "quest" then
        local shift = _G.IsShiftKeyDown
        if type(shift) == "function" and shift() then
            toggleWatch(self, entry.quest)
        else
            toggleFold(self, entry.key)
        end
    end
end

local function onEnter(self, frame)
    local entry = frame.entry
    if not entry then return end
    if entry.kind == "group" then
        frame.hover:Show()
        showTooltip(frame, { entry.name, L.questListGroupHint })
    elseif entry.kind == "quest" then
        frame.hover:Show()
        showTooltip(frame, { entry.quest.title, entry.quest.isTask and L.questListTaskHint or L.questListRowHint })
    end
end

local function onLeave(frame)
    if frame.hover then frame.hover:Hide() end
    hideTooltip()
end

row = function(self, index)
    self.rows = self.rows or {}
    local current = self.rows[index]
    if current then return current end
    local frame = CreateFrame("Button", nil, self.body)
    frame:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    local hover = frame:CreateTexture(nil, "BACKGROUND")
    hover:SetAllPoints(frame)
    hover:Hide()
    frame.hover = hover
    local arrow = app.Type:Text(frame, "label")
    arrow:SetPoint("LEFT", 2, 0)
    arrow:SetWidth(14)
    arrow:Hide()
    local iconButton = CreateFrame("Button", nil, frame)
    iconButton:SetSize(18, 18)
    iconButton:SetPoint("LEFT", 0, 0)
    iconButton:SetFrameLevel(frame:GetFrameLevel() + 2)
    iconButton:RegisterForClicks("LeftButtonUp")
    local icon = iconButton:CreateTexture(nil, "ARTWORK")
    icon:SetAllPoints(iconButton)
    iconButton:Hide()
    local label = app.Type:Text(frame, "body")
    local right = app.Type:Text(frame, "label")
    right:SetJustifyH("RIGHT")
    right:SetWordWrap(false)
    right:SetPoint("RIGHT", -2, 0)
    local dot = frame:CreateTexture(nil, "ARTWORK")
    dot:SetPoint("RIGHT", -3, 0)
    dot:Hide()
    -- Difficulty mark: a local signal at the row's left edge, never a tint on
    -- the whole title. A fixed height keeps it reading as a marker on wrapped
    -- rows instead of a column.
    local mark = frame:CreateTexture(nil, "ARTWORK")
    mark:SetSize(2, 12)
    mark:SetPoint("LEFT", 19, 0)
    mark:Hide()
    frame.arrow, frame.iconButton, frame.icon, frame.label, frame.right, frame.dot, frame.mark =
        arrow, iconButton, icon, label, right, dot, mark
    frame:SetScript("OnClick", function(clicked, button) onClick(self, clicked, button) end)
    frame:SetScript("OnEnter", function(clicked) onEnter(self, clicked) end)
    frame:SetScript("OnLeave", function(clicked) onLeave(clicked) end)
    iconButton:SetScript("OnClick", function()
        local entry = iconButton.entry
        if entry and entry.kind == "quest" then
            focusQuest(self, entry.quest.id, entry.quest.isTask)
            refresh(self)
        end
    end)
    iconButton:SetScript("OnEnter", function(clicked)
        local entry = iconButton.entry
        if entry and entry.kind == "quest" then
            showTooltip(clicked, { entry.quest.title, entry.quest.isTask and L.questListTaskHint or L.questListIconHint })
        end
    end)
    iconButton:SetScript("OnLeave", function() hideTooltip() end)
    self.rows[index] = { frame = frame, label = label, iconButton = iconButton, icon = icon,
        arrow = arrow, right = right, dot = dot, mark = mark, hover = hover }
    return self.rows[index]
end

paintRow = function(self, current, entry, y)
    local frame, label, icon = current.frame, current.label, current.icon
    local accent, muted, text = app.Theme:Accent(), app.Theme.colors.muted, app.Theme.colors.text
    local height, size = LINE_HEIGHT, 11
    local red, green, blue, alpha = muted[1], muted[2], muted[3], 1
    local flags = ""
    local markColor

    frame.entry = entry
    current.paintY = y
    frame.iconButton.entry = entry
    current.itemLink = nil
    frame:ClearAllPoints()
    frame:SetPoint("TOPLEFT", self.body, "TOPLEFT", 0, -y)
    frame:SetWidth(BODY_WIDTH)
    frame.hover:SetColorTexture(accent[1], accent[2], accent[3], 0.1)
    frame.iconButton:Hide()
    frame.arrow:Hide()
    frame.mark:Hide()
    frame.right:SetText("")
    frame.right:ClearAllPoints()
    frame.right:SetPoint("RIGHT", -2, 0)
    frame.right:SetWidth(28)
    frame.dot:Hide()
    label:ClearAllPoints()
    label:SetWidth(BODY_WIDTH)
    label:SetWordWrap(true)

    if entry.kind == "group" then
        height, size = HEADER_HEIGHT, 12
        red, green, blue = accent[1], accent[2], accent[3]
        label:SetText(entry.name)
        label:SetPoint("LEFT", 18, 0)
        label:SetWidth(BODY_WIDTH - 18 - 28)
        frame.arrow:SetText(self.folds[entry.key] and "+" or "-")
        frame.arrow:Show()
        frame.right:SetFormattedText("%d", entry.count)
        frame.right:SetTextColor(muted[1], muted[2], muted[3], 1)
    elseif entry.kind == "quest" then
        local quest = entry.quest
        height, size = QUEST_HEIGHT, 13
        red, green, blue, alpha, flags = titleInk(self, quest, text)
        local qr, qg, qb = app.Theme:QuestColor(quest.level)
        if qr then markColor = { qr, qg, qb } end
        label:SetText(quest.title)
        label:SetPoint("LEFT", QUEST_INDENT, 0)
        label:SetWidth(BODY_WIDTH - QUEST_INDENT - (quest.itemLink and 110 or 82))
        paintQuestIcon(icon, quest.state)
        frame.iconButton:Show()
        -- The pooled item-use button is applied after all rows are painted.
        current.itemLink = quest.itemLink
        frame.right:ClearAllPoints()
        frame.right:SetPoint("RIGHT", quest.itemLink and -38 or -14, 0)
        frame.right:SetWidth(56)
        -- World quest rows give the right slot to the remaining time in the
        -- turn-in gold; the fold toggle keeps working, it just loses its "+"
        -- marker. Regular rows keep the marker and the muted color.
        local timeLeft = quest.isTask and quest.timeLeft
        if timeLeft then
            frame.right:SetText(timeLeft >= 3600
                and string.format(L.taskTimeHours, math.floor(timeLeft / 3600))
                or string.format(L.taskTimeMinutes, math.max(1, math.floor(timeLeft / 60))))
            frame.right:SetTextColor(0.95, 0.8, 0.42, 1)
        else
            if quest.isTask then
                frame.right:SetText("")
            else
                frame.right:SetText(self.folds[entry.key] and "+" or "")
            end
            frame.right:SetTextColor(muted[1], muted[2], muted[3], 1)
        end
        if self.superNow == quest.id then
            frame.dot:SetSize(7, 7)
            frame.dot:SetColorTexture(accent[1], accent[2], accent[3], 1)
            frame.dot:Show()
        elseif self.watchedNow and self.watchedNow[quest.id] then
            frame.dot:SetSize(4, 4)
            frame.dot:SetColorTexture(muted[1], muted[2], muted[3], 1)
            frame.dot:Show()
        end
    elseif entry.kind == "line" then
        label:SetText(entry.text)
        label:SetPoint("LEFT", 26, 0)
        label:SetWidth(BODY_WIDTH - 26 - 4)
        if entry.done then alpha = 0.55 end
        if entry.color == "ready" then
            red, green, blue, alpha = 0.95, 0.8, 0.42, 1
        elseif entry.color == "failed" then
            red, green, blue, alpha = 0.9, 0.4, 0.38, 1
        end
    else
        height = 20
        label:SetText(L.questListEmpty)
        label:SetPoint("LEFT", 0, 0)
        label:SetWidth(BODY_WIDTH)
    end

    label:SetFont(app.Type:Face(), size, flags)
    label:SetTextColor(red, green, blue, alpha)
    if markColor then
        frame.mark:SetColorTexture(markColor[1], markColor[2], markColor[3], 1)
        frame.mark:Show()
    end
    -- The measured height (not the fixed row constant) drives the row, the
    -- content height and therefore the scroll range.
    height = textHeight(label, height, size)
    frame:SetHeight(height)
    frame:Show()
    return height
end

local function build(self)
    local frame = CreateFrame("Frame", "LumaUIQuestList", UIParent)
    frame:Hide()
    frame:SetSize(WIDTH, MIN_HEIGHT)
    frame:SetFrameStrata("LOW")
    frame:EnableMouse(false)
    self.frame = frame
    self.title = app.Type:Text(frame, "body")
    self.title:SetPoint("TOPLEFT", 12, -12)
    self.title:SetWordWrap(false)
    self.rule = app.Theme:Rule(frame)
    self.rule:SetPoint("TOPLEFT", 12, -32)
    self.rule:SetPoint("TOPRIGHT", -12, -32)
    self.rule:SetHeight(1)
    self.filterButtons = {}
    for _, key in ipairs(FILTERS) do
        local filterKey = key
        local button = CreateFrame("Button", nil, frame)
        button:SetSize(38, 16)
        button:SetPoint("TOPRIGHT", FILTER_OFFSETS[key], -11)
        local label = app.Type:Text(button, "micro")
        label:SetPoint("CENTER")
        label:SetText(L[FILTER_TEXT[key]])
        label:SetWordWrap(false)
        button.label = label
        local bar = button:CreateTexture(nil, "ARTWORK")
        bar:SetPoint("BOTTOMLEFT", 0, 0)
        bar:SetPoint("BOTTOMRIGHT", 0, 0)
        bar:SetHeight(1)
        button.bar = bar
        button:SetScript("OnClick", function() setFilter(self, filterKey) end)
        self.filterButtons[key] = button
    end
    local scroll = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 10, -40)
    scroll:SetPoint("BOTTOMRIGHT", -10, 10)
    self.scroll = scroll
    self.body = CreateFrame("Frame", nil, scroll)
    self.body:SetSize(BODY_WIDTH, MIN_HEIGHT)
    scroll:SetScrollChild(self.body)
    self.rows = {}
    self.folds = self.folds or {}
    -- Default placement sits left of the center so the panel does not overlap
    -- the party or minimap areas; the layout page can move it.
    app.Layout:Register("questList", frame, -640, 100, L.questList)
end

-- 015 phase 12 (simulated, default off): with `ui.questBelowMap` the list hangs
-- under the minimap. A saved position (manual or from unlock mode) always wins,
-- and a missing minimap keeps the normal placement.
local function placeBelowMap(self)
    local profile = app.Store:Profile()
    if not self.frame then return end
    -- A saved position (manual or from unlock mode) always wins.
    if profile.positions.questList then return end
    if profile.ui.questBelowMap == true then
        local map = rawget(_G, "Minimap")
        if not map then return end
        self.frame:ClearAllPoints()
        self.frame:SetPoint("TOPRIGHT", map, "BOTTOMRIGHT", 0, -16)
        return
    end
    -- The switch was turned off (or the map is missing): go back to the entry's
    -- own default instead of leaving the panel where the old rule put it.
    if self.placing then return end
    self.placing = true
    app.Layout:Apply("questList")
    self.placing = nil
end

local function nativeFrame()
    local frame = _G.ObjectiveTrackerFrame
    -- Frame globals are userdata on the real client, so a type() == "table"
    -- check would silently skip the takeover in game; only test the methods.
    if frame and type(frame.Hide) == "function" and type(frame.Show) == "function" then return frame end
end

-- Compare the two independently scaled frames in screen-space. Geometry can
-- be unavailable while the client lays out frames; that is an unknown result,
-- never evidence that they do or do not overlap.
local function screenRect(frame)
    if not frame or type(frame.GetRect) ~= "function" or type(frame.GetEffectiveScale) ~= "function" then return nil end
    if type(frame.IsForbidden) == "function" then
        local ok, forbidden = pcall(frame.IsForbidden, frame)
        if not ok or Plain(forbidden, "boolean") ~= false then return nil end
    end
    local ok, left, bottom, width, height, scale = pcall(function()
        local x, y, w, h = frame:GetRect()
        return x, y, w, h, frame:GetEffectiveScale()
    end)
    if not ok then return nil end
    left, bottom = Plain(left, "number"), Plain(bottom, "number")
    width, height, scale = Plain(width, "number"), Plain(height, "number"), Plain(scale, "number")
    if not left or not bottom or not width or not height or not scale
        or width <= 0 or height <= 0 or scale <= 0 then return nil end
    return { left = left * scale, right = (left + width) * scale,
        bottom = bottom * scale, top = (bottom + height) * scale }
end

local function nativeVisible(frame)
    if not frame then return false end
    local method = frame.IsVisible or frame.IsShown
    if type(method) ~= "function" then return nil end
    local ok, visible = pcall(method, frame)
    if not ok then return nil end
    return Plain(visible, "boolean")
end

local nativeObserved = setmetatable({}, { __mode = "k" })
local function observeNative(frame)
    if not frame or nativeObserved[frame] or type(frame.HookScript) ~= "function" then return end
    if type(frame.IsForbidden) == "function" then
        local ok, forbidden = pcall(frame.IsForbidden, frame)
        if not ok or Plain(forbidden, "boolean") ~= false then return end
    end
    nativeObserved[frame] = true
    for _, event in ipairs({ "OnShow", "OnHide", "OnSizeChanged" }) do
        pcall(frame.HookScript, frame, event, function()
            if component and component.running and nativeFrame() == frame then scheduleOverlap(component) end
        end)
    end
end

local function checkOverlap(self)
    if not self.running or not self.frame or inCombat() then return end
    local native = nativeFrame()
    local shown = nativeVisible(native)
    if shown == nil then return end
    local overlaps = false
    if shown then
        local own, other = screenRect(self.frame), screenRect(native)
        if not own or not other then return end
        overlaps = own.left < other.right and own.right > other.left
            and own.bottom < other.top and own.top > other.bottom
    end
    local entry = app.Layout.entries.questList
    if overlaps then
        if not self.overlapHidden then
            self.overlapHidden = true
            if entry then entry.allowHiddenMove = true end
            self.frame:Hide()
            requestSync(self)
            app:Print(L.questOverlapHidden)
        end
    elseif self.overlapHidden then
        self.overlapHidden = nil
        if entry then entry.allowHiddenMove = nil end
        self.frame:Show()
        requestSync(self)
    end
end

scheduleOverlap = function(self)
    if not self.running then return end
    if inCombat() then
        -- PLAYER_REGEN_ENABLED already owns the deferred refresh; avoid adding
        -- a queue job for every ordinary quest update during combat.
        self.overlapPending = true
        return
    end
    self.overlapPending = nil
    observeNative(nativeFrame())
    if self.overlapTimer then return end
    local timerApi = _G.C_Timer and _G.C_Timer.NewTimer
    if type(timerApi) ~= "function" then app:Call("questList/overlap", checkOverlap, self); return end
    local generation = self.overlapGeneration or 0
    local ok, timer = pcall(timerApi, 0.05, function()
        if not self.running or self.overlapGeneration ~= generation then return end
        self.overlapTimer = nil
        app:Call("questList/overlap", checkOverlap, self)
    end)
    if ok and timer then self.overlapTimer = timer else app:Call("questList/overlap", checkOverlap, self) end
end


-- The takeover targets individual quest modules, never the whole tracker: a
-- client without module-level control keeps its own objectives.
local NATIVE_MODULES = { "CampaignQuestObjectiveTracker", "QuestObjectiveTracker", "WorldQuestObjectiveTracker" }

local function nativeContainer()
    local frame = nativeFrame()
    if frame and type(frame.RemoveModule) == "function" and type(frame.AddModule) == "function"
        and type(frame.HasModule) == "function" then
        return frame
    end
end

local function nativeModule(name)
    local frame = _G[name]
    if frame and type(frame.Hide) == "function" and type(frame.Show) == "function" then return frame end
end

local nativeHooked = {}
local showNative

-- A module the client shows again (module registration, an Edit Mode layout,
-- a quest update) is taken back down while the takeover is active. The hook is
-- installed once per module per session, and its job defers in combat.
local function hookModule(frame)
    if nativeHooked[frame] or type(frame.HookScript) ~= "function" then return end
    nativeHooked[frame] = true
    frame:HookScript("OnShow", function(shown)
        if not component or not component.running or not component.nativeHidden then return end
        -- A module the client re-registers mid-fight would be laid out by the
        -- client itself, which is legal for it but not for us: take it back
        -- down after the fight, when the container may be touched again.
        app.Queue:Run(NATIVE_JOB, function()
            if not component or not component.running or not component.nativeHidden or inCombat() then return end
            local state = component.nativeRemoved and component.nativeRemoved[shown]
            local container = nativeContainer()
            if not container or not state then return end
            local checked, present = pcall(container.HasModule, container, shown)
            if not checked then return end
            if present then
                local removed = pcall(container.RemoveModule, container, shown)
                local verified, stillPresent = pcall(container.HasModule, container, shown)
                if not removed or not verified or stillPresent then return end
            end
            if shown:IsShown() then pcall(shown.Hide, shown) end
        end)
    end)
end

-- The takeover only runs while the panel actually replaces something. With no
-- quest row on screen (nothing tracked, an empty filter, a failed refresh) the
-- quest modules come back and the client draws its own objectives again.
local function hideNative(self)
    local container = nativeContainer()
    local modules = {}
    if container then
        for _, name in ipairs(NATIVE_MODULES) do
            local frame = nativeModule(name)
            if frame then modules[#modules + 1] = frame end
        end
    end
    if container and #modules > 0 then
        self.nativeRemoved = self.nativeRemoved or {}
        local count = 0
        for _, frame in ipairs(modules) do
            local checked, present = pcall(container.HasModule, container, frame)
            if not checked then showNative(self); return end
            if present then
                local state = { shown = frame:IsShown() and true or false, removed = false }
                self.nativeRemoved[frame] = state
                local removed = pcall(container.RemoveModule, container, frame)
                local verified, stillPresent = pcall(container.HasModule, container, frame)
                -- AddModule is idempotent, so an inconclusive post-check must
                -- still be included in rollback.
                state.removed = not verified or not stillPresent
                if not removed or not state.removed then showNative(self); return end
                if frame:IsShown() and not pcall(frame.Hide, frame) then showNative(self); return end
                count = count + 1
            end
        end
        self.nativeHidden = count > 0
        if self.nativeHidden then
            for frame in pairs(self.nativeRemoved) do hookModule(frame) end
        end
        return
    end
    -- The whole tracker also owns scenario, achievement and other objectives.
    -- Without individual module control it stays available to the player.
end

showNative = function(self)
    local removed = self.nativeRemoved
    self.nativeHidden = nil
    if removed then
        local container = nativeFrame()
        if not container or type(container.AddModule) ~= "function" or type(container.HasModule) ~= "function" then
            container = nil
        end
        local added = false
        local pending = {}
        for frame, state in pairs(removed) do
            if state.removed and container then
                local called = pcall(container.AddModule, container, frame)
                local checked, present = pcall(container.HasModule, container, frame)
                if called and checked and present then
                    state.removed = false
                    added = true
                end
            end
            if not state.removed and state.shown then
                local checked, shown = pcall(frame.IsShown, frame)
                if not checked or (not shown and not pcall(frame.Show, frame)) then
                    pending[frame] = state
                end
            end
            if state.removed then pending[frame] = state end
        end
        self.nativeRemoved = next(pending) and pending or nil
        if self.nativeRemoved then app:Report("questList/restore", "Could not restore a native tracker module") end
        local manager = _G.ObjectiveTrackerManager
        if added and type(manager) == "table" and type(manager.UpdateAll) == "function" then
            -- The container's own displayability decides which modules show.
            pcall(manager.UpdateAll, manager)
        end
    end
end

-- Content decides the takeover, but a panel that yielded to the native tracker
-- for overlap no longer replaces anything: the quest modules must come back so
-- the player never loses both displays at once.
local function wantsNative(self)
    return NATIVE_PARITY_VALIDATED and self.hasContent == true and not self.overlapHidden
end

-- In combat the decision is queued, because a client that treats the tracker as
-- protected must not be touched mid-fight.
local function syncNative(self)
    if not self.running then return end
    if self.nativeRemoved and not self.nativeHidden then
        showNative(self)
        if self.nativeRemoved then return end
    end
    if wantsNative(self) then hideNative(self) else showNative(self) end
end

requestSync = function(self)
    self.hasContent = self.hasContent == true
    local wantHidden = wantsNative(self)
    -- Nothing to do when the recorded state already matches: this keeps routine
    -- quest log refreshes (including combat ones) out of the combat queue.
    if not (self.nativeRemoved and not self.nativeHidden)
        and (self.nativeHidden == true) == wantHidden then return end
    if inCombat() then
        app.Queue:Run(NATIVE_JOB, function()
            if self.running then syncNative(self) end
        end)
    else
        syncNative(self)
    end
end

component = app:RegisterComponent({ id = "questList", label = "questList", defaultEnabled = true,
    Supported = function()
        return type(C_QuestLog) == "table"
            and type(C_QuestLog.GetNumQuestLogEntries) == "function"
            and type(C_QuestLog.GetInfo) == "function"
    end,
    Enable = function(self)
        if not self.frame then build(self) end
        self.overlapGeneration = (self.overlapGeneration or 0) + 1
        for _, event in ipairs({ "QUEST_LOG_UPDATE", "QUEST_ACCEPTED", "QUEST_REMOVED", "QUEST_TURNED_IN", "QUEST_WATCH_LIST_CHANGED", "SUPER_TRACKING_CHANGED" }) do
            self:Listen(event, refresh)
        end
        if sessionSupported() then
            for _, event in ipairs({ "QUEST_SESSION_CREATED", "QUEST_SESSION_DESTROYED", "QUEST_SESSION_ENTER_STATE_CHANGED" }) do
                self:Listen(event, refresh)
            end
        end
        -- Item icons arrive after the row exists; remaining world-quest time
        -- advances while the panel sits still.
        self:Listen("GET_ITEM_INFO_RECEIVED", refreshItemIcons)
        self:Every(TASK_TICK, refreshTaskTimes)
        self:Listen("PLAYER_REGEN_ENABLED", function(current)
            if not current.running then return end
            -- A combat refresh painted text only; rebuild once the lock is gone.
            -- Otherwise still pick up world-quest time that changed mid-fight.
            if current.pendingReflow then
                refresh(current)
            else
                refreshTaskTimes(current)
                requestSync(current)
            end
            scheduleOverlap(current)
        end)
        self:Listen("EDIT_MODE_LAYOUTS_UPDATED", function(current) scheduleOverlap(current) end)
        self:Listen("PLAYER_ENTERING_WORLD", function(current) scheduleOverlap(current) end)
        app:Subscribe(self, "LAYOUT_APPLIED", function(id)
            if id == "questList" then placeBelowMap(self); scheduleOverlap(self) end
        end)
        app:Subscribe(self, "RUNTIME_UPDATED", function() placeBelowMap(self); scheduleOverlap(self) end)
        -- Restore saved folds, then keep following the selected profile; the
        -- runtime cleanup unsubscribes this automatically on disable.
        seedFolds(self)
        self.filter = readFilter()
        app:Subscribe(self, "PROFILE_CHANGED", function()
            if not self.running then return end
            local filter = readFilter()
            local filterChanged = filter ~= self.filter
            self.filter = filter
            if seedFolds(self) or filterChanged then refresh(self) end
        end)
        -- Refresh draws the current quest data and records whether it has rows.
        refresh(self)
    end,
    Refresh = refresh,
    Disable = function(self)
        self.overlapGeneration = (self.overlapGeneration or 0) + 1
        if self.overlapTimer then self.overlapTimer:Cancel(); self.overlapTimer = nil end
        self.overlapHidden, self.overlapPending = nil, nil
        local entry = app.Layout.entries.questList
        if entry then entry.allowHiddenMove = nil end
        if self.frame then self.frame:Hide() end
        clearFeedback(self)
        self.pendingReflow, self.lockedPaint = nil, nil
        if self.sessionBanner then
            self.sessionBanner.frame:Hide()
            self.sessionBanner = nil
        end
        app.Queue:Run(NATIVE_JOB, function()
            if self.running then return end
            showNative(self)
        end)
    end,
})

-- Diagnostics: one line for the components page inside `/luma status`. The
-- coverage part names whether the panel took only the quest modules.
function component:Describe()
    if not self.running then return nil end
    local state = self.nativeHidden and app.L.nativeTaken or app.L.nativeKept
    local content = self.hasContent and app.L.nativeContent or app.L.nativeNoContent
    if not self.nativeHidden then
        local result = string.format("questList: %s · %s · %s", state, content, app.L.nativeAwaitingValidation)
        if self.overlapHidden then result = result .. " · " .. app.L.questOverlapStatus end
        return result
    end
    return string.format("questList: %s · %s · %s", state, content, app.L.nativeQuestsOnly)
end
