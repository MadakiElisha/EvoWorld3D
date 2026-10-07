extends Node3D
## Composition root: owns world + sim, paints both, runs the clock.

@export var width := 72
@export var depth := 72
@export var world_seed := 524274379   # a known-good island as the front door
@export var max_height := 8
@export var time_scale := 1

const CURATED_SEEDS := [524274379, 2655256772, 819918188]
var curated_idx := 0
var outcome := ""

var world: WorldData
var sim: Simulation
var visual_root: Node3D
var creature_mm: MultiMesh
var head_mm: MultiMeshInstance3D
var ear_mm: MultiMeshInstance3D
var leg_mm: MultiMeshInstance3D
var tail_mm: MultiMeshInstance3D
var acc := 0.0
var extinction_announced := false
var lab: BalanceLab = null
var fp_index := -1
var pixel_noise: ImageTexture

const BASE_TPS := 8.0
const MAX_POP := 800

func _ready() -> void:
	visual_root = Node3D.new()
	add_child(visual_root)
	restart()
	pixel_noise = make_pixel_noise(8, 0.6, 1.0)
	_apply_pixel_look()
	_setup_atmosphere()

func _setup_atmosphere() -> void:
	var sun := get_node_or_null("DirectionalLight3D") as DirectionalLight3D
	if sun != null:
		sun.light_color = Color(1.0, 0.95, 0.85)
		sun.light_energy = 1.15
		sun.shadow_enabled = true
		sun.rotation_degrees = Vector3(-55, 0, 35)
	var we := get_node_or_null("WorldEnvironment") as WorldEnvironment
	if we != null and we.environment != null:
		var env := we.environment
		env.tonemap_mode = Environment.TONE_MAPPER_ACES
		env.fog_enabled = true
		env.fog_light_color = Color(0.7, 0.82, 0.95)
		env.fog_density = 0.002

func make_pixel_noise(size := 16, lo := 0.78, hi := 1.0) -> ImageTexture:
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	for x in size:
		for y in size:
			var v := randf_range(lo, hi)
			img.set_pixel(x, y, Color(v, v, v, 1.0))
	return ImageTexture.create_from_image(img)

func _apply_pixel_look() -> void:
	for child in get_children():
		var mesh: Mesh = null
		if child is MultiMeshInstance3D:
			mesh = child.multimesh.mesh
		elif child is MeshInstance3D:
			mesh = child.mesh
		if mesh == null:
			continue
		var mat := mesh.material as StandardMaterial3D
		if mat == null:
			mat = StandardMaterial3D.new()
			mesh.material = mat
		mat.albedo_texture = pixel_noise
		mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
		mat.vertex_color_use_as_albedo = true

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed:
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
					print("LAB started — sim will run slowly while it searches, ~2-4 minutes")
			KEY_H:
				sim.spawn_herbs(10)
				print("GOD: +10 herbivores")
			KEY_P:
				sim.spawn_preds(3)
				print("GOD: +3 predators")
			KEY_C:
				sim.cull_preds(0.4)
				print("GOD: culled 40% of predators")
			KEY_D:
				sim.cull_herbs(0.4)
				print("GOD: culled 40% of herbivores")
			KEY_N:
				curated_idx = (curated_idx + 1) % CURATED_SEEDS.size()
				world_seed = CURATED_SEEDS[curated_idx]
				outcome = ""
				restart()
			KEY_V:
				if fp_index < 0:
					fp_index = 0
					get_node("Camera3D").set_process(false)
				else:
					fp_index = -1
					get_node("Camera3D").set_process(true)
			KEY_B:
				sim.brain_mode = 1 - sim.brain_mode
				print("GOD: brain_mode = %d" % sim.brain_mode)

