-- SPDX-License-Identifier: GPL-3.0-or-later
local planner = dofile('src/planner.lua')
local raster = dofile('src/raster.lua')
local edges = dofile('src/edges.lua')
local fixtures = dofile('tests/terrain.lua')
assert(edges.set_raster(raster))
local count = 0
local function test(name,fn)
    local ok,err = pcall(fn)
    if not ok then error(name .. ': ' .. tostring(err)) end
    count = count + 1
end
local function request(x,z)
    local a,b = {x=0,y=0,z=0},{x=x,y=0,z=z}
    return {start=a,goal=b,provenance={start={requested=a,ground=a,resolved=a},goal={requested=b,ground=b,resolved=b}}}
end
local function run(s, size)
    local r
    repeat r = s:step({max_expansions=size}) until r.status ~= 'running'
    return r
end
local function route_string(r)
    local s = ''
    for _,p in ipairs(r.centerline) do s = s .. p.x .. ',' .. p.y .. ',' .. p.z .. ';' end
    for _,h in ipairs(r.headings) do s = s .. h .. ',' end
    return s .. ':' .. r.cost
end
test('flat route and slice equivalence',function()
    assert(planner.set_edges(edges))
    local t = fixtures.rectangle(-9,21,-13,13,0)
    local a = run(assert(planner.new(t,request(12,4))),1000)
    local b = run(assert(planner.new(t,request(12,4))),1)
    assert(a.status == 'succeeded' and b.status == 'succeeded')
    assert(route_string(a.route) == route_string(b.route))
    assert(a.metrics.expansions == b.metrics.expansions)
    assert(a.route.metrics.length > 0 and a.route.request.provenance.goal.resolved.x == 12)
end)
test('barrier and budget failures',function()
    local t = fixtures.rectangle(-5,13,-5,5,0)
    for z=-5,5 do for x=5,7 do t:set_column(x,z,0,{status='water'}) end end
    local r = run(assert(planner.new(t,request(8,0))),1000)
    assert(r.status == 'failed' and r.error.code == 'bounded_no_route' and r.metrics.rejections.water)
    t = fixtures.rectangle(-9,21,-9,9,0)
    for _,case in ipairs({{max_expansions=1,code='expansion_budget'}, {max_states=1,code='state_budget'}, {max_heap_entries=1,code='heap_budget'}}) do
        r = run(assert(planner.new(t,request(12,0),case)),1000)
        assert(r.error.code == case.code)
    end
end)
test('unsnapped endpoint ground must match the surveyed column',function()
    local t = fixtures.rectangle(-9,21,-9,9,0)
    local req = request(8,0)
    req.provenance.goal.requested = {x=7,y=0,z=0}
    req.provenance.goal.ground = {x=7,y=0,z=0}
    assert(planner.new(t,req))
    t:set_column(7,0,0,{status='water'})
    local s,err = planner.new(t,req)
    assert(not s and err.code == 'invalid_endpoint' and err.position.x == 7)
    t:set_column(7,0,10)
    s,err = planner.new(t,req)
    assert(not s and err.code == 'invalid_endpoint' and err.position.x == 7)
end)
test('road detours through a pass around a high ridge',function()
    local t = fixtures.rectangle(-17,33,-25,25,0)
    for x=5,11 do for z=-12,8 do t:set_column(x,z,4) end end
    local r = run(assert(planner.new(t,request(20,0))),1000)
    assert(r.status == 'succeeded')
    local detoured=false
    for _,p in ipairs(r.route.centerline) do if math.abs(p.z) >= 12 then detoured=true end end
    assert(detoured and r.route.metrics.length > 20 and (r.metrics.rejections.grade or r.metrics.rejections.earthwork))
end)
test('deadline pending and cancellation',function()
    local t = fixtures.rectangle(-9,21,-9,9,0)
    local s = assert(planner.new(t,request(12,0)))
    local calls=0
    local r = s:step({max_expansions=100,deadline=1},function() calls=calls+1; return calls == 1 and 0 or 1 end)
    assert(r.status == 'running' and r.metrics.expansions == 0)
    r = run(s,1)
    local expected = run(assert(planner.new(t,request(12,0))),1000)
    assert(route_string(r.route) == route_string(expected.route))
    s = assert(planner.new(t,request(12,0)))
    r = s:cancel(); assert(r.status == 'cancelled' and s:cancel() == r and s:step({max_expansions=1}) == r)
end)
test('invalid slices terminate idempotently',function()
    local t = fixtures.rectangle(-9,21,-9,9,0)
    local s = assert(planner.new(t,request(12,0)))
    local r = s:step({max_expansions=0})
    assert(r.status == 'failed' and r.error.code == 'invalid_config')
    assert(s:step({max_expansions=1}) == r and s:cancel() == r)
end)

local function graph_edges(graph)
    local ds={{1,0},{1,1},{0,1},{-1,1},{-1,0},{-1,-1},{0,-1},{1,-1}}
    return {evaluate=function(_,_,s,h)
        local k=s.i..':'..s.j..':'..(s.heading == nil and 's' or s.heading)
        local c=graph[k] and graph[k][h]
        if not c then return {ok=false,code='outside'} end
        local d=ds[h+1]
        return {ok=true,cost=c,next_state={i=s.i+d[1],j=s.j+d[2],heading=h},
            metrics={length=c,ascent=0,descent=0,grade=0,turn_count=0,cut_count=0,fill_count=0}}
    end}
