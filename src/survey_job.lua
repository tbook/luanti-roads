-- SPDX-License-Identifier: GPL-3.0-or-later
-- Sequential emerge, then small full-height read-only inspection tiles.
local service = {}
local TILE = 4
-- Bound each server callback by both elapsed time and a hard tile count. A
-- single slow tile cannot be interrupted, so check the clock between tiles.
local SLICE_SECONDS = 0.010
local SLICE_TILES = 8
local TIMEOUT = 60
local function copy(t)
    if type(t) ~= "table" then return t end
    local out={}; for k,v in pairs(t) do out[k]=copy(v) end; return out
end
local function fail(code, reason) return nil, {code=code, reason=reason} end

-- ops: now() seconds, after(delay, fn), emerge(minp,maxp,cb),
-- load_area(minp,maxp) (load existing blocks only), access,
-- actions={cancelled=...,errored=...,memory=...,disk=...,generated=...}.
-- Each job is independent; callbacks and scheduled work are invalidated at
-- termination. The caller owns global exclusion and starts/cancels jobs.
function service.new(preflight, inspector, ops, start, goal, owner, config)
    if type(preflight) ~= "table" or type(preflight.plan) ~= "function"
        or type(inspector) ~= "table" or type(inspector.inspect) ~= "function"
        or type(ops) ~= "table" or type(ops.now) ~= "function"
        or type(ops.after) ~= "function" or type(ops.emerge) ~= "function" or type(ops.load_area) ~= "function"
        or type(ops.actions) ~= "table" or type(ops.access) ~= "table"
        or type(owner) ~= "string" then return fail("invalid_config", "missing survey dependencies") end
    local actions=ops.actions
    local seen_actions={}
    for _,key in ipairs({"cancelled","errored","memory","disk","generated"}) do
        local v=actions[key]
        if type(v) ~= "number" or seen_actions[v] then return fail("invalid_config", "invalid emerge action constants") end
        seen_actions[v]=true
    end
    local plan,err=preflight.plan(start,goal,config)
    if not plan then return nil,err end
    local dimension=type(config) == "table" and config.dimension_bounds
    if type(dimension) ~= "table" or type(dimension.min_y) ~= "number" or type(dimension.max_y) ~= "number"
        or dimension.min_y ~= math.floor(dimension.min_y) or dimension.max_y ~= math.floor(dimension.max_y)
        or dimension.min_y > dimension.max_y then return fail("invalid_config", "missing overworld ground limits") end
    local ground_min,ground_max=dimension.min_y,dimension.max_y
    if #plan.patches > 96 or plan.chunk_count ~= #plan.patches then return fail("survey_budget", "invalid chunk count") end
    for _,p in ipairs(plan.patches) do
        if not p.voxel_count or p.voxel_count > 2000000 then return fail("survey_budget", "patch allocation exceeds limit") end
    end
    local b=copy(plan.requested_bounds)
    local state={status="running", metrics={chunks_total=#plan.patches,chunks_completed=0,
        callbacks=0, tiles_completed=0, columns_completed=0, emerge_wait_seconds=0,
        inspection_seconds=0, max_inspection_seconds=0, max_patch_voxels=0,
        max_emerge_voxels=0,load_seconds=0,max_load_voxels=0}}
    local started=ops.now()
    local last_progress=started
    local columns={}
    local request_id=0
    local current=0
    local tile_x,tile_z=b.min_x,b.min_z
    local function finish(code,reason)
        if state.status ~= "running" then return end
        state.status=code == "cancelled" and "cancelled" or "failed"
        state.error={code=code,reason=reason}; request_id=request_id+1; columns={}
    end
    local function schedule(delay,fn)
        local ok,why=pcall(ops.after,delay,fn)
        if not ok then finish("survey_failed", "cannot schedule survey: "..tostring(why)) end
    end
    local function check_timeout()
        if state.status ~= "running" then return false end
        if ops.now()-last_progress >= TIMEOUT then finish("survey_timeout", "survey made no progress for 60 seconds"); return false end
        return true
    end
    local function monitor()
        if check_timeout() then schedule(1,monitor) end
    end
    local inspect_next,inspect_slice,emerge_next
    local function key(x,z) return x..":"..z end
    inspect_next=function()
        if not check_timeout() then return end
        local tile={min_x=tile_x,max_x=math.min(tile_x+TILE-1,b.max_x),
            min_z=tile_z,max_z=math.min(tile_z+TILE-1,b.max_z),min_y=b.min_y,max_y=b.max_y}
        local volume=(tile.max_x-tile.min_x+1)*(tile.max_z-tile.min_z+1)*(tile.max_y-tile.min_y+1)
        if volume > 2000000 then finish("survey_budget", "inspection allocation exceeds limit"); return end
        local begin=ops.now()
        -- load_area loads existing mapblocks only. Account for the rounded
        -- blocks, not just the smaller node rectangle passed to the API.
        local function block_span(lo,hi) return (math.floor(hi/16)-math.floor(lo/16)+1)*16 end
        local load_volume=block_span(tile.min_x,tile.max_x)*block_span(tile.min_y,tile.max_y)*block_span(tile.min_z,tile.max_z)
        if load_volume > 2000000 then finish("survey_budget", "tile load exceeds allocation limit"); return end
        local loaded,load_result=pcall(ops.load_area,{x=tile.min_x,y=tile.min_y,z=tile.min_z},
            {x=tile.max_x,y=tile.max_y,z=tile.max_z})
        state.metrics.load_seconds=state.metrics.load_seconds+math.max(0,ops.now()-begin)
        state.metrics.max_load_voxels=math.max(state.metrics.max_load_voxels,load_volume)
        if not loaded or load_result == false then finish("survey_failed", "tile load failed: "..tostring(load_result)); return end
        local ok,result,why=pcall(inspector.inspect,tile,owner,ops.access)
        state.metrics.max_patch_voxels=math.max(state.metrics.max_patch_voxels,volume)
        if not ok or not result then finish("survey_failed", "surface inspection failed: "..tostring(ok and why and why.reason or result)); return end
        local copied, copy_error=pcall(function()
            for x=tile.min_x,tile.max_x do for z=tile.min_z,tile.max_z do
                local col=result.get_column(x,z)
                if type(col) ~= "table" then error("missing inspected column") end
                if col.status == "ok" and (type(col.ground_y) ~= "number" or col.ground_y < ground_min or col.ground_y > ground_max) then
                    col={status="unknown",reason="surface outside overworld"}
                end
                columns[key(x,z)]=copy(col); state.metrics.columns_completed=state.metrics.columns_completed+1
            end end
        end)
        if not copied then finish("survey_failed", "surface summary failed: "..tostring(copy_error)); return end
        local elapsed=math.max(0,ops.now()-begin)
        state.metrics.inspection_seconds=state.metrics.inspection_seconds+elapsed
        state.metrics.max_inspection_seconds=math.max(state.metrics.max_inspection_seconds,elapsed)
        result=nil
        state.metrics.tiles_completed=state.metrics.tiles_completed+1
        last_progress=ops.now()
        tile_z=tile.max_z+1
        if tile_z>b.max_z then tile_z=b.min_z; tile_x=tile.max_x+1 end
        if tile_x>b.max_x then
            local saved=columns; local bounds=copy(b)
            state.terrain={version=1,bounds=copy(bounds),owner=owner,get_column=function(x,z)
                if x<bounds.min_x or x>bounds.max_x or z<bounds.min_z or z>bounds.max_z then return {status="outside"} end
                return copy(saved[key(x,z)] or {status="unknown",reason="missing column"})
            end}
            state.status="succeeded"; state.metrics.total_seconds=ops.now()-started; request_id=request_id+1
        end
    end
    inspect_slice=function()
        local deadline=ops.now()+SLICE_SECONDS
        for _=1,SLICE_TILES do
            inspect_next()
            if state.status ~= "running" then return end
            if ops.now() >= deadline then break end
        end
        schedule(0,inspect_slice)
    end
    emerge_next=function()
        if not check_timeout() then return end
        current=current+1
        if current>#plan.patches then schedule(0,inspect_slice); return end
        local p=plan.patches[current].request_bounds
        state.metrics.max_emerge_voxels=math.max(state.metrics.max_emerge_voxels,plan.patches[current].voxel_count)
        request_id=request_id+1; local id=request_id
        local pending={}; local count=0; local began=ops.now(); local previous
        local function callback(pos,action,remaining)
            if state.status ~= "running" or id ~= request_id then return end
            if not check_timeout() then return end
            if type(pos) ~= "table" or type(pos.x) ~= "number" or type(pos.y) ~= "number" or type(pos.z) ~= "number"
                or type(remaining) ~= "number" or remaining < 0 or remaining ~= math.floor(remaining) then
                finish("survey_failed", "malformed emerge callback"); return
            end
            for _,axis in ipairs({"x","y","z"}) do
                local v=pos[axis]
                if v ~= math.floor(v) or v < math.floor(p["min_"..axis]/16)
                    or v > math.floor(p["max_"..axis]/16) then
                    finish("survey_failed", "emerge callback outside requested mapblocks"); return
                end
            end
            local idpos=pos.x..":"..pos.y..":"..pos.z
            if pending[idpos] or (previous and remaining ~= previous-1) then
                finish("survey_failed", "duplicate or out-of-order emerge callback"); return
            end
            pending[idpos]=true; count=count+1; previous=remaining
            state.metrics.callbacks=state.metrics.callbacks+1; last_progress=ops.now()
            if action ~= actions.memory and action ~= actions.disk and action ~= actions.generated then
                finish("survey_failed", "emerge cancelled, errored, or returned an unknown outcome"); return
            end
            if remaining == 0 then
                if count ~= 125 then finish("survey_failed", "incomplete emerge callback coverage"); return end
                state.metrics.emerge_wait_seconds=state.metrics.emerge_wait_seconds+math.max(0,ops.now()-began)
                state.metrics.chunks_completed=state.metrics.chunks_completed+1
                request_id=request_id+1
                schedule(0,emerge_next)
            end
        end
        local ok,why=pcall(ops.emerge,{x=p.min_x,y=p.min_y,z=p.min_z},{x=p.max_x,y=p.max_y,z=p.max_z},callback)
        if not ok then finish("survey_failed", "emerge request failed: "..tostring(why)) end
    end
    local job={}
    function job:cancel() finish("cancelled", "survey cancelled") end
    function job:status()
        local result={status=state.status, metrics=copy(state.metrics),error=copy(state.error)}
        if state.status == "succeeded" then result.terrain=state.terrain end
        return result
    end
    schedule(0,emerge_next); schedule(1,monitor)
    return job
end
return service
