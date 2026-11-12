# Minimal planner contracts (version 1)

This resolves the interfaces left open by [the engineering design](engineering_design.md)
for issue #2. It specifies behavior, not an implementation framework. All modules
use ordinary Lua 5.1 tables; the pure modules have no Luanti dependency.

## Coordinates, endpoints, and ordering

World node coordinates are integers. Surface `y` is the center coordinate of the
top full support block, as in the design; its physical top is `y + 0.5`.
Horizontal lengths and grades use Euclidean X/Z distance in nodes. Bounds are
inclusive. Round a real number with `floor(value + 0.5)`, including negatives;
ties go toward positive infinity.

Endpoint resolution first rounds requested X/Z to a node column and inspects its
outdoor natural surface. The player must be standing on that surface: feet must
be within 0.5 nodes vertically of its physical top. Flying, standing on a roof,
vegetation or water, being underground, and missing/ambiguous surface inspection
fail `invalid_endpoint`. The adapter converts engine player position to feet
position. This prevents snapping from choosing an unrelated surface below a roof.

The first resolved endpoint `(ax, ay, az)` anchors the lattice. Coordinates `(i,j)`
map to `(ax + 4*i, az + 4*j)`; their Y comes from the survey. Snap the second
requested X/Z independently to `i = round((x-ax)/4)` and `j = round((z-az)/4)`.
Use the original requested X/Z for this calculation, before column rounding.
Inspect both the requested ground column and snapped column independently. Require
horizontal snap distance <= 3 and natural surface height difference <= 2; otherwise
fail `invalid_endpoint`. This does not exempt either endpoint's complete road cap
from feasibility checks. Reject coincident resolved endpoints. Report requested,
unsnapped ground, and snapped positions. The maximum 192-node separation applies
to both requested and resolved endpoints, measured horizontally.

Headings are fixed in this order:

| Heading | dx | dz |
| --- | --- | --- |
| 0 | 1 | 0 |
| 1 | 1 | 1 |
| 2 | 0 | 1 |
| 3 | -1 | 1 |
| 4 | -1 | 0 |
| 5 | -1 | -1 |
| 6 | 0 | -1 |
| 7 | 1 | -1 |

A step adds `(dx,dz)` to `(i,j)` and four times that to world X/Z. At the start
consider headings 0 through 7. Thereafter consider straight, left (`h+1 mod 8`),
right (`h-1 mod 8`), in that order. Heap priority is `(f, h_cost, insertion_serial)`
ascending. Replace a state's parent only on strictly lower cost. Do not depend on
Lua `pairs` order. Emit columns/writes sorted by X, then Z, then Y.

## Immutable terrain snapshot

`Terrain` is an immutable snapshot with `version`, inclusive `bounds` (X/Y/Z),
`owner`, and `get_column(x,z)`. There is no loading or engine access in that getter.
Outside X/Z bounds it returns `{status="outside"}`. Inside, a column is:

```lua
{ status = "ok", ground_y = 12, material = "natural_fill_id",
  band = { -- offsets -3 through +5, inclusive; keys may be negative
    [-3] = {kind="natural", material="stone_id", protected=false},
    -- all nine entries required
  } }
-- Or {status="unknown"|"water"|"structure", reason="diagnostic"}
```

Band `kind` is `natural`, `replaceable`, `air`, `water`, `obstacle`, or `unknown`.
Material IDs are adapter-owned interned identifiers, not per-column copies of
node definitions. `protected` describes the requesting owner's ability to write
that particular node. `natural` means full walkable solid from the conservative
allowlist; slabs and leaves do not qualify. `replaceable` means explicitly allowed
plants/leaves. Trunks, authored nodes, metadata-bearing nodes, and unrecognized
nodes are obstacles unless the adapter explicitly classifies them otherwise.

The survey scans a column within its full vertical inspection window to find an
outdoor natural surface; canopy is not ground. It must not select a cave floor
beneath an obstructing structure or interpret a clipped scan as an outdoor
surface. An unresolved top/bottom boundary, `ignore`, or missing sample produces
`unknown`. The material adapter owns recognition rules; it must retain an
obstacle in the band even when it looked past that obstacle to locate ground.

This nine-node band is sufficient because allowed surface Y `r` lies within
`g-2..g+2`, support is checked as low as `g-3`, and clearance as high as `g+5`.
A missing required band entry is unknown, never air. If the band extends beyond
the inspection window the column is unknown. Surveys may discard full voxel
patches once these summaries are made. The construction phase rereads actual
nodes; this compact snapshot is not a substitute for stale-plan checks.

## Raster geometry

