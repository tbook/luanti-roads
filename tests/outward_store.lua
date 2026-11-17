-- SPDX-License-Identifier: GPL-3.0-or-later
local outward_store = dofile('src/outward_store.lua')
local fx = dofile('tests/outward_fixture.lua')
local count = 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if not ok then error('outward store '..name..': '..tostring(err)) end
    count = count + 1
end
local SID = 'auto:3:-2'
local function new_store(storage, clock)
    storage = storage or fx.storage()
    local t = clock or 100
    return outward_store.new({storage = storage, serialize = fx.serialize, deserialize = fx.deserialize,
        now = function() t = t + 1; return t end}), storage
end
local function make(store, exit_id, state, writes)
    local op = assert(store:new_op(SID, exit_id, {requester = 'alice', candidates = {{x=1, z=2}}}))
    op.state = state or 'failed'; op.writes = writes or 'none'
    return op
end

test('operations get stable identities and survive a reload', function()
    local store, storage = new_store()
    local op = make(store, '+x:1:2', 'built', 'all')
    op.road = {centerline = {{x=1, y=2, z=3}}, terminal_heading = 2}
    assert(store:save(SID, op))
    assert(op.op_id == SID..'/+x:1:2#1' and op.seq == 1)
    local again = new_store(storage)
    local doc = assert(again:doc(SID))
    assert(doc.operations[1].op_id == op.op_id and doc.operations[1].road.terminal_heading == 2)
    local second = assert(again:new_op(SID, '+x:1:2', {}))
    assert(second.seq == 2 and again:latest(SID).seq == 2)
end)

test('a built road reserves the settlement; partial and unknown work reserve only their exit', function()
    local store = new_store()
    assert(store:eligibility(SID, '+x:1:2') == 'open')
    local built = make(store, '+x:1:2', 'built', 'all')
    local state, detail = store:eligibility(SID, '+z:5:6')
    assert(state == 'reserved' and detail.scope == 'settlement' and detail.op_id == built.op_id)
    built.state = 'failed'; built.writes = 'none'
    for _, case in ipairs({{'partial', 'some'}, {'interrupted', 'unknown'}, {'building', 'unknown'}}) do
        local op = make(store, '+x:1:2', case[1], case[2])
        state, detail = store:eligibility(SID, '+x:1:2')
        assert(state == 'reserved' and detail.scope == 'exit' and detail.op_id == op.op_id, case[1])
        assert(store:eligibility(SID, '+z:5:6') == 'open', case[1]) -- other exits stay eligible
        op.state = 'failed'; op.writes = 'none'
    end
    for _, case in ipairs({{'failed', 'none'}, {'cancelled', 'none'}, {'interrupted', 'none'}, {'planning', 'none'}}) do
        make(store, '+x:1:2', case[1], case[2])
        assert(store:eligibility(SID, '+x:1:2') == 'open', case[1])
    end
end)

test('startup converts mid-flight work conservatively and never replays it', function()
    local store, storage = new_store()
    local planning = make(store, '+x:1:2', 'planning', 'none')
    local building = make(store, '+z:5:6', 'building', 'unknown')
    assert(store:save(SID))
    local fresh = new_store(storage)
    local summary = assert(fresh:recover())
    assert(summary.settlements == 1 and summary.converted == 1 and summary.failed_saves == 0)
    local doc = assert(fresh:doc(SID))
    assert(doc.operations[1].state == 'interrupted' and doc.operations[1].writes == 'none')
    assert(doc.operations[2].state == 'interrupted' and doc.operations[2].writes == 'unknown')
    assert(fresh:eligibility(SID, '+x:1:2') == 'open')
    assert(fresh:eligibility(SID, '+z:5:6') == 'reserved')
    -- Durable: another fresh store sees the converted states without converting again.
    local third = new_store(storage)
    assert(third:recover().converted == 0)
    assert(third:eligibility(SID, '+z:5:6') == 'reserved')
end)

