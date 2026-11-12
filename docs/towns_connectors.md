# Proposed Towns approach connectors (#26)

Status: proposed design; no connector implementation exists yet. Preserve the
natural full-block planner and add a bounded connector at either selected end.
Do not classify stairs or slabs as ordinary replaceable terrain.

## Evidence and supported scope

The neighboring Towns mod's `src/town_roads.lua` defines `RAMP_MIN=4`,
`RAMP_MAX=16`, `DEPTH=32`, and outside widths of four nodes for principal roads
and two for secondary roads. `approach()` makes straight cardinal rows from:

- `mcl_core:cobble` full blocks;
- `mcl_stairs:slab_cobble` bottom slabs, with `param2=0`;
- `mcl_stairs:stair_cobble` upright straight stairs, with `param2=0..3`.

Its facedirs are +Z=0, +X=1, -Z=2, -X=3. Ascending stairs face the outward
direction; descending stairs face its opposite. Surface profiles use half-node
levels and the ramp finishes once its full-block level meets natural terrain.
The source explicitly avoids following a descending stair with an excessively
low slab. Supports may extend down to 32 nodes below town ground.

VoxeLibre's `mods/ITEMS/mcl_stairs/api.lua` defines an upright stair as a full
bottom half plus an upper half on local +Z. Bottom slabs end at node-center Y;
full blocks end at Y+0.5. Rotation and half-height boundaries therefore matter.
Check these definitions against the supported game during implementation.

Support only coherent, straight, Towns-compatible approaches selected by the
player standing on an allowed stair or slab. Leave ordinary natural endpoints
unchanged. Full-cobble-only selections retain existing natural-ground behavior;
there is no reliable way to infer a ramp direction from a flat cobble square.
No Towns dependency or access to its private runtime tables is needed.

Geometry cannot authenticate who built it. A geometrically compatible player
copy is indistinguishable from a generated ramp. Reject inconsistent geometry,
not unverifiable historical changes. Automatic discovery and a Towns integration
API remain future work.

## Bounded endpoint resolution

After the existing survey finishes, inspect raw endpoint nodes through injected
read-only access functions within that survey's bounds. Do not retain its entire
voxel volume or generate additional terrain for a connector.

Surveyed blocks may have been evicted before endpoint resolution. Immediately
before raw inspection, call bounded `core.load_area` for the already-generated
mapblocks covering each connector candidate window. Account for mapblock-rounded
volume under the existing read/allocation limit. This loads existing terrain;
it must not call `emerge_area` or generate missing blocks. Recheck every read:
nil, `ignore`, failed loads, or incomplete metadata/protection information remain
unknown and reject that candidate. Inject this loading operation for tests.

Inspect candidate straight strips in the four cardinal directions. Require a
consistent two- or four-wide profile, supported pieces, outdoor clearance, and
a unique usable continuation from the selection to natural ground. A selection
inside a ramp may preserve only the traversed suffix and its necessary supports;
it need not identify the town boundary. Reject ambiguity rather than guessing.
Determine maximal coherent transverse rows before enumerating widths: a verified
four-wide strip is one candidate, not several overlapping two-wide alternatives.
Deduplicate the same maximal strip reached through different selected lanes.
Use two-wide candidates only when they are genuinely maximal supported strips;
reject larger or irregular authored surfaces rather than slicing them arbitrarily.

Use at most 16 preserved rows from the selection, an eight-node transition to
the natural planning cap, width four, and support inspection depth 32. Also bound
the vertical window, candidate count, and total reads explicitly in code. Never
expand beyond the original survey or supported overworld bounds. Exhaustion is
a useful endpoint failure, not permission to search farther.

The connector has two parts: an unchanged ramp walking path, and a short paved
transition on natural terrain. Put the normal three-wide square planning cap
completely beyond preserved shaped nodes. The transition can narrow to two
nodes where a secondary ramp requires it, then meet the cap. Generate transition
operations with the existing natural-material, support, clearance, and protection
rules; do not add arbitrary stair writes. Reject a site whose seam needs them.

Choose the start natural landing first; it anchors the existing four-node
lattice. Resolve the goal connector to a natural landing on that same lattice.
Enumerate bounded candidates deterministically, validate the complete transition,
and report failure when none fit. Never choose a landing and subsequently snap
it away from the checked transition. Keep the existing 192-node limits for both
requested and resolved endpoint separation.

## Provenance and geometry contract

Keep original fractional player feet and the selected support separate from the
natural landing. Natural endpoints retain their existing version-one contract.
Connector endpoints explicitly extend it:

```lua
{ requested={x,y,z}, ground={x,y,z}, resolved={x,y,z},
  connector={version=1, direction={x,z}, width=2,
    path={ -- ordered physical walking samples, including half-node elevations
      {x=0,y=12.0,z=0}, ...
    },
    landing={x,y,z},
    preserved={ -- exact raw read-only expectations, including supports/clearance
      {x,y,z,name="mcl_stairs:stair_cobble",param2=0,
       has_metadata=false,protected=false}, ...
    },
    transition={surfaces=..., writes=..., expectations=...}
  }
}
```

Here `ground` is the selected support node, not necessarily a natural full block;
`resolved` and `landing` are identical natural planner points. Record fractional
walking elevations only in connector geometry; do not pass them into the A*
lattice. Endpoint resolution, planner input validation, and composer provenance
validation must agree on this alternative contract. Keep route search, raster
segments, and edge costs unchanged except for the connector constraints below.

