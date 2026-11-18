-- SPDX-License-Identifier: GPL-3.0-or-later
local seam=dofile('src/seam.lua')
local source_classify=dofile('src/surface.lua').classify
local p={x=1,y=2,z=3,name='mcl_core:cobble',param2=7,has_metadata=false,protected=false}
local node={name=p.name,param2=p.param2}
local metadata,protection,timer=false,false,false
local access={get_node=function() return node end,has_metadata=function() return metadata end,
    is_protected=function() return protection end}
local function check(patch)
    return seam.check_patch(patch or {p},access,'alice',function() return timer end)
end
assert(check())
for _,v in ipairs({true,'unknown'}) do
    metadata=v; local ok,err=check(); assert(not ok and err.code=='seam_changed'); metadata=false
    protection=v; ok,err=check(); assert(not ok and err.code=='seam_changed'); protection=false
    timer=v; ok,err=check(); assert(not ok and err.code=='seam_changed'); timer=false
end
node={name=p.name,param2=8}; assert(not check())
node={name='ignore',param2=7}; assert(not check())
node=nil; assert(not check())
node={name=p.name,param2=p.param2}
assert(not check({p,p}))
local oversized={}; for i=1,513 do oversized[i]=p end
assert(not check(oversized))
local maximum={}
for i=1,512 do maximum[i]={x=i,y=2,z=3,name=p.name,param2=p.param2,has_metadata=false,protected=false} end
assert(check(maximum))
local holes={[1]=p,[3]=p}; assert(not check(holes))
access.get_node=function() error('unloaded') end
assert(not check())
print('ok - exact seam patch inspection')

local raster=dofile('src/raster.lua')
local a,b,c={x=0,y=0,z=0},{x=4,y=0,z=0},{x=8,y=0,z=0}
local columns=assert(raster.join(assert(raster.segment(a,b)),assert(raster.segment(b,c)))).columns
local plan={centerline={a,b,c},headings={0,0},expectations={},writes={}}
local snapshot={}
for _,column in ipairs(columns) do
    for y=-1,3 do
        local pos={x=column.x,y=y,z=column.z}
        plan.expectations[#plan.expectations+1]={x=pos.x,y=y,z=pos.z,kind=y<=0 and 'natural' or 'air',material=y<=0 and 'mcl_core:stone' or nil,protected=false}
        snapshot[#snapshot+1]={x=pos.x,y=y,z=pos.z,name=y<=0 and 'mcl_core:stone' or 'air',
            param2=7,has_metadata=false,protected=false,has_timer=false}
        if y==0 then plan.writes[#plan.writes+1]={x=pos.x,y=y,z=pos.z,kind='road'} end
    end
end
local derived=assert(seam.derive(raster,plan,columns,snapshot,source_classify))
assert(seam.validate(raster,derived))
assert(#derived.tail==3 and #derived.surfaces==#columns and #derived.preserved==#columns*5)
for _,v in ipairs(derived.preserved) do
    if v.y==0 then assert(v.name=='mcl_core:cobble' and v.param2==0)
    else assert(v.param2==7) end
end
local removed=table.remove(derived.preserved)
assert(not seam.validate(raster,derived))
derived.preserved[#derived.preserved+1]=removed
assert(seam.validate(raster,derived))
local old=snapshot[1].has_timer; snapshot[1].has_timer=true
assert(not seam.derive(raster,plan,columns,snapshot,source_classify)); snapshot[1].has_timer=old
local name=snapshot[1].name; snapshot[1].name='mcl_core:dirt'
assert(not seam.derive(raster,plan,columns,snapshot,source_classify)); snapshot[1].name=name
plan.headings[2]=1; assert(not seam.derive(raster,plan,columns,snapshot,source_classify)); plan.headings[2]=0
local first=columns[1]
for y=-510,-2 do
    plan.expectations[#plan.expectations+1]={x=first.x,y=y,z=first.z,kind='natural',material='mcl_core:stone',protected=false}
    snapshot[#snapshot+1]={x=first.x,y=y,z=first.z,name='mcl_core:stone',param2=0,
        has_metadata=false,protected=false,has_timer=false}
end
local oversized,limit=seam.derive(raster,plan,columns,snapshot,source_classify)
assert(not oversized and limit.limit==512 and limit.observed==513)
for y=-510,-2 do table.remove(plan.expectations); table.remove(snapshot) end
table.remove(snapshot,1); assert(not seam.derive(raster,plan,columns,snapshot,source_classify))
print('ok - derive exact source seam')
