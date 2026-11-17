-- Frozen from the version-one builder's initial gate before issue #26.
-- Reaching the scheduler would allow its preflight and writes to begin.
return function(plan,ops)
    if type(plan)~='table' or type(plan.owner)~='string' or type(plan.writes)~='table'
        or type(plan.expectations)~='table' then return nil end
    if #plan.writes>10000 or #plan.expectations>50000 then return nil end
    local e=plan.endpoints or {}
    local provenance=plan.request and plan.request.provenance or {}
    if plan.version~=1 or plan.connector or plan.connectors or e.connector or e.connectors
        or provenance.connector or provenance.connectors
        or (e.start and (e.start.connector or e.start.connectors))
        or (e.goal and (e.goal.connector or e.goal.connectors))
        or (provenance.start and (provenance.start.connector or provenance.start.connectors))
        or (provenance.goal and (provenance.goal.connector or provenance.goal.connectors)) then
        return nil
    end
    ops.after()
    return true
end
