extends SceneTree
## Headless balance regression: plays unaided rounds with the real RoundJudge rules.
##
##   godot --headless --path . -s res://tools/regress.gd -- [options]
##     --islands=524274379,2655256772   world seeds (default: the curated islands)
##     --runs=10                        sim seeds per island (1..N)
##     --ticks=10000                    round length cap (default RoundJudge.WIN_TICKS)
##     --brain                          brain mode, using saved champions if any
##     --shard=0/4                      only run every 4th job starting at 0 (for parallel runs)
##     --set=start_preds=16,ambush_p=0.8   override Simulation knobs for this run
##
## Prints one "RUN ..." line per round, then a summary (tools/regress.sh merges shards).

const CURATED := [524274379, 2655256772, 819918188]

func _opt(args: PackedStringArray, key: String, def: String) -> String:
	for a in args:
		if a.begins_with("--" + key + "="):
			return a.split("=", true, 1)[1]
	return def

func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var islands: Array = []
	for s in _opt(args, "islands", ",".join(CURATED.map(func(v): return str(v)))).split(","):
		islands.append(int(s))
	var runs := int(_opt(args, "runs", "10"))
	var max_ticks := int(_opt(args, "ticks", str(RoundJudge.WIN_TICKS)))
	var brain := args.has("--brain")
	var shard := _opt(args, "shard", "0/1").split("/")
	var shard_i := int(shard[0])
	var shard_n := int(shard[1])
	var champs := ChampionStore.load_champions() if brain else {}
	var overrides := {}
	var set_s := _opt(args, "set", "")
	if set_s != "":
		for kv in set_s.split(","):
			var parts := kv.split("=")
			overrides[parts[0]] = float(parts[1])
		print("# overrides: %s" % str(overrides))
	if brain:
		print("# brain mode, champions: %s" % ("loaded" if not champs.is_empty() else "NONE (random brains)"))

	var job := -1
	var wins := 0
	var total := 0
	var total_ms := 0.0
	var total_ticks := 0
	for island in islands:
		for run in range(1, runs + 1):
			job += 1
			if job % shard_n != shard_i:
				continue
			var world := WorldData.new(72, 72, island, 8)
			var sim := Simulation.new(world, run, false)
			if brain:
				sim.brain_mode = 1
				if not champs.is_empty():
					sim.champ_herb = champs.herb
					sim.champ_pred = champs.pred
			for k in overrides:
				var cur = sim.get(k)
				if cur == null:
					push_error("unknown knob: %s" % k)
					quit(1)
					return
				sim.set(k, int(overrides[k]) if typeof(cur) == TYPE_INT else overrides[k])
			sim.populate()
			var judge := RoundJudge.new()
			var t0 := Time.get_ticks_usec()
			while judge.update(sim) == "" and sim.tick_count < max_ticks:
				sim.tick()
			var ms := (Time.get_ticks_usec() - t0) / 1000.0
			var ct := sim.counts()
			var outcome := judge.outcome if judge.outcome != "" else "TIMEOUT"
			print("RUN island=%d seed=%d outcome=%s tick=%d herb=%d pred=%d ms_per_tick=%.2f reason=%s" % [island, run, outcome, sim.tick_count, ct.x, ct.y, ms / maxi(sim.tick_count, 1), judge.reason.replace(" ", "_")])
			total += 1
			wins += 1 if outcome == "STEWARD" else 0
			total_ms += ms
			total_ticks += sim.tick_count
			sim.release()
	if shard_n == 1 and total > 0:
		print("SUMMARY rounds=%d steward=%d (%.0f%%) mean_ms_per_tick=%.2f" % [total, wins, 100.0 * wins / total, total_ms / maxi(total_ticks, 1)])
	quit()
