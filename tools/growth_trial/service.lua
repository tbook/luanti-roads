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
local road_destinations = load('road_destinations')
local growth_scheduler = load('growth_scheduler')
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

-- opts.roads: the junction scenario. The registered-road provider and resolver are the
-- only destination provider (no Towns), exits are looked up per settlement and exit id.
local function services(trap, counters, opts)
    opts = opts or {}
    local exits, joins_service = {}, nil
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
        if trap.fail_survey then
            -- A scripted terrain-survey failure: the cycle stops with zero writes (a blocked road).
            return nil, {code = 'survey_failed', reason = 'scripted survey failure'}
        end
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
    function towns:exit(settlement, exit_id) return copy(exits[settlement.id .. '/' .. tostring(exit_id)] or descriptor) end
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
    local providers, attachments, unavailable = dest.providers, dest.attachments, dest.unavailable
    if opts.roads then
        local joins = road_destinations.new({store = gstore, digest = towns_destinations.revision, connectors = connectors,
            edges = edges, raster = raster, surface = surface, access = access,
            load = function(minp, maxp) return core.load_area(minp, maxp) end, has_timer = timer, owner = growth.OWNER})
        providers, attachments, unavailable = joins.providers, joins.attachments, joins.unavailable
        joins_service = joins
    end
    local service = check(growth.new({policy = growth_policy, providers = providers, attachments = attachments,
        destination_unavailable = unavailable, towns = adapter, wrap_terrain = towns_adapter.wrap_terrain,
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
    local function add_exit(spec)
        local d = copy(descriptor)
        d.settlement_id = spec.sid; d.exit_id = spec.exit; d.anchor = copy(spec.anchor); d.direction = copy(spec.direction)
        d.center = {x = spec.anchor.x - 10, y = 0, z = spec.anchor.z}
        exits[spec.sid .. '/' .. spec.exit] = d
    end
    -- Scheduler scenario: the real proximity scheduler over this trial's growth service, with
    -- scripted connected players and positions (players[name] = feet position, or nil).
    local proximity, players, extends = nil, {}, {}
    if opts.scheduler then
        proximity = check(growth_scheduler.new({enabled = true, now = now,
            connected = function()
                local names = {}
                for name, pos in pairs(players) do if pos then names[#names + 1] = name end end
                return names
            end,
            sample = function(name) return players[name] and copy(players[name]) or nil end,
            roads = function()
                local list = {}
                for _, id in ipairs(gstore:road_ids()) do
                    local road = gstore:road(id)
                    if road then
                        list[#list + 1] = {road_id = id, revision = road.revision, endpoint = road.endpoint, state = road.state,
                            activation = road.activation}
                    end
                end
                return list
            end,
            slot_busy = function() return slot_jobs.active ~= nil end,
            extend = function(road_id, actor)
                -- The record is made before the call: a cycle cut off inside extend never returns.
                local road = gstore:road(road_id)
                local who = players.walker
                local record = {road_id = road_id, actor = actor, revision = road and road.revision,
                    dist = who and road and math.sqrt((who.x - road.endpoint.x) ^ 2 + (who.z - road.endpoint.z) ^ 2) or nil}
                extends[#extends + 1] = record
                local id, err = service:extend(road_id, actor)
                record.id, record.err = id, err
                return id, err
            end,
            log = function(l, m) core.log(l, m) end}))
    end
    local command_defs = {}
    assert(commands.register({register_chatcommand = function(name, def) command_defs[name] = def end,
        get_player_by_name = function() return nil end}, slot_jobs, surface, function() return config end,
        nil, nil, {service = service, scheduler = proximity}))
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
    return {service = service, outward = outward_service, gstore = gstore, show = show, slot_jobs = slot_jobs, try = try, grow = grow,
        exits = exits, joins = joins_service, add_exit = add_exit, proximity = proximity, players = players, extends = extends}
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

------------------------------------------------------------------ junction scenario
-- Roads joining roads (#52), in its own disposable world (roads_trial_scenario = junction).
-- A flat stone world holds four fresh seeded roads, each built by the real outward
-- service and adopted: A runs east along z = 0 (x 208..248); B comes from the south
-- (x = 228) and joins A in a T; C comes from the east facing A's open endpoint and joins
-- it end to end; D comes from the north (x = 216) and is the cut-off cycle (a second,
-- clear T interval). Towns is absent: the registered-road provider is the only one.
-- Every junction is checked by an independent breadth-first walk over the real nodes,
-- by byte-for-byte comparison of the target road, and by the claims persisted.
local J = {
    a = {x = 160, y = -32, z = -110}, b = {x = 360, y = 31, z = 110},
    A = {sid = 'junction:a', exit = '+x:200:0', anchor = {x = 200, y = 0, z = 0}, direction = {x = 1, z = 0}, target = {x = 248, z = 0}},
    B = {sid = 'junction:b', exit = '+z:220:-60', anchor = {x = 220, y = 0, z = -60}, direction = {x = 0, z = 1}, target = {x = 228, z = -20}},
    C = {sid = 'junction:c', exit = '-x:312:0', anchor = {x = 312, y = 0, z = 0}, direction = {x = -1, z = 0}, target = {x = 280, z = 0}},
    D = {sid = 'junction:d', exit = '-z:208:60', anchor = {x = 208, y = 0, z = 60}, direction = {x = 0, z = -1}, target = {x = 216, z = 20}},
}
local JUNCTION_KEY = 'trial_junction_expect'

local function fill_junction_area()
    local vm = core.get_voxel_manip()
    local emin, emax = vm:read_from_map(J.a, J.b)
    local area = VoxelArea:new({MinEdge = emin, MaxEdge = emax}); local data = vm:get_data()
    local stone, air = core.get_content_id('mcl_core:stone'), core.get_content_id('air')
    for z = J.a.z, J.b.z do for y = J.a.y, J.b.y do for x = J.a.x, J.b.x do data[area:index(x, y, z)] = y <= 0 and stone or air end end end
    vm:set_data(data); vm:write_to_map(); vm:update_map()
end

-- Names and param2 of every node of a box: the target road must be byte for byte unchanged.
local function signature(x1, x2, z1, z2)
    core.load_area({x = x1, y = -6, z = z1}, {x = x2, y = 6, z = z2})
    local out = {}
    for x = x1, x2 do for z = z1, z2 do for y = -4, 5 do
        local n = core.get_node({x = x, y = y, z = z}); out[#out + 1] = n.name .. '/' .. n.param2
    end end end
    return table.concat(out, ',')
end
local function a_signature() return signature(207, 249, -1, 1) end

-- Every listed "x:z" must be reachable by the walking oracle from (sx, sz).
local function must_reach(sx, sz, box, list, what)
    local reached = walk_world(sx, sz, box)
    for _, key in ipairs(list) do assert(reached[key], what .. ': ' .. key .. ' is not walkable from ' .. sx .. ':' .. sz) end
    return reached
end
local JBOX = {x1 = 190, x2 = 340, z1 = -80, z2 = 80}

local function build_road(s, spec, then_do)
    s.add_exit(spec)
    check(s.outward:start({settlement_id = spec.sid, exit_id = spec.exit, requester = 'trial', policy = {version = 1, seed = 1},
        candidates = {spec.target}}))
    wait(function() return s.outward:status() == nil end, function()
        local status = check(s.outward:status(spec.sid))
        assert(status.state == 'built' and status.writes == 'all', core.serialize(status.error))
        assert(s.grow('adopt ' .. status.op_id):find('is adopted from outward operation', 1, true))
        then_do('growth:v1:' .. status.op_id)
    end)
end
local function cycle(s, road_id, then_do)
    assert(s.grow('extend ' .. road_id):find('started', 1, true))
    wait(function() return s.service.active == nil end, then_do)
end
local function claim_state(gstore, id) local c = gstore:claim(id); return c and c.state end

local function junction_one(done, mod_storage)
    local mode = core.settings:get('roads_trial_interrupt') or 'planning'
    assert(mode == 'planning' or mode == 'build', 'roads_trial_interrupt must be planning or build')
    fill_junction_area()
    local trap, fired = {mod_storage = mod_storage}, false
    function trap.fire(kind)
        if fired then return end
        fired = true
        core.log('action', 'GROWTH_TRIAL_INTERRUPT ' .. kind)
        done()
    end
    local counters = {surveys = 0, builds = 0}
    local s = services(trap, counters, {roads = true})
    local service, gstore = s.service, s.gstore
    build_road(s, J.A, function(A)
        local target_before = a_signature()
        build_road(s, J.B, function(B)
            cycle(s, B, function()
                -- T junction: B stops, A is untouched and still open, the interval is claimed.
                local st = check(service:status(B))
                assert(st.state == 'connected' and st.connected.kind == 'road' and st.connected.id == A
                    and st.connected.junction == 't', core.serialize(st))
                local text = s.grow('status ' .. B)
                assert(text:find('Connected to road ' .. A .. ' by a T junction', 1, true), text)
                assert(check(service:status(A)).state == 'open' and a_signature() == target_before, 'the T junction touched the target road')
                for u = 225, 231 do assert(claim_state(gstore, 'join:x:0:' .. u) == 'held', 'join claim ' .. u) end
                assert(gstore:claim('join:x:0:224') == nil and gstore:claim('join:x:0:232') == nil, 'the interval is exactly 7 nodes')
                local inspected = s.grow('inspect ' .. B)
                assert(inspected:find('World: matches_intended', 1, true) and inspected:find('Attachment: checked', 1, true)
                    and inspected:find('matches the intended geometry', 1, true), inspected)
                -- Walk every branch: B's start, B's end, onto A and out along both of A's ends.
                must_reach(228, -60, JBOX, {'228:-60', '228:-20', '228:-4', '228:-2', '228:-1', '228:0', '228:1', '208:0', '248:0', '207:1', '249:-1'}, 'T junction')
                core.log('action', 'GROWTH_TRIAL_T_JUNCTION ' .. core.serialize({road = B, target = A, junction = st.connected.junction}))
                build_road(s, J.C, function(C)
                    cycle(s, C, function()
                        -- End to end: both unfinished endpoints stop; A can no longer grow.
                        local ca, cc = check(service:status(A)), check(service:status(C))
                        assert(cc.state == 'connected' and cc.connected.id == A and cc.connected.junction == 'end', core.serialize(cc))
                        assert(ca.state == 'connected' and ca.connected.id == C, core.serialize(ca))
                        assert(claim_state(gstore, 'endjoin:' .. A) == 'held', 'the target endpoint stays claimed')
                        local ok, msg = s.try('extend ' .. A)
                        assert(not ok and msg:find('not_extendable', 1, true), tostring(msg))
                        assert(a_signature() == target_before, 'the end-to-end join touched the target road')
                        local text2 = s.grow('status ' .. C)
                        assert(text2:find('Connected to road ' .. A .. ' end to end', 1, true), text2)
                        local inspected2 = s.grow('inspect ' .. C)
                        assert(inspected2:find('World: matches_intended', 1, true) and inspected2:find('Attachment: checked', 1, true), inspected2)
                        must_reach(320, 0, JBOX, {'320:0', '280:0', '250:0', '249:0', '248:0', '228:0', '208:0', '228:-20', '228:-60'}, 'end-to-end join')
                        core.log('action', 'GROWTH_TRIAL_END_JUNCTION ' .. core.serialize({road = C, target = A, junction = cc.connected.junction}))
                        build_road(s, J.D, function(D)
                            -- The cut-off cycle: a second T onto A, with a clear interval (213..219).
                            mod_storage:set_string(JUNCTION_KEY, core.serialize({mode = mode, A = A, B = B, C = C, D = D,
                                target = target_before}))
                            trap.survey, trap.build = mode == 'planning', mode == 'build'
                            assert(s.grow('extend ' .. D):find('started', 1, true))
                            wait(function() return fired end, function() end)
                        end)
                    end)
                end)
            end)
        end)
    end)
end

local function junction_two(done, mod_storage)
    local raw = mod_storage:get_string(JUNCTION_KEY)
    assert(raw ~= '', 'no junction expectations from phase 1: was the same world used?')
    local expect = check(core.deserialize(raw, true))
    local trap, counters = {mod_storage = mod_storage}, {surveys = 0, builds = 0}
    local s = services(trap, counters, {roads = true})
    local service, gstore = s.service, s.gstore
    local A, B, C, D = expect.A, expect.B, expect.C, expect.D
    -- Earlier junctions survive the restart exactly: states, connections and held claims.
    assert(check(gstore:road(A)).state == 'connected' and check(gstore:road(B)).state == 'connected'
        and check(gstore:road(C)).state == 'connected', 'the finished junction roads changed state')
    assert(gstore:road(B).connected.id == A and gstore:road(C).connected.id == A and gstore:road(A).connected.id == C)
    for u = 225, 231 do assert(claim_state(gstore, 'join:x:0:' .. u) == 'held', 'join claim ' .. u .. ' after restart') end
    assert(claim_state(gstore, 'endjoin:' .. A) == 'held')
    assert(a_signature() == expect.target, 'the target road changed across the restart')
    local road = check(gstore:road(D))
    local joins = gstore:claims_of(D, 64)
    local text = s.grow('status ' .. D)
    assert(text:find('interrupted', 1, true), text)
    if expect.mode == 'planning' then
        assert(road.state == 'stopped' and road.stop.code == 'interrupted' and road.pending == nil, core.serialize(road))
        assert(#joins == 0, 'a cycle interrupted in planning holds no claim')
    else
        assert(road.state == 'uncertain' and road.pending and road.pending.state == 'uncertain' and road.stop.code == 'interrupted', core.serialize(road))
        assert(#joins >= 7, 'the interrupted junction keeps its claims (' .. #joins .. ')')
        for _, c in ipairs(joins) do assert(c.state == 'uncertain', c.id .. ' is ' .. c.state) end
        for u = 213, 219 do assert(claim_state(gstore, 'join:x:0:' .. u) == 'uncertain', 'join claim ' .. u) end
    end
    core.log('action', 'GROWTH_TRIAL_RESTART ' .. core.serialize({mode = expect.mode, state = road.state, claims = #joins}))
    local started = core.get_us_time() / 1e6
    wait(function() return core.get_us_time() / 1e6 - started > 3 end, function()
        assert(service.active == nil and counters.builds == 0 and counters.surveys == 0, 'work was replayed after restart')
        if expect.mode == 'planning' then
            -- Deliberate retry: the cut-off T is built now, claims its interval and is walked.
            assert(s.grow('retry ' .. D):find('Retry started as growth cycle', 1, true))
            wait(function() return service.active == nil end, function()
                local after = check(service:status(D))
                assert(after.state == 'connected' and after.connected.id == A and after.connected.junction == 't', core.serialize(after))
                for u = 213, 219 do assert(claim_state(gstore, 'join:x:0:' .. u) == 'held', 'retried claim ' .. u) end
                assert(a_signature() == expect.target, 'the retried junction touched the target road')
                local inspected = s.grow('inspect ' .. D)
                assert(inspected:find('World: matches_intended', 1, true) and inspected:find('matches the intended geometry', 1, true), inspected)
                must_reach(216, 60, JBOX, {'216:60', '216:20', '216:2', '216:1', '216:0', '216:-1', '208:0', '248:0', '280:0', '320:0', '228:-60'}, 'retried T junction')
                core.log('action', 'GROWTH_TRIAL_JUNCTION_RETRY ' .. core.serialize({road = D, state = after.state, junction = after.connected.junction}))
                done()
            end)
        else
            local ok, msg = s.try('extend ' .. D)
            assert(not ok and msg:find('not_extendable', 1, true), tostring(msg))
            ok, msg = s.try('retry ' .. D)
            assert(not ok and msg:find('not_retryable', 1, true), tostring(msg))
            local ok2, report = s.try('inspect ' .. D)
            assert(ok2 and report:find('World: matches_intended', 1, true) and report:find('Attachment: checked', 1, true)
                and report:find('matches the intended geometry', 1, true) and report:find('Claims held by this road', 1, true)
                and report:find('Writes may have happened', 1, true), tostring(report))
            assert(counters.builds == 0 and counters.surveys == 0 and check(gstore:road(D)).state == 'uncertain')
            assert(a_signature() == expect.target, 'the interrupted junction touched the target road')
            -- The written geometry is walkable, but an interrupted junction is never promoted.
            must_reach(216, 60, JBOX, {'216:60', '216:20', '216:2', '216:1', '216:0', '216:-1', '208:0', '248:0', '320:0'}, 'interrupted T junction')
            assert(not check(gstore:road(D)).connected, 'an uncertain junction is never connected')
            -- Retire keeps every reservation.
            assert(s.grow('retire ' .. D):find('retired', 1, true))
            assert(claim_state(gstore, 'join:x:0:216') == 'uncertain', 'retire released a claim')
            core.log('action', 'GROWTH_TRIAL_JUNCTION_INSPECT ' .. report:gsub('\n', ' | '))
            done()
        end
    end)
end

------------------------------------------------------------------ scheduler scenario
-- Automatic growth by player proximity (#53). The REAL growth_scheduler runs over this
-- trial's real growth service; only the player is scripted: connected() and sample()
-- return a scripted position that the driver moves one waypoint per scheduler tick (the
-- scheduler's own 1 s sampling interval, real time), so a walk is a sequence of samples
-- exactly as a client's would be. Everything else (growth, planner, builder, claims,
-- storage, the /roads_grow definition) is as in the growth scenario. The world is the growth
-- world (walls, `away`) with the `steer` town moved 96 nodes further so the final
-- attachment is the fifth cycle.
--   phase 1: stationary player inside the radius (no arming); automatic cycles 1 and 2 from
--   the old forward inner edge; an edited seam refuses the next automatic cycle (seam_changed,
--   no retry loop); a scripted survey failure stops cycle 3 (blocked, never retried
--   automatically, deliberate retry builds it); cycle 4 is cut off (planning or build).
--   phase 2 (restart): nothing is replayed with a player standing at the endpoint; planning
--   mode retries cycle 4 deliberately and cycle 5 is the automatic final attachment.
local SCHED_KEY = 'trial_scheduler_expect'
local WALKER = 'walker'
local function sched_towns()
    TOWNS = {steer = layout.towns(ORIGIN_X + CYCLE).steer, away = layout.towns(ORIGIN_X).away}
    STEER = TOWNS.steer.exits[1]
    STEER_FULL_ID = TOWNS.steer.id .. '/' .. STEER.id
end
local function at(x) return {x = x, y = 1, z = 0} end
-- Waypoints ending exactly at `to`, spaced 12 nodes (a walking pace per 1 s sample is slower; the
-- scheduler only sees positions), starting at `from`. Spacing keeps intermediate samples outside 24.
local function walk_path(from, to)
    local list = {}
    local x = to
    while x > from do table.insert(list, 1, at(x)); x = x - 12 end
    table.insert(list, 1, at(from))
    return list
end
local function stay(x, n) local list = {}; for i = 1, n do list[i] = at(x) end; return list end
local function join(...)
    local out = {}
    for _, part in ipairs({...}) do for _, p in ipairs(part) do out[#out + 1] = p end end
    return out
end

-- Moves the scripted player one waypoint per scheduler tick. Growth started by the scheduler is
-- waited out (the player stands where the trigger sample put it); then_do runs once the last
-- waypoint has been sampled and the slot and queue are idle. No cycle may start before the last waypoint.
local function drive(s, trap, positions, then_do, trigger)
    trigger = trigger or #positions   -- the waypoint at which a start is expected; none may happen earlier
    local i, last, before = 1, s.proximity.ticks, #s.extends
    local started = core.get_us_time() / 1e6
    s.players[WALKER] = positions[1]
    local poll
    poll = guarded(function()
        if trap.stop then return end
        s.proximity:step()
        if s.proximity.ticks ~= last then
            last = s.proximity.ticks
            if i < trigger then
                assert(#s.extends == before, 'automatic growth started before waypoint ' .. trigger .. ' (waypoint ' .. i .. ' of ' .. #positions
                    .. ', x ' .. positions[i].x .. ')')
            end
            if s.slot_jobs.active == nil and s.proximity.queue:size() == 0 then
                if i >= #positions then return then_do() end
                i = i + 1
                s.players[WALKER] = positions[i]
            end
        end
        if core.get_us_time() / 1e6 - started > 240 then error('scripted walk timed out') end
        core.after(0.1, poll)
    end)
    poll()
end

local function sched_trap(mod_storage, done, s_ref)
    local trap = {mod_storage = mod_storage}
    function trap.fire(kind)
        if trap.stop then return end
        trap.stop = true
        local rec = s_ref.s.extends[#s_ref.s.extends]
        assert(rec and rec.actor == 'proximity' and rec.dist and rec.dist <= 24,
            'the interrupted cycle was not started by the scheduler: ' .. core.serialize(rec))
        core.log('action', 'GROWTH_TRIAL_INTERRUPT ' .. kind .. ' ' .. core.serialize({actor = rec.actor, dist = rec.dist}))
        done()
    end
    return trap
end

local function sched_one(done, mod_storage)
    local mode = core.settings:get('roads_trial_interrupt') or 'planning'
    assert(mode == 'planning' or mode == 'build', 'roads_trial_interrupt must be planning or build')
    fill_area()
    local ref = {}
    local trap = sched_trap(mod_storage, done, ref)
    local counters = {surveys = 0, builds = 0}
    local s = services(trap, counters, {scheduler = true})
    ref.s = s
    local service, gstore, grow = s.service, s.gstore, s.grow
    check(s.outward:start({settlement_id = SID, exit_id = EXIT, requester = 'trial', policy = {version = 1, seed = 1},
        candidates = {{x = ORIGIN_X, z = 0}}}))
    wait(function() return s.outward:status() == nil end, function()
        local status = check(s.outward:status(SID))
        assert(status.state == 'built' and status.writes == 'all', core.serialize(status.error))
        assert(grow('adopt ' .. status.op_id):find('is adopted from outward operation', 1, true))
        local road_id = 'growth:v1:' .. status.op_id
        local function cur() return check(service:status(road_id)) end
        local first = cur()
        assert(first.endpoint.x == ORIGIN_X and first.revision == 1 and first.state == 'open')
        local report = grow('status ' .. road_id)
        assert(report:find('Automatic growth is enabled', 1, true) and report:find('Waiting for a player', 1, true), report)

        -- One automatic cycle: the player walks on from where the previous trigger left them, with no
        -- backtracking, until the first sample inside 24 of the new endpoint.
        local function advance(towns, from, then_do)
            local st = cur()
            local before = #s.extends
            s.show(towns)
            drive(s, trap, walk_path(from or s.players[WALKER].x, st.endpoint.x - 20), function()
                assert(#s.extends == before + 1, 'expected one automatic start, saw ' .. (#s.extends - before))
                local rec = s.extends[#s.extends]
                assert(rec.id and rec.actor == 'proximity' and rec.dist <= 24 and rec.revision == st.revision, core.serialize(rec))
                local now_status = cur()
                assert(now_status.state == 'open' and now_status.revision == st.revision + 1
                    and now_status.endpoint.x > st.endpoint.x and now_status.endpoint.z == 0, core.serialize(now_status))
                assert(node_name(now_status.endpoint) == COBBLE)
                assert(grow('inspect ' .. road_id):find('World: matches_intended', 1, true))
                core.log('action', 'GROWTH_TRIAL_SCHEDULER_AUTO ' .. core.serialize({from = st.endpoint.x, to = now_status.endpoint.x,
                    revision = now_status.revision, trigger_dist = rec.dist, trigger_x = s.players[WALKER].x}))
                then_do(now_status)
            end)
        end

        -- Ticks with a player already inside the radius never arm: nothing starts.
        local x0 = ORIGIN_X
        drive(s, trap, stay(x0 - 10, 4), function()
            assert(#s.extends == 0 and service.active == nil and counters.builds == 1, 'a player first seen inside started growth')
            local armed = s.proximity:status(road_id)
            assert(armed.armed == 0 and armed.queue.length == 0, core.serialize(armed))
            advance({}, x0 - 60, function(c1)
                local text = grow('status ' .. road_id)
                assert(text:find('Selected: none', 1, true) and text:find('built (directional)', 1, true), text)
                advance({TOWNS.away}, nil, function(c2)
                    local text2 = grow('status ' .. road_id)
                    assert(text2:find('built (directional)', 1, true)
                        and text2:find('destination ' .. TOWNS.away.exits[1].id .. ' (final) incompatible_heading', 1, true)
                        and text2:find('96 node fallback composed', 1, true), text2)
                    core.log('action', 'GROWTH_TRIAL_FALLBACK ' .. text2)
                    -- Edited seam at the c2 endpoint: the automatic start is refused and not repeated.
                    local _, record = count_bends(gstore, c2.last_segment_id)
                    local edit = check(layout.seam_edit_node(record.next_seam.preserved, c2.endpoint), 'endpoint not in the preserved seam')
                    edit = {x = edit.x, y = edit.y, z = edit.z, name = edit.name}
                    local ahead = {x = c2.endpoint.x + 4, y = 0, z = 0}
                    local ahead_name = node_name(ahead)
                    core.swap_node(edit, {name = DIRT})
                    local builds, before = counters.builds, #s.extends
                    local seam_walk = walk_path(s.players[WALKER].x, c2.endpoint.x - 20)
                    drive(s, trap, join(seam_walk, stay(c2.endpoint.x - 20, 4)), function()
                        assert(#s.extends == before + 1, 'the refused cycle was started ' .. (#s.extends - before) .. ' times')
                        local rec = s.extends[#s.extends]
                        assert(not rec.id and rec.err and rec.err.code == 'seam_changed' and rec.actor == 'proximity', core.serialize(rec))
                        assert(node_name(edit) == DIRT and node_name(ahead) == ahead_name and counters.builds == builds
                            and service.active == nil, 'a refused automatic cycle did work or repaired the seam')
                        local after = cur()
                        assert(after.state == 'open' and after.revision == c2.revision and after.pending == nil, core.serialize(after))
                        assert(grow('inspect ' .. road_id):find('World: mismatch', 1, true))
                        core.log('action', 'GROWTH_TRIAL_SCHEDULER_SEAM_REFUSED ' .. core.serialize(rec.err))
                        core.swap_node(edit, {name = edit.name})
                        assert(grow('inspect ' .. road_id):find('World: matches_intended', 1, true))
                        -- Blocked stop: leave and re-approach; the survey fails once, then never again by itself.
                        trap.fail_survey = true
                        s.show({})
                        local x = c2.endpoint.x
                        local count = #s.extends
                        drive(s, trap, walk_path(x - 56, x - 20), function()
                            assert(#s.extends == count + 1, 'expected one blocked start')
                            local rec2 = s.extends[#s.extends]
                            assert(rec2.id and rec2.actor == 'proximity' and rec2.dist <= 24, core.serialize(rec2))
                            local stopped = cur()
                            assert(stopped.state == 'stopped' and stopped.stop and stopped.stop.code == 'survey_failed'
                                and stopped.revision == c2.revision and stopped.pending == nil, core.serialize(stopped))
                            local blocked = grow('status ' .. road_id)
                            assert(blocked:find('Blocked: automatic growth never retries a stopped road', 1, true), blocked)
                            -- Leaving and returning twice (and standing inside): no automatic retry.
                            drive(s, trap, join(walk_path(x - 56, x - 20), stay(x - 20, 2), walk_path(x - 56, x - 20), stay(x - 20, 3)), function()
                                assert(#s.extends == count + 1 and service.active == nil and cur().state == 'stopped',
                                    'a stopped road was retried automatically')
                                core.log('action', 'GROWTH_TRIAL_SCHEDULER_BLOCKED ' .. blocked:gsub('\n', ' | '))
                                trap.fail_survey = false
                                -- Deliberate retry builds the cycle; the scheduler stays out of it.
                                assert(grow('retry ' .. road_id):find('Retry started as growth cycle', 1, true))
                                wait(function() return service.active == nil end, function()
                                    local c3 = cur()
                                    assert(c3.state == 'open' and c3.revision == c2.revision + 1 and c3.endpoint.x > c2.endpoint.x, core.serialize(c3))
                                    assert(#s.extends == count + 1, 'the scheduler took part in a deliberate retry')
                                    -- Cycle 4: the automatic start that is cut off.
                                    local from = s.players[WALKER].x
                                    mod_storage:set_string(SCHED_KEY, core.serialize({road_id = road_id, revision = c3.revision,
                                        endpoint = c3.endpoint, mode = mode, edit = edit, ahead_x = c3.endpoint.x + 4, player_x = c3.endpoint.x - 20,
                                        extends = #s.extends + 1}))
                                    trap.survey, trap.build = mode == 'planning', mode == 'build'
                                    s.show({TOWNS.steer})
                                    drive(s, trap, walk_path(from, c3.endpoint.x - 20), function()
                                        error('the cut-off cycle should have stopped the server')
                                    end)
                                end)
                            end)
                        end)
                    end, #seam_walk)
                end)
            end)
        end)
    end)
end

local function sched_two(done, mod_storage)
    local raw = mod_storage:get_string(SCHED_KEY)
    assert(raw ~= '', 'no scheduler expectations from phase 1: was the same world used?')
    local expect = check(core.deserialize(raw, true))
    local ref = {}
    local trap = sched_trap(mod_storage, done, ref)
    local counters = {surveys = 0, builds = 0}
    local s = services(trap, counters, {scheduler = true})
    ref.s = s
    local service, gstore, grow, try = s.service, s.gstore, s.grow, s.try
    local road_id = expect.road_id
    local road = check(gstore:road(road_id), 'road ' .. road_id .. ' is not in the persisted registry')
    assert(road.revision == expect.revision and road.endpoint.x == expect.endpoint.x, core.serialize(road))
    if expect.mode == 'planning' then
        assert(road.state == 'stopped' and road.stop.code == 'interrupted' and road.pending == nil, core.serialize(road))
    else
        assert(road.state == 'uncertain' and road.pending and road.pending.state == 'uncertain' and road.stop.code == 'interrupted', core.serialize(road))
    end
    core.log('action', 'GROWTH_TRIAL_RESTART ' .. core.serialize({mode = expect.mode, state = road.state, stop = road.stop, revision = road.revision}))
    -- The scheduler is running and a player stands at the endpoint of the interrupted road, after
    -- a first sample from far away, for several ticks: nothing is replayed, nothing is retried.
    local ex = expect.endpoint.x
    drive(s, trap, join(walk_path(ex - 56, ex - 10), stay(ex - 10, 5)), function()
        assert(#s.extends == 0 and service.active == nil and counters.builds == 0 and counters.surveys == 0,
            'work was started after restart with a player present')
        assert(node_name({x = expect.ahead_x, y = 0, z = 0}) ~= COBBLE, 'the interrupted cycle wrote terrain ahead of the endpoint')
        local report = grow('status ' .. road_id)
        assert(not report:find('Queued for automatic growth', 1, true), report)
        assert(check(gstore:road(road_id)).state == road.state, 'state changed on its own')
        if expect.mode == 'planning' then
            assert(report:find('Blocked: automatic growth never retries a stopped road', 1, true), report)
            core.log('action', 'GROWTH_TRIAL_SCHEDULER_NO_REPLAY ' .. core.serialize({ticks = s.proximity.ticks, extends = #s.extends}))
            s.show({TOWNS.steer})
            assert(grow('retry ' .. road_id):find('Retry started as growth cycle', 1, true))
            wait(function() return service.active == nil end, function()
                local c4 = check(service:status(road_id))
                assert(c4.state == 'open' and c4.revision == expect.revision + 1 and c4.endpoint.x > ex, core.serialize(c4))
                assert(#s.extends == 0, 'the scheduler took part in a deliberate retry')
                -- Cycle 5: the automatic final attachment to the built exit, from the old forward inner edge.
                drive(s, trap, walk_path(s.players[WALKER].x, c4.endpoint.x - 20), function()
                    assert(#s.extends == 1, 'expected one automatic start, saw ' .. #s.extends)
                    local rec = s.extends[1]
                    assert(rec.id and rec.actor == 'proximity' and rec.dist <= 24 and rec.revision == c4.revision, core.serialize(rec))
                    local after = check(service:status(road_id))
                    assert(after.state == 'connected' and after.revision == c4.revision + 1
                        and after.connected.approach_id == STEER.id and after.connected.id == TOWNS.steer.id, core.serialize(after))
                    local record = check(gstore:load_record(after.last_segment_id))
                    local final = record.headings[#record.headings]
                    assert(final == 7 or final == 0 or final == 1, 'arrival heading ' .. final .. ' does not face into the town')
                    local claim = check(gstore:claim('exit:' .. STEER_FULL_ID))
                    assert(claim.state == 'held' and claim.road_id == road_id, 'the full exit id stays claimed')
                    assert(arrived(c4.endpoint.x), 'no walkable path from the seam onto the built exit')
                    local inspected = grow('inspect ' .. road_id)
                    assert(inspected:find('World: matches_intended', 1, true) and inspected:find('matches the intended geometry', 1, true), inspected)
                    -- A connected road never arms again, even with the player at the exit.
                    drive(s, trap, join(walk_path(after.endpoint.x - 60, after.endpoint.x), stay(after.endpoint.x, 3)), function()
                        assert(#s.extends == 1 and service.active == nil, 'a connected road was grown again')
                        core.log('action', 'GROWTH_TRIAL_SCHEDULER_ARRIVAL ' .. core.serialize({state = after.state, endpoint = after.endpoint,
                            revision = after.revision, trigger_dist = rec.dist, final_heading = final, walkable = true, claim = claim.state}))
                        done()
                    end)
                end)
            end)
        else
            local ok, msg = try('extend ' .. road_id)
            assert(not ok and msg:find('not_extendable', 1, true), tostring(msg))
            ok, msg = try('retry ' .. road_id)
            assert(not ok and msg:find('not_retryable', 1, true), tostring(msg))
            assert(counters.builds == 0 and counters.surveys == 0 and check(gstore:road(road_id)).state == 'uncertain')
            core.log('action', 'GROWTH_TRIAL_SCHEDULER_NO_REPLAY ' .. core.serialize({ticks = s.proximity.ticks, extends = #s.extends,
                state = 'uncertain'}))
            done()
        end
    end)
end

return function(phase, done, mod_storage)
    local scenario = core.settings:get('roads_trial_scenario')
    local junction = scenario == 'junction'
    local scheduler = scenario == 'scheduler'
    if junction then a, b = J.a, J.b end
    if scheduler then b = {x = 800, y = 31, z = 70}; sched_towns() end
    core.emerge_area(a, b, function(_, _, left)
        if left ~= 0 then return end
        core.after(0, guarded(function()
            if scheduler then
                if phase == 1 then sched_one(done, mod_storage) else sched_two(done, mod_storage) end
            elseif junction then
                if phase == 1 then junction_one(done, mod_storage) else junction_two(done, mod_storage) end
            elseif phase == 1 then phase_one(done, mod_storage) else phase_two(done, mod_storage) end
        end))
    end)
end
