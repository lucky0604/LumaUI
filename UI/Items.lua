local _, app = ...
local L, Plain = app.L, app.Capabilities.Plain
-- Shared item browser layer for the bags and the bank: one normalized read of a
-- container slot, one cell paint, one set of user-click actions and one filter
-- row. Both windows build their own frames and paging around these, so search,
-- categories, quality, lock and junk semantics cannot drift apart again.
local Items = {}
app.Items = Items

-- Retail item class ids -> browser filter categories. Anything else, including
-- items whose class id cannot be read yet, counts as "other".
local CLASS_CATEGORY = {
    [2] = "equip", [4] = "equip", [0] = "consumable",
    [5] = "mat", [7] = "mat", [11] = "quest",
}
local classCache = {}

function Items.Class(link)
    if not link or type(C_Item) ~= "table" or type(C_Item.GetItemInfoInstant) ~= "function" then return nil end
    local id = Plain(tonumber(link:match("item:(%d+)")), "number")
    if not id then return nil end
    local cached = classCache[id]
    if cached ~= nil then return cached end
    -- GetItemInfoInstant returns (name, link, quality, itemLevel, reqLevel,
    -- classID, ...): the sixth value is the class id on Retail.
    local ok, _, _, _, _, _, classID = pcall(C_Item.GetItemInfoInstant, link)
    classID = ok and Plain(classID, "number") or nil
    if classID ~= nil then classCache[id] = classID end
    return classID
end

function Items.Category(link)
    local classID = Items.Class(link)
    if classID == nil then return "other" end
    return CLASS_CATEGORY[classID] or "other"
end

-- One container slot, plain values only. Every field is read through Plain so
-- a restricted value can never reach arithmetic, comparison or text.
function Items.Read(bag, slot)
    if type(C_Container) ~= "table" or type(C_Container.GetContainerItemInfo) ~= "function" then return nil end
    local ok, info = pcall(C_Container.GetContainerItemInfo, bag, slot)
    if not ok or type(info) ~= "table" then return nil end
    local link = Plain(info.hyperlink, "string")
    local id = Plain(info.itemID, "number")
    local name = Plain(info.itemName, "string")
    if not name and link then name = link:match("%[(.-)%]") end
    return {
        bag = bag, slot = slot, link = link, itemID = id,
        name = name or tostring(id or ""),
        texture = Plain(info.iconFileID, "number"),
        count = Plain(info.stackCount, "number") or 1,
        quality = Plain(info.quality, "number"),
        locked = app.Capabilities.IsSecret(info.isLocked) or Plain(info.isLocked, "boolean") == true,
        junk = Plain(info.hasNoValue, "boolean") == true,
    }
end

function Items.Matches(item, query, category)
    if category and category ~= "all" and Items.Category(item.link) ~= category then return false end
    if not query or query == "" then return true end
    if item.name:lower():find(query, 1, true) then return true end
    return item.itemID ~= nil and tostring(item.itemID):find(query, 1, true) ~= nil
end

function Items.Actions()
    return type(C_Container) == "table"
        and type(C_Container.PickupContainerItem) == "function"
        and type(C_Container.UseContainerItem) == "function"
end

function Items.Link(item)
    if not item or not item.link then return end
    local util = rawget(_G, "ChatFrameUtil")
    if util and type(util.InsertLink) == "function" then
        util.InsertLink(item.link)
        return
    end
    if type(ChatEdit_InsertLink) == "function" and ChatEdit_InsertLink(item.link) then return end
    if type(ChatFrame_OpenChat) == "function" then ChatFrame_OpenChat(item.link) end
end

-- User clicks, never automated actions. A locked slot and a window whose
-- permissions forbid changes refuse before the client call; missing container
-- functions degrade to a message instead of an error.
function Items.Pickup(item)
    if not item then return end
    if item.blocked then app:Print(item.blocked); return end
    if item.locked then app:Print(L.itemLocked); return end
    if not Items.Actions() then app:Print(L.itemActionsUnavailable); return end
    C_Container.PickupContainerItem(item.bag, item.slot)
end

function Items.Use(item)
    if not item then return end
    if item.blocked then app:Print(item.blocked); return end
    if item.locked then app:Print(L.itemLocked); return end
    if not Items.Actions() then app:Print(L.itemActionsUnavailable); return end
    C_Container.UseContainerItem(item.bag, item.slot)
end

-- The cursor carries an item: the client's own answer, never a guess.
function Items.CursorHasItem()
    if type(GetCursorInfo) ~= "function" then return false end
    local ok, kind = pcall(GetCursorInfo)
    return ok and Plain(kind, "string") == "item"
end

-- Dropping on the window itself (not on a cell) puts the cursor item into the
-- first empty slot of the given containers. The client refuses what a container
-- cannot hold, so a reagent-only bag simply is skipped by its own answer.
function Items.DropFirstFree(bags)
    if not Items.CursorHasItem() then return false end
    if not Items.Actions() then app:Print(L.itemActionsUnavailable); return false end
    for _, bag in ipairs(bags or {}) do
        local ok, slots = pcall(C_Container.GetContainerNumSlots, bag)
        slots = ok and Plain(slots, "number") or 0
        for slot = 1, slots do
            if not Items.Read(bag, slot) then
                C_Container.PickupContainerItem(bag, slot)
                return true
            end
        end
    end
    app:Print(L.bagFull)
    return false
