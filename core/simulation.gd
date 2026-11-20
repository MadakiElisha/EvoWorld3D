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
##
## Determinism: every random draw goes through `rng`, so the same world seed +
## sim seed + inputs always replays the same history.

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
var pred_step_mult := 1.3          # predators cover 30% more ground per step (capture_probability assumes this)
var pred_forest_blocked := true    # canopy is a refuge: predators cannot enter forest tiles
var pred_rival_cost := 0.35
var pred_rival_radius := 2.5
var pred_breed_max_rivals := 1   # territorial: no breeding when the neighborhood is full
var scan_interval := 4

# --- ambush / vigilance ---
var ambush_p := 0.85
var alert_memory := 30

# --- movement / brains ---
var step_scale := 0.3
var turn_rate := 0.35
var neuron_cost := 0.004

const NRAYS := 5
const B_IN := NRAYS * 3 + 2        # per ray: food/prey, threat, wall  + energy + bias
const B_HID := 12
const B_OUT := 3                   # turn, throttle, sprint
const BRAIN_SIZE := B_IN * B_HID + B_HID + B_HID * B_OUT + B_OUT

var brain_mode := 0   # 0 = hand-written reflexes, 1 = evolved neural net
var champ_herb := PackedFloat32Array()
var champ_pred := PackedFloat32Array()

# ---------------------------------------------------------------------------
# STATE
# ---------------------------------------------------------------------------

var world: WorldData
var rng := RandomNumberGenerator.new()
var sim_seed := 0
var creatures: Array[CreatureData] = []
var food: PackedFloat32Array
var tick_count := 0

var _herbs: Array[CreatureData] = []
var _preds: Array[CreatureData] = []

# Spatial hash: CELL x CELL tiles per bucket, one grid per species.
const CELL := 4
var _gw := 0
var _gd := 0
var _herb_cells: Array = []
var _pred_cells: Array = []

# Measurement window counters (consumed by window_stats())
var _w_kills := 0
var _w_attempts := 0
var _w_pred_births := 0
var _w_pred_deaths := 0
var _w_ambush := 0


## p_seed < 0 derives the sim seed from the world seed (same island = same history).
## p_populate = false leaves the world empty so callers can set knobs/champions first,
## then call populate().
func _init(p_world: WorldData, p_seed: int = -1, p_populate: bool = true) -> void:
	world = p_world
	sim_seed = p_seed if p_seed >= 0 else world.world_seed
	rng.seed = hash(sim_seed)
	food = PackedFloat32Array()
	food.resize(world.width * world.depth)
	_gw = ceili(world.width / float(CELL))
	_gd = ceili(world.depth / float(CELL))
	_herb_cells.resize(_gw * _gd)
	_pred_cells.resize(_gw * _gd)
	for i in _gw * _gd:
		_herb_cells[i] = []
		_pred_cells[i] = []
	if p_populate:
		populate()

## Drop every creature reference (call before discarding a Simulation).
func release() -> void:
	for c in creatures:
		c.threat = null
		c.target = null
	creatures.clear()
	_herbs.clear()
	_preds.clear()
	for i in _herb_cells.size():
		_herb_cells[i].clear()
		_pred_cells[i].clear()

func populate() -> void:
	seed_food()
	spawn_initial()

# ---------------------------------------------------------------------------
# BRAINS
# ---------------------------------------------------------------------------

func make_random_brain(r: RandomNumberGenerator = null) -> PackedFloat32Array:
	var g: RandomNumberGenerator = r if r != null else rng
	var w := PackedFloat32Array()
	w.resize(BRAIN_SIZE)
	for i in w.size():
		w[i] = g.randf_range(-1.0, 1.0)
	return w

func mutate_brain(src: PackedFloat32Array, r: RandomNumberGenerator = null) -> PackedFloat32Array:
	var g: RandomNumberGenerator = r if r != null else rng
	var w := src.duplicate()
	for i in w.size():
		if g.randf() < 0.12:
			w[i] = clampf(w[i] + g.randf_range(-0.4, 0.4), -3.0, 3.0)
	return w

## A fresh brain for a creature with no parent: a mutated champion if one is loaded.
func _fresh_brain(sp: int) -> PackedFloat32Array:
	var champ := champ_herb if sp == CreatureData.Species.HERB else champ_pred
	if champ.size() == BRAIN_SIZE:
		return mutate_brain(champ)
	return make_random_brain()

## Re-seed every living creature's brain from the loaded champions.
func adopt_champions() -> void:
	for c in creatures:
		c.brain = _fresh_brain(c.species)

