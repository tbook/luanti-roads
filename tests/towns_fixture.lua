-- Fake `towns_api` (version 1) for pure tests. Everything is plain data so a
-- test can change it between calls to model Towns progressing.
local fixture = {}
local full, slab, stair = 'mcl_core:cobble', 'mcl_stairs:slab_cobble', 'mcl_stairs:stair_cobble'
local facedirs = {['1:0']=1, ['-1:0']=3, ['0:1']=0, ['0:-1']=2}

-- A published exit that matches tests/connector_fixture.lua's exit() world:
-- first column at the origin, `width` columns across, columns sorted by
-- transverse coordinate like Towns does.
function fixture.exit(direction, kind, width)
    local d = direction or {x=1, z=0}; width = width or 2; kind = kind or 'flat'
    local p2 = facedirs[d.x..':'..d.z]
    local profile
    if kind == 'flat' then
        profile = {}; for n = 1, 6 do profile[n] = {y=1, name=full, param2=0} end
    elseif kind == 'down' then
        profile = {{y=2, name=full, param2=0}, {y=2, name=stair, param2=(p2+2)%4}, {y=2, name=slab, param2=0}}
    else
        profile = {{y=1, name=stair, param2=p2}, {y=1, name=full, param2=0}, {y=2, name=slab, param2=0}}
    end
    local columns = {}
    for l = 0, width - 1 do columns[#columns+1] = {x=(d.z == 0) and 0 or -l*d.z, z=(d.x == 0) and 0 or l*d.x} end
    table.sort(columns, function(a, b)
        if d.x ~= 0 then return a.z < b.z end
        return a.x < b.x
    end)
    local label = (d.x == 1 and '+x') or (d.x == -1 and '-x') or (d.z == 1 and '+z') or '-z'
    return {id = label..':'..columns[1].x..':'..columns[1].z, source = 'street',
        direction = {x=d.x, z=d.z}, columns = columns, length = #profile, profile = profile}
end

function fixture.settlement(id, exits)
    return {id = id, site_id = 'site', state = 'complete', town_type = 'medieval',
        center = {x=0, y=1, z=0}, reservation = {min={x=-60, y=-10, z=-60}, max={x=-10, y=40, z=60}},
        core = {x1=-50, z1=-50, x2=-12, z2=50}, structures = {{x1=-55, z1=-5, x2=-50, z2=5}},
        exits = exits or {fixture.exit()}}
end

-- Returns a controllable fake. fake.api is the table Roads sees.
function fixture.new(options)
    options = options or {}
    local fake = {version = options.version or 1, healthy = true, records = {}, statuses = {},
        items = {}, writer_state = nil, calls = {}, others = {}}
    local api = {version = fake.version}
    fake.api = api
    local function count(name) fake.calls[name] = (fake.calls[name] or 0) + 1 end
    function api.available() count('available'); if fake.healthy then return true end return false, 'registry unhealthy' end
    function api.settlement(id)
        count('settlement')
        if not fake.healthy then return nil, 'unavailable', 'registry unhealthy' end
        if fake.records[id] then return fake.records[id] end
        return nil, fake.statuses[id] or 'not_found', 'no such settlement'
    end
    function api.settlements(pos, radius)
        count('settlements')
        if not fake.healthy then return nil, 'unavailable', 'unavailable' end
        local list = {}
        for _, s in ipairs(fake.others) do list[#list+1] = s end
        return list
    end
    function api.exclusions(rect)
        count('exclusions')
        if fake.exclusions_error then return nil, 'unavailable', fake.exclusions_error end
        local list = {}
        for _, item in ipairs(fake.items) do
            for _, r in ipairs(item.rects) do
                if r.x1 <= rect.x2 and r.x2 >= rect.x1 and r.z1 <= rect.z2 and r.z2 >= rect.z1 then
                    list[#list+1] = item; break
                end
            end
        end
        return list
    end
    function api.writer() count('writer'); if fake.writer_error then error('boom') end return fake.writer_state end
    -- Convenience: the exclusion Towns publishes for a settlement.
    function fake.exclude_settlement(s)
        local rects = {s.core}
        for _, r in ipairs(s.structures) do rects[#rects+1] = r end
        fake.items[#fake.items+1] = {id = s.id, kind = 'settlement', state = 'complete', rects = rects,
            y_min = s.reservation.min.y, y_max = s.reservation.max.y}
    end
    return fake
end
return fixture
