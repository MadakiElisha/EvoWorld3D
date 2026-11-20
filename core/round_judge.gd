class_name RoundJudge
extends RefCounted
## Decides when a round is won or lost. Shared by the game and the headless
## regression runner so both use exactly the same rules.
##
## STEWARD : both species alive at WIN_TICKS.
## COLLAPSE: a species has been extinct for EXTINCTION_GRACE ticks
##           (the player gets that long to reintroduce it with H / P),
##           or everything is dead.

const WIN_TICKS := 10000
const EXTINCTION_GRACE := 400     # ~50 s at 1x speed

var outcome := ""
var reason := ""
var herb_gone_at := -1
var pred_gone_at := -1

func update(sim: Simulation) -> String:
	if outcome != "":
		return outcome
	var ct := sim.counts()
	var t := sim.tick_count
	herb_gone_at = -1 if ct.x > 0 else (herb_gone_at if herb_gone_at >= 0 else t)
	pred_gone_at = -1 if ct.y > 0 else (pred_gone_at if pred_gone_at >= 0 else t)
	if ct.x == 0 and ct.y == 0:
		_end("COLLAPSE", "all life is gone")
	elif herb_gone_at >= 0 and t - herb_gone_at >= EXTINCTION_GRACE:
		_end("COLLAPSE", "herbivores went extinct")
	elif pred_gone_at >= 0 and t - pred_gone_at >= EXTINCTION_GRACE:
		_end("COLLAPSE", "predators went extinct")
	elif t >= WIN_TICKS and ct.x > 0 and ct.y > 0:
		_end("STEWARD", "both species survived %d ticks" % WIN_TICKS)
	return outcome

func _end(o: String, r: String) -> void:
	outcome = o
	reason = r

## A live warning for the HUD while a species is extinct but still recoverable.
func warning(sim: Simulation) -> String:
	if outcome != "":
		return ""
	if pred_gone_at >= 0:
		return "PREDATORS EXTINCT — press P to reintroduce (%d ticks left)" % (EXTINCTION_GRACE - (sim.tick_count - pred_gone_at))
	if herb_gone_at >= 0:
		return "HERBIVORES EXTINCT — press H to reintroduce (%d ticks left)" % (EXTINCTION_GRACE - (sim.tick_count - herb_gone_at))
	return ""
