-- SPDX-License-Identifier: GPL-3.0-or-later
-- Exact, read-only validation of a bounded continuation patch.
local seam = {}

local function integer(n)
    return type(n)=='number' and n==n and n~=math.huge and n~=-math.huge
        and n==math.floor(n)
end

local function changed(reason, position)
    return nil, {code='seam_changed', reason=reason, position=position}
end

local function key2(p) return p.x..':'..p.z end
local function key3(p) return p.x..':'..p.y..':'..p.z end
local function point(p)
    return type(p)=='table' and integer(p.x) and integer(p.y) and integer(p.z)
        and math.abs(p.x)<=31000 and math.abs(p.y)<=31000 and math.abs(p.z)<=31000
end
local function array(t, maximum)
    if type(t)~='table' or #t>maximum then return false end
    local n=0
    for k in pairs(t) do
        if not integer(k) or k<1 or k>#t then return false end
        n=n+1
    end
    return n==#t
end

-- Derive an intended patch from an already validated source plan and a bounded
-- exact snapshot captured and checked against that plan before any writes.
-- source_surfaces is checked against the source plan's rasterized footprint.
-- This function does not authenticate saved records or inspect the world itself.
function seam.derive(raster, plan, source_surfaces, snapshot, classify)
    if type(raster)~='table' or type(raster.segment)~='function' or type(raster.join)~='function'
        or type(plan)~='table' or not array(plan.centerline,1024)
        or #plan.centerline<2 or not array(plan.headings,1023)
        or #plan.headings~=#plan.centerline-1 or not array(plan.expectations,50000)
        or not array(plan.writes,10000) or not array(source_surfaces,50000)
        or not array(snapshot,50000) or type(classify)~='function' then
        return changed('invalid source plan or exact snapshot')
    end
    local tail={}
    for i=math.max(1,#plan.centerline-2),#plan.centerline do
        local p=plan.centerline[i]
        if not point(p) then return changed('invalid source tail') end
        tail[#tail+1]={x=p.x,y=p.y,z=p.z}
    end
    local joined
    for i=1,#tail-1 do
        local edge,err=raster.segment(tail[i],tail[i+1])
        if not edge or edge.grade>0.25 then return changed('invalid source tail geometry',err and err.position) end
        if joined then
            joined,err=raster.join(joined,edge)
            if not joined then return changed('conflicting source tail geometry',err and err.position) end
        else joined=edge end
    end
    local heading=plan.headings[#plan.headings]
    local dirs={{1,0},{1,1},{0,1},{-1,1},{-1,0},{-1,-1},{0,-1},{1,-1}}
    local prev,last=tail[#tail-1],tail[#tail]
    if not integer(heading) or heading<0 or heading>7
        or last.x-prev.x~=4*dirs[heading+1][1] or last.z-prev.z~=4*dirs[heading+1][2] then
        return changed('source heading does not match tail')
    end
    local footprint={}
    local source_raster,source_count={},0
    for i=1,#plan.centerline-1 do
        local edge=raster.segment(plan.centerline[i],plan.centerline[i+1])
        if not edge then return changed('invalid source geometry') end
        for _,p in ipairs(edge.columns) do
            local id=key2(p)
            if source_raster[id]~=nil and source_raster[id]~=p.y then
                return changed('conflicting source footprint',p)
            end
            if source_raster[id]==nil then
                source_count=source_count+1
                if source_count>50000 then return changed('source footprint exceeds allocation limit',p) end
            end
            source_raster[id]=p.y
        end
    end
    for _,endpoint in pairs(plan.endpoints or {}) do
        local transition=type(endpoint)=='table' and endpoint.connector and endpoint.connector.transition
        for _,p in ipairs(transition and transition.surfaces or {}) do
            if not point(p) or (source_raster[key2(p)]~=nil and source_raster[key2(p)]~=p.y) then
                return changed('invalid source transition footprint',p)
            end
            if source_raster[key2(p)]==nil then
                source_count=source_count+1
                if source_count>50000 then return changed('source footprint exceeds allocation limit',p) end
            end
            source_raster[key2(p)]=p.y
        end
    end
    for _,p in ipairs(source_surfaces) do
        if not point(p) or footprint[key2(p)]~=nil or source_raster[key2(p)]~=p.y then
            return changed('invalid source footprint')
        end
        footprint[key2(p)]=p.y
    end
    for id,y in pairs(source_raster) do
        if footprint[id]~=y then return changed('incomplete source footprint') end
    end
    local expected,raw,writes={},{},{}
    for _,p in ipairs(plan.expectations) do
        if not point(p) or expected[key3(p)] then return changed('invalid source expectations') end
        expected[key3(p)]=p
    end
    for _,p in ipairs(snapshot) do
        if not point(p) or raw[key3(p)] or type(p.name)~='string' or p.name=='' or p.name=='ignore'
            or not integer(p.param2) or p.param2<0 or p.param2>255
            or p.has_metadata~=false or p.protected~=false or p.has_timer~=false then
            return changed('invalid exact source snapshot')
        end
        raw[key3(p)]=p
    end
    for _,p in ipairs(plan.writes) do
        if not point(p) or writes[key3(p)] or not expected[key3(p)]
            or (p.kind~='road' and p.kind~='fill' and p.kind~='air')
            or (p.kind=='fill' and (type(p.material)~='string' or p.material=='')) then
            return changed('invalid source write')
        end
        writes[key3(p)]=p
    end
    local result={version=1,tail=tail,endpoint=last,heading=heading,surfaces={},bands={},preserved={}}
    for _,p in ipairs(joined.columns) do
        local actual=footprint[key2(p)]
        if actual~=nil then
            if actual~=p.y then return changed('tail differs from source footprint',p) end
            result.surfaces[#result.surfaces+1]={x=p.x,y=p.y,z=p.z}
            local min=p.y-1
            -- Construction may extend below the ordinary support position for fill.
            while expected[p.x..':'..(min-1)..':'..p.z] do min=min-1 end
            result.bands[#result.bands+1]={x=p.x,z=p.z,min_y=min}
            for y=min,p.y+3 do
                local pos={x=p.x,y=y,z=p.z}
                local id=key3(pos)
                local old,write=raw[id],writes[id]
                if not expected[id] or not old then return changed('source band is incomplete',pos) end
                local expectation=expected[id]
                local ok,entry=pcall(classify,{name=old.name,param2=old.param2},old.has_metadata)
                local matches=expectation.name~=nil
                    and expectation.name==old.name and expectation.param2==old.param2
                    and expectation.has_metadata==old.has_metadata and expectation.protected==old.protected
                    or expectation.name==nil and ok and type(entry)=='table' and entry.kind==expectation.kind
                    and entry.material==expectation.material and expectation.protected==old.protected
                if not matches then
                    return changed('source snapshot differs from plan expectation',pos)
                end
                local name,param2=old.name,old.param2
                if write then
                    name=write.kind=='road' and 'mcl_core:cobble' or write.kind=='air' and 'air' or write.material
                    param2=0
                end
                result.preserved[#result.preserved+1]={x=p.x,y=y,z=p.z,name=name,param2=param2,
                    has_metadata=false,protected=false}
                if #result.preserved>512 then
                    return nil,{code='seam_changed',reason='seam patch exceeds 512 nodes',
                        position=pos,limit=512,observed=#result.preserved}
                end
            end
        else return changed('source tail outside footprint',p) end
    end
    if #result.surfaces==0 or footprint[key2(last)]~=last.y then return changed('source endpoint is outside footprint') end
    local valid,err=seam.validate(raster,result)
    if not valid then return nil,err end
    return result
end

-- Structural validation alone is not source authentication. The caller must
-- also compare the complete patch with the durable source-derived record.
function seam.validate(raster, patch)
    if type(raster)~='table' or type(raster.segment)~='function' or type(raster.join)~='function'
        or type(patch)~='table' or patch.version~=1 or not array(patch.tail,3)
        or #patch.tail<2 or not array(patch.surfaces,512) or #patch.surfaces==0
        or not array(patch.bands,512) or #patch.bands~=#patch.surfaces
        or not array(patch.preserved,512) or #patch.preserved==0 then
        return changed('invalid seam structure')
    end
    local joined
    for i=1,#patch.tail-1 do
        if not point(patch.tail[i]) or not point(patch.tail[i+1]) then return changed('invalid seam tail') end
        local edge,err=raster.segment(patch.tail[i],patch.tail[i+1])
        if not edge or edge.grade>0.25 then return changed('invalid seam tail geometry',err and err.position) end
        if joined then
            joined,err=raster.join(joined,edge)
            if not joined then return changed('invalid seam tail join',err and err.position) end
        else joined=edge end
    end
    local previous,endpoint=patch.tail[#patch.tail-1],patch.tail[#patch.tail]
    local dirs={{1,0},{1,1},{0,1},{-1,1},{-1,0},{-1,-1},{0,-1},{1,-1}}
    if not point(patch.endpoint) or patch.endpoint.x~=endpoint.x or patch.endpoint.y~=endpoint.y
        or patch.endpoint.z~=endpoint.z or not integer(patch.heading) or patch.heading<0 or patch.heading>7
        or endpoint.x-previous.x~=4*dirs[patch.heading+1][1]
        or endpoint.z-previous.z~=4*dirs[patch.heading+1][2] then
        return changed('seam endpoint or heading is inconsistent')
    end
    if #patch.tail==3 then
        local first,mid=patch.tail[1],patch.tail[2]
        local incoming
        for i,d in ipairs(dirs) do
            if mid.x-first.x==4*d[1] and mid.z-first.z==4*d[2] then incoming=i-1 end
        end
        local difference=incoming and math.abs(incoming-patch.heading)
        if not difference or math.min(difference,8-difference)>1 then
            return changed('seam tail turn exceeds 45 degrees')
        end
    end
    local raster_columns,surfaces,bands,nodes={},{},{},{}
    for _,p in ipairs(joined.columns) do raster_columns[key2(p)]=p.y end
    for _,p in ipairs(patch.surfaces) do
        if not point(p) or surfaces[key2(p)] or raster_columns[key2(p)]~=p.y then
            return changed('invalid seam surface',p)
        end
        surfaces[key2(p)]=p.y
    end
    for id,y in pairs(raster_columns) do
        if surfaces[id]~=y then return changed('incomplete seam surface footprint') end
    end
    if surfaces[key2(endpoint)]~=endpoint.y then return changed('missing seam endpoint surface') end
    for _,p in ipairs(patch.bands) do
        if type(p)~='table' or not integer(p.x) or not integer(p.z) or not integer(p.min_y)
            or bands[key2(p)] or surfaces[key2(p)]==nil or p.min_y>surfaces[key2(p)]-1
            or p.min_y < -31000 then return changed('invalid seam band') end
        bands[key2(p)]=p.min_y
    end
    for _,p in ipairs(patch.preserved) do
        if not point(p) or nodes[key3(p)] or type(p.name)~='string' or p.name=='' or p.name=='ignore'
            or not integer(p.param2) or p.param2<0 or p.param2>255
            or p.has_metadata~=false or p.protected~=false then return changed('invalid preserved node',p) end
        local min,y=bands[key2(p)],surfaces[key2(p)]
        if not min or p.y<min or p.y>y+3 then return changed('preserved node outside seam band',p) end
        nodes[key3(p)]=true
    end
    for id,y in pairs(surfaces) do
        local min=bands[id]
        if not min or y+3-min+1>512 then return changed('missing or oversized seam band') end
        local x,z=id:match('^(-?%d+):(-?%d+)$')
        for height=min,y+3 do
            if not nodes[x..':'..height..':'..z] then return changed('missing preserved node') end
        end
    end
    return true
end

-- The caller is responsible for authenticating the patch's geometry and
-- loading existing mapblocks. This function never loads or generates terrain.
function seam.check_patch(preserved, access, owner, has_timer)
    if type(preserved)~='table' or #preserved==0 or #preserved>512 then
        return changed('invalid or oversized seam patch')
    end
    if type(access)~='table' or type(access.get_node)~='function'
        or type(access.has_metadata)~='function' or type(access.is_protected)~='function'
        or type(owner)~='string' or type(has_timer)~='function' then
        return changed('seam inspection is unavailable')
    end
    local seen={}
    for i,p in ipairs(preserved) do
        if type(p)~='table' or not integer(p.x) or not integer(p.y) or not integer(p.z)
            or math.abs(p.x)>31000 or math.abs(p.y)>31000 or math.abs(p.z)>31000
            or type(p.name)~='string' or p.name=='' or p.name=='ignore'
            or not integer(p.param2) or p.param2<0 or p.param2>255
            or p.has_metadata~=false or p.protected~=false then
            return changed('invalid seam expectation at index '..i)
        end
        local key=p.x..':'..p.y..':'..p.z
        if seen[key] then return changed('duplicate seam expectation',p) end
        seen[key]=true
        local ok,node=pcall(access.get_node,p)
        if not ok or type(node)~='table' or node.name~=p.name or node.param2~=p.param2 then
            return changed('seam node is missing or changed',p)
        end
        local mok,metadata=pcall(access.has_metadata,p)
        local pok,protected=pcall(access.is_protected,p,owner)
        local tok,timer=pcall(has_timer,p)
        if not mok or metadata~=false or not pok or protected~=false
            or not tok or timer~=false then
            return changed('seam metadata, protection or timer changed or is unknown',p)
        end
    end
    -- Reject holes and extra keys: ipairs alone would silently skip them.
    local count=0
    for k in pairs(preserved) do
        if not integer(k) or k<1 or k>#preserved then return changed('invalid seam patch array') end
        count=count+1
    end
    if count~=#preserved then return changed('incomplete seam patch array') end
    return true
end

-- Verify the world and surveyed seam columns before allowing v3 geometry.
-- Durable source authentication is a separate service responsibility.
function seam.check_request(raster, request, terrain, access, has_timer)
    if type(request)~='table' or type(request.provenance)~='table'
        or type(request.provenance.start)~='table'
        or request.provenance.start.origin~='growth_seam' or type(request.start_seam)~='table'
        or request.start_heading~=request.start_seam.heading
        or type(terrain)~='table' or type(terrain.get_column)~='function' then
        return changed('inconsistent seam request')
    end
    local valid,err=seam.validate(raster,request.start_seam)
    if not valid then return nil,err end
    local p=request.start_seam.endpoint
    if not point(request.start) or request.start.x~=p.x or request.start.y~=p.y or request.start.z~=p.z then
        return changed('seam endpoint differs from request')
    end
    valid,err=seam.check_patch(request.start_seam.preserved,access,terrain.owner,has_timer)
    if not valid then return nil,err end
    local exact={}
    for _,node in ipairs(request.start_seam.preserved) do exact[key3(node)]=node end
    local overlays={}
    for _,surface in ipairs(request.start_seam.surfaces) do
        local ok,col=pcall(terrain.get_column,surface.x,surface.z)
        if not ok or type(col)~='table' or col.status~='ok' or not integer(col.ground_y)
            or type(col.band)~='table' then
            return changed('seam surface differs from survey',surface)
        end
        local band={}
        for offset=-3,5 do band[offset]=col.band[surface.y+offset-col.ground_y] end
        for y=surface.y-1,surface.y+3 do
            local entry=band[y-surface.y]
            local node=exact[surface.x..':'..y..':'..surface.z]
            if not entry or not node or entry.protected~=false
                or (node.name=='air' and entry.kind~='air')
                or (node.name~='air' and entry.material~=node.name) then
                return changed('surveyed seam band differs from exact world',surface)
            end
        end
        local top=band[0]
        if top.kind~='natural' then return changed('seam road is not natural solid',surface) end
        overlays[key2(surface)]={status='ok',ground_y=surface.y,material=top.material,band=band}
    end
    local result={}
    for k,v in pairs(terrain) do result[k]=v end
    result.get_column=function(x,z) return overlays[x..':'..z] or terrain.get_column(x,z) end
    return true,nil,result
end

return seam
