#!/usr/bin/env python3
"""Run Towns-generated connector preservation trials in disposable VoxeLibre worlds."""
import argparse
from pathlib import Path
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--luanti", required=True, help="Luanti executable")
parser.add_argument("--towns", type=Path, required=True, help="Towns mod source directory")
args = parser.parse_args()
root = Path(__file__).resolve().parents[2]
for descending in (False, True):
    world = Path(tempfile.mkdtemp(prefix="roads-connector-trial-"))
    mods = world / "worldmods"
    trial = mods / "roads_trial"
    trial.mkdir(parents=True)
    (mods / "roads").symlink_to(root, target_is_directory=True)
    (trial / "init.lua").write_bytes((Path(__file__).parent / "init.lua").read_bytes())
    (trial / "town_roads.lua").write_bytes((args.towns / "src/town_roads.lua").read_bytes())
    (trial / "mod.conf").write_text("name = roads_trial\ndepends = roads, mcl_stairs\n")
    (world / "world.mt").write_text(
        "gameid = mineclone2\nbackend = sqlite3\nplayer_backend = sqlite3\n"
        "auth_backend = sqlite3\nmod_storage_backend = sqlite3\n"
        "load_mod_roads = true\nload_mod_roads_trial = true\n")
    config = world / "trial.conf"
    config.write_text(
        "mg_name = singlenode\ncreative_mode = true\nenable_damage = false\n"
        "server_announce = false\nport = 30126\n"
        f"roads_trial_descending = {str(descending).lower()}\n")
    print(f"{'Descending' if descending else 'Ascending'} trial: {world}", flush=True)
    result = subprocess.run(
        [args.luanti, "--server", "--world", str(world), "--config", str(config), "--logfile", ""],
        text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=90)
    (world / "trial-output.txt").write_text(result.stdout)
    for line in result.stdout.splitlines():
        if "ROADS_TRIAL_" in line or "ERROR[" in line:
            print(line)
    if result.returncode or "ROADS_TRIAL_PASS" not in result.stdout or "ROADS_TRIAL_FAIL" in result.stdout:
        raise SystemExit(f"Trial failed; full output: {world / 'trial-output.txt'}")
