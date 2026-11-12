-- SPDX-License-Identifier: GPL-3.0-or-later
-- Read-only VoxeLibre adapter. No engine calls occur after snapshot creation.
local surface = {}
local classes = {}
local walkable_leaves = {}
local function allow(kind, names)
    for _, name in ipairs(names) do classes[name] = kind end
end
allow("natural", {"mcl_core:stone", "mcl_core:dirt", "mcl_core:dirt_with_grass",
    "mcl_core:dirt_with_grass_snow", "mcl_core:podzol", "mcl_core:redsand",
    "mcl_core:sand", "mcl_core:gravel", "mcl_core:clay", "mcl_core:sandstone",
    "mcl_core:granite", "mcl_core:andesite", "mcl_core:diorite", "mcl_core:snowblock",
    "mcl_core:cobble"})
local leaves = {"mcl_core:leaves", "mcl_core:darkleaves", "mcl_core:jungleleaves",
    "mcl_core:acacialeaves", "mcl_core:spruceleaves", "mcl_core:birchleaves",
    "mcl_core:mangroveleaves"}
allow("replaceable", leaves)
for _, name in ipairs(leaves) do walkable_leaves[name] = true end
allow("replaceable", {"mcl_flowers:tallgrass", "mcl_flowers:fern",
    "mcl_flowers:clover", "mcl_flowers:fourleaf_clover", "mcl_core:deadbush"})
allow("water", {"mcl_core:water_source", "mcl_core:water_flowing"})
classes.air = "air"

function surface.classify(node, metadata)
    if not node or not node.name or node.name == "ignore" or metadata == nil then
        return {kind="unknown"}
    end
    if metadata then return {kind="obstacle", material=node.name} end
    local kind = classes[node.name] or "obstacle"
    return {kind=kind, material=kind ~= "air" and node.name or nil}
end

-- Metadata is rejected even on otherwise recognized natural materials.
function surface.engine_access(engine)
    return {
        get_node = function(pos) return engine.get_node_or_nil(pos) end,
        has_metadata = function(pos)
            local data = engine.get_meta(pos):to_table()
            if not data then return nil end
            return (data.fields and next(data.fields) ~= nil) or
                (data.inventory and next(data.inventory) ~= nil) or false
        end,
        is_protected = function(pos, owner) return engine.is_protected(pos, owner) end,
        get_natural_light = function(pos, time) return engine.get_natural_light(pos, time) end,
    }
end

local function integer(n) return type(n) == "number" and n == math.floor(n) and math.abs(n) <= 31000 end
local function error_result(code, reason) return nil, {code=code, reason=reason} end

