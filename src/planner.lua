-- SPDX-License-Identifier: GPL-3.0-or-later
-- Deterministic, resumable A* over lattice position and incoming heading.
local planner = {}
local edges
local defaults = {slope=4, turn=2, cut=1, fill=1}
local local_errors = {outside=true, unknown=true, water=true, structure=true, grade=true,
    earthwork=true, support=true, clearance=true, protected=true, profile_conflict=true, step_height=true}

local function finite(n)
    return type(n) == 'number' and n == n and n ~= math.huge and n ~= -math.huge
end
local function integer(n) return finite(n) and n == math.floor(n) end
local function copy(t)
    if type(t) ~= 'table' then return t end
    local r = {}
    for k,v in pairs(t) do r[k] = copy(v) end
    return r
end
local function failure(code, reason, extra)
    local e = extra or {}; e.code, e.reason = code, reason; return e
end
local function point(p, integral)
    return type(p) == 'table' and finite(p.x) and finite(p.y) and finite(p.z)
        and (not integral or (integer(p.x) and integer(p.y) and integer(p.z)))
end
local function same(a,b) return a.x == b.x and a.y == b.y and a.z == b.z end
local function key(i,j,h) return i .. ':' .. j .. ':' .. (h == nil and 'start' or h) end
local function less(a,b)
    if a.f ~= b.f then return a.f < b.f end
    if a.h ~= b.h then return a.h < b.h end
    return a.serial < b.serial
end
local function push(heap, v)
    local n = #heap + 1
    while n > 1 do
        local p = math.floor(n / 2)
        if not less(v, heap[p]) then break end
        heap[n], n = heap[p], p
    end
    heap[n] = v
end
local function pop(heap)
    local root, last = heap[1], table.remove(heap)
    if #heap > 0 then
        local n = 1
        while n * 2 <= #heap do
            local c = n * 2
            if c < #heap and less(heap[c+1], heap[c]) then c = c + 1 end
            if not less(heap[c], last) then break end
            heap[n], n = heap[c], c
        end
        heap[n] = last
    end
    return root
end
function planner.set_edges(module)
    if type(module) ~= 'table' or type(module.evaluate) ~= 'function' then
        return nil, 'edge dependency must provide evaluate'
    end
    edges = module
    return true
end

