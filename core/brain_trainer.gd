class_name BrainTrainer
extends RefCounted
## Offline neuroevolution: one focal brain at a time in a small arena against
## reflex opponents, then a measurement pass (evolved vs random vs reflex).
## Incremental: call step(budget_ms) every frame, or step(INF) headless.
##
## Fitness is lifetime-based and always read from the candidate itself:
##   100 * (ticks survived / TICKS) + 0.5 * energy if alive + 40 * offspring
## Every candidate in a generation faces the same arenas (common random numbers),
## so differences in score come from the brain, not from luck.

const POP := 16
const ELITE := 4
const GENS := 20
const TICKS := 500
const SEEDS := 4

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
		if _tick >= TICKS or not _focal.alive:
			_end_eval()
	return not done

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
	if _species == 0:
		for i in 3:
			_spawn(_sim, CreatureData.Species.PRED, null)
		_focal = _spawn(_sim, CreatureData.Species.HERB, _current_brain())
	else:
		for i in 6:
			_spawn(_sim, CreatureData.Species.HERB, null)
		_focal = _spawn(_sim, CreatureData.Species.PRED, _current_brain())
	if _focal == null:   # arena had no room: score as an instant death
		_focal = CreatureData.new()
		_focal.alive = false
	_tick = 0

func _end_eval() -> void:
	var f := 100.0 * float(_focal.age) / TICKS + 40.0 * _focal.offspring
	if _focal.alive:
		f += 0.5 * _focal.energy
	_acc += f
	_seed_i += 1
	_sim.release()
	_sim = null
	_focal = null
	_tick = 0
	if _seed_i >= SEEDS:
		var score := _acc / SEEDS
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
