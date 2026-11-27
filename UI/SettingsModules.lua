local _, app = ...
local L, Controls = app.L, app.Controls
local SettingsUI = app.Settings
local kit = SettingsUI.kit
local note, noteHeight, section, settingsControl = kit.note, kit.noteHeight, kit.section, kit.settingsControl

-- Navigation order for the settings window. Page ids and component ids are
-- separate on purpose: a page can manage several runtime components (chat and
-- chat tabs, bags and bank) and a component never needs a page of its own just
-- because it can be switched. Every component named in `components` gets one
-- switch on its page; a test asserts that no registered component is missing.
SettingsUI.registry = {
    -- Combat
    { id = "actionBars", group = "combat", label = "navActionBars", extras = "ActionBars",
      components = { "actionBars", "ownedBars", "actionButtons", "actionPanel" } },
    { id = "unitFrames", group = "combat", label = "navUnitFrames", extras = "UnitFrames",
      components = { "unitFrames" } },
    { id = "cooldowns", group = "combat", label = "navCooldowns", extras = "Cooldowns",
      components = { "cooldownGroups", "cooldownViewer" } },
    { id = "resources", group = "combat", label = "navResources", extras = "Resources",
      components = { "playerResource", "playerCast", "edgeAuras" } },
    { id = "groups", group = "combat", label = "navGroups", extras = "Groups", components = { "partyFrames", "raidFrames", "clickCast" } },
    { id = "nameplates", group = "combat", label = "navNameplates", components = { "nameplates" } },
    -- World
    { id = "chat", group = "world", label = "navChat", extras = "Chat",
      components = { "chat", "chatTabs", "chatView" } },
    { id = "minimap", group = "world", label = "navMinimap", extras = "Tools",
      components = { "minimap", "launcher", "gameMenu", "utilityCorner" } },
    { id = "quests", group = "world", label = "navQuests", extras = "Quests",
      components = { "questTracker", "questIndicators", "questList" } },
    { id = "containers", group = "world", label = "navContainers", extras = "Containers",
      components = { "inventory", "bank" } },
    -- Windows
    { id = "windows", group = "windows", label = "navWindows", components = { "characterWindow", "systemWindows" } },
    { id = "info", group = "windows", label = "navInfo", extras = "Info",
      components = { "dataStrip", "experience", "topPerformance" } },
    { id = "meter", group = "windows", label = "navMeter", components = { "damageMeterArea", "damageMeter", "combatText" } },
    { id = "tooltip", group = "windows", label = "navTooltip", extras = "Tooltip", components = { "tooltip" } },
}
-- Navigation groups, in display order. The overview sits above them and the
-- profiles page forms the last group on its own.
SettingsUI.navGroups = {
    { id = "combat", label = "navGroupCombat" },
    { id = "world", label = "navGroupWorld" },
    { id = "windows", label = "navGroupWindows" },
}
SettingsUI.moduleByID = {}
for _, entry in ipairs(SettingsUI.registry) do SettingsUI.moduleByID[entry.id] = entry end

-- The one place that says which page owns a component, for tests and for the
-- diagnostics page.
function SettingsUI:ModuleOf(componentID)
    for _, entry in ipairs(self.registry) do
        for _, id in ipairs(entry.components) do
            if id == componentID then return entry.id end
        end
    end
end

-- Overview line: current profile, plus how many components need attention.
function SettingsUI:ModuleSummary()
    local count = 0
    for _, id in ipairs(app.order) do
        local status = app.components[id].status
        if status == "failed" or status == "unsupported" or status == "dependency" then count = count + 1 end
    end
    local text = count > 0 and string.format(L.modulesIssues, count) or L.modulesHealthy
    return L.active .. ": " .. app.Store.current .. "\n" .. text
end

-- A module's status in one short sentence. Technical detail — which sub-part,
-- which ownership record, which evidence level — stays on the diagnostics page;
-- this line answers "can I use the page I am looking at".
function SettingsUI:ModuleStatus(entry)
    local running, failed, unsupported, disabled = 0, 0, 0, 0
    for _, id in ipairs(entry.components or {}) do
        local component = app.components[id]
        if component then
            local status = component.status
            if status == "running" then running = running + 1
            elseif status == "failed" then failed = failed + 1
            elseif status == "unsupported" then unsupported = unsupported + 1
            else disabled = disabled + 1 end
        end
    end
    if app.Store.readonly then return L.moduleStatusReadonly end
    if failed > 0 then return string.format(L.moduleStatusFailed, failed) end
    if unsupported > 0 then return string.format(L.moduleStatusUnsupported, unsupported) end
    if running > 0 then return string.format(L.moduleStatusRunning, running) end
    return L.moduleStatusOff
end

