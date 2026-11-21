local _, app = ...
local module

local function plain(value, expected)
    return app.Capabilities.Plain(value, expected)
end

local MODE_XP, MODE_REPUTATION = "xp", "reputation"

local function maxPlayerLevel()
    -- Only an explicit expansion ceiling may hide the bar. Deriving it from the
    -- player's own level would be circular: a client that reports no XP range at
    -- max level already says so with maximum <= 0.
    if type(GetMaxLevelForPlayerExpansion) ~= "function" then return nil end
    local ok, level = pcall(GetMaxLevelForPlayerExpansion)
    return ok and plain(level, "number") or nil
end

-- Reputation replaces the experience bar whenever the player is watching a
-- faction, exactly as the native bar does; watching it is the client's own
-- statement that reputation is what this character is progressing.
local function watchedFaction()
    if type(GetWatchedFactionInfo) ~= "function" then return nil end
    local ok, name, reaction, minimum, maximum, current = pcall(GetWatchedFactionInfo)
    if not ok then return nil end
    name, reaction = plain(name, "string"), plain(reaction, "number")
    minimum, maximum, current = plain(minimum, "number"), plain(maximum, "number"), plain(current, "number")
    if not name or not minimum or not maximum or not current or maximum <= minimum then return nil end
    local label
    if reaction then
        label = _G["FACTION_STANDING_LABEL" .. reaction]
        if type(label) ~= "string" then label = type(_FACTION_STANDING_LABEL) == "table" and _FACTION_STANDING_LABEL[reaction] or nil end
    end
    return { name = name, reaction = reaction, minimum = minimum, maximum = maximum, current = current,
        standing = type(label) == "string" and label or nil }
end

local function xpState()
    local current = plain(type(UnitXP) == "function" and UnitXP("player") or nil, "number")
    local maximum = plain(type(UnitXPMax) == "function" and UnitXPMax("player") or nil, "number")
    if not current or not maximum or maximum <= 0 then return nil end
    if type(IsXPUserDisabled) == "function" then
        local ok, disabled = pcall(IsXPUserDisabled)
        if ok and disabled == true then return nil end
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
    local faction = watchedFaction()
    local xp = not faction and xpState() or nil
    if not faction and not xp then
        -- Nothing applies to this character right now (max level, XP locked,
        -- no watched faction): the bar hides instead of printing a fake 0%.
        self.mode = nil
        self.frame:Hide()
        return
    end
    self.frame:Show()
    if faction then
        self.mode, self.faction = MODE_REPUTATION, faction
        self.bar:SetMinMaxValues(faction.minimum, faction.maximum)
        self.bar:SetValue(faction.current)
        local percent = math.floor((faction.current - faction.minimum) / (faction.maximum - faction.minimum) * 100)
        local label = faction.name .. (faction.standing and ("  ·  " .. faction.standing) or "")
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
            GameTooltip:AddLine(string.format("%d / %d", faction.current, faction.maximum), 1, 1, 1)
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
    Supported = function() return type(UnitXP) == "function" and type(UnitXPMax) == "function" end,
    Enable = function(self)
        if not self.frame then
            local frame = CreateFrame("Frame", "LumaUIExperience", UIParent, "BackdropTemplate")
            frame:SetSize(650, 20)
            self.frame = frame
            self.bar = app.Theme:Bar(frame, 18)
            self.bar:SetPoint("TOPLEFT", 1, -1)
            self.bar:SetPoint("BOTTOMRIGHT", -1, 1)
            self.text = app.Theme:Text(self.bar, 11)
            self.text:SetPoint("CENTER")
            frame:EnableMouse(true)
            tooltip(frame, self)
            local screenHeight = UIParent:GetHeight()
            app.Layout:Join("topInfo", "experience", frame, 0, screenHeight / 2 - 64,
                { label = app.L.topInfoGroup, x = 0, y = screenHeight / 2 - 47, width = 650, height = 59 })
        end
        for _, event in ipairs({ "PLAYER_XP_UPDATE", "PLAYER_LEVEL_UP", "UPDATE_EXHAUSTION", "DISABLE_XP_GAIN", "ENABLE_XP_GAIN",
            "PLAYER_ENTERING_WORLD", "UPDATE_FACTION", "CHAT_MSG_COMBAT_FACTION_CHANGE" }) do
            self:Listen(event, update)
        end
        update(self)
    end,
    Refresh = function(self)
        if not self.frame then return end
        app.Theme:PaintSurface(self.frame, "hud")
        update(self)
    end,
    Disable = function(self) if self.frame then self.frame:Hide() end end,
})
