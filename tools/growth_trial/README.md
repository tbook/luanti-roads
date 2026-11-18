# Disposable growth seam trial

With VoxeLibre installed as `mineclone2`, run:

```sh
python3 tools/growth_trial/run.py --luanti /path/to/luanti
```

The runner creates a temporary world, copies the checked-out source modules into
a trial mod, and uses the real engine to build a source road and a continuation.
It derives the exact seam before the source write, checks it after both writes,
and verifies that editing a preserved node prevents another search. The temporary
world and output log are retained at the printed path. UDP port 30126 is used.
This headless check does not verify player traversal.
