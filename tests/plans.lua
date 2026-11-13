-- SPDX-License-Identifier: GPL-3.0-or-later
local raster = dofile('src/raster.lua')
local edges = dofile('src/edges.lua')
local planner = dofile('src/planner.lua')
local plans = dofile('src/plans.lua')
local fixture = dofile('tests/terrain.lua')
assert(edges.set_raster(raster)); assert(planner.set_edges(edges)); assert(plans.set_dependencies(raster,edges))
local count = 0
local function test(name, f)
    local ok, err = pcall(f); if not ok then error(name .. ': ' .. tostring(err)) end
    count = count + 1
end
local function request(a,b)
    local function ep(p) return {requested={x=p.x,y=p.y+0.5,z=p.z},ground=p,resolved=p} end
    return {start=a,goal=b,provenance={start=ep(a),goal=ep(b)}}
end
local function route(t,a,b)
    local s = assert(planner.new(t,request(a,b)))
    local result = s:step({max_expansions=1000})
    while result.status == 'running' do result = s:step({max_expansions=1000}) end
    assert(result.status == 'succeeded', result.error and result.error.reason)
    return result.route
end
local function lookup(list,x,y,z)
    for _,p in ipairs(list) do if p.x==x and p.y==y and p.z==z then return p end end
end
local function ordered(list)
    for i=2,#list do local a,b=list[i-1],list[i]
        assert(a.x<b.x or a.x==b.x and (a.z<b.z or a.z==b.z and a.y<b.y))
    end
