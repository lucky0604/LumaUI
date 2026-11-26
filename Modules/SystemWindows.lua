local _, app = ...
local module

-- M2.7 system windows, first version: presentation only. Every adapter owns
-- one native window: it records the window's decorative regions, hides the
-- texture art, recolors its FontStrings and draws a LumaUI panel with a 1px
-- edge behind the window content. The window itself is never shown or hidden,
-- secure buttons and child frames are not touched, and disabling restores
-- every recorded value so the native art returns exactly as it was. Opening a
-- window in combat is allowed (texture visibility is not protected); enabling
-- and disabling the component still go through the combat queue like every
-- other component.
--
-- Adding another window later only appends one entry to ADAPTERS below: give
-- it the global frame name (or an ordered `frames` list when the client renamed
-- the window between builds), the art sub-containers worth probing, and either
-- reuse the shared apply/restore pair or provide window specific ones. An
-- adapter marked required makes the component "unsupported" while its frame
-- is missing; unmarked adapters are skipped silently instead.

-- GetRegions yields the window's own regions without gaps, so the trailing
-- nils a table constructor drops carry no region. -> region list or nil.
local function collectRegions(frame)
    if type(frame.GetRegions) ~= "function" then return nil end
    local results = { pcall(frame.GetRegions, frame) }
    if not results[1] then return nil end
    local regions = {}
    for index = 2, #results do regions[#regions + 1] = results[index] end
    return regions
end

-- The modern character window keeps its art in named child frames, not in the
-- window's own regions: the two pane hosts (the right one carries a stone
-- background), the paper doll frame and the model scene. Names confirmed
-- against the reference implementation's skin for the same client generation;
-- every name is probed before use and absent ones are silently skipped.
local SUBFRAMES = { "LeftPaneHost", "RightPaneHost", "PaperDollFrame", "CharacterModelScene" }
local HIDDEN_CHILDREN = { "CharacterLevelTextBackground" }
local SLOT_NAMES = { "Head", "Neck", "Shoulder", "Back", "Chest", "Shirt", "Tabard", "Wrist", "Hands", "Waist",
    "Legs", "Feet", "Finger0", "Finger1", "Trinket0", "Trinket1", "MainHand", "SecondaryHand", "Ranged", "Ammo" }

-- Texture or FontString? Harness stubs tag their regions with kind; the live
-- client answers through IsObjectType. Anything undecidable stays untouched.
local function regionKind(region)
    local kind = region.kind
    if kind == "texture" or kind == "fontstring" then return kind end
    if type(region.IsObjectType) == "function" then
        local ok, isTexture = pcall(region.IsObjectType, region, "Texture")
        if ok then return isTexture and "texture" or "fontstring" end
    end
    return nil
end

local function isRegion(value)
    return type(value) == "table" or type(value) == "userdata"
end

-- Fades a whole frame (used for art containers and row plates), recording its
-- alpha once per enable cycle. Defined before the sweeps that use it: a local
-- declared later would resolve to a nil global inside them.
local function fadeFrame(entry, frame)
    if not isRegion(frame) or type(frame.SetAlpha) ~= "function" or type(frame.GetAlpha) ~= "function" then return end
    if entry.alphaState[frame] == nil then
        local ok, alpha = pcall(frame.GetAlpha, frame)
        if ok and type(alpha) == "number" then entry.alphaState[frame] = alpha end
    end
    pcall(frame.SetAlpha, frame, 0)
end

-- Children arrive as varargs on the live client and as one table in the test
-- harness; both shapes normalize into a plain array.
local function collectChildren(frame)
    if type(frame.GetChildren) ~= "function" then return {} end
    local results = { pcall(frame.GetChildren, frame) }
    if not results[1] then return {} end
    if type(results[2]) == "table" and results[3] == nil then return results[2] end
    local list = {}
    for index = 2, #results do list[#list + 1] = results[index] end
    return list
end

-- A frame's global name, read defensively: a frame the client has not finished
-- initialising can raise from GetName, and a name is only ever used for probing
-- and string matching here.
local function frameName(frame)
    if type(frame.GetName) ~= "function" then return nil end
    local ok, name = pcall(frame.GetName, frame)
    if ok and type(name) == "string" then return name end
    return nil
end

