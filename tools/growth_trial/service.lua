-- SPDX-License-Identifier: GPL-3.0-or-later
-- Engine phase of the growth trial: the real outward service records a growth
-- seed while building a fresh road, the seed is adopted and one continuation
-- cycle is built. Towns and terrain surveying are scripted over a pre-filled
-- stone world; construction, node reads, metadata, protection, timers and
-- mod storage are the real engine's. Returns function(done).
local root = core.get_modpath('roads_trial')
local function load(n) return dofile(root..'/src/'..n..'.lua') end
local surface, raster, edges, planner, plans, builder, seam =
    load('surface'), load('raster'), load('edges'), load('planner'), load('plans'), load('build'), load('seam')
edges.set_raster(raster); planner.set_edges(edges); plans.set_dependencies(raster, edges)
planner.set_seam_dependencies(seam, raster); plans.set_seam_dependency(seam); builder.set_seam_dependencies(seam, raster)
local outward, outward_store, growth, growth_store = load('outward'), load('outward_store'), load('growth'), load('growth_store')
local access = surface.engine_access(core)
local SID, EXIT = 'trial:0:0', '+x:200:0'
local COBBLE = 'mcl_core:cobble'
local function timer(p) return core.get_node_timer(p):is_started() end
local function copy(v)
    if type(v) ~= 'table' then return v end
    local r = {}; for k, x in pairs(v) do r[k] = copy(x) end; return r
end
local function check(v, e) assert(v, core.serialize(e)); return v end

local a, b = {x = 160, y = -32, z = -48}, {x = 380, y = 31, z = 48}

local function body(done)
    local vm = core.get_voxel_manip()
    local emin, emax = vm:read_from_map(a, b)
    local area = VoxelArea:new({MinEdge = emin, MaxEdge = emax}); local data = vm:get_data()
    local stone, air = core.get_content_id('mcl_core:stone'), core.get_content_id('air')
    for z = a.z, b.z do for y = a.y, b.y do for x = a.x, b.x do data[area:index(x, y, z)] = y <= 0 and stone or air end end end
    vm:set_data(data); vm:write_to_map(); vm:update_map()

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
        local r = rect(p, q)
        check(r.min_x >= a.x and r.max_x <= b.x and r.min_z >= a.z and r.max_z <= b.z, 'trial area too small')
        local terrain = check(surface.inspect(r, owner, access))
        local job = {state = 'succeeded'}
        function job:status() return {status = self.state, terrain = terrain, metrics = {}} end
        function job:cancel() self.state = 'cancelled' end
        return job
    end
    local function new_planner(terrain, request, config) return planner.new(terrain, request, config) end
    local function compose(terrain, route, config) return plans.compose(terrain, route, config) end
    local function start_build(plan, finished, guard)
        return builder.new(plan, {now = now, guard = guard, after = core.after, load = core.load_area,
            access = access, classify = surface.classify, has_timer = timer, write = function(p, n) core.swap_node(p, n) end}, finished)
    end
    local config = {world = {chunksize = 5}, planner = {weights = {slope = 4, turn = 2, cut = 1, fill = 1}, road_material = COBBLE},
        composition = {road_material = COBBLE}}
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
    local mod_storage = core.get_mod_storage()
    local storage = {get = function(k) local v = mod_storage:get_string(k); if v == '' then return nil end return v end,
        set = function(k, v) mod_storage:set_string(k, v) end, keys = function() return mod_storage:get_keys() end}
    local deserialize = function(t) return core.deserialize(t, true) end
    local gstore = growth_store.new({storage = storage, serialize = core.serialize, deserialize = deserialize, now = os.time})
    local ostore = outward_store.new({storage = storage, serialize = core.serialize, deserialize = deserialize, now = os.time})
    local interval = function() return tonumber(core.settings:get('server_map_save_interval')) or 5.3 end
    local outward_service
    local service = check(growth.new({store = gstore, jobs = slot_jobs, now = now, after = core.after, raster = raster, seam = seam,
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

    local function wait(predicate, then_do)
        local started = now()
        local function poll()
            if predicate() then return then_do() end
            if now() - started > 80 then error('trial timed out waiting for the service') end
            core.after(0.5, poll)
        end
        poll()
    end

    check(outward_service:start({settlement_id = SID, exit_id = EXIT, requester = 'trial', policy = {version = 1, seed = 1},
        candidates = {{x = 248, z = 0}}}))
    wait(function() return outward_service:status() == nil end, function()
        local status = check(outward_service:status(SID))
        assert(status.state == 'built' and status.writes == 'all', core.serialize(status.error))
        local op = outward_service:operation(status.op_id)
        assert(op.growth and op.growth.state == 'verified', core.serialize(op.growth))
        local road_id = check(service:adopt(status.op_id, 'trial'))
        local before = check(service:status(road_id))
        assert(before.endpoint.x == 248 and before.revision == 1)
        check(service:extend(road_id, 'trial'))
        wait(function() return service.active == nil end, function()
            local after = check(service:status(road_id))
            assert(after.state == 'open' and after.revision == 2 and after.endpoint.x == 344, core.serialize(after))
            assert(core.get_node({x = 344, y = 0, z = 0}).name == COBBLE)
            local report = check(service:inspect(road_id, 'trial'))
            assert(report.world.status == 'matches_intended', core.serialize(report.world))
            core.log('action', 'GROWTH_TRIAL_SERVICE ' .. core.serialize({road_id = road_id, op_id = status.op_id,
                revision = after.revision, endpoint = after.endpoint, segment = after.last_segment_id}))
            done()
        end)
    end)
end

return function(done)
    core.emerge_area(a, b, function(_, _, left)
        if left ~= 0 then return end
        core.after(0, function()
            local ok, err = xpcall(body, debug.traceback, done)
            if not ok then
                core.log('error', 'GROWTH_TRIAL_FAIL ' .. tostring(err))
                core.request_shutdown('trial failed', false, 0)
            end
        end)
    end)
end
