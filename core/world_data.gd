class_name WorldData
extends RefCounted
## Pure simulation data. No visuals, no nodes. This IS the world.

enum Biome { WATER, SAND, GRASS, FOREST, STONE }

var width: int = 48
var depth: int = 48
var world_seed: int = 1337
var max_height: int = 8
var frequency: float = 0.065

var heights: PackedInt32Array = PackedInt32Array()
var biomes: PackedByteArray = PackedByteArray()

func _init(p_width: int = 48, p_depth: int = 48, p_seed: int = 1337, p_max_height: int = 8) -> void:
	width = p_width
	depth = p_depth
	world_seed = p_seed
	max_height = p_max_height
	regenerate()

func regenerate() -> void:
	var noise := FastNoiseLite.new()
	noise.seed = world_seed
	noise.frequency = frequency

	heights.resize(width * depth)
	biomes.resize(width * depth)

	for x in width:
		for z in depth:
			var wx := float(x) - width / 2.0
			var wz := float(z) - depth / 2.0
			var n := noise.get_noise_2d(wx, wz)
			var normalized := n * 0.5 + 0.5
			var h := int(normalized * max_height) + 1

			var b: int
			if n < -0.35:
				b = Biome.WATER
			elif n < -0.18:
				b = Biome.SAND
			elif n < 0.18:
				b = Biome.GRASS
			elif n < 0.42:
				b = Biome.FOREST
			else:
				b = Biome.STONE

			var i := idx(x, z)
			heights[i] = h
			biomes[i] = b

func idx(x: int, z: int) -> int:
	return x * depth + z

func in_bounds(x: int, z: int) -> bool:
	return x >= 0 and z >= 0 and x < width and z < depth

func height_at(x: int, z: int) -> int:
	if not in_bounds(x, z):
		return 0
	return heights[idx(x, z)]

func biome_at(x: int, z: int) -> int:
	if not in_bounds(x, z):
		return Biome.WATER
	return biomes[idx(x, z)]

func is_walkable(x: int, z: int) -> bool:
	return biome_at(x, z) != Biome.WATER

static func biome_color(b: int) -> Color:
	match b:
		Biome.WATER: return Color(0.16, 0.42, 0.85)
		Biome.SAND: return Color(0.82, 0.74, 0.52)
		Biome.GRASS: return Color(0.33, 0.68, 0.32)
		Biome.FOREST: return Color(0.22, 0.50, 0.28)
		_: return Color(0.55, 0.56, 0.62)
