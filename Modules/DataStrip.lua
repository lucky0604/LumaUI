local _, app = ...

-- The Pearl information strip: one quiet band along the bottom edge, split by
-- hairline gaps into the readings the visual target shows (money, durability,
-- performance, bags, zone, guild/friends, mail, coordinates, time). Every value
-- is read from a public API and kept plain; secret values never reach a string
-- concatenation or a comparison here.
local WIDTH_COMPACT = 340
local HEIGHT = app.Theme.strip.height
local ROW_HEIGHT = HEIGHT - 6
-- The band owns the screen edge: twelve units of padding, eight between
-- readings, and a centre column for the zone name. The minimum widths below are
-- the text budget, not the rendered width: any leftover space is split evenly so
-- the nine readings spread across the band like the visual target instead of
-- clustering at the two ends.
local PAD, FIELD_GAP, ZONE_WIDTH = 12, 8, 200

local FIELDS = {
    -- The client's money string carries gold, silver and copper (and, on some
    -- builds, inline coin icons), so the reading needs more room than the
    -- numeric part alone. A wider fixed minimum keeps it from running into the
    -- durability field when the amount grows.
    { key = "money", width = 150, icon = "Interface\\Icons\\INV_Misc_Coin_01" },
    { key = "durability", width = 92, icon = "Interface\\Icons\\Trade_BlackSmithing" },
    { key = "performance", width = 100, icon = "Interface\\Icons\\Spell_Arcane_Arcane04" },
    { key = "bags", width = 88, icon = "Interface\\Icons\\INV_Misc_Bag_08" },
    { key = "zone", width = 170, icon = "Interface\\Icons\\INV_Misc_Map_01" },
    { key = "guild", width = 124, icon = "Interface\\Icons\\Achievement_GuildPerk_EveryonesAFriend" },
    { key = "mail", width = 60, icon = "Interface\\Icons\\INV_Letter_05" },
    { key = "coords", width = 76, icon = "Interface\\Icons\\INV_Misc_Map_02" },
    { key = "clock", width = 46, icon = "Interface\\Icons\\INV_Misc_PocketWatch_01" },
}
local MIN_WIDTH, TEXT_OFFSET = {}, {}
for _, def in ipairs(FIELDS) do MIN_WIDTH[def.key] = def.width end
local LEFT_ORDER = { "money", "durability", "performance", "bags" }
local RIGHT_ORDER = { "clock", "coords", "mail", "guild" }
local FULL_WIDTH_MIN = 1200

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
    local fps, home, world = app.Capabilities.Performance()
    local latency = home and world and math.max(home, world) or nil
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
    TEXT_OFFSET[def.key] = offset
    local text = app.Type:Text(holder, "body")
    text:SetPoint("LEFT", offset, 0)
    text:SetWidth(def.width - offset)
    text:SetWordWrap(false)
    text:SetJustifyH("LEFT")
    self[def.key] = text
    hover(holder, function(reports, owner) reports[reportFor(def.key)](reports, owner) end)
end

