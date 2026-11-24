local _, app = ...
local module

-- Quest titles in the native tracker are repainted in the game's difficulty
-- colors (trivial and low-level quests turn gray), matching the quest log.
-- The tracker keeps its own background-free look, hover highlight and clicks.
-- Campaign quests use the same block type, so they get the same treatment.
--
-- The frame itself is re-anchored below the minimap so the right side reads as
-- one column: map, zone band, quests. Only the container is moved and narrowed;
-- folding, quest items, world quests, scenario/dungeon modules and every block
-- stay native. The original anchors are restored when the component is off.

local TRACKERS = { "QuestObjectiveTracker", "CampaignQuestObjectiveTracker" }
local LAYOUT_JOB = "questTracker/layout"
local COLUMN_GAP = 6
local COLUMN_GAP_WITHOUT_PANEL = 28
local MIN_WIDTH = 120

local function eachBlock(visit)
    for _, name in ipairs(TRACKERS) do
        local tracker = _G[name]
        if type(tracker) == "table" then
            local used = tracker.usedBlocks
            if type(used) == "table" then
                for _, entry in pairs(used) do
                    if type(entry) == "table" then
                        if entry.HeaderText then
                            -- Some modules key blocks directly by quest ID.
                            visit(entry)
                        else
                            for _, block in pairs(entry) do
                                if type(block) == "table" then visit(block) end
                            end
                        end
                    end
                end
            elseif type(tracker.EnumerateActiveBlocks) == "function" then
                pcall(tracker.EnumerateActiveBlocks, tracker, visit)
            end
        end
    end
end

local function styleBlock(self, block)
    if not self.running or type(block) ~= "table" then return end
    local header = block.HeaderText
    if not header or block.isHighlighted then return end
    -- Pearl uses one amber-gold for every quest title; difficulty still comes
    -- from the level number and the native objective text, not a rainbow of
    -- header colours.
    local accent = app.Theme:Accent()
    header:SetTextColor(accent[1], accent[2], accent[3])
    if not block.lumaStyled and type(block.UpdateHighlight) == "function" and type(hooksecurefunc) == "function" then
        -- Native hover repaints the header white; leaving it should return to
        -- the difficulty color instead of the default header color.
        block.lumaStyled = true
        hooksecurefunc(block, "UpdateHighlight", function(current) styleBlock(self, current) end)
    end
end

local function paint(self)
    if not self.running then return end
    eachBlock(function(block) styleBlock(self, block) end)
end

local function restoreColors()
    eachBlock(function(block)
        if type(block) == "table" and block.HeaderText and type(block.UpdateHighlight) == "function" then
            block:UpdateHighlight()
        end
    end)
end

local function saveLayout(self)
    local frame = _G.ObjectiveTrackerFrame
    if not frame or self.savedLayout then return end
    local points = {}
    for index = 1, 8 do
        local called, point, relativeTo, relativePoint, x, y =
            pcall(frame.GetPoint, frame, index)
        if not called or point == nil then break end
        points[#points + 1] = {
            point = point, relativeTo = relativeTo,
            relativePoint = relativePoint, x = x, y = y,
        }
    end
    local called, width = pcall(frame.GetWidth, frame)
    width = called and app.Capabilities.Plain(width, "number") or nil
    self.savedLayout = { points = points, width = width }
end

local function restoreLayout(self)
    local saved = self.savedLayout
    self.savedLayout = nil
    self.anchorTarget = nil
    local frame = _G.ObjectiveTrackerFrame
    if not frame or not saved then return end
    frame:ClearAllPoints()
    if saved.width then frame:SetWidth(saved.width) end
    for _, point in ipairs(saved.points) do
        frame:SetPoint(point.point, point.relativeTo, point.relativePoint, point.x or 0, point.y or 0)
    end
end

local function applyLayout(self)
    local frame = _G.ObjectiveTrackerFrame
    local map = _G.Minimap
    if not frame or not map then return end
    local minimap = app.components.minimap
    if not minimap or not minimap.running then
        restoreLayout(self)
        return
    end
    local panel = _G.LumaUIMinimapPanel
    local anchor = panel or map
    local called, width = pcall(anchor.GetWidth, anchor)
    width = called and app.Capabilities.Plain(width, "number") or nil
    if not width or width <= 0 then width = 100 end
    frame:ClearAllPoints()
    -- Right-align to the map column so a client that keeps the native text
    -- width still lays out on screen; the frame width gives the quest column
    -- its slightly wider than the map footprint.
    frame:SetPoint("TOPRIGHT", anchor, "BOTTOMRIGHT", 0,
        -((panel and COLUMN_GAP) or COLUMN_GAP_WITHOUT_PANEL))
    frame:SetWidth(math.max(MIN_WIDTH, width))
    self.anchorTarget = anchor
end

local function queueLayout(self)
    if not self.running then return end
    app.Queue:Run(LAYOUT_JOB, function()
        if self.running then
            saveLayout(self)
            applyLayout(self)
        end
    end)
end

local function hookMap(self)
    local map = _G.Minimap
    if not map or type(map.HookScript) ~= "function" or self.mapHooked then return end
    self.mapHooked = true
    map:HookScript("OnSizeChanged", function()
        if module.running then queueLayout(module) end
    end)
end

local function install(self)
    local frame = _G.ObjectiveTrackerFrame
    if not frame then return end
    if not self.hooked then
        self.hooked = true
        if type(hooksecurefunc) == "function" and type(frame.Update) == "function" then
            hooksecurefunc(frame, "Update", function() paint(module) end)
        end
        if type(frame.HookScript) == "function" then
            frame:HookScript("OnShow", function() if module.running then paint(module) end end)
        end
    end
    if not self.subscribed then
        self.subscribed = true
        -- The minimap panel can appear after this component if the minimap was
        -- off at login; re-anchor once the target changes, not on every update.
        app:Subscribe(self, "RUNTIME_UPDATED", function()
            if not self.running then return end
            local minimap = app.components.minimap
            if not minimap or not minimap.running then return end
            local want = _G.LumaUIMinimapPanel or _G.Minimap
            if want and want ~= self.anchorTarget then queueLayout(self) end
        end)
    end
    hookMap(self)
    -- Difficulty colors depend on the player's level, so repaint when it changes
    -- even if the tracker itself does not redraw.
    self:Listen("PLAYER_LEVEL_UP", paint)
    self:Listen("PLAYER_ENTERING_WORLD", queueLayout)
    self:Listen("EDIT_MODE_LAYOUTS_UPDATED", queueLayout)
    self:Listen("DISPLAY_SIZE_CHANGED", queueLayout)
    self:Listen("UI_SCALE_CHANGED", queueLayout)
    queueLayout(self)
    paint(self)
end

module = app:RegisterComponent({ id = "questTracker", label = "questTracker",
    Supported = function() return _G.ObjectiveTrackerFrame ~= nil end,
    Enable = install,
    Refresh = function(self) queueLayout(self); paint(self) end,
    Disable = function(self) restoreColors(); restoreLayout(self) end,
})
