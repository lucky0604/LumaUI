local _, app = ...
local Ownership = { records = {} }
app.Ownership = Ownership

-- One shared vocabulary for "who draws this control right now". A component
-- keeps its own enable/disable logic; this table only records what that logic
-- concluded, so diagnostics can separate four things the old reports merged:
--
--   intent    the profile asked for this (native, owned, styled, off)
--   active    what is actually on screen this run (native, owned, styled, none)
--   evidence  none / simulated / validated in the current client build
--   reason    a short ASCII token when active is not what intent asked for
--
-- Nothing here reads or stores a unit value: only plain strings a component
-- already decided are recorded. A record is replaced atomically, so a failed
-- handover cannot leave half of a previous conclusion behind.

local INTENT = { native = true, owned = true, styled = true, off = true }
local ACTIVE = { native = true, owned = true, styled = true, none = true }
local EVIDENCE = { none = true, simulated = true, validated = true }

local function token(value, allowed, fallback)
    if type(value) == "string" and allowed[value] then return value end
    return fallback
end

local function plainText(value, limit)
    value = app.Capabilities.Plain(value, "string")
    if not value or value == "" then return nil end
    value = value:gsub("[%c|]", "")
    if #value > (limit or 48) then value = value:sub(1, limit or 48) end
    if value == "" then return nil end
    return value
end

function Ownership:Set(id, state)
    -- A dotted id names a part of one component ("unitFrames.playerCast"), so
    -- one control can report its visible layer and its sub-parts separately.
    if type(id) ~= "string" or not id:match("^[%a][%w_%.]*$") then return false end
    state = type(state) == "table" and state or {}
    self.records[id] = {
        intent = token(state.intent, INTENT, "native"),
        active = token(state.active, ACTIVE, "native"),
        evidence = token(state.evidence, EVIDENCE, "none"),
        reason = plainText(state.reason, 48),
    }
    return true
end

function Ownership:Get(id)
    return id and self.records[id] or nil
end

function Ownership:Clear(id)
    if id then
        self.records[id] = nil
        return
    end
    self.records = {}
end

-- Sets only the "active" side of an existing record: a component that is
-- stopping keeps the intent the profile still holds, so the next report does
-- not read "the player chose native" when the module was merely disabled.
function Ownership:Active(id, active, reason, evidence)
    local record = self.records[id]
    if not record then return false end
    record.active = token(active, ACTIVE, record.active)
    record.reason = plainText(reason, 48)
    if evidence then record.evidence = token(evidence, EVIDENCE, record.evidence) end
    return true
end

function Ownership:IDs()
    local list = {}
    for id in pairs(self.records) do list[#list + 1] = id end
    table.sort(list)
    return list
end

function Ownership:Describe(id)
    local record = self.records[id]
    if not record then return nil end
    local text = string.format("%s: intent=%s active=%s evidence=%s",
        id, record.intent, record.active, record.evidence)
    if record.reason then text = text .. " reason=" .. record.reason end
    return text
end

-- One line per recorded control, sorted, for the diagnostics page and
-- `/luma ownership`. A component that never registered is simply absent; the
-- page says so instead of implying every control was audited.
function Ownership:Lines()
    local lines = {}
    for _, id in ipairs(self:IDs()) do lines[#lines + 1] = self:Describe(id) end
    return lines
end

-- A handover that failed keeps the native path and names why. Called by the
-- components that already know the concrete reason; the helper only keeps the
-- four fields consistent so no caller writes "owned" while native still draws.
function Ownership:HandedBack(id, intent, reason)
    return self:Set(id, { intent = intent or "owned", active = "native",
        evidence = "none", reason = reason or "not-validated" })
end

function Ownership:HandedOver(id, active, evidence, reason)
    return self:Set(id, { intent = "owned", active = active or "owned",
        evidence = evidence or "simulated", reason = reason })
end
