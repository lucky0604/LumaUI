local _, app = ...

-- Private aura anchors. Some encounter debuffs are "private auras": the client
-- lets an addon reserve a native display for them but never exposes the aura's
-- name, duration, stacks or ordering to Lua. The only supported interaction is
-- C_UnitAuras.AddPrivateAuraAnchor(args), which returns an anchor id, and
-- C_UnitAuras.RemovePrivateAuraAnchor(id); both are documented as
-- SecretArguments = "AllowedWhenUntainted".
--
-- Contract used here (UnitAuraDocumentation / UnitConstantsDocumentation, and
-- Blizzard_UnitFrame/Shared/CompactUnitFrame.lua as the reference use):
--   args = unitToken, auraIndex, parent, showCooldownFrame, showCooldownEdge,
--          showCountdownNumbers, showDispelIcon, isContainer,
--          iconInfo = { iconAnchor = { point, relativeTo, relativePoint,
--          offsetX, offsetY }, iconWidth, iconHeight, borderScale }
--   isContainer = false reserves one display slot per auraIndex; the client
--   draws the private aura at that index (in its own priority order) inside the
--   slot. Ordering, time, stacks and the icon itself are engine-drawn — nothing
--   here reads or reasons about aura content.
--   Every anchor belongs to exactly one unitToken; the client's secure watcher
--   rejects an anchor for any other unit.
--
-- Lifecycle: anchors are created and removed only from the non-combat queue
-- (their display is parented to a secure unit button). Each call is pcall'ed,
-- so one rejected slot only costs that slot; the caller decides what a partial
-- or total failure means for its own takeover. The anchor count per frame is
-- fixed by the caller, so attach is idempotent and a reused button can never
-- show another member's private aura.

local PrivateAuras = { attached = 0 }
app.PrivateAuras = PrivateAuras

function PrivateAuras.Available()
    return type(C_UnitAuras) == "table" and type(C_UnitAuras.AddPrivateAuraAnchor) == "function"
end

local function removeAnchors(frame)
    local ids = frame.lumaPrivateAnchors
    frame.lumaPrivateAnchors = nil
    if not ids then return 0 end
    local removed = 0
    for index = 1, #ids do
        if pcall(C_UnitAuras.RemovePrivateAuraAnchor, ids[index]) then removed = removed + 1 end
    end
    PrivateAuras.attached = math.max(0, PrivateAuras.attached - removed)
    return removed
end

-- Releases every anchor this frame owns; safe when none is attached.
function PrivateAuras.Release(frame)
    if not frame then return end
    frame.lumaPrivateUnit = nil
    frame.lumaPrivateCount = nil
    frame.lumaPrivateComplete = nil
    removeAnchors(frame)
end

-- Slots run along `point` on the frame, one per aura index, `step` apart:
-- index 1 sits at offsetX/offsetY and each later index moves away from the
-- corner by one step. Options are plain numbers chosen by the caller, never
-- values read from the client.
--
-- An attempt for the same unit and slot count is not repeated, even when the
-- client refused every anchor: the caller then sees no slots and keeps the
-- native frame, and a burst of roster events does not hammer a rejection.
-- Attach returns true only when every slot was granted; a partial grant still
-- records what it got (so Release removes it) but never counts as coverage.
-- One line for the diagnostics page: how many anchors this session holds and
-- whether the client exposes the API at all. No aura content is read.
function PrivateAuras.Describe()
    return string.format("privateAuras: attached=%d api=%s owner=native",
        PrivateAuras.attached or 0, PrivateAuras.Available() and "yes" or "no")
end

function PrivateAuras.Attach(frame, unit, count, options)
    if not frame or not unit or not count or count < 1 then return false end
    if not PrivateAuras.Available() then return false end
    if frame.lumaPrivateUnit == unit and frame.lumaPrivateCount == count then
        return frame.lumaPrivateComplete == true
    end
    removeAnchors(frame)
    frame.lumaPrivateUnit = nil
    frame.lumaPrivateCount = nil
    local ids = {}
    for index = 1, count do
        local args = {
            unitToken = unit,
            auraIndex = index,
            parent = frame,
            showCooldownFrame = true,
            showCooldownEdge = false,
            showCountdownNumbers = false,
            showDispelIcon = true,
            isContainer = false,
            iconInfo = {
                iconWidth = options.size,
                iconHeight = options.size,
                iconAnchor = {
                    point = options.point,
                    relativeTo = frame,
                    relativePoint = options.point,
                    offsetX = options.offsetX + (index - 1) * options.step,
                    offsetY = options.offsetY,
                },
            },
        }
        local ok, id = pcall(C_UnitAuras.AddPrivateAuraAnchor, args)
        id = ok and app.Capabilities.Plain(id, "number") or nil
        if id then ids[#ids + 1] = id end
    end
    frame.lumaPrivateUnit = unit
    frame.lumaPrivateCount = count
    frame.lumaPrivateAnchors = #ids > 0 and ids or nil
    frame.lumaPrivateComplete = #ids == count or nil
    PrivateAuras.attached = PrivateAuras.attached + #ids
    return frame.lumaPrivateComplete == true
end
