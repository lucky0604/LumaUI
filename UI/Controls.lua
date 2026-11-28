local _, app = ...
local Controls = {}
app.Controls = Controls

-- Every control resolves its look from the whole state, never from the last
-- event. That is what keeps a selected navigation entry selected after the
-- mouse leaves it (the old implementation reset the border on OnLeave).
local function newState()
    return { hover = false, pressed = false, selected = false, disabled = false, focus = false }
end

local function accent()
    return app.Theme:Accent()
end

-- A hairline that exists only while a control has a state to announce. Idle
-- controls have no edge at all: the border belongs to the interaction, not to the
-- material, and that is the difference between a designed control and a grey box.
-- It is a child frame rather than the control's own backdrop so switching it on and
-- off never rebuilds the fill.
local function newRing(frame)
    if type(CreateFrame) ~= "function" then return nil end
    local ring = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    if not ring or type(ring.SetBackdrop) ~= "function" then return nil end
    ring:SetAllPoints(frame)
    ring:SetBackdrop({ edgeFile = app.Theme.white, edgeSize = app.Pixel:Pixels(1) })
    ring:SetBackdropColor(0, 0, 0, 0)
    ring:SetBackdropBorderColor(0, 0, 0, 0)
    return ring
end

local function setRing(control, color, alpha)
    if not control.ring then return end
    control.ring:SetBackdropBorderColor(color[1], color[2], color[3], alpha or 0)
end

local function hoverTo(control, target)
    local overlay = control.hoverOverlay
    if not overlay then return end
    if not app.Transitions then
        overlay:SetAlpha(target)
        return
    end
    -- The wash is a Texture, and a Texture has no animation group: Fade would
    -- settle at once. The value channel is the one alpha driver that works on
    -- both a Texture and a Frame, so the hover eases in both directions.
    if type(overlay.CreateAnimationGroup) ~= "function" then
        app.Transitions:Animate(control, "hover", {
            from = overlay:GetAlpha(), to = target, duration = 0.09,
            apply = function(value) overlay:SetAlpha(value) end,
        })
        return
    end
    app.Transitions:Fade(control, overlay, target, 0.09, nil, "hover")
end

local function apply(control)
    local state = control.state
    local theme = app.Theme
    local line = theme.colors.line
    local color = accent()
    local ringOn = false
    if state.disabled then
        -- A disabled control loses its edge and hover wash; it never looks like
        -- a target the player can press. A flat row stays transparent even when
        -- disabled: only its text dims, so the list keeps its rhythm.
        theme:PaintSurface(control, "embedded")
        if control.flat then control:SetBackdropColor(0, 0, 0, 0) end
        if control.text then
            local muted = theme.colors.muted
            control.text:SetTextColor(muted[1], muted[2], muted[3], 1)
        end
        if control.hoverOverlay then control.hoverOverlay:SetAlpha(0) end
    else
        theme:PaintSurface(control, "button")
        if control.flat then
            -- A list row is text on the page, not a button-shaped slab: it keeps
            -- its fill only while it is being touched. Stacking one raised patch
            -- per row is exactly what turned a settings page into a grid of boxes.
            if not (state.hover or state.pressed or state.selected) then
                control:SetBackdropColor(0, 0, 0, 0)
            end
        end
        if state.pressed then
            local raised = theme.colors.raised
            control:SetBackdropColor(raised[1] * 1.6, raised[2] * 1.6, raised[3] * 1.6,
                theme:Opacity("windowOpacity"))
        end
        ringOn = (state.selected or state.hover or state.focus or control.kind == "primary") == true
        if control.text then
            local text = theme.colors.text
            if state.selected or control.kind == "primary" then
                text = color
            elseif control.mutedWhenIdle and not state.hover then
                text = theme.colors.muted
            end
            control.text:SetTextColor(text[1], text[2], text[3], 1)
        end
    end
    -- A soft-selected control (the navigation) announces its state with a wash
    -- and a lit outline instead of the full-strength ring a button uses: the
    -- gold four-sided frame is what made the left column read as a row of boxes.
    local soft = control.selectedSoft and state.selected and not state.disabled
    if soft then
        if control.selectedCapsule then
            control.selectedCapsule:SetColorTexture(color[1], color[2], color[3], 1)
            control.selectedCapsule:SetAlpha(state.hover and 0.26 or 0.20)
            control.selectedCapsule:Show()
        end
    elseif control.selectedCapsule then
        control.selectedCapsule:Hide()
    end
    setRing(control, ringOn and color or line, ringOn and (soft and 0.30 or 1) or 0)
    if control.selectedMark then
        if state.selected and not state.disabled then control.selectedMark:Show() else control.selectedMark:Hide() end
    end
    if control.focusMark then
        if state.focus and not state.disabled then control.focusMark:Show() else control.focusMark:Hide() end
    end
    if control.refresh then control.refresh(control) end
end

local function setFocus(control)
    if Controls.focused == control then return end
    local previous = Controls.focused
    Controls.focused = control
    if previous and previous.state then
        previous.state.focus = false
        if previous.Refresh then previous:Refresh() end
    end
    if control and control.state then
        control.state.focus = true
        if control.Refresh then control:Refresh() end
    end
end

function Controls:ClearFocus()
    setFocus(nil)
end

