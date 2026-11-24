local _, app = ...
local L, Plain = app.L, app.Capabilities.Plain
local Items = app.Items
local PAGE_SIZE, COLUMNS = 48, 8
local module

-- Each bank type is probed on its own: whether it can be viewed and whether its
-- contents may be acted on are separate questions on Retail. The tab bag ids
-- come from C_Bank.FetchPurchasedBankTabIDs; the legacy character-bank
-- container is only a fallback for builds without that call, never a guess at
-- account bag numbers.
local function bankTypes()
    local list = {}
    local enum = type(Enum) == "table" and Enum.BankType
    if type(enum) ~= "table" then return list end
    local character, account = Plain(enum.Character, "number"), Plain(enum.Account, "number")
    if character then list[#list + 1] = { kind = character, key = "character", label = L.bankSourceCharacter } end
    if account then list[#list + 1] = { kind = account, key = "account", label = L.bankSourceAccount } end
    return list
end

local function probe(fn, kind)
    if type(C_Bank) ~= "table" or type(C_Bank[fn]) ~= "function" then return nil end
    local ok, value = pcall(C_Bank[fn], kind)
    if not ok then return nil end
    return Plain(value, "boolean")
end

local function canView(kind) return probe("CanViewBank", kind) end
local function canUse(kind) return probe("CanUseBank", kind) end

local function slotsOf(bag)
    if type(C_Container) ~= "table" or type(C_Container.GetContainerNumSlots) ~= "function" then return 0 end
    local ok, slots = pcall(C_Container.GetContainerNumSlots, bag)
    return ok and Plain(slots, "number") or 0
end

-- Purchased tab ids for one bank type. Returns nil when the client has no tab
-- API at all, {} when the API answered with no tabs.
local function tabBags(kind)
    if type(C_Bank) ~= "table" or type(C_Bank.FetchPurchasedBankTabIDs) ~= "function" then return nil end
    local ok, tabs = pcall(C_Bank.FetchPurchasedBankTabIDs, kind)
    if not ok or type(tabs) ~= "table" then return nil end
    local bags = {}
    for _, bag in ipairs(tabs) do
        local id = Plain(bag, "number")
        if id and slotsOf(id) > 0 then bags[#bags + 1] = id end
    end
    return bags
end

-- One bank type's readable state. `usable` is nil when the client cannot say;
-- actions then go ahead and the client itself refuses, as it did before.
local function stateOf(spec)
    local state = { kind = spec.kind, key = spec.key, label = spec.label, viewable = canView(spec.kind) }
    state.usable = canUse(spec.kind)
    if state.viewable ~= true then return state end
    local tabs = tabBags(spec.kind)
    if tabs == nil and spec.key == "character" and Plain(BANK_CONTAINER, "number") then
        -- Legacy builds: the character bank is one container, no tab list.
        tabs = slotsOf(BANK_CONTAINER) > 0 and { BANK_CONTAINER } or {}
    end
    state.bags = tabs
    state.empty = tabs ~= nil and #tabs == 0
    return state
end

local function collect(state, query, category)
    local items = {}
    for _, bag in ipairs(state.bags or {}) do
        for slot = 1, slotsOf(bag) do
            local item = Items.Read(bag, slot)
            if item and Items.Matches(item, query, category) then
                if state.usable == false then item.blocked = L.bankBlocked end
                items[#items + 1] = item
            end
        end
    end
    return items
end

local function sourceChips(self)
    for _, chip in ipairs(self.sources or {}) do
        chip:SetSelected(chip.key == self.source)
        chip:SetShown((self.sourceCount or 0) > 1)
    end
end

local function refresh(self)
    self.dirty = true
    if not self.frame or not self.frame:IsShown() then return end
    self.dirty = false
    -- Re-probe on every refresh: the bank can close, a tab can be purchased or
    -- the account can lose its inventory lock while the window stays open.
    self.states = {}
    for _, spec in ipairs(bankTypes()) do
        local state = stateOf(spec)
        if state.viewable == true then self.states[#self.states + 1] = state end
    end
    self.sourceCount = #self.states
    local active
    for _, state in ipairs(self.states) do
        if state.key == self.source then active = state end
    end
    if not active then
        active = self.states[1]
        self.source = active and active.key or nil
    end
    sourceChips(self)
    local items, note
    if not active then
        items = {}
        note = L.bankClosed
    elseif active.empty then
        items = {}
        note = L.bankNoTabs
    else
        items = collect(active, self.search:GetText():lower(), self.filter)
        if #items == 0 then note = L.empty end
    end
    local pages = math.max(1, math.ceil(#items / PAGE_SIZE))
    self.page = math.max(1, math.min(self.page or 1, pages))
    self.pageLabel:SetFormattedText("%d / %d", self.page, pages)
    -- The corner note names the active degradation: a closed bank, no tabs, or
    -- browse-only permissions. Nothing is silently omitted.
    if active and active.usable == false and not note then note = L.bankBlocked end
    self.empty:SetShown(#items == 0)
    self.empty:SetText(#items == 0 and (note or L.empty) or "")
    self.note:SetShown(note ~= nil and not self.empty:IsShown())
    self.note:SetText(note or "")
    for i, button in ipairs(self.buttons) do
        Items.Paint(button, items[(self.page - 1) * PAGE_SIZE + i])
    end
end

local function redraw(self) refresh(self) end

local function build(self)
    local frame = CreateFrame("Frame", "LumaUIBank", UIParent, "BackdropTemplate")
    self.frame, self.buttons, self.page = frame, {}, 1
    frame:Hide()
    frame:SetSize(508, 500)
    frame:SetFrameStrata("HIGH")
    frame:EnableMouse(true)
    frame:SetClampedToScreen(true)
    UISpecialFrames[#UISpecialFrames + 1] = "LumaUIBank"
    local title = app.Type:Text(frame, "display")
    title:SetPoint("TOPLEFT", 20, -18)
    title:SetText(L.bankTitle)
    local close = app.Controls:Button(frame, "×", 28, function() frame:Hide() end)
    close:SetPoint("TOPRIGHT", -12, -12)
    Items.Search(frame, self, 462, 26, -56, function() refresh(self) end)
    -- The bank type is a choice, not a title: only viewable banks appear, and a
    -- single viewable bank shows no choice at all.
    self.sources = {}
    local sourceX = 22
    for _, spec in ipairs(bankTypes()) do
        local chip = app.Controls:Button(frame, spec.label, 92, function()
            self.source, self.page = spec.key, 1
            sourceChips(self)
            refresh(self)
        end, { mutedWhenIdle = true, height = 22 })
        chip.key = spec.key
        chip:SetPoint("TOPLEFT", sourceX, -88)
        self.sources[#self.sources + 1] = chip
        sourceX = sourceX + 98
    end
    Items.FilterRow(frame, self, 22, -118, function() refresh(self) end)
    self.empty = app.Theme:Text(frame, 14, true)
    self.empty:SetPoint("CENTER")
    self.empty:SetText(L.bankClosed)
    for i = 1, PAGE_SIZE do
        local button = Items.Cell(frame)
        self.buttons[i] = button
        button:SetPoint("TOPLEFT", 22 + ((i - 1) % COLUMNS) * 44, -156 - math.floor((i - 1) / COLUMNS) * 44)
        button:SetScript("OnClick", function(self2, mouseButton)
            local item = self2.item
            if not item then return end
            if IsModifiedClick and IsModifiedClick("CHATLINK") then Items.Link(item); return end
            if mouseButton == "RightButton" then Items.Use(item) else Items.Pickup(item) end
        end)
    end
    Items.Pager(frame, self, { "BOTTOMLEFT", 22, 40 }, 56, function() redraw(self) end)
    self.note = app.Theme:Text(frame, 11, true)
    self.note:SetPoint("BOTTOMRIGHT", -22, 52)
    self.note:SetJustifyH("RIGHT")
    local hint = app.Theme:Text(frame, 11, true)
    hint:SetPoint("BOTTOMLEFT", 22, 14)
    hint:SetPoint("BOTTOMRIGHT", -22, 14)
    hint:SetJustifyH("LEFT")
    hint:SetText(L.bankHintActions)
    -- Fixed position near the native bank frame when it exists; the bank
    -- window is deliberately not registered in the LumaUI layout editor.
    local bankFrame = rawget(_G, "BankFrame")
    local anchored = bankFrame ~= nil and pcall(frame.SetPoint, frame, "TOPLEFT", bankFrame, "TOPRIGHT", 18, -8)
    if not anchored then frame:SetPoint("CENTER", UIParent, "CENTER", 260, 40) end
    -- Only this window fades in; its cells are plain children, so an 8-column
    -- grid appears in one step instead of 48 staggered fades.
    frame:SetScript("OnShow", function() refresh(self); app.Transitions:Reveal(frame) end)
end

module = app:RegisterComponent({ id = "bank", label = "bankTitle", defaultEnabled = false,
    Supported = function(_, caps) return caps.containers end,
    Enable = function(self)
        if not self.frame then build(self) end
        -- The component switch doubles as the open entry: enabling creates the
        -- browser and shows it. Bank events keep it in sync.
        self.frame:Show()
        pcall(self.Listen, self, "BANKFRAME_OPENED", function()
            self.frame:Show()
            refresh(self)
        end)
        pcall(self.Listen, self, "BANKFRAME_CLOSED", function() self.frame:Hide() end)
        -- Tabs and permission changes redraw while the window is open.
        for _, event in ipairs({ "BAG_UPDATE_DELAYED", "BANK_TABS_CHANGED", "PLAYER_ACCOUNT_BANK_TAB_SLOTS_CHANGED" }) do
            pcall(self.Listen, self, event, function()
                if self.frame and self.frame:IsShown() then refresh(self) end
            end)
        end
    end,
    Refresh = function(self)
        app.Surface:Plate(self.frame, "card")
        Items.PaintFilters(self)
        sourceChips(self)
        refresh(self)
    end,
    Disable = function(self)
        if self.frame then
            app.Transitions:Settle(self.frame)
            self.frame:Hide()
        end
    end,
})

function module:Toggle()
    if not self.running then app:Print(L.bankHintDisabled); return end
    self.frame:SetShown(not self.frame:IsShown())
end

-- Diagnostics: which bank types this build reports viewable, and the tab count
-- each one answered with. Nothing is inferred beyond what was probed.
function module:Describe()
    if not self.running then return nil end
    local parts = {}
    for _, state in ipairs(self.states or {}) do
        parts[#parts + 1] = string.format("%s=%d", state.key, state.bags and #state.bags or 0)
    end
    return string.format("bank: %s", #parts > 0 and table.concat(parts, " ") or L.diagNoBank)
end