-- access supplies get_node(pos), has_metadata(pos), is_protected(pos, owner),
-- and get_natural_light(pos, time_of_day).
-- All must read only, and report missing/unloaded data as nil. Snapshot memory
-- is proportional to the number of columns, while reads are bounded by volume.
function surface.inspect(bounds, owner, access)
    if type(bounds) ~= "table" or type(owner) ~= "string" or type(access) ~= "table"
        or type(access.get_node) ~= "function" or type(access.has_metadata) ~= "function"
        or type(access.is_protected) ~= "function" or type(access.get_natural_light) ~= "function" then
        return error_result("invalid_config", "missing bounds, owner, or read functions")
    end
    for _, key in ipairs({"min_x", "max_x", "min_y", "max_y", "min_z", "max_z"}) do
        if not integer(bounds[key]) then return error_result("invalid_config", "invalid bounds") end
    end
    local nx, ny, nz = bounds.max_x-bounds.min_x+1, bounds.max_y-bounds.min_y+1, bounds.max_z-bounds.min_z+1
    if nx <= 0 or ny <= 0 or nz <= 0 or nx * ny * nz > 2000000 then
        return error_result("survey_budget", "invalid or oversized inspection window")
    end
    local b = {}; for k,v in pairs(bounds) do b[k] = v end
    local columns = {}
    for x = b.min_x, b.max_x do
        for z = b.min_z, b.max_z do
            local nodes, ground, blocked, unknown = {}, nil, nil, false
            for y = b.max_y, b.min_y, -1 do
                local pos = {x=x,y=y,z=z}
                local node = access.get_node(pos)
                local metadata
                if node then metadata = access.has_metadata(pos) end
                local entry = surface.classify(node, metadata)
                nodes[y] = entry
                if entry.kind == "unknown" then unknown = true end
                if not ground then
                    if entry.kind == "natural" then ground = y
                    elseif entry.kind == "water" then blocked = blocked or "water"
                    elseif entry.kind == "obstacle" then blocked = blocked or "structure" end
                end
            end
            local col
            local daylight_ok, daylight = pcall(access.get_natural_light, {x=x,y=b.max_y,z=z}, 0.5)
            if unknown or nodes[b.max_y].kind ~= "air" or not daylight_ok or daylight ~= 15 then
                col = {status="unknown", reason="outdoor daylight unavailable"}
            elseif not ground or ground-3 < b.min_y or ground+5 > b.max_y then
                col = {status="unknown", reason="incomplete or clipped surface window"}
            elseif blocked then col = {status=blocked, reason="obstruction above ground"}
            else
                local band = {}
                for offset = -3, 5 do
                    local y = ground + offset
                    local entry = nodes[y]
                    local protected = access.is_protected({x=x,y=y,z=z}, owner)
                    if type(protected) ~= "boolean" then entry = {kind="unknown"}; protected = false end
                    band[offset] = {kind=entry.kind, material=entry.material, protected=protected}
                end
                col = {status="ok", ground_y=ground, material=nodes[ground].material, band=band}
            end
            columns[x .. ":" .. z] = col
        end
    end
    return {version=1, bounds=b, owner=owner, get_column=function(x,z)
        if x < b.min_x or x > b.max_x or z < b.min_z or z > b.max_z then return {status="outside"} end
        return columns[x .. ":" .. z] or {status="unknown", reason="missing column"}
    end}
end

-- Engine player reference position is converted using its actual collision box.
function surface.player_feet(player)
    local pos, props = player:get_pos(), player:get_properties()
    if not pos or not props or not props.collisionbox or type(props.collisionbox[2]) ~= "number" then return nil end
    return {x=pos.x, y=pos.y + props.collisionbox[2], z=pos.z}
end

local function round(v) return math.floor(v + 0.5) end
local function distance(a,b) return math.sqrt((a.x-b.x)^2 + (a.z-b.z)^2) end
local function ground(snapshot, feet)
    if type(feet) ~= "table" or type(feet.x) ~= "number" or type(feet.y) ~= "number" or type(feet.z) ~= "number" then return nil end
    local x,z = round(feet.x),round(feet.z)
    local col = snapshot.get_column(x,z)
    if col.status ~= "ok" or math.abs(feet.y - (col.ground_y+0.5)) > 0.5 then return nil end
    -- VoxeLibre leaves are full walkable blocks; tallgrass and the other
    -- explicitly allowed small plants are nonwalkable and do not support feet.
    if walkable_leaves[col.band[1].material] then return nil end
    return {x=x,y=col.ground_y,z=z}
end
function surface.endpoints(snapshot, first, second)
    local a,b = ground(snapshot,first),ground(snapshot,second)
    if not a or not b or distance(first, second) > 192 then return error_result("invalid_endpoint", "invalid requested ground") end
    local x,z = a.x+4*round((second.x-a.x)/4), a.z+4*round((second.z-a.z)/4)
    local col = snapshot.get_column(x,z)
    if col.status ~= "ok" or distance(second, {x=x,z=z}) > 3 or math.abs(col.ground_y-b.y) > 2 then
        return error_result("invalid_endpoint", "invalid snapped ground")
    end
    local resolved = {x=x,y=col.ground_y,z=z}
    if distance(a,resolved) == 0 or distance(a,resolved) > 192 then return error_result("invalid_endpoint", "invalid resolved distance") end
    local function copy(p) return {x=p.x,y=p.y,z=p.z} end
    return {start={requested=copy(first),ground=a,resolved=copy(a)},
        goal={requested=copy(second),ground=b,resolved=resolved}}
end
return surface
