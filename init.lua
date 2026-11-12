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
local survey_job=load("src/survey_job.lua")
local voxelibre=load("src/voxelibre.lua")
local lifecycle=load("src/jobs.lua")
local commands=load("src/commands.lua")
local preview=load("src/preview.lua")

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
    resolve_endpoints=function(terrain,first,second) return surface.endpoints(terrain,first,second) end,
    new_planner=function(terrain,request,config)
        local planner_config={weights=config.weights,road_material=config.road_material}
        return planner.new(terrain,request,planner_config)
    end,
    compose=function(terrain,route,config) return plans.compose(terrain,route,config) end,
}
local controller,err=lifecycle.new(ops)
if not controller then error("[roads] cannot initialize job lifecycle: "..tostring(err.reason)) end
local preview_renderer,preview_error=preview.new(core,function() return core.get_us_time()/1000000 end)
if not preview_renderer then error("[roads] cannot initialize route preview: "..tostring(preview_error.reason)) end
assert(commands.register(core,controller,surface,world_config,preview_renderer))
core.register_on_leaveplayer(function(player)
    local name=player:get_player_name()
    controller:disconnect(name)
    preview_renderer:forget(name)
end)
core.log("action","[roads] route planning commands registered; surveys can generate terrain")
