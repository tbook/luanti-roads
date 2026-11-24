-- SPDX-License-Identifier: GPL-3.0-or-later
-- Durable, bounded records for road growth. Pure: mod storage and the codec
-- are injected. One registry document is the authority for roads, endpoint
-- revisions, pending intent, claims and the footprint index; immutable
-- geometry lives in separate segment records. Nothing here touches terrain.
-- A record that may have been written is never made to look unused.
local store = {}

local SCHEMA = 1
local PREFIX = "growth/v1/"
local REGISTRY_KEY = PREFIX .. "registry"
local SEGMENT_PREFIX = PREFIX .. "segment/"
local LIMITS = {roads = 128, segments = 1024, road_segments = 128, segment_bytes = 131072,
    registry_bytes = 4194304, cells = 16, references = 16384, cell_size = 128,
    query_cells = 100, query_references = 1024, attempts = 4, claims = 2048}
store.LIMITS = LIMITS

local ROAD_STATES = {open = true, planning = true, building = true, stopped = true, uncertain = true,
    retired = true, connected = true}
-- Segment/seed entries that reserve space in the index.
local SEGMENT_STATES = {intended = true, verified = true, unverified = true, building = true,
    built = true, uncertain = true}

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
local function integer(n) return type(n) == "number" and n == math.floor(n) and math.abs(n) <= 31000 end
local function point(p) return type(p) == "table" and integer(p.x) and integer(p.y) and integer(p.z) end
local function count(t) local n = 0; for _ in pairs(t) do n = n + 1 end; return n end

-- Growth-wide cell identity for the spatial index.
function store.cell(x, z)
    return math.floor(x / LIMITS.cell_size) .. ":" .. math.floor(z / LIMITS.cell_size)
end

local function valid_entry(id, e)
    if type(id) ~= "string" or type(e) ~= "table" or not SEGMENT_STATES[e.state]
        or (e.kind ~= "seed" and e.kind ~= "segment") or type(e.writes) ~= "string"
        or type(e.cells) ~= "table" or #e.cells < 1 or #e.cells > LIMITS.cells
        or type(e.bounds) ~= "table" or not integer(e.bounds.x1) or not integer(e.bounds.z1)
        or not integer(e.bounds.x2) or not integer(e.bounds.z2)
        or (e.road_id ~= nil and type(e.road_id) ~= "string") then
        return false
    end
    for _, c in ipairs(e.cells) do if type(c) ~= "string" then return false end end
    return true
end

local function valid_registry(reg)
    if type(reg) ~= "table" or type(reg.roads) ~= "table" or type(reg.segs) ~= "table"
        or type(reg.claims) ~= "table" then return false end
    if count(reg.roads) > LIMITS.roads or count(reg.segs) > LIMITS.segments
        or count(reg.claims) > LIMITS.claims then return false end
    for id, entry in pairs(reg.segs) do if not valid_entry(id, entry) then return false end end
    for id, road in pairs(reg.roads) do
        if type(id) ~= "string" or type(road) ~= "table" or not ROAD_STATES[road.state]
            or not integer(road.revision) or road.revision < 1 or not point(road.endpoint)
            or not integer(road.local_heading) or type(road.preferred) ~= "table"
            or not integer(road.next_seq) or type(road.segments) ~= "table"
            or #road.segments < 1 or #road.segments > LIMITS.road_segments
            or type(road.origin_op_id) ~= "string" then return false end
        for _, sid in ipairs(road.segments) do
            if not reg.segs[sid] then return false end
        end
        if road.pending ~= nil and (type(road.pending) ~= "table" or type(road.pending.segment_id) ~= "string") then
            return false
        end
        if road.state == "building" and (type(road.pending) ~= "table" or not reg.segs[road.pending.segment_id]) then
            return false
        end
    end
    for id, claim in pairs(reg.claims) do
        if type(id) ~= "string" or type(claim) ~= "table" or type(claim.kind) ~= "string"
            or type(claim.road_id) ~= "string" or type(claim.state) ~= "string" then return false end
    end
    return true
