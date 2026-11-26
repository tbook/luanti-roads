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
    return r.centerline,r.endpoints
end

-- One precise failure as text. Every sentence ends with a full stop.
local function failure(e)
    local parts={tostring(e.code)..": "..tostring(e.reason)}
    if e.limit~=nil then parts[#parts+1]="(limit "..tostring(e.limit)..", observed "..tostring(e.observed)..")" end
    if e.position then parts[#parts+1]="at "..fmt_point(e.position) end
    local text=table.concat(parts," ")
    if text:sub(-1)~="." then text=text.."." end
    for _,b in ipairs(type(e.blocked)=="table" and e.blocked or {}) do
        text=text.." "..tostring(b.settlement_id).." "..(b.reason or ("is "..tostring(b.state))).."."
    end
    for _,s in ipairs(type(e.skipped)=="table" and e.skipped or {}) do
        text=text..(s.settlement_id and (" Settlement "..tostring(s.settlement_id).." exit ") or " Exit ")
            ..tostring(s.exit_id).." is "..tostring(s.state)..(s.reason and (" ("..s.reason..")") or "").."."
    end
    for _,s in ipairs(type(e.no_exits)=="table" and e.no_exits or {}) do
        text=text.." Settlement "..tostring(s.settlement_id).." "..tostring(s.reason or "has no usable exits").."."
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

-- Growth command family (/roads_grow). Its text is bounded: the service keeps
-- only the latest attempts and every list shown here is capped.
local GROW_PREFIX="growth:v1:"
local GROW_ACTIONS={adopt=true,extend=true,status=true,cancel=true,retry=true,retire=true,inspect=true}
local GROW_USAGE="Usage: /roads_grow adopt <outward-op-id> | extend|status|cancel|retry|retire|inspect <road-id>."
local GROW_ITEMS=4

local function growth_target(t)
    if t.kind=="destination" then
        return "destination "..tostring(t.approach_id).." ("..tostring(t.mode)..")"
    end
    return tostring(t.length).." node fallback"
end

-- Scan, selection and rejection lines of a growth summary.
function commands.growth_destination_lines(s)
    local lines={}
    local scan=s.scan
    if type(scan)~="table" then
        lines[1]="Destinations: no scan is recorded yet."
        return lines
    end
    if scan.status=="disabled" then
        lines[1]="Destinations: scan disabled (no destination provider is installed); growth targets the preferred direction only."
    else
        local names={}
        for _,kind in ipairs({"town","village","road"}) do
            if scan.providers and scan.providers[kind] then names[#names+1]=kind.."="..tostring(scan.providers[kind]) end
        end
        lines[1]=string.format("Destinations: scan %s (%s); %d descriptors inspected.",tostring(scan.status),
            table.concat(names,", "),tonumber(scan.inspected) or 0)
    end
    local candidates=type(s.candidates)=="table" and s.candidates or {}
    if #candidates==0 then
        lines[#lines+1]="Selected: none; directional fallback (96 then 64 nodes) is attempted."
    else
        for i,c in ipairs(candidates) do
            lines[#lines+1]=string.format("%s: %s %s approach %s, %s attachment, %s nodes away%s.",i==1 and "Selected" or "Next candidate",
                tostring(c.kind),tostring(c.id),tostring(c.approach_id),tostring(c.mode),tostring(c.distance),
                c.mode=="waypoint" and " (waypoint: partial progress only)" or "")
        end
        lines[#lines+1]="Directional fallback (96 then 64 nodes) follows if no destination attempt succeeds."
    end
    local rejected=type(s.rejected)=="table" and s.rejected or {}
    local total=tonumber(scan.rejected_total) or #rejected
    for i=1,math.min(#rejected,GROW_ITEMS) do
        lines[#lines+1]="Rejected "..tostring(rejected[i].kind).." approach "..tostring(rejected[i].approach_id)..": "..tostring(rejected[i].reason).."."
    end
    if total>math.min(#rejected,GROW_ITEMS) then lines[#lines+1]=(total-math.min(#rejected,GROW_ITEMS)).." more rejected destinations are not listed." end
    return lines
end

-- Presentation of a growth-service summary (see src/growth.lua status).
function commands.growth_summary(s)
    if type(s)~="table" then return "No growth road is recorded for this identifier." end
    local hv=HEADING_VECTORS[(tonumber(s.local_heading) or 0)+1] or {0,0}
    local pv=s.preferred or {}
    local src=s.source or {}
    local segments=tonumber(s.segments) or 0
    local lines={string.format("Growth road %s: %s, revision %s, endpoint %s, %d %s.",
        tostring(s.road_id),tostring(s.state),tostring(s.revision),fmt_point(s.endpoint),segments,segments==1 and "segment" or "segments")}
    lines[#lines+1]=string.format("Local heading %s toward (%d, %d); preferred outward (%d, %d) from settlement %s exit %s, outward operation %s.",
        tostring(s.local_heading),hv[1],hv[2],pv.x or 0,pv.z or 0,tostring(src.settlement_id),tostring(src.exit_id),tostring(s.origin_op_id))
    if s.active then
        lines[#lines+1]="Current cycle: stage "..tostring(s.stage)..(s.pending and (", segment "..tostring(s.pending.segment_id)) or "").."."
    elseif s.pending then
        lines[#lines+1]="Unfinished segment "..tostring(s.pending.segment_id)..": "..tostring(s.pending.state)..", writes "..tostring(s.pending.writes).."."
    elseif s.last_segment_id then
        lines[#lines+1]="Last segment "..tostring(s.last_segment_id).."."
    end
    for _,line in ipairs(commands.growth_destination_lines(s)) do lines[#lines+1]=line end
    local attempts=type(s.attempts)=="table" and s.attempts or {}
    for i=math.max(1,#attempts-GROW_ITEMS+1),#attempts do
        local a=attempts[i]
        local targets={}
        for _,t in ipairs(type(a.targets)=="table" and a.targets or {}) do
            targets[#targets+1]=growth_target(t).." "..tostring(t.outcome)..(t.reason and (" - "..tostring(t.reason)) or "")
        end
        lines[#lines+1]=string.format("Attempt on %s from revision %s: %s%s%s; %d chunks, %d expansions.",
            tostring(a.segment_id),tostring(a.from_revision),tostring(a.outcome),a.result and (" ("..tostring(a.result)..")") or "",
            #targets>0 and ("; "..table.concat(targets,"; ")) or "",a.chunks or 0,a.expansions or 0)
    end
    local b=type(s.budgets)=="table" and s.budgets or {}
    lines[#lines+1]=string.format("Limits per cycle: %s chunks (%s for destinations, %s reserved for fallback), %s expansions (%s per destination attempt, %s reserved for fallback), %s attempts%s.",
        tostring(b.chunks),tostring(b.destination_chunks),tostring(b.reserved_chunks),tostring(b.expansions),
        tostring(b.destination_expansions),tostring(b.reserved_expansions),tostring(b.attempts),
        s.active and string.format(" (used %d chunks, %d expansions)",b.used_chunks or 0,b.used_expansions or 0) or "")
    if s.stop then
        lines[#lines+1]=(s.state=="stopped" and "Blocked: " or "Stop: ")..failure(s.stop)
        local attempted={}
        for _,e in ipairs(type(s.stop.attempted)=="table" and s.stop.attempted or {}) do
            attempted[#attempted+1]=growth_target(e).." "..tostring(e.outcome)
        end
        if #attempted>0 then lines[#lines+1]="Attempted: "..table.concat(attempted,"; ").."." end
    end
    if s.connected then
        local how=s.connected.junction=="t" and " by a T junction" or s.connected.junction=="end" and " end to end" or ""
        lines[#lines+1]=string.format("Connected to %s %s%s (approach %s).",tostring(s.connected.kind),tostring(s.connected.id),how,tostring(s.connected.approach_id))
    end
    if s.retired then lines[#lines+1]=string.format("Retired by %s; was %s.",tostring(s.retired.by),tostring(s.retired.was)) end
    if s.explanation then lines[#lines+1]=s.explanation end
    lines[#lines+1]="Seam: not compared here; /roads_grow inspect compares the intended seam with the world. Adopt, extend and retry refuse an edited seam."
    return table.concat(lines," ")
end

-- Presentation of a growth inspect report: the summary plus the world comparison.
function commands.growth_inspect(r)
    if type(r)~="table" then return "No growth report is available." end
    local lines={commands.growth_summary(r)}
    local w=type(r.world)=="table" and r.world or {}
    if w.status=="unknown" then
        lines[#lines+1]="World: unknown"..(w.reason and (" ("..tostring(w.reason)..")") or "").."."
    else
        lines[#lines+1]="World: "..tostring(w.status).." against the "..tostring(w.intended)..(w.segment_id and (" of "..tostring(w.segment_id)) or "").."."
        local c=w.comparison
        if type(c)=="table" then
            lines[#lines+1]=string.format("Checked %d preserved nodes: %d differ or are unreadable%s.",
                c.checked or 0,c.mismatched or 0,c.loaded and "" or "; the seam mapblocks were not loaded")
            local samples=type(c.samples)=="table" and c.samples or {}
            for i=1,math.min(#samples,GROW_ITEMS) do
                local x=samples[i]
                lines[#lines+1]="Node "..fmt_point(x).." expected "..tostring(x.expected)..": "..tostring(x.reason).."."
            end
        end
    end
    local a=type(r.world)=="table" and r.world.attachment or nil
    if type(a)=="table" then
        lines[#lines+1]=string.format("Attachment: checked %d exit and transition nodes: %d differ or are unreadable (%s). "
            .."Inspection only compares; the walking path is not re-walked and nothing is promoted or repaired.",
            a.checked or 0,a.mismatched or 0,a.matches and "matches the intended geometry" or "mismatch")
        local samples=type(a.samples)=="table" and a.samples or {}
        for i=1,math.min(#samples,GROW_ITEMS) do
            local x=samples[i]
            lines[#lines+1]="Attachment node "..fmt_point(x).." expected "..tostring(x.expected)..": "..tostring(x.reason).."."
        end
    end
    local counts,order={},{}
    for _,seg in ipairs(type(r.segments_state)=="table" and r.segments_state or {}) do
        local state=tostring(seg.state)
        if not counts[state] then counts[state]=0; order[#order+1]=state end
        counts[state]=counts[state]+1
    end
    table.sort(order)
    local parts={}
    for _,state in ipairs(order) do parts[#parts+1]=counts[state].." "..state end
    if #parts>0 then lines[#lines+1]="Segments by state: "..table.concat(parts,", ").."." end
    -- Reservations of this road: exit, endpoint and road-join interval claims.
    local claim_counts,claim_order={}, {}
    for _,claim in ipairs(type(r.claims)=="table" and r.claims or {}) do
        local label=tostring(claim.kind).." "..tostring(claim.state)
        if not claim_counts[label] then claim_counts[label]=0; claim_order[#claim_order+1]=label end
        claim_counts[label]=claim_counts[label]+1
    end
    table.sort(claim_order)
    local claim_parts={}
    for _,label in ipairs(claim_order) do claim_parts[#claim_parts+1]=claim_counts[label].." "..label end
    if #claim_parts>0 then
        local total=tonumber(r.claims_total) or #r.claims
        lines[#lines+1]="Claims held by this road: "..total.." ("..table.concat(claim_parts,", ")..(total>#r.claims and "; first "..#r.claims.." shown" or "").."). Uncertain claims are never released automatically."
    end
    if r.note then lines[#lines+1]=r.note end
    return table.concat(lines," ")
end

-- outward (optional) = {service, towns, policy, seed=function() -> string};
-- without it /roads_outward is not registered and status/cancel stay manual.
-- growth (optional) = {service}; without it /roads_grow is not registered.
function commands.register(engine,controller,surface,world_config,preview_renderer,outward,growth)
    if type(engine)~="table" or type(engine.register_chatcommand)~="function"
        or type(controller)~="table" or type(surface)~="table"
        or type(surface.player_feet)~="function" or type(world_config)~="function" then
        return nil,"command dependencies are incomplete"
    end
    if outward~=nil and (type(outward)~="table" or type(outward.service)~="table"
        or type(outward.towns)~="table" or type(outward.policy)~="table" or type(outward.seed)~="function") then
        return nil,"outward command dependencies are incomplete"
    end
    if growth~=nil and (type(growth)~="table" or type(growth.service)~="table") then
        return nil,"growth command dependencies are incomplete"
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
    if growth then
        -- Arguments are checked here; the service owns every state decision and
        -- returns its own error codes. Nothing is written for a bad request.
        local service=growth.service
        local function with_status(text,road_id)
            local s,err=service:status(road_id)
            if not s then return text.." "..failure(err) end
            return text.." "..commands.growth_summary(s)
        end
        engine.register_chatcommand("roads_grow",{params="adopt <outward-op-id> | extend|status|cancel|retry|retire|inspect <road-id>",
            description="Adopt a built outward road for growth, or extend, inspect, cancel, retry or retire a growth road. Extending or retrying may generate terrain and builds one segment; growth is never automatic.",
            privs={server=true},
            func=function(name,param)
                local words={}
                for word in tostring(param or ""):gmatch("%S+") do words[#words+1]=word end
                local action,id=words[1],words[2]
                if not action then return false,"invalid_request: missing action. "..GROW_USAGE end
                if not GROW_ACTIONS[action] then return false,"invalid_request: unknown action "..action..". "..GROW_USAGE end
                if #words~=2 then return false,"invalid_request: "..action.." takes exactly one argument. "..GROW_USAGE end
                if action=="adopt" then
                    local road_id,err=service:adopt(id,name)
                    if not road_id then return false,failure(err) end
                    return true,with_status("Growth road "..road_id.." is adopted from outward operation "..id..". Adopting it again changes nothing.",road_id)
                end
                if id:sub(1,#GROW_PREFIX)~=GROW_PREFIX then
                    return false,"invalid_request: a growth road id starts with "..GROW_PREFIX..". "..GROW_USAGE
                end
                if action=="extend" then
                    local cycle,err=service:extend(id,name)
                    if not cycle then return false,failure(err) end
                    return true,with_status("Growth cycle "..cycle.." started. It may generate terrain and builds at most one segment.",id)
                elseif action=="status" then
                    local s,err=service:status(id)
                    if not s then return false,failure(err) end
                    return true,commands.growth_summary(s)
                elseif action=="cancel" then
                    local ok,err=service:cancel(id,name)
                    if not ok then return false,failure(err) end
                    -- A cancel after the builder entered leaves the road uncertain; do not
                    -- promise anything beyond what the stored state says.
                    local after=service:status(id)
                    local tail=after and after.state=="uncertain" and "Writes are unknown and every reservation is kept."
                        or "No writes were made; the server slot is released."
                    return true,with_status("Growth cycle for "..id.." cancelled by "..name..". "..tail,id)
                elseif action=="retry" then
                    local cycle,err=service:retry(id,name)
                    if not cycle then return false,failure(err) end
                    return true,with_status("Retry started as growth cycle "..cycle..". It may generate terrain and builds at most one segment.",id)
                elseif action=="retire" then
                    local ok,err=service:retire(id,name)
                    if not ok then return false,failure(err) end
                    return true,with_status("Growth road "..id.." is retired; every reservation is kept.",id)
                end
                local report,err=service:inspect(id,name)
                if not report then return false,failure(err) end
                return true,commands.growth_inspect(report)
            end})
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
                route,endpoints=outward_route(latest or {})
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
