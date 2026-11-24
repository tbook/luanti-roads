-- SPDX-License-Identifier: GPL-3.0-or-later
-- Pure destination ranking and waypoint policy for road growth (#49). The
-- caller supplies one road's endpoint, preferred direction and source, the
-- installed destination providers (nil when a provider is absent) and an
-- unavailability lookup. Each provider result is normalized to bounded
-- descriptors, destinations outside the forward cone are dropped, the rest are
-- ranked, and at most two are returned with their targets. The directional
-- fallback targets are always included. Nothing here reads the world or
-- storage, touches lifecycle state or starts work, and nothing is ever
-- reported as connected.
local policy = {}

policy.VERSION = 1
policy.QUERY_RADIUS = 512       -- horizontal query radius, nodes
policy.SETTLEMENT_CAP = 32      -- settlements/sites per provider query (the nearby limit)
policy.EXIT_CAP = 32            -- exit descriptors kept per settlement
policy.TOTAL_LIMIT = 1024       -- descriptors inspected per cycle, shared by all providers
policy.FINAL_RANGE = 192        -- planner endpoint separation limit
policy.WAYPOINT_LENGTH = 96     -- distant steering target, nodes
policy.FALLBACK_LENGTHS = {96, 64}
policy.MIN_ADVANCE = 32         -- a waypoint must close at least this distance
policy.MAX_CANDIDATES = 2
policy.KINDS = {"town", "village", "road"}   -- scan and report order
policy.STATUS = {none = "complete", truncated = "truncated", possible = "possibly_truncated"}

local LATTICE = 4
local MAX_COORDINATE = 31000
local MAX_TEXT = 128
local MAX_COUNTER = 2147483647
local TRUNCATION_RANK = {none = 0, possible = 1, truncated = 2}

local function err(code, reason, extra)
    local result = extra or {}
    result.code = code; result.reason = reason
    return nil, result
end

local function integer(n) return type(n) == "number" and n == math.floor(n) and math.abs(n) <= MAX_COORDINATE end
local function counter(n) return type(n) == "number" and n == math.floor(n) and n >= 0 and n <= MAX_COUNTER end
local function text(s) return type(s) == "string" and s ~= "" and #s <= MAX_TEXT end
local function squared(dx, dz) return dx * dx + dz * dz end
local function round4(v) return LATTICE * math.floor(v / LATTICE + 0.5) end

local function cardinal(d)
    return type(d) == "table" and integer(d.x) and integer(d.z) and math.abs(d.x) + math.abs(d.z) == 1
end

-- One descriptor, typed and copied. nil means the provider broke its contract,
-- which fails the cycle closed. A non-cardinal approach direction is not a
-- contract breach; the ranking reports it as an unsupported approach. Position
-- range is checked by the ranking, not here.
local function descriptor(kind, item)
    if type(item) ~= "table" or item.version ~= 1 or item.kind ~= kind then return nil end
    local p, d = item.position, item.direction
    if not text(item.id) or not text(item.approach_id) then return nil end
    if type(p) ~= "table" or not integer(p.x) or not integer(p.y) or not integer(p.z) then return nil end
    if type(d) ~= "table" or not integer(d.x) or not integer(d.z) then return nil end
    if not (counter(item.revision) or text(item.revision)) then return nil end
    return {version = 1, kind = kind, id = item.id, approach_id = item.approach_id,
        position = {x = p.x, y = p.y, z = p.z}, direction = {x = d.x, z = d.z}, revision = item.revision}
end

-- Bounded normalization of one provider result against the remaining shared
-- descriptor `budget`. Up to `budget` items are inspected (`inspected`). Items
-- beyond the settlement cap (distinct id, SETTLEMENT_CAP) or the per-settlement
-- exit cap (EXIT_CAP) are dropped. Any drop, and any result that reaches the
-- budget exactly or beyond it, is truncated. Otherwise a Towns result with
-- exactly SETTLEMENT_CAP distinct settlements is possibly truncated.
-- Returns {items, truncation, inspected} or nil, {code, reason, provider}.
function policy.normalize(kind, result, budget)
    if not integer(budget) or budget < 0 then
        return err("invalid_request", "a non-negative descriptor budget is required", {provider = kind})
    end
    if type(result) ~= "table" or type(result.items) ~= "table" or TRUNCATION_RANK[result.truncation] == nil then
        return err("provider_invalid", kind .. " returned a result without items or a known truncation state",
            {provider = kind})
    end
    local n = #result.items
    local take = math.min(n, budget)
    local items, exits, distinct, dropped = {}, {}, 0, false
    for i = 1, take do
        local d = descriptor(kind, result.items[i])
        if not d then
            return err("provider_invalid", kind .. " returned a malformed descriptor", {provider = kind, index = i})
        end
        if exits[d.id] == nil then
            if distinct >= policy.SETTLEMENT_CAP then
                dropped = true
            else
                distinct = distinct + 1
                exits[d.id] = 0
            end
        end
        if exits[d.id] ~= nil then
            if exits[d.id] >= policy.EXIT_CAP then
                dropped = true
            else
                exits[d.id] = exits[d.id] + 1
                items[#items + 1] = d
            end
        end
    end
    local truncation = result.truncation
    if dropped or n >= budget then
        truncation = "truncated"
    elseif kind == "town" and distinct >= policy.SETTLEMENT_CAP and truncation == "none" then
        truncation = "possible"
    end
    return {items = items, truncation = truncation, inspected = take}
end

-- Query one provider for at most SETTLEMENT_CAP settlements. A raised error or
-- a nil result is an unhealthy provider.
local function query(kind, provider, endpoint, budget)
    local ok, result, why = pcall(provider.nearby, provider,
        {x = endpoint.x, y = endpoint.y, z = endpoint.z}, policy.QUERY_RADIUS, policy.SETTLEMENT_CAP)
    if not ok then
        return err("provider_unhealthy", "the " .. kind .. " provider raised an error; the cycle is closed",
            {provider = kind, cause = tostring(result)})
    end
    if result == nil then
        local cause = type(why) == "table" and (why.code or why.reason) or tostring(why)
        return err("provider_unhealthy", "the " .. kind .. " provider failed; the cycle is closed",
            {provider = kind, cause = tostring(cause)})
    end
    return policy.normalize(kind, result, budget)
end

-- Ranking order: horizontal approach distance, kind, approach id, then the
-- remaining fields so that every pair of distinct descriptors has a fixed order.
local function order_key(d, endpoint)
    return {squared(d.position.x - endpoint.x, d.position.z - endpoint.z), d.kind, d.approach_id, d.id,
        d.position.x, d.position.y, d.position.z, d.direction.x, d.direction.z, tostring(d.revision)}
end

local function ranks_before(a, b, endpoint)
    local ka, kb = order_key(a, endpoint), order_key(b, endpoint)
    for i = 1, #ka do
        if ka[i] ~= kb[i] then return ka[i] < kb[i] end
    end
    return false
end

-- The lattice waypoint `length` nodes from the endpoint toward an approach.
-- Offsets are rounded to the endpoint's four-node lattice. `advance` is how
-- much nearer the waypoint is to the approach than the endpoint was.
function policy.waypoint(endpoint, approach, length)
    local dx, dz = approach.x - endpoint.x, approach.z - endpoint.z
    local distance = math.sqrt(squared(dx, dz))
    if distance == 0 then return nil end
    local tx = endpoint.x + round4(length * dx / distance)
    local tz = endpoint.z + round4(length * dz / distance)
    local after = math.sqrt(squared(approach.x - tx, approach.z - tz))
    return {x = tx, z = tz, advance = distance - after}
end

-- Directional fallback targets on the preferred vector, longest first.
function policy.fallback(endpoint, preferred)
    local result = {}
    for i, length in ipairs(policy.FALLBACK_LENGTHS) do
        result[i] = {length = length,
            target = {x = endpoint.x + length * preferred.x, z = endpoint.z + length * preferred.z}}
    end
    return result
end

-- A candidate for one retained destination, or nil and a reason when a
-- waypoint does not make the required progress.
local function candidate(endpoint, d)
    local dx, dz = d.position.x - endpoint.x, d.position.z - endpoint.z
    local distance2 = squared(dx, dz)
    local entry = {descriptor = d, distance = math.sqrt(distance2)}
    if distance2 <= policy.FINAL_RANGE * policy.FINAL_RANGE then
        entry.mode = "final"
        entry.target = {x = d.position.x, z = d.position.z}
        return entry
    end
    local wp = policy.waypoint(endpoint, d.position, policy.WAYPOINT_LENGTH)
    if not wp or wp.advance < policy.MIN_ADVANCE then return nil, "no_progress" end
    entry.mode = "waypoint"
    entry.outcome = "partial_progress"
    entry.target = {x = wp.x, z = wp.z}
    entry.advance = wp.advance
    return entry
end

-- input = {
--   road = {road_id, endpoint={x,y,z}, preferred={x,z} (cardinal),
--     source={settlement_id, exit_id}},
--   providers = {town=..., village=..., road=...},  -- each nearby(pos, radius, limit) or nil
--   unavailable = function(descriptor) -> reason | nil  -- busy, uncertain or claimed
-- }
-- Returns {scan={status, truncation, providers, inspected}, candidates,
-- rejected, fallback} or nil, {code, reason, provider?}. candidates[1] is the
-- selected destination; a "final" mode may attempt a real attachment, a
-- "waypoint" is partial progress only. Every call is a fresh snapshot, so the
-- selection can move between cycles.
function policy.select(input)
    if type(input) ~= "table" then return err("invalid_request", "a selection request is required") end
    local road = input.road
    if type(road) ~= "table" or not text(road.road_id) or type(road.endpoint) ~= "table"
        or not integer(road.endpoint.x) or not integer(road.endpoint.y) or not integer(road.endpoint.z)
        or not cardinal(road.preferred) or type(road.source) ~= "table" or not text(road.source.settlement_id) then
        return err("invalid_request",
            "a road id, integer endpoint, cardinal preferred direction and source settlement are required")
    end
    local providers = input.providers or {}
    if type(providers) ~= "table" then return err("invalid_request", "providers must be a table") end
    for _, kind in ipairs(policy.KINDS) do
        local p = providers[kind]
        if p ~= nil and (type(p) ~= "table" or type(p.nearby) ~= "function") then
            return err("invalid_request", kind .. " provider must expose nearby(pos, radius, limit)")
        end
    end
    if type(input.unavailable) ~= "function" then return err("invalid_request", "an unavailability lookup is required") end

    local endpoint, preferred = road.endpoint, road.preferred
    local items, states, truncation, inspected, present = {}, {}, "none", 0, 0
    for _, kind in ipairs(policy.KINDS) do
        local provider = providers[kind]
        if provider == nil then
            states[kind] = "absent"
        else
            present = present + 1
            local result, why = query(kind, provider, endpoint, policy.TOTAL_LIMIT - inspected)
            if not result then return nil, why end
            states[kind] = "ok"
            inspected = inspected + result.inspected
            if TRUNCATION_RANK[result.truncation] > TRUNCATION_RANK[truncation] then truncation = result.truncation end
            for _, d in ipairs(result.items) do items[#items + 1] = d end
        end
    end

    local rejected = {}
    local function reject(d, reason)
        rejected[#rejected + 1] = {kind = d.kind, approach_id = d.approach_id, reason = reason}
    end
    local pool = {}
    for _, d in ipairs(items) do
        local dx, dz = d.position.x - endpoint.x, d.position.z - endpoint.z
        local dot = dx * preferred.x + dz * preferred.z
        local reason
        if squared(dx, dz) > policy.QUERY_RADIUS * policy.QUERY_RADIUS then
            reason = "out_of_radius"
        elseif d.id == road.source.settlement_id then
            reason = "source"
        elseif d.id == road.road_id or d.approach_id == road.road_id then
            reason = "self"
        elseif not cardinal(d.direction) then
            reason = "unsupported_approach"
        elseif dot <= 0 or 4 * dot * dot < squared(dx, dz) then
            reason = "outside_cone"   -- more than 60 degrees from the preferred direction, or behind it
        else
            local why = input.unavailable(d)
            if why ~= nil and why ~= false then reason = type(why) == "string" and why or "unavailable" end
        end
        if reason then reject(d, reason) else pool[#pool + 1] = d end
    end

    table.sort(pool, function(a, b) return ranks_before(a, b, endpoint) end)
    local retained, candidates, seen = {}, {}, {}
    for _, d in ipairs(pool) do
        local key = d.kind .. ":" .. d.approach_id   -- kind keeps equal approach ids of different kinds apart
        if seen[key] then
            reject(d, "duplicate")
        elseif #retained >= policy.MAX_CANDIDATES then
            reject(d, "ranked_below")
        else
            seen[key] = true
            retained[#retained + 1] = d
        end
    end
    for _, d in ipairs(retained) do
        local entry, reason = candidate(endpoint, d)
        if entry then candidates[#candidates + 1] = entry else reject(d, reason) end
    end

    return {
        scan = {status = present == 0 and "disabled" or policy.STATUS[truncation], truncation = truncation,
            providers = states, inspected = inspected},
        candidates = candidates,
        rejected = rejected,
        fallback = policy.fallback(endpoint, preferred),
    }
end

return policy
