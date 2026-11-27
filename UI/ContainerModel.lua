local _, app = ...
local Plain = app.Capabilities.Plain
local Items = app.Items

-- Container data layer: one normalized record per physical slot, independent of
-- any window. Records carry the source (bag / bank / warband), the container id
-- and the slot, so a view can group, filter and search them without re-reading
-- the client, and an item operation always targets the physical slot.
local Model = {}
app.ContainerModel = Model

-- Display order of sections. Quest items (class 12) and quivers (class 11) are
-- different classes; Items.Category already keeps them apart.
Model.sections = { "quest", "equip", "consumable", "mat", "other" }

function Model.Key(source, bag, slot)
    return tostring(source) .. ":" .. tostring(bag) .. ":" .. tostring(slot)
end

-- Item-data backfill: a slot whose name cannot be read yet asks the client to
-- load it once; ITEM_DATA_LOAD_RESULT makes the window refresh. Ids are asked
-- for once per session so a slow load cannot turn into a request loop.
local requested = {}
function Model.Backfill(item)
    if item.link or not item.itemID or requested[item.itemID] then return false end
    local api = rawget(_G, "C_Item")
    if type(api) ~= "table" or type(api.RequestLoadItemDataByID) ~= "function" then return false end
    requested[item.itemID] = true
    pcall(api.RequestLoadItemDataByID, item.itemID)
    return true
end

-- Reads every slot of the given containers once. Empty slots are counted but
-- produce no record. `list` is { bag ids }, `source` a short tag.
function Model.Collect(source, list)
    local records, free, total = {}, 0, 0
    if type(C_Container) ~= "table" or type(C_Container.GetContainerNumSlots) ~= "function" then
        return records, free, total
    end
    for _, bag in ipairs(list or {}) do
        local okSlots, slots = pcall(C_Container.GetContainerNumSlots, bag)
        slots = okSlots and Plain(slots, "number") or 0
        local used = 0
        for slot = 1, slots do
            local item = Items.Read(bag, slot)
            if item then
                used = used + 1
                Model.Backfill(item)
                records[#records + 1] = {
                    key = Model.Key(source, bag, slot), source = source, bag = bag, slot = slot,
                    item = item, category = Items.Category(item.link),
                }
            end
        end
        total, free = total + slots, free + (slots - used)
    end
    return records, free, total
end

-- One normalized match used by every view: trimmed, lower-cased plain
-- substring over name or item id; an empty query matches everything.
function Model.Normalize(query)
    if type(query) ~= "string" then return "" end
    return (query:gsub("^%s+", ""):gsub("%s+$", ""):lower())
end

function Model.Search(records, query, category)
    query = Model.Normalize(query)
    local out = {}
    for _, record in ipairs(records) do
        if (not category or category == "all" or record.category == category)
            and (query == "" or Items.Matches(record.item, query, nil)) then
            out[#out + 1] = record
        end
    end
    return out
end

-- Group records into the fixed section order; empty sections are omitted and
-- each record appears in exactly one section.
function Model.Group(records)
    local buckets = {}
    for _, record in ipairs(records) do
        local name = record.category or "other"
        buckets[name] = buckets[name] or {}
        table.insert(buckets[name], record)
    end
    local sections = {}
    for _, name in ipairs(Model.sections) do
        if buckets[name] then sections[#sections + 1] = { id = name, items = buckets[name] } end
    end
    return sections
end

-- Bank bag ids for one bank type, resolved from the client only: purchased tab
-- ids when the API answers, else the legacy character container. Returns
-- viewable (bool or nil), usable (bool or nil), bags, empty.
function Model.BankState(kind, legacyContainer)
    local bank = rawget(_G, "C_Bank")
    local container = rawget(_G, "C_Container")
    local function probe(fn)
        if type(bank) ~= "table" or type(bank[fn]) ~= "function" then return nil end
        local ok, value = pcall(bank[fn], kind)
        if not ok then return nil end
        return Plain(value, "boolean")
    end
    local function numSlots(bag)
        if type(container) ~= "table" or type(container.GetContainerNumSlots) ~= "function" then return nil end
        local ok, slots = pcall(container.GetContainerNumSlots, bag)
        if not ok then return nil end
        return Plain(slots, "number")
    end
    local viewable, usable = probe("CanViewBank"), probe("CanUseBank")
    if viewable ~= true then return viewable, usable, nil, false end
    local bags
    if type(bank) == "table" and type(bank.FetchPurchasedBankTabIDs) == "function" then
        local ok, tabs = pcall(bank.FetchPurchasedBankTabIDs, kind)
        if ok and type(tabs) == "table" then
            bags = {}
            for _, id in ipairs(tabs) do
                local n = Plain(id, "number")
                if n and (numSlots(n) or 0) > 0 then bags[#bags + 1] = n end
            end
        end
    end
    if bags == nil and legacyContainer then
        bags = (numSlots(legacyContainer) or 0) > 0 and { legacyContainer } or {}
    end
    return viewable, usable, bags, bags ~= nil and #bags == 0
end

-- Dirty-bag merging: BAG_UPDATE fires per container; a view marks them and
-- takes the merged set once on BAG_UPDATE_DELAYED instead of rescanning each time.
function Model.NewDirty()
    return { set = {}, all = false }
end

function Model.Mark(dirty, bag)
    if bag == nil then dirty.all = true else dirty.set[bag] = true end
end

function Model.Take(dirty)
    local result = { all = dirty.all, bags = {} }
    for bag in pairs(dirty.set) do result.bags[#result.bags + 1] = bag end
    table.sort(result.bags)
    dirty.set, dirty.all = {}, false
    return result
end

-- Flat row list for a virtualized sectioned view. Each section contributes one
-- header row (carrying its total count even when collapsed) and, unless
-- collapsed, ceil(n / perRow) item rows. Every record lands in exactly one row
-- slot; a view only has to draw the rows inside its scroll window.
function Model.Rows(sections, collapsed, perRow)
    perRow = math.max(1, math.floor(tonumber(perRow) or 1))
    collapsed = collapsed or {}
    local rows = {}
    for _, section in ipairs(sections) do
        local items = section.items
        rows[#rows + 1] = { kind = "header", section = section.id, count = #items, collapsed = collapsed[section.id] == true }
        if collapsed[section.id] ~= true then
            for first = 1, #items, perRow do
                rows[#rows + 1] = { kind = "items", section = section.id, first = first, last = math.min(#items, first + perRow - 1) }
            end
        end
    end
    return rows
end

-- Rows that intersect [offset, offset + height) for fixed row heights.
function Model.Visible(rows, rowHeight, offset, height)
    local first = math.max(1, math.floor(offset / rowHeight) + 1)
    local last = math.min(#rows, math.ceil((offset + height) / rowHeight))
    return first, last
end
