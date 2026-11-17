-- SPDX-License-Identifier: GPL-3.0-or-later
-- Bounded owner-only particle preview sampling, independent of world writes.
local preview={}
local MAX_CENTERLINE=100000
local MAX_PARTICLES=96
local MAX_CONNECTOR_POINTS=512
local SPACING=2.5
local EXPIRY=30
local RATE_LIMIT=8
local COORD_LIMIT=31000

local function finite(n)
    return type(n)=="number" and n==n and n~=math.huge and n~=-math.huge
end

function preview.sample(centerline)
    if type(centerline)~="table" or #centerline<2 or #centerline>MAX_CENTERLINE then
        return nil,{code="invalid_route",reason="route geometry is missing or exceeds preview limits"}
    end
    local lengths,total={},0
    for i=1,#centerline do
        local p=centerline[i]
        if type(p)~="table" or not finite(p.x) or not finite(p.y) or not finite(p.z)
            or p.x~=math.floor(p.x) or p.y~=math.floor(p.y) or p.z~=math.floor(p.z)
            or math.abs(p.x)>COORD_LIMIT or math.abs(p.y)>COORD_LIMIT or math.abs(p.z)>COORD_LIMIT then
            return nil,{code="invalid_route",reason="route contains an invalid coordinate"}
        end
        if i>1 then
            local prev=centerline[i-1]
            local d=math.sqrt((p.x-prev.x)^2+(p.y-prev.y)^2+(p.z-prev.z)^2)
            -- Planner centerline edges connect four-node lattice points. A
            -- diagonal can therefore span four nodes on each horizontal axis.
            if d==0 or math.abs(p.x-prev.x)>4 or math.abs(p.y-prev.y)>1
                or math.abs(p.z-prev.z)>4 then
                return nil,{code="invalid_route",reason="route contains an invalid step"}
            end
            lengths[i]=d; total=total+d
        end
    end
    local count=math.min(MAX_PARTICLES,math.floor(total/SPACING)+2)
    if count<2 then count=2 end
    local points={}
    local segment=2
    local traversed=0
    for sample=0,count-1 do
        local distance=total*sample/(count-1)
        while segment<#centerline and traversed+lengths[segment]<distance do
            traversed=traversed+lengths[segment]
            segment=segment+1
        end
        local a,b=centerline[segment-1],centerline[segment]
        local d=lengths[segment]
        local t=math.max(0,math.min(1,(distance-traversed)/d))
        -- Node coordinates denote block centers; lift above the maximum
        -- two-node natural-ground cut accepted by the planner, with margin
        -- for the planner's linearly interpolated, rounded road profile.
        points[#points+1]={x=a.x+(b.x-a.x)*t,
            y=a.y+(b.y-a.y)*t+3.5,z=a.z+(b.z-a.z)*t}
    end
    return points
end

