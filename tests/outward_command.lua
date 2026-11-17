-- SPDX-License-Identifier: GPL-3.0-or-later
-- /roads_outward, /roads_status and /roads_cancel against the real outward
-- service, store, Towns adapter and job slot. Only the terrain pipeline
-- (survey, search, composition, construction) is scripted.
local commands = dofile('src/commands.lua')
local lifecycle = dofile('src/jobs.lua')
local outward = dofile('src/outward.lua')
local outward_store = dofile('src/outward_store.lua')
local adapter = dofile('src/towns_adapter.lua')
local policy = dofile('src/outward_policy.lua')
local surface = dofile('src/surface.lua')
local towns_fixture = dofile('tests/towns_fixture.lua')
local fx = dofile('tests/outward_fixture.lua')
local count = 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if not ok then error('outward command '..name..': '..tostring(err)) end
    count = count + 1
end

local SID = 'auto:3:-2'
local EAST, NORTH = '+x:0:0', '+z:9:10'
local CONFIG = {world = {chunksize = 5}, planner = {weights = {slope = 4}, road_material = 'mcl_core:cobble'},
    composition = {road_material = 'mcl_core:cobble'}}

local function copy(v)
    if type(v) ~= 'table' then return v end
    local r = {}; for k, x in pairs(v) do r[k] = copy(x) end; return r
end

