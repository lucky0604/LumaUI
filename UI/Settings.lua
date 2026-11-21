local _, app = ...
local L, Controls = app.L, app.Controls
local SettingsUI = { pages = {}, active = "general", profileOffset = 0 }
app.Settings = SettingsUI

local function note(parent, text, y, width)
    local label = app.Theme:TextRole(parent, "muted")
    label:SetPoint("TOPLEFT", 0, y)
    label:SetWidth(width or 462)
    label:SetText(text)
    label:SetJustifyV("TOP")
    return label
end

-- A quiet group heading: one muted line and a very light rule. Grouping comes
-- from this, not from a second outlined surface around every row.
local function section(parent, text, y)
    local label = app.Theme:Text(parent, 11, true)
    label:SetPoint("TOPLEFT", 0, y)
    label:SetWidth(462)
    label:SetText(text)
    local line = parent:CreateTexture(nil, "ARTWORK")
    line:SetPoint("TOPLEFT", 0, y - 15)
    line:SetWidth(462)
    line:SetHeight(app.Pixel:Pixels(1))
    local c = app.Theme.colors.line
    line:SetColorTexture(c[1], c[2], c[3], 0.3)
    return label
end

-- Controls that write the profile: disabled as a group on a read-only database.
local function settingsControl(page, control)
    page.settings = page.settings or {}
    page.settings[#page.settings + 1] = control
    return control
end

-- GetChildren returns varargs on the live client and one table in the local
-- harness (the same shape both existing traversals already handle).
local function childList(frame)
    if not frame or type(frame.GetChildren) ~= "function" then return {} end
    local results = { pcall(frame.GetChildren, frame) }
    if not results[1] then return {} end
    if type(results[2]) == "table" then return results[2] end
    local list = {}
    for index = 2, #results do list[#list + 1] = results[index] end
    return list
end

-- Re-applies the resolved state of every cached control on a page, so a theme
-- or accent change reaches controls that were built earlier in the session.
local function refreshStateful(root, depth)
    if not root or (depth or 0) > 4 then return end
    for _, child in ipairs(childList(root)) do
        if child.state and type(child.Refresh) == "function" then
            app:Call("settings/refresh", child.Refresh, child)
        end
        refreshStateful(child, (depth or 0) + 1)
    end
end

function SettingsUI:Result(ok, message)
    if not ok and message then app:Print(message) end
end

function SettingsUI:BuildGeneral(page)
    local scroll = Controls:Scroll(page, 464, 420)
    scroll:SetPoint("TOPLEFT")
    local body = CreateFrame("Frame", nil, scroll)
    body:SetSize(462, 420)
    scroll:SetScrollChild(body)
    page.scroll = scroll
    local updates = {}
    local function get(key) return app.Store:Profile().appearance[key] end
    local function set(key, value) self:Result(app.Store:Set("appearance", key, value)) end
    local y = -26
    note(body, L.generalHint, 0, 462)
    section(body, L.sectionSize, y)
    y = y - 22
    updates[#updates + 1] = settingsControl(page,
        Controls:Range(body, L.scale, y, 0.7, 1.5, 0.05, function() return get("scale") end,
            function(v) set("scale", v) end))
    y = y - 70
    section(body, L.sectionMotion, y)
    y = y - 22
    updates[#updates + 1] = settingsControl(page,
        Controls:Toggle(body, L.motion, y, function() return get("motion") end, function(v) set("motion", v) end))
    y = y - 40
    updates[#updates + 1] = settingsControl(page,
        Controls:Toggle(body, L.reduceMotion, y, function() return get("reduceMotion") end,
            function(v) set("reduceMotion", v) end))
    y = y - 44
    section(body, L.sectionOpacity, y)
    y = y - 22
    updates[#updates + 1] = settingsControl(page,
        Controls:Range(body, L.windowOpacity, y, 0.45, 1, 0.05, function() return get("windowOpacity") end,
            function(v) set("windowOpacity", v) end))
    y = y - 70
    updates[#updates + 1] = settingsControl(page,
        Controls:Range(body, L.hudOpacity, y, 0.15, 1, 0.05, function() return get("hudOpacity") end,
            function(v) set("hudOpacity", v) end))
    y = y - 70
    updates[#updates + 1] = settingsControl(page,
        Controls:Range(body, L.chatOpacity, y, 0, 1, 0.05, function() return get("chatOpacity") end,
            function(v) set("chatOpacity", v) end))
    y = y - 70
    updates[#updates + 1] = settingsControl(page,
        Controls:Range(body, L.chatActiveOpacity, y, 0.2, 1, 0.05,
            function() return get("chatActiveOpacity") end, function(v) set("chatActiveOpacity", v) end))
    y = y - 74
    section(body, L.sectionAccent, y)
    y = y - 22
    local ocean = settingsControl(page, Controls:Button(body, L.ocean, 150, function() set("accent", "ocean") end))
    ocean:SetPoint("TOPLEFT", 0, y)
    local ember = settingsControl(page, Controls:Button(body, L.ember, 150, function() set("accent", "ember") end))
    ember:SetPoint("TOPLEFT", 164, y)
    y = y - 40
    updates[#updates + 1] = settingsControl(page,
        Controls:Toggle(body, L.tooltipQuality, y, function() return get("tooltipQuality") end,
            function(v) set("tooltipQuality", v) end))
    y = y - 44
    section(body, L.sectionInfo, y)
    y = y - 22
    updates[#updates + 1] = settingsControl(page,
        Controls:Toggle(body, L.stripCompact, y, function() return app.Store:Profile().ui.stripCompact == true end,
            function(v) self:Result(app.Store:Set("ui", "stripCompact", v)) end))
    y = y - 40
    local clockLabel = note(body, L.clockOwner, y, 462)
    page.clockLabel = clockLabel
    -- Exactly one clock: three mutually exclusive choices, none of them a
    -- forced write on login. The current value is read from the profile on
    -- every update, so a profile switch repaints the selected button.
    local clockButtons = {}
    local function clockChoice(key, label, x)
        local button = settingsControl(page, Controls:Button(body, label, 104, function()
            self:Result(app.Store:Set("ui", "clock", key))
            self:Update()
        end))
        button:SetPoint("TOPLEFT", x, y - 20)
        clockButtons[key] = button
        return button
    end
    clockChoice("strip", L.clockStrip, 0)
    clockChoice("minimap", L.clockMinimap, 112)
    clockChoice("off", L.clockOff, 224)
    updates[#updates + 1] = { Update = function()
        local current = app.Store:Profile().ui.clock
        for key, button in pairs(clockButtons) do button:SetSelected(key == current) end
    end }
    y = y - 62
    section(body, L.sectionLayout, y)
    y = y - 22
    local edit = settingsControl(page, Controls:Button(body, L.edit, 150, function() app.Layout:Toggle() end))
    edit:SetPoint("TOPLEFT", 0, y)
    local reset = settingsControl(page, Controls:Button(body, L.resetLayout, 150, function()
        self:Result(app.Store:Reset(true))
        app.Layout:ApplyAll()
    end))
    reset:SetPoint("TOPLEFT", 164, y)
    y = y - 44
    page.instructions = note(body, L.instructions, y, 462)
    y = y - 44
    section(body, L.sectionCompatibility, y)
    y = y - 22
    updates[#updates + 1] = settingsControl(page,
        Controls:Range(body, L.legacyOpacity, y, 0.45, 1, 0.05, function() return get("opacity") end,
            function(v) set("opacity", v) end))
    y = y - 70
    page.compatibilityHint = note(body, L.compatibilityHint, y, 462)
    body:SetHeight(math.max(420, -y + 34))
    page.Update = function()
        for _, control in ipairs(updates) do control:Update() end
        local readonly = app.Store.readonly
        for _, control in ipairs(page.settings or {}) do
            if control.SetEnabled then control:SetEnabled(not readonly) end
        end
        scroll:UpdateRange()
    end
end

function SettingsUI:BuildModules(page)
    note(page, L.modulesHint, -2, 462)
    local scroll = Controls:Scroll(page, 464, 300)
    scroll:SetPoint("TOPLEFT", 0, -34)
    local body = CreateFrame("Frame", nil, scroll)
    body:SetSize(462, math.max(300, #app.order * 40))
    scroll:SetScrollChild(body)
    page.rows = {}
    page.scroll = scroll
    local issues = app.Theme:TextRole(page, "muted")
    issues:SetPoint("TOPLEFT", 0, -342)
    issues:SetWidth(330)
    page.issues = issues
    local diag = Controls:Button(page, L.openDiagnostics, 160, function() self:Select("diagnostics") end)
    diag:SetPoint("TOPLEFT", 0, -364)
    diag:Hide()
    page.diagButton = diag
    page.Update = function()
        local count = 0
        for i, id in ipairs(app.order) do
            local row = page.rows[id]
            if not row then
                local component = app.components[id]
                local label = type(component.label) == "string" and component.label or id
                row = Controls:Toggle(body, L[label], -(i - 1) * 40,
                    function() return app.Store:Profile().modules[id] == true end,
                    function(v) self:Result(app.Store:Set("modules", id, v)) end)
                row:SetWidth(462)
                page.rows[id] = row
                settingsControl(page, row)
            end
            row:Update(app.components[id])
            local status = app.components[id].status
            if status == "failed" or status == "unsupported" or status == "dependency" then
                count = count + 1
            end
        end
        body:SetHeight(math.max(300, #app.order * 40))
        scroll:UpdateRange()
        issues:SetText(count > 0 and string.format(L.modulesIssues, count) or L.modulesHealthy)
        diag:SetShown(count > 0)
        local readonly = app.Store.readonly
        for _, row in pairs(page.rows) do row:SetEnabled(not readonly) end
    end
end

function SettingsUI:BuildLayout(page)
    note(page, L.layoutHint, -2, 462)
    local move = Controls:Button(page, L.edit, 150, function() app.Layout:Toggle() end)
    move:SetPoint("TOPLEFT", 0, -52)
    local reset = Controls:Button(page, L.resetLayout, 150, function()
        self:Result(app.Store:Reset(true))
        app.Layout:ApplyAll()
    end)
    reset:SetPoint("TOPLEFT", 164, -52)
    local editMode = Controls:Button(page, L.openEditMode, 250, function()
        if EditModeManagerFrame and ShowUIPanel then
            ShowUIPanel(EditModeManagerFrame)
        else
            app:Print(L.editModeUnavailable)
        end
    end)
    editMode:SetPoint("TOPLEFT", 0, -92)
    self.layoutEditMode = editMode
    note(page, L.nativeLayoutHint, -128, 462)
    -- 16:9 preset: preview is explicit, applying writes only to the current
    -- profile and snapshots what was there, undo restores that snapshot.
    note(page, L.presetHint, -164, 462)
    local preview = Controls:Button(page, L.presetPreview, 104, function()
        app.Layout:PreviewPreset("default16x9")
        self:Update()
    end)
    preview:SetPoint("TOPLEFT", 0, -196)
    local apply = Controls:Button(page, L.presetApply, 104, function()
        app.Layout:ApplyPreset("default16x9")
        self:Update()
    end)
    apply:SetPoint("TOPLEFT", 112, -196)
    local cancel = Controls:Button(page, L.presetCancel, 104, function()
        app.Layout:CancelPresetPreview()
        self:Update()
    end)
    cancel:SetPoint("TOPLEFT", 224, -196)
    local undo = Controls:Button(page, L.presetUndo, 104, function()
        app.Layout:UndoPreset()
        self:Update()
    end)
    undo:SetPoint("TOPLEFT", 336, -196)
    self.presetButtons = { preview = preview, apply = apply, cancel = cancel, undo = undo }
    local count = note(page, "", -236, 462)
    self.layoutCount = count
    local scroll = Controls:Scroll(page, 464, 160)
    scroll:SetPoint("TOPLEFT", 0, -254)
    local body = CreateFrame("Frame", nil, scroll)
    body:SetSize(462, 160)
    scroll:SetScrollChild(body)
    self.layoutRows = {}
    self.layoutScroll = scroll
    -- Rows are built on demand for the entries that actually exist, so every
    -- registered panel is reachable no matter how many components are running.
    local function createRow(index)
        local row = CreateFrame("Frame", nil, body)
        row:SetSize(462, 32)
        row:SetPoint("TOPLEFT", 0, -(index - 1) * 34)
        row.label = app.Theme:TextRole(row, "label")
        row.label:SetPoint("LEFT")
        row.label:SetWidth(320)
        row.button = Controls:Button(row, L.move, 90, function()
            if row.id then app.Layout:SetEditing(true) end
        end)
        row.button:SetPoint("RIGHT")
        self.layoutRows[index] = row
        return row
    end
    self.layoutEmpty = note(page, L.noLayoutEntries, -254, 464)
    page.Update = function()
        local ids = app.Layout:IDs()
        local rows = self.layoutRows
        local readonly = app.Store.readonly
        for index, id in ipairs(ids) do
            local row = rows[index] or createRow(index)
            row.id = id
            local entry = app.Layout.entries[id]
            row.label:SetText(entry and entry.label or id)
            row:SetShown(true)
            row.button:SetEnabled(not readonly)
        end
        for index = #ids + 1, #rows do
            rows[index].id = nil
            rows[index]:SetShown(false)
        end
        self.layoutEmpty:SetShown(#ids == 0)
        count:SetText(string.format(L.layoutCount, #ids))
        move:SetEnabled(not readonly)
        reset:SetEnabled(not readonly)
        editMode:SetEnabled(not readonly)
        preview:SetEnabled(not readonly)
        apply:SetEnabled(not readonly)
        cancel:SetEnabled(not readonly and app.Layout.previewName ~= nil)
        undo:SetEnabled(not readonly and app.Layout.presetSnapshot ~= nil)
        body:SetHeight(math.max(160, #ids * 34))
        scroll:UpdateRange()
    end
end

function SettingsUI:BuildProfiles(page)
    note(page, L.profileHint, -2, 462)
    local readonlyNote = note(page, L.readonlyNote, -30, 462)
    readonlyNote:Hide()
    self.readonlyNote = readonlyNote
    self.currentLabel = note(page, "", -64)
    note(page, L.profileName, -92)
    local input = Controls:Input(page, 482)
    input:SetPoint("TOPLEFT", 6, -114)
    local function create(copy)
        self:Result(app.Store:Create(input:GetText(), copy))
        input:ClearFocus()
        self.confirmDelete, self.confirmReset = nil, nil
        self:Update()
    end
    local blank = Controls:Button(page, L.create, 150, function() create(false) end)
    blank:SetPoint("TOPLEFT", 0, -152)
    local duplicate = Controls:Button(page, L.copy, 150, function() create(true) end)
    duplicate:SetPoint("TOPLEFT", 164, -152)
    self.createButton, self.duplicateButton = blank, duplicate
    -- The value itself is only committed by Store:Create; the controls show the
    -- validation result and refuse the action while the name is invalid.
    local function syncCreate()
        local valid = input:IsValid() and not app.Store.readonly
        blank:SetEnabled(valid)
        duplicate:SetEnabled(valid)
    end
    input:SetValidateHandler(syncCreate)
    input:SetValidator(function(text) return app.Store:ValidName(text) end)
    syncCreate()
    self.profileInput = input
    self.profileRows = {}
    for i = 1, 5 do
        local row = CreateFrame("Frame", nil, page)
        row:SetSize(490, 28)
        row:SetPoint("TOPLEFT", 0, -196 - (i - 1) * 33)
        row.name = app.Theme:TextRole(row, "label")
        row.name:SetPoint("LEFT")
        row.name:SetWidth(270)
        row.use = Controls:Button(row, L.use, 74, function()
            self.confirmDelete, self.confirmReset = nil, nil
            self:Result(app.Store:Select(row.key))
        end)
        row.use:SetPoint("RIGHT", -96, 0)
        row.delete = Controls:Button(row, L.delete, 90, function()
            if self.confirmDelete == row.key then
                self.confirmDelete = nil
                self:Result(app.Store:Delete(row.key))
            else
                self.confirmDelete = row.key
                self:Update()
            end
        end)
        row.delete:SetPoint("RIGHT")
        self.profileRows[i] = row
    end
    local previous = Controls:Button(page, "<", 42, function()
        self.profileOffset = math.max(0, self.profileOffset - 5)
        self:Update()
    end)
    previous:SetPoint("TOPLEFT", 0, -360)
    local following = Controls:Button(page, ">", 42, function()
        if self.profileOffset + 5 < #app.Store:Names() then self.profileOffset = self.profileOffset + 5 end
        self:Update()
    end)
    following:SetPoint("TOPLEFT", 52, -360)
    local reset = Controls:Button(page, L.resetProfile, 230, function()
        if self.confirmReset then
            self.confirmReset = nil
            self:Result(app.Store:Reset(false))
        else
            self.confirmReset = true
            self:Update()
        end
    end)
    reset:SetPoint("TOPRIGHT", 0, -360)
    page.Update = function()
        self.currentLabel:SetText(L.active .. ": " .. app.Store.current)
        local names = app.Store:Names()
        local readonly = app.Store.readonly
        readonlyNote:SetShown(readonly)
        if self.profileOffset >= #names then self.profileOffset = math.max(0, math.floor((#names - 1) / 5) * 5) end
        for i, row in ipairs(self.profileRows) do
            row.key = names[self.profileOffset + i]
            row:SetShown(row.key ~= nil)
            if row.key then
                row.name:SetText(row.key .. (row.key == app.Store.current and "  ·  " .. L.profileCurrent or ""))
                -- The current profile cannot be re-selected and the last profile
                -- cannot be deleted: the control says so instead of failing.
                row.use:SetEnabled(not readonly and row.key ~= app.Store.current)
                row.delete:SetEnabled(not readonly and #names > 1)
                row.delete.text:SetText(self.confirmDelete == row.key and L.deleteConfirm or L.delete)
            end
        end
        previous:SetEnabled(not readonly)
        following:SetEnabled(not readonly)
        reset:SetEnabled(not readonly)
        syncCreate()
        reset.text:SetText(self.confirmReset and L.resetConfirm or L.resetProfile)
    end
end

function SettingsUI:BuildDiagnostics(page)
    local scroll = Controls:Scroll(page, 464, 300)
    scroll:SetPoint("TOPLEFT", 0, -2)
    local body = CreateFrame("Frame", nil, scroll)
    body:SetSize(462, 300)
    scroll:SetScrollChild(body)
    page.scroll = scroll
    page.bodies = {}
    page.headers = {}
    local sections = {}
    local reflow
    local function setSection(section, expanded)
        if section.expanded == expanded then return end
        section.expanded = expanded
        section.header:SetFolded(not expanded)
        if expanded then
            app.Transitions:Cancel(section, "fold")
            section.text:SetAlpha(0)
            section.text:Show()
            app.Transitions:Fade(section, section.text, 1, 0.18, nil, "fold")
        else
            app.Transitions:Fade(section, section.text, 0, 0.12, function()
                if not section.expanded then
                    section.text:Hide()
                    section.text:SetAlpha(0)
                    if reflow then reflow() end
                end
            end, "fold")
        end
        if reflow then reflow() end
    end
    local function addSection(key, title, expanded)
        local section
        local header = Controls:FoldHeader(body, title, 462, function(folded)
            setSection(section, not folded)
        end)
        local text = app.Theme:TextRole(body, "muted")
        text:SetWidth(462)
        text:SetJustifyV("TOP")
        text:Hide()
        section = { key = key, header = header, text = text, expanded = expanded == true }
        header:SetFolded(not section.expanded)
        if section.expanded then text:Show() end
        sections[#sections + 1] = section
        page.bodies[key] = text
        page.headers[key] = header
        return section
    end
    addSection("status", L.diagStatus, true)
    addSection("native", L.diagNative, false)
    addSection("errors", L.diagErrors, true)
    reflow = function()
        local y = 0
        for _, section in ipairs(sections) do
            section.header:ClearAllPoints()
            section.header:SetPoint("TOPLEFT", 0, -y)
            y = y + 30
            -- A collapsing body keeps its space until the fade ends, so the
            -- sections below never jump under a still visible fade.
            if section.expanded or section.text:IsShown() then
                section.text:ClearAllPoints()
                section.text:SetPoint("TOPLEFT", 0, -y)
                y = y + math.max(18, section.text:GetStringHeight() or 18) + 12
            end
        end
        body:SetHeight(math.max(300, y + 6))
        scroll:UpdateRange()
    end
    local clear = Controls:Button(page, L.clear, 180, function()
        app.errors = {}
        self:Update()
    end)
    clear:SetPoint("TOPLEFT", 0, -312)
    note(page, L.privacy, -346)
    page.DisplayText = function()
        local parts = {}
        for _, section in ipairs(sections) do
            parts[#parts + 1] = section.text:GetText() or ""
        end
        return table.concat(parts, "\n")
    end
    page.Update = function()
        local caps = app.Capabilities.Snapshot()
        local status = {
            "LumaUI " .. app.version,
            L.runtime .. ": " .. tostring(caps.version) .. " / " .. tostring(caps.build) .. " / " .. tostring(caps.interface),
            L.api .. ": " .. app.apiVersion,
            L.active .. ": " .. app.Store.current,
            L.pending .. ": " .. app.Queue:Count(), "",
        }
        for _, id in ipairs(app.order) do status[#status + 1] = L[id] .. ": " .. app.components[id].status end
        local native = {}
        for _, id in ipairs(app.order) do
            local component = app.components[id]
            if type(component.Describe) == "function" then
                local ok, line = pcall(component.Describe, component)
                if ok and type(line) == "string" and line ~= "" then native[#native + 1] = line end
            end
        end
        if #native == 0 then native[1] = L.nativeNone end
        local errors = { L.errors .. ": " .. #app.errors }
        if #app.errors == 0 then
            errors[#errors + 1] = L.emptyDiagnostics
        else
            for _, err in ipairs(app.errors) do
                errors[#errors + 1] = err.context .. " (" .. err.count .. "): " .. err.message
            end
        end
        page.bodies.status:SetText(table.concat(status, "\n"))
        page.bodies.native:SetText(table.concat(native, "\n"))
        page.bodies.errors:SetText(table.concat(errors, "\n"))
        sections[1].header:SetText(L.diagStatus)
        sections[2].header:SetText(L.diagNative)
        sections[3].header:SetText((#app.errors > 0 and (L.diagErrors .. "  ·  " .. #app.errors)) or L.diagErrors)
        reflow()
    end
end

function SettingsUI:Build()
    local frame = CreateFrame("Frame", "LumaUISettings", UIParent, "BackdropTemplate")
    self.frame = frame
    frame:Hide()
    frame:SetSize(760, 574)
    frame:SetPoint("CENTER")
    frame:SetFrameStrata("DIALOG")
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function(self) self:StartMoving() end)
    frame:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
    -- Open/close fades are owned by Open/Close; OnShow only refreshes data and
    -- OnHide drops any task still in flight so a native Esc close cannot leave
    -- a half-transparent window behind for the next open.
    frame:SetScript("OnShow", function() self:Update() end)
    frame:SetScript("OnHide", function()
        self.wantsOpen = false
        app.Transitions:Cancel(self, "open")
        if self.frame then self.frame:SetAlpha(0) end
        if app.Controls then app.Controls:ClearFocus() end
        self.confirmDelete, self.confirmReset = nil, nil
    end)
    UISpecialFrames[#UISpecialFrames + 1] = "LumaUISettings"
    local theme = app.Theme
    -- Compact header: title and version on one line, one wrapped subtitle, one
    -- rule; the pages start higher than the old 110px header allowed.
    local title = theme:TextRole(frame, "title")
    title:SetPoint("TOPLEFT", theme:Space("lg") + 6, -12)
    title:SetText("LumaUI")
    local version = theme:TextRole(frame, "muted")
    version:SetPoint("LEFT", title, "RIGHT", 8, 0)
    version:SetText(app.version)
    self.versionLabel = version
    local subtitle = note(frame, L.subtitle, -36, 660)
    subtitle:ClearAllPoints()
    subtitle:SetPoint("TOPLEFT", theme:Space("lg") + 6, -36)
    local close = Controls:Button(frame, "×", 30, function() self:Close() end)
    close:SetPoint("TOPRIGHT", -14, -12)
    self.closeButton = close
    self.rule = app.Theme:Rule(frame)
    self.rule:SetPoint("TOPLEFT", theme:Space("lg") + 6, -62)
    self.rule:SetSize(708, 2)
    -- The navigation sits on an embedded surface instead of five separate
    -- outlined rows: one quiet region, one accent line for the active page.
    local nav = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    nav:SetPoint("TOPLEFT", theme:Space("md") + 4, -74)
    nav:SetSize(200, 216)
    nav:EnableMouse(false)
    self.navPanel = nav
    self.navigation = {}
    for i, key in ipairs({ "general", "layout", "modules", "profiles", "diagnostics" }) do
        local button = Controls:Navigation(frame, L[key], 176, function() self:Select(key) end)
        button:SetPoint("TOPLEFT", 24, -84 - (i - 1) * 42)
        self.navigation[key] = button
        local page = CreateFrame("Frame", nil, frame)
        page:SetPoint("TOPLEFT", 228, -72)
        page:SetSize(490, 424)
        page:Hide()
        self.pages[key] = page
    end
    self:BuildGeneral(self.pages.general)
    self:BuildLayout(self.pages.layout)
    self:BuildModules(self.pages.modules)
    self:BuildProfiles(self.pages.profiles)
    self:BuildDiagnostics(self.pages.diagnostics)
    self.footer = note(frame, "", -541, 708)
    self.footer:ClearAllPoints()
    self.footer:SetPoint("BOTTOMLEFT", 26, 16)
    self:Select(self.active)
end

function SettingsUI:Select(key)
    local previous = self.pages[self.active]
    self.active = self.pages[key] and key or "general"
    local page = self.pages[self.active]
    -- Each page keeps its own scroll position for the session; switching pages
    -- never repositions another page.
    if previous and previous ~= page then app.Transitions:Settle(previous) end
    for name, current in pairs(self.pages) do current:SetShown(name == self.active) end
    if page and self.frame and self.frame:IsShown() then
        page:SetAlpha(0)
        app.Transitions:Fade(page, page, 1, 0.16, nil, "page")
    end
    self:Update()
end

function SettingsUI:Update()
    if not self.frame then return end
    app.Theme:PaintSurface(self.frame, "window")
    if self.navPanel then app.Theme:PaintSurface(self.navPanel, "embedded") end
    local c = app.Theme:Accent()
    self.rule:SetColorTexture(c[1], c[2], c[3])
    for key, button in pairs(self.navigation) do
        -- Selected state is part of the control's own resolution, so a mouse
        -- leave can never reset the current page's accent (R03).
        button:SetSelected(key == self.active)
    end
    local page = self.pages[self.active]
    if page and page.Update then page.Update() end
    if page then refreshStateful(page) end
    local text = app.Store.readonly and L.readonlyNote
        or (app.Queue:Count() > 0 and L.queued or L.about)
    self.footer:SetText(text)
end

-- Opening never delays visibility: the frame is shown at once and only its
-- alpha animates. Opening again during a close continues from the current alpha
-- instead of restarting from zero.
function SettingsUI:Open(page)
    if not self.frame then self:Build() end
    local frame = self.frame
    self.wantsOpen = true
    if page then self:Select(page) end
    if not frame:IsShown() then
        frame:SetAlpha(0)
        frame:Show()
    end
    app.Transitions:Fade(self, frame, 1, 0.18, nil, "open")
end

function SettingsUI:Close()
    local frame = self.frame
    if not frame or not frame:IsShown() then return end
    self.wantsOpen = false
    -- A closing window must not keep keyboard focus.
    if app.Controls then app.Controls:ClearFocus() end
    if self.profileInput then self.profileInput:ClearFocus() end
    app.Transitions:Fade(self, frame, 0, 0.13, function()
        -- A reopen replaces the task, so this callback only runs for the final
        -- close request; the intent flag is a second guard.
        if self.wantsOpen then return end
        if self.frame and self.frame:IsShown() then self.frame:Hide() end
    end, "open")
end

function SettingsUI:Toggle(page)
    if not app.ready then app:Print(L.notReady); return end
    if not self.frame then self:Build() end
    if page then
        self:Open(page)
    elseif self.frame:IsShown() and self.wantsOpen then
        -- Open and the same key closes it; a press while the close fade is
        -- still running falls into the else branch and reopens instead.
        self:Close()
    else
        self:Open()
    end
end