-- A control probed by global name must belong to the window being skinned. A
-- window the client replaced leaves same-named globals behind, and pulling
-- those into the new sweep would fade a frame nobody is looking at while the
-- replacement stays native. Ownership is a parent-chain question, walked with
-- the client's GetParent and the harness's parent field, bounded in depth. An
-- adapter whose window owns a separate toplevel (mail's opened letter) records
-- it in `roots`; a control hanging off one of those is accepted too.
local function owned(entry, value)
    if not isRegion(value) or value == entry.frame then return value end
    local roots = entry.roots
    if roots and roots[value] then return value end
    local guard, parent = 0, value
    while guard < 16 do
        guard = guard + 1
        local up
        if type(parent.GetParent) == "function" then
            local ok, found = pcall(parent.GetParent, parent)
            up = ok and found or nil
        end
        up = up or parent.parent
        if not up or up == parent then return nil end
        if up == entry.frame or (roots and roots[up]) then return value end
        parent = up
    end
    return nil
end

-- The control of that name on the bound window, or nil. The window's own
-- field wins, the global is accepted only when it hangs off the window.
local function named(entry, name)
    if type(name) ~= "string" then return nil end
    local localValue = entry.frame and entry.frame[name]
    if isRegion(localValue) then return localValue end
    return owned(entry, _G[name])
end

-- Named descendants: the client moves controls between anonymous containers
-- across builds, so the explicit name lists below are backed by a bounded
-- substring walk. `keep` filters the hits down to the shapes worth dressing.
local function collectNamed(root, needle, depth, keep)
    local list, seen = {}, {}
    if not isRegion(root) then return list end
    local function add(frame)
        if seen[frame] then return end
        seen[frame] = true
        list[#list + 1] = frame
    end
    local function walk(frame, level)
        if level > depth then return end
        for _, child in ipairs(collectChildren(frame)) do
            local name = frameName(child)
            if name and string.find(name, needle, 1, true) and (not keep or keep(child, name)) then
                add(child)
            end
            walk(child, level + 1)
        end
    end
    walk(root, 1)
    return list
end

local function endsWithDigits(name)
    return type(name) == "string" and string.find(name, "%d+$") ~= nil
end

-- The stats pane draws a dark plate behind every row; only that plate goes,
-- the row's own labels and values (and their game colors) stay as drawn.
local function sweepStatRows(entry, pane)
    if not isRegion(pane) then return end
    for _, row in ipairs(collectChildren(pane)) do
        fadeFrame(entry, row.Background)
    end
end

-- Stat list styling, after the reference skin's technique: a header row gets a
-- dark band and larger type, a stat row gets a faint 1px divider above the row
-- below it, and its label is dimmed so the value (in the game's own color)
-- reads first. Everything LumaUI creates is recorded so disable removes it.
local STAT_BAND_ALPHA, STAT_DIVIDER_ALPHA = 0.35, 0.06

local function ownTexture(entry, parent, layer, sublevel)
    local texture = parent:CreateTexture(nil, layer or "BACKGROUND", nil, sublevel)
    entry.own = entry.own or {}
    entry.own[texture] = true
    entry.decor = entry.decor or {}
    entry.decor[#entry.decor + 1] = texture
    return texture
end

local function styleStatRow(entry, row)
    if not isRegion(row) or type(row.CreateTexture) ~= "function" then return end
    fadeFrame(entry, row.Background)
    if isRegion(row.Title) then
        if not entry.statBand[row] then
            local band = ownTexture(entry, row, "BACKGROUND", -7)
            band:SetAllPoints(row)
            band:SetColorTexture(0, 0, 0, STAT_BAND_ALPHA)
            entry.statBand[row] = band
        end
        entry.statBand[row]:Show()
        if type(row.Title.SetFont) == "function" and type(GameFontNormal) == "table" then
            pcall(row.Title.SetFont, row.Title, GameFontNormal:GetFont(), 12, "")
        end
    elseif isRegion(row.Label) or isRegion(row.Value) then
        if not entry.statLine[row] then
            local line = ownTexture(entry, row, "ARTWORK")
            line:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 6, 0)
            line:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -6, 0)
            line:SetHeight(1)
            line:SetColorTexture(1, 1, 1, STAT_DIVIDER_ALPHA)
            entry.statLine[row] = line
        end
        entry.statLine[row]:Show()
        if isRegion(row.Label) and type(row.Label.SetTextColor) == "function" then
            local muted = app.Theme.colors.muted
            pcall(row.Label.SetTextColor, row.Label, muted[1], muted[2], muted[3], 1)
        end
    end
end

local function dressStatRows(entry, pane)
    if not isRegion(pane) then return end
    for _, row in ipairs(collectChildren(pane)) do
        app:Call("systemWindows/statRow", styleStatRow, entry, row)
    end
end

-- The paper doll sits on its own inset so the model reads as a framed view
-- instead of a hole in the panel.
local function dressModel(entry)
    local scene = _G.CharacterModelScene or entry.frame.CharacterModelScene
    if not isRegion(scene) then return end
    if not entry.modelInset then
        local inset = CreateFrame("Frame", nil, scene, "BackdropTemplate")
        inset:SetAllPoints(scene)
        inset:EnableMouse(false)
        inset:SetFrameLevel(math.max(0, (scene.GetFrameLevel and scene:GetFrameLevel() or 1) - 1))
        entry.modelInset = inset
    end
    local surface, line = app.Theme.colors.surface, app.Theme.colors.line
    app.Theme:Surface(entry.modelInset)
    entry.modelInset:SetBackdropColor(surface[1], surface[2], surface[3], 0.55)
    entry.modelInset:SetBackdropBorderColor(line[1], line[2], line[3], 1)
    entry.modelInset:Show()
end

-- Hides one frame's own texture regions and recolors its FontStrings to the
-- theme text color. Everything is recorded on first sight per enable cycle so
-- restore can put it all back; later runs only hide again, because the client
-- likes to redraw its own art. A keep set protects the art a window needs to
-- stay usable: item icons, slider thumbs and the like. `textOnly` recolors the
-- text and leaves every texture alone, which is what a button whose art must
-- survive (a social window's invite or whisper button) asks for.
local function sweepFrame(entry, frame, keep, textOnly)
    -- A frame the adapter decided must keep its native art is skipped whole:
    -- an input field's box and a page arrow's disabled state are the state, not
    -- decoration, and recoloring their pieces would break how they read.
    if entry.keep and entry.keep[frame] then return end
    local regions = collectRegions(frame)
    if not regions then return end
    for _, region in ipairs(regions) do
        -- `keep` is the per-call keep set (a row's content); `entry.keep` is the
        -- adapter's set of controls that must stay exactly as the client drew
        -- them (a search field, a scroll bar, a result count line).
        if isRegion(region) and not (keep and keep[region]) and not (entry.keep and entry.keep[region])
            and not (entry.own and entry.own[region]) then
            local kind = regionKind(region)
            if kind == "texture" and not textOnly and type(region.SetAlpha) == "function"
                and type(region.GetAlpha) == "function" then
                -- Alpha, not visibility: the client re-shows its own textures
                -- whenever it likes (model load, layout, hover art) and a
                -- hidden texture comes back with it, while a faded one stays
                -- faded. This is the difference between "blank then native
                -- again" and a skin that holds.
                if entry.alphaState[region] == nil then
                    local ok, alpha = pcall(region.GetAlpha, region)
                    if ok and type(alpha) == "number" then entry.alphaState[region] = alpha end
                end
                pcall(region.SetAlpha, region, 0)
            elseif kind == "fontstring" and type(region.SetTextColor) == "function"
                and type(region.GetTextColor) == "function"
                and not (entry.plainText and entry.plainText[region]) then
                if entry.fontState[region] == nil then
                    local ok, red, green, blue, alpha = pcall(region.GetTextColor, region)
                    if ok and red then entry.fontState[region] = { red, green, blue, alpha } end
                end
                local text = app.Theme.colors.text
                region:SetTextColor(text[1], text[2], text[3])
            end
        end
    end
end

-- The keep set of one frame: item icons stay visible because they carry the
-- actual items, and slider thumbs stay because they carry the interaction.
local function keepOf(frame)
    local keep
    local icon = frame.icon or frame.Icon
    if isRegion(icon) then
        keep = { [icon] = true }
    end
    return keep
end

-- The icon of a button is its content — the attached item, the spell — so it
-- joins the own set and every sweep skips it. Clients that keep the icon as a
-- named child ("<ButtonName>Icon") are covered by the second lookup.
local function protectIcon(entry, frame)
    local icon = frame.icon or frame.Icon
    if not isRegion(icon) then return nil end
    entry.own = entry.own or {}
    entry.own[icon] = true
    return icon
end

local function protectNamedIcon(entry, frame)
    local name = frameName(frame)
    local icon = name and named(entry, name .. "Icon")
    if not isRegion(icon) then return nil end
    entry.own = entry.own or {}
    entry.own[icon] = true
    return icon
end

-- Forward declarations: dressTab below uses itemArt, which is defined after it.
-- A local declared later would make the reference a nil global at run time.
local itemArt

-- Tabs lose the game's tab art like everything else, which leaves bare text
-- floating on the panel. Each tab gets a LumaUI surface and a 1px bottom rule,
-- accented while it is the selected page.
local function dressTab(entry, tab, owner)
    if not isRegion(tab) then return end
    -- Icon tabs (the paper doll's side buttons) must keep their icon, so they
    -- take the same path as an item button; text tabs lose all their art.
    if keepOf(tab) then itemArt(entry, tab) else sweepFrame(entry, tab) end
    local decor = entry.tabBg[tab]
    if not decor then
        local surface = tab:CreateTexture(nil, "BACKGROUND", nil, -8)
        surface:SetAllPoints(tab)
        local rule = tab:CreateTexture(nil, "ARTWORK")
        rule:SetPoint("BOTTOMLEFT", tab, "BOTTOMLEFT", 2, 1)
        rule:SetPoint("BOTTOMRIGHT", tab, "BOTTOMRIGHT", -2, 1)
        rule:SetHeight(1)
        decor = { surface = surface, rule = rule }
        entry.tabBg[tab] = decor
        entry.own = entry.own or {}
        entry.own[surface] = true
        entry.own[rule] = true
    end
    local raised, line = app.Theme.colors.raised, app.Theme.colors.line
    local accent = app.Theme:Accent()
    local selected = false
    -- `owner` picks which tab system's active id decides: the spellbook pane's
    -- inner category system, or the window's own page tabs.
    owner = owner or entry.frame
    -- The window's page tabs are PanelTemplates buttons (owner.selectedTab) or
    -- belong to the client's tab system (owner:GetTab() answers the active tab
    -- id). The client's inner tab system can also answer IsSelected on the
    -- button itself. All three are read only; the client keeps deciding what is
    -- selected.
    local selectedID
    if owner and type(owner.GetTab) == "function" then
        local ok, id = pcall(owner.GetTab, owner)
        if ok and type(id) == "number" then selectedID = id end
    end
    if not selectedID and owner and type(owner.selectedTab) == "number" then selectedID = owner.selectedTab end
    if selectedID and type(tab.GetID) == "function" then
        local ok, id = pcall(tab.GetID, tab)
        selected = ok and type(id) == "number" and id ~= 0 and id == selectedID
    end
    if not selected and type(tab.IsSelected) == "function" then
        local ok, isSelected = pcall(tab.IsSelected, tab)
        selected = ok and isSelected == true
    end
    decor.surface:SetColorTexture(raised[1], raised[2], raised[3], selected and 1 or 0.55)
    decor.surface:SetShown(true)
    if selected then
        decor.rule:SetColorTexture(accent[1], accent[2], accent[3], 1)
    else
        decor.rule:SetColorTexture(line[1], line[2], line[3], 1)
    end
    decor.rule:SetShown(true)
end

-- Decorative fields an item button carries; everything else on it (the icon
-- above all) is the actual item art and stays.
local ITEM_ART = { "BorderFrame", "IconBorder", "NormalTexture", "SlotBackground", "SlotArt", "Slot", "Shine" }

-- An item button is recognised by carrying an icon region; those are never
-- swept wholesale, because the icon is the item itself.
function itemArt(entry, button)
    for _, key in ipairs(ITEM_ART) do
        local region = button[key]
        -- A quality border or count the adapter protects is content, not art.
        if not (entry.own and entry.own[region]) then fadeFrame(entry, region) end
    end
    for _, region in ipairs(collectRegions(button) or {}) do
        if isRegion(region) and type(region.GetAtlas) == "function" then
            local ok, atlas = pcall(region.GetAtlas, region)
            if ok and type(atlas) == "string" and string.find(atlas, "GearSlot", 1, true) then
                fadeFrame(entry, region)
            end
        end
    end
end

-- Shared dressing for content buttons (spell slots, attachment slots): the
-- named decorative fields are faded first, then the rest of the button is
-- swept only once its icon is protected — a blind sweep would delete the
-- content the button exists for.
local function dressButtonArt(entry, button, art)
    if not isRegion(button) then return end
    local icon = protectIcon(entry, button) or protectNamedIcon(entry, button)
    for _, key in ipairs(art) do
        local region = button[key]
        -- A field that was registered as content (a quality border) wins over
        -- the plate list, exactly as itemArt treats its own set.
        if not (entry.own and entry.own[region]) then fadeFrame(entry, region) end
    end
    fadeFrame(entry, button.NineSlice)
    if icon then sweepFrame(entry, button) end
    return icon
end

local function isForbidden(frame)
    if type(frame.IsForbidden) ~= "function" then return false end
    local ok, forbidden = pcall(frame.IsForbidden, frame)
    return ok and forbidden == true
end

-- Walks the window's frame tree and strips its decorative art. Naming every
-- frame by hand does not survive client patches, so the walk is shape based:
-- each frame loses its own textures (minus the keep set) and its NineSlice,
-- and its text is recolored. Depths and node counts are capped so a large
-- window cannot turn a repaint into a stall, and the 3D model scene is never
-- descended into.
local WALK_DEPTH, WALK_NODES = 4, 800
local NO_WALK = { CharacterModelScene = true }
local NO_WALK_NAMES = { CharacterModelScene = true, QuestModelScene = true }

-- A price is content, not decoration: fading the coin art leaves a vendor slot
-- with numbers nobody can read. Every money frame is skipped by name, together
-- with its whole subtree, so the client's own coins and numerals stay as drawn.
-- The check is a suffix so a client that renames the parent still keeps its
-- price frames.
local function isMoneyFrameName(name)
    return type(name) == "string" and string.find(name, "MoneyFrame$") ~= nil
end

local function sweepTree(entry, frame, depth, budget)
    if budget.count >= WALK_NODES or depth > WALK_DEPTH then return end
    if type(frame) ~= "table" and type(frame) ~= "userdata" then return end
    if isForbidden(frame) then return end
    local name = frameName(frame)
    if name and (NO_WALK_NAMES[name] or isMoneyFrameName(name)) then return end
    budget.count = budget.count + 1
    local keep = keepOf(frame)
    if keep then
        -- An item button: fade only its decorative art so the icon survives.
        itemArt(entry, frame)
        return
    end
    sweepFrame(entry, frame)
    fadeFrame(entry, frame.NineSlice)
    if depth == WALK_DEPTH then return end
    for _, child in ipairs(collectChildren(frame)) do
        sweepTree(entry, child, depth + 1, budget)
    end
end

-- Hide the window's texture regions, recolor its FontString regions and hide
-- the known art containers. Returns nil when the window cannot be swept at
-- all; it deliberately raises instead of returning nil/false on a failure
-- further in, so an interrupted sweep is rolled back by the caller instead of
-- being mistaken for a completed one.
local function hideArt(entry)
    if collectRegions(entry.frame) == nil then return nil end
    sweepFrame(entry, entry.frame)
    -- Art containers are probed one by one and only hidden when they exist.
    -- CharacterFrame.CurrencyContainer is deliberately absent from this list:
    -- its currency header content is not proven to be pure art, and this
    -- version only hides certain decoration.
    for _, key in ipairs(entry.adapter.containers or {}) do
        fadeFrame(entry, entry.frame[key])
    end
    return true
end

-- Draws the LumaUI backing inside the window itself: a BACKGROUND texture plus
-- four 1px edge strips. Drawing on the window's own background layer is far
-- more reliable than parking a child frame below its parent (client versions
-- clamp that, and a clamped panel shows the world through the window). The
-- window's content — slots, text, the model — sits on higher layers, so the
-- backing never covers anything functional.
local function paintPanel(entry)
    local frame = entry.frame
    local panel = entry.panel
    if not panel then
        panel = {}
        panel.surface = frame:CreateTexture(nil, "BACKGROUND", nil, -8)
        panel.surface:SetAllPoints(frame)
        panel.edges = {}
        for index = 1, 4 do
            local edge = frame:CreateTexture(nil, "BACKGROUND", nil, -7)
            panel.edges[index] = edge
        end
        entry.panel = panel
        -- The backing lives on the window itself, so the art walk would reach
        -- it too; LumaUI's own regions are kept in a set and skipped.
        entry.own = entry.own or {}
        entry.own[panel.surface] = true
        for _, edge in ipairs(panel.edges) do entry.own[edge] = true end
    end
    local bg = app.Theme.colors.raised
    local accent = app.Theme:Accent()
    panel.surface:SetColorTexture(bg[1], bg[2], bg[3], app.Store:Profile().appearance.opacity)
    panel.surface:SetShown(true)
    -- top, bottom, left, right
    panel.edges[1]:ClearAllPoints()
    panel.edges[1]:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
    panel.edges[1]:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
    panel.edges[1]:SetHeight(1)
    panel.edges[2]:ClearAllPoints()
    panel.edges[2]:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 0, 0)
    panel.edges[2]:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
    panel.edges[2]:SetHeight(1)
    panel.edges[3]:ClearAllPoints()
    panel.edges[3]:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
    panel.edges[3]:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 0, 0)
    panel.edges[3]:SetWidth(1)
    panel.edges[4]:ClearAllPoints()
    panel.edges[4]:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
    panel.edges[4]:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
    panel.edges[4]:SetWidth(1)
    for index = 1, 4 do
        panel.edges[index]:SetColorTexture(accent[1], accent[2], accent[3], 1)
        panel.edges[index]:SetShown(true)
    end
    return panel
end

-- Rollback is the one path that must finish: a single region that refuses a
-- write (a protected or half-built object) is skipped, and every other recorded
-- value still returns. Each write is guarded for that reason.
local function restoreArt(entry)
    for region, state in pairs(entry.regionState or {}) do
        if type(region.SetShown) == "function" then pcall(region.SetShown, region, state.shown) end
    end
    entry.regionState = {}
    for region, color in pairs(entry.fontState or {}) do
        if type(region.SetTextColor) == "function" then pcall(region.SetTextColor, region, unpack(color)) end
    end
    entry.fontState = {}
    for container, state in pairs(entry.containerState or {}) do
        if type(container.SetShown) == "function" then pcall(container.SetShown, container, state.shown) end
    end
    entry.containerState = {}
    -- Faded art comes back to the opacity it had before the skin ran.
    for region, alpha in pairs(entry.alphaState or {}) do
        if type(region.SetAlpha) == "function" then pcall(region.SetAlpha, region, alpha) end
    end
    entry.alphaState = {}
    if entry.panel then
        if entry.panel.surface then entry.panel.surface:Hide() end
        for _, edge in ipairs(entry.panel.edges or {}) do edge:Hide() end
    end
end

-- Equipment slots: the game draws a heavy border frame and a "GearSlot" atlas
-- ring around every item button. Both are recorded and hidden, and a thin
-- LumaUI frame colored by the item's quality (or the line color when empty)
-- takes their place. PaperDollItemSlotButton_Update drives the recolors on the
-- live client; tests drive the recolor through the component Refresh.
local function colorSlotBorder(entry, border)
    if not border then return end
    local red, green, blue
    local button = border.qualityButton
    local ok, slotID = pcall(button.GetID, button)
    if ok and type(slotID) == "number" and type(GetInventoryItemQuality) == "function" then
        local okQ, quality = pcall(GetInventoryItemQuality, "player", slotID)
        quality = okQ and app.Capabilities.Plain(quality, "number")
        red, green, blue = app.Theme:QualityColor(quality)
    end
    if not red then
        local line = app.Theme.colors.line
        red, green, blue = line[1], line[2], line[3]
    end
    border:SetBackdropBorderColor(red, green, blue, 1)
end

local function slotBorder(entry, button)
    local border = entry.slotBorders[button]
    if not border then
        border = CreateFrame("Frame", nil, button, "BackdropTemplate")
        -- A 1px edge-only backdrop: without an edgeFile the border color has
        -- nothing to render on the live client.
        border:SetBackdrop({ edgeFile = app.Theme.white, edgeSize = 1,
            insets = { left = 1, right = 1, top = 1, bottom = 1 } })
        border:SetAllPoints(button)
        border:EnableMouse(false)
        border.qualityButton = button
        entry.slotBorders[button] = border
        -- The icon is cropped and sits on a LumaUI surface instead of the
        -- game's slot art, so an empty and a full slot read the same way.
        local icon = button.icon or button.Icon
        if isRegion(icon) and type(icon.SetTexCoord) == "function" then
            entry.own = entry.own or {}
            entry.own[icon] = true
            pcall(icon.SetTexCoord, icon, 0.07, 0.93, 0.07, 0.93)
        end
        local shade = button:CreateTexture(nil, "BACKGROUND", nil, -7)
        shade:SetAllPoints(button)
        local surface = app.Theme.colors.surface
        shade:SetColorTexture(surface[1], surface[2], surface[3], 0.85)
        entry.own = entry.own or {}
        entry.own[shade] = true
        border.shade = shade
    end
    return border
end

local function recolorSlots(entry)
    for _, border in pairs(entry.slotBorders or {}) do colorSlotBorder(entry, border) end
end

local function dressSlots(entry)
    for _, name in ipairs(SLOT_NAMES) do
        local button = named(entry, "Character" .. name .. "Slot")
        if isRegion(button) then
            itemArt(entry, button)
            colorSlotBorder(entry, slotBorder(entry, button))
        end
    end
    if not entry.slotHooked and type(hooksecurefunc) == "function"
        and type(_G.PaperDollItemSlotButton_Update) == "function" then
        entry.slotHooked = true
        -- The string form hooks the global on the live client. The harness now
        -- implements the same two-argument form, but the client global does not
        -- exist there, so the guard above keeps the install client-only.
        pcall(hooksecurefunc, "PaperDollItemSlotButton_Update", function()
            if module.running and entry.panel and entry.panel.surface and entry.panel.surface:IsShown() then
                recolorSlots(entry)
            end
        end)
    end
end

local function applyCharacter(entry)
    -- The dedicated LumaUI character window owns this frame when it runs. The
    -- adapter hands the frame over: it removes its own skin first, and the next
    -- runtime pass re-applies it once the window gives the frame back.
    local dedicated = app.components and app.components.characterWindow
    if dedicated and dedicated.running then return "handover" end
    -- Without region or child access there is no safe art sweep; a panel drawn
    -- under live native art would look broken, so the adapter skips as a whole.
    if type(entry.frame.GetRegions) ~= "function" and type(entry.frame.GetChildren) ~= "function" then
        return false
    end
    -- The backing goes down first: the window is never left blank while the
    -- art is being stripped below.
    paintPanel(entry)
    if not hideArt(entry) then return false end
    -- Shape based walk: every frame in the window loses its decorative
    -- textures and keeps its text, item icons and sliders. Naming frames by
    -- hand does not survive client patches.
    sweepTree(entry, entry.frame, 0, { count = 0 })
    -- The right pane's stone background is the big art piece sitting between
    -- our panel and the stats content.
    local right = entry.frame.RightPaneHost
    if isRegion(right) then fadeFrame(entry, right.StoneBg) end
    for _, name in ipairs(HIDDEN_CHILDREN) do
        fadeFrame(entry, named(entry, name))
    end
    dressSlots(entry)
    -- Side tabs (character pages, paper doll side buttons) keep their text and
    -- lose the game's tab art; the bottom page tabs get a LumaUI surface.
    for index = 1, 8 do dressTab(entry, named(entry, "CharacterFrameModeTab" .. index)) end
    for index = 1, 3 do dressTab(entry, named(entry, "PaperDollSidebarTab" .. index)) end
    for index = 1, 5 do dressTab(entry, named(entry, "CharacterFrameTab" .. index)) end
    dressStatRows(entry, named(entry, "CharacterStatsPaneScrollBox"))
    dressModel(entry)
    paintPanel(entry)
    return true
end

local function restoreCharacter(entry)
    restoreArt(entry)
    -- Equipment slot borders are LumaUI objects, so they are hidden rather than
    -- restored. Everything the game owns came back through restoreArt.
    for _, border in pairs(entry.slotBorders or {}) do
        if type(border.Hide) == "function" then border:Hide() end
        if border.shade then border.shade:Hide() end
    end
    -- LumaUI's own tab surfaces go away with the skin.
    for _, decor in pairs(entry.tabBg or {}) do
        if decor.surface then decor.surface:Hide() end
        if decor.rule then decor.rule:Hide() end
    end
    for _, texture in ipairs(entry.decor or {}) do
        if type(texture.Hide) == "function" then texture:Hide() end
    end
    if entry.modelInset then entry.modelInset:Hide() end
end

-- One LumaUI row decoration, shared by every list an adapter dresses: a faint
-- alternating tint plus a 1px rule, both recorded in the own and decor sets so
-- a repaint never fades them and disable removes them. Cached per row, so
-- repeated applies do not stack textures.
local ROW_TINT_ALPHA, ROW_RULE_ALPHA = 0.05, 0.12

local function dressListRow(entry, cache, row, index, selected)
    if not isRegion(row) or type(row.CreateTexture) ~= "function" or not cache then return end
    local decor = cache[row]
    if not decor then
        local tint = ownTexture(entry, row, "BACKGROUND", -8)
        tint:SetAllPoints(row)
        local rule = ownTexture(entry, row, "ARTWORK")
        rule:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 4, 0)
        rule:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -4, 0)
        rule:SetHeight(1)
        -- The selected row's marker: a 2px accent bar down the left edge, so
        -- the open mail is readable even though the game's row plate is faded.
        local bar = ownTexture(entry, row, "ARTWORK", 1)
        bar:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0)
        bar:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 0, 0)
        bar:SetWidth(2)
        decor = { tint = tint, rule = rule, bar = bar }
        cache[row] = decor
    end
    local line = app.Theme.colors.line
    local accent = app.Theme:Accent()
    decor.tint:SetColorTexture(1, 1, 1, ROW_TINT_ALPHA)
    decor.tint:SetShown(index % 2 == 0)
    decor.rule:SetColorTexture(line[1], line[2], line[3], ROW_RULE_ALPHA)
    decor.rule:SetShown(true)
    decor.bar:SetColorTexture(accent[1], accent[2], accent[3], 1)
    decor.bar:SetShown(selected == true)
