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
