local _, app = ...

-- The LumaUI character window is composed, not skinned. Four zones share one
-- grid: identity and item level across the top, equipment inspection on the
-- left, the player model in the middle and the attribute / equipment-set panel
-- on the right. The reputation and currency pages reuse one list renderer.
--
-- Equipment follows real Retail slot semantics: armor, accessories and a
-- single weapons column of its own. The denominator is the number of slots
-- this client and character actually use, so an unused ranged slot never
-- inflates it, and no frame is added just to fill the grid. Slots are plain
-- buttons driven by public inventory APIs; template names disappear between
-- builds and a missing template must not fail the window.
--
-- Secret rules: item identity and player stats are public values read through
-- Plain(); nothing here compares, concatenates or persists a restricted value.
-- Display refreshes never trigger gameplay actions: equipment sets only swap
-- when the player clicks a set row.

local W, H = 760, 600
local HEADER_H, TAB_H, PAD = 44, 40, 14
local IDENTITY_H = 64
local MAIN_TOP = IDENTITY_H + 8
local MAIN_H = H - HEADER_H - TAB_H - MAIN_TOP - 10

local SLOT, SLOT_GAP = 40, 6
local SLOT_PITCH = SLOT + SLOT_GAP
local ROW_H = 22
local SET_ROW_H = 28
local SEP = "  ·  "

-- Retail inventory slot ids (INVSLOT_*), ordered anatomically inside each group.
local SLOT_HEAD, SLOT_NECK, SLOT_SHOULDER, SLOT_SHIRT, SLOT_CHEST = 1, 2, 3, 4, 5
local SLOT_WAIST, SLOT_LEGS, SLOT_FEET, SLOT_WRIST, SLOT_HANDS = 6, 7, 8, 9, 10
local SLOT_FINGER1, SLOT_FINGER2, SLOT_TRINKET1, SLOT_TRINKET2 = 11, 12, 13, 14
local SLOT_BACK, SLOT_MAIN, SLOT_OFF, SLOT_RANGED, SLOT_TABARD = 15, 16, 17, 18, 19

local ARMOR_SLOTS = { SLOT_HEAD, SLOT_SHOULDER, SLOT_BACK, SLOT_CHEST, SLOT_WRIST,
    SLOT_HANDS, SLOT_WAIST, SLOT_LEGS, SLOT_FEET, SLOT_SHIRT, SLOT_TABARD }
local ACCESSORY_SLOTS = { SLOT_NECK, SLOT_FINGER1, SLOT_FINGER2, SLOT_TRINKET1, SLOT_TRINKET2 }
local WEAPON_SLOTS = { SLOT_MAIN, SLOT_OFF, SLOT_RANGED }

local GEAR_COLUMNS = 3
local GEAR_W = GEAR_COLUMNS * SLOT + (GEAR_COLUMNS - 1) * SLOT_GAP
local WEAPON_X = PAD + GEAR_W + 10
local MODEL_X = WEAPON_X + SLOT + 14
local MODEL_W = 284
local STATS_X = MODEL_X + MODEL_W + 14
local STATS_W = W - PAD - STATS_X
local STAT_CONTENT_W = STATS_W - 16
local LIST_W = W - 2 * PAD - 4
local LIST_TOP = 40

local component

local function plain(value, kind)
    return app.Capabilities.Plain(value, kind)
end

-- One ending path for the model drag: mouse-up, hiding the window, switching
-- pages and disabling the component all clear the ticker, the drag flag and the
-- last cursor position, so no owned ticker survives a closed window.
local function endModelDrag(model)
    if not model then return end
    model.dragging = false
    if model.ticker then model.ticker:Cancel(); model.ticker = nil end
    model.lastX = nil
end

local function readValue(getter)
    local ok, value = pcall(getter)
    if not ok then return nil end
    return plain(value, "number")
end

-- ---------------------------------------------------------------------------
-- Painting helpers
-- ---------------------------------------------------------------------------

-- Repaint the cached card when the profile or theme changes. The plate and
-- shadow are shared with the settings and inventory windows.
local function paintBackground(window)
    app.Surface:Plate(window, "card")
end

