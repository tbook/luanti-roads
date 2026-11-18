-- SPDX-License-Identifier: GPL-3.0-or-later
local raster=dofile('src/raster.lua')
local seam=dofile('src/seam.lua')
local source_classify=dofile('src/surface.lua').classify
local edges=dofile('src/edges.lua')
local planner=dofile('src/planner.lua')
local plans=dofile('src/plans.lua')
local build=dofile('src/build.lua')
local classify=dofile('src/surface.lua').classify
local fixture=dofile('tests/terrain.lua')
assert(edges.set_raster(raster)); assert(planner.set_edges(edges)); assert(plans.set_dependencies(raster,edges))
planner.set_seam_dependencies(seam,raster); plans.set_seam_dependency(seam); build.set_seam_dependencies(seam,raster)
local a,b,c={x=0,y=0,z=0},{x=4,y=0,z=0},{x=8,y=0,z=0}
local surfaces=assert(raster.join(assert(raster.segment(a,b)),assert(raster.segment(b,c)))).columns
local source={centerline={a,b,c},headings={0,0},expectations={},writes={}}
local snapshot={}
for _,p in ipairs(surfaces) do
    for y=-1,3 do
        source.expectations[#source.expectations+1]={x=p.x,y=y,z=p.z,kind=y<=0 and 'natural' or 'air',material=y<=0 and 'mcl_core:stone' or nil,protected=false}
        snapshot[#snapshot+1]={x=p.x,y=y,z=p.z,name=y<=0 and 'mcl_core:stone' or 'air',
            param2=0,has_metadata=false,protected=false,has_timer=false}
        if y==0 then source.writes[#source.writes+1]={x=p.x,y=y,z=p.z,kind='road'} end
    end
end
local patch=assert(seam.derive(raster,source,surfaces,snapshot,source_classify))
local terrain=fixture.rectangle(-4,20,-5,8,0); terrain.owner='alice'
for _,col in pairs(terrain.columns) do
    col.material='mcl_core:stone'
    for _,entry in pairs(col.band) do if entry.kind=='natural' then entry.material='mcl_core:stone' end end
end
local raw={}
local function key(p) return p.x..':'..p.y..':'..p.z end
for _,p in ipairs(patch.preserved) do raw[key(p)]={name=p.name,param2=p.param2} end
for _,p in ipairs(patch.surfaces) do terrain:set_node(p.x,p.z,p.y,{kind='natural',material='mcl_core:cobble',protected=false}) end
local access={get_node=function(p) return raw[key(p)] or {name=p.y<=0 and 'mcl_core:stone' or 'air',param2=0} end,
    has_metadata=function() return false end,is_protected=function() return false end}
local function timer() return false end
local function request(old_ground)
    local goal={x=16,y=0,z=0}
    return {start=c,goal=goal,start_heading=0,start_seam=patch,provenance={
        start={origin='growth_seam',requested={x=8,y=old_ground+0.5,z=0},ground={x=8,y=old_ground,z=0},resolved=c},
        goal={requested={x=16,y=0.5,z=0},ground=goal,resolved=goal}}}
end
local config={road_material='mcl_core:cobble',seam_access=access,seam_has_timer=timer}
local lastplan
for _,old_y in ipairs({-2,2}) do
    local search=assert(planner.new(terrain,request(old_y),config))
    local result=search:step({max_expansions=1000})
    while result.status=='running' do result=search:step({max_expansions=1000}) end
    assert(result.status=='succeeded',result.error and result.error.reason)
    assert(result.route.centerline[1].y==0 and result.route.headings[1]==0)
    local plan,why=plans.compose(terrain,result.route,config)
    assert(plan,why and why.reason)
    lastplan=plan
    assert(plan.version==3 and plan.seam_version==1)
    local queue,writes={},0
    local ops={after=function(_,f) queue[#queue+1]=f end,load=function() end,now=function() return 0 end,
        access=access,has_timer=timer,classify=classify,write=function() writes=writes+1 end}
    local outcome
    assert(build.new(plan,ops,function(err) outcome=err or 'ok' end))
    while #queue>0 do table.remove(queue,1)() end
    assert(outcome=='ok' and writes>0)
    local p=patch.preserved[1]
    plan.writes[#plan.writes+1]={x=p.x,y=p.y,z=p.z,kind='air'}
    local job,err=build.new(plan,ops,function() end)
    assert(not job and err.code=='build_failed')
    table.remove(plan.writes)
end
local original=access.has_metadata
access.has_metadata=function() return true end
local bad,err=planner.new(terrain,request(0),config)
assert(not bad and err.code=='seam_changed')
access.has_metadata=original
local function attempt(change)
    local queue,writes,outcome={},0
    local ops={after=function(_,f) queue[#queue+1]=f end,load=function() end,now=function() return 0 end,
        access={get_node=access.get_node,has_metadata=access.has_metadata,is_protected=access.is_protected},
        has_timer=timer,classify=classify,write=function() writes=writes+1 end}
    change(ops)
    local job,err=build.new(lastplan,ops,function(e) outcome=e or 'ok' end)
    if not job then return err,writes end
    while #queue>0 do table.remove(queue,1)() end
    return outcome,writes
end
for _,change in ipairs({
    function(o) o.access.has_metadata=function() return true end end,
    function(o) o.access.is_protected=function() return true end end,
    function(o) o.has_timer=function() return nil end end,
    function(o) local get=o.access.get_node; o.access.get_node=function(p)
        if p.x==8 and p.y==-1 and p.z==0 then return nil end
        return get(p)
    end end,
    function(o) local get=o.access.get_node; o.access.get_node=function(p)
        if p.x==8 and p.y==1 and p.z==0 then return {name='mcl_core:stone',param2=0} end
        return get(p)
    end end,
}) do
    local e,writes=attempt(change)
    assert(e.code=='seam_changed' and writes==0)
end
local removed=table.remove(lastplan.expectations,1)
local job,e=build.new(lastplan,{classify=classify},function() end)
assert(not job and e.code=='build_failed')
lastplan.expectations[#lastplan.expectations+1]=removed
local missing_write=table.remove(lastplan.writes,1)
job,e=build.new(lastplan,{classify=classify},function() end)
assert(not job and e.code=='build_failed')
lastplan.writes[#lastplan.writes+1]=missing_write
print('ok - growth seam planner, composition, and builder')
