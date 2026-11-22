local _, app = ...
local module

-- Square mask is a built-in solid texture; 186178 is the modern circular mask.
local SQUARE_MASK = "Interface\\Buttons\\WHITE8X8"
local CIRCLE_MASK = 186178

local function nativePlayerCoords()
    local container = MinimapCluster and MinimapCluster.MinimapContainer
    return (container and container.PlayerCoords) or (MinimapCluster and MinimapCluster.PlayerCoords)
end

-- The native entries a square minimap leaves in place. LumaUI reads whether
-- each one exists so the diagnostics can say which shortcuts still work, but
-- never moves, hides or recolors them: their anchors belong to Edit Mode and,
-- for third-party buttons, to whoever created them.
local KNOWN_BUTTONS = {
    { key = "calendar", object = function() return _G.GameTimeFrame end },
    { key = "tracking", object = function()
        local cluster = _G.MinimapCluster
        return (_G.MiniMapTracking) or (cluster and (cluster.Tracking or cluster.TrackingButton)) or nil
    end },
    { key = "addons", object = function() return _G.AddonCompartmentFrame end },
    { key = "worldMap", object = function()
        local cluster = _G.MinimapCluster
        return _G.MiniMapWorldMapButton or (cluster and (cluster.ToggleMinimapButton or cluster.ZoneTextButton)) or nil
    end },
}

local function knownButtons()
    local found = {}
    for _, entry in ipairs(KNOWN_BUTTONS) do
        local ok, frame = pcall(entry.object)
        if ok and frame then found[#found + 1] = entry.key end
    end
    return found
end

local function setShown(self, shown)
    if self.panel then self.panel:SetShown(shown) end
    if self.edge then self.edge:SetShown(shown) end
end

local function style(self)
    if not Minimap then return end
    local accent = app.Theme:Accent()
    if self.panel then app.Surface:Plate(self.panel, "hud") end
    if self.rule then
        self.rule:SetColorTexture(accent[1], accent[2], accent[3], 0.75)
        self.rule:SetHeight(app.Pixel:Pixels(1, self.panel))
    end

    -- The round native compass ring and the top header plate are the nested
    -- Blizzard art. Hide them; the zone label, tracking menu and every map
    -- button stay where they are.
    local compass = _G.MinimapCompassTexture
    if compass then
        if self.compassShown == nil then
            self.compassShown = compass:IsShown()
            local ok, red, green, blue, alpha = pcall(compass.GetVertexColor, compass)
            if ok then self.compassColor = { red, green, blue, alpha } end
            local desaturated, value = pcall(compass.IsDesaturated, compass)
            if desaturated then self.compassDesaturated = value end
        end
        compass:Hide()
        compass:SetDesaturated(true)
        compass:SetVertexColor(accent[1], accent[2], accent[3])
    end
    local borderTop = MinimapCluster and MinimapCluster.BorderTop
    if borderTop then
        if self.borderTopShown == nil then self.borderTopShown = borderTop:IsShown() end
        borderTop:Hide()
    end
    local zoneText = _G.MinimapZoneText
    if zoneText then
        if not self.zoneColor then self.zoneColor = { zoneText:GetTextColor() } end
        local text = app.Theme.colors.text
        zoneText:SetTextColor(text[1], text[2], text[3])
    end
    if self.edge then
        self.edge:SetBackdrop({ edgeFile = app.Theme.white, edgeSize = app.Pixel:Pixels(1, self.edge) })
        local line = app.Theme.colors.line
        self.edge:SetBackdropBorderColor(line[1], line[2], line[3], 0.85)
    end
    setShown(self, Minimap:IsVisible())
end

local function updateInfo(self)
    -- One clock for the whole UI. The strip owns it unless this profile asked
    -- for the minimap panel; with "off" neither LumaUI surface prints the time
    -- and the native calendar entry stays the only clock.
    local placement = app.Store:Profile().ui.clock
    local showClock = placement == "minimap"
    if self.clock then
        local hour, minute = GetGameTime()
        self.clock:SetFormattedText("%02d:%02d", hour, minute)
        self.clock:SetShown(showClock)
    end
    if not self.useCoords or not self.coords then
        if self.coords then self.coords:Hide() end
        return
    end
    local map = C_Map.GetBestMapForUnit("player")
    local position = map and C_Map.GetPlayerMapPosition(map, "player")
    if position then
        local x, y = position:GetXY()
        x = app.Capabilities.Plain(x, "number")
        y = app.Capabilities.Plain(y, "number")
        if x and y then
            self.coords:SetFormattedText("%.0f, %.0f", x * 100, y * 100)
            self.coords:Show()
            return
        end
    end
    self.coords:Hide()
end

local function hideNativeCoords(self)
    local playerCoords = nativePlayerCoords()
    if playerCoords then
        if self.coordsShown == nil then self.coordsShown = playerCoords:IsShown() end
        playerCoords:Hide()
    end
end

local function restoreNativeCoords(self)
    local playerCoords = nativePlayerCoords()
    if playerCoords and self.coordsShown ~= nil then
        if self.coordsShown then playerCoords:Show() else playerCoords:Hide() end
    end
end

local function build(self)
    local panel = CreateFrame("Frame", "LumaUIMinimapPanel", UIParent, "BackdropTemplate")
    panel:SetFrameStrata("BACKGROUND")
    panel:EnableMouse(false)
    panel:SetPoint("TOPLEFT", Minimap, "TOPLEFT", -6, 6)
    panel:SetPoint("BOTTOMRIGHT", Minimap, "BOTTOMRIGHT", 6, -22)
    self.panel = panel
    app.Surface:Plate(panel, "hud")
    self.rule = panel:CreateTexture(nil, "ARTWORK")
    self.rule:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 6, 3)
    self.rule:SetWidth(24)

    local edge = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    edge:SetFrameStrata("MEDIUM")
    edge:EnableMouse(false)
    edge:SetPoint("TOPLEFT", Minimap, "TOPLEFT", 0, 0)
    edge:SetPoint("BOTTOMRIGHT", Minimap, "BOTTOMRIGHT", 0, 0)
    edge:SetBackdrop({ edgeFile = app.Theme.white, edgeSize = app.Pixel:Pixels(1, edge) })
    edge:Hide()
    self.edge = edge

    self.clock = app.Type:Text(panel, "micro")
    self.clock:SetPoint("BOTTOMLEFT", 6, 6)
    self.coords = app.Type:Text(panel, "micro")
    self.coords:SetPoint("BOTTOMRIGHT", -6, 6)
    self.useCoords = type(C_Map) == "table"
        and type(C_Map.GetBestMapForUnit) == "function"
        and type(C_Map.GetPlayerMapPosition) == "function"
    if not self.useCoords then self.coords:Hide() end
