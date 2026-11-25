-- SPDX-License-Identifier: GPL-3.0-or-later
-- Engine phases of the growth trial. Towns and terrain surveying are scripted;
-- construction, node reads, metadata, protection, timers, map storage and mod
-- storage are the real engine's. The growth steps go through the registered
-- /roads_grow definition.
--
-- Destinations are the real towns_destinations provider and resolver over the real
-- towns_adapter and a scripted towns_api (the Towns mod itself is not loaded): the
-- published exits are really built in the world (layout.towns), so cycle 1 steers by
-- waypoint toward a distant town (partial_progress), cycle 2 meets a town whose exit
-- faces away from the road (rejected before any write; the real 96-node fallback
-- builds), cycle 3 sees no town, and the fourth cycle is a final attachment to the
-- graded width-4 exit, which is the cycle that is cut off. In phase 2 that
-- attachment is retried (planning cut: connected, walked) or inspected (build cut:
-- uncertain, claim kept, geometry compared). The straight trajectory is the same.
--
-- Phase 1 (fresh world): pre-fill a flat stone area with obstacle walls
-- (layout.lua), build a fresh outward road that records a growth seed, adopt it,
-- walk three consecutive continuation cycles that each bend round a wall, edit the
-- seam (extension is refused, nothing is repaired), restore it, then start a
-- fourth cycle that is deliberately cut off (roads_trial_interrupt = planning or
-- build) and shut the server down.
-- Phase 2 (second launch of the SAME world; nothing is rewritten): check what
-- the restart made of the persisted registry, that nothing was replayed, and
-- then exercise the road that the interrupted state allows.
-- Returns function(phase, done, mod_storage); mod_storage must be obtained at
-- mod load time (core.get_mod_storage is not available later).
local root = core.get_modpath('roads_trial')
local function load(n) return dofile(root .. '/src/' .. n .. '.lua') end
local layout = dofile(root .. '/layout.lua')
local surface, raster, edges, planner, plans, builder, seam =
    load('surface'), load('raster'), load('edges'), load('planner'), load('plans'), load('build'), load('seam')
edges.set_raster(raster); planner.set_edges(edges); plans.set_dependencies(raster, edges)
planner.set_seam_dependencies(seam, raster); plans.set_seam_dependency(seam); builder.set_seam_dependencies(seam, raster)
local outward, outward_store, growth, growth_store = load('outward'), load('outward_store'), load('growth'), load('growth_store')
local commands = load('commands')
local growth_policy = load('growth_policy')
local connectors, towns_adapter, towns_destinations = load('connectors'), load('towns_adapter'), load('towns_destinations')
local access = surface.engine_access(core)
local SID, EXIT = 'trial:0:0', '+x:200:0'
local COBBLE, DIRT = 'mcl_core:cobble', 'mcl_core:dirt'
local ORIGIN_X, CYCLE = 248, layout.CYCLE_LENGTH   -- seed endpoint x; nodes per continuation cycle
local TOWNS = layout.towns(ORIGIN_X)
local STEER = TOWNS.steer.exits[1]               -- the exit the road finally attaches to
local STEER_FULL_ID = TOWNS.steer.id .. '/' .. STEER.id
local EXPECT_KEY = 'trial_expect'
local function timer(p) return core.get_node_timer(p):is_started() end
local function copy(v)
    if type(v) ~= 'table' then return v end
    local r = {}; for k, x in pairs(v) do r[k] = copy(x) end; return r
end
local function check(v, e) assert(v, core.serialize(e)); return v end
local function fail(err)
    core.log('error', 'GROWTH_TRIAL_FAIL ' .. tostring(err))
    core.request_shutdown('trial failed', false, 0)
end
-- Errors in core.after callbacks would abort the server without a marker line.
local function guarded(fn)
    return function(...)
        local ok, err = xpcall(fn, debug.traceback, ...)
        if not ok then fail(err) end
    end
end

-- The area must cover every survey window: 4 cycles of 96 nodes plus 32 margin.
local a, b = {x = 160, y = -32, z = -40}, {x = 680, y = 31, z = 70}

