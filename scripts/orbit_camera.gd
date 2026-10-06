extends Camera3D

@export var target: Vector3 = Vector3(0, 4, 0)
@export var distance := 34.0
@export var min_distance := 10.0
@export var max_distance := 120.0
@export var sensitivity := 0.25

var yaw := 40.0
var pitch := 32.0
var dragging := false

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			dragging = event.pressed

		elif event.button_index == MOUSE_BUTTON_WHEEL_UP:
			distance = clampf(distance * 0.9, min_distance, max_distance)

		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			distance = clampf(distance * 1.1, min_distance, max_distance)

	elif event is InputEventMouseMotion and dragging:
		yaw -= event.relative.x * sensitivity
		pitch += event.relative.y * sensitivity
		pitch = clampf(pitch, 8.0, 80.0)

func _process(_delta: float) -> void:
	var elevation := deg_to_rad(pitch)
	var yaw_rad := deg_to_rad(yaw)

	var offset := Vector3(
		distance * cos(elevation) * sin(yaw_rad),
		distance * sin(elevation),
		distance * cos(elevation) * cos(yaw_rad)
	)

	global_position = target + offset
	look_at(target, Vector3.UP)