end

local function hook(self)
    self.hooked = self.hooked or {}
    local frames = { Minimap }
    if MinimapCluster then frames[#frames + 1] = MinimapCluster end
    for _, frame in ipairs(frames) do
        if frame and not self.hooked[frame] then
            frame:HookScript("OnShow", function()
                if module.running then style(module); updateInfo(module) end
            end)
            frame:HookScript("OnHide", function()
                if module.running then setShown(module, false) end
            end)
            self.hooked[frame] = true
        end
    end
end

module = app:RegisterComponent({ id = "minimap", label = "minimap",
    Supported = function() return Minimap ~= nil end,
    Enable = function(self)
        if not self.panel then build(self) end
        hook(self)
        if Minimap.SetMaskTexture then
            Minimap:SetMaskTexture(SQUARE_MASK)
            self.maskApplied = true
        end
        local compass = _G.MinimapCompassTexture
        if compass then
            if self.compassShown == nil then self.compassShown = compass:IsShown() end
            compass:Hide()
        end
        if self.useCoords then hideNativeCoords(self) end
        style(self)
        updateInfo(self)
        self:Every(1, updateInfo)
    end,
    Refresh = function(self)
        style(self)
        updateInfo(self)
    end,
    Disable = function(self)
        setShown(self, false)
        if self.maskApplied and Minimap.SetMaskTexture then
            Minimap:SetMaskTexture(CIRCLE_MASK)
            self.maskApplied = false
        end
        local compass = _G.MinimapCompassTexture
        if compass then
            if self.compassShown == nil then self.compassShown = compass:IsShown() end
            compass:SetShown(self.compassShown)
            compass:SetDesaturated(self.compassDesaturated or false)
            if self.compassColor then
                compass:SetVertexColor(unpack(self.compassColor))
            else
                compass:SetVertexColor(1, 1, 1, 1)
            end
        end
        local borderTop = MinimapCluster and MinimapCluster.BorderTop
        if borderTop and self.borderTopShown ~= nil then
            borderTop:SetShown(self.borderTopShown)
        end
        local zoneText = _G.MinimapZoneText
        if zoneText and self.zoneColor then
            zoneText:SetTextColor(unpack(self.zoneColor))
        end
        restoreNativeCoords(self)
    end,
})

-- One diagnostics line: which native entries the square frame still offers and
-- that third-party buttons are left exactly where their owners put them. A
-- missing optional entry is listed instead of being hidden, so a player can
-- tell the difference between "LumaUI removed it" and "this client lacks it".
function module:Describe()
    if not self.running then return nil end
    local known = knownButtons()
    local clock = app.Store:Profile().ui.clock
    return string.format("minimap: %s=%d (%s), clock=%s, third-party=%s",
        app.L.minimapButtons, #known, table.concat(known, ","),
        tostring(clock), app.L.minimapThirdPartyKept)
end
