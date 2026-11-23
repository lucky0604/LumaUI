local _, app = ...
local Surface = {}
app.Surface = Surface

-- Nine-slicing is what turns two small textures into every card in the UI: the
-- corners keep their pixels and only the straight edges stretch, so a 20-unit
-- card and a 600-unit window share one 4 KB file. The margins here mirror the
-- layout tools/make-media.py builds; a margin smaller than the arc it protects
-- does not fail loudly, it cuts the corner and leaves a seam, which is why both
-- sides carry the same numbers and the generator asserts the relationship.
Surface.plateMargin = 10
Surface.shadowMargin = 36
Surface.shadowInset = 16

-- Texture sublevels are a closed range in the client (-8..7); a value outside it
-- raises inside CreateTexture, which surfaces as a Lua error and taints whatever
-- called it. Naming the two slots keeps the invariant checkable by a test instead
-- of by a stack trace, and the order matters: the shadow draws under the plate.
Surface.LAYERS = { shadow = -8, plate = -7 }

local MEDIA = {
    plate = "Interface\\AddOns\\LumaUI\\Media\\plate.tga",
    shadow = "Interface\\AddOns\\LumaUI\\Media\\shadow.tga",
}
Surface.media = MEDIA

-- Surface roles name a purpose, never a colour: the colour token and the opacity
-- token are resolved on every paint so a theme or profile change needs no rebuild.
-- Both surface APIs now read the same role table in Theme; the old backdrop names
-- are aliases instead of a second palette. Only "card" carries a shadow; a shadow
-- on everything is what turns a layout into a pile of floating boxes.
local ALIASES = {
    card = "window", raised = "button", inset = "embedded",
    hud = "hud", chat = "chat", chatActive = "chatActive",
}
local ROLES = {}
for name, alias in pairs(ALIASES) do
    local spec = app.Theme.surfaceRoles[alias]
    ROLES[name] = {
        color = spec.color,
        opacity = spec.opacity,
        shadow = name == "card",
    }
end
Surface.roles = ROLES
Surface.aliases = ALIASES
local CANONICAL = { window = "card", button = "raised", embedded = "inset" }
Surface.canonical = CANONICAL

function Surface:Role(name)
    local resolved = CANONICAL[name] or name
    return ROLES[resolved] or ROLES.card, resolved
end

-- Feature test once per session. The slice API is the one capability the whole
-- surface language rests on, so it is probed on a real texture rather than assumed
-- from the presence of a metatable method.
function Surface:CanSlice()
    if self.slice ~= nil then return self.slice end
    self.slice = false
    if self.probe then return self.slice end
    if not UIParent or type(UIParent.CreateTexture) ~= "function" then return self.slice end
    local ok, texture = pcall(UIParent.CreateTexture, UIParent, nil, "BACKGROUND")
    if not ok or not texture then return self.slice end
    texture:Hide()
    self.probe = texture
    if type(texture.SetTextureSliceMargins) == "function" then
        local sliced = pcall(texture.SetTextureSliceMargins, texture,
            self.plateMargin, self.plateMargin, self.plateMargin, self.plateMargin)
        self.slice = sliced == true
    end
    return self.slice
end

local function align(texture, points)
    if type(texture.ClearAllPoints) == "function" then texture:ClearAllPoints() end
    if type(texture.SetAllPoints) == "function" and not points then texture:SetAllPoints() return end
    for _, point in ipairs(points or {}) do texture:SetPoint(unpack(point)) end
end

-- Whether the client actually accepted a texture path. `SetTexture` reports success
-- on this build, older ones return nothing, and only an explicit false is treated
-- as a failure so a capable client is never downgraded by a quiet API.
local function applyTexture(texture, path)
    if type(texture.SetTexture) ~= "function" then return false end
    local called, success = pcall(texture.SetTexture, texture, path)
    if not called then return false end
    return success ~= false
end

function Surface:Shadow(frame)
    local shadow = frame.lumaShadow
    if not shadow then
        -- Sublevels run -8..7 and the client rejects anything outside it, so the
        -- shadow takes the lowest legal slot and the plate sits one above it.
        shadow = frame:CreateTexture(nil, "BACKGROUND", nil, self.LAYERS.shadow)
        frame.lumaShadow = shadow
    end
    if not applyTexture(shadow, MEDIA.shadow) then
        shadow:Hide()
        return nil
    end
    if type(shadow.SetTextureSliceMargins) == "function" then
        shadow:SetTextureSliceMargins(self.shadowMargin, self.shadowMargin,
            self.shadowMargin, self.shadowMargin)
    end
    -- The blur lives inside the texture, so the draw is placed one inset larger on
    -- every side: the inner edge of the ramp then lands exactly on the card edge.
    local inset = self.shadowInset
    align(shadow, {
        { "TOPLEFT", frame, "TOPLEFT", -inset, inset },
        { "BOTTOMRIGHT", frame, "BOTTOMRIGHT", inset, -inset },
    })
    if type(shadow.SetVertexColor) == "function" then shadow:SetVertexColor(0, 0, 0, 1) end
    shadow:Show()
    return shadow
end

