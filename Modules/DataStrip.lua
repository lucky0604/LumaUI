local _, app = ...

-- The Pearl information strip: one quiet band along the bottom edge, split by
-- hairline gaps into the readings the visual target shows (money, durability,
-- performance, bags, zone, guild/friends, mail, coordinates, time). Every value
-- is read from a public API and kept plain; secret values never reach a string
-- concatenation or a comparison here.
local WIDTH_COMPACT = 340
local HEIGHT = app.Theme.strip.height
local ROW_HEIGHT = HEIGHT - 6

local FIELDS = {
    { key = "money", width = 100, icon = "Interface\\Icons\\INV_Misc_Coin_01" },
    { key = "durability", width = 92, icon = "Interface\\Icons\\Trade_BlackSmithing" },
    { key = "performance", width = 100, icon = "Interface\\Icons\\Spell_Arcane_Arcane04" },
    { key = "bags", width = 80, icon = "Interface\\Icons\\INV_Misc_Bag_08" },
    { key = "zone", width = 170, icon = "Interface\\Icons\\INV_Misc_Map_01" },
    { key = "guild", width = 124, icon = "Interface\\Icons\\Achievement_GuildPerk_EveryonesAFriend" },
    { key = "mail", width = 54, icon = "Interface\\Icons\\INV_Letter_05" },
    { key = "coords", width = 76, icon = "Interface\\Icons\\INV_Misc_Map_02" },
    { key = "clock", width = 46, icon = "Interface\\Icons\\INV_Misc_PocketWatch_01" },
}
local LEFT_ORDER = { "money", "durability", "performance", "bags" }
local RIGHT_ORDER = { "clock", "coords", "mail", "guild" }

local function ui()
    local profile = app.Store and app.Store:Profile()
    return profile and profile.ui or {}
end

local function clockPlacement()
    local value = ui().clock
    if value == "minimap" or value == "off" then return value end
    return "strip"
end

local function isCompact()
    return ui().stripCompact == true
end

local function hex(color)
    local function part(value)
        value = math.max(0, math.min(1, value or 0))
        return string.format("%02x", math.floor(value * 255 + 0.5))
    end
    return part(color[1]) .. part(color[2]) .. part(color[3])
end

local function tone(text, color)
    if text == nil or text == "" then return "" end
    return "|cff" .. hex(color) .. tostring(text) .. "|r"
end

local function label(text)
    return tone(text, app.Theme.colors.muted)
end

local function value(text)
    return tone(text, app.Theme:Accent())
end

local function gameTime()
    if type(GetGameTime) ~= "function" then return nil end
    local ok, hour, minute = pcall(GetGameTime)
    hour = ok and app.Capabilities.Plain(hour, "number") or nil
    minute = ok and app.Capabilities.Plain(minute, "number") or nil
    if not hour or not minute then return nil end
    return string.format("%02d:%02d", hour, minute)
end

local function plainNumber(api, ...)
    if type(api) ~= "function" then return nil end
    local ok, result = pcall(api, ...)
    return ok and app.Capabilities.Plain(result, "number") or nil
end

local function durability()
    local read = _G.GetInventoryItemDurability
    if type(read) ~= "function" then return nil end
    local lowest
    for slot = 1, 19 do
        local ok, current, maximum = pcall(read, slot)
        current = ok and app.Capabilities.Plain(current, "number") or nil
        maximum = ok and app.Capabilities.Plain(maximum, "number") or nil
        if current and maximum and maximum > 0 then
            local percent = current / maximum * 100
            if not lowest or percent < lowest then lowest = percent end
        end
    end
    if not lowest then return nil end
    return math.floor(lowest + 0.5)
end

local function bags()
    local api = _G.C_Container
    local slotsFn = api and api.GetContainerNumSlots or _G.GetContainerNumSlots
    local freeFn = api and api.GetContainerNumFreeSlots or _G.GetContainerNumFreeSlots
    if type(slotsFn) ~= "function" or type(freeFn) ~= "function" then return nil end
    local used, total = 0, 0
    for bag = 0, 5 do
        local slots = plainNumber(slotsFn, bag)
        local free = plainNumber(freeFn, bag)
        if slots and free and slots > 0 then
            total = total + slots
            used = used + math.max(0, slots - free)
        end
    end
    if total == 0 then return nil end
    return used, total
end

local function coords()
    local mapApi = _G.C_Map
    if type(mapApi) ~= "table" or type(mapApi.GetBestMapForUnit) ~= "function"
        or type(mapApi.GetPlayerMapPosition) ~= "function" then return nil end
    local map = mapApi.GetBestMapForUnit("player")
    local position = map and mapApi.GetPlayerMapPosition(map, "player")
    if not position then return nil end
    local x, y = position:GetXY()
    x = app.Capabilities.Plain(x, "number")
    y = app.Capabilities.Plain(y, "number")
    if not x or not y then return nil end
    return string.format("%.1f, %.1f", x * 100, y * 100)
end

