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
var acc := 0.0
var extinction_announced := false
var lab: BalanceLab = null
var fp_index := -1

const BASE_TPS := 8.0
const MAX_POP := 800

func _ready() -> void:
	visual_root = Node3D.new()
	add_child(visual_root)
	restart()

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

func render_creatures() -> void:
	var n := sim.creatures.size()
	creature_mm.visible_instance_count = n
	head_mm.visible_instance_count = n
	for i in n:
		var c := sim.creatures[i]
		var tx := int(floor(c.x))
		var tz := int(floor(c.z))
		var y := world.height_at(tx, tz) + 0.3
		var wx := c.x - world.width / 2.0
		var wz := c.z - world.depth / 2.0
		var e := clampf(c.energy / 100.0, 0.0, 1.0)
		var facing := Basis(Vector3.UP, c.heading)
		var by := y
		if c.species == CreatureData.Species.PRED:
			by = y + 0.1
			var basis := facing.scaled(Vector3(1.35, 1.35, 1.35))
			creature_mm.set_instance_transform(i, Transform3D(basis, Vector3(wx, by, wz)))
			creature_mm.set_instance_color(i, Color.from_hsv(0.86, 0.9, 0.45 + 0.55 * e))
		else:
			creature_mm.set_instance_transform(i, Transform3D(facing, Vector3(wx, by, wz)))
			var hue := 0.05 + 0.33 * (1.0 - clampf((c.speed - 0.2) / 2.8, 0.0, 1.0))
			creature_mm.set_instance_color(i, Color.from_hsv(hue, 0.85, 0.45 + 0.55 * e))
		var forward := Vector3(sin(c.heading), 0.0, cos(c.heading))
		var head_scale := 0.6 + 0.6 * clampf(c.sense / 3.0, 0.0, 1.0)
		var head_basis := Basis(Vector3.UP, c.heading).scaled(Vector3(head_scale, head_scale, head_scale))
		head_mm.set_instance_transform(i, Transform3D(head_basis, Vector3(wx, by, wz) + forward * 0.3 + Vector3.UP * 0.22))
