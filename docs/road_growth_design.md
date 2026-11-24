# Player-driven road growth (#44)

Status: engineering design for [epic #44](https://github.com/tbook/luanti-roads/issues/44).
This document specifies future implementation, not behavior already shipped.
It supersedes the terrain-load growth idea in `brainstorm.txt` and the
continuation item in #40. The existing planner and outward-road documents remain
the contracts for their current versions.

## Behavior and boundaries

An unfinished road extends by one bounded segment when a player makes a fresh
approach to its endpoint. Every cycle looks for known destinations again. It
tries suitable destinations first, then a target in the road's preferred outward
direction. A distant destination can steer several cycles without being reserved
as a permanent objective. A road stops when it makes a verified connection or
when the bounded cycle fails. Failure means blocked under these limits, not proof
that no route exists anywhere.

Preferred direction is the original exit's cardinal outward vector. Local heading
is the last constructed lattice edge, including diagonal bends. Store both;
never update preferred direction from a detour. No global network search is needed.

New-town automatic starts (#42), major-gate origin selection (#41), and optional
completed-village destinations (#43) remain separate work. Automatic initial roads
eventually apply only to new towns; that does not disqualify a command-built
road from explicit continuation or testing when its original write recorded the
growth seed specified below. Current pre-seed records cannot be adopted. Villages do not originate
roads. Existing-road junctions remain part of #44, in their own implementation
slice. Bridges, tunnels, edited-road reconstruction and predicted settlements
are excluded.

The constants below are initial tunable defaults, not measured performance
claims. Their finite upper bounds are acceptance requirements. Raising them
requires reviewing generation, memory, disk use and server pauses together.

## Current implementation constraints

`outward.lua` already owns candidate attempts, unioned survey chunk accounting,
aggregate expansions, the shared `jobs` slot, Towns waiting and durable intent.
`outward_store.lua` saves schema-1 documents under
`outward/v1/settlement/<id>`; a built operation reserves a whole settlement.
Its road stores centerline, headings, terminal and original outward vector, but
not an exact continuation seam. It cannot simply become a sequence of repeated
outward requests: its origin and reservation semantics differ.

`planner.new(terrain, request, config)` seeds a free heading. It requires a
four-node lattice, endpoints within 192 nodes, and endpoint Y equal to the
surveyed ground. `edges.evaluate` validates a prior edge by reconstructing it
from that ground. `plans.compose` independently resets the first incoming
heading and rejects conflicting overlapping surface heights. The three-node
swept raster can overlap the preceding segment even when centerlines meet at
one point. Direction matching alone does not establish a valid seam.

Current Towns connector v1 accepts cardinal strips of width 2 or 4 and a flat
transition. It forbids operations touching its preserved nodes. It is not a
generic continuation or junction representation. Plans v1/v2 and the current
manual commands must retain their existing behavior.

The adapter's `overlay(rect, source, selected_exit_id)` masks exclusions and
other exits as structures. It has no destination-exit exception. Final Towns
attachment therefore needs explicit geometry and overlay changes; aiming at a
town center or passing a second exit through today's wrapper will not work.

## Small shared interfaces

Keep survey, policy, geometry, construction and persistence separate. Add a
`growth.lua` service and `growth_store.lua`; put pure selection in
`growth_policy.lua`. Extend existing geometry modules rather than creating a
second planner or writer. Reuse the outward service's injected dependencies and
global `jobs:hold/release` convention. Extract shared attempt bookkeeping only
where both services actually need it; do not refactor the manual workflow.

Proposed service methods (errors retain `{code, reason, position?, limit?, observed?}`):

```lua
growth:adopt(outward_op_id, actor)       --> road_id | nil, err
growth:extend(road_id, actor)            --> cycle_id | nil, err
growth:status(road_id)                   --> bounded_summary | nil, err
growth:cancel(road_id, actor)            --> true | nil, err
growth:retry(road_id, actor)             --> cycle_id | nil, err
growth:retire(road_id, actor)            --> true | nil, err
growth:inspect(road_id, actor)           --> bounded_report | nil, err
```

Expose these through one server-privileged command family:
`/roads_grow adopt <outward-op-id>`, `extend|status|cancel|retry|retire|inspect <road-id>`.
Adoption and administrative actions never imply permission to overwrite edits.
`inspect` may load existing mapblocks but must not generate terrain. Summary
includes endpoint/revision, preferred/local directions, selected and rejected
destinations, fallback, each attempt, budgets, seam status and stop reason.
Preview shows the current cycle or last segment; status is available after restart.

Destination providers expose one bounded query shape:

```lua
provider:nearby(pos, radius, limit) --> {items={descriptor...},
--   truncation="none"|"truncated"|"possible"} | nil, err
-- descriptor = {version=1, kind="town"|"village"|"road", id=stable_id,
--   approach_id=stable_id, position={x,y,z}, direction={x,z}, revision=...}
```

The provider result uses `truncation="possible"` when completeness is unknown;
status renders this as `possibly_truncated`.
Towns v1 has no truncation flag: exactly 32 returned settlements must be reported
as possibly truncated, even if the underlying registry has exactly 32. Fewer
than 32 does not waive the consumer's own descriptor cap.
Descriptors identify completed published approaches, not arbitrary coordinates.
The owning adapter resolves and rechecks their full geometry later. Towns uses
its public v1 API only. There is no optional village API in Roads today: #43
must define and verify its producer contract before enabling that provider.
Absence disables that provider; an installed but unhealthy settlement/exclusion
provider fails the cycle closed, rather than masquerading as an empty list.

## Connected continuation geometry

Add plan version 3 for growth, with `seam_version=1`; leave v1/v2 validation
unchanged. Add `request.start_heading` (integer 0..7), `request.start_seam`
and optional `request.goal_attachment`. These are validated data, not arbitrary
callbacks. Both planner and composer use the incoming heading for the first
edge. Route output still starts at the saved endpoint; it does not prepend an
old edge and rebuild it. Edges use the stored prior edge's actual Y for the
initial join, rather than guessing its old natural-ground height.

Define v3-only `provenance.start.origin="growth_seam"`: its resolved endpoint
and route's first point use the saved, exact-validated built surface Y. This
explicitly replaces the current nonconnector `ground==resolved` requirement
only for that authenticated start. Route reconstruction must retain that saved
Y instead of rereading it as natural ground. Edge and composer terrain access
may overlay Y only within authenticated preserved seam surface columns after
exact world validation. Their underlying support/clearance nodes still come
from the validated world, and surrounding natural terrain is freshly surveyed;
unknown or changed columns remain obstacles. This handles cut/fill endpoints
without weakening v1/v2 provenance or inventing traversable ground.

```lua
seam = {version=1, endpoint={x,y,z}, heading=0,
  previous={x,y,z}, surfaces={{x,y,z}, ...},
  preserved={{x,y,z,name,param2,has_metadata=false,protected=false}, ...}}
```

The seam comprises the last two rasterized edges, clipped to their actual built
footprint, their support/clearance expectations and final node states. Derive
these final states from the validated plan and its writes before construction;
read them back after construction before publishing the next endpoint. Cap the
patch at 512 exact nodes. If the patch cannot fit, fail before any write. Two
edges cover the immediate join; this does not authorize overlap with any older
part of the road. Check such overlap against the stored road footprint as well.

Implementation clarification: retain the last three centerline points (or both
points for a one-edge source), not just the immediately previous point. The
canonical patch is the joined raster of those edges, clipped to the source
plan's actual footprint. Record the bottom of the original construction band
for each surface column and every exact final node through three nodes above the
surface. These bounds come from the validated source plan, not the current
world. Semantic source expectations alone do not contain exact node names or
param2: capture exact pre-write states, verify them against the source plan,
overlay its writes, and persist the resulting intended states before writing.
The builder must independently check structure and reject missing expectations,
preserved writes and geometry that would require a removed write. Slice B owns
authentication against the durable source record and post-write readback.

Read and validate every seam node, metadata, timer and protection before search,
and again in the synchronous construction preflight. Unknown, missing or edited
seams stop with `seam_changed`; never repair them. Preserve exact param2 even
for full blocks. Survey must include the prior edge and seam band. No synthetic
surface may make unknown or changed world nodes traversable.

Geometry constraints distinguish read-only existing surfaces from new surfaces:
an overlapping seam column is permitted only at the identical surface Y; its
support and headroom must pass exact expectations. Validate the union with
`raster.join`, including adjacent steps, grade and at most a 45-degree turn.
Composer emits zero writes anywhere in the preserved patch, and incorporates
its exact expectations. A required cut, fill or clearance write there rejects
the candidate. The v3 builder independently rejects preserved-node writes and
inconsistent provenance. Merely removing conflicting writes is insufficient.

Mask all other stored road footprints, including this road's earlier segments,
as obstacles. Permit only the validated start patch and, later, a selected goal
attachment patch. A footprint is the swept raster plus construction support and
clearance band, not just centerline points or cobblestone classification. Search
and composition share the same masks. This prevents return through the source,
own-road loops, accidental crossings and paving over another road.

For initial command continuation, use a deterministic 96-node forward target,
then 64 nodes if needed, snapped to the current endpoint lattice. Preserve the
preferred vector; report a blocked outcome when local terrain cannot depart
smoothly toward these bounded goals. Do not relax the seam to make progress.

## One destination-aware cycle

1. Lock the road's endpoint revision and the shared job slot. Reject connected,
   retired, active or uncertain records. Verify the seam. Snapshot known
   destinations before any survey/emerge; new discoveries are considered next
   cycle. The command-only first slice records `scan=disabled_by_stage` until
   providers land; automatic activation requires the completed cycle policy.
2. Query within 512 horizontal nodes. Towns returns at most 32 settlements with
   at most 32 exits each. Inspect at most 1,024 exit descriptors. Road provider
   scans its bounded spatial index, never the world's mapblocks. Village query
   will share the same total descriptor cap of 1,024 rather than add to it.
   On truncation report it; do not claim no destination exists beyond the cap.
3. Exclude the source settlement, own road, uncertain/busy approaches and
   destinations behind the road: target displacement must have a positive dot
   product with preferred direction and lie within 60 degrees of it. This
   policy avoids returning to the origin without assuming local bends are the
   preferred direction. Compatibility also requires a supported final approach;
   opposite-growing roads are attractive but cardinal equality is not required.
4. Sort by horizontal approach distance, then kind and stable approach ID.
   Retain at most two distinct candidates. Recheck a descriptor before use.
   When the exact approach can fit the 192-node planner range, try a real final
   attachment. Otherwise target a 96-node waypoint toward it, rounded on the
   endpoint's lattice; mark the result `partial_progress`, never `connected`.
   Reject a waypoint that does not advance at least 32 nodes toward its selected
   destination. Re-scan even after successful partial progress next cycle.
5. Attempt candidates sequentially. A failed route/composition uses its actual
   work allocation; release its snapshot before trying another. If no candidate
   succeeds, try directional fallback (96 then 64 nodes). A successful candidate
   produces at most one constructed segment, not a second fallback segment.
6. Persist intent, revalidate guards and build. Publish a new endpoint only
   after full success and seam readback. A valid final attachment stops this
   road as `connected`. All attempts failing stops it as `blocked`, with the
   concrete last error and all attempted outcomes; revisits do not retry it.

Budget partition makes fallback a real attempt, not an unreachable code path:

| Resource | Whole cycle ceiling | Destination portion | Reserved fallback portion |
| --- | --- | --- | --- |
| Distinct generated/surveyed mapchunks | 96 | at most 64 | at least 32 unused slots |
| Search expansions | 150,000 | at most 100,000 (50,000 each) | 50,000 total |
| Attempts | 4 | 2 | 2 |

Count unioned mapchunks before emerge, including failed/partial surveys. Count
repeated search work, not only successful work. Fallback can reuse chunks from
the destination portion. If its preflight cannot fit remaining coverage, record
`survey_budget` without generating; a reservation does not promise any terrain
can be routed. Destination failure must not terminate the cycle merely because
its individual expansion allowance expired (today's outward service does this).
Unused destination allowance can pass to fallback within whole-cycle limits.

Retain current caps: 192-node endpoint separation, 128-node vertical survey
interval, two million voxels per read, 250,000 search states and heap entries,
1,000 expansions or 5 ms per search slice, 10,000 writes and 50,000 expectations
per build. Add a 1,024-centerline-point cap before saving a growth segment.
Keep 60-second survey no-progress and 180-second Towns-writer limits. Reject
oversized work before allocation/generation. One segment uses one final
synchronous builder batch; measure its pause rather than claiming a 5 ms write
budget. Each error identifies the limit and observed value.

## Final attachments

**Completed Towns.** `towns_api` v1 publishes complete settlements and verified
exit profiles; `src/towns_adapter.lua` already validates supported widths and
profiles. Add a resolver for a growth start seam and a destination published
exit. Select a compatible natural landing on the start's lattice outside the
destination footprint, then validate the reversed walking path from that landing
onto the actual built exit. Arrival heading faces into the town (opposite the
published outward vector), with at most the allowed 45-degree final bend.
Reuse the existing connector strip/path/transition validators where possible;
do not assume reversing direction also reverses stair facedir correctly.

Generalize the overlay input to a bounded list of selected approaches. The only
exception is exact inspected preserved exit geometry and an allowed transition
outside the core/structures. Never subtract an entire destination reservation,
exit bounding box or town core from exclusions. Untouched preserved nodes can
remain inside exclusions; every proposed write must still pass the normal
Towns guard. If no supported landing/transition fits, reject that destination
and allow fallback. No Towns producer change is required by this design.

Re-read the published settlement/exit and exact world approach, check protection,
and query fresh exclusions/writer immediately before construction using the
current guard discipline. Revalidate the whole walking path after writes before
marking connected. Ending nearby, touching an exclusion or reaching a waypoint
does not count as arrival. Reserve the selected full exit ID during final
attachment so another road cannot construct a duplicate join after this one.

Before selection and again during synchronous preflight, consult both outward
reservations and growth claims. An outward operation that reserves this exit
(including unadopted built, partial or uncertain work) makes it unavailable as
an incoming destination. Legacy built records reserve the whole settlement under
the existing service contract: conservatively reject that settlement's exits,
rather than guessing which other exits are actually free. Do not silently weaken
this legacy rule. B defines an injected read-only incoming-claim lookup for the
current `outward.lua` service, backed by the growth registry (empty when no claims
exist). Today's `/roads_outward` must reject a claimed full exit ID before
accepting an origin request and check again in its synchronous construction
preflight, not only during planning. F populates those same claims for incoming
attachments. This is required current-service integration, with no dependency
on #41/#42. Future origin registration and #41's eventual per-gate work must
honor the same lookup. All origins and final attachments share the global slot;
admission and preflight both check these claims. Test outward-first and
incoming-first ordering, including persisted incoming claims after restart.
#41 may deliberately replace the legacy settlement-wide policy in its own scope.

**Existing Roads roads.** This means verified, registered Roads segments, not
arbitrary cobblestone or all player-built paths. Initially permit end-to-end
joins and T junctions onto a flat straight interior edge with enough approach
clearance. Exclude bends, sloped interiors, uncertain segments and own-road
segments. This useful subset keeps junction geometry small; report unsupported
approaches rather than silently crossing a road. Spatial discovery finds
candidate edges; actual nodes, support/headroom and the proposed union determine
compatibility. Preserve all existing target nodes, write only the new approach,
and prove a full-width cardinally connected walkable union. Do not require the
two road lattices to align: a bounded flat transition outside the target's
preserved patch bridges supported offsets, like a Towns transition. Failure
falls back rather than snapping or rewriting the target road.

Use a stable target edge ID plus a reserved join interval (edge and adjacent
footprint) to suppress overlapping joins, not only an exact center point.
Serialization in the single job slot handles live races; persistent claims handle
restart. An end-to-end join marks both unfinished endpoints connected. A T join
stops the incoming road while the target road's own endpoint may continue.
Post-build inspection and restart recovery belong in the junction ticket.

## Persistence, reservations and recovery

Use a new growth namespace. Do not migrate legacy schema-1 outward records or
change their one-road-per-settlement rule as part of continuation. Future outward
operations gain an optional reference to a separately versioned growth seed;
their existing schema and reservation meaning stay compatible. Growth road identity
is `growth:v1:<outward-op-id>`; segment/cycle identities use a monotonically
allocated per-road sequence and include the source endpoint revision. Never
reuse an identity, including after zero-write failure. A segment is identified
before any world write. Records are versioned and validated on read.

```lua
registry = {schema=1, roads={ [road_id]={origin_op_id=...,
  source={settlement_id=..., exit_id=...}, preferred={x=1,z=0},
  revision=1, endpoint={x,y,z}, local_heading=0, last_segment_id=...,
  state="open", next_seq=2, activation="needs_departure"} },
  claims={...}, pending=nil}
segment = {schema=1, id=..., road_id=..., sequence=..., from_revision=...,
  state="prepared", writes="none", centerline={...}, headings={...},
  start_seam=..., next_seam=..., footprint=..., destination=...,
  attempts={...}, aggregate=..., policy_version=1, geometry_version=1}
```

Keep one bounded registry document as the authority for endpoint revisions,
active intent and join claims; immutable per-segment geometry lives in separate
keys. Only the latest four zero-write attempt summaries per road need retention.
Do not retain survey voxels or full search state. Global caps: 128 roads, 1,024
possibly-written segments total, 128 per road, 128 KiB per segment, 4 MiB registry.
Cap each segment's spatial-index references at 16 cells (128-node cells), total
16,384 references. Stored raster geometry allows index reconstruction; the index
is a cache, not authority. Startup and queries process bounded batches. A
512-node query visits at most 100 cells and at most 1,024 segment references
(deduplicate before raster inspection); the total descriptor budget still
applies. Oversized/corrupt records or indexes disable growth with an inspectable
error, not an empty network. Full registry/segment cap means `storage_budget`;
never evict built/uncertain reservations to admit more work. These caps bound disk
to approximately 132 MiB plus codec/key overhead; not a claim about Lua heap use.

Destination discovery can truncate its candidate list. Obstacle lookup cannot:
before surveying a corridor, collect every intersecting stored footprint from
all relevant index cells, within a hard 1,024-reference cap. If coverage cannot
be established within that cap, fail closed with `road_index_budget` before
survey/generation; never interpret omitted references as clear terrain. Recheck
complete coverage for the actual composed footprint before construction.
Tests must include dense cells exceeding the cap and show zero writes/generation.

Commit ordering under the shared global slot:

1. Allocate sequence, persist planning intent, consume the endpoint revision's
   activation, and read back before starting survey. No connection claim is
   needed for a distant steering waypoint.
2. Save the prepared segment geometry and exact seam/attachment final states.
   Save/read back one registry update containing `pending={segment_id,
   from_revision, writes="unknown", state="building"}` and all affected source,
   destination-exit or road-join claims. Thus one authoritative document reserves
   both sides; cross-key atomic transactions are not assumed. A dangling prepared
   segment without that registry update is known to have made zero writes.
3. Use the existing outward durability wait before handing off to the builder.
   Retain its supported save-interval refusal. Recheck endpoint revision,
   destination claim, Towns guards and exact expectations after the wait.
4. Construct once. Save segment result, then publish the next endpoint/connected
   states and clear pending in the registry. Keep successful join claims. Failure
   to save a completion leaves the old `building` intent reserved and uncertain;
   never advance optimistically or replay its segment after restart.

The current wait/readback scheme is an engine-dependent durability assumption,
not an fsync or power-loss guarantee. #38's engine restart/partial trials are a
release prerequisite before any automatic writes, and the growth ticket must
check supported Luanti storage behavior against the actual engine version.
If record-before-write ordering cannot be established there, keep automatic
growth disabled and report the blocker; do not substitute a claim of atomicity.

Restart converts planning to stopped/no-writes and building to uncertain/unknown,
reserving both source and target. It starts no growth and replays no writes.
Uncertain and partial segments remain visible obstacles. `cancel` stops pending
callbacks using operation tokens; before builder entry it records known zero
writes, after possible writes it cannot reopen anything. Disconnect does not
cancel world-owned work. Never infer zero writes from a generic exception after
the writer began; preserve the conservative outcome even if an inner builder
exception is currently reported as `build_failed`.

`retry` is deliberate and only allowed for blocked/cancelled/failed known-zero
work after revalidation. `retire` stops future growth and retains all reservations.
`inspect` compares the bounded intended seam/attachment with actual world nodes.
For uncertain work it can report fully matching final geometry or mismatches,
but this milestone does not automatically promote, repair or replay it. Keep it
retired/reserved; further continuation requires a separately reviewed recovery
decision. This is intentionally conservative and must be explained in status.

Future outward operations produce `growth_seed={version=1, origin_op_id,
geometry_version=1, centerline, headings, footprint, terminal, preferred,
seam, state="intended"}` in a separate bounded 128-KiB record before any writes.
The seam records intended final material, param2, support and clearance derived
from the actual composed expectations plus writes. Persist/read back that seed
and the operation's reference before the existing outward durability wait.
After construction, read back its exact patch and only then mark the seed
verified. If verification or saving fails, the outward result remains inspectable
under its normal reservation rules, but it is not growth-ready. This producer
support is a change inside today's Roads outward pipeline, not a #41/#42
dependency. Count seed records and their bytes within growth storage caps.

Adoption is explicit and idempotent. Accept only a durably saved `built/all`
outward operation with a verified durable seed and matching identity/geometry.
Load the bounded patch without generation and compare every expected node,
support, clearance, metadata, timer and protection again before persisting the
growth record. Never derive intended state from today's world and call it proof
that a road was not edited. Existing records lack these intended states and are
explicitly unadoptable, even if their centerline still looks correct. Partial,
unknown, malformed or mismatching operations are also unadoptable with a reason.
The old source reservation stays. The first continuation trial therefore builds
a fresh command-driven outward road with seed recording enabled, then adopts
it; there is no old-road backfill. New origins can use the same producer contract
when #41/#42 arrive. Unknown future schemas are read-only blocked data; no silent
downgrade or migration drops claims.

## Player activation and scheduling

Use player positions, not `on_generated`, mapblock loading or emerge callbacks.
An endpoint has a horizontal inner radius of 24 nodes, outer radius of 36 and
vertical tolerance of 16. Sample positions every second. To arm a player for a
particular endpoint revision, observe that player outside the outer radius;
crossing into the inner radius later supplies one approach token. Require a
finite valid position and an alive connected player. Players first observed
inside an endpoint, including after teleport/login/restart, supply no token.

On every new endpoint revision, discard every player's old arming information;
the new endpoint needs its own outside-then-inside observation. For an ordinary
straight 64-node extension, a player at the old inner radius's forward edge is
40 nodes from the new endpoint, outside 36; the next sample can arm that player,
then their advance into 24 can activate it. Include this exact case in tests.
A stationary player, another player already standing at the new endpoint,
road-generated terrain, and a restart cannot chain construction. Leaving beyond
36 and returning can activate one still-open endpoint; a blocked endpoint needs
explicit administrative retry. Short/detoured progress or a player moving near
the new endpoint during construction may leave them inside 36 at publication;
that player must depart and approach again. Sampled observations do not claim
perfect physical crossing detection. There is no per-road cooldown in this
version: one token per revision, the global job and bounded queue/cycle budgets
limit growth. Commands supply explicit activation and bypass proximity only.

Persist revision and consumed intent before surveying. The arming map is
session-only, keyed by player and revision, bounded to 32 players and 128 roads;
extra players are processed round-robin by rotating the retained player slots.
Evicting a slot drops all its arming history; readmission requires a new outside
observation and later crossing, never restores a cached token. Thus excess
players may miss an approach but cannot gain one from eviction. Keep a rotating
endpoint-comparison cursor per retained player; sample a fresh position on each
visit and retain outside observations only for the current revision.
Remove disconnected players and obsolete revisions. Use a 128-node endpoint
index; each player only queries neighboring cells. Bound scheduler work to 32
player samples and 64 endpoint comparisons per tick; rotate cursors for fairness.
Crossings are defined by these sampled observations, not every physical motion.
Fast approaches can be missed and safely require another approach.

Queue at most 16 unique `{road_id, revision}` entries, one active global job.
Reserve each queued key in memory, coalesce players, and recheck position,
revision, state and the triggering player's continued proximity when dequeuing.
Entries expire after 30 seconds;
stale/full entries produce no writes and require a new crossing. Queue is not
persisted. Never renew a token from a stationary player when an entry expires.
Only consume the durable endpoint intent once actual work is admitted. Manual
planning continues to own its slot until released; queued growth waits fairly
and cannot cancel it. #42's initial-road scheduler must use this same slot and
bounded queue/admission helper, not add a second worker.

## Implementation tickets

The tickets below reference this design and [design PR #45](https://github.com/tbook/luanti-roads/pull/45).
Implementation is blocked on design approval and merge. Their design links pin
the reviewed design commit; the PR carries subsequent corrections and tracking
links. Every ticket also references epic #44. Each feature
slice includes status, deliberate retry/cancel and conservative recovery for its
own behavior; no separate tools or recovery epic is needed.

| Slice | Suggested developer | Dependencies | Acceptance and verification |
| --- | --- | --- | --- |
| [A. Validated continuation seams and plan v3](https://github.com/tbook/luanti-roads/issues/46) | Senior (geometry judgment) | Approved design | Implement v3-only start provenance/Y, initial heading in planner and composer, exact preserved patch and independent builder checks. Keep v1/v2 behavior unchanged. Pure Lua tests cover cut/fill endpoint Y, diagonal/sloped bends, overlapping raster heights, changed support/headroom/metadata/protection/timers, unknown terrain and patch caps. No commands or automatic construction yet. |
| [B. Durable growth lifecycle, outward seed producer and adoption](https://github.com/tbook/luanti-roads/issues/47) | Senior (persistence and interruption judgment) | A | Future outward operations record intended seed before writes and read back after build; current legacy operations are explicitly unadoptable. Implement versioned registry/segments, dual-side claims, bounded complete obstacle index, one-cycle service and token-safe cancellation. Inject growth-claim lookup into current outward admission and synchronous preflight; fake incoming claims test rejection before F exists. Preserve old outward reservations. Test record limits, dense index overflow, duplicate revisions, save failures before/after writes, uncertain builder outcomes and restart without replay. Supply bounded status/inspect/retry/retire service methods and demonstrate a fresh seeded outward road plus one continuation in a disposable world. |
| [C. Command-driven one-segment workflow and trial evidence](https://github.com/tbook/luanti-roads/issues/48) | Junior (command/presentation integration) | B | Wire the server-privileged command family, persistent lookup and bounded preview/status. Explicitly report legacy adoption refusal, local/preferred headings, seam result, blocked reason, limits and uncertainty. Tests cover argument/privilege errors, repeated adoption/extension, cancellation and deliberate retry without repair. Disposable flat/v7 trials walk consecutive bends from a fresh seeded road, edit a seam and restart planning/build; report actual evidence. |
| [D. Pure destination ranking and waypoint policy](https://github.com/tbook/luanti-roads/issues/49) | Junior (pure policy) | A; approved provider shapes | Implement bounded descriptor normalization, stable two-candidate ranking, forward cone, source/self exclusion, distant waypoints, 96/64 fallback targets and per-cycle rescan inputs. Test deterministic ties, both truncation states, absent/unhealthy providers, descriptor caps, destination switching and positive waypoint progress. No world writing or lifecycle rewrite. |
| [E. Destination attempt orchestration and reserved fallback](https://github.com/tbook/luanti-roads/issues/50) | Senior (shared budgets and runtime lifecycle) | B, C, D | Integrate providers and destination/fallback attempts into the service. Fake final-attachment providers initially; unsupported attachments reject explicitly. Test actual shared chunk union, per-attempt expansion exhaustion followed by fallback, reserved resources, zero-destination directional growth, all-blocked stopping, stale destination revisions and restart/cancel during each attempt. Commands expose scan/selection/fallback/limits and deliberate retry. No automatic scheduling yet. |
| [F. Completed-Towns provider and verified final attachment](https://github.com/tbook/luanti-roads/issues/51) | Senior (connector geometry and exclusion safety) | E | Use public v1 only; exactly 32 results means possibly truncated. Implement reverse landing/exit attachment, precise overlay exceptions, outward-store plus growth-claim checks at selection/preflight and persistent exit claims consumed by B's current-outward lookup. Test outward-first and incoming-first ordering, including incoming claims after restart. Also test flat/graded width-2/4 exits, incompatible headings/lattices, changed destinations, unadopted/uncertain outward origins, conservative legacy settlement reservations and no exclusion holes. World trials show distant steering, partial progress, actual walkable arrival, fallback and interrupted attachment inspection. Stop only after walking-path verification. |
| [G. Compatible existing-road endpoints and T junctions](https://github.com/tbook/luanti-roads/issues/52) | Senior (geometry/claims) | E; independent of F | Discover registered segments through bounded index; implement flat straight T and end-to-end attachments, offset lattices, exact preservation and overlapping join-interval claims. Test source loops/crossings, incompatible grades/bends, competing roads, both-endpoint stop versus T target continuation, storage/restart uncertainty and player edits. World trial walks all branches; command inspect/retry explains failure and interruption. Keep this slice linked and open if F ships first. |
| [H. Player proximity activation and shared bounded scheduling](https://github.com/tbook/luanti-roads/issues/53) | Junior (scoped scheduler using established service) | C, E, F, G; #38 engine evidence | Implement sampled 24/36 crossing, new-revision reset, safe arming eviction/rotation, finite shared queue, duplicate coalescing and fair admission. Keep automatic growth disabled until engine gates pass. Lua integration tests exercise the ordinary straight 64-node advance from the old forward inner edge without forced backtracking, stationary/multiple/excess players, leaving/returning, login/teleport, revisions, road-caused emergence, queue overflow/expiry, busy manual slot and restart without replay. World trials demonstrate several advancing segments, both arrivals, blocked stop, edited seam and interruption. Status explains waiting/blocked state. |

#41/#42 origin work need not wait for all destination features to be developed,
but must register identities/seams before writing roads intended for growth and
must not enable this automatic scheduler early. #43 plugs its verified completed
village provider into D/E's contract and owns its final-attachment tests. It does
not become a prerequisite for Towns/road-only growth.

## Review and evidence

Design basis: current `src/outward.lua`, `outward_store.lua`, `outward_policy.lua`,
`towns_adapter.lua`, `planner.lua`, `edges.lua`, `raster.lua`, `plans.lua`,
`connectors.lua`, `build.lua`; existing tests for those modules; and the local
producer's public `../towns/docs/roads_integration.md` (v1). The producer document
specifies completed-only queries, 32-result/32-exit caps and writer/exclusion
coordination. No private Towns state is proposed as an integration surface.

This design adds no implementation and records no new engine trial results.
The known #38 gaps and current evidence remain in `roads_outward.md` section 7.
Review must specifically check seam overlap at turns/grades, plan-version
isolation, destination overlay exceptions, durable dual-side claims, fallback
reservation and approach reset. Implementation tickets own the tests and engine
evidence above. Product defaults (radii, scan cone, supported initial
junction subset and finite world cap) are explicit here so review can change
them before implementation; none requires a speculative global planner.

## Slice B implementation notes (#47)

Implemented in `src/growth_store.lua` (registry, segment records, claims, index)
and `src/growth.lua` (seed hooks, adoption, one directional cycle, status,
cancel, retry, retire, inspect). Interpretations of the design above:

- Pending intent lives on each road record (`road.pending`), not in one
  registry-wide field, so several uncertain roads can coexist after a restart.
  Road states are `open|planning|building|stopped|uncertain|retired|connected`;
  `stopped` always means known zero writes and is the only retryable state.
- A seed is segment 1 of its road (`growth:v1:<op>:s1`); unadopted seeds count
  against the 128-road cap and all seeds/segments against the 1,024 cap. A seed
  whose outward operation provably wrote nothing is released; every other seed
  stays reserved. Recovery voids seeds only for operations that are
  `failed|cancelled|interrupted` with `writes=none`.
- Seed creation failure (derivation, 512-node patch cap, storage) does not fail
  the outward road: the operation records `growth.state=unseeded` with the
  reason and is simply not adoptable. A seed whose readback fails stays
  `intended` (`growth.state=unverified`). Legacy operations have no `growth`
  field and report `legacy_unadoptable`.
- `growth.hooks.claim(settlement_id, exit_id)` reads claim id
  `exit:<settlement_id>/<exit_id>`. The outward service checks it at admission,
  in `eligibility` (state `claimed`) and twice before building (after the
  composed plan and again after the durability wait). An unreadable or
  newer-schema registry makes the lookup fail closed (`growth_unavailable`).
- The builder's generic `build_failed` callback, `partial_build` and unknown
  codes keep the segment uncertain; only `stale_plan`, `seam_changed`,
  `towns_busy`, `towns_conflict` and `write_budget` prove zero writes. A refusal
  to start the builder is zero writes.
- `extend(road_id, actor, {claims=...})` accepts claims for destination slices;
  no command exposes them yet. This slice only plans the 96- then 64-node
  directional target; destination ranking and attachments belong to later slices.
- Obstacle masking uses stored raster geometry and fails closed on index
  disagreement (`road_index_corrupt`) or an incomplete query (`road_index_budget`).
  The exempt columns are only the authenticated start-seam surfaces.
- Not yet verified in an engine: storage durability ordering (#38), Towns
  integration through the real adapter, restart in a real world, and player
  traversal. `tools/growth_trial` states what its headless phases cover.

## Slice C implementation notes (#48)

Implemented as `/roads_grow` in `src/commands.lua`, registered only when the
growth service is passed to `commands.register` (`init.lua` does this). Every
action is server-privileged and maps one-to-one onto the service methods.
Interpretations of the design above:

- Arguments are checked before the service runs: an unknown or missing action,
  a wrong argument count, or a road id without the `growth:v1:` prefix returns
  `invalid_request` and writes nothing. Service errors keep their codes.
- `adopt` reports the road and its state. Repeating it is idempotent and says so;
  the service decides whether anything changes.
- `extend` and `retry` return the cycle id (`<road-id>:s<seq>:r<revision>`) and
  do not wait for the cycle. `status` shows the live stage while it runs.
- The status text carries the local and preferred headings, the endpoint and
  revision, the current or last segment, the attempts (latest four), the
  per-cycle limits, the stop reason (`Blocked:` when stopped), the explanation
  for uncertain or retired work, and a note that destinations are not scanned.
- The design lists a seam status in the summary. The service summary does not
  carry one, because checking it reads the world. Adopt, extend and retry report
  `seam_changed` when they check it, and `inspect` reports the comparison with
  the world. `status` only points to `inspect`. A senior may want the service to
  record the last seam verification durably.
- "Preview" is the textual current cycle or last segment. No particle preview was
  added.
- `inspect` shows at most four mismatched nodes and the segment states by count.

Tests: `tests/growth_command.lua` drives the registered definition over the real
growth and outward services (`tests/growth_fixture.lua`, extracted from
`tests/growth.lua` without changes to its assertions). The engine trial phase
in `tools/growth_trial/service.lua` uses the same command path. It is a two-launch
trial (see its README): three consecutive bends round obstacle walls, a seam-edit
refusal, then an interrupted fourth cycle and a second launch that checks the
restart conversion (`stopped` or `uncertain`) without rewriting the world.
`tests/growth_trial.lua` dry-runs that logic; the engine run itself is still a
manual step. The cancel message claims a released slot only when no build began.

## Slice E implementation notes (#50)

Implemented in `src/growth.lua` (cycle orchestration), with presentation in
`src/commands.lua` and tests in `tests/growth_destination.lua`. Interpretations:

- `growth.new` takes the pure `policy` module and optional `providers`
  (`town|village|road`, each `nearby(pos, radius, limit)`), `attachments`
  (by kind) and `destination_unavailable(descriptor)` (busy/uncertain approaches
  such as outward reservations; growth claims on `exit:<id>/<approach_id>` are
  always consulted). `init.lua` installs no provider yet (#51), so production
  cycles report `scan=disabled` and grow directionally.
- `extend` takes the destination snapshot after the job slot is held and before
  any survey or durable intent. An unhealthy installed provider fails the cycle
  closed (`provider_unhealthy`) without consuming the activation.
- Attempts: the retained candidates (at most two) in policy order, then the 96-
  and 64-node fallback targets, each a full survey/search/compose attempt. The first
  attempt that composes is the only one committed; a cycle builds at most one
  segment.
- Chunks: one union across attempts. A destination attempt that would raise the
  union above 64 is refused with `survey_budget` before survey; fallback may reach
  96 and reuses counted chunks.
- Expansions: a destination attempt gets `min(50,000, remaining - 50,000)`. Each
  fallback attempt gets `floor(remaining / fallback attempts left)`, so unused
  destination allowance passes to fallback and the last attempt takes the rest.
  An exhausted allowance fails only its attempt.
- Attachment provider contract (fake only; #51 builds on it). Every destination
  candidate, waypoint or final, requires `ops.attachments[kind]` with a callable
  `resolve(self, descriptor, {mode="final"|"waypoint", endpoint, preferred, road_id})`
  returning `{revision, recheck(self, descriptor) -> true | nil, err}` plus, for
  `mode="final"` only, `goal={x,z}`, optional `claims` and
  `verify(self, {plan, endpoint}) -> true | nil, err`; or `nil, {code, reason}`.
  All of this is checked before any survey. A missing resolver is
  `attachment_unsupported`, a result without a callable `recheck` (or, for final,
  `verify`) is `attachment_invalid`, a revision different from the snapshot is
  `stale_destination`; each rejection falls back with zero writes. Waypoints are
  therefore not trusted unchecked: they need a revision-checkable provider
  contract. `recheck` runs again after the durability wait (zero writes on
  failure). `connected` requires `verify` after construction; a failed
  verification leaves the road `uncertain` (`attachment_unverified`) and keeps
  the claims. Waypoint and directional results are `partial_progress` and
  `directional`. With no providers installed nothing is scanned (`scan
  disabled`) and behavior is unchanged.
- Accepted deviation: a claim conflict at reservation or a lost claim in the
  synchronous preflight stops the cycle with zero writes and does not fall back.
  Likewise an obstacle-collection failure (`store:collect`, e.g.
  `road_index_budget`) ends the cycle at once: the index is shared by every
  target, so fallback would hit the same failure.
- A blocked cycle's stop carries `attempted` (kind, length, approach, outcome per
  attempt) next to the last concrete error.
