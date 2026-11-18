-- SPDX-License-Identifier: GPL-3.0-or-later
-- Construct a sloped, bending source over cut and fill terrain, then extend it.
local raster=dofile('src/raster.lua')
local seam=dofile('src/seam.lua')
local edges=dofile('src/edges.lua')
local planner=dofile('src/planner.lua')
local plans=dofile('src/plans.lua')
local build=dofile('src/build.lua')
local classify=dofile('src/surface.lua').classify
local fixture=dofile('tests/terrain.lua')
edges.set_raster(raster); planner.set_edges(edges); plans.set_dependencies(raster,edges)
planner.set_seam_dependencies(seam,raster); plans.set_seam_dependency(seam); build.set_seam_dependencies(seam,raster)
local a,b,c={x=0,y=0,z=0},{x=4,y=1,z=0},{x=8,y=1,z=4}
local surfaces=assert(raster.join(assert(raster.segment(a,b)),assert(raster.segment(b,c)))).columns
local function key(p) return p.x..':'..p.y..':'..p.z end
for _,delta in ipairs({-2,1}) do
    local source={centerline={a,b,c},headings={0,1},expectations={},writes={}}
    local snapshot={}
    for _,p in ipairs(surfaces) do
        local g=p.y+delta
        for y=math.min(g,p.y-1),p.y+3 do
            local name=y<=g and 'mcl_core:stone' or 'air'
            source.expectations[#source.expectations+1]={x=p.x,y=y,z=p.z,
                kind=name=='air' and 'air' or 'natural',material=name~='air' and name or nil,protected=false}
            snapshot[#snapshot+1]={x=p.x,y=y,z=p.z,name=name,param2=0,
                has_metadata=false,protected=false,has_timer=false}
            local kind=y==p.y and 'road' or y<p.y and y>g and 'fill'
                or y>p.y and y<=g and 'air' or nil
            if kind then source.writes[#source.writes+1]={x=p.x,y=y,z=p.z,kind=kind,
                material=kind=='fill' and 'mcl_core:stone' or nil} end
        end
    end
    local patch,why=seam.derive(raster,source,surfaces,snapshot,classify)
    assert(patch,why and why.reason)
    local raw={}
    for _,node in ipairs(patch.preserved) do raw[key(node)]={name=node.name,param2=node.param2} end
    local terrain=fixture.rectangle(-5,24,-5,20,1); terrain.owner='alice'
    for _,col in pairs(terrain.columns) do
        col.material='mcl_core:stone'
        for _,entry in pairs(col.band) do if entry.kind=='natural' then entry.material='mcl_core:stone' end end
    end
    for _,p in ipairs(surfaces) do
        local col=terrain:set_column(p.x,p.z,p.y)
        col.material='mcl_core:cobble'
        for _,entry in pairs(col.band) do if entry.kind=='natural' then entry.material='mcl_core:stone' end end
        col.band[0].material='mcl_core:cobble'
    end
    local access={get_node=function(p) return raw[key(p)] or {name=p.y<=1 and 'mcl_core:stone' or 'air',param2=0} end,
        has_metadata=function() return false end,is_protected=function() return false end}
    local timer=function() return false end
    local goal={x=16,y=1,z=12}
    local request={start=c,goal=goal,start_heading=1,start_seam=patch,provenance={
        start={origin='growth_seam',requested={x=c.x,y=c.y+delta+0.5,z=c.z},
            ground={x=c.x,y=c.y+delta,z=c.z},resolved=c},
        goal={requested={x=goal.x,y=goal.y+0.5,z=goal.z},ground=goal,resolved=goal}}}
    local config={road_material='mcl_core:cobble',seam_access=access,seam_has_timer=timer}
    local endcol=terrain.get_column(c.x,c.z)
    local original_ground,original_band=endcol.ground_y,endcol.band
    local shifted={}; for offset=-3,5 do shifted[offset]=original_band[offset+1] end
    endcol.ground_y=endcol.ground_y+1; endcol.band=shifted
    local valid,overlay_error,overlay=seam.check_request(raster,request,terrain,access,timer)
    assert(valid,overlay_error and overlay_error.reason)
    assert(overlay.get_column(c.x,c.z).ground_y==c.y)
    endcol.ground_y,endcol.band=original_ground,original_band
    local original_status=endcol.status; endcol.status='unknown'
    local unknown,unknown_error=planner.new(terrain,request,config)
    assert(not unknown and unknown_error.code=='seam_changed'); endcol.status=original_status
    local search,err=planner.new(terrain,request,config); assert(search,err and err.reason)
    local result=search:step({max_expansions=1000})
    while result.status=='running' do result=search:step({max_expansions=1000}) end
    assert(result.status=='succeeded',result.error and result.error.reason)
    assert(result.route.centerline[1].y==c.y and result.route.headings[1]==1)
    local plan,e=plans.compose(terrain,result.route,config); assert(plan,e and e.reason)
    local road=assert(plan.writes[1])
    assert(road.kind=='road')
    local support
    for _,p in ipairs(plan.expectations) do
        if p.x==road.x and p.y==road.y-1 and p.z==road.z then support=p; break end
    end
    assert(support and support.kind=='natural')
    local saved_kind,saved_material=support.kind,support.material
    support.kind='air'; support.material=nil
    plan.expectations[#plan.expectations+1]={x=road.x,y=road.y-2,z=road.z,
        kind='natural',material='mcl_core:stone',protected=false}
    local fill={x=road.x,y=road.y-1,z=road.z,kind='fill'}
    plan.writes[#plan.writes+1]=fill
    local probe={classify=classify,after=function() error('must not schedule invalid fill') end}
    for _,material in ipairs({'air','mcl_core:dirt'}) do
        fill.material=material
        local rejected,rejection=build.new(plan,probe,function() end)
        assert(not rejected and rejection.code=='build_failed')
    end
    table.remove(plan.writes); table.remove(plan.expectations)
    support.kind,support.material=saved_kind,saved_material
    local queue,outcome={},nil
    local ops={after=function(_,f) queue[#queue+1]=f end,load=function() end,now=function() return 0 end,
        access=access,has_timer=timer,classify=classify,write=function() end}
    local job; job,e=build.new(plan,ops,function(err) outcome=err or 'ok' end); assert(job,e and e.reason)
    while #queue>0 do table.remove(queue,1)() end
    assert(outcome=='ok',type(outcome)=='table' and outcome.reason or tostring(outcome))
end
local conflicting=assert(raster.segment({x=8,y=2,z=4},{x=12,y=2,z=8}))
local joined=raster.join({columns=surfaces},conflicting)
assert(not joined,'overlapping seam heights must agree')
local separated={}
for _,edge in ipairs({assert(raster.segment({x=4,y=0,z=0},{x=8,y=0,z=0})),
    assert(raster.segment({x=4,y=2,z=3},{x=8,y=2,z=3}))}) do
    for _,p in ipairs(edge.columns) do separated[p.x..':'..p.z]=p end
end
assert(not build.validate_surface_steps(separated),'nonconsecutive edges must have safe adjacent steps')
print('ok - growth continuation from cut and fill across sloped diagonal bend')
