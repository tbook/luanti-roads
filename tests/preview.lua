-- SPDX-License-Identifier: GPL-3.0-or-later
local preview=dofile("src/preview.lua")
local raster=dofile("src/raster.lua")
local edges=dofile("src/edges.lua")
local planner=dofile("src/planner.lua")
local plans=dofile("src/plans.lua")
local terrain_fixture=dofile("tests/terrain.lua")
assert(edges.set_raster(raster)); assert(planner.set_edges(edges)); assert(plans.set_dependencies(raster,edges))
local count=0
local function test(name,fn)
    local ok,err=pcall(fn)
    if not ok then error("preview "..name..": "..tostring(err)) end
    count=count+1
end

test("samples centerline in world coordinates including elevation",function()
    local line={{x=0,y=10,z=0},{x=1,y=10,z=0},{x=2,y=11,z=0},{x=3,y=11,z=0}}
    local points=assert(preview.sample(line))
    assert(#points>=2 and #points<=preview.MAX_PARTICLES)
    assert(points[1].x==0 and points[1].y==13.5 and points[1].z==0)
    assert(points[#points].x==3 and points[#points].y==14.5 and points[#points].z==0)
    for _,p in ipairs(points) do assert(p.y>=13.5 and p.y<=14.5) end
    assert(points[1].y>12+1,"marker should clear the maximum accepted two-node cut")
end)

test("caps marker count for long routes and rejects malformed geometry",function()
    local line={}
    for x=0,500 do line[#line+1]={x=x,y=0,z=0} end
    local points=assert(preview.sample(line))
    assert(#points==preview.MAX_PARTICLES and points[1].x==0 and points[#points].x==500)
    local bad,err=preview.sample({{x=0,y=0,z=0},{x=5,y=0,z=0}})
    assert(not bad and err.code=="invalid_route")
    bad,err=preview.sample({{x=0,y=0,z=0},{x=0/0,y=0,z=0}})
    assert(not bad and err.code=="invalid_route")
end)

test("samples actual example planner route including diagonal and grade segments",function()
    local terrain=terrain_fixture.rectangle(-8,24,-12,12,0)
    terrain.owner="preview-example"
    for x=8,12 do for z=-3,3 do terrain:set_column(x,z,2) end end
    local a,b={x=0,y=0,z=0},{x=20,y=0,z=0}
    local function endpoint(p) return {requested={x=p.x,y=p.y+0.5,z=p.z},ground=p,resolved=p} end
    local search=assert(planner.new(terrain,{start=a,goal=b,
        provenance={start=endpoint(a),goal=endpoint(b)}}))
    local result=search:step({max_expansions=1000})
    while result.status=="running" do result=search:step({max_expansions=1000}) end
    assert(result.status=="succeeded")
    local plan=assert(plans.compose(terrain,result.route,{road_material="cobble"}))
    local diagonal=false
    for i=2,#plan.centerline do
        local p,q=plan.centerline[i-1],plan.centerline[i]
        if p.x~=q.x and p.z~=q.z then diagonal=true end
    end
    assert(diagonal,"example fixture should exercise diagonal lattice segments")
    local points=assert(preview.sample(plan.centerline))
    assert(#points<=preview.MAX_PARTICLES)
    assert(math.abs(points[1].x-plan.centerline[1].x)<0.000001
        and math.abs(points[1].z-plan.centerline[1].z)<0.000001
        and math.abs(points[#points].x-plan.centerline[#plan.centerline].x)<0.000001
        and math.abs(points[#points].z-plan.centerline[#plan.centerline].z)<0.000001)
    local min_y,max_y=math.huge,-math.huge
    for _,p in ipairs(points) do min_y=math.min(min_y,p.y); max_y=math.max(max_y,p.y) end
    assert(max_y==min_y,"flat example should remain level")
    local grade_points=assert(preview.sample({{x=0,y=0,z=0},{x=4,y=1,z=4},{x=8,y=2,z=4}}))
    local low,high=math.huge,-math.huge
    for _,p in ipairs(grade_points) do low=math.min(low,p.y); high=math.max(high,p.y) end
    assert(high>low and math.abs(grade_points[#grade_points].y-5.5)<0.000001,
        "preview samples linearly interpolate graded diagonal segments")
    local rounded=assert(preview.sample({{x=0,y=10,z=0},{x=4,y=11,z=0}}))
    local middle=rounded[2]
    local rounded_ground=math.floor((10.5)+0.5)+2
    assert(math.abs(middle.y-14.0)<0.000001 and middle.y>rounded_ground+0.5,
        "vertical margin should clear rounded terrain at half-node profile interpolation")
end)

test("renderer targets owner, expires particles, and enforces per-player rate cap",function()
    local now=0; local emitted={}
    local engine={add_particle=function(def) emitted[#emitted+1]=def end}
    local renderer=assert(preview.new(engine,function() return now end))
    local line={}; for x=0,20 do line[#line+1]={x=x,y=3,z=4} end
    local n=assert(renderer:show("alice",line))
    assert(n==#emitted and n<=preview.MAX_PARTICLES)
    for _,p in ipairs(emitted) do
        assert(p.playername=="alice" and p.expirationtime==preview.EXPIRY)
        assert(p.texture=="default_cobble.png^[opacity:200" and p.collisiondetection==false)
    end
    local again,err=renderer:show("alice",line)
    assert(not again and err.code=="rate_limited" and #emitted==n)
    assert(renderer:show("bob",line))
    renderer:forget("alice")
    assert(renderer:show("alice",line))
    now=preview.RATE_LIMIT
    assert(renderer:show("alice",line))
end)

print("ok - "..count.." route preview tests")
