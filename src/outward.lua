-- SPDX-License-Identifier: GPL-3.0-or-later
-- Persistent outward-road operations: one road from a completed Towns
-- settlement exit toward caller-supplied targets. This module owns endpoint
-- resolution, attempts, shared budgets, the durable record and the hand-off
-- to construction. Surveying, planning, composition and building stay in
-- their own modules and are injected, so the lifecycle is testable without
-- Luanti. It never reads Towns internals and never replays a build.
local outward = {}

local MAX_CHUNKS = 96
local MAX_EXPANSIONS = 150000
local MAX_CANDIDATES = 4
local MAX_PREVIEW_OPERATIONS = 64
local WRITER_WAIT = 180
local OWNER = "roads:outward" -- a colon cannot appear in a player name

local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for k, v in pairs(value) do result[k] = copy(v) end
    return result
end
-- Keep only the small walking geometry needed by /roads_preview. The full
-- endpoint provenance contains terrain expectations and must stay out of the
-- persistent outward-operation record.
local function preview_endpoints(endpoints)
    if type(endpoints) ~= "table" then return nil end
    local result = {}
    for _, side in ipairs({"start", "goal"}) do
        local endpoint = endpoints[side]
        local connector = type(endpoint) == "table" and endpoint.connector or nil
        if type(connector) == "table" and type(connector.path) == "table"
            and type(connector.transition) == "table" and type(connector.transition.path) == "table" then
            result[side] = {connector = {version = 1, path = copy(connector.path),
                transition = {path = copy(connector.transition.path)}}}
        end
    end
    return next(result) and result or nil
end
local function error_result(code, reason, extra)
    local result = extra or {}
    result.code = code; result.reason = reason
    return result
end
local function integer(n) return type(n) == "number" and n == math.floor(n) and math.abs(n) <= 31000 end

-- Errors that prove the builder performed no writes.
local ZERO_WRITE = {stale_plan = true, towns_busy = true, towns_conflict = true, build_failed = true, write_budget = true}
local BUDGET = {survey_budget = true, expansion_budget = true}

local REQUIRED = {"jobs", "towns", "store", "now", "after", "world_config", "survey", "start_survey",
    "exit_endpoints", "new_planner", "compose", "start_build", "wrap_terrain"}