`raster.segment(a,b)` accepts world integer points with a valid lattice displacement
and returns `{columns={ {x,z,y}, ... }, length, grade}` or an input failure.
It is geometry only: no terrain checks, costs, materials, or engine calls.

1. Compute the **closed supercover** of the straight centerline between node
   centers A and B: include every integer-centered unit X/Z square touched by
   the line. At an exact corner include both side cells as well as the diagonal
   cell. A cardinal 4-node edge has five center cells; a diagonal has thirteen.
2. For each supercover cell include its 3-by-3 neighborhood (offsets -1..1 on
   both axes). Union by X/Z. This square brush is the precise meaning of swept
   three-node width here; diagonal roads are somewhat wider and have square caps.
3. For every resulting column P, compute
   `t = clamp(dot(P-A,B-A) / dot(B-A,B-A), 0, 1)` using X/Z only, and assign
   `y = round(a.y + t*(b.y-a.y))`.

This explicit brush sacrifices constant perpendicular width for simple,
conservative, connected block geometry. Do not substitute a thin diagonal line
or a perpendicular offset brush in another module.

`raster.join(previous, current)` unions two consecutive segment column sets.
Both must assign identical Y to every shared X/Z column. A mismatch is
`profile_conflict`; do not choose a height by write order. Also require all
cardinally neighboring surface columns in the union to differ by at most one Y.
These conservative rules may reject some otherwise plausible uphill bends.
They are a deliberate constraint of the minimal full-block renderer.

The incoming heading reconstructs the preceding point: subtract its lattice
vector from the current `(i,j)` and fetch that point's natural Y. Rasterize that
preceding segment again. No parent-chain-dependent geometry is permitted. The
start sentinel has no previous segment. Every edge includes both endpoint caps,
so start and goal need no special cap renderer.

## Feasibility and costs

The pure edge module does not load sibling files from the process working
directory. The caller loads `src/raster.lua` using the mod path and injects it
once with `edges.set_raster(raster)` before calling `edges.evaluate`. An absent
or invalid injected raster is an `invalid_config` failure. `config.weights`,
when supplied, is a table with optional `slope`, `turn`, `cut`, and `fill` values;
each omitted value uses its documented default. `config.road_material` may
supply the adapter-owned road material ID: an existing natural road node with
that exact ID is a no-op and needs no write permission. Without the ID, road
surface replacement is conservatively treated as a write.

`edges.evaluate(terrain, anchor, state, next_heading, config)` returns either
`{ok=true, next_state=..., segment=..., cost=..., metrics=...}` or
`{ok=false, code=..., position=..., reason=...}`. State is `{i,j,heading}`;
only the initial state has `heading=nil`. Y is always derived from the survey.

Require heading change <= 45 degrees and absolute grade <= 1/4. For each raster
column with natural surface `g` and proposed road surface `r`:

- Reject non-OK columns, missing data, water, and `abs(r-g) > 2`.
- Require `r-1` to be natural solid when cutting (`r <= g`): the existing
  support below the excavated surface must be solid. Existing nodes changed
  by excavation must also be allowed natural material, air, or replaceable.
- When filling (`r > g`), require the original ground at `g` to be natural;
  replace air/replaceable nodes at `g+1..r-1` with the column's natural fill
  material. These are support writes. Anything else there blocks the edge.
- Place road at `r`. The existing node there must be natural, air, or replaceable.
  Clear `r+1..r+3`; existing nodes must be natural, air, or replaceable. Natural
  nodes cleared this way are cuts; water, obstacles, and unknown are forbidden.
- Check protection at every prospective change, including road, support,
  excavation, and vegetation removal. Merely reading existing support is not a
  write. Air-to-air clearance entries require no permission to write.
- Require cardinal neighbors in the raster to have surface rises <= 1.

Then check the join against the reconstructed preceding segment, applying the
same terrain/clearance/support rules to its union. Edge cost counts only the new
segment; previous-segment overlaps may consequently be charged twice across a
route, as allowed by the design.

Cost is exactly the design's formula: horizontal length, quadratic normalized
grade penalty, quadratic turn penalty, plus cut and fill counts times weights.
`heading_change / 45_degrees` is 0 or 1. Start turn cost is zero. `cut_count`
counts natural solid nodes removed to air; `fill_count` counts support nodes
added beneath the road, excluding the road surface itself. Replacing a natural
block with road is neither cut nor fill. Vegetation clearing has no earthwork
cost. All weights must be finite and nonnegative. Initial defaults are
`slope=4, turn=2, cut=1, fill=1`; these are experiment parameters, not gameplay
promises. Segment metrics include length, ascent, descent, absolute grade,
turn count, cut count, and fill count.

