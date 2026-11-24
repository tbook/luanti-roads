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

Destination steering and fallback use fake providers only (no Towns, no
attachment provider): cycle 1 sees a town 400 nodes ahead, so the cycle builds a
waypoint segment and reports `built (partial_progress)` (`GROWTH_TRIAL_STEERING`);
cycle 2 sees a town 160 nodes ahead whose final attachment the fake provider rejects as unsupported, so it
is rejected explicitly and the real 96-node fallback builds
(`GROWTH_TRIAL_FALLBACK`); cycle 3 has no provider (`scan disabled`). The three
trajectories are identical, so the rest of the trial is unchanged.

Phase 2 (`roads_trial_phase = 2`) restarts and checks the persisted registry:
planning interruption must read `stopped` (code `interrupted`, no pending
segment, endpoint node ahead untouched); build interruption must read
`uncertain` (pending segment, source claim and segment entry uncertain).
After 3 s nothing may have been surveyed or built. Planning mode then edits
the seam, requires `retry` to be refused with `seam_changed` (still stopped),
restores it, retries, and requires revision 5 at x 632 with a bending segment.
Build mode requires `extend` to be refused `not_extendable`, `retry`
`not_retryable`, and logs `inspect`.

Pass output: `GROWTH_TRIAL_BEND` x3, `GROWTH_TRIAL_SEAM_EDIT_REFUSED`,
`GROWTH_TRIAL_INTERRUPT`, `GROWTH_TRIAL_PHASE1_PASS`, then
`GROWTH_TRIAL_RESTART` and `GROWTH_TRIAL_PASS` (plus `GROWTH_TRIAL_RETRY` or
`GROWTH_TRIAL_UNCERTAIN_INSPECT`), and `Trial passed: both phases.` Any
`GROWTH_TRIAL_FAIL` or a nonzero exit is a failure; logs are kept in the world
directory. `--world DIR --phase 2` repeats the restart check on a kept world.

`tests/growth_trial.lua` dry-runs the same logic (layout, bends, seam-edit node,
interruption conversion) in pure Lua; it does not exercise the engine, mod
storage durability or shutdown timing.

Not verified: player traversal, restart after a hard crash, partial writes
inside one builder tick, or the real Towns API.
