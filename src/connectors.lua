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

-- Shared per-node checks: preserve the node, its support column and its
-- headroom, and require outdoor daylight. Used by both the player-selected
-- stair inspection and the published-exit revalidation.
local function retainer()
    local preserved,seen={}, {}
    local function retain(node)
        if node.has_metadata then return nil,'connector node has metadata',node end
        if node.protected then return nil,'connector node is protected',node end
        local key=id(node); if not seen[key] then seen[key]=true; preserved[#preserved+1]=node end
        return true
    end
    return retain,preserved
end

local function check_node(read,node,classify,access,retain)
    local ok,err,where=retain(node); if not ok then return nil,err,where end
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
    return true
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
    local retain,preserved=retainer()
    local path={}
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
            local ok; ok,err,where=check_node(read,node,classify,access,retain)
            if not ok then return nil,err,where end
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
    -- Prefer continuing the strip straight: candidates nearest its lateral
    -- centre first (the same centre outward_policy plans from), then nearest.
    local centre=math.floor((c.min+c.max)/2+0.5)
    local order={}
    for n=c.rows+1,c.rows+8 do for shift=-3,3 do order[#order+1]={n=n,shift=shift} end end
    table.sort(order,function(a,b)
        local ka,kb=math.abs(a.shift-centre),math.abs(b.shift-centre)
        if ka~=kb then return ka<kb end
        if a.n~=b.n then return a.n<b.n end
        return a.shift<b.shift
    end)
    for _,cand in ipairs(order) do
        local n,shift=cand.n,cand.shift
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
    end
    return result
end

local function make_endpoint(feet,c,option,extra)
    local connector={version=1,direction=c.direction,width=c.width,path=c.path,landing=copy(option.landing),
        preserved=c.preserved,transition=option.transition}
    for k,v in pairs(extra or {}) do connector[k]=v end
    return {requested=copy(feet),ground=copy(c.selection),resolved=copy(option.landing),connector=connector}
end

-- Pair every start with its goals, keep the pairs the edge rules can enter and
-- leave at some heading, and reject ambiguous connector continuations.
local function match_pairs(terrain,starts,goals_of,edges,anchor)
    local matches,pairs_checked={},0
    for _,start in ipairs(starts) do
        for _,goal in ipairs(goals_of(start)) do
            pairs_checked=pairs_checked+1
            if pairs_checked>MAX_PAIR_CHECKS then return nil,'connector landing candidate budget exceeded',anchor end
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
    if #matches==0 then return nil,'no lattice-compatible natural connector landing',anchor end
    local first_match=matches[1]
    for i=2,#matches do
        for _,side in ipairs({'start','goal'}) do
            local x,y=first_match[side].connector,matches[i][side].connector
            if x and y and (x.direction.x~=y.direction.x or x.direction.z~=y.direction.z) then
                return nil,'approach has ambiguous usable continuations',first_match[side].ground
            end
        end
    end
    return first_match
end


-- Revalidate a published Towns exit against the current world. Every column of
-- every step must still match the published node exactly. No player position
-- or stair/slab heuristic is involved; the published record is the provenance.
local function face_of(d)
    for _,candidate in ipairs(directions) do
        if candidate.x==d.x and candidate.z==d.z then return candidate end
    end
end

local function inspect_exit(read,desc,classify,access)
    local d,a=face_of(desc.direction),desc.anchor
    local lateral={x=-d.z,z=d.x}
    local min,max=desc.offsets.min,desc.offsets.max
    local retain,preserved=retainer()
    local path={}
    local previous,selection
    for n=0,desc.length-1 do
        local entry=desc.profile[n+1]
        local x,z=a.x+n*d.x,a.z+n*d.z
        local first
        for off=min,max do
            local p={x=x+lateral.x*off,y=entry.y,z=z+lateral.z*off}
            local node,why=read(p); if not node then return nil,why,p end
            if node.name~=entry.name or node.param2~=entry.param2 then
                return nil,'published exit node changed',node
            end
            local ok,err,where=check_node(read,node,classify,access,retain)
            if not ok then return nil,err,where end
            first=first or node
            if n==0 and off==0 then selection=node end
        end
        local h1,h2=surface_height(first,d,-1),surface_height(first,d,1)
        if not h1 or (previous and math.abs(h1-previous)>0.5) then
            return nil,'approach has an unsafe or unsupported step',first
        end
        path[#path+1]={x=x-0.25*d.x,y=h1,z=z-0.25*d.z}
        path[#path+1]={x=x+0.25*d.x,y=h2,z=z+0.25*d.z}
        previous=h2
    end
    return {direction={x=d.x,z=d.z},width=max-min+1,path=path,preserved=preserved,
        rows=desc.length,last_height=previous,selection=selection,min=min,max=max,lateral=lateral}
end

local function integral(n) return type(n)=='number' and n==math.floor(n) and math.abs(n)<=31000 end
local function valid_descriptor(desc)
    if type(desc)~='table' or type(desc.direction)~='table' or type(desc.anchor)~='table'
        or type(desc.offsets)~='table' or type(desc.profile)~='table' then return false end
    if not face_of(desc.direction) then return false end
    for _,axis in ipairs({'x','y','z'}) do if not integral(desc.anchor[axis]) then return false end end
    local o=desc.offsets
    if not integral(o.min) or not integral(o.max) or o.min>0 or o.max<0 then return false end
    local width=o.max-o.min+1
    if width~=2 and width~=4 then return false end
    if not integral(desc.length) or desc.length<1 or desc.length>16 or #desc.profile~=desc.length then return false end
    for _,entry in ipairs(desc.profile) do
        if type(entry)~='table' or not integral(entry.y) or type(entry.name)~='string'
            or not integral(entry.param2) then return false end
    end
    return desc.profile[1].y==desc.anchor.y
end

local function inside(rect,x,z)
    return type(rect)=='table' and x>=rect.x1 and x<=rect.x2 and z>=rect.z1 and z<=rect.z2
end

local function inside_any(rects,x,z)
    if type(rects)~='table' then return false end
    for _,r in ipairs(rects) do if inside(r,x,z) then return true end end
    return false
end

-- Resolve a published exit and a caller-supplied target without any player.
-- descriptor: see towns_adapter.exit. target is an integer {x,z}. The optional
-- descriptor.footprint list of rects (x1,z1,x2,z2: the core and outskirts
-- structures) keeps goals outside the source settlement; the unbuilt
-- reservation belt around it is allowed. Never emerges or generates terrain.
function connectors.exit_endpoints(terrain,desc,target,access,load,surface,edges)
    if type(access)~='table' or type(load)~='function' then return fail('connector inspection is unavailable') end
    if not valid_descriptor(desc) then return fail('invalid published exit descriptor') end
    if type(target)~='table' or not integral(target.x) or not integral(target.z) then
        return fail('invalid target position')
    end
    if inside_any(desc.footprint,target.x,target.z) then return fail('target inside source settlement') end
    local read=reader(terrain,access,load)
    local c,why,where=inspect_exit(read,desc,surface.classify,access)
    if not c then return fail(why,where) end
    local feet={x=desc.anchor.x,y=c.path[2].y,z=desc.anchor.z}
    local dx,dz=target.x-feet.x,target.z-feet.z
    if dx*dx+dz*dz>192*192 then return fail('requested endpoints exceed 192 nodes') end
    local col=terrain.get_column(target.x,target.z)
    if type(col)~='table' or col.status~='ok' then return fail('invalid requested goal ground',target) end
    local bg=surface.ground(terrain,{x=target.x,y=col.ground_y+0.5,z=target.z})
    if not bg then return fail('invalid requested goal ground',target) end
    local goal_feet={x=target.x,y=bg.y+0.5,z=target.z}
    local starts={}
    local origin={origin='published_exit',offsets={min=c.min,max=c.max},
        exit={api_version=desc.api_version,settlement_id=desc.settlement_id,exit_id=desc.exit_id,source=desc.source}}
    for _,o in ipairs(landing_options(terrain,c)) do starts[#starts+1]=make_endpoint(feet,c,o,origin) end
    local matches,reason,position=match_pairs(terrain,starts,function(start)
        local x=start.resolved.x+4*round((goal_feet.x-start.resolved.x)/4)
        local z=start.resolved.z+4*round((goal_feet.z-start.resolved.z)/4)
        local snapped=terrain.get_column(x,z)
        if snapped and snapped.status=='ok' and (goal_feet.x-x)^2+(goal_feet.z-z)^2<=9
            and math.abs(snapped.ground_y-bg.y)<=2 and not inside_any(desc.footprint,x,z) then
            return {{requested=copy(goal_feet),ground=bg,resolved={x=x,y=snapped.ground_y,z=z}}}
        end
        return {}
    end,edges,c.selection)
    if not matches then return fail(reason,position) end
    return matches
end

-- Heading indices follow edges.lua: 0=(1,0) 1=(1,1) 2=(0,1) 3=(-1,1) 4=(-1,0) 5=(-1,-1) 6=(0,-1) 7=(1,-1).
local HEADINGS={{1,0},{1,1},{0,1},{-1,1},{-1,0},{-1,-1},{0,-1},{1,-1}}

-- Final headings that face into the town: opposite the published outward
-- vector, plus its two 45-degree neighbours (the one allowed final bend).
function connectors.arrival_headings(direction)
    for i,h in ipairs(HEADINGS) do
        if h[1]==-direction.x and h[2]==-direction.z then
            local result={(i-2)%8,i-1,i%8}
            table.sort(result)
            return result
        end
    end
end

local WIDE={min_x=-31000,max_x=31000,min_y=-31000,max_y=31000,min_z=-31000,max_z=31000}

-- Re-read a published exit from the world: every node must match its profile,
-- stay unprotected and free of metadata, and keep support, headroom and
-- daylight. Used immediately before construction; never emerges terrain.
-- env = {access, load, classify, owner}.
function connectors.inspect_published_exit(desc,env)
    if type(env)~='table' or type(env.access)~='table' or type(env.load)~='function'
        or type(env.classify)~='function' then return fail('connector inspection is unavailable') end
    if not valid_descriptor(desc) then return fail('invalid published exit descriptor') end
    local read=reader({bounds=WIDE,owner=env.owner},env.access,env.load)
    local c,why,where=inspect_exit(read,desc,env.classify,env.access)
    if not c then return fail(why,where) end
    return c
end

-- The arrival side of a published exit for a growth road ending at `start`
-- (a seam endpoint {x,y,z}): inspect the built exit, choose a natural landing
-- on the start's four-node lattice outside the destination footprint, build the
-- same transition and landing cap the outward side uses, and require that the
-- final edge can enter the landing heading into the town (opposite the
-- published outward vector, at most one 45-degree final bend). Returns
-- {goal=<endpoint with connector>, headings={...}} or nil, error.
function connectors.exit_goal(terrain,desc,start,access,load,surface,edges)
    if type(access)~='table' or type(load)~='function' then return fail('connector inspection is unavailable') end
    if not valid_descriptor(desc) then return fail('invalid published exit descriptor') end
    if type(start)~='table' or not integral(start.x) or not integral(start.y) or not integral(start.z) then
        return fail('invalid growth endpoint')
    end
    local d=face_of(desc.direction)
    local dx,dz=desc.anchor.x-start.x,desc.anchor.z-start.z
    if dx*dx+dz*dz>192*192 then return fail('requested endpoints exceed 192 nodes') end
    -- The landing lies beyond the strip's seam row; arriving heading into the
    -- town needs the road on that outward side with room for one lattice edge.
    local along=(start.x-desc.anchor.x)*d.x+(start.z-desc.anchor.z)*d.z
    if along<desc.length+5 then
        return nil,{code='incompatible_heading',position={x=desc.anchor.x,y=desc.anchor.y,z=desc.anchor.z},
            reason='the exit faces away from the road or lies beside it; no supported arrival heading into the town'}
    end
    local read=reader(terrain,access,load)
    local c,why,where=inspect_exit(read,desc,surface.classify,access)
    if not c then return fail(why,where) end
    local feet={x=desc.anchor.x,y=c.path[2].y,z=desc.anchor.z}
    local origin={origin='published_exit',offsets={min=c.min,max=c.max},
        exit={api_version=desc.api_version,settlement_id=desc.settlement_id,exit_id=desc.exit_id,source=desc.source}}
    local headings=connectors.arrival_headings(desc.direction)
    local options=landing_options(terrain,c,start)
    if #options==0 then return fail('no lattice-compatible natural connector landing',c.selection) end
    local reason,position='no supported landing fits',c.selection
    for _,option in ipairs(options) do
        local inside=inside_any(desc.footprint,option.landing.x,option.landing.z)
        for _,p in ipairs(option.transition.surfaces) do
            if inside_any(desc.footprint,p.x,p.z) then inside=true; position=p end
        end
        if inside then
            reason='the landing or its transition lies inside the destination footprint'
        else
            local goal=make_endpoint(feet,c,option,origin)
            local constraints,constraint_reason=edges.connector_constraints({goal=goal})
            if not constraints then
                reason=constraint_reason
            else
                for _,h in ipairs(headings) do
                    local dir=HEADINGS[h+1]
                    local edge=edges.evaluate(terrain,option.landing,{i=-dir[1],j=-dir[2]},h,
                        {road_material=full,constraints=constraints})
                    if edge.ok then return {goal=goal,headings=headings} end
                    reason='no final edge can arrive heading into the town: '..tostring(edge.reason)
                    position=edge.position or position
                end
            end
        end
    end
    return fail(reason,position)
end

-- Walk the finished road onto the built exit, in the walking direction, against
-- the live world. The exact preserved exit nodes must be unchanged, every
-- sampled road and transition node must be a road block with clear headroom and
-- solid support, every step must be walkable, and the road must end at the
-- landing heading into the town. env = {access, load, classify, has_timer,
-- raster, owner}. Returns true or nil, {code, reason, position}.
function connectors.verify_arrival(plan,env)
    local function bad(reason,p)
        return nil,{code='attachment_unverified',reason=reason,position=p and {x=p.x,y=p.y,z=p.z} or nil}
    end
    if type(plan)~='table' or plan.version~=3 or type(plan.request)~='table' or type(env)~='table'
        or type(env.raster)~='table' or type(env.has_timer)~='function' or type(env.classify)~='function'
        or type(env.access)~='table' or type(env.load)~='function' then return bad('arrival inspection is unavailable') end
    local goal=plan.endpoints and plan.endpoints.goal
    local c=goal and goal.connector
    local attach=plan.request.goal_attachment
    if type(c)~='table' or c.origin~='published_exit' or type(attach)~='table' or type(attach.headings)~='table'
        or type(c.transition)~='table' or type(c.path)~='table' or type(c.preserved)~='table'
        or type(plan.centerline)~='table' or type(plan.headings)~='table' then
        return bad('the plan has no published-exit arrival')
    end
    local last=plan.centerline[#plan.centerline]
    if not last or last.x~=c.landing.x or last.y~=c.landing.y or last.z~=c.landing.z then
        return bad('the road does not end at the exit landing',last)
    end
    local final=plan.headings[#plan.headings]
    local allowed=false
    for _,h in ipairs(attach.headings) do if h==final then allowed=true end end
    if not allowed then return bad('the final heading does not face into the town') end
    local read=reader({bounds=WIDE,owner=env.owner},env.access,env.load)
    for _,p in ipairs(c.preserved) do
        local node,why=read(p)
        if not node then return bad(why,p) end
        if node.name~=p.name or node.param2~=p.param2 or node.has_metadata or node.protected then
            return bad('a preserved exit node changed',p)
        end
        local ok,timer=pcall(env.has_timer,p)
        if not ok or timer~=false then return bad('a preserved exit node has a timer or an unknown timer state',p) end
    end
    local function road_node(x,y,z)
        local node,why=read({x=x,y=y,z=z})
        if not node then return nil,why end
        if node.name~=full or node.param2~=0 or node.has_metadata then return nil,'the walking surface is not a plain road block' end
        for dy=1,3 do
            local air,why2=read({x=x,y=y+dy,z=z})
            if not air then return nil,why2 end
            if air.name~='air' then return nil,'the walking path lacks three clear nodes' end
        end
        local below,why3=read({x=x,y=y-1,z=z})
        if not below then return nil,why3 end
        local kind=below.name~='air' and env.classify({name=below.name,param2=below.param2},below.has_metadata)
        if not kind or kind.kind~='natural' then return nil,'the walking surface has no solid support' end
        return true
    end
    local surfaces={}
    for i=1,#plan.centerline-1 do
        local edge=env.raster.segment(plan.centerline[i],plan.centerline[i+1])
        if not edge then return bad('the road geometry cannot be rasterized',plan.centerline[i]) end
        for _,p in ipairs(edge.columns) do surfaces[p.x..':'..p.z]=p.y end
    end
    local walk={}
    -- A step may rise at most `rise`; consecutive samples are at most `reach` apart (squared).
    local function step(x,y,z,rise,reach,where)
        local previous=walk[#walk]
        if previous and (math.abs(y-previous.y)>rise+1e-9 or (x-previous.x)^2+(z-previous.z)^2>reach) then
            return bad(where,{x=x,y=y,z=z})
        end
        walk[#walk+1]={x=x,y=y,z=z}
        return true
    end
    -- The road: each lattice step is sampled at every node along it.
    for i=1,#plan.centerline-1 do
        local a,b=plan.centerline[i],plan.centerline[i+1]
        for t=0,3 do
            local x,z=a.x+t*(b.x-a.x)/4,a.z+t*(b.z-a.z)/4
            local y=surfaces[x..':'..z]
            if y==nil then return bad('a road sample lies outside the swept footprint',{x=x,y=a.y,z=z}) end
            local ok,why=road_node(x,y,z); if not ok then return bad(why,{x=x,y=y,z=z}) end
            local stepped,err=step(x,y+0.5,z,1,2.0001,'the road is not a connected walking path')
            if not stepped then return nil,err end
        end
    end
    local ok,why=road_node(last.x,last.y,last.z); if not ok then return bad(why,last) end
    local stepped,err=step(last.x,last.y+0.5,last.z,1,2.0001,'the road is not a connected walking path')
    if not stepped then return nil,err end
    for _,p in ipairs(c.transition.surfaces) do
        ok,why=road_node(p.x,p.y,p.z); if not ok then return bad(why,p) end
    end
    -- The transition from the landing to the seam row, then the exit from its last row to its first.
    for i=#c.transition.path,1,-1 do
        local p=c.transition.path[i]
        if p.y-0.5~=c.landing.y then return bad('the transition is not flat',p) end
        stepped,err=step(p.x,p.y,p.z,0.5,1.0001,'the transition is not a connected walking path')
        if not stepped then return nil,err end
    end
    for i=#c.path,1,-1 do
        local p=c.path[i]
        stepped,err=step(p.x,p.y,p.z,0.5,1.5626,'the exit is not a connected walking path')
        if not stepped then return nil,err end
    end
    return true
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
    local matches,why,where=match_pairs(terrain,starts,function(start)
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
        return goals
    end,edges,a or b)
    if not matches then return fail(why,where) end
    return matches
end

return connectors
