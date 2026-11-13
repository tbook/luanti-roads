# Towns connector trial results

On 2026-11-13, the disposable headless trial ran against Luanti 5.18 and the
installed VoxeLibre 0.92.3. See [the runner](../tools/connector_trial/README.md)
for reproduction. Ramp nodes came from the neighboring Towns mod's actual
`town_roads.approach()` function, copied into each temporary fixture mod.

| Profile | Width | Generated rows | Resolved start | Resolved goal | Writes | Preserved reads |
| --- | --- | --- | --- | --- | --- | --- |
| Ascending | 4 | 5 | `(6,4,-2)` | `(34,4,2)` | 117 | 100 |
| Descending | 4 | 4 | `(5,0,-2)` | `(33,0,2)` | 117 | 104 |

Both trials completed real-engine inspection, endpoint resolution, search,
composition, construction preflight, and construction. Every recorded preserved
node (including its orientation) and metadata matched the pre-build value.
Each trial uses an independent temporary singlenode world with a stone terrain
fixture; no existing player world is modified.

These trials establish engine integration and preservation for those profiles.
Actual player traversal and client-side particle appearance still need client
inspection. The synthetic Lua suite separately exercises orientation and width
variants, rejection behavior, and planner/composer constraints.
