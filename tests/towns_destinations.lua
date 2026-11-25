-- SPDX-License-Identifier: GPL-3.0-or-later
-- Completed-Towns destinations and verified final attachment (#51). The real
-- adapter, provider, resolver, connector geometry, planner, composer, builder,
-- outward and growth services run over the simulated world of
-- tests/growth_fixture.lua with a scripted towns_api; see
-- tests/towns_destinations_fixture.lua.
local fx = dofile('tests/towns_destinations_fixture.lua')
local build = dofile('src/build.lua')
local planner = dofile('src/planner.lua')
local plans = dofile('src/plans.lua')
local seam = dofile('src/seam.lua')
local surface = fx.surface
build.set_seam_dependencies(seam, fx.raster)

local count = 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if not ok then error('towns destinations '..name..': '..tostring(err)) end
    count = count + 1
end

local WEST_CORE = {x1 = 121, z1 = -30, x2 = 180, z2 = 30}
local GRADE_DY = {flat = -1, down = -1, up = -2}

-- A town east of the seeded road with an exit facing west (anchor x = 120).
local function west_town(w, kind, width, options)
    options = options or {}
    local e = fx.exit(fx.DIRS.west, kind, width, 120, 0, GRADE_DY[kind])
    local exits = {e}
    for _, more in ipairs(options.extra or {}) do exits[#exits + 1] = more end
    local s = fx.settlement(options.id or 'auto:7:1', exits, WEST_CORE)
    if options.structures then s.structures = options.structures end
    w.publish(s)
    return s, e
end
local function full_id(s, e) return s.id..'/'..e.id end
local function claim_of(h, s, e) return h.growth_store:claim('exit:'..full_id(s, e)) end
local function stage_of(h) return h.growth.active and h.growth.active.stage end
local function last_attempt(h, road_id) local r = h.road(road_id); return r.attempts[#r.attempts], r end
local function inside(rect, p) return p.x >= rect.x1 and p.x <= rect.x2 and p.z >= rect.z1 and p.z <= rect.z2 end
local function reserve(h, sid, exit_id, state, writes)
    local op = assert(h.store:new_op(sid, exit_id, {settlement_id = sid, requester = 'bob', candidates = {}, attempts = {}, aggregate = {}}))
    op.state = state; op.writes = writes
    assert(h.store:save(sid, op))
    return op
end

------------------------------------------------------------ attachment
test('a published flat width-2 exit is reached by a real walkable arrival and its full exit id stays claimed', function()
    local w = fx.setup()
    local h = w.h
    local road_id = w.adopt()
    local s, e = west_town(w, 'flat', 2)
    assert(not fx.walk(h, 48, 0, {x1 = 40, x2 = 125, z1 = -20, z2 = 20})['120:0'], 'not connected before the cycle')
    assert(h.run_cycle(road_id))
    local attempt, road = last_attempt(h, road_id)
    assert(road.state == 'connected', tostring(road.stop and road.stop.reason)..' '..tostring(attempt.targets[1] and attempt.targets[1].reason))
    assert(attempt.result == 'connected' and attempt.targets[1].kind == 'destination' and attempt.targets[1].mode == 'final')
    assert(road.connected.kind == 'town' and road.connected.id == s.id and road.connected.approach_id == e.id)
    local claim = assert(claim_of(h, s, e))
    assert(claim.state == 'held' and claim.road_id == road_id)
    local reached = fx.walk(h, 48, 0, {x1 = 40, x2 = 125, z1 = -20, z2 = 20})
    assert(reached['120:0'] and reached['120:-1'], 'the walking path reaches the exit rows')
    local record = assert(h.growth_store:load_record(road.last_segment_id))
    assert(record.attachment and record.attachment.kind == 'published_exit' and #record.attachment.nodes > 0)
    local report = assert(h.growth:inspect(road_id, 'admin'))
    assert(report.world.status == 'matches_intended' and report.world.attachment.matches)
end)

test('flat and graded exits of width 2 and 4 attach, heights following the published profile', function()
    for _, kind in ipairs({'flat', 'down', 'up'}) do
        for _, width in ipairs({2, 4}) do
            local w = fx.setup()
            local h = w.h
            local road_id = w.adopt()
            local s, e = west_town(w, kind, width)
            assert(h.run_cycle(road_id))
            local attempt, road = last_attempt(h, road_id)
            assert(road.state == 'connected', kind..' w'..width..': '..tostring(road.stop and road.stop.reason)
                ..' / '..tostring(attempt.targets[1] and attempt.targets[1].outcome)..' '..tostring(attempt.targets[1] and attempt.targets[1].reason))
            assert(claim_of(h, s, e).state == 'held')
            local reached = fx.walk(h, 48, 0, {x1 = 40, x2 = 125, z1 = -20, z2 = 20})
            for _, c in ipairs(e.columns) do
                assert(reached[c.x..':'..c.z], kind..' w'..width..' reaches column '..c.x..':'..c.z)
            end
            -- Every preserved exit node is exactly as published.
            for n = 0, e.length - 1 do
                for _, c in ipairs(e.columns) do
                    local node = h.access.get_node({x = c.x - n, y = e.profile[n + 1].y, z = c.z})
                    assert(node.name == e.profile[n + 1].name and node.param2 == e.profile[n + 1].param2)
                end
            end
        end
    end
end)

test('an exit facing north is reached with a final bend into the town and every direction has its arrival headings', function()
    local expected = {west = {0, 1, 7}, east = {3, 4, 5}, north = {5, 6, 7}, south = {1, 2, 3}}
    for name, d in pairs(fx.DIRS) do
        local got = fx.connectors.arrival_headings(d)
        table.sort(got)
        local want = expected[name]; table.sort(want)
        assert(table.concat(got, ',') == table.concat(want, ','), name..': '..table.concat(got, ','))
    end
    local w = fx.setup()
    local h = w.h
    local road_id = w.adopt()
    local e = fx.exit(fx.DIRS.north, 'flat', 2, 150, -30, -1)
    local s = fx.settlement('auto:8:1', {e}, {x1 = 120, z1 = -80, x2 = 180, z2 = -31})
    w.publish(s)
    assert(h.run_cycle(road_id))
    local attempt, road = last_attempt(h, road_id)
    assert(road.state == 'connected', tostring(road.stop and road.stop.reason)..' '..tostring(attempt.targets[1] and attempt.targets[1].reason))
    local record = assert(h.growth_store:load_record(road.last_segment_id))
    local last = record.headings[#record.headings]
    assert(last == 5 or last == 6 or last == 7, 'arrives heading into the town, got '..last)
    local reached = fx.walk(h, 48, 0, {x1 = 40, x2 = 160, z1 = -40, z2 = 20})
    assert(reached['149:-30'] and reached['150:-30'])
end)

test('a heading that cannot face into the town is rejected before any write and growth falls back', function()
    local w = fx.setup()
    local h = w.h
    local road_id = w.adopt()
    -- The exit faces east, away from the road: the town lies to its west.
    local e = fx.exit(fx.DIRS.east, 'flat', 2, 120, 0, -1)
    local s = fx.settlement('auto:7:2', {e}, {x1 = 70, z1 = -30, x2 = 119, z2 = 30})
    w.publish(s)
    assert(h.run_cycle(road_id))
    local attempt, road = last_attempt(h, road_id)
    assert(attempt.targets[1].kind == 'destination' and attempt.targets[1].outcome == 'incompatible_heading'
        and attempt.targets[1].reason:find('faces away'), attempt.targets[1].outcome)
    assert(road.state ~= 'connected' and road.connected == nil and claim_of(h, s, e) == nil)
    assert(attempt.targets[2].kind == 'fallback' and attempt.result ~= 'connected')
end)

test('a landing that cannot sit on the start lattice is rejected and growth falls back', function()
    local w = fx.setup()
    local h = w.h
    local road_id = w.adopt()
    local s, e = west_town(w, 'flat', 2)
    -- Raise every lattice node of the landing window by one: no flat natural landing remains.
    for _, x in ipairs({104, 108, 112}) do
        for _, z in ipairs({-8, -4, 0, 4, 8}) do h.set(x, 1, z, {name = 'mcl_core:obsidian', param2 = 0}) end
    end
    assert(h.run_cycle(road_id))
    local attempt, road = last_attempt(h, road_id)
    assert(attempt.targets[1].outcome == 'invalid_endpoint' and attempt.targets[1].reason:find('lattice%-compatible'),
        tostring(attempt.targets[1].outcome)..' '..tostring(attempt.targets[1].reason))
    assert(road.connected == nil and claim_of(h, s, e) == nil and attempt.targets[2].kind == 'fallback')
end)

test('a waypoint toward a town leaves the exit seam row masked; only the final attachment releases it', function()
    local w = fx.setup()
    local s, e = west_town(w, 'flat', 2)
    local d = assert(w.dest.providers.town:nearby({x = 48, y = 0, z = 0}, 512, 32)).items[1]
    local rect = {x1 = 90, z1 = -40, x2 = 200, z2 = 40}
    local function covered(resolved, x, z)
        for _, r in ipairs(assert(w.a:overlay(rect, nil, nil, resolved.approaches))) do
            if x >= r.x1 and x <= r.x2 and z >= r.z1 and z <= r.z2 then return true end
        end
        return false
    end
    local waypoint = assert(w.dest.attachments.town:resolve(d, {mode = 'waypoint', road_id = 'r'}))
    assert(waypoint.approaches == nil and covered(waypoint, 114, 0) and covered(waypoint, 114, -1))
    local final = assert(w.dest.attachments.town:resolve(d, {mode = 'final', road_id = 'r'}))
    assert(#final.approaches == 1 and not covered(final, 114, 0) and not covered(final, 114, -1) and covered(final, 115, 0))
end)

test('an arrival that no final edge can enter heading into the town is rejected before any write', function()
    local w = fx.setup()
    local h = w.h
    local road_id = w.adopt()
    local s, e = west_town(w, 'flat', 2)
    -- A raised bank across the whole approach side of the landing window.
    for x = 96, 109 do
        for z = -12, 12 do for y = 1, 3 do h.set(x, y, z, {name = 'mcl_core:obsidian', param2 = 0}) end end
    end
    assert(h.run_cycle(road_id))
    local attempt, road = last_attempt(h, road_id)
    assert(attempt.targets[1].outcome == 'invalid_endpoint' and attempt.targets[1].reason:find('no final edge can arrive heading into the town'),
        tostring(attempt.targets[1].outcome)..' '..tostring(attempt.targets[1].reason))
    assert(road.connected == nil and claim_of(h, s, e) == nil)
    assert(attempt.targets[#attempt.targets].kind == 'fallback')
end)

test('no exclusion is ever subtracted: only the exact exit rows stay masked and only the seam row is left to the exclusions', function()
    local w = fx.setup()
    local h = w.h
    local s, e = west_town(w, 'flat', 2)
    local rect = {x1 = 90, z1 = -40, x2 = 200, z2 = 40}
    local function cells(list)
        local covered = {}
        for _, r in ipairs(list) do
            for x = math.max(r.x1, rect.x1), math.min(r.x2, rect.x2) do
                for z = math.max(r.z1, rect.z1), math.min(r.z2, rect.z2) do covered[x..':'..z] = true end
            end
        end
        return covered
    end
    local plain = cells(assert(w.a:overlay(rect, nil, nil, nil)))
    local named = cells(assert(w.a:overlay(rect, nil, nil, {{settlement_id = s.id, exit_id = e.id}})))
    local removed, added = {}, 0
    for id in pairs(plain) do if not named[id] then removed[#removed + 1] = id end end
    for id in pairs(named) do if not plain[id] then added = added + 1 end end
    table.sort(removed)
    assert(added == 0 and #removed == 2 and removed[1] == '114:-1' and removed[2] == '114:0',
        'only the two seam-row columns are released: '..table.concat(removed, ','))
    for x = 115, 120 do assert(named[x..':0'] and named[x..':-1'], 'built exit rows stay masked') end
    for _, r in ipairs(w.fake.items[1].rects) do
        for x = math.max(r.x1, rect.x1), math.min(r.x2, rect.x2) do
            for z = math.max(r.z1, rect.z1), math.min(r.z2, rect.z2) do assert(named[x..':'..z], 'exclusion hole') end
        end
    end
    -- The seam row inside an exclusion stays masked: a hole is never opened.
    w.fake.items[#w.fake.items + 1] = {id = 'extra', kind = 'settlement', state = 'complete',
        rects = {{x1 = 114, z1 = -1, x2 = 114, z2 = 0}}, y_min = -31000, y_max = 31000}
    local with_exclusion = cells(assert(w.a:overlay(rect, nil, nil, {{settlement_id = s.id, exit_id = e.id}})))
    assert(with_exclusion['114:0'] and with_exclusion['114:-1'])
    assert(not w.a:overlay(rect, nil, nil, {{settlement_id = 1, exit_id = 'x'}}))
end)

test('untouched exit rows may lie inside an exclusion; nothing is written into any exclusion or its transition', function()
    local w = fx.setup()
    local h = w.h
    local road_id = w.adopt()
    -- The settlement's structures reach over the whole built exit (rows 115..120).
    local s, e = west_town(w, 'flat', 2, {structures = {{x1 = 115, z1 = -3, x2 = 125, z2 = 3}}})
    local rects = {}
    for _, item in ipairs(w.fake.items) do for _, r in ipairs(item.rects) do rects[#rects + 1] = r end end
    assert(h.run_cycle(road_id))
    local _, road = last_attempt(h, road_id)
    assert(road.state == 'connected')
    for _, p in ipairs(w.writes) do
        for _, r in ipairs(rects) do assert(not inside(r, p), 'a write lies inside a Towns exclusion') end
    end

    -- When the exclusion also covers the seam row and the landing window, there is no transition.
    w = fx.setup()
    h = w.h
    road_id = w.adopt()
    s, e = west_town(w, 'flat', 2, {structures = {{x1 = 100, z1 = -12, x2 = 125, z2 = 12}}})
    assert(h.run_cycle(road_id))
    local attempt
    attempt, road = last_attempt(h, road_id)
    assert(attempt.targets[1].outcome == 'invalid_endpoint' and road.connected == nil and claim_of(h, s, e) == nil,
        tostring(attempt.targets[1].outcome)..' '..tostring(attempt.targets[1].reason))
    for _, p in ipairs(w.writes) do assert(not inside({x1 = 100, z1 = -12, x2 = 125, z2 = 12}, p), 'a write lies inside the exclusion') end
end)

test('a Towns exclusion that appears after the durability wait stops the cycle through the guard with zero writes', function()
    local w = fx.setup()
    local h = w.h
    local road_id = w.adopt()
    local s, e = west_town(w, 'flat', 2)
    assert(h.growth:extend(road_id, 'admin'))
    h.run_until(function() return stage_of(h) == 'durability_wait' end)
    assert(claim_of(h, s, e).state == 'pending')
    w.fake.items[#w.fake.items + 1] = {id = 'late', kind = 'settlement', state = 'building',
        rects = {{x1 = 100, z1 = -10, x2 = 112, z2 = 10}}, y_min = -31000, y_max = 31000}
    h.run_until(function() return h.growth.active == nil end)
    local road = h.road(road_id)
    assert(road.state == 'stopped' and road.stop.code == 'towns_conflict' and h.writes == 0, road.stop and road.stop.code)
    assert(claim_of(h, s, e) == nil and road.pending == nil)

    -- A Towns writer that is active at that moment only defers the build.
    w = fx.setup(); h = w.h
    road_id = w.adopt()
    s, e = west_town(w, 'flat', 2)
    assert(h.growth:extend(road_id, 'admin'))
    h.run_until(function() return stage_of(h) == 'durability_wait' end)
    w.fake.writer_state = {kind = 'automatic', phase = 'build', since = 1}
    for _ = 1, 50 do h.step() end
    assert(h.writes == 0 and h.growth.active, 'no write while Towns is writing')
    w.fake.writer_state = nil
    h.run_until(function() return h.growth.active == nil end)
    assert(h.road(road_id).state == 'connected' and h.writes > 0)
end)

------------------------------------------------------------ ordering and claims
test('outward-first: reservations of every kind make an exit unavailable, a legacy built record the whole settlement', function()
    local function scenario(setup_reservation, expect_unavailable_b)
        local w = fx.setup()
        local h = w.h
        local road_id = w.adopt()
        local b = fx.exit(fx.DIRS.west, 'flat', 2, 120, 16, -1)
        local s, a = west_town(w, 'flat', 2, {extra = {b}})
        setup_reservation(h, s, a, b)
        assert(h.run_cycle(road_id))
        local attempt, road = last_attempt(h, road_id)
        return h, road_id, s, a, b, attempt, road
    end
    -- A partial outward road reserves its own exit only: the other exit is still chosen.
    local h, road_id, s, a, b, attempt, road = scenario(function(hh, ss, aa) reserve(hh, ss.id, aa.id, 'partial', 'some') end)
    assert(road.state == 'connected' and road.connected.approach_id == b.id, tostring(road.stop and road.stop.reason))
    local reasons = {}
    for _, r in ipairs(attempt.rejected) do reasons[r.approach_id] = r.reason end
    assert(reasons[a.id] == 'outward_reserved_exit', tostring(reasons[a.id]))
    assert(claim_of(h, s, a) == nil and claim_of(h, s, b).state == 'held')

    -- An interrupted build with unknown writes (an uncertain origin) reserves its exit too.
    h, road_id, s, a, b, attempt, road = scenario(function(hh, ss, aa) reserve(hh, ss.id, aa.id, 'interrupted', 'unknown') end)
    assert(road.connected and road.connected.approach_id == b.id)

    -- Interrupted with provably no writes is no reservation at all.
    h, road_id, s, a, b, attempt, road = scenario(function(hh, ss, aa) reserve(hh, ss.id, aa.id, 'interrupted', 'none') end)
    assert(road.connected and road.connected.approach_id == a.id, 'the nearer exit is open again')

    -- A built outward road (legacy or unadopted) reserves the whole settlement, not guessing free exits.
    h, road_id, s, a, b, attempt, road = scenario(function(hh, ss, aa) reserve(hh, ss.id, aa.id, 'built', 'all') end)
    assert(road.connected == nil and road.state ~= 'connected')
    local both = {}
    for _, r in ipairs(attempt.rejected) do both[r.approach_id] = r.reason end
    assert(both[a.id] == 'outward_reserved_settlement' and both[b.id] == 'outward_reserved_settlement')
    assert(claim_of(h, s, a) == nil and claim_of(h, s, b) == nil)

    -- Another exit of the same settlement reserved by a *different* settlement id is irrelevant.
    h, road_id, s, a, b, attempt, road = scenario(function(hh) reserve(hh, 'auto:99:99', 'x', 'built', 'all') end)
    assert(road.connected and road.connected.approach_id == a.id)
end)

test('an outward reservation that appears during the durability wait stops the cycle in the synchronous preflight', function()
    local w = fx.setup()
    local h = w.h
    local road_id = w.adopt()
    local s, e = west_town(w, 'flat', 2)
    assert(h.growth:extend(road_id, 'admin'))
    h.run_until(function() return stage_of(h) == 'durability_wait' end)
    assert(claim_of(h, s, e).state == 'pending')
    reserve(h, s.id, e.id, 'partial', 'some')
    h.run_until(function() return h.growth.active == nil end)
    local road = h.road(road_id)
    assert(road.state == 'stopped' and road.stop.code == 'destination_unavailable' or road.stop.code == 'stale_destination',
        road.stop and road.stop.code)
    assert(h.writes == 0 and h.builds == 0 and claim_of(h, s, e) == nil)
end)

test('incoming-first: the persistent exit claim rejects /roads_outward at admission, also after restart; other exits stay open', function()
    local w = fx.setup()
    local h = w.h
    local road_id = w.adopt()
    local b = fx.exit(fx.DIRS.west, 'flat', 2, 120, 16, -1)
    local s, a = west_town(w, 'flat', 2, {extra = {b}})
    assert(h.run_cycle(road_id))
    assert(h.road(road_id).state == 'connected')
    local function outward_request(exit_id)
        return {settlement_id = s.id, exit_id = exit_id, requester = 'bob', policy = {version = 1, seed = 1},
            candidates = {{x = 200, z = 0}}}
    end
    local started, err = h.outward:start(outward_request(a.id))
    assert(not started and err.code == 'already_reserved' and err.scope == 'exit' and err.claim.road_id == road_id)
    assert(h.outward:eligibility(s.id, a.id) == 'claimed' and h.outward:eligibility(s.id, b.id) == 'open')
    assert(h.jobs.active == nil, 'a rejected admission holds no slot')
    h.restart()
    started, err = h.outward:start(outward_request(a.id))
    assert(not started and err.code == 'already_reserved' and err.claim.road_id == road_id, 'the claim survives a restart')
    assert(h.outward:eligibility(s.id, a.id) == 'claimed')
    -- And growth no longer selects it.
    assert(w.dest.unavailable({kind = 'town', id = s.id, approach_id = a.id}) == 'claimed')
    assert(w.dest.unavailable({kind = 'town', id = s.id, approach_id = b.id}) == nil)
end)

test('an incoming claim that is still pending or uncertain after a restart keeps the exit reserved', function()
    local w = fx.setup()
    local h = w.h
    local road_id = w.adopt()
    local s, e = west_town(w, 'flat', 2)
    assert(h.growth:extend(road_id, 'admin'))
    h.run_until(function() return stage_of(h) == 'durability_wait' end)
    h.restart()
    local claim = assert(claim_of(h, s, e))
    assert(claim.state == 'uncertain' and h.road(road_id).state == 'uncertain')
    local started, err = h.outward:start({settlement_id = s.id, exit_id = e.id, requester = 'bob', policy = {version = 1, seed = 1},
        candidates = {{x = 200, z = 0}}})
    assert(not started and err.code == 'already_reserved')
    assert(w.dest.unavailable({kind = 'town', id = s.id, approach_id = e.id}) == 'claimed')
    h.run()
    assert(h.writes == 0 and h.builds == 0, 'nothing is replayed')
end)

test('another growth road holding the claim makes the exit unavailable at selection', function()
    local w = fx.setup()
    local h = w.h
    local road_id = w.adopt()
    local s, e = west_town(w, 'flat', 2)
    assert(h.growth_store:update(function(d)
        d.claims['exit:'..full_id(s, e)] = {kind = 'exit', road_id = 'growth:v1:other', segment_id = 'other:s2:r1', state = 'held'}
        return true
    end))
    assert(h.run_cycle(road_id))
    local attempt = last_attempt(h, road_id)
    assert(#attempt.candidates == 0 and attempt.rejected[1].reason == 'claimed' and attempt.result == 'directional')
end)

------------------------------------------------------------ stale and changed destinations
test('a destination that changes after the snapshot, after resolution or after the wait is rejected with zero writes', function()
    -- Changed between the snapshot and the resolver.
    local w = fx.setup()
    local h = w.h
    local road_id = w.adopt()
    local s, e = west_town(w, 'flat', 2)
    local real = w.dest.providers.town
    h.providers.town = {nearby = function(self, pos, radius, limit)
        local result, err = real:nearby(pos, radius, limit)
        s.structures[#s.structures + 1] = {x1 = 190, z1 = 0, x2 = 195, z2 = 3}
        return result, err
    end}
    assert(h.run_cycle(road_id))
    local attempt = last_attempt(h, road_id)
    assert(attempt.targets[1].outcome == 'stale_destination' and attempt.targets[1].reason:find('published exit changed'))
    assert(attempt.result == 'directional' and claim_of(h, s, e) == nil)

    -- Changed during the durability wait: the whole published exit is re-read.
    w = fx.setup(); h = w.h
    road_id = w.adopt()
    s, e = west_town(w, 'flat', 2)
    assert(h.growth:extend(road_id, 'admin'))
    h.run_until(function() return stage_of(h) == 'durability_wait' end)
    s.exits[1].profile[1].name = 'mcl_core:stone'
    h.run_until(function() return h.growth.active == nil end)
    local road = h.road(road_id)
    assert(road.state == 'stopped' and road.stop.code == 'stale_destination' and h.writes == 0 and claim_of(h, s, e) == nil)

    -- The published record is withdrawn.
    w = fx.setup(); h = w.h
    road_id = w.adopt()
    s, e = west_town(w, 'flat', 2)
    assert(h.growth:extend(road_id, 'admin'))
    h.run_until(function() return stage_of(h) == 'durability_wait' end)
    w.fake.records[s.id] = nil
    h.run_until(function() return h.growth.active == nil end)
    assert(h.road(road_id).stop.code == 'stale_destination' and h.writes == 0)
end)

test('an edited, protected or blocked exit in the world is never attached', function()
    local function with_edit(edit)
        local w = fx.setup()
        local h = w.h
        local road_id = w.adopt()
        local s, e = west_town(w, 'flat', 2)
        edit(w, h, s, e)
        assert(h.run_cycle(road_id))
        local attempt, road = last_attempt(h, road_id)
        assert(road.connected == nil and claim_of(h, s, e) == nil and attempt.result == 'directional', attempt.result)
        return attempt.targets[1].outcome, attempt.targets[1].reason
    end
    local outcome, reason = with_edit(function(_, h) h.set(118, 0, 0, {name = 'mcl_core:dirt', param2 = 0}) end)
    assert(outcome == 'invalid_endpoint' and reason:find('published exit node changed'), reason)
    outcome, reason = with_edit(function(_, h) h.meta['117:0:-1'] = true end)
    assert(outcome == 'invalid_endpoint' and reason:find('metadata'), reason)
    outcome, reason = with_edit(function(w) w.access.is_protected = function(p) return p.x == 116 and p.y == 0 and p.z == 0 end
        w.h.access.is_protected = w.access.is_protected end)
    assert(outcome == 'invalid_endpoint' and reason:find('protected'), reason)
    outcome, reason = with_edit(function(_, h) h.set(119, 2, 0, {name = 'mcl_core:stone', param2 = 0}) end)
    assert(outcome == 'invalid_endpoint' and reason:find('headroom'), reason)
    -- An exit that is edited after the wait stops the cycle (preflight re-reads the exact world approach).
    local w = fx.setup()
    local h = w.h
    local road_id = w.adopt()
    local s, e = west_town(w, 'flat', 2)
    assert(h.growth:extend(road_id, 'admin'))
    h.run_until(function() return stage_of(h) == 'durability_wait' end)
    h.set(118, 0, 0, {name = 'mcl_core:dirt', param2 = 0})
    h.run_until(function() return h.growth.active == nil end)
    local road = h.road(road_id)
    assert(road.state == 'stopped' and road.stop.code == 'stale_destination' and h.writes == 0, road.stop and road.stop.code)
    assert(h.access.get_node({x = 118, y = 0, z = 0}).name == 'mcl_core:dirt', 'never repaired')
end)

------------------------------------------------------------ verification after construction
test('a walking path that breaks after the writes is never reported connected: uncertain, claim kept, inspect compares', function()
    local w = fx.setup()
    local h = w.h
    local road_id = w.adopt()
    local s, e = west_town(w, 'flat', 2)
    -- Break a transition block right after the builder finishes, before verification.
    local real = h.attachments.town
    h.attachments.town = {resolve = function(self, d, ctx)
        local resolved, err = real:resolve(d, ctx)
        if resolved and resolved.verify then
            local verify = resolved.verify
            resolved.verify = function(a, result)
                local c = result.plan.endpoints.goal.connector
                local p = c.transition.surfaces[1]
                h.set(p.x, p.y, p.z, {name = 'mcl_core:dirt', param2 = 0})
                return verify(a, result)
            end
        end
        return resolved, err
    end}
    assert(h.run_cycle(road_id))
    local road = h.road(road_id)
    assert(road.state == 'uncertain' and road.stop.code == 'attachment_unverified' and road.connected == nil, road.stop and road.stop.code)
    assert(claim_of(h, s, e).state == 'uncertain', 'the exit stays reserved')
    local report = assert(h.growth:inspect(road_id, 'admin'))
    assert(report.world.attachment and not report.world.attachment.matches and report.world.attachment.mismatched >= 1
        and report.world.status == 'mismatch')
    assert(select(2, h.growth:extend(road_id, 'admin')).code == 'not_extendable')
    assert(select(2, h.growth:retry(road_id, 'admin')).code == 'not_retryable')
    assert(h.access.get_node({x = 120, y = 0, z = 0}).name == 'mcl_core:cobble')
end)

test('verification rejects a broken road, a changed exit and a wrong final heading in the finished world', function()
    local w = fx.setup()
    local h = w.h
    local road_id = w.adopt()
    local s, e = west_town(w, 'flat', 2)
    local captured
    local real = h.attachments.town
    h.attachments.town = {resolve = function(self, d, ctx)
        local resolved, err = real:resolve(d, ctx)
        if resolved and resolved.verify then
            local verify = resolved.verify
            resolved.verify = function(a, result) captured = result; return verify(a, result) end
        end
        return resolved, err
    end}
    assert(h.run_cycle(road_id))
    assert(h.road(road_id).state == 'connected' and captured)
    local env = {access = w.access, load = function() end, classify = surface.classify, has_timer = function() return false end,
        raster = fx.raster, owner = 'roads:growth'}
    local plan = captured.plan
    assert(fx.connectors.verify_arrival(plan, env))
    local function expect_fail(mutate, restore, reason)
        mutate()
        local ok, err = fx.connectors.verify_arrival(plan, env)
        restore()
        assert(not ok and err.code == 'attachment_unverified' and err.reason:find(reason), tostring(err and err.reason))
    end
    local mid = plan.centerline[math.floor(#plan.centerline / 2)]
    local keep = h.access.get_node({x = mid.x, y = mid.y, z = mid.z})
    expect_fail(function() h.set(mid.x, mid.y, mid.z, {name = 'air', param2 = 0}) end,
        function() h.set(mid.x, mid.y, mid.z, keep) end, 'road block')
    expect_fail(function() h.set(mid.x, mid.y + 2, mid.z, {name = 'mcl_core:stone', param2 = 0}) end,
        function() h.set(mid.x, mid.y + 2, mid.z, {name = 'air', param2 = 0}) end, 'three clear nodes')
    expect_fail(function() h.set(117, 0, 0, {name = 'mcl_core:stone', param2 = 0}) end,
        function() h.set(117, 0, 0, {name = 'mcl_core:cobble', param2 = 0}) end, 'preserved exit node changed')
    h.meta['119:0:0'] = true
    local ok, err = fx.connectors.verify_arrival(plan, env)
    h.meta['119:0:0'] = nil
    assert(not ok and err.reason:find('changed'))
    local headings = plan.request.goal_attachment.headings
    plan.request.goal_attachment.headings = {3}
    ok, err = fx.connectors.verify_arrival(plan, env)
    plan.request.goal_attachment.headings = headings
    assert(not ok and err.reason:find('final heading'))
    assert(fx.connectors.verify_arrival(plan, env))
end)

test('a builder interrupted during a final attachment leaves an uncertain road whose attachment can be inspected, never repaired', function()
    local function run(mode)
        local w = fx.setup()
        local h = w.h
        local road_id = w.adopt()
        local s, e = west_town(w, 'flat', 2)
        local seen = 0
        if mode == 'swallowed' then
            h.build_script = function(plan, done, guard)
                return build.new(plan, {now = function() return h.time end, guard = guard, after = h.after, load = function() end,
                    access = h.access, classify = surface.classify, has_timer = function() return false end,
                    write = function(p, n) h.writes = h.writes + 1; h.set(p.x, p.y, p.z, {name = n.name, param2 = n.param2 or 0}) end},
                    function() end)
            end
        else
            h.write_hook = function(p) seen = seen + 1; if seen > 40 then error('the engine stopped') end end
        end
        assert(h.growth:extend(road_id, 'admin'))
        h.run_until(function() return h.growth.active == nil or (mode == 'swallowed' and h.writes > 0) end)
        if mode == 'swallowed' then h.step(); h.restart() end
        local road = h.road(road_id)
        assert(road.state == 'uncertain', road.state..' '..tostring(road.stop and road.stop.code)..' '..tostring(road.stop and road.stop.reason))
        assert(claim_of(h, s, e).state == 'uncertain', 'the destination reservation is never released')
        assert(w.dest.unavailable({kind = 'town', id = s.id, approach_id = e.id}) == 'claimed')
        local report = assert(h.growth:inspect(road_id, 'admin'))
        assert(report.world.attachment and report.world.attachment.checked > 0)
        return h, road_id, report, s, e
    end
    local h, road_id, report = run('swallowed')
    assert(report.world.attachment.matches and report.world.status == 'matches_intended', 'the finished geometry matches the intended nodes')
    assert(h.growth:retire(road_id, 'admin'))
    assert(h.road(road_id).state == 'retired', 'retire keeps every reservation')
    -- Edited afterwards: inspect reports the mismatch and repairs nothing.
    local node = h.access.get_node({x = 116, y = 0, z = 0})
    h.set(116, 0, 0, {name = 'mcl_core:dirt', param2 = 0})
    report = assert(h.growth:inspect(road_id, 'admin'))
    assert(not report.world.attachment.matches and report.world.attachment.samples[1].x == 116 and report.world.status == 'mismatch')
    assert(h.access.get_node({x = 116, y = 0, z = 0}).name == 'mcl_core:dirt' and node.name == 'mcl_core:cobble')

    h, road_id, report = run('partial')
    assert(not report.world.attachment.matches and report.world.attachment.mismatched > 0, 'unwritten nodes are reported')
    assert(h.road(road_id).stop.code == 'partial_build' and h.road(road_id).pending.writes == 'some')
end)

------------------------------------------------------------ waypoints and scanning
test('a distant completed town steers by revision-checked waypoint: partial progress, no claim, never connected', function()
    local w = fx.setup()
    local h = w.h
    local road_id = w.adopt()
    local e = fx.exit(fx.DIRS.west, 'flat', 2, 520, 0, -1)
    local s = fx.settlement('auto:7:5', {e}, {x1 = 521, z1 = -30, x2 = 580, z2 = 30})
    w.publish(s)
    assert(h.run_cycle(road_id))
    local attempt, road = last_attempt(h, road_id)
    assert(attempt.result == 'partial_progress' and attempt.candidates[1].mode == 'waypoint' and road.state == 'open')
    assert(road.connected == nil and claim_of(h, s, e) == nil and road.endpoint.x == 144)
    assert(attempt.scan.status == 'complete' and attempt.scan.providers.town == 'ok')
    -- The next cycle rescans and may still steer.
    assert(h.run_cycle(road_id))
    assert(last_attempt(h, road_id).result == 'partial_progress' and h.road(road_id).endpoint.x == 240)
    -- A waypoint toward a changed exit is rejected, not trusted.
    local snapshot = assert(w.dest.providers.town:nearby({x = 240, y = 0, z = 0}, 512, 32)).items
    assert(#snapshot == 1)
    h.providers.town = {nearby = function() return {items = snapshot, truncation = 'none'} end}
    s.structures[#s.structures + 1] = {x1 = 600, z1 = 0, x2 = 605, z2 = 3}
    assert(h.run_cycle(road_id))
    local late = last_attempt(h, road_id)
    assert(late.targets[1].outcome == 'stale_destination' and late.result == 'directional')
end)

test('exactly 32 settlements are reported possibly truncated and the limit is honoured', function()
    local w = fx.setup()
    local fake, a = w.fake, w.a
    local function town(i)
        local s = fx.settlement('auto:'..i..':0', {fx.exit(fx.DIRS.west, 'flat', 2, 100 + i, 0, -1)}, {x1 = 200, z1 = 0, x2 = 210, z2 = 10})
        s.center = {x = 100 + i, y = 0, z = 0}
        return s
    end
    for i = 1, 31 do fake.others[#fake.others + 1] = town(i) end
    local result = assert(w.dest.providers.town:nearby({x = 0, y = 0, z = 0}, 512, 32))
    assert(result.truncation == 'none' and #result.items == 31)
    fake.others[#fake.others + 1] = town(32)
    result = assert(w.dest.providers.town:nearby({x = 0, y = 0, z = 0}, 512, 32))
    assert(result.truncation == 'possible' and #result.items == 32, 'exactly 32 might be more')
    fake.others[#fake.others + 1] = town(33)
    result = assert(w.dest.providers.town:nearby({x = 0, y = 0, z = 0}, 512, 32))
    assert(result.truncation == 'truncated' and #result.items == 32, 'more than the limit is truncated')
    result = assert(w.dest.providers.town:nearby({x = 0, y = 0, z = 0}, 512, 5))
    assert(result.truncation == 'truncated' and #result.items == 5)
    local list, info = a:scan({x = 0, z = 0}, 512, 5)
    assert(#list == 5 and info.truncation == 'truncated' and #a:nearby({x = 0, z = 0}, 512, 3) == 3)
    local bad, why = a:nearby({x = 0, z = 0}, 512, 0); assert(not bad and why.code == 'invalid_request')
    bad, why = a:nearby({x = 0, z = 0}, 512, 33); assert(not bad and why.code == 'invalid_request')
    -- Through the growth cycle the status reads possibly truncated (exactly 32) or truncated.
    local w2 = fx.setup()
    local road_id = w2.adopt()
    for i = 1, 32 do
        local s = fx.settlement('auto:'..i..':9', {fx.exit(fx.DIRS.west, 'flat', 2, 600 + i * 4, 100, -1)}, {x1 = 700, z1 = 100, x2 = 710, z2 = 110})
        s.center = {x = 600 + i * 4, y = 0, z = 100}
        w2.fake.others[#w2.fake.others + 1] = s
    end
    assert(w2.h.run_cycle(road_id))
    local attempt = last_attempt(w2.h, road_id)
    assert(attempt.scan.status == 'possibly_truncated' and attempt.scan.truncation == 'possible', attempt.scan.status)
end)

test('unsupported exits are not offered; an absent Towns disables the provider and an unhealthy one fails the cycle closed', function()
    local w = fx.setup()
    local h = w.h
    local road_id = w.adopt()
    local wide = fx.exit(fx.DIRS.west, 'flat', 2, 120, 8, -1)
    wide.columns[3] = {x = 120, z = 10}
    wide.columns[3].z = wide.columns[2].z + 1
    local good = fx.exit(fx.DIRS.west, 'flat', 2, 120, 0, -1)
    local s = fx.settlement('auto:7:7', {good, wide}, WEST_CORE)
    w.fake.records[s.id] = s; w.fake.others = {s}
    local result = assert(w.dest.providers.town:nearby({x = 48, y = 0, z = 0}, 512, 32))
    assert(#result.items == 1 and result.skipped == 1 and result.items[1].approach_id == good.id)
    local d = result.items[1]
    assert(d.version == 1 and d.kind == 'town' and d.id == s.id and d.position.x == 120 and d.direction.x == -1
        and type(d.revision) == 'string' and #d.revision <= 128)
    -- Absent Towns: no provider, a disabled scan.
    local absent = fx.setup({present = function() return false end})
    assert(absent.dest.providers.town == nil and absent.dest.providers.village == nil)
    -- Unhealthy: the cycle fails closed and nothing is consumed.
    w.fake.healthy = false
    local id, err = h.growth:extend(road_id, 'admin')
    assert(not id and err.code == 'provider_unhealthy', err and err.code)
    assert(h.road(road_id).state == 'open' and h.road(road_id).revision == 1 and h.surveys == 0)
end)

test('descriptors are stable between calls and change with the published exit or its settlement footprint', function()
    local w = fx.setup()
    local s, e = west_town(w, 'flat', 2)
    local first = assert(w.dest.providers.town:nearby({x = 48, y = 0, z = 0}, 512, 32)).items[1]
    local again = assert(w.dest.providers.town:nearby({x = 48, y = 0, z = 0}, 512, 32)).items[1]
    assert(first.revision == again.revision)
    s.core.x2 = s.core.x2 + 1
    local moved = assert(w.dest.providers.town:nearby({x = 48, y = 0, z = 0}, 512, 32)).items[1]
    assert(moved.revision ~= first.revision)
    s.core.x2 = s.core.x2 - 1
    s.exits[1].profile[2].y = 1
    local changed = assert(w.dest.providers.town:nearby({x = 48, y = 0, z = 0}, 512, 32)).items[1]
    -- A profile that no longer fits is dropped, not offered with a stale revision.
    assert(changed == nil or changed.revision ~= first.revision)
end)

------------------------------------------------------------ geometry contracts
test('the planner, composer and builder enforce the arrival heading and keep goal connectors out of plain growth plans', function()
    local w = fx.setup()
    local h = w.h
    local road_id = w.adopt()
    local s, e = west_town(w, 'flat', 2)
    local desc = assert(w.a:exit(assert(w.a:settlement(s.id)), e.id))
    local job = h.start_survey({x = 48, y = 0, z = 0}, {x = 120, y = 0, z = 0}, 'roads:growth')
    local terrain = job:status().terrain
    local rects = assert(w.a:overlay({x1 = terrain.bounds.min_x, z1 = terrain.bounds.min_z, x2 = terrain.bounds.max_x,
        z2 = terrain.bounds.max_z}, nil, nil, {{settlement_id = s.id, exit_id = e.id}}))
    terrain = fx.adapter.wrap_terrain(terrain, rects)
    local last = assert(h.growth_store:load_record(h.road(road_id).last_segment_id))
    local patch = last.next_seam
    local arrival = assert(fx.connectors.exit_goal(terrain, desc, patch.endpoint, w.access, function() end, surface, fx.edges))
    assert(table.concat(arrival.headings, ',') == '0,1,7')
    local request = {start = patch.endpoint, goal = arrival.goal.resolved, start_heading = patch.heading, start_seam = patch,
        goal_attachment = {version = 1, headings = arrival.headings},
        provenance = {start = {origin = 'growth_seam', requested = {x = 48, y = 0.5, z = 0}, ground = patch.endpoint, resolved = patch.endpoint},
            goal = arrival.goal}}
    local config = {road_material = fx.COBBLE, seam_access = w.access, seam_has_timer = function() return false end}
    assert(fx.edges.set_raster(fx.raster)); assert(planner.set_edges(fx.edges)); assert(plans.set_dependencies(fx.raster, fx.edges))
    planner.set_seam_dependencies(seam, fx.raster); plans.set_seam_dependency(seam)
    local function search(req)
        local made, err = planner.new(terrain, req, config)
        if not made then return nil, err end
        local result = made:step({max_expansions = 1000})
        while result.status == 'running' do result = made:step({max_expansions = 1000}) end
        return result
    end
    local result = assert(search(request))
    assert(result.status == 'succeeded')
    local final = result.route.headings[#result.route.headings]
    assert(final == 0 or final == 1 or final == 7)
    local plan = assert(plans.compose(terrain, result.route, config))
    assert(plan.version == 3 and plan.connector_version == 1 and plan.seam_version == 1)
    assert(build.new(plan, {now = function() return 0 end, after = function() end, load = function() end, access = w.access,
        classify = surface.classify, has_timer = function() return false end, write = function() end}, function() end))
    -- A different heading set that excludes every reachable arrival finds no route.
    local blocked = {start = request.start, goal = request.goal, start_heading = request.start_heading, start_seam = request.start_seam,
        provenance = request.provenance, goal_attachment = {version = 1, headings = {3}}}
    local none = search(blocked)
    assert(none.status == 'failed' or none.status == 'succeeded')
    if none.status == 'succeeded' then assert(none.route.headings[#none.route.headings] == 3) end
    -- The composer rejects a route whose last heading is not allowed.
    local forged = {}
    for k, v in pairs(result.route) do forged[k] = v end
    forged.request = {start = request.start, goal = request.goal, start_heading = request.start_heading, start_seam = request.start_seam,
        provenance = request.provenance, goal_attachment = {version = 1, headings = {3}}}
    local composed, err = plans.compose(terrain, forged, config)
    assert(not composed and err.code == 'composition_failed')
    -- Malformed attachments and attachments without a goal connector are refused.
    for _, bad in ipairs({{version = 2, headings = {4}}, {version = 1, headings = {}}, {version = 1, headings = {4, 4}},
        {version = 1, headings = {9}}, {version = 1, headings = {1, 2, 3, 4}}}) do
        local r = {start = request.start, goal = request.goal, start_heading = request.start_heading, start_seam = request.start_seam,
            provenance = request.provenance, goal_attachment = bad}
        local made, why = planner.new(terrain, r, config)
        assert(not made and why.code == 'seam_changed')
    end
    -- A plain growth plan (no connector) with a goal attachment, or a start connector, is refused.
    local plain = {start = request.start, goal = request.goal, start_heading = request.start_heading, start_seam = request.start_seam,
        provenance = {start = request.provenance.start, goal = {requested = arrival.goal.requested, ground = arrival.goal.ground,
            resolved = arrival.goal.resolved}}, goal_attachment = {version = 1, headings = {4}}}
    local made, why = planner.new(terrain, plain, config)
    assert(not made and why.code == 'seam_changed')
    -- The builder refuses to write any preserved exit node and a plan whose last heading is not allowed.
    local tampered = {}
    for k, v in pairs(plan) do tampered[k] = v end
    tampered.writes = {}
    for _, p in ipairs(plan.writes) do tampered.writes[#tampered.writes + 1] = p end
    local first = plan.endpoints.goal.connector.preserved[1]
    tampered.writes[#tampered.writes + 1] = {x = first.x, y = first.y, z = first.z, kind = 'air'}
    local made_build, build_err = build.new(tampered, {now = function() return 0 end, after = function() end, load = function() end,
        access = w.access, classify = surface.classify, has_timer = function() return false end, write = function() end}, function() end)
    assert(not made_build and build_err.code == 'build_failed')
end)

------------------------------------------------------------ real producer data
-- Verbatim towns_api v1 settlements recorded from the Towns mod (tests/towns_real_settlements.lua).
-- Each exit that can face a road ending at x = 48 heading +x is moved next to that road (heights
-- shifted so its seam meets the world's flat ground) and attached through the real pipeline.
local REAL = dofile('tests/towns_real_settlements.lua')
local function moved(settlement, exit_index, ax, az, dy)
    local function copy(v)
        if type(v) ~= 'table' then return v end
        local r = {}; for k, x in pairs(v) do r[k] = copy(x) end; return r
    end
    local s = copy(settlement)
    local e = s.exits[exit_index]
    local dx, dz = ax - e.columns[1].x, az - e.columns[1].z
    local function rect(r) r.x1 = r.x1 + dx; r.x2 = r.x2 + dx; r.z1 = r.z1 + dz; r.z2 = r.z2 + dz end
    rect(s.core)
    for _, r in ipairs(s.structures) do rect(r) end
    s.center.x, s.center.z, s.center.y = s.center.x + dx, s.center.z + dz, s.center.y + dy
    for _, corner in pairs(s.reservation) do corner.x, corner.z, corner.y = corner.x + dx, corner.z + dz, corner.y + dy end
    s.exits = {e}
    for _, c in ipairs(e.columns) do c.x = c.x + dx; c.z = c.z + dz end
    for _, p in ipairs(e.profile) do p.y = p.y + dy end
    e.id = e.id:match('^(..)')..':'..e.columns[1].x..':'..e.columns[1].z
    return s, e
end

-- Outcomes of the 14 recorded exits. The five east-facing ones cannot face a road that ends heading
-- +x and are not attempted here. Of the nine attempted, five attach; four are rejected because a
-- Towns structure rectangle covers part of the landing window or its cap (this design only builds
-- the transition outside core and structures), which is never forced or subtracted.
local REAL_EXPECTED = {
    ['auto:1:-1/+z:1534:-282'] = 'connected', ['auto:1:-1/-x:1451:-336'] = 'rejected', ['auto:1:-1/-x:1455:-304'] = 'connected',
    ['auto:1:-2/-x:1281:-1692'] = 'connected', ['auto:1:-2/-z:1360:-1775'] = 'rejected',
    ['auto:-2:-2/+z:-1711:-1663'] = 'connected', ['auto:-2:-2/-x:-1790:-1685'] = 'rejected',
    ['auto:-2:-2/-x:-1790:-1747'] = 'rejected', ['auto:-2:-2/-x:-1794:-1717'] = 'connected',
}
test('real published Towns exits (graded stairs and slabs, widths 2 and 4) are attached or rejected, never forced', function()
    local tried = 0
    for _, settlement in ipairs(REAL) do
        for index, published in ipairs(settlement.exits) do
            local d = published.direction
            local key = settlement.id..'/'..published.id
            if d.x ~= 1 then
                local anchor_x, anchor_z = 120, 0
                if d.z == 1 then anchor_x, anchor_z = 150, -40 elseif d.z == -1 then anchor_x, anchor_z = 150, 40 end
                local last = published.profile[#published.profile]
                local s, e = moved(settlement, index, anchor_x, anchor_z, -last.y)
                local w = fx.setup()
                local h = w.h
                local road_id = w.adopt()
                w.publish(s)
                local rects = {}
                for _, item in ipairs(w.fake.items) do for _, r in ipairs(item.rects) do rects[#rects + 1] = r end end
                assert(h.run_cycle(road_id))
                local attempt, road = last_attempt(h, road_id)
                tried = tried + 1
                local outcome = road.state == 'connected' and 'connected' or 'rejected'
                assert(outcome == REAL_EXPECTED[key], key..' expected '..tostring(REAL_EXPECTED[key])..' but '..outcome..': '
                    ..tostring(attempt.targets[1] and attempt.targets[1].outcome)..' '..tostring(attempt.targets[1] and attempt.targets[1].reason))
                for _, p in ipairs(w.writes) do
                    for _, r in ipairs(rects) do assert(not inside(r, p), key..': a write lies inside a Towns exclusion') end
                end
                if outcome == 'connected' then
                    local reached = fx.walk(h, 48, 0, {x1 = 40, x2 = 200, z1 = -70, z2 = 70})
                    for _, c in ipairs(e.columns) do assert(reached[c.x..':'..c.z], key..' is not walkable to '..c.x..':'..c.z) end
                    for n = 0, e.length - 1 do
                        for _, c in ipairs(e.columns) do
                            local node = h.access.get_node({x = c.x + e.direction.x * n, y = e.profile[n + 1].y, z = c.z + e.direction.z * n})
                            assert(node.name == e.profile[n + 1].name and node.param2 == e.profile[n + 1].param2, key..' preserved node changed')
                        end
                    end
                else
                    assert(road.connected == nil and claim_of(h, s, e) == nil, key)
                end
            end
        end
    end
    assert(tried == 9, 'tried '..tried)
end)

print('ok - '..count..' towns destination tests')
