# Roads: minimal testable planner

Status: proposed design, ready to guide a first implementation.

## Purpose

Demonstrate that a bounded planner can find a reasonable road through actual
VoxeLibre terrain between two explicit endpoints. Display it with plain blocks.
The first question is whether the route makes sense on foot, not whether its
paving, bridges, or roadside scenery look finished.

Success means reproducible, connected routes that trade distance against grade,
turning, and small terrain modifications, with bounded generation and search.
A failed search must explain its limit instead of claiming that no route exists
anywhere in the world.

## Scope and decisions

The initial model supports one manually requested connection at a time, in the
overworld, with v7 and flat as the first validation mapgens. It uses existing
VoxeLibre nodes and has no Towns or Living Villages dependency.

Included:

- Read-only route planning over a bounded, explicitly surveyed region.
- A three-node-wide road with enough headroom for walking.
- Gentle grades, bends, shallow cuts, and low supported fills.
- A preview of the selected centerline and a separate command to build it.
- Deterministic reports, a plain Lua planner harness, and real-world trials.

Deferred:

- Automatic destination selection, unexplored town candidates, network growth,
  junctions, persistence across restarts, and standalone waystones.
- Hierarchical search, D* Lite, continuous curves, and arbitrary road elevations.
- Bridge and tunnel moves. These remain explicit future search extensions.
- Decorative surfaces, custom nodes, mobs, and gameplay rewards.

Floating preview markers can show a tentative route, but a built road in this
milestone must have support. Water and large drops are obstacles. This deliberately
tests the surface-routing foundation before adding expensive crossing choices.

## User workflow

Proposed commands, all requiring the `server` privilege:

1. `/roads_start` records an endpoint at the player's feet.
2. `/roads_plan` records the other endpoint and starts survey and search.
3. `/roads_preview` displays temporary particles along the centerline.
4. `/roads_build` validates and builds the last successful plan.
5. `/roads_status` reports the current stage, progress, result, or failure.
6. `/roads_cancel` cancels planning or discards an unbuilt result.

Commands respond immediately. One global job prevents overlapping surveys and
writes. Requests during an active job are rejected clearly. Endpoint selections
belong to the requesting player. Disconnect cancels an unfinished job; server
restart discards all jobs and plans for this milestone.

Planning never places road blocks. Surveying can generate new terrain and thus
trigger other mods; the command help must say so. Building only accepts a plan
owned by the requesting player. An interrupted build is reported as partial;
there is no promise of transactional rollback.

## Coordinates and endpoints

Use world X/Z horizontally and world Y vertically. A road surface Y denotes the
topmost full support block; a walker occupies the air above it.

Resolve an endpoint to natural walkable ground under the player, not to leaves,
water, a roof, or a cave floor. Reject unsupported or ambiguous endpoints.
Snap the second endpoint to the nearest point on a four-node lattice anchored at
the first endpoint, with deterministic tie-breaking. Report both requested and
resolved positions. Maximum horizontal snap distance is three nodes. The target
surface must independently pass inspection; do not silently snap across a cliff.

Exact attachment to a town gate will be a later adapter with explicit approach
geometry, not an assumption of this lattice prototype.

## Bounded terrain survey

Start with the endpoint bounding rectangle plus a 32-node margin. Maximum endpoint
separation is 192 nodes horizontally. Use a vertical interval spanning both endpoint
ground levels plus 48 nodes above and below; reject a total interval over 128 nodes.
These are initial experiment limits, not claims about useful production distances.

Before requesting terrain, round to the actual engine mapchunk coverage and count
the union. Reject a request exceeding 96 standard 80-cubed chunks. Validate the
expected chunksize and dimension bounds; unsupported configurations fail clearly.
The generated region can be larger than the requested region because generation
occurs in chunks. Include that cost in the report.

Queue small emerge requests sequentially. Check every completion outcome, enforce
a 60-second no-progress timeout, and stop scheduling after cancellation. Late
callbacks must check the job identity and do nothing for an obsolete job.

Read terrain in bounded patches after emerge completion, rather than retaining
the entire voxel volume. Initial maximum read allocation: two million voxels.
Keep a compact surface summary for each X/Z column:

- Surface Y and material, or a reason that the column is unusable/unknown.
- Whether the column is wet or occupied by an authored/unsupported structure.
- Replaceable vegetation and the clearance available above the surface.
- Information needed to validate the permitted shallow excavation and fill.

Use a conservative VoxeLibre material adapter with explicit natural-material and
replaceable-plant rules. Ignore canopy as ground; do not interpret `ignore`, missing
ground, or an inspection-window boundary as a traversable surface. Unknown nodes
and structures are obstacles. This cannot prove that natural-looking blocks were
not placed by a player; use disposable test worlds for initial construction.

Check protection for the complete candidate write footprint. Voxel writes do not
enforce protection automatically. Revalidate against actual nodes before building.

Do not add automatic survey expansion yet. A route blocked by the survey boundary
returns `bounded_no_route`, with the region dimensions in its report.

## Search graph

Implement A* in pure Lua over an injected terrain summary. Use a binary heap,
stable neighbor order, and deterministic tie-breaking. No world access or random
numbers occur inside the planner.

Initial state: `(lattice_x, lattice_z, incoming_heading)`. Eight headings connect
neighboring lattice points, four nodes apart on each axis. Start heading is free;
the goal accepts any heading. Each edge is a short straight segment. Adjacent
edges may change heading by at most 45 degrees.

For this milestone, road Y at each lattice point is the surveyed natural-ground Y.
An edge's intermediate profile linearly interpolates those endpoint heights.
This avoids a large elevation search dimension. It does mean the planner cannot
choose to stay high across a broad depression; that limitation is deliberate.

Reject an edge if:

- Its absolute grade exceeds 1:4.
- Its full-width rasterized profile requires cutting or filling over two nodes.
- It encounters water, unknown terrain, structures, protection, or the region edge.
- It cannot provide three air nodes of headroom above the walking surface.
- Its final block representation would have an adjacent rise greater than one node.

Validate the segment interior and road width, not just its endpoint samples.
Diagonal edges use a connected supercover raster; width is a swept three-node
footprint. The join of successive edges must also be checked for clearance,
support, and connection. Incoming heading makes this join check well-defined.

Proposed segment cost:

    horizontal_length
    + slope_weight * horizontal_length * (grade / max_grade)^2
    + turn_weight * (heading_change / 45_degrees)^2
    + cut_weight * excavated_block_count
    + fill_weight * added_support_block_count

All weights are nonnegative. Counts refer to each segment's proposed footprint;
small overlaps at joins may be counted twice in the estimate. The final report
also gives deduplicated construction counts. Cost is a design preference, not a
simulation of money or labor.

Use horizontal straight-line distance to the goal as the A* heuristic, since every
edge costs at least its horizontal length. Do not add an unproven slope estimate
that could overestimate remaining cost. The shortest result is relative to this
discrete graph and surveyed region, not to all possible roads in the world.

Process search in resumable slices: initially at most 1,000 expansions or 5 ms per
server step, whichever occurs first. Cap total expansions at 150,000 and retained
search states at 250,000; stop with a specific budget failure. These values must be
measured in Luanti and adjusted if memory or responsiveness is poor.

## Plan representation and construction

A successful plan contains resolved endpoints, survey bounds, ordered centerline
points with Y, segment headings, cost parameters, metrics, and version numbers for
the planner and rasterizer. Keep it in memory for the current session.

The same rasterizer used for edge validation produces the final deduplicated
write list. Reject conflicting writes at self-overlaps or joins rather than letting
write order decide the road shape. This final composition check can fail even
after graph search succeeds; report `composition_failed` and retain its diagnostics.

Use cobblestone full blocks for the initial supported road, with air clearance
and natural-material fill beneath it. A rise of one full block is acceptable for
this walking experiment; stairs and slabs are a later renderer improvement.
Do not place inventories, metadata, schematics, or custom nodes.

Before any construction, reread and validate the entire affected footprint against
current terrain and protection. A stale or conflicting plan requires replanning.
For the first implementation, cap the final write list at 50,000 nodes and apply
the validated list in one synchronous batch, so callbacks cannot modify the world
between validation and successive write batches. Measure this pause; reduce the
cap if necessary. Any future batched writer needs per-batch revalidation and
explicit partial-completion handling.

Retain a completed result for status/preview but reject a second build of it.
Never automatically rebuild a road that a player subsequently edits.

