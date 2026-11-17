-- SPDX-License-Identifier: GPL-3.0-or-later
-- Pure tests for the /roads_outward selection policy. The real Towns adapter
-- normalizes exits; eligibility comes from a plain table standing in for the
-- service.
local policy = dofile('src/outward_policy.lua')
local adapter = dofile('src/towns_adapter.lua')
local towns = dofile('tests/towns_fixture.lua')
local count = 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if not ok then error('outward policy '..name..': '..tostring(err)) end
    count = count + 1
end

local DIRS = {{x=1, z=0}, {x=-1, z=0}, {x=0, z=1}, {x=0, z=-1}}
local normalizer = adapter.new(function() return nil end) -- exit() never calls Towns

-- A fixture exit whose first column sits at (x, z).
local function placed_exit(d, kind, width, x, z)
    local e = towns.exit(d, kind, width)
    local dx, dz = x - e.columns[1].x, z - e.columns[1].z
    for _, c in ipairs(e.columns) do c.x = c.x + dx; c.z = c.z + dz end
    e.id = e.id:match('^(..)')..':'..e.columns[1].x..':'..e.columns[1].z
    return e
end

local function town(id, cx, cz, exits, half)
    local s = towns.settlement(id, exits)
    s.center = {x=cx, y=1, z=cz}
    half = half or 40
    s.reservation = {min={x=cx-half, y=-10, z=cz-half}, max={x=cx+half, y=40, z=cz+half}}
    -- The built footprint fills the reservation here, so nothing may land inside it.
    s.core = {x1=cx-half, z1=cz-half, x2=cx+half, z2=cz+half}; s.structures = {}
    return s
end

-- Eligibility map: a settlement key, or 'settlement/exit'. Anything else is open.
local function states(map)
    return function(sid, eid)
        if map[sid] then return map[sid] end
        if eid and map[sid..'/'..eid] then return map[sid..'/'..eid] end
        return 'open'
    end
end

local function request(settlements, overrides)
    local r = {requester={x=0, z=0}, world_seed='4242', settlements=settlements,
        exit=function(s, id) return normalizer:exit(s, id) end, eligibility=states({})}
    for k, v in pairs(overrides or {}) do r[k] = v end
    return r
end

-- Independent statement of the nominal planning landing.
local function nominal_of(desc)
    local dx, dz = desc.direction.x, desc.direction.z
    local centre = math.floor((desc.offsets.min + desc.offsets.max) / 2 + 0.5)
    return {x = desc.anchor.x + (desc.length + 1) * dx + centre * (-dz),
        z = desc.anchor.z + (desc.length + 1) * dz + centre * dx}
end

local function same_targets(a, b)
    if #a ~= #b then return false end
    for i = 1, #a do if a[i].x ~= b[i].x or a[i].z ~= b[i].z then return false end end
    return true
end

test('nearest open settlement wins, ties break by identity, blocked records are skipped', function()
    local near = town('auto:2:0', 100, 0, {placed_exit({x=1, z=0}, 'flat', 2, 150, 0)})
    local tie = town('auto:0:5', 0, 100, {placed_exit({x=0, z=1}, 'flat', 2, 0, 150)})
    local far = town('auto:1:0', 300, 0, {placed_exit({x=1, z=0}, 'flat', 2, 350, 0)})
    local chosen = assert(policy.select(request({far, tie, near})))
    assert(chosen.settlement_id == 'auto:0:5', chosen.settlement_id) -- equal distance, lower id
    assert(chosen.exit_id == '+z:0:150' and math.abs(chosen.settlement_distance - 100) < 1e-9)
    assert(policy.select(request({near, far, tie})).settlement_id == 'auto:0:5') -- input order is irrelevant
    chosen = assert(policy.select(request({far, tie, near}, {eligibility = states({['auto:0:5'] = 'reserved'})})))
    assert(chosen.settlement_id == 'auto:2:0')
    chosen = assert(policy.select(request({far, tie, near}, {eligibility = states({['auto:0:5'] = 'reserved', ['auto:2:0'] = 'unreadable'})})))
    assert(chosen.settlement_id == 'auto:1:0')
end)