end

-- LumaUI textures created for a window are hidden (not destroyed) on disable, so
-- the next enable reuses them through the same caches: the tab surfaces and the
-- rows' tint and rule.
local function hideDecor(entry)
    for _, decor in pairs(entry.tabBg or {}) do
        if decor.surface then decor.surface:Hide() end
        if decor.rule then decor.rule:Hide() end
    end
    for _, texture in ipairs(entry.decor or {}) do
        if type(texture.Hide) == "function" then texture:Hide() end
    end
end

-- Mail: the send and inbox panes carry their own art, the inbox list is a
-- stack of rows with nothing separating them once the game's row plates are
-- faded, and the buttons read as bare text on our panel. Every name below is
-- probed before use, so a client that renames or drops a piece simply keeps that
-- piece native instead of failing as a whole.
--
-- Names confirmed against the live client's MailFrame.xml (InboxFrame with
-- MailItem1..7 rows and their Button child, SendMailFrame with 16 attachment
-- slots, OpenMailFrame with its letter and 16 attachment buttons).
local MAIL_PANES = { "SendMailFrame", "InboxFrame" }
local MAIL_ATTACHMENTS = 16
local MAIL_TABS = 2
local MAIL_BUTTONS = { "SendMailMailButton", "SendMailButton", "SendMailSendButton", "SendMailMoneyButton",
    "SendMailCODButton", "SendMailExpressButton", "SendMailCancelButton", "SendMailSendMoneyButton",
    "InboxPrevPageButton", "InboxNextPageButton", "OpenAllMail", "TakeAllButton", "TakeAllAttachmentsButton",
    "CollectAllButton", "InboxReplyButton", "InboxDeleteButton", "InboxReturnButton",
    "OpenMailReplyButton", "OpenMailDeleteButton", "OpenMailCancelButton", "OpenMailMoneyButton",
    "OpenMailReportSpamButton" }
-- Page arrows carry a disabled texture: the game disables them at the first and
-- last page, so their art must stay for that state to read. They only lose
-- their text color and their backing.
local MAIL_STATE_BUTTONS = { "InboxPrevPageButton", "InboxNextPageButton" }
local MAIL_EDITBOXES = { "SendMailNameEditBox", "SendMailSubjectEditBox", "SendMailBodyEditBox" }

-- Regions that carry item content stay exactly as drawn even where the sweep
-- would fade them: the quality frame of an attachment, the unusable overlay,
-- the stack count and the C.O.D. label. They join the same set a protected icon
-- does, which every sweep already skips.
local function protectRegions(entry, ...)
    entry.own = entry.own or {}
    for index = 1, select("#", ...) do
        local region = select(index, ...)
        if isRegion(region) then entry.own[region] = true end
    end
end

-- An attachment slot shows the attached item's icon; that is content, so the
-- slot only loses its decorative fields. The quality border, the overlay and
-- the count stay so the attachment still reads like an item.
local MAIL_SLOT_ART = { "BorderFrame", "NormalTexture", "SlotBackground", "SlotArt", "Slot", "Shine", "ButtonSlot" }

local function dressAttachment(entry, slot)
    if not isRegion(slot) then return end
    local icon = protectIcon(entry, slot) or protectNamedIcon(entry, slot)
    protectRegions(entry, slot.IconBorder, slot.IconOverlay, slot.IconOverlay2, slot.Count, slot.COD)
    for _, key in ipairs(MAIL_SLOT_ART) do
        local region = slot[key]
        if not (entry.own and entry.own[region]) then fadeFrame(entry, region) end
    end
    fadeFrame(entry, slot.NineSlice)
    if icon then sweepFrame(entry, slot) end
end

-- A text button keeps its label and loses its art. A button that carries an
-- icon (the take-all paperclip, an attachment) keeps it through the same
-- item-button path.
local function dressTextButton(entry, button)
    if not isRegion(button) then return end
    if protectIcon(entry, button) or protectNamedIcon(entry, button) then
        itemArt(entry, button)
    else
        sweepFrame(entry, button)
    end
    fadeFrame(entry, button.NineSlice)
end

-- Inbox rows: "InboxFrameButton1" on most builds, "...Item1" / "...Mail1" on
-- others. Only names ending in a number count as rows, so page buttons are
-- never decorated by mistake. One level of nesting covers scrolled lists.
local function collectMailRows(pane)
    local rows, seen = {}, {}
    local function isRow(frame)
        local name = frameName(frame)
        if not name then return false end
        return string.find(name, "Button%d+$") ~= nil or string.find(name, "Item%d+$") ~= nil
            or string.find(name, "Mail%d+$") ~= nil
    end
    local function add(frame)
        if seen[frame] then return end
        seen[frame] = true
        rows[#rows + 1] = frame
    end
    local function walk(parent, level)
        if level > 2 then return end
        for _, child in ipairs(collectChildren(parent)) do
            if isRow(child) then add(child) else walk(child, level + 1) end
        end
    end
    walk(pane, 1)
    return rows
end

-- An inbox row takes the shared list decoration; the row cache keeps one set of
-- LumaUI textures per row, so a repaint reuses them instead of stacking a
-- second set. The row is the MailItem frame, whose Button child is the check
-- button the client ticks for the open mail.
local function mailRowSelected(row)
    local check = row.Button
    if not isRegion(check) or type(check.GetChecked) ~= "function" then return false end
    local ok, checked = pcall(check.GetChecked, check)
    return ok and checked == true
end

-- The row's sender, subject, expiry and C.O.D. text carry the client's own read
-- state (unread is yellow, read grey) and the expiry color, so they are never
-- recolored; the client rewrites them on every inbox update.
local function plainRowText(entry, row)
    entry.plainText = entry.plainText or {}
    for _, key in ipairs({ "Sender", "Subject", "ExpireTime", "COD", "Count" }) do
        if isRegion(row[key]) then entry.plainText[row[key]] = true end
    end
    if isRegion(row.Button) then
        entry.own = entry.own or {}
        local icon = protectIcon(entry, row.Button) or protectNamedIcon(entry, row.Button)
        if isRegion(row.Button.COD) then entry.plainText[row.Button.COD] = true end
        if isRegion(row.Button.Count) then entry.plainText[row.Button.Count] = true end
        if isRegion(row.Button.IconBorder) then entry.own[row.Button.IconBorder] = true end
        return icon
    end
end

local function dressMailRow(entry, row, index)
    plainRowText(entry, row)
    dressListRow(entry, entry.mailRows, row, index, mailRowSelected(row))
end

-- A page/tab button's art is the only thing that reads as disabled (the client
-- swaps in a grey texture), so those keep their native art and only the walk
-- around them is skinned.
local function keepNative(entry, frame)
    if not isRegion(frame) then return end
    entry.keep = entry.keep or {}
    entry.keep[frame] = true
end

local function dressMail(entry)
    local frame = entry.frame
    -- The opened letter is a toplevel window of its own, not a child of
    -- MailFrame; declaring it a root lets named() accept its controls while
    -- still refusing unrelated frames. It is looked up by its own name, so a
    -- stale letter left by a rebuilt MailFrame is not adopted.
    local letter = _G.OpenMailFrame
    entry.roots = {}
    if isRegion(letter) and frameName(letter) == "OpenMailFrame" then
        entry.roots[letter] = true
    else
        letter = nil
    end
    for _, paneName in ipairs(MAIL_PANES) do
        local pane = named(entry, paneName)
        if isRegion(pane) then
            -- The pane's own backdrop goes; its content is walked separately.
            sweepFrame(entry, pane)
            fadeFrame(entry, pane.NineSlice)
            if paneName == "InboxFrame" then
                local index = 0
                for _, row in ipairs(collectMailRows(pane)) do
                    index = index + 1
                    app:Call("systemWindows/mail/row", dressMailRow, entry, row, index)
                end
                -- The red "too much mail" warning is a message, not decoration.
                local tooMuch = named(entry, "InboxTooMuchMail")
                if isRegion(tooMuch) then
                    entry.plainText = entry.plainText or {}
                    for _, region in ipairs(collectRegions(tooMuch) or {}) do
                        if isRegion(region) and regionKind(region) == "fontstring" then
                            entry.plainText[region] = true
                        end
                    end
                end
            end
        end
    end
    -- Attachment slots live on the send pane and on the opened inbox mail; only
    -- the name pattern changes between builds.
    for index = 1, MAIL_ATTACHMENTS do
        dressAttachment(entry, named(entry, "Attachment" .. index))
        dressAttachment(entry, named(entry, "SendMailAttachment" .. index))
        dressAttachment(entry, named(entry, "MailAttachment" .. index))
        dressAttachment(entry, named(entry, "OpenMailAttachmentButton" .. index))
        dressAttachment(entry, named(entry, "InboxFrameAttachment" .. index))
    end
    -- Input fields keep their native box: the client draws the focus state and
    -- the caret inside it, and a text field that no longer looks like one is a
    -- usability loss, not a skin.
    for _, name in ipairs(MAIL_EDITBOXES) do keepNative(entry, named(entry, name)) end
    for _, name in ipairs(MAIL_STATE_BUTTONS) do keepNative(entry, named(entry, name)) end
    -- Button labels are FontStrings: the sweep recolors them to the theme text
    -- color and records their original color for restore.
    for _, name in ipairs(MAIL_BUTTONS) do
        local button = named(entry, name)
        if isRegion(button) and not (entry.keep and entry.keep[button]) then dressTextButton(entry, button) end
    end
    -- "Send" and "take all" get renamed freely, so any button-shaped descendant
    -- of a pane or of the letter is dressed as well. Row names end in a number
    -- and are skipped here: they were decorated as rows above.
    local function isTextButton(_, name)
        if endsWithDigits(name) then return false end
        return string.find(name, "Button", 1, true) ~= nil
    end
    for _, paneName in ipairs(MAIL_PANES) do
        local pane = named(entry, paneName)
        for _, button in ipairs(collectNamed(pane, "Button", 2, isTextButton)) do
            if not (entry.keep and entry.keep[button]) then dressTextButton(entry, button) end
        end
    end
    if isRegion(letter) then
        for _, button in ipairs(collectNamed(letter, "Button", 2, isTextButton)) do
            dressTextButton(entry, button)
        end
        -- The letter's own frame art is a separate skin: its stationery back
        -- stays (it is the letterhead) and only the surrounding frame goes.
        for _, name in ipairs({ "OpenStationeryBackgroundLeft", "OpenStationeryBackgroundRight" }) do
            keepNative(entry, named(entry, name))
        end
        sweepFrame(entry, letter)
        fadeFrame(entry, letter.NineSlice)
    end
    -- The two panes are page tabs of the window itself.
    for index = 1, MAIL_TABS do dressTab(entry, named(entry, "MailFrameTab" .. index)) end
    if not entry.mailUpdateHooked and type(hooksecurefunc) == "function"
        and type(_G.InboxFrame_Update) == "function" then
        entry.mailUpdateHooked = true
        -- The client rewrites a row whenever the page, the read state or the
        -- open mail changes; the row decorations follow it.
        pcall(hooksecurefunc, "InboxFrame_Update", function()
            if not module.running then return end
            local current = module.entries and module.entries.mail
            if current ~= entry or not entry.applied then return end
            local index = 0
            for _, row in ipairs(collectMailRows(named(entry, "InboxFrame") or entry.frame)) do
                index = index + 1
                plainRowText(entry, row)
                dressListRow(entry, entry.mailRows, row, index, mailRowSelected(row))
            end
        end)
    end
end

