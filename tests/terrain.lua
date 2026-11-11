-- SPDX-License-Identifier: GPL-3.0-or-later
-- Small immutable-like column snapshots for pure planner tests.
local terrain = {}

function terrain.new(bounds)
    local self = {columns = {}, bounds = bounds}
    function self:set_column(x, z, ground_y, options)
        options = options or {}
        local band = {}
        for offset = -3, 5 do
            local y = ground_y + offset
            local kind = y <= ground_y and "natural" or "air"
            band[offset] = {kind = kind, material = kind == "natural" and "stone" or nil,
                protected = false}
        end
        local column = {status = "ok", ground_y = ground_y, material = "stone", band = band}
        if options.status then column.status = options.status end
        self.columns[x .. ":" .. z] = column
        return column
    end
    self.get_column = function(x, z)
        local b = self.bounds
        if b and (x < b.min_x or x > b.max_x or z < b.min_z or z > b.max_z) then
            return {status = "outside"}
        end
        return self.columns[x .. ":" .. z] or {status = "unknown", reason = "fixture column absent"}
    end
    function self:set_node(x, z, y, entry)
        local column = assert(self.columns[x .. ":" .. z])
        column.band[y - column.ground_y] = entry
    end
    return self
end

function terrain.rectangle(min_x, max_x, min_z, max_z, ground_y)
    local self = terrain.new({min_x = min_x, max_x = max_x, min_z = min_z, max_z = max_z})
    for x = min_x, max_x do
        for z = min_z, max_z do self:set_column(x, z, ground_y or 0) end
    end
    return self
end

return terrain
