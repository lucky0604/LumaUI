local _, app = ...
local L, Plain = app.L, app.Capabilities.Plain
local Items = app.Items
local PAGE_SIZE, COLUMNS = 60, 12
-- The component spec is registered at the bottom of this file, and the
-- container-takeover methods are defined before it: they are collected here and
-- copied onto the spec right after registration.
local methods = {}
local module = methods

-- Another bag addon that is loaded owns the client's container entry points;
-- LumaUI then keeps out of the way instead of wrapping them a second time.
local BAG_ADDONS = { "Bagnon", "AdiBags", "ArkInventory", "Baganator", "Combuctor", "BetterBags", "ElvUI" }
local function otherBagAddon()
    local api = rawget(_G, "C_AddOns")
    local loaded = type(api) == "table" and api.IsAddOnLoaded
    if type(loaded) ~= "function" then return nil end
    for _, name in ipairs(BAG_ADDONS) do
        local ok, value = pcall(loaded, name)
        if ok and value then return name end
    end
end

local function bagIDs()
    local list = {}
    for bag = 0, Plain(NUM_TOTAL_EQUIPPED_BAG_SLOTS, "number") or 5 do list[#list + 1] = bag end
    return list
end

local function sortAvailable()
    return type(C_Container) == "table" and type(C_Container.SortBags) == "function"
end

-- The bag window shows the bags plus any bank this character can view: one
-- source row under the title switches between them. A bank source keeps the
-- bank's permission rules — an unknown permission is read-only — and the bag
-- source stays available as the way back.
local SOURCE_SPECS = {
    { id = "bag", label = "bagSourceBags", width = 56 },
    { id = "character", label = "bankSourceCharacter", width = 92 },
    { id = "account", label = "bankSourceAccount", width = 92 },
}

local function bankKindOf(source)
    local enums = rawget(_G, "Enum")
    local bank = type(enums) == "table" and enums.BankType or nil
    if type(bank) ~= "table" then return nil end
    if source == "character" then return Plain(bank.Character, "number") end
    if source == "account" then return Plain(bank.Account, "number") end
    return nil
end

-- One probe pass per redraw: the bag source is always viewable; each bank
-- source is the client's own answer about view, permission and tab bags.
local function probeSources()
    local states = {
        bag = { source = "bag", viewable = true, usable = true, bags = bagIDs(), empty = false },
    }
    for _, spec in ipairs(SOURCE_SPECS) do
        if spec.id ~= "bag" then
            local kind = bankKindOf(spec.id)
            local legacy = spec.id == "character" and Plain(rawget(_G, "BANK_CONTAINER"), "number") or nil
            local viewable, usable, bags, empty
            if kind ~= nil then
                viewable, usable, bags, empty = app.ContainerModel.BankState(kind, legacy)
            end
            states[spec.id] = {
                source = spec.id, kind = kind,
                viewable = viewable == true,
                usable = usable,
                bags = viewable == true and bags or nil,
                empty = empty == true,
            }
        end
    end
    return states
end

-- Slots are read once through the shared container model; search and category
-- filtering use its normalized match, so each physical slot appears once. A
-- bank source is read-only unless the client confirmed the permission.
local function collect(state, query, category)
    local source = (state and state.source) or "bag"
    local records, free, total = app.ContainerModel.Collect(source, (state and state.bags) or {})
    if source ~= "bag" and (not state or state.usable ~= true) then
        for _, record in ipairs(records) do
            record.item.blocked = L.bankBlocked
        end
    end
    local found = app.ContainerModel.Search(records, query, category)
    local items = {}
    for _, record in ipairs(found) do
        items[#items + 1] = record.item
    end
    return items, free, total, found
end

-- The source chips share the row with the search field and the sort button:
-- chips repack from the left edge, the search box takes whatever width the
-- chips and the sort button leave, so one row always fits the window.
local function layoutSources(self, states)
    if not self.sources or not self.search then return end
    local source = self.source or "bag"
    local x = 22
    for _, spec in ipairs(SOURCE_SPECS) do
        local chip = self.sources[spec.id]
        local state = states[spec.id]
        local visible
        if spec.id == "bag" then
            local anyBank = false
            for _, other in ipairs(SOURCE_SPECS) do
                if other.id ~= "bag" and states[other.id] and states[other.id].viewable then anyBank = true end
            end
            visible = anyBank or source ~= "bag"
        else
            -- The selected bank stays labelled even while the client withholds
            -- it, so the window never shows foreign content under the old name.
            visible = state ~= nil and (state.viewable == true or source == spec.id)
        end
        chip:ClearAllPoints()
        chip:SetShown(visible == true)
        chip:SetSelected(source == spec.id)
        if visible then
            chip:SetPoint("TOPLEFT", x, -50)
            x = x + spec.width + 6
        end
    end
    local searchX = x > 22 and (x + 2) or 22
    local right = self.canSort and 450 or 542
    self.search:ClearAllPoints()
    self.search:SetPoint("TOPLEFT", searchX, -50)
    self.search:SetSize(right - searchX - (self.canSort and 8 or 0), 28)
end

-- Dropping on the window, not on a cell, uses the first empty slot of the
-- active source. A bank the character cannot use refuses the drop.
local function dropHere(self)
    if self.closing then return end
    if not Items.CursorHasItem() then return end
    local source = self.source or "bag"
    if source == "bag" then
        Items.DropFirstFree(bagIDs())
        return
    end
    local state = probeSources()[source]
    if not state or state.viewable ~= true then app:Print(L.bankClosed); return end
    if state.usable ~= true then app:Print(L.bankBlocked); return end
    Items.DropFirstFree(state.bags or {})
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
            -- The slot may have changed while the amount was typed or the
            -- player was in combat; the physical slot is re-checked before the
            -- split so the wrong stack is never cut.
            if not Items.Verify(item) then app:Print(L.itemStale); return end
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
    if not item then return end
    if not Items.Verify(item) then app:Print(L.itemStale); return end
    if item.blocked then app:Print(item.blocked); return end
    if item.locked then app:Print(L.itemLocked); return end
    local count = Plain(item.count, "number") or 1
    if count - 1 < 1 then return end
    if InCombatLockdown() then return end
    if not Items.Actions() or type(C_Container.SplitContainerItem) ~= "function" then return end
    buildSplit()
    local dialog = module.split
    -- The full record is kept so the queued action can re-check the slot; the
    -- confirmation re-verifies against the physical container before splitting.
    dialog.item = item
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
    self.sourceStates = probeSources()
    local state = self.sourceStates[self.source or "bag"]
    local items, free, total, found = collect(state, self.search:GetText(), self.filter)
    local pages = math.max(1, math.ceil(#items / PAGE_SIZE))
    self.page = math.max(1, math.min(self.page or 1, pages))
    self.pageLabel:SetFormattedText("%d / %d", self.page, pages)
    self.summary:SetFormattedText(L.slots, free, total)
    -- Empty state names the cause: no containers at all, no slots, a filter
    -- that matched nothing, a bank that cannot be viewed right now, or a bank
    -- without any tab. The wording never claims more than was probed.
    local emptyText = L.empty
    if state and state.source ~= "bag" then
        if state.viewable ~= true then emptyText = L.bankClosed
        elseif state.empty == true then emptyText = L.bankNoTabs end
    elseif total == 0 then
        emptyText = L.noContainers
    end
    self.empty:SetText(emptyText)
    self.empty:SetShown(#items == 0)
    -- Sorting follows the active source's permission and the client capability
    -- on every redraw rather than whatever was true when the window opened.
    if state and state.source ~= "bag" then
        self.canSort = state.viewable == true and state.usable == true
            and type(C_Container) == "table" and type(C_Container.SortBank) == "function"
    else
        self.canSort = sortAvailable()
    end
    layoutSources(self, self.sourceStates)
    if self.wallet then
        local money = type(GetMoney) == "function" and Plain(GetMoney(), "number") or nil
        self.wallet:SetShown(app.WalletPanel ~= nil)
        local label = money and type(GetMoneyString) == "function" and GetMoneyString(money) or L.walletTitle
        local pinned = app.Ledger and app.Ledger:PinnedText() or ""
        self.wallet.text:SetText(pinned ~= "" and (label .. "  " .. pinned) or label)
    end
    if self.bagRow then self.bagRow:Refresh() end
    self.sort:SetShown(self.canSort)
    for i, button in ipairs(self.buttons) do
        Items.Paint(button, items[(self.page - 1) * PAGE_SIZE + i])
        if self.sectioned then button:Hide() end
    end
    if self.sectionView then
        self.sectionView:SetShown(self.sectioned == true)
        if self.sectioned then
            self.sectionView:Set(found, app.Store:Profile().ui.containerCollapsed)
        end
    end
end

function methods:SetSectioned(on)
    self.sectioned = on == true
    if self.sectioned and self.frame and not self.sectionView then
        local view = app.ContainerView:Create(self.frame, 500, 270, function(button, mouse)
            local item = button.item
            if not item or self.closing then return end
            if IsModifiedClick and IsModifiedClick("CHATLINK") then Items.Link(item); return end
            if mouse == "RightButton" then Items.Use(item) else Items.Pickup(item) end
        end)
        view.scroll:SetPoint("TOPLEFT", 22, -130)
        view.onToggle = function(section)
            local collapsed = {}
            for k, v in pairs(app.Store:Profile().ui.containerCollapsed or {}) do collapsed[k] = v end
            collapsed[section] = (not collapsed[section]) or nil
            app.Store:Set("ui", "containerCollapsed", collapsed)
            refresh(self)
        end
        self.sectionView = view
    end
    refresh(self)
end

local function redraw(self)
    refresh(self)
end

local function build(self)
    local frame = CreateFrame("Frame", "LumaUIInventory", UIParent, "BackdropTemplate")
    self.frame, self.buttons, self.page, self.source = frame, {}, 1, "bag"
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
    Items.Search(frame, self, 520, 22, -50, function() refresh(self) end)
    -- Source chips: the bags plus every bank the client lets this character
    -- view. Clicking one re-collects from that source's physical containers.
    self.sources = {}
    local sourceX = 22
    for _, spec in ipairs(SOURCE_SPECS) do
        local chip = app.Controls:Button(frame, L[spec.label], spec.width, function()
            self.source = spec.id
            self.page = 1
            refresh(self)
        end, { mutedWhenIdle = true, height = 22 })
        chip.source = spec.id
        chip:SetPoint("TOPLEFT", sourceX, -50)
        sourceX = sourceX + spec.width + 6
        self.sources[spec.id] = chip
    end
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
            if not item or self.closing then return end
            if IsModifiedClick and IsModifiedClick("CHATLINK") then Items.Link(item); return end
            if mouseButton == "LeftButton" and IsControlKeyDown and IsControlKeyDown() then openSplit(item); return end
            if mouseButton == "RightButton" then Items.Use(item) else Items.Pickup(item) end
        end)
        button:SetScript("OnDragStart", function(self2) if not self.closing then Items.Pickup(self2.item) end end)
        button:SetScript("OnReceiveDrag", function(self2) if not self.closing then Items.Pickup(self2.item) end end)
    end
    -- Dropping on the window, not on a cell, uses the first empty slot of the
    -- active source; the source's permission is re-probed per drop.
    frame:SetScript("OnReceiveDrag", function() dropHere(self) end)
    frame:SetScript("OnMouseUp", function() dropHere(self) end)
    self.bagRow = Items.BagSlotRow(frame, 22, 84)
    Items.Pager(frame, self, { "BOTTOMLEFT", 22, 58 }, 62, function() redraw(self) end)
    self.summary = app.Theme:Text(frame, 12, true)
    self.summary:SetPoint("BOTTOMRIGHT", -22, 88)
    self.sort = app.Controls:Button(frame, L.sortBags, 92, function()
        if not self.canSort then app:Print(L.itemActionsUnavailable); return end
        local state = self.sourceStates and self.sourceStates[self.source or "bag"]
        if not state or state.source == "bag" then
            C_Container.SortBags()
        else
            pcall(C_Container.SortBank, state.kind)
        end
        refresh(self)
    end)
    self.sort:SetPoint("TOPRIGHT", -22, -50)
    -- Footer wallet: live carried gold; clicking opens the ledger. Read-only.
    self.wallet = app.Controls:Button(frame, "", 150, function()
        if app.WalletPanel then app.WalletPanel:Toggle() end
    end)
    self.wallet:SetPoint("BOTTOMRIGHT", -22, 48)
    local hint = app.Theme:Text(frame, 11, true)
    hint:SetPoint("BOTTOMLEFT", 22, 25)
    hint:SetPoint("BOTTOMRIGHT", -22, 25)
    hint:SetJustifyH("LEFT")
    hint:SetText(L.bagHint)
    -- Only the window container animates in; the 60 cells are plain children
    -- and never get a per-item fade, so a large grid opens in one step.
    frame:SetScript("OnShow", function()
        self.closing = false
        refresh(self)
        app.Transitions:Reveal(frame)
    end)
    -- Any hide (Esc, button, component off) is a final state: the close fade
    -- is dropped and the frame is left opaque and hittable for the next open.
    frame:SetScript("OnHide", function()
        self.closing = false
        app.Transitions:Cancel(frame)
        frame:SetAlpha(1)
        frame:EnableMouse(true)
    end)
    app.Layout:Register("inventory", frame, UIParent:GetWidth() / 2 - 310, -45, L.inventory)
end

--------------------------------------------------------------------
-- Container takeover (014 phase 01)
--------------------------------------------------------------------
-- The bag key, the bag bar and "open all bags" are the client's own globals.
-- Each is wrapped, never replaced in spirit: the wrapper calls the original and
-- then decides what the player sees. The rule is deliberately narrow — LumaUI
-- only takes over the client's containers. When another bag addon's frames open
-- (the client's own frames never appear), nothing of ours is drawn on top, so
-- two browsers cannot stack. Every wrapper is inert while the profile switch is
-- off, and the originals are put back when it is turned off or the module stops.
local ENTRY_TOGGLES = { "ToggleBackpack", "ToggleAllBags", "ToggleBag" }
local ENTRY_OPENS = { "OpenAllBags" }
local ENTRY_CLOSES = { "CloseAllBags" }

local function nativeBagFrames()
    local frames = {}
    local combined = rawget(_G, "ContainerFrameCombinedBags")
    if combined then frames[#frames + 1] = combined end
    local count = Plain(rawget(_G, "NUM_CONTAINER_FRAMES"), "number") or 0
    for index = 1, count do
        local frame = rawget(_G, "ContainerFrame" .. index)
        if frame then frames[#frames + 1] = frame end
    end
    return frames
end

local function anyNativeBagOpen()
    if type(rawget(_G, "IsAnyBagOpen")) == "function" then
        local ok, open = pcall(_G.IsAnyBagOpen)
        if ok and Plain(open, "boolean") == true then return true end
    end
    for _, frame in ipairs(nativeBagFrames()) do
        local ok, shown = pcall(frame.IsShown, frame)
        if ok and shown == true then return true end
    end
    return false
end

local function hideNativeBags()
    local hidden = 0
    for _, frame in ipairs(nativeBagFrames()) do
        local ok, shown = pcall(frame.IsShown, frame)
        if ok and shown == true then
            if pcall(frame.Hide, frame) then hidden = hidden + 1 end
        end
    end
    return hidden
end

-- The client's own container window opened: hand it over. Another addon's
-- window opening on its own frames reaches neither branch and is left alone.
function module:AfterClientOpen()
    if not self.takeover or not self.running then return end
    if not anyNativeBagOpen() then return end
    hideNativeBags()
    self:SetOpen(true)
end

function module:AfterClientClose()
    if not self.takeover or not self.running then return end
    if self.frame and self.frame:IsShown() then self:SetOpen(false) end
end

function module:TakeoverWanted()
    return self.running == true and app.Store:Profile().ui.containerTakeover == true
end

function module:InstallTakeover()
    if self.entryWrappers then return true end
    local self_ = self
    local installed = {}
    local function wrap(name, before, after)
        local original = rawget(_G, name)
        if type(original) ~= "function" then return end
        local wrapper = function(...)
            if before and self_:BeforeClientToggle() then return end
            original(...)
            if after then app:Call("inventory/entry", self_[after], self_) end
        end
        rawset(_G, name, wrapper)
        installed[#installed + 1] = { name = name, original = original, wrapper = wrapper }
    end
    for _, name in ipairs(ENTRY_TOGGLES) do wrap(name, true, "AfterClientOpen") end
    for _, name in ipairs(ENTRY_OPENS) do wrap(name, false, "AfterClientOpen") end
    for _, name in ipairs(ENTRY_CLOSES) do wrap(name, false, "AfterClientClose") end
    if #installed == 0 then return false end
    self.entryWrappers = installed
    return true
end

function module:RemoveTakeover()
    for _, entry in ipairs(self.entryWrappers or {}) do
        -- Only put an original back while our wrapper is still the function in
        -- place: a bag addon that loaded later owns it now, and restoring over
        -- that would silently disable it.
        if rawget(_G, entry.name) == entry.wrapper then rawset(_G, entry.name, entry.original) end
    end
    self.entryWrappers = nil
end

-- A toggle whose window is already open is the player closing it; the client's
-- own container stays closed instead of being opened and hidden in one frame.
function module:BeforeClientToggle()
    if not self.takeover or not self.running then return false end
    local frame = self.frame
    if frame and frame:IsShown() then
        self:SetOpen(false)
        return true
    end
    return false
end

-- One entry point for the profile switch and the module lifecycle.
function module:ApplyTakeover()
    local wanted = self:TakeoverWanted()
    local other = wanted and otherBagAddon() or nil
    if self.buildFailed or not self.frame then wanted = false end
    if other then wanted = false end
    if wanted and not self.entryWrappers then self:InstallTakeover() end
    if not wanted and self.entryWrappers then self:RemoveTakeover() end
    self.takeover = wanted
    if app.Ownership then
        app.Ownership:Set("inventory.entry", wanted
            and { intent = "owned", active = "owned", evidence = "simulated" }
            or { intent = "owned", active = "native", evidence = "simulated",
                reason = self.buildFailed and "build" or (other and "thirdparty" or "option-off") })
    end
    return wanted
end

module = app:RegisterComponent({ id = "inventory", label = "inventory",
    Supported = function(_, caps) return caps.containers end,
    Enable = function(self)
        self.buildFailed = nil
        if not self.frame then
            -- A window that cannot be built leaves the client's containers alone.
            local ok = pcall(build, self)
            if not ok then
                self.frame = nil
                self.buildFailed = true
                app.Ownership:Set("inventory.entry", { intent = "owned", active = "native",
                    evidence = "simulated", reason = "build" })
                return
            end
        end
        self:Listen("BAG_UPDATE_DELAYED", refresh)
        self:Listen("PLAYER_EQUIPMENT_CHANGED", refresh)
        self:Listen("ITEM_DATA_LOAD_RESULT", refresh)
        self:ApplyTakeover()
    end,
    Refresh = function(self)
        if not self.frame then self:ApplyTakeover(); return end
        app.Surface:Plate(self.frame, "card")
        paintFilters(self)
        refresh(self)
        -- The profile switch lives in the same Refresh as the theme: turning it
        -- on or off applies on the next reconcile, without a reload.
        self:ApplyTakeover()
    end,
    Disable = function(self)
        self.takeover = false
        self:RemoveTakeover()
        if self.frame then
            -- A reveal still in flight is settled before hiding, so the window
            -- never comes back at a half faded alpha.
            app.Transitions:Settle(self.frame)
            self.frame:Hide()
        end
    end,
})

-- Container-takeover methods were defined before registration; the runtime
-- calls the spec, so they are copied onto it here without touching the
-- lifecycle callbacks it just declared.
for key, value in pairs(methods) do
    if module[key] == nil then module[key] = value end
end

-- The switch itself: written to the profile so the choice survives a reload.
-- Turning it off restores the client's entry points and containers at once.
function module:SetTakeover(wanted)
    wanted = wanted == true
    if (app.Store:Profile().ui.containerTakeover == true) == wanted then
        self:ApplyTakeover()
        return true
    end
    if not app.Store:Set("ui", "containerTakeover", wanted) then
        app:Print(L.readonly)
        return false
    end
    -- The switch promises the bank window as well, so the bank component is
    -- switched on with it: a component left off would make the bank silently
    -- stay native while the bag key changed.
    if wanted then app.Store:Set("modules", "bank", true) end
    self:ApplyTakeover()
    app:Print(wanted and L.containerTakeoverOn or L.containerTakeoverOff)
    return true
end

function module:ToggleTakeover()
    return self:SetTakeover(not (app.Store:Profile().ui.containerTakeover == true))
end

-- Re-entrant open/close. Opening from a half-closed window continues from the
-- current alpha; closing clears search focus and hits first, and only the
-- latest close hides the window. Motion off, combat or a missing fade settle
-- at once.
function module:SetOpen(open)
    local frame = self.frame
    if not self.running or not frame then return end
    local Transitions = app.Transitions
    if open then
        if frame:IsShown() and self.closing then
            self.closing = false
            frame:EnableMouse(true)
            Transitions:Fade(frame, frame, 1, 0.16, nil, "reveal")
        elseif not frame:IsShown() then
            frame:Show()
        end
        return
    end
    if not frame:IsShown() or self.closing then return end
    if InCombatLockdown() or not Transitions.MotionEnabled() then frame:Hide(); return end
    self.closing = true
    if self.search then self.search:ClearFocus() end
    frame:EnableMouse(false)
    Transitions:Cancel(frame, "reveal")
    local task = Transitions:Fade(frame, frame, 0, 0.11, function()
        if self.closing then frame:Hide() end
    end, "reveal")
    if not task and self.closing then frame:Hide() end
end

function module:Toggle()
    if not self.running then app:Print(L.inventoryDisabled); return end
    local frame = self.frame
    if not frame then app:Print(L.inventoryDisabled); return end
    self:SetOpen(not frame:IsShown() or self.closing == true)
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
