-- Fakes for outward-road tests: deterministic codec and injectable mod storage.
local fixture = {}

local function encode(value, out)
    local t = type(value)
    if t == 'table' then
        local keys = {}
        for k in pairs(value) do keys[#keys+1] = k end
        table.sort(keys, function(a, b)
            if type(a) == type(b) then return a < b end
            return type(a) < type(b)
        end)
        out[#out+1] = '{'
        for _, k in ipairs(keys) do
            out[#out+1] = '['; encode(k, out); out[#out+1] = ']='; encode(value[k], out); out[#out+1] = ','
        end
        out[#out+1] = '}'
    elseif t == 'string' then out[#out+1] = string.format('%q', value)
    elseif t == 'number' or t == 'boolean' then out[#out+1] = tostring(value)
    else error('cannot serialize '..t) end
end
function fixture.serialize(value)
    local out = {}; encode(value, out); return 'return '..table.concat(out)
end
function fixture.deserialize(text)
    local chunk, e = loadstring(text); if not chunk then error(e) end
    setfenv(chunk, {})
    return chunk()
end

-- storage.fail_set: nil | true | function(key, value, n) -> boolean (fail this write)
-- storage.mismatch: when true, get() returns something else than what was set.
function fixture.storage(initial)
    local data = {}
    for k, v in pairs(initial or {}) do data[k] = v end
    local s = {data = data, sets = 0, fail_set = nil, mismatch = false, fail_get = false}
    function s.get(key)
        if s.fail_get then error('read failed') end
        local v = data[key]
        if s.mismatch and v then return v..' ' end
        return v
    end
    function s.set(key, value)
        s.sets = s.sets + 1
        local fail = s.fail_set
        if type(fail) == 'function' then fail = fail(key, value, s.sets) end
        if fail then error('disk full') end
        data[key] = value
    end
    function s.keys()
        local list = {}
        for k in pairs(data) do list[#list+1] = k end
        return list
    end
    return s
end
return fixture
