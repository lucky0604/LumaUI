local _, app = ...
local L, Plain = app.L, app.Capabilities.Plain
local Items = app.Items
local PAGE_SIZE, COLUMNS = 60, 12
local module

local function sortAvailable()
    return type(C_Container) == "table" and type(C_Container.SortBags) == "function"
end

local function collect(query, category)
    local items, free, total = {}, 0, 0
    query = query:lower()
    for bag = 0, Plain(NUM_TOTAL_EQUIPPED_BAG_SLOTS, "number") or 5 do
        local okSlots, slots = pcall(C_Container.GetContainerNumSlots, bag)
        slots = okSlots and Plain(slots, "number") or 0
        local okFree, empty = pcall(C_Container.GetContainerNumFreeSlots, bag)
        empty = okFree and Plain(empty, "number") or 0
        total, free = total + slots, free + empty
        for slot = 1, slots do
            local item = Items.Read(bag, slot)
            if item and Items.Matches(item, query, category) then items[#items + 1] = item end
        end
    end
    return items, free, total
end

-- Split dialog: Ctrl+click on a stack opens a small input (1 .. stack-1) and
-- the confirmed amount goes through SplitContainerItem, queued to the end of
-- combat like every other protected action. Shift+click keeps its chat link.
local function confirmSplit()
    local dialog = module and module.split
    if not dialog or not dialog.item then return end
    local item, maximum = dialog.item, dialog.maximum
    local count = Plain(tonumber(dialog.input:GetText()), "number")
    if not count or count ~= math.floor(count) then return end
    count = math.max(1, math.min(maximum, count))
    dialog.item = nil
    dialog.input:ClearFocus()
    dialog.frame:Hide()
    app.Queue:Run("inventory/split", function()
        if type(C_Container) == "table" and type(C_Container.SplitContainerItem) == "function" then
            C_Container.SplitContainerItem(item.bag, item.slot, count)
        end
    end)
end

local function buildSplit()
    if module.split then return end
    local frame = CreateFrame("Frame", "LumaUIInventorySplit", UIParent, "BackdropTemplate")
    frame:Hide()
    frame:SetSize(240, 150)
    frame:SetFrameStrata("HIGH")
    frame:EnableMouse(true)
    frame:SetPoint("CENTER", module.frame, "CENTER")
    UISpecialFrames[#UISpecialFrames + 1] = "LumaUIInventorySplit"
    app.Surface:Plate(frame, "card")
    local title = app.Type:Text(frame, "title")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText(L.bagSplitTitle)
    local close = app.Controls:Button(frame, "×", 28, function() frame:Hide() end)
    close:SetPoint("TOPRIGHT", -12, -12)
    local range = app.Theme:Text(frame, 12, true)
    range:SetPoint("TOPLEFT", 16, -46)
    local input = app.Controls:Input(frame, 208)
    input:SetPoint("TOPLEFT", 16, -66)
    local confirm = app.Controls:Button(frame, L.bagSplitConfirm, 104, confirmSplit)
    confirm:SetPoint("BOTTOMLEFT", 16, 14)
    input:SetScript("OnEnterPressed", function() confirmSplit() end)
    input:SetScript("OnEscapePressed", function() frame:Hide() end)
    module.split = { frame = frame, input = input, range = range, confirm = confirm }
    frame:SetScript("OnHide", function()
        input:ClearFocus()
        module.split.item = nil
    end)
end

local function openSplit(item)
    local count = Plain(item and item.count, "number") or 1
    if count - 1 < 1 then return end
    if InCombatLockdown() then return end
    if not Items.Actions() or type(C_Container.SplitContainerItem) ~= "function" then return end
    buildSplit()
    local dialog = module.split
    dialog.item = { bag = item.bag, slot = item.slot }
    dialog.maximum = count - 1
    dialog.input:SetText("")
    dialog.range:SetFormattedText("1 - %d", dialog.maximum)
    dialog.frame:Show()
end

local function paintFilters(self)
    Items.PaintFilters(self)
end

local function refresh(self)
    self.dirty = true
    if not self.frame or not self.frame:IsShown() then return end
    self.dirty = false
    local items, free, total = collect(self.search:GetText(), self.filter)
    local pages = math.max(1, math.ceil(#items / PAGE_SIZE))
    self.page = math.max(1, math.min(self.page or 1, pages))
    self.pageLabel:SetFormattedText("%d / %d", self.page, pages)
    self.summary:SetFormattedText(L.slots, free, total)
    -- Empty state names the cause: no containers at all, no slots, or a filter
    -- that matched nothing. The wording never claims more than was probed.
    local emptyText = #items == 0 and total == 0 and L.noContainers or L.empty
    self.empty:SetText(emptyText)
    self.empty:SetShown(#items == 0)
    -- Sorting is a bag action, so it follows the client capability on every
    -- redraw rather than whatever was true when the window first opened.
    self.canSort = sortAvailable()
    self.sort:SetShown(self.canSort)
    for i, button in ipairs(self.buttons) do
        Items.Paint(button, items[(self.page - 1) * PAGE_SIZE + i])
    end
end

local function redraw(self)
    refresh(self)
end

local function build(self)
    local frame = CreateFrame("Frame", "LumaUIInventory", UIParent, "BackdropTemplate")
    self.frame, self.buttons, self.page = frame, {}, 1
    frame:Hide()
    frame:SetSize(564, 452)
    frame:SetFrameStrata("HIGH")
    frame:EnableMouse(true)
    frame:SetClampedToScreen(true)
    UISpecialFrames[#UISpecialFrames + 1] = "LumaUIInventory"
    local title = app.Type:Text(frame, "display")
    title:SetPoint("TOPLEFT", 20, -18)
    title:SetText(L.bagTitle)
    local close = app.Controls:Button(frame, "×", 28, function() frame:Hide() end)
    close:SetPoint("TOPRIGHT", -12, -12)
    Items.Search(frame, self, 518, 26, -60, function() refresh(self) end)
    Items.FilterRow(frame, self, 22, -94, function() refresh(self) end)
    self.empty = app.Theme:Text(frame, 14, true)
    self.empty:SetPoint("CENTER")
    self.empty:SetText(L.empty)
    for i = 1, PAGE_SIZE do
        local button = Items.Cell(frame)
        self.buttons[i] = button
        button:SetPoint("TOPLEFT", 22 + ((i - 1) % COLUMNS) * 44, -130 - math.floor((i - 1) / COLUMNS) * 44)
        button:RegisterForDrag("LeftButton")
        -- Native bag semantics: left click picks up, right click uses, modified
        -- click inserts a chat link, Ctrl+click splits a stack. These are user
        -- clicks, not automated actions.
        button:SetScript("OnClick", function(self2, mouseButton)
            local item = self2.item
            if not item then return end
            if IsModifiedClick and IsModifiedClick("CHATLINK") then Items.Link(item); return end
            if mouseButton == "LeftButton" and IsControlKeyDown and IsControlKeyDown() then openSplit(item); return end
            if mouseButton == "RightButton" then Items.Use(item) else Items.Pickup(item) end
        end)
        button:SetScript("OnDragStart", function(self2) Items.Pickup(self2.item) end)
        button:SetScript("OnReceiveDrag", function(self2) Items.Pickup(self2.item) end)
    end
    Items.Pager(frame, self, { "BOTTOMLEFT", 22, 58 }, 62, function() redraw(self) end)
    self.summary = app.Theme:Text(frame, 12, true)
    self.summary:SetPoint("BOTTOMRIGHT", -22, 88)
    self.sort = app.Controls:Button(frame, L.sortBags, 92, function()
        if not self.canSort then app:Print(L.itemActionsUnavailable); return end
        C_Container.SortBags()
        refresh(self)
    end)
    self.sort:SetPoint("BOTTOMRIGHT", -22, 48)
    local hint = app.Theme:Text(frame, 11, true)
    hint:SetPoint("BOTTOMLEFT", 22, 25)
    hint:SetPoint("BOTTOMRIGHT", -22, 25)
    hint:SetJustifyH("LEFT")
    hint:SetText(L.bagHint)
    -- Only the window container animates in; the 60 cells are plain children
    -- and never get a per-item fade, so a large grid opens in one step.
    frame:SetScript("OnShow", function() refresh(self); app.Transitions:Reveal(frame) end)
    app.Layout:Register("inventory", frame, UIParent:GetWidth() / 2 - 310, -45, L.inventory)
end

module = app:RegisterComponent({ id = "inventory", label = "inventory",
    Supported = function(_, caps) return caps.containers end,
    Enable = function(self)
        if not self.frame then build(self) end
        self:Listen("BAG_UPDATE_DELAYED", refresh)
        self:Listen("ITEM_DATA_LOAD_RESULT", refresh)
    end,
    Refresh = function(self)
        app.Surface:Plate(self.frame, "card")
        paintFilters(self)
        refresh(self)
    end,
    Disable = function(self)
        if self.frame then
            -- A reveal still in flight is settled before hiding, so the window
            -- never comes back at a half faded alpha.
            app.Transitions:Settle(self.frame)
            self.frame:Hide()
        end
    end,
})

function module:Toggle()
    if not self.running then app:Print(L.inventoryDisabled); return end
    self.frame:SetShown(not self.frame:IsShown())
end

-- Diagnostics: what the browser can actually do on this build, not what it
-- intended to do. The slot count is read the same way the browser reads it.
function module:Describe()
    if not self.running then return nil end
    local caps = app.Capabilities.Snapshot()
    local action = caps.containerActions and L.diagActionsOn or L.diagActionsOff
    local sort = caps.containerSort and L.diagSortOn or L.diagSortOff
    local total = 0
    for bag = 0, Plain(NUM_TOTAL_EQUIPPED_BAG_SLOTS, "number") or 5 do
        local ok, slots = pcall(C_Container.GetContainerNumSlots, bag)
        total = total + (ok and Plain(slots, "number") or 0)
    end
    return string.format("inventory: %s · %s · %d %s", action, sort, total, L.diagSlots)
end