function planner.new(terrain, request, config)
    if not edges or type(terrain) ~= 'table' or type(terrain.get_column) ~= 'function' then
        return nil, failure('invalid_config', 'edge dependency and terrain snapshot are required')
    end
    if config ~= nil and type(config) ~= 'table' then return nil, failure('invalid_config', 'config must be a table') end
    config = config or {}
    local road_material = config.road_material
    if config.weights ~= nil and type(config.weights) ~= 'table' then return nil, failure('invalid_config', 'weights must be a table') end
    local weights = {}
    for k,v in pairs(defaults) do
        local n = (config.weights or {})[k]; if n == nil then n = v end
        if not finite(n) or n < 0 then return nil, failure('invalid_config', 'weights must be finite and nonnegative') end
        weights[k] = n
    end
    local limits = {}
    for k,v in pairs({max_expansions=150000, max_states=250000, max_heap_entries=250000}) do
        local n = config[k]; if n == nil then n = v end
        if not integer(n) or n < 1 or n > v then return nil, failure('invalid_config', k .. ' must be a positive integer within the shared limit') end
        limits[k] = n
    end
    if type(request) ~= 'table' or not point(request.start,true) or not point(request.goal,true)
        or type(request.provenance) ~= 'table' then return nil, failure('invalid_endpoint', 'resolved endpoints and provenance are required') end
    for _,name in ipairs({'start','goal'}) do
        local p = request.provenance[name]
        if type(p) ~= 'table' or not point(p.requested,false) or not point(p.ground,true)
            or not point(p.resolved,true) or not same(p.resolved, request[name])
            or p.ground.x ~= math.floor(p.requested.x+0.5)
            or p.ground.z ~= math.floor(p.requested.z+0.5)
            or math.abs(p.requested.y-(p.ground.y+0.5)) > 0.5 then
            return nil, failure('invalid_endpoint', 'endpoint provenance is missing or inconsistent')
        end
    end
    local a,b = request.start, request.goal
    local dx,dz = b.x-a.x,b.z-a.z
    local requested_a, requested_b = request.provenance.start.requested, request.provenance.goal.requested
    local requested_dx, requested_dz = requested_b.x-requested_a.x, requested_b.z-requested_a.z
    local ground_b = request.provenance.goal.ground
    if (dx == 0 and dz == 0) or dx % 4 ~= 0 or dz % 4 ~= 0 or dx*dx+dz*dz > 192*192
        or requested_dx*requested_dx+requested_dz*requested_dz > 192*192
        or not same(request.provenance.start.ground,a)
        or b.x ~= a.x + 4*math.floor((requested_b.x-a.x)/4+0.5)
        or b.z ~= a.z + 4*math.floor((requested_b.z-a.z)/4+0.5)
        or (requested_b.x-b.x)^2+(requested_b.z-b.z)^2 > 9
        or math.abs(ground_b.y-b.y) > 2 then
        return nil, failure('invalid_endpoint', 'endpoints must be distinct, aligned, and within range')
    end
    for _,p in ipairs({a,b,request.provenance.start.ground,request.provenance.goal.ground}) do
        local ok,c = pcall(terrain.get_column,p.x,p.z)
        if not ok or type(c) ~= 'table' or c.status ~= 'ok' or c.ground_y ~= p.y then
            return nil, failure('invalid_endpoint', 'endpoint does not match surveyed ground', {position=copy(p)})
        end
    end
    local self = {terrain=terrain, request=copy(request), weights=weights, limits=limits,
        heap={}, records={}, serial=0, pending=nil, terminal=nil,
        metrics={expansions=0, states=1, heap_peak=1, stale_entries=0, rejections={}}}
    a,b = self.request.start,self.request.goal
    local goal_i, goal_j = dx/4,dz/4
    local function heuristic(i,j) return 4 * math.sqrt((goal_i-i)^2 + (goal_j-j)^2) end
    local start = {i=0,j=0,heading=nil,g=0}
    self.records[key(0,0,nil)] = start
    push(self.heap,{record=start,g=0,h=heuristic(0,0),f=heuristic(0,0),serial=0})
    local function finish(status, err, route)
        self.terminal = {status=status, metrics=copy(self.metrics), error=err, route=route}
        return self.terminal
    end
    local function success(rec)
        local reversed, headings = {}, {}
        while rec do
            local x,z = a.x+4*rec.i,a.z+4*rec.j
            local col = terrain.get_column(x,z)
            reversed[#reversed+1] = {x=x,y=col.ground_y,z=z}
            if rec.heading ~= nil then headings[#headings+1] = rec.heading end
            rec = rec.parent
        end
        local points, hs = {}, {}
        for i=#reversed,1,-1 do points[#points+1] = reversed[i] end
        for i=#headings,1,-1 do hs[#hs+1] = headings[i] end
        local route = {request=copy(self.request), centerline=points, headings=hs,
            cost=self.goal_cost, parameters={weights=copy(weights), road_material=road_material}, metrics=copy(self.metrics)}
        route.metrics.length, route.metrics.ascent, route.metrics.descent = 0,0,0
        route.metrics.max_grade, route.metrics.turn_count, route.metrics.cut_count, route.metrics.fill_count = 0,0,0,0
        local r = self.goal_record
        while r.parent do
            local m = r.edge_metrics
            for _,name in ipairs({'length','ascent','descent','turn_count','cut_count','fill_count'}) do
                route.metrics[name] = route.metrics[name] + m[name]
            end
            route.metrics.max_grade = math.max(route.metrics.max_grade,m.grade)
            r = r.parent
        end
        return finish('succeeded',nil,route)
    end
    function self:cancel()
        if not self.terminal then return finish('cancelled', failure('cancelled','search cancelled')) end
        return self.terminal
    end
    function self:step(slice, clock)
        if self.terminal then return self.terminal end
        if type(slice) ~= 'table' or not integer(slice.max_expansions) or slice.max_expansions < 1
            or (slice.deadline ~= nil and (not finite(slice.deadline) or type(clock) ~= 'function')) then
            return finish('failed',failure('invalid_config','invalid search slice'))
        end
        local used = 0
        local function expired() return slice.deadline ~= nil and clock() >= slice.deadline end
        while used < slice.max_expansions do
            if not self.pending then
                if #self.heap == 0 then return finish('failed',failure('bounded_no_route','frontier exhausted', {bounds=copy(terrain.bounds)})) end
                if expired() then break end
                local entry = pop(self.heap)
                if self.records[key(entry.record.i,entry.record.j,entry.record.heading)] ~= entry.record then
                    self.metrics.stale_entries = self.metrics.stale_entries + 1
                else self.pending = entry end
            end
            if self.pending then
                if expired() then break end
                local entry = self.pending
                if self.metrics.expansions >= limits.max_expansions then
                    return finish('failed',failure('expansion_budget','expansion limit reached',{limit=limits.max_expansions,observed=self.metrics.expansions}))
                end
                self.pending = nil
                local rec = entry.record
                self.metrics.expansions = self.metrics.expansions + 1; used = used + 1
                if rec.i == goal_i and rec.j == goal_j then
                    self.goal_cost, self.goal_record = rec.g, rec
                    return success(rec)
                end
                local headings
                if rec.heading == nil then headings = {0,1,2,3,4,5,6,7}
                else headings = {rec.heading,(rec.heading+1)%8,(rec.heading+7)%8} end
                for _,h in ipairs(headings) do
                    local edge = edges.evaluate(terrain,a,rec,h,{weights=weights, road_material=road_material})
                    if not edge.ok then
                        if not local_errors[edge.code] then return finish('failed',failure(edge.code,edge.reason,{position=edge.position})) end
                        self.metrics.rejections[edge.code] = (self.metrics.rejections[edge.code] or 0) + 1
                    else
                        local s, g = edge.next_state, rec.g + edge.cost
                        local id = key(s.i,s.j,s.heading)
                        local old = self.records[id]
                        if not old or g < old.g then
                            if not old and self.metrics.states >= limits.max_states then return finish('failed',failure('state_budget','state limit reached',{limit=limits.max_states,observed=self.metrics.states})) end
                            if #self.heap + (self.pending and 1 or 0) >= limits.max_heap_entries then return finish('failed',failure('heap_budget','heap limit reached',{limit=limits.max_heap_entries,observed=#self.heap})) end
                            -- Immutable parent snapshots preserve path consistency on later improvements.
                            local nextrec = {i=s.i,j=s.j,heading=s.heading,g=g,parent=rec,edge_metrics=edge.metrics}
                            self.records[id] = nextrec
                            if not old then self.metrics.states = self.metrics.states + 1 end
                            self.serial = self.serial + 1
                            local hc = heuristic(s.i,s.j)
                            push(self.heap,{record=nextrec,g=g,h=hc,f=g+hc,serial=self.serial})
                            self.metrics.heap_peak = math.max(self.metrics.heap_peak,#self.heap)
                        end
                    end
                end
            end
        end
        return {status='running',metrics=copy(self.metrics)}
    end
    return self
end
return planner
