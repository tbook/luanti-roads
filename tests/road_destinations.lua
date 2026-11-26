-- SPDX-License-Identifier: GPL-3.0-or-later
-- Existing-road destinations (#52): the road provider over registered growth
-- segments, T junctions onto flat straight runs, end-to-end joins, offset
-- lattices, exact preservation of the target road, join-interval claims, source
-- loops and crossings, incompatible grades and bends, competing roads,
-- storage/restart uncertainty and player edits. The real provider, resolver,
-- connector geometry, planner, composer, builder, outward and growth services run
-- over the simulated world of tests/growth_fixture.lua; only surveying, the job
-- slot and the clock are scripted. See tests/road_destinations_fixture.lua.
local fx = dofile('tests/road_destinations_fixture.lua')
local commands = dofile('src/commands.lua')
local build = dofile('src/build.lua')
local growth_store = dofile('src/growth_store.lua')
local outward_fx = dofile('tests/outward_fixture.lua')
local seam = dofile('src/seam.lua')
build.set_seam_dependencies(seam, fx.raster)
local surface = fx.surface
local destinations = fx.destinations

local count = 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if not ok then error('road destinations '..name..': '..tostring(err)) end
    count = count + 1
end

local function node(h, x, y, z) return h.access.get_node({x = x, y = y, z = z}) end
-- Names and param2 of every node of a box, to prove that nothing in it changed.
local function snapshot(h, x1, x2, z1, z2, y1, y2)
    local map = {}
    for x = x1, x2 do for z = z1, z2 do for y = y1 or -4, y2 or 5 do
        local n = node(h, x, y, z); map[x..':'..y..':'..z] = n.name..'/'..n.param2
    end end end
    return map
end
local function same(a, b)
    for k, v in pairs(a) do if b[k] ~= v then return false, k end end
    return true
end
local A_BOX = {7, 49, -1, 1}   -- the footprint of the standard target road (x 8..48 on z = 0)
local function a_snapshot(h) return snapshot(h, A_BOX[1], A_BOX[2], A_BOX[3], A_BOX[4]) end
local function last_attempt(h, road_id) local r = h.road(road_id); return r.attempts[#r.attempts], r end
local function claim_ids(h, road_id)
    local list = h.growth_store:claims_of(road_id, 64)
    local ids = {}
    for _, c in ipairs(list) do ids[#ids + 1] = c.id..'='..c.state end
    return ids
end
local function stage_of(h) return h.growth.active and h.growth.active.stage end
local function in_a(p) return p.x >= A_BOX[1] and p.x <= A_BOX[2] and p.z >= A_BOX[3] and p.z <= A_BOX[4] end
local function writes_in_a(w)
    for _, p in ipairs(w.writes) do if in_a(p) then return p end end
end
local function reach(h, x, z, box) return fx.walk(h, x, z, box or {x1 = -10, x2 = 150, z1 = -80, z2 = 20}) end
local function commands_for(h)
    local registered = {}
    local engine = {register_chatcommand = function(name, def) registered[name] = def end,
        get_player_by_name = function() return nil end}
    assert(commands.register(engine, h.jobs, surface, function() return {} end, nil, nil, {service = h.growth}))
    return registered
end
local EAST_END = {sid = 'auto:5:5', exit_id = '-x:0:0', anchor = {x = 112, y = 0, z = 0}, direction = {x = -1, z = 0}, target = {x = 80, z = 0}}

------------------------------------------------------------ pure geometry
test('only straight flat cardinal runs of a record are approaches; slopes, bends and diagonals split them', function()
    local function record(points, headings) return {centerline = points, headings = headings} end
    local flat = {}
    for i = 0, 10 do flat[#flat + 1] = {x = 8 + 4 * i, y = 0, z = 0} end
    local runs = destinations.runs(record(flat, {0, 0, 0, 0, 0, 0, 0, 0, 0, 0}))
    assert(#runs == 1 and runs[1].lo == 8 and runs[1].hi == 48 and runs[1].axis == 'x' and runs[1].line == 0 and runs[1].y == 0)
    -- A one-node rise splits the run: the sloped edge belongs to neither.
    local sloped = {}
    for i = 0, 10 do sloped[#sloped + 1] = {x = 8 + 4 * i, y = i >= 5 and 1 or 0, z = 0} end
    runs = destinations.runs(record(sloped, {0, 0, 0, 0, 0, 0, 0, 0, 0, 0}))
    assert(#runs == 2 and runs[1].hi == 24 and runs[2].lo == 28 and runs[1].last == 4 and runs[2].first == 6, #runs)
    -- A diagonal bend ends a run; the diagonal edge is no run at all.
    local bent = {{x = 0, y = 0, z = 0}, {x = 4, y = 0, z = 0}, {x = 8, y = 0, z = 0}, {x = 12, y = 0, z = 4}, {x = 16, y = 0, z = 8},
        {x = 16, y = 0, z = 12}, {x = 16, y = 0, z = 16}}
    runs = destinations.runs(record(bent, {0, 0, 1, 1, 2, 2}))
    assert(#runs == 2 and runs[1].hi == 8 and runs[2].axis == 'z' and runs[2].line == 16 and runs[2].lo == 8 and runs[2].hi == 16)
    -- A turn between two cardinal runs of different headings starts a new run.
    runs = destinations.runs(record({{x = 0, y = 0, z = 0}, {x = 4, y = 0, z = 0}, {x = 4, y = 0, z = 4}}, {0, 2}))
    assert(#runs == 2)
    -- Malformed records offer nothing.
    assert(#destinations.runs({centerline = {{x = 0, y = 0, z = 0}}, headings = {}}) == 0)
    assert(#destinations.runs({}) == 0)
end)

test('the store lists segments near a position nearest first, at most 100 cells and 1,024 references, truncation reported', function()
    local storage = outward_fx.storage()
    local store = growth_store.new({storage = storage, serialize = outward_fx.serialize, deserialize = outward_fx.deserialize,
        now = function() return 1 end})
    local function entry(cells, x1, z1, x2, z2)
        return {kind = 'segment', state = 'built', writes = 'all', cells = cells, road_id = 'r',
            bounds = {x1 = x1, z1 = z1, x2 = x2, z2 = z2}, bytes = 1}
    end
    assert(store:update(function(d)
        d.segs.near = entry({'0:0'}, 0, 0, 10, 10); d.segs.far = entry({'3:0'}, 400, 0, 410, 10)
        d.segs.out = entry({'8:0'}, 1100, 0, 1110, 10)
        d.roads.r = {origin_op_id = 'op', source = {settlement_id = 's', exit_id = 'e'}, preferred = {x = 1, z = 0}, revision = 1,
            endpoint = {x = 0, y = 0, z = 0}, local_heading = 0, last_segment_id = 'near', segments = {'near', 'far', 'out'},
            state = 'open', next_seq = 2, activation = 'needs_departure', attempts = {}}
        return true
    end))
    local ids, info = assert(store:nearby({x = 20, z = 0}, 512))
    assert(table.concat(ids, ',') == 'near,far' and not info.truncated and info.cells <= 100, table.concat(ids, ','))
    ids = assert(store:nearby({x = 20, z = 0}, 100))
    assert(table.concat(ids, ',') == 'near')
    local _, err = store:nearby({x = 0, z = 0}, 5000)
    assert(err.code == 'invalid_request')
end)

test('provider caps: dense cells truncate discovery (obstacle lookup still fails closed)', function()
    local storage = outward_fx.storage()
    local store = growth_store.new({storage = storage, serialize = outward_fx.serialize, deserialize = outward_fx.deserialize,
        now = function() return 1 end})
    local function entry(x)
        return {kind = 'segment', state = 'built', writes = 'all', cells = {'0:0'}, road_id = 'r',
            bounds = {x1 = x, z1 = 0, x2 = x + 1, z2 = 1}, bytes = 1}
    end
    assert(store:update(function(d)
        for i = 1, 600 do d.segs['a'..i] = entry(i % 100) end
        d.roads.r = {origin_op_id = 'op', source = {settlement_id = 's', exit_id = 'e'}, preferred = {x = 1, z = 0}, revision = 1,
            endpoint = {x = 0, y = 0, z = 0}, local_heading = 0, last_segment_id = 'a1', segments = {'a1'},
            state = 'open', next_seq = 2, activation = 'needs_departure', attempts = {}}
        return true
    end))
    local ids, info = assert(store:nearby({x = 0, z = 0}, 100))
    assert(#ids == 600 and not info.truncated)
    assert(store:update(function(d)
        for i = 1, 600 do d.segs['a'..i].cells = {'0:0', '-1:0'} end
        return true
    end))
    ids, info = assert(store:nearby({x = 0, z = 0}, 100))
    assert(info.truncated and info.references == 1024 and #ids <= 1024, 'discovery truncates at the reference cap')
    local _, err = store:collect({x1 = -50, z1 = 0, x2 = 50, z2 = 50})
    assert(err.code == 'road_index_budget', 'but an obstacle lookup never treats a cut-off list as clear')
end)

------------------------------------------------------------ provider
test('the provider offers T approaches from the side facing the endpoint and the open endpoint of a road', function()
    local w = fx.setup()
    local h = w.h
    local a = w.target()
    local road = w.dest.providers.road
    local south = assert(road:nearby({x = 28, y = 0, z = -20}, 512, 32))
    assert(south.truncation == 'none' and #south.items == 1, #south.items)
    local item = south.items[1]
    assert(item.kind == 'road' and item.id == a and item.version == 1 and item.approach_id:match('#t1:s$'))
    assert(item.direction.x == 0 and item.direction.z == -1 and item.position.x == 28 and item.position.z == 0 and item.position.y == 0)
    -- Clamped into the run's interior: x 11..45.
    local west = assert(road:nearby({x = -30, y = 0, z = -20}, 512, 32))
    assert(west.items[1].position.x == 11)
    local north = assert(road:nearby({x = 28, y = 0, z = 20}, 512, 32))
    assert(north.items[1].direction.z == 1 and north.items[1].approach_id:match('#t1:n$'))
    -- From beyond the endpoint on the line: the end approach only, facing east.
    local beyond = assert(road:nearby({x = 80, y = 0, z = 0}, 512, 32))
    assert(#beyond.items == 1 and beyond.items[1].approach_id:match('#end:e$') and beyond.items[1].position.x == 48
        and beyond.items[1].direction.x == 1)
    -- Beside the road within 7 nodes no approach has room for a landing.
    assert(#assert(road:nearby({x = 28, y = 0, z = -5}, 512, 32)).items == 0)
    -- Different revisions for different approaches; the same approach is stable.
    assert(south.items[1].revision ~= beyond.items[1].revision)
    assert(assert(road:nearby({x = 30, y = 0, z = -40}, 512, 32)).items[1].revision == south.items[1].revision)
    -- Out of radius.
    assert(#assert(road:nearby({x = 28, y = 0, z = -900}, 512, 32)).items == 0)
end)

test('unadopted seeds are never offered as roads', function()
    local w = fx.setup()
    local h = w.h
    local a = w.target()
    local status = w.road({sid = 'auto:7:7', exit_id = '+z:0:0', anchor = {x = 92, y = 0, z = -60}, direction = {x = 0, z = 1},
        target = {x = 100, z = -20}, adopt = false})
    assert(status.state == 'built' and h.growth_store:entry(h.outward:operation(status.op_id).growth.seed_id).road_id == nil)
    local items = assert(w.dest.providers.road:nearby({x = 100, y = 0, z = -40}, 512, 32)).items
    for _, item in ipairs(items) do assert(item.id == a, 'only the registered road is offered') end
end)

test('an uncertain road is not a destination, and an unreadable segment record fails the cycle closed without consuming anything', function()
    local w = fx.setup()
    local h = w.h
    local a = w.target()
    local b = w.incoming(28, -60, -20)
    h.build_script = function() return {cancel = function() end} end
    assert(h.growth:extend(a, 'admin'))
    h.run_until(function() return stage_of(h) == 'building' end)
    h.restart()
    h.build_script = nil
    assert(h.road(a).state == 'uncertain')
    assert(#assert(w.dest.providers.road:nearby({x = 28, y = 0, z = -20}, 512, 32)).items == 0, 'an uncertain road is excluded')
    assert(h.run_cycle(b))
    assert(last_attempt(h, b).result == 'directional' and h.road(b).state ~= 'connected')
    -- A stored segment that cannot be read is an unhealthy provider, never an empty network.
    w = fx.setup()
    h = w.h
    a = w.target()
    b = w.incoming(28, -60, -20)
    local record_key = growth_store.PREFIX..'segment/'..h.road(a).last_segment_id
    local saved = h.storage.data[record_key]
    h.storage.data[record_key] = 'garbage'
    local items, err = w.dest.providers.road:nearby({x = 28, y = 0, z = -20}, 512, 32)
    assert(items == nil and err.code == 'segment_corrupt')
    local surveys, revision = h.surveys, h.road(b).revision
    local id, cerr = h.growth:extend(b, 'admin')
    assert(id == nil and cerr.code == 'provider_unhealthy', tostring(cerr and cerr.code))
    assert(h.road(b).state == 'open' and h.road(b).revision == revision and h.road(b).activation == 'needs_departure')
    assert(h.surveys == surveys and h.builds == 0 and h.jobs.active == nil)
    h.storage.data[record_key] = saved
    assert(h.run_cycle(b) and h.road(b).state == 'connected', 'the cycle works once the record is readable again')
end)

------------------------------------------------------------ T junction
test('a T junction attaches by a real walkable union, preserves every target node and claims its interval', function()
    local w = fx.setup()
    local h = w.h
    local a = w.target()
    local b = w.incoming(28, -60, -20)
    local before = a_snapshot(h)
    assert(not reach(h, 28, -20)['28:0'], 'not connected before the cycle')
    assert(h.run_cycle(b))
    local attempt, road = last_attempt(h, b)
    assert(road.state == 'connected', tostring(road.stop and road.stop.reason)..' '..tostring(attempt.targets[1] and attempt.targets[1].reason))
    assert(attempt.result == 'connected' and attempt.targets[1].kind == 'destination' and attempt.targets[1].mode == 'final')
    assert(road.connected.kind == 'road' and road.connected.id == a and road.connected.junction == 't')
    assert(road.connected.approach_id:match('#t1:s$'))
    -- Exact preservation: the target road is byte for byte what it was, and nothing was written on it.
    assert(same(before, a_snapshot(h)) and writes_in_a(w) == nil)
    -- A walking path from the new road onto the target and out along both of its ends.
    local reached = reach(h, 28, -60)
    assert(reached['28:-20'] and reached['28:-2'] and reached['28:-1'] and reached['28:0'] and reached['28:1'], 'T entry')
    assert(reached['8:0'] and reached['48:0'] and reached['9:1'] and reached['47:-1'], 'both branches of the target')
    -- The 7-node join interval is claimed on the target line and held.
    local claims = claim_ids(h, b)
    local joins = 0
    for _, id in ipairs(claims) do if id:match('^join:x:0:') then joins = joins + 1; assert(id:match('=held$')) end end
    assert(joins == 7 and h.growth_store:claim('join:x:0:25') and h.growth_store:claim('join:x:0:31') and not h.growth_store:claim('join:x:0:32'))
    assert(not h.growth_store:claim('endjoin:'..a), 'a T never claims the target endpoint')
    -- The target is untouched in the registry: it is open and may continue.
    local target = h.road(a)
    assert(target.state == 'open' and target.revision == 1 and target.connected == nil)
    local report = assert(h.growth:inspect(b, 'admin'))
    assert(report.world.status == 'matches_intended' and report.world.attachment.matches and report.world.attachment.checked > 0)
    assert(report.claims_total == 7, report.claims_total)
    -- The incoming road stopped: it neither extends nor retries.
    local id, err = h.growth:extend(b, 'admin')
    assert(not id and err.code == 'not_extendable')
    id, err = h.growth:retry(b, 'admin')
    assert(not id and err.code == 'not_retryable')
end)

test('the target road continues after a T join: its next segment is built beside the junction, never over it', function()
    local w = fx.setup()
    local h = w.h
    local a = w.target()
    local b = w.incoming(28, -60, -20)
    assert(h.run_cycle(b))
    local join_nodes = snapshot(h, 20, 36, -8, -2)
    assert(h.run_cycle(a))
    local target = h.road(a)
    assert(target.state == 'open' and target.revision == 2 and target.endpoint.x == 144, target.state..' '..target.endpoint.x)
    assert(same(join_nodes, snapshot(h, 20, 36, -8, -2)), 'the T junction is untouched by the continuation')
    local reached = reach(h, 28, -60)
    assert(reached['144:0'] and reached['8:0'] and reached['28:-20'], 'the whole network is one walkable component')
    assert(h.growth_store:claim('join:x:0:28').state == 'held')
end)

test('offset lattices: a landing on the incoming road lattice meets the target road in either axis offset, near an end or not', function()
    local cases = {{28, -60, -20}, {29, -61, -21}, {30, -62, -22}, {31, -63, -23}, {33, -63, -23}, {10, -60, -20}, {46, -60, -20}, {44, -62, -22}}
    for _, c in ipairs(cases) do
        local w = fx.setup()
        local h = w.h
        local a = w.target()
        local b = w.incoming(c[1], c[2], c[3])
        local before = a_snapshot(h)
        assert(h.run_cycle(b), 'cycle '..c[1])
        local attempt, road = last_attempt(h, b)
        assert(road.state == 'connected', c[1]..': '..tostring(road.stop and road.stop.reason)..' / '..tostring(attempt.targets[1] and attempt.targets[1].reason))
        assert(same(before, a_snapshot(h)) and writes_in_a(w) == nil, 'target preserved at '..c[1])
        local reached = reach(h, c[1], c[3], {x1 = -10, x2 = 150, z1 = -80, z2 = 20})
        assert(reached['8:0'] and reached['48:0'] and reached[c[1]..':'..c[3]], 'walk at '..c[1])
        -- The landing is on the incoming road's own lattice.
        local record = assert(h.growth_store:load_record(road.last_segment_id))
        local last = record.centerline[#record.centerline]
        assert((last.x - c[1]) % 4 == 0 and (last.z - c[3]) % 4 == 0, 'lattice at '..c[1])
    end
end)

------------------------------------------------------------ end to end
test('an end-to-end join ends both unfinished roads and the target can no longer grow', function()
    local w = fx.setup()
    local h = w.h
    local a = w.target()
    local b = w.road(EAST_END)
    local before = a_snapshot(h)
    assert(h.run_cycle(b))
    local attempt, road = last_attempt(h, b)
    assert(road.state == 'connected', tostring(road.stop and road.stop.reason)..' '..tostring(attempt.targets[1] and attempt.targets[1].reason))
    assert(road.connected.kind == 'road' and road.connected.id == a and road.connected.junction == 'end')
    local target = h.road(a)
    assert(target.state == 'connected' and target.connected.id == b and target.connected.junction == 'end', target.state)
    assert(same(before, a_snapshot(h)) and writes_in_a(w) == nil)
    local reached = reach(h, 120, 0)
    assert(reached['8:0'] and reached['48:0'] and reached['49:0'] and reached['80:0'] and reached['120:0'], 'one continuous walkable road')
    assert(h.growth_store:claim('endjoin:'..a).state == 'held' and h.growth_store:claim('endjoin:'..a).road_id == b)
    local id, err = h.growth:extend(a, 'admin')
    assert(not id and err.code == 'not_extendable' and err.state == 'connected')
    id, err = h.growth:extend(b, 'admin')
    assert(not id and err.code == 'not_extendable')
    local _, text = commands_for(h).roads_grow.func('admin', 'status '..a)
    assert(text:find('connected', 1, true) and text:find('Connected to road '..b..' end to end', 1, true), text)
end)

test('both endpoints face each other: whichever road runs first joins and stops both, the other cannot start', function()
    for _, first in ipairs({'a', 'b'}) do
        local w = fx.setup()
        local h = w.h
        local a = w.target()
        local b = w.road(EAST_END)
        local starter, other = a, b
        if first == 'b' then starter, other = b, a end
        assert(h.run_cycle(starter), first)
        local attempt, road = last_attempt(h, starter)
        assert(road.state == 'connected' and attempt.targets[1].kind == 'destination', first..': '..tostring(road.stop and road.stop.reason))
        assert(h.road(other).state == 'connected' and h.road(other).revision == 1)
        local _, err = h.growth:extend(other, 'admin')
        assert(err and err.code == 'not_extendable')
        assert(reach(h, 120, 0)['8:0'], 'walkable end to end when '..first..' ran first')
    end
end)

test('a T join and a target that continues: only the incoming road stops', function()
    local w = fx.setup()
    local h = w.h
    local a = w.target()
    local b = w.incoming(40, -60, -20)
    assert(h.run_cycle(b))
    assert(h.road(b).state == 'connected' and h.road(a).state == 'open')
    assert(h.run_cycle(a) and h.road(a).revision == 2)
    assert(h.road(a).state == 'open' and h.road(b).state == 'connected')
end)

------------------------------------------------------------ incompatible approaches
local function columns_of(h, record)
    local cols = {}
    for i = 1, #record.centerline - 1 do
        local edge = fx.raster.segment(record.centerline[i], record.centerline[i + 1])
        for _, p in ipairs(edge.columns) do cols[#cols + 1] = p end
    end
    return cols
end
local function touches_a(h, road_id)
    for _, sid in ipairs(h.road(road_id).segments) do
        for _, p in ipairs(columns_of(h, assert(h.growth_store:load_record(sid)))) do
            if in_a(p) then return p end
        end
    end
end

test('a T whose landing is not natural flat ground at the road level is refused and explained; nothing is crossed or rewritten', function()
    local w = fx.setup()
    local h = w.h
    local a = w.target()
    local b = w.incoming(28, -60, -20)
    for x = 0, 60 do for z = -14, -2 do h.set(x, 1, z, {name = fx.fixture.STONE, param2 = 0}) end end
    local before = a_snapshot(h)
    assert(h.run_cycle(b))
    local attempt, road = last_attempt(h, b)
    assert(road.state ~= 'connected' and attempt.result == 'directional', tostring(attempt.result))
    local first = attempt.targets[1]
    assert(first.kind == 'destination' and first.outcome == 'attachment_rejected' and first.reason:find('no T junction fits', 1, true), first.reason)
    assert(same(before, a_snapshot(h)) and writes_in_a(w) == nil and touches_a(h, b) == nil, 'target untouched and not crossed')
    assert(h.growth_store:claim('join:x:0:28') == nil, 'a refused join claims nothing')
    local _, text = commands_for(h).roads_grow.func('admin', 'status '..b)
    assert(text:find('attachment_rejected - no T junction fits', 1, true), text)
end)

test('an endpoint beside the target has no landing room: no approach is offered and growth detours without crossing', function()
    local w = fx.setup()
    local h = w.h
    local a = w.target()
    local b = w.incoming(28, -43, -3)
    local before = a_snapshot(h)
    assert(#assert(w.dest.providers.road:nearby(h.road(b).endpoint, 512, 32)).items == 0)
    assert(h.run_cycle(b))
    local attempt, road = last_attempt(h, b)
    assert(road.state == 'stopped' and #attempt.candidates == 0 and #attempt.targets == 2, road.state)
    assert(road.stop.attempted[1].kind == 'fallback' and road.stop.reason, 'blocked, with every attempt explained')
    assert(attempt.scan.providers.road == 'ok' and attempt.scan.status == 'complete')
    assert(same(before, a_snapshot(h)) and writes_in_a(w) == nil and touches_a(h, b) == nil, 'never crosses or paves over the road')
end)

test('a sloped or bent stored run is not an approach: a sloped target section is skipped and the flat run used', function()
    local w = fx.setup()
    local h = w.h
    local a = w.target()
    local b = w.incoming(28, -60, -20)
    -- Recorded geometry with a one-node rise in the middle (the world nodes stay as built).
    local sid = h.road(a).last_segment_id
    local record = assert(h.growth_store:load_record(sid))
    for i = 6, #record.centerline do record.centerline[i].y = 1 end
    assert(h.growth_store:save_record(record))
    local items = assert(w.dest.providers.road:nearby({x = 28, y = 0, z = -20}, 512, 32)).items
    assert(#items == 2)
    for _, item in ipairs(items) do
        assert(item.position.x <= 21 or item.position.x >= 31, 'no approach on the sloped edge x '..item.position.x)
    end
    assert(items[1].position.y == 1 and items[2].position.y == 0)
    assert(h.run_cycle(b))
    local attempt, road = last_attempt(h, b)
    -- The nearer approach lies on the (recorded) raised run, whose nodes are not there: refused, never repaired.
    assert(attempt.targets[1].outcome == 'attachment_rejected' and attempt.targets[1].reason:find('changed', 1, true), attempt.targets[1].reason)
    assert(road.state == 'connected' and attempt.targets[2].outcome == 'composed', 'the flat run is joined')
    local join = h.growth_store:claim('join:x:0:21')
    assert(join and join.road_id == b, 'joined at the end of the flat run')
end)

------------------------------------------------------------ source loops
test('a road never joins its own segments, even when a provider offers them', function()
    local w = fx.setup()
    local h = w.h
    local a = w.target()
    local b = w.incoming(28, -60, -20)
    local real = w.dest.providers.road
    local resolved = 0
    h.providers.road = {nearby = function(_, pos, radius, limit)
        local result = assert(real:nearby(pos, radius, limit))
        for _, item in ipairs(result.items) do item.id = b end   -- pretend the target is b's own road
        return result
    end}
    h.attachments.road = {resolve = function() resolved = resolved + 1; return nil, {code = 'x', reason = 'unexpected'} end}
    assert(h.run_cycle(b))
    local attempt = last_attempt(h, b)
    assert(resolved == 0 and #attempt.candidates == 0 and h.road(b).state ~= 'connected')
    assert(attempt.rejected[1].kind == 'road' and attempt.rejected[1].reason == 'self')
    -- The resolver itself refuses a road's own segments too.
    local descriptor
    for _, item in ipairs(assert(real:nearby({x = 28, y = 0, z = -20}, 512, 32)).items) do if item.id == a then descriptor = descriptor or item end end
    local res, err = w.dest.attachments.road:resolve(descriptor, {mode = 'final', road_id = a})
    assert(res == nil and err.code == 'destination_unavailable' and err.reason:find('own segment', 1, true), tostring(res)..tostring(err and err.code)..tostring(err and err.reason))
end)

------------------------------------------------------------ competing roads and claims
test('competing roads: an overlapping interval is refused, the second road joins elsewhere, and claims survive a restart', function()
    local w = fx.setup()
    local h = w.h
    local a = w.target()
    local b = w.incoming(28, -60, -20)
    assert(h.run_cycle(b) and h.road(b).state == 'connected')
    h.restart()
    assert(h.growth_store:claim('join:x:0:28').state == 'held' and h.growth_store:claim('join:x:0:28').road_id == b, 'claims persist')
    local before_b = snapshot(h, 26, 30, -8, 1)
    local c = w.incoming(34, -60, -20, 'auto:8:8')
    local before = a_snapshot(h)
    assert(h.run_cycle(c))
    local attempt, road = last_attempt(h, c)
    assert(road.state == 'connected', tostring(road.stop and road.stop.reason)..' '..tostring(attempt.targets[1] and attempt.targets[1].reason))
    local lowest, highest = 1000, -1000
    for _, id in ipairs(claim_ids(h, c)) do
        local u = id:match('^join:x:0:(%-?%d+)=')
        if u then lowest = math.min(lowest, tonumber(u)); highest = math.max(highest, tonumber(u)) end
    end
    assert(lowest >= 32 and highest - lowest == 6, 'the second T is clear of the first interval: '..lowest..'..'..highest)
    assert(same(before_b, snapshot(h, 26, 30, -8, 1)), 'the first road is untouched by the second')
    assert(same(before, a_snapshot(h)) and writes_in_a(w) == nil)
    local reached = reach(h, 34, -60)
    assert(reached['8:0'] and reached['48:0'] and reached['28:-60'], 'both roads join the same walkable network')
    assert(h.growth_store:claim('join:x:0:28').road_id == b)
end)

test('when every position is claimed the T is refused with the reason and growth falls back', function()
    local w = fx.setup()
    local h = w.h
    local a = w.target()
    local b = w.incoming(28, -60, -20)
    assert(h.growth_store:update(function(d)
        for u = 8, 48 do d.claims['join:x:0:'..u] = {kind = 'join', road_id = 'growth:v1:other', segment_id = 'other:s2', state = 'held', side = 'destination'} end
        return true
    end))
    assert(h.run_cycle(b))
    local attempt, road = last_attempt(h, b)
    assert(road.state ~= 'connected' and attempt.targets[1].outcome == 'destination_unavailable', tostring(attempt.targets[1].outcome))
    assert(attempt.targets[1].reason:find('claims the join interval', 1, true), attempt.targets[1].reason)
    assert(writes_in_a(w) == nil)
end)

test('a claim taken after selection stops the cycle with zero writes and keeps the other road claim; retry joins elsewhere', function()
    local w = fx.setup()
    local h = w.h
    local a = w.target()
    local b = w.incoming(28, -60, -20)
    h.on_planner = function()
        h.on_planner = nil
        assert(h.growth_store:update(function(d)
            d.claims['join:x:0:30'] = {kind = 'join', road_id = 'growth:v1:rival', segment_id = 'rival:s2', state = 'held', side = 'destination'}
            return true
        end))
    end
    assert(h.run_cycle(b))
    local road = h.road(b)
    assert(road.state == 'stopped' and road.stop.code == 'claim_conflict', road.state..' '..tostring(road.stop and road.stop.code))
    assert(h.builds == 0 and h.writes == 0 and h.growth_store:claim('join:x:0:30').road_id == 'growth:v1:rival')
    for _, id in ipairs(claim_ids(h, b)) do assert(false, 'zero-write stop releases our own claims: '..id) end
    -- Deliberate retry, no repair: the rival's interval is avoided.
    assert(h.growth:retry(b, 'admin'))
    h.run_until(function() return h.growth.active == nil end)
    assert(h.road(b).state == 'connected')
    assert(not h.growth_store:claim('join:x:0:30').road_id:find('auto:9:9', 1, true))
end)

test('a claim lost during the durability wait stops the cycle before any write', function()
    local w = fx.setup()
    local h = w.h
    local a = w.target()
    local b = w.incoming(28, -60, -20)
    assert(h.growth:extend(b, 'admin'))
    h.run_until(function() return stage_of(h) == 'durability_wait' end)
    assert(h.growth:cancel(b, 'admin') == true)
    assert(h.road(b).state == 'stopped' and h.builds == 0 and #claim_ids(h, b) == 0)
    -- Again, but a third party's claim replaces ours.
    assert(h.growth:retry(b, 'admin'))
    h.run_until(function() return stage_of(h) == 'durability_wait' end)
    assert(h.growth_store:settle(function(d) d.claims['join:x:0:28'].road_id = 'growth:v1:rival'; d.claims['join:x:0:28'].segment_id = 'rival:s2' end) == true)
    h.run_until(function() return h.growth.active == nil end)
    local road = h.road(b)
    assert(road.state == 'stopped' and road.stop.code == 'claim_conflict' and h.builds == 0 and h.writes == 0)
end)

------------------------------------------------------------ player edits
test('an edited target node is never repaired: the join avoids it, and the broken target is honestly not walkable through', function()
    local w = fx.setup()
    local h = w.h
    local a = w.target()
    local b = w.incoming(28, -60, -20)
    h.set(28, 0, 0, {name = 'mcl_core:dirt', param2 = 0})
    assert(h.run_cycle(b))
    local attempt, road = last_attempt(h, b)
    assert(road.state == 'connected', tostring(road.stop and road.stop.reason))
    assert(node(h, 28, 0, 0).name == 'mcl_core:dirt', 'the edit was not repaired')
    local lowest, highest = 1000, -1000
    for _, id in ipairs(claim_ids(h, b)) do
        local u = id:match('^join:x:0:(%-?%d+)=')
        if u then lowest = math.min(lowest, tonumber(u)); highest = math.max(highest, tonumber(u)) end
    end
    local centre = (lowest + highest) / 2
    assert(highest - lowest == 6 and math.abs(centre - 28) >= 2, 'the preserved strip does not contain the edited node: '..centre)
    local reached = reach(h, 28, -60)
    assert(reached['8:0'] and reached['48:0'] and not reached['28:0'], 'the cut node is honestly not walkable and nothing was repaired')
end)

test('a target edited during the durability wait stops the cycle with zero writes; retry avoids the edit without repairing it', function()
    local w = fx.setup()
    local h = w.h
    local a = w.target()
    local b = w.incoming(28, -60, -20)
    assert(h.growth:extend(b, 'admin'))
    h.run_until(function() return stage_of(h) == 'durability_wait' end)
    h.set(28, 0, -1, {name = 'mcl_core:dirt', param2 = 0})
    h.run_until(function() return h.growth.active == nil end)
    local road = h.road(b)
    assert(road.state == 'stopped' and road.stop.code == 'stale_destination' and h.builds == 0 and h.writes == 0, road.state..' '..tostring(road.stop and road.stop.code))
    assert(#claim_ids(h, b) == 0 and node(h, 28, 0, -1).name == 'mcl_core:dirt')
    assert(h.growth:retry(b, 'admin'))
    h.run_until(function() return h.growth.active == nil end)
    assert(h.road(b).state == 'connected' and node(h, 28, 0, -1).name == 'mcl_core:dirt')
end)

test('a junction edited after construction is reported by inspect, never repaired', function()
    local w = fx.setup()
    local h = w.h
    local a = w.target()
    local b = w.incoming(28, -60, -20)
    assert(h.run_cycle(b))
    h.set(28, 0, -1, {name = 'mcl_core:dirt', param2 = 0})
    local report = assert(h.growth:inspect(b, 'admin'))
    assert(report.world.status == 'mismatch' and not report.world.attachment.matches and report.world.attachment.samples[1].x == 28)
    assert(node(h, 28, 0, -1).name == 'mcl_core:dirt')
    local _, text = commands_for(h).roads_grow.func('admin', 'inspect '..b)
    assert(text:find('Attachment: checked', 1, true) and text:find('mismatch', 1, true) and text:find('Claims held by this road', 1, true), text)
    local id, err = h.growth:retry(b, 'admin')
    assert(not id and err.code == 'not_retryable')
end)

------------------------------------------------------------ interruption, restart, storage
local function swallowing_builder(h)
    h.build_script = function(plan, done, guard)
        return build.new(plan, {now = function() return h.time end, guard = guard, after = h.after, load = function() end,
            access = h.access, classify = surface.classify, has_timer = function() return false end,
            write = function(p, n) h.writes = h.writes + 1; h.set(p.x, p.y, p.z, {name = n.name, param2 = n.param2 or 0}) end},
            function() end)
    end
end

test('an interrupted T build is uncertain with its claims kept, inspectable, never replayed; the target and rivals respect it', function()
    for _, mode in ipairs({'swallowed', 'partial'}) do
        local w = fx.setup()
        local h = w.h
        local a = w.target()
        local b = w.incoming(28, -60, -20)
        local seen = 0
        if mode == 'swallowed' then swallowing_builder(h)
        else h.write_hook = function() seen = seen + 1; if seen > 30 then error('the engine stopped') end end end
        assert(h.growth:extend(b, 'admin'))
        h.run_until(function() return h.growth.active == nil or (mode == 'swallowed' and h.writes > 0) end)
        if mode == 'swallowed' then h.step(); h.restart() end
        local road = h.road(b)
        assert(road.state == 'uncertain', mode..': '..road.state)
        assert(h.growth_store:claim('join:x:0:28').state == 'uncertain', 'the join interval stays reserved')
        local report = assert(h.growth:inspect(b, 'admin'))
        assert(report.world.attachment and report.world.attachment.checked > 0)
        if mode == 'swallowed' then assert(report.world.attachment.matches) else assert(report.world.attachment.mismatched > 0) end
        h.write_hook, h.build_script = nil, nil
        local builds, writes = h.builds, h.writes
        h.run()
        assert(h.builds == builds and h.writes == writes, 'never replayed')
        -- The T target may still grow; a rival avoids the uncertain interval; uncertain work is not a target.
        local c = w.incoming(34, -60, -20, 'auto:8:8')
        assert(h.run_cycle(c))
        local lowest = 1000
        for _, id in ipairs(claim_ids(h, c)) do local u = id:match('^join:x:0:(%-?%d+)='); if u then lowest = math.min(lowest, tonumber(u)) end end
        assert(h.road(c).state == 'connected' and lowest >= 32, mode..' rival at '..lowest)
        assert(h.run_cycle(a) and h.road(a).state == 'open' and h.road(a).revision == 2)
        local items = assert(w.dest.providers.road:nearby({x = 28, y = 0, z = -20}, 512, 32)).items
        assert(#items >= 1)
        local text = select(2, commands_for(h).roads_grow.func('admin', 'inspect '..b))
        assert(text:find('Writes may have happened', 1, true) and text:find('Uncertain claims are never released', 1, true), text)
        assert(h.growth:retire(b, 'admin') and h.growth_store:claim('join:x:0:28').state == 'uncertain', 'retire retains every reservation')
    end
end)

test('an interrupted end-to-end join keeps the target endpoint reserved: it can no longer grow', function()
    local w = fx.setup()
    local h = w.h
    local a = w.target()
    local b = w.road(EAST_END)
    swallowing_builder(h)
    assert(h.growth:extend(b, 'admin'))
    h.run_until(function() return h.writes > 0 end)
    h.step(); h.restart()
    assert(h.road(b).state == 'uncertain' and h.road(a).state == 'open')
    assert(h.growth_store:claim('endjoin:'..a).state == 'uncertain')
    local id, err = h.growth:extend(a, 'admin')
    assert(not id and err.code == 'not_extendable' and err.reason:find('claims this endpoint', 1, true), tostring(err and err.reason))
    assert(h.growth:retire(a, 'admin') and h.growth_store:claim('endjoin:'..a))
    assert(h.road(a).state == 'retired')
end)

test('storage failure at the reservation stops with zero writes and no claim; the retry is deliberate', function()
    local w = fx.setup()
    local h = w.h
    local a = w.target()
    local b = w.incoming(28, -60, -20)
    h.storage.fail_set = function(key, value) return key:find('registry$') and value:find('"building"', 1, true) ~= nil end
    assert(h.run_cycle(b))
    local road = h.road(b)
    assert(road.state == 'stopped' and road.stop.code == 'storage_failed' and h.builds == 0 and h.writes == 0)
    assert(#claim_ids(h, b) == 0 and h.growth_store:claim('join:x:0:28') == nil)
    h.storage.fail_set = nil
    assert(h.growth:retry(b, 'admin'))
    h.run_until(function() return h.growth.active == nil end)
    assert(h.road(b).state == 'connected')
end)

test('restart during planning leaves no claim; a dense obstacle index stops before survey and writes', function()
    local w = fx.setup()
    local h = w.h
    local a = w.target()
    local b = w.incoming(28, -60, -20)
    assert(h.growth:extend(b, 'admin'))
    h.run_until(function() return stage_of(h) == 'surveying' end)
    h.restart()
    assert(h.road(b).state == 'stopped' and h.road(b).stop.code == 'interrupted' and #claim_ids(h, b) == 0)
    assert(h.growth_store:update(function(d)
        for i = 1, 300 do
            d.segs['dense'..i] = {kind = 'segment', state = 'built', writes = 'all', cells = {'-1:-1', '0:-1', '-1:0', '0:0'},
                bounds = {x1 = -100, z1 = -100, x2 = 100, z2 = 100}, bytes = 1}
        end
        return true
    end))
    local surveys = h.surveys
    h.growth:retry(b, 'admin')
    h.run_until(function() return h.growth.active == nil end)
    local road = h.road(b)
    assert(road.state == 'stopped' and road.stop.code == 'road_index_budget' and h.surveys == surveys and h.builds == 0 and h.writes == 0, road.stop.code)
end)

test('the provider reads at most 32 segment records and 32 roads per query and reports truncation', function()
    local w = fx.setup()
    local h = w.h
    local a = w.target()
    local template = assert(h.growth_store:load_record(h.road(a).last_segment_id))
    local road_template = h.road(a)
    for i = 1, 40 do
        local record = {}
        for k, v in pairs(template) do record[k] = v end
        record.id = 'clone'..i..':s1'; record.road_id = 'growth:v1:clone'..i
        local bytes = assert(h.growth_store:save_record(record))
        assert(h.growth_store:update(function(d)
            d.segs[record.id] = {kind = 'segment', state = 'built', writes = 'all', road_id = record.road_id, cells = {'0:0'},
                bounds = {x1 = 7, z1 = -1, x2 = 49, z2 = 1}, bytes = bytes}
            local road = {}
            for k, v in pairs(road_template) do road[k] = v end
            road.segments = {record.id}; road.last_segment_id = record.id; road.origin_op_id = 'clone'..i
            d.roads[record.road_id] = road
            return true
        end))
    end
    local loads, load = 0, h.growth_store.load_record
    h.growth_store.load_record = function(self, id) loads = loads + 1; return load(self, id) end
    local result = assert(w.dest.providers.road:nearby({x = 28, y = 0, z = -20}, 512, 32))
    h.growth_store.load_record = load
    assert(loads <= 32 and result.truncation == 'truncated', loads)
    local roads = {}
    for _, item in ipairs(result.items) do roads[item.id] = true end
    local n = 0; for _ in pairs(roads) do n = n + 1 end
    assert(n <= 32 and #result.items <= 256)
    local few = assert(w.dest.providers.road:nearby({x = 28, y = 0, z = -20}, 512, 3))
    local m = 0; roads = {}
    for _, item in ipairs(few.items) do if not roads[item.id] then roads[item.id] = true; m = m + 1 end end
    assert(m == 3 and few.truncation == 'truncated')
end)

test('a distant road steers by revision-checked waypoint without claims, then attaches once it is in range', function()
    local w = fx.setup()
    local h = w.h
    local a = w.target()
    local b = w.incoming(28, -340, -300)
    local before = a_snapshot(h)
    assert(h.run_cycle(b))
    local attempt, road = last_attempt(h, b)
    assert(attempt.result == 'partial_progress' and attempt.candidates[1].mode == 'waypoint' and road.state == 'open', tostring(attempt.result))
    assert(road.connected == nil and #claim_ids(h, b) == 0 and h.growth_store:claim('join:x:0:28') == nil)
    assert(h.run_cycle(b))
    attempt, road = last_attempt(h, b)
    assert(attempt.result == 'partial_progress' and road.state == 'open' and road.endpoint.z == -108, road.endpoint.z)
    assert(h.run_cycle(b))
    attempt, road = last_attempt(h, b)
    assert(attempt.candidates[1].mode == 'final' and road.state == 'connected' and attempt.result == 'connected', tostring(attempt.result))
    assert(same(before, a_snapshot(h)) and writes_in_a(w) == nil)
    assert(reach(h, 28, -340, {x1 = -10, x2 = 150, z1 = -350, z2 = 20})['48:0'])
end)

test('a road junction connector of width 3 exists only for road joins; Towns connectors stay 2 or 4 wide', function()
    local env = {access = {get_node = function() return {name = 'air', param2 = 0} end, has_metadata = function() return false end,
        is_protected = function() return false end}}
    local desc = {api_version = 1, settlement_id = 's', exit_id = 'e', source = 'x', direction = {x = 0, z = -1},
        anchor = {x = 28, y = 0, z = 1}, offsets = {min = -1, max = 1}, length = 3,
        profile = {{y = 0, name = fx.COBBLE, param2 = 0}, {y = 0, name = fx.COBBLE, param2 = 0}, {y = 0, name = fx.COBBLE, param2 = 0}}}
    local terrain = {bounds = {min_x = -100, max_x = 100, min_y = -50, max_y = 50, min_z = -100, max_z = 100}, owner = 'o',
        get_column = function() return nil end}
    local ok, err = fx.connectors.exit_goal(terrain, desc, {x = 28, y = 0, z = -30}, env.access, function() end, surface, fx.edges)
    assert(ok == nil and err.reason == 'invalid published exit descriptor', tostring(err and err.reason))
    desc.kind = 'road'
    ok, err = fx.connectors.exit_goal(terrain, desc, {x = 28, y = 0, z = -30}, env.access, function() end, surface, fx.edges)
    assert(ok == nil and err.reason ~= 'invalid published exit descriptor', 'a road exit passes the shape check')
    -- The connector constraints of a real road join accept width 3 only with the road marker.
    local w = fx.setup()
    local h = w.h
    w.target()
    local b = w.incoming(28, -60, -20)
    local provenance
    h.on_planner = function(_, request) provenance = request.provenance end
    assert(h.run_cycle(b))
    local connector = provenance.goal.connector
    assert(connector.width == 3 and connector.exit.kind == 'road')
    assert(fx.edges.connector_constraints(provenance))
    connector.exit.kind = 'town'
    local constraints = fx.edges.connector_constraints(provenance)
    assert(constraints == nil, 'a width-3 connector is not a Towns connector')
end)

test('a whole selection (query, availability lookup and resolve) reads at most 32 segment records', function()
    local w = fx.setup()
    local h = w.h
    local a = w.target()
    local b = w.incoming(28, -60, -20)
    local template = assert(h.growth_store:load_record(h.road(a).last_segment_id))
    local road_template = h.road(a)
    for i = 1, 60 do
        local record = {}
        for k, v in pairs(template) do record[k] = v end
        record.id = 'clone'..i..':s1'; record.road_id = 'growth:v1:clone'..i
        local bytes = assert(h.growth_store:save_record(record))
        assert(h.growth_store:update(function(d)
            d.segs[record.id] = {kind = 'segment', state = 'built', writes = 'all', road_id = record.road_id, cells = {'0:0'},
                bounds = {x1 = 7, z1 = -1, x2 = 49, z2 = 1}, bytes = bytes}
            local road = {}
            for k, v in pairs(road_template) do road[k] = v end
            road.segments = {record.id}; road.last_segment_id = record.id; road.origin_op_id = 'clone'..i
            d.roads[record.road_id] = road
            return true
        end))
    end
    local loads, load = 0, h.growth_store.load_record
    local unavailable_calls, unavailable = 0, h.unavailable
    h.growth_store.load_record = function(self, id) loads = loads + 1; return load(self, id) end
    h.unavailable = function(d) unavailable_calls = unavailable_calls + 1; return unavailable(d) end
    assert(h.growth:extend(b, 'admin'))
    h.run_until(function() return stage_of(h) == 'surveying' end)
    h.growth_store.load_record = load
    assert(unavailable_calls >= 20, 'the lookup ran for many descriptors: '..unavailable_calls)
    assert(loads >= 28 and loads <= 32, 'record reads over the whole selection: '..loads)
end)

test('the per-cycle claim cap leaves room for a T (7 claims) with no caller claims, and refuses extra ones explicitly', function()
    local w = fx.setup()
    local h = w.h
    local a = w.target()
    local b = w.incoming(28, -60, -20)
    -- One caller claim still fits (7 + 1 = 8)...
    assert(h.growth:extend(b, 'admin', {claims = {{id = 'caller:1', kind = 'test'}}}))
    h.run_until(function() return h.growth.active == nil end)
    assert(h.road(b).state == 'connected' and h.growth_store:claim('caller:1').state == 'held')
    -- ... two do not: the T is refused naming the cap, and growth falls back.
    local w2 = fx.setup()
    local h2 = w2.h
    w2.target()
    local b2 = w2.incoming(28, -60, -20)
    assert(h2.growth:extend(b2, 'admin', {claims = {{id = 'caller:1', kind = 'test'}, {id = 'caller:2', kind = 'test'}}}))
    h2.run_until(function() return h2.growth.active == nil end)
    local attempt, road = last_attempt(h2, b2)
    local first = attempt.targets[1]
    assert(road.state ~= 'connected' and first.kind == 'destination' and first.outcome == 'attachment_rejected', tostring(first.outcome))
    assert(first.reason:find('the cap is 8', 1, true) and first.reason:find('7 claims', 1, true), first.reason)
    assert(h2.growth_store:claim('join:x:0:28') == nil)
end)

test('a landing placed laterally beside the target run at a large lattice offset stays off the target', function()
    for _, c in ipairs({{9, -63, -23}, {47, -61, -21}}) do
        local w = fx.setup()
        local h = w.h
        local a = w.target()
        local b = w.incoming(c[1], c[2], c[3])
        local before = a_snapshot(h)
        assert(h.run_cycle(b))
        local road = h.road(b)
        assert(road.state == 'connected', c[1]..': '..tostring(road.stop and road.stop.reason))
        local lowest, highest = 1000, -1000
        for _, id in ipairs(claim_ids(h, b)) do
            local u = id:match('^join:x:0:(%-?%d+)=')
            if u then lowest = math.min(lowest, tonumber(u)); highest = math.max(highest, tonumber(u)) end
        end
        local centre = (lowest + highest) / 2
        local record = assert(h.growth_store:load_record(road.last_segment_id))
        local landing = record.centerline[#record.centerline]
        assert(math.abs(landing.x - centre) >= 2, 'the landing is shifted sideways by '..(landing.x - centre))
        assert(landing.z <= -3, 'the landing cap (z-1..z+1) clears the target footprint at z -1: '..landing.z)
        assert(touches_a(h, b) == nil and writes_in_a(w) == nil and same(before, a_snapshot(h)))
        assert(reach(h, c[1], c[3])['8:0'] and reach(h, c[1], c[3])['48:0'], 'walkable at '..c[1])
    end
end)

test('a T and an end join on the same line: adjacent non-overlapping intervals both succeed, overlapping ones collide', function()
    -- The T at x 41 claims 38..44; the end join at x 48 claims 45..49: adjacent, not overlapping.
    for _, t_first in ipairs({true, false}) do
        local w = fx.setup()
        local h = w.h
        local a = w.target()
        local t = w.incoming(41, -60, -20)
        local e = w.road(EAST_END)
        local before = a_snapshot(h)
        local order = t_first and {t, e} or {e, t}
        for _, id in ipairs(order) do
            assert(h.run_cycle(id))
            assert(h.road(id).state == 'connected', (t_first and 'T first: ' or 'end first: ')..tostring(h.road(id).stop and h.road(id).stop.reason))
        end
        assert(h.road(h.road(t).connected.id).state == 'connected' and h.road(a).state == 'connected')
        for u = 38, 44 do assert(h.growth_store:claim('join:x:0:'..u).road_id == t, 'T claim '..u) end
        for u = 45, 49 do assert(h.growth_store:claim('join:x:0:'..u).road_id == e, 'end claim '..u) end
        assert(same(before, a_snapshot(h)) and writes_in_a(w) == nil)
        local reached = reach(h, 120, 0)
        assert(reached['8:0'] and reached['48:0'] and reached['41:-60'], 'one walkable network')
    end
    -- Overlapping: a T at x 43 would claim 40..46, which overlaps the end join's 45..49.
    local w = fx.setup()
    local h = w.h
    local a = w.target()
    local e = w.road(EAST_END)
    assert(h.run_cycle(e) and h.road(e).state == 'connected')
    local t = w.incoming(43, -60, -20)
    assert(h.run_cycle(t))
    local road = h.road(t)
    assert(road.state == 'connected', tostring(road.stop and road.stop.reason))
    for u = 45, 49 do assert(h.growth_store:claim('join:x:0:'..u).road_id == e, 'the end claim '..u..' was taken over') end
    for _, id in ipairs(claim_ids(h, t)) do
        local u = id:match('^join:x:0:(%-?%d+)=')
        assert(not u or tonumber(u) <= 44, 'the T moved off the overlap: '..id)
    end
    -- And the other order: the T at x 43 first, then the end join finds its interval taken.
    w = fx.setup(); h = w.h
    a = w.target()
    t = w.incoming(43, -60, -20)
    assert(h.run_cycle(t) and h.road(t).state == 'connected')
    assert(h.growth_store:claim('join:x:0:46').road_id == t)
    e = w.road(EAST_END)
    assert(h.run_cycle(e))
    local attempt, erd = last_attempt(h, e)
    assert(h.road(a).state == 'open' and not (erd.connected and erd.connected.id == a), 'the end join onto A is refused')
    assert(attempt.targets[1].outcome == 'destination_unavailable' and attempt.targets[1].reason:find('claims the join interval', 1, true),
        tostring(attempt.targets[1].outcome)..' '..tostring(attempt.targets[1].reason))
    assert(h.growth_store:claim('endjoin:'..a) == nil)
end)

test('/roads_grow explains a road junction, its claims and a refused join', function()
    local w = fx.setup()
    local h = w.h
    local a = w.target()
    local b = w.incoming(28, -60, -20)
    local cmds = commands_for(h)
    local _, text = cmds.roads_grow.func('admin', 'extend '..b)
    assert(text:find('road=ok', 1, true) and text:find('Selected: road '..a, 1, true) and text:find('final attachment', 1, true), text)
    h.run_until(function() return h.growth.active == nil end)
    _, text = cmds.roads_grow.func('admin', 'status '..b)
    assert(text:find('Connected to road '..a..' by a T junction', 1, true) and text:find('built (connected)', 1, true), text)
    _, text = cmds.roads_grow.func('admin', 'inspect '..b)
    assert(text:find('Claims held by this road: 7 (7 join held)', 1, true), text)
    _, text = cmds.roads_grow.func('admin', 'status '..a)
    assert(text:find('growth:v1', 1, true) and text:find(': open,', 1, true), text)
end)

print("ok - "..count.." road destination tests")
