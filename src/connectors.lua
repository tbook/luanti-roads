-- SPDX-License-Identifier: GPL-3.0-or-later
-- Bounded inspection of the straight Towns stair and slab approach vocabulary.
local connectors = {}
local MAX_READS,MAX_LOAD_VOXELS,MAX_PAIR_CHECKS=30000,2000000,4096
local stair, slab, full = 'mcl_stairs:stair_cobble', 'mcl_stairs:slab_cobble', 'mcl_core:cobble'
local directions={{x=1,z=0,p2=1},{x=0,z=1,p2=0},{x=-1,z=0,p2=3},{x=0,z=-1,p2=2}}
local function round(n) return math.floor(n+0.5) end
local function id(p) return p.x..':'..p.y..':'..p.z end
local function fail(reason,p) return nil,{code='invalid_endpoint',reason=reason,position=p} end
local function same(a,b) return a.name==b.name and a.param2==b.param2 and a.y==b.y end
local function copy(p) return {x=p.x,y=p.y,z=p.z} end
local function in_bounds(b,p)
    return p.x>=b.min_x and p.x<=b.max_x and p.y>=b.min_y and p.y<=b.max_y
        and p.z>=b.min_z and p.z<=b.max_z
end

-- Load individual previously surveyed mapblocks lazily. The rounded volume is
-- included in the limit even though inspection retains only a small read cache.
local function reader(terrain,access,load)
    local cache,blocks,volume,count={}, {},0,0
    local function read(p)
        if not in_bounds(terrain.bounds,p) then return nil,'connector exceeds surveyed bounds' end
        local key=id(p); if cache[key] then return cache[key] end
        local bx,by,bz=math.floor(p.x/16)*16,math.floor(p.y/16)*16,math.floor(p.z/16)*16
        local lo={x=bx,y=by,z=bz}; local hi={x=bx+15,y=by+15,z=bz+15}
        if not in_bounds(terrain.bounds,lo) or not in_bounds(terrain.bounds,hi) then
            return nil,'connector mapblock exceeds surveyed bounds'
        end
        local block=id(lo)
        if not blocks[block] then
            volume=volume+4096
            if volume>MAX_LOAD_VOXELS then return nil,'connector mapblock load budget exceeded' end
            local ok,result=pcall(load,lo,hi)
            if not ok or result==false then return nil,'connector mapblock could not be loaded' end
            blocks[block]=true
        end
        local ok,node=pcall(access.get_node,p)
        if not ok or type(node)~='table' or type(node.name)~='string' or node.name=='ignore'
            or type(node.param2)~='number' then return nil,'unknown connector node' end
        local m,meta=pcall(access.has_metadata,p)
        local q,protected=pcall(access.is_protected,p,terrain.owner)
        if not m or type(meta)~='boolean' or not q or type(protected)~='boolean' then
            return nil,'unknown connector metadata or protection'
        end
        local v={x=p.x,y=p.y,z=p.z,name=node.name,param2=node.param2,
            has_metadata=meta,protected=protected}
        cache[key]=v
        count=count+1
        if count>MAX_READS then return nil,'connector read budget exceeded' end
        return v
    end
    return read
end

local function surface_height(node,d,half)
    if node.name==full and node.param2==0 then return node.y+0.5 end
    if node.name==slab and node.param2==0 then return node.y end
    if node.name==stair and node.param2>=0 and node.param2<=3 then
        if node.param2~=d.p2 and node.param2~=(d.p2+2)%4 then return nil end
        local high=(node.param2==d.p2 and half>0) or (node.param2~=(d.p2) and half<0)
        return node.y+(high and 0.5 or 0)
    end
end

local function selected(read,feet)
    local x,z=round(feet.x),round(feet.z)
    for _,y in ipairs({math.floor(feet.y),math.floor(feet.y-0.5)}) do
        local p={x=x,y=y,z=z}; local node,why=read(p)
        if not node then return nil,why,p end
        if node.name==stair or node.name==slab then return node end
    end
    return false
end