end
test('planner integration, overlapping caps and semantic footprint', function()
    local t=fixture.rectangle(-3,12,-3,8,0); t.owner='alice'; t.version=1
    local a,b={x=0,y=0,z=0},{x=8,y=0,z=4}
    local r=route(t,a,b); local p=assert(plans.compose(t,r,{road_material='cobble'}))
    assert(p.owner=='alice' and p.version==1 and p.planner_version==1 and p.raster_version==1)
    assert(p.request.provenance.goal.resolved.x==8 and p.metrics.length>0)
    assert(#p.writes==49 and p.metrics.road_count==49 and p.metrics.write_count==49)
    assert(#p.expectations==49*5 and lookup(p.expectations,0,-1,0).kind=='natural')
    assert(lookup(p.expectations,0,3,0).kind=='air')
    ordered(p.writes); ordered(p.expectations)
    local again=assert(plans.compose(t,r,{road_material='cobble'}))
    for i,v in ipairs(p.writes) do local q=again.writes[i]; assert(v.x==q.x and v.y==q.y and v.z==q.z and v.kind==q.kind) end
    p.request.start.x=99; assert(r.request.start.x==0 and t.get_column(0,0).ground_y==0)
end)
test('fill, excavation, no-op road and protected unchanged clearance', function()
    local t=fixture.rectangle(-2,6,-2,2,0)
    t:set_column(2,1,-2); t:set_column(2,-1,2)
    t:set_node(0,0,0,{kind='natural',material='cobble',protected=false})
    t:set_node(0,0,1,{kind='air',protected=true})
    local r=route(t,{x=0,y=0,z=0},{x=4,y=0,z=0})
    local p=assert(plans.compose(t,r,{road_material='cobble'}))
    assert(not lookup(p.writes,0,0,0) and lookup(p.expectations,0,0,0).material=='cobble')
    assert(lookup(p.expectations,0,1,0).protected and not lookup(p.writes,0,1,0))
    assert(lookup(p.writes,2,-1,1).kind=='fill')
    assert(lookup(p.expectations,2,-2,1).kind=='natural')
    assert(lookup(p.writes,2,1,-1).kind=='air' and lookup(p.writes,2,2,-1).kind=='air')
    assert(p.metrics.fill_count==1 and p.metrics.cut_count==2 and p.metrics.road_count==20)
end)
test('write cap and invalid terrain fail before returning a plan', function()
    local t=fixture.rectangle(-2,6,-2,2,0); local r=route(t,{x=0,y=0,z=0},{x=4,y=0,z=0})
    local p,e=plans.compose(t,r,{road_material='cobble',max_writes=20})
    assert(not p and e.code=='write_budget' and e.observed==21)
    t:set_node(2,0,1,{kind='obstacle',protected=false})
    p,e=plans.compose(t,r,{road_material='cobble'}); assert(not p and e.code=='composition_failed')
end)
test('reject inconsistent centerline and nonconsecutive profile overlaps', function()
    local t=fixture.rectangle(-6,10,-6,10,0)
    local r=route(t,{x=0,y=0,z=0},{x=4,y=0,z=0})
    r.headings[1]=1
    local p,e=plans.compose(t,r,{road_material='cobble'}); assert(not p and e.code=='composition_failed')
    -- A synthetic raster supplies a conflicting distant overlap, independently of joins.
    local calls=0
    local fake={join=raster.join,segment=function(a,b)
        calls=calls+1; local s=assert(raster.segment(a,b))
        if calls==2 then s.columns[#s.columns+1]={x=0,z=0,y=1} end
        return s
    end}
    assert(plans.set_dependencies(fake,edges))
    t=fixture.rectangle(-2,10,-2,2,0); r=route(t,{x=0,y=0,z=0},{x=8,y=0,z=0})
    p,e=plans.compose(t,r,{road_material='cobble'}); assert(not p and e.code=='composition_failed')
    assert(plans.set_dependencies(raster,edges))
end)
test('protected no-op road and differing protected material', function()
    local t=fixture.rectangle(-2,6,-2,2,0)
    local a,b={x=0,y=0,z=0},{x=4,y=0,z=0}
    local r=route(t,a,b)
    t:set_node(2,0,0,{kind='natural',material='cobble',protected=true})
    local p=assert(plans.compose(t,r,{road_material='cobble'}))
    assert(not lookup(p.writes,2,0,0) and lookup(p.expectations,2,0,0).protected)
    local s=assert(planner.new(t,request(a,b),{road_material='cobble'}))
    local report=s:step({max_expansions=1000})
    assert(report.status=='succeeded')
    local _,e=plans.compose(t,r,{road_material='other'})
    assert(e.code=='composition_failed' and e.reason:find('protected'))
end)
test('invalid provenance and false write cap are rejected', function()
    local t=fixture.rectangle(-2,10,-2,2,0)
    local r=route(t,{x=0,y=0,z=0},{x=8,y=0,z=0})
    local _,e=plans.compose(t,r,{road_material='cobble',max_writes=false})
    assert(e.code=='invalid_config')
    r.request.provenance.start.ground.x=99
    _,e=plans.compose(t,r,{road_material='cobble'})
    assert(e.code=='invalid_endpoint')
    r.request.provenance.start.ground.x=0
    r.request.provenance.goal.requested.y=10
    _,e=plans.compose(t,r,{road_material='cobble'})
    assert(e.code=='invalid_endpoint')
end)
test('interned material identity is retained and mismatches fail', function()
    local material,other = {id='cobble'}, {id='cobble'}
    material.self = material -- Interned identifiers are opaque and may be cyclic.
    local t=fixture.rectangle(-2,10,-2,2,0)
    local a,b={x=0,y=0,z=0},{x=8,y=0,z=0}
    t:set_node(6,0,0,{kind='natural',material=material,protected=true})
    local config={road_material=material}
    local search=assert(planner.new(t,request(a,b),config))
    local initial=search:step({max_expansions=1})
    assert(initial.status=='running')
    config.road_material=other
    local result=search:step({max_expansions=1000})
    assert(result.status=='succeeded' and result.route.parameters.road_material==material)
    local plan=assert(plans.compose(t,result.route,{road_material=material}))
    assert(plan.parameters.road_material==material and lookup(plan.expectations,6,0,0).material==material)
    assert(not lookup(plan.writes,6,0,0))
    local _,err=plans.compose(t,result.route,{road_material=other})
    assert(err.code=='invalid_config')
end)
test('connector reserves its approach and composes exact expectations', function()
    local t=fixture.rectangle(-12,24,-12,12,0)
    local a,b={x=0,y=0,z=0},{x=8,y=0,z=0}
    local req=request(a,b)
    local c={version=1,landing={x=0,y=0,z=0},direction={x=1,z=0},width=2,
        path={{x=-4.25,y=0,z=0},{x=-3.75,y=0,z=0}},preserved={},
        transition={surfaces={},writes={},expectations={}}}
    for z=0,1 do for y=-1,3 do
        c.preserved[#c.preserved+1]={x=-4,y=y,z=z,
            name=y==-1 and 'mcl_core:stone' or y==0 and 'mcl_stairs:slab_cobble' or 'air',
            param2=0,has_metadata=false,protected=false}
    end end
    for x=-3,1 do for z=-1,1 do
        local tr=c.transition
        tr.surfaces[#tr.surfaces+1]={x=x,y=0,z=z}
        tr.writes[#tr.writes+1]={x=x,y=0,z=z,kind='road'}
        for y=-1,3 do tr.expectations[#tr.expectations+1]={x=x,y=y,z=z,kind=y<=0 and 'natural' or 'air',material=y<=0 and 'stone' or nil,protected=false} end
    end end
    req.provenance.start.connector=c
    req.provenance.start.ground={x=-4,y=0,z=0}
    req.provenance.start.requested={x=-4.25,y=0,z=0}
    local constraints=assert(edges.connector_constraints(req.provenance))
    assert(not edges.evaluate(t,a,{i=0,j=0},4,{road_material='cobble',constraints=constraints}).ok)
    assert(edges.evaluate(t,a,{i=0,j=0},0,{road_material='cobble',constraints=constraints}).ok)
    -- A later diagonal must account for its full support footprint, even away
    -- from either endpoint and even though the contact is read-only.
    c.preserved[#c.preserved+1]={x=7,y=-1,z=3,name='mcl_core:stone',param2=0,has_metadata=false,protected=false}
    constraints=assert(edges.connector_constraints(req.provenance))
    local diagonal=edges.evaluate(t,a,{i=1,j=0},1,{road_material='cobble',constraints=constraints})
    assert(not diagonal.ok and diagonal.code=='connector')
    local s=assert(planner.new(t,req,{road_material='cobble'}))
    local result=s:step({max_expansions=1000}); assert(result.status=='succeeded')
    local plan=assert(plans.compose(t,result.route,{road_material='cobble'}))
    assert(plan.version==2 and plan.connector_version==1)
    assert(lookup(plan.expectations,-4,0,0).name=='mcl_stairs:slab_cobble')
    assert(not lookup(plan.writes,-4,0,0) and lookup(plan.writes,-3,0,0))
    local detour=request(a,{x=16,y=0,z=0})
    detour.provenance.start=req.provenance.start
    c.preserved[#c.preserved+1]={x=8,y=-1,z=0,name='mcl_core:stone',param2=0,has_metadata=false,protected=false}
    local search=assert(planner.new(t,detour,{road_material='cobble'}))
    local alternative=search:step({max_expansions=1000})
    while alternative.status=='running' do alternative=search:step({max_expansions=1000}) end
    assert(alternative.status=='succeeded',alternative.error and alternative.error.reason)
    local bent=false
    for _,point in ipairs(alternative.route.centerline) do if point.z~=0 then bent=true end end
    assert(bent,'route must detour around preserved support')
    assert(plans.compose(t,alternative.route,{road_material='cobble'}))
    for _,position in ipairs({{-4,0,0},{-4,-1,1},{-4,3,1}}) do
        local p=lookup(c.preserved,position[1],position[2],position[3]); local old=p.x
        p.x=old-6
        local accepted=edges.connector_constraints(req.provenance)
        assert(not accepted, 'missing preserved surface, support or clearance must be rejected')
        p.x=old
    end
    local seam=lookup(c.transition.surfaces,-3,0,1); seam.z=8
    assert(not edges.connector_constraints(req.provenance), 'incomplete width seam must be rejected')
    seam.z=1
    seam.y=1
    assert(not edges.connector_constraints(req.provenance), 'one-node transition step must be rejected')
    seam.y=0
    local cap_write=lookup(c.transition.writes,-1,0,0)
    cap_write.kind='air'
    local broken=assert(edges.connector_constraints(req.provenance))
    assert(not edges.evaluate(t,a,{i=0,j=0},0,{road_material='cobble',constraints=broken}).ok,
        'landing cap operation mismatch must reject the edge')
    cap_write.kind='road'
    c.path[1].x=-8
    result.route.request.provenance.start.connector=c
    local _,seam_error=plans.compose(t,result.route,{road_material='cobble'})
    assert(seam_error and seam_error.code=='invalid_endpoint')
    c.path[1].x=-4.25
    c.transition.writes[1].kind='air'
    result.route.request.provenance.start.connector=c
    local _,err=plans.compose(t,result.route,{road_material='cobble'})
    assert(err and err.code=='composition_failed')
end)
print('ok - '..count..' complete-plan tests')
