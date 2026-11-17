# `/roads_outward`: seeded outward road (#35)

Status: code complete and pure-tested. **No real-world trial has been run.** The
trial procedure in section 6 is for a person to run in a disposable VoxeLibre
world. Until that is done, the in-game behaviour below is unverified.

Depends on the outward-road service and Towns adapter in
[`outward_road_service.md`](outward_road_service.md) (#34) and the Towns contract
in `../towns/docs/roads_integration.md` (`towns_api` version 1).

## 1. Command

```
/roads_outward
```

- Requires the `server` privilege, like every Roads command.
- Takes no arguments. Its help text says that it **may generate terrain and
  automatically builds a road**. No endpoint selection and no build step are
  needed.
- Runs at most one road per explicit invocation. Nothing starts at server start
  or when a town completes.

Related commands, extended for outward work:

- `/roads_status` shows the active outward operation (for any `server` player)
  or, when you are idle, the most recent outward operation you requested in this
  server session.
- `/roads_cancel` cancels an active outward operation when one is running, and
  releases the shared slot. Otherwise it behaves as before and cancels your manual
  plan job.
- `/roads_preview` shows your manual plan when one exists. Otherwise it shows the
  centreline of your last outward road that reached commit (building, built, or failed after commit),
  using the existing preview renderer.

## 2. Selection policy (`src/outward_policy.lua`, pure)

The policy runs synchronously before the service is called. It never starts work
and never touches the service lifecycle.

1. **Settlement.** Completed settlements are listed with
   `towns_api.settlements` within **512 horizontal nodes** of the requester (by
   the adapter's `nearby`). The nearest one whose service eligibility is `open`
   is chosen. Ties are broken by settlement id. Settlements that are `reserved`
   (a built road), `unreadable`, or `active` are skipped and reported.
2. **Exit.** The chosen settlement's exits are considered in id order. The first
   one that normalizes (`towns_adapter.exit`) and is `open` for the service is
   chosen. Partial, interrupted or uncertain exits, and unsupported exits, are
   skipped and reported. If no exit is usable, the command reports
   `no_usable_exit`. It does **not** try another settlement.
3. **Nominal planning landing.** The first node beyond the exit's built length,
   on the lateral centre of its columns:
   `anchor + (length + 1) * direction + centre * lateral`. `centre` is the
   rounded midpoint of the exit's lateral offsets.
4. **Candidates.** Up to four integer targets, in generation order:
   - distance from the nominal landing in **64 to 128** nodes;
   - within **45 degrees** of the exit's outward direction (checked exactly in
     integer arithmetic after rounding);
   - outside the source settlement's footprint, meaning its published `core` and
     `structures` rectangles (the unbuilt outskirts belt of the reservation is
     allowed);
   - requested separation (anchor to target) at most **192** nodes;
   - resolved separation bounded by `distance + 11 + 3 <= 192`. The 11 covers the
     start moving to its landing, and the 3 covers the goal snapping.

   A draw that breaks any bound is dropped and another is drawn, up to 64 draws.
   Nothing is clamped or relaxed. If no candidate survives, the command reports
   `no_target`.
5. **Randomness.** A local Park-Miller generator, seeded from
   `world seed | settlement id | exit id | policy version (1)`. It never reads or
   changes `math.random` or any shared state. A given identity, seed and exit
   geometry always produce the same targets. The world seed is used as the text
   Luanti reports (`core.get_mapgen_setting("seed")`), up to 64 characters and
   without `|`. It is never parsed as a double, so 64-bit and negative seeds are
   exact. Numbers are accepted only when a double holds them exactly (up to
   2^53).
6. **Persistence.** The chosen inputs (`version`, `seed`, requester, settlement
   distance, direction, nominal landing, distance range, angle, draw count) are
   stored in the operation's `policy` field. The service persists it verbatim.

The chosen operation then goes through the unchanged service: survey budget,
Towns writer waiting, endpoint resolution, search, composition, durable
`building` record, durability wait, and construction. Its aggregate retry
budgets (96 chunks, 150,000 expansions) apply.

## 3. Reported outcomes

Every failure is a single clear line with a code. Examples:

| Situation | Code | Notes |
| --- | --- | --- |
| Towns mod absent | `towns_unavailable` | Manual commands are unaffected. |
| Unsupported `towns_api` version | `towns_unsupported` | |
| Registry unhealthy | `towns_unavailable` | |
| Nothing open within 512 nodes | `no_eligible_settlement` | If none is found nearby, the plain text. If some are found but all are skipped, lists each settlement and why (built road, in progress, unreadable record). |
| Chosen settlement has no usable exit | `no_usable_exit` | Lists each skipped exit and why. |
| No seeded target survives the bounds | `no_target` | Reports the settlement and exit. |
| Operation or slot busy | `busy` | Also when a manual plan holds the slot. |
| Built or uncertain prior work | `already_reserved` | Only reachable on a race; selection avoids it. |
| World seed unreadable | `unavailable` | No work is started. |
| Blocked terrain (every target) | the last attempt's code, e.g. `bounded_no_route` | Each attempt is listed in `/roads_status`. |

On success the reply names the operation, settlement, exit, the requester's
distance to the settlement, and the four targets.

`/roads_status` (for an active or most recent outward operation) shows:

- the operation id, state and stage (`planning`, `surveying`, `waiting_towns`,
  `resolving`, `searching`, `composing`, `committing`, `durability_wait`,
  `building`), and whether it is persisted;
- settlement, exit and requester, the targets, and the target currently tried;
- each attempt's target, outcome and reason;
- the chosen road: requested and resolved target, terminal, and metrics (length,
  ascent, descent, max grade, turns, cuts, fills, writes);
- route geometry: the landing, the outward direction, the number of centreline
  nodes, up to eight waypoints (the start, about every 16th node, and the end,
  or eight evenly spaced nodes when a route is longer), the terminal and its
  heading as a direction vector;
- aggregate metrics: distinct chunks and chunk requests, expansions, survey and
  search seconds, longest slice, peak states and heap entries, and any exhausted
  shared budget with its limit and observed value;
- writes (`none`, `unknown`, `some`, `all`), construction pause, cancellation
  and the precise error with its position, limit or observed value where
  applicable.

The live aggregate was previously empty until commit. The service's status now
reads the running aggregate (`src/outward.lua`, `summarize`).

## 4. Coverage

Pure Lua 5.1, run with `lua5.1 tests/run.lua` (about 35 s):

- `tests/outward_policy.lua` (12 tests): nearest choice, identity ties and input
  order, blocked records, horizontal radius (inclusive at 512, y ignored), exit
  order with reserved and unsupported skips, no fall-through to another
  settlement, candidate bounds for every direction, shape, and width against an
  independent float oracle, reservation rejection, reproducibility, seed and exit
  sensitivity, count prefix property, global `math.random` unchanged, invalid
  requests and caps, `no_target`, exact separation limits, persisted policy,
  realistic 64-bit and negative seed text (reproducible, distinct per seed,
  refused when a number cannot be exact, `|` and over-length refused).
- `tests/outward_command.lua` (14 tests): privilege and help text, online
  player, unreadable seed, Towns absent and unsupported, a success run with live
  status and the built outcome, repeat refused after built, busy against a manual
  plan and against an outward run, no eligible settlement beyond the radius, a
  partial exit skipped, cancellation with the exit reopened, blocked terrain
  with per-attempt report and zero writes, presentation of budgets and
  positions, bounded route geometry (at most eight waypoints, start and end
  included, terminal heading), the outward preview fallback, and a 64-bit seed
  through the command path. The command, service, store, adapter and job slot are real. Only
  the terrain pipeline is scripted.
- `tests/towns_adapter.lua`: `nearby` keeps Towns order, drops incomplete or
  malformed records, returns copies, and classifies unavailable and unsupported.

Developer-run mutation checks, in a scratch copy and not independently verified:
reverting the live aggregate, widening the angle draw without the check, using
`math.random`, reversing the identity tie break, making the radius exclusive,
removing the reservation check, and removing the outward busy pre-check were each
reported as caught by at least one of these suites. A reviewer should rerun them
before relying on them.

**Not covered by tests:** real Luanti (mod storage commit timing, emerge,
`core.get_mapgen_setting("seed")`, chat command behaviour, protection owner
interaction) and real VoxeLibre geometry.

## 5. Limitations

- **Towns returns at most 32 settlements** per query. If the nearest 32 within
  512 nodes are all blocked, the command reports `no_eligible_settlement` even if
  a farther open settlement exists.
- **No settlement fall-through.** When the nearest open settlement has no usable
  exit, the command reports it rather than trying the next one. This follows the
  ticket's "report no usable exit rather than scanning". A product decision is
  needed if this should change.
- **Targets ignore Towns exclusions at selection time.** Only the source's
  footprint (core and structures) is checked when generating targets. Exclusions, other settlements
  and the connector's own rules are enforced later by the service's overlay,
  endpoint resolution, and build guard.
- **Route geometry is a sample, not the connector.** `/roads_status` shows the
  landing, up to eight centreline waypoints, the terminal and its heading. The
  preview shows the full centreline of the last outward road for its requester.
  Neither shows the connector paths or transitions at the exit. Those are not kept
  in the outward status summary. The journey must still be inspected on foot.
- **Memory-only "last request".** `/roads_status` recalls the settlement a player
  last requested only for the current server session. Other players' finished
  runs are reachable through `roads.outward:status(settlement_id)` (Lua), not
  through a command.
- **Retries are explicit and deterministic.** Each `/roads_outward` repeats
  selection with the same identity, so unchanged terrain produces the same
  targets and probably the same failure. Nothing retries automatically.
- **One successful road per settlement, and only the chosen exit blocks.** These
  are service rules (#34). A partial or uncertain road blocks its exit only.
- **Versioned targets.** Changing `policy.VERSION` changes every target for every
  settlement.

## 6. Trial procedure (for a human, disposable world)

Record the outputs of each step. Do not treat this document as evidence that a
trial has passed.

**Setup**

1. Create a disposable VoxeLibre world with Towns and Roads enabled. Note the
   world seed from the world's creation settings (or `map_meta.txt`).
2. Explore until an automatic Towns settlement completes. It must be published
   (`towns_api.settlements` lists it). Confirm with server Lua if available, for
   example `/lua return towns_api.settlements({x=0,z=0}, 512)`.
3. Note each published exit (id, direction, width, length, profile kind: flat
   full-block or graded stair/slab).

**Sloped exit, then flat exit**

4. Stand within 512 nodes of the settlement and run `/roads_outward` once. Record
   the reply: settlement id, exit id, requester distance and targets.
5. Repeat `/roads_status` until the stage is `building` or the state is terminal.
   Record stages and times.
6. On completion, record from `/roads_status`: chosen target (requested and
   resolved), terminal, length, ascent, descent, max grade, turns, cuts, fills,
   writes, chunks, expansions, peak states and heap, survey seconds, search
   seconds, longest slice and pause seconds.
7. Walk the road from the exit to the target. Check that it is continuous,
   that the approach orientation and stair/slab supports at the exit match what
   the settlement built, and that no settlement structure was cut.
8. Repeat with a second settlement or exit of the other kind, so that both a
   sloped (stair/slab) departure and a flat full-block departure are inspected.

**Repeat and restart**

9. Run `/roads_outward` again on the same settlement. It must be refused with
   `no_eligible_settlement`, naming the settlement and why it was skipped (for
   example, that it already has a built outward road). Record the reply.
10. Restart the server during `surveying` or `building`. After restart,
    `/roads_status` must show the operation as interrupted (with writes
    `none` or `unknown`) and must not replay the build. Record the state. A
    `building` record with unknown writes reserves its exit only.

**Blocked terrain**

11. In a second disposable world, surround one exit with obstacles (stone walls)
    that make every target unreachable, or raise a cliff across the approach.
    Run `/roads_outward`. Expect `bounded_no_route` (or `earthwork`, `clearance`
    or `grade`) reported for each attempt, and the error precise. Record the
    reply, the attempts, the chunks and expansions.
12. Confirm zero writes: no road or cobblestone appears near the exit, and the
    status reads `Writes: none`. Repeat `/roads_outward`: the exit is open again
    and the same failure is expected.

**Recording**

13. For every run record: world seed, settlement id, exit id, exit kind and
    width, chosen target, the metrics listed in step 6, the observed stages and
    times, any Luanti log lines starting with `[roads]`, and the server
    save-interval setting. Note anything that differs from this document.

## 7. Trial results

Recorded from one real run. Anything not listed under "Observed" has not been
run in the engine.

**Observed in Luanti 5.18, 2026-11-17, world Testlandia:**

- An automatic medieval town, `auto:-1:2` (center -326, 2556, town seed
  718373748), was published by Towns.
- The first `/roads_outward` selected exit `+x:-273:2554` (wall_gatehouse,
  width 4, graded cobble/slab profile). It failed with `no_target`, because
  targets had to lie outside the whole settlement reservation. This was fixed
  afterwards: targets now have to lie outside the source footprint only (core
  and structures), as section 2 describes.
- The second run built a road. The first candidate target (-166, 2482) resolved
  to (-164, 7, 2483). Metrics: about 144 nodes long, ascent 2, descent 9, turns
  10, cuts 18, fills 0, max grade 0.25, 691 writes, 2990 expectations, 1154
  expansions, 18 new chunks, survey 5.9 s, search 8.2 s.
- The player confirmed that the road looked good and connected to the exit.
- The road's landing was about 4 to 5 blocks sideways from the gate's centre.
  The cause is the landing candidate ordering in `connectors.landing_options`.
  This was fixed after the trial. The fix has not been re-run in the engine.
- A repeat `/roads_outward` was refused with `no_eligible_settlement`, which
  confirmed the repeat check. That run used the wording from before the
  per-reason presentation change, so the new wording has not been seen in the
  engine.
- The other published exits got no road, by design: one successful road per
  settlement.

**Not run in the engine (unit tests only):**

- A flat full-block exit.
- Blocked-terrain failure.
- Restart and replay safety.
- Storage-failure paths.
- Cancellation.

Pure or scripted unit tests cover parts of these (for example in
`tests/outward_policy.lua`, `tests/outward_command.lua`, `tests/outward_store.lua`,
`tests/outward.lua` and `tests/connectors.lua`). They are not evidence of engine
behaviour.
