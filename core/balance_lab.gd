class_name BalanceLab
extends RefCounted
## Incremental headless parameter search (hill climb). Call step(budget_ms) per
## frame, or step(INF) headless. Every evaluation (baseline and each candidate)
## runs on the SAME islands with the SAME sim seeds, so a candidate only wins by
## being better, not by drawing a luckier random stream.

const ISLANDS := [1337, 777, 4242]
const SIM_SEEDS := [11, 22]            # paired random streams per island
const TICKS := 4000
const MAX_ITER := 24

var names := ["pred_kill_gain", "pred_cooldown", "ambush_p", "fear_energy", "forest_regrow_mult", "pred_rival_cost"]
var best: Array = []
var best_score := -1.0
var progress := 0.0

var _rng := RandomNumberGenerator.new()
var _iter := 0
var _phase := 0          # 0 = baseline, 1 = candidates
var _candidate: Array = []
var _run_idx := 0
var _tick := 0
var _coexist := 0
var _floor_h := 100000.0
var _floor_p := 100000.0
var _total := 0.0
var _sim: Simulation = null
var _done := false

func _init(template: Simulation, lab_seed: int = 1) -> void:
	_rng.seed = hash(lab_seed)
	for n in names:
		best.append(float(template.get(n)))
	_candidate = best.duplicate()

func _runs() -> int:
	return ISLANDS.size() * SIM_SEEDS.size()

func step(budget_ms: float = 8.0) -> bool:     # one bounded work chunk; returns false when all done
	if _done:
		return false
	var t0 := Time.get_ticks_usec()
	while (Time.get_ticks_usec() - t0) < budget_ms * 1000.0:
		if _sim == null:
			_start_run()
		_sim.tick()
		_tick += 1
		if _tick > 1000:
			var ct := _sim.counts()
			if ct.x > 0 and ct.y > 0:
				_coexist = _tick
				_floor_h = minf(_floor_h, float(ct.x))
				_floor_p = minf(_floor_p, float(ct.y))
		if _tick >= TICKS:
			_finish_run()
			if _done:
				break
	return not _done

func _finish_run() -> void:
	if _floor_h > 99999.0:
		_floor_h = 0.0
	if _floor_p > 99999.0:
		_floor_p = 0.0
	_total += float(_coexist) + 3.0 * minf(_floor_h, 60.0) + 3.0 * minf(_floor_p, 15.0)
	_run_idx += 1
	_tick = 0
	_coexist = 0
	_floor_h = 100000.0
	_floor_p = 100000.0
	_sim.release()
	_sim = null
	progress = (float(_iter) + float(_run_idx) / _runs()) / float(MAX_ITER + 1)
	if _run_idx >= _runs():
		_run_idx = 0
		var score := _total / float(_runs())
		_total = 0.0
		_on_eval_done(score)

func _on_eval_done(score: float) -> void:
	if _phase == 0:
		best_score = score
		print("LAB baseline score=%.0f params=%s" % [best_score, str(best)])
		_phase = 1
	elif score > best_score:
		best = _candidate.duplicate()
		best_score = score
		print("LAB iter %d/%d score=%.0f best=%.0f KEEP" % [_iter, MAX_ITER, score, best_score])
	else:
		print("LAB iter %d/%d score=%.0f best=%.0f" % [_iter, MAX_ITER, score, best_score])
	_iter += 1
	if _iter > MAX_ITER:
		_done = true
		progress = 1.0
		print("LAB DONE best_score=%.0f" % best_score)
		print("LAB RESULT — paste over the matching knobs in simulation.gd:")
		for i in names.size():
			print("var %s := %.2f" % [names[i], best[i]])
		return
	_candidate = best.duplicate()
	var i := _rng.randi() % names.size()
	_candidate[i] = _candidate[i] * _rng.randf_range(0.7, 1.3)

func _start_run() -> void:
	var island: int = ISLANDS[_run_idx / SIM_SEEDS.size()]
	var sim_seed: int = SIM_SEEDS[_run_idx % SIM_SEEDS.size()]
	_sim = Simulation.new(WorldData.new(48, 48, island, 8), sim_seed, false)
	_apply(_sim, _candidate if _phase == 1 else best)
	_sim.populate()

func _apply(sim: Simulation, v: Array) -> void:
	for i in names.size():
		var cur = sim.get(names[i])
		sim.set(names[i], int(round(v[i])) if typeof(cur) == TYPE_INT else v[i])
