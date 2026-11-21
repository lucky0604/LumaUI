local _, app = ...
local module

-- Quest titles in the native tracker are repainted in the game's difficulty
-- colors (trivial and low-level quests turn gray), matching the quest log.
-- The tracker keeps its own background-free look, hover highlight and clicks.
-- Campaign quests use the same block type, so they get the same treatment.

local TRACKERS = { "QuestObjectiveTracker", "CampaignQuestObjectiveTracker" }

local function levelOf(questID)
    local log = _G.C_QuestLog
    if type(log) ~= "table" or type(log.GetQuestDifficultyLevel) ~= "function" then return nil end
    local ok, level = pcall(log.GetQuestDifficultyLevel, questID)
    if not ok then return nil end
    return app.Capabilities.Plain(level, "number")
end

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
    local questID = app.Capabilities.Plain(block.id, "number")
    if not questID then return end
    local red, green, blue = app.Theme:QuestColor(levelOf(questID))
    if not red then return end
    header:SetTextColor(red, green, blue)
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

local function restore()
    eachBlock(function(block)
        if type(block) == "table" and block.HeaderText and type(block.UpdateHighlight) == "function" then
            block:UpdateHighlight()
        end
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
    -- Difficulty colors depend on the player's level, so repaint when it changes
    -- even if the tracker itself does not redraw.
    self:Listen("PLAYER_LEVEL_UP", paint)
    paint(self)
end

module = app:RegisterComponent({ id = "questTracker", label = "questTracker",
    Supported = function()
        return _G.ObjectiveTrackerFrame ~= nil
            and type(_G.C_QuestLog) == "table"
            and type(_G.C_QuestLog.GetQuestDifficultyLevel) == "function"
    end,
    Enable = install,
    Refresh = paint,
    Disable = restore,
})
