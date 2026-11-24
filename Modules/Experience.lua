local _, app = ...
local module

local function plain(value, expected)
    return app.Capabilities.Plain(value, expected)
end

local MODE_XP, MODE_REPUTATION = "xp", "reputation"

-- The client's own status bars are the ground truth this module replaces: they
-- carry the same experience or watched faction, plus rested and locked states.
-- A bar is therefore hidden only while the replacement actually draws a reading
-- of its own; when the replacement hides (max level, XP locked, nothing watched)
-- or the component stops, the native bar comes back instead of leaving the
-- player with no reading at all. Builds without a readable container keep the
-- native bar untouched.
local NATIVE_BARS = { "MainStatusTrackingBarContainer", "StatusTrackingBarManager" }

local function nativeStatusBar()
    for _, name in ipairs(NATIVE_BARS) do
        local frame = _G[name]
        if frame and type(frame.Hide) == "function" and type(frame.Show) == "function" then
            return frame
        end
    end
end

local function suppressNative(self, wanted)
    local frame = nativeStatusBar()
    if not frame then return end
    -- Read the live state instead of trusting the last write: Edit Mode can
    -- re-show the container between two events, and the next pass must hide it
    -- again rather than assume the takeover still holds.
    local okShown, shown = pcall(frame.IsShown, frame)
    shown = okShown and shown == true
    -- `wanted` is the hidden state: act when the bar is visible and should be
    -- hidden, or hidden and should be visible.
    if shown == wanted then
        local method = wanted and frame.Hide or frame.Show
        local ok, problem = pcall(method, frame)
        if not ok then
            -- One report per session: a client that refuses the write must not
            -- spam the diagnostics on every experience event.
            if not self.nativeFailed then
                self.nativeFailed = true
                app:Report("experience/native", problem)
            end
            return
        end
    end
    self.nativeSuppressed = wanted
end

local function maxPlayerLevel()
    -- Only an explicit expansion ceiling may hide the bar. Deriving it from the
    -- player's own level would be circular: a client that reports no XP range at
    -- max level already says so with maximum <= 0.
    if type(GetMaxLevelForPlayerExpansion) ~= "function" then return nil end
    local ok, level = pcall(GetMaxLevelForPlayerExpansion)
    return ok and plain(level, "number") or nil
end

-- Normalize only public values. An incomplete watched faction leaves the
-- native progress bar responsible for it instead of presenting a guessed XP bar.
local function factionState(name, reaction, minimum, maximum, current, standing)
    name, reaction = plain(name, "string"), plain(reaction, "number")
    minimum, maximum, current = plain(minimum, "number"), plain(maximum, "number"), plain(current, "number")
    standing = plain(standing, "string")
    if not name or name == "" or not minimum or not maximum or not current then return nil end
    if maximum <= minimum then
        local cap = plain(_G.MAX_REPUTATION_REACTION, "number") or 8
        if maximum == minimum and reaction and reaction >= cap and current >= maximum then
            minimum, maximum, current = 0, 1, 1
        else
            return nil
        end
    end
    if not standing and reaction then
        standing = plain(_G["FACTION_STANDING_LABEL" .. reaction], "string")
        if not standing and type(_FACTION_STANDING_LABEL) == "table" then
            standing = plain(_FACTION_STANDING_LABEL[reaction], "string")
        end
    end
    return { name = name, reaction = reaction, minimum = minimum, maximum = maximum,
        current = math.max(minimum, math.min(maximum, current)), standing = standing }
end

local function callBoolean(fn, id)
    if type(fn) ~= "function" then return nil end
    local ok, result = pcall(fn, id)
    if not ok then return nil end
    return plain(result, "boolean")
end

