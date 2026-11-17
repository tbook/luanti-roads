-- SPDX-License-Identifier: GPL-3.0-or-later
local commands=dofile("src/commands.lua")
local count=0
local function test(name,fn)
    local ok,err=pcall(fn)
    if not ok then error("presentation "..name..": "..tostring(err)) end
    count=count+1
end

test("status reports selected position, natural landing, displacement and connector lengths",function()
    local status={state="ready",endpoints={
        start={requested={x=-4,y=10.5,z=2},resolved={x=0,y=8,z=2},connector={
            path={{x=-4,y=10.5,z=2},{x=-3,y=10,z=2},{x=-2,y=9.5,z=2}},
            transition={path={{x=-1,y=9,z=2},{x=0,y=8.5,z=2}}}}},
        goal={requested={x=20,y=8.5,z=2},resolved={x=20,y=8,z=2}}}}
    local message=commands.summary(status)
    assert(message:find("Start selected (-4.0, 10.5, 2.0), natural landing (0.0, 8.0, 2.0).",1,true))
    assert(message:find("Start connector: 4.5 nodes displacement, 2.2 nodes preserved path, 2.2 nodes transition.",1,true))
    assert(message:find("Goal selected (20.0, 8.5, 2.0), natural landing (20.0, 8.0, 2.0).",1,true))
    assert(not message:find("Goal connector:",1,true))
end)

print("ok - "..count.." presentation tests")
