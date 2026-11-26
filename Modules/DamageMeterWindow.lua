local _, app = ...

-- The official statistics window, as a sample with an explicit data seam.
--
-- Retail's damage meter API has changed shape between builds, and LumaUI does
-- not guess an API: it never calls a method it has not been told exists. Instead
-- the window draws whatever a registered provider returns, in one documented
-- shape:
--
--     provider() -> {
--         title = "Damage", total = 1234567,
--         rows = { { name = "Name", className = "MAGE", amount = 123456 }, ... },
--     }
--
-- Every number in that table must be a plain Lua number. A row whose amount is
-- secret is dropped instead of being compared, sorted, formatted or stored, so a
-- restricted value can never leak through a sort or a percentage.
--
-- With no provider the window shows one quiet line and nothing else; the reserved
-- bottom-right area stays with whichever meter the player already runs. The
-- window is its own frame (never a native meter), remembers nothing across
-- sessions beyond its component toggle, and releases its ticker on disable.

local WIDTH, HEIGHT = 268, 196
local ROW_HEIGHT = 18
local MAX_ROWS = 8
local ID = "damageMeter"
local component

local function number(value)
    return app.Capabilities.Plain(value, "number")
end

local function text(value)
    return app.Capabilities.Plain(value, "string")
end

-- Opt-in official source (015 phase 13, UNVERIFIED on a real client). The
-- field names below are a best guess; every read is plain-checked and any
-- missing piece yields no data, so a wrong guess shows nothing instead of
-- wrong numbers. Off by default (`ui.meterOfficial`); an external provider wins.
local function officialWanted()
    return app.Store:Profile().ui.meterOfficial == true
        and type(_G.C_DamageMeter) == "table"
        and type(C_DamageMeter.GetCombatSessionFromType) == "function"
        and rawget(_G, "Enum") ~= nil and type(Enum.DamageMeterSessionType) == "table"
        and type(Enum.DamageMeterType) == "table"
end

local function officialProvider()
    local ok, session = pcall(C_DamageMeter.GetCombatSessionFromType,
        Enum.DamageMeterSessionType.Current, Enum.DamageMeterType.DamageDone)
    if not ok or type(session) ~= "table" or type(session.combatSources) ~= "table" then return nil end
    local rows = {}
    for _, source in ipairs(session.combatSources) do
        if type(source) == "table" then
            rows[#rows + 1] = { name = source.name, className = source.classFilename,
                amount = source.totalAmount }
        end
    end
    return { title = app.L.meterSample, total = session.totalAmount, rows = rows }
end

local function provider()
    if type(app.DamageMeterProvider) == "function" then return app.DamageMeterProvider end
    if officialWanted() then return officialProvider end
    return nil
end

-- Normalizes one provider result. Rows keep their order; `percent` is computed
-- only from plain numbers, and a total of zero is not a division.
local function read()
    local readProvider = provider()
    if type(readProvider) ~= "function" then return nil end
    local ok, data = pcall(readProvider)
    if not ok or type(data) ~= "table" then return nil end
    local total = number(data.total)
    local rows = {}
    for _, row in ipairs(data.rows or {}) do
        if type(row) == "table" then
            local amount = number(row.amount)
            local name = text(row.name)
            if amount and name and amount >= 0 then
                rows[#rows + 1] = {
                    name = name, className = text(row.className), amount = amount,
                }
            end
        end
    end
    if total and total > 0 then
        for _, row in ipairs(rows) do row.percent = row.amount / total end
    end
    return { title = text(data.title) or app.L.meterSample, total = total, rows = rows }
end

local function build(self)
    if self.frame then return self.frame end
    local frame = CreateFrame("Frame", "LumaUIDamageMeter", UIParent, "BackdropTemplate")
    frame:SetSize(WIDTH, HEIGHT)
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function(current) current:StartMoving() end)
    frame:SetScript("OnDragStop", function(current) current:StopMovingOrSizing() end)
    app.Theme:PaintSurface(frame, "window")
    self.frame = frame

    local title = app.Type:Text(frame, "title")
    title:SetPoint("TOPLEFT", 10, -8)
    title:SetText(app.L.meterSample)
    self.title = title

    local total = app.Type:Text(frame, "micro")
    total:SetPoint("TOPRIGHT", -10, -10)
    self.total = total

    local close = app.Controls:Button(frame, "×", 22, function() self:Hide() end)
    close:SetPoint("TOPRIGHT", -6, -6)
    -- The title row owns the top edge; the close sits above it.
    title:ClearAllPoints()
    title:SetPoint("TOPLEFT", 10, -8)
    title:SetWidth(WIDTH - 50)

    self.rows = {}
    for index = 1, MAX_ROWS do
        local row = CreateFrame("Frame", nil, frame)
        row:SetHeight(ROW_HEIGHT)
        row:SetPoint("TOPLEFT", 10, -30 - (index - 1) * ROW_HEIGHT)
        row:SetPoint("TOPRIGHT", -10, -30 - (index - 1) * ROW_HEIGHT)
        -- The share is a thin StatusBar under the text, one per row: the client
        -- draws the fill, so a percentage never has to become a texture size.
        row.bar = app.Theme:Bar(row, 3)
        row.bar:SetPoint("BOTTOMLEFT", 0, 0)
        row.bar:SetPoint("BOTTOMRIGHT", 0, 0)
        row.bar:SetMinMaxValues(0, 1)
        row.name = app.Type:Text(row, "micro")
        row.name:SetPoint("LEFT", 4, 0)
        row.name:SetWidth(96)
        row.name:SetJustifyH("LEFT")
        row.value = app.Type:Text(row, "micro")
        row.value:SetPoint("RIGHT", -4, 0)
        row.value:SetJustifyH("RIGHT")
        row:Hide()
        self.rows[index] = row
    end

    local empty = app.Type:Text(frame, "note")
    empty:SetPoint("TOPLEFT", 10, -34)
    empty:SetWidth(WIDTH - 20)
    empty:SetText(app.L.meterNoProvider)
    self.empty = empty

    -- Anchored to the reserved statistics area when that region exists, so the
    -- sample lands where the mockup puts the meter; otherwise bottom right.
    local area = app.Layout.entries.damageMeterArea
    local anchor = area and area.frame or UIParent
    frame:ClearAllPoints()
    if anchor ~= UIParent then
        frame:SetPoint("TOPLEFT", anchor, "TOPLEFT", 0, 0)
    else
        frame:SetPoint("BOTTOMRIGHT", UIParent, "BOTTOMRIGHT", -40, 46)
    end
    return frame
