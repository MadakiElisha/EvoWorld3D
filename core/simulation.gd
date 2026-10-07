class_name Simulation
extends RefCounted
## Headless ecosystem: plants, herbivores, predators, evolution.
## Pure logic and knobs. No nodes, no rendering, no printing.
##
## Predation follows the standard Holling cycle:
##   encounter (movement) -> strike (PROBABILISTIC) -> handling (cooldown) -> conversion (energy)
## The stochastic strike is the stability core: capture chance responds
## smoothly to trait ratios, instead of flipping between "always catch"
## and "never catch" like a deterministic chase.

# ---------------------------------------------------------------------------
# PARAMETERS
# ---------------------------------------------------------------------------

# --- plants ---
var food_regrow := 0.012
var forest_regrow_mult := 0.65
var food_max := 1.0

# --- population ---
var start_herbs := 160
var start_preds := 20
var max_pop := 700

# --- herbivores ---
var eat_gain := 18.0
var metabolism_cost := 0.6
var move_cost := 0.25
var repro_energy := 110.0
var repro_age := 40
var max_age := 600
var mutation := 0.08
var herb_baby_energy := 25.0

# --- fear and stamina ---
var fear_energy := 60.0
var panic_cost := 0.9
var panic_speed_mult := 1.15
var vigilance_graze_penalty := 0.5   # head-up grazers get half a mouthful

# --- predators ---
var pred_repro_energy := 140.0
var pred_repro_age := 60
var pred_baby_energy := 70.0
var pred_kill_fraction := 0.45
var pred_kill_gain := 15.0
var pred_strike_range := 2.4
var pred_cooldown := 20
var pred_miss_cooldown := 6
var pred_body_mult := 1.0
var pred_leg_mult := 1.2
var pred_innate_speed := 1.5
var pred_innate_sense := 2.0
var pred_hunt_mult := 1.5
var pred_step_mult := 1.3
var pred_rival_cost := 0.35
var pred_rival_radius := 2.5
var pred_breed_max_rivals := 1   # territorial: no breeding when the neighborhood is full
var scan_interval := 4

# --- ambush / vigilance ---
var ambush_p := 0.85
var alert_memory := 30

# ---------------------------------------------------------------------------
# STATE
# ---------------------------------------------------------------------------

var world: WorldData
var creatures: Array[CreatureData] = []
var food: PackedFloat32Array
var tick_count := 0

var _herbs: Array[CreatureData] = []
var _preds: Array[CreatureData] = []

# Measurement window counters (consumed by window_stats())
var _w_kills := 0
var _w_attempts := 0
var _w_pred_births := 0
var _w_pred_deaths := 0
var _w_ambush := 0


func _init(p_world: WorldData) -> void:
	world = p_world
	food = PackedFloat32Array()
	food.resize(world.width * world.depth)
	seed_food()
	spawn_initial()

func seed_food() -> void:
	for x in world.width:
		for z in world.depth:
			var b := world.biomes[x * world.depth + z]
			if b == WorldData.Biome.GRASS:
				food[world.idx(x, z)] = randf_range(0.3, 1.0)
			elif b == WorldData.Biome.FOREST:
				food[world.idx(x, z)] = randf_range(0.5, 1.0)

func spawn_initial() -> void:
	var tries := 0
	var herbs := 0
	while herbs < start_herbs and tries < start_herbs * 50:
		tries += 1
		var x := randi_range(0, world.width - 1)
		var z := randi_range(0, world.depth - 1)
		if world.is_walkable(x, z):
			creatures.append(make_creature(x + 0.5, z + 0.5, null))
			herbs += 1
	tries = 0
	var preds := 0
	while preds < start_preds and tries < start_preds * 100:
		tries += 1
		var x := randi_range(0, world.width - 1)
		var z := randi_range(0, world.depth - 1)
		if world.is_walkable(x, z):
			var c := make_creature(x + 0.5, z + 0.5, null)
			c.species = CreatureData.Species.PRED
			c.energy = 80.0
			c.speed = pred_innate_speed
			c.sense = pred_innate_sense
			creatures.append(c)
			preds += 1

func make_creature(px: float, pz: float, parent: CreatureData) -> CreatureData:
	var c := CreatureData.new()
	c.x = px
	c.z = pz
	c.wander_angle = randf() * TAU
	if parent != null:
		c.species = parent.species
		c.speed = mutate(parent.speed)
		c.sense = mutate(parent.sense)
		c.metabolism = mutate(parent.metabolism)
		c.energy = pred_baby_energy if parent.species == CreatureData.Species.PRED else herb_baby_energy
	return c

