-- SPDX-License-Identifier: GPL-3.0-or-later
-- Growth lifecycle: outward seed producer, adoption, claims, one-cycle
-- continuation, failures, cancellation and restart. The real outward service,
-- planner, composer, builder and seam code run over a simulated world; only
-- Towns, surveying and the clock are scripted.
local raster = dofile('src/raster.lua')
local seam = dofile('src/seam.lua')
local edges = dofile('src/edges.lua')
local planner = dofile('src/planner.lua')
local plans = dofile('src/plans.lua')
local build = dofile('src/build.lua')
local surface = dofile('src/surface.lua')
local outward = dofile('src/outward.lua')
local outward_store = dofile('src/outward_store.lua')
local growth = dofile('src/growth.lua')
local growth_store = dofile('src/growth_store.lua')
local fx = dofile('tests/outward_fixture.lua')
assert(edges.set_raster(raster)); assert(planner.set_edges(edges)); assert(plans.set_dependencies(raster, edges))
planner.set_seam_dependencies(seam, raster); plans.set_seam_dependency(seam); build.set_seam_dependencies(seam, raster)

local count = 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if not ok then error('growth '..name..': '..tostring(err)) end
    count = count + 1
end
local SID, EAST = 'auto:3:-2', '+x:0:0'
local STONE, COBBLE = 'mcl_core:stone', 'mcl_core:cobble'
local function copy(v)
    if type(v) ~= 'table' then return v end
    local r = {}; for k, x in pairs(v) do r[k] = copy(x) end; return r
end