local function inspect_direction(terrain,read,feet,selection,d,classify,access)
    local lateral={x=-d.z,z=d.x}
    local function row_piece(x,z,near)
        local found
        for y=near+1,near-1,-1 do
            local p={x=x,y=y,z=z}; local n,why=read(p)
            if not n then return nil,why,p end
            if n.name==stair or n.name==slab or n.name==full then
                if not surface_height(n,d,-1) then return nil,'unsupported or misoriented approach node',p end
                found=n; break
            end
        end
        return found
    end
    local offsets={0}; local min,max=0,0
    for _,sign in ipairs({-1,1}) do
        for n=1,5 do
            local off=n*sign
            local node,why,pos=row_piece(selection.x+lateral.x*off,selection.z+lateral.z*off,selection.y)
            if why then return nil,why,pos end
            if not node or not same(node,selection) then break end
            min=math.min(min,off); max=math.max(max,off)
        end
    end
    local width=max-min+1
    if width~=2 and width~=4 then return nil,'approach strip must be maximally two or four nodes wide',selection end
    for off=min,max do offsets[#offsets+1]=off end
    table.remove(offsets,1)
    local preserved,seen,path={}, {},{}
    local function retain(node)
        if node.has_metadata then return nil,'connector node has metadata',node end
        if node.protected then return nil,'connector node is protected',node end
        local key=id(node); if not seen[key] then seen[key]=true; preserved[#preserved+1]=node end
        return true
    end
    local last_y,previous=selection.y,nil
    local rows=0
    for n=0,16 do
        local x,z=selection.x+n*d.x,selection.z+n*d.z
        local first,why,pos=row_piece(x+lateral.x*min,z+lateral.z*min,last_y)
        if why then return nil,why,pos end
        if not first then break end
        if n==16 then return nil,'approach exceeds sixteen preserved rows',first end
        local h1,h2=surface_height(first,d,-1),surface_height(first,d,1)
        if not h1 or (previous and math.abs(h1-previous)>0.5) then
            return nil,'approach has an unsafe or unsupported step',first
        end
        for _,off in ipairs(offsets) do
            local node,err,where=row_piece(x+lateral.x*off,z+lateral.z*off,last_y)
            if err then return nil,err,where end
            if not node or not same(node,first) then return nil,'approach row is inconsistent',node or {x=x+lateral.x*off,y=last_y,z=z+lateral.z*off} end
            local ok; ok,err,where=retain(node); if not ok then return nil,err,where end
            local supported=false
            for depth=1,32 do
                local below; below,err=read({x=node.x,y=node.y-depth,z=node.z})
                if not below then return nil,err,node end
                ok,err,where=retain(below); if not ok then return nil,err,where end
                if below.name~=full then
                    local kind=classify(below,false)
                    if kind and kind.kind=='natural' then supported=true; break end
                    return nil,'approach support is missing or unsupported',below
                end
            end
            if not supported then return nil,'approach support depth exceeds 32 nodes',node end
            for dy=1,3 do
                local clear; clear,err=read({x=node.x,y=node.y+dy,z=node.z})
                if not clear then return nil,err,node end
                ok,err,where=retain(clear); if not ok then return nil,err,where end
                if clear.name~='air' then return nil,'approach headroom is obstructed',clear end
            end
            local lit,light=pcall(access.get_natural_light,{x=node.x,y=node.y+3,z=node.z},0.5)
            if not lit or light~=15 then return nil,'approach is not in outdoor daylight',node end
        end
        for _,off in ipairs({min-1,max+1}) do
            local extra,err,where=row_piece(x+lateral.x*off,z+lateral.z*off,last_y)
            if err then return nil,err,where end
            if extra then return nil,'approach has an irregular or wider row',extra end
        end
        if n==0 then
            local along=(feet.x-selection.x)*d.x+(feet.z-selection.z)*d.z
            local height=surface_height(first,d,along>=0 and 1 or -1)
            if math.abs(feet.y-height)>0.2 then return nil,'selected stair half does not match player feet',selection end
        end
        path[#path+1]={x=x-0.25*d.x,y=h1,z=z-0.25*d.z}
        path[#path+1]={x=x+0.25*d.x,y=h2,z=z+0.25*d.z}
        previous,last_y,rows=h2,first.y,rows+1
    end
    if rows==0 then return nil,'no preserved approach',selection end
    return {direction={x=d.x,z=d.z},width=width,path=path,preserved=preserved,
        rows=rows,last_height=previous,selection=selection,min=min,max=max,lateral=lateral}
end

-- Transition columns are deliberately flat: a full-block-only seam cannot
-- safely bridge a half-height slope without introducing new shaped nodes.
local function transition(terrain,c,landing)
    local d,t=c.direction,c.lateral
    local along=(landing.x-c.selection.x)*d.x+(landing.z-c.selection.z)*d.z
    if along<c.rows+1 or along>c.rows+8 then return nil end
    if math.abs(c.last_height-(landing.y+0.5))>0.5 then return nil end
    local surfaces,seen,walking={}, {},{}
    local function add(x,z)
        local key=x..':'..z
        if not seen[key] then seen[key]=true; surfaces[#surfaces+1]={x=x,y=landing.y,z=z} end
    end
    for n=c.rows,along do
        for off=c.min,c.max do add(c.selection.x+n*d.x+off*t.x,c.selection.z+n*d.z+off*t.z) end
        walking[#walking+1]={x=c.selection.x+n*d.x,y=landing.y+0.5,z=c.selection.z+n*d.z}
    end
    local shift=(landing.x-c.selection.x)*t.x+(landing.z-c.selection.z)*t.z
    for off=math.min(0,shift),math.max(0,shift) do
        add(c.selection.x+along*d.x+off*t.x,c.selection.z+along*d.z+off*t.z)
    end
    local step=shift<0 and -1 or 1
    for off=step,shift,step do
        walking[#walking+1]={x=c.selection.x+along*d.x+off*t.x,y=landing.y+0.5,
            z=c.selection.z+along*d.z+off*t.z}
    end
    for x=landing.x-1,landing.x+1 do for z=landing.z-1,landing.z+1 do add(x,z) end end
    local writes,expectations={},{}
    for _,p in ipairs(surfaces) do
        local col=terrain.get_column(p.x,p.z)
        if type(col)~='table' or col.status~='ok' or col.ground_y~=p.y then return nil end
        for y=p.y-1,p.y+3 do
            local e=col.band[y-col.ground_y]
            if not e or (e.kind~='natural' and e.kind~='air' and e.kind~='replaceable')
                or type(e.protected)~='boolean' then return nil end
            if y==p.y-1 and e.kind~='natural' then return nil end
            local kind=y==p.y and 'road' or y>p.y and 'air' or nil
            local noop=kind=='road' and e.kind=='natural' and e.material==full
                or kind=='air' and e.kind=='air'
            if kind and not noop then
                if e.protected then return nil end
                writes[#writes+1]={x=p.x,y=y,z=p.z,kind=kind}
            end
            expectations[#expectations+1]={x=p.x,y=y,z=p.z,kind=e.kind,material=e.material,protected=e.protected}
        end
    end
    return {surfaces=surfaces,writes=writes,expectations=expectations,path=walking}
end

local function candidates(terrain,feet,selection,read,classify,access)
    local result,reason,position={},'no safe connector continuation',selection
    for _,d in ipairs(directions) do
        local c,why,where=inspect_direction(terrain,read,feet,selection,d,classify,access)
        if c then result[#result+1]=c else reason,position=why or reason,where or position end
    end
    return result,reason,position
end

local function landing_options(terrain,c,anchor)
    local result={}
    for n=c.rows+1,c.rows+8 do for shift=-3,3 do
        local x=c.selection.x+n*c.direction.x+shift*c.lateral.x
        local z=c.selection.z+n*c.direction.z+shift*c.lateral.z
        if n-c.rows+math.abs(shift)<=8 and (not anchor or ((x-anchor.x)%4==0 and (z-anchor.z)%4==0)) then
            local col=terrain.get_column(x,z)
            if col and col.status=='ok' then
                local landing={x=x,y=col.ground_y,z=z}
                local tr=transition(terrain,c,landing)
                if tr then result[#result+1]={landing=landing,transition=tr} end
            end
        end
    end end
    return result
end

local function make_endpoint(feet,c,option)
    return {requested=copy(feet),ground=copy(c.selection),resolved=copy(option.landing),
        connector={version=1,direction=c.direction,width=c.width,path=c.path,landing=copy(option.landing),
            preserved=c.preserved,transition=option.transition}}
end

-- Surface and access are injected for pure tests and to avoid retaining raw
-- terrain in the survey snapshot. Never emerges or generates terrain.
function connectors.endpoints(terrain,first,second,access,load,surface,edges)
    local ordinary=surface.endpoints(terrain,first,second)
    if ordinary then return ordinary end
    if type(access)~='table' or type(load)~='function' then return fail('connector inspection is unavailable') end
    local dx,dz=second.x-first.x,second.z-first.z
    if dx*dx+dz*dz>192*192 then return fail('requested endpoints exceed 192 nodes') end
    local read=reader(terrain,access,load)
    local a,why,where=selected(read,first); if a==nil then return fail(why,where) end
    local b; b,why,where=selected(read,second); if b==nil then return fail(why,where) end
    if not a and not b then return surface.endpoints(terrain,first,second) end
    for _,node in ipairs({a or false,b or false}) do
        if node and ((node.name==slab and node.param2~=0)
            or (node.name==stair and (node.param2~=math.floor(node.param2) or node.param2<0 or node.param2>3))) then
            return fail('selected stair or slab has an unsupported orientation',node)
        end
    end
    local ag,bg=surface.ground(terrain,first),surface.ground(terrain,second)
    if not a and not ag then return fail('invalid requested start ground',first) end
    if not b and not bg then return fail('invalid requested goal ground',second) end
    local ac,bc={},{}
    if a then ac,why,where=candidates(terrain,first,a,read,surface.classify,access); if #ac==0 then return fail(why,where) end end
    if b then bc,why,where=candidates(terrain,second,b,read,surface.classify,access); if #bc==0 then return fail(why,where) end end
    local starts={}
    if a then
        for _,c in ipairs(ac) do for _,o in ipairs(landing_options(terrain,c)) do
            starts[#starts+1]=make_endpoint(first,c,o)
        end end
    else starts[1]={requested=copy(first),ground=ag,resolved=copy(ag)} end
    local matches,pairs_checked={},0
    for _,start in ipairs(starts) do
        local goals={}
        if b then
            for _,c in ipairs(bc) do for _,o in ipairs(landing_options(terrain,c,start.resolved)) do
                goals[#goals+1]=make_endpoint(second,c,o)
            end end
        else
            local x=start.resolved.x+4*round((second.x-start.resolved.x)/4)
            local z=start.resolved.z+4*round((second.z-start.resolved.z)/4)
            local col=terrain.get_column(x,z)
            if col and col.status=='ok' and (second.x-x)^2+(second.z-z)^2<=9 and math.abs(col.ground_y-bg.y)<=2 then
                goals[1]={requested=copy(second),ground=bg,resolved={x=x,y=col.ground_y,z=z}}
            end
        end
        for _,goal in ipairs(goals) do
            pairs_checked=pairs_checked+1
            if pairs_checked>MAX_PAIR_CHECKS then return fail('connector landing candidate budget exceeded',a or b) end
            local x,z=goal.resolved.x-start.resolved.x,goal.resolved.z-start.resolved.z
            if x*x+z*z>0 and x*x+z*z<=192*192 then
                local provenance={start=start,goal=goal}
                local constraints=edges and edges.connector_constraints(provenance)
                local feasible=constraints~=nil
                if feasible then
                    for _,side in ipairs({'start','goal'}) do
                        if provenance[side].connector then
                            local point=provenance[side].resolved
                            local accepted=false
                            for h=0,7 do
                                local dir=({{1,0},{1,1},{0,1},{-1,1},{-1,0},{-1,-1},{0,-1},{1,-1}})[h+1]
                                local state=side=='start' and {i=0,j=0} or {i=-dir[1],j=-dir[2]}
                                local edge=edges.evaluate(terrain,point,state,h,{road_material=full,constraints=constraints})
                                if edge.ok then accepted=true; break end
                            end
                            if not accepted then feasible=false; break end
                        end
                    end
                end
                if feasible then matches[#matches+1]=provenance end
            end
        end
    end
    if #matches==0 then return fail('no lattice-compatible natural connector landing',a or b) end
    local first_match=matches[1]
    for i=2,#matches do
        for _,side in ipairs({'start','goal'}) do
            local x,y=first_match[side].connector,matches[i][side].connector
            if x and y and (x.direction.x~=y.direction.x or x.direction.z~=y.direction.z) then
                return fail('approach has ambiguous usable continuations',first_match[side].ground)
            end
        end
    end
    return first_match
end

return connectors