func brain_sense(c: CreatureData) -> PackedFloat32Array:
	var inp := PackedFloat32Array()
	inp.resize(B_IN)
	var max_len := c.sense * 2.0
	var is_herb := c.species == CreatureData.Species.HERB
	var target: CreatureData = nearest_predator(c, max_len) if is_herb else nearest_prey(c, max_len)
	if is_herb:
		# Same vigilance rule as the reflex herbivore: a close, visible predator puts it on alert.
		var safe := world.biome_at(int(floor(c.x)), int(floor(c.z))) == WorldData.Biome.FOREST
		c.threat = null
		if target != null and not safe:
			var tdx := target.x - c.x
			var tdz := target.z - c.z
			if tdx * tdx + tdz * tdz <= (c.sense + 0.5) * (c.sense + 0.5):
				c.threat = target
	for r in NRAYS:
		var ang := c.heading + deg_to_rad(-60.0 + 30.0 * r)
		var dx := sin(ang); var dz := cos(ang)
		var food_v := 0.0; var wall_v := 0.0
		var d := 0.5
		while d <= max_len:
			var tx := int(floor(c.x + dx * d)); var tz := int(floor(c.z + dz * d))
			if not can_enter(c.species, tx, tz):
				wall_v = 1.0 - d / max_len; break
			if is_herb and food_v == 0.0 and food[world.idx(tx, tz)] > 0.2:
				food_v = 1.0 - d / max_len
			d += 0.5
		var other_v := 0.0
		if target != null:
			var ta := atan2(target.x - c.x, target.z - c.z)
			if absf(wrapf(ta - ang, -PI, PI)) < deg_to_rad(18.0):
				other_v = clampf(1.0 - Vector2(target.x - c.x, target.z - c.z).length() / max_len, 0.0, 1.0)
		inp[r * 3 + 0] = food_v if is_herb else other_v
		inp[r * 3 + 1] = other_v if is_herb else 0.0
		inp[r * 3 + 2] = wall_v
	inp[NRAYS * 3 + 0] = clampf(c.energy / 150.0, 0.0, 1.0) * 2.0 - 1.0
	inp[NRAYS * 3 + 1] = 1.0
	return inp

## Returns (turn in -1..1, throttle in 0..1); writes sprint to c.sprint_out.
func brain_think(c: CreatureData) -> Vector2:
	var inp := brain_sense(c)
	var w := c.brain
	var h := PackedFloat32Array()
	h.resize(B_HID)
	var hb := B_IN * B_HID
	for j in B_HID:
		var s := w[hb + j]
		for i in B_IN:
			s += inp[i] * w[i * B_HID + j]
		h[j] = tanh(s)
	var ob := hb + B_HID
	var bb := ob + B_HID * B_OUT
	var out := PackedFloat32Array([0.0, 0.0, 0.0])
	for k in B_OUT:
		var s := w[bb + k]
		for j in B_HID:
			s += h[j] * w[ob + j * B_OUT + k]
		out[k] = tanh(s)
	c.sprint_out = out[2]
	return Vector2(out[0], (out[1] + 1.0) * 0.5)

func reflex_control(c: CreatureData) -> Vector3:
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
				c.wander_angle += rng.randf_range(-0.6, 0.6)
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
			c.wander_angle += rng.randf_range(-0.6, 0.6)
			desired = Vector2(cos(c.wander_angle), sin(c.wander_angle))
	return Vector3(desired.x, desired.y, 1.0 if fleeing else 0.0)

# ---------------------------------------------------------------------------
# SETUP AND SPAWNING
# ---------------------------------------------------------------------------

func seed_food() -> void:
	for x in world.width:
		for z in world.depth:
			var b := world.biomes[world.idx(x, z)]
			if b == WorldData.Biome.GRASS:
				food[world.idx(x, z)] = rng.randf_range(0.3, 1.0)
			elif b == WorldData.Biome.FOREST:
				food[world.idx(x, z)] = rng.randf_range(0.5, 1.0)

## Movement rule shared by brains, reflexes, spawning and escapes.
func can_enter(sp: int, tx: int, tz: int) -> bool:
	if not world.in_bounds(tx, tz):
		return false
	var b := world.biome_at(tx, tz)
	if b == WorldData.Biome.WATER:
		return false
	if sp == CreatureData.Species.PRED and pred_forest_blocked and b == WorldData.Biome.FOREST:
		return false
	return true

func _random_tile_for(sp: int, tries: int) -> Vector2i:
	for t in tries:
		var x := rng.randi_range(0, world.width - 1)
		var z := rng.randi_range(0, world.depth - 1)
		if can_enter(sp, x, z):
			return Vector2i(x, z)
	return Vector2i(-1, -1)