local function ownerText(entry)
    local lines = {}
    if app.Ownership then
        for _, id in ipairs(entry.components) do
            for _, line in ipairs(app.Ownership:Matching(id)) do lines[#lines + 1] = line end
        end
    end
    if #lines == 0 then return L.moduleOwnerNone end
    return L.moduleOwner .. "\n" .. table.concat(lines, "\n")
end

local function profileUI() return app.Store:Profile().ui end

-- Names a control so search can scroll to it: page.fields[id] is the control.
local function field(page, id, control)
    page.fields = page.fields or {}
    page.fields[id] = control
    return control
end

local function simpleToggle(body, text, getter, setter)
    return Controls:Toggle(body, text, 0, getter, setter, { width = 462 })
end

----------------------------------------------------------------------
-- Selectable objects
----------------------------------------------------------------------
-- A module page starts with "which object am I editing". The list is the real
-- layout/handle or catalog set; an object that is disabled this run is still
-- listed (its controls say so) instead of disappearing and silently moving the
-- selection to something else.
local Objects = {}

function Objects.actionBars()
    local list = {}
    for _, bar in ipairs(app.BarModel:NativeFixed()) do
        list[#list + 1] = { id = bar.key, label = string.format(L.actionBarLabel, bar.display), bar = bar }
    end
    -- Contextual bars are objects too, so each has its own entry; they only
    -- explain where the client places them (no capacity or size controls).
    for _, bar in ipairs(app.BarModel.native) do
        if bar.kind ~= "main" and bar.kind ~= "fixed" then
            list[#list + 1] = { id = bar.key, label = L["actionBarContext_" .. bar.kind] or bar.key, bar = bar }
        end
    end
    return list
end

-- Party and raid are two independent objects even while their layout entries
-- are not built yet (the components are off by default).
function Objects.groups()
    return {
        { id = "party", label = L.partyGroup },
        { id = "raidFrames", label = L.raidFrames },
    }
end

function Objects.unitFrames()
    local list, seen = {}, {}
    for _, unit in ipairs({ "player", "target", "focus", "pet", "targettarget" }) do
        local id = "unit_" .. unit
        if app.Layout.entries[id] and not seen[id] then
            seen[id] = true
            local label = L["object_" .. unit] or unit
            list[#list + 1] = { id = id, label = label }
        end
    end
    return list
end

function Objects.cooldowns()
    local list = {}
    for _, id in ipairs(app.CooldownModel.GROUP_IDS) do
        local label = id == "essential" and L.hudGroupEssential
            or (id == "utility" and L.hudGroupUtility or L.hudGroupBuffs)
        list[#list + 1] = { id = "cdGroup_" .. id, label = label, group = id }
    end
    return list
end

function Objects.chat()
    local list = {}
    for _, id in ipairs(app.Layout:IDs()) do
        if id:sub(1, 4) == "chat" and not (app.Layout.entries[id] or {}).member then
            list[#list + 1] = { id = id, label = L.viewLabel or L.navChat }
            break
        end
    end
    return list
end

function SettingsUI:ObjectList(moduleID)
    local provider = Objects[moduleID]
    if provider then
        local ok, list = pcall(provider)
        if ok and type(list) == "table" then return list end
        return {}
    end
    -- Modules without a dedicated object list fall back to their own layout
    -- handles, so "Position" still targets something real.
    local list = {}
    local entry = self.moduleByID[moduleID]
    for _, component in ipairs(entry and entry.components or {}) do
        local layoutEntry = app.Layout.entries[component]
        if layoutEntry and not layoutEntry.member then
            list[#list + 1] = { id = component, label = layoutEntry.label or component }
        end
    end
    return list
end

function SettingsUI:SelectedObject(moduleID)
    local list = self:ObjectList(moduleID)
    self.moduleObject = self.moduleObject or {}
    local wanted = self.moduleObject[moduleID]
    for _, object in ipairs(list) do
        if object.id == wanted then return wanted end
    end
    return list[1] and list[1].id or nil
end

function SettingsUI:SelectObject(moduleID, id)
    self.moduleObject = self.moduleObject or {}
    local page = self.pages[moduleID]
    local previous = self:SelectedObject(moduleID)
    if page and page.scroll and page.scrollMemory and previous ~= id then
        -- Each object keeps its own reading position; the first visit starts at
        -- the top.
        if previous ~= nil then page.scrollMemory[previous] = page.scroll:GetVerticalScroll() or 0 end
    end
    self.moduleObject[moduleID] = id
    self:Update()
    if page and page.scroll and page.scrollMemory and previous ~= id then
        page.scroll:ScrollTo(page.scrollMemory[id] or 0)
    end
end

-- The real bar entry behind the selected action-bar object (nil when the
-- selection is not a bar).
function SettingsUI:SelectedBar(moduleID)
    local id = self:SelectedObject(moduleID or "actionBars")
    return id and app.BarModel:Native(id) or nil
end

----------------------------------------------------------------------
-- Per-module controls
----------------------------------------------------------------------
-- Each builder returns a function that lays its controls out from `top` and
-- returns the next free offset; the page calls it on every refresh so a profile
-- switch or a long translation never leaves stale spacing.
local Extras = {}

-- Action bars: object first (1–8), then the real controls for that bar. Bars
-- 1–3 also carry LumaUI's own scale; bars 4–8 keep the client's position and
-- gain capacity, rows, size, spacing and visibility through the safe adapter.
function Extras.ActionBars(page, body)
    local self = SettingsUI
    local scope = note(body, L.actionBarScopeHint, 0, 462)
    local function bar()
        return self:SelectedBar("actionBars")
    end
    local function barID() return bar() and bar().id or 1 end
    local function layoutKey(key)
        local layouts = profileUI().actionBarLayout
        local spec = layouts and layouts[barID()]
        return spec and spec[key]
    end
    local function stage(key, value)
        local slot = barID()
        local current = app.Store.Clone(profileUI().actionBarLayout or {})
        local spec = current[slot] or {}
        spec[key] = value
        current[slot] = spec
        self:Result(app.Store:Set("ui", "actionBarLayout", current))
        self:Update()
    end
    local function countLabel(number)
        if number < 0.5 then return L.followClient end
        return string.format("%d", math.floor(number + 0.5))
    end
    local controls = {
        -- 0 is "the client's own value": the control is a real choice, not a
        -- reset that silently writes 12.
        buttons = Controls:Range(body, L.actionBarButtons, 0, 0, 12, 1,
            function() return layoutKey("buttons") or 0 end,
            function(value) stage("buttons", value) end, { width = 462, format = countLabel }),
        rows = Controls:Range(body, L.actionBarRows, 0, 0, 12, 1,
            function() return layoutKey("rows") or 0 end,
            function(value) stage("rows", value) end, { width = 462, format = countLabel }),
        size = Controls:Range(body, L.actionBarSize, 0, 0, 60, 1,
            function() return layoutKey("size") or 0 end,
            function(value) stage("size", value) end, { width = 462, format = countLabel }),
        gap = Controls:Range(body, L.actionBarGap, 0, 0, 12, 1,
            function() return layoutKey("gap") or 4 end,
            function(value) stage("gap", value) end, { width = 462, format = countLabel }),
    }
    for key, control in pairs(controls) do field(page, key, settingsControl(page, control)) end
    local scale = Controls:Range(body, L.actionBarScaleSelected, 0, 0.5, 1.5, 0.05,
        function()
            local index = barID()
            return profileUI().actionBarScales[index] or 1
        end,
        function(value)
            local index = barID()
            local current = app.Store.Clone(profileUI().actionBarScales)
            current[index] = value
            self:Result(app.Store:Set("ui", "actionBarScales", current))
        end, { width = 462 })
    field(page, "scale", settingsControl(page, scale))
    local visibility = {}
    for index, mode in ipairs({ { "always", L.visibilityAlways }, { "combat", L.visibilityCombat },
        { "outofcombat", L.visibilityOutOfCombat }, { "hidden", L.visibilityHidden } }) do
        local key = mode[1]
        visibility[index] = Controls:Button(body, mode[2], 108, function()
            stage("visible", key)
        end)
        visibility[index].mode = key
        settingsControl(page, visibility[index])
        if index == 1 then field(page, "visible", visibility[index]) end
    end
    local hint = note(body, L.actionBarLayoutHint, 0, 462)
    local limits = note(body, L.actionBarMainHint, 0, 462)
    local reset = Controls:Button(body, L.actionBarReset, 200, function()
        local slot = barID()
        -- Dot call: `Store:Clone(x)` clones the Store itself, so this reset used
        -- to drop every other bar's saved override instead of only this slot.
        local current = app.Store.Clone(profileUI().actionBarLayout or {})
        current[slot] = nil
        self:Result(app.Store:Set("ui", "actionBarLayout", current))
        if profileUI().actionBarScales[slot] then
            local scales = app.Store.Clone(profileUI().actionBarScales)
            scales[slot] = 1
            self:Result(app.Store:Set("ui", "actionBarScales", scales))
        end
        self:Update()
    end)
    settingsControl(page, reset)
    local editMode = Controls:Button(body, L.openEditMode, 200, function()
        if EditModeManagerFrame and ShowUIPanel then
            ShowUIPanel(EditModeManagerFrame)
        else
            app:Print(L.editModeUnavailable)
        end
    end)
    self.layoutEditMode = editMode
    settingsControl(page, editMode)
    page.barControls = controls
    page.barScale = scale
    page.barVisibility = visibility
    page.barReset = reset
    page.barLimits = limits
    page.clientOwned = note(body, L.actionBarClientOwnedHint, 0, 462)
    return function(top)
        local readonly = app.Store.readonly
        local entry = bar()
        local managed = entry and entry.manageable
        scope:ClearAllPoints(); scope:SetPoint("TOPLEFT", 0, top)
        top = top - noteHeight(scope, 28)
        -- Only fixed bars 2–8 are rearranged by the safe adapter. Bar 1 and the
        -- contextual bars (pet, stance, extra, zone) ignore these fields at
        -- runtime, so offering them would be a control that does nothing.
        local fixed = entry ~= nil and entry.kind == "fixed"
        for _, key in ipairs({ "buttons", "rows", "size", "gap" }) do
            local control = controls[key]
            control:SetShown(fixed)
            if fixed then
                control:ClearAllPoints(); control:SetPoint("TOPLEFT", 0, top)
                control:Update(); control:SetEnabled(not readonly)
                top = top - 62
            end
        end
        scale:SetShown(managed == true)
        if managed then
            scale:ClearAllPoints(); scale:SetPoint("TOPLEFT", 0, top)
            scale:Update(); scale:SetEnabled(not readonly)
            top = top - 62
        end
        limits:SetShown(not fixed)
        if not fixed then
            limits:SetText(entry and entry.kind == "main" and L.actionBarMainHint or L.actionBarContextHint)
            limits:ClearAllPoints(); limits:SetPoint("TOPLEFT", 0, top)
            top = top - noteHeight(limits, 34)
        end
        local current = layoutKey("visible") or "always"
        for index, button in ipairs(visibility) do
            button:SetShown(fixed)
            button:ClearAllPoints()
            button:SetPoint("TOPLEFT", ((index - 1) % 2) * 116, top - math.floor((index - 1) / 2) * 36)
            button:SetSelected(button.mode == current)
            button:SetEnabled(not readonly and entry ~= nil)
        end
        if fixed then top = top - 76 end
        hint:SetShown(fixed)
        if fixed then
            hint:ClearAllPoints(); hint:SetPoint("TOPLEFT", 0, top)
            top = top - noteHeight(hint, 34)
        end
        reset:SetShown(fixed or managed == true)
        reset:ClearAllPoints(); reset:SetPoint("TOPLEFT", 0, top)
        reset:SetEnabled(not readonly)
        editMode:ClearAllPoints(); editMode:SetPoint("TOPLEFT", 208, top)
        editMode:SetEnabled(not readonly)
        -- Bars 4–8 are the client's: its own visible setting decides whether one
        -- is on screen, so the page says where to turn it off instead of
        -- offering a switch LumaUI would not honour.
        local clientOwned = page.clientOwned
        if clientOwned then
            local owned = entry ~= nil and entry.manageable ~= true
            clientOwned:SetShown(owned)
            if owned then
                clientOwned:ClearAllPoints()
                clientOwned:SetPoint("TOPLEFT", 0, top - 34)
                top = top - noteHeight(clientOwned, 40) - 34
            end
        end
        return top - 42
    end
end

function Extras.Chat(page, body)
    local self = SettingsUI
    local function get(key) return app.Store:Profile().appearance[key] end
    local function set(key, value) self:Result(app.Store:Set("appearance", key, value)) end
    local controls = {
        field(page, "takeover", settingsControl(page, simpleToggle(body, L.chatViewTitle, function()
            return app.Store:Profile().ui.chatTakeover == true
        end, function(v)
            local view = app.components and app.components.chatView
            if view and view.running then
                self:Result(view:SetTakeover(v))
            else
                self:Result(app.Store:Set("ui", "chatTakeover", v))
            end
            self:Update()
        end))),
        field(page, "opacity", settingsControl(page, Controls:Range(body, L.chatOpacity, 0, 0, 1, 0.05,
            function() return get("chatOpacity") end, function(v) set("chatOpacity", v) end, { width = 462 }))),
        settingsControl(page, Controls:Range(body, L.chatActiveOpacity, 0, 0.2, 1, 0.05,
            function() return get("chatActiveOpacity") end, function(v) set("chatActiveOpacity", v) end,
            { width = 462 })),
        field(page, "width", settingsControl(page, Controls:Range(body, L.chatWidthLabel, 0, 240, 600, 10,
            function() return profileUI().chatWidth > 0 and profileUI().chatWidth or 380 end,
            function(value)
                -- One writer saves width and height together and applies them;
                -- two independent writes could leave a half-applied size.
                local chat = app.components and app.components.chat
                local height = profileUI().chatHeight > 0 and profileUI().chatHeight or 140
                if chat and chat.running then
                    self:Result(chat:SetSize(math.floor(value), height))
                else
                    self:Result(app.Store:Set("ui", "chatWidth", math.floor(value)))
                end
            end, { width = 462, format = function(n) return string.format("%d", math.floor(n + 0.5)) end }))),
        field(page, "height", settingsControl(page, Controls:Range(body, L.chatHeightLabel, 0, 100, 400, 10,
            function() return profileUI().chatHeight > 0 and profileUI().chatHeight or 140 end,
            function(value)
                local chat = app.components and app.components.chat
                local width = profileUI().chatWidth > 0 and profileUI().chatWidth or 380
                if chat and chat.running then
                    self:Result(chat:SetSize(width, math.floor(value)))
                else
                    self:Result(app.Store:Set("ui", "chatHeight", math.floor(value)))
                end
            end, { width = 462, format = function(n) return string.format("%d", math.floor(n + 0.5)) end }))),
    }
    return function(top)
        local readonly = app.Store.readonly
        for _, control in ipairs(controls) do
            control:ClearAllPoints(); control:SetPoint("TOPLEFT", 0, top)
            control:Update(); control:SetEnabled(not readonly)
            top = top - 70
        end
        return top
    end
end

function Extras.Containers(page, body)
    local self = SettingsUI
    local toggle = field(page, "takeover", settingsControl(page, simpleToggle(body, L.containerTakeover, function()
        return profileUI().containerTakeover == true
    end, function(v)
        -- One writer for the switch: it also enables the bank component and
        -- prints a confirmation, so the checkbox and `/luma bags takeover`
        -- can never disagree.
        local inventory = app.components and app.components.inventory
        if inventory and inventory.running then
            self:Result(inventory:SetTakeover(v))
        else
            self:Result(app.Store:Set("ui", "containerTakeover", v))
        end
        self:Update()
    end)))
    local hint = note(body, L.containerTakeoverHint, 0, 462)
    page.takeoverHint = hint
    return function(top)
        toggle:ClearAllPoints(); toggle:SetPoint("TOPLEFT", 0, top)
        toggle:Update(); toggle:SetEnabled(not app.Store.readonly)
        top = top - 44
        hint:ClearAllPoints(); hint:SetPoint("TOPLEFT", 0, top)
        return top - noteHeight(hint, 46)
    end
end

-- Unit frames carry no size or colour setting: the module's geometry is derived
-- from the central block. What a player can really choose is which parts of a
-- frame are drawn, so that is what this page offers, per part, with the effect
-- named plainly. A part turned off also releases its row height.
function Extras.UnitFrames(page, body)
    local self = SettingsUI
    local function on(key) return profileUI().unitParts[key] ~= false end
    local function set(key, value)
        local parts = app.Store.Clone(profileUI().unitParts or {})
        parts[key] = value and true or false
        self:Result(app.Store:Set("ui", "unitParts", parts))
        local component = app.components and app.components.unitFrames
        if component and component.running and component.Refresh then component:Refresh() end
        self:Update()
    end
    local controls = {
        cast = field(page, "partsCast", settingsControl(page, simpleToggle(body,
            L.unitPartCast, function() return on("cast") end, function(v) set("cast", v) end))),
        auras = field(page, "partsAuras", settingsControl(page, simpleToggle(body,
            L.unitPartAuras, function() return on("auras") end, function(v) set("auras", v) end))),
        marks = field(page, "partsMarks", settingsControl(page, simpleToggle(body,
            L.unitPartMarks, function() return on("marks") end, function(v) set("marks", v) end))),
    }
    local hint = note(body, L.unitPartsHint, 0, 462)
    return function(top)
        local readonly = app.Store.readonly
        for _, key in ipairs({ "cast", "auras", "marks" }) do
            local control = controls[key]
            control:ClearAllPoints(); control:SetPoint("TOPLEFT", 0, top)
            control:Update(); control:SetEnabled(not readonly)
            top = top - 40
        end
        hint:ClearAllPoints(); hint:SetPoint("TOPLEFT", 0, top)
        return top - noteHeight(hint, 40)
    end
end

-- Native tool hosts (018 Step 2). Two independent switches: "collected" is the
-- new screen, "follow client" leaves the Blizzard bar exactly where it is. The
-- writer is the component, so the switch and `/luma tools` cannot disagree.
function Extras.Tools(page, body)
    local self = SettingsUI
    local corner = function() return app.components and app.components.utilityCorner end
    local function mode(key)
        local tools = profileUI().nativeTools
        return (tools and tools[key] or "collect") == "collect"
    end
    local function set(key, collected)
        local instance = corner()
        if instance and instance.running then
            self:Result(instance:SetHost(key, collected and "collect" or "client"))
        else
            self:Result(app.Store:Set("ui", "nativeTools", (function()
                -- Dot call: `Store:Clone(x)` would clone the Store itself.
                local list = app.Store.Clone(profileUI().nativeTools or {})
                list[key] = collected and "collect" or "client"
                return list
            end)()))
        end
        self:Update()
    end
    local bags = field(page, "bagsBar", settingsControl(page, simpleToggle(body,
        L.nativeToolsBags, function() return mode("bagsBar") end,
        function(value) set("bagsBar", value) end)))
    local micro = field(page, "microMenu", settingsControl(page, simpleToggle(body,
        L.nativeToolsMicro, function() return mode("microMenu") end,
        function(value) set("microMenu", value) end)))
    local noteText = note(body, L.nativeToolsNote, 0, 462)
    local toggle = settingsControl(page, Controls:Button(body, L.nativeToolsExpand, 220, function()
        local instance = corner()
        if instance and instance.running then
            self:Result(instance:ToggleNative())
            self:Update()
        end
    end))
    page.nativeTools = { bags = bags, micro = micro, toggle = toggle }
    return function(top)
        local readonly = app.Store.readonly
        for _, control in ipairs({ bags, micro }) do
            control:ClearAllPoints(); control:SetPoint("TOPLEFT", 0, top)
            control:Update(); control:SetEnabled(not readonly)
            top = top - 44
        end
        noteText:ClearAllPoints(); noteText:SetPoint("TOPLEFT", 0, top)
        top = top - noteHeight(noteText, 34)
        toggle:ClearAllPoints(); toggle:SetPoint("TOPLEFT", 0, top)
        local instance = corner()
        toggle:SetText(instance and instance.expanded and L.nativeToolsCollapse or L.nativeToolsExpand)
        toggle:SetEnabled(not readonly and instance ~= nil and instance.running == true)
        return top - 44
    end
end

function Extras.Info(page, body)
    local self = SettingsUI
    local compact = field(page, "compact", settingsControl(page, simpleToggle(body, L.stripCompact,
        function() return profileUI().stripCompact == true end,
        function(v) self:Result(app.Store:Set("ui", "stripCompact", v)) end)))
    local clockLabel = field(page, "clock", note(body, L.clockOwner, 0, 462))
    page.clockLabel = clockLabel
    local buttons = {}
    -- Exactly one clock: three mutually exclusive choices, none of them a
    -- forced write on login. The current value is read from the profile on
    -- every refresh, so a profile switch repaints the selected button.
    for index, spec in ipairs({ { "strip", L.clockStrip }, { "minimap", L.clockMinimap }, { "off", L.clockOff } }) do
        local key = spec[1]
        local button = settingsControl(page, Controls:Button(body, spec[2], 104, function()
            self:Result(app.Store:Set("ui", "clock", key))
            self:Update()
        end))
        button.slot = index
        buttons[key] = button
    end
    return function(top)
        compact:ClearAllPoints(); compact:SetPoint("TOPLEFT", 0, top)
        compact:Update(); compact:SetEnabled(not app.Store.readonly)
        top = top - 44
        clockLabel:ClearAllPoints(); clockLabel:SetPoint("TOPLEFT", 0, top)
        top = top - noteHeight(clockLabel, 20)
        local current = profileUI().clock
        for key, button in pairs(buttons) do
            button:ClearAllPoints(); button:SetPoint("TOPLEFT", (button.slot - 1) * 112, top)
            button:SetSelected(key == current)
            button:SetEnabled(not app.Store.readonly)
        end
        return top - 42
    end
end

-- Quests: the one layout switch 015 added without an entry. It used to be a save
-- field only; the switch now applies both directions and a manually placed panel
-- keeps its position.
-- Party and raid: the raid grid has real size and spacing settings (0 follows
-- the built-in size). Party rows are joined to the layout at build time, so the
-- party object only shows a note.
function Extras.Groups(page, body)
    local self = SettingsUI
    local function raidSelected() return self:SelectedObject("groups") == "raidFrames" end
    local function raidValue(key)
        local frames = profileUI().groupFrames
        return frames and frames.raid and frames.raid[key] or 0
    end
    local function stage(key, value)
        local frames = app.Store.Clone(profileUI().groupFrames or { raid = {} })
        frames.raid = frames.raid or {}
        frames.raid[key] = value
        self:Result(app.Store:Set("ui", "groupFrames", frames))
        local raid = app.components and app.components.raidFrames
        if raid and raid.running then raid:Refresh() end
        self:Update()
    end
    local function label(number)
        if number < 0.5 then return L.followClient end
        return string.format("%d", math.floor(number + 0.5))
    end
    local controls = {
        width = Controls:Range(body, L.groupRaidWidth, 0, 0, 140, 1,
            function() return raidValue("width") end, function(v) stage("width", v) end,
            { width = 462, format = label }),
        height = Controls:Range(body, L.groupRaidHeight, 0, 0, 48, 1,
            function() return raidValue("height") end, function(v) stage("height", v) end,
            { width = 462, format = label }),
        gap = Controls:Range(body, L.groupRaidGap, 0, 0, 16, 1,
            function() return raidValue("gap") end, function(v) stage("gap", v) end,
            { width = 462, format = label }),
    }
    for key, control in pairs(controls) do field(page, "raid" .. key, settingsControl(page, control)) end
    local hint = note(body, L.groupPartyHint, 0, 462)
    page.groupControls = controls
    page.groupHint = hint
    return function(top)
        local raid = raidSelected()
        for _, key in ipairs({ "width", "height", "gap" }) do
            local control = controls[key]
            control:SetShown(raid)
            if raid then
                control:ClearAllPoints(); control:SetPoint("TOPLEFT", 0, top)
                control:Update(); control:SetEnabled(not app.Store.readonly)
                top = top - 62
            end
        end
        hint:SetShown(not raid)
        if not raid then
            hint:ClearAllPoints(); hint:SetPoint("TOPLEFT", 0, top)
            top = top - noteHeight(hint, 28)
        end
        return top
    end
end

-- Class resources: the two own rows are explicit choices because they replace
-- nothing; the client's displays stay on screen.
function Extras.Resources(page, body)
    local self = SettingsUI
    local function toggleFor(key, label)
        return field(page, key, settingsControl(page, simpleToggle(body, label,
            function() return profileUI()[key == "runes" and "resourceRunes" or "resourceFragments"] == "owned" end,
            function(value)
                local setting = key == "runes" and "resourceRunes" or "resourceFragments"
                self:Result(app.Store:Set("ui", setting, value and "owned" or "native"))
                local resource = app.components and app.components.playerResource
                if resource and resource.running then resource:Refresh() end
                self:Update()
            end)))
    end
    local runes = toggleFor("runes", L.resourceRunesToggle)
    local fragments = toggleFor("fragments", L.resourceFragmentsToggle)
    local arc = field(page, "arc", settingsControl(page, simpleToggle(body, L.resourceArcToggle,
        function() return profileUI().resourceStyle == "arc" end,
        function(value)
            self:Result(app.Store:Set("ui", "resourceStyle", value and "arc" or "line"))
            local resource = app.components and app.components.playerResource
            if resource and resource.running then resource:Refresh() end
            self:Update()
        end)))
    local hint = note(body, L.resourceStyleHint, 0, 462)
    page.resourceToggles = { runes = runes, fragments = fragments, arc = arc }
    return function(top)
        for _, control in ipairs({ runes, fragments, arc }) do
            control:ClearAllPoints(); control:SetPoint("TOPLEFT", 0, top)
            control:Update(); control:SetEnabled(not app.Store.readonly)
            top = top - 44
        end
        hint:ClearAllPoints(); hint:SetPoint("TOPLEFT", 0, top)
        return top - noteHeight(hint, 28)
    end
end

function Extras.Quests(page, body)
    local self = SettingsUI
    local belowMap = field(page, "belowMap", settingsControl(page, simpleToggle(body, L.questBelowMap,
        function() return profileUI().questBelowMap == true end,
        function(value)
            self:Result(app.Store:Set("ui", "questBelowMap", value))
            local quests = app.components and app.components.questList
            if quests and quests.running then quests:Refresh() end
            self:Update()
        end)))
    local hint = note(body, L.questBelowMapHint, 0, 462)
    return function(top)
        belowMap:ClearAllPoints(); belowMap:SetPoint("TOPLEFT", 0, top)
        belowMap:Update(); belowMap:SetEnabled(not app.Store.readonly)
        top = top - 44
        hint:ClearAllPoints(); hint:SetPoint("TOPLEFT", 0, top)
        return top - noteHeight(hint, 28)
    end
end

function Extras.Tooltip(page, body)
    local self = SettingsUI
    local toggle = field(page, "quality", settingsControl(page, simpleToggle(body, L.tooltipQuality,
        function() return app.Store:Profile().appearance.tooltipQuality end,
        function(v) self:Result(app.Store:Set("appearance", "tooltipQuality", v)) end)))
    return function(top)
        toggle:ClearAllPoints(); toggle:SetPoint("TOPLEFT", 0, top)
        toggle:Update(); toggle:SetEnabled(not app.Store.readonly)
        return top - 44
    end
end

-- Cooldown management: the three own groups. Changes are a session draft,
-- previewed at once, written only by Apply and dropped by Cancel.
function Extras.Cooldowns(page, body)
    local self = SettingsUI
    local hudControls = {}
    local hudHeading = note(body, L.hudEditorHint, 0, 462)
    local function groupComponent() return app.components and app.components.cooldownGroups end
    -- The selected object chooses the group; the editor edits that group only.
    local function selectedGroup()
        local id = self:SelectedObject("cooldowns")
        return id and id:match("^cdGroup_(.+)$") or "essential"
    end
    -- The mode switch. Without it the groups never draw, so the editor would
    -- offer geometry for a block the player cannot see.
    local hudOwned = Controls:Toggle(body, L.hudOwned, 0,
        function() return profileUI().cooldownGroups.owned == true end,
        function(wanted)
            local component = groupComponent()
            if component and component.running then self:Result(component:SetOwned(wanted)) end
            self:Update()
        end, { width = 462 })
    -- Tracked buffs are the one Cooldown Manager block LumaUI does not replace,
    -- so hiding them is a separate switch with its own warning.
    local hudBuffs = Controls:Toggle(body, L.hudHideBuffs, 0,
        function() return profileUI().cooldownGroups.hideBuffViewers ~= false end,
        function(wanted)
            local component = groupComponent()
            if component and component.running then self:Result(component:SetHideBuffViewers(wanted)) end
            self:Update()
        end, { width = 462 })
    -- Counts and pixels are not percentages: without a formatter the shared
    -- slider would print an icon size of 26 as "2600%".
    local function countLabel(number) return string.format("%d", math.floor(number + 0.5)) end
    local groupTitles = {
        essential = L.hudGroupEssential, utility = L.hudGroupUtility, buffs = L.hudGroupBuffs,
    }
    for _, groupID in ipairs(app.CooldownModel.GROUP_IDS) do
        local id = groupID
        local function value(key)
            local component = groupComponent()
            return component and component:DraftValue(id, key)
        end
        local function stage(key, wanted)
            local component = groupComponent()
            if component and component.running then component:SetDraft(id, key, wanted) end
            self:Update()
        end
        local title = groupTitles[id] or id
        -- Follow mode is a mode switch, not geometry: written at once.
        local follow = Controls:Toggle(body, title .. " · " .. L.hudFollow, 0,
            function()
                local groups = app.CooldownModel:Normalize(profileUI().cooldownGroups)
                return ((groups.groups[id] or {}).auto ~= false)
            end,
            function(wanted)
                local component = groupComponent()
                if component and component.running then self:Result(component:SetFollow(id, wanted)) end
                self:Update()
            end, { width = 462 })
        local vertical = Controls:Toggle(body, title .. " · " .. L.hudVertical, 0,
            function() return value("vertical") == true end,
            function(wanted) stage("vertical", wanted) end, { width = 462 })
        local function range(key, label, low, high)
            return Controls:Range(body, title .. " · " .. label, 0, low, high, 1,
                function() return value(key) or low end,
                function(wanted) stage(key, wanted) end,
                { width = 462, format = countLabel })
        end
        local model = app.CooldownModel
        hudControls[#hudControls + 1] = { follow = follow, vertical = vertical, id = id,
            max = range("max", L.hudMax, model.maxRange[1], model.maxRange[2]),
            limit = range("limit", L.hudLimit, model.limitRange[1], model.limitRange[2]),
            size = range("size", L.hudSize, model.sizeRange[1], model.sizeRange[2]),
            gap = range("gap", L.hudGap, model.gapRange[1], model.gapRange[2]),
            import = Controls:Button(body, title .. " · " .. L.hudImport, 250, function()
                local component = groupComponent()
                if component then self:Result(component:Import(id)) end
                self:Update()
            end),
            empty = note(body, L.hudEmptyGroup, 0, 462),
            reset = Controls:Button(body, title .. " · " .. L.hudResetPosition, 250, function()
                local component = groupComponent()
                if component then component:ResetPosition(id) end
                self:Update()
            end) }
    end
    -- Spell order: one pooled row per slot with up / down / other-group
    -- buttons. These write at once through the same Model:Move as `/luma cds
    -- move`, so a failed move changes nothing. One row per storable slot: the
    -- model accepts up to `maxEntries`, and an editor that stopped short could
    -- not reorder or remove the rest.
    local orderRows = {}
    local function orderOf(id)
        local ui = profileUI()
        local group = ui and ui.cooldownGroups and ui.cooldownGroups.groups and ui.cooldownGroups.groups[id]
        return group and group.order or {}
    end
    for _, groupID in ipairs(app.CooldownModel.GROUP_IDS) do
        local id = groupID
        local others = {}
        for _, known in ipairs(app.CooldownModel.GROUP_IDS) do
            if known ~= id then others[#others + 1] = known end
        end
        local other = others[1]
        for slot = 1, app.CooldownModel.maxEntries do
            local rowFrame = CreateFrame("Frame", nil, body)
            rowFrame:SetSize(462, 26)
            local label = app.Theme:Text(rowFrame, 12)
            label:SetPoint("LEFT", 4, 0)
            label:SetWidth(280)
            label:SetJustifyH("LEFT")
            local record = { frame = rowFrame, label = label, group = id, slot = slot }
            local function act(fn)
                local component = groupComponent()
                if component and component.running and not app.Store.readonly and record.spellID then
                    fn(component, record.spellID)
                end
                self:Update()
            end
            record.up = Controls:Button(rowFrame, "▲", 30, function()
                act(function(c, spell) c:MoveSpell(spell, id, record.slot - 1) end)
            end)
            record.down = Controls:Button(rowFrame, "▼", 30, function()
                act(function(c, spell) c:MoveSpell(spell, id, record.slot + 1) end)
            end)
            record.swap = Controls:Button(rowFrame, "⇄", 30, function()
                act(function(c, spell) c:MoveSpell(spell, other) end)
            end)
            record.up:SetPoint("RIGHT", rowFrame, "RIGHT", -72, 0)
            record.down:SetPoint("RIGHT", rowFrame, "RIGHT", -38, 0)
            record.swap:SetPoint("RIGHT", rowFrame, "RIGHT", -4, 0)
            -- Mouse drag: drop on any listed row to take its group and slot.
            rowFrame:EnableMouse(true)
            rowFrame:RegisterForDrag("LeftButton")
            rowFrame:SetScript("OnDragStart", function() record.dragging = true; rowFrame:SetAlpha(0.6) end)
            rowFrame:SetScript("OnDragStop", function()
                rowFrame:SetAlpha(1)
                if not record.dragging then return end
                record.dragging = false
                local cursor = select(2, GetCursorPosition())
                local scale = UIParent:GetEffectiveScale()
                local y = app.Capabilities.Plain(cursor, "number")
                if y and scale and scale > 0 then self:DropOrderRow(record, y / scale) end
            end)
            rowFrame:Hide()
            orderRows[#orderRows + 1] = record
        end
    end
    -- Finds the listed row under the cursor height and moves the dragged spell
    -- there. Dropping on itself, outside every row, in combat or read-only
    -- changes nothing.
    function self:DropOrderRow(record, y)
        local component = groupComponent()
        if not component or not component.running or app.Store.readonly or not record.spellID then return false end
        for _, target in ipairs(orderRows) do
            if target ~= record and target.spellID and target.frame:IsShown() then
                local top, bottom = target.frame:GetTop(), target.frame:GetBottom()
                top, bottom = app.Capabilities.Plain(top, "number"), app.Capabilities.Plain(bottom, "number")
                if top and bottom and y <= top and y >= bottom then
                    local moved = component:MoveSpell(record.spellID, target.group, target.slot)
                    self:Update()
                    return moved
                end
            end
        end
        return false
    end
    -- Live preview: the selected group's real plan (rows, columns, capacity)
    -- drawn with plain icon textures. It is never a protected frame and takes
    -- no clicks, so it cannot trigger an action.
    local previewBox = CreateFrame("Frame", nil, body)
    previewBox:SetSize(462, 96)
    previewBox:EnableMouse(false)
    local previewBack = previewBox:CreateTexture(nil, "BACKGROUND")
    previewBack:SetAllPoints()
    previewBack:SetColorTexture(0, 0, 0, 0.25)
    local previewCells = {}
    for index = 1, app.CooldownModel.maxEntries do
        local cell = previewBox:CreateTexture(nil, "ARTWORK")
        cell:Hide()
        previewCells[index] = cell
    end
    local previewNote = note(body, L.hudPreviewEmpty, 0, 462)
    function page.RefreshHudPreview(component, groupID)
        local group = component and component.running and component:EffectiveGroup(groupID) or nil
        local order = group and group.order or {}
        local plan = group and app.CooldownModel:Plan(group, 0) or nil
        local drawn = plan and plan.count or 0
        local scale = 1
        if plan and plan.width > 0 and plan.height > 0 then
            scale = math.min(1, 440 / plan.width, 80 / plan.height)
        end
        for index, cell in ipairs(previewCells) do
            local slot = plan and plan.slots[index]
            if slot then
                local size = slot.size * scale
                cell:SetSize(size, size)
                cell:ClearAllPoints()
                -- Plan y counts up from the block's bottom edge.
                cell:SetPoint("CENTER", previewBox, "CENTER", slot.x * scale,
                    (slot.y - plan.height / 2) * scale)
                local info = _G.C_Spell and _G.C_Spell.GetSpellInfo and _G.C_Spell.GetSpellInfo(order[index])
                local icon = info and app.Capabilities.Plain(info.iconID, "number") or nil
                cell:SetTexture(icon or 134400)
                cell:Show()
            else
                cell:Hide()
            end
        end
        return drawn
    end
    local hudApply = Controls:Button(body, L.hudApply, 150, function()
        local component = groupComponent()
        if component then self:Result(component:ApplyDraft()) end
        self:Update()
    end)
    local hudCancel = Controls:Button(body, L.hudCancel, 150, function()
        local component = groupComponent()
        if component then component:CancelDraft() end
        self:Update()
    end)
    -- Search targets the selected group's own control, so the field map is
    -- rebuilt from whichever group the page currently shows.
    page.fields = page.fields or {}
    page.fields.owned = hudOwned
    page.fields.order = orderRows[1] and orderRows[1].frame or hudApply
    function page.RemapFields()
        local active = selectedGroup()
        for _, group in ipairs(hudControls) do
            if group.id == active then
                for _, key in ipairs({ "size", "gap", "max", "limit", "vertical", "import" }) do
                    page.fields[key] = group[key]
                end
            end
        end
    end
    self.hudEditor = { heading = hudHeading, owned = hudOwned, buffs = hudBuffs,
        groups = hudControls, apply = hudApply, cancel = hudCancel, orderRows = orderRows,
        preview = previewBox, previewCells = previewCells }
    return function(top)
        local readonly = app.Store.readonly
        local component = groupComponent()
        local live = component and component.running == true
        local active = selectedGroup()
        hudHeading:ClearAllPoints(); hudHeading:SetPoint("TOPLEFT", 0, top - 4)
        top = top - 4 - noteHeight(hudHeading, 28)
        hudOwned:SetShown(live)
        hudOwned:SetEnabled(live and not readonly)
        if live then
            hudOwned:ClearAllPoints(); hudOwned:SetPoint("TOPLEFT", 0, top)
            hudOwned:Update(component)
            top = top - 38
        end
        hudBuffs:SetShown(live)
        hudBuffs:SetEnabled(live and not readonly)
        if live then
            hudBuffs:ClearAllPoints(); hudBuffs:SetPoint("TOPLEFT", 0, top)
            hudBuffs:Update(component)
            top = top - 38
        end
        for _, group in ipairs(hudControls) do
            -- Only the selected group's geometry is editable here; the other
            -- groups keep their values and are chosen with the object row above.
            local shown = live and group.id == active
            group.follow:SetShown(shown)
            group.follow:SetEnabled(shown and not readonly)
            if shown then
                group.follow:ClearAllPoints(); group.follow:SetPoint("TOPLEFT", 0, top)
                group.follow:Update(component)
                top = top - 38
            end
            for _, key in ipairs({ "vertical", "max", "limit", "size", "gap" }) do
                local control = group[key]
                control:SetShown(shown)
                control:SetEnabled(shown and not readonly)
                if shown then
                    control:ClearAllPoints()
                    control:SetPoint("TOPLEFT", 0, top)
                    control:Update()
                    top = top - (key == "vertical" and 38 or 62)
                end
            end
            local auto = (app.CooldownModel:Normalize(profileUI().cooldownGroups).groups[group.id] or {}).auto ~= false
            local empty = shown and (auto or #orderOf(group.id) == 0)
            group.empty:SetText(auto and L.hudAutoGroup or L.hudEmptyGroup)
            group.empty:SetShown(empty == true)
            group.import:SetShown(shown)
            group.import:SetEnabled(shown and not readonly)
            if empty then
                group.empty:ClearAllPoints(); group.empty:SetPoint("TOPLEFT", 0, top)
                top = top - noteHeight(group.empty, 20)
            end
            if shown then
                group.import:ClearAllPoints(); group.import:SetPoint("TOPLEFT", 0, top)
                top = top - 38
                group.reset:SetShown(true)
                group.reset:SetEnabled(not readonly)
                group.reset:ClearAllPoints(); group.reset:SetPoint("TOPLEFT", 0, top)
                top = top - 40
            else
                group.reset:SetShown(false)
            end
        end
        -- Preview of the selected group's plan; an empty group says so instead
        -- of drawing a blank box.
        local drawn = page.RefreshHudPreview(component, active)
        previewBox:SetShown(live and drawn > 0)
        previewNote:SetShown(live and drawn == 0)
        if live then
            local target = drawn > 0 and previewBox or previewNote
            target:ClearAllPoints(); target:SetPoint("TOPLEFT", 0, top)
            top = top - (drawn > 0 and 104 or noteHeight(previewNote, 20))
        end
        for _, record in ipairs(orderRows) do
            local spellID = live and orderOf(record.group)[record.slot] or nil
            record.spellID = spellID
            record.frame:SetShown(spellID ~= nil)
            if spellID then
                local info = _G.C_Spell and _G.C_Spell.GetSpellInfo and _G.C_Spell.GetSpellInfo(spellID)
                local name = info and app.Capabilities.Plain(info.name, "string") or nil
                record.label:SetText(string.format("%s · %s", groupTitles[record.group] or record.group,
                    name or tostring(spellID)))
                record.up:SetEnabled(not readonly and record.slot > 1)
                record.down:SetEnabled(not readonly and record.slot < #orderOf(record.group))
                record.swap:SetEnabled(not readonly)
                record.frame:ClearAllPoints()
                record.frame:SetPoint("TOPLEFT", 0, top)
                top = top - 28
            end
        end
        local pending = live and component:HasDraft()
        hudApply:SetShown(live); hudCancel:SetShown(live)
        hudApply:SetEnabled(pending and not readonly)
        hudCancel:SetEnabled(pending == true)
        if live then
            hudApply:ClearAllPoints(); hudApply:SetPoint("TOPLEFT", 0, top)
            hudCancel:ClearAllPoints(); hudCancel:SetPoint("TOPLEFT", 164, top)
            top = top - 40
        end
        return top
    end
end

-- A module page: header, the module's status in one line, the object selector,
-- the object's real controls, then the internal component switches folded away.
function SettingsUI:BuildModule(page, entry)
    -- Fixed header: module name, status, the object selector and the on-screen
    -- locate action. Only the form below it scrolls.
    local header = CreateFrame("Frame", nil, page)
    header:SetPoint("TOPLEFT")
    header:SetSize(464, 96)
    page.header = header
    local scroll = Controls:Scroll(page, 464, 330)
    scroll:SetPoint("TOPLEFT", page, "TOPLEFT", 0, -96)
    local body = CreateFrame("Frame", nil, scroll)
    body:SetSize(462, 330)
    scroll:SetScrollChild(body)
    page.scroll, page.module, page.rows, page.rowList = scroll, entry, {}, {}
    page.scrollMemory = {}
    local heading = section(header, L[entry.label], 0)
    page.heading = heading
    page.status = note(header, "", 0, 236)
    -- 018 Step 4.1: one selector instead of a tab per object. A page with a
    -- single object omits it entirely; a page with more uses one dropdown, so
    -- the action bar page no longer opens with twelve buttons.
    local objects = self:ObjectList(entry.id)
    page.tabs = {}
    local selector
    if #objects > 1 then
        selector = Controls:Dropdown(header, 220, function(id) self:SelectObject(entry.id, id) end)
        page.selector = selector
        page.navObjects = objects
        settingsControl(page, selector)
    end
    -- The module's main switch stays visible; the components it runs alongside
    -- are internal plumbing and live in the fold below.
    local primary
    for _, id in ipairs(entry.components) do
        local component = app.components[id]
        if component and not primary then
            local label = type(component.label) == "string" and component.label or id
            primary = Controls:Toggle(body, L[label], 0,
                function() return app.Store:Profile().modules[id] == true end,
                function(v) self:Result(app.Store:Set("modules", id, v)) end,
                { width = 462, component = component })
            primary.componentID = id
            page.primary = primary
            page.rows[id] = primary
            settingsControl(page, primary)
        elseif component then
            local label = type(component.label) == "string" and component.label or id
            local row = Controls:Toggle(body, L[label], 0,
                function() return app.Store:Profile().modules[id] == true end,
                function(v) self:Result(app.Store:Set("modules", id, v)) end,
                { width = 462, component = component })
            row.componentID = id
            page.rows[id] = row
            page.rowList[#page.rowList + 1] = row
            settingsControl(page, row)
        end
    end
    local switches = Controls:FoldHeader(body, L.moduleInternals, 462, function() self:Update() end)
    switches:SetFolded(true)
    page.switches = switches
    local owner = note(body, "", 0, 462)
    owner:SetText("")
    page.owner = owner
    local locate = Controls:Button(header, L.moduleLocate, 104, function()
        self:Locate(entry.id, self:SelectedObject(entry.id))
    end)
    page.locate = locate
    local diagnostics = Controls:Button(header, L.openDiagnostics, 104, function() self:Select("diagnostics") end)
    page.diagButton = diagnostics
    local extra = entry.extras and Extras[entry.extras] and Extras[entry.extras](page, body) or nil
    page.Update = function()
        local readonly = app.Store.readonly
        local selected = self:SelectedObject(entry.id)
        page.selected = selected
        if page.RemapFields then page.RemapFields() end
        -- Header: heading, then the status line beside the two actions, then
        -- the object row. It is measured every refresh because a long
        -- translation or a wrapped object row changes its height.
        local htop = -22
        page.status:SetText(self:ModuleStatus(entry))
        page.status:ClearAllPoints(); page.status:SetPoint("TOPLEFT", 0, htop)
        locate:ClearAllPoints(); locate:SetPoint("TOPLEFT", 244, htop + 2)
        diagnostics:ClearAllPoints(); diagnostics:SetPoint("TOPLEFT", 356, htop + 2)
        locate:SetEnabled(not readonly and selected ~= nil)
        htop = htop - math.max(34, noteHeight(page.status, 20))
        if selector then
            selector:ClearAllPoints()
            selector:SetPoint("TOPLEFT", 0, htop)
            selector:SetItems(page.navObjects, selected)
            selector:SetEnabled(not readonly)
            htop = htop - 34
        end
        local headerHeight = math.min(200, -htop + 4)
        header:SetHeight(headerHeight)
        scroll:ClearAllPoints()
        scroll:SetPoint("TOPLEFT", page, "TOPLEFT", 0, -headerHeight)
        scroll:SetViewHeight(math.max(120, 424 - headerHeight))
        page.viewHeight = math.max(120, 424 - headerHeight)
        -- Body: the primary switch, the object's controls, internal switches.
        local top = -4
        if primary then
            primary:ClearAllPoints(); primary:SetPoint("TOPLEFT", 0, top)
            primary:Update(app.components[primary.componentID])
            primary:SetEnabled(not readonly)
            top = top - 40
        end
        if extra then top = extra(top) end
        top = top - 8
        -- Internal switches, folded by default. The fold keeps its own state
        -- across refreshes; nothing below moves while it is closed.
        switches:ClearAllPoints(); switches:SetPoint("TOPLEFT", 0, top)
        top = top - 32
        local open = switches.folded == false
        for _, row in ipairs(page.rowList) do
            row:SetShown(open)
            row:Update(app.components[row.componentID])
            row:SetEnabled(not readonly)
            if open then
                row:ClearAllPoints(); row:SetPoint("TOPLEFT", 0, top)
                top = top - 38
            end
        end
        if open and #page.rowList == 0 then
            switches:SetShown(false)
            top = top - 0
        else
            switches:SetShown(true)
        end
        body:SetHeight(math.max(page.viewHeight, -top + 6))
        scroll:UpdateRange()
    end
end

-- The first handle a module owns, used when the page has no selected object or
-- the remembered object is disabled this run.
function SettingsUI:SuggestLayoutID(moduleID)
    local entry = self.moduleByID[moduleID]
    for _, component in ipairs(entry and entry.components or {}) do
        if app.Unlock:CanSelect(component) then return component end
    end
    -- Module ids that own several handles (unit frames, cooldown groups, the
    -- action bars) fall back to the first handle with their prefix.
    local prefixes = { actionBars = "actionBar", unitFrames = "unit_", cooldowns = "cdGroup_",
        groups = "party", chat = "chat" }
    local prefix = prefixes[moduleID]
    if not prefix then return nil end
    local ids = app.Layout:IDs()
    for _, id in ipairs(ids) do
        if id:sub(1, #prefix) == prefix and app.Unlock:CanSelect(id) then return id end
    end
    return nil
end

-- "Position": hand the player to the on-screen mover with the object the page
-- currently shows selected. A stored object that is disabled this run is named
-- in chat so the fall back to the global mode is visible, not silent.
function SettingsUI:Locate(moduleID, objectID)
    self.locateTarget = moduleID
    local wanted = objectID or self.moduleObject and self.moduleObject[moduleID]
    local pick
    if wanted then
        if app.Unlock:CanSelect(wanted) then
            pick = wanted
        elseif app.Layout.entries[wanted] or app.BarModel:Native(wanted) then
            -- A real object of this build that has no movable handle right now
            -- (a bar the client owns, a disabled panel): say so, then fall back.
            app:Print(string.format(L.unlockTargetMissing, tostring(wanted)))
        end
    end
    if not pick then pick = self:SuggestLayoutID(moduleID) end
    return app.Unlock:Enter({ page = moduleID, select = pick })
end

-- Profile page: presets, undo and the whole-layout reset. They moved here from
-- the old Layout page because they act on the profile, not on one module.
function SettingsUI:BuildPresets(page, body)
    local hint = note(body, L.presetHint, 0, 462)
    self.presetHint = hint
    local selected = "default16x9"
    local choices = {}
    local function choose(name)
        selected = name
        app.Layout:CancelPresetPreview()
        self:Update()
    end
    local order = { { "default16x9", L.preset16x9 }, { "combat", L.presetCombat },
        { "pearlCity", L.presetPearlCity }, { "pearlCombat", L.presetPearlCombat } }
    for index, spec in ipairs(order) do
        local name = spec[1]
        choices[name] = Controls:Button(body, spec[2], 150, function() choose(name) end)
        choices[name].slot = index
    end
    self.presetChoices = choices
    local preview = Controls:Button(body, L.presetPreview, 104, function()
        app.Layout:PreviewPreset(selected)
        self:Update()
    end)
    local apply = Controls:Button(body, L.presetApply, 104, function()
        app.Layout:ApplyPreset(selected)
        self:Update()
    end)
    local cancel = Controls:Button(body, L.presetCancel, 104, function()
        app.Layout:CancelPresetPreview()
        self:Update()
    end)
    local undo = Controls:Button(body, L.presetUndo, 104, function()
        app.Layout:UndoPreset()
        self:Update()
    end)
    self.presetButtons = { preview = preview, apply = apply, cancel = cancel, undo = undo }
    local reset = Controls:Button(body, L.resetLayout, 150, function()
        self:Result(app.Store:Reset(true))
        app.Layout:ApplyAll()
    end)
    self.layoutReset = reset
    local count = note(body, "", 0, 462)
    self.layoutCount = count
    return function(top)
        local readonly = app.Store.readonly
        hint:ClearAllPoints(); hint:SetPoint("TOPLEFT", 0, top)
        top = top - noteHeight(hint, 28)
        for name, button in pairs(choices) do
            button:ClearAllPoints()
            button:SetPoint("TOPLEFT", ((button.slot - 1) % 2) * 164, top - math.floor((button.slot - 1) / 2) * 38)
            button:SetEnabled(not readonly)
            button:SetSelected(name == selected)
        end
        top = top - 76
        local x = 0
        for _, button in ipairs({ preview, apply, cancel, undo }) do
            button:ClearAllPoints(); button:SetPoint("TOPLEFT", x, top)
            x = x + 112
        end
        preview:SetEnabled(not readonly)
        apply:SetEnabled(not readonly)
        cancel:SetEnabled(not readonly and app.Layout.previewName ~= nil)
        undo:SetEnabled(not readonly and app.Layout.presetSnapshot ~= nil)
        top = top - 40
        reset:ClearAllPoints(); reset:SetPoint("TOPLEFT", 0, top)
        reset:SetEnabled(not readonly)
        top = top - 40
        local text = string.format(L.layoutCount, #app.Layout:IDs())
        if app.Layout.previewWarnings and next(app.Layout.previewWarnings) then
            text = text .. " · " .. L.presetOverlapHint
        end
        count:SetText(text)
        count:ClearAllPoints(); count:SetPoint("TOPLEFT", 0, top)
        return top - noteHeight(count, 20)
    end
end
