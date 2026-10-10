extends RefCounted
## Single owner of map-floor results and seed lifecycle; no view or file IO.
## The game's run state retains this object when swapping 2D/2.5D views.
const Generator = preload("res://systems/map/flat_2d/planar_map_generator.gd")
const Session = preload("res://systems/map/flat_2d/planar_map_session.gd")
const Domains = preload("res://systems/random/random_domains.gd")
const RUN_VERSION := 1
const MAX_FLOORS := 20
var last_error := ""
var current_floor := 0
var _source: Object
var _content_version: String
var _map_set_id := ""
var _seed := ""
var _configs: Array = []
var _floors: Dictionary = {}
var _failures: Dictionary = {}
var _anchor: RefCounted

func _init(seed_source: Object, content_version: String) -> void:
	_source = seed_source
	_content_version = content_version

func _fail(message: String) -> bool:
	last_error = message
	return false

func _normalize(configs: Array) -> Array:
	if configs.is_empty() or configs.size() > MAX_FLOORS:
		_fail("Expected 1–%d floor configurations" % MAX_FLOORS)
		return []
	var generator = Generator.new()
	var normalized: Array = []
	for config in configs:
		if not config is Dictionary:
			_fail("Each floor configuration must be a Dictionary")
			return []
		var clean: Dictionary = generator.normalize_config(config)
		if clean.is_empty():
			_fail(generator.last_error)
			return []
		normalized.append(clean)
	return normalized

func _valid_source() -> bool:
	if _content_version.is_empty() or _source == null:
		return _fail("Run coordinator requires configured seed source and content version")
	for method in ["get_main_seed", "get_stream", "begin_run", "capture_snapshot", "restore_snapshot"]:
		if not _source.has_method(method):
			return _fail("Seed source is missing " + method)
	return true

func _install(seed_text: String, configs: Array, map_set_id: String) -> void:
	_seed = seed_text
	_configs = configs.duplicate(true)
	_map_set_id = map_set_id
	_floors = {}
	_failures = {}
	current_floor = 0
	_anchor = _source.get_stream(Domains.MAP_RUN, [_map_set_id], 0)
	last_error = ""

## Explicit new-game operation. Validate policy before invalidating other RNGs.
func start_new_run(seed_text: String, configs: Array, map_set_id: String = "world") -> bool:
	if not _valid_source() or map_set_id.strip_edges().is_empty():
		return _fail("Invalid seed source or map_set_id")
	var normalized := _normalize(configs)
	if normalized.is_empty():
		return false
	var chosen: String = _source.begin_run(seed_text)
	if chosen.is_empty():
		return _fail("Seed source rejected new run")
	_install(chosen, normalized, map_set_id)
	return true

## For a run coordinator which has already initialized SeedService.
## Call once when creating map state; scene reopening must reuse this object.
func attach_existing_run(configs: Array, map_set_id: String = "world") -> bool:
	if not _valid_source() or map_set_id.strip_edges().is_empty():
		return _fail("Invalid seed source or map_set_id")
	var normalized := _normalize(configs)
	if normalized.is_empty():
		return false
	var chosen: String = _source.get_main_seed()
	if chosen.is_empty():
		return _fail("Initialize SeedService before attaching map state")
	_install(chosen, normalized, map_set_id)
	return true

func _current_context() -> bool:
	if _seed.is_empty() or _source.get_main_seed() != _seed:
		return _fail("Map state belongs to another seed context")
	# Identity comparison is a zero-draw lifecycle check. This also catches a
	# foreign begin/restore using the same seed text without reading internals.
	if _source.get_stream(Domains.MAP_RUN, [_map_set_id], 0) != _anchor:
		return _fail("Seed context was replaced; start/restore the map run too")
	return true

func get_main_seed() -> String:
	return _seed

func floor_count() -> int:
	return _configs.size()

func map_id_for(index: int) -> String:
	return "%s:floor-%03d" % [_map_set_id, index]

func _check_floor(snapshot: Dictionary, state: Dictionary, index: int, seed_text: String, configs: Array, map_set_id: String) -> bool:
	if snapshot.get("map_id") != "%s:floor-%03d" % [map_set_id, index] or snapshot.get("seed") != seed_text or snapshot.get("floor_index") != index:
		return _fail("Floor snapshot identity does not match run")
	if snapshot.get("generator_version") != Generator.VERSION or not snapshot.get("generation_config") is Dictionary:
		return _fail("Floor generator version/configuration mismatch")
	# JSON loads numbers as floats; normalize both sides before Dictionary
	# comparison, which otherwise treats integer/float values differently.
	var generator = Generator.new()
	var actual_config: Dictionary = generator.normalize_config(snapshot.generation_config)
	if actual_config.is_empty() or actual_config != configs[index - 1]:
		return _fail("Floor generator version/configuration mismatch")
	var candidate = Session.new()
	if not candidate.load_map(snapshot) or not candidate.restore_state(state):
		return _fail("Invalid floor state: " + candidate.last_error)
	return true