local function applyMail(entry)
    local frame = entry.frame
    if type(frame.GetRegions) ~= "function" and type(frame.GetChildren) ~= "function" then return false end
    paintPanel(entry)
    if not hideArt(entry) then return false end
    -- Content buttons are dressed before the tree walk, so their icons are in
    -- the own set by the time the sweep reaches them.
    dressMail(entry)
    sweepTree(entry, frame, 0, { count = 0 })
    paintPanel(entry)
    return true
end

local function restoreMail(entry)
    restoreArt(entry)
    -- The row tint, rule and selection bar are LumaUI textures cached per row:
    -- hide them but keep the objects, so the next enable reuses them. The tab
    -- surfaces and the other decorations go through hideDecor.
    for _, decor in pairs(entry.mailRows or {}) do
        if decor.tint then decor.tint:Hide() end
        if decor.rule then decor.rule:Hide() end
        if decor.bar then decor.bar:Hide() end
    end
    hideDecor(entry)
end

-- Spellbook: the window was SpellBookFrame up to the 10.x client and became the
-- spellbook pane of PlayerSpellsFrame in 11.x, so both names are probed in that
-- order. The 11.x window hosts three pages (specialisations, talents and the
-- spellbook) as hidden children chosen by a tab system; only the spellbook pane
-- is this adapter's to restyle, so the specialisation and talent subtrees, the
-- search preview list and the paged spell grid are excluded from the walk and
-- keep exactly what the client drew.
--
-- Names confirmed against the live client's Blizzard_PlayerSpells sources:
-- PlayerSpellsFrame.SpellBookFrame (SpellBookFrameTemplate) carries the header
-- textures (TopBar, BookBGLeft/Right/Halved, Bookmark, BookCornerFlipbook), the
-- category tab system (CategoryTabSystem), the settings dropdown, the search
-- box, the assisted-combat spell and PagedSpellsFrame, which lays out pooled
-- SpellBookItemTemplate frames two views per page and turns them with
-- PagingControls. A spell item is a row (Backplate, plus a TextContainer with
-- Name / SubName / RequiredLevel) and a Button carrying the spell icon, its
-- learned/unlearned border, hover, trainable, cooldown, auto-cast, glyph and
-- click-binding art. "Not learned" is expressed by desaturating and dimming the
-- icon and dimming the text alpha, so the button subtree is kept whole and only
-- the plate behind it is faded.
local SPELL_TABS, SPELL_BUTTONS = 10, 24
-- The book's page chrome behind the content. Faded whole; text and controls
-- are handled by their own passes below.
local SPELL_CHROME = { "TopBar", "BookBGLeft", "BookBGRight", "BookBGHalved", "Bookmark", "BookCornerFlipbook" }
-- Row text the client rewrites with its own state (the "not learned" dimming,
-- the required level and trainable lines), so it is never recolored.
local SPELL_ROW_TEXT = { "Name", "SubName", "RequiredLevel" }
-- Legacy 10.x spell buttons: decorative fields only, the icon stays.
local SPELL_ART = { "BorderFrame", "IconBorder", "NormalTexture", "SlotBackground", "SlotArt", "SlotFrame", "Slot",
    "Shine" }
-- Top-level subtrees of PlayerSpellsFrame that this adapter does not own.
local SPELL_OUT_OF_SCOPE = { "SpecFrame", "TalentsFrame" }

local function looksLikeSpellButton(frame)
    if isRegion(frame.icon) or isRegion(frame.Icon) then return true end
    local name = frameName(frame)
    return name ~= nil and string.find(name, "SpellButton%d+$") ~= nil
end

