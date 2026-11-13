local root=core.get_modpath('roads')
local function load(n) return dofile(root..'/src/'..n..'.lua') end
local surface,connectors=load('surface'),load('connectors')
local raster,edges,planner,plans,builder=load('raster'),load('edges'),load('planner'),load('plans'),load('build')
assert(edges.set_raster(raster)); assert(planner.set_edges(edges)); assert(plans.set_dependencies(raster,edges))
local towns=dofile(core.get_modpath('roads_trial')..'/town_roads.lua')
local bounds={min_x=-16,max_x=63,min_z=-16,max_z=31,min_y=-32,max_y=31}
local access=surface.engine_access(core)
local function key(p) return p.x..':'..p.y..':'..p.z end
local function check(v,e) assert(v,core.serialize(e)); return v end
local function trial()
 local descending=core.settings:get_bool('roads_trial_descending',false)
 local top=descending and 0 or 4
 local ground=descending and 4 or 0
 local columns={}
 for z=0,3 do columns[#columns+1]={x=0,z=z,direction={x=1,z=0}} end
 local region={get=function(x,y,z) return y<=top and 'mcl_core:stone' or 'air' end}
 local changes,omissions,length=towns.approach(columns,ground,region,function(n)
  return {walkable=n~='air'}
 end,function() return false end)
 assert(#changes>0 and #omissions==0)
 local vm=core.get_voxel_manip()
 local emin,emax=vm:read_from_map({x=-16,y=-32,z=-16},{x=63,y=31,z=31})
 local area=VoxelArea:new({MinEdge=emin,MaxEdge=emax}); local data=vm:get_data()
 local stone,air=core.get_content_id('mcl_core:stone'),core.get_content_id('air')
 for z=-16,31 do for y=-32,31 do for x=-16,63 do data[area:index(x,y,z)]=y<=top and stone or air end end end
 vm:set_data(data); vm:write_to_map(); vm:update_map()
 for _,p in ipairs(changes) do core.set_node(p,{name=p.name,param2=p.param2}) end
 local terrain=check(surface.inspect(bounds,'roads_trial',access))
 local endpoints,e=connectors.endpoints(terrain,{x=-.25,y=descending and 4.5 or 1,z=1},{x=32,y=top+.5,z=1},access,core.load_area,surface,edges)
 check(endpoints,e)
 local request={start=endpoints.start.resolved,goal=endpoints.goal.resolved,provenance=endpoints}
 local search=check(planner.new(terrain,request,{road_material='mcl_core:cobble'}))
 local result
 repeat result=search:step({max_expansions=1000}) until result.status~='running'
 assert(result.status=='succeeded',core.serialize(result.error))
 local plan=check(plans.compose(terrain,result.route,{road_material='mcl_core:cobble'}))
 local before={}
 for _,side in ipairs({'start','goal'}) do local c=endpoints[side].connector
  if c then for _,p in ipairs(c.preserved) do before[key(p)]={pos=p,node=core.get_node(p),meta=core.get_meta(p):to_table()} end end
 end
 local done=false
 check(builder.new(plan,{now=function() return core.get_us_time()/1e6 end,after=core.after,load=core.load_area,
  access=access,classify=surface.classify,has_timer=function(p) return core.get_node_timer(p):is_started() end,
  write=function(p,n) core.swap_node(p,n) end},function(err,metrics)
  assert(not err,core.serialize(err))
  local preserved=0
  for _,p in pairs(before) do
   assert(core.serialize(core.get_node(p.pos))==core.serialize(p.node),'preserved node changed')
   assert(core.serialize(core.get_meta(p.pos):to_table())==core.serialize(p.meta),'preserved metadata changed')
   preserved=preserved+1
  end
  done=true
  core.log('action','ROADS_TRIAL_PASS '..core.serialize({towns_rows=length,writes=metrics.writes,preserved=preserved,
   start=endpoints.start.resolved,goal=endpoints.goal.resolved,version=plan.version}))
  core.request_shutdown('roads trial complete',false,0)
 end))
 core.after(30,function() if not done then error('roads trial build timed out') end end)
end
core.after(0,function()
 core.emerge_area({x=-16,y=-32,z=-16},{x=63,y=31,z=31},function(_,_,remaining)
  if remaining==0 then core.after(0,function()
   local ok,err=xpcall(trial,debug.traceback)
   if not ok then core.log('error','ROADS_TRIAL_FAIL '..tostring(err)); core.request_shutdown('trial failed',false,0) end
  end) end
 end)
end)
