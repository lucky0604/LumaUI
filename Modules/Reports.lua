local _, app = ...
local Reports = {}
app.Reports = Reports

local muted = app.Theme.colors.muted
local text = app.Theme.colors.text

local function plain(value, expected)
    return app.Capabilities.Plain(value, expected)
end

local function addMuted(tooltip, message)
    tooltip:AddLine(message, muted[1], muted[2], muted[3], true)
end

local function addLine(tooltip, message, red, green, blue)
    tooltip:AddLine(message, red or text[1], green or text[2], blue or text[3], true)
end

local function secondsLabel(seconds)
    seconds = plain(seconds, "number")
    if not seconds then return nil end
    if seconds <= 0 then return nil end
    if type(SecondsToTime) == "function" then
        local ok, label = pcall(SecondsToTime, seconds, true, nil, 3)
        label = ok and plain(label, "string") or nil
        if label then return label end
    end
    local days = math.floor(seconds / 86400)
    local hours = math.floor((seconds % 86400) / 3600)
    local minutes = math.floor((seconds % 3600) / 60)
    if days > 0 then return string.format("%dd %dh", days, hours) end
    if hours > 0 then return string.format("%dh %dm", hours, minutes) end
    return string.format("%dm", minutes)
end

local function savedInstances()
    if type(GetNumSavedInstances) ~= "function" or type(GetSavedInstanceInfo) ~= "function" then return nil end
    local count = plain(GetNumSavedInstances(), "number")
    if not count then return nil end
    local raids, bosses = {}, {}
    for index = 1, count do
        local ok, name, _, reset, _, _, extended, _, isRaid, _, difficultyName = pcall(GetSavedInstanceInfo, index)
        if ok then
            name = plain(name, "string")
            if name and plain(isRaid, "boolean") then
                raids[#raids + 1] = {
                    name = name,
                    reset = plain(reset, "number"),
                    extended = plain(extended, "boolean"),
                    difficulty = plain(difficultyName, "string"),
                }
            end
        end
    end
    if type(GetNumSavedWorldBosses) == "function" and type(GetSavedWorldBossInfo) == "function" then
        local bossCount = plain(GetNumSavedWorldBosses(), "number") or 0
        for index = 1, bossCount do
            local ok, name, _, reset = pcall(GetSavedWorldBossInfo, index)
            name = ok and plain(name, "string") or nil
            if name then bosses[#bosses + 1] = { name = name, reset = plain(reset, "number") } end
        end
    end
    return raids, bosses
end

function Reports:ShowRaid(owner)
    if type(RequestRaidInfo) == "function" then pcall(RequestRaidInfo) end
    local tooltip = GameTooltip
    tooltip:SetOwner(owner, "ANCHOR_RIGHT")
    tooltip:SetText(app.L.raidProgress)
    local raids, bosses = savedInstances()
    if not raids then
        addMuted(tooltip, app.L.unavailable)
        tooltip:Show()
        return
    end
    local shown = 0
    for _, raid in ipairs(raids) do
        shown = shown + 1
        local name = raid.name
        if raid.difficulty then name = name .. "  ·  " .. raid.difficulty end
        addLine(tooltip, name)
        local reset = secondsLabel(raid.reset)
        local status
        if reset then
            status = string.format(app.L.raidResets, reset)
        else
            status = app.L.raidExpired
        end
        if raid.extended then status = status .. "  ·  " .. app.L.raidExtended end
        addMuted(tooltip, status)
    end
    if #bosses > 0 then
        addLine(tooltip, app.L.worldBosses)
        for _, boss in ipairs(bosses) do
            shown = shown + 1
            local reset = secondsLabel(boss.reset)
            addMuted(tooltip, boss.name .. (reset and ("  ·  " .. string.format(app.L.raidResets, reset)) or ""))
        end
    end
    if shown == 0 then addMuted(tooltip, app.L.raidNone) end
    tooltip:Show()
end

local function moneyString(amount)
    if not plain(amount, "number") then return nil end
    if type(GetMoneyString) ~= "function" then return nil end
    local ok, value = pcall(GetMoneyString, amount, true)
    return ok and plain(value, "string") or nil
end

local function sortedLedger()
    local list = {}
    for key, amount in pairs(app.Store.money or {}) do
        if plain(amount, "number") then list[#list + 1] = { key = key, amount = amount } end
    end
    table.sort(list, function(a, b)
        if a.amount == b.amount then return a.key < b.key end
        return a.amount > b.amount
    end)
    return list
end

function Reports:RecordMoney()
    local amount = plain(type(GetMoney) == "function" and GetMoney() or nil, "number")
    local character = app.Store.character
    if amount and character then app.Store:SetMoney(character, amount) end
end

function Reports:ShowMoney(owner)
    self:RecordMoney()
    local tooltip = GameTooltip
    tooltip:SetOwner(owner, "ANCHOR_RIGHT")
    tooltip:SetText(app.L.goldLedger)
    local current, total, count = app.Store.character, 0, 0
    local list = sortedLedger()
    local limit = 12
    for index, entry in ipairs(list) do
        total = total + entry.amount
        count = count + 1
        local label = entry.key
        if entry.key == current then label = label .. "  (" .. app.L.goldCurrent .. ")" end
        local value = moneyString(entry.amount) or tostring(entry.amount)
        if index <= limit then
            addLine(tooltip, label)
            addMuted(tooltip, value)
        end
    end
    if count > limit then addMuted(tooltip, string.format("+%d", count - limit)) end
    if count == 0 then addMuted(tooltip, app.L.unavailable) end
    local totalLabel = moneyString(total)
    if totalLabel then
        addLine(tooltip, app.L.goldTotal .. ":  " .. totalLabel)
    end

    local bank = C_Bank
    local function fetchBank(bankType)
        if type(bank) ~= "table" or type(bank.FetchDepositedMoney) ~= "function" then return nil end
        if type(bank.CanViewBank) == "function" then
            local ok, viewable = pcall(bank.CanViewBank, bankType)
            if not ok or not viewable then return nil end
        end
        local ok, amount = pcall(bank.FetchDepositedMoney, bankType)
        if not ok then return nil end
        return plain(amount, "number")
    end
    if type(Enum) == "table" and type(Enum.BankType) == "table" then
        local warband = fetchBank(Enum.BankType.Account)
        local label = moneyString(warband)
        if label then addLine(tooltip, app.L.goldWarband .. ":  " .. label) end
    end

    addMuted(tooltip, app.L.goldNote)
    tooltip:Show()
end

function Reports:ShowZone(owner)
    local tooltip = GameTooltip
    tooltip:SetOwner(owner, "ANCHOR_RIGHT")
    tooltip:SetText(app.L.zoneTooltip)
    self:AddLocation(tooltip)
    tooltip:Show()
end

function Reports:ShowPerformance(owner)
    local tooltip = GameTooltip
    tooltip:SetOwner(owner, "ANCHOR_RIGHT")
    tooltip:SetText(app.L.networkTooltip)
    self:AddPerformance(tooltip)
    tooltip:Show()
end

-- The lines are shared with the compact strip's summary report, so both places
-- can never disagree about what LumaUI knows.

function Reports:AddPerformance(tooltip)
    local fps, home, world = app.Capabilities.Performance()
    if fps then addLine(tooltip, string.format("%s:  %d", app.L.networkFps, math.floor(fps + 0.5))) end
    if home and world then
        addLine(tooltip, string.format("%s:  %d %s", app.L.networkHome, home, app.L.latency))
        addLine(tooltip, string.format("%s:  %d %s", app.L.networkWorld, world, app.L.latency))
    end
end

function Reports:AddLocation(tooltip)
    local zone = plain(GetRealZoneText(), "string")
    if zone then addLine(tooltip, zone) end
    local subZone = type(GetSubZoneText) == "function" and plain(GetSubZoneText(), "string") or nil
    if subZone and subZone ~= "" and subZone ~= zone then
        addMuted(tooltip, string.format("%s:  %s", app.L.subZoneLabel, subZone))
    end
    if type(C_Map) == "table" and type(C_Map.GetBestMapForUnit) == "function" then
        local map = C_Map.GetBestMapForUnit("player")
        local position = map and C_Map.GetPlayerMapPosition(map, "player")
        if position then
            local x, y = position:GetXY()
            x, y = plain(x, "number"), plain(y, "number")
            if x and y then
                addMuted(tooltip, string.format("%s:  %.0f, %.0f", app.L.coordsLabel, x * 100, y * 100))
            end
        end
    end
end

-- Lowest durability among equipped items, as a percentage, when the client
-- exposes the query. A slot with no item is skipped; an all-empty set reports
-- nothing rather than a misleading 100%.
local function lowestDurability()
    if type(GetInventoryItemDurability) ~= "function" or type(GetInventoryItemLink) ~= "function" then return nil end
    local lowest
    for slot = 1, 19 do
        local ok, link = pcall(GetInventoryItemLink, "player", slot)
        if ok and link then
            local okd, current, maximum = pcall(GetInventoryItemDurability, slot)
            current, maximum = okd and plain(current, "number") or nil, okd and plain(maximum, "number") or nil
            if current and maximum and maximum > 0 then
                local percent = math.floor(current / maximum * 100)
                if not lowest or percent < lowest then lowest = percent end
            end
        end
    end
    return lowest
end

-- The compact strip's constant text is the zone and the time; this single
-- hover region carries everything that used to be printed all the time.
function Reports:ShowSummary(owner)
    self:RecordMoney()
    local tooltip = GameTooltip
    tooltip:SetOwner(owner, "ANCHOR_RIGHT")
    tooltip:SetText(app.L.summaryTooltip)
    self:AddLocation(tooltip)
    local amount = plain(type(GetMoney) == "function" and GetMoney() or nil, "number")
    local label = moneyString(amount)
    if label then addLine(tooltip, string.format("%s:  %s", app.L.gold, label)) end
    local durability = lowestDurability()
    if durability then
        addLine(tooltip, string.format("%s:  %d%%", app.L.durability, durability))
    end
    self:AddPerformance(tooltip)
    addMuted(tooltip, app.L.summaryHint)
    tooltip:Show()
end