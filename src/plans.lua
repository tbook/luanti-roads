-- SPDX-License-Identifier: GPL-3.0-or-later
-- Pure composition of a route against the same immutable terrain snapshot.
local plans = {}
local raster, edges
local dirs = {{1,0},{1,1},{0,1},{-1,1},{-1,0},{-1,-1},{0,-1},{1,-1}}
local function copy(v)
    if type(v) ~= 'table' then return v end
    local result = {}
    for k, value in pairs(v) do result[k] = copy(value) end
    return result
end
local function fail(code, reason, position, extra)
    local e = extra or {}; e.code, e.reason, e.position = code, reason, position
    return nil, e
end
local function finite(n) return type(n)=='number' and n==n and n~=math.huge and n~=-math.huge end
local function integer(n) return finite(n) and n==math.floor(n) end
local function point(p) return type(p)=='table' and integer(p.x) and integer(p.y) and integer(p.z) end
local function same(a,b) return point(a) and point(b) and a.x==b.x and a.y==b.y and a.z==b.z end
local function key(x,z) return x .. ':' .. z end
local function sort_nodes(a,b)
    if a.x ~= b.x then return a.x < b.x end
    if a.z ~= b.z then return a.z < b.z end
    return a.y < b.y
end
function plans.set_dependencies(r, e)
    if type(r) ~= 'table' or type(r.segment) ~= 'function' or type(r.join) ~= 'function'
        or type(e) ~= 'table' or type(e.evaluate) ~= 'function' then
        return nil, 'raster and edge dependencies are required'
    end
    raster, edges = r, e
    return true
end