local function harness(options)
    options = options or {}
    local h = {time = 0, queue = {}, events = {}, builds = 0, surveys = 0, writes = 0, nodes = {}, meta = {},
        storage = options.storage or fx.storage(), logs = {}}
    h.jobs = {active = nil}
    function h.jobs:hold(holder)
        if self.active then return nil, {code = 'busy', reason = 'another road job owns the server slot'} end
        self.active = {holder = holder, external = true}; return self.active
    end
    function h.jobs:release(token) if token and self.active == token then self.active = nil; return true end return false end

    local function key(p) return p.x..':'..p.y..':'..p.z end
    local function node_at(x, y, z)
        return h.nodes[x..':'..y..':'..z] or (y <= 0 and {name = STONE, param2 = 0} or {name = 'air', param2 = 0})
    end
    h.access = {get_node = function(p) local n = node_at(p.x, p.y, p.z); return {name = n.name, param2 = n.param2} end,
        has_metadata = function(p) return h.meta[key(p)] or false end,
        is_protected = function() return false end}
    local function has_timer() return false end
    function h.set(x, y, z, node) h.nodes[x..':'..y..':'..z] = node end

    local function terrain_for(bounds)
        local t = {version = 1, owner = 'survey', bounds = bounds}
        local cache = {}
        t.get_column = function(x, z)
            if x < bounds.min_x or x > bounds.max_x or z < bounds.min_z or z > bounds.max_z then return {status = 'outside'} end
            local id = x..':'..z
            if cache[id] then return cache[id] end
            local ground = -8
            for y = 8, -8, -1 do if node_at(x, y, z).name ~= 'air' then ground = y; break end end
            local band = {}
            for offset = -3, 5 do
                local n = node_at(x, ground + offset, z)
                band[offset] = n.name == 'air' and {kind = 'air', protected = false}
                    or {kind = 'natural', material = n.name, protected = false}
            end
            cache[id] = {status = 'ok', ground_y = ground, material = node_at(x, ground, z).name, band = band}
            return cache[id]
        end
        return t
    end
    local function rect(a, b)
        return {min_x = math.min(a.x, b.x) - 32, max_x = math.max(a.x, b.x) + 32, min_y = -50, max_y = 50,
            min_z = math.min(a.z, b.z) - 32, max_z = math.max(a.z, b.z) + 32}
    end
    h.survey = {plan = function(a, b)
        local r = rect(a, b)
        local chunks = {}
        for ix = math.floor((r.min_x + 32) / 80), math.floor((r.max_x + 32) / 80) do
            for iz = math.floor((r.min_z + 32) / 80), math.floor((r.max_z + 32) / 80) do chunks[#chunks + 1] = {ix = ix, iy = 0, iz = iz} end
        end
        return {chunks = chunks, chunk_count = #chunks, chunk_bounds = r, requested_bounds = r}
    end}
    function h.start_survey(a, b, owner)
        h.surveys = h.surveys + 1
        h.events[#h.events + 1] = 'survey'
        if h.survey_error then return nil, h.survey_error end
        local terrain = terrain_for(rect(a, b)); terrain.owner = owner
        local job = {state = 'succeeded'}
        function job:status() return {status = self.state, terrain = terrain, metrics = {}} end
        function job:cancel() self.state = 'cancelled' end
        h.last_survey = job
        return job
    end
    function h.after(delay, fn)
        h.queue[#h.queue + 1] = {at = h.time + delay, fn = fn, order = #h.queue}
    end
    function h.step()
        table.sort(h.queue, function(a, b) if a.at ~= b.at then return a.at < b.at end return a.order < b.order end)
        local task = table.remove(h.queue, 1)
        if not task then return false end
        if task.at > h.time then h.time = task.at end
        task.fn()
        return true
    end
    function h.run(limit)
        for _ = 1, limit or 20000 do if not h.step() then return end end
        error('queue did not drain')
    end
    function h.run_until(predicate, limit)
        for _ = 1, limit or 20000 do
            if predicate() then return true end
            if not h.step() then return predicate() end
        end
        error('condition not reached')
    end
    -- Builder: real construction over the simulated world unless scripted.
    function h.start_build(plan, done, guard)
        h.builds = h.builds + 1
        h.events[#h.events + 1] = 'build'
        if h.build_script then return h.build_script(plan, done, guard) end
        return build.new(plan, {now = function() return h.time end, guard = guard, after = h.after,
            load = function() end, access = h.access, classify = surface.classify, has_timer = has_timer,
            write = function(p, n)
                if h.write_hook then h.write_hook(p, n) end
                h.writes = h.writes + 1
                h.set(p.x, p.y, p.z, {name = n.name, param2 = n.param2 or 0})
            end}, done)
    end

    -- Storage wrapper that records the durable ordering.
    local base_set = h.storage.set
    h.storage.set = function(k, v)
        if k:find('registry$') then
            local reg = fx.deserialize(v)
            local states = {}
            for id, r in pairs(reg.roads) do states[#states + 1] = id..'='..r.state..(r.pending and ('/'..r.pending.state) or '') end
            table.sort(states)
            h.events[#h.events + 1] = 'registry:'..table.concat(states, ',')
        elseif k:find('segment/') then h.events[#h.events + 1] = 'record:'..k:match('segment/(.*)$')
        end
        return base_set(k, v)
    end

    local towns = {}
    local descriptor = {api_version = 1, settlement_id = SID, exit_id = EAST, source = 'test', direction = {x = 1, z = 0},
        anchor = {x = 0, y = 0, z = 0}, columns = {{x = 0, z = 0}, {x = 0, z = 1}}, length = 3,
        profile = {{y = 0, name = COBBLE, param2 = 0}}, center = {x = -10, y = 0, z = 0}, town_type = 'village'}
    function towns:settlement(id) return {id = id} end
    function towns:exit() return copy(descriptor) end
    function towns:writer() return nil end
    function towns:overlay() return {} end
    function towns:recheck() return true end
    function towns:new_guard() return function() return 'ok' end end
    h.towns = towns

    local config = {world = {chunksize = 5}, planner = {weights = {slope = 4, turn = 2, cut = 1, fill = 1}, road_material = COBBLE},
        composition = {road_material = COBBLE}}
    local function new_planner(terrain, request, c)
        if h.on_planner then h.on_planner(terrain, request) end
        return planner.new(terrain, request, c)
    end
    local function compose(terrain, route, c) return plans.compose(terrain, route, c) end

    local function wire()
        h.growth_store = growth_store.new({storage = h.storage, serialize = fx.serialize, deserialize = fx.deserialize,
            now = function() return 1000 + h.time end})
        h.store = outward_store.new({storage = h.storage, serialize = fx.serialize, deserialize = fx.deserialize,
            now = function() return 1000 + h.time end})
        local outward_service
        h.growth = assert(growth.new({store = h.growth_store, jobs = h.jobs, now = function() return h.time end,
            after = h.after, raster = raster, seam = seam, access = h.access, has_timer = has_timer,
            classify = surface.classify, load_area = function() end, world_config = function() return config end,
            survey = h.survey, start_survey = h.start_survey, new_planner = new_planner, compose = compose,
            start_build = h.start_build, save_interval = function() return 5.3 end, towns = options.growth_towns,
            wrap_terrain = options.growth_towns and function(t) return t end or nil,
            find_operation = function(id) return outward_service and outward_service:operation(id) end,
            log = function(level, message) h.logs[#h.logs + 1] = level..': '..message end}))
        local ops = {jobs = h.jobs, towns = towns, store = h.store, now = function() return h.time end, after = h.after,
            world_config = function() return config end, survey = h.survey, start_survey = h.start_survey,
            exit_endpoints = function(terrain, d, target)
                local ground = terrain.get_column(d.anchor.x + 8, d.anchor.z).ground_y
                local start = {x = d.anchor.x + 8, y = ground, z = d.anchor.z}
                local goal = {x = target.x, y = terrain.get_column(target.x, target.z).ground_y, z = target.z}
                return {start = {requested = {x = start.x, y = start.y + 0.5, z = start.z}, ground = copy(start), resolved = copy(start)},
                    goal = {requested = {x = goal.x, y = goal.y + 0.5, z = goal.z}, ground = copy(goal), resolved = copy(goal)}}
            end,
            new_planner = new_planner, compose = compose, start_build = h.start_build,
            wrap_terrain = function(t) return t end, save_interval = function() return 5.3 end,
            growth = (not options.legacy) and h.growth.hooks or nil,
            log = function() end}
        outward_service = assert(outward.new(ops))
        h.outward = outward_service
    end
    wire()
    -- A restart: new stores and services over the same storage, pending callbacks gone.
    function h.restart()
        h.queue = {}; h.jobs.active = nil
        wire()
        h.outward:recover()
        h.growth:recover()
    end
    function h.events_since(n) local r = {}; for i = n + 1, #h.events do r[#r + 1] = h.events[i] end; return r end

    function h.build_outward(overrides)
        local request = {settlement_id = SID, exit_id = EAST, requester = 'alice', policy = {version = 1, seed = 1},
            candidates = {{x = 48, z = 0}}}
        for k, v in pairs(overrides or {}) do request[k] = v end
        local started, err = h.outward:start(request)
        if not started then return nil, err end
        h.run_until(function() return h.outward:status() == nil end)
        return h.outward:status(SID)
    end
    function h.seeded_road(overrides)
        local status = assert(h.build_outward(overrides))
        assert(status.state == 'built', status.state..' '..tostring(status.error and status.error.reason))
        h.builds, h.surveys = 0, 0 -- count growth work separately from the outward road
        return status
    end
    function h.adopted()
        local status = h.seeded_road()
        return assert(h.growth:adopt(status.op_id, 'admin')), status
    end
    function h.run_cycle(road_id)
        local id, err = h.growth:extend(road_id, 'admin')
        if not id then return nil, err end
        h.run_until(function() return h.growth.active == nil end)
        return id
    end
    function h.road(road_id) return h.growth_store:road(road_id) end
    return h
end

local function road_columns(h, road_id)
    -- cobble surface columns of everything built so far, by z=0 line
    local xs = {}
    for x = 0, 400 do if h.nodes[x..':0:0'] and h.nodes[x..':0:0'].name == COBBLE then xs[#xs + 1] = x end end
    return xs
end

-- Index entry plus record for an existing road, as a stand-in for any registered footprint.
local function add_obstacle(h, id, centerline)
    local cells, seen, bounds = {}, {}, nil
    for i = 1, #centerline - 1 do
        for _, p in ipairs(raster.segment(centerline[i], centerline[i + 1]).columns) do
            bounds = bounds or {x1 = p.x, z1 = p.z, x2 = p.x, z2 = p.z}
            bounds.x1 = math.min(bounds.x1, p.x); bounds.x2 = math.max(bounds.x2, p.x)
            bounds.z1 = math.min(bounds.z1, p.z); bounds.z2 = math.max(bounds.z2, p.z)
            local cell = growth_store.cell(p.x, p.z)
            if not seen[cell] then seen[cell] = true; cells[#cells + 1] = cell end
        end
    end
    table.sort(cells)
    assert(h.growth_store:save_record({schema = 1, id = id, centerline = centerline}))
    assert(h.growth_store:update(function(d)
        d.segs[id] = {kind = 'segment', state = 'built', writes = 'all', cells = cells, bounds = bounds, bytes = 10,
            road_id = 'other'}
        return true
    end))
end
local function wall(x, z1, z2)
    local line = {}
    for z = z1, z2, 4 do line[#line + 1] = {x = x, y = 0, z = z} end
    return line
end

------------------------------------------------------------------ seed producer
test('an outward road records its intended seed before writing and verifies it afterwards', function()
    local h = harness()
    local before = #h.events
    local status = h.seeded_road()
    local op = h.outward:operation(status.op_id)
    assert(op.growth.state == 'verified' and op.growth.seed_id == 'growth:v1:'..status.op_id..':s1')
    local entry = h.growth_store:entry(op.growth.seed_id)
    assert(entry.kind == 'seed' and entry.state == 'verified' and entry.writes == 'all' and entry.origin_op_id == status.op_id)
    local record = assert(h.growth_store:load_record(op.growth.seed_id))
    assert(record.state == 'verified' and record.terminal.x == 48 and record.terminal_heading == 0
        and record.preferred.x == 1 and #record.next_seam.preserved > 0)
    -- Ordering: seed record and registry reference, then the building op, then the write.
    local order = h.events_since(before)
    local function index_of(prefix)
        for i, e in ipairs(order) do if e:sub(1, #prefix) == prefix then return i end end
    end
    local seed_record = index_of('record:'..op.growth.seed_id)
    local seed_registry = index_of('registry:')
    local build_event = index_of('build')
    assert(seed_record and seed_registry and build_event and seed_record < seed_registry and seed_registry < build_event, table.concat(order, ' | '))
    assert(h.writes > 0 and h.nodes['48:0:0'].name == COBBLE)
end)

test('legacy operations and failed or unverified seeds are explicitly unadoptable', function()
    local legacy = harness({legacy = true})
    local status = legacy:seeded_road()
    local op = legacy.outward:operation(status.op_id)
    assert(op.growth == nil)
    local id, err = legacy.growth:adopt(status.op_id, 'admin')
    assert(not id and err.code == 'legacy_unadoptable', err and err.code)

    -- Seed storage fails before any write: the road is built but not growth-ready.
    local h = harness()
    local failing = true
    local base = h.storage.fail_set
    h.storage.fail_set = function(k) return failing and k:find('growth/v1/segment/') ~= nil end
    status = h.seeded_road()
    op = h.outward:operation(status.op_id)
    assert(op.growth.state == 'unseeded' and op.growth.code == 'storage_failed' and h.growth_store:counts().segments == 0)
    id, err = h.growth:adopt(status.op_id, 'admin')
    assert(not id and err.code == 'legacy_unadoptable')
    assert(h.outward:eligibility(SID, EAST) == 'reserved', 'the outward reservation is unaffected')

    -- Readback differs after construction: the seed stays intended, not verified.
    h = harness()
    h.write_hook = function(p, n)
        if p.x == 48 and p.y == 0 and p.z == 0 then n.param2 = 1 end
    end
    status = h.seeded_road()
    op = h.outward:operation(status.op_id)
    assert(op.growth.state == 'unverified' and h.growth_store:entry(op.growth.seed_id).state == 'intended')
    id, err = h.growth:adopt(status.op_id, 'admin')
    assert(not id and err.code == 'seed_unverified')

    -- Registry save failure for the seed leaves the orphan record unreferenced.
    h = harness()
    h.storage.fail_set = function(k) return k:find('registry$') ~= nil end
    status = assert(h.build_outward())
    assert(status.state == 'built')
    assert(h.outward:operation(status.op_id).growth.state == 'unseeded' and h.growth_store:counts().segments == 0)
end)

test('a seed is released when the outward operation provably wrote nothing and kept otherwise', function()
    local h = harness()
    h.build_script = function() return nil, {code = 'build_failed', reason = 'scripted startup refusal'} end
    local status = assert(h.build_outward())
    assert(status.state == 'failed' and status.writes == 'none')
    assert(h.growth_store:counts().segments == 0 and h.outward:operation(status.op_id).growth.state == 'void')
    assert(h.outward:eligibility(SID, EAST) == 'open')

    for _, case in ipairs({{'partial_build', 'partial', 'some'}, {'mystery', 'partial', 'unknown'}}) do
        h = harness()
        h.build_script = function(plan, done)
            local b = {cancel = function() end}
            h.after(0, function() done({code = case[1], reason = 'scripted'}, {writes = 3}) end)
            return b
        end
        status = assert(h.build_outward())
        assert(status.state == case[2] and status.writes == case[3], status.state)
        local seed_id = 'growth:v1:'..status.op_id..':s1'
        assert(h.growth_store:entry(seed_id).state == 'intended', 'uncertain outward work keeps its seed reserved')
        assert(h.outward:operation(status.op_id).growth.state == 'intended')
        local id, err = h.growth:adopt(status.op_id, 'admin')
        assert(not id and err.code == 'not_adoptable')
    end

    -- A restart that interrupts the build keeps the seed; an interrupted no-write op releases it.
    h = harness()
    h.build_script = function() return {cancel = function() end} end
    assert(h.outward:start({settlement_id = SID, exit_id = EAST, requester = 'alice', policy = {version = 1, seed = 1},
        candidates = {{x = 48, z = 0}}}))
    h.run_until(function() return h.builds == 1 end)
    local op_id = h.outward:status().op_id
    h.restart()
    assert(h.outward:operation(op_id).state == 'interrupted' and h.outward:operation(op_id).writes == 'unknown')
    assert(h.growth_store:entry('growth:v1:'..op_id..':s1').state == 'intended', 'unknown writes keep the seed')
    local op = h.store:find(SID, op_id)
    op.writes = 'none'; assert(h.store:save(SID, op))
    h.restart()
    assert(h.growth_store:entry('growth:v1:'..op_id..':s1') == nil, 'interrupted with no writes releases the seed')
end)

------------------------------------------------------------------ adoption
test('adoption is explicit, idempotent and keeps the outward reservation', function()
    local h = harness()
    local status = h.seeded_road()
    local road_id = assert(h.growth:adopt(status.op_id, 'admin'))
    assert(road_id == 'growth:v1:'..status.op_id)
    assert(h.growth:adopt(status.op_id, 'admin') == road_id and #h.growth_store:road_ids() == 1)
    local road = h.road(road_id)
    assert(road.state == 'open' and road.revision == 1 and road.next_seq == 2 and road.endpoint.x == 48
        and road.local_heading == 0 and road.preferred.x == 1 and road.activation == 'needs_departure')
    assert(h.growth_store:entry(road.segments[1]).road_id == road_id)
    local started, err = h.outward:start({settlement_id = SID, exit_id = EAST, requester = 'alice', policy = {version = 1},
        candidates = {{x = 48, z = 0}}})
    assert(not started and err.code == 'already_reserved' and err.scope == 'settlement')
    assert(h.outward:eligibility(SID, '+z:10:10') == 'reserved')
    h.restart()
    assert(h.road(road_id).state == 'open' and h.growth:adopt(status.op_id, 'admin') == road_id)
    assert(h.growth:status(road_id).source.exit_id == EAST)
end)

test('adoption refuses unknown, unbuilt, mismatching and edited operations', function()
    local h = harness()
    local _, err = h.growth:adopt('nope', 'admin'); assert(err.code == 'unknown_operation')
    _, err = h.growth:adopt(SID..'/'..EAST..'#9', 'admin'); assert(err.code == 'unknown_operation')
    _, err = h.growth:adopt(nil, 'admin'); assert(err.code == 'invalid_request')
    local status = h.seeded_road()
    -- A node in the intended seam is edited: adoption re-reads it and refuses.
    h.set(48, 1, 0, {name = 'mcl_core:stone', param2 = 0})
    local id
    id, err = h.growth:adopt(status.op_id, 'admin')
    assert(not id and err.code == 'seam_changed' and #h.growth_store:road_ids() == 0)
    h.set(48, 1, 0, {name = 'air', param2 = 0})
    assert(h.growth:adopt(status.op_id, 'admin'))
    -- A seed whose geometry does not match the operation is rejected.
    h = harness()
    status = h.seeded_road()
    local record = h.growth_store:load_record('growth:v1:'..status.op_id..':s1')
    record.centerline[2].y = 1
    assert(h.growth_store:save_record(record))
    id, err = h.growth:adopt(status.op_id, 'admin')
    assert(not id and err.code == 'seed_mismatch')
    -- A corrupt registry blocks adoption instead of looking empty.
    h = harness()
    status = h.seeded_road()
    h.storage.data['growth/v1/registry'] = 'garbage'
    h.restart()
    id, err = h.growth:adopt(status.op_id, 'admin')
    assert(not id and err.code == 'growth_disabled')
end)

------------------------------------------------------------------ claims and admission
test('incoming claims reject outward admission and the synchronous preflight, even after restart', function()
    local h = harness()
    -- Admission: a fake incoming claim on the full exit id.
    assert(h.growth_store:update(function(d)
        d.claims['exit:'..SID..'/'..EAST] = {kind = 'exit', road_id = 'growth:v1:other', segment_id = 'growth:v1:other:s2:r1',
            state = 'pending', side = 'destination'}
        return true
    end))
    local started, err = h.outward:start({settlement_id = SID, exit_id = EAST, requester = 'alice', policy = {version = 1},
        candidates = {{x = 48, z = 0}}})
    assert(not started and err.code == 'already_reserved' and err.scope == 'exit' and err.claim.state == 'pending', err and err.code)
    assert(h.jobs.active == nil and h.surveys == 0 and h.store:latest(SID) == nil)
    assert(h.outward:eligibility(SID, EAST) == 'claimed' and h.outward:eligibility(SID, '+z:10:10') == 'open')
    assert(h.outward:eligibility(SID) == 'open', 'settlement-wide queries are not exit claims')
    h.restart()
    started, err = h.outward:start({settlement_id = SID, exit_id = EAST, requester = 'alice', policy = {version = 1},
        candidates = {{x = 48, z = 0}}})
    assert(not started and err.code == 'already_reserved', 'persisted claims survive restart')
    assert(h.builds == 0 and h.writes == 0)

    -- Preflight: a claim that arrives after admission, during the durability wait.
    h = harness()
    assert(h.outward:start({settlement_id = SID, exit_id = EAST, requester = 'alice', policy = {version = 1},
        candidates = {{x = 48, z = 0}}}))
    h.run_until(function() return h.outward:status().stage == 'durability_wait' end)
    assert(h.growth_store:update(function(d)
        d.claims['exit:'..SID..'/'..EAST] = {kind = 'exit', road_id = 'growth:v1:late', segment_id = 's', state = 'pending'}
        return true
    end))
    h.run()
    local status = h.outward:status(SID)
    assert(status.state == 'failed' and status.writes == 'none' and status.error.code == 'already_reserved')
    assert(h.builds == 0 and h.writes == 0 and h.growth_store:counts().segments == 0, 'seed released, builder never started')

    -- Claims that cannot be established fail closed.
    h = harness()
    h.storage.data['growth/v1/registry'] = 'garbage'
    h.restart()
    started, err = h.outward:start({settlement_id = SID, exit_id = EAST, requester = 'alice', policy = {version = 1},
        candidates = {{x = 48, z = 0}}})
    assert(not started and err.code == 'growth_unavailable')
    assert(h.outward:eligibility(SID, EAST) == 'unreadable')
end)

------------------------------------------------------------------ one-cycle continuation
test('one cycle persists intent, prepares, reserves, waits, builds once and publishes the next endpoint', function()
    local h = harness()
    local road_id = h.adopted()
    local before = #h.events
    local segment_id = assert(h.run_cycle(road_id))
    assert(segment_id == road_id..':s2:r1')
    local road = h.road(road_id)
    assert(road.state == 'open' and road.revision == 2 and road.endpoint.x == 144 and road.endpoint.z == 0
        and road.local_heading == 0 and road.last_segment_id == segment_id and road.pending == nil
        and road.activation == 'needs_departure' and #road.segments == 2 and road.next_seq == 3)
    assert(road.preferred.x == 1 and road.preferred.z == 0, 'the preferred direction is unchanged')
    assert(h.growth_store:claim('endpoint:'..road_id..':1') == nil, 'the old source claim is released after publication')
    local entry = h.growth_store:entry(segment_id)
    assert(entry.state == 'built' and entry.writes == 'all' and entry.road_id == road_id)
    local record = assert(h.growth_store:load_record(segment_id))
    assert(record.state == 'built' and record.seam_status == 'verified' and record.from_revision == 1 and record.sequence == 2)
    assert(h.nodes['144:0:0'].name == COBBLE and h.nodes['100:0:0'].name == COBBLE and h.builds == 1)
    -- Durable ordering.
    local order = h.events_since(before)
    local function first(pattern)
        for i, e in ipairs(order) do if e:find(pattern, 1, true) then return i end end
    end
    local function exact(name) for i, e in ipairs(order) do if e == name then return i end end end
    local planning, survey_i = first('=planning/planning'), exact('survey')
    local prepared, building = first('record:'..segment_id), first('=building/building')
    local build_i, built = exact('build'), first('=open')
    assert(planning and survey_i and prepared and building and build_i and built, table.concat(order, ' | '))
    assert(planning < survey_i and survey_i < prepared and prepared < building and building < build_i and build_i < built,
        table.concat(order, ' | '))
    -- Status reports the cycle and a second, explicit cycle chains on the new seam.
    local status = h.growth:status(road_id)
    assert(status.state == 'open' and #status.attempts == 1 and status.attempts[1].outcome == 'built'
        and status.attempts[1].targets[1].length == 96 and status.attempts[1].targets[1].outcome == 'composed')
    local second = assert(h.run_cycle(road_id))
    assert(second == road_id..':s3:r2' and h.road(road_id).endpoint.x == 240 and h.builds == 2)
    assert(h.growth:inspect(road_id, 'admin').world.status == 'matches_intended')
end)

test('a segment with an unfinished cycle or settled state cannot be extended twice', function()
    local h = harness()
    local road_id = h.adopted()
    local first = assert(h.growth:extend(road_id, 'alice'))
    local again, err = h.growth:extend(road_id, 'bob')
    assert(not again and err.code == 'not_extendable' and err.state == 'planning')
    local _, other = h.growth:extend('growth:v1:none', 'bob'); assert(other.code == 'unknown_road')
    h.run_until(function() return h.growth.active == nil end)
    assert(h.road(road_id).revision == 2 and first == road_id..':s2:r1')
    assert(h.road(road_id).next_seq == 3, 'identities are allocated once per cycle')
    -- Stale revision: the road moved on between intent and reservation.
    h = harness()
    road_id = h.adopted()
    h.on_planner = function()
        assert(h.growth_store:update(function(d) d.roads[road_id].revision = 7; return true end))
    end
    h.run_cycle(road_id)
    local road = h.road(road_id)
    assert(road.state == 'stopped' and road.stop.code == 'stale_revision' and road.revision == 7 and h.builds == 0,
        'a stale revision never builds')
    assert(h.growth_store:counts().segments == 1 and #road.segments == 1)
end)

test('an edited seam stops extension without consuming anything or repairing it', function()
    local h = harness()
    local road_id = h.adopted()
    h.set(48, 0, 0, {name = 'mcl_core:dirt', param2 = 0})
    local before = h.road(road_id)
    local id, err = h.growth:extend(road_id, 'admin')
    assert(not id and err.code == 'seam_changed')
    local after = h.road(road_id)
    assert(after.state == 'open' and after.next_seq == before.next_seq and after.activation == before.activation)
    assert(h.surveys == 0 and h.jobs.active == nil and h.nodes['48:0:0'].name == 'mcl_core:dirt', 'player edit left alone')
    local inspect = h.growth:inspect(road_id, 'admin')
    assert(inspect.world.status == 'mismatch' and inspect.world.comparison.mismatched >= 1 and #inspect.world.comparison.samples >= 1)
    h.set(48, 0, 0, {name = COBBLE, param2 = 0})
    assert(h.growth:extend(road_id, 'admin'))
end)

test('the obstacle index masks stored roads and refuses dense or oversized coverage before surveying', function()
    -- A long stored road across the corridor blocks both directional targets.
    local h = harness()
    local road_id = h.adopted()
    add_obstacle(h, 'wall:s1', wall(100, -200, 200))
    local first_events = #h.events
    assert(h.run_cycle(road_id))
    local road = h.road(road_id)
    assert(road.state == 'stopped' and road.stop.code, 'blocked, not extended')
    assert(road.revision == 1 and h.builds == 0 and h.nodes['100:0:0'] == nil)
    assert(h.growth_store:entry('wall:s1') and #road.attempts == 1 and road.attempts[1].outcome == 'blocked')
    assert(h.growth_store:counts().segments == 2)

    -- A coverage that cannot be established fails closed before any survey.
    h = harness()
    road_id = h.adopted()
    assert(h.growth_store:update(function(d)
        for i = 1, 600 do
            d.segs['dense'..i] = {kind = 'segment', state = 'built', writes = 'all', cells = {'0:0', '1:0'},
                bounds = {x1 = 0, z1 = 0, x2 = 300, z2 = 20}, bytes = 1, road_id = 'x'}
        end
        return true
    end))
    h.run_cycle(road_id)
    road = h.road(road_id)
    assert(road.state == 'stopped' and road.stop.code == 'road_index_budget', road.stop and road.stop.code)
    assert(h.surveys == 0 and h.builds == 0 and h.writes > 0 and h.nodes['100:0:0'] == nil)
    assert(h.growth:status(road_id).stop.limit == 1024)

    -- A corrupt index entry (cells that disagree with stored geometry) fails closed.
    h = harness()
    road_id = h.adopted()
    add_obstacle(h, 'bad:s1', wall(100, -8, 8))
    assert(h.growth_store:update(function(d) d.segs['bad:s1'].cells = {'0:0', '9:9'}; return true end))
    h.run_cycle(road_id)
    assert(h.road(road_id).stop.code == 'road_index_corrupt' and h.surveys == 0)

    -- An obstacle registered while the search runs is caught by the composed-footprint recheck.
    h = harness()
    road_id = h.adopted()
    h.on_planner = function() add_obstacle(h, 'late:s1', wall(100, -200, 200)) end
    h.run_cycle(road_id)
    road = h.road(road_id)
    assert(road.state == 'stopped' and h.builds == 0 and road.attempts[1].targets[1].outcome == 'road_overlap',
        road.stop and road.stop.code)
    -- The fallback target then sees the registered wall in its own complete coverage and is blocked.
    assert(road.stop.code == 'bounded_no_route' and road.revision == 1)
end)

------------------------------------------------------------------ failures
test('storage failures before any write stop the cycle with zero writes and never reuse an identity', function()
    local function setup(fail_pattern, nth)
        local h = harness()
        local road_id = h.adopted()
        local seen = 0
        h.storage.fail_set = function(k)
            if k:find(fail_pattern) then seen = seen + 1; return seen == (nth or 1) end
            return false
        end
        return h, road_id
    end
    -- Intent cannot be saved: nothing is surveyed.
    local h, road_id = setup('registry$', 1)
    local id, err = h.growth:extend(road_id, 'admin')
    assert(not id and err.code == 'storage_failed' and h.surveys == 0 and h.jobs.active == nil)
    assert(h.road(road_id).state == 'open')
    assert(h.road(road_id).next_seq == 3, 'the failed attempt burned its identity')
    h.storage.fail_set = nil
    assert(h.run_cycle(road_id) == road_id..':s3:r1', 'the next cycle gets a fresh sequence')

    -- The prepared segment cannot be saved.
    h, road_id = setup('segment/', 1)
    h.run_cycle(road_id)
    local road = h.road(road_id)
    assert(road.state == 'stopped' and road.stop.code == 'storage_failed' and h.builds == 0 and h.writes > 0)
    assert(h.nodes['100:0:0'] == nil and h.growth_store:counts().segments == 1)
    h.storage.fail_set = nil
    assert(h.growth:retry(road_id, 'admin') == road_id..':s3:r1')

    -- The reservation cannot be saved (second registry write): the builder is never started.
    h, road_id = setup('registry$', 2)
    h.run_cycle(road_id)
    road = h.road(road_id)
    assert(road.state == 'stopped' and road.stop.code == 'storage_failed' and h.builds == 0)
    assert(h.growth_store:counts().segments == 1 and h.growth_store:claim('endpoint:'..road_id..':1') == nil)
    -- Read-back mismatch is a failure too.
    h, road_id = setup('nothing', 1)
    h.storage.mismatch = true
    id, err = h.growth:extend(road_id, 'admin')
    assert(not id and err.code == 'storage_failed')
end)

test('a completion that cannot be saved leaves the old intent reserved and uncertain, with no optimistic advance', function()
    local h = harness()
    local road_id = h.adopted()
    local building_saved = false
    h.storage.fail_set = function(k, v)
        if k:find('registry$') and v:find('"building"') == nil and building_saved and v:find('built') then return true end
        if k:find('registry$') and v:find('building') then building_saved = true end
        return false
    end
    h.run_cycle(road_id)
    local road = h.road(road_id)
    assert(h.builds == 1 and h.nodes['144:0:0'].name == COBBLE, 'the world was written once')
    assert(road.state == 'uncertain' and road.revision == 1 and road.endpoint.x == 48 and road.pending.writes == 'all',
        road.state)
    local entry = h.growth_store:entry(road_id..':s2:r1')
    assert(entry.state == 'uncertain' and h.growth_store:claim('endpoint:'..road_id..':1').state == 'uncertain')
    local id, err = h.growth:extend(road_id, 'admin'); assert(not id and err.code == 'not_extendable')
    id, err = h.growth:retry(road_id, 'admin'); assert(not id and err.code == 'not_retryable')
    -- Restart replays nothing and stays uncertain.
    h.storage.fail_set = nil
    h.restart()
    assert(h.road(road_id).state == 'uncertain' and h.builds == 1 and #h.queue == 0 and h.jobs.active == nil)
    assert(h.growth:status(road_id).explanation:find('never promotes'))
    assert(h.growth:inspect(road_id, 'admin').world.status == 'matches_intended', 'inspection reports, it does not promote')
    assert(h.road(road_id).state == 'uncertain')
end)

test('uncertain builder outcomes keep reservations; proven zero-write outcomes release them', function()
    local function run(script, claim)
        local h = harness()
        local road_id = h.adopted()
        h.build_script = script(h)
        local id = assert(h.growth:extend(road_id, 'admin', {claims = {{id = 'exit:far/town', kind = 'exit'}}}))
        h.run_until(function() return h.growth.active == nil end)
        return h, road_id, id
    end
    local function finishing(code, writes)
        return function(h)
            return function(plan, done)
                local b = {cancel = function() end}
                h.after(0, function() done({code = code, reason = 'scripted '..code}, {writes = writes}) end)
                return b
            end
        end
    end
    for _, case in ipairs({{'partial_build', 'some'}, {'build_failed', 'unknown'}, {'mystery', 'unknown'}}) do
        local h, road_id, id = run(finishing(case[1], 2))
        local road = h.road(road_id)
        assert(road.state == 'uncertain' and road.pending.writes == case[2] and road.stop.code == case[1], case[1])
        assert(h.growth_store:entry(id).state == 'uncertain' and h.growth_store:claim('exit:far/town').state == 'uncertain')
        assert(h.growth_store:claim('endpoint:'..road_id..':1').state == 'uncertain')
        local _, err = h.growth:retry(road_id, 'admin'); assert(err.code == 'not_retryable')
        h.restart()
        assert(h.road(road_id).state == 'uncertain' and h.builds == 1)
    end
    for _, code in ipairs({'stale_plan', 'seam_changed', 'towns_busy', 'towns_conflict', 'write_budget'}) do
        local h, road_id, id = run(finishing(code, 0))
        local road = h.road(road_id)
        assert(road.state == 'stopped' and road.stop.code == code and road.pending == nil, code)
        assert(h.growth_store:entry(id) == nil and h.growth_store:claim('exit:far/town') == nil
            and h.growth_store:claim('endpoint:'..road_id..':1') == nil, 'known zero writes release the reservation')
        assert(#road.segments == 1 and road.revision == 1)
    end
    -- A synchronous refusal to start the builder made no writes; an exception from inside is also zero here
    -- because no write can precede the scheduled tick.
    local h, road_id = run(function(hh) return function() return nil, {code = 'build_failed', reason = 'refused'} end end)
    assert(h.road(road_id).state == 'stopped' and h.road(road_id).stop.code == 'build_failed')
    h, road_id = run(function(hh) return function() error('boom') end end)
    assert(h.road(road_id).state == 'stopped')
end)

test('dual-side claims are reserved with the segment, conflict-checked and retained on success', function()
    local h = harness()
    local road_id = h.adopted()
    local claim = {id = 'exit:far/town', kind = 'exit'}
    assert(h.growth:extend(road_id, 'admin', {claims = {claim}}))
    h.run_until(function() return h.road(road_id).state == 'building' end)
    local source, dest = h.growth_store:claim('endpoint:'..road_id..':1'), h.growth_store:claim('exit:far/town')
    assert(source.side == 'source' and dest.side == 'destination' and source.segment_id == dest.segment_id
        and source.state == 'pending' and dest.state == 'pending')
    h.run()
    assert(h.growth_store:claim('exit:far/town').state == 'held' and h.growth_store:claim('endpoint:'..road_id..':1') == nil)
    assert(h.road(road_id).state == 'open')
    -- A later cycle (or another road) cannot claim the same destination.
    local _, err = h.growth:extend(road_id, 'admin', {claims = {{id = '', kind = 'exit'}}})
    assert(err.code == 'invalid_request')
    assert(h.growth:extend(road_id, 'admin', {claims = {claim}}))
    h.run()
    local road = h.road(road_id)
    assert(road.state == 'stopped' and road.stop.code == 'claim_conflict' and h.builds == 1, road.stop and road.stop.code)
    assert(h.growth_store:claim('exit:far/town').state == 'held', 'the earlier holder keeps its claim')
    assert(h.growth_store:entry(road_id..':s3:r2') == nil and #road.segments == 2)
end)

------------------------------------------------------------------ cancellation
test('cancellation is token safe at every stage', function()
    -- While surveying: late callbacks do nothing.
    local h = harness()
    local road_id = h.adopted()
    assert(h.growth:extend(road_id, 'alice'))
    assert(h.growth.active.stage == 'planning')
    h.run_until(function() return h.growth.active.stage == 'surveying' end)
    assert(h.growth:cancel(road_id, 'alice'))
    h.run()
    local road = h.road(road_id)
    assert(road.state == 'stopped' and road.stop.code == 'cancelled' and h.builds == 0 and h.writes > 0 and h.jobs.active == nil)
    assert(h.last_survey.state == 'cancelled' and road.pending == nil and road.attempts[1].outcome == 'cancelled')
    local _, err = h.growth:cancel(road_id, 'alice'); assert(err.code == 'no_plan')
    assert(h.growth:retry(road_id, 'alice'))
    h.run()
    assert(h.road(road_id).state == 'open' and h.road(road_id).revision == 2)

    -- During the durability wait: the registry reservation is released and the builder never starts.
    h = harness()
    road_id = h.adopted()
    assert(h.growth:extend(road_id, 'alice', {claims = {{id = 'exit:far/town', kind = 'exit'}}}))
    h.run_until(function() return h.growth.active.stage == 'durability_wait' end)
    assert(h.growth_store:entry(road_id..':s2:r1') and h.growth_store:claim('exit:far/town'))
    assert(h.growth:cancel(road_id, 'alice'))
    h.run()
    road = h.road(road_id)
    assert(road.state == 'stopped' and h.builds == 0 and h.growth_store:entry(road_id..':s2:r1') == nil
        and h.growth_store:claim('exit:far/town') == nil and #road.segments == 1)

    -- After the builder started: the reservation stays and the late result is ignored.
    h = harness()
    road_id = h.adopted()
    local cancelled_builder, late_done
    h.build_script = function(plan, done)
        late_done = done
        return {cancel = function() cancelled_builder = true end}
    end
    assert(h.growth:extend(road_id, 'alice'))
    h.run_until(function() return h.builds == 1 end)
    assert(h.growth:cancel(road_id, 'alice'))
    assert(cancelled_builder and h.jobs.active == nil)
    road = h.road(road_id)
    assert(road.state == 'uncertain' and road.stop.code == 'cancelled' and road.pending.writes == 'unknown')
    late_done(nil, {writes = 5})
    assert(h.road(road_id).state == 'uncertain' and h.road(road_id).revision == 1, 'a stale callback cannot publish')
    h.run()
    assert(h.builds == 1 and h.road(road_id).state == 'uncertain')
    -- A fresh cycle after cancellation cannot be confused with the old callbacks.
    assert(h.growth:cancel('x') == nil)
end)

------------------------------------------------------------------ restart
test('restart converts interrupted cycles conservatively and never replays them', function()
    -- Planning interrupted: known zero writes.
    local h = harness()
    local road_id = h.adopted()
    assert(h.growth:extend(road_id, 'alice'))
    h.run_until(function() return h.growth.active.stage == 'surveying' end)
    h.restart()
    local road = h.road(road_id)
    assert(road.state == 'stopped' and road.stop.code == 'interrupted' and road.pending == nil)
    assert(h.builds == 0 and h.writes > 0 and #h.queue == 0 and h.growth.active == nil)
    assert(h.road(road_id).next_seq == 3)
    assert(h.growth:retry(road_id, 'alice') == road_id..':s3:r1')
    h.run()
    assert(h.road(road_id).revision == 2)

    -- Building interrupted: uncertain, both sides reserved, no replay.
    h = harness()
    road_id = h.adopted()
    h.build_script = function() return {cancel = function() end} end
    assert(h.growth:extend(road_id, 'alice', {claims = {{id = 'exit:far/town', kind = 'exit'}}}))
    h.run_until(function() return h.builds == 1 end)
    h.restart()
    road = h.road(road_id)
    assert(road.state == 'uncertain' and road.pending.state == 'uncertain' and #h.queue == 0)
    assert(h.growth_store:claim('exit:far/town').state == 'uncertain'
        and h.growth_store:claim('endpoint:'..road_id..':1').state == 'uncertain')
    assert(h.growth_store:entry(road_id..':s2:r1').state == 'uncertain')
    h.build_script = nil
    local id, err = h.growth:extend(road_id, 'alice'); assert(not id and err.code == 'not_extendable')
    h.run()
    assert(h.builds == 1, 'no replay after restart')
    -- The reservation still blocks incoming outward origins, and is visible to the obstacle index.
    assert(h.outward:eligibility(SID, EAST) == 'reserved')
    assert(#assert(h.growth_store:collect({x1 = 60, z1 = -4, x2 = 70, z2 = 4})) >= 1)
end)

------------------------------------------------------------------ service methods
test('status, retire and retry are bounded and conservative', function()
    local h = harness()
    local road_id = h.adopted()
    h.survey_error = {code = 'survey_failed', reason = 'scripted survey failure'}
    assert(h.run_cycle(road_id))
    assert(h.road(road_id).state == 'stopped' and h.road(road_id).stop.code == 'survey_failed')
    for _ = 1, 5 do
        assert(h.growth:retry(road_id, 'admin'))
        h.run_until(function() return h.growth.active == nil end)
        assert(h.road(road_id).state == 'stopped' and h.road(road_id).stop.code == 'survey_failed')
    end
    local status = h.growth:status(road_id)
    assert(#status.attempts == 4 and status.next_seq == 2 + 6 and status.state == 'stopped')
    assert(status.attempts[4].targets[1].reason == 'scripted survey failure' and #status.attempts[4].targets == 2)
    assert(h.growth:status().counts.roads == 1 and #h.growth:status().roads == 1)
    local _, err = h.growth:status('missing'); assert(err.code == 'unknown_road')
    h.survey_error = nil
    -- Retire retains everything and refuses further work; it is idempotent.
    assert(h.growth:retire(road_id, 'admin') and h.growth:retire(road_id, 'admin'))
    status = h.growth:status(road_id)
    assert(status.state == 'retired' and status.retired.was == 'stopped' and status.explanation)
    assert(h.growth_store:entry(h.road(road_id).segments[1]))
    local id
    id, err = h.growth:extend(road_id, 'admin'); assert(not id and err.code == 'not_extendable')
    id, err = h.growth:retry(road_id, 'admin'); assert(not id and err.code == 'not_retryable')
    -- A busy road cannot be retired, an open road can.
    h = harness()
    road_id = h.adopted()
    assert(h.growth:extend(road_id, 'admin'))
    _, err = h.growth:retire(road_id, 'admin'); assert(err.code == 'busy')
    _, err = h.growth:retry(road_id, 'admin'); assert(err.code == 'not_retryable')
    h.run()
    assert(h.growth:retire(road_id, 'admin') and h.road(road_id).revision == 2)
    -- Retire an uncertain road: reservations stay.
    h = harness()
    road_id = h.adopted()
    h.build_script = function() return {cancel = function() end} end
    assert(h.growth:extend(road_id, 'admin')); h.run_until(function() return h.builds == 1 end)
    h.restart()
    assert(h.growth:retire(road_id, 'admin'))
    assert(h.road(road_id).retired.was == 'uncertain' and h.growth_store:entry(road_id..':s2:r1').state == 'uncertain')
    -- Retry refuses an edited seam and does not clear the stop.
    h = harness()
    road_id = h.adopted()
    h.survey_error = {code = 'survey_failed', reason = 'x'}
    h.run_cycle(road_id)
    h.set(48, 0, 0, {name = 'mcl_core:dirt', param2 = 0})
    id, err = h.growth:retry(road_id, 'admin')
    assert(not id and err.code == 'seam_changed' and h.road(road_id).state == 'stopped')
end)

test('inspect compares the intended seam with the world without changing anything', function()
    local h = harness()
    local road_id = h.adopted()
    local report = h.growth:inspect(road_id, 'admin')
    assert(report.world.status == 'matches_intended' and report.world.comparison.checked > 0 and report.index_entries == 1)
    h.set(48, 2, 0, {name = 'mcl_core:stone', param2 = 0})
    h.meta['48:0:0'] = true
    report = h.growth:inspect(road_id, 'admin')
    assert(report.world.status == 'mismatch' and report.world.comparison.mismatched == 2)
    assert(#report.world.comparison.samples <= 16)
    assert(h.nodes['48:2:0'].name == 'mcl_core:stone', 'nothing was repaired')
    assert(h.road(road_id).state == 'open')
    local _, err = h.growth:inspect('missing', 'admin'); assert(err.code == 'unknown_road')
end)

test('a zero-write release whose save fails keeps the segment record readable and an obstacle after restart', function()
    local h = harness()
    local road_id = h.adopted()
    h.build_script = function(plan, done)
        h.after(0, function()
            h.storage.fail_set = function(k) return k:find('registry$') ~= nil end
            done({code = 'stale_plan', reason = 'scripted'}, {writes = 0})
        end)
        return {cancel = function() end}
    end
    assert(h.growth:extend(road_id, 'admin'))
    h.run_until(function() return h.growth.active == nil end)
    local sid = road_id..':s2:r1'
    assert(h.road(road_id).state == 'stopped', 'memory shows the known outcome')
    assert(h.growth_store:load_record(sid), 'the record is kept while the stored registry may still reserve it')
    h.storage.fail_set = nil
    h.restart()
    assert(h.road(road_id).state == 'uncertain' and h.growth_store:entry(sid).state == 'uncertain')
    assert(h.growth_store:load_record(sid))
    local ids = assert(h.growth_store:collect({x1 = 100, z1 = -2, x2 = 110, z2 = 2}))
    local found = false
    for _, id in ipairs(ids) do if id == sid then found = true end end
    assert(found, 'the uncertain entry is still an obstacle')
    -- A new road near it can still run a cycle's obstacle query without segment_missing.
    local mask, err = h.growth_store:load_record(sid)
    assert(mask and not err)

    -- hooks.void with a failing save keeps the seed record; recover voids it later.
    h = harness()
    h.build_script = function() return nil, {code = 'build_failed', reason = 'scripted startup refusal'} end
    h.storage.fail_set = function(k, v) return k:find('registry$') ~= nil and v:find('intended') == nil end
    local status = assert(h.build_outward())
    assert(status.state == 'failed')
    local seed_id = 'growth:v1:'..status.op_id..':s1'
    assert(h.growth_store:load_record(seed_id), 'seed record kept after failed release save')
    h.storage.fail_set = nil
    h.restart()
    assert(h.growth_store:entry(seed_id) == nil, 'recover re-voids the seed')
end)

test('growth failures never break the outward road and dependencies are required', function()
    local h = harness()
    h.growth.hooks.prepare = function() error('boom') end
    local status = h.seeded_road()
    assert(h.outward:operation(status.op_id).growth.state == 'unseeded')
    h = harness()
    h.growth.hooks.verify = function() error('boom') end
    status = h.seeded_road()
    assert(h.outward:operation(status.op_id).growth.state == 'unverified')
    local service, err = growth.new({})
    assert(not service and err.code == 'invalid_config')
end)

print('ok - '..count..' growth lifecycle tests')