## Planner and complete plan

```lua
local search, err = planner.new(terrain, request, config)
-- request.start / request.goal = {x,y,z}; resolved and lattice-aligned
-- request.provenance = {start=Endpoint, goal=Endpoint}; see below
-- config.road_material optionally identifies no-op existing road nodes
local report = search:step({max_expansions=1000, deadline=...}, clock)
search:cancel()
```

`Endpoint` is `{requested={x,y,z}, ground={x,y,z}, resolved={x,y,z}}`.
`requested` preserves the player's original feet position, including fractional
coordinates; `ground` is the inspected natural surface under that requested
position before lattice snapping; `resolved` is the inspected lattice point.
For the start, ground and resolved coincide. `request.start` and `request.goal`
must equal their provenance's resolved points. Endpoint resolution constructs
this object; the planner copies the complete request into its route result,
and `plans.compose` copies it into the plan. Thus composition does not need to
reconstruct player positions from a centerline. Reject missing or inconsistent
provenance as `invalid_endpoint`.

`clock()` is an injected monotonic seconds function. Check deadline before every
heap removal, including removal of a stale entry, and before beginning an
expansion. On deadline expiry return `running` without losing an unprocessed
valid entry: either leave it on the heap or retain it as pending for the next
slice. A single expansion is not preempted. Tests can omit deadline/clock
and use only expansion counts. Timing never affects ordering or the selected
path. `step` returns `status="running"|"succeeded"|"failed"|"cancelled"`,
`metrics`, and either `route` or `error` on completion. Terminal calls return
the same result and do no more work. Cancellation is idempotent. Count an
expansion only when a current, non-stale best entry begins expansion; a valid
entry retained pending is counted once when resumed. Retained
states means unique discovered state records; cap heap entries separately at
250,000 so stale priority entries cannot defeat the memory bound. Start with
150,000 total expansions and 250,000 states/heap entries. Check a cap before
the operation that would exceed it; a pending entry remains included in the
retained-entry cap. Discarding a stale entry does not consume an expansion.
Tests must exercise a slice dominated by stale entries and a deadline reached
after a valid removal but before expansion, then resume to the same final route
and costs as an unsliced run.

The result `route` contains the complete original `request`, ordered world
centerline points including both endpoints, edge headings, cost, effective cost
parameters, and search metrics.
Success means shortest cost in this graph subject to the budgets, not a promise
that the later composition will succeed. The heuristic is horizontal Euclidean
distance. A budget failure is not `bounded_no_route`.

`plans.compose(terrain, route, config)` uses dependencies installed with
`plans.set_dependencies(raster, edges)` and requires `config.road_material`, the
adapter-owned cobblestone material ID, to recognize existing road nodes. It
rerasterizes all segments with the shared rasterizer, checks all overlaps
(including nonconsecutive ones), and emits:

```lua
{ version=1, planner_version=1, raster_version=1,
  owner="player", request=route.request,
  endpoints=route.request.provenance, survey_bounds=...,
  centerline=..., headings=..., parameters=..., cost=...,
  metrics={ -- search metrics, route length/ascent/descent/grade/turns,
            -- deduplicated cut/fill/road/clear/write counts
  },
  writes={ {x=0,y=0,z=0, kind="road"},
           {x=0,y=-1,z=0, kind="fill", material="..."},
           {x=0,y=1,z=0, kind="air"} },
  expectations=... }
```

`expectations` lists the classification/material/protection of every node on
which feasibility depends, including unchanged support and clearance. For
construction, reread this footprint with the same adapter and compare these
semantic expectations, then rerun feasibility and protection before any write.
Any mismatch makes the plan stale. Runtime node metadata must still be rejected,
even if the underlying node name is a natural material.

Resolve road material to the adapter's cobblestone, fill to the specified natural
material, and air to air. Identical writes deduplicate; different material or
kind at one coordinate, different surface heights at one column, and road/support
inside another segment's clearance cause `composition_failed`. Check the final
surface's cardinal rises too. Omit no-op writes against the snapshot; retain their
expectations where they matter. Cap actual deduplicated writes at 50,000; `config.max_writes` may lower this
limit for testing or stricter callers. Independently cap the number of distinct
surface columns at 50,000 to bound allocations even when most writes are no-ops.
`expectations` is a sorted list of `{x,y,z,kind,material,protected}` records;
material IDs retain their adapter-owned identity.

## Errors, limits, and lifecycle ownership

Errors are `{code, reason, position?, limit?, observed?}`. Stable top-level codes:

