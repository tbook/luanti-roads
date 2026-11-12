-- SPDX-License-Identifier: GPL-3.0-or-later
local survey=dofile("src/survey.lua")
local count=0
local function test(name,fn)
    local ok,err=pcall(fn)
    if not ok then error("survey "..name..": "..tostring(err)) end
    count=count+1
end
local function config(overrides)
    local c={mapgen="v7",chunksize=5,chunk_origin={x=-32,y=-32,z=-32},
        map_limits={min_x=-31000,max_x=31000,min_y=-31000,max_y=31000,
            min_z=-31000,max_z=31000},
        dimension_bounds={min_x=-31000,max_x=31000,min_y=-31000,max_y=31000,
            min_z=-31000,max_z=31000},safe_generation_bounds={min_y=-31000,max_y=31000}}
    for k,v in pairs(overrides or {}) do c[k]=v end
    return c
end
local function contains(outer,inner)
    return outer.min_x<=inner.min_x and outer.max_x>=inner.max_x
        and outer.min_y<=inner.min_y and outer.max_y>=inner.max_y
        and outer.min_z<=inner.min_z and outer.max_z>=inner.max_z
end

test("negative coordinates use canonical chunk origin and complete coverage",function()
    local p=assert(survey.plan({x=-1,y=0,z=-2},{x=8,y=2,z=5},config()))
    assert(p.requested_bounds.min_x==-33 and p.requested_bounds.max_x==40)
    assert(p.requested_bounds.min_z==-34 and p.requested_bounds.max_z==37)
    assert(contains(p.chunk_bounds,p.requested_bounds))
    assert((p.chunk_bounds.min_x+32)%80==0 and (p.chunk_bounds.min_y+32)%80==0)
    assert((p.chunk_bounds.min_z+32)%80==0)
    assert(p.chunk_bounds.min_x==-112 and p.chunk_bounds.max_x==47)
    assert(p.chunks[1].ix==-1 and p.chunks[#p.chunks].ix==0)
    -- -32 is the first node of chunk 0; -33 remains in chunk -1.
    assert(p.chunks[1].bounds.max_x==-33)
    for _,point in ipairs({{x=-1,y=0,z=-2},{x=8,y=2,z=5}}) do
        assert(point.x>=p.requested_bounds.min_x and point.x<=p.requested_bounds.max_x)
        assert(point.z>=p.requested_bounds.min_z and point.z<=p.requested_bounds.max_z)
    end
end)

test("exact chunk boundaries and inclusive endpoint bounds",function()
    local p=assert(survey.plan({x=48,y=0,z=0},{x=48,y=0,z=0},config()))
    -- Requested X is [16,80], so the inclusive coordinate 80 belongs to the
    -- next chunk even though it lies exactly on its boundary.
    assert(p.chunk_bounds.min_x==-32 and p.chunk_bounds.max_x==127)
    assert(p.requested_bounds.min_x==16 and p.requested_bounds.max_x==80)
    assert(contains(p.chunk_bounds,p.requested_bounds))
end)

test("diagonal separation uses horizontal Euclidean distance",function()
    local pass=assert(survey.plan({x=0,y=0,z=0},{x=135,y=0,z=135},config()))
    assert(math.abs(pass.endpoint_distance-math.sqrt(36450))<1e-9)
    local fail,err=survey.plan({x=0,y=0,z=0},{x=136,y=0,z=136},config())
    assert(not fail and err.code=="survey_budget" and err.limit==192)
end)

test("vertical padding and inclusive span cap",function()
    local pass=assert(survey.plan({x=0,y=-10,z=0},{x=0,y=21,z=0},config()))
    assert(pass.requested_bounds.min_y==-58 and pass.requested_bounds.max_y==69)
    assert(pass.vertical_span==128)
    local fail,err=survey.plan({x=0,y=0,z=0},{x=0,y=32,z=0},config())
    assert(not fail and err.code=="survey_budget" and err.observed==129)
end)

test("unsupported mapgens, chunksizes, origins, and malformed limits fail",function()
    for _,c in ipairs({config({mapgen="singlenode"}),config({chunksize=4})}) do
        local p,err=survey.plan({x=0,y=0,z=0},{x=1,y=0,z=0},c)
        assert(not p and err.code=="unsupported_world")
    end
    local p,err=survey.plan({x=0,y=0,z=0},{x=1,y=0,z=0},config({chunk_origin={x=7,y=-13,z=19}}))
    assert(not p and err.code=="unsupported_world")
    local malformed=config(); malformed.chunk_origin=nil
    p,err=survey.plan({x=0,y=0,z=0},{x=1,y=0,z=0},malformed)
    assert(not p and err.code=="invalid_config")
    p,err=survey.plan({x=0,y=0,z=0},{x=1,y=0,z=0},config({chunk_origin={x=-32,y=-32}}))
    assert(not p and err.code=="invalid_config")
    local c=config({map_limits={min_x=-10,max_x=10,min_y=-10,max_y=10,min_z=-10,max_z=10}})
    p,err=survey.plan({x=0,y=0,z=0},{x=1,y=0,z=0},c)
    assert(not p and err.code=="unsupported_world" and err.bounds)
    c=config({map_limits={min_x=-1e20,max_x=1e20,min_y=-31000,max_y=31000,min_z=-31000,max_z=31000}})
    p,err=survey.plan({x=0,y=0,z=0},{x=1,y=0,z=0},c)
    assert(not p and err.code=="unsupported_world")
end)

test("chunk union is distinct, ordered, and patches are sequential and bounded",function()
    local p=assert(survey.plan({x=-40,y=0,z=0},{x=40,y=0,z=0},config()))
    local seen={}
    assert(p.chunk_count==#p.chunks and #p.patches==#p.chunks)
    for i,ch in ipairs(p.chunks) do
        local id=ch.ix..":"..ch.iy..":"..ch.iz
        assert(not seen[id],"duplicate mapchunk")
        seen[id]=true
        local patch=p.patches[i]
        assert(patch.sequence==i and patch.voxel_count==512000)
        assert(patch.request_bounds.min_x==ch.bounds.min_x
            and patch.request_bounds.max_z==ch.bounds.max_z)
        assert(contains(patch.read_bounds,patch.request_bounds))
        assert(patch.voxel_count<=survey.MAX_PATCH_VOXELS)
    end
    local expected=((p.chunk_bounds.max_x-p.chunk_bounds.min_x+1)/80)
        *((p.chunk_bounds.max_y-p.chunk_bounds.min_y+1)/80)
        *((p.chunk_bounds.max_z-p.chunk_bounds.min_z+1)/80)
    assert(p.chunk_count==expected)
    assert(p.voxel_count==p.chunk_count*512000)
end)

test("invalid endpoints and survey resource limits are rejected",function()
    local p,err=survey.plan(nil,{x=1,y=0,z=0},config())
    assert(not p and err.code=="invalid_endpoint")
    for _,point in ipairs({{}, {x=0,y=0.5,z=0},{x=math.huge,y=0,z=0},
        {x=1e20,y=0,z=0}}) do
        p,err=survey.plan(point,{x=1,y=0,z=0},config())
        assert(not p and err.code=="invalid_endpoint")
    end
    local p,err=survey.plan({x=0,y=0,z=0},{x=193,y=0,z=0},config())
    assert(not p and err.code=="survey_budget" and err.limit==192)
    -- The allowed distance, margin and vertical-span limits bound the largest
    -- normal request below 96 chunks; this verifies the dimension budget that
    -- remains independently reachable from valid survey geometry.
    p,err=survey.plan({x=0,y=-1,z=0},{x=0,y=31,z=0},config())
    assert(not p and err.code=="survey_budget" and err.limit==survey.MAX_VERTICAL_SPAN)
end)

test("dimension bounds reject non-overworld requests",function()
    local c=config({dimension_bounds={min_x=-100,max_x=100,min_y=-20,max_y=100,
        min_z=-100,max_z=100}})
    local p,err=survey.plan({x=0,y=-21,z=0},{x=0,y=0,z=0},c)
    assert(not p and err.code=="unsupported_world" and err.dimension_bounds)
end)

test("normal and flat overworld permit padded coverage into safe void",function()
    for _,v in ipairs({{mapgen="v7",min_y=-62},{mapgen="flat",min_y=9}}) do
        local c=config({mapgen=v.mapgen,dimension_bounds={min_x=-31000,max_x=31000,
            min_y=v.min_y,max_y=30000,min_z=-31000,max_z=31000},
            safe_generation_bounds={min_y=v.min_y-1999,max_y=31000}})
        local p=assert(survey.plan({x=0,y=12,z=0},{x=4,y=12,z=0},c))
        assert(p.requested_bounds.min_y==-36 and p.requested_bounds.max_y==60)
        assert(p.chunk_bounds.min_y==-112 and p.chunk_bounds.max_y==127)
        local missing=config({safe_generation_bounds=false})
        local no,e=survey.plan({x=0,y=12,z=0},{x=4,y=12,z=0},missing)
        assert(not no and e.code=="unsupported_world")
        no,e=survey.plan({x=0,y=v.min_y-2000,z=0},{x=4,y=v.min_y-2000,z=0},c)
        assert(not no and e.code=="unsupported_world")
        c.safe_generation_bounds.min_y=-111
        no,e=survey.plan({x=0,y=12,z=0},{x=4,y=12,z=0},c)
        assert(not no and e.code=="unsupported_world" and e.safe_generation_bounds)
    end
end)

test("chunk-rounded generation cannot cross an overworld dimension boundary",function()
    local c=config({dimension_bounds={min_x=-10,max_x=100,min_y=-100,max_y=100,
        min_z=-100,max_z=100}})
    local start_point,end_point={x=22,y=0,z=0},{x=22,y=0,z=0}
    local requested_min_x=math.min(start_point.x,end_point.x)-survey.HORIZONTAL_MARGIN
    local requested_max_x=math.max(start_point.x,end_point.x)+survey.HORIZONTAL_MARGIN
    assert(requested_min_x>=c.dimension_bounds.min_x
        and requested_max_x<=c.dimension_bounds.max_x)
    local p,err=survey.plan(start_point,end_point,c)
    assert(not p and err.code=="unsupported_world" and err.bounds.min_x==-32)
end)

print("ok - "..count.." survey tests")