local function performance()
    local fps = plainNumber(_G.GetFramerate)
    local latency
    if type(GetNetStats) == "function" then
        local ok, _, _, home, world = pcall(GetNetStats)
        home = ok and app.Capabilities.Plain(home, "number") or nil
        world = ok and app.Capabilities.Plain(world, "number") or nil
        if home and world then latency = math.max(home, world) end
    end
    if not fps and not latency then return nil end
    local text = label(app.L.fps) .. " " .. value(fps and math.floor(fps + 0.5) or "--")
    if latency then
        text = text .. "   " .. label(app.L.latency) .. " " .. value(latency)
    end
    return text
end

local function update(self)
    if not self.frame or not self.frame:IsShown() then return end
    local accent = app.Theme:Accent()
    if self.money then
        local amount = plainNumber(_G.GetMoney)
        local text = "--"
        if amount and type(GetMoneyString) == "function" then
            local ok, formatted = pcall(GetMoneyString, amount, true)
            formatted = ok and app.Capabilities.Plain(formatted, "string") or nil
            if formatted then text = formatted end
        end
        self.money:SetText(text)
        self.money:SetTextColor(accent[1], accent[2], accent[3])
    end
    if self.durability and self.durability:IsShown() then
        local percent = durability()
        self.durability:SetText(label(app.L.durability) .. " " ..
            value(percent and (percent .. "%") or "--"))
    end
    if self.performance and self.performance:IsShown() then
        self.performance:SetText(performance() or "--")
    end
    if self.bags and self.bags:IsShown() then
        local used, total = bags()
        self.bags:SetText(label(app.L.bagLabel) .. " " ..
            value(used and (used .. "/" .. total) or "--"))
    end
    if self.zone and self.zone:IsShown() then
        local zone = type(GetRealZoneText) == "function"
            and app.Capabilities.Plain(GetRealZoneText(), "string") or nil
        self.zone:SetText(zone or "--")
        local text = app.Theme.colors.text
        self.zone:SetTextColor(text[1], text[2], text[3])
    end
    if self.guild and self.guild:IsShown() then
        local guild = 0
        if type(IsInGuild) == "function" then
            local ok, inGuild = pcall(IsInGuild)
            if ok and app.Capabilities.Plain(inGuild, "boolean") == true then
                guild = plainNumber(_G.GetNumGuildMembers) or 0
            end
        end
        local friends = plainNumber(_G.GetNumFriends) or 0
        self.guild:SetText(label(app.L.guildLabel) .. " " .. value(guild) ..
            "   " .. label(app.L.friendsLabel) .. " " .. value(friends))
    end
    if self.mail and self.mail:IsShown() then
        local count = plainNumber(_G.GetInboxNumItems) or 0
        self.mail:SetText(label(app.L.mailLabel) .. " " .. value(count))
    end
    if self.coords and self.coords:IsShown() then
        self.coords:SetText(coords() or "--")
        self.coords:SetTextColor(accent[1], accent[2], accent[3])
    end
    if self.clock and self.clock:IsShown() then
        self.clock:SetText(gameTime() or "--")
        self.clock:SetTextColor(accent[1], accent[2], accent[3])
    end
end

local function segment(self, key)
    local frame = CreateFrame("Frame", nil, self.frame)
    frame:SetHeight(ROW_HEIGHT)
    frame:EnableMouse(false)
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

local function reportFor(key)
    if key == "zone" or key == "coords" then return "ShowZone" end
    if key == "performance" then return "ShowPerformance" end
    if key == "money" then return "ShowMoney" end
    if key == "clock" then return "ShowRaid" end
    return "ShowSummary"
end

local function buildField(self, def)
    local holder = segment(self, def.key)
    holder:SetWidth(def.width)
    if def.key ~= "money" and def.key ~= "zone" then
        local line = holder:CreateTexture(nil, "ARTWORK")
        line:SetWidth(app.Pixel:Pixels(1, holder))
        line:SetHeight(12)
        line:SetPoint("LEFT", -4, 0)
        local color = app.Theme.colors.line
        line:SetColorTexture(color[1], color[2], color[3], 0.28)
    end
    local offset = 0
    if def.icon then
        local icon = holder:CreateTexture(nil, "ARTWORK")
        icon:SetSize(12, 12)
        icon:SetPoint("LEFT", 0, 0)
        if type(icon.SetTexture) == "function" then
            pcall(icon.SetTexture, icon, def.icon)
        end
        local accent = app.Theme:Accent()
        if type(icon.SetVertexColor) == "function" then icon:SetVertexColor(accent[1], accent[2], accent[3]) end
        offset = 16
    end
    local text = app.Type:Text(holder, "body")
    text:SetPoint("LEFT", offset, 0)
    text:SetWidth(def.width - offset)
    text:SetWordWrap(false)
    text:SetJustifyH("LEFT")
    self[def.key] = text
    hover(holder, function(reports, owner) reports[reportFor(def.key)](reports, owner) end)
