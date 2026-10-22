extends Node
## Persistence regression: real shop/event writers, with no native windows or player saves.
const Session = preload("res://systems/map/flat_2d/planar_map_session.gd")
var checks := 0
var failures := 0
var outcomes: Array[Dictionary] = []
var fixture_root := ""
var serial := 0

func _ready() -> void:
	call_deferred("_run")

func _run() -> void:
	get_tree().current_scene = null
	fixture_root = "user://restart-persistence-%d" % Time.get_ticks_usec()
	if not _check("unique QA user profile", str(ProjectSettings.get_setting("application/config/custom_user_dir_name", "")).begins_with("restart-persistence-qa-")):
		get_tree().quit(2)
		return
	for kind: String in ["shop", "event", "combined"]:
		for result: String in ["defeat", "victory"]:
			_matrix_case(kind, result)
	_check_named_strings()
	_check_invalid_data()
	_check_write_rollback()
	var report := {"checks": checks, "failures": failures, "outcomes": outcomes,
		"fixture_root": ProjectSettings.globalize_path(fixture_root), "engine": Engine.get_version_info().string}
	var report_path := fixture_root.path_join("results.json")
	var file := FileAccess.open(report_path, FileAccess.WRITE)
	if file != null: file.store_string(JSON.stringify(report, "\t"))
	print("RESTART_PERSISTENCE_RESULT ", JSON.stringify(report))
	get_tree().quit(0 if failures == 0 else 1)

func _new_config() -> Dictionary:
	serial += 1
	var config: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/config/main_menu_new_run.json"))
	config["run_id"] = "restart-persistence-%d" % serial
	return config

func _reset_fixture(label: String) -> bool:
	SaveGateway.save_path = fixture_root.path_join(label).path_join("game.json")
	EncounterFlow.session = null
	return _check(label + " isolated load", SaveGateway.load_current() == OK)

func _open_content(run: RunStateMachine, kind: String) -> void:
	var session := Session.new()
	session.map_id = run.current_map_id
	EncounterFlow.session = session
	for content: String in (["shop", "event"] if kind == "combined" else [kind]):
		var request := {"type": content, "map_id": run.current_map_id, "node_id": "fixture-" + content,
			"request_id": "fixture-" + content, "floor_index": 1}
		session.pending = request
		var error := RunShop.open(run, request) if content == "shop" else RunRandomEvents.open(run, request)
		_check(kind + " real " + content + " writer", error == OK)
	_check(kind + " runtime StringName provenance", _has_names(run.inventory_state))

func _matrix_case(kind: String, result: String) -> void:
	var label := kind + "-" + result
	if not _reset_fixture(label): return
	if not _check(label + " initial run", SaveGateway.start_new_run(label, _new_config()) == OK): return
	for cycle in 2:
		var run := SaveGateway.current_run()
		var run_id := run.run_id
		_open_content(run, kind)
		var inventory_before := _json(run.inventory_state)
		var error := run.set_health(0) if result == "defeat" else run.finish_victory()
		_check(label + " finish %d" % cycle, error == OK and not GlobalState.run_active and SaveGateway.current_run() == null and GlobalState.run_history.size() == cycle + 1)
		var record: Dictionary = GlobalState.run_history.back()
		_check(label + " final inventory preserved", _json(record.final_inventory.inventory_state) == inventory_before and record.result == result)
		var prepared := GlobalState.build_save_payload()
		_check(label + " JSON-safe prepared history", prepared.error == OK and GlobalStateMachine._is_json_safe(prepared.payload))
		error = SaveGateway.start_new_run(label + "-next", _new_config())
		outcomes.append({"case": label, "cycle": cycle, "new_run_error": error})
		if not _check(label + " same-process new run %d" % cycle, error == OK): return
		_check(label + " next run identity", SaveGateway.current_run().run_id != run_id and SaveGateway.current_run().active and GlobalState.run_history.size() == cycle + 1)
	# Save and cold-restore a live shop/event run as well as the ended records.
	var run := SaveGateway.current_run()
	_open_content(run, kind)
	var snapshot := _json(run.to_dictionary())
	var history := _json(GlobalState.run_history)
	var seeds := _json(SeedService.capture_snapshot())
	_check(label + " save before cold restore", SaveGateway.save_current() == OK)
	_check(label + " cold load", SaveGateway.load_current() == OK and SaveGateway.current_run() == null)
	_check(label + " cold continue", SaveGateway.continue_saved_run() == OK)
	_check(label + " cold state preserved", _json(SaveGateway.current_run().to_dictionary()) == snapshot and _json(GlobalState.run_history) == history and _json(SeedService.capture_snapshot()) == seeds)
	# Overwriting an active run must archive the same canonical inventory too.
	_check(label + " active overwrite", SaveGateway.start_new_run(label + "-overwrite", _new_config(), true) == OK)
	_check(label + " overwrite archives inventory", GlobalState.run_history.size() == 3 and _json(GlobalState.run_history.back().final_inventory.inventory_state) == _json(JSON.parse_string(snapshot).inventory_state))

