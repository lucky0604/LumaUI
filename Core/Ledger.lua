local _, app = ...
local Ledger = {}
app.Ledger = Ledger

-- Account ledger (Phase 09). Plain rows only, kept in the LumaUIDB root and never
-- in a profile. A row is one balance of one currency (id 0 = money, in copper)
-- observed for one character or for one warband scope of one source. A missing
-- row means "not read"; a stored 0 means "confirmed zero".
--
-- Snapshots use the fixed-line text protocol LUMA-WALLET/1. Parsing is plain
-- string work with explicit bounds: no load/loadstring, no SavedVariables import,
-- everything is validated before the single write.
Ledger.version = 1
Ledger.limits = { bytes = 256 * 1024, rows = 2000, name = 96, quantity = 1000000000000, sources = 16 }

local HEADER = "LUMA-WALLET/1"
local SAFE = "[%w%-_%.]"

local function finite(value)
    return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function escape(text)
    return (tostring(text):gsub("[^%w%-_%.]", function(c) return string.format("%%%02X", c:byte()) end))
end

local function unescape(text)
    if text:find("%%") then
        if text:find("%%[^%x]") or text:find("%%%x[^%x]") or text:find("%%%x?$") then return nil end
    end
    if text:find("[^%w%-_%.%%]") then return nil end
    return (text:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

local function regionOf(value)
    if type(value) ~= "string" or value == "" then return "?" end
    value = value:upper():sub(1, 4)
    if value:find("[^A-Z0-9?]") then return "?" end
    return value
end

local function now()
    local time = type(GetServerTime) == "function" and GetServerTime() or nil
    return finite(time) and math.floor(time) or nil
end

local function key(source, scope, char, currency)
    return table.concat({ source, scope, char, currency }, "|")
end

local function cleanName(name)
    if type(name) ~= "string" or name == "" or #name > Ledger.limits.name then return nil end
    return name
end

local function cleanRow(row)
    if type(row) ~= "table" then return nil end
    if row.scope ~= "c" and row.scope ~= "w" then return nil end
    if type(row.source) ~= "string" or row.source == "" or #row.source > 48 then return nil end
    if type(row.char) ~= "string" or row.char == "" or #row.char > 128 then return nil end
    if not finite(row.currency) or row.currency < 0 or row.currency ~= math.floor(row.currency) then return nil end
    if not finite(row.qty) or row.qty < 0 or row.qty > Ledger.limits.quantity then return nil end
    local seen = finite(row.seen) and row.seen >= 0 and math.floor(row.seen) or nil
    return {
        source = row.source, scope = row.scope, char = row.char, name = cleanName(row.name) or row.char,
        region = regionOf(row.region), currency = row.currency, qty = math.floor(row.qty), seen = seen,
        imported = row.imported == true,
    }
end

-- Normalized account data, sanitized once per load.
function Ledger:Data()
    local store = app.Store
    local data = store and store.data
    if type(data) ~= "table" then return { sources = {}, rows = {} } end
    local ledger = data.ledger
    if type(ledger) ~= "table" or ledger.clean ~= self then
        local clean = { sources = {}, rows = {}, version = 1 }
        if type(ledger) == "table" and type(ledger.sources) == "table" then
            local count = 0
            for id, info in pairs(ledger.sources) do
                if type(id) == "string" and #id <= 48 and type(info) == "table" and count < self.limits.sources then
                    count = count + 1
                    clean.sources[id] = {
                        name = cleanName(info.name) or id, region = regionOf(info.region),
                        group = type(info.group) == "string" and #info.group <= 48 and info.group or nil,
                        imported = info.imported == true,
                    }
                end
            end
        end
        if type(ledger) == "table" and type(ledger.rows) == "table" then
            local count = 0
            for _, row in pairs(ledger.rows) do
                local ok = cleanRow(row)
                if ok and clean.sources[ok.source] and count < self.limits.rows then
                    count = count + 1
                    clean.rows[key(ok.source, ok.scope, ok.char, ok.currency)] = ok
                end
            end
        end
        data.ledger = clean
        clean.clean = self
        ledger = clean
    end
    return ledger
end

local function writable()
    return app.Store and not app.Store.readonly and type(app.Store.data) == "table"
end

function Ledger:LocalSource()
    local data = self:Data()
    local id = "local"
    if not data.sources[id] then
        data.sources[id] = { name = "Local", region = regionOf(type(GetCurrentRegionName) == "function" and GetCurrentRegionName() or nil), imported = false }
    end
    return id, data.sources[id]
end

function Ledger:RenameSource(id, name)
    if not writable() then return false end
    local data = self:Data()
    local info = data.sources[id]
    name = cleanName(name)
    if not info or not name then return false end
    info.name = name
    return true
end

-- Character identity: a readable plain GUID wins; otherwise the protected
-- realm/name key. Unreadable identity records nothing.
function Ledger:Identity(guid, character)
    if type(guid) == "string" and guid ~= "" and not (app.Capabilities and app.Capabilities.IsSecret and app.Capabilities.IsSecret(guid)) then
        return "g:" .. guid
    end
    if type(character) == "string" and character ~= "" then return "n:" .. character end
end

-- Record one live observation. Only plain numbers are stored; anything else
-- leaves the previous row alone (never turned into 0).
function Ledger:Record(scope, char, display, currency, qty, seen)
    if not writable() then return false end
    if not char or not finite(currency) or not finite(qty) or qty < 0 then return false end
    local data = self:Data()
    local source = self:LocalSource()
    local row = cleanRow({
        source = source, scope = scope, char = char, name = display, region = data.sources[source].region,
        currency = currency, qty = qty, seen = seen or now(),
    })
    if not row then return false end
    data.rows[key(source, scope, char, currency)] = row
    return true
end

-- Legacy root money: kept as the character balances' fallback. Rows without an
-- observation time are reported as old, never as freshly read.
function Ledger:Money()
    local list = {}
    local data = self:Data()
    local live = {}
    for _, row in pairs(data.rows) do
        if row.scope == "c" and row.currency == 0 then
            local existing = live[row.char]
            if not existing or (row.seen or -1) > (existing.seen or -1) then live[row.char] = row end
            list[#list + 1] = row
        end
    end
    local legacy = app.Store and app.Store.money
    if type(legacy) == "table" then
        for name, amount in pairs(legacy) do
            if not live["n:" .. name] then
                list[#list + 1] = { source = "local", scope = "c", char = "n:" .. name, name = name, currency = 0, qty = amount, legacy = true }
            end
        end
    end
    table.sort(list, function(a, b) return a.name < b.name end)
    return list
end

-- Total of one currency. Character rows add up. Warband rows count once per
-- warband group (sources the user grouped share a group id); an ungrouped
-- source is its own group. Returns total, ambiguous(list of groups left out).
function Ledger:Total(currency, region)
    local data = self:Data()
    local sum, warband, seen = 0, 0, {}
    for _, row in pairs(data.rows) do
        if row.currency == currency and (not region or row.region == region) then
            if row.scope == "c" then
                sum = sum + row.qty
            else
                local info = data.sources[row.source]
                local group = (info and info.group) or row.source
                local slot = group .. "|" .. row.region
                if not seen[slot] or (row.seen or -1) > (seen[slot].seen or -1) then seen[slot] = row end
            end
        end
    end
    for _, row in pairs(seen) do warband = warband + row.qty end
    return sum, warband
end

-- Export of the own local ledger only; imported rows are not forwarded.
function Ledger:Export()
    local data = self:Data()
    local sourceID, info = self:LocalSource()
    local lines = { HEADER, table.concat({ "S", escape(sourceID), info.region, escape(info.name) }, "\t") }
    local keys = {}
    for k, row in pairs(data.rows) do
        if row.source == sourceID and not row.imported then keys[#keys + 1] = k end
    end
    table.sort(keys)
    for _, k in ipairs(keys) do
        local row = data.rows[k]
        lines[#lines + 1] = table.concat({
            "R", row.scope, escape(row.char), escape(row.name), tostring(row.currency), tostring(row.qty), tostring(row.seen or 0),
        }, "\t")
    end
    return table.concat(lines, "\n") .. "\n"
end

local function number(text, maximum)
    if not text or not text:find("^%d+$") or #text > 15 then return nil end
    local value = tonumber(text)
    if not value or value > maximum then return nil end
    return value
end

-- Parse and validate everything; no state changes. Returns plan or nil, reason.
function Ledger:Preview(text)
    local limits = self.limits
    if type(text) ~= "string" then return nil, "type" end
    if #text > limits.bytes then return nil, "size" end
    local lines = {}
    for line in (text:gsub("\r", "") .. "\n"):gmatch("([^\n]*)\n") do
        if line ~= "" then
            lines[#lines + 1] = line
            if #lines > limits.rows + 2 then return nil, "rows" end
        end
    end
    if lines[1] ~= HEADER then return nil, "header" end
    local source = lines[2] and { lines[2]:match("^S\t([^\t]*)\t([^\t]*)\t([^\t]*)$") }
    if not source or not source[1] then return nil, "source" end
    local id, region, alias = unescape(source[1]), source[2], unescape(source[3])
    if not id or id == "" or #id > 40 or not alias or #alias > limits.name or alias == "" then return nil, "source" end
    if region == "" or #region > 4 or region:find("[^A-Z0-9?]") then return nil, "region" end
    local sourceID = "imp:" .. id
    local rows = {}
    for index = 3, #lines do
        local scope, char, name, currency, qty, seen = lines[index]:match("^R\t([cw])\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)$")
        if not scope then return nil, "row" end
        char, name = unescape(char), unescape(name)
        currency, qty, seen = number(currency, 2147483647), number(qty, limits.quantity), number(seen, 4102444800)
        if not char or char == "" or #char > 128 or not name or #name > limits.name or name == "" or not currency or not qty or not seen then
            return nil, "row"
        end
        rows[#rows + 1] = { source = sourceID, scope = scope, char = char, name = name, region = region, currency = currency, qty = qty, seen = seen > 0 and seen or nil, imported = true }
    end
    local data = self:Data()
    local plan = { sourceID = sourceID, name = alias, region = region, rows = rows, added = 0, updated = 0, unchanged = 0, stale = 0 }
    for _, row in ipairs(rows) do
        local existing = data.rows[key(row.source, row.scope, row.char, row.currency)]
        if not existing then
            plan.added = plan.added + 1
        elseif (row.seen or 0) < (existing.seen or 0) then
            plan.stale = plan.stale + 1
        elseif existing.qty == row.qty and (existing.seen or 0) == (row.seen or 0) then
            plan.unchanged = plan.unchanged + 1
        else
            plan.updated = plan.updated + 1
        end
    end
    if not data.sources[sourceID] and self:SourceCount() >= limits.sources then return nil, "sources" end
    return plan
end

function Ledger:SourceCount()
    local count = 0
    for _ in pairs(self:Data().sources) do count = count + 1 end
    return count
end

-- One write after a validated preview. Older values never replace newer ones
-- of the same source.
function Ledger:Commit(plan)
    if not plan or not writable() then return false end
    local data = self:Data()
    local info = data.sources[plan.sourceID]
    if not info then
        info = { name = plan.name, region = plan.region, imported = true }
        data.sources[plan.sourceID] = info
    end
    for _, row in ipairs(plan.rows) do
        local k = key(row.source, row.scope, row.char, row.currency)
        local existing = data.rows[k]
        if not existing or (row.seen or 0) >= (existing.seen or 0) then data.rows[k] = cleanRow(row) end
    end
    return true
end

-- Same-region sources the user declares to be one warband share one group id,
-- so their warband rows count once. Undeclared sources stay separate.
function Ledger:Group(sourceA, sourceB)
    if not writable() then return false end
    local data = self:Data()
    local a, b = data.sources[sourceA], data.sources[sourceB]
    if not a or not b or sourceA == sourceB or a.region ~= b.region then return false end
    local group = a.group or b.group or ("grp:" .. sourceA)
    a.group, b.group = group, group
    return true
end

-- Current character currencies: the known ids come from the currency list
-- (headers skipped); each balance is read through GetCurrencyInfo. An id the
-- client does not answer for is left alone (unread, not zero). The native list
-- is never opened or expanded.
function Ledger:ReadCurrencies(character, guid)
    local api = rawget(_G, "C_CurrencyInfo")
    if type(api) ~= "table" or type(api.GetCurrencyListSize) ~= "function"
        or type(api.GetCurrencyListInfo) ~= "function" or type(api.GetCurrencyInfo) ~= "function" then return 0 end
    local id = self:Identity(guid, character)
    local plain = app.Capabilities.Plain
    if not id then return 0 end
    local okSize, size = pcall(api.GetCurrencyListSize)
    size = okSize and plain(size, "number") or 0
    local recorded = 0
    for index = 1, size do
        local okInfo, entry = pcall(api.GetCurrencyListInfo, index)
        local currency = okInfo and type(entry) == "table" and plain(entry.currencyID, "number")
        if currency and plain(entry.isHeader, "boolean") ~= true and currency > 0 then
            local okRead, info = pcall(api.GetCurrencyInfo, currency)
            local qty = okRead and type(info) == "table" and plain(info.quantity, "number") or nil
            if qty and self:Record("c", id, character, currency, qty) then recorded = recorded + 1 end
        end
    end
    return recorded
end

-- Warband-visible character balances. The request is made once while pending;
-- rows arrive with ACCOUNT_CHARACTER_CURRENCY_DATA_RECEIVED. Only plain fields
-- are stored; an unanswered or unreadable row is skipped, never turned into 0.
function Ledger:RequestWarband()
    local api = rawget(_G, "C_CurrencyInfo")
    if type(api) ~= "table" or type(api.RequestCurrencyDataForAccountCharacters) ~= "function" then return false end
    if type(api.IsAccountCharacterCurrencyDataReady) == "function" then
        local ok, ready = pcall(api.IsAccountCharacterCurrencyDataReady)
        if ok and ready == true then return true end
    end
    if self.requested then return false end
    self.requested = true
    pcall(api.RequestCurrencyDataForAccountCharacters)
    return false
end

function Ledger:ReadWarband(currencyID)
    self.requested = nil
    local api = rawget(_G, "C_CurrencyInfo")
    local plain = app.Capabilities.Plain
    if type(api) ~= "table" or type(api.FetchCurrencyDataFromAccountCharacters) ~= "function" then return 0 end
    if not plain(currencyID, "number") then return 0 end
    local ok, list = pcall(api.FetchCurrencyDataFromAccountCharacters, currencyID)
    if not ok or type(list) ~= "table" then return 0 end
    local count = 0
    for _, entry in ipairs(list) do
        if type(entry) == "table" then
            local guid = plain(entry.characterGUID, "string")
            local name = plain(entry.fullCharacterName, "string") or plain(entry.characterName, "string")
            local qty = plain(entry.quantity, "number")
            local id = self:Identity(guid, name)
            if id and qty and self:Record("c", id, name or id, currencyID, qty) then count = count + 1 end
        end
    end
    return count
end

-- Warband bank gold: a separate warband-scope row, never merged into carried gold.
-- Only called when the bank answers; a refused read keeps the previous row.
function Ledger:ReadBankMoney()
    local bank, enum = rawget(_G, "C_Bank"), rawget(_G, "Enum")
    if type(bank) ~= "table" or type(bank.FetchDepositedMoney) ~= "function" then return false end
    local kind = type(enum) == "table" and type(enum.BankType) == "table" and enum.BankType.Account
    if kind == nil then return false end
    local ok, amount = pcall(bank.FetchDepositedMoney, kind)
    amount = ok and app.Capabilities.Plain(amount, "number") or nil
    if not amount then return false end
    return self:Record("w", "bank", "Warband bank", 0, amount)
end

-- Known currency ids of the own rows (money excluded): the set a warband fetch
-- is asked about. The API has no full enumeration, so nothing else is probed.
function Ledger:KnownCurrencies()
    local seen, list = {}, {}
    for _, row in pairs(self:Data().rows) do
        if row.currency > 0 and not seen[row.currency] then
            seen[row.currency] = true
            list[#list + 1] = row.currency
        end
    end
    table.sort(list)
    return list
end

function Ledger:ReadAllWarband()
    local count = 0
    for _, id in ipairs(self:KnownCurrencies()) do count = count + self:ReadWarband(id) end
    return count
end

-- Pinned currencies (profile setting, at most four ids). Toggle returns the new
-- pinned state, or nil when the data is read-only.
function Ledger:TogglePin(currency)
    if not writable() or not finite(currency) or currency <= 0 or currency ~= math.floor(currency) then return nil end
    local list, out, found = app.Store:Profile().ui.pinnedCurrencies or {}, {}, false
    for _, id in ipairs(list) do
        if id == currency then found = true else out[#out + 1] = id end
    end
    if not found then
        if #out >= 4 then return nil end
        out[#out + 1] = currency
    end
    if not app.Store:Set("ui", "pinnedCurrencies", out) then return nil end
    return not found
end

-- Footer text: "name quantity" for each pinned id the client answers for.
-- Unanswered ids are left out rather than shown as 0.
function Ledger:PinnedText()
    local api, plain, parts = rawget(_G, "C_CurrencyInfo"), app.Capabilities.Plain, {}
    if type(api) ~= "table" or type(api.GetCurrencyInfo) ~= "function" then return "" end
    for _, id in ipairs(app.Store:Profile().ui.pinnedCurrencies or {}) do
        local ok, info = pcall(api.GetCurrencyInfo, id)
        local qty = ok and type(info) == "table" and plain(info.quantity, "number") or nil
        if qty then parts[#parts + 1] = string.format("%d: %d", id, qty) end
    end
    return table.concat(parts, "  ")
end

-- Filtered rows for the ledger list: by currency id (number) or source id
-- (string); no filter returns everything. Sorted for stable output.
function Ledger:Rows(filter)
    local out = {}
    for _, row in pairs(self:Data().rows) do
        if filter == nil or row.currency == filter or row.source == filter then out[#out + 1] = row end
    end
    table.sort(out, function(a, b)
        if a.currency ~= b.currency then return a.currency < b.currency end
        if a.source ~= b.source then return a.source < b.source end
        return a.char < b.char
    end)
    return out
end