local function collectSpellButtons(entry)
    local buttons, seen = {}, {}
    local function add(button)
        if not isRegion(button) or seen[button] then return end
        seen[button] = true
        buttons[#buttons + 1] = button
    end
    for index = 1, SPELL_BUTTONS do
        add(named(entry, "SpellButton" .. index))
    end
    add(entry.frame.SpellButton)
    for _, button in ipairs(collectNamed(entry.frame, "SpellButton", 3)) do
        if looksLikeSpellButton(button) then add(button) end
    end
    return buttons
end

-- The pane that actually holds spell content. On 11.x it is a child of the
-- window; on the older client the bound frame is the spellbook itself.
local function spellbookPane(entry)
    local frame = entry.frame
    if isRegion(frame.SpellBookFrame) then return frame.SpellBookFrame end
    return frame
end

-- The pooled grid the client fills with spell items, its views and its page
-- controls. Absent on the legacy window, which is why every caller falls back.
local function spellPagedFrame(entry, pane)
    if isRegion(pane.PagedSpellsFrame) then return pane.PagedSpellsFrame end
    return named(entry, "PagedSpellsFrame")
end

-- The rows the grid currently shows: category headers and spell items, read
-- from the paged frame's own EnumerateFrames / GetFrames. Returns nil when the
-- window has no paged grid at all, so the caller keeps the legacy named walk.
local function collectSpellItems(entry, pane)
    local paged = spellPagedFrame(entry, pane)
    if not isRegion(paged) then return nil end
    local rows = {}
    if type(paged.EnumerateFrames) == "function" then
        local ok, iterator, state, control = pcall(paged.EnumerateFrames, paged)
        if ok and type(iterator) == "function" then
            -- Bounded like every other walk: a broken iterator must not hang a
            -- repaint.
            for _ = 1, 600 do
                local key, frame = iterator(state, control)
                if key == nil then break end
                control = key
                if isRegion(frame) then rows[#rows + 1] = frame end
            end
            return rows
        end
    end
    if type(paged.GetFrames) == "function" then
        local ok, frames = pcall(paged.GetFrames, paged)
        if ok and type(frames) == "table" then
            for _, frame in ipairs(frames) do
                if isRegion(frame) then rows[#rows + 1] = frame end
            end
        end
    end
    return rows
end

local function isSpellHeader(item)
    return isRegion(item.Text) and not isRegion(item.Button)
end

-- Text the client rewrites: the item name, sub-name and the required-level /
-- trainable line. Their alpha is the unlearned state, so they stay untouched.
local function plainSpellText(entry, item)
    entry.plainText = entry.plainText or {}
    for _, key in ipairs(SPELL_ROW_TEXT) do
        local region = item[key]
        if isRegion(region) and regionKind(region) == "fontstring" then entry.plainText[region] = true end
    end
    if isRegion(item.Text) and regionKind(item.Text) == "fontstring" then entry.plainText[item.Text] = true end
end

-- A category header: the backplate and divider go, the heading text stays.
local function dressSpellHeader(entry, item)
    fadeFrame(entry, item.Backplate)
    fadeFrame(entry, item.Border)
    plainSpellText(entry, item)
end

-- A spell item keeps its whole button (icon, learned/unlearned border, hover,
-- trainable, cooldown, auto-cast, glyph and click-binding art are all client
-- state), loses only the plate behind it and its drop shadow, and takes the
-- shared row tint. Pooled rows are redressed after every page turn.
local function dressSpellItem(entry, item, index)
    if not isRegion(item) then return end
    plainSpellText(entry, item)
    fadeFrame(entry, item.Backplate)
    local button = item.Button
    if isRegion(button) then
        fadeFrame(entry, button.BorderShadow)
        keepNative(entry, button)
    end
    entry.spellRows = entry.spellRows or {}
    dressListRow(entry, entry.spellRows, item, index)
end

-- Tabs of one client tab system. `owner` is the frame whose GetTab (or
-- selectedTab) says which tab id is active; the inner category system belongs
-- to the spellbook pane, the outer one to the window.
local function dressTabSystem(entry, system, owner, seen)
    if not isRegion(system) then return end
    local inner = system.TabSystem
    if not isRegion(inner) then inner = system end
    if type(inner.tabs) ~= "table" then return end
    for _, tab in ipairs(inner.tabs) do
        if isRegion(tab) and not seen[tab] then
            seen[tab] = true
            dressTab(entry, tab, owner)
        end
    end
end

local function redrawSpellTabs(entry)
    local pane = spellbookPane(entry)
    local seen = {}
    dressTabSystem(entry, pane.CategoryTabSystem, pane, seen)
    dressTabSystem(entry, entry.frame.TabSystem, entry.frame, seen)
    -- Named page/side tabs of the legacy window; probing them is harmless on a
    -- client that does not have them.
    for index = 1, SPELL_TABS do
        for _, prefix in ipairs({ "SpellBookFrameTabButton", "PlayerSpellsFrameTabButton", "PlayerSpellsFrameTab",
            "SpellBookSkillLineTab", "SpellBookPageTab" }) do
            local tab = named(entry, prefix .. index)
            if isRegion(tab) and not seen[tab] then
                seen[tab] = true
                dressTab(entry, tab)
            end
        end
    end
    local function isTab(_, name) return endsWithDigits(name) end
    for _, tab in ipairs(collectNamed(entry.frame, "TabButton", 3, isTab)) do
        if not seen[tab] then
            seen[tab] = true
            dressTab(entry, tab)
        end
    end
end

local function redrawSpellRows(entry)
    local pane = spellbookPane(entry)
    local rows = collectSpellItems(entry, pane)
    entry.spellRows = entry.spellRows or {}
    if not rows then
        -- Legacy window without a paged grid: named spell buttons only.
        for _, button in ipairs(collectSpellButtons(entry)) do
            dressButtonArt(entry, button, SPELL_ART)
        end
        return
    end
    local index = 0
    for _, item in ipairs(rows) do
        if isSpellHeader(item) then
            app:Call("systemWindows/spellbook/header", dressSpellHeader, entry, item)
        else
            index = index + 1
            app:Call("systemWindows/spellbook/row", dressSpellItem, entry, item, index)
        end
    end
end

-- The grid rebuilds its rows on every page turn, category change and search
-- clear, all of which go through the paged frame's own layout call; the
-- window's SetTab moves between the spellbook, talent and specialisation
-- pages. Both hooks are installed once per entry, guard on the entry still
-- being the live one and do nothing after disable.
local function hookSpellbook(entry, pane)
    if entry.spellHooked or type(hooksecurefunc) ~= "function" then return end
    entry.spellHooked = true
    local function live()
        return module.running and entry.applied and module.entries and module.entries.spellbook == entry
    end
    local paged = spellPagedFrame(entry, pane)
    if isRegion(paged) and type(paged.DisplayViewsForCurrentPage) == "function" then
        pcall(hooksecurefunc, paged, "DisplayViewsForCurrentPage", function()
            if not live() then return end
            app:Call("systemWindows/spellbook/rows", redrawSpellRows, entry)
        end)
    end
    if type(entry.frame.SetTab) == "function" then
        pcall(hooksecurefunc, entry.frame, "SetTab", function()
            if not live() then return end
            app:Call("systemWindows/spellbook/tabs", redrawSpellTabs, entry)
            app:Call("systemWindows/spellbook/rows", redrawSpellRows, entry)
        end)
    end
end

local function dressSpellbook(entry)
    local frame = entry.frame
    local pane = spellbookPane(entry)
    -- The book chrome behind the content goes; a title strip, when the client
    -- has one, only loses its art and keeps its text.
    for _, key in ipairs(SPELL_CHROME) do fadeFrame(entry, pane[key] or frame[key]) end
    for _, key in ipairs({ "Title", "TitleBg", "TitleBackground", "Header" }) do
        local control = pane[key] or frame[key]
        if isRegion(control) then
            -- The title's own art goes; the frame itself is not faded, because
            -- the title text is a child region and fading the container would
            -- take the text with it.
            sweepFrame(entry, control)
            fadeFrame(entry, control.NineSlice)
            fadeFrame(entry, control.Backplate)
            fadeFrame(entry, control.Background)
        end
    end
    -- Controls whose look is state: the search field (focus ring and caret),
    -- the settings dropdown (its own menu icon), the help plate button, the
    -- assisted-combat spell (a real action with its own tooltip) and the paging
    -- arrows (disabled on the first and the last page).
    keepNative(entry, pane.SearchBox)
    keepNative(entry, pane.SettingsDropdown)
    keepNative(entry, pane.HelpPlateButton)
    keepNative(entry, pane.AssistedCombatRotationSpellFrame)
    local paged = spellPagedFrame(entry, pane)
    if isRegion(paged) then
        keepNative(entry, paged.PagingControls)
        keepNative(entry, paged.ScrollBar)
    end
    redrawSpellRows(entry)
    redrawSpellTabs(entry)
    hookSpellbook(entry, pane)
end

-- The spellbook's own walk, told which subtrees are not its business: the
-- talent and specialisation pages share the window and must keep every piece of
-- art the client draws, and the paged grid and search preview draw rows through
-- their own item pass. Kept frames (search field, dropdown, paging controls)
-- short-circuit their whole subtree.
local SPELL_WALK_DEPTH, SPELL_WALK_NODES = 6, 1200

local function sweepSpellTree(entry, frame, depth, budget)
    if budget.count >= SPELL_WALK_NODES or depth > SPELL_WALK_DEPTH then return end
    if not isRegion(frame) or isForbidden(frame) then return end
    local name = frameName(frame)
    if name and (NO_WALK_NAMES[name] or isMoneyFrameName(name)) then return end
    if entry.keep and entry.keep[frame] then return end
    if entry.spellSkip and entry.spellSkip[frame] then return end
    if entry.spellRows and entry.spellRows[frame] then return end
    budget.count = budget.count + 1
    -- A legacy 10.x spell button carries its own icon: only its decoration goes.
    if looksLikeSpellButton(frame) then
        dressButtonArt(entry, frame, SPELL_ART)
        return
    end
    sweepFrame(entry, frame)
    fadeFrame(entry, frame.NineSlice)
    if depth == SPELL_WALK_DEPTH then return end
    for _, child in ipairs(collectChildren(frame)) do
        sweepSpellTree(entry, child, depth + 1, budget)
    end
end

local function applySpellbook(entry)
    local frame = entry.frame
    if type(frame.GetRegions) ~= "function" and type(frame.GetChildren) ~= "function" then return false end
    paintPanel(entry)
    if not hideArt(entry) then return false end
    -- Icons and kept controls are registered before the walk runs; otherwise
    -- the sweep would fade the spell art itself.
    dressSpellbook(entry)
    local pane = spellbookPane(entry)
    entry.spellSkip = {}
    for _, key in ipairs(SPELL_OUT_OF_SCOPE) do
        local other = frame[key]
        if isRegion(other) then entry.spellSkip[other] = true end
    end
    if isRegion(pane.SearchPreviewContainer) then entry.spellSkip[pane.SearchPreviewContainer] = true end
    local paged = spellPagedFrame(entry, pane)
    if isRegion(paged) then entry.spellSkip[paged] = true end
    sweepSpellTree(entry, frame, 0, { count = 0 })
    paintPanel(entry)
    return true
end

local function restoreSpellbook(entry)
    restoreArt(entry)
    hideDecor(entry)
end

-- Named list rows: the explicit "Prefix<N>" names cover the clients we know and
-- the bounded substring walk picks up a row the client created under a container
-- we do not name. A name ending in a number is the row marker, and a tab also
-- ends in one, so tab buttons are excluded: they are dressed as tabs.
local function isRowName(_, name)
    if not endsWithDigits(name) then return false end
    return string.find(name, "Tab", 1, true) == nil
end

local function collectRows(entry, prefixes, count, needle)
    local frame = entry.frame
    local rows, seen = {}, {}
    local function add(row)
        if not isRegion(row) or seen[row] then return end
        seen[row] = true
        rows[#rows + 1] = row
    end
    for _, prefix in ipairs(prefixes) do
        for index = 1, count do
            add(named(entry, prefix .. index))
        end
    end
    for _, row in ipairs(collectNamed(frame, needle, 3, isRowName)) do add(row) end
    return rows
end

-- ##############################################################################
-- NPC windows: gossip, merchant and quest detail.
--
-- On the retail client these three windows coexist: a dialogue window opens
-- GossipFrame, a vendor opens MerchantFrame and a quest opens QuestFrame, often
-- at the same time. That is unlike the spellbook, whose two names are two
-- generations of one window, so listing the three as candidates of one adapter
-- would skin whichever happened to load first and leave the others native. Each
-- window therefore gets its own adapter entry (npc, merchant, quest) built from
-- the shared apply/restore pair below; every entry keeps its own recorded state
-- and its own OnShow hook, and a window that is missing is skipped silently.
--
-- The windows are also where an icon appears in more than one role: a vendor or
-- reward slot shows the item, an option row is pure text. Option rows take the
-- list treatment (1px rule plus alternating tint); slots only lose the
-- decoration around their icon, which stays visible.
--
-- Every entry probes only the names of its own window. A shared list would let
-- the entry that ran first dress another window's controls and record their
-- alpha in its own state, which makes restore order decide the final opacity.

local NPC_OPTIONS, NPC_SLOTS, NPC_TABS = 16, 12, 4
-- Decoration a vendor or reward slot wears around its icon. The icon itself is
-- the item and never joins this list; the money frames are skipped by the walk.
-- `SlotTexture` is the live client's name for the empty-slot plate a vendor row
-- draws behind its item (MerchantItemTemplate), `SlotArt`/`Slot` the older
-- spelling on reward slots.
local NPC_SLOT_ART = { "BorderFrame", "IconBorder", "NormalTexture", "SlotTexture", "SlotBackground", "SlotArt",
    "SlotFrame", "Slot", "Shine", "NameFrame", "Background", "Border" }
-- What an item button carries that is the item, not its plate: the quality
-- frame, the unusable/quest overlay, the stack count and the vendor's price
-- context icon. Name is a FontString and is registered as plain text instead.
local NPC_ITEM_CONTENT = { "IconBorder", "IconOverlay", "IconOverlay2", "IconQuestTexture", "Count",
    "QuestRewardContextIcon", "UndoFrame", "Name" }
-- The parchment a quest or gossip panel reads on: its background atlas and the
-- four material tiles plus the seal wash. It stays fully drawn — the panel text
-- keeps the client's material colors, which are only readable on that paper.
local NPC_PANEL_ART = { "Bg", "MaterialTopLeft", "MaterialTopRight", "MaterialBotLeft", "MaterialBotRight",
    "SealMaterialBG" }

local NPC_CONTROLS = {
    gossip = {
        -- GreetingPanel is a ScrollBoxList: greeting text, dividers, quest
        -- titles and options are rows pooled from five templates, so the rows
        -- are read through the box, not by name.
        lists = { "GreetingPanel" },
        panes = { "GreetingPanel" },
        -- Older builds keep the option rows as named buttons on a plain pane.
        rows = { "GossipOptionButton" },
        needle = "OptionButton",
        native = { "FriendshipStatusBar" },
        buttons = { "GossipFrameCloseButton", "GossipFrameGreetingGoodbyeButton" },
        tabs = { "GossipFrameTab" },
    },
    merchant = {
        lists = {},
        slots = { "MerchantItem" },
        items = { "MerchantBuyBackItem" },
        buttons = { "MerchantFrameCloseButton", "MerchantSellAllJunkButton", "MerchantRepairAllButton",
            "MerchantRepairItemButton", "MerchantGuildBankRepairButton", "MerchantBuyBackButton" },
        -- Page arrows draw a Disabled texture at the first and last page, and the
        -- filter dropdown owns its menu; both stay exactly as the client drew
        -- them. The money insets and the money frames are skipped by name.
        native = { "MerchantPrevPageButton", "MerchantNextPageButton", "FilterDropdown" },
        tabs = { "MerchantFrameTab" },
    },
    quest = {
        lists = { "QuestFrameGreetingPanel" },
        panes = { "QuestFrameDetailPanel", "QuestFrameRewardPanel", "QuestFrameProgressPanel",
            "QuestFrameGreetingPanel" },
        native = { "AccountCompletedNotice", "FriendshipStatusBar" },
        slots = { "QuestProgressItem", "QuestRewardItem" },
        -- QuestInfo reward buttons are created lazily and re-parented onto the
        -- active scroll child, so they are read from the tree by name shape.
        needles = { "QuestInfoItem" },
        buttons = { "QuestFrameCloseButton", "QuestFrameAcceptButton", "QuestFrameDeclineButton",
            "QuestFrameCompleteButton", "QuestFrameCompleteQuestButton", "QuestFrameGoodbyeButton",
            "QuestFrameRewardCompleteButton" },
        -- The action that moves the quest forward gets the edge; the refusal and
        -- the way out stay quiet.
        primary = { "QuestFrameAcceptButton", "QuestFrameCompleteButton", "QuestFrameCompleteQuestButton",
            "QuestFrameRewardCompleteButton" },
        secondary = { "QuestFrameDeclineButton", "QuestFrameGoodbyeButton" },
        tabs = { "QuestFrameTab" },
    },
}

local function plainRegion(entry, region)
    if not isRegion(region) then return end
    entry.plainText = entry.plainText or {}
    entry.plainText[region] = true
end

-- Registers every FontString under a frame as content text, bounded by depth and
-- node count. Quest and gossip body text carries the client's material colors
-- (and QuestTextContrast may fix them per string), so none of it is recolored.
local function plainNpcText(entry, frame, depth, budget)
    if not isRegion(frame) or depth < 0 or budget.count >= 400 then return end
    for _, region in ipairs(collectRegions(frame) or {}) do
        if isRegion(region) and regionKind(region) == "fontstring" then plainRegion(entry, region) end
    end
    budget.count = budget.count + 1
    for _, child in ipairs(collectChildren(frame)) do
        plainNpcText(entry, child, depth - 1, budget)
    end
end

-- An item button keeps its icon, quality frame, overlays, stack count and name
-- color; only the plate around them goes.
local function dressNpcItem(entry, button)
    if not isRegion(button) then return end
    local icon = protectIcon(entry, button) or protectNamedIcon(entry, button)
    for _, key in ipairs(NPC_ITEM_CONTENT) do
        local region = button[key]
        if isRegion(region) then
            if regionKind(region) == "fontstring" then plainRegion(entry, region) else protectRegions(entry, region) end
        end
    end
    for _, key in ipairs(NPC_SLOT_ART) do
        local region = button[key]
        -- A field that is also content (the quality border, the quest bang's
        -- frame) was protected above and wins over the plate list.
        if not (entry.own and entry.own[region]) then fadeFrame(entry, region) end
    end
    fadeFrame(entry, button.NineSlice)
    -- The hover highlight is the only cue the pointer is over the item.
    if type(button.GetHighlightTexture) == "function" then
        local ok, highlight = pcall(button.GetHighlightTexture, button)
        if ok then protectRegions(entry, highlight) end
    end
    if icon then sweepFrame(entry, button) end
end

-- A vendor slot (MerchantItemTemplate) is a frame around an ItemButton: its own
-- regions are the empty-slot plate, the label frame and the quality-colored
-- name. The name is content; the plate goes; the item button is dressed as one.
local function dressNpcSlot(entry, slot)
    if not isRegion(slot) then return end
    if isRegion(slot.Name) then plainRegion(entry, slot.Name) end
    sweepFrame(entry, slot)
    if isRegion(slot.ItemButton) then
        dressNpcItem(entry, slot.ItemButton)
    else
        dressNpcItem(entry, slot)
    end
end

-- A panel is parchment: its paper and material tiles stay, its body text keeps
-- the client's colors, and only the controls drawn on top are skinned.
local function dressNpcPanel(entry, pane)
    if not isRegion(pane) then return end
    for _, key in ipairs(NPC_PANEL_ART) do protectRegions(entry, pane[key]) end
    plainNpcText(entry, pane, 3, { count = 0 })
    sweepFrame(entry, pane)
end

-- Row and button feedback for the NPC windows (015 phase 03). One state per
-- frame: hover, press and, for a primary action, an accent edge that brightens on
-- hover and pulses once when the button becomes usable. The client's own click,
-- focus and confirmation paths are never replaced; the frame is only observed
-- through HookScript. Hooks cannot be removed, so each reads `state.entry`, which
-- restore clears. Pooled rows reset on hide and on every repaint, so a hover can
-- never carry over to the next row or quest.
local FEEL_ROW, FEEL_PRESS, FEEL_EDGE, FEEL_EDGE_QUIET = 0.10, 0.18, 0.55, 0.30
local feelStates = setmetatable({}, { __mode = "k" })

local function feelEnabled(frame)
    if type(frame.IsEnabled) ~= "function" then return true end
    local ok, value = pcall(frame.IsEnabled, frame)
    return not ok or value ~= false
end

local function feelPaint(state)
    local decor, frame = state.decor, state.frame
    if not decor then return end
    local live = state.entry ~= nil
    local accent = app.Theme:Accent()
    if state.kind == "row" then
        local alpha = live and ((state.press and FEEL_PRESS) or (state.level * FEEL_ROW)) or 0
        decor.hover:SetColorTexture(accent[1], accent[2], accent[3], alpha)
        decor.hover:SetShown(alpha > 0)
        return
    end
    local enabled = live and feelEnabled(frame)
    local base = state.kind == "primary" and FEEL_EDGE or 0
    local alpha = 0
    if enabled then
        local top = state.kind == "primary" and 1 or FEEL_EDGE_QUIET
        alpha = base + (top - base) * state.level
        if state.pulse > alpha then alpha = state.pulse end
        if state.press then alpha = 1 end
    end
    for _, edge in ipairs(decor.edges) do
        edge:SetColorTexture(accent[1], accent[2], accent[3], alpha)
        edge:SetShown(alpha > 0)
    end
end

local function feelTo(state, target)
    if not state.entry then return end
    app.Transitions:Animate(state, "mix", { from = state.level, to = target, duration = 0.12,
        apply = function(value) state.level = value; feelPaint(state) end })
end

local function feelReset(state)
    state.hover, state.press, state.level, state.pulse = false, false, 0, 0
    app.Transitions:Cancel(state, "mix")
    app.Transitions:Cancel(state, "pulse")
    feelPaint(state)
end

local function feelHook(frame, state)
    if state.hooked or type(frame.HookScript) ~= "function" then return end
    state.hooked = true
    local function hook(script, fn)
        pcall(frame.HookScript, frame, script, function()
            if state.entry then app:Call("systemWindows/feel", fn) end
        end)
    end
    hook("OnEnter", function() state.hover = true; feelTo(state, 1) end)
    hook("OnLeave", function() state.hover, state.press = false, false; feelTo(state, 0) end)
    hook("OnMouseDown", function() state.press = true; feelPaint(state) end)
    hook("OnMouseUp", function() state.press = false; feelPaint(state) end)
    hook("OnHide", function() feelReset(state) end)
    if state.kind ~= "row" then
        hook("OnDisable", function() feelPaint(state) end)
        hook("OnEnable", function()
            feelPaint(state)
            if state.kind == "primary" then
                state.pulse = 1
                feelPaint(state)
                app.Transitions:Animate(state, "pulse", { from = 1, to = 0, duration = 0.35,
                    apply = function(value) state.pulse = value; feelPaint(state) end })
            end
        end)
    end
end

local function feelAttach(entry, frame, kind)
    if not isRegion(frame) or type(frame.CreateTexture) ~= "function" then return end
    if type(frame.IsForbidden) == "function" and frame:IsForbidden() then return end
    local state = feelStates[frame]
    if not state then
        state = { frame = frame, kind = kind, level = 0, pulse = 0 }
        feelStates[frame] = state
    end
    state.entry, state.kind = entry, kind
    if not state.decor then
        if kind == "row" then
            local hover = ownTexture(entry, frame, "BACKGROUND", -6)
            hover:SetAllPoints(frame)
            state.decor = { hover = hover }
        else
            local top, bottom, left, right = ownTexture(entry, frame, "OVERLAY"), ownTexture(entry, frame, "OVERLAY"),
                ownTexture(entry, frame, "OVERLAY"), ownTexture(entry, frame, "OVERLAY")
            top:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0); top:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0); top:SetHeight(1)
            bottom:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 0, 0); bottom:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0); bottom:SetHeight(1)
            left:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0); left:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 0, 0); left:SetWidth(1)
            right:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0); right:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0); right:SetWidth(1)
            state.decor = { edges = { top, bottom, left, right } }
        end
    end
    entry.feel = entry.feel or {}
    entry.feel[state] = true
    feelHook(frame, state)
    feelReset(state)
end

local function feelRelease(entry)
    for state in pairs(entry.feel or {}) do
        state.entry = nil
        feelReset(state)
    end
    entry.feel = nil
end