function plans.compose(terrain, route, config)
    if not raster or not edges or type(terrain) ~= 'table' or type(terrain.get_column) ~= 'function'
        or type(config) ~= 'table' or config.road_material == nil then
        return fail('invalid_config', 'dependencies, terrain, and road_material are required')
    end
    local cap = config.max_writes
    if cap == nil then cap = 10000 end
    if not integer(cap) or cap < 1 or cap > 10000 then
        return fail('invalid_config', 'max_writes must be an integer between 1 and 10000')
    end
    if type(route) ~= 'table' or type(route.centerline) ~= 'table' or #route.centerline < 2
        or type(route.headings) ~= 'table' or #route.headings ~= #route.centerline - 1
        or type(route.request) ~= 'table' or type(route.request.provenance) ~= 'table'
        or type(route.parameters) ~= 'table' or type(route.metrics) ~= 'table' or not finite(route.cost) then
        return fail('composition_failed', 'route is incomplete')
    end
    if route.parameters.road_material ~= nil and route.parameters.road_material ~= config.road_material then
        return fail('invalid_config', 'road material differs from the material used by the planner')
    end
    local request = route.request
    for _,name in ipairs({'start','goal'}) do
        local p = request.provenance[name]
        if type(p) ~= 'table' or type(p.requested) ~= 'table'
            or not finite(p.requested.x) or not finite(p.requested.y) or not finite(p.requested.z) or not point(p.ground)
            or not same(p.resolved, request[name]) then
            return fail('invalid_endpoint', 'endpoint provenance is missing or inconsistent')
        end
    end
    local a,b = request.start,request.goal
    local pa,pb = request.provenance.start,request.provenance.goal
    local constraints, has_connector
    has_connector=pa.connector or pb.connector
    if has_connector then
        if type(edges.connector_constraints)~='function' then return fail('invalid_config','connector constraints unavailable') end
        local why; constraints,why=edges.connector_constraints(request.provenance)
        if not constraints then return fail('invalid_endpoint',why) end
    end
    local function valid_endpoint(p)
        return p.ground.x == math.floor(p.requested.x+0.5)
            and p.ground.z == math.floor(p.requested.z+0.5)
            and math.abs(p.requested.y-(p.ground.y+0.5)) <= 0.5
    end
    local dx,dz = b.x-a.x,b.z-a.z
    local rdx,rdz = pb.requested.x-pa.requested.x,pb.requested.z-pa.requested.z
    if not valid_endpoint(pa) or not valid_endpoint(pb) or (not pa.connector and not same(pa.ground,a))
        or (dx==0 and dz==0) or dx%4~=0 or dz%4~=0 or dx*dx+dz*dz>192*192
        or rdx*rdx+rdz*rdz>192*192
        or (not pb.connector and (b.x~=a.x+4*math.floor((pb.requested.x-a.x)/4+0.5)
        or b.z~=a.z+4*math.floor((pb.requested.z-a.z)/4+0.5)
        or (pb.requested.x-b.x)^2+(pb.requested.z-b.z)^2>9
        or math.abs(pb.ground.y-b.y)>2)) then
        return fail('invalid_endpoint', 'endpoint provenance is inconsistent')
    end
    local checked={a,b}
    if not pa.connector then checked[#checked+1]=pa.ground end
    if not pb.connector then checked[#checked+1]=pb.ground end
    for _,p in ipairs(checked) do
        local ok,c = pcall(terrain.get_column,p.x,p.z)
        if not ok or type(c)~='table' or c.status~='ok' or c.ground_y~=p.y then
            return fail('invalid_endpoint', 'endpoint does not match surveyed ground', copy(p))
        end
    end
    if not same(route.centerline[1], request.start) or not same(route.centerline[#route.centerline], request.goal) then
        return fail('invalid_endpoint', 'route endpoints do not match request')
    end
    local surfaces, surface_list = {}, {}
    local anchor = route.centerline[1]
    for i=1,#route.headings do
        local a,b,h = route.centerline[i],route.centerline[i+1],route.headings[i]
        if not point(a) or not point(b) or not integer(h) or h<0 or h>7 then
            return fail('composition_failed', 'invalid centerline or heading')
        end
        local d = dirs[h+1]
        if b.x-a.x~=4*d[1] or b.z-a.z~=4*d[2] then
            return fail('composition_failed', 'heading does not match centerline', b)
        end
        local state = {i=(a.x-anchor.x)/4, j=(a.z-anchor.z)/4, heading=route.headings[i-1]}
        local edge = edges.evaluate(terrain, anchor, state, h,
            {weights=route.parameters.weights, road_material=config.road_material, constraints=constraints})
        if not edge.ok then return fail('composition_failed', 'edge rejected: '..tostring(edge.code)..': '..tostring(edge.reason), edge.position) end
        local ca, cb = terrain.get_column(a.x,a.z), terrain.get_column(b.x,b.z)
        if ca.ground_y ~= a.y or cb.ground_y ~= b.y then
            return fail('composition_failed', 'centerline height differs from terrain', a)
        end
        local segment, err = raster.segment(a,b)
        if not segment then return fail('composition_failed', err.reason, err.position) end
        for _,p in ipairs(segment.columns) do
            local id = key(p.x,p.z)
            local old = surfaces[id]
            if old and old.y ~= p.y then
                return fail('composition_failed', 'overlapping surface heights conflict', copy(p))
            elseif not old then
                -- Every surface requires a road node and at least four expectations.
                -- This independent bound prevents a no-op route exhausting memory.
                if #surface_list >= 50000 then
                    return fail('composition_failed', 'surface allocation limit reached', copy(p), {limit=50000, observed=#surface_list+1})
                end
                local q = copy(p); surfaces[id] = q; surface_list[#surface_list+1] = q
            end
        end
    end
    for _,endpoint in ipairs({pa,pb}) do
        if endpoint.connector then
            local ok,err=edges.check_surfaces(terrain,endpoint.connector.transition.surfaces,config.road_material)
            if not ok then return fail('composition_failed','transition rejected: '..tostring(err.reason),err.position) end
            for _,p in ipairs(endpoint.connector.transition.surfaces) do
                local id=key(p.x,p.z); local old=surfaces[id]
                if old and old.y~=p.y then return fail('composition_failed','transition surface conflicts with road',p) end
                if not old then
                    if #surface_list>=50000 then return fail('composition_failed','surface allocation limit reached',p) end
                    local q=copy(p); surfaces[id]=q; surface_list[#surface_list+1]=q
                end
            end
        end
    end
    table.sort(surface_list, sort_nodes)
    for _,p in ipairs(surface_list) do
        for _,d in ipairs({{1,0},{0,1}}) do
            local n = surfaces[key(p.x+d[1],p.z+d[2])]
            if n and math.abs(n.y-p.y)>1 then return fail('composition_failed', 'adjacent surface rise exceeds one node', copy(p)) end
        end
    end
    local writes, expectations = {}, {}
    local counts = {road_count=0, fill_count=0, clear_count=0, cut_count=0, write_count=0}
    local function expect(p,y,entry)
        expectations[#expectations+1] = {x=p.x,y=y,z=p.z,kind=entry.kind,
            material=entry.material,protected=entry.protected}
    end
    local function write(p,y,kind,material,entry)
        local noop = kind == 'air' and entry.kind == 'air'
            or kind == 'road' and entry.material == config.road_material and entry.kind == 'natural'
            or kind == 'fill' and entry.material == material and entry.kind == 'natural'
        if noop then return true end
        if #writes >= cap then return false end
        writes[#writes+1] = {x=p.x,y=y,z=p.z,kind=kind,material=material}
        counts[kind == 'air' and 'clear_count' or kind..'_count'] = counts[kind == 'air' and 'clear_count' or kind..'_count'] + 1
        if kind == 'air' and entry.kind == 'natural' then counts.cut_count = counts.cut_count+1 end
        return true
    end
    for _,p in ipairs(surface_list) do
        local col = terrain.get_column(p.x,p.z)
        if type(col)~='table' or col.status~='ok' then return fail('composition_failed','transition terrain unavailable',p) end
        local g,r = col.ground_y,p.y
        local first = r <= g and r-1 or g
        local last = r+3
        for y=first,last do
            local entry = col.band[y-g]
            if type(entry) ~= 'table' then return fail('composition_failed', 'missing semantic expectation', {x=p.x,y=y,z=p.z}) end
            if constraints and constraints.preserved[p.x..':'..y..':'..p.z] then
                return fail('composition_failed','operation intersects preserved connector',{x=p.x,y=y,z=p.z})
            end
            expect(p,y,entry)
            local kind,material
            if y==r then kind='road'
            elseif y>r then kind='air'
            elseif r>g and y>g then kind='fill'; material=col.material end
            if kind and not write(p,y,kind,material,entry) then
                return fail('write_budget', 'deduplicated write limit exceeded', {x=p.x,y=y,z=p.z}, {limit=cap,observed=#writes+1})
            end
        end
    end
    if has_connector then
        local function k(p) return p.x..':'..p.y..':'..p.z end
        local expected, written = {}, {}
        for _,p in ipairs(expectations) do expected[k(p)]=p end
        for _,p in ipairs(writes) do written[k(p)]=p end
        for _,endpoint in ipairs({pa,pb}) do
            local c=endpoint.connector
            if c then
                local columns, recorded_expectations, recorded_writes = {}, {}, {}
                for _,p in ipairs(c.transition.surfaces) do columns[key(p.x,p.z)]=true end
                for _,p in ipairs(c.transition.expectations) do recorded_expectations[k(p)]=p end
                for _,p in ipairs(c.transition.writes) do recorded_writes[k(p)]=p end
                for _,name in ipairs({'expectations','writes'}) do
                    local map=name=='writes' and written or expected
                    for _,p in ipairs(c.transition[name]) do
                        local q=map[k(p)]
                        if not q or q.kind~=p.kind or q.material~=p.material
                            or (name=='expectations' and q.protected~=p.protected) then
                            return fail('composition_failed','transition operation differs from surveyed terrain',p)
                        end
                    end
                end
                for _,p in ipairs(expectations) do
                    if columns[key(p.x,p.z)] and not recorded_expectations[k(p)] then
                        return fail('composition_failed','transition expectation is missing',p)
                    end
                end
                for _,p in ipairs(writes) do
                    if columns[key(p.x,p.z)] and not recorded_writes[k(p)] then
                        return fail('composition_failed','transition write is missing',p)
                    end
                end
                for _,p in ipairs(c.preserved) do
                    local old=expected[k(p)]
                    if old then
                        if old.name~=p.name or old.param2~=p.param2 or old.has_metadata~=p.has_metadata
                            or old.protected~=p.protected then return fail('composition_failed','preserved expectations conflict',p) end
                    else local q=copy(p); expectations[#expectations+1]=q; expected[k(p)]=q end
                end
            end
        end
    end
    if #expectations>50000 then return fail('composition_failed','expectation allocation limit reached',nil,{limit=50000,observed=#expectations}) end
    table.sort(writes,sort_nodes); table.sort(expectations,sort_nodes)
    counts.write_count = #writes
    local metrics = copy(route.metrics)
    for k,v in pairs(counts) do metrics[k]=v end
    local parameters = {}
    for k,v in pairs(route.parameters) do
        if k ~= "road_material" then parameters[k] = copy(v) end
    end
    parameters.road_material = config.road_material
    return {version=has_connector and 2 or 1, connector_version=has_connector and 1 or nil, planner_version=1, raster_version=1, owner=terrain.owner,
        request=copy(request), endpoints=copy(request.provenance), survey_bounds=copy(terrain.bounds),
        centerline=copy(route.centerline), headings=copy(route.headings), parameters=parameters,
        cost=route.cost, metrics=metrics, writes=writes, expectations=expectations}
end
return plans
