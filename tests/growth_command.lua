-- SPDX-License-Identifier: GPL-3.0-or-later
-- /roads_grow through the registered command definition, over the real growth
-- and outward services in the shared simulated world (tests/growth_fixture.lua).
-- Only Towns, surveying, the job slot and the clock are scripted.
local commands = dofile('src/commands.lua')
local surface = dofile('src/surface.lua')
local fixture = dofile('tests/growth_fixture.lua')
local harness = fixture.harness
local SID, EAST, COBBLE = fixture.SID, fixture.EAST, fixture.COBBLE
local count = 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if not ok then error('growth command '..name..': '..tostring(err)) end
    count = count + 1
end

local function commands_for(h)
    local registered = {}
    local engine = {register_chatcommand = function(name, def) registered[name] = def end,
        get_player_by_name = function() return nil end}
    assert(commands.register(engine, h.jobs, surface, function() return {} end, nil, nil, {service = h.growth}))
    return registered
end
local function run(cmds, text, who)
    return cmds.roads_grow.func(who or 'admin', text)
end

test('/roads_grow is server-privileged, names the automatic setting, and needs the growth service', function()
    local h = harness()
    local def = assert(commands_for(h).roads_grow)
    assert(def.privs and def.privs.server == true)
    local description = def.description:lower()
    assert(description:find('may generate terrain', 1, true) and description:find('roads_growth_automatic', 1, true), description)
    assert(def.params:find('adopt <outward-op-id>', 1, true) and def.params:find('inspect <road-id>', 1, true), def.params)
    local bare = {}
    assert(commands.register({register_chatcommand = function(name) bare[name] = true end,
        get_player_by_name = function() return nil end}, h.jobs, surface, function() return {} end, nil))
    assert(bare.roads_grow == nil and bare.roads_status and bare.roads_cancel)
    local bad, why = commands.register({register_chatcommand = function() end,
        get_player_by_name = function() return nil end}, h.jobs, surface, function() return {} end, nil, nil, {})
    assert(bad == nil and why == 'growth command dependencies are incomplete', why)
end)

test('argument errors are reported before the service runs and write nothing', function()
    local h = harness()
    local cmds = commands_for(h)
    h.seeded_road()
    local sets = h.storage.sets
    local cases = {
        {'', 'missing action'},
        {'   ', 'missing action'},
        {'launch growth:v1:x', 'unknown action launch'},
        {'adopt', 'adopt takes exactly one argument'},
        {'adopt a b', 'adopt takes exactly one argument'},
        {'status', 'status takes exactly one argument'},
        {'extend a b', 'extend takes exactly one argument'},
        {'status outward:1', 'a growth road id starts with growth:v1:'},
        {'inspect auto:3:-2', 'a growth road id starts with growth:v1:'},
    }
    for _, c in ipairs(cases) do
        local ok, msg = run(cmds, c[1])
        assert(not ok and msg:find('invalid_request: ', 1, true) and msg:find(c[2], 1, true), c[1]..' -> '..tostring(msg))
        assert(msg:find('Usage: /roads_grow adopt <outward-op-id>', 1, true), c[1]..' -> '..tostring(msg))
    end
    assert(h.storage.sets == sets and h.growth:status().counts.roads == 0 and h.jobs.active == nil, 'no writes')
end)

test('unknown roads and operations are reported with the service code', function()
    local h = harness()
    local cmds = commands_for(h)
    local ok, msg = run(cmds, 'status growth:v1:none')
    assert(not ok and msg == 'unknown_road: no growth road growth:v1:none.', msg)
    ok, msg = run(cmds, 'adopt missing-op')
    assert(not ok and msg:find('unknown_operation', 1, true), msg)
    ok, msg = run(cmds, 'cancel growth:v1:none')
    assert(not ok and msg:find('no_plan', 1, true), msg)
    assert(h.growth:status().counts.roads == 0 and h.jobs.active == nil)
end)

test('a legacy outward road is refused explicitly and its reservation is kept', function()
    local h = harness({legacy = true})
    local cmds = commands_for(h)
    local status = h.seeded_road()
    local ok, msg = run(cmds, 'adopt '..status.op_id)
    assert(not ok and msg:find('legacy_unadoptable: this outward road was recorded without an intended growth seed', 1, true), msg)
    assert(h.growth:status().counts.roads == 0 and h.growth_store:counts().segments == 0)
    assert(h.outward:eligibility(SID, EAST) == 'reserved')
end)

