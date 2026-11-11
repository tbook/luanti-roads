-- SPDX-License-Identifier: GPL-3.0-or-later
-- Pure terrain-aware validation and cost for one rasterized lattice edge.
local edges = {}
local raster

local DEFAULTS = {slope = 4, turn = 2, cut = 1, fill = 1}
local MAX_GRADE = 1 / 4
local DIRECTIONS = {
    {1, 0}, {1, 1}, {0, 1}, {-1, 1},
    {-1, 0}, {-1, -1}, {0, -1}, {1, -1},
}

local function finite(n)
    return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge
end

local function fail(code, reason, position)
    return {ok = false, code = code, reason = reason, position = position}
end

local function config_weights(config)
    if config ~= nil and type(config) ~= "table" then return nil end
    local supplied = {}
    if config and config.weights ~= nil then supplied = config.weights end
    if type(supplied) ~= "table" then return nil end
    local result = {}
    for name, default in pairs(DEFAULTS) do
        local n = supplied[name]
        if n == nil then n = default end
        if not finite(n) or n < 0 then return nil end
        result[name] = n
    end
    return result
end

local function terrain_column(terrain, x, z)
    if type(terrain) ~= "table" or type(terrain.get_column) ~= "function" then
        return nil, "unknown", "terrain snapshot has no column reader"
    end
    local ok, column = pcall(terrain.get_column, x, z)
    if not ok or type(column) ~= "table" then
        return nil, "unknown", "terrain column is missing or unreadable"
    end
    if column.status ~= "ok" then
        local code = column.status == "outside" and "outside"
            or column.status == "water" and "water"
            or column.status == "structure" and "structure" or "unknown"
        return nil, code, column.reason or ("terrain column status is " .. tostring(column.status))
    end
    if not finite(column.ground_y) or column.ground_y ~= math.floor(column.ground_y)
        or type(column.band) ~= "table" then
        return nil, "unknown", "terrain column is incomplete"
    end
    return column
end

local function node(column, y)
    local entry = column.band[y - column.ground_y]
    if type(entry) ~= "table" then return nil end
    return entry
end

local function allowed_existing(entry)
    return entry and (entry.kind == "natural" or entry.kind == "air"
        or entry.kind == "replaceable")
end

local function check_write(entry, position)
    if entry.protected == true then
        return "protected", "a required write is protected", position
    end
    if entry.protected ~= false then
        return "unknown", "protection status for a required write is unknown", position
    end
end

local function count_cut(counts, p, y)
    if not counts then return end
    local k = p.x .. ":" .. y .. ":" .. p.z
    if not counts.cut_positions[k] then
        counts.cut_positions[k] = true
        counts.cut = counts.cut + 1
    end
end

-- Validate one column's rendered road, support, excavation, and headroom.
-- `counts` is nil when validating a previous segment in a join: that overlap
-- must remain feasible, but is charged to the newly proposed segment only.
local function check_column(column, p, counts)
    local g, r = column.ground_y, p.y
    if math.abs(r - g) > 2 then
        return "earthwork", "road surface is more than two nodes from natural ground", p
    end

    if r <= g then
        local support = node(column, r - 1)
        if not support then return "unknown", "required support sample is missing", p end
        if support.kind ~= "natural" then
            return support.kind == "unknown" and "unknown" or "support",
                "cut road requires natural solid support below its surface", p
        end
        for y = r + 1, g do
            local entry = node(column, y)
            if not entry then return "unknown", "excavation sample is missing", p end
            if not allowed_existing(entry) then
                return entry.kind == "water" and "water"
                    or entry.kind == "unknown" and "unknown" or "structure",
                    "excavation meets an unsupported node", p
            end
            if entry.kind ~= "air" then
                local code, reason, pos = check_write(entry, {x = p.x, y = y, z = p.z})
                if code then return code, reason, pos end
            end
            if entry.kind == "natural" then count_cut(counts, p, y) end
        end
    else
        local ground = node(column, g)
        if not ground then return "unknown", "natural support sample is missing", p end
        if ground.kind ~= "natural" then
            return ground.kind == "unknown" and "unknown" or "support",
                "fill requires natural ground", p
        end
        if column.material == nil then
            return "unknown", "natural fill material is missing", p
        end
        for y = g + 1, r - 1 do
            local entry = node(column, y)
            if not entry then return "unknown", "fill support sample is missing", p end
            if entry.kind ~= "air" and entry.kind ~= "replaceable" then
                return entry.kind == "water" and "water"
                    or entry.kind == "unknown" and "unknown" or "support",
                    "fill support space is occupied", p
            end
            local code, reason, pos = check_write(entry, {x = p.x, y = y, z = p.z})
            if code then return code, reason, pos end
            if counts then counts.fill = counts.fill + 1 end
        end
    end

    local road = node(column, r)
    if not road then return "unknown", "road surface sample is missing", p end
    if not allowed_existing(road) then
        return road.kind == "water" and "water" or road.kind == "unknown" and "unknown"
            or "structure", "road surface is occupied", p
    end
    local code, reason, pos = check_write(road, {x = p.x, y = r, z = p.z})
    if code then return code, reason, pos end

    for y = r + 1, r + 3 do
        local entry = node(column, y)
        if not entry then return "unknown", "headroom sample is missing", p end
        if not allowed_existing(entry) then
            return entry.kind == "water" and "water" or entry.kind == "unknown" and "unknown"
                or "clearance", "road does not have three clear nodes", p
        end
        if entry.kind ~= "air" then
            local code, reason, pos = check_write(entry, {x = p.x, y = y, z = p.z})
            if code then return code, reason, pos end
        end
        if entry.kind == "natural" then count_cut(counts, p, y) end
    end
    return nil
