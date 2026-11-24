-- SPDX-License-Identifier: GPL-3.0-or-later
-- Road growth lifecycle: seed recording for outward roads, explicit adoption,
-- one bounded destination-aware continuation cycle (sequential destination
-- attempts, then reserved directional fallback), and conservative status,
-- cancel, retry, retire and inspect operations. This module owns the durable
-- ordering (intent, prepared segment, registry reservation, durability wait,
-- single build, publication). Surveying, planning, composition and building
-- are injected and stay in their own modules. It never replays a build, never
-- releases an uncertain reservation and never repairs player edits.
local growth = {}

-- Shared cycle budget partition (design: "One destination-aware cycle").
local MAX_CHUNKS = 96             -- distinct mapchunks in the whole cycle
local DEST_CHUNKS = 64            -- destination attempts stop here; 32 stay for fallback
local MAX_EXPANSIONS = 150000
local DEST_EXPANSIONS = 50000     -- per destination attempt
local RESERVED_EXPANSIONS = 50000 -- never spent by destination attempts
local MAX_ATTEMPTS = 4            -- 2 destination + 2 fallback
local MAX_REJECTED = 8            -- rejected destinations kept in an attempt summary
local MAX_CENTERLINE = 1024
local MAX_COLUMNS = 50000
local MAX_SAMPLES = 16            -- mismatches reported by inspect
local MAX_CLAIMS_PER_CYCLE = 8
local WRITER_WAIT = 180
local OWNER = "roads:growth"
-- Errors that prove a builder made no writes. A generic build_failed from the
-- builder callback is deliberately absent: it can follow the first write.
local ZERO_WRITE = {stale_plan = true, towns_busy = true, towns_conflict = true, write_budget = true,
    seam_changed = true}
local BUDGET = {survey_budget = true, expansion_budget = true}

local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for k, v in pairs(value) do result[k] = copy(v) end
    return result
end
local function error_result(code, reason, extra)
    local result = extra or {}
    result.code = code; result.reason = reason
    return result
end
local function integer(n) return type(n) == "number" and n == math.floor(n) and math.abs(n) <= 31000 end
local function point(p) return type(p) == "table" and integer(p.x) and integer(p.y) and integer(p.z) end
local function key2(p) return p.x .. ":" .. p.z end
local function cardinal(d)
    return type(d) == "table" and integer(d.x) and integer(d.z) and math.abs(d.x) + math.abs(d.z) == 1
end

local REQUIRED = {"policy", "store", "jobs", "now", "after", "raster", "seam", "access", "has_timer", "classify",
    "load_area", "world_config", "survey", "start_survey", "new_planner", "compose", "start_build",
    "save_interval", "find_operation"}

