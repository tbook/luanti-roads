# Asynchronous terrain survey

`src/survey_job.lua` exports `new(preflight, inspector, ops, start, goal,
owner, config)`. Supply the modules from `src/survey.lua` and `src/surface.lua`,
endpoint positions and world configuration accepted by `survey.plan`, and a
read-only `surface.engine_access(core)` object as `ops.access`. `ops.now()`
returns monotonic seconds; `ops.after(delay, fn)` schedules work on the server;
`ops.emerge(minp, maxp, callback)` has Luanti `emerge_area` semantics.
`ops.load_area(minp, maxp)` must load existing blocks without generating them;
inject `core.load_area`.
`ops.actions` maps `cancelled`, `errored`, `memory`, `disk`, and `generated`
to the five Luanti `EMERGE_*` constants. A failed preflight returns `nil, error`.

A job starts asynchronously. `job:status()` returns `running`, `succeeded`,
`failed`, or `cancelled`, with metrics and terminal error or completed terrain.
`job:cancel()` is idempotent. A terminal job ignores all pending callbacks and
scheduled work. The caller owns global job exclusion and disconnect handling.
A timer fails an inactive job after 60 seconds. Each successful engine
callback counts as progress; emergence is sequential and errors stop the job.

The inspector needs the entire vertical window to identify the outdoor surface.
The job therefore completes the preflight's bounded mapchunk emerges first,
then reads the requested region as 4-by-4 horizontal tiles spanning the full
vertical inspection window. Each tile is released after its summaries are
copied. A callback processes at most eight tiles, stopping between tiles once
10 ms has elapsed, before yielding. An individual tile can exceed that time.
The job loads each tile's blocks
before reading it, because emerged blocks can be evicted while earlier tiles
are being inspected. Rounded mapblock load volumes are capped independently.
Missing blocks remain unknown; loading does not generate new terrain. Ground
outside the true configured overworld Y interval is reported unknown.
Daylight and metadata checks are
provided by the surface adapter. The final getter returns independent column
copies, with `outside` beyond the requested rectangle. Successful emergence
does not guarantee completion of deferred world changes by other mods.

Metrics report completed chunks, callbacks, tiles, columns, time waiting for
emerge, total and maximum inspection-tile time including summary copying,
maximum inspection and emerge volumes, and total elapsed time on success.
They also include load time and the maximum rounded load volume.

After surveying, the planning lifecycle schedules each running search slice
for the next Luanti server step. Each slice retains its 5 ms deadline and
expansion cap; a single search expansion cannot be interrupted. Survey status
polls still run at 100 ms intervals. Cancellation invalidates queued work.

## Disposable-world integration

Luanti 5.18.0 and VoxeLibre 0.92.3, flat mapgen, seed 1275046580066254493;
endpoints (8,12,8), using the normal preflight window, in a disposable world.
The service emerged 3 chunks with 375 callbacks and completed 289 inspection
tiles. It took 15.92 seconds elapsed, with 1.38 seconds in inspection and a
maximum measured tile of 50 ms. A 100 ms periodic callback ran 147 times while
the survey progressed. The sample column was classified as water. The probe
created/generated terrain only in the disposable world; the survey itself made
no terrain writes. These are single-run measurements, not latency guarantees;
server load and Lua garbage collection may cause longer pauses. An earlier
8-by-8 tile run finished in 4.76 seconds with a 70 ms maximum tile, before the
copy time was included in that metric. Smaller tiles trade throughput for more
frequent yielding.

After adding per-tile `core.load_area`, a second run in the same disposable
world completed 3 chunks and 289 tiles in 16.25 seconds; the maximum combined
load and inspection tile was 43 ms and 147 heartbeat callbacks ran. This run
checks the real load API but did not force mapblock eviction; an automated
fake-engine test simulates eviction before every tile.
