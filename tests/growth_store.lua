-- SPDX-License-Identifier: GPL-3.0-or-later
-- Durable growth registry: caps, dense index, save failures, restart conversion.
local growth_store = dofile('src/growth_store.lua')
local fx = dofile('tests/outward_fixture.lua')
local count = 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if not ok then error('growth store '..name..': '..tostring(err)) end
    count = count + 1
end
local L = growth_store.LIMITS

local function new_store(storage)
    storage = storage or fx.storage()
    return growth_store.new({storage = storage, serialize = fx.serialize, deserialize = fx.deserialize,
        now = function() return 7 end}), storage
end
local function entry(cells, kind, state)
    local list = {}
    for i, c in ipairs(cells or {'0:0'}) do list[i] = c end
    return {kind = kind or 'segment', state = state or 'built', writes = 'all', cells = list,
        bounds = {x1 = 0, z1 = 0, x2 = 10, z2 = 10}, bytes = 100}
end
local function road(segments, state)
    return {origin_op_id = 'op', source = {settlement_id = 's', exit_id = 'e'}, preferred = {x = 1, z = 0},
        revision = 1, endpoint = {x = 0, y = 0, z = 0}, local_heading = 0, last_segment_id = segments[#segments],
        segments = segments, state = state or 'open', next_seq = 2, activation = 'needs_departure', attempts = {}}
end
local function add_road(store, id, state)
    local sid = id..':s1'
    assert(store:update(function(d)
        d.segs[sid] = entry(); d.segs[sid].road_id = id
        d.roads[id] = road({sid}, state)
        return true
    end))
    return sid
end

test('an empty registry is healthy and updates are read back before they apply', function()
    local store, storage = new_store()
    assert(store:health() and #store:road_ids() == 0)
    add_road(store, 'r1')
    assert(store:road('r1').state == 'open')
    assert(storage.data[growth_store.PREFIX..'registry'])
    local copy = store:road('r1'); copy.state = 'hacked'
    assert(store:road('r1').state == 'open', 'accessors return copies')
    local again = new_store(storage)
    assert(again:road('r1').revision == 1 and again:entry('r1:s1').kind == 'segment')
end)

test('a failed save leaves the old document but never reuses an allocated sequence', function()
    local store, storage = new_store()
    add_road(store, 'r1')
    storage.fail_set = true
    local ok, err = store:update(function(d)
        d.roads.r1.next_seq = 5; d.roads.r1.state = 'planning'; d.roads.r1.pending = {segment_id = 'x'}
        return true
    end)
    assert(not ok and err.code == 'storage_failed')
    assert(store:road('r1').state == 'open' and store:road('r1').next_seq == 5, 'state reverts, identity advances')
    storage.fail_set = nil
    storage.mismatch = true
    ok, err = store:update(function(d) d.roads.r1.revision = 9; return true end)
    assert(not ok and err.reason:find('read%-back'))
    assert(store:road('r1').revision == 1)
end)

test('record, segment, road and claim caps fail with storage_budget and do not apply', function()
    local store = new_store()
    add_road(store, 'r1')
    local ok, err = store:update(function(d)
        for i = 1, L.segments do
            d.segs['x'..i] = entry()
            d.roads.r1.segments[#d.roads.r1.segments + 1] = 'x'..math.min(i, 5)
        end
        return true
    end)
    assert(not ok and err.code == 'storage_budget', err and err.code)
    ok, err = store:update(function(d) d.segs.big = entry({'0:0','0:1','0:2','0:3','0:4','0:5','0:6','0:7','0:8','0:9',
        '0:10','0:11','0:12','0:13','0:14','0:15','0:16'}); return true end)
    assert(not ok, 'a 17-cell entry is malformed')
    ok, err = store:update(function(d)
        for i = 1, L.roads + 1 do
            d.segs['s'..i] = entry(); d.segs['s'..i].road_id = 'r'..i
            d.roads['r'..i] = road({'s'..i})
        end
        return true
    end)
    assert(not ok and err.code == 'storage_budget' and err.limit == L.roads)
    -- Unadopted seeds count against the same road cap.
    ok, err = store:update(function(d)
        for i = 1, L.roads do d.segs['seed'..i] = entry({'0:0'}, 'seed', 'verified') end
        return true
    end)
    assert(not ok and err.code == 'storage_budget')
    ok, err = store:update(function(d)
        for i = 1, L.road_segments do
            d.segs['p'..i] = entry(); d.roads.r1.segments[#d.roads.r1.segments + 1] = 'p'..i
        end
        return true
    end)
    assert(not ok and err.code == 'storage_budget' and err.limit == L.road_segments)
    ok, err = store:update(function(d) d.roads.r1.stop = {reason = string.rep('x', L.registry_bytes + 1)}; return true end)
    assert(not ok and err.code == 'storage_budget' and err.limit == L.registry_bytes)
    assert(#store:road_ids() == 1 and store:counts().segments == 1)
end)

test('segment records are size bounded, read back and validated on load', function()
    local store, storage = new_store()
    local record = {schema = 1, id = 'r1:s1', filler = 'x'}
    assert(store:save_record(record))
    assert(store:load_record('r1:s1').filler == 'x')
    record.filler = string.rep('x', L.segment_bytes)
    local bytes, err = store:save_record(record)
    assert(not bytes and err.code == 'storage_budget' and err.limit == L.segment_bytes)
    assert(store:load_record('r1:s1').filler == 'x', 'the oversize record was not written')
    local _, missing = store:load_record('nope')
    assert(missing.code == 'segment_missing')
    storage.data[growth_store.PREFIX..'segment/bad'] = fx.serialize({schema = 2, id = 'bad'})
    local _, bad = store:load_record('bad')
    assert(bad.code == 'segment_corrupt')
    storage.data[growth_store.PREFIX..'segment/other'] = fx.serialize({schema = 1, id = 'different'})
    _, bad = store:load_record('other')
    assert(bad.code == 'segment_corrupt')
    storage.mismatch = true
    bytes, err = store:save_record({schema = 1, id = 'r2'})
    assert(not bytes and err.code == 'storage_failed')
end)

test('index queries are complete or fail with road_index_budget', function()
    local store = new_store()
    add_road(store, 'r1')
    local ids, info = assert(store:collect({x1 = 0, z1 = 0, x2 = 50, z2 = 50}))
    assert(#ids == 1 and ids[1] == 'r1:s1' and info.cells == 1)
    ids = assert(store:collect({x1 = 500, z1 = 500, x2 = 600, z2 = 600}))
    assert(#ids == 0, 'a distant query is clear')
    ids = assert(store:collect({x1 = 11, z1 = 0, x2 = 50, z2 = 50}))
    assert(#ids == 0, 'a cell hit outside the stored bounds is not an obstacle')
    -- Query size: 11 x 11 cells exceeds the 100-cell cap.
    local _, err = store:collect({x1 = 0, z1 = 0, x2 = 11 * 128 - 1, z2 = 11 * 128 - 1})
    assert(err.code == 'road_index_budget' and err.limit == L.query_cells and err.observed == 121)
    -- A 10 x 10 query is accepted.
    assert(store:collect({x1 = 0, z1 = 0, x2 = 10 * 128 - 1, z2 = 10 * 128 - 1}))
    -- Dense cells: 600 entries each referencing two queried cells = 1,200 > 1,024.
    assert(store:update(function(d)
        for i = 1, 600 do d.segs['dense'..i] = entry({'0:0', '1:0'}) end
        return true
    end))
    _, err = store:collect({x1 = 0, z1 = 0, x2 = 200, z2 = 50})
    assert(err.code == 'road_index_budget' and err.limit == L.query_references and err.observed == 1025)
    -- The same population queried through one cell stays within the cap.
    ids = assert(store:collect({x1 = 0, z1 = 0, x2 = 50, z2 = 50}))
    assert(#ids == 601)
    local bad = {x1 = 5, z1 = 5, x2 = 1, z2 = 1}
    _, err = store:collect(bad)
    assert(err.code == 'invalid_request')
end)

test('restart converts planning to stopped and building to uncertain, keeping every reservation', function()
    local store, storage = new_store()
    local planning = add_road(store, 'planning')
    local building = add_road(store, 'building')
    assert(store:update(function(d)
        d.roads.planning.state = 'planning'; d.roads.planning.pending = {segment_id = 'planning:s2', state = 'planning', writes = 'none'}
        d.roads.building.state = 'building'
        d.roads.building.pending = {segment_id = 'building:s2', state = 'building', writes = 'unknown'}
        d.roads.building.segments[2] = 'building:s2'
        d.segs['building:s2'] = entry({'0:0'}, 'segment', 'building'); d.segs['building:s2'].road_id = 'building'
        d.claims['exit:a/b'] = {kind = 'exit', road_id = 'building', segment_id = 'building:s2', state = 'pending'}
        return true
    end))
    local again = new_store(storage)
    assert(again:health())
    local p, b = again:road('planning'), again:road('building')
    assert(p.state == 'stopped' and p.pending == nil and p.stop.code == 'interrupted')
    assert(b.state == 'uncertain' and b.pending.state == 'uncertain' and b.stop.code == 'interrupted')
    assert(again:entry('building:s2').state == 'uncertain' and again:claim('exit:a/b').state == 'uncertain')
    assert(again:entry(planning) and again:entry(building))
    -- The conversion was persisted: a third load sees the same thing.
    local third = new_store(storage)
    assert(third:road('building').state == 'uncertain' and third:road('planning').state == 'stopped')
end)

test('an unreadable, oversized or newer registry disables growth instead of looking empty', function()
    local storage = fx.storage()
    storage.data[growth_store.PREFIX..'registry'] = 'not a table'
    local store = new_store(storage)
    local ok, err = store:health()
    assert(not ok and err.code == 'growth_disabled' and err.state == 'unreadable')
    local _, blocked = store:update(function() return true end)
    assert(blocked.code == 'growth_disabled')
    assert(store:collect({x1 = 0, z1 = 0, x2 = 1, z2 = 1}) == nil)
    assert(storage.data[growth_store.PREFIX..'registry'] == 'not a table', 'unreadable data is never overwritten')

    storage = fx.storage({[growth_store.PREFIX..'registry'] = fx.serialize({schema = 2, roads = {}, segs = {}, claims = {}})})
    store = new_store(storage)
    ok, err = store:health()
    assert(not ok and err.state == 'future_schema')
    assert(not store:update(function() return true end))

    storage = fx.storage({[growth_store.PREFIX..'registry'] = string.rep('x', L.registry_bytes + 1)})
    ok, err = new_store(storage):health()
    assert(not ok and err.state == 'unreadable')

    storage = fx.storage({[growth_store.PREFIX..'registry'] = fx.serialize({schema = 1, roads = {r = {state = 'bogus'}},
        segs = {}, claims = {}})})
    ok, err = new_store(storage):health()
    assert(not ok and err.state == 'unreadable')
    storage = fx.storage(); storage.fail_get = true
    ok, err = new_store(storage):health()
    assert(not ok and err.state == 'unreadable')
end)

test('settle applies known outcomes in memory and retries the save later', function()
    local store, storage = new_store()
    add_road(store, 'r1')
    storage.fail_set = true
    local persisted = store:settle(function(d) d.roads.r1.state = 'retired' end)
    assert(persisted == false and store:road('r1').state == 'retired')
    storage.fail_set = nil
    assert(store:health())
    assert(new_store(storage):road('r1').state == 'retired', 'the deferred save was retried')
end)

test('a building road without its pending intent disables growth instead of throwing', function()
    local storage = fx.storage()
    local seed = new_store(storage)
    add_road(seed, 'r1')
    local doc = fx.deserialize(storage.data[growth_store.PREFIX..'registry'])
    doc.roads.r1.state = 'building'; doc.roads.r1.pending = nil
    storage.data[growth_store.PREFIX..'registry'] = fx.serialize(doc)
    local ok, err = new_store(storage):health()
    assert(not ok and err.code == 'growth_disabled' and err.state == 'unreadable')
    doc.roads.r1.pending = {segment_id = 'missing', state = 'building'}
    storage.data[growth_store.PREFIX..'registry'] = fx.serialize(doc)
    ok, err = new_store(storage):health()
    assert(not ok and err.code == 'growth_disabled')
end)

print('ok - '..count..' growth store tests')
