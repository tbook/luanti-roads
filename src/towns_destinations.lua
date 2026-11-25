-- SPDX-License-Identifier: GPL-3.0-or-later
-- Completed-Towns destinations for road growth (#51): the `nearby` provider
-- over the public towns_api v1 (through towns_adapter), the final-attachment
-- resolver for a published exit, and the busy/claimed lookup used at selection.
-- A descriptor names one published exit: id = settlement id, approach_id = the
-- exit id (the full exit id is "<id>/<approach_id>"), revision = a digest of
-- the normalized published exit and its settlement footprint. Everything that
-- reads or judges the world is injected; nothing here writes terrain.
--
-- Attachment contract (see growth.lua): resolve(descriptor, ctx) returns
--   {revision, recheck}                                  for a waypoint, and
--   {revision, recheck, verify, endpoint, goal, claims, approaches}  for a final
-- attachment, or nil, {code, reason}. `endpoint(terrain, {start, heading})`
-- picks the landing and connector once the terrain is surveyed.
local destinations = {}

local KIND = "town"
local EXIT_CAP = 32

local function err(code, reason, extra)
    local result = extra or {}
    result.code = code; result.reason = reason
    return nil, result
end
local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for k, v in pairs(value) do result[k] = copy(v) end
    return result
end

-- Canonical text of a plain table: sorted keys, no spaces.
local function canonical(value, out)
    local t = type(value)
    if t == "table" then
        local keys = {}
        for k in pairs(value) do keys[#keys + 1] = k end
        table.sort(keys, function(a, b)
            if type(a) == type(b) then return a < b end
            return type(a) < type(b)
        end)
        out[#out + 1] = "{"
        for _, k in ipairs(keys) do
            out[#out + 1] = tostring(k); out[#out + 1] = "="
            canonical(value[k], out)
            out[#out + 1] = ","
        end
        out[#out + 1] = "}"
    else
        out[#out + 1] = t .. ":" .. tostring(value)
    end
end

-- Two small rolling digests; this identifies a change, it is not a security hash.
function destinations.revision(exit)
    local out = {}
    canonical(exit, out)
    local text = table.concat(out)
    local a, b = 7, 11
    for i = 1, #text do
        local byte = text:byte(i)
        a = (a * 31 + byte) % 2147483629
        b = (b * 131 + byte) % 2147483587
    end
    return string.format("r1:%08x%08x", a, b)
end

function destinations.claim_id(settlement_id, exit_id) return "exit:" .. settlement_id .. "/" .. exit_id end

-- ops = {towns (adapter), outward = function() -> outward service,
--   connectors, edges, raster, surface, access, load(minp, maxp), has_timer,
--   owner, present = function() -> boolean (towns_api installed)}
function destinations.new(ops)
    local towns, connectors = ops.towns, ops.connectors
    local self = {}

    -- Why a published exit cannot be joined right now, or nil when it is open.
    -- One lookup covers outward reservations (legacy built records reserve the
    -- whole settlement; partial, building and interrupted-with-writes records
    -- reserve their exit) and persistent growth claims. A claim held by this
    -- very road (its own pending reservation) is not a conflict. A lookup that
    -- cannot be answered fails closed.
    local function unavailable_reason(settlement_id, exit_id, road_id)
        local service = ops.outward and ops.outward() or nil
        if not service then return "outward_unavailable" end
        local called, state, detail = pcall(service.eligibility, service, settlement_id, exit_id)
        if not called then return "outward_unavailable" end
        if state == "open" then return nil end
        if state == "claimed" then
            local claim = type(detail) == "table" and detail.claim or nil
            if road_id and type(claim) == "table" and claim.road_id == road_id then return nil end
            return "claimed"
        end
        if state == "active" then return "outward_active" end
        if state == "reserved" then
            return type(detail) == "table" and detail.scope == "settlement" and "outward_reserved_settlement"
                or "outward_reserved_exit"
        end
        return "outward_unreadable"
    end
    local DESCRIBE = {
        claimed = "the exit is claimed by another growth road",
        outward_unavailable = "outward reservations cannot be read",
        outward_unreadable = "the stored outward record of this settlement is unreadable",
        outward_active = "an outward road is being planned from this settlement",
        outward_reserved_settlement = "a built outward road reserves the whole settlement",
        outward_reserved_exit = "a partial or uncertain outward road reserves this exit",
    }

    -- Selection-time lookup for growth's `destination_unavailable`.
    function self.unavailable(descriptor)
        if descriptor.kind ~= KIND then return nil end
        return unavailable_reason(descriptor.id, descriptor.approach_id, nil)
    end

    ------------------------------------------------------------ provider
    -- nearby(pos, radius, limit): at most `limit` settlements, at most 32 exits
    -- each. Exits the connector cannot honour (unsupported width or profile) are
    -- not approaches Roads can attach to and are skipped. Exactly 32 settlements
    -- is reported possibly truncated because towns_api v1 has no truncation flag.
    local provider = {}
    function provider:nearby(pos, radius, limit)
        local list, info = towns:scan({x = pos.x, z = pos.z}, radius, limit)
        if not list then return nil, info end
        local items, skipped = {}, 0
        for _, settlement in ipairs(list) do
            for i, published in ipairs(settlement.exits or {}) do
                if i > EXIT_CAP then break end
                local exit = type(published) == "table" and towns:exit(settlement, published.id) or nil
                if exit then
                    items[#items + 1] = {version = 1, kind = KIND, id = settlement.id, approach_id = exit.exit_id,
                        position = {x = exit.anchor.x, y = exit.anchor.y, z = exit.anchor.z},
                        direction = {x = exit.direction.x, z = exit.direction.z}, revision = destinations.revision(exit)}
                else
                    skipped = skipped + 1
                end
            end
        end
        return {items = items, truncation = info.truncation, skipped = skipped}
    end
    local present = ops.present or function() return true end
    -- An absent Towns mod disables this provider; an installed but unhealthy
    -- one fails the cycle closed (the provider returns nil, error).
    self.providers = setmetatable({}, {__index = function(_, kind)
        if kind == KIND and present() then return provider end
        return nil
    end})

    ------------------------------------------------------------ attachment
    local function current_exit(descriptor)
        local settlement, serr = towns:settlement(descriptor.id)
        if not settlement then
            return err("stale_destination", "the settlement is no longer an eligible completed settlement: " .. tostring(serr.reason))
        end
        local exit, eerr = towns:exit(settlement, descriptor.approach_id)
        if not exit then
            return err("stale_destination", "the exit is no longer usable: " .. tostring(eerr.reason))
        end
        return exit
    end

    local function world_env()
        return {access = ops.access, load = ops.load, classify = ops.surface.classify, owner = ops.owner,
            has_timer = ops.has_timer, raster = ops.raster}
    end

    -- Everything that can change between selection and construction: the
    -- published settlement and exit, the busy/claimed state and, for a final
    -- attachment, the exact built exit in the world (nodes, protection,
    -- support, headroom and daylight). Fresh Towns exclusions and the writer
    -- are checked by the builder's guard in the same synchronous step as the
    -- writes.
    local function recheck_all(mode, descriptor, road_id, expected_revision, exit)
        local fresh, why = current_exit(descriptor)
        if not fresh then return nil, why end
        if destinations.revision(fresh) ~= expected_revision or fresh.exit_id ~= exit.exit_id then
            return err("stale_destination", "the published exit changed")
        end
        local published, perr = towns:recheck(exit)
        if not published then return nil, perr end
        local reason = unavailable_reason(descriptor.id, descriptor.approach_id, road_id)
        if reason then return err("destination_unavailable", DESCRIBE[reason] or reason) end
        if mode == "final" then
            local c, cerr = connectors.inspect_published_exit(exit, world_env())
            if not c then return err("stale_destination", "the built exit no longer matches: " .. tostring(cerr.reason), {position = cerr.position}) end
        end
        return true
    end

    local attachment = {}
    function attachment:resolve(descriptor, ctx)
        if descriptor.kind ~= KIND then return err("attachment_unsupported", "not a Towns destination") end
        local exit, why = current_exit(descriptor)
        if not exit then return nil, why end
        local revision = destinations.revision(exit)
        if revision ~= descriptor.revision then
            return err("stale_destination", "the published exit changed from revision " .. tostring(descriptor.revision)
                .. " to " .. revision)
        end
        local reason = unavailable_reason(descriptor.id, descriptor.approach_id, ctx.road_id)
        if reason then return err("destination_unavailable", DESCRIBE[reason] or reason) end
        local mode, road_id = ctx.mode, ctx.road_id
        local resolved = {revision = revision}
        function resolved.recheck(_, current)
            return recheck_all(mode, current, road_id, revision, exit)
        end
        if mode ~= "final" then return resolved end
        -- Only a final attachment releases the exit's seam row from the mask.
        resolved.approaches = {{settlement_id = descriptor.id, exit_id = descriptor.approach_id}}
        resolved.goal = {x = exit.anchor.x, z = exit.anchor.z}
        resolved.claims = {{id = destinations.claim_id(descriptor.id, descriptor.approach_id), kind = "exit",
            side = "destination"}}
        -- The landing and connector come from the surveyed terrain (which already
        -- carries every exclusion and stored road as obstacles).
        function resolved.endpoint(_, terrain, context)
            return connectors.exit_goal(terrain, exit, context.start, ops.access, ops.load, ops.surface, ops.edges)
        end
        -- After construction: the published exit is unchanged and the whole
        -- walking path, road to exit, is intact in the world.
        function resolved.verify(_, result)
            local published, perr = towns:recheck(exit)
            if not published then return nil, perr end
            return connectors.verify_arrival(result.plan, world_env())
        end
        return resolved
    end
    self.attachments = {[KIND] = attachment}
    return self
end

return destinations
