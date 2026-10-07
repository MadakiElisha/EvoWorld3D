class_name CreatureData
extends RefCounted
## One creature's entire existence: position, energy, genes, species, vigilance.

enum Species { HERB, PRED }

var species: int = Species.HERB
var x: float = 0.0
var z: float = 0.0
var energy: float = 60.0
var age: int = 0
var wander_angle: float = 0.0
var alive: bool = true
var cooldown: int = 0
var alert_ticks := 0   # vigilance memory: >0 = head up; 0 = grazing (ambushable)
var threat: CreatureData = null   # cached nearest predator (herbivores)
var target: CreatureData = null   # cached nearest prey (predators)
var scan_timer := 0
var heading: float = 0.0   # yaw the body faces (radians)
var distance_walked := 0.0

# Genes (mutate on reproduction)
var speed: float = 1.0
var sense: float = 1.5
var metabolism: float = 1.0
var brain := PackedFloat32Array()   # 56 weights: 6 sensors -> 6 hidden -> 2 motor
