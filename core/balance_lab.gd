class_name BalanceLab
extends RefCounted
## Incremental headless parameter search: does a bounded amount of work per
## step() call so the game keeps running. game_controller calls step() per frame.

const SEEDS := [1337, 777, 4242]
const TICKS := 4000
const MAX_ITER := 24
const TICKS_PER_STEP := 250

var names := ["pred_kill_gain", "pred_cooldown", "ambush_p", "fear_energy", "forest_regrow_mult", "pred_rival_cost"]
var best: Array = []
var best_score := -1.0

var _iter := 0
var _phase := 0          # 0 = baseline, 1 = candidates
var _candidate: Array = []
var _seed_idx := 0
var _tick := 0
var _coexist := 0
var _floor_h := 100000.0
var _floor_p := 100000.0
var _total := 0.0
var _sim: Simulation = null
var _done := false

func _init(template: Simulation) -> void:
	for n in names:
		best.append(float(template.get(n)))
	_candidate = best.duplicate()

func step() -> bool:     # one bounded work chunk; returns false when all done
	if _done:
		return false
	var budget := TICKS_PER_STEP
	while budget > 0:
		if _sim == null:
			_start_seed()
		_sim.tick()
		_tick += 1
		if _tick > 1000:
			var ct := _sim.counts()
			if ct.x > 0 and ct.y > 0:
				_coexist = _tick
				_floor_h = minf(_floor_h, float(ct.x))
				_floor_p = minf(_floor_p, float(ct.y))
		budget -= 1
		if _tick >= TICKS:
			_finish_seed()
			if _done:
				break
	return not _done

func _finish_seed() -> void:
	if _floor_h > 99999.0:
		_floor_h = 0.0
	if _floor_p > 99999.0:
		_floor_p = 0.0
	_total += float(_coexist) + 3.0 * minf(_floor_h, 60.0) + 3.0 * minf(_floor_p, 15.0)
	_seed_idx += 1
	_tick = 0
	_coexist = 0
	_floor_h = 100000.0
	_floor_p = 100000.0
	_sim = null
	if _seed_idx >= SEEDS.size():
		_seed_idx = 0
		var score := _total / float(SEEDS.size())
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
		print("LAB iter %d/%d score=%.0f best=%.0f KEEP" % [_iter + 1, MAX_ITER, score, best_score])
	else:
		print("LAB iter %d/%d score=%.0f best=%.0f" % [_iter + 1, MAX_ITER, score, best_score])
	_iter += 1
	if _iter > MAX_ITER:
		_done = true
		print("LAB DONE best_score=%.0f" % best_score)
		print("LAB RESULT — paste over the matching knobs in simulation.gd:")
		for i in names.size():
			print("var %s := %.2f" % [names[i], best[i]])
		return
	_candidate = best.duplicate()
	var i := randi() % names.size()
	_candidate[i] = _candidate[i] * randf_range(0.7, 1.3)

func _start_seed() -> void:
	var world := WorldData.new(48, 48, SEEDS[_seed_idx], 8)
	_sim = Simulation.new(world)
	_apply(_sim, _candidate if _phase == 1 else best)

func _apply(sim: Simulation, v: Array) -> void:
	for i in names.size():
		sim.set(names[i], v[i])
