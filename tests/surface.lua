local surface = dofile("src/surface.lua")
local count = 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if not ok then error(name .. ": " .. tostring(err)) end
    count = count + 1
end
local bounds = {min_x=-1,max_x=9,min_y=-6,max_y=8,min_z=0,max_z=0}
local overrides, metadata, protection, reads, light = {}, {}, {}, 0, {}
local function key(p) return p.x .. ":" .. p.y .. ":" .. p.z end
local access = {
    get_node = function(p)
        reads = reads + 1
        assert(p.x >= bounds.min_x and p.x <= bounds.max_x and p.y >= bounds.min_y and p.y <= bounds.max_y)
        local name = overrides[key(p)]
        if name == "unloaded" then return nil end
        return {name=name or (p.y <= 0 and "mcl_core:stone" or "air")}
    end,
    has_metadata = function(p) return metadata[key(p)] or false end,
    is_protected = function(p, owner) assert(owner == "alice"); return protection[key(p)] or false end,
    get_natural_light = function(p, time)
        assert(time == 0.5 and p.y == bounds.max_y)
        local value=light[p.x]
        if value == "error" then error("light unavailable") end
        if value == "nil" then return nil end
        return value or 15
    end,
}
local function reset() overrides, metadata, protection, reads, light = {}, {}, {}, 0, {} end
local function snap() return assert(surface.inspect(bounds,"alice",access)) end
local function set(x,y,name) overrides[x .. ":" .. y .. ":0"] = name end
test("full bounded scan, band, protection and stable snapshot", function()
    reset(); protection["1:2:0"] = true
    local s = snap(); assert(reads == 11*15)
    local c=s.get_column(1,0); assert(c.status == "ok" and c.ground_y == 0)
    assert(c.band[-3].kind == "natural" and c.band[5].kind == "air" and c.band[2].protected)
    set(1,1,"mcl_core:water_source"); assert(s.get_column(1,0).status == "ok")
    assert(s.get_column(10,0).status == "outside")
end)
test("canopy and obstruction in excavation band", function()
    reset(); set(1,4,"mcl_core:leaves"); set(1,-1,"mcl_core:glass")
    local c=snap().get_column(1,0)
    assert(c.status == "ok" and c.band[4].kind == "replaceable" and c.band[-1].kind == "obstacle")
end)
test("water, roof, metadata, unknown and unloaded", function()
    reset(); set(0,1,"mcl_core:water_source"); set(1,4,"mcl_core:glass")
    set(2,2,"ignore"); set(3,-4,"unloaded"); metadata["4:0:0"]=true
    local s=snap()
    assert(s.get_column(0,0).status == "water")
    assert(s.get_column(1,0).status == "structure")
    assert(s.get_column(2,0).status == "unknown" and s.get_column(3,0).status == "unknown")
    assert(s.get_column(4,0).status == "structure")
end)
test("clipped scan and headroom", function()
    reset(); for y=1,8 do set(0,y,"mcl_core:stone") end
    for y=-3,0 do set(1,y,"air") end
    set(2,3,"mcl_flowers:tallgrass")
    local s=snap(); assert(s.get_column(0,0).status == "unknown")
    assert(s.get_column(1,0).status == "unknown")
    assert(s.get_column(2,0).band[3].kind == "replaceable")
end)
test("endpoint checks requested and snapped independently", function()
    reset(); local s=snap()
    local p=assert(surface.endpoints(s,{x=0,y=0.5,z=0},{x=5,y=0.5,z=0}))
    assert(p.goal.ground.x == 5 and p.goal.resolved.x == 4)
    assert(not surface.endpoints(s,{x=0,y=3,z=0},{x=5,y=.5,z=0}))
    assert(not surface.endpoints(s,{x=0,y=-2,z=0},{x=5,y=.5,z=0}))
    assert(not surface.endpoints(s,{x=0,y=.5,z=0},{x=1,y=.5,z=0}))
    set(4,1,"mcl_core:water_source"); s=snap()
    assert(not surface.endpoints(s,{x=0,y=.5,z=0},{x=5,y=.5,z=0}))
end)
test("player feet from collision box", function()
    local p={get_pos=function() return {x=1,y=4,z=2} end,
        get_properties=function() return {collisionbox={-0.3,-1,-0.3,0.3,0.8,0.3}} end}
    assert(surface.player_feet(p).y == 3)
end)
test("nonwalkable grass permits endpoints; walkable leaves reject them", function()
    reset(); set(0,1,"mcl_flowers:tallgrass")
    local s=snap()
    assert(surface.endpoints(s,{x=0,y=.5,z=0},{x=5,y=.5,z=0}))
    set(0,1,"mcl_core:leaves"); s=snap()
    assert(not surface.endpoints(s,{x=0,y=.5,z=0},{x=5,y=.5,z=0}))
end)
test("ordinary flowers allow routing but retain metadata and protection", function()
    reset(); set(0,1,"mcl_flowers:poppy"); set(1,1,"mcl_flowers:dandelion")
    set(2,1,"mcl_flowers:tulip_red"); protection["0:1:0"]=true; metadata["1:1:0"]=true
    local s=snap(); local poppy=s.get_column(0,0)
    assert(poppy.status=="ok" and poppy.band[1].kind=="replaceable" and poppy.band[1].protected)
    assert(s.get_column(1,0).status=="structure")
    assert(s.get_column(2,0).band[1].kind=="replaceable")
    assert(surface.endpoints(s,{x=0,y=.5,z=0},{x=5,y=.5,z=0}))
    assert(surface.classify({name="mcl_core:tree"},false).kind=="obstacle")
    assert(surface.classify({name="mcl_flowerpots:flower_pot"},false).kind=="obstacle")
end)
test("thin snow permits endpoint selection while retaining metadata and protection", function()
    reset(); set(0,0,"mcl_core:dirt_with_grass_snow"); set(0,1,"mcl_core:snow")
    set(1,1,"mcl_core:snow"); metadata["1:1:0"]=true
    set(2,1,"mcl_core:snow"); protection["2:1:0"]=true
    set(3,1,"mcl_core:snow_2")
    local s=snap()
    assert(s.get_column(0,0).status=="ok" and s.get_column(0,0).band[1].kind=="replaceable")
    assert(surface.endpoints(s,{x=0,y=.5,z=0},{x=5,y=.5,z=0}))
    assert(s.get_column(1,0).status=="structure")
    assert(s.get_column(2,0).band[1].protected)
    assert(s.get_column(3,0).status=="structure")
end)
test("natural decorations and exposed ores retain their protections", function()
    reset(); set(0,1,"mcl_core:vine"); set(1,1,"mcl_mushrooms:mushroom_brown")
    set(2,1,"mcl_mushrooms:mushroom_red"); set(3,0,"mcl_core:stone_with_coal")
    set(4,0,"mcl_copper:stone_with_copper"); metadata["1:1:0"]=true; protection["3:0:0"]=true
    local s=snap()
    assert(s.get_column(0,0).band[1].kind=="replaceable")
    assert(s.get_column(1,0).status=="structure" and s.get_column(2,0).band[1].kind=="replaceable")
    assert(s.get_column(3,0).material=="mcl_core:stone_with_coal" and s.get_column(3,0).band[0].protected)
    assert(s.get_column(4,0).material=="mcl_copper:stone_with_copper")
    assert(surface.classify({name="mcl_core:stone_with_coal"},true).kind=="obstacle")
    assert(surface.classify({name="mcl_farming:wheat_8"},false).kind=="obstacle")
end)
test("explicit classification and engine read adapter", function()
    assert(surface.classify({name="other:stone"},false).kind == "obstacle")
    assert(surface.classify({name="mcl_core:stone"},true).kind == "obstacle")
    local engine={get_node_or_nil=function() return {name="air"} end,
        get_meta=function() return {to_table=function() return {fields={},inventory={}} end} end,
        is_protected=function() return false end,
        get_natural_light=function(_, time) assert(time == .5); return 0 end,
        get_node_light=function() return 15 end}
    local a=surface.engine_access(engine); assert(a.has_metadata({}) == false)
    assert(a.get_natural_light({}, .5) == 0)
end)
test("noon natural daylight distinguishes open sky from dark or unavailable", function()
    reset(); set(1,4,"mcl_core:leaves")
    light[2]=0; light[3]=14; light[4]="nil"; light[5]="error"
    set(6,8,"mcl_core:leaves")
    local s=snap()
    assert(s.get_column(0,0).status == "ok" and s.get_column(1,0).status == "ok")
    for x=2,6 do assert(s.get_column(x,0).status == "unknown") end
end)
test("VoxeLibre biome surface materials are natural and retain identity", function()
    reset()
    for x, name in ipairs({"mcl_core:dirt_with_grass_snow", "mcl_core:podzol", "mcl_core:redsand"}) do
        set(x,0,name)
    end
    local s=snap()
    for x, name in ipairs({"mcl_core:dirt_with_grass_snow", "mcl_core:podzol", "mcl_core:redsand"}) do
        local col=s.get_column(x,0)
        assert(col.status == "ok" and col.ground_y == 0 and col.material == name)
        assert(col.band[0].kind == "natural" and col.band[0].material == name)
        assert(surface.classify({name=name},true).kind == "obstacle")
    end
end)
print("ok - " .. count .. " surface inspection tests")
