local _, app = ...
local L, Controls = app.L, app.Controls
local SettingsUI = { pages = {}, active = "overview", profileOffset = 0 }
app.Settings = SettingsUI

-- 019 geometry. The window grew from 760x574 to 880x600 so the navigation fits
-- every page without a rail and the body can hold a card's worth of controls at
-- once; `FitToScreen` still scales it down on a small viewport. `NAV_WIDTH` is
-- the whole left column (panel plus gutter), `CONTENT` the body column every
-- page and its cards are measured from.
SettingsUI.WIDTH, SettingsUI.HEIGHT = 880, 600
-- The whole left column (panel plus its gutter) and the body column every page
-- and its cards are measured from. 16 + 200 + 22 = 238 for the page's left
-- edge, and 880 - 238 - 30 = 612 for its width.
SettingsUI.NAV_WIDTH, SettingsUI.CONTENT = 200, 612
local CONTENT = SettingsUI.CONTENT
local NAV_WIDTH = SettingsUI.NAV_WIDTH
-- Body controls are one scrollbar's width narrower than the page frame, so a
-- card can never slide under the rail.
local COLUMN = CONTENT - 2
SettingsUI.COLUMN = COLUMN
-- Vertical anchors, kept in one place so the header, the page area and the
-- footer cannot drift apart when one of them changes.
local PAGE_LEFT, PAGE_TOP, PAGE_HEIGHT = 238, -74, 466
SettingsUI.PAGE_LEFT, SettingsUI.PAGE_TOP, SettingsUI.PAGE_HEIGHT = PAGE_LEFT, PAGE_TOP, PAGE_HEIGHT
-- Vertical advance per control kind. A range row is 44 px and a switch row 32;
-- the step carries a few pixels of breathing room so two cards never touch.
local RANGE_STEP, SWITCH_STEP = 50, 40

-- Pages that existed before 015 keep answering to their old key, so a stored
-- command, a bound macro or an older test still lands on the right page.
local PAGE_ALIAS = { general = "overview", modules = "overview", layout = "profiles" }
SettingsUI.aliases = PAGE_ALIAS

local function note(parent, text, y, width)
    local label = app.Type:Text(parent, "micro")
    label:SetPoint("TOPLEFT", 0, y)
    label:SetWidth(width or COLUMN)
    label:SetText(text)
    label:SetJustifyV("TOP")
    return label
end

local function noteHeight(label, minimum)
    local ok, value = pcall(label.GetStringHeight, label)
    value = ok and app.Capabilities.Plain(value, "number") or nil
    return math.max(minimum, value and math.ceil(value) + 10 or minimum)
end

-- A quiet group heading: one muted line and a very light rule. Grouping comes
-- from this, not from a second outlined surface around every row.
local function section(parent, text, y)
    local label = app.Type:Text(parent, "label")
    label:SetPoint("TOPLEFT", 0, y)
    label:SetWidth(COLUMN)
    label:SetText(text)
    local line = app.Surface:HLine(parent, 0.3)
    line:SetPoint("TOPLEFT", 0, y - 15)
    line:SetWidth(COLUMN)
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

-- The module pages live in UI/SettingsModules.lua and share these builders.
SettingsUI.kit = {
    note = note, noteHeight = noteHeight, section = section,
    settingsControl = settingsControl, refreshStateful = refreshStateful,
}

function SettingsUI:Result(ok, message)
    if not ok and message then app:Print(message) end
end

