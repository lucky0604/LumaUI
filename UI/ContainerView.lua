local _, app = ...
local L = app.L
local Items, Model = app.Items, app.ContainerModel

-- Single scrolling, sectioned item view. Only the rows inside the scroll window
-- own widgets: headers and cells come from small pools and are re-pointed on
-- every scroll, so a 200-slot bag costs a few dozen frames. Every cell keeps its
-- physical bag/slot through the shared Items click helpers.
local View = {}
app.ContainerView = View

local CELL, GAP, HEADER, PAD = 40, 4, 22, 4
local ROW = CELL + GAP

function View:Create(parent, width, height, onClick)
    local view = setmetatable({ width = width, height = height, onClick = onClick, headers = {}, cells = {} }, { __index = View })
    view.scroll = app.Controls:Scroll(parent, width, height)
    view.body = CreateFrame("Frame", nil, view.scroll)
    view.body:SetSize(width, 1)
    view.scroll:SetScrollChild(view.body)
    view.perRow = math.max(1, math.floor((width - PAD) / ROW))
    view.scroll:SetScript("OnVerticalScroll", function() view:Draw() end)
    return view
end

-- Row heights differ (header vs item row), so offsets are accumulated once.
function View:Layout(sections, collapsed)
    self.sections, self.rows = sections, Model.Rows(sections, collapsed, self.perRow)
    self.offsets, self.total = {}, PAD
    for index, row in ipairs(self.rows) do
        self.offsets[index] = self.total
        self.total = self.total + (row.kind == "header" and HEADER or ROW)
    end
    self.body:SetHeight(math.max(1, self.total))
    self.scroll:UpdateRange()
end

local function pooled(pool, index, make)
    local frame = pool[index]
    if not frame then frame = make(); pool[index] = frame end
    return frame
end

function View:Draw()
    if not self.rows then return end
    local top = self.scroll:GetVerticalScroll() or 0
    local bottom = top + self.height
    local usedH, usedC = 0, 0
    local byID = {}
    for _, section in ipairs(self.sections) do byID[section.id] = section.items end
    for index, row in ipairs(self.rows) do
        local y = self.offsets[index]
        local h = row.kind == "header" and HEADER or ROW
        if y + h >= top and y <= bottom then
            if row.kind == "header" then
                usedH = usedH + 1
                local header = pooled(self.headers, usedH, function()
                    local button = app.Controls:Button(self.body, "", self.width - 12, function(b)
                        if b.section and self.onToggle then self.onToggle(b.section) end
                    end, { flat = true, height = HEADER - 2 })
                    return button
                end)
                header.section = row.section
                header:ClearAllPoints()
                header:SetPoint("TOPLEFT", PAD, -y)
                header.text:SetText(string.format("%s %s (%d)", row.collapsed and "+" or "-", L["section_" .. row.section] or row.section, row.count))
                header:Show()
            else
                local items = byID[row.section]
                for i = row.first, row.last do
                    usedC = usedC + 1
                    local cell = pooled(self.cells, usedC, function()
                        local c = Items.Cell(self.body)
                        c:SetScript("OnClick", function(b, mouse) if b.record and self.onClick then self.onClick(b, mouse) end end)
                        return c
                    end)
                    local record = items[i]
                    cell.record, cell.item = record, record.item
                    cell:ClearAllPoints()
                    cell:SetPoint("TOPLEFT", PAD + (i - row.first) * ROW, -y)
                    Items.Paint(cell, record.item)
                    cell:Show()
                end
            end
        end
    end
    for i = usedH + 1, #self.headers do self.headers[i]:Hide() end
    for i = usedC + 1, #self.cells do self.cells[i].record = nil; self.cells[i]:Hide() end
    self.drawnCells = usedC
end

function View:Set(records, collapsed)
    self:Layout(Model.Group(records), collapsed)
    self:Draw()
end

function View:SetShown(shown) self.scroll:SetShown(shown); self.scroll.bar:SetShown(shown and self.scroll.scrollable) end
