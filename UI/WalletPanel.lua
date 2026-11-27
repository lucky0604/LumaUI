local _, app = ...
local L = app.L
local Panel = {}
app.WalletPanel = Panel

-- Ledger window: a read-only list of the recorded balances with their age, and
-- one multi-line box for LUMA-WALLET/1 text. Export fills the box with the own
-- ledger; Import validates the pasted text, shows the counts, and only a second
-- press writes it. Offline rows have no actions.
local function lines(filter)
    local out = {}
    local Ledger = app.Ledger
    if filter ~= nil then
        for _, row in ipairs(Ledger:Rows(filter)) do
            out[#out + 1] = string.format("%s  #%d = %d  [%s]", row.name, row.currency, row.qty,
                row.seen and L.walletRead or L.walletUnknown)
        end
        return out
    end
    for _, row in ipairs(Ledger:Money()) do
        local age = row.legacy and L.walletLegacy or (row.seen and L.walletRead or L.walletUnknown)
        out[#out + 1] = string.format("%s  %s  [%s]", row.name, GetMoneyString and GetMoneyString(row.qty) or tostring(row.qty), age)
    end
    return out
end

function Panel:Build()
    if self.frame then return end
    local frame = CreateFrame("Frame", "LumaUIWallet", UIParent, "BackdropTemplate")
    frame:Hide()
    frame:SetSize(420, 380)
    frame:SetPoint("CENTER")
    frame:SetFrameStrata("HIGH")
    frame:EnableMouse(true)
    UISpecialFrames[#UISpecialFrames + 1] = "LumaUIWallet"
    app.Surface:Plate(frame, "card")
    local title = app.Type:Text(frame, "title")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText(L.walletTitle)
    local list = app.Type:Text(frame, "micro")
    list:SetPoint("TOPLEFT", 16, -44)
    list:SetWidth(388)
    local status = app.Type:Text(frame, "micro")
    status:SetPoint("BOTTOMLEFT", 16, 14)
    status:SetWidth(388)
    local box = CreateFrame("EditBox", nil, frame)
    box:SetMultiLine(true)
    box:SetAutoFocus(false)
    box:SetMaxBytes(app.Ledger.limits.bytes)
    box:SetSize(388, 120)
    box:SetPoint("BOTTOMLEFT", 16, 80)
    box:SetFontObject(ChatFontNormal or GameFontHighlightSmall)
    local export = app.Controls:Button(frame, L.walletExport, 120, function() Panel:Export() end)
    export:SetPoint("BOTTOMLEFT", 16, 44)
    local import = app.Controls:Button(frame, L.walletImport, 120, function() Panel:Import() end)
    import:SetPoint("LEFT", export, "RIGHT", 8, 0)
    local filterBox = app.Controls:Input(frame, 120, { height = 22, maxLetters = 48 })
    filterBox:SetPoint("TOPRIGHT", -16, -14)
    filterBox:SetValidateHandler(function() Panel:Refresh() end)
    -- Source controls: the button cycles the selected source, the name box and
    -- Rename change its display name, Group joins it with the local source.
    local pick = app.Controls:Button(frame, "", 120, function() Panel:NextSource() end)
    pick:SetPoint("BOTTOMLEFT", 16, 210)
    local nameBox = app.Controls:Input(frame, 110, { height = 22, maxLetters = 40 })
    nameBox:SetPoint("LEFT", pick, "RIGHT", 8, 0)
    local rename = app.Controls:Button(frame, L.walletRename, 70, function() Panel:RenameSource() end)
    rename:SetPoint("LEFT", nameBox, "RIGHT", 8, 0)
    local group = app.Controls:Button(frame, L.walletGroup, 70, function() Panel:GroupSource() end)
    group:SetPoint("LEFT", rename, "RIGHT", 8, 0)
    self.frame, self.list, self.status, self.box, self.filterBox = frame, list, status, box, filterBox
    self.pick, self.nameBox = pick, nameBox
end

function Panel:Refresh()
    if not self.frame then return end
    local text = self.filterBox and self.filterBox:GetText() or ""
    local filter = text ~= "" and (tonumber(text) or text) or nil
    self.list:SetText(table.concat(lines(filter), "\n"))
end

local function sourceIDs()
    local ids = {}
    for id in pairs(app.Ledger:Data().sources) do ids[#ids + 1] = id end
    table.sort(ids)
    return ids
end

function Panel:NextSource()
    self:Build()
    local ids = sourceIDs()
    if #ids == 0 then return end
    local index = 0
    for i, id in ipairs(ids) do if id == self.selected then index = i end end
    self.selected = ids[index % #ids + 1]
    self.pick.text:SetText(self.selected)
end

function Panel:RenameSource()
    self:Build()
    local ok = self.selected and app.Ledger:RenameSource(self.selected, self.nameBox:GetText())
    self.status:SetText(ok and L.walletRenamed or L.walletRenameFailed)
end

function Panel:GroupSource()
    self:Build()
    local ok = self.selected and app.Ledger:Group("local", self.selected)
    self.status:SetText(ok and L.walletGrouped or L.walletGroupFailed)
end

function Panel:Export()
    self:Build()
    self.pending = nil
    self.box:SetText(app.Ledger:Export())
    self.status:SetText(L.walletExported)
end

-- First press previews, the second press with the same text commits.
function Panel:Import()
    self:Build()
    local text = self.box:GetText()
    if app.Store.readonly then self.status:SetText(L.readonly); return end
    if self.pending and self.pending.text == text then
        app.Ledger:Commit(self.pending.plan)
        self.status:SetText(L.walletImported)
        self.pending = nil
        self:Refresh()
        return
    end
    local plan, reason = app.Ledger:Preview(text)
    if not plan then
        self.pending = nil
        self.status:SetText(string.format(L.walletRejected, tostring(reason)))
        return
    end
    self.pending = { text = text, plan = plan }
    self.status:SetText(string.format(L.walletPreview, plan.name, plan.added, plan.updated, plan.unchanged, plan.stale))
end

function Panel:Toggle()
    self:Build()
    if self.frame:IsShown() then self.frame:Hide() else
        if app.Ledger:RequestWarband() then app.Ledger:ReadAllWarband() end
        self:Refresh(); self.frame:Show()
    end
end