end

-- Equipped-bag slots (bag bar): click with an item on the cursor puts it in
-- that slot, otherwise picks the bag up. Hidden when the client lacks the calls.
function Items.BagSlotsAvailable()
    return type(C_Container) == "table" and type(C_Container.ContainerIDToInventoryID) == "function"
        and type(PutItemInBag) == "function" and type(PickupBagFromSlot) == "function"
        and type(GetInventoryItemTexture) == "function"
end

function Items.BagSlotRow(frame, x, y)
    local row = { buttons = {} }
    local count = (Plain(NUM_BAG_SLOTS, "number") or 4) + 1
    for index = 1, count do
        local button = Items.Cell(frame)
        button:SetSize(30, 30)
        button:SetPoint("BOTTOMLEFT", x + (index - 1) * 34, y)
        button.bagID = index
        local function swap(self)
            if InCombatLockdown() then app:Print(L.bagSwapCombat); return end
            local ok, inventoryID = pcall(C_Container.ContainerIDToInventoryID, self.bagID)
            inventoryID = ok and Plain(inventoryID, "number") or nil
            if not inventoryID then return end
            if Items.CursorHasItem() then PutItemInBag(inventoryID) else PickupBagFromSlot(inventoryID) end
        end
        button:SetScript("OnClick", swap)
        button:SetScript("OnReceiveDrag", swap)
        row.buttons[index] = button
    end
    function row:Refresh()
        local available = Items.BagSlotsAvailable()
        for _, button in ipairs(self.buttons) do
            button:SetShown(available)
            if available then
                local ok, inventoryID = pcall(C_Container.ContainerIDToInventoryID, button.bagID)
                inventoryID = ok and Plain(inventoryID, "number") or nil
                local texture = inventoryID and select(2, pcall(GetInventoryItemTexture, "player", inventoryID)) or nil
                button.icon:SetTexture(Plain(texture, "number") or Plain(texture, "string"))
                button.icon:SetShown(texture ~= nil)
            end
        end
    end
    return row
end

-- A 40x40 cell with its icon, stack count, lock dimming and junk mark. The
-- modules attach their own click and drag scripts; the cell only owns hover.
function Items.Cell(parent)
    local button = CreateFrame("Button", nil, parent, "BackdropTemplate")
    button:SetSize(40, 40)
    button:RegisterForClicks("AnyUp")
    button.icon = button:CreateTexture(nil, "ARTWORK")
    button.icon:SetPoint("TOPLEFT", 2, -2)
    button.icon:SetPoint("BOTTOMRIGHT", -2, 2)
    button.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    button.count = app.Type:Text(button, "body")
    button.count:SetFont(app.Type:Face(), 11, "OUTLINE")
    button.count:SetPoint("BOTTOMRIGHT", -2, 2)
    button.border = CreateFrame("Frame", nil, button, "BackdropTemplate")
    button.border:SetAllPoints(button)
    button.border:EnableMouse(false)
    button.border:Hide()
    button.hover = button:CreateTexture(nil, "HIGHLIGHT")
    button.hover:SetAllPoints(button)
    -- Junk (no vendor value) keeps its native meaning: a small gold mark, not
    -- a recoloured cell, so quality colours stay readable.
    button.junk = button:CreateTexture(nil, "OVERLAY")
    button.junk:SetSize(6, 6)
    button.junk:SetPoint("BOTTOMLEFT", 3, 3)
    button.junk:SetColorTexture(0.95, 0.8, 0.42, 0.9)
    button.junk:Hide()
    -- The sweep belongs to the cell and is hidden with it, so an emptied slot
    -- never keeps the previous item's cooldown running.
    button.cooldown = CreateFrame("Cooldown", nil, button, "CooldownFrameTemplate")
    button.cooldown:SetAllPoints(button.icon)
    if type(button.cooldown.SetDrawEdge) == "function" then
        button.cooldown:SetDrawEdge(false)
    end
    button.cooldown:Hide()
    button:SetScript("OnEnter", function()
        if not button.item then return end
        GameTooltip:SetOwner(button, "ANCHOR_RIGHT")
        GameTooltip:SetBagItem(button.item.bag, button.item.slot)
        GameTooltip:Show()
    end)
    button:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return button
end

-- Container cooldown, read straight from the client. Values are only passed on
-- to the cooldown frame when both are plain numbers; a restricted value leaves
-- the cell without a sweep rather than guessing.
function Items.Cooldown(item)
    if not item then return nil end
    local api = _G.C_Container
    if type(api) ~= "table" or type(api.GetContainerItemCooldown) ~= "function" then return nil end
    local ok, start, duration = pcall(api.GetContainerItemCooldown, item.bag, item.slot)
    if not ok then return nil end
    start, duration = Plain(start, "number"), Plain(duration, "number")
    if not start or not duration or duration <= 0 then return nil end
    return start, duration
end

