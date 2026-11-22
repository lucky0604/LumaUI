local _, app = ...
local Plain = app.Capabilities.Plain
local module

-- Only tooltips known by name are touched. Nothing is enumerated from the
-- frame tree, so a third-party tooltip is never restyled or hooked.
local TARGETS = {
    { name = "GameTooltip", role = "main" },
    { name = "ItemRefTooltip", role = "link" },
    { name = "ShoppingTooltip1", role = "compare" },
    { name = "ShoppingTooltip2", role = "compare" },
}

-- One visual language for all four: the same 6px outer inset, the same thin
-- single outline. Roles only differ in strength: a comparison tooltip is
-- secondary, so it is quieter and never borrows the item quality colour of the
-- tooltip it compares against.
local ROLES = {
    main = { quality = true, edge = 0.9, fill = 0.05 },
    link = { quality = true, edge = 0.85, fill = 0.05 },
    compare = { quality = false, edge = 0.6, fill = 0 },
}
local EDGE = 6

local function known(name)
    for _, spec in ipairs(TARGETS) do
        if spec.name == name then return spec end
    end
end

local function itemQuality(target)
    if type(target.GetItem) ~= "function" then return nil end
    local ok, _, link = pcall(target.GetItem, target)
    if not ok then return nil end
    link = Plain(link, "string")
    if not link then return nil end
    local getInfo = C_Item and C_Item.GetItemInfo or GetItemInfo
    if type(getInfo) ~= "function" then return nil end
    local loaded, _, _, quality = pcall(getInfo, link)
    if not loaded then return nil end
    return Plain(quality, "number")
end

-- A tooltip is painted only when it is a readable GameTooltip object. A
-- forbidden frame, or a frame of another object type that happens to carry one
-- of these names, is refused: its native art is left exactly as the client
-- wrote it and nothing on it is called.
local function usable(target)
    if type(target) ~= "table" then return false end
    local ok, forbidden = pcall(target.IsForbidden, target)
    if ok and forbidden then return false end
    if type(target.GetObjectType) == "function" then
        local okType, objectType = pcall(target.GetObjectType, target)
        if okType and objectType ~= "GameTooltip" then return false end
    end
    return true
end

-- On the client IsEmbedded is a plain key on the template, not a method; a
-- build that exposes it as a function is honoured too.
local function embedded(target)
    if type(target.IsEmbedded) == "boolean" then return target.IsEmbedded end
    if type(target.IsEmbedded) ~= "function" then return false end
    local ok, value = pcall(target.IsEmbedded, target)
    return ok and value == true
end

local function hideDecor(decor)
    if not decor then return end
    if decor.plate then decor.plate:Hide() end
    if decor.shadow then decor.shadow:Hide() end
    if decor.quality then decor.quality:Hide() end
    for _, line in ipairs(decor.lines or {}) do line:Hide() end
end

local function ensureDecor(self, target, spec)
    local decor = self.decor[spec.name]
    if decor then return decor end
    decor = { name = spec.name, role = spec.role, lines = {} }
    -- A tooltip borrows the same card recipe as every other surface instead of
    -- drawing its own fill and four 1px strips: one shape, one shadow, and a single
    -- quality rule along the top edge. Textures live on BACKGROUND/BORDER, below the
    -- ARTWORK text the client builds, so the surface can never drift in front of
    -- native content.
    decor.shadow = target:CreateTexture(nil, "BACKGROUND", nil, -8)
    decor.plate = target:CreateTexture(nil, "BACKGROUND", nil, -7)
    decor.quality = target:CreateTexture(nil, "BORDER", nil, 1)
    decor.nine = target.NineSlice
    if decor.nine and type(decor.nine.IsShown) == "function" then
        local ok, shown = pcall(decor.nine.IsShown, decor.nine)
        decor.nineShown = ok and shown == true
    end
    self.decor[spec.name] = decor
    return decor
end

local function edgeColor(self, spec, target)
    local accent = app.Theme:Accent()
    local red, green, blue = accent[1], accent[2], accent[3]
    -- Quality is presentation only: it reads the item link and repaints the
    -- outline, never text, and never a value the client marks secret.
    if ROLES[spec.role].quality and app.Store:Profile().appearance.tooltipQuality then
        local quality = itemQuality(target)
        if quality then
            local red2, green2, blue2 = app.Theme:QualityColor(quality)
            if red2 then red, green, blue = red2, green2, blue2 end
        end
    end
    return red, green, blue
end

