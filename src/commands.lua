-- SPDX-License-Identifier: GPL-3.0-or-later
-- Privileged chat-command adapters; all state and work live in src/jobs.lua.
local commands={}

local function fmt_point(p)
    if type(p)~="table" then return "unknown" end
    return string.format("(%.1f, %.1f, %.1f)",p.x,p.y,p.z)
end
local function path_length(path,previous)
    local length=0
    for _,p in ipairs(path or {}) do
        if previous then
            local dx,dy,dz=p.x-previous.x,p.y-previous.y,p.z-previous.z
            length=length+math.sqrt(dx*dx+dy*dy+dz*dz)
        end
        previous=p
    end
    return length
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
        for _,key in ipairs({"start","goal"}) do
            local endpoint=e[key]
            local label=key=="start" and "Start" or "Goal"
            lines[#lines+1]=label.." selected "..fmt_point(endpoint.requested)..", natural landing "..fmt_point(endpoint.resolved).."."
            local c=endpoint.connector
            if c then
                local dx=endpoint.resolved.x-endpoint.requested.x
                local dy=endpoint.resolved.y+0.5-endpoint.requested.y
                local dz=endpoint.resolved.z-endpoint.requested.z
                local displacement=math.sqrt(dx*dx+dy*dy+dz*dz)
                local path=c.path or {}; local transition=c.transition or {}
                local preserved_length=path_length(path)
                local transition_length=path_length(transition.path,path[#path])
                lines[#lines+1]=string.format("%s connector: %.1f nodes displacement, %.1f nodes preserved path, %.1f nodes transition.",
                    label,displacement,preserved_length,transition_length)
            end
        end
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
    if status.build_metrics then
        lines[#lines+1]=string.format("Construction: %d writes, %.3f seconds synchronous pause.",
            status.build_metrics.writes or 0,status.build_metrics.pause_seconds or 0)
    end
    if status.metrics then
        lines[#lines+1]=string.format("Route: cost %.1f, length %.1f, max grade %.3f, cuts %d, fills %d.",
            status.cost or 0,status.metrics.length or 0,status.metrics.max_grade or 0,
            status.metrics.cut_count or 0,status.metrics.fill_count or 0)
    end
    return table.concat(lines," ")
end

local function fmt_target(t)
    if type(t)~="table" or type(t.x)~="number" or type(t.z)~="number" then return "unknown" end
    return string.format("(%d, %d)",t.x,t.z)
end
local HEADING_VECTORS={{1,0},{1,1},{0,1},{-1,1},{-1,0},{-1,-1},{0,-1},{1,-1}}
local WAYPOINT_STRIDE,MAX_WAYPOINTS=16,8

-- Indices of a bounded sample: start, every WAYPOINT_STRIDE-th node, end. When
-- that is still too many, MAX_WAYPOINTS evenly spaced nodes span the route.
local function waypoint_indices(n)
    if n<1 then return {} end
    local picks={}
    for i=1,n,WAYPOINT_STRIDE do picks[#picks+1]=i end
    if picks[#picks]~=n then picks[#picks+1]=n end
    if #picks<=MAX_WAYPOINTS then return picks end
    local even={}
    for j=0,MAX_WAYPOINTS-1 do even[#even+1]=1+math.floor(j*(n-1)/(MAX_WAYPOINTS-1)+0.5) end
    return even
end

local function outward_route(s)
    local r=s.road
    if type(r)~="table" or type(r.centerline)~="table" or #r.centerline==0 then return nil end
    return r.centerline
end

-- One precise failure as text. Every sentence ends with a full stop.
local function failure(e)
    local parts={tostring(e.code)..": "..tostring(e.reason)}
    if e.limit~=nil then parts[#parts+1]="(limit "..tostring(e.limit)..", observed "..tostring(e.observed)..")" end
    if e.position then parts[#parts+1]="at "..fmt_point(e.position) end
    local text=table.concat(parts," ")
    if text:sub(-1)~="." then text=text.."." end
    for _,b in ipairs(type(e.blocked)=="table" and e.blocked or {}) do
        text=text.." "..tostring(b.settlement_id).." is "..tostring(b.state).."."
    end
    for _,s in ipairs(type(e.skipped)=="table" and e.skipped or {}) do
        text=text.." Exit "..tostring(s.exit_id).." is "..tostring(s.state)..(s.reason and (" ("..s.reason..")") or "").."."
    end
    return text
end

-- Presentation of an outward-road service summary (see src/outward.lua status).
function commands.outward_summary(s)
    if type(s)~="table" then return "No outward road is active or recorded for this settlement." end
    local head="Outward road "..tostring(s.op_id)..": "..tostring(s.state)
    if s.active then head=head..", stage "..tostring(s.stage) end
    local lines={head.."."}
    lines[#lines+1]=string.format("Settlement %s, exit %s, requested by %s.",
        tostring(s.settlement_id),tostring(s.exit_id),tostring(s.requester))
    if type(s.candidates)=="table" and #s.candidates>0 then
        local targets={}
        for i,t in ipairs(s.candidates) do targets[i]=fmt_target(t) end
        lines[#lines+1]="Targets "..table.concat(targets,", ")..(s.current_target and (", trying "..fmt_target(s.current_target)) or "").."."
    end
    for _,a in ipairs(type(s.attempts)=="table" and s.attempts or {}) do
        lines[#lines+1]=string.format("Attempt %d to %s: %s%s.",a.index or 0,fmt_target(a.target),
            tostring(a.outcome),a.reason and (" - "..tostring(a.reason)) or "")
    end
    local r=s.road
    if r then
        local m=r.metrics or {}
        lines[#lines+1]=string.format("Road to %s, resolved %s, terminal %s: length %.1f, ascent %d, descent %d, max grade %.3f, turns %d, cuts %d, fills %d, %d writes.",
            fmt_target(r.requested_target),fmt_target(r.resolved_target),fmt_target(r.terminal),
            m.length or 0,m.ascent or 0,m.descent or 0,m.max_grade or 0,m.turns or 0,m.cuts or 0,m.fills or 0,r.write_count or 0)
    end
    local a=s.aggregate
    if type(a)=="table" and (a.chunks or 0)>0 then
        lines[#lines+1]=string.format("Aggregate: %d chunks (%d requests), %d expansions, survey %.1f s, search %.1f s, longest slice %.3f s, peak states %d, peak heap %d.",
            a.chunks or 0,a.chunk_requests or 0,a.expansions or 0,a.survey_seconds or 0,a.search_seconds or 0,
            a.longest_slice or 0,a.peak_states or 0,a.peak_heap_entries or 0)
    elseif type(a)=="table" and (a.expansions or 0)>0 then
        lines[#lines+1]=string.format("Aggregate: %d expansions, search %.1f s, peak states %d.",
            a.expansions or 0,a.search_seconds or 0,a.peak_states or 0)
    end
    if type(a)=="table" and a.limit_reached then
        lines[#lines+1]="Shared "..tostring(a.limit_reached).." budget reached (limit "..tostring(a.limit)..", observed "..tostring(a.observed)..")."
    end
    if r and type(r.centerline)=="table" and #r.centerline>0 then
        local line=r.centerline
        local pts={}
        for _,i in ipairs(waypoint_indices(#line)) do pts[#pts+1]=fmt_point(line[i]) end
        local hv=HEADING_VECTORS[(tonumber(r.terminal_heading) or 0)+1] or {0,0}
        lines[#lines+1]=string.format("Route geometry: landing %s, outward (%d, %d); %d centreline nodes, waypoints %s; terminal %s, heading %s toward (%d, %d).",
            fmt_point(r.landing),(r.outward or {}).x or 0,(r.outward or {}).z or 0,#line,table.concat(pts,", "),
            fmt_point(r.terminal),tostring(r.terminal_heading),hv[1],hv[2])
    end
    if s.writes then lines[#lines+1]="Writes: "..tostring(s.writes).."." end
    if s.build then
        lines[#lines+1]=string.format("Construction: %d writes, %.3f seconds synchronous pause.",s.build.writes or 0,s.build.pause_seconds or 0)
    end
    if s.error then lines[#lines+1]="Error "..failure(s.error) end
    if s.cancelled_by then lines[#lines+1]="Cancelled by "..tostring(s.cancelled_by).."." end
    if s.persisted==false then lines[#lines+1]="Warning: the record could not be saved and may not survive a restart." end
    return table.concat(lines," ")
end

-- outward (optional) = {service, towns, policy, seed=function() -> string};
-- without it /roads_outward is not registered and status/cancel stay manual.
function commands.register(engine,controller,surface,world_config,preview_renderer,outward)
    if type(engine)~="table" or type(engine.register_chatcommand)~="function"
        or type(controller)~="table" or type(surface)~="table"
        or type(surface.player_feet)~="function" or type(world_config)~="function" then
        return nil,"command dependencies are incomplete"
    end
    if outward~=nil and (type(outward)~="table" or type(outward.service)~="table"
        or type(outward.towns)~="table" or type(outward.policy)~="table" or type(outward.seed)~="function") then
        return nil,"outward command dependencies are incomplete"
    end
    -- Settlement each player last requested, so /roads_status can report it after the run ends (memory only).
    local last_outward={}
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
    register("roads_status","Show your road planning status, or the outward road status",function(name)
        local manual=controller:status(name)
        if outward then
            local active=outward.service:status()
            if active then return true,commands.outward_summary(active) end
            local settlement=last_outward[name]
            if manual.state=="idle" and settlement then
                local latest=outward.service:status(settlement)
                if latest then return true,commands.outward_summary(latest) end
            end
        end
        return true,summary(manual)
    end)
    register("roads_cancel","Cancel your road planning job, discard its unbuilt plan, or cancel an active outward road",function(name)
        if outward and outward.service:status() then
            local ok,err=outward.service:cancel(name)
            if not ok then return false,failure(err) end
            return true,"Outward road cancelled and its server slot released."
        end
        local ok,err=controller:cancel(name)
        if not ok then return false,err.reason end
        return true,"Road planning cancelled and its server slot released."
    end)
    if outward then
        -- Explicit trigger only: this may generate terrain and builds one road
        -- automatically. There are no endpoint or build steps.
        register("roads_outward","Automatically build one outward road from a completed Towns settlement. This may generate terrain and automatically builds a road; no endpoint selection or build step is needed.",function(name)
            local feet,err=player(name); if not feet then return false,err end
            local service=outward.service
            local active=service:status()
            if active then
                return false,"busy: outward road "..tostring(active.op_id).." is "..tostring(active.stage or active.state)
                    ..". Use /roads_status or /roads_cancel."
            end
            local seed=outward.seed()
            if not ((type(seed)=="string" and seed~="") or type(seed)=="number") then
                return false,"unavailable: the world seed could not be read"
            end
            local settlements,why=outward.towns:nearby({x=feet.x,z=feet.z},outward.policy.RADIUS)
            if not settlements then return false,failure(why) end
            local chosen,choice_error=outward.policy.select({requester=feet,world_seed=seed,settlements=settlements,
                exit=function(settlement,exit_id) return outward.towns:exit(settlement,exit_id) end,
                eligibility=function(settlement_id,exit_id) return service:eligibility(settlement_id,exit_id) end})
            if not chosen then return false,failure(choice_error) end
            local started,start_error=service:start({settlement_id=chosen.settlement_id,exit_id=chosen.exit_id,
                requester=name,policy=chosen.policy,candidates=chosen.candidates})
            if not started then return false,failure(start_error) end
            last_outward[name]=chosen.settlement_id
            local targets={}
            for i,t in ipairs(chosen.candidates) do targets[i]=fmt_target(t) end
            return true,string.format("Outward road %s started: settlement %s, exit %s, %.1f nodes from the requester, targets %s. It may generate terrain and builds one road automatically; use /roads_status to follow it.",
                tostring(started.op_id),chosen.settlement_id,chosen.exit_id,chosen.settlement_distance,table.concat(targets,", "))
        end)
    end
    register("roads_build","Build your planned road",function(name)
        if not engine.get_player_by_name(name) then return false,"This command requires an online player." end
        local ok,why=controller:build(name)
        if not ok then return false,tostring(why.code)..": "..tostring(why.reason) end
        return true,"Road construction started; use /roads_status to check progress."
    end)
    if preview_renderer then
        register("roads_preview","Show your route as a temporary particle preview",function(name)
            if not engine.get_player_by_name(name) then return false,"This command requires an online player." end
            local route,why,endpoints=controller:preview_route(name)
            if not route and outward and last_outward[name] then
                -- No manual plan: show the centreline of this player's last outward road.
                local latest=outward.service:status(last_outward[name])
                route=outward_route(latest or {})
                endpoints=nil
            end
            if not route then return false,why.reason end
            local count,preview_error=preview_renderer:show(name,route,endpoints)
            if not count then return false,preview_error.reason end
            return true,string.format("Showing %d temporary route markers for 30 seconds. Look above the road.",count)
        end)
    end
    return true
end

commands.summary=summary
return commands
