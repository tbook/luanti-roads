-- SPDX-License-Identifier: GPL-3.0-or-later
-- Load existing mapblocks in small batches, then validate and write without yielding.
local build={}
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
    if (plan.version~=1 and plan.version~=2)
        or (plan.version==1 and (plan.connector_version~=nil or has_connector))
        or (plan.version==2 and (plan.connector_version~=1 or not has_connector))
        or plan.connector or plan.connectors or e.connector or e.connectors
        or provenance.connector or provenance.connectors
        or (e.start and e.start.connectors) or (e.goal and e.goal.connectors)
        or (provenance.start and provenance.start.connectors)
        or (provenance.goal and provenance.goal.connectors)
        or (plan.version==1 and ((provenance.start and provenance.start.connector)
            or (provenance.goal and provenance.goal.connector))) then
        return nil,fail('build_failed','unsupported plan version or connector')
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
    local function final()
        local started=ops.now()
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
            if ops.has_timer(p) then
                return finish(fail('stale_plan','a node timer is active in the construction footprint'))
            end
            local protected=ops.access.is_protected(p,plan.owner)
            if p.name ~= nil then
                if plan.version~=2 or not node or node.name~=p.name
                    or node.param2~=p.param2 or meta~=p.has_metadata
                    or protected~=p.protected then
                    return finish(fail('stale_plan','connector changed at '..p.x..','..p.y..','..p.z))
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
    local function tick()
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