func spawn_initial() -> void:
	for i in start_herbs:
		var p := _random_tile_for(CreatureData.Species.HERB, 50)
		if p.x >= 0:
			creatures.append(make_creature(p.x + 0.5, p.y + 0.5, null, CreatureData.Species.HERB))
	for i in start_preds:
		var p := _random_tile_for(CreatureData.Species.PRED, 100)
		if p.x >= 0:
			var c := make_creature(p.x + 0.5, p.y + 0.5, null, CreatureData.Species.PRED)
			c.energy = 80.0
			c.speed = pred_innate_speed
			c.sense = pred_innate_sense
			creatures.append(c)

func make_creature(px: float, pz: float, parent: CreatureData, sp: int = CreatureData.Species.HERB) -> CreatureData:
	var c := CreatureData.new()
	c.x = px
	c.z = pz
	c.prev_x = px      # no lerp-from-origin streak on the first rendered frame
	c.prev_z = pz
	c.wander_angle = rng.randf() * TAU
	c.heading = rng.randf_range(-PI, PI)
	c.use_brain = brain_mode == 1
	if parent != null:
		c.species = parent.species
		c.speed = mutate(parent.speed)
		c.sense = mutate(parent.sense)
		c.metabolism = mutate(parent.metabolism)
		c.energy = pred_baby_energy if parent.species == CreatureData.Species.PRED else herb_baby_energy
		c.brain = mutate_brain(parent.brain) if parent.brain.size() == BRAIN_SIZE else _fresh_brain(c.species)
	else:
		c.species = sp
		c.brain = _fresh_brain(sp)
	return c

func make_baby(parent: CreatureData) -> CreatureData:
	var bx := clampf(parent.x + rng.randf_range(-0.7, 0.7), 0.5, world.width - 0.5)
	var bz := clampf(parent.z + rng.randf_range(-0.7, 0.7), 0.5, world.depth - 0.5)
	if not can_enter(parent.species, int(floor(bx)), int(floor(bz))):
		bx = parent.x
		bz = parent.z
	return make_creature(bx, bz, parent)

func mutate(v: float) -> float:
	return clampf(v + rng.randf_range(-mutation, mutation), 0.2, 3.0)

# ---------------------------------------------------------------------------
# QUERIES
# ---------------------------------------------------------------------------

func counts() -> Vector2i:
	var h := 0
	var p := 0
	for c in creatures:
		if not c.alive:
			continue
		if c.species == CreatureData.Species.HERB:
			h += 1
		else:
			p += 1
	return Vector2i(h, p)

func gene_averages(species: int) -> Vector3:
	var s := Vector3.ZERO
	var n := 0
	for c in creatures:
		if c.species == species and c.alive:
			s += Vector3(c.speed, c.sense, c.metabolism)
			n += 1
	if n == 0:
		return Vector3.ZERO
	return s / n

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
# SPATIAL GRID
# ---------------------------------------------------------------------------

func _cell_of(x: float, z: float) -> int:
	var cx := clampi(int(x) / CELL, 0, _gw - 1)
	var cz := clampi(int(z) / CELL, 0, _gd - 1)
	return cx * _gd + cz

func _cells_for(sp: int) -> Array:
	return _herb_cells if sp == CreatureData.Species.HERB else _pred_cells

func _rebuild_caches() -> void:
	_herbs.clear()
	_preds.clear()
	for i in _herb_cells.size():
		_herb_cells[i].clear()
		_pred_cells[i].clear()
	for c in creatures:
		if not c.alive:
			c.cell = -1
			continue
		c.cell = _cell_of(c.x, c.z)
		if c.species == CreatureData.Species.HERB:
			_herbs.append(c)
			_herb_cells[c.cell].append(c)
		else:
			_preds.append(c)
			_pred_cells[c.cell].append(c)

## Every position change inside a tick goes through here so the grid stays exact.
func _relocate(c: CreatureData, nx: float, nz: float) -> void:
	c.x = nx
	c.z = nz
	if c.cell < 0:
		return
	var nc := _cell_of(nx, nz)
	if nc != c.cell:
		var cells := _cells_for(c.species)
		cells[c.cell].erase(c)
		cells[nc].append(c)
		c.cell = nc

