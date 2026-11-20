extends Node3D
## Composition root: owns world + sim, paints both, runs the clock.

@export var width := 72
@export var depth := 72
@export var world_seed := 524274379   # a known-good island as the front door
@export var max_height := 8
@export var time_scale := 1

const CURATED_SEEDS := [524274379, 2655256772, 819918188]
const BASE_TPS := 8.0
const MAX_POP := 800                 # render capacity; must stay >= sim.max_pop
const SIM_BUDGET_MS := 12.0          # max wall time spent ticking per frame
const TOOL_BUDGET_MS := 6.0          # max wall time for the lab / trainer per frame

var curated_idx := 0
var outcome := ""                    # mirrored from judge for the HUD
var judge: RoundJudge

var world: WorldData
var sim: Simulation
var brain_mode := 0                  # survives restarts
var champ_herb := PackedFloat32Array()
var champ_pred := PackedFloat32Array()

var visual_root: Node3D
var creature_mm: MultiMesh
var head_mm: MultiMeshInstance3D
var ear_mm: MultiMeshInstance3D
var leg_mm: MultiMeshInstance3D
var tail_mm: MultiMeshInstance3D
var acc := 0.0
var actual_tps := 0.0
var _tps_ticks := 0
var _tps_time := 0.0
var lab: BalanceLab = null
var trainer: BrainTrainer = null
var fp_target: CreatureData = null
var pixel_noise: ImageTexture

var trunk_mm: MultiMeshInstance3D
var leaf_mm: MultiMeshInstance3D
var accent_mm: MultiMeshInstance3D
var rock_mm: MultiMeshInstance3D
var tuft_mm: MultiMeshInstance3D
var water_mm: MultiMeshInstance3D

func _ready() -> void:
	visual_root = Node3D.new()
	add_child(visual_root)
	pixel_noise = make_pixel_noise(8, 0.6, 1.0)
	_setup_atmosphere()
	var saved := ChampionStore.load_champions()
	if not saved.is_empty():
		champ_herb = saved.herb
		champ_pred = saved.pred
		print("Loaded trained champions from %s (saved %s). Press B to switch to brains." % [ChampionStore.absolute_path(), saved.get("saved_at", "?")])
	restart()

func _setup_atmosphere() -> void:
	var sun := get_node_or_null("DirectionalLight3D") as DirectionalLight3D
	if sun != null:
		sun.light_color = Color(1.0, 0.95, 0.85)
		sun.light_energy = 1.15
		sun.shadow_enabled = true
		sun.rotation_degrees = Vector3(-38, 0, 30)
	var we := get_node_or_null("WorldEnvironment") as WorldEnvironment
	if we != null and we.environment != null:
		var env := we.environment
		env.tonemap_mode = Environment.TONE_MAPPER_ACES
		env.fog_enabled = true
		env.fog_light_color = Color(0.7, 0.82, 0.95)
		env.fog_density = 0.002
		env.fog_sky_affect = false

func make_pixel_noise(size := 16, lo := 0.78, hi := 1.0) -> ImageTexture:
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	var r := RandomNumberGenerator.new()
	r.seed = 99
	for x in size:
		for y in size:
			var v := r.randf_range(lo, hi)
			img.set_pixel(x, y, Color(v, v, v, 1.0))
	return ImageTexture.create_from_image(img)

## Material-only pass. Safe to call after every rebuild: each material is styled once.
func _apply_pixel_look() -> void:
	var nodes: Array = []
	nodes.append_array(find_children("*", "MultiMeshInstance3D", true, false))
	nodes.append_array(find_children("*", "MeshInstance3D", true, false))
	for node in nodes:
		var mesh: Mesh = null
		if node is MultiMeshInstance3D and node.multimesh != null:
			mesh = node.multimesh.mesh
		elif node is MeshInstance3D:
			mesh = node.mesh
		if mesh == null:
			continue
		var mat := mesh.material as StandardMaterial3D
		if mat == null:
			mat = StandardMaterial3D.new()
			mesh.material = mat
		if mat.has_meta("pixel_look"):
			continue
		mat.set_meta("pixel_look", true)
		mat.albedo_texture = pixel_noise
		mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
		mat.vertex_color_use_as_albedo = true
		mat.albedo_color = mat.albedo_color.lerp(Color(0.55, 0.55, 0.55), 0.3)