test('a failed conversion save keeps the conversion and is retried later', function()
    local store, storage = new_store()
    make(store, '+x:1:2', 'building', 'unknown'); assert(store:save(SID))
    local fresh = new_store(storage)
    storage.fail_set = true
    local summary = fresh:recover(); assert(summary.failed_saves == 1)
    assert(fresh:eligibility(SID, '+x:1:2') == 'reserved') -- still reserved in memory
    assert(storage.data[outward_store.PREFIX..SID]:find('building'))
    storage.fail_set = nil
    assert(fresh:doc(SID)) -- retries the sweep save
    assert(not storage.data[outward_store.PREFIX..SID]:find('"building"'))
end)

test('unreadable or unsupported documents reserve the settlement and are never overwritten', function()
    local key = outward_store.PREFIX..SID
    for _, text in ipairs({'garbage(', fx.serialize({schema = 2, settlement_id = SID, next_seq = 1, operations = {}}),
        fx.serialize({schema = 1, settlement_id = 'other', next_seq = 1, operations = {}}), fx.serialize({schema = 1})}) do
        local store, storage = new_store(fx.storage({[key] = text}))
        local summary = store:recover(); assert(summary.unreadable == 1)
        local state = store:eligibility(SID, '+x:1:2'); assert(state == 'unreadable')
        local op, err = store:new_op(SID, '+x:1:2', {}); assert(not op and err.code == 'storage_failed')
        assert(not store:save(SID) and storage.data[key] == text)
        assert(select(2, store:doc(SID)).code == 'unreadable')
    end
    local store = new_store(fx.storage()); store = nil
end)

test('save failures and read-back mismatches are reported and leave memory authoritative', function()
    local store, storage = new_store()
    local op = make(store, '+x:1:2', 'partial', 'some')
    storage.fail_set = true
    local ok, err = store:save(SID, op); assert(not ok and err.code == 'storage_failed')
    assert(store:eligibility(SID, '+x:1:2') == 'reserved') -- reservation still applies this session
    storage.fail_set = nil; storage.mismatch = true
    ok, err = store:save(SID, op); assert(not ok and err.code == 'storage_failed' and err.reason:find('read%-back'))
    storage.mismatch = false
    assert(store:save(SID, op))
end)

test('an accept that cannot be saved can be discarded without a trace', function()
    local store, storage = new_store()
    local op = assert(store:new_op(SID, '+x:1:2', {}))
    storage.fail_set = true; assert(not store:save(SID, op))
    store:discard(SID, op)
    assert(#store:doc(SID).operations == 0 and store:doc(SID).next_seq == 1)
end)

test('retention evicts the oldest zero-write operations and keeps every reservation', function()
    local store, storage = new_store()
    local kept = make(store, '+x:1:2', 'partial', 'some')
    for i = 1, 7 do make(store, '+z:5:6', 'failed', 'none') end
    assert(store:save(SID))
    local doc = store:doc(SID)
    assert(#doc.operations == 5 and doc.operations[1].op_id == kept.op_id)
    assert(doc.operations[2].seq == 5 and doc.operations[5].seq == 8)
    -- An oversized document sheds old zero-write records, then fails closed.
    local big = make(store, '+z:5:6', 'failed', 'none'); big.diagnostics = string.rep('x', 70000)
    assert(not store:save(SID) )
    local small = new_store()
    local op = make(small, '+x:1:2', 'partial', 'some'); op.road = {note = string.rep('y', 70000)}
    local ok, err = small:save(SID); assert(not ok and err.code == 'storage_failed' and err.reason:find('exceeds'))
    local sheds = new_store()
    for i = 1, 3 do local o = make(sheds, '+z:5:6', 'failed', 'none'); o.diagnostics = string.rep('z', 30000) end
    assert(sheds:save(SID) and #sheds:doc(SID).operations < 3)
end)

print('ok - '..count..' outward store tests')