local function paintHeader(window)
    local rule = app.Surface:HLine(window, 0.45)
    rule:SetPoint("TOPLEFT", PAD, -HEADER_H)
    rule:SetPoint("TOPRIGHT", -PAD, -HEADER_H)
    window.headerRule = rule
    local function paint()
        local line, text = app.Theme.colors.line, app.Theme.colors.text
        rule:SetHeight(app.Pixel:Pixels(1, window))
        rule:SetVertexColor(line[1], line[2], line[3], 0.45)
        window.title:SetTextColor(text[1], text[2], text[3], 1)
    end
    window.painters[#window.painters + 1] = paint
    paint()
end

-- Section labels use the same quiet type role and rule as the settings pages.
local function sectionHeader(window, parent, text, x, y, width)
    local label = app.Type:Text(parent, "label")
    label:SetPoint("TOPLEFT", x, -y - 2)
    label:SetWidth(width + 8)
    label:SetWordWrap(false)
    label:SetText(text)
    local rule = app.Surface:HLine(parent, 0.25)
    rule:SetPoint("TOPLEFT", x, -y - 19)
    rule:SetWidth(width)
    local function paint()
        local line, muted = app.Theme.colors.line, app.Theme.colors.muted
        rule:SetHeight(app.Pixel:Pixels(1, parent))
        rule:SetVertexColor(line[1], line[2], line[3], 0.25)
        label:SetTextColor(muted[1], muted[2], muted[3], 1)
    end
    window.painters[#window.painters + 1] = paint
    paint()
    return label
end

-- ---------------------------------------------------------------------------
-- Inventory data
-- ---------------------------------------------------------------------------

local function slotItemID(slotID)
    if type(GetInventoryItemID) ~= "function" then return nil end
    local ok, itemID = pcall(GetInventoryItemID, "player", slotID)
    itemID = ok and plain(itemID, "number") or nil
    if itemID and itemID ~= 0 then return itemID end
    return nil
end

local function slotHasItem(slotID)
    if slotItemID(slotID) then return true end
    if type(GetInventoryItemLink) == "function" then
        local ok, link = pcall(GetInventoryItemLink, "player", slotID)
        link = ok and plain(link, "string") or nil
        if link and link ~= "" then return true end
    end
    if type(GetInventoryItemTexture) == "function" then
        local ok, texture = pcall(GetInventoryItemTexture, "player", slotID)
        texture = ok and plain(texture, "number") or nil
        if texture then return true end
    end
    return false
end

-- The ranged/relic slot is real on Classic builds; Retail keeps the id but no
-- longer uses it, so it only earns a place when the character actually has
-- something there. This is what keeps the denominator honest.
local function rangedSupported()
    if slotHasItem(SLOT_RANGED) then return true end
    return app.Capabilities.IsRetail() ~= true
end

-- Equipment icon. Three paths, because the icon API moved between builds:
--   1. GetInventoryItemTexture (older builds),
--   2. GetInventoryItemID + C_Item.GetItemIconByID,
--   3. GetInventoryItemLink + GetItemInfo (the link path works on every build
--      that still has item links; the icon is the tenth return value).
local function itemIcon(slotID)
    if type(GetInventoryItemTexture) == "function" then
        local ok, texture = pcall(GetInventoryItemTexture, "player", slotID)
        texture = ok and plain(texture, "number") or nil
        if texture then return texture end
    end
    if type(GetInventoryItemID) == "function" and type(C_Item) == "table"
        and type(C_Item.GetItemIconByID) == "function" then
        local itemID = slotItemID(slotID)
        if itemID then
            local okIcon, icon = pcall(C_Item.GetItemIconByID, itemID)
            icon = okIcon and plain(icon, "number") or nil
            if icon then return icon end
        end
    end
    if type(GetInventoryItemLink) == "function" and type(GetItemInfo) == "function" then
        local ok, link = pcall(GetInventoryItemLink, "player", slotID)
        link = ok and plain(link, "string") or nil
        if link then
            local okInfo, _, _, _, _, _, _, _, _, _, texture = pcall(GetItemInfo, link)
            texture = okInfo and plain(texture, "number") or nil
            if texture then return texture end
        end
    end
end

local function paintSlot(button)
    local theme = app.Theme
    local surface, line = theme.colors.surface, theme.colors.line
    local opacity = theme:Opacity("window")
    local texture = itemIcon(button.slotID)
    if texture then
        button.icon:SetTexture(texture)
        if type(button.icon.SetTexCoord) == "function" then
            pcall(button.icon.SetTexCoord, button.icon, 0.07, 0.93, 0.07, 0.93)
        end
        button.icon:Show()
    else
        button.icon:Hide()
    end
    local quality
    if type(GetInventoryItemQuality) == "function" then
        local ok, value = pcall(GetInventoryItemQuality, "player", button.slotID)
        quality = ok and plain(value, "number") or nil
    end
    local red, green, blue = theme:QualityColor(quality)
    if red then
        button:SetBackdropBorderColor(red, green, blue, 1)
        button:SetBackdropColor(surface[1] * 1.2, surface[2] * 1.2, surface[3] * 1.2, opacity)
    else
        -- An empty slot is a quiet inset, not a bright outline waiting to be
        -- counted: its border sits below the line colour.
        button:SetBackdropBorderColor(line[1], line[2], line[3], 0.45)
        button:SetBackdropColor(surface[1], surface[2], surface[3], opacity * 0.8)
    end
end

local function createSlot(parent, slotID)
    local button = CreateFrame("Button", nil, parent, "BackdropTemplate")
    button:SetSize(SLOT, SLOT)
    button.slotID = slotID
    local edge = app.Pixel:Pixels(1)
    button:SetBackdrop({ bgFile = app.Theme.white, edgeFile = app.Theme.white, edgeSize = edge,
        insets = { left = edge, right = edge, top = edge, bottom = edge } })
    button.icon = button:CreateTexture(nil, "ARTWORK")
    button.icon:SetPoint("TOPLEFT", 3, -3)
    button.icon:SetPoint("BOTTOMRIGHT", -3, 3)
    button.icon:Hide()
    -- Right-click use needs its own register entry; a plain Button only gets
    -- left clicks by default.
    if type(button.RegisterForClicks) == "function" then
        button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    end
    button:SetScript("OnClick", function(self, mouseButton)
        if mouseButton == "RightButton" then
            if type(UseInventoryItem) == "function" then pcall(UseInventoryItem, self.slotID) end
        elseif type(PickupInventoryItem) == "function" then
            pcall(PickupInventoryItem, self.slotID)
        end
    end)
    button:SetScript("OnEnter", function(self)
        local tooltip = _G.GameTooltip
        if type(tooltip) ~= "table" then return end
        -- SetOwner is what makes the tooltip follow the cursor and show at
        -- all; without it SetInventoryItem fills a hidden tooltip.
        if type(tooltip.SetOwner) == "function" then pcall(tooltip.SetOwner, tooltip, self, "ANCHOR_RIGHT") end
        if type(tooltip.ClearLines) == "function" then pcall(tooltip.ClearLines, tooltip) end
        if type(tooltip.SetInventoryItem) == "function" then
            pcall(tooltip.SetInventoryItem, tooltip, "player", self.slotID)
        end
        if type(tooltip.Show) == "function" then pcall(tooltip.Show, tooltip) end
    end)
    button:SetScript("OnLeave", function()
        local tooltip = _G.GameTooltip
        if type(tooltip) == "table" and type(tooltip.Hide) == "function" then pcall(tooltip.Hide, tooltip) end
    end)
    -- Drag and drop: dragging picks the slot up, dropping another item on it
    -- places that item there — the game's own PickupInventoryItem does the swap.
    button:RegisterForDrag("LeftButton")
    button:SetScript("OnDragStart", function(self)
        if type(PickupInventoryItem) == "function" then pcall(PickupInventoryItem, self.slotID) end
    end)
    button:SetScript("OnReceiveDrag", function(self)
        if type(PickupInventoryItem) == "function" then pcall(PickupInventoryItem, self.slotID) end
    end)
    paintSlot(button)
    return button
end

local function equippedCount(window)
    local count = 0
    for _, slot in ipairs(window.slots or {}) do
        if slotHasItem(slot.slotID) then count = count + 1 end
    end
    return count
end

-- ---------------------------------------------------------------------------
-- Identity and attributes
-- ---------------------------------------------------------------------------

local function playerName()
    local name, realm
    if type(UnitFullName) == "function" then
        local ok, first, second = pcall(UnitFullName, "player")
        if ok then name, realm = plain(first, "string"), plain(second, "string") end
    end
    if not name and type(UnitName) == "function" then
        local ok, first = pcall(UnitName, "player")
        name = ok and plain(first, "string") or nil
    end
    return name, realm
end

local function playerClass()
    if type(UnitClass) ~= "function" then return nil end
    local ok, display, token, id = pcall(UnitClass, "player")
    if not ok then return nil end
    return plain(display, "string"), plain(token, "string"), plain(id, "number")
end

local function playerLevel()
    if type(UnitLevel) ~= "function" then return nil end
    local ok, level = pcall(UnitLevel, "player")
    return ok and plain(level, "number") or nil
end

-- Specialization name and primary stat index (1 strength .. 4 intellect).
local function specialization()
    if type(GetSpecialization) ~= "function" or type(GetSpecializationInfo) ~= "function" then
        return nil, nil
    end
    local ok, index = pcall(GetSpecialization)
    index = ok and plain(index, "number") or nil
    if not index or index == 0 then return nil, nil end
    local okInfo, _, name, _, _, _, primaryStat = pcall(GetSpecializationInfo, index)
    if not okInfo then return nil, nil end
    return plain(name, "string"), plain(primaryStat, "number")
end

-- Primary statistics are integers (stat points, armour); secondary statistics
-- are percentages as the client returns them. The distinction is kept in the
-- format, not guessed per value.
local PRIMARY_SOURCES = {
    { key = "statStrength", index = 1, getter = function() return UnitStat("player", 1) end },
    { key = "statAgility", index = 2, getter = function() return UnitStat("player", 2) end },
    { key = "statStamina", index = 3, getter = function() return UnitStat("player", 3) end },
    { key = "statIntellect", index = 4, getter = function() return UnitStat("player", 4) end },
    { key = "statArmor", getter = function() return (UnitArmor("player")) end },
}
local SECONDARY_SOURCES = {
    { key = "statCrit", percent = true, rating = "CR_CRIT_MELEE", ratingConst = "CritMelee",
        getter = function() return GetCritChance() end },
    { key = "statHaste", percent = true, rating = "CR_HASTE_MELEE", ratingConst = "HasteMelee",
        getter = function() return GetHaste() end },
    { key = "statMastery", percent = true, rating = "CR_MASTERY", ratingConst = "Mastery",
        getter = function() return GetMasteryEffect() end },
    { key = "statVersatility", percent = true, rating = "CR_VERSATILITY_DAMAGE_DONE",
        ratingConst = "VersatilityDamageDone", getter = function() return GetVersatilityBonus(0) end },
}
local STAT_SOURCES = {}
for _, source in ipairs(PRIMARY_SOURCES) do STAT_SOURCES[#STAT_SOURCES + 1] = source end
for _, source in ipairs(SECONDARY_SOURCES) do STAT_SOURCES[#STAT_SOURCES + 1] = source end

local function formatStat(source, value)
    if type(value) ~= "number" then return "-" end
    if source.percent then return string.format("%.1f%%", value) end
    return string.format("%d", math.floor(value))
end

-- Combat rating ids: the CR_* globals of older builds, or Constants.CombatRating
-- on current ones. Returns nil when neither exists, in which case the tooltip
-- simply omits the rating line.
local function ratingID(globalName, constantName)
    local value = _G[globalName]
    if type(value) == "number" then return value end
    local constants = _G.Constants and _G.Constants.CombatRating
    if type(constants) == "table" then
        value = constants[constantName]
        if type(value) == "number" then return value end
    end
    return nil
end

-- A hover tip on a stat row: the explanation first, then the rating line for
-- secondary stats when the client exposes it.
local function attachTip(row, text, ratingKey, ratingConstant)
    if not text then return end
    row:EnableMouse(true)
    row:SetScript("OnEnter", function(self)
        local tip = _G.GameTooltip
        if type(tip) ~= "table" then return end
        if type(tip.SetOwner) == "function" then pcall(tip.SetOwner, tip, self, "ANCHOR_RIGHT") end
        if type(tip.ClearLines) == "function" then pcall(tip.ClearLines, tip) end
        if type(tip.AddLine) == "function" then pcall(tip.AddLine, tip, text) end
        local id = ratingKey and ratingID(ratingKey, ratingConstant)
        if id and type(GetCombatRating) == "function" then
            local rating = readValue(function() return (GetCombatRating(id)) end)
            if rating then
                local bonus = readValue(function() return (GetCombatRatingBonus(id)) end)
                if bonus then
                    pcall(tip.AddLine, tip, string.format(app.L.statRatingDetail, math.floor(rating), bonus))
                else
                    pcall(tip.AddLine, tip, string.format(app.L.statRatingOnly, math.floor(rating)))
                end
            end
        end
        if type(tip.Show) == "function" then pcall(tip.Show, tip) end
    end)
    row:SetScript("OnLeave", function()
        local tip = _G.GameTooltip
        if type(tip) == "table" and type(tip.Hide) == "function" then pcall(tip.Hide, tip) end
    end)
end

-- ---------------------------------------------------------------------------
-- Equipment sets
-- ---------------------------------------------------------------------------

-- Saved equipment sets, with the state the game reports for each one. An older
-- build without GetEquipmentSetIDs falls back to indexing GetEquipmentSetInfo.
local function equipmentSets()
    local out = {}
    local api = _G.C_EquipmentSet
    if type(api) ~= "table" then return out end
    local ids = {}
    if type(api.GetEquipmentSetIDs) == "function" then
        local ok, list = pcall(api.GetEquipmentSetIDs)
        if ok and type(list) == "table" then
            for _, id in ipairs(list) do
                id = plain(id, "number")
                if id then ids[#ids + 1] = id end
            end
        end
    end
    if #ids == 0 and type(api.GetNumEquipmentSets) == "function"
        and type(api.GetEquipmentSetInfo) == "function" then
        local count = readValue(function() return (api.GetNumEquipmentSets()) end)
        for index = 1, math.min(count or 0, 40) do
            local ok, _, _, setID = pcall(api.GetEquipmentSetInfo, index)
            setID = ok and plain(setID, "number") or nil
            if setID then ids[#ids + 1] = setID end
        end
    end
    for _, id in ipairs(ids) do
        local ok, name, icon, setID, equipped, items, equippedItems, lost = pcall(api.GetEquipmentSetInfo, id)
        name = ok and plain(name, "string") or nil
        if name and name ~= "" then
            out[#out + 1] = {
                id = plain(setID, "number") or id,
                name = name,
                icon = plain(icon, "number"),
                equipped = plain(equipped, "boolean") == true,
                items = plain(items, "number"),
                equippedItems = plain(equippedItems, "number"),
                lost = plain(lost, "number"),
            }
        end
    end
    return out
end

-- Equipping a set is a real operation, never something a display refresh does.
-- It is refused in combat and for sets with locked items, and clicking the
-- already equipped set is a no-op.
local function equipSet(setID, isEquipped)
    if not setID or isEquipped then return end
    local api = _G.C_EquipmentSet
    if type(api) ~= "table" or type(api.UseEquipmentSet) ~= "function" then return end
    if InCombatLockdown() then app:Print(app.L.equipSetCombat); return end
    if type(api.EquipmentSetContainsLockedItems) == "function" then
        local ok, locked = pcall(api.EquipmentSetContainsLockedItems, setID)
        if ok and locked == true then app:Print(app.L.equipSetLocked); return end
    end
    app:Call("characterWindow/equipSet", api.UseEquipmentSet, setID)
end

-- ---------------------------------------------------------------------------
-- List pages (reputation and currency share one renderer)
-- ---------------------------------------------------------------------------

-- Faction standing, coloured by the game's own reaction colours.
local function stanceColor(id)
    local reaction = {
        [5] = { 0.20, 0.82, 0.38 }, [6] = { 0.20, 0.82, 0.38 }, [7] = { 0.20, 0.82, 0.38 }, [8] = { 0.20, 0.82, 0.38 },
        [4] = { 0.93, 0.78, 0.25 }, [3] = { 0.90, 0.55, 0.25 }, [2] = { 0.88, 0.35, 0.25 },
        [1] = { 0.80, 0.20, 0.20 },
    }
    return reaction[id] or app.Theme.colors.line
end

-- Factions, regrouped so every header is followed by its own members. The
-- client's flat list is not reliably ordered: some groups list their members
-- before the header, which broke folding and indentation. Membership is
-- assigned by scanning forward to the next header, and a header with nothing
-- after it claims the contiguous entries right before it.
local function factionEntries()
    local raw = {}
    local api = _G.C_Reputation
    if type(api) == "table" and type(api.GetNumFactions) == "function"
        and type(api.GetFactionDataByIndex) == "function" then
        local okCount, total = pcall(api.GetNumFactions)
        if not okCount or type(total) ~= "number" then return raw end
        for index = 1, total do
            local ok, data = pcall(api.GetFactionDataByIndex, index)
            if ok and type(data) == "table" and type(data.name) == "string" and data.name ~= "" then
                if data.isHeader == true then
                    raw[#raw + 1] = { kind = "header", key = "f" .. index, name = data.name }
                else
                    raw[#raw + 1] = { kind = "entry", name = data.name,
                        child = data.isChild == true,
                        standing = plain(data.reaction, "number"),
                        min = plain(data.currentReactionThreshold, "number"),
                        max = plain(data.nextReactionThreshold, "number"),
                        value = plain(data.currentStanding, "number") }
                end
            end
        end
    elseif type(GetNumFactions) == "function" then
        local okCount, total = pcall(GetNumFactions)
        if not okCount or type(total) ~= "number" then return raw end
        for index = 1, total do
            local ok, name, _, standingID, barMin, barMax, barValue, _, _, isHeader = pcall(GetFactionInfo, index)
            if ok and type(name) == "string" and name ~= "" then
                if isHeader == true then
                    raw[#raw + 1] = { kind = "header", key = "f" .. index, name = name }
                else
                    raw[#raw + 1] = { kind = "entry", name = name,
                        standing = type(standingID) == "number" and standingID or nil,
                        min = barMin, max = barMax, value = barValue }
                end
            end
        end
    else
        return raw
    end
    return raw
end

-- Every currency the client lists, keeping its own group headers.
local function currencyEntries()
    local out = {}
    local api = _G.C_CurrencyInfo
    if type(api) ~= "table" or type(api.GetCurrencyListSize) ~= "function" then return out end
    local okSize, size = pcall(api.GetCurrencyListSize)
    if not okSize or type(size) ~= "number" then return out end
    for index = 1, size do
        local ok, info = pcall(api.GetCurrencyListInfo, index)
        if ok and type(info) == "table" and info.name then
            if info.isHeader then
                out[#out + 1] = { kind = "header", key = "c" .. index, name = info.name }
            elseif not info.isChild then
                out[#out + 1] = { kind = "entry", name = info.name,
                    quantity = plain(info.quantity, "number"), icon = plain(info.iconFileID, "number") }
            end
        end
    end
    return out
end

-- Standing text: the FACTION_STANDING_LABEL* globals on older builds, and the
-- localised string of the same name on current ones.
local function standingText(id)
    if type(id) ~= "number" then return "" end
    local label = _G["FACTION_STANDING_LABEL" .. id]
    if type(label) == "string" and label ~= "" then return label end
    if type(GetText) == "function" then
        local ok, text = pcall(GetText, "FACTION_STANDING_LABEL" .. id)
        if ok and type(text) == "string" then return text end
    end
    return ""
end

-- Marks every header that has at least one member after it. Computed on the
-- full list, so a folded header still knows it can be unfolded.
local function annotateMembers(entries)
    local current
    for _, entry in ipairs(entries) do
        if entry.kind == "header" then
            current = entry
            entry.hasMembers = false
        elseif current then
            current.hasMembers = true
        end
    end
    return entries
end

-- Hides the rows a folded header covers.
local function visibleEntries(page, entries)
    local shown, folded = {}, false
    for _, entry in ipairs(entries) do
        if entry.kind == "header" then
            folded = page.folds[entry.key] == true
            shown[#shown + 1] = entry
        elseif not folded then
            shown[#shown + 1] = entry
        end
    end
    return shown
end

-- A list row: label left, value right, a hairline under a stat and a dark band
-- behind a group header.
local function listRowFrame(parent, header, index)
    local row = CreateFrame("Frame", nil, parent)
    row:SetSize(LIST_W, ROW_H)
    row.label = app.Theme:Text(row, 12, false)
    row.label:SetPoint("LEFT", 4, 0)
    row.value = app.Theme:Text(row, 12, false)
    row.value:SetPoint("RIGHT", -4, 0)
    row.value:SetJustifyH("RIGHT")
    if not header and index and index % 2 == 0 then
        local shade = row:CreateTexture(nil, "BACKGROUND", nil, -8)
        shade:SetAllPoints(row)
        shade:SetColorTexture(1, 1, 1, 0.03)
    end
    local rule = row:CreateTexture(nil, "ARTWORK")
    rule:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 4, 0)
    rule:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -4, 0)
    rule:SetHeight(1)
    rule:SetColorTexture(1, 1, 1, 0.06)
    return row
end

local function listRow(page, index)
    page.rows = page.rows or {}
    local row = page.rows[index]
    if row then return row end
    row = listRowFrame(page, false, index)
    row:SetPoint("TOPLEFT", PAD, -(LIST_TOP - 4) - (index - 1) * ROW_H)
    row:EnableMouse(true)
    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(16, 16)
    row.icon:SetPoint("LEFT", 2, 0)
    row.icon:Hide()
    -- A thin progress bar for faction standing, drawn behind the text.
    row.track = row:CreateTexture(nil, "BACKGROUND", nil, -8)
    row.track:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 2, 0)
    row.track:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -2, 0)
    row.track:SetHeight(2)
    row.track:Hide()
    row.fill = row:CreateTexture(nil, "BACKGROUND", nil, -7)
    row.fill:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 2, 0)
    row.fill:SetHeight(2)
    row.fill:Hide()
    row.glow = row:CreateTexture(nil, "BACKGROUND", nil, -6)
    row.glow:SetAllPoints(row)
    row.glow:SetTexture(app.Theme.media.glow)
    row.glow:SetVertexColor(1, 1, 1, 0.10)
    row.glow:Hide()
    row:SetScript("OnEnter", function(self) self.glow:Show() end)
    row:SetScript("OnLeave", function(self) self.glow:Hide() end)
    page.rows[index] = row
    return row
end

-- Shared renderer: headers become fold toggles with a band, entries become
-- rows with a value, an optional icon and an optional progress bar. The row
-- count follows the page height, and the scroll offset is clamped so a long
-- list never scrolls into blank space.
local function renderList(window, page, kind)
    if not page then return end
    page.rows = page.rows or {}
    local all = annotateMembers(kind == "reputation" and factionEntries() or currencyEntries())
    local entries = visibleEntries(page, all)
    local rowsVisible = window.listRows or 14
    page.entryCount = #entries
    local maxOffset = math.max(0, #entries - rowsVisible)
    page.offset = math.max(0, math.min(page.offset or 0, maxOffset))
    local first = (page.offset or 0) + 1
    local shown = 0
    local afterHeader = false
    for index = first, math.min(#entries, first + rowsVisible - 1) do
        shown = shown + 1
        local entry = entries[index]
        local row = listRow(page, shown)
        -- A row directly under a header is a member of it: one indent level,
        -- so the hierarchy reads as a tree instead of a flat list.
        local indent = 4
        if entry.kind == "header" then
            afterHeader = true
        elseif afterHeader or entry.child then
            indent = 18
        end
        -- A currency icon occupies the left gutter, so its name starts after it.
        if entry.icon and kind ~= "reputation" then
            indent = indent + 14
        end
        row.label:ClearAllPoints()
        row.label:SetPoint("LEFT", indent, 0)
        -- Bound the label so a long faction or currency name truncates instead
        -- of running under the right-aligned value.
        row.label:SetWidth(math.max(60, LIST_W - indent - 104))
        row.icon:Hide()
        row.track:Hide()
        row.fill:Hide()
        if entry.kind == "header" then
            row.isHeader = true
            -- Only a header with members gets the fold marker; an empty group
            -- is shown as a plain band.
            local marker = ""
            if entry.hasMembers then
                marker = page.folds[entry.key] and "+ " or "- "
            end
            row.label:SetText(marker .. entry.name)
            row.value:SetText("")
            local accent = app.Theme:Accent()
            row.label:SetTextColor(accent[1], accent[2], accent[3], 1)
            row:SetScript("OnMouseUp", function()
                if entry.hasMembers then
                    page.folds[entry.key] = not page.folds[entry.key]
                    renderList(window, page, kind)
                    return
                end
                -- A group the client reported without members may still be
                -- expandable through its own API; ask it, then repaint.
                local api = _G.C_Reputation
                local apiIndex = tonumber(tostring(entry.key):match("%d+"))
                if api and apiIndex and type(api.SetFactionCollapsed) == "function" then
                    pcall(api.SetFactionCollapsed, apiIndex, false)
                    renderList(window, page, kind)
                end
            end)
        else
            row.isHeader = false
            row:SetScript("OnMouseUp", nil)
            if kind == "reputation" then
                local color = entry.standing and stanceColor(entry.standing) or app.Theme.colors.muted
                row.label:SetText(entry.name)
                row.label:SetTextColor(color[1], color[2], color[3], 1)
                -- The standing label plus the exact numbers, so the page shows
                -- how much reputation is actually there.
                local standing = standingText(entry.standing)
                if type(entry.value) == "number" and type(entry.max) == "number" then
                    standing = standing ~= "" and (standing .. "  ") or ""
                    standing = standing .. string.format("%d / %d", entry.value, entry.max)
                elseif type(entry.value) == "number" then
                    standing = (standing ~= "" and (standing .. "  ") or "") .. string.format("%d", entry.value)
                end
                row.value:SetText(standing)
                if type(entry.min) == "number" and type(entry.max) == "number"
                    and type(entry.value) == "number" and entry.max > entry.min then
                    local ratio = math.max(0, math.min(1, (entry.value - entry.min) / (entry.max - entry.min)))
                    row.track:Show()
                    row.track:SetColorTexture(1, 1, 1, 0.08)
                    row.fill:Show()
                    row.fill:SetWidth(math.max(1, LIST_W * ratio))
                    row.fill:SetColorTexture(color[1], color[2], color[3], 0.55)
                end
            else
                row.label:SetText(entry.name)
                local muted = app.Theme.colors.muted
                row.label:SetTextColor(muted[1], muted[2], muted[3], 1)
                row.value:SetText(entry.quantity and tostring(entry.quantity) or "")
                if entry.icon and type(row.icon.SetTexture) == "function" then
                    pcall(row.icon.SetTexture, row.icon, entry.icon)
                    row.icon:Show()
                end
            end
        end
        row:Show()
    end
    -- An empty page says so instead of leaving a blank panel.
    local empty = entries[#entries] == nil
    if empty then
        local row = listRow(page, 1)
        row.isHeader = false
        row:SetScript("OnMouseUp", nil)
        row.label:ClearAllPoints()
        row.label:SetPoint("LEFT", 4, 0)
        row.label:SetText(app.L.listEmpty)
        local muted = app.Theme.colors.muted
        row.label:SetTextColor(muted[1], muted[2], muted[3], 1)
        row.value:SetText("")
        row.icon:Hide(); row.track:Hide(); row.fill:Hide()
        row:Show()
        shown = 1
    end
    for index = shown + 1, #page.rows do page.rows[index]:Hide() end
end

local function refreshReputation(window, page) renderList(window, page, "reputation") end
local function refreshCurrency(window, page) renderList(window, page, "currency") end

-- ---------------------------------------------------------------------------
-- Pages
-- ---------------------------------------------------------------------------

local function makePage(window, index)
    local page = CreateFrame("Frame", nil, window)
    page:SetPoint("TOPLEFT", 1, -HEADER_H)
    page:SetPoint("BOTTOMRIGHT", -1, TAB_H)
    page:Hide()
    page.offset = 0
    page.folds = {}
    -- Long lists scroll with the wheel; the page refreshes its own slice. Only
    -- the list pages take the wheel — the window itself never zooms globally.
    page:EnableMouseWheel(true)
    page:SetScript("OnMouseWheel", function(self, delta)
        local step = (delta > 0) and -1 or 1
        local maxOffset = math.max(0, (self.entryCount or 0) - (window.listRows or 14))
        self.offset = math.max(0, math.min(maxOffset, (self.offset or 0) + step))
        if self.refresh then self.refresh(self) end
    end)
    window.pages[index] = page
    return page
end

-- Page switching fades the incoming page in and settles the outgoing one, so a
-- fast tab press replaces the task instead of stacking two fades. While the
-- window is hidden the page is simply shown at full alpha; the window-level
-- open fade owns visibility then.
local function showPage(window, index)
    if window.currentPage == 1 and index ~= 1 then endModelDrag(window.model) end
    local previous = window.pages[window.currentPage]
    local page = window.pages[index]
    if previous and previous ~= page then
        app.Transitions:Settle(previous, "page")
        previous:SetAlpha(1)
        previous:Hide()
    end
    window.currentPage = index
    for buttonIndex, button in ipairs(window.tabs or {}) do
        button:SetSelected(buttonIndex == index)
    end
    if page then
        if window:IsShown() then
            if not page:IsShown() then page:SetAlpha(0) end
            page:Show()
            app.Transitions:Fade(page, page, 1, 0.14, nil, "page")
        else
            page:SetAlpha(1)
            page:Show()
        end
    end
    if index == 2 then refreshReputation(window, page) end
    if index == 3 then refreshCurrency(window, page) end
end

local TAB_LABELS = { "tabCharacter", "tabReputation", "tabCurrency" }

local function buildTabs(window)
    local bar = CreateFrame("Frame", nil, window)
    bar:SetPoint("BOTTOMLEFT", 1, 1)
    bar:SetPoint("BOTTOMRIGHT", -1, 1)
    bar:SetHeight(TAB_H)
    window.tabs = {}
    for index, key in ipairs(TAB_LABELS) do
        local button = app.Controls:Tab(bar, app.L[key], 120, function() showPage(window, index) end,
            { height = 30 })
        button:SetPoint("LEFT", 14 + (index - 1) * 128, 0)
        window.tabs[index] = button
    end
end

local function buildListHeader(window, page, text)
    page.title = app.Type:Text(page, "title")
    page.title:SetPoint("TOPLEFT", PAD, -10)
    page.title:SetText(text)
    page.rule = page:CreateTexture(nil, "ARTWORK")
    page.rule:SetPoint("TOPLEFT", PAD, -32)
    page.rule:SetSize(LIST_W, 1)
    local function paint()
        local accent = app.Theme:Accent()
        page.rule:SetColorTexture(accent[1], accent[2], accent[3], 0.35)
        page.title:SetTextColor(app.Theme.colors.text[1], app.Theme.colors.text[2], app.Theme.colors.text[3])
    end
    window.painters[#window.painters + 1] = paint
    paint()
end

-- ---------------------------------------------------------------------------
-- Zone 1: identity and item level
-- ---------------------------------------------------------------------------

local function buildIdentity(window, page)
    local strip = CreateFrame("Frame", nil, page)
    strip:SetPoint("TOPLEFT", PAD, -4)
    strip:SetSize(W - 2 * PAD, IDENTITY_H)
    window.identity = strip

    window.identityName = app.Type:Text(strip, "display")
    window.identityName:SetPoint("TOPLEFT", 0, -2)
    window.identityName:SetWidth(320)
    window.identityName:SetWordWrap(false)
    window.identityName:SetText("")

    window.identityRealm = app.Type:Text(strip, "label")
    window.identityRealm:SetPoint("LEFT", window.identityName, "RIGHT", 8, -1)
    window.identityRealm:SetWidth(125)
    window.identityRealm:SetWordWrap(false)
    window.identityRealm:SetText("")

    window.identityMeta = app.Type:Text(strip, "label")
    window.identityMeta:SetPoint("TOPLEFT", 0, -30)
    window.identityMeta:SetWidth(420)
    window.identityMeta:SetWordWrap(false)
    window.identityMeta:SetText("")

    -- The summary cluster sits on the right: item level on top, the equipped
    -- count under it, both right-aligned so a three-digit level never pushes
    -- the count sideways.
    window.itemLevel = CreateFrame("Frame", nil, strip)
    window.itemLevel:SetSize(90, 50)
    window.itemLevel:SetPoint("TOPRIGHT", 0, -0)
    window.itemLevel.value = app.Type:Text(window.itemLevel, "display")
    window.itemLevel.value:SetPoint("TOPRIGHT", 0, 0)
    window.itemLevel.value:SetJustifyH("RIGHT")
    window.itemLevel.value:SetText("-")
    window.itemLevel.label = app.Theme:Text(window.itemLevel, 10, true)
    window.itemLevel.label:SetPoint("TOPRIGHT", 0, -24)
    window.itemLevel.label:SetJustifyH("RIGHT")
    window.itemLevel.label:SetText(app.L.statItemLevel)

    window.equipped = CreateFrame("Frame", nil, strip)
    window.equipped:SetSize(160, 16)
    window.equipped:SetPoint("TOPRIGHT", -96, -26)
    window.equipped.label = app.Theme:Text(window.equipped, 11, true)
    window.equipped.label:SetPoint("RIGHT", -54, 0)
    window.equipped.label:SetText(app.L.statEquipped)
    window.equipped.value = app.Theme:Text(window.equipped, 11, false)
    window.equipped.value:SetPoint("RIGHT", 0, 0)
    window.equipped.value:SetJustifyH("RIGHT")
    window.equipped.value:SetText("-")

    -- A soft rule closes the identity strip without drawing a box around it.
    local rule = page:CreateTexture(nil, "ARTWORK")
    rule:SetPoint("TOPLEFT", PAD, -(IDENTITY_H + 2))
    rule:SetPoint("TOPRIGHT", -PAD, -(IDENTITY_H + 2))
    rule:SetHeight(1)
    local function paint()
        local accent = app.Theme:Accent()
        rule:SetColorTexture(accent[1], accent[2], accent[3], 0.18)
        local muted = app.Theme.colors.muted
        window.identityRealm:SetTextColor(muted[1], muted[2], muted[3], 1)
        window.identityMeta:SetTextColor(muted[1], muted[2], muted[3], 1)
        window.itemLevel.label:SetTextColor(muted[1], muted[2], muted[3], 1)
        window.equipped.label:SetTextColor(muted[1], muted[2], muted[3], 1)
        window.equipped.value:SetTextColor(muted[1], muted[2], muted[3], 1)
        local text = app.Theme.colors.text
        window.identityName:SetTextColor(text[1], text[2], text[3])
        window.itemLevel.value:SetTextColor(text[1], text[2], text[3])
    end
    window.painters[#window.painters + 1] = paint
    paint()
end

local function refreshIdentity(window)
    local name, realm = playerName()
    window.identityName:SetText(name or app.L.identityUnknown)
    window.identityRealm:SetText(realm or "")

    local classDisplay = playerClass()
    local specName = specialization()
    local parts = {}
    if classDisplay then parts[#parts + 1] = classDisplay end
    if specName then parts[#parts + 1] = specName end
    local level = playerLevel()
    if level then parts[#parts + 1] = string.format(app.L.characterLevel, level) end
    window.identityMeta:SetText(table.concat(parts, SEP))

    local levelValue = readValue(function() return (GetAverageItemLevel()) end)
    window.itemLevel.value:SetText(levelValue and string.format("%d", math.floor(levelValue)) or "-")
    window.equipped.value:SetText(string.format(app.L.equipCount, equippedCount(window), #(window.slots or {})))
end

-- ---------------------------------------------------------------------------
-- Zone 2: equipment inspection
-- ---------------------------------------------------------------------------

-- Which groups this client uses. The weapon group keeps a single column of its
-- own; the ranged slot only joins it when the character has something there.
local function gearGroups()
    local out = {}
    out[#out + 1] = { key = "equipGroupArmor", slots = ARMOR_SLOTS, columns = GEAR_COLUMNS, x = PAD }
    out[#out + 1] = { key = "equipGroupAccessories", slots = ACCESSORY_SLOTS, columns = GEAR_COLUMNS, x = PAD }
    local weapons = {}
    for _, slotID in ipairs(WEAPON_SLOTS) do
        if slotID ~= SLOT_RANGED or rangedSupported() then weapons[#weapons + 1] = slotID end
    end
    out[#out + 1] = { key = "equipGroupWeapons", slots = weapons, columns = 1, x = WEAPON_X }
    return out
end

local function groupRows(group)
    return math.max(1, math.ceil(#group.slots / group.columns))
end

local function buildGear(window, page)
    local groups = gearGroups()
    -- The armour/accessory stack and the weapons column are centred together,
    -- so the column does not read as a top-heavy grid with a dead strip below.
    local stackHeight, weaponHeight = 0, 0
    for _, group in ipairs(groups) do
        local block = 24 + groupRows(group) * SLOT_PITCH
        if group.columns == 1 then
            weaponHeight = block
        else
            stackHeight = stackHeight + block + 12
        end
    end
    local columnHeight = math.max(stackHeight, weaponHeight)
    local top = MAIN_TOP + math.max(0, math.floor((MAIN_H - columnHeight) / 2))
    window.slots, window.gearHeaders = {}, {}
    local y = top
    for _, group in ipairs(groups) do
        if #group.slots > 0 then
            local groupTop = group.columns == 1 and top or y
            window.gearHeaders[group.key] = sectionHeader(window, page, app.L[group.key], group.x, groupTop,
                group.columns == 1 and SLOT or GEAR_W)
            local slotTop = groupTop + 24
            for index, slotID in ipairs(group.slots) do
                local column = (index - 1) % group.columns
                local row = math.floor((index - 1) / group.columns)
                local slot = createSlot(page, slotID)
                slot:SetPoint("TOPLEFT", group.x + column * SLOT_PITCH, -(slotTop + row * SLOT_PITCH))
                slot.groupKey = group.key
                window.slots[#window.slots + 1] = slot
            end
            if group.columns ~= 1 then
                y = y + 24 + groupRows(group) * SLOT_PITCH + 12
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Zone 3: the player model
-- ---------------------------------------------------------------------------

local function buildModel(window, page)
    local stage = CreateFrame("Frame", nil, page, "BackdropTemplate")
    stage:SetPoint("TOPLEFT", MODEL_X, -MAIN_TOP)
    stage:SetSize(MODEL_W, MAIN_H)
    stage:EnableMouse(false)
    window.modelStage = stage
    window.painters[#window.painters + 1] = function() app.Surface:Plate(stage, "inset") end
    local glow = stage:CreateTexture(nil, "BACKGROUND", nil, -6)
    glow:SetPoint("CENTER", 0, 30)
    glow:SetSize(MODEL_W - 24, MAIN_H - 140)
    glow:SetTexture(app.Theme.media.glow)
    glow:SetVertexColor(1, 1, 1, 0.10)
    stage.glow = glow

    local ok, model = pcall(CreateFrame, "PlayerModel", nil, stage)
    if not ok or not model then
        -- The model is a preview; a client without PlayerModel loses the
        -- preview and nothing else.
        local fallback = app.Theme:Text(stage, 12, true)
        fallback:SetPoint("CENTER", 0, 0)
        fallback:SetWidth(MODEL_W - 40)
        fallback:SetWordWrap(true)
        fallback:SetJustifyH("CENTER")
        fallback:SetText(app.L.modelUnavailable)
        stage.fallback = fallback
        window.model = nil
        return
    end
    model:SetSize(MODEL_W - 24, MAIN_H - 96)
    model:SetPoint("CENTER", 0, 8)
    if type(model.SetUnit) == "function" then pcall(model.SetUnit, model, "player") end
    -- Drag the model to turn it, wheel over it to zoom the camera.
    model:EnableMouse(true)
    model:EnableMouseWheel(true)
    model.distance = 2.2
    -- Drag to turn: a short ticker reads the cursor while the button is held
    -- (never a permanent update loop) and stops on mouse-up, on hide, on a page
    -- switch and on disable through the same ending path.
    model:SetScript("OnMouseDown", function(self, button)
        if button ~= nil and button ~= "LeftButton" then return end
        endModelDrag(self)
        self.dragging = true
        if type(C_Timer) ~= "table" or type(C_Timer.NewTicker) ~= "function" then return end
        if self.ticker then return end
        self.ticker = C_Timer.NewTicker(0.05, function()
            if not self.dragging or type(GetCursorPosition) ~= "function" then return end
            local x = GetCursorPosition()
            if type(x) ~= "number" then return end
            local delta = x - (self.lastX or x)
            self.lastX = x
            if delta ~= 0 then
                window.modelAngle = (window.modelAngle or 0) + delta * 0.01
                if type(self.SetRotation) == "function" then
                    pcall(self.SetRotation, self, window.modelAngle)
                end
            end
        end)
    end)
    model:SetScript("OnMouseUp", function(self) endModelDrag(self) end)
    -- A closed window or a hidden model must never keep the cursor ticker.
    model:SetScript("OnHide", function(self) endModelDrag(self) end)
    model:SetScript("OnMouseWheel", function(self, delta)
        self.distance = math.max(0.8, math.min(4.5, (self.distance or 2.2) - delta * 0.25))
        if type(self.SetCameraDistance) == "function" then
            pcall(self.SetCameraDistance, self, self.distance)
        end
    end)
    window.modelAngle = 0
    -- Rotation buttons: the model turns a step per click.
    for _, spec in ipairs({ { direction = -1, key = "rotateLeft", text = "<" },
        { direction = 1, key = "rotateRight", text = ">" } }) do
        local button = app.Controls:Button(stage, spec.text, 26, function()
            window.modelAngle = (window.modelAngle or 0) + spec.direction * 0.35
            if window.model and type(window.model.SetRotation) == "function" then
                pcall(window.model.SetRotation, window.model, window.modelAngle)
            end
        end, { height = 24 })
        button:SetPoint("BOTTOM", spec.direction < 0 and -18 or 18, 12)
        window[spec.key] = button
    end
    window.model = model
end

-- ---------------------------------------------------------------------------
-- Zone 4: attributes and equipment sets
-- ---------------------------------------------------------------------------

-- The stat column is a scroll area of foldable groups. Each group owns a
-- progress value (1 open, 0 folded); the layout reads it, so a fold animates
-- the group's height and everything under it follows. With motion off the
-- transition applies the target value at once and the layout settles.
local function reflowStats(window)
    local content = window.statsContent
    if not content then return end
    local y = 0
    for _, group in ipairs(window.statOrder or {}) do
        group.header:ClearAllPoints()
        group.header:SetPoint("TOPLEFT", 0, -y)
        y = y + 24
        local progress = group.progress
        if progress == nil then progress = window.folds[group.key] and 0 or 1 end
        local height = math.floor((group.height or 0) * progress + 0.5)
        if height > 0 then
            group.frame:ClearAllPoints()
            group.frame:SetPoint("TOPLEFT", 0, -y)
            group.frame:SetHeight(math.max(1, group.height or 1))
            group.frame:Show()
            y = y + height
        else
            group.frame:Hide()
        end
        y = y + 6
    end
    if window.setsHint then
        window.setsHint:ClearAllPoints()
        window.setsHint:SetPoint("TOPLEFT", 4, -y)
        y = y + 32
    end
    if window.statsHint then
        window.statsHint:ClearAllPoints()
        window.statsHint:SetPoint("TOPLEFT", 4, -y)
        y = y + 30
    end
    local view = window.statsScroll and window.statsScroll:GetHeight() or MAIN_H
    content:SetHeight(math.max(y, view))
    if window.statsScroll then window.statsScroll:UpdateRange() end
end

local function setFold(window, group, folded)
    window.folds[group.key] = folded
    local target = folded and 0 or 1
    local from = group.progress
    if from == nil then from = folded and 1 or 0 end
    group.frame:Show()
    app.Transitions:Animate(group.header, "fold", {
        from = from, to = target, duration = 0.14, easing = "linear",
        apply = function(value)
            group.progress = value
            reflowStats(window)
        end,
    })
end

local function makeStatGroup(window, key, title)
    local content = window.statsContent
    local group = { key = key, height = 0, progress = 1 }
    group.header = app.Controls:FoldHeader(content, title, STAT_CONTENT_W, function(folded)
        setFold(window, group, folded)
    end)
    group.frame = CreateFrame("Frame", nil, content)
    group.frame:SetSize(STAT_CONTENT_W, 0)
    window.statGroups[key] = group
    window.statOrder[#window.statOrder + 1] = group
    return group
end

local function addStatRow(group, index, source)
    local row = CreateFrame("Frame", nil, group.frame)
    row:SetSize(STAT_CONTENT_W, ROW_H)
    row:SetPoint("TOPLEFT", 0, -(index - 1) * ROW_H)
    row.label = app.Theme:Text(row, 12, false)
    row.label:SetPoint("LEFT", 4, 0)
    row.label:SetText(app.L[source.key])
    row.value = app.Theme:Text(row, 12, false)
    row.value:SetPoint("RIGHT", -4, 0)
    row.value:SetJustifyH("RIGHT")
    row.value:SetText("-")
    if index % 2 == 0 then
        local shade = row:CreateTexture(nil, "BACKGROUND", nil, -8)
        shade:SetAllPoints(row)
        shade:SetColorTexture(1, 1, 1, 0.03)
    end
    local rule = row:CreateTexture(nil, "ARTWORK")
    rule:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 4, 0)
    rule:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -4, 0)
    rule:SetHeight(1)
    rule:SetColorTexture(1, 1, 1, 0.06)
    attachTip(row, app.L[source.key .. "Tip"], source.rating, source.ratingConst)
    return row
end

local function createSetRow(window, group, index)
    local row = CreateFrame("Button", nil, group.frame)
    row:SetSize(STAT_CONTENT_W, SET_ROW_H - 2)
    row:SetPoint("TOPLEFT", 0, -(index - 1) * SET_ROW_H)
    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(18, 18)
    row.icon:SetPoint("LEFT", 4, 0)
    row.icon:Hide()
    row.label = app.Theme:Text(row, 12, false)
    row.label:SetPoint("LEFT", 28, 0)
    -- Player-named sets can be long; keep the name clear of the right-hand value.
    row.label:SetWidth(STAT_CONTENT_W - 28 - 60)
    row.value = app.Theme:Text(row, 11, true)
    row.value:SetPoint("RIGHT", -4, 0)
    row.value:SetJustifyH("RIGHT")
    row.glow = row:CreateTexture(nil, "BACKGROUND", nil, -6)
    row.glow:SetAllPoints(row)
    row.glow:SetTexture(app.Theme.media.glow)
    row.glow:SetVertexColor(1, 1, 1, 0.10)
    row.glow:Hide()
    row:SetScript("OnEnter", function(self) self.glow:Show() end)
    row:SetScript("OnLeave", function(self) self.glow:Hide() end)
    -- A real operation, so it is a button with a cursor-hover wash, not a
    -- read-only line pretending to be one.
    row:SetScript("OnClick", function(self)
        equipSet(self.setID, self.setEquipped)
    end)
    return row
end

local function renderSets(window)
    local group = window.statGroups and window.statGroups.sets
    if not group then return end
    local sets = equipmentSets()
    window.setRows = window.setRows or {}
    local text, muted = app.Theme.colors.text, app.Theme.colors.muted
    local used = 0
    if #sets == 0 then
        used = 1
        local row = window.setRows[1] or createSetRow(window, group, 1)
        window.setRows[1] = row
        row.setID, row.setEquipped = nil, false
        row.icon:Hide()
        row.label:SetText(app.L.setsEmpty)
        row.label:SetTextColor(muted[1], muted[2], muted[3], 1)
        row.value:SetText("")
        row:Show()
    else
        for index, set in ipairs(sets) do
            local row = window.setRows[index] or createSetRow(window, group, index)
            window.setRows[index] = row
            used = index
            row.setID = set.id
            row.setEquipped = set.equipped
            local accent = app.Theme:Accent()
            row.label:SetText(set.name)
            if set.equipped then
                row.label:SetTextColor(accent[1], accent[2], accent[3], 1)
            else
                row.label:SetTextColor(text[1], text[2], text[3], 1)
            end
            if set.equipped then
                row.value:SetText(app.L.setEquipped)
                row.value:SetTextColor(accent[1], accent[2], accent[3], 1)
            elseif set.items and set.equippedItems then
                row.value:SetText(string.format("%d/%d", set.equippedItems, set.items))
                row.value:SetTextColor(muted[1], muted[2], muted[3], 1)
            else
                row.value:SetText("")
            end
            if set.icon then
                if type(row.icon.SetTexture) == "function" then pcall(row.icon.SetTexture, row.icon, set.icon) end
                row.icon:Show()
            else
                row.icon:Hide()
            end
            row:Show()
        end
    end
    for index = used + 1, #window.setRows do window.setRows[index]:Hide() end
    group.height = math.max(1, used) * SET_ROW_H
end

local function refreshStats(window)
    if not window then return end
    for _, paint in ipairs(window.painters or {}) do pcall(paint) end
    refreshIdentity(window)
    for _, slot in ipairs(window.slots or {}) do paintSlot(slot) end
    local accent = app.Theme:Accent()
    local muted, text = app.Theme.colors.muted, app.Theme.colors.text
    local _, primaryStat = specialization()
    for _, entry in ipairs(window.statRows or {}) do
        local source = entry.source
        local value = readValue(source.getter)
        entry.row.value:SetText(formatStat(source, value))
        entry.row.value:SetTextColor(text[1], text[2], text[3], 1)
        if source.index and primaryStat and source.index == primaryStat then
            entry.row.label:SetTextColor(accent[1], accent[2], accent[3], 1)
        else
            entry.row.label:SetTextColor(muted[1], muted[2], muted[3], 1)
        end
    end
    renderSets(window)
    reflowStats(window)
end

local function buildStats(window, page)
    -- A quiet inset panel behind the scroll area; grouping comes from the value
    -- step, not from a border around every row.
    local panel = CreateFrame("Frame", nil, page, "BackdropTemplate")
    panel:SetPoint("TOPLEFT", STATS_X - 6, -(MAIN_TOP - 6))
    panel:SetSize(STATS_W, MAIN_H + 6)
    panel:EnableMouse(false)
    window.statsPanel = panel
    window.painters[#window.painters + 1] = function() app.Surface:Plate(panel, "inset") end

    local scroll = app.Controls:Scroll(page, STAT_CONTENT_W + 2, MAIN_H)
    scroll:SetPoint("TOPLEFT", STATS_X, -MAIN_TOP)
    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(STAT_CONTENT_W, MAIN_H)
    scroll:SetScrollChild(content)
    window.statsScroll, window.statsContent = scroll, content
    window.statGroups, window.statOrder, window.statRows = {}, {}, {}

    local primary = makeStatGroup(window, "primary", app.L.statHeader)
    for index, source in ipairs(PRIMARY_SOURCES) do
        local row = addStatRow(primary, index, source)
        window.statRows[#window.statRows + 1] = { row = row, source = source }
    end
    primary.height = #PRIMARY_SOURCES * ROW_H

    local secondary = makeStatGroup(window, "secondary", app.L.statGroupSecondary)
    for index, source in ipairs(SECONDARY_SOURCES) do
        local row = addStatRow(secondary, index, source)
        window.statRows[#window.statRows + 1] = { row = row, source = source }
    end
    secondary.height = #SECONDARY_SOURCES * ROW_H

    local sets = makeStatGroup(window, "sets", app.L.statSets)
    sets.height = SET_ROW_H

    window.setsHint = app.Theme:Text(content, 11, true)
    window.setsHint:SetWidth(STAT_CONTENT_W - 8)
    window.setsHint:SetWordWrap(true)
    window.setsHint:SetText(app.L.setsHint)
    window.statsHint = app.Theme:Text(content, 11, true)
    window.statsHint:SetWidth(STAT_CONTENT_W - 8)
    window.statsHint:SetWordWrap(true)
    window.statsHint:SetText(app.L.statsHint)
    window.painters[#window.painters + 1] = function()
        local muted = app.Theme.colors.muted
        window.setsHint:SetTextColor(muted[1], muted[2], muted[3], 1)
        window.statsHint:SetTextColor(muted[1], muted[2], muted[3], 1)
    end
    reflowStats(window)
end

-- ---------------------------------------------------------------------------
-- Window chrome, open/close and dragging
-- ---------------------------------------------------------------------------

-- Dragging: the header strip is the handle, so dragging never fights with the
-- slots. Ctrl + wheel adjusts this window's relative scale and the choice is
-- stored with the profile. Layout:Apply stays the only writer of the frame
-- scale, combining appearance.scale with this window's relative one.
local function makeDraggable(window)
    window:SetMovable(true)
    window:SetClampedToScreen(true)
    local handle = CreateFrame("Frame", nil, window)
    handle:SetPoint("TOPLEFT", 0, 0)
    handle:SetPoint("TOPRIGHT", 0, 0)
    handle:SetHeight(HEADER_H)
    handle:EnableMouse(true)
    handle:EnableMouseWheel(true)
    handle:RegisterForDrag("LeftButton")
    handle:SetScript("OnDragStart", function() window:StartMoving() end)
    handle:SetScript("OnDragStop", function()
        window:StopMovingOrSizing()
        local point, _, _, x, y = window:GetPoint(1)
        if point then app.Store:SetPosition("characterWindow", x or 0, y or 0) end
    end)
    handle:SetScript("OnMouseWheel", function(_, delta)
        if type(IsControlKeyDown) == "function" and not IsControlKeyDown() then return end
        local current = app.Store:Profile().ui.windowScale or 1
        local wanted = math.max(0.8, math.min(1.3, current + (delta > 0 and 0.05 or -0.05)))
        if app.Store:Set("ui", "windowScale", wanted) then
            app.Layout:Apply("characterWindow")
        end
    end)
    window.dragHandle = handle
end

-- The preview is independent of the native character window and its binding.
local function showWindow()
    local window = component and component.window
    if not window then return end
    component.wantsOpen = true
    if not window:IsShown() then
        window:SetAlpha(0)
        window:Show()
    end
    app.Transitions:Fade(window, window, 1, 0.18, nil, "open")
end

-- Closing fades to the final state, then hides. A reopen replaces the task, so
-- the callback only runs for the last close request.
local function hideWindow()
    local window = component and component.window
    if not window or not window:IsShown() then return end
    component.wantsOpen = false
    app.Transitions:Fade(window, window, 0, 0.13, function()
        if component.wantsOpen then return end
        if component.window and component.window:IsShown() then component.window:Hide() end
    end, "open")
end

-- The explicit "game window" entry closes the preview and opens the native
-- frame if necessary. If it is already shown, do not toggle it closed.
local function openNativeWindow()
    if not component or not component.running then return false end
    component.wantsOpen = false
    local window = component.window
    if window then
        app.Transitions:Cancel(window, "open")
        window:SetAlpha(1)
        if window:IsShown() then window:Hide() end
    end
    local ok = pcall(function()
        local native = _G.CharacterFrame
        if native and type(native.IsShown) == "function" and native:IsShown() then return end
        if type(_G.ToggleCharacter) == "function" then _G.ToggleCharacter("PaperDollFrame") end
    end)
    return ok
end

local function build(window)
    window:SetSize(W, H)
    window.painters = {}
    window.painters[#window.painters + 1] = function() paintBackground(window) end
    paintBackground(window)
    window.title = app.Type:Text(window, "display")
    window.title:SetPoint("TOPLEFT", PAD, -12)
    window.title:SetText(app.L.characterWindow)
    paintHeader(window)
    local close = app.Controls:Button(window, "×", 28, function() hideWindow() end, { height = 28 })
    close:SetPoint("TOPRIGHT", -10, -8)
    -- The game's own window stays one click away: the LumaUI window implements
    -- character, reputation and currency pages only.
    local nativeEntry = app.Controls:Button(window, app.L.characterNativeEntry, 112,
        function() openNativeWindow() end, { height = 24 })
    nativeEntry:SetPoint("TOPRIGHT", -44, -10)
    window.nativeEntry = nativeEntry

    window.pages = {}
    window.folds = {}
    window.currentPage = 1
    window.listRows = math.max(6, math.floor((H - HEADER_H - TAB_H - LIST_TOP - 10) / ROW_H))
    local page = makePage(window, 1)
    page:Show()

    buildIdentity(window, page)
    buildGear(window, page)
    buildModel(window, page)
    buildStats(window, page)

    makePage(window, 2)
    makePage(window, 3)
    window.pages[2].refresh = function(self) refreshReputation(window, self) end
    window.pages[3].refresh = function(self) refreshCurrency(window, self) end
    buildListHeader(window, window.pages[2], app.L.tabReputation)
    buildListHeader(window, window.pages[3], app.L.tabCurrency)

    buildTabs(window)
    showPage(window, 1)
    makeDraggable(window)
    refreshStats(window)
    return window
end

-- Display refreshes are coalesced: while the window is hidden an event only
-- marks it dirty, and the next open repaints once. Nothing refreshes in the
-- background, and nothing here performs a gameplay action.
local function requestRefresh()
    local window = component and component.window
    if not window or not component.running then return end
    if not window:IsShown() then window.dirty = true; return end
    refreshStats(window)
end

component = app:RegisterComponent({ id = "characterWindow", label = "characterWindow", defaultEnabled = false,
    Supported = function() return type(UnitStat) == "function" end,
    Enable = function(self)
        if not self.window then
            local window = CreateFrame("Frame", "LumaUICharacterWindow", UIParent, "BackdropTemplate")
            window:Hide()
            -- The relative window scale is a property of this panel; Layout is
            -- still the only place that turns it into an actual frame scale.
            app.Layout:Register("characterWindow", window, 0, 0, app.L.characterWindow,
                function() return app.Store:Profile().ui.windowScale or 1 end)
            self.window = build(window)
            UISpecialFrames[#UISpecialFrames + 1] = "LumaUICharacterWindow"
            -- OnShow repaints once if events arrived while hidden; OnHide is the
            -- single cleanup path for Esc, the close button, the native entry
            -- and a disable.
            window:SetScript("OnShow", function()
                if not component.running then return end
                local page = window.pages and window.pages[window.currentPage]
                if page then
                    app.Transitions:Cancel(page, "page")
                    page:SetAlpha(1)
                end
                refreshStats(window)
                window.dirty = nil
            end)
            window:SetScript("OnHide", function()
                component.wantsOpen = false
                app.Transitions:Cancel(window, "open")
                window:SetAlpha(1)
                for _, page in pairs(window.pages or {}) do
                    app.Transitions:Cancel(page, "page")
                    page:SetAlpha(1)
                end
                -- A fold interrupted by closing settles at its target instead of
                -- staying half open; the next open lays the column out again.
                for key, group in pairs(window.statGroups or {}) do
                    app.Transitions:Cancel(group.header, "fold")
                    group.progress = window.folds[key] and 0 or 1
                end
                endModelDrag(window.model)
                reflowStats(window)
            end)
        end
        refreshStats(self.window)
        -- Equipment, item cache, rating and set changes repaint while open; while
        -- hidden they only mark the window dirty.
        self:Listen("PLAYER_EQUIPMENT_CHANGED", function() requestRefresh() end)
        self:Listen("PLAYER_ENTERING_WORLD", function()
            local window = component.window
            if window and window.model and type(window.model.SetUnit) == "function" then
                pcall(window.model.SetUnit, window.model, "player")
            end
            requestRefresh()
        end)
        self:Listen("ITEM_DATA_LOAD_RESULT", function() requestRefresh() end)
        self:Listen("GET_ITEM_INFO_RECEIVED", function() requestRefresh() end)
        self:Listen("COMBAT_RATING_UPDATE", function() requestRefresh() end)
        self:Listen("UNIT_STATS", function(_, _, unit)
            if unit == "player" then requestRefresh() end
        end)
        self:Listen("EQUIPMENT_SETS_CHANGED", function() requestRefresh() end)
        self:Listen("EQUIPMENT_SWAP_FINISHED", function() requestRefresh() end)
    end,
    Refresh = function(self)
        if not self.window then return end
        refreshStats(self.window)
        for index, button in ipairs(self.window.tabs or {}) do
            button:SetSelected(index == self.window.currentPage)
        end
        if self.window.statsScroll then self.window.statsScroll:UpdateRange() end
    end,
    Disable = function(self)
        local window = self.window
        if not window then return end
        self.wantsOpen = false
        endModelDrag(window.model)
        app.Transitions:Cancel(window, "open")
        for _, page in pairs(window.pages or {}) do app.Transitions:Cancel(page, "page") end
        for _, group in pairs(window.statGroups or {}) do app.Transitions:Cancel(group.header, "fold") end
        window:SetAlpha(1)
        window:Hide()
    end,
})

-- Diagnostics for `/luma status`: the native panel and binding remain intact.
function component:Describe()
    if not self.running then return nil end
    return string.format("characterWindow: %s (%s)", app.L.nativeEntryKept, app.L.characterNativeEntry)
end

-- `/luma char`: opens or closes the LumaUI character window.
function component:Toggle()
    if not self.running then app:Print(app.L.characterWindowDisabled); return end
    if self.window:IsShown() then hideWindow() else showWindow() end
end
