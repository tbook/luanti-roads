-- SPDX-License-Identifier: GPL-3.0-or-later
local adapter = dofile('src/towns_adapter.lua')
local towns = dofile('tests/towns_fixture.lua')
local count = 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if not ok then error('towns adapter '..name..': '..tostring(err)) end
    count = count + 1
end
local function ready(exits)
    local fake = towns.new()
    local s = towns.settlement('auto:3:-2', exits)
    fake.records[s.id] = s
    local a = adapter.new(function() return fake.api end, function() return fake.now or 0 end)
    return fake, a, s
end

test('absent, unsupported and unhealthy Towns are distinct failures', function()
    local a = adapter.new(function() return nil end)
    local s, e = a:settlement('auto:3:-2'); assert(not s and e.code == 'towns_unavailable')
    local fake = towns.new({version = 2})
    a = adapter.new(function() return fake.api end)
    s, e = a:settlement('x'); assert(not s and e.code == 'towns_unsupported')
    fake.api.version = nil
    s, e = a:settlement('x'); assert(not s and e.code == 'towns_unsupported')
    fake.api.version = 1; fake.healthy = false
    s, e = a:settlement('x'); assert(not s and e.code == 'towns_unavailable')
    a = adapter.new(function() error('no api') end)
    s, e = a:settlement('x'); assert(not s and e.code == 'towns_unavailable')
    assert(a:writer() == nil)
end)

test('every Towns settlement status is ineligible and only complete records pass', function()
    local fake, a, s = ready()
    for _, status in ipairs({'not_found', 'incomplete', 'unsupported', 'invalid', 'unavailable'}) do
        fake.statuses['other'] = status
        local r, e = a:settlement('other')
        assert(not r and e.code == 'ineligible_settlement' and e.status == status, status)
    end
    local r = assert(a:settlement(s.id)); assert(r.id == s.id)
    r.center.x = 99; assert(fake.records[s.id].center.x == 0)
    fake.records[s.id].state = 'building'
    local bad; r, bad = a:settlement(s.id); assert(not r and bad.code == 'ineligible_settlement')
    fake.records[s.id].state = 'complete'; fake.records[s.id].core = nil
    r, bad = a:settlement(s.id); assert(not r and bad.status == 'invalid')
end)

