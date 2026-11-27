local _, app = ...
local Store = { schema = 1 }
app.Store = Store
Store.defaults = {
    -- `opacity` is the legacy single value still used by compatibility panels.
    -- windowOpacity/hudOpacity/chatOpacity/chatActiveOpacity are the semantic
    -- roles added in 0.15.0: a window, a HUD support and an idle/active chat
    -- backdrop no longer share one number.
    appearance = { scale = 1, opacity = 0.92, windowOpacity = 0.92, hudOpacity = 0.80,
        chatOpacity = 0.82, chatActiveOpacity = 0.90, motion = true, reduceMotion = false,
        accent = "pearl", tooltipQuality = true,
        -- Off by default: the client's cooldown viewers are pooled containers
        -- that re-lay out their own buttons, and rewriting a pooled button's
        -- anchor can leave the two layouts fighting. The stable path moves the
        -- viewer frame; the slot grid is an explicit opt-in.
        perIconSlots = false },
    -- `topPerformance` is off by default: the bottom strip already owns the FPS
    -- and latency reading, and one readout is the Pearl default (010 phase 08).
    -- An explicit profile keeps its saved value.
    modules = { launcher = true, minimap = true, questTracker = true, questList = false, dataStrip = true, experience = true, topPerformance = false, chat = true, chatTabs = true, chatView = true, tooltip = true, inventory = true, unitFrames = true, partyFrames = true, nameplates = true, actionBars = true },
    ui = { questFilter = "all", questFolds = { groups = {}, quests = {} }, windowScale = 1,
        actionBarScales = { 1, 1, 1 },
        -- 018 Step 1: per-bar hover policy. Absent means independent hover
        -- ("only the bar under the pointer wakes"); `always` keeps a bar lit.
        actionBarHover = {},
        -- 018 Step 2: the two client tool hosts. "collect" hides the Blizzard
        -- bar behind the shared tool entry; "client" follows the client. The
        -- field run confirmed both hosts hide and come back correctly (bag
        -- slots, micro menu, queue eye, edit mode), so the new screen's
        -- composition is the default. Each host records its own original
        -- visibility and is handed back when a write is refused.
        nativeTools = { bagsBar = "collect", microMenu = "collect" },
        -- 018 follow-up: per-part switches for the owned unit frames. `bars` is
        -- never switched off (a health bar is the frame), the other three are.
        unitParts = { cast = true, auras = true, marks = true },
        clickCast = {}, auraFilter = "all", takeoverUnitFrames = true,
        -- One clock by default. The bottom strip owns it; the minimap panel is
        -- the alternative, and the choice persists per profile. The full strip
        -- is the visual target; compact stays a deliberate opt-in.
        clock = "strip", stripCompact = false,
        -- 012 phase 04/05: LumaUI's own nameplate layer is a real renderer and
        -- is opt-in until the live client confirms it draws over every plate.
        -- The reversible native repaint above stays the default.
        -- 012 phase 04: the own 116 x 8 plate layer is the shipped look. The
        -- native plate stays the click/position/aura host; `plateCast` remains
        -- opt-in because that row is still awaiting in-game validation.
        plateOwned = true, plateCast = false,
        -- 013 phase 02: restricted health goes straight into the own StatusBar
        -- (`plateDirect`), and the client's matching native parts are handed
        -- over while the own layer draws (`plateNative` = "hide"). "keep" leaves
        -- every native part visible under the own layer and is the diagnostic
        -- fallback until each hand-over has live evidence.
        plateDirect = true, plateNative = "hide",
        -- 012 phase 08: own rune row and player cast bar. The client's runes and
        -- cast bar keep drawing until the own path is explicitly enabled.
        resourceRunes = "native", resourceFragments = "native", resourceStyle = "line", playerCastOwned = false, containerCollapsed = {}, pinnedCurrencies = {},
        -- 012 phase 10/11: own secure action bars. Off by default; the native
        -- bars keep keys, paging and vehicle handling until the own path is
        -- validated in game.
        ownedBars = { enabled = false, bars = {} },
        -- 016 phase 07: per-bar layout overrides for the client's own bars
        -- (button count, rows, size, gap, visibility), applied and restored out
        -- of combat. Empty means "the client's own layout", which is the default.
        actionBarLayout = {},
        groupFrames = { raid = { width = 0, height = 0, gap = 0 } },
        -- Layout-level native switches for the group frames. Party keeps its
        -- current default; raid stays off until its own validation exists.
        partyTakeover = true, raidTakeover = false,
        -- 012 phase 16: saved size of the main chat window. Zero means "use the
        -- client's own size"; Normalize only accepts the documented range.
        chatWidth = 0, chatHeight = 0,
        -- 012 phase 06: own cooldown groups. Enabled but empty means nothing is
        -- drawn; a group only appears after an explicit import or `/luma cds
        -- add`, so the default screen keeps the client's own viewers.
        -- 014: the own groups are the display and follow the client's Cooldown
        -- Manager; an empty profile therefore starts with them on.
        cooldownGroups = { owned = true, hideBuffViewers = true, groups = {} },
        -- 014 phase 01: route the client's bag entry points (bag key, bag bar,
        -- "open all bags" from the bank/mailbox/merchant) and an open bank to
        -- the LumaUI windows. Off by default: the native containers keep their
        -- bag bar, equipment slots and profession tabs, and this replacement is
        -- not equivalent yet.
        containerTakeover = false,
        -- 015 phase 06: draw chat in LumaUI's own message area. Off until the
        -- client acceptance for the window passes (default push is phase 14).
        chatTakeover = false, meterOfficial = false, questBelowMap = false, stripAvoidRight = false, unitNarrowAvoid = false },
    positions = {},
    -- 018 Step 3: which default composition a profile was built for. A profile
    -- without the field predates this screen; Normalize fills it in for any
    -- profile that is created now, so "already on the new screen" is explicit
    -- instead of guessed from two equal coordinate values.
    screenVersion = 2,
}

