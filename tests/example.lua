-- SPDX-License-Identifier: GPL-3.0-or-later
-- Run from the repository root: lua5.1 tests/example.lua
local raster = dofile('src/raster.lua')
local edges = dofile('src/edges.lua')
local planner = dofile('src/planner.lua')
local plans = dofile('src/plans.lua')
local fixture = dofile('tests/terrain.lua')
assert(edges.set_raster(raster)); assert(planner.set_edges(edges)); assert(plans.set_dependencies(raster,edges))
local t = fixture.rectangle(-8,24,-12,12,0)
t.owner = 'example'
-- A low raised strip makes a detour attractive without making it mandatory.
for x=8,12 do for z=-3,3 do t:set_column(x,z,2) end end
local a,b = {x=0,y=0,z=0},{x=20,y=0,z=0}
local function endpoint(p) return {requested={x=p.x,y=p.y+0.5,z=p.z},ground=p,resolved=p} end
local search = assert(planner.new(t,{start=a,goal=b,provenance={start=endpoint(a),goal=endpoint(b)}}))
local result = search:step({max_expansions=1000})
while result.status=='running' do result=search:step({max_expansions=1000}) end
assert(result.status=='succeeded',result.error and result.error.reason)
local p = assert(plans.compose(t,result.route,{road_material='cobble'}))
print('Road centerline:')
for _,v in ipairs(p.centerline) do print(string.format('  (%d, %d, %d)',v.x,v.y,v.z)) end
print(string.format('Length %.2f; cost %.2f; turns %d; road %d; fill %d; cuts %d; total writes %d',
    p.metrics.length,p.cost,p.metrics.turn_count,p.metrics.road_count,p.metrics.fill_count,p.metrics.cut_count,p.metrics.write_count))
