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

local function id3(p) return p.x .. ':' .. p.y .. ':' .. p.z end
local function id2(p) return p.x .. ':' .. p.z end
local function integral_point(p)
    return type(p)=='table' and finite(p.x) and p.x==math.floor(p.x)
        and finite(p.y) and p.y==math.floor(p.y) and finite(p.z) and p.z==math.floor(p.z)
end

-- Validate the raw expectations against the physical path, not just against
-- one another. These are the full-block supports understood by the survey.
local natural_support={}
for _,name in ipairs({'stone','dirt','dirt_with_grass','dirt_with_grass_snow','podzol','redsand','sand',
    'gravel','clay','sandstone','granite','andesite','diorite','snowblock',
    'stone_with_coal','stone_with_iron','stone_with_gold','stone_with_redstone',
    'stone_with_redstone_lit','stone_with_lapis','stone_with_emerald','stone_with_diamond'}) do
    natural_support['mcl_core:'..name]=true
end
natural_support['mcl_copper:stone_with_copper']=true
local function validate_preserved(endpoint,c,raw,transition_columns)
    local direction=c.direction
    if #c.path%2~=0 then return nil,'walking path has incomplete rows' end
    local lateral={x=-direction.z,z=direction.x}
    local requested=endpoint.requested
    if type(requested)~='table' or not finite(requested.x) or not finite(requested.y) or not finite(requested.z)
        or not integral_point(endpoint.ground) then return nil,'invalid selected connector ground' end
    local ground=endpoint.ground
    if ground.x~=math.floor(requested.x+0.5) or ground.z~=math.floor(requested.z+0.5) then
        return nil,'connector selection does not match ground'
    end
    local function get(x,y,z) return raw[x..':'..y..':'..z] end
    local selected=get(ground.x,ground.y,ground.z)
    if not selected or (selected.name~='mcl_stairs:stair_cobble' and selected.name~='mcl_stairs:slab_cobble') then
        return nil,'selected shaped node is not preserved'
    end
    local offset_min,offset_max=0,0
    for _,sign in ipairs({-1,1}) do for n=1,5 do
        local off=sign*n; local p=get(ground.x+off*lateral.x,ground.y,ground.z+off*lateral.z)
        if not p or p.name~=selected.name or p.param2~=selected.param2 then break end
        offset_min=math.min(offset_min,off); offset_max=math.max(offset_max,off)
    end end
    if offset_max-offset_min+1~=c.width then return nil,'preserved strip width differs from path' end
    local facedir=direction.x==1 and 1 or direction.x==-1 and 3 or direction.z==1 and 0 or 2
    local previous
    for row=0,#c.path/2-1 do
        local x,z=ground.x+row*direction.x,ground.z+row*direction.z
        local first,last=c.path[row*2+1],c.path[row*2+2]
        if first.x~=x-.25*direction.x or first.z~=z-.25*direction.z
            or last.x~=x+.25*direction.x or last.z~=z+.25*direction.z then
            return nil,'walking samples do not follow the selected strip'
        end
        local y=math.floor(math.max(first.y,last.y))
        -- A full block's top and a stair's high half are y+0.5; a slab's is y.
        local node=get(x,y,z)
        if not node then return nil,'walking surface is not preserved' end
        local h1,h2
        if node.name=='mcl_core:cobble' and node.param2==0 then h1,h2=y+.5,y+.5
        elseif node.name=='mcl_stairs:slab_cobble' and node.param2==0 then h1,h2=y,y
        elseif node.name=='mcl_stairs:stair_cobble' and (node.param2==facedir or node.param2==(facedir+2)%4) then
            if node.param2==facedir then h1,h2=y,y+.5 else h1,h2=y+.5,y end
        else return nil,'unsupported preserved walking surface' end
        if first.y~=h1 or last.y~=h2 or (previous and math.abs(previous-h1)>.5) then
            return nil,'walking surface heights do not match preserved nodes'
        end
        if row==0 then
            local along=(requested.x-ground.x)*direction.x+(requested.z-ground.z)*direction.z
            local selected_height=along>=0 and h2 or h1
            if ground.y~=y or math.abs(requested.y-selected_height)>.2 then return nil,'selected stair half does not match feet' end
        end
        for off=offset_min,offset_max do
            local sx,sz=x+off*lateral.x,z+off*lateral.z
            local p=get(sx,y,sz)
            if not p or p.name~=node.name or p.param2~=node.param2 then return nil,'preserved row is incomplete' end
            for dy=1,3 do
                local clear=get(sx,y+dy,sz)
                if not clear or clear.name~='air' then return nil,'preserved clearance is incomplete' end
            end
            local supported=false
            for depth=1,32 do
                local support=get(sx,y-depth,sz)
                if not support then return nil,'preserved support is incomplete' end
                if support.name~='mcl_core:cobble' then
                    if not natural_support[support.name] then return nil,'preserved support is unsupported' end
                    supported=true; break
                end
            end
            if not supported then return nil,'preserved support exceeds depth limit' end
            if row==#c.path/2-1 then
                local seam=transition_columns[(sx+direction.x)..':'..(sz+direction.z)]
                if not seam or math.abs(seam.y+.5-h2)>.5 then return nil,'terminal seam does not cover full approach width' end
            end
        end
        previous=h2
    end
    return true
