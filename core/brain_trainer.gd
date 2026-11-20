class_name BrainTrainer
extends RefCounted
## Offline neuroevolution: one focal brain at a time in a small arena against
## reflex opponents, then a measurement pass (evolved vs random vs reflex).
## Incremental: call step(budget_ms) every frame, or step(INF) headless.
##
## Fitness is lifetime-based and always read from the candidate itself:
##   100 * (ticks survived / ticks) + 0.5 * energy if alive + 40 * offspring
##   + optional shaping: `shape` points per tile closed on the SAME target (food tile or
##     prey). Steps where the target changes are skipped, so a kill (next prey
##     is farther away) or a finished meal is never punished.
## Optional curriculum: early generations train in easier arenas (fewer predators for
## herbivores, slower prey for predators), ramping to full difficulty by 60% of
## the run. Measurement always uses full difficulty and no shaping.
## Every candidate in a generation faces the same arenas (common random numbers),
## so differences in score come from the brain, not from luck.

const POP := 16
const ELITE := 4
const GENS := 20
const SEEDS := 4
const MEASURE_SEEDS := 12   # more arenas for the final comparison (less noise)

# Tunable per run (tools/train.gd flags: --ticks= --shape= --curriculum=0/1).
# Defaults are the proven setup. A/B on seed 1 (12 measurement arenas):
#   default                  herb 1.9x reflex, pred 0.86x reflex
#   ticks=700 shape=3 curr=1 herb 2.2x reflex, pred 0.57x reflex
# Shaping seems to teach predators to charge, which alerts prey and loses the
# 0.85 ambush strike. Both champion sets kept all 3 islands alive in brain mode.
var ticks := 500
var shape := 0.0            # points per tile closed on the same target; 0 = off
var curriculum := false

var done := false
var champ_herb := PackedFloat32Array()
var champ_pred := PackedFloat32Array()
var report := ""
var progress := 0.0           # 0..1, for HUD display

var _brains: Simulation       # used only for its brain helpers
var _rng := RandomNumberGenerator.new()
var _phase := 0               # 0 = evolve, 2 = measure
var _species := 0
var _pop: Array = []
var _fit: Array = []
var _gen := 0
var _cand := 0
var _seed_i := 0
var _tick := 0
var _sim: Simulation = null
var _focal: CreatureData = null
var _acc := 0.0
var _shape := 0.0
var _prev_d := -1.0
var _prev_tile := Vector2i(-1, -1)
var _prev_prey: CreatureData = null
var _measure_kind := 0
var _meas := [[0.0, 0.0, 0.0], [0.0, 0.0, 0.0]]

func _init(train_seed: int = 1) -> void:
	_rng.seed = hash(train_seed)
	_brains = Simulation.new(WorldData.new(8, 8, 1, 2), 0, false)
	_new_pop()

func _new_pop() -> void:
	_pop.clear()
	for i in POP:
		_pop.append(_brains.make_random_brain(_rng))
	_fit.resize(POP)

## Runs evaluation ticks until budget_ms of wall time is used. Returns false when finished.
func step(budget_ms: float = 8.0) -> bool:
	if done:
		return false
	var t0 := Time.get_ticks_usec()
	while not done and (Time.get_ticks_usec() - t0) < budget_ms * 1000.0:
		if _sim == null:
			_start_eval()
		_sim.tick()
		_tick += 1
		if _phase < 2 and shape != 0.0:
			_sample_shape()
		if _tick >= ticks or not _focal.alive:
			_end_eval()
	return not done

## Reward closing distance on an unchanged target; reset when the target changes.
func _sample_shape() -> void:
	if not _focal.alive:
		return
	var d := -1.0
	var same := false
	if _focal.species == CreatureData.Species.HERB:
		var off := _sim.seek_food(_focal)
		if off != Vector2.ZERO:
			var tile := Vector2i(int(floor(_focal.x + off.x)), int(floor(_focal.z + off.y)))
			d = off.length()
			same = tile == _prev_tile
			_prev_tile = tile
		else:
			_prev_tile = Vector2i(-1, -1)
	else:
		var prey := _sim.nearest_prey(_focal, 999.0)
		if prey != null:
			d = Vector2(prey.x - _focal.x, prey.z - _focal.z).length()
			same = prey == _prev_prey
		_prev_prey = prey
	if same and _prev_d >= 0.0 and d >= 0.0:
		_shape += (_prev_d - d) * shape
	_prev_d = d

## 0 = easiest arena, 1 = full difficulty. Measurement is always 1.
func _difficulty() -> float:
	if not curriculum or _phase == 2:
		return 1.0
	return clampf(float(_gen) / (GENS * 0.6), 0.0, 1.0)