func make_baby(parent: CreatureData) -> CreatureData:
	var bx := clampf(parent.x + randf_range(-0.7, 0.7), 0.5, world.width - 0.5)
	var bz := clampf(parent.z + randf_range(-0.7, 0.7), 0.5, world.depth - 0.5)
	if not world.is_walkable(int(floor(bx)), int(floor(bz))):
		bx = parent.x
		bz = parent.z
	return make_creature(bx, bz, parent)

func mutate(v: float) -> float:
	return clampf(v + randf_range(-mutation, mutation), 0.2, 3.0)

func counts() -> Vector2i:
	var h := 0
	var p := 0
	for c in creatures:
		if c.species == CreatureData.Species.HERB:
			h += 1
		else:
			p += 1
	return Vector2i(h, p)

func gene_averages(species: int) -> Vector3:
	var s := Vector3.ZERO
	var n := 0
	for c in creatures:
		if c.species == species:
			s += Vector3(c.speed, c.sense, c.metabolism)
			n += 1
	if n == 0:
		return Vector3.ZERO
	return s / n
	
func _rebuild_caches() -> void:
	_herbs.clear()
	_preds.clear()
	for c in creatures:
		if c.species == CreatureData.Species.HERB:
			_herbs.append(c)
		else:
			_preds.append(c)

## Predation internals for the last 500-tick window; resets on read.
func window_stats() -> String:
	var p := float(_w_kills) / maxf(float(_w_attempts), 1.0)
	var s := "kills=%d att=%d p=%.2f amb=%d pb=%d pd=%d" % [_w_kills, _w_attempts, p, _w_ambush, _w_pred_births, _w_pred_deaths]
	_w_ambush = 0
	_w_kills = 0
	_w_attempts = 0
	_w_pred_births = 0
	_w_pred_deaths = 0
	return s

# ---------------------------------------------------------------------------
# TICK: named phases, in order
# ---------------------------------------------------------------------------

func tick() -> void:
	tick_count += 1
	_rebuild_caches()
	_regrow_plants()
	var babies: Array[CreatureData] = []
	for c in creatures:
		_age_and_burn(c)
		_act(c)
		_feed(c)
		_reproduce(c, babies)
		_check_death(c)
	_survive_and_birth(babies)

func _regrow_plants() -> void:
	for i in food.size():
		if food[i] < food_max:
			var b := world.biomes[i]
			if b == WorldData.Biome.GRASS:
				food[i] = minf(food_max, food[i] + food_regrow)
			elif b == WorldData.Biome.FOREST:
				food[i] = minf(food_max, food[i] + food_regrow * forest_regrow_mult)

func _age_and_burn(c: CreatureData) -> void:
	c.age += 1
	if c.cooldown > 0:
		c.cooldown -= 1
	var body_mult := pred_body_mult if c.species == CreatureData.Species.PRED else 1.0
	c.energy -= metabolism_cost * c.metabolism * body_mult
	c.energy -= 0.05 * c.sense * c.sense * body_mult
	if c.species == CreatureData.Species.PRED:
		c.energy -= pred_rival_cost * _rival_count(c)

func _rival_count(c: CreatureData) -> int:
	var n := 0
	for o in _preds:
		if o == c or o.species != CreatureData.Species.PRED or not o.alive:
			continue
		var dx := o.x - c.x
		var dz := o.z - c.z
		if dx * dx + dz * dz < pred_rival_radius * pred_rival_radius:
			n += 1
	return n

func _act(c: CreatureData) -> void:
	var moved := step_creature(c)
	if moved > 0:
		var leg_mult := pred_leg_mult if c.species == CreatureData.Species.PRED else 1.0
		c.energy -= move_cost * c.metabolism * c.speed * c.speed * leg_mult
	if moved == 2:
		c.energy -= panic_cost
	if c.species == CreatureData.Species.PRED and c.cooldown <= 0:
		_try_strike(c)

func _feed(c: CreatureData) -> void:
	if c.species != CreatureData.Species.HERB:
		return
	var tx := int(floor(c.x))
	var tz := int(floor(c.z))
	if not world.in_bounds(tx, tz):
		return
	var i := world.idx(tx, tz)
	if food[i] <= 0.05:
		return
	var bite := minf(food[i], 0.25 + 0.35 * c.metabolism)
	if c.alert_ticks > 0:
		bite *= vigilance_graze_penalty
	food[i] -= bite
	c.energy += bite * eat_gain * minf(1.0, c.metabolism * c.metabolism)

func _reproduce(c: CreatureData, babies: Array[CreatureData]) -> void:
	var is_pred := c.species == CreatureData.Species.PRED
	var repro_e := pred_repro_energy if is_pred else repro_energy
	var repro_a := pred_repro_age if is_pred else repro_age
	var crowded := is_pred and _rival_count(c) > pred_breed_max_rivals
	if c.energy > repro_e and c.age > repro_a and not crowded:
		c.energy *= 0.5
		babies.append(make_baby(c))
		if is_pred:
			_w_pred_births += 1

