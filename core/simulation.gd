class_name Simulation
extends RefCounted
## Headless ecosystem. No nodes, no visuals. Pure rules.
## ALL balance knobs live at the top of this file.

var world: WorldData
var creatures: Array[CreatureData] = []
var food: PackedFloat32Array
var tick_count: int = 0

# --- World / plants ---
var food_regrow := 0.006
var forest_regrow_mult := 0.5
var food_max := 1.0

# --- Population ---
var start_herbs := 40
var start_preds := 8
var max_pop := 300

# --- Herbivores ---
var eat_gain := 18.0
var metabolism_cost := 0.6
var move_cost := 0.25
var repro_energy := 110.0
var repro_age := 40
var max_age := 600
var mutation := 0.15
var panic_cost := 0.3        # extra burn per tick while fleeing
var panic_speed_mult := 1.15 # flee sprint multiplier

# --- Predators: heavy, expensive, born hunters ---
var pred_repro_energy := 120.0
var herb_baby_energy := 25.0
var pred_baby_energy := 55.0
var pred_repro_age := 60
var pred_kill_gain := 15.0
var fear_energy := 50.0
var pred_rival_cost := 0.12
var pred_rival_radius := 2.5
var pred_kill_fraction := 0.5
var pred_catch_dist := 0.9
var pred_cooldown := 12
var pred_body_mult := 1.5
var pred_leg_mult := 1.2
var pred_innate_speed := 1.5
var pred_innate_sense := 2.0
var pred_hunt_mult := 1.5    # hunt radius = sense * this

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

func tick() -> void:
	tick_count += 1

	# Plants regrow
	for i in food.size():
		if food[i] < food_max:
			var b := world.biomes[i]
			if b == WorldData.Biome.GRASS:
				food[i] = minf(food_max, food[i] + food_regrow)
			elif b == WorldData.Biome.FOREST:
				food[i] = minf(food_max, food[i] + food_regrow * forest_regrow_mult)

	var babies: Array[CreatureData] = []
	for c in creatures:
		c.age += 1
		if c.cooldown > 0:
			c.cooldown -= 1

		# Energy costs, species-aware
		var body_mult := 1.0
		var leg_mult := 1.0
		if c.species == CreatureData.Species.PRED:
			body_mult = pred_body_mult
			leg_mult = pred_leg_mult

		c.energy -= metabolism_cost * c.metabolism * body_mult
		c.energy -= 0.05 * c.sense * c.sense * body_mult
		if c.species == CreatureData.Species.PRED:
			var rivals := 0
			for o in creatures:
				if o == c or o.species != CreatureData.Species.PRED:
					continue
				var dx := o.x - c.x
				var dz := o.z - c.z
				if dx * dx + dz * dz < pred_rival_radius * pred_rival_radius:
					rivals += 1
			c.energy -= pred_rival_cost * rivals

		var moved := step_creature(c)
		if moved > 0:
			c.energy -= move_cost * c.metabolism * c.speed * c.speed * leg_mult
		if moved == 2:
			c.energy -= panic_cost  # sprinting in fear is exhausting

		# Feeding
		if c.species == CreatureData.Species.HERB:
			var tx := int(floor(c.x))
			var tz := int(floor(c.z))
			if world.in_bounds(tx, tz):
				var fi := world.idx(tx, tz)
				if food[fi] > 0.05:
					var bite := minf(food[fi], 0.25 + 0.35 * c.metabolism)
					food[fi] -= bite
					var efficiency := minf(1.0, c.metabolism * c.metabolism)
					c.energy += bite * eat_gain * efficiency
		else:
			try_kill(c)

		# Reproduction
		var repro_e := repro_energy if c.species == CreatureData.Species.HERB else pred_repro_energy
		var repro_a := repro_age if c.species == CreatureData.Species.HERB else pred_repro_age
		if c.energy > repro_e and c.age > repro_a:
			c.energy *= 0.5
			babies.append(make_baby(c))

		# Death
		if c.energy <= 0.0 or c.age > max_age:
			c.alive = false

	var survivors: Array[CreatureData] = []
	for c in creatures:
		if c.alive:
			survivors.append(c)
	creatures = survivors

	if creatures.size() < max_pop:
		creatures.append_array(babies)

func make_baby(parent: CreatureData) -> CreatureData:
	var bx := clampf(parent.x + randf_range(-0.7, 0.7), 0.5, world.width - 0.5)
	var bz := clampf(parent.z + randf_range(-0.7, 0.7), 0.5, world.depth - 0.5)
	if not world.is_walkable(int(floor(bx)), int(floor(bz))):
		bx = parent.x
		bz = parent.z
	return make_creature(bx, bz, parent)

func nearest_predator(c: CreatureData, radius: float) -> CreatureData:
	var best: CreatureData = null
	var best_d := radius * radius
	for o in creatures:
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
	for o in creatures:
		if o.species != CreatureData.Species.HERB or not o.alive:
			continue
		if world.biome_at(int(floor(o.x)), int(floor(o.z))) == WorldData.Biome.FOREST:
			continue  # canopy hides them; hunters wait in the open
		var dx := o.x - c.x
		var dz := o.z - c.z
		var d := dx * dx + dz * dz
		if d < best_d:
			best_d = d
			best = o
	return best

func try_kill(c: CreatureData) -> void:
	if c.cooldown > 0:
		return
	var prey := nearest_prey(c, pred_catch_dist)
	if prey != null:
		c.energy += prey.energy * pred_kill_fraction + pred_kill_gain
		prey.alive = false
		c.cooldown = pred_cooldown

## Returns: 0 = stayed, 1 = moved, 2 = moved while fleeing
func step_creature(c: CreatureData) -> int:
	var desired := Vector2.ZERO
	var fleeing := false

	if c.species == CreatureData.Species.HERB:
		var safe := world.biome_at(int(floor(c.x)), int(floor(c.z))) == WorldData.Biome.FOREST
		var desperate := c.energy < fear_energy
		var threat: CreatureData = null
		if not safe and not desperate:
			threat = nearest_predator(c, c.sense + 0.5)
		if threat != null:
			desired = Vector2(c.x - threat.x, c.z - threat.z)
			fleeing = true
		else:
			desired = seek_food(c)
			if desired == Vector2.ZERO:
				c.wander_angle += randf_range(-0.6, 0.6)
				desired = Vector2(cos(c.wander_angle), sin(c.wander_angle))
	else:
		var prey := nearest_prey(c, c.sense * pred_hunt_mult)
		if prey != null:
			desired = Vector2(prey.x - c.x, prey.z - c.z)
		else:
			c.wander_angle += randf_range(-0.6, 0.6)
			desired = Vector2(cos(c.wander_angle), sin(c.wander_angle))

	if desired.length_squared() < 0.0001:
		return 0
	desired = desired.normalized()

	var step_len := 0.3 * c.speed
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