## Nearest living member of `cells` within radius (excluding c). skip_forest hides canopy dwellers.
func _nearest_in(cells: Array, c: CreatureData, radius: float, skip_forest: bool) -> CreatureData:
	var best: CreatureData = null
	var best_d := radius * radius
	var r := ceili(radius / CELL)
	var cx := clampi(int(c.x) / CELL, 0, _gw - 1)
	var cz := clampi(int(c.z) / CELL, 0, _gd - 1)
	for gx in range(maxi(cx - r, 0), mini(cx + r, _gw - 1) + 1):
		for gz in range(maxi(cz - r, 0), mini(cz + r, _gd - 1) + 1):
			for o in cells[gx * _gd + gz]:
				if o == c or not o.alive:
					continue
				var dx: float = o.x - c.x
				var dz: float = o.z - c.z
				var d := dx * dx + dz * dz
				if d >= best_d:
					continue
				if skip_forest and world.biome_at(int(floor(o.x)), int(floor(o.z))) == WorldData.Biome.FOREST:
					continue  # canopy hides them; hunters work the open ground
				best_d = d
				best = o
	return best

func nearest_predator(c: CreatureData, radius: float) -> CreatureData:
	return _nearest_in(_pred_cells, c, radius, false)

func nearest_prey(c: CreatureData, radius: float) -> CreatureData:
	return _nearest_in(_herb_cells, c, radius, true)

func _rival_count(c: CreatureData) -> int:
	var n := 0
	var rr := pred_rival_radius * pred_rival_radius
	var r := ceili(pred_rival_radius / CELL)
	var cx := clampi(int(c.x) / CELL, 0, _gw - 1)
	var cz := clampi(int(c.z) / CELL, 0, _gd - 1)
	for gx in range(maxi(cx - r, 0), mini(cx + r, _gw - 1) + 1):
		for gz in range(maxi(cz - r, 0), mini(cz + r, _gd - 1) + 1):
			for o in _pred_cells[gx * _gd + gz]:
				if o == c or not o.alive:
					continue
				var dx: float = o.x - c.x
				var dz: float = o.z - c.z
				if dx * dx + dz * dz < rr:
					n += 1
	return n

# ---------------------------------------------------------------------------
# TICK: named phases, in order
# ---------------------------------------------------------------------------

func tick() -> void:
	tick_count += 1
	_rebuild_caches()
	_regrow_plants()
	var babies: Array[CreatureData] = []
	for c in creatures:
		if not c.alive:
			continue   # killed earlier this tick (or culled): no posthumous meals or births
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
	if c.use_brain:
		c.energy -= neuron_cost * B_HID

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
	if c.energy <= repro_e or c.age <= repro_a:
		return
	if creatures.size() + babies.size() >= max_pop:
		return   # world is full: no birth, and the parent keeps its energy
	if is_pred and _rival_count(c) > pred_breed_max_rivals:
		return   # territorial: no breeding when the neighborhood is full
	c.energy *= 0.5
	c.offspring += 1
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
		else:
			c.threat = null   # break threat/target reference cycles so dead creatures are freed
			c.target = null
	creatures = survivors
	creatures.append_array(babies)

# ---------------------------------------------------------------------------
# MOVEMENT AND BEHAVIOR
# ---------------------------------------------------------------------------

## Returns 0 = stayed, 1 = moved, 2 = moved while fleeing/sprinting.
func step_creature(c: CreatureData) -> int:
	c.prev_x = c.x
	c.prev_z = c.z
	var fleeing := false
	var sp := c.speed * step_scale
	if c.species == CreatureData.Species.PRED:
		sp *= pred_step_mult
	if c.use_brain and c.brain.size() == BRAIN_SIZE:
		var out := brain_think(c)
		fleeing = c.sprint_out > 0.5
		if c.threat != null and c.threat.alive:
			c.alert_ticks = alert_memory
		elif c.alert_ticks > 0:
			c.alert_ticks -= 1
		c.heading = wrapf(c.heading + out.x * turn_rate, -PI, PI)
		sp *= out.y
	else:
		var rc := reflex_control(c)
		fleeing = rc.z > 0.5
		if rc.x * rc.x + rc.y * rc.y < 0.0001:
			c.last_step = 0.0
			return 0
		c.heading = atan2(rc.x, rc.y)
	if fleeing:
		sp *= panic_speed_mult
	if sp <= 0.0001:
		c.last_step = 0.0
		return 0
	var nx := c.x + sin(c.heading) * sp
	var nz := c.z + cos(c.heading) * sp
	if not can_enter(c.species, int(floor(nx)), int(floor(nz))):
		c.last_step = 0.0
		return 0
	_relocate(c, nx, nz)
	c.last_step = sp
	c.distance_walked += sp
	return 2 if fleeing else 1

