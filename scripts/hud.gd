extends Control
## View-only dashboard: reads the Simulation, draws history, warnings and the outcome banner.

const MAX_SAMPLES := 240
const SAMPLE_EVERY := 50
const MAX_HERB := 700.0
const MAX_PRED := 160.0

var history_h: PackedFloat32Array = PackedFloat32Array()
var history_p: PackedFloat32Array = PackedFloat32Array()
var last_sample_tick := -999999
var _last_sim: Simulation = null

func _process(_delta: float) -> void:
	var sim := _sim()
	if sim == null:
		return
	if sim != _last_sim:   # new world: start the graph over
		_last_sim = sim
		history_h.clear()
		history_p.clear()
		last_sample_tick = -999999
	if sim.tick_count - last_sample_tick >= SAMPLE_EVERY:
		last_sample_tick = sim.tick_count
		var ct := sim.counts()
		history_h.push_back(float(ct.x))
		history_p.push_back(float(ct.y))
		if history_h.size() > MAX_SAMPLES:
			history_h.remove_at(0)
			history_p.remove_at(0)
	queue_redraw()

func _scene() -> Node:
	return get_tree().current_scene

func _sim() -> Simulation:
	var scene := _scene()
	if scene == null or not ("sim" in scene):
		return null
	return scene.get("sim")

func _draw() -> void:
	var sim := _sim()
	if sim == null:
		return
	var scene := _scene()
	draw_rect(Rect2(8, 8, 380, 282), Color(0, 0, 0, 0.55))
	var font := ThemeDB.fallback_font
	var ct := sim.counts()
	var ts: int = scene.get("time_scale")
	var tps: float = scene.get("actual_tps")
	var target := 8.0 * ts
	var speed_col := Color.WHITE if tps >= target * 0.9 or tps == 0.0 else Color(1.0, 0.75, 0.3)
	draw_string(font, Vector2(18, 28), "tick %d   %dx  (%.0f/%.0f tps)   brains %s" % [sim.tick_count, ts, tps, target, "ON" if sim.brain_mode == 1 else "off"], HORIZONTAL_ALIGNMENT_LEFT, 360, 13, speed_col)
	var gh := sim.gene_averages(0)
	var gp := sim.gene_averages(1)
	draw_string(font, Vector2(18, 46), "herb %d  spd %.2f sns %.2f met %.2f" % [ct.x, gh.x, gh.y, gh.z], HORIZONTAL_ALIGNMENT_LEFT, 360, 13, Color(0.5, 1.0, 0.55))
	draw_string(font, Vector2(18, 62), "pred %d  spd %.2f sns %.2f met %.2f" % [ct.y, gp.x, gp.y, gp.z], HORIZONTAL_ALIGNMENT_LEFT, 360, 13, Color(1.0, 0.45, 0.75))
	draw_string(font, Vector2(18, 78), "1-4 speed | space rand | N next island | H/P spawn | C/D cull", HORIZONTAL_ALIGNMENT_LEFT, 360, 11, Color(0.75, 0.75, 0.75))
	draw_string(font, Vector2(18, 92), "V follow / Tab next | B brains | F7 train | F9 balance lab", HORIZONTAL_ALIGNMENT_LEFT, 360, 11, Color(0.75, 0.75, 0.75))
	_draw_curve(history_h, Color(0.45, 1.0, 0.55), MAX_HERB)
	_draw_curve(history_p, Color(1.0, 0.35, 0.65), MAX_PRED)
	_draw_tools(font, scene)
	_draw_outcome(font, scene, sim)

func _draw_tools(font: Font, scene: Node) -> void:
	var y := 256.0
	var trainer = scene.get("trainer")
	if trainer != null:
		draw_string(font, Vector2(18, y), "training brains… %d%%" % int(trainer.progress * 100.0), HORIZONTAL_ALIGNMENT_LEFT, 360, 12, Color(0.6, 0.85, 1.0))
		y += 14
	var lab = scene.get("lab")
	if lab != null:
		draw_string(font, Vector2(18, y), "balance lab… %d%%" % int(lab.progress * 100.0), HORIZONTAL_ALIGNMENT_LEFT, 360, 12, Color(0.6, 0.85, 1.0))

func _draw_outcome(font: Font, scene: Node, sim: Simulation) -> void:
	var judge = scene.get("judge")
	if judge == null:
		return
	var warn: String = judge.warning(sim)
	if warn != "":
		draw_string(font, Vector2(18, 236), warn, HORIZONTAL_ALIGNMENT_LEFT, 360, 12, Color(1.0, 0.6, 0.3))
	if judge.outcome == "":
		return
	var win: bool = judge.outcome == "STEWARD"
	draw_string(font, Vector2(150, 140), judge.outcome, HORIZONTAL_ALIGNMENT_LEFT, 360, 36, Color(0.5, 1.0, 0.5) if win else Color(1.0, 0.35, 0.35))
	draw_string(font, Vector2(150, 162), judge.reason, HORIZONTAL_ALIGNMENT_LEFT, 230, 12, Color.WHITE)

func _draw_curve(history: PackedFloat32Array, color: Color, maxv: float) -> void:
	if history.size() < 2:
		return
	var pts := PackedVector2Array()
	for i in history.size():
		var x := 18.0 + i * (350.0 / MAX_SAMPLES)
		var y := 220.0 - (history[i] / maxv) * 110.0
		pts.append(Vector2(x, y))
	draw_polyline(pts, color, 2.0)
