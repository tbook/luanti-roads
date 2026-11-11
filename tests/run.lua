-- SPDX-License-Identifier: GPL-3.0-or-later
-- Run from the repository root: lua5.1 tests/run.lua
local raster = dofile("src/raster.lua")
local count = 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if not ok then error(name .. ": " .. tostring(err)) end
    count = count + 1
end
local function k(x, z) return x .. ":" .. z end
local function map(columns)
    local result = {}
    for i, p in ipairs(columns) do
        assert(not result[k(p.x, p.z)], "duplicate column")
        if i > 1 then
            local q = columns[i - 1]
            assert(q.x < p.x or (q.x == p.x and q.z < p.z), "unstable order")
        end
        result[k(p.x, p.z)] = p.y
    end
    return result
end

-- Independent oracle: a centerline intersects the closed unit square around
-- (x,z) when its parameter interval intersects both square slabs.
local function touches(a, b, x, z)
    local low, high = 0, 1
    for _, axis in ipairs({{a.x, b.x - a.x, x}, {a.z, b.z - a.z, z}}) do
        local start, delta, center = axis[1], axis[2], axis[3]
        if delta == 0 then
            if math.abs(start - center) > 0.5 then return false end
        else
            local t1, t2 = (center - 0.5 - start) / delta, (center + 0.5 - start) / delta
            low, high = math.max(low, math.min(t1, t2)), math.min(high, math.max(t1, t2))
        end
    end
    return low <= high
end
local function expected(a, b)
    local result = {}
    for x = math.min(a.x, b.x) - 1, math.max(a.x, b.x) + 1 do
        for z = math.min(a.z, b.z) - 1, math.max(a.z, b.z) + 1 do
            for ox = -1, 1 do
                for oz = -1, 1 do
                    if touches(a, b, x + ox, z + oz) then result[k(x, z)] = true end
                end
            end
        end
    end
    return result
end
local function connected(columns)
    local seen, pending, all = {}, {columns[1]}, map(columns)
    local n = 0
    while #pending > 0 do
        local p = table.remove(pending)
        local id = k(p.x, p.z)
        if not seen[id] then
            seen[id], n = true, n + 1
            for _, d in ipairs({{1,0}, {-1,0}, {0,1}, {0,-1}}) do
                local x, z = p.x + d[1], p.z + d[2]
                if all[k(x,z)] ~= nil and not seen[k(x,z)] then
                    pending[#pending + 1] = {x=x, z=z}
                end
            end
        end
    end
    assert(n == #columns, "disconnected footprint")
end

test("all orientations, supercover and profiles", function()
    local dirs = {{1,0},{1,1},{0,1},{-1,1},{-1,0},{-1,-1},{0,-1},{1,-1}}
    for _, d in ipairs(dirs) do
        for _, dy in ipairs({-1, 0, 1}) do
            local a = {x=-7,y=-2,z=3}
            local b = {x=a.x+4*d[1],y=a.y+dy,z=a.z+4*d[2]}
            local segment = assert(raster.segment(a,b))
            local actual, want = map(segment.columns), expected(a,b)
            assert(#segment.columns == (d[1] ~= 0 and d[2] ~= 0 and 37 or 21))
            for id in pairs(want) do assert(actual[id] ~= nil, "missing " .. id) end
            for id in pairs(actual) do assert(want[id], "unexpected " .. id) end
            local length2 = (b.x-a.x)^2 + (b.z-a.z)^2
            assert(segment.length == math.sqrt(length2))
            assert(segment.grade == math.abs(dy)/segment.length)
            for _, p in ipairs(segment.columns) do
                local t = math.max(0, math.min(1, ((p.x-a.x)*(b.x-a.x)+(p.z-a.z)*(b.z-a.z))/length2))
                assert(p.y == math.floor(a.y+t*dy+0.5))
            end
            connected(segment.columns)
        end
    end
end)

test("round ties toward positive infinity and clamp caps", function()
    local up = map(assert(raster.segment({x=0,y=-2,z=0},{x=4,y=-1,z=0})).columns)
    assert(up[k(1,0)] == -2 and up[k(2,0)] == -1)
    assert(up[k(-1,0)] == -2 and up[k(5,0)] == -1)
    local down = map(assert(raster.segment({x=0,y=0,z=0},{x=4,y=-1,z=0})).columns)
    assert(down[k(2,0)] == 0 and down[k(3,0)] == -1)
end)

test("flat bends and reversed segments", function()
    local dirs = {{1,0},{1,1},{0,1},{-1,1},{-1,0},{-1,-1},{0,-1},{1,-1}}
    for i, d in ipairs(dirs) do
        local a, b = {x=0,y=0,z=0}, {x=4*d[1],y=0,z=4*d[2]}
        local first = assert(raster.segment(a,b))
        local reverse = map(assert(raster.segment(b,a)).columns)
        for _, p in ipairs(first.columns) do assert(reverse[k(p.x,p.z)] == p.y) end
        for _, turn in ipairs({-1,0,1}) do
            local nextdir = dirs[(i-1+turn)%8+1]
            local c = {x=b.x+4*nextdir[1],y=0,z=b.z+4*nextdir[2]}
            local joined = assert(raster.join(first, assert(raster.segment(b,c))))
            connected(joined.columns)
        end
    end
    local ab = assert(raster.segment({x=0,y=0,z=0},{x=4,y=0,z=0}))
    local bc = assert(raster.segment({x=4,y=0,z=0},{x=8,y=0,z=4}))
    assert(#assert(raster.join(ab,bc)).columns == 49)
end)

test("join rejects conflicting profiles and excessive adjacent steps", function()
    local a = assert(raster.segment({x=0,y=0,z=0},{x=4,y=0,z=0}))
    local b = assert(raster.segment({x=4,y=1,z=0},{x=8,y=1,z=0}))
    local joined, err = raster.join(a,b)
    assert(not joined and err.code == "profile_conflict")
    joined, err = raster.join({columns={{x=0,y=0,z=0}}}, {columns={{x=1,y=2,z=0}}})
    assert(not joined and err.code == "step_height")
end)

test("invalid inputs", function()
    for _, b in ipairs({{x=0,y=0,z=0}, {x=4,y=0,z=2}, {x=8,y=0,z=0}, {x=4,y=0.5,z=0}}) do
        local segment, err = raster.segment({x=0,y=0,z=0},b)
        assert(not segment and err.code == "invalid_endpoint")
    end
    local segment, err = raster.segment(nil, {})
    assert(not segment and err.code == "invalid_endpoint")
end)

print("ok - " .. count .. " raster tests")