func _check_death(c: CreatureData) -> void:
	if c.energy <= 0.0 or c.age > max_age:
		c.alive = false
		if c.species == CreatureData.Species.PRED:
			_w_pred_deaths += 1

func _survive_and_birth(babies: Array[CreatureData]) -> void:
	var survivors: Array[CreatureData] = []
	for c in creatures:
		if c.alive:
			survivors.append(c)
	creatures = survivors
	if creatures.size() < max_pop:
		creatures.append_array(babies)

# ---------------------------------------------------------------------------
# MOVEMENT AND BEHAVIOR
# ---------------------------------------------------------------------------

## Returns 0 = stayed, 1 = moved, 2 = moved while fleeing.
func step_creature(c: CreatureData) -> int:
	var desired := Vector2.ZERO
	var fleeing := false

	if c.species == CreatureData.Species.HERB:
		var safe := world.biome_at(int(floor(c.x)), int(floor(c.z))) == WorldData.Biome.FOREST
		var desperate := c.energy < fear_energy
		if c.scan_timer <= 0:
			c.scan_timer = scan_interval
			c.threat = null if safe else nearest_predator(c, 1.8 if desperate else c.sense + 0.5)
		else:
			c.scan_timer -= 1
			if c.threat != null and (not c.threat.alive or safe):
				c.threat = null
		if c.threat != null:
			c.alert_ticks = alert_memory
			desired = Vector2(c.x - c.threat.x, c.z - c.threat.z)
			fleeing = true
		else:
			if c.alert_ticks > 0:
				c.alert_ticks -= 1
			desired = seek_food(c)
			if desired == Vector2.ZERO:
				c.wander_angle += randf_range(-0.6, 0.6)
				desired = Vector2(cos(c.wander_angle), sin(c.wander_angle))
	else:
		if c.scan_timer <= 0:
			c.scan_timer = scan_interval
			c.target = nearest_prey(c, c.sense * pred_hunt_mult)
		else:
			c.scan_timer -= 1
			if c.target != null and (not c.target.alive or world.biome_at(int(floor(c.target.x)), int(floor(c.target.z))) == WorldData.Biome.FOREST):
				c.target = null
		if c.target != null:
			desired = Vector2(c.target.x - c.x, c.target.z - c.z)
		else:
			c.wander_angle += randf_range(-0.6, 0.6)
			desired = Vector2(cos(c.wander_angle), sin(c.wander_angle))

	if desired.length_squared() < 0.0001:
		return 0
	desired = desired.normalized()

	var step_len := 0.3 * c.speed
	if c.species == CreatureData.Species.PRED:
		step_len *= pred_step_mult
	if fleeing:
		step_len *= panic_speed_mult

	var nx := c.x + desired.x * step_len
	var nz := c.z + desired.y * step_len
	var ntx := int(floor(nx))
	var ntz := int(floor(nz))
	var blocked := not world.is_walkable(ntx, ntz)
	if not blocked and c.species == CreatureData.Species.PRED:
		blocked = world.biome_at(ntx, ntz) == WorldData.Biome.FOREST
	if not blocked:
		c.x = nx
		c.z = nz
		c.heading = atan2(desired.x, desired.y)
		return 2 if fleeing else 1
	return 0

func seek_food(c: CreatureData) -> Vector2:
	var tx := int(floor(c.x))
	var tz := int(floor(c.z))
	var r := int(ceil(c.sense))
	var best_d := 1000000.0
	var best_pos := Vector2.ZERO
	for dx in range(-r, r + 1):
		for dz in range(-r, r + 1):
			var nx := tx + dx
			var nz := tz + dz
			if not world.in_bounds(nx, nz):
				continue
			if food[world.idx(nx, nz)] > 0.15:
				var d := dx * dx + dz * dz
				if d < best_d:
					best_d = d
					best_pos = Vector2(nx + 0.5, nz + 0.5)
	if best_d > 999999.0:
		return Vector2.ZERO
	return best_pos - Vector2(c.x, c.z)

# ---------------------------------------------------------------------------
# PREDATION: encounter -> strike -> handling -> conversion
# ---------------------------------------------------------------------------

func nearest_predator(c: CreatureData, radius: float) -> CreatureData:
	var best: CreatureData = null
	var best_d := radius * radius
	for o in _preds:
		if o.species != CreatureData.Species.PRED or not o.alive:
			continue
		var dx := o.x - c.x
		var dz := o.z - c.z
		var d := dx * dx + dz * dz
		if d < best_d:
			best_d = d
			best = o
	return best