func _process(delta: float) -> void:
	if outcome != "":
		return
	acc += delta * BASE_TPS * time_scale
	var guard := 0
	while acc >= 1.0 and guard < 500:
		sim.tick()
		acc -= 1.0
		guard += 1
		if sim.tick_count % 500 == 0:
			var ct := sim.counts()
			print("tick %d | herb %d | pred %d | %s" % [sim.tick_count, ct.x, ct.y, sim.window_stats()])
		if sim.creatures.is_empty():
			if not extinction_announced:
				print("EXTINCTION at tick %d" % sim.tick_count)
				extinction_announced = true
			acc = 0.0
			break
	if lab != null:
		if not lab.step():
			lab = null
	if outcome == "":
		var ct := sim.counts()
		if sim.creatures.is_empty():
			outcome = "COLLAPSE"
		elif sim.tick_count >= 10000 and ct.x > 0 and ct.y > 0:
			outcome = "STEWARD"
	render_creatures()
	
	if fp_index >= 0 and sim.creatures.size() > 0:
		if fp_index >= sim.creatures.size():
			fp_index = 0
		var fc := sim.creatures[fp_index]
		var ftx := int(floor(fc.x))
		var ftz := int(floor(fc.z))
		var fy := world.height_at(ftx, ftz) + 0.6
		var fwx := fc.x - world.width / 2.0
		var fwz := fc.z - world.depth / 2.0
		get_node("Camera3D").global_transform = Transform3D(Basis(Vector3.UP, fc.heading + PI), Vector3(fwx, fy, fwz))

func restart() -> void:
	outcome = ""
	fp_index = -1
	for child in visual_root.get_children():
		child.queue_free()
	extinction_announced = false
	world = WorldData.new(width, depth, world_seed, max_height)
	sim = Simulation.new(world)
	build_terrain_visual()
	build_creature_visual()
	print("World %dx%d seed=%d | creatures=%d" % [world.width, world.depth, world.world_seed, sim.creatures.size()])
	get_node("Camera3D").set_process(true)

func build_terrain_visual() -> void:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	var box := BoxMesh.new()
	box.size = Vector3(1, 1, 1)
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	box.material = mat
	mm.mesh = box
	mm.instance_count = world.width * world.depth

	for x in world.width:
		for z in world.depth:
			var i := world.idx(x, z)
			var h := world.heights[i]
			var color := WorldData.biome_color(world.biomes[i])
			color = color.darkened(randf_range(0.0, 0.08))
			var wx := float(x) - world.width / 2.0
			var wz := float(z) - world.depth / 2.0
			var basis := Basis().scaled(Vector3(1, h, 1))
			mm.set_instance_transform(i, Transform3D(basis, Vector3(wx, h * 0.5, wz)))
			mm.set_instance_color(i, color)

	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	visual_root.add_child(mmi)

func build_creature_visual() -> void:
	creature_mm = MultiMesh.new()
	creature_mm.transform_format = MultiMesh.TRANSFORM_3D
	creature_mm.use_colors = true
	var box := BoxMesh.new()
	box.size = Vector3(0.4, 0.35, 0.7)   # long axis = forward
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	box.material = mat
	creature_mm.mesh = box
	creature_mm.instance_count = MAX_POP
	creature_mm.visible_instance_count = 0

	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = creature_mm
	visual_root.add_child(mmi)
	
	head_mm = MultiMeshInstance3D.new()
	var head_mesh := BoxMesh.new()
	head_mesh.size = Vector3(0.22, 0.18, 0.16)
	var head_mat := StandardMaterial3D.new()
	head_mat.albedo_color = Color(0.08, 0.08, 0.1)
	head_mesh.material = head_mat
	var head_mult := MultiMesh.new()
	head_mult.transform_format = MultiMesh.TRANSFORM_3D
	head_mult.instance_count = MAX_POP
	head_mult.mesh = head_mesh
	head_mm.multimesh = head_mult
	add_child(head_mm)
	
	leg_mm = MultiMeshInstance3D.new()
	var leg_mesh := BoxMesh.new()
	leg_mesh.size = Vector3(0.1, 0.22, 0.1)
	var leg_mat := StandardMaterial3D.new()
	leg_mat.albedo_color = Color(0.15, 0.1, 0.08)
	leg_mesh.material = leg_mat
	var leg_mult := MultiMesh.new()
	leg_mult.transform_format = MultiMesh.TRANSFORM_3D
	leg_mult.instance_count = MAX_POP * 4
	leg_mult.mesh = leg_mesh
	leg_mm.multimesh = leg_mult
	add_child(leg_mm)
	
	tail_mm = MultiMeshInstance3D.new()
	var tail_mesh := BoxMesh.new()
	tail_mesh.size = Vector3(0.08, 0.08, 0.25)
	var tail_mat := StandardMaterial3D.new()
	tail_mat.albedo_color = Color(0.2, 0.14, 0.1)
	tail_mesh.material = tail_mat
	var tail_mult := MultiMesh.new()
	tail_mult.transform_format = MultiMesh.TRANSFORM_3D
	tail_mult.instance_count = MAX_POP
	tail_mult.mesh = tail_mesh
	tail_mm.multimesh = tail_mult
	add_child(tail_mm)
	
	ear_mm = MultiMeshInstance3D.new()
	var ear_mesh := BoxMesh.new()
	ear_mesh.size = Vector3(0.08, 0.12, 0.06)
	var ear_mat := StandardMaterial3D.new()
	ear_mat.albedo_color = Color(0.12, 0.09, 0.08)
	ear_mesh.material = ear_mat
	var ear_mult := MultiMesh.new()
	ear_mult.transform_format = MultiMesh.TRANSFORM_3D
	ear_mult.instance_count = MAX_POP * 2
	ear_mult.mesh = ear_mesh
	ear_mm.multimesh = ear_mult
	add_child(ear_mm)

