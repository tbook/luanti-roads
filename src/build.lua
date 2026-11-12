-- SPDX-License-Identifier: GPL-3.0-or-later
-- Load existing mapblocks in small batches, then validate and write without yielding.
local build={}
local function fail(code,reason) return {code=code,reason=reason} end
function build.new(plan,ops,done)
    if type(plan)~='table' or type(plan.owner)~='string' or type(plan.writes)~='table'
        or type(plan.expectations)~='table' then
        return nil,fail('build_failed','invalid construction plan')
    end
    if #plan.writes>10000 or #plan.expectations>50000 then
        return nil,fail('write_budget','construction exceeds the 10,000-write or 50,000-node inspection limit')
    end
    -- Any future connector contract must bump plan.version. Older builders
    -- cannot safely validate or preserve its extra geometry.
    local e=plan.endpoints or {}
    local provenance=plan.request and plan.request.provenance or {}
    if plan.version~=1 or plan.connector or plan.connectors or e.connector or e.connectors
        or provenance.connector or provenance.connectors
        or (e.start and (e.start.connector or e.start.connectors))
        or (e.goal and (e.goal.connector or e.goal.connectors))
        or (provenance.start and (provenance.start.connector or provenance.start.connectors))
        or (provenance.goal and (provenance.goal.connector or provenance.goal.connectors)) then
        return nil,fail('build_failed','unsupported plan version or connector')
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
        for _,p in ipairs(plan.expectations) do
            local node=ops.access.get_node(p)
            local meta=node and ops.access.has_metadata(p)
            local entry=ops.classify(node,meta)
            if ops.has_timer(p) then
                return finish(fail('stale_plan','a node timer is active in the construction footprint'))
            end
            local protected=ops.access.is_protected(p,plan.owner)
            if entry.kind~=p.kind or entry.material~=p.material or protected~=p.protected then
                return finish(fail('stale_plan','terrain, metadata, or protection changed at '..p.x..','..p.y..','..p.z))
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