-- The plate recipe, applied to a texture the caller already owns. Frames go through
-- Surface:Plate; a module that has to decorate a native frame (a tooltip, a
-- nameplate) anchors its own texture and borrows this, so its card can never drift
-- away from the rest of the UI. Returns true when the shape is a real nine-slice.
function Surface:ApplyPlate(texture, roleName)
    if not texture then return false end
    local resolved = CANONICAL[roleName] or roleName
    local name = ROLES[resolved] and resolved or "card"
    local role = ROLES[name]
    local sliced = false
    if self:CanSlice() then
        local loaded = applyTexture(texture, MEDIA.plate)
        self.textureOk = loaded
        if loaded and type(texture.SetTextureSliceMargins) == "function" then
            texture:SetTextureSliceMargins(self.plateMargin, self.plateMargin,
                self.plateMargin, self.plateMargin)
            sliced = true
        end
    else
        self.textureOk = false
    end
    -- No slice support, or the client refused the file: a square fill keeps the
    -- colours and the hierarchy and loses only the corner. That is the right trade —
    -- a distorted corner texture looks broken, a square card just looks older, and
    -- the style sheet says which of the two happened.
    if not sliced and type(texture.SetColorTexture) == "function" then
        texture:SetColorTexture(1, 1, 1, 1)
    end
    local color = app.Theme.colors[role.color] or app.Theme.colors.surface
    if type(texture.SetVertexColor) == "function" then
        texture:SetVertexColor(color[1], color[2], color[3], app.Theme:Opacity(role.opacity))
    end
    return sliced
end

function Surface:Plate(frame, roleName)
    if not frame or type(frame.CreateTexture) ~= "function" then return frame end
    local resolved = CANONICAL[roleName] or roleName
    local name = ROLES[resolved] and resolved or "card"
    local role = ROLES[name]

    if role.shadow and self:CanSlice() then
        self:Shadow(frame)
    elseif frame.lumaShadow then
        frame.lumaShadow:Hide()
    end

    local plate = frame.lumaPlate
    if not plate then
        plate = frame:CreateTexture(nil, "BACKGROUND", nil, self.LAYERS.plate)
        frame.lumaPlate = plate
        -- A plate is the shape. Leaving the old backdrop in place would stack a
        -- 1px edge on top of the new corner and read as a double outline.
        if type(frame.SetBackdrop) == "function" then frame:SetBackdrop(nil) end
        if type(frame.SetBackdropColor) == "function" then frame:SetBackdropColor(0, 0, 0, 0) end
    end

    local sliced = self:ApplyPlate(plate, name)
    if not sliced and frame.lumaShadow then frame.lumaShadow:Hide() end
    align(plate)
    frame.lumaSurfaceRole = name
    return frame
end

-- What the style sheet reports: whether the client can nine-slice at all, and
-- whether it accepted LumaUI's own texture files. Both are probed on the real
-- drawing path rather than assumed, so the panel doubles as the phase-zero test.
function Surface:Diagnostics()
    return { slice = self:CanSlice(), texture = self.textureOk ~= false }
end

-- Repaint without rebuilding. Theme and profile changes call this instead of
-- recreating textures, so a settings change never leaves orphan regions behind.
function Surface:Refresh(frame)
    if not frame then return end
    local role = frame.lumaSurfaceRole
    if role then self:Plate(frame, role) end
    return frame
end

-- A horizontal rule of exactly one physical pixel, whatever the UI scale: 1 at
-- 100%, 2/3 at 150%, 1/2 at 200%. Callers set the width and the anchor.
function Surface:HLine(parent, alpha)
    local line = parent:CreateTexture(nil, "ARTWORK", nil, 1)
    line:SetColorTexture(1, 1, 1, 1)
    line:SetHeight(app.Pixel:Pixels(1))
    local c = app.Theme.colors.line
    line:SetVertexColor(c[1], c[2], c[3], alpha or 0.55)
    return line
end

function Surface:VLine(parent, alpha)
    local line = parent:CreateTexture(nil, "ARTWORK", nil, 1)
    line:SetColorTexture(1, 1, 1, 1)
    line:SetWidth(app.Pixel:Pixels(1))
    local c = app.Theme.colors.line
    line:SetVertexColor(c[1], c[2], c[3], alpha or 0.55)
    return line
end

-- The empty part of a bar. A rounded track needs more height than twice the slice
-- margin, so thin bars (the reference draws them 5–8 px tall) stay square and get
-- their shape from the fill instead of a distorted corner.
function Surface:Track(bar, roleName)
    if not bar then return end
    local name = ROLES[roleName] and roleName or "inset"
    local height = type(bar.GetHeight) == "function" and bar:GetHeight() or 0
    if height >= (self.plateMargin * 2) + 4 and self:CanSlice() then
        return self:Plate(bar, name)
    end
    local track = bar.lumaTrack
    if not track then
        track = bar:CreateTexture(nil, "BACKGROUND", nil, self.LAYERS.plate)
        bar.lumaTrack = track
    end
    track:ClearAllPoints()
    track:SetAllPoints()
    local color = app.Theme.colors[ROLES[name].color] or app.Theme.colors.raised
    track:SetColorTexture(color[1] * 0.55, color[2] * 0.55, color[3] * 0.55, 1)
    return track
end
