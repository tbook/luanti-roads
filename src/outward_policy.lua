-- SPDX-License-Identifier: GPL-3.0-or-later
-- Selection and seeded target policy for /roads_outward. Pure: the caller
-- supplies the requester position, the completed Towns settlements, the
-- normalized exits and the service's eligibility answers. Nothing here starts
-- work, touches the service lifecycle, or uses the global random state.
local policy = {}

policy.VERSION = 1
policy.RADIUS = 512            -- settlement search radius, horizontal nodes
policy.MIN_DISTANCE = 64       -- candidate distance from the outward planning landing
policy.MAX_DISTANCE = 128
policy.MAX_ANGLE = 45          -- degrees either side of the exit's outward direction
policy.MAX_COUNT = 4           -- candidates per request
policy.MAX_SEPARATION = 192    -- requested and resolved endpoint separation limit
policy.MAX_COORDINATE = 31000
local LANDING_SLACK = 11       -- resolved start may move 8 along and 3 across from the nominal landing
local SNAP_SLACK = 3           -- resolved goal snaps at most 3 nodes from the target
local DRAW_LIMIT = 64          -- bounded generator draws per request
local WARMUP = 8               -- discarded generator draws
local MODULUS = 2147483647     -- Park-Miller minimal standard generator (2^31 - 1)
local MULTIPLIER = 16807       -- products stay below 2^53, so doubles are exact

local function err(code, reason, extra)
    local result = extra or {}
    result.code = code; result.reason = reason
    return nil, result
end

local function integer(n) return type(n) == "number" and n == math.floor(n) and math.abs(n) <= policy.MAX_COORDINATE end
local function finite(n) return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge end

-- A local generator seeded from the request identity only. It never reads or
-- writes math.random, so other code's random sequence is unaffected.
local function generator(text)
    local h = 0
    for i = 1, #text do h = (h * 31 + text:byte(i)) % MODULUS end
    local state = h % (MODULUS - 1) + 1
    local function unit()
        state = (state * MULTIPLIER) % MODULUS
        return state / MODULUS
    end
    for _ = 1, WARMUP do unit() end
    return unit
end

local function squared(dx, dz) return dx * dx + dz * dz end

-- Requested separation (anchor to target) and a conservative bound on the
-- resolved separation: the resolved start lies within LANDING_SLACK of the
-- nominal landing and the resolved goal within SNAP_SLACK of the target.
function policy.within_separation(anchor, nominal, target)
    local requested2 = squared(target.x - anchor.x, target.z - anchor.z)
    if requested2 > policy.MAX_SEPARATION * policy.MAX_SEPARATION then return false end
    local to_nominal = math.sqrt(squared(target.x - nominal.x, target.z - nominal.z))
    return to_nominal + LANDING_SLACK + SNAP_SLACK <= policy.MAX_SEPARATION
end

-- Integer candidate check. The nominal landing and target are integers, so
-- the distance and angle tests are exact.
local function acceptable(desc, nominal, t)
    local vx, vz = t.x - nominal.x, t.z - nominal.z
    local d = desc.direction
    local dot = vx * d.x + vz * d.z
    if dot <= 0 or 2 * dot * dot < squared(vx, vz) then return false end -- within 45 degrees
    local d2 = squared(vx, vz)
    if d2 < policy.MIN_DISTANCE * policy.MIN_DISTANCE or d2 > policy.MAX_DISTANCE * policy.MAX_DISTANCE then return false end
    local r = desc.reservation
    if t.x >= r.x1 and t.x <= r.x2 and t.z >= r.z1 and t.z <= r.z2 then return false end
    if not integer(t.x) or not integer(t.z) then return false end
    return policy.within_separation(desc.anchor, nominal, t)
end

-- The planning landing: the first node the connector may resolve to, one step
-- beyond the built exit's length, on the lateral centre of its columns.
local function nominal_landing(desc)
    local d = desc.direction
    local lateral = {x = -d.z, z = d.x}
    local centre = math.floor((desc.offsets.min + desc.offsets.max) / 2 + 0.5)
    return {x = desc.anchor.x + (desc.length + 1) * d.x + centre * lateral.x,
        z = desc.anchor.z + (desc.length + 1) * d.z + centre * lateral.z}
end

-- The mapgen seed is kept as its decimal text, exactly as Luanti reports it.
-- It is never parsed as a double (64-bit seeds exceed 2^53). A number is only
-- accepted when it is an integer that a double holds exactly.
local SEED_MAX_LENGTH = 64
local function seed_text(seed)
    if type(seed) == "number" then
        if seed == math.floor(seed) and math.abs(seed) <= 2 ^ 53 then return string.format("%.0f", seed) end
        return nil
    end
    if type(seed) ~= "string" or seed == "" or #seed > SEED_MAX_LENGTH or seed:find("|", 1, true) then return nil end
    return seed
end

local function by_identity(a, b)
    if a.d2 ~= b.d2 then return a.d2 < b.d2 end
    return a.id < b.id
end

