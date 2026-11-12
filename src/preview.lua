-- SPDX-License-Identifier: GPL-3.0-or-later
-- Bounded owner-only particle preview sampling, independent of world writes.
local preview={}
local MAX_CENTERLINE=100000
local MAX_PARTICLES=96
local SPACING=2.5
local EXPIRY=8
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

function preview.new(engine,now)
    if type(engine)~="table" or type(engine.add_particle)~="function" or type(now)~="function" then
        return nil,{code="invalid_config",reason="particle renderer is unavailable"}
    end
    local last={}
    local renderer={}
    function renderer:forget(owner) last[owner]=nil end
    function renderer:show(owner,centerline)
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
        last[owner]=time
        for _,pos in ipairs(points) do
            local ok,why=pcall(engine.add_particle,{
                pos=pos,velocity={x=0,y=0,z=0},acceleration={x=0,y=0,z=0},
                expirationtime=EXPIRY,size=0.55,collisiondetection=false,
                texture="default_cobble.png^[opacity:200",playername=owner,
            })
            if not ok then return nil,{code="preview_failed",reason="could not create route preview: "..tostring(why)} end
        end
        return #points
    end
    return renderer
end

preview.MAX_PARTICLES=MAX_PARTICLES
preview.EXPIRY=EXPIRY
preview.RATE_LIMIT=RATE_LIMIT
return preview