end

-- Build the same immutable footprint used during search and composition.
function edges.connector_constraints(provenance)
    local result = {preserved={}, reserved={}, caps={}}
    for _,side in ipairs({'start','goal'}) do
        local endpoint = provenance and provenance[side]
        local c = endpoint and endpoint.connector
        if c then
            if type(c)~='table' or c.version~=1 or not integral_point(c.landing)
                or not integral_point(endpoint.resolved) or id3(c.landing)~=id3(endpoint.resolved)
                or type(c.preserved)~='table' or #c.preserved==0 or #c.preserved>50000
                or type(c.transition)~='table' or type(c.transition.surfaces)~='table'
                or type(c.transition.writes)~='table' or type(c.transition.expectations)~='table'
                or #c.transition.surfaces>50000 or #c.transition.writes>10000
                or #c.transition.expectations>50000 then
                return nil, 'invalid connector footprint'
            end
            for _,p in ipairs(c.preserved) do
                if not integral_point(p) or type(p.name)~='string' or not finite(p.param2)
                    or p.param2~=math.floor(p.param2) or p.param2<0 or p.param2>255
                    or p.has_metadata~=false or p.protected~=false then return nil, 'invalid preserved expectation' end
                result.preserved[id3(p)] = true
            end
            if type(c.direction)~='table' or not finite(c.direction.x) or not finite(c.direction.z)
                or math.abs(c.direction.x)+math.abs(c.direction.z)~=1
                or (c.width~=2 and c.width~=4) or type(c.path)~='table' or #c.path==0 or #c.path>32 then
                return nil, 'invalid connector walking path'
            end
            for i,p in ipairs(c.path) do
                if type(p)~='table' or not finite(p.x) or not finite(p.y) or not finite(p.z) then return nil,'invalid connector walking sample' end
                local previous=c.path[i-1]
                if previous and (math.abs(p.y-previous.y)>0.5 or (p.x-previous.x)^2+(p.z-previous.z)^2>1) then
                    return nil,'disconnected connector walking path'
                end
            end
            local cap = {surfaces={}, expectations={}, writes={}}
            local transition_columns={}
            for _,p in ipairs(c.transition.surfaces) do
                if not integral_point(p) then return nil, 'invalid transition surface' end
                if p.y~=c.landing.y then return nil, 'connector transition must remain flat' end
                local k=id2(p)
                if transition_columns[k] then return nil, 'duplicate transition surface' end
                transition_columns[k]=p
                if math.abs(p.x-c.landing.x)<=1 and math.abs(p.z-c.landing.z)<=1 then
                    if cap.surfaces[k] and cap.surfaces[k]~=p.y then return nil, 'conflicting cap surface' end
                    cap.surfaces[k]=p.y
                else result.reserved[k]=true end
            end
            local raw={}
            for _,p in ipairs(c.preserved) do
                local k=id3(p)
                if raw[k] then return nil,'duplicate preserved expectation' end
                raw[k]=p
            end
            local valid,why=validate_preserved(endpoint,c,raw,transition_columns)
            if not valid then return nil,why end
            for x=c.landing.x-1,c.landing.x+1 do for z=c.landing.z-1,c.landing.z+1 do
                if cap.surfaces[x..':'..z]==nil then return nil, 'incomplete landing cap' end
            end end
            local queue={transition_columns[id2(c.landing)]}; local seen={[id2(c.landing)]=true}; local qi=1
            while qi<=#queue do
                local p=queue[qi]; qi=qi+1
                for _,d in ipairs({{1,0},{-1,0},{0,1},{0,-1}}) do
                    local k=(p.x+d[1])..':'..(p.z+d[2]); local q=transition_columns[k]
                    if q and not seen[k] and math.abs(p.y-q.y)<=1 then seen[k]=true; queue[#queue+1]=q end
                end
            end
            if #queue~=#c.transition.surfaces then return nil,'disconnected connector transition' end
            local last=c.path[#c.path]; local seam=false
            for _,p in ipairs(c.transition.surfaces) do
                if math.abs(p.x-last.x)<=1.25 and math.abs(p.z-last.z)<=1.25
                    and math.abs((p.y+0.5)-last.y)<=0.5 then seam=true; break end
            end
            if not seam then return nil,'disconnected connector seam' end
            for _,name in ipairs({'expectations','writes'}) do
                for _,p in ipairs(c.transition[name]) do
                    if not integral_point(p) or type(p.kind)~='string' then return nil, 'invalid transition operation' end
                    local k=id3(p)
                    if math.abs(p.x-c.landing.x)<=1 and math.abs(p.z-c.landing.z)<=1 then
                        if cap[name][k] then return nil, 'duplicate cap operation' end
                        cap[name][k]=p
                    else result.reserved[id2(p)]=true end
                end
            end
            result.caps[#result.caps+1]=cap
        end
    end
    return result
end

local function check_constraints(terrain, columns, constraints, material)
    if not constraints then return end
    for _,p in ipairs(columns) do
        if constraints.reserved[id2(p)] then return 'connector', 'road intersects reserved transition', p end
        local col=terrain.get_column(p.x,p.z)
        local g,r=col.ground_y,p.y
        local first=r<=g and r-1 or g
        for y=first,r+3 do
            local pos={x=p.x,y=y,z=p.z}; local k=id3(pos)
            if constraints.preserved[k] then return 'connector', 'road intersects preserved connector', pos end
            local entry=node(col,y)
            for _,cap in ipairs(constraints.caps) do
                local height=cap.surfaces[id2(p)]
                if height then
                    if height~=r then return 'connector', 'landing cap height differs', p end
                    local expected=cap.expectations[k]
                    if not expected or expected.kind~=entry.kind or expected.material~=entry.material
                        or expected.protected~=entry.protected then return 'connector', 'landing cap expectation differs', pos end
                    local kind,write_material
                    if y==r then kind='road' elseif y>r then kind='air'
                    elseif r>g and y>g then kind='fill'; write_material=col.material end
                    local noop=kind=='air' and entry.kind=='air'
                        or kind=='road' and entry.kind=='natural' and entry.material==material
                        or kind=='fill' and entry.kind=='natural' and entry.material==write_material
                    local w=cap.writes[k]
                    if (kind and not noop) then
                        if not w or w.kind~=kind or w.material~=write_material then return 'connector', 'landing cap write differs', pos end
                    elseif w then return 'connector', 'landing cap write differs', pos end
                end
            end
        end
    end
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
local function check_column(column, p, counts, road_material)
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
    if not (road_material ~= nil and road.kind == "natural" and road.material == road_material) then
        local code, reason, pos = check_write(road, {x = p.x, y = r, z = p.z})
        if code then return code, reason, pos end
    end

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

local function validate_columns(terrain, columns, counts, road_material)
    for _, p in ipairs(columns) do
        local column, code, reason = terrain_column(terrain, p.x, p.z)
        if not column then return code, reason, p end
        local issue, why, position = check_column(column, p, counts, road_material)
        if issue then return issue, why, position end
    end
    return nil
end

function edges.check_surfaces(terrain, columns, road_material)
    local code, reason, position = validate_columns(terrain, columns, nil, road_material)
    if code then return nil, fail(code, reason, position) end
    return true
end

-- Reject a destination before A* only when its complete 3-by-3 cap cannot be
-- rendered for any incoming heading or any grade-compatible predecessor
-- elevation. This deliberately errs toward searching: it does not apply the
-- preceding segment's body constraints or guess which approach the route uses.
function edges.check_goal_cap(terrain, goal, config)
    if not raster then return nil, fail("invalid_config", "raster dependency has not been injected") end
    local failures = {}
    local directions = {{1,0},{1,1},{0,1},{-1,1},{-1,0},{-1,-1},{0,-1},{1,-1}}
    for _, direction in ipairs(directions) do
        for previous_y = goal.y - 1, goal.y + 1 do
            local previous = {x=goal.x-4*direction[1], y=previous_y, z=goal.z-4*direction[2]}
            local cap, err = raster.segment(previous, goal)
            if cap then
                local columns = {}
                for _, p in ipairs(cap.columns) do
                    if math.abs(p.x-goal.x) <= 1 and math.abs(p.z-goal.z) <= 1 then
                        columns[#columns+1] = p
                    end
                end
                local issue, reason, position = validate_columns(terrain, columns, nil,
                    config and config.road_material)
                if not issue then return true end
                failures[issue] = failures[issue] or {reason=reason, position=position}
            elseif err then
                return nil, fail(err.code, err.reason, err.position)
            end
        end
    end
    local names = {"water", "structure", "protected", "unknown", "support", "clearance", "earthwork"}
    local causes = {}
    for _, name in ipairs(names) do if failures[name] then causes[#causes+1]=name end end
    for name in pairs(failures) do
        local known=false; for _, listed in ipairs(names) do if name==listed then known=true end end
        if not known then causes[#causes+1]=name end
    end
    table.sort(causes)
    local detail = #causes > 0 and table.concat(causes, ", ") or "no feasible cap profile"
    local first = failures[causes[1]]
    return nil, fail("blocked_destination",
        string.format("Destination at (%d, %d, %d) has no clear 3-by-3 road cap; observed blockers: %s",
            goal.x, goal.y, goal.z, detail), first and first.position or goal)
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
    local issue, why, position = validate_columns(terrain, segment.columns, counts, config and config.road_material)
    if issue then return fail(issue, why, position) end
    issue, why, position = check_constraints(terrain, segment.columns, config and config.constraints, config and config.road_material)
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
        issue, why, position = validate_columns(terrain, joined.columns, nil, config and config.road_material)
        if issue then return fail(issue, why, position) end
        issue, why, position = check_constraints(terrain, joined.columns, config and config.constraints, config and config.road_material)
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
