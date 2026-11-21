local _, app = ...

-- M5.1 floating combat text, presentation only. LumaUI never creates, moves or
-- reads the numbers the client prints: it restyles the FontStrings that the
-- game's own floating combat text already owns. Only the font is written — the
-- face (GameFontNormal's face), the string's own size and an OUTLINE flag.
-- Text colors are deliberately left untouched: a line's color encodes the
-- client's own message type (damage school, heal, miss, ...) and cannot be
-- classified reliably from the outside, so LumaUI never guesses a palette and
-- the native colors stay exactly as drawn.
--
-- Everything touched is recorded once per enable cycle and its font is put
-- back on disable. The native root is probed, never assumed: FloatingCombatText
-- is the frame the classic floating-combat-text UI owns, and
-- CombatTextFontString is the older standalone region; a build that exposes
-- neither is reported as unsupported and stays inert instead of guessing more
-- names. No event or OnUpdate is registered, and the only writes happen on the
-- component's enable/refresh/disable path, which the runtime calls outside
-- combat and routes through app.Queue.

local JOB = "combatText/apply"
local MAX_DEPTH = 4
local FALLBACK_SIZE = 16

-- Frames are userdata on the live client and tables in the test harness.
local function isObject(value)
    return type(value) == "table" or type(value) == "userdata"
end

-- FontString or something else (texture, frame, ...)? The harness tags stubs
-- with kind; the live client answers through IsObjectType.
local function isFontString(region)
    if not isObject(region) then return false end
    local kind = region.kind
    if kind == "fontstring" then return true end
    if kind == "texture" then return false end
    if type(region.IsObjectType) == "function" then
        local ok, result = pcall(region.IsObjectType, region, "FontString")
        if ok then return result == true end
    end
    -- A region with a font API but no frame children is a FontString; a frame
    -- also carries GetFont in the harness and must not be mistaken for one.
    return type(region.GetFont) == "function" and type(region.SetFont) == "function"
        and type(region.GetChildren) ~= "function" and type(region.GetRegions) ~= "function"
end

-- GetRegions/GetChildren return varargs on the live client and a single table
-- in the harness; both shapes normalize into one array. Every call is guarded,
-- so a region this addon cannot inspect is skipped rather than fatal.
local function collectRegions(frame)
    if type(frame.GetRegions) ~= "function" then return {} end
    local results = { pcall(frame.GetRegions, frame) }
    if not results[1] then return {} end
    local list = {}
    for index = 2, #results do
        if isObject(results[index]) then list[#list + 1] = results[index] end
    end
    return list
end

local function collectChildren(frame)
    if type(frame.GetChildren) ~= "function" then return {} end
    local results = { pcall(frame.GetChildren, frame) }
    if not results[1] then return {} end
    if type(results[2]) == "table" and results[3] == nil then return results[2] end
    local list = {}
    for index = 2, #results do
        if isObject(results[index]) then list[#list + 1] = results[index] end
    end
    return list
end

-- Bounded walk: the root's own regions, then every child's regions. A frame
-- the client nests deeper than MAX_DEPTH is left alone rather than guessed at.
local function collectFontStrings(root)
    local found, visited = {}, {}
    local function walk(object, depth)
        if not isObject(object) or visited[object] or depth > MAX_DEPTH then return end
        visited[object] = true
        if isFontString(object) then found[#found + 1] = object; return end
        for _, region in ipairs(collectRegions(object)) do
            if isFontString(region) then found[#found + 1] = region end
        end
        for _, child in ipairs(collectChildren(object)) do walk(child, depth + 1) end
    end
    walk(root, 1)
    return found
end

-- The font face the rest of LumaUI draws with. nil when the client lacks the
-- global font object; the caller then keeps the region's own face.
local function themeFace()
    local font = _G.GameFontNormal
    if not isObject(font) or type(font.GetFont) ~= "function" then return nil end
    local ok, path = pcall(font.GetFont, font)
    if not ok then return nil end
    return app.Capabilities.Plain(path, "string")
end

-- The FontString's own font, size and flags, read defensively. A region whose
-- font cannot be read is not patched, because it could not be put back.
local function readFont(fontString)
    if type(fontString.GetFont) ~= "function" or type(fontString.SetFont) ~= "function" then return nil end
    local ok, font, size, flags = pcall(fontString.GetFont, fontString)
    if not ok then return nil end
    local Plain = app.Capabilities.Plain
    return Plain(font, "string"), Plain(size, "number"), Plain(flags, "string")
end

-- Read but never written: the recorded color documents what the game drew,
-- while this pass leaves the native palette alone (see the file comment).
local function readColor(fontString)
    if type(fontString.GetTextColor) ~= "function" then return nil end
    local ok, red, green, blue, alpha = pcall(fontString.GetTextColor, fontString)
    if not ok then return nil end
    local Plain = app.Capabilities.Plain
    red, green, blue, alpha = Plain(red, "number"), Plain(green, "number"), Plain(blue, "number"), Plain(alpha, "number")
    if red and green and blue then return { red, green, blue, alpha } end
end

-- The native root: the combat-text frame if this build has one, else the older
-- standalone font string. A missing pair is what makes the component
-- unsupported; no further global names are guessed.
local function findRoot()
    local root = _G.FloatingCombatText
    if isObject(root) and (isFontString(root) or type(root.GetChildren) == "function"
        or type(root.GetRegions) == "function") then
        return root
    end
    local fontString = _G.CombatTextFontString
    if isFontString(fontString) then return fontString end
    return nil
end

-- One record per patched FontString per enable cycle. Weak keys, because the
-- client owns these regions and may replace them between enable cycles.
local function newRecords()
    return setmetatable({}, { __mode = "k" })
end

local function apply(self)
    local root = findRoot()
    if not root then return end
    local records = self.records
    if not records then records = newRecords(); self.records = records end
    local face = themeFace()
    for _, fontString in ipairs(collectFontStrings(root)) do
        if not records[fontString] then
            local font, size, flags = readFont(fontString)
            if font then
                records[fontString] = { font = font, size = size, flags = flags, color = readColor(fontString) }
                pcall(fontString.SetFont, fontString, face or font, size or FALLBACK_SIZE, "OUTLINE")
            end
        end
    end
end

local function restore(self)
    for fontString, record in pairs(self.records or {}) do
        if record.size then
            pcall(fontString.SetFont, fontString, record.font, record.size, record.flags)
        else
            pcall(fontString.SetFont, fontString, record.font)
        end
    end
    -- The records belong to one enable cycle; a fresh table keeps the next
    -- cycle from seeing stale values.
    self.records = newRecords()
end

local function schedule(component, wanted)
    app.Queue:Run(JOB, function()
        if wanted then apply(component) else restore(component) end
    end)
end

app:RegisterComponent({
    id = "combatText",
    label = "combatText",
    defaultEnabled = false,
    Supported = function() return findRoot() ~= nil end,
    Enable = function(self)
        -- apply() creates the cycle's record table on first use, so a repeated
        -- Enable keeps the originals of regions it already patched.
        schedule(self, true)
    end,
    Refresh = function(self)
        schedule(self, true)
    end,
    Disable = function(self)
        schedule(self, false)
    end,
})
