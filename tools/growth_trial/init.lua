local root=core.get_modpath('roads_trial')
-- Phase 1 builds a fresh world; phase 2 is a second launch of that world and rewrites nothing.
local phase=tonumber(core.settings:get('roads_trial_phase')) or 1
local mod_storage=core.get_mod_storage() -- only available while mods load
local function load(n) return dofile(root..'/src/'..n..'.lua') end
local surface,raster,edges,planner,plans,builder,seam=load('surface'),load('raster'),load('edges'),load('planner'),load('plans'),load('build'),load('seam')
edges.set_raster(raster); planner.set_edges(edges); plans.set_dependencies(raster,edges)
planner.set_seam_dependencies(seam,raster); plans.set_seam_dependency(seam); builder.set_seam_dependencies(seam,raster)
local bounds={min_x=-16,max_x=63,min_z=-16,max_z=31,min_y=-32,max_y=31}
local access=surface.engine_access(core)
local function timer(p) return core.get_node_timer(p):is_started() end
local function check(v,e) assert(v,core.serialize(e)); return v end
local function fail(err) core.log('error','GROWTH_TRIAL_FAIL '..tostring(err)); core.request_shutdown('trial failed',false,0) end
local function safe(f) local ok,err=xpcall(f,debug.traceback); if not ok then fail(err) end end
local function search(t,req,config)
 local job=check(planner.new(t,req,config)); local result
 repeat result=job:step({max_expansions=1000}) until result.status~='running'
 assert(result.status=='succeeded',core.serialize(result.error)); return result.route
end
local function build(plan,done)
 check(builder.new(plan,{now=function() return core.get_us_time()/1e6 end,after=core.after,load=core.load_area,
  access=access,classify=surface.classify,has_timer=timer,write=function(p,n) core.swap_node(p,n) end},
  function(err,metrics) safe(function() assert(not err,core.serialize(err)); done(metrics) end) end))
end
local function trial()
 local vm=core.get_voxel_manip()
 local emin,emax=vm:read_from_map({x=-16,y=-32,z=-16},{x=63,y=31,z=31})
 local area=VoxelArea:new({MinEdge=emin,MaxEdge=emax}); local data=vm:get_data()
 local stone,air=core.get_content_id('mcl_core:stone'),core.get_content_id('air')
 for z=-16,31 do for y=-32,31 do for x=-16,63 do data[area:index(x,y,z)]=y<=0 and stone or air end end end
 vm:set_data(data); vm:write_to_map(); vm:update_map()
 local terrain=check(surface.inspect(bounds,'roads_trial',access))
 local endpoints=check(surface.endpoints(terrain,{x=0,y=.5,z=0},{x=8,y=.5,z=0}))
 local request={start=endpoints.start.resolved,goal=endpoints.goal.resolved,provenance=endpoints}
 local source=check(plans.compose(terrain,search(terrain,request,{road_material='mcl_core:cobble'}),{road_material='mcl_core:cobble'}))
 local footprint={}
 for i=1,#source.centerline-1 do
  local edge=check(raster.segment(source.centerline[i],source.centerline[i+1]))
  footprint=footprint.columns and check(raster.join(footprint,edge)) or edge
 end
 local snapshot={}
 for _,p in ipairs(source.expectations) do
  local n=check(access.get_node(p)); snapshot[#snapshot+1]={x=p.x,y=p.y,z=p.z,name=n.name,param2=n.param2,
   has_metadata=access.has_metadata(p),protected=access.is_protected(p,'roads_trial'),has_timer=timer(p)}
 end
 local patch=check(seam.derive(raster,source,footprint.columns,snapshot,surface.classify))
 build(source,function()
  check(seam.check_patch(patch.preserved,access,'roads_trial',timer))
  local fresh=check(surface.inspect(bounds,'roads_trial',access))
  local start=patch.endpoint; local goal={x=16,y=0,z=0}
  local req={start=start,goal=goal,start_heading=patch.heading,start_seam=patch,provenance={
   start={origin='growth_seam',requested={x=start.x,y=start.y+.5,z=start.z},ground=start,resolved=start},
   goal={requested={x=goal.x,y=goal.y+.5,z=goal.z},ground=goal,resolved=goal}}}
  local config={road_material='mcl_core:cobble',seam_access=access,seam_has_timer=timer}
  local plan=check(plans.compose(fresh,search(fresh,req,config),config))
  build(plan,function(metrics)
   check(seam.check_patch(patch.preserved,access,'roads_trial',timer))
   local p=patch.preserved[1]; core.swap_node(p,{name='mcl_core:dirt'})
   local rejected,err=planner.new(fresh,req,config)
   assert(not rejected and err.code=='seam_changed')
   core.log('action','GROWTH_TRIAL_SEAM '..core.serialize({writes=metrics.writes,preserved=#patch.preserved}))
   dofile(root..'/service.lua')(1,function()
    core.log('action','GROWTH_TRIAL_PHASE1_PASS')
    core.request_shutdown('growth trial phase 1 complete',false,0)
   end,mod_storage)
  end)
 end)
end
if phase==2 then
 core.after(0,function() safe(function()
  dofile(root..'/service.lua')(2,function()
   core.log('action','GROWTH_TRIAL_PASS')
   core.request_shutdown('growth trial complete',false,0)
  end,mod_storage)
 end) end)
else
 core.after(0,function() core.emerge_area({x=-16,y=-32,z=-16},{x=63,y=31,z=31},function(_,_,left)
  if left==0 then core.after(0,function() safe(trial) end) end
 end) end)
end
