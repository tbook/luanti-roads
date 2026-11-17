local surface=dofile('src/surface.lua')
local connectors=dofile('src/connectors.lua')
local edges=dofile('src/edges.lua')
assert(edges.set_raster(dofile('src/raster.lua')))
local fixture=dofile('tests/connector_fixture.lua')
local count=0
local function test(name,fn)
    local ok,err=pcall(fn); if not ok then error(name..': '..tostring(err)) end
    count=count+1
end
local bounds={min_x=-32,max_x=47,min_y=-32,max_y=31,min_z=-32,max_z=47}
local function resolve(d,descending,width,mutate,after,lane)
    local access,overrides,feet=fixture.new(d,descending,width)
    if lane then feet.x=feet.x-lane*d.z; feet.z=feet.z+lane*d.x end
    if mutate then mutate(access,overrides) end
    local terrain=assert(surface.inspect(bounds,'alice',access))
    if after then after(access,overrides) end
    local goal={x=feet.x+d.x*20,y=descending and 1.5 or 2.5,z=feet.z+d.z*20}
    local loads=0
    local result,err=connectors.endpoints(terrain,feet,goal,access,function() loads=loads+1 end,surface,edges)
    return result,err,loads
end
test('realistic ascent and descent in cardinal directions and both widths',function()
    for _,d in ipairs({{x=1,z=0,p2=1},{x=-1,z=0,p2=3},{x=0,z=1,p2=0},{x=0,z=-1,p2=2}}) do
        for _,descending in ipairs({false,true}) do
            for _,width in ipairs({2,4}) do
                local p,err,loads=resolve(d,descending,width)
                assert(p,('%d,%d descending=%s width=%d: %s'):format(d.x,d.z,tostring(descending),width,err and err.reason or '?')); assert(loads>0)
                assert(p.start.connector.width==width and #p.start.connector.path==6)
                assert(p.start.resolved.x==p.start.connector.landing.x)
            end
        end
    end
end)
test('both middle lanes identify one maximal four-wide strip',function()
    for _,lane in ipairs({1,2}) do
        local p,err=resolve({x=1,z=0,p2=1},false,4,nil,nil,lane)
        assert(p,err and err.reason); assert(p.start.connector.width==4)
    end
end)
test('rejects altered, protected, metadata-bearing and obstructed ramp nodes',function()
    local d={x=1,z=0,p2=1}
    local cases={
        function(a,o) o['1:1:0']={name='mcl_stairs:stair_cobble',param2=20} end,
        function(a,o) o['1:1:0']={name='mcl_stairs:stair_cobble_inner',param2=1} end,
        function(a,o) o['2:2:1']={name='air',param2=0} end,
        function(a,o) o['2:3:0']={name='mcl_core:stone',param2=0} end,
        function(a,o) a.has_metadata=function(p) return p.x==1 and p.y==1 and p.z==0 end end,
        function(a,o) a.is_protected=function(p) return p.x==1 and p.y==0 and p.z==0 end end,
    }
    for _,mutate in ipairs(cases) do
        local p,err=resolve(d,false,2,mutate)
        assert(not p and err.code=='invalid_endpoint')
    end
end)
test('evicted data is loaded before raw reads and unknown data fails closed',function()
    local d={x=1,z=0,p2=1}
    local access,_,feet=fixture.new(d,false,2)
    local terrain=assert(surface.inspect(bounds,'alice',access))
    local original=access.get_node; local loaded={}; local calls=0
    access.get_node=function(p)
        local k=math.floor(p.x/16)..':'..math.floor(p.y/16)..':'..math.floor(p.z/16)
        if not loaded[k] then return nil end
        return original(p)
    end
    local function load(p)
        calls=calls+1; loaded[math.floor(p.x/16)..':'..math.floor(p.y/16)..':'..math.floor(p.z/16)]=true
    end
    local goal={x=20.75,y=2.5,z=0}
    local result=assert(connectors.endpoints(terrain,feet,goal,access,load,surface,edges))
    assert(result.start.connector and calls>0 and calls*4096<=2000000)
    loaded={}; access.get_node=function() return {name='ignore',param2=0} end
    local p,err=connectors.endpoints(terrain,feet,goal,access,load,surface,edges)
    assert(not p and err.code=='invalid_endpoint')
end)
test('tries a later landing when all headings at the first are blocked',function()
    local access,_,feet=fixture.new({x=1,z=0,p2=1},false,2)
    local terrain=assert(surface.inspect(bounds,'alice',access))
    local natural={x=20.75,y=2.5,z=0}
    for _,goal_connector in ipairs({false,true}) do
        local first_anchor
        local proxy={connector_constraints=edges.connector_constraints,evaluate=function(t,anchor,state,heading,config)
            if not first_anchor then first_anchor={x=anchor.x,z=anchor.z} end
            if anchor.x==first_anchor.x and anchor.z==first_anchor.z then
                return {ok=false,code='connector',reason='fixture blocks every heading'}
            end
            return edges.evaluate(t,anchor,state,heading,config)
        end}
        local a,b=goal_connector and natural or feet,goal_connector and feet or natural
        local p,err=connectors.endpoints(terrain,a,b,access,function() end,surface,proxy)
        assert(p,err and err.reason)
        local landing=goal_connector and p.goal.resolved or p.start.resolved
        assert(landing.x~=first_anchor.x or landing.z~=first_anchor.z)
    end
end)
test('support depth and ramp length are bounded',function()
    local d={x=1,z=0,p2=1}
    local p,err=resolve(d,false,2,function(_,o)
        for y=-31,0 do o['1:'..y..':0']={name='mcl_core:cobble',param2=0} end
    end)
    assert(not p and err.code=='invalid_endpoint')
    p,err=resolve(d,false,2,function(_,o)
        for x=4,20 do for z=0,1 do o[x..':2:'..z]={name='mcl_core:cobble',param2=0} end end
    end)
    assert(not p and err.code=='invalid_endpoint')
end)
test('connectors at both ends align a transverse lattice offset',function()
    local d={x=1,z=0,p2=1}; local rev={x=-1,z=0,p2=3}
    local _,first,a=fixture.new(d,false,2)
    local _,last,b=fixture.new(rev,false,2)
    local nodes={}
    for k,v in pairs(first) do nodes[k]=v end
    for k,v in pairs(last) do
        local x,y,z=k:match('^(-?%d+):(-?%d+):(-?%d+)$')
        nodes[(tonumber(x)+30)..':'..y..':'..(tonumber(z)+1)]=v
    end
    b.x,b.z=b.x+30,b.z+1
    local access={get_node=function(p)
        local node=nodes[p.x..':'..p.y..':'..p.z]
        local ground=(p.x<4 or p.x>26) and 0 or 2
        return node or {name=p.y<=ground and 'mcl_core:stone' or 'air',param2=0}
    end,has_metadata=function() return false end,is_protected=function() return false end,
        get_natural_light=function() return 15 end}
    local terrain=assert(surface.inspect(bounds,'alice',access))
    local p,err=connectors.endpoints(terrain,a,b,access,function() end,surface,edges)
    assert(p,err and err.reason)
    assert(p.start.connector and p.goal.connector)
    assert((p.start.resolved.x-p.goal.resolved.x)%4==0)
    assert((p.start.resolved.z-p.goal.resolved.z)%4==0)
    local planner=dofile('src/planner.lua'); assert(planner.set_edges(edges))
    local search=assert(planner.new(terrain,{start=p.start.resolved,goal=p.goal.resolved,provenance=p},
        {road_material='mcl_core:cobble'}))
    local result=search:step({max_expansions=1000})
    while result.status=='running' do result=search:step({max_expansions=1000}) end
    assert(result.status=='succeeded',result.error and result.error.reason)
    local plans=dofile('src/plans.lua'); assert(plans.set_dependencies(dofile('src/raster.lua'),edges))
    local plan,why=plans.compose(terrain,result.route,{road_material='mcl_core:cobble'})
    assert(plan,why and why.reason); assert(plan.version==2)
end)

local planner=dofile('src/planner.lua'); assert(planner.set_edges(edges))
local plans=dofile('src/plans.lua'); assert(plans.set_dependencies(dofile('src/raster.lua'),edges))
local function exit_resolve(d,kind,width,mutate,desc_mutate,target_mutate)
    local access,overrides,desc,target=fixture.exit(d,kind,width)
    if mutate then mutate(access,overrides,desc) end
    local terrain=assert(surface.inspect(bounds,'roads:outward',access))
    if desc_mutate then desc_mutate(desc) end
    if target_mutate then target_mutate(target) end
    local result,err=connectors.exit_endpoints(terrain,desc,target,access,function() end,surface,edges)
    return result,err,terrain,desc,target
end
test('published flat and graded exits resolve in every direction and width',function()
    for _,d in ipairs({{x=1,z=0,p2=1},{x=-1,z=0,p2=3},{x=0,z=1,p2=0},{x=0,z=-1,p2=2}}) do
        for _,kind in ipairs({'flat','down','up'}) do
            for _,width in ipairs({2,4}) do
                local p,err,_,desc=exit_resolve(d,kind,width)
                assert(p,('%d,%d %s w%d: %s'):format(d.x,d.z,kind,width,err and err.reason or '?'))
                local c=p.start.connector
                assert(c.origin=='published_exit' and c.width==width and #c.path==2*desc.length)
                assert(c.exit.exit_id=='fixture' and c.exit.api_version==1)
                assert(p.start.ground.x==0 and p.start.ground.z==0 and p.start.ground.y==desc.profile[1].y)
                assert(p.start.resolved.x==c.landing.x and p.start.requested.y==c.path[2].y)
                assert(p.goal.connector==nil and p.goal.requested.y==p.goal.ground.y+0.5)
                local along=(p.start.resolved.x*d.x+p.start.resolved.z*d.z)
                assert(along>desc.length)
            end
        end
    end
end)
test('published exit plans, composes and preserves approach nodes',function()
    local build=dofile('src/build.lua')
    for _,kind in ipairs({'flat','down','up'}) do
        local d={x=0,z=-1,p2=2}
        local p,err,terrain,desc,target=exit_resolve(d,kind,2)
        assert(p,err and err.reason)
        local search=assert(planner.new(terrain,{start=p.start.resolved,goal=p.goal.resolved,provenance=p},
            {road_material='mcl_core:cobble'}))
        local result=search:step({max_expansions=1000})
        while result.status=='running' do result=search:step({max_expansions=1000}) end
        assert(result.status=='succeeded',result.error and result.error.reason)
        local plan,why=plans.compose(terrain,result.route,{road_material='mcl_core:cobble'})
        assert(plan,why and why.reason); assert(plan.version==2 and plan.connector_version==1)
        local preserved={}
        for _,n in ipairs(plan.endpoints.start.connector.preserved) do preserved[n.x..':'..n.y..':'..n.z]=n end
        local exact=0
        for _,w in ipairs(plan.writes) do assert(not preserved[w.x..':'..w.y..':'..w.z]) end
        for _,n in pairs(preserved) do
            if n.name==desc.profile[1].name or n.name=='mcl_stairs:slab_cobble' then exact=exact+1 end
        end
        assert(exact>0)
        -- The builder accepts the current world and refuses a changed exit with zero writes.
        local function run(changed)
            local writes,queue={},{}
            local access=select(1,fixture.exit(d,kind,2))
            local ops={now=function() return 0 end,after=function(_,fn) queue[#queue+1]=fn end,
                load=function() end,classify=surface.classify,has_timer=function() return false end,
                access={get_node=function(q)
                    if changed and q.x==0 and q.z==-1 then return {name='mcl_core:stone',param2=0} end
                    return access.get_node(q)
                end,has_metadata=function() return false end,is_protected=function() return false end},
                write=function(q,node) writes[#writes+1]=q end}
            local outcome
            assert(build.new(plan,ops,function(e) outcome=e or 'ok' end))
            while #queue>0 do table.remove(queue,1)() end
            return outcome,writes
        end
        local ok_outcome,w=run(false); assert(ok_outcome=='ok' and #w>0,type(ok_outcome)=='table' and ok_outcome.reason or '')
        local stale,none=run(true); assert(type(stale)=='table' and stale.code=='stale_plan' and #none==0)
    end
end)
test('published exit rejects changed, unsupported, blocked and exposed nodes',function()
    local d={x=1,z=0,p2=1}
    local cases={
        function(a,o) o['2:1:0']={name='mcl_core:cobble',param2=3} end,
        function(a,o) o['1:1:1']={name='mcl_core:stone',param2=0} end,
        function(a,o) o['3:3:1']={name='mcl_core:stone',param2=0} end,
        function(a,o) a.has_metadata=function(p) return p.x==2 and p.y==1 and p.z==0 end end,
        function(a,o) a.is_protected=function(p) return p.x==2 and p.y==0 and p.z==1 end end,
        function(a,o) a.get_natural_light=function(p) return p.x==4 and 0 or 15 end end,
        function(a,o) for y=-31,0 do o['3:'..y..':0']={name='mcl_core:cobble',param2=0} end end,
    }
    for i,mutate in ipairs(cases) do
        local p,err=exit_resolve(d,'flat',2,mutate)
        assert(not p and err.code=='invalid_endpoint',i)
    end
    -- profile vocabulary and shape violations
    local p,err=exit_resolve(d,'flat',2,nil,function(desc) desc.profile[2].y=3 end)
    assert(not p and err.code=='invalid_endpoint')
    p,err=exit_resolve(d,'flat',2,nil,function(desc) desc.offsets.max=2 end)
    assert(not p and err.code=='invalid_endpoint')
    p,err=exit_resolve(d,'flat',2,nil,function(desc) desc.direction={x=1,z=1} end)
    assert(not p and err.code=='invalid_endpoint')
end)
test('published exit accepts lateral neighbour cobble that a player selection rejects',function()
    local function neighbour(a,o) for n=0,5 do o[n..':1:2']={name='mcl_core:cobble',param2=0} end end
    local p,err=exit_resolve({x=1,z=0,p2=1},'flat',2,neighbour)
    assert(p,err and err.reason)
    local access,overrides,feet=fixture.new({x=1,z=0,p2=1},false,2)
    for n=-16,6 do overrides[n..':1:2']={name='mcl_stairs:stair_cobble',param2=1} end
    overrides['1:1:2']={name='mcl_stairs:stair_cobble',param2=1}
    local terrain=assert(surface.inspect(bounds,'alice',access))
    local r,e=connectors.endpoints(terrain,feet,{x=20.75,y=2.5,z=0},access,function() end,surface,edges)
    assert(not r and e.code=='invalid_endpoint')
end)
test('published exit targets are bounded and kept outside the source reservation',function()
    local p,err=exit_resolve({x=1,z=0,p2=1},'flat',2,nil,nil,function(t) t.x=300 end)
    assert(not p and err.code=='invalid_endpoint')
    p,err=exit_resolve({x=1,z=0,p2=1},'flat',2,nil,function(desc) desc.reservation={x1=10,z1=-10,x2=40,z2=10} end)
    assert(not p and err.reason:find('inside source settlement'))
    p,err=exit_resolve({x=1,z=0,p2=1},'flat',2,nil,nil,function(t) t.x=1.5 end)
    assert(not p and err.code=='invalid_endpoint')
    -- A water target cannot be a goal.
    p,err=exit_resolve({x=1,z=0,p2=1},'flat',2,function(a)
        local g=a.get_node
        a.get_node=function(q) if q.x>=24 and q.y>=1 and q.y<=1 then return {name='mcl_core:water_source',param2=0} end return g(q) end
    end)
    assert(not p and err.code=='invalid_endpoint')
end)
print('ok - '..count..' connector inspection tests')
