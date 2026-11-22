local _, app = ...
local module

-- Two readings of the same strip. Compact is the default: the constant
-- display carries the zone and the time only, and everything else (money,
-- network, coordinates, durability) is one hover away. The full layout is
-- still available as a saved per-profile choice.
local WIDTH_FULL, WIDTH_COMPACT, HEIGHT = 650, 340, 30

local function ui()
    local profile = app.Store and app.Store:Profile()
    return profile and profile.ui or {}
end

-- Exactly one LumaUI clock is visible at a time. The strip owns it by default;
-- "minimap" moves it into the minimap panel and "off" leaves the time to the
-- native calendar button.
local function clockPlacement()
    local value = ui().clock
    if value == "minimap" or value == "off" then return value end
    return "strip"
end

local function isCompact()
    return ui().stripCompact ~= false
end

local function gameTime()
    if type(GetGameTime) ~= "function" then return nil end
    local ok, hour, minute = pcall(GetGameTime)
    hour = ok and app.Capabilities.Plain(hour, "number") or nil
    minute = ok and app.Capabilities.Plain(minute, "number") or nil
    if not hour or not minute then return nil end
    return string.format("%02d:%02d", hour, minute)
end

local function update(self)
    if not self.frame or not self.frame:IsShown() then return end
    if self.zone then
        local zone = type(GetRealZoneText) == "function" and app.Capabilities.Plain(GetRealZoneText(), "string")
        self.zone:SetText(zone or "")
    end
    if self.clock and self.clock:IsShown() then
        self.clock:SetText(gameTime() or "")
    end
    if self.performance and self.performance:IsShown() then
        local fps = type(GetFramerate) == "function" and app.Capabilities.Plain(GetFramerate(), "number")
        local latency
        if type(GetNetStats) == "function" then
            local ok, _, _, home, world = pcall(GetNetStats)
            home = ok and app.Capabilities.Plain(home, "number") or nil
            world = ok and app.Capabilities.Plain(world, "number") or nil
            if home and world then latency = math.max(home, world) end
        end
        if fps and latency then
            self.performance:SetFormattedText("%d %s  ·  %d %s", math.floor(fps + 0.5), app.L.fps, latency, app.L.latency)
        else
            self.performance:SetText("")
        end
    end
    if self.money and self.money:IsShown() and type(GetMoney) == "function" then
        local amount = app.Capabilities.Plain(GetMoney(), "number")
        local label = ""
        if amount and type(GetMoneyString) == "function" then
            local ok, value = pcall(GetMoneyString, amount, true)
            label = ok and app.Capabilities.Plain(value, "string") or ""
        end
        self.money:SetText(label)
    end
end

-- A segment is one hover target. Mouse is enabled only on its own rectangle,
-- so the strip never steals clicks from anything underneath it.
local function segment(self, key)
    local frame = CreateFrame("Frame", nil, self.frame)
    frame:SetHeight(24)
    self.segments[key] = frame
    return frame
end

local function hover(frame, report)
    frame:EnableMouse(true)
    frame:SetScript("OnEnter", function()
        if not app.ready or not app.Reports then return end
        app:Call("dataStrip/hover", report, app.Reports, frame)
    end)
    frame:SetScript("OnLeave", function()
        if type(GameTooltip.IsOwned) ~= "function" or GameTooltip:IsOwned(frame) then GameTooltip:Hide() end
    end)
end

-- One layout pass decides which fields the constant display carries. Hidden
-- fields stay built and anchored, so switching modes on a profile change never
-- rebuilds the strip; only their hover rectangles stop catching the mouse, so
-- the wide summary segment underneath owns that empty area without shadowing
-- a field that is actually printed.
local function relayout(self)
    local compact = isCompact()
    -- The strip prints the time only when this profile gave it the clock; with
    -- "minimap" the panel owns it and with "off" the native entry does.
    local showClock = clockPlacement() == "strip"
    self.frame:SetWidth(compact and WIDTH_COMPACT or WIDTH_FULL)
    self.zone:SetShown(true)
    self.clock:SetShown(showClock)
    self.performance:SetShown(not compact)
    self.money:SetShown(not compact)
    self.summary:SetShown(compact)
    local segments = self.segments or {}
    if segments.zone then segments.zone:EnableMouse(true) end
    if segments.summary then segments.summary:EnableMouse(compact) end
    if segments.performance then segments.performance:EnableMouse(not compact) end
    if segments.money then segments.money:EnableMouse(not compact) end
    if segments.clock then segments.clock:EnableMouse(showClock) end
    local anchor = self.clock:IsShown() and self.clock or self.zone
    self.summary:ClearAllPoints()
    self.summary:SetPoint("LEFT", anchor, "RIGHT", 16, 0)
    self.summary:SetPoint("RIGHT", self.frame, "RIGHT", -12, 0)
