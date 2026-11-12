-- SPDX-License-Identifier: GPL-3.0-or-later
local lifecycle=dofile("src/jobs.lua")
local commands=dofile("src/commands.lua")
local voxelibre=dofile("src/voxelibre.lua")
local survey=dofile("src/survey.lua")
local preview=dofile("src/preview.lua")
local count=0
local function test(name,fn)
    local ok,err=pcall(fn)
    if not ok then error("jobs "..name..": "..tostring(err)) end
    count=count+1
end
local function point(x,y,z) return {x=x,y=y,z=z} end
local function lattice_line(a,b)
    local n=math.max(math.abs(b.x-a.x),math.abs(b.y-a.y),math.abs(b.z-a.z))
    local line={}
    for i=0,n do line[#line+1]={x=a.x+(b.x-a.x)*i/n,y=a.y+(b.y-a.y)*i/n,z=a.z+(b.z-a.z)*i/n} end
    return line
end
local function endpoint(feet,resolved_x)
    local ground={x=math.floor(feet.x+0.5),y=math.floor(feet.y+0.5)-1,z=math.floor(feet.z+0.5)}
    local resolved={x=resolved_x or ground.x,y=ground.y,z=ground.z}
    return {requested={x=feet.x,y=feet.y,z=feet.z},ground=ground,resolved=resolved}
end
local function harness(options)
    options=options or {}
    local h={time=0,queue={},survey_jobs={},searches={},composed=0,notices={}}
    local terrain={version=1,bounds={min_x=-100,max_x=100,min_y=-100,max_y=100,min_z=-100,max_z=100},
        get_column=function(x,z) return {status="ok",ground_y=0} end}
    local endpoints={start=endpoint(point(0,0.5,0)),goal=endpoint(point(8,0.5,0))}
    local ops={now=function() return h.time end,
        after=function(delay,fn)
            if options.schedule_error then error("scheduler unavailable") end
            h.queue[#h.queue+1]={at=h.time+delay,fn=fn}
        end,
        notify=function(name,status) h.notices[#h.notices+1]={name=name,status=status} end,
        start_survey=function(a,b,owner,config)
            h.survey_args={start=a,goal=b,owner=owner,config=config}
            if options.start_survey_error then return nil,{code="survey_budget",reason="preflight blocked"} end
            local s={state="running",cancelled=false}
            function s:status() return {status=self.state,error=self.error,terrain=self.state=="succeeded" and terrain or nil,
                metrics={chunks_total=2,chunks_completed=self.state=="succeeded" and 2 or 1,columns_completed=20,tiles_completed=3}} end
            function s:cancel() self.cancelled=true; self.state="cancelled"; self.error={code="cancelled",reason="cancelled"} end
            h.survey_jobs[#h.survey_jobs+1]=s; h.survey=s
            return s
        end,
        resolve_endpoints=function(_,a,b)
            h.resolve_args={a=a,b=b}
            if options.endpoint_error then return nil,{code="invalid_endpoint",reason="bad snap"} end
            return endpoints
        end,
        new_planner=function(_,request,config)
            h.request=request; h.planner_config=config
            if options.planner_start_error then return nil,{code="invalid_endpoint",reason="planner refused endpoint"} end
            local search={calls=0,cancelled=false}
            function search:step()
                self.calls=self.calls+1
                if options.search_error then return {status="failed",error={code="bounded_no_route",reason="barrier"},metrics={expansions=2,states=4}} end
                if options.search_slices and self.calls < options.search_slices then return {status="running",metrics={expansions=self.calls*10,states=8}} end
                return {status="succeeded",metrics={expansions=15,states=10},route={cost=27,
                    centerline=lattice_line(request.start,request.goal),
                    metrics={length=24,ascent=0,descent=0,max_grade=0.1,turn_count=1,cut_count=2,fill_count=3}}}
            end
            function search:cancel() self.cancelled=true end
            h.searches[#h.searches+1]=search; h.search=search
            return search
        end,
        compose=function(_,route,config)
            h.composed=h.composed+1; h.route=route; h.composition_config=config
            if options.compose_error then return nil,{code="composition_failed",reason="overlap"} end
            return {owner="alice",writes={},centerline=route.centerline,metrics={length=route.metrics.length,max_grade=0.1,
                cut_count=5,fill_count=6,road_count=200,write_count=300}}
        end}
    h.controller=assert(lifecycle.new(ops))
    h.drain=function(limit)
        limit=limit or 100
        for _=1,limit do
            table.sort(h.queue,function(a,b) return a.at<b.at end)
            local task=table.remove(h.queue,1)
            if not task then break end
            h.time=task.at; task.fn()
        end
    end
    h.config={world={chunksize=5},planner={road_material="cobble"},composition={road_material="cobble"}}
    return h
end

test("per-player endpoint ownership and simultaneous requests",function()
    local h=harness()
    local id,err=h.controller:plan("alice",point(8,.5,0),h.config)
    assert(not id and err.code=="invalid_endpoint")
    assert(h.controller:start_endpoint("alice",point(0,.5,0)))
    assert(h.controller:start_endpoint("bob",point(20,.5,0)))
    id=assert(h.controller:plan("alice",point(8,.5,0),h.config))
    assert(h.controller:status("alice").state=="surveying")
    local other,e=h.controller:plan("bob",point(32,.5,0),h.config)
    assert(not other and e.code=="busy" and h.controller:status("bob").state=="idle")
    assert(h.survey_args.owner=="alice" and h.survey_args.start.x==0 and h.survey_args.goal.x==8)
    assert(h.controller:start_endpoint("alice",point(40,.5,0))) -- selection is independent of active job
    assert(h.survey_args.start.x==0)
end)

test("survey, resumable search, composition, ready ownership, and release",function()
    local h=harness({search_slices=2})
    h.controller:start_endpoint("alice",point(0,.5,0))
    local id=assert(h.controller:plan("alice",point(8,.5,0),h.config))
    h.survey.state="succeeded"
    h.drain(1) -- poll transitions into first search slice
    assert(h.controller:status("alice").state=="searching" and h.search.calls==1)
    h.drain(1)
    assert(h.controller:status("alice").state=="ready" and h.composed==1)
    local s=h.controller:status("alice")
    assert(s.id==id and s.endpoints.start.resolved.x==0 and s.endpoints.goal.resolved.x==8)
    assert(s.cost==27 and s.metrics.cut_count==5 and s.metrics.write_count==300
        and s.search_metrics.expansions==15)
    local saved=h.controller.reports.alice
    assert(saved.plan and saved.search==nil and saved.terrain==nil and saved.route==nil and saved.survey==nil)
    local next_id,err=h.controller:plan("bob",point(12,.5,0),h.config)
    assert(not next_id and err.code=="invalid_endpoint") -- Bob has no selected first point.
    h.controller:start_endpoint("bob",point(0,.5,0))
    next_id,err=h.controller:plan("bob",point(12,.5,0),h.config)
    assert(not next_id and err.code=="busy")
    local ok,not_owner=h.controller:cancel("bob")
    assert(not ok and not_owner.code=="not_owner")
    assert(h.controller:cancel("alice"))
    assert(h.controller:status("alice").state=="cancelled")
    next_id=assert(h.controller:plan("bob",point(12,.5,0),h.config))
    assert(next_id and h.controller:status("bob").state=="surveying")
end)

test("preflight, survey, endpoint and planner startup failures release the slot",function()
    for _,options in ipairs({{start_survey_error=true},{endpoint_error=true},{planner_start_error=true}}) do
        local h=harness(options); h.controller:start_endpoint("alice",point(0,.5,0))
        local id,err=h.controller:plan("alice",point(8,.5,0),h.config)
        if options.start_survey_error then
            assert(not id and err.code=="survey_budget")
        else
            assert(id); h.survey.state="succeeded"; h.drain(1)
        assert(h.controller:status("alice").state=="failed")
        assert(h.controller.reports.alice.search==nil and h.controller.reports.alice.terrain==nil)
        end
        options.start_survey_error=nil; options.endpoint_error=nil; options.planner_start_error=nil
        h.controller:start_endpoint("bob",point(0,.5,0))
        assert(h.controller:plan("bob",point(12,.5,0),h.config))
    end
    local h=harness(); h.controller:start_endpoint("alice",point(0,.5,0))
    assert(h.controller:plan("alice",point(8,.5,0),h.config))
    h.survey.state="failed"; h.survey.error={code="survey_failed",reason="emerge failed"}; h.drain(1)
    assert(h.controller:status("alice").error.code=="survey_failed" and not h.controller.active)
end)

test("search and composition failures are reported and clean up",function()
    for _,options in ipairs({{search_error=true},{compose_error=true}}) do
        local h=harness(options); h.controller:start_endpoint("alice",point(0,.5,0))
        assert(h.controller:plan("alice",point(8,.5,0),h.config))
        h.survey.state="succeeded"; h.drain(1)
        assert(h.controller:status("alice").state=="failed" and not h.controller.active)
        h.controller:start_endpoint("bob",point(0,.5,0))
        assert(h.controller:plan("bob",point(12,.5,0),h.config))
    end
end)

test("cancel and disconnect invalidate obsolete survey/search callbacks",function()
    local h=harness(); h.controller:start_endpoint("alice",point(0,.5,0))
    assert(h.controller:plan("alice",point(8,.5,0),h.config))
    local old_survey=h.survey
    assert(h.controller:cancel("alice") and old_survey.cancelled)
    h.controller:start_endpoint("bob",point(0,.5,0))
    assert(h.controller:plan("bob",point(12,.5,0),h.config))
    old_survey.state="succeeded"; h.drain(1)
    assert(h.controller:status("bob").state=="surveying" and #h.searches==0)
    h.controller:disconnect("bob")
    assert(not h.controller.active and h.controller:status("bob").state=="idle")

    h=harness({search_slices=3}); h.controller:start_endpoint("alice",point(0,.5,0))
    assert(h.controller:plan("alice",point(8,.5,0),h.config)); h.survey.state="succeeded"; h.drain(1)
    local old_search=h.search; assert(old_search and old_search.calls==1)
    h.controller:disconnect("alice")
    assert(old_search.cancelled and not h.controller.active)
    h.drain(5); assert(h.composed==0 and h.controller:status("alice").state=="idle")
end)

test("scheduler errors cancel in-flight services and compact terminal state",function()
    local options={schedule_error=true}; local h=harness(options)
    h.controller:start_endpoint("alice",point(0,.5,0))
    local id,err=h.controller:plan("alice",point(8,.5,0),h.config)
    assert(not id and err.code=="survey_failed")
    assert(h.survey.cancelled and not h.controller.active)
    local r=h.controller.reports.alice
    assert(r.search==nil and r.terrain==nil and r.route==nil and r.plan==nil and r.config==nil)
end)

test("public commands require server privilege, warn about generation, and omit build",function()
    local h=harness(); local registered={}
    local player={get_pos=function() return point(1,1.5,2) end,
        get_properties=function() return {collisionbox={-0.3,-1,-.3,.3,1,.3}} end}
    local engine={register_chatcommand=function(name,def) registered[name]=def end,
        get_player_by_name=function() return player end}
    local surface={player_feet=function(p) return point(p:get_pos().x,p:get_pos().y-1,p:get_pos().z) end}
    assert(commands.register(engine,h.controller,surface,function() return h.config end))
    for _,name in ipairs({"roads_start","roads_plan","roads_status","roads_cancel"}) do
        assert(registered[name] and registered[name].privs.server)
    end
    assert(not registered.roads_build)
    assert(registered.roads_plan.description:find("generate new terrain",1,true))
    local ok,message=registered.roads_start.func("alice")
    assert(ok and message:find("First endpoint",1,true))
    ok,message=registered.roads_plan.func("alice")
    assert(ok and message:find("generate new terrain",1,true))
    ok,message=registered.roads_status.func("alice")
    assert(ok and message:find("surveying",1,true))
    ok,message=registered.roads_cancel.func("alice")
    assert(ok and message:find("cancelled",1,true))
end)

test("preview command is privileged, owner-only, and displays an available ready plan",function()
    local h=harness(); local registered,particles={},{}
    local player={get_pos=function() return point(1,1.5,2) end,
        get_properties=function() return {collisionbox={-0.3,-1,-.3,.3,1,.3}} end}
    local engine={register_chatcommand=function(name,def) registered[name]=def end,
        get_player_by_name=function(name) return name=="alice" and player or nil end,
        add_particle=function(def) particles[#particles+1]=def end}
    local surface={player_feet=function(p) return point(p:get_pos().x,p:get_pos().y-1,p:get_pos().z) end}
    local renderer=assert(preview.new(engine,function() return h.time end))
    assert(commands.register(engine,h.controller,surface,function() return h.config end,renderer))
    assert(registered.roads_preview and registered.roads_preview.privs.server)
    local ok,message=registered.roads_preview.func("alice")
    assert(not ok and message:find("no road plan",1,true))
    h.controller:start_endpoint("alice",point(0,.5,0)); h.controller:plan("alice",point(8,.5,0),h.config)
    h.survey.state="succeeded"; h.drain()
    ok,message=registered.roads_preview.func("alice")
    assert(ok and message:find("temporary route markers",1,true) and #particles>=2)
    assert(particles[1].playername=="alice" and particles[1].expirationtime==8)
    local count=#particles
    ok,message=registered.roads_preview.func("alice")
    assert(not ok and message:find("wait",1,true) and #particles==count)
    ok,message=registered.roads_preview.func("bob")
    assert(not ok and message:find("online player",1,true))
end)

test("built owner plan remains previewable and other players cannot access its route",function()
    local h=harness(); h.controller:start_endpoint("alice",point(0,.5,0))
    h.controller:plan("alice",point(8,.5,0),h.config); h.survey.state="succeeded"; h.drain()
    local line=assert(h.controller:preview_route("alice")); assert(#line>=2 and line[1].x==0 and line[#line].x==8)
    local other,err=h.controller:preview_route("bob")
    assert(not other and err.code=="not_owner")
    h.controller.active.state="built"
    h.controller.reports.alice=h.controller.active; h.controller.active=nil
    assert(#assert(h.controller:preview_route("alice"))==#line)
end)

test("production VoxeLibre bounds reach survey service and permit padded flat-world survey",function()
    local engine={get_mapgen_setting=function(name)
        return name=="mg_name" and "flat" or "5"
    end}
    local vars={chunksize=5,central_chunk_offset_in_nodes=-32,chunk_size_in_nodes=80,
        mapgen_edge_min=-30912,mapgen_edge_max=31007,mg_overworld_min=9,
        mg_overworld_max=31007,mg_realm_barrier_overworld_end_min=-2020,
        mg_realm_barrier_overworld_end_max=-2009}
    local world=assert(voxelibre.world_config(engine,vars))
    assert(world.dimension_bounds.min_y==9 and world.dimension_bounds.max_y==31000)
    assert(world.safe_generation_bounds.min_y==-2008 and world.chunk_origin.y==-32)
    local bounds=assert(survey.plan(point(0,12,0),point(32,12,0),world))
    assert(bounds.requested_bounds.min_y==-36 and bounds.chunk_bounds.min_y==-112)
    local h=harness()
    h.controller:start_endpoint("alice",point(0,.5,0))
    local full={world=world,planner={road_material="cobble"},composition={road_material="cobble"}}
    assert(h.controller:plan("alice",point(8,.5,0),full))
    assert(h.survey_args.config.dimension_bounds.min_y==9
        and h.survey_args.config.safe_generation_bounds.min_y==-2008
        and h.survey_args.config.chunk_origin.y==-32)
end)

print("ok - "..count.." route job/command tests")
