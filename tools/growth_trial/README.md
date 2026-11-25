# Disposable growth trial

With VoxeLibre installed as `mineclone2`, run:

```sh
python3 tools/growth_trial/run.py --luanti /path/to/luanti
```

The runner creates a temporary world, copies the checked-out source modules into
a trial mod, and uses the real engine to build a source road and a continuation.
It derives the exact seam before the source write, checks it after both writes,
and verifies that editing a preserved node prevents another search. The temporary
world and output log are retained at the printed path. UDP port 30126 is used.

## Growth lifecycle phases (two launches of one world)

`run.py` launches the same disposable world twice. Between launches nothing is
rewritten; phase 2 only reads persisted state.

```sh
python3 tools/growth_trial/run.py --luanti /path/to/luanti [--mg-name singlenode|flat|v7] [--interrupt planning|build]
```

Phase 1 (`roads_trial_phase = 1`, fresh world) pre-fills x 160..680, z -40..40
with flat stone (ground y = 0) and four obstacle walls (`layout.lua`, one per
cycle, alternating sides). The real outward service, with scripted Towns and
survey, builds a fresh road recording a growth seed; `/roads_grow` then adopts it
(twice), extends three consecutive cycles (each must bend round its wall, reach
x 344, 440, 536, and inspect as `matches_intended`), edits the endpoint node of
the preserved seam (extension must be refused with `seam_changed`, the node stays
edited, no work starts, `inspect` says `mismatch`), restores it, and starts a
fourth cycle that is cut off:

- `--interrupt planning` (default): the survey never completes, the server shuts
  down while the cycle is planning (zero writes).
- `--interrupt build`: the real builder writes the segment, its completion is
  swallowed, and the server shuts down before the result is saved.

Destinations are the real `towns_destinations` provider and resolver over the real
`towns_adapter`, with a scripted `towns_api` (the Towns mod is not loaded) whose two
published settlements have their exits really built in the world with real
`mcl_core:cobble`, `mcl_stairs:stair_cobble` and `mcl_stairs:slab_cobble` nodes
(`layout.towns`): `steer` is a town 400 nodes ahead of the first seam with a graded,
four-wide, west-facing exit; `away` lies 160 nodes ahead of the second seam, 30 nodes
aside, with an exit that faces east, away from the road. Cycle 1 sees `steer` and
builds a waypoint segment (`built (partial_progress)`, no claim; `GROWTH_TRIAL_STEERING`);
cycle 2 sees only `away`, which is rejected `incompatible_heading` before any write, and
the real 96-node fallback builds (`GROWTH_TRIAL_FALLBACK`); cycle 3 sees no town. The
three trajectories are identical, so the walls and bends are unchanged. The fourth cycle
sees `steer` 112 nodes ahead: a final attachment to the graded exit, which is the cycle
that is cut off.

Phase 2 (`roads_trial_phase = 2`) restarts and checks the persisted registry:
planning interruption must read `stopped` (code `interrupted`, no pending
segment, endpoint node ahead untouched); build interruption must read
`uncertain` (pending segment, source claim and segment entry uncertain).
After 3 s nothing may have been surveyed or built. Planning mode then edits
the seam, requires `retry` to be refused with `seam_changed` (still stopped),
restores it, and retries: the retried cycle is the cut-off final attachment, so it
must end `connected` at the exit (revision 5, a heading facing into the town,
the full exit id claimed `held`, `inspect` matching the intended geometry), an
independent breadth-first walk over the real world's nodes from the seam endpoint
must reach every column of the built exit's first row (`GROWTH_TRIAL_ARRIVAL`), and
`outward:start` from that exit must be refused `already_reserved`. Build mode
requires `extend` to be refused `not_extendable`, `retry` `not_retryable`, the
exit claim to be `uncertain` after the restart, `inspect` to report the exact
exit and transition nodes as matching (`Attachment: checked N`), `outward:start`
to be refused from the persisted claim, the written geometry to be walkable, and the
road to stay unconnected (`GROWTH_TRIAL_ATTACHMENT_INSPECT`).

Pass output: `GROWTH_TRIAL_STEERING`, `GROWTH_TRIAL_FALLBACK`, `GROWTH_TRIAL_BEND` x3,
`GROWTH_TRIAL_SEAM_EDIT_REFUSED`, `GROWTH_TRIAL_INTERRUPT`, `GROWTH_TRIAL_PHASE1_PASS`, then
`GROWTH_TRIAL_RESTART` and `GROWTH_TRIAL_PASS` (plus `GROWTH_TRIAL_ARRIVAL` or
`GROWTH_TRIAL_ATTACHMENT_INSPECT`), and `Trial passed: both phases.` Any
`GROWTH_TRIAL_FAIL` or a nonzero exit is a failure; logs are kept in the world
directory. `--world DIR --phase 2` repeats the restart check on a kept world.

`tests/growth_trial.lua` dry-runs the same logic (layout, bends, seam-edit node,
interruption conversion) in pure Lua; it does not exercise the engine, mod
storage durability or shutdown timing.

Not verified: player traversal, restart after a hard crash, partial writes
inside one builder tick, or the real Towns API.
