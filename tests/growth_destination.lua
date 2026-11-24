-- SPDX-License-Identifier: GPL-3.0-or-later
-- Destination-aware growth cycles (#50): snapshot before any survey, sequential
-- destination attempts, the shared budget partition, reserved directional
-- fallback, fake final attachments, stale destinations, blocked stops,
-- restart/cancel during every attempt, and the /roads_grow output. The real
-- outward and growth services, planner, composer and builder run over the
-- simulated world of tests/growth_fixture.lua; only providers (destinations and
-- final attachments), surveying and the clock are scripted.
local commands = dofile('src/commands.lua')
local surface = dofile('src/surface.lua')
local fixture = dofile('tests/growth_fixture.lua')
local harness, COBBLE = fixture.harness, fixture.COBBLE

local count = 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if not ok then error('growth destination '..name..': '..tostring(err)) end
    count = count + 1
end

-- The seeded road ends at x=48 heading +x, preferred +x; a straight cycle reaches x=144.
local function town(id, approach, x, z, revision)
    return {version = 1, kind = 'town', id = id, approach_id = approach, position = {x = x, y = 0, z = z},
        direction = {x = -1, z = 0}, revision = revision or 1}
end
local function install_town(h, items, truncation)
    local provider = {calls = 0, items = items, truncation = truncation or 'none'}
    function provider:nearby(pos, radius, limit)
        self.calls = self.calls + 1
        self.last = {pos = pos, radius = radius, limit = limit}
        h.events[#h.events + 1] = 'scan'
        return {items = self.items, truncation = self.truncation}
    end
    h.providers.town = provider
    return provider
end
-- Fake final-attachment provider; `o` can be changed while a cycle runs.
local function install_attachment(h, o)
    o = o or {}
    h.attachments.town = {resolve = function(self, d, ctx)
        h.events[#h.events + 1] = 'resolve:'..ctx.mode
        o.resolved = (o.resolved or 0) + 1
        if o.reject and ctx.mode == 'final' then return nil, {code = 'unsupported_attachment', reason = o.reject} end
        local resolved = {revision = o.revision or d.revision,
            recheck = (not o.no_recheck) and function() return not o.stale_late end or nil,
            verify = (not o.no_verify) and function() if o.verify == false then return nil, {reason = 'walking path is broken'} end return true end or nil}
        if ctx.mode == 'final' then
            resolved.goal = {x = d.position.x, z = d.position.z}
            resolved.claims = {{id = 'exit:'..d.id..'/'..d.approach_id, kind = 'exit'}}
        end
        return resolved
    end}
    return o
end
local function failing_planner(h, code)
    h.allowances = {}
    h.planner_wrap = function(job, c)
        h.allowances[#h.allowances + 1] = c.max_expansions
        return {step = function() return {status = 'failed', error = {code = code or 'bounded_no_route', reason = 'scripted '..(code or 'no route')},
            metrics = {expansions = code == 'expansion_budget' and c.max_expansions or 10}} end,
            cancel = function() end}
    end
end
local function hanging_job(kind)
    return {status = function() return {status = 'running'} end,
        step = function() return {status = 'running', metrics = {expansions = 0}} end, cancel = function(self) self.cancelled = true end}
end
-- The seed road's own writes are not growth work.
local function adopt(h) local id = h.adopted(); h.writes = 0; return id end
local function stage_of(h) return h.growth.active and h.growth.active.stage end
local function commands_for(h)
    local registered = {}
    local engine = {register_chatcommand = function(name, def) registered[name] = def end,
        get_player_by_name = function() return nil end}
    assert(commands.register(engine, h.jobs, surface, function() return {} end, nil, nil, {service = h.growth}))
    return registered
end
local function expect_no_work(h)
    assert(h.growth.active == nil and h.jobs.active == nil)
    local surveys, builds = h.surveys, h.builds
    h.run()
    assert(h.surveys == surveys and h.builds == builds, 'no callbacks may run after stopping')
end

test('destinations are snapshotted with the query shape before any survey; none installed means a disabled scan', function()
    local h = harness()
    local road_id = adopt(h)
    assert(h.run_cycle(road_id))
    local road = h.road(road_id)
    assert(road.state == 'open' and road.revision == 2 and road.endpoint.x == 144)
    local latest = road.attempts[#road.attempts]
    assert(latest.scan.status == 'disabled' and latest.result == 'directional' and #latest.candidates == 0, 'no provider is a disabled scan')

    h = harness()
    road_id = adopt(h)
    local provider = install_town(h, {})
    local mark = #h.events
    assert(h.run_cycle(road_id))
    assert(provider.calls == 1 and provider.last.radius == 512 and provider.last.limit == 32 and provider.last.pos.x == 48)
    local first_survey, first_scan
    for i = mark + 1, #h.events do
        local e = h.events[i]
        if e == 'scan' and not first_scan then first_scan = i end
        if e == 'survey' and not first_survey then first_survey = i end
    end
    assert(first_scan and first_survey and first_scan < first_survey, 'the snapshot precedes the first survey')
    latest = h.road(road_id).attempts[1]
    assert(latest.scan.status == 'complete' and latest.scan.providers.town == 'ok' and latest.scan.providers.village == 'absent')
    assert(h.builds == 1 and h.road(road_id).revision == 2, 'zero destinations still grow directionally')
end)

test('a destination discovered during the cycle is only considered next cycle', function()
    local h = harness()
    local road_id = adopt(h)
    local provider = install_town(h, {})
    install_attachment(h)
    h.on_planner = function() provider.items = {town('town-b', 'b/west', 600, 0)} end
    assert(h.run_cycle(road_id))
    assert(h.road(road_id).attempts[1].result == 'directional' and #h.road(road_id).attempts[1].candidates == 0)
    h.on_planner = nil
    assert(h.run_cycle(road_id))
    local latest = h.road(road_id).attempts[2]
    assert(latest.result == 'partial_progress' and latest.candidates[1].approach_id == 'b/west')
end)

test('a distant destination steers by waypoint: partial progress, never connected, rescanned each cycle', function()
    local h = harness()
    local road_id = adopt(h)
    local provider = install_town(h, {town('town-b', 'b/west', 448, 0)})
    install_attachment(h)
    assert(h.run_cycle(road_id))
    local road = h.road(road_id)
    assert(road.state == 'open' and road.endpoint.x == 144 and road.connected == nil and h.builds == 1)
    local a = road.attempts[1]
    assert(a.result == 'partial_progress' and a.candidates[1].mode == 'waypoint' and a.targets[#a.targets].kind == 'destination')
    local record = assert(h.growth_store:load_record(road.last_segment_id))
    assert(record.destination.kind == 'town' and record.destination.approach_id == 'b/west' and record.destination.mode == 'waypoint')
    -- Destination switching: the next snapshot may choose another approach.
    provider.items = {town('town-c', 'c/west', 456, 0), town('town-b', 'b/west', 448, 0)}
    assert(h.run_cycle(road_id))
    assert(provider.calls == 2)
    road = h.road(road_id)
    assert(road.attempts[2].candidates[1].approach_id == 'b/west' and road.attempts[2].candidates[2].approach_id == 'c/west')
    assert(road.endpoint.x == 240 and road.state == 'open', 'at most one segment per cycle')
    assert(h.builds == 2)
end)

test('a reachable destination attaches through a fake final attachment and stops connected', function()
    local h = harness()
    local road_id = adopt(h)
    install_town(h, {town('town-b', 'b/west', 192, 0)})
    local o = install_attachment(h)
    assert(h.run_cycle(road_id))
    local road = h.road(road_id)
    assert(road.state == 'connected' and road.endpoint.x == 192 and road.connected.approach_id == 'b/west' and road.pending == nil)
    assert(h.builds == 1 and road.attempts[1].result == 'connected')
    local claim = assert(h.growth_store:claim('exit:town-b/b/west'))
    assert(claim.state == 'held' and claim.road_id == road_id, 'the full exit stays claimed')
    local id, err = h.growth:extend(road_id, 'admin')
    assert(not id and err.code == 'not_extendable')
    -- The claim keeps another road from selecting the same approach.
    assert(h.growth:retry(road_id, 'admin') == nil)
    local _, text = commands_for(h).roads_grow.func('admin', 'status '..road_id)
    assert(text:find('Connected to town town-b', 1, true), text)
end)

test('an unverified final attachment is uncertain, never connected', function()
    local h = harness()
    local road_id = adopt(h)
    install_town(h, {town('town-b', 'b/west', 192, 0)})
    install_attachment(h, {verify = false})
    assert(h.run_cycle(road_id))
    local road = h.road(road_id)
    assert(road.state == 'uncertain' and road.stop.code == 'attachment_unverified' and road.connected == nil)
    assert(h.growth_store:claim('exit:town-b/b/west').state == 'uncertain')
end)

test('unsupported attachments reject explicitly and fall back to a real directional attempt', function()
    local h = harness()
    local road_id = adopt(h)
    install_town(h, {town('town-b', 'b/west', 192, 0)})
    assert(h.run_cycle(road_id))   -- no attachment provider at all
    local road = h.road(road_id)
    local a = road.attempts[1]
    assert(a.targets[1].kind == 'destination' and a.targets[1].outcome == 'attachment_unsupported'
        and a.targets[1].reason:find('no final%-attachment provider'), 'explicit rejection')
    assert(a.targets[2].kind == 'fallback' and a.targets[2].length == 96 and a.result == 'directional')
    assert(h.surveys == 1 and h.builds == 1 and road.state == 'open' and road.endpoint.x == 144, 'the rejection cost no survey')

    h = harness()
    road_id = adopt(h)
    install_town(h, {town('town-b', 'b/west', 192, 0)})
    install_attachment(h, {reject = 'only flat width-2 exits are supported'})
    assert(h.run_cycle(road_id))
    a = h.road(road_id).attempts[1]
    assert(a.targets[1].outcome == 'unsupported_attachment' and a.targets[1].reason:find('width%-2'))
    assert(a.result == 'directional' and h.road(road_id).state == 'open')
    assert(h.growth_store:claim('exit:town-b/b/west') == nil, 'a rejected attachment holds no claim')
end)

test('stale destination revisions are rejected before survey and again after the durability wait', function()
    local h = harness()
    local road_id = adopt(h)
    install_town(h, {town('town-b', 'b/west', 192, 0, 1)})
    install_attachment(h, {revision = 2})
    assert(h.run_cycle(road_id))
    local a = h.road(road_id).attempts[1]
    assert(a.targets[1].outcome == 'stale_destination' and a.targets[1].reason:find('revision 1 to 2'))
    assert(a.result == 'directional' and h.surveys == 1)

    -- Waypoints are rechecked too when a provider is installed.
    h = harness()
    road_id = adopt(h)
    install_town(h, {town('town-b', 'b/west', 448, 0, 'r1')})
    install_attachment(h, {revision = 'r2'})
    assert(h.run_cycle(road_id))
    assert(h.road(road_id).attempts[1].targets[1].outcome == 'stale_destination' and h.road(road_id).attempts[1].result == 'directional')

    -- A change during the durability wait stops the cycle with zero writes and releases the claims.
    h = harness()
    road_id = adopt(h)
    install_town(h, {town('town-b', 'b/west', 192, 0)})
    local o = install_attachment(h)
    assert(h.growth:extend(road_id, 'admin'))
    h.run_until(function() return stage_of(h) == 'durability_wait' end)
    assert(h.growth_store:claim('exit:town-b/b/west').state == 'pending')
    o.stale_late = true
    h.run_until(function() return h.growth.active == nil end)
    local road = h.road(road_id)
    assert(road.state == 'stopped' and road.stop.code == 'stale_destination' and h.builds == 0 and h.writes == 0)
    assert(h.growth_store:claim('exit:town-b/b/west') == nil and road.pending == nil and road.revision == 1)
    assert(road.stop.attempted[#road.stop.attempted].outcome == 'composed')
end)

test('an attachment that cannot be fully checked is rejected before any survey and falls back with zero writes', function()
    for _, case in ipairs({{'no_verify', 'verify', 192}, {'no_recheck', 'recheck', 192}, {'no_recheck', 'recheck', 448}}) do
        local h = harness()
        local road_id = adopt(h)
        install_town(h, {town('town-b', 'b/west', case[3], 0)})
        install_attachment(h, {[case[1]] = true})
        assert(h.run_cycle(road_id))
        local t = h.road(road_id).attempts[1].targets
        assert(t[1].kind == 'destination' and t[1].outcome == 'attachment_invalid' and t[1].reason:find('lacks a callable '..case[2]), t[1].reason)
        assert(h.road(road_id).attempts[1].result == 'directional' and h.surveys == 1 and h.builds == 1)
        assert(h.growth_store:claim('exit:town-b/b/west') == nil)
    end
end)

test('a waypoint with an installed provider but no attachment resolver is rejected, not trusted unchecked', function()
    local h = harness()
    local road_id = adopt(h)
    install_town(h, {town('town-b', 'b/west', 448, 0)})
    assert(h.run_cycle(road_id))
    local a = h.road(road_id).attempts[1]
    assert(a.targets[1].outcome == 'attachment_unsupported' and a.targets[1].reason:find('revision%-checking'))
    assert(a.result == 'directional' and h.surveys == 1 and h.builds == 1 and h.writes > 0)
end)

test('a failure to collect obstacles ends the cycle with zero writes and no fallback', function()
    local h = harness()
    local road_id = adopt(h)
    install_town(h, {town('town-b', 'b/west', 192, 0)})
    install_attachment(h)
    local original = h.growth_store.collect
    h.growth_store.collect = function() return nil, {code = 'road_index_budget', reason = 'too many references'} end
    assert(h.run_cycle(road_id))
    h.growth_store.collect = original
    local road = h.road(road_id)
    assert(road.state == 'stopped' and road.stop.code == 'road_index_budget' and h.surveys == 0 and h.builds == 0)
    assert(road.stop.attempted == nil, 'the cycle ended at the first destination attempt; fallback was not tried')
end)

test('selection excludes claimed and busy approaches and reports why', function()
    local h = harness()
    local road_id = adopt(h)
    install_town(h, {town('town-b', 'b/west', 192, 0), town('town-c', 'c/west', 200, 0), town('town-d', 'd/west', 208, 0)})
    install_attachment(h, {reject = 'scripted'})
    assert(h.growth_store:update(function(d)
        d.claims['exit:town-b/b/west'] = {kind = 'exit', road_id = 'other', segment_id = 'seg', state = 'held'}
        return true
    end))
    h.unavailable = function(d) if d.id == 'town-c' then return 'busy' end end
    assert(h.run_cycle(road_id))
    local a = h.road(road_id).attempts[1]
    assert(#a.candidates == 1 and a.candidates[1].approach_id == 'd/west')
    local why = {}
    for _, r in ipairs(a.rejected) do why[r.approach_id] = r.reason end
    assert(why['b/west'] == 'claimed' and why['c/west'] == 'busy', 'claims and busy lookups feed the policy')
end)

test('an unhealthy provider fails the cycle closed before anything is consumed', function()
    local h = harness()
    local road_id = adopt(h)
    h.providers.town = {nearby = function() return nil, {code = 'towns_unavailable', reason = 'registry offline'} end}
    local before = h.road(road_id)
    local id, err = h.growth:extend(road_id, 'admin')
    assert(not id and err.code == 'provider_unhealthy')
    local after = h.road(road_id)
    assert(after.state == 'open' and after.next_seq == before.next_seq and after.activation == before.activation)
    assert(h.jobs.active == nil and h.surveys == 0 and h.builds == 0 and #h.queue == 0)
    h.providers.town = {nearby = function() error('boom') end}
    id, err = h.growth:extend(road_id, 'admin')
    assert(not id and err.code == 'provider_unhealthy' and h.jobs.active == nil)
end)

------------------------------------------------------------------ budgets
test('destination attempts keep 50,000 expansions in reserve and unused allowance passes to fallback', function()
    -- Every search exhausts its whole allowance: 50,000 + 50,000 + 25,000 + 25,000.
    local h = harness()
    local road_id = adopt(h)
    install_town(h, {town('town-b', 'b/west', 192, 0), town('town-c', 'c/west', 200, 0)})
    install_attachment(h)
    failing_planner(h, 'expansion_budget')
    assert(h.run_cycle(road_id))
    assert(#h.allowances == 4)
    assert(h.allowances[1] == 50000 and h.allowances[2] == 50000, 'each destination attempt is capped at 50,000')
    assert(h.allowances[3] == 25000 and h.allowances[4] == 25000, 'the reserved 50,000 serves two fallback attempts')
    local road = h.road(road_id)
    assert(road.state == 'stopped' and road.stop.code == 'expansion_budget' and road.stop.observed == 150000 and h.builds == 0)
    assert(#road.stop.attempted == 4 and road.stop.attempted[1].kind == 'destination' and road.stop.attempted[4].kind == 'fallback')
    assert(road.attempts[1].expansions == 150000)

    -- Destinations that fail without searching leave their whole allowance to fallback.
    h = harness()
    road_id = adopt(h)
    install_town(h, {town('town-b', 'b/west', 192, 0), town('town-c', 'c/west', 200, 0)})
    install_attachment(h, {reject = 'scripted'})
    failing_planner(h, 'bounded_no_route')
    assert(h.run_cycle(road_id))
    assert(#h.allowances == 2 and h.allowances[1] == 75000 and h.allowances[2] == 150000 - 10,
        'the second fallback attempt takes everything the first left')
    local stop = h.road(road_id).stop
    assert(stop.code == 'bounded_no_route' and #stop.attempted == 4 and h.surveys == 2)
end)

test('a destination that exhausts its own allowance does not end the cycle: fallback still builds', function()
    local h = harness()
    local road_id = adopt(h)
    install_town(h, {town('town-b', 'b/west', 192, 0)})
    install_attachment(h)
    h.planner_wrap = function(job, c)
        h.allowances = h.allowances or {}
        h.allowances[#h.allowances + 1] = c.max_expansions
        if #h.allowances == 1 then
            return {step = function() return {status = 'failed', error = {code = 'expansion_budget', reason = 'allowance spent'},
                metrics = {expansions = c.max_expansions}} end, cancel = function() end}
        end
        return job
    end
    assert(h.run_cycle(road_id))
    local road = h.road(road_id)
    assert(road.state == 'open' and road.endpoint.x == 144 and h.builds == 1)
    assert(road.attempts[1].targets[1].outcome == 'expansion_budget' and road.attempts[1].result == 'directional')
    assert(h.allowances[1] == 50000 and h.allowances[2] == 50000 and #h.allowances == 2, 'fallback searched on')
    assert(road.attempts[1].expansions >= 50000, 'the spent work still counts toward the cycle')
end)

local function chunk_script(h, sizes)
    local original = h.survey.plan
    h.plans = {}
    h.survey.plan = function(a, b, config)
        local plan = original(a, b, config)
        local script = sizes[#h.plans + 1] or {1, 1}
        local chunks = {}
        for i = script[1], script[2] do chunks[#chunks + 1] = {ix = i, iy = 0, iz = 0} end
        plan.chunks, plan.chunk_count = chunks, #chunks
        h.plans[#h.plans + 1] = script
        return plan
    end
end

test('the mapchunk ceiling is a real union: destinations stop at 64 and fallback reuses their chunks up to 96', function()
    local h = harness()
    local road_id = adopt(h)
    install_town(h, {town('town-b', 'b/west', 192, 0), town('town-c', 'c/west', 200, 0)})
    install_attachment(h)
    -- attempt 1: 60 chunks; attempt 2: chunks 41..70 would make 70 (> 64);
    -- fallback 96: chunks 1..96 reuses the 60 (union 96); fallback 64: chunk 97 would exceed 96.
    chunk_script(h, {{1, 60}, {41, 70}, {1, 96}, {1, 97}})
    failing_planner(h, 'bounded_no_route')
    assert(h.run_cycle(road_id))
    local road = h.road(road_id)
    assert(#h.plans == 4)
    local t = road.attempts[1].targets
    assert(t[1].outcome == 'bounded_no_route' and t[1].chunks_new == 60)
    assert(t[2].outcome == 'survey_budget' and t[2].reason:find('70 distinct mapchunks') and t[2].reason:find('destination limit 64'))
    assert(t[3].outcome == 'bounded_no_route' and t[3].chunks_new == 36, 'fallback adds only the 36 chunks it has not already counted')
    assert(t[4].outcome == 'survey_budget' and t[4].reason:find('97 distinct mapchunks'))
    assert(h.surveys == 2, 'refused attempts never reach the survey or emerge')
    assert(road.attempts[1].chunks == 96 and road.stop.code == 'survey_budget' and road.stop.limit == 96 and road.stop.observed == 97)
    assert(#road.stop.attempted == 4)
end)

test('the 32 chunks reserved for fallback let it build after a destination used the whole destination share', function()
    local h = harness()
    local road_id = adopt(h)
    install_town(h, {town('town-b', 'b/west', 192, 0)})
    install_attachment(h)
    chunk_script(h, {{1, 64}, {1, 96}})
    local calls = 0
    h.planner_wrap = function(job)
        calls = calls + 1
        if calls == 1 then return {step = function() return {status = 'failed', error = {code = 'bounded_no_route', reason = 'walled'},
            metrics = {expansions = 5}} end, cancel = function() end} end
        return job
    end
    assert(h.run_cycle(road_id))
    local road = h.road(road_id)
    assert(road.state == 'open' and road.attempts[1].result == 'directional' and road.attempts[1].chunks == 96)
    assert(h.builds == 1 and h.surveys == 2)
end)

test('a destination needing more than 64 chunks is refused without generating, leaving fallback its 32', function()
    local h = harness()
    local road_id = adopt(h)
    install_town(h, {town('town-b', 'b/west', 192, 0)})
    install_attachment(h)
    chunk_script(h, {{1, 65}, {1, 40}})
    assert(h.run_cycle(road_id))
    local road = h.road(road_id)
    assert(road.attempts[1].targets[1].outcome == 'survey_budget' and h.surveys == 1 and road.state == 'open')
    assert(road.attempts[1].result == 'directional' and road.attempts[1].chunks == 40)
end)

test('a fallback that cannot fit the chunk budget records survey_budget without generating', function()
    local h = harness()
    local road_id = adopt(h)
    chunk_script(h, {{1, 97}, {1, 98}})
    assert(h.run_cycle(road_id))
    local road = h.road(road_id)
    assert(h.surveys == 0 and h.builds == 0 and road.state == 'stopped' and road.stop.code == 'survey_budget')
    assert(road.stop.limit == 96 and road.stop.observed == 98 and #road.stop.attempted == 2)
end)

------------------------------------------------------------------ blocked
test('a wholly blocked cycle stops with the last concrete error and every attempted outcome; deliberate retry reopens it', function()
    local h = harness()
    local road_id = adopt(h)
    install_town(h, {town('town-b', 'b/west', 192, 0), town('town-c', 'c/west', 200, 0)})
    install_attachment(h)
    failing_planner(h, 'bounded_no_route')
    assert(h.run_cycle(road_id))
    local road = h.road(road_id)
    assert(road.state == 'stopped' and road.stop.code == 'bounded_no_route' and #road.stop.attempted == 4)
    local kinds = {}
    for i, e in ipairs(road.stop.attempted) do kinds[i] = e.kind..(e.length and (':'..e.length) or '')..':'..e.outcome end
    assert(table.concat(kinds, ' ') == 'destination:144:bounded_no_route destination:152:bounded_no_route fallback:96:bounded_no_route fallback:64:bounded_no_route', table.concat(kinds, ' '))
    assert(h.builds == 0 and h.writes == 0 and road.pending == nil and road.revision == 1 and h.jobs.active == nil)
    assert(h.growth_store:claim('exit:town-b/b/west') == nil and h.growth_store:claim('exit:town-c/c/west') == nil)
    -- Revisits do not retry; only a deliberate retry does.
    local surveys = h.surveys
    local id, err = h.growth:extend(road_id, 'admin')
    assert(not id and err.code == 'not_extendable' and h.surveys == surveys)
    local cmds = commands_for(h)
    local ok, text = cmds.roads_grow.func('admin', 'status '..road_id)
    assert(ok and text:find('Blocked: bounded_no_route', 1, true) and text:find('Attempted: destination b/west (final) bounded_no_route; '
        .. 'destination c/west (final) bounded_no_route; 96 node fallback bounded_no_route; 64 node fallback bounded_no_route.', 1, true), text)
    h.planner_wrap = nil
    ok, text = cmds.roads_grow.func('admin', 'retry '..road_id)
    assert(ok and text:find('Retry started', 1, true), text)
    h.run_until(function() return h.growth.active == nil end)
    road = h.road(road_id)
    assert(road.state == 'connected' or road.state == 'open', road.state)
    assert(h.builds == 1)
end)

------------------------------------------------------------------ restart and cancel
for _, case in ipairs({{1, 'searching'}, {2, 'searching'}, {3, 'searching'}, {4, 'searching'},
    {1, 'surveying'}, {2, 'surveying'}, {3, 'surveying'}, {4, 'surveying'}}) do
    local attempt, stage = case[1], case[2]
    local label = (attempt <= 2 and 'destination attempt ' or 'fallback attempt ')..attempt..' while '..stage
    local function setup()
        local h = harness()
        local road_id = adopt(h)
        install_town(h, {town('town-b', 'b/west', 192, 0), town('town-c', 'c/west', 200, 0)})
        install_attachment(h)
        h.hung = nil
        h.planner_wrap = function(job)
            if stage == 'searching' and h.growth.active.index == attempt then
                h.hung = hanging_job(); return h.hung
            end
            return {step = function() return {status = 'failed', error = {code = 'bounded_no_route', reason = 'walled'},
                metrics = {expansions = 7}} end, cancel = function() end}
        end
        h.survey_script = function(a, b, owner)
            if stage == 'surveying' and h.growth.active.index == attempt then
                h.hung = hanging_job(); return h.hung
            end
            return nil, {code = 'survey_failed', reason = 'scripted earlier failure'}
        end
        if stage == 'surveying' then
            -- Earlier attempts end at survey startup; the chosen one hangs mid-survey.
        else
            h.survey_script = nil
        end
        assert(h.growth:extend(road_id, 'admin'))
        h.run_until(function() return h.growth.active and h.growth.active.index == attempt and h.hung ~= nil end)
        return h, road_id
    end

    test('cancel during '..label..' stops with zero writes and no stray callbacks', function()
        local h, road_id = setup()
        assert(h.growth.active.stage == stage)
        assert(h.growth:cancel(road_id, 'admin'))
        assert(h.hung.cancelled, 'the outstanding work is cancelled')
        local road = h.road(road_id)
        assert(road.state == 'stopped' and road.stop.code == 'cancelled' and road.pending == nil and road.revision == 1)
        assert(road.attempts[#road.attempts].outcome == 'cancelled' and #road.attempts[#road.attempts].targets == attempt - 1)
        assert(h.builds == 0 and h.writes == 0 and h.growth_store:claim('exit:town-b/b/west') == nil)
        expect_no_work(h)
        assert(h.road(road_id).state == 'stopped')
        -- The cancelled cycle is a known zero-write stop: retry is deliberate and still available.
        h.planner_wrap, h.survey_script = nil, nil
        assert(h.growth:retry(road_id, 'admin'))
    end)

    test('restart during '..label..' leaves a stopped road with no replay', function()
        local h, road_id = setup()
        h.restart()
        local road = h.road(road_id)
        assert(road.state == 'stopped' and road.stop.code == 'interrupted' and road.pending == nil and road.revision == 1)
        assert(h.builds == 0 and h.writes == 0 and h.growth.active == nil and h.jobs.active == nil)
        assert(h.growth_store:claim('exit:town-b/b/west') == nil)
        local surveys = h.surveys
        h.run()
        assert(h.surveys == surveys and h.builds == 0)
    end)
end

test('cancel and restart during the durability wait of a final attachment keep or release the claim conservatively', function()
    local h = harness()
    local road_id = adopt(h)
    install_town(h, {town('town-b', 'b/west', 192, 0)})
    install_attachment(h)
    assert(h.growth:extend(road_id, 'admin'))
    h.run_until(function() return stage_of(h) == 'durability_wait' end)
    assert(h.growth:cancel(road_id, 'admin'))
    local road = h.road(road_id)
    assert(road.state == 'stopped' and h.builds == 0 and h.growth_store:claim('exit:town-b/b/west') == nil, 'known zero writes release the claim')
    expect_no_work(h)

    h = harness()
    road_id = adopt(h)
    install_town(h, {town('town-b', 'b/west', 192, 0)})
    install_attachment(h)
    assert(h.growth:extend(road_id, 'admin'))
    h.run_until(function() return stage_of(h) == 'durability_wait' end)
    h.restart()
    road = h.road(road_id)
    assert(road.state == 'uncertain' and road.pending.state == 'uncertain' and h.builds == 0)
    assert(h.growth_store:claim('exit:town-b/b/west').state == 'uncertain', 'the destination reservation is never silently released')
    h.run()
    assert(h.builds == 0 and h.writes == 0, 'never replayed')
    local id, err = h.growth:retry(road_id, 'admin')
    assert(not id and err.code == 'not_retryable')
end)

test('cancel after the builder started keeps the final attachment claim and marks the road uncertain', function()
    local h = harness()
    local road_id = adopt(h)
    install_town(h, {town('town-b', 'b/west', 192, 0)})
    install_attachment(h)
    h.build_script = function() return {cancel = function() end} end
    assert(h.growth:extend(road_id, 'admin'))
    h.run_until(function() return stage_of(h) == 'building' end)
    assert(h.growth:cancel(road_id, 'admin'))
    local road = h.road(road_id)
    assert(road.state == 'uncertain' and h.growth_store:claim('exit:town-b/b/west').state == 'uncertain')
end)

------------------------------------------------------------------ commands
test('/roads_grow shows the scan, selection, rejections, fallback and limits for an active and a finished cycle', function()
    local h = harness()
    local road_id = adopt(h)
    install_town(h, {town('town-b', 'b/west', 448, 0), town('town-s', 's/east', 40, 0), town('town-c', 'c/west', 192, 0)}, 'possible')
    install_attachment(h, {reject = 'scripted'})
    local cmds = commands_for(h)
    local ok, text = cmds.roads_grow.func('admin', 'extend '..road_id)
    assert(ok and text:find('started', 1, true), text)
    assert(text:find('scan possibly_truncated (town=ok, village=absent, road=absent); 3 descriptors inspected.', 1, true), text)
    assert(text:find('Selected: town town-c approach c/west, final attachment, 144 nodes away.', 1, true), text)
    assert(text:find('Next candidate: town town-b approach b/west, waypoint attachment, 400 nodes away (waypoint: partial progress only).', 1, true), text)
    assert(text:find('Directional fallback (96 then 64 nodes) follows', 1, true), text)
    assert(text:find('Rejected town approach s/east: outside_cone.', 1, true), text)
    assert(text:find('Limits per cycle: 96 chunks (64 for destinations, 32 reserved for fallback), 150000 expansions (50000 per destination attempt, 50000 reserved for fallback), 4 attempts (used', 1, true), text)
    h.run_until(function() return h.growth.active == nil end)
    ok, text = cmds.roads_grow.func('admin', 'status '..road_id)
    assert(ok and text:find('revision 2, endpoint (144.0, 0.0, 0.0)', 1, true), text)
    assert(text:find('built (partial_progress); destination c/west (final) unsupported_attachment - scripted; destination b/west (waypoint) composed;', 1, true), text)
    -- Inspect carries the same selection report.
    ok, text = cmds.roads_grow.func('admin', 'inspect '..road_id)
    assert(ok and text:find('Selected: town town-c', 1, true), text)
end)

print('ok - '..count..' growth destination tests')
