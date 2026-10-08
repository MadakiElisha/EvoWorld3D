class_name BrainTrainer
extends RefCounted
## Random-start neuroevolution vs reflex baseline. Incremental: step() per frame.

const POP := 16
const GENS := 20
const TICKS := 500
const SEEDS := 4
const TICKS_PER_STEP := 1500

var sim_template: Simulation
var done := false

var _phase := 0
var _species := 0
var _pop: Array = []
var _fit: Array = []
var _gen := 0
var _cand := 0
var _seed_i := 0
var _tick := 0
var _sim: Simulation = null
var _acc := 0.0
var _start_energy := 0.0
var _champ: Array = [PackedFloat32Array(), PackedFloat32Array()]
var _measure_kind := 0
var _meas := [[0.0, 0.0, 0.0], [0.0, 0.0, 0.0]]

func _init(template: Simulation) -> void:
	sim_template = template
	_new_pop()

func _new_pop() -> void:
	_pop.clear()
	for i in POP:
		_pop.append(sim_template.make_random_brain())
	_fit.resize(POP)

func step() -> bool:
	if done:
		return false
	var budget := TICKS_PER_STEP
	while budget > 0 and not done:
		if _sim == null:
			_start_eval()
		_sim.tick()
		_tick += 1
		budget -= 1
		if _tick >= TICKS:
			_end_eval()
	return not done

func _current_brain():
	if _phase == 2:
		match _measure_kind:
			0: return _champ[_species]
			1: return sim_template.make_random_brain()
			_: return null
	return _pop[_cand]

func _spawn(sim: Simulation, sp: int, brain) -> CreatureData:
	for t in 60:
		var x := randi_range(2, sim.world.width - 3)
		var z := randi_range(2, sim.world.depth - 3)
		if sim.world.is_walkable(x, z):
			var c := sim.make_creature(x + 0.5, z + 0.5, null)
			c.species = sp
			c.energy = 70.0
			c.speed = 1.6 if sp == 1 else 1.2
			c.sense = 2.0
			if brain == null:
				c.use_brain = false
			else:
				c.use_brain = true
				c.brain = brain
			sim.creatures.append(c)
			return c
	return null

func _start_eval() -> void:
	var w := WorldData.new(32, 32, 700 + _seed_i * 13, 6)
	_sim = Simulation.new(w)
	_sim.creatures.clear()
	if _species == 0:
		for i in 3:
			_spawn(_sim, 1, null)
		var h := _spawn(_sim, 0, _current_brain())
		_start_energy = h.energy if h != null else 70.0
	else:
		for i in 6:
			_spawn(_sim, 0, null)
		_spawn(_sim, 1, _current_brain())
	_tick = 0

func _end_eval() -> void:
	var f := 0.0
	var focal: CreatureData = null
	for c in _sim.creatures:
		if c.species == _species:
			focal = c
			break
	if focal != null and focal.alive:
		f = (focal.energy - 70.0) + 40.0
	else:
		f = -60.0
	_acc += f
	_seed_i += 1
	_sim = null
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
	print("TRAIN species=%d gen=%d best=%.1f" % [_species, _gen, _fit[order[0]]])
	_gen += 1
	if _gen >= GENS:
		_champ[_species] = _pop[order[0]]
		if _species == 0:
			_species = 1
			_gen = 0
			_cand = 0
			_new_pop()
		else:
			_phase = 2
			_species = 0
	else:
		var next := []
		for k in 4:
			next.append(_pop[order[k]])
		while next.size() < POP:
			next.append(sim_template.mutate_brain(next[randi() % 4]))
		_pop = next
		_cand = 0

func _finalize() -> void:
	print("TRAIN MEASURE  species | evolved | random | reflex")
	for s in 2:
		print("               %d       | %7.1f | %6.1f | %6.1f" % [s, _meas[s][0], _meas[s][1], _meas[s][2]])
	sim_template.champ_herb = _champ[0]
	sim_template.champ_pred = _champ[1]
	print("TRAIN DONE — champions injected. Press B in a new world.")
	done = true
