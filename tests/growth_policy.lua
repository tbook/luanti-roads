-- SPDX-License-Identifier: GPL-3.0-or-later
-- Pure tests for the growth destination ranking and waypoint policy (#49).
-- Providers are plain tables that return fixed normalized-shape results.
local policy = dofile('src/growth_policy.lua')
local count = 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if not ok then error('growth policy '..name..': '..tostring(err)) end
    count = count + 1
end

local WEST = {x=-1, z=0}

local function desc(kind, id, approach, x, z, direction, revision)
    return {version=1, kind=kind, id=id, approach_id=approach,
        position={x=x, y=0, z=z}, direction=direction or WEST, revision=revision or 1}
end

-- A provider whose nearby() returns the given items, and records its calls.
local function provider(items, truncation)
    local p = {calls={}}
    function p:nearby(pos, radius, limit)
        self.calls[#self.calls+1] = {pos=pos, radius=radius, limit=limit}
        return {items=items, truncation=truncation or 'none'}
    end
    return p
end

local function road(endpoint, preferred)
    return {road_id='growth:v1:op1', endpoint=endpoint or {x=0, y=0, z=0},
        preferred=preferred or {x=1, z=0}, source={settlement_id='source', exit_id='e0'}}
end

local function input(providers, opts)
    opts = opts or {}
    return {road=opts.road or road(opts.endpoint, opts.preferred), providers=providers,
        unavailable=opts.unavailable or function() return nil end}
end

local function ids(result)
    local out = {}
    for i, c in ipairs(result.candidates) do out[i] = c.descriptor.approach_id end
    return out
end

local function rejected_reason(result, approach)
    for _, r in ipairs(result.rejected) do
        if r.approach_id == approach then return r.reason end
    end
end

test('absent providers disable the scan and keep directional fallback', function()
    local result = assert(policy.select(input({})))
    assert(result.scan.status == 'disabled' and result.scan.inspected == 0)
    for _, kind in ipairs(policy.KINDS) do assert(result.scan.providers[kind] == 'absent') end
    assert(#result.candidates == 0)
    assert(result.fallback[1].length == 96 and result.fallback[1].target.x == 96 and result.fallback[1].target.z == 0)
    assert(result.fallback[2].length == 64 and result.fallback[2].target.x == 64 and result.fallback[2].target.z == 0)
end)

test('one installed provider leaves the others absent and scanned', function()
    local town = provider({desc('town', 'b', 'e1', 100, 0)})
    local result = assert(policy.select(input({town=town})))
    assert(result.scan.providers.town == 'ok')
    assert(result.scan.providers.village == 'absent' and result.scan.providers.road == 'absent')
    assert(result.scan.status == 'complete')
    assert(#result.candidates == 1)
end)

test('unhealthy installed providers fail the cycle closed', function()
    local good = provider({desc('town', 'b', 'e1', 100, 0)})
    local failing = {nearby=function() return nil, {code='storage_budget'} end}
    local result, err = policy.select(input({town=good, road=failing}))
    assert(not result and err.code == 'provider_unhealthy' and err.provider == 'road')

    local raising = {nearby=function() error('boom') end}
    result, err = policy.select(input({village=raising}))
    assert(not result and err.code == 'provider_unhealthy' and err.provider == 'village')
    result, err = policy.select(input({town=raising}))
    assert(not result and err.code == 'provider_unhealthy')

    local no_truncation = {nearby=function() return {items={}} end}
    result, err = policy.select(input({town=no_truncation}))
    assert(not result and err.code == 'provider_invalid' and err.provider == 'town')

    local wrong_kind = {nearby=function() return {items={desc('road', 'r', 'a', 100, 0)}, truncation='none'} end}
    result, err = policy.select(input({town=wrong_kind}))
    assert(not result and err.code == 'provider_invalid')

    local wrong_version = desc('town', 'b', 'e1', 100, 0); wrong_version.version = 2
    result, err = policy.select(input({town=provider({wrong_version})}))
    assert(not result and err.code == 'provider_invalid')

    -- Out of radius is a rejection, not a cycle failure.
    result = assert(policy.select(input({town=provider({desc('town', 'b', 'e1', 513, 0)})})))
    assert(#result.candidates == 0 and rejected_reason(result, 'e1') == 'out_of_radius')
    result = assert(policy.select(input({town=provider({desc('town', 'b', 'e1', 512, 0)})})))
    assert(#result.candidates == 1 and result.candidates[1].mode == 'waypoint')

    result, err = policy.select({road=road(), providers={town={}}, unavailable=function() end})
    assert(not result and err.code == 'invalid_request')
    result, err = policy.select({road=road(), providers={}})
    assert(not result and err.code == 'invalid_request')
end)

test('truncation states and the exact-32 Towns rule', function()
    local one = {desc('town', 's1', 'e1', 100, 0)}
    assert(policy.select(input({town=provider(one, 'none')})).scan.status == 'complete')
    assert(policy.select(input({town=provider(one, 'possible')})).scan.status == 'possibly_truncated')
    assert(policy.select(input({town=provider(one, 'truncated')})).scan.status == 'truncated')

    local function settlements(n, exits_each, kind)
        local items = {}
        for i = 1, n do
            for e = 1, exits_each do
                items[#items+1] = desc(kind or 'town', 's' .. i, 'e' .. i .. '_' .. e, 20 + 2 * i, 0)
            end
        end
        return items
    end
    local r = assert(policy.select(input({town=provider(settlements(32, 1), 'none')})))
    assert(r.scan.truncation == 'possible' and r.scan.status == 'possibly_truncated')
    assert(r.scan.inspected == 32)
    r = assert(policy.select(input({town=provider(settlements(31, 1), 'none')})))
    assert(r.scan.truncation == 'none' and r.scan.status == 'complete')
    -- 16 settlements with two exits each are 32 descriptors but 16 settlements.
    r = assert(policy.select(input({town=provider(settlements(16, 2), 'none')})))
    assert(r.scan.truncation == 'none')
    -- A provider already reporting truncation keeps that state.
    r = assert(policy.select(input({town=provider(settlements(32, 1), 'truncated')})))
    assert(r.scan.status == 'truncated')
    -- Villages and roads have no settlement-count rule of their own.
    r = assert(policy.select(input({road=provider(settlements(32, 1, 'road'), 'none')})))
    assert(r.scan.truncation == 'none')
end)

test('descriptor caps: per provider, shared total and malformed fields', function()
    local items = {}
    for i = 1, 5 do items[i] = desc('road', 'r' .. i, 'a' .. i, 10 + i, 0) end
    local n = assert(policy.normalize('road', {items=items, truncation='none'}, 6))
    assert(#n.items == 5 and n.inspected == 5 and n.truncation == 'none')
    n = assert(policy.normalize('road', {items=items, truncation='none'}, 5))
    assert(#n.items == 5 and n.truncation == 'truncated')   -- exactly the budget is truncated
    n = assert(policy.normalize('road', {items=items, truncation='none'}, 2))
    assert(#n.items == 2 and n.inspected == 2 and n.truncation == 'truncated')
    n = assert(policy.normalize('road', {items={}, truncation='possible'}, 1))
    assert(n.truncation == 'possible')
    n = assert(policy.normalize('road', {items={}, truncation='none'}, 0))
    assert(n.truncation == 'truncated')   -- a zero budget means the cap was already reached
    local bad, err = policy.normalize('road', {items=items, truncation='none'}, -1)
    assert(not bad and err.code == 'invalid_request')

    -- Items beyond 32 distinct settlements are dropped and reported as truncated.
    local function many_of(kind, count, exits)
        local out = {}
        for i = 1, count do
            for e = 1, exits or 1 do
                out[#out+1] = desc(kind, kind .. i, kind .. 'a' .. i .. '_' .. e, 10 + i, 0)
            end
        end
        return out
    end
    local rp = provider(many_of('road', 33), 'none')
    local r = assert(policy.select(input({road=rp})))
    assert(rp.calls[1].limit == policy.SETTLEMENT_CAP and rp.calls[1].radius == 512)
    assert(r.scan.inspected == 33 and r.scan.status == 'truncated')
    assert(#r.candidates == policy.MAX_CANDIDATES)

    -- Three providers at 33 settlements each inspect 99 descriptors, all within budget.
    local t, v, rd = provider(many_of('town', 33), 'none'), provider(many_of('village', 33), 'none'),
        provider(many_of('road', 33), 'none')
    r = assert(policy.select(input({town=t, village=v, road=rd})))
    assert(r.scan.inspected == 99 and r.scan.status == 'truncated')
    assert(#r.candidates == policy.MAX_CANDIDATES)

    -- Malformed descriptor fields fail closed.
    local long = desc('town', string.rep('x', 129), 'e1', 100, 0)
    local _, e = policy.select(input({town=provider({long})}))
    assert(e and e.code == 'provider_invalid')
    local big = desc('town', 'b', 'e1', 31001, 0)
    _, e = policy.select(input({town=provider({big})}))
    assert(e and e.code == 'provider_invalid')
    local negative = desc('town', 'b', 'e1', 100, 0, WEST, -1)
    _, e = policy.select(input({town=provider({negative})}))
    assert(e and e.code == 'provider_invalid')
    local noid = desc('town', 'b', 'e1', 100, 0); noid.approach_id = ''
    _, e = policy.select(input({town=provider({noid})}))
    assert(e and e.code == 'provider_invalid')
end)

test('forward cone edges and source/self exclusion', function()
    local result = assert(policy.select(input({town=provider({
        desc('town', 'b', 'inside', 100, 173),   -- about 59.9 degrees
        desc('town', 'b', 'outside', 100, 174),  -- about 60.1 degrees
        desc('town', 'b', 'perp', 0, 50),        -- 90 degrees: zero dot product
        desc('town', 'b', 'back', -10, 0),
        desc('town', 'b', 'self_point', 0, 0),   -- no displacement
    })})))
    assert(rejected_reason(result, 'outside') == 'outside_cone')
    assert(rejected_reason(result, 'perp') == 'outside_cone')
    assert(rejected_reason(result, 'back') == 'outside_cone')
    assert(rejected_reason(result, 'self_point') == 'outside_cone')
    assert(ids(result)[1] == 'inside')

    result = assert(policy.select(input({town=provider({
        desc('town', 'b', 'near', 1, 0),
        desc('town', 'b', 'diag_edge_far', 150, 260),  -- just outside the cone
    })})))
    assert(rejected_reason(result, 'diag_edge_far') == 'outside_cone')
    assert(ids(result)[1] == 'near' and result.candidates[1].mode == 'final')

    -- Source settlement, own road by id or approach, and unsupported directions.
    result = assert(policy.select(input({
        town=provider({
            desc('town', 'source', 'source_exit', 100, 0),
            desc('town', 'other', 'valid', 200, 0),
            desc('town', 'other', 'diag_exit', 120, 0, {x=1, z=1}),
        }),
        road=provider({
            desc('road', 'growth:v1:op1', 'own_segment', 120, 0),
            desc('road', 'elsewhere', 'growth:v1:op1', 130, 0),
            desc('road', 'elsewhere', 'other_road', 140, 0),
        }),
    })))
    assert(rejected_reason(result, 'source_exit') == 'source')
    assert(rejected_reason(result, 'own_segment') == 'self')
    assert(rejected_reason(result, 'diag_exit') == 'unsupported_approach')
    assert(ids(result)[1] == 'other_road' and ids(result)[2] == 'valid')
    assert(rejected_reason(result, 'valid') == nil)
end)

test('unavailable destinations are rejected only inside the cone', function()
    local calls = 0
    local result = assert(policy.select(input({town=provider({
        desc('town', 'b', 'busy', 100, 0),
        desc('town', 'b', 'free', 200, 0),
        desc('town', 'b', 'behind', -100, 0),
    })}, {unavailable=function(d)
        calls = calls + 1
        if d.approach_id == 'busy' then return 'claimed' end
    end})))
    assert(calls == 2)
    assert(rejected_reason(result, 'busy') == 'claimed')
    assert(rejected_reason(result, 'behind') == 'outside_cone')
    assert(ids(result)[1] == 'free')
end)

test('deterministic ties regardless of provider order', function()
    local a = desc('town', 'x', 'a', 100, 0)
    local b = desc('town', 'x', 'b', 100, 0)
    local r = desc('road', 'y', 'r', 100, 0)
    local forward = assert(policy.select(input({town=provider({a, b}), road=provider({r})})))
    local reversed = assert(policy.select(input({town=provider({b, a}), road=provider({r})})))
    assert(table.concat(ids(forward), ',') == table.concat(ids(reversed), ','))
    -- Equal distance: kind orders first ('road' before 'town'), then approach id.
    assert(ids(forward)[1] == 'r' and ids(forward)[2] == 'a')

    local near = desc('town', 'z', 'q', 50, 0)
    local far = desc('town', 'z', 'p', 80, 0)
    local closer = assert(policy.select(input({town=provider({far, near})})))
    assert(ids(closer)[1] == 'q' and ids(closer)[2] == 'p')

    -- Duplicate approach ids are one destination.
    local dup = assert(policy.select(input({town=provider({a, desc('town', 'x', 'a', 100, 0, WEST, 2)})})))
    assert(#dup.candidates == 1 and rejected_reason(dup, 'a') == 'duplicate')
end)

test('destination switching across cycles uses fresh snapshots', function()
    local A = desc('town', 'A', 'eA', 300, 0)
    local B = desc('town', 'B', 'eB', 400, 0)
    local cycle1 = assert(policy.select(input({town=provider({B, A})})))
    assert(ids(cycle1)[1] == 'eA' and cycle1.candidates[1].mode == 'waypoint')

    -- A is no longer known: the selection moves to B.
    local cycle2 = assert(policy.select(input({town=provider({B})})))
    assert(ids(cycle2)[1] == 'eB')

    -- A nearer destination that appears later takes over, as a final approach.
    local C = desc('town', 'C', 'eC', 150, 0)
    local cycle3 = assert(policy.select(input({town=provider({B, C})})))
    assert(ids(cycle3)[1] == 'eC' and cycle3.candidates[1].mode == 'final')
    assert(cycle3.candidates[1].target.x == 150 and cycle3.candidates[1].target.z == 0)
end)

test('final range boundary is 192 nodes', function()
    local at = assert(policy.select(input({town=provider({desc('town', 'b', 'at', 192, 0)})})))
    assert(at.candidates[1].mode == 'final' and at.candidates[1].target.x == 192)
    local past = assert(policy.select(input({town=provider({desc('town', 'b', 'past', 193, 0)})})))
    assert(past.candidates[1].mode == 'waypoint' and past.candidates[1].outcome == 'partial_progress')
end)

test('distant waypoints are lattice points with positive progress', function()
    local result = assert(policy.select(input({town=provider({desc('town', 'b', 'far', 300, 0)})})))
    local c = result.candidates[1]
    assert(c.mode == 'waypoint' and c.outcome == 'partial_progress')
    assert(c.target.x == 96 and c.target.z == 0 and c.advance == 96)

    local endpoint = {x=6, y=0, z=-2}
    result = assert(policy.select(input({town=provider({desc('town', 'b', 'diag', 200, 100)})},
        {endpoint=endpoint})))
    c = result.candidates[1]
    assert(c.mode == 'waypoint' and c.advance >= policy.MIN_ADVANCE)
    assert((c.target.x - endpoint.x) % 4 == 0 and (c.target.z - endpoint.z) % 4 == 0)
    assert(math.abs(math.sqrt((c.target.x-endpoint.x)^2 + (c.target.z-endpoint.z)^2) - 96) <= 3)

    -- Every rounded waypoint on a fixed sweep keeps the planner lattice and progress.
    for ang = 0, 359, 7 do
        local rad = math.rad(ang)
        local dest = {x=math.floor(260 * math.cos(rad) + 0.5), z=math.floor(260 * math.sin(rad) + 0.5)}
        local wp = policy.waypoint({x=0, z=0}, dest, 96)
        assert(wp.x % 4 == 0 and wp.z % 4 == 0)
        assert(wp.advance >= policy.MIN_ADVANCE)
    end

    -- The 32-node rule is a guard: a short waypoint would not make it.
    local short = policy.waypoint({x=0, z=0}, {x=300, z=0}, 16)
    assert(short.advance < policy.MIN_ADVANCE)
end)

test('fallback targets follow the preferred direction', function()
    local result = assert(policy.select(input({}, {endpoint={x=4, y=0, z=8}, preferred={x=0, z=1}})))
    assert(result.fallback[1].length == 96 and result.fallback[1].target.x == 4 and result.fallback[1].target.z == 104)
    assert(result.fallback[2].length == 64 and result.fallback[2].target.x == 4 and result.fallback[2].target.z == 72)
    result = assert(policy.select(input({}, {preferred={x=-1, z=0}})))
    assert(result.fallback[1].target.x == -96 and result.fallback[2].target.x == -64)
end)

test('invalid requests are rejected before any provider is queried', function()
    local p = provider({desc('town', 'b', 'e1', 100, 0)})
    local result, err = policy.select({road=road(), providers={town=p}})
    assert(not result and err.code == 'invalid_request' and #p.calls == 0)
    result, err = policy.select({road={road_id='growth:v1:op1', endpoint={x=0, y=0, z=0},
        preferred={x=1, z=1}, source={settlement_id='source'}}, providers={town=p}, unavailable=function() end})
    assert(not result and err.code == 'invalid_request')
    result, err = policy.select({road=road(), providers={town={}}, unavailable=function() end})
    assert(not result and err.code == 'invalid_request')
end)

test('shared 1,024 descriptor budget binds across providers', function()
    local towns = {}
    for i = 1, 32 do
        for e = 1, 32 do towns[#towns+1] = desc('town', 't' .. i, 'te' .. i .. '_' .. e, 20 + 2 * i, 0) end
    end
    local vs = {}
    for i = 1, 100 do vs[i] = desc('village', 'v' .. (i % 4), 'va' .. i, 40, i % 5) end
    -- Exactly 1,024 town descriptors reach the shared cap: truncated, not complete.
    local r = assert(policy.select(input({town=provider(towns, 'none'), village=provider(vs, 'none')})))
    assert(r.scan.inspected == 1024 and r.scan.status == 'truncated')
    for _, x in ipairs(r.rejected) do assert(x.kind ~= 'village') end

    -- A town result of 1,000 leaves 24 for the village query; the rest is cut.
    local some = {}
    for i = 1, 1000 do some[i] = towns[i] end
    local vs2 = {}
    for i = 1, 100 do vs2[i] = desc('village', 'v' .. (i % 4), 'vb' .. i, 40, i % 5) end
    r = assert(policy.select(input({town=provider(some, 'none'), village=provider(vs2, 'none')})))
    assert(r.scan.inspected == 1024 and r.scan.status == 'truncated')
    assert(r.scan.providers.village == 'ok')
end)

test('per-settlement exit cap of 32 is enforced', function()
    local exits = {}
    for e = 1, 33 do exits[e] = desc('town', 'one', 'x' .. e, 100, 0) end
    local n = assert(policy.normalize('town', {items=exits, truncation='none'}, 1024))
    assert(#n.items == 32 and n.inspected == 33 and n.truncation == 'truncated')
    local r = assert(policy.select(input({town=provider(exits, 'none')})))
    assert(r.scan.status == 'truncated' and r.scan.inspected == 33 and #r.candidates == policy.MAX_CANDIDATES)

    -- Exactly 32 exits for one settlement is complete.
    local ok = {}
    for e = 1, 32 do ok[e] = desc('town', 'one', 'x' .. e, 100, 0) end
    n = assert(policy.normalize('town', {items=ok, truncation='none'}, 1024))
    assert(#n.items == 32 and n.truncation == 'none')
end)

test('32 settlements with several exits each are possibly truncated', function()
    local items = {}
    for i = 1, 32 do
        for e = 1, 3 do items[#items+1] = desc('town', 's' .. i, 's' .. i .. 'e' .. e, 20 + 2 * i, 0) end
    end
    local r = assert(policy.select(input({town=provider(items, 'none')})))
    assert(r.scan.status == 'possibly_truncated' and r.scan.truncation == 'possible')
    assert(r.scan.inspected == 96)
    -- The same settlements with a provider-reported truncation stay truncated.
    r = assert(policy.select(input({town=provider(items, 'truncated')})))
    assert(r.scan.status == 'truncated')
end)

test('dedup keys include kind so equal approach ids stay distinct', function()
    local r = assert(policy.select(input({
        town=provider({desc('town', 'x', 'shared', 100, 0)}),
        road=provider({desc('road', 'y', 'shared', 120, 0)}),
    })))
    assert(#r.candidates == 2)
    assert(r.candidates[1].descriptor.kind == 'town' and r.candidates[2].descriptor.kind == 'road')
    assert(rejected_reason(r, 'shared') == nil)
end)

print('ok - ' .. count .. ' growth destination policy tests')
