-- SPDX-License-Identifier: GPL-3.0-or-later
-- Shared world for the completed-Towns destination tests (#51): a published
-- Towns exit of any direction, width and grade is written into the simulated
-- growth world next to a fake towns_api, and the real towns_adapter,
-- towns_destinations, connectors, planner, composer and builder run over it.
-- Only the towns_api data, surveying and the clock are scripted.
local fixture = dofile('tests/growth_fixture.lua')
local towns_fixture = dofile('tests/towns_fixture.lua')
local adapter = dofile('src/towns_adapter.lua')
local destinations = dofile('src/towns_destinations.lua')
local connectors = dofile('src/connectors.lua')
local edges = dofile('src/edges.lua')
local raster = dofile('src/raster.lua')
local surface = dofile('src/surface.lua')
assert(edges.set_raster(raster))

local M = {fixture = fixture, towns_fixture = towns_fixture, adapter = adapter, destinations = destinations,
    connectors = connectors, edges = edges, raster = raster, surface = surface, COBBLE = fixture.COBBLE}

local DIRS = {west = {x = -1, z = 0}, east = {x = 1, z = 0}, north = {x = 0, z = 1}, south = {x = 0, z = -1}}
M.DIRS = DIRS

-- A published exit like towns_api publishes it, translated to (ox, oz) with its
-- profile heights shifted by dy. Kinds: 'flat', 'down' (descends outward) and
-- 'up' (climbs outward); see tests/towns_fixture.lua.
function M.exit(direction, kind, width, ox, oz, dy)
    local e = towns_fixture.exit(direction, kind, width)
    for _, c in ipairs(e.columns) do c.x = c.x + ox; c.z = c.z + oz end
    for _, p in ipairs(e.profile) do p.y = p.y + dy end
    e.id = e.id:match('^(..)') .. ':' .. e.columns[1].x .. ':' .. e.columns[1].z
    return e
end

-- Write the exit's nodes (with support below and clear air above) into the world.
function M.place_exit(h, e)
    local d = e.direction
    for n = 0, e.length - 1 do
        local entry = e.profile[n + 1]
        for _, c in ipairs(e.columns) do
            local x, z = c.x + d.x * n, c.z + d.z * n
            for y = 0, entry.y - 1 do h.set(x, y, z, {name = fixture.STONE, param2 = 0}) end
            h.set(x, entry.y, z, {name = entry.name, param2 = entry.param2})
            for y = entry.y + 1, entry.y + 4 do h.set(x, y, z, {name = 'air', param2 = 0}) end
        end
    end
end

-- A published settlement whose built core lies behind the exits.
function M.settlement(id, exits, core)
    local s = towns_fixture.settlement(id, exits)
    s.center = {x = math.floor((core.x1 + core.x2) / 2), y = 0, z = math.floor((core.z1 + core.z2) / 2)}
    s.core = core
    s.structures = {{x1 = core.x2 + 1, z1 = core.z1, x2 = core.x2 + 4, z2 = core.z1 + 4}}
    s.reservation = {min = {x = core.x1 - 30, y = -10, z = core.z1 - 30}, max = {x = core.x2 + 30, y = 40, z = core.z2 + 30}}
    return s
end

-- The standard setup: the seeded road ends at (48, 0, 0) heading +x. `fake` is
-- the fake towns_api, `a` the real adapter over it and `dest` the real provider.
function M.setup(options)
    options = options or {}
    local fake = towns_fixture.new()
    local a = adapter.new(function() return fake.api end, function() return fake.now or 0 end)
    local h = fixture.harness({growth_towns = a, wrap_terrain = adapter.wrap_terrain, aligned_bounds = true})
    local access = {get_node = h.access.get_node, has_metadata = h.access.has_metadata, is_protected = h.access.is_protected,
        get_natural_light = function() return 15 end}
    local env = {access = access}
    local dest = destinations.new({towns = a, outward = function() return h.outward end, connectors = connectors, edges = edges,
        raster = raster, surface = surface, access = env.access, load = function() end,
        has_timer = function() return false end, owner = 'roads:growth', present = options.present})
    h.providers.town = dest.providers.town
    h.attachments.town = dest.attachments.town
    h.unavailable = dest.unavailable
    local writes = {}
    h.write_hook = function(p) writes[#writes + 1] = {x = p.x, y = p.y, z = p.z} end
    local world = {h = h, fake = fake, a = a, dest = dest, env = env, access = access, writes = writes}
    -- Publish a settlement with its exits and (by default) its Towns exclusion.
    function world.publish(s, no_exclusion)
        fake.records[s.id] = s
        fake.others[#fake.others + 1] = s
        if not no_exclusion then fake.exclude_settlement(s) end
        for _, e in ipairs(s.exits) do
            M.place_exit(h, {direction = e.direction, length = e.length, profile = e.profile, columns = e.columns})
        end
        return s
    end
    function world.adopt()
        local road_id = h.adopted(); h.writes = 0; for i = #writes, 1, -1 do writes[i] = nil end
        return road_id
    end
    return world
end

-- Independent walking oracle: breadth-first search over the columns of the world
-- whose top node is a road, stair or slab with three clear nodes above it. A step
-- to a neighbouring column may rise at most one node. Starts at (sx, sz); returns
-- the set of reached "x:z" keys.
function M.walk(h, sx, sz, box)
    local function top(x, z)
        for y = 6, -4, -1 do
            local n = h.access.get_node({x = x, y = y, z = z})
            if n.name ~= 'air' then return y, n end
        end
    end
    local function height(y, n)
        if n.name == 'mcl_stairs:slab_cobble' then return y end
        if n.name == 'mcl_core:cobble' or n.name == 'mcl_stairs:stair_cobble' then return y + 0.5 end
    end
    local function standing(x, z)
        local y, n = top(x, z)
        if not y then return nil end
        local top_height = height(y, n)
        if not top_height then return nil end
        for dy = 1, 3 do
            if h.access.get_node({x = x, y = y + dy, z = z}).name ~= 'air' then return nil end
        end
        return top_height
    end
    local seen, queue = {}, {{x = sx, z = sz}}
    local first = standing(sx, sz)
    if not first then return seen end
    seen[sx .. ':' .. sz] = first
    local i = 1
    while i <= #queue do
        local p = queue[i]; i = i + 1
        for _, d in ipairs({{1, 0}, {-1, 0}, {0, 1}, {0, -1}}) do
            local x, z = p.x + d[1], p.z + d[2]
            local id = x .. ':' .. z
            if not seen[id] and x >= box.x1 and x <= box.x2 and z >= box.z1 and z <= box.z2 then
                local height_here = standing(x, z)
                if height_here and math.abs(height_here - seen[p.x .. ':' .. p.z]) <= 1 then
                    seen[id] = height_here; queue[#queue + 1] = {x = x, z = z}
                end
            end
        end
    end
    return seen
end

return M
