-- SPDX-License-Identifier: GPL-3.0-or-later
-- Durable, bounded records for outward-road operations. Pure: mod storage and
-- the serialization codec are injected. One document per settlement holds a
-- short list of operations. Nothing here writes terrain, and a record that was
-- once possibly written is never made to look unused.
local store = {}

local SCHEMA = 1
local PREFIX = "outward/v1/settlement/"
local MAX_DOC_BYTES = 65536
local KEEP_NON_RESERVING = 4

local function err(code, reason, extra)
    local result = extra or {}
    result.code = code; result.reason = reason
    return nil, result
end
local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for k, v in pairs(value) do result[k] = copy(v) end
    return result
end

-- Scope of the reservation an operation holds, or nil. A built road reserves
-- the whole settlement (at most one successful road each). A partial road, or
-- an operation that may have written, reserves only its own exit.
local function reservation(op)
    if op.state == "built" then return "settlement" end
    if op.state == "partial" or op.state == "building" then return "exit" end
    if op.state == "interrupted" and op.writes ~= "none" then return "exit" end
    return nil
end
store.reservation = reservation

local function valid_doc(settlement_id, doc)
    if type(doc) ~= "table" or doc.schema ~= SCHEMA or doc.settlement_id ~= settlement_id
        or type(doc.next_seq) ~= "number" or type(doc.operations) ~= "table" then return false end
    for _, op in ipairs(doc.operations) do
        if type(op) ~= "table" or type(op.op_id) ~= "string" or type(op.exit_id) ~= "string"
            or type(op.seq) ~= "number" or type(op.state) ~= "string" or type(op.writes) ~= "string" then
            return false
        end
    end
    return true
end

