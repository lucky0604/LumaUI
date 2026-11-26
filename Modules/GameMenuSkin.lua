local _, app = ...

-- LumaUI's own look for the client's Esc menu (016).
--
-- The menu stays the client's: `MainMenuFrameMixin` still builds every button,
-- keeps its callbacks, disabled tooltips, gamepad focus, narration and hit
-- areas. This file only replaces the picture:
--
--   * `Border` is a `DialogBorderTemplate`: a tiled stone background plus a
--     nine-slice frame. Both are painted at alpha 0 and LumaUI's own card plate
--     (the same recipe the settings window uses) takes their place.
--   * `Header` is a `DialogHeaderTemplate` with metal corner art and a tiled
--     centre. The art is painted out; the text keeps its FontString but takes
--     LumaUI's title role and sits at the card's top-left.
--   * each pooled button is a `BigRedThreeSliceButtonTemplate`. Its three red
--     slices and its highlight atlas are painted out, a raised LumaUI surface is
--     drawn behind the label, and the three state fonts become LumaUI font
--     objects so hover and disabled read in LumaUI's palette.
--
-- Alpha is used instead of Hide/Show because `ThreeSliceButtonMixin` and the
-- header mixin rewrite atlases and anchors on show; neither touches alpha, so
-- the skin survives a rebuild without fighting the client's update path. Every
-- write is recorded once per object, so `Restore` hands the frame back exactly
-- as the client had it.

local Skin = {}
app.GameMenuSkin = Skin

local PLATE_SUBLEVEL = -8
local WIDTH = 300
local PADDING = { top = 54, bottom = 30, left = 18, right = 18, spacing = 2 }
local BUTTON_HEIGHT = 34
local HEADER_INSET_X, HEADER_INSET_Y = 18, -12
local HEADER_HEIGHT = 24

local FONT_NAMES = {
    normal = "LumaUIGameMenuNormal",
    highlight = "LumaUIGameMenuHighlight",
    disabled = "LumaUIGameMenuDisabled",
}

local fonts = {}

local function plain(value, kind)
    return app.Capabilities.Plain(value, kind)
end

