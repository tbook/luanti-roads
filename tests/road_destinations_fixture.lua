-- SPDX-License-Identifier: GPL-3.0-or-later
-- Shared world for the existing-road destination tests (#52): several growth
-- roads are built in the simulated growth world of tests/growth_fixture.lua (each
-- from its own scripted outward origin and adopted), and the real road provider,
-- resolver, connector geometry, planner, composer, builder, outward and growth
-- services run over it. Only surveying, the job slot and the clock are scripted.
local fixture = dofile('tests/growth_fixture.lua')
local destinations = dofile('src/road_destinations.lua')
local towns_destinations = dofile('src/towns_destinations.lua')
local connectors = dofile('src/connectors.lua')
local edges = dofile('src/edges.lua')
local raster = dofile('src/raster.lua')
local surface = dofile('src/surface.lua')
local towns_fixture = dofile('tests/towns_destinations_fixture.lua')
assert(edges.set_raster(raster))

local M = {fixture = fixture, destinations = destinations, connectors = connectors, edges = edges, raster = raster,
    surface = surface, COBBLE = fixture.COBBLE, walk = towns_fixture.walk}

local function copy(v)
    if type(v) ~= 'table' then return v end
    local r = {}; for k, x in pairs(v) do r[k] = copy(x) end
    return r
end

-- options: harness options (aligned_bounds is always on).
function M.setup(options)
    options = options or {}
    local h_options = {aligned_bounds = true}
    for k, v in pairs(options) do h_options[k] = v end
    local h = fixture.harness(h_options)
    local access = {get_node = h.access.get_node, has_metadata = h.access.has_metadata, is_protected = h.access.is_protected,
        get_natural_light = function() return 15 end}
    -- The registry is rebuilt by a harness restart; always talk to the current one.
    local store = setmetatable({}, {__index = function(_, name)
        return function(_, ...) return h.growth_store[name](h.growth_store, ...) end
    end})
    local dest = destinations.new({store = store, digest = towns_destinations.revision, connectors = connectors, edges = edges,
        raster = raster, surface = surface, access = access, load = function() end,
        has_timer = function() return false end, owner = 'roads:growth'})
    h.providers.road = dest.providers.road
    h.attachments.road = dest.attachments.road
    h.unavailable = dest.unavailable
    local writes = {}
    h.write_hook = function(p) writes[#writes + 1] = {x = p.x, y = p.y, z = p.z} end

    local exits, base = {}, h.towns:exit()
    function h.towns:settlement(id) return {id = id} end
    function h.towns:exit(settlement, exit_id) return copy(exits[settlement.id .. '/' .. exit_id]) end
    exits[fixture.SID .. '/' .. fixture.EAST] = copy(base)

    local world = {h = h, dest = dest, access = access, writes = writes, roads = {}}

    -- Build one outward road from a scripted exit and adopt it. spec = {sid, exit_id,
    -- anchor = {x,y,z}, direction = {x,z}, target = {x,z}}. The road starts 8 nodes
    -- east of the anchor (the fixture's scripted exit endpoints) and runs to target.
    function world.road(spec)
        local descriptor = copy(base)
        descriptor.settlement_id = spec.sid; descriptor.exit_id = spec.exit_id
        descriptor.anchor = copy(spec.anchor); descriptor.direction = copy(spec.direction)
        descriptor.center = {x = spec.anchor.x - 10, y = 0, z = spec.anchor.z}
        exits[spec.sid .. '/' .. spec.exit_id] = descriptor
        local started, err = h.outward:start({settlement_id = spec.sid, exit_id = spec.exit_id, requester = 'alice',
            policy = {version = 1, seed = 1}, candidates = {spec.target}})
        assert(started, err and err.reason)
        h.run_until(function() return h.outward:status() == nil end)
        local status = assert(h.outward:status(spec.sid))
        assert(status.state == 'built', status.state .. ' ' .. tostring(status.error and status.error.reason))
        h.builds, h.surveys, h.writes = 0, 0, 0
        for i = #writes, 1, -1 do writes[i] = nil end
        if spec.adopt == false then return status end
        local road_id = assert(h.growth:adopt(status.op_id, 'admin'))
        world.roads[#world.roads + 1] = road_id
        return road_id
    end
    -- The standard target road A: along z = 0 from x = 8 to x = 48, heading east.
    function world.target()
        local road_id = world.road({sid = fixture.SID, exit_id = fixture.EAST, anchor = {x = 0, y = 0, z = 0},
            direction = {x = 1, z = 0}, target = {x = 48, z = 0}})
        h.writes = 0; for i = #writes, 1, -1 do writes[i] = nil end
        return road_id
    end
    -- An incoming road ending at (x, 0, z - 40 + 40) heading north (+z), x = anchor.x + 8:
    -- from (x, -60) to (x, -20) by default.
    function world.incoming(anchor_x, from_z, to_z, sid)
        local road_id = world.road({sid = sid or 'auto:9:9', exit_id = '+z:0:0', anchor = {x = anchor_x - 8, y = 0, z = from_z},
            direction = {x = 0, z = 1}, target = {x = anchor_x, z = to_z}})
        h.writes = 0; for i = #writes, 1, -1 do writes[i] = nil end
        return road_id
    end
    function world.cycle(road_id)
        local id, err = h.run_cycle(road_id)
        return id, err
    end
    function world.last_attempt(road_id)
        local r = h.road(road_id)
        return r.attempts[#r.attempts], r
    end
    return world
end

return M