-- options: storage={get,set,keys}, serialize, deserialize, now (os.time)
function store.new(options)
    local storage, serialize, deserialize = options.storage, options.serialize, options.deserialize
    local now = options.now or function() return 0 end
    local self = {}
    local cache = {} -- settlement_id -> {doc=..., unreadable=reason, dirty=bool}

    local function key(settlement_id) return PREFIX .. settlement_id end

    local function persist(settlement_id, entry)
        local ok, text = pcall(serialize, entry.doc)
        if not ok or type(text) ~= "string" then return err("storage_failed", "cannot serialize the operation record") end
        -- Bound the record: older zero-write operations are dropped first.
        while #text > MAX_DOC_BYTES do
            local dropped
            local ops = entry.doc.operations
            for i = 1, #ops - 1 do -- never drop the newest (in-flight) operation
                if not reservation(ops[i]) then table.remove(ops, i); dropped = true; break end
            end
            if not dropped then return err("storage_failed", "operation record exceeds " .. MAX_DOC_BYTES .. " bytes") end
            ok, text = pcall(serialize, entry.doc)
            if not ok or type(text) ~= "string" then return err("storage_failed", "cannot serialize the operation record") end
        end
        local set_ok, set_err = pcall(storage.set, key(settlement_id), text)
        if not set_ok then return err("storage_failed", "mod storage write failed: " .. tostring(set_err)) end
        local get_ok, back = pcall(storage.get, key(settlement_id))
        if not get_ok or back ~= text then return err("storage_failed", "operation record read-back mismatch") end
        return true
    end

    -- Keep every reserving operation and the newest few others.
    local function retain(doc)
        local kept, others = {}, {}
        for _, op in ipairs(doc.operations) do
            if not reservation(op) then others[#others + 1] = op end
        end
        local drop = {}
        for i = 1, #others - KEEP_NON_RESERVING do drop[others[i]] = true end
        for _, op in ipairs(doc.operations) do if not drop[op] then kept[#kept + 1] = op end end
        doc.operations = kept
    end

    -- Operations that were mid-flight can never be live in a freshly loaded
    -- document: convert them without replaying anything.
    local function convert(entry)
        local changed = 0
        for _, op in ipairs(entry.doc.operations) do
            if op.state == "planning" then
                op.state = "interrupted"; op.writes = "none"; op.updated_at = now()
                op.error = op.error or {code = "interrupted", reason = "restart interrupted planning; no writes were made"}
                changed = changed + 1
            elseif op.state == "building" then
                op.state = "interrupted"; op.writes = "unknown"; op.updated_at = now()
                op.error = {code = "interrupted", reason = "restart interrupted a possibly started build; writes are unknown"}
                changed = changed + 1
            end
        end
        return changed
    end

    local function load(settlement_id)
        local entry = cache[settlement_id]
        if entry then return entry end
        local ok, text = pcall(storage.get, key(settlement_id))
        if not ok then
            entry = {unreadable = "mod storage read failed"}
        elseif text == nil or text == "" then
            entry = {doc = {schema = SCHEMA, settlement_id = settlement_id, next_seq = 1, operations = {}}, fresh = true}
        else
            local decoded_ok, doc = pcall(deserialize, text)
            if decoded_ok and valid_doc(settlement_id, doc) then
                entry = {doc = doc}
                if convert(entry) > 0 then entry.dirty = true end
            else
                entry = {unreadable = "stored operation record is unreadable or has an unsupported schema"}
            end
        end
        cache[settlement_id] = entry
        return entry
    end

    local function flush(settlement_id, entry)
        if entry.dirty and entry.doc then
            local ok, why = persist(settlement_id, entry)
            if ok then entry.dirty = nil else return nil, why end
        end
        return true
    end

    -- The document of a settlement, or nil plus an error when unreadable.
    -- Retries a conversion save that failed earlier.
    function self:doc(settlement_id)
        local entry = load(settlement_id)
        if entry.unreadable then return err("unreadable", entry.unreadable) end
        flush(settlement_id, entry)
        return entry.doc
    end

    -- 'open' | 'reserved' | 'unreadable', detail. exit_id may be nil to ask
    -- only about settlement-wide reservations.
    function self:eligibility(settlement_id, exit_id)
        local entry = load(settlement_id)
        if entry.unreadable then return "unreadable", {scope = "settlement", reason = entry.unreadable} end
        for _, op in ipairs(entry.doc.operations) do
            local scope = reservation(op)
            if scope == "settlement" or (scope == "exit" and exit_id ~= nil and op.exit_id == exit_id) then
                return "reserved", {scope = scope, op_id = op.op_id, state = op.state, writes = op.writes, exit_id = op.exit_id}
            end
        end
        return "open"
    end

    -- Create an operation in memory only (not yet durable).
    function self:new_op(settlement_id, exit_id, fields)
        local entry = load(settlement_id)
        if entry.unreadable then return err("storage_failed", entry.unreadable) end
        local seq = entry.doc.next_seq
        entry.doc.next_seq = seq + 1
        local op = copy(fields or {})
        op.op_id = settlement_id .. "/" .. exit_id .. "#" .. seq
        op.seq = seq; op.exit_id = exit_id
        op.state = "planning"; op.writes = "none"
        op.created_at = now(); op.updated_at = op.created_at
        entry.doc.operations[#entry.doc.operations + 1] = op
        return op
    end

    -- Persist a settlement document with read-back verification. On failure
    -- the in-memory document is unchanged so reservations still apply.
    function self:save(settlement_id, op)
        local entry = load(settlement_id)
        if entry.unreadable then return err("storage_failed", entry.unreadable) end
        if op then op.updated_at = now() end
        retain(entry.doc)
        local ok, why = persist(settlement_id, entry)
        if not ok then entry.dirty = true; return nil, why end
        entry.dirty = nil
        return true
    end

    -- Remove an operation that was never made durable (the accept save failed).
    function self:discard(settlement_id, op)
        local entry = cache[settlement_id]
        if not entry or not entry.doc then return end
        for i, candidate in ipairs(entry.doc.operations) do
            if candidate == op then table.remove(entry.doc.operations, i); break end
        end
        if op.seq == entry.doc.next_seq - 1 then entry.doc.next_seq = op.seq end
    end

    function self:latest(settlement_id)
        local entry = load(settlement_id)
        if entry.unreadable then return nil, {code = "unreadable", reason = entry.unreadable} end
        local ops = entry.doc.operations
        return ops[#ops] and copy(ops[#ops]) or nil
    end

    function self:find(settlement_id, op_id)
        local entry = load(settlement_id)
        for _, op in ipairs(entry.doc and entry.doc.operations or {}) do
            if op.op_id == op_id then return op end
        end
    end

    -- Startup sweep: load every outward document, convert interrupted work,
    -- and report what was found. Never builds anything.
    function self:recover()
        local summary = {settlements = 0, converted = 0, unreadable = 0, failed_saves = 0}
        local ok, keys = pcall(storage.keys)
        if not ok or type(keys) ~= "table" then return nil, {code = "storage_failed", reason = "cannot list stored operations"} end
        table.sort(keys)
        for _, k in ipairs(keys) do
            if type(k) == "string" and k:sub(1, #PREFIX) == PREFIX then
                local settlement_id = k:sub(#PREFIX + 1)
                local was_cached = cache[settlement_id] ~= nil
                local entry = load(settlement_id)
                summary.settlements = summary.settlements + 1
                if entry.unreadable then summary.unreadable = summary.unreadable + 1
                else
                    if entry.dirty and not was_cached then summary.converted = summary.converted + 1 end
                    local flushed = flush(settlement_id, entry)
                    if not flushed then summary.failed_saves = summary.failed_saves + 1 end
                end
            end
        end
        return summary
    end

    return self
end

store.PREFIX = PREFIX
store.MAX_DOC_BYTES = MAX_DOC_BYTES
return store
