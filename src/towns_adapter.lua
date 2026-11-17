-- SPDX-License-Identifier: GPL-3.0-or-later
-- Optional, read-only adapter for the versioned Towns `towns_api` (version 1).
-- Every call is protected and every result is validated before use. Nothing
-- from Towns storage or internals is read, and no terrain is written here.
local adapter = {}

local SUPPORTED_VERSION = 1
local DEFER_LIMIT = 180
local full, slab, stair = "mcl_core:cobble", "mcl_stairs:slab_cobble", "mcl_stairs:stair_cobble"
-- Facedirs match connectors.lua: +Z=0, +X=1, -Z=2, -X=3.
local facedirs = {["0:1"]=0, ["1:0"]=1, ["0:-1"]=2, ["-1:0"]=3}

local function err(code, reason, extra)
    local result = extra or {}
    result.code = code; result.reason = reason
    return nil, result
end
local function integer(n) return type(n) == "number" and n == math.floor(n) and math.abs(n) <= 31000 end
local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for k, v in pairs(value) do result[k] = copy(v) end
    return result
end
local function equal(a, b)
    if type(a) ~= type(b) then return false end
    if type(a) ~= "table" then return a == b end
    for k, v in pairs(a) do if not equal(v, b[k]) then return false end end
    for k in pairs(b) do if a[k] == nil then return false end end
    return true
end
local function valid_rect(r)
    return type(r) == "table" and integer(r.x1) and integer(r.z1) and integer(r.x2) and integer(r.z2)
        and r.x1 <= r.x2 and r.z1 <= r.z2
end
local function overlaps(a, b) return a.x1 <= b.x2 and a.x2 >= b.x1 and a.z1 <= b.z2 and a.z2 >= b.z1 end

