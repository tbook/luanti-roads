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

A second phase (`service.lua`) exercises the slice-B lifecycle against the same
engine: the real outward service (scripted Towns and survey over a pre-filled
stone area at x 160..380) builds a fresh road with a growth seed recorded before
writing and verified by readback, the seed is adopted, and one continuation
cycle is built, published and inspected. Mod storage, node reads, metadata,
protection, timers, `load_area` and `swap_node` are the engine's.

This headless check does not verify player traversal, generated terrain,
restart/partial-write behaviour (stop and restart the world with the printed
`GROWTH_TRIAL_SERVICE` log line and inspect `growth/v1/registry` in the trial
world's mod storage), or the real Towns API.