## Nearest food tile within a (2r+1)^2 square. Searches outward ring by ring and
## stops once no farther ring can beat the best hit. Ties break on the smallest
## (dx, dz), which is exactly what the old full-square scan returned.
func seek_food(c: CreatureData) -> Vector2:
	var tx := int(floor(c.x))
	var tz := int(floor(c.z))
	var r := int(ceil(c.sense))
	var w := world.width
	var dp := world.depth
	var best_d := 1 << 30
	var bdx := 0
	var bdz := 0
	for k in r + 1:
		for dx in range(-k, k + 1):
			var nx := tx + dx
			if nx < 0 or nx >= w:
				continue
			var edge := dx == -k or dx == k
			var dz := -k
			while dz <= k:
				var nz := tz + dz
				if nz >= 0 and nz < dp and food[nx * dp + nz] > 0.15:
					var d := dx * dx + dz * dz
					if d < best_d or (d == best_d and (dx < bdx or (dx == bdx and dz < bdz))):
						best_d = d
						bdx = dx
						bdz = dz
				dz += 1 if edge else 2 * k   # interior columns only touch the ring's top and bottom
				if k == 0:
					break
		if best_d < (k + 1) * (k + 1):
			break
	if best_d == 1 << 30:
		return Vector2.ZERO
	return Vector2(tx + bdx + 0.5, tz + bdz + 0.5) - Vector2(c.x, c.z)

# ---------------------------------------------------------------------------
# PREDATION: encounter -> strike -> handling -> conversion
# ---------------------------------------------------------------------------

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
	if rng.randf() < p:
		_kill(c, prey)
	else:
		_escape_burst(prey, c)
		prey.alert_ticks = alert_memory        # a missed lunge puts prey on high alert
		c.cooldown = pred_miss_cooldown

## Smooth functional response: the stability core.
## r = predator effective speed / fleeing prey effective speed.
## p slides from 0.20 (floor) through 0.55 (r=1.0) to 0.95 (r~1.29).
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
	away = away.normalized().rotated(rng.randf_range(-0.7, 0.7))
	for reach in [2.0, 1.2, 0.6]:
		var nx := clampf(prey.x + away.x * reach, 0.5, world.width - 0.5)
		var nz := clampf(prey.z + away.y * reach, 0.5, world.depth - 0.5)
		if can_enter(prey.species, int(floor(nx)), int(floor(nz))):
			_relocate(prey, nx, nz)
			break
	prey.energy -= 4.0

# ---------------------------------------------------------------------------
# GOD TOOLS (called between ticks)
# ---------------------------------------------------------------------------

## Returns how many were actually spawned (the population cap can limit it).
func spawn_herbs(n: int) -> int:
	_rebuild_caches()
	var made := 0
	for i in mini(n, max_pop - creatures.size()):
		var donor: CreatureData = null
		if _herbs.size() > 0:
			donor = _herbs[rng.randi() % _herbs.size()]
		var p := _random_tile_for(CreatureData.Species.HERB, 50)
		if p.x < 0:
			continue
		var c := make_creature(p.x + 0.5, p.y + 0.5, donor, CreatureData.Species.HERB)
		c.energy = 60.0
		c.age = rng.randi_range(0, 200)
		creatures.append(c)
		made += 1
	return made

func spawn_preds(n: int) -> int:
	_rebuild_caches()
	var made := 0
	for i in mini(n, max_pop - creatures.size()):
		var donor: CreatureData = null
		if _preds.size() > 0:
			donor = _preds[rng.randi() % _preds.size()]
		var p := _random_tile_for(CreatureData.Species.PRED, 50)
		if p.x < 0:
			continue
		var c := make_creature(p.x + 0.5, p.y + 0.5, donor, CreatureData.Species.PRED)
		c.energy = 80.0
		c.age = rng.randi_range(0, 200)
		if donor == null:
			# captive-bred stock: matched to current prey, not naive defaults
			c.speed = clampf(gene_averages(CreatureData.Species.HERB).x * 0.95, 0.2, 3.0)
			c.sense = 2.0
		creatures.append(c)
		made += 1
	return made

func cull_preds(fraction: float) -> int:
	return _cull(CreatureData.Species.PRED, fraction)

func cull_herbs(fraction: float) -> int:
	return _cull(CreatureData.Species.HERB, fraction)

func _cull(sp: int, fraction: float) -> int:
	var targets: Array[CreatureData] = []
	for c in creatures:
		if c.species == sp and c.alive:
			targets.append(c)
	# Fisher-Yates on the sim RNG (Array.shuffle() would use the global RNG)
	for i in range(targets.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var tmp := targets[i]
		targets[i] = targets[j]
		targets[j] = tmp
	var n := int(targets.size() * fraction)
	for i in n:
		targets[i].alive = false
	return n