func _new_multimesh(mesh: Mesh, count: int, colors: bool) -> MultiMeshInstance3D:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = colors            # must be set before instance_count
	mm.instance_count = count
	mm.visible_instance_count = 0
	mm.mesh = mesh
	var mi := MultiMeshInstance3D.new()
	mi.multimesh = mm
	return mi

func _box(size: Vector3, color: Color) -> BoxMesh:
	var bm := BoxMesh.new()
	bm.size = size
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	bm.material = mat
	return bm

func _make_prop_mesh(color: Color, cap: int) -> MultiMeshInstance3D:
	var mi := _new_multimesh(_box(Vector3.ONE, color), cap, true)
	add_child(mi)   # props persist across restarts; rebuilt in place by build_props()
	return mi

func build_props() -> void:
	if trunk_mm == null:
		trunk_mm = _make_prop_mesh(Color(0.35, 0.22, 0.12), 400)
		leaf_mm = _make_prop_mesh(Color(0.15, 0.5, 0.18), 800)
		accent_mm = _make_prop_mesh(Color(0.9, 0.4, 0.6), 400)
		rock_mm = _make_prop_mesh(Color(0.45, 0.45, 0.48), 300)
		tuft_mm = _make_prop_mesh(Color(0.4, 0.75, 0.3), 600)
		water_mm = _make_prop_mesh(Color(0.2, 0.5, 0.9), 2000)
		var wmat := water_mm.multimesh.mesh.material as StandardMaterial3D
		wmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		wmat.albedo_color = Color(0.2, 0.5, 0.9, 0.55)
	var rng := RandomNumberGenerator.new()
	rng.seed = world_seed
	var counts := {}
	for mi in [trunk_mm, leaf_mm, accent_mm, rock_mm, tuft_mm, water_mm]:
		counts[mi] = 0
	var put := func(mi: MultiMeshInstance3D, xf: Transform3D) -> void:
		var i: int = counts[mi]
		if i < mi.multimesh.instance_count:
			mi.multimesh.set_instance_transform(i, xf)
			var v := rng.randf_range(0.86, 1.08)
			mi.multimesh.set_instance_color(i, Color(v, v, v, 1.0))
			counts[mi] = i + 1
	for x in world.width:
		for z in world.depth:
			var b := world.biome_at(x, z)
			var wx := x - world.width / 2.0 + 0.5
			var wz := z - world.depth / 2.0 + 0.5
			var y := world.height_at(x, z)
			if b == WorldData.Biome.WATER:
				put.call(water_mm, Transform3D(Basis().scaled(Vector3(0.98, 0.06, 0.98)), Vector3(wx, y + 0.42, wz)))
				continue
			var r := rng.randf()
			if b == WorldData.Biome.FOREST and r < 0.10 and counts[leaf_mm] < 798:
				put.call(trunk_mm, Transform3D(Basis(), Vector3(wx, y + 0.6, wz)))
				put.call(leaf_mm, Transform3D(Basis().scaled(Vector3(1.5, 1.0, 1.5)), Vector3(wx, y + 1.5, wz)))
				put.call(leaf_mm, Transform3D(Basis().scaled(Vector3(1.0, 0.8, 1.0)), Vector3(wx, y + 2.2, wz)))
			elif b == WorldData.Biome.GRASS:
				if r < 0.05:
					put.call(accent_mm, Transform3D(Basis().scaled(Vector3(0.18, 0.25, 0.18)), Vector3(wx, y + 0.12, wz)))
				elif r < 0.2:
					put.call(tuft_mm, Transform3D(Basis().scaled(Vector3(0.3, 0.2, 0.3)), Vector3(wx, y + 0.1, wz)))
			elif r < 0.08:
				put.call(rock_mm, Transform3D(Basis().scaled(Vector3(0.6, 0.4, 0.6)), Vector3(wx, y + 0.15, wz)))
	for mi in counts:
		mi.multimesh.visible_instance_count = counts[mi]