end

local function relayout(self)
    -- Below 1200 px the left and right clusters would meet the centred zone
    -- name; fall back to the compact reading instead of drawing overlapping text.
    local compact = isCompact() or UIParent:GetWidth() < 1200
    local showClock = clockPlacement() == "strip"
    local width = math.max(900, UIParent:GetWidth() - 32)
    self.frame:SetWidth(compact and WIDTH_COMPACT or width)
    for _, def in ipairs(FIELDS) do
        local shown = not compact and (def.key ~= "clock" or showClock)
        self.segments[def.key]:SetShown(shown)
        if self[def.key] then self[def.key]:SetShown(shown) end
    end
    if compact then
        -- Compact keeps the old zone + clock reading, with the remainder as one
        -- hover summary so the band still answers every other field.
        self.segments.zone:SetShown(true)
        self.zone:SetShown(true)
        self.segments.clock:SetShown(showClock)
        self.clock:SetShown(showClock)
        self.segments.zone:ClearAllPoints()
        self.segments.zone:SetPoint("LEFT", 12, 0)
        self.segments.clock:ClearAllPoints()
        self.segments.clock:SetPoint("LEFT", 198, 0)
        self.summary:SetShown(true)
        self.summary:ClearAllPoints()
        self.summary:SetPoint("LEFT", showClock and self.segments.clock or self.segments.zone, "RIGHT", 10, 0)
        self.summary:SetPoint("RIGHT", self.frame, "RIGHT", -12, 0)
        return
    end

    self.summary:SetShown(false)
    -- Full width: readings hug the left and right edges, the zone name owns the
    -- centre, and the space between is deliberately empty as in the visual target.
    local left = self.frame
    for _, key in ipairs(LEFT_ORDER) do
        local holder = self.segments[key]
        holder:ClearAllPoints()
        holder:SetPoint("LEFT", left, left == self.frame and "LEFT" or "RIGHT",
            left == self.frame and 12 or 8, 0)
        left = holder
    end
    local zone = self.segments.zone
    zone:ClearAllPoints()
    zone:SetPoint("CENTER", self.frame, "CENTER", 0, 0)
    local right = self.frame
    local order = showClock and RIGHT_ORDER or { "coords", "mail", "guild" }
    for _, key in ipairs(order) do
        local holder = self.segments[key]
        holder:ClearAllPoints()
        holder:SetPoint("RIGHT", right, right == self.frame and "RIGHT" or "LEFT",
            right == self.frame and -12 or -8, 0)
        right = holder
    end
end

app:RegisterComponent({ id = "dataStrip", label = "dataStrip",
    Enable = function(self)
        if not self.frame then
            local frame = CreateFrame("Frame", "LumaUIDataStrip", UIParent, "BackdropTemplate")
            local fullWidth = math.max(900, UIParent:GetWidth() - 32)
            frame:SetSize(fullWidth, HEIGHT)
            frame:EnableMouse(false)
            self.frame = frame
            self.segments = self.segments or {}

            for _, def in ipairs(FIELDS) do buildField(self, def) end

            -- The strip is a bottom bar in the Pearl target, not a second top
            -- row: it owns one layout group so moving it never touches the XP
            -- bar group.
            local screenHeight = UIParent:GetHeight()
            app.Layout:Join("bottomBar", "dataStrip", frame, 0, -screenHeight / 2 + HEIGHT,
                { label = app.L.bottomBar, x = 0, y = -screenHeight / 2 + HEIGHT,
                    width = fullWidth, height = HEIGHT })

            local summary = segment(self, "summary")
            summary:SetHeight(HEIGHT - 8)
            summary:SetPoint("TOP", frame, "TOP", 0, -2)
            summary:SetPoint("BOTTOM", frame, "BOTTOM", 0, 2)
            hover(summary, function(reports, owner) reports:ShowSummary(owner) end)
            self.summary = summary
        end
        app.Surface:Plate(self.frame, "hud")
        relayout(self)
        self.frame:Show()
        self:Listen("PLAYER_MONEY", update)
        self:Listen("PLAYER_ENTERING_WORLD", update)
        self:Listen("ZONE_CHANGED_NEW_AREA", update)
        self:Listen("BAG_UPDATE_DELAYED", update)
        self:Listen("UPDATE_INVENTORY_DURABILITY", update)
        self:Listen("GUILD_ROSTER_UPDATE", update)
        self:Listen("FRIENDLIST_UPDATE", update)
        self:Listen("UPDATE_PENDING_MAIL", update)
        self:Listen("DISPLAY_SIZE_CHANGED", function(current) relayout(current) end)
        self:Listen("UI_SCALE_CHANGED", function(current) relayout(current) end)
        self:Every(1, update)
        update(self)
    end,
    Refresh = function(self)
        if not self.frame then return end
        relayout(self)
        app.Surface:Plate(self.frame, "hud")
        update(self)
    end,
    Disable = function(self) if self.frame then self.frame:Hide() end end,
})
