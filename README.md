# Roads

A Luanti mod exploring terrain-aware country roads for VoxeLibre, with future
connections between Towns and Living Villages settlements.

## Status

This repository contains an early route planner for VoxeLibre. Server-privileged
players can select two endpoints and request a terrain survey and route plan.
Planning may generate terrain in a bounded region. An owner can build a ready
plan as a plain cobblestone road after terrain and protection are rechecked.

The first milestone will survey a bounded region between two manually selected
endpoints, find a route balancing distance, slope, turns, and earthworks, and
preview or build it using plain blocks. Bridges, tunnels, automatic destinations,
and settlement integration are later extensions.

- [Original brainstorm](docs/brainstorm.txt)
- [Engineering design](docs/engineering_design.md)

## Installation

Place this repository in a directory named `roads` under Luanti's `mods`
directory, or in a world's `worldmods` directory. Enable `roads` in a VoxeLibre
world. The mod depends on VoxeLibre's `mcl_core` and `mcl_init`; Towns and Living
Villages are not required.

## Commands

All commands require the server privilege. Use `/roads_start` at the first
endpoint, travel to the destination, then use `/roads_plan`. Check progress and
the selected endpoints, natural landings, and any connector lengths with
`/roads_status`; `/roads_cancel` cancels active work or releases a completed,
unbuilt plan. `/roads_preview` shows the route and any preserved Towns walking
path and paved transition in separate colors to its owner for 30 seconds. Preview requests are limited
to one every eight seconds. Only one
survey or ready plan can hold the server slot at a time. Use `/roads_build` to
construct your ready plan. The mod checks terrain and protection again before
writing; if construction is interrupted by an error, it reports partial work.
Construction currently permits up to 10,000 writes and 50,000 inspected nodes
per plan. These initial limits are tuning points, not latency guarantees; larger
plans must be shortened. Construction changes terrain and has no automatic
rollback; use a disposable world while playtesting.

## Development

`mod.conf` declares the mod and dependencies; `init.lua` wires the Luanti
adapters to the pure Lua planning modules under `src/`. Run the unit suite with
`lua5.1 tests/run.lua`. GitHub Actions runs the same suite for pull requests and
pushes to `main`.

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).
