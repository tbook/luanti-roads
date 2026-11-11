-- SPDX-License-Identifier: GPL-3.0-or-later
-- Pure survey preflight. Engine adapters provide the active world's settings.
local survey = {}

survey.VERSION = 1
survey.HORIZONTAL_MARGIN = 32
survey.MAX_ENDPOINT_DISTANCE = 192
survey.VERTICAL_PADDING = 48
survey.MAX_VERTICAL_SPAN = 128
survey.STANDARD_CHUNK_NODES = 80
survey.MAX_CHUNKS = 96
survey.MAX_PATCH_VOXELS = 2000000
-- Supported chunksize-5 Luanti mapchunks span 80 nodes and align from -32
-- through 47 on each axis. Keep this fixed; caller-supplied origins could
-- silently count different terrain than the engine will emerge.
survey.SUPPORTED_CHUNK_ORIGIN = {x=-32,y=-32,z=-32}
-- Luanti's hard coordinate limit. Injected map and dimension bounds may narrow
-- this range but cannot extend it.
survey.ENGINE_COORD_LIMIT = 31000

local function finite_integer(n)
    return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge
        and n == math.floor(n)
end

local function bounds_copy(b)
    return {min_x=b.min_x, max_x=b.max_x, min_y=b.min_y, max_y=b.max_y,
        min_z=b.min_z, max_z=b.max_z}
end

local function failure(code, reason, details)
    local e = details or {}
    e.code, e.reason = code, reason
    return nil, e
end

local function validate_point(p, label)
    if type(p) ~= "table" or not finite_integer(p.x) or not finite_integer(p.y)
        or not finite_integer(p.z) then
        return false, label .. " endpoint must have integer x, y, and z"
    end
    if math.abs(p.x)>survey.ENGINE_COORD_LIMIT or math.abs(p.y)>survey.ENGINE_COORD_LIMIT
        or math.abs(p.z)>survey.ENGINE_COORD_LIMIT then
        return false, label .. " endpoint exceeds Luanti's supported coordinate limit"
    end
    return true
end

local function validate_config(c)
    if type(c) ~= "table" then return nil, "world configuration is required", "invalid_config" end
    -- Luanti's mapgen chunk size is measured in mapblocks. The MVP supports the
    -- default five-mapblock chunk, i.e. an 80-node cube.
    if c.chunksize ~= 5 then
        return nil, "unsupported mapgen chunksize; expected 5 mapblocks (80 nodes)", "unsupported_world"
    end
    if c.mapgen ~= "v7" and c.mapgen ~= "flat" then
        return nil, "unsupported mapgen; supported mapgens are v7 and flat", "unsupported_world"
    end
    if type(c.chunk_origin) ~= "table" then
        return nil, "chunk_origin x/y/z must match the supported Luanti alignment", "invalid_config"
    end
    for _, axis in ipairs({"x", "y", "z"}) do
        if not finite_integer(c.chunk_origin[axis]) then
            return nil, "chunk_origin." .. axis .. " must be an integer", "invalid_config"
        end
        if c.chunk_origin[axis] ~= survey.SUPPORTED_CHUNK_ORIGIN[axis] then
            return nil, "unsupported mapchunk origin; chunksize 5 is aligned at -32 on every axis", "unsupported_world"
        end
    end
    local function read_bounds(name)
        local b=c[name]
        if type(b) ~= "table" then return nil, name .. " are required", "invalid_config" end
        for _, key in ipairs({"min_x", "max_x", "min_y", "max_y", "min_z", "max_z"}) do
            if not finite_integer(b[key]) then return nil, name .. "." .. key .. " must be an integer", "invalid_config" end
            if math.abs(b[key]) > survey.ENGINE_COORD_LIMIT then
                return nil, name .. " exceeds Luanti's supported coordinate limit", "unsupported_world"
            end
        end
        if b.min_x>b.max_x or b.min_y>b.max_y or b.min_z>b.max_z then
            return nil, name .. " minimum exceeds maximum", "invalid_config"
        end
        return b
    end
    local m, err, code=read_bounds("map_limits")
    if not m then return nil,err,code end
    local d; d,err,code=read_bounds("dimension_bounds")
    if not d then return nil,err,code end
    return {chunk_nodes=survey.STANDARD_CHUNK_NODES,
        origin={x=c.chunk_origin.x,y=c.chunk_origin.y,z=c.chunk_origin.z},
        map_limits=m,dimension_bounds=d}
end

local function chunk_index(v, origin, size)
    return math.floor((v - origin) / size)
end

local function axis_bounds(minimum, maximum, origin, size)
    local first = chunk_index(minimum, origin, size)
    local last = chunk_index(maximum, origin, size)
    return origin + first * size, origin + (last + 1) * size - 1, first, last
end

local function make_chunks(b, cfg)
    local size, o = cfg.chunk_nodes, cfg.origin
    local ix0, ix1 = chunk_index(b.min_x,o.x,size), chunk_index(b.max_x,o.x,size)
    local iy0, iy1 = chunk_index(b.min_y,o.y,size), chunk_index(b.max_y,o.y,size)
    local iz0, iz1 = chunk_index(b.min_z,o.z,size), chunk_index(b.max_z,o.z,size)
    local chunks = {}
    for ix=ix0,ix1 do
        for iy=iy0,iy1 do
            for iz=iz0,iz1 do
                local min_x,min_y,min_z=o.x+ix*size,o.y+iy*size,o.z+iz*size
                chunks[#chunks+1] = {ix=ix,iy=iy,iz=iz,
                    bounds={min_x=min_x,max_x=min_x+size-1,min_y=min_y,max_y=min_y+size-1,
                        min_z=min_z,max_z=min_z+size-1}, voxel_count=size*size*size}
            end
        end
    end
    return chunks
