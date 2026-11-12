-- SPDX-License-Identifier: GPL-3.0-or-later
-- Privileged chat-command adapters; all state and work live in src/jobs.lua.
local commands={}

local function fmt_point(p)
    if type(p)~="table" then return "unknown" end
    return string.format("(%.1f, %.1f, %.1f)",p.x,p.y,p.z)
end
local function summary(status)
    local state=status.state or "idle"
    if state=="idle" then return "No road plan is active." end
    local lines={"Road plan "..state.."."}
    if status.error then
        lines[#lines+1]=tostring(status.error.code)..": "..tostring(status.error.reason)
    end
    local e=status.endpoints
    if e then
        lines[#lines+1]="Start requested "..fmt_point(e.start.requested)..", resolved "..fmt_point(e.start.resolved).."."
        lines[#lines+1]="Goal requested "..fmt_point(e.goal.requested)..", resolved "..fmt_point(e.goal.resolved).."."
    elseif status.requested_endpoints then
        lines[#lines+1]="Start requested "..fmt_point(status.requested_endpoints.start)..", not yet resolved."
        lines[#lines+1]="Goal requested "..fmt_point(status.requested_endpoints.goal)..", not yet resolved."
    end
    local sm=status.survey_metrics
    if sm then lines[#lines+1]=string.format("Survey: %d/%d chunks, %d columns, %d tiles.",
        sm.chunks_completed or 0,sm.chunks_total or 0,sm.columns_completed or 0,sm.tiles_completed or 0) end
    local pm=status.search_metrics
    if pm then lines[#lines+1]=string.format("Search: %d expansions, %d states.",pm.expansions or 0,pm.states or 0) end
    local search_error = status.error and status.error.code
    if (search_error=="bounded_no_route" or search_error=="expansion_budget"
        or search_error=="state_budget" or search_error=="heap_budget")
        and pm and type(pm.rejections)=="table" then
        local rejected={}
        for code,count in pairs(pm.rejections) do
            if type(code)=="string" and type(count)=="number" and count>0 then
                rejected[#rejected+1]={code=code,count=count}
            end
        end
        table.sort(rejected,function(a,b)
            if a.count~=b.count then return a.count>b.count end
            return a.code<b.code
        end)
        local details={}
        for i=1,math.min(3,#rejected) do
            details[#details+1]=rejected[i].code.." "..rejected[i].count
        end
        if #details>0 then lines[#lines+1]="Most common rejected edges: "..table.concat(details,", ").."." end
    end
    if status.metrics then
        lines[#lines+1]=string.format("Route: cost %.1f, length %.1f, max grade %.3f, cuts %d, fills %d.",
            status.cost or 0,status.metrics.length or 0,status.metrics.max_grade or 0,
            status.metrics.cut_count or 0,status.metrics.fill_count or 0)
    end
    return table.concat(lines," ")
end

function commands.register(engine,controller,surface,world_config,preview_renderer)
    if type(engine)~="table" or type(engine.register_chatcommand)~="function"
        or type(controller)~="table" or type(surface)~="table"
        or type(surface.player_feet)~="function" or type(world_config)~="function" then
        return nil,"command dependencies are incomplete"
    end
    local function player(name)
        local p=engine.get_player_by_name(name)
        if not p then return nil,"This command requires an online player." end
        local feet=surface.player_feet(p)
        if not feet then return nil,"Could not read your player position." end
        return feet
    end
    local function register(name,description,func)
        engine.register_chatcommand(name,{params="",description=description,privs={server=true},func=func})
    end
    register("roads_start","Select your first road endpoint",function(name)
        local feet,err=player(name); if not feet then return false,err end
        local selected,why=controller:start_endpoint(name,feet)
        if not selected then return false,why.reason end
        return true,"First endpoint selected at "..fmt_point(selected)..". Travel to the destination and use /roads_plan."
    end)
    register("roads_plan","Plan a route to your current position; surveying can generate new terrain",function(name)
        local feet,err=player(name); if not feet then return false,err end
        local ok,config,config_error=pcall(world_config)
        if not ok or not config then return false,(config_error and config_error.reason) or tostring(config or config_error) end
        local id,why=controller:plan(name,feet,config)
        if not id then return false,tostring(why.code)..": "..tostring(why.reason) end
        return true,"Road planning job "..id.." started. Surveying can generate new terrain; use /roads_status to check progress."
    end)
    register("roads_status","Show your road planning status",function(name)
        return true,summary(controller:status(name))
    end)
    register("roads_cancel","Cancel your road planning job or discard its unbuilt plan",function(name)
        local ok,err=controller:cancel(name)
        if not ok then return false,err.reason end
        return true,"Road planning cancelled and its server slot released."
    end)
    if preview_renderer then
        register("roads_preview","Show your route as a temporary particle preview",function(name)
            if not engine.get_player_by_name(name) then return false,"This command requires an online player." end
            local route,why=controller:preview_route(name)
            if not route then return false,why.reason end
            local count,preview_error=preview_renderer:show(name,route)
            if not count then return false,preview_error.reason end
            return true,string.format("Showing %d temporary route markers for 30 seconds. Look above the road.",count)
        end)
    end
    return true
end

commands.summary=summary
return commands
