-- SPDX-License-Identifier: GPL-3.0-or-later
-- Load existing mapblocks in small batches, then validate and write without yielding.
local build={}
local seam,raster
function build.set_seam_dependencies(s,r) seam,raster=s,r end
local function fail(code,reason) return {code=code,reason=reason} end
local function equal(a,b)
    if type(a)~=type(b) then return false end
    if type(a)~='table' then return a==b end
    for k,v in pairs(a) do if not equal(v,b[k]) then return false end end
    for k in pairs(b) do if a[k]==nil then return false end end
    return true
end
local function valid_position(p)
    if type(p)~='table' then return false end
    for _,axis in ipairs({'x','y','z'}) do
        local n=p[axis]
        if type(n)~='number' or n~=n or math.abs(n)>31000 or n~=math.floor(n) then return false end
    end
    return true
end
local function dense_array(t,limit)
    if type(t)~='table' or #t>limit then return false end
    local count=0
    for k in pairs(t) do
        if type(k)~='number' or k~=math.floor(k) or k<1 or k>#t then return false end
        count=count+1
    end
    return count==#t
end
function build.validate_surface_steps(surfaces)
    for _,p in pairs(surfaces) do
        for _,d in ipairs({{1,0},{0,1}}) do
            local neighbor=surfaces[(p.x+d[1])..':'..(p.z+d[2])]
            if neighbor and math.abs(neighbor.y-p.y)>1 then return false end
        end
    end
    return true