test('radius is horizontal and inclusive at 512 nodes', function()
    local edge = town('auto:9:0', 512, 0, {placed_exit({x=1, z=0}, 'flat', 2, 562, 0)})
    local beyond = town('auto:8:0', 513, 0, {placed_exit({x=1, z=0}, 'flat', 2, 563, 0)})
    local diagonal = town('auto:7:7', 363, 363, {placed_exit({x=1, z=0}, 'flat', 2, 413, 363)}) -- about 513.4 nodes
    local chosen = assert(policy.select(request({beyond, diagonal, edge})))
    assert(chosen.settlement_id == 'auto:9:0')
    local none, err = policy.select(request({beyond, diagonal}))
    assert(not none and err.code == 'no_eligible_settlement' and err.considered == 0 and err.radius == 512)
    assert(err.reason == 'no completed settlement within 512 nodes', err.reason) -- none nearby: plain text
    assert(#err.blocked == 0)
    -- The requester position is what counts, not the settlement's y value.
    edge.center.y = -900
    assert(policy.select(request({edge})).settlement_id == 'auto:9:0')
end)

test('reserved, unreadable and busy settlements are excluded and reported', function()
    local a = town('auto:1:0', 100, 0, {placed_exit({x=1, z=0}, 'flat', 2, 150, 0)})
    local b = town('auto:0:1', 0, 100, {placed_exit({x=0, z=1}, 'flat', 2, 0, 150)})
    local c = town('auto:3:0', 200, 0, {placed_exit({x=1, z=0}, 'flat', 2, 250, 0)})
    local none, err = policy.select(request({a, b, c}, {eligibility = states({
        ['auto:1:0'] = 'reserved', ['auto:0:1'] = 'unreadable', ['auto:3:0'] = 'active'})}))
    assert(not none and err.code == 'no_eligible_settlement' and err.considered == 3)
    assert(#err.blocked == 3 and err.blocked[1].settlement_id == 'auto:0:1' and err.blocked[1].state == 'unreadable')
    assert(err.blocked[2].state == 'reserved' and err.blocked[3].state == 'active')
    -- Each skipped settlement carries its own reason; the summary counts what was found.
    assert(err.blocked[1].reason == 'has an unreadable outward record and is not usable', err.blocked[1].reason)
    assert(err.blocked[2].reason == 'already has a built outward road', err.blocked[2].reason)
    assert(err.blocked[3].reason == 'already has an outward road in progress', err.blocked[3].reason)
    assert(err.reason:find('3 found, none open', 1, true), err.reason)
    -- An unrecognised state is reported as not usable rather than hidden.
    none, err = policy.select(request({a}, {eligibility = states({['auto:1:0'] = 'mystery'})}))
    assert(not none and err.blocked[1].state == 'mystery' and err.blocked[1].reason == 'is not usable')
end)

test('exits are chosen in stable order; reserved and unsupported exits are skipped', function()
    local a = normalizer
    local s = town('auto:5:5', 200, 0, {
        placed_exit({x=1, z=0}, 'flat', 2, 240, 0),     -- +x:240:0, reserved below
        placed_exit({x=0, z=1}, 'flat', 2, 200, 150),   -- +z:200:150, unsupported below
        placed_exit({x=-1, z=0}, 'flat', 2, 160, 0)})   -- -x:160:0, open
    local unsupported = '+z:200:150'
    local function exit_fn(settlement, id)
        if id == unsupported then return nil, {code = 'unsupported_exit', reason = 'test'} end
        return a:exit(settlement, id)
    end
    local chosen = assert(policy.select(request({s}, {exit = exit_fn,
        eligibility = states({['auto:5:5/+x:240:0'] = 'partial'})})))
    assert(chosen.exit_id == '-x:160:0', chosen.exit_id)

    -- Every exit blocked: report it for this settlement; do not fall through to another one.
    local other = town('auto:6:6', 300, 0, {placed_exit({x=1, z=0}, 'flat', 2, 340, 0)})
    local none, err = policy.select(request({s, other}, {exit = exit_fn, eligibility = states({
        ['auto:5:5/+x:240:0'] = 'partial', ['auto:5:5/-x:160:0'] = 'reserved'})}))
    assert(not none and err.code == 'no_usable_exit' and err.settlement_id == 'auto:5:5', err and err.code)
    assert(#err.skipped == 3)
    local seen = {}
    for _, item in ipairs(err.skipped) do seen[item.exit_id] = item.state end
    assert(seen['+x:240:0'] == 'partial' and seen['-x:160:0'] == 'reserved' and seen[unsupported] == 'unsupported')
end)

test('candidates keep distance, angle, reservation and separation bounds for every exit shape', function()
    local checked = 0
    for _, d in ipairs(DIRS) do
        for _, kind in ipairs({'flat', 'down', 'up'}) do
            for _, width in ipairs({2, 4}) do
                for _, seed in ipairs({'1', '77'}) do
                    -- Exit at negative coordinates; the reservation box reaches 80 nodes out
                    -- so some seeded draws must be rejected and replaced.
                    local ex, ez = -120, -40
                    local e = placed_exit(d, kind, width, ex, ez)
                    local s = town('auto:-4:-1', ex, ez, {e}, 80)
                    local r = assert(policy.select(request({s}, {world_seed = seed})))
                    local desc = r.descriptor
                    local nominal = nominal_of(desc)
                    assert(r.nominal.x == nominal.x and r.nominal.z == nominal.z)
                    assert(#r.candidates >= 1 and #r.candidates <= 4)
                    local res = desc.reservation
                    for i, t in ipairs(r.candidates) do
                        assert(t.x == math.floor(t.x) and t.z == math.floor(t.z), 'integer')
                        local vx, vz = t.x - nominal.x, t.z - nominal.z
                        local dist = math.sqrt(vx * vx + vz * vz)
                        assert(dist >= 64 - 1e-9 and dist <= 128 + 1e-9, 'distance ' .. dist)
                        local cos = (vx * d.x + vz * d.z) / dist
                        assert(cos >= math.cos(math.pi / 4) - 1e-9, 'angle')
                        assert(not (t.x >= res.x1 and t.x <= res.x2 and t.z >= res.z1 and t.z <= res.z2), 'reservation')
                        local rx, rz = t.x - desc.anchor.x, t.z - desc.anchor.z
                        assert(rx * rx + rz * rz <= 192 * 192, 'requested separation')
                        assert(dist + 14 <= 192, 'resolved bound')
                        for j = 1, i - 1 do
                            assert(not (r.candidates[j].x == t.x and r.candidates[j].z == t.z), 'duplicate')
                        end
                        checked = checked + 1
                    end
                end
            end
        end
    end
    assert(checked >= 40, checked)
end)

test('unrestricted exits produce four distinct candidates; seeds and exits change them', function()
    local s = town('auto:2:2', 300, 0, {placed_exit({x=1, z=0}, 'flat', 2, 340, 0), placed_exit({x=0, z=1}, 'flat', 2, 300, 40)}, 10)
    local first = assert(policy.select(request({s})))
    assert(#first.candidates == 4 and first.exit_id == '+x:340:0')
    local again = assert(policy.select(request({s})))
    assert(same_targets(first.candidates, again.candidates), 'reproducible')
    local other_seed = assert(policy.select(request({s}, {world_seed = '4243'})))
    assert(not same_targets(first.candidates, other_seed.candidates), 'seed')
    local other_exit = assert(policy.select(request({s}, {eligibility = states({['auto:2:2/+x:340:0'] = 'partial'})})))
    assert(other_exit.exit_id == '+z:300:40' and not same_targets(first.candidates, other_exit.candidates), 'exit')
    -- A smaller count is a prefix of the same ordered sequence.
    local one = assert(policy.select(request({s}, {count = 1})))
    assert(#one.candidates == 1 and one.candidates[1].x == first.candidates[1].x and one.candidates[1].z == first.candidates[1].z)
end)

test('local randomness never reads or changes math.random', function()
    math.randomseed(12345)
    local expected = {math.random(), math.random(), math.random()}
    math.randomseed(12345)
    assert(policy.select(request({town('auto:4:4', 120, 0, {placed_exit({x=1, z=0}, 'flat', 2, 160, 0)})})))
    local actual = {math.random(), math.random(), math.random()}
    for i = 1, 3 do assert(actual[i] == expected[i], 'global sequence moved at ' .. i) end
end)

test('invalid requests and caps are rejected before any selection', function()
    local s = {town('auto:4:4', 120, 0, {placed_exit({x=1, z=0}, 'flat', 2, 160, 0)})}
    -- Build each broken request explicitly: nil fields cannot be expressed as overrides.
    local function broken(field, value) local r = request(s); r[field] = value; return r end
    local cases = {
        function() return policy.select(nil) end,
        function() return policy.select(broken('requester', nil)) end,
        function() return policy.select(broken('requester', {x = 0/0, z = 0})) end,
        function() return policy.select(broken('world_seed', nil)) end,
        function() return policy.select(broken('world_seed', '')) end,
        function() return policy.select(broken('world_seed', 1.5)) end,
        function() return policy.select(broken('settlements', nil)) end,
        function() return policy.select(broken('exit', nil)) end,
        function() return policy.select(broken('count', 0)) end,
        function() return policy.select(broken('count', 5)) end,
        function() return policy.select(broken('count', 2.5)) end,
    }
    for i, call in ipairs(cases) do
        local r, e = call()
        assert(not r and e.code == 'invalid_request', i)
    end
end)

test('realistic 64-bit mapgen seeds are kept as text and give reproducible targets', function()
    local s = {town('auto:4:4', 120, 0, {placed_exit({x=1, z=0}, 'flat', 2, 160, 0)})}
    local seeds = {'-8335498217344751253', '9223372036854775807', '-9223372036854775808', '18446744073709551615', '4242'}
    local seen = {}
    for _, seed in ipairs(seeds) do
        local first = assert(policy.select(request(s, {world_seed = seed})), seed)
        local again = assert(policy.select(request(s, {world_seed = seed})), seed)
        assert(first.policy.seed == seed, 'seed is persisted verbatim')
        assert(same_targets(first.candidates, again.candidates), 'same seed, same targets: ' .. seed)
        local key = first.candidates[1].x .. ':' .. first.candidates[1].z
        assert(not seen[key], 'distinct seeds differ: ' .. seed)
        seen[key] = true
    end
    -- A number that a double holds exactly is the same identity as its text.
    local from_number = assert(policy.select(request(s, {world_seed = 4242})))
    assert(from_number.policy.seed == '4242' and same_targets(from_number.candidates,
        assert(policy.select(request(s, {world_seed = '4242'}))).candidates))
    -- Numbers beyond 2^53 cannot be exact, so they are refused rather than rounded.
    local r, e = policy.select(request(s, {world_seed = 2 ^ 60}))
    assert(not r and e.code == 'invalid_request')
    for _, bad in ipairs({'', 'a|b', string.rep('9', 65)}) do
        r, e = policy.select(request(s, {world_seed = bad}))
        assert(not r and e.code == 'invalid_request', bad)
    end
end)

test('no candidate inside the source settlement or outside the bounds yields no_target', function()
    local s = town('auto:4:4', 120, 0, {placed_exit({x=1, z=0}, 'flat', 2, 160, 0)}, 1000)
    local r, e = policy.select(request({s}))
    assert(not r and e.code == 'no_target' and e.settlement_id == 'auto:4:4' and e.exit_id == '+x:160:0')
    assert(e.draws == 64)
    local n = e.rejected
    assert(n.outside_bounds + n.in_settlement + n.too_far + n.duplicate == 64 and n.in_settlement > 0)
    assert(e.reason:find('inside the source settlement', 1, true))
end)

test('real Testlandia settlement: targets may lie in the outskirts belt outside the footprint', function()
    local e = placed_exit({x=1, z=0}, 'flat', 4, -273, 2554)
    while #e.profile > 4 do table.remove(e.profile) end; e.length = 4 -- the real exit is 4 long
    assert(e.id == '+x:-273:2554')
    local s = town('auto:-1:2', -326, 2556, {e}, 245)
    s.center.y = 15
    s.reservation = {min={x=-571, y=-112, z=2311}, max={x=-81, y=157, z=2801}}
    s.core = {x1=-431, z1=2423, x2=-279, z2=2634}
    s.structures = {{x1=-282, z1=2548, x2=-274, z2=2563}, {x1=-268, z1=2530, x2=-256, z2=2546},
        {x1=-269, z1=2457, x2=-257, z2=2473}, {x1=-248, z1=2601, x2=-241, z2=2609}, {x1=-283, z1=2630, x2=-276, z2=2637}}
    local r, err = policy.select(request({s}, {requester = {x = -326, z = 2556}}))
    assert(r, err and (err.code .. ': ' .. tostring(err.reason) .. tostring(err.skipped and err.skipped[1].reason)))
    assert(r.nominal.x == -268 and r.nominal.z == 2556)
    assert(#r.candidates >= 1)
    local res = r.descriptor.reservation
    for _, t in ipairs(r.candidates) do
        assert(t.x >= res.x1 and t.x <= res.x2 and t.z >= res.z1 and t.z <= res.z2, 'inside the belt')
        for _, f in ipairs(r.descriptor.footprint) do
            assert(not (t.x >= f.x1 and t.x <= f.x2 and t.z >= f.z1 and t.z <= f.z2), 'outside the footprint')
        end
    end
    -- The landing and the first connector steps are not inside any footprint rect.
    for x = -273, -264 do
        for z = 2554, 2557 do
            for _, f in ipairs(r.descriptor.footprint) do
                assert(not (x >= f.x1 and x <= f.x2 and z >= f.z1 and z <= f.z2), 'landing ' .. x .. ',' .. z)
            end
        end
    end
end)

test('separation limit is exact and rejects rather than clamps', function()
    local anchor, nominal = {x = 0, z = 0}, {x = 0, z = 0}
    assert(policy.within_separation(anchor, nominal, {x = 178, z = 0}))
    assert(not policy.within_separation(anchor, nominal, {x = 179, z = 0}))
    anchor, nominal = {x = 0, z = 0}, {x = 20, z = 0}
    assert(policy.within_separation(anchor, nominal, {x = 180, z = 0}))
    assert(not policy.within_separation(anchor, nominal, {x = 193, z = 0}))
end)

test('the persisted policy records the chosen inputs', function()
    local s = town('auto:4:4', 120, 0, {placed_exit({x=1, z=0}, 'flat', 2, 160, 0)})
    local r = assert(policy.select(request({s}, {requester = {x = 5, z = -3}})))
    local p = r.policy
    assert(p.version == 1 and p.seed == '4242' and p.radius == 512 and p.count == #r.candidates)
    assert(p.requester.x == 5 and p.requester.z == -3 and p.max_angle == 45)
    assert(p.nominal.x == r.nominal.x and p.nominal.z == r.nominal.z and p.direction.x == 1)
    assert(p.distance_range[1] == 64 and p.distance_range[2] == 128)
end)

print('ok - ' .. count .. ' outward selection policy tests')