end
test('equal f and heuristic priorities use insertion order',function()
    local t=fixtures.rectangle(-5,17,-9,9,0)
    local diagonal=math.sqrt(32)
    assert(planner.set_edges(graph_edges({['0:0:s']={[1]=diagonal,[7]=diagonal},
        ['1:1:1']={[0]=4},['1:-1:7']={[0]=4},
        ['2:1:0']={[7]=diagonal},['2:-1:0']={[1]=diagonal}})))
    local r=run(assert(planner.new(t,request(12,0))),1)
    assert(r.status == 'succeeded' and r.route.headings[1] == 1
        and r.route.headings[2] == 0 and r.route.headings[3] == 7)
    assert(r.route.centerline[2].x == 4 and r.route.centerline[2].z == 4)
    assert(planner.set_edges(edges))
end)
test('arrivals with different headings retain different continuations',function()
    local t=fixtures.rectangle(-5,13,-5,13,0)
    assert(planner.set_edges(graph_edges({['0:0:s']={[0]=4,[1]=math.sqrt(32)},
        ['1:0:0']={[1]=6},['1:1:1']={[0]=4},['2:1:1']={[2]=4}})))
    local r=run(assert(planner.new(t,request(8,8))),1)
    assert(r.status == 'succeeded' and #r.route.headings == 3)
    assert(r.route.headings[1] == 0 and r.route.headings[2] == 1 and r.route.headings[3] == 2)
    assert(planner.set_edges(edges))
end)

-- A finite directed graph provides a separate Dijkstra oracle, while retaining
-- valid heading-state transitions. Some edges deliberately improve a state.
test('Dijkstra oracle, stale heap entries and stable ties',function()
    local t = fixtures.rectangle(-1,21,-13,13,0)
    local graph = {}
    local function add(i,j,h,nh,c)
        local k=i..':'..j..':'..(h == nil and 's' or h)
        graph[k] = graph[k] or {}; graph[k][nh]=c
    end
    add(0,0,nil,0,12); add(0,0,nil,1,6); add(1,1,1,7,6)
    add(1,0,0,1,6); add(2,1,7,0,4); add(2,1,1,0,4)
    add(3,1,0,7,6); add(4,0,7,0,4)
    local ds={{1,0},{1,1},{0,1},{-1,1},{-1,0},{-1,-1},{0,-1},{1,-1}}
    local fake = {evaluate=function(_,_,s,h)
        local k=s.i..':'..s.j..':'..(s.heading == nil and 's' or s.heading)
        local c=graph[k] and graph[k][h]
        if not c then return {ok=false,code='outside',reason='no edge'} end
        local d=ds[h+1]
        return {ok=true,cost=c,next_state={i=s.i+d[1],j=s.j+d[2],heading=h},
            metrics={length=c,ascent=0,descent=0,grade=0,turn_count=0,cut_count=0,fill_count=0}}
    end}
    assert(planner.set_edges(fake))
    local queue={{i=0,j=0,h=nil,c=0}}; local best={}; local oracle
    while #queue > 0 do
        local idx=1; for n=2,#queue do if queue[n].c < queue[idx].c then idx=n end end
        local s=table.remove(queue,idx); local k=s.i..':'..s.j..':'..(s.h == nil and 's' or s.h)
        if not best[k] or s.c < best[k] then
            best[k]=s.c
            if s.i == 4 and s.j == 0 then oracle=s.c; break end
            for h,c in pairs(graph[k] or {}) do local d=ds[h+1]; queue[#queue+1]={i=s.i+d[1],j=s.j+d[2],h=h,c=s.c+c} end
        end
    end
    local a=run(assert(planner.new(t,request(16,0))),1000)
    local b=run(assert(planner.new(t,request(16,0))),1)
    assert(a.status == 'succeeded' and a.route.cost == oracle and route_string(a.route)==route_string(b.route))
    assert(planner.set_edges(edges))
end)
test('deadline while removing stale entries preserves the remaining frontier',function()
    local t = fixtures.rectangle(-1,21,-9,9,0)
    local fake = {evaluate=function(_,_,s,h)
        local dest,c
        if s.heading == nil and h == 0 then dest,c={i=1,j=0,heading=0},20
        elseif s.heading == nil and h == 1 then dest,c={i=1,j=1,heading=1},6
        elseif s.heading == nil and h == 2 then dest,c={i=0,j=1,heading=2},40
        elseif s.i == 1 and s.j == 1 and h == 0 then dest,c={i=1,j=0,heading=0},6 end
        if not dest then return {ok=false,code='outside'} end
        return {ok=true,next_state=dest,cost=c,metrics={length=c,ascent=0,descent=0,grade=0,turn_count=0,cut_count=0,fill_count=0}}
    end}
    assert(planner.set_edges(fake))
    local s=assert(planner.new(t,request(16,0)))
    local calls=0
    local result=s:step({max_expansions=100,deadline=1},function()
        calls=calls+1; return calls >= 8 and 1 or 0
    end)
    assert(result.status == 'running' and result.metrics.stale_entries == 1)
    result=run(s,1)
    local baseline=run(assert(planner.new(t,request(16,0))),100)
    assert(result.error.code == 'bounded_no_route' and result.metrics.expansions == baseline.metrics.expansions)
    assert(planner.set_edges(edges))
end)
print('ok - '..count..' planner search tests')
