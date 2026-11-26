local _, app = ...
local L, Plain = app.L, app.Capabilities.Plain
local Items = app.Items
local PAGE_SIZE, COLUMNS = 48, 8
-- The spec is registered at the bottom; the bank-takeover methods are defined
-- before it, so they are collected here and copied onto the spec afterwards.
local methods = {}
local module = methods

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

local function collect(state, query, category, tab)
    local items = {}
    for index, bag in ipairs(state.bags or {}) do
        if tab == nil or tab == index then
        for slot = 1, slotsOf(bag) do
            local item = Items.Read(bag, slot)
            if item and Items.Matches(item, query, category) then
                if state.usable == false then item.blocked = L.bankBlocked end
                items[#items + 1] = item
            end
        end
        end
    end
    return items
end

-- One chip per purchased tab (plus "All"), only when the active bank has more
-- than one tab; the selection resets when the source or tab count changes.
local function tabChips(self, active)
    local count = active and active.bags and #active.bags or 0
    if self.tabCount ~= count or self.tabSource ~= (active and active.key) then
        self.tab, self.tabCount, self.tabSource = nil, count, active and active.key
    end
    for index, chip in ipairs(self.tabButtons or {}) do
        local shown = count > 1 and (index == 1 or index - 1 <= count)
        chip:SetShown(shown)
        if shown then chip:SetSelected((index == 1 and self.tab == nil) or self.tab == index - 1) end
    end
end

local function activeState(self)
    for _, state in ipairs(self.states or {}) do
        if state.key == self.source then return state end
    end
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
    self.canSort = false
    local active
    for _, state in ipairs(self.states) do
        if state.key == self.source then active = state end
    end
    if not active then
        active = self.states[1]
        self.source = active and active.key or nil
    end
    sourceChips(self)
    if not active then tabChips(self, nil) end
    -- Sorting is the client's own bank sort for this bank type, and only when
    -- the type may be acted on and the call exists.
    self.canSort = active ~= nil and active.usable ~= false and type(C_Container) == "table"
        and type(C_Container.SortBank) == "function"
    if self.sortButton then self.sortButton:SetShown(self.canSort) end
    local items, note
    if not active then
        items = {}
        note = L.bankClosed
    elseif active.empty then
        items = {}
        note = L.bankNoTabs
    else
        tabChips(self, active)
        items = collect(active, self.search:GetText():lower(), self.filter, self.tab)
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
    local close = app.Controls:Button(frame, "×", 28, function() self:SetOpen(false) end)
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
    -- Tab chips: "All" and up to 8 purchased tabs of the active bank type.
    self.tabButtons = {}
    for index = 1, 9 do
        local chip = app.Controls:Button(frame, index == 1 and L.bankTabAll or string.format(L.bankTabN, index - 1), 44,
            function()
                self.tab = index > 1 and index - 1 or nil
                self.page = 1
                refresh(self)
            end, { mutedWhenIdle = true, height = 22 })
        chip:SetPoint("TOPLEFT", 22 + (index - 1) * 48, -144)
        chip:Hide()
        self.tabButtons[index] = chip
    end
    self.sortButton = app.Controls:Button(frame, L.sortBags, 92, function()
        local state = activeState(self)
        if not self.canSort or not state then app:Print(L.itemActionsUnavailable); return end
        pcall(C_Container.SortBank, state.kind)
        refresh(self)
    end)
    self.sortButton:SetPoint("BOTTOMRIGHT", -22, 70)
    self.sortButton:Hide()
    Items.FilterRow(frame, self, 22, -118, function() refresh(self) end)
    self.empty = app.Theme:Text(frame, 14, true)
    self.empty:SetPoint("CENTER")
    self.empty:SetText(L.bankClosed)
    for i = 1, PAGE_SIZE do
        local button = Items.Cell(frame)
        self.buttons[i] = button
        button:SetPoint("TOPLEFT", 22 + ((i - 1) % COLUMNS) * 44, -172 - math.floor((i - 1) / COLUMNS) * 44)
        button:RegisterForDrag("LeftButton")
        button:SetScript("OnDragStart", function(self2) if not self.closing then Items.Pickup(self2.item) end end)
        button:SetScript("OnReceiveDrag", function(self2) if not self.closing then Items.Pickup(self2.item) end end)
        button:SetScript("OnClick", function(self2, mouseButton)
            local item = self2.item
            if not item or self.closing then return end
            if IsModifiedClick and IsModifiedClick("CHATLINK") then Items.Link(item); return end
            if mouseButton == "RightButton" then Items.Use(item) else Items.Pickup(item) end
        end)
    end
    -- Dropping on the window puts the item in the first empty slot of the
    -- active bank type (the client enforces what that bank accepts).
    local function dropHere()
        if self.closing then return end
        local state = activeState(self)
        if state and state.bags and state.usable ~= false then
            Items.DropFirstFree(state.bags)
        end
    end
    frame:SetScript("OnReceiveDrag", dropHere)
    frame:SetScript("OnMouseUp", dropHere)
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
    frame:SetScript("OnShow", function()
        self.closing = false
        refresh(self)
        app.Transitions:Reveal(frame)
    end)
    -- Any hide is a final state: opaque and hittable for the next open. When
    -- this window was the one holding the session open, closing it ends the
    -- session too, exactly like closing the client's own bank.
    frame:SetScript("OnHide", function()
        self.closing = false
        app.Transitions:Cancel(frame)
        frame:SetAlpha(1)
        frame:EnableMouse(true)
        if module then module:EndSession() end
    end)
end

--------------------------------------------------------------------
-- Native bank takeover (014 phase 01)
--------------------------------------------------------------------
-- The client's window owns the bank session: BankFrame:OnHide calls
-- C_Bank.CloseBankFrame, so hiding it would empty our own browser. The frame
-- stays shown and is made invisible and unhittable instead, together with its
-- content panel, so the session keeps running and everything comes back exactly
-- as recorded when the bank closes or the switch is turned off.
local function nativeBankFrame()
    return rawget(_G, "BankFrame")
end

function module:TakeoverOn()
    return self.running == true and self.frame ~= nil and app.Store:Profile().ui.containerTakeover == true
end

function module:SuppressNative(active)
    local frame = nativeBankFrame()
    if not frame then return false end
    if active then
        if not self.nativeBank then
            local okAlpha, alpha = pcall(frame.GetAlpha, frame)
            local okMouse, mouse = pcall(frame.IsMouseEnabled, frame)
            self.nativeBank = {
                alpha = okAlpha and Plain(alpha, "number") or 1,
                mouse = okMouse and mouse == true or false,
                panel = frame.BankPanel,
            }
        end
        pcall(frame.SetAlpha, frame, 0)
        pcall(frame.EnableMouse, frame, false)
        local panel = self.nativeBank.panel
        if panel then pcall(panel.Hide, panel) end
        return true
    end
    if not self.nativeBank then return false end
    local recorded = self.nativeBank
    self.nativeBank = nil
    pcall(frame.SetAlpha, frame, recorded.alpha)
    pcall(frame.EnableMouse, frame, recorded.mouse)
    if recorded.panel then pcall(recorded.panel.Show, recorded.panel) end
    return true
end

-- Closing our window ends the session, because the client's window is what
-- holds it. The reverse path (walking away, the client closing it) arrives as
-- BANKFRAME_CLOSED and only restores what was recorded.
function module:EndSession()
    if not self.nativeBank then return end
    self:SuppressNative(false)
    if type(C_Bank) == "table" and type(C_Bank.CloseBankFrame) == "function" then
        pcall(C_Bank.CloseBankFrame)
    end
end

module = app:RegisterComponent({ id = "bank", label = "bankTitle", defaultEnabled = false,
    Supported = function(_, caps) return caps.containers end,
    Enable = function(self)
        self.buildFailed = nil
        if not self.frame then
            -- A window that cannot be built leaves the client's bank alone.
            if not pcall(build, self) then
                self.frame, self.buildFailed = nil, true
                return
            end
        end
        -- The component switch doubles as the open entry: enabling creates the
        -- browser and shows it. With the takeover on the client's own window is
        -- what opens it, so no empty browser sits on screen at login.
        if not self:TakeoverOn() then self.frame:Show() end
        pcall(self.Listen, self, "BANKFRAME_OPENED", function()
            if self:TakeoverOn() then self:SuppressNative(true) end
            self.frame:Show()
            refresh(self)
        end)
        pcall(self.Listen, self, "BANKFRAME_CLOSED", function()
            -- Hand the client's frame back first: the hide below runs the close
            -- path, and that path must not ask the client to close a session
            -- which the client has already closed.
            self:SuppressNative(false)
            self.frame:Hide()
        end)
        -- Tabs and permission changes redraw while the window is open.
        for _, event in ipairs({ "BAG_UPDATE_DELAYED", "BANK_TABS_CHANGED", "PLAYER_ACCOUNT_BANK_TAB_SLOTS_CHANGED" }) do
            pcall(self.Listen, self, event, function()
                if self.frame and self.frame:IsShown() then refresh(self) end
            end)
        end
    end,
    Refresh = function(self)
        -- Turning the shared switch off must hand the client's window back even
        -- when the bank is open and this module was never re-enabled.
        if not self:TakeoverOn() then self:SuppressNative(false) end
        if not self.frame then return end
        app.Surface:Plate(self.frame, "card")
        Items.PaintFilters(self)
        sourceChips(self)
        refresh(self)
    end,
    Disable = function(self)
        self:SuppressNative(false)
        if self.frame then
            app.Transitions:Settle(self.frame)
            self.frame:Hide()
        end
    end,
})

-- The takeover methods were defined before registration; the runtime calls the
-- spec, so they are copied onto it without touching its lifecycle callbacks.
for key, value in pairs(methods) do
    if module[key] == nil then module[key] = value end
end

-- Same re-entrant open/close as the bags. The server-side BANKFRAME_CLOSED
-- hides at once; only the player's own close and toggle fade.
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
    if not self.running then app:Print(L.bankHintDisabled); return end
    if not self.frame then app:Print(L.bankHintDisabled); return end
    self:SetOpen(not self.frame:IsShown() or self.closing == true)
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