-- One row of a gossip ScrollBoxList. The pool serves five shapes: greeting text
-- (a FontString, no plate), a spacer, a quest title and an option — both the
-- latter carry a 16px bullet/quest icon the client tints (trivial quests are
-- grey) and a label it may fix to the stone color.
local function dressNpcRow(entry, row, index)
    if not isRegion(row) then return end
    if isRegion(row.GreetingText) then
        plainRegion(entry, row.GreetingText)
        return
    end
    local icon = protectIcon(entry, row) or protectNamedIcon(entry, row)
    local regions = collectRegions(row)
    if not icon and (not regions or #regions == 0) then return end
    if type(row.GetFontString) == "function" then
        local ok, label = pcall(row.GetFontString, row)
        if ok then plainRegion(entry, label) end
    end
    -- The hover highlight is the only cue the pointer is over a row, and the
    -- client draws it as an unnamed region; keep it.
    if type(row.GetHighlightTexture) == "function" then
        local ok, highlight = pcall(row.GetHighlightTexture, row)
        if ok then protectRegions(entry, highlight) end
    end
    for _, region in ipairs(regions or {}) do
        if isRegion(region) and regionKind(region) == "texture" and not (entry.own and entry.own[region]) then
            fadeFrame(entry, region)
        end
    end
    dressListRow(entry, entry.npcRows, row, index)
    feelAttach(entry, row, "row")
end

-- A window button keeps its label; a button that carries an icon (the vendor's
-- sell-all/repair tiles) keeps the icon through the item-button path.
local function dressNpcButton(entry, button)
    if not isRegion(button) then return end
    if keepOf(button) then
        dressButtonArt(entry, button, NPC_SLOT_ART)
    else
        dressTextButton(entry, button)
    end
    local kind = entry.feelKind and entry.feelKind[button]
    if kind then feelAttach(entry, button, kind) end
end

-- The greeting panel's quest titles come from the client's titleButtonPool:
-- anonymous buttons that carry the same 16px quest icon and a label. They are
-- anchored on the panel's scroll child, so the walk descends a few levels.
local function collectGreetingRows(pane, depth, rows)
    rows = rows or {}
    if not isRegion(pane) or depth < 0 then return rows end
    for _, child in ipairs(collectChildren(pane)) do
        if isRegion(child) and (isRegion(child.Icon) or isRegion(child.icon)) then
            rows[#rows + 1] = child
        else
            collectGreetingRows(child, depth - 1, rows)
        end
    end
    return rows
end

-- The frames a window's list box currently shows, with each row's position in
-- its own list. Rows are pooled anonymous buttons, so enumeration goes through
-- the box (ForEachFrame on the live ScrollBoxList, EnumerateFrames as the
-- fallback); nil means the client has no box here and the named walk decides.
local function collectBoxRows(panes, position)
    local rows, seen, found = {}, {}, false
    for _, pane in ipairs(panes) do
        local box = pane.ScrollBox
        if isRegion(box) then
            local list
            if type(box.ForEachFrame) == "function" then
                found = true
                list = {}
                pcall(box.ForEachFrame, box, function(row) list[#list + 1] = row end)
            elseif type(box.EnumerateFrames) == "function" then
                found = true
                local ok, enumerated = pcall(box.EnumerateFrames, box)
                if ok and type(enumerated) == "table" then list = enumerated end
            end
            for index, row in ipairs(list or {}) do
                if isRegion(row) and not seen[row] then
                    seen[row] = true
                    position[row] = index
                    rows[#rows + 1] = row
                end
            end
        end
    end
    if not found then return nil end
    return rows
end

-- A named control of the bound window: the frame's own field first, then the
-- global of that name when it belongs to this window. The live quest and
-- merchant windows name most of their children globally without a parentKey,
-- so probing only the field would miss every panel.
local function npcControl(entry, name)
    local control = entry.frame and entry.frame[name]
    if isRegion(control) then return control end
    return named(entry, name)
end

local function dressNpc(entry)
    local frame = entry.frame
    local controls = entry.adapter.controls or {}
    entry.npcRows = entry.npcRows or {}
    entry.feelKind = {}
    for _, key in ipairs(controls.secondary or {}) do entry.feelKind[npcControl(entry, key) or false] = "secondary" end
    for _, key in ipairs(controls.primary or {}) do entry.feelKind[npcControl(entry, key) or false] = "primary" end
    -- Panels are dressed first so their parchment and plain text are recorded
    -- before any sweep reaches them.
    for _, key in ipairs(controls.panes or {}) do
        dressNpcPanel(entry, npcControl(entry, key))
    end
    -- Rows come from the window's list boxes (the gossip ScrollBoxList and the
    -- quest greeting pool) and from the named walk for older builds.
    local panes = {}
    for _, key in ipairs(controls.lists or {}) do
        local pane = npcControl(entry, key)
        if isRegion(pane) then panes[#panes + 1] = pane end
    end
    local index, position = 0, {}
    local boxRows = collectBoxRows(panes, position)
    for _, row in ipairs(boxRows or {}) do
        index = index + 1
        app:Call("systemWindows/" .. entry.adapter.id .. "/row", dressNpcRow, entry, row, position[row] or index)
    end
    -- A greeting panel without a box keeps its pooled title buttons as direct
    -- children; those are walked instead.
    if not boxRows then
        for _, pane in ipairs(panes) do
            local rowIndex = 0
            for _, row in ipairs(collectGreetingRows(pane, 3)) do
                rowIndex = rowIndex + 1
                app:Call("systemWindows/" .. entry.adapter.id .. "/greet", dressNpcRow, entry, row, rowIndex)
            end
        end
    end
    for _, row in ipairs(collectRows(entry, controls.rows or {}, NPC_OPTIONS, controls.needle or "OptionButton")) do
        index = index + 1
        app:Call("systemWindows/" .. entry.adapter.id .. "/row", dressNpcRow, entry, row, index)
    end
    -- Vendor and reward slots: the icon is content, so it joins the own set
    -- before the slot is swept; only the decoration around it goes.
    for _, prefix in ipairs(controls.slots or {}) do
        for slotIndex = 1, NPC_SLOTS do
            local slot = npcControl(entry, prefix .. slotIndex)
            if isRegion(slot) then
                if isRegion(slot.ItemButton) then dressNpcSlot(entry, slot) else dressNpcItem(entry, slot) end
            end
        end
    end
    -- Lazy-created reward buttons, named "<rewardsFrame>QuestInfoItemN".
    for _, needle in ipairs(controls.needles or {}) do
        -- QuestFrame > <panel> > <ScrollChildFrame> > QuestInfoRewardsFrame >
        -- QuestInfoItemN: five levels from the window.
        local hits = collectNamed(frame, needle, 5, isRowName)
        for _, button in ipairs(hits) do
            dressNpcItem(entry, button)
        end
    end
    -- Single item buttons (the buyback slot) take the same path.
    for _, key in ipairs(controls.items or {}) do
        dressNpcSlot(entry, npcControl(entry, key))
    end
    -- Window buttons keep their labels; controls that carry state stay native.
    for _, key in ipairs(controls.buttons or {}) do
        dressNpcButton(entry, npcControl(entry, key))
    end
    for _, key in ipairs(controls.native or {}) do
        keepNative(entry, npcControl(entry, key))
    end
    -- Buttons get renamed freely, so any remaining "…Button" descendant of the
    -- window is dressed as well; numbered names are rows and were handled above.
    local function isLabelButton(_, name)
        if endsWithDigits(name) then return false end
        return string.find(name, "Button", 1, true) ~= nil
    end
    for _, button in ipairs(collectNamed(frame, "Button", 2, isLabelButton)) do
        if not (entry.keep and entry.keep[button]) then dressNpcButton(entry, button) end
    end
    -- Vendor page tabs keep their labels and lose the tab art.
    for _, prefix in ipairs(controls.tabs or {}) do
        for tabIndex = 1, NPC_TABS do
            dressTab(entry, npcControl(entry, prefix .. tabIndex))
        end
    end
    -- Scroll boxes and bars are interaction state, like in the social window.
    for _, pane in ipairs(panes) do
        keepNative(entry, pane.ScrollBar)
        keepNative(entry, pane.ScrollBox)
    end
end

local function applyNpc(entry)
    local frame = entry.frame
    -- Without region or child access there is no safe art sweep; the adapter
    -- skips as a whole, like the other optional windows.
    if type(frame.GetRegions) ~= "function" and type(frame.GetChildren) ~= "function" then return false end
    paintPanel(entry)
    if not hideArt(entry) then return false end
    -- Rows and slots are dressed before the walk: their icons and LumaUI
    -- textures are in the own set by the time the sweep reaches them.
    dressNpc(entry)
    sweepTree(entry, frame, 0, { count = 0 })
    paintPanel(entry)
    return true
end

local function restoreNpc(entry)
    feelRelease(entry)
    restoreArt(entry)
    hideDecor(entry)
end

-- ##############################################################################
-- Social window: FriendsFrame hosts the friends, ignore, who and guild panes, so
-- one entry covers every page. WhoFrame is listed as a fallback name for a
-- client that keeps the who list in a window of its own; the first candidate
-- present wins and every pane below is probed as a child of that frame, so a
-- same-named global from another addon is never repainted.
--
-- Names confirmed against the live client's FriendsFrame.xml/.lua: the three
-- lists are ScrollBoxList panes (FriendsListFrame, FriendsFrame.IgnoreListWindow,
-- WhoFrame) whose rows are pooled from templates (FriendsListButtonTemplate,
-- IgnoreListButtonTemplate, WhoListButtonTemplate) under anonymous names, so the
-- rows are read through the scroll box instead of by global name.
--
-- The window's actions are its point: the invite, whisper, add and remove
-- buttons keep their native art and only take the theme text color. Friend rows
-- keep their status icon, game icon and the client's online/offline background
-- and name colors, and a dressed row is never swept again.

local SOCIAL_ROWS, SOCIAL_TABS = 25, 8
local SOCIAL_ROW_PREFIXES = { "FriendsFrameButton", "WhoListButton", "GuildFrameButton", "GuildRosterButton" }
local SOCIAL_PANES = { "FriendsListFrame", "IgnoreListFrame", "IgnoreListWindow", "WhoFrame", "WhoListFrame",
    "GuildFrame", "GuildRosterFrame", "RaidFrame", "FriendsFrameInset" }
-- The scroll box panes: the friends list, the ignore list (a child of the frame)
-- and the who list. Rows are pooled frames the client reuses, so the list is
-- enumerated through the box on every repaint rather than cached by name.
local SOCIAL_LISTS = { "FriendsListFrame", "IgnoreListWindow", "WhoFrame" }
-- The plate fields a row draws behind its content. Everything else on the row
-- (status icon, game icon, class icon, label) is content and stays. The live
-- client's friends rows name the plate `background`, the who rows only carry a
-- highlight texture — and that highlight is the client's hover/selected state,
-- so it is content, not plate.
local SOCIAL_ROW_ART = { "background", "Background", "Bg",
    "Selection", "Selected", "NormalTexture", "NineSlice", "Border", "BorderTexture", "Divider", "Flash" }
-- Row text that carries the client's semantics: online/offline name colors,
-- the info line, the who columns' class colors. Never recolored.
local SOCIAL_ROW_TEXT = { "name", "Name", "info", "Info", "Variable", "Level", "Class" }
-- Columns, search fields and the scroll bars are interaction state: the client
-- draws hover, sort and disabled states there, and the bar's thumb is the only
-- "where am I in the list" signal. They stay native.
local SOCIAL_NATIVE = { "WhoFrameColumnHeader1", "WhoFrameColumnHeader2", "WhoFrameColumnHeader3",
    "WhoFrameColumnHeader4", "WhoFrameEditBox", "WhoFrameDropdown", "FriendsFrameStatusDropdown",
    "WhoFrameTotals" }
local SOCIAL_ACTIONS = {}
for _, name in ipairs({ "FriendsFrameAddFriendButton", "FriendsFrameRemoveFriendButton", "FriendsFrameInviteButton",
    "FriendsFrameWhisperButton", "FriendsFrameSendMessageButton", "FriendsFrameBroadcastButton",
    "WhoFrameWhoButton", "WhoFrameGroupInviteButton", "WhoFrameAddFriendButton", "WhoFrameIgnoreButton",
    "WhoFrameWhisperButton", "WhoFrameCancelButton", "GuildFrameInviteButton", "GuildFrameWhisperButton",
    "GuildFramePromoteButton", "GuildFrameDemoteButton", "GuildFrameRemoveButton",
    "GuildRosterInviteButton", "GuildRosterWhisperButton", "GuildRosterPromoteButton",
    "GuildRosterDemoteButton", "GuildRosterRemoveButton" }) do
    SOCIAL_ACTIONS[name] = true
end

-- Whether the client marks a frame as protected. Reading the flag is enough:
-- this adapter never writes an attribute or a script on anything.
local function isProtectedFrame(frame)
    if type(frame.IsProtected) ~= "function" then return false end
    local ok, protected = pcall(frame.IsProtected, frame)
    return ok and protected == true
end

-- Content textures on a member row: the status icon (AFK, DND, combat), the
-- battle.net game icon, the class/avatar art and the favourite star. The live
-- client names them with lower-case keys (status, gameIcon, Favorite); the older
-- capitalised spelling is kept for builds that use it. Everything else on the
-- row is its plate, which the skin replaces with a LumaUI rule and tint.
local SOCIAL_ROW_CONTENT = { "status", "Status", "StatusIcon", "gameIcon", "GameIcon", "Icon", "ClassIcon",
    "Avatar", "Speaker", "Favorite" }

local function socialRowKeep(row)
    local keep = {}
    local function add(region)
        if isRegion(region) then keep[region] = true end
    end
    for _, key in ipairs(SOCIAL_ROW_CONTENT) do add(row[key]) end
    local name = frameName(row)
    if name then
        for _, suffix in ipairs(SOCIAL_ROW_CONTENT) do add(_G[name .. suffix]) end
    end
    -- The row's own text carries the client's online/offline and class colors,
    -- and its icon buttons (summon, travel pass) are the row's actions.
    for _, key in ipairs(SOCIAL_ROW_TEXT) do add(row[key]) end
    return keep
end

-- A row is selected when the client locked its highlight (PanelTemplates and the
-- list code call LockHighlight on the selected row). Reading the lock is enough;
-- the skin only draws its own bar and never toggles the client's highlight.
local function socialRowSelected(row)
    if type(row.IsHighlightLocked) ~= "function" then return false end
    local ok, locked = pcall(row.IsHighlightLocked, row)
    return ok and locked == true
end

-- The row text the client rewrites with its own colors: the friend name
-- (online/offline), the info line, and the who columns' class-colored name,
-- middle, level and class strings. Registered as plain text so no sweep or
-- repaint ever recolors them.
local function plainSocialText(entry, row)
    entry.plainText = entry.plainText or {}
    for _, key in ipairs(SOCIAL_ROW_TEXT) do
        local region = row[key]
        if isRegion(region) and regionKind(region) == "fontstring" then entry.plainText[region] = true end
    end
    -- The client's group headers ("Ignored", "Blocked Invites") are rows too.
    if isRegion(row.Title) and regionKind(row.Title) == "fontstring" then entry.plainText[row.Title] = true end
end

-- The list draws its own separators as rows: the "online above, offline below"
-- divider and the group headers ("Ignored", "Blocked Invites"). A divider is a
-- row with nothing but a bar texture — no label and none of the content fields
-- a member row carries — and that bar is the separator, so the row is kept
-- whole. A header has a title and is dressed like any other row; its title text
-- survives through plainSocialText.
local function isDividerRow(row)
    local label = false
    for _, key in ipairs({ "name", "Name", "Title", "info", "Info", "Variable", "Level", "Class" }) do
        if isRegion(row[key]) then return false end
    end
    for _, key in ipairs(SOCIAL_ROW_CONTENT) do
        if isRegion(row[key]) then return false end
    end
    for _, region in ipairs(collectRegions(row) or {}) do
        if isRegion(region) and regionKind(region) == "fontstring" then label = true break end
    end
    return not label
end

-- A member row keeps its icons, its label and its hover highlight; the plate
-- behind them is faded and the row takes the shared rule and alternating tint.
-- A selected row gets the accent bar like the mail list.
local function dressSocialRow(entry, row, index)
    if not isRegion(row) then return end
    entry.dividerRows = entry.dividerRows or {}
    if isDividerRow(row) then
        -- Kept for this pass only: rows come from a shared pool, so the frame
        -- the client hands out next may be a friend instead of a divider, and a
        -- permanent keep would leave that row unpainted. A frame that was a
        -- member row before has a tint and rule on it; those go now.
        entry.dividerRows[row] = true
        local decor = entry.socialRows and entry.socialRows[row]
        if decor then
            if decor.tint then decor.tint:Hide() end
            if decor.rule then decor.rule:Hide() end
            if decor.bar then decor.bar:Hide() end
        end
        return
    end
    entry.dividerRows[row] = nil
    plainSocialText(entry, row)
    for _, key in ipairs(SOCIAL_ROW_ART) do fadeFrame(entry, row[key]) end
    fadeFrame(entry, row.NineSlice)
    protectIcon(entry, row)
    protectNamedIcon(entry, row)
    -- The button's highlight tell is the only cue that the pointer is over a
    -- row; the client keeps it as an unnamed region, so it is read through the
    -- button API and protected instead of being swept.
    protectRegions(entry, row.Highlight, row.HighlightTexture, row.highlight)
    if type(row.GetHighlightTexture) == "function" then
        local ok, texture = pcall(row.GetHighlightTexture, row)
        if ok then protectRegions(entry, texture) end
    end
    -- The row is swept with its content kept: the plate goes, the status and game
    -- icons stay, and any text not in the keep set takes the theme color.
    sweepFrame(entry, row, socialRowKeep(row))
    dressListRow(entry, entry.socialRows, row, index, socialRowSelected(row))
end

-- The panes that own a scroll box. The window's own field wins, and a pane
-- kept as a global hanging off the window is accepted too, so a client that
-- moves one out of the parent frame still has it found.
local function listPanes(entry)
    local panes, seen = {}, {}
    local function add(pane)
        if not isRegion(pane) or seen[pane] then return end
        seen[pane] = true
        panes[#panes + 1] = pane
    end
    for _, key in ipairs(SOCIAL_LISTS) do
        add(entry.frame[key])
        add(named(entry, key))
    end
    add(named(entry, "IgnoreListWindow"))
    return panes
end

-- The frames a list currently shows, read from its scroll box, each with its
-- position inside its own list (the alternating tint restarts per list, not
-- across panes). The live client pools anonymous row buttons from templates, so
-- enumeration has to go through the box: ForEachFrame is the list API,
-- EnumerateFrames the fallback for a view without it. Returns nil when no box
-- exists at all, which lets the caller fall back to the name walk below.
local function collectListRows(entry)
    local rows, position, seen = {}, {}, {}
    local found = false
    for _, pane in ipairs(listPanes(entry)) do
        local box = pane.ScrollBox
        if isRegion(box) then
            local list = nil
            if type(box.ForEachFrame) == "function" then
                found = true
                list = {}
                pcall(box.ForEachFrame, box, function(row) list[#list + 1] = row end)
            elseif type(box.EnumerateFrames) == "function" then
                found = true
                local ok, enumerated = pcall(box.EnumerateFrames, box)
                if ok and type(enumerated) == "table" then list = enumerated end
            end
            for index, row in ipairs(list or {}) do
                if isRegion(row) and not seen[row] then
                    seen[row] = true
                    position[row] = index
                    rows[#rows + 1] = row
                end
            end
        end
    end
    if not found then return nil end
    return rows, position
end

local function collectSocialTabs(entry)
    local tabs, seen = {}, {}
    local function add(tab)
        if not isRegion(tab) or seen[tab] then return end
        seen[tab] = true
        tabs[#tabs + 1] = tab
    end
    -- The page tabs are named; the window's own sub-tabs (friends, recent
    -- allies, recruit-a-friend) come from the client's tab pool, so they carry
    -- no stable name and are read from the tab system itself.
    for index = 1, SOCIAL_TABS do
        add(named(entry, "FriendsFrameTab" .. index))
        add(named(entry, "FriendsFrameTabButton" .. index))
    end
    local header = named(entry, "FriendsTabHeader")
    if not isRegion(header) then header = entry.frame and entry.frame.FriendsTabHeader end
    if isRegion(header) then
        local system = header.TabSystem
        if isRegion(system) and type(system.tabs) == "table" then
            for _, tab in ipairs(system.tabs) do add(tab) end
        end
    end
    for _, tab in ipairs(collectNamed(entry.frame, "TabButton", 3, endsWithDigits)) do add(tab) end
    return tabs
end

-- The social window's own walk. It differs from sweepTree in two ways: a dressed
-- row is left alone (its status and game icons are content), and a protected
-- frame or a window action button only has its text recolored, never its art.
-- Depth and node caps keep a long list from turning a repaint into a stall.
local SOCIAL_WALK_DEPTH, SOCIAL_WALK_NODES = 4, 800

local function sweepSocialTree(entry, frame, depth, budget)
    if budget.count >= SOCIAL_WALK_NODES or depth > SOCIAL_WALK_DEPTH then return end
    if not isRegion(frame) or isForbidden(frame) then return end
    local name = frameName(frame)
    if name and (NO_WALK_NAMES[name] or isMoneyFrameName(name)) then return end
    budget.count = budget.count + 1
    -- A kept frame is interaction state (a scroll box, its bar, a search field):
    -- the whole subtree stays native. Rows inside a list box are dressed by the
    -- row pass, not by the walk.
    if entry.keep and entry.keep[frame] then return end
    -- A dressed row already had its plate replaced and its icons kept, so the
    -- walk does not touch it a second time. A divider's bar is the separator
    -- itself, and a header's title has already been registered as plain text.
    if entry.socialRows and entry.socialRows[frame] then return end
    if entry.dividerRows and entry.dividerRows[frame] then return end
    if (name and SOCIAL_ACTIONS[name]) or isProtectedFrame(frame) then
        -- Text only: the button keeps its art and its click, the label follows
        -- the theme.
        sweepFrame(entry, frame, nil, true)
        return
    end
    if keepOf(frame) then
        -- An item button: fade only its decoration so the icon survives.
        itemArt(entry, frame)
        return
    end
    sweepFrame(entry, frame)
    fadeFrame(entry, frame.NineSlice)
    if depth == SOCIAL_WALK_DEPTH then return end
    for _, child in ipairs(collectChildren(frame)) do
        sweepSocialTree(entry, child, depth + 1, budget)
    end
end

-- The window controls that are interaction state and stay native: the who
-- list's sortable column headers (they draw the sort arrow and their own
-- pressed/hover art), the search field (focus and caret), the filter
-- dropdowns (their own menus), the result count line and the ignore list's
-- unignore button (it is enabled only while a player is selected, and its
-- disabled look is the only signal for that). The scroll boxes and bars are
-- found through their panes rather than by name.
local function keepSocialNative(entry)
    for _, name in ipairs(SOCIAL_NATIVE) do keepNative(entry, named(entry, name)) end
    local ignore = named(entry, "IgnoreListWindow")
    if isRegion(ignore) then keepNative(entry, ignore.UnignorePlayerButton) end
    for _, pane in ipairs(listPanes(entry)) do
        keepNative(entry, pane.ScrollBar)
        keepNative(entry, pane.ScrollBox)
    end
end

-- Rows are dressed from the scroll box when the client has one, and from the
-- named walk otherwise. The box also reports each row's position inside its own
-- list; the named walk falls back to one running index, because its hits are
-- already in list order. A row keeps its content either way, and the walk below
-- reads the row cache so it never dresses a row twice in one pass.
local function socialRows(entry)
    local rows, position = collectListRows(entry)
    if rows then return rows, position end
    local walked = collectRows(entry, SOCIAL_ROW_PREFIXES, SOCIAL_ROWS, "Button")
    position = {}
    for index, row in ipairs(walked) do position[row] = index end
    return walked, position
end

local function redrawSocialRows(entry)
    -- The divider set describes this pass only: the client's row pool hands the
    -- same frame out as a friend, a header or a divider in different rebuilds.
    entry.dividerRows = {}
    local rows, position = socialRows(entry)
    for _, row in ipairs(rows) do
        app:Call("systemWindows/social/row", dressSocialRow, entry, row, position[row] or 0)
    end
end

local function dressSocial(entry)
    local frame = entry.frame
    entry.socialRows = entry.socialRows or {}
    for _, key in ipairs(SOCIAL_PANES) do
        local pane = frame[key]
        if isRegion(pane) then
            sweepFrame(entry, pane)
            fadeFrame(entry, pane.NineSlice)
        end
    end
    keepSocialNative(entry)
    redrawSocialRows(entry)
    -- Top page tabs keep their text; the selected page carries the accent rule.
    for _, tab in ipairs(collectSocialTabs(entry)) do dressTab(entry, tab) end
    -- The client rebuilds a list whenever its data changes (a friend comes
    -- online, a who search returns, a page is scrolled) and reuses pooled rows,
    -- so the decorations have to be reapplied after each rebuild. The hooks are
    -- installed once per entry, guard on the entry still being the live one, and
    -- do nothing after disable.
    if not entry.socialHooked and type(hooksecurefunc) == "function" then
        entry.socialHooked = true
        local function live()
            return module.running and entry.applied and module.entries
                and module.entries.social == entry
        end
        local function refreshRows()
            if not live() then return end
            app:Call("systemWindows/social/rows", redrawSocialRows, entry)
        end
        for _, name in ipairs({ "FriendsList_Update", "WhoList_Update", "IgnoreList_Update" }) do
            if type(_G[name]) == "function" then pcall(hooksecurefunc, name, refreshRows) end
        end
        local function refreshSelection()
            if not live() then return end
            local rows, position = socialRows(entry)
            for _, row in ipairs(rows) do
                dressListRow(entry, entry.socialRows, row, position[row] or 0, socialRowSelected(row))
            end
        end
        -- Selection changes do not rebuild the list; they only move the modal
        -- highlight, so only the rows' accent bars need to follow.
        for _, name in ipairs({ "FriendsFrame_SelectFriend", "WhoList_SetSelectedButton" }) do
            if type(_G[name]) == "function" then pcall(hooksecurefunc, name, refreshSelection) end
        end
    end
end

local function applySocial(entry)
    local frame = entry.frame
    if type(frame.GetRegions) ~= "function" and type(frame.GetChildren) ~= "function" then return false end
    paintPanel(entry)
    if not hideArt(entry) then return false end
    -- Rows and tabs are dressed before the walk, so the walk sees their caches
    -- and their icons are protected before it reaches them.
    dressSocial(entry)
    sweepSocialTree(entry, frame, 0, { count = 0 })
    paintPanel(entry)
    return true
end

local function restoreSocial(entry)
    restoreArt(entry)
    hideDecor(entry)
end

local ADAPTERS = {
    {
        id = "character",
        frame = "CharacterFrame",
        required = true,
        containers = { "NineSlice" },
        -- The dedicated LumaUI character window competes for this frame, so
        -- this adapter is re-considered on every runtime pass: whoever owns the
        -- frame at that moment decides, and the handover restores the old skin
        -- before either side draws.
        mutual = true,
        apply = applyCharacter,
        restore = restoreCharacter,
    },
    { id = "mail", frame = "MailFrame", containers = { "NineSlice" }, apply = applyMail, restore = restoreMail },
    -- NPC windows: gossip, vendor and quest detail are three different windows
    -- that exist at the same time, so they are three entries over one shared
    -- dressing instead of three candidate names of a single window. Each keeps
    -- its own state, its own OnShow hook and its own control names.
    { id = "npc", frame = "GossipFrame", containers = { "NineSlice" }, controls = NPC_CONTROLS.gossip,
        apply = applyNpc, restore = restoreNpc },
    { id = "merchant", frame = "MerchantFrame", containers = { "NineSlice" }, controls = NPC_CONTROLS.merchant,
        apply = applyNpc, restore = restoreNpc },
    { id = "quest", frame = "QuestFrame", containers = { "NineSlice" }, controls = NPC_CONTROLS.quest,
        apply = applyNpc, restore = restoreNpc },
    -- The social window: FriendsFrame holds the friends, ignore, who and guild
    -- panes; WhoFrame is its fallback name on a client that keeps the who list
    -- in a window of its own.
    { id = "social", frames = { "FriendsFrame", "WhoFrame" }, containers = { "NineSlice" },
        apply = applySocial, restore = restoreSocial },
    -- The spellbook was renamed between client generations: the first candidate
    -- name present wins, and the adapter stays silent when neither exists.
    { id = "spellbook", frames = { "SpellBookFrame", "PlayerSpellsFrame" }, containers = { "NineSlice" },
        apply = applySpellbook, restore = restoreSpellbook },
}

-- A window can carry different names across client generations. Adapters list
-- their candidates in order; the first one present wins.
local function adapterFrame(adapter)
    if not adapter.frames then return _G[adapter.frame] end
    for _, name in ipairs(adapter.frames) do
        local frame = _G[name]
        if frame then return frame end
    end
    return nil
end

-- ##############################################################################
-- Adapter lifecycle.
--
-- Every window adapter is its own state machine, independent of the component:
-- `applied` says whether this window currently wears the LumaUI skin, `status`
-- records the last attempt (applied / failed / handover / missing). The
-- component being "running" never stands in for a window having been applied;
-- a window that fails keeps its native art and leaves its neighbours alone.
--
-- One apply either finishes or is undone: the window's recorded state is
-- rolled back whenever the attempt throws or refuses, so a half-swept window is
-- never left on screen. The delayed repaints after OnShow are one-shot timers
-- owned by the adapter, bounded per window, and cancelled on disable, failure
-- or handover so a stale callback can never repaint a restored window.

local RETRY_DELAYS = { 0.4, 1.6 }
local RETRY_LIMIT = #RETRY_DELAYS

local windowState = {}   -- [id] = last status, for diagnostics
local retries = {}       -- [id] = { { token = n, handle = timer }, ... }
local watching = false   -- LoD discovery listeners installed

local function cancelRetries(id)
    local list = retries[id]
    if not list then return end
    retries[id] = nil
    for _, item in ipairs(list) do
        if item.handle and type(item.handle.Cancel) == "function" then pcall(item.handle.Cancel, item.handle) end
    end
end

local function cancelAllRetries()
    for id in pairs(retries) do cancelRetries(id) end
end

-- Every LumaUI object an entry can carry, hidden in one sweep. An apply that
-- failed halfway may have created caches its adapter's own restore does not
-- know about yet, so the rollback hides them generically after the adapter's
-- restore has put the native values back. Only objects LumaUI created are
-- hidden: the own set also holds client regions the skin protects (item
-- icons), and those must never be touched.
local function hideOwnObjects(entry)
    for index = #(entry.decor or {}), 1, -1 do
        local texture = entry.decor[index]
        if type(texture.Hide) == "function" then pcall(texture.Hide, texture) end
    end
    for _, cache in ipairs({ entry.tabBg, entry.statBand, entry.statLine, entry.slotBorders }) do
        for _, object in pairs(cache or {}) do
            if type(object.Hide) == "function" then pcall(object.Hide, object) end
            if object.shade and type(object.shade.Hide) == "function" then pcall(object.shade.Hide, object.shade) end
            if object.surface and type(object.surface.Hide) == "function" then pcall(object.surface.Hide, object.surface) end
            if object.rule and type(object.rule.Hide) == "function" then pcall(object.rule.Hide, object.rule) end
        end
    end
    for _, cache in ipairs({ entry.mailRows, entry.npcRows, entry.socialRows }) do
        for _, decor in pairs(cache or {}) do
            if decor.tint and type(decor.tint.Hide) == "function" then pcall(decor.tint.Hide, decor.tint) end
            if decor.rule and type(decor.rule.Hide) == "function" then pcall(decor.rule.Hide, decor.rule) end
            if decor.bar and type(decor.bar.Hide) == "function" then pcall(decor.bar.Hide, decor.bar) end
        end
    end
    if entry.panel then
        if entry.panel.surface and type(entry.panel.surface.Hide) == "function" then pcall(entry.panel.surface.Hide, entry.panel.surface) end
        for _, edge in ipairs(entry.panel.edges or {}) do
            if type(edge.Hide) == "function" then pcall(edge.Hide, edge) end
        end
    end
    if entry.modelInset and type(entry.modelInset.Hide) == "function" then pcall(entry.modelInset.Hide, entry.modelInset) end
end

-- One apply attempt, with its outcome recorded and its failure rolled back.
-- Returns the status string so the caller can decide whether retries make
-- sense. The nil/false returns of an adapter both mean "this window cannot be
-- skinned as a whole": no partial skin is kept.
local function paintEntry(entry, reason)
    -- A job queued for a later combat-queue flush must not repaint after the
    -- component was disabled in the meantime.
    if not module.running then return nil end
    -- A failure sticks: the same window is not re-attempted by every following
    -- runtime pass, refresh or retry (that would be an unbounded retry loop
    -- wearing another name, and would repeat one defect as a stream of errors).
    -- Opening the window again is a real change worth a fresh attempt.
    if entry.status == "failed" and reason ~= "show" then return entry.status end
    local adapter = entry.adapter
    local id = adapter.id
    local ok, result = app:Call("systemWindows/" .. id .. "/" .. (reason or "apply"), adapter.apply, entry)
    local status
    if not ok then
        status = "failed"
        entry.failure = "error"
    elseif result == "handover" then
        status = "handover"
        entry.failure = nil
    elseif result == true then
        status = "applied"
        entry.failure = nil
    else
        status = "failed"
        entry.failure = "unusable"
    end
    if status == "applied" then
        entry.applied = true
    else
        -- Failure and handover both leave the frame to somebody else. Anything
        -- the attempt recorded is undone here, and pending repaints are
        -- cancelled first so none of them can re-skin the window afterwards.
        cancelRetries(id)
        app:Call("systemWindows/" .. id .. "/rollback", adapter.restore, entry)
        -- The adapter's restore knows its own caches; this second sweep covers
        -- objects an interrupted attempt created before it could be completed.
        app:Call("systemWindows/" .. id .. "/rollback/own", hideOwnObjects, entry)
        entry.applied = false
    end
    entry.status = status
    windowState[id] = status
    -- 015 phase 13: one record per window, so the module page can say whether
    -- the skin or the client's own window is on screen and why.
    if app.Ownership then
        local owned = entry.applied == true
        app.Ownership:Set("systemWindows." .. id, { intent = "owned",
            active = owned and "owned" or "native", evidence = "simulated",
            reason = (not owned) and tostring(status or "idle") or nil })
    end
    return status
end

-- A delayed repaint: the client lays the window out and reloads its art after
-- OnShow, so the skin is painted again shortly after. Each callback is a
-- one-shot owned here, capped per window, and it drops itself when the
-- component stopped, the window was rolled back or the frame was rebound.
local function scheduleRetry(entry, delay)
    if type(C_Timer) ~= "table" or type(C_Timer.After) ~= "function" then return end
    local id = entry.adapter.id
    local list = retries[id] or {}
    retries[id] = list
    if #list >= RETRY_LIMIT then return end
    local item
    item = {}
    item.handle = C_Timer.After(delay, function()
        -- Cancellation is by handle and list membership: a callback that fired
        -- after its list was replaced (disable, rollback) is stale by token and
        -- must do nothing at all.
        if not retries[id] or retries[id] ~= list then return end
        for index = #list, 1, -1 do
            if list[index] == item then table.remove(list, index) end
        end
        if not module.running or not entry.applied then return end
        if entry.frame ~= adapterFrame(entry.adapter) then return end
        paintEntry(entry, "retry")
    end)
    list[#list + 1] = item
end

local function hookEntry(entry, entries)
    if entry.hooked then return end
    entry.hooked = true
    entry.frame:HookScript("OnShow", function()
        -- The window may be opened in combat: hiding textures and repainting
        -- the backing are not protected operations, so this repaints directly
        -- while the component runs. The hook is installed once per frame and
        -- turns into a no-op while the component is disabled, or once the entry
        -- has been rebound to a rebuilt frame.
        if not module.running then return end
        if entries[entry.adapter.id] ~= entry then return end
        -- Repeated shows are idempotent: caches make every repaint reuse the
        -- same textures instead of stacking a second set.
        if paintEntry(entry, "show") == "applied" then
            for _, delay in ipairs(RETRY_DELAYS) do scheduleRetry(entry, delay) end
        end
    end)
end

-- Binds one adapter to its window (or unbinds a stale binding first). Returns
-- false when the window does not exist yet; the caller then installs the LoD
-- discovery listeners.
local function bindAdapter(adapter, entries)
    local frame = adapterFrame(adapter)
    local entry = entries[adapter.id]
    -- A previous enable may have bound the entry to another candidate name (or
    -- to a window that was rebuilt): restore against the old frame before
    -- binding the new one.
    if entry and entry.frame ~= frame then
        cancelRetries(adapter.id)
        app:Call("systemWindows/" .. adapter.id .. "/restore", adapter.restore, entry)
        entries[adapter.id] = nil
        entry = nil
    end
    if not frame then
        if entry then
            cancelRetries(adapter.id)
            app:Call("systemWindows/" .. adapter.id .. "/restore", adapter.restore, entry)
            entries[adapter.id] = nil
        end
        windowState[adapter.id] = "missing"
        return false
    end
    if not entry then
        entry = { adapter = adapter, frame = frame, regionState = {}, fontState = {},
            containerState = {}, alphaState = {}, slotBorders = {}, tabBg = {}, own = {},
            statBand = {}, statLine = {}, decor = {}, mailRows = {}, applied = false }
        entries[adapter.id] = entry
    end
    entry.frame = frame
    hookEntry(entry, entries)
    app.Queue:Run("systemWindows/" .. adapter.id .. "/apply", function() paintEntry(entry, "enable") end)
    return true
end

-- Known load-on-demand windows: a window absent at login arrives later as the
-- client loads its addon. Discovery runs on those real load events only, and a
-- window that appeared is bound exactly like one present at login.
local function discover(moduleRef)
    for _, adapter in ipairs(ADAPTERS) do
        if not moduleRef.entries[adapter.id] and adapterFrame(adapter) then
            bindAdapter(adapter, moduleRef.entries)
        end
    end
end

local function watchLoad(moduleRef)
    if watching then return end
    watching = true
    local function wake()
        if moduleRef.running then app:Call("systemWindows/discover", discover, moduleRef) end
    end
    moduleRef:Listen("ADDON_LOADED", wake)
    moduleRef:Listen("PLAYER_ENTERING_WORLD", wake)
end

-- Re-considers the windows whose owner may have changed: after a profile
-- switch, a theme rebuild or the dedicated character window stopping, a window
-- that was handed over or failed gets a fresh decision without a second hook.
-- Installed with every enable, because the base cleanup drops the component's
-- subscriptions on disable.
-- Whether the adapter's window is still the frame the entry is bound to. The
-- client can rebuild or replace a window; the entry then follows the name
-- rather than a dead frame, and bindAdapter restores and rebinds it.
local function reframe(adapter, entries)
    local entry = entries[adapter.id]
    if not entry then return false end
    if adapterFrame(adapter) == entry.frame then return false end
    bindAdapter(adapter, entries)
    return true
end

local function onRuntimeUpdated()
    if not module.running or not module.entries then return end
    for _, adapter in ipairs(ADAPTERS) do
        local entry = module.entries[adapter.id]
        if not entry then
            -- A profile switch can arrive before the window did: discovery is
            -- idempotent and binds only what exists.
            if adapterFrame(adapter) then bindAdapter(adapter, module.entries) end
        elseif reframe(adapter, module.entries) then
            -- A rebuilt window was just rebound and painted by bindAdapter.
        elseif adapter.mutual then
            -- A mutually exclusive adapter follows its owner on every runtime
            -- pass, whether it is currently applied or handed over; a failed
            -- window keeps its failure until the next real attempt.
            app.Queue:Run("systemWindows/" .. adapter.id .. "/apply",
                function() paintEntry(entry, "runtime") end)
        end
    end
end


module = app:RegisterComponent({
    id = "systemWindows", label = "systemWindows", defaultEnabled = false,
    Supported = function()
        for _, adapter in ipairs(ADAPTERS) do
            if adapter.required and adapterFrame(adapter) == nil then return false end
        end
        return true
    end,
    Enable = function(self)
        self.entries = self.entries or {}
        -- A window that arrives by load-on-demand after login is discovered on
        -- its real load event; the listeners exist only while the component
        -- runs and are released by Cleanup.
        watchLoad(self)
        app:Subscribe(self, "RUNTIME_UPDATED", onRuntimeUpdated)
        for _, adapter in ipairs(ADAPTERS) do bindAdapter(adapter, self.entries) end
    end,
    Refresh = function(self)
        for id, entry in pairs(self.entries or {}) do
            -- Re-attempting every bound window here is what lets a failed or
            -- handed-over window recover on the next pass without any timer:
            -- the apply itself decides applied / handover / failed again.
            app.Queue:Run("systemWindows/" .. id .. "/apply", function() paintEntry(entry, "refresh") end)
        end
    end,
    Disable = function(self)
        -- Pending one-shots die first: a delayed repaint must never repaint a
        -- window that is being restored. The base cleanup that follows also
        -- unregisters the load listeners, so the discovery flag resets here.
        cancelAllRetries()
        watching = false
        windowState = {}
        if app.Ownership then
            for _, adapter in ipairs(ADAPTERS) do app.Ownership:Clear("systemWindows." .. adapter.id) end
        end
        for id, entry in pairs(self.entries or {}) do
            app.Queue:Run("systemWindows/" .. id .. "/restore", function()
                app:Call("systemWindows/" .. id .. "/restore", entry.adapter.restore, entry)
                entry.applied = false
                entry.status = nil
            end)
        end
    end,
})

-- Diagnostics: one line per window with the outcome of its last attempt, so a
-- window that failed or was handed over names its real reason instead of
-- hiding behind the component's own "running" state.
function module:Describe()
    if not self.running then return nil end
    local parts = {}
    for _, adapter in ipairs(ADAPTERS) do
        local entry = self.entries and self.entries[adapter.id]
        -- A refused window names its reason; an applied or handed-over one
        -- names the outcome; one that never arrived says so.
        local state = windowState[adapter.id] or "idle"
        if entry and entry.status == "failed" and entry.failure then
            state = "failed/" .. entry.failure
        end
        parts[#parts + 1] = adapter.id .. "=" .. state
    end
    return "systemWindows: " .. table.concat(parts, " ")
end