## Generate a floor once, then always reuse its saved result and state.
## Pre-generating in a different order cannot affect other floor streams.
func get_floor(index: int) -> Dictionary:
	if not _current_context():
		return {}
	if index < 1 or index > floor_count():
		_fail("Floor index out of range")
		return {}
	if _floors.has(index):
		last_error = ""
		return _floors[index].duplicate(true)
	if _failures.has(index):
		_fail(_failures[index])
		return {}
	var generator = Generator.new()
	var snapshot: Dictionary = generator.generate(_source, map_id_for(index), index, _configs[index - 1])
	var candidate = Session.new()
	if snapshot.is_empty() or not candidate.load_map(snapshot):
		var error: String = generator.last_error if snapshot.is_empty() else candidate.last_error
		_failures[index] = "Floor generation rejected: " + error
		_fail(_failures[index])
		return {}
	var state: Dictionary = candidate.capture_state()
	if not _check_floor(snapshot, state, index, _seed, _configs, _map_set_id):
		_failures[index] = last_error
		return {}
	_floors[index] = {"snapshot": snapshot.duplicate(true), "state": state}
	last_error = ""
	return _floors[index].duplicate(true)

func store_current(state: Dictionary) -> bool:
	if not _current_context() or current_floor < 1 or not _floors.has(current_floor):
		return _fail("No active generated floor")
	var entry: Dictionary = _floors[current_floor]
	if not _check_floor(entry.snapshot, state, current_floor, _seed, _configs, _map_set_id):
		return false
	entry.state = state.duplicate(true)
	last_error = ""
	return true

## The caller decides progression policy. Pending encounters cannot be left.
func enter_floor(index: int, current_state: Dictionary = {}) -> Dictionary:
	if index < 1 or index > floor_count():
		_fail("Floor index out of range")
		return {}
	if not current_state.is_empty() and not store_current(current_state):
		return {}
	if current_floor > 0 and not _floors[current_floor].state.pending.is_empty():
		_fail("Resolve or cancel the active encounter before switching floors")
		return {}
	var entry := get_floor(index)
	if entry.is_empty():
		return {}
	current_floor = index
	return entry

func capture_snapshot(current_state: Dictionary = {}) -> Dictionary:
	if not _current_context() or (not current_state.is_empty() and not store_current(current_state)):
		return {}
	var records: Array = []
	var indices := _floors.keys()
	indices.sort()
	for index in indices:
		var entry: Dictionary = _floors[index]
		records.append({"floor_index": index, "snapshot": entry.snapshot.duplicate(true), "state": entry.state.duplicate(true)})
	var failures: Array = []
	indices = _failures.keys()
	indices.sort()
	for index in indices:
		failures.append({"floor_index": index, "error": _failures[index]})
	last_error = ""
	return {"run_version": RUN_VERSION, "generator_version": Generator.VERSION, "map_set_id": _map_set_id, "current_floor": current_floor, "floor_configs": _configs.duplicate(true), "seed_snapshot": _source.capture_snapshot(), "floors": records, "generation_failures": failures}

## Preflight EVERY floor and RNG in candidates. No global mutation or signals
## until validation succeeds; caller then binds the active floor to its view.
func restore_snapshot(saved: Dictionary) -> bool:
	if not _valid_source() or saved.get("run_version") != RUN_VERSION or saved.get("generator_version") != Generator.VERSION:
		return _fail("Run/generator version mismatch")
	if not saved.get("map_set_id") is String or str(saved.map_set_id).strip_edges().is_empty() or not saved.get("floor_configs") is Array or not saved.get("floors") is Array or not saved.get("generation_failures", []) is Array or not saved.get("seed_snapshot") is Dictionary or not Session._integer(saved.get("current_floor")):
		return _fail("Invalid run snapshot structure")
	var configs := _normalize(saved.floor_configs)
	if configs.is_empty():
		return false
	var active_index := int(saved.current_floor)
	if active_index < 0 or active_index > configs.size():
		return _fail("Invalid saved current_floor")
	var seed_candidate := SeedRegistry.new(_content_version)
	if seed_candidate.restore_snapshot(saved.seed_snapshot) != OK:
		return _fail("Incompatible or invalid seed snapshot")
	var records: Dictionary = {}
	for record in saved.floors:
		if not record is Dictionary or not Session._integer(record.get("floor_index")) or not record.get("snapshot") is Dictionary or not record.get("state") is Dictionary:
			return _fail("Invalid saved floor record")
		var index := int(record.floor_index)
		if index < 1 or index > configs.size() or records.has(index):
			return _fail("Duplicate or out-of-range saved floor")
		if not _check_floor(record.snapshot, record.state, index, seed_candidate.get_main_seed(), configs, saved.map_set_id):
			return false
		if index != active_index and not record.state.pending.is_empty():
			return _fail("Inactive floor cannot have a pending encounter")
		records[index] = {"snapshot": record.snapshot.duplicate(true), "state": record.state.duplicate(true)}
	if active_index > 0 and not records.has(active_index):
		return _fail("Active floor missing from saved records")
	var failures: Dictionary = {}
	for failure in saved.get("generation_failures", []):
		if not failure is Dictionary or not Session._integer(failure.get("floor_index")) or not failure.get("error") is String or failure.error.is_empty():
			return _fail("Invalid saved generation failure")
		var index := int(failure.floor_index)
		if index < 1 or index > configs.size() or records.has(index) or failures.has(index):
			return _fail("Duplicate or out-of-range failed floor")
		failures[index] = failure.error
	# Commit the globally shared random context only after all preflight checks.
	if _source.restore_snapshot(saved.seed_snapshot) != OK:
		return _fail("Seed source rejected restore; active state preserved")
	_install(seed_candidate.get_main_seed(), configs, saved.map_set_id)
	_floors = records
	_failures = failures
	current_floor = active_index
	return true