end

local function draw(self)
    local frame = build(self)
    local data = read()
    if not data or #data.rows == 0 then
        for _, row in ipairs(self.rows) do row:Hide() end
        self.empty:Show()
        self.total:SetText("")
        frame:Show()
        return
    end
    self.empty:Hide()
    self.title:SetText(data.title or app.L.meterSample)
    self.total:SetText(data.total and string.format("%.0f", data.total) or "")
    for index, row in ipairs(self.rows) do
        local source = data.rows[index]
        if source then
            row.name:SetText(source.name)
            row.value:SetText(string.format("%.0f%%", (source.percent or 0) * 100))
            row.bar:SetValue(source.percent or 0)
            local red, green, blue = app.Theme:ClassColor(source.className)
            if red then app.Theme:PaintBar(row.bar, { red, green, blue }) end
            row:Show()
        else
            row:Hide()
        end
    end
    frame:Show()
end

component = app:RegisterComponent({ id = ID, label = ID, defaultEnabled = false,
    Supported = function() return provider() ~= nil end,
    Enable = function(self)
        build(self)
        draw(self)
        -- The provider is read once a second only while the window is open. Timer
        -- creation is guarded: a build without C_Timer keeps the manual Refresh.
        if type(C_Timer) == "table" and type(C_Timer.NewTicker) == "function" then
            self.ticker = C_Timer.NewTicker(1, function()
                if component.running and component.frame and component.frame:IsShown() then
                    draw(component)
                end
            end)
        end
        app:Subscribe(self, "DAMAGE_METER_UPDATED", function()
            if self.running and self.frame and self.frame:IsShown() then
                app:Call("damageMeter/draw", draw, self)
            end
        end)
    end,
    Refresh = function(self)
        draw(self)
    end,
    Disable = function(self)
        if self.ticker then
            if type(self.ticker.Cancel) == "function" then pcall(self.ticker.Cancel, self.ticker) end
            self.ticker = nil
        end
        if self.frame then self.frame:Hide() end
        for _, row in ipairs(self.rows or {}) do row:Hide() end
    end,
})

function component:Show()
    if not self.running then return false end
    draw(self)
    return true
end

function component:Hide()
    if self.frame then self.frame:Hide() end
end

function component:IsShown()
    return self.frame ~= nil and self.frame:IsShown()
end

-- One provider seam. A statistics addon (or a future native adapter) registers a
-- function returning the documented table; LumaUI never reaches into it.
function app:SetDamageMeterProvider(readProvider)
    app.DamageMeterProvider = type(readProvider) == "function" and readProvider or nil
end

function component:Describe()
    if not self.running then return nil end
    local shown = 0
    for _, row in ipairs(self.rows or {}) do
        if row:IsShown() then shown = shown + 1 end
    end
    return string.format("damageMeter: rows=%d shown=%s source=%s", shown,
        self.frame and self.frame:IsShown() and "yes" or "no",
        type(app.DamageMeterProvider) == "function" and "external" or "none")
end

-- 012 phase 19 probe. The official meter API's exact session/entry shape is not
-- verified on this build, so the adapter reads nothing and calls nothing with a
-- guessed argument. This report names what the client exposes; a shape is
-- adopted only after a real session confirms it. Until then the reserved area
-- stays with the player's own meter and the window keeps its provider seam.
local OFFICIAL_FUNCTIONS = {
    "GetCombatSessionFromType", "GetCombatSessionFromID",
    "GetAvailableCombatSessions", "GetCurrentCombatSession",
}

function component:Probe()
    local api = _G.C_DamageMeter
    if type(api) ~= "table" then
        app:Print(app.L.meterNoApi)
        return
    end
    local found = {}
    for _, name in ipairs(OFFICIAL_FUNCTIONS) do
        if type(api[name]) == "function" then found[#found + 1] = name end
    end
    app:Print(string.format("damageMeter: api=yes functions=%s provider=%s",
        #found > 0 and table.concat(found, ",") or "-",
        type(app.DamageMeterProvider) == "function" and "external" or "none"))
    app:Print("  " .. app.L.meterApiPending)
end