-- input = {
--   requester = {x, z},          -- horizontal feet position
--   world_seed = string|integer, -- the world's mapgen seed
--   settlements = {record...},   -- completed, validated Towns records (any order)
--   exit(settlement, exit_id) -> descriptor | nil, err   -- towns adapter
--   eligibility(settlement_id, exit_id?) -> state, detail  -- service
--   count = 1..4 (optional, default 4)
-- }
-- Returns {settlement_id, exit_id, settlement_distance, descriptor, nominal,
-- candidates, policy} or nil, {code, reason, ...}. Never clamps: a target that
-- breaks a bound is dropped, and no bound is relaxed.
function policy.select(input)
    if type(input) ~= "table" then return err("invalid_request", "a selection request is required") end
    local q = input.requester
    if type(q) ~= "table" or not finite(q.x) or not finite(q.z) then
        return err("invalid_request", "a horizontal requester position is required")
    end
    local seed = seed_text(input.world_seed)
    if not seed then
        return err("invalid_request", "the world seed is required: a non-empty string of at most 64 characters without '|'")
    end
    if type(input.settlements) ~= "table" then return err("invalid_request", "settlements are required") end
    if type(input.exit) ~= "function" or type(input.eligibility) ~= "function" then
        return err("invalid_request", "exit and eligibility lookups are required")
    end
    local count = input.count == nil and policy.MAX_COUNT or input.count
    if not integer(count) or count < 1 or count > policy.MAX_COUNT then
        return err("invalid_request", "between 1 and " .. policy.MAX_COUNT .. " targets may be requested", {limit = policy.MAX_COUNT, observed = count})
    end

    -- Nearest first, then by stable id. Duplicate ids are ignored.
    local ranked, seen = {}, {}
    for _, s in ipairs(input.settlements) do
        local c = type(s) == "table" and s.center
        if type(s) == "table" and type(s.id) == "string" and s.id ~= "" and not seen[s.id]
            and type(c) == "table" and integer(c.x) and integer(c.z) then
            local d2 = squared(c.x - q.x, c.z - q.z)
            if d2 <= policy.RADIUS * policy.RADIUS then
                seen[s.id] = true
                ranked[#ranked + 1] = {d2 = d2, id = s.id, record = s}
            end
        end
    end
    table.sort(ranked, by_identity)

    local chosen, blocked = nil, {}
    for _, entry in ipairs(ranked) do
        local state = input.eligibility(entry.id)
        if state == "open" then chosen = entry; break end
        blocked[#blocked + 1] = {settlement_id = entry.id, state = tostring(state)}
    end
    if not chosen then
        return err("no_eligible_settlement", "no completed settlement within " .. policy.RADIUS
            .. " nodes is open for an outward road", {considered = #ranked, blocked = blocked, radius = policy.RADIUS})
    end

    -- Exits in stable order; the first one the service reports open is used.
    -- The chosen settlement is not abandoned for another if no exit is usable.
    local exit_ids = {}
    for _, e in ipairs(chosen.record.exits or {}) do
        if type(e) == "table" and type(e.id) == "string" then exit_ids[#exit_ids + 1] = e.id end
    end
    table.sort(exit_ids)
    local descriptor, exit_id, skipped = nil, nil, {}
    for i, id in ipairs(exit_ids) do
        if i == 1 or id ~= exit_ids[i - 1] then
            local desc, why = input.exit(chosen.record, id)
            if desc then
                local state = input.eligibility(chosen.id, id)
                if state == "open" then descriptor, exit_id = desc, id; break end
                skipped[#skipped + 1] = {exit_id = id, state = tostring(state)}
            else
                skipped[#skipped + 1] = {exit_id = id, state = "unsupported", reason = type(why) == "table" and why.reason or nil}
            end
        end
    end
    if not descriptor then
        return err("no_usable_exit", "settlement " .. chosen.id .. " has no usable open exit",
            {settlement_id = chosen.id, skipped = skipped})
    end

    local nominal = nominal_landing(descriptor)
    local unit = generator(seed .. "|" .. chosen.id .. "|" .. exit_id .. "|" .. policy.VERSION)
    local d = descriptor.direction
    local lateral = {x = -d.z, z = d.x}
    local targets, draws = {}, 0
    while #targets < count and draws < DRAW_LIMIT do
        draws = draws + 1
        local distance = policy.MIN_DISTANCE + unit() * (policy.MAX_DISTANCE - policy.MIN_DISTANCE)
        local angle = (unit() * 2 - 1) * policy.MAX_ANGLE * math.pi / 180
        local ux = math.cos(angle) * d.x + math.sin(angle) * lateral.x
        local uz = math.cos(angle) * d.z + math.sin(angle) * lateral.z
        local t = {x = math.floor(nominal.x + distance * ux + 0.5), z = math.floor(nominal.z + distance * uz + 0.5)}
        local duplicate = false
        for _, existing in ipairs(targets) do
            if existing.x == t.x and existing.z == t.z then duplicate = true end
        end
        if not duplicate and acceptable(descriptor, nominal, t) then targets[#targets + 1] = t end
    end
    if #targets == 0 then
        return err("no_target", "no seeded target within " .. policy.MIN_DISTANCE .. "-" .. policy.MAX_DISTANCE
            .. " nodes of the exit's landing satisfied the bounds",
            {settlement_id = chosen.id, exit_id = exit_id, draws = draws})
    end

    local settlement_distance = math.sqrt(chosen.d2)
    return {settlement_id = chosen.id, exit_id = exit_id, settlement_distance = settlement_distance,
        descriptor = descriptor, nominal = nominal, candidates = targets,
        policy = {version = policy.VERSION, seed = seed, radius = policy.RADIUS,
            requester = {x = q.x, z = q.z}, settlement_distance = settlement_distance,
            direction = {x = d.x, z = d.z}, nominal = {x = nominal.x, z = nominal.z},
            distance_range = {policy.MIN_DISTANCE, policy.MAX_DISTANCE}, max_angle = policy.MAX_ANGLE,
            draws = draws, count = #targets}}
end

return policy
