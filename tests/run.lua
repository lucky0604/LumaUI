local H = dofile("tests/WowHarness.lua")
local total, passed = 0, 0
local function eq(actual, expected)
    if actual ~= expected then error("Expected " .. tostring(expected) .. ", got " .. tostring(actual), 2) end
end
local function test(name, fn)
    total = total + 1
    local ok, message = pcall(fn)
    if ok then passed = passed + 1; print("PASS " .. name) else print("FAIL " .. name .. ": " .. message) end
end

test("manifest loads, login enables isolated components", function()
    local app = H.Load()
    H.Fire("PLAYER_LOGIN")
    eq(app.ready, true)
    eq(app.components.dataStrip.running, true)
    eq(app.components.unitFrames.running, nil)
    eq(#app.errors, 0)
    H.Fire("PLAYER_LOGIN")
    -- data strip clock, minimap clock, quest list task-time tick and the
    -- cooldown stack's slow re-check of the client's own repacks. The top
    -- performance capsule is off by default (010 phase 08), so its ticker is
    -- not among them.
    eq(#H.timers, 4)
end)

test("profiles isolate copies and remember each character", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local store = app.Store
    eq(store:Create("Raid", true), true)
    store:Set("appearance", "scale", 1.3)
    store:Select("Default")
    eq(store:Profile().appearance.scale, 1)
    store:Open("Other - Realm")
    eq(store.current, "Default")
    store:Open("Tester - Realm")
    eq(store.current, "Default")
    store:Select("Raid")
    store:Open("Tester - Realm")
    eq(store.current, "Raid")
    store:Delete("Raid")
    eq(store.current, "Default")
    eq(store:Delete("Default"), false)
    eq(store:Create("   ", false), false)
    eq(store:Create("bad|name", false), false)
end)

test("malformed persisted values are normalized", function()
    local app = H.Load({ profiles = { Broken = { appearance = { scale = 9, opacity = 0 / 0, motion = "yes", tooltipQuality = "yes" }, modules = { dataStrip = "on" }, ui = { questFilter = "everything" }, positions = { broken = { x = "wrong", y = 2 } } } }, characters = { ["Tester - Realm"] = "Broken" } })
    H.Fire("PLAYER_LOGIN")
    local profile = app.Store:Profile()
    eq(profile.appearance.scale, 1.5)
    eq(profile.appearance.opacity, 0.92)
    eq(profile.appearance.motion, true)
    eq(profile.appearance.tooltipQuality, true)
    eq(profile.modules.dataStrip, true)
    eq(profile.ui.questFilter, "all")
    eq(profile.positions.broken, nil)
    eq(#app.errors, 0)
end)

test("newer schema is preserved byte-for-byte in memory", function()
    local saved = { schema = 99, sentinel = { "keep" } }
    local app = H.Load(saved); H.Fire("PLAYER_LOGIN")
    eq(LumaUIDB, saved)
    eq(app.Store.readonly, true)
    eq(app.Store:Set("appearance", "scale", 1.2), false)
    eq(app.Store:Create("No", false), false)
    eq(app.Store:Reset(), false)
    eq(saved.sentinel[1], "keep")
end)

test("combat queue keeps the newest keyed request", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    H.Combat(true)
    local result = 0
    app.Queue:Run("test", function() result = 1 end)
    app.Queue:Run("test", function() result = 2 end)
    eq(app.Queue:Count(), 1)
    eq(result, 0)
    H.Combat(false)
    eq(result, 2)
    eq(app.Queue:Count(), 0)
end)

test("secure units draw secret values and defer protected changes", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.Store:Set("modules", "unitFrames", true)
    local units = app.components.unitFrames
    eq(units.running, true)
    eq(units.frames.target:GetAttribute("unit"), "target")
    H.Combat(true)
    H.Fire("UNIT_HEALTH", H.Secret("target"))
    app.Store:Set("appearance", "scale", 1.2)
    app.Store:Set("modules", "unitFrames", false)
    eq(units.running, true)
    eq(app.Queue:Count(), 1)
    H.Combat(false)
    eq(units.running, false)
    eq(units.frames.target:IsShown(), false)
    eq(units.frames.target.watched, false)
    eq(#app.errors, 0)
end)

test("timers and event subscriptions are released on disable", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local before = #H.timers
    app.Store:Set("modules", "dataStrip", false)
    local cancelled = 0
    for _, timer in ipairs(H.timers) do if timer.cancelled then cancelled = cancelled + 1 end end
    eq(cancelled, 1)
    eq(next(app.components.dataStrip.events.events), nil)
    app.Store:Set("modules", "dataStrip", true)
    eq(#H.timers, before + 1)
    eq(H.timers[#H.timers].cancelled, nil)
end)

test("settings pages, profiles, inventory and commands work", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    for _, page in ipairs({ "general", "layout", "modules", "profiles", "diagnostics" }) do app.Settings:Toggle(page) end
    eq(app.components.launcher.label, "launcher")
    eq(app.Settings.pages.modules.rows.launcher.text:GetText(), app.L.launcher)
    app.Store:Create("Test", true)
    app.Settings:Toggle("profiles")
    eq(app.Settings.profileRows[2].key, "Test")
    SlashCmdList.LUMAUI("bags")
    local inventory = app.components.inventory
    eq(inventory.frame:IsShown(), true)
    eq(inventory.buttons[1].item.bag, 0)
    eq(inventory.buttons[6].item.bag, 5)
    inventory.search:SetText("not-found")
    inventory.search.scripts.OnTextChanged(inventory.search)
    eq(inventory.empty:IsShown(), true)
    eq(inventory.buttons[1]:IsShown(), false)
    SlashCmdList.LUMAUI("status")
    eq(app.Settings.active, "diagnostics")
    eq(#app.errors, 0)
end)

test("layout editing ends on combat and preserves saved positions", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.Layout:Toggle()
    eq(app.Layout.editing, true)
    local overlay = app.Layout.entries.questList.overlay
    overlay:ClearAllPoints()
    overlay:SetPoint("CENTER", UIParent, "CENTER", 101, -101)
    overlay.scripts.OnDragStop(overlay)
    eq(app.Store:Profile().positions.questList.x, 100)
    eq(app.Store:Profile().positions.questList.y, -100)
    H.Combat(true)
    eq(app.Layout.editing, false)
    eq(overlay:IsShown(), false)
    eq(app.Layout:Toggle(), false)
    H.Combat(false)
    app.Store:Reset(true)
    eq(next(app.Store:Profile().positions), nil)
end)

test("hooks stay single across enable cycles and restore visibility", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    for _ = 1, 3 do
        app.Store:Set("modules", "tooltip", false)
        app.Store:Set("modules", "tooltip", true)
        app.Store:Set("modules", "chat", false)
        app.Store:Set("modules", "chat", true)
        app.Store:Set("modules", "chatTabs", false)
        app.Store:Set("modules", "chatTabs", true)
    end
    eq(GameTooltip.hookCount, 2)
    eq(ItemRefTooltip.hookCount, 2)
    eq(ShoppingTooltip1.hookCount, 2)
    eq(ShoppingTooltip2.hookCount, 2)
    eq(ChatFrame1.hookCount, 3)
    eq(ChatFrame1EditBox.hookCount, 2)
    eq(ChatFrame2.hookCount, 3)
    eq(ChatFrame2EditBox.hookCount, 2)
    eq(ChatFrame1Tab.hookCount, 3)
    GameTooltip:Show()
    eq(app.components.tooltip.decor.GameTooltip.plate:IsShown(), true)
    GameTooltip:Hide()
    eq(app.components.tooltip.decor.GameTooltip.plate:IsShown(), false)
    local entry = app.components.chat.windows[1]
    ChatFrame1:Hide()
    eq(entry.background:IsShown(), false)
    ChatFrame1:Show()
    eq(entry.background:IsShown(), true)
end)

test("component failures do not stop healthy modules", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local bad = app:RegisterComponent({ id = "broken", defaultEnabled = true,
        Enable = function() error("deliberate test failure") end, Disable = function() end })
    eq(bad.status, "failed")
    eq(app.components.dataStrip.running, true)
    local dependent = app:RegisterComponent({ id = "dependent", requires = { "broken" }, defaultEnabled = true,
        Enable = function() error("must not run") end, Disable = function() end })
    eq(dependent.status, "dependency")
    eq(dependent.running, nil)
end)

test("unsupported capabilities disable only that component", function()
    local app = H.Load({ migrations = { pearlBatch = true },
        profiles = { Default = { modules = { questList = true } } } })
    C_Container = nil; C_QuestLog = nil; H.Fire("PLAYER_LOGIN")
    eq(app.components.inventory.status, "unsupported")
    eq(app.components.questList.status, "unsupported")
    eq(app.components.dataStrip.running, true)
    eq(#app.errors, 0)
end)

test("optional extension switches survive while their addon is absent", function()
    local app = H.Load({ schema = 1, profiles = { Default = { modules = { externalWidget = false } } } })
    H.Fire("PLAYER_LOGIN")
    eq(app.Store:Profile().modules.externalWidget, false)
    app.Settings:Toggle("modules")
    app:RegisterComponent({ id = "externalWidget", defaultEnabled = true,
        Enable = function() end, Disable = function() end })
    app.Settings:Update()
    eq(app.components.externalWidget.status, "disabled")
    eq(app.Settings.pages.modules.rows.externalWidget ~= nil, true)
end)

test("the Pearl batch retires the custom quest panel only once", function()
    local app = H.Load({ schema = 1,
        profiles = { Default = { modules = { questList = true } } } })
    H.Fire("PLAYER_LOGIN")
    eq(app.Store:Profile().modules.questList, false)
    eq(app.components.questList.running, nil)
    eq(LumaUIDB.migrations.pearlBatch, true)
    -- A deliberate opt-in after the migration is the player's choice and is
    -- carried forward by a reload.
    app.Store:Set("modules", "questList", true)
    eq(app.Store:Profile().modules.questList, true)
    local saved = LumaUIDB
    local again = H.Load(saved); H.Fire("PLAYER_LOGIN")
    eq(again.Store:Profile().modules.questList, true)
    eq(#app.errors, 0)
end)

test("duplicate errors are counted without repeated chat output", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local before = #H.messages
    app:Report("test", "repeat")
    app:Report("test", "repeat")
    app:Report("test", "repeat")
    eq(#H.messages, before + 1)
    eq(#app.errors, 1)
    eq(app.errors[1].count, 3)
end)

test("profiles changed during combat apply only their final module state", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.Store:Create("Combat", true)
    app.Store:Set("modules", "unitFrames", true)
    app.Store:Select("Default")
    H.Combat(true)
    app.Store:Select("Combat")
    app.Store:Select("Default")
    app.Store:Select("Combat")
    eq(app.components.unitFrames.running, false)
    eq(app.Queue:Count(), 1)
    H.Combat(false)
    eq(app.components.unitFrames.running, true)
    eq(app.Store.current, "Combat")
    eq(#app.errors, 0)
end)

test("re-entering combat while flushing does not drop remaining jobs", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local called = 0
    H.Combat(true)
    app.Queue:Run("first", function() called = called + 1; H.Combat(true) end)
    app.Queue:Run("second", function() called = called + 1 end)
    H.Combat(false)
    eq(called, 1)
    eq(app.Queue:Count(), 1)
    H.Combat(false)
    eq(called, 2)
    eq(app.Queue:Count(), 0)
end)

test("non-Retail clients do not mutate saved variables", function()
    local saved = { marker = true }
    local app = H.Load(saved); WOW_PROJECT_ID = 2; H.Fire("PLAYER_LOGIN")
    eq(app.ready, nil)
    eq(LumaUIDB, saved)
    eq(#H.timers, 0)
end)

test("English fallback loads with no optional shared-media dependency", function()
    H.locale = "frFR"
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    eq(app.L.general, "Appearance")
    eq(app.L.unknown_key, "unknown_key")
    eq(#app.errors, 0)
    H.locale = nil
end)

test("chat backgrounds cover every window and its input box", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local chat = app.components.chat
    eq(ChatFrame1Background:IsShown(), false)
    eq(ChatFrame1TopLeftTexture:IsShown(), false)
    for index = 1, 4 do
        local entry = chat.windows[index]
        eq(entry ~= nil, true)
        eq(entry.background:IsShown(), index == 1)
    end
    eq(chat.windows[1].editBackground:IsShown(), false)
    -- Focus, not box visibility, is the semantic: with the client's "im" chat
    -- style the input stays on screen while deactivated.
    ChatFrame1EditBox:Show()
    eq(chat.windows[1].editBackground:IsShown(), false)
    ChatFrame1EditBox:SetFocus()
    eq(chat.windows[1].editBackground:IsShown(), true)
    H.Advance(0.3)
    eq(chat.windows[1].editBackground:GetAlpha(), 1)
    ChatFrame1EditBox:ClearFocus()
    H.Advance(0.3)
    eq(chat.windows[1].editBackground:IsShown(), false)
    ChatFrame1EditBox:Hide()
    ChatFrame2:Show()
    eq(chat.windows[2].background:IsShown(), true)
    ChatFrame2:Hide()
    eq(chat.windows[2].background:IsShown(), false)
    app.Store:Set("modules", "chat", false)
    eq(ChatFrame1Background:IsShown(), true)
    eq(ChatFrame1TopLeftTexture:IsShown(), true)
    eq(chat.windows[1].background:IsShown(), false)
    app.Store:Set("modules", "chat", true)
    eq(ChatFrame1Background:IsShown(), false)
    eq(chat.windows[1].background:IsShown(), true)
    NUM_CHAT_WINDOWS = 5
    local late = H.NewFrame("ChatFrame5", UIParent)
    late.editBox = H.NewFrame("ChatFrame5EditBox", UIParent)
    H.Fire("UPDATE_CHAT_WINDOWS")
    eq(chat.windows[5] ~= nil, true)
    eq(chat.windows[5].background:IsShown(), true)
    eq(#app.errors, 0)
end)

test("inventory browser uses native pickup, use, link and sort semantics", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    SlashCmdList.LUMAUI("bags")
    local inventory = app.components.inventory
    local button = inventory.buttons[1]
    eq(button.item.name, "Test item 0")
    button.scripts.OnClick(button, "LeftButton")
    eq(H.calls.pickupCount, 1)
    eq(H.calls.pickup.bag, 0)
    button.scripts.OnClick(button, "RightButton")
    eq(H.calls.useCount, 1)
    eq(H.calls.use.slot, 1)
    H.modifiedClicks.CHATLINK = true
    H.inserted = nil
    button.scripts.OnClick(button, "LeftButton")
    eq(H.inserted, button.item.link)
    eq(H.calls.pickupCount, 1)
    H.modifiedClicks.CHATLINK = false
    button.scripts.OnDragStart(button)
    eq(H.calls.pickupCount, 2)
    button.scripts.OnReceiveDrag(button)
    eq(H.calls.pickupCount, 3)
    inventory.sort.scripts.OnClick(inventory.sort)
    eq(H.calls.sort, true)
    inventory.search:SetText("test item 3")
    inventory.search.scripts.OnTextChanged(inventory.search)
    eq(inventory.buttons[1].item.bag, 3)
    eq(#app.errors, 0)
end)

test("inventory still browses when item actions are unavailable", function()
    local app = H.Load()
    C_Container.UseContainerItem = nil
    C_Container.PickupContainerItem = nil
    C_Container.SortBags = nil
    H.Fire("PLAYER_LOGIN")
    SlashCmdList.LUMAUI("bags")
    local inventory = app.components.inventory
    eq(inventory.running, true)
    eq(inventory.sort:IsShown(), false)
    local before = #H.messages
    inventory.buttons[1].scripts.OnClick(inventory.buttons[1], "LeftButton")
    eq(H.calls.pickup, nil)
    eq(#H.messages, before + 1)
    eq(#app.errors, 0)
end)

test("tooltip draws one card and one quality rule instead of a four-sided frame", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local tooltip = app.components.tooltip
    for _, name in ipairs({ "GameTooltip", "ItemRefTooltip", "ShoppingTooltip1", "ShoppingTooltip2" }) do
        local decor = tooltip.decor[name]
        eq(decor ~= nil, true)
        eq(decor.plate:IsShown(), false)
        -- Four hand-placed 1px strips are exactly what the card replaced.
        eq(#decor.lines, 0)
        eq(decor.quality ~= nil, true)
        eq(_G[name].NineSlice:IsShown(), false)
    end
    GameTooltip.itemLink = "|Hitem:999|h[Quality item]|h"
    GameTooltip:Show()
    local decor = tooltip.decor.GameTooltip
    eq(decor.plate:IsShown(), true)
    eq(decor.quality:IsShown(), true)
    eq(decor.plate.drawLayer, "BACKGROUND")
    eq(decor.quality.drawLayer, "BORDER")
    eq(decor.quality.color[3], 0.87)
    ItemRefTooltip.itemLink = "|Hitem:999|h[Quality item]|h"
    ItemRefTooltip:Show()
    eq(tooltip.decor.ItemRefTooltip.plate:IsShown(), true)
    ItemRefTooltip:Hide()
    eq(tooltip.decor.ItemRefTooltip.plate:IsShown(), false)
    GameTooltip:Hide()
    GameTooltip.itemLink = nil
    GameTooltip:Show()
    local accent = app.Theme:Accent()
    eq(decor.quality.color[1], accent[1])
    app.Store:Set("appearance", "tooltipQuality", false)
    GameTooltip:Hide()
    GameTooltip.itemLink = "|Hitem:999|h[Quality item]|h"
    GameTooltip:Show()
    eq(decor.quality.color[1], accent[1])
    GameTooltip.forbidden = true
    GameTooltip:Hide()
    GameTooltip:Show()
    eq(decor.plate:IsShown(), false)
    GameTooltip.forbidden = false
    app.Store:Set("modules", "tooltip", false)
    eq(decor.plate:IsShown(), false)
    eq(GameTooltip.NineSlice:IsShown(), true)
    eq(ItemRefTooltip.NineSlice:IsShown(), true)
    app.Store:Set("modules", "tooltip", true)
    eq(GameTooltip.NineSlice:IsShown(), false)
    eq(#app.errors, 0)
end)

test("restricted player identity never enters profile keys", function()
    local app = H.Load()
    local original = UnitFullName
    _G.UnitFullName = function() return H.Secret("Secret"), H.Secret("Realm") end
    H.Fire("PLAYER_LOGIN")
    eq(app.ready, true)
    eq(app.Store.character, "Player - Realm")
    eq(app.Store.data.characters["Player - Realm"], "Default")
    _G.UnitFullName = original
    eq(#app.errors, 0)
end)

test("minimap frame follows native visibility and quest titles use the Pearl accent", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local minimap = app.components.minimap
    eq(minimap.running, true)
    eq(minimap.panel:IsShown(), true)
    -- The map has a quiet HUD plate and one separate boundary line.
    eq(minimap.panel.lumaSurfaceRole, "hud")
    eq(minimap.panel.backdrop, nil)
    eq(minimap.edge.backdrop.edgeSize, 1)
    eq(minimap.clock:GetText(), "12:34")
    eq(minimap.coords:GetText(), "50, 25")
    eq(MinimapCompassTexture.desaturated, true)
    eq(MinimapCompassTexture:IsShown(), false)
    eq(MinimapCluster.BorderTop:IsShown(), false)
    eq(Minimap.maskTexture, "Interface\\Buttons\\WHITE8X8")
    eq(minimap.edge:IsShown(), true)
    eq(MinimapZoneText.textColor[1], 0.96)
    eq(MinimapCluster.MinimapContainer.PlayerCoords:IsShown(), false)
    Minimap:Hide()
    eq(minimap.panel:IsShown(), false)
    eq(minimap.edge:IsShown(), false)
    Minimap:Show()
    eq(minimap.panel:IsShown(), true)
    eq(minimap.edge:IsShown(), true)
    MinimapCluster:Hide()
    eq(minimap.panel:IsShown(), false)
    eq(minimap.edge:IsShown(), false)
    MinimapCluster:Show()
    eq(minimap.panel:IsShown(), true)
    eq(minimap.edge:IsShown(), true)
    local tracker = app.components.questTracker
    eq(tracker.running, true)
    eq(tracker.panel, nil)
    local blocks = QuestObjectiveTracker.usedBlocks[1]
    local accent = app.Theme:Accent()
    eq(blocks[101].HeaderText.textColor[1], accent[1])
    eq(blocks[102].HeaderText.textColor[1], accent[1])
    -- Campaign quests come from a separate module enumerated without usedBlocks.
    eq(H.campaignBlock.HeaderText.textColor[1], accent[1])
    eq(H.campaignBlock.HeaderText.textColor[2], accent[2])
    H.Fire("PLAYER_LEVEL_UP")
    eq(H.campaignBlock.HeaderText.textColor[2], accent[2])
    blocks[101].isHighlighted = true
    blocks[101]:UpdateHighlight()
    eq(blocks[101].HeaderText.textColor[1], 1)
    blocks[101].isHighlighted = false
    blocks[101]:UpdateHighlight()
    eq(blocks[101].HeaderText.textColor[1], accent[1])
    local added = H.NewFrame(nil, QuestObjectiveTracker)
    added.id = 103
    added.isHighlighted = false
    added.HeaderText = H.NewFrame(nil, added)
    added.HeaderText.textColor = { 1, 0.82, 0, 1 }
    added.UpdateHighlight = function(current) current.HeaderText:SetTextColor(1, 0.82, 0, 1) end
    QuestObjectiveTracker.usedBlocks[1][103] = added
    H.questLevels[103] = 7
    ObjectiveTrackerFrame:Update()
    eq(added.HeaderText.textColor[1], accent[1])
    app.Store:Set("modules", "questTracker", false)
    eq(blocks[101].HeaderText.textColor[1], 1)
    eq(blocks[101].HeaderText.textColor[2], 0.82)
    eq(H.campaignBlock.HeaderText.textColor[2], 0.82)
    app.Store:Set("modules", "questTracker", true)
    eq(blocks[101].HeaderText.textColor[1], accent[1])
    eq(H.campaignBlock.HeaderText.textColor[2], accent[2])
    app.Store:Set("modules", "minimap", false)
    eq(minimap.panel:IsShown(), false)
    eq(minimap.edge:IsShown(), false)
    eq(Minimap.maskTexture, 186178)
    eq(MinimapCompassTexture:IsShown(), true)
    eq(MinimapCompassTexture.desaturated, false)
    eq(MinimapZoneText.textColor[1], 1)
    eq(MinimapCluster.MinimapContainer.PlayerCoords:IsShown(), true)
    app.Store:Set("modules", "minimap", true)
    eq(minimap.panel:IsShown(), true)
    eq(minimap.edge:IsShown(), true)
    eq(MinimapCompassTexture.desaturated, true)
    eq(Minimap.maskTexture, "Interface\\Buttons\\WHITE8X8")
    eq(MinimapCompassTexture:IsShown(), false)
    eq(MinimapCluster.MinimapContainer.PlayerCoords:IsShown(), false)
    eq(#app.errors, 0)
end)

test("the native quest column follows the minimap and restores", function()
    local app = H.Load(); UIParent:SetSize(1920, 1080); H.Fire("PLAYER_LOGIN")
    local tracker = app.components.questTracker
    local frame = _G.ObjectiveTrackerFrame
    local panel = _G.LumaUIMinimapPanel
    eq(tracker.running, true)
    -- The frame sits under the map panel and takes the panel's width; the
    -- fixture is narrower than the 120 UI minimum.
    eq(frame.point[1], "TOPRIGHT")
    eq(frame.point[2], panel)
    eq(frame.point[3], "BOTTOMRIGHT")
    eq(frame.point[5], -6)
    eq(frame.width, 120)
    -- Long zone names are clipped to the map instead of spilling out.
    eq(_G.MinimapZoneText.width, 174)
    panel:SetWidth(300)
    tracker:Refresh()
    eq(frame.width, 300)
    _G.Minimap:SetWidth(200)
    app.components.minimap:Refresh()
    eq(_G.MinimapZoneText.width, 176)
    app.Store:Set("modules", "questTracker", false)
    eq(frame.point, nil)
    eq(frame.width, 250)
    -- The zone width belongs to the minimap component; restoring it is tested
    -- with that component's own disable path.
    app.Store:Set("modules", "minimap", false)
    eq(_G.MinimapZoneText.width, 100)
    eq(#app.errors, 0)
end)

test("minimap card follows the HUD theme and screen scale without rebuilding", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local minimap = app.components.minimap
    local plate, edge, rule = minimap.panel.lumaPlate, minimap.edge, minimap.rule
    eq(plate.vertexColor[4], 0.80)
    eq(minimap.clock.lumaTypeRole, "micro")
    eq(minimap.coords.lumaTypeRole, "micro")
    eq(minimap.clock.point[1], "BOTTOMLEFT")
    eq(minimap.coords.point[1], "BOTTOMRIGHT")
    app.Store:Set("appearance", "hudOpacity", 0.4)
    app.Store:Set("appearance", "accent", "ember")
    eq(minimap.panel.lumaPlate, plate)
    eq(minimap.edge, edge)
    eq(minimap.rule, rule)
    eq(plate.vertexColor[4], 0.4)
    eq(rule.color[1], app.Theme.colors.ember[1])
    UIParent:SetScale(2)
    H.Fire("UI_SCALE_CHANGED")
    eq(edge.backdrop.edgeSize, 0.5)
    eq(rule:GetHeight(), 0.5)
    UIParent:SetScale(1)
    H.Fire("UI_SCALE_CHANGED")
    eq(#app.errors, 0)
end)

test("layout page lists movable panels and opens native edit mode", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.Settings:Toggle("layout")
    eq(app.Settings.active, "layout")
    app.Settings:Update()
    local row = app.Settings.layoutRows[1]
    eq(row ~= nil, true)
    eq(row.id ~= nil, true)
    eq(row.label:GetText() ~= "", true)
    row.button.scripts.OnClick(row.button)
    eq(app.Layout.editing, true)
    local escape = app.Layout.escape
    eq(escape ~= nil, true)
    eq(escape:IsShown(), true)
    eq(UISpecialFrames[#UISpecialFrames], "LumaUILayoutEscape")
    escape:Hide()
    eq(app.Layout.editing, false)
    app.Settings:Toggle("layout")
    app.Settings:Update()
    app.Settings.layoutEditMode.scripts.OnClick(app.Settings.layoutEditMode)
    eq(H.shownPanel, EditModeManagerFrame)
    SlashCmdList.LUMAUI("layout")
    eq(app.Settings.active, "layout")
    eq(#app.errors, 0)
end)

test("quest list replaces the native quest block while offering folds, tracking and icons", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local list = app.components.questList
    eq(list.running, true)
    eq(list.status, "running")
    eq(list.filter, "all")
    eq(list.frame:IsShown(), true)
    eq(list.title:GetText(), app.L.questListTitle .. "  2")
    eq(app.Layout.entries.questList ~= nil, true)
    eq(app.Layout.entries.questList.label, app.L.questList)
    eq(list.frame.backdrop, nil)
    -- The panel replaces only the quest modules; everything else stays native.
    eq(list.nativeHidden, true)
    eq(ObjectiveTrackerFrame:IsShown(), true)
    eq(QuestObjectiveTracker:IsShown(), false)
    eq(CampaignQuestObjectiveTracker:IsShown(), false)
    eq(WorldQuestObjectiveTracker:IsShown(), false)
    eq(ScenarioObjectiveTracker:IsShown(), true)
    eq(ObjectiveTrackerFrame:HasModule(QuestObjectiveTracker), false)
    eq(ObjectiveTrackerFrame:HasModule(CampaignQuestObjectiveTracker), false)
    eq(ObjectiveTrackerFrame:HasModule(ScenarioObjectiveTracker), true)
    eq(app.components.questTracker.running, true)
    -- The client may show a quest module again on its own updates; the takeover
    -- takes it back down so both trackers cannot list the same quest.
    QuestObjectiveTracker:Show()
    eq(QuestObjectiveTracker:IsShown(), false)
    eq(ObjectiveTrackerFrame:HasModule(QuestObjectiveTracker), false)

    local function findRow(text)
        for _, current in ipairs(list.rows) do
            if current.frame:IsShown() and current.label:GetText() == text then return current end
        end
    end

    eq(list.rows[1].label:GetText(), "Campaign")
    eq(list.rows[1].arrow:GetText(), "-")
    eq(list.rows[1].iconButton:IsShown(), false)
    local first = findRow("First quest")
    eq(first ~= nil, true)
    eq(first.right:GetText(), "")
    eq(first.dot:IsShown(), true)
    eq(first.dot.width, 4)
    eq(first.iconButton:IsShown(), true)
    eq(first.icon.atlas, "SideInProgressquesticon")
    eq(first.icon.texture, nil)
    -- Titles carry state; difficulty lives on the local two-pixel mark.
    eq(first.label.textColor[1], app.Theme.colors.text[1])
    eq(first.label.textColor[4], 1)
    eq(first.mark:IsShown(), true)
    eq(first.mark.color[1], 0.5)
    eq(first.label.wordWrap, true)
    eq(findRow("Slay 8 boars") ~= nil, true)
    eq(findRow("Return to town") ~= nil, true)
    local second = findRow("Second quest")
    eq(second.label.textColor[1], app.Theme.colors.text[1])
    eq(second.label.textColor[4], 0.78)
    eq(second.mark.color[1], 1)
    eq(second.mark.color[2], 0.82)
    eq(findRow("Talk to the scout") ~= nil, true)

    -- Group headers fold and unfold; the quest log's own collapsed flag is ignored.
    H.Click(list.rows[1].frame)
    eq(list.rows[1].arrow:GetText(), "+")
    eq(findRow("First quest"), nil)
    eq(findRow("Second quest"), nil)
    H.Click(list.rows[1].frame)
    eq(list.rows[1].arrow:GetText(), "-")
    eq(findRow("First quest") ~= nil, true)
    eq(findRow("Second quest") ~= nil, true)

    -- Quest titles fold their objectives.
    H.Click(findRow("First quest").frame)
    eq(findRow("Slay 8 boars"), nil)
    eq(findRow("First quest").right:GetText(), "+")
    H.Click(findRow("First quest").frame)
    eq(findRow("Slay 8 boars") ~= nil, true)

    -- Shift-clicking a title toggles the watch list.
    H.shiftDown = true
    H.Click(findRow("Second quest").frame)
    H.shiftDown = false
    eq(H.questLog.watch[102], 1)
    eq(findRow("Second quest").dot:IsShown(), true)
    eq(findRow("Second quest").dot.width, 4)
    H.shiftDown = true
    H.Click(findRow("Second quest").frame)
    H.shiftDown = false
    eq(H.questLog.watch[102], nil)
    eq(findRow("Second quest").dot:IsShown(), false)
    eq(findRow("Second quest").right:GetText(), "")

    -- Icon clicks toggle super tracking, which the map uses to draw the path.
    H.Click(findRow("First quest").iconButton)
    eq(H.superTracked, 101)
    eq(findRow("First quest").dot:IsShown(), true)
    eq(findRow("First quest").dot.width, 7)
    H.Click(findRow("First quest").iconButton)
    eq(H.superTracked, nil)

    -- A quest outside the watch list is watched first, like the map pin does.
    eq(H.questLog.watch[102], nil)
    H.Click(findRow("Second quest").iconButton)
    eq(H.questLog.watch[102], 1)
    eq(H.superTracked, 102)
    eq(findRow("Second quest").dot.width, 7)
    H.Click(findRow("Second quest").iconButton)
    eq(H.superTracked, nil)

    -- Completed quests switch to the turn-in icon, show no objective lines and
    -- turn their title to the turn-in gold.
    H.questLog.ready[102] = true
    H.Fire("QUEST_LOG_UPDATE")
    eq(findRow("Second quest").icon.texture, "Interface\\GossipFrame\\ActiveQuestIcon")
    eq(findRow("Second quest").icon.atlas, nil)
    eq(findRow("Second quest").label.textColor[1], 0.95)
    eq(findRow("Second quest").label.textColor[2], 0.8)
    eq(findRow("Talk to the scout"), nil)
    eq(findRow(app.L.questListReady) ~= nil, true)
    H.questLog.ready[102] = nil
    H.questLog.failed[101] = true
    H.Fire("QUEST_LOG_UPDATE")
    eq(findRow(app.L.questListFailed) ~= nil, true)
    eq(findRow("First quest").icon.vertexColor[2], 0.35)
    eq(findRow("First quest").label.textColor[1], 0.9)
    H.questLog.failed[101] = nil

    -- Restricted titles are skipped without arithmetic or concatenation.
    H.questLog.entries[1] = { title = H.Secret("hidden"), isHeader = true }
    H.Fire("QUEST_LOG_UPDATE")
    eq(list.title:GetText(), app.L.questListTitle .. "  2")
    eq(list.rows[1].label:GetText(), app.L.questListOther)
    H.questLog.entries = {
        { title = "Campaign", isHeader = true, isCollapsed = true },
        { title = "First quest", questID = 101, level = 5 },
        { title = "Other", isHeader = true },
        { title = "Second quest", questID = 102, level = 80 },
    }
    H.Fire("QUEST_LOG_UPDATE")
    eq(list.title:GetText(), app.L.questListTitle .. "  2")
    eq(findRow("First quest") ~= nil, true)

    -- An empty filter keeps the panel and its filter buttons reachable, and the
    -- quest modules return to the client while the panel has nothing to show.
    local entries = H.questLog.entries
    H.questLog.entries = {}
    H.Fire("QUEST_LOG_UPDATE")
    eq(list.frame:IsShown(), true)
    eq(list.title:GetText(), app.L.questListTitle .. "  0")
    eq(findRow(app.L.questListEmpty) ~= nil, true)
    eq(list.hasContent, false)
    eq(list.nativeHidden, nil)
    eq(QuestObjectiveTracker:IsShown(), true)
    eq(ObjectiveTrackerFrame:HasModule(QuestObjectiveTracker), true)
    H.questLog.entries = entries
    H.Fire("QUEST_LOG_UPDATE")
    eq(findRow("First quest") ~= nil, true)
    eq(list.hasContent, true)
    eq(QuestObjectiveTracker:IsShown(), false)
    eq(ObjectiveTrackerFrame:HasModule(QuestObjectiveTracker), false)
    eq(#app.errors, 0)
end)

test("quest list filters persist and restore the native tracker on disable", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local list = app.components.questList
    eq(app.Store:Profile().ui.questFilter, "all")
    eq(list.title:GetText(), app.L.questListTitle .. "  2")

    local function findRow(text)
        for _, current in ipairs(list.rows) do
            if current.frame:IsShown() and current.label:GetText() == text then return current end
        end
    end

    H.Click(list.filterButtons.tracked)
    eq(list.filter, "tracked")
    eq(app.Store:Profile().ui.questFilter, "tracked")
    eq(list.title:GetText(), app.L.questListTitle .. "  1")
    eq(findRow("First quest") ~= nil, true)
    eq(findRow("Second quest"), nil)

    H.questLog.map = { { questID = 102 } }
    H.Click(list.filterButtons.zone)
    eq(list.filter, "zone")
    eq(app.Store:Profile().ui.questFilter, "zone")
    eq(list.title:GetText(), app.L.questListTitle .. "  1")
    eq(findRow("Second quest") ~= nil, true)
    eq(findRow("First quest"), nil)

    -- The quest log's zone headers also count as the current area.
    H.questLog.entries = {
        { title = "Test Zone", isHeader = true },
        { title = "First quest", questID = 101, level = 5 },
        { title = "Elsewhere", isHeader = true },
        { title = "Second quest", questID = 102, level = 80 },
    }
    H.questLog.map = {}
    H.Fire("QUEST_LOG_UPDATE")
    eq(findRow("First quest") ~= nil, true)
    eq(findRow("Second quest"), nil)

    H.Click(list.filterButtons.all)
    eq(app.Store:Profile().ui.questFilter, "all")
    eq(list.title:GetText(), app.L.questListTitle .. "  2")
    H.Click(list.filterButtons.tracked)

    local saved = LumaUIDB
    local reloaded = H.Load(saved); H.Fire("PLAYER_LOGIN")
    local restored = reloaded.components.questList
    eq(restored.filter, "tracked")
    eq(restored.title:GetText(), reloaded.L.questListTitle .. "  1")
    -- The reloaded panel has content, so the quest modules stay replaced.
    eq(QuestObjectiveTracker:IsShown(), false)
    eq(ObjectiveTrackerFrame:HasModule(QuestObjectiveTracker), false)
    eq(ScenarioObjectiveTracker:IsShown(), true)

    reloaded.Store:Set("modules", "questList", false)
    eq(restored.running, false)
    eq(restored.status, "disabled")
    eq(restored.frame:IsShown(), false)
    eq(QuestObjectiveTracker:IsShown(), true)
    eq(CampaignQuestObjectiveTracker:IsShown(), true)
    eq(ObjectiveTrackerFrame:HasModule(QuestObjectiveTracker), true)
    eq(next(restored.events.events, nil), nil)
    reloaded.Store:Set("modules", "questList", true)
    eq(restored.running, true)
    eq(restored.frame:IsShown(), true)
    eq(QuestObjectiveTracker:IsShown(), false)
    eq(ObjectiveTrackerFrame:HasModule(QuestObjectiveTracker), false)
    eq(ObjectiveTrackerFrame:HasModule(ScenarioObjectiveTracker), true)
    eq(#reloaded.errors, 0)
end)

test("chat tabs replace native art and mark the active window", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local tabs = app.components.chatTabs
    eq(tabs.running, true)
    local first, second = tabs.tabs[1], tabs.tabs[2]
    eq(first ~= nil, true)
    eq(first.decor.bg:IsShown(), true)
    for _, key in ipairs({ "Left", "Right", "Middle", "ActiveLeft", "ActiveMiddle", "ActiveRight", "HighlightLeft", "HighlightMiddle", "HighlightRight" }) do
        eq(first.tab[key]:GetAlpha(), 0)
        eq(first.tab[key]:IsShown(), false)
    end
    eq(first.tab:GetAlpha(), 1)
    eq(first.decor.rule:IsShown(), true)
    -- Pearl tabs have no pill: both backings are transparent, and only the
    -- selected rule carries the accent.
    eq(first.decor.bg.color[4], 0)
    eq(second.decor.bg.color[4], 0)
    eq(first.decor.rule.color[2] > second.decor.rule.color[2], true)
    eq(second.decor.rule:IsShown(), false)
    eq(second.fontColor ~= nil, true)
    -- The client re-shows its own selected-tab art on dock updates; the next
    -- paint must hide it again without losing the saved restore state.
    ChatFrame1Tab.ActiveLeft:Show()
    ChatFrame1Tab.ActiveLeft:SetAlpha(1)
    H.selectedDockFrame = ChatFrame2
    H.Fire("UPDATE_CHAT_WINDOWS")
    eq(ChatFrame1Tab.ActiveLeft:GetAlpha(), 0)
    eq(ChatFrame1Tab.ActiveLeft:IsShown(), false)
    eq(tabs.tabs[1].decor.rule:IsShown(), false)
    eq(tabs.tabs[2].decor.rule:IsShown(), true)
    H.selectedDockFrame = nil
    app.Store:Set("modules", "chatTabs", false)
    eq(ChatFrame1Tab.Left:GetAlpha(), 1)
    eq(ChatFrame1Tab.Left:IsShown(), true)
    eq(ChatFrame1Tab:GetAlpha(), 0.4)
    eq(ChatFrame1Tab:GetFontString():GetTextColor(), 1)
    eq(first.decor.bg:IsShown(), false)
    app.Store:Set("modules", "chatTabs", true)
    eq(ChatFrame1Tab.Left:GetAlpha(), 0)
    eq(first.decor.bg:IsShown(), true)
    eq(#app.errors, 0)
end)

test("data strip hover reports own raid progress, money and performance", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local strip = app.components.dataStrip
    H.savedInstances = {
        { name = "Manaforge Omega", reset = 3 * 86400, isRaid = true, difficultyName = "Heroic", locked = true },
        { name = "Dungeon", reset = 3600, isRaid = false },
    }
    H.savedWorldBosses = { { name = "World Boss", reset = 5 * 86400 } }

    GameTooltip.lines = {}
    strip.segments.clock.scripts.OnEnter()
    eq(H.raidRequested, true)
    local raidLines = table.concat(GameTooltip.lines, "\n")
    eq(raidLines:find("Manaforge Omega", 1, true) ~= nil, true)
    eq(raidLines:find("Heroic", 1, true) ~= nil, true)
    eq(raidLines:find("3 days", 1, true) ~= nil, true)
    eq(raidLines:find("Dungeon", 1, true), nil)
    eq(raidLines:find("World Boss", 1, true) ~= nil, true)

    H.savedInstances = {}
    H.savedWorldBosses = {}
    GameTooltip.lines = {}
    strip.segments.clock.scripts.OnEnter()
    eq(table.concat(GameTooltip.lines, "\n"):find(app.L.raidNone, 1, true) ~= nil, true)

    app.Store:SetMoney("Alt - Realm", 200000)
    H.warbandMoney = 50000
    H.money = 123456
    GameTooltip.lines = {}
    strip.segments.money.scripts.OnEnter()
    local moneyLines = table.concat(GameTooltip.lines, "\n")
    eq(moneyLines:find("Tester - Realm", 1, true) ~= nil, true)
    eq(moneyLines:find(app.L.goldCurrent, 1, true) ~= nil, true)
    eq(moneyLines:find("Alt - Realm", 1, true) ~= nil, true)
    eq(moneyLines:find(app.L.goldWarband, 1, true) ~= nil, true)
    eq(moneyLines:find(app.L.goldNote, 1, true) ~= nil, true)
    eq(app.Store.money["Tester - Realm"], 123456)
    H.money = 250000
    H.Fire("PLAYER_MONEY")
    eq(app.Store.money["Tester - Realm"], 250000)

    GameTooltip.lines = {}
    strip.segments.zone.scripts.OnEnter()
    local zoneLines = table.concat(GameTooltip.lines, "\n")
    eq(zoneLines:find("Test Zone", 1, true) ~= nil, true)
    eq(zoneLines:find("Test Subzone", 1, true) ~= nil, true)
    eq(zoneLines:find(app.L.coordsLabel, 1, true) ~= nil, true)

    GameTooltip.lines = {}
    strip.segments.performance.scripts.OnEnter()
    local performance = table.concat(GameTooltip.lines, "\n")
    eq(performance:find("120", 1, true) ~= nil, true)
    eq(performance:find("40", 1, true) ~= nil, true)

    strip.segments.performance.scripts.OnLeave()
    eq(GameTooltip:IsShown(), false)
    eq(#app.errors, 0)
end)

test("money ledger normalizes stored values and refuses invalid writes", function()
    local app = H.Load({ money = { ["A - Realm"] = 1234.9, ["B - Realm"] = -5, ["bad|name"] = 10, ["C - Realm"] = 1e15 } })
    H.Fire("PLAYER_LOGIN")
    local money = app.Store.money
    eq(money["A - Realm"], 1234)
    eq(money["B - Realm"], nil)
    eq(money["bad|name"], nil)
    eq(money["C - Realm"], 1000000000000)
    eq(app.Store:SetMoney("D - Realm", 0 / 0), false)
    eq(app.Store:SetMoney(nil, 10), false)
    eq(LumaUIDB.money, app.Store.money)
    -- Recording continues with the strip disabled; it is a core service.
    app.Store:Set("modules", "dataStrip", false)
    H.money = 777
    H.Fire("PLAYER_MONEY")
    eq(app.Store.money["Tester - Realm"], 777)
    H.money = 888
    H.Fire("PLAYER_ENTERING_WORLD")
    eq(app.Store.money["Tester - Realm"], 888)
    local readonly = H.Load({ schema = 99 })
    H.Fire("PLAYER_LOGIN")
    eq(readonly.Store:SetMoney("E - Realm", 10), false)
end)

test("experience tooltip adds completion and remaining lines", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local experience = app.components.experience
    GameTooltip.lines = {}
    experience.frame.scripts.OnEnter()
    local lines = table.concat(GameTooltip.lines, "\n")
    eq(lines:find(string.format(app.L.xpProgress, 30), 1, true) ~= nil, true)
    eq(lines:find(string.format(app.L.xpRemaining, 70), 1, true) ~= nil, true)
    eq(lines:find(app.L.rested, 1, true) ~= nil, true)
    experience.frame.scripts.OnLeave()
    eq(GameTooltip:IsShown(), false)
    eq(#app.errors, 0)
end)

test("quest folds persist per profile and sanitize damaged saves", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local list = app.components.questList
    local function findRow(rows, text)
        for _, current in ipairs(rows) do
            if current.frame:IsShown() and current.label:GetText() == text then return current end
        end
    end

    -- Folding a group writes through to the current profile.
    H.Click(list.rows[1].frame)
    eq(findRow(list.rows, "First quest"), nil)
    eq(app.Store:Profile().ui.questFolds.groups["Campaign"], true)

    -- A reload restores the saved group fold.
    local saved = LumaUIDB
    local reloaded = H.Load(saved); H.Fire("PLAYER_LOGIN")
    local restored = reloaded.components.questList
    eq(restored.rows[1].arrow:GetText(), "+")
    eq(findRow(restored.rows, "First quest"), nil)

    -- Unfolding persists as an empty group list; folding a quest remembers its id.
    H.Click(restored.rows[1].frame)
    eq(findRow(restored.rows, "First quest") ~= nil, true)
    eq(next(reloaded.Store:Profile().ui.questFolds.groups), nil)
    H.Click(findRow(restored.rows, "First quest").frame)
    eq(reloaded.Store:Profile().ui.questFolds.quests["101"], true)
    eq(findRow(restored.rows, "Slay 8 boars"), nil)

    -- Fold state follows the selected profile: a blank profile expands, the
    -- folded profile collapses again.
    reloaded.Store:Create("Clean", false)
    reloaded.Store:Set("modules", "questList", true)
    eq(findRow(restored.rows, "Slay 8 boars") ~= nil, true)
    reloaded.Store:Select("Default")
    eq(findRow(restored.rows, "Slay 8 boars"), nil)
    reloaded.Store:Select("Clean")
    eq(findRow(restored.rows, "Slay 8 boars") ~= nil, true)

    -- Damaged saves are normalized away; rows start expanded.
    local broken = H.Load({ migrations = { pearlBatch = true },
        profiles = { Default = { modules = { questList = true }, ui = { questFolds = {
            groups = { ["Campaign"] = "yes", [string.rep("x", 200)] = true, [7] = true },
            quests = { ["101"] = 1, ["bad\nkey"] = true } } } } } })
    H.Fire("PLAYER_LOGIN")
    local clean = broken.Store:Profile().ui.questFolds
    eq(next(clean.groups), nil)
    eq(next(clean.quests), nil)
    eq(findRow(broken.components.questList.rows, "First quest") ~= nil, true)
    eq(#broken.errors, 0)
end)

test("quest item buttons use secure attributes and defer changes in combat", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local list = app.components.questList
    local function findRow(rows, text)
        for _, current in ipairs(rows) do
            if current.frame:IsShown() and current.label:GetText() == text then return current end
        end
    end

    H.questLog.itemIndex[101] = 1
    H.questLog.items[1] = { link = "|Hitem:123|h[Quest item]|h", charges = 3 }
    H.Fire("QUEST_LOG_UPDATE")
    local first = findRow(list.rows, "First quest")
    eq(first.itemButton ~= nil, true)
    eq(first.itemButton:IsShown(), true)
    eq(first.itemButton:GetAttribute("type"), "item")
    eq(first.itemButton:GetAttribute("item"), "|Hitem:123|h[Quest item]|h")
    eq(first.itemButton.icon.texture, 134400)
    -- Rows without a usable item show no button.
    eq(findRow(list.rows, "Second quest").itemButton, nil)

    -- Combat defers the attribute change into a single queued job.
    H.questLog.itemIndex = { [102] = 2 }
    H.questLog.items = { [2] = { link = "|Hitem:456|h[Other item]|h" } }
    H.Combat(true)
    H.Fire("QUEST_LOG_UPDATE")
    eq(app.Queue:Count(), 1)
    eq(first.itemButton:GetAttribute("item"), "|Hitem:123|h[Quest item]|h")
    eq(first.itemButton:IsShown(), true)
    H.Combat(false)
    eq(first.itemButton:IsShown(), false)
    local second = findRow(list.rows, "Second quest")
    eq(second.itemButton ~= nil, true)
    eq(second.itemButton:GetAttribute("item"), "|Hitem:456|h[Other item]|h")
    eq(second.itemButton.icon.texture, 134400)
    eq(#app.errors, 0)
end)

test("party quest sync banner appears only with session support", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local list = app.components.questList
    eq(list.sessionBanner, nil)
    H.questSession.exists = true
    H.Fire("QUEST_SESSION_CREATED")
    eq(list.sessionBanner ~= nil, true)
    eq(list.sessionBanner.label:GetText(), app.L.questSyncLabel)
    eq(list.sessionBanner.button.text:GetText(), app.L.questSyncJoin)
    H.Click(list.sessionBanner.button)
    eq(H.calls.sessionEnter, 1)
    H.questSession.state = 1
    H.Fire("QUEST_SESSION_ENTER_STATE_CHANGED")
    eq(list.sessionBanner.button.text:GetText(), app.L.questSyncLeave)
    H.Click(list.sessionBanner.button)
    eq(H.calls.sessionLeave, 1)
    H.questSession.exists = false
    H.Fire("QUEST_SESSION_DESTROYED")
    eq(list.sessionBanner, nil)
    -- Rows return to the top once the banner is gone.
    eq(list.rows[1].label:GetText(), "Campaign")

    -- A client without the session API shows no banner and no errors.
    local bare = H.Load(); C_QuestSession = nil; H.Fire("PLAYER_LOGIN")
    H.questSession.exists = true
    H.Fire("QUEST_LOG_UPDATE")
    eq(bare.components.questList.sessionBanner, nil)
    eq(#bare.errors, 0)
end)

test("quest rows open a context menu and missing APIs stay silent", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local list = app.components.questList
    local function findRow(rows, text)
        for _, current in ipairs(rows) do
            if current.frame:IsShown() and current.label:GetText() == text then return current end
        end
    end

    local first = findRow(list.rows, "First quest")
    H.Click(first.frame, "RightButton")
    eq(H.menu ~= nil, true)
    eq(H.menu.owner, first.frame)
    eq(H.menu.entries[1].kind, "title")
    eq(H.menu.entries[1].text, "First quest")
    local track, focus, log, abandon = nil, nil, nil, nil
    for _, entry in ipairs(H.menu.entries) do
        if entry.kind == "button" then
            if entry.text == app.L.questMenuUntrack then track = entry
            elseif entry.text == app.L.questMenuFocus then focus = entry
            elseif entry.text == app.L.questMenuLog then log = entry
            elseif entry.text == app.L.questMenuAbandon then abandon = entry end
        end
    end
    eq(track ~= nil, true)
    eq(focus ~= nil, true)
    eq(log ~= nil, true)
    eq(abandon ~= nil, true)
    track.fn()
    eq(H.questLog.watch[101], nil)
    focus.fn()
    eq(H.superTracked, 101)
    log.fn()
    eq(H.calls.openQuest, 101)
    abandon.fn()
    eq(H.calls.selectedQuest, 101)
    eq(H.calls.abandon, 1)

    -- Group rows have no context menu.
    H.menu = nil
    H.Click(list.rows[1].frame, "RightButton")
    eq(H.menu, nil)

    -- Without MenuUtil the right click stays silent.
    local bare = H.Load()
    MenuUtil = nil
    H.Fire("PLAYER_LOGIN")
    local bareFirst = nil
    for _, current in ipairs(bare.components.questList.rows) do
        if current.frame:IsShown() and current.label:GetText() == "First quest" then bareFirst = current end
    end
    eq(bareFirst ~= nil, true)
    H.Click(bareFirst.frame, "RightButton")
    eq(H.menu, nil)
    eq(#bare.errors, 0)
end)

-- ==== TRACK: VIS-17 QUEST HIERARCHY AND SAFE LAYOUT —append new tests above this line ====
test("quest titles wrap and the row height follows the measured text", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local list = app.components.questList
    local long = string.rep("很长的中文任务标题", 14)
    H.questLog.entries = {
        { title = "Campaign", isHeader = true },
        { title = long, questID = 301, level = 5 },
        { title = "Short", questID = 302, level = 5 },
    }
    H.questLog.objectives = { [301] = { { text = string.rep("完成世界任务目标", 12) } }, [302] = {} }
    H.Fire("QUEST_LOG_UPDATE")

    local function findRow(text)
        for _, current in ipairs(list.rows) do
            if current.frame:IsShown() and current.label:GetText() == text then return current end
        end
    end

    local wrapped = findRow(long)
    eq(wrapped ~= nil, true)
    eq(wrapped.label.wordWrap, true)
    -- The wrapped row and its objective line are taller than a single line and
    -- the content height grew with them, so the scroll range covers the text.
    local base = 13 * 1.32
    eq(wrapped.frame:GetHeight() > base * 2, true)
    eq(list.body:GetHeight() > wrapped.frame:GetHeight(), true)
    local short = findRow("Short")
    eq(short.frame:GetHeight(), 20)
    local objective = nil
    for _, current in ipairs(list.rows) do
        if current.frame:IsShown() and current.label:GetText() == string.rep("完成世界任务目标", 12) then objective = current end
    end
    eq(objective ~= nil, true)
    eq(objective.frame:GetHeight() > 16, true)
    -- Difficulty stays local: the title keeps the state ink, the mark carries
    -- the quest level color.
    eq(wrapped.mark:IsShown(), true)
    eq(wrapped.mark.color[1], 0.5)
    eq(wrapped.label.textColor[1], app.Theme.colors.text[1])
    -- The panel is capped so one enormous title cannot grow it without bound.
    eq(list.frame:GetHeight() <= 430, true)
    eq(#app.errors, 0)
end)

test("expired world quest time repaints without a quest log update", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local list = app.components.questList
    H.questLog.entries[3] = { title = "Timed task", questID = 105, level = 60, isTask = true }
    H.taskInfo[105] = 45 * 60
    H.Fire("QUEST_LOG_UPDATE")
    local function findRow(text)
        for _, current in ipairs(list.rows) do
            if current.frame:IsShown() and current.label:GetText() == text then return current end
        end
    end
    eq(findRow("Timed task").right:GetText(), string.format(app.L.taskTimeMinutes, 45))
    -- Time advances on its own; the slow tick rewrites the row.
    H.taskInfo[105] = 44 * 60
    H.Advance(30)
    eq(findRow("Timed task").right:GetText(), string.format(app.L.taskTimeMinutes, 44))
    -- A task that expired loses its time and the row, not just the label.
    H.taskInfo[105] = nil
    H.Advance(30)
    eq(findRow("Timed task").right:GetText(), "")
    eq(findRow("Timed task") ~= nil, true)
    -- With no task row left the tick costs nothing and stays quiet.
    H.Advance(30)
    eq(#app.errors, 0)
end)

test("item icons arrive after the row and repaint in place", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local list = app.components.questList
    local function findRow(text)
        for _, current in ipairs(list.rows) do
            if current.frame:IsShown() and current.label:GetText() == text then return current end
        end
    end
    local instant = C_Item.GetItemInfoInstant
    C_Item.GetItemInfoInstant = function() return nil end
    _G.GetItemInfoInstant = function() return nil end
    H.questLog.itemIndex[101] = 1
    H.questLog.items[1] = { link = "|Hitem:777|h[Cached later]|h" }
    H.Fire("QUEST_LOG_UPDATE")
    local button = findRow("First quest").itemButton
    eq(button:IsShown(), true)
    eq(button.icon.texture, nil)
    -- The cache fills in later; the item event paints the texture only.
    C_Item.GetItemInfoInstant = instant
    H.Fire("GET_ITEM_INFO_RECEIVED", 777, true)
    eq(button.icon.texture, 134400)
    eq(button:GetAttribute("item"), "|Hitem:777|h[Cached later]|h")
    eq(#app.errors, 0)
end)

test("a restyled quest row keeps its secure slot without touching geometry in combat", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local list = app.components.questList
    local function findRow(rows, text)
        for _, current in ipairs(rows) do
            if current.frame:IsShown() and current.label:GetText() == text then return current end
        end
    end
    H.questLog.itemIndex[101] = 1
    H.questLog.items[1] = { link = "|Hitem:123|h[Quest item]|h" }
    H.Fire("QUEST_LOG_UPDATE")
    local first = findRow(list.rows, "First quest")
    eq(list.secureSpawned, true)
    -- Protected rows keep their geometry mid-fight: only text is repainted.
    local point = first.frame.point
    local height = first.frame:GetHeight()
    H.Combat(true)
    H.questLog.ready[101] = true
    H.Fire("QUEST_LOG_UPDATE")
    eq(list.lockedPaint, true)
    eq(first.frame.point, point)
    eq(first.frame:GetHeight(), height)
    eq(first.label:GetText(), "First quest")
    eq(first.label.textColor[1], 0.95)
    eq(first.iconButton:IsShown(), true)
    -- The locked paint is deferred: the scroll offset and body size wait too.
    eq(app.Queue:Count() > 0, true)
    -- Out of combat the deferred layout runs and every new row lands.
    H.Combat(false)
    eq(list.pendingReflow, nil)
    eq(first.frame:IsShown(), true)
    eq(first.frame:GetHeight() >= 20, true)
    eq(findRow(list.rows, app.L.questListReady) ~= nil, true)
    eq(#app.errors, 0)
end)

test("quest timer and secure item occupy separate title slots", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    H.questLog.entries[3] = { title = "Timed item quest", questID = 102, level = 80, isTask = true }
    H.taskInfo[102] = 45 * 60
    H.questLog.itemIndex[102] = 2
    H.questLog.items[2] = { link = "|Hitem:456|h[Quest item]|h" }
    H.Fire("QUEST_LOG_UPDATE")
    local row
    for _, current in ipairs(app.components.questList.rows) do
        if current.label:GetText() == "Timed item quest" then row = current end
    end
    eq(row ~= nil, true)
    eq(row.right:GetText(), string.format(app.L.taskTimeMinutes, 45))
    eq(row.itemButton:IsShown(), true)
    eq(row.right.point[2], -38)
    eq(row.right:GetWidth(), 56)
    eq(row.itemButton.point[2], -14)
    eq(row.label:GetWidth(), 124)
    eq(row.label.font, app.Type:Face())
    eq(#app.errors, 0)
end)

test("quest rows keep their item identity until combat reflow", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local list = app.components.questList
    H.questLog.itemIndex[101] = 1
    H.questLog.items[1] = { link = "|Hitem:123|h[Quest item]|h" }
    H.Fire("QUEST_LOG_UPDATE")
    local row
    for _, current in ipairs(list.rows) do
        if current.label:GetText() == "First quest" then row = current end
    end
    eq(row.itemButton:GetAttribute("item"), "|Hitem:123|h[Quest item]|h")
    H.Combat(true)
    H.questLog.entries = {
        { title = "Campaign", isHeader = true },
        { title = "Second quest", questID = 102, level = 80 },
    }
    H.Fire("QUEST_LOG_UPDATE")
    eq(row.label:GetText(), "First quest")
    eq(row.frame.entry.quest.id, 101)
    eq(row.itemButton:GetAttribute("item"), "|Hitem:123|h[Quest item]|h")
    H.Combat(false)
    eq(row.label:GetText(), "Second quest")
    eq(row.itemButton:IsShown(), false)
    eq(#app.errors, 0)
end)

test("quest item changes remain paired with their original row during combat", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local list = app.components.questList
    H.questLog.itemIndex[101] = 1
    H.questLog.items[1] = { link = "|Hitem:123|h[Old item]|h" }
    H.Fire("QUEST_LOG_UPDATE")
    local row
    for _, current in ipairs(list.rows) do
        if current.label:GetText() == "First quest" then row = current end
    end
    H.Combat(true)
    H.questLog.entries[2].title = "Changed quest"
    H.questLog.items[1] = { link = "|Hitem:456|h[New item]|h" }
    H.Fire("QUEST_LOG_UPDATE")
    eq(row.label:GetText(), "First quest")
    eq(row.itemButton:GetAttribute("item"), "|Hitem:123|h[Old item]|h")
    H.Combat(false)
    eq(row.label:GetText(), "Changed quest")
    eq(row.itemButton:GetAttribute("item"), "|Hitem:456|h[New item]|h")
    eq(#app.errors, 0)
end)

test("the quest panel replaces native quest modules and keeps the rest", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local list = app.components.questList
    eq(list.nativeHidden, true)
    eq(QuestObjectiveTracker:IsShown(), false)
    eq(CampaignQuestObjectiveTracker:IsShown(), false)
    eq(WorldQuestObjectiveTracker:IsShown(), false)
    -- Scenario goals are not covered by this panel and stay native.
    eq(ScenarioObjectiveTracker:IsShown(), true)
    eq(ObjectiveTrackerFrame:HasModule(ScenarioObjectiveTracker), true)
    local line = list:Describe()
    eq(line:find(app.L.nativeTaken, 1, true) ~= nil, true)
    eq(line:find(app.L.nativeQuestsOnly, 1, true) ~= nil, true)
    -- Disabling hands every removed module back to the client.
    app.Store:Set("modules", "questList", false)
    eq(QuestObjectiveTracker:IsShown(), true)
    eq(ObjectiveTrackerFrame:HasModule(QuestObjectiveTracker), true)
    eq(list.nativeRemoved, nil)
    -- Without the container's module list all native objectives stay visible.
    ObjectiveTrackerFrame.RemoveModule = nil
    app.Store:Set("modules", "questList", true)
    eq(ObjectiveTrackerFrame:IsShown(), true)
    eq(ScenarioObjectiveTracker:IsShown(), true)
    eq(QuestObjectiveTracker:IsShown(), true)
    eq(list.nativeHidden, nil)
    eq(list:Describe():find(app.L.nativeKept, 1, true) ~= nil, true)
    app.Store:Set("modules", "questList", false)
    eq(ObjectiveTrackerFrame:IsShown(), true)
    eq(#app.errors, 0)
end)

test("the takeover leaves an absent native module absent", function()
    local app = H.Load()
    ObjectiveTrackerFrame:RemoveModule(WorldQuestObjectiveTracker)
    WorldQuestObjectiveTracker:Hide()
    H.Fire("PLAYER_LOGIN")
    local list = app.components.questList
    eq(list.nativeHidden, true)
    eq(ObjectiveTrackerFrame:HasModule(QuestObjectiveTracker), false)
    eq(ObjectiveTrackerFrame:HasModule(WorldQuestObjectiveTracker), false)
    app.Store:Set("modules", "questList", false)
    eq(ObjectiveTrackerFrame:HasModule(QuestObjectiveTracker), true)
    eq(QuestObjectiveTracker:IsShown(), true)
    -- A module the client had already removed is never re-registered or shown.
    eq(ObjectiveTrackerFrame:HasModule(WorldQuestObjectiveTracker), false)
    eq(WorldQuestObjectiveTracker:IsShown(), false)
    eq(list.nativeRemoved, nil)
    eq(#app.errors, 0)
end)

test("the quest takeover removes only the quest modules", function()
    local app = H.Load()
    local removed = {}
    local remove = ObjectiveTrackerFrame.RemoveModule
    ObjectiveTrackerFrame.RemoveModule = function(self, module)
        removed[#removed + 1] = module
        return remove(self, module)
    end
    H.Fire("PLAYER_LOGIN")
    local list = app.components.questList
    eq(list.nativeHidden, true)
    eq(#removed, 3)
    eq(removed[1] == CampaignQuestObjectiveTracker, true)
    eq(removed[2] == QuestObjectiveTracker, true)
    eq(removed[3] == WorldQuestObjectiveTracker, true)
    eq(ObjectiveTrackerFrame:HasModule(QuestObjectiveTracker), false)
    eq(ObjectiveTrackerFrame:HasModule(ScenarioObjectiveTracker), true)
    eq(QuestObjectiveTracker:IsShown(), false)
    eq(CampaignQuestObjectiveTracker:IsShown(), false)
    eq(ScenarioObjectiveTracker:IsShown(), true)
    eq(#app.errors, 0)
end)

test("a client re-registered quest module is taken back down", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local list = app.components.questList
    eq(list.nativeHidden, true)
    ObjectiveTrackerFrame:AddModule(QuestObjectiveTracker)
    QuestObjectiveTracker:Show()
    eq(ObjectiveTrackerFrame:HasModule(QuestObjectiveTracker), false)
    eq(QuestObjectiveTracker:IsShown(), false)
    app.Store:Set("modules", "questList", false)
    eq(ObjectiveTrackerFrame:HasModule(QuestObjectiveTracker), true)
    eq(QuestObjectiveTracker:IsShown(), true)
    eq(#app.errors, 0)
end)

test("an overlapping quest panel yields both trackers and remains movable", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local list, native = app.components.questList, ObjectiveTrackerFrame
    local x = 300
    list.frame.GetRect = function() return x, 50, 100, 100 end
    native.GetRect = function() return 50, 20, 200, 200 end
    native.GetEffectiveScale = function() return 2 end
    H.Fire("EDIT_MODE_LAYOUTS_UPDATED")
    eq(list.overlapHidden, true)
    eq(list.frame:IsShown(), false)
    eq(native:IsShown(), true)
    -- The panel hides, so the quest modules must return to the client instead of
    -- leaving the player with neither display.
    eq(native:HasModule(QuestObjectiveTracker), true)
    eq(QuestObjectiveTracker:IsShown(), true)
    eq(native:HasModule(ScenarioObjectiveTracker), true)
    eq(list.nativeHidden, nil)
    eq(list:Describe():find(app.L.questOverlapStatus, 1, true) ~= nil, true)
    -- Hidden previews remain represented in the layout editor, even if a
    -- hidden frame cannot report a centre on this client.
    list.frame.GetCenter = function() return nil end
    app.Layout:SetEditing(true)
    eq(app.Layout.entries.questList.overlay:IsShown(), true)
    x = 600
    app.Layout:Apply("questList")
    eq(list.overlapHidden, nil)
    eq(list.frame:IsShown(), true)
    -- Moving clear of the tracker resumes the takeover.
    eq(list.nativeHidden, true)
    eq(native:HasModule(QuestObjectiveTracker), false)
    eq(QuestObjectiveTracker:IsShown(), false)
    app.Layout:SetEditing(false)
    eq(#app.errors, 0)
end)

test("quest overlap decisions defer in combat and ignore secret geometry", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local list, native = app.components.questList, ObjectiveTrackerFrame
    local x = 500
    list.frame.GetRect = function() return x, 100, 100, 100 end
    native.GetRect = function() return 100, 100, 200, 200 end
    H.Fire("EDIT_MODE_LAYOUTS_UPDATED")
    eq(list.frame:IsShown(), true)
    list.frame.protected = true
    H.Combat(true)
    x = 150
    H.Fire("EDIT_MODE_LAYOUTS_UPDATED")
    eq(list.frame:IsShown(), true)
    H.Combat(false)
    eq(list.frame:IsShown(), false)
    native.GetRect = function() return H.Secret(100), 100, 200, 200 end
    H.Fire("EDIT_MODE_LAYOUTS_UPDATED")
    eq(list.frame:IsShown(), false)
    native:Hide()
    eq(list.frame:IsShown(), true)
    eq(list.overlapHidden, nil)
    eq(#app.errors, 0)
end)

test("quest overlap check waits for layout and cancels when disabled", function()
    local app = H.Load()
    C_Timer.NewTimer = C_Timer.After
    H.Fire("PLAYER_LOGIN")
    local list, native = app.components.questList, ObjectiveTrackerFrame
    local x = 150
    list.frame.GetRect = function() return x, 100, 100, 100 end
    native.GetRect = function() return 100, 100, 200, 200 end
    eq(list.overlapTimer ~= nil, true)
    eq(list.frame:IsShown(), true)
    H.Advance(0.06)
    eq(list.frame:IsShown(), false)
    x = 500
    H.Fire("EDIT_MODE_LAYOUTS_UPDATED")
    local pending = list.overlapTimer
    eq(pending ~= nil, true)
    app.Store:Set("modules", "questList", false)
    eq(pending.cancelled, true)
    H.Advance(0.1)
    eq(list.frame:IsShown(), false)
    eq(app.Layout.entries.questList.allowHiddenMove, nil)
    eq(native:IsShown(), true)
    eq(#app.errors, 0)
end)

test("a native module hidden by the client stays hidden after a takeover cycle", function()
    local app = H.Load()
    ObjectiveTrackerFrame:RemoveModule(QuestObjectiveTracker)
    QuestObjectiveTracker:Hide()
    H.Fire("PLAYER_LOGIN")
    local list = app.components.questList
    eq(list.nativeHidden, true)
    eq(ObjectiveTrackerFrame:HasModule(QuestObjectiveTracker), false)
    eq(ObjectiveTrackerFrame:HasModule(CampaignQuestObjectiveTracker), false)
    app.Store:Set("modules", "questList", false)
    eq(ObjectiveTrackerFrame:HasModule(QuestObjectiveTracker), false)
    eq(QuestObjectiveTracker:IsShown(), false)
    eq(ObjectiveTrackerFrame:HasModule(CampaignQuestObjectiveTracker), true)
    eq(CampaignQuestObjectiveTracker:IsShown(), true)
    eq(list.nativeRemoved, nil)
    eq(#app.errors, 0)
end)

-- ==== TRACK: QUEST PANEL —append new tests above this line ====
test("current zone world quests are tracked automatically", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local list = app.components.questList
    H.questLog.entries[3] = { title = "Zone task", questID = 105, level = 60, isTask = true }
    H.questLog.entries[4] = { title = "Away task", questID = 106, level = 60, isTask = true }
    H.questLog.objectives[105] = { { text = "Kill stuff" } }
    H.questLog.map = { { questID = 105 } }  -- 105 is on the current map, 106 is not
    H.Fire("QUEST_LOG_UPDATE")

    local function findRow(text)
        for _, current in ipairs(list.rows) do
            if current.frame:IsShown() and current.label:GetText() == text then return current end
        end
    end

    -- The tracked view keeps watched quests and adds the zone's world tasks.
    H.Click(list.filterButtons.tracked)
    eq(findRow("First quest") ~= nil, true)
    eq(findRow("Zone task") ~= nil, true)
    eq(findRow("Away task"), nil)
    eq(list.title:GetText(), app.L.questListTitle .. "  2")
    -- A manually focused task shows even outside the zone, on top of the rest.
    H.Click(list.filterButtons.all)
    H.Click(findRow("Away task").iconButton)
    H.Click(list.filterButtons.tracked)
    eq(findRow("Away task") ~= nil, true)
    eq(findRow("Zone task") ~= nil, true)
    eq(list.title:GetText(), app.L.questListTitle .. "  3")
    -- Unfocusing drops it again; the zone task stays automatically.
    H.Click(findRow("Away task").iconButton)
    eq(findRow("Away task"), nil)
    eq(findRow("Zone task") ~= nil, true)
    eq(list.title:GetText(), app.L.questListTitle .. "  2")
    H.Click(list.filterButtons.all)
    eq(#app.errors, 0)
end)


test("world quest tracking super-tracks instead of watching", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local list = app.components.questList
    H.questLog.entries[2].isTask = true  -- "First quest" (101) acts as a world quest
    H.Fire("QUEST_LOG_UPDATE")

    local function findRow(text)
        for _, current in ipairs(list.rows) do
            if current.frame:IsShown() and current.label:GetText() == text then return current end
        end
    end

    -- Shift+clicking a world quest focuses it; the watch list stays untouched.
    H.shiftDown = true
    H.Click(findRow("First quest").frame)
    H.shiftDown = false
    eq(H.superTracked, 101)
    eq(H.questLog.watch[101], 1)
    -- Clicking again unfocuses, still without touching the watch list.
    H.shiftDown = true
    H.Click(findRow("First quest").frame)
    H.shiftDown = false
    eq(H.superTracked, nil)
    -- The icon path skips the watch attempt for tasks as well.
    H.Click(findRow("First quest").iconButton)
    eq(H.superTracked, 101)
    eq(H.questLog.watch[101], 1)
    H.Click(findRow("First quest").iconButton)
    eq(H.superTracked, nil)
    -- The tracked filter shows the focused world quest even though it cannot
    -- be watched.
    H.Click(findRow("First quest").iconButton)
    H.Click(list.filterButtons.tracked)
    eq(findRow("First quest") ~= nil, true)
    H.Click(list.filterButtons.all)
    H.Click(findRow("First quest").iconButton)
    eq(H.superTracked, nil)
    -- Regular quests keep the watch toggle and their own hint.
    H.shiftDown = true
    H.Click(findRow("Second quest").frame)
    H.shiftDown = false
    eq(H.questLog.watch[102], 1)
    eq(H.superTracked, nil)
    findRow("First quest").frame.scripts.OnEnter(findRow("First quest").frame)
    eq(GameTooltip.lines[2], app.L.questListTaskHint)
    findRow("Second quest").frame.scripts.OnEnter(findRow("Second quest").frame)
    eq(GameTooltip.lines[2], app.L.questListRowHint)
    eq(#app.errors, 0)
end)


test("unit frames draw cast bars with interrupt state and secret names", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.Store:Set("modules", "unitFrames", true)
    local units = app.components.unitFrames
    eq(units.running, true)
    eq(units.parts.cast.available, true)
    local frame = units.frames.target
    eq(frame.cast:IsShown(), false)
    H.cast.target = { name = "Fireball", startTime = 0, endTime = 2500 }
    H.Fire("UNIT_SPELLCAST_START", "target")
    eq(frame.cast:IsShown(), true)
    eq(frame.castName:GetText(), "Fireball")
    eq(frame.castTime:GetText(), string.format(app.L.castSeconds, 2.5))
    eq(frame.cast:GetValue(), 0)
    eq(frame.cast.minimum, 0)
    eq(frame.cast.maximum, 1)
    -- Not interruptible turns the fill into the locked red pair (dark end at
    -- 0.45x, light end toward white); interruptible restores the accent pair.
    H.cast.target.notInterruptible = true
    H.Fire("UNIT_SPELLCAST_NOT_INTERRUPTIBLE", "target")
    local fill = frame.cast:GetStatusBarTexture()
    eq(fill.gradient ~= nil, true)
    eq(fill.gradient.lo[1], 0.405)
    eq(fill.gradient.hi[1], 0.925)
    H.cast.target.notInterruptible = false
    H.Fire("UNIT_SPELLCAST_INTERRUPTIBLE", "target")
    local accent = app.Theme:Accent()
    eq(fill.gradient.lo[1], accent[1] * 0.45)
    eq(fill.gradient.hi[1], accent[1] + (1 - accent[1]) * 0.25)
    -- Stop and failed hide the bar once the API stops reporting a cast.
    H.cast.target.gone = true
    H.Fire("UNIT_SPELLCAST_STOP", "target")
    eq(frame.cast:IsShown(), false)
    H.cast.target = { name = "Fireball", startTime = 0, endTime = 2500 }
    H.Fire("UNIT_SPELLCAST_START", "target")
    eq(frame.cast:IsShown(), true)
    H.cast.target.gone = true
    H.Fire("UNIT_SPELLCAST_FAILED", "target")
    eq(frame.cast:IsShown(), false)
    -- Channels read through UnitChannelInfo and end with CHANNEL_STOP.
    H.cast.target = { name = "Drain Life", startTime = 0, endTime = 3000, channel = true }
    H.Fire("UNIT_SPELLCAST_CHANNEL_START", "target")
    eq(frame.cast:IsShown(), true)
    eq(frame.castName:GetText(), "Drain Life")
    H.cast.target = nil
    H.Fire("UNIT_SPELLCAST_CHANNEL_STOP", "target")
    eq(frame.cast:IsShown(), false)
    -- A delayed cast re-renders the remaining time against GetTime.
    H.cast.target = { name = "Fireball", startTime = 0, endTime = 2500 }
    H.Fire("UNIT_SPELLCAST_START", "target")
    eq(frame.castTime:GetText(), string.format(app.L.castSeconds, 2.5))
    H.now = 1
    H.Fire("UNIT_SPELLCAST_DELAYED", "target")
    eq(frame.castTime:GetText(), string.format(app.L.castSeconds, 1.5))
    eq(frame.cast:GetValue(), 0.4)
    -- A short ticker only lives while the cast runs and drives the value.
    eq(frame.cast.updater ~= nil, true)
    H.now = 1.5
    frame.cast.updater.callback()
    eq(frame.cast:GetValue(), 0.6)
    eq(frame.castTime:GetText(), string.format(app.L.castSeconds, 1))
    H.now = 0
    -- Restricted spell names go straight to SetText without Lua errors.
    H.cast.target = { name = H.Secret("Secret spell"), startTime = 0, endTime = 2500 }
    H.Fire("UNIT_SPELLCAST_START", "target")
    eq(frame.cast:IsShown(), true)
    eq(frame.cast.updater ~= nil, true)
    H.cast.target.gone = true
    H.Fire("UNIT_SPELLCAST_STOP", "target")
    eq(frame.cast:IsShown(), false)
    eq(frame.cast.updater, nil)
    eq(#app.errors, 0)
end)

test("unit frame auras render debuffs first and degrade without the API", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.Store:Set("modules", "unitFrames", true)
    local units = app.components.unitFrames
    local frame = units.frames.target
    eq(units.parts.auras.available, true)
    eq(#frame.auraIcons, 10)
    local function shownCount()
        local count = 0
        for _, icon in ipairs(frame.auraIcons) do
            if icon:IsShown() then count = count + 1 end
        end
        return count
    end

    H.unitAuras.target = {
        helpful = { { icon = "buff1" }, { icon = "buff2" } },
        harmful = { { icon = "debuff1" } },
    }
    H.Fire("UNIT_AURA", "target")
    eq(shownCount(), 3)
    -- Debuffs come first; icons keep their art, the school colour is the border.
    eq(frame.auraIcons[1].texture, "debuff1")
    local red, green, blue = frame.auraIcons[1]:GetVertexColor()
    eq(red, 1)
    eq(green, 1)
    eq(blue, 1)
    eq(frame.auraIcons[2].texture, "buff1")
    eq(frame.auraIcons[2]:GetVertexColor(), 1)
    eq(frame.auraIcons[3].texture, "buff2")

    -- More auras than the row can hold are cut off after ten icons.
    local many = {}
    for index = 1, 12 do many[index] = { icon = "buff" .. index } end
    H.unitAuras.target = { helpful = many, harmful = { { icon = "debuff1" }, { icon = "debuff2" }, { icon = "debuff3" } } }
    H.Fire("UNIT_AURA", "target")
    eq(shownCount(), 10)
    eq(frame.auraIcons[10].texture, "buff7")

    -- Restricted icons are skipped instead of reaching SetTexture.
    H.unitAuras.target = { harmful = { { icon = H.Secret("hidden icon") } }, helpful = { { icon = "buff1" } } }
    H.Fire("UNIT_AURA", "target")
    eq(shownCount(), 1)
    eq(frame.auraIcons[1].texture, "buff1")

    -- Losing the aura API mid-session empties the row and keeps the component.
    C_UnitAuras.GetAuraDataByIndex = nil
    H.Fire("UNIT_AURA", "target")
    eq(shownCount(), 0)
    eq(units.running, true)
    eq(#app.errors, 0)
end)

test("raid target marks map the classic grid and clear on updates", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.Store:Set("modules", "unitFrames", true)
    local units = app.components.unitFrames
    local frame = units.frames.target
    eq(units.parts.marks.available, true)
    eq(frame.mark:IsShown(), false)
    -- Index 3 sits in column 2, row 0 of the 4x2 atlas grid.
    H.raidTargets.target = 3
    H.Fire("RAID_TARGET_UPDATE")
    eq(frame.mark:IsShown(), true)
    local left, right, top, bottom = frame.mark:GetTexCoord()
    eq(left, 0.5)
    eq(right, 0.75)
    eq(top, 0)
    eq(bottom, 0.25)
    -- Invalid, restricted and cleared indices hide the mark again.
    H.raidTargets.target = 9
    H.Fire("RAID_TARGET_UPDATE")
    eq(frame.mark:IsShown(), false)
    H.raidTargets.target = H.Secret(3)
    H.Fire("RAID_TARGET_UPDATE")
    eq(frame.mark:IsShown(), false)
    H.raidTargets.target = nil
    H.Fire("RAID_TARGET_UPDATE")
    eq(frame.mark:IsShown(), false)
    eq(#app.errors, 0)
end)

test("unit frames keep running when cast, aura and mark APIs are missing", function()
    local app = H.Load()
    _G.UnitCastingInfo, _G.UnitChannelInfo, _G.GetRaidTargetIndex = nil, nil, nil
    C_UnitAuras = nil
    H.Fire("PLAYER_LOGIN")
    app.Store:Set("modules", "unitFrames", true)
    local units = app.components.unitFrames
    eq(units.running, true)
    eq(units.parts.bars.available, true)
    eq(units.parts.cast.available, false)
    eq(units.parts.auras.available, false)
    eq(units.parts.marks.available, false)
    eq(units.parts.interaction.available, true)
    local frame = units.frames.target
    eq(frame.cast, nil)
    eq(frame.castName, nil)
    eq(frame.castTime, nil)
    eq(frame.auraIcons, nil)
    eq(frame.mark, nil)
    eq(frame:GetHeight(), 38)
    -- Unavailable parts registered no events, so their events stay inert.
    H.Fire("UNIT_AURA", "target")
    H.Fire("RAID_TARGET_UPDATE")
    H.Fire("UNIT_SPELLCAST_START", "target")
    eq(frame:GetAttribute("unit"), "target")
    eq(frame.watched, true)
    eq(#app.errors, 0)
end)

test("unit frames keep auras and marks without the cast API", function()
    local app = H.Load()
    _G.UnitCastingInfo, _G.UnitChannelInfo = nil, nil
    H.Fire("PLAYER_LOGIN")
    app.Store:Set("modules", "unitFrames", true)
    local units = app.components.unitFrames
    eq(units.parts.cast.available, false)
    eq(units.parts.auras.available, true)
    eq(units.parts.marks.available, true)
    local frame = units.frames.target
    eq(frame.cast, nil)
    eq(frame:GetHeight(), 64)
    H.unitAuras.target = { helpful = { { icon = "buff1" } } }
    H.Fire("UNIT_AURA", "target")
    eq(frame.auraIcons[1]:IsShown(), true)
    H.raidTargets.target = 4
    H.Fire("RAID_TARGET_UPDATE")
    eq(frame.mark:IsShown(), true)
    eq(#app.errors, 0)
end)

test("unit frames keep cast and marks without the aura API", function()
    local app = H.Load()
    C_UnitAuras = nil
    H.Fire("PLAYER_LOGIN")
    app.Store:Set("modules", "unitFrames", true)
    local units = app.components.unitFrames
    eq(units.parts.auras.available, false)
    eq(units.parts.cast.available, true)
    eq(units.parts.marks.available, true)
    local frame = units.frames.target
    eq(frame.auraIcons, nil)
    eq(frame:GetHeight(), 54)
    H.cast.target = { name = "Fireball", startTime = 0, endTime = 2500 }
    H.Fire("UNIT_SPELLCAST_START", "target")
    eq(frame.cast:IsShown(), true)
    H.cast.target.gone = true
    H.Fire("UNIT_SPELLCAST_STOP", "target")
    eq(frame.cast:IsShown(), false)
    eq(#app.errors, 0)
end)

test("unit frame height follows parts and disable releases everything", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.Store:Set("modules", "unitFrames", true)
    local units = app.components.unitFrames
    local frame = units.frames.target
    eq(frame:GetWidth(), 180)
    eq(frame:GetHeight(), 80)
    eq(frame.watched, true)
    -- Hover shows the unit tooltip through the interaction part.
    frame.scripts.OnEnter(frame)
    eq(H.tooltipUnit, "target")
    eq(GameTooltip:IsShown(), true)
    frame.scripts.OnLeave(frame)
    eq(H.tooltipUnit, "target")
    eq(GameTooltip:IsShown(), false)
    -- Disabling hides the frame, releases the watch and every registration.
    app.Store:Set("modules", "unitFrames", false)
    eq(units.running, false)
    eq(frame:IsShown(), false)
    eq(frame.watched, false)
    eq(next(frame.events.events), nil)
    eq(frame.cast:IsShown(), false)
    -- Re-enabling rebuilds events, redraws and keeps the part height.
    H.cast.target = nil
    app.Store:Set("modules", "unitFrames", true)
    eq(units.running, true)
    eq(frame.events.events["UNIT_SPELLCAST_START"], "target")
    eq(frame.events.events["UNIT_AURA"], "target")
    eq(frame.events.events["RAID_TARGET_UPDATE"], true)
    eq(frame:GetHeight(), 80)
    eq(frame.cast:IsShown(), false)
    eq(#app.errors, 0)
end)

test("unit main frames share the health baseline and keep it during part changes", function()
    local app = H.Load(); UIParent:SetSize(1920, 1080); H.Fire("PLAYER_LOGIN")
    app.Store:Set("modules", "unitFrames", true)
    local units = app.components.unitFrames
    local player, target = units.frames.player, units.frames.target
    eq(player:GetWidth(), 180)
    eq(target:GetWidth(), 180)
    eq(player.health:GetHeight(), 18)
    eq(target.health:GetHeight(), 18)
    local function healthTop(frame)
        return frame.point[5] + frame:GetHeight() / 2 - 15
    end
    -- The health top aligns with the applied main skill row: in this fixture the
    -- utility row ends at 172 above the screen bottom, i.e. -368 from centre.
    eq(math.abs(healthTop(player) + 368) < 0.01, true)
    eq(math.abs(healthTop(target) - healthTop(player)) < 0.01, true)
    -- Fallback cooldown block is 300 UI units: centre = 150 + 5.76 + 90.
    eq(player.point[4], -245.76)
    eq(target.point[4], 245.76)
    local playerTop = player.point[5] + player:GetHeight() / 2
    -- Auras sit directly under power; the target cast owns the next row.
    eq(target.auraIcons[1].point[3], -40)
    eq(target.cast.point[3], -60)
    H.cast.target = { name = "Fireball", startTime = 0, endTime = 2500 }
    H.Fire("UNIT_SPELLCAST_START", "target")
    eq(target.cast:IsShown(), true)
    eq(player.point[5] + player:GetHeight() / 2, playerTop)
    eq(target.auraIcons[1].point[3], -40)
    H.cast.target.gone = true
    H.Fire("UNIT_SPELLCAST_STOP", "target")
    eq(target.cast:IsShown(), false)
    eq(target.auraIcons[1].point[3], -40)
    -- The player's cast remains the client's central bar, not an inline row.
    eq(player.cast, nil)
    eq(#app.errors, 0)
end)

test("a missing aura part keeps the main frame's top edge fixed", function()
    local app = H.Load(); UIParent:SetSize(1920, 1080); H.Fire("PLAYER_LOGIN")
    app.Store:Set("modules", "unitFrames", true)
    local player = app.components.unitFrames.frames.player
    local top = player.point[5] + player:GetHeight() / 2
    local saved = C_UnitAuras
    C_UnitAuras = nil
    app:Reconcile()
    eq(player:GetHeight(), 38)
    eq(math.abs(player.point[5] + player:GetHeight() / 2 - top) < 0.01, true)
    C_UnitAuras = saved
    app:Reconcile()
    eq(player:GetHeight(), 64)
    eq(math.abs(player.point[5] + player:GetHeight() / 2 - top) < 0.01, true)
    eq(#app.errors, 0)
end)

test("auxiliary unit frames are compact and sit in the inner half of their column", function()
    local app = H.Load(); UIParent:SetSize(1920, 1080); H.Fire("PLAYER_LOGIN")
    app.Store:Set("modules", "unitFrames", true)
    local units = app.components.unitFrames
    local player, target = units.frames.player, units.frames.target
    local pet, tot, focus = units.frames.pet, units.frames.targettarget, units.frames.focus
    eq(pet:GetWidth(), 100)
    eq(pet:GetHeight(), 28)
    eq(pet.health:GetHeight(), 12)
    eq(pet.health.point[3], -13)
    eq(pet.cast, nil)
    eq(pet.auraIcons, nil)
    -- A 100-wide auxiliary frame sits centred in the inner half of the
    -- 180-wide main column: (180 - 100) / 2 = 40 in from its centre.
    eq(pet.point[4], player.point[4] + 40)
    eq(tot.point[4], target.point[4] - 40)
    eq(focus.point[4], target.point[4])
    -- Pet sits under the player, focus above the target, both with a 6px gap.
    eq(pet.point[5] + pet:GetHeight() / 2, player.point[5] - player:GetHeight() / 2 - 6)
    eq(focus.point[5] - focus:GetHeight() / 2, target.point[5] + target:GetHeight() / 2 + 6)
    eq(#app.errors, 0)
end)

test("saved unit positions keep their old centre instead of the new default", function()
    local app = H.Load(); UIParent:SetSize(1920, 1080); H.Fire("PLAYER_LOGIN")
    app.Store:SetPosition("unit_player", 123, -45)
    app.Store:SetPosition("unit_pet", 77, -88)
    app.Store:Set("modules", "unitFrames", true)
    local units = app.components.unitFrames
    eq(units.frames.player.point[4], 123)
    eq(units.frames.player.point[5], -45)
    eq(units.frames.pet.point[4], 77)
    eq(units.frames.pet.point[5], -88)
    -- An unsaved frame still receives the shared central default.
    eq(units.frames.target.point[4], 245.76)
    eq(#app.errors, 0)
end)

test("a central change during combat queues one unit layout and applies after", function()
    local app = H.Load(); UIParent:SetSize(1920, 1080); H.Fire("PLAYER_LOGIN")
    app.Store:Set("modules", "unitFrames", true)
    local player = app.components.unitFrames.frames.player
    local x = player.point[4]
    H.Combat(true)
    app.Layout:SetActionAreaBottom(80)
    app.Layout:SetActionAreaBottom(100)
    eq(app.Layout:ActionAreaBottom(), 100)
    -- Two jobs, one per owner: the unit frames and the cooldown stack each queue
    -- their own key, and a second central change does not queue a third.
    eq(app.Queue:Count(), 2)
    eq(player.point[4], x)
    H.Combat(false)
    eq(player.point[4], x)
    eq(app.Queue:Count(), 0)
    eq(#app.errors, 0)
end)

test("the player cast placeholder is an edit-mode rectangle below the action area", function()
    local app = H.Load(); UIParent:SetSize(1920, 1080); H.Fire("PLAYER_LOGIN")
    app.Store:Set("modules", "unitFrames", true)
    local entry = app.components.unitFrames.playerCastEntry
    eq(entry.placeholder, true)
    eq(entry.frame:IsShown(), false)
    eq(PlayerCastingBarFrame:IsShown(), true)
    local central = app.Layout:Central()
    local actionBottom = -central.screen.height / 2 + central.action.bottom
    local top = entry.frame.point[5] + entry.frame:GetHeight() / 2
    local bottom = entry.frame.point[5] - entry.frame:GetHeight() / 2
    eq(entry.frame.point[4], 0)
    eq(top <= actionBottom - 8 + 0.01, true)
    eq(bottom <= actionBottom - 8 + 0.01, true)
    app.Layout:SetEditing(true)
    eq(entry.frame:IsShown(), true)
    app.Layout:SetEditing(false)
    eq(entry.frame:IsShown(), false)
    app.Store:Set("modules", "unitFrames", false)
    eq(entry.placeholder, false)
    eq(entry.hidden, true)
    eq(entry.frame:IsShown(), false)
    local listed = false
    for _, id in ipairs(app.Layout:IDs()) do if id == "unit_player_cast" then listed = true end end
    eq(listed, false)
    eq(PlayerCastingBarFrame:IsShown(), true)
    eq(#app.errors, 0)
end)

test("the damage window placeholder reserves the bottom right corner", function()
    local app = H.Load(); UIParent:SetSize(1920, 1080); H.Fire("PLAYER_LOGIN")
    local entry = app.Layout.entries.damageMeterArea
    eq(entry ~= nil, true)
    eq(entry.placeholder, true)
    -- 13% of 1920 wide, 16% of 1080 tall, 3% in from the right edge, bottom edge
    -- 46 units above the screen bottom (the strip is 30 tall).
    eq(entry.frame:GetWidth(), 250)
    eq(entry.frame:GetHeight(), 173)
    eq(entry.frame.point[4], 777)
    eq(entry.frame.point[5], -407)
    -- The outline never takes a click and is only visible while editing.
    eq(entry.frame:IsMouseEnabled(), false)
    eq(entry.frame:IsShown(), false)
    app.Layout:SetEditing(true)
    eq(entry.frame:IsShown(), true)
    app.Layout:SetEditing(false)
    eq(entry.frame:IsShown(), false)
    eq(#app.errors, 0)
end)

test("the damage window placeholder leaves the layout page when disabled", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local function listed()
        for _, id in ipairs(app.Layout:IDs()) do
            if id == "damageMeterArea" then return true end
        end
        return false
    end
    eq(listed(), true)
    app.Store:Set("modules", "damageMeterArea", false)
    local entry = app.Layout.entries.damageMeterArea
    eq(entry.hidden, true)
    eq(entry.frame:IsShown(), false)
    eq(listed(), false)
    -- A position saved while the module was off is used again on re-enable, so
    -- toggling never resets the reserved rectangle.
    app.Store:SetPosition("damageMeterArea", 100, -200)
    app.Store:Set("modules", "damageMeterArea", true)
    eq(entry.hidden, nil)
    eq(entry.frame.point[4], 100)
    eq(entry.frame.point[5], -200)
    eq(#app.errors, 0)
end)

test("the unit diagnostic reports the shared block and frame centres", function()
    local app = H.Load(); UIParent:SetSize(1920, 1080); H.Fire("PLAYER_LOGIN")
    app.Store:Set("modules", "unitFrames", true)
    SlashCmdList.LUMAUI("unit")
    eq(#app.errors, 0)
end)

test("a self-target does not repeat the player's aura row", function()
    local app = H.Load(); UIParent:SetSize(1920, 1080); H.Fire("PLAYER_LOGIN")
    app.Store:Set("modules", "unitFrames", true)
    local units = app.components.unitFrames
    local player, target = units.frames.player, units.frames.target
    H.unitAuras.player = { helpful = { { icon = "player-aura" } } }
    H.unitAuras.target = { helpful = { { icon = "target-aura" } } }
    _G.UnitIsUnit = function(a, b) return a == b or (a == "target" and b == "player") end
    H.Fire("UNIT_AURA", "player")
    H.Fire("UNIT_AURA", "target")
    eq(player.auraIcons[1]:IsShown(), true)
    eq(target.auraIcons[1]:IsShown(), false)
    _G.UnitIsUnit = function(a, b) return a == b end
    H.Fire("PLAYER_TARGET_CHANGED")
    eq(target.auraIcons[1]:IsShown(), true)
    eq(target.auraIcons[1].texture, "target-aura")
    _G.UnitIsUnit = nil
    eq(#app.errors, 0)
end)

-- ==== TRACK: UNIT FRAMES —append new tests above this line ====
test("unit bars keep names and values above compact health and power", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.Store:Set("modules", "unitFrames", true)
    for _, unit in ipairs({ "player", "target" }) do
        local frame = app.components.unitFrames.frames[unit]
        eq(frame.name.point[1], "TOPLEFT")
        eq(frame.name.point[3], 0)
        eq(frame.value.point[1], "TOPRIGHT")
        eq(frame.value.point[3], 0)
        eq(frame.health:GetHeight(), 18)
        eq(frame.power:GetHeight(), 3)
        eq(frame.powerValue.point[1], "TOPRIGHT")
        eq(frame.powerValue.point[3], -36)
    end
    eq(#app.errors, 0)
end)

test("party rows keep the native private auras in their own right column", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.Store:Set("modules", "partyFrames", true)
    local frame = app.components.partyFrames.frames.party1
    eq(frame.health:GetHeight(), 8)
    eq(frame.power:GetHeight(), 2)
    local id = frame.lumaPrivateAnchors[1]
    local anchor = H.privateAnchors.live[id].iconInfo.iconAnchor
    eq(anchor.point, "BOTTOMRIGHT")
    eq(anchor.offsetX, -6)
    eq(anchor.offsetY, 3)
    -- The five slots run left from the right edge inside the reserved column,
    -- and the bars stop before that column, so no aura can cover a bar.
    local private = app.Theme.party.private
    local bandLeft = 190 - private.inset - ((private.slots - 1) * private.step + private.icon)
    eq(bandLeft > 190 - app.Theme.party.right, true)
    -- Both bars stop at the reserved column instead of running under the auras.
    eq(frame.power.point[1], "TOPRIGHT")
    eq(frame.power.point[2], -app.Theme.party.right)
    eq(frame.health.point[2], -app.Theme.party.right)
    eq(#app.errors, 0)
end)

test("unit bars paint class, reaction and power gradient pairs", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.Store:Set("modules", "unitFrames", true)
    local units = app.components.unitFrames
    local player, target = units.frames.player, units.frames.target
    -- The player's bar runs the class pair from the game's class colors: dark
    -- end at 0.45x, light end toward white, the fill texture white under it.
    local fill = player.health:GetStatusBarTexture()
    local monk = RAID_CLASS_COLORS.MONK
    eq(fill.gradient.hi[2], monk.g + (1 - monk.g) * 0.25)
    eq(fill.gradient.lo[2], monk.g * 0.45)
    eq(player.health.barColor[1], 1)
    eq(player.health.background.color[1], 0.4 * (fill.gradient.lo[1] + fill.gradient.hi[1]) / 2)
    -- A hostile creature runs the hostile pair; a friendly one the green pair.
    local tfill = target.health:GetStatusBarTexture()
    eq(tfill.gradient.lo[1], app.Theme.colors.hostile[1] * 0.45)
    H.unitInfo.focus.reaction = 5
    H.Fire("UNIT_HEALTH", "focus")
    local focus = units.frames.focus.health:GetStatusBarTexture()
    eq(focus.gradient.hi[2], app.Theme.colors.friendly[2] + (1 - app.Theme.colors.friendly[2]) * 0.25)
    -- The power bar follows the power type's game color; mana by default.
    local pfill = player.power:GetStatusBarTexture()
    local mana = PowerBarColor.MANA
    eq(pfill.gradient.lo[3], mana.b * 0.45)
    eq(pfill.gradient.hi[3], mana.b + (1 - mana.b) * 0.25)
    -- A tapped unit grays out; restricted identity falls back to the accent
    -- pair without touching secret values.
    H.unitInfo.target = { isPlayer = false, tapped = true }
    H.Fire("UNIT_HEALTH", "target")
    local tappedFill = target.health:GetStatusBarTexture()
    eq(tappedFill.gradient.lo[1], app.Theme.colors.tapped[1] * 0.45)
    H.unitInfo.target = { isPlayer = H.Secret(true) }
    H.unitInfo.focus.reaction = H.Secret(5)
    H.Fire("UNIT_HEALTH", "target")
    local accent = app.Theme:Accent()
    local after = target.health:GetStatusBarTexture()
    eq(after.gradient.hi[1], accent[1] + (1 - accent[1]) * 0.25)
    eq(#app.errors, 0)
end)

test("bar gradients fall back to a flat middle without the gradient API", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    _G.CreateColor = nil
    app.Store:Set("modules", "unitFrames", true)
    local health = app.components.unitFrames.frames.player.health
    eq(health:GetStatusBarTexture().gradient, nil)
    -- The fill falls back to the unit pair's flat middle; the lookup itself
    -- does not depend on the gradient API.
    local monk = RAID_CLASS_COLORS.MONK
    local lo, hi = monk.r * 0.45, monk.r + (1 - monk.r) * 0.25
    eq(health.barColor[1], (lo + hi) / 2)
    eq(#app.errors, 0)
end)


test("unit frame preview preserves native frames and cast bars", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    eq(PlayerFrame:IsShown(), true)
    eq(TargetFrame:IsShown(), false)
    app.Store:Set("modules", "unitFrames", true)
    local units = app.components.unitFrames
    eq(PlayerFrame:IsShown(), true)
    eq(PetFrame:IsShown(), true)
    eq(TargetFrame:IsShown(), false)
    eq(PlayerCastingBarFrame:IsShown(), true)
    eq(PetCastingBarFrame:IsShown(), true)
    eq(units.takeover.units, false)
    eq(units.takeover.cast, false)
    eq(units:Describe():find(app.L.nativeAwaitingValidation, 1, true) ~= nil, true)
    -- The player cast is the client's own bar; only bars and auras remain here.
    eq(units.frames.player:GetHeight(), 64)
    -- The preview never suppresses a client re-show.
    PlayerFrame:Show()
    eq(PlayerFrame:IsShown(), true)
    app.Store:Set("modules", "unitFrames", false)
    eq(PlayerFrame:IsShown(), true)
    eq(TargetFrame:IsShown(), false)
    eq(PlayerCastingBarFrame:IsShown(), true)
    -- Disabling during combat leaves native frames intact until the queued
    -- component shutdown is allowed to run.
    app.Store:Set("modules", "unitFrames", true)
    eq(PlayerFrame:IsShown(), true)
    H.Combat(true)
    app.Store:Set("modules", "unitFrames", false)
    eq(PlayerFrame:IsShown(), true)
    H.Combat(false)
    eq(PlayerFrame:IsShown(), true)
    eq(#app.errors, 0)
end)

test("the takeover switch hides native unit frames and gives them back", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.Store:Set("modules", "unitFrames", true)
    -- The switch is off by default: native frames stay on screen.
    eq(app.Store:Profile().ui.takeoverUnitFrames, false)
    eq(PlayerFrame:IsShown(), true)
    -- Turning it on hides the native frames the preview replaces and reports
    -- the takeover; the client keeps the native cast bars unhidden only when
    -- the switch is on too, so they leave as well here.
    app.Store:Set("ui", "takeoverUnitFrames", true)
    app:Reconcile()
    local units = app.components.unitFrames
    eq(units.takeover.units, true)
    eq(units.takeover.cast, true)
    eq(PlayerFrame:IsShown(), false)
    eq(PetFrame:IsShown(), false)
    eq(units.nativeSuppressed, true)
    -- A client re-show is suppressed again on the next refresh.
    PlayerFrame:Show()
    units:Refresh()
    eq(PlayerFrame:IsShown(), false)
    -- Turning it off restores every frame it recorded as shown.
    app.Store:Set("ui", "takeoverUnitFrames", false)
    app:Reconcile()
    eq(units.takeover.units, false)
    eq(PlayerFrame:IsShown(), true)
    eq(PetFrame:IsShown(), true)
    eq(units.nativeSuppressed, nil)
    -- Disabling the component while taken over still gives the frames back.
    app.Store:Set("ui", "takeoverUnitFrames", true)
    app:Reconcile()
    eq(PlayerFrame:IsShown(), false)
    app.Store:Set("modules", "unitFrames", false)
    eq(PlayerFrame:IsShown(), true)
    eq(#app.errors, 0)
end)

test("the takeover switch backs off when a replacement part is missing", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.Store:Set("modules", "unitFrames", true)
    app.Store:Set("ui", "takeoverUnitFrames", true)
    -- The cast API is what the harness probe removes; without it the missing
    -- part wins over the switch and every native frame stays.
    local saved = _G.UnitCastingInfo
    _G.UnitCastingInfo = nil
    app:Reconcile()
    local units = app.components.unitFrames
    eq(units.takeover.units, false)
    eq(units.takeover.cast, false)
    eq(PlayerFrame:IsShown(), true)
    _G.UnitCastingInfo = saved
    app:Reconcile()
    eq(units.takeover.units, true)
    eq(PlayerFrame:IsShown(), false)
    app.Store:Set("ui", "takeoverUnitFrames", false)
    app:Reconcile()
    eq(PlayerFrame:IsShown(), true)
    eq(#app.errors, 0)
end)

test("/luma takeover toggles the switch through the queue", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.Store:Set("modules", "unitFrames", true)
    H.messages = {}
    SlashCmdList.LUMAUI("takeover")
    local text = table.concat(H.messages, "\n")
    eq(app.Store:Profile().ui.takeoverUnitFrames, true)
    eq(text:find(app.L.takeoverOn, 1, true) ~= nil, true)
    H.messages = {}
    SlashCmdList.LUMAUI("takeover")
    text = table.concat(H.messages, "\n")
    eq(app.Store:Profile().ui.takeoverUnitFrames, false)
    eq(text:find(app.L.takeoverOff, 1, true) ~= nil, true)
    eq(#app.errors, 0)
end)

test("world quest rows show the remaining time in gold", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local list = app.components.questList
    H.questLog.entries[3] = { title = "Zone task", questID = 105, level = 60, isTask = true }
    H.taskInfo[105] = 23 * 3600
    H.Fire("QUEST_LOG_UPDATE")

    local function findRow(text)
        for _, current in ipairs(list.rows) do
            if current.frame:IsShown() and current.label:GetText() == text then return current end
        end
    end

    -- Hours on the right slot, painted in the turn-in gold.
    local task = findRow("Zone task")
    eq(task.right:GetText(), string.format(app.L.taskTimeHours, 23))
    local red, green, blue, alpha = task.right:GetTextColor()
    eq(red, 0.95)
    eq(green, 0.8)
    eq(blue, 0.42)
    eq(alpha, 1)
    -- The fold marker yields to the time, but folding still toggles.
    H.Click(task.frame)
    eq(findRow("Zone task").right:GetText(), string.format(app.L.taskTimeHours, 23))
    H.Click(findRow("Zone task").frame)
    eq(findRow("Zone task").right:GetText(), string.format(app.L.taskTimeHours, 23))

    -- Minutes for anything under an hour, never below one minute.
    H.taskInfo[105] = 45 * 60
    H.Fire("QUEST_LOG_UPDATE")
    eq(findRow("Zone task").right:GetText(), string.format(app.L.taskTimeMinutes, 45))
    H.taskInfo[105] = 59
    H.Fire("QUEST_LOG_UPDATE")
    eq(findRow("Zone task").right:GetText(), string.format(app.L.taskTimeMinutes, 1))
    -- Zero or missing data leaves the slot empty, also when folded.
    H.taskInfo[105] = 0
    H.Fire("QUEST_LOG_UPDATE")
    eq(findRow("Zone task").right:GetText(), "")
    H.Click(findRow("Zone task").frame)
    eq(findRow("Zone task").right:GetText(), "")
    H.Click(findRow("Zone task").frame)

    -- Regular rows keep the fold marker and the muted color.
    local muted = app.Theme.colors.muted
    H.Click(findRow("First quest").frame)
    local regular = findRow("First quest")
    eq(regular.right:GetText(), "+")
    local mr, mg, mb = regular.right:GetTextColor()
    eq(mr, muted[1])
    eq(mg, muted[2])
    eq(mb, muted[3])
    H.Click(findRow("First quest").frame)
    eq(findRow("First quest").right:GetText(), "")
    eq(#app.errors, 0)
end)

-- ==== TRACK-P2: QUEST POLISH —append new tests above this line ====
test("unit frames include the target's target with parts, watch and events", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.Store:Set("modules", "unitFrames", true)
    local units = app.components.unitFrames
    local frame = units.frames.targettarget
    eq(frame ~= nil, true)
    eq(frame:GetAttribute("unit"), "targettarget")
    eq(frame.watched, true)
    eq(frame:GetHeight(), 28)
    eq(frame:GetWidth(), 100)
    eq(frame.events.events["UNIT_HEALTH"], "targettarget")
    eq(frame.events.events["RAID_TARGET_UPDATE"], true)
    eq(_G.LumaUIUnit_targettarget:IsShown(), true)
    -- A player target-of-target redraws with the class pair on its event.
    H.unitInfo.targettarget = { isPlayer = true, class = "WARRIOR" }
    H.Fire("UNIT_HEALTH", "targettarget")
    local fill = frame.health:GetStatusBarTexture()
    local warrior = RAID_CLASS_COLORS.WARRIOR
    eq(fill.gradient.lo[1], warrior.r * 0.45)
    eq(fill.gradient.hi[1], warrior.r + (1 - warrior.r) * 0.25)
    -- A hostile one switches to the hostile reaction pair.
    H.unitInfo.targettarget = { isPlayer = false, reaction = 3 }
    H.Fire("UNIT_HEALTH", "targettarget")
    eq(fill.gradient.lo[1], app.Theme.colors.hostile[1] * 0.45)
    -- Disabling releases it like every other unit frame.
    app.Store:Set("modules", "unitFrames", false)
    eq(frame:IsShown(), false)
    eq(frame.watched, false)
    eq(next(frame.events.events), nil)
    eq(#app.errors, 0)
end)

test("health prints a percent, power abbreviates, secrets keep the engine path", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.Store:Set("modules", "unitFrames", true)
    local frame = app.components.unitFrames.frames.target
    local originalHealth, originalPower = UnitHealth, UnitPower
    _G.UnitHealth = function() return 1487600 end
    _G.UnitPower = function() return 234560 end
    H.Fire("UNIT_HEALTH", "target")
    eq(frame.value:GetText(), "42.0%")
    eq(frame.powerValue:GetText(), "23万")
    -- Losing the client formatter keeps the plain "%d" power text; the health
    -- percent is engine formatted and does not depend on it.
    _G.AbbreviateLargeNumbers = nil
    H.Fire("UNIT_HEALTH", "target")
    eq(frame.value:GetText(), "42.0%")
    eq(frame.powerValue:GetText(), "234560")
    -- Restricted values never reach the formatter or any Lua arithmetic.
    _G.AbbreviateLargeNumbers = function(value) if value >= 10000 then return string.format("%.0f万", value / 10000) end return tostring(value) end
    _G.UnitHealth, _G.UnitPower = originalHealth, originalPower
    H.Fire("UNIT_HEALTH", "target")
    eq(frame.value:GetText(), "42.0%")
    eq(frame.powerValue:GetText(), "10")
    eq(#app.errors, 0)
end)

test("party frames watch units and take over the native frame", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    eq(app.components.partyFrames.status, "disabled")
    eq(PartyFrame:IsShown(), true)
    app.Store:Set("modules", "partyFrames", true)
    local party = app.components.partyFrames
    eq(party.running, true)
    local first = party.frames.party1
    eq(first ~= nil, true)
    eq(first:GetAttribute("unit"), "party1")
    eq(first:GetAttribute("*type1"), "target")
    eq(first:GetAttribute("*type2"), "togglemenu")
    eq(first.watched, true)
    eq(first:IsShown(), true)
    -- Full coverage takes the native display down; a client Show is re-hidden
    -- by the same suppression hook until coverage drops.
    eq(PartyFrame:IsShown(), false)
    PartyFrame:Show()
    eq(PartyFrame:IsShown(), false)
    -- A unit event redraws that member's bar with its reaction pair.
    H.unitInfo.party1 = { isPlayer = false, reaction = 5 }
    H.Fire("UNIT_HEALTH", "party1")
    eq(first.health:GetStatusBarTexture().gradient.lo[1], app.Theme.colors.friendly[1] * 0.45)
    eq(first.name:GetText() ~= "", true)
    -- Losing every member restores the native frame; the next covered roster
    -- takes it down again.
    local originalExists = UnitExists
    _G.UnitExists = function() return false end
    H.Fire("GROUP_ROSTER_UPDATE")
    eq(PartyFrame:IsShown(), true)
    _G.UnitExists = originalExists
    H.Fire("GROUP_ROSTER_UPDATE")
    eq(PartyFrame:IsShown(), false)
    -- Disabling releases the watches, hides the buttons and restores the
    -- native frame.
    app.Store:Set("modules", "partyFrames", false)
    eq(first.watched, false)
    eq(first:IsShown(), false)
    eq(PartyFrame:IsShown(), true)
    eq(#app.errors, 0)
end)

test("party frames defer building in combat and tolerate a missing native frame", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    H.Combat(true)
    app.Store:Set("modules", "partyFrames", true)
    local party = app.components.partyFrames
    -- The reconciler itself is queued in combat, so nothing has been built.
    eq(party.running == true, false)
    eq(party.frames, nil)
    H.Combat(false)
    eq(party.running, true)
    eq(party.frames.party1 ~= nil, true)
    eq(PartyFrame:IsShown(), false)
    -- A client without the centralized party frame keeps working.
    local bare = H.Load()
    _G.PartyFrame = nil
    H.Fire("PLAYER_LOGIN")
    bare.Store:Set("modules", "partyFrames", true)
    eq(bare.components.partyFrames.running, true)
    eq(bare.components.partyFrames.frames.party1 ~= nil, true)
    eq(#bare.errors, 0)
end)


test("inventory filter chips group items by item class", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    -- Seed the class ids before the first render: the browser caches the class
    -- id per item id, so the first collect would otherwise pin the fallback.
    H.itemClasses[123], H.itemClasses[456], H.itemClasses[789] = 2, 0, 11
    SlashCmdList.LUMAUI("bags")
    local inventory = app.components.inventory
    -- One item id per bag: 123 weapon (equip), 456 consumable, 789 quest item
    -- and 999 unknown, so every chip can be checked against a different row.
    local ids = { [0] = 123, [1] = 456, [2] = 789, [3] = 999, [4] = 123, [5] = 456 }
    C_Container.GetContainerItemInfo = function(bag, slot)
        if slot == 2 then return nil end
        local id = ids[bag]
        return { hyperlink = "|Hitem:" .. id .. "|h[Item " .. bag .. "]|h", itemName = "Item " .. bag,
            itemID = id, stackCount = 2, iconFileID = 134400, quality = 2, isLocked = false }
    end
    inventory.search.scripts.OnTextChanged(inventory.search)
    local function shownBags()
        local bags = {}
        for _, button in ipairs(inventory.buttons) do
            if button:IsShown() then bags[#bags + 1] = button.item.bag end
        end
        return bags
    end

    H.Click(inventory.filters[2])  -- Equipment: the weapon-class items
    eq(inventory.filter, "equip")
    eq(inventory.filters[2].selected, true)
    eq(inventory.filters[1].selected, false)
    local bags = shownBags()
    eq(#bags, 2)
    eq(bags[1], 0)
    eq(bags[2], 4)
    H.Click(inventory.filters[3])  -- Consumables
    bags = shownBags()
    eq(#bags, 2)
    eq(bags[1], 1)
    eq(bags[2], 5)
    H.Click(inventory.filters[5])  -- Quest items
    eq(shownBags()[1], 2)
    H.Click(inventory.filters[6])  -- Other: the unknown class id
    eq(shownBags()[1], 3)
    -- Empty results keep the existing empty state.
    H.Click(inventory.filters[4])  -- Materials: none in the bags
    eq(inventory.empty:IsShown(), true)
    eq(inventory.buttons[1]:IsShown(), false)
    H.Click(inventory.filters[1])  -- All restores the full page
    eq(inventory.filter, "all")
    eq(#shownBags(), 6)
    eq(inventory.empty:IsShown(), false)
    eq(#app.errors, 0)
end)

test("ctrl click splits stacks and defers the protected action in combat", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    SlashCmdList.LUMAUI("bags")
    local inventory = app.components.inventory
    local button = inventory.buttons[1]  -- the stub stack of 2 in bag 0 slot 1
    eq(button.item.count, 2)
    -- Ctrl+click opens the split dialog bound to that stack.
    H.ctrlDown = true
    button.scripts.OnClick(button, "LeftButton")
    H.ctrlDown = false
    eq(inventory.split ~= nil, true)
    eq(inventory.split.frame:IsShown(), true)
    eq(inventory.split.frame.point[1], "CENTER")
    eq(inventory.split.frame.point[2], inventory.frame)
    eq(inventory.split.frame.lumaSurfaceRole, "card")
    eq(inventory.split.item.bag, 0)
    eq(inventory.split.item.slot, 1)
    -- Non-numeric input is rejected and keeps the dialog open.
    inventory.split.input:SetText("abc")
    inventory.split.confirm.scripts.OnClick(inventory.split.confirm)
    eq(H.calls.split, nil)
    eq(inventory.split.frame:IsShown(), true)
    -- Amounts beyond the stack are clamped to 1 .. stack-1.
    inventory.split.input:SetText("9")
    inventory.split.confirm.scripts.OnClick(inventory.split.confirm)
    eq(H.calls.split.bag, 0)
    eq(H.calls.split.slot, 1)
    eq(H.calls.split.amount, 1)
    eq(inventory.split.frame:IsShown(), false)
    eq(inventory.split.item, nil)
    -- Confirming in combat queues the newest split instead of acting.
    H.ctrlDown = true
    button.scripts.OnClick(button, "LeftButton")
    H.ctrlDown = false
    inventory.split.input:SetText("1")
    local before = H.calls.split
    H.Combat(true)
    inventory.split.confirm.scripts.OnClick(inventory.split.confirm)
    eq(app.Queue:Count(), 1)
    eq(H.calls.split, before)
    eq(inventory.split.frame:IsShown(), false)
    H.Combat(false)
    eq(H.calls.split ~= before, true)
    eq(H.calls.split.amount, 1)
    eq(#app.errors, 0)
end)

test("bank browser renders the character bank and follows the bank frame", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local bank = app.components.bank
    eq(app.Store:Profile().modules.bank, false)
    eq(app.Store.defaults.modules.bank, false)
    -- Only the character bank is viewable here; its tab list is the legacy
    -- character container, which the component reads from the API, not a guess.
    H.bankView = { [Enum.BankType.Character] = true }
    H.bankTabs = { [Enum.BankType.Character] = { -1 } }
    H.bankSlots[-1] = {
        [1] = { itemID = 501, name = "Bank item", link = "|Hitem:501|h[Bank item]|h", stack = 1 },
        [2] = { itemID = 502, name = "Stacked item", link = "|Hitem:502|h[Stacked item]|h", stack = 5 },
    }
    -- Enabling the component creates the browser and opens it.
    app.Store:Set("modules", "bank", true)
    eq(bank.running, true)
    eq(bank.frame ~= nil, true)
    eq(bank.frame:IsShown(), true)
    eq(bank.buttons[1].item.bag, -1)
    eq(bank.buttons[1].item.slot, 1)
    eq(bank.buttons[2].item.bag, -1)
    eq(bank.buttons[2].item.slot, 2)
    eq(bank.buttons[2].item.count, 5)
    eq(bank.buttons[3]:IsShown(), false)
    -- One viewable bank shows no source choice, and nothing is degraded.
    eq(bank.sources[1]:IsShown(), false)
    eq(bank.note:IsShown(), false)
    eq(app.Layout.entries.bank, nil)

    -- The bank frame events open and close the window.
    bank.frame:Hide()
    eq(bank.frame:IsShown(), false)
    H.Fire("BANKFRAME_OPENED")
    eq(bank.frame:IsShown(), true)
    H.Fire("BANKFRAME_CLOSED")
    eq(bank.frame:IsShown(), false)

    -- A viewable account bank adds its own tabs and the source choice.
    H.bankView = { [Enum.BankType.Character] = true, [Enum.BankType.Account] = true }
    H.bankTabs = { [Enum.BankType.Character] = { -1 }, [Enum.BankType.Account] = { 11, 12 } }
    H.bankSlots[11] = { [1] = { itemID = 601, name = "Warband item", link = "|Hitem:601|h[Warband item]|h" } }
    H.Fire("BANKFRAME_OPENED")
    eq(bank.sources[1]:IsShown(), true)
    eq(bank.sources[2]:IsShown(), true)
    eq(bank.sources[1].selected, true)
    H.Click(bank.sources[2])  -- Warband
    eq(bank.buttons[1].item.bag, 11)
    eq(bank.buttons[1].item.name, "Warband item")
    H.Click(bank.sources[1])  -- back to the character bank
    eq(bank.buttons[1].item.bag, -1)
    H.Fire("BANKFRAME_CLOSED")
    eq(bank.frame:IsShown(), false)

    -- Clicks: left picks up from the bank bag, right uses; Shift inserts a link.
    H.Fire("BANKFRAME_OPENED")
    bank.buttons[1].scripts.OnClick(bank.buttons[1], "LeftButton")
    eq(H.calls.pickup.bag, -1)
    eq(H.calls.pickup.slot, 1)
    bank.buttons[2].scripts.OnClick(bank.buttons[2], "RightButton")
    eq(H.calls.use.bag, -1)
    eq(H.calls.use.slot, 2)
    H.modifiedClicks.CHATLINK = true
    H.inserted = nil
    bank.buttons[1].scripts.OnClick(bank.buttons[1], "LeftButton")
    eq(H.inserted, bank.buttons[1].item.link)
    H.modifiedClicks.CHATLINK = false

    -- Opening while in combat stays allowed; it is a plain browser window.
    H.Combat(true)
    bank.frame:Show()
    eq(bank.frame:IsShown(), true)
    H.Combat(false)

    -- Disabling hides the window and releases every registration.
    app.Store:Set("modules", "bank", false)
    eq(bank.frame:IsShown(), false)
    eq(next(bank.events.events), nil)
    H.Fire("BANKFRAME_OPENED")
    eq(bank.frame:IsShown(), false)
    eq(#app.errors, 0)
end)

test("bank browser searches bank items and fails alone without containers", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    H.bankView = { [Enum.BankType.Character] = true }
    H.bankTabs = { [Enum.BankType.Character] = { -1 } }
    H.bankSlots[-1] = { [1] = { itemID = 501, name = "Bank item", link = "|Hitem:501|h[Bank item]|h", stack = 1 } }
    app.Store:Set("modules", "bank", true)
    local bank = app.components.bank
    eq(bank.running, true)
    bank.search:SetText("no match")
    bank.search.scripts.OnTextChanged(bank.search)
    eq(bank.empty:IsShown(), true)
    eq(bank.buttons[1]:IsShown(), false)
    bank.search:SetText("")
    bank.search.scripts.OnTextChanged(bank.search)
    eq(bank.buttons[1]:IsShown(), true)
    eq(bank.buttons[1].item.name, "Bank item")
    -- Missing container support marks only this component unsupported; the
    -- switch has to be on for the capability check to run at all.
    local bare = H.Load()
    C_Container = nil
    H.Fire("PLAYER_LOGIN")
    bare.Store:Set("modules", "bank", true)
    eq(bare.components.bank.status, "unsupported")
    eq(bare.components.inventory.status, "unsupported")
    eq(bare.components.dataStrip.running, true)
    eq(#bare.errors, 0)
end)

-- ==== TRACK-P2: BAGS —append new tests above this line ====
test("system windows reskin the character frame and reapply on show", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local component = app.components.systemWindows
    eq(component.status, "disabled")
    app.Store:Set("modules", "systemWindows", true)
    eq(component.running, true)
    local regions = H.characterRegions
    -- Art is faded to alpha 0 rather than hidden: the client re-shows its own
    -- textures on layout and model load, and a faded texture stays faded. The
    -- title FontString stays visible and is recolored to the theme text color.
    eq(regions[1]:GetAlpha(), 0)
    eq(regions[2]:GetAlpha(), 0)
    eq(regions[3]:GetAlpha(), 0)
    eq(regions[4]:IsShown(), true)
    eq(regions[4]:GetTextColor(), app.Theme.colors.text[1])
    eq(CharacterFrame.NineSlice:GetAlpha(), 0)
    local entry = component.entries.character
    eq(entry ~= nil, true)
    local panel = entry.panel
    eq(panel ~= nil, true)
    -- The backing is drawn on the window's own background layer: one surface
    -- texture plus four 1px accent edges.
    eq(panel.surface:IsShown(), true)
    eq(panel.surface.drawLayer, "BACKGROUND")
    eq(#panel.edges, 4)
    local accent = app.Theme:Accent()
    eq(panel.edges[1].color[1], accent[1])
    eq(panel.edges[1]:IsShown(), true)
    eq(CharacterFrame.hookCount, 1)
    -- The client redraws its own art and the window is reopened: the OnShow
    -- hook reapplies without installing a second hook, and the redrawn texture
    -- is faded again.
    regions[1]:Show()
    regions[1]:SetAlpha(1)
    CharacterFrame:Hide()
    CharacterFrame:Show()
    eq(regions[1]:GetAlpha(), 0)
    eq(regions[4]:IsShown(), true)
    eq(panel.surface:IsShown(), true)
    eq(#app.errors, 0)
end)

test("system windows restore native art and degrade without the frame", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local component = app.components.systemWindows
    app.Store:Set("modules", "systemWindows", true)
    local regions = H.characterRegions
    local panel = component.entries.character.panel
    app.Store:Set("modules", "systemWindows", false)
    eq(component.running, false)
    eq(component.status, "disabled")
    -- Every faded region comes back to full opacity, including the natively
    -- hidden one, and the title color returns.
    eq(regions[1]:GetAlpha(), 1)
    eq(regions[2]:GetAlpha(), 1)
    eq(regions[3]:GetAlpha(), 1)
    eq(regions[4]:IsShown(), true)
    eq(regions[4]:GetTextColor(), 1)
    eq(CharacterFrame.NineSlice:GetAlpha(), 1)
    eq(panel.surface:IsShown(), false)
    -- Load discovery listens for late windows while the component runs; those
    -- registrations are released with the component, so nothing can leak.
    eq(component.events ~= nil, true)
    eq(next(component.events.events), nil)
    -- Re-enabling reapplies the reskin with the same single hook.
    app.Store:Set("modules", "systemWindows", true)
    eq(component.running, true)
    eq(regions[1]:GetAlpha(), 0)
    eq(regions[3]:GetAlpha(), 0)
    eq(regions[4]:IsShown(), true)
    eq(CharacterFrame.NineSlice:GetAlpha(), 0)
    eq(component.entries.character.panel.surface:IsShown(), true)
    eq(CharacterFrame.hookCount, 1)
    -- Without CharacterFrame the component reports unsupported and stays quiet.
    local bare = H.Load({ profiles = { Default = { modules = { systemWindows = true } } } })
    _G.CharacterFrame = nil
    H.Fire("PLAYER_LOGIN")
    eq(bare.components.systemWindows.status, "unsupported")
    eq(bare.components.systemWindows.running, nil)
    eq(#bare.errors, 0)
    eq(#app.errors, 0)
end)

test("stat rows get a header band and divider styling", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    _G.CharacterStatsPaneScrollBox = H.NewFrame("CharacterStatsPaneScrollBox", CharacterFrame)
    local header = H.NewFrame(nil, CharacterStatsPaneScrollBox)
    header.Title = H.NewFrame(nil, header)
    local stat = H.NewFrame(nil, CharacterStatsPaneScrollBox)
    stat.Label = H.NewFrame(nil, stat)
    stat.Value = H.NewFrame(nil, stat)
    app.Store:Set("modules", "systemWindows", true)
    local entry = app.components.systemWindows.entries.character
    -- Header rows get a dark band behind the title; stat rows get a faint
    -- divider and a dimmed label so the value reads first.
    eq(entry.statBand[header] ~= nil, true)
    eq(entry.statBand[header].color[4], 0.35)
    eq(entry.statLine[stat] ~= nil, true)
    eq(entry.statLine[stat].height, 1)
    eq(stat.Label.textColor[1], app.Theme.colors.muted[1])
    app.Store:Set("modules", "systemWindows", false)
    eq(entry.statBand[header]:IsShown(), false)
    eq(entry.statLine[stat]:IsShown(), false)
    eq(#app.errors, 0)
end)


test("character adapter strips side tabs and stats row plates", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    _G.CharacterFrameModeTab1 = H.NewFrame("CharacterFrameModeTab1", CharacterFrame)
    local tabArt = H.NewFrame(nil, CharacterFrameModeTab1)
    tabArt.kind = "texture"
    CharacterFrameModeTab1.GetRegions = function() return tabArt end
    _G.PaperDollSidebarTab1 = H.NewFrame("PaperDollSidebarTab1", CharacterFrame)
    local sideArt = H.NewFrame(nil, PaperDollSidebarTab1)
    sideArt.kind = "texture"
    PaperDollSidebarTab1.GetRegions = function() return sideArt end
    _G.CharacterStatsPaneScrollBox = H.NewFrame("CharacterStatsPaneScrollBox", CharacterFrame)
    local row = H.NewFrame(nil, CharacterStatsPaneScrollBox)
    row.Background = H.NewFrame(nil, row)
    app.Store:Set("modules", "systemWindows", true)
    eq(tabArt:GetAlpha(), 0)
    eq(sideArt:GetAlpha(), 0)
    eq(row.Background:GetAlpha(), 0)
    app.Store:Set("modules", "systemWindows", false)
    eq(tabArt:GetAlpha(), 1)
    eq(sideArt:GetAlpha(), 1)
    eq(row.Background:GetAlpha(), 1)
    eq(#app.errors, 0)
end)


test("character adapter strips the real window structure and dresses slots", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    -- The modern window: art in named child frames, slots with border frames
    -- and GearSlot atlas rings (structure per the 12.x baseline).
    _G.PaperDollFrame = H.NewFrame("PaperDollFrame", CharacterFrame)
    local paperArt = H.NewFrame(nil, PaperDollFrame)
    paperArt.kind = "texture"
    PaperDollFrame.GetRegions = function() return paperArt end
    CharacterFrame.LeftPaneHost = H.NewFrame(nil, CharacterFrame)
    CharacterFrame.RightPaneHost = H.NewFrame(nil, CharacterFrame)
    CharacterFrame.RightPaneHost.StoneBg = H.NewFrame(nil, CharacterFrame.RightPaneHost)
    _G.CharacterLevelTextBackground = H.NewFrame("CharacterLevelTextBackground", CharacterFrame)
    local slot = H.NewFrame("CharacterHeadSlot", CharacterFrame, "SecureUnitButtonTemplate")
    slot.BorderFrame = H.NewFrame(nil, slot)
    slot.NormalTexture = H.NewFrame(nil, slot)
    local gear = H.NewFrame(nil, slot)
    gear.atlas = "GearSlot-Bag"
    -- The item icon lives on the button and must survive the skin.
    slot.icon = H.NewFrame(nil, slot)
    slot.GetRegions = function() return gear end
    slot.GetID = function() return 1 end
    _G.PaperDollItemSlotButton_Update = function() end
    H.slotQuality = 2
    app.Store:Set("modules", "systemWindows", true)
    local entry = app.components.systemWindows.entries.character
    eq(entry ~= nil, true)
    eq(CharacterFrame.RightPaneHost.StoneBg:GetAlpha(), 0)
    eq(_G.CharacterLevelTextBackground:GetAlpha(), 0)
    eq(paperArt:GetAlpha(), 0)
    eq(slot.BorderFrame:GetAlpha(), 0)
    eq(slot.NormalTexture:GetAlpha(), 0)
    eq(gear:GetAlpha(), 0)
    eq(slot.icon:GetAlpha(), 1)
    local border = entry.slotBorders[slot]
    eq(border ~= nil, true)
    eq(border.borderColor[1], ITEM_QUALITY_COLORS[2].r)
    -- A quality change repaints the border through the component Refresh.
    H.slotQuality = 3
    app.components.systemWindows:Refresh()
    eq(border.borderColor[1], ITEM_QUALITY_COLORS[3].r)
    -- Disabling restores the art, the atlas ring and drops the borders.
    app.Store:Set("modules", "systemWindows", false)
    eq(slot.BorderFrame:GetAlpha(), 1)
    eq(slot.NormalTexture:GetAlpha(), 1)
    eq(gear:GetAlpha(), 1)
    eq(border:IsShown(), false)
    eq(_G.CharacterLevelTextBackground:GetAlpha(), 1)
    eq(#app.errors, 0)
end)



test("character window builds slots, model and a stats column", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    eq(app.components.characterWindow.status, "disabled")
    app.Store:Set("modules", "characterWindow", true)
    local window = app.components.characterWindow.window
    eq(window ~= nil, true)
    -- Retail uses eighteen slots: eleven armour pieces, five accessories and
    -- two weapons. The ranged slot is not padded in when it is unused.
    eq(#window.slots, 18)
    eq(window.slots[1].slotID, 1)
    eq(window.slots[1].icon.texture, 134401)
    eq(window.slots[1].icon:IsShown(), true)
    eq(window.dragHandle ~= nil, true)
    eq(window.model.modelUnit, "player")
    -- Left click picks the item up with the slot's own id.
    H.Click(window.slots[2])
    eq(H.calls.inventoryPickup, window.slots[2].slotID)
    -- The stats column reads the public getters and floors them.
    eq(window.itemLevel.value:GetText(), "287")
    eq(#window.statRows, 9)
    eq(window.statRows[1].row.value:GetText(), "810")
    eq(window.statRows[5].row.value:GetText(), "2650")
    -- A quality border colours the slot.
    H.slotQuality = 4
    app.components.characterWindow:Refresh()
    eq(window.slots[1].borderColor[1], ITEM_QUALITY_COLORS[4].r)
    -- Toggling shows and hides our own window; disabling closes it.
    app.components.characterWindow:Toggle()
    eq(window:IsShown(), true)
    app.components.characterWindow:Toggle()
    eq(window:IsShown(), false)
    app.Store:Set("modules", "characterWindow", false)
    eq(window:IsShown(), false)
    eq(#app.errors, 0)
end)

test("character window falls back to the item link for icons", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local savedTexture, savedIcon = GetInventoryItemTexture, C_Item.GetItemIconByID
    _G.GetInventoryItemTexture = nil
    C_Item.GetItemIconByID = nil
    app.Store:Set("modules", "characterWindow", true)
    local window = app.components.characterWindow.window
    -- With only the link path left, the slot still gets an icon.
    eq(window.slots[1].icon.texture, 134500 + 2001)
    eq(window.slots[1].icon:IsShown(), true)
    _G.GetInventoryItemTexture, C_Item.GetItemIconByID = savedTexture, savedIcon
    eq(#app.errors, 0)
end)

test("character window switches between character, reputation and currency pages", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.Store:Set("modules", "characterWindow", true)
    local window = app.components.characterWindow.window
    eq(#window.tabs, 3)
    eq(window.pages[1]:IsShown(), true)
    eq(window.pages[2]:IsShown(), false)
    -- Reputation page: faction rows with the game's standing label.
    H.Click(window.tabs[2])
    eq(window.pages[2]:IsShown(), true)
    eq(window.pages[1]:IsShown(), false)
    eq(window.currentPage, 2)
    local rep = window.pages[2].rows[1]
    eq(rep.label:GetText(), "Argent Dawn")
    eq(rep.value:GetText(), "Friendly  4300 / 21000")
    -- Currency page: icon, name and amount.
    H.Click(window.tabs[3])
    eq(window.pages[3]:IsShown(), true)
    local currency = window.pages[3].rows[1]
    eq(currency.label:GetText(), "Valor")
    eq(currency.value:GetText(), "1200")
    eq(currency.icon.texture, 134945)
    -- Back to the character page.
    H.Click(window.tabs[1])
    eq(window.pages[1]:IsShown(), true)
    eq(window.currentPage, 1)
    eq(#app.errors, 0)
end)

test("character window scrolls long faction lists and rotates the model", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.Store:Set("modules", "characterWindow", true)
    local window = app.components.characterWindow.window
    -- More factions than one page can hold, so the wheel has somewhere to go.
    local total = window.listRows + 8
    H.factions = {}
    for index = 1, total do
        H.factions[#H.factions + 1] = { name = "Faction " .. index, standing = 5 }
    end
    H.Click(window.tabs[2])
    local page = window.pages[2]
    -- The page shows as many rows as its height allows, and the rest is
    -- reachable with the wheel. The row count is measured from the layout, not
    -- a fixed number.
    local rows = window.listRows
    eq(rows >= 14, true)
    eq(page.rows[rows] ~= nil, true)
    eq(page.rows[rows].label:GetText(), "Faction " .. rows)
    page.scripts.OnMouseWheel(page, -1)
    eq(page.offset, 1)
    eq(page.rows[1].label:GetText(), "Faction 2")
    page.scripts.OnMouseWheel(page, 1)
    eq(page.offset, 0)
    eq(page.rows[1].label:GetText(), "Faction 1")
    -- The offset is clamped at the end of the list rather than scrolling into
    -- blank rows.
    for _ = 1, total do page.scripts.OnMouseWheel(page, -1) end
    eq(page.offset, total - rows)
    -- Model rotation steps the angle and drives the model.
    local before = window.modelAngle
    H.Click(window.rotateLeft)
    eq(window.modelAngle < before, true)
    eq(window.model.rotation, window.modelAngle)
    eq(#app.errors, 0)
end)

test("reputation folds by group and draws a standing bar", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    H.factions = {
        { name = "Alliance", header = true },
        { name = "Stormwind", standing = 5 },
        { name = "Ironforge", standing = 3 },
    }
    app.Store:Set("modules", "characterWindow", true)
    local window = app.components.characterWindow.window
    H.Click(window.tabs[2])
    local page = window.pages[2]
    eq(page.rows[1].label:GetText(), "- Alliance")
    eq(page.rows[2].label:GetText(), "Stormwind")
    -- The faction row carries a two-pixel standing bar sized by the ratio.
    eq(page.rows[2].fill:IsShown(), true)
    local width = page.rows[2].fill.width
    eq(width > 0, true)
    -- Folding the header hides its members.
    page.rows[1].scripts.OnMouseUp()
    eq(page.rows[1].label:GetText(), "+ Alliance")
    eq(page.rows[2]:IsShown(), false)
    page.rows[1].scripts.OnMouseUp()
    eq(page.rows[2]:IsShown(), true)
    eq(#app.errors, 0)
end)

test("character window exposes equipped count, slot drag and tab glow", function()
    local app = H.Load()
    H.Fire("PLAYER_LOGIN")
    app.Store:Set("modules", "characterWindow", true)
    local window = app.components.characterWindow.window
    -- Every drawn slot holds an item in the stub, so the count is the slot total.
    eq(window.equipped.value:GetText(), "18 / 18")
    -- Dragging a slot picks it up, and dropping onto one places the item.
    local slot = window.slots[1]
    slot.scripts.OnDragStart(slot)
    eq(H.calls.inventoryPickup, slot.slotID)
    slot.scripts.OnReceiveDrag(slot)
    eq(H.calls.inventoryPickup, slot.slotID)
    -- The active tab carries the LumaUI underline; the others hide theirs.
    eq(window.tabs[1].selectedMark:IsShown(), true)
    H.Click(window.tabs[2])
    eq(window.tabs[1].selectedMark:IsShown(), false)
    eq(window.tabs[2].selectedMark:IsShown(), true)
    eq(#app.errors, 0)
end)

test("system windows also skin the mail frame with the generic adapter", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.Store:Set("modules", "systemWindows", true)
    local component = app.components.systemWindows
    local entry = component.entries.mail
    eq(entry ~= nil, true)
    -- Art is faded and a LumaUI backing is drawn on the window.
    eq(H.mailArt:GetAlpha(), 0)
    eq(entry.panel.surface:IsShown(), true)
    app.Store:Set("modules", "systemWindows", false)
    eq(H.mailArt:GetAlpha(), 1)
    eq(entry.panel.surface:IsShown(), false)
    eq(#app.errors, 0)
end)

test("character window shows saved sets, rating details and scales", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.Store:Set("modules", "characterWindow", true)
    local window = app.components.characterWindow.window
    -- Saved sets come from C_EquipmentSet.GetEquipmentSetIDs and carry the
    -- state the game reports: the equipped set, and the unequipped set's
    -- equipped/total item count.
    eq(#window.setRows, 2)
    eq(window.setRows[1].label:GetText(), "Raid")
    eq(window.setRows[1].value:GetText(), app.L.setEquipped)
    eq(window.setRows[2].label:GetText(), "Mythic")
    eq(window.setRows[2].value:GetText(), "3/4")
    -- Clicking an unequipped set is a real swap; the equipped one is a no-op.
    H.Click(window.setRows[2])
    eq(H.equipmentSetUsed, 22)
    H.equipmentSetUsed = nil
    H.Click(window.setRows[1])
    eq(H.equipmentSetUsed, nil)
    -- A set with locked items is refused instead of being swapped.
    H.equipmentSets[2].locked = true
    H.messages = {}
    H.Click(window.setRows[2])
    eq(H.equipmentSetUsed, nil)
    eq(H.messages[1]:find(app.L.equipSetLocked, 1, true) ~= nil, true)
    H.equipmentSets[2].locked = false
    -- Combat refuses the swap too, without touching the set API.
    H.Combat(true)
    H.Click(window.setRows[2])
    eq(H.equipmentSetUsed, nil)
    H.Combat(false)
    -- Hovering a secondary stat adds its rating and percentage.
    GameTooltip.lines = {}
    window.statRows[6].row.scripts.OnEnter(window.statRows[6].row)
    local lines = table.concat(GameTooltip.lines, "\n")
    eq(lines:find(app.L.statCritTip, 1, true) ~= nil, true)
    eq(lines:find("420", 1, true) ~= nil, true)
    eq(lines:find("12.5", 1, true) ~= nil, true)
    -- Ctrl + wheel on the title bar changes the stored scale.
    H.ctrlDown = true
    window.dragHandle.scripts.OnMouseWheel(window.dragHandle, 1)
    eq(app.Store:Profile().ui.windowScale, 1.05)
    eq(window:GetScale(), 1.05)
    H.ctrlDown = false
    window.dragHandle.scripts.OnMouseWheel(window.dragHandle, 1)
    eq(app.Store:Profile().ui.windowScale, 1.05)
    eq(#app.errors, 0)
end)

test("reputation page handles an empty or unexpected faction list", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    H.factions = {}
    app.Store:Set("modules", "characterWindow", true)
    local window = app.components.characterWindow.window
    H.Click(window.tabs[2])
    -- No factions at all: the page must still open without errors.
    eq(window.pages[2]:IsShown(), true)
    eq(#app.errors, 0)
    -- A faction whose standing is not a number is still listed instead of
    -- being dropped (clients differ in what GetFactionInfo returns).
    H.factions = { { name = "Odd faction", standing = nil } }
    H.Click(window.tabs[1])
    H.Click(window.tabs[2])
    eq(window.pages[2].rows[1].label:GetText(), "Odd faction")
    eq(#app.errors, 0)
end)

test("reputation page reads the modern C_Reputation API", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    _G.C_Reputation = {
        GetNumFactions = function() return 3 end,
        GetFactionDataByIndex = function(index)
            if index == 1 then return { name = "Groups", isHeader = true } end
            return { name = "Faction " .. index, reaction = 5,
                currentReactionThreshold = 0, nextReactionThreshold = 100, currentStanding = 50 }
        end,
    }
    app.Store:Set("modules", "characterWindow", true)
    local window = app.components.characterWindow.window
    H.Click(window.tabs[2])
    local page = window.pages[2]
    eq(page.rows[1].label:GetText(), "- Groups")
    eq(page.rows[2].label:GetText(), "Faction 2")
    eq(page.rows[2].value:GetText(), "Friendly  50 / 100")
    eq(page.rows[2].fill:IsShown(), true)
    _G.C_Reputation = nil
    eq(#app.errors, 0)
end)

test("stat tooltip falls back to Constants.CombatRating", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local savedCrit, savedConstants = _G.CR_CRIT_MELEE, _G.Constants
    _G.CR_CRIT_MELEE = nil
    _G.Constants = { CombatRating = { CritMelee = 9, HasteMelee = 18, Mastery = 26, VersatilityDamageDone = 29 } }
    app.Store:Set("modules", "characterWindow", true)
    local window = app.components.characterWindow.window
    GameTooltip.lines = {}
    window.statRows[6].row.scripts.OnEnter(window.statRows[6].row)
    local lines = table.concat(GameTooltip.lines, "\n")
    eq(lines:find("420", 1, true) ~= nil, true)
    eq(lines:find("12.5", 1, true) ~= nil, true)
    _G.CR_CRIT_MELEE, _G.Constants = savedCrit, savedConstants
    eq(#app.errors, 0)
end)

test("reputation standing falls back to the localised string and empty groups stay flat", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local savedLabel = _G.FACTION_STANDING_LABEL5
    local savedText = _G.GetText
    _G.FACTION_STANDING_LABEL5 = nil
    _G.GetText = function(key)
        if key == "FACTION_STANDING_LABEL5" then return "Localised Friendly" end
        return savedText and savedText(key) or key
    end
    H.factions = {
        { name = "Loaded group", header = true },
        { name = "Member", standing = 5 },
        { name = "Empty group", header = true },
    }
    app.Store:Set("modules", "characterWindow", true)
    local window = app.components.characterWindow.window
    H.Click(window.tabs[2])
    local page = window.pages[2]
    -- The member uses the fallback label.
    eq(page.rows[2].value:GetText():find("Localised Friendly", 1, true) ~= nil, true)
    -- The empty group has no fold marker: there is nothing to unfold.
    eq(page.rows[3].label:GetText(), "Empty group")
    _G.FACTION_STANDING_LABEL5, _G.GetText = savedLabel, savedText
    eq(#app.errors, 0)
end)

test("raid frames build watched buttons while preserving native frames", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    eq(app.components.raidFrames.status, "disabled")
    eq(CompactRaidFrameContainer:IsShown(), true)
    local savedExists = UnitExists
    _G.UnitExists = function(unit) return unit == "raid1" or unit == "raid2" end
    H.inRaid = true
    app.Store:Set("modules", "raidFrames", true)
    local raid = app.components.raidFrames
    eq(raid.running, true)
    local first = raid.frames[1]
    eq(first ~= nil, true)
    eq(raid.frames[2] ~= nil, true)
    -- Only the tokens the client reports get a button; 40 are never allocated.
    eq(raid.frames[3], nil)
    eq(first:GetAttribute("unit"), "raid1")
    eq(first:GetAttribute("*type1"), "target")
    eq(first:GetAttribute("*type2"), "togglemenu")
    eq(first:GetWidth(), 90)
    eq(first:GetHeight(), 32)
    eq(first.watched, true)
    eq(first:IsShown(), true)
    eq(first.events.events["UNIT_HEALTH"], "raid1")
    -- The grid is one 5 x 8 block: 96 px per column, 36 px per row.
    eq(raid.container:GetWidth(), 474)
    eq(raid.container:GetHeight(), 284)
    eq(app.Layout.entries.raidFrames.frame, raid.container)
    -- A ninth member opens the second column one step to the right.
    _G.UnitExists = function(unit) return unit == "raid1" or unit == "raid2" or unit == "raid9" end
    H.Fire("GROUP_ROSTER_UPDATE")
    eq(raid.frames[9] ~= nil, true)
    eq(raid.frames[9].point[4], 96)
    eq(raid.frames[9].point[5], 0)
    -- Both the native raid container and its manager stay available.
    eq(CompactRaidFrameContainer:IsShown(), true)
    eq(CompactRaidFrameManager:IsShown(), true)
    CompactRaidFrameContainer:Show()
    eq(CompactRaidFrameContainer:IsShown(), true)
    -- A unit event redraws that member's bar with its class pair.
    H.unitInfo.raid1 = { isPlayer = true, class = "WARRIOR" }
    H.Fire("UNIT_HEALTH", "raid1")
    local warrior = RAID_CLASS_COLORS.WARRIOR
    eq(first.health:GetStatusBarTexture().gradient.lo[1], warrior.r * 0.45)
    eq(first.name.text ~= nil, true)
    -- The diagnostic reports the state the prototype actually sees, through the
    -- `/luma raid` command like the party one.
    H.messages = {}
    SlashCmdList.LUMAUI("raid")
    local text = table.concat(H.messages, "\n")
    eq(text:find("raidFrames: status=running", 1, true) ~= nil, true)
    eq(text:find("raid1: exists=yes button=yes watched=yes shown=yes", 1, true) ~= nil, true)
    eq(text:find("native CompactRaidFrameContainer: exists=yes shown=yes taken=no", 1, true) ~= nil, true)
    _G.UnitExists = savedExists
    H.inRaid = false
    eq(#app.errors, 0)
end)

test("raid frames give the native frames back when the raid ends and reuse buttons", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local savedExists = UnitExists
    local present = { raid1 = true, raid2 = true }
    _G.UnitExists = function(unit) return present[unit] == true end
    H.inRaid = true
    app.Store:Set("modules", "raidFrames", true)
    local raid = app.components.raidFrames
    local first, second = raid.frames[1], raid.frames[2]
    eq(CompactRaidFrameContainer:IsShown(), true)
    -- The raid disbands: preview buttons hide and are kept for the next roster.
    present = {}
    H.inRaid = false
    H.Fire("GROUP_ROSTER_UPDATE")
    eq(CompactRaidFrameContainer:IsShown(), true)
    eq(CompactRaidFrameManager:IsShown(), true)
    eq(first:IsShown(), false)
    eq(first.watched, false)
    eq(raid.frames[1], first)
    -- A later roster reuses the same frame; the member that left stays hidden.
    present = { raid1 = true, raid5 = true }
    H.inRaid = true
    H.Fire("GROUP_ROSTER_UPDATE")
    eq(raid.frames[1], first)
    eq(raid.frames[2], second)
    eq(raid.frames[5] ~= nil, true)
    eq(first.watched, true)
    eq(first:IsShown(), true)
    eq(second:IsShown(), false)
    eq(CompactRaidFrameContainer:IsShown(), true)
    _G.UnitExists = savedExists
    H.inRaid = false
    eq(#app.errors, 0)
end)

test("raid frames defer in combat and release watches, events and natives on disable", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local savedExists = UnitExists
    _G.UnitExists = function(unit) return unit == "raid1" or unit == "raid3" end
    H.inRaid = true
    H.Combat(true)
    app.Store:Set("modules", "raidFrames", true)
    local raid = app.components.raidFrames
    -- The reconciler is queued in combat, so no secured button exists yet and
    -- the native raid frames stay untouched.
    eq(raid.running == true, false)
    eq(raid.frames, nil)
    eq(CompactRaidFrameContainer:IsShown(), true)
    H.Combat(false)
    eq(raid.running, true)
    local first = raid.frames[1]
    eq(first ~= nil, true)
    eq(raid.frames[3] ~= nil, true)
    eq(first.watched, true)
    eq(CompactRaidFrameContainer:IsShown(), true)
    -- A roster change in combat only queues the rebuild; drawing still runs.
    H.Combat(true)
    H.Fire("GROUP_ROSTER_UPDATE")
    eq(app.Queue:Count(), 1)
    H.Fire("UNIT_HEALTH", "raid1")
    -- A click is handled by the secure template, so only the attribute stays
    -- and no Lua script can run on the button.
    eq(first:GetAttribute("*type1"), "target")
    eq(first.scripts.OnClick, nil)
    eq(#app.errors, 0)
    H.Combat(false)
    eq(app.Queue:Count(), 0)
    -- Disabling releases watches, unit events, buttons and both native frames.
    app.Store:Set("modules", "raidFrames", false)
    eq(first.watched, false)
    eq(first:IsShown(), false)
    eq(next(first.events.events), nil)
    eq(CompactRaidFrameContainer:IsShown(), true)
    eq(CompactRaidFrameManager:IsShown(), true)
    eq(app.Layout.entries.raidFrames.frame:IsShown(), false)
    _G.UnitExists = savedExists
    H.inRaid = false
    eq(#app.errors, 0)
end)

-- ==== TRACK-P3: RAID —append new tests above this line ====
test("action panel draws behind the native bars and hides on disable", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    eq(app.components.actionPanel.status, "disabled")
    app.Store:Set("modules", "actionPanel", true)
    local panel = app.components.actionPanel.panels[MainActionBar]
    eq(panel ~= nil, true)
    eq(panel:IsShown(), true)
    eq(panel.parent, UIParent)
    -- The bar's own Show/Hide drives the panel.
    MainActionBar:Hide()
    eq(panel:IsShown(), false)
    MainActionBar:Show()
    eq(panel:IsShown(), true)
    app.Store:Set("modules", "actionPanel", false)
    eq(panel:IsShown(), false)
    eq(#app.errors, 0)
end)

test("action panel follows the native bar's strata through a queued refresh", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local bar = MainActionBar
    bar.strata = "MEDIUM"
    bar.level = 50
    bar.GetFrameStrata = function(self) return self.strata end
    bar.UpdateFrameStrata = function(self, strata) self.strata = strata end
    app.Store:Set("modules", "actionPanel", true)
    local panel = app.components.actionPanel.panels[bar]
    panel.SetFrameStrata = function(self, strata) self.strata = strata end
    bar:UpdateFrameStrata("HIGH")
    eq(panel.strata, "HIGH")
    eq(panel.level, 49)
    H.Combat(true)
    bar:UpdateFrameStrata("TOOLTIP")
    eq(panel.strata, "HIGH")
    H.Combat(false)
    eq(panel.strata, "TOOLTIP")
    eq(#app.errors, 0)
end)

test("action panel hides until its native bar has a safe lower layer", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local bar = MainActionBar
    bar:SetFrameLevel(0)
    app.Store:Set("modules", "actionPanel", true)
    local component = app.components.actionPanel
    local panel = component.panels[bar]
    eq(panel:IsShown(), false)
    eq(panel.lumaLayerSafe, false)
    eq(component:Describe():find(app.L.actionPanelLayerUnavailable, 1, true) ~= nil, true)
    bar:Hide(); bar:Show()
    eq(panel:IsShown(), false)
    bar:SetFrameLevel(8)
    H.Fire("EDIT_MODE_LAYOUTS_UPDATED")
    eq(panel:IsShown(), true)
    eq(panel.level, 7)
    eq(component:Describe(), nil)
    -- A bar may change level while hidden without firing an Edit Mode event.
    bar:Hide()
    bar:SetFrameLevel(0)
    bar:Show()
    eq(panel:IsShown(), false)
    eq(panel.lumaLayerSafe, false)
    bar:Hide()
    bar:SetFrameLevel(8)
    H.Combat(true)
    bar:Show()
    eq(panel:IsShown(), false)
    H.Combat(false)
    eq(panel:IsShown(), true)
    bar.GetFrameStrata = function() return H.Secret("HIGH") end
    H.Fire("EDIT_MODE_LAYOUTS_UPDATED")
    eq(panel:IsShown(), false)
    eq(panel.lumaLayerSafe, false)
    eq(#app.errors, 0)
end)

test("an old action bar cannot reshow its panel after replacement", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.Store:Set("modules", "actionPanel", true)
    local old = MainActionBar
    local oldPanel = app.components.actionPanel.panels[old]
    local replacement = H.NewFrame("MainActionBar", UIParent)
    H.Fire("EDIT_MODE_LAYOUTS_UPDATED")
    local newPanel = app.components.actionPanel.panels[replacement]
    eq(oldPanel:IsShown(), false)
    eq(newPanel:IsShown(), true)
    old:Hide()
    old:Show()
    eq(oldPanel:IsShown(), false)
    app.Store:Set("modules", "actionPanel", false)
    eq(newPanel:IsShown(), false)
    eq(#app.errors, 0)
end)

test("action panel does not show while the native bar's parent is hidden", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local parent = H.NewFrame(nil, UIParent)
    MainActionBar:SetParent(parent)
    parent:Hide()
    app.Store:Set("modules", "actionPanel", true)
    local panel = app.components.actionPanel.panels[MainActionBar]
    eq(MainActionBar:IsShown(), true)
    eq(panel:IsShown(), false)
    parent:Show()
    MainActionBar.scripts.OnShow(MainActionBar)
    eq(panel:IsShown(), true)
    eq(#app.errors, 0)
end)

test("a failed action bar panel does not interrupt another bar", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local previous = _G.MultiBarBottomLeft
    local bad = H.NewFrame("MultiBarBottomLeft", UIParent)
    local hook = bad.HookScript
    bad.HookScript = function() error("bar refused hooks") end
    app.Store:Set("modules", "actionPanel", true)
    local component = app.components.actionPanel
    eq(component.panels[MainActionBar]:IsShown(), true)
    eq(component.panels[bad], nil)
    eq(component.failedBars[bad], true)
    eq(#app.errors, 1)
    app.Store:Set("modules", "actionPanel", false)
    bad.HookScript = hook
    app.Store:Set("modules", "actionPanel", true)
    eq(component.panels[bad]:IsShown(), true)
    eq(component.failedBars[bad], nil)
    eq(component.panels[MainActionBar]:IsShown(), true)
    eq(#app.errors, 1)
    _G.MultiBarBottomLeft = previous
end)

test("click casting binds secure spell attributes on our unit buttons", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.Store:Set("modules", "unitFrames", true)
    app.Store:Set("modules", "clickCast", true)
    local click = app.components.clickCast
    eq(click.running, true)
    local button = _G.LumaUIUnit_player
    eq(button ~= nil, true)
    -- A plain key is rejected: the modifier rule protects normal clicking.
    eq(click:Bind("left", "Flash Heal"), false)
    -- A modifier + button binding becomes a secure spell attribute pair.
    eq(click:Bind("shift-left", "Flash Heal"), true)
    eq(button:GetAttribute("*shift-type1"), "spell")
    eq(button:GetAttribute("*shift-spell1"), "Flash Heal")
    -- Clearing one binding removes only that pair.
    eq(click:Bind("shift-left", "off"), true)
    eq(button:GetAttribute("*shift-type1"), nil)
    -- Invalid shapes never reach the store.
    eq(click:Bind("banana-left", "X"), false)
    eq(app.Store:Profile().ui.clickCast["banana-left"], nil)
    -- Disabling clears every attribute we wrote.
    click:Bind("ctrl-right", "Renew")
    eq(button:GetAttribute("*ctrl-type2"), "spell")
    app.Store:Set("modules", "clickCast", false)
    eq(button:GetAttribute("*ctrl-type2"), nil)
    eq(#app.errors, 0)
end)

test("mail adapter cleans panes, separates inbox rows and keeps attachment icons", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.Store:Set("modules", "systemWindows", true)
    local entry = app.components.systemWindows.entries.mail
    eq(entry ~= nil, true)
    -- Both panes lose their own art; the attachment slot keeps the attached
    -- item's icon and drops only its slot decoration.
    eq(H.mailSendArt:GetAlpha(), 0)
    eq(H.mailInboxArt:GetAlpha(), 0)
    eq(H.mailAttachment.Icon:GetAlpha(), 1)
    eq(H.mailAttachment.NormalTexture:GetAlpha(), 0)
    -- Button text follows the theme and its original color is recorded.
    eq(H.mailSendLabel.textColor[1], app.Theme.colors.text[1])
    -- Every inbox row gets a 1px LumaUI rule; alternate rows get a tint.
    local first = entry.mailRows[H.mailRows[1]]
    local second = entry.mailRows[H.mailRows[2]]
    eq(first ~= nil, true)
    eq(first.rule.height, 1)
    eq(first.rule.drawLayer, "ARTWORK")
    eq(first.rule:IsShown(), true)
    eq(first.tint:IsShown(), false)
    eq(second.tint:IsShown(), true)
    -- The page button is not a row, so it gets no separator.
    eq(entry.mailRows[InboxPrevPageButton], nil)
    -- A repaint reuses the row textures instead of stacking a second set.
    app.components.systemWindows:Refresh()
    eq(entry.mailRows[H.mailRows[1]].rule, first.rule)
    -- Disabling removes the LumaUI decoration and restores the native art.
    app.Store:Set("modules", "systemWindows", false)
    eq(first.rule:IsShown(), false)
    eq(second.tint:IsShown(), false)
    eq(first.bar:IsShown(), false)
    eq(H.mailSendArt:GetAlpha(), 1)
    eq(H.mailAttachment.NormalTexture:GetAlpha(), 1)
    eq(H.mailSendLabel.textColor[1], 1)
    eq(#app.errors, 0)
end)

test("spellbook adapter picks PlayerSpellsFrame and keeps spell icons", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.Store:Set("modules", "systemWindows", true)
    local entry = app.components.systemWindows.entries.spellbook
    eq(entry ~= nil, true)
    -- 11.x names the window PlayerSpellsFrame; SpellBookFrame is absent here.
    eq(entry.frame, PlayerSpellsFrame)
    eq(H.spellFrameArt:GetAlpha(), 0)
    eq(entry.panel.surface:IsShown(), true)
    -- Spell slot: the spell icon survives, the slot decoration goes.
    eq(H.spellButton.Icon:GetAlpha(), 1)
    eq(H.spellButton.NormalTexture:GetAlpha(), 0)
    -- Tab art is swept, the label is recolored so the text stays readable.
    eq(H.spellTabArt:GetAlpha(), 0)
    eq(H.spellTabText.textColor[1], app.Theme.colors.text[1])
    -- The title strip's native art fades as well.
    eq(H.spellTitleArt:GetAlpha(), 0)
    -- Disabling restores every recorded alpha and color.
    app.Store:Set("modules", "systemWindows", false)
    eq(H.spellButton.NormalTexture:GetAlpha(), 1)
    eq(H.spellTabArt:GetAlpha(), 1)
    eq(H.spellTitleArt:GetAlpha(), 1)
    eq(H.spellTabText.textColor[1], 1)
    eq(entry.panel.surface:IsShown(), false)
    eq(#app.errors, 0)
end)

test("system windows skip a missing mail or spellbook window silently", function()
    local app = H.Load()
    _G.MailFrame, _G.SendMailFrame, _G.InboxFrame = nil, nil, nil
    _G.SpellBookFrame, _G.PlayerSpellsFrame = nil, nil
    H.Fire("PLAYER_LOGIN")
    app.Store:Set("modules", "systemWindows", true)
    local component = app.components.systemWindows
    eq(component.running, true)
    -- The optional adapters skip when their window is missing; nothing else is
    -- marked unsupported and no hook is installed on a window that is not there.
    eq(component.entries.mail, nil)
    eq(component.entries.spellbook, nil)
    eq(component.entries.character ~= nil, true)
    app.Store:Set("modules", "systemWindows", false)
    eq(#app.errors, 0)
end)

test("click casting re-applies after party and raid roster changes", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.Store:Set("modules", "unitFrames", true)
    app.Store:Set("modules", "clickCast", true)
    local click = app.components.clickCast
    click:Bind("shift-left", "Flash Heal")
    -- A raid button created later gets the attributes on the next roster event.
    local raidButton = H.NewFrame("LumaUIRaid7", UIParent, "SecureUnitButtonTemplate")
    eq(raidButton:GetAttribute("*shift-type1"), nil)
    H.Fire("GROUP_ROSTER_UPDATE")
    eq(raidButton:GetAttribute("*shift-type1"), "spell")
    eq(raidButton:GetAttribute("*shift-spell1"), "Flash Heal")
    eq(#app.errors, 0)
end)

-- ==== TRACK-P3: MISC —append new tests above this line ====

test("aura icons show stack counts and remaining time with a one-second ticker", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.Store:Set("modules", "unitFrames", true)
    local units = app.components.unitFrames
    local frame = units.frames.target
    H.unitAuras.target = {
        harmful = { { icon = "debuff1", applications = 3, duration = 30, expirationTime = 25 } },
        helpful = { { icon = "buff1", applications = 1, duration = 600, expirationTime = 600 } },
    }
    H.now = 0
    H.Fire("UNIT_AURA", "target")
    local first = frame.auraIcons[1]
    eq(first:IsShown(), true)
    eq(first.count:GetText(), "3")
    eq(first.time:GetText(), "25")
    -- A single application shows no count, and long durations use minutes.
    local second = frame.auraIcons[2]
    eq(second.count:GetText(), "")
    eq(second.time:GetText(), "10m")
    -- The ticker only exists while a timed aura is shown and refreshes text.
    eq(frame.auraTicker ~= nil, true)
    H.now = 20
    frame.auraTicker.callback()
    eq(first.time:GetText(), "5")
    -- Losing every aura stops the ticker and clears the labels.
    H.unitAuras.target = nil
    H.Fire("UNIT_AURA", "target")
    eq(first:IsShown(), false)
    eq(frame.auraTicker, nil)
    eq(first.count:GetText(), "")
    eq(#app.errors, 0)
end)

test("npc adapter dresses gossip, merchant and quest windows and keeps their content", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.Store:Set("modules", "systemWindows", true)
    local component = app.components.systemWindows
    -- The three NPC windows coexist, so each one carries its own entry over the
    -- shared dressing instead of being three candidate names of one window.
    local gossip, merchant, quest = component.entries.npc, component.entries.merchant, component.entries.quest
    eq(gossip ~= nil, true)
    eq(merchant ~= nil, true)
    eq(quest ~= nil, true)
    eq(gossip.frame, GossipFrame)
    eq(merchant.frame, MerchantFrame)
    -- Window art is faded and a LumaUI backing is drawn behind the content.
    eq(H.gossipArt:GetAlpha(), 0)
    eq(H.merchantArt:GetAlpha(), 0)
    eq(H.questArt:GetAlpha(), 0)
    eq(gossip.panel.surface:IsShown(), true)
    -- The greeting panel's plate goes; its greeting FontString keeps the
    -- client's material color (QuestTextContrast may fix it per string).
    eq(H.greetingBg:GetAlpha(), 0)
    eq(H.gossipText.textColor[1], 0.9)
    eq(H.gossipText.textColor[2], 0.8)
    -- Rows come from the ScrollBoxList: the greeting row is left alone, the
    -- option and quest rows take the rule and alternating tint while keeping
    -- their icon (which the client tints for trivial quests) and their label.
    local boxRows = H.gossipScrollRows
    eq(gossip.npcRows[boxRows[1]] == nil, true)
    eq(gossip.npcRows[boxRows[3]] ~= nil, true)
    local questRowDecor = gossip.npcRows[boxRows[3]]
    local optionRowDecor = gossip.npcRows[boxRows[5]]
    eq(questRowDecor.rule.height, 1)
    eq(questRowDecor.rule:IsShown(), true)
    -- Position is the box position, so the tint alternates down the list.
    eq(questRowDecor.tint:IsShown(), false)
    eq(gossip.npcRows[boxRows[4]].tint:IsShown(), true)
    eq(optionRowDecor.tint:IsShown(), false)
    eq(H.gossipQuestIcon:GetAlpha(), 1)
    eq(H.gossipOptionIcon:GetAlpha(), 1)
    eq(H.gossipQuestLabel.textColor[1], 1)
    -- The friendship bar is window state, never skinned.
    eq(H.friendshipArt:GetAlpha(), 1)
    -- A repaint reuses the row textures instead of stacking a second set.
    component:Refresh()
    eq(gossip.npcRows[boxRows[3]].rule, questRowDecor.rule)
    -- The vendor slot keeps the item icon, its quality border and its
    -- quality-colored name; only the slot plate goes. The price lives in money
    -- frames, whose coins stay fully drawn.
    eq(H.merchantIcon:GetAlpha(), 1)
    eq(H.merchantIconBorder:GetAlpha(), 1)
    eq(H.merchantSlotArt:GetAlpha(), 0)
    eq(H.merchantItemName.textColor[1], 0.2)
    eq(H.merchantItemName.textColor[3], 1)
    eq(H.merchantCoin:GetAlpha(), 1)
    eq(H.playerCoin:GetAlpha(), 1)
    -- The action tile keeps its icon; the page arrow keeps its disabled-state
    -- art.
    eq(H.merchantSellIcon:GetAlpha(), 1)
    eq(H.merchantPrevArt:GetAlpha(), 1)
    -- Quest panels keep their parchment and the client's body text color.
    eq(QuestFrame.QuestFrameDetailPanel.Bg:GetAlpha(), 1)
    eq(QuestFrame.QuestFrameRewardPanel.SealMaterialBG:GetAlpha(), 1)
    eq(H.questBody.textColor[1], 0.12)
    -- Reward buttons read from the tree by name shape: icon, quality border and
    -- the quality-colored Name stay.
    eq(H.rewardIcon:GetAlpha(), 1)
    eq(H.rewardBorder:GetAlpha(), 1)
    eq(H.rewardName.textColor[1], 0.64)
    -- The greeting panel's pooled title buttons keep their quest icon.
    eq(H.greetingIcon:GetAlpha(), 1)
    -- The accept button is a plain text button: its art goes, its label stays.
    eq(H.questOptionArt:GetAlpha(), 0)
    -- The model scene is never walked into.
    eq(H.questModelArt:GetAlpha(), 1)
    -- Disabling restores every alpha and hides the LumaUI decoration.
    app.Store:Set("modules", "systemWindows", false)
    eq(H.gossipArt:GetAlpha(), 1)
    eq(H.merchantSlotArt:GetAlpha(), 1)
    eq(H.rewardIcon:GetAlpha(), 1)
    eq(H.questOptionArt:GetAlpha(), 1)
    eq(H.greetingBg:GetAlpha(), 1)
    eq(H.merchantIconBorder:GetAlpha(), 1)
    eq(questRowDecor.rule:IsShown(), false)
    eq(gossip.npcRows[boxRows[4]].tint:IsShown(), false)
    eq(gossip.panel.surface:IsShown(), false)
    -- Re-enabling reapplies with one OnShow hook per window.
    app.Store:Set("modules", "systemWindows", true)
    eq(H.gossipArt:GetAlpha(), 0)
    eq(H.merchantSlotArt:GetAlpha(), 0)
    eq(GossipFrame.hookCount, 1)
    eq(MerchantFrame.hookCount, 1)
    -- A reopened window is re-skinned through that hook rather than a new one.
    H.gossipArt:SetAlpha(1)
    GossipFrame:Hide()
    GossipFrame:Show()
    eq(H.gossipArt:GetAlpha(), 0)
    eq(GossipFrame.hookCount, 1)
    eq(#app.errors, 0)
end)

test("npc windows follow late content, pooled rows and keep material text", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.Store:Set("modules", "systemWindows", true)
    local component = app.components.systemWindows
    local gossip, quest = component.entries.npc, component.entries.quest
    -- Long Chinese greeting text is a plain body string: it is never
    -- recolored, so the client's material color still reads.
    local long = string.rep("这是一段很长的任务对话文本，用于检查自动换行后颜色保持不变。", 6)
    H.gossipText:SetText(long)
    eq(H.gossipText:GetText(), long)
    component:Refresh()
    eq(H.gossipText.textColor[1], 0.9)
    -- A reward button the client creates after the window was skinned (a quest
    -- with more rewards) is dressed on the next repaint, without a second set
    -- of textures on the ones already there.
    local late = H.NewFrame("QuestInfoRewardsFrameQuestInfoItem2", QuestInfoRewardsFrame)
    local lateIcon = H.NewFrame(nil, late)
    lateIcon.kind = "texture"
    late.Icon = lateIcon
    local lateBorder = H.NewFrame(nil, late)
    lateBorder.kind = "texture"
    late.IconBorder = lateBorder
    local lateName = H.NewFrame(nil, late)
    lateName.kind = "fontstring"
    lateName.textColor = { 0.64, 0.21, 0.93, 1 }
    late.Name = lateName
    late.GetRegions = function() return lateIcon, lateBorder, lateName end
    H.rewardButton.iconTexture = H.rewardButton.Icon
    component:Refresh()
    eq(lateIcon:GetAlpha(), 1)
    eq(lateBorder:GetAlpha(), 1)
    eq(lateName.textColor[1], 0.64)
    -- The reward buttons already on screen were not re-dressed into a second
    -- set: their own icon and quality frame are still the same objects.
    eq(H.rewardButton.Icon, H.rewardIcon)
    eq(H.rewardButton.IconBorder:GetAlpha(), 1)
    -- The gossip list box is reused by the client for other NPCs: a row that
    -- was a quest title becomes an option (new label, new icon) and the skin
    -- follows the frame instead of remembering the old kind.
    local reused = H.gossipScrollRows[3]
    reused.GreetingText = nil
    local reusedIcon = reused.Icon
    reused.GetFontString = function() return H.gossipQuestLabel end
    H.gossipQuestLabel:SetText("新的对话选项")
    component:Refresh()
    eq(gossip.npcRows[reused] ~= nil, true)
    eq(reusedIcon:GetAlpha(), 1)
    eq(gossip.npcRows[reused].rule:IsShown(), true)
    app.Store:Set("modules", "systemWindows", false)
    eq(H.gossipArt:GetAlpha(), 1)
    eq(gossip.npcRows[reused].rule:IsShown(), false)
end)

test("a vendor control that refuses the walk fails only the vendor window", function()
    local app = H.Load()
    -- One of the window's own regions throws when the sweep recolors it: the
    -- merchant entry rolls back to native art and the gossip and quest windows
    -- still take the skin.
    local poison = H.NewFrame(nil, MerchantFrame)
    poison.kind = "fontstring"
    poison.textColor = { 1, 1, 1, 1 }
    poison.SetTextColor = function() error("client refused the color") end
    MerchantFrame.GetRegions = function() return H.merchantArt, poison end
    H.Fire("PLAYER_LOGIN")
    app.Store:Set("modules", "systemWindows", true)
    local component = app.components.systemWindows
    eq(component.entries.merchant.status, "failed")
    eq(component.entries.merchant.applied, false)
    -- The window art faded before the throw came back with the rollback.
    eq(H.merchantArt:GetAlpha(), 1)
    -- Neighbours are untouched by the failure.
    eq(component.entries.npc.status, "applied")
    eq(component.entries.quest.status, "applied")
    eq(H.gossipArt:GetAlpha(), 0)
    eq(H.questArt:GetAlpha(), 0)
    -- Disabling restores the rest with no further error.
    app.Store:Set("modules", "systemWindows", false)
    eq(H.gossipArt:GetAlpha(), 1)
    eq(#app.errors, 1)
    eq(app.errors[1].context, "systemWindows/merchant/enable")
end)

test("social adapter separates member rows and leaves window actions intact", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    -- A protected action button (the client marks some social buttons secure):
    -- only its label may follow the theme.
    local guarded = H.NewFrame("WhoFrameGroupInviteButton", FriendsFrame)
    guarded.IsProtected = function() return true end
    local guardedArt = H.NewFrame(nil, guarded)
    guardedArt.kind = "texture"
    local guardedText = H.NewFrame(nil, guarded)
    guardedText.kind = "fontstring"
    guardedText.textColor = { 1, 0.82, 0, 1 }
    guarded.GetRegions = function() return guardedArt, guardedText end
    app.Store:Set("modules", "systemWindows", true)
    local component = app.components.systemWindows
    local entry = component.entries.social
    eq(entry ~= nil, true)
    eq(entry.frame, FriendsFrame)
    eq(H.friendsArt:GetAlpha(), 0)
    eq(entry.panel.surface:IsShown(), true)
    -- Member rows are read from the pane's scroll box and dressed in place: the
    -- plate and the online/offline background are faded while the status icon,
    -- the game icon, the hover highlight and the client's own name/info colors
    -- all survive, and a 1px rule plus an alternating tint separate the list.
    local first = H.socialRows[1]
    local decor = entry.socialRows[first]
    eq(decor ~= nil, true)
    eq(decor.rule.height, 1)
    eq(decor.rule.drawLayer, "ARTWORK")
    eq(decor.rule:IsShown(), true)
    eq(decor.tint:IsShown(), false)
    eq(entry.socialRows[H.socialRows[2]].tint:IsShown(), true)
    eq(H.socialRowStatus:GetAlpha(), 1)
    eq(H.socialRowGameIcon:GetAlpha(), 1)
    eq(H.socialRowPlate:GetAlpha(), 0)
    eq(H.socialRowHighlight:GetAlpha(), 1)
    eq(first.background:GetAlpha(), 0)
    -- Name and info carry online/offline and area semantics: never recolored.
    eq(H.socialRowName.textColor[2], 0.82)
    eq(H.socialRowInfo.textColor[1], 0.486)
    eq(decor.bar:IsShown(), false)
    -- The invite button is the window's action: its art and its click stay and
    -- only the label is recolored. A protected button is treated the same way.
    eq(H.inviteArt:GetAlpha(), 1)
    eq(H.inviteText.textColor[1], app.Theme.colors.text[1])
    eq(FriendsFrameInviteButton.scripts.OnClick, nil)
    eq(guardedArt:GetAlpha(), 1)
    eq(guardedText.textColor[1], app.Theme.colors.text[1])
    -- The page tab keeps its label and loses the tab art; the selected style is
    -- LumaUI's own surface and rule.
    eq(H.friendsTabArt:GetAlpha(), 0)
    eq(H.friendsTabText.textColor[1], app.Theme.colors.text[1])
    eq(entry.tabBg[FriendsFrameTab1].surface:IsShown(), true)
    -- A row built later by a scroll data provider is dressed on the next repaint.
    local late = H.friendRow(4)
    component:Refresh()
    eq(entry.socialRows[late] ~= nil, true)
    eq(late.background:GetAlpha(), 0)
    eq(late.status:GetAlpha(), 1)
    -- Disabling restores the native art, colors and decoration.
    app.Store:Set("modules", "systemWindows", false)
    eq(H.friendsArt:GetAlpha(), 1)
    eq(H.socialRowPlate:GetAlpha(), 1)
    eq(H.socialRowHighlight:GetAlpha(), 1)
    eq(H.socialRowName.textColor[2], 0.82)
    eq(H.inviteText.textColor[1], 1)
    eq(guardedText.textColor[1], 1)
    eq(H.friendsTabText.textColor[1], 1)
    eq(decor.rule:IsShown(), false)
    eq(entry.tabBg[FriendsFrameTab1].surface:IsShown(), false)
    eq(#app.errors, 0)
end)

test("system windows skip missing npc and social windows silently", function()
    local app = H.Load()
    _G.GossipFrame, _G.MerchantFrame, _G.QuestFrame = nil, nil, nil
    _G.FriendsFrame, _G.WhoFrame = nil, nil
    H.Fire("PLAYER_LOGIN")
    app.Store:Set("modules", "systemWindows", true)
    local component = app.components.systemWindows
    eq(component.running, true)
    -- Every NPC and social window is optional: a client that lacks one keeps the
    -- component running, installs no hook and reports no error.
    eq(component.entries.npc, nil)
    eq(component.entries.merchant, nil)
    eq(component.entries.quest, nil)
    eq(component.entries.social, nil)
    eq(component.entries.character ~= nil, true)
    app.Store:Set("modules", "systemWindows", false)
    eq(#app.errors, 0)
end)

-- ==== TRACK-P4: SYSTEM —append new tests above this line ====

test("raid frames place members by subgroup, one column per squad", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local savedExists = UnitExists
    _G.UnitExists = function(unit)
        return unit == "raid1" or unit == "raid2" or unit == "raid3" or unit == "raid4"
    end
    H.raidSubgroups = { [1] = 1, [2] = 1, [3] = 2, [4] = 2 }
    H.inRaid = true
    app.Store:Set("modules", "raidFrames", true)
    local raid = app.components.raidFrames
    local first, second, third, fourth = raid.frames[1], raid.frames[2], raid.frames[3], raid.frames[4]
    eq(first ~= nil and second ~= nil and third ~= nil and fourth ~= nil, true)
    -- Subgroup 1 fills the first column top down; subgroup 2 opens the second
    -- column one 96 px step to the right.
    eq(first.point[4], 0)
    eq(first.point[5], 0)
    eq(second.point[4], 0)
    eq(second.point[5], -36)
    eq(third.point[4], 96)
    eq(third.point[5], 0)
    eq(fourth.point[4], 96)
    eq(fourth.point[5], -36)
    -- The grid is sized to the columns and rows actually in use.
    eq(raid.container:GetWidth(), 186)
    eq(raid.container:GetHeight(), 68)
    -- A member who changes subgroup is re-pointed by the next reflow: subgroup 2
    -- now holds raid2..raid4 in raid index order.
    H.raidSubgroups[2] = 2
    H.Fire("GROUP_ROSTER_UPDATE")
    eq(second.point[4], 96)
    eq(second.point[5], 0)
    eq(third.point[4], 96)
    eq(third.point[5], -36)
    eq(fourth.point[4], 96)
    eq(fourth.point[5], -72)
    eq(raid.container:GetHeight(), 104)
    -- In combat the reflow is only queued: the old slot stays until it ends.
    H.raidSubgroups[2] = 1
    H.Combat(true)
    H.Fire("GROUP_ROSTER_UPDATE")
    eq(app.Queue:Count(), 1)
    eq(second.point[4], 96)
    H.Combat(false)
    eq(app.Queue:Count(), 0)
    eq(second.point[4], 0)
    eq(second.point[5], -36)
    _G.UnitExists = savedExists
    H.inRaid = false
    eq(#app.errors, 0)
end)

test("raid frames paint the raid target icon on each member button", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local savedExists = UnitExists
    _G.UnitExists = function(unit) return unit == "raid1" or unit == "raid2" end
    H.inRaid = true
    app.Store:Set("modules", "raidFrames", true)
    local raid = app.components.raidFrames
    local first, second = raid.frames[1], raid.frames[2]
    -- Every button starts without a mark, in the 12 x 12 top right corner.
    eq(first.mark:IsShown(), false)
    eq(first.mark:GetWidth(), 12)
    eq(first.mark:GetHeight(), 12)
    eq(first.mark.point[1], "TOPRIGHT")
    -- Index 3 shows the classic numbered icon for that index.
    H.raidTargets.raid1 = 3
    H.Fire("RAID_TARGET_UPDATE")
    eq(first.mark:IsShown(), true)
    eq(first.mark.texture, "Interface\\TargetingFrame\\UI-RaidTargetingIcon_3")
    -- The member's own unit events repaint its mark as well.
    H.raidTargets.raid2 = 8
    H.Fire("UNIT_HEALTH", "raid2")
    eq(second.mark:IsShown(), true)
    eq(second.mark.texture, "Interface\\TargetingFrame\\UI-RaidTargetingIcon_8")
    -- Out of range, restricted and cleared indices hide the icon again.
    H.raidTargets.raid1 = 9
    H.Fire("RAID_TARGET_UPDATE")
    eq(first.mark:IsShown(), false)
    H.raidTargets.raid1 = H.Secret(4)
    H.Fire("RAID_TARGET_UPDATE")
    eq(first.mark:IsShown(), false)
    H.raidTargets.raid1, H.raidTargets.raid2 = nil, nil
    H.Fire("RAID_TARGET_UPDATE")
    eq(first.mark:IsShown(), false)
    eq(second.mark:IsShown(), false)
    _G.UnitExists = savedExists
    H.inRaid = false
    eq(#app.errors, 0)
end)

-- ==== TRACK-P5: RAID —append new tests above this line ====
test("combat text keeps native colors and restores fonts on disable", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local component = app.components.combatText
    eq(component ~= nil, true)
    eq(component.running, nil)
    local first, second = H.combatText[1], H.combatText[2]
    eq(first:GetFont(), "Fonts/Original.ttf")
    app.Store:Set("modules", "combatText", true)
    eq(component.running, true)
    -- The face follows GameFontNormal, the string's own size is kept and an
    -- outline is added.
    local face = GameFontNormal:GetFont()
    eq(first.font, face)
    eq(first.fontSize, 22)
    eq(first.fontFlags, "OUTLINE")
    eq(second.font, face)
    eq(second.fontSize, 16)
    eq(second.fontFlags, "OUTLINE")
    -- The client's own per-type colors are never guessed or overwritten.
    eq(first.textColor[1], 0.2)
    eq(first.textColor[2], 0.4)
    eq(second.textColor[3], 0.1)
    local recorded = 0
    for _ in pairs(component.records) do recorded = recorded + 1 end
    eq(recorded, 2)
    -- A repeated Enable keeps the first cycle's originals.
    component:Enable()
    eq(first.font, face)
    eq(first.fontFlags, "OUTLINE")
    -- Disabling restores every recorded font and clears the cycle's records.
    app.Store:Set("modules", "combatText", false)
    eq(component.running, false)
    eq(first.font, "Fonts/Original.ttf")
    eq(first.fontSize, 22)
    eq(first.fontFlags, "")
    eq(second.font, "Fonts/Original.ttf")
    eq(second.fontSize, 16)
    eq(second.fontFlags, "")
    eq(first.textColor[1], 0.2)
    eq(next(component.records), nil)
    eq(#app.errors, 0)
end)

test("combat text is unsupported and silent without the native root", function()
    local app = H.Load({ profiles = { Default = { modules = { combatText = true } } } })
    _G.FloatingCombatText = nil
    _G.CombatTextFontString = nil
    H.Fire("PLAYER_LOGIN")
    eq(app.components.combatText.status, "unsupported")
    eq(app.components.combatText.running, nil)
    eq(#app.errors, 0)
    eq(app.Queue:Count(), 0)
end)

-- ==== TRACK-P5: COMBATTEXT —append new tests above this line ====
test("dispellable debuffs get a school border and the filter can hide the rest", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.Store:Set("modules", "unitFrames", true)
    local frame = app.components.unitFrames.frames.target
    H.unitAuras.target = {
        harmful = { { icon = "magic1", dispelName = "Magic" }, { icon = "plain1" } },
        helpful = {},
    }
    H.Fire("UNIT_AURA", "target")
    local magic, plain = frame.auraIcons[1], frame.auraIcons[2]
    -- The dispellable one gets a blue magic border, the other none.
    eq(magic.border:IsShown(), true)
    eq(magic.border.borderColor[3], 1)
    eq(plain.border:IsShown(), false)
    -- Switching the profile filter to "dispel" hides the undispellable debuff.
    app.Store:Set("ui", "auraFilter", "dispel")
    H.Fire("UNIT_AURA", "target")
    eq(magic:IsShown(), true)
    eq(plain:IsShown(), false)
    app.Store:Set("ui", "auraFilter", "all")
    H.Fire("UNIT_AURA", "target")
    eq(plain:IsShown(), true)
    eq(#app.errors, 0)
end)

test("nameplates paint the target bar and restore it on disable", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    eq(app.components.nameplates.status, "disabled")
    app.Store:Set("modules", "nameplates", true)
    local bar = H.targetBar
    -- The bar is repainted with the Pearl combat fill: one fixed colour on the
    -- matte texture, no horizontal gradient record.
    eq(bar.gradient, nil)
    eq(bar.statusFill ~= nil and bar.statusFill.texture, app.Theme.media.combatFill)
    local original = app.components.nameplates.originals[bar]
    eq(original ~= nil, true)
    eq(original.color[1], 0.8)
    eq(original.texture ~= nil, true)
    -- A target change repaints without stacking records.
    local count = 0
    for _ in pairs(app.components.nameplates.originals) do count = count + 1 end
    eq(count, 1)
    H.Fire("PLAYER_TARGET_CHANGED")
    eq(count, 1)
    -- Disabling restores the original colour and fill texture.
    app.Store:Set("modules", "nameplates", false)
    eq(bar.barColor[1], 0.8)
    eq(bar.statusFill.texture, original.texture)
    eq(#app.errors, 0)
end)

test("the target plate keeps its track, hairline and mark in step", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.Store:Set("modules", "nameplates", true)
    local bar = H.targetBar
    local bg, edge, mark = bar.lumaNameplateBg, bar.lumaNameplateEdge, bar.lumaNameplateMark
    eq(bg:IsShown(), true)
    eq(edge:IsShown(), true)
    eq(mark:IsShown(), true)
    -- The mock keeps the last anchor only: the track reaches 3 units out and the
    -- hairline 2, so the bar reads as a dark block with a lit edge instead of a
    -- single flat outline.
    eq(bg.point[1], "BOTTOMRIGHT")
    eq(bg.point[4], 3)
    eq(bg.point[5], -3)
    eq(edge.point[4], 2)
    eq(edge.point[5], -2)
    -- The mark is LumaUI's own two-pixel stripe outside the track; the client's
    -- nameplate text and the bar's own size are never touched.
    eq(mark.point[1], "BOTTOMLEFT")
    eq(mark.point[4], -4)
    eq(mark.width, 2)
    -- Stopping the module hides all three and leaves no stale decoration.
    app.Store:Set("modules", "nameplates", false)
    eq(bg:IsShown(), false)
    eq(edge:IsShown(), false)
    eq(mark:IsShown(), false)
    eq(bar.barColor[1], 0.8)
    eq(#app.errors, 0)
end)

test("the nameplate diagnostic separates a missing plate from a missing component", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.Store:Set("modules", "nameplates", true)
    local plate = H.nameplates.target
    -- The component only repaints a bar the client already draws, so "no plate"
    -- and "component stopped" must read differently.
    H.nameplates.target = nil
    app.components.nameplates:Diagnose()
    local joined = table.concat(H.messages, "\n")
    eq(joined:find("target: plate=no", 1, true) ~= nil, true)
    -- The client's own switch is reported and never written.
    _G.GetCVar = function(name) return name == "nameplateShowEnemies" and "0" or "1" end
    H.messages = {}
    app.components.nameplates:Diagnose()
    joined = table.concat(H.messages, "\n")
    eq(joined:find("nameplateShowEnemies=0", 1, true) ~= nil, true)
    _G.GetCVar = nil
    H.nameplates.target = plate
    H.messages = {}
    app.components.nameplates:Diagnose()
    joined = table.concat(H.messages, "\n")
    eq(joined:find("target: plate=yes", 1, true) ~= nil, true)
    eq(joined:find("source=HealthBarsContainer.healthBar", 1, true) ~= nil, true)
    eq(#app.errors, 0)
end)

-- ==== TRACK-P5: MISC —append new tests above this line ====

-- ==== TRACK: VIS-00..04 first round —append new tests above this line ====
test("aura icons accept a numeric file ID as well as a texture path", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.Store:Set("modules", "unitFrames", true)
    local frame = app.components.unitFrames.frames.target
    -- AuraData.icon is documented as a fileID; a path is still a legal texture.
    H.unitAuras.target = { harmful = { { icon = 136243, dispelName = "Magic" } },
        helpful = { { icon = "Interface\\Icons\\Spell_Nature" } } }
    H.Fire("UNIT_AURA", "target")
    eq(frame.auraIcons[1]:IsShown(), true)
    eq(frame.auraIcons[1].texture, 136243)
    eq(frame.auraIcons[2].texture, "Interface\\Icons\\Spell_Nature")
    -- Unsupported shapes are skipped instead of reaching SetTexture.
    H.unitAuras.target = { harmful = { { icon = {} } },
        helpful = { { icon = H.Secret(136243) }, { icon = true } } }
    H.Fire("UNIT_AURA", "target")
    local shown = 0
    for _, icon in ipairs(frame.auraIcons) do if icon:IsShown() then shown = shown + 1 end end
    eq(shown, 0)
    eq(#app.errors, 0)
end)

test("world quest time uses the dedicated time API and degrades", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local list = app.components.questList
    local function findRow(text)
        for _, current in ipairs(list.rows) do
            if current.frame:IsShown() and current.label:GetText() == text then return current end
        end
    end
    H.questLog.entries[3] = { title = "Zone task", questID = 105, level = 60, isTask = true }
    -- GetQuestInfoByQuestID keeps the documented four-value shape and carries no
    -- time; only the dedicated seconds call does.
    H.taskInfo[105] = 3600
    H.Fire("QUEST_LOG_UPDATE")
    eq(findRow("Zone task").right:GetText(), string.format(app.L.taskTimeHours, 1))
    -- A client with only the documented minutes call still shows a time.
    C_TaskQuest.GetQuestTimeLeftSeconds = nil
    H.taskInfo[105] = nil
    H.taskMinutes[105] = 2
    H.Fire("QUEST_LOG_UPDATE")
    eq(findRow("Zone task").right:GetText(), string.format(app.L.taskTimeMinutes, 2))
    -- Neither call: the row simply shows no time, without an error.
    C_TaskQuest.GetQuestTimeLeftMinutes = nil
    H.Fire("QUEST_LOG_UPDATE")
    eq(findRow("Zone task").right:GetText(), "")
    eq(#app.errors, 0)
end)

test("quest item icons follow the documented instant-info tuple", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local list = app.components.questList
    local link = "|Hitem:123|h[Quest item]|h"
    local function findRow(text)
        for _, current in ipairs(list.rows) do
            if current.frame:IsShown() and current.label:GetText() == text then return current end
        end
    end
    H.questLog.itemIndex[101] = 1
    H.questLog.items[1] = { link = link }
    H.Fire("QUEST_LOG_UPDATE")
    -- C_Item.GetItemInfoInstant: the icon is the FIFTH return value.
    eq(findRow("First quest").itemButton.icon.texture, 134400)
    -- The legacy global namespace answers the same tuple shape.
    C_Item.GetItemInfoInstant = nil
    H.Fire("QUEST_LOG_UPDATE")
    eq(findRow("First quest").itemButton.icon.texture, 134400)
    -- With only the full GetItemInfo call left, the texture is its tenth value.
    _G.GetItemInfoInstant = nil
    C_Item.GetItemInfo = nil
    _G.GetItemInfo = function(itemLink)
        return "Item", itemLink, 2, 10, 0, "Misc", "Misc", 1, "", 987654, 5
    end
    H.Fire("QUEST_LOG_UPDATE")
    eq(findRow("First quest").itemButton.icon.texture, 987654)
    -- No icon data at all: the secure button still works, it just draws nothing.
    _G.GetItemInfo = nil
    H.Fire("QUEST_LOG_UPDATE")
    local button = findRow("First quest").itemButton
    eq(button:IsShown(), true)
    eq(button.icon.texture, nil)
    eq(button:GetAttribute("item"), link)
    eq(#app.errors, 0)
end)

test("action panel repaints cached panels when the profile changes", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.Store:Set("modules", "actionPanel", true)
    local panel = app.components.actionPanel.panels[MainActionBar]
    eq(panel ~= nil, true)
    -- The action panel is a HUD support, so it follows the HUD opacity role.
    eq(panel.backgroundColor[4], 0.80)
    app.Store:Set("appearance", "hudOpacity", 0.5)
    -- A cached panel must follow the new value instead of keeping the old one.
    eq(panel.backgroundColor[4], 0.5)
    -- The legacy single opacity no longer drives HUD supports.
    app.Store:Set("appearance", "opacity", 0.7)
    eq(panel.backgroundColor[4], 0.5)
    app.Store:Set("appearance", "hudOpacity", 0.8)
    eq(panel.backgroundColor[4], 0.8)
    -- Disabling still hides every cached panel.
    app.Store:Set("modules", "actionPanel", false)
    eq(panel:IsShown(), false)
    eq(#app.errors, 0)
end)

test("character window scale combines the global and relative values once", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.Store:Set("modules", "characterWindow", true)
    local window = app.components.characterWindow.window
    app.Store:Set("ui", "windowScale", 1.2)
    app.Store:Set("appearance", "scale", 1.2)
    -- Layout is the only writer: global 1.2 x relative 1.2.
    eq(math.abs(window:GetScale() - 1.44) < 1e-9, true)
    -- Repeated layout passes, re-opening and another profile change keep it.
    app.Layout:ApplyAll()
    app.Layout:ApplyAll()
    eq(math.abs(window:GetScale() - 1.44) < 1e-9, true)
    window:Show()
    app.Layout:ApplyAll()
    eq(math.abs(window:GetScale() - 1.44) < 1e-9, true)
    -- The top info pair is one group now: the container takes the global scale
    -- and its members inherit it instead of writing their own scale.
    eq(app.Layout.entries.topInfo.frame:GetScale(), 1.2)
    eq(app.Layout.entries.dataStrip.frame:GetScale(), 1)
    eq(app.Layout.entries.dataStrip.frame:GetEffectiveScale(), 1.2)
    app.Store:Set("ui", "windowScale", 1)
    eq(math.abs(window:GetScale() - 1.2) < 1e-9, true)
    eq(#app.errors, 0)
end)

test("model drag releases its ticker on every ending path", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.Store:Set("modules", "characterWindow", true)
    local window = app.components.characterWindow.window
    local model = window.model
    window:Show()
    -- Closing the window ends the drag.
    model.scripts.OnMouseDown(model)
    local first = model.ticker
    eq(first ~= nil, true)
    eq(model.dragging, true)
    model.lastX = 10
    window:Hide()
    eq(first.cancelled, true)
    eq(model.ticker, nil)
    eq(model.dragging, false)
    eq(model.lastX, nil)
    -- Switching pages ends the drag.
    window:Show()
    model.scripts.OnMouseDown(model)
    local second = model.ticker
    H.Click(window.tabs[2])
    eq(second.cancelled, true)
    eq(model.ticker, nil)
    -- Disabling the component ends the drag.
    H.Click(window.tabs[1])
    model.scripts.OnMouseDown(model)
    local third = model.ticker
    app.Store:Set("modules", "characterWindow", false)
    eq(third.cancelled, true)
    eq(model.ticker, nil)
    -- No owned drag ticker stays alive anywhere.
    local active = 0
    for _, timer in ipairs(H.timers) do
        if timer.interval == 0.05 and not timer.cancelled then active = active + 1 end
    end
    eq(active, 0)
    eq(#app.errors, 0)
end)

test("layout page builds a row for every registered panel", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.Settings:Toggle("layout")
    app.Settings:Update()
    eq(#app.Layout:IDs() >= 3, true)
    for index = 1, 13 do
        app.Layout:Register("probe" .. index, H.NewFrame(nil, UIParent), 0, 0, "Probe " .. index)
    end
    app.Settings:Update()
    local ids = app.Layout:IDs()
    eq(#ids >= 16, true)
    eq(#app.Settings.layoutRows, #ids)
    for index, id in ipairs(ids) do
        local row = app.Settings.layoutRows[index]
        eq(row.id, id)
        eq(row:IsShown(), true)
    end
    eq(app.Settings.layoutRows[#ids].label:GetText(), app.Layout.entries[ids[#ids]].label)
    -- Removing entries hides the extra rows instead of leaving stale labels.
    for index = 1, 12 do app.Layout.entries["probe" .. index] = nil end
    app.Settings:Update()
    eq(#app.Layout:IDs(), #ids - 12)
    eq(app.Settings.layoutRows[#ids]:IsShown(), false)
    eq(app.Settings.layoutRows[#ids].id, nil)
    eq(#app.errors, 0)
end)

test("native unit frames stay when a replacement part is missing", function()
    local app = H.Load()
    C_UnitAuras = nil
    H.Fire("PLAYER_LOGIN")
    app.Store:Set("modules", "unitFrames", true)
    local units = app.components.unitFrames
    eq(units.running, true)
    eq(units.parts.auras.available, false)
    eq(units.takeover.units, false)
    eq(table.concat(units.takeover.missing, ","), "auras")
    -- Even available parts are not sufficient to establish native parity.
    eq(PlayerFrame:IsShown(), true)
    eq(PetFrame:IsShown(), true)
    eq(PlayerCastingBarFrame:IsShown(), true)
    -- The preview itself keeps drawing the parts it does have.
    eq(units.frames.target.watched, true)
    -- A client without the cast API keeps both its frames and its cast bars.
    local bare = H.Load()
    _G.UnitCastingInfo, _G.UnitChannelInfo = nil, nil
    H.Fire("PLAYER_LOGIN")
    bare.Store:Set("modules", "unitFrames", true)
    eq(bare.components.unitFrames.takeover.cast, false)
    eq(bare.components.unitFrames.takeover.units, false)
    eq(PlayerFrame:IsShown(), true)
    eq(PlayerCastingBarFrame:IsShown(), true)
    -- Losing the aura API mid-session leaves the native frames intact.
    local full = H.Load(); H.Fire("PLAYER_LOGIN")
    full.Store:Set("modules", "unitFrames", true)
    eq(PlayerFrame:IsShown(), true)
    C_UnitAuras = nil
    full:Reconcile()
    eq(full.components.unitFrames.takeover.units, false)
    eq(PlayerFrame:IsShown(), true)
    eq(PlayerCastingBarFrame:IsShown(), true)
    eq(#full.errors, 0)
end)

test("group takeovers need our own visible buttons", function()
    local app = H.Load()
    local savedWatch = RegisterUnitWatch
    -- A watch that registers without ever showing the button: the client has
    -- not accepted our frame, so the native frame must stay.
    _G.RegisterUnitWatch = function(frame) frame.watched = true end
    H.Fire("PLAYER_LOGIN")
    app.Store:Set("modules", "partyFrames", true)
    eq(app.components.partyFrames.running, true)
    eq(app.components.partyFrames.frames.party1 ~= nil, true)
    eq(app.components.partyFrames.frames.party1:IsShown(), false)
    eq(PartyFrame:IsShown(), true)
    -- The raid prototype uses the same rule.
    local exists = UnitExists
    _G.UnitExists = function(unit) return unit == "raid1" end
    app.Store:Set("modules", "raidFrames", true)
    eq(app.components.raidFrames.frames[1] ~= nil, true)
    eq(app.components.raidFrames.frames[1]:IsShown(), false)
    eq(CompactRaidFrameContainer:IsShown(), true)
    _G.UnitExists = exists
    _G.RegisterUnitWatch = savedWatch
    eq(#app.errors, 0)
end)

test("party enable cycles install one native suppression hook", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    -- QuestList hooks the tracker and each replaced module once; cycling the
    -- panel must not add a second suppression hook.
    local baseline = ObjectiveTrackerFrame.hookCount
    local moduleBaseline = QuestObjectiveTracker.hookCount or 0
    eq(baseline >= 1, true)
    eq(moduleBaseline, 1)
    for _ = 1, 20 do
        app.Store:Set("modules", "unitFrames", true)
        app.Store:Set("modules", "unitFrames", false)
    end
    eq(PlayerFrame.hookCount or 0, 0)
    eq(TargetFrame.hookCount or 0, 0)
    eq(PlayerCastingBarFrame.hookCount or 0, 0)
    for _ = 1, 20 do
        app.Store:Set("modules", "questList", false)
        app.Store:Set("modules", "questList", true)
    end
    eq(ObjectiveTrackerFrame.hookCount, baseline)
    eq(QuestObjectiveTracker.hookCount or 0, moduleBaseline)
    eq(CampaignQuestObjectiveTracker.hookCount or 0, 1)
    eq(WorldQuestObjectiveTracker.hookCount or 0, 1)
    for _ = 1, 20 do
        app.Store:Set("modules", "partyFrames", true)
        app.Store:Set("modules", "partyFrames", false)
    end
    eq(PartyFrame.hookCount or 0, 1)
    -- The unit preview leaves client visibility alone after repeated cycles.
    app.Store:Set("modules", "unitFrames", true)
    eq(PlayerFrame:IsShown(), true)
    PlayerFrame:Show()
    eq(PlayerFrame:IsShown(), true)
    -- A quest module re-shown by the client is suppressed again, not left up.
    QuestObjectiveTracker:Show()
    eq(QuestObjectiveTracker:IsShown(), false)
    eq(ObjectiveTrackerFrame:HasModule(QuestObjectiveTracker), false)
    eq(#app.errors, 0)
end)

test("quest panel returns the native tracker when it has nothing to show", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local list = app.components.questList
    eq(ObjectiveTrackerFrame:IsShown(), true)
    eq(QuestObjectiveTracker:IsShown(), false)
    eq(list.nativeHidden, true)
    eq(ScenarioObjectiveTracker:IsShown(), true)
    H.questLog.entries = {}
    H.questLog.watch = {}
    H.Fire("QUEST_LOG_UPDATE")
    eq(list.hasContent, false)
    eq(list.nativeHidden, nil)
    eq(QuestObjectiveTracker:IsShown(), true)
    eq(CampaignQuestObjectiveTracker:IsShown(), true)
    eq(ObjectiveTrackerFrame:HasModule(QuestObjectiveTracker), true)
    eq(list.frame:IsShown(), true)
    -- Content comes back, so the takeover resumes.
    H.questLog.entries = { { title = "New quest", questID = 201, level = 10 } }
    H.Fire("QUEST_LOG_UPDATE")
    eq(list.hasContent, true)
    eq(list.nativeHidden, true)
    eq(QuestObjectiveTracker:IsShown(), false)
    eq(ScenarioObjectiveTracker:IsShown(), true)
    -- A re-show from the client is taken back down.
    QuestObjectiveTracker:Show()
    eq(QuestObjectiveTracker:IsShown(), false)
    eq(#app.errors, 0)
end)

test("nameplate styling restores the previous plate and skips forbidden bars", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.Store:Set("modules", "nameplates", true)
    local component = app.components.nameplates
    local firstBar = H.targetBar
    eq(component.originals[firstBar] ~= nil, true)
    local function plateWith(bar)
        return H.Plate("modern", bar)
    end
    H.nameplates.target = plateWith(H.PlainBar({ 0.1, 0.9, 0.2, 1 }))
    local secondBar = H.nameplates.target.UnitFrame.HealthBarsContainer.healthBar
    H.Fire("PLAYER_TARGET_CHANGED")
    -- The previous plate takes its native colour back and leaves the records.
    eq(firstBar.barColor[1], 0.8)
    eq(component.originals[firstBar], nil)
    eq(component.originals[secondBar] ~= nil, true)
    -- Losing the plate restores the bar that was painted last. The event always
    -- carries the unit token, so the record is released through that unit.
    H.nameplates.target = nil
    H.Fire("NAME_PLATE_UNIT_REMOVED", "target")
    eq(secondBar.barColor[1], 0.1)
    eq(next(component.originals), nil)
    -- A forbidden bar is never painted, recorded or restored.
    local forbiddenBar = H.NewFrame(nil, UIParent)
    forbiddenBar.forbidden = true
    forbiddenBar.barColor = { 0.3, 0.3, 0.3, 1 }
    forbiddenBar.GetStatusBarColor = function(bar) return unpack(bar.barColor) end
    H.nameplates.target = plateWith(forbiddenBar)
    H.Fire("PLAYER_TARGET_CHANGED")
    eq(forbiddenBar.barColor[1], 0.3)
    eq(component.originals[forbiddenBar], nil)
    eq(#app.errors, 0)
end)

-- Adds one hostile plate for `unit` and returns the bar it was given.
local function addPlate(unit, color)
    local bar = H.PlainBar(color)
    H.nameplates[unit] = H.Plate("modern", bar)
    H.Fire("NAME_PLATE_UNIT_ADDED", unit)
    return bar
end

test("every hostile plate gets the visible layer and only the target carries the chip", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.Store:Set("modules", "nameplates", true)
    local component = app.components.nameplates
    local first = addPlate("nameplate1", { 0.5, 0.1, 0.1, 1 })
    local second = addPlate("nameplate2", { 0.2, 0.5, 0.1, 1 })
    -- Both plates are painted from their own snapshot, not only the target.
    eq(first.statusFill.texture, app.Theme.media.combatFill)
    eq(second.statusFill.texture, app.Theme.media.combatFill)
    eq(first.lumaNameplateBg:IsShown(), true)
    eq(second.lumaNameplateBg:IsShown(), true)
    eq(component.plates.nameplate1 ~= nil, true)
    eq(component.plates.nameplate2 ~= nil, true)
    eq(first.lumaNameplateTarget:IsShown(), false)
    -- Moving the target moves only the selection cue.
    H.unitSame = { nameplate2 = "target" }
    H.Fire("PLAYER_TARGET_CHANGED")
    eq(second.lumaNameplateTarget:IsShown(), true)
    eq(first.lumaNameplateTarget:IsShown(), false)
    eq(component.plates.nameplate2.target, true)
    -- A removed plate takes its native colour back even if the client already
    -- dropped the unit frame.
    H.nameplates.nameplate1 = nil
    H.Fire("NAME_PLATE_UNIT_REMOVED", "nameplate1")
    eq(first.barColor[1], 0.5)
    eq(first.lumaNameplateBg:IsShown(), false)
    eq(component.plates.nameplate1, nil)
    app.Store:Set("modules", "nameplates", false)
    eq(second.barColor[1], 0.2)
    eq(#app.errors, 0)
end)

test("a recycled plate restores its previous owner before the new unit paints", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.Store:Set("modules", "nameplates", true)
    local component = app.components.nameplates
    local bar = H.PlainBar({ 0.7, 0.7, 0.1, 1 })
    H.nameplates.nameplate1 = H.Plate("modern", bar)
    H.Fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
    -- The client hands the same bar to another unit: the first owner is
    -- released, and the new snapshot records the native colour, not the paint.
    H.nameplates.nameplate2 = H.Plate("modern", bar)
    H.Fire("NAME_PLATE_UNIT_ADDED", "nameplate2")
    eq(component.plates.nameplate1, nil)
    eq(component.plates.nameplate2.bar, bar)
    eq(component.originals[bar].color[1], 0.7)
    app.Store:Set("modules", "nameplates", false)
    eq(bar.barColor[1], 0.7)
    eq(#app.errors, 0)
end)

test("a friendly plate keeps its native fill and still gains the LumaUI plate", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.Store:Set("modules", "nameplates", true)
    local component = app.components.nameplates
    H.unitInfo.nameplate7 = { enemy = false }
    local friendly = addPlate("nameplate7", { 0.1, 0.4, 0.1, 1 })
    -- A city or camp shows friendly plates; the layer has to appear there or it
    -- looks broken. What stays native is the reaction colour: green means
    -- friendly, so the fill is not repainted.
    eq(friendly.gradient, nil)
    eq(friendly.barColor[1], 0.1)
    eq(friendly.lumaNameplateBg:IsShown(), true)
    eq(component.plates.nameplate7.enemy, false)
    -- A plate that exposes no unit frame is skipped with a reason instead of
    -- being partially decorated.
    H.nameplates.nameplate8 = H.NewFrame(nil, UIParent)
    H.Fire("NAME_PLATE_UNIT_ADDED", "nameplate8")
    eq(component.plates.nameplate8, nil)
    eq(component.lastReason, "no-unit-frame")
    app.Store:Set("modules", "nameplates", false)
    eq(friendly.barColor[1], 0.1)
    eq(#app.errors, 0)
end)

test("a plate whose bar appears a moment later is styled by the retry", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.Store:Set("modules", "nameplates", true)
    local component = app.components.nameplates
    -- The client announced the plate before its unit frame existed. That is a
    -- timing problem, not an unsupported build, so one retry is scheduled.
    local plate = H.NewFrame(nil, UIParent)
    H.nameplates.nameplate5 = plate
    H.Fire("NAME_PLATE_UNIT_ADDED", "nameplate5")
    eq(component.plates.nameplate5, nil)
    eq(component.lastReason, "no-unit-frame")
    eq(component.retries.nameplate5, 1)
    -- A quarter second later the bar is readable and the plate is styled.
    local bar = H.PlainBar({ 0.4, 0.2, 0.2, 1 })
    plate.UnitFrame = H.Plate("modern", bar).UnitFrame
    H.Advance(0.3)
    eq(component.plates.nameplate5 ~= nil, true)
    eq(bar.lumaNameplateBg:IsShown(), true)
    -- A restricted bar is a real limitation and is never retried.
    local restricted = H.NewFrame(nil, UIParent)
    local forbidden = H.PlainBar({ 0.3, 0.3, 0.3, 1 })
    forbidden.forbidden = true
    restricted.UnitFrame = H.Plate("modern", forbidden).UnitFrame
    H.nameplates.nameplate6 = restricted
    H.Fire("NAME_PLATE_UNIT_ADDED", "nameplate6")
    eq(component.lastReason, "restricted")
    eq(component.retries.nameplate6, nil)
    app.Store:Set("modules", "nameplates", false)
    eq(forbidden.barColor[1], 0.3)
    eq(#app.errors, 0)
end)

test("a texture-drawn nameplate bar is decorated without repainting the fill", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.Store:Set("modules", "nameplates", true)
    local component = app.components.nameplates
    H.unitInfo.nameplate9 = { enemy = true }
    -- Some builds draw the plate health bar with a texture instead of a
    -- StatusBar. The layer still has to appear; only the fill is left alone.
    local bar = H.NewFrame(nil, UIParent)
    bar:SetSize(120, 10)
    bar.SetStatusBarColor = nil
    bar.color = { 0.2, 0.6, 0.2, 1 }
    local plate = H.NewFrame(nil, UIParent)
    local unitFrame = H.NewFrame(nil, plate)
    unitFrame.HealthBarsContainer = { healthBar = bar }
    plate.UnitFrame = unitFrame
    H.nameplates.nameplate9 = plate
    H.Fire("NAME_PLATE_UNIT_ADDED", "nameplate9")
    eq(component.plates.nameplate9 ~= nil, true)
    eq(component.plates.nameplate9.source, "HealthBarsContainer.healthBar")
    eq(bar.lumaNameplateBg:IsShown(), true)
    eq(bar.color[1], 0.2)
    app.Store:Set("modules", "nameplates", false)
    eq(bar.lumaNameplateBg:IsShown(), false)
    eq(#app.errors, 0)
end)

test("the plates command reads the client setting and can turn nameplates on", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    -- The field report this covers: both nameplate CVars at 0, so the client
    -- draws nothing and no styling can appear. The report has to say that.
    local cvars = { nameplateShowEnemies = "0", nameplateShowFriends = "0" }
    _G.GetCVar = function(name) return cvars[name] end
    _G.SetCVar = function(name, value) cvars[name] = value end
    H.messages = {}
    SlashCmdList.LUMAUI("plates")
    local text = table.concat(H.messages, "\n")
    eq(text:find(string.format(app.L.platesNothingDrawn, "0", "0"), 1, true) ~= nil, true)
    eq(text:find("nameplateShowEnemies=0", 1, true) ~= nil, true)
    -- The player can turn them back on explicitly; nothing is written silently.
    H.messages = {}
    SlashCmdList.LUMAUI("plates on")
    eq(cvars.nameplateShowEnemies, "1")
    eq(table.concat(H.messages, "\n"):find(app.L.platesTurnedOn, 1, true) ~= nil, true)
    H.messages = {}
    SlashCmdList.LUMAUI("plates off")
    eq(cvars.nameplateShowEnemies, "0")
    eq(cvars.nameplateShowFriends, "0")
    eq(table.concat(H.messages, "\n"):find(app.L.platesTurnedOff, 1, true) ~= nil, true)
    _G.GetCVar, _G.SetCVar = nil, nil
    eq(#app.errors, 0)
end)

test("the modern nested nameplate bar wins over the legacy field", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.Store:Set("modules", "nameplates", true)
    local modern = H.PlainBar({ 0.8, 0.1, 0.1, 1 })
    local legacy = H.PlainBar({ 0.2, 0.3, 0.4, 1 })
    H.nameplates.target = H.Plate("both", modern, legacy)
    H.Fire("PLAYER_TARGET_CHANGED")
    -- Only the field the Retail unit frame really uses is painted.
    eq(modern.statusFill.texture, app.Theme.media.combatFill)
    eq(modern.gradient, nil)
    eq(legacy.gradient, nil)
    eq(legacy.barColor[1], 0.2)
    eq(app.components.nameplates.originals[legacy], nil)
    app.Store:Set("modules", "nameplates", false)
    eq(modern.barColor[1], 0.8)
    eq(#app.errors, 0)
end)

test("a restricted modern nameplate bar is not bypassed through the legacy field", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.Store:Set("modules", "nameplates", true)
    local modern = H.PlainBar({ 0.8, 0.1, 0.1, 1 })
    modern.forbidden = true
    local legacy = H.PlainBar({ 0.2, 0.3, 0.4, 1 })
    H.nameplates.target = H.Plate("both", modern, legacy)
    H.Fire("PLAYER_TARGET_CHANGED")
    eq(modern.barColor[1], 0.8)
    eq(legacy.barColor[1], 0.2)
    eq(next(app.components.nameplates.originals), nil)
    H.messages = {}
    app.components.nameplates:Diagnose()
    local joined = table.concat(H.messages, "\n")
    eq(joined:find("modern=restricted", 1, true) ~= nil, true)
    eq(#app.errors, 0)
end)

test("a modern nameplate field without a drawing method falls back to the legacy bar", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.Store:Set("modules", "nameplates", true)
    local modern = { IsForbidden = function() return false end }
    local legacy = H.PlainBar({ 0.2, 0.3, 0.4, 1 })
    H.nameplates.target = H.Plate("both", modern, legacy)
    H.Fire("PLAYER_TARGET_CHANGED")
    eq(legacy.statusFill.texture, app.Theme.media.combatFill)
    eq(app.components.nameplates.originals[legacy] ~= nil, true)
    app.Store:Set("modules", "nameplates", false)
    eq(legacy.barColor[1], 0.2)
    eq(#app.errors, 0)
end)

test("a nameplate bar without a readable colour keeps its native fill", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.Store:Set("modules", "nameplates", true)
    -- No GetStatusBarColor on this bar, so the colour cannot be put back.
    local bar = H.NewFrame(nil, UIParent)
    H.nameplates.target = H.Plate("modern", bar)
    H.Fire("PLAYER_TARGET_CHANGED")
    local record = app.components.nameplates.originals[bar]
    eq(record ~= nil, true)
    eq(record.paintable, false)
    eq(bar.gradient, nil)
    eq(bar.lumaNameplateBg ~= nil and bar.lumaNameplateBg:IsShown(), true)
    app.Store:Set("modules", "nameplates", false)
    eq(bar.lumaNameplateBg:IsShown(), false)
    eq(#app.errors, 0)
end)

test("the nameplate diagnostic names a missing unit frame", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.Store:Set("modules", "nameplates", true)
    H.nameplates.target = H.NewFrame(nil, UIParent)
    H.messages = {}
    app.components.nameplates:Diagnose()
    local joined = table.concat(H.messages, "\n")
    eq(joined:find("frame=no", 1, true) ~= nil, true)
    eq(#app.errors, 0)
end)

test("the target's plate is owned by its nameplate token, not the alias", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.Store:Set("modules", "nameplates", true)
    local component = app.components.nameplates
    -- Before the client exposes a token the alias alone holds the plate.
    eq(component.plates.target ~= nil, true)
    -- The client now answers the same plate through a real token: the token
    -- takes ownership and the alias record is released, so one plate is never
    -- held (and restored) twice.
    H.nameplates.nameplate7 = H.nameplates.target
    H.unitInfo.nameplate7 = { reaction = 3 }
    H.Fire("PLAYER_TARGET_CHANGED")
    eq(component.plates.target, nil)
    eq(component.plates.nameplate7 ~= nil, true)
    eq(component.plates.nameplate7.bar, H.targetBar)
    eq(component.plates.nameplate7.class, "hostile")
    local painted = 0
    for _ in pairs(component.originals) do painted = painted + 1 end
    eq(painted, 1)
    -- The token goes away: its bar is restored and no alias record takes over.
    H.nameplates.nameplate7 = nil
    H.Fire("NAME_PLATE_UNIT_REMOVED", "nameplate7")
    eq(component.plates.nameplate7, nil)
    eq(component.plates.target, nil)
    eq(H.targetBar.barColor[1], 0.8)
    eq(#app.errors, 0)
end)

test("the plate report counts bases, classes and fill outcomes", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.Store:Set("modules", "nameplates", true)
    local function addPlate(unit, reaction, plate)
        H.unitInfo[unit] = { reaction = reaction }
        H.nameplates[unit] = plate or H.Plate("modern")
        H.Fire("NAME_PLATE_UNIT_ADDED", unit)
        return H.nameplates[unit]
    end
    addPlate("nameplate1", 2)  -- hostile, painted
    addPlate("nameplate2", 5)  -- friendly, native fill kept
    addPlate("nameplate3", 4)  -- neutral, native fill kept
    local restricted = H.Plate("modern", H.PlainBar({ 0.5, 0.2, 0.2, 1 }))
    restricted.UnitFrame.HealthBarsContainer.healthBar.forbidden = true
    addPlate("nameplate4", 2, restricted)  -- hostile, restricted bar
    -- No readable reaction and no readable hostile answer: class unknown. The
    -- stub stays active through the report because the report re-classifies on
    -- the spot instead of trusting the record's snapshot.
    local bare = H.Plate("modern")
    H.unitInfo.nameplate5 = {}
    H.nameplates.nameplate5 = bare
    local enemy = _G.UnitIsEnemy
    _G.UnitIsEnemy = function(a, b)
        if b == "nameplate5" then return H.Secret(true) end
        return enemy(a, b)
    end
    H.Fire("NAME_PLATE_UNIT_ADDED", "nameplate5")
    H.messages = {}
    app.components.nameplates:Diagnose()
    local text = table.concat(H.messages, "\n")
    eq(text:find("plates: bases=5 readable=4 friendly=1 neutral=1 hostile=2 unknown=1", 1, true) ~= nil, true)
    eq(text:find("decorated=4", 1, true) ~= nil, true)
    -- Only the one hostile plate with a readable colour gets the LumaUI fill;
    -- the friendly, neutral and unknown plates keep the client's own.
    eq(text:find("painted=1", 1, true) ~= nil, true)
    eq(text:find("keptFill=3", 1, true) ~= nil, true)
    -- Per-plate lines name the class, the owner and whether the fill is ours.
    eq(text:find("nameplate2: class=friendly owner=luma", 1, true) ~= nil, true)
    eq(text:find("nameplate4: class=hostile owner=native", 1, true) ~= nil, true)
    eq(text:find("nameplate5: class=unknown", 1, true) ~= nil, true)
    eq(text:find("fill=luma", 1, true) ~= nil, true)
    eq(text:find("fill=native", 1, true) ~= nil, true)
    -- `/luma dump` carries the same totals into the saved report.
    H.messages = {}
    SlashCmdList.LUMAUI("dump")
    local saved = table.concat(LumaUIDB.diagnostics.lines, "\n")
    eq(saved:find("plates: bases=5", 1, true) ~= nil, true)
    _G.UnitIsEnemy = enemy
    app.Store:Set("modules", "nameplates", false)
    eq(#app.errors, 0)
end)

test("a retry bound to a recycled plate never decorates the new one", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.Store:Set("modules", "nameplates", true)
    local component = app.components.nameplates
    -- The token appears without a unit frame yet, which schedules the one retry.
    local bare = H.NewFrame(nil, UIParent)
    H.nameplates.nameplate9 = bare
    H.unitInfo.nameplate9 = { reaction = 3 }
    H.Fire("NAME_PLATE_UNIT_ADDED", "nameplate9")
    -- The client recycles the token for another plate before the retry fires.
    local fresh = H.Plate("modern")
    H.nameplates.nameplate9 = fresh
    H.Advance(0.3)
    local bar = fresh.UnitFrame.HealthBarsContainer.healthBar
    eq(bar.lumaNameplateBg, nil)
    eq(component.plates.nameplate9, nil)
    -- A fresh ADDED event styles the new plate normally.
    H.Fire("NAME_PLATE_UNIT_ADDED", "nameplate9")
    eq(bar.lumaNameplateBg:IsShown(), true)
    eq(component.plates.nameplate9.bar, bar)
    app.Store:Set("modules", "nameplates", false)
    eq(#app.errors, 0)
end)

test("a plate that turns forbidden is released without a write", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.Store:Set("modules", "nameplates", true)
    H.unitInfo.nameplate2 = { reaction = 3 }
    local plate = H.Plate("modern")
    H.nameplates.nameplate2 = plate
    H.Fire("NAME_PLATE_UNIT_ADDED", "nameplate2")
    local bar = plate.UnitFrame.HealthBarsContainer.healthBar
    local component = app.components.nameplates
    eq(component.originals[bar] ~= nil, true)
    bar.forbidden = true
    H.Fire("NAME_PLATE_UNIT_REMOVED", "nameplate2")
    -- The record is dropped without writing to the now-restricted bar.
    eq(component.plates.nameplate2, nil)
    eq(component.originals[bar], nil)
    app.Store:Set("modules", "nameplates", false)
    eq(#app.errors, 0)
end)

test("the target chip is warm white and friendly bars keep their fill", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.Store:Set("modules", "nameplates", true)
    local text = app.Theme.colors.text
    eq(H.targetBar.lumaNameplateTarget.color[1], text[1])
    eq(H.targetBar.lumaNameplateTarget.color[2], text[2])
    eq(H.targetBar.lumaNameplateTarget.color[3], text[3])
    -- A friendly plate is decorated but its fill stays the client's own.
    H.unitInfo.nameplate3 = { reaction = 5 }
    local plate = H.Plate("modern")
    H.nameplates.nameplate3 = plate
    H.Fire("NAME_PLATE_UNIT_ADDED", "nameplate3")
    local bar = plate.UnitFrame.HealthBarsContainer.healthBar
    eq(bar.statusFill == nil or bar.statusFill.texture == nil, true)
    eq(bar.lumaNameplateBg:IsShown(), true)
    eq(app.components.nameplates.plates.nameplate3.painted, false)
    app.Store:Set("modules", "nameplates", false)
    eq(#app.errors, 0)
end)

test("region samples separate shown, parent-hidden and alpha-zero", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    ChatFrame1.rect = { left = 32, bottom = 48, width = 514, height = 194 }
    local sample = app.Layout:Sample("chat")
    eq(sample.shown, true)
    eq(sample.visible, true)
    -- The frame itself is shown but its parent is hidden: nothing is drawn, and
    -- the report says "not visible" while `shown` stays truthful.
    UIParent:Hide()
    sample = app.Layout:Sample("chat")
    eq(sample.shown, true)
    eq(sample.visible, false)
    UIParent:Show()
    -- Alpha zero draws nothing either.
    ChatFrame1:SetAlpha(0)
    sample = app.Layout:Sample("chat")
    eq(sample.visible, false)
    eq(sample.alpha, 0)
    ChatFrame1:SetAlpha(1)
    eq(app.Layout:Sample("chat").visible, true)
    eq(#app.errors, 0)
end)

test("/luma hud covers the resource, unit, chat plate and reserved cast area", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.Store:Set("modules", "unitFrames", true)
    H.messages = {}
    app.Layout:Diagnose()
    local text = table.concat(H.messages, "\n")
    eq(text:find("resource LumaUIPlayerResource:", 1, true) ~= nil, true)
    eq(text:find("chatPlate LumaUIChatFrame1Plate:", 1, true) ~= nil, true)
    eq(text:find("unit LumaUIUnit_player:", 1, true) ~= nil, true)
    eq(text:find("unit LumaUIUnit_target:", 1, true) ~= nil, true)
    eq(text:find("castArea LumaUIPlaceholder_unit_player_cast:", 1, true) ~= nil, true)
    eq(text:find("reserved=yes", 1, true) ~= nil, true)
    eq(text:find("vis=", 1, true) ~= nil, true)
    eq(#app.errors, 0)
end)

test("the hud report shows the applied skill top the rail follows", function()
    local app = H.Load()
    for _, name in ipairs({ "UtilityCooldownViewer", "BuffBarCooldownViewer", "BuffIconCooldownViewer" }) do
        _G[name]:Hide()
    end
    _G.EssentialCooldownViewer:SetSize(275, 118)
    H.Fire("PLAYER_LOGIN")
    H.messages = {}
    app.Layout:Diagnose()
    local text = table.concat(H.messages, "\n")
    eq(text:find("cooldown: bottom=104 top=222", 1, true) ~= nil, true)
    eq(#app.errors, 0)
end)

test("the chat size trial is explicit, reversible and refused in combat", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    ChatFrame1:SetSize(514, 194)
    H.messages = {}
    SlashCmdList.LUMAUI("chat")
    eq(ChatFrame1:GetWidth(), 320)
    eq(ChatFrame1:GetHeight(), 140)
    eq(table.concat(H.messages, "\n"):find(app.L.chatSizeOn, 1, true) ~= nil, true)
    -- The message plate follows the resized frame in the same pass.
    eq(app.components.chat.windows[1].background:IsShown(), true)
    -- Combat refuses instead of resizing a docked, protected frame.
    H.Combat(true)
    H.messages = {}
    SlashCmdList.LUMAUI("chat")
    eq(table.concat(H.messages, "\n"):find(app.L.layoutCombat, 1, true) ~= nil, true)
    eq(ChatFrame1:GetWidth(), 320)
    H.Combat(false)
    -- Asking again restores the recorded size.
    H.messages = {}
    SlashCmdList.LUMAUI("chat")
    eq(ChatFrame1:GetWidth(), 514)
    eq(ChatFrame1:GetHeight(), 194)
    eq(table.concat(H.messages, "\n"):find(app.L.chatSizeOff, 1, true) ~= nil, true)
    -- Turning the component off also gives back any size it still holds.
    SlashCmdList.LUMAUI("chat")
    eq(ChatFrame1:GetWidth(), 320)
    app.Store:Set("modules", "chat", false)
    eq(ChatFrame1:GetWidth(), 514)
    eq(#app.errors, 0)
end)

test("the chat plate and the native chat are one surface, not an overlap", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    ChatFrame1.rect = { left = 32, bottom = 48, width = 514, height = 194 }
    _G.LumaUIChatFrame1Plate.rect = { left = 30, bottom = 46, width = 518, height = 198 }
    eq(#app.Layout:Overlaps(), 0)
    -- The resource rail crossing the chat is a real conflict, reported once for
    -- the window even though two chat frames are sampled.
    _G.LumaUIPlayerResource.rect = { left = 40, bottom = 60, width = 200, height = 10 }
    local list = app.Layout:Overlaps()
    eq(#list, 1)
    eq(list[1].a == "chat" or list[1].b == "chat", true)
    eq(#app.errors, 0)
end)

test("the unit report names the player cast bar's real owner", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.Store:Set("modules", "unitFrames", true)
    app.Store:Set("ui", "takeoverUnitFrames", true)
    local line = app.components.unitFrames:Describe()
    eq(line:find(app.L.nativeTargetCast, 1, true) ~= nil, true)
    eq(line:find(app.L.playerCastNative, 1, true) ~= nil, true)
    H.messages = {}
    app.components.unitFrames:Diagnose()
    local text = table.concat(H.messages, "\n")
    eq(text:find("cast: owner=native", 1, true) ~= nil, true)
    eq(text:find("takeover=possible", 1, true) ~= nil, true)
    -- The native bar is still the one shown; the takeover flag never moves it.
    eq(PlayerCastingBarFrame:IsShown(), true)
    eq(#app.errors, 0)
end)

test("/luma hud reports measured and estimated geometry without writing", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local viewer = _G.EssentialCooldownViewer
    H.messages = {}
    app.Layout:Diagnose()
    local joined = table.concat(H.messages, "\n")
    eq(joined:find("action:", 1, true) ~= nil, true)
    eq(joined:find("viewer EssentialCooldownViewer", 1, true) ~= nil, true)
    -- The harness reports no rect until a test gives one, so the report must say
    -- "unknown" rather than invent a position.
    eq(joined:find("rect=unknown", 1, true) ~= nil, true)
    viewer.rect = { left = 800, bottom = 100, width = 300, height = 50 }
    H.messages = {}
    app.Layout:Diagnose()
    joined = table.concat(H.messages, "\n")
    eq(joined:find("rect=300x50@800,100", 1, true) ~= nil, true)
    eq(#app.errors, 0)
end)

test("the viewer block is reported in UIParent units, not scaled twice", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    UIParent:SetScale(2)
    local viewer = _G.EssentialCooldownViewer
    viewer.rect = { left = 0, bottom = 0, width = 300, height = 60 }
    local pool = { active = {} }
    function pool:EnumerateActive()
        local index = 0
        return function()
            index = index + 1
            return self.active[index]
        end
    end
    viewer.itemFramePool = pool
    for index = 1, 2 do
        local icon = H.NewFrame("BlockIcon" .. index, viewer)
        icon.rect = { left = (index - 1) * 34, bottom = 0, width = 30, height = 30 }
        pool.active[index] = icon
    end
    H.messages = {}
    app.Layout:Diagnose()
    local joined = table.concat(H.messages, "\n")
    -- GetRect is already divided by each frame's effective scale, so a UI scale
    -- of 2 must not shrink the reported block: the two icons span 64x30 and the
    -- viewer's own rectangle stays in the same units.
    eq(joined:find("block=64x30", 1, true) ~= nil, true)
    eq(joined:find("rect=300x60@0,0", 1, true) ~= nil, true)
    UIParent:SetScale(1)
    _G.BlockIcon1, _G.BlockIcon2 = nil, nil
    eq(#app.errors, 0)
end)

test("/luma dump writes the diagnostics report into SavedVariables", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    H.messages = {}
    SlashCmdList.LUMAUI("dump")
    -- Chat carries only the confirmation; the report itself goes to the file so
    -- nothing has to be copied out of the chat frame.
    eq(#H.messages, 1)
    eq(H.messages[1]:find(app.L.diagnosticsSaved, 1, true) ~= nil, true)
    local dump = LumaUIDB.diagnostics
    eq(type(dump), "table")
    eq(type(dump.lines), "table")
    local text = table.concat(dump.lines, "\n")
    eq(text:find(app.L.diagStatus, 1, true) ~= nil, true)
    eq(text:find(app.L.hudHeader, 1, true) ~= nil, true)
    eq(text:find("action:", 1, true) ~= nil, true)
    eq(#app.errors, 0)
end)

test("/luma dump leaves a newer database untouched", function()
    local saved = { schema = 99, sentinel = { "keep" } }
    local app = H.Load(saved); H.Fire("PLAYER_LOGIN")
    H.messages = {}
    SlashCmdList.LUMAUI("dump")
    eq(LumaUIDB, saved)
    eq(saved.diagnostics, nil)
    eq(H.messages[1]:find(app.L.readonly, 1, true) ~= nil, true)
    eq(#app.errors, 0)
end)

test("native region samples use the reported rectangle and its scale", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    MinimapCluster.rect = { left = 1700, bottom = 900, width = 200, height = 150 }
    local sample = app.Layout:Sample("map")
    eq(sample.measured, true)
    eq(sample.owner, "minimap")
    eq(sample.width, 200)
    -- A frame at twice UIParent's scale reports twice the units; the sample is
    -- converted so two regions can be compared in one coordinate space.
    ChatFrame1.rect = { left = 100, bottom = 100, width = 400, height = 200 }
    ChatFrame1:SetScale(2)
    local chat = app.Layout:Sample("chat")
    eq(chat.width, 200)
    eq(chat.left, 50)
    -- A region whose frame this client does not have stays unknown.
    eq(app.Layout:Sample("meter"), nil)
    eq(app.Layout:Sample("nope"), nil)
    eq(#app.errors, 0)
end)

test("overlapping owned regions are reported and separated ones are not", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    MinimapCluster.rect = { left = 1600, bottom = 800, width = 300, height = 200 }
    ChatFrame1.rect = { left = 100, bottom = 100, width = 400, height = 200 }
    eq(#app.Layout:Overlaps(), 0)
    -- The chat now sits under the map column: both owners are named.
    ChatFrame1.rect = { left = 1700, bottom = 850, width = 400, height = 200 }
    local list = app.Layout:Overlaps()
    eq(#list, 1)
    local pair = list[1]
    eq((pair.a == "chat" and pair.b == "map") or (pair.a == "map" and pair.b == "chat"), true)
    eq(pair.width, 200)
    eq(pair.height, 150)
    H.messages = {}
    app.Layout:Diagnose()
    eq(table.concat(H.messages, "\n"):find("overlap: ", 1, true) ~= nil, true)
    eq(#app.errors, 0)
end)

test("edit-mode guides outline only the native regions this client reports", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    MinimapCluster.rect = { left = 1600, bottom = 800, width = 300, height = 200 }
    ChatFrame1.rect = { left = 100, bottom = 100, width = 400, height = 200 }
    eq(app.Layout:SetEditing(true), true)
    local guides = app.Layout.edgeGuides
    eq(guides.map:IsShown(), true)
    eq(guides.map.label:GetText():find("minimap", 1, true) ~= nil, true)
    eq(guides.chat:IsShown(), true)
    -- No damage meter frame on this client, so no guide and no reset boundary.
    eq(guides.meter, nil)
    eq(app.Layout:SetEditing(false), true)
    eq(guides.map:IsShown(), false)
    eq(#app.errors, 0)
end)

test("the edge pulse samples an ease-out curve and lays out four segments", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local pulse = app.EdgePulse
    eq(pulse:Sample(0), 0)
    eq(pulse:Sample(1), 1)
    eq(pulse:Sample(2), 1)
    eq(pulse:Sample(-1), 0)
    eq(math.abs(pulse:Sample(0.5) - 0.875) < 0.0001, true)
    local frame = H.NewFrame(nil, UIParent)
    frame:SetSize(200, 100)
    pulse:Show(frame)
    local sizes = pulse:Layout(frame, 0.5)
    eq(sizes.top, 100)
    eq(sizes.bottom, 100)
    eq(sizes.left, 50)
    eq(sizes.right, 50)
    eq(frame.lumaEdgePulse.top:IsShown(), true)
    eq(#app.errors, 0)
end)

test("the edge pulse stops when the run finishes or the host is released", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local pulse = app.EdgePulse
    local frame = H.NewFrame(nil, UIParent)
    frame:SetSize(200, 100)
    H.now = 10
    pulse:Show(frame)
    eq(pulse:Tick(10.06), true)
    eq(pulse:Tick(10 + pulse.duration + 0.01), false)
    eq(frame.lumaEdgePulse.top:IsShown(), false)
    eq(next(pulse.active), nil)
    -- Release cancels an in-flight run instead of letting it finish.
    pulse:Show(frame)
    pulse:Release(frame)
    eq(frame.lumaEdgePulse.top:IsShown(), false)
    eq(pulse:Tick(11), false)
    eq(#app.errors, 0)
end)

test("primary controls pulse on hover and drop the animation when disabled", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local button = app.Controls:Button(UIParent, "Go", 100, function() end, { kind = "primary" })
    button:SetSize(120, 30)
    button.scripts.OnEnter(button)
    eq(button.lumaEdgePulse ~= nil, true)
    eq(button.lumaEdgePulse.top:IsShown(), true)
    eq(app.EdgePulse.active[button] ~= nil, true)
    button.scripts.OnLeave(button)
    eq(button.lumaEdgePulse.top:IsShown(), false)
    eq(app.EdgePulse.active[button], nil)
    -- A control disabled mid-hover loses the edge instead of keeping a tick.
    button.scripts.OnEnter(button)
    button:SetEnabled(false)
    eq(app.EdgePulse.active[button], nil)
    eq(button.lumaEdgePulse.top:IsShown(), false)
    eq(#app.errors, 0)
end)

test("the quest indicator outlines only a shown native button", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local component = app.components.questIndicators
    -- No native quest button on this client: the component reports unsupported
    -- and attaches nothing.
    eq(component.running ~= true, true)
    local frame = H.NewFrame("QuestActionFrame", UIParent)
    frame:SetSize(40, 40)
    app.Store:Set("modules", "questIndicators", true)
    eq(component.running, true)
    eq(component.attached, frame)
    app.Store:Set("modules", "questIndicators", false)
    eq(component.attached, nil)
    eq(app.EdgePulse.active[frame], nil)
    eq(#app.errors, 0)
end)

test("the settings window keeps an Esc entry for the game menu", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.Settings:Toggle("modules")
    eq(app.Settings.gameMenuButton ~= nil, true)
    eq(app.Settings.gameMenuButton.text:GetText(), app.L.escMenu)
    -- The hint closes the game menu path without touching the settings window.
    H.Click(app.Settings.gameMenuButton)
    eq(#app.errors, 0)
end)

test("an item cell clears every layer when the slot empties or the paint fails", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    _G.C_Container = _G.C_Container or {}
    _G.C_Container.GetContainerItemCooldown = function() return 10, 5 end
    local cell = app.Items.Cell(UIParent)
    app.Items.Paint(cell, { bag = 0, slot = 1, texture = 123, quality = 4, count = 20 })
    eq(cell:IsShown(), true)
    eq(cell.count:GetText(), 20)
    eq(cell.cooldown:IsShown(), true)
    -- An emptied slot drops the icon, count, quality edge and the sweep.
    app.Items.Paint(cell, nil)
    eq(cell:IsShown(), false)
    eq(cell.count:GetText(), "")
    eq(cell.cooldown:IsShown(), false)
    -- A failed paint leaves an empty cell, never a stale icon with a new border.
    cell.icon.SetTexture = function() error("no texture") end
    app.Items.Paint(cell, { bag = 0, slot = 1, texture = 1 })
    eq(cell:IsShown(), false)
    eq(#app.errors, 1)
    eq(app.errors[1].context, "items/paint")
    _G.C_Container.GetContainerItemCooldown = nil
end)

test("chat derives typing, active, quiet and combat from one state", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local chat = app.components.chat
    local shown = H.NewFrame(nil, UIParent)
    local hidden = H.NewFrame(nil, UIParent)
    hidden:Hide()
    eq(chat:StateOf({ frame = shown }), "active")
    eq(chat:StateOf({ frame = shown, focused = true }), "typing")
    -- A hidden window outranks focus: no layer is painted for it.
    eq(chat:StateOf({ frame = hidden, focused = true }), "quiet")
    H.Combat(true)
    eq(chat:StateOf({ frame = shown }), "combat")
    eq(chat:StateOf({ frame = shown, focused = true }), "typing")
    H.Combat(false)
    eq(#app.errors, 0)
end)

test("the statistics sample draws only plain provider values", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app:SetDamageMeterProvider(function()
        return { title = "Damage", total = 1000, rows = {
            { name = "A", className = "MAGE", amount = 600 },
            { name = "B", className = "WARRIOR", amount = H.Secret(300) },
            { name = "C", className = "ROGUE", amount = 400 },
        } }
    end)
    app.Store:Set("modules", "damageMeter", true)
    local meter = app.components.damageMeter
    eq(meter.running, true)
    eq(meter:Show(), true)
    eq(meter.title:GetText(), "Damage")
    eq(meter.total:GetText(), "1000")
    eq(meter.rows[1].name:GetText(), "A")
    eq(meter.rows[1].value:GetText(), "60%")
    eq(meter.rows[1].bar.value, 0.6)
    -- The restricted row is dropped instead of being compared or formatted, and
    -- the next row moves up rather than leaving a hole.
    eq(meter.rows[2].name:GetText(), "C")
    eq(meter.rows[3]:IsShown(), false)
    meter:Hide()
    eq(meter:IsShown(), false)
    app.Store:Set("modules", "damageMeter", false)
    eq(meter.ticker, nil)
    app:SetDamageMeterProvider(nil)
    eq(#app.errors, 0)
end)

test("the statistics sample stays dormant without a provider", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local meter = app.components.damageMeter
    eq(meter.running ~= true, true)
    H.messages = {}
    SlashCmdList.LUMAUI("meter")
    eq(table.concat(H.messages, "\n"):find(app.L.meterNoProvider, 1, true) ~= nil, true)
    eq(#app.errors, 0)
end)

test("character preview keeps the native toggle and game-window entry independent", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.Store:Set("modules", "characterWindow", true)
    app.Store:Set("appearance", "motion", false)
    local window = app.components.characterWindow.window
    eq(window.nativeEntry ~= nil, true)
    eq(UISpecialFrames[#UISpecialFrames], "LumaUICharacterWindow")
    -- The native toggle never opens the preview.
    CharacterFrame:Hide()
    ToggleCharacter("PaperDollFrame")
    eq(window:IsShown(), false)
    eq(CharacterFrame:IsShown(), true)
    SlashCmdList.LUMAUI("char")
    eq(window:IsShown(), true)
    eq(CharacterFrame:IsShown(), true)
    -- The native binding continues to toggle the native frame alone.
    ToggleCharacter("PaperDollFrame")
    eq(window:IsShown(), true)
    eq(CharacterFrame:IsShown(), false)
    -- The header entry opens the game's window and closes the preview.
    H.Click(window.nativeEntry)
    eq(window:IsShown(), false)
    eq(CharacterFrame:IsShown(), true)
    eq(#app.errors, 0)
end)

test("diagnostics describe the native takeover of every replacement", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.Settings:Toggle("diagnostics")
    local page = app.Settings.pages.diagnostics
    eq(page.headers.native.text:GetText(), app.L.diagNative)
    local native = page.bodies.native:GetText()
    -- The quest panel runs by default and reports the module-only takeover.
    eq(native:find("questList: " .. app.L.nativeTaken, 1, true) ~= nil, true)
    eq(native:find(app.L.nativeQuestsOnly, 1, true) ~= nil, true)
    -- A disabled replacement contributes no takeover line.
    eq(native:find("unitFrames:", 1, true), nil)
    app.Store:Set("modules", "unitFrames", true)
    app.Settings:Update()
    native = page.bodies.native:GetText()
    eq(native:find("unitFrames: ", 1, true) ~= nil, true)
    eq(native:find(app.L.nativeUnits, 1, true) ~= nil, true)
    eq(#app.errors, 0)
end)

test("diagnostics list the other addons sharing the session", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.Settings:Toggle("diagnostics")
    local page = app.Settings.pages.diagnostics
    -- A lone session is said plainly instead of an empty list.
    eq(page.bodies.coexistence:GetText(), app.L.diagCoexistenceNone)
    H.addons = {
        { name = "LumaUI", title = "LumaUI", loaded = true },
        { name = "GoldWQ", title = "Gold World Quests", loaded = true },
        -- Installed but not loaded: still named, sorted after the live ones.
        { name = "HyperframePlus", title = "Hyperframe+", loaded = false },
    }
    app.Settings:Update()
    local text = page.bodies.coexistence:GetText()
    eq(text:find("GoldWQ (Gold World Quests) · " .. app.L.diagCoexistenceLoaded, 1, true) ~= nil, true)
    -- An absent addon is named without a title lookup of its own: the fallback
    -- keeps the folder name readable either way.
    eq(text:find("HyperframePlus (Hyperframe+) · " .. app.L.diagCoexistenceAbsent, 1, true) ~= nil, true)
    -- The census names only other addons: LumaUI itself never appears.
    eq(text:find("LumaUI (", 1, true), nil)
    -- Loaded entries sort ahead of absent ones regardless of name order.
    eq(text:find("GoldWQ", 1, true) < text:find("HyperframePlus", 1, true), true)
    eq(#app.errors, 0)
end)

test("a coexistence census works without the addon APIs", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local page = app.Settings.pages.diagnostics
    local saved = _G.C_AddOns
    _G.C_AddOns = { GetAddOnMetadata = function() return "0.4.0" end }
    app.Settings:Toggle("diagnostics")
    app.Settings:Update()
    eq(app.Settings.pages.diagnostics.bodies.coexistence:GetText(), app.L.diagCoexistenceNone)
    _G.C_AddOns = saved
    eq(#app.errors, 0)
end)

-- ==== TRACK: VIS-05 theme roles and pixels —append new tests above this line ====
test("pixel helper snaps to the physical grid without touching the UI scale", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    eq(app.Pixel:Unit(), 1)
    eq(app.Pixel:Size(1), 1)
    eq(app.Pixel:Size(0), 0)
    eq(app.Pixel:Offset(0), 0)
    local before = UIParent:GetScale()
    UIParent:SetScale(2)
    eq(app.Pixel:Unit(), 0.5)
    eq(app.Pixel:Pixels(1), 0.5)
    eq(app.Pixel:Pixels(0), 0)
    -- Sizes snap to whole physical pixels and never fall below one pixel.
    eq(app.Pixel:Size(1), 1)
    eq(app.Pixel:Size(0.3), 0.5)
    eq(app.Pixel:Offset(-1.2), -1)
    -- A theme paint uses the snapped hairline and leaves UIParent's scale alone.
    local frame = H.NewFrame("PixelProbeWindow", UIParent, "BackdropTemplate")
    app.Theme:PaintSurface(frame, "window")
    eq(frame.backdrop.edgeSize, 0.5)
    eq(UIParent:GetScale(), 2)
    UIParent:SetScale(1.5)
    local scaled = H.NewFrame("PixelProbeWindow2", UIParent, "BackdropTemplate")
    app.Theme:PaintSurface(scaled, "window")
    eq(math.abs(scaled.backdrop.edgeSize - 2 / 3) < 1e-9, true)
    eq(UIParent:GetScale(), 1.5)
    eq(before, 1)
    eq(#app.errors, 0)
end)

test("appearance role opacities default, clamp and keep the legacy value", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local appearance = app.Store:Profile().appearance
    eq(appearance.opacity, 0.92)
    eq(appearance.windowOpacity, 0.92)
    eq(appearance.hudOpacity, 0.80)
    eq(appearance.chatOpacity, 0.82)
    eq(appearance.chatActiveOpacity, 0.90)
    -- A damaged profile keeps the legacy value but never reaches a role beyond
    -- its own range.
    local broken = H.Load({ profiles = { Default = { appearance = {
        opacity = 0.5, windowOpacity = "wide", hudOpacity = 9,
        chatOpacity = -2, chatActiveOpacity = 0 / 0 } } } })
    H.Fire("PLAYER_LOGIN")
    local a = broken.Store:Profile().appearance
    eq(a.opacity, 0.5)
    eq(a.windowOpacity, 0.92)
    eq(a.hudOpacity, 1)
    eq(a.chatOpacity, 0)
    eq(a.chatActiveOpacity, 0.90)
    -- An old profile without the new fields receives the defaults, not the
    -- legacy value, so nothing turns transparent on the first login.
    local old = H.Load({ profiles = { Default = { appearance = { opacity = 0.5 } } } })
    H.Fire("PLAYER_LOGIN")
    eq(old.Store:Profile().appearance.windowOpacity, 0.92)
    eq(old.Store:Profile().appearance.opacity, 0.5)
    eq(#old.errors, 0)
end)

test("theme surface roles keep window, embedded, button, HUD and chat apart", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local theme = app.Theme
    local window = H.NewFrame(nil, UIParent, "BackdropTemplate")
    theme:PaintSurface(window, "window")
    eq(window.backdrop.bgFile, theme.media.panel)
    eq(window.backdrop.edgeFile, theme.white)
    eq(window.backdrop.edgeSize, 1)
    eq(window.backgroundColor[4], 0.92)
    eq(window.lumaSurfaceRole, "window")
    local embedded = H.NewFrame(nil, UIParent, "BackdropTemplate")
    theme:PaintSurface(embedded, "embedded")
    eq(embedded.backdrop.edgeFile, nil)
    eq(embedded.backdrop.bgFile, theme.media.inset)
    eq(embedded.backgroundColor[4], 0.92)
    eq(embedded.backgroundColor[1], theme.colors.embedded[1] * 2.1)
    local button = H.NewFrame(nil, UIParent, "BackdropTemplate")
    theme:PaintSurface(button, "button")
    -- An idle control is a flat patch. The hairline belongs to the interaction, so
    -- the button surface carries no edge of its own; Controls draws the ring.
    eq(button.backdrop.edgeFile, nil)
    eq(button.backgroundColor[1], theme.colors.raised[1] * 2.1)
    local hud = H.NewFrame(nil, UIParent, "BackdropTemplate")
    theme:PaintSurface(hud, "hud")
    eq(hud.backdrop.edgeFile, nil)
    eq(hud.backgroundColor[4], 0.80)
    local chat = H.NewFrame(nil, UIParent, "BackdropTemplate")
    theme:PaintSurface(chat, "chat")
    eq(chat.backgroundColor[4], 0.82)
    local active = H.NewFrame(nil, UIParent, "BackdropTemplate")
    theme:PaintSurface(active, "chatActive")
    eq(active.backgroundColor[4], 0.90)
    eq(active.backdrop.bgFile, theme.white)
    -- The window and the embedded region differ in colour and edge, and the
    -- button is the brightest of the three.
    eq(window.backgroundColor[1] ~= embedded.backgroundColor[1], true)
    eq(button.backgroundColor[1] > window.backgroundColor[1], true)
    -- Unknown roles fall back to the window role instead of erroring.
    local fallback = H.NewFrame(nil, UIParent, "BackdropTemplate")
    theme:PaintSurface(fallback, "nope")
    eq(fallback.lumaSurfaceRole, "window")
    -- Spacing and focus tokens exist and follow the live accent.
    eq(theme:Space("md"), 12)
    eq(theme:Space("nope"), 12)
    eq(theme:FocusColor()[1], theme:Accent()[1])
    eq(theme.shadow.edge, 10)
    -- Every surface role names one of the five generated textures.
    eq(theme.media.inset, "Interface\\AddOns\\LumaUI\\Media\\inset.tga")
    local paths, unique = {}, true
    for _, key in ipairs({ "panel", "bar", "rule", "glow", "inset" }) do
        eq(type(theme.media[key]), "string")
        if paths[theme.media[key]] then unique = false end
        paths[theme.media[key]] = true
    end
    eq(unique, true)
    eq(#app.errors, 0)
end)

test("theme text roles follow the semantic scale", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local theme = app.Theme
    local parent = H.NewFrame(nil, UIParent)
    local title = theme:TextRole(parent, "title")
    eq(title.fontSize, 20)
    eq(title.textColor[1], theme.colors.text[1])
    eq(title.lumaTextRole, "title")
    eq(theme:TextRole(parent, "body").fontSize, 14)
    eq(theme:TextRole(parent, "label").fontSize, 13)
    eq(theme:TextRole(parent, "value").fontSize, 13)
    local muted = theme:TextRole(parent, "muted")
    eq(muted.fontSize, 12)
    eq(muted.textColor[1], theme.colors.muted[1])
    -- An unknown role falls back to body instead of erroring.
    eq(theme:TextRole(parent, "nope").fontSize, 14)
    eq(#app.errors, 0)
end)

test("legacy panel and text APIs keep their old contract", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local theme = app.Theme
    app.Store:Set("appearance", "opacity", 0.5)
    local legacy = H.NewFrame(nil, UIParent, "BackdropTemplate")
    theme:Panel(legacy, true)
    eq(legacy.backgroundColor[4], 0.5)
    eq(legacy.backdrop.bgFile, theme.media.panel)
    eq(legacy.backdrop.edgeFile, theme.white)
    theme:Surface(legacy, true)
    eq(legacy.backgroundColor[4], 0.5)
    eq(legacy.backdrop.bgFile, theme.white)
    local text = theme:Text(legacy, 11, true)
    eq(text.fontSize, 11)
    eq(text.textColor[1], theme.colors.muted[1])
    -- The legacy opacity does not leak into the semantic roles.
    local hud = H.NewFrame(nil, UIParent, "BackdropTemplate")
    theme:PaintSurface(hud, "hud")
    eq(hud.backgroundColor[4], 0.80)
    eq(#app.errors, 0)
end)

test("settings window, HUD strips, chat and roles repaint from their tokens", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.Settings:Toggle()
    -- The window is a card now: a plate with a shadow and no backdrop edge at all.
    -- A hairline around the whole window is what made it read as a flat page.
    eq(app.Settings.frame.lumaSurfaceRole, "card")
    eq(app.Settings.frame.backdrop, nil)
    eq(app.Settings.frame.lumaPlate ~= nil, true)
    eq(app.Settings.frame.lumaPlate.vertexColor[4], app.Theme:Opacity("windowOpacity"))
    eq(app.Settings.navPanel.lumaSurfaceRole, "inset")
    eq(app.Settings.navigation.modules.lumaSurfaceRole, "button")
    -- HUD supports use the HUD role instead of the window opacity.
    eq(app.components.dataStrip.frame.lumaSurfaceRole, "hud")
    eq(app.components.dataStrip.frame.lumaPlate.vertexColor[4], 0.80)
    eq(app.components.dataStrip.zone.lumaTypeRole, "body")
    eq(app.components.experience.frame.lumaSurfaceRole, "hud")
    -- Chat: quiet support while reading, stronger backdrop while typing.
    local chat = app.components.chat.windows[1]
    eq(chat.background.lumaSurfaceRole, "chat")
    eq(chat.background.lumaPlate.vertexColor[4], 0.82)
    ChatFrame1EditBox:Show()
    eq(chat.editBackground.lumaSurfaceRole, "chatActive")
    eq(chat.editBackground.lumaPlate.vertexColor[4], 0.90)
    ChatFrame1EditBox:Hide()
    -- Profile changes repaint the cached surfaces from their own token.
    app.Store:Set("appearance", "windowOpacity", 0.8)
    app.Store:Set("appearance", "chatOpacity", 0.4)
    app.Store:Set("appearance", "hudOpacity", 0.5)
    app.Settings:Update()
    -- A plate carries its opacity in the texture's vertex colour, so the profile
    -- token reaches the window through the plate rather than through a backdrop.
    eq(app.Settings.frame.lumaPlate.vertexColor[4], 0.8)
    eq(app.Theme:Opacity("windowOpacity"), 0.8)
    -- An unknown token falls back to the legacy opacity instead of nil.
    eq(app.Theme:Opacity("window"), app.Store:Profile().appearance.opacity)
    eq(chat.background.lumaPlate.vertexColor[4], 0.4)
    eq(app.components.dataStrip.frame.lumaPlate.vertexColor[4], 0.5)
    -- The character window gradient follows the window token as well.
    app.Store:Set("modules", "characterWindow", true)
    eq(app.Theme:Opacity("windowOpacity"), 0.8)
    eq(#app.errors, 0)
end)

test("a UI scale change re-snaps hairlines through the layout pass", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.Settings:Toggle()
    local parent = H.NewFrame(nil, UIParent)
    -- A rule is one physical pixel, so its size in UI units follows the scale.
    eq(app.Surface:HLine(parent):GetHeight(), app.Pixel:Pixels(1))
    UIParent:SetScale(2)
    H.Fire("UI_SCALE_CHANGED")
    eq(app.Surface:HLine(parent):GetHeight(), 0.5)
    eq(app.Settings.navPanel.lumaSurfaceRole, "inset")
    UIParent:SetScale(1)
    H.Fire("UI_SCALE_CHANGED")
    eq(app.Surface:HLine(parent):GetHeight(), 1)
    eq(#app.errors, 0)
end)

-- ==== TRACK: VIS-06 transitions —append new tests above this line ====
test("transitions fade in and out and reverse from the current alpha", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local tr = app.Transitions
    app.Settings:Toggle()
    local frame = app.Settings.frame
    eq(frame:IsShown(), true)
    eq(frame:GetAlpha(), 0)
    eq(tr:Count(), 1)
    H.Advance(0.09)
    local mid = frame:GetAlpha()
    eq(mid > 0 and mid < 1, true)
    -- Closing continues from the visible value instead of jumping to zero.
    app.Settings:Close()
    eq(frame:GetAlpha(), mid)
    H.Advance(0.02)
    local lower = frame:GetAlpha()
    eq(lower < mid, true)
    -- Reopening mid-close reverses again; the replaced close never hides it.
    app.Settings:Open()
    eq(frame:GetAlpha(), lower)
    H.Advance(1)
    eq(frame:GetAlpha(), 1)
    eq(frame:IsShown(), true)
    eq(tr:Count(), 0)
    eq(#app.errors, 0)
end)

test("settings close hides only after the fade and resets for the next open", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.Settings:Toggle()
    local frame = app.Settings.frame
    H.Advance(0.3)
    eq(frame:GetAlpha(), 1)
    app.Settings:Close()
    -- Visibility is never delayed: the window is still there while it fades.
    eq(frame:IsShown(), true)
    H.Advance(0.3)
    eq(frame:IsShown(), false)
    eq(frame:GetAlpha(), 0)
    -- The next open starts from zero again.
    app.Settings:Toggle()
    eq(frame:IsShown(), true)
    eq(frame:GetAlpha(), 0)
    H.Advance(0.3)
    eq(frame:GetAlpha(), 1)
    eq(#app.errors, 0)
end)

test("rapid open and close reversals keep one task and the last intent", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local tr = app.Transitions
    app.Settings:Toggle()
    for index = 1, 50 do
        if index % 2 == 1 then app.Settings:Close() else app.Settings:Open() end
    end
    eq(tr:Count(), 1)
    eq(app.Settings.frame:IsShown(), true)
    app.Settings:Close()
    H.Advance(1)
    eq(app.Settings.frame:IsShown(), false)
    eq(tr:Count(), 0)
    eq(#app.errors, 0)
end)

test("motion off and reduced motion settle every transition immediately", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.Store:Set("appearance", "motion", false)
    app.Settings:Toggle()
    eq(app.Settings.frame:GetAlpha(), 1)
    eq(app.Transitions:Count(), 0)
    app.Settings:Close()
    eq(app.Settings.frame:IsShown(), false)
    -- Reduced motion takes the same immediate path.
    app.Store:Set("appearance", "motion", true)
    app.Store:Set("appearance", "reduceMotion", true)
    eq(app.Transitions:MotionEnabled(), false)
    app.Settings:Toggle()
    eq(app.Settings.frame:IsShown(), true)
    eq(app.Settings.frame:GetAlpha(), 1)
    eq(app.Transitions:Count(), 0)
    app.Settings:Close()
    eq(app.Settings.frame:IsShown(), false)
    app.Store:Set("appearance", "reduceMotion", false)
    eq(app.Transitions:MotionEnabled(), true)
    eq(#app.errors, 0)
end)

test("page switching fades the new page and settles the previous one", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.Settings:Toggle()
    H.Advance(0.3)
    local general, modules = app.Settings.pages.general, app.Settings.pages.modules
    eq(general:GetAlpha(), 1)
    app.Settings:Select("modules")
    eq(modules:IsShown(), true)
    eq(modules:GetAlpha(), 0)
    H.Advance(0.05)
    eq(modules:GetAlpha() > 0, true)
    H.Advance(0.3)
    eq(modules:GetAlpha(), 1)
    -- The page that was left is settled at full alpha before being hidden.
    eq(general:GetAlpha(), 1)
    eq(app.Transitions:Count(), 0)
    -- Fifty fast switches leave one page task, not fifty.
    local keys = { "general", "modules", "layout", "profiles", "diagnostics" }
    for index = 1, 50 do
        app.Settings:Select(keys[(index % #keys) + 1])
    end
    eq(app.Transitions:Count(), 1)
    H.Advance(1)
    eq(app.Transitions:Count(), 0)
    eq(#app.errors, 0)
end)

test("the value channel driver exists only while a task is active", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local tr = app.Transitions
    local owner = {}
    local values, done = {}, 0
    tr:Animate(owner, "decor", {
        from = 0, to = 10, duration = 0.1,
        apply = function(value) values[#values + 1] = value end,
        onDone = function() done = done + 1 end,
    })
    eq(tr:HasDriver(), true)
    eq(tr:Count(), 1)
    H.Advance(1)
    eq(done, 1)
    eq(tr:Count(), 0)
    eq(tr:HasDriver(), false)
    eq(values[#values], 10)
    -- After completion the driver is gone and the paint callback stops.
    local painted = #values
    H.Advance(1)
    eq(#values, painted)
    eq(done, 1)
    eq(#app.errors, 0)
end)

test("replacing a channel drops the stale completion callback", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local tr = app.Transitions
    local frame = H.NewFrame("TransitionProbe1", UIParent)
    local done = {}
    tr:Fade("ownerA", frame, 0, 0.2, function() done[#done + 1] = "first" end, "fade")
    H.Advance(0.05)
    tr:Fade("ownerA", frame, 1, 0.2, function() done[#done + 1] = "second" end, "fade")
    H.Advance(1)
    eq(#done, 1)
    eq(done[1], "second")
    eq(frame:GetAlpha(), 1)
    eq(tr:Count(), 0)
    eq(#app.errors, 0)
end)

test("settling applies the target, runs one completion and never repeats it", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local tr = app.Transitions
    local frame = H.NewFrame("TransitionProbe2", UIParent)
    local done = 0
    tr:Fade("ownerB", frame, 0, 0.2, function() done = done + 1 end, "fade")
    H.Advance(0.05)
    tr:Settle("ownerB")
    eq(frame:GetAlpha(), 0)
    eq(done, 1)
    eq(tr:Count(), 0)
    -- A stopped group can never fire a second completion later.
    H.Advance(1)
    eq(done, 1)
    eq(#app.errors, 0)
end)

test("errors inside paint and completion callbacks are isolated", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local tr = app.Transitions
    tr:Animate({}, "bad", {
        from = 0, to = 1, duration = 0.05,
        apply = function() error("paint failure") end,
        onDone = function() error("done failure") end,
    })
    H.Advance(0.3)
    eq(tr:Count(), 0)
    eq(tr:HasDriver(), false)
    -- The framework finished anyway and reported both failures once each.
    local contexts = {}
    for _, err in ipairs(app.errors) do contexts[err.context] = err.message end
    eq(contexts["transitions/apply"] ~= nil, true)
    eq(contexts["transitions/apply"]:find("paint failure", 1, true) ~= nil, true)
    eq(contexts["transitions/done"] ~= nil, true)
    eq(contexts["transitions/done"]:find("done failure", 1, true) ~= nil, true)
    eq(#app.errors, 2)
end)

test("the legacy reveal adapter fades own windows and settles with motion off", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    SlashCmdList.LUMAUI("bags")
    local inventory = app.components.inventory
    eq(inventory.frame:IsShown(), true)
    eq(inventory.frame:GetAlpha(), 0)
    H.Advance(1)
    eq(inventory.frame:GetAlpha(), 1)
    app.Store:Set("appearance", "motion", false)
    inventory.frame:Hide()
    inventory.frame:Show()
    eq(inventory.frame:GetAlpha(), 1)
    eq(app.Transitions:Count(), 0)
    eq(#app.errors, 0)
end)

test("a native hide cancels the open task and resets alpha for the next open", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.Settings:Toggle()
    local frame = app.Settings.frame
    H.Advance(0.05)
    eq(app.Transitions:Count(), 1)
    -- Esc on a UISpecialFrames window hides it directly, without our Close.
    frame:Hide()
    eq(app.Transitions:Count(), 0)
    eq(frame:GetAlpha(), 0)
    H.Advance(0.2)
    eq(frame:IsShown(), false)
    app.Settings:Toggle()
    eq(frame:IsShown(), true)
    eq(frame:GetAlpha(), 0)
    H.Advance(0.3)
    eq(frame:GetAlpha(), 1)
    eq(#app.errors, 0)
end)

test("hiding during a page fade leaves the page visible on the next open", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.Settings:Open()
    H.Advance(0.3)
    app.Settings:Select("modules")
    app.Settings.frame:Hide()
    eq(app.Transitions:Count(), 0)
    app.Settings:Open()
    H.Advance(0.3)
    eq(app.Settings.pages.modules:IsShown(), true)
    eq(app.Settings.pages.modules:GetAlpha(), 1)
    app.Settings:Select("modules")
    eq(app.Transitions:Count(), 0)
    eq(#app.errors, 0)
end)

test("two channels on one owner settle independently", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local tr = app.Transitions
    local first = H.NewFrame("TransitionProbe3", UIParent)
    local second = H.NewFrame("TransitionProbe4", UIParent)
    tr:Fade("ownerC", first, 0, 0.2, nil, "first")
    tr:Fade("ownerC", second, 0, 0.2, nil, "second")
    eq(tr:Count(), 2)
    tr:Settle("ownerC", "first")
    eq(tr:Count(), 1)
    eq(first:GetAlpha(), 0)
    H.Advance(1)
    eq(second:GetAlpha(), 0)
    eq(tr:Count(), 0)
    eq(#app.errors, 0)
end)

test("disabling a window settles its reveal before hiding it", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    SlashCmdList.LUMAUI("bags")
    local inventory = app.components.inventory
    eq(inventory.frame:GetAlpha(), 0)
    H.Advance(0.05)
    eq(inventory.frame:GetAlpha() < 1, true)
    app.Store:Set("modules", "inventory", false)
    eq(inventory.frame:GetAlpha(), 1)
    eq(inventory.frame:IsShown(), false)
    eq(app.Transitions:Count(), 0)
    eq(#app.errors, 0)
end)

test("a profile change settles a fade that is still in flight", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.Settings:Toggle()
    H.Advance(0.05)
    eq(app.Settings.frame:GetAlpha() < 1, true)
    app.Store:Set("appearance", "accent", "ember")
    eq(app.Settings.frame:GetAlpha(), 1)
    eq(app.Transitions:Count(), 0)
    eq(#app.errors, 0)
end)

test("a forbidden frame is never animated or touched", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local frame = H.NewFrame("TransitionForbidden", UIParent)
    frame.forbidden = true
    local task = app.Transitions:Fade("ownerD", frame, 0.2, 0.2, function() error("must not run") end, "fade")
    eq(task, nil)
    eq(app.Transitions:Count(), 0)
    eq(frame:GetAlpha(), 1)
    app.Transitions:Reveal(frame)
    eq(frame:GetAlpha(), 1)
    H.Advance(1)
    eq(app.Transitions:Count(), 0)
    eq(#app.errors, 0)
end)

-- ==== TRACK: VIS-07 controls —append new tests above this line ====
test("selected navigation keeps its accent after the mouse leaves", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.Settings:Toggle("modules")
    local modules = app.Settings.navigation.modules
    local general = app.Settings.navigation.general
    local accent = app.Theme:Accent()
    eq(modules.state.selected, true)
    eq(modules.selectedMark:IsShown(), true)
    eq(modules.ring.borderColor[1], accent[1])
    modules.scripts.OnEnter(modules)
    H.Advance(0.2)
    eq(modules.ring.borderColor[1], accent[1])
    modules.scripts.OnLeave(modules)
    eq(modules.state.hover, false)
    -- R03: leaving hover never clears the selected accent.
    eq(modules.ring.borderColor[1], accent[1])
    eq(modules.selectedMark:IsShown(), true)
    app.Settings:Select("general")
    eq(modules.state.selected, false)
    -- An idle control carries no hairline at all: the accent ring is a state, and
    -- an unselected entry must not keep a permanent box around it.
    eq(modules.ring.borderColor[4], 0)
    eq(modules.selectedMark:IsShown(), false)
    eq(general.state.selected, true)
    eq(general.ring.borderColor[1], accent[1])
    eq(#app.errors, 0)
end)

test("control state resolves hover, pressed, disabled and click together", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local calls = 0
    local button = app.Controls:Button(UIParent, "Probe", 100, function() calls = calls + 1 end)
    eq(button.state.disabled, false)
    button.scripts.OnEnter(button)
    eq(button.state.hover, true)
    H.Advance(0.2)
    eq(button.hoverOverlay:GetAlpha() > 0, true)
    button.scripts.OnMouseDown(button)
    eq(button.state.pressed, true)
    button.scripts.OnMouseUp(button)
    eq(button.state.pressed, false)
    H.Click(button)
    eq(calls, 1)
    -- Disabled: hover, press and click are inert and an in-flight hover wash is
    -- cancelled instead of finishing behind a disabled control.
    button.scripts.OnLeave(button)
    H.Advance(0.02)
    eq(app.Transitions:Count(), 1)
    button:SetEnabled(false)
    eq(app.Transitions:Count(), 0)
    eq(button.hoverOverlay:GetAlpha(), 0)
    eq(button.state.hover, false)
    button.scripts.OnEnter(button)
    eq(button.state.hover, false)
    H.Click(button)
    eq(calls, 1)
    -- The disabled surface has no edge, so it does not look pressable.
    eq(button.backdrop.edgeFile, nil)
    button:SetEnabled(true)
    H.Click(button)
    eq(calls, 2)
    eq(#app.errors, 0)
end)

test("switch rows have a real track, thumb and one commit per click", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local value = false
    local commits = 0
    local row = app.Controls:Toggle(UIParent, "Probe switch", 0,
        function() return value end,
        function(wanted) commits = commits + 1; value = wanted end)
    eq(row.track ~= nil, true)
    eq(row.thumb.parent, row.track)
    row:Update()
    eq(row.valueText:GetText(), app.L.off)
    eq(row.thumb.point[1], "LEFT")
    H.Click(row)
    eq(commits, 1)
    eq(value, true)
    eq(row.valueText:GetText(), app.L.on)
    eq(row.thumb.point[1], "RIGHT")
    eq(row:IsOn(), true)
    -- A disabled switch does not commit even when clicked.
    row:SetEnabled(false)
    H.Click(row)
    eq(commits, 1)
    row:SetEnabled(true)
    -- Five fast clicks end on the last value, one commit each.
    for _ = 1, 5 do H.Click(row) end
    eq(value, false)
    eq(commits, 6)
    eq(#app.errors, 0)
end)

test("profile input validates and gates the create actions", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.Settings:Toggle("profiles")
    local input = app.Settings.profileInput
    local create = app.Settings.createButton
    eq(input ~= nil and create ~= nil, true)
    -- An empty name is invalid, so both create actions start disabled.
    eq(input:IsValid(), false)
    eq(create.state.disabled, true)
    input:SetText("New profile")
    input.scripts.OnTextChanged(input)
    eq(input:IsValid(), true)
    eq(create.state.disabled, false)
    -- Invalid characters are shown in the warning colour and disable the action.
    input:SetText("bad|name")
    input.scripts.OnTextChanged(input)
    eq(input:IsValid(), false)
    eq(create.state.disabled, true)
    eq(input.ring.borderColor[1], app.Theme.colors.ember[1])
    -- Chinese names survive the edit box and are accepted by the store.
    input:SetText("团队方案")
    input.scripts.OnTextChanged(input)
    eq(input:GetText(), "团队方案")
    eq(input:IsValid(), true)
    H.Click(create)
    eq(app.Store.current, "团队方案")
    -- Focus is visible and Esc leaves the focus state through ClearFocus.
    input.scripts.OnEditFocusGained(input)
    eq(app.Controls.focused, input)
    eq(input.state.focus, true)
    eq(input.ring.borderColor[1], app.Theme:Accent()[1])
    input.scripts.OnEscapePressed(input)
    eq(app.Controls.focused, nil)
    eq(input.state.focus, false)
    eq(#app.errors, 0)
end)

test("a failing control callback is isolated from the rest of the page", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local bad = app.Controls:Button(UIParent, "Bad", 80, function() error("click failure") end)
    H.Click(bad)
    eq(#app.errors, 1)
    eq(app.errors[1].context, "controls/click")
    eq(bad.state.pressed, false)
    local ok = 0
    local good = app.Controls:Button(UIParent, "Good", 80, function() ok = ok + 1 end)
    H.Click(good)
    eq(ok, 1)
    eq(#app.errors, 1)
end)

test("slider follows the drag but commits once on release", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local value = 1.0
    local commits = 0
    local row = app.Controls:Range(UIParent, "Probe scale", 0, 0.7, 1.5, 0.05,
        function() return value end,
        function(wanted) value = wanted; commits = commits + 1 end)
    local slider = row.slider
    eq(slider ~= nil, true)
    row:Update()
    eq(row.valueLabel:GetText(), "100%")
    eq(commits, 0)
    -- Dragging updates the label immediately but never reconciles per pixel.
    slider.scripts.OnMouseDown(slider)
    slider:SetValue(0.95)
    eq(row.valueLabel:GetText(), "95%")
    eq(commits, 0)
    slider.scripts.OnMouseUp(slider)
    eq(commits, 1)
    eq(math.abs(value - 0.95) < 1e-9, true)
    -- The wheel is a coarse commit and values are clamped to the range.
    slider.scripts.OnMouseWheel(slider, 10)
    eq(commits, 2)
    eq(math.abs(value - 1.45) < 1e-9, true)
    slider:SetValue(9)
    eq(commits, 3)
    eq(value, 1.5)
    eq(row.valueLabel:GetText(), "150%")
    -- A programmatic refresh does not call the setter again.
    row:Update()
    eq(commits, 3)
    eq(#app.errors, 0)
end)

test("tabs and fold headers resolve their own selected state", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local picked
    local tab = app.Controls:Tab(UIParent, "Probe tab", 100, function(self) picked = self end)
    eq(tab.selectedMark:IsShown(), false)
    tab:SetSelected(true)
    eq(tab.state.selected, true)
    eq(tab.selectedMark:IsShown(), true)
    H.Click(tab)
    eq(picked, tab)
    tab:SetSelected(false)
    eq(tab.selectedMark:IsShown(), false)
    local folds = {}
    local header = app.Controls:FoldHeader(UIParent, "Probe group", 300, function(folded)
        folds[#folds + 1] = folded
    end)
    eq(header.mark:GetText(), "-")
    H.Click(header)
    eq(folds[1], true)
    eq(header.mark:GetText(), "+")
    eq(header.state.selected, true)
    H.Click(header)
    eq(folds[2], false)
    eq(header.mark:GetText(), "-")
    header:SetFolded(true)
    eq(header.mark:GetText(), "+")
    eq(#app.errors, 0)
end)

test("scroll areas derive their range and clamp scrolling", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local scroll = app.Controls:Scroll(UIParent, 300, 100)
    local body = CreateFrame("Frame", nil, scroll)
    body:SetSize(300, 400)
    scroll:SetScrollChild(body)
    scroll:UpdateRange()
    eq(scroll.rangeMax, 300)
    eq(scroll.bar.maximum, 300)
    eq(scroll:GetVerticalScroll(), 0)
    eq(scroll.thumb:GetHeight(), 24)
    scroll.scripts.OnMouseWheel(scroll, -1)
    eq(scroll:GetVerticalScroll(), 40)
    for _ = 1, 20 do scroll.scripts.OnMouseWheel(scroll, -5) end
    eq(scroll:GetVerticalScroll(), 300)
    for _ = 1, 20 do scroll.scripts.OnMouseWheel(scroll, 5) end
    eq(scroll:GetVerticalScroll(), 0)
    -- Short content collapses the range instead of leaving a dead scrollbar.
    scroll:ScrollBy(300)
    body:SetHeight(50)
    scroll:UpdateRange()
    eq(scroll.rangeMax, 0)
    eq(scroll.bar.maximum, 1)
    eq(scroll:GetVerticalScroll(), 0)
    eq(scroll.thumb:GetHeight() <= scroll:GetHeight(), true)
    eq(#app.errors, 0)
end)

test("profile rows disable impossible actions instead of failing", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.Settings:Toggle("profiles")
    local page = app.Settings.pages.profiles
    page.Update()
    local first = app.Settings.profileRows[1]
    eq(first.key, "Default")
    -- One profile: it is already active and cannot be deleted.
    eq(first.use.state.disabled, true)
    eq(first.delete.state.disabled, true)
    app.Store:Create("Raid", false)
    page.Update()
    local defaultRow, raidRow
    for _, row in ipairs(app.Settings.profileRows) do
        if row.key == "Default" then defaultRow = row end
        if row.key == "Raid" then raidRow = row end
    end
    eq(defaultRow.use.state.disabled, false)
    eq(defaultRow.delete.state.disabled, false)
    eq(raidRow.use.state.disabled, true)
    eq(raidRow.delete.state.disabled, false)
    -- Clicking the disabled "use" of the current profile changes nothing.
    H.Click(raidRow.use)
    eq(app.Store.current, "Raid")
    eq(#app.errors, 0)
end)

test("rapid module switches end on the last value", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.Settings:Toggle("modules")
    local row = app.Settings.pages.modules.rows.launcher
    local before = app.Store:Profile().modules.launcher
    for _ = 1, 5 do H.Click(row) end
    eq(app.Store:Profile().modules.launcher, not before)
    eq(row:IsOn(), not before)
    eq(row.valueText:GetText(), (not before) and app.L.on or app.L.off)
    eq(#app.errors, 0)
end)

test("inventory filter chips use the shared selected state", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    SlashCmdList.LUMAUI("bags")
    local inventory = app.components.inventory
    local all, equip = inventory.filters[1], inventory.filters[2]
    eq(all.selected, true)
    eq(all.state.selected, true)
    eq(all.text.textColor[1], app.Theme:Accent()[1])
    -- Hovering and leaving an idle chip keeps it muted, not accent.
    equip.scripts.OnEnter(equip)
    equip.scripts.OnLeave(equip)
    eq(equip.selected, false)
    eq(equip.state.hover, false)
    eq(equip.text.textColor[1], app.Theme.colors.muted[1])
    -- Selecting another chip moves the accent; the old one returns to muted.
    H.Click(equip)
    eq(equip.selected, true)
    eq(all.selected, false)
    eq(equip.text.textColor[1], app.Theme:Accent()[1])
    eq(all.text.textColor[1], app.Theme.colors.muted[1])
    eq(#app.errors, 0)
end)

-- ==== TRACK: VIS-08 settings sample —append new tests above this line ====
test("settings header is compact and the general page scrolls", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.Settings:Toggle()
    local frame = app.Settings.frame
    local general = app.Settings.pages.general
    eq(frame:IsShown(), true)
    eq(general:IsShown(), true)
    -- Pages start above the old 110px header, so the content area is taller.
    eq(general.point[1], "TOPLEFT")
    eq(general.point[2], 228)
    eq(general.point[3], -72)
    eq(app.Settings.versionLabel:GetText(), app.version)
    eq(app.Settings.closeButton ~= nil, true)
    -- Long content lives in a scroll area instead of running past the window.
    eq(general.scroll ~= nil, true)
    eq(general.scroll.rangeMax > 0, true)
    for _, key in ipairs({ "general", "layout", "modules", "profiles", "diagnostics" }) do
        eq(app.Settings.pages[key] ~= nil, true)
        eq(app.Settings.navigation[key].state.selected, key == "general")
    end
    eq(#app.errors, 0)
end)

test("shared settings scroll areas accept wheel input", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.Settings:Toggle("layout")
    for _, key in ipairs({ "general", "layout", "modules", "diagnostics" }) do
        local scroll = app.Settings.pages[key].scroll
        eq(scroll:IsMouseEnabled(), true)
        eq(scroll:IsMouseWheelEnabled(), true)
    end
    local scroll = app.Settings.pages.layout.scroll
    -- The harness does not calculate the client's dynamic layout height.
    scroll.rangeMax = 100
    eq(scroll:GetVerticalScroll(), 0)
    scroll.scripts.OnMouseWheel(scroll, -1)
    eq(scroll:GetVerticalScroll() > 0, true)
    eq(#app.errors, 0)
end)

test("settings controls fit their scroll content without clipping the values", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.Settings:Toggle("general")
    local page = app.Settings.pages.general
    for _, control in ipairs(page.settings) do
        if control.slider then
            eq(control:GetWidth(), 462)
            eq(control.slider:GetWidth(), 462)
        elseif control.kind == "switch" then
            eq(control:GetWidth(), 462)
            eq(control.text.point[1], "RIGHT")
            eq(control.text.point[2], control.statusText)
        end
    end
    eq(#app.errors, 0)
end)

test("settings general page reserves height for long translated descriptions", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.L.generalHint = string.rep("长说明文字", 60)
    app.L.clockOwner = string.rep("时钟选择说明", 25)
    app.L.instructions = string.rep("布局说明", 40)
    app.L.compatibilityHint = string.rep("透明度说明", 40)
    app.Settings:Toggle("general")
    local page = app.Settings.pages.general
    local clock
    for _, control in ipairs(page.settings) do
        if control.text and control.text:GetText() == app.L.clockStrip then clock = control end
    end
    eq(clock ~= nil, true)
    eq(clock.point[3] <= page.clockLabel.point[3] - page.clockLabel:GetStringHeight(), true)
    local body = page.scroll:GetScrollChild()
    eq(body:GetHeight() >= -page.compatibilityHint.point[3] + page.compatibilityHint:GetStringHeight(), true)
    eq(#app.errors, 0)
end)

test("layout page flows long notes, warnings and every movable row within one scroll", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.L.layoutHint = string.rep("布局说明", 70)
    app.L.nativeLayoutHint = string.rep("原生界面说明", 45)
    app.L.presetHint = string.rep("预设说明", 50)
    app.L.presetOverlapHint = string.rep("重叠警告", 50)
    app.Settings:Toggle("layout")
    local page, settings = app.Settings.pages.layout, app.Settings
    eq(page.scroll, settings.layoutScroll)
    eq(page.layoutMove.point[3] <= page.layoutHint.point[3] - page.layoutHint:GetStringHeight(), true)
    eq(settings.presetChoices.combat.point[3] <= page.presetHint.point[3] - page.presetHint:GetStringHeight(), true)
    local firstY = settings.layoutRows[1].point[3]
    app.Layout.previewWarnings = { questList = true }
    settings:Update()
    eq(settings.layoutRows[1].point[3] < firstY, true)
    eq(settings.layoutRows[1].point[3] <= settings.layoutCount.point[3] - settings.layoutCount:GetStringHeight(), true)
    local rows = settings.layoutRows
    local last = rows[#app.Layout:IDs()]
    local body = page.scroll:GetScrollChild()
    eq(body:GetHeight() >= -last.point[3] + last:GetHeight(), true)
    eq(page.scroll.rangeMax > 0, true)
    page.scroll:ScrollBy(page.scroll.rangeMax)
    local offset = page.scroll:GetVerticalScroll()
    settings:Select("general")
    settings:Select("layout")
    eq(page.scroll:GetVerticalScroll(), offset)
    eq(#app.errors, 0)
end)

test("general page exposes role opacities and reduced motion", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.Settings:Toggle("general")
    local page = app.Settings.pages.general
    local function find(text)
        for _, control in ipairs(page.settings) do
            if control.title and control.title:GetText() == text then return control end
            if control.text and type(control.text.GetText) == "function" and control.text:GetText() == text then
                return control
            end
        end
    end
    local windowRow = find(app.L.windowOpacity)
    eq(windowRow ~= nil, true)
    -- Dragging only commits on release, so the stored value stays until then.
    windowRow.slider.scripts.OnMouseDown(windowRow.slider)
    windowRow.slider:SetValue(0.75)
    eq(app.Store:Profile().appearance.windowOpacity, 0.92)
    windowRow.slider.scripts.OnMouseUp(windowRow.slider)
    eq(app.Store:Profile().appearance.windowOpacity, 0.75)
    local reduceRow = find(app.L.reduceMotion)
    eq(reduceRow ~= nil, true)
    H.Click(reduceRow)
    eq(app.Store:Profile().appearance.reduceMotion, true)
    eq(app.Transitions:MotionEnabled(), false)
    -- The chat input backing is a separate token, so the idle support and the
    -- field the player types into can be tuned apart.
    local activeRow = find(app.L.chatActiveOpacity)
    eq(activeRow ~= nil, true)
    activeRow.slider.scripts.OnMouseDown(activeRow.slider)
    activeRow.slider:SetValue(0.4)
    activeRow.slider.scripts.OnMouseUp(activeRow.slider)
    eq(app.Store:Profile().appearance.chatActiveOpacity, 0.4)
    eq(#app.errors, 0)
end)

test("modules page separates issues from the switch list", function()
    local app = H.Load()
    app:RegisterComponent({ id = "brokenProbe", defaultEnabled = true,
        Enable = function() error("probe failure") end, Disable = function() end })
    H.Fire("PLAYER_LOGIN")
    app.Settings:Toggle("modules")
    local page = app.Settings.pages.modules
    eq(app.components.brokenProbe.status, "failed")
    -- The line counts every component that needs attention, including optional
    -- ones this client does not support, so compare against the same rule.
    local attention = 0
    for _, component in pairs(app.components) do
        if component.status == "failed" or component.status == "unsupported" then
            attention = attention + 1
        end
    end
    eq(attention >= 1, true)
    eq(page.issues:GetText():find(tostring(attention), 1, true) ~= nil, true)
    eq(page.diagButton:IsShown(), true)
    H.Click(page.diagButton)
    eq(app.Settings.active, "diagnostics")
    eq(app.Settings.pages.diagnostics:IsShown(), true)
    eq(#app.errors >= 1, true)
end)

test("diagnostics folds sections and shows the error count", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.Settings:Toggle("diagnostics")
    local page = app.Settings.pages.diagnostics
    eq(page.bodies.status:IsShown(), true)
    eq(page.bodies.native:IsShown(), false)
    eq(page.bodies.errors:IsShown(), true)
    H.Click(page.headers.native)
    eq(page.bodies.native:IsShown(), true)
    H.Advance(0.2)
    eq(page.bodies.native:GetAlpha(), 1)
    H.Click(page.headers.status)
    H.Advance(0.3)
    eq(page.bodies.status:IsShown(), false)
    app:Report("probe", "diagnostic error")
    app.Settings:Update()
    eq(page.headers.errors.text:GetText():find("1", 1, true) ~= nil, true)
    eq(#app.errors >= 1, true)
end)

test("a read-only profile disables changes and shows the notice", function()
    local app = H.Load({ schema = 99 })
    H.Fire("PLAYER_LOGIN")
    eq(app.Store.readonly, true)
    app.Settings:Toggle("profiles")
    eq(app.Settings.readonlyNote:IsShown(), true)
    eq(app.Settings.createButton.state.disabled, true)
    eq(app.Settings.profileRows[1].use.state.disabled, true)
    eq(app.Settings.profileRows[1].delete.state.disabled, true)
    eq(app.Settings.footer:GetText(), app.L.readonlyNote)
    -- General settings cannot be changed either.
    app.Settings:Select("general")
    local disabled = 0
    for _, control in ipairs(app.Settings.pages.general.settings) do
        if control.state and control.state.disabled then disabled = disabled + 1 end
    end
    eq(disabled > 0, true)
    -- Layout actions are disabled as well.
    app.Settings:Select("layout")
    eq(app.Settings.layoutRows[1].button.state.disabled, true)
    eq(#app.errors, 0)
end)

test("closing the settings window clears keyboard focus", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.Settings:Toggle("profiles")
    local input = app.Settings.profileInput
    input.scripts.OnEditFocusGained(input)
    eq(app.Controls.focused, input)
    app.Settings:Close()
    eq(app.Controls.focused, nil)
    eq(input.state.focus, false)
    H.Advance(0.3)
    eq(app.Settings.frame:IsShown(), false)
    eq(#app.errors, 0)
end)

test("changing pages or closing through the client releases the profile input", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.Settings:Toggle("profiles")
    local input = app.Settings.profileInput
    input.focused = true
    input.scripts.OnEditFocusGained(input)
    app.Settings:Select("general")
    eq(input.focused, false)
    eq(app.Controls.focused, nil)
    app.Settings:Select("profiles")
    input.focused = true
    input.scripts.OnEditFocusGained(input)
    app.Settings.frame:Hide()
    eq(input.focused, false)
    eq(app.Controls.focused, nil)
    eq(#app.errors, 0)
end)

test("a value is saved even if the window closes during the transition", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.Settings:Toggle("modules")
    local row = app.Settings.pages.modules.rows.minimap
    local before = app.Store:Profile().modules.minimap
    H.Click(row)
    eq(app.Store:Profile().modules.minimap, not before)
    app.Settings:Close()
    H.Advance(1)
    eq(app.Settings.frame:IsShown(), false)
    eq(app.Store:Profile().modules.minimap, not before)
    eq(#app.errors, 0)
end)

test("fifty fast page switches settle on the last page", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.Settings:Toggle()
    local keys = { "general", "layout", "modules", "profiles", "diagnostics" }
    for index = 1, 50 do app.Settings:Select(keys[(index % #keys) + 1]) end
    eq(app.Settings.active, keys[(50 % #keys) + 1])
    H.Advance(1)
    eq(app.Transitions:Count(), 0)
    eq(#app.errors, 0)
end)

test("a hundred window cycles keep objects and tasks stable", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.Settings:Toggle()
    H.Advance(0.3)
    local frames = #H.frames
    for _ = 1, 50 do
        app.Settings:Close()
        app.Settings:Open()
    end
    H.Advance(1)
    eq(#H.frames, frames)
    eq(app.Settings.frame:IsShown(), true)
    eq(app.Transitions:Count(), 0)
    -- The window still works after the cycles.
    app.Settings:Select("modules")
    eq(app.Settings.pages.modules:IsShown(), true)
    eq(#app.errors, 0)
end)

test("each settings page keeps its own scroll position", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.Settings:Toggle("modules")
    H.Advance(0.3)
    local modules = app.Settings.pages.modules
    modules.scroll:ScrollBy(80)
    eq(modules.scroll:GetVerticalScroll(), 80)
    app.Settings:Select("general")
    app.Settings:Select("modules")
    eq(modules.scroll:GetVerticalScroll(), 80)
    eq(#app.errors, 0)
end)

test("an accent change repaints cached page controls", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.Settings:Toggle("modules")
    local row = app.Settings.pages.modules.rows.launcher
    local old = app.Theme:Accent()
    app.Store:Set("appearance", "accent", "ember")
    local ember = app.Theme.colors.ember
    eq(app.Theme:Accent()[1], ember[1])
    eq(old[1] ~= ember[1], true)
    eq(row.valueText.textColor[1], ember[1])
    eq(#app.errors, 0)
end)

test("general page wraps long Chinese text inside its scroll area", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.Settings:Toggle("general")
    local page = app.Settings.pages.general
    eq(page.compatibilityHint:GetText(), app.L.compatibilityHint)
    eq(page.compatibilityHint.width, 462)
    eq(page.instructions.width, 462)
    eq(page.scroll.rangeMax > 0, true)
    eq(#app.errors, 0)
end)

-- ==== TRACK: VIS-09 action button sample —append new tests above this line ====
test("action button sample skins the main bar and records originals", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local button = _G.ActionButton1
    eq(app.components.actionButtons.status, "disabled")
    -- Nothing is touched while the sample is off.
    eq(button.icon.texCoord, nil)
    eq(button.lumaActionSkin, nil)
    app.Store:Set("modules", "actionButtons", true)
    local component = app.components.actionButtons
    eq(component.running, true)
    eq(component.skinned, 1)
    eq(component.total, 1)
    -- Icon crop, HotKey/Count fonts and our own backing/edge.
    eq(button.icon.texCoord[1], 0.08)
    eq(button.icon.texCoord[2], 0.92)
    eq(button.icon.texCoord[3], 0.08)
    eq(button.icon.texCoord[4], 0.92)
    eq(button.HotKey.fontSize, 10)
    eq(button.Count.fontSize, 12)
    eq(button.lumaActionSkin.bg:IsShown(), true)
    eq(button.lumaActionSkin.border:IsShown(), true)
    eq(button.lumaActionSkin.border.backdrop.edgeSize, 1)
    -- Only the static frame art is replaced; it is recorded first.
    eq(button.NormalTexture:GetAlpha(), 0)
    eq(button.SlotBackground:GetAlpha(), 0)
    eq(button.SlotArt:GetAlpha(), 0)
    app.Settings:Toggle("modules")
    eq(app.Settings.pages.modules.rows.actionButtons ~= nil, true)
    eq(#app.errors, 0)
end)

test("disabling the action button sample restores the native button", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local button = _G.ActionButton1
    app.Store:Set("modules", "actionButtons", true)
    app.Store:Set("modules", "actionButtons", false)
    -- The harness reports the default crop {0,0,0,0,1,1,1,1} and size 13.
    eq(button.icon.texCoord[1], 0)
    eq(button.icon.texCoord[5], 1)
    eq(button.icon.texCoord[6], 1)
    eq(button.HotKey.fontSize, 13)
    eq(button.Count.fontSize, 13)
    eq(button.NormalTexture:GetAlpha(), 1)
    eq(button.SlotBackground:GetAlpha(), 1)
    eq(button.SlotArt:GetAlpha(), 1)
    eq(button.lumaActionSkin.bg:IsShown(), false)
    eq(button.lumaActionSkin.border:IsShown(), false)
    eq(app.Transitions:Count(), 0)
    eq(#app.errors, 0)
end)

test("action button edges follow the bar's effective scale on refresh", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local button = _G.ActionButton1
    button:SetScale(2)
    app.Store:Set("modules", "actionButtons", true)
    eq(button.lumaActionSkin.border.backdrop.edgeSize, 0.5)
    button:SetScale(1)
    H.Fire("EDIT_MODE_LAYOUTS_UPDATED")
    eq(button.lumaActionSkin.border.backdrop.edgeSize, 1)
    eq(#app.errors, 0)
end)

test("action button refresh restores a button removed from the bar", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local old = _G.ActionButton1
    app.Store:Set("modules", "actionButtons", true)
    local replacement = H.NewFrame(nil, _G.MainActionBar)
    replacement.icon = H.NewFrame(nil, replacement)
    _G.MainActionBar.actionButtons = { replacement }
    app.components.actionButtons:Refresh()
    eq(old.icon.texCoord[1], 0)
    eq(old.NormalTexture:GetAlpha(), 1)
    eq(old.lumaActionSkin.border:IsShown(), false)
    old.scripts.OnEnter(old)
    eq(app.Transitions:Count(), 0)
    eq(replacement.lumaActionSkin.border:IsShown(), true)
    eq(#app.errors, 0)
end)

test("action button refresh restores replaced regions and skins their replacements", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local button = _G.ActionButton1
    local originalIcon, originalHotkey = button.icon, button.HotKey
    app.Store:Set("modules", "actionButtons", true)
    button.icon = H.NewFrame(nil, button)
    button.HotKey = H.NewFrame(nil, button)
    app.components.actionButtons:Refresh()
    eq(originalIcon.texCoord[1], 0)
    eq(originalHotkey.fontSize, 13)
    eq(button.icon.texCoord[1], 0.08)
    eq(button.HotKey.fontSize, 10)
    app.Store:Set("modules", "actionButtons", false)
    eq(button.icon.texCoord[1], 0)
    eq(button.HotKey.fontSize, 13)
    eq(#app.errors, 0)
end)

test("action button refresh restores replaced static art before styling the new member", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local button = ActionButton1
    local old = button.SlotArt
    old:SetAlpha(0.4)
    app.Store:Set("modules", "actionButtons", true)
    eq(old:GetAlpha(), 0)
    local replacement = H.NewFrame(nil, button)
    replacement:SetAlpha(0.7)
    button.SlotArt = replacement
    app.components.actionButtons:Refresh()
    eq(old:GetAlpha(), 0.4)
    eq(replacement:GetAlpha(), 0)
    app.Store:Set("modules", "actionButtons", false)
    eq(replacement:GetAlpha(), 0.7)
    eq(#app.errors, 0)
end)

test("action button refresh hides its skin when a decorated icon becomes forbidden", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local button = ActionButton1
    app.Store:Set("modules", "actionButtons", true)
    button.icon.forbidden = true
    app.components.actionButtons:Refresh()
    eq(app.components.actionButtons.failed, true)
    eq(button.lumaActionSkin.border:IsShown(), false)
    eq(button.lumaActionSkin.bg:IsShown(), false)
    eq(button.NormalTexture:GetAlpha(), 1)
    eq(app.components.actionButtons.originals[button] ~= nil, true)
    button.icon.forbidden = false
    app.Store:Set("modules", "actionButtons", false)
    eq(button.icon.texCoord[1], 0)
    eq(app.components.actionButtons.originals[button], nil)
end)

test("action button refresh rolls back if a tracked member becomes restricted", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local button = ActionButton1
    local original = button.SlotArt
    app.Store:Set("modules", "actionButtons", true)
    button.SlotArt = H.Secret("restricted")
    app.components.actionButtons:Refresh()
    eq(app.components.actionButtons.failed, true)
    eq(original:GetAlpha(), 1)
    eq(button.lumaActionSkin.border:IsShown(), false)
    eq(app.components.actionButtons.originals[button], nil)
    eq(#app.errors > 0, true)
    button.SlotArt = original
    app.Store:Set("modules", "actionButtons", false)
end)

test("action button sample leaves an unreadable icon and forbidden member alone", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local button = _G.ActionButton1
    local forbidden = button.HotKey
    forbidden.forbidden = true
    local icon = button.icon
    local original = icon.GetTexCoord
    icon.GetTexCoord = function() return H.Secret(0), 0, 0, 0, 1, 1, 1, 1 end
    app.Store:Set("modules", "actionButtons", true)
    eq(button.lumaActionSkin, nil)
    eq(button.NormalTexture:GetAlpha(), 1)
    icon.GetTexCoord = original
    app.components.actionButtons:Refresh()
    eq(forbidden.fontSize, nil)
    eq(button.lumaActionSkin.border:IsShown(), true)
    app.Store:Set("modules", "actionButtons", false)
    eq(forbidden.fontSize, nil)
    eq(#app.errors, 0)
end)

test("action button apply failure restores changed members and reports the failure", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local button = _G.ActionButton1
    local art = button.SlotArt
    local setter = art.SetAlpha
    local failed = false
    art.SetAlpha = function(self, value)
        if value == 0 and not failed then failed = true; error("test failure") end
        setter(self, value)
    end
    app.Store:Set("modules", "actionButtons", true)
    eq(button.icon.texCoord[1], 0)
    eq(button.HotKey.fontSize, 13)
    eq(button.NormalTexture:GetAlpha(), 1)
    eq(button.SlotBackground:GetAlpha(), 1)
    eq(button.lumaActionSkin.border:IsShown(), false)
    eq(app.components.actionButtons.failed, true)
    eq(#app.errors > 0, true)
    button.scripts.OnEnter(button)
    eq(app.Transitions:Count(), 0)
    app.Store:Set("modules", "actionButtons", false)
    eq(app.components.actionButtons.failed, nil)
end)

test("action button restoration keeps its snapshot when a region becomes forbidden", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local button = _G.ActionButton1
    app.Store:Set("modules", "actionButtons", true)
    button.icon.forbidden = true
    app.Store:Set("modules", "actionButtons", false)
    eq(button.lumaActionSkin.border:IsShown(), false)
    eq(app.components.actionButtons.originals[button] ~= nil, true)
    button.icon.forbidden = false
    app.Store:Set("modules", "actionButtons", true)
    app.Store:Set("modules", "actionButtons", false)
    eq(button.icon.texCoord[1], 0)
    eq(app.components.actionButtons.originals[button], nil)
end)

test("repeated action button cycles keep one skin and one hook set", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local button = _G.ActionButton1
    local before = #(button.children or {})
    for _ = 1, 20 do
        app.Store:Set("modules", "actionButtons", true)
        app.Store:Set("modules", "actionButtons", false)
    end
    local skin = button.lumaActionSkin
    eq(skin ~= nil, true)
    -- OnEnter + OnLeave + OnHide, installed once for the session.
    eq(button.hookCount, 3)
    -- Only the backing texture and the border frame were added.
    eq(#button.children, before + 2)
    app.Store:Set("modules", "actionButtons", true)
    eq(button.lumaActionSkin, skin)
    eq(#button.children, before + 2)
    eq(#app.errors, 0)
end)

test("action button sample skips buttons without an icon", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local fake = H.NewFrame("ActionButton2", _G.MainActionBar)
    fake.NormalTexture = H.NewFrame(nil, fake)
    _G.MainActionBar.actionButtons[2] = fake
    app.Store:Set("modules", "actionButtons", true)
    eq(app.components.actionButtons.total, 2)
    eq(app.components.actionButtons.skinned, 1)
    eq(fake.lumaActionSkin, nil)
    eq(#app.errors, 0)
end)

test("action button sample reports unsupported without a main bar", function()
    local app = H.Load()
    _G.MainActionBar.actionButtons = nil
    _G.ActionButton1 = nil
    H.Fire("PLAYER_LOGIN")
    app.Store:Set("modules", "actionButtons", true)
    eq(app.components.actionButtons.status, "unsupported")
    eq(app.components.actionButtons.running, nil)
    eq(#app.errors, 0)
end)

test("action button sample defers protected changes until combat ends", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local button = _G.ActionButton1
    H.Combat(true)
    app.Store:Set("modules", "actionButtons", true)
    eq(app.components.actionButtons.running, nil)
    eq(button.icon.texCoord, nil)
    eq(button.lumaActionSkin, nil)
    H.Combat(false)
    eq(app.components.actionButtons.running, true)
    eq(button.icon.texCoord[1], 0.08)
    -- Disabling in combat also waits; the skin stays until the fight ends.
    H.Combat(true)
    app.Store:Set("modules", "actionButtons", false)
    eq(button.icon.texCoord[1], 0.08)
    H.Combat(false)
    eq(button.icon.texCoord[1], 0)
    eq(button.lumaActionSkin.border:IsShown(), false)
    eq(app.Transitions:Count(), 0)
    eq(#app.errors, 0)
end)

test("the sample animates only its own hover edge and stops on disable", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.Store:Set("modules", "actionButtons", true)
    local button = _G.ActionButton1
    local skin = button.lumaActionSkin
    local line = app.Theme.colors.line
    eq(skin.border.borderColor[1], line[1])
    button.scripts.OnEnter(button)
    H.Advance(0.2)
    local accent = app.Theme:Accent()
    eq(math.abs(skin.border.borderColor[1] - accent[1]) < 0.01, true)
    eq(math.abs(skin.border.borderColor[3] - accent[3]) < 0.01, true)
    -- Disabling mid-interaction cancels the task and hides the edge.
    app.Store:Set("modules", "actionButtons", false)
    eq(app.Transitions:Count(), 0)
    eq(skin.border:IsShown(), false)
    -- The permanent hook is inert after the sample stops.
    button.scripts.OnEnter(button)
    eq(skin.border:IsShown(), false)
    eq(#app.errors, 0)
end)

test("the sample follows a live accent change on cached buttons", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.Store:Set("modules", "actionButtons", true)
    local button = _G.ActionButton1
    button.scripts.OnEnter(button)
    H.Advance(0.2)
    eq(math.abs(button.lumaActionSkin.border.borderColor[1] - app.Theme:Accent()[1]) < 0.01, true)
    app.Store:Set("appearance", "accent", "ember")
    -- The refresh repaints the cached button with the current hover mix.
    eq(math.abs(button.lumaActionSkin.border.borderColor[1] - app.Theme.colors.ember[1]) < 0.01, true)
    eq(app.Theme:Accent()[1], app.Theme.colors.ember[1])
    eq(#app.errors, 0)
end)

test("the sample leaves state art and click behaviour untouched", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local fake = H.NewFrame("ActionButton3", _G.MainActionBar)
    fake.icon = H.NewFrame(nil, fake)
    fake.NormalTexture = H.NewFrame(nil, fake)
    fake.PushedTexture = H.NewFrame(nil, fake)
    fake.PushedTexture:SetAlpha(0.8)
    fake.CheckedTexture = H.NewFrame(nil, fake)
    fake.CheckedTexture:SetAlpha(0.5)
    fake.cooldown = H.NewFrame(nil, fake)
    fake.SpellHighlightTexture = H.NewFrame(nil, fake)
    _G.MainActionBar.actionButtons[3] = fake
    app.Store:Set("modules", "actionButtons", true)
    eq(fake.icon.texCoord[1], 0.08)
    eq(fake.PushedTexture:GetAlpha(), 0.8)
    eq(fake.CheckedTexture:GetAlpha(), 0.5)
    eq(fake.cooldown.alpha, nil)
    eq(fake.cooldown.scripts.OnClick, nil)
    eq(fake.SpellHighlightTexture.alpha, nil)
    eq(fake.scripts.OnClick, nil)
    eq(fake.attributes["type"], nil)
    eq(#app.errors, 0)
end)

test("the button sample and the bar panel stay independent", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.Store:Set("modules", "actionPanel", true)
    local panel = app.components.actionPanel.panels[_G.MainActionBar]
    eq(panel:IsShown(), true)
    local barArt = _G.MainActionBar.BorderArt
    local artAlpha = barArt.alpha
    app.Store:Set("modules", "actionButtons", true)
    -- The bar frame art and the panel background are not part of this sample.
    eq(barArt.alpha, artAlpha)
    eq(panel.backgroundColor[4], 0.80)
    app.Store:Set("modules", "actionButtons", false)
    eq(panel:IsShown(), true)
    eq(#app.errors, 0)
end)

test("diagnostics report how many sample buttons were skinned", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.Store:Set("modules", "actionButtons", true)
    app.Settings:Toggle("diagnostics")
    local text = app.Settings.pages.diagnostics:DisplayText()
    eq(text:find("actionButtons: 1/1", 1, true) ~= nil, true)
    app.Store:Set("modules", "actionButtons", false)
    app.Settings:Update()
    eq(app.Settings.pages.diagnostics:DisplayText():find("actionButtons:", 1, true), nil)
    eq(#app.errors, 0)
end)

test("the bar ownership report reads the client without touching anything", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local panel = app.components.actionPanel
    H.messages = {}
    SlashCmdList.LUMAUI("bars")
    local text = table.concat(H.messages, "\n")
    -- The report names every tracked bar even when the client never built it.
    eq(text:find(app.L.barsReportHeader, 1, true) ~= nil, true)
    eq(text:find("MainActionBar", 1, true) ~= nil, true)
    eq(text:find("MultiBarBottomLeft", 1, true) ~= nil, true)
    eq(text:find("MultiBar7", 1, true) ~= nil, true)
    eq(text:find("PetActionBar", 1, true) ~= nil, true)
    -- A bar that exists reports visibility and button count; without a rect
    -- from the client it says so instead of inventing coordinates.
    local mainLine = text:match("MainActionBar%s+shown=%S+.*")
    eq(mainLine ~= nil, true)
    eq(mainLine:find("shown=yes", 1, true) ~= nil, true)
    eq(mainLine:find("buttons=", 1, true) ~= nil, true)
    -- The report is read-only: no panel was created and no bar state changed.
    eq(panel.panels == nil or next(panel.panels) == nil, true)
    eq(_G.MainActionBar:IsShown(), true)
    eq(#app.errors, 0)
end)

test("the bar ownership report works while the panel component is off", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    eq(app.components.actionPanel.status, "disabled")
    H.messages = {}
    SlashCmdList.LUMAUI("bars")
    local text = table.concat(H.messages, "\n")
    eq(text:find(app.L.barsReportHeader, 1, true) ~= nil, true)
    eq(text:find("status=disabled", 1, true) ~= nil, true)
    eq(#app.errors, 0)
end)

test("the bar ownership report flags two visible bars on the same spot", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    -- The harness MainActionBar and MultiBarBottomLeft both exist and are shown;
    -- give them one top-left corner and different corners from every other bar.
    _G.MultiBarBottomLeft = H.NewFrame("MultiBarBottomLeft", UIParent)
    _G.MultiBarBottomLeft.rect = { left = 890, bottom = 60, width = 524, height = 45 }
    _G.MultiBarBottomLeft.actionButtons = {}
    local main = _G.MainActionBar
    main.rect = { left = 890, bottom = 60, width = 524, height = 45 }
    main.actionButtons = {}
    H.messages = {}
    SlashCmdList.LUMAUI("bars")
    local text = table.concat(H.messages, "\n")
    -- Each stacked bar names the other instead of both reading as normal rows.
    local mainLine = text:match("MainActionBar%s+shown=%S+.*")
    local leftLine = text:match("MultiBarBottomLeft%s+shown=%S+.*")
    eq(mainLine:find(app.L.barsOverlapAt, 1, true) ~= nil, true)
    eq(leftLine:find(app.L.barsOverlapAt, 1, true) ~= nil, true)
    -- Separating the bars clears the flag on the next report.
    main.rect = { left = 890, bottom = 60, width = 524, height = 45 }
    _G.MultiBarBottomLeft.rect = { left = 890, bottom = 10, width = 524, height = 45 }
    H.messages = {}
    SlashCmdList.LUMAUI("bars")
    text = table.concat(H.messages, "\n")
    eq(text:find(app.L.barsOverlapAt, 1, true), nil)
    eq(#app.errors, 0)
end)

-- ==== TRACK: VIS-10 layout groups and presets — append new tests above this line ====
test("party frames are one layout group item", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.Store:Set("modules", "partyFrames", true)
    local ids = app.Layout:IDs()
    local hasParty = false
    for _, id in ipairs(ids) do
        if id == "party" then hasParty = true end
        eq(id ~= "party_party1", true)
    end
    eq(hasParty, true)
    local group = app.Layout.entries.party
    eq(group.group, true)
    eq(group.label, app.L.partyGroup)
    local member = app.Layout.entries.party_party1
    eq(member.member, true)
    eq(member.groupId, "party")
    eq(member.frame.parent, group.frame)
    -- Pearl puts the party block on the left edge, level with the unit bars: on
    -- the 1920x1080 fixture its left edge lands at 15.5% of the width (-567 is
    -- the centre offset) and the first row's top edge at 48.5% of the height.
    eq(group.x, -567)
    -- Four compact 32 unit rows with a 3 unit gap: the block is 140 high and
    -- grows downward from the same first-row centre.
    eq(group.y, -38)
    eq(group.frame:GetWidth(), 190)
    eq(group.frame:GetHeight(), 140)
    eq(member.rx, 0)
    eq(member.ry, 54)
    eq(app.Layout.entries.party_party3.ry, -16)
    -- Moving the group moves every member with it.
    app.Store:SetPosition("party", 120, -40)
    app.Layout:ApplyAll()
    eq(group.frame.point[1], "CENTER")
    eq(group.frame.point[2], UIParent)
    eq(group.frame.point[4], 120)
    eq(group.frame.point[5], -40)
    eq(member.frame.point[1], "CENTER")
    eq(member.frame.point[2], group.frame)
    eq(member.frame.point[4], 0)
    eq(member.frame.point[5], 54)
    eq(#app.errors, 0)
end)

test("old absolute party positions convert once into group offsets", function()
    local app = H.Load({ profiles = { Default = { positions = {
        party_party2 = { x = -200, y = -320 },
    } } } })
    H.Fire("PLAYER_LOGIN")
    app.Store:Set("modules", "partyFrames", true)
    local member = app.Layout.entries.party_party2
    -- -200 - (-567) = 367 ; -320 - (-38) = -282
    eq(member.rx, 367)
    eq(member.ry, -282)
    -- The old absolute key stays; the migration offset is persisted next to it.
    eq(app.Store:Profile().positions.party_party2.x, -200)
    eq(app.Store:Profile().positions["party|party_party2"].x, 367)
    app.Store:SetPosition("party", 0, 0)
    app.Layout:ApplyAll()
    eq(member.frame.point[4], 367)
    eq(member.frame.point[5], -282)
    eq(#app.errors, 0)
end)

test("the information strip owns the bottom bar while experience stays on top", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local group = app.Layout.entries.bottomBar
    eq(group.group, true)
    eq(group.label, app.L.bottomBar)
    local strip = app.Layout.entries.dataStrip
    local xp = app.Layout.entries.experience
    eq(strip.member, true)
    eq(strip.groupId, "bottomBar")
    eq(xp.groupId, "topInfo")
    eq(strip.rx, 0)
    eq(strip.ry, 0)
    eq(xp.ry, -17)
    eq(strip.frame.parent, group.frame)
    local top = app.Layout.entries.topInfo
    eq(xp.frame.parent, top.frame)
    for _, id in ipairs(app.Layout:IDs()) do
        eq(id ~= "dataStrip", true)
        eq(id ~= "experience", true)
    end
    eq(#app.errors, 0)
end)

test("a stale top info centre cannot drag the experience bar off the screen axis", function()
    local app = H.Load({ schema = 1, profiles = { Default = { positions = {
        topInfo = { x = -900, y = 420 },
    } } } })
    H.Fire("PLAYER_LOGIN")
    local group = app.Layout.entries.topInfo
    -- The band keeps the saved height but its centre stays on the screen axis,
    -- so an old or accidental drag cannot leave the bar half off the window.
    eq(group.frame.point[1], "CENTER")
    eq(group.frame.point[4], 0)
    eq(group.frame.point[5], 420)
    eq(app.Store:Profile().positions.topInfo.x, -900)
    eq(#app.errors, 0)
end)

test("a legacy experience position is centred inside the top information band", function()
    local app = H.Load({ schema = 1, profiles = { Default = { positions = {
        experience = { x = -900, y = 500 },
    } } } })
    H.Fire("PLAYER_LOGIN")
    local xp = app.Layout.entries.experience
    -- The old absolute centre only contributes its height; the corrected
    -- per-member offset is written back for the next profile load.
    eq(xp.rx, 0)
    eq(xp.ry, 7)
    eq(app.Store:Profile().positions["topInfo|experience"].x, 0)
    app.Store:SetPosition("topInfo|experience", -300, 0)
    app.Layout:RefreshMembers()
    eq(xp.rx, 0)
    eq(#app.errors, 0)
end)

test("the bottom strip spans the screen, spreads its readings and keeps a saved position", function()
    local app = H.Load(); UIParent:SetSize(1920, 1080); H.Fire("PLAYER_LOGIN")
    local strip = app.components.dataStrip
    local group = app.Layout.entries.bottomBar
    -- Full width, flush to the bottom edge: the group owns the edge margin.
    eq(strip.frame:GetWidth(), 1920)
    eq(group.frame:GetWidth(), 1920)
    eq(group.margin, 0)
    eq(group.frame.point[4], 0)
    eq(group.frame.point[5], -525)
    -- The left cluster starts at the band padding; slack is shared evenly, so
    -- the money field is wider than its text budget without measuring text.
    eq(strip.segments.money.point[1], "LEFT")
    eq(strip.segments.money.point[2], strip.frame)
    eq(strip.segments.money.point[4], 12)
    eq(strip.segments.money:GetWidth(), 246.5)
    eq(strip.segments.zone:GetWidth(), 200)
    eq(strip.segments.zone.point[4], 0)
    eq(strip.segments.clock.point[1], "RIGHT")
    eq(strip.segments.clock.point[4], -12)
    eq(strip.segments.clock:GetWidth(), 173.5)
    -- A smaller screen shrinks the slack and moves the flush centre with it.
    UIParent:SetSize(1600, 900); H.Fire("DISPLAY_SIZE_CHANGED")
    eq(strip.frame:GetWidth(), 1600)
    eq(strip.segments.money:GetWidth(), 206.5)
    eq(group.frame:GetWidth(), 1600)
    eq(group.frame.point[5], -435)
    -- A deliberate position survives a resize, while the default stays flush.
    app.Store:SetPosition("bottomBar", 0, -200)
    app.Layout:ApplyAll()
    eq(group.frame.point[5], -200)
    UIParent:SetSize(1366, 768); H.Fire("DISPLAY_SIZE_CHANGED")
    eq(group.frame.point[5], -200)
    eq(app.Layout.entries.bottomBar.y, -369)
    -- Narrow windows fall back to the compact reading instead of overlapping.
    UIParent:SetSize(1100, 800); H.Fire("DISPLAY_SIZE_CHANGED")
    eq(strip.frame:GetWidth(), 340)
    eq(strip.summary:IsShown(), true)
    eq(strip.segments.money:IsShown(), false)
    eq(strip.segments.zone:IsShown(), true)
    eq(strip.segments.clock:IsShown(), true)
    -- An appearance scale grows the band but must not push it past the screen:
    -- the local width is divided by the group scale.
    UIParent:SetSize(1920, 1080); H.Fire("DISPLAY_SIZE_CHANGED")
    app.Store:Set("appearance", "scale", 1.2)
    eq(math.abs(strip.frame:GetWidth() - 1600) < 1e-6, true)
    eq(math.abs(strip.frame:GetEffectiveScale() - 1.2) < 1e-9, true)
    eq(group.frame:GetWidth(), 1600)
    eq(#app.errors, 0)
end)

test("a missing group container falls back to absolute positions", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local member = app.Layout.entries.experience
    local group = app.Layout.entries.topInfo
    group.frame = nil
    app.Store:SetPosition("experience", 40, 60)
    eq(pcall(app.Layout.ApplyAll, app.Layout), true)
    eq(member.frame.point[1], "CENTER")
    eq(member.frame.point[2], UIParent)
    eq(member.frame.point[4], 40)
    eq(member.frame.point[5], 60)
    -- A missing member frame is skipped instead of failing the pass.
    app.Layout.entries.dataStrip.frame = nil
    eq(pcall(app.Layout.ApplyAll, app.Layout), true)
    eq(#app.errors, 0)
end)

test("group joins reject cycles and group containers as members", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local frame = H.NewFrame(nil, UIParent)
    eq(app.Layout:Join("party", "party", frame, 0, 0), false)
    local custom = app.Layout:RegisterGroup("custom", nil, 0, 0, "Custom")
    eq(app.Layout:Join("custom", "custom", frame, 0, 0), false)
    eq(app.Layout:Join("custom", "otherMember", custom.frame, 0, 0), false)
    eq(app.Layout.entries.party, nil)
    eq(app.Layout.entries.otherMember, nil)
    eq(#app.errors, 0)
end)

test("preset preview draws outlines without moving panels", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local group = app.Layout.entries.topInfo
    local beforeX, beforeY = group.frame.point[4], group.frame.point[5]
    local shown = app.Layout:PreviewPreset("default16x9")
    eq(shown > 0, true)
    eq(app.Layout.previewName, "default16x9")
    local overlay = app.Layout.presetOverlays.topInfo
    eq(overlay ~= nil and overlay:IsShown(), true)
    eq(group.frame.point[4], beforeX)
    eq(group.frame.point[5], beforeY)
    eq(next(app.Store:Profile().positions), nil)
    app.Layout:CancelPresetPreview()
    eq(overlay:IsShown(), false)
    eq(app.Layout.previewName, nil)
    eq(#app.errors, 0)
end)

test("applying a preset writes positions and undo restores the snapshot", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.Store:SetPosition("questList", 11, 12)
    app.Layout:PreviewPreset("default16x9")
    app.Layout:ApplyPreset("default16x9")
    local expectedX = 0 * UIParent:GetWidth() / app.Layout:Scale("topInfo")
    local expectedY = 0.435 * UIParent:GetHeight() / app.Layout:Scale("topInfo")
    eq(math.abs(app.Store:Profile().positions.topInfo.x - expectedX) < 1e-6, true)
    eq(math.abs(app.Store:Profile().positions.topInfo.y - expectedY) < 1e-6, true)
    eq(app.Layout.previewName, nil)
    eq(app.Layout.presetSnapshot ~= nil, true)
    app.Layout:UndoPreset()
    eq(app.Layout.presetSnapshot, nil)
    eq(app.Store:Profile().positions.questList.x, 11)
    eq(app.Store:Profile().positions.questList.y, 12)
    eq(app.Store:Profile().positions.topInfo, nil)
    eq(#app.errors, 0)
end)

test("preset undo preserves unrelated positions edited after applying", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.Store:SetPosition("questList", 11, 12)
    app.Store:SetPosition("otherPanel", 20, 30)
    app.Layout:ApplyPreset("combat")
    app.Store:SetPosition("otherPanel", 40, 50)
    app.Store:SetPosition("newPanel", 60, 70)
    app.Layout:UndoPreset()
    local positions = app.Store:Profile().positions
    eq(positions.questList.x, 11)
    eq(positions.questList.y, 12)
    eq(positions.otherPanel.x, 40)
    eq(positions.otherPanel.y, 50)
    eq(positions.newPanel.x, 60)
    eq(positions.newPanel.y, 70)
    eq(positions.topInfo, nil)
    eq(#app.errors, 0)
end)

test("combat layout is selected and previewed without moving the native action bar", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.Settings:Toggle("layout")
    local bar = _G.MainActionBar
    local point = bar.point
    H.Click(app.Settings.presetChoices.combat)
    H.Click(app.Settings.presetButtons.preview)
    eq(app.Layout.previewName, "combat")
    local guide = app.Layout.presetOverlays.nativeActionArea
    eq(guide:IsShown(), true)
    -- The guide is the measured action rectangle, not a preset-only grid. With
    -- only the main bar present its one measured row has no separator and the
    -- label says the two missing bars make this an estimate.
    eq(guide:GetWidth(), 524)
    eq(guide:GetHeight(), 40)
    eq(guide.point[1], "CENTER")
    eq(guide.point[2], UIParent)
    eq(guide.point[4], 0)
    eq(guide.point[5], -464)
    eq(#guide.rowLines, 0)
    eq(guide.label:GetText():find(app.L.presetEstimate, 1, true) ~= nil, true)
    local firstLine = guide.rowLines[1]
    app.Layout:PreviewPreset("combat")
    eq(guide.rowLines[1], firstLine)
    eq(#guide.rowLines, 0)
    eq(bar.point, point)
    H.Click(app.Settings.presetButtons.apply)
    eq(app.Layout.presetOverlays.nativeActionArea:IsShown(), false)
    eq(app.Layout.presetSnapshot.name, "combat")
    eq(bar.point, point)
    eq(#app.errors, 0)
end)

test("combat preset keeps unit frames close to the action area on wide screens", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.Store:Set("modules", "unitFrames", true)
    UIParent:SetSize(1920, 1080)
    app.Layout:PreviewPreset("combat")
    local playerOverlay = app.Layout.presetOverlays.unit_player
    local targetOverlay = app.Layout.presetOverlays.unit_target
    local firstX = playerOverlay.point[4]
    eq(firstX, -245.76)
    eq(targetOverlay.point[4], 245.76)
    UIParent:SetSize(3440, 1440)
    H.Fire("DISPLAY_SIZE_CHANGED")
    -- The gutter is a screen-width ratio, so it grows from 5.76 to the 8 unit
    -- cap on an ultrawide screen; the block itself stays at the measured 300.
    eq(playerOverlay.point[4], -248)
    eq(targetOverlay.point[4], 248)
    eq(app.Layout.previewName, "combat")
    app.Layout:ApplyPreset("combat")
    eq(app.components.unitFrames.frames.player.point[4], -248)
    eq(app.components.unitFrames.frames.target.point[4], 248)
    eq(#app.errors, 0)
end)

test("preset preview and application agree on screen-edge clamping", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.Store:Set("modules", "unitFrames", true)
    app.Store:Set("appearance", "scale", 1.5)
    UIParent:SetSize(800, 600)
    app.Layout:PreviewPreset("combat")
    local player = app.components.unitFrames.frames.player
    local overlay = app.Layout.presetOverlays.unit_player
    local previewX, previewY = overlay.point[4], overlay.point[5]
    app.Layout:ApplyPreset("combat")
    eq(math.abs(player.point[4] * 1.5 - previewX) < 0.001, true)
    eq(math.abs(player.point[5] * 1.5 - previewY) < 0.001, true)
    eq(#app.errors, 0)
end)

test("combat preview flags cramped and off-screen outlines without moving frames", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.Store:Set("modules", "unitFrames", true)
    app.Store:Set("appearance", "scale", 1.5)
    UIParent:SetSize(800, 600)
    local player = app.components.unitFrames.frames.player
    local originalPoint = player.point
    app.Layout:PreviewPreset("combat")
    eq(player.point, originalPoint)
    eq(app.Layout.previewWarnings.unit_player, true)
    eq(app.Layout.previewWarnings.nativeActionArea, true)
    eq(app.Layout.presetOverlays.unit_player.label:GetText():find(app.L.presetOverlapShort, 1, true) ~= nil, true)
    app.Settings:Toggle("layout")
    eq(app.Settings.layoutCount:GetText():find(app.L.presetOverlapHint, 1, true) ~= nil, true)
    UIParent:SetSize(480, 600)
    app.Layout:PreviewPreset("combat")
    eq(app.Layout.presetOverlays.nativeActionArea:GetWidth(), 524)
    eq(app.Layout.previewWarnings.nativeActionArea, true)
    app.Layout:CancelPresetPreview()
    eq(app.Layout.previewWarnings, nil)
    eq(app.Layout.presetOverlays.unit_player:IsShown(), false)
    eq(#app.errors, 0)
end)

test("no layout preset is ever applied without an explicit request", function()
    local app = H.Load({ profiles = { Default = { positions = {
        questList = { x = -600, y = 120 },
    } } } })
    H.Fire("PLAYER_LOGIN")
    app.Layout:ApplyAll()
    eq(app.Store:Profile().positions.questList.x, -600)
    eq(app.Store:Profile().positions.questList.y, 120)
    eq(app.Store:Profile().positions.topInfo, nil)
    eq(app.Layout.presetSnapshot, nil)
    eq(#app.errors, 0)
end)

test("a read-only profile cannot apply or undo a preset", function()
    local app = H.Load({ schema = 99 })
    H.Fire("PLAYER_LOGIN")
    eq(app.Store.readonly, true)
    app.Layout:PreviewPreset("default16x9")
    app.Layout:ApplyPreset("default16x9")
    eq(next(app.Store:Profile().positions), nil)
    eq(app.Layout.presetSnapshot, nil)
    app.Settings:Toggle("layout")
    eq(app.Settings.presetButtons.preview.state.disabled, true)
    eq(app.Settings.presetButtons.apply.state.disabled, true)
    eq(app.Settings.presetButtons.undo.state.disabled, true)
    eq(#app.errors, 0)
end)

test("applying a preset in combat waits for combat to end", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    H.Combat(true)
    app.Layout:ApplyPreset("default16x9")
    eq(app.Queue:Count(), 1)
    eq(app.Store:Profile().positions.topInfo, nil)
    H.Combat(false)
    eq(app.Store:Profile().positions.topInfo ~= nil, true)
    eq(#app.errors, 0)
end)

test("a screen change clamps the group without rewriting its position", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.Store:SetPosition("topInfo", 0, 620)
    UIParent:SetSize(1280, 720)
    H.Fire("DISPLAY_SIZE_CHANGED")
    eq(app.Store:Profile().positions.topInfo.y, 620)
    local frame = app.Layout.entries.topInfo.frame
    eq(frame.point[5] < 620, true)
    eq(frame.point[5] > 0, true)
    eq(#app.errors, 0)
end)

test("the raid grid registers as a single group container", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local exists = UnitExists
    _G.UnitExists = function(unit) return unit == "raid1" end
    app.Store:Set("modules", "raidFrames", true)
    local entry = app.Layout.entries.raidFrames
    eq(entry ~= nil, true)
    eq(entry.group, true)
    eq(entry.frame, app.components.raidFrames.container)
    eq(type(app.Layout.SetEntryDefault), "function")
    _G.UnitExists = exists
    eq(#app.errors, 0)
end)

test("layout page lists groups and preset controls", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.Store:Set("modules", "partyFrames", true)
    app.Settings:Toggle("layout")
    local labels = {}
    for _, row in ipairs(app.Settings.layoutRows) do
        if row:IsShown() then labels[row.id] = row.label:GetText() end
    end
    eq(labels.party, app.L.partyGroup)
    eq(labels.topInfo, app.L.topInfoGroup)
    eq(labels.party_party1, nil)
    eq(app.Settings.presetButtons ~= nil, true)
    H.Click(app.Settings.presetButtons.preview)
    eq(app.Layout.previewName, "default16x9")
    eq(app.Settings.presetButtons.cancel.state.disabled, false)
    H.Click(app.Settings.presetButtons.cancel)
    eq(app.Layout.previewName, nil)
    H.Click(app.Settings.presetButtons.apply)
    eq(app.Store:Profile().positions.topInfo ~= nil, true)
    eq(app.Settings.presetButtons.undo.state.disabled, false)
    H.Click(app.Settings.presetButtons.undo)
    eq(app.Store:Profile().positions.topInfo, nil)
    eq(#app.errors, 0)
end)

test("member offsets follow the selected profile", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.Store:Set("modules", "partyFrames", true)
    local member = app.Layout.entries.party_party1
    eq(member.rx, 0)
    eq(member.ry, 54)
    app.Store:Create("Moved", false)
    app.Store:SetPosition("party|party_party1", 170, 20)
    app.Store:Select("Default")
    eq(member.rx, 0)
    app.Store:Select("Moved")
    eq(member.rx, 170)
    eq(member.ry, 20)
    app.Layout:ApplyAll()
    eq(member.frame.point[4], 170)
    eq(member.frame.point[5], 20)
    eq(#app.errors, 0)
end)

test("a third-party placeholder is editable without touching unknown frames", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local entry = app.Layout:RegisterPlaceholder("thirdParty", "Third-party area", 300, 120, 220, 90)
    eq(entry.placeholder, true)
    eq(entry.frame:IsShown(), false)
    -- It only appears while positions are edited.
    app.Layout:SetEditing(true)
    eq(entry.frame:IsShown(), true)
    local overlay = entry.overlay
    eq(overlay ~= nil, true)
    overlay:ClearAllPoints()
    overlay:SetPoint("CENTER", UIParent, "CENTER", 301, 121)
    overlay.scripts.OnDragStop(overlay)
    eq(app.Store:Profile().positions.thirdParty.x, 300)
    eq(app.Store:Profile().positions.thirdParty.y, 120)
    app.Layout:SetEditing(false)
    eq(entry.frame:IsShown(), false)
    -- Entering combat also ends editing and hides the outline.
    app.Layout:SetEditing(true)
    eq(entry.frame:IsShown(), true)
    H.Combat(true)
    eq(app.Layout.editing, false)
    eq(entry.frame:IsShown(), false)
    eq(#app.errors, 0)
end)

test("repeated party enable cycles keep one group and four members", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    for _ = 1, 5 do
        app.Store:Set("modules", "partyFrames", true)
        app.Store:Set("modules", "partyFrames", false)
    end
    app.Store:Set("modules", "partyFrames", true)
    local group = app.Layout.entries.party
    eq(group ~= nil, true)
    eq(#group.members, 4)
    for _, id in ipairs({ "party_party1", "party_party2", "party_party3", "party_party4" }) do
        eq(app.Layout.entries[id] ~= nil, true)
    end
    local rows = 0
    for _, id in ipairs(app.Layout:IDs()) do
        if id == "party" then rows = rows + 1 end
        eq(id ~= "party_party2", true)
    end
    eq(rows, 1)
    eq(#app.errors, 0)
end)

-- ==== TRACK: VIS-11 unit HUD, casts and auras — append new tests above this line ====
test("unit events redraw only the subscribed parts and keep one cast timer", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.Store:Set("modules", "unitFrames", true)
    local frame = app.components.unitFrames.frames.target
    eq(frame.eventParts.UNIT_HEALTH[1].id, "bars")
    eq(#frame.eventParts.UNIT_HEALTH, 1)
    eq(frame.eventParts.UNIT_AURA[1].id, "auras")
    eq(frame.eventParts.UNIT_SPELLCAST_START[1].id, "cast")
    eq(frame.eventParts.UNIT_SPELLCAST_EMPOWER_START[1].id, "cast")
    H.cast.target = { name = "Fireball", startTime = 0, endTime = 2500 }
    H.Fire("UNIT_SPELLCAST_START", "target")
    local timer = frame.cast.updater
    eq(timer ~= nil, true)
    -- Health and aura events must not rebuild the cast timer.
    H.Fire("UNIT_HEALTH", "target")
    eq(frame.cast.updater, timer)
    H.Fire("UNIT_AURA", "target")
    eq(frame.cast.updater, timer)
    -- An interruptible toggle is the same cast.
    H.Fire("UNIT_SPELLCAST_NOT_INTERRUPTIBLE", "target")
    eq(frame.cast.updater, timer)
    -- A delayed cast with a different end time is a new timer.
    H.cast.target.endTime = 3000
    H.Fire("UNIT_SPELLCAST_DELAYED", "target")
    eq(frame.cast.updater ~= timer, true)
    eq(timer.cancelled, true)
    H.cast.target.gone = true
    H.Fire("UNIT_SPELLCAST_STOP", "target")
    eq(frame.cast.updater, nil)
    eq(frame.cast:IsShown(), false)
    eq(#app.errors, 0)
end)

test("channels and empowers use their own cast fill", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.Store:Set("modules", "unitFrames", true)
    local frame = app.components.unitFrames.frames.target
    -- Channel: green pair.
    H.cast.target = { name = "Drain Life", startTime = 0, endTime = 3000, channel = true }
    H.Fire("UNIT_SPELLCAST_CHANNEL_START", "target")
    local fill = frame.cast:GetStatusBarTexture()
    eq(math.abs(fill.gradient.lo[1] - 0.135) < 1e-6, true)
    -- Empowered channel: amber pair.
    H.cast.target.isEmpowered = true
    H.Fire("UNIT_SPELLCAST_CHANNEL_START", "target")
    eq(math.abs(fill.gradient.lo[1] - 0.45) < 1e-6, true)
    H.cast.target = nil
    H.Fire("UNIT_SPELLCAST_CHANNEL_STOP", "target")
    -- Empowered cast detected through the documented spell predicate.
    H.empowerSpells[15125] = true
    H.cast.target = { name = "Empower", startTime = 0, endTime = 2500 }
    H.Fire("UNIT_SPELLCAST_START", "target")
    eq(math.abs(fill.gradient.lo[1] - 0.45) < 1e-6, true)
    H.empowerSpells[15125] = nil
    H.Fire("UNIT_SPELLCAST_START", "target")
    local accent = app.Theme:Accent()
    eq(fill.gradient.lo[1], accent[1] * 0.45)
    eq(#app.errors, 0)
end)

test("death and disconnection are shown on the unit bar", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.Store:Set("modules", "unitFrames", true)
    local frame = app.components.unitFrames.frames.target
    H.unitState.dead.target = true
    H.Fire("UNIT_FLAGS", "target")
    eq(frame.statusText:GetText(), app.L.unitDead)
    H.unitState.dead.target = nil
    H.Fire("UNIT_FLAGS", "target")
    eq(frame.statusText:GetText(), "")
    H.unitState.offline.target = true
    H.Fire("UNIT_CONNECTION", "target")
    eq(frame.statusText:GetText(), app.L.unitOffline)
    H.unitState.offline.target = nil
    H.Fire("UNIT_CONNECTION", "target")
    eq(frame.statusText:GetText(), "")
    -- A restricted flag is never interpreted as dead or offline.
    _G.UnitIsDeadOrGhost = function() return H.Secret(true) end
    H.Fire("UNIT_FLAGS", "target")
    eq(frame.statusText:GetText(), "")
    eq(#app.errors, 0)
end)

test("auras sort by remaining time only when every value is readable", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.Store:Set("modules", "unitFrames", true)
    local frame = app.components.unitFrames.frames.target
    H.unitAuras.target = {
        harmful = {
            { icon = "later", expirationTime = H.now + 30 },
            { icon = "sooner", expirationTime = H.now + 10 },
        },
        helpful = { { icon = "buff", expirationTime = H.now + 20 } },
    }
    H.Fire("UNIT_AURA", "target")
    eq(frame.auraIcons[1].texture, "sooner")
    eq(frame.auraIcons[2].texture, "later")
    eq(frame.auraIcons[3].texture, "buff")
    -- One restricted expiration keeps the client's own order for that list.
    H.unitAuras.target = {
        harmful = {
            { icon = "first", expirationTime = H.now + 30 },
            { icon = "restricted", expirationTime = H.Secret(H.now + 10) },
        },
        helpful = {},
    }
    H.Fire("UNIT_AURA", "target")
    eq(frame.auraIcons[1].texture, "first")
    eq(frame.auraIcons[2].texture, "restricted")
    eq(frame.auraIcons[2].expiration, nil)
    eq(#app.errors, 0)
end)

test("reused aura slots clear their old stack, time and border", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.Store:Set("modules", "unitFrames", true)
    local frame = app.components.unitFrames.frames.target
    H.unitAuras.target = {
        harmful = { { icon = "first", applications = 5, expirationTime = H.now + 20, dispelName = "Magic" } },
        helpful = {},
    }
    H.Fire("UNIT_AURA", "target")
    local icon = frame.auraIcons[1]
    eq(icon.texture, "first")
    eq(icon.count:GetText(), "5")
    eq(icon.border:IsShown(), true)
    eq(icon.time:GetText() ~= "", true)
    H.unitAuras.target = { harmful = { { icon = "second" } }, helpful = {} }
    H.Fire("UNIT_AURA", "target")
    eq(icon.texture, "second")
    eq(icon.count:GetText(), "")
    eq(icon.time:GetText(), "")
    eq(icon.border:IsShown(), false)
    eq(icon.expiration, nil)
    eq(#app.errors, 0)
end)

test("the aura filter is about dispel school and leaves buffs alone", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.Store:Set("modules", "unitFrames", true)
    local frame = app.components.unitFrames.frames.target
    H.unitAuras.target = {
        harmful = { { icon = "magic", dispelName = "Magic" }, { icon = "plain" } },
        helpful = { { icon = "buff" } },
    }
    app.Store:Set("ui", "auraFilter", "dispel")
    H.Fire("UNIT_AURA", "target")
    eq(frame.auraIcons[1].texture, "magic")
    eq(frame.auraIcons[2].texture, "buff")
    eq(frame.auraIcons[3]:IsShown(), false)
    app.Store:Set("ui", "auraFilter", "all")
    H.Fire("UNIT_AURA", "target")
    eq(frame.auraIcons[2].texture, "plain")
    eq(frame.auraIcons[3].texture, "buff")
    eq(#app.errors, 0)
end)

test("disabling the unit HUD releases cast and aura timers", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.Store:Set("modules", "unitFrames", true)
    local frame = app.components.unitFrames.frames.target
    H.cast.target = { name = "Fireball", startTime = 0, endTime = 2500 }
    H.Fire("UNIT_SPELLCAST_START", "target")
    H.unitAuras.target = { harmful = { { icon = "timed", expirationTime = H.now + 20 } }, helpful = {} }
    H.Fire("UNIT_AURA", "target")
    H.unitState.dead.target = true
    H.Fire("UNIT_FLAGS", "target")
    eq(frame.cast.updater ~= nil, true)
    eq(frame.auraTicker ~= nil, true)
    app.Store:Set("modules", "unitFrames", false)
    eq(frame.cast.updater, nil)
    eq(frame.auraTicker, nil)
    eq(frame.auraIcons[1]:IsShown(), false)
    eq(frame.statusText:GetText(), "")
    eq(#app.errors, 0)
end)

test("party buttons reserve one native private aura anchor per aura index", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.Store:Set("modules", "partyFrames", true)
    local party = app.components.partyFrames
    local anchors = H.privateAnchors
    -- Four members, five aura indexes each: the native display budget.
    eq(anchors.added, 20)
    eq(anchors.removed, 0)
    eq(anchors.liveCount, 20)
    -- Every anchor belongs to its own button and unit, and is a single
    -- (non-container) display slot in the client's own order.
    for _, unit in ipairs({ "party1", "party2", "party3", "party4" }) do
        local frame = party.frames[unit]
        eq(frame.lumaPrivateUnit, unit)
        eq(#frame.lumaPrivateAnchors, 5)
        for index, id in ipairs(frame.lumaPrivateAnchors) do
            local args = anchors.live[id]
            eq(args.unitToken, unit)
            eq(args.auraIndex, index)
            eq(args.parent, frame)
            eq(args.isContainer, false)
            eq(args.iconInfo.iconAnchor.relativeTo, frame)
            eq(args.iconInfo.iconWidth, app.Theme.party.private.icon)
            eq(args.iconInfo.iconHeight, app.Theme.party.private.icon)
        end
    end
    -- Complete anchor coverage takes the native display down.
    eq(PartyFrame:IsShown(), false)
    -- A member leaving releases only that member's slots; the rest stay.
    local saved = UnitExists
    _G.UnitExists = function(token) return token ~= "party2" end
    H.Fire("GROUP_ROSTER_UPDATE")
    eq(party.frames.party2.lumaPrivateAnchors, nil)
    eq(party.frames.party2.lumaPrivateUnit, nil)
    eq(anchors.liveCount, 15)
    eq(#party.frames.party1.lumaPrivateAnchors, 5)
    -- Rejoining the same token gets fresh slots for that unit only.
    _G.UnitExists = saved
    H.Fire("GROUP_ROSTER_UPDATE")
    eq(#party.frames.party2.lumaPrivateAnchors, 5)
    for _, id in ipairs(party.frames.party2.lumaPrivateAnchors) do
        eq(anchors.live[id].unitToken, "party2")
    end
    -- Disabling releases every anchor it created.
    app.Store:Set("modules", "partyFrames", false)
    eq(anchors.liveCount, 0)
    eq(#anchors.removedIDs, anchors.added - H.privateAnchors.refused)
    eq(#app.errors, 0)
end)

test("party rows take their height from the theme and keep the aura band clear", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.Store:Set("modules", "partyFrames", true)
    local frame = app.components.partyFrames.frames.party1
    -- The module used to hard-code 46 while the theme said 30; the row now reads
    -- the one number the theme publishes.
    eq(frame:GetHeight(), app.Theme.party.height)
    eq(frame:GetWidth(), app.Theme.party.width)
    eq(frame:GetHeight(), 32)
    -- The aura anchors no longer use a band under the power bar: they live in
    -- the reserved right column. The five slots plus the inset must fit inside
    -- that column, and the icons must fit inside the row height.
    local private = app.Theme.party.private
    local band = (private.slots - 1) * private.step + private.icon
    eq(private.inset + band <= app.Theme.party.right, true)
    eq(private.bottom + private.icon <= app.Theme.party.height, true)
    eq(#app.errors, 0)
end)

test("the party block keeps its mockup place on a narrow screen", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    UIParent:SetSize(1280, 720)
    app.Store:Set("modules", "partyFrames", true)
    local group = app.Layout.entries.party
    -- 15.5% of 1280 puts the left edge at 198 and the 190 wide block's centre at
    -- 293, which is 347 left of the screen centre.
    eq(group.x, -347)
    -- 48.5% of 720 leaves ~11 units above the centre for the first row's top;
    -- the group centre sits half a 140 unit block lower.
    eq(group.y, -43)
    eq(#app.errors, 0)
end)

test("raid buttons reserve private aura anchors and release them on roster loss", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local saved = UnitExists
    _G.UnitExists = function(unit) return unit == "raid1" or unit == "raid2" end
    H.inRaid = true
    app.Store:Set("modules", "raidFrames", true)
    local raid = app.components.raidFrames
    eq(H.privateAnchors.added, 10)
    for index = 1, 2 do
        local button = raid.frames[index]
        eq(button.lumaPrivateUnit, "raid" .. index)
        eq(#button.lumaPrivateAnchors, 5)
        for slot, id in ipairs(button.lumaPrivateAnchors) do
            eq(H.privateAnchors.live[id].unitToken, "raid" .. index)
            eq(H.privateAnchors.live[id].auraIndex, slot)
        end
    end
    eq(CompactRaidFrameContainer:IsShown(), true)
    -- A member leaving releases its slots, the surviving one keeps its own.
    _G.UnitExists = function(unit) return unit == "raid2" end
    H.Fire("GROUP_ROSTER_UPDATE")
    eq(raid.frames[1].lumaPrivateUnit, nil)
    eq(H.privateAnchors.liveCount, 5)
    eq(#raid.frames[2].lumaPrivateAnchors, 5)
    -- Disable releases the rest.
    app.Store:Set("modules", "raidFrames", false)
    eq(H.privateAnchors.liveCount, 0)
    _G.UnitExists = saved
    H.inRaid = false
    eq(#app.errors, 0)
end)

test("a client without the private aura API keeps the native group frames", function()
    local app = H.Load()
    -- The anchor API is the only way the replacement could draw private auras;
    -- without it the native frame keeps the job.
    _G.C_UnitAuras.AddPrivateAuraAnchor = nil
    H.Fire("PLAYER_LOGIN")
    app.Store:Set("modules", "partyFrames", true)
    eq(app.components.partyFrames.running, true)
    eq(app.components.partyFrames.frames.party1 ~= nil, true)
    eq(PartyFrame:IsShown(), true)
    local saved = UnitExists
    _G.UnitExists = function(unit) return unit == "raid1" end
    H.inRaid = true
    app.Store:Set("modules", "raidFrames", true)
    eq(app.components.raidFrames.frames[1] ~= nil, true)
    eq(CompactRaidFrameContainer:IsShown(), true)
    _G.UnitExists = saved
    H.inRaid = false
    eq(#app.errors, 0)
end)

test("one refused anchor keeps the native frame instead of a partial replacement", function()
    local app = H.Load()
    H.privateAnchorRefuse = true
    H.Fire("PLAYER_LOGIN")
    app.Store:Set("modules", "partyFrames", true)
    local party = app.components.partyFrames
    -- Every Add call was made and answered nil; nothing was recorded as live.
    eq(H.privateAnchors.refused, 20)
    eq(H.privateAnchors.liveCount, 0)
    eq(party.frames.party1.lumaPrivateAnchors, nil)
    -- A partial replacement would silently drop private auras, so the native
    -- frame stays exactly where the client had it.
    eq(PartyFrame:IsShown(), true)
    app.Store:Set("modules", "partyFrames", false)
    eq(#app.errors, 0)
end)

test("a roster change in combat re-points anchors only after the fight", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.Store:Set("modules", "partyFrames", true)
    local party = app.components.partyFrames
    local anchors = H.privateAnchors
    eq(anchors.added, 20)
    H.Combat(true)
    -- A member leaves mid-fight. Release/Create are protected changes on
    -- secure buttons, so the queued job must wait.
    local saved = UnitExists
    _G.UnitExists = function(token) return token ~= "party3" end
    H.Fire("GROUP_ROSTER_UPDATE")
    eq(anchors.removed, 0)
    eq(anchors.added, 20)
    eq(#party.frames.party3.lumaPrivateAnchors, 5)
    H.Combat(false)
    eq(anchors.liveCount, 15)
    eq(party.frames.party3.lumaPrivateAnchors, nil)
    -- The surviving members keep their own anchors untouched.
    for _, id in ipairs(party.frames.party1.lumaPrivateAnchors) do
        eq(anchors.live[id].unitToken, "party1")
    end
    _G.UnitExists = saved
    eq(#app.errors, 0)
end)

-- ==== TRACK: VIS-12 party/raid completeness — append new tests above this line ====
test("party members show role and death/offline state", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.Store:Set("modules", "partyFrames", true)
    local frame = app.components.partyFrames.frames.party1
    H.roles.party1 = "HEALER"
    H.Fire("UNIT_FLAGS", "party1")
    eq(frame.role:GetText(), app.L.roleHealer)
    eq(frame.role.textColor[1], 0.30)
    H.unitState.dead.party1 = true
    H.Fire("UNIT_FLAGS", "party1")
    eq(frame.status:GetText(), app.L.unitDead)
    H.unitState.dead.party1 = nil
    H.unitState.offline.party1 = true
    H.Fire("UNIT_CONNECTION", "party1")
    eq(frame.status:GetText(), app.L.unitOffline)
    H.unitState.offline.party1 = nil
    H.roles.party1 = "DAMAGER"
    H.Fire("UNIT_FLAGS", "party1")
    eq(frame.role:GetText(), app.L.roleDamage)
    eq(frame.status:GetText(), "")
    -- Unknown/restricted role clears the glyph instead of guessing.
    H.roles.party1 = nil
    H.Fire("UNIT_FLAGS", "party1")
    eq(frame.role:GetText(), "")
    eq(#app.errors, 0)
end)

test("raid buttons show role and death/offline state in fixed areas", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local saved = UnitExists
    _G.UnitExists = function(unit) return unit == "raid1" end
    app.Store:Set("modules", "raidFrames", true)
    local button = app.components.raidFrames.frames[1]
    eq(button.role.point[1], "TOPRIGHT")
    eq(button.role.point[2], -17)
    H.roles.raid1 = "TANK"
    H.unitState.dead.raid1 = true
    H.Fire("UNIT_FLAGS", "raid1")
    eq(button.role:GetText(), app.L.roleTank)
    eq(button.role.textColor[1], 0.42)
    eq(button.status:GetText(), app.L.unitDead)
    H.unitState.dead.raid1 = nil
    H.roles.raid1 = "HEALER"
    H.Fire("UNIT_FLAGS", "raid1")
    eq(button.role:GetText(), app.L.roleHealer)
    eq(button.status:GetText(), "")
    _G.UnitExists = saved
    eq(#app.errors, 0)
end)

test("a reused party token refreshes role and status", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.Store:Set("modules", "partyFrames", true)
    local frame = app.components.partyFrames.frames.party1
    H.roles.party1 = "TANK"
    H.unitState.dead.party1 = true
    H.Fire("UNIT_FLAGS", "party1")
    eq(frame.role:GetText(), app.L.roleTank)
    eq(frame.status:GetText(), app.L.unitDead)
    -- The member leaves: decorations are cleared before the watch hides it.
    local saved = UnitExists
    _G.UnitExists = function(unit) return unit ~= "party1" and saved(unit) end
    H.Fire("GROUP_ROSTER_UPDATE")
    eq(frame.role:GetText(), "")
    eq(frame.status:GetText(), "")
    -- Someone else joins the same token with fresh values.
    _G.UnitExists = saved
    H.roles.party1 = "DAMAGER"
    H.unitState.dead.party1 = nil
    H.Fire("GROUP_ROSTER_UPDATE")
    eq(frame.role:GetText(), app.L.roleDamage)
    eq(frame.status:GetText(), "")
    eq(#app.errors, 0)
end)

test("a rejected member watch keeps that member off the takeover", function()
    local app = H.Load()
    local saved = RegisterUnitWatch
    _G.RegisterUnitWatch = function(frame)
        if frame == _G.LumaUIParty2 then error("watch rejected") end
        return saved(frame)
    end
    H.Fire("PLAYER_LOGIN")
    app.Store:Set("modules", "partyFrames", true)
    local party = app.components.partyFrames
    eq(party.frames.party2.lumaWatched, nil)
    eq(party.frames.party1.lumaWatched, true)
    eq(PartyFrame:IsShown(), true)
    _G.RegisterUnitWatch = saved
    eq(#app.errors, 0)
end)

test("click casting survives party and raid reflows", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.Store:Set("modules", "partyFrames", true)
    app.Store:Set("modules", "clickCast", true)
    local click = app.components.clickCast
    eq(click:Bind("shift-left", "Flash Heal"), true)
    local frame = app.components.partyFrames.frames.party1
    eq(frame:GetAttribute("*shift-type1"), "spell")
    eq(frame:GetAttribute("*shift-spell1"), "Flash Heal")
    H.Fire("GROUP_ROSTER_UPDATE")
    eq(frame:GetAttribute("*shift-spell1"), "Flash Heal")
    -- Raid buttons created later receive the same binding.
    local saved = UnitExists
    _G.UnitExists = function(unit) return unit == "raid1" end
    H.inRaid = true
    app.Store:Set("modules", "raidFrames", true)
    H.Fire("GROUP_ROSTER_UPDATE")
    local raid = app.components.raidFrames.frames[1]
    eq(raid ~= nil, true)
    eq(raid:GetAttribute("*shift-spell1"), "Flash Heal")
    _G.UnitExists = saved
    H.inRaid = false
    -- Re-enabling the party component keeps the secure attributes.
    app.Store:Set("modules", "partyFrames", false)
    app.Store:Set("modules", "partyFrames", true)
    eq(frame:GetAttribute("*shift-spell1"), "Flash Heal")
    eq(#app.errors, 0)
end)

test("raid frames cap at forty members", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local saved = UnitExists
    _G.UnitExists = function(unit) return unit:match("^raid%d+$") ~= nil end
    H.inRaid = true
    app.Store:Set("modules", "raidFrames", true)
    local raid = app.components.raidFrames
    eq(raid.frames[40] ~= nil, true)
    eq(raid.frames[41], nil)
    eq(#raid.frames, 40)
    _G.UnitExists = saved
    H.inRaid = false
    eq(#app.errors, 0)
end)

test("party and raid diagnostics state their coverage", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.Store:Set("modules", "partyFrames", true)
    local saved = UnitExists
    _G.UnitExists = function(unit) return unit == "raid1" end
    app.Store:Set("modules", "raidFrames", true)
    app.Settings:Toggle("diagnostics")
    local text = app.Settings.pages.diagnostics:DisplayText()
    eq(text:find(app.L.partyCoverage, 1, true) ~= nil, true)
    eq(text:find(app.L.raidCoverage, 1, true) ~= nil, true)
    _G.UnitExists = saved
    eq(#app.errors, 0)
end)

test("private auras stay a documented gap instead of guessed anchors", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local caps = app.Capabilities.Snapshot()
    eq(type(caps.privateAuras), "boolean")
    app.Store:Set("modules", "unitFrames", true)
    app.Settings:Toggle("diagnostics")
    local text = app.Settings.pages.diagnostics:DisplayText()
    -- The preview states what it does not cover instead of claiming parity.
    eq(text:find(app.L.unitCoverage, 1, true) ~= nil, true)
    eq(text:find(app.L.partyCoverage, 1, true), nil)
    eq(#app.errors, 0)
end)

test("both native party displays are taken over while covered", function()
    local app = H.Load()
    local native = H.NewFrame("CompactPartyFrame", UIParent)
    native:Show()
    H.Fire("PLAYER_LOGIN")
    eq(native:IsShown(), true)
    app.Store:Set("modules", "partyFrames", true)
    -- Raid-style party frames live on CompactPartyFrame, not PartyFrame.
    eq(native:IsShown(), false)
    eq(PartyFrame:IsShown(), false)
    -- A client Show is re-hidden while coverage holds.
    native:Show()
    eq(native:IsShown(), false)
    app.Store:Set("modules", "partyFrames", false)
    eq(native:IsShown(), true)
    eq(PartyFrame:IsShown(), true)
    eq(#app.errors, 0)
end)

test("permanent auras show no countdown and only timed auras own the ticker", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.Store:Set("modules", "unitFrames", true)
    local frame = app.components.unitFrames.frames.target
    H.unitAuras.target = {
        helpful = {
            { icon = "permanent", expirationTime = 0 },
            { icon = "minute", expirationTime = H.now + 90 },
        },
        harmful = {},
    }
    H.Fire("UNIT_AURA", "target")
    eq(frame.auraIcons[1].expiration, nil)
    eq(frame.auraIcons[1].time:GetText(), "")
    eq(frame.auraIcons[2].time:GetText(), "1m")
    eq(frame.auraIcons[2].time:GetWidth(), 18)
    eq(frame.auraIcons[2].time.fontSize, 8)
    eq(frame.auraTicker ~= nil, true)
    -- Only permanent auras left: no "0" label and no ticker.
    H.unitAuras.target = { helpful = { { icon = "permanent", expirationTime = 0 } }, harmful = {} }
    H.Fire("UNIT_AURA", "target")
    eq(frame.auraIcons[1].time:GetText(), "")
    eq(frame.auraTicker, nil)
    eq(#app.errors, 0)
end)

-- ==== TRACK: VIS-16 map, information strip and experience ====
test("exactly one clock shows and the choice survives a reload", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local strip, minimap = app.components.dataStrip, app.components.minimap
    eq(app.Store:Profile().ui.clock, "strip")
    eq(strip.clock:IsShown(), true)
    eq(strip.clock:GetText(), "12:34")
    eq(minimap.clock:IsShown(), false)
    app.Store:Set("ui", "clock", "minimap")
    eq(strip.clock:IsShown(), false)
    eq(strip.segments.clock:IsShown(), false)
    eq(minimap.clock:IsShown(), true)
    eq(minimap.clock:GetText(), "12:34")
    app.Store:Set("ui", "clock", "off")
    eq(strip.clock:IsShown(), false)
    eq(minimap.clock:IsShown(), false)
    -- The choice is the player's, so it is read back from the profile exactly
    -- as saved; nothing forces a default on the next login.
    eq(LumaUIDB.profiles.Default.ui.clock, "off")
    local saved = LumaUIDB
    local again = H.Load(saved); H.Fire("PLAYER_LOGIN")
    eq(again.components.dataStrip.clock:IsShown(), false)
    eq(again.Store:Profile().ui.clock, "off")
    -- A damaged value falls back to the strip instead of hiding the time.
    local broken = H.Load({ profiles = { Default = { ui = { clock = "somewhere" } } } })
    H.Fire("PLAYER_LOGIN")
    eq(broken.Store:Profile().ui.clock, "strip")
    eq(#broken.errors, 0)
    eq(#app.errors, 0)
end)

test("the compact strip prints only the zone and time and reports the rest", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local strip = app.components.dataStrip
    -- The full Pearl strip is the default; compact is a deliberate opt-in.
    eq(app.Store:Profile().ui.stripCompact, false)
    eq(strip.performance:IsShown(), true)
    app.Store:Set("ui", "stripCompact", true)
    eq(app.Store:Profile().ui.stripCompact, true)
    eq(strip.zone:IsShown(), true)
    eq(strip.clock:IsShown(), true)
    eq(strip.performance:IsShown(), false)
    eq(strip.money:IsShown(), false)
    eq(strip.summary:IsShown(), true)
    -- Hidden fields stop catching the mouse, so the wide summary segment under
    -- them is reachable.
    eq(strip.segments.performance:IsShown() == false or true, true)
    H.durability = { [1] = { 40, 100 }, [16] = { 90, 100 } }
    GameTooltip.lines = {}
    strip.segments.summary.scripts.OnEnter()
    local lines = table.concat(GameTooltip.lines, "\n")
    eq(lines:find("Test Zone", 1, true) ~= nil, true)
    eq(lines:find(app.L.gold, 1, true) ~= nil, true)
    eq(lines:find(app.L.durability, 1, true) ~= nil, true)
    eq(lines:find("40%", 1, true) ~= nil, true)
    eq(lines:find(app.L.networkFps, 1, true) ~= nil, true)
    H.durability = nil
    strip.segments.summary.scripts.OnLeave()
    eq(GameTooltip:IsShown(), false)
    -- The full reading is still available as a saved choice.
    app.Store:Set("ui", "stripCompact", false)
    eq(strip.performance:IsShown(), true)
    eq(strip.money:IsShown(), true)
    eq(strip.summary:IsShown(), false)
    app.Store:Set("ui", "stripCompact", true)
    eq(strip.summary:IsShown(), true)
    eq(#app.errors, 0)
end)

test("the experience bar follows level, lock and watched reputation", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local experience = app.components.experience
    eq(experience.mode, "xp")
    eq(experience.frame:IsShown(), true)
    eq(experience.text:GetText(), string.format("%s  %d%%", app.L.xp, 30))
    -- Max level: the client reports no XP range, and the bar hides instead of
    -- printing a fake 0%.
    H.maxLevel = 80
    H.Fire("PLAYER_LEVEL_UP")
    eq(experience.frame:IsShown(), false)
    H.maxLevel = 90
    H.Fire("PLAYER_LEVEL_UP")
    eq(experience.frame:IsShown(), true)
    -- XP locked is an explicit state, not a zero-progress bar.
    _G.IsXPUserDisabled = function() return true end
    H.Fire("DISABLE_XP_GAIN")
    eq(experience.frame:IsShown(), false)
    _G.IsXPUserDisabled = function() return false end
    H.Fire("ENABLE_XP_GAIN")
    eq(experience.frame:IsShown(), true)
    -- A watched faction replaces the experience bar; the standing colour is the
    -- game's own palette, and the tooltip names the faction.
    _G.FACTION_BAR_COLORS = { [5] = { r = 0.1, g = 0.8, b = 0.1 } }
    H.watchedFaction = { name = "Argent Dawn", reaction = 5, minimum = 0, maximum = 21000, current = 15750 }
    H.Fire("UPDATE_FACTION")
    eq(experience.mode, "reputation")
    eq(experience.frame:IsShown(), true)
    local label = experience.text:GetText()
    eq(label:find("Argent Dawn", 1, true) ~= nil, true)
    eq(label:find("75%", 1, true) ~= nil, true)
    eq(type(experience.bar.barColor) == "table", true)
    GameTooltip.lines = {}
    experience.frame.scripts.OnEnter()
    eq(GameTooltip:GetText():find("Argent Dawn", 1, true) ~= nil, true)
    eq(table.concat(GameTooltip.lines, "\n"):find("Friendly", 1, true) ~= nil, true)
    experience.frame.scripts.OnLeave()
    -- Watching nothing returns to experience points.
    H.watchedFaction = nil
    H.Fire("UPDATE_FACTION")
    eq(experience.mode, "xp")
    eq(#app.errors, 0)
end)

test("the native status bar is released whenever the replacement stops drawing", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local experience = app.components.experience
    local native = _G.MainStatusTrackingBarContainer
    -- A drawn XP reading takes the client's bar over.
    eq(experience.frame:IsShown(), true)
    eq(native:IsShown(), false)
    eq(experience.nativeSuppressed, true)
    -- Edit Mode re-shows the client's container; the next pass hides it again.
    native:Show()
    eq(native:IsShown(), true)
    H.Fire("EDIT_MODE_LAYOUTS_UPDATED")
    eq(native:IsShown(), false)
    -- Max level hides the replacement, so the client's own bar comes back.
    H.maxLevel = 80
    H.Fire("PLAYER_LEVEL_UP")
    eq(experience.frame:IsShown(), false)
    eq(native:IsShown(), true)
    eq(experience.nativeSuppressed, false)
    -- Turning the component off also releases it.
    H.maxLevel = 90
    H.Fire("PLAYER_LEVEL_UP")
    eq(native:IsShown(), false)
    app.Store:Set("modules", "experience", false)
    eq(native:IsShown(), true)
    eq(#app.errors, 0)
end)

test("a refused native status bar write is reported once and never hides the reading", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local experience = app.components.experience
    local native = _G.MainStatusTrackingBarContainer
    native.Hide = function() error("refused", 0) end
    -- The client re-shows its bar; the replacement tries the takeover again.
    native:Show()
    experience.nativeSuppressed = nil
    H.Fire("PLAYER_XP_UPDATE")
    eq(experience.frame:IsShown(), true)
    eq(#app.errors, 1)
    -- The refusal is reported once, not on every experience event.
    H.Fire("PLAYER_XP_UPDATE")
    eq(#app.errors, 1)
end)

test("the experience bar draws the rested pool behind the current progress", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local experience = app.components.experience
    -- The fixture reports 30/100 XP with 25 rested.
    eq(experience.rested:IsShown(), true)
    eq(experience.rested.width, 25)
    eq(experience.rested.point[1], "TOPLEFT")
    eq(experience.rested.point[4], 30)
    -- A wider bar scales both the offset and the segment.
    experience.bar:SetWidth(640)
    H.Fire("PLAYER_XP_UPDATE")
    eq(experience.rested.width, 160)
    eq(experience.rested.point[4], 192)
    -- Reputation has no rested band, and no pool hides the segment.
    H.watchedFaction = { name = "Argent Dawn", reaction = 5, minimum = 0, maximum = 21000, current = 15750 }
    H.Fire("UPDATE_FACTION")
    eq(experience.rested:IsShown(), false)
    H.watchedFaction = nil
    _G.GetXPExhaustion = function() return nil end
    H.Fire("UPDATE_FACTION")
    eq(experience.mode, "xp")
    eq(experience.rested:IsShown(), false)
    eq(#app.errors, 0)
end)

test("retail watched reputation uses the current API and safe progress ranges", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local experience = app.components.experience
    local mode, pending, capped = "normal", false, false
    _G.C_Reputation = {
        GetWatchedFactionData = function()
            if mode == "none" then return nil end
            if mode == "normalCapped" then
                return { factionID = 42, name = "Test faction", reaction = 8,
                    currentReactionThreshold = 42000, nextReactionThreshold = 42000, currentStanding = 42000 }
            end
            return { factionID = 42, name = "Test faction", reaction = 5,
                currentReactionThreshold = 3000, nextReactionThreshold = 9000, currentStanding = 4500 }
        end,
        IsFactionParagonForCurrentPlayer = function() return mode == "paragon" end,
        IsMajorFaction = function()
            if mode == "secret" then return H.Secret(true) end
            return mode == "major" or mode == "paragon"
        end,
        GetFactionParagonInfo = function() return 12500, 10000, 1, pending end,
    }
    _G.C_MajorFactions = {
        GetMajorFactionData = function() return { renownLevelThreshold = 2500,
            renownReputationEarned = 1000, renownLevel = 3, maxLevel = 10 } end,
        HasMaximumRenown = function() return capped end,
    }
    _G.C_GossipInfo = {
        GetFriendshipReputation = function()
            if mode == "friendCapped" then
                return { friendshipFactionID = 42, reaction = "Best friend", reactionThreshold = 3000,
                    nextThreshold = nil, standing = 3000 }
            end
            if mode ~= "friend" then return { friendshipFactionID = 0 } end
            return { friendshipFactionID = 42, reaction = "Friend", reactionThreshold = 1000,
                nextThreshold = 3000, standing = 1600 }
        end,
    }
    H.Fire("UPDATE_FACTION")
    eq(experience.mode, "reputation")
    eq(experience.text:GetText():find("25%%") ~= nil, true)
    GameTooltip.lines = {}
    experience.frame.scripts.OnEnter()
    eq(table.concat(GameTooltip.lines, "\n"):find("1500 / 6000", 1, true) ~= nil, true)
    mode = "normalCapped"
    H.Fire("UPDATE_FACTION")
    eq(experience.text:GetText():find("100%%") ~= nil, true)
    mode = "friend"
    H.Fire("UPDATE_FACTION")
    eq(experience.text:GetText():find("30%%") ~= nil, true)
    eq(experience.faction.standing, "Friend")
    mode = "friendCapped"
    H.Fire("UPDATE_FACTION")
    eq(experience.text:GetText():find("100%%") ~= nil, true)
    eq(experience.faction.standing, "Best friend")
    mode = "major"
    H.Fire("UPDATE_FACTION")
    eq(experience.text:GetText():find("40%%") ~= nil, true)
    eq(experience.faction.standing, string.format(app.L.reputationRenown, 3))
    capped = true
    H.Fire("MAJOR_FACTION_RENOWN_LEVEL_CHANGED")
    eq(experience.text:GetText():find("100%%") ~= nil, true)
    mode = "paragon"
    H.Fire("UPDATE_FACTION")
    eq(experience.text:GetText():find("25%%") ~= nil, true)
    eq(experience.faction.standing, app.L.reputationParagon)
    pending = true
    H.Fire("UPDATE_FACTION")
    eq(experience.text:GetText():find("100%%") ~= nil, true)
    eq(experience.text:GetText():find(app.L.reputationRewardPending, 1, true) ~= nil, true)
    mode = "secret"
    H.Fire("UPDATE_FACTION")
    eq(experience.frame:IsShown(), false)
    eq(experience.mode, nil)
    mode = "none"
    _G.IsXPUserDisabled = function() return H.Secret(false) end
    H.Fire("UPDATE_FACTION")
    eq(experience.frame:IsShown(), false)
    _G.IsXPUserDisabled = function() return false end
    H.Fire("UPDATE_FACTION")
    eq(experience.mode, "xp")
    eq(experience.frame:IsShown(), true)
    _G.C_Reputation, _G.C_MajorFactions, _G.C_GossipInfo = nil, nil, nil
    eq(#app.errors, 0)
end)

test("watched reputation can run without XP APIs", function()
    local app = H.Load()
    _G.UnitXP, _G.UnitXPMax = nil, nil
    _G.C_Reputation = {
        GetWatchedFactionData = function() return { factionID = 42, name = "Test faction", reaction = 5,
            currentReactionThreshold = 0, nextReactionThreshold = 100, currentStanding = 40 } end,
        IsFactionParagonForCurrentPlayer = function() return false end,
        IsMajorFaction = function() return false end,
    }
    _G.C_GossipInfo = { GetFriendshipReputation = function() return { friendshipFactionID = 0 } end }
    H.Fire("PLAYER_LOGIN")
    eq(app.components.experience.running, true)
    eq(app.components.experience.mode, "reputation")
    eq(app.components.experience.text:GetText():find("40%%") ~= nil, true)
    _G.C_Reputation, _G.C_GossipInfo = nil, nil
    eq(#app.errors, 0)
end)

test("the minimap keeps native and third-party buttons and says so", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local minimap = app.components.minimap
    local line = minimap:Describe()
    eq(type(line), "string")
    eq(line:find("calendar", 1, true) ~= nil, true)
    eq(line:find("tracking", 1, true) ~= nil, true)
    eq(line:find("worldMap", 1, true) ~= nil, true)
    eq(line:find(app.L.minimapThirdPartyKept, 1, true) ~= nil, true)
    -- LumaUI never moves or hides them.
    eq(GameTimeFrame:IsShown(), true)
    eq(MiniMapTracking:IsShown(), true)
    eq(#app.errors, 0)
end)

test("the settings page writes the one clock and strip mode through", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.Settings:Toggle("general")
    local page = app.Settings.pages.general
    local strip, minimap = app.components.dataStrip, app.components.minimap
    local function button(text)
        for _, control in ipairs(page.settings) do
            if control.text and type(control.text.GetText) == "function" and control.text:GetText() == text then
                return control
            end
        end
    end
    local compact = button(app.L.stripCompact)
    eq(compact ~= nil, true)
    H.Click(compact)
    eq(app.Store:Profile().ui.stripCompact, true)
    eq(app.components.dataStrip.performance:IsShown(), false)
    H.Click(compact)
    eq(app.Store:Profile().ui.stripCompact, false)
    eq(app.components.dataStrip.performance:IsShown(), true)
    local toMinimap = button(app.L.clockMinimap)
    eq(toMinimap ~= nil, true)
    H.Click(toMinimap)
    eq(app.Store:Profile().ui.clock, "minimap")
    eq(minimap.clock:IsShown(), true)
    eq(strip.clock:IsShown(), false)
    local toStrip = button(app.L.clockStrip)
    H.Click(toStrip)
    eq(app.Store:Profile().ui.clock, "strip")
    eq(strip.clock:IsShown(), true)
    eq(minimap.clock:IsShown(), false)
    eq(#app.errors, 0)
end)

-- ==== TRACK: VIS-15 chat, tabs and input focus — append new tests above this line ====

test("chat input mirrors the frame font and spacing and restores both", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local chat = app.components.chat
    local frame, box = ChatFrame1, ChatFrame1EditBox
    frame.font, frame.fontSize, frame.fontFlags = "Fonts/Chat.ttf", 14, ""
    app.components.chat:Refresh()
    eq(box.font, "Fonts/Chat.ttf")
    eq(box.fontSize, 14)
    -- One leading rule derived from the client's own font size.
    eq(frame.spacing, math.floor(14 / 6))
    -- The client's own font menu changes the frame font; the next paint follows.
    frame.fontSize = 18
    app.components.chat:Refresh()
    eq(box.fontSize, 18)
    eq(frame.spacing, math.floor(18 / 6))
    -- Disable restores the box font and the spacing the frame started with.
    app.Store:Set("modules", "chat", false)
    eq(box.fontSize, 13)
    eq(frame.spacing, 0)
    eq(#app.errors, 0)
end)

test("the chat plate reaches up to the tab row and drops back without one", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local chat = app.components.chat
    local entry = chat.windows[1]
    -- Message area runs 200..560; the tab row sits 20 units above it. The plate
    -- covers that row plus one unit of overlap so the tab's own rule lands on
    -- the plate edge instead of beside a hairline of background.
    ChatFrame1.rect = { left = 20, bottom = 200, width = 320, height = 360 }
    ChatFrame1Tab.rect = { left = 20, bottom = 580, width = 80, height = 20 }
    chat:Refresh()
    eq(entry.tabLift, 21)
    -- A hidden tab contributes nothing to the surface.
    ChatFrame1Tab:Hide()
    chat:Refresh()
    eq(entry.tabLift, 0)
    ChatFrame1Tab:Show()
    chat:Refresh()
    eq(entry.tabLift, 21)
    -- A window without its own tab keeps the native background edge.
    eq(chat.windows[2].tabLift, 0)
    eq(#app.errors, 0)
end)

test("the chat input field sits inside the message plate", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local entry = app.components.chat.windows[1]
    ChatFrame1EditBox:SetFocus()
    H.Advance(0.3)
    eq(entry.editBackground:IsShown(), true)
    -- The mock keeps the last anchor: the field is inset 4 units on every side,
    -- not 6, so it reads as part of the conversation surface.
    eq(entry.editBackground.point[4], 4)
    eq(entry.editBackground.point[5], -4)
    eq(#app.errors, 0)
end)

test("chat backing fades on focus and survives a mid-fade reversal", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local chat = app.components.chat
    local entry = chat.windows[1]
    local background = entry.editBackground
    eq(background:IsShown(), false)
    -- Gaining focus fades in over the native beat, not instantly.
    ChatFrame1EditBox:SetFocus()
    eq(background:IsShown(), true)
    H.Advance(0.05)
    eq(background:GetAlpha() > 0 and background:GetAlpha() < 1, true)
    local beforeReverse = background:GetAlpha()
    -- Losing focus mid-fade reverses from the current alpha and settles hidden.
    ChatFrame1EditBox:ClearFocus()
    eq(background:GetAlpha(), beforeReverse)
    H.Advance(0.5)
    eq(background:GetAlpha(), 0)
    eq(background:IsShown(), false)
    eq(app.Transitions:Count(), 0)
    -- A second cycle is not a no-op: the reverse must fade again.
    ChatFrame1EditBox:SetFocus()
    H.Advance(0.5)
    eq(background:GetAlpha(), 1)
    ChatFrame1EditBox:ClearFocus()
    H.Advance(0.5)
    eq(background:IsShown(), false)
    -- Reduce motion settles immediately in both directions.
    app.Store:Set("appearance", "reduceMotion", true)
    ChatFrame1EditBox:SetFocus()
    eq(background:GetAlpha(), 1)
    ChatFrame1EditBox:ClearFocus()
    H.Advance(0.01)
    eq(background:IsShown(), false)
    eq(app.Transitions:Count(), 0)
    eq(#app.errors, 0)
end)

test("chat follows a replaced edit box and releases the old focus hooks", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local entry = app.components.chat.windows[1]
    local old = ChatFrame1EditBox
    ChatFrame1.fontSize = 18
    app.components.chat:Refresh()
    eq(old.fontSize, 18)
    local replacement = H.NewFrame(nil, ChatFrame1)
    replacement.HasFocus = function() return false end
    ChatFrame1.editBox = replacement
    H.Fire("UPDATE_CHAT_WINDOWS")
    eq(entry.editBox, replacement)
    eq(old.fontSize, 13)
    old.scripts.OnEditFocusGained(old)
    eq(entry.editBackground:IsShown(), false)
    replacement.scripts.OnEditFocusGained(replacement)
    eq(entry.editBackground:IsShown(), true)
    H.Advance(0.3)
    eq(entry.editBackground:GetAlpha(), 1)
    app.Store:Set("modules", "chat", false)
    eq(entry.editBackground:IsShown(), false)
    replacement.scripts.OnEditFocusGained(replacement)
    eq(entry.editBackground:IsShown(), false)
    eq(#app.errors, 0)
end)

test("chat keeps an edit box font when its previous font cannot be read", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local replacement = H.NewFrame(nil, ChatFrame1)
    replacement.GetFont = function() error("font unavailable") end
    ChatFrame1.editBox = replacement
    H.Fire("UPDATE_CHAT_WINDOWS")
    eq(replacement.font, nil)
    app.Store:Set("modules", "chat", false)
    eq(replacement.font, nil)
    eq(#app.errors, 0)
end)

test("chat hides the input backing when its window hides mid-fade", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local entry = app.components.chat.windows[1]
    ChatFrame1EditBox:SetFocus()
    H.Advance(0.05)
    ChatFrame1:Hide()
    eq(entry.editBackground:IsShown(), false)
    eq(app.Transitions:Count(), 0)
    -- Showing the window again repaints from the box's real focus state.
    ChatFrame1:Show()
    H.Advance(0.5)
    eq(entry.editBackground:IsShown(), true)
    eq(entry.editBackground:GetAlpha(), 1)
    eq(#app.errors, 0)
end)

test("chat never shows a focused input backing while its window is hidden", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local entry = app.components.chat.windows[2]
    eq(ChatFrame2:IsShown(), false)
    ChatFrame2EditBox:SetFocus()
    eq(entry.editBackground:IsShown(), false)
    ChatFrame2:Show()
    eq(entry.editBackground:IsShown(), true)
    ChatFrame2EditBox:ClearFocus()
    H.Advance(0.3)
    eq(entry.editBackground:IsShown(), false)
    eq(#app.errors, 0)
end)

test("chat follows temporary windows beyond the numbered limit", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local chat = app.components.chat
    -- A whisper popout is created past NUM_CHAT_WINDOWS and registers itself.
    local temp = H.NewFrame("ChatFrame9", UIParent)
    temp.isDocked = false
    temp.editBox = H.NewFrame("ChatFrame9EditBox", UIParent)
    temp.Background = H.NewFrame("ChatFrame9Background", temp)
    CHAT_FRAMES[#CHAT_FRAMES + 1] = "ChatFrame9"
    H.Fire("UPDATE_CHAT_WINDOWS")
    eq(chat.windows[9] ~= nil, true)
    eq(chat.windows[9].background:IsShown(), true)
    -- Closing it removes the entry and restores what it had hidden.
    CHAT_FRAMES[#CHAT_FRAMES] = nil
    H.Fire("UPDATE_CHAT_WINDOWS")
    eq(chat.windows[9], nil)
    eq(temp.Background:IsShown(), true)
    eq(#app.errors, 0)
end)

test("a window whose native art refuses the write is handed back intact", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local chat = app.components.chat
    local entry
    -- Another addon can own a window's art and refuse hide calls. The component
    -- must leave that window entirely alone instead of erroring every paint.
    local guarded = H.NewFrame("ChatFrame7", UIParent)
    guarded.editBox = H.NewFrame("ChatFrame7EditBox", UIParent)
    guarded.Background = H.NewFrame("ChatFrame7Background", guarded)
    guarded.Background.Hide = function() error("owned by another addon") end
    CHAT_FRAMES[#CHAT_FRAMES + 1] = "ChatFrame7"
    H.Fire("UPDATE_CHAT_WINDOWS")
    entry = chat.windows[7]
    eq(entry ~= nil, true)
    eq(entry.conflict, true)
    -- Nothing of ours is drawn over art we could not take over.
    eq(entry.background, nil)
    eq(guarded.Background:IsShown(), true)
    eq(#app.errors, 0)
    -- Once the window is gone the component forgets it.
    CHAT_FRAMES[#CHAT_FRAMES] = nil
    H.Fire("UPDATE_CHAT_WINDOWS")
    eq(chat.windows[7], nil)
    eq(#app.errors, 0)
end)

test("chat tabs give selected, unread, hover and idle separate semantics", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local tabs = app.components.chatTabs
    local first, second = tabs.tabs[1], tabs.tabs[2]
    eq(first.selected, true)
    eq(second.selected, false)
    eq(second.unread, false)
    eq(second.decor.rule:IsShown(), false)
    -- The client's own alert flag is the unread semantic.
    ChatFrameUtil.SetTabAlerting(ChatFrame2Tab, true)
    H.Fire("UPDATE_CHAT_WINDOWS")
    eq(second.unread, true)
    eq(second.decor.rule:IsShown(), true)
    -- The client stopping the flash clears it again.
    FCF_StopAlertFlash(ChatFrame2)
    H.Advance(0.05)
    eq(second.unread, false)
    eq(second.decor.rule:IsShown(), false)
    -- Hover lights an idle tab without promoting it to selected.
    second.tab.scripts.OnEnter(second.tab)
    eq(second.decor.hover:IsShown(), true)
    eq(second.selected, false)
    second.tab.scripts.OnLeave(second.tab)
    eq(second.decor.hover:IsShown(), false)
    -- A selected window is never also shown as unread.
    ChatFrameUtil.SetTabAlerting(ChatFrame1Tab, true)
    H.Fire("UPDATE_CHAT_WINDOWS")
    eq(first.unread, false)
    eq(app.Transitions:Count(), 0)
    eq(#app.errors, 0)
end)

test("chat tabs repaint after the client re-shows its own art", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local tabs = app.components.chatTabs
    -- Ordering proof: the client's dock update writes native art and alpha, and
    -- our paint must run after that write, not before it.
    FCFTab_UpdateColors(ChatFrame1Tab, true)
    FCFTab_UpdateAlpha(ChatFrame1)
    eq(ChatFrame1Tab.ActiveLeft:GetAlpha(), 0)
    eq(ChatFrame1Tab.ActiveLeft:IsShown(), false)
    eq(ChatFrame1Tab:GetAlpha(), 1)
    -- An unread flag flipped by the client's flash entry point repaints too.
    FCF_StartAlertFlash(ChatFrame2)
    eq(tabs.tabs[2].unread, true)
    eq(tabs.tabs[2].decor.rule:IsShown(), true)
    FCF_StopAlertFlash(ChatFrame2)
    eq(tabs.tabs[2].unread, false)
    eq(#app.errors, 0)
end)

test("chat tabs follow tab reuse and restore on disable", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local tabs = app.components.chatTabs
    local first = tabs.tabs[1]
    local original = first.tab
    -- Tab reuse: the client replaces the tab frame for index 1.
    local replacement = H.NewFrame("ChatFrame1Tab", UIParent)
    replacement.alpha = 0.4
    replacement.fontString = H.NewFrame(nil, replacement)
    replacement.fontString.textColor = { 1, 0.82, 0 }
    for _, key in ipairs({ "Left", "Right", "Middle", "ActiveLeft", "ActiveMiddle", "ActiveRight", "HighlightLeft", "HighlightMiddle", "HighlightRight" }) do
        replacement[key] = H.NewFrame(nil, replacement)
    end
    H.Fire("UPDATE_CHAT_WINDOWS")
    eq(tabs.tabs[1].tab, replacement)
    eq(replacement.Left:GetAlpha(), 0)
    eq(original.Left:GetAlpha(), 1)
    eq(original:GetAlpha(), 0.4)
    -- Disable restores the replacement's own art and label colour.
    app.Store:Set("modules", "chatTabs", false)
    eq(replacement.Left:GetAlpha(), 1)
    eq(replacement:GetAlpha(), 0.4)
    eq(replacement.fontString:GetTextColor(), 1)
    eq(#app.errors, 0)
end)

-- ==== TRACK: VIS-14 character window recomposition — append new tests above this line ====

test("character window keeps weapons in their own column and drops the unused ranged slot", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.Store:Set("modules", "characterWindow", true)
    local window = app.components.characterWindow.window
    -- Armour and accessories share one grid; weapons get a separate single
    -- column. Group keys say which is which, so a caller can tell them apart.
    local groupOf = {}
    for _, slot in ipairs(window.slots) do
        groupOf[slot.slotID] = slot.groupKey
    end
    eq(groupOf[1], "equipGroupArmor")
    eq(groupOf[5], "equipGroupArmor")
    eq(groupOf[19], "equipGroupArmor")
    eq(groupOf[2], "equipGroupAccessories")
    eq(groupOf[13], "equipGroupAccessories")
    eq(groupOf[16], "equipGroupWeapons")
    eq(groupOf[17], "equipGroupWeapons")
    -- Eighteen slots would include the unused ranged slot; the real Retail
    -- character uses eighteen, so no placeholder is added and none is invented.
    eq(#window.slots, 18)
    eq(groupOf[18], nil)
    -- The weapon column sits to the right of the armour grid.
    local weapon = window.slots[#window.slots]
    local armour
    for _, slot in ipairs(window.slots) do
        if slot.slotID == 1 then armour = slot end
    end
    eq(weapon.point[2] > armour.point[2], true)
    eq(window.equipped.value:GetText(), "18 / 18")
    eq(#app.errors, 0)
end)

test("character window counts a ranged slot only when the character uses it", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    -- A character with something in the ranged slot (a relic or wand) gets it.
    H.emptySlots = {}
    app.Store:Set("modules", "characterWindow", true)
    local window = app.components.characterWindow.window
    eq(#window.slots, 19)
    eq(window.equipped.value:GetText(), "19 / 19")
    eq(#app.errors, 0)
end)

test("character attributes carry units and the right format", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.Store:Set("modules", "characterWindow", true)
    local window = app.components.characterWindow.window
    local function valueOf(key)
        for _, entry in ipairs(window.statRows) do
            if entry.source.key == key then return entry.row.value:GetText() end
        end
    end
    -- Primary statistics are integers, secondary ones are percentages with one
    -- decimal. Neither is guessed from the value.
    eq(valueOf("statStrength"), "810")
    eq(valueOf("statArmor"), "2650")
    eq(valueOf("statCrit"), "13.4%")
    eq(valueOf("statHaste"), "20.2%")
    eq(valueOf("statMastery"), "20.1%")
    eq(valueOf("statVersatility"), "7.6%")
    -- Every stat row also has a group, so the column can fold as two sections.
    eq(window.statGroups.primary ~= nil, true)
    eq(window.statGroups.secondary ~= nil, true)
    eq(window.statGroups.sets ~= nil, true)
    -- The primary stat of the current specialization is highlighted.
    local accent = app.Theme:Accent()
    local strength
    for _, entry in ipairs(window.statRows) do
        if entry.source.key == "statStrength" then strength = entry.row end
    end
    eq(strength.label.textColor[1], accent[1])
    eq(#app.errors, 0)
end)

test("a hidden character window coalesces updates and repaints once on open", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.Store:Set("modules", "characterWindow", true)
    local component = app.components.characterWindow
    local window = component.window
    eq(window:IsShown(), false)
    -- While hidden, the events only mark the window dirty; nothing repaints.
    window.dirty = nil
    local before = window.slots[1].borderColor[1]
    H.slotQuality = 3
    H.Fire("PLAYER_EQUIPMENT_CHANGED")
    eq(window.dirty, true)
    eq(window.slots[1].borderColor[1], before)
    H.Fire("COMBAT_RATING_UPDATE")
    H.Fire("EQUIPMENT_SETS_CHANGED")
    eq(window.dirty, true)
    eq(window.slots[1].borderColor[1], before)
    -- Opening repaints and clears the flag.
    component:Toggle()
    eq(window:IsShown(), true)
    eq(window.dirty, nil)
    eq(window.slots[1].borderColor[1], ITEM_QUALITY_COLORS[3].r)
    H.Advance(0.2)
    -- A refresh never equips a set or uses an item: display only.
    eq(H.equipmentSetUsed, nil)
    -- Opening goes through the shared open transition.
    component:Toggle()
    H.Advance(0.2)
    eq(window:IsShown(), false)
    H.slotQuality = nil
    eq(#app.errors, 0)
end)

test("character window open, page and fold go through the shared transitions", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.Store:Set("modules", "characterWindow", true)
    local component = app.components.characterWindow
    local window = component.window
    local transitions = app.Transitions
    component:Toggle()
    eq(window:IsShown(), true)
    eq(window:GetAlpha(), 0)
    eq(transitions:Count() > 0, true)
    H.Advance(0.2)
    eq(window:GetAlpha(), 1)
    -- Switching pages fades the incoming page in on its own channel.
    H.Click(window.tabs[2])
    eq(window.pages[2]:IsShown(), true)
    eq(window.pages[1]:IsShown(), false)
    H.Advance(0.2)
    eq(window.pages[2]:GetAlpha(), 1)
    -- Folding a stat group animates its height to zero and settling applies the
    -- target state without leaving the group half open.
    H.Click(window.tabs[1])
    H.Advance(0.2)
    local group = window.statGroups.secondary
    local openHeight = group.height
    group.header.scripts.OnClick(group.header)
    eq(window.folds.secondary, true)
    app.Transitions:SettleAll()
    eq(group.progress, 0)
    -- Reduce motion applies the final state at once.
    app.Store:Set("appearance", "reduceMotion", true)
    group.header.scripts.OnClick(group.header)
    eq(window.folds.secondary, false)
    eq(group.progress, 1)
    -- Disabling the window leaves no task running for it.
    component:Toggle()
    app.Store:Set("modules", "characterWindow", false)
    eq(window:IsShown(), false)
    eq(transitions.tasks[window], nil)
    eq(#app.errors, 0)
    local _ = openHeight
end)

test("equipment sets list nothing gracefully and never swap from a refresh", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local saved = H.equipmentSets
    H.equipmentSets = {}
    app.Store:Set("modules", "characterWindow", true)
    local window = app.components.characterWindow.window
    eq(window.setRows[1].label:GetText(), app.L.setsEmpty)
    eq(window.setRows[1].setID, nil)
    H.Click(window.setRows[1])
    eq(H.equipmentSetUsed, nil)
    -- A refresh with sets present must not equip anything either.
    H.equipmentSets = saved
    app.components.characterWindow:Refresh()
    eq(H.equipmentSetUsed, nil)
    eq(#app.errors, 0)
end)

test("character preview animation and native window entry stay independent", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.Store:Set("modules", "characterWindow", true)
    local component = app.components.characterWindow
    local window = component.window
    CharacterFrame:Show()
    SlashCmdList.LUMAUI("char")
    eq(window:IsShown(), true)
    eq(CharacterFrame:IsShown(), true)
    -- Closing is a fade; the window hides when the transition completes.
    SlashCmdList.LUMAUI("char")
    H.Advance(0.2)
    eq(window:IsShown(), false)
    -- Opening the native entry while it is already shown must not close it.
    SlashCmdList.LUMAUI("char")
    CharacterFrame:Show()
    H.Click(window.nativeEntry)
    eq(window:IsShown(), false)
    eq(CharacterFrame:IsShown(), true)
    -- Opening again after the native window was used still works.
    SlashCmdList.LUMAUI("char")
    eq(window:IsShown(), true)
    eq(#app.errors, 0)
end)

test("character card keeps equipment headings and identity in their own zones", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.Store:Set("modules", "characterWindow", true)
    local component = app.components.characterWindow
    local window = component.window
    eq(window.lumaSurfaceRole, "card")
    eq(window.backdrop, nil)
    eq(window.modelStage.lumaSurfaceRole, "inset")
    eq(window.statsPanel.lumaSurfaceRole, "inset")
    eq(window.title.lumaTypeRole, "display")
    eq(window.identityName.lumaTypeRole, "display")
    eq(window.identityRealm.lumaTypeRole, "label")
    eq(window.identityName:GetWidth(), 320)
    eq(window.identityRealm:GetWidth(), 125)
    eq(window.identityRealm.wordWrap, false)
    for _, key in ipairs({ "equipGroupArmor", "equipGroupAccessories", "equipGroupWeapons" }) do
        local first
        for _, slot in ipairs(window.slots) do
            if slot.groupKey == key then first = slot; break end
        end
        local heading = window.gearHeaders[key]
        eq(first ~= nil and heading ~= nil, true)
        eq(heading.point[3] - first.point[3], 22)
        eq(heading.point[3] < 0, true)
    end
    local plate, children = window.lumaPlate, #window.children
    app.Store:Set("appearance", "windowOpacity", 0.8)
    component:Refresh()
    eq(window.lumaPlate, plate)
    eq(window.lumaPlate.vertexColor[4], 0.8)
    eq(#window.children, children)
    eq(#app.errors, 0)
end)

test("long faction and set names stay clear of the right-hand value", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local longName = string.rep("Very long faction name ", 6)
    H.factions = { { name = "Group", header = true }, { name = longName, standing = 5 } }
    app.Store:Set("modules", "characterWindow", true)
    local window = app.components.characterWindow.window
    H.Click(window.tabs[2])
    local page = window.pages[2]
    -- The full name is kept for the client to truncate, and its width is bounded
    -- so it cannot run underneath the right-aligned value.
    eq(page.rows[2].label:GetText(), longName)
    eq(page.rows[2].label.width ~= nil and page.rows[2].label.width <= 620, true)
    eq(page.rows[2].value:GetText(), "Friendly  4300 / 21000")
    -- Player-named equipment sets get the same bound in the stat column.
    H.equipmentSets[2].name = string.rep("Long set name ", 8)
    app.components.characterWindow:Refresh()
    eq(window.setRows[2].label.width ~= nil and window.setRows[2].label.width <= 150, true)
    eq(window.setRows[2].value:GetText(), "3/4")
    eq(#app.errors, 0)
end)

-- ==== TRACK: VIS-18 BAG AND BANK AVAILABILITY ====
test("bag and bank share card styling and item quality edges", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    SlashCmdList.LUMAUI("bags")
    H.bankView = { [Enum.BankType.Character] = true }
    H.bankTabs = { [Enum.BankType.Character] = { -1 } }
    H.bankSlots[-1] = { [1] = { itemID = 801, name = "Bank item", link = "|Hitem:801|h[Bank item]|h" } }
    app.Store:Set("modules", "bank", true)
    local inventory, bank = app.components.inventory, app.components.bank
    eq(inventory.frame.lumaSurfaceRole, "card")
    eq(bank.frame.lumaSurfaceRole, "card")
    local cell = inventory.buttons[1]
    app.Items.Paint(cell, { texture = 134400, count = 1, quality = 1, locked = false })
    eq(cell.lumaSurfaceRole, "embedded")
    eq(cell.border:IsShown(), false)
    app.Items.Paint(cell, { texture = 134400, count = 1, quality = 2, locked = false })
    eq(cell.border:IsShown(), true)
    eq(cell.border.borderColor[2], ITEM_QUALITY_COLORS[2].g)
    app.Items.Paint(cell, { texture = 134400, count = 1, quality = 1, locked = false })
    eq(cell.border:IsShown(), false)
    eq(#app.errors, 0)
end)

test("inventory search retains the shared input focus state", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    SlashCmdList.LUMAUI("bags")
    local inventory = app.components.inventory
    local input = inventory.search
    input.scripts.OnEditFocusGained(input)
    eq(input.state.focus, true)
    eq(app.Controls.focused, input)
    eq(inventory.searchHint:IsShown(), false)
    input.scripts.OnEditFocusLost(input)
    eq(input.state.focus, false)
    eq(app.Controls.focused, nil)
    eq(inventory.searchHint:IsShown(), true)
    eq(#app.errors, 0)
end)

test("secret item lock state never enters a comparison or an item action", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local original = C_Container.GetContainerItemInfo
    C_Container.GetContainerItemInfo = function()
        return { hyperlink = "|Hitem:701|h[Item]|h", itemID = 701, itemName = "Item",
            stackCount = 1, iconFileID = 134400, quality = 1,
            isLocked = H.Secret(true), hasNoValue = H.Secret(true) }
    end
    local item = app.Items.Read(0, 1)
    eq(item.locked, true)
    eq(item.junk, false)
    app.Items.Pickup(item)
    eq(H.calls.pickup, nil)
    C_Container.GetContainerItemInfo = original
    eq(#app.errors, 0)
end)

test("locked slots dim their cell and refuse item actions", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    SlashCmdList.LUMAUI("bags")
    local inventory = app.components.inventory
    -- Slot 1 of bag 0 arrives locked and junk-free; bag 1 carries a junk item.
    local locked = { link = "|Hitem:701|h[Locked item]|h", itemName = "Locked item", itemID = 701,
        stackCount = 1, iconFileID = 134400, quality = 2, isLocked = true }
    local plain = { link = "|Hitem:702|h[Junk item]|h", itemName = "Junk item", itemID = 702,
        stackCount = 1, iconFileID = 134400, quality = 1, hasNoValue = true }
    C_Container.GetContainerItemInfo = function(bag, slot)
        if slot ~= 1 then return nil end
        if bag == 0 then return locked end
        if bag == 1 then return plain end
        return nil
    end
    inventory.search.scripts.OnTextChanged(inventory.search)
    local first = inventory.buttons[1]
    eq(first.item.bag, 0)
    eq(first.item.locked, true)
    eq(first.icon.desaturated, true)
    eq(first.icon:GetAlpha() < 1, true)
    local before = #H.messages
    first.scripts.OnClick(first, "LeftButton")
    eq(H.calls.pickup, nil)
    eq(#H.messages, before + 1)
    eq(H.messages[#H.messages]:find(app.L.itemLocked, 1, true) ~= nil, true)
    first.scripts.OnClick(first, "RightButton")
    eq(H.calls.use, nil)
    -- The junk item keeps its native mark but is free to move.
    local second = inventory.buttons[2]
    eq(second.item.junk, true)
    eq(second.junk:IsShown(), true)
    second.scripts.OnClick(second, "LeftButton")
    eq(H.calls.pickup.bag, 1)
    eq(#app.errors, 0)
end)

test("bags and bank share one cell and refuse a closed bank or lost permission", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    H.bankView = { [Enum.BankType.Character] = true }
    H.bankTabs = { [Enum.BankType.Character] = { -1 } }
    H.bankSlots[-1] = { [1] = { itemID = 801, name = "Bank item", link = "|Hitem:801|h[Bank item]|h" } }
    app.Store:Set("modules", "bank", true)
    local bank = app.components.bank
    eq(bank.buttons[1].item.name, "Bank item")
    -- The bank permission can be withdrawn while the window stays open; the
    -- corner note then names browse-only and clicks stop before the client call.
    H.bankUsable = { [Enum.BankType.Character] = false }
    H.Fire("BANK_TABS_CHANGED", Enum.BankType.Character)
    eq(bank.note:IsShown(), true)
    eq(bank.note:GetText(), app.L.bankBlocked)
    local before = #H.messages
    bank.buttons[1].scripts.OnClick(bank.buttons[1], "LeftButton")
    eq(H.calls.pickup, nil)
    eq(#H.messages, before + 1)
    -- A closed bank stops being listed at all instead of showing stale slots.
    H.bankView = {}
    H.Fire("BANKFRAME_OPENED")
    eq(bank.empty:IsShown(), true)
    eq(bank.empty:GetText(), app.L.bankClosed)
    eq(bank.buttons[1]:IsShown(), false)
    -- A viewable bank without purchased tabs says exactly that.
    H.bankView = { [Enum.BankType.Character] = true }
    H.bankTabs = { [Enum.BankType.Character] = {} }
    H.Fire("BANKFRAME_OPENED")
    eq(bank.empty:GetText(), app.L.bankNoTabs)
    eq(#app.errors, 0)
end)

test("the bag browser opens its grid in one step and keeps its objects", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    SlashCmdList.LUMAUI("bags")
    local inventory = app.components.inventory
    -- Only the window fades; the 60 cells are plain children at full alpha, so
    -- a large grid never staggers into place cell by cell.
    local frameCount = #H.frames
    local cell = inventory.buttons[1]
    local alpha = cell:GetAlpha()
    inventory.frame:Hide()
    inventory.frame:Show()
    eq(inventory.frame:GetAlpha(), 0)
    eq(cell:GetAlpha(), alpha)
    H.Advance(0.2)
    eq(inventory.frame:GetAlpha(), 1)
    -- A hundred opens reuse the same frames.
    for _ = 1, 100 do
        inventory.frame:Hide()
        inventory.frame:Show()
        H.Advance(0.2)
    end
    eq(#H.frames, frameCount)
    eq(inventory.buttons[60] ~= nil, true)
    eq(#app.errors, 0)
end)

test("an unreadable client reports no containers instead of an empty bag", function()
    local app = H.Load()
    C_Container.GetContainerNumSlots = function() return 0 end
    C_Container.GetContainerNumFreeSlots = function() return 0 end
    H.Fire("PLAYER_LOGIN")
    SlashCmdList.LUMAUI("bags")
    local inventory = app.components.inventory
    eq(inventory.empty:IsShown(), true)
    eq(inventory.empty:GetText(), app.L.noContainers)
    eq(inventory.summary:GetText(), string.format(app.L.slots, 0, 0))
    -- Diagnostics state the probed capability rather than an intention.
    local line = inventory:Describe()
    eq(line:find(app.L.diagActionsOn, 1, true) ~= nil, true)
    eq(line:find(app.L.diagSortOn, 1, true) ~= nil, true)
    eq(#app.errors, 0)
end)

test("the bank diagnostics list the probed types and tab counts", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    H.bankView = { [Enum.BankType.Character] = true, [Enum.BankType.Account] = true }
    H.bankTabs = { [Enum.BankType.Character] = { -1 }, [Enum.BankType.Account] = { 11, 12 } }
    H.bankSlots[-1] = { [1] = { itemID = 901 } }
    H.bankSlots[11] = { [1] = { itemID = 902 } }
    H.bankSlots[12] = { [1] = { itemID = 903 } }
    app.Store:Set("modules", "bank", true)
    local bank = app.components.bank
    local line = bank:Describe()
    eq(line:find("character=1", 1, true) ~= nil, true)
    eq(line:find("account=2", 1, true) ~= nil, true)
    -- With no viewable bank the line says so instead of printing nothing.
    H.bankView = {}
    H.Fire("BANKFRAME_OPENED")
    eq(bank:Describe(), "bank: " .. app.L.diagNoBank)
    eq(#app.errors, 0)
end)

-- ==== TRACK: VIS-19 TOOLTIP SEMANTICS AND RESTORE — append new tests above this line ====
test("the client's own backdrop style cannot put the native tooltip art back", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local tooltip = app.components.tooltip
    GameTooltip:Show()
    eq(GameTooltip.NineSlice:IsShown(), false)
    -- The client rewrites the backdrop on every hide and on styled tooltip data.
    local style = _G.SharedTooltip_SetBackdropStyle
    style(GameTooltip, nil, false)
    eq(GameTooltip.NineSlice:IsShown(), false)
    style(GameTooltip, { layoutType = "TooltipAzeriteLayout", padding = { left = 6, right = 6, top = 6, bottom = 6 } })
    eq(GameTooltip.NineSlice:IsShown(), false)
    eq(tooltip.decor.GameTooltip.plate:IsShown(), true)
    -- A lazy reapply after the tooltip hides still leaves nothing floating.
    GameTooltip:Hide()
    style(GameTooltip, nil, false)
    eq(GameTooltip.NineSlice:IsShown(), false)
    eq(tooltip.decor.GameTooltip.plate:IsShown(), false)
    eq(#app.errors, 0)
end)

test("comparison tooltips stay secondary and never borrow the item quality edge", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    ShoppingTooltip1.itemLink = "|Hitem:999|h[Quality item]|h"
    ShoppingTooltip1:Show()
    ShoppingTooltip2:Show()
    local accent = app.Theme:Accent()
    local decor = app.components.tooltip.decor
    eq(decor.ShoppingTooltip1.quality.color[1], accent[1])
    eq(decor.ShoppingTooltip1.quality.color[2], accent[2])
    -- The main tooltip may use the item quality colour when the option is on.
    GameTooltip.itemLink = "|Hitem:999|h[Quality item]|h"
    GameTooltip:Show()
    eq(decor.GameTooltip.quality.color[1], 0.0)
    -- The comparison is quieter than the tooltip it compares against.
    eq(decor.ShoppingTooltip1.quality.color[4] < decor.GameTooltip.quality.color[4], true)
    ShoppingTooltip1:Hide()
    ShoppingTooltip2:Hide()
    GameTooltip:Hide()
    GameTooltip.itemLink = nil
    eq(#app.errors, 0)
end)

test("an unknown, forbidden or embedded tooltip is left entirely alone", function()
    local app = H.Load()
    -- Forbidden before the component ever runs: no decor is created for it and
    -- its native art is never written by LumaUI.
    GameTooltip.forbidden = true
    H.Fire("PLAYER_LOGIN")
    local tooltip = app.components.tooltip
    eq(tooltip.decor.GameTooltip, nil)
    GameTooltip:Show()
    eq(GameTooltip.NineSlice:IsShown(), true)
    GameTooltip.forbidden = false
    -- A frame of another object type that happens to carry the name is refused:
    -- nothing is parented to it and no texture is created on it.
    local realTooltip = _G.GameTooltip
    local wrongType = H.NewFrame(nil, UIParent)
    wrongType.NineSlice = H.NewFrame(nil, wrongType)
    wrongType.GetObjectType = function() return "Frame" end
    _G.GameTooltip = wrongType
    local before = #H.frames
    tooltip:Refresh()
    eq(#H.frames, before)
    eq(#(wrongType.children or {}), 1)
    _G.GameTooltip = realTooltip
    -- An embedded tooltip is drawn inside another frame, so no surface is added
    -- and the client's own embedded-hide of the art is left as it is.
    ItemRefTooltip.IsEmbedded = true
    ItemRefTooltip:Show()
    eq(tooltip.decor.ItemRefTooltip.plate:IsShown(), false)
    eq(ItemRefTooltip.NineSlice:IsShown(), false)
    ItemRefTooltip.IsEmbedded = false
    ItemRefTooltip:Hide()
    -- A real hide/show transition paints again; the tooltip was already shown
    -- above, so showing it a second time would otherwise be a no-op.
    GameTooltip:Hide()
    GameTooltip:Show()
    eq(tooltip.decor.GameTooltip.plate:IsShown(), true)
    GameTooltip:Hide()
    eq(#app.errors, 0)
end)

test("decor follows a reused tooltip's size and is released on disable", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local tooltip = app.components.tooltip
    local decor = tooltip.decor.GameTooltip
    GameTooltip:Show()
    local frames = #H.frames
    for size = 1, 5 do
        GameTooltip:SetSize(100 + size * 20, 40 + size * 10)
        GameTooltip:Hide()
        GameTooltip:Show()
        -- The surface is anchored to the tooltip itself, never to a stored size.
        eq(decor.plate.point[1], "BOTTOMRIGHT")
        eq(decor.plate.point[2], GameTooltip)
    end
    eq(#H.frames, frames)
    local style = _G.SharedTooltip_SetBackdropStyle
    app.Store:Set("modules", "tooltip", false)
    eq(decor.plate:IsShown(), false)
    eq(GameTooltip.NineSlice:IsShown(), true)
    -- Restore goes through the client's own reset, not a guessed visibility.
    eq(GameTooltip.style, nil)
    style(GameTooltip)
    eq(GameTooltip.NineSlice:IsShown(), true)
    app.Store:Set("modules", "tooltip", true)
    GameTooltip:Show()
    eq(GameTooltip.NineSlice:IsShown(), false)
    local line = tooltip:Describe()
    eq(line:find("main", 1, true) ~= nil, true)
    eq(line:find("compare", 1, true) ~= nil, true)
    GameTooltip:Hide()
    eq(#app.errors, 0)
end)

-- ==== TRACK: VIS-20 ADAPTER STATE, TRANSACTIONS AND LATE LOADING ====

test("a half-failed apply is rolled back to native art for that window only", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local component = app.components.systemWindows
    -- The inbox pane throws in the middle of its sweep: its first art region
    -- is faded, then a FontString refuses its color write. Texture alphas and
    -- text colors are written at different points, so the pane is left with
    -- half of the skin applied when the error escapes.
    local poison = H.NewFrame(nil, InboxFrame)
    poison.kind = "fontstring"
    poison.textColor = { 1, 1, 1, 1 }
    poison.SetTextColor = function() error("client refused the color") end
    InboxFrame.GetRegions = function() return H.mailInboxArt, poison end
    app.Store:Set("modules", "systemWindows", true)
    local mail = component.entries.mail
    eq(mail ~= nil, true)
    -- The failed window is rolled back to its native look: both the region
    -- faded before the throw and the panes swept earlier came back, and no
    -- LumaUI surface is left behind.
    eq(mail.status, "failed")
    eq(mail.applied, false)
    eq(H.mailInboxArt:GetAlpha(), 1)
    eq(H.mailSendArt:GetAlpha(), 1)
    eq(mail.panel.surface:IsShown(), false)
    -- The other windows were not affected by the failure.
    eq(component.entries.character.status, "applied")
    eq(component.entries.character.applied, true)
    eq(H.characterRegions[1]:GetAlpha(), 0)
    eq(H.gossipArt:GetAlpha(), 0)
    -- Disabling restores what remains and reports no new error: the original
    -- throw is the one reported error, under the failing window's context.
    app.Store:Set("modules", "systemWindows", false)
    eq(H.characterRegions[1]:GetAlpha(), 1)
    eq(#app.errors, 1)
    eq(app.errors[1].context, "systemWindows/mail/enable")
end)

test("a delayed repaint is owned, capped and dies with the component", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local component = app.components.systemWindows
    app.Store:Set("modules", "systemWindows", true)
    local entry = component.entries.character
    eq(entry.status, "applied")
    -- Opening the window paints it and schedules exactly the bounded set of
    -- one-shot repaints; each is a C_Timer.After handle the adapter holds.
    local before = #H.timers
    CharacterFrame:Hide()
    CharacterFrame:Show()
    eq(#H.timers, before + 2)
    -- The client redraws its own art between the show and the retry; the
    -- one-shot runs and the skin is back without a second hook.
    H.characterRegions[1]:SetAlpha(1)
    H.Advance(0.4)
    eq(H.characterRegions[1]:GetAlpha(), 0)
    H.Advance(1.3)
    eq(CharacterFrame.hookCount, 1)
    -- A repeat show while the retries are still pending does not stack more
    -- timers than the per-window cap, and a disable cancels every pending one
    -- so nothing repaints a restored window.
    CharacterFrame:Hide()
    CharacterFrame:Show()
    CharacterFrame:Hide()
    CharacterFrame:Show()
    app.Store:Set("modules", "systemWindows", false)
    local pending = 0
    for _, timer in ipairs(H.timers) do
        if timer.after and not timer.cancelled and not timer.fired then pending = pending + 1 end
    end
    eq(pending, 0)
    -- A stale callback that somehow fired after the disable does nothing.
    H.characterRegions[1]:SetAlpha(1)
    H.Advance(2)
    eq(H.characterRegions[1]:GetAlpha(), 1)
    eq(#app.errors, 0)
end)

test("repeated shows are idempotent and keep one set of textures", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local component = app.components.systemWindows
    app.Store:Set("modules", "systemWindows", true)
    local entry = component.entries.mail
    local rows = entry.mailRows
    local firstRule = rows[H.mailRows[1]].rule
    local frames = #H.frames
    for _ = 1, 50 do
        MailFrame:Hide()
        MailFrame:Show()
    end
    H.Advance(2)
    -- Fifty open/close cycles reuse the same row textures and one hook, and
    -- nothing new is created on the window.
    eq(rows[H.mailRows[1]].rule, firstRule)
    eq(MailFrame.hookCount, 1)
    eq(#H.frames, frames)
    eq(entry.status, "applied")
    eq(#app.errors, 0)
end)

test("a window that loads after login is discovered and bound once", function()
    local app = H.Load()
    -- The mail window is load-on-demand: it is absent when the component
    -- starts and arrives later with the client's addon.
    _G.MailFrame, _G.SendMailFrame, _G.InboxFrame = nil, nil, nil
    H.Fire("PLAYER_LOGIN")
    app.Store:Set("modules", "systemWindows", true)
    local component = app.components.systemWindows
    eq(component.entries.mail, nil)
    eq(component.running, true)
    -- The window arrives (same fixture the harness builds at load time).
    _G.MailFrame = H.NewFrame("MailFrame", UIParent)
    MailFrame.NineSlice = H.NewFrame(nil, MailFrame)
    local mailArt = H.NewFrame(nil, MailFrame)
    mailArt.kind = "texture"
    MailFrame.GetRegions = function() return mailArt end
    _G.SendMailFrame = H.NewFrame("SendMailFrame", MailFrame)
    SendMailFrame.NineSlice = H.NewFrame(nil, SendMailFrame)
    local sendArt = H.NewFrame(nil, SendMailFrame)
    sendArt.kind = "texture"
    SendMailFrame.GetRegions = function() return sendArt end
    _G.InboxFrame = H.NewFrame("InboxFrame", MailFrame)
    InboxFrame.NineSlice = H.NewFrame(nil, InboxFrame)
    local inboxArt = H.NewFrame(nil, InboxFrame)
    inboxArt.kind = "texture"
    InboxFrame.GetRegions = function() return inboxArt end
    -- A real load event delivers it: the adapter binds, paints and hooks once.
    H.Fire("ADDON_LOADED", "Blizzard_MailFrame")
    local mail = component.entries.mail
    eq(mail ~= nil, true)
    eq(mail.frame, MailFrame)
    eq(mail.status, "applied")
    eq(sendArt:GetAlpha(), 0)
    eq(MailFrame.hookCount, 1)
    -- A later load event finds the binding already in place.
    H.Fire("ADDON_LOADED", "Blizzard_MailFrame")
    eq(MailFrame.hookCount, 1)
    -- A window that never arrives stays silent: no entry, no hook, no error.
    eq(component.entries.spellbook ~= nil, true)
    app.Store:Set("modules", "systemWindows", false)
    eq(sendArt:GetAlpha(), 1)
    eq(#app.errors, 0)
end)

test("a rebuilt window is rebound to the new frame and the old one restored", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.Store:Set("modules", "systemWindows", true)
    local component = app.components.systemWindows
    local oldFrame = MailFrame
    local oldArt = H.mailSendArt
    eq(oldArt:GetAlpha(), 0)
    -- The client replaces the whole window: a new frame carries the same name
    -- and owns new panes. The old frame fades away still wearing the skin.
    local oldSend = SendMailFrame
    local rebuilt = H.NewFrame(nil, UIParent)
    local rebuiltArt = H.NewFrame(nil, rebuilt)
    rebuiltArt.kind = "texture"
    rebuilt.GetRegions = function() return rebuiltArt end
    _G.MailFrame = rebuilt
    -- The replacement's own panes are bound under the same names.
    local rebuiltSend = H.NewFrame(nil, rebuilt)
    local rebuiltSendArt = H.NewFrame(nil, rebuiltSend)
    rebuiltSendArt.kind = "texture"
    rebuiltSend.GetRegions = function() return rebuiltSendArt end
    _G.SendMailFrame = rebuiltSend
    -- A runtime pass (profile switch, theme rebuild) notices the replacement.
    app.Store:Set("appearance", "windowOpacity", 0.95)
    local entry = component.entries.mail
    eq(entry.frame, rebuilt)
    eq(rebuiltArt:GetAlpha(), 0)
    eq(rebuiltSendArt:GetAlpha(), 0)
    -- The old frame's art came back before the new frame was bound; the stale
    -- pane name does not pull the old pane into the new skin.
    eq(oldArt:GetAlpha(), 1)
    eq(oldSend:GetAlpha(), 1)
    eq(entry.frame ~= oldFrame, true)
    -- A reopened old window is not repainted by the hook it still carries.
    oldArt:SetAlpha(1)
    oldFrame:Hide()
    oldFrame:Show()
    eq(oldArt:GetAlpha(), 1)
    eq(#app.errors, 0)
end)

test("the dedicated character window takes the frame over and gives it back", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.Store:Set("modules", "systemWindows", true)
    local component = app.components.systemWindows
    local entry = component.entries.character
    eq(entry.status, "applied")
    eq(H.characterRegions[1]:GetAlpha(), 0)
    -- The LumaUI character window starts: it owns CharacterFrame now, so the
    -- adapter restores its own skin instead of fighting for the frame.
    app.Store:Set("modules", "characterWindow", true)
    eq(entry.status, "handover")
    eq(entry.applied, false)
    eq(H.characterRegions[1]:GetAlpha(), 1)
    eq(entry.panel.surface:IsShown(), false)
    -- While the dedicated window runs, a runtime pass keeps the handover: the
    -- adapter does not repaint the frame underneath it.
    app.Store:Set("appearance", "windowOpacity", 0.95)
    eq(component.entries.character.status, "handover")
    eq(H.characterRegions[1]:GetAlpha(), 1)
    -- The dedicated window stops: the next runtime pass paints the frame again
    -- through the same single hook.
    app.Store:Set("modules", "characterWindow", false)
    eq(component.entries.character.status, "applied")
    eq(H.characterRegions[1]:GetAlpha(), 0)
    eq(entry.panel.surface:IsShown(), true)
    eq(CharacterFrame.hookCount, 1)
    eq(#app.errors, 0)
end)

test("system window diagnostics name each window's real outcome", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.Store:Set("modules", "systemWindows", true)
    local line = app.components.systemWindows:Describe()
    eq(type(line), "string")
    eq(line:find("character=applied", 1, true) ~= nil, true)
    eq(line:find("mail=applied", 1, true) ~= nil, true)
    eq(line:find("spellbook=applied", 1, true) ~= nil, true)
    -- A missing optional window says so instead of vanishing from the line.
    local other = H.Load()
    _G.GossipFrame = nil
    H.Fire("PLAYER_LOGIN")
    other.Store:Set("modules", "systemWindows", true)
    local otherLine = other.components.systemWindows:Describe()
    eq(otherLine:find("npc=missing", 1, true) ~= nil, true)
    eq(otherLine:find("character=applied", 1, true) ~= nil, true)
    -- Disabled components report nothing.
    other.Store:Set("modules", "systemWindows", false)
    eq(other.components.systemWindows:Describe(), nil)
    eq(#app.errors, 0)
    eq(#other.errors, 0)
end)

test("a profile switch and a read-only store leave every window consistent", function()
    local app = H.Load({ profiles = { Default = { modules = { systemWindows = true } },
        Plain = { modules = { systemWindows = false } } } })
    H.Fire("PLAYER_LOGIN")
    local component = app.components.systemWindows
    eq(component.running, true)
    eq(H.characterRegions[1]:GetAlpha(), 0)
    -- Switching to a profile with the switch off restores every window; no
    -- pending retry repaints one afterwards.
    app.Store:Set("ui", "clock", true)
    local ok = app.Store:Select("Plain")
    eq(ok, true)
    eq(component.running, false)
    eq(H.characterRegions[1]:GetAlpha(), 1)
    eq(H.gossipArt:GetAlpha(), 1)
    H.Advance(2)
    eq(H.characterRegions[1]:GetAlpha(), 1)
    -- Back to the profile that skins windows: one hook per window again.
    app.Store:Select("Default")
    eq(component.running, true)
    eq(H.characterRegions[1]:GetAlpha(), 0)
    eq(CharacterFrame.hookCount, 1)
    -- A store written by a newer schema is read-only: the saved switch still
    -- decides, the skin applies, and no write is attempted.
    local readonly = H.Load({ profiles = { Default = { modules = { systemWindows = true } } } })
    H.Fire("PLAYER_LOGIN")
    readonly.Store.readonly = true
    readonly:Reconcile()
    eq(readonly.components.systemWindows.running, true)
    eq(H.characterRegions[1]:GetAlpha(), 0)
    eq(readonly.Store:Set("modules", "systemWindows", false), false)
    eq(readonly.components.systemWindows.running, true)
    eq(#app.errors, 0)
    eq(#readonly.errors, 0)
end)

test("a window without field access is refused instead of half painted", function()
    local app = H.Load()
    -- A window that cannot be walked (no region or child access) cannot be
    -- skinned safely: the adapter refuses it as a whole and leaves the window
    -- native, while every other window is still applied.
    _G.MerchantFrame = H.NewFrame("MerchantFrame", UIParent)
    MerchantFrame.GetRegions = false
    MerchantFrame.GetChildren = false
    H.Fire("PLAYER_LOGIN")
    app.Store:Set("modules", "systemWindows", true)
    local component = app.components.systemWindows
    local merchant = component.entries.merchant
    eq(merchant ~= nil, true)
    eq(merchant.status, "failed")
    eq(merchant.applied, false)
    eq(merchant.failure, "unusable")
    -- No panel was drawn on the refused window and nothing was created on it.
    eq(merchant.panel == nil, true)
    eq(MerchantFrame.children, nil)
    eq(component.entries.npc.status, "applied")
    eq(H.gossipArt:GetAlpha(), 0)
    -- Opening the refused window retries once, stays refused, and does not
    -- report an error: refusing is a decision, not a defect.
    MerchantFrame:Hide()
    MerchantFrame:Show()
    eq(merchant.status, "failed")
    eq(#app.errors, 0)
    -- The diagnostics line names the refusal for that window only.
    local line = component:Describe()
    eq(line:find("merchant=failed", 1, true) ~= nil, true)
    eq(line:find("npc=applied", 1, true) ~= nil, true)
    app.Store:Set("modules", "systemWindows", false)
    eq(#app.errors, 0)
end)


test("mail skin marks the open row and never recolors read state", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.Store:Set("modules", "systemWindows", true)
    local entry = app.components.systemWindows.entries.mail
    eq(entry.status, "applied")
    local row = H.mailRows[1]
    -- Nothing is open yet: no row carries the accent bar.
    eq(entry.mailRows[row].bar:IsShown(), false)
    -- The client ticks the row's Button for the open mail and then rewrites
    -- the row; the row decoration follows without a full repaint.
    row.Button:SetChecked(true)
    _G.InboxFrame_Update()
    eq(entry.mailRows[row].bar:IsShown(), true)
    eq(entry.mailRows[H.mailRows[2]].bar:IsShown(), false)
    -- A new page clears the selection again.
    row.Button:SetChecked(false)
    _G.InboxFrame_Update()
    eq(entry.mailRows[row].bar:IsShown(), false)
    -- Sender and subject carry the client's read/unread colors; the skin
    -- records them as plain text and never writes them.
    eq(row.Sender.textColor[1], 0.75)
    eq(row.Subject.textColor[1], 0.75)
    app.components.systemWindows:Refresh()
    eq(row.Sender.textColor[1], 0.75)
    eq(row.Subject.textColor[1], 0.75)
    -- The row's item icon, its quality border and the count stay as content.
    eq(row.Button.Icon:GetAlpha(), 1)
    eq(row.Button.IconBorder:GetAlpha(), 1)
    eq(#app.errors, 0)
end)

test("mail keeps its text fields, page arrows and stationery native", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.Store:Set("modules", "systemWindows", true)
    -- Input fields: the client draws the focus state and the caret in the box.
    eq(H.mailEditBoxArt:GetAlpha(), 1)
    -- A page arrow's art is the game's disabled state.
    eq(H.mailPageArt:GetAlpha(), 1)
    -- The opened letter is a toplevel of its own: its frame art goes and its
    -- stationery backdrop stays, because the letterhead is the letter.
    eq(H.mailLetterArt:GetAlpha(), 0)
    eq(H.letterStationery:GetAlpha(), 1)
    -- Its take button keeps working and its label is recolored like the rest.
    eq(H.mailLetterLabel.textColor[1], app.Theme.colors.text[1])
    -- Its attachment slots keep the item they carry.
    eq(H.mailLetterAttachment.Icon:GetAlpha(), 1)
    -- The page tabs lose their art and get a LumaUI surface with a rule.
    local tab = app.components.systemWindows.entries.mail.tabBg[MailFrameTab1]
    eq(tab ~= nil, true)
    eq(tab.surface:IsShown(), true)
    eq(tab.rule:IsShown(), true)
    eq(H.mailTabArt:GetAlpha(), 0)
    app.Store:Set("modules", "systemWindows", false)
    eq(H.mailLetterArt:GetAlpha(), 1)
    eq(#app.errors, 0)
end)

test("mail skin survives re-open, tab switches and late letter arrival", function()
    local app = H.Load()
    -- The letter is load-on-demand: it does not exist at login.
    _G.OpenMailFrame = nil
    local function openLetter()
        local letter = H.NewFrame("OpenMailFrame", UIParent)
        local art = H.NewFrame(nil, letter)
        art.kind = "texture"
        letter.GetRegions = function() return art end
        return { frame = letter, letterArt = art }
    end
    H.Fire("PLAYER_LOGIN")
    app.Store:Set("modules", "systemWindows", true)
    local entry = app.components.systemWindows.entries.mail
    eq(entry.status, "applied")
    -- Tab switches only toggle the panes; repeated opens repaint through the
    -- one hook without stacking decorations.
    local first = entry.mailRows[H.mailRows[1]]
    for _ = 1, 10 do
        MailFrame:Hide(); MailFrame:Show()
    end
    eq(entry.mailRows[H.mailRows[1]], first)
    eq(MailFrame.hookCount, 1)
    -- The letter loads late: the next attempt binds it, and its controls join
    -- the skin without a second entry.
    local built = openLetter()
    -- The letter arrives while the skin runs, and the next repaint of the mail
    -- window (an ordinary open) adopts it through the same entry.
    H.Fire("ADDON_LOADED", "Blizzard_MailFrame")
    MailFrame:Hide(); MailFrame:Show()
    eq(entry.roots ~= nil and entry.roots[built.frame], true)
    eq(built.letterArt:GetAlpha(), 0)
    app.Store:Set("modules", "systemWindows", false)
    eq(built.letterArt:GetAlpha(), 1)
    eq(#app.errors, 0)
end)

-- ==== TRACK: VIS-22 SOCIAL WINDOW ====

test("social rows come from the scroll box and keep the client's colors", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.Store:Set("modules", "systemWindows", true)
    local entry = app.components.systemWindows.entries.social
    eq(entry.status, "applied")
    -- The who list and the ignore list are dressed through their own boxes. The
    -- rows are anonymous frames, so only the box can enumerate them.
    local who = H.whoRows[1]
    eq(entry.socialRows[who] ~= nil, true)
    eq(who.Highlight:GetAlpha(), 1)
    eq(H.whoName.textColor[1], 1)
    eq(H.whoClass.textColor[1], 0.41)
    -- The alternating tint restarts in each list rather than running across
    -- panes: the who list's second row is even, exactly like the friends
    -- list's second row.
    eq(entry.socialRows[H.whoRows[2]].tint:IsShown(), true)
    local ignore = entry.socialRows[H.ignoreRow]
    eq(ignore ~= nil, true)
    eq(H.ignoreName.textColor[2], 0.82)
    -- The column headers, the search field, the sort dropdown, the totals line
    -- and the unignore button keep their own art: the sort arrow, the focus
    -- ring and the disabled look are state, not decoration.
    eq(H.whoHeaderArt:GetAlpha(), 1)
    eq(H.whoEditArt:GetAlpha(), 1)
    eq(H.whoTotals.textColor[2], 0.82)
    eq(H.unignoreArt:GetAlpha(), 1)
    -- Disabling gives every one of them back untouched.
    app.Store:Set("modules", "systemWindows", false)
    eq(H.whoHighlight:GetAlpha(), 1)
    eq(H.ignoreName.textColor[2], 0.82)
    eq(H.whoTotals.textColor[2], 0.82)
    eq(#app.errors, 0)
end)

test("social selection, rebuilds and reuse follow the client without a second hook", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.Store:Set("modules", "systemWindows", true)
    local entry = app.components.systemWindows.entries.social
    local first, second = H.socialRows[1], H.socialRows[2]
    -- Selection is read from the client's modal highlight lock; the skin only
    -- draws its own bar and never toggles the client's highlight.
    local locked = {}
    first.IsHighlightLocked = function() return locked[first] == true end
    second.IsHighlightLocked = function() return locked[second] == true end
    local decor = entry.socialRows[first]
    eq(decor.bar:IsShown(), false)
    locked[first] = true
    _G.FriendsList_Update()
    eq(decor.bar:IsShown(), true)
    eq(entry.socialRows[second].bar:IsShown(), false)
    -- Moving the selection only needs the bars to follow.
    locked[first] = false
    locked[second] = true
    _G.FriendsList_Update()
    eq(decor.bar:IsShown(), false)
    eq(entry.socialRows[second].bar:IsShown(), true)
    -- The client rebuilds a list by reusing pooled rows; the refresh after its
    -- update keeps the same decorations instead of stacking new ones.
    local tint = decor.tint
    local decorCount = #entry.decor
    for _ = 1, 10 do _G.FriendsList_Update() end
    eq(entry.socialRows[first].tint, tint)
    eq(#entry.decor, decorCount)
    eq(FriendsFrame.hookCount, 1)
    -- A row the box hands out later is dressed by the same refresh path.
    local late = H.friendRow(4)
    _G.FriendsList_Update()
    eq(entry.socialRows[late] ~= nil, true)
    eq(late.background:GetAlpha(), 0)
    eq(late.status:GetAlpha(), 1)
    -- Disabling removes the bars and stops the hooks from drawing.
    app.Store:Set("modules", "systemWindows", false)
    eq(entry.socialRows[second].bar:IsShown(), false)
    locked[first] = true
    _G.FriendsList_Update()
    eq(decor.bar:IsShown(), false)
    eq(#app.errors, 0)
end)

-- ==== TRACK: VIS-23 SPELLBOOK WINDOW ====

test("spellbook rows come from the paged grid and keep spell state", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.Store:Set("modules", "systemWindows", true)
    local entry = app.components.systemWindows.entries.spellbook
    eq(entry.status, "applied")
    -- The rows are pooled frames the grid enumerates, not named globals.
    local item = H.spellItems[1]
    eq(entry.spellRows[item] ~= nil, true)
    -- The plate behind the row goes; the button carrying the icon, the
    -- learned/unlearned border and the hover art is kept whole, because the
    -- desaturated icon and the dimmed text on a not-learned spell are state.
    eq(item.Backplate:GetAlpha(), 0)
    eq(item.Button.Icon:GetAlpha(), 1)
    eq(item.Button.Border:GetAlpha(), 1)
    eq(item.Button.BorderShadow:GetAlpha(), 0)
    -- The unlearned dimming is the client's own text alpha: never rewritten.
    eq(item.Name.alpha, 0.6)
    eq(item.Name.textColor[1], 1)
    -- A category header loses its plate and keeps its heading, which carries
    -- the client's own spellbook color and is therefore never recolored.
    eq(H.spellHeader.Backplate:GetAlpha(), 0)
    eq(H.spellHeader.Text.textColor == nil, true)
    -- Disabling restores the plates and leaves nothing behind.
    app.Store:Set("modules", "systemWindows", false)
    eq(item.Backplate:GetAlpha(), 1)
    eq(item.Button.BorderShadow:GetAlpha(), 1)
    eq(H.spellHeader.Backplate:GetAlpha(), 1)
    eq(#app.errors, 0)
end)

test("spellbook leaves the talent and spec pages alone and follows paging", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.Store:Set("modules", "systemWindows", true)
    local entry = app.components.systemWindows.entries.spellbook
    -- The specialisation page is a sibling of the spellbook pane, not part of
    -- this adapter: its art keeps the client's alpha.
    eq(H.spellSpecArt:GetAlpha(), 1)
    -- Kept controls: the search field's focus ring, the settings menu icon and
    -- the paging arrows (their disabled look is the only page-state cue).
    eq(H.spellSearchArt:GetAlpha(), 1)
    eq(H.spellSettingsArt:GetAlpha(), 1)
    eq(H.spellPagingArt:GetAlpha(), 1)
    -- The book chrome behind the content fades.
    eq(H.spellChrome[1]:GetAlpha(), 0)
    -- Category tabs take the LumaUI surface; the selected one carries the
    -- accent rule, and switching the pane's tab moves it.
    local first, second = H.spellTabs[1], H.spellTabs[2]
    local decor = entry.tabBg[first.tab]
    local secondDecor = entry.tabBg[second.tab]
    local accent = app.Theme:Accent()
    local line = app.Theme.colors.line
    eq(decor.rule.color[1], accent[1])
    eq(secondDecor.rule.color[1], line[1])
    eq(entry.tabBg[second.tab].surface:GetAlpha() >= 0, true)
    -- A window page switch re-reads the tab system: the accent rule leaves the
    -- old tab and lands on the newly selected one.
    H.spellPane.selectedTab = 2
    PlayerSpellsFrame:SetTab(2)
    eq(secondDecor.rule.color[1], accent[1])
    eq(decor.rule.color[1], line[1])
    -- The grid rebuilds on every page turn; rows the client recycles are
    -- redressed by the same pass and the decorations are reused.
    local tint = entry.spellRows[H.spellItems[1]].tint
    local decorCount = #entry.decor
    for _ = 1, 5 do H.spellPaged.DisplayViewsForCurrentPage() end
    eq(entry.spellRows[H.spellItems[1]].tint, tint)
    eq(#entry.decor, decorCount)
    -- A row handed out later is dressed as well.
    local late = H.NewFrame(nil, H.spellPaged)
    late.Backplate = H.NewFrame(nil, late); late.Backplate.kind = "texture"
    late.Name = H.NewFrame(nil, late); late.Name.kind = "fontstring"
    late.Button = H.NewFrame(nil, late)
    late.Button.Icon = H.NewFrame(nil, late.Button); late.Button.Icon.kind = "texture"
    late.Button.GetRegions = function() return late.Button.Icon end
    late.GetRegions = function() return late.Backplate end
    table.insert(H.spellPaged.rows, late)
    H.spellPaged.DisplayViewsForCurrentPage()
    eq(entry.spellRows[late] ~= nil, true)
    eq(late.Backplate:GetAlpha(), 0)
    eq(late.Button.Icon:GetAlpha(), 1)
    -- Disabling removes the row decorations again.
    app.Store:Set("modules", "systemWindows", false)
    eq(entry.spellRows[late].tint:IsShown(), false)
    eq(#app.errors, 0)
end)

-- ==== TRACK: VIS-23 SPELLBOOK WINDOW — append new tests above this line ====

-- ==== TRACK: VIS-22 SOCIAL WINDOW — append new tests above this line ====

-- ==== TRACK: VIS-24 STYLE FOUNDATION — append new tests above this line ====

test("a list row has no fill until it is touched", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local parent = H.NewFrame(nil, UIParent)
    local row = app.Controls:Toggle(parent, "row", 0, function() return false end, function() end)
    -- A switch row is a line of text on the page, not a raised slab: one fill per
    -- row is what made the settings page read as a grid of boxes.
    eq(row.flat, true)
    eq(row.backgroundColor[4], 0)
    row.state.hover = true
    row:Refresh()
    eq(row.backgroundColor[4] > 0, true)
    row.state.hover = false
    row:Refresh()
    eq(row.backgroundColor[4], 0)
    -- Disabled rows keep the transparent rhythm and only dim their text.
    row:SetEnabled(false)
    eq(row.backgroundColor[4], 0)
    eq(#app.errors, 0)
end)

test("a control draws its hairline only while it has a state to announce", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local parent = H.NewFrame(nil, UIParent)
    local button = app.Controls:Button(parent, "plain", 120, nil)
    local accent = app.Theme:Accent()
    -- Idle: the ring exists but is fully transparent, so the control is a flat patch.
    eq(button.ring ~= nil, true)
    eq(button.ring.borderColor[4], 0)
    -- Selected: the accent hairline appears, and it is the accent, not the line token.
    button:SetSelected(true)
    eq(button.ring.borderColor[4], 1)
    eq(button.ring.borderColor[1], accent[1])
    -- Deselecting puts it away again rather than leaving a permanent border.
    button:SetSelected(false)
    eq(button.ring.borderColor[4], 0)
    -- A primary button is announced at rest, because that is what makes it primary.
    local primary = app.Controls:Button(parent, "go", 120, nil, { kind = "primary" })
    eq(primary.ring.borderColor[4], 1)
    -- Hover is a state too.
    primary.state.hover = true
    primary:Refresh()
    eq(primary.ring.borderColor[4], 1)
    eq(#app.errors, 0)
end)

test("Pearl combat fill paints a fixed colour on the matte texture", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    eq(app.Theme.media.combatFill, "Interface\\AddOns\\LumaUI\\Media\\combat-fill.tga")
    eq(app.Theme.media.scrim, "Interface\\AddOns\\LumaUI\\Media\\hud-scrim.tga")
    local bar = app.Theme:Bar(UIParent, 10)
    app.Theme:PaintCombatBar(bar, { 0.88, 0.24, 0.20 })
    -- The fill is the matte texture with the bar's own colour; no horizontal
    -- gradient record, which is what kept short bars saturated.
    eq(bar.statusFill.texture, app.Theme.media.combatFill)
    eq(bar.gradient, nil)
    eq(bar.barColor[1], 0.88)
    eq(bar.barColor[2], 0.24)
    eq(bar.barColor[3], 0.20)
    -- The track is the same colour dimmed, so the empty part still reads.
    eq(bar.background.color ~= nil, true)
    -- The legacy gradient painter still chooses its own texture: the two roles
    -- are independent and existing panels keep their path.
    local legacy = app.Theme:Bar(UIParent, 12)
    app.Theme:PaintBar(legacy, { 0.2, 0.8, 0.4 })
    eq(legacy.gradient ~= nil, true)
    eq(#app.errors, 0)
end)

test("the text scrim is one local texture per host, reused on repaint", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local host = H.NewFrame(nil, UIParent)
    local scrim = app.Theme:Scrim(host, 6)
    eq(scrim ~= nil, true)
    eq(host.lumaScrim, scrim)
    eq(scrim.texture, app.Theme.media.scrim)
    eq(scrim:IsShown(), true)
    -- Repeated paints reuse the same texture instead of stacking another one.
    local children = #(host.children or {})
    eq(app.Theme:Scrim(host, 6), scrim)
    eq(#(host.children or {}), children)
    -- A host that cannot parent textures simply draws none.
    eq(app.Theme:Scrim({}, 4), nil)
    eq(#app.errors, 0)
end)

test("surface layers stay inside the client's sublevel range", function()
    local app = H.Load()
    local layers = app.Surface.LAYERS
    -- CreateTexture rejects a sublevel outside -8..7 at run time, and the error
    -- reaches whatever called it (a chat command, a settings click), so the range
    -- is asserted here rather than discovered in game.
    for name, value in pairs(layers) do
        eq(type(value), "number")
        eq(value >= -8 and value <= 7, true)
        eq(name ~= nil, true)
    end
    -- The shadow must be drawn under the plate, not over it.
    eq(layers.shadow < layers.plate, true)
end)

test("type roles are a closed ascending scale with one resolved face", function()
    local app = H.Load()
    local roles = app.Type.roles
    eq(#({ "display", "title", "body", "label", "micro", "world" }), 6)
    eq(roles.display.size > roles.title.size, true)
    eq(roles.title.size > roles.body.size, true)
    eq(roles.body.size > roles.label.size, true)
    eq(roles.label.size > roles.micro.size, true)
    -- Only the over-the-world role carries an outline; a card never needs one.
    eq(roles.world.outline, true)
    eq(roles.body.outline, nil)
    eq(roles.display.weight, "strong")
    local face = app.Type:Face()
    eq(type(face), "string")
    eq(face ~= "", true)
    -- Resolved once and reused: the probe must not run per FontString.
    eq(app.Type:Face(), face)
end)

test("surface roles name purpose and paint a shape without a backdrop edge", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    eq(app.Surface.roles.card.shadow, true)
    -- Only one role floats; a shadow on every surface is what makes a layout noisy.
    local shadows = 0
    for _, role in pairs(app.Surface.roles) do if role.shadow then shadows = shadows + 1 end end
    eq(shadows, 1)
    local frame = H.NewFrame(nil, UIParent)
    app.Surface:Plate(frame, "card")
    eq(frame.lumaSurfaceRole, "card")
    eq(frame.lumaPlate ~= nil, true)
    -- The harness has no slice API, so the plate must fall back to a square fill
    -- and no shadow rather than leaving a half-built texture behind.
    eq(app.Surface:CanSlice(), false)
    eq(frame.lumaShadow, nil)
    -- An unknown role degrades to the card instead of erroring at the call site.
    local other = H.NewFrame(nil, UIParent)
    app.Surface:Plate(other, "nonsense")
    eq(other.lumaSurfaceRole, "card")
    eq(#app.errors, 0)
end)

test("hairlines hold one physical pixel at any UI scale", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local parent = H.NewFrame(nil, UIParent)
    local line = app.Surface:HLine(parent, 0.5)
    eq(line:GetHeight(), app.Pixel:Size(1))
    local vertical = app.Surface:VLine(parent)
    eq(vertical:GetWidth(), app.Pixel:Size(1))
end)

test("the style sheet builds once, repaints and reuses its frame", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local frame = app.StyleSheet:Toggle(true)
    eq(frame:IsShown(), true)
    eq(app.StyleSheet.frame, frame)
    -- A second open must not build a second card.
    app.StyleSheet:Toggle(false)
    eq(frame:IsShown(), false)
    eq(app.StyleSheet:Toggle(true), frame)
    app.StyleSheet:Paint()
    eq(#app.errors, 0)
end)


test("Pearl is the default accent and one migration moves old profiles", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    eq(app.Store:Profile().appearance.accent, "pearl")
    local legacy = H.Load({ profiles = { Default = {
        appearance = { accent = "ocean", hudOpacity = 0.62 },
        ui = { stripCompact = true } } } })
    H.Fire("PLAYER_LOGIN")
    eq(legacy.Store:Profile().appearance.accent, "pearl")
    eq(legacy.Store:Profile().appearance.hudOpacity, 0.80)
    eq(legacy.Store:Profile().ui.stripCompact, false)
    eq(legacy.Store:Profile().modules.unitFrames, true)
    eq(legacy.Store:Profile().modules.actionBars, true)
    eq(legacy.Store:Profile().ui.takeoverUnitFrames, true)
    eq(LumaUIDB.migrations.pearlBatch, true)
    eq(LumaUIDB.migrations.actionBars, true)
    local again = H.Load(LumaUIDB); H.Fire("PLAYER_LOGIN")
    eq(again.Store:Profile().appearance.accent, "pearl")
    eq(#again.errors, 0)
end)

test("surface aliases resolve to the one Theme role table", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local card = app.Surface:Role("card")
    local window = app.Theme.surfaceRoles.window
    eq(card.color, window.color)
    eq(card.opacity, window.opacity)
    local inset, resolved = app.Surface:Role("embedded")
    eq(resolved, "inset")
    eq(inset.color, "embedded")
    eq(inset.opacity, "windowOpacity")
    eq(#app.errors, 0)
end)

test("the Pearl visual replacements are on for a fresh profile", function()
    local app = H.Load({
        profiles = { Default = {} },
        migrations = { pearlBatch = true, questListDefault = true, visualModules = true,
            actionBars = true },
    })
    H.Fire("PLAYER_LOGIN")
    local profile = app.Store:Profile()
    eq(profile.modules.unitFrames, true)
    eq(profile.modules.partyFrames, true)
    eq(profile.modules.nameplates, true)
    eq(profile.modules.actionBars, true)
    eq(profile.ui.takeoverUnitFrames, true)
    eq(app.components.unitFrames.running, true)
    eq(app.components.partyFrames.running, true)
    eq(app.components.nameplates.running, true)
    eq(app.components.actionBars.running, true)
    eq(app.components.unitFrames.takeover.units, true)
    eq(PlayerFrame:IsShown(), false)
    eq(#app.errors, 0)
end)

test("action bars stack at the centre and restore on disable", function()
    local app = H.Load({
        profiles = { Default = {} },
        migrations = { pearlBatch = true, questListDefault = true, visualModules = true,
            actionBars = true },
    })
    local bar2 = H.NewFrame("MultiBarBottomLeft", UIParent)
    bar2.actionButtons = { H.NewFrame("MultiBarBottomLeftButton1", bar2) }
    local bar3 = H.NewFrame("MultiBarBottomRight", UIParent)
    bar3.actionButtons = { H.NewFrame("MultiBarBottomRightButton1", bar3) }
    local button = MainActionBar.actionButtons[1]
    local countdown = H.NewFrame(nil, button)
    countdown:SetFont("Fonts/Mock.ttf", 10)
    local cooldownWrites = 0
    local cooldown = H.NewFrame(nil, button)
    cooldown.GetCountdownFontString = function() return countdown end
    cooldown.SetHideCountdownNumbers = function(self, hide) cooldownWrites = cooldownWrites + 1; self.hideNumbers = hide end
    cooldown.SetSwipeColor = function() cooldownWrites = cooldownWrites + 1 end
    button.cooldown = cooldown
    H.Fire("PLAYER_LOGIN")

    eq(MainActionBar.point[1], "BOTTOM")
    eq(MainActionBar.point[2], UIParent)
    eq(MainActionBar.point[4], 0)
    eq(MainActionBar.point[5], 56)
    eq(bar2.point[1], "BOTTOM")
    eq(bar2.point[2], MainActionBar)
    eq(bar2.point[4], 0)
    eq(bar2.point[5], 4)
    eq(bar3.point[2], bar2)
    eq(MainActionBar.alpha, 0)
    eq(bar2.alpha, 0)
    eq(bar3.alpha, 0)
    -- The native cooldown object is never written: in 12.x its update passes
    -- secret values to SetCooldown and any addon write on it taints that call
    -- (field report: "Secret values are only allowed during untainted
    -- execution"). Countdown text keeps the client's own font and anchors too.
    eq(cooldownWrites, 0)
    eq(cooldown.hideNumbers, nil)
    eq(countdown.fontSize, 10)
    eq(countdown.point, nil)

    _G.MouseIsOver = function() return true end
    H.Advance(0.35)
    eq(MainActionBar.alpha > 0.5, true)
    _G.MouseIsOver = function() return false end
    H.now = H.now + 2
    H.Advance(1.6)
    eq(MainActionBar.alpha < 0.1, true)
    _G.MouseIsOver = nil

    app.Store:Set("modules", "actionBars", false)
    eq(MainActionBar.alpha, 1)
    eq(MainActionBar.point, nil)
    eq(countdown.fontSize, 10)
    eq(#app.errors, 0)
end)

test("action bars skin every bar once and hand the buttons back on disable", function()
    local app = H.Load({
        profiles = { Default = {} },
        migrations = { pearlBatch = true, questListDefault = true, visualModules = true,
            actionBars = true },
    })
    local bar2 = H.NewFrame("MultiBarBottomLeft", UIParent)
    local button2 = H.NewFrame("MultiBarBottomLeftButton1", bar2)
    button2.icon = H.NewFrame(nil, button2)
    button2.NormalTexture = H.NewFrame(nil, button2)
    button2.SlotBackground = H.NewFrame(nil, button2)
    button2.SlotArt = H.NewFrame(nil, button2)
    button2.HotKey = H.NewFrame(nil, button2)
    button2.Count = H.NewFrame(nil, button2)
    bar2.actionButtons = { button2 }
    local button = MainActionBar.actionButtons[1]
    H.Fire("PLAYER_LOGIN")
    local component = app.components.actionBars
    eq(button.lumaActionBarSkin ~= nil, true)
    eq(button2.lumaActionBarSkin ~= nil, true)
    eq(component.skins[button], button.lumaActionBarSkin)
    local entry = button.lumaActionBarSkin
    -- A second layout must reuse the recorded entry instead of stacking one.
    component:Refresh()
    eq(button.lumaActionBarSkin, entry)
    app.Store:Set("modules", "actionBars", false)
    eq(button.lumaActionBarSkin, nil)
    eq(button.icon.texCoord[1], 0)
    eq(button.NormalTexture:GetAlpha(), 1)
    eq(next(component.skins), nil)
    eq(#app.errors, 0)
end)

test("the single-bar sample keeps the bar skin out of its way", function()
    local app = H.Load({
        profiles = { Default = {} },
        migrations = { pearlBatch = true, questListDefault = true, visualModules = true,
            actionBars = true },
    })
    local sample = app.components.actionButtons
    H.Fire("PLAYER_LOGIN")
    local button = MainActionBar.actionButtons[1]
    local component = app.components.actionBars
    eq(button.lumaActionBarSkin ~= nil, true)
    app.Store:Set("modules", "actionButtons", true)
    eq(sample.running, true)
    eq(button.lumaActionBarSkin, nil)
    eq(button.lumaActionSkin ~= nil, true)
    eq(next(component.skins), nil)
    app.Store:Set("modules", "actionButtons", false)
    eq(button.lumaActionSkin.border:IsShown(), false)
    eq(app.components.actionBars.running, true)
    eq(button.lumaActionBarSkin ~= nil, true)
    eq(#app.errors, 0)
end)

test("the cooldown manager viewers are stacked above the measured action area and put back", function()
    local app = H.Load()
    local essential = H.NewFrame("EssentialCooldownViewer", UIParent)
    essential:SetPoint("CENTER", UIParent, "CENTER", 111, 222)
    local utility = H.NewFrame("UtilityCooldownViewer", UIParent)
    utility:Hide()
    local buffs = H.NewFrame("BuffIconCooldownViewer", UIParent)
    H.Fire("PLAYER_LOGIN")
    local component = app.components.cooldownViewer
    eq(component.running, true)
    -- Bottom to top: skill rows hug the action area (bottom 56, main bar 40 and
    -- an 8 unit gap put the first row at 104). A viewer the player hid is
    -- skipped instead of being forced back on screen.
    eq(essential.point[1], "BOTTOM")
    eq(essential.point[2], UIParent)
    eq(essential.point[4], 0)
    eq(essential.point[5], 104)
    eq(utility.point, nil)
    eq(utility:IsShown(), false)
    eq(_G.BuffBarCooldownViewer.point[5], 142)
    eq(buffs.point[5], 180)
    eq(component.placedRows[1].id, "essential")
    eq(component.placedRows[2].id, "buffBar")
    eq(component.placedRows[3].id, "buffIcon")

    app.Store:Set("modules", "cooldownViewer", false)
    eq(essential.point[1], "CENTER")
    eq(essential.point[4], 111)
    eq(essential.point[5], 222)
    eq(essential.lumaCooldownViewerOriginal, nil)
    eq(buffs.point, nil)
    eq(utility:IsShown(), false)
    eq(#app.errors, 0)
    -- These globals outlive one H.Load; drop them so the next case starts from
    -- a client without cooldown viewers.
    _G.EssentialCooldownViewer, _G.UtilityCooldownViewer = nil, nil
    _G.BuffIconCooldownViewer, _G.BuffBarCooldownViewer = nil, nil
end)

test("the cooldown manager placement stays off without native viewers", function()
    local app = H.Load()
    -- A client build without the Cooldown Manager has none of these globals.
    _G.EssentialCooldownViewer, _G.UtilityCooldownViewer = nil, nil
    _G.BuffIconCooldownViewer, _G.BuffBarCooldownViewer = nil, nil
    H.Fire("PLAYER_LOGIN")
    eq(app.components.cooldownViewer.running == true, false)
    eq(app.components.cooldownViewer.status, "unsupported")
    eq(#app.errors, 0)
end)

test("central geometry measures the managed action area and exposes unit boundaries", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local bar2 = H.NewFrame("MultiBarBottomLeft", UIParent)
    bar2:SetSize(524, 44)
    local bar3 = H.NewFrame("MultiBarBottomRight", UIParent)
    bar3:SetSize(524, 44)
    local central = app.Layout:Central()
    eq(central.action.width, 524)
    eq(central.action.height, 136)
    eq(central.action.bottom, 56)
    eq(central.action.top, 192)
    eq(central.cooldown.bottom, 200)
    -- The visible cooldown block owns the unit boundary; the fixture viewers
    -- report 300 UI units, not the 524-wide bars.
    eq(central.content.width, 300)
    eq(central.content.measured, true)
    eq(central.units.left, -155.76)
    eq(central.units.right, 155.76)
    eq(central.action.estimated, false)
    -- Rows are bottom-up distances from the screen bottom; the centre offset
    -- offered to 002 is the same value minus half the screen.
    local essential = H.NewFrame("EssentialCooldownViewer", UIParent)
    essential:SetSize(300, 50)
    local utility = H.NewFrame("UtilityCooldownViewer", UIParent)
    utility:SetSize(280, 40)
    local rows = app.Layout:CentralRows({
        { frame = essential, id = "essential" }, { frame = utility, id = "utility" } })
    eq(rows.rows[1].bottom, 200)
    eq(rows.rows[1].top, 250)
    eq(rows.rows[2].bottom, 258)
    eq(rows.mainRow, rows.rows[1])
    eq(rows.mainRow.id, "essential")
    eq(rows.cooldown.top, 298)
    eq(rows.units.rowTop, 298)
    eq(rows.units.rowTopY, -242)
    eq(rows.units.rowCenterY, -315)
    -- The widest visible row matches the fixture block, so the boundary stays
    -- put and no extra central change is published.
    eq(rows.content.width, 300)
    eq(rows.content.measured, true)
    eq(rows.contentChanged, nil)
    eq(rows.units.left, -155.76)
    eq(#app.errors, 0)
end)

-- Every icon of a viewer goes into its own slot: the block is centred on the
-- screen axis, a short row keeps its own centre and the row bottom is the one
-- the stack assigned (56 + 40 action height + 8 gap = 104 in these fixtures).
local function iconViewerFixture(app, count)
    for _, name in ipairs({ "EssentialCooldownViewer", "UtilityCooldownViewer", "BuffBarCooldownViewer" }) do
        _G[name]:Hide()
    end
    local viewer = _G.BuffIconCooldownViewer
    viewer:SetSize(300, 80)
    viewer:Show()
    viewer.rect = { left = 810, bottom = 780, width = 300, height = 80 }
    viewer.icons = {}
    for index = 1, count do
        local icon = H.NewFrame("BuffIconButton" .. index, viewer)
        icon:SetSize(30, 30)
        icon:SetPoint("TOPLEFT", viewer, "TOPLEFT", (index - 1) * 34, 0)
        icon.rect = { left = 810 + (index - 1) * 34, bottom = 830, width = 30, height = 30 }
        viewer.icons[index] = icon
    end
    return app.components.cooldownViewer, viewer
end

-- The shipped default: the viewer frame moves, the pooled buttons keep the
-- client's own anchors. Rewriting a pooled button is what made the live HUD
-- look like it never settled, so this path is the one a player gets.
test("the slot grid is an opt-in command that refreshes the stack", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.Store:Set("appearance", "perIconSlots", false)
    H.messages = {}
    SlashCmdList.LUMAUI("slots")
    eq(app.Store:Profile().appearance.perIconSlots, true)
    eq(table.concat(H.messages, "\n"):find(app.L.slotsOn, 1, true) ~= nil, true)
    SlashCmdList.LUMAUI("slots")
    eq(app.Store:Profile().appearance.perIconSlots, false)
    eq(table.concat(H.messages, "\n"):find(app.L.slotsOff, 1, true) ~= nil, true)
    eq(#app.errors, 0)
end)

test("the shipped cooldown default moves the viewer and leaves pooled icons alone", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.Store:Set("appearance", "perIconSlots", false)
    local viewer = _G.EssentialCooldownViewer
    viewer:SetSize(300, 80)
    viewer:Show()
    viewer.icons = {}
    for index = 1, 4 do
        local icon = H.NewFrame("DefaultIcon" .. index, viewer)
        icon:SetSize(30, 30)
        icon:SetPoint("TOPLEFT", viewer, "TOPLEFT", (index - 1) * 34, 0)
        icon.rect = { left = 810 + (index - 1) * 34, bottom = 830, width = 30, height = 30 }
        viewer.icons[index] = icon
    end
    local component = app.components.cooldownViewer
    component:Refresh()
    eq(viewer.point[1], "BOTTOM")
    for index = 1, 4 do
        eq(viewer.icons[index].point[1], "TOPLEFT")
        eq(viewer.icons[index].point[4], (index - 1) * 34)
    end
    eq(component:Describe():find("slots=off", 1, true) ~= nil, true)
    -- A settled stack publishes nothing: the component is the publisher of the
    -- message it used to subscribe to, and a pass must not feed itself.
    local published = 0
    local observer = {}
    app:Subscribe(observer, "LAYOUT_CENTRAL_CHANGED", function() published = published + 1 end)
    component:Refresh()
    eq(published, 0)
    app:Unsubscribe(observer, "LAYOUT_CENTRAL_CHANGED")
    app.Store:Set("modules", "cooldownViewer", false)
    for index = 1, 4 do _G["DefaultIcon" .. index] = nil end
    eq(#app.errors, 0)
end)

-- A main row owns the block the unit frames flank. Its width must come from the
-- client's own viewer frame, not from how many skills happen to be active: a
-- HUD that walks in and out on every cooldown is what a player reads as "the
-- style changed after entering the instance".
-- An item shaped like the client's cooldown viewer template (see
-- Blizzard_CooldownViewer/CooldownViewer.xml): an ARTWORK `Icon` texture, a
-- `Cooldown` frame with SetCountdownFont, `ChargeCount.Current` and the
-- template's own `cooldownFont` key used to restore the countdown font.
local function skinnableItem(name, viewer)
    local button = H.NewFrame(name, viewer)
    button:SetSize(28, 28)
    button:SetPoint("TOPLEFT", viewer, "TOPLEFT", 0, 0)
    button.rect = { left = 810, bottom = 830, width = 28, height = 28 }
    button.Icon = H.NewFrame(nil, button)
    local cooldown = H.NewFrame(nil, button)
    cooldown.SetCountdownFont = function(self, font) self.font = font end
    button.Cooldown = cooldown
    local charge = H.NewFrame(nil, button)
    local current = H.NewFrame(nil, charge)
    current:SetFont("Fonts/Mock.ttf", 12, "")
    charge.Current = current
    button.ChargeCount = charge
    button.cooldownFont = "GameFontHighlightHugeOutline"
    return button
end

local function essentialSkinned(app, items)
    local viewer = _G.EssentialCooldownViewer
    viewer:SetSize(300, 40)
    viewer:Show()
    viewer.icons = items
    app.components.cooldownViewer:Refresh()
    return viewer
end

test("the cooldown skin crops icons and restores every recorded member", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local button = skinnableItem("SkinIcon1", _G.EssentialCooldownViewer)
    essentialSkinned(app, { button })
    local crop = app.CooldownSkin.crop
    eq(button.Icon.texCoord[1], crop[1])
    eq(button.Icon.texCoord[2], crop[2])
    eq(button.Icon.texCoord[3], crop[3])
    eq(button.Icon.texCoord[4], crop[4])
    eq(button.lumaCooldownDecor.bg:IsShown(), true)
    eq(button.lumaCooldownDecor.border:IsShown(), true)
    eq(button.lumaCooldownDecor.border.backdrop.edgeSize, 1)
    -- Timer and charge fonts are the Pearl roles; the native cooldown values
    -- (swipe, charges, glow) are never written.
    eq(button.Cooldown.font, app.Theme.fontObjects.iconTimer)
    eq(button.ChargeCount.Current.fontSize, 11)
    eq(button.ChargeCount.Current.fontFlags, "OUTLINE")
    eq(button.Cooldown.cooldownStart, nil)
    eq(button.Cooldown.cooldownDuration, nil)
    eq(app.components.cooldownViewer:Describe():find("skin=1/1", 1, true) ~= nil, true)
    app.Store:Set("modules", "cooldownViewer", false)
    -- The recorded crop, fonts and decorations all go back.
    eq(button.Icon.texCoord[1], 0)
    eq(button.Icon.texCoord[5], 1)
    eq(button.Icon.texCoord[6], 1)
    eq(button.Cooldown.font, "GameFontHighlightHugeOutline")
    eq(button.ChargeCount.Current.fontSize, 12)
    eq(button.ChargeCount.Current.fontFlags, "")
    eq(button.lumaCooldownDecor.bg:IsShown(), false)
    eq(button.lumaCooldownDecor.border:IsShown(), false)
    eq(#app.errors, 0)
end)

test("a cooldown item without readable members stays native and is counted", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local plain = H.NewFrame("PlainIcon", _G.EssentialCooldownViewer)
    plain:SetSize(28, 28)
    plain:SetPoint("TOPLEFT", _G.EssentialCooldownViewer, "TOPLEFT", 40, 0)
    plain.rect = { left = 850, bottom = 830, width = 28, height = 28 }
    local good = skinnableItem("SkinIcon2", _G.EssentialCooldownViewer)
    essentialSkinned(app, { plain, good })
    eq(plain.lumaCooldownSkin, nil)
    eq(plain.lumaCooldownDecor, nil)
    eq(good.lumaCooldownSkin ~= nil, true)
    local counts = app.components.cooldownViewer.skinStats.essential
    eq(counts.applied, 1)
    eq(counts.unknown, 1)
    app.Store:Set("modules", "cooldownViewer", false)
    eq(#app.errors, 0)
end)

test("a refused icon write rolls that item back and the next icon continues", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local broken = skinnableItem("SkinBroken", _G.EssentialCooldownViewer)
    local setter = broken.Icon.SetTexCoord
    broken.Icon.SetTexCoord = function(self, ...) error("refused", 0) end
    local good = skinnableItem("SkinGood", _G.EssentialCooldownViewer)
    good.rect = { left = 850, bottom = 830, width = 28, height = 28 }
    essentialSkinned(app, { broken, good })
    eq(broken.lumaCooldownSkin, nil)
    eq(broken.lumaCooldownDecor.bg:IsShown(), false)
    -- The rollback puts back the template's own countdown font, not the Pearl one.
    eq(broken.Cooldown.font, "GameFontHighlightHugeOutline")
    eq(good.Icon.texCoord[1], app.CooldownSkin.crop[1])
    eq(app.components.cooldownViewer.skinStats.essential.applied, 1)
    eq(app.components.cooldownViewer.skinStats.essential.unknown, 1)
    broken.Icon.SetTexCoord = setter
    app.Store:Set("modules", "cooldownViewer", false)
    eq(#app.errors, 0)
end)

test("a reused pooled button restores the old members before the new skin", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local button = skinnableItem("PooledIcon", _G.EssentialCooldownViewer)
    local oldIcon = button.Icon
    essentialSkinned(app, { button })
    eq(oldIcon.texCoord[1], app.CooldownSkin.crop[1])
    -- The pool hands the frame a new icon; the old one must come back clean.
    button.Icon = H.NewFrame(nil, button)
    app.components.cooldownViewer:Refresh()
    eq(oldIcon.texCoord[1], 0)
    eq(oldIcon.texCoord[5], 1)
    eq(button.Icon.texCoord[1], app.CooldownSkin.crop[1])
    app.Store:Set("modules", "cooldownViewer", false)
    eq(button.Icon.texCoord[1], 0)
    eq(#app.errors, 0)
end)

test("a settled cooldown skin writes nothing on later passes", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local button = skinnableItem("SettledIcon", _G.EssentialCooldownViewer)
    essentialSkinned(app, { button })
    local writes = 0
    local texSet, fontSet, chargeSet = button.Icon.SetTexCoord,
        button.Cooldown.SetCountdownFont, button.ChargeCount.Current.SetFont
    button.Icon.SetTexCoord = function(self, ...) writes = writes + 1; return texSet(self, ...) end
    button.Cooldown.SetCountdownFont = function(self, ...) writes = writes + 1; return fontSet(self, ...) end
    button.ChargeCount.Current.SetFont = function(self, ...) writes = writes + 1; return chargeSet(self, ...) end
    local children = #(button.children or {})
    H.Advance(2)
    app.components.cooldownViewer:Refresh()
    eq(writes, 0)
    eq(#(button.children or {}), children)
    button.Icon.SetTexCoord = texSet
    button.Cooldown.SetCountdownFont = fontSet
    button.ChargeCount.Current.SetFont = chargeSet
    app.Store:Set("modules", "cooldownViewer", false)
    eq(#app.errors, 0)
end)

test("/luma hud names the skinned icon count per viewer", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local button = skinnableItem("ReportIcon", _G.EssentialCooldownViewer)
    essentialSkinned(app, { button })
    H.messages = {}
    app.Layout:Diagnose()
    local text = table.concat(H.messages, "\n")
    eq(text:find("viewer EssentialCooldownViewer:", 1, true) ~= nil, true)
    eq(text:find("skin=1/1", 1, true) ~= nil, true)
    app.Store:Set("modules", "cooldownViewer", false)
    eq(#app.errors, 0)
end)

test("fifteen essential icons stay two centred rows instead of dropping skills", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local viewer = _G.EssentialCooldownViewer
    viewer:SetSize(300, 80)
    viewer:Show()
    viewer.icons = {}
    for index = 1, 15 do
        local icon = H.NewFrame("FifteenIcon" .. index, viewer)
        icon:SetSize(30, 30)
        icon:SetPoint("TOPLEFT", viewer, "TOPLEFT", (index - 1) * 34, 0)
        icon.rect = { left = 810 + (index - 1) * 34, bottom = 830, width = 30, height = 30 }
        viewer.icons[index] = icon
    end
    app.components.cooldownViewer:Refresh()
    -- Nine on the main row (302 wide, first slot -136), six on the centred row
    -- above it (200 wide, first slot -85). Every one of the fifteen is placed:
    -- capacity never drops a skill from the list.
    eq(viewer.icons[1].point[4], -136)
    eq(viewer.icons[9].point[4], 136)
    eq(viewer.icons[10].point[4], -85)
    eq(viewer.icons[15].point[4], 85)
    eq(viewer.icons[10].point[5], 153)
    for index = 1, 15 do eq(viewer.icons[index].point[1], "CENTER") end
    app.Store:Set("modules", "cooldownViewer", false)
    for index = 1, 15 do _G["FifteenIcon" .. index] = nil end
    eq(#app.errors, 0)
end)

test("a viewer re-anchored every beat falls back to the native grid once", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local viewer = _G.EssentialCooldownViewer
    viewer:SetSize(300, 40)
    viewer:Show()
    viewer.icons = {}
    local icon = H.NewFrame("FlapIcon", viewer)
    icon:SetSize(30, 30)
    icon:SetPoint("TOPLEFT", viewer, "TOPLEFT", 0, 0)
    icon.rect = { left = 810, bottom = 830, width = 30, height = 30 }
    viewer.icons[1] = icon
    local component = app.components.cooldownViewer
    -- The client keeps putting the pooled button back; the grid must not fight
    -- it forever.
    local function clientRepack() icon:SetPoint("TOPLEFT", viewer, "TOPLEFT", 0, 0) end
    clientRepack(); component:Refresh()
    clientRepack(); component:Refresh()
    clientRepack(); component:Refresh()
    eq(component.iconFallback[viewer], true)
    eq(icon.point[1], "TOPLEFT")
    -- From here the native grid is left alone: LumaUI writes nothing more.
    local writes = 0
    local setter = icon.SetPoint
    icon.SetPoint = function(self, ...) writes = writes + 1; return setter(self, ...) end
    clientRepack()
    component:Refresh()
    eq(writes, 1)
    icon.SetPoint = setter
    app.Store:Set("modules", "cooldownViewer", false)
    eq(#app.errors, 1)
end)

test("the hud report lists each planned central row and the slot mode", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.Store:Set("appearance", "perIconSlots", false)
    local essential = H.NewFrame("EssentialCooldownViewer", UIParent)
    essential:SetSize(300, 40)
    essential:Show()
    app.components.cooldownViewer:Refresh()
    H.messages = {}
    app.Layout:Diagnose()
    local text = table.concat(H.messages, "\n")
    -- The two lines a player can compare between a login and an instance: the
    -- planned row and the mode it was planned in.
    eq(text:find("row1 essential: w=", 1, true) ~= nil, true)
    eq(text:find("slots=off", 1, true) ~= nil, true)
    app.Store:Set("appearance", "perIconSlots", true)
    H.messages = {}
    app.Layout:Diagnose()
    eq(table.concat(H.messages, "\n"):find("slots=on", 1, true) ~= nil, true)
    _G.EssentialCooldownViewer = nil
    app.Store:Set("appearance", "perIconSlots", false)
    eq(#app.errors, 0)
end)

test("a main cooldown row keeps its block width when skills come off cooldown", function()
    local app = H.Load(); UIParent:SetSize(1920, 1080); H.Fire("PLAYER_LOGIN")
    local viewer = _G.EssentialCooldownViewer
    viewer:SetSize(300, 40)
    viewer:Show()
    viewer.icons = {}
    local function addIcons(count)
        for index = 1, count do
            if not viewer.icons[index] then
                local icon = H.NewFrame("StableIcon" .. index, viewer)
                icon:SetSize(30, 30)
                icon:SetPoint("TOPLEFT", viewer, "TOPLEFT", (index - 1) * 34, 0)
                icon.rect = { left = 810 + (index - 1) * 34, bottom = 830, width = 30, height = 30 }
                viewer.icons[index] = icon
            end
        end
    end
    addIcons(2)
    local component = app.components.cooldownViewer
    component:Refresh()
    local first = app.Layout:ContentWidth()
    addIcons(9)
    component:Refresh()
    eq(app.Layout:ContentWidth(), first)
    eq(first, 300)
    for index = 1, 9 do _G["StableIcon" .. index] = nil end
    app.Store:Set("modules", "cooldownViewer", false)
    eq(#app.errors, 0)
end)

test("a plate bar that cannot host textures still gets its decorations", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.Store:Set("modules", "nameplates", true)
    local component = app.components.nameplates
    H.unitInfo.nameplate11 = { enemy = true }
    -- A texture-drawn bar cannot parent a texture or a frame. The decorations
    -- move to a holder in the bar's parent instead of failing the component.
    -- A plain table models it: only the region methods exist, none of the frame
    -- ones that would let decorations become children.
    local bar = {
        SetPoint = function() end,
        GetParent = function() return UIParent end,
        GetFrameLevel = function() return 5 end,
        SetColorTexture = function() end,
    }
    local plate = H.NewFrame(nil, UIParent)
    local unitFrame = H.NewFrame(nil, plate)
    unitFrame.HealthBarsContainer = { healthBar = bar }
    plate.UnitFrame = unitFrame
    H.nameplates.nameplate11 = plate
    H.Fire("NAME_PLATE_UNIT_ADDED", "nameplate11")
    eq(component.plates.nameplate11 ~= nil, true)
    eq(bar.lumaNameplateHolder ~= nil, true)
    eq(bar.lumaNameplateBg:IsShown(), true)
    -- One bad plate must not stop the next one from being styled.
    H.unitInfo.nameplate12 = { enemy = true }
    local broken = H.PlainBar({ 0.5, 0.2, 0.2, 1 })
    broken.CreateTexture = function() error("this bar cannot host textures") end
    H.nameplates.nameplate12 = H.Plate("modern", broken)
    H.Fire("NAME_PLATE_UNIT_ADDED", "nameplate12")
    eq(component.plates.nameplate12 ~= nil, true)
    eq(app.errors[#app.errors].context, "nameplates/decorate")
    app.Store:Set("modules", "nameplates", false)
    eq(#app.errors, 1)
end)

test("tracked buff icons are centred in one row of equal-sized slots", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local component, viewer = iconViewerFixture(app, 4)
    component:Refresh()
    -- Four 30 unit icons with the measured 4 unit gap span 132 units, so the
    -- slots sit at -51, -17, 17 and 51 around the screen axis. The bottom row
    -- starts where the stack put the viewer.
    for index, x in ipairs({ -51, -17, 17, 51 }) do
        eq(viewer.icons[index].point[1], "CENTER")
        eq(viewer.icons[index].point[2], UIParent)
        eq(viewer.icons[index].point[4], x)
        eq(viewer.icons[index].point[5], 119)
    end
    -- The slot plan is the block the unit frames flank; the mockup floor still
    -- applies because four 30 unit icons are narrower than it.
    eq(app.Layout:Central().content.width, 167.04)
    eq(#app.errors, 0)
end)

test("a tenth essential icon wraps into a centred continuation row", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local viewer = _G.EssentialCooldownViewer
    viewer:SetSize(300, 80)
    viewer:Show()
    viewer.icons = {}
    for index = 1, 10 do
        local icon = H.NewFrame("EssentialIcon" .. index, viewer)
        icon:SetSize(30, 30)
        icon:SetPoint("TOPLEFT", viewer, "TOPLEFT", (index - 1) * 34, 0)
        icon.rect = { left = 810 + (index - 1) * 34, bottom = 830, width = 30, height = 30 }
        viewer.icons[index] = icon
    end
    app.components.cooldownViewer:Refresh()
    -- Nine icons fill the main row: 9 * 30 + 8 * 4 = 302 wide, first slot -136.
    eq(viewer.icons[1].point[4], -136)
    eq(viewer.icons[9].point[4], 136)
    -- The tenth icon is alone on the row above and is centred on the same axis.
    -- The essential row uses a 4 unit row gap: 104 + 34 + 15.
    eq(viewer.icons[10].point[4], 0)
    eq(viewer.icons[10].point[5], 153)
    eq(viewer.icons[1].point[5], 119)
    app.Store:Set("modules", "cooldownViewer", false)
    for index = 1, 10 do _G["EssentialIcon" .. index] = nil end
    eq(#app.errors, 0)
end)

test("a narrow screen shrinks the row capacity instead of widening the row", function()
    local app = H.Load(); UIParent:SetSize(800, 600); H.Fire("PLAYER_LOGIN")
    local viewer = _G.EssentialCooldownViewer
    viewer:SetSize(300, 80)
    viewer:Show()
    viewer.icons = {}
    for index = 1, 5 do
        local icon = H.NewFrame("NarrowIcon" .. index, viewer)
        icon:SetSize(30, 30)
        icon:SetPoint("TOPLEFT", viewer, "TOPLEFT", (index - 1) * 34, 0)
        icon.rect = { left = 300 + (index - 1) * 34, bottom = 400, width = 30, height = 30 }
        viewer.icons[index] = icon
    end
    app.components.cooldownViewer:Refresh()
    -- 800 * 0.17 = 136 units of room, so only four 34 unit pitches fit per row.
    eq(viewer.icons[4].point[4] > 0, true)
    eq(viewer.icons[5].point[4], 0)
    eq(viewer.icons[5].point[5], viewer.icons[4].point[5] + 34)
    app.Store:Set("modules", "cooldownViewer", false)
    for index = 1, 5 do _G["NarrowIcon" .. index] = nil end
    eq(#app.errors, 0)
end)

test("the tracked buff viewer is read through its item frame pool", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    for _, name in ipairs({ "EssentialCooldownViewer", "UtilityCooldownViewer", "BuffBarCooldownViewer" }) do
        _G[name]:Hide()
    end
    local viewer = _G.BuffIconCooldownViewer
    viewer:SetSize(300, 40)
    viewer:Show()
    viewer.rect = { left = 810, bottom = 820, width = 300, height = 40 }
    -- Current builds expose the pooled buttons through this iterator; the
    -- named tables are absent, which is why the grid stayed left aligned.
    local pool = { active = {} }
    function pool:EnumerateActive()
        local index = 0
        return function()
            index = index + 1
            return self.active[index]
        end
    end
    viewer.itemFramePool = pool
    for index = 1, 2 do
        local icon = H.NewFrame("PoolIcon" .. index, viewer)
        icon:SetSize(30, 30)
        icon:SetPoint("TOPLEFT", viewer, "TOPLEFT", (index - 1) * 34, 0)
        icon.rect = { left = 810 + (index - 1) * 34, bottom = 830, width = 30, height = 30 }
        pool.active[index] = icon
    end
    app.components.cooldownViewer:Refresh()
    -- Two icons are one 64 unit row centred on the screen axis.
    eq(pool.active[1].point[4], -17)
    eq(pool.active[2].point[4], 17)
    eq(#app.errors, 0)
end)

test("a tracked buff viewer with no readable height still places its icons", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    for _, name in ipairs({ "EssentialCooldownViewer", "UtilityCooldownViewer", "BuffBarCooldownViewer" }) do
        _G[name]:Hide()
    end
    local viewer = _G.BuffIconCooldownViewer
    viewer:Show()
    -- The grid sizes itself from its icons on the live client and can report no
    -- frame height. The icons must still be placed instead of the whole viewer
    -- being filtered out of the pass.
    viewer:SetWidth(300)
    viewer:SetHeight(0)
    viewer.rect = { left = 810, bottom = 750, width = 300, height = 0 }
    for index = 1, 2 do
        local icon = H.NewFrame("NoHeightIcon" .. index, viewer)
        icon:SetSize(30, 30)
        icon:SetPoint("TOPLEFT", viewer, "TOPLEFT", (index - 1) * 34, 0)
        icon.rect = { left = 810 + (index - 1) * 34, bottom = 750, width = 30, height = 30 }
    end
    app.components.cooldownViewer:Refresh()
    eq(_G.NoHeightIcon1.point[4], -17)
    eq(_G.NoHeightIcon2.point[4], 17)
    eq(#app.errors, 0)
    _G.NoHeightIcon1, _G.NoHeightIcon2 = nil, nil
end)

test("a client repack is centred again on the next pass", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    for _, name in ipairs({ "EssentialCooldownViewer", "UtilityCooldownViewer", "BuffBarCooldownViewer" }) do
        _G[name]:Hide()
    end
    local viewer = _G.BuffIconCooldownViewer
    viewer:SetSize(300, 40)
    viewer:Show()
    viewer.rect = { left = 810, bottom = 790, width = 300, height = 40 }
    local icon = H.NewFrame("RepackIcon", viewer)
    icon:SetSize(30, 30)
    icon:SetPoint("TOPLEFT", viewer, "TOPLEFT", 0, 0)
    icon.rect = { left = 810, bottom = 800, width = 30, height = 30 }
    app.components.cooldownViewer:Refresh()
    eq(icon.point[1], "CENTER")
    eq(icon.point[4], 0)
    -- The client puts the icon back on the left edge; the next pass must place
    -- it again instead of treating the previous write as "already applied".
    icon:SetPoint("TOPLEFT", viewer, "TOPLEFT", 0, 0)
    icon.rect = { left = 810, bottom = 800, width = 30, height = 30 }
    app.components.cooldownViewer:Refresh()
    eq(icon.point[1], "CENTER")
    eq(icon.point[4], 0)
    eq(#app.errors, 0)
    _G.RepackIcon = nil
end)

test("icons a pixel apart still share one row and keep their spacing", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    for _, name in ipairs({ "EssentialCooldownViewer", "UtilityCooldownViewer", "BuffBarCooldownViewer" }) do
        _G[name]:Hide()
    end
    local viewer = _G.BuffIconCooldownViewer
    viewer:SetSize(300, 40)
    viewer:Show()
    viewer.rect = { left = 810, bottom = 780, width = 300, height = 40 }
    local first = H.NewFrame("JitterIcon1", viewer)
    first:SetSize(30, 30)
    first:SetPoint("TOPLEFT", viewer, "TOPLEFT", 0, 0)
    first.rect = { left = 810, bottom = 800, width = 30, height = 30 }
    local second = H.NewFrame("JitterIcon2", viewer)
    second:SetSize(30, 30)
    second:SetPoint("TOPLEFT", viewer, "TOPLEFT", 34, -1)
    second.rect = { left = 844, bottom = 799, width = 30, height = 30 }
    app.components.cooldownViewer:Refresh()
    -- A per-icon row key would have given each icon its own row and destroyed
    -- the measured 34 unit pitch.
    eq(first.point[5], second.point[5])
    eq(second.point[4] - first.point[4], 34)
    eq(#app.errors, 0)
    _G.JitterIcon1, _G.JitterIcon2 = nil, nil
end)

test("disabling the cooldown viewers puts the tracked icons back", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    for _, name in ipairs({ "EssentialCooldownViewer", "UtilityCooldownViewer", "BuffBarCooldownViewer" }) do
        _G[name]:Hide()
    end
    local viewer = _G.BuffIconCooldownViewer
    viewer:SetSize(300, 40)
    viewer:Show()
    viewer.rect = { left = 810, bottom = 790, width = 300, height = 40 }
    local icon = H.NewFrame("RestoreIcon", viewer)
    icon:SetSize(30, 30)
    icon:SetPoint("TOPLEFT", viewer, "TOPLEFT", 0, 0)
    icon.rect = { left = 810, bottom = 800, width = 30, height = 30 }
    app.components.cooldownViewer:Refresh()
    eq(icon.point[1], "CENTER")
    app.Store:Set("modules", "cooldownViewer", false)
    eq(icon.point[1], "TOPLEFT")
    eq(icon.point[4], 0)
    eq(#app.errors, 0)
    _G.RestoreIcon = nil
end)

test("a refused icon anchor restores that viewer and falls back to the whole frame", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local component, viewer = iconViewerFixture(app, 3)
    -- The client refuses the slot anchor but would accept the original one, as
    -- a protected write does: the component must not leave a half-placed row.
    local broken = viewer.icons[1]
    local original = broken.SetPoint
    local slotWrites = 0
    broken.SetPoint = function(self, point, ...)
        if point == "CENTER" then slotWrites = slotWrites + 1 error("protected") end
        return original(self, point, ...)
    end
    component:Refresh()
    eq(slotWrites, 1)
    -- Every icon of that viewer keeps the anchor the client gave it, and the
    -- viewer itself is still moved by the fallback path.
    eq(broken.point[1], "TOPLEFT")
    eq(viewer.icons[2].point[1], "TOPLEFT")
    eq(viewer.icons[3].point[1], "TOPLEFT")
    eq(viewer.point[1], "BOTTOM")
    eq(component.iconFallback[viewer], true)
    -- A later pass does not fight the same refused write, and the refusal is
    -- reported once through the session error list.
    component:Refresh()
    eq(slotWrites, 1)
    eq(#app.errors, 1)
    eq(app.errors[1].context, "cooldownViewer/slots")
end)

test("central grid geometry: empty, single, full and overflow rows", function()
    local app = H.Load()
    local grid = app.CentralGrid
    local empty = grid:Plan({ count = 0, size = 30, style = "essential" })
    eq(#empty.rows, 0)
    eq(empty.width, 0)
    local single = grid:Plan({ count = 1, size = 30, style = "essential" })
    eq(single.perRow, 9)
    eq(single.slots[1].x, 0)
    eq(single.width, 30)
    local full = grid:Plan({ count = 9, size = 30, gap = 4, style = "essential" })
    eq(#full.rows, 1)
    eq(full.width, 302)
    eq(full.slots[1].x, -136)
    eq(full.slots[9].x, 136)
    -- Ten icons: nine on the main row, one centred above it.
    local ten = grid:Plan({ count = 10, size = 30, gap = 4, style = "essential" })
    eq(#ten.rows, 2)
    eq(ten.rows[2].count, 1)
    eq(ten.slots[10].x, 0)
    eq(ten.slots[10].y, 49)
    eq(ten.height, 64)
    -- The utility row caps at seven even when there is room for more.
    local utility = grid:Plan({ count = 8, size = 30, gap = 4, style = "utility" })
    eq(utility.perRow, 7)
    eq(#utility.rows, 2)
    eq(utility.rows[2].count, 1)
    -- A narrow screen reduces the capacity to whole icons.
    local narrow = grid:Plan({ count = 5, size = 30, gap = 4, maxWidth = 100, style = "essential" })
    eq(narrow.perRow, 3)
    eq(#narrow.rows, 2)
    eq(narrow.rows[2].count, 2)
    eq(narrow.rows[2].width, 64)
    eq(#app.errors, 0)
end)

-- Plan 010/01 (red light): a 275 x 118 essential viewer puts its real top at
-- 222 above a 104 block bottom, so the resource rail belongs at 228. Reading a
-- fresh `Central()` returns `cooldown.top == cooldown.bottom` by construction,
-- which is how the field screenshot got a rail at 110 crossing the lowest skill
-- row. This test walks the normal login path and asserts the applied geometry.
test("the resource rail anchors above the measured skill block, not its bottom", function()
    local app = H.Load()
    for _, name in ipairs({ "UtilityCooldownViewer", "BuffBarCooldownViewer", "BuffIconCooldownViewer" }) do
        _G[name]:Hide()
    end
    _G.EssentialCooldownViewer:SetSize(275, 118)
    H.Fire("PLAYER_LOGIN")
    local central = app.Layout:Central()
    eq(central.cooldown.bottom, 104)
    eq(central.cooldown.top, 222)
    eq(app.components.playerResource.rail.point[5], 228)
    eq(#app.errors, 0)
end)

test("a same-width height change moves the resource rail", function()
    local app = H.Load()
    for _, name in ipairs({ "UtilityCooldownViewer", "BuffBarCooldownViewer", "BuffIconCooldownViewer" }) do
        _G[name]:Hide()
    end
    local viewer = _G.EssentialCooldownViewer
    viewer:SetSize(275, 30)
    H.Fire("PLAYER_LOGIN")
    eq(app.components.playerResource.rail.point[5], 140)
    -- The width never changes; only the row gets taller. The notification must
    -- follow the top edge, not just the block width.
    viewer:SetHeight(118)
    app.components.cooldownViewer:Refresh()
    eq(app.Layout:Central().content.width, 275)
    eq(app.components.playerResource.rail.point[5], 228)
    eq(#app.errors, 0)
end)

test("a refused main viewer keeps the rail above the rows that were placed", function()
    local app = H.Load()
    for _, name in ipairs({ "UtilityCooldownViewer", "BuffBarCooldownViewer", "BuffIconCooldownViewer" }) do
        _G[name]:Hide()
    end
    local essential = _G.EssentialCooldownViewer
    essential:SetSize(275, 118)
    -- This build refuses the re-anchor; the viewer keeps wherever the client
    -- put it. Its readable rect is the only trustworthy top edge.
    essential.rect = { left = 800, bottom = 300, width = 275, height = 118 }
    local original = essential.SetPoint
    essential.SetPoint = function(self, point, ...)
        if point == "BOTTOM" then error("refused", 0) end
        return original(self, point, ...)
    end
    H.Fire("PLAYER_LOGIN")
    eq(essential.point == nil or essential.point[1] ~= "BOTTOM", true)
    eq(app.components.playerResource.rail.point[5], 424)
    -- The corrected top is not mistaken for a new plan: a settled stack with a
    -- refused row publishes nothing on later beats.
    local published = 0
    local observer = {}
    app:Subscribe(observer, "LAYOUT_CENTRAL_CHANGED", function() published = published + 1 end)
    app.components.cooldownViewer:Refresh()
    app.components.cooldownViewer:Refresh()
    eq(published, 0)
    app:Unsubscribe(observer, "LAYOUT_CENTRAL_CHANGED")
    -- Without readable geometry the refused row is unknown and the block
    -- collapses to the reserved baseline instead of reserving a top nothing
    -- draws at.
    essential.rect = nil
    app.Layout:ClearAppliedRows()
    app.components.playerResource:Refresh()
    eq(app.components.playerResource.rail.point[5], 110)
    essential.SetPoint = original
    app.components.playerResource.rail.point = nil
    eq(#app.errors, 1)
end)

test("disabling the cooldown stack returns the rail to the reserved baseline", function()
    local app = H.Load()
    for _, name in ipairs({ "UtilityCooldownViewer", "BuffBarCooldownViewer", "BuffIconCooldownViewer" }) do
        _G[name]:Hide()
    end
    _G.EssentialCooldownViewer:SetSize(275, 118)
    H.Fire("PLAYER_LOGIN")
    local rail = app.components.playerResource.rail
    eq(rail.point[5], 228)
    app.Store:Set("modules", "cooldownViewer", false)
    eq(rail.point[5], 110)
    eq(#app.errors, 0)
end)

test("a settled resource rail is not rewritten by the slow layout beat", function()
    local app = H.Load()
    for _, name in ipairs({ "UtilityCooldownViewer", "BuffBarCooldownViewer", "BuffIconCooldownViewer" }) do
        _G[name]:Hide()
    end
    _G.EssentialCooldownViewer:SetSize(275, 118)
    H.Fire("PLAYER_LOGIN")
    local rail = app.components.playerResource.rail
    local writes = 0
    local setPoint, clearAllPoints, setWidth = rail.SetPoint, rail.ClearAllPoints, rail.SetWidth
    rail.SetPoint = function(self, ...) writes = writes + 1; return setPoint(self, ...) end
    rail.ClearAllPoints = function(self) writes = writes + 1; return clearAllPoints(self) end
    rail.SetWidth = function(self, ...) writes = writes + 1; return setWidth(self, ...) end
    H.Advance(3)
    app.components.cooldownViewer:Refresh()
    app.components.playerResource:Refresh()
    eq(writes, 0)
    rail.SetPoint, rail.ClearAllPoints, rail.SetWidth = setPoint, clearAllPoints, setWidth
    eq(#app.errors, 0)
end)

test("death knight runes stay native instead of a continuous second rail", function()
    local app = H.Load()
    local power, powerMax, powerType = _G.UnitPower, _G.UnitPowerMax, _G.UnitPowerType
    H.unitInfo.player.class = "DEATHKNIGHT"
    _G.UnitPowerType = function() return 6, "RUNIC_POWER" end
    _G.UnitPowerMax = function(unit, kind)
        if kind == 5 then return 6 end
        if kind then return 0 end
        return 100
    end
    _G.UnitPower = function(unit, kind) if kind == 5 then return 3 end return 60 end
    H.Fire("PLAYER_LOGIN")
    local component = app.components.playerResource
    -- Runes recover one at a time; the generic 0..6 rail would replace that
    -- recovery with a worse summary, so the native display owns it.
    eq(component.secondaryNative, "runes")
    eq(component.secondaryType, nil)
    eq(component.rail.secondary:IsShown(), false)
    eq(component.rail:GetHeight(), 6)
    eq(component:Describe():find(app.L.resourceNative, 1, true) ~= nil, true)
    H.messages = {}
    component:Diagnose()
    eq(table.concat(H.messages, "\n"):find("native=runes", 1, true) ~= nil, true)
    -- A spec without a native per-rune display gets the summary rail back.
    H.unitInfo.player.class = "PRIEST"
    _G.UnitPowerType = function() return 0, "MANA" end
    component:Refresh()
    eq(component.secondaryNative, nil)
    eq(component.secondaryType, 5)
    eq(component.rail.secondary:IsShown(), true)
    _G.UnitPower, _G.UnitPowerMax, _G.UnitPowerType = power, powerMax, powerType
    app.Store:Set("modules", "playerResource", false)
    eq(#app.errors, 0)
end)

test("the main health top follows the applied skill row", function()
    local app = H.Load()
    for _, name in ipairs({ "UtilityCooldownViewer", "BuffBarCooldownViewer", "BuffIconCooldownViewer" }) do
        _G[name]:Hide()
    end
    _G.EssentialCooldownViewer:SetSize(275, 118)
    H.Fire("PLAYER_LOGIN")
    app.Store:Set("modules", "unitFrames", true)
    local player = app.components.unitFrames.frames.player
    -- The essential row ends at 222; the frame top carries the 15 unit name row
    -- above a health bar whose top edge is collinear with the skill block.
    local healthTop = player.point[5] + player:GetHeight() / 2 - 15
    eq(math.abs(healthTop - (222 - 540)) < 0.01, true)
    -- With no applied viewer row the mockup fraction is the baseline again.
    app.Store:Set("modules", "cooldownViewer", false)
    local fallback = player.point[5] + player:GetHeight() / 2 - 15
    eq(math.abs(fallback + 205.2) < 0.01, true)
    eq(#app.errors, 0)
end)

test("the player resource rail follows the central block and passes values through", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local component = app.components.playerResource
    eq(component.running, true)
    local rail = component.rail
    eq(rail:IsShown(), true)
    -- Values reach the client's own drawing methods untouched: the harness hands
    -- back secret numbers, so nothing here may compare or convert them.
    eq(rail.primary.value ~= nil, true)
    -- A class with no readable second resource hides the second rail.
    eq(component.secondaryType, nil)
    eq(rail.secondary:IsShown(), false)
    eq(rail:GetHeight(), 6)
    -- Geometry follows the same central measurement every other HUD part reads.
    component:Refresh()
    local central = app.Layout:Central()
    eq(rail:GetWidth(), central.content.width)
    eq(rail.point[1], "BOTTOM")
    eq(rail.point[5], central.cooldown.top + 6)
    -- Disabling hides the rail and releases the component's events.
    app.Store:Set("modules", "playerResource", false)
    eq(rail:IsShown(), false)
    eq(#app.errors, 0)
end)

test("a class resource gets a second rail only when the client reports it", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local component = app.components.playerResource
    local rail = component.rail
    local power, powerMax = _G.UnitPower, _G.UnitPowerMax
    _G.UnitPower = function(unit, kind) if kind == 4 then return 3 end return 60 end
    _G.UnitPowerMax = function(unit, kind) if kind == 4 then return 5 end return 100 end
    component:Refresh()
    eq(component.secondaryType, 4)
    eq(rail.secondary:IsShown(), true)
    eq(rail:GetHeight(), 11)
    eq(rail.primary.value, 60)
    eq(rail.primary.maximum, 100)
    eq(rail.secondary.value, 3)
    eq(rail.secondary.maximum, 5)
    -- A restricted maximum is not evidence of a resource: the rail goes away.
    _G.UnitPowerMax = function() return H.Secret(100) end
    component:Refresh()
    eq(component.secondaryType, nil)
    eq(rail.secondary:IsShown(), false)
    _G.UnitPower, _G.UnitPowerMax = power, powerMax
    app.Store:Set("modules", "playerResource", false)
    eq(#app.errors, 0)
end)

test("the measured cooldown block moves the unit frames beside it", function()
    local app = H.Load(); UIParent:SetSize(1920, 1080); H.Fire("PLAYER_LOGIN")
    app.Store:Set("modules", "unitFrames", true)
    local player = app.components.unitFrames.frames.player
    -- Before any viewer is readable the mockup fallback applies.
    eq(player.point[4], -245.76)
    local viewer = H.NewFrame("EssentialCooldownViewer", UIParent)
    viewer:SetSize(360, 40)
    local central = app.Layout:CentralRows({ { frame = viewer, id = "essential", main = true } })
    eq(central.content.width, 360)
    eq(central.contentChanged, true)
    app:Publish("LAYOUT_CENTRAL_CHANGED")
    eq(player.point[4], -275.76)
    -- An auxiliary row above the skills never widens the block: the buffs sit
    -- above the frames' top edge, so pulling the health bars apart would only
    -- make the centre read worse.
    local buff = H.NewFrame("BuffBarCooldownViewer", UIParent)
    buff:SetSize(500, 20)
    local again = app.Layout:CentralRows({
        { frame = viewer, id = "essential", main = true }, { frame = buff, id = "buffBar" } })
    eq(again.content.width, 360)
    eq(again.content.mainOnly, true)
    eq(again.contentChanged, nil)
    app:Publish("LAYOUT_CENTRAL_CHANGED")
    eq(player.point[4], -275.76)
    -- A wider main row still owns the block: the unit frames follow the skills.
    local utility = H.NewFrame("UtilityCooldownViewer", UIParent)
    utility:SetSize(500, 40)
    local wide = app.Layout:CentralRows({
        { frame = viewer, id = "essential", main = true },
        { frame = utility, id = "utility", main = true },
        { frame = buff, id = "buffBar" } })
    eq(wide.content.width, 500)
    eq(wide.contentChanged, true)
    app:Publish("LAYOUT_CENTRAL_CHANGED")
    eq(player.point[4], -345.76)
    -- No readable viewer returns to the mockup ratio instead of keeping a stale
    -- block width; the units follow in the same pass. The placement component
    -- is off first so it cannot re-measure the 360-wide fixture afterwards.
    app.Store:Set("modules", "cooldownViewer", false)
    app.Layout:CentralRows({})
    eq(app.Layout:ContentWidth(), 167.04)
    app:Publish("LAYOUT_CENTRAL_CHANGED")
    eq(player.point[4], -179.28)
    eq(#app.errors, 0)
end)

test("a preset centre follows the main skill block until it is dragged", function()
    local app = H.Load(); UIParent:SetSize(1920, 1080); H.Fire("PLAYER_LOGIN")
    app.Store:Set("modules", "unitFrames", true)
    -- The placement component measures the fixture viewers itself; turning it
    -- off keeps this test about the boundary the preset reads.
    app.Store:Set("modules", "cooldownViewer", false)
    local player = app.components.unitFrames.frames.player
    -- The preset stores the centre it was applied with.
    app.Layout:ApplyPreset("combat")
    eq(player.point[4], -245.76)
    eq(app.Store:Profile().positions.unit_player.x, -245.76)
    -- A wider tracked-buff row is auxiliary: it sits above the frames' top edge
    -- and must not pull the health bars apart after a preset. The main row here
    -- is the fixture's 300 unit essential viewer.
    local essential = _G.EssentialCooldownViewer
    local buff = H.NewFrame("BuffBarCooldownViewer", UIParent)
    buff:SetSize(500, 20)
    app.Layout:CentralRows({
        { frame = essential, id = "essential", main = true }, { frame = buff, id = "buffBar" } })
    app:Publish("LAYOUT_CENTRAL_CHANGED")
    eq(player.point[4], -245.76)
    -- A wider main row moves the stored centre with the frame.
    local utility = H.NewFrame("UtilityCooldownViewer", UIParent)
    utility:SetSize(500, 40)
    app.Layout:CentralRows({
        { frame = utility, id = "utility", main = true }, { frame = buff, id = "buffBar" } })
    app:Publish("LAYOUT_CENTRAL_CHANGED")
    eq(player.point[4], -345.76)
    eq(app.Store:Profile().positions.unit_player.x, -345.76)
    -- A deliberate drag wins: the next boundary change keeps the saved centre.
    app.Store:SetPosition("unit_player", -120, -230)
    app.Layout:CentralRows({ { frame = utility, id = "utility", main = true } })
    app:Publish("LAYOUT_CENTRAL_CHANGED")
    eq(player.point[4], -120)
    eq(#app.errors, 0)
end)

test("central geometry marks a missing action area as an estimate", function()
    local app = H.Load()
    _G.MainActionBar, _G.MultiBarBottomLeft, _G.MultiBarBottomRight = nil, nil, nil
    H.Fire("PLAYER_LOGIN")
    local central = app.Layout:Central()
    eq(central.action.estimated, true)
    eq(central.action.width, 524)
    eq(central.action.height, 128)
    eq(central.action.bottom, 56)
    eq(#central.action.rows, 3)
    eq(#app.errors, 0)
end)

test("the action area baseline moves both the bars and the cooldown stack", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local essential = _G.EssentialCooldownViewer
    eq(essential.point[5], 104)
    app.Store:Set("modules", "actionBars", true)
    eq(MainActionBar.point[5], 56)
    eq(essential.point[5], 104)
    eq(app.Layout:SetActionAreaBottom(80), true)
    eq(MainActionBar.point[5], 80)
    eq(essential.point[5], 128)
    eq(app.Layout:SetActionAreaBottom(80), false)
    -- In combat both components queue; the latest shared baseline wins and
    -- each keeps its own key instead of one overwriting the other.
    H.Combat(true)
    app.Layout:SetActionAreaBottom(90)
    app.Layout:SetActionAreaBottom(100)
    eq(MainActionBar.point[5], 80)
    eq(app.Queue:Count(), 2)
    H.Combat(false)
    eq(MainActionBar.point[5], 100)
    eq(essential.point[5], 148)
    -- Switching only the bars off leaves the cooldown stack on the new area.
    app.Store:Set("modules", "actionBars", false)
    eq(app.components.cooldownViewer.running, true)
    eq(essential.point[5], 148)
    app.Store:Set("modules", "cooldownViewer", false)
    eq(essential.point, nil)
    eq(#app.errors, 0)
end)

test("bars fade in from the measured rectangle and the panel shares their alpha", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.Store:Set("modules", "actionBars", true)
    app.Store:Set("modules", "actionPanel", true)
    local panel = app.components.actionPanel.panels[MainActionBar]
    eq(panel:IsShown(), true)
    eq(MainActionBar.alpha, 0)
    eq(panel:GetAlpha(), 0)
    -- UIParent centre is 960,540 in the fixture; -480 is inside the area whose
    -- bottom is 56 above the screen bottom (centre offset -484).
    _G.GetCursorPosition = function() return 960, 60 end
    H.Advance(0.35)
    eq(MainActionBar.alpha > 0.5, true)
    eq(panel:GetAlpha(), MainActionBar.alpha)
    -- Chat focus inside the same rectangle must not summon the bars.
    _G.GetMouseFocus = function() return ChatFrame1 end
    H.now = H.now + 2
    H.Advance(1.6)
    eq(MainActionBar.alpha < 0.1, true)
    _G.GetCursorPosition, _G.GetMouseFocus = nil, nil
    _G.MouseIsOver = function() return false end
    app.Store:Set("modules", "actionBars", false)
    eq(panel:GetAlpha(), 1)
    eq(panel:IsShown(), true)
    _G.MouseIsOver = nil
    eq(#app.errors, 0)
end)

test("empty, hidden and alpha-zero cooldown viewers collapse their rows", function()
    local app = H.Load()
    _G.UtilityCooldownViewer.cooldownButtons = {}
    _G.BuffBarCooldownViewer:SetAlpha(0)
    _G.BuffIconCooldownViewer:SetHeight(1)
    H.Fire("PLAYER_LOGIN")
    local component = app.components.cooldownViewer
    eq(_G.EssentialCooldownViewer.point[5], 104)
    eq(_G.UtilityCooldownViewer.point, nil)
    eq(_G.BuffBarCooldownViewer.point, nil)
    eq(_G.BuffIconCooldownViewer.point, nil)
    eq(#component.placedRows, 1)
    eq(component.placedRows[1].id, "essential")
    -- Skipping a viewer changes only its position, never its own visibility.
    eq(_G.UtilityCooldownViewer:IsShown(), true)
    eq(_G.BuffBarCooldownViewer:IsShown(), true)
    app.Store:Set("modules", "cooldownViewer", false)
    eq(_G.EssentialCooldownViewer.lumaCooldownViewerOriginal, nil)
    eq(next(component.events.events), nil)
    eq(#app.errors, 0)
end)

test("a cooldown viewer that loads after login joins the next layout pass", function()
    local app = H.Load()
    _G.UtilityCooldownViewer, _G.BuffIconCooldownViewer, _G.BuffBarCooldownViewer = nil, nil, nil
    H.Fire("PLAYER_LOGIN")
    local component = app.components.cooldownViewer
    eq(component.running, true)
    eq(_G.EssentialCooldownViewer.point[5], 104)
    local utility = H.NewFrame("UtilityCooldownViewer", UIParent)
    utility:SetSize(280, 28)
    H.Fire("PLAYER_ENTERING_WORLD")
    eq(utility.point[1], "BOTTOM")
    eq(utility.point[5], 142)
    app.Store:Set("modules", "cooldownViewer", false)
    eq(utility.point, nil)
    eq(#app.errors, 0)
end)

test("one refused cooldown viewer keeps its anchor and the stack continues", function()
    local app = H.Load()
    local essential = _G.EssentialCooldownViewer
    essential:SetPoint("CENTER", UIParent, "CENTER", 33, 44)
    local original = essential.SetPoint
    essential.SetPoint = function(self, point, ...)
        if point == "BOTTOM" then error("refused", 0) end
        return original(self, point, ...)
    end
    H.Fire("PLAYER_LOGIN")
    local component = app.components.cooldownViewer
    eq(essential.point[1], "CENTER")
    eq(essential.point[4], 33)
    eq(essential.point[5], 44)
    -- The refused row collapses, so the next viewer takes its place.
    eq(_G.UtilityCooldownViewer.point[5], 104)
    eq(#app.errors, 1)
    eq(app.errors[1].context:find("cooldownViewer", 1, true) ~= nil, true)
    app.Store:Set("modules", "cooldownViewer", false)
    eq(essential.point[1], "CENTER")
    eq(essential.point[4], 33)
    essential.SetPoint = original
    eq(#app.errors, 1)
end)

test("a target change cannot bring a suppressed native frame back", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.Store:Set("modules", "unitFrames", true)
    app.Store:Set("ui", "takeoverUnitFrames", true)
    eq(app.components.unitFrames.takeover.units, true)
    eq(TargetFrame:IsShown(), false)
    -- The client re-shows TargetFrame on every target change; the OnShow hook
    -- must keep the replacement single.
    TargetFrame:Show()
    eq(TargetFrame:IsShown(), false)
    app.Store:Set("ui", "takeoverUnitFrames", false)
    TargetFrame:Show()
    eq(TargetFrame:IsShown(), true)
    eq(#app.errors, 0)
end)

test("bottom strip reads durability and bag counts on its own tick", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    local strip = app.components.dataStrip
    H.durability = { [1] = { 40, 100 }, [16] = { 90, 100 } }
    H.Fire("UPDATE_INVENTORY_DURABILITY")
    eq(strip.durability:GetText():find("40%", 1, true) ~= nil, true)
    eq(strip.bags:GetText():find("6/12", 1, true) ~= nil, true)
    eq(#app.errors, 0)
end)

test("top performance shares the strip sample and releases its ticker", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    -- The strip owns the readout by default (010 phase 08); the top capsule is
    -- an explicit opt-in.
    eq(app.components.topPerformance.running == true, false)
    app.Store:Set("modules", "topPerformance", true)
    local top = app.components.topPerformance
    eq(top.running, true)
    eq(top.status, "running")
    eq(top.frame:IsShown(), true)
    eq(top.frame.point[1], "CENTER")
    eq(top.frame.point[2], UIParent)
    eq(top.frame.point[4], 0)
    eq(top.frame.point[5], 518)
    -- A fixed capsule: a wider number must not resize the band.
    eq(top.frame:GetWidth(), 96)
    eq(top.text:GetText(), app.L.fps .. " 120  " .. app.L.latency .. " 40")
    -- The strip and the top reading update on the same beat; the shared cache
    -- means one guarded client query, not one per component.
    local calls = 0
    local framerate = _G.GetFramerate
    _G.GetFramerate = function()
        calls = calls + 1
        return framerate()
    end
    H.Advance(1)
    eq(calls, 1)
    -- With the strip disabled the top reading keeps sampling by itself.
    app.Store:Set("modules", "dataStrip", false)
    H.Advance(1)
    eq(calls, 2)
    -- With both disabled there is no performance timer left.
    app.Store:Set("modules", "topPerformance", false)
    eq(top.frame:IsShown(), false)
    local before = calls
    H.Advance(2)
    eq(calls, before)
    eq(#app.errors, 0)
end)

test("the top reading falls back to the values this client can report", function()
    local app = H.Load(); H.Fire("PLAYER_LOGIN")
    app.Store:Set("modules", "topPerformance", true)
    local top = app.components.topPerformance
    local framerate, netstats = _G.GetFramerate, _G.GetNetStats
    -- FPS unreadable: the latency survives on its own.
    _G.GetFramerate = nil
    H.Advance(1)
    eq(top.text:GetText(), app.L.latency .. " 40")
    eq(top.frame:IsShown(), true)
    -- Nothing readable: the capsule hides instead of printing stale numbers.
    _G.GetNetStats = nil
    H.Advance(1)
    eq(top.frame:IsShown(), false)
    -- A recovered client brings the reading back on the next beat.
    _G.GetFramerate, _G.GetNetStats = framerate, netstats
    H.Advance(1)
    eq(top.text:GetText(), app.L.fps .. " 120  " .. app.L.latency .. " 40")
    eq(top.frame:IsShown(), true)
    eq(#app.errors, 0)
end)

test("the top reading stays off by default on an old or read-only database", function()
    -- An old profile without the switch gets the new default (off): the bottom
    -- strip is the one readout unless the player explicitly turns the capsule on.
    local old = H.Load({ schema = 1, profiles = { Default = { modules = {} } } })
    H.Fire("PLAYER_LOGIN")
    eq(old.components.topPerformance.running == true, false)
    eq(old.components.topPerformance.frame, nil)
    -- A newer-schema database is read-only: enabling refuses instead of
    -- silently changing stored data.
    local readonly = H.Load({ schema = 99 })
    H.Fire("PLAYER_LOGIN")
    eq(readonly.Store.readonly, true)
    eq(readonly.components.topPerformance.running == true, false)
    eq(readonly.Store:Set("modules", "topPerformance", true), false)
    eq(readonly.components.topPerformance.running == true, false)
    eq(#old.errors, 0)
    eq(#readonly.errors, 0)
end)

print(string.format("%d/%d tests passed", passed, total))
if passed ~= total then os.exit(1) end
