-- SPDX-License-Identifier: GPL-3.0-or-later
-- Pure terrain shaping for the growth trial (no engine calls; also used by
-- tests/growth_trial.lua). The world is flat stone with ground at y = 0. Every
-- continuation cycle plans 96 nodes straight ahead from the seam endpoint, so a
-- short two-node-thick wall of an obstacle block across the middle of that run
-- forces the route to swerve round it: each cycle then contains several bends
-- and ends back on the straight line. The detour side alternates.
local layout = {}

layout.CYCLE_LENGTH = 96
layout.WALL_NODE = 'mcl_core:obsidian'   -- unlisted in surface.classify, so an obstacle
layout.WALL_Y = 1                         -- one node above the y = 0 ground blocks a column
-- {offset ahead of the cycle's start, min z, max z}; indexed by cycle.
layout.SPANS = {{48, -20, 6}, {48, -6, 20}, {48, -20, 6}, {48, -6, 20}}

-- Wall boxes for the cycles that start at origin_x, origin_x + 96, ...
function layout.walls(origin_x)
    local list = {}
    for i, span in ipairs(layout.SPANS) do
        local x = origin_x + (i - 1) * layout.CYCLE_LENGTH + span[1]
        list[i] = {min_x = x, max_x = x + 1, min_z = span[2], max_z = span[3], y = layout.WALL_Y}
    end
    return list
end

-- Calls fn(x, y, z, name) for each wall node.
function layout.each_wall_node(origin_x, fn)
    for _, w in ipairs(layout.walls(origin_x)) do
        for x = w.min_x, w.max_x do for z = w.min_z, w.max_z do fn(x, w.y, z, layout.WALL_NODE) end end
    end
end

-- Published Towns exits that really exist in the trial world (ground y = 0), in the
-- shape towns_api publishes them. `steer` faces west and lies 400 nodes ahead of the
-- first seam (a distant, compatible town: waypoint, then the final attachment once
-- it is in range); its exit is graded (stair, slab) and four wide. `away` lies
-- 160 nodes ahead of the second seam, 30 nodes aside, with an exit that faces east,
-- away from the road: it can never be entered heading into the town.
local FACEDIR = {['1:0'] = 1, ['-1:0'] = 3, ['0:1'] = 0, ['0:-1'] = 2}
local COBBLE, STAIR, SLAB = 'mcl_core:cobble', 'mcl_stairs:stair_cobble', 'mcl_stairs:slab_cobble'
function layout.exit(direction, kind, width, ox, oz)
    local d = direction
    local p2 = FACEDIR[d.x .. ':' .. d.z]
    local profile = {}
    if kind == 'flat' then
        for n = 1, 6 do profile[n] = {y = 0, name = COBBLE, param2 = 0} end
    else -- 'down': a graded exit one node above the ground that descends outward
        profile = {{y = 1, name = COBBLE, param2 = 0}, {y = 1, name = STAIR, param2 = (p2 + 2) % 4}, {y = 1, name = SLAB, param2 = 0}}
    end
    local columns = {}
    for l = 0, width - 1 do
        columns[#columns + 1] = {x = ox + ((d.z == 0) and 0 or -l * d.z), z = oz + ((d.x == 0) and 0 or l * d.x)}
    end
    table.sort(columns, function(a, b)
        if d.x ~= 0 then return a.z < b.z end
        return a.x < b.x
    end)
    local label = (d.x == 1 and '+x') or (d.x == -1 and '-x') or (d.z == 1 and '+z') or '-z'
    return {id = label .. ':' .. columns[1].x .. ':' .. columns[1].z, source = 'street', direction = {x = d.x, z = d.z},
        columns = columns, length = #profile, profile = profile}
end

-- Calls fn(x, y, z, name, param2) for each built node of a published exit.
function layout.each_exit_node(exit, fn)
    for n = 0, exit.length - 1 do
        local entry = exit.profile[n + 1]
        for _, c in ipairs(exit.columns) do
            fn(c.x + exit.direction.x * n, entry.y, c.z + exit.direction.z * n, entry.name, entry.param2)
        end
    end
end

local function settlement(id, exit, core)
    return {id = id, site_id = 'trial', state = 'complete', town_type = 'medieval', exits = {exit}, core = core,
        structures = {{x1 = core.x2 + 1, z1 = core.z1, x2 = core.x2 + 4, z2 = core.z1 + 4}},
        center = {x = math.floor((core.x1 + core.x2) / 2), y = 0, z = math.floor((core.z1 + core.z2) / 2)},
        reservation = {min = {x = core.x1 - 30, y = -10, z = core.z1 - 30}, max = {x = core.x2 + 30, y = 40, z = core.z2 + 30}}}
end

-- origin_x is the seed endpoint x. Returns {steer = settlement, away = settlement}.
function layout.towns(origin_x)
    local west, east = {x = -1, z = 0}, {x = 1, z = 0}
    local steer_x = origin_x + 400
    local away_x = origin_x + layout.CYCLE_LENGTH + 160
    return {
        steer = settlement('trial:town-east', layout.exit(west, 'down', 4, steer_x, 0), {x1 = steer_x + 1, z1 = -30, x2 = steer_x + 52, z2 = 30}),
        away = settlement('trial:town-away', layout.exit(east, 'flat', 2, away_x, 30), {x1 = away_x - 34, z1 = 12, x2 = away_x - 1, z2 = 60}),
    }
end

-- Number of direction changes along a centerline of {x, z} points.
function layout.bends(centerline)
    local count, px, pz = 0, nil, nil
    for i = 2, #centerline do
        local dx, dz = centerline[i].x - centerline[i - 1].x, centerline[i].z - centerline[i - 1].z
        if px and (dx ~= px or dz ~= pz) then count = count + 1 end
        px, pz = dx, dz
    end
    return count
end

-- The preserved seam node that is the road surface at the endpoint column, or nil.
-- Editing it is the trial's "player edit" of the seam.
function layout.seam_edit_node(preserved, endpoint)
    for _, p in ipairs(preserved) do
        if p.x == endpoint.x and p.y == endpoint.y and p.z == endpoint.z then return p end
    end
    return nil
end

return layout
