extends SceneTree
## Headless balance lab (hill climb over the knobs listed in BalanceLab.names).
##   godot --headless --path . -s res://tools/lab.gd -- [--seed=1]
func _init() -> void:
	var seed_v := 1
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--seed="):
			seed_v = int(a.split("=")[1])
	var template := Simulation.new(WorldData.new(8, 8, 1, 2), 0, false)
	var lab := BalanceLab.new(template, seed_v)
	while lab.step(INF):
		pass
	quit()
