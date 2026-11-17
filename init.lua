-- SPDX-License-Identifier: GPL-3.0-or-later
local modname=core.get_current_modname()
local modpath=core.get_modpath(modname)
local function load(path) return dofile(modpath.."/"..path) end

local raster=load("src/raster.lua")
local edges=load("src/edges.lua")
local planner=load("src/planner.lua")
local plans=load("src/plans.lua")
local survey=load("src/survey.lua")
local surface=load("src/surface.lua")
local connectors=load("src/connectors.lua")
local survey_job=load("src/survey_job.lua")
local voxelibre=load("src/voxelibre.lua")
local lifecycle=load("src/jobs.lua")
local commands=load("src/commands.lua")
local preview=load("src/preview.lua")
local build=load("src/build.lua")
local towns_adapter=load("src/towns_adapter.lua")
local outward_store=load("src/outward_store.lua")
local outward=load("src/outward.lua")

assert(edges.set_raster(raster))
assert(planner.set_edges(edges))
assert(plans.set_dependencies(raster,edges))

local function world_config()
    local vars=rawget(_G,"mcl_vars")
    local world,err=voxelibre.world_config(core,vars,survey.ENGINE_COORD_LIMIT)
    if not world then return nil,err end
    return {world=world,
        planner={weights={slope=4,turn=2,cut=1,fill=1},road_material="mcl_core:cobble"},
        composition={road_material="mcl_core:cobble"},
    }
end

local function round(n) return math.floor(n+0.5) end
local function now() return core.get_us_time()/1000000 end
local access=surface.engine_access(core)
local ops={now=now,after=function(delay,fn) core.after(delay,fn) end,
    start_survey=function(first,second,owner,config)
        if type(config)~="table" then return nil,{code="unsupported_world",reason="world configuration is missing"} end
        local a={x=round(first.x),y=round(first.y),z=round(first.z)}
        local b={x=round(second.x),y=round(second.y),z=round(second.z)}
        return survey_job.new(survey,surface,{
            now=now,after=function(delay,fn) core.after(delay,fn) end,
            emerge=function(minp,maxp,callback) core.emerge_area(minp,maxp,callback) end,
            load_area=function(minp,maxp) return core.load_area(minp,maxp) end,
            access=access,actions={cancelled=core.EMERGE_CANCELLED,errored=core.EMERGE_ERRORED,
                memory=core.EMERGE_FROM_MEMORY,disk=core.EMERGE_FROM_DISK,generated=core.EMERGE_GENERATED},
        },a,b,owner,config)
    end,
    resolve_endpoints=function(terrain,first,second)
        return connectors.endpoints(terrain,first,second,access,
            function(minp,maxp) return core.load_area(minp,maxp) end,surface,edges)
    end,
    new_planner=function(terrain,request,config)
        local planner_config={weights=config.weights,road_material=config.road_material,
            max_expansions=config.max_expansions}
        return planner.new(terrain,request,planner_config)
    end,
    compose=function(terrain,route,config) return plans.compose(terrain,route,config) end,
    start_build=function(plan,done,guard)
        return build.new(plan,{now=now,guard=guard,after=function(delay,fn) core.after(delay,fn) end,
            load=function(minp,maxp) return core.load_area(minp,maxp) end,
            access=access,classify=surface.classify,
            has_timer=function(pos) return core.get_node_timer(pos):is_started() end,
            write=function(pos,node) core.swap_node(pos,node) end},done)
    end,
}
-- Published-exit endpoint resolution for the outward-road service.
ops.exit_endpoints=function(terrain,descriptor,target)
    return connectors.exit_endpoints(terrain,descriptor,target,access,
        function(minp,maxp) return core.load_area(minp,maxp) end,surface,edges)
end
local controller,err=lifecycle.new(ops)
if not controller then error("[roads] cannot initialize job lifecycle: "..tostring(err.reason)) end
local preview_renderer,preview_error=preview.new(core,function() return core.get_us_time()/1000000 end)
if not preview_renderer then error("[roads] cannot initialize route preview: "..tostring(preview_error.reason)) end
assert(commands.register(core,controller,surface,world_config,preview_renderer))

-- Outward-road service. Towns is optional: without towns_api the service
-- reports towns_unavailable and manual commands are unaffected. The command
-- that drives it belongs to a later ticket; trials may call roads.outward.
do
    local mod_storage=core.get_mod_storage()
    local towns=towns_adapter.new(function() return rawget(_G,"towns_api") end,now)
    local store=outward_store.new({
        storage={get=function(key) local v=mod_storage:get_string(key); if v=="" then return nil end return v end,
            set=function(key,value) mod_storage:set_string(key,value) end,
            keys=function() return mod_storage:get_keys() end},
        serialize=core.serialize,
        deserialize=function(text) return core.deserialize(text,true) end,
        now=os.time})
    local outward_ops={jobs=controller,towns=towns,store=store,now=now,after=ops.after,
        world_config=world_config,survey=survey,start_survey=ops.start_survey,
        exit_endpoints=ops.exit_endpoints,new_planner=ops.new_planner,compose=ops.compose,
        start_build=ops.start_build,wrap_terrain=towns_adapter.wrap_terrain,
        save_interval=function() return tonumber(core.settings:get("server_map_save_interval")) or 5.3 end,
        log=function(level,message) core.log(level,message) end,
        notify=function(name,summary)
            if summary.active then return end
            local player=core.get_player_by_name(name)
            if player then
                core.chat_send_player(name,"[roads] outward road "..tostring(summary.op_id)..": "..tostring(summary.state)
                    ..(summary.error and (" ("..tostring(summary.error.code)..": "..tostring(summary.error.reason)..")") or ""))
            end
        end}
    local service,service_error=outward.new(outward_ops)
    if not service then error("[roads] cannot initialize outward service: "..tostring(service_error.reason)) end
    service:recover()
    rawset(_G,"roads",{outward=service})
end
core.register_on_leaveplayer(function(player)
    local name=player:get_player_name()
    controller:disconnect(name)
    preview_renderer:forget(name)
end)
core.log("action","[roads] route planning commands registered; surveys can generate terrain")