end

-- options: storage={get,set,keys}, serialize, deserialize, now (os.time)
function store.new(options)
    local storage, serialize, deserialize = options.storage, options.serialize, options.deserialize
    local now = options.now or function() return 0 end
    local self = {}
    local reg, blocked, dirty, index, loaded

    local function build_index()
        index = {}
        for id, e in pairs(reg.segs) do
            for _, cell in ipairs(e.cells) do
                local list = index[cell]
                if not list then list = {}; index[cell] = list end
                list[#list + 1] = id
            end
        end
    end

    local function persist(doc)
        local ok, text = pcall(serialize, doc)
        if not ok or type(text) ~= "string" then return err("storage_failed", "cannot serialize the growth registry") end
        if #text > LIMITS.registry_bytes then
            return err("storage_budget", "growth registry exceeds " .. LIMITS.registry_bytes .. " bytes",
                {limit = LIMITS.registry_bytes, observed = #text})
        end
        local set_ok, set_err = pcall(storage.set, REGISTRY_KEY, text)
        if not set_ok then return err("storage_failed", "mod storage write failed: " .. tostring(set_err)) end
        local get_ok, back = pcall(storage.get, REGISTRY_KEY)
        if not get_ok or back ~= text then return err("storage_failed", "growth registry read-back mismatch") end
        return true
    end

    -- A restart can never find live work: planning made no writes; building
    -- may have, so it becomes uncertain and keeps every reservation.
    local function convert()
        local changed = 0
        for _, road in pairs(reg.roads) do
            if road.state == "planning" then
                road.state = "stopped"; road.pending = nil
                road.stop = {code = "interrupted", reason = "restart interrupted planning; no writes were made"}
                changed = changed + 1
            elseif road.state == "building" then
                road.state = "uncertain"
                road.pending.state = "uncertain"
                road.stop = {code = "interrupted", reason = "restart interrupted a possibly started build; writes are unknown"}
                local e = reg.segs[road.pending.segment_id]
                if e then e.state = "uncertain" end
                for _, claim in pairs(reg.claims) do
                    if claim.segment_id == road.pending.segment_id then claim.state = "uncertain" end
                end
                changed = changed + 1
            end
        end
        return changed
    end

    local function load()
        if loaded then return end
        loaded = true
        local ok, text = pcall(storage.get, REGISTRY_KEY)
        if not ok then
            blocked = {state = "unreadable", reason = "mod storage read failed"}
        elseif text == nil or text == "" then
            reg = {schema = SCHEMA, roads = {}, segs = {}, claims = {}}
        elseif #text > LIMITS.registry_bytes then
            blocked = {state = "unreadable", reason = "growth registry exceeds " .. LIMITS.registry_bytes .. " bytes"}
        else
            local decoded_ok, doc = pcall(deserialize, text)
            if not decoded_ok or type(doc) ~= "table" then
                blocked = {state = "unreadable", reason = "growth registry is unreadable"}
            elseif type(doc.schema) == "number" and doc.schema > SCHEMA then
                blocked = {state = "future_schema", reason = "growth registry schema " .. doc.schema
                    .. " is newer than supported schema " .. SCHEMA .. "; it is read-only blocked data"}
            elseif doc.schema ~= SCHEMA or not valid_registry(doc) then
                blocked = {state = "unreadable", reason = "growth registry is malformed or exceeds its caps"}
            else
                reg = doc
                if convert() > 0 then dirty = true end
            end
        end
        if reg then build_index() end
    end

    local function flush()
        if dirty and reg and not blocked then
            if persist(reg) then dirty = nil end
        end
    end

    -- true, or nil plus a growth_disabled error that explains why.
    function self:health()
        load()
        if blocked then
            return err("growth_disabled", blocked.reason, {state = blocked.state})
        end
        flush()
        return true
    end

    -- Persistent write that is never applied in memory unless it is durable.
    -- next_seq values are monotonic even when the save fails, so an identity
    -- allocated for a failed attempt is never handed out again.
    function self:update(mutator)
        local ok, why = self:health(); if not ok then return nil, why end
        local draft = copy(reg)
        local good, merr = mutator(draft)
        if not good then return nil, merr end
        local before = {}
        for id, road in pairs(reg.roads) do before[id] = road.next_seq end
        if count(draft.roads) > LIMITS.roads then
            return err("storage_budget", "growth is limited to " .. LIMITS.roads .. " roads and unadopted seeds",
                {limit = LIMITS.roads, observed = count(draft.roads)})
        end
        local unadopted, references = 0, 0
        for _, e in pairs(draft.segs) do
            if e.kind == "seed" and not e.road_id then unadopted = unadopted + 1 end
            references = references + #e.cells
        end
        if count(draft.roads) + unadopted > LIMITS.roads then
            return err("storage_budget", "growth is limited to " .. LIMITS.roads .. " roads and unadopted seeds",
                {limit = LIMITS.roads, observed = count(draft.roads) + unadopted})
        end
        if count(draft.segs) > LIMITS.segments then
            return err("storage_budget", "growth is limited to " .. LIMITS.segments .. " possibly written segments",
                {limit = LIMITS.segments, observed = count(draft.segs)})
        end
        if references > LIMITS.references then
            return err("storage_budget", "growth is limited to " .. LIMITS.references .. " index references",
                {limit = LIMITS.references, observed = references})
        end
        if count(draft.claims) > LIMITS.claims then
            return err("storage_budget", "growth is limited to " .. LIMITS.claims .. " claims",
                {limit = LIMITS.claims, observed = count(draft.claims)})
        end
        for id, road in pairs(draft.roads) do
            if #road.segments > LIMITS.road_segments then
                return err("storage_budget", "road " .. id .. " is limited to " .. LIMITS.road_segments .. " segments",
                    {limit = LIMITS.road_segments, observed = #road.segments})
            end
        end
        if not valid_registry(draft) then return err("storage_failed", "growth update would produce a malformed registry") end
        local saved, save_err = persist(draft)
        if not saved then
            -- The old document stays authoritative; only identities advance.
            for id, road in pairs(draft.roads) do
                local old = reg.roads[id]
                if old and before[id] and road.next_seq > old.next_seq then old.next_seq = road.next_seq end
            end
            dirty = true
            return nil, save_err
        end
        reg = draft; dirty = nil
        build_index()
        return true
    end

    -- Apply a change whose outcome is already known (zero-write release,
    -- conservative uncertainty) in memory regardless of storage. If the save
    -- fails the older, more conservative stored document wins after restart.
    function self:settle(mutator)
        local ok, why = self:health(); if not ok then return nil, why end
        mutator(reg)
        build_index()
        local saved = persist(reg)
        dirty = not saved or nil
        return saved and true or false
    end

    -- Read accessors return copies.
    function self:road(road_id)
        load(); if not reg or blocked then return nil end
        return copy(reg.roads[road_id])
    end
    function self:road_ids()
        load(); local ids = {}
        for id in pairs(reg and reg.roads or {}) do ids[#ids + 1] = id end
        table.sort(ids)
        return ids
    end
    function self:entry(id)
        load(); if not reg or blocked then return nil end
        return copy(reg.segs[id])
    end
    function self:entry_ids()
        load(); local ids = {}
        for id in pairs(reg and reg.segs or {}) do ids[#ids + 1] = id end
        table.sort(ids)
        return ids
    end
    function self:claim(id)
        load(); if not reg or blocked then return nil end
        return copy(reg.claims[id])
    end
    function self:counts()
        load()
        if not reg then return {roads = 0, segments = 0, claims = 0, references = 0} end
        local references = 0
        for _, e in pairs(reg.segs) do references = references + #e.cells end
        return {roads = count(reg.roads), segments = count(reg.segs), claims = count(reg.claims), references = references}
    end

    -- Segment/seed records. Written and read back before any registry
    -- reference exists; an unreferenced record is a harmless orphan.
    function self:save_record(record)
        local ok, why = self:health(); if not ok then return nil, why end
        local good, text = pcall(serialize, record)
        if not good or type(text) ~= "string" then return err("storage_failed", "cannot serialize the segment record") end
        if #text > LIMITS.segment_bytes then
            return err("storage_budget", "segment record exceeds " .. LIMITS.segment_bytes .. " bytes",
                {limit = LIMITS.segment_bytes, observed = #text})
        end
        local key = SEGMENT_PREFIX .. record.id
        local set_ok, set_err = pcall(storage.set, key, text)
        if not set_ok then return err("storage_failed", "mod storage write failed: " .. tostring(set_err)) end
        local get_ok, back = pcall(storage.get, key)
        if not get_ok or back ~= text then return err("storage_failed", "segment record read-back mismatch") end
        return #text
    end
    function self:load_record(id)
        local ok, why = self:health(); if not ok then return nil, why end
        local get_ok, text = pcall(storage.get, SEGMENT_PREFIX .. id)
        if not get_ok then return err("storage_failed", "mod storage read failed") end
        if text == nil or text == "" then return err("segment_missing", "segment record " .. id .. " is missing") end
        if #text > LIMITS.segment_bytes then return err("segment_corrupt", "segment record " .. id .. " is oversized") end
        local decoded_ok, record = pcall(deserialize, text)
        if not decoded_ok or type(record) ~= "table" or record.schema ~= SCHEMA or record.id ~= id then
            return err("segment_corrupt", "segment record " .. id .. " is unreadable or has an unsupported schema")
        end
        return record
    end
    function self:remove_record(id)
        pcall(storage.set, SEGMENT_PREFIX .. id, "")
    end

    -- Every stored entry whose index cells touch rect, deduplicated. The result
    -- is complete or an error: omitted references are never treated as clear.
    function self:collect(rect)
        local ok, why = self:health(); if not ok then return nil, why end
        if type(rect) ~= "table" or not integer(rect.x1) or not integer(rect.z1) or not integer(rect.x2)
            or not integer(rect.z2) or rect.x1 > rect.x2 or rect.z1 > rect.z2 then
            return err("invalid_request", "a valid query rectangle is required")
        end
        local size = LIMITS.cell_size
        local cx1, cx2 = math.floor(rect.x1 / size), math.floor(rect.x2 / size)
        local cz1, cz2 = math.floor(rect.z1 / size), math.floor(rect.z2 / size)
        local cells = (cx2 - cx1 + 1) * (cz2 - cz1 + 1)
        if cells > LIMITS.query_cells then
            return err("road_index_budget", "the query would visit " .. cells .. " index cells (limit "
                .. LIMITS.query_cells .. ")", {limit = LIMITS.query_cells, observed = cells})
        end
        local seen, ids, references = {}, {}, 0
        for cx = cx1, cx2 do
            for cz = cz1, cz2 do
                for _, id in ipairs(index[cx .. ":" .. cz] or {}) do
                    references = references + 1
                    if references > LIMITS.query_references then
                        return err("road_index_budget", "the query would visit more than " .. LIMITS.query_references
                            .. " index references", {limit = LIMITS.query_references, observed = references})
                    end
                    if not seen[id] then
                        seen[id] = true
                        local b = reg.segs[id].bounds
                        if b.x1 <= rect.x2 and b.x2 >= rect.x1 and b.z1 <= rect.z2 and b.z2 >= rect.z1 then
                            ids[#ids + 1] = id
                        end
                    end
                end
            end
        end
        table.sort(ids)
        return ids, {cells = cells, references = references}
    end

    function self:now() return now() end
    self.LIMITS = LIMITS
    self.cell = store.cell
    return self
end

store.SCHEMA = SCHEMA
store.PREFIX = PREFIX
return store