func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	match event.keycode:
		KEY_SPACE:
			world_seed = randi()
			restart()
		KEY_1: time_scale = 1
		KEY_2: time_scale = 4
		KEY_3: time_scale = 16
		KEY_4: time_scale = 64
		KEY_F9:
			if lab == null:
				lab = BalanceLab.new(sim)
				print("LAB started — runs in the background of the game (or headless: tools/README)")
		KEY_H:
			print("GOD: +%d herbivores" % sim.spawn_herbs(10))
		KEY_P:
			print("GOD: +%d predators" % sim.spawn_preds(3))
		KEY_C:
			print("GOD: culled %d predators" % sim.cull_preds(0.4))
		KEY_D:
			print("GOD: culled %d herbivores" % sim.cull_herbs(0.4))
		KEY_N:
			curated_idx = (curated_idx + 1) % CURATED_SEEDS.size()
			world_seed = CURATED_SEEDS[curated_idx]
			restart()
		KEY_V:
			if fp_target == null:
				_follow_next()
			else:
				fp_target = null
				get_node("Camera3D").set_process(true)
		KEY_TAB:
			if fp_target != null:
				_follow_next()
		KEY_B:
			brain_mode = 1 - brain_mode
			sim.brain_mode = brain_mode
			for cc in sim.creatures:
				cc.use_brain = brain_mode == 1
			var src := "trained champions" if champ_herb.size() > 0 else "untrained random brains (press F7 to train)"
			print("GOD: brain_mode = %d%s" % [brain_mode, (" — " + src) if brain_mode == 1 else ""])
		KEY_F7:
			if trainer == null:
				trainer = BrainTrainer.new(randi())
				print("TRAINING started — watch Output (or run it headless: tools/README)")

func _follow_next() -> void:
	if sim.creatures.is_empty():
		fp_target = null
		return
	var i := sim.creatures.find(fp_target)
	for k in sim.creatures.size():
		var c: CreatureData = sim.creatures[(i + 1 + k) % sim.creatures.size()]
		if c.alive and c != fp_target:
			fp_target = c
			get_node("Camera3D").set_process(false)
			return

func _process(delta: float) -> void:
	# Background tools run even after the round has ended.
	if lab != null and not lab.step(TOOL_BUDGET_MS):
		lab = null
	if trainer != null and not trainer.step(TOOL_BUDGET_MS):
		champ_herb = trainer.champ_herb
		champ_pred = trainer.champ_pred
		_inject_champions(sim)
		sim.adopt_champions()
		print("Champions adopted by every creature in this world (and saved for future worlds). Press B to use brains.")
		trainer = null

	if outcome == "":
		_run_clock(delta)
	render_creatures()
	_update_fp_camera()

func _run_clock(delta: float) -> void:
	acc += delta * BASE_TPS * time_scale
	acc = minf(acc, BASE_TPS * time_scale * 0.25 + 1.0)   # drop backlog the CPU can't catch up on
	var t0 := Time.get_ticks_usec()
	while acc >= 1.0:
		sim.tick()
		acc -= 1.0
		_tps_ticks += 1
		if sim.tick_count % 500 == 0:
			var ct := sim.counts()
			print("tick %d | herb %d | pred %d | %s" % [sim.tick_count, ct.x, ct.y, sim.window_stats()])
		outcome = judge.update(sim)
		if outcome != "":
			print("ROUND OVER: %s — %s (tick %d)" % [outcome, judge.reason, sim.tick_count])
			acc = 0.0
			break
		if (Time.get_ticks_usec() - t0) > SIM_BUDGET_MS * 1000.0:
			acc = minf(acc, 1.0)
			break
	_tps_time += delta
	if _tps_time >= 0.5:
		actual_tps = _tps_ticks / _tps_time
		_tps_ticks = 0
		_tps_time = 0.0

