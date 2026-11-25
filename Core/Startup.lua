local _, app = ...
local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:RegisterEvent("PLAYER_MONEY")
events:RegisterEvent("PLAYER_REGEN_ENABLED")
events:RegisterEvent("PLAYER_REGEN_DISABLED")
events:RegisterEvent("DISPLAY_SIZE_CHANGED")
events:RegisterEvent("UI_SCALE_CHANGED")

local function command(input)
    if not app.ready then app:Print(app.L.notReady); return end
    local action, rest = input:match("^%s*(%S*)%s*(.-)%s*$")
    action = action:lower()
    if action == "edit" then app.Layout:Toggle()
    elseif action == "layout" then app.Settings:Toggle("layout")
    elseif action == "bags" then
        -- `takeover` is the switch itself; anything else toggles the browser.
        if rest == "takeover" then
            app.components.inventory:ToggleTakeover()
        else
            app.components.inventory:Toggle()
        end
    elseif action == "bank" then app.components.bank:Toggle()
    elseif action == "party" then app.components.partyFrames:Diagnose()
    elseif action == "unit" then app.components.unitFrames:Diagnose()
    elseif action == "raid" and app.components.raidFrames then app.components.raidFrames:Diagnose()
    elseif action == "plates" and app.components.nameplates then
        -- `on` / `friends` / `off` change the client's own nameplate setting at
        -- the player's explicit request; anything else prints the report.
        app.components.nameplates:Command(rest)
    elseif action == "dump" then app:WriteDiagnostics()
    elseif action == "ownership" or action == "owner" then
        -- Read-only ownership table: what each control asked for, what is on
        -- screen, and whether the current build has real evidence for it.
        local lines = app.Ownership:Lines()
        if #lines == 0 then
            app:Print(app.L.ownNone)
        else
            app:Print(app.L.ownHeader)
            for _, line in ipairs(lines) do app:Print("  " .. line) end
        end
    elseif action == "hud" then app.Layout:Diagnose()
    elseif action == "cds" and app.components.cooldownGroups then
        app.components.cooldownGroups:Command(rest)
    elseif action == "cast" then
        local cast = app.components.playerCast
        if not cast or cast.running ~= true then
            app:Print(app.L.notReady)
        elseif rest == "status" then
            cast:Diagnose()
        else
            cast:Toggle()
        end
    elseif action == "ownedbars" and app.components.ownedBars then
        app.components.ownedBars:Command(rest)
    elseif action == "runes" then
        local wanted = app.Store:Profile().ui.resourceRunes ~= "owned"
        if app.Store:Set("ui", "resourceRunes", wanted and "owned" or "native") then
            app:Print(wanted and app.L.runesOn or app.L.runesOff)
            local resource = app.components.playerResource
            if resource and resource.running then resource:Refresh() end
        else
            app:Print(app.L.readonly)
        end
    elseif action == "bars" and app.components.actionPanel then app.components.actionPanel:Diagnose()
    elseif action == "chat" then
        -- Explicit, reversible chat-size trial (010 phase 08). The client's own
        -- chat settings own the real size; this only asks once and can put the
        -- previous size back.
        local chat = app.components.chat
        if not chat or chat.running ~= true then
            app:Print(app.L.chatTrialNeedsComponent)
            return
        end
        -- `/luma chat <width> <height>` saves a size, `reset` clears it, and the
        -- bare command keeps its historical trial toggle.
        local width, height = rest:match("^(%d+)%s+(%d+)$")
        if width then
            chat:SetSize(tonumber(width), tonumber(height))
        elseif rest == "reset" then
            chat:SetSize(nil, nil)
        elseif chat:SetTrialSize(chat.trialSize ~= true) then
            app:Print(chat.trialSize and app.L.chatSizeOn or app.L.chatSizeOff)
        end
    elseif action == "char" then app.components.characterWindow:Toggle()
    elseif action == "aura" then
        local current = app.Store:Profile().ui.auraFilter
        local wanted = current == "dispel" and "all" or "dispel"
        if app.Store:Set("ui", "auraFilter", wanted) then
            app:Print(wanted == "dispel" and app.L.auraFilterDispel or app.L.auraFilterAll)
            app:Reconcile()
        end
    elseif action == "takeover" and rest == "party" then
        local wanted = app.Store:Profile().ui.partyTakeover == false
        if app.Store:Set("ui", "partyTakeover", wanted) then
            app:Print(wanted and app.L.partyTakeoverOn or app.L.partyTakeoverOff)
            app:Reconcile()
        else
            app:Print(app.L.readonly)
        end
    elseif action == "takeover" and rest == "raid" then
        local wanted = app.Store:Profile().ui.raidTakeover == false
        if app.Store:Set("ui", "raidTakeover", wanted) then
            app:Print(wanted and app.L.raidTakeoverOn or app.L.raidTakeoverOff)
            app:Reconcile()
        else
            app:Print(app.L.readonly)
        end
    elseif action == "takeover" then
        -- Explicit native-unit-frame takeover. The value persists in the
        -- profile; unitFrames applies it on its next Refresh/enable, so the
        -- component must be running for the switch to have an effect.
        local current = app.Store:Profile().ui.takeoverUnitFrames == true
        local wanted = not current
        if not app.Store:Set("ui", "takeoverUnitFrames", wanted) then
            app:Print(app.L.takeoverFailed)
        elseif wanted then
            app:Print(app.L.takeoverOn)
            app:Reconcile()
        else
            app:Print(app.L.takeoverOff)
            app:Reconcile()
        end
    elseif action == "cc" then
        local key, spell = rest:match("^(%S*)%s*(.-)%s*$")
        local click = app.components.clickCast
        if not key or key == "" or key == "list" then
            click:List()
        elseif key == "clear" then
            click:Clear()
        else
            click:Bind(key:lower(), spell)
        end
    elseif action == "slots" then
        -- Opt-in per-icon grid. Off by default because rewriting a pooled
        -- cooldown button's anchor can fight the client's own layout.
        local wanted = not (app.Store:Profile().appearance.perIconSlots == true)
        if not app.Store:Set("appearance", "perIconSlots", wanted) then
            app:Print(app.L.readonly)
            return
        end
        app:Print(wanted and app.L.slotsOn or app.L.slotsOff)
        local viewer = app.components.cooldownViewer
        if viewer and viewer.running then
            app:Call("command/slots", viewer.Refresh, viewer)
        end
    elseif action == "meter" and rest == "api" then
        local meter = app.components.damageMeter
        if meter and type(meter.Probe) == "function" then
            meter:Probe()
        else
            app:Print(app.L.meterNoProvider)
        end
    elseif action == "meter" then
        -- The sample window only draws from a registered provider; without one
        -- it says so instead of covering the reserved area with an empty frame.
        if type(app.DamageMeterProvider) ~= "function" then
            app:Print(app.L.meterNoProvider)
            return
        end
        app.Store:Set("modules", "damageMeter", true)
        local meter = app.components.damageMeter
        if not meter or meter.running ~= true then
            app:Print(app.L.meterNoProvider)
            return
        end
        if meter:IsShown() then meter:Hide() else meter:Show() end
    elseif action == "status" then app.Settings:Toggle("diagnostics")
    elseif action == "style" then
        -- A command that answers with silence is indistinguishable from a broken
        -- one, so opening the sample reports the capability line to chat as well as
        -- drawing it. app:Call also turns any failure inside the build into a
        -- readable chat report instead of an invisible error.
        if not app.StyleSheet then app:Print(app.L.styleMissing); return end
        local ok, frame = app:Call("command/style", app.StyleSheet.Toggle, app.StyleSheet)
        if not ok then return end
        if frame and type(frame.IsShown) == "function" and frame:IsShown() then
            app:Print(app.L.styleOpened .. "   ·   " .. app.StyleSheet:Describe())
        else
            app:Print(app.L.styleClosed)
        end
    elseif action == "help" then app:Print(app.L.commands)
    else app.Settings:Toggle() end