local function modernFaction(api)
    local ok, data = pcall(api.GetWatchedFactionData)
    if not ok or app.Capabilities.IsSecret(data) then return nil, true end
    if data == nil then return nil, false end
    if type(data) ~= "table" then return nil, true end
    local id, name = plain(data.factionID, "number"), plain(data.name, "string")
    if id == 0 or name == "" then return nil, false end
    if not id or not name then return nil, true end
    local reaction = plain(data.reaction, "number")
    local paragon = callBoolean(api.IsFactionParagonForCurrentPlayer, id)
    local major = callBoolean(api.IsMajorFaction, id)
    if paragon == nil or major == nil then return nil, true end
    if paragon then
        if type(api.GetFactionParagonInfo) ~= "function" then return nil, true end
        local success, current, threshold, _, pending = pcall(api.GetFactionParagonInfo, id)
        current, threshold, pending = plain(current, "number"), plain(threshold, "number"), plain(pending, "boolean")
        if not success or not current or not threshold or threshold <= 0 or pending == nil then return nil, true end
        local progress = pending and threshold or current % threshold
        local state = factionState(name, reaction, 0, threshold, progress, app.L.reputationParagon)
        if state then state.rewardPending = pending end
        return state, true
    end
    if major then
        local majorApi = _G.C_MajorFactions
        if type(majorApi) ~= "table" or type(majorApi.GetMajorFactionData) ~= "function" then return nil, true end
        local success, info = pcall(majorApi.GetMajorFactionData, id)
        if not success or app.Capabilities.IsSecret(info) or type(info) ~= "table" then return nil, true end
        local threshold, earned = plain(info.renownLevelThreshold, "number"), plain(info.renownReputationEarned, "number")
        local level, maximumLevel = plain(info.renownLevel, "number"), plain(info.maxLevel, "number")
        local capped = callBoolean(majorApi.HasMaximumRenown, id)
        if capped == nil and level and maximumLevel and maximumLevel > 0 then capped = level >= maximumLevel end
        if not threshold or threshold <= 0 or not earned or capped == nil then return nil, true end
        local label = level and string.format(app.L.reputationRenown, level) or nil
        return factionState(name, reaction, 0, threshold, capped and threshold or earned, label), true
    end
    local gossip = _G.C_GossipInfo
    if type(gossip) ~= "table" or type(gossip.GetFriendshipReputation) ~= "function" then return nil, true end
    local success, friendship = pcall(gossip.GetFriendshipReputation, id)
    if not success or app.Capabilities.IsSecret(friendship) then return nil, true end
    if friendship ~= nil then
        if type(friendship) ~= "table" then return nil, true end
        local friendshipID = plain(friendship.friendshipFactionID, "number")
        if not friendshipID then return nil, true end
        if friendshipID > 0 then
            local label = plain(friendship.reaction, "string")
            if app.Capabilities.IsSecret(friendship.nextThreshold) then return nil, true end
            if friendship.nextThreshold == nil then return factionState(name, reaction, 0, 1, 1, label), true end
            return factionState(name, reaction, friendship.reactionThreshold,
                friendship.nextThreshold, friendship.standing, label), true
        end
    end
    return factionState(name, reaction, data.currentReactionThreshold,
        data.nextReactionThreshold, data.currentStanding), true
end

local function watchedFaction()
    local api = _G.C_Reputation
    if type(api) == "table" and type(api.GetWatchedFactionData) == "function" then
        return modernFaction(api)
    end
    if type(GetWatchedFactionInfo) ~= "function" then return nil, false end
    local ok, name, reaction, minimum, maximum, current = pcall(GetWatchedFactionInfo)
    if not ok or app.Capabilities.IsSecret(name) then return nil, true end
    if name == nil then return nil, false end
    return factionState(name, reaction, minimum, maximum, current), true
end

local function xpState()
    if type(UnitXP) ~= "function" or type(UnitXPMax) ~= "function" then return nil end
    local currentOK, current = pcall(UnitXP, "player")
    local maximumOK, maximum = pcall(UnitXPMax, "player")
    current = currentOK and plain(current, "number") or nil
    maximum = maximumOK and plain(maximum, "number") or nil
    if not current or not maximum or maximum <= 0 then return nil end
    if type(IsXPUserDisabled) == "function" then
        local ok, disabled = pcall(IsXPUserDisabled)
        if not ok then return nil end
        disabled = plain(disabled, "boolean")
        if disabled ~= false then return nil end
    end
    local level = type(UnitLevel) == "function" and plain(UnitLevel("player"), "number") or nil
    local ceiling = maxPlayerLevel()
    if level and ceiling and level >= ceiling then return nil end
    return { current = current, maximum = maximum }
end

local function paintMode(self, mode, faction)
    local accent = app.Theme:Accent()
    local color = accent
    if mode == MODE_REPUTATION and faction and faction.reaction then
        local palette = _G.FACTION_BAR_COLORS
        local standing = type(palette) == "table" and palette[faction.reaction] or nil
        local red = standing and plain(standing.r, "number")
        local green = standing and plain(standing.g, "number")
        local blue = standing and plain(standing.b, "number")
        if red and green and blue then color = { red, green, blue } end
    end
    app.Theme:PaintBar(self.bar, color)
end