-- Extra width handed to every reading in one cluster. Equal shares keep the
-- separators evenly spaced, and the result depends only on the screen, never on
-- the current text, so a ticking clock or a money change cannot make fields jump.
local function clusterSlack(keys, span)
    local base = (#keys - 1) * FIELD_GAP
    for _, key in ipairs(keys) do base = base + MIN_WIDTH[key] end
    return math.max(0, (span - base) / #keys)
end

local function setTextWidth(self, key, width)
    local text = self[key]
    if text then text:SetWidth(math.max(1, width - (TEXT_OFFSET[key] or 0))) end
end

local function relayout(self, screenWidth)
    -- Below the minimum the left and right clusters would meet the centred zone
    -- name; fall back to the compact reading instead of drawing overlapping text.
    local compact = isCompact() or screenWidth < FULL_WIDTH_MIN
    local showClock = clockPlacement() == "strip"
    local width = compact and WIDTH_COMPACT or math.max(1, screenWidth)
    self.frame:SetWidth(width)
    for _, def in ipairs(FIELDS) do
        local shown = not compact and (def.key ~= "clock" or showClock)
        self.segments[def.key]:SetShown(shown)
        if self[def.key] then self[def.key]:SetShown(shown) end
    end
    if compact then
        -- Compact keeps the zone and clock on one short band; the remainder is a
        -- hover summary so every field is still reachable.
        local zone, clock = self.segments.zone, self.segments.clock
        zone:SetShown(true)
        self.zone:SetShown(true)
        self.segments.clock:SetShown(showClock)
        self.clock:SetShown(showClock)
        zone:ClearAllPoints()
        zone:SetWidth(MIN_WIDTH.zone)
        zone:SetPoint("LEFT", self.frame, "LEFT", PAD, 0)
        setTextWidth(self, "zone", MIN_WIDTH.zone)
        clock:ClearAllPoints()
        clock:SetWidth(MIN_WIDTH.clock)
        clock:SetPoint("LEFT", self.frame, "LEFT", PAD + MIN_WIDTH.zone + FIELD_GAP * 2, 0)
        setTextWidth(self, "clock", MIN_WIDTH.clock)
        self.summary:SetShown(true)
        self.summary:ClearAllPoints()
        self.summary:SetPoint("LEFT", showClock and clock or zone, "RIGHT", FIELD_GAP, 0)
        self.summary:SetPoint("RIGHT", self.frame, "RIGHT", -PAD, 0)
        return
    end

    self.summary:SetShown(false)
    -- The zone keeps the centre; the two clusters split the rest evenly and use
    -- the full width instead of leaving empty islands between the ends.
    local span = (width - ZONE_WIDTH) / 2 - PAD - FIELD_GAP
    local leftExtra = clusterSlack(LEFT_ORDER, span)
    local previous
    for _, key in ipairs(LEFT_ORDER) do
        local holder = self.segments[key]
        local fieldWidth = MIN_WIDTH[key] + leftExtra
        holder:ClearAllPoints()
        holder:SetWidth(fieldWidth)
        if previous then
            holder:SetPoint("LEFT", previous, "RIGHT", FIELD_GAP, 0)
        else
            holder:SetPoint("LEFT", self.frame, "LEFT", PAD, 0)
        end
        setTextWidth(self, key, fieldWidth)
        previous = holder
    end

    local zone = self.segments.zone
    zone:ClearAllPoints()
    zone:SetWidth(ZONE_WIDTH)
    zone:SetPoint("CENTER", self.frame, "CENTER", 0, 0)
    setTextWidth(self, "zone", ZONE_WIDTH)

    local rightKeys = showClock and RIGHT_ORDER or { "coords", "mail", "guild" }
    local rightExtra = clusterSlack(rightKeys, span)
    previous = nil
    for _, key in ipairs(rightKeys) do
        local holder = self.segments[key]
        local fieldWidth = MIN_WIDTH[key] + rightExtra
        holder:ClearAllPoints()
        holder:SetWidth(fieldWidth)
        if previous then
            holder:SetPoint("RIGHT", previous, "LEFT", -FIELD_GAP, 0)
        else
            holder:SetPoint("RIGHT", self.frame, "RIGHT", -PAD, 0)
        end
        setTextWidth(self, key, fieldWidth)
        previous = holder
    end
end

-- Applies the band's own geometry: full width, flush to the bottom edge, and a
-- layout group that reports the same rectangle. The default follows the current
-- screen only when the player has not saved a position for the group.
local function fit(self)
    local scale = app.Layout:Scale("bottomBar")
    if type(scale) ~= "number" or scale <= 0 then scale = 1 end
    local screenWidth, screenHeight = UIParent:GetWidth() / scale, UIParent:GetHeight() / scale
    relayout(self, screenWidth)
    local group = app.Layout.entries.bottomBar
    if not group then return end
    -- The band owns the reserved action baseline: the bars must stay above its
    -- top edge even if the strip height token grows.
    app.Layout:SetActionAreaBottom(math.max(app.Layout:ActionAreaBottom(), HEIGHT + 8))
    -- A full-width bar cannot keep an eight-unit window margin; it owns the edge.
    group.margin = 0
    app.Layout:SetGroupSize("bottomBar", math.max(1, self.frame:GetWidth()), HEIGHT)
    local flushY = -screenHeight / 2 + HEIGHT / 2
    app.Layout:SetEntryDefault("bottomBar", 0, flushY)
    local offset = app.Store:Profile().positions["bottomBar|dataStrip"]
    local member = app.Layout.entries.dataStrip
    if member and member.member == "bottomBar" then
        -- Keep the member's fallback default in step with the group so a profile
        -- refresh derives a zero offset, and clear a stale one after a resize.
        member.x, member.y = 0, flushY
        if not offset then member.rx, member.ry = 0, 0 end
    end
    app.Layout:Apply("bottomBar")
    if not offset then app.Layout:Apply("dataStrip") end
end

app:RegisterComponent({ id = "dataStrip", label = "dataStrip",
    Enable = function(self)
        if not self.frame then
            local frame = CreateFrame("Frame", "LumaUIDataStrip", UIParent, "BackdropTemplate")
            local scale = app.Layout:Scale("bottomBar")
            if scale <= 0 then scale = 1 end
            local screenWidth, screenHeight = UIParent:GetWidth() / scale, UIParent:GetHeight() / scale
            local flushY = -screenHeight / 2 + HEIGHT / 2
            frame:SetSize(screenWidth, HEIGHT)
            frame:EnableMouse(false)
            self.frame = frame
            self.segments = self.segments or {}

            for _, def in ipairs(FIELDS) do buildField(self, def) end

            -- The strip is a bottom bar in the Pearl target, not a second top
            -- row: it owns one layout group so moving it never touches the XP
            -- bar group.
            app.Layout:Join("bottomBar", "dataStrip", frame, 0, flushY,
                { label = app.L.bottomBar, x = 0, y = flushY,
                    width = screenWidth, height = HEIGHT })

            local summary = segment(self, "summary")
            summary:SetHeight(HEIGHT - 8)
            summary:SetPoint("TOP", frame, "TOP", 0, -2)
            summary:SetPoint("BOTTOM", frame, "BOTTOM", 0, 2)
            hover(summary, function(reports, owner) reports:ShowSummary(owner) end)
            self.summary = summary
        end
        app.Surface:Plate(self.frame, "hud")
        fit(self)
        self.frame:Show()
        self:Listen("PLAYER_MONEY", update)
        self:Listen("PLAYER_ENTERING_WORLD", update)
        self:Listen("ZONE_CHANGED_NEW_AREA", update)
        self:Listen("BAG_UPDATE_DELAYED", update)
        self:Listen("UPDATE_INVENTORY_DURABILITY", update)
        self:Listen("GUILD_ROSTER_UPDATE", update)
        self:Listen("FRIENDLIST_UPDATE", update)
        self:Listen("UPDATE_PENDING_MAIL", update)
        self:Listen("DISPLAY_SIZE_CHANGED", function(current) fit(current) end)
        self:Listen("UI_SCALE_CHANGED", function(current) fit(current) end)
        -- A profile or appearance change scales the group after Reconcile; the
        -- band reads the new scale once instead of keeping a stale width.
        app:Subscribe(self, "RUNTIME_UPDATED", function()
            if self.running then fit(self) end
        end)
        self:Every(1, update)
        update(self)
    end,
    Refresh = function(self)
        if not self.frame then return end
        fit(self)
        app.Surface:Plate(self.frame, "hud")
        update(self)
    end,
    Disable = function(self) if self.frame then self.frame:Hide() end end,
})