func render_creatures() -> void:
	var n := sim.creatures.size()
	creature_mm.visible_instance_count = n
	for i in n:
		var c := sim.creatures[i]
		var tx := int(floor(c.x))
		var tz := int(floor(c.z))
		var y := world.height_at(tx, tz) + 0.3
		var wx := c.x - world.width / 2.0
		var wz := c.z - world.depth / 2.0
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
		head_mm.multimesh.set_instance_transform(i, Transform3D(facing.scaled(Vector3(hs, hs, hs)), body_pos + facing * (Vector3(0, 0.18, 0.42) * scale)))
		var wag := sin(c.distance_walked * 4.0) * 0.15
		tail_mm.multimesh.set_instance_transform(i, Transform3D(facing, body_pos + facing * (Vector3(wag * 0.3, 0.05, -0.42) * scale)))
		var phase := fmod(c.distance_walked * 3.0, TAU)
		var leg_local := [
			Vector3(-0.14, -0.22, 0.24), Vector3(0.14, -0.22, 0.24),
			Vector3(-0.14, -0.22, -0.24), Vector3(0.14, -0.22, -0.24)
		]
		for L in 4:
			var diag := 0.0 if (L == 0 or L == 3) else PI
			var lift := absf(sin(phase + diag)) * 0.07
			var swing := cos(phase + diag) * 0.1
			leg_mm.multimesh.set_instance_transform(i * 4 + L, Transform3D(facing, body_pos + facing * ((leg_local[L] + Vector3(0, lift, swing)) * scale)))
		for E in 2:
			var ex := -0.1 if E == 0 else 0.1
			ear_mm.multimesh.set_instance_transform(i * 2 + E, Transform3D(facing, body_pos + facing * (Vector3(ex, 0.3, 0.4) * scale)))
	for j in range(n, MAX_POP):
		head_mm.multimesh.set_instance_transform(j, Transform3D(Basis().scaled(Vector3.ZERO), Vector3.ZERO))
		tail_mm.multimesh.set_instance_transform(j, Transform3D(Basis().scaled(Vector3.ZERO), Vector3.ZERO))
	for j in range(n * 4, MAX_POP * 4):
		leg_mm.multimesh.set_instance_transform(j, Transform3D(Basis().scaled(Vector3.ZERO), Vector3.ZERO))
	for j in range(n * 2, MAX_POP * 2):
		ear_mm.multimesh.set_instance_transform(j, Transform3D(Basis().scaled(Vector3.ZERO), Vector3.ZERO))
