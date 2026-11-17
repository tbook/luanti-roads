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
return fixture