test('adoption reports headings, seam and state, and repeating it changes nothing', function()
    local h = harness()
    local cmds = commands_for(h)
    local status = h.seeded_road()
    local road_id = 'growth:v1:'..status.op_id
    local ok, msg = run(cmds, 'adopt '..status.op_id)
    assert(ok, msg)
    assert(msg:find('Growth road '..road_id..' is adopted from outward operation '..status.op_id, 1, true), msg)
    assert(msg:find('Growth road '..road_id..': open, revision 1, endpoint (48.0, 0.0, 0.0)', 1, true), msg)
    assert(msg:find('Local heading 0 toward (1, 0); preferred outward (1, 0)', 1, true), msg)
    assert(msg:find('Destinations: no scan is recorded yet', 1, true) and msg:find('Seam: not compared here', 1, true), msg)
    local before = h.road(road_id)
    ok, msg = run(cmds, 'adopt '..status.op_id)
    assert(ok and msg:find('Adopting it again changes nothing', 1, true), msg)
    local after = h.road(road_id)
    assert(#h.growth_store:road_ids() == 1 and after.revision == before.revision and after.next_seq == before.next_seq)
    assert(h.builds == 0 and h.surveys == 0, 'adoption never surveys or builds')
end)

test('one extension at a time; the active cycle is shown and the published endpoint advances on repeat', function()
    local h = harness()
    local cmds = commands_for(h)
    local road_id = h.adopted()
    local ok, msg = run(cmds, 'extend '..road_id)
    assert(ok and msg:find('Growth cycle '..road_id..':s2:r1 started', 1, true), msg)
    assert(msg:find('Current cycle: stage planning, segment '..road_id..':s2:r1.', 1, true), msg)
    ok, msg = run(cmds, 'extend '..road_id)
    assert(not ok and msg:find('not_extendable: a growth cycle is already planning this road', 1, true), msg)
    h.run_until(function() return h.growth.active and h.growth.active.stage == 'surveying' end)
    ok, msg = run(cmds, 'status '..road_id)
    assert(ok and msg:find('Current cycle: stage surveying', 1, true), msg)
    h.run_until(function() return h.growth.active == nil end)
    ok, msg = run(cmds, 'status '..road_id)
    assert(ok and msg:find('revision 2, endpoint (144.0, 0.0, 0.0)', 1, true), msg)
    assert(msg:find('Attempt on '..road_id..':s2:r1 from revision 1: built (directional); 96 node fallback composed', 1, true), msg)
    assert(msg:find('Destinations: scan disabled (no destination provider is installed)', 1, true), msg)
    assert(msg:find('Selected: none; directional fallback (96 then 64 nodes)', 1, true), msg)
    assert(msg:find('Last segment '..road_id..':s2:r1.', 1, true), msg)
    -- A second, explicit cycle chains on the new seam and publishes the next endpoint.
    ok, msg = run(cmds, 'extend '..road_id)
    assert(ok and msg:find(road_id..':s3:r2 started', 1, true), msg)
    h.run_until(function() return h.growth.active == nil end)
    ok, msg = run(cmds, 'inspect '..road_id)
    assert(ok and msg:find('revision 3, endpoint (240.0, 0.0, 0.0)', 1, true), msg)
    assert(msg:find('World: matches_intended against the current endpoint seam', 1, true), msg)
    assert(h.builds == 2 and h.road(road_id).pending == nil)
end)

test('an edited seam refuses extension and retry with seam_changed, reports the mismatch and repairs nothing', function()
    local h = harness()
    local cmds = commands_for(h)
    local road_id = h.adopted()
    h.set(48, 0, 0, {name = 'mcl_core:dirt', param2 = 0})
    local ok, msg = run(cmds, 'extend '..road_id)
    assert(not ok and msg:find('seam_changed', 1, true), msg)
    assert(h.surveys == 0 and h.jobs.active == nil and h.road(road_id).revision == 1)
    ok, msg = run(cmds, 'inspect '..road_id)
    assert(ok and msg:find('World: mismatch against the current endpoint seam', 1, true), msg)
    assert(msg:find('differ or are unreadable', 1, true) and msg:find(' expected ', 1, true), msg)
    ok, msg = run(cmds, 'retry '..road_id)
    assert(not ok and msg:find('not_retryable: only a stopped road', 1, true), msg)
    assert(h.nodes['48:0:0'].name == 'mcl_core:dirt' and h.road(road_id).state == 'open', 'player edit left alone')
end)

test('cancellation stops with zero writes, and deliberate retry runs once the seam is verified again', function()
    local h = harness()
    local cmds = commands_for(h)
    local road_id = h.adopted()
    assert(run(cmds, 'extend '..road_id))
    h.run_until(function() return h.growth.active and h.growth.active.stage == 'surveying' end)
    local writes = h.writes
    local ok, msg = run(cmds, 'cancel '..road_id, 'alice')
    assert(ok and msg:find('Growth cycle for '..road_id..' cancelled by alice', 1, true), msg)
    assert(msg:find('Blocked: cancelled: growth cycle cancelled by alice', 1, true), msg)
    assert(msg:find('No writes were made; the server slot is released.', 1, true), msg)
    assert(msg:find('from revision 1: cancelled', 1, true), msg)
    assert(h.writes == writes and h.builds == 0 and h.jobs.active == nil, 'zero writes after cancellation')
    ok, msg = run(cmds, 'cancel '..road_id)
    assert(not ok and msg:find('no_plan', 1, true), msg)
    -- Retry is deliberate and uses a fresh identity; the endpoint and seam are unchanged.
    ok, msg = run(cmds, 'retry '..road_id)
    assert(ok and msg:find('Retry started as growth cycle '..road_id..':s3:r1', 1, true), msg)
    h.run_until(function() return h.growth.active == nil end)
    ok, msg = run(cmds, 'status '..road_id)
    assert(ok and msg:find('revision 2, endpoint (144.0, 0.0, 0.0)', 1, true), msg)
    assert(msg:find('Blocked:', 1, true) == nil, 'a published road is not blocked')
end)

test('a cancelled build is uncertain: reservations stay, the explanation is shown and retry is refused', function()
    local h = harness()
    local cmds = commands_for(h)
    local road_id = h.adopted()
    h.build_script = function() return {cancel = function() end} end
    assert(run(cmds, 'extend '..road_id))
    h.run_until(function() return h.builds == 1 end)
    local ok, msg = run(cmds, 'cancel '..road_id)
    assert(ok and msg:find('Stop: cancelled: cancelled after construction started by admin', 1, true), msg)
    assert(msg:find('Writes are unknown and every reservation is kept.', 1, true), msg)
    assert(not msg:find('server slot is released', 1, true), msg)
    assert(msg:find('Unfinished segment '..road_id..':s2:r1: uncertain, writes unknown.', 1, true), msg)
    assert(msg:find('never promotes, repairs or replays uncertain work', 1, true), msg)
    ok, msg = run(cmds, 'retry '..road_id)
    assert(not ok and msg:find('not_retryable', 1, true), msg)
    ok, msg = run(cmds, 'extend '..road_id)
    assert(not ok and msg:find('not_extendable: an earlier segment may have been written', 1, true), msg)
    assert(h.builds == 1 and h.road(road_id).state == 'uncertain' and h.growth_store:entry(road_id..':s2:r1').state == 'uncertain')
end)

test('retire is explicit, keeps every reservation and refuses further growth', function()
    local h = harness()
    local cmds = commands_for(h)
    local road_id = h.adopted()
    local ok, msg = run(cmds, 'retire '..road_id)
    assert(ok and msg:find('Growth road '..road_id..' is retired; every reservation is kept.', 1, true), msg)
    assert(msg:find('Retired by admin; was open.', 1, true), msg)
    ok, msg = run(cmds, 'extend '..road_id)
    assert(not ok and msg:find('not_extendable', 1, true), msg)
    ok, msg = run(cmds, 'retry '..road_id)
    assert(not ok and msg:find('not_retryable', 1, true), msg)
    assert(h.growth_store:entry(h.road(road_id).segments[1]) and h.outward:eligibility(SID, EAST) == 'reserved')
end)

test('a road that stopped with a scripted error reports the blocked reason and retries only after revalidation', function()
    local h = harness()
    local cmds = commands_for(h)
    local road_id = h.adopted()
    h.survey_error = {code = 'survey_failed', reason = 'scripted survey failure'}
    assert(run(cmds, 'extend '..road_id))
    h.run_until(function() return h.growth.active == nil end)
    local ok, msg = run(cmds, 'status '..road_id)
    assert(ok and msg:find('Blocked: survey_failed: scripted survey failure', 1, true), msg)
    assert(msg:find('survey_failed - scripted survey failure', 1, true), msg)
    h.set(48, 0, 0, {name = 'mcl_core:dirt', param2 = 0})
    ok, msg = run(cmds, 'retry '..road_id)
    assert(not ok and msg:find('seam_changed', 1, true), msg)
    assert(h.road(road_id).state == 'stopped' and h.nodes['48:0:0'].name == 'mcl_core:dirt', 'stop and edit left alone')
    h.set(48, 0, 0, {name = COBBLE, param2 = 0})
    h.survey_error = nil
    ok, msg = run(cmds, 'retry '..road_id)
    assert(ok and msg:find('Retry started', 1, true), msg)
    h.run_until(function() return h.growth.active == nil end)
    assert(h.road(road_id).state == 'open' and h.road(road_id).revision == 2)
end)

test('inspect shows at most four mismatched nodes and says when nothing was loaded', function()
    local h = harness()
    local cmds = commands_for(h)
    local road_id = h.adopted()
    local last = assert(h.growth_store:load_record(h.road(road_id).last_segment_id))
    local preserved = last.next_seam.preserved
    assert(#preserved >= 1)
    for _, p in ipairs(preserved) do h.set(p.x, p.y, p.z, {name = 'mcl_core:dirt', param2 = 0}) end
    local ok, msg = run(cmds, 'inspect '..road_id)
    assert(ok and msg:find('World: mismatch', 1, true), msg)
    local _, shown = msg:gsub('Node %(', '')
    assert(shown == math.min(4, #preserved), shown .. ' of ' .. #preserved)
    assert(msg:find('Inspection never promotes, repairs or replays work.', 1, true), msg)
    assert(h.nodes[preserved[1].x..':'..preserved[1].y..':'..preserved[1].z].name == 'mcl_core:dirt')
end)

test('the road is found from durable state after a restart and an interrupted cycle is shown conservatively', function()
    local h = harness()
    local road_id = h.adopted()
    local cmds = commands_for(h)
    assert(run(cmds, 'extend '..road_id))
    h.run_until(function() return h.growth.active and h.growth.active.stage == 'surveying' end)
    h.restart()
    cmds = commands_for(h)
    local ok, msg = run(cmds, 'status '..road_id)
    assert(ok and msg:find('Growth road '..road_id..': stopped', 1, true), msg)
    assert(msg:find('Blocked: interrupted', 1, true), msg)
    ok, msg = run(cmds, 'retry '..road_id)
    assert(ok and msg:find('Retry started as growth cycle '..road_id..':s3:r1', 1, true), msg)
    h.run_until(function() return h.growth.active == nil end)
    assert(h.road(road_id).revision == 2)
end)

local BUDGETS = {chunks = 96, expansions = 150000, destination_chunks = 64, reserved_chunks = 32,
    destination_expansions = 50000, reserved_expansions = 50000, attempts = 4}
test('presentation is bounded: the latest four attempts, capped lists and the explanation for uncertain work', function()
    local attempts = {}
    for i = 1, 6 do
        attempts[i] = {segment_id = 'seg'..i, from_revision = 1, outcome = 'blocked', chunks = i, expansions = i * 10,
            targets = {{length = 96, outcome = 'bounded_no_route', reason = 'no route ' .. i}}}
    end
    local text = commands.growth_summary({road_id = 'growth:v1:op', state = 'uncertain', revision = 1,
        endpoint = {x = 48, y = 0, z = 0}, local_heading = 2, preferred = {x = 0, z = 1}, segments = 3,
        source = {settlement_id = SID, exit_id = EAST}, origin_op_id = 'op', attempts = attempts,
        budgets = BUDGETS, active = false,
        pending = {segment_id = 'seg-pending', state = 'uncertain', writes = 'unknown'},
        stop = {code = 'cancelled', reason = 'cancelled after construction started; writes are unknown'},
        explanation = 'Writes may have happened. The reservation is kept.'})
    assert(text:find('Local heading 2 toward (0, 1); preferred outward (0, 1)', 1, true), text)
    assert(text:find('Unfinished segment seg-pending: uncertain, writes unknown.', 1, true), text)
    assert(text:find('Destinations: no scan is recorded yet', 1, true), text)
    assert(text:find('Limits per cycle: 96 chunks (64 for destinations, 32 reserved for fallback), 150000 expansions (50000 per destination attempt, 50000 reserved for fallback), 4 attempts.', 1, true), text)
    assert(text:find('Stop: cancelled: cancelled after construction started; writes are unknown.', 1, true), text)
    assert(text:find('Writes may have happened.', 1, true), text)
    assert(not text:find('seg1 ', 1, true) and not text:find('seg2 ', 1, true), 'only the latest four attempts are shown')
    assert(text:find('Attempt on seg6 from revision 1: blocked; 96 node fallback bounded_no_route - no route 6; 6 chunks, 60 expansions.', 1, true), text)
    local active = commands.growth_summary({road_id = 'growth:v1:op', state = 'open', revision = 1,
        endpoint = {x = 0, y = 0, z = 0}, local_heading = 0, preferred = {x = 1, z = 0}, segments = 1, source = {},
        attempts = {}, budgets = {chunks = 96, expansions = 150000, destination_chunks = 64, reserved_chunks = 32, destination_expansions = 50000,
            reserved_expansions = 50000, attempts = 4, used_chunks = 3, used_expansions = 900},
        active = true, stage = 'surveying', pending = {segment_id = 'seg-live', state = 'planning', writes = 'none'}})
    assert(active:find('Current cycle: stage surveying, segment seg-live.', 1, true), active)
    assert(active:find('4 attempts (used 3 chunks, 900 expansions).', 1, true), active)
    assert(commands.growth_summary(nil) == 'No growth road is recorded for this identifier.')
end)

print('ok - '..count..' growth command tests')
