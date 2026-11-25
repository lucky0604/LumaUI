local _, app = ...

-- 012 phase 17: one small tool corner for the low-frequency entries. The
-- buttons are LumaUI's own and each calls a documented entry point; no native
-- micro menu, bag bar or calendar button is moved or hidden. The strip keeps
-- the clock, the meter keeps the bottom-right reserve, and this corner sits
-- above that reserve so the three never share a rectangle.
--
-- The panel is a normal layout entry: drag it in `/luma edit`, its position is
-- saved per profile, and a preset may place it like any other panel.

local ID = "utilityCorner"
local HEIGHT = 26
local BUTTON = 26
local GAP = 4
local component

local function ensureFrame(self)
    if self.frame then return self.frame end
    local frame = CreateFrame("Frame", "LumaUIUtilityCorner", UIParent, "BackdropTemplate")
    frame:SetSize(BUTTON * 5 + GAP * 4, HEIGHT)
    app.Surface:Plate(frame, "hud")
    frame.buttons = {}
    local entries = {
        { key = "settings", label = app.L.drawerSettings, run = function() app.Settings:Toggle() end },
        { key = "bags", label = app.L.drawerBags, run = function()
            local inventory = app.components.inventory
            if inventory and inventory.running then inventory:Toggle() end
        end },
        { key = "character", label = app.L.drawerCharacter, run = function()
            local window = app.components.characterWindow
            if window and window.running then window:Toggle() end
        end },
        { key = "layout", label = app.L.drawerLayout, run = function() app.Layout:Toggle() end },
        { key = "menu", label = app.L.utilityMenu, run = function()
            if type(ToggleGameMenu) == "function" then ToggleGameMenu() end
        end },
    }
    for index, entry in ipairs(entries) do
        local button = app.Controls:Button(frame, entry.label, BUTTON, entry.run, { height = 18, size = 9 })
        button:SetPoint("LEFT", (index - 1) * (BUTTON + GAP) + GAP / 2, 0)
        frame.buttons[entry.key] = button
    end
    frame:Show()
    app.Layout:Register(ID, frame, 0, 0, app.L.utilityCorner)
    self.frame = frame
    return frame
end

-- Default position: above the reserved meter block on the right edge. The
-- saved position still wins; this only sets the fallback.
local function position(self)
    local width = UIParent:GetWidth() or 1024
    local height = UIParent:GetHeight() or 768
    local scale = app.Layout:Scale(ID)
    if not scale or scale <= 0 then scale = 1 end
    local x = width / 2 - 60
    local y = -height / 2 + 46 + height * 0.16 + 12
    self.frame:SetSize((BUTTON * 5 + GAP * 4) / scale, HEIGHT)
    app.Layout:SetEntryDefault(ID, x / scale, y / scale)
    app.Layout:Apply(ID)
end

component = app:RegisterComponent({ id = "utilityCorner", label = "utilityCorner", defaultEnabled = true,
    Enable = function(self)
        ensureFrame(self)
        position(self)
        self:Listen("DISPLAY_SIZE_CHANGED", function(current) position(current) end)
        self:Listen("UI_SCALE_CHANGED", function(current) position(current) end)
        app:Subscribe(self, "LAYOUT_CENTRAL_CHANGED", function()
            if self.running then position(self) end
        end)
        if app.Ownership then
            app.Ownership:Set("utilityCorner", { intent = "owned", active = "owned",
                evidence = "simulated" })
        end
    end,
    Refresh = function(self)
        ensureFrame(self)
        position(self)
    end,
    Disable = function(self)
        if self.frame then self.frame:Hide() end
        if app.Ownership then app.Ownership:Active("utilityCorner", "native", "component-off") end
    end,
})

function component:Describe()
    if not self.running then return nil end
    return string.format("utilityCorner: own=%d native-micro-menu=kept", 5)
end
