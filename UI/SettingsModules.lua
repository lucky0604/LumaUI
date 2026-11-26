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
    { id = "actionBars", label = "navActionBars", extras = "ActionBars",
      components = { "actionBars", "ownedBars", "actionButtons", "actionPanel" } },
    { id = "unitFrames", label = "navUnitFrames", components = { "unitFrames" } },
    { id = "cooldowns", label = "navCooldowns", extras = "Cooldowns",
      components = { "cooldownGroups", "cooldownViewer" } },
    { id = "chat", label = "navChat", extras = "Chat", components = { "chat", "chatTabs", "chatView" } },
    { id = "groups", label = "navGroups", components = { "partyFrames", "raidFrames", "clickCast" } },
    { id = "nameplates", label = "navNameplates", components = { "nameplates" } },
    { id = "resources", label = "navResources", components = { "playerResource", "playerCast", "edgeAuras" } },
    { id = "minimap", label = "navMinimap", components = { "minimap", "launcher", "gameMenu", "utilityCorner" } },
    { id = "quests", label = "navQuests", extras = "Quests",
      components = { "questTracker", "questIndicators", "questList" } },
    { id = "containers", label = "navContainers", extras = "Containers", components = { "inventory", "bank" } },
    { id = "windows", label = "navWindows", components = { "characterWindow", "systemWindows" } },
    { id = "info", label = "navInfo", extras = "Info",
      components = { "dataStrip", "experience", "topPerformance" } },
    { id = "meter", label = "navMeter", components = { "damageMeterArea", "damageMeter", "combatText" } },
    { id = "tooltip", label = "navTooltip", extras = "Tooltip", components = { "tooltip" } },
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
    return list
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
    self.moduleObject[moduleID] = id
    self:Update()
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
    local function countLabel(number) return string.format("%d", math.floor(number + 0.5)) end
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
    for _, control in pairs(controls) do settingsControl(page, control) end
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
    settingsControl(page, scale)
    local visibility = {}
    for index, mode in ipairs({ { "always", L.visibilityAlways }, { "combat", L.visibilityCombat },
        { "outofcombat", L.visibilityOutOfCombat }, { "hidden", L.visibilityHidden } }) do
        local key = mode[1]
        visibility[index] = Controls:Button(body, mode[2], 108, function()
            stage("visible", key)
        end)
        visibility[index].mode = key
        settingsControl(page, visibility[index])
    end
    local hint = note(body, L.actionBarLayoutHint, 0, 462)
    local reset = Controls:Button(body, L.actionBarReset, 200, function()
        local slot = barID()
        local current = app.Store:Clone(profileUI().actionBarLayout or {})
        current[slot] = nil
        self:Result(app.Store:Set("ui", "actionBarLayout", current))
        if profileUI().actionBarScales[slot] then
            local scales = app.Store:Clone(profileUI().actionBarScales)
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
    return function(top)
        local readonly = app.Store.readonly
        local entry = bar()
        local managed = entry and entry.manageable
        scope:ClearAllPoints(); scope:SetPoint("TOPLEFT", 0, top)
        top = top - noteHeight(scope, 28)
        for _, key in ipairs({ "buttons", "rows", "size", "gap" }) do
            local control = controls[key]
            -- Bars 4–8 cannot be moved by LumaUI yet; capacity, rows, size and
            -- spacing are still real because they only rearrange the client's
            -- own buttons.
            control:ClearAllPoints(); control:SetPoint("TOPLEFT", 0, top)
            control:Update(); control:SetEnabled(not readonly and entry ~= nil)
            top = top - 62
        end
        scale:SetShown(managed == true)
        if managed then
            scale:ClearAllPoints(); scale:SetPoint("TOPLEFT", 0, top)
            scale:Update(); scale:SetEnabled(not readonly)
            top = top - 62
        end
        local current = layoutKey("visible") or "always"
        for index, button in ipairs(visibility) do
            button:ClearAllPoints()
            button:SetPoint("TOPLEFT", ((index - 1) % 2) * 116, top - math.floor((index - 1) / 2) * 36)
            button:SetSelected(button.mode == current)
            button:SetEnabled(not readonly and entry ~= nil)
        end
        top = top - 76
        hint:ClearAllPoints(); hint:SetPoint("TOPLEFT", 0, top)
        top = top - noteHeight(hint, 34)
        reset:ClearAllPoints(); reset:SetPoint("TOPLEFT", 0, top)
        reset:SetEnabled(not readonly)
        editMode:ClearAllPoints(); editMode:SetPoint("TOPLEFT", 208, top)
        editMode:SetEnabled(not readonly)
        return top - 42
    end
end

function Extras.Chat(page, body)
    local self = SettingsUI
    local function get(key) return app.Store:Profile().appearance[key] end
    local function set(key, value) self:Result(app.Store:Set("appearance", key, value)) end
    local controls = {
        settingsControl(page, simpleToggle(body, L.chatViewTitle, function()
            return app.Store:Profile().ui.chatTakeover == true
        end, function(v)
            local view = app.components and app.components.chatView
            if view and view.running then
                self:Result(view:SetTakeover(v))
            else
                self:Result(app.Store:Set("ui", "chatTakeover", v))
            end
            self:Update()
        end)),
        settingsControl(page, Controls:Range(body, L.chatOpacity, 0, 0, 1, 0.05,
            function() return get("chatOpacity") end, function(v) set("chatOpacity", v) end, { width = 462 })),
        settingsControl(page, Controls:Range(body, L.chatActiveOpacity, 0, 0.2, 1, 0.05,
            function() return get("chatActiveOpacity") end, function(v) set("chatActiveOpacity", v) end,
            { width = 462 })),
        settingsControl(page, Controls:Range(body, L.chatWidthLabel, 0, 240, 600, 10,
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
            end, { width = 462, format = function(n) return string.format("%d", math.floor(n + 0.5)) end })),
        settingsControl(page, Controls:Range(body, L.chatHeightLabel, 0, 100, 400, 10,
            function() return profileUI().chatHeight > 0 and profileUI().chatHeight or 140 end,
            function(value)
                local chat = app.components and app.components.chat
                local width = profileUI().chatWidth > 0 and profileUI().chatWidth or 380
                if chat and chat.running then
                    self:Result(chat:SetSize(width, math.floor(value)))
                else
                    self:Result(app.Store:Set("ui", "chatHeight", math.floor(value)))
                end
            end, { width = 462, format = function(n) return string.format("%d", math.floor(n + 0.5)) end })),
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
    local toggle = settingsControl(page, simpleToggle(body, L.containerTakeover, function()
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
    end))
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

function Extras.Info(page, body)
    local self = SettingsUI
    local compact = settingsControl(page, simpleToggle(body, L.stripCompact,
        function() return profileUI().stripCompact == true end,
        function(v) self:Result(app.Store:Set("ui", "stripCompact", v)) end))
    local clockLabel = note(body, L.clockOwner, 0, 462)
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
function Extras.Quests(page, body)
    local self = SettingsUI
    local belowMap = settingsControl(page, simpleToggle(body, L.questBelowMap,
        function() return profileUI().questBelowMap == true end,
        function(value)
            self:Result(app.Store:Set("ui", "questBelowMap", value))
            local quests = app.components and app.components.questList
            if quests and quests.running then quests:Refresh() end
            self:Update()
        end))
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
    local toggle = settingsControl(page, simpleToggle(body, L.tooltipQuality,
        function() return app.Store:Profile().appearance.tooltipQuality end,
        function(v) self:Result(app.Store:Set("appearance", "tooltipQuality", v)) end))
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
    self.hudEditor = { heading = hudHeading, owned = hudOwned, buffs = hudBuffs,
        groups = hudControls, apply = hudApply, cancel = hudCancel, orderRows = orderRows }
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
    local scroll = Controls:Scroll(page, 464, 420)
    scroll:SetPoint("TOPLEFT")
    local body = CreateFrame("Frame", nil, scroll)
    body:SetSize(462, 420)
    scroll:SetScrollChild(body)
    page.scroll, page.module, page.rows, page.rowList = scroll, entry, {}, {}
    local heading = section(body, L[entry.label], 0)
    page.heading = heading
    page.status = note(body, "", 0, 462)
    page.tabs = {}
    for index, object in ipairs(self:ObjectList(entry.id)) do
        local tab = Controls:Tab(body, object.label, 100, function() self:SelectObject(entry.id, object.id) end)
        page.tabs[index] = { button = tab, id = object.id }
        settingsControl(page, tab)
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
    local locate = Controls:Button(body, L.moduleLocate, 150, function()
        self:Locate(entry.id, self:SelectedObject(entry.id))
    end)
    page.locate = locate
    local diagnostics = Controls:Button(body, L.openDiagnostics, 150, function() self:Select("diagnostics") end)
    page.diagButton = diagnostics
    local extra = entry.extras and Extras[entry.extras] and Extras[entry.extras](page, body) or nil
    page.Update = function()
        local readonly = app.Store.readonly
        local top = -22
        local selected = self:SelectedObject(entry.id)
        page.selected = selected
        local shown = #page.tabs > 1
        for index, tab in ipairs(page.tabs) do
            tab.button:SetShown(shown)
            if shown then
                tab.button:ClearAllPoints()
                tab.button:SetPoint("TOPLEFT", ((index - 1) % 4) * 112, top - math.floor((index - 1) / 4) * 34)
                tab.button:SetSelected(tab.id == selected)
                tab.button:SetEnabled(not readonly)
            end
        end
        if shown then top = top - math.ceil(#page.tabs / 4) * 34 end
        page.status:SetText(self:ModuleStatus(entry))
        page.status:ClearAllPoints(); page.status:SetPoint("TOPLEFT", 0, top)
        top = top - noteHeight(page.status, 20)
        if primary then
            primary:ClearAllPoints(); primary:SetPoint("TOPLEFT", 0, top)
            primary:Update(app.components[primary.componentID])
            primary:SetEnabled(not readonly)
            top = top - 40
        end
        if extra then top = extra(top) end
        locate:ClearAllPoints(); locate:SetPoint("TOPLEFT", 0, top)
        diagnostics:ClearAllPoints(); diagnostics:SetPoint("TOPLEFT", 164, top)
        locate:SetEnabled(not readonly and selected ~= nil)
        top = top - 40
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
        body:SetHeight(math.max(420, -top + 6))
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