The endpoint resolver also derives immutable search constraints from the checked
connectors: excluded read/write coordinates, selected landing-cap footprint, and
allowed departure/arrival headings. Every preserved surface, support, and clearance
coordinate is excluded from ordinary-road operations; a read-only support contact
is excluded too. Transition columns outside the chosen cap are reserved to the
connector. Only the explicit landing cap may overlap the normal road, and its
assigned surface heights and operations must match exactly.

Use the shared raster and feasibility operation footprint to reject candidate
edges whose surface, support, excavation, or clearance requirements intersect an
exclusion. Check the preceding-segment join as well. A centerline-only obstacle
test is insufficient. Apply the rule throughout search, not just at the first
and final edge: it must prevent later loops cutting back across an approach.
The check is geometric and does not reclassify cobble as an obstacle globally.

At the start, allow only headings whose complete departing footprint matches the
checked landing cap and clears its reserved connector. At the goal, require the
same condition for arriving edges; derive these separately instead of assuming
both ends use the same heading. Keep allowed alternatives in normal deterministic
search order. If a candidate landing has no feasible heading, try the remaining
bounded landing candidates before failing endpoint resolution. If its constrained
search later fails, report that bounded failure; the MVP need not retry whole
searches for other endpoint landings. Include these constraints in copied request
provenance so composition can independently enforce them. This lets A* consider
valid detours rather than finding a forbidden shortcut that only fails composition.

Derive each piece's walking surface from its allowed name and upright facedir,
including the player's position within the selected stair. Use half-cell samples
along the ramp so both stair halves are checked. Adjacent connector walking
surfaces and its terminal seam must have rises/drops no larger than half a node;
retain appropriate player headroom over the whole walking envelope. Do not claim
that the rest of the existing full-block road is stair-smooth. Reject top slabs,
upside-down stairs, corner stairs, transverse misorientation, missing rows, and
unsupported or obstructed profiles.

## Preservation, composition, and construction

Preserve every existing approach surface and support relied on by the walking
path, and record exact node names and `param2`. Record all clearance reads too.
Require metadata absence and unprotected status for the connector footprint;
unknown metadata or protection results fail. Never erase metadata or assume a
natural-looking support is replaceable merely because it is below a stair.

Composer unions the ordinary road and transition operations with the normal
conflict checks and shared write/allocation caps. It rejects any operation at a
preserved surface/support/clearance coordinate, even a nominal no-op; the natural
cap must not excavate underneath the preserved approach. Deduplicate compatible
expectations and reject incompatible ones. Check the entire connector-to-cap
seam, rather than reporting success for two disconnected components.

Plans using connectors must use top-level `version=2` plus `connector_version=1`.
The version bump makes the initial #12 version-one builder fail closed even if
it does not know connector fields exist. A connector-capable builder explicitly
supports ordinary version-one plans and version-two/connector-version-one plans,
and rejects every unsupported combination before writing. Do not change an
ordinary plan's version merely because its builder supports connectors.

A compatible builder rereads connector expectations with the same adapter during
preflight. Name, `param2`, metadata, protection, support, or headroom changes make
the plan stale before any writes. Load already generated data only, within the
same bounded construction rules. Preserve the existing natural-terrain semantic
checks alongside these exact connector checks.

## Presentation and failures

Preview the preserved walking segment and new transition in distinguishable
colors, joined to the main route. Status reports original selection, natural
landing, displacement, and preserved/transition lengths. Extend the current
centerline-only preview interface explicitly; hiding a displaced endpoint is not
a connection. Preview remains owner-only, temporary, and bounded.

Use `invalid_endpoint` with a concrete reason and position for ambiguous strips,
unsupported forms, unsafe seams, excessive length, missing support/headroom,
metadata, protection, unknown terrain, and lack of a lattice-compatible landing.
Construction uses `stale_plan` for changed expectations and a clear unsupported
connector-version failure before any writes.

## Implementation and tests

Use Terra for connector inspection, endpoint/provenance integration, composition,
and builder checks: oriented geometry and lattice seams cross existing contracts.
After that contract lands, preview/status presentation is a bounded Luna task.
Each implementation includes its own tests and documentation updates.

Required scenarios:

- Ascending/descending ramps in all four orientations, full blocks, bottom slabs,
  both widths, and selection partway along a stair.
- Select either middle lane of a four-wide approach: maximal-strip enumeration
  produces one candidate, not false ambiguity from its nested two-wide strips.
- Connector at start, goal, or both ends, with negative coordinates and goal
  lattice offsets; an invalid snap cannot silently disconnect the seam.
- A route whose cheapest unconstrained path crosses preserved cobble/support or
  connector clearance must take a valid alternative. Check start departures,
  reversed goal arrivals, wider diagonal footprints, joins, and a later loop
  through the approach. Explicit cap overlap succeeds only with matching heights
  and operations; an invalid heading or landing does not hide another allowed one.
- Evict connector mapblocks between survey and endpoint resolution; the injected
  bounded load restores existing data immediately before inspection. Unknown or
  `ignore` after load fails without generation, unbounded loading, or extra survey.
- Reversed/inverted/corner stairs, broken rows, floating supports, low ceilings,
  metadata, protection, unknown nodes, ambiguous paths, and bounded exhaustion.
- Composition proves preserved nodes/supports never enter writes and rejects
  transition/road conflicts, support excavation, and disconnected geometry.
- Build rejects changed name/facedir, removed support, new metadata/protection,
  blocked clearance, and unsupported connector versions with zero writes.
- A version-one-only builder rejects a version-two connector plan; the upgraded
  builder accepts ordinary version-one and supported version-two connector plans,
  rejecting missing/inconsistent/unknown connector-version combinations.
- A disposable world reproduces a real Towns ramp, verifies player traversal and
  preview, and compares raw approach/support nodes and metadata before/after build.
  Never perform construction trials in the user's world.
