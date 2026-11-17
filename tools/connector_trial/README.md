# Disposable connector trial

With VoxeLibre installed as `mineclone2`, run from the repository root:

```sh
python3 tools/connector_trial/run.py --luanti /path/to/luanti --towns ../towns
```

The runner creates two temporary worlds, copies Towns' pure `approach()` helper
into a fixture mod, and reproduces its ascending and descending four-wide ramps.
It runs real node inspection, connector resolution, planning, composition, and
construction. Every preserved node and its metadata must remain unchanged.
Worlds and full logs remain in the printed temporary directories for inspection.
It never opens or modifies an existing world. UDP port 30126 must be available.

This headless trial checks construction and preservation. It does not verify
client particle appearance or actual player traversal; inspect those in a client.