| Owner | Codes |
| --- | --- |
| Input/config | `invalid_config`, `invalid_endpoint` |
| Survey | `unsupported_world`, `survey_budget`, `survey_failed`, `survey_timeout` |
| Search | `bounded_no_route`, `expansion_budget`, `state_budget`, `heap_budget` |
| Composition | `composition_failed`, `write_budget` |
| Job/build | `busy`, `not_owner`, `no_plan`, `cancelled`, `stale_plan`, `already_built`, `build_failed`, `partial_build` |

Local edge rejection codes are `outside`, `unknown`, `water`, `structure`,
`grade`, `earthwork`, `support`, `clearance`, `protected`, `profile_conflict`,
and `step_height`. Aggregate rejection counts in search diagnostics; exhausting
the frontier returns `bounded_no_route`, with bounds, even if no boundary edge
was actually visited. Malformed public inputs return input errors, not local
edge rejections. Construction does not proceed on any composition error.

One config module owns the numerical limits from the design (distance 192,
margin 32, vertical padding 48/max span 128, chunk count 96, read allocation
2,000,000, survey inactivity 60 seconds, search slice 1000/0.005 seconds, search
caps above, write cap 50,000). Survey owns preflight coverage/allocation checks;
planner owns search limits; composition/build own write limits. Pure modules
accept config explicitly. Callers cannot silently relax shared geometry limits.

Survey configuration supplies `dimension_bounds` as the true usable overworld
(inclusive X/Y/Z) and `safe_generation_bounds={min_y,max_y}` as an independently
established inclusive interval excluding other realms and their barriers. The
VoxeLibre adapter derives the latter from authoritative world definitions and
fails closed when unavailable. Both endpoint ground heights must lie inside the
true dimension. Surface selection must also respect those true Y bounds.
Padding may extend beyond the true overworld into the safe interval. Complete
chunk coverage must stay within the true X/Z bounds, hard map limits, the safe
generation interval, and the true Y bounds padded by 48 and rounded outward to
chunks (with that envelope intersected with the map limits). This permits, for
example, a normal low overworld surface without permitting End terrain as a
destination or generation across a realm boundary.

The jobs module owns one global slot from accepted `/roads_plan` until cancel,
failure, disconnect, or completion of build. A **ready plan retains that slot**
and its owner; another request receives `busy`. The owner can preview, build, or
cancel. After build or failure, release the slot but retain one terminal report
per connected player; a built plan may be previewed and rejects repeat build as
`already_built`. Ready/terminal records are replaced by that player's next job
and discarded on disconnect/restart. Endpoint selections are separate per-player
records; modifying one's selection does not mutate an existing plan. Job IDs
invalidate late emerge callbacks. Cancellation during synchronous validation/
build is observed only after that call returns; no interleaved command is assumed.

## Worked examples

All examples use natural solid through Y=0, air above, no protection, and enough
survey margin, unless stated. Sets below include square caps.

1. **Cardinal:** A=(0,0,0), B=(4,0,0). Supercover X=0..4, Z=0;
   footprint X=-1..5, Z=-1..1: 21 surface columns at Y=0. No cuts/fills;
   three clearance nodes per column. Length/cost=4.
2. **Diagonal:** A=(0,0,0), B=(4,0,4). Supercover consists of `(k,k)`
   for k=0..4, plus `(k+1,k)` and `(k,k+1)` for k=0..3 (13 cells).
   Square dilation yields 37 columns. All Y=0; length/cost=`sqrt(32)`.
   Consecutive squares touch by faces through the side cells, without corner gaps.
3. **Uphill:** A=(0,0,0), B=(4,1,0). Let natural ground at each footprint
   column be `round(clamp(x/4,0,1))`. Profile by X=-1..5 is
   `0,0,0,1,1,1,1`; grade=1/4, maximum cardinal rise=1. There are no
   cuts/fills; cost=`4 + 4*4 = 20` with defaults.
4. **Flat bend:** previous A=(0,0,0), current B=(4,0,0), next C=(8,0,4).
   Incoming heading 0 reconstructs A from B. New heading 1 is permitted.
   The two footprints overlap in 9 columns; union has `21+37-9=49`
   columns, every one at Y=0. New edge cost=`sqrt(32)+2`. Union clearance
   is Y=1..3, with no write conflicts or unsupported surface.
5. **Width/earthwork rejection:** in example 1, lower natural ground at (2,1)
   from 0 to -3, retaining the same endpoints. The surface profile remains 0;
   this outer road column requires three nodes of height difference and rejects
   as `earthwork`, even though every centerline sample remains flat. At ground
   -2 it is allowed: fill at -1 supports the road at 0, with air at 1..3.
