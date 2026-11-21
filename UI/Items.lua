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
        locked = info.isLocked == true,
        junk = info.hasNoValue == true,
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
    button.count = app.Theme:Text(button, 11)
    button.count:SetPoint("BOTTOMRIGHT", -2, 2)
    -- Junk (no vendor value) keeps its native meaning: a small gold mark, not
    -- a recoloured cell, so quality colours stay readable.
    button.junk = button:CreateTexture(nil, "OVERLAY")
    button.junk:SetSize(6, 6)
    button.junk:SetPoint("BOTTOMLEFT", 3, 3)
    button.junk:SetColorTexture(0.95, 0.8, 0.42, 0.9)
    button.junk:Hide()
    button:SetScript("OnEnter", function()
        if not button.item then return end
        GameTooltip:SetOwner(button, "ANCHOR_RIGHT")
        GameTooltip:SetBagItem(button.item.bag, button.item.slot)
        GameTooltip:Show()
    end)
    button:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return button
end

function Items.Paint(button, item)
    button.item = item
    button:SetShown(item ~= nil)
    if not item then
        if button.junk then button.junk:Hide() end
        return
    end
    button.icon:SetTexture(item.texture or 134400)
    button.icon:SetDesaturated(item.locked == true)
    button.icon:SetAlpha(item.locked and 0.55 or 1)
    button.count:SetText(item.count > 1 and item.count or "")
    app.Theme:Panel(button, true)
    local red, green, blue = app.Theme:QualityColor(item.quality)
    if red then button:SetBackdropBorderColor(red, green, blue, 1) end
    button.junk:SetShown(item.junk == true and item.locked ~= true)
end

-- Search field with its placeholder and the same focus behaviour in both
-- windows. `onChange` runs after the page resets to one.
function Items.Search(frame, state, width, x, y, onChange)
    local input = app.Controls:Input(frame, width)
    input:SetPoint("TOPLEFT", x, y)
    local hint = app.Theme:Text(frame, 12, true)
    hint:SetPoint("LEFT", input, "LEFT", 4, 0)
    hint:SetText(L.search)
    input:SetScript("OnTextChanged", function()
        state.page = 1
        if onChange then onChange() end
    end)
    input:SetScript("OnEditFocusGained", function() hint:Hide() end)
    input:SetScript("OnEditFocusLost", function() hint:SetShown(input:GetText() == "") end)
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
