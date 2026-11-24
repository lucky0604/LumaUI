local _, app = ...
local Type = {}
app.Type = Type

-- LumaUI ships no font files. Every client already carries a flat sans for its
-- own script, and borrowing it keeps the download at a few hundred kilobytes and
-- the licensing at zero. ARHei is the Hei (flat) face the Chinese client itself
-- uses, and it also carries Latin glyphs, so one file covers a mixed line without
-- the per-glyph fallback that used to switch from a Latin serif to the client's
-- Kai (calligraphic) face in the middle of a sentence. The latter is the single
-- biggest reason the old text read as patched together rather than designed.
local CANDIDATES = {
    "Fonts\\ARHei.ttf",
    "Fonts\\ARIALN.TTF",
    "Fonts\\FRIZQT__.TTF",
}

-- Roles are a small, closed set on purpose: five sizes and one over-the-world
-- variant. Hierarchy in the reference design comes from weight, colour and
-- outline, not from inventing a new size per call site. Sizes are UI units, not
-- screen pixels; the client scales them, so a role never encodes a resolution.
Type.roles = {
    display = { size = 17, color = "text", weight = "strong" },
    title = { size = 14, color = "text", weight = "strong" },
    body = { size = 12, color = "text" },
    label = { size = 11, color = "muted" },
    micro = { size = 10, color = "muted" },
    -- Anything drawn straight onto the world (names, objectives, combat text)
    -- needs the outline or it disappears against a bright scene.
    world = { size = 13, color = "text", outline = true },
}

local resolved

local function probeFont()
    if Type.probe then return Type.probe end
    if type(CreateFont) ~= "function" then return nil end
    local ok, font = pcall(CreateFont, "LumaTypeProbe")
    if not ok or not font then return nil end
    Type.probe = font
    return font
end

-- A rejected SetFont either returns false or silently keeps the previous face, so
-- the check reads the face back instead of trusting the call.
local function usable(path)
    local probe = probeFont()
    if not probe or type(probe.SetFont) ~= "function" then return false end
    local ok, success = pcall(probe.SetFont, probe, path, 12, "")
    if not ok or success == false then return false end
    if type(probe.GetFont) ~= "function" then return true end
    local read, file = pcall(probe.GetFont, probe)
    if not read or type(file) ~= "string" then return true end
    return file:lower() == path:lower()
end

-- The resolved face, cached for the session. A client that refuses every candidate
-- keeps the face its own font objects already use: always valid, just older.
function Type:Face()
    if resolved then return resolved end
    for _, path in ipairs(CANDIDATES) do
        if usable(path) then
            resolved = path
            return resolved
        end
    end
    local ok, file = pcall(function() return GameFontNormal:GetFont() end)
    if ok and type(file) == "string" and file ~= "" then
        resolved = file
    else
        resolved = "Fonts\\FRIZQT__.TTF"
    end
    self.fallback = true
    return resolved
end

function Type:Role(name)
    return self.roles[name] or self.roles.body
end

function Type:Color(role)
    local colors = app.Theme.colors
    return colors[role.color] or colors.text
end

-- Restyle an existing FontString in place. Returns it so callers can chain.
function Type:Apply(text, roleName)
    if not text then return text end
    local role = self:Role(roleName)
    if type(text.SetFont) == "function" then
        local flags = role.outline and "OUTLINE" or ""
        pcall(text.SetFont, text, self:Face(), role.size, flags)
    end
    local color = self:Color(role)
    if type(text.SetTextColor) == "function" then
        pcall(text.SetTextColor, text, color[1], color[2], color[3], 1)
    end
    if role.weight == "strong" then
        -- The client ships no bold face for addon text, and OUTLINE reads as a
        -- stroke around glyphs rather than weight inside them. A same-colour
        -- shadow nudged one pixel sideways thickens the stems without changing
        -- the letterforms, which is the whole legacy of "fake bold" in this UI.
        if type(text.SetShadowColor) == "function" then
            pcall(text.SetShadowColor, text, color[1], color[2], color[3], 1)
        end
        if type(text.SetShadowOffset) == "function" then
            pcall(text.SetShadowOffset, text, app.Pixel:Pixels(1), 0)
        end
    elseif type(text.SetShadowOffset) == "function" then
        pcall(text.SetShadowOffset, text, 0, 0)
    end
    text.lumaTypeRole = roleName or "body"
    return text
end

function Type:Text(parent, roleName)
    local text = parent:CreateFontString(nil, "OVERLAY")
    if type(text.SetJustifyH) == "function" then text:SetJustifyH("LEFT") end
    return self:Apply(text, roleName)
end

-- Everything the settings diagnostics need to say about typography, without the
-- panel having to know how the face was chosen.
function Type:Diagnostics()
    return { face = self:Face(), fallback = self.fallback == true, roles = 6 }
end
