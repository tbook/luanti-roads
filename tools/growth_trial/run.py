#!/usr/bin/env python3
"""Run the growth trial in a new disposable VoxeLibre world, in two launches.

Phase 1 builds the world, walks consecutive bends, edits a seam and interrupts a
fourth cycle. Phase 2 starts the same world again without rewriting anything and
checks what restart did to the persisted state.
"""
import argparse
from pathlib import Path
import shutil
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--luanti', required=True)
parser.add_argument('--mg-name', default='singlenode', choices=['singlenode', 'flat', 'v7'],
    help='mapgen for the disposable world; the trial area is pre-filled with stone either way')
parser.add_argument('--interrupt', default='planning', choices=['planning', 'build'],
    help='where the fourth cycle is cut off before the restart: during planning (zero writes, '
         'expect stopped) or right after construction (expect uncertain)')
parser.add_argument('--world', help='reuse this existing trial world instead of creating one (use with --phase 2)')
parser.add_argument('--phase', type=int, choices=[1, 2], help='run only this phase (2 needs --world)')
args = parser.parse_args()
if args.phase == 2 and not args.world:
    parser.error('--phase 2 needs --world from an earlier phase 1')
root = Path(__file__).resolve().parents[2]
here = Path(__file__).parent


def make_world():
    world = Path(tempfile.mkdtemp(prefix='roads-growth-trial-'))
    trial = world / 'worldmods' / 'roads_trial'
    trial.mkdir(parents=True)
    (world / 'worldmods' / 'roads').symlink_to(root, target_is_directory=True)
    for name in ('init.lua', 'service.lua', 'layout.lua'):
        (trial / name).write_bytes((here / name).read_bytes())
    shutil.copytree(root / 'src', trial / 'src')
    (trial / 'mod.conf').write_text('name = roads_trial\ndepends = roads\n')
    (world / 'world.mt').write_text('gameid = mineclone2\nbackend = sqlite3\nplayer_backend = sqlite3\n'
        'auth_backend = sqlite3\nmod_storage_backend = sqlite3\nload_mod_roads = true\nload_mod_roads_trial = true\n')
    return world


def launch(world, phase, pass_marker):
    config = world / f'trial-phase{phase}.conf'
    config.write_text(f'mg_name = {args.mg_name}\nserver_announce = false\nport = 30126\n'
        'mg_flags = nodecorations,nocaves,nodungeons\nserver_unload_unused_data_timeout = 100000\nserver_map_save_interval = 5.3\n'
        f'roads_trial_phase = {phase}\nroads_trial_interrupt = {args.interrupt}\n')
    result = subprocess.run([args.luanti, '--server', '--world', str(world), '--config', str(config),
        '--logfile', ''], text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=420)
    log = world / f'trial-phase{phase}-output.txt'
    log.write_text(result.stdout)
    print(f'--- phase {phase} ---', flush=True)
    for line in result.stdout.splitlines():
        if 'GROWTH_TRIAL_' in line or 'ERROR[' in line:
            print(line)
    if result.returncode or pass_marker not in result.stdout or 'GROWTH_TRIAL_FAIL' in result.stdout:
        raise SystemExit(f'Phase {phase} failed; full output: {log}')


if args.world:
    world = Path(args.world)
else:
    world = make_world()
print(f'Disposable world: {world}', flush=True)
if args.phase != 2:
    launch(world, 1, 'GROWTH_TRIAL_PHASE1_PASS')
if args.phase != 1:
    launch(world, 2, 'GROWTH_TRIAL_PASS')
    print('Trial passed: both phases.')