end
SLASH_LUMAUI1, SLASH_LUMAUI2 = "/luma", "/lumaui"
SlashCmdList.LUMAUI = command

local function identityKey()
    -- UnitFullName can be secret when the client restricts unit identity. Never
    -- concatenate or persist a secret, and never use one as a table key.
    local character, realm = UnitFullName("player")
    character = app.Capabilities.Plain(character, "string")
    realm = app.Capabilities.Plain(realm, "string") or GetRealmName()
    if not character then
        app:Print(app.L.identityUnavailable)
        character = "Player"
    end
    return character .. " - " .. tostring(realm)
end

function app:Initialize()
    if self.ready then return end
    if not self.Capabilities.IsRetail() then self:Print(self.L.retailOnly); return end
    self.Store:Open(identityKey())
    self.ready = true
    if self.Reports then self:Call("startup/money", self.Reports.RecordMoney, self.Reports) end
    self:Subscribe(self, "PROFILE_CHANGED", function()
        -- A profile switch can change the motion settings or a theme colour in
        -- the middle of a fade; settle every owned transition at its target so
        -- no half-faded surface or transparent window is left behind. A preset
        -- preview and its snapshot belong to the profile that opened them.
        self.Transitions:SettleAll()
        if self.Layout then
            self.Layout:CancelPresetPreview()
            self.Layout:ClearPresetSnapshot()
            -- Member offsets belong to the selected profile, not to the frame.
            self.Layout:RefreshMembers()
        end
        self:Reconcile()
        self.Settings:Update()
    end)
    self:Subscribe(self.Settings, "RUNTIME_UPDATED", function() self.Settings:Update() end)
    self:Reconcile()
    if Settings and Settings.RegisterCanvasLayoutCategory then
        local categoryFrame = CreateFrame("Frame")
        local text = self.Theme:Text(categoryFrame, 17)
        text:SetPoint("TOPLEFT", 24, -24)
        text:SetText("LumaUI")
        local button = self.Controls:Button(categoryFrame, self.L.general, 180, function() self.Settings:Toggle() end)
        button:SetPoint("TOPLEFT", 24, -64)
        self.settingsCategory = Settings.RegisterCanvasLayoutCategory(categoryFrame, "LumaUI")
        Settings.RegisterAddOnCategory(self.settingsCategory)
    end
    self:Print(self.Store.readonly and self.L.newerData or self.L.ready)
end

events:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_LOGIN" then
        app:Call("startup", app.Initialize, app)
    elseif event == "PLAYER_ENTERING_WORLD" or event == "PLAYER_MONEY" then
        -- The account money ledger must not depend on the information strip
        -- being enabled, so recording lives in the core startup frame.
        if app.ready and app.Reports then app:Call("startup/money", app.Reports.RecordMoney, app.Reports) end
    elseif event == "PLAYER_REGEN_ENABLED" then
        app.Queue:Flush()
        if app.ready then app.Settings:Update() end
    elseif event == "PLAYER_REGEN_DISABLED" then
        if app.Layout.editing then app.Layout:SetEditing(false) end
        if app.ready then app.Settings:Update() end
    elseif app.ready then
        -- A display or UI scale change moves panels and changes what one
        -- physical pixel is, so the hairline roles repaint through Reconcile.
        app.Queue:Run("layout/display", function()
            app.Layout:ApplyAll()
            app:Reconcile()
        end)
    end
end)

if IsLoggedIn() then app:Call("startup", app.Initialize, app) end