end
function build.new(plan,ops,done)
    if type(plan)~='table' or type(plan.owner)~='string' or type(plan.writes)~='table'
        or type(plan.expectations)~='table' then
        return nil,fail('build_failed','invalid construction plan')
    end
    if #plan.writes>10000 or #plan.expectations>50000 then
        return nil,fail('write_budget','construction exceeds the 10,000-write or 50,000-node inspection limit')
    end
    local e=plan.endpoints or {}
    local provenance=plan.request and plan.request.provenance or {}
    local has_connector=(e.start and e.start.connector) or (e.goal and e.goal.connector)
    if (plan.version~=1 and plan.version~=2 and plan.version~=3)
        or (plan.version==1 and (plan.connector_version~=nil or has_connector))
        or (plan.version==2 and (plan.connector_version~=1 or not has_connector))
        or (plan.version==3 and (plan.seam_version~=1 or (e.start and e.start.connector)
            or plan.connector_version~=((e.goal and e.goal.connector) and 1 or nil)))
        or (plan.version~=3 and plan.seam_version~=nil)
        or plan.connector or plan.connectors or e.connector or e.connectors
        or provenance.connector or provenance.connectors
        or (e.start and e.start.connectors) or (e.goal and e.goal.connectors)
        or (provenance.start and provenance.start.connectors)
        or (provenance.goal and provenance.goal.connectors)
        or (plan.version==1 and ((provenance.start and provenance.start.connector)
            or (provenance.goal and provenance.goal.connector))) then
        return nil,fail('build_failed','unsupported plan version or connector')
    end
    if plan.version==3 then
        local request=plan.request
        local patch=request and request.start_seam
        local ok=seam and raster and seam.validate(raster,patch)
        if not ok or type(ops)~='table' or type(ops.classify)~='function'
            or type(request.provenance)~='table' or type(e.start)~='table'
            or type(e.goal)~='table' or not valid_position(request.start) or not valid_position(request.goal)
            or not equal(e.start.resolved,request.start) or not equal(e.goal.resolved,request.goal)
            or e.start.origin~='growth_seam' or not equal(e,request.provenance)
            or request.start_heading~=patch.heading or not equal(request.start,patch.endpoint)
            or type(plan.parameters)~='table' or plan.parameters.road_material~='mcl_core:cobble'
            or not dense_array(plan.centerline,1024) or #plan.centerline<2
            or not dense_array(plan.headings,1023) or #plan.headings~=#plan.centerline-1
            or not dense_array(plan.expectations,50000) or not dense_array(plan.writes,10000)
            or not equal(plan.centerline[1],request.start) or not equal(plan.centerline[#plan.centerline],request.goal) then
            return nil,fail('build_failed','invalid growth seam provenance or route')
        end
        local exact,written,observed={},{},{}
        local function key(p) return p.x..':'..p.y..':'..p.z end
        for _,p in ipairs(plan.expectations) do
            if not valid_position(p) or observed[key(p)] then return nil,fail('build_failed','invalid growth expectations') end
            observed[key(p)]=p
            if p.name~=nil then exact[key(p)]=p end
        end
        for _,p in ipairs(plan.writes) do
            if not valid_position(p) or written[key(p)] or not observed[key(p)]
                or (p.kind~='road' and p.kind~='air' and p.kind~='fill')
                or (p.kind=='fill' and (type(p.material)~='string' or p.material=='')) then
                return nil,fail('build_failed','invalid or uninspected growth write')
            end
            written[key(p)]=p
        end
        for _,p in ipairs(patch.preserved) do
            local q=exact[key(p)]
            if not q or not equal(p,q) or written[key(p)] then
                return nil,fail('build_failed','incomplete or written seam preservation')
            end
            exact[key(p)]=nil
        end
        -- An optional arrival at a published exit: its exact preserved nodes
        -- must be expected and never written, and the last heading must face in.
        local arrival_ok,_,arrival_headings=seam.check_goal_attachment(request)
        if not arrival_ok then return nil,fail('build_failed','invalid goal attachment') end
        local goal_connector=e.goal.connector
        local transition_surfaces={}
        if goal_connector then
            local c=goal_connector
            if c.version~=1 or c.origin~='published_exit' or not dense_array(c.preserved,50000) or #c.preserved==0
                or type(c.transition)~='table' or not dense_array(c.transition.surfaces,50000)
                or not valid_position(c.landing) or not arrival_headings
                or not arrival_headings[plan.headings[#plan.headings]]
                or not equal(plan.centerline[#plan.centerline],c.landing) then
                return nil,fail('build_failed','invalid arrival connector')
            end
            for _,p in ipairs(c.preserved) do
                local q=exact[key(p)]
                if not valid_position(p) or not q or written[key(p)] or q.name~=p.name or q.param2~=p.param2
                    or q.has_metadata~=false or p.has_metadata~=false or q.protected~=false or p.protected~=false then
                    return nil,fail('build_failed','arrival connector preservation is incomplete')
                end
                exact[key(p)]=nil
            end
            for _,p in ipairs(c.transition.surfaces) do
                if not valid_position(p) or p.y~=c.landing.y then
                    return nil,fail('build_failed','invalid arrival transition surface')
                end
                transition_surfaces[#transition_surfaces+1]=p
            end
        end
        if next(exact) then return nil,fail('build_failed','unattributed exact expectation') end
        local dirs={{1,0},{1,1},{0,1},{-1,1},{-1,0},{-1,-1},{0,-1},{1,-1}}
        local heading=patch.heading
        local route_surfaces={}
        local prior={columns=patch.surfaces}
        for i,h in ipairs(plan.headings) do
            local a,b=plan.centerline[i],plan.centerline[i+1]
            if not valid_position(a) or not valid_position(b) or type(h)~='number' or h~=math.floor(h) or h<0 or h>7
                or b.x-a.x~=4*dirs[h+1][1] or b.z-a.z~=4*dirs[h+1][2]
                or math.min(math.abs(h-heading),8-math.abs(h-heading))>1 then
                return nil,fail('build_failed','invalid growth route heading')
            end
            local edge=raster.segment(a,b)
            if not edge or edge.grade>0.25 or not raster.join(prior,edge)
                or not raster.join({columns=patch.surfaces},edge) then
                return nil,fail('build_failed','invalid growth route geometry')
            end
            for _,p in ipairs(edge.columns) do
                local k=p.x..':'..p.z
                if route_surfaces[k] and route_surfaces[k].y~=p.y then
                    return nil,fail('build_failed','conflicting growth surface heights')
                end
                route_surfaces[k]=p
            end
            prior=edge; heading=h
        end
        for _,p in ipairs(transition_surfaces) do
            local k=p.x..':'..p.z
            if route_surfaces[k] and route_surfaces[k].y~=p.y then
                return nil,fail('build_failed','arrival transition conflicts with the road')
            end
            route_surfaces[k]=route_surfaces[k] or {x=p.x,y=p.y,z=p.z}
        end
        local function state(p,y)
            local id=p.x..':'..y..':'..p.z
            local entry=observed[id]
            if entry and entry.name then
                entry=ops.classify({name=entry.name,param2=entry.param2},entry.has_metadata)
            end
            return entry,written[id]
        end
        if not build.validate_surface_steps(route_surfaces) then
            return nil,fail('build_failed','adjacent growth surfaces exceed one node')
        end
        for _,p in pairs(route_surfaces) do
            local road,write=state(p,p.y)
            if not road or not ((road.kind=='natural' and road.material=='mcl_core:cobble' and not write)
                or (write and write.kind=='road')) then
                return nil,fail('build_failed','missing road expectation or required write')
            end
            for y=p.y+1,p.y+3 do
                local entry,w=state(p,y)
                if not entry or not ((entry.kind=='air' and not w) or (entry.kind~='air' and w and w.kind=='air')) then
                    return nil,fail('build_failed','missing clearance expectation or required write')
                end
            end
            local supported=false
            local fills={}
            for y=p.y-1,p.y-2,-1 do
                local entry,w=state(p,y)
                if not entry then return nil,fail('build_failed','missing support expectation') end
                if entry.kind=='natural' and not w then
                    for _,fill in ipairs(fills) do
                        if fill.material~=entry.material then
                            return nil,fail('build_failed','fill differs from natural support material')
                        end
                    end
                    supported=true; break
                end
                if not w or w.kind~='fill' or (entry.kind~='air' and entry.kind~='replaceable') then
                    return nil,fail('build_failed','missing required fill')
                end
                fills[#fills+1]=w
            end
            if not supported then return nil,fail('build_failed','missing natural fill support') end
        end
        for _,p in ipairs(plan.writes) do
            local surface=route_surfaces[p.x..':'..p.z]
            local entry=observed[key(p)]
            if not surface or p.y<surface.y-1 or p.y>surface.y+3
                or (p.y==surface.y and p.kind~='road')
                or (p.y<surface.y and p.kind~='fill')
                or (p.y>surface.y and p.kind~='air')
                or entry.protected~=false
                or (entry.kind~='natural' and entry.kind~='air' and entry.kind~='replaceable') then
                return nil,fail('build_failed','write outside growth geometry')
            end
        end
        -- A preserved overlap is already constructed only if it has a road,
        -- solid support and clear headroom. This rejects a removed required
        -- road, fill, cut or clearance operation independently of composition.
        local nodes={}
        for _,p in ipairs(patch.preserved) do nodes[key(p)]=p end
        for _,p in ipairs(patch.surfaces) do
            local function at(y) return nodes[p.x..':'..y..':'..p.z] end
            local road,support=at(p.y),at(p.y-1)
            local classified=support and ops.classify({name=support.name,param2=support.param2},false)
            if not road or road.name~='mcl_core:cobble' or not classified or classified.kind~='natural' then
                return nil,fail('build_failed','seam road or support requires construction')
            end
            for y=p.y+1,p.y+3 do
                if not at(y) or at(y).name~='air' then return nil,fail('build_failed','seam headroom requires construction') end
            end
        end
    end
    if plan.version==2 then
        local exact, written = {}, {}
        local function key(p) return p.x..':'..p.y..':'..p.z end
        local observed={}
        for _,p in ipairs(plan.expectations) do
            if not valid_position(p) or observed[key(p)] then
                return nil,fail('build_failed','invalid or duplicate construction expectation')
            end
            observed[key(p)]=true
            if p.name then
                if type(p.name)~='string' or p.name=='' or type(p.param2)~='number'
                    or p.param2~=math.floor(p.param2) or p.param2<0 or p.param2>255
                    or p.has_metadata~=false or p.protected~=false then
                    return nil,fail('build_failed','invalid exact connector expectation')
                end
                exact[key(p)]=p
            end
        end
        for _,p in ipairs(plan.writes) do
            if not valid_position(p) or written[key(p)] then
                return nil,fail('build_failed','invalid or duplicate construction write')
            end
            written[key(p)]=true
        end
        for _,side in ipairs({'start','goal'}) do
            local connector=e[side] and e[side].connector
            local other=provenance[side] and provenance[side].connector
            if (connector~=nil) ~= (other~=nil) then
                return nil,fail('build_failed','inconsistent connector provenance')
            end
            if connector then
                if connector.version~=1 or other.version~=1 or not equal(connector,other)
                    or type(connector.preserved)~='table'
                    or #connector.preserved==0 then
                    return nil,fail('build_failed','invalid connector expectations')
                end
                for _,p in ipairs(connector.preserved) do
                    if not valid_position(p) then return nil,fail('build_failed','invalid preserved position') end
                    local q=exact[key(p)]
                    if not q or written[key(p)] or q.name~=p.name or q.param2~=p.param2
                        or q.has_metadata~=false or p.has_metadata~=false
                        or q.protected~=false or p.protected~=false then
                        return nil,fail('build_failed','connector preservation is incomplete')
                    end
                end
            end
        end
    end
    local blocks,seen={},{}
    for _,p in ipairs(plan.expectations) do
        local x,y,z=math.floor(p.x/16)*16,math.floor(p.y/16)*16,math.floor(p.z/16)*16
        local key=x..':'..y..':'..z
        if not seen[key] then
            seen[key]=true; blocks[#blocks+1]={x=x,y=y,z=z}
        end
    end
    local self={cancelled=false,index=1}
    function self:cancel() self.cancelled=true end
    local function finish(err,metrics) if not self.cancelled then done(err,metrics) end end
    local tick
    local function final()
        local started=ops.now()
        -- Optional coordination hook (for example the Towns writer check). It
        -- runs in the same synchronous callback as the writes. 'defer' reloads
        -- the blocks later; a failure performs zero writes.
        if ops.guard then
            local verdict,why=ops.guard(plan)
            if verdict=='defer' then
                self.index=1
                local ok,err=pcall(ops.after,1,function() if not self.cancelled then tick() end end)
                if not ok then finish(fail('build_failed','cannot schedule construction: '..tostring(err))) end
                return
            elseif verdict~='ok' then
                return finish(type(why)=='table' and why or fail('build_failed','construction guard rejected the plan'))
            end
        end
        -- Snow can melt while a long search runs. A planned clear already
        -- removes the snow, so its disappearance has the same outcome.
        local clears={}
        for _,p in ipairs(plan.writes) do
            if p.kind=='air' then clears[p.x..':'..p.y..':'..p.z]=true end
        end
        for _,p in ipairs(plan.expectations) do
            local node=ops.access.get_node(p)
            local meta=node and ops.access.has_metadata(p)
            local entry=ops.classify(node,meta)
            local timer=ops.has_timer(p)
            if timer or (plan.version==3 and p.name~=nil and timer~=false) then
                return finish(fail(plan.version==3 and p.name~=nil and 'seam_changed' or 'stale_plan',
                    'a node timer is active or unknown in the construction footprint'))
            end
            local protected=ops.access.is_protected(p,plan.owner)
            if p.name ~= nil then
                if (plan.version~=2 and plan.version~=3) or not node or node.name~=p.name
                    or node.param2~=p.param2 or meta~=p.has_metadata
                    or protected~=p.protected then
                    return finish(fail(plan.version==3 and 'seam_changed' or 'stale_plan','preserved node changed at '..p.x..','..p.y..','..p.z))
                end
            else
            local melted_snow=p.kind=='replaceable' and p.material=='mcl_core:snow'
                and entry.kind=='air' and clears[p.x..':'..p.y..':'..p.z]
            local grass_changed=p.kind=='natural' and entry.kind=='natural'
                and p.material=='mcl_core:dirt_with_grass_snow' and entry.material=='mcl_core:dirt_with_grass'
            if (not melted_snow and not grass_changed
                and (entry.kind~=p.kind or entry.material~=p.material)) or protected~=p.protected then
                return finish(fail('stale_plan','terrain, metadata, or protection changed at '..p.x..','..p.y..','..p.z))
            end
            end
        end
        local count=0
        for _,p in ipairs(plan.writes) do
            local name=p.kind=='road' and 'mcl_core:cobble' or p.kind=='air' and 'air' or p.material
            local ok,err=pcall(ops.write,p,{name=name})
            if not ok then
                return finish(fail('partial_build','construction stopped after '..count..' completed writes; the failed write may also have changed terrain: '..tostring(err)),
                    {writes=count,pause_seconds=ops.now()-started})
            end
            count=count+1
        end
        finish(nil,{writes=count,pause_seconds=ops.now()-started})
    end
    tick=function()
        if self.cancelled then return end
        local stop=math.min(self.index+15,#blocks)
        for i=self.index,stop do
            local p=blocks[i]
            local ok,result=pcall(ops.load,p,{x=p.x+15,y=p.y+15,z=p.z+15})
            if not ok or result==false then return finish(fail('build_failed','could not load construction terrain')) end
        end
        self.index=stop+1
        if self.index<=#blocks then
            local ok,err=pcall(ops.after,0,tick)
            if not ok then finish(fail('build_failed','cannot schedule construction: '..tostring(err))) end
        else
            local ok,err=pcall(final)
            if not ok then finish(fail('build_failed','construction preflight failed: '..tostring(err))) end
        end
    end
    local ok,err=pcall(ops.after,0,tick)
    if not ok then return nil,fail('build_failed','cannot schedule construction: '..tostring(err)) end
    return self
end
return build