end

app:RegisterComponent({ id = "dataStrip", label = "dataStrip",
    Enable = function(self)
        if not self.frame then
            local frame = CreateFrame("Frame", "LumaUIDataStrip", UIParent, "BackdropTemplate")
            frame:SetSize(WIDTH_FULL, HEIGHT)
            frame:EnableMouse(false)
            self.frame = frame
            self.zone = app.Type:Text(frame, "body")
            self.zone:SetPoint("LEFT", 12, 0)
            self.zone:SetWidth(180)
            self.clock = app.Type:Text(frame, "body")
            self.clock:SetPoint("LEFT", 198, 0)
            self.performance = app.Type:Text(frame, "label")
            self.performance:SetPoint("LEFT", 258, 0)
            self.money = app.Type:Text(frame, "body")
            self.money:SetPoint("RIGHT", -12, 0)
            -- The strip and the experience bar share one top-centre group, so
            -- the pair moves as one layout item.
            local screenHeight = UIParent:GetHeight()
            app.Layout:Join("topInfo", "dataStrip", frame, 0, screenHeight / 2 - 30,
                { label = app.L.topInfoGroup, x = 0, y = screenHeight / 2 - 47, width = WIDTH_FULL, height = 59 })

            self.segments = self.segments or {}
            local zone = segment(self, "zone")
            zone:SetPoint("LEFT", self.zone, "LEFT", -8, 0)
            zone:SetPoint("RIGHT", self.zone, "RIGHT", 8, 0)
            hover(zone, function(reports, owner) reports:ShowZone(owner) end)
            local clock = segment(self, "clock")
            clock:SetPoint("LEFT", self.clock, "LEFT", -8, 0)
            clock:SetPoint("RIGHT", self.clock, "RIGHT", 40, 0)
            hover(clock, function(reports, owner) reports:ShowRaid(owner) end)
            local performance = segment(self, "performance")
            performance:SetPoint("LEFT", self.performance, "LEFT", -6, 0)
            performance:SetPoint("RIGHT", self.performance, "RIGHT", 6, 0)
            hover(performance, function(reports, owner) reports:ShowPerformance(owner) end)
            local money = segment(self, "money")
            money:SetPoint("LEFT", self.money, "LEFT", -8, 0)
            money:SetPoint("RIGHT", self.money, "RIGHT", 8, 0)
            hover(money, function(reports, owner) reports:ShowMoney(owner) end)
            -- Compact keeps the values but not the ink: the free space to the
            -- right of the clock reports everything the strip used to print.
            local summary = segment(self, "summary")
            summary:SetHeight(HEIGHT - 8)
            summary:SetPoint("TOP", frame, "TOP", 0, -2)
            summary:SetPoint("BOTTOM", frame, "BOTTOM", 0, 2)
            hover(summary, function(reports, owner) reports:ShowSummary(owner) end)
            self.summary = summary
        end
        relayout(self)
        self.frame:Show()
        self:Listen("PLAYER_MONEY", update)
        self:Listen("PLAYER_ENTERING_WORLD", update)
        self:Listen("ZONE_CHANGED_NEW_AREA", update)
        self:Every(1, update)
        update(self)
    end,
    Refresh = function(self)
        if not self.frame then return end
        relayout(self)
        -- A HUD support uses the HUD role: it lets the world through instead of
        -- repeating the window surface behind combat information.
        app.Surface:Plate(self.frame, "hud")
        update(self)
    end,
    Disable = function(self) if self.frame then self.frame:Hide() end end,
})
