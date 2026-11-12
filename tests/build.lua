-- SPDX-License-Identifier: GPL-3.0-or-later
local build=dofile('src/build.lua')
local surface=dofile('src/surface.lua')
local function scenario(change)
    local queue,writes={},{}
    local plan={version=1,owner='alice',expectations={
        {x=0,y=-1,z=0,kind='natural',material='mcl_core:stone',protected=true},
        {x=0,y=0,z=0,kind='natural',material='mcl_core:dirt',protected=false},
        {x=0,y=1,z=0,kind='air',protected=false}},
        writes={{x=0,y=0,z=0,kind='road'},{x=0,y=1,z=0,kind='air'}}}
    local ops={now=function() return 0 end,after=function(_,fn) queue[#queue+1]=fn end,
        load=function() end,classify=surface.classify,has_timer=function() return false end,
        access={get_node=function(p) return {name=p.y==-1 and 'mcl_core:stone' or p.y==0 and 'mcl_core:dirt' or 'air'} end,
            has_metadata=function() return false end,is_protected=function(p) return p.y==-1 end},
        write=function(p,node) writes[#writes+1]={p=p,node=node} end}
    if change then change(plan,ops,writes) end
    local result,metrics
    local job,err=build.new(plan,ops,function(e,m) result=e or 'success'; metrics=m end)
    while #queue>0 do table.remove(queue,1)() end
    return result,metrics,writes,job,err
end
local result,metrics,writes=scenario()
assert(result=='success' and metrics.writes==2 and writes[1].node.name=='mcl_core:cobble')
for _,change in ipairs({
    function(_,ops) ops.access.get_node=function() return nil end end,
    function(_,ops) ops.access.has_metadata=function() return true end end,
    function(_,ops) ops.access.is_protected=function() return true end end,
    function(_,ops) ops.access.get_node=function() return {name='mcl_core:stone'} end end,
    function(_,ops) ops.has_timer=function() return true end end,
}) do
    local e,_,w=scenario(change); assert(e.code=='stale_plan' and #w==0)
end
local e,_,w=scenario(function(_,ops) ops.load=function() error('load error') end end)
assert(e.code=='build_failed' and #w==0)
e,metrics,w=scenario(function(_,ops,writes)
    ops.write=function(p,node) if #writes==1 then error('write error') end; writes[#writes+1]={p=p,node=node} end
end)
assert(e.code=='partial_build' and #w==1 and metrics.writes==1)
local _,_,_,job,err=scenario(function(plan) for i=1,10001 do plan.writes[i]={} end end)
assert(not job and err.code=='write_budget')
local _,_,_,limited,limit_error=scenario(function(plan) for i=1,50001 do plan.expectations[i]={} end end)
assert(not limited and limit_error.code=='write_budget')
local _,_,_,boundary,boundary_error=scenario(function(plan,ops)
    local expectation=plan.expectations[1]
    local write=plan.writes[1]
    for i=1,50000 do plan.expectations[i]=expectation end
    for i=1,10000 do plan.writes[i]=write end
    -- Verify acceptance without executing 10,000 duplicate fixture writes.
    ops.after=function() end
end)
assert(boundary and not boundary_error)
for _,change in ipairs({
    function(plan) plan.version=2 end,
    function(plan) plan.endpoints={start={connector={}}} end,
    function(plan) plan.request={provenance={goal={connector={}}}} end,
}) do
    local _,_,w,job,e=scenario(change)
    assert(not job and e.code=='build_failed' and #w==0)
end
print('ok - 10 construction test scenarios')