function SettingsUI:BuildOverview(page)
    local scroll = Controls:Scroll(page, CONTENT, PAGE_HEIGHT - 4)
    scroll:SetPoint("TOPLEFT")
    local body = CreateFrame("Frame", nil, scroll)
    body:SetSize(COLUMN, PAGE_HEIGHT - 4)
    scroll:SetScrollChild(body)
    page.scroll = scroll
    -- 019: the whole overview is one card. The rows keep their own x=0 anchors
    -- and the y cursor keeps measuring them, so the card is the container and
    -- the page's existing flow is untouched. `paddingX = 0` is what makes that
    -- true: with a 14 px inset every row would shift right by 14.
    local card = Controls:Card(cardBody, L.overview, nil, { paddingX = 0 })
    page.card = card
    local cardBody = card.body
    local updates = {}
    local function get(key) return app.Store:Profile().appearance[key] end
    local function set(key, value) self:Result(app.Store:Set("appearance", key, value)) end
    local hint = note(cardBody, L.generalHint, 0, COLUMN)
    local y = -noteHeight(hint, 26)
    -- 018 Step 3: the profile this character uses may still carry the geometry
    -- of the previous composition. Offer a copy on the new screen, and a way
    -- back once it was adopted; both buttons exist only when they can act.
    local tryScreen = settingsControl(page, Controls:Button(cardBody, L.screenTry, 220, function()
        local name, problem = app.Store:TryNewScreen()
        if name then
            self:Result(true, string.format(L.screenAdopted, name))
        else
            self:Result(false, problem or L.readonly)
        end
        self:Update()
    end))
    tryScreen:SetPoint("TOPLEFT", 0, y)
    local backScreen = settingsControl(page, Controls:Button(cardBody, L.screenBack, 220, function()
        local ok, problem = app.Store:ReturnToSource()
        self:Result(ok, ok and L.screenReturned or (problem or L.readonly))
        self:Update()
    end))
    backScreen:SetPoint("TOPLEFT", 230, y)
    page.screenTry, page.screenBack = tryScreen, backScreen
    page.screenLabel = note(cardBody, "", 0, COLUMN)
    page.screenLabel:SetPoint("TOPLEFT", 0, y - 34)
    y = y - 34 - noteHeight(page.screenLabel, 30) - 12
    section(cardBody, L.sectionSize, y)
    y = y - 22
    updates[#updates + 1] = settingsControl(page,
        Controls:Range(cardBody, L.scale, y, 0.7, 1.5, 0.05, function() return get("scale") end,
            function(v) set("scale", v) end, { width = COLUMN }))
    y = y - RANGE_STEP
    section(cardBody, L.sectionMotion, y)
    y = y - 22
    updates[#updates + 1] = settingsControl(page,
        Controls:Toggle(cardBody, L.motion, y, function() return get("motion") end, function(v) set("motion", v) end,
            { width = COLUMN }))
    y = y - 40
    updates[#updates + 1] = settingsControl(page,
        Controls:Toggle(cardBody, L.reduceMotion, y, function() return get("reduceMotion") end,
            function(v) set("reduceMotion", v) end, { width = COLUMN }))
    y = y - 44
    section(cardBody, L.sectionOpacity, y)
    y = y - 22
    updates[#updates + 1] = settingsControl(page,
        Controls:Range(cardBody, L.windowOpacity, y, 0.45, 1, 0.05, function() return get("windowOpacity") end,
            function(v) set("windowOpacity", v) end, { width = COLUMN }))
    y = y - RANGE_STEP
    updates[#updates + 1] = settingsControl(page,
        Controls:Range(cardBody, L.hudOpacity, y, 0.15, 1, 0.05, function() return get("hudOpacity") end,
            function(v) set("hudOpacity", v) end, { width = COLUMN }))
    y = y - RANGE_STEP
    y = y - 4
    section(cardBody, L.sectionAccent, y)
    y = y - 22
    local pearl = settingsControl(page, Controls:Button(cardBody, L.pearl, 140, function() set("accent", "pearl") end))
    pearl:SetPoint("TOPLEFT", 0, y)
    local ocean = settingsControl(page, Controls:Button(cardBody, L.ocean, 140, function() set("accent", "ocean") end))
    ocean:SetPoint("TOPLEFT", 148, y)
    local ember = settingsControl(page, Controls:Button(cardBody, L.ember, 140, function() set("accent", "ember") end))
    ember:SetPoint("TOPLEFT", 296, y)
    y = y - 40
    section(cardBody, L.sectionStatus, y)
    y = y - 22
    page.statusLabel = note(cardBody, "", y, COLUMN)
    page.statusHeight = 40
    y = y - 44
    local diagnostics = Controls:Button(cardBody, L.openDiagnostics, 180, function() self:Select("diagnostics") end)
    diagnostics:SetPoint("TOPLEFT", 0, y)
    page.diagButton = diagnostics
    y = y - 44
    page.instructions = note(cardBody, L.instructions, y, COLUMN)
    y = y - noteHeight(page.instructions, 44)
    section(cardBody, L.sectionCompatibility, y)
    y = y - 22
    updates[#updates + 1] = settingsControl(page,
        Controls:Range(cardBody, L.legacyOpacity, y, 0.45, 1, 0.05, function() return get("opacity") end,
            function(v) set("opacity", v) end, { width = COLUMN }))
    y = y - RANGE_STEP
    page.compatibilityHint = note(cardBody, L.compatibilityHint, y, COLUMN)
    y = y - noteHeight(page.compatibilityHint, 34)
    -- Components that no module page claims (an optional extension registered
    -- after the window was built) are still switchable from here.
    page.rows = {}
    local extensionTop = y
    body:SetHeight(math.max(PAGE_HEIGHT - 4, -y + 34))
    page.Update = function()
        local unclaimed = 0
        for _, id in ipairs(app.order) do
            if not self:ModuleOf(id) then
                unclaimed = unclaimed + 1
                local row = page.rows[id]
                if not row then
                    local component = app.components[id]
                    local label = type(component.label) == "string" and component.label or id
                    row = Controls:Toggle(cardBody, L[label], 0,
                        function() return app.Store:Profile().modules[id] == true end,
                        function(v) self:Result(app.Store:Set("modules", id, v)) end,
                        { width = COLUMN, component = component })
                    page.rows[id] = row
                    settingsControl(page, row)
                end
                row:ClearAllPoints()
                row:SetPoint("TOPLEFT", 0, extensionTop - 22 - (unclaimed - 1) * 38)
                row:Update(app.components[id])
            end
        end
        -- The heading and its rule exist only once something needs them.
        if unclaimed > 0 and not page.extensionHeading then
            page.extensionHeading = section(cardBody, L.sectionExtensions, extensionTop)
        end
        card:ClearAllPoints()
        card:SetPoint("TOPLEFT", 0, 0)
        card:SetWidth(COLUMN)
        card:Layout(-extensionTop + 8 + unclaimed * 38)
        body:SetHeight(math.max(PAGE_HEIGHT - 4, card:GetHeight() + 34))
        for _, control in ipairs(updates) do control:Update() end
        -- The two screen buttons follow the profile, not a one-time session
        -- flag: a legacy profile offers the copy, an adopted one the way back,
        -- and neither shows when it would do nothing.
        local legacy = app.Store:IsLegacyScreen()
        local back = app.Store:ScreenReturn()
        local readonly = app.Store.readonly
        tryScreen:SetShown(legacy and not readonly)
        backScreen:SetShown(back ~= nil and not readonly)
        tryScreen:SetEnabled(not readonly)
        backScreen:SetEnabled(not readonly)
        if legacy then
            local keys = app.Store:LegacyKeys()
            page.screenLabel:SetText(string.format(L.screenLegacyHint, #keys))
        elseif back then
            page.screenLabel:SetText(string.format(L.screenAdoptedHint, back.from))
        else
            page.screenLabel:SetText("")
        end
        local summary = self:ModuleSummary()
        page.statusLabel:SetText(summary)
        for _, control in ipairs(page.settings or {}) do
            if control.SetEnabled then control:SetEnabled(not readonly) end
        end
        scroll:UpdateRange()
    end
end

function SettingsUI:BuildProfiles(page)
    -- One scroll area: the profile list, then the layout presets that act on the
    -- whole profile. Long translations grow the page instead of covering rows.
    local scroll = Controls:Scroll(page, CONTENT, PAGE_HEIGHT - 4)
    scroll:SetPoint("TOPLEFT")
    local body = CreateFrame("Frame", nil, scroll)
    body:SetSize(COLUMN, PAGE_HEIGHT - 4)
    scroll:SetScrollChild(body)
    page.scroll = scroll
    note(body, L.profileHint, -2, COLUMN)
    local readonlyNote = note(body, L.readonlyNote, -30, COLUMN)
    readonlyNote:Hide()
    self.readonlyNote = readonlyNote
    self.currentLabel = note(body, "", -64)
    note(body, L.profileName, -92)
    local input = Controls:Input(body, 482)
    input:SetPoint("TOPLEFT", 6, -114)
    local function create(copy)
        self:Result(app.Store:Create(input:GetText(), copy))
        input:ClearFocus()
        self.confirmDelete, self.confirmReset = nil, nil
        self:Update()
    end
    local blank = Controls:Button(body, L.create, 150, function() create(false) end)
    blank:SetPoint("TOPLEFT", 0, -152)
    local duplicate = Controls:Button(body, L.copy, 150, function() create(true) end)
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
        local row = CreateFrame("Frame", nil, body)
        row:SetSize(COLUMN, 28)
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
    local previous = Controls:Button(body, "<", 42, function()
        self.profileOffset = math.max(0, self.profileOffset - 5)
        self:Update()
    end)
    previous:SetPoint("TOPLEFT", 0, -360)
    local following = Controls:Button(body, ">", 42, function()
        if self.profileOffset + 5 < #app.Store:Names() then self.profileOffset = self.profileOffset + 5 end
        self:Update()
    end)
    following:SetPoint("TOPLEFT", 52, -360)
    local reset = Controls:Button(body, L.resetProfile, 230, function()
        if self.confirmReset then
            self.confirmReset = nil
            self:Result(app.Store:Reset(false))
        else
            self.confirmReset = true
            self:Update()
        end
    end)
    reset:SetPoint("TOPRIGHT", 0, -360)
    section(body, L.sectionPresets, -402)
    local presets = self:BuildPresets(page, body)
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
        local bottom = presets(-424)
        body:SetHeight(math.max(420, -bottom + 6))
        scroll:UpdateRange()
    end
end

function SettingsUI:BuildDiagnostics(page)
    local scroll = Controls:Scroll(page, CONTENT, PAGE_HEIGHT - 4)
    scroll:SetPoint("TOPLEFT", 0, -2)
    local body = CreateFrame("Frame", nil, scroll)
    body:SetSize(COLUMN, PAGE_HEIGHT - 4)
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
        local header = Controls:FoldHeader(body, title, COLUMN, function(folded)
            setSection(section, not folded)
        end)
        local text = app.Theme:TextRole(body, "muted")
        text:SetWidth(COLUMN)
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
    addSection("coexistence", L.diagCoexistence, false)
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
        body:SetHeight(math.max(PAGE_HEIGHT - 4, y + 6))
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
        -- Per-control ownership table: intent, active displayer, evidence and
        -- the reason a native path was kept are reported separately from the
        -- component prose above (012 phase 01).
        if app.Ownership then
            for _, line in ipairs(app.Ownership:Lines()) do native[#native + 1] = line end
        end
        if #native == 0 then native[1] = L.nativeNone end
        local coexistence = {}
        -- The addon census is advisory only: it names what else is in the
        -- session, sorted with loaded entries first, so two HUDs drawing over
        -- one area can be attributed from the diagnostics page. Addon names and
        -- titles are plain client data, not secret unit identity.
        do
            local addons = {}
            local numAddons = type(C_AddOns) == "table" and type(C_AddOns.GetNumAddOns) == "function"
                and C_AddOns.GetNumAddOns() or 0
            local loadable = type(C_AddOns) == "table" and type(C_AddOns.IsAddOnLoaded) == "function"
            for index = 1, numAddons do
                local name, title = C_AddOns.GetAddOnInfo(index)
                name = app.Capabilities.Plain(name, "string")
                if name and name ~= app.name then
                    -- IsAddOnLoaded returns loadedOrLoading, loaded; loading
                    -- counts as loaded here so an in-flight addon is still named.
                    local loaded = false
                    if loadable then
                        local loadedOrLoading = C_AddOns.IsAddOnLoaded(name)
                        loaded = loadedOrLoading == true
                    end
                    addons[#addons + 1] = {
                        name = name,
                        title = app.Capabilities.Plain(title, "string") or name,
                        loaded = loaded == true,
                    }
                end
            end
            table.sort(addons, function(a, b)
                if a.loaded ~= b.loaded then return a.loaded end
                return a.name < b.name
            end)
            if #addons == 0 then
                coexistence[1] = L.diagCoexistenceNone
            else
                for _, entry in ipairs(addons) do
                    coexistence[#coexistence + 1] = entry.name .. " (" .. entry.title .. ") · "
                        .. (entry.loaded and L.diagCoexistenceLoaded or L.diagCoexistenceAbsent)
                end
            end
        end
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
        page.bodies.coexistence:SetText(table.concat(coexistence, "\n"))
        page.bodies.errors:SetText(table.concat(errors, "\n"))
        sections[1].header:SetText(L.diagStatus)
        sections[2].header:SetText(L.diagNative)
        sections[3].header:SetText(L.diagCoexistence)
        sections[4].header:SetText((#app.errors > 0 and (L.diagErrors .. "  ·  " .. #app.errors)) or L.diagErrors)
        reflow()
    end
end

function SettingsUI:Build()
    local frame = CreateFrame("Frame", "LumaUISettings", UIParent, "BackdropTemplate")
    self.frame = frame
    frame:Hide()
    frame:SetSize(self.WIDTH, self.HEIGHT)
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
        for _, page in pairs(self.pages) do app.Transitions:Settle(page, "page") end
        if self.frame then self.frame:SetAlpha(0) end
        if self.profileInput then self.profileInput:ClearFocus() end
        if app.Controls then app.Controls:ClearFocus() end
        self:HideSearchResults()
        self.confirmDelete, self.confirmReset = nil, nil
    end)
    UISpecialFrames[#UISpecialFrames + 1] = "LumaUISettings"
    local theme = app.Theme
    -- Compact header: title and version on one line, one wrapped subtitle, one
    -- rule; the pages start higher than the old 110px header allowed.
    local title = app.Type:Text(frame, "display")
    title:SetPoint("TOPLEFT", theme:Space("lg") + 6, -12)
    title:SetText("LumaUI")
    local version = app.Type:Text(frame, "micro")
    version:SetPoint("LEFT", title, "RIGHT", 8, 0)
    version:SetText(app.version)
    self.versionLabel = version
    local close = Controls:Button(frame, "×", 30, function() self:Close() end)
    close:SetPoint("TOPRIGHT", -14, -12)
    self.closeButton = close
    -- The key hint for the client's own game menu. It is a plain button: the
    -- game menu stays the client's window, and Esc still closes this one through
    -- UISpecialFrames.
    local escape = Controls:Button(frame, L.escMenu, 46, function()
        if type(ToggleGameMenu) == "function" then ToggleGameMenu() end
    end)
    escape:SetPoint("TOPRIGHT", close, "TOPLEFT", -6, 0)
    escape.pulse = true
    self.gameMenuButton = escape
    -- The title bar action: unlock the HUD for on-screen editing from any page.
    -- It calls the same mode as a module page's "Position" button.
    local unlock = Controls:Button(frame, L.unlock, 74, function() self:Unlock() end)
    unlock:SetPoint("TOPRIGHT", escape, "TOPLEFT", -6, 0)
    unlock.pulse = true
    self.unlockButton = unlock
    self:BuildSearch(frame)
    self:WatchDisplay()
    self.rule = app.Theme:Rule(frame)
    self.rule:SetPoint("TOPLEFT", theme:Space("lg") + 6, -62)
    self.rule:SetSize(self.WIDTH - 44, 2)
    -- The navigation sits on an embedded surface: overview, one entry per
    -- module, then profiles. At 880x600 every page fits without a rail; the
    -- scroll container stays because a translated caption can still push the
    -- list past the panel at a large UI scale.
    local nav = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    nav:SetPoint("TOPLEFT", theme:Space("md") + 4, PAGE_TOP)
    nav:SetSize(NAV_WIDTH - 12, PAGE_HEIGHT + 14)
    nav:EnableMouse(false)
    self.navPanel = nav
    local navScroll = Controls:Scroll(frame, NAV_WIDTH - 34, PAGE_HEIGHT + 6)
    navScroll:SetPoint("TOPLEFT", nav, "TOPLEFT", 6, -8)
    local navBody = CreateFrame("Frame", nil, navScroll)
    navScroll:SetScrollChild(navBody)
    self.navScroll, self.navBody = navScroll, navBody
    self.navigation = {}
    self.navLabels = {}
    -- Page order stays a flat list of page ids (overview, every module, profiles);
    -- the group headings are real fold buttons and never become pages. Each group
    -- remembers whether it is open; entering a page opens only its own group, so
    -- the list never jumps under the pointer.
    self.navOrder = { "overview" }
    self.navFold = self.navFold or {}
    local labels = { overview = L.overview, profiles = L.profiles }
    for _, entry in ipairs(self.registry) do labels[entry.id] = L[entry.label] end
    self.navGroups_ = self.navGroups_
        or (function()
            local map = {}
            for _, group in ipairs(self.navGroups) do map[group.id] = true end
            return map
        end)()
    local rowY = 0
    local function addPage(key)
        local button = Controls:Navigation(navBody, labels[key], NAV_WIDTH - 40, function() self:Select(key) end)
        button:SetPoint("TOPLEFT", 0, -rowY)
        self.navigation[key] = button
        -- A 28 px row plus a 2 px gap fits all 17 entries in the 452 px column
        -- without the rail the old 30 px rows needed.
        rowY = rowY + 28
    end
    -- Groups are plain captions, not folds. The whole list fits one screen, so
    -- a collapsed group would only add a click between the player and a page.
    local folds = {}
    local function addGroup(id, labelKey)
        local heading = app.Type:Text(navBody, "micro")
        heading:SetPoint("TOPLEFT", 10, -(rowY + 8))
        heading:SetText(L[labelKey])
        heading.key = id
        heading.pages = {}
        self.navLabels[#self.navLabels + 1] = heading
        folds[id] = heading
        rowY = rowY + 24
    end
    -- Kept as a no-op hook so page selection never has to special-case folding.
    local function expandOwn() end
    addPage("overview")
    for _, group in ipairs(self.navGroups) do
        addGroup(group.id, group.label)
        for _, entry in ipairs(self.registry) do
            if entry.group == group.id then
                self.navOrder[#self.navOrder + 1] = entry.id
                folds[group.id].pages[#folds[group.id].pages + 1] = entry.id
                addPage(entry.id)
            end
        end
    end
    -- Profiles and diagnostics are not module groups: they act on the whole
    -- profile, so they live at the bottom of the navigation on their own row.
    self.navOrder[#self.navOrder + 1] = "diagnostics"
    addPage("diagnostics")
    self.navOrder[#self.navOrder + 1] = "profiles"
    addPage("profiles")
    self.navFolds = folds
    self.navExpandOwn = expandOwn
    navBody:SetSize(NAV_WIDTH - 40, rowY + 4)
    navScroll:UpdateRange()
    self.footer = note(frame, "", PAGE_TOP - PAGE_HEIGHT - 6, CONTENT)
    self.footer:ClearAllPoints()
    self.footer:SetPoint("BOTTOMLEFT", PAGE_LEFT, 16)
    self:Select(self.active)
end

-- Pages build on first visit: the window opens with one page's worth of
-- controls instead of every module's, and a page that fails to build is
-- reported without taking the window with it.
function SettingsUI:EnsurePage(key)
    if self.pages[key] then return self.pages[key] end
    local page = CreateFrame("Frame", nil, self.frame)
    page:SetPoint("TOPLEFT", PAGE_LEFT, PAGE_TOP)
    page:SetSize(CONTENT, PAGE_HEIGHT)
    page:Hide()
    self.pages[key] = page
    local ok
    if key == "overview" then ok = app:Call("settings/overview", self.BuildOverview, self, page)
    elseif key == "profiles" then ok = app:Call("settings/profiles", self.BuildProfiles, self, page)
    elseif key == "diagnostics" then ok = app:Call("settings/diagnostics", self.BuildDiagnostics, self, page)
    elseif self.moduleByID[key] then ok = app:Call("settings/module", self.BuildModule, self, page, self.moduleByID[key])
    end
    if not ok then page.failed = true end
    return page
end

function SettingsUI:Select(key)
    key = PAGE_ALIAS[key] or key
    if key ~= "diagnostics" and key ~= "overview" and key ~= "profiles" and not self.moduleByID[key] then
        key = "overview"
    end
    local previous = self.pages[self.active]
    self.active = key
    local page = self:EnsurePage(key)
    -- Each page keeps its own scroll position for the session; switching pages
    -- never repositions another page.
    if previous and previous ~= page then
        app.Transitions:Settle(previous)
        -- A page owns its own controls, and a control may own a one-shot motion
        -- (the segmented highlight, a cell's proc pulse). Those are settled here,
        -- at the one place a page is left, so nothing keeps running behind a
        -- hidden page.
        if previous.preview then
            app.Transitions:Settle(previous.preview)
            for _, cell in ipairs(previous.preview.cells or {}) do app.Transitions:Settle(cell) end
        end
        if previous.segmented then app.Transitions:Settle(previous.segmented) end
        if previous.scroll then app.Transitions:Settle(previous.scroll) end
        if previous == self.pages.profiles and self.profileInput then self.profileInput:ClearFocus() end
        app.Controls:ClearFocus()
    end
    for name, current in pairs(self.pages) do current:SetShown(name == self.active) end
    -- The group that owns the page opens; every other group keeps the state the
    -- player left it in. Groups cannot jump under the pointer this way.
    if self.navExpandOwn then self.navExpandOwn(self) end
    if self.navigation then
        for key, button in pairs(self.navigation) do
            if button.SetSelected then button:SetSelected(key == self.active) end
        end
    end
    if page and previous ~= page and self.frame and self.frame:IsShown() then
        -- A 2 px lift instead of the old 4: the new page settles under the
        -- header rather than sliding up into it. Motion off lands on the final
        -- position in the same pass.
        local targetTop = PAGE_TOP
        page:SetAlpha(0)
        page:ClearAllPoints()
        page:SetPoint("TOPLEFT", self.frame, "TOPLEFT", PAGE_LEFT, targetTop - 2)
        app.Transitions:Animate(page, "page", {
            from = 0, to = 1, duration = 0.14,
            apply = function(value)
                page:SetAlpha(value)
                page:ClearAllPoints()
                page:SetPoint("TOPLEFT", self.frame, "TOPLEFT", PAGE_LEFT, targetTop - 2 * (1 - value))
            end,
        })
    end
    self:Update()
end

-- Keep the applied alpha as the start of a reversal. Native Alpha animations
-- can leave GetAlpha reporting the base value while their visual alpha changes.
function SettingsUI:FadeWindow(target, duration, onDone)
    local frame = self.frame
    app.Transitions:Animate(self, "open", {
        from = frame:GetAlpha(), to = target, duration = duration,
        apply = function(value) frame:SetAlpha(value) end,
        onDone = onDone,
    })
end

function SettingsUI:Update()
    if not self.frame then return end
    -- A window is a card: rounded, softly shadowed, and with no hairline around it.
    -- The old backdrop wrapped the whole window in a 1px edge, which is what made it
    -- read as a flat page rather than as a surface floating over the world.
    app.Surface:Plate(self.frame, "card")
    if self.navPanel then app.Surface:Plate(self.navPanel, "inset") end
    local c = app.Theme:Accent()
    self.rule:SetColorTexture(c[1], c[2], c[3])
    local highlighted = self.active == "diagnostics" and "overview" or self.active
    for key, button in pairs(self.navigation) do
        -- Selected state is part of the control's own resolution, so a mouse
        -- leave can never reset the current page's accent (R03).
        button:SetSelected(key == highlighted)
    end
    local page = self.pages[self.active]
    if page and page.Update and not page.failed then app:Call("settings/update", page.Update) end
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
    self:FitToScreen()
    self.wantsOpen = true
    if page then self:Select(page) end
    if not frame:IsShown() then
        frame:SetAlpha(0)
        frame:Show()
    end
    self:FadeWindow(1, 0.18)
end

function SettingsUI:Close()
    local frame = self.frame
    if not frame or not frame:IsShown() then return end
    self.wantsOpen = false
    -- A closing window must not keep keyboard focus.
    if app.Controls then app.Controls:ClearFocus() end
    if self.profileInput then self.profileInput:ClearFocus() end
    self:FadeWindow(0, 0.13, function()
        -- A reopen replaces the task, so this callback only runs for the final
        -- close request; the intent flag is a second guard.
        if self.wantsOpen then return end
        if self.frame and self.frame:IsShown() then self.frame:Hide() end
    end)
end

-- The title-bar action. Phase 05 turns this into the on-screen unlock mode;
-- the settings window stays reachable through the same Toggle.
function SettingsUI:Unlock()
    return app.Unlock:Toggle({ page = self.active })
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
