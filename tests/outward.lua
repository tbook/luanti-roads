-- SPDX-License-Identifier: GPL-3.0-or-later
local outward = dofile('src/outward.lua')
local outward_store = dofile('src/outward_store.lua')
local adapter = dofile('src/towns_adapter.lua')
local lifecycle = dofile('src/jobs.lua')
local towns_fixture = dofile('tests/towns_fixture.lua')
local fx = dofile('tests/outward_fixture.lua')
local count = 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if not ok then error('outward '..name..': '..tostring(err)) end
    count = count + 1
end

local SID = 'auto:3:-2'
local EAST, NORTH = '+x:0:0', '+z:10:10'
local function copy(v)
    if type(v) ~= 'table' then return v end
    local r = {}; for k, x in pairs(v) do r[k] = copy(x) end; return r
end

-- Pipeline harness. Surveys, planning, composition and building are scripted
-- fakes; Towns, the store, the job slot and the service are the real modules.
local function harness(options)
    options = options or {}
    local h = {time = 0, queue = {}, builds = {}, surveys = {}, planners = {}, endpoint_calls = {}, notices = {},
        behavior = options.behavior or {}, composed = 0, logs = {}}
    h.fake = options.fake or towns_fixture.new()
    local second = towns_fixture.exit({x=0, z=1}, 'flat', 2)
    for _, c in ipairs(second.columns) do c.x = c.x + 10; c.z = c.z + 10 end
    second.id = NORTH
    h.settlement = towns_fixture.settlement(SID, {towns_fixture.exit({x=1, z=0}, 'flat', 2), second})
    if not options.fake then h.fake.records[SID] = h.settlement end
    h.storage = options.storage or fx.storage()
    local function make_store()
        return outward_store.new({storage = h.storage, serialize = fx.serialize, deserialize = fx.deserialize,
            now = function() return 1000 + h.time end})
    end
    h.make_store = make_store
    h.store = make_store()
    h.adapter = adapter.new(function() return h.fake.api end, function() return h.time end)
    local function after(delay, fn)
        if h.schedule_error then error('scheduler unavailable') end
        h.queue[#h.queue+1] = {at = h.time + delay, fn = fn, order = #h.queue}
    end
    h.after = after
    h.terrain = {version = 1, owner = 'roads:outward',
        bounds = {min_x = -200, max_x = 200, min_y = -50, max_y = 50, min_z = -200, max_z = 200},
        get_column = function(x, z) return {status = 'ok', ground_y = 1, material = 'mcl_core:dirt'} end}
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
    local config = {world = {chunksize = 5}, planner = {weights = {slope = 4}, road_material = 'mcl_core:cobble'},
        composition = {road_material = 'mcl_core:cobble'}}
    local function behavior_for(x) return h.behavior[x] or {} end
    local ops = {jobs = h.controller, towns = h.adapter, store = h.store,
        now = function() return h.time end, after = after,
        world_config = function() if h.world_error then return nil, {code = 'unsupported_world', reason = 'no world'} end return config end,
        survey = options.survey or {plan = function(a, b, world)
            h.survey_plans = (h.survey_plans or 0) + 1
            if h.behavior.plan_error and h.behavior.plan_error[b.x] then return nil, h.behavior.plan_error[b.x] end
            local chunks = {{ix = 0, iy = 0, iz = 0}, {ix = math.floor(b.x / 80), iy = 0, iz = 0}}
            if h.behavior.extra_chunks and h.behavior.extra_chunks[b.x] then
                for i = 1, h.behavior.extra_chunks[b.x] do chunks[#chunks+1] = {ix = 1000 + b.x, iy = i, iz = 0} end
            end
            return {chunks = chunks, chunk_count = #chunks}
        end},
        start_survey = function(a, b, owner, world)
            h.surveys[#h.surveys+1] = {first = a, second = b, owner = owner}
            local beh = behavior_for(b.x)
            if beh.survey_start_error then return nil, beh.survey_start_error end
            local s = {state = h.hold_survey and 'running' or (beh.survey_error and 'failed' or 'succeeded')}
            function s:status()
                return {status = self.state, terrain = self.state == 'succeeded' and (options.terrain or h.terrain) or nil,
                    error = self.state == 'failed' and beh.survey_error or nil, metrics = {}}
            end
            function s:cancel() self.cancelled = true; self.state = 'cancelled' end
            h.surveys[#h.surveys].job = s; h.survey = s
            return s
        end,
        exit_endpoints = options.exit_endpoints or function(terrain, descriptor, target)
            h.endpoint_calls[#h.endpoint_calls+1] = {terrain = terrain, descriptor = descriptor, target = target}
            local beh = behavior_for(target.x)
            if beh.endpoint_error then return nil, beh.endpoint_error end
            local anchor = descriptor.anchor
            return {start = {requested = {x = anchor.x, y = anchor.y + 0.5, z = anchor.z}, ground = copy(anchor),
                    resolved = {x = anchor.x + 20, y = 1, z = anchor.z}, connector = {origin = 'published_exit'}},
                goal = {requested = {x = target.x, y = 1.5, z = target.z}, ground = {x = target.x, y = 1, z = target.z},
                    resolved = {x = target.x, y = 1, z = target.z}}}
        end,
        new_planner = options.new_planner or function(terrain, request, config2)
            local beh = behavior_for(request.goal.x)
            local planner = {calls = 0, config = config2, request = request}
            h.planners[#h.planners+1] = planner
            h.planner = planner
            function planner:step(budget, clock)
                self.calls = self.calls + 1
                self.budget = budget
                local slices = beh.slices or 2
                local total = beh.expansions or 100
                local so_far = math.min(total, self.calls * math.ceil(total / slices))
                if so_far > self.config.max_expansions then
                    return {status = 'failed', metrics = {expansions = self.config.max_expansions, states = 9, heap_peak = 7},
                        error = {code = 'expansion_budget', reason = 'expansion limit reached', limit = self.config.max_expansions,
                            observed = self.config.max_expansions}}
                end
                if self.calls < slices then return {status = 'running', metrics = {expansions = so_far, states = 5, heap_peak = 4}} end
                if beh.fail then
                    return {status = 'failed', metrics = {expansions = so_far, states = 8, heap_peak = 6},
                        error = {code = beh.fail, reason = 'scripted failure '..beh.fail}}
                end
                return {status = 'succeeded', metrics = {expansions = so_far, states = 10, heap_peak = 8},
                    route = {request = request, centerline = {{x = request.start.x, y = 1, z = request.start.z},
                        {x = request.goal.x, y = 1, z = request.goal.z}}, headings = {2}, cost = 5,
                        metrics = {length = 20, ascent = 1, descent = 0, max_grade = 0.1, turn_count = 1, cut_count = 2, fill_count = 3}}}
            end
            function planner:cancel() self.cancelled = true end
            return planner
        end,
        compose = function(terrain, route, config2)
            h.composed = h.composed + 1
            local beh = behavior_for(route.request.goal.x)
            if beh.compose_error then return nil, beh.compose_error end
            return {version = 2, connector_version = 1, owner = terrain.owner, endpoints = copy(route.request.provenance),
                request = copy(route.request), centerline = copy(route.centerline), headings = copy(route.headings),
                metrics = copy(route.metrics), writes = {{x = 30, y = 1, z = 0, kind = 'road'}, {x = 30, y = 2, z = 0, kind = 'air'}},
                expectations = {{x = 30, y = 1, z = 0, kind = 'natural', material = 'mcl_core:dirt', protected = false}}}
        end,
        start_build = options.start_build or function(plan, done, guard)
            local b = {plan = plan, done = done, guard = guard, cancelled = false}
            function b:cancel() self.cancelled = true end
            h.builds[#h.builds+1] = b; h.build = b
            return b
        end,
        wrap_terrain = adapter.wrap_terrain,
        save_interval = function() return h.save_interval or 5.3 end,
        notify = function(name, summary) h.notices[#h.notices+1] = {name = name, summary = summary} end,
        log = function(level, message) h.logs[#h.logs+1] = level..': '..message end}
    h.ops = ops
    h.service = assert(outward.new(ops))
    -- A restart: a fresh store and service over the same storage and Towns.
    function h.restart()
        h.store = make_store()
        ops.store = h.store
        h.controller.active = nil
        h.service = assert(outward.new(ops))
        return h.service:recover()
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
        for _ = 1, limit or 5000 do if not h.step() then return end end
        error('queue did not drain')
    end
    function h.run_until(predicate, limit)
        for _ = 1, limit or 5000 do
            if predicate() then return true end
            if not h.step() then return predicate() end
        end
        error('condition not reached')
    end
    function h.stage() local s = h.service:status(); return s and s.stage end
    function h.request(overrides)
        local r = {settlement_id = SID, exit_id = EAST, requester = 'alice', policy = {version = 1, seed = 42},
            candidates = {{x = 100, z = 0}}}
        for k, v in pairs(overrides or {}) do r[k] = v end
        return r
    end
    function h.latest() return h.service:status(SID) end
    function h.doc() return h.store:doc(SID) end
    return h
end

-- Drive one request all the way to a build that is waiting for the builder.
local function to_build(h, overrides)
    local started = assert(h.service:start(h.request(overrides)))
    h.run_until(function() return h.build ~= nil end)
    return started
end

test('requests are validated before anything else happens', function()
    local h = harness()
    local bad = {
        {candidates = {}}, {candidates = {{x=1, z=1}, {x=2, z=1}, {x=3, z=1}, {x=4, z=1}, {x=5, z=1}}},
        {candidates = {{x=1, z=1}, {x=1, z=1}}}, {candidates = {{x=1.5, z=1}}}, {candidates = {{x=1}}},
        {candidates = 'x'}, {settlement_id = ''}, {exit_id = 5}, {requester = ''}, {policy = 'seed'},
    }
    for i, change in ipairs(bad) do
        local r, e = h.service:start(h.request(change))
        assert(not r and e.code == 'invalid_request', i)
    end
    local r, e = h.service:start(nil); assert(not r and e.code == 'invalid_request')
    assert(h.controller.active == nil and h.storage.sets == 0 and #h.surveys == 0)
end)

test('optional Towns absence and ineligible settlements fail before any slot, record or work', function()
    local h = harness()
    local missing = adapter.new(function() return nil end)
    h.ops.towns = missing
    local service = assert(outward.new(h.ops))
    local r, e = service:start(h.request()); assert(not r and e.code == 'towns_unavailable')
    h.ops.towns = h.adapter
    service = assert(outward.new(h.ops))
    for _, status in ipairs({'not_found', 'incomplete', 'unsupported', 'invalid', 'unavailable'}) do
        h.fake.records['auto:9:9'] = nil; h.fake.statuses['auto:9:9'] = status
        r, e = service:start(h.request({settlement_id = 'auto:9:9'}))
        assert(not r and e.code == 'ineligible_settlement' and e.status == status, status)
    end
    r, e = service:start(h.request({exit_id = '+x:99:99'})); assert(not r and e.code == 'unsupported_exit')
    h.fake.version = nil; h.fake.api.version = 2
    r, e = service:start(h.request()); assert(not r and e.code == 'towns_unsupported')
    h.fake.api.version = 1
    h.world_error = true
    r, e = service:start(h.request()); assert(not r and e.code == 'unsupported_world', e and e.code)
    assert(h.controller.active == nil and h.storage.sets == 0 and #h.surveys == 0)
    assert(service:status(SID) == nil and service:status() == nil)
end)

test('a request completes: durable intent precedes construction, then the settlement is reserved', function()
    local h = harness()
    local started = assert(h.service:start(h.request()))
    assert(started.state == 'planning' and started.op_id == SID..'/'..EAST..'#1')
    assert(h.controller.active and h.controller.active.holder.kind == 'outward')
    assert(h.service:status().stage == 'planning' and h.service:eligibility(SID, EAST) == 'active')
    assert(h.controller:status('alice').slot.stage == 'planning')
    local doc = fx.deserialize(h.storage.data[outward_store.PREFIX..SID])
    assert(doc.operations[1].state == 'planning' and doc.operations[1].writes == 'none') -- durable before any work
    assert(doc.operations[1].source.exit_id == EAST and doc.operations[1].policy.seed == 42)
    h.run_until(function() return h.stage() == 'durability_wait' end)
    doc = fx.deserialize(h.storage.data[outward_store.PREFIX..SID])
    local op = doc.operations[1]
    -- Intended road and continuation information are on disk before the builder exists.
    assert(#h.builds == 0 and op.state == 'building' and op.writes == 'unknown')
    assert(op.road.chosen_index == 1 and op.road.requested_target.x == 100 and #op.road.centerline == 2)
    assert(op.road.terminal.x == 100 and op.road.terminal_heading == 2 and op.road.outward.x == 1)
    assert(op.road.write_count == 2 and op.road.footprint.x1 == 30 and op.road.metrics.length == 20)
    assert(op.aggregate.expansions == 100 and op.aggregate.chunks == 2)
    local waited_from = h.time
    h.run_until(function() return h.build ~= nil end)
    assert(h.time - waited_from >= 6.3 - 1e-9) -- one map save interval plus a second
    assert(h.service:status().stage == 'building' and h.build.guard and h.build.plan.owner == 'roads:outward')
    assert(h.surveys[1].owner == 'roads:outward' and h.surveys[1].first.x == 0 and h.surveys[1].second.x == 100)
    h.build.done(nil, {writes = 2, pause_seconds = 0.01})
    assert(h.controller.active == nil and h.service.active == nil)
    local status = h.latest()
    assert(status.state == 'built' and status.writes == 'all' and not status.active and status.build.writes == 2)
    assert(status.requester == 'alice' and h.notices[#h.notices].summary.state == 'built')
    -- Reserved for the whole settlement, in this session and after restart.
    for _, exit_id in ipairs({EAST, NORTH}) do
        local r, e = h.service:start(h.request({exit_id = exit_id}))
        assert(not r and e.code == 'already_reserved' and e.scope == 'settlement', exit_id)
    end
    assert(h.service:eligibility(SID, NORTH) == 'reserved')
    local sets = h.storage.sets
    local summary = h.restart(); assert(summary.settlements == 1 and summary.converted == 0)
    local r, e = h.service:start(h.request({exit_id = NORTH})); assert(not r and e.code == 'already_reserved')
    h.run(); assert(#h.builds == 1 and h.storage.sets == sets and h.latest().state == 'built')
    assert(h.latest().road.terminal_heading == 2)
end)

test('shared slot: busy against manual and outward work, no queue, disconnect does not cancel', function()
    local h = harness()
    assert(h.controller:start_endpoint('alice', {x = 0, y = .5, z = 0}))
    assert(h.controller:plan('alice', {x = 8, y = .5, z = 0}, {world = {}, planner = {}, composition = {}}))
    local r, e = h.service:start(h.request()); assert(not r and e.code == 'busy')
    assert(h.storage.sets == 0 and #h.surveys == 0 and h.service.active == nil)
    h.controller:cancel('alice')
    assert(h.service:start(h.request()))
    r, e = h.service:start(h.request({exit_id = NORTH})); assert(not r and e.code == 'busy')
    assert(h.controller:start_endpoint('bob', {x = 0, y = .5, z = 0}))
    r, e = h.controller:plan('bob', {x = 8, y = .5, z = 0}, {}); assert(not r and e.code == 'busy')
    h.controller:disconnect('alice')
    assert(h.service.active and h.controller.active.holder)
    h.run_until(function() return h.build ~= nil end)
    h.controller:disconnect('alice')
    assert(h.service.active and not h.build.cancelled)
    h.build.done(nil, {writes = 2})
    assert(h.latest().state == 'built' and h.latest().requester == 'alice')
end)

test('a ready manual plan keeps the slot', function()
    local h = harness()
    h.controller.active = {owner = 'alice', state = 'ready'}
    local r, e = h.service:start(h.request()); assert(not r and e.code == 'busy')
    assert(h.storage.sets == 0)
end)

test('cancellation is honoured in every stage and late callbacks do nothing', function()
    for _, stage in ipairs({'surveying', 'waiting_towns', 'searching', 'durability_wait', 'building'}) do
        local h = harness({behavior = {[100] = {slices = 4}}})
        if stage == 'surveying' then h.hold_survey = true end
        if stage == 'waiting_towns' then h.fake.writer_state = {kind = 'automatic', phase = 'build', since = 0} end
        assert(h.service:start(h.request()))
        h.run_until(function() return h.stage() == stage end)
        local survey_job = h.survey
        local planner = h.planner
        local build = h.build
        assert(h.controller:cancel('carol'), stage)
        assert(h.service.active == nil and h.controller.active == nil)
        local status = h.latest()
        assert(status.state == 'cancelled' and status.writes == 'none' and status.cancelled_by == 'carol', stage)
        assert(status.error.code == 'cancelled')
        if stage == 'surveying' then assert(survey_job.cancelled) end
        if stage == 'searching' then assert(planner.cancelled) end
        if stage == 'building' then assert(build.cancelled) end
        -- Late survey, writer, search, durability and builder callbacks are ignored.
        h.fake.writer_state = nil
        if survey_job then survey_job.state = 'succeeded' end
        local calls = #h.endpoint_calls
        local builds = #h.builds
        h.run()
        if build then build.done(nil, {writes = 2}) end
        assert(#h.endpoint_calls == calls and #h.builds == builds and h.latest().state == 'cancelled', stage)
        assert(h.service:eligibility(SID, EAST) == 'open')
        local r, e = h.service:cancel('carol'); assert(not r and e.code == 'no_plan')
        -- The exit is free again and persisted as cancelled with no writes.
        assert(h.restart().converted == 0 and h.latest().state == 'cancelled')
        assert(h.service:start(h.request()))
    end
end)

test('cancellation during a build wait never leaves a stale persisted building record', function()
    local h = harness()
    to_build(h)
    h.service:cancel('alice')
    h.restart()
    assert(h.service:eligibility(SID, EAST) == 'open' and h.latest().state == 'cancelled')
end)

test('multiple candidates share one expansion budget and chunk coverage', function()
    local h = harness({behavior = {[100] = {fail = 'bounded_no_route', expansions = 60000, slices = 3},
        [160] = {fail = 'bounded_no_route', expansions = 60000, slices = 3},
        [200] = {expansions = 100000, slices = 4}}})
    assert(h.service:start(h.request({candidates = {{x = 100, z = 0}, {x = 160, z = 5}, {x = 200, z = 9}}})))
    h.run()
    assert(#h.planners == 3 and #h.builds == 0 and h.composed == 0)
    assert(h.planners[1].config.max_expansions == 150000 and h.planners[2].config.max_expansions == 90000
        and h.planners[3].config.max_expansions == 30000)
    local status = h.latest()
    assert(status.state == 'failed' and status.writes == 'none' and status.error.code == 'expansion_budget')
    assert(status.error.limit == 150000 and status.error.observed == 150000)
    assert(status.aggregate.limit_reached == 'expansions' and status.aggregate.expansions == 150000)
    assert(#status.attempts == 3 and status.attempts[1].outcome == 'bounded_no_route' and status.attempts[2].expansions == 60000)
    -- Chunk (0,0,0) is shared by all and (2,0,0) by the last two: 3 distinct chunks, 6 requests.
    assert(status.aggregate.chunks == 3 and status.aggregate.chunk_requests == 6)
    assert(status.attempts[1].chunks_new == 2 and status.attempts[2].chunks_new == 1 and status.attempts[3].chunks_new == 0)
    assert(h.service:eligibility(SID, EAST) == 'open') -- zero writes never block anything
end)

test('a later candidate that composes is the only road ever built; failed attempts leave no fragments', function()
    local h = harness({behavior = {[100] = {fail = 'bounded_no_route'},
        [140] = {compose_error = {code = 'composition_failed', reason = 'overlap', position = {x = 1, y = 2, z = 3}}},
        [60] = {endpoint_error = {code = 'invalid_endpoint', reason = 'water'}}}})
    to_build(h, {candidates = {{x = 100, z = 0}, {x = 140, z = 0}, {x = 60, z = 0}, {x = 180, z = 0}}})
    assert(#h.builds == 1 and h.build.plan.request.goal.x == 180)
    local op = h.latest()
    assert(op.attempts[1].outcome == 'bounded_no_route' and op.attempts[2].outcome == 'composition_failed'
        and op.attempts[2].position.x == 1 and op.attempts[3].outcome == 'invalid_endpoint' and op.attempts[4].outcome == 'composed')
    assert(op.road.chosen_index == 4 and op.road.requested_target.x == 180)
    h.build.done(nil, {writes = 2}); assert(h.latest().state == 'built')
    assert(h.composed == 2) -- only composed candidates reach composition
end)

test('when every candidate fails the final error is the deciding attempt', function()
    local h = harness({behavior = {[100] = {fail = 'bounded_no_route'}, [140] = {endpoint_error = {code = 'invalid_endpoint', reason = 'last'}}}})
    assert(h.service:start(h.request({candidates = {{x = 100, z = 0}, {x = 140, z = 0}}}))); h.run()
    local s = h.latest(); assert(s.state == 'failed' and s.error.code == 'invalid_endpoint' and s.error.reason == 'last' and #h.builds == 0)
end)

test('the chunk budget skips an over-budget target and continues', function()
    -- Target 100 uses 92 distinct chunks and fails; 160 would raise the total to 103 and is skipped
    -- without a survey; 40 reuses already covered chunks and succeeds.
    local h = harness({behavior = {[100] = {fail = 'bounded_no_route'}, extra_chunks = {[100] = 90, [160] = 10}}})
    assert(h.service:start(h.request({candidates = {{x = 100, z = 0}, {x = 160, z = 0}, {x = 40, z = 0}}})))
    h.run_until(function() return h.build ~= nil end)
    local op = h.latest()
    assert(op.attempts[1].outcome == 'bounded_no_route' and op.attempts[1].chunks_new == 92)
    assert(op.attempts[2].outcome == 'survey_budget' and op.attempts[2].reason:find('96') and op.attempts[2].chunks_new == 0)
    assert(op.attempts[3].outcome == 'composed' and op.attempts[3].chunks_new == 0 and op.road.chosen_index == 3)
    assert(#h.surveys == 2 and op.aggregate.chunks == 92 and op.aggregate.chunk_requests == 92 + 2)
    h.build.done(nil, {writes = 2})
    -- Every candidate over budget: the aggregate budget error, and not even one survey.
    h = harness({behavior = {extra_chunks = {[160] = 100, [170] = 100}}})
    assert(h.service:start(h.request({candidates = {{x = 160, z = 0}, {x = 170, z = 0}}}))); h.run()
    local s = h.latest()
    assert(s.error.code == 'survey_budget' and s.error.limit == 96 and s.aggregate.limit_reached == 'chunks'
        and #h.surveys == 0 and s.writes == 'none' and #s.attempts == 2)
end)

test('preflight and survey failures move on to the next candidate', function()
    local h = harness({behavior = {plan_error = {[100] = {code = 'survey_budget', reason = 'endpoint separation exceeds 192 nodes'}},
        [140] = {survey_error = {code = 'survey_timeout', reason = 'no progress'}},
        [60] = {survey_start_error = {code = 'survey_failed', reason = 'cannot start'}}}})
    to_build(h, {candidates = {{x = 100, z = 0}, {x = 140, z = 0}, {x = 60, z = 0}, {x = 30, z = 0}}})
    local att = h.latest().attempts
    assert(att[1].outcome == 'survey_budget' and att[2].outcome == 'survey_timeout' and att[3].outcome == 'survey_failed'
        and att[4].outcome == 'composed')
    h.service:cancel('x')
end)

test('Towns writer coordination: emergence-triggered writer and candidate delay the plan, then exclude the area', function()
    local h = harness()
    -- Emergence finishes, but Towns has already taken the lock and registered a candidate (G3).
    h.hold_survey = true
    assert(h.service:start(h.request()))
    h.run_until(function() return h.stage() == 'surveying' end)
    h.fake.writer_state = {kind = 'automatic', phase = 'loading', since = 5}
    h.fake.items[#h.fake.items+1] = {id = 'site:7', kind = 'candidate', state = 'contacted',
        rects = {{x1 = 90, z1 = -10, x2 = 110, z2 = 10}}, y_min = -31000, y_max = 31000}
    h.survey.state = 'succeeded'
    h.run_until(function() return h.stage() == 'waiting_towns' end)
    for _ = 1, 20 do h.step() end
    assert(#h.endpoint_calls == 0 and h.stage() == 'waiting_towns')
    -- Towns finishes and publishes a settlement that covers part of the survey.
    local newcomer = towns_fixture.settlement('auto:8:8')
    newcomer.core = {x1 = 60, z1 = 20, x2 = 80, z2 = 40}; newcomer.structures = {}
    h.fake.exclude_settlement(newcomer)
    h.fake.writer_state = nil
    h.run_until(function() return #h.endpoint_calls == 1 end)
    local terrain = h.endpoint_calls[1].terrain
    assert(terrain.get_column(100, 0).status == 'structure') -- candidate area
    assert(terrain.get_column(70, 30).status == 'structure') -- newly published settlement
    assert(terrain.get_column(70, 50).status == 'ok')
    assert(h.endpoint_calls[1].descriptor.exit_id == EAST)
    h.service:cancel('x')
end)

test('a writer busy past 180 seconds fails the attempt with towns_busy and zero writes', function()
    local h = harness()
    h.fake.writer_state = {kind = 'manual', phase = 'build', since = 0}
    assert(h.service:start(h.request()))
    h.run()
    local s = h.latest()
    assert(s.state == 'failed' and s.error.code == 'towns_busy' and s.writes == 'none' and #h.builds == 0)
    assert(h.time >= 180 and h.time < 200 and h.fake.calls.writer > 100)
    assert(h.service:eligibility(SID, EAST) == 'open')
    -- Unhealthy exclusions are never read as "no towns".
    h.fake.writer_state = nil; h.fake.exclusions_error = 'down'
    assert(h.service:start(h.request())); h.run()
    assert(h.latest().error.code == 'towns_unavailable' and #h.builds == 0)
end)

test('construction is guarded: Towns writing defers, a new settlement blocks with zero writes', function()
    local h = harness()
    to_build(h)
    local guard = h.build.guard
    local plan = h.build.plan
    assert(guard(plan) == 'ok')
    h.fake.writer_state = {kind = 'automatic', phase = 'build', since = 1}
    assert(guard(plan) == 'defer')
    h.fake.writer_state = nil
    local newcomer = towns_fixture.settlement('auto:8:8'); newcomer.core = {x1 = 25, z1 = -5, x2 = 35, z2 = 5}
    newcomer.structures = {}; h.fake.exclude_settlement(newcomer)
    local verdict, err = guard(plan); assert(verdict == 'fail' and err.code == 'towns_conflict')
    h.build.done(err)
    local s = h.latest(); assert(s.state == 'failed' and s.writes == 'none' and s.error.code == 'towns_conflict')
    assert(h.service:eligibility(SID, EAST) == 'open')
end)

test('a changed published exit is refused before the intent is saved', function()
    local h = harness()
    h.hold_survey = false
    assert(h.service:start(h.request()))
    h.run_until(function() return h.stage() == 'searching' end)
    h.settlement.exits[1].profile[1].y = 5
    h.run()
    local s = h.latest()
    assert(s.state == 'failed' and s.error.code == 'stale_exit' and s.writes == 'none' and #h.builds == 0)
    local op = h.doc().operations[1]; assert(op.state == 'failed' and not op.road)
end)

test('storage failure at accept starts no work; a failed commit save makes zero writes', function()
    local h = harness()
    h.storage.fail_set = true
    local r, e = h.service:start(h.request()); assert(not r and e.code == 'storage_failed')
    assert(h.controller.active == nil and #h.surveys == 0 and #h.doc().operations == 0 and h.doc().next_seq == 1)
    h.storage.fail_set = nil
    assert(h.service:start(h.request()).op_id == SID..'/'..EAST..'#1') -- the aborted sequence number is reusable
    h.storage.fail_set = function(key, value) return value:find('"building"') ~= nil end
    h.run()
    local s = h.latest()
    assert(s.state == 'failed' and s.writes == 'none' and s.error.code == 'storage_failed' and #h.builds == 0)
    assert(not h.doc().operations[1].road)
    assert(h.service:eligibility(SID, EAST) == 'open' and h.controller.active == nil)
end)

test('a mismatching read-back at commit leaves a durable building record that restart treats as uncertain', function()
    local h = harness()
    assert(h.service:start(h.request()))
    h.run_until(function() return h.stage() == 'searching' end)
    h.storage.fail_set = function(key, value)
        if value:find('"building"') then h.storage.mismatch = true end
        return false
    end
    h.run_until(function() return h.service.active == nil end)
    h.storage.mismatch = false
    assert(h.latest().state == 'failed' and h.latest().writes == 'none' and #h.builds == 0)
    -- Best-effort cleanup replaced the building record.
    h.storage.fail_set = nil
    local summary = h.restart(); assert(summary.converted == 0)
    assert(h.service:eligibility(SID, EAST) == 'open')
end)

test('storage failure after a successful build keeps the exit reserved now and after restart', function()
    local h = harness()
    to_build(h)
    h.storage.fail_set = true
    h.build.done(nil, {writes = 2})
    local s = h.latest()
    assert(s.state == 'built' and s.writes == 'all' and s.persisted == false and h.controller.active == nil)
    assert(h.logs[#h.logs]:find('cannot save'))
    local r, e = h.service:start(h.request({exit_id = NORTH})); assert(not r and e.code == 'already_reserved')
    -- The disk still says "building": restart sees possibly written work and reserves the exit.
    h.storage.fail_set = nil
    local summary = h.restart(); assert(summary.converted == 1)
    s = h.latest(); assert(s.state == 'interrupted' and s.writes == 'unknown')
    r, e = h.service:start(h.request({exit_id = EAST})); assert(not r and e.code == 'already_reserved' and e.scope == 'exit')
    assert(h.service:eligibility(SID, NORTH) == 'open') -- other exits stay eligible
    assert(h.service:start(h.request({exit_id = NORTH})))
end)

test('a partial build reserves only its own exit; other exits still build, once', function()
    local h = harness()
    to_build(h)
    h.build.done({code = 'partial_build', reason = 'stopped after 1 writes'}, {writes = 1})
    local s = h.latest(); assert(s.state == 'partial' and s.writes == 'some' and s.error.code == 'partial_build')
    assert(h.controller.active == nil)
    local r, e = h.service:start(h.request({exit_id = EAST})); assert(not r and e.code == 'already_reserved' and e.scope == 'exit')
    assert(h.service:eligibility(SID, EAST) == 'reserved' and h.service:eligibility(SID, NORTH) == 'open')
    for _ = 1, 2 do h.restart(); r, e = h.service:start(h.request({exit_id = EAST})); assert(not r and e.code == 'already_reserved') end
    -- Another exit proceeds and, once built, reserves the whole settlement.
    h.build = nil
    to_build(h, {exit_id = NORTH})
    h.build.done(nil, {writes = 2})
    assert(h.latest().state == 'built')
    r, e = h.service:start(h.request({exit_id = NORTH})); assert(not r and e.scope == 'settlement')
end)

test('unknown builder failures are treated as possibly written; known zero-write failures are not', function()
    for _, case in ipairs({{'stale_plan', 'failed', 'none'}, {'towns_busy', 'failed', 'none'}, {'build_failed', 'failed', 'none'},
        {'mystery', 'partial', 'unknown'}}) do
        local h = harness()
        to_build(h)
        h.build.done({code = case[1], reason = 'x'})
        local s = h.latest(); assert(s.state == case[2] and s.writes == case[3], case[1])
        assert((h.service:eligibility(SID, EAST) == 'open') == (case[3] == 'none'), case[1])
    end
end)

test('restart from every persisted state is conservative and never replays construction', function()
    local key = outward_store.PREFIX..SID
    local function doc_with(state, writes, exit_id)
        return fx.serialize({schema = 1, settlement_id = SID, next_seq = 2, operations = {{
            op_id = SID..'/'..(exit_id or EAST)..'#1', seq = 1, exit_id = exit_id or EAST, state = state, writes = writes,
            requester = 'alice', created_at = 1, updated_at = 1, settlement_id = SID, candidates = {{x = 100, z = 0}}, attempts = {}}}})
    end
    local expectations = {
        {'planning', 'none', 'open', 'open'}, {'failed', 'none', 'open', 'open'}, {'cancelled', 'none', 'open', 'open'},
        {'interrupted', 'none', 'open', 'open'}, {'interrupted', 'unknown', 'reserved', 'open'},
        {'building', 'unknown', 'reserved', 'open'}, {'partial', 'some', 'reserved', 'open'},
        {'built', 'all', 'reserved', 'reserved'},
    }
    for _, case in ipairs(expectations) do
        local h = harness({storage = fx.storage({[key] = doc_with(case[1], case[2])})})
        local summary = assert(h.restart())
        assert(summary.settlements == 1, case[1])
        assert(h.service:eligibility(SID, EAST) == case[3], case[1]..' own exit')
        assert(h.service:eligibility(SID, NORTH) == case[4], case[1]..' other exit')
        h.run(); assert(#h.builds == 0 and #h.surveys == 0, case[1]) -- nothing is replayed
        local s = h.latest()
        assert(s.state ~= 'planning' and s.state ~= 'building', case[1])
    end
    local h = harness({storage = fx.storage({[key] = 'garbage('})})
    local summary = h.restart(); assert(summary.unreadable == 1)
    local r, e = h.service:start(h.request({exit_id = NORTH})); assert(not r and e.code == 'already_reserved')
    assert(h.storage.data[key] == 'garbage(') -- never overwritten
end)

test('retrying after a zero-write failure is explicit, creates a new operation and never loops', function()
    local h = harness({behavior = {[100] = {fail = 'bounded_no_route'}}})
    for i = 1, 3 do
        local r = assert(h.service:start(h.request()))
        assert(r.op_id == SID..'/'..EAST..'#'..i)
        h.run()
        assert(h.latest().state == 'failed' and h.service.active == nil)
    end
    assert(#h.planners == 3) -- one attempt per explicit request
    assert(#h.doc().operations == 3)
    for i = 4, 8 do assert(h.service:start(h.request())); h.run() end
    assert(#h.doc().operations == 4 and h.doc().operations[1].seq == 5) -- bounded retention
end)

test('scheduler failure ends the operation cleanly', function()
    local h = harness()
    h.schedule_error = true
    local r, e = h.service:start(h.request())
    assert(not r and e.code == 'survey_failed' and h.service.active == nil and h.controller.active == nil)
    assert(h.latest().state == 'failed' and h.latest().writes == 'none')
end)

test('status identifies the settlement, exit, target and stage while running', function()
    local h = harness({behavior = {[100] = {slices = 5}}})
    assert(h.service:start(h.request({candidates = {{x = 100, z = 7}}})))
    h.run_until(function() return h.stage() == 'searching' end)
    local s = h.service:status()
    assert(s.settlement_id == SID and s.exit_id == EAST and s.current_target.x == 100 and s.current_target.z == 7 and s.active)
    assert(h.service:status('auto:other') == nil and h.service:status(SID).op_id == s.op_id)
    h.service:cancel('x')
end)

-- Real survey/connector/planner/composer/builder pipeline over flat and sloped exits.
local function real_pipeline(direction, kind, width)
    local surface = dofile('src/surface.lua')
    local connectors = dofile('src/connectors.lua')
    local edges = dofile('src/edges.lua'); assert(edges.set_raster(dofile('src/raster.lua')))
    local planner = dofile('src/planner.lua'); assert(planner.set_edges(edges))
    local plans = dofile('src/plans.lua'); assert(plans.set_dependencies(dofile('src/raster.lua'), edges))
    local build = dofile('src/build.lua')
    local fixture = dofile('tests/connector_fixture.lua')
    local access, _, desc, target = fixture.exit(direction, kind, width)
    local bounds = {min_x = -32, max_x = 47, min_y = -32, max_y = 31, min_z = -32, max_z = 47}
    local terrain = assert(surface.inspect(bounds, 'roads:outward', access))
    local exit = towns_fixture.exit({x = direction.x, z = direction.z}, kind, width)
    local fake = towns_fixture.new()
    local settlement = towns_fixture.settlement(SID, {exit})
    -- The town lies behind the exit.
    local lo, hi = {x = -60, z = -60}, {x = 60, z = 60}
    if direction.x == 1 then hi.x = -10 elseif direction.x == -1 then lo.x = 10
    elseif direction.z == 1 then hi.z = -10 else lo.z = 10 end
    settlement.reservation = {min = {x = lo.x, y = -10, z = lo.z}, max = {x = hi.x, y = 40, z = hi.z}}
    settlement.core = {x1 = lo.x + 5, z1 = lo.z + 5, x2 = hi.x - 2, z2 = hi.z - 5}; settlement.structures = {}
    fake.records[SID] = settlement
    local writes, queue = {}, {}
    local h
    h = harness({fake = fake, terrain = terrain,
        exit_endpoints = function(t, descriptor, tgt)
            return connectors.exit_endpoints(t, descriptor, tgt, access, function() end, surface, edges)
        end,
        new_planner = function(t, request, config) return planner.new(t, request, config) end,
        start_build = function(plan, done, guard)
            return build.new(plan, {now = function() return h.time end, after = function(d, fn) h.after(d, fn) end,
                load = function() end, classify = surface.classify, has_timer = function() return false end, guard = guard,
                access = access, write = function(p, node) writes[#writes+1] = {x = p.x, y = p.y, z = p.z, node = node} end}, done)
        end})
    -- The harness' fake compose is replaced by the real composer.
    h.ops.compose = function(t, route, config) return plans.compose(t, route, config) end
    h.ops.survey = {plan = function(a, b) return {chunks = {{ix = 0, iy = 0, iz = 0}}, chunk_count = 1} end}
    h.service = assert(outward.new(h.ops))
    return h, writes, exit, target, desc
end

test('real pipeline builds flat and sloped exits in every direction without touching the approach', function()
    for _, d in ipairs({{x = 1, z = 0, p2 = 1}, {x = -1, z = 0, p2 = 3}, {x = 0, z = 1, p2 = 0}, {x = 0, z = -1, p2 = 2}}) do
        for _, kind in ipairs({'flat', 'down', 'up'}) do
            local h, writes, exit, target, desc = real_pipeline(d, kind, 2)
            local r = assert(h.service:start(h.request({exit_id = exit.id, candidates = {target}})))
            h.run()
            local s = h.latest()
            assert(s.state == 'built' and s.writes == 'all' and #writes > 0, d.x..','..d.z..' '..kind..': '..tostring(s.error and s.error.reason))
            local op = h.doc().operations[1]
            assert(op.state == 'built' and op.road.plan_version == 2 and op.road.connector_version == 1)
            assert(op.road.outward.x == d.x and op.road.outward.z == d.z and op.source.profile[1].name == exit.profile[1].name)
            -- No write lands on a published approach node (preserved connector nodes).
            local approach = {}
            for n = 0, exit.length - 1 do for l = 0, 1 do
                local e = exit.profile[n + 1]
                approach[(n * d.x + l * -d.z)..':'..e.y..':'..(n * d.z + l * d.x)] = true
            end end
            for _, w in ipairs(writes) do assert(not approach[w.x..':'..w.y..':'..w.z], 'approach node written') end
            assert(h.service:eligibility(SID, exit.id) == 'reserved')
        end
    end
end)

test('real pipeline: a stale world performs zero writes and leaves the exit open', function()
    local h, writes, exit, target = real_pipeline({x = 1, z = 0, p2 = 1}, 'flat', 2)
    -- The world changes between planning and construction.
    local original = h.ops.start_build
    h.ops.start_build = function(plan, done, guard)
        plan.expectations[#plan.expectations].material = 'mcl_core:sand'
        plan.expectations[#plan.expectations].kind = 'natural'
        local first = plan.expectations[1]
        first.kind = 'air'; first.material = nil
        return original(plan, done, guard)
    end
    h.service = assert(outward.new(h.ops))
    assert(h.service:start(h.request({exit_id = exit.id, candidates = {target}}))); h.run()
    local s = h.latest()
    assert(s.state == 'failed' and s.writes == 'none' and s.error.code == 'stale_plan' and #writes == 0, s.error and s.error.reason)
    assert(h.service:eligibility(SID, exit.id) == 'open')
end)

test('progress notices are marked active and only terminal notices are final', function()
    local h = harness()
    to_build(h)
    h.build.done(nil, {writes = 2})
    local finals, progress = 0, 0
    for _, n in ipairs(h.notices) do if n.summary.active then progress = progress + 1 else finals = finals + 1 end end
    assert(progress >= 4 and finals == 1 and not h.notices[#h.notices].summary.active
        and h.notices[#h.notices].summary.state == 'built')
end)

test('an uncopyable policy is rejected without leaking the slot or a record', function()
    local h = harness()
    local cyclic = {}; cyclic.self = cyclic
    local r, e = h.service:start(h.request({policy = cyclic}))
    assert(not r and e.code == 'invalid_request' and h.controller.active == nil and h.storage.sets == 0)
    assert(h.service:start(h.request()))
end)

test('outward service refuses incomplete dependencies', function()
    local r, e = outward.new({}); assert(not r and e.code == 'invalid_config')
    r, e = outward.new(nil); assert(not r and e.code == 'invalid_config')
end)

print('ok - '..count..' outward service tests')
