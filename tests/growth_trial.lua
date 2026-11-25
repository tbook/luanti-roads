-- SPDX-License-Identifier: GPL-3.0-or-later
-- Dry run of the engine trial's logic (tools/growth_trial) with the real surface
-- inspector, planner, builder, growth service and commands over the shared
-- simulated world: consecutive bends from a seeded road, a seam edit that is
-- refused without repair, and restart of an interrupted planning or build.
-- The engine, mod storage durability and shutdown timing are NOT exercised.
local surface = dofile('src/surface.lua')
local build = dofile('src/build.lua')
build.set_seam_dependencies(dofile('src/seam.lua'), dofile('src/raster.lua'))
local commands = dofile('src/commands.lua')
local layout = dofile('tools/growth_trial/layout.lua')
local fixture = dofile('tests/growth_fixture.lua')
local count = 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if not ok then error('growth trial '..name..': '..tostring(err)) end
    count = count + 1
end

local function trial_world()
    local h = fixture.harness()
    local road_id = h.adopted()
    local origin = h.road(road_id).endpoint.x
    layout.each_wall_node(origin, function(x, y, z, name) h.set(x, y, z, {name = name, param2 = 0}) end)
    local access = {get_node = h.access.get_node, has_metadata = h.access.has_metadata,
        is_protected = h.access.is_protected, get_natural_light = function() return 15 end}
    function h.start_survey(a, b, owner)
        h.surveys = h.surveys + 1
        local r = {min_x = math.min(a.x, b.x) - 32, max_x = math.max(a.x, b.x) + 32, min_y = -32, max_y = 31,
            min_z = math.min(a.z, b.z) - 32, max_z = math.max(a.z, b.z) + 32}
        local terrain = assert(surface.inspect(r, owner, access))
        local job = {}
        function job:status() return {status = 'succeeded', terrain = terrain, metrics = {}} end
        function job:cancel() end
        return job
    end
    h.restart() -- rewire the services onto the shaped survey
    return h, road_id, origin
end
local function node(h, p) return h.nodes[p.x..':'..p.y..':'..p.z] or h.access.get_node(p) end
local function last_record(h, road_id) return assert(h.growth_store:load_record(h.road(road_id).last_segment_id)) end

test('four consecutive cycles from a fresh seeded road each bend round a wall and keep the seam', function()
    local h, road_id, origin = trial_world()
    local previous = h.road(road_id).endpoint
    for cycle = 1, 4 do
        assert(h.run_cycle(road_id), 'cycle '..cycle)
        local road = h.road(road_id)
        assert(road.state == 'open' and road.revision == cycle + 1, road.state..' '..road.revision)
        assert(road.endpoint.x == origin + 96 * cycle and road.endpoint.z == 0, road.endpoint.x..','..road.endpoint.z)
        local record = last_record(h, road_id)
        assert(record.centerline[1].x == previous.x and record.centerline[1].z == previous.z, 'starts at the seam')
        assert(layout.bends(record.centerline) >= 2, 'cycle '..cycle..' bends '..layout.bends(record.centerline))
        local far = 0
        for _, p in ipairs(record.centerline) do far = math.max(far, math.abs(p.z)) end
        assert(far >= 4, 'cycle '..cycle..' never left the straight line')
        previous = road.endpoint
    end
end)

test('the seam-edit node is inside the preserved patch; an edit is refused with seam_changed and nothing is repaired', function()
    local h, road_id = trial_world()
    assert(h.run_cycle(road_id))
    local road = h.road(road_id)
    local patch = last_record(h, road_id).next_seam
    local edit = assert(layout.seam_edit_node(patch.preserved, road.endpoint), 'endpoint surface is not preserved')
    assert(edit.name == fixture.COBBLE)
    assert(node(h, edit).name == fixture.COBBLE)
    h.set(edit.x, edit.y, edit.z, {name = 'mcl_core:dirt', param2 = 0})
    local builds, writes, surveys, revision = h.builds, h.writes, h.surveys, road.revision
    local id, err = h.growth:extend(road_id, 'admin')
    assert(id == nil and err.code == 'seam_changed', tostring(err and err.code))
    local report = assert(h.growth:inspect(road_id, 'admin'))
    assert(report.world.status == 'mismatch', report.world.status)
    assert(node(h, edit).name == 'mcl_core:dirt', 'the edit was repaired')
    assert(h.builds == builds and h.writes == writes and h.surveys == surveys and h.growth.active == nil)
    assert(h.road(road_id).state == 'open' and h.road(road_id).revision == revision and h.road(road_id).pending == nil)
    h.set(edit.x, edit.y, edit.z, {name = fixture.COBBLE, param2 = 0})
    assert(h.run_cycle(road_id) and h.road(road_id).revision == revision + 1, 'extension resumes once the seam matches')
end)

