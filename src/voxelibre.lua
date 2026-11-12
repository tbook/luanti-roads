-- SPDX-License-Identifier: GPL-3.0-or-later
-- Read-only VoxeLibre world configuration for the supported route survey.
local voxelibre={}
local function integer(n)
    return type(n)=="number" and n==n and n~=math.huge and n~=-math.huge
        and n==math.floor(n)
end
local function failure(reason)
    return nil,{code="unsupported_world",reason=reason}
end

function voxelibre.world_config(engine,vars,engine_limit)
    engine_limit=engine_limit or 31000
    if type(engine)~="table" or type(engine.get_mapgen_setting)~="function" or type(vars)~="table" then
        return failure("VoxeLibre mapgen settings are unavailable")
    end
    if not integer(engine_limit) or engine_limit<1 then return failure("Luanti coordinate limit is invalid") end
    local required={"chunksize","central_chunk_offset_in_nodes","chunk_size_in_nodes",
        "mapgen_edge_min","mapgen_edge_max","mg_overworld_min","mg_overworld_max",
        "mg_realm_barrier_overworld_end_min","mg_realm_barrier_overworld_end_max"}
    for _,key in ipairs(required) do
        if not integer(vars[key]) then return failure("VoxeLibre world bound "..key.." is unavailable") end
    end
    local ok,mapgen=pcall(engine.get_mapgen_setting,"mg_name")
    if not ok then return failure("Luanti mapgen name is unavailable") end
    local size_ok,size_value=pcall(engine.get_mapgen_setting,"chunksize")
    local chunksize=size_ok and tonumber(size_value) or nil
    if (mapgen~="v7" and mapgen~="flat") or vars.chunksize~=5 or chunksize~=5
        or vars.central_chunk_offset_in_nodes~=-32 or vars.chunk_size_in_nodes~=80 then
        return failure("unsupported mapgen or VoxeLibre mapchunk alignment")
    end
    local minimum=math.max(vars.mapgen_edge_min,-engine_limit)
    local maximum=math.min(vars.mapgen_edge_max,engine_limit)
    local overworld_min,overworld_max=vars.mg_overworld_min,math.min(vars.mg_overworld_max,maximum)
    local barrier_min,barrier_max=vars.mg_realm_barrier_overworld_end_min,
        vars.mg_realm_barrier_overworld_end_max
    local safe_min=barrier_max+1
    if minimum>maximum or overworld_min>overworld_max or barrier_min>barrier_max
        or barrier_max>=overworld_min or safe_min>=overworld_min or safe_min>overworld_max then
        return failure("unsupported VoxeLibre overworld/realm boundary layout")
    end
    return {mapgen=mapgen,chunksize=chunksize,
        chunk_origin={x=vars.central_chunk_offset_in_nodes,y=vars.central_chunk_offset_in_nodes,
            z=vars.central_chunk_offset_in_nodes},
        map_limits={min_x=minimum,max_x=maximum,min_y=minimum,max_y=maximum,
            min_z=minimum,max_z=maximum},
        dimension_bounds={min_x=minimum,max_x=maximum,min_y=overworld_min,
            max_y=overworld_max,min_z=minimum,max_z=maximum},
        safe_generation_bounds={min_y=safe_min,max_y=overworld_max}}
end

return voxelibre