func _check_named_strings() -> void:
	if not _reset_fixture("named-strings"): return
	GlobalState.run_history.append({"legacy": {&"named_key": [&"named_value", {&"nested": &"text"}]}})
	var raw := GlobalState.run_history.duplicate(true)
	var prepared := GlobalState.build_save_payload()
	_check("prior in-memory history canonicalizes named keys and values", prepared.error == OK and not _has_names(prepared.payload) and prepared.payload.run_history[0].legacy["named_key"] == ["named_value", {"nested": "text"}])
	_check("payload capture leaves prior in-memory history unchanged", _has_names(GlobalState.run_history) and GlobalState.run_history == raw)
	var validator := GlobalStateMachine.new()
	_check("external installer retains strict JSON validation", validator._install_save({"save_version": 1, "settings": {}, "run_history": raw, "active_run": null}) == ERR_INVALID_DATA)
	var json_data: Dictionary = JSON.parse_string(_json(prepared.payload))
	_check("legitimate JSON string form loads", validator._install_save(json_data) == OK)
	validator.free()
	_check("set_setting retains strict values", GlobalState.set_setting("named-setting", &"value") == ERR_INVALID_PARAMETER)

func _check_invalid_data() -> void:
	if not _reset_fixture("invalid-data"): return
	if not _check("invalid fixture start", SaveGateway.start_new_run("invalid", _new_config()) == OK): return
	var run := SaveGateway.current_run()
	var original_id := run.run_id
	var baseline_bytes := FileAccess.get_sha256(SaveGateway.save_path)
	var baseline_seeds := _json(SeedService.capture_snapshot())
	var object := RefCounted.new()
	var invalid: Array = [object, NAN, INF, -INF, Vector2.ONE, {1: "numeric key"}]
	for index in invalid.size():
		GlobalState.run_history.append({"invalid": invalid[index]})
		var data := {"save_version": 1, "settings": {}, "run_history": GlobalState.run_history.duplicate(true), "active_run": null}
		var validator := GlobalStateMachine.new()
		_check("invalid %d direct installer rejects" % index, validator._install_save(data) == ERR_INVALID_DATA)
		validator.free()
		_check("invalid %d capture rejects" % index, GlobalState.build_save_payload().error == ERR_INVALID_DATA)
		_check("invalid %d normal save rejects" % index, SaveGateway.save_current() == ERR_INVALID_DATA)
		_check("invalid %d new game rejects" % index, SaveGateway.start_new_run("invalid-next", _new_config(), true) == ERR_INVALID_DATA)
		_check("invalid %d rollback preserves disk/run/random/history" % index, FileAccess.get_sha256(SaveGateway.save_path) == baseline_bytes and SaveGateway.current_run() == run and run.run_id == original_id and run.active and GlobalState.run_active and _json(SeedService.capture_snapshot()) == baseline_seeds and GlobalState.run_history.size() == 1)
		GlobalState.run_history.clear()
	# The live snapshot is part of the same boundary; unsafe values cannot stringify away.
	run.inventory_state["invalid"] = object
	_check("unsafe live state rejects before save", GlobalState.build_save_payload().error == ERR_INVALID_DATA and SaveGateway.save_current() == ERR_INVALID_DATA and FileAccess.get_sha256(SaveGateway.save_path) == baseline_bytes)
	run.inventory_state.erase("invalid")
	_check("valid state still saves after invalid values removed", SaveGateway.save_current() == OK)

func _check_write_rollback() -> void:
	if not _reset_fixture("write-rollback"): return
	if not _check("write fixture start", SaveGateway.start_new_run("write-rollback", _new_config()) == OK): return
	var run := SaveGateway.current_run()
	_open_content(run, "combined")
	var bytes := FileAccess.get_sha256(SaveGateway.save_path)
	var state := _json(run.to_dictionary())
	var seeds := _json(SeedService.capture_snapshot())
	var history := _json(GlobalState.run_history)
	var temporary := SaveGateway.save_path + ".tmp"
	_check("real write failure fixture", DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(temporary)) == OK)
	_check("new game returns real write failure", SaveGateway.start_new_run("blocked-write", _new_config(), true) != OK)
	_check("write failure preserves old disk/run/random/history", FileAccess.get_sha256(SaveGateway.save_path) == bytes and SaveGateway.current_run() == run and GlobalState.run_active and _json(run.to_dictionary()) == state and _json(SeedService.capture_snapshot()) == seeds and _json(GlobalState.run_history) == history)
	_check("remove only fixture blocker", DirAccess.remove_absolute(ProjectSettings.globalize_path(temporary)) == OK)
	_check("new game succeeds after write recovers", SaveGateway.start_new_run("write-recovered", _new_config(), true) == OK)
	_check("recovered overwrite archives once", GlobalState.run_history.size() == 1 and GlobalState.run_history[0].run_id == run.run_id)

func _has_names(value: Variant) -> bool:
	if value is StringName: return true
	if value is Array:
		for child: Variant in value:
			if _has_names(child): return true
	if value is Dictionary:
		for key: Variant in value:
			if key is StringName or _has_names(value[key]): return true
	return false

func _json(value: Variant) -> String:
	return JSON.stringify(JSON.parse_string(JSON.stringify(value)))

func _check(label: String, passed: bool) -> bool:
	checks += 1
	if not passed: failures += 1
	print("%s %s" % ["PASS" if passed else "FAIL", label])
	return passed
