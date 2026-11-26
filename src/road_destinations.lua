-- SPDX-License-Identifier: GPL-3.0-or-later
-- Existing-road destinations for road growth (#52): the `nearby` provider over
-- registered growth segments (through the bounded spatial index, never the
-- world's mapblocks), the final-attachment resolver for a T junction onto a flat
-- straight interior run or an end-to-end join at another unfinished road's
-- endpoint, and the busy/claimed lookup used at selection.
--
-- A descriptor names one approach: id = the target growth road id, approach_id
-- = "<segment id>#t<first edge>:<d>" (a T onto a straight flat run, approached
-- from side d) or "<segment id>#end:<d>" (the road's open endpoint, d = its
-- heading), where d is e, w, n or s, the cardinal direction from the target road
-- toward the incoming road. The target's own nodes are never written: the join
-- is expressed as a plan-v3 goal connector (see connectors.lua) whose preserved
-- patch is three rows of the target road across its full three-node width, plus
-- the usual flat transition and landing cap, which start one row beyond that
-- patch. Nothing checks a "target footprint" rectangle (road exits have none);
-- what keeps the new surfaces off the target is the three-row patch covering its
-- full width, the planner and composer seeing road nodes as non-natural (a
-- transition or landing column must be natural ground at the landing height), and
-- the growth service masking every stored footprint as an obstacle. The
-- transition bridges lattice offsets between the two roads.
-- Everything that reads or judges the world is injected; nothing writes terrain.
local destinations = {}

local KIND = "road"
local COBBLE = "mcl_core:cobble"
local ROWS = 3             -- preserved rows across (T) or along (end) the target road
local MARGIN = 2           -- claimed nodes beyond the preserved patch along the target
local MIN_AWAY = 7         -- the incoming road must start this far beyond the target centre
-- Segment records read per query. A selection reads at most this many in nearby, one for the
-- road's own seam in extend and a few in resolve, so a whole selection stays within 32 reads.
local MAX_RECORDS = 28
local MAX_ITEMS = 256      -- descriptors produced per query
local MAX_POSITIONS = 512  -- T positions considered per attempt (claims are cheap to check)
local MAX_ANCHORS = 8      -- T positions whose geometry is inspected per attempt
local DIRS = {e = {x = 1, z = 0}, w = {x = -1, z = 0}, n = {x = 0, z = 1}, s = {x = 0, z = -1}}
-- Cardinal headings (edges.lua indices) and the direction letter of each.
local HEADING_DIR = {[0] = "e", [2] = "n", [4] = "w", [6] = "s"}
local LISTED = {open = true, stopped = true, retired = true, connected = true}

local function err(code, reason, extra)
    local result = extra or {}
    result.code = code; result.reason = reason
    return nil, result
end

local function sort_candidates(list)
    table.sort(list, function(a, b)
        if a.d2 ~= b.d2 then return a.d2 < b.d2 end
        return a.approach_id < b.approach_id
    end)
end

-- Straight, flat, cardinal runs of one segment record: consecutive lattice edges
-- of equal heading and height on one line.
function destinations.runs(record)
    local c, hs = record.centerline, record.headings
    if type(c) ~= "table" or type(hs) ~= "table" or #c < 2 or #hs ~= #c - 1 then return {} end
    local runs, cur = {}, nil
    for i = 1, #hs do
        local a, b = c[i], c[i + 1]
        local d = DIRS[HEADING_DIR[hs[i]] or ""]
        if d and b.x - a.x == 4 * d.x and b.z - a.z == 4 * d.z and a.y == b.y then
            local along = d.x ~= 0 and "x" or "z"
            local line = along == "x" and a.z or a.x
            local u1, u2 = a[along], b[along]
            if cur and cur.heading == hs[i] and cur.y == a.y and cur.line == line and cur.last == i - 1 then
                cur.last = i
                cur.lo = math.min(cur.lo, u1, u2); cur.hi = math.max(cur.hi, u1, u2)
            else
                cur = {heading = hs[i], axis = along, line = line, y = a.y, first = i, last = i,
                    lo = math.min(u1, u2), hi = math.max(u1, u2)}
                runs[#runs + 1] = cur
            end
        else
            cur = nil
        end
    end
    return runs
end

-- Claim ids of a join interval: one per node coordinate along the target line, so
-- that any two joins whose intervals overlap, from either side, share an id.
local function claim_ids(axis, line, from, to)
    local ids = {}
    for u = math.min(from, to), math.max(from, to) do
        ids[#ids + 1] = {id = "join:" .. axis .. ":" .. line .. ":" .. u, kind = "join", side = "destination"}
    end
    return ids
end

-- ops = {store (growth_store), digest(value) -> revision text, connectors, edges,
--   raster, surface, access (with get_natural_light), load(minp, maxp), has_timer,
--   owner}
function destinations.new(ops)
    local store, connectors = ops.store, ops.connectors
    local self = {}

    local function world_env()
        return {access = ops.access, load = ops.load, classify = ops.surface.classify, owner = ops.owner,
            has_timer = ops.has_timer, raster = ops.raster}
    end

    ------------------------------------------------------------ candidates
    -- Every approach one built segment offers. `road` and `entry` are the stored
    -- road and segment entry; the result carries the geometry needed to describe
    -- and to resolve it.
    local function candidates_of(record, entry, road, road_id)
        local list = {}
        local listed = LISTED[road.state]
        for _, run in ipairs(destinations.runs(record)) do
            -- A T needs the whole interval plus its margin inside a straight run.
            if listed and run.hi - run.lo >= 6 then
                local perpendicular = run.axis == "x" and {"n", "s"} or {"e", "w"}
                for _, side in ipairs(perpendicular) do
                    list[#list + 1] = {kind = "t", road_id = road_id, segment_id = record.id, run = run, side = side,
                        approach_id = record.id .. "#t" .. run.first .. ":" .. side,
                        revision = ops.digest({k = "t", s = record.id, f = run.first, l = run.last, y = run.y,
                            line = run.line, axis = run.axis, lo = run.lo, hi = run.hi, side = side,
                            state = entry.state, writes = entry.writes})}
                end
            end
        end
        -- The open (or stopped) endpoint of the road's latest segment, when the
        -- last edge is straight and flat and the stored endpoint agrees.
        local hs, c = record.headings, record.centerline
        if road.last_segment_id == record.id and (road.state == "open" or road.state == "stopped")
            and type(hs) == "table" and type(c) == "table" and #hs >= 1 and #c == #hs + 1 then
            local e, h = c[#c], hs[#hs]
            local letter = HEADING_DIR[h]
            local p = road.endpoint
            if letter and road.local_heading == h and p and p.x == e.x and p.y == e.y and p.z == e.z
                and c[#c - 1].y == e.y and e.x - c[#c - 1].x == 4 * DIRS[letter].x and e.z - c[#c - 1].z == 4 * DIRS[letter].z then
                list[#list + 1] = {kind = "end", road_id = road_id, segment_id = record.id, side = letter,
                    endpoint = {x = e.x, y = e.y, z = e.z}, approach_id = record.id .. "#end:" .. letter,
                    revision = ops.digest({k = "end", s = record.id, e = {x = e.x, y = e.y, z = e.z}, h = h,
                        rev = road.revision, state = entry.state, writes = entry.writes})}
            end
        end
        return list
    end

    local function parse(approach_id)
        local segment, first, side = approach_id:match("^(.+)#t(%d+):([ewns])$")
        if segment then return segment, "t", tonumber(first), side end
        segment, side = approach_id:match("^(.+)#end:([ewns])$")
        if segment then return segment, "end", nil, side end
    end

    -- The candidate a descriptor names, recomputed from the stored registry.
    local function locate(descriptor)
        local segment, kind, first, side = parse(descriptor.approach_id)
        if not segment then return err("stale_destination", "the approach " .. tostring(descriptor.approach_id) .. " is not a road approach") end
        local entry = store:entry(segment)
        local road = entry and entry.road_id and store:road(entry.road_id) or nil
        if not entry or not road or entry.road_id ~= descriptor.id
            or (entry.state ~= "built" and entry.state ~= "verified") or entry.writes ~= "all" then
            return err("stale_destination", "the target road segment is no longer a registered built segment")
        end
        local record, rerr = store:load_record(segment)
        if not record then return err("stale_destination", "the target road segment cannot be read: " .. tostring(rerr.reason)) end
        for _, cand in ipairs(candidates_of(record, entry, road, entry.road_id)) do
            if cand.kind == kind and cand.side == side and (kind == "end" or cand.run.first == first) then
                cand.road = road
                return cand
            end
        end
        return err("stale_destination", "the target road no longer offers this approach (bend, grade or endpoint changed)")
    end

    -- Why a candidate cannot be joined right now, or nil when it is open. A claim
    -- held by this very road's own pending segment is not a conflict.
    -- Registry data only (road state and claims): no segment record is read.
    local function unavailable_by(target_id, kind, road_id)
        local road = store:road(target_id)
        if not road then return "target_missing" end
        if target_id == road_id then return "self" end
        if road.state == "planning" or road.state == "building" or road.state == "uncertain" then return "target_busy" end
        if kind == "end" then
            if road.state ~= "open" and road.state ~= "stopped" then return "target_ended" end
            local claim = store:claim("endjoin:" .. target_id)
            if claim and claim.road_id ~= road_id then return "claimed" end
        end
        return nil
    end
    local DESCRIBE = {
        self = "the target is this road's own segment",
        target_missing = "the target road is no longer registered",
        target_busy = "the target road is being extended or has uncertain work",
        target_ended = "the target road already ended (connected or retired), so its endpoint cannot be joined",
        claimed = "another road claims this join interval",
    }
    local function unavailable_reason(cand, road_id) return unavailable_by(cand.road_id, cand.kind, road_id) end
    -- Selection-time lookup, for up to 256 descriptors per cycle: registry data
    -- only. Staleness of the stored geometry (one segment record read) is checked
    -- by resolve and again by recheck, for the at most two retained candidates.
    function self.unavailable(descriptor)
        if descriptor.kind ~= KIND then return nil end
        local segment, kind = parse(descriptor.approach_id)
        if not segment then return "stale" end
        local entry = store:entry(segment)
        if not entry or entry.road_id ~= descriptor.id or (entry.state ~= "built" and entry.state ~= "verified")
            or entry.writes ~= "all" then
            return "stale"
        end
        return unavailable_by(descriptor.id, kind, nil)
    end

    ------------------------------------------------------------ provider
    local provider = {}
    function provider:nearby(pos, radius, limit)
        local ids, info = store:nearby({x = pos.x, z = pos.z}, radius)
        if not ids then return nil, info end
        local found, truncated, loaded = {}, info.truncated, 0
        for _, id in ipairs(ids) do
            local entry = store:entry(id)
            if entry and entry.road_id and (entry.state == "built" or entry.state == "verified") and entry.writes == "all" then
                local road = store:road(entry.road_id)
                if road and road.state ~= "planning" and road.state ~= "building" and road.state ~= "uncertain" then
                    if loaded >= MAX_RECORDS then truncated = true; break end
                    loaded = loaded + 1
                    -- A segment that cannot be read fails the cycle closed; it is
                    -- never taken for an empty network.
                    local record, rerr = store:load_record(id)
                    if not record then return nil, rerr end
                    if record.road_id ~= entry.road_id then
                        return nil, {code = "road_index_corrupt", reason = "segment " .. id .. " belongs to another road than its index entry"}
                    end
                    for _, cand in ipairs(candidates_of(record, entry, road, entry.road_id)) do
                        local d, position, away
                        if cand.kind == "t" then
                            d = DIRS[cand.side]
                            local run = cand.run
                            local c = cand.run.axis == "x" and pos.x or pos.z
                            c = math.max(run.lo + 3, math.min(run.hi - 3, c))
                            position = run.axis == "x" and {x = c, y = run.y, z = run.line} or {x = run.line, y = run.y, z = c}
                        else
                            d = DIRS[cand.side]
                            position = cand.endpoint
                        end
                        away = (pos.x - position.x) * d.x + (pos.z - position.z) * d.z
                        if away >= MIN_AWAY then
                            local dx, dz = position.x - pos.x, position.z - pos.z
                            found[#found + 1] = {d2 = dx * dx + dz * dz, approach_id = cand.approach_id, road_id = cand.road_id,
                                item = {version = 1, kind = KIND, id = cand.road_id, approach_id = cand.approach_id,
                                    position = position, direction = {x = d.x, z = d.z}, revision = cand.revision}}
                        end
                    end
                end
            end
        end
        sort_candidates(found)
        local items, roads, distinct = {}, {}, 0
        for _, f in ipairs(found) do
            if not roads[f.road_id] then
                if distinct >= (limit or 32) then truncated = true; break end
                roads[f.road_id] = true; distinct = distinct + 1
            end
            if #items >= MAX_ITEMS then truncated = true; break end
            items[#items + 1] = f.item
        end
        return {items = items, truncation = truncated and "truncated" or "none"}
    end
    -- The road provider has no external dependency: it is always present.
    self.providers = setmetatable({}, {__index = function(_, kind)
        if kind == KIND then return provider end
        return nil
    end})

    ------------------------------------------------------------ geometry
    -- The synthesized "exit" of a road join: three rows of the target road,
    -- from the far side (anchor) to the near side, across its full width.
    local function exit_of(cand, centre)
        local d = DIRS[cand.side]
        local anchor
        if cand.kind == "t" then
            anchor = {x = centre.x - d.x, y = centre.y, z = centre.z - d.z}
        else
            anchor = {x = cand.endpoint.x - d.x, y = cand.endpoint.y, z = cand.endpoint.z - d.z}
        end
        local profile = {}
        for i = 1, ROWS do profile[i] = {y = anchor.y, name = COBBLE, param2 = 0} end
        return {api_version = 1, settlement_id = cand.road_id, exit_id = cand.approach_id, source = "road", kind = "road",
            direction = {x = d.x, z = d.z}, anchor = anchor, offsets = {min = -1, max = 1}, length = ROWS, profile = profile}
    end

    -- Claims of a join: the interval along the target line and, for an end-to-end
    -- join, the target's endpoint itself.
    local function claims_of(cand, centre)
        if cand.kind == "t" then
            local run = cand.run
            local c = run.axis == "x" and centre.x or centre.z
            return claim_ids(run.axis, run.line, c - 1 - MARGIN, c + 1 + MARGIN)
        end
        local d = DIRS[cand.side]
        local axis = d.x ~= 0 and "x" or "z"
        local sign = d.x ~= 0 and d.x or d.z
        local e = axis == "x" and cand.endpoint.x or cand.endpoint.z
        local line = axis == "x" and cand.endpoint.z or cand.endpoint.x
        -- Last footprint column is e + sign; the margin runs back into the road.
        local list = claim_ids(axis, line, e + sign, e - sign * (1 + MARGIN))
        list[#list + 1] = {id = "endjoin:" .. cand.road_id, kind = "endjoin", side = "destination"}
        return list
    end

    -- T positions along the run, nearest the start first.
    local function anchors(cand, start)
        local run = cand.run
        local from = start[run.axis]
        local list = {}
        for c = run.lo + 3, run.hi - 3 do list[#list + 1] = c end
        table.sort(list, function(a, b)
            local da, db = math.abs(a - from), math.abs(b - from)
            if da ~= db then return da < db end
            return a < b
        end)
        local result = {}
        for i = 1, math.min(#list, MAX_POSITIONS) do
            local c = list[i]
            result[i] = run.axis == "x" and {x = c, y = run.y, z = run.line} or {x = run.line, y = run.y, z = c}
        end
        return result
    end

    local function conflicting(claims, road_id)
        for _, claim in ipairs(claims) do
            local stored = store:claim(claim.id)
            if stored and stored.road_id ~= road_id then return stored end
        end
    end

    ------------------------------------------------------------ attachment
    local attachment = {}
    function attachment:resolve(descriptor, ctx)
        if descriptor.kind ~= KIND then return err("attachment_unsupported", "not a road destination") end
        local cand, why = locate(descriptor)
        if not cand then return nil, why end
        if cand.revision ~= descriptor.revision then
            return err("stale_destination", "the target road changed from revision " .. tostring(descriptor.revision)
                .. " to " .. cand.revision)
        end
        local mode, road_id = ctx.mode, ctx.road_id
        local reason = unavailable_reason(cand, road_id)
        if reason then return err("destination_unavailable", DESCRIBE[reason] or reason) end
        local chosen
        local resolved = {revision = cand.revision}
        -- Selection to construction: the target is still a built, registered,
        -- unclaimed segment with the same geometry; for a final attachment the
        -- chosen join interval is still free and the exact target nodes are
        -- unchanged in the world. Never repairs anything.
        function resolved.recheck(_, current)
            local fresh, ferr = locate(current)
            if not fresh then return nil, ferr end
            if fresh.revision ~= cand.revision then return err("stale_destination", "the target road changed") end
            local why_not = unavailable_reason(fresh, road_id)
            if why_not then return err("destination_unavailable", DESCRIBE[why_not] or why_not) end
            if mode == "final" then
                if not chosen then return err("stale_destination", "no join was chosen") end
                local other = conflicting(chosen.claims, road_id)
                if other then
                    return err("destination_unavailable", "another road (" .. tostring(other.road_id) .. ") claims this join interval")
                end
                local c, cerr = connectors.inspect_published_exit(chosen.exit, world_env())
                if not c then
                    return err("stale_destination", "the target road nodes no longer match: " .. tostring(cerr.reason), {position = cerr.position})
                end
            end
            return true
        end
        if mode ~= "final" then return resolved end
        -- Survey target only: the middle of the run, or the endpoint. The join itself
        -- is chosen by endpoint() once the terrain is surveyed.
        if cand.kind == "t" then
            local mid = math.floor((cand.run.lo + cand.run.hi) / 2)
            resolved.goal = cand.run.axis == "x" and {x = mid, z = cand.run.line} or {x = cand.run.line, z = mid}
        else
            resolved.goal = {x = cand.endpoint.x, z = cand.endpoint.z}
        end
        -- The exact join comes from the surveyed terrain: the nearest free T position
        -- (or the endpoint) whose landing, transition and arrival heading all fit.
        function resolved.endpoint(_, terrain, context)
            local tried, claimed, last, last_claim = 0, 0, nil, nil
            local options = {}
            if cand.kind == "t" then options = anchors(cand, context.start) else options[1] = {x = cand.endpoint.x, y = cand.endpoint.y, z = cand.endpoint.z} end
            for _, centre in ipairs(options) do
                if tried >= MAX_ANCHORS then break end
                local claims = claims_of(cand, centre)
                local other = conflicting(claims, road_id)
                if other then
                    claimed = claimed + 1
                    last_claim = "another road (" .. tostring(other.road_id) .. ") claims the join interval near " .. centre.x .. "," .. centre.z
                else
                    tried = tried + 1
                    local exit = exit_of(cand, centre)
                    local made, merr = connectors.exit_goal(terrain, exit, context.start, ops.access, ops.load, ops.surface, ops.edges)
                    if made then
                        chosen = {exit = exit, claims = claims}
                        return {goal = made.goal, headings = made.headings, claims = claims,
                            joined = {road_id = cand.road_id, revision = cand.road.revision, junction = cand.kind}}
                    end
                    last = merr
                end
            end
            local what = cand.kind == "t" and "T junction" or "end-to-end join"
            local detail = last and last.reason or last_claim or "no position is available"
            return nil, {code = tried == 0 and "destination_unavailable" or "attachment_rejected", position = last and last.position,
                reason = "no " .. what .. " fits (" .. tried .. " position" .. (tried == 1 and "" or "s") .. " inspected, " .. claimed
                    .. " skipped for claims): " .. tostring(detail)}
        end
        -- After construction: the target is still registered and the whole walking
        -- path, from the new road onto the target's own nodes, is intact.
        function resolved.verify(_, result)
            local fresh, ferr = locate(descriptor)
            if not fresh then return nil, ferr end
            return connectors.verify_arrival(result.plan, world_env())
        end
        return resolved
    end
    self.attachments = {[KIND] = attachment}
    return self
end

return destinations