local function fill_area()
    local vm = core.get_voxel_manip()
    local emin, emax = vm:read_from_map(a, b)
    local area = VoxelArea:new({MinEdge = emin, MaxEdge = emax}); local data = vm:get_data()
    local stone, air = core.get_content_id('mcl_core:stone'), core.get_content_id('air')
    for z = a.z, b.z do for y = a.y, b.y do for x = a.x, b.x do data[area:index(x, y, z)] = y <= 0 and stone or air end end end
    local wall = core.get_content_id(layout.WALL_NODE)
    layout.each_wall_node(ORIGIN_X, function(x, y, z) data[area:index(x, y, z)] = wall end)
    vm:set_data(data); vm:write_to_map(); vm:update_map()
    -- Really built published exits (real stair and slab nodes with their facedirs).
    for _, town in pairs(TOWNS) do
        layout.each_exit_node(town.exits[1], function(x, y, z, name, param2)
            core.set_node({x = x, y = y, z = z}, {name = name, param2 = param2})
        end)
    end
end

-- Independent walking oracle over the real world: breadth-first search over columns
-- whose top node is a road, stair or slab with three clear nodes above it; a step to a
-- neighbouring column may rise at most one node. Returns the set of reached "x:z" keys.
local function walk_world(sx, sz, box)
    core.load_area({x = box.x1, y = -8, z = box.z1}, {x = box.x2, y = 8, z = box.z2})
    local function standing(x, z)
        for y = 6, -4, -1 do
            local n = core.get_node({x = x, y = y, z = z})
            if n.name ~= 'air' then
                local height = n.name == 'mcl_stairs:slab_cobble' and y
                    or (n.name == 'mcl_core:cobble' or n.name == 'mcl_stairs:stair_cobble') and y + 0.5
                if not height then return nil end
                for dy = 1, 3 do
                    if core.get_node({x = x, y = y + dy, z = z}).name ~= 'air' then return nil end
                end
                return height
            end
        end
    end
    local seen, queue = {}, {{x = sx, z = sz}}
    local first = standing(sx, sz)
    if not first then return seen end
    seen[sx .. ':' .. sz] = first
    local i = 1
    while i <= #queue do
        local p = queue[i]; i = i + 1
        for _, d in ipairs({{1, 0}, {-1, 0}, {0, 1}, {0, -1}}) do
            local x, z = p.x + d[1], p.z + d[2]
            local id = x .. ':' .. z
            if not seen[id] and x >= box.x1 and x <= box.x2 and z >= box.z1 and z <= box.z2 then
                local here = standing(x, z)
                if here and math.abs(here - seen[p.x .. ':' .. p.z]) <= 1 then
                    seen[id] = here; queue[#queue + 1] = {x = x, z = z}
                end
            end
        end
    end
    return seen
end
-- Does the walk from the seam reach every column of the built exit's first row?
local function arrived(from_x)
    local reached = walk_world(from_x, 0, {x1 = from_x - 4, x2 = STEER.columns[1].x + 2, z1 = -20, z2 = 20})
    for _, c in ipairs(STEER.columns) do if not reached[c.x .. ':' .. c.z] then return false end end
    return true
end

-- Logs why a column is or is not known natural ground (diagnostic only).
local function diagnose(x, z)
    local t = surface.inspect({min_x = x, max_x = x, min_y = a.y, max_y = b.y, min_z = z, max_z = z}, 'roads_trial', access)
    local col = t and t.get_column(x, z) or {}
    local odd = {}
    for y = b.y, a.y, -1 do
        local n = core.get_node_or_nil({x = x, y = y, z = z})
        local name = n and n.name or 'nil'
        if name ~= 'air' and name ~= 'mcl_core:stone' then odd[#odd + 1] = y .. '=' .. name end
    end
    core.log('action', 'GROWTH_TRIAL_COLUMN ' .. core.serialize({x = x, z = z, status = col.status, reason = col.reason,
        light = core.get_natural_light({x = x, y = b.y, z = z}, 0.5), odd = odd}))
end

local function services(trap, counters)
    local slot_jobs = {active = nil}
    function slot_jobs:hold(holder)
        if self.active then return nil, {code = 'busy', reason = 'slot busy'} end
        self.active = {holder = holder, external = true}; return self.active
    end
    function slot_jobs:release(t) if self.active == t then self.active = nil end end
    local function now() return core.get_us_time() / 1e6 end
    local function rect(p, q)
        return {min_x = math.min(p.x, q.x) - 32, max_x = math.max(p.x, q.x) + 32, min_y = -32, max_y = 31,
            min_z = math.min(p.z, q.z) - 32, max_z = math.max(p.z, q.z) + 32}
    end
    local survey = {plan = function(p, q)
        local r = rect(p, q)
        return {chunks = {{ix = 0, iy = 0, iz = 0}}, chunk_count = 1, chunk_bounds = r, requested_bounds = r}
    end}
    local function start_survey(p, q, owner)
        counters.surveys = counters.surveys + 1
        local r = rect(p, q)
        check(r.min_x >= a.x and r.max_x <= b.x and r.min_z >= a.z and r.max_z <= b.z, 'trial area too small')
        if trap.survey then
            -- Planning never finishes: the interrupted cycle stays in the surveying stage.
            local job = {}
            function job:status() return {status = 'running'} end
            function job:cancel() end
            trap.fire('planning')
            return job
        end
        -- The scripted survey reads only loaded blocks, and the engine unloads idle ones
        -- (no player is online), so load the surveyed window from the map first.
        check(core.load_area({x = r.min_x, y = r.min_y, z = r.min_z}, {x = r.max_x, y = r.max_y, z = r.max_z}) ~= false,
            'survey window could not be loaded')
        local terrain = check(surface.inspect(r, owner, access))
        local goal_col = terrain.get_column(q.x, q.z)
        core.log('action', 'GROWTH_TRIAL_SURVEY ' .. core.serialize({from = p, to = q, goal_status = goal_col.status, reason = goal_col.reason}))
        if goal_col.status ~= 'ok' then diagnose(q.x, q.z) end
        local job = {state = 'succeeded'}
        function job:status() return {status = self.state, terrain = terrain, metrics = {}} end
        function job:cancel() self.state = 'cancelled' end
        return job
    end
    local function new_planner(terrain, request, config) return planner.new(terrain, request, config) end
    local function compose(terrain, route, config) return plans.compose(terrain, route, config) end
    local function start_build(plan, finished, guard)
        counters.builds = counters.builds + 1
        local callback = finished
        if trap.build then
            -- The real builder writes the segment, but its completion never reaches the
            -- growth service: the shape of a stop right after construction.
            callback = function(err, metrics)
                core.log('action', 'GROWTH_TRIAL_BUILD_SWALLOWED ' .. core.serialize({err = err, writes = metrics and metrics.writes}))
                trap.fire('build')
            end
        end
        return builder.new(plan, {now = now, guard = guard, after = core.after, load = core.load_area,
            access = access, classify = surface.classify, has_timer = timer, write = function(p, n) core.swap_node(p, n) end}, callback)
    end
    local config = {world = {chunksize = 5}, planner = {weights = {slope = 4, turn = 2, cut = 1, fill = 1}, road_material = COBBLE},
        composition = {road_material = COBBLE}}
    -- Scripted towns_api v1: which published settlements exist is a per-cycle choice.
    local visible = {}
    local api = {version = 1}
    local function sorted_visible()
        local list = {}
        for _, town in pairs(TOWNS) do if visible[town.id] then list[#list + 1] = town end end
        table.sort(list, function(p, q) return p.id < q.id end)
        return list
    end
    function api.available() return true end
    function api.settlement(id)
        for _, town in ipairs(sorted_visible()) do if town.id == id then return copy(town) end end
        return nil, 'not_found', 'no such settlement'
    end
    function api.settlements() local list = {}; for _, t in ipairs(sorted_visible()) do list[#list + 1] = copy(t) end; return list end
    function api.exclusions(rect)
        local list = {}
        for _, town in ipairs(sorted_visible()) do
            local rects = {copy(town.core)}
            for _, r in ipairs(town.structures) do rects[#rects + 1] = copy(r) end
            local hit = false
            for _, r in ipairs(rects) do
                if r.x1 <= rect.x2 and r.x2 >= rect.x1 and r.z1 <= rect.z2 and r.z2 >= rect.z1 then hit = true end
            end
            if hit then list[#list + 1] = {id = town.id, kind = 'settlement', state = 'complete', rects = rects, y_min = -10, y_max = 40} end
        end
        return list
    end
    function api.writer() return nil end
    local adapter = towns_adapter.new(function() return api end, now)
    local outward_service_ref
    local dest = towns_destinations.new({towns = adapter, outward = function() return outward_service_ref end,
        connectors = connectors, edges = edges, raster = raster, surface = surface, access = access,
        load = function(minp, maxp) return core.load_area(minp, maxp) end, has_timer = timer, owner = growth.OWNER})
    local descriptor = {api_version = 1, settlement_id = SID, exit_id = EXIT, source = 'trial', direction = {x = 1, z = 0},
        anchor = {x = 200, y = 0, z = 0}, columns = {{x = 200, z = 0}, {x = 200, z = 1}}, length = 3,
        profile = {{y = 0, name = COBBLE, param2 = 0}}, center = {x = 190, y = 0, z = 0}, town_type = 'village'}
    local towns = {}
    function towns:settlement(id) return {id = id} end
    function towns:exit() return copy(descriptor) end
    function towns:writer() return nil end
    function towns:overlay() return {} end
    function towns:recheck() return true end
    function towns:new_guard() return function() return 'ok' end end
    local storage = {get = function(k) local v = trap.mod_storage:get_string(k); if v == '' then return nil end return v end,
        set = function(k, v) trap.mod_storage:set_string(k, v) end, keys = function() return trap.mod_storage:get_keys() end}
    local deserialize = function(t) return core.deserialize(t, true) end
    local gstore = growth_store.new({storage = storage, serialize = core.serialize, deserialize = deserialize, now = os.time})
    local ostore = outward_store.new({storage = storage, serialize = core.serialize, deserialize = deserialize, now = os.time})
    local interval = function() return tonumber(core.settings:get('server_map_save_interval')) or 5.3 end
    local outward_service
    local service = check(growth.new({policy = growth_policy, providers = dest.providers, attachments = dest.attachments,
        destination_unavailable = dest.unavailable, towns = adapter, wrap_terrain = towns_adapter.wrap_terrain,
        store = gstore, jobs = slot_jobs, now = now, after = core.after, raster = raster, seam = seam,
        access = access, has_timer = timer, classify = surface.classify, load_area = core.load_area,
        world_config = function() return config end, survey = survey, start_survey = start_survey, new_planner = new_planner,
        compose = compose, start_build = start_build, save_interval = interval,
        find_operation = function(id) return outward_service:operation(id) end,
        log = function(l, m) core.log(l, m) end}))
    outward_service = check(outward.new({jobs = slot_jobs, towns = towns, store = ostore, now = now, after = core.after,
        world_config = function() return config end, survey = survey, start_survey = start_survey,
        exit_endpoints = function(_, d, target)
            local start = {x = d.anchor.x + 8, y = 0, z = d.anchor.z}
            local goal = {x = target.x, y = 0, z = target.z}
            return {start = {requested = {x = start.x, y = 0.5, z = start.z}, ground = copy(start), resolved = copy(start)},
                goal = {requested = {x = goal.x, y = 0.5, z = goal.z}, ground = copy(goal), resolved = copy(goal)}}
        end,
        new_planner = new_planner, compose = compose, start_build = start_build, wrap_terrain = function(t) return t end,
        save_interval = interval, growth = service.hooks, log = function(l, m) core.log(l, m) end}))
    local command_defs = {}
    assert(commands.register({register_chatcommand = function(name, def) command_defs[name] = def end,
        get_player_by_name = function() return nil end}, slot_jobs, surface, function() return config end,
        nil, nil, {service = service}))
    outward_service_ref = outward_service
    -- Same startup order as init.lua.
    outward_service:recover(); service:recover()
    local function try(text) return command_defs.roads_grow.func('trial', text) end
    local function grow(text)
        local ok, msg = try(text)
        assert(ok, msg)
        return msg
    end
    local function show(towns) visible = {}; for _, t in ipairs(towns) do visible[t.id] = true end end
    return {service = service, outward = outward_service, gstore = gstore, show = show, slot_jobs = slot_jobs, try = try, grow = grow}
end

-- Polls predicate every half second (80 s limit), then calls then_do. Both run guarded.
local function wait(predicate, then_do)
    local started = core.get_us_time() / 1e6
    local poll
    poll = guarded(function()
        if predicate() then return then_do() end
        if core.get_us_time() / 1e6 - started > 80 then error('trial timed out waiting for the service') end
        core.after(0.5, poll)
    end)
    poll()
end

local function node_name(p) return core.get_node(p).name end
local function count_bends(gstore, segment_id)
    local record = check(gstore:load_record(segment_id), 'segment record ' .. tostring(segment_id))
    return layout.bends(record.centerline), record
end

local function phase_one_body(done, mod_storage)
    local mode = core.settings:get('roads_trial_interrupt') or 'planning'
    assert(mode == 'planning' or mode == 'build', 'roads_trial_interrupt must be planning or build')
    local trap = {mod_storage = mod_storage}
    local fired = false
    function trap.fire(kind)
        if fired then return end
        fired = true
        core.log('action', 'GROWTH_TRIAL_INTERRUPT ' .. kind)
        done()   -- logs the phase marker and requests shutdown in this same server step
    end
    local counters = {surveys = 0, builds = 0}
    local s = services(trap, counters)
    local service, gstore, grow, try = s.service, s.gstore, s.grow, s.try

    check(s.outward:start({settlement_id = SID, exit_id = EXIT, requester = 'trial', policy = {version = 1, seed = 1},
        candidates = {{x = 248, z = 0}}}))
    wait(function() return s.outward:status() == nil end, function()
        local status = check(s.outward:status(SID))
        assert(status.state == 'built' and status.writes == 'all', core.serialize(status.error))
        local op = s.outward:operation(status.op_id)
        assert(op.growth and op.growth.state == 'verified', core.serialize(op.growth))
        local road_id = 'growth:v1:' .. status.op_id
        assert(grow('adopt ' .. status.op_id):find('is adopted from outward operation', 1, true))
        assert(grow('adopt ' .. status.op_id):find('Adopting it again changes nothing', 1, true))
        local before = check(service:status(road_id))
        assert(before.endpoint.x == ORIGIN_X and before.revision == 1)

        local walk
        walk = function(cycle)
            if cycle > 3 then return s.finish_walk() end
            -- cycle 1: a distant compatible town (waypoint); cycle 2: a town whose exit
            -- faces away (rejected, real fallback); cycle 3: none in the world's data.
            s.show(cycle == 1 and {TOWNS.steer} or cycle == 2 and {TOWNS.away} or {})
            assert(grow('extend ' .. road_id):find('Growth cycle ' .. road_id .. ':s' .. (cycle + 1) .. ':r' .. cycle .. ' started', 1, true))
            wait(function() return service.active == nil end, function()
                local now_status = check(service:status(road_id))
                local report = grow('status ' .. road_id)
                if cycle == 1 then
                    assert(report:find('built (partial_progress)', 1, true) and report:find('waypoint attachment, 400 nodes away', 1, true)
                        and report:find('destination ' .. STEER.id .. ' (waypoint) composed', 1, true), report)
                    assert(gstore:claim('exit:' .. STEER_FULL_ID) == nil, 'a waypoint claims nothing')
                    core.log('action', 'GROWTH_TRIAL_STEERING ' .. report)
                elseif cycle == 2 then
                    assert(report:find('built (directional)', 1, true)
                        and report:find('destination ' .. TOWNS.away.exits[1].id .. ' (final) incompatible_heading', 1, true)
                        and report:find('96 node fallback composed', 1, true), report)
                    core.log('action', 'GROWTH_TRIAL_FALLBACK ' .. report)
                else
                    assert(report:find('Selected: none', 1, true) and report:find('built (directional)', 1, true), report)
                end
                assert(now_status.state == 'open' and now_status.revision == cycle + 1
                    and now_status.endpoint.x == ORIGIN_X + CYCLE * cycle, core.serialize(now_status))
                assert(node_name(now_status.endpoint) == COBBLE)
                local bends, record = count_bends(gstore, now_status.last_segment_id)
                assert(bends >= 2, 'cycle ' .. cycle .. ' has only ' .. bends .. ' bends')
                local text = grow('status ' .. road_id)
                assert(text:find(('revision %d, endpoint (%.1f, 0.0, 0.0)'):format(cycle + 1, now_status.endpoint.x), 1, true), text)
                assert(grow('inspect ' .. road_id):find('World: matches_intended', 1, true))
                core.log('action', 'GROWTH_TRIAL_BEND ' .. core.serialize({cycle = cycle, bends = bends,
                    points = #record.centerline, endpoint = now_status.endpoint, heading = now_status.local_heading}))
                walk(cycle + 1)
            end)
        end
        function s.finish_walk()
            local road = check(service:status(road_id))
            local _, record = count_bends(gstore, road.last_segment_id)
            -- Edit the seam endpoint, inside the preserved patch: extension is refused, inspect reports it, nothing is repaired.
            local edit = check(layout.seam_edit_node(record.next_seam.preserved, road.endpoint), 'the endpoint is not in the preserved seam')
            local ahead = {x = road.endpoint.x + 4, y = 0, z = 0}
            local ahead_name = node_name(ahead)
            edit = {x = edit.x, y = edit.y, z = edit.z, name = edit.name}
            core.swap_node(edit, {name = DIRT})
            local ok, refusal = try('extend ' .. road_id)
            assert(not ok and refusal:find('seam_changed', 1, true), tostring(refusal))
            assert(node_name(edit) == DIRT, 'the edit was repaired')
            assert(service.active == nil and counters.builds == 1 + 3 and node_name(ahead) == ahead_name, 'a refused extension did work')
            local after = check(service:status(road_id))
            assert(after.state == 'open' and after.revision == road.revision and after.pending == nil, core.serialize(after))
            assert(grow('inspect ' .. road_id):find('World: mismatch', 1, true))
            core.log('action', 'GROWTH_TRIAL_SEAM_EDIT_REFUSED ' .. refusal)
            core.swap_node(edit, {name = edit.name})
            assert(grow('inspect ' .. road_id):find('World: matches_intended', 1, true))
            -- Interrupted fourth cycle. Everything phase 2 compares with is saved first.
            mod_storage:set_string(EXPECT_KEY, core.serialize({road_id = road_id, revision = road.revision,
                endpoint = road.endpoint, mode = mode, edit = edit,
                ahead = ahead, ahead_name = ahead_name, segments = road.segments}))
            trap.survey, trap.build = mode == 'planning', mode == 'build'
            s.show({TOWNS.steer})   -- 112 nodes ahead: a final attachment, which is what gets cut off
            assert(grow('extend ' .. road_id):find('started', 1, true))
            wait(function() return fired end, function() end)
        end
        walk(1)
    end)
end

local function phase_one(done, mod_storage)
    fill_area()
    phase_one_body(done, mod_storage)
end

local function phase_two(done, mod_storage)
    local raw = mod_storage:get_string(EXPECT_KEY)
    assert(raw ~= '', 'no expectations from phase 1: was the same world used?')
    local expect = check(core.deserialize(raw, true))
    local trap, counters = {mod_storage = mod_storage}, {surveys = 0, builds = 0}
    local s = services(trap, counters)
    local service, gstore, grow, try = s.service, s.gstore, s.grow, s.try
    local road_id = expect.road_id
    local road = check(gstore:road(road_id), 'road ' .. road_id .. ' is not in the persisted registry')
    assert(road.revision == expect.revision and road.endpoint.x == expect.endpoint.x
        and road.endpoint.y == expect.endpoint.y and road.endpoint.z == expect.endpoint.z, core.serialize(road))
    if expect.mode == 'planning' then
        assert(road.state == 'stopped' and road.stop.code == 'interrupted' and road.pending == nil, core.serialize(road))
    else
        assert(road.state == 'uncertain' and road.pending and road.pending.state == 'uncertain'
            and road.stop.code == 'interrupted', core.serialize(road))
        assert(check(gstore:claim('endpoint:' .. road_id .. ':' .. expect.revision)).state == 'uncertain', 'source claim')
        assert(check(gstore:entry(road.pending.segment_id)).state == 'uncertain', 'segment entry')
    end
    local text = grow('status ' .. road_id)
    assert(text:find('Blocked: interrupted', 1, true) or text:find('Stop: interrupted', 1, true), text)
    core.log('action', 'GROWTH_TRIAL_RESTART ' .. core.serialize({mode = expect.mode, state = road.state, stop = road.stop,
        pending = road.pending, revision = road.revision}))
    -- Give any wrongly replayed work time to show itself, then check nothing ran.
    local started = core.get_us_time() / 1e6
    wait(function() return core.get_us_time() / 1e6 - started > 3 end, function()
        assert(service.active == nil and counters.builds == 0 and counters.surveys == 0, 'work was replayed after restart')
        assert(check(gstore:road(road_id)).state == road.state, 'state changed on its own')
        if expect.mode == 'planning' then
            assert(node_name(expect.ahead) == expect.ahead_name, 'the interrupted planning wrote terrain')
            local edit = expect.edit
            core.swap_node(edit, {name = DIRT})
            local ok, refusal = try('retry ' .. road_id)
            assert(not ok and refusal:find('seam_changed', 1, true), tostring(refusal))
            assert(node_name(edit) == DIRT and check(gstore:road(road_id)).state == 'stopped', 'retry repaired or reopened')
            assert(counters.surveys == 0, 'retry surveyed with an edited seam')
            core.swap_node(edit, {name = edit.name})
            s.show({TOWNS.steer})
            assert(grow('retry ' .. road_id):find('Retry started as growth cycle', 1, true))
            wait(function() return service.active == nil end, function()
                -- The retried cycle is the final attachment that was cut off: it connects.
                local after = check(service:status(road_id))
                assert(after.state == 'connected' and after.revision == expect.revision + 1
                    and after.connected.approach_id == STEER.id and after.connected.id == TOWNS.steer.id, core.serialize(after))
                local bends = count_bends(gstore, after.last_segment_id)
                assert(bends >= 2, 'the attachment has only ' .. bends .. ' bends')
                local record = check(gstore:load_record(after.last_segment_id))
                local final = record.headings[#record.headings]
                assert(final == 7 or final == 0 or final == 1, 'arrival heading ' .. final .. ' does not face into the town')
                local claim = check(gstore:claim('exit:' .. STEER_FULL_ID))
                assert(claim.state == 'held' and claim.road_id == road_id, 'the full exit id stays claimed')
                assert(arrived(expect.endpoint.x), 'no walkable path from the seam onto the built exit')
                local inspected = grow('inspect ' .. road_id)
                assert(inspected:find('World: matches_intended', 1, true) and inspected:find('matches the intended geometry', 1, true), inspected)
                local admitted, why = s.outward:start({settlement_id = TOWNS.steer.id, exit_id = STEER.id, requester = 'trial',
                    policy = {version = 1, seed = 1}, candidates = {{x = 700, z = 0}}})
                assert(not admitted and why.code == 'already_reserved' and why.scope == 'exit', 'an outward road may not start from a claimed exit')
                core.log('action', 'GROWTH_TRIAL_ARRIVAL ' .. core.serialize({state = after.state, endpoint = after.endpoint,
                    revision = after.revision, bends = bends, final_heading = final, walkable = true, claim = claim.state}))
                done()
            end)
        else
            local ok, msg = try('extend ' .. road_id)
            assert(not ok and msg:find('not_extendable', 1, true), tostring(msg))
            ok, msg = try('retry ' .. road_id)
            assert(not ok and msg:find('not_retryable', 1, true), tostring(msg))
            local ok2, report = try('inspect ' .. road_id)
            assert(ok2 and report:find('World:', 1, true), tostring(report))
            assert(counters.builds == 0 and counters.surveys == 0 and check(gstore:road(road_id)).state == 'uncertain')
            -- The cut-off final attachment: its reservation, geometry and walkability after a restart.
            assert(check(gstore:claim('exit:' .. STEER_FULL_ID)).state == 'uncertain', 'the exit claim is kept, uncertain')
            assert(report:find('World: matches_intended', 1, true) and report:find('Attachment: checked', 1, true)
                and report:find('matches the intended geometry', 1, true), report)
            local admitted, why = s.outward:start({settlement_id = TOWNS.steer.id, exit_id = STEER.id, requester = 'trial',
                policy = {version = 1, seed = 1}, candidates = {{x = 700, z = 0}}})
            assert(not admitted and why.code == 'already_reserved', 'the persisted incoming claim blocks /roads_outward')
            assert(arrived(expect.endpoint.x), 'the written geometry should be walkable even though it is never promoted')
            assert(not check(gstore:road(road_id)).connected, 'an uncertain attachment is never connected')
            core.log('action', 'GROWTH_TRIAL_ATTACHMENT_INSPECT ' .. report:gsub('\n', ' | '))
            done()
        end
    end)
end

return function(phase, done, mod_storage)
    core.emerge_area(a, b, function(_, _, left)
        if left ~= 0 then return end
        core.after(0, guarded(function()
            if phase == 1 then phase_one(done, mod_storage) else phase_two(done, mod_storage) end
        end))
    end)
end
