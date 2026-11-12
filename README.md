# Roads

A Luanti mod exploring terrain-aware country roads for VoxeLibre, with future
connections between Towns and Living Villages settlements.

## Status

This repository contains an early route planner for VoxeLibre. Server-privileged
players can select two endpoints and request a terrain survey and route plan.
Planning may generate terrain in a bounded region. It does not place road blocks;
construction is not implemented.

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
the resolved endpoints with `/roads_status`; `/roads_cancel` cancels active
work or releases a completed, unbuilt plan. `/roads_preview` briefly shows the
ready route to its owner as temporary particles. Preview requests are limited
to one every eight seconds and markers expire after eight seconds. Only one
survey or ready plan can hold the server slot at a time. A ready plan does not
build anything.

## Development

`mod.conf` declares the mod and dependencies; `init.lua` wires the Luanti
adapters to the pure Lua planning modules under `src/`. Run the unit suite with
`lua5.1 tests/run.lua`.

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).
