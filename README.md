# Roads

A Luanti mod exploring terrain-aware country roads for VoxeLibre, with future
connections between Towns and Living Villages settlements.

## Status

This repository currently contains a loadable mod skeleton and a proposed
engineering design. Route planning, commands, and road construction are not yet
implemented. Loading the mod does not modify terrain or generate roads.

The first milestone will survey a bounded region between two manually selected
endpoints, find a route balancing distance, slope, turns, and earthworks, and
preview or build it using plain blocks. Bridges, tunnels, automatic destinations,
and settlement integration are later extensions.

- [Original brainstorm](docs/brainstorm.txt)
- [Engineering design](docs/engineering_design.md)

## Installation

Place this repository in a directory named `roads` under Luanti's `mods`
directory, or in a world's `worldmods` directory. Enable `roads` in a VoxeLibre
world. The skeleton requires VoxeLibre's `mcl_core` mod; Towns and Living Villages
are not required.

## Development

`mod.conf` declares the mod and dependencies; `init.lua` is the entry point.
Implementation modules will be added under `src/` as the planner is developed.
The design specifies a pure Lua planner and synthetic terrain fixtures before
real-world surveying and construction are introduced.

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).