local function clone(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, child in pairs(value) do result[key] = clone(child) end
    return result
end
Store.Clone = clone

local function finite(value)
    return type(value) == "number" and value == value and value > -math.huge and value < math.huge
end

local function bounded(value, fallback, low, high)
    if not finite(value) then return fallback end
    return math.max(low, math.min(high, value))
end

function Store:ValidName(name)
    if type(name) ~= "string" then return false end
    local chars = 0
    for _ in name:gmatch("[^\128-\191]") do chars = chars + 1 end
    return chars >= 1 and chars <= 40 and name:find("%S") ~= nil and not name:find("[%c|]")
end

function Store:Normalize(input)
    local result = clone(self.defaults)
    if type(input) ~= "table" then return result end
    local look = type(input.appearance) == "table" and input.appearance or {}
    result.appearance.scale = bounded(look.scale, 1, 0.7, 1.5)
    result.appearance.opacity = bounded(look.opacity, 0.92, 0.45, 1)
    -- Semantic surface opacities. A profile written before these fields existed
    -- receives the defaults instead of being migrated to the legacy value, so
    -- nothing turns transparent or opaque on the first login.
    result.appearance.windowOpacity = bounded(look.windowOpacity, 0.92, 0.45, 1)
    result.appearance.hudOpacity = bounded(look.hudOpacity, 0.80, 0.15, 1)
    result.appearance.chatOpacity = bounded(look.chatOpacity, 0.82, 0, 1)
    result.appearance.chatActiveOpacity = bounded(look.chatActiveOpacity, 0.90, 0.2, 1)
    if type(look.motion) == "boolean" then result.appearance.motion = look.motion end
    -- Reduced motion settles every transition at once without a reload; it is
    -- stored next to the motion switch so both share one validated profile.
    if type(look.reduceMotion) == "boolean" then result.appearance.reduceMotion = look.reduceMotion end
    if type(look.tooltipQuality) == "boolean" then result.appearance.tooltipQuality = look.tooltipQuality end
    -- Opt-in per-icon slot grid for the cooldown viewers. The shipped default is
    -- off; a profile that never chose keeps the stable whole-viewer placement.
    if type(look.perIconSlots) == "boolean" then result.appearance.perIconSlots = look.perIconSlots end
    if look.accent == "ember" or look.accent == "ocean" or look.accent == "pearl" then
        result.appearance.accent = look.accent
    end
    local ui = type(input.ui) == "table" and input.ui or {}
    if ui.questFilter == "tracked" or ui.questFilter == "zone" or ui.questFilter == "all" then
        result.ui.questFilter = ui.questFilter
    end
    -- Aura row filter: everything, or only debuffs the player can dispel.
    if ui.auraFilter == "dispel" then result.ui.auraFilter = "dispel" end
    -- Native unit-frame takeover defaults on for the Pearl layout; an explicit
    -- false still keeps the game's frames on screen.
    if type(ui.takeoverUnitFrames) == "boolean" then
        result.ui.takeoverUnitFrames = ui.takeoverUnitFrames
    end
    -- One clock. "strip" (default), "minimap" or "off"; anything else keeps
    -- the default, so a damaged value can never hide the time entirely.
    if ui.clock == "minimap" or ui.clock == "off" then result.ui.clock = ui.clock end
    if type(ui.stripCompact) == "boolean" then result.ui.stripCompact = ui.stripCompact end
    if type(ui.plateOwned) == "boolean" then result.ui.plateOwned = ui.plateOwned end
    if type(ui.plateCast) == "boolean" then result.ui.plateCast = ui.plateCast end
    if type(ui.plateDirect) == "boolean" then result.ui.plateDirect = ui.plateDirect end
    if ui.plateNative == "keep" then result.ui.plateNative = "keep" end
    if ui.resourceRunes == "owned" then result.ui.resourceRunes = "owned" end
    if ui.resourceFragments == "owned" then result.ui.resourceFragments = "owned" end
    result.ui.resourceStyle = ui.resourceStyle == "arc" and "arc" or "line"
    -- Container view: collapsed section names (known sections only) and up to
    -- four pinned currency ids; anything else is dropped.
    local collapsed, pinned = {}, {}
    if type(ui.containerCollapsed) == "table" then
        for _, name in ipairs({ "quest", "equip", "consumable", "mat", "other" }) do
            if ui.containerCollapsed[name] == true then collapsed[name] = true end
        end
    end
    if type(ui.pinnedCurrencies) == "table" then
        for _, id in ipairs(ui.pinnedCurrencies) do
            if finite(id) and id > 0 and id == math.floor(id) and id <= 2147483647 and #pinned < 4 then
                local dup = false
                for _, other in ipairs(pinned) do if other == id then dup = true end end
                if not dup then pinned[#pinned + 1] = id end
            end
        end
    end
    result.ui.containerCollapsed, result.ui.pinnedCurrencies = collapsed, pinned
    -- Container takeover is a single switch for both windows: one profile that
    -- asked for it must not end up with the bags replaced and the bank native.
    if type(ui.containerTakeover) == "boolean" then
        result.ui.containerTakeover = ui.containerTakeover
    end
    if type(ui.chatTakeover) == "boolean" then result.ui.chatTakeover = ui.chatTakeover end
    if type(ui.meterOfficial) == "boolean" then result.ui.meterOfficial = ui.meterOfficial end
    if type(ui.questBelowMap) == "boolean" then result.ui.questBelowMap = ui.questBelowMap end
    if type(ui.stripAvoidRight) == "boolean" then result.ui.stripAvoidRight = ui.stripAvoidRight end
    if type(ui.unitNarrowAvoid) == "boolean" then result.ui.unitNarrowAvoid = ui.unitNarrowAvoid end
    if type(ui.playerCastOwned) == "boolean" then result.ui.playerCastOwned = ui.playerCastOwned end
    -- Cooldown-group shape lives in one model so the store and the renderer
    -- cannot disagree about an icon size, a cap or a spell ID.
    result.ui.cooldownGroups = app.CooldownModel:Normalize(ui.cooldownGroups)
    result.ui.ownedBars = app.BarModel:Normalize(ui.ownedBars)
    result.ui.actionBarLayout = app.BarModel:NormalizeLayout(ui.actionBarLayout)
    result.ui.actionBarHover = app.BarModel:NormalizeHover(ui.actionBarHover)
    -- The two native tool hosts accept only the two documented modes; anything
    -- else keeps the new composition's collected state.
    do
        local tools = type(ui.nativeTools) == "table" and ui.nativeTools or {}
        result.ui.nativeTools = {
            bagsBar = tools.bagsBar == "client" and "client" or "collect",
            microMenu = tools.microMenu == "client" and "client" or "collect",
        }
    end
    do
        local parts = type(ui.unitParts) == "table" and ui.unitParts or {}
        result.ui.unitParts = {
            cast = parts.cast ~= false,
            auras = parts.auras ~= false,
            marks = parts.marks ~= false,
        }
    end
    -- Raid button geometry. 0 keeps the built-in value ("follows client" in the
    -- settings); anything outside the range is dropped, never clamped silently.
    local frames = type(ui.groupFrames) == "table" and ui.groupFrames or {}
    local raid = type(frames.raid) == "table" and frames.raid or {}
    local function inRange(value, low, high)
        return finite(value) and value >= low and value <= high and math.floor(value) or 0
    end
    result.ui.groupFrames = { raid = {
        width = inRange(raid.width, 60, 140),
        height = inRange(raid.height, 20, 48),
        gap = inRange(raid.gap, 1, 16),
    } }
    if type(ui.partyTakeover) == "boolean" then result.ui.partyTakeover = ui.partyTakeover end
    if type(ui.raidTakeover) == "boolean" then result.ui.raidTakeover = ui.raidTakeover end
    result.ui.chatWidth = finite(ui.chatWidth) and ui.chatWidth >= 240 and ui.chatWidth <= 600
        and math.floor(ui.chatWidth) or 0
    result.ui.chatHeight = finite(ui.chatHeight) and ui.chatHeight >= 100 and ui.chatHeight <= 400
        and math.floor(ui.chatHeight) or 0
    -- Scale of LumaUI's own windows (the character window uses it today).
    result.ui.windowScale = bounded(ui.windowScale, 1, 0.8, 1.3)
    if type(ui.actionBarScales) == "table" then
        for index = 1, #result.ui.actionBarScales do
            result.ui.actionBarScales[index] = bounded(ui.actionBarScales[index], 1, 0.5, 1.5)
        end
    end
    -- Click-casting bindings: "modifier-button" -> spell name. Only plain
    -- strings with a known shape are kept, so a damaged save cannot inject
    -- arbitrary secure attributes.
    result.ui.clickCast = {}
    if type(ui.clickCast) == "table" then
        local count = 0
        for key, spell in pairs(ui.clickCast) do
            if count < 24 and type(key) == "string" and type(spell) == "string"
                and key:match("^[%l%-]+$") and #key <= 24 and spell ~= ""
                and #spell <= 60 and not spell:find("[%c|]") then
                result.ui.clickCast[key] = spell
                count = count + 1
            end
        end
    end
    -- Quest panel fold state: only collapsed entries are kept, with plain
    -- string keys ("g:<group name>", "q:<quest id>") and a hard entry cap so a
    -- damaged database can never grow unbounded.
    result.ui.questFolds = { groups = {}, quests = {} }
    if type(ui.questFolds) == "table" then
        for _, kind in ipairs({ "groups", "quests" }) do
            local source = ui.questFolds[kind]
            if type(source) == "table" then
                local count = 0
                for key, collapsed in pairs(source) do
                    if count < 256 and collapsed == true and type(key) == "string"
                        and #key >= 1 and #key <= 96 and not key:find("[%c]") then
                        result.ui.questFolds[kind][key] = true
                        count = count + 1
                    end
                end
            end
        end
    end
    local modules = type(input.modules) == "table" and input.modules or {}
    -- Keep switches for optional extensions even while those addons are absent.
    for id, value in pairs(modules) do
        if type(id) == "string" and id:match("^[%a][%w_]*$") and type(value) == "boolean" then result.modules[id] = value end
    end
    for id in pairs(result.modules) do
        if type(modules[id]) == "boolean" then result.modules[id] = modules[id] end
    end
    if type(input.positions) == "table" then
        for id, position in pairs(input.positions) do
            if type(id) == "string" and type(position) == "table" and finite(position.x) and finite(position.y) then
                result.positions[id] = { x = bounded(position.x, 0, -20000, 20000), y = bounded(position.y, 0, -20000, 20000),
                    anchor = app.Geometry and app.Geometry.CleanAnchor(position.anchor) or nil }
            end
        end
    end
    -- `screenVersion` records which composition a profile was built for. The
    -- flag itself is decided by `IsLegacyScreen` from the saved geometry, which
    -- is the only reliable evidence: an older build stamped the current version
    -- onto every profile it wrote, so the number cannot be trusted. A copy this
    -- build created carries an explicit `false` and keeps it.
    if type(input.legacyScreen) == "boolean" then
        result.legacyScreen = input.legacyScreen
    else
        result.legacyScreen = nil
    end
    if type(input.screenVersion) == "number" and input.screenVersion > 0 then
        result.screenVersion = math.floor(input.screenVersion)
    else
        result.screenVersion = nil
    end
    if type(input.takeoverBackup) == "table" then
        local backup = {}
        for name, record in pairs(input.takeoverBackup) do
            if type(name) == "string" and name:match("^[%a_][%w_]*%.[%a_][%w_]*$") and type(record) == "table"
                and type(record.had) == "boolean" then
                local function scalar(v) return type(v) == "boolean" or type(v) == "string" or finite(v) end
                if (record.old == nil or scalar(record.old)) and scalar(record.applied) then
                    backup[name] = { had = record.had, old = record.old, applied = record.applied }
                end
            end
        end
        if next(backup) then result.takeoverBackup = backup end
    end
    return result
end

-- { section, key, value } entries; see the 015 migration in Open.
Store.TAKEOVER_015 = {}

function Store:ApplyTakeover(profile)
    if type(profile) ~= "table" then return end
    local backup = type(profile.takeoverBackup) == "table" and profile.takeoverBackup or {}
    for _, entry in ipairs(self.TAKEOVER_015) do
        local section, key, value = entry[1], entry[2], entry[3]
        if type(profile[section]) ~= "table" then profile[section] = {} end
        local name = section .. "." .. key
        if backup[name] == nil then
            local old = profile[section][key]
            backup[name] = { had = old ~= nil, old = old, applied = value }
        end
        profile[section][key] = value
    end
    if next(backup) then profile.takeoverBackup = backup end
end

-- Puts back the pre-takeover value of every flip the player has not changed
-- since; a later manual edit is kept. Returns how many entries were restored.
function Store:RestoreTakeover(profile)
    profile = profile or self:Profile()
    local backup = type(profile.takeoverBackup) == "table" and profile.takeoverBackup or nil
    if not backup then return 0 end
    local restored = 0
    for name, record in pairs(backup) do
        local section, key = name:match("^(.-)%.(.+)$")
        local bucket = section and profile[section]
        if type(bucket) == "table" and bucket[key] == record.applied then
            bucket[key] = record.had and record.old or nil
            restored = restored + 1
        end
    end
    profile.takeoverBackup = nil
    return restored
end

function Store:Open(character)
    local saved = _G.LumaUIDB
    if type(saved) == "table" and type(saved.schema) == "number" and saved.schema > self.schema then
        self.readonly = true
        self.money = {}
        self.data = { schema = self.schema, profiles = { Default = clone(self.defaults) }, characters = {} }
    else
        self.readonly = false
        saved = type(saved) == "table" and saved or {}
        local profiles = {}
        if type(saved.profiles) == "table" then
            for name, profile in pairs(saved.profiles) do
                if self:ValidName(name) then profiles[name] = self:Normalize(profile) end
            end
        end
        if not next(profiles) then profiles.Default = clone(self.defaults) end
        -- Pearl visual batch: the custom quest panel leaves the default screen
        -- and the cold ocean accent moves to the target amber-gold once. Later
        -- user choices are not overridden again.
        local migrations = {
            pearlBatch = type(saved.migrations) == "table" and saved.migrations.pearlBatch == true,
            questListDefault = true,
        }
        if not migrations.pearlBatch then
            for _, profile in pairs(profiles) do
                profile.modules.questList = false
                local look = profile.appearance
                -- Move only untouched legacy defaults; a deliberate custom
                -- opacity survives the batch.
                if look.accent == "ocean" then look.accent = "pearl" end
                if look.opacity == 0.9 then look.opacity = 0.92 end
                if look.windowOpacity == 0.96 then look.windowOpacity = 0.92 end
                if look.hudOpacity == 0.62 then look.hudOpacity = 0.80 end
                if look.chatOpacity == 0.25 then look.chatOpacity = 0.82 end
                if look.chatActiveOpacity == 0.75 then look.chatActiveOpacity = 0.90 end
                if profile.ui and profile.ui.stripCompact == true then profile.ui.stripCompact = false end
            end
            migrations.pearlBatch = true
        end
        -- The Pearl screen is the default screen: the three visual unit
        -- replacements come on together, and the unit frames take over the
        -- native ones so the player never sees two copies. The switch stays
        -- reversible per profile.
        migrations.visualModules = type(saved.migrations) == "table"
            and saved.migrations.visualModules == true
        if not migrations.visualModules then
            for _, profile in pairs(profiles) do
                profile.modules.unitFrames = true
                profile.modules.partyFrames = true
                profile.modules.nameplates = true
                profile.modules.actionBars = true
                profile.ui.takeoverUnitFrames = true
            end
            migrations.visualModules = true
        end
        migrations.actionBars = type(saved.migrations) == "table"
            and saved.migrations.actionBars == true
        if not migrations.actionBars then
            for _, profile in pairs(profiles) do
                profile.modules.actionBars = true
            end
            migrations.actionBars = true
        end
        -- 012 second pass: the own nameplate layer became the shipped default.
        -- Profiles created while the old default was off were already
        -- normalized with an explicit `false`, so changing the default alone
        -- never reaches them. Flip every profile once; an explicit choice made
        -- after this migration is preserved because the flag never runs again.
        migrations.plateOwnedDefault = type(saved.migrations) == "table"
            and saved.migrations.plateOwnedDefault == true
        if not migrations.plateOwnedDefault then
            for _, profile in pairs(profiles) do
                profile.ui.plateOwned = true
            end
            migrations.plateOwnedDefault = true
        end
        -- 014: the own cooldown groups became the shipped display, and each group
        -- follows the client's Cooldown Manager by default. Profiles written
        -- while the default was "off, empty, manual" carry explicit `false`
        -- values, so the new default alone never reaches them: enable once, and
        -- leave every later choice alone.
        migrations.cooldownGroupsDefault = type(saved.migrations) == "table"
            and saved.migrations.cooldownGroupsDefault == true
        if not migrations.cooldownGroupsDefault then
            for _, profile in pairs(profiles) do
                if type(profile.ui) ~= "table" then profile.ui = {} end
                local ui = profile.ui
                local groups = ui.cooldownGroups
                if type(groups) ~= "table" then
                    ui.cooldownGroups = { owned = true, hideBuffViewers = true, groups = {} }
                else
                    groups.owned = true
                    groups.hideBuffViewers = true
                    for _, id in ipairs({ "essential", "utility", "buffs" }) do
                        local group = type(groups.groups) == "table" and groups.groups[id]
                        if type(group) == "table" then group.auto = true end
                    end
                end
            end
            migrations.cooldownGroupsDefault = true
        end
        -- 018: every group follows the player's Cooldown Manager again. A profile
        -- that ran `/luma cds import` once was flipped to a manual copy by an
        -- older build, so it kept drawing that frozen list even after the player
        -- edited the CDM. The stored order is kept as the fallback for a build
        -- whose list cannot be read, and an explicit manual edit after this
        -- migration still turns `auto` off again.
        migrations.cooldownAuto018 = type(saved.migrations) == "table"
            and saved.migrations.cooldownAuto018 == true
        if not migrations.cooldownAuto018 then
            for _, profile in pairs(profiles) do
                local ui = type(profile.ui) == "table" and profile.ui or nil
                local groups = ui and type(ui.cooldownGroups) == "table" and ui.cooldownGroups.groups
                if type(groups) == "table" then
                    for _, id in ipairs({ "essential", "utility", "buffs" }) do
                        if type(groups[id]) == "table" then groups[id].auto = true end
                    end
                end
            end
            migrations.cooldownAuto018 = true
        end
        -- 015: one-time takeover switches. Only parts that reached equivalence in
        -- the client belong in TAKEOVER_015 (empty until in-game evidence exists).
        -- Each flip keeps the old value, telling "field absent" from an explicit
        -- value, so RestoreTakeover can undo it without touching later edits.
        migrations.takeover015 = type(saved.migrations) == "table"
            and saved.migrations.takeover015 == true
        if not migrations.takeover015 then
            for _, profile in pairs(profiles) do self:ApplyTakeover(profile) end
            migrations.takeover015 = true
        end
        -- The adopted-screen record survives a reload, so a player who restarts
        -- can still return to the profile their copy came from.
        local screenReturn
        if type(saved.screenReturn) == "table" and type(saved.screenReturn.from) == "string"
            and type(saved.screenReturn.to) == "string" then
            screenReturn = { from = saved.screenReturn.from, to = saved.screenReturn.to }
        end
        -- A profile that predates `screenVersion` and already carries explicit
        -- geometry is the one the new screen would replace. Mark it once here,
        -- before any UI reads it, and never flip the flag back: the player's
        -- decision to keep the old layout is a normal saved value.
        for _, profile in pairs(profiles) do
            if profile.legacyScreen and not next(profile.positions) then
                -- Nothing saved yet: this profile is already on the new screen.
                profile.legacyScreen = nil
                profile.screenVersion = self.SCREEN_VERSION
            end
        end
        -- 018: the two native tool hosts move to the collected default. A profile
        -- written while the default was "follow client" carries that value
        -- explicitly, so changing the default alone never reaches it. The player
        -- can still set either host back to "client" and that choice survives.
        migrations.nativeToolsCollect = type(saved.migrations) == "table"
            and saved.migrations.nativeToolsCollect == true
        if not migrations.nativeToolsCollect then
            for _, profile in pairs(profiles) do
                local ui = type(profile.ui) == "table" and profile.ui or nil
                if ui and type(ui.nativeTools) == "table" then
                    ui.nativeTools.bagsBar = "collect"
                    ui.nativeTools.microMenu = "collect"
                end
            end
            migrations.nativeToolsCollect = true
        end
        -- 018: an earlier build of this same iteration wrote `legacyScreen =
        -- false` onto every profile on save, including profiles that still carry
        -- the previous composition's placements. That value is not evidence, so
        -- it is cleared once here and `IsLegacyScreen` decides from the saved
        -- geometry instead. A copy created after this migration keeps its `false`.
        migrations.screenLegacy018 = type(saved.migrations) == "table"
            and saved.migrations.screenLegacy018 == true
        if not migrations.screenLegacy018 then
            for _, profile in pairs(profiles) do
                if profile.legacyScreen == false then profile.legacyScreen = nil end
            end
            migrations.screenLegacy018 = true
        end
        self.data = { schema = self.schema, profiles = profiles, characters = {}, migrations = migrations }
        self.data.screenReturn = screenReturn
        if type(saved.characters) == "table" then
            for name, selected in pairs(saved.characters) do
                if type(name) == "string" and type(selected) == "string" and profiles[selected] then self.data.characters[name] = selected end
            end
        end
        -- Account-wide money ledger: values are recorded from this account's own
        -- characters only, so the tooltip never needs a restricted API.
        local money = {}
        if type(saved.money) == "table" then
            for key, amount in pairs(saved.money) do
                if type(key) == "string" and self:ValidName(key) and finite(amount) and amount >= 0 then
                    money[key] = math.floor(math.min(amount, 1000000000000))
                end
            end
        end
        self.money = money
        self.data.money = money
        if type(saved.ledger) == "table" then self.data.ledger = saved.ledger end
        -- Written reports survive a restart: `/luma cds file` is meant to be read
        -- from the file after a reload, so dropping them on login would defeat
        -- the whole point. Only plain text lines are kept, and a slot that is no
        -- longer a table is discarded rather than copied blindly.
        if type(saved.reports) == "table" then
            local reports = {}
            for key, entry in pairs(saved.reports) do
                if type(key) == "string" and key:match("^[%a][%w_]*$") and type(entry) == "table"
                    and type(entry.lines) == "table" then
                    local lines = {}
                    for index, line in ipairs(entry.lines) do
                        if type(line) == "string" then lines[index] = line end
                    end
                    reports[key] = {
                        version = type(entry.version) == "string" and entry.version or nil,
                        title = type(entry.title) == "string" and entry.title:sub(1, 64) or key,
                        lines = lines,
                    }
                end
            end
            self.data.reports = next(reports) and reports or nil
        end
        if type(saved.diagnostics) == "table" and type(saved.diagnostics.lines) == "table" then
            self.data.diagnostics = saved.diagnostics
        end
        -- The adopted-screen record survives a reload, so a player who restarts
        -- can still return to the profile their copy came from.
        if type(saved.screenReturn) == "table" and type(saved.screenReturn.from) == "string"
            and type(saved.screenReturn.to) == "string" then
            self.data.screenReturn = { from = saved.screenReturn.from, to = saved.screenReturn.to }
        end
        _G.LumaUIDB = self.data
    end
    self.character = character
    local current = self.data.characters[character]
    if not current or not self.data.profiles[current] then
        current = self.data.profiles.Default and "Default" or self:Names()[1]
        self.data.characters[character] = current
    end
    self.current = current
end

function Store:Profile() return self.data.profiles[self.current] end

function Store:Names()
    local list = {}
    for name in pairs(self.data.profiles) do list[#list + 1] = name end
    table.sort(list)
    return list
end

-- 018 Step 3: what a profile still owns from before this composition. A profile
-- written by an older iteration carries its own explicit coordinates, so the new
-- defaults never reach it; identifying it here is what lets the player try the
-- new screen without losing the old one.
--
-- Only the keys this composition actually owns are reported, and only when the
-- profile says something explicit for them. A profile with no saved geometry is
-- already on the new screen and needs no copy.
Store.SCREEN_VERSION = 2
Store.LEGACY_KEYS = {
    "actionBar1", "actionBar2", "actionBar3",
    "cdGroup_essential", "cdGroup_utility", "cdGroup_buffs",
    "unit_player", "unit_target", "unit_focus", "unit_pet", "unit_targettarget",
    "party", "questList", "chat", "chatPlate", "utilityCorner", "damageMeterArea",
    "bottomBar", "topInfo", "playerCast", "playerResource", "minimap",
}

-- The composition a profile was built for. `IsLegacyScreen` is the authority: a
-- profile that still owns placements this screen replaced reports the old
-- version even when a save stamped the new number onto it.
function Store:ScreenVersion()
    if self:IsLegacyScreen() then return 1 end
    local profile = self:Profile()
    local value = profile and profile.screenVersion
    if type(value) == "number" and value > 0 then return value end
    return self.SCREEN_VERSION
end

-- The copy the player adopted for this screen, and the profile it came from.
-- `Store:ReturnToSource()` uses it for the one-click way back; a stale entry
-- (the source renamed or deleted) is dropped instead of leaving a dead button.
function Store:ScreenReturn()
    local record = self.data and self.data.screenReturn
    if type(record) ~= "table" or type(record.from) ~= "string" then return nil end
    if not self.data.profiles[record.from] then
        self.data.screenReturn = nil
        return nil
    end
    return record
end

function Store:ReturnToSource()
    local record = self:ScreenReturn()
    if not record then return false end
    if self.readonly then return false, app.L.readonly end
    local ok, problem = self:Select(record.from)
    if ok then self.data.screenReturn = nil end
    return ok, problem
end

-- True while this profile still carries the composition it was written with.
-- `screenVersion` alone cannot answer that: an older build stamped the current
-- number onto every profile on each write, so a profile saved by it reads as
-- "current" while its placements are still the old ones. The stored flag and the
-- saved geometry are the real evidence, and a profile with no placements at all
-- is already on this screen.
function Store:IsLegacyScreen()
    local profile = self:Profile()
    if not profile then return false end
    -- A copy this composition created says so explicitly: it keeps an explicit
    -- false, which outranks the saved geometry it inherited.
    if profile.legacyScreen == false then return false end
    if profile.legacyScreen == true then return true end
    return next(profile.positions or {}) ~= nil
end

-- The saved keys of an older profile that this composition would replace. Used
-- by the overview preview and by `TryNewScreen`; an empty list means the profile
-- is already on this screen.
function Store:LegacyKeys()
    local profile = self:Profile()
    if not profile then return {} end
    if not self:IsLegacyScreen() then return {} end
    local list, seen = {}, {}
    local function add(id)
        if seen[id] then return end
        seen[id] = true
        list[#list + 1] = id
    end
    for _, id in ipairs(self.LEGACY_KEYS) do
        local position = profile.positions[id]
        if type(position) == "table" then add(id) end
    end
    for id in pairs(profile.positions) do
        if type(id) == "string" and not seen[id] then
            -- A key outside the catalog is still the player's own placement;
            -- it is listed so the preview never claims fewer changes than it
            -- makes.
            if id:match("^actionBar[1-3]$") or id:match("^cdGroup_") or id:match("^unit_") then add(id) end
        end
    end
    return list
end

-- A profile name that cannot collide with an existing one: "Pearl", "Pearl 2"…
function Store:CopyName(base)
    base = type(base) == "string" and base:match("^%s*(.-)%s*$") or "Pearl"
    if not self:ValidName(base) then base = "Pearl" end
    if not self.data.profiles[base] then return base end
    for index = 2, 99 do
        local name = string.format("%s %d", base, index)
        if self:ValidName(name) and not self.data.profiles[name] then return name end
    end
    return nil
end

-- Creates the copy this composition needs and selects it. Every other profile
-- value (actions, keybinds, abilities, unrelated windows, the wallet) travels
-- with the copy; only the keys this screen replaces are dropped, and the old
-- profile stays untouched so "return to it" is a plain Select.
--
-- Returns the copy name, or nil plus the reason it was not created.
function Store:TryNewScreen(base)
    if self.readonly then return nil, app.L.readonly end
    local source = self:Profile()
    if not source then return nil, app.L.unknownProfile end
    local name = self:CopyName(base or source.name or "Pearl")
    if not name then return nil, app.L.invalidName end
    local copy = clone(source)
    copy.screenVersion = self.SCREEN_VERSION
    copy.legacyScreen = false
    for _, id in ipairs(self:LegacyKeys()) do copy.positions[id] = nil end
    -- A fresh screen owns no preset snapshot and no per-screen drafts.
    copy.takeoverBackup = nil
    self.data.profiles[name] = self:Normalize(copy)
    self.data.profiles[name].screenVersion = self.SCREEN_VERSION
    self.data.profiles[name].legacyScreen = false
    -- Remember where the copy came from, so the overview can offer a one-click
    -- way back; the record is cleared by ReturnToSource.
    self.data.screenReturn = { from = self.current, to = name }
    local ok, problem = self:Select(name)
    if not ok then
        self.data.profiles[name] = nil
        self.data.screenReturn = nil
        return nil, problem
    end
    -- The copy starts on this screen's own composition: the preset writes the
    -- entries it lists, so the player gets the new layout immediately instead of
    -- an empty position table.
    if app.Layout and type(app.Layout.ApplyPreset) == "function" then
        local preset = self.SCREEN_PRESET
        if type(preset) == "function" then preset = preset() end
        if type(preset) == "string" then
            for _, available in ipairs(app.Layout:Presets()) do
                if available.id == preset then
                    app.Layout:ApplyPreset(preset)
                    -- The preset snapshot belongs to the source profile; the
                    -- copy is the new baseline and must not "undo" to it.
                    app.Layout:ClearPresetSnapshot()
                    break
                end
            end
        end
    end
    return name
end

-- Which layout preset a copy of the current screen adopts.
Store.SCREEN_PRESET = function() return "pearlCity" end

function Store:Changed()
    app:Publish("PROFILE_CHANGED", self.current)
end

function Store:Set(section, key, value)
    if self.readonly then return false, app.L.readonly end
    if section ~= "appearance" and section ~= "modules" and section ~= "ui" then return false end
    local profile = clone(self:Profile())
    if profile[section][key] == nil then return false end
    profile[section][key] = value
    self.data.profiles[self.current] = self:Normalize(profile)
    self:Changed()
    return true
end

-- A plain position replaces any anchor: moving a component by hand detaches it.
-- `anchor` (optional) saves the follow rule with the last resolved centre, so a
-- missing target falls back to where the component last was.
function Store:SetPosition(id, x, y, anchor)
    if self.readonly or not finite(x) or not finite(y) then return false end
    self:Profile().positions[id] = { x = bounded(x, 0, -20000, 20000), y = bounded(y, 0, -20000, 20000),
        anchor = app.Geometry.CleanAnchor(anchor) }
    return true
end

-- Removes only the follow rule; the current landing point stays.
function Store:ClearAnchor(id)
    if self.readonly then return false end
    local position = self:Profile().positions[id]
    if position then position.anchor = nil end
    return true
end

-- Replaces the whole position table. Used by the layout preset undo: the
-- snapshot is restored as a set, so keys the preset added disappear and keys it
-- did not touch keep their values.
function Store:SetPositions(positions)
    if self.readonly then return false, app.L.readonly end
    if type(positions) ~= "table" then return false end
    local profile = self:Profile()
    profile.positions = {}
    for id, position in pairs(positions) do
        if type(id) == "string" and type(position) == "table"
            and finite(position.x) and finite(position.y) then
            profile.positions[id] = { x = bounded(position.x, 0, -20000, 20000),
                y = bounded(position.y, 0, -20000, 20000), anchor = app.Geometry.CleanAnchor(position.anchor) }
        end
    end
    return true
end

function Store:SetMoney(character, amount)    if self.readonly or type(character) ~= "string" then return false end
    amount = finite(amount) and math.floor(amount) or nil
    if not amount or amount < 0 then return false end
    amount = math.min(amount, 1000000000000)
    self.money[character] = amount
    if self.data.money ~= self.money then self.data.money = self.money end
    return true
end

function Store:Create(name, copyCurrent)
    if self.readonly then return false, app.L.readonly end
    name = type(name) == "string" and name:match("^%s*(.-)%s*$") or name
    if not self:ValidName(name) then return false, app.L.invalidName end
    if self.data.profiles[name] then return false, app.L.exists end
    self.data.profiles[name] = copyCurrent and clone(self:Profile()) or clone(self.defaults)
    -- An explicit new profile is on the current screen by construction, even
    -- when it was copied from one that predates it.
    self.data.profiles[name].screenVersion = self.SCREEN_VERSION
    self.data.profiles[name].legacyScreen = false
    return self:Select(name)
end

function Store:Select(name)
    if self.readonly then return false, app.L.readonly end
    if not self.data.profiles[name] then return false, app.L.unknownProfile end
    self.current, self.data.characters[self.character] = name, name
    self:Changed()
    return true
end

function Store:Delete(name)
    if self.readonly then return false, app.L.readonly end
    if not self.data.profiles[name] then return false, app.L.unknownProfile end
    if #self:Names() == 1 then return false, app.L.lastProfile end
    self.data.profiles[name] = nil
    local fallback = self:Names()[1]
    for character, current in pairs(self.data.characters) do
        if current == name then self.data.characters[character] = fallback end
    end
    self.current = self.data.characters[self.character]
    self:Changed()
    return true
end

function Store:Reset(layoutOnly)
    if self.readonly then return false, app.L.readonly end
    if layoutOnly then self:Profile().positions = {} else self.data.profiles[self.current] = clone(self.defaults) end
    self:Changed()
    return true
end
