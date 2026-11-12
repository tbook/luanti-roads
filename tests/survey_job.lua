local service=dofile("src/survey_job.lua")
local count=0
local function test(name,fn) local ok,e=pcall(fn); if not ok then error(name..": "..tostring(e)) end; count=count+1 end
local function fixture()
    local time, queue, requests=0,{},{}
    local actions={cancelled=0,errored=1,memory=2,disk=3,generated=4}
    local patch={request_bounds={min_x=-32,max_x=47,min_y=-32,max_y=47,min_z=-32,max_z=47},voxel_count=512000}
    local plan={chunk_count=2,patches={patch,patch},requested_bounds={min_x=0,max_x=8,min_z=0,max_z=8,min_y=-6,max_y=8}}
    local pre={plan=function() return plan end}
    local inspector={inspect=function(b,owner)
        assert(owner=="alice" and b.min_y==-6 and b.max_y==8)
        return {get_column=function(x,z) return {status="ok",ground_y=0,material="stone",band={[0]={kind="natural",protected=false}}} end}
    end}
    local ops={actions=actions,access={},now=function() return time end,
        after=function(delay,fn) queue[#queue+1]={at=time+delay,fn=fn} end,
        emerge=function(a,b,cb) requests[#requests+1]=cb end}
    local function run()
        table.sort(queue,function(a,b) return a.at<b.at end)
        local task=table.remove(queue,1); if task then time=task.at; task.fn() end
    end
    local function callbacks(cb,action,skip)
        for i=0,124 do if i~=skip then cb({x=i%5-2,y=math.floor(i/5)%5-2,z=math.floor(i/25)-2},action or actions.memory,124-i) end end
    end
    local job=assert(service.new(pre,inspector,ops,{},{},"alice",{}))
    return {job=job,run=run,requests=requests,callbacks=callbacks,actions=actions,
        advance=function(n) time=time+n end,plan=plan,pre=pre,inspector=inspector,ops=ops}
end
local function complete(f)
    f.run(); assert(#f.requests==1); f.callbacks(f.requests[1]); f.run()
    assert(#f.requests==2); f.callbacks(f.requests[2]); f.run()
    for _=1,20 do if f.job:status().status~="running" then break end; f.run() end
end
test("sequential requests, yielded tiles, full vertical window, detached summary",function()
    local f=fixture(); complete(f); local s=f.job:status()
    assert(s.status=="succeeded" and s.metrics.chunks_completed==2 and s.metrics.tiles_completed==9)
    assert(s.metrics.columns_completed==81 and s.metrics.callbacks==250 and s.metrics.max_patch_voxels==240)
    local c=s.terrain.get_column(0,0); c.band[0].kind="water"
    assert(s.terrain.get_column(0,0).band[0].kind=="natural" and s.terrain.get_column(-1,0).status=="outside")
end)
test("all failed actions and unknown action fail",function()
    for _,v in ipairs({0,1,99}) do local f=fixture(); f.run(); f.requests[1]({x=0,y=0,z=0},v,124); assert(f.job:status().status=="failed"); f.run(); assert(#f.requests==1) end
end)
test("incomplete, duplicate and out of order callbacks fail",function()
    local f=fixture(); f.run(); f.callbacks(f.requests[1],nil,17); assert(f.job:status().status=="failed")
    f=fixture(); f.run(); local cb=f.requests[1]; cb({x=0,y=0,z=0},2,124); cb({x=0,y=0,z=0},2,123); assert(f.job:status().status=="failed")
    f=fixture(); f.run(); cb=f.requests[1]; cb({x=0,y=0,z=0},2,124); cb({x=1,y=0,z=0},2,122); assert(f.job:status().status=="failed")
end)
test("timeout and cancellation invalidate late callbacks",function()
    local f=fixture(); f.run(); f.advance(60); f.requests[1]({x=0,y=0,z=0},2,124); assert(f.job:status().error.code=="survey_timeout")
    f=fixture(); f.run(); f.job:cancel(); f.callbacks(f.requests[1]); for i=1,3 do f.run() end
    assert(f.job:status().status=="cancelled" and #f.requests==1)
    local nextjob=fixture(); complete(nextjob); assert(nextjob.job:status().status=="succeeded")
end)
test("caps and inspection failure",function()
    local f=fixture(); f.plan.patches[1].voxel_count=2000001
    local j,e=service.new(f.pre,f.inspector,f.ops,{},{},"alice",{}); assert(not j and e.code=="survey_budget")
    f=fixture(); f.inspector.inspect=function() error("broken") end
    f.run(); f.callbacks(f.requests[1]); f.run(); f.callbacks(f.requests[2]); f.run(); f.run()
    assert(f.job:status().error.code=="survey_failed")
end)
print("ok - "..count.." asynchronous survey tests")
