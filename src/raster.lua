-- SPDX-License-Identifier: GPL-3.0-or-later
-- Pure geometry for four-node lattice edges. See docs/planner_contract.md.
local raster = {}

local function integer(n)
    return type(n) == "number" and n == n and n ~= math.huge
        and n ~= -math.huge and n == math.floor(n)
end

local function point(p)
    return type(p) == "table" and integer(p.x) and integer(p.y) and integer(p.z)
end

local function key(x, z)
    return x .. ":" .. z
end

local function sort_columns(columns)
    table.sort(columns, function(a, b)
        if a.x ~= b.x then return a.x < b.x end
        if a.z ~= b.z then return a.z < b.z end
        return a.y < b.y
    end)
end

local function failure(code, reason, position)
    return nil, {code = code, reason = reason, position = position}
end

function raster.segment(a, b)
    if not point(a) or not point(b) then
        return failure("invalid_endpoint", "segment endpoints must be integer points")
    end
    local dx, dz = b.x - a.x, b.z - a.z
    if not ((math.abs(dx) == 4 and (math.abs(dz) == 4 or dz == 0))
        or (dx == 0 and math.abs(dz) == 4)) then
        return failure("invalid_endpoint", "segment must be one lattice step")
    end

    local sx = dx == 0 and 0 or dx / 4
    local sz = dz == 0 and 0 or dz / 4
    local footprint = {}
    local function brush(x, z)
        for ox = -1, 1 do
            for oz = -1, 1 do
                local px, pz = x + ox, z + oz
                footprint[key(px, pz)] = {x = px, z = pz}
            end
        end
    end
    for k = 0, 4 do
        brush(a.x + k * sx, a.z + k * sz)
        if sx ~= 0 and sz ~= 0 and k < 4 then
            -- Both squares touched only at each corner belong to the closed cover.
            brush(a.x + (k + 1) * sx, a.z + k * sz)
            brush(a.x + k * sx, a.z + (k + 1) * sz)
        end
    end

    local columns = {}
    local length2 = dx * dx + dz * dz
    for _, p in pairs(footprint) do
        local t = ((p.x - a.x) * dx + (p.z - a.z) * dz) / length2
        t = math.max(0, math.min(1, t))
        p.y = math.floor(a.y + t * (b.y - a.y) + 0.5)
        columns[#columns + 1] = p
    end
    sort_columns(columns)
    local length = math.sqrt(length2)
    return {columns = columns, length = length, grade = math.abs(b.y - a.y) / length}
end

function raster.join(previous, current)
    if type(previous) ~= "table" or type(previous.columns) ~= "table"
        or type(current) ~= "table" or type(current.columns) ~= "table" then
        return failure("invalid_endpoint", "join requires two segment column sets")
    end
    local by_position, columns = {}, {}
    for _, segment in ipairs({previous, current}) do
        for _, p in ipairs(segment.columns) do
            if not point(p) then
                return failure("invalid_endpoint", "join columns must be integer points")
            end
            local k = key(p.x, p.z)
            local old = by_position[k]
            if old and old.y ~= p.y then
                return failure("profile_conflict", "overlapping columns have different heights", p)
            elseif not old then
                local copy = {x = p.x, y = p.y, z = p.z}
                by_position[k] = copy
                columns[#columns + 1] = copy
            end
        end
    end
    sort_columns(columns)
    for _, p in ipairs(columns) do
        -- Checking positive X/Z covers each cardinal pair once, deterministically.
        for _, offset in ipairs({{1, 0}, {0, 1}}) do
            local neighbor = by_position[key(p.x + offset[1], p.z + offset[2])]
            if neighbor and math.abs(p.y - neighbor.y) > 1 then
                return failure("step_height", "adjacent surface rise exceeds one node", p)
            end
        end
    end
    return {columns = columns}
end

return raster