function growth.new(ops)
    for _, name in ipairs(REQUIRED) do
        if ops == nil or ops[name] == nil then
            return nil, error_result("invalid_config", "growth service dependency is missing: " .. name)
        end
    end
    local store, jobs, raster, seam, access = ops.store, ops.jobs, ops.raster, ops.seam, ops.access
    local policy = ops.policy
    local self = {active = nil}

    local function log(level, message)
        if ops.log then pcall(ops.log, level, "[roads] " .. message) end
    end
    local function disabled() return store:health() end

    ------------------------------------------------------------ geometry
    -- Rasterized footprint columns (the swept raster; construction support and
    -- clearance occupy the same columns) of a stored or composed centerline,
    -- plus any extra surfaces (connector transitions) that cannot be derived.
    local function columns_of(centerline, extra)
        if type(centerline) ~= "table" or #centerline < 2 or #centerline > MAX_CENTERLINE then
            return nil, error_result("invalid_geometry", "centerline must have 2 to " .. MAX_CENTERLINE .. " points")
        end
        local map, list = {}, {}
        local function add(p)
            local id = key2(p)
            if map[id] ~= nil and map[id] ~= p.y then
                return error_result("invalid_geometry", "conflicting footprint heights", {position = {x = p.x, y = p.y, z = p.z}})
            end
            if map[id] == nil then
                if #list >= MAX_COLUMNS then
                    return error_result("storage_budget", "footprint exceeds " .. MAX_COLUMNS .. " columns",
                        {limit = MAX_COLUMNS, observed = #list + 1})
                end
                map[id] = p.y; list[#list + 1] = {x = p.x, y = p.y, z = p.z}
            end
        end
        for i = 1, #centerline - 1 do
            if not point(centerline[i]) or not point(centerline[i + 1]) then
                return nil, error_result("invalid_geometry", "centerline point is invalid")
            end
            local edge = raster.segment(centerline[i], centerline[i + 1])
            if not edge then return nil, error_result("invalid_geometry", "centerline edge cannot be rasterized") end
            for _, p in ipairs(edge.columns) do
                local bad = add(p); if bad then return nil, bad end
            end
        end
        for _, p in ipairs(extra or {}) do
            if not point(p) then return nil, error_result("invalid_geometry", "extra footprint column is invalid") end
            local bad = add(p); if bad then return nil, bad end
        end
        return list, map
    end

    local function footprint_summary(list)
        local bounds, cells, ordered = nil, {}, {}
        for _, p in ipairs(list) do
            bounds = bounds or {x1 = p.x, z1 = p.z, x2 = p.x, z2 = p.z}
            bounds.x1 = math.min(bounds.x1, p.x); bounds.x2 = math.max(bounds.x2, p.x)
            bounds.z1 = math.min(bounds.z1, p.z); bounds.z2 = math.max(bounds.z2, p.z)
            local cell = store.cell(p.x, p.z)
            if not cells[cell] then cells[cell] = true; ordered[#ordered + 1] = cell end
        end
        table.sort(ordered)
        if #ordered > store.LIMITS.cells then
            return nil, error_result("storage_budget", "footprint touches " .. #ordered .. " index cells (limit "
                .. store.LIMITS.cells .. ")", {limit = store.LIMITS.cells, observed = #ordered})
        end
        return {bounds = bounds, cells = ordered, count = #list}
    end

    ------------------------------------------------------------ obstacles
    -- Footprint columns of the given stored entries clipped to rect, minus the
    -- authenticated start-patch columns. An entry whose reconstructed index
    -- cells disagree with the registry is corrupt: fail closed.
    local function obstacle_mask(ids, rect, allowed)
        local mask = {}
        for _, id in ipairs(ids) do
            local entry = store:entry(id)
            local record, why = store:load_record(id)
            if not entry or not record then return nil, why or error_result("road_index_corrupt", "entry " .. id .. " vanished") end
            local list, merr = columns_of(record.centerline, record.footprint and record.footprint.extra)
            if not list then return nil, merr end
            local summary, serr = footprint_summary(list)
            if not summary then return nil, serr end
            local same = #summary.cells == #entry.cells
            for i, c in ipairs(summary.cells) do same = same and entry.cells[i] == c end
            if not same then
                return nil, error_result("road_index_corrupt", "stored footprint of " .. id .. " disagrees with its index cells")
            end
            for _, p in ipairs(list) do
                if p.x >= rect.x1 and p.x <= rect.x2 and p.z >= rect.z1 and p.z <= rect.z2 and not allowed[key2(p)] then
                    mask[key2(p)] = id
                end
            end
        end
        return mask
    end

    local function mask_terrain(terrain, mask)
        local wrapped = {}
        for k, v in pairs(terrain) do wrapped[k] = v end
        wrapped.get_column = function(x, z)
            if mask[x .. ":" .. z] then return {status = "structure", reason = "existing road footprint"} end
            return terrain.get_column(x, z)
        end
        return wrapped
    end

    local function seam_columns(patch)
        local allowed = {}
        for _, p in ipairs(patch.surfaces) do allowed[key2(p)] = true end
        return allowed
    end

    ------------------------------------------------------------ seam checks
    local function patch_bounds(patch)
        local minp, maxp
        for _, p in ipairs(patch.preserved) do
            minp = minp or {x = p.x, y = p.y, z = p.z}; maxp = maxp or {x = p.x, y = p.y, z = p.z}
            for _, axis in ipairs({"x", "y", "z"}) do
                minp[axis] = math.min(minp[axis], p[axis]); maxp[axis] = math.max(maxp[axis], p[axis])
            end
        end
        return minp, maxp
    end
    -- Existing mapblocks only: load_area never generates terrain.
    local function check_seam(patch, owner)
        local valid, why = seam.validate(raster, patch)
        if not valid then return nil, why end
        local minp, maxp = patch_bounds(patch)
        local loaded, result = pcall(ops.load_area, minp, maxp)
        if not loaded or result == false then
            return nil, error_result("seam_changed", "seam mapblocks could not be loaded", {position = minp})
        end
        return seam.check_patch(patch.preserved, access, owner, ops.has_timer)
    end

    ------------------------------------------------------------ outward seeds
    -- Source surfaces exactly as seam.derive expects them: the swept raster of
    -- the whole plan plus connector transition surfaces.
    local function source_surfaces(plan)
        local list, map = columns_of(plan.centerline)
        if not list then return nil, map end
        local extra = {}
        for _, endpoint in pairs(plan.endpoints or {}) do
            local transition = type(endpoint) == "table" and endpoint.connector and endpoint.connector.transition
            for _, p in ipairs(transition and transition.surfaces or {}) do
                if not point(p) then return nil, error_result("invalid_geometry", "transition surface is invalid") end
                if map[key2(p)] == nil then
                    map[key2(p)] = p.y; list[#list + 1] = {x = p.x, y = p.y, z = p.z}
                    extra[#extra + 1] = {x = p.x, y = p.y, z = p.z}
                    if #list > MAX_COLUMNS then
                        return nil, error_result("storage_budget", "footprint exceeds " .. MAX_COLUMNS .. " columns")
                    end
                end
            end
        end
        return list, extra
    end

    local function capture_snapshot(plan)
        local snapshot = {}
        for _, p in ipairs(plan.expectations) do
            local ok, node = pcall(access.get_node, p)
            if not ok or type(node) ~= "table" or type(node.name) ~= "string" then
                return nil, error_result("seed_unavailable", "an expected node could not be read", {position = {x = p.x, y = p.y, z = p.z}})
            end
            local m_ok, meta = pcall(access.has_metadata, p)
            local p_ok, protected = pcall(access.is_protected, p, plan.owner)
            local t_ok, timer = pcall(ops.has_timer, p)
            if not (m_ok and p_ok and t_ok) then
                return nil, error_result("seed_unavailable", "node state could not be read", {position = {x = p.x, y = p.y, z = p.z}})
            end
            snapshot[#snapshot + 1] = {x = p.x, y = p.y, z = p.z, name = node.name, param2 = node.param2,
                has_metadata = meta, protected = protected, has_timer = timer}
        end
        return snapshot
    end

    local hooks = {}
    local function seed_id(op_id) return "growth:v1:" .. op_id .. ":s1" end

    -- Persist the intended seed before the outward builder is started. On any
    -- failure the outward road simply is not growth-ready; its own reservation
    -- rules are unaffected.
    function hooks.prepare(op, plan, descriptor)
        local ok, why = disabled(); if not ok then return nil, why end
        if type(plan) ~= "table" or type(plan.owner) ~= "string" or type(plan.centerline) ~= "table" then
            return nil, error_result("seed_unavailable", "the outward plan has no growth geometry")
        end
        local list, extra = source_surfaces(plan)
        if not list then return nil, extra end
        local snapshot, serr = capture_snapshot(plan)
        if not snapshot then return nil, serr end
        local derived, derr = seam.derive(raster, plan, list, snapshot, ops.classify)
        if not derived then return nil, derr end
        local summary, ferr = footprint_summary(list)
        if not summary then return nil, ferr end
        summary.extra = extra
        local id = seed_id(op.op_id)
        local road_id = "growth:v1:" .. op.op_id
        local record = {schema = 1, kind = "seed", id = id, road_id = road_id, origin_op_id = op.op_id,
            settlement_id = op.settlement_id, exit_id = op.exit_id, sequence = 1, from_revision = 0,
            owner = plan.owner, geometry_version = 1, policy_version = 1,
            centerline = copy(plan.centerline), headings = copy(plan.headings),
            terminal = copy(derived.endpoint), terminal_heading = derived.heading,
            preferred = {x = descriptor.direction.x, z = descriptor.direction.z},
            footprint = summary, next_seam = derived, state = "intended", created_at = store:now()}
        local bytes, save_err = store:save_record(record)
        if not bytes then return nil, save_err end
        local updated, update_err = store:update(function(d)
            if d.segs[id] then return nil, error_result("duplicate_seed", "seed " .. id .. " already exists") end
            d.segs[id] = {kind = "seed", state = "intended", writes = "unknown", cells = copy(summary.cells),
                bounds = copy(summary.bounds), bytes = bytes, origin_op_id = op.op_id,
                settlement_id = op.settlement_id, exit_id = op.exit_id}
            return true
        end)
        if not updated then store:remove_record(id); return nil, update_err end
        return {seed_id = id, state = "intended"}
    end

    -- After a built/all outcome: compare the exact patch with the world and
    -- only then mark the seed verified. Any failure leaves it "intended"
    -- (reserved, not growth-ready).
    function hooks.verify(seed)
        local ok, why = disabled(); if not ok then return nil, why end
        local entry = store:entry(seed.seed_id)
        local record, rerr = store:load_record(seed.seed_id)
        if not entry or not record or record.state ~= "intended" then return nil, rerr or error_result("seed_unavailable", "seed is not pending verification") end
        local good, cerr = check_seam(record.next_seam, record.owner)
        if not good then return nil, cerr end
        record.state = "verified"
        local bytes, save_err = store:save_record(record)
        if not bytes then return nil, save_err end
        local updated, update_err = store:update(function(d)
            local e = d.segs[seed.seed_id]
            if not e or e.state ~= "intended" then return nil, error_result("seed_unavailable", "seed changed during verification") end
            e.state = "verified"; e.writes = "all"; e.bytes = bytes
            return true
        end)
        if not updated then return nil, update_err end
        return {seed_id = seed.seed_id, state = "verified"}
    end

    -- The outward operation provably wrote nothing: release the seed.
    function hooks.void(seed)
        local entry = store:entry(seed.seed_id)
        if not entry or entry.kind ~= "seed" or entry.road_id then return true end
        local settled = store:settle(function(d)
            local e = d.segs[seed.seed_id]
            if e and e.kind == "seed" and not e.road_id then d.segs[seed.seed_id] = nil end
        end)
        if settled == true then store:remove_record(seed.seed_id) end
        return settled
    end

    -- Incoming claim on a full exit id. Returns claim | nil, and an error when
    -- claims cannot be established (the caller must fail closed).
    function hooks.claim(settlement_id, exit_id)
        local ok, why = disabled(); if not ok then return nil, why end
        local claim = store:claim("exit:" .. settlement_id .. "/" .. exit_id)
        if claim then return {kind = claim.kind, road_id = claim.road_id, segment_id = claim.segment_id, state = claim.state} end
        return nil
    end
    self.hooks = hooks

    -- Startup sweep: reconcile seeds whose outward operation provably wrote
    -- nothing. Everything else stays reserved. Never builds or repairs.
    function self:recover()
        local ok, why = disabled()
        if not ok then log("error", "growth recovery: " .. tostring(why.reason)); return nil, why end
        local summary = {roads = #store:road_ids(), seeds = 0, voided = 0, kept = 0}
        for _, id in ipairs(store:entry_ids()) do
            local e = store:entry(id)
            if e.kind == "seed" and not e.road_id and e.state == "intended" then
                summary.seeds = summary.seeds + 1
                local op = ops.find_operation(e.origin_op_id)
                if op and op.writes == "none" and (op.state == "failed" or op.state == "cancelled" or op.state == "interrupted") then
                    hooks.void({seed_id = id}); summary.voided = summary.voided + 1
                else
                    summary.kept = summary.kept + 1
                end
            end
        end
        return summary
    end

    ------------------------------------------------------------ adoption
    function self:adopt(op_id, actor)
        local ok, why = disabled(); if not ok then return nil, why end
        if type(op_id) ~= "string" or op_id == "" then
            return nil, error_result("invalid_request", "an outward operation id is required")
        end
        local road_id = "growth:v1:" .. op_id
        if store:road(road_id) then return road_id end -- idempotent
        local op = ops.find_operation(op_id)
        if not op then return nil, error_result("unknown_operation", "no outward operation " .. op_id) end
        local function refuse(code, reason) return nil, error_result(code, reason, {op_id = op_id}) end
        if op.state ~= "built" or op.writes ~= "all" then
            return refuse("not_adoptable", "only a built outward road (state " .. tostring(op.state) .. ", writes "
                .. tostring(op.writes) .. ") can be adopted")
        end
        if op.persist_failed then return refuse("not_adoptable", "the outward record is not durably saved") end
        if type(op.growth) ~= "table" or type(op.growth.seed_id) ~= "string" then
            return refuse("legacy_unadoptable", "this outward road was recorded without an intended growth seed; "
                .. "it can never be adopted, even if it still looks correct")
        end
        if op.growth.state ~= "verified" then
            return refuse("seed_unverified", "the growth seed was not verified after construction (" .. tostring(op.growth.state) .. ")")
        end
        local entry = store:entry(op.growth.seed_id)
        local record, rerr = store:load_record(op.growth.seed_id)
        if not entry or entry.kind ~= "seed" or entry.state ~= "verified" or entry.origin_op_id ~= op_id or not record then
            return refuse("seed_unverified", "the durable seed is missing, malformed or not verified" .. (rerr and (": " .. rerr.reason) or ""))
        end
        local road = op.road
        if record.state ~= "verified" or record.origin_op_id ~= op_id or record.settlement_id ~= op.settlement_id
            or record.exit_id ~= op.exit_id or type(road) ~= "table" or not point(road.terminal)
            or road.terminal.x ~= record.terminal.x or road.terminal.y ~= record.terminal.y or road.terminal.z ~= record.terminal.z
            or road.terminal_heading ~= record.terminal_heading or #road.centerline ~= #record.centerline
            or not cardinal(record.preferred) then
            return refuse("seed_mismatch", "the seed does not match the outward operation")
        end
        for i, p in ipairs(road.centerline) do
            local q = record.centerline[i]
            if not q or p.x ~= q.x or p.y ~= q.y or p.z ~= q.z then
                return refuse("seed_mismatch", "the seed geometry differs from the outward road")
            end
        end
        local good, serr = check_seam(record.next_seam, record.owner)
        if not good then return nil, serr end
        local updated, uerr = store:update(function(d)
            local e = d.segs[op.growth.seed_id]
            if not e or e.state ~= "verified" or e.road_id then return nil, error_result("seed_unverified", "seed changed during adoption") end
            if d.roads[road_id] then return true end
            e.road_id = road_id
            d.roads[road_id] = {origin_op_id = op_id, source = {settlement_id = op.settlement_id, exit_id = op.exit_id},
                preferred = copy(record.preferred), revision = 1, endpoint = copy(record.terminal),
                local_heading = record.terminal_heading, last_segment_id = op.growth.seed_id,
                segments = {op.growth.seed_id}, state = "open", next_seq = 2, activation = "needs_departure",
                attempts = {}, adopted_by = actor, adopted_at = store:now()}
            return true
        end)
        if not updated then return nil, uerr end
        return road_id
    end

    ------------------------------------------------------------ summaries
    local function trimmed(road)
        local attempts = {}
        for i = math.max(1, #(road.attempts or {}) - store.LIMITS.attempts + 1), #(road.attempts or {}) do
            attempts[#attempts + 1] = copy(road.attempts[i])
        end
        return attempts
    end
    local CONSERVATIVE = {
        uncertain = "Writes may have happened. The reservation is kept; this version never promotes, repairs or replays "
            .. "uncertain work. Use inspect to compare the world; further growth needs a separately reviewed recovery decision.",
        retired = "Growth is stopped; every reservation is retained.",
    }
    local function summarize(road_id, road)
        local act = self.active and self.active.road_id == road_id and self.active or nil
        local latest = road.attempts and road.attempts[#road.attempts] or nil
        local view = act and {scan = act.scan, candidates = act.candidates, rejected = act.rejected} or latest or {}
        return {road_id = road_id, origin_op_id = road.origin_op_id, source = copy(road.source), state = road.state,
            revision = road.revision, endpoint = copy(road.endpoint), local_heading = road.local_heading,
            preferred = copy(road.preferred), last_segment_id = road.last_segment_id, activation = road.activation,
            segments = #road.segments, pending = copy(road.pending), stop = copy(road.stop),
            retired = copy(road.retired), attempts = trimmed(road), next_seq = road.next_seq,
            stage = act and act.stage or nil, active = act ~= nil, explanation = CONSERVATIVE[road.state],
            scan = copy(view.scan), candidates = copy(view.candidates), rejected = copy(view.rejected),
            result = latest and latest.result or nil, connected = copy(road.connected),
            budgets = {chunks = MAX_CHUNKS, expansions = MAX_EXPANSIONS, destination_chunks = DEST_CHUNKS,
                reserved_chunks = MAX_CHUNKS - DEST_CHUNKS, destination_expansions = DEST_EXPANSIONS,
                reserved_expansions = RESERVED_EXPANSIONS, attempts = MAX_ATTEMPTS,
                used_chunks = act and act.agg.chunks or nil, used_expansions = act and act.agg.expansions or nil}}
    end
    local function notify(road_id)
        if ops.notify then
            local road = store:road(road_id)
            if road then pcall(ops.notify, road_id, summarize(road_id, road)) end
        end
    end

    function self:status(road_id)
        local ok, why = disabled(); if not ok then return nil, why end
        if road_id == nil then
            local ids = store:road_ids()
            local list = {}
            for i = 1, math.min(#ids, store.LIMITS.roads) do
                local road = store:road(ids[i])
                list[#list + 1] = {road_id = ids[i], state = road.state, revision = road.revision}
            end
            return {health = "ok", counts = store:counts(), roads = list}
        end
        local road = store:road(road_id)
        if not road then return nil, error_result("unknown_road", "no growth road " .. tostring(road_id)) end
        return summarize(road_id, road)
    end

    ------------------------------------------------------------ cycle
    local function current(act, token) return self.active == act and act.token == token end

    local function cancel_work(act)
        if act.survey then pcall(act.survey.cancel, act.survey) end
        if act.search then pcall(act.search.cancel, act.search) end
        if act.builder then pcall(act.builder.cancel, act.builder) end
        act.survey, act.search, act.builder, act.terrain, act.plan = nil, nil, nil, nil, nil
    end

    -- Invalidate callbacks, stop outstanding work and free the slot.
    local function end_cycle(act)
        if self.active ~= act then return false end
        cancel_work(act)
        act.token = act.token + 1
        self.active = nil
        jobs:release(act.slot)
        return true
    end

    local function push_attempt(road, act, outcome, err, result)
        road.attempts = road.attempts or {}
        road.attempts[#road.attempts + 1] = {segment_id = act.segment_id, sequence = act.sequence,
            from_revision = act.from_revision, outcome = outcome, code = err and err.code, reason = err and err.reason,
            result = result, scan = copy(act.scan), candidates = copy(act.candidates), rejected = copy(act.rejected),
            targets = copy(act.log), chunks = act.agg.chunks, expansions = act.agg.expansions}
        while #road.attempts > store.LIMITS.attempts do table.remove(road.attempts, 1) end
    end

    local function stop_fields(err)
        return {code = err.code, reason = err.reason, position = copy(err.position), limit = err.limit, observed = err.observed,
            attempted = copy(err.attempted)}
    end

    -- Known zero writes: release this segment's intent, reservation and claims.
    local function release_zero(act, err, outcome)
        local sid = act.segment_id
        local persisted = store:settle(function(d)
            local road = d.roads[act.road_id]
            if not road or not road.pending or road.pending.segment_id ~= sid then return end
            d.segs[sid] = nil
            for i, id in ipairs(road.segments) do if id == sid then table.remove(road.segments, i); break end end
            for cid, claim in pairs(d.claims) do if claim.segment_id == sid then d.claims[cid] = nil end end
            road.pending = nil; road.state = "stopped"; road.stop = stop_fields(err)
            push_attempt(road, act, outcome or "blocked", err)
        end)
        if persisted == true then
            store:remove_record(sid)
        elseif persisted == false then
            -- The stored registry may still reserve this segment (restart makes it
            -- uncertain), so its geometry record must stay readable.
            log("warning", "growth stop of " .. act.road_id .. " could not be saved; the stored registry may still "
                .. "reserve the segment and restart will report it uncertain")
        end
    end

    -- Possible writes: keep every reservation, mark uncertain.
    local function mark_uncertain(act, err, writes)
        local sid = act.segment_id
        store:settle(function(d)
            local road = d.roads[act.road_id]
            if not road or not road.pending or road.pending.segment_id ~= sid then return end
            road.state = "uncertain"; road.pending.state = "uncertain"; road.pending.writes = writes or "unknown"
            road.stop = stop_fields(err)
            local e = d.segs[sid]
            if e then e.state = "uncertain"; e.writes = writes or "unknown" end
            for _, claim in pairs(d.claims) do if claim.segment_id == sid then claim.state = "uncertain" end end
            push_attempt(road, act, "uncertain", err)
        end)
    end

    local function finish_zero(act, err, outcome)
        if self.active ~= act then return end
        if err.attempted == nil and #act.log > 0 then
            err.attempted = {}
            for _, e in ipairs(act.log) do
                err.attempted[#err.attempted + 1] = {kind = e.kind, length = e.length, approach_id = e.approach_id,
                    mode = e.mode, outcome = e.outcome}
            end
        end
        end_cycle(act)
        release_zero(act, err, outcome)
        notify(act.road_id)
    end
    local function finish_uncertain(act, err, writes)
        if self.active ~= act then return end
        end_cycle(act)
        mark_uncertain(act, err, writes)
        notify(act.road_id)
    end

    local function later(act, fn, delay)
        local token = act.token
        local ok, why = pcall(ops.after, delay or 0, function()
            if current(act, token) then fn() end
        end)
        if not ok then
            local err = error_result("survey_failed", "cannot schedule growth work: " .. tostring(why))
            if act.builder_entered then finish_uncertain(act, err) else finish_zero(act, err) end
        end
    end

    local function set_stage(act, stage) act.stage = stage end

    local next_attempt

    local function record_attempt(act, outcome, err)
        local a = act.attempt or {}
        act.log[#act.log + 1] = {kind = a.kind, mode = a.mode, approach_id = a.approach_id, length = a.length, outcome = outcome, reason = err and err.reason,
            position = err and copy(err.position), chunks_new = act.attempt_chunks or 0,
            expansions = act.attempt_expansions or 0}
        act.last_error = err
        act.outcomes[#act.outcomes + 1] = outcome
    end
    local function attempt_failed(act, err)
        act.survey, act.search, act.terrain = nil, nil, nil
        record_attempt(act, err.code, err)
        later(act, function() next_attempt(act) end, 0)
    end

    local function all_failed(act)
        local err = act.last_error or error_result("bounded_no_route", "no directional target produced a road")
        local only_budget = #act.outcomes > 0
        for _, outcome in ipairs(act.outcomes) do if not BUDGET[outcome] then only_budget = false end end
        if only_budget and act.agg.expansions >= MAX_EXPANSIONS then
            err = error_result("expansion_budget", "the cycle used its shared budget of " .. MAX_EXPANSIONS
                .. " search expansions", {limit = MAX_EXPANSIONS, observed = act.agg.expansions})
        end
        finish_zero(act, err)
    end

    local function publish(act, metrics)
        local sid = act.segment_id
        local record = act.record
        -- Exact readback of the new seam, then the saved result, then the registry.
        local good, rerr = check_seam(record.next_seam, act.owner)
        record.build = {writes = metrics and metrics.writes, pause_seconds = metrics and metrics.pause_seconds}
        if not good then
            record.state = "built"; record.seam_status = "mismatch"
            store:save_record(record)
            return finish_uncertain(act, error_result("seam_unverified", "the constructed seam differs from its intended state: "
                .. tostring(rerr and rerr.reason), {position = rerr and rerr.position}), "all")
        end
        record.state = "built"; record.seam_status = "verified"
        local bytes, save_err = store:save_record(record)
        if not bytes then
            return finish_uncertain(act, error_result("storage_failed", "the segment result could not be saved: "
                .. tostring(save_err.reason)), "all")
        end
        -- Only a verified final attachment is "connected"; a waypoint or a
        -- directional segment is never reported as arrival.
        local attempt = act.attempt or {}
        local result = attempt.kind ~= "destination" and "directional"
            or (attempt.mode == "final" and "connected" or "partial_progress")
        if result == "connected" then
            local att = act.attachment
            local called, verified, why = false, nil, nil
            if att and type(att.verify) == "function" then
                called, verified, why = pcall(att.verify, att, {plan = act.plan, endpoint = copy(record.next_seam.endpoint)})
            end
            if not called or not verified then
                return finish_uncertain(act, error_result("attachment_unverified", "the final attachment could not be verified"
                    .. " after construction: " .. tostring(type(why) == "table" and why.reason or why or "no verifier")), "all")
            end
        end
        local updated, update_err = store:update(function(d)
            local road = d.roads[act.road_id]
            if not road or road.state ~= "building" or not road.pending or road.pending.segment_id ~= sid
                or road.revision ~= act.from_revision then
                return nil, error_result("stale_revision", "the endpoint revision changed before publication")
            end
            local e = d.segs[sid]
            e.state = "built"; e.writes = "all"; e.bytes = bytes
            d.claims["endpoint:" .. act.road_id .. ":" .. act.from_revision] = nil
            for _, claim in pairs(d.claims) do
                if claim.segment_id == sid then claim.state = "held" end
            end
            road.revision = road.revision + 1
            road.endpoint = copy(record.next_seam.endpoint); road.local_heading = record.next_seam.heading
            road.last_segment_id = sid; road.state = "open"; road.pending = nil; road.stop = nil
            road.activation = "needs_departure"
            if result == "connected" then
                local d = attempt.descriptor
                road.state = "connected"
                road.connected = {kind = d.kind, id = d.id, approach_id = d.approach_id, revision = d.revision, segment_id = sid}
            end
            push_attempt(road, act, "built", nil, result)
            return true
        end)
        if not updated then
            -- Never advance optimistically: the old building intent stays reserved.
            return finish_uncertain(act, error_result("storage_failed", "the new endpoint could not be saved: "
                .. tostring(update_err.reason)), "all")
        end
        end_cycle(act)
        notify(act.road_id)
    end

    local function builder_done(act, token, err, metrics)
        if not current(act, token) then return end
        act.builder = nil
        if not err then return publish(act, metrics) end
        if err.code == "partial_build" then return finish_uncertain(act, err, "some") end
        if ZERO_WRITE[err.code] then return finish_zero(act, err) end
        return finish_uncertain(act, err, "unknown")
    end

    -- The synchronous preflight immediately before the single build.
    local function start_builder(act)
        local sid = act.segment_id
        set_stage(act, "preflight")
        local road = store:road(act.road_id)
        if not road or road.state ~= "building" or not road.pending or road.pending.segment_id ~= sid
            or road.revision ~= act.from_revision then
            return finish_zero(act, error_result("stale_revision", "the endpoint revision or pending intent changed"))
        end
        if not store:claim("endpoint:" .. act.road_id .. ":" .. act.from_revision) then
            return finish_zero(act, error_result("claim_missing", "the source claim is missing"))
        end
        for _, claim in ipairs(act.claims) do
            local stored = store:claim(claim.id)
            if not stored or stored.segment_id ~= sid then
                return finish_zero(act, error_result("claim_conflict", "claim " .. claim.id .. " is no longer held by this segment"))
            end
        end
        if act.attachment and type(act.attachment.recheck) == "function" then
            local called, fresh, why = pcall(act.attachment.recheck, act.attachment, copy(act.attempt.descriptor))
            if not called or not fresh then
                return finish_zero(act, error_result("stale_destination", "the destination changed or can no longer be attached: "
                    .. tostring(type(why) == "table" and why.reason or why or fresh)))
            end
        end
        local good, why = check_seam(act.patch, act.start_owner)
        if not good then return finish_zero(act, why) end
        local token = act.token
        act.builder_entered = true
        set_stage(act, "building")
        local started, builder, build_err = pcall(ops.start_build, act.plan, function(err, metrics)
            builder_done(act, token, err, metrics)
        end, ops.towns and ops.towns:new_guard() or nil)
        if not started then build_err = error_result("build_failed", "construction startup failed: " .. tostring(builder)); builder = nil end
        if not builder then
            act.builder_entered = false
            return finish_zero(act, build_err or error_result("build_failed", "construction could not start"))
        end
        act.builder = builder
    end

    local function commit(act)
        local plan, sid = act.plan, act.segment_id
        set_stage(act, "saving")
        local interval = ops.save_interval()
        if type(interval) ~= "number" or interval ~= interval or interval > 60 then
            return finish_zero(act, error_result("storage_failed",
                "the server map save interval is too long to guarantee durability before construction"))
        end
        -- Footprint of what is about to be built, and complete coverage of it.
        if type(plan) ~= "table" or plan.version ~= 3 or type(plan.centerline) ~= "table" or #plan.centerline < 3 then
            return attempt_failed(act, error_result("segment_too_short", "a continuation needs at least two edges to carry a seam"))
        end
        local list, lerr = columns_of(plan.centerline)
        if not list then return attempt_failed(act, lerr) end
        local summary, ferr = footprint_summary(list)
        if not summary then return attempt_failed(act, ferr) end
        local ids, cerr = store:collect(summary.bounds)
        if not ids then return finish_zero(act, cerr) end
        local mask, merr = obstacle_mask(ids, summary.bounds, seam_columns(act.patch))
        if not mask then return finish_zero(act, merr) end
        for _, p in ipairs(list) do
            if mask[key2(p)] then
                return attempt_failed(act, error_result("road_overlap", "the segment overlaps stored road " .. mask[key2(p)],
                    {position = {x = p.x, y = p.y, z = p.z}}))
            end
        end
        for _, w in ipairs(plan.writes) do
            if mask[w.x .. ":" .. w.z] then
                return attempt_failed(act, error_result("road_overlap", "a write overlaps stored road " .. mask[w.x .. ":" .. w.z],
                    {position = {x = w.x, y = w.y, z = w.z}}))
            end
        end
        -- Intended final seam from exact pre-write states plus the plan's writes.
        local snapshot, serr = capture_snapshot(plan)
        if not snapshot then return attempt_failed(act, serr) end
        local derived, derr = seam.derive(raster, plan, list, snapshot, ops.classify)
        if not derived then return attempt_failed(act, derr) end
        record_attempt(act, "composed", nil)
        local record = {schema = 1, kind = "segment", id = sid, road_id = act.road_id,
            origin_op_id = act.origin_op_id, sequence = act.sequence, from_revision = act.from_revision,
            owner = act.owner, geometry_version = 1, policy_version = 1,
            centerline = copy(plan.centerline), headings = copy(plan.headings),
            start_seam = copy(act.patch), next_seam = derived, footprint = summary,
            destination = act.attempt.kind == "destination" and {kind = act.attempt.descriptor.kind,
                id = act.attempt.descriptor.id, approach_id = act.attempt.approach_id, mode = act.attempt.mode,
                revision = act.attempt.descriptor.revision, position = copy(act.attempt.descriptor.position)} or nil,
            attempts = copy(act.log), aggregate = copy(act.agg),
            writes = #plan.writes, state = "prepared", created_at = store:now()}
        local bytes, save_err = store:save_record(record)
        if not bytes then return finish_zero(act, save_err) end
        act.record = record
        -- One registry update reserves the segment, its source and every
        -- destination-side claim together before any world write.
        local reserved, reserve_err = store:update(function(d)
            local road = d.roads[act.road_id]
            if not road or road.state ~= "planning" or not road.pending or road.pending.segment_id ~= sid
                or road.revision ~= act.from_revision then
                return nil, error_result("stale_revision", "the endpoint revision changed before reservation")
            end
            local claims = {}
            claims["endpoint:" .. act.road_id .. ":" .. act.from_revision] = {kind = "endpoint", side = "source"}
            for _, claim in ipairs(act.claims) do claims[claim.id] = {kind = claim.kind, side = claim.side or "destination"} end
            for id, claim in pairs(claims) do
                local existing = d.claims[id]
                if existing then
                    return nil, error_result("claim_conflict", "claim " .. id .. " is already held by " .. tostring(existing.road_id),
                        {claim = id, holder = existing.road_id})
                end
                claim.road_id = act.road_id; claim.segment_id = sid; claim.state = "pending"
                d.claims[id] = claim
            end
            road.state = "building"
            road.pending = {segment_id = sid, from_revision = act.from_revision, sequence = act.sequence,
                writes = "unknown", state = "building"}
            road.segments[#road.segments + 1] = sid
            d.segs[sid] = {road_id = act.road_id, kind = "segment", state = "building", writes = "unknown",
                cells = copy(summary.cells), bounds = copy(summary.bounds), bytes = bytes}
            return true
        end)
        if not reserved then return finish_zero(act, reserve_err) end
        set_stage(act, "durability_wait")
        later(act, function() start_builder(act) end, math.min(interval, 60) + 1)
    end

    local function compose_route(act, route)
        set_stage(act, "composing")
        local config = copy(act.config.composition)
        config.seam_access, config.seam_has_timer = access, ops.has_timer
        local ok, plan, why = pcall(ops.compose, act.terrain, route, config)
        if not ok then why = error_result("composition_failed", "plan composition failed: " .. tostring(plan)); plan = nil end
        if not plan then return attempt_failed(act, why or error_result("composition_failed", "route composition failed")) end
        act.plan = plan
        act.owner = act.terrain.owner or OWNER
        act.terrain, act.search, act.survey = nil, nil, nil
        commit(act)
    end

    local function search_slice(act)
        local started = ops.now()
        local ok, result = pcall(act.search.step, act.search, {max_expansions = 1000, deadline = started + 0.005}, ops.now)
        if not ok or type(result) ~= "table" then
            return attempt_failed(act, error_result("invalid_config", "planner step failed: " .. tostring(result)))
        end
        local metrics = result.metrics or {}
        local delta = math.max(0, (metrics.expansions or 0) - (act.attempt_expansions or 0))
        act.attempt_expansions = metrics.expansions or 0
        act.agg.expansions = act.agg.expansions + delta
        if result.status == "running" then return later(act, function() search_slice(act) end, 0) end
        if result.status == "succeeded" then return compose_route(act, result.route) end
        if result.status == "cancelled" then return finish_zero(act, error_result("cancelled", "search cancelled"), "cancelled") end
        local err = result.error or error_result("bounded_no_route", "planner did not produce a route")
        -- An exhausted per-attempt allowance fails this attempt only; the
        -- next attempt (and the reserved fallback) still has its share.
        attempt_failed(act, err)
    end

    local function resolve_and_search(act, terrain)
        set_stage(act, "waiting_towns")
        local waited_from = ops.now()
        local function proceed()
            local wrapped = terrain
            if ops.towns then
                if ops.towns:writer() then
                    if ops.now() - waited_from >= WRITER_WAIT then
                        return attempt_failed(act, error_result("towns_busy", "Towns kept writing terrain for " .. WRITER_WAIT .. " seconds"))
                    end
                    return later(act, proceed, 1)
                end
                local b = terrain.bounds
                local rects, why = ops.towns:overlay({x1 = b.min_x, z1 = b.min_z, x2 = b.max_x, z2 = b.max_z})
                if not rects then return attempt_failed(act, why) end
                wrapped = ops.wrap_terrain(terrain, rects)
            end
            wrapped = mask_terrain(wrapped, act.mask)
            act.terrain = wrapped
            set_stage(act, "resolving")
            local start = act.patch.endpoint
            local goal_x, goal_z = act.attempt.target.x, act.attempt.target.z
            local ok, col = pcall(wrapped.get_column, goal_x, goal_z)
            if not ok or type(col) ~= "table" or col.status ~= "ok" or not integer(col.ground_y) then
                return attempt_failed(act, error_result("invalid_endpoint", "the forward target is not known natural ground",
                    {position = {x = goal_x, z = goal_z}}))
            end
            local goal = {x = goal_x, y = col.ground_y, z = goal_z}
            local request = {start = copy(start), goal = goal, start_heading = act.patch.heading, start_seam = copy(act.patch),
                provenance = {start = {origin = "growth_seam", requested = {x = start.x, y = start.y + 0.5, z = start.z},
                        ground = copy(start), resolved = copy(start)},
                    goal = {requested = {x = goal.x, y = goal.y + 0.5, z = goal.z}, ground = copy(goal), resolved = copy(goal)}}}
            local planner_config = {weights = act.config.planner.weights, road_material = act.config.planner.road_material,
                max_expansions = act.allowance, seam_access = access, seam_has_timer = ops.has_timer}
            local made, search, serr = pcall(ops.new_planner, wrapped, request, planner_config)
            if not made then serr = error_result("invalid_config", "planner creation failed: " .. tostring(search)); search = nil end
            if not search then return attempt_failed(act, serr or error_result("invalid_config", "planner could not start")) end
            act.search = search
            act.attempt_expansions = 0
            set_stage(act, "searching")
            search_slice(act)
        end
        proceed()
    end

    local function poll_survey(act)
        local ok, result = pcall(act.survey.status, act.survey)
        if not ok or type(result) ~= "table" then
            return attempt_failed(act, error_result("survey_failed", "survey status failed: " .. tostring(result)))
        end
        if result.status == "running" then return later(act, function() poll_survey(act) end, 0.1) end
        if result.status == "cancelled" then
            return finish_zero(act, result.error or error_result("cancelled", "survey cancelled"), "cancelled")
        end
        if result.status ~= "succeeded" then
            return attempt_failed(act, result.error or error_result("survey_failed", "survey failed"))
        end
        act.survey = nil
        resolve_and_search(act, result.terrain)
    end

    -- Recheck a snapshot destination through its attachment provider. Every
    -- destination candidate comes from an installed provider, so both modes
    -- need `attachments[kind].resolve`; the result must carry a callable
    -- `recheck` (run again after the durability wait) and, for a final
    -- attachment, a callable `verify` too. All of this is checked before any
    -- survey, so an unusable attachment falls back with zero writes.
    local function resolve_destination(act, a)
        local d = a.descriptor
        local att = ops.attachments and ops.attachments[d.kind] or nil
        if type(att) ~= "table" or type(att.resolve) ~= "function" then
            return nil, error_result("attachment_unsupported", "no " .. (a.mode == "final" and "final-attachment" or "revision-checking")
                .. " provider supports " .. d.kind .. " destinations; this version cannot " .. (a.mode == "final" and "attach to "
                or "steer toward ") .. tostring(d.approach_id))
        end
        local called, resolved, why = pcall(att.resolve, att, copy(d), {mode = a.mode, endpoint = copy(act.patch.endpoint),
            preferred = copy(act.road.preferred), road_id = act.road_id})
        if not called then
            return nil, error_result("attachment_failed", "the attachment provider raised an error: " .. tostring(resolved))
        end
        if type(resolved) ~= "table" then
            return nil, error_result(type(why) == "table" and why.code or "attachment_rejected",
                type(why) == "table" and why.reason or "the destination attachment was rejected")
        end
        if type(resolved.recheck) ~= "function" or (a.mode == "final" and type(resolved.verify) ~= "function") then
            return nil, error_result("attachment_invalid", "the " .. a.mode .. " attachment for " .. tostring(d.approach_id)
                .. " lacks a callable " .. (type(resolved.recheck) ~= "function" and "recheck" or "verify"))
        end
        if resolved.revision ~= d.revision then
            return nil, error_result("stale_destination", "destination " .. tostring(d.approach_id) .. " changed from revision "
                .. tostring(d.revision) .. " to " .. tostring(resolved.revision))
        end
        if a.mode == "final" then
            local g = resolved.goal
            if type(g) ~= "table" or not integer(g.x) or not integer(g.z) then
                return nil, error_result("attachment_rejected", "the attachment has no valid goal")
            end
            a.target = {x = g.x, z = g.z}
            local claims = {}
            for _, claim in ipairs(resolved.claims or {}) do
                if #claims >= MAX_CLAIMS_PER_CYCLE or type(claim) ~= "table" or type(claim.id) ~= "string" or claim.id == ""
                    or #claim.id > 256 or type(claim.kind) ~= "string" then
                    return nil, error_result("attachment_rejected", "the attachment claims are invalid")
                end
                claims[#claims + 1] = {id = claim.id, kind = claim.kind, side = claim.side or "destination"}
            end
            for _, claim in ipairs(claims) do act.claims[#act.claims + 1] = claim end
        end
        act.attachment = resolved
        return true
    end

    -- Expansion allowance of the attempt about to run. Destination attempts
    -- never touch the reserved fallback share; fallback attempts split what
    -- remains (including unused destination allowance), the last taking all.
    local function allowance_for(act, a)
        local remaining = MAX_EXPANSIONS - act.agg.expansions
        if a.kind == "destination" then
            return math.min(DEST_EXPANSIONS, remaining - RESERVED_EXPANSIONS)
        end
        local left = 0
        for i = act.index, #act.list do if act.list[i].kind == "fallback" then left = left + 1 end end
        return math.floor(remaining / math.max(1, left))
    end

    next_attempt = function(act)
        act.index = act.index + 1
        act.attempt_chunks, act.attempt_expansions = 0, 0
        act.attachment = nil
        act.claims = copy(act.base_claims)
        local a = act.list[act.index]
        act.attempt = a
        if not a then return all_failed(act) end
        local allowance = allowance_for(act, a)
        if allowance < 1 then
            local err = error_result("expansion_budget", "the cycle used its shared budget of " .. MAX_EXPANSIONS
                .. " search expansions", {limit = MAX_EXPANSIONS, observed = act.agg.expansions})
            if a.kind == "destination" then return attempt_failed(act, err) end
            return finish_zero(act, err)
        end
        act.allowance = allowance
        if a.kind == "destination" then
            local ok, rerr = resolve_destination(act, a)
            if not ok then return attempt_failed(act, rerr) end
        end
        local start = act.patch.endpoint
        local first = {x = start.x, y = start.y, z = start.z}
        local second = {x = a.target.x, y = start.y, z = a.target.z}
        local plan, why = ops.survey.plan(first, second, act.config.world)
        if not plan then return attempt_failed(act, why or error_result("survey_failed", "survey preflight failed")) end
        local cap = a.kind == "destination" and DEST_CHUNKS or MAX_CHUNKS
        local fresh, union = {}, act.agg.chunks
        for _, c in ipairs(plan.chunks) do
            local id = c.ix .. ":" .. c.iy .. ":" .. c.iz
            if not act.chunks[id] then fresh[#fresh + 1] = id; union = union + 1 end
        end
        if union > cap then
            return attempt_failed(act, error_result("survey_budget", "this target would raise the cycle to " .. union
                .. " distinct mapchunks (" .. (a.kind == "destination" and ("destination limit " .. DEST_CHUNKS
                    .. "; the rest is reserved for fallback") or ("limit " .. MAX_CHUNKS)) .. ")", {limit = cap, observed = union}))
        end
        -- Complete obstacle coverage before anything is surveyed or generated.
        local b = plan.chunk_bounds or plan.requested_bounds
        local rect = b and {x1 = b.min_x, z1 = b.min_z, x2 = b.max_x, z2 = b.max_z}
        local ids, cerr = store:collect(rect)
        if not ids then return finish_zero(act, cerr) end
        local mask, merr = obstacle_mask(ids, rect, seam_columns(act.patch))
        if not mask then return finish_zero(act, merr) end
        act.mask = mask
        for _, id in ipairs(fresh) do act.chunks[id] = true end
        act.agg.chunks = union
        act.agg.chunk_requests = act.agg.chunk_requests + plan.chunk_count
        act.attempt_chunks = #fresh
        set_stage(act, "surveying")
        local ok, service, err = pcall(ops.start_survey, first, second, OWNER, act.config.world)
        if not ok then err = error_result("survey_failed", "survey startup failed: " .. tostring(service)); service = nil end
        if not service then return attempt_failed(act, err or error_result("survey_failed", "terrain survey could not start")) end
        act.survey = service
        later(act, function() poll_survey(act) end, 0.1)
    end

    -- Snapshot of the known destinations, taken before any survey. A provider
    -- that is installed but unhealthy fails the cycle closed.
    local function unavailable(d)
        local claim, cerr = hooks.claim(d.id, d.approach_id)
        if cerr then return "claim_lookup_failed" end
        if claim then return "claimed" end
        if ops.destination_unavailable then
            local ok, why = pcall(ops.destination_unavailable, copy(d))
            if not ok then return "unavailable" end
            if why ~= nil and why ~= false then return type(why) == "string" and why or "unavailable" end
        end
        return nil
    end
    local function select_destinations(road_id, road)
        local selection, serr = policy.select({road = {road_id = road_id, endpoint = copy(road.endpoint),
            preferred = copy(road.preferred), source = copy(road.source)}, providers = ops.providers or {},
            unavailable = unavailable})
        if not selection then return nil, serr end
        local list, candidates = {}, {}
        for _, c in ipairs(selection.candidates) do
            local d = c.descriptor
            list[#list + 1] = {kind = "destination", mode = c.mode, descriptor = copy(d), approach_id = d.approach_id,
                target = copy(c.target), length = math.floor(c.distance + 0.5)}
            candidates[#candidates + 1] = {kind = d.kind, id = d.id, approach_id = d.approach_id, mode = c.mode,
                distance = math.floor(c.distance + 0.5), result = c.outcome}
        end
        for _, f in ipairs(selection.fallback) do
            list[#list + 1] = {kind = "fallback", length = f.length, target = copy(f.target)}
        end
        local rejected = {}
        for i = 1, math.min(#selection.rejected, MAX_REJECTED) do rejected[i] = copy(selection.rejected[i]) end
        return list, selection.scan, candidates, rejected, #selection.rejected
    end

    local EXTENDABLE = {
        planning = "a growth cycle is already planning this road",
        building = "a segment is being built; wait for it or cancel",
        uncertain = "an earlier segment may have been written; it needs a separately reviewed recovery decision",
        retired = "this road was retired",
        connected = "this road is connected and does not grow",
        stopped = "this road is stopped; use retry after reviewing the reason",
    }

    function self:extend(road_id, actor, options)
        local ok, why = disabled(); if not ok then return nil, why end
        local road = store:road(road_id)
        if not road then return nil, error_result("unknown_road", "no growth road " .. tostring(road_id)) end
        if road.state ~= "open" then
            return nil, error_result("not_extendable", EXTENDABLE[road.state] or "the road is not open", {state = road.state})
        end
        local claims = {}
        for _, claim in ipairs(options and options.claims or {}) do
            if #claims >= MAX_CLAIMS_PER_CYCLE or type(claim) ~= "table" or type(claim.id) ~= "string" or claim.id == ""
                or #claim.id > 256 or type(claim.kind) ~= "string" then
                return nil, error_result("invalid_request", "claims must be at most " .. MAX_CLAIMS_PER_CYCLE .. " tables with id and kind")
            end
            claims[#claims + 1] = {id = claim.id, kind = claim.kind, side = claim.side}
        end
        local last, lerr = store:load_record(road.last_segment_id)
        if not last then return nil, lerr end
        local patch = last.next_seam
        if type(patch) ~= "table" or not point(patch.endpoint) or patch.endpoint.x ~= road.endpoint.x
            or patch.endpoint.y ~= road.endpoint.y or patch.endpoint.z ~= road.endpoint.z
            or patch.heading ~= road.local_heading or not cardinal(road.preferred) then
            return nil, error_result("seam_changed", "the stored seam does not match the road endpoint")
        end
        -- Read-only: an edited seam is reported without consuming anything.
        local good, serr = check_seam(patch, last.owner)
        if not good then return nil, serr end
        local config, cerr = ops.world_config()
        if not config then return nil, cerr or error_result("unsupported_world", "world configuration is unavailable") end
        local act = {token = 0, index = 0, stage = "planning", chunks = {}, outcomes = {}, log = {}, claims = copy(claims),
            base_claims = claims,
            agg = {chunks = 0, chunk_requests = 0, expansions = 0}, road_id = road_id, road = road, patch = patch,
            start_owner = last.owner, config = config, actor = actor, from_revision = road.revision,
            origin_op_id = road.origin_op_id}
        local slot, busy = jobs:hold({kind = "growth",
            cancel = function(who) return self:cancel(road_id, who) end,
            status = function() return {road_id = road_id, stage = act.stage, segment_id = act.segment_id} end})
        if not slot then return nil, busy end
        act.slot = slot
        -- Snapshot destinations before anything is surveyed; discoveries made
        -- later are considered next cycle.
        local list, scan, candidates, rejected, rejected_total = select_destinations(road_id, road)
        if not list then jobs:release(slot); return nil, scan end
        act.list, act.scan, act.candidates, act.rejected = list, scan, candidates, rejected
        act.scan.rejected_total = rejected_total
        -- Intent: allocate the identity and consume the activation before any survey.
        local sequence
        local intended, ierr = store:update(function(d)
            local r = d.roads[road_id]
            if not r or r.state ~= "open" or r.revision ~= act.from_revision then
                return nil, error_result("stale_revision", "the road changed before its cycle began")
            end
            sequence = r.next_seq
            r.next_seq = sequence + 1
            local sid = road_id .. ":s" .. sequence .. ":r" .. r.revision
            r.state = "planning"; r.activation = "consumed"; r.stop = nil
            r.pending = {segment_id = sid, from_revision = r.revision, sequence = sequence, writes = "none", state = "planning"}
            return true
        end)
        if not intended then jobs:release(slot); return nil, ierr end
        act.sequence = sequence
        act.segment_id = road_id .. ":s" .. sequence .. ":r" .. act.from_revision
        self.active = act
        notify(road_id)
        later(act, function() next_attempt(act) end, 0)
        if self.active ~= act then
            local after = store:road(road_id)
            return nil, after and after.stop or error_result("survey_failed", "the cycle could not be scheduled")
        end
        return act.segment_id
    end

    ------------------------------------------------------------ cancel/retry/retire
    function self:cancel(road_id, actor)
        local act = self.active
        if not act or (road_id ~= nil and act.road_id ~= road_id) then
            return nil, error_result("no_plan", "there is no active growth cycle" .. (road_id and (" for " .. tostring(road_id)) or ""))
        end
        act.cancelled_by = actor
        if act.builder_entered then
            -- The builder may already have written: stop callbacks, keep the reservation.
            finish_uncertain(act, error_result("cancelled", "cancelled after construction started" .. (actor and (" by " .. tostring(actor)) or "")
                .. "; writes are unknown"), "unknown")
        else
            finish_zero(act, error_result("cancelled", "growth cycle cancelled" .. (actor and (" by " .. tostring(actor)) or "")), "cancelled")
        end
        return true
    end

    function self:retry(road_id, actor)
        local ok, why = disabled(); if not ok then return nil, why end
        local road = store:road(road_id)
        if not road then return nil, error_result("unknown_road", "no growth road " .. tostring(road_id)) end
        if road.state ~= "stopped" then
            return nil, error_result("not_retryable", "only a stopped road with known zero writes can be retried (state "
                .. road.state .. ")", {state = road.state})
        end
        if self.active then return nil, error_result("busy", "another road job owns the server slot") end
        local last, lerr = store:load_record(road.last_segment_id)
        if not last then return nil, lerr end
        local good, serr = check_seam(last.next_seam, last.owner)
        if not good then return nil, serr end
        local reopened, rerr = store:update(function(d)
            local r = d.roads[road_id]
            if not r or r.state ~= "stopped" or r.pending then return nil, error_result("not_retryable", "the road changed") end
            r.state = "open"; r.stop_history = copy(r.stop); r.stop = nil
            return true
        end)
        if not reopened then return nil, rerr end
        local id, err = self:extend(road_id, actor)
        if not id then
            store:settle(function(d)
                local r = d.roads[road_id]
                if r and r.state == "open" then r.state = "stopped"; r.stop = r.stop_history end
            end)
            return nil, err
        end
        return id
    end

    function self:retire(road_id, actor)
        local ok, why = disabled(); if not ok then return nil, why end
        local road = store:road(road_id)
        if not road then return nil, error_result("unknown_road", "no growth road " .. tostring(road_id)) end
        if road.state == "retired" then return true end
        if road.state == "planning" or road.state == "building" then
            return nil, error_result("busy", "cancel the active cycle before retiring the road", {state = road.state})
        end
        local updated, uerr = store:update(function(d)
            local r = d.roads[road_id]
            if not r or r.state == "planning" or r.state == "building" then return nil, error_result("busy", "the road is active") end
            r.retired = {was = r.state, by = actor, at = store:now()}
            r.state = "retired"
            return true
        end)
        if not updated then return nil, uerr end
        return true
    end

    ------------------------------------------------------------ inspect
    -- Compare intended seam nodes with the loaded world. Read-only: existing
    -- mapblocks may be loaded, nothing is generated, promoted or repaired.
    local function compare_patch(patch)
        local minp, maxp = patch_bounds(patch)
        local loaded, result = pcall(ops.load_area, minp, maxp)
        local report = {checked = #patch.preserved, mismatched = 0, samples = {}, loaded = loaded and result ~= false}
        for _, p in ipairs(patch.preserved) do
            local reason
            local g_ok, node = pcall(access.get_node, p)
            if not g_ok or type(node) ~= "table" or node.name ~= p.name or node.param2 ~= p.param2 then
                reason = "node differs or is unloaded"
            else
                local m_ok, meta = pcall(access.has_metadata, p)
                local t_ok, timer = pcall(ops.has_timer, p)
                if not m_ok or meta ~= false or not t_ok or timer ~= false then reason = "metadata or timer present or unknown" end
            end
            if reason then
                report.mismatched = report.mismatched + 1
                if #report.samples < MAX_SAMPLES then
                    report.samples[#report.samples + 1] = {x = p.x, y = p.y, z = p.z, expected = p.name, reason = reason}
                end
            end
        end
        report.matches = report.mismatched == 0
        return report
    end

    function self:inspect(road_id, actor)
        local ok, why = disabled(); if not ok then return nil, why end
        local road = store:road(road_id)
        if not road then return nil, error_result("unknown_road", "no growth road " .. tostring(road_id)) end
        local report = summarize(road_id, road)
        report.claims = {}
        local ids = store:entry_ids()
        for _, sid in ipairs(road.segments) do
            local e = store:entry(sid)
            report.segments_state = report.segments_state or {}
            if #report.segments_state < store.LIMITS.road_segments then
                report.segments_state[#report.segments_state + 1] = {id = sid, state = e and e.state, writes = e and e.writes}
            end
        end
        report.index_entries = #ids
        local target_id = road.pending and road.pending.segment_id or road.last_segment_id
        local record, rerr = store:load_record(target_id)
        if not record then
            report.world = {status = "unknown", reason = rerr and rerr.reason}
            return report
        end
        local patch = record.next_seam
        report.world = {segment_id = target_id, intended = road.pending and "pending segment seam" or "current endpoint seam"}
        if type(patch) == "table" and seam.validate(raster, patch) then
            local cmp = compare_patch(patch)
            report.world.comparison = cmp
            report.world.status = cmp.matches and "matches_intended" or "mismatch"
        else
            report.world.status = "intended_seam_invalid"
        end
        report.note = "Inspection never promotes, repairs or replays work."
        return report
    end

    return self
end

growth.OWNER = OWNER
growth.MAX_CHUNKS, growth.MAX_EXPANSIONS = MAX_CHUNKS, MAX_EXPANSIONS
return growth
