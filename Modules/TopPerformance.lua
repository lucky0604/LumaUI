local _, app = ...

-- The optional top-centre FPS and latency reading from the Pearl target. It is
-- presentation only: the sampler lives in Capabilities and is shared with the
-- bottom strip and the report tooltips, so running both readouts never doubles
-- the client queries or shows two different numbers on the same beat. The
-- component owns one narrow capsule and one one-second ticker; disabling it
-- hides the capsule and releases the ticker through the component runtime.

-- A fixed capsule keeps a ticking number from resizing the band; the text is
-- centred inside it and both readings still share one line. The capsule sits
-- close to the top readout row so the two do not leave an empty gap.
local WIDTH, HEIGHT = 96, 16

local function build(self)
    if self.frame then return end
    local frame = CreateFrame("Frame", "LumaUITopPerformance", UIParent, "BackdropTemplate")
    frame:SetSize(WIDTH, HEIGHT)
    frame:SetPoint("TOP", UIParent, "TOP", 0, -22)
    app.Theme:PaintSurface(frame, "hud")
    local text = app.Type:Text(frame, "micro")
    text:SetPoint("CENTER")
    text:SetJustifyH("CENTER")
    local accent = app.Theme:Accent()
    text:SetTextColor(accent[1], accent[2], accent[3])
    self.frame, self.text = frame, text
end

local function update(self)
    if not self.text then return end
    local fps, home, world = app.Capabilities.Performance()
    local latency = home and world and math.max(home, world) or nil
    local parts = {}
    if fps then parts[#parts + 1] = app.L.fps .. " " .. math.floor(fps + 0.5) end
    if latency then parts[#parts + 1] = app.L.latency .. " " .. latency end
    if #parts == 0 then
        self.frame:Hide()
        return
    end
    self.text:SetText(table.concat(parts, "  "))
    self.frame:Show()
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
        if self.frame then self.frame:Hide() end
    end,
})