local function update(self)
    local faction, watching = watchedFaction()
    local xp = not watching and xpState() or nil
    if not faction and not xp then
        -- Nothing applies to this character right now (max level, XP locked,
        -- no watched faction): the bar hides instead of printing a fake 0%,
        -- and the client's own bar takes the reading back.
        self.mode, self.faction, self.current, self.maximum = nil, nil, nil, nil
        self.frame:Hide()
        suppressNative(self, false)
        return
    end
    self.frame:Show()
    suppressNative(self, true)
    if faction then
        self.mode, self.faction = MODE_REPUTATION, faction
        self.current, self.maximum = nil, nil
        self.bar:SetMinMaxValues(faction.minimum, faction.maximum)
        self.bar:SetValue(faction.current)
        local percent = math.floor((faction.current - faction.minimum) / (faction.maximum - faction.minimum) * 100)
        local label = faction.name .. (faction.standing and ("  ·  " .. faction.standing) or "")
        if faction.rewardPending then label = label .. "  ·  " .. app.L.reputationRewardPending end
        self.text:SetFormattedText("%s  %d%%", label, percent)
    else
        self.mode, self.faction = MODE_XP, nil
        self.bar:SetMinMaxValues(0, xp.maximum)
        self.bar:SetValue(xp.current)
        self.text:SetFormattedText("%s  %d%%", app.L.xp, math.floor(xp.current / xp.maximum * 100))
        self.current, self.maximum = xp.current, xp.maximum
    end
    paintMode(self, self.mode, faction)
end

local function tooltip(frame, module)
    frame:SetScript("OnEnter", function()
        local faction = module.faction
        GameTooltip:SetOwner(frame, "ANCHOR_TOP")
        if module.mode == MODE_REPUTATION and faction then
            GameTooltip:SetText(faction.name)
            if faction.standing then GameTooltip:AddLine(faction.standing, 0.8, 0.9, 0.9, true) end
            GameTooltip:AddLine(string.format("%d / %d", faction.current - faction.minimum, faction.maximum - faction.minimum), 1, 1, 1)
            GameTooltip:Show()
            return
        end
        if not module.current then return end
        GameTooltip:SetText(app.L.xp)
        GameTooltip:AddLine(string.format("%d / %d", module.current, module.maximum), 1, 1, 1)
        GameTooltip:AddLine(string.format(app.L.xpProgress, math.floor(module.current / module.maximum * 100)), 0.8, 0.9, 0.9, true)
        GameTooltip:AddLine(string.format(app.L.xpRemaining, module.maximum - module.current), 0.8, 0.9, 0.9, true)
        local rested = type(GetXPExhaustion) == "function" and plain(GetXPExhaustion(), "number") or nil
        if rested then GameTooltip:AddLine(app.L.rested .. ": " .. rested, 0.5, 0.8, 1) end
        GameTooltip:Show()
    end)
    frame:SetScript("OnLeave", function()
        if type(GameTooltip.IsOwned) ~= "function" or GameTooltip:IsOwned(frame) then GameTooltip:Hide() end
    end)
end

app:RegisterComponent({ id = "experience", label = "experience",
    -- Either an XP range or a watched faction is enough; the client decides
    -- which one applies at any moment.
    Supported = function()
        return (type(UnitXP) == "function" and type(UnitXPMax) == "function")
            or (type(C_Reputation) == "table" and type(C_Reputation.GetWatchedFactionData) == "function")
            or type(GetWatchedFactionInfo) == "function"
    end,
    Enable = function(self)
        self.nativeSuppressed, self.nativeFailed = nil, nil
        if not self.frame then
            local frame = CreateFrame("Frame", "LumaUIExperience", UIParent, "BackdropTemplate")
            frame:SetSize(650, 20)
            self.frame = frame
            self.bar = app.Theme:Bar(frame, 18)
            self.bar:SetPoint("TOPLEFT", 1, -1)
            self.bar:SetPoint("BOTTOMRIGHT", -1, 1)
            self.text = app.Theme:Text(self.bar, 11)
            self.text:SetPoint("CENTER")
            self.text:SetWidth(630)
            self.text:SetWordWrap(false)
            self.text:SetJustifyH("CENTER")
            frame:EnableMouse(true)
            tooltip(frame, self)
            local screenHeight = UIParent:GetHeight()
            app.Layout:Join("topInfo", "experience", frame, 0, screenHeight / 2 - 64,
                { label = app.L.topInfoGroup, x = 0, y = screenHeight / 2 - 47, width = 650, height = 59 })
        end
        -- Edit Mode can re-show the native container after the player moves it;
        -- the replacement owns the reading, so the suppression is replayed with
        -- every layout pass instead of only once at login.
        for _, event in ipairs({ "PLAYER_XP_UPDATE", "PLAYER_LEVEL_UP", "UPDATE_EXHAUSTION", "DISABLE_XP_GAIN", "ENABLE_XP_GAIN",
            "PLAYER_ENTERING_WORLD", "EDIT_MODE_LAYOUTS_UPDATED", "UPDATE_FACTION",
            "MAJOR_FACTION_RENOWN_LEVEL_CHANGED", "CHAT_MSG_COMBAT_FACTION_CHANGE" }) do
            self:Listen(event, update)
        end
        update(self)
    end,
    Refresh = function(self)
        if not self.frame then return end
        app.Theme:PaintSurface(self.frame, "hud")
        update(self)
    end,
    Disable = function(self)
        if self.frame then self.frame:Hide() end
        suppressNative(self, false)
        self.nativeSuppressed = nil
    end,
})