func nearest_prey(c: CreatureData, radius: float) -> CreatureData:
	var best: CreatureData = null
	var best_d := radius * radius
	for o in _herbs:
		if o.species != CreatureData.Species.HERB or not o.alive:
			continue
		if world.biome_at(int(floor(o.x)), int(floor(o.z))) == WorldData.Biome.FOREST:
			continue  # canopy hides them; hunters work the open ground
		var dx := o.x - c.x
		var dz := o.z - c.z
		var d := dx * dx + dz * dz
		if d < best_d:
			best_d = d
			best = o
	return best

func _try_strike(c: CreatureData) -> void:
	var prey := nearest_prey(c, pred_strike_range)
	if prey == null:
		return
	var dx := prey.x - c.x
	var dz := prey.z - c.z
	var d := sqrt(dx * dx + dz * dz)
	var prox := clampf(1.0 - 0.5 * d / pred_strike_range, 0.0, 1.0)
	_w_attempts += 1
	var p: float
	if prey.alert_ticks <= 0:
		p = ambush_p * prox                    # ambush: head-down grazer, speed irrelevant
		_w_ambush += 1
	else:
		p = capture_probability(c, prey) * prox  # chase: the speed ratio decides
	if randf() < p:
		_kill(c, prey)
	else:
		_escape_burst(prey, c)
		prey.alert_ticks = alert_memory        # a missed lunge puts prey on high alert
		c.cooldown = pred_miss_cooldown

## Smooth functional response: the stability core.
## r = predator effective speed / fleeing prey effective speed.
## p slides from 0.05 (r=0.75) through 0.5 (r=1.0) to 0.95 (r=1.25).
func capture_probability(pred: CreatureData, prey: CreatureData) -> float:
	var pred_eff := pred.speed * pred_step_mult
	var prey_eff := prey.speed * panic_speed_mult
	var r := pred_eff / maxf(prey_eff, 0.01)
	return clampf(0.55 + 1.4 * (r - 1.0), 0.20, 0.95)

func _kill(pred: CreatureData, prey: CreatureData) -> void:
	pred.energy += prey.energy * pred_kill_fraction + pred_kill_gain
	prey.alive = false
	pred.cooldown = pred_cooldown
	_w_kills += 1

func _escape_burst(prey: CreatureData, pred: CreatureData) -> void:
	var away := Vector2(prey.x - pred.x, prey.z - pred.z)
	if away.length_squared() < 0.0001:
		away = Vector2.RIGHT
	away = away.normalized().rotated(randf_range(-0.7, 0.7))
	for reach in [2.0, 1.2, 0.6]:
		var nx := clampf(prey.x + away.x * reach, 0.5, world.width - 0.5)
		var nz := clampf(prey.z + away.y * reach, 0.5, world.depth - 0.5)
		if world.is_walkable(int(floor(nx)), int(floor(nz))):
			prey.x = nx
			prey.z = nz
			break
	prey.energy -= 4.0

func spawn_herbs(n: int) -> void:
	for i in n:
		var donor: CreatureData = null
		if _herbs.size() > 0:
			donor = _herbs[randi() % _herbs.size()]
		for t in 50:
			var x := randi_range(0, world.width - 1)
			var z := randi_range(0, world.depth - 1)
			if world.is_walkable(x, z):
				var c := make_creature(x + 0.5, z + 0.5, donor)
				c.energy = 60.0
				c.age = randi_range(0, 200)
				creatures.append(c)
				break

func spawn_preds(n: int) -> void:
	for i in n:
		var donor: CreatureData = null
		if _preds.size() > 0:
			donor = _preds[randi() % _preds.size()]
		for t in 50:
			var x := randi_range(0, world.width - 1)
			var z := randi_range(0, world.depth - 1)
			if world.is_walkable(x, z) and world.biome_at(x, z) != WorldData.Biome.FOREST:
				var c := make_creature(x + 0.5, z + 0.5, donor)
				c.species = CreatureData.Species.PRED
				c.energy = 80.0
				c.age = randi_range(0, 200)
				if donor == null:
					# captive-bred stock: matched to current prey, not naive defaults
					c.speed = clampf(gene_averages(CreatureData.Species.HERB).x * 0.95, 0.2, 3.0)
					c.sense = 2.0
				creatures.append(c)
				break

func cull_preds(fraction: float) -> void:
	var targets: Array[CreatureData] = []
	for c in creatures:
		if c.species == CreatureData.Species.PRED:
			targets.append(c)
	targets.shuffle()
	for i in int(targets.size() * fraction):
		targets[i].alive = false

func cull_herbs(fraction: float) -> void:
	var targets: Array[CreatureData] = []
	for c in creatures:
		if c.species == CreatureData.Species.HERB:
			targets.append(c)
	targets.shuffle()
	for i in int(targets.size() * fraction):
		targets[i].alive = false
