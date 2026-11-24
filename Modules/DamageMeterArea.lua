local _, app = ...

-- The bottom-right statistics window belongs to whichever damage/healing addon
-- the player runs (Details!, Skada, the client's own readout). LumaUI reserves
-- the space and nothing else: it never looks the addon up, never moves, hides or
-- reads it, and the outline is LumaUI's own layout region. The outline is only
-- visible while positions are being edited and never takes mouse input, so a
-- window dropped on top of it keeps every click.
--
-- The reservation is one layout entry, so it is draggable on the layout page,
-- remembered per profile and restored by the same preset undo as every other
-- panel. Its default geometry follows the mockup: about 13% of the screen width
-- with the bottom edge level with the chat window, clear of the objective
-- tracker on the left and of the bottom strip's quick-entry buttons.

local ID = "damageMeterArea"
local WIDTH_RATIO = 0.13
local HEIGHT_RATIO = 0.16
-- The right edge stops short of the screen edge so a scrollbar or a row's own
-- status bar still fits inside the reserved block.
local RIGHT_RATIO = 0.03
-- Bottom edge distance from the screen bottom. The bottom strip is 30 units
-- tall; 46 leaves it clear and lines the block up with the chat window.
local BOTTOM = 46
local MIN_WIDTH, MIN_HEIGHT = 120, 80

local function screenSize()
    local okWidth, width = pcall(UIParent.GetWidth, UIParent)
    local okHeight, height = pcall(UIParent.GetHeight, UIParent)
    width = okWidth and app.Capabilities.Plain(width, "number") or nil
    height = okHeight and app.Capabilities.Plain(height, "number") or nil
    if not width or width <= 0 then width = 1920 end
    if not height or height <= 0 then height = 1080 end
    return width, height
end

local function ensure(self)
    if self.entry then
        -- Re-enabling puts the outline back on the layout page.
        self.entry.hidden = nil
        return self.entry
    end
    self.entry = app.Layout:RegisterPlaceholder(ID, app.L.damageMeterArea, 0, 0, 240, 160)
    self.entry.margin = 4
    return self.entry
end

-- Whole screen units: a fraction of the screen is almost never an integer, and
-- a long decimal in a saved position makes every later comparison inexact for
-- no visible gain.
local function whole(value)
    return math.floor(value + 0.5)
end

-- Width and height are frame units and the centre offset keeps the block's
-- bottom edge on BOTTOM, so a resolution change re-derives the same proportions
-- instead of stretching the saved rectangle.
local function position(self)
    local entry = ensure(self)
    local scale = app.Layout:Scale(ID)
    if not scale or scale <= 0 then scale = 1 end
    local screenWidth, screenHeight = screenSize()
    local width = whole(math.max(MIN_WIDTH, screenWidth * WIDTH_RATIO))
    local height = whole(math.max(MIN_HEIGHT, screenHeight * HEIGHT_RATIO))
    local x = whole(screenWidth / 2 - screenWidth * RIGHT_RATIO - width / 2)
    local y = whole(-screenHeight / 2 + BOTTOM + height / 2)
    if entry.frame then entry.frame:SetSize(width / scale, height) end
    app.Layout:SetEntryDefault(ID, x / scale, y / scale)
    app.Layout:Apply(ID)
end

app:RegisterComponent({
    id = "damageMeterArea", label = "damageMeterArea", defaultEnabled = true,
    Enable = function(self)
        position(self)
        self:Listen("PLAYER_ENTERING_WORLD", function(current) position(current) end)
        self:Listen("UI_SCALE_CHANGED", function(current) position(current) end)
        self:Listen("DISPLAY_SIZE_CHANGED", function(current) position(current) end)
    end,
    Refresh = function(self) position(self) end,
    Disable = function(self)
        -- The entry stays registered so the saved position survives a module
        -- toggle; `hidden` only drops it from the layout page and the outline.
        local entry = self.entry
        if not entry then return end
        entry.hidden = true
        if entry.frame then entry.frame:Hide() end
    end,
})
