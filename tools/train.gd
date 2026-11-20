extends SceneTree
## Headless brain training. Saves champions to user://champions.bin, which the game
## loads on startup (press B in-game to switch creatures to brains).
##   godot --headless --path . -s res://tools/train.gd -- [--seed=1]
func _init() -> void:
	var seed_v := 1
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--seed="):
			seed_v = int(a.split("=")[1])
	var t0 := Time.get_ticks_msec()
	var tr := BrainTrainer.new(seed_v)
	while tr.step(INF):
		pass
	print("trained in %.1f min" % ((Time.get_ticks_msec() - t0) / 60000.0))
	quit()
