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
    setRing(control, ringOn and color or line, ringOn and 1 or 0)
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
        -- One shared animation class: a primary control announces the
        -- interaction with four growing hairlines on top of the static ring.
        if app.EdgePulse and (self.pulse or self.kind == "primary") then
            app.EdgePulse:Show(self)
        end
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

-- Navigation entry: selected keeps an accent edge, accent text and a small
-- accent bar on the left, independent of hover. The row itself is flat — on an
-- inset navigation well a stack of raised slabs is exactly the box look the
-- navigation was supposed to replace, so the accent bar carries the state instead.
function Controls:Navigation(parent, text, width, callback, options)
    options = options or {}
    options.flat = true
    local button = self:Button(parent, text, width or 176, callback, options)
    button.kind = "navigation"
    button.text:ClearAllPoints()
    button.text:SetPoint("LEFT", 16, 0)
    local mark = button:CreateTexture(nil, "ARTWORK")
    mark:SetSize(app.Pixel:Pixels(2), 16)
    mark:SetPoint("LEFT", 6, 0)
    local color = accent()
    mark:SetColorTexture(color[1], color[2], color[3], 1)
    mark:Hide()
    button.selectedMark = mark
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

-- Switch row: label left, a real track and thumb on the right, plus the old
-- value and runtime-status fields the settings page still reads.
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
    row.valueText:SetPoint("RIGHT", -56, 0)
    row.statusText = app.Theme:Text(row, 11, true)
    row.statusText:SetPoint("RIGHT", -128, 0)
    row.statusText:SetWidth(65)
    row.statusText:SetJustifyH("RIGHT")
    row.statusText:SetWordWrap(false)
    row.valueText:SetWidth(55)
    row.valueText:SetJustifyH("RIGHT")
    row.valueText:SetWordWrap(false)
    row.text:SetPoint("RIGHT", row.statusText, "LEFT", -8, 0)
    row.text:SetWordWrap(false)
    local track = CreateFrame("Frame", nil, row, "BackdropTemplate")
    track:SetSize(34, 16)
    track:SetPoint("RIGHT", -12, 0)
    track:EnableMouse(false)
    app.Theme:PaintSurface(track, "embedded")
    local thumb = track:CreateTexture(nil, "ARTWORK")
    thumb:SetSize(14, 14)
    thumb:SetPoint("LEFT", track, "LEFT", 1, 0)
    local color = accent()
    thumb:SetColorTexture(color[1], color[2], color[3], 1)
    row.track, row.thumb = track, thumb
    function row:Update(component)
        local on = getter() == true
        self.valueText:SetText(on and app.L.on or app.L.off)
        local c = on and accent() or app.Theme.colors.muted
        self.valueText:SetTextColor(c[1], c[2], c[3])
        self.thumb:ClearAllPoints()
        if on then
            self.thumb:SetPoint("RIGHT", self.track, "RIGHT", -1, 0)
        else
            self.thumb:SetPoint("LEFT", self.track, "LEFT", 1, 0)
        end
        self.thumb:SetColorTexture(c[1], c[2], c[3], 1)
        local raised = app.Theme.colors.raised
        if on then
            self.track:SetBackdropColor(c[1] * 0.55, c[2] * 0.55, c[3] * 0.55, 1)
        else
            self.track:SetBackdropColor(raised[1] * 1.4, raised[2] * 1.4, raised[3] * 1.4, 1)
        end
        if component then
            local status = component.status
            if on and status == "running" then
                self.statusText:SetText(app.L.statusRunning)
            elseif on and status == "failed" then
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
    input:SetFont(GameFontNormal:GetFont(), options.size or 12, "")
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

-- Horizontal value row. The label follows the drag; the profile is committed
-- once on release or wheel step, so dragging never reconciles the whole UI per
-- pixel.
function Controls:Range(parent, title, y, low, high, step, getter, setter, options)
    options = options or {}
    local width = options.width or 490
    local row = CreateFrame("Frame", nil, parent)
    row:SetSize(width, 58)
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
    local slider = CreateFrame("Slider", nil, row, "BackdropTemplate")
    slider:SetPoint("TOPLEFT", 0, -30)
    slider:SetSize(width, 8)
    slider:SetOrientation("HORIZONTAL")
    slider:SetMinMaxValues(low, high)
    slider:SetValueStep(step)
    slider:SetObeyStepOnDrag(true)
    slider:EnableMouseWheel(true)
    app.Theme:PaintSurface(slider, "embedded")
    local thumb = slider:CreateTexture(nil, "OVERLAY")
    thumb:SetSize(12, 20)
    local color = accent()
    thumb:SetColorTexture(color[1], color[2], color[3])
    slider:SetThumbTexture(thumb)
    local pending
    local function format(number)
        value:SetFormattedText("%.0f%%", number * 100)
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
    slider:SetScript("OnValueChanged", function(self, number)
        local snapped = snap(number)
        format(snapped)
        if row.updating then return end
        pending = snapped
        if not self.dragging then commit() end
    end)
    slider:SetScript("OnMouseDown", function(self)
        if row.disabled then return end
        self.dragging = true
        Controls:ClearFocus()
    end)
    slider:SetScript("OnMouseUp", function(self)
        self.dragging = false
        commit()
    end)
    slider:SetScript("OnMouseWheel", function(self, delta)
        if row.disabled then return end
        -- One wheel step is a coarse change: SetValue fires OnValueChanged,
        -- which commits exactly once because the slider is not being dragged.
        self:SetValue(snap((self:GetValue() or getter()) + delta * step))
    end)
    function slider:Refresh()
        local c = accent()
        thumb:SetColorTexture(c[1], c[2], c[3])
    end
    function row:Update()
        row.updating = true
        local current = getter()
        slider:SetValue(current)
        format(current)
        slider:Refresh()
        row.updating = false
    end
    function row:SetEnabled(enabled)
        row.disabled = enabled == false
        if row.disabled then
            pending = nil
            slider.dragging = false
        end
        if type(slider.EnableMouse) == "function" then slider:EnableMouse(not row.disabled) end
        slider:SetAlpha(row.disabled and 0.55 or 1)
    end
    function row:IsEnabled()
        return row.disabled ~= true
    end
    row.slider = slider
    row.valueLabel = value
    return row
end

-- Foldable section header: the marker and the selected state share one source.
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
        self.state.selected = self.folded
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
    bar:SetSize(6, height or 150)
    bar:SetPoint("TOPLEFT", scroll, "TOPRIGHT", 8, 0)
    bar:EnableMouseWheel(true)
    app.Theme:PaintSurface(bar, "embedded")
    local thumb = bar:CreateTexture(nil, "OVERLAY")
    thumb:SetWidth(6)
    thumb:SetHeight(40)
    local color = accent()
    thumb:SetColorTexture(color[1], color[2], color[3], 0.9)
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
        local ratio = content > 0 and math.min(1, view / content) or 1
        thumb:SetHeight(math.min(view, math.max(16, math.floor((view - 2) * ratio))))
    end
    return scroll
end