end

-- Compute complete, inclusive chunk coverage and a deterministic sequential
-- patch list. Each patch is one actual mapchunk, so request and read allocation
-- are both bounded independently of total surveyed volume.
function survey.plan(start_point, end_point, config)
    local ok, why = validate_point(start_point, "start")
    if not ok then return failure("invalid_endpoint", why) end
    ok, why = validate_point(end_point, "end")
    if not ok then return failure("invalid_endpoint", why) end
    local cfg, config_error, config_code = validate_config(config)
    if not cfg then return failure(config_code, config_error) end

    local dx, dz = end_point.x-start_point.x, end_point.z-start_point.z
    local distance = math.sqrt(dx*dx + dz*dz)
    if distance > survey.MAX_ENDPOINT_DISTANCE then
        return failure("survey_budget", "endpoint separation exceeds 192 nodes",
            {limit=survey.MAX_ENDPOINT_DISTANCE,observed=distance})
    end

    local requested = {
        min_x=math.min(start_point.x,end_point.x)-survey.HORIZONTAL_MARGIN,
        max_x=math.max(start_point.x,end_point.x)+survey.HORIZONTAL_MARGIN,
        min_z=math.min(start_point.z,end_point.z)-survey.HORIZONTAL_MARGIN,
        max_z=math.max(start_point.z,end_point.z)+survey.HORIZONTAL_MARGIN,
        min_y=math.min(start_point.y,end_point.y)-survey.VERTICAL_PADDING,
        max_y=math.max(start_point.y,end_point.y)+survey.VERTICAL_PADDING,
    }
    local function inside(b)
        return requested.min_x>=b.min_x and requested.max_x<=b.max_x
            and requested.min_y>=b.min_y and requested.max_y<=b.max_y
            and requested.min_z>=b.min_z and requested.max_z<=b.max_z
    end
    if not inside(cfg.dimension_bounds) then
        return failure("unsupported_world", "survey request exceeds supported overworld dimension bounds",
            {bounds=requested,dimension_bounds=cfg.dimension_bounds})
    end
    local vertical_span=requested.max_y-requested.min_y+1
    if vertical_span > survey.MAX_VERTICAL_SPAN then
        return failure("survey_budget", "vertical survey interval exceeds 128 nodes",
            {limit=survey.MAX_VERTICAL_SPAN,observed=vertical_span})
    end

    local rounded={}
    rounded.min_x,rounded.max_x=axis_bounds(requested.min_x,requested.max_x,cfg.origin.x,cfg.chunk_nodes)
    rounded.min_y,rounded.max_y=axis_bounds(requested.min_y,requested.max_y,cfg.origin.y,cfg.chunk_nodes)
    rounded.min_z,rounded.max_z=axis_bounds(requested.min_z,requested.max_z,cfg.origin.z,cfg.chunk_nodes)
    local m=cfg.map_limits
    if rounded.min_x<m.min_x or rounded.max_x>m.max_x or rounded.min_y<m.min_y
        or rounded.max_y>m.max_y or rounded.min_z<m.min_z or rounded.max_z>m.max_z then
        return failure("unsupported_world", "complete mapchunk coverage exceeds world map limits",
            {bounds=rounded,map_limits=m})
    end
    if rounded.min_x<cfg.dimension_bounds.min_x or rounded.max_x>cfg.dimension_bounds.max_x
        or rounded.min_y<cfg.dimension_bounds.min_y or rounded.max_y>cfg.dimension_bounds.max_y
        or rounded.min_z<cfg.dimension_bounds.min_z or rounded.max_z>cfg.dimension_bounds.max_z then
        return failure("unsupported_world", "complete mapchunk coverage exceeds supported overworld dimension bounds",
            {bounds=rounded,dimension_bounds=cfg.dimension_bounds})
    end

    -- Count the union of chunks covering the inclusive rectangular survey. A
    -- chunk is represented once even when many road columns share it.
    local chunks=make_chunks(requested,cfg)
    if #chunks > survey.MAX_CHUNKS then
        return failure("survey_budget", "survey requires more than 96 distinct mapchunks",
            {limit=survey.MAX_CHUNKS,observed=#chunks})
    end
    local patches={}
    for i, chunk in ipairs(chunks) do
        if chunk.voxel_count > survey.MAX_PATCH_VOXELS then
            return failure("survey_budget", "one mapchunk exceeds the read allocation cap",
                {limit=survey.MAX_PATCH_VOXELS,observed=chunk.voxel_count})
        end
        patches[i]={sequence=i,request_bounds=bounds_copy(chunk.bounds),
            read_bounds=bounds_copy(chunk.bounds),voxel_count=chunk.voxel_count,
            chunk={x=chunk.ix,y=chunk.iy,z=chunk.iz}}
    end
    local voxel_count=0
    for _,p in ipairs(patches) do voxel_count=voxel_count+p.voxel_count end
    return {version=survey.VERSION,requested_bounds=requested,chunk_bounds=rounded,
        chunks=chunks,patches=patches,chunk_count=#chunks,voxel_count=voxel_count,
        max_patch_voxels=survey.MAX_PATCH_VOXELS,
        endpoint_distance=distance,vertical_span=vertical_span}
end

return survey