local function paint(self, name)
    local spec, target = known(name), _G[name]
    local decor = self.decor[name]
    if not spec or not target or not usable(target) then
        hideDecor(decor)
        return
    end
    decor = ensureDecor(self, target, spec)
    -- An embedded tooltip is drawn inside another frame, not as its own window;
    -- the client hides the art there too, so nothing is painted around it.
    if embedded(target) then
        hideDecor(decor)
        return
    end
    -- The native NineSlice carries the full tooltip art and its own heavy
    -- border. It is hidden on every paint, including the paints that run right
    -- after the client re-applies its own backdrop style on each hide.
    if decor.nine then
        pcall(decor.nine.Hide, decor.nine)
    end

    local role = ROLES[spec.role]
    local opacity = math.min(1, app.Store:Profile().appearance.opacity + role.fill)
    local surface = app.Surface
    local plate, shadow = decor.plate, decor.shadow

    plate:ClearAllPoints()
    plate:SetPoint("TOPLEFT", target, "TOPLEFT", -EDGE, EDGE)
    plate:SetPoint("BOTTOMRIGHT", target, "BOTTOMRIGHT", EDGE, -EDGE)
    surface:ApplyPlate(plate, "card")
    -- The tooltip floats over arbitrary game art, so it keeps a stronger fill than
    -- an ordinary window: text must stay readable over a raid fight.
    if type(plate.SetVertexColor) == "function" then
        plate:SetVertexColor(app.Theme.colors.surface[1], app.Theme.colors.surface[2],
            app.Theme.colors.surface[3], opacity)
    end

    if shadow and surface:CanSlice() then
        local inset = surface.shadowInset
        shadow:ClearAllPoints()
        shadow:SetPoint("TOPLEFT", plate, "TOPLEFT", -inset, inset)
        shadow:SetPoint("BOTTOMRIGHT", plate, "BOTTOMRIGHT", inset, -inset)
        if type(shadow.SetTexture) == "function" then shadow:SetTexture(surface.media.shadow) end
        if type(shadow.SetTextureSliceMargins) == "function" then
            local margin = surface.shadowMargin
            shadow:SetTextureSliceMargins(margin, margin, margin, margin)
        end
        if type(shadow.SetVertexColor) == "function" then shadow:SetVertexColor(0, 0, 0, 1) end
    end

    -- One quality rule instead of a four-sided frame: it marks what the tooltip is
    -- about without wrapping every tooltip in a box again.
    local red, green, blue = edgeColor(self, spec, target)
    local quality = decor.quality
    quality:ClearAllPoints()
    quality:SetPoint("TOPLEFT", plate, "TOPLEFT", 1, -1)
    quality:SetPoint("TOPRIGHT", plate, "TOPRIGHT", -1, -1)
    quality:SetHeight(app.Pixel:Pixels(1))
    quality:SetColorTexture(red, green, blue, role.edge)

    -- The surface is corner-anchored to the tooltip itself, so the client can
    -- resize it between uses and the decoration follows without any stored
    -- size. Visibility tracks the tooltip, so a reused tooltip that hides is
    -- never left with a floating surface.
    local shown = target:IsShown()
    plate:SetShown(shown)
    quality:SetShown(shown)
    if shadow then shadow:SetShown(shown and surface:CanSlice()) end
end

-- The client re-applies its backdrop style on every hide and whenever tooltip
-- data carries a special style (azerite, corrupted). A secure hook on that one
-- function re-applies ours after the client's write, so the native art can
-- never reappear over the LumaUI surface.
local function hookStyle(self)
    if self.styleHooked then return end
    if type(_G.SharedTooltip_SetBackdropStyle) ~= "function" or type(hooksecurefunc) ~= "function" then return end
    local ok = pcall(hooksecurefunc, "SharedTooltip_SetBackdropStyle", function(tooltip)
        if not module.running then return end
        if type(tooltip) ~= "table" or type(tooltip.GetName) ~= "function" then return end
        local named, name = pcall(tooltip.GetName, tooltip)
        if not named or not name or not module.decor[name] then return end
        app:Call("tooltip/style", paint, module, name)
    end)
    self.styleHooked = ok == true
end

local function restoreNative(target, decor)
    if not target or not decor or not decor.nine then return end
    if not usable(target) then return end
    local style = rawget(_G, "SharedTooltip_SetBackdropStyle")
    if type(style) == "function" then
        -- The client's own reset: default layout, native art back, padding
        -- cleared. Whatever style the client last used is what it gets back.
        local ok = pcall(style, target, nil, embedded(target))
        if ok then return end
    end
    pcall(decor.nine.SetShown, decor.nine, decor.nineShown ~= false)
end

local function hook(self, spec)
    local target = _G[spec.name]
    if not target then return end
    if not self.hooked[spec.name] then
        target:HookScript("OnShow", function()
            if module.running then app:Call("tooltip/show", paint, module, spec.name) end
        end)
        target:HookScript("OnHide", function()
            hideDecor(module.decor and module.decor[spec.name])
        end)
        self.hooked[spec.name] = true
    end
    app:Call("tooltip/paint", paint, self, spec.name)
end

module = app:RegisterComponent({ id = "tooltip", label = "tooltip",
    Enable = function(self)
        self.decor, self.hooked = self.decor or {}, self.hooked or {}
        hookStyle(self)
        for _, spec in ipairs(TARGETS) do hook(self, spec) end
    end,
    Refresh = function(self)
        for _, spec in ipairs(TARGETS) do
            if _G[spec.name] then app:Call("tooltip/refresh", paint, self, spec.name) end
        end
    end,
    Disable = function(self)
        for _, spec in ipairs(TARGETS) do
            local decor = self.decor and self.decor[spec.name]
            hideDecor(decor)
            restoreNative(_G[spec.name], decor)
        end
    end,
})

-- Diagnostics: the roles this build is painting, and whether the outline may
-- borrow the item quality colour. Nothing is inferred about content.
function module:Describe()
    if not self.running then return nil end
    local parts = {}
    for _, spec in ipairs(TARGETS) do
        if self.decor and self.decor[spec.name] then parts[#parts + 1] = spec.role end
    end
    local quality = app.Store:Profile().appearance.tooltipQuality and app.L.diagTooltipQuality or app.L.diagTooltipPlain
    return string.format("tooltip: %s · %s",
        #parts > 0 and table.concat(parts, " ") or app.L.diagTooltipNone, quality)
end
