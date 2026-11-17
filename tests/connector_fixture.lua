-- Deterministic Towns-compatible ramp fixture. Coordinates are relative to
-- the selection; a long cobble street behind it makes the outward suffix
-- the unique bounded continuation.
local fixture={}
function fixture.new(direction,descending,width)
    local overrides={}
    local function key(x,y,z)
        if x==0 then x=0 end; if y==0 then y=0 end; if z==0 then z=0 end
        return x..':'..y..':'..z
    end
    local d=direction or {x=1,z=0,p2=1}; width=width or 2
    local tx,tz=-d.z,d.x
    local function put(n,l,y,name,p2)
        overrides[key(n*d.x+l*tx,y,n*d.z+l*tz)]={name=name,param2=p2 or 0}
    end
    local base=descending and 2 or 0
    for l=0,width-1 do
        for n=-16,0 do put(n,l,descending and 2 or 1,'mcl_core:cobble') end
        if descending then
            put(1,l,2,'mcl_stairs:stair_cobble',(d.p2+2)%4)
            put(2,l,2,'mcl_stairs:slab_cobble')
            put(3,l,1,'mcl_core:cobble')
            put(3,l,2,'air')
        else
            put(1,l,1,'mcl_stairs:stair_cobble',d.p2)
            put(2,l,1,'mcl_core:cobble')
            put(2,l,2,'mcl_stairs:slab_cobble')
            put(3,l,1,'mcl_core:cobble')
            put(3,l,2,'mcl_core:cobble')
        end
    end
    local access={}
    function access.get_node(p)
        local n=p.x*d.x+p.z*d.z
        local y=n>=4 and (descending and 1 or 2) or base
        return overrides[key(p.x,p.y,p.z)] or {name=p.y<=y and 'mcl_core:stone' or 'air',param2=0}
    end
    function access.has_metadata() return false end
    function access.is_protected() return false end
    function access.get_natural_light() return 15 end
    return access,overrides,{x=d.x*0.75,y=descending and 2.5 or 1,z=d.z*0.75},d
end

-- Published-exit fixture: a Towns-style exit at the origin whose nodes follow
-- a profile (as published by towns_api) and whose seam meets natural terrain
-- at seam_y. kind is 'flat', 'down' (stair, slab, descends outward) or 'up'.
-- Returns access, overrides, descriptor, target, direction.
local stair,slab,full='mcl_stairs:stair_cobble','mcl_stairs:slab_cobble','mcl_core:cobble'
function fixture.exit(direction,kind,width)
    local d=direction or {x=1,z=0,p2=1}; width=width or 2; kind=kind or 'flat'
    local profile,seam_y
    if kind=='flat' then
        profile={}; for n=1,6 do profile[n]={y=1,name=full,param2=0} end; seam_y=1
    elseif kind=='down' then
        profile={{y=2,name=full,param2=0},{y=2,name=stair,param2=(d.p2+2)%4},{y=2,name=slab,param2=0}}; seam_y=1
    else
        profile={{y=1,name=stair,param2=d.p2},{y=1,name=full,param2=0},{y=2,name=slab,param2=0}}; seam_y=2
    end
    local L=#profile
    local tx,tz=-d.z,d.x
    local overrides={}
    local function key(x,y,z)
        if x==0 then x=0 end; if y==0 then y=0 end; if z==0 then z=0 end
        return x..':'..y..':'..z
    end
    for n=0,L-1 do for l=0,width-1 do
        local e=profile[n+1]
        overrides[key(n*d.x+l*tx,e.y,n*d.z+l*tz)]={name=e.name,param2=e.param2}
    end end
    local access={}
    function access.get_node(p)
        local n=p.x*d.x+p.z*d.z
        local ground=n>=L and seam_y or profile[math.max(n,0)+1].y-1
        return overrides[key(p.x,p.y,p.z)] or {name=p.y<=ground and 'mcl_core:stone' or 'air',param2=0}
    end
    function access.has_metadata() return false end
    function access.is_protected() return false end
    function access.get_natural_light() return 15 end
    local columns={}
    for l=0,width-1 do columns[#columns+1]={x=l*tx,z=l*tz} end
    local descriptor={api_version=1,settlement_id='auto:0:0',exit_id='fixture',source='street',
        direction={x=d.x,z=d.z},anchor={x=0,y=profile[1].y,z=0},offsets={min=0,max=width-1},
        length=L,profile=profile}
    return access,overrides,descriptor,{x=d.x*(L+20),z=d.z*(L+20)},d
end
return fixture
