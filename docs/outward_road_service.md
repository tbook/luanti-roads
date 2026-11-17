# Outward-road service and Towns adapter contract (#34)

Status: architecture contract for [Roads #34](https://github.com/tbook/luanti-roads/issues/34)
(epic #33). It settles the integration and lifecycle details. The `/roads_outward`
command, seeded targets, and real-world trials belong to #35, which uses this
service and does not add a second lifecycle.

Producer contract: `../towns/docs/roads_integration.md` (`towns_api`, version 1),
as implemented in `towns/src/towns_api.lua` (Towns #458/#459, merged).

## 1. Decisions at a glance

1. **Exits become ordinary version-1 connectors.** A new pure function,
   `connectors.exit_endpoints`, builds the same connector geometry
   (`direction`, `width`, `path`, `landing`, `preserved`, `transition`) from a
   published exit. It does not search from a player's position. The connector
   gets `origin="published_exit"`, which removes the need for a player selection.
   Plans stay `version=2, connector_version=1`, and the builder is unchanged
   apart from one guard hook.
2. **One survey per candidate.** Reuse the existing survey job for each
   candidate. The service counts distinct mapchunks across attempts using the
   pure `survey.plan` output. It passes the remaining expansion budget to
   `planner.new` as `max_expansions`. The survey, planner, and composer are not
   rewritten.
3. **Settlement and exit exclusions are added to the terrain snapshot.** A
   thin terrain wrapper reports any column inside a Towns exclusion rect, or
   under another published exit, as `{status="structure"}`. Search, connector
   transitions, and composition all see the same rule. This is required:
   `mcl_core:cobble` is classified as *natural*, so without the wrapper a route
   could pave or cut through town streets and walls.
4. **The outward service shares the global slot.** It lives in its own module
   (`src/outward.lua`). It takes the existing `jobs` slot through a small
   `hold/release` API, so manual and outward work exclude each other. The
   requester's connection does not affect outward work.
5. **Persist the intended road, wait one save interval, then build.** The
   intended road is saved with `state="building"` and read back. The service
   then waits until Luanti has committed mod storage to disk, and only then
   starts construction. A restart turns `building` into an `interrupted` state
   with unknown writes, which reserves that exit. Construction is never
   replayed.

## 2. Towns adapter (`src/towns_adapter.lua`, pure)

`adapter.new(get_api)`: `get_api()` returns `rawget(_G,"towns_api")` in the
engine and a fake in tests. Every call into the API is wrapped in `pcall`, and
its result is validated before use. Nothing from Towns storage or internals is
read.

- **Availability.** If the API is absent, return `towns_unavailable`. If
  `api.version ~= 1` (missing, malformed, or newer), return
  `towns_unsupported`. If `api.available()` returns false, return
  `towns_unavailable` with the reason given. Add `optional_depends = towns` to
  `mod.conf` so `towns_api` exists before Roads `init.lua` runs. Manual commands
  never touch the adapter.
- **`adapter.settlement(id)`.** Calls `api.settlement(id)` and maps each Towns
  failure status to `{code="ineligible_settlement", status=<towns status>}`
  (`not_found`, `incomplete`, `unsupported`, `invalid`, `unavailable`). Only
  complete published records are accepted. The adapter checks the shape it
  depends on: integer `center`, `reservation`, `core`, `structures`, and
  `exits`.
- **`adapter.exit(settlement, exit_id)`.** Requires exactly one exit with that
  `id`. It is normalized into an *exit descriptor*, or rejected with
  `unsupported_exit` and a reason:
  - `direction` must be a cardinal unit vector, and `length` must be 1..16 with
    `#profile == length`.
  - Columns must be contiguous along `lateral = {x=-d.z, z=d.x}`, and the width
    must be **2 or 4**. Widths 1 and 3 are rejected because the connector
    contract supports only 2 and 4.
  - Profile vocabulary is limited to `mcl_core:cobble` with p2 0,
    `mcl_stairs:slab_cobble` with p2 0, and `mcl_stairs:stair_cobble` with p2
    either the outward facedir or its opposite. The facedirs are +Z=0, +X=1,
    -Z=2, -X=3, the same as `connectors.lua`.
  - The anchor is the step-0 node of `columns[1]`. Lateral offsets
    `{min,max}` are relative to the anchor.
  - The descriptor carries `{settlement_id, exit_id, source, direction, anchor,
    offsets, length, profile, api_version=1}`.

  Flat exits (all full cobble, one y) and graded exits are handled the same
  way. The direction comes from the published record, not from any player
  heuristic.
- **`adapter.writer()`.** Returns `nil` or `{kind, phase, since}`. A
  `pcall` error is treated as busy.
- **`adapter:overlay(rect, source_settlement, selected_exit_id)`.** Returns the exclusion rects
  for a survey rect, or an error:
  - `api.exclusions(rect)`: every item of any kind or state contributes its
    rects. `too_many` and `unavailable` are errors (`towns_unavailable`) and are
    never read as "no towns".
  - Footprints of **all other published exits** of the source settlement:
    columns × steps 0..L-1, plus the seam step L.
  - Exit footprints of other published settlements from
    `api.settlements(rect_center, min(1024, half_diagonal + 256))`.

  The selected exit's own steps 0..L-1 are not added, because they are
  already protected by the connector's `preserved` constraints. Its seam and
  transition columns must stay outside every rect.
- **`adapter:new_guard()`, the build-time check.** It returns a function
  `guard(plan)` with its own 180 s deferral clock, returning `"ok"`, `"defer"`,
  or `"fail", err`.
  - If `writer() ~= nil`, or a `candidate` exclusion overlaps the bounding
    rect of `plan.writes`, the result is *defer*. After 180 s of continuous
    deferral it becomes *fail* with `towns_busy`.
  - If a write position lies inside any other exclusion rect and within its
    `y_min..y_max`, the result is *fail* with `towns_conflict`.
  - If the exclusions cannot be read, the result is *fail* with
    `towns_unavailable`.
  - Otherwise the result is *ok*.
- **`adapter.wrap_terrain(terrain, rects)`** is the terrain overlay wrapper
  described in section 1. It uses a bucketed rectangle index so per-column
  lookups stay cheap during search.
- **`adapter.recheck(descriptor)`.** Immediately before committing, fetch the
  settlement again and require the same exit with an identical
  columns/length/profile. Otherwise fail with `stale_exit`. Published records
  are immutable by contract, so this is cheap protection against a
  wrong-version or downgraded Towns.

### Mapping an exit to connector geometry (`connectors.exit_endpoints`)

`connectors.exit_endpoints(terrain, descriptor, target, access, load, surface,
edges)` returns provenance `{start, goal}` or an `invalid_endpoint` error. It
reuses the existing `reader` (bounded `load_area`, metadata, protection, and
`ignore` handling). It also reuses the per-node checks from
`inspect_direction`: support down to natural ground within 32 nodes, 3 air
nodes of headroom, daylight, no metadata, and no protection. Factor those
checks into a helper rather than duplicating them. It also reuses
`transition`, `landing_options`, the goal lattice snap (current lines 284-290),
and the heading-feasibility loop. Factor the matching tail of
`connectors.endpoints` into a shared local function.

- **Revalidation.** For every column and step n in 0..L-1, read the node at
  `(c + d*n, profile[n+1].y)`. It must match the published `name` and `param2`
  exactly. That node and the row must also pass the support, headroom,
  daylight, metadata, and protection checks. Walking heights come from the
  existing `surface_height`. Adjacent walking heights may differ by at most 0.5.
  The lateral "irregular or wider row" probe is **not** applied: the published
  record is explicit provenance, and neighbouring town cobble is handled by the
  overlay. The result is `c = {direction, width, path, preserved, rows=L,
  last_height, selection=anchor node, min, max, lateral}`.
- **Start endpoint.**
  - `ground = anchor`.
  - `requested = {x=anchor.x, y=<outward-half walking height of row 0>,
    z=anchor.z}`. This is a walking-surface sample from the published geometry,
    not a player position. It satisfies the existing planner and composer
    `requested`/`ground` consistency rules.
  - `resolved = landing`, chosen by the unchanged landing and transition
    enumeration. It is anchored first, as in #26.
  - The connector is `{version=1, origin="published_exit", exit={api_version,
    settlement_id, exit_id, source}, offsets={min,max}, direction, width, path,
    landing, preserved, transition}`.
- **Goal endpoint.**
  - Round `target.x` and `target.z` to a column. The column must be `ok`, and
    must pass `surface.ground(terrain, {x, y=ground_y+0.5, z})`; this rejects
    standing on leaves. Set `requested = {target.x, ground_y+0.5, target.z}`;
    it is derived from inspected ground, and no player is involved.
  - Snap to the landing lattice with the existing rules: at most 3 nodes
    horizontally and at most 2 nodes of height difference.
  - `planner.new` still checks the full goal cap (`check_goal_cap`).
  - If the snapped goal lies inside the source settlement's whole
    `reservation` rect, fail with `invalid_endpoint`, "target inside source
    settlement".
- **Limits.** The existing 192-node checks apply to requested points (row-0
  sample to target) and to resolved points (landing to snapped goal). Over-limit
  candidates are rejected and never clamped.
- **`edges.validate_preserved`.** Add one branch for
  `connector.origin=="published_exit"`:
  - Skip the "selected node must be stair/slab" rule and the ±5 neighbour
    width probe. Use `connector.offsets` instead, and require
    `offsets.max - offsets.min + 1 == width`.
  - Keep every other check: rows, path samples, clearance, supports, seam
    coverage, and connectivity.

  A missing `origin` keeps today's player-selection behaviour unchanged.
  `connector_constraints` (preserved and reserved sets, caps, headings), the
  composer, and the builder's exact rereads apply as they do now.
- **Survey start point.** Survey from `requested` (the step-0 anchor, at the
  profile's first y) to `{target.x, profile[L].y, target.z}`. The y of an
  unresolved target is estimated at seam level. The anchor-based start keeps
  the whole ramp, its 16-aligned reader blocks, and the landing (at most L+8
  ≤ 24 nodes away) inside the 32-node survey margin. The vertical window is
  ≤105 nodes. Targets outside it are reported `unknown` or `invalid_endpoint`,
  which is acceptable because 128 nodes at a grade of 1/4 rises only 32.

## 3. Service entry point (`src/outward.lua`, pure; deps injected)

```lua
local service = outward.new{
  jobs=controller, towns=adapter, store=outward_store_instance,
  now=..., after=..., notify=function(name, summary) end,   -- notify is best effort
  world_config=..., survey=survey,                           -- survey.plan for counting chunks
  start_survey=..., exit_endpoints=..., new_planner=..., compose=..., start_build=...,
  save_interval=function() return 5.3 end,                   -- server_map_save_interval
}
service:start{settlement_id=..., exit_id=..., requester="name",
  policy={version=..., seed=..., ...},     -- opaque to the service; persisted verbatim (#35 owns it)
  candidates={{x=..,z=..}, ...}}           -- 1..4 integer targets in the caller's order; no duplicates
  -> {op_id=..., state="planning"} | nil, err
service:status(settlement_id?) -> summary | nil   -- the active operation, or the latest record for that settlement
service:cancel(actor)          -> true | nil, err
service:eligibility(settlement_id, exit_id?) -> "open"|"active"|"reserved"|"unreadable", detail
service:recover()              -- startup sweep; init.lua calls it once
```

Errors use the existing `{code, reason, position?, limit?, observed?}` shape.
New codes: `towns_unavailable`, `towns_unsupported`, `ineligible_settlement`,
`unsupported_exit`, `stale_exit`, `already_reserved`, `towns_busy`,
`towns_conflict`, `storage_failed`, `invalid_request`. The codes `busy`,
`cancelled`, `survey_budget`, `expansion_budget`, `bounded_no_route`,
`invalid_endpoint`, `composition_failed`, `stale_plan`, and `partial_build` keep
their existing meanings.

**`start` order (synchronous):**

1. Validate the request.
2. `towns.settlement` and `towns.exit`.
3. `store:eligibility(settlement_id, exit_id)` must be `open`. Otherwise
   return `already_reserved` with the reservation scope (`settlement` or
   `exit`).
4. `jobs:hold(holder)`; if the slot is taken, return `busy` with no queue.
5. Save the `planning` record. If the save fails, release the slot and return
   `storage_failed`.
6. Schedule the first attempt.

**Per-candidate attempt (stages reported in `status.stage`):**

1. **Budget check.**
   - `survey.plan(start, goal_est, world)` gives the chunk keys
     `ix:iy:iz`. Merge them with the operation's spent set. If the union is
     over 96, record the attempt as `survey_budget` (aggregate) and **continue**
     to the next candidate; a nearer target can reuse coverage.
   - If the expansion budget remaining is 0, stop with `expansion_budget`
     (aggregate).
2. `surveying`: `start_survey(start, goal_est, "roads:outward", world)`, polled
   every 100 ms as `jobs.lua` does.
3. `waiting_towns`: poll `towns.writer()` every 1 s until it returns `nil`,
   with a 180 s limit; on timeout the attempt fails `towns_busy`. Then call
   `towns.overlay(survey_rect)` and wrap the terrain.
4. `resolving`: `exit_endpoints(wrapped, descriptor, candidate, ...)`.
5. `searching`: `new_planner(wrapped, request, {weights, road_material,
   max_expansions=remaining})`. Slices stay at 1000 expansions and 5 ms, run via
   `after(0)`. Add the attempt's `metrics.expansions` to the spent total
   whatever the outcome. If an attempt hits `expansion_budget` while the cap was
   below 150,000, report the *aggregate* limit and stop.
6. `composing`: `compose(wrapped, route, {road_material})`. The first success
   ends the candidate loop.

Failed attempts release their terrain, search, and route before the next one
begins. Only the composed plan of the successful candidate is kept, so
fragments from failed attempts are never built.

**Commit and build:**

1. Call `towns.recheck`.
2. Save the `building` record containing the intended road (section 5), then
   read it back. If either step fails, the operation fails with
   `storage_failed`, writes=none.
3. `durability_wait`: wait `min(save_interval, 60) + 1` seconds. If the
   setting is above 60, refuse to build (`storage_failed`, "save interval too
   long").
4. `start_build(plan, done)` with `ops.guard = towns.guard`.

**Identity and late callbacks.** Every scheduled callback captures `(op,
token)` and does nothing unless `service.active == op and op.token == token`.
Terminal transitions increment the token and cancel the survey, search, or
builder exactly as `jobs.lua` `cancel_work` does. The survey job already
ignores late emerge callbacks.

**Shared slot (`src/jobs.lua`, small change):**

- `jobs:hold(holder)` returns a token, or `nil, busy` if `self.active` is set.
  `jobs:release(token)` frees the slot. The holder is `{external=true,
  kind="outward", cancel(actor), status()}`.
- The existing `plan`, `build`, and `preview_route` already return busy or
  `not_owner` while `self.active` is set; check each against an external
  holder.
- `jobs:cancel(owner)` delegates to `holder.cancel(owner)`. `jobs:status(owner)`
  adds `slot={kind="outward", op_id, stage}` so #35 can present it.
- `jobs:disconnect` must **skip** external holders.
- A manual "ready" plan keeps the slot as it does today, so an outward request
  during that time gets `busy`.

**Authorization.** The service does not check privileges. #35's commands
require `server`, as all Roads commands do. Work is owned by the operation
identity. The requester is stored for audit and best-effort notification only.
Any caller that reaches `cancel` or `status` (that is, any player with `server`)
may cancel the active outward operation or read its status. Cancellation
records `cancelled_by`. Disconnecting has no effect.

**Protection owner.** Surveys and plans use the owner `"roads:outward"`. The
colon means it cannot be a player name, so protection mods treat every
protected node as protected. Outward roads therefore never cross protected
land, whoever requested them.

## 4. Aggregate budgets

| Limit | Scope | Mechanism |
| --- | --- | --- |
| 96 distinct mapchunks | operation | union of `survey.plan(...).chunks` keys, counted before each emerge; failed or partial surveys still count |
| 150,000 expansions | operation | `max_expansions = 150000 - spent`, using the existing `planner.new` config cap (`planner.lua` lines 78-83); repeated work counts |
| 250,000 states / heap entries, survey 2M-voxel allocations, 60 s survey inactivity, 1000/5 ms slices | per attempt | unchanged |
| 4 candidates | operation | request validation |
| 10,000 writes / 50,000 expectations | the single build | unchanged composer and builder caps |
| Towns writer wait | 180 s per wait | service (planning) and builder guard (build) |

The operation's `aggregate` metrics report:

- distinct chunks and total chunk requests;
- total expansions;
- per-attempt peak states and heap entries;
- total survey and search seconds;
- the longest search slice;
- `limit_reached`: `"chunks" | "expansions" | nil`, with `limit` and
  `observed`.

The final error is the deciding attempt's precise error. When every candidate
was skipped or stopped by budget, the error is the aggregate budget error.

## 5. Persistent operation record (`src/outward_store.lua`, pure)

**Storage.** Use Luanti mod storage, through an injected `{get, set, keys}`
adapter and a `serialize`/`deserialize` codec, one key per settlement:
`outward/v1/settlement/<settlement_id>`. Startup enumerates entries with
`StorageRef:get_keys()`, filtered by prefix. Docs are capped at 64 KiB once
serialized; a larger doc is a `storage_failed` save.

```lua
{ schema=1, settlement_id="auto:3:-2", next_seq=3,
  operations={  -- oldest first; every reserving op plus the 4 newest non-reserving ops
    { op_id="auto:3:-2/+x:120:-40#2", seq=2, exit_id="+x:120:-40",
      state="planning"|"failed"|"cancelled"|"building"|"built"|"partial"|"interrupted",
      writes="none"|"unknown"|"some"|"all",
      requester="name", cancelled_by=nil, created_at=os_time, updated_at=os_time,
      source={api_version=1, settlement_id, exit_id, exit_source, direction, columns, length,
              profile, center, town_type},          -- copy of the published exit used
      policy={...}, candidates={{x,z},...},
      attempts={{index, target={x,z}, outcome="composed"|<code>, reason, position,
                 chunks_new, expansions, survey_seconds, search_seconds}},  -- at most 4
      aggregate={...},                               -- section 4
      road={plan_version=2, connector_version=1, chosen_index, requested_target={x,z},
            resolved_target={x,y,z}, landing={x,y,z}, centerline={...}, headings={...},
            terminal={x,y,z}, terminal_heading=h, outward={x,z},
            metrics={length, ascent, descent, max_grade, turns, cuts, fills},
            write_count, expectation_count, footprint={x1,z1,x2,z2}},
      build={writes, pause_seconds}, error={code, reason, position, limit, observed} } } }
```

Write lists and expectations are **not** persisted, because they can be up to
10k and 50k entries. The centerline, endpoints, terminal heading and outward
direction, footprint rect, and counts are the continuation information. A doc
with an unknown or higher `schema` that does not deserialize is `unreadable`.
It is never overwritten and is treated as reserved.

**State machine** (persisted states; `uncertain` exists only in memory):

```
start ──save──> planning ──> failed | cancelled                  (writes=none; settlement stays open)
                    │
                    └─ composed ──save+readback──> building ──wait──> builder
                         (save fails: failed/storage_failed, writes=none)
builder: ok              -> built   (writes=all)   reserves the whole settlement
         partial_build   -> partial (writes=some)  reserves its exit only
         unknown error code -> partial (writes=unknown) reserves its exit only
         zero-write error (stale_plan, towns_busy, towns_conflict, build_failed
           before writes, cancel during load or wait)
                         -> failed | cancelled (writes=none); the exit opens again
restart: planning -> interrupted (writes=none; open, retryable)
         building -> interrupted (writes=unknown; reserves its exit)
save failure after writes may have happened -> the in-memory state (built/partial) still
         reserves, and the disk still says building, so the restart sweep makes it
         interrupted/unknown (reserves the exit)
```

- **Ordering.**
  1. Save `building` with the full `road`, and read it back.
  2. Wait for the durability interval.
  3. The builder loads blocks, runs the guard, runs the preflight, then writes
     everything in one synchronous batch.

  I verified in Luanti `src/server.cpp` (master) that mod storage is committed
  (`endSave`/`beginSave`) every `server_map_save_interval` seconds, default
  5.3, and at shutdown. `set_string` alone is therefore not durable. The wait
  makes sure the record reaches disk before the first map write. After a hard
  crash the outcome can only be conservative: the road blocks are lost while
  the record says `building`, which is then reserved.
- **Eligibility (per exit, decided by the product owner).** A partial or
  uncertain road blocks **only its own exit**; the settlement and its other
  exits stay eligible and other roads continue. Reservations are:
  - `built` reserves the **whole settlement** (at most one successful outward
    road per settlement in this milestone);
  - `partial`, `building`, or `interrupted` with writes other than `none`
    (including unknown-outcome builder failures and the in-memory result of a
    save failure after construction) reserve **their exit**;
  - an unreadable or unsupported-schema document reserves the whole
    settlement, because its exits cannot be known;
  - `active` means the operation holds the slot; otherwise the answer is
    `open`.
  A `built` operation whose final save failed is reserved in memory, but
  after a restart the disk says `building`, so it is reserved as
  `interrupted`/unknown for its **exit only**. The one-road-per-settlement
  rule is therefore guaranteed for built roads that were durably recorded and
  best-effort otherwise.
  Zero-write failures never block anything. Only one operation runs at a time
  because of the global slot.
- **Retry.** A new explicit `start` creates a new `seq`/`op_id`. The service
  never loops or retries automatically. With the same policy and terrain it will
  probably fail the same way, and that is accepted.
- **Retention.** Keep every reserving operation (at most one per exit, plus
  the built one) and the 4 newest non-reserving operations per settlement,
  evicting the oldest non-reserving operation first. If a document still
  exceeds 64 KiB, older non-reserving operations are shed and then the save
  fails closed with `storage_failed`. Docs are created only for requested, published settlements.
- **Restart.** `recover()` runs once from `init.lua`. Its sweep saves the
  conversions. If such a save fails, log an error, keep the in-memory
  conversion (still reserving where applicable), and the next start repeats
  the sweep. No automatic build is ever replayed. Recovering a reserved
  operation is out of scope (see Q1). Documents loaded from disk are
  converted lazily on first access as well, so a conversion whose save failed
  is repeated on the next start for that settlement.

## 6. Writer coordination (Towns contract G1-G4)

- **Planning.** After each survey succeeds, poll `writer()` with `after(1)`,
  limited to 180 s, until it is `nil`. Then query `exclusions` once for the
  survey rect and wrap the terrain. G3 means any job or candidate caused by our
  emergence is already visible. G1 means Towns writes only inside candidate or
  settlement rects, and those rects are excluded. A failed attempt does not
  stop Towns.
- **Build.** Add an optional `ops.guard()` to `build.lua`, called at the start
  of `final()`, before the preflight, in the same synchronous callback as the
  writes:
  - *ok*: proceed.
  - *defer*: reset `index=1` and reschedule `tick` after 1 s. This reloads the
    blocks, because the delay may have evicted them.
  - *fail*: zero writes.

  The guard owns the 180 s deferral limit and returns `towns_busy` when it is
  reached. Without `ops.guard`, the builder behaves exactly as today, so the
  manual path is unchanged.
- **No deadlock.** Roads never holds anything Towns waits on (G4), and Roads
  always waits by yielding with `after`. Every wait is bounded. Ordinary
  settlement generation is never disabled.

## 7. Files and sequencing

The work can land as one PR built from these commits. Each commit keeps
`lua5.1 tests/run.lua` passing.

1. `connectors.exit_endpoints` and the `edges.validate_preserved`
   `published_exit` branch, with tests. Manual connector tests stay unchanged.
2. `build.lua` `ops.guard` and the `jobs.lua` `hold`/`release`, delegation,
   and disconnect skip, with tests.
3. `src/towns_adapter.lua` (validation, overlay, guard, recheck) and a terrain
   overlay wrapper, with tests.
4. `src/outward_store.lua`, with tests.
5. `src/outward.lua`, wiring in `init.lua` (mod storage, the
   `server_map_save_interval` setting, `optional_depends = towns`, a call to
   `recover()`, and exposing the service as `roads.outward` for trials and
   #35), and documentation updates. Point `towns_connectors.md` and
   `engineering_design.md` to this document.

## 8. Test plan (pure Lua 5.1)

Fakes:

- **Towns.** `version` and `available` switches; settlements in each status;
  `exclusions` that can change over time; a writer lock. An emerge hook can,
  synchronously as G3 requires, set `writer()` and add a candidate exclusion,
  then later clear the writer and publish a settlement whose rects cover part
  of the survey.
- **Store.** Injectable `set` errors, read-back mismatch, oversize docs, and
  corrupt or unknown-schema docs.
- **Clock and queue.** A manual `after` queue.
- **Pipeline.** Fake survey, planner, compose, and builder ops, in the style of
  `tests/jobs.lua`.

Cases:

- **Adapter.**
  - API absent; version 2; `available()` false.
  - Each `settlement()` status.
  - Missing, duplicate, or width-1/3 exit; bad vocabulary or orientation.
  - Flat and graded exits in all four directions, at negative coordinates.
- **Connectors.**
  - Flat full-block and stair/slab exits at widths 2 and 4.
  - A changed name or param2, missing support, or blocked headroom is
    rejected.
  - Lateral neighbour cobble is accepted for a published exit and still
    rejected for a player selection.
  - Seam inside an overlay rect causes the endpoint to fail.
  - Composition never writes preserved nodes.
  - The builder rejects a changed exit with zero writes.
- **Exclusion.** A cheapest route through town cobble or another exit detours.
  A target inside the reservation is rejected.
- **Budgets.**
  - A second candidate reuses chunks and they are counted once.
  - A candidate that would exceed 96 chunks is skipped and the next one is
    tried.
  - Expansions are cumulative and the aggregate `expansion_budget` stops the
    loop.
  - Four failures give a precise final error, and no failed attempt is ever
    built.
- **Lifecycle.**
  - `busy` against a manual job and against a ready manual plan.
  - Manual `plan` is busy while an outward operation holds the slot.
  - Disconnect does not cancel.
  - Cancel in every stage; late survey, search, writer-poll, and builder
    callbacks after cancel or terminal do nothing.
- **Writer coordination.**
  - Emergence-triggered candidate: the service waits, then the overlay
    excludes the new settlement.
  - A settlement that appears before the build gives `towns_conflict` with zero
    writes.
  - A writer busy for more than 180 s gives `towns_busy` with zero writes; the
    Towns fake keeps progressing throughout.
- **Persistence.**
  - Save failure at accept leads to no work.
  - Save failure at commit leads to zero writes.
  - Save failure after a full or partial build makes the operation uncertain,
    and after a restart it is reserved.
  - A restart from planning, building, built, partial, and failed (each
    simulated by a fresh service over the same store plus `recover()`) gives the
    expected eligibility.
  - A repeated request after built (any exit), or after partial or
    interrupted-unknown (that exit only) is rejected with `already_reserved`;
    after a zero-write failure it is allowed.
  - Retention evicts the oldest zero-write operation.
- **Regression.** Existing manual, planner, builder, and connector suites pass.

## 9. Assumptions, risks, and what is unverified

- **Verified from source:**
  - the Towns API shapes and statuses (`towns/src/towns_api.lua`,
    `town_exits.lua`);
  - Roads' connector, planner, composer, and builder contracts;
  - `planner.new` accepting `max_expansions` up to 150,000;
  - Luanti committing mod storage on `server_map_save_interval`, and
    `get_keys()` being part of the API (both checked on master, not on the
    installed 5.18 build).
- **Unverified, to settle in #35 trials:**
  - Whether Towns' published `structures` rects cover the ramp's seam or
    landing area. If they do, every such exit fails at endpoint resolution with
    a clear reason, and a Towns follow-up would be needed.
  - Whether gatehouse and postern approaches pass the 3-air headroom and
    daylight checks at step 0.
  - How long four sequential surveys take in a real world.
- **Runner-up for surveys: one union survey for all candidates.** This would
  inject a precomputed plan into the survey job's `preflight` parameter, so the
  survey job itself would not change. It would win if the trials show that
  sequential per-candidate surveys are too slow. The costs are that it surveys
  candidates that are never tried, and that arbitrary caller candidates can
  exceed 96 chunks.
- **Runner-up for the slot: extract a shared pipeline module.** Pulling a
  survey→search→compose runner out of `jobs.lua` for both flows would remove
  roughly 80 lines of mirrored polling. It would win if a third job type
  appears. It is deferred because it touches every manual lifecycle test.

## 10. Product decisions

- **Q1 (accepted).** A `partial`, `interrupted`/unknown, or unreadable record
  blocks permanently, and #34 provides no in-game release. An explicit,
  audited admin release is a later ticket.
- **Q2 (changed by the product owner).** A partial or uncertain road blocks
  only its own **exit**, not the settlement. The other exits stay eligible and
  other roads continue. The one successful (`built`) road per settlement rule
  remains.

Resolved here with defaults, no input needed:

- Any `server`-privileged player may view or cancel any outward operation.
- Outward work survives the requester disconnecting.
- Targets must be outside the source's whole reservation, although the road may
  cross the unbuilt outskirts belt.
- Outward roads use the conservative protection owner `roads:outward`.
- Planning interrupted by a restart is retryable.
- The durability wait adds about 6 s before construction.

**Cross-cutting observation, outside #34's scope.** Manual `/roads_plan`
classifies Towns cobble as natural ground and ignores Towns exclusions, so a
manual road can still cut through a town. Consider applying the same overlay to
manual planning when Towns is present.

## 11. Implementation notes (#34)

Implemented in the order of section 7 (`src/connectors.lua` and `src/edges.lua`;
`src/build.lua` and `src/jobs.lua`; `src/towns_adapter.lua`;
`src/outward_store.lua`; `src/outward.lua` plus `init.lua`). Differences from
the text above:

- The adapter is an object: `adapter.new(get_api, now)` with methods
  `settlement`, `exit`, `writer`, `overlay`, `new_guard`, `recheck`, and the
  plain function `adapter.wrap_terrain`. The exit descriptor also carries
  `columns`, `center`, `town_type`, and `reservation = {x1,z1,x2,z2}`.
  `connectors.exit_endpoints` uses `reservation` to reject targets and snapped
  goals inside the source settlement.
- The anchor is `columns[1]` and offsets are computed relative to it, so
  west and north exits may have negative offsets.
- `build.lua` `ops.guard(plan)` returns `"ok"`, `"defer"` or `"fail", err`. A
  guard error counts as a zero-write `build_failed`. `ops.start_build` takes
  the guard as its third argument.
- The store keeps one in-memory document per settlement; operations are
  edited in place and saved with `store:save`, which reads the text back.
  The service stores `settlement_id` inside each operation as well.
- `outward.new` also takes `wrap_terrain` and an optional `log`. `status`
  returns plain data (stage, attempts, aggregate, road summary, `persisted`);
  user-facing status text belongs to #35.
- `init.lua` exposes the service as the global `roads.outward`.
- Not verified here: real Luanti behaviour (mod storage commit timing,
  `get_keys`, emerge). Trials belong to #35.
