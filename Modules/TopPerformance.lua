local _, app = ...

-- The optional top-centre FPS and latency reading from the Pearl target. It is
-- presentation only: the sampler lives in Capabilities and is shared with the
-- bottom strip and the report tooltips, so running both readouts never doubles
-- the client queries or shows two different numbers on the same beat. The
-- component owns one FontString and one one-second ticker; disabling it hides
-- the reading and releases the ticker through the component runtime.

local function update(self)
    if not self.text then return end
    local fps, home, world = app.Capabilities.Performance()
    local latency = home and world and math.max(home, world) or nil
    local parts = {}
    if fps then parts[#parts + 1] = app.L.fps .. " " .. math.floor(fps + 0.5) end
    if latency then parts[#parts + 1] = app.L.latency .. " " .. latency end
    if #parts == 0 then
        self.text:Hide()
        return
    end
    self.text:SetText(table.concat(parts, "   "))
    self.text:Show()
end

local function build(self)
    if self.text then return end
    local text = app.Type:Text(UIParent, "micro")
    text:SetPoint("TOP", UIParent, "TOP", 0, -6)
    text:SetJustifyH("CENTER")
    local accent = app.Theme:Accent()
    text:SetTextColor(accent[1], accent[2], accent[3])
    self.text = text
end

app:RegisterComponent({
    id = "topPerformance", label = "topPerformance", defaultEnabled = true,
    Enable = function(self)
        build(self)
        self:Every(1, update)
        update(self)
    end,
    Refresh = function(self)
        build(self)
        update(self)
    end,
    Disable = function(self)
        if self.text then self.text:Hide() end
    end,
})