-- A bucketed rectangle index keeps per-column lookups cheap during search.
-- items: {x1,z1,x2,z2, ...}. clip (optional) limits the buckets that are built.
local CELL = 16
local function new_index(items, clip)
    local buckets, count = {}, 0
    for _, item in ipairs(items) do
        local x1, z1, x2, z2 = item.x1, item.z1, item.x2, item.z2
        if clip then
            x1, z1 = math.max(x1, clip.x1), math.max(z1, clip.z1)
            x2, z2 = math.min(x2, clip.x2), math.min(z2, clip.z2)
        end
        if x1 <= x2 and z1 <= z2 then
            for cx = math.floor(x1 / CELL), math.floor(x2 / CELL) do
                for cz = math.floor(z1 / CELL), math.floor(z2 / CELL) do
                    local key = cx .. ":" .. cz
                    local list = buckets[key]
                    if not list then list = {}; buckets[key] = list end
                    list[#list + 1] = item
                end
            end
            count = count + 1
        end
    end
    local index = {count = count}
    function index.at(x, z)
        local list = buckets[math.floor(x / CELL) .. ":" .. math.floor(z / CELL)]
        if list then
            for _, item in ipairs(list) do
                if x >= item.x1 and x <= item.x2 and z >= item.z1 and z <= item.z2 then return item end
            end
        end
    end
    return index
end

-- Report every column inside an overlay rectangle as a structure so that
-- search, connector transitions and composition share the same exclusion rule.
function adapter.wrap_terrain(terrain, rects)
    local b = terrain.bounds
    local index = new_index(rects, b and {x1 = b.min_x, z1 = b.min_z, x2 = b.max_x, z2 = b.max_z})
    local wrapped = {}
    for k, v in pairs(terrain) do wrapped[k] = v end
    wrapped.get_column = function(x, z)
        if index.at(x, z) then return {status = "structure", reason = "Towns exclusion"} end
        return terrain.get_column(x, z)
    end
    return wrapped
end

local function strip_rect(columns, d, steps)
    local r
    for _, c in ipairs(columns) do
        for _, n in ipairs({0, steps}) do
            local x, z = c.x + d.x * n, c.z + d.z * n
            if not r then r = {x1 = x, z1 = z, x2 = x, z2 = z}
            else r.x1 = math.min(r.x1, x); r.x2 = math.max(r.x2, x); r.z1 = math.min(r.z1, z); r.z2 = math.max(r.z2, z) end
        end
    end
    return r
end

function adapter.new(get_api, now)
    local self = {}
    local clock = type(now) == "function" and now or function() return 0 end

    local function api()
        local ok, value = pcall(get_api)
        if not ok or type(value) ~= "table" then
            return err("towns_unavailable", "the Towns mod is not installed")
        end
        if value.version ~= SUPPORTED_VERSION then
            return err("towns_unsupported", "unsupported Towns API version " .. tostring(value.version))
        end
        for _, name in ipairs({"available", "settlement", "settlements", "exclusions", "writer"}) do
            if type(value[name]) ~= "function" then return err("towns_unsupported", "Towns API lacks " .. name) end
        end
        return value
    end

    function self:available()
        local a, e = api(); if not a then return nil, e end
        local ok, good, reason = pcall(a.available)
        if not ok or good ~= true then
            return err("towns_unavailable", "Towns settlement registry is unavailable: " .. tostring(ok and reason or good))
        end
        return true
    end

    -- Complete published settlements only.
    function self:settlement(id)
        local a, e = api(); if not a then return nil, e end
        local good, aerr = self:available(); if not good then return nil, aerr end
        if type(id) ~= "string" or id == "" then return err("ineligible_settlement", "settlement id is required", {status = "not_found"}) end
        local called, s, status, message = pcall(a.settlement, id)
        if not called then return err("towns_unavailable", "Towns settlement query failed") end
        if type(s) ~= "table" then
            return err("ineligible_settlement", "settlement is not an eligible completed settlement: "
                .. tostring(status) .. (message and (" (" .. tostring(message) .. ")") or ""), {status = tostring(status)})
        end
        local c, r = s.center, s.reservation
        local function pos(p) return type(p) == "table" and integer(p.x) and integer(p.y) and integer(p.z) end
        local ok_shape = s.id == id and s.state == "complete" and pos(c) and type(r) == "table"
            and pos(r.min) and pos(r.max) and type(s.core) == "table"
            and valid_rect(s.core) and type(s.structures) == "table" and type(s.exits) == "table"
        for _, rect in ipairs(ok_shape and s.structures or {}) do ok_shape = ok_shape and valid_rect(rect) end
        if not ok_shape then return err("ineligible_settlement", "published settlement record is malformed", {status = "invalid"}) end
        return copy(s)
    end

    -- Normalize one published exit; reject anything the connector cannot honour.
    function self:exit(settlement, exit_id)
        if type(settlement) ~= "table" or type(exit_id) ~= "string" then
            return err("unsupported_exit", "settlement and exit id are required")
        end
        local found
        for _, e in ipairs(settlement.exits or {}) do
            if type(e) == "table" and e.id == exit_id then
                if found then return err("unsupported_exit", "exit id is not unique") end
                found = e
            end
        end
        if not found then return err("unsupported_exit", "exit is not published for this settlement") end
        local d = found.direction
        local facedir = type(d) == "table" and integer(d.x) and integer(d.z) and facedirs[d.x .. ":" .. d.z]
        if not facedir then return err("unsupported_exit", "exit direction is not a cardinal unit vector") end
        local length = found.length
        if not integer(length) or length < 1 or length > 16 or type(found.profile) ~= "table" or #found.profile ~= length then
            return err("unsupported_exit", "exit length does not match its profile")
        end
        local cols = found.columns
        if type(cols) ~= "table" or #cols < 1 or #cols > 4 then return err("unsupported_exit", "exit columns are invalid") end
        local lateral = {x = -d.z, z = d.x}
        local offsets, seen = {}, {}
        for _, c in ipairs(cols) do
            if type(c) ~= "table" or not integer(c.x) or not integer(c.z) then return err("unsupported_exit", "exit column is invalid") end
            local dx, dz = c.x - cols[1].x, c.z - cols[1].z
            if dx * d.x + dz * d.z ~= 0 then return err("unsupported_exit", "exit columns are not aligned across the road") end
            local off = dx * lateral.x + dz * lateral.z
            if seen[off] then return err("unsupported_exit", "exit columns repeat") end
            seen[off] = true; offsets[#offsets + 1] = off
        end
        table.sort(offsets)
        for i = 2, #offsets do
            if offsets[i] ~= offsets[i - 1] + 1 then return err("unsupported_exit", "exit columns are not contiguous") end
        end
        if #offsets ~= 2 and #offsets ~= 4 then
            return err("unsupported_exit", "exit width " .. #offsets .. " is unsupported; only 2 or 4 nodes are connectable")
        end
        local profile = {}
        for i, p in ipairs(found.profile) do
            if type(p) ~= "table" or not integer(p.y) or not integer(p.param2) then
                return err("unsupported_exit", "exit profile entry is invalid")
            end
            local good = (p.name == full and p.param2 == 0) or (p.name == slab and p.param2 == 0)
                or (p.name == stair and (p.param2 == facedir or p.param2 == (facedir + 2) % 4))
            if not good then return err("unsupported_exit", "exit node " .. tostring(p.name) .. " with param2 " .. p.param2 .. " is unsupported") end
            profile[i] = {y = p.y, name = p.name, param2 = p.param2}
        end
        local r = settlement.reservation
        return {api_version = SUPPORTED_VERSION, settlement_id = settlement.id, exit_id = found.id,
            source = found.source, direction = {x = d.x, z = d.z},
            anchor = {x = cols[1].x, y = profile[1].y, z = cols[1].z},
            offsets = {min = offsets[1], max = offsets[#offsets]}, length = length, profile = profile,
            columns = copy(cols), center = copy(settlement.center), town_type = settlement.town_type,
            reservation = {x1 = r.min.x, z1 = r.min.z, x2 = r.max.x, z2 = r.max.z}}
    end

    function self:writer()
        local a = api(); if not a then return nil end
        local ok, w = pcall(a.writer)
        if not ok then return {kind = "unknown", phase = "query_failed", since = clock()} end
        if w == nil then return nil end
        if type(w) ~= "table" then return {kind = "unknown", phase = "malformed", since = clock()} end
        return copy(w)
    end

    local function exclusion_items(a, rect)
        local ok, list, reason = pcall(a.exclusions, rect)
        if not ok or type(list) ~= "table" then
            return err("towns_unavailable", "Towns exclusions are unavailable: " .. tostring(ok and reason or list))
        end
        return list
    end

    -- Exclusion rectangles Roads must treat as structures inside a survey rect:
    -- every Towns exclusion of any kind or state plus the footprints of the
    -- other published exits. The selected exit's own steps are protected by
    -- the connector's preserved constraints instead.
    function self:overlay(rect, source, selected_exit_id)
        local a, e = api(); if not a then return nil, e end
        if not valid_rect({x1 = rect.x1, z1 = rect.z1, x2 = rect.x2, z2 = rect.z2}) then
            return err("towns_unavailable", "invalid survey rectangle")
        end
        local good, aerr = self:available(); if not good then return nil, aerr end
        local list, le = exclusion_items(a, rect); if not list then return nil, le end
        local rects = {}
        for _, item in ipairs(list) do
            if type(item) ~= "table" or type(item.rects) ~= "table" then
                return err("towns_unavailable", "malformed Towns exclusion")
            end
            for _, r in ipairs(item.rects) do
                if not valid_rect(r) then return err("towns_unavailable", "malformed Towns exclusion") end
                if overlaps(r, rect) then rects[#rects + 1] = {x1 = r.x1, z1 = r.z1, x2 = r.x2, z2 = r.z2} end
            end
        end
        local function add_exits(settlement, skip)
            for _, ex in ipairs(settlement.exits or {}) do
                if ex.id ~= skip and type(ex.direction) == "table" and type(ex.columns) == "table" and integer(ex.length) then
                    local r = strip_rect(ex.columns, ex.direction, ex.length) -- steps 0..L, including the seam
                    if r and overlaps(r, rect) then rects[#rects + 1] = r end
                end
            end
        end
        if source then add_exits(source, selected_exit_id) end
        local cx, cz = (rect.x1 + rect.x2) / 2, (rect.z1 + rect.z2) / 2
        local half = math.sqrt((rect.x2 - rect.x1) ^ 2 + (rect.z2 - rect.z1) ^ 2) / 2
        local called, others, why = pcall(a.settlements, {x = math.floor(cx), z = math.floor(cz)},
            math.min(1024, math.ceil(half + 256)))
        if not called or type(others) ~= "table" then
            return err("towns_unavailable", "Towns settlements are unavailable: " .. tostring(called and why or others))
        end
        for _, s in ipairs(others) do
            if type(s) == "table" and (not source or s.id ~= source.id) then add_exits(s) end
        end
        return rects
    end

    -- Build-time guard. A fresh guard tracks its own deferral limit. Returns
    -- 'ok', 'defer', or 'fail' plus an error.
    function self:new_guard()
        local first_defer
        return function(plan)
            local function defer()
                first_defer = first_defer or clock()
                if clock() - first_defer >= DEFER_LIMIT then
                    return "fail", {code = "towns_busy", reason = "Towns kept writing terrain for " .. DEFER_LIMIT .. " seconds"}
                end
                return "defer"
            end
            if self:writer() then return defer() end
            local a, e = api(); if not a then return "fail", e end
            local x1, z1, x2, z2
            for _, p in ipairs(plan.writes) do
                x1 = x1 and math.min(x1, p.x) or p.x; x2 = x2 and math.max(x2, p.x) or p.x
                z1 = z1 and math.min(z1, p.z) or p.z; z2 = z2 and math.max(z2, p.z) or p.z
            end
            if not x1 then first_defer = nil; return "ok" end
            local list, le = exclusion_items(a, {x1 = x1, z1 = z1, x2 = x2, z2 = z2})
            if not list then return "fail", le end
            local holds, blocks = false, {}
            for _, item in ipairs(list) do
                if type(item) ~= "table" or type(item.rects) ~= "table" then
                    return "fail", {code = "towns_unavailable", reason = "malformed Towns exclusion"}
                end
                if item.kind == "candidate" then
                    for _, r in ipairs(item.rects) do if valid_rect(r) and overlaps(r, {x1 = x1, z1 = z1, x2 = x2, z2 = z2}) then holds = true end end
                else
                    for _, r in ipairs(item.rects) do
                        if valid_rect(r) then
                            blocks[#blocks + 1] = {x1 = r.x1, z1 = r.z1, x2 = r.x2, z2 = r.z2,
                                y_min = integer(item.y_min) and item.y_min or -31000,
                                y_max = integer(item.y_max) and item.y_max or 31000, id = item.id}
                        end
                    end
                end
            end
            local index = new_index(blocks)
            for _, p in ipairs(plan.writes) do
                local b = index.at(p.x, p.z)
                if b and p.y >= b.y_min and p.y <= b.y_max then
                    return "fail", {code = "towns_conflict", reason = "road write lies inside Towns area " .. tostring(b.id),
                        position = {x = p.x, y = p.y, z = p.z}}
                end
            end
            if holds then return defer() end
            first_defer = nil
            return "ok"
        end
    end

    -- Published records are immutable, but a wrong or downgraded Towns could
    -- differ; require the identical exit immediately before committing.
    function self:recheck(descriptor)
        local s, e = self:settlement(descriptor.settlement_id)
        if not s then return nil, {code = "stale_exit", reason = "settlement is no longer eligible: " .. tostring(e.reason)} end
        local current, ee = self:exit(s, descriptor.exit_id)
        if not current then return nil, {code = "stale_exit", reason = "exit is no longer usable: " .. tostring(ee.reason)} end
        if not equal(current, descriptor) then return nil, {code = "stale_exit", reason = "published exit changed"} end
        return true
    end

    return self
end

return adapter
