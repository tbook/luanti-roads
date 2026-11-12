-- SPDX-License-Identifier: GPL-3.0-or-later
-- Owns endpoint selections and the server-wide survey/search/plan lifecycle.
local jobs = {}

local function copy(value)
    if type(value) ~= "table" then return value end
    local result={}
    for k,v in pairs(value) do result[k]=copy(v) end
    return result
end
local function error_result(code,reason,extra)
    local result=extra or {}; result.code=code; result.reason=reason; return result
end
local function finite(n)
    return type(n)=="number" and n==n and n~=math.huge and n~=-math.huge
end
local function valid_feet(p)
    return type(p)=="table" and finite(p.x) and finite(p.y) and finite(p.z)
end

-- ops is deliberately injected so this lifecycle can be tested without Luanti:
-- now, after, start_survey, resolve_endpoints, new_planner, compose, notify.
function jobs.new(ops)
    if type(ops)~="table" or type(ops.now)~="function" or type(ops.after)~="function"
        or type(ops.start_survey)~="function" or type(ops.resolve_endpoints)~="function"
        or type(ops.new_planner)~="function" or type(ops.compose)~="function" then
        return nil,error_result("invalid_config","job lifecycle dependencies are incomplete")
    end
    local self={selections={},reports={},active=nil,next_id=0}

    local function publish(record)
        if ops.notify then pcall(ops.notify,record.owner,self:status(record.owner)) end
    end
    local function cancel_work(record)
        if record.survey and record.state=="surveying" then pcall(record.survey.cancel,record.survey) end
        if record.search and record.state=="searching" then pcall(record.search.cancel,record.search) end
    end
    local function finish(record,status,err,plan,request)
        if record.closed then return end
        if status~="ready" then cancel_work(record) end
        record.closed=true
        record.state=status
        record.error=copy(err)
        record.plan=plan
        record.request=request and copy(request) or record.request
        record.finished_at=ops.now()
        if self.active==record and status~="ready" then self.active=nil end
        -- Keep compact diagnostics and (only for a ready owner) the composed
        -- plan. Never retain the survey snapshot or A* state graph in reports.
        record.survey=nil; record.search=nil; record.terrain=nil; record.route=nil
        record.config=nil
        if status~="ready" then record.plan=nil end
        self.reports[record.owner]=record
        publish(record)
    end
    local function current(record)
        return self.active==record and not record.closed
    end
    local function later(record,fn)
        local ok,err=pcall(ops.after,0.1,function()
            if current(record) then fn() end
        end)
        if not ok then finish(record,"failed",error_result("survey_failed","cannot schedule planning job: "..tostring(err))) end
    end
    local tick_search
    local function begin_search(record,terrain)
        if not current(record) then return end
        local call_ok,endpoint,err=pcall(ops.resolve_endpoints,terrain,record.start_feet,record.goal_feet)
        if not call_ok then err=error_result("survey_failed","endpoint inspection failed: "..tostring(endpoint)); endpoint=nil end
        if not endpoint then finish(record,"failed",err or error_result("invalid_endpoint","endpoint resolution failed")); return end
        record.endpoints=copy(endpoint)
        local request={start=copy(endpoint.start.resolved),goal=copy(endpoint.goal.resolved),provenance=copy(endpoint)}
        record.request=request
        call_ok,endpoint,err=pcall(ops.new_planner,terrain,request,record.config.planner)
        local search,search_error
        if call_ok then search,search_error=endpoint,err
        else search_error=error_result("invalid_config","planner creation failed: "..tostring(endpoint)) end
        if not search then finish(record,"failed",search_error or error_result("invalid_config","planner could not start")); return end
        record.terrain=terrain
        record.search=search
        record.state="searching"
        record.search_started_at=ops.now()
        publish(record)
        tick_search(record)
    end
    tick_search=function(record)
        if not current(record) then return end
        local now=ops.now()
        local ok,result=pcall(record.search.step,record.search,
            {max_expansions=1000,deadline=now+0.005},ops.now)
        if not ok or type(result)~="table" then
            finish(record,"failed",error_result("invalid_config","planner step failed: "..tostring(result))); return
        end
        record.search_metrics=copy(result.metrics)
        if result.status=="running" then later(record,function() tick_search(record) end); return end
        if result.status~="succeeded" then
            finish(record,result.status=="cancelled" and "cancelled" or "failed",
                result.error or error_result("bounded_no_route","planner did not produce a route")); return
        end
        record.route=result.route
        record.state="composing"
        publish(record)
        local compose_ok,composed,plan_error=pcall(ops.compose,record.terrain,record.route,record.config.composition)
        if not compose_ok then plan_error=error_result("composition_failed","plan composition failed: "..tostring(composed)); composed=nil end
        if not composed then finish(record,"failed",plan_error or error_result("composition_failed","route composition failed")); return end
        record.plan=composed
        record.state="ready"
        record.completed_at=ops.now()
        record.route_summary={cost=record.route.cost,metrics=copy(composed.metrics or record.route.metrics)}
        record.survey=nil; record.search=nil; record.terrain=nil; record.route=nil; record.config=nil
        self.reports[record.owner]=record
        publish(record)
        -- The ready plan owns the global slot until the owner cancels it or a
        -- future build command completes it.
    end

    function self:start_endpoint(owner,feet)
        if type(owner)~="string" or owner=="" or not valid_feet(feet) then
            return nil,error_result("invalid_endpoint","a player position is required")
        end
        self.selections[owner]=copy(feet)
        return copy(feet)
    end

    function self:plan(owner,feet,config)
        if type(owner)~="string" or owner=="" or not valid_feet(feet) then
            return nil,error_result("invalid_endpoint","a player position is required")
        end
        local start=self.selections[owner]
        if not start then return nil,error_result("invalid_endpoint","use /roads_start to select the first endpoint") end
        if self.active then return nil,error_result("busy","another road planning job owns the server slot") end
        self.next_id=self.next_id+1
        local record={id=self.next_id,owner=owner,state="surveying",start_feet=copy(start),
            goal_feet=copy(feet),config=copy(config or {}),started_at=ops.now()}
        self.active=record
        self.reports[owner]=record
        local call_ok,service,err=pcall(ops.start_survey,record.start_feet,record.goal_feet,owner,record.config.world)
        if not call_ok then err=error_result("survey_failed","survey startup failed: "..tostring(service)); service=nil end
        if not service then
            finish(record,"failed",err or error_result("survey_failed","terrain survey could not start"))
            return nil,copy(record.error)
        end
        record.survey=service
        later(record,function() self:_poll_survey(record) end)
        if record.closed then return nil,copy(record.error) end
        publish(record)
        return record.id
    end

    function self:_poll_survey(record)
        if not current(record) then return end
        local ok,result=pcall(record.survey.status,record.survey)
        if not ok or type(result)~="table" then
            finish(record,"failed",error_result("survey_failed","survey status failed: "..tostring(result))); return
        end
        record.survey_metrics=copy(result.metrics)
        if result.status=="running" then later(record,function() self:_poll_survey(record) end); return end
        if result.status=="cancelled" then finish(record,"cancelled",result.error or error_result("cancelled","survey cancelled")); return end
        if result.status~="succeeded" then finish(record,"failed",result.error or error_result("survey_failed","survey failed")); return end
        begin_search(record,result.terrain)
    end

    function self:cancel(owner)
        local record=self.active
        if not record then return nil,error_result("no_plan","there is no active road plan") end
        if record.owner~=owner then return nil,error_result("not_owner","only the planning player can cancel this job") end
        finish(record,"cancelled",error_result("cancelled","planning cancelled by owner"))
        return true
    end

    function self:disconnect(owner)
        local record=self.active
        if record and record.owner==owner then
            cancel_work(record)
            record.closed=true
            self.active=nil
            record.survey=nil; record.search=nil; record.terrain=nil; record.route=nil; record.plan=nil; record.config=nil
        end
        self.selections[owner]=nil
        self.reports[owner]=nil
    end

    function self:status(owner)
        local record=self.active and self.active.owner==owner and self.active or self.reports[owner]
        if not record then return {state="idle",owner=owner} end
        local result={id=record.id,owner=record.owner,state=record.state,
            error=copy(record.error),started_at=record.started_at,finished_at=record.finished_at,
            endpoints=copy(record.endpoints),request=copy(record.request),
            requested_endpoints={start=copy(record.start_feet),goal=copy(record.goal_feet)},
            survey_metrics=copy(record.survey_metrics),search_metrics=copy(record.search_metrics)}
        if record.route_summary then result.metrics=copy(record.route_summary.metrics); result.cost=record.route_summary.cost end
        return result
    end
    return self
end

return jobs