func _update_fp_camera() -> void:
	if fp_target == null:
		return
	if not fp_target.alive:
		_follow_nearest_of(fp_target)
		if fp_target == null:
			get_node("Camera3D").set_process(true)
			return
	# Eye just in front of the creature's own head, so the view isn't blocked by it.
	var fc := fp_target
	var frac := clampf(acc, 0.0, 1.0)
	var rx := lerpf(fc.prev_x, fc.x, frac)
	var rz := lerpf(fc.prev_z, fc.z, frac)
	var is_pred := fc.species == CreatureData.Species.PRED
	var scale := 1.35 if is_pred else 1.0
	var body_pos := Vector3(rx - world.width / 2.0, world.height_at(int(floor(rx)), int(floor(rz))) + 0.3 + (0.1 if is_pred else 0.0), rz - world.depth / 2.0)
	var facing := Basis(Vector3.UP, fc.heading)
	get_node("Camera3D").global_transform = Transform3D(Basis(Vector3.UP, fc.heading + PI), body_pos + facing * (Vector3(0, 0.25, 0.6) * scale))

## When the followed creature dies, hop to the nearest living one of the same species.
func _follow_nearest_of(dead: CreatureData) -> void:
	var best: CreatureData = null
	var bd := INF
	for c in sim.creatures:
		if c.alive and c.species == dead.species:
			var d := (c.x - dead.x) * (c.x - dead.x) + (c.z - dead.z) * (c.z - dead.z)
			if d < bd:
				bd = d
				best = c
	fp_target = best

func _inject_champions(s: Simulation) -> void:
	s.champ_herb = champ_herb
	s.champ_pred = champ_pred

func restart() -> void:
	outcome = ""
	fp_target = null
	acc = 0.0
	for child in visual_root.get_children():
		child.queue_free()
	if sim != null:
		sim.release()
	world = WorldData.new(width, depth, world_seed, max_height)
	sim = Simulation.new(world, -1, false)
	sim.brain_mode = brain_mode
	_inject_champions(sim)
	sim.populate()
	assert(sim.max_pop <= MAX_POP)
	judge = RoundJudge.new()
	build_terrain_visual()
	build_creature_visual()
	build_props()
	_apply_pixel_look()
	print("World %dx%d seed=%d | creatures=%d | brains=%s" % [world.width, world.depth, world.world_seed, sim.creatures.size(), "on" if brain_mode == 1 else "off"])
	get_node("Camera3D").set_process(true)

func build_terrain_visual() -> void:
	var mmi := _new_multimesh(_box(Vector3.ONE, Color.WHITE), world.width * world.depth, true)
	(mmi.multimesh.mesh.material as StandardMaterial3D).vertex_color_use_as_albedo = true
	var mm := mmi.multimesh
	mm.visible_instance_count = -1
	var rng := RandomNumberGenerator.new()
	rng.seed = world_seed
	for x in world.width:
		for z in world.depth:
			var i := world.idx(x, z)
			var h := world.heights[i]
			var color := WorldData.biome_color(world.biomes[i]).darkened(rng.randf_range(0.0, 0.08))
			var wx := float(x) - world.width / 2.0
			var wz := float(z) - world.depth / 2.0
			mm.set_instance_transform(i, Transform3D(Basis().scaled(Vector3(1, h, 1)), Vector3(wx, h * 0.5, wz)))
			mm.set_instance_color(i, color)
	visual_root.add_child(mmi)