-- Connector coordinates are walking samples, so half-node and fractional
-- elevations are expected. Keep their validation and particle budget separate
-- from the planner's integer lattice centerline.
local function sample_connector(line)
    if type(line)~="table" or #line<1 or #line>MAX_CONNECTOR_POINTS then
        return nil,{code="invalid_route",reason="connector geometry is missing or exceeds preview limits"}
    end
    local total,lengths=0,{}
    for i,p in ipairs(line) do
        if type(p)~="table" or not finite(p.x) or not finite(p.y) or not finite(p.z)
            or math.abs(p.x)>COORD_LIMIT or math.abs(p.y)>COORD_LIMIT or math.abs(p.z)>COORD_LIMIT then
            return nil,{code="invalid_route",reason="connector contains an invalid coordinate"}
        end
        if i>1 then
            local q=line[i-1]
            local dx,dy,dz=p.x-q.x,p.y-q.y,p.z-q.z
            local d=math.sqrt(dx*dx+dy*dy+dz*dz)
            if d==0 or d>2 or math.abs(dx)>1 or math.abs(dz)>1 or math.abs(dy)>0.5 then
                return nil,{code="invalid_route",reason="connector contains an invalid step"}
            end
            lengths[i]=d; total=total+d
        end
    end
    local n=math.max(2,math.min(MAX_PARTICLES,math.floor(total/SPACING)+2))
    local points={}
    if #line==1 or total==0 then
        local p=line[1]; points[1]={x=p.x,y=p.y+3,z=p.z}; return points
    end
    local segment,traversed=2,0
    for j=0,n-1 do
        local distance=total*j/(n-1)
        while segment<#line and traversed+lengths[segment]<distance do
            traversed=traversed+lengths[segment]; segment=segment+1
        end
        local a,b=line[segment-1],line[segment]
        local t=math.max(0,math.min(1,(distance-traversed)/lengths[segment]))
        points[#points+1]={x=a.x+(b.x-a.x)*t,y=a.y+(b.y-a.y)*t+3,z=a.z+(b.z-a.z)*t}
    end
    return points
end

local function connector_lines(endpoints)
    local preserved,transition={},{}
    if endpoints==nil then return preserved,transition end
    if type(endpoints)~="table" then return nil,nil,{code="invalid_route",reason="connector endpoints are malformed"} end
    for _,key in ipairs({"start","goal"}) do
        local endpoint=endpoints[key]
        local c=type(endpoint)=="table" and endpoint.connector or nil
        if c~=nil then
            if type(c)~="table" or c.version~=1 or type(c.path)~="table"
                or type(c.transition)~="table" or type(c.transition.path)~="table" then
                return nil,nil,{code="invalid_route",reason="connector geometry is malformed"}
            end
            preserved[#preserved+1]=c.path
            local line={c.path[#c.path]}
            for _,p in ipairs(c.transition.path) do line[#line+1]=p end
            transition[#transition+1]=line
        end
    end
    return preserved,transition
end

function preview.new(engine,now)
    if type(engine)~="table" or type(engine.add_particle)~="function" or type(now)~="function" then
        return nil,{code="invalid_config",reason="particle renderer is unavailable"}
    end
    local last={}
    local renderer={}
    function renderer:forget(owner) last[owner]=nil end
    function renderer:show(owner,centerline,endpoints)
        if type(owner)~="string" or owner=="" then
            return nil,{code="invalid_owner",reason="a player is required to preview a route"}
        end
        local time=now()
        if not finite(time) then return nil,{code="preview_failed",reason="preview clock is unavailable"} end
        if last[owner] and time-last[owner]<RATE_LIMIT then
            return nil,{code="rate_limited",reason="wait before requesting another preview"}
        end
        local points,err=preview.sample(centerline)
        if not points then return nil,err end
        local preserved,transitions,connector_error=connector_lines(endpoints)
        if connector_error then return nil,connector_error end
        local groups={{points=points,color="^[colorize:#fff35c:180"}}
        for _,line in ipairs(preserved) do
            local sampled; sampled,err=sample_connector(line); if not sampled then return nil,err end
            groups[#groups+1]={points=sampled,color="^[colorize:#55e6ff:200"}
        end
        for _,line in ipairs(transitions) do
            local sampled; sampled,err=sample_connector(line); if not sampled then return nil,err end
            groups[#groups+1]={points=sampled,color="^[colorize:#ff9f43:200"}
        end
        local total=0
        for _,group in ipairs(groups) do group.quota=#group.points; total=total+group.quota end
        -- Share the budget while retaining both ends of every walking segment.
        -- Sampling a long road must never crowd its connector out of the preview.
        while total>MAX_PARTICLES do
            local largest=groups[1]
            for _,group in ipairs(groups) do if group.quota>largest.quota then largest=group end end
            largest.quota=largest.quota-1; total=total-1
        end
        for _,group in ipairs(groups) do
            local selected={}
            for i=1,group.quota do
                local index=group.quota==1 and 1 or math.floor((i-1)*(#group.points-1)/(group.quota-1)+1.5)
                selected[i]=group.points[index]
            end
            group.points=selected
        end
        last[owner]=time
        for _,group in ipairs(groups) do for _,pos in ipairs(group.points) do
            local ok,why=pcall(engine.add_particle,{
                pos=pos,velocity={x=0,y=0,z=0},acceleration={x=0,y=0,z=0},
                -- Particle sizes use engine units: 10 units span one node.
                -- A large glowing marker is visible against varied terrain.
                expirationtime=EXPIRY,size=8,glow=14,collisiondetection=false,
                texture="roads_preview.png"..group.color,playername=owner,
            })
            if not ok then return nil,{code="preview_failed",reason="could not create route preview: "..tostring(why)} end
        end end
        return total
    end
    return renderer
end

preview.MAX_PARTICLES=MAX_PARTICLES
preview.EXPIRY=EXPIRY
preview.RATE_LIMIT=RATE_LIMIT
return preview
