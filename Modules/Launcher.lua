local _, app = ...
local module = app:RegisterComponent({ id = "launcher", label = "launcher",
    Enable = function(self)
        if not self.button then
            local button = CreateFrame("Button", "LumaUILauncher", Minimap, "BackdropTemplate")
            button:SetSize(30, 30)
            button:SetPoint("BOTTOMRIGHT", Minimap, "BOTTOMRIGHT", 8, -8)
            button:SetFrameStrata("MEDIUM")
            button:SetFrameLevel(Minimap:GetFrameLevel() + 8)
            button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
            local icon = app.Theme:Text(button, 19)
            icon:SetPoint("CENTER", 0, 1)
            icon:SetText("L")
            -- `label` is component metadata used by the settings page; the
            -- minimap glyph lives on its own field so it does not shadow it.
            self.icon, self.button = icon, button
            button:SetScript("OnClick", function(_, which)
                if which == "RightButton" then app.Unlock:Toggle() else app.Settings:Toggle() end
            end)
            button:SetScript("OnEnter", function()
                GameTooltip:SetOwner(button, "ANCHOR_LEFT")
                GameTooltip:SetText("LumaUI")
                GameTooltip:AddLine(app.L.launcherHint, 0.8, 0.9, 0.9, true)
                GameTooltip:Show()
            end)
            button:SetScript("OnLeave", function() GameTooltip:Hide() end)
        end
        self.button:Show()
    end,
    Refresh = function(self)
        app.Theme:Panel(self.button, true)
        local c = app.Theme:Accent()
        self.icon:SetTextColor(c[1], c[2], c[3])
    end,
    Disable = function(self) if self.button then self.button:Hide() end end,
})