func build_creature_visual() -> void:
	# Every part lives under visual_root so restart() frees all of it (no ghost parts).
	var body := _new_multimesh(_box(Vector3(0.4, 0.35, 0.7), Color.WHITE), MAX_POP, true)   # long axis = forward
	(body.multimesh.mesh.material as StandardMaterial3D).vertex_color_use_as_albedo = true
	creature_mm = body.multimesh
	visual_root.add_child(body)
	head_mm = _new_multimesh(_box(Vector3(0.22, 0.18, 0.16), Color(0.08, 0.08, 0.1)), MAX_POP, false)
	leg_mm = _new_multimesh(_box(Vector3(0.1, 0.22, 0.1), Color(0.15, 0.1, 0.08)), MAX_POP * 4, false)
	tail_mm = _new_multimesh(_box(Vector3(0.08, 0.08, 0.25), Color(0.2, 0.14, 0.1)), MAX_POP, false)
	ear_mm = _new_multimesh(_box(Vector3(0.08, 0.12, 0.06), Color(0.12, 0.09, 0.08)), MAX_POP * 2, false)
	for mi in [head_mm, leg_mm, tail_mm, ear_mm]:
		visual_root.add_child(mi)

const LEG_LOCAL := [
	Vector3(-0.14, -0.22, 0.24), Vector3(0.14, -0.22, 0.24),
	Vector3(-0.14, -0.22, -0.24), Vector3(0.14, -0.22, -0.24)
]

func render_creatures() -> void:
	var frac := clampf(acc, 0.0, 1.0)
	var heads := head_mm.multimesh
	var legs := leg_mm.multimesh
	var tails := tail_mm.multimesh
	var ears := ear_mm.multimesh
	var n := 0
	for c in sim.creatures:
		if not c.alive:
			continue   # culled this frame, removed at the next tick
		if n >= MAX_POP:
			break
		var i := n
		n += 1
		var rx := lerpf(c.prev_x, c.x, frac)
		var rz := lerpf(c.prev_z, c.z, frac)
		var y := world.height_at(int(floor(rx)), int(floor(rz))) + 0.3
		var wx := rx - world.width / 2.0
		var wz := rz - world.depth / 2.0
		var e := clampf(c.energy / 100.0, 0.0, 1.0)
		var facing := Basis(Vector3.UP, c.heading)
		var is_pred := c.species == CreatureData.Species.PRED
		var scale := 1.35 if is_pred else 1.0
		var body_pos := Vector3(wx, y + (0.1 if is_pred else 0.0), wz)
		creature_mm.set_instance_transform(i, Transform3D(facing.scaled(Vector3(scale, scale, scale)), body_pos))
		if is_pred:
			creature_mm.set_instance_color(i, Color.from_hsv(0.86, 0.9, 0.45 + 0.55 * e))
		else:
			var hue := 0.05 + 0.33 * (1.0 - clampf((c.speed - 0.2) / 2.8, 0.0, 1.0))
			creature_mm.set_instance_color(i, Color.from_hsv(hue, 0.85, 0.45 + 0.55 * e))
		var hs := 0.6 + 0.6 * clampf(c.sense / 3.0, 0.0, 1.0)
		heads.set_instance_transform(i, Transform3D(facing.scaled(Vector3(hs, hs, hs)), body_pos + facing * (Vector3(0, 0.18, 0.42) * scale)))
		var wag := sin(c.distance_walked * 4.0) * 0.15
		tails.set_instance_transform(i, Transform3D(facing, body_pos + facing * (Vector3(wag * 0.3, 0.05, -0.42) * scale)))
		var phase := fmod(c.distance_walked * 3.0, TAU)
		for L in 4:
			var diag := 0.0 if (L == 0 or L == 3) else PI
			var lift := absf(sin(phase + diag)) * 0.07
			var swing := cos(phase + diag) * 0.1
			legs.set_instance_transform(i * 4 + L, Transform3D(facing, body_pos + facing * ((LEG_LOCAL[L] + Vector3(0, lift, swing)) * scale)))
		for E in 2:
			var ex := -0.1 if E == 0 else 0.1
			ears.set_instance_transform(i * 2 + E, Transform3D(facing, body_pos + facing * (Vector3(ex, 0.3, 0.4) * scale)))
	creature_mm.visible_instance_count = n
	heads.visible_instance_count = n
	tails.visible_instance_count = n
	legs.visible_instance_count = n * 4
	ears.visible_instance_count = n * 2
