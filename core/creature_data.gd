class_name CreatureData
extends RefCounted
## One creature's entire existence: position, energy, genes, species.

enum Species { HERB, PRED }

var species: int = Species.HERB
var x: float = 0.0
var z: float = 0.0
var energy: float = 60.0
var age: int = 0
var wander_angle: float = 0.0
var alive: bool = true
var cooldown: int = 0

# Genes (mutate on reproduction)
var speed: float = 1.0
var sense: float = 1.5
var metabolism: float = 1.0
