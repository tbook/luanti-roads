# Epic: Generate one outward road from a completed Towns settlement

Status: tracked by [Roads epic #33](https://github.com/tbook/luanti-roads/issues/33).
The trigger is one explicit server command. This document does not enable generation.

## Implementation tickets

1. [Towns producer #458](https://github.com/tbook/luanti-towns/issues/458).
2. [Roads adapter and persistent jobs #34](https://github.com/tbook/luanti-roads/issues/34), dependent on Towns #458.
3. [Command, seeded targets and trials #35](https://github.com/tbook/luanti-roads/issues/35), dependent on Roads #34.

Living Villages integration is deferred to a separate future milestone.

## Outcome

In a disposable VoxeLibre world, generate one plain cobblestone road from a real,
completed Towns settlement toward a reproducibly chosen point in the surrounding
landscape. The system chooses the exit and destination; the player does not walk
to or select either endpoint. Inspect the resulting journey before investing in
road decoration or more sophisticated routing.

This is the first slice of roads growing outward through successive bounded
regions, eventually toward other settlements, including future settlements.
This ticket builds one segment and records its continuation information; it does
not implement successive extension or promise a future destination exists.

## Interaction

- Add a server-privileged `/roads_outward` command. Select the nearest eligible
  completed settlement within a bounded lookup radius (proposed: 512 nodes).
  Break ties deterministically and report the selected settlement.
- One invocation automatically selects, plans, validates, and builds at most one
  road. Command help explicitly says it can generate terrain and build a road.
  Do not require the existing manual endpoint/plan/build sequence.
- Use the existing status and cancellation facilities, with enough information
  to identify the settlement, exit, target, stage, and final result.
- Work belongs to a persistent settlement/road identity, independent of the
  invoking player's connection. Disconnect must not lose the outcome or make
  an already built road eligible for duplicate construction.
- Do not schedule background roads at startup or on settlement completion in
  this command-triggered version.

## Settlement integration prerequisite

Define a minimal, versioned Towns-to-Roads interface for completed settlements
and verified outward exits. Keep the Towns adapter optional; ordinary manual
Roads commands must still work without Towns.

The handoff needs stable settlement and exit identities, settlement exclusion
bounds, outward direction, and enough actual approach geometry/provenance to
resolve and validate a connected departure without a player standing there.
An exit omitted or unsuccessfully graded by Towns is not usable. Flat full-block
approaches must be supported when explicit direction/provenance is available;
the current player-selected stair/slab heuristic must not become a requirement
that excludes valid flat exits.

Only completed settlements qualify. Candidate sites, reserved/building sites,
interrupted builds, and unavailable or unsupported records do not. Revalidate
the actual approach before construction. Preserve authored settlement blocks,
supports, and clearance; allow only the explicitly checked connector seam.

Current Towns automatic records contain identity, center, envelope, and lifecycle
state, but not verified exits. Its internal `town_roads.exits()` describes planned
openings, not proof of a completed usable approach. Do not consume private tables,
read another mod's storage directly, regenerate a plan from a center, or infer
completion from nearby cobble as a substitute for the integration contract.

The corresponding Towns change is a prerequisite ticket in that repository;
this Roads ticket does not authorize modifying the neighboring mod. The first
supported population may be recorded, automatically generated Towns settlements.
Do not claim support for older/manual towns without an explicit published record.

## Exit and destination selection

- Choose one eligible unused exit in a stable order. This milestone permits at
  most one successfully built outward road per settlement.
- Generate a bounded, ordered set of target candidates using a local seeded
  generator derived from world seed, settlement ID, exit ID, and policy version.
  Never use or alter shared global random state. Persist the chosen inputs.
- Proposed target policy: horizontal distance 64–128 nodes from the outward
  planning landing, within 45 degrees of its outward direction. Respect the
  existing 192-node limits for both requested and resolved endpoints, including
  any connector displacement. Do not silently clamp or raise planner limits.
- Proposed maximum: four candidates per invocation. Resolve targets to usable
  outdoor natural ground, then validate their full road caps using existing
  rules. No fabricated player standing position is needed at either endpoint.
- Require the road to depart through its checked exit and remain outside the
  source settlement apart from the approved connector. Its target must also be
  outside that settlement; an outward target alone does not prevent a route
  looping back through town.
- Try candidates deterministically until one composes successfully or the
  candidate/work budget is exhausted. Finish planning before construction;
  never build fragments from unsuccessful attempts.
- Use existing surface routing and cobblestone construction. Water, deep drops,
  unknown terrain, and unsupported structures remain obstacles. A bounded
  failure is an acceptable result when no candidate can be reached.

## Bounded work and construction

Share the existing Roads global job slot with manual work. Reject a busy request
clearly rather than creating an unbounded queue. Use resumable survey/search,
cancellation, job identity checks, and the existing construction preflight.

Candidate retries must share a finite per-invocation budget, rather than each
receiving an unlimited fresh allowance. Keep total generated chunk coverage at
most 96 distinct mapchunks and total search expansions at most 150,000 across
attempts; retain existing allocation, retained-state, and slice limits. Reused
coverage may be counted once, but repeated search work still counts. Keep the
10,000-write and 50,000-inspected-expectation construction caps. Report actual
aggregate work and the precise limit reached.

Coordinate with Towns' terrain-writing lifecycle through the integration contract.
Road survey emergence can trigger settlement generation; emerge completion does
not establish that deferred settlement writes have finished. Exclude known
settlement footprints/reservations and avoid racing their writers. Do not solve
this by permanently disabling ordinary settlement generation.

## Persistent outcome and future continuation

Persist the operation identity and intended road before the first world write.
If this cannot be saved, do not build. Record source settlement/exit, policy
version and seed, chosen/resolved target, final centerline, terminal heading,
metrics, and outcome. Version the record so later extension can identify its
source, endpoint, and outward direction without rediscovering them from blocks.

Completed roads are not rebuilt by another invocation or restart. On restart,
mark unfinished work interrupted and do not automatically replay construction.
Partial writes remain explicitly partial/interrupted and require deliberate
recovery; they must not be treated as an unused exit. Retain bounded diagnostics
for zero-write failures; an explicit later retry may reuse the deterministic
policy, but there is no automatic retry loop.

Future candidate/committed/completed destination adapters should be possible
without changing the terrain planner. No speculative destination registry or
continuation algorithm is required in this ticket.

## Acceptance and validation

1. In a disposable world with an actual generated Towns settlement, one trigger
   selects an eligible exit and target and builds a connected, supported outward
   road without manual endpoint selection. Inspect it on foot and record the
   source, seed, endpoint, length, routing metrics, and work/timing measurements.
2. Verify a sloped stair/slab exit and a flat full-block exit. Confirm approach
   node names, orientations, supports, and relevant metadata are preserved.
3. Pure Lua 5.1 tests cover deterministic selection and ties, outward candidate
   bounds, settlement exclusion, aggregate retry budgets, no usable exit,
   inaccessible targets, busy jobs, cancellation, and optional Towns absence.
4. Integration tests reject candidate/building/interrupted settlements and
   changed or invalid approaches. A stale preflight performs zero road writes.
   Exercise deferred Towns work triggered by road emergence.
5. Repeat invocation and restart cannot duplicate a successful or partial road.
   Test storage failure before writing and interruption during construction.
6. Real-world trials include a successful journey and a blocked-terrain failure
   with a concrete reason. Existing manual command and connector tests pass.

## Scope and implementation ownership

Exclude Living Villages integration, roads to another settlement, automatic
network growth, successive extensions, bridges, tunnels, new road elevations,
decoration, and generalized recovery of partially written roads.

Before implementation, have an architect settle the small integration/lifecycle
contract, especially verified exits, writer coordination, and restart semantics.
Keep that contract separate from route search, rasterization, and construction.
Use a senior developer for the integration and persistent lifecycle work, with
an independent reviewer. Split routine command/status presentation into a junior
task if useful. Implement the Towns prerequisite separately before depending on
its published interface; do not turn this into a rewrite of either planner.

## References

- [Towns-compatible connectors](towns_connectors.md)
- [Connector engine trials](towns_connector_trials.md)
- [Planner contracts](planner_contract.md)
- [Original landscape/network intent](brainstorm.txt)