## Suggested files

- `mod.conf`, `init.lua`: dependency metadata and wiring.
- `src/config.lua`: limits and named cost presets.
- `src/terrain.lua`: emerge lifecycle and compact survey.
- `src/voxelibre.lua`: material, dimension, and protection adapter.
- `src/raster.lua`: shared footprint, profile, and write-list geometry.
- `src/planner.lua`: graph, heap, resumable A*, and metrics.
- `src/jobs.lua`: command ownership, cancellation, and state transitions.
- `src/commands.lua`, `src/preview.lua`, `src/build.lua`: engine integration.
- `tests/`: synthetic terrains and planner/geometry checks using Lua 5.1.

State transitions:

    idle -> surveying -> searching -> ready -> validating -> built
                         |            |          |
                         +-> failed   +-> cancel +-> stale / failed / partial

Cancellation and failure are possible during survey and search as well. One
cleanup path releases job ownership in every terminal case.

## Validation and acceptance

Synthetic fixtures test behavior, not exact implementation-specific paths:

1. Flat land: connected near-direct route, no unsupported sections.
2. Rounded hill: a suitable slope cost makes a gentler detour beat a steep crossing.
3. Ridge with a pass: use the pass when all other crossings exceed maximum grade.
4. Shallow depression: use bounded fill where allowed.
5. Deep ravine/water barrier: detour if available; otherwise bounded failure.
6. Protected rectangle and narrow ledge: the complete road width avoids obstacles.
7. Diagonal bends: connected, supported raster without gaps or clearance conflicts.
8. Missing surface and exhausted budgets: specific failures, no road writes.
9. Repeat input: identical route and metrics under deterministic tie-breaking.

Also check that every accepted edge obeys grade, clearance, and earthwork limits,
and that cancellation/late callbacks cannot resume an obsolete job. Inject stale
terrain and protection changes before building and verify zero road writes.

In disposable flat and v7 worlds, inspect routes on foot and record endpoint
distance, route length, climb/descent, maximum grade, turns, cuts/fills, generated
chunks, survey time, search expansions, peak states, and longest server slice.
Use a small set of fixed coordinates and seeds for repeat comparisons.

The milestone is accepted when these trials produce reasonable routes or clear
bounded failures, the built path matches validation, and work stays inside its
generation, allocation, search, and write caps. Visual beauty is not required.

## Implementation sequence

1. Pure terrain fixtures, rasterizer, and resumable planner; inspect path metrics.
2. Read-only real-world survey, commands, and particle preview.
3. Shared construction composition, stale-plan validation, and plain-block build.
4. Compare cost presets on the same terrain; record evidence and tune defaults.

Only then decide whether the next investment should be longer-range hierarchical
planning, selectable road elevations, bridge/tunnel edges, or Towns integration.
Do not add all four to rescue an unmeasured first planner.

## Extension contracts

Destination selection will provide endpoint candidates independently of routing.
Towns integration must distinguish predicted sites from completed towns and expose
actual usable approaches. Its current candidate-site and road-exit modules are
internal implementation details, not a stable integration contract.

Bridge/tunnel edges can later connect nonadjacent states with fixed setup and
length-dependent costs, bounded surveyed interiors, compatible approach headings,
and explicit segment types. Arbitrary road Y requires extending the search state;
construction mode or span history may also be needed if crossings grow stepwise.

Incremental surveys will require coordination with town construction and other
terrain writers: emerge completion alone does not guarantee that deferred mod
jobs have finished. That coordination is outside this standalone experiment.

## References

- [Luanti mod structure](https://api.luanti.org/mods/).
- [Luanti environment, generation, and storage APIs](https://api.luanti.org/core-namespace-reference/).
- [Luanti mapgen objects and heightmap scope](https://api.luanti.org/mapgen-objects/).
- [Galin et al., Procedural Generation of Roads](https://doi.org/10.1111/j.1467-8659.2009.01612.x).
- [Dolgov et al., Practical Search Techniques in Path Planning for Autonomous Driving](https://ai.stanford.edu/~ddolgov/papers/dolgov_gpp_stair08.pdf).
- [Koenig and Likhachev, D* Lite](https://idm-lab.org/bib/abstracts/Koen02e.html).