-- Removes every layer this module added to a cell and hides it. Used for an
-- empty slot and for a paint that failed halfway: a cell either shows a whole
-- item or nothing, never a stale icon with a new border.
function Items.Clear(button)
    button.item = nil
    button:SetShown(false)
    if button.junk then button.junk:Hide() end
    if button.border then button.border:Hide() end
    if button.cooldown then button.cooldown:Hide() end
    if button.count then button.count:SetText("") end
    if button.icon then
        if type(button.icon.SetDesaturated) == "function" then button.icon:SetDesaturated(false) end
        button.icon:SetAlpha(1)
    end
end

function Items.Paint(button, item)
    if not item then
        Items.Clear(button)
        return
    end
    local painted = pcall(function()
        button.icon:SetTexture(item.texture or 134400)
        button.icon:SetDesaturated(item.locked == true)
        button.icon:SetAlpha(item.locked and 0.55 or 1)
        button.count:SetText(item.count > 1 and item.count or "")
        app.Theme:PaintSurface(button, "embedded")
        local accent = app.Theme:Accent()
        button.hover:SetColorTexture(accent[1], accent[2], accent[3], 0.12)
        local quality = Plain(item.quality, "number")
        local red, green, blue = app.Theme:QualityColor(quality)
        if red and quality ~= 1 then
            button.border:SetBackdrop({ edgeFile = app.Theme.white, edgeSize = app.Pixel:Pixels(1, button.border) })
            button.border:SetBackdropBorderColor(red, green, blue, 1)
            button.border:Show()
        else
            button.border:Hide()
        end
        button.junk:SetShown(item.junk == true and item.locked ~= true)
        local start, duration = Items.Cooldown(item)
        if start and duration and type(button.cooldown.SetCooldown) == "function" then
            button.cooldown:SetCooldown(start, duration)
            button.cooldown:Show()
        else
            button.cooldown:Hide()
        end
    end)
    if not painted then
        Items.Clear(button)
        app:Report("items/paint", "cell")
        return
    end
    button.item = item
    button:SetShown(true)
end

-- Search field with its placeholder and the same focus behaviour in both
-- windows. `onChange` runs after the page resets to one.
function Items.Search(frame, state, width, x, y, onChange)
    local input = app.Controls:Input(frame, width)
    input:SetPoint("TOPLEFT", x, y)
    local hint = app.Theme:Text(frame, 12, true)
    hint:SetPoint("LEFT", input, "LEFT", 4, 0)
    hint:SetText(L.search)
    input:HookScript("OnTextChanged", function()
        state.page = 1
        if onChange then onChange() end
    end)
    input:HookScript("OnEditFocusGained", function() hint:Hide() end)
    input:HookScript("OnEditFocusLost", function() hint:SetShown(input:GetText() == "") end)
    state.search, state.searchHint = input, hint
    return input
end

-- Page controls: `<  n / m  >` anchored at `point` (a table of point, x, y).
-- The page number is clamped by the module's redraw before it reaches the
-- label, so the controls only move the page and ask for a repaint.
function Items.Pager(frame, state, point, gap, redraw)
    local previous = app.Controls:Button(frame, "<", 36, function()
        state.page = math.max(1, (state.page or 1) - 1)
        redraw()
    end)
    previous:SetPoint(point[1], point[2], point[3])
    local following = app.Controls:Button(frame, ">", 36, function()
        state.page = (state.page or 1) + 1
        redraw()
    end)
    following:SetPoint("LEFT", previous, "RIGHT", gap or 62, 0)
    local label = app.Theme:Text(frame, 12)
    label:SetPoint("LEFT", previous, "RIGHT", 10, 0)
    state.previous, state.next, state.pageLabel = previous, following, label
    return previous, following
end

local FILTERS = {
    { key = "all", label = "bagFilterAll", width = 40 },
    { key = "equip", label = "bagFilterEquip", width = 76 },
    { key = "consumable", label = "bagFilterConsumable", width = 92 },
    { key = "mat", label = "bagFilterMat", width = 76 },
    { key = "quest", label = "bagFilterQuest", width = 52 },
    { key = "other", label = "bagFilterOther", width = 52 },
}

function Items.PaintFilters(state)
    for _, chip in ipairs(state.filters or {}) do
        -- The shared control resolves selected/hover/disabled itself; the chip
        -- only supplies which filter is active.
        chip:SetSelected(chip.key == state.filter)
    end
end

-- The same six chips under both windows. `onChange` runs after the filter and
-- page reset, so each window only decides how to redraw its grid.
function Items.FilterRow(frame, state, x, y, onChange)
    state.filters = state.filters or {}
    for _, spec in ipairs(FILTERS) do
        local chip = app.Controls:Button(frame, L[spec.label], spec.width, function()
            state.filter = spec.key
            state.page = 1
            Items.PaintFilters(state)
            if onChange then onChange() end
        end, { mutedWhenIdle = true, height = 22 })
        chip.key = spec.key
        chip:SetPoint("TOPLEFT", x, y)
        state.filters[#state.filters + 1] = chip
        x = x + spec.width + 6
    end
    state.filter = state.filter or "all"
    Items.PaintFilters(state)
    return x
end
