-- SPDX-License-Identifier: GPL-3.0-or-later
-- Shared growth harness for tests/growth.lua and tests/growth_command.lua. The
-- real outward service, growth service, stores, planner, composer, builder and
-- seam code run over a simulated world; only Towns, surveying, the job slot and
-- the clock are scripted.
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
local growth_policy = dofile('src/growth_policy.lua')
local fx = dofile('tests/outward_fixture.lua')
assert(edges.set_raster(raster)); assert(planner.set_edges(edges)); assert(plans.set_dependencies(raster, edges))
planner.set_seam_dependencies(seam, raster); plans.set_seam_dependency(seam); build.set_seam_dependencies(seam, raster)
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
    h.providers, h.attachments = {}, {}   -- fake destination and final-attachment providers, by kind
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
        if h.survey_script then return h.survey_script(a, b, owner) end
        -- Like the engine's chunk-aligned survey, the surveyed bounds cover whole mapblocks.
        local r = rect(a, b)
        if options.aligned_bounds then r = {min_x = math.floor(r.min_x / 16) * 16, max_x = math.floor(r.max_x / 16) * 16 + 15, min_y = -64, max_y = 63,
            min_z = math.floor(r.min_z / 16) * 16, max_z = math.floor(r.max_z / 16) * 16 + 15} end
        local terrain = terrain_for(r); terrain.owner = owner
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
        if h.on_planner then h.on_planner(terrain, request, c) end
        local job, err = planner.new(terrain, request, c)
        if job and h.planner_wrap then return h.planner_wrap(job, c, request) end
        return job, err
    end
    local function compose(terrain, route, c) return plans.compose(terrain, route, c) end

    local function wire()
        h.growth_store = growth_store.new({storage = h.storage, serialize = fx.serialize, deserialize = fx.deserialize,
            now = function() return 1000 + h.time end})
        h.store = outward_store.new({storage = h.storage, serialize = fx.serialize, deserialize = fx.deserialize,
            now = function() return 1000 + h.time end})
        local outward_service
        h.growth = assert(growth.new({policy = growth_policy, providers = h.providers, attachments = h.attachments,
            destination_unavailable = function(d) if h.unavailable then return h.unavailable(d) end end, store = h.growth_store, jobs = h.jobs, now = function() return h.time end,
            after = h.after, raster = raster, seam = seam, access = h.access, has_timer = has_timer,
            classify = surface.classify, load_area = function() end, world_config = function() return config end,
            survey = h.survey, start_survey = h.start_survey, new_planner = new_planner, compose = compose,
            start_build = h.start_build, save_interval = function() return 5.3 end, towns = options.growth_towns,
            wrap_terrain = options.growth_towns and (options.wrap_terrain or function(t) return t end) or nil,
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

return {harness = harness, SID = SID, EAST = EAST, COBBLE = COBBLE, STONE = STONE}
