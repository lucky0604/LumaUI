local _, app = ...

-- The quest indicator over an NPC is a client-owned button. LumaUI does not
-- click it, move it, resize it or replace its icon: it only draws the same edge
-- animation the controls use when the button the client already shows is
-- available. If the build names the button differently, nothing is attached and
-- the client keeps its own look — that is the fallback, not an error.
--
-- Candidates are tried in order and the first existing frame wins. Only a shown
-- button is outlined, and the pulse is released when the button hides, when the
-- component stops or when the client swaps the frame out.

local CANDIDATES = { "QuestActionFrame", "QuestActionButton", "QuestBang" }
local component

local function questFrame()
    for _, name in ipairs(CANDIDATES) do
        local frame = _G[name]
        if type(frame) == "table" or type(frame) == "userdata" then return frame, name end
    end
end

local function isShown(frame)
    if type(frame.IsShown) ~= "function" then return false end
    local ok, shown = pcall(frame.IsShown, frame)
    return ok and shown == true
end

local function refresh(self)
    local frame = questFrame()
    self.frameName = nil
    if not frame or not isShown(frame) then
        if self.attached then app.EdgePulse:Release(self.attached) end
        self.attached = nil
        return false
    end
    self.frameName = "quest"
    if self.attached ~= frame then
        if self.attached then app.EdgePulse:Release(self.attached) end
        self.attached = frame
    end
    if not next(app.EdgePulse.active) or not app.EdgePulse.active[frame] then
        app.EdgePulse:Show(frame, app.Theme:Accent())
    end
    return true
end

component = app:RegisterComponent({ id = "questIndicators", label = "questIndicators",
    defaultEnabled = true,
    Supported = function()
        return questFrame() ~= nil and app.EdgePulse ~= nil
    end,
    Enable = function(self)
        -- Quest availability changes land in QUEST_LOG_UPDATE; the other two
        -- cover a reload and a new target. Reads only, so they can run in combat.
        for _, event in ipairs({ "QUEST_LOG_UPDATE", "PLAYER_ENTERING_WORLD", "PLAYER_TARGET_CHANGED" }) do
            self:Listen(event, function(current) refresh(current) end)
        end
        refresh(self)
    end,
    Refresh = function(self)
        refresh(self)
    end,
    Disable = function(self)
        if self.attached then app.EdgePulse:Release(self.attached) end
        self.attached = nil
        self.frameName = nil
    end,
})

function component:Describe()
    if not self.running then return nil end
    return string.format("questIndicators: attached=%s", self.attached and self.frameName or "none")
end