end

local function validate_columns(terrain, columns, counts)
    for _, p in ipairs(columns) do
        local column, code, reason = terrain_column(terrain, p.x, p.z)
        if not column then return code, reason, p end
        local issue, why, position = check_column(column, p, counts)
        if issue then return issue, why, position end
    end
    return nil
end

local function world_point(terrain, x, z)
    local column, code, reason = terrain_column(terrain, x, z)
    if not column then return nil, code, reason end
    return {x = x, y = column.ground_y, z = z}
end

local function heading_index(heading)
    return type(heading) == "number" and heading == math.floor(heading)
        and heading >= 0 and heading <= 7 and heading + 1 or nil
end

function edges.evaluate(terrain, anchor, state, next_heading, config)
    if not raster then
        return fail("invalid_config", "raster dependency has not been injected")
    end
    local weights = config_weights(config)
    if not weights then return fail("invalid_config", "cost weights must be finite and nonnegative") end
    if type(anchor) ~= "table" or not finite(anchor.x) or not finite(anchor.z)
        or anchor.x ~= math.floor(anchor.x) or anchor.z ~= math.floor(anchor.z)
        or type(state) ~= "table" or not finite(state.i) or not finite(state.j)
        or state.i ~= math.floor(state.i) or state.j ~= math.floor(state.j)
        or not heading_index(next_heading)
        or (state.heading ~= nil and not heading_index(state.heading)) then
        return fail("invalid_endpoint", "edge state, anchor, or heading is invalid")
    end
    if state.heading ~= nil then
        local diff = math.abs(next_heading - state.heading)
        if math.min(diff, 8 - diff) > 1 then
            return fail("invalid_endpoint", "heading change exceeds 45 degrees")
        end
    end

    local current_x, current_z = anchor.x + 4 * state.i, anchor.z + 4 * state.j
    local from, code, reason = world_point(terrain, current_x, current_z)
    if not from then return fail(code, reason, {x = current_x, z = current_z}) end
    local dir = DIRECTIONS[next_heading + 1]
    local next_x, next_z = current_x + 4 * dir[1], current_z + 4 * dir[2]
    local to
    to, code, reason = world_point(terrain, next_x, next_z)
    if not to then return fail(code, reason, {x = next_x, z = next_z}) end
    local horizontal = math.sqrt((next_x - current_x)^2 + (next_z - current_z)^2)
    local grade = math.abs(to.y - from.y) / horizontal
    if grade > MAX_GRADE then return fail("grade", "edge grade exceeds 1:4", to) end

    local segment, err = raster.segment(from, to)
    if not segment then return fail(err.code, err.reason, err.position) end
    local counts = {cut = 0, fill = 0, cut_positions = {}}
    local issue, why, position = validate_columns(terrain, segment.columns, counts)
    if issue then return fail(issue, why, position) end

    if state.heading ~= nil then
        local incoming = DIRECTIONS[state.heading + 1]
        local previous_i, previous_j = state.i - incoming[1], state.j - incoming[2]
        local previous_x, previous_z = anchor.x + 4 * previous_i, anchor.z + 4 * previous_j
        local previous
        previous, code, reason = world_point(terrain, previous_x, previous_z)
        if not previous then return fail(code, reason, {x = previous_x, z = previous_z}) end
        local prior_segment
        prior_segment, err = raster.segment(previous, from)
        if not prior_segment then return fail(err.code, err.reason, err.position) end
        local joined
        joined, err = raster.join(prior_segment, segment)
        if not joined then return fail(err.code, err.reason, err.position) end
        issue, why, position = validate_columns(terrain, joined.columns, nil)
        if issue then return fail(issue, why, position) end
    end

    local change = state.heading == nil and 0
        or math.min(math.abs(next_heading - state.heading), 8 - math.abs(next_heading - state.heading))
    local normalized_grade = grade / MAX_GRADE
    local turn_ratio = change -- one heading index is exactly 45 degrees
    local cost = segment.length + weights.slope * segment.length * normalized_grade * normalized_grade
        + weights.turn * turn_ratio * turn_ratio + weights.cut * counts.cut + weights.fill * counts.fill
    return {
        ok = true,
        next_state = {i = state.i + dir[1], j = state.j + dir[2], heading = next_heading},
        segment = segment,
        cost = cost,
        metrics = {
            length = segment.length,
            ascent = math.max(0, to.y - from.y),
            descent = math.max(0, from.y - to.y),
            grade = grade,
            turn_count = change == 0 and 0 or 1,
            cut_count = counts.cut,
            fill_count = counts.fill,
        },
    }
end

-- Wiring injects the already-loaded geometry module, so importing this pure
-- evaluator never assumes the process working directory.
function edges.set_raster(raster_module)
    if type(raster_module) ~= "table" or type(raster_module.segment) ~= "function"
        or type(raster_module.join) ~= "function" then
        return nil, "raster dependency must provide segment and join"
    end
    raster = raster_module
    return true
end

return edges
