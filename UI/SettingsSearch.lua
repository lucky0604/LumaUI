local _, app = ...
local L, Controls, Plain = app.L, app.Controls, app.Capabilities.Plain
local SettingsUI = app.Settings

-- Settings search. The index is a flat list of descriptors (page, optional
-- object, optional field id, localized label key, short aliases) instead of a
-- walk over built frames: pages are built lazily, so a field that has not been
-- drawn yet must still be findable. Picking a result opens the page, selects
-- the object, and scrolls to the field once the page has laid itself out.
--
-- Aliases are written in both languages on purpose: a player types what the
-- control means to them ("符文", "rune"), not the exact label.
SettingsUI.fieldIndex = {
    { page = "actionBars", field = "buttons", label = "actionBarButtons", alias = "buttons 按钮 格数 数量 count" },
    { page = "actionBars", field = "rows", label = "actionBarRows", alias = "rows 行 排 行数" },
    { page = "actionBars", field = "size", label = "actionBarSize", alias = "size 大小 图标 尺寸 icon" },
    { page = "actionBars", field = "gap", label = "actionBarGap", alias = "gap spacing 间距 间隔" },
    { page = "actionBars", field = "visible", label = "fieldVisibility", alias = "show hide 显隐 战斗 隐藏 显示" },
    { page = "actionBars", field = "scale", label = "actionBarScaleSelected", alias = "scale 缩放" },
    { page = "cooldowns", field = "size", label = "hudSize", alias = "技能尺寸 图标大小 icon size 尺寸" },
    { page = "cooldowns", field = "gap", label = "hudGap", alias = "gap 间距 技能间距" },
    { page = "cooldowns", field = "max", label = "hudMax", alias = "row 每行 容量 技能行" },
    { page = "cooldowns", field = "limit", label = "hudLimit", alias = "limit 上限 最多" },
    { page = "cooldowns", field = "vertical", label = "hudVertical", alias = "纵列 横排 竖排 方向 orientation" },
    { page = "cooldowns", field = "import", label = "hudImport", alias = "import 导入 顺序 client" },
    { page = "cooldowns", field = "owned", label = "hudOwned", alias = "own 自有 技能组 冷却组" },
    { page = "cooldowns", field = "order", label = "fieldSpellOrder", alias = "order 技能顺序 拖放 跨组 排序" },
    { page = "chat", field = "takeover", label = "chatViewTitle", alias = "view 消息区 聊天视图" },
    { page = "chat", field = "opacity", label = "chatOpacity", alias = "opacity 透明度 背景" },
    { page = "chat", field = "width", label = "chatWidthLabel", alias = "width 宽度 尺寸" },
    { page = "chat", field = "height", label = "chatHeightLabel", alias = "height 高度 尺寸" },
    { page = "quests", field = "belowMap", label = "questBelowMap", alias = "任务 地图下方 tracker" },
    { page = "containers", field = "takeover", label = "containerTakeover", alias = "背包 银行 bag bank 接管" },
    { page = "info", field = "compact", label = "stripCompact", alias = "底带 信息条 compact 紧凑" },
    { page = "info", field = "clock", label = "clockOwner", alias = "时钟 clock 时间" },
    { page = "tooltip", field = "quality", label = "tooltipQuality", alias = "提示框 品质 quality" },
    { page = "groups", object = "raidFrames", field = "raidwidth", label = "groupRaidWidth", alias = "团队 raid 宽度 width 大小" },
    { page = "groups", object = "raidFrames", field = "raidheight", label = "groupRaidHeight", alias = "团队 raid 高度 height" },
    { page = "groups", object = "raidFrames", field = "raidgap", label = "groupRaidGap", alias = "团队 raid 间距 gap spacing" },
    { page = "resources", field = "runes", label = "resourceRunesToggle", alias = "符文 rune runes 死亡骑士 dk" },
    { page = "resources", field = "fragments", label = "resourceFragmentsToggle", alias = "残片 灵魂 soul fragment 复仇 dh vengeance" },
    -- Whole pages: reachable by what the page is about.
    { page = "groups", label = "navGroups", alias = "小队 团队 party raid 队伍 预览 小队预览 preview" },
    { page = "resources", label = "navResources", alias = "符文 rune runes 资源 能量 碎片 残片 resource 施法" },
    { page = "unitFrames", label = "navUnitFrames", alias = "单位框 玩家 目标 frame unit player target" },
    { page = "nameplates", label = "navNameplates", alias = "姓名板 nameplate plates" },
}

