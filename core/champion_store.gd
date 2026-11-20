class_name ChampionStore
extends RefCounted
## Persists trained champion brains so they survive restarts and app launches.
## The headless trainer (tools/train.gd) and the game share the same user:// folder.

const PATH := "user://champions.bin"
const VERSION := 1

static func save(herb: PackedFloat32Array, pred: PackedFloat32Array, report := "") -> Error:
	var f := FileAccess.open(PATH, FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	f.store_var({
		"version": VERSION,
		"brain_size": Simulation.BRAIN_SIZE,
		"herb": herb,
		"pred": pred,
		"report": report,
		"saved_at": Time.get_datetime_string_from_system(),
	})
	return OK

## Returns {} when nothing usable is saved (missing file or a brain layout change).
static func load_champions() -> Dictionary:
	if not FileAccess.file_exists(PATH):
		return {}
	var f := FileAccess.open(PATH, FileAccess.READ)
	if f == null:
		return {}
	var d = f.get_var()
	if typeof(d) != TYPE_DICTIONARY or d.get("brain_size", -1) != Simulation.BRAIN_SIZE:
		return {}
	return d

static func absolute_path() -> String:
	return ProjectSettings.globalize_path(PATH)