local function harness(options)
    options = options or {}
    local h = {time = 0, queue = {}, builds = {}, notices = {}, players = {}, cmds = {}, seed = '4242',
        pos = {x = 100, y = 0, z = 0}, hold_survey = options.hold_survey, planner_fail = options.planner_fail}
    h.fake = towns_fixture.new()
    local east = towns_fixture.exit({x = 1, z = 0}, 'flat', 2)
    local north = towns_fixture.exit({x = 0, z = 1}, 'flat', 2)
    for _, c in ipairs(north.columns) do c.x = c.x + 10; c.z = c.z + 10 end
    north.id = '+z:'..north.columns[1].x..':'..north.columns[1].z
    h.settlement = towns_fixture.settlement(SID, {east, north})
    h.fake.records[SID] = h.settlement
    h.fake.others = {h.settlement}
    h.storage = fx.storage()
    h.store = outward_store.new({storage = h.storage, serialize = fx.serialize, deserialize = fx.deserialize,
        now = function() return 1000 end})
    h.adapter = adapter.new(function() return h.fake.api end, function() return h.time end)
    local function after(delay, fn) h.queue[#h.queue + 1] = {at = h.time + delay, fn = fn, order = #h.queue} end
    h.terrain = {version = 1, owner = 'roads:outward', bounds = {min_x = -500, max_x = 500, min_y = -50, max_y = 50,
        min_z = -500, max_z = 500}, get_column = function() return {status = 'ok', ground_y = 1, material = 'mcl_core:dirt'} end}
    h.controller = assert(lifecycle.new({now = function() return h.time end, after = after,
        start_survey = function()
            local s = {state = 'running'}
            function s:status() return {status = self.state, metrics = {}} end
            function s:cancel() self.state = 'cancelled' end
            return s
        end,
        resolve_endpoints = function() return nil, {code = 'invalid_endpoint', reason = 'stub'} end,
        new_planner = function() return nil, {code = 'invalid_config', reason = 'stub'} end,
        compose = function() return nil, {code = 'composition_failed', reason = 'stub'} end}))
    local ops = {jobs = h.controller, towns = h.adapter, store = h.store,
        now = function() return h.time end, after = after,
        world_config = function() return CONFIG end,
        survey = {plan = function() return {chunks = {{ix = 0, iy = 0, iz = 0}}, chunk_count = 1} end},
        start_survey = function()
            local s = {state = h.hold_survey and 'running' or 'succeeded'}
            h.survey = s
            function s:status()
                return {status = self.state, terrain = self.state == 'succeeded' and h.terrain or nil, metrics = {}}
            end
            function s:cancel() self.state = 'cancelled' end
            return s
        end,
        exit_endpoints = function(_, descriptor, target)
            local a = descriptor.anchor
            return {start = {requested = {x = a.x, y = a.y + 0.5, z = a.z}, ground = copy(a),
                    resolved = {x = a.x + 20, y = 1, z = a.z}, connector = {origin = 'published_exit'}},
                goal = {requested = {x = target.x, y = 1.5, z = target.z}, ground = {x = target.x, y = 1, z = target.z},
                    resolved = {x = target.x, y = 1, z = target.z}}}
        end,
        new_planner = function(_, request)
            local planner = {}
            function planner:step()
                if h.planner_fail then
                    return {status = 'failed', metrics = {expansions = 30, states = 4, heap_peak = 3},
                        error = {code = 'bounded_no_route', reason = 'no route within bounds'}}
                end
                return {status = 'succeeded', metrics = {expansions = 120, states = 10, heap_peak = 8},
                    route = {request = request, centerline = {{x = request.start.x, y = 1, z = request.start.z},
                        {x = request.goal.x, y = 1, z = request.goal.z}}, headings = {2}, cost = 5,
                        metrics = {length = 20, ascent = 1, descent = 0, max_grade = 0.1, turn_count = 1, cut_count = 2, fill_count = 3}}}
            end
            function planner:cancel() self.cancelled = true end
            return planner
        end,
        compose = function(terrain, route)
            return {version = 2, connector_version = 1, owner = terrain.owner, endpoints = copy(route.request.provenance),
                request = copy(route.request), centerline = copy(route.centerline), headings = copy(route.headings),
                metrics = copy(route.metrics), writes = {{x = 30, y = 1, z = 0, kind = 'road'}, {x = 30, y = 2, z = 0, kind = 'air'}},
                expectations = {}}
        end,
        start_build = function(plan, done, guard)
            local b = {plan = plan, done = done, guard = guard}
            function b:cancel() self.cancelled = true end
            h.builds[#h.builds + 1] = b; h.build = b
            return b
        end,
        wrap_terrain = adapter.wrap_terrain,
        save_interval = function() return 5.3 end,
        notify = function(name, summary) h.notices[#h.notices + 1] = {name = name, summary = summary} end}
    h.service = assert(outward.new(ops))
    h.players.alice = {get_pos = function() return h.pos end,
        get_properties = function() return {collisionbox = {-0.3, 0, -0.3, 0.3, 1.7, 0.3}} end}

    -- Commands are registered through the same entry point init.lua uses.
    function h.commands_with(towns_obj, seed, preview)
        local registered = {}
        local engine = {register_chatcommand = function(name, def) registered[name] = def end,
            get_player_by_name = function(name) return h.players[name] end}
        assert(commands.register(engine, h.controller, surface, function() return CONFIG end, preview,
            {service = h.service, towns = towns_obj or h.adapter, policy = policy,
                seed = function() return seed or h.seed end}))
        return registered
    end
    h.cmds = h.commands_with()
    function h.run_cmd(name, player)
        local def = assert(h.cmds[name], name)
        return def.func(player or 'alice')
    end
    function h.step()
        table.sort(h.queue, function(a, b) if a.at ~= b.at then return a.at < b.at end return a.order < b.order end)
        local task = table.remove(h.queue, 1)
        if not task then return false end
        if task.at > h.time then h.time = task.at end
        task.fn()
        return true
    end
    function h.run_until(predicate, limit)
        for _ = 1, limit or 5000 do
            if predicate() then return true end
            if not h.step() then return predicate() end
        end
        error('condition not reached')
    end
    function h.run(limit)
        for _ = 1, limit or 5000 do if not h.step() then return end end
        error('queue did not drain')
    end
    function h.latest() return h.service:status(SID) end
    return h
end

test('/roads_outward is server-privileged and its help states terrain generation and automatic building', function()
    local h = harness()
    local def = assert(h.cmds.roads_outward)
    assert(def.privs and def.privs.server == true and def.params == '')
    local description = def.description:lower()
    assert(description:find('may generate terrain', 1, true), description)
    assert(description:find('automatically build', 1, true) and description:find('road', 1, true), description)
    assert(description:find('no endpoint', 1, true), description)
    assert(h.cmds.roads_status.privs.server == true and h.cmds.roads_cancel.privs.server == true)
    -- Without outward dependencies the command is absent and status/cancel stay manual.
    local bare = {}
    assert(commands.register({register_chatcommand = function(name, d) bare[name] = d end,
        get_player_by_name = function() return nil end}, h.controller, surface, function() return CONFIG end, nil))
    assert(bare.roads_outward == nil and bare.roads_status and bare.roads_cancel)
    local bad, why = commands.register({register_chatcommand = function() end}, h.controller, surface,
        function() return CONFIG end, nil, {service = h.service, towns = h.adapter, policy = policy})
    assert(bad == nil and why, 'a missing seed function is rejected')
end)

test('the command needs an online player and a readable world seed; failures write nothing', function()
    local h = harness()
    local ok, msg = h.run_cmd('roads_outward', 'nobody')
    assert(not ok and msg:find('online player', 1, true), msg)
    h.seed = nil
    ok, msg = h.run_cmd('roads_outward')
    assert(not ok and msg:find('unavailable: the world seed', 1, true), msg)
    assert(h.storage.sets == 0 and h.service.active == nil and h.controller.active == nil and #h.builds == 0)
end)

test('Towns absence and unsupported integration versions are reported and never reach the service', function()
    local h = harness()
    local absent = h.commands_with(adapter.new(function() return nil end))
    local ok, msg = absent.roads_outward.func('alice')
    assert(not ok and msg:find('towns_unavailable', 1, true), msg)
    h.fake.api.version = 2
    local unsupported = h.commands_with()
    ok, msg = unsupported.roads_outward.func('alice')
    assert(not ok and msg:find('towns_unsupported', 1, true), msg)
    h.fake.api.version = 1
    h.fake.healthy = false
    ok, msg = h.run_cmd('roads_outward')
    assert(not ok and msg:find('towns_unavailable', 1, true), msg)
    h.fake.healthy = true
    assert(h.storage.sets == 0 and h.service.active == nil and h.controller.active == nil)
end)

test('a request names settlement, exit and targets; status shows live stage and aggregate progress', function()
    local h = harness({hold_survey = true})
    local ok, msg = h.run_cmd('roads_outward')
    assert(ok, msg)
    assert(msg:find('Outward road '..SID..'/'..EAST..'#1 started', 1, true), msg)
    assert(msg:find('settlement '..SID..', exit '..EAST, 1, true), msg)
    assert(msg:find('targets (', 1, true) and msg:find('may generate terrain', 1, true), msg)
    -- The chosen targets are the policy's: between one and four, all distinct.
    local active = assert(h.service:status())
    assert(#active.candidates >= 1 and #active.candidates <= 4, #active.candidates)
    h.run_until(function() return h.service:status().stage == 'surveying' end)
    ok, msg = h.run_cmd('roads_status')
    assert(ok, msg)
    assert(msg:find('Outward road '..SID..'/'..EAST..'#1: planning, stage surveying.', 1, true), msg)
    assert(msg:find('Settlement '..SID..', exit '..EAST..', requested by alice.', 1, true), msg)
    -- The aggregate is live while the job runs, not only after it commits.
    assert(msg:find('Aggregate: 1 chunks (1 requests)', 1, true), 'live aggregate: ' .. msg)
    -- Finish the survey and every later stage; then the summary records the road.
    h.survey.state = 'succeeded'
    h.run_until(function() return h.build ~= nil end)
    ok, msg = h.run_cmd('roads_status')
    assert(msg:find('stage building', 1, true) or msg:find('stage durability_wait', 1, true), msg)
    h.build.done(nil, {writes = 2, pause_seconds = 0.01})
    ok, msg = h.run_cmd('roads_status')
    assert(ok and msg:find('Outward road '..SID..'/'..EAST..'#1: built.', 1, true), msg)
    assert(msg:find('Writes: all.', 1, true) and msg:find('Construction: 2 writes', 1, true), msg)
    assert(msg:find('Road to (', 1, true) and msg:find('length 20.0', 1, true), msg)
    -- Built reserves the whole settlement: a repeat is refused with the reason, not a silent retry.
    ok, msg = h.run_cmd('roads_outward')
    assert(not ok and msg:find('no_eligible_settlement', 1, true), msg)
    assert(msg:find('1 found, none open', 1, true) and msg:find(SID..' already has a built outward road.', 1, true), msg)
    assert(h.storage.sets > 0 and h.service.active == nil and h.controller.active == nil)
end)

test('an unrelated player has no outward record and an idle request reports no plan', function()
    local h = harness()
    local ok, msg = h.run_cmd('roads_status')
    assert(ok and msg == 'No road plan is active.', msg)
end)

test('a busy slot from a manual plan or an outward run is reported and nothing new starts', function()
    local h = harness({hold_survey = true})
    assert(h.controller:start_endpoint('alice', {x = 0, y = .5, z = 0}))
    assert(h.controller:plan('alice', {x = 8, y = .5, z = 0}, {world = {}, planner = {}, composition = {}}))
    local ok, msg = h.run_cmd('roads_outward')
    assert(not ok and msg:find('busy', 1, true), msg)
    assert(h.storage.sets == 0 and h.service.active == nil)
    h.controller:cancel('alice')
    ok, msg = h.run_cmd('roads_outward')
    assert(ok, msg)
    ok, msg = h.run_cmd('roads_outward', 'alice')
    assert(not ok and msg:find('busy: outward road '..SID..'/'..EAST..'#1 is planning', 1, true), msg)
    assert(h.service.active and #h.builds == 0)
end)

test('a request far from every settlement reports no eligible settlement with the search radius', function()
    local h = harness()
    h.pos = {x = 5000, y = 0, z = 0}
    local ok, msg = h.run_cmd('roads_outward')
    assert(not ok and msg:find('no_eligible_settlement', 1, true) and msg:find('512', 1, true), msg)
    assert(msg == 'no_eligible_settlement: no completed settlement within 512 nodes.', msg)
    assert(h.storage.sets == 0 and h.service.active == nil)
end)

test('a partial or uncertain exit is skipped and the other exit is used', function()
    local h = harness()
    local op = h.store:new_op(SID, EAST, {settlement_id = SID, requester = 'bob', source = {}, policy = {}, candidates = {},
        attempts = {}, aggregate = {}})
    op.state = 'partial'; op.writes = 'some'
    assert(h.store:save(SID, op))
    local ok, msg = h.run_cmd('roads_outward')
    assert(ok, msg)
    assert(msg:find('exit '..NORTH, 1, true) and not msg:find(EAST, 1, true), msg)
end)

test('cancellation releases the slot, records who cancelled, and the exit is open again', function()
    local h = harness({hold_survey = true})
    assert(h.run_cmd('roads_outward'))
    h.run_until(function() return h.service:status() and h.service:status().stage == 'surveying' end)
    local ok, msg = h.run_cmd('roads_cancel', 'alice')
    assert(ok and msg:find('Outward road cancelled', 1, true), msg)
    assert(h.service:status() == nil and h.controller.active == nil and h.service:eligibility(SID, EAST) == 'open')
    ok, msg = h.run_cmd('roads_status')
    assert(msg:find('cancelled', 1, true) and msg:find('Cancelled by alice', 1, true) and msg:find('Error cancelled', 1, true), msg)
    ok, msg = h.run_cmd('roads_cancel')
    assert(not ok and msg == 'there is no active road plan', msg)
    h.run()
    assert(#h.builds == 0 and h.latest().state == 'cancelled' and h.latest().writes == 'none')
    -- A fresh request after cancellation is allowed and gets a new sequence number.
    ok, msg = h.run_cmd('roads_outward')
    assert(ok and msg:find('#2 started', 1, true), msg)
end)

test('blocked terrain fails with a precise per-target report and no construction', function()
    local h = harness({planner_fail = true})
    local ok, msg = h.run_cmd('roads_outward')
    assert(ok, msg)
    h.run()
    assert(#h.builds == 0 and h.latest().state == 'failed' and h.latest().writes == 'none')
    ok, msg = h.run_cmd('roads_status')
    assert(ok and msg:find('Outward road '..SID..'/'..EAST..'#1: failed.', 1, true), msg)
    assert(msg:find('Error bounded_no_route: no route within bounds.', 1, true), msg)
    assert(msg:find('Attempt 1 to (', 1, true) and msg:find('bounded_no_route - no route within bounds.', 1, true), msg)
    assert(msg:find('Writes: none.', 1, true), msg)
    -- A failed attempt keeps the exit open for an explicit retry.
    assert(h.service:eligibility(SID, EAST) == 'open')
end)

test('presentation shows an exhausted shared budget and a failure position precisely', function()
    local text = commands.outward_summary({op_id = 'auto:3:-2/+x:0:0#1', settlement_id = SID, exit_id = EAST,
        state = 'failed', writes = 'none', requester = 'bob', candidates = {{x = 100, z = 0}},
        aggregate = {chunks = 97, chunk_requests = 120, expansions = 3, limit_reached = 'chunks', limit = 96, observed = 97},
        error = {code = 'survey_budget', reason = 'every target would exceed the shared budget', limit = 96, observed = 97},
        persisted = false})
    assert(text:find('Shared chunks budget reached (limit 96, observed 97).', 1, true), text)
    assert(text:find('Error survey_budget: every target would exceed the shared budget (limit 96, observed 97).', 1, true), text)
    assert(text:find('Warning: the record could not be saved', 1, true), text)
    local at = commands.outward_summary({op_id = 'x', state = 'failed', error = {code = 'towns_conflict',
        reason = 'road write lies inside Towns area', position = {x = 4, y = 2, z = -7}}})
    assert(at:find('towns_conflict: road write lies inside Towns area at (4.0, 2.0, -7.0).', 1, true), at)
    assert(commands.outward_summary(nil) == 'No outward road is active or recorded for this settlement.')
end)

test('a realistic 64-bit world seed from the command path starts a run and persists the text', function()
    local h = harness()
    h.seed = '-8335498217344751253'
    local ok, msg = h.run_cmd('roads_outward')
    assert(ok, msg)
    assert(h.service:status().state == 'planning' and h.service:status().settlement_id == SID)
    assert(h.storage.data['outward/v1/settlement/'..SID]:find('-8335498217344751253', 1, true), 'seed persisted as text')
end)

test('route geometry is bounded, starts and ends on the road, and shows the terminal heading', function()
    local line = {}
    for i = 1, 150 do line[i] = {x = i, y = 1, z = 0} end
    local text = commands.outward_summary({op_id = 'op#1', state = 'built', writes = 'all', settlement_id = SID,
        exit_id = EAST, requester = 'alice', candidates = {{x = 200, z = 0}},
        road = {requested_target = {x = 200, z = 0}, resolved_target = {x = 200, z = 0}, terminal = {x = 150, y = 1, z = 0},
            landing = {x = 7, y = 1, z = 0}, outward = {x = 1, z = 0}, terminal_heading = 0, centerline = line,
            metrics = {length = 149}, write_count = 3}})
    local segment = text:match('waypoints (.-); terminal')
    assert(segment, text)
    local points = {}
    for x in segment:gmatch('%((%-?%d+%.%d), ') do points[#points + 1] = tonumber(x) end
    assert(#points >= 2 and #points <= 8, #points)
    assert(points[1] == 1.0 and points[#points] == 150.0, 'start and end are included')
    assert(text:find('150 centreline nodes', 1, true), text)
    assert(text:find('landing (7.0, 1.0, 0.0), outward (1, 0)', 1, true), text)
    assert(text:find('terminal (150.0, 1.0, 0.0), heading 0 toward (1, 0).', 1, true), text)
    -- A short route is sampled every node-stride and never padded.
    local short = commands.outward_summary({op_id = 'op#2', state = 'built', road = {landing = {x = 0, y = 0, z = 0},
        outward = {x = 0, z = 1}, terminal = {x = 0, y = 0, z = 3}, terminal_heading = 2,
        centerline = {{x = 0, y = 0, z = 0}, {x = 0, y = 0, z = 1}, {x = 0, y = 0, z = 3}}}})
    assert(short:find('3 centreline nodes, waypoints (0.0, 0.0, 0.0), (0.0, 0.0, 3.0);', 1, true), short)
    -- Operations with no road show no geometry.
    assert(not commands.outward_summary({op_id = 'op#3', state = 'planning'}):find('Route geometry', 1, true))
end)

test('/roads_preview shows the outward centreline when no manual plan exists', function()
    local shown = {}
    local renderer = {show = function(_, owner, centerline, endpoints)
        shown[#shown + 1] = {owner = owner, count = #centerline, endpoints = endpoints}
        return #centerline
    end}
    local h = harness()
    local cmds = h.commands_with(nil, nil, renderer)
    local ok, msg = cmds.roads_outward.func('alice')
    assert(ok, msg)
    h.run_until(function() return h.build ~= nil end)
    h.build.done(nil, {writes = 2, pause_seconds = 0})
    ok, msg = cmds.roads_preview.func('alice')
    assert(ok and msg:find('temporary route markers', 1, true), msg)
    assert(shown[1].owner == 'alice' and shown[1].count == 2 and shown[1].endpoints == nil)
    -- Someone else has nothing to preview.
    h.players.bob = h.players.alice
    ok, msg = cmds.roads_preview.func('bob')
    assert(not ok and msg ~= nil and #shown == 1, msg)
end)

print('ok - ' .. count .. ' outward command tests')