test('restart during planning stops with zero writes; a seam edit still blocks retry; retry then bends on', function()
    local h, road_id, origin = trial_world()
    for _ = 1, 3 do assert(h.run_cycle(road_id)) end
    local road = h.road(road_id)
    assert(road.endpoint.x == origin + 288)
    local ahead = {x = road.endpoint.x + 4, y = 0, z = 0}
    local before = node(h, ahead).name
    assert(h.growth:extend(road_id, 'admin'))
    h.run_until(function() return h.growth.active and h.growth.active.stage == 'surveying' end)
    local writes = h.writes
    h.restart()
    road = h.road(road_id)
    assert(road.state == 'stopped' and road.stop.code == 'interrupted' and road.pending == nil and road.revision == 4)
    h.run()
    assert(h.writes == writes and h.builds == 3 and h.growth.active == nil and node(h, ahead).name == before, 'nothing is replayed')
    local edit = assert(layout.seam_edit_node(last_record(h, road_id).next_seam.preserved, road.endpoint))
    h.set(edit.x, edit.y, edit.z, {name = 'mcl_core:dirt', param2 = 0})
    local id, err = h.growth:retry(road_id, 'admin')
    assert(id == nil and err.code == 'seam_changed' and h.road(road_id).state == 'stopped')
    h.set(edit.x, edit.y, edit.z, {name = fixture.COBBLE, param2 = 0})
    assert(h.growth:retry(road_id, 'admin'))
    h.run_until(function() return h.growth.active == nil end)
    road = h.road(road_id)
    assert(road.state == 'open' and road.revision == 5 and road.endpoint.x == origin + 384, road.state..' '..road.revision)
    assert(layout.bends(last_record(h, road_id).centerline) >= 2)
end)

test('restart after construction began but before the result was saved is uncertain, reserved and never replayed', function()
    local h, road_id = trial_world()
    for _ = 1, 3 do assert(h.run_cycle(road_id)) end
    -- The builder writes, but its completion is swallowed: the shape of a stop right after the writes.
    h.build_script = function(plan, _, guard)
        return build.new(plan, {now = function() return h.time end, guard = guard, after = h.after, load = function() end,
            access = h.access, classify = surface.classify, has_timer = function() return false end,
            write = function(p, n) h.writes = h.writes + 1; h.set(p.x, p.y, p.z, {name = n.name, param2 = n.param2 or 0}) end},
            function() end)
    end
    local revision = h.road(road_id).revision
    assert(h.growth:extend(road_id, 'admin'))
    h.run_until(function() return h.builds == 4 end)
    h.run()
    assert(h.road(road_id).state == 'building', h.road(road_id).state)
    h.restart()
    local road = h.road(road_id)
    assert(road.state == 'uncertain' and road.pending.state == 'uncertain' and road.revision == revision)
    assert(h.growth_store:claim('endpoint:'..road_id..':'..revision).state == 'uncertain')
    h.build_script = nil
    local builds, writes = h.builds, h.writes
    local id, err = h.growth:extend(road_id, 'admin'); assert(id == nil and err.code == 'not_extendable')
    id, err = h.growth:retry(road_id, 'admin'); assert(id == nil and err.code == 'not_retryable')
    h.run()
    assert(h.builds == builds and h.writes == writes and h.road(road_id).state == 'uncertain', 'nothing is replayed')
    assert(h.growth:inspect(road_id, 'admin').world.status ~= nil)
    local text = commands.growth_summary(assert(h.growth:status(road_id)))
    assert(text:find('Stop: interrupted', 1, true) and text:find('uncertain', 1, true), text)
end)

test('the trial towns steer, are rejected for a bad heading, and finally take a walkable arrival at the graded width-4 exit', function()
    local fx = dofile('tests/towns_destinations_fixture.lua')
    local w = fx.setup()
    local h = w.h
    local road_id = w.adopt()
    local origin = h.road(road_id).endpoint.x
    local towns = layout.towns(origin)
    local steer, away = towns.steer, towns.away
    for _, town in pairs(towns) do
        layout.each_exit_node(town.exits[1], function(x, y, z, name, param2) h.set(x, y, z, {name = name, param2 = param2}) end)
        w.fake.records[town.id] = town
    end
    local function show(list)
        w.fake.others, w.fake.items = {}, {}
        for _, town in ipairs(list) do w.fake.others[#w.fake.others + 1] = town; w.fake.exclude_settlement(town) end
    end
    local function status() return assert(h.growth:status(road_id)) end
    show({steer})
    assert(h.run_cycle(road_id))
    local a = h.road(road_id).attempts[1]
    assert(a.result == 'partial_progress' and a.candidates[1].mode == 'waypoint' and a.candidates[1].distance == 400
        and h.growth_store:claim('exit:'..steer.id..'/'..steer.exits[1].id) == nil)
    show({away})
    assert(h.run_cycle(road_id))
    a = h.road(road_id).attempts[2]
    assert(a.result == 'directional' and a.targets[1].outcome == 'incompatible_heading' and a.targets[2].length == 96)
    show({})
    assert(h.run_cycle(road_id))
    assert(h.road(road_id).attempts[3].result == 'directional' and #h.road(road_id).attempts[3].candidates == 0)
    local seam_x = status().endpoint.x
    assert(seam_x == origin + 288)
    show({steer})
    assert(h.run_cycle(road_id))
    local road = h.road(road_id)
    assert(road.state == 'connected' and road.connected.approach_id == steer.exits[1].id, tostring(road.stop and road.stop.reason))
    local reached = fx.walk(h, seam_x, 0, {x1 = seam_x - 4, x2 = origin + 402, z1 = -20, z2 = 20})
    for _, c in ipairs(steer.exits[1].columns) do assert(reached[c.x..':'..c.z], 'the exit column '..c.x..':'..c.z) end
    local final = assert(h.growth_store:load_record(road.last_segment_id)).headings
    assert(({[7] = true, [0] = true, [1] = true})[final[#final]])
    assert(select(2, h.outward:start({settlement_id = steer.id, exit_id = steer.exits[1].id, requester = 'x', policy = {version = 1, seed = 1},
        candidates = {{x = origin + 450, z = 0}}})).code == 'already_reserved')
end)

print('ok - '..count..' growth trial dry-run tests')