-- Shared decoration: a quiet hover wash and a one-pixel focus line.
local function decorate(control, options)
    local color = accent()
    local overlay = control:CreateTexture(nil, "BACKGROUND", nil, -7)
    overlay:SetAllPoints(control)
    overlay:SetColorTexture(color[1], color[2], color[3], 1)
    overlay:SetAlpha(0)
    control.hoverOverlay = overlay
    local focusMark = control:CreateTexture(nil, "ARTWORK")
    focusMark:SetPoint("BOTTOMLEFT", 2, 1)
    focusMark:SetPoint("BOTTOMRIGHT", -2, 1)
    focusMark:SetHeight(app.Pixel:Pixels(1))
    focusMark:SetColorTexture(color[1], color[2], color[3], 1)
    focusMark:Hide()
    control.focusMark = focusMark
    control.ring = newRing(control)
    return options
end

local function wireState(control)
    control:SetScript("OnEnter", function(self)
        if self.state.disabled then return end
        self.state.hover = true
        apply(self)
        hoverTo(self, 0.12)
        -- One shared animation class: an interactive button announces the
        -- interaction with four growing hairlines on top of the static ring.
        -- A repeated OnEnter in the same hover does not restart the run. Flat
        -- rows and navigation entries stay quiet: a list of pulsing rows would
        -- read as noise, not as feedback.
        local pulses = self.pulse ~= false
            and (self.kind == "primary" or (self.kind == "secondary" and not self.flat))
        if app.EdgePulse and pulses and not app.EdgePulse.active[self] then
            app.EdgePulse:Show(self)
        end
        end)
    -- Hiding (window closed, page switched) releases the run and the hover
    -- layer at once, so nothing is left animating on an invisible control.
    control:SetScript("OnHide", function(self)
        self.state.hover = false
        self.state.pressed = false
        if app.Transitions then app.Transitions:Cancel(self, "hover") end
        if self.hoverOverlay then self.hoverOverlay:SetAlpha(0) end
        if app.EdgePulse then app.EdgePulse:Release(self) end
        apply(self)
    end)
        control:SetScript("OnLeave", function(self)
        self.state.hover = false
        self.state.pressed = false
        apply(self)
        hoverTo(self, 0)
        if app.EdgePulse then app.EdgePulse:Hide(self) end
        end)
    control:SetScript("OnMouseDown", function(self)
        if self.state.disabled then return end
        self.state.pressed = true
        apply(self)
    end)
    control:SetScript("OnMouseUp", function(self)
        self.state.pressed = false
        apply(self)
    end)
    function control:Refresh()
        apply(self)
    end
    function control:SetSelected(selected)
        self.state.selected = selected == true
        -- Kept as a plain field for callers that have always read it.
        self.selected = self.state.selected
        apply(self)
    end
    function control:IsSelected()
        return self.state.selected == true
    end
    function control:SetFocusState(focused)
        self.state.focus = focused == true
        apply(self)
    end
    function control:SetEnabled(enabled)
        local wanted = enabled ~= false
        if self.state.disabled == (not wanted) then return end
        self.state.disabled = not wanted
        if self.state.disabled then
            self.state.hover = false
            self.state.pressed = false
            self.state.focus = false
            if app.Transitions then app.Transitions:Cancel(self, "hover") end
            if self.hoverOverlay then self.hoverOverlay:SetAlpha(0) end
            -- A disabled control must not keep an animation or a visible edge.
            if app.EdgePulse then app.EdgePulse:Hide(self) end
            if Controls.focused == self then Controls:ClearFocus() end
        end
        apply(self)
    end
    function control:IsEnabled()
        return self.state.disabled ~= true
    end
    function control:SetText(value)
        if self.text then self.text:SetText(value) end
    end
end

-- Ordinary/secondary button. `options.kind` may be "primary" (accent edge and
-- text) or "secondary" (default).
function Controls:Button(parent, text, width, callback, options)
    options = options or {}
    local button = CreateFrame("Button", nil, parent, "BackdropTemplate")
    button:SetSize(width or 120, options.height or 30)
    button.state = newState()
    button.kind = options.kind or "secondary"
    button.flat = options.flat == true
    -- Carried on the control, not read from the call site: `pulse = false` is the
    -- documented opt-out and a caller may also set `button.pulse` afterwards.
    button.pulse = options.pulse
    button.mutedWhenIdle = options.mutedWhenIdle == true
    button.callback = callback
    button.text = app.Theme:Text(button, options.size or 12)
    button.text:SetPoint("CENTER", options.textOffset or 0, 0)
    button.text:SetText(text)
    decorate(button)
    app.Theme:PaintSurface(button, "button")
    button:SetScript("OnClick", function(self, mouseButton)
        if self.state.disabled then return end
        if self.callback then app:Call("controls/click", self.callback, self, mouseButton) end
    end)
    wireState(button)
    apply(button)
    return button
end

-- Navigation entry: a compact row with a soft capsule behind the current page
-- and one short accent bar on the left. The row itself stays flat — on an inset
-- navigation well a stack of raised slabs is exactly the box look the
-- navigation was supposed to replace, so the capsule and the bar carry the
-- state instead of a four-sided frame. A faint accent outline is kept on the
-- selected row only, at a third of the old weight, so it reads as a lit edge
-- rather than as a gold box.
function Controls:Navigation(parent, text, width, callback, options)
    options = options or {}
    options.flat = true
    local button = self:Button(parent, text, width or 176, callback, options)
    button.kind = "navigation"
    button:SetHeight(28)
    button.text:ClearAllPoints()
    button.text:SetPoint("LEFT", 18, 0)
    local mark = button:CreateTexture(nil, "ARTWORK")
    mark:SetSize(app.Pixel:Pixels(3), 14)
    mark:SetPoint("LEFT", 7, 0)
    local color = accent()
    mark:SetColorTexture(color[1], color[2], color[3], 1)
    mark:Hide()
    button.selectedMark = mark
    -- The capsule sits under the label: a low-alpha accent wash, rounded by the
    -- same nine-slice plate the cards use when the client can slice.
    local capsule = button:CreateTexture(nil, "BACKGROUND", nil, -6)
    capsule:SetPoint("TOPLEFT", 2, -2)
    capsule:SetPoint("BOTTOMRIGHT", -2, 2)
    capsule:SetColorTexture(color[1], color[2], color[3], 1)
    capsule:SetAlpha(0)
    button.selectedCapsule = capsule
    button.selectedSoft = true
    apply(button)
    return button