-- Other phases add their own descriptors without editing this table.
function SettingsUI:RegisterSearch(entry)
    self.fieldIndex[#self.fieldIndex + 1] = entry
end

local function lower(text)
    if type(text) ~= "string" then return "" end
    return text:lower()
end

local function pageLabel(pageKey)
    local entry = SettingsUI.moduleByID[pageKey]
    return entry and L[entry.label] or pageKey
end

local function objectLabel(pageKey, objectID)
    if not objectID then return nil end
    for _, object in ipairs(SettingsUI:ObjectList(pageKey)) do
        if object.id == objectID then return object.label end
    end
end

-- Plain-substring search over label, alias and page name. Chinese matches the
-- original text; Latin matches the lower-cased form. Results keep index order,
-- field entries before page entries of the same page, capped for the panel.
function SettingsUI:Search(query, limit)
    query = lower(query):gsub("^%s+", ""):gsub("%s+$", "")
    local results = {}
    if query == "" then return results end
    limit = limit or 8
    for _, entry in ipairs(self.fieldIndex) do
        local label = L[entry.label] or ""
        local haystack = lower(label) .. " " .. lower(entry.alias) .. " " .. lower(pageLabel(entry.page))
        if self.moduleByID[entry.page] and haystack:find(query, 1, true) then
            local exact = lower(label):find(query, 1, true) ~= nil
            results[#results + 1] = { entry = entry, label = label, exact = exact }
        end
    end
    table.sort(results, function(a, b)
        if a.exact ~= b.exact then return a.exact end
        return false
    end)
    while #results > limit do results[#results] = nil end
    return results
end

-- Position of a control inside its scroll body. The live client returns
-- (point, relativeTo, relativePoint, x, y).
local function offsetY(control)
    local ok, a, b, c, d, e = pcall(control.GetPoint, control, 1)
    if not ok then return nil end
    local y = Plain(e, "number")
    if y == nil then y = Plain(c, "number") end
    return y
end

-- Scroll the page so the field sits near the top and give it a short focus
-- ring. The timer only clears the ring if nothing else took the focus.
function SettingsUI:FocusField(pageKey, fieldID)
    local page = self.pages[pageKey]
    local control = page and page.fields and page.fields[fieldID]
    if not control then return false end
    local shown = type(control.IsShown) ~= "function" or control:IsShown()
    if not shown then return false end
    local y = offsetY(control)
    if page.scroll and y then page.scroll:ScrollTo(math.max(0, -y - 8)) end
    if control.state then
        control.state.focus = true
        if type(control.Refresh) == "function" then control:Refresh() end
        self.searchFlash = control
        C_Timer.After(1.4, function()
            if self.searchFlash ~= control then return end
            self.searchFlash = nil
            control.state.focus = false
            if type(control.Refresh) == "function" then control:Refresh() end
        end)
    end
    return true
end

function SettingsUI:OpenResult(result)
    local entry = result.entry
    self:HideSearchResults()
    if self.searchInput then self.searchInput:SetText(""); self.searchInput:ClearFocus() end
    self:Select(entry.page)
    local object = entry.object
    if object then
        if objectLabel(entry.page, object) then
            self:SelectObject(entry.page, object)
        else
            app:Print(string.format(L.searchObjectMissing, tostring(object)))
        end
    end
    if entry.field then self:FocusField(entry.page, entry.field) end
end

function SettingsUI:HideSearchResults()
    if self.searchPanel then self.searchPanel:Hide() end
end

function SettingsUI:RefreshSearch()
    if not self.searchPanel then return end
    local query = self.searchInput:GetText() or ""
    local results = self:Search(query)
    for index, row in ipairs(self.searchRows) do
        local result = results[index]
        row:SetShown(result ~= nil)
        if result then
            local suffix = pageLabel(result.entry.page)
            if not result.entry.field then suffix = L.searchPageSuffix end
            local label = result.label .. " · " .. suffix
            if app.Store.readonly and result.entry.field then label = label .. " · " .. L.searchReadonly end
            row.text:SetText(label)
            row.result = result
        end
    end
    self.searchEmpty:SetShown(query ~= "" and #results == 0)
    self.searchEmpty:SetText(L.searchNoResult)
    self.searchPanel:SetShown(query ~= "")
    self.searchPanel:SetHeight(math.max(34, #results * 30 + 8))
end

-- The search box sits in the header where the old tagline was. Results drop
-- over the page area in a card and never take the page's own layout with them.
function SettingsUI:BuildSearch(frame)
    local input = Controls:Input(frame, 300, { height = 26, maxLetters = 40 })
    input:SetPoint("TOPLEFT", 26, -30)
    self.searchInput = input
    local hint = app.Type:Text(input, "micro")
    hint:SetPoint("LEFT", 10, 0)
    hint:SetText(L.searchPlaceholder)
    input.hint = hint
    local panel = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    panel:SetPoint("TOPLEFT", input, "BOTTOMLEFT", 0, -4)
    panel:SetSize(300, 34)
    panel:SetFrameStrata("FULLSCREEN_DIALOG")
    panel:EnableMouse(true)
    app.Surface:Plate(panel, "card")
    panel:Hide()
    self.searchPanel = panel
    self.searchRows = {}
    for index = 1, 8 do
        local row = Controls:Button(panel, "", 292, function(button)
            if button.result then self:OpenResult(button.result) end
        end, { flat = true, height = 28 })
        row.text:ClearAllPoints()
        row.text:SetPoint("LEFT", 10, 0)
        row:SetPoint("TOPLEFT", 4, -4 - (index - 1) * 30)
        row:Hide()
        self.searchRows[index] = row
    end
    local empty = app.Type:Text(panel, "micro")
    empty:SetPoint("TOPLEFT", 10, -10)
    empty:Hide()
    self.searchEmpty = empty
    input:SetValidateHandler(function(box)
        hint:SetShown((box:GetText() or "") == "")
        self:RefreshSearch()
    end)
    input:SetScript("OnEscapePressed", function(box)
        box:SetText("")
        box:ClearFocus()
        self:HideSearchResults()
    end)
    input:SetScript("OnEnterPressed", function(box)
        local first = self:Search(box:GetText(), 1)[1]
        if first then self:OpenResult(first) else box:ClearFocus() end
    end)
end

-- Keep the window inside the screen at large UI scales or small windows: the
-- frame is scaled down, never past 1, so the page width and the header stay
-- intact. Called from Open and on the two display events.
function SettingsUI:FitToScreen()
    local frame = self.frame
    if not frame then return end
    local width = Plain(UIParent:GetWidth(), "number")
    local height = Plain(UIParent:GetHeight(), "number")
    if not width or not height or width <= 0 or height <= 0 then return end
    local fit = math.min(1, (width * 0.96) / 760, (height * 0.94) / 574)
    fit = math.max(0.5, fit)
    if frame:GetScale() ~= fit then frame:SetScale(fit) end
    self.fitScale = fit
end

function SettingsUI:WatchDisplay()
    if self.displayWatcher then return end
    local watcher = CreateFrame("Frame")
    watcher:RegisterEvent("UI_SCALE_CHANGED")
    watcher:RegisterEvent("DISPLAY_SIZE_CHANGED")
    watcher:SetScript("OnEvent", function() self:FitToScreen() end)
    self.displayWatcher = watcher
end
