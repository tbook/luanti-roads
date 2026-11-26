-- SPDX-License-Identifier: GPL-3.0-or-later
-- Player proximity activation for growth roads (design: "Player activation and
-- scheduling", slice H). Sampled positions of connected players arm an open
-- endpoint revision from outside the outer radius; a later sample inside the
-- inner radius supplies one approach token, which queues the endpoint. Queued
-- endpoints are admitted through ops.extend, which owns the shared job slot and
-- the durable activation intent. Nothing here writes storage: arming, the player
-- window and the queue are session-only and lost on restart.
--
-- Everything external is injected (clock, connected players, fresh samples,
-- endpoint snapshot, slot state, growth extend) so the module runs in pure Lua
-- 5.1. `scheduler.queue` is a bounded keyed admission queue that later slices
-- (#42) can reuse instead of adding a second worker.
local scheduler = {}

local INNER, OUTER, VERTICAL = 24, 36, 16
-- Two consecutive samples further apart than this are a teleport, not an
-- approach: arming is dropped so the first inside sample is not a token.
local JUMP = 2 * OUTER
local CELL = 128
local MAX_PLAYERS = 32        -- retained player slots (samples per tick)
local MAX_ROADS = 128         -- armed endpoints kept per player slot
local MAX_COMPARISONS = 64    -- endpoint comparisons per tick
local INTERVAL = 1            -- seconds between sampling ticks
local QUEUE_MAX = 16
local QUEUE_TTL = 30

local function finite(n) return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge end
local function valid(p) return type(p) == "table" and finite(p.x) and finite(p.y) and finite(p.z) end
local function count(t) local n = 0; for _ in pairs(t) do n = n + 1 end; return n end
local function error_result(code, reason, extra)
    local result = extra or {}
    result.code = code; result.reason = reason
    return result
end
local function distance3(a, b)
    local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end
-- Adding 0 turns a negative zero into zero so cell keys are stable.
local function cell_of(v) return math.floor(v / CELL) + 0 end
local function cell_key(cx, cz) return cx .. ":" .. cz end

------------------------------------------------------------ admission queue
-- Bounded, keyed FIFO. A key is reserved in memory while queued; owners (player
-- names) form a set per key, so duplicates coalesce. Entries expire and nothing
-- is persisted.
local queue = {}

function queue.new(options)
    options = options or {}
    local max = options.max or QUEUE_MAX
    local ttl = options.ttl or QUEUE_TTL
    if not finite(max) or max < 1 or not finite(ttl) or ttl <= 0 then
        return nil, error_result("invalid_config", "queue bounds must be positive")
    end
    local self = {max = max, ttl = ttl, entries = {}, by_key = {}}

    function self:size() return #self.entries end
    function self:get(key) return self.by_key[key] end

    -- "queued" (new key), "coalesced" (owner joins a queued key) or "full".
    function self:offer(key, owner, now, meta)
        local entry = self.by_key[key]
        if entry then
            entry.owners[owner] = true
            return "coalesced", entry
        end
        if #self.entries >= self.max then return "full" end
        entry = {key = key, owners = {[owner] = true}, meta = meta, queued_at = now, expires_at = now + self.ttl}
        self.entries[#self.entries + 1] = entry
        self.by_key[key] = entry
        return "queued", entry
    end

    function self:remove(key)
        local entry = self.by_key[key]
        if not entry then return nil end
        self.by_key[key] = nil
        for i, e in ipairs(self.entries) do
            if e == entry then table.remove(self.entries, i); break end
        end
        return entry
    end

    -- Remove every entry for which keep(entry) is false. Returns the removed entries.
    function self:prune(keep)
        local kept, removed = {}, {}
        for _, e in ipairs(self.entries) do
            if keep(e) then
                kept[#kept + 1] = e
            else
                self.by_key[e.key] = nil
                removed[#removed + 1] = e
            end
        end
        self.entries = kept
        return removed
    end

    -- Admit the first FIFO entry that is ready. opts.busy() true stops admission
    -- without touching any entry (a busy slot waits, it never cancels).
    -- opts.check(entry) returns "ready" | "skip" (keep, try later) | "drop".
    -- opts.start(entry) returns true or nil, err; err.code == "busy" keeps the
    -- entry queued, any other refusal removes it. Returns the admitted entry, or
    -- nil plus "busy" when the slot stopped admission.
    function self:admit(opts)
        if opts.busy and opts.busy() then return nil, "busy" end
        local snapshot = {}
        for i, e in ipairs(self.entries) do snapshot[i] = e end
        for _, e in ipairs(snapshot) do
            local verdict = opts.check(e)
            if verdict == "ready" then
                local ok, err = opts.start(e)
                if ok then
                    self:remove(e.key)
                    return e
                end
                if type(err) == "table" and err.code == "busy" then return nil, "busy" end
                self:remove(e.key)
            elseif verdict == "drop" then
                self:remove(e.key)
            end
        end
        return nil
    end

    return self
end

scheduler.queue = queue

------------------------------------------------------------ proximity scheduler
-- ops (all injected):
--   now()                  clock in seconds
--   connected()            names of connected players
--   sample(name)           fresh feet position {x,y,z}, or nil when dead/unavailable
--   roads()                growth road snapshots {road_id, revision, endpoint, state, activation}
--   slot_busy()            true while any job owns the shared slot
--   extend(road_id, actor) growth service extend: id, or nil plus error
--   log(level, message)    optional
-- options.enabled          automatic growth switch; step() does nothing when false
function scheduler.new(ops)
    if type(ops) ~= "table" or type(ops.now) ~= "function" or type(ops.connected) ~= "function"
        or type(ops.sample) ~= "function" or type(ops.roads) ~= "function"
        or type(ops.slot_busy) ~= "function" or type(ops.extend) ~= "function" then
        return nil, error_result("invalid_config", "growth scheduler dependencies are incomplete")
    end
    local q = queue.new({max = QUEUE_MAX, ttl = QUEUE_TTL})
    local self = {enabled = ops.enabled == true, slots = {}, offset = 0, ticks = 0, next_at = nil,
        endpoints = {}, index = {}, positions = {}, queue = q,
        last = {samples = 0, comparisons = 0, admitted = 0}}

    local function log(level, message)
        if ops.log then pcall(ops.log, level, "[roads] " .. message) end
    end

    local function sorted_names(list)
        local seen, names = {}, {}
        for _, name in ipairs(list or {}) do
            if type(name) == "string" and name ~= "" and not seen[name] then
                seen[name] = true
                names[#names + 1] = name
            end
        end
        table.sort(names)
        return names
    end

    -- Open endpoints whose next segment is still unconsumed (activation
    -- needs_departure). Blocked, planning, building, uncertain and connected roads
    -- are not listed, so they never arm or queue.
    local function build_index(list)
        self.endpoints, self.index = {}, {}
        for _, r in ipairs(list) do
            if type(r) == "table" and type(r.road_id) == "string" and r.state == "open"
                and r.activation == "needs_departure" and type(r.revision) == "number" and valid(r.endpoint) then
                local e = {road_id = r.road_id, revision = r.revision, x = r.endpoint.x, y = r.endpoint.y, z = r.endpoint.z}
                self.endpoints[e.road_id] = e
                local key = cell_key(cell_of(e.x), cell_of(e.z))
                local bucket = self.index[key]
                if not bucket then bucket = {}; self.index[key] = bucket end
                bucket[#bucket + 1] = e
            end
        end
    end

    -- Endpoints in the player's cell and its eight neighbours (cells are 128 nodes,
    -- wider than the 36-node outer radius), in road-id order.
    local function nearby(pos)
        local cx, cz = cell_of(pos.x), cell_of(pos.z)
        local found = {}
        for ix = -1, 1 do
            for iz = -1, 1 do
                local bucket = self.index[cell_key(cx + ix, cz + iz)]
                if bucket then
                    for _, e in ipairs(bucket) do found[#found + 1] = e end
                end
            end
        end
        table.sort(found, function(a, b) return a.road_id < b.road_id end)
        return found
    end

    local function enqueue(name, e, now)
        local meta = {road_id = e.road_id, revision = e.revision}
        return self.queue:offer(e.road_id .. "#" .. e.revision, name, now, meta)
    end

    -- Compare one sampled position with one endpoint. Outside the outer cylinder
    -- arms this revision; a later inside-inner sample consumes the arming and
    -- queues one token. Arming is never created for a first observation inside.
    local function compare(slot, name, e, pos, now)
        local dx, dz = pos.x - e.x, pos.z - e.z
        local horizontal2 = dx * dx + dz * dz
        local vertical_ok = math.abs(pos.y - e.y) <= VERTICAL
        local arm = slot.arm[e.road_id]
        if not vertical_ok or horizontal2 > OUTER * OUTER then
            -- At the cap, the least recently observed outside arming for another road
            -- makes room. Dropping history never grants a token; this road still needs
            -- its own outside observation and then a crossing.
            if not arm and count(slot.arm) >= MAX_ROADS then
                local oldest, oldest_id = nil, nil
                for road_id, other in pairs(slot.arm) do
                    if oldest == nil or other.at < oldest.at or (other.at == oldest.at and road_id < oldest_id) then
                        oldest, oldest_id = other, road_id
                    end
                end
                slot.arm[oldest_id] = nil
            end
            slot.arm[e.road_id] = {revision = e.revision, at = self.ticks}
        elseif horizontal2 <= INNER * INNER and arm and arm.revision == e.revision then
            slot.arm[e.road_id] = nil
            enqueue(name, e, now)
        end
    end

    -- One fresh sample of a retained player, then up to the remaining comparison
    -- budget against the endpoints near it, from this player's rotating cursor.
    local function visit(name, slot, now)
        self.last.samples = self.last.samples + 1
        local ok, pos = pcall(ops.sample, name)
        if not ok or not valid(pos) then
            -- A missing or dead observation is not an approach: forget the arming.
            slot.arm, slot.last, slot.cursor = {}, nil, 0
            return
        end
        pos = {x = pos.x, y = pos.y, z = pos.z}
        self.positions[name] = pos
        if slot.last and distance3(pos, slot.last) > JUMP then slot.arm = {} end
        slot.last = pos
        local found = nearby(pos)
        local n = math.min(#found, MAX_COMPARISONS - self.last.comparisons)
        if n <= 0 then return end
        for i = 1, n do
            compare(slot, name, found[(slot.cursor + i - 1) % #found + 1], pos, now)
        end
        self.last.comparisons = self.last.comparisons + n
        slot.cursor = (slot.cursor + n) % #found
    end

    local function admit(now)
        local entry = self.queue:admit({
            busy = ops.slot_busy,
            check = function(e)
                local road = self.endpoints[e.meta.road_id]
                if not road or road.revision ~= e.meta.revision then return "drop" end
                -- Continued proximity: any owner sampled this tick. Owners not sampled
                -- this tick wait (the entry expires); an entry is never renewed.
                local sampled, near = false, false
                for name in pairs(e.owners) do
                    local p = self.positions[name]
                    if p then
                        sampled = true
                        if math.abs(p.y - road.y) <= VERTICAL then
                            local dx, dz = p.x - road.x, p.z - road.z
                            if dx * dx + dz * dz <= INNER * INNER then near = true end
                        end
                    end
                end
                if not sampled then return "skip" end
                return near and "ready" or "drop"
            end,
            start = function(e)
                local called, id, err = pcall(ops.extend, e.meta.road_id, "proximity")
                if not called then return nil, error_result("failed", "growth start failed: " .. tostring(id)) end
                if not id then return nil, err end
                return id
            end})
        if entry then self.last.admitted = 1 end
        return entry
    end

    -- One sampling tick: retained window, endpoint snapshot, queue upkeep, bounded
    -- sampling and at most one admission. Never writes storage.
    function self:tick()
        local now = ops.now()
        self.next_at = now + INTERVAL
        self.ticks = self.ticks + 1
        self.last = {samples = 0, comparisons = 0, admitted = 0}
        self.positions = {}

        local names = sorted_names(ops.connected())
        local present = {}
        for _, name in ipairs(names) do present[name] = true end
        -- Retained window: all connected players up to MAX_PLAYERS; with more, the
        -- window slides one name per tick so every player gets samples in turn.
        local window = names
        if #names > MAX_PLAYERS then
            self.offset = self.offset % #names
            window = {}
            for i = 1, MAX_PLAYERS do window[i] = names[(self.offset + i - 1) % #names + 1] end
            self.offset = (self.offset + 1) % #names
        end
        local keep = {}
        for _, name in ipairs(window) do keep[name] = true end
        -- Evicted and disconnected players lose their arming history.
        for name in pairs(self.slots) do
            if not keep[name] then self.slots[name] = nil end
        end
        for _, name in ipairs(window) do
            if not self.slots[name] then self.slots[name] = {arm = {}, cursor = 0} end
        end

        local ok, list = pcall(ops.roads)
        build_index(ok and type(list) == "table" and list or {})
        -- Arming for obsolete revisions or roads that are no longer open is dropped.
        for _, slot in pairs(self.slots) do
            for road_id, arm in pairs(slot.arm) do
                local e = self.endpoints[road_id]
                if not e or e.revision ~= arm.revision then slot.arm[road_id] = nil end
            end
        end

        -- Queue upkeep: expiry, disconnected owners, and entries whose road has moved on.
        self.queue:prune(function(e) return now < e.expires_at end)
        for _, e in ipairs(self.queue.entries) do
            for name in pairs(e.owners) do
                if not present[name] then e.owners[name] = nil end
            end
        end
        self.queue:prune(function(e)
            local road = self.endpoints[e.meta.road_id]
            return next(e.owners) ~= nil and road ~= nil and road.revision == e.meta.revision
        end)

        if #window > 0 then
            -- Rotate the starting player so the comparison budget is shared fairly.
            local start = self.ticks % #window
            for i = 1, #window do
                local name = window[(start + i - 1) % #window + 1]
                visit(name, self.slots[name], now)
            end
        end

        return admit(now)
    end

    -- Driver for the engine globalstep: runs one tick per INTERVAL when enabled.
    function self:step()
        if not self.enabled then return false end
        local now = ops.now()
        if self.next_at and now < self.next_at then return false end
        local ok, err = pcall(self.tick, self)
        if not ok then log("error", "growth proximity tick failed: " .. tostring(err)) end
        return ok
    end

    -- Presentation facts for one road (or the scheduler as a whole). Read-only.
    function self:status(road_id)
        local now = ops.now()
        local entries = self.queue.entries
        local st = {enabled = self.enabled, slot_busy = ops.slot_busy() == true,
            queue = {length = #entries, max = QUEUE_MAX}, retained_players = count(self.slots), armed = 0}
        if road_id ~= nil then
            for i, entry in ipairs(entries) do
                if entry.meta.road_id == road_id then
                    st.queued = {position = i, of = #entries, age = math.max(0, math.floor(now - entry.queued_at)),
                        expires_in = math.max(0, math.ceil(entry.expires_at - now)), players = count(entry.owners)}
                    break
                end
            end
            local e = self.endpoints[road_id]
            st.eligible = e ~= nil
            if e then
                for _, slot in pairs(self.slots) do
                    local arm = slot.arm[road_id]
                    if arm and arm.revision == e.revision then st.armed = st.armed + 1 end
                end
            end
        end
        return st
    end

    return self
end

return scheduler