function outward.new(ops)
    for _, name in ipairs(REQUIRED) do
        if ops == nil or ops[name] == nil then
            return nil, error_result("invalid_config", "outward service dependency is missing: " .. name)
        end
    end
    local jobs, towns, store = ops.jobs, ops.towns, ops.store
    local self = {active = nil}
    local next_token = 0
    -- Display-only geometry stays out of the durable operation record.
    local preview_geometry = {}
    local preview_order = {}

    local function log(level, message)
        if ops.log then pcall(ops.log, level, "[roads] " .. message) end
    end

    local function new_aggregate()
        return {chunks = 0, chunk_requests = 0, expansions = 0, peak_states = 0, peak_heap_entries = 0,
            survey_seconds = 0, search_seconds = 0, longest_slice = 0}
    end

    ---------------------------------------------------------------- summaries
    local function summarize(op, act)
        local road = op.road
        return {op_id = op.op_id, settlement_id = op.settlement_id, exit_id = op.exit_id, state = op.state,
            writes = op.writes, stage = act and act.stage or nil, active = act ~= nil,
            requester = op.requester, cancelled_by = op.cancelled_by,
            candidates = copy(op.candidates), attempts = copy(op.attempts),
            -- The live aggregate is kept on the active record until it is committed to the op.
            aggregate = copy(act and act.agg or op.aggregate),
            current_target = act and op.candidates[act.index] and copy(op.candidates[act.index]) or nil,
            error = copy(op.error), build = copy(op.build), created_at = op.created_at, updated_at = op.updated_at,
            persisted = not op.persist_failed,
            road = road and {chosen_index = road.chosen_index, requested_target = copy(road.requested_target),
                resolved_target = copy(road.resolved_target), landing = copy(road.landing),
                centerline = copy(road.centerline), endpoints = copy(preview_geometry[op.op_id]), terminal = copy(road.terminal),
                terminal_heading = road.terminal_heading, outward = copy(road.outward), metrics = copy(road.metrics),
                write_count = road.write_count, expectation_count = road.expectation_count} or nil}
    end

    ------------------------------------------------------------ persistence
    local function save(op, quiet)
        local ok, why = store:save(op.settlement_id, op)
        if ok then op.persist_failed = nil; return true end
        op.persist_failed = true
        if not quiet then log("error", "cannot save outward operation " .. op.op_id .. ": " .. tostring(why.reason)) end
        return nil, why
    end

    -- Progress notices carry active=true so presentation can ignore them;
    -- terminal notices are summarized without the active record.
    local function notify(op, act)
        if ops.notify then pcall(ops.notify, op.requester, summarize(op, act)) end
    end

    ----------------------------------------------------------- work control
    local function cancel_work(act)
        if act.survey then pcall(act.survey.cancel, act.survey) end
        if act.search then pcall(act.search.cancel, act.search) end
        if act.builder then pcall(act.builder.cancel, act.builder) end
        act.survey, act.search, act.builder, act.terrain, act.plan = nil, nil, nil, nil, nil
    end

    -- Every terminal transition goes through here: it invalidates pending
    -- callbacks, stops outstanding work, records the outcome and frees the slot.
    local function finish(act, state, writes, err, extra)
        if self.active ~= act then return end
        cancel_work(act)
        act.token = act.token + 1
        local op = act.op
        op.state = state; op.writes = writes
        op.error = err and copy(err) or nil
        for k, v in pairs(extra or {}) do op[k] = v end
        op.aggregate = copy(act.agg)
        save(op)
        self.active = nil
        jobs:release(act.slot)
        notify(op)
    end

    local function current(act, token) return self.active == act and act.token == token end

    local function later(act, fn, delay)
        local token = act.token
        local ok, why = pcall(ops.after, delay or 0, function()
            if current(act, token) then fn() end
        end)
        if not ok then
            finish(act, "failed", act.op.writes, error_result("survey_failed", "cannot schedule outward work: " .. tostring(why)))
        end
    end

    local function set_stage(act, stage)
        act.stage = stage
        notify(act.op, act)
    end

    ----------------------------------------------------------- attempts
    local next_attempt

    local function record_attempt(act, outcome, err, extra)
        local entry = {index = act.index, target = copy(act.op.candidates[act.index]), outcome = outcome,
            reason = err and err.reason, position = err and copy(err.position),
            chunks_new = act.attempt_chunks or 0, expansions = act.attempt_expansions or 0,
            survey_seconds = act.attempt_survey_seconds or 0, search_seconds = act.attempt_search_seconds or 0}
        for k, v in pairs(extra or {}) do entry[k] = v end
        act.op.attempts[#act.op.attempts + 1] = entry
        act.last_error = err
        act.outcomes[#act.outcomes + 1] = outcome
    end

    -- A candidate failed: drop everything it held and try the next one.
    local function attempt_failed(act, err)
        act.survey, act.search, act.terrain, act.route = nil, nil, nil, nil
        record_attempt(act, err.code, err)
        later(act, function() next_attempt(act) end, 0)
    end

    local function stop_expansions(act)
        act.agg.limit_reached = "expansions"
        act.agg.limit = MAX_EXPANSIONS; act.agg.observed = act.agg.expansions
        finish(act, "failed", "none", error_result("expansion_budget",
            "the operation used its shared budget of " .. MAX_EXPANSIONS .. " search expansions",
            {limit = MAX_EXPANSIONS, observed = act.agg.expansions}))
    end

    local function all_failed(act)
        local err = act.last_error or error_result("bounded_no_route", "no target candidate produced a road")
        local only_budget = #act.outcomes > 0
        for _, outcome in ipairs(act.outcomes) do if not BUDGET[outcome] then only_budget = false end end
        if only_budget then
            if act.agg.limit_reached == "expansions" then return stop_expansions(act) end
            act.agg.limit_reached = "chunks"; act.agg.limit = MAX_CHUNKS; act.agg.observed = act.max_union
            err = error_result("survey_budget", "every target would exceed the shared budget of " .. MAX_CHUNKS
                .. " distinct mapchunks", {limit = MAX_CHUNKS, observed = act.max_union})
        end
        finish(act, "failed", "none", err)
    end

    local function commit(act)
        local op = act.op
        local plan = act.plan
        set_stage(act, "committing")
        local ok, why = towns:recheck(act.descriptor)
        if not ok then return finish(act, "failed", "none", why) end
        local interval = ops.save_interval and ops.save_interval() or 5.3
        if type(interval) ~= "number" or interval ~= interval or interval > 60 then
            return finish(act, "failed", "none", error_result("storage_failed",
                "the server map save interval is too long to guarantee durability before construction"))
        end
        local start, goal = plan.endpoints.start, plan.endpoints.goal
        local footprint
        for _, w in ipairs(plan.writes) do
            footprint = footprint or {x1 = w.x, z1 = w.z, x2 = w.x, z2 = w.z}
            footprint.x1 = math.min(footprint.x1, w.x); footprint.x2 = math.max(footprint.x2, w.x)
            footprint.z1 = math.min(footprint.z1, w.z); footprint.z2 = math.max(footprint.z2, w.z)
        end
        local line = plan.centerline
        local m = plan.metrics or {}
        op.road = {plan_version = plan.version, connector_version = plan.connector_version,
            chosen_index = act.index, requested_target = copy(op.candidates[act.index]),
            resolved_target = copy(goal.resolved), landing = copy(start.resolved),
            centerline = copy(line), headings = copy(plan.headings),
            terminal = copy(line[#line]), terminal_heading = plan.headings[#plan.headings],
            outward = copy(act.descriptor.direction),
            metrics = {length = m.length, ascent = m.ascent, descent = m.descent, max_grade = m.max_grade,
                turns = m.turn_count, cuts = m.cut_count, fills = m.fill_count},
            write_count = #plan.writes, expectation_count = #plan.expectations, footprint = footprint}
        local preview = preview_endpoints(plan.endpoints)
        if preview then
            preview_geometry[op.op_id] = preview
            preview_order[#preview_order + 1] = op.op_id
            while #preview_order > MAX_PREVIEW_OPERATIONS do
                preview_geometry[table.remove(preview_order, 1)] = nil
            end
        end
        op.state = "building"; op.writes = "unknown"; op.aggregate = copy(act.agg)
        local saved, save_err = save(op, true)
        if not saved then
            -- Zero writes were made. Undo the in-memory commitment and make a
            -- best-effort attempt to replace the durable "building" record.
            op.road = nil; op.state = "planning"; op.writes = "none"
            return finish(act, "failed", "none", save_err)
        end
        set_stage(act, "durability_wait")
        later(act, function()
            set_stage(act, "building")
            local started, builder, build_err
            local token = act.token
            started, builder, build_err = pcall(ops.start_build, plan, function(err, metrics)
                if not current(act, token) then return end
                act.builder = nil
                if not err then
                    return finish(act, "built", "all", nil, {build = copy(metrics)})
                elseif err.code == "partial_build" then
                    return finish(act, "partial", "some", err, {build = copy(metrics)})
                elseif ZERO_WRITE[err.code] then
                    return finish(act, "failed", "none", err)
                end
                return finish(act, "partial", "unknown", err)
            end, towns:new_guard())
            if not started then build_err = error_result("build_failed", "construction startup failed: " .. tostring(builder)); builder = nil end
            if not builder then return finish(act, "failed", "none", build_err or error_result("build_failed", "construction could not start")) end
            act.builder = builder
        end, math.min(interval, 60) + 1)
    end

    local function compose_route(act, route)
        set_stage(act, "composing")
        local ok, plan, why = pcall(ops.compose, act.terrain, route, act.config.composition)
        if not ok then why = error_result("composition_failed", "plan composition failed: " .. tostring(plan)); plan = nil end
        if not plan then return attempt_failed(act, why or error_result("composition_failed", "route composition failed")) end
        act.plan = plan
        act.terrain, act.search, act.survey = nil, nil, nil
        record_attempt(act, "composed", nil)
        commit(act)
    end

    local function search_slice(act)
        local started = ops.now()
        local ok, result = pcall(act.search.step, act.search, {max_expansions = 1000, deadline = started + 0.005}, ops.now)
        local elapsed = math.max(0, ops.now() - started)
        act.agg.longest_slice = math.max(act.agg.longest_slice, elapsed)
        act.attempt_search_seconds = (act.attempt_search_seconds or 0) + elapsed
        act.agg.search_seconds = act.agg.search_seconds + elapsed
        if not ok or type(result) ~= "table" then
            return attempt_failed(act, error_result("invalid_config", "planner step failed: " .. tostring(result)))
        end
        local metrics = result.metrics or {}
        -- Repeated work counts: add the delta since the previous slice.
        local delta = math.max(0, (metrics.expansions or 0) - (act.attempt_expansions or 0))
        act.attempt_expansions = metrics.expansions or 0
        act.agg.expansions = act.agg.expansions + delta
        act.agg.peak_states = math.max(act.agg.peak_states, metrics.states or 0)
        act.agg.peak_heap_entries = math.max(act.agg.peak_heap_entries, metrics.heap_peak or 0)
        if result.status == "running" then return later(act, function() search_slice(act) end, 0) end
        if result.status == "succeeded" then return compose_route(act, result.route) end
        if result.status == "cancelled" then return finish(act, "cancelled", "none", error_result("cancelled", "search cancelled")) end
        local err = result.error or error_result("bounded_no_route", "planner did not produce a route")
        if err.code == "expansion_budget" then
            record_attempt(act, err.code, err)
            return stop_expansions(act)
        end
        attempt_failed(act, err)
    end

    local function resolve_and_search(act, terrain)
        local op = act.op
        local target = op.candidates[act.index]
        set_stage(act, "waiting_towns")
        local waited_from = ops.now()
        local function wait_for_towns()
            if towns:writer() then
                if ops.now() - waited_from >= WRITER_WAIT then
                    return attempt_failed(act, error_result("towns_busy", "Towns kept writing terrain for " .. WRITER_WAIT .. " seconds"))
                end
                return later(act, wait_for_towns, 1)
            end
            local b = terrain.bounds
            local rects, why = towns:overlay({x1 = b.min_x, z1 = b.min_z, x2 = b.max_x, z2 = b.max_z},
                act.settlement, act.descriptor.exit_id)
            if not rects then return attempt_failed(act, why) end
            local wrapped = ops.wrap_terrain(terrain, rects)
            act.terrain = wrapped
            set_stage(act, "resolving")
            local ok, provenance, err = pcall(ops.exit_endpoints, wrapped, act.descriptor, target)
            if not ok then err = error_result("survey_failed", "endpoint inspection failed: " .. tostring(provenance)); provenance = nil end
            if not provenance then return attempt_failed(act, err or error_result("invalid_endpoint", "endpoint resolution failed")) end
            local request = {start = copy(provenance.start.resolved), goal = copy(provenance.goal.resolved), provenance = copy(provenance)}
            local remaining = MAX_EXPANSIONS - act.agg.expansions
            if remaining < 1 then return stop_expansions(act) end
            local planner_config = {weights = act.config.planner.weights, road_material = act.config.planner.road_material,
                max_expansions = remaining}
            local made, search, serr = pcall(ops.new_planner, wrapped, request, planner_config)
            if not made then serr = error_result("invalid_config", "planner creation failed: " .. tostring(search)); search = nil end
            if not search then return attempt_failed(act, serr or error_result("invalid_config", "planner could not start")) end
            act.search = search
            act.attempt_expansions = 0
            set_stage(act, "searching")
            search_slice(act)
        end
        wait_for_towns()
    end

    local function poll_survey(act)
        local ok, result = pcall(act.survey.status, act.survey)
        if not ok or type(result) ~= "table" then
            return attempt_failed(act, error_result("survey_failed", "survey status failed: " .. tostring(result)))
        end
        if result.status == "running" then return later(act, function() poll_survey(act) end, 0.1) end
        local seconds = math.max(0, ops.now() - act.survey_started)
        act.attempt_survey_seconds = seconds
        act.agg.survey_seconds = act.agg.survey_seconds + seconds
        if result.status == "cancelled" then return finish(act, "cancelled", "none", result.error or error_result("cancelled", "survey cancelled")) end
        if result.status ~= "succeeded" then
            return attempt_failed(act, result.error or error_result("survey_failed", "survey failed"))
        end
        act.survey = nil
        resolve_and_search(act, result.terrain)
    end

    next_attempt = function(act)
        local op = act.op
        act.index = act.index + 1
        act.attempt_chunks, act.attempt_expansions, act.attempt_survey_seconds, act.attempt_search_seconds = 0, 0, 0, 0
        if act.index > #op.candidates then return all_failed(act) end
        if act.agg.expansions >= MAX_EXPANSIONS then return stop_expansions(act) end
        local target = op.candidates[act.index]
        local d = act.descriptor
        local first = {x = d.anchor.x, y = d.anchor.y, z = d.anchor.z}
        local second = {x = target.x, y = d.profile[#d.profile].y, z = target.z}
        local world = act.config.world
        local plan, why = ops.survey.plan(first, second, world)
        if not plan then
            return attempt_failed(act, why or error_result("survey_failed", "survey preflight failed"))
        end
        -- Reused chunks count once; failed or partial surveys still count.
        local fresh, union = {}, act.agg.chunks
        for _, c in ipairs(plan.chunks) do
            local key = c.ix .. ":" .. c.iy .. ":" .. c.iz
            if not act.chunks[key] then fresh[#fresh + 1] = key; union = union + 1 end
        end
        act.max_union = math.max(act.max_union, union)
        if union > MAX_CHUNKS then
            return attempt_failed(act, error_result("survey_budget",
                "this target would raise the operation to " .. union .. " distinct mapchunks (limit " .. MAX_CHUNKS .. ")",
                {limit = MAX_CHUNKS, observed = union}))
        end
        for _, key in ipairs(fresh) do act.chunks[key] = true end
        act.agg.chunks = union
        act.agg.chunk_requests = act.agg.chunk_requests + plan.chunk_count
        act.attempt_chunks = #fresh
        set_stage(act, "surveying")
        local ok, service, err = pcall(ops.start_survey, first, second, OWNER, world)
        if not ok then err = error_result("survey_failed", "survey startup failed: " .. tostring(service)); service = nil end
        if not service then return attempt_failed(act, err or error_result("survey_failed", "terrain survey could not start")) end
        act.survey = service
        act.survey_started = ops.now()
        later(act, function() poll_survey(act) end, 0.1)
    end

    ----------------------------------------------------------------- entry
    local function validate(request)
        if type(request) ~= "table" then return error_result("invalid_request", "a request table is required") end
        for _, name in ipairs({"settlement_id", "exit_id", "requester"}) do
            if type(request[name]) ~= "string" or request[name] == "" then
                return error_result("invalid_request", name .. " must be a non-empty string")
            end
        end
        if request.policy ~= nil and type(request.policy) ~= "table" then
            return error_result("invalid_request", "policy must be a table")
        end
        local c = request.candidates
        if type(c) ~= "table" or #c < 1 or #c > MAX_CANDIDATES then
            return error_result("invalid_request", "between 1 and " .. MAX_CANDIDATES .. " target candidates are required")
        end
        local seen = {}
        for i, t in ipairs(c) do
            if type(t) ~= "table" or not integer(t.x) or not integer(t.z) then
                return error_result("invalid_request", "target candidate " .. i .. " must have integer x and z")
            end
            local key = t.x .. ":" .. t.z
            if seen[key] then return error_result("invalid_request", "target candidates must be distinct") end
            seen[key] = true
        end
    end

    function self:start(request)
        local bad = validate(request)
        if bad then return nil, bad end
        local settlement, err = towns:settlement(request.settlement_id)
        if not settlement then return nil, err end
        local descriptor, exit_err = towns:exit(settlement, request.exit_id)
        if not descriptor then return nil, exit_err end
        local config, config_err = ops.world_config()
        if not config then return nil, config_err or error_result("unsupported_world", "world configuration is unavailable") end
        local state, detail = store:eligibility(request.settlement_id, request.exit_id)
        if state == "unreadable" then
            return nil, error_result("already_reserved", "the stored record for this settlement is unreadable and blocks it", detail)
        elseif state == "reserved" then
            return nil, error_result("already_reserved", detail.scope == "settlement"
                and "this settlement already has a built outward road"
                or "this exit has a partial or uncertain outward road", detail)
        end
        local act = {token = 0, index = 0, stage = "planning", chunks = {}, max_union = 0, outcomes = {},
            agg = new_aggregate(), descriptor = descriptor, settlement = settlement, config = config}
        local policy_ok, policy = pcall(copy, request.policy or {})
        if not policy_ok then return nil, error_result("invalid_request", "policy cannot be copied") end
        local slot, busy = jobs:hold({kind = "outward",
            cancel = function(actor) return self:cancel(actor) end,
            status = function()
                return {op_id = act.op and act.op.op_id, stage = act.stage, settlement_id = request.settlement_id,
                    exit_id = request.exit_id}
            end})
        if not slot then return nil, busy end
        act.slot = slot
        local op, op_err = store:new_op(request.settlement_id, request.exit_id, {
            settlement_id = request.settlement_id, requester = request.requester,
            source = {api_version = descriptor.api_version, settlement_id = descriptor.settlement_id,
                exit_id = descriptor.exit_id, exit_source = descriptor.source, direction = copy(descriptor.direction),
                columns = copy(descriptor.columns), length = descriptor.length, profile = copy(descriptor.profile),
                center = copy(descriptor.center), town_type = descriptor.town_type},
            policy = policy, candidates = copy(request.candidates), attempts = {}, aggregate = {}})
        if not op then jobs:release(slot); return nil, error_result("storage_failed", op_err.reason) end
        act.op = op
        local saved, save_err = store:save(request.settlement_id, op)
        if not saved then
            store:discard(request.settlement_id, op)
            jobs:release(slot)
            return nil, save_err
        end
        self.active = act
        notify(op, act)
        later(act, function() next_attempt(act) end, 0)
        if self.active ~= act then
            -- Scheduling failed and the operation already finished.
            return nil, copy(op.error)
        end
        return {op_id = op.op_id, state = "planning"}
    end

    function self:cancel(actor)
        local act = self.active
        if not act then return nil, error_result("no_plan", "there is no active outward road operation") end
        act.op.cancelled_by = actor
        finish(act, "cancelled", "none", error_result("cancelled", "outward road cancelled" .. (actor and (" by " .. tostring(actor)) or "")))
        return true
    end

    function self:status(settlement_id)
        local act = self.active
        if act and (settlement_id == nil or act.op.settlement_id == settlement_id) then
            return summarize(act.op, act)
        end
        if settlement_id == nil then return nil end
        local op = store:latest(settlement_id)
        return op and summarize(op) or nil
    end

    -- 'open' | 'active' | 'reserved' | 'unreadable' for a settlement, or for one of its exits.
    function self:eligibility(settlement_id, exit_id)
        if self.active and self.active.op.settlement_id == settlement_id then return "active", {op_id = self.active.op.op_id} end
        return store:eligibility(settlement_id, exit_id)
    end

    -- Startup sweep (called once). Never builds anything.
    function self:recover()
        local summary, err = store:recover()
        if not summary then log("error", "outward recovery failed: " .. tostring(err.reason)); return nil, err end
        if summary.converted > 0 or summary.unreadable > 0 or summary.failed_saves > 0 then
            log("warning", "outward recovery: " .. summary.converted .. " interrupted operation record(s) converted, "
                .. summary.unreadable .. " unreadable, " .. summary.failed_saves .. " failed save(s)")
        end
        return summary
    end

    return self
end

outward.OWNER = OWNER
outward.MAX_CHUNKS, outward.MAX_EXPANSIONS = MAX_CHUNKS, MAX_EXPANSIONS
return outward
