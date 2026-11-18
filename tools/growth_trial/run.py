#!/usr/bin/env python3
"""Run a continuation seam trial in a new disposable VoxeLibre world."""
import argparse
from pathlib import Path
import shutil
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--luanti', required=True)
args = parser.parse_args()
root = Path(__file__).resolve().parents[2]
world = Path(tempfile.mkdtemp(prefix='roads-growth-trial-'))
trial = world / 'worldmods' / 'roads_trial'
trial.mkdir(parents=True)
(world / 'worldmods' / 'roads').symlink_to(root, target_is_directory=True)
(trial / 'init.lua').write_bytes((Path(__file__).parent / 'init.lua').read_bytes())
shutil.copytree(root / 'src', trial / 'src')
(trial / 'mod.conf').write_text('name = roads_trial\ndepends = roads\n')
(world / 'world.mt').write_text('gameid = mineclone2\nbackend = sqlite3\nplayer_backend = sqlite3\n'
    'auth_backend = sqlite3\nmod_storage_backend = sqlite3\nload_mod_roads = true\nload_mod_roads_trial = true\n')
config = world / 'trial.conf'
config.write_text('mg_name = singlenode\nserver_announce = false\nport = 30126\n')
print(f'Disposable world: {world}', flush=True)
result = subprocess.run([args.luanti, '--server', '--world', str(world), '--config', str(config),
    '--logfile', ''], text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=90)
(world / 'trial-output.txt').write_text(result.stdout)
for line in result.stdout.splitlines():
    if 'GROWTH_TRIAL_' in line or 'ERROR[' in line:
        print(line)
if result.returncode or 'GROWTH_TRIAL_PASS' not in result.stdout or 'GROWTH_TRIAL_FAIL' in result.stdout:
    raise SystemExit(f'Trial failed; full output: {world / "trial-output.txt"}')