local function capturePoints(frame, maxPoints)
    local points = {}
    if not frame or type(frame.GetPoint) ~= "function" then return points end
    for index = 1, maxPoints or 2 do
        local ok, point, relative, relativePoint, x, y = pcall(frame.GetPoint, frame, index)
        if not ok or point == nil then break end
        points[#points + 1] = { point, relative, relativePoint, plain(x, "number"), plain(y, "number") }
    end
    return points
end

local function restorePoints(frame, points)
    if not frame or type(frame.ClearAllPoints) ~= "function" then return end
    pcall(frame.ClearAllPoints, frame)
    for _, point in ipairs(points or {}) do
        pcall(frame.SetPoint, frame, point[1], point[2], point[3], point[4], point[5])
    end
end

local function alphaOf(texture)
    if not texture or type(texture.GetAlpha) ~= "function" then return nil end
    local ok, value = pcall(texture.GetAlpha, texture)
    return ok and plain(value, "number") or nil
end

local function setAlpha(texture, value)
    if texture and value ~= nil and type(texture.SetAlpha) == "function" then
        pcall(texture.SetAlpha, texture, value)
    end
end

local function hideTexture(texture)
    if texture and type(texture.SetAlpha) == "function" then pcall(texture.SetAlpha, texture, 0) end
end

local function textureOf(button, getter)
    if type(button[getter]) ~= "function" then return nil end
    local ok, texture = pcall(button[getter], button)
    return ok and texture or nil
end

-- Mode-independent font objects: created once per session so a rebuild cannot
-- leak objects, and a theme change only retints the same three.
local function fontFor(state)
    if fonts[state] then return fonts[state] end
    if type(CreateFont) ~= "function" then return nil end
    local ok, font = pcall(CreateFont, FONT_NAMES[state])
    if not ok or not font then return nil end
    local role = app.Type:Role("body")
    if type(font.SetFont) == "function" then
        pcall(font.SetFont, font, app.Type:Face(), role.size, "")
    end
    fonts[state] = font
    return font
end

local function tintFonts()
    local colors = app.Theme.colors
    local palette = {
        normal = colors.text,
        highlight = app.Theme:Accent(),
        disabled = colors.muted,
    }
    for state, color in pairs(palette) do
        local font = fontFor(state)
        if font and color and type(font.SetTextColor) == "function" then
            pcall(font.SetTextColor, font, color[1], color[2], color[3], 1)
        end
    end
end

-- The client's own values, recorded before the first write. A non-positive
-- measurement (a frame that has not been laid out yet) is never recorded, so a
-- restore cannot set a width or height to zero.
local function recordMenu(menu)
    if menu.lumaMenuRecord then return menu.lumaMenuRecord end
    local record = {
        width = plain(menu:GetWidth(), "number"),
        topPadding = plain(menu.topPadding, "number"),
        bottomPadding = plain(menu.bottomPadding, "number"),
        leftPadding = plain(menu.leftPadding, "number"),
        rightPadding = plain(menu.rightPadding, "number"),
        spacing = plain(menu.spacing, "number"),
        buttons = {},
    }
    if record.width and record.width <= 0 then record.width = nil end
    local border = menu.Border
    if border then
        record.border = { bg = alphaOf(border.Bg), nineSlice = alphaOf(border.NineSlice) }
    end
    local header = menu.Header
    if header then
        local text = header.Text
        local font, color = nil, nil
        if text and type(text.GetFont) == "function" then
            local ok, file, size, flags = pcall(text.GetFont, text)
            if ok then font = { plain(file, "string"), plain(size, "number"), plain(flags, "string") } end
        end
        if text and type(text.GetTextColor) == "function" then
            local ok, r, g, b, a = pcall(text.GetTextColor, text)
            if ok then color = { plain(r, "number"), plain(g, "number"), plain(b, "number"), plain(a, "number") } end
        end
        local justify, width
        if text and type(text.GetJustifyH) == "function" then
            local ok, value = pcall(text.GetJustifyH, text)
            justify = ok and plain(value, "string") or nil
        end
        if text and type(text.GetWidth) == "function" then
            local ok, value = pcall(text.GetWidth, text)
            width = ok and plain(value, "number") or nil
        end
        record.header = {
            points = capturePoints(header, 2),
            left = alphaOf(header.LeftBG), right = alphaOf(header.RightBG), center = alphaOf(header.CenterBG),
            title = text and { font = font, color = color, points = capturePoints(text, 2),
                justify = justify, width = width } or nil,
        }
    end
    menu.lumaMenuRecord = record
    return record
end

local function recordButton(button, record)
    if button.lumaButtonRecord then return button.lumaButtonRecord end
    local normalTexture, highlightTexture = textureOf(button, "GetNormalTexture"), textureOf(button, "GetHighlightTexture")
    local function fontOf(getter)
        if type(button[getter]) ~= "function" then return nil end
        local ok, font = pcall(button[getter], button)
        return ok and font or nil
    end
    local saved = {
        height = plain(button:GetHeight(), "number"),
        left = alphaOf(button.Left), center = alphaOf(button.Center), right = alphaOf(button.Right),
        normal = alphaOf(normalTexture), highlight = alphaOf(highlightTexture),
        normalFont = fontOf("GetNormalFontObject"),
        highlightFont = fontOf("GetHighlightFontObject"),
        disabledFont = fontOf("GetDisabledFontObject"),
    }
    if saved.height and saved.height <= 0 then saved.height = nil end
    button.lumaButtonRecord = saved
    if record then record.buttons[#record.buttons + 1] = button end
    return saved
end

local function paintButton(button)
    local saved = recordButton(button)
    hideTexture(button.Left)
    hideTexture(button.Center)
    hideTexture(button.Right)
    hideTexture(textureOf(button, "GetNormalTexture"))
    hideTexture(textureOf(button, "GetHighlightTexture"))
    local normal, highlight, disabled = fontFor("normal"), fontFor("highlight"), fontFor("disabled")
    if normal and type(button.SetNormalFontObject) == "function" then pcall(button.SetNormalFontObject, button, normal) end
    if highlight and type(button.SetHighlightFontObject) == "function" then pcall(button.SetHighlightFontObject, button, highlight) end
    if disabled and type(button.SetDisabledFontObject) == "function" then pcall(button.SetDisabledFontObject, button, disabled) end
    if saved.height and type(button.SetHeight) == "function" then pcall(button.SetHeight, button, BUTTON_HEIGHT) end
    -- A raised surface behind the label. The button has no BackdropTemplate, so
    -- this is a texture, exactly like the plate on the menu itself.
    local plate = button.lumaPlate
    if not plate and type(button.CreateTexture) == "function" then
        plate = button:CreateTexture(nil, "BACKGROUND", nil, PLATE_SUBLEVEL)
        button.lumaPlate = plate
    end
    if plate then
        pcall(app.Surface.ApplyPlate, app.Surface, plate, "button")
        if type(plate.SetAllPoints) == "function" then pcall(plate.SetAllPoints, plate, button) end
        if type(plate.Show) == "function" then pcall(plate.Show, plate) end
        button.lumaSurfaceRole = "button"
    end
    button.lumaSkinned = true
end

local function paintHeader(menu, record)
    local header = menu.Header
    if not header then return end
    hideTexture(header.LeftBG)
    hideTexture(header.RightBG)
    hideTexture(header.CenterBG)
    if type(header.ClearAllPoints) == "function" and type(header.SetPoint) == "function" then
        pcall(header.ClearAllPoints, header)
        pcall(header.SetPoint, header, "TOPLEFT", menu, "TOPLEFT", HEADER_INSET_X, HEADER_INSET_Y)
    end
    local headerWidth = plain(menu:GetWidth(), "number")
    if headerWidth and headerWidth > 0 and type(header.SetWidth) == "function" then
        pcall(header.SetWidth, header, headerWidth - HEADER_INSET_X * 2)
    end
    if type(header.SetHeight) == "function" then pcall(header.SetHeight, header, HEADER_HEIGHT) end
    local text = header.Text
    if not text then return end
    app.Type:Apply(text, "title")
    if type(text.SetJustifyH) == "function" then pcall(text.SetJustifyH, text, "LEFT") end
    if type(text.ClearAllPoints) == "function" and type(text.SetPoint) == "function" then
        pcall(text.ClearAllPoints, text)
        pcall(text.SetPoint, text, "LEFT", header, "LEFT", 0, 0)
    end
    local width = plain(menu:GetWidth(), "number")
    if width and width > 0 and type(text.SetWidth) == "function" then
        pcall(text.SetWidth, text, width - HEADER_INSET_X * 2)
    end
end

local function paint(menu)
    local record = recordMenu(menu)
    if type(app.Surface.Plate) == "function" then
        pcall(app.Surface.Plate, app.Surface, menu, "card")
        -- Restore hides LumaUI's plate instead of destroying it, so a later
        -- Apply has to bring the same texture back.
        if menu.lumaPlate and type(menu.lumaPlate.Show) == "function" then
            pcall(menu.lumaPlate.Show, menu.lumaPlate)
        end
    end
    -- The native dialog border: a tiled stone background and a nine-slice
    -- frame. Both stay in the hierarchy (the layout reads their size) and only
    -- lose their picture.
    if menu.Border then
        hideTexture(menu.Border.Bg)
        hideTexture(menu.Border.NineSlice)
    end
    if record.width and type(menu.SetWidth) == "function" then
        pcall(menu.SetWidth, menu, WIDTH)
    end
    -- Layout constants are KeyValue fields the client reads on its next layout
    -- pass; writing them and dirtying is how a native menu is resized.
    menu.topPadding, menu.bottomPadding = PADDING.top, PADDING.bottom
    menu.leftPadding, menu.rightPadding = PADDING.left, PADDING.right
    menu.spacing = PADDING.spacing
    paintHeader(menu, record)
    tintFonts()
    local pool = menu.buttonPool
    if pool and type(pool.EnumerateActive) == "function" then
        for button in pool:EnumerateActive() do
            recordButton(button, record)
            paintButton(button)
        end
    end
    if type(menu.MarkDirty) == "function" then pcall(menu.MarkDirty, menu) end
    menu.lumaSkinned = true
    return true
end

-- Re-applies the skin after the client rebuilt or resized the menu. Called from
-- the component's InitButtons/OnShow hooks and on a theme change; it never
-- records a value twice.
function Skin:Apply(menu)
    menu = menu or _G.GameMenuFrame
    if not menu or type(menu.GetWidth) ~= "function" then return false end
    local ok, result = pcall(paint, menu)
    return ok and result == true
end

-- One button that appeared after the last pass (a pool growth or a late
-- AddButton) gets the same treatment without touching the rest of the menu.
function Skin:ApplyButton(button)
    if not button then return false end
    return pcall(paintButton, button)
end

function Skin:Refresh(menu)
    menu = menu or _G.GameMenuFrame
    if not menu or not menu.lumaSkinned then return false end
    return self:Apply(menu)
end

function Skin:IsSkinned(menu)
    menu = menu or _G.GameMenuFrame
    return menu ~= nil and menu.lumaSkinned == true
end

-- Hands the frame back exactly as recorded: border art, header art and anchors,
-- title type and anchors, button art, fonts and height, layout constants and
-- width. LumaUI's own plate and shadow are hidden, not destroyed, so a later
-- Apply reuses them.
function Skin:Restore(menu)
    menu = menu or _G.GameMenuFrame
    local record = menu and menu.lumaMenuRecord
    if not record then return false end
    if record.border then
        setAlpha(menu.Border and menu.Border.Bg, record.border.bg)
        setAlpha(menu.Border and menu.Border.NineSlice, record.border.nineSlice)
    end
    if record.header then
        local header = menu.Header
        setAlpha(header and header.LeftBG, record.header.left)
        setAlpha(header and header.RightBG, record.header.right)
        setAlpha(header and header.CenterBG, record.header.center)
        restorePoints(header, record.header.points)
        local text = header and header.Text
        local title = record.header.title
        if text and title then
            if title.font and title.font[1] and type(text.SetFont) == "function" then
                pcall(text.SetFont, text, title.font[1], title.font[2] or 12, title.font[3] or "")
            end
            if title.color and type(text.SetTextColor) == "function" then
                local r, g, b, a = title.color[1] or 1, title.color[2] or 1, title.color[3] or 1, title.color[4] or 1
                pcall(text.SetTextColor, text, r, g, b, a)
            end
            restorePoints(text, title.points)
            if title.width and type(text.SetWidth) == "function" then pcall(text.SetWidth, text, title.width) end
            if title.justify and type(text.SetJustifyH) == "function" then pcall(text.SetJustifyH, text, title.justify) end
        end
    end
    for _, button in ipairs(record.buttons) do
        local saved = button.lumaButtonRecord
        if saved then
            setAlpha(button.Left, saved.left)
            setAlpha(button.Center, saved.center)
            setAlpha(button.Right, saved.right)
            setAlpha(textureOf(button, "GetNormalTexture"), saved.normal)
            setAlpha(textureOf(button, "GetHighlightTexture"), saved.highlight)
            if saved.normalFont and type(button.SetNormalFontObject) == "function" then
                pcall(button.SetNormalFontObject, button, saved.normalFont)
            end
            if saved.highlightFont and type(button.SetHighlightFontObject) == "function" then
                pcall(button.SetHighlightFontObject, button, saved.highlightFont)
            end
            if saved.disabledFont and type(button.SetDisabledFontObject) == "function" then
                pcall(button.SetDisabledFontObject, button, saved.disabledFont)
            end
            if saved.height and type(button.SetHeight) == "function" then
                pcall(button.SetHeight, button, saved.height)
            end
            if button.lumaPlate and type(button.lumaPlate.Hide) == "function" then
                pcall(button.lumaPlate.Hide, button.lumaPlate)
            end
            button.lumaButtonRecord = nil
            button.lumaSkinned = nil
            button.lumaSurfaceRole = nil
        end
    end
    if menu.lumaPlate and type(menu.lumaPlate.Hide) == "function" then pcall(menu.lumaPlate.Hide, menu.lumaPlate) end
    if menu.lumaShadow and type(menu.lumaShadow.Hide) == "function" then pcall(menu.lumaShadow.Hide, menu.lumaShadow) end
    menu.lumaSurfaceRole = nil
    menu.lumaSkinned = nil
    if record.width and type(menu.SetWidth) == "function" then pcall(menu.SetWidth, menu, record.width) end
    if record.topPadding ~= nil then menu.topPadding = record.topPadding end
    if record.bottomPadding ~= nil then menu.bottomPadding = record.bottomPadding end
    if record.leftPadding ~= nil then menu.leftPadding = record.leftPadding end
    if record.rightPadding ~= nil then menu.rightPadding = record.rightPadding end
    if record.spacing ~= nil then menu.spacing = record.spacing end
    menu.lumaMenuRecord = nil
    if type(menu.MarkDirty) == "function" then pcall(menu.MarkDirty, menu) end
    return true
end
