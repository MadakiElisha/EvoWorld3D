# EvoWorld3D

An ecosystem god-game in Godot 4.7. A voxel island, grazing herbivores and hunting
predators whose genes (speed, sense, metabolism) and optional neural brains mutate
every generation. You are the steward: keep both species alive for 10,000 ticks
(**STEWARD**) without letting the island **COLLAPSE**.

## Run it (Ubuntu)

1. Download the official **Godot 4.7-stable** Linux build (x86_64 zip) from
   godotengine.org. Don't use the apt package; it's an old version.
2. Unzip it, `chmod +x` the binary, and optionally symlink it as `godot` on your PATH.
3. If you copied this folder from Windows, delete the `.godot/` folder first and let
   Godot reimport.
4. `godot --path .` to play, or `godot -e --path .` to open the editor.

If git shows every file as modified after copying from Windows:
`git config core.fileMode false`.

## Controls

| Key | Action |
| --- | --- |
| Mouse drag / wheel | orbit / zoom |
| 1 2 3 4 | speed 1× 4× 16× 64× (HUD turns orange when the CPU can't keep up) |
| Space / N | random island / next curated island |
| H / P | spawn herbivores / predators (reintroduce an extinct species) |
| C / D | cull 40% of predators / herbivores |
| V, Tab | follow a creature first-person, cycle to the next |
| B | toggle evolved brains vs hand-written reflexes |
| F7 / F9 | train brains / run the balance lab in the background |

## Rules (core/round_judge.gd)

- **STEWARD**: both species alive at tick 10,000.
- **COLLAPSE**: a species stays extinct for 400 ticks (you get that long to press H/P),
  or everything dies.

## Headless tools

These run without a window, so they're much faster than the in-game versions and you
can leave them running in a terminal.

```bash
# Balance regression across all cores: STEWARD rate per island
GODOT=godot tools/regress.sh --runs=10
GODOT=godot tools/regress.sh --runs=10 --set=start_preds=16,ambush_p=0.8   # try knob changes
GODOT=godot tools/regress.sh --runs=10 --brain                             # with saved champions

# Train brains; the champions are saved to user://champions.bin and the game loads them on start
godot --headless --path . -s res://tools/train.gd
godot --headless --path . -s res://tools/train.gd -- --ticks=700 --shape=3 --curriculum=1   # fitness shaping + easy-to-hard arenas

# Hill-climb balance knobs
godot --headless --path . -s res://tools/lab.gd
```

Every run is deterministic: the same island seed + sim seed + inputs replay the same
history. Use the regression STEWARD rate over many seeds, not single runs, to judge a
balance change.

## Layout

```
core/       pure simulation, no nodes: world, creatures, sim, judge, trainer, lab
scripts/    game controller (rendering, input), HUD, orbit camera
tools/      headless entry points
```
