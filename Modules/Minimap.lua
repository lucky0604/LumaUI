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
    if self.zonePlate then self.zonePlate:SetShown(shown) end
end

-- Long zone names must stay inside the map column. The native zone FontString
-- has no width of its own on every build; give it the map width and let the
-- client truncate instead of letting the text spill past the square frame.
local function fitZone(self)
    local zoneText = _G.MinimapZoneText
    if not zoneText or not Minimap then return end
    if self.zoneWidth == nil then
        local called, width = pcall(zoneText.GetWidth, zoneText)
        self.zoneWidth = called and app.Capabilities.Plain(width, "number") or nil
        if type(zoneText.GetWordWrap) == "function" then
            local wrapped, value = pcall(zoneText.GetWordWrap, zoneText)
            self.zoneWrap = wrapped and value or nil
        end
    end
    local called, mapWidth = pcall(Minimap.GetWidth, Minimap)
    mapWidth = called and app.Capabilities.Plain(mapWidth, "number") or nil
    if not mapWidth or mapWidth <= 0 then return end
    local width = math.max(40, mapWidth - 24)
    if type(zoneText.SetWidth) == "function" then zoneText:SetWidth(width) end
    if type(zoneText.SetWordWrap) == "function" then zoneText:SetWordWrap(false) end
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
        fitZone(self)
    end
    if self.edge then
        self.edge:SetBackdrop({ edgeFile = app.Theme.white, edgeSize = app.Pixel:Pixels(1, self.edge) })
        local line = app.Theme.colors.line
        self.edge:SetBackdropBorderColor(line[1], line[2], line[3], 0.85)
    end
    setShown(self, Minimap:IsVisible())
end

local function updateInfo(self)
    -- Pearl keeps the minimap itself clean by default: time and coordinates
    -- live on the bottom strip, and the panel carries only the zone label. The
    -- explicit "minimap" clock choice still brings the small readout back.
    local profile = app.Store and app.Store:Profile()
    local showClock = profile ~= nil and profile.ui.clock == "minimap"
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

    -- The zone name sits on its own quiet band under the square map, as in the
    -- visual target; the native FontString keeps the text and its click target.
    if _G.MinimapZoneText then
        local zonePlate = CreateFrame("Frame", "LumaUIMinimapZone", UIParent, "BackdropTemplate")
        zonePlate:SetFrameStrata("LOW")
        zonePlate:EnableMouse(false)
        zonePlate:SetPoint("TOPLEFT", MinimapZoneText, "TOPLEFT", -10, 5)
        zonePlate:SetPoint("BOTTOMRIGHT", MinimapZoneText, "BOTTOMRIGHT", 10, -5)
        app.Surface:Plate(zonePlate, "hud")
        self.zonePlate = zonePlate
    end

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

    -- 012 phase 14: the low-frequency entries live in one LumaUI drawer under
    -- the map. Every button is LumaUI's own and calls the client's documented
    -- entry point; no native button is moved, hidden or reparented, so calendar,
    -- tracking and third-party buttons keep their own position and clicks.
    local toggle = app.Controls:Button(panel, "···", 22, function(current)
        if module.drawer then module.drawer:SetShown(not module.drawer:IsShown()) end
    end, { height = 18, size = 11 })
    toggle:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -4, -4)
    self.drawerToggle = toggle

    local drawer = CreateFrame("Frame", "LumaUIMinimapDrawer", UIParent, "BackdropTemplate")
    drawer:SetFrameStrata("DIALOG")
    drawer:SetSize(148, 4 + 6 * 24)
    drawer:SetPoint("TOPLEFT", panel, "BOTTOMLEFT", 0, -4)
    app.Surface:Plate(drawer, "window")
    drawer:Hide()
    self.drawer = drawer
    local entries = {
        { text = app.L.drawerSettings, run = function() app.Settings:Toggle() end },
        { text = app.L.drawerBags, run = function()
            local inventory = app.components.inventory
            if inventory and inventory.running then inventory:Toggle() end
        end },
        { text = app.L.drawerCharacter, run = function()
            local window = app.components.characterWindow
            if window and window.running then window:Toggle() end
        end },
        { text = app.L.drawerLayout, run = function() app.Unlock:Toggle() end },
        { text = app.L.drawerCalendar, run = function()
            if type(ToggleCalendar) == "function" then ToggleCalendar() end
        end },
        { text = app.L.drawerMap, run = function()
            if type(ToggleWorldMap) == "function" then ToggleWorldMap() end
        end },
    }
    self.drawerButtons = {}
    for index, entry in ipairs(entries) do
        local button = app.Controls:Button(drawer, entry.text, 136, entry.run, { height = 20, size = 11 })
        button:SetPoint("TOPLEFT", 6, -4 - (index - 1) * 24)
        self.drawerButtons[index] = button
    end
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
            if frame == Minimap and not self.sizeHooked then
                self.sizeHooked = true
                frame:HookScript("OnSizeChanged", function()
                    if module.running then fitZone(module) end
                end)
            end
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
        if self.zonePlate then self.zonePlate:Show() end
        self:Listen("ZONE_CHANGED", function() fitZone(module) end)
        self:Listen("ZONE_CHANGED_NEW_AREA", function() fitZone(module) end)
        style(self)
        updateInfo(self)
        self:Every(1, updateInfo)
    end,
    Refresh = function(self)
        style(self)
        updateInfo(self)
    end,
    Disable = function(self)
        if self.drawer then self.drawer:Hide() end
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
        if zoneText then
            if self.zoneColor then zoneText:SetTextColor(unpack(self.zoneColor)) end
            if self.zoneWidth and type(zoneText.SetWidth) == "function" then
                zoneText:SetWidth(self.zoneWidth)
            end
            if self.zoneWrap ~= nil and type(zoneText.SetWordWrap) == "function" then
                zoneText:SetWordWrap(self.zoneWrap)
            end
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
    return string.format("minimap: %s=%d (%s), clock=%s, drawer=%s, third-party=%s",
        app.L.minimapButtons, #known, table.concat(known, ","),
        tostring(clock), self.drawer and self.drawer:IsShown() and "open" or "closed",
        app.L.minimapThirdPartyKept)
end