test('exits normalize flat and graded geometry in every direction at negative coordinates', function()
    for _, d in ipairs({{x=1, z=0}, {x=-1, z=0}, {x=0, z=1}, {x=0, z=-1}}) do
        for _, kind in ipairs({'flat', 'down', 'up'}) do
            for _, width in ipairs({2, 4}) do
                local exit = towns.exit(d, kind, width)
                for _, c in ipairs(exit.columns) do c.x = c.x - 120; c.z = c.z - 40 end
                exit.id = exit.id:match('^(..)')..':'..exit.columns[1].x..':'..exit.columns[1].z
                local _, a, s = ready({exit})
                local desc = assert(a:exit(s, exit.id))
                assert(desc.offsets.max - desc.offsets.min + 1 == width)
                assert(desc.offsets.min <= 0 and desc.offsets.max >= 0)
                assert(desc.anchor.x == exit.columns[1].x and desc.anchor.y == exit.profile[1].y)
                assert(desc.length == #exit.profile and desc.reservation.x1 == -60)
                assert(desc.direction.x == d.x and desc.direction.z == d.z)
                assert(a:recheck(desc))
            end
        end
    end
end)

test('missing, duplicate, narrow, wide and misoriented exits are rejected', function()
    local _, a, s = ready()
    local r, e = a:exit(s, 'nope'); assert(not r and e.code == 'unsupported_exit')
    local function mutated(fn)
        local exit = towns.exit({x=1, z=0}, 'flat', 2); fn(exit)
        local _, adapter2, settlement = ready({exit})
        return adapter2:exit(settlement, exit.id)
    end
    local cases = {
        function(x) x.columns = {x.columns[1]} end,                              -- width 1
        function(x) x.columns = {{x=0, z=0}, {x=0, z=1}, {x=0, z=2}} end,         -- width 3
        function(x) x.columns = {{x=0, z=0}, {x=0, z=2}} end,                     -- gap
        function(x) x.columns = {{x=0, z=0}, {x=1, z=1}} end,                     -- not across
        function(x) x.direction = {x=1, z=1} end,
        function(x) x.length = 5 end,
        function(x) x.profile[2].name = 'mcl_core:stone' end,
        function(x) x.profile[2] = {y=1, name='mcl_stairs:stair_cobble', param2=0} end, -- sideways stair
        function(x) x.profile[2] = {y=1, name='mcl_core:cobble', param2=2} end,
    }
    for i, change in ipairs(cases) do
        r, e = mutated(change); assert(not r and e.code == 'unsupported_exit', i)
    end
    local twin = towns.exit({x=1, z=0}, 'flat', 2)
    local _, a2, s2 = ready({twin, twin})
    r, e = a2:exit(s2, twin.id); assert(not r and e.code == 'unsupported_exit')
end)

test('recheck refuses a changed or withdrawn exit', function()
    local fake, a, s = ready()
    local desc = assert(a:exit(s, s.exits[1].id))
    assert(a:recheck(desc))
    fake.records[s.id].exits[1].profile[1].y = 2
    local r, e = a:recheck(desc); assert(not r and e.code == 'stale_exit')
    fake.records[s.id] = nil
    r, e = a:recheck(desc); assert(not r and e.code == 'stale_exit')
end)

test('overlay covers exclusions of every kind and other exits, and never reads absence as safety', function()
    local fake, a, s = ready({towns.exit({x=1, z=0}, 'flat', 2), towns.exit({x=0, z=1}, 'flat', 2)})
    fake.items = {{id='c', kind='candidate', state='contacted', rects={{x1=30, z1=30, x2=40, z2=40}}, y_min=-31000, y_max=31000},
        {id='far', kind='settlement', state='building', rects={{x1=500, z1=500, x2=510, z2=510}}, y_min=0, y_max=9}}
    local other = towns.settlement('auto:9:9', {towns.exit({x=-1, z=0}, 'flat', 2)})
    other.exits[1].columns = {{x=70, z=10}, {x=70, z=11}}; fake.others = {other, s}
    local desc = assert(a:exit(s, s.exits[1].id))
    local rects = assert(a:overlay({x1=-20, z1=-20, x2=100, z2=100}, s, desc.exit_id))
    local function covered(x, z)
        for _, r in ipairs(rects) do if x >= r.x1 and x <= r.x2 and z >= r.z1 and z <= r.z2 then return true end end
        return false
    end
    assert(covered(35, 35)) -- candidate
    assert(not covered(505, 505)) -- outside the query
    assert(covered(0, 4)) -- other exit of the source settlement (+z), seam included
    assert(not covered(3, 0)) -- the selected exit's own steps are not overlaid
    assert(covered(65, 10)) -- other settlement's exit footprint
    fake.exclusions_error = 'too_many'
    local r, e = a:overlay({x1=0, z1=0, x2=10, z2=10}, s, desc.exit_id); assert(not r and e.code == 'towns_unavailable')
    fake.exclusions_error = nil; fake.healthy = false
    r, e = a:overlay({x1=0, z1=0, x2=10, z2=10}, s, desc.exit_id); assert(not r and e.code == 'towns_unavailable')
end)

test('overlay fails closed on malformed exclusion items', function()
    local fake, a, s = ready()
    for _, bad in ipairs({'x', {id = 'a'}, {id = 'a', rects = 5}, {id = 'a', rects = {{x1 = 1}}}}) do
        fake.items = {bad}
        local r, e = a:overlay({x1 = 0, z1 = 0, x2 = 10, z2 = 10}, s, 'nope')
        assert(not r and e.code == 'towns_unavailable')
    end
end)

test('terrain wrapper reports excluded columns as structures and delegates the rest', function()
    local terrain = {version=1, owner='o', bounds={min_x=-50, max_x=50, min_y=-5, max_y=5, min_z=-50, max_z=50},
        get_column=function(x, z) return {status='ok', ground_y=x} end}
    local wrapped = adapter.wrap_terrain(terrain, {{x1=0, z1=0, x2=20, z2=3}, {x1=-100, z1=-100, x2=-90, z2=-90}})
    assert(wrapped.bounds == terrain.bounds and wrapped.owner == 'o' and wrapped.version == 1)
    assert(wrapped.get_column(10, 2).status == 'structure' and wrapped.get_column(21, 2).ground_y == 21)
    assert(wrapped.get_column(10, 4).status == 'ok' and wrapped.get_column(-1, 0).status == 'ok')
    assert(wrapped.get_column(-95, -95).status == 'ok')
end)

local function plan_at(x, y, z) return {writes = {{x=x, y=y, z=z, kind='road'}}} end
test('build guard defers on a writer or candidate, fails on a settlement, and times out', function()
    local fake, a = ready()
    local guard = a:new_guard()
    assert(guard(plan_at(5, 1, 5)) == 'ok')
    fake.writer_state = {kind='automatic', phase='build', since=1}
    assert(guard(plan_at(5, 1, 5)) == 'defer')
    fake.writer_state = nil
    fake.items = {{id='c', kind='candidate', state='inspecting', rects={{x1=0, z1=0, x2=9, z2=9}}, y_min=-31000, y_max=31000}}
    assert(guard(plan_at(5, 1, 5)) == 'defer')
    assert(guard(plan_at(50, 1, 50)) == 'ok')
    fake.items = {{id='s', kind='settlement', state='complete', rects={{x1=0, z1=0, x2=9, z2=9}}, y_min=0, y_max=10}}
    local v, e = guard(plan_at(5, 1, 5)); assert(v == 'fail' and e.code == 'towns_conflict' and e.position.x == 5)
    assert(guard(plan_at(5, 11, 5)) == 'ok') -- above the settlement's vertical extent
    fake.items = {}
    fake.exclusions_error = 'down'
    v, e = guard(plan_at(5, 1, 5)); assert(v == 'fail' and e.code == 'towns_unavailable')
    fake.exclusions_error = nil
    local g2 = a:new_guard()
    fake.writer_state = {kind='manual', phase='search', since=0}
    fake.now = 10; assert(g2(plan_at(5, 1, 5)) == 'defer')
    fake.now = 189; assert(g2(plan_at(5, 1, 5)) == 'defer')
    fake.now = 190; v, e = g2(plan_at(5, 1, 5)); assert(v == 'fail' and e.code == 'towns_busy')
    fake.writer_error = true
    local w = a:writer(); assert(w and w.phase == 'query_failed') -- a query error counts as busy
end)

test('nearby keeps Towns order, drops incomplete or malformed records and returns copies', function()
    local fake, a, s = ready()
    local near = towns.settlement('auto:1:0', {}); near.center = {x = 40, y = 1, z = 0}
    local far = towns.settlement('auto:2:0', {}); far.center = {x = 300, y = 1, z = 0}
    local broken = towns.settlement('auto:3:0', {}); broken.core = nil
    local building = towns.settlement('auto:4:0', {}); building.state = 'building'
    fake.others = {s, near, far, broken, building}
    local list, e = a:nearby({x = 0, z = 0}, 512)
    assert(list and not e)
    local ids = {}
    for _, r in ipairs(list) do ids[#ids + 1] = r.id end
    assert(table.concat(ids, ',') == 'auto:3:-2,auto:1:0,auto:2:0', table.concat(ids, ','))
    list[2].center.x = 999
    assert(near.center.x == 40, 'returned records are copies')
    local bad, why = a:nearby(nil, 512); assert(not bad and why.code == 'invalid_request')
    fake.healthy = false
    bad, why = a:nearby({x = 0, z = 0}, 512); assert(not bad and why.code == 'towns_unavailable')
    fake.healthy = true; fake.api.version = 2
    bad, why = a:nearby({x = 0, z = 0}, 512); assert(not bad and why.code == 'towns_unsupported')
end)

print('ok - '..count..' towns adapter tests')
