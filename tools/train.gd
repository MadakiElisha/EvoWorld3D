extends SceneTree
## Headless brain training. Saves champions to user://champions.bin, which the game
## loads on startup (press B in-game to switch creatures to brains).
##   godot --headless --path . -s res://tools/train.gd -- [--seed=1] [--ticks=500] [--shape=0] [--curriculum=0]
##   e.g. fitness shaping + curriculum: -- --ticks=700 --shape=3 --curriculum=1
func _init() -> void:
	var seed_v := 1
	var opts := {}
	for a in OS.get_cmdline_user_args():
		var kv := a.trim_prefix("--").split("=")
		if kv.size() == 2:
			opts[kv[0]] = kv[1]
	seed_v = int(opts.get("seed", "1"))
	var t0 := Time.get_ticks_msec()
	var tr := BrainTrainer.new(seed_v)
	tr.ticks = int(opts.get("ticks", str(tr.ticks)))
	tr.shape = float(opts.get("shape", str(tr.shape)))
	tr.curriculum = opts.get("curriculum", "0") != "0"
	print("TRAIN config: ticks=%d shape=%.1f curriculum=%s seed=%d" % [tr.ticks, tr.shape, str(tr.curriculum), seed_v])
	while tr.step(INF):
		pass
	print("trained in %.1f min" % ((Time.get_ticks_msec() - t0) / 60000.0))
	quit()