end

-- Tab: the same state machine with an underline instead of a left bar.
function Controls:Tab(parent, text, width, callback, options)
    options = options or {}
    local button = self:Button(parent, text, width or 96, callback, options)
    button.kind = "tab"
    local underline = button:CreateTexture(nil, "ARTWORK")
    underline:SetPoint("BOTTOMLEFT", 8, 2)
    underline:SetPoint("BOTTOMRIGHT", -8, 2)
    underline:SetHeight(app.Pixel:Pixels(2))
    local color = accent()
    underline:SetColorTexture(color[1], color[2], color[3], 1)
    underline:Hide()
    button.selectedMark = underline
    apply(button)
    return button
end

-- Dropdown: one button showing the current choice, one popup list of the
-- others. Used where a page has more objects than a tab row can hold. The popup
-- belongs to the button, closes on a pick, on Escape-style `Close`, and when its
-- owner hides, so it never outlives the page.
function Controls:Dropdown(parent, width, onSelect, options)
    options = options or {}
    local drop
    drop = self:Button(parent, "", width or 220, function() drop:Toggle() end, options)
    drop.text:ClearAllPoints()
    drop.text:SetPoint("LEFT", 12, 0)
    drop.text:SetPoint("RIGHT", -24, 0)
    local arrow = app.Theme:Text(drop, 11, true)
    arrow:SetPoint("RIGHT", -10, 0)
    arrow:SetText("v")
    local popup = CreateFrame("Frame", nil, drop, "BackdropTemplate")
    popup:SetFrameStrata("FULLSCREEN_DIALOG")
    popup:SetPoint("TOPLEFT", drop, "BOTTOMLEFT", 0, -2)
    popup:EnableMouse(true)
    app.Surface:Plate(popup, "card")
    popup:Hide()
    drop.popup, drop.rows, drop.items = popup, {}, {}
    function drop:Close() popup:Hide() end
    function drop:Toggle()
        if popup:IsShown() then popup:Hide() else popup:Show() end
    end
    -- items: { { id =, label = }, ... }; selected: the id shown on the button.
    function drop:SetItems(items, selected)
        self.items, self.selected = items, selected
        local shownLabel
        for index, item in ipairs(items) do
            local row = self.rows[index]
            if not row then
                row = Controls:Button(popup, "", (width or 220) - 8, function(button)
                    popup:Hide()
                    if onSelect and button.itemID ~= nil then onSelect(button.itemID) end
                end, { flat = true, height = 26 })
                row.text:ClearAllPoints()
                row.text:SetPoint("LEFT", 10, 0)
                self.rows[index] = row
            end
            row.itemID = item.id
            row.text:SetText(item.label)
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", 4, -4 - (index - 1) * 26)
            row:SetSelected(item.id == selected)
            row:Show()
            if item.id == selected then shownLabel = item.label end
        end
        for index = #items + 1, #self.rows do self.rows[index]:Hide() end
        popup:SetSize((width or 220), #items * 26 + 8)
        self.text:SetText(shownLabel or "")
    end
    drop:SetScript("OnHide", function() popup:Hide() end)
    return drop
end

-- Switch row: label left, a capsule track and a round thumb on the right.
-- The two value fields stay on the control because the pages and the search
-- read them, but the redundant "running" suffix is no longer drawn: a switch
-- that already says Enabled does not need a second word saying it runs.
function Controls:Toggle(parent, text, y, getter, setter, options)
    options = options or {}
    local row
    row = self:Button(parent, "", options.width or 490, function()
        if not setter then return end
        app:Call("controls/toggle", setter, not getter())
        row:Update(options.component)
    end, { height = 32, flat = true })
    row.kind = "switch"
    row:SetPoint("TOPLEFT", 0, y)
    row.text:ClearAllPoints()
    row.text:SetPoint("LEFT", 12, 0)
    row.text:SetText(text)
    row.valueText = app.Theme:Text(row, 12)
    row.valueText:SetPoint("RIGHT", -60, 0)
    row.statusText = app.Theme:Text(row, 11, true)
    row.statusText:SetPoint("RIGHT", -132, 0)
    row.statusText:SetWidth(65)
    row.statusText:SetJustifyH("RIGHT")
    row.statusText:SetWordWrap(false)
    row.valueText:SetWidth(52)
    row.valueText:SetJustifyH("RIGHT")
    row.valueText:SetWordWrap(false)
    row.text:SetPoint("RIGHT", row.statusText, "LEFT", -8, 0)
    row.text:SetWordWrap(false)
    -- 38 x 20 capsule: the track is the control, the 16 px dot inside it is the
    -- thumb. Both are masked into a round end where the client exposes the
    -- portrait mask; a build without it keeps the same two-tone block, just
    -- with square ends, so the switch never disappears.
    local track = CreateFrame("Frame", nil, row, "BackdropTemplate")
    track:SetSize(38, 20)
    track:SetPoint("RIGHT", -12, 0)
    track:EnableMouse(false)
    local trackFill = track:CreateTexture(nil, "ARTWORK")
    trackFill:SetAllPoints(track)
    trackFill:SetColorTexture(1, 1, 1, 1)
    local trackEdge = track:CreateTexture(nil, "OVERLAY")
    trackEdge:SetAllPoints(track)
    trackEdge:SetColorTexture(1, 1, 1, 1)
    -- A round mask is borrowed from the client's own portrait alpha mask: it is
    -- already loaded on every client and gives a true capsule end without a new
    -- texture file. `CreateMaskTexture` is absent on some builds and in tests,
    -- so every mask step is optional.
    local function round(region)
        if type(track.CreateMaskTexture) ~= "function" then return false end
        local ok, mask = pcall(track.CreateMaskTexture, track)
        if not ok or not mask or type(region.AddMaskTexture) ~= "function" then return false end
        local applied = pcall(mask.SetTexture, mask, "Interface\\CHARACTERFRAME\\TempPortraitAlphaMask",
            "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
        if not applied then return false end
        mask:SetAllPoints(region)
        return (pcall(region.AddMaskTexture, region, mask))
    end
    local rounded = round(trackFill)
    local thumb = CreateFrame("Frame", nil, track)
    thumb:SetSize(16, 16)
    thumb:SetPoint("LEFT", track, "LEFT", 2, 0)
    local dot = thumb:CreateTexture(nil, "OVERLAY")
    dot:SetAllPoints(thumb)
    dot:SetColorTexture(1, 1, 1, 1)
    if rounded then round(dot) end
    -- The edge is a hairline inset so the capsule reads as a well even when the
    -- client cannot round the fill.
    trackEdge:Hide()
    row.track, row.thumb, row.trackFill, row.thumbDot = track, thumb, trackFill, dot
    row.trackRounded = rounded
    local function settle(on, animate)
        local c = on and accent() or app.Theme.colors.muted
        local raised = app.Theme.colors.raised
        local floor = on and { c[1] * 0.55, c[2] * 0.55, c[3] * 0.55 }
            or { raised[1] * 1.5, raised[2] * 1.5, raised[3] * 1.5 }
        -- The anchor is the state, not the animation: writing it first means the
        -- thumb is never left on the wrong side if the client refuses to animate.
        thumb:ClearAllPoints()
        if on then
            thumb:SetPoint("RIGHT", track, "RIGHT", -2, 0)
        else
            thumb:SetPoint("LEFT", track, "LEFT", 2, 0)
        end
        local function paintFill(value)
            trackFill:SetColorTexture(floor[1], floor[2], floor[3], 1)
            dot:SetColorTexture(0.97 * value + c[1] * (1 - value),
                0.96 * value + c[2] * (1 - value), 0.94 * value + c[3] * (1 - value), 1)
        end
        paintFill(on and 0 or 1)
        if animate and app.Transitions then
            -- 0.12 s tint settle across the whole capsule: the thumb arrives at
            -- once and the track catches up, which reads as one smooth throw.
            local from = on and 1 or 0
            local to = on and 0 or 1
            app.Transitions:Animate(row, "switch", {
                from = from, to = to, duration = 0.12,
                apply = function(value) paintFill(value) end,
            })
        end
    end
    function row:Update(component)
        local on = getter() == true
        self.valueText:SetText(on and app.L.on or app.L.off)
        local c = on and accent() or app.Theme.colors.muted
        self.valueText:SetTextColor(c[1], c[2], c[3])
        -- Only a real change animates. A page refresh repaints every row on
        -- each profile update, and starting a tween per repaint would keep the
        -- transition queue busy for no visible reason.
        settle(on, self.painted == true and self.lastOn ~= on)
        self.painted = true
        self.lastOn = on
        if component then
            local status = component.status
            -- Only an abnormal status earns a word; "running" is what the switch
            -- already shows, so it is exactly the duplicate this page drops.
            if on and status == "failed" then
                self.statusText:SetText(app.L.statusFailed)
            elseif on and status == "unsupported" then
                self.statusText:SetText(app.L.unsupported)
            elseif on and status == "dependency" then
                self.statusText:SetText(app.L.statusDependency)
            else
                self.statusText:SetText("")
            end
        end
        self:Refresh()
    end
    function row:IsOn()
        return getter() == true
    end
    row:Update(options.component)
    return row
end

-- Text input: a real focus state, a validator border and Esc/Enter to leave.
-- Invalid input is shown in the warning colour; the caller decides whether to
-- refuse the action (the settings page disables its create buttons).
function Controls:Input(parent, width, options)
    options = options or {}
    local input = CreateFrame("EditBox", nil, parent, "BackdropTemplate")
    input:SetSize(width or 200, options.height or 28)
    input:SetAutoFocus(false)
    input:SetMaxLetters(options.maxLetters or 120)
    input:SetFont(app.Type and app.Type:Face() or GameFontNormal:GetFont(), options.size or 12, "")
    if type(input.SetTextInsets) == "function" then input:SetTextInsets(8, 8, 0, 0) end
    input.state = newState()
    input.ring = newRing(input)
    local function paintInput()
        app.Theme:PaintSurface(input, "button")
        local focusColor = accent()
        local warning = app.Theme.colors.ember
        local line = app.Theme.colors.line
        -- An input is the one control that keeps a resting boundary: a field with
        -- no edge at all reads as empty space rather than as somewhere to type.
        if input.state.focus then
            setRing(input, focusColor, 1)
        elseif input.valid == false then
            setRing(input, warning, 1)
        else
            setRing(input, line, 0.6)
        end
    end
    function input:Refresh()
        paintInput()
    end
    function input:Validate()
        local ok = true
        if self.validator then
            local called, result = pcall(self.validator, self:GetText())
            ok = called and result == true
        end
        self.valid = ok
        paintInput()
        return ok
    end
    function input:SetValidator(validator)
        self.validator = validator
        return self:Validate()
    end
    function input:IsValid()
        return self.valid ~= false
    end
    function input:SetFocusState(focused)
        self.state.focus = focused == true
        paintInput()
    end
    input:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    input:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    input:SetScript("OnEditFocusGained", function(self)
        setFocus(self)
        self:Refresh()
    end)
    input:SetScript("OnEditFocusLost", function(self)
        if Controls.focused == self then Controls:ClearFocus() end
        self:Refresh()
    end)
    input:SetScript("OnTextChanged", function(self)
        self:Validate()
        if self.onValidate then app:Call("controls/validate", self.onValidate, self) end
    end)
    function input:SetValidateHandler(handler)
        self.onValidate = handler
    end
    paintInput()
    return input
end

-- Horizontal value row: one 44 px line — title and formatted value on the top
-- row, the rail underneath. The value is also an editor: clicking the number
-- turns it into a field, Enter or leaving commits an exact value, Esc restores
-- what was there. The slider stays the wide surface (`slider:GetWidth()` is the
-- row width) so a drag anywhere on the rail still works.
function Controls:Range(parent, title, y, low, high, step, getter, setter, options)
    options = options or {}
    local width = options.width or 490
    local row = CreateFrame("Frame", nil, parent)
    row:SetSize(width, 44)
    row:SetPoint("TOPLEFT", 0, y)
    local label = app.Theme:TextRole(row, "label")
    label:SetPoint("TOPLEFT")
    label:SetText(title)
    row.title = label
    local value = app.Theme:Text(row, 12, true)
    value:SetPoint("TOPRIGHT")
    value:SetWidth(55)
    value:SetJustifyH("RIGHT")
    label:SetPoint("TOPRIGHT", value, "TOPLEFT", -8, 0)
    label:SetWordWrap(false)
    local slider = CreateFrame("Slider", nil, row)
    slider:SetPoint("TOPLEFT", 0, -26)
    slider:SetSize(width, 8)
    slider:SetOrientation("HORIZONTAL")
    slider:SetMinMaxValues(low, high)
    slider:SetValueStep(step)
    slider:SetObeyStepOnDrag(true)
    slider:EnableMouseWheel(true)
    -- Prism-style rail: a dark capsule track, a thin accent fill and a round
    -- thumb that hugs the value. The native thumb texture is kept but made
    -- invisible so hit testing and the client's own drag maths stay untouched.
    slider.track = slider:CreateTexture(nil, "ARTWORK")
    slider.track:SetColorTexture(1, 1, 1, 1)
    slider.track:SetHeight(4)
    slider.track:SetPoint("LEFT", slider, "LEFT", 8, 0)
    slider.track:SetPoint("RIGHT", slider, "RIGHT", -8, 0)
    slider.fill = slider:CreateTexture(nil, "ARTWORK", nil, 1)
    slider.fill:SetColorTexture(1, 1, 1, 1)
    slider.fill:SetHeight(4)
    slider.fill:SetPoint("LEFT", slider.track, "LEFT", 0, 0)
    local thumb = slider:CreateTexture(nil, "OVERLAY")
    thumb:SetSize(14, 14)
    thumb:SetColorTexture(1, 1, 1, 1)
    -- A round thumb from the client's own portrait mask when the widget exposes
    -- masks; a plain white square otherwise, so a build without them keeps a
    -- working control.
    local function round(region)
        if type(slider.CreateMaskTexture) ~= "function" then return end
        local ok, mask = pcall(slider.CreateMaskTexture, slider)
        if not ok or not mask or not region.AddMaskTexture then return end
        mask:SetAllPoints(region)
        mask:SetTexture("Interface\\CHARACTERFRAME\\TempPortraitAlphaMask",
            "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
        region:AddMaskTexture(mask)
    end
    round(thumb)
    slider:SetThumbTexture(thumb)
    local thumbGlow = slider:CreateTexture(nil, "OVERLAY", nil, 2)
    thumbGlow:SetSize(22, 22)
    thumbGlow:SetColorTexture(1, 1, 1, 1)
    round(thumbGlow)
    local hover, dragging = false, false
    -- One paint for track, fill, thumb and glow, driven by the slider's own
    -- value so the fill always matches the handle the client drags.
    local function paint()
        local colour = accent()
        local floor = app.Theme.colors.raised
        slider.track:SetColorTexture(floor[1] * 0.55, floor[2] * 0.55, floor[3] * 0.55, 1)
        local rangeLow, rangeHigh = low, high
        if type(slider.GetMinMaxValues) == "function" then rangeLow, rangeHigh = slider:GetMinMaxValues() end
        local current = type(slider.GetValue) == "function" and slider:GetValue() or rangeLow
        local fraction = (rangeHigh and rangeHigh > rangeLow)
            and math.max(0, math.min(1, (current - rangeLow) / (rangeHigh - rangeLow))) or 0
        local span = (slider:GetWidth() or width) - 16
        local length = math.max(0, span * fraction)
        slider.fill:SetWidth(math.max(0.01, length))
        slider.fill:ClearAllPoints()
        slider.fill:SetPoint("LEFT", slider.track, "LEFT", 0, 0)
        local enabled = not row.disabled
        local brightness = enabled and 1 or 0.4
        slider.fill:SetColorTexture(colour[1] * brightness, colour[2] * brightness, colour[3] * brightness, 1)
        thumb:SetColorTexture(0.97 * brightness, 0.96 * brightness, brightness, 1)
        thumbGlow:SetColorTexture(colour[1], colour[2], colour[3],
            enabled and ((hover or dragging) and 0.22 or 0.08) or 0.03)
    end
    slider.Paint = paint
    local pending
    -- Percent is only the default because most ranges here are opacities. A
    -- count or a pixel size must not read "2600%": `options.format` receives the
    -- snap value and returns the whole label.
    local formatValue = options.format or function(number)
        return string.format("%.0f%%", number * 100)
    end
    local function format(number)
        value:SetText(formatValue(number))
    end
    local function commit()
        if pending == nil then return end
        local number = pending
        pending = nil
        if row.disabled then return end
        if setter then app:Call("controls/range", setter, number) end
    end
    local function snap(number)
        return math.max(low, math.min(high, math.floor(number / step + 0.5) * step))
    end
    -- The number is also a field. It covers the label's own rectangle, so the
    -- row never grows a second input line: click the value, type, Enter.
    local editor = CreateFrame("EditBox", nil, row, "BackdropTemplate")
    editor:SetSize(56, 22)
    editor:SetPoint("TOPRIGHT", 2, 1)
    editor:SetAutoFocus(false)
    editor:SetMaxLetters(8)
    editor:SetFont(app.Type and app.Type:Face() or GameFontNormal:GetFont(), 12, "")
    if type(editor.SetTextInsets) == "function" then editor:SetTextInsets(4, 4, 0, 0) end
    editor:SetJustifyH("RIGHT")
    editor:EnableMouse(true)
    editor:SetAlpha(0)
    editor:Hide()
    row.editor = editor
    local function leaveEditor(restore)
        if row.editing ~= true then return end
        row.editing = false
        local text = editor:GetText()
        editor:Hide()
        editor:SetAlpha(0)
        value:Show()
        if restore then
            row:Update()
            return
        end
        local number = tonumber(text)
        if number == nil then
            row:Update()
            return
        end
        local snapped = snap(number)
        -- The exact entry is one commit. Setting the slider fires OnValueChanged,
        -- which would commit a second time through the drag path; the guard is
        -- the same one a programmatic refresh uses.
        pending = nil
        row.updating = true
        slider:SetValue(snapped)
        row.updating = false
        if not row.disabled and setter then app:Call("controls/range", setter, snapped) end
        row:Update()
    end
    row.CommitValue = function(text) -- exposed for a keyboard-driven caller
        editor:SetText(tostring(text))
        leaveEditor(false)
    end
    value:EnableMouse(true)
    value:SetScript("OnMouseDown", function()
        if row.disabled then return end
        row.editing = true
        local current = type(slider.GetValue) == "function" and slider:GetValue() or low
        -- The raw number, not the formatted label: the player edits a value,
        -- not a percentage sign.
        editor:SetText(type(current) == "number" and string.format("%g", current) or "")
        value:Hide()
        editor:Show()
        editor:SetAlpha(1)
        editor:SetFocus()
        if type(editor.HighlightText) == "function" then editor:HighlightText() end
    end)
    editor:SetScript("OnEnterPressed", function() leaveEditor(false) end)
    editor:SetScript("OnEscapePressed", function() leaveEditor(true) end)
    editor:SetScript("OnEditFocusLost", function() leaveEditor(false) end)
    editor:SetScript("OnMouseDown", function(self) self:SetFocus() end)
    local function selectAll(self)
        if type(self.HighlightText) == "function" then self:HighlightText() end
    end
    editor:SetScript("OnEditFocusGained", selectAll)
    slider:SetScript("OnValueChanged", function(self, number)
        local snapped = snap(number)
        format(snapped)
        if paint then paint() end
        if row.updating then return end
        pending = snapped
        if not self.dragging then commit() end
    end)
    slider:SetScript("OnMouseDown", function(self)
        if row.disabled then return end
        self.dragging = true
        dragging = true
        Controls:ClearFocus()
        paint()
    end)
    slider:SetScript("OnMouseUp", function(self)
        self.dragging = false
        dragging = false
        paint()
        commit()
    end)
    slider:SetScript("OnEnter", function() hover = true; paint() end)
    slider:SetScript("OnLeave", function() hover = false; if not dragging then paint() end end)
    slider:SetScript("OnSizeChanged", function() paint() end)
    slider:SetScript("OnMouseWheel", function(self, delta)
        if row.disabled then return end
        -- One wheel step is a coarse change: SetValue fires OnValueChanged,
        -- which commits exactly once because the slider is not being dragged.
        self:SetValue(snap((self:GetValue() or getter()) + delta * step))
    end)
    function slider:Refresh() paint() end
    function row:Update()
        if row.editing then return end
        row.updating = true
        local current = getter()
        slider:SetValue(current)
        format(current)
        paint()
        row.updating = false
    end
    function row:SetEnabled(enabled)
        row.disabled = enabled == false
        if row.disabled then
            pending = nil
            slider.dragging = false
            dragging = false
            if row.editing then leaveEditor(true) end
        end
        if type(slider.EnableMouse) == "function" then slider:EnableMouse(not row.disabled) end
        slider:SetAlpha(row.disabled and 0.55 or 1)
        paint()
    end
    function row:IsEnabled()
        return row.disabled ~= true
    end
    row.slider = slider
    row.valueLabel = value
    return row
end

-- Foldable section header: the marker is the only thing that changes with the
-- fold. `state.selected` is about being the *chosen* row, which a fold is not:
-- writing it here is what lit a full accent frame under every collapsed
-- "internal components" section at the bottom of every module page.
function Controls:FoldHeader(parent, text, width, onToggle)
    local header = self:Button(parent, text, width or 400, function(self)
        self:SetFolded(not self.folded)
        if onToggle then app:Call("controls/fold", onToggle, self.folded) end
    end, { height = 24, flat = true })
    header.text:ClearAllPoints()
    header.text:SetPoint("LEFT", 10, 0)
    local mark = app.Theme:Text(header, 11, true)
    mark:SetPoint("RIGHT", -8, 0)
    header.mark = mark
    header.folded = false
    function header:SetFolded(folded)
        self.folded = folded == true
        self.mark:SetText(self.folded and "+" or "-")
        self:Refresh()
    end
    header:SetFolded(false)
    return header
end

-- Scroll area with a LumaUI scrollbar. The scroll logic stays with the client's
-- ScrollFrame; only the bar and its states are ours. `UpdateRange` is called by
-- the owner after the content height changes.
function Controls:Scroll(parent, width, height)
    local scroll = CreateFrame("ScrollFrame", nil, parent)
    scroll:SetSize(width or 464, height or 150)
    -- Retail only dispatches wheel input to the scroll frame when it is also
    -- a mouse target; wheel enablement alone leaves long pages inaccessible.
    scroll:EnableMouse(true)
    scroll:EnableMouseWheel(true)
    local bar = CreateFrame("Slider", nil, parent, "BackdropTemplate")
    bar:SetOrientation("VERTICAL")
    -- A 3 px rail at low contrast: the old 6 px full-strength gold bar was the
    -- widest thing on the navigation column and read as a second border.
    bar:SetSize(3, height or 150)
    bar:SetPoint("TOPLEFT", scroll, "TOPRIGHT", 6, 0)
    bar:EnableMouseWheel(true)
    app.Theme:PaintSurface(bar, "embedded")
    local thumb = bar:CreateTexture(nil, "OVERLAY")
    thumb:SetWidth(3)
    thumb:SetHeight(40)
    local color = accent()
    thumb:SetColorTexture(color[1], color[2], color[3], 0.45)
    bar:SetThumbTexture(thumb)
    scroll.bar = bar
    scroll.thumb = thumb
    scroll.rangeMin, scroll.rangeMax = 0, 0
    local updating = false
    bar:SetScript("OnValueChanged", function(_, value)
        if updating then return end
        scroll:SetVerticalScroll(value)
    end)
    bar:SetScript("OnMouseWheel", function(_, delta)
        scroll:ScrollBy(-delta * 40)
    end)
    scroll:SetScript("OnMouseWheel", function(_, delta)
        scroll:ScrollBy(-delta * 40)
    end)
    function scroll:ScrollBy(delta)
        local target = self:GetVerticalScroll() + delta
        target = math.max(self.rangeMin or 0, math.min(self.rangeMax or 0, target))
        updating = true
        bar:SetValue(target)
        updating = false
        self:SetVerticalScroll(target)
    end
    -- The header above a module page changes height with the object row, so the
    -- viewport and its rail are resized together.
    function scroll:SetViewHeight(height)
        self:SetHeight(height)
        bar:SetHeight(height)
        self:UpdateRange()
    end
    function scroll:ScrollTo(value)
        value = math.max(self.rangeMin or 0, math.min(self.rangeMax or 0, value or 0))
        updating = true
        bar:SetValue(value)
        updating = false
        self:SetVerticalScroll(value)
    end
    function scroll:UpdateRange()
        local child = self:GetScrollChild()
        local content = child and child:GetHeight() or 0
        local view = self:GetHeight()
        local maxScroll = math.max(0, content - view)
        self.rangeMin, self.rangeMax = 0, maxScroll
        local current = self:GetVerticalScroll() or 0
        local target = math.max(0, math.min(current, maxScroll))
        updating = true
        bar:SetMinMaxValues(0, math.max(maxScroll, 1))
        bar:SetValue(target)
        updating = false
        if current ~= target then self:SetVerticalScroll(target) end
        -- A page that fits has nothing to scroll: no rail, no hit area, and the
        -- content sits at its top instead of a full-height thumb.
        local scrollable = maxScroll > 0
        self.scrollable = scrollable
        bar:SetShown(scrollable)
        bar:EnableMouse(scrollable)
        thumb:SetShown(scrollable)
        if scrollable then
            local ratio = content > 0 and math.min(1, view / content) or 1
            thumb:SetHeight(math.min(view, math.max(16, math.floor((view - 2) * ratio))))
        end
    end
    return scroll
end

----------------------------------------------------------------------
-- 019: grouped containers
----------------------------------------------------------------------
-- A settings page used to be rows of controls printed directly on the window
-- fill. These three primitives are what turn it into a page of grouped cards:
-- `Card` is the group, `DualRow` puts two related controls on one line, and
-- `Segmented` is the object/sub-page switch at the top of a page.

-- A card: a rounded section surface with a title line, an optional subtitle and
-- a body the caller fills. It reports its own body height so a page can lay out
-- card after card without hardcoding how many rows each one holds.
function Controls:Card(parent, title, subtitle, options)
    options = options or {}
    local card = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    card:EnableMouse(false)
    -- `options.paddingX = 0` lets an existing row keep its exact width and its
    -- x=0 anchor while still sitting on a card; the title keeps its own inset.
    local padX = options.paddingX
    if padX == nil then padX = 14 end
    card.padding = { x = padX, titleInset = 14, top = 12, bottom = 12 }
    app.Surface:Plate(card, "section")
    card.title = app.Theme:Text(card, 13)
    card.title:SetPoint("TOPLEFT", card.padding.titleInset, -card.padding.top)
    card.title:SetText(title or "")
    card.title:SetWordWrap(false)
    local accent = app.Theme:Accent()
    card.title:SetTextColor(accent[1], accent[2], accent[3])
    card.subtitle = app.Type:Text(card, "micro")
    card.subtitle:SetPoint("TOPLEFT", card.title, "BOTTOMLEFT", 0, -3)
    card.subtitle:SetWidth(400)
    card.subtitle:SetJustifyV("TOP")
    card.subtitle:SetText(subtitle or "")
    card.subtitle:SetShown((subtitle or "") ~= "")
    -- The body is a real frame so children can be anchored to its top-left and
    -- the card can measure what the caller added without reading every child.
    local body = CreateFrame("Frame", nil, card)
    card.body = body
    card.headingHeight = 0
    function card:SetTitle(text)
        self.title:SetText(text or "")
    end
    function card:SetSubtitle(text)
        text = text or ""
        self.subtitle:SetText(text)
        self.subtitle:SetShown(text ~= "")
        self:Layout(0)
    end
    -- `bodyHeight` is the caller's own measure of the rows it placed. The card
    -- grows to the title block plus that, and the body is anchored under the
    -- last heading line.
    function card:Layout(bodyHeight)
        local top = self.padding.top
        local heading = self.title:GetStringHeight()
        if not heading or heading <= 0 then heading = 16 end
        top = top + heading + 4
        if self.subtitle:IsShown() then
            local height = self.subtitle:GetStringHeight()
            if not height or height <= 0 then height = 12 end
            top = top + height + 4
        end
        self.headingHeight = top
        body:ClearAllPoints()
        body:SetPoint("TOPLEFT", self.padding.x, -top)
        body:SetPoint("TOPRIGHT", -self.padding.x, -top)
        body:SetHeight(math.max(1, bodyHeight or 0))
        self:SetHeight(top + math.max(1, bodyHeight or 0) + self.padding.bottom)
    end
    card:Layout(0)
    return card
end

-- Two controls on one line. The caller receives two equal-width parent frames
-- and builds each control inside its own half, so a slider, a dropdown or a
-- switch all measure from the same inner width without knowing about each
-- other. `layout(innerWidth)` is called by the page once the card's width is
-- known; it returns the row height so the card can reserve exactly that.
function Controls:DualRow(card, options)
    options = options or {}
    local body = card and card.body or card
    if not body then return nil end
    local gap = options.gap or 18
    local left = CreateFrame("Frame", nil, body)
    local right = CreateFrame("Frame", nil, body)
    left:SetPoint("TOPLEFT")
    right:SetPoint("TOPLEFT", left, "TOPRIGHT", gap, 0)
    function left:SetRowHeight(height)
        self:SetHeight(math.max(1, height))
        right:SetHeight(self:GetHeight())
    end
    local function layout(innerWidth)
        local half = math.max(60, (innerWidth - gap) / 2)
        left:SetSize(half, left:GetHeight())
        right:SetSize(half, right:GetHeight())
        return math.max(left:GetHeight(), right:GetHeight())
    end
    left.layout = layout
    right.layout = layout
    return left, right, layout
end

-- Segmented switch: a compact pill row where the selected item has a sliding
-- highlight block. Items are { id =, label = } and `onSelect(id)` runs on a
-- click; the caller owns the current id and re-calls SetSelected on refresh, so
-- a profile change and a click resolve through the same path.
function Controls:Segmented(parent, items, width, options)
    options = options or {}
    items = items or {}
    local seg = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    seg:SetHeight(options.height or 26)
    seg:SetWidth(width or 300)
    app.Surface:Plate(seg, "field")
    seg.items, seg.buttons, seg.current = items, {}, nil
    local highlight = seg:CreateTexture(nil, "BACKGROUND", nil, -5)
    local accent = app.Theme:Accent()
    highlight:SetColorTexture(accent[1], accent[2], accent[3], 0.20)
    highlight:Hide()
    seg.highlight = highlight
    local pad = 2
    for index, item in ipairs(items) do
        local button = self:Button(seg, item.label or item.id, 80, function()
            if seg.current == item.id then return end
            seg:SetSelected(item.id)
            if options.onSelect then app:Call("controls/segmented", options.onSelect, item.id) end
        end, { flat = true, height = (options.height or 26) - pad * 2 })
        button.kind = "segment"
        button.itemID = item.id
        button.pulse = false
        button.text:ClearAllPoints()
        button.text:SetPoint("CENTER")
        button:SetPoint("LEFT", seg, "LEFT", pad + (index - 1) * ((width or 300) - pad * 2) / math.max(1, #items), 0)
        button:SetSize(((width or 300) - pad * 2) / math.max(1, #items), (options.height or 26) - pad * 2)
        seg.buttons[index] = button
    end
    -- `skip` is the caller's refresh path: applying a selection without firing
    -- onSelect is what lets a profile switch repaint the row without a loop.
    function seg:SetSelected(id, skip)
        self.current = id
        local target
        for index, button in ipairs(self.buttons) do
            local active = button.itemID == id
            button:SetSelected(active)
            if active then target = button end
        end
        if not target then highlight:Hide(); return end
        highlight:ClearAllPoints()
        highlight:SetPoint("TOPLEFT", target, "TOPLEFT", 0, 0)
        highlight:SetPoint("BOTTOMRIGHT", target, "BOTTOMRIGHT", 0, 0)
        highlight:Show()
        -- A short cross-fade instead of a hard jump; motion off settles at once
        -- and never leaves the block transparent.
        if not skip and app.Transitions and app.Transitions.MotionEnabled() then
            highlight:SetAlpha(0)
            app.Transitions:Fade(self, highlight, 1, 0.12, nil, "segment")
        else
            highlight:SetAlpha(1)
            if app.Transitions then app.Transitions:Settle(self, "segment") end
        end
    end
    function seg:SetEnabled(enabled)
        for _, button in ipairs(self.buttons) do button:SetEnabled(enabled) end
        self.disabled = enabled == false
    end
    if #items > 0 then seg:SetSelected(items[1].id, true) end
    return seg
end