func _current_brain():
	if _phase == 2:
		match _measure_kind:
			0: return champ_herb if _species == 0 else champ_pred
			1: return _brains.make_random_brain(_rng)
			_: return null   # reflex baseline
	return _pop[_cand]

func _spawn(sim: Simulation, sp: int, brain) -> CreatureData:
	for t in 60:
		var x := sim.rng.randi_range(2, sim.world.width - 3)
		var z := sim.rng.randi_range(2, sim.world.depth - 3)
		if sim.can_enter(sp, x, z):
			var c := sim.make_creature(x + 0.5, z + 0.5, null, sp)
			c.energy = 70.0
			c.speed = 1.6 if sp == CreatureData.Species.PRED else 1.2
			c.sense = 2.0
			c.use_brain = brain != null
			if brain != null:
				c.brain = brain
			sim.creatures.append(c)
			return c
	return null

func _start_eval() -> void:
	var w := WorldData.new(32, 32, 700 + _seed_i * 13, 6)
	# same arena seed for every candidate of this generation/species
	_sim = Simulation.new(w, hash([_phase, _species, _gen, _seed_i]), false)
	_sim.seed_food()
	var diff := _difficulty()
	if _species == 0:
		for i in 1 + int(round(2.0 * diff)):          # 1 predator -> 3
			_spawn(_sim, CreatureData.Species.PRED, null)
		_focal = _spawn(_sim, CreatureData.Species.HERB, _current_brain())
	else:
		for i in 6:
			var prey := _spawn(_sim, CreatureData.Species.HERB, null)
			if prey != null:
				prey.speed = lerpf(0.7, 1.2, diff)      # slow prey -> normal
		_focal = _spawn(_sim, CreatureData.Species.PRED, _current_brain())
	if _focal == null:   # arena had no room: score as an instant death
		_focal = CreatureData.new()
		_focal.alive = false
	_tick = 0
	_shape = 0.0
	_prev_d = -1.0
	_prev_tile = Vector2i(-1, -1)
	_prev_prey = null

func _end_eval() -> void:
	var f := 100.0 * float(_focal.age) / ticks + 40.0 * _focal.offspring + _shape
	if _focal.alive:
		f += 0.5 * _focal.energy
	_acc += f
	_seed_i += 1
	_prev_prey = null
	_sim.release()
	_sim = null
	_focal = null
	_tick = 0
	var n_seeds := SEEDS if _phase < 2 else MEASURE_SEEDS
	if _seed_i >= n_seeds:
		var score := _acc / n_seeds
		_acc = 0.0
		_seed_i = 0
		_on_candidate_done(score)

func _on_candidate_done(score: float) -> void:
	if _phase < 2:
		_fit[_cand] = score
		_cand += 1
		progress = (float(_species * GENS + _gen) + float(_cand) / POP) / (2.0 * GENS)
		if _cand >= POP:
			_next_gen()
	else:
		_meas[_species][_measure_kind] = score
		_measure_kind += 1
		if _measure_kind > 2:
			_measure_kind = 0
			_species += 1
			if _species > 1:
				_finalize()

func _next_gen() -> void:
	var order := range(POP)
	order.sort_custom(func(a, b): return _fit[a] > _fit[b])
	var mean := 0.0
	for v in _fit:
		mean += v
	print("TRAIN species=%s gen=%d best=%.1f mean=%.1f" % [_name(_species), _gen, _fit[order[0]], mean / POP])
	_gen += 1
	if _gen >= GENS:
		if _species == 0:
			champ_herb = _pop[order[0]]
			_species = 1
			_gen = 0
			_cand = 0
			_new_pop()
		else:
			champ_pred = _pop[order[0]]
			_phase = 2
			_species = 0
			_gen = 0
	else:
		var next := []
		for k in ELITE:
			next.append(_pop[order[k]])
		while next.size() < POP:
			next.append(_brains.mutate_brain(next[_rng.randi() % ELITE], _rng))
		_pop = next
		_cand = 0

func _name(sp: int) -> String:
	return "herb" if sp == 0 else "pred"

func _finalize() -> void:
	var lines := ["TRAIN MEASURE  species | evolved | random | reflex"]
	for s in 2:
		lines.append("               %s    | %7.1f | %6.1f | %6.1f" % [_name(s), _meas[s][0], _meas[s][1], _meas[s][2]])
	report = "\n".join(lines)
	print(report)
	var err := ChampionStore.save(champ_herb, champ_pred, report)
	print("TRAIN DONE — champions saved to %s (err=%d)" % [ChampionStore.absolute_path(), err])
	progress = 1.0
	_brains.release()
	done = true
