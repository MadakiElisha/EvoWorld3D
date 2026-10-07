extends Control
## View-only dashboard: reads the Simulation, draws history and the outcome banner.

const MAX_SAMPLES := 240
const SAMPLE_EVERY := 50
const MAX_HERB := 700.0
const MAX_PRED := 160.0

var history_h: PackedFloat32Array = PackedFloat32Array()
var history_p: PackedFloat32Array = PackedFloat32Array()
var last_sample_tick := -999999

func _process(_delta: float) -> void:
	var sim := _sim()
	if sim == null:
		return
	if sim.tick_count - last_sample_tick >= SAMPLE_EVERY:
		last_sample_tick = sim.tick_count
		var ct := sim.counts()
		history_h.push_back(float(ct.x))
		history_p.push_back(float(ct.y))
		if history_h.size() > MAX_SAMPLES:
			history_h.remove_at(0)
			history_p.remove_at(0)
	queue_redraw()

func _sim() -> Simulation:
	var scene := get_tree().current_scene
	if scene == null or not ("sim" in scene):
		return null
	return scene.get("sim")

func _draw() -> void:
	var sim := _sim()
	if sim == null:
		return
	draw_rect(Rect2(8, 8, 360, 210), Color(0, 0, 0, 0.55))
	var font := ThemeDB.fallback_font
	var ct := sim.counts()
	draw_string(font, Vector2(18, 28), "tick %d" % sim.tick_count, HORIZONTAL_ALIGNMENT_LEFT, 340, 14, Color.WHITE)
	var gh := sim.gene_averages(0)
	var gp := sim.gene_averages(1)
	draw_string(font, Vector2(18, 46), "herb %d  spd %.2f sns %.2f met %.2f" % [ct.x, gh.x, gh.y, gh.z], HORIZONTAL_ALIGNMENT_LEFT, 340, 13, Color(0.5, 1.0, 0.55))
	draw_string(font, Vector2(18, 62), "pred %d  spd %.2f sns %.2f met %.2f" % [ct.y, gp.x, gp.y, gp.z], HORIZONTAL_ALIGNMENT_LEFT, 340, 13, Color(1.0, 0.45, 0.75))
	draw_string(font, Vector2(18, 78), "1-4 speed | space rand | N next island | H/P C/D gods", HORIZONTAL_ALIGNMENT_LEFT, 340, 11, Color(0.75, 0.75, 0.75))
	_draw_curve(history_h, Color(0.45, 1.0, 0.55), MAX_HERB)
	_draw_curve(history_p, Color(1.0, 0.35, 0.65), MAX_PRED)
	_draw_outcome(font)

func _draw_outcome(font: Font) -> void:
	var scene := get_tree().current_scene
	if scene == null or not ("outcome" in scene):
		return
	var outcome: String = scene.get("outcome")
	if outcome == "":
		return
	var win := outcome == "STEWARD"
	draw_string(font, Vector2(150, 130), outcome, HORIZONTAL_ALIGNMENT_LEFT, 340, 36, Color(0.5, 1.0, 0.5) if win else Color(1.0, 0.35, 0.35))

func _draw_curve(history: PackedFloat32Array, color: Color, maxv: float) -> void:
	if history.size() < 2:
		return
	var pts := PackedVector2Array()
	for i in history.size():
		var x := 18.0 + i * (330.0 / MAX_SAMPLES)
		var y := 198.0 - (history[i] / maxv) * 110.0
		pts.append(Vector2(x, y))
	draw_polyline(pts, color, 2.0)
