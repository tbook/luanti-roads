-- SPDX-License-Identifier: GPL-3.0-or-later
-- Player proximity scheduling (#53). Most tests drive src/growth_scheduler.lua
-- with a scripted world (players, road snapshots, slot, clock) whose extend
-- behaves like the growth service: intent is consumed on admission, the slot is
-- held until the cycle publishes or stops. The last tests run the real growth
-- service (tests/growth_fixture.lua) and the real job slot.
local scheduler = dofile('src/growth_scheduler.lua')
local commands = dofile('src/commands.lua')
local fixture = dofile('tests/growth_fixture.lua')
local count = 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if not ok then error('growth scheduler '..name..': '..tostring(err)) end
    count = count + 1
end
local function copy(v)
    if type(v) ~= 'table' then return v end
    local r = {}; for k, x in pairs(v) do r[k] = copy(x) end; return r
end

local A = 'growth:v1:a'

-- Scripted world. Positions are {x, y, z} per player; a road snapshot mirrors the
-- store record fields the scheduler reads. extend() moves the road into planning
-- and the slot into busy, as the real service does; w.publish/w.stop end the cycle.
local function world()
    local w = {t = 0, players = {}, roads = {}, byid = {}, calls = {}, busy = false, refuse = {}, seen = {}}
    function w.add_road(id, endpoint, revision)
        local r = {road_id = id, revision = revision or 1, endpoint = {x = endpoint.x, y = endpoint.y or 0, z = endpoint.z},
            state = 'open', activation = 'needs_departure'}
        w.roads[#w.roads + 1] = r; w.byid[id] = r
        return r
    end
    function w.at(name, x, z, y) w.players[name] = {x = x, y = y or 0, z = z} end
    function w.extend(id)
        local r = w.byid[id]
        w.calls[#w.calls + 1] = id
        if w.refuse[id] then return nil, {code = w.refuse[id], reason = 'refused by the test'} end
        if not r or r.state ~= 'open' then return nil, {code = 'not_extendable', reason = 'the road is not open'} end
        if w.busy then return nil, {code = 'busy', reason = 'another road job owns the server slot'} end
        r.state = 'planning'; r.activation = 'consumed'; w.busy = true
        return id..':s'..#w.calls..':r'..r.revision
    end
    function w.publish(id, endpoint)
        local r = w.byid[id]
        r.revision = r.revision + 1
        r.endpoint = {x = endpoint.x, y = endpoint.y or 0, z = endpoint.z}
        r.state = 'open'; r.activation = 'needs_departure'; w.busy = false
    end
    function w.stop(id) w.byid[id].state = 'stopped'; w.busy = false end
    function w.sched(extra)
        local ops = {enabled = true, now = function() return w.t end,
            connected = function()
                local names = {}
                for name in pairs(w.players) do names[#names + 1] = name end
                return names
            end,
            sample = function(name)
                w.seen[name] = (w.seen[name] or 0) + 1
                local p = w.players[name]
                return p and {x = p.x, y = p.y, z = p.z} or nil
            end,
            roads = function()
                local list = {}
                for _, r in ipairs(w.roads) do list[#list + 1] = copy(r) end
                return list
            end,
            slot_busy = function() return w.busy end,
            extend = function(id, actor) return w.extend(id, actor) end}
        for k, v in pairs(extra or {}) do ops[k] = v end
        return assert(scheduler.new(ops))
    end
    -- One sampling tick at the current time, then one second passes.
    function w.tick(s)
        s:tick()
        w.t = w.t + 1
    end
    return w
end

------------------------------------------------------------ admission helper
test('bounded queue: coalesce owners, refuse the 17th key, admit in FIFO order, and keep busy entries', function()
    local q = assert(scheduler.queue.new({max = 2, ttl = 30}))
    assert(q:offer('a#1', 'alice', 0, {road_id = 'a'}) == 'queued')
    assert(q:offer('a#1', 'bob', 5, {road_id = 'a'}) == 'coalesced' and q:size() == 1)
    assert(q:get('a#1').owners.bob and q:get('a#1').queued_at == 0, 'coalescing keeps the first queue time')
    assert(q:offer('b#1', 'carol', 1) == 'queued')
    assert(q:offer('c#1', 'dave', 2) == 'full' and q:size() == 2 and q:get('c#1') == nil, 'the third key is refused')
    local busy = true
    local starts = {}
    local function opts(start, verdict)
        return {busy = function() return busy end, check = function() return verdict or 'ready' end, start = start}
    end
    -- A busy slot stops admission without touching any entry.
    local r, why = q:admit(opts(function(e) starts[#starts + 1] = e.key; return true end))
    assert(r == nil and why == 'busy' and #starts == 0 and q:size() == 2, 'busy slot waits')
    busy = false
    -- Refusals that are not busy remove the entry and admission continues in FIFO order.
    r = q:admit(opts(function(e) starts[#starts + 1] = e.key; return nil, {code = 'growth_failed'} end))
    assert(r == nil and table.concat(starts, ',') == 'a#1,b#1' and q:size() == 0, 'refused entries are removed')
    -- "busy" from the starter keeps the entry for a later tick.
    assert(q:offer('c#1', 'dave', 2) == 'queued')
    r, why = q:admit(opts(function() return nil, {code = 'busy'} end))
    assert(r == nil and why == 'busy' and q:size() == 1, 'a busy starter keeps the entry')
    r = q:admit(opts(function(e) return true end))
    assert(r and r.key == 'c#1' and q:size() == 0, 'an accepted start removes the admitted entry')
    -- Skipped entries wait; dropped entries leave without starting.
    assert(q:offer('d#1', 'erin', 10) == 'queued')
    assert(q:admit(opts(function() error('must not start') end, 'skip')) == nil and q:size() == 1, 'skipped entries wait')
    assert(q:admit(opts(function() error('must not start') end, 'drop')) == nil and q:size() == 0, 'dropped entries leave')
    -- Expiry is at queued_at + ttl: pruning with now < expires_at keeps the entry only before it.
    assert(q:offer('e#1', 'frank', 10) == 'queued' and q:get('e#1').expires_at == 40)
    local now = 39
    assert(#q:prune(function(e) return now < e.expires_at end) == 0 and q:size() == 1)
    now = 40
    assert(#q:prune(function(e) return now < e.expires_at end) == 1 and q:size() == 0 and q:get('e#1') == nil)
end)

------------------------------------------------------------ the exact straight advance
test('ordinary 64-node advance: arm 40 from the new endpoint, then walk into 24 with no backtracking', function()
    local w = world()
    local s = w.sched()
    w.add_road(A, {x = 0, z = 0})
    w.at('alice', 60, 0); w.tick(s)              -- outside 36: arms revision 1
    w.at('alice', 24, 0); w.tick(s)              -- inside 24: the one token
    assert(#w.calls == 1 and w.calls[1] == A and w.busy, 'the first crossing starts one cycle')
    w.publish(A, {x = 64, z = 0})                -- the 64-node extension publishes revision 2
    w.at('alice', 24, 0); w.tick(s)              -- old inner forward edge is 40 from the new endpoint: arms
    assert(#w.calls == 1, 'arming alone never starts work')
    w.at('alice', 30, 0); w.tick(s)              -- 34 from the endpoint: between the radii
    assert(#w.calls == 1)
    w.at('alice', 40, 0); w.tick(s)              -- 24 from the endpoint: the token
    assert(#w.calls == 2 and w.calls[2] == A, 'advancing into 24 activates the new endpoint')
    assert(w.byid[A].revision == 2)
end)

------------------------------------------------------------ revisions
test('a new revision discards every arming from the previous revision', function()
    local w = world()
    local s = w.sched()
    w.add_road(A, {x = 0, z = 0})
    w.at('alice', 60, 0); w.tick(s)              -- arms revision 1
    w.publish(A, {x = 100, z = 0})               -- revision 2, from some other cycle
    w.at('alice', 70, 0); w.tick(s)              -- 30 from revision 2: no arming for it
    w.at('alice', 80, 0); w.tick(s)              -- 20 from revision 2: inside without arming
    assert(#w.calls == 0, 'revision 1 arming does not carry over')
    assert(s.slots.alice.arm[A] == nil)
end)

test('stationary, first-seen-inside, endpoint-occupant and road-caused emergence never chain construction', function()
    local w = world()
    local s = w.sched()
    w.add_road(A, {x = 0, z = 0})
    w.add_road('growth:v1:b', {x = 450, z = 0})
    w.at('outside', -60, 0); w.at('inside', 10, 0)
    for _ = 1, 20 do w.tick(s) end
    assert(#w.calls == 0, 'stationary outside and first-seen inside players never activate')
    -- A player stands at 50 from the endpoint of b (armed), then b is published onto them.
    w.at('standing', 400, 0)
    w.tick(s)
    w.publish('growth:v1:b', {x = 400, z = 0})
    w.tick(s); w.tick(s)
    assert(#w.calls == 0, 'standing at the new endpoint is first observed inside for the new revision')
    -- Road-generated terrain changes nothing about positions: a player 30 away
    -- (between the radii) that was never observed outside never activates.
    w.at('nearby', 30, 0)
    for _ = 1, 10 do w.tick(s) end
    w.publish(A, {x = 20, z = 0})
    for _ = 1, 10 do w.tick(s) end
    assert(#w.calls == 0, 'emergence and publication alone never activate')
end)

test('leaving beyond 36 and returning activates a still-open endpoint once per revision', function()
    local w = world()
    local s = w.sched()
    w.add_road(A, {x = 0, z = 0})
    w.refuse[A] = 'growth_failed'                -- refused without writes: the road stays open
    w.at('alice', 60, 0); w.tick(s)
    w.at('alice', 20, 0); w.tick(s)
    assert(#w.calls == 1 and w.byid[A].state == 'open' and w.byid[A].activation == 'needs_departure')
    w.at('alice', 60, 0); w.tick(s)              -- leaves beyond 36
    w.at('alice', 20, 0); w.tick(s)              -- returns: a fresh token
    assert(#w.calls == 2, 'leaving and returning gives one more token')
    for _ = 1, 5 do w.tick(s) end                -- standing still inside is not a new crossing
    assert(#w.calls == 2)
end)

test('login, teleport and first-seen-inside observations supply no token', function()
    local w = world()
    local s = w.sched()
    w.add_road(A, {x = 0, z = 0})
    w.at('alice', 10, 0); w.tick(s); w.tick(s)   -- login inside
    assert(#w.calls == 0)
    w.at('bob', 200, 0); w.tick(s)               -- armed far away
    w.at('bob', 10, 0); w.tick(s)                -- teleported inside: a jump beyond 72 is not an approach
    assert(#w.calls == 0, 'teleport from far outside gives no token')
    w.at('carol', 60, 0); w.tick(s)
    w.at('carol', 20, 0); w.tick(s)              -- a short move from outside is indistinguishable from walking
    assert(#w.calls == 1 and w.calls[1] == A)
end)

test('disconnected players lose arming and queued owners; a reconnect inside is first-seen', function()
    local w = world()
    local s = w.sched()
    w.add_road(A, {x = 0, z = 0})
    w.busy = true
    w.at('alice', 60, 0); w.tick(s)
    w.at('alice', 20, 0); w.tick(s)
    assert(s.queue:size() == 1)
    w.players.alice = nil; w.tick(s)             -- leaves: its queued owner is removed
    assert(s.queue:size() == 0 and s.slots.alice == nil)
    w.busy = false
    w.tick(s)
    assert(#w.calls == 0, 'an entry without a present owner never starts')
    w.at('alice', 20, 0); w.tick(s); w.tick(s)   -- reconnects inside: first observed
    assert(#w.calls == 0)
end)

------------------------------------------------------------ coalescing and busy slot
test('a queued owner that is no longer within 24 when the slot frees is dropped without starting', function()
    local w = world()
    local s = w.sched()
    w.add_road(A, {x = 0, z = 0})
    w.busy = true
    w.at('alice', 60, 0); w.tick(s)
    w.at('alice', 20, 0); w.tick(s)              -- queued
    assert(s.queue:size() == 1)
    w.at('alice', 60, 0); w.tick(s)              -- still present, but back outside 36
    w.busy = false
    w.tick(s)
    assert(#w.calls == 0 and s.queue:size() == 0, 'continued proximity is rechecked at admission')
    assert(w.byid[A].state == 'open' and w.byid[A].activation == 'needs_departure', 'nothing was consumed')
end)

test('duplicate players coalesce into one queued key and one extension', function()
    local w = world()
    local s = w.sched()
    w.add_road(A, {x = 0, z = 0})
    w.busy = true
    w.at('alice', 60, 0); w.at('bob', 60, 5); w.tick(s)
    w.at('alice', 20, 0); w.at('bob', 20, 5); w.tick(s)
    local entry = s.queue:get(A..'#1')
    assert(s.queue:size() == 1 and entry and entry.owners.alice and entry.owners.bob)
    w.at('alice', 60, 0); w.tick(s)
    w.at('alice', 20, 0); w.tick(s)              -- alice again while queued: coalesced, not a second entry
    assert(s.queue:size() == 1 and #w.calls == 0)
    w.busy = false
    w.tick(s)
    assert(#w.calls == 1 and s.queue:size() == 0 and w.busy, 'one extension for the coalesced key')
end)

test('a busy manual slot makes queued growth wait without cancelling it', function()
    local w = world()
    local s = w.sched()
    w.add_road(A, {x = 0, z = 0})
    w.busy = true                                -- a planning job holds the slot
    w.at('alice', 60, 0); w.tick(s)
    w.at('alice', 20, 0); w.tick(s)
    local st = s:status(A)
    assert(st.slot_busy and st.queued and st.queued.position == 1 and st.queued.of == 1 and st.queued.players == 1)
    for _ = 1, 10 do w.tick(s) end
    assert(#w.calls == 0 and s.queue:size() == 1 and w.busy, 'waiting never calls extend or touches the slot')
    assert(s:status(A).queued.age == 11, 'age advances with the clock')
    w.busy = false
    w.tick(s)
    assert(#w.calls == 1 and s.queue:size() == 0)
    assert(s:status(A).queued == nil and s:status(A).slot_busy == true)
end)

------------------------------------------------------------ queue overflow and expiry
test('the 17th unique endpoint is refused as full, makes no writes and needs a fresh crossing', function()
    local w = world()
    local s = w.sched()
    w.busy = true
    for i = 1, 17 do
        w.add_road('growth:v1:r'..i, {x = i * 200, z = 0})
        w.at('p'..i, i * 200 + 60, 0)
    end
    w.tick(s)
    for i = 1, 17 do w.at('p'..i, i * 200 + 20, 0) end
    w.tick(s)
    assert(s.queue:size() == 16 and #w.calls == 0, 'sixteen keys are reserved, none written')
    -- Which key was refused depends on the rotating visit order; exactly one is missing.
    local refused
    for i = 1, 17 do
        if s.queue:get('growth:v1:r'..i..'#1') == nil then
            assert(refused == nil, 'only one key is refused')
            refused = i
        end
    end
    assert(refused, 'one key is refused')
    local order = {}
    for i, e in ipairs(s.queue.entries) do order[i] = e.meta.road_id end
    for _ = 1, 3 do w.tick(s) end
    assert(s.queue:size() == 16, 'staying inside does not renew the refused key')
    -- Free the slot: the queue drains in arrival order, one cycle at a time.
    w.busy = false
    for i = 1, 16 do
        w.tick(s)
        assert(w.calls[#w.calls] == order[i], 'FIFO admission at step '..i)
        assert(#w.calls == i and w.busy)
        -- The cycle ends: the road is open again for the next crossing (not a real publish).
        w.byid[order[i]].state = 'open'; w.byid[order[i]].activation = 'needs_departure'
        w.busy = false
    end
    assert(s.queue:size() == 0)
    w.tick(s)
    assert(#w.calls == 16, 'the refused player gets no extension without a fresh crossing')
    -- The refused player leaves and crosses again: a new key that is admitted now.
    local x = refused * 200
    w.at('p'..refused, x + 60, 0); w.tick(s)
    w.at('p'..refused, x + 20, 0); w.tick(s)
    assert(#w.calls == 17 and w.calls[17] == 'growth:v1:r'..refused, 'a new crossing queues and starts it')
end)

test('queued endpoints expire after 30 seconds, and a stationary player never renews them', function()
    local w = world()
    local s = w.sched()
    w.add_road(A, {x = 0, z = 0})
    w.busy = true
    w.at('alice', 60, 0); w.tick(s)
    w.at('alice', 20, 0)
    local queued_at = w.t
    w.tick(s)
    assert(s.queue:size() == 1 and s.queue:get(A..'#1').expires_at == queued_at + 30)
    for _ = 1, 29 do w.tick(s) end
    assert(s.queue:size() == 1, 'still queued at 29 seconds')
    w.tick(s)                                    -- the 30th second
    assert(s.queue:size() == 0, 'expired at 30 seconds')
    w.busy = false
    for _ = 1, 5 do w.tick(s) end                -- the stationary player is inside but has no arming
    assert(#w.calls == 0, 'an expired entry is never renewed by a stationary player')
    w.at('alice', 60, 0); w.tick(s)
    w.at('alice', 20, 0); w.tick(s)
    assert(#w.calls == 1, 'leaving and returning is a new crossing')
end)

------------------------------------------------------------ bounds, rotation, eviction
test('more than 32 players are sampled in a rotating window of at most 32', function()
    local w = world()
    local s = w.sched()
    w.add_road(A, {x = 0, z = 0})
    for i = 1, 40 do w.at(string.format('p%02d', i), 60 + i, 0) end
    for _ = 1, 40 do
        w.tick(s)
        assert(s.last.samples <= 32 and s.last.comparisons <= 64, 'per-tick work bound')
    end
    for i = 1, 40 do assert((w.seen[string.format('p%02d', i)] or 0) > 0, 'every player is sampled in turn') end
    assert(#w.calls == 0, 'outside players never activate')
end)

test('an evicted player loses its arming and cannot gain a token by readmission inside', function()
    local w = world()
    local s = w.sched()
    w.add_road(A, {x = 0, z = 0})
    for i = 1, 40 do w.at(string.format('p%02d', i), 60 + i, 0) end
    local target = 'p40'
    local guard = 0
    while not s.slots[target] do w.tick(s); guard = guard + 1; assert(guard < 200) end
    w.tick(s)
    assert(s.slots[target].arm[A] and s.slots[target].arm[A].revision == 1, 'retained player is armed from outside')
    guard = 0
    while s.slots[target] do w.tick(s); guard = guard + 1; assert(guard < 200) end
    w.at(target, 20, 0)                          -- moves inside while it is not retained
    guard = 0
    repeat w.tick(s); guard = guard + 1; assert(guard < 200) until s.slots[target]
    assert(s.slots[target].arm[A] == nil and #w.calls == 0, 'readmission is a first observation inside')
    w.tick(s)
    assert(#w.calls == 0)
end)

test('per-tick work is bounded by 32 samples and 64 comparisons, with comparison budget rotating', function()
    local w = world()
    local s = w.sched()
    for i = 1, 10 do w.add_road('growth:v1:n'..i, {x = i * 4, z = 0}) end
    for i = 1, 40 do w.at(string.format('q%02d', i), 16, 10) end   -- 40 players, each near all 10 endpoints
    for _ = 1, 6 do
        w.tick(s)
        assert(s.last.samples == 32, 'at most 32 samples in a tick, got '..s.last.samples)
        assert(s.last.comparisons == 64, 'comparisons are capped at 64, got '..s.last.comparisons)
    end
    -- The window moves one name per tick, so every player is sampled within a full rotation.
    for _ = 1, 40 do w.tick(s); assert(s.last.samples <= 32 and s.last.comparisons <= 64) end
    for i = 1, 40 do assert((w.seen[string.format('q%02d', i)] or 0) > 0, 'q'..i..' sampled') end
end)

local function size(t) local n = 0; for _ in pairs(t) do n = n + 1 end; return n end

test('the 128-road arming cap evicts the least recently observed arming instead of locking a player out', function()
    local w = world()
    local s = w.sched()
    for k = 1, 130 do w.add_road(string.format('growth:v1:r%03d', k), {x = 10, y = 40 * k, z = 10}) end
    w.at('p', 10, 10, 0)                         -- every road is 40 or more nodes above: outside each
    local ever = {}
    for _ = 1, 8 do
        w.tick(s)
        for id in pairs(s.slots.p.arm) do ever[id] = true end
        assert(size(s.slots.p.arm) <= 128, 'arming is capped at 128 roads')
    end
    assert(size(ever) == 130, 'every road was armed in turn, not only the first 128; got '..size(ever))
    assert(size(s.slots.p.arm) == 128)
    -- A road that is not currently armed gets no token from a crossing alone.
    local unarmed
    for k = 1, 130 do
        if s.slots.p.arm[string.format('growth:v1:r%03d', k)] == nil then unarmed = k; break end
    end
    assert(unarmed, 'one road was evicted')
    w.at('p', 10, 10, 40 * unarmed)              -- inside that road's vertical band and radius
    w.tick(s)
    assert(#w.calls == 0, 'an evicted road needs a fresh outside observation before it can activate')
end)

test('vertical tolerance: 16 nodes is inside and 17 is outside, and vertical separation arms', function()
    local w = world()
    local s = w.sched()
    w.add_road(A, {x = 0, z = 0})
    w.at('up', 10, 0, 17); w.tick(s)             -- 17 vertically away: outside, arms
    assert(s.slots.up.arm[A] ~= nil)
    w.at('up', 10, 0, 16); w.tick(s)             -- exactly 16: inside, the token
    assert(#w.calls == 1, 'dy=16 is inside')
    local w2 = world()
    local s2 = w2.sched()
    w2.add_road(A, {x = 0, z = 0})
    w2.at('edge', 10, 0, 17)
    for _ = 1, 3 do w2.tick(s2) end              -- stays at dy=17: never inside
    assert(#w2.calls == 0 and s2.slots.edge.arm[A] ~= nil, 'dy=17 never supplies a token')
    w2.at('edge', 10, 0, 16); w2.tick(s2)
    assert(#w2.calls == 1, 'dropping to dy=16 is the approach')
end)

test('128-node cells: neighbouring cells across zero and into negative coordinates are compared; two cells away are not', function()
    -- Endpoint 130 (cell 1), player 127 (cell 0).
    local w = world()
    local s = w.sched()
    w.add_road(A, {x = 130, z = 0})
    w.at('p', 60, 0); w.tick(s)                  -- 70 out, across the cell boundary: armed
    assert(s.slots.p.arm[A] ~= nil)
    w.at('p', 127, 0); w.tick(s)                 -- 3 from the endpoint: token
    assert(#w.calls == 1)
    -- Endpoint -1 (cell -1), player 60 (cell 0) and 20.
    local w2 = world()
    local s2 = w2.sched()
    w2.add_road(A, {x = -1, z = 0})
    w2.at('p', 60, 0); w2.tick(s2)               -- 61 out (cell 0 sees cell -1)
    w2.at('p', 20, 0); w2.tick(s2)               -- 21 in
    assert(#w2.calls == 1, 'negative cell neighbours are compared')
    -- Endpoint -1 (cell -1), player -130 (cell -2), then -60 and -20.
    local w3 = world()
    local s3 = w3.sched()
    w3.add_road(A, {x = -1, z = 0})
    w3.at('p', -130, 0); w3.tick(s3)
    w3.at('p', -60, 0); w3.tick(s3)
    w3.at('p', -20, 0); w3.tick(s3)
    assert(#w3.calls == 1, 'a player in the cell below zero approaches across the boundary')
    -- The same across the z boundary, both above and below zero.
    local w5 = world()
    local s5 = w5.sched()
    w5.add_road(A, {x = 0, z = 130})
    w5.at('p', 0, 60); w5.tick(s5)
    w5.at('p', 0, 127); w5.tick(s5)
    assert(#w5.calls == 1, 'z neighbours above zero are compared')
    local w6 = world()
    local s6 = w6.sched()
    w6.add_road(A, {x = 0, z = -1})
    w6.at('p', 0, 60); w6.tick(s6)
    w6.at('p', 0, 20); w6.tick(s6)
    assert(#w6.calls == 1, 'z neighbours below zero are compared')
    -- Endpoint 400 (cell 3); player at 0 (cell 0) is two cells away and is not compared.
    local w4 = world()
    local s4 = w4.sched()
    w4.add_road(A, {x = 400, z = 0})
    w4.at('p', 0, 0); w4.tick(s4)
    assert(s4.slots.p.arm[A] == nil, 'a player two cells away is not compared')
    w4.at('p', 290, 0); w4.tick(s4)              -- cell 2 is a neighbour: outside, armed
    assert(s4.slots.p.arm[A] ~= nil)
    w4.at('p', 330, 0); w4.tick(s4)
    w4.at('p', 390, 0); w4.tick(s4)
    assert(#w4.calls == 1)
end)

test('teleport guard: a jump of more than 72 nodes between samples is never an approach; 72 still counts', function()
    local w = world()
    local s = w.sched()
    w.add_road(A, {x = 0, z = 0})
    w.at('t', -90, 0); w.tick(s)                 -- armed
    w.at('t', 10, 0); w.tick(s)                  -- jump of 100: a teleport, no token
    assert(#w.calls == 0)
    local w2 = world()
    local s2 = w2.sched()
    w2.add_road(A, {x = 0, z = 0})
    w2.at('m', -62, 0); w2.tick(s2)              -- armed
    w2.at('m', 10, 0); w2.tick(s2)               -- jump of exactly 72: still an approach (documented)
    assert(#w2.calls == 1)
end)

test('step runs one sampling tick per second when enabled and nothing when disabled', function()
    local w = world()
    local off = w.sched({enabled = false})
    w.add_road(A, {x = 0, z = 0})
    w.at('alice', 60, 0)
    w.t = 0
    assert(off:step() == false and off.ticks == 0 and w.seen.alice == nil, 'disabled automatic growth samples nothing')
    local on = w.sched()
    w.t = 10
    assert(on:step() == true and on.ticks == 1)
    w.t = 10.5
    assert(on:step() == false and on.ticks == 1, 'no second tick within the same second')
    w.t = 11
    assert(on:step() == true and on.ticks == 2)
end)

------------------------------------------------------------ blocked, restart and status
test('a blocked endpoint is never armed, queued or retried automatically', function()
    local w = world()
    local s = w.sched()
    w.add_road(A, {x = 0, z = 0})
    w.stop(A)
    w.at('alice', 60, 0); w.tick(s)
    w.at('alice', 20, 0); w.tick(s)
    for _ = 1, 100 do w.tick(s) end
    assert(#w.calls == 0 and s.queue:size() == 0 and s:status(A).eligible == false)
end)

test('restart replays nothing: a new scheduler has no arming, queue or retained window', function()
    local w = world()
    local s1 = w.sched()
    w.add_road(A, {x = 0, z = 0})
    w.busy = true
    w.at('alice', 60, 0); w.tick(s1)
    w.at('alice', 20, 0); w.tick(s1)
    assert(s1.queue:size() == 1)
    -- Process restart: a new scheduler over the same road, the slot now free.
    w.busy = false
    local s2 = w.sched()
    assert(s2.queue:size() == 0 and next(s2.slots) == nil)
    w.at('alice', 10, 0)
    for _ = 1, 20 do w.tick(s2) end
    assert(#w.calls == 0, 'a player first seen inside after restart activates nothing')
end)

test('status explains queued position, arming and eligibility', function()
    local w = world()
    local s = w.sched()
    w.add_road(A, {x = 0, z = 0})
    w.add_road('growth:v1:b', {x = 500, z = 0})
    w.busy = true
    w.at('alice', 60, 0); w.at('bob', 560, 0); w.tick(s)
    local st = s:status(A)
    assert(st.eligible and st.armed == 1 and st.queued == nil and st.retained_players == 2)
    w.at('alice', 20, 0); w.tick(s)
    st = s:status(A)
    -- Queued at the tick's time; the clock has advanced one second since.
    assert(st.queued and st.queued.position == 1 and st.queued.age == 1 and st.queued.expires_in == 29
        and st.queue.length == 1)
    assert(s:status('growth:v1:b').armed == 1 and s:status('growth:v1:b').queued == nil)
    assert(s:status('growth:v1:none').eligible == false)
end)

------------------------------------------------------------ presentation
local function road_summary(state, activation)
    return {road_id = A, state = state, revision = 1, endpoint = {x = 0, y = 0, z = 0}, local_heading = 0,
        preferred = {x = 1, z = 0}, source = {settlement_id = 's', exit_id = 'e'}, origin_op_id = 'op', segments = 1,
        activation = activation, attempts = {}, budgets = {chunks = 96, destination_chunks = 64, reserved_chunks = 32,
        expansions = 150000, destination_expansions = 50000, reserved_expansions = 50000, attempts = 4}}
end

test('status text explains disabled automatic growth, queued waiting, arming and blocked endpoints', function()
    local disabled = commands.growth_summary(road_summary('open', 'needs_departure'),
        {enabled = false, slot_busy = false, queue = {length = 0, max = 16}, armed = 0, eligible = true})
    assert(disabled:find('Automatic growth is disabled (roads_growth_automatic is false)', 1, true), disabled)
    assert(disabled:find('Waiting for a player', 1, true) == nil, 'disabled never claims to wait for a player')
    local queued = commands.growth_summary(road_summary('open', 'needs_departure'),
        {enabled = true, slot_busy = true, queued = {position = 2, of = 3, age = 4, expires_in = 26, players = 1},
            queue = {length = 3, max = 16}, armed = 0, eligible = true})
    assert(queued:find('Automatic growth is enabled', 1, true), queued)
    assert(queued:find('Queued for automatic growth: position 2 of 3, waiting 4 s, expires in 26 s.', 1, true), queued)
    assert(queued:find('The server slot is busy', 1, true) and queued:find('is not cancelled', 1, true), queued)
    local waiting = commands.growth_summary(road_summary('open', 'needs_departure'),
        {enabled = true, slot_busy = false, queue = {length = 0, max = 16}, armed = 1, eligible = true})
    assert(waiting:find('Waiting for a player: approach within 24 nodes after being seen beyond 36 (1 armed nearby).', 1, true), waiting)
    local blocked = commands.growth_summary(road_summary('stopped', 'consumed'),
        {enabled = true, slot_busy = false, queue = {length = 0, max = 16}, armed = 0, eligible = false})
    assert(blocked:find('automatic growth never retries a stopped road', 1, true), blocked)
    assert(commands.growth_summary(road_summary('open', 'needs_departure')):find('Automatic growth', 1, true) == nil,
        'without scheduler facts the summary is unchanged')
end)

------------------------------------------------------------ real growth service
-- The real growth service, job slot and stores: the scheduler admits through
-- growth:extend and nothing else. Players and time are scripted.
local function live(h, players)
    return assert(scheduler.new({enabled = true, now = function() return h.time end,
        connected = function()
            local names = {}
            for name in pairs(players) do names[#names + 1] = name end
            return names
        end,
        sample = function(name)
            local p = players[name]
            return p and {x = p.x, y = p.y, z = p.z} or nil
        end,
        roads = function()
            local list = {}
            for _, id in ipairs(h.growth_store:road_ids()) do
                local r = h.growth_store:road(id)
                list[#list + 1] = {road_id = id, revision = r.revision, endpoint = r.endpoint, state = r.state,
                    activation = r.activation}
            end
            return list
        end,
        slot_busy = function() return h.jobs.active ~= nil end,
        extend = function(id, actor) return h.growth:extend(id, actor) end}))
end

test('real service: two advancing segments, each activated by its own approach, no backtracking', function()
    local h = fixture.harness()
    local road_id = h.adopted()
    local players = {}
    local s = live(h, players)
    local function tick() s:tick(); h.time = h.time + 1 end
    players.alice = {x = 100, y = 0, z = 0}; tick()          -- outside 36 of the endpoint at 48
    players.alice = {x = 60, y = 0, z = 0}; tick()           -- 12 from it: token, cycle starts
    assert(h.growth.active ~= nil, 'the approach admits one cycle')
    h.run_until(function() return h.growth.active == nil end)
    local r = h.road(road_id)
    assert(r.revision == 2 and r.endpoint.x == 144 and r.activation == 'needs_departure' and h.builds == 1, 'first segment')
    players.alice = {x = 60, y = 0, z = 0}; tick()           -- 84 from the new endpoint: arms
    assert(h.growth.active == nil and h.builds == 1)
    players.alice = {x = 120, y = 0, z = 0}; tick()          -- 24 from it: token
    h.run_until(function() return h.growth.active == nil end)
    r = h.road(road_id)
    assert(r.revision == 3 and r.endpoint.x == 240 and h.builds == 2, 'second segment without any command')
    assert(h.growth:inspect(road_id, 'admin').world.status == 'matches_intended')
end)

test('real service: a busy manual slot holds the approach, and release admits it once', function()
    local h = fixture.harness()
    local road_id = h.adopted()
    local players = {}
    local s = live(h, players)
    local function tick() s:tick(); h.time = h.time + 1 end
    local manual = assert(h.jobs:hold({kind = 'planning', cancel = function() return nil, {code = 'no_plan'} end,
        status = function() return {kind = 'planning'} end}))
    players.alice = {x = 100, y = 0, z = 0}; tick()
    players.alice = {x = 60, y = 0, z = 0}; tick()
    for _ = 1, 5 do tick() end
    assert(h.jobs.active == manual and h.builds == 0 and h.road(road_id).state == 'open', 'manual job is untouched')
    assert(h.road(road_id).activation == 'needs_departure' and s:status(road_id).queued, 'queueing wrote nothing')
    h.jobs:release(manual)
    tick()
    assert(h.growth.active ~= nil, 'released slot admits the queued approach')
    h.run_until(function() return h.growth.active == nil end)
    assert(h.road(road_id).revision == 2 and h.builds == 1)
end)

test('real service: a stopped endpoint is not retried automatically', function()
    local h = fixture.harness()
    local road_id = h.adopted()
    local players = {}
    local s = live(h, players)
    local function tick() s:tick(); h.time = h.time + 1 end
    h.survey_error = {code = 'survey_failed', reason = 'scripted survey failure'}
    players.alice = {x = 100, y = 0, z = 0}; tick()
    players.alice = {x = 60, y = 0, z = 0}; tick()
    h.run_until(function() return h.growth.active == nil end)
    local stopped = h.road(road_id)
    assert(stopped.state == 'stopped' and stopped.activation == 'consumed', stopped.state)
    local surveys = h.surveys
    for _ = 1, 3 do
        players.alice = {x = 100, y = 0, z = 0}; tick()
        players.alice = {x = 60, y = 0, z = 0}; tick()
    end
    assert(h.surveys == surveys and h.growth.active == nil and h.road(road_id).state == 'stopped',
        'only an explicit retry reopens a stopped endpoint')
    assert(s:status(road_id).eligible == false)
end)

test('real service: restart replays nothing and a stationary player cannot chain construction', function()
    local h = fixture.harness()
    local road_id = h.adopted()
    local players = {}
    local s = live(h, players)
    local function tick() s:tick(); h.time = h.time + 1 end
    players.alice = {x = 100, y = 0, z = 0}; tick()
    players.alice = {x = 60, y = 0, z = 0}; tick()
    h.run_until(function() return h.growth.active == nil end)
    assert(h.road(road_id).revision == 2 and h.builds == 1)
    h.restart()
    local s2 = live(h, players)
    players.alice = {x = 130, y = 0, z = 0}      -- 14 from the endpoint at 144, first seen inside
    for _ = 1, 20 do s2:tick(); h.time = h.time + 1 end
    assert(h.builds == 1 and h.growth.active == nil and h.road(road_id).revision == 2, 'restart replays nothing')
end)

print('ok - '..count..' growth scheduler tests')
