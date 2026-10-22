extends "res://tests/random_event_flow_selftest.gd"
## Real event choice/result/suspend/return paths; every save uses the QA profile.
const NODE_ELIXIR_REWARD := 0
var checks := 0
var resolved: Array[String] = []

func _run() -> void:
	get_tree().current_scene = null
	if not str(ProjectSettings.get_setting("application/config/custom_user_dir_name", "")).begins_with("result-confirmation-qa-"):
		print("EVENT_RESULT_CONFIRMATION_REFUSED non-QA user profile")
		get_tree().quit(2)
		return
	fixture_root = "user://event-result-confirmation-%d" % Time.get_ticks_usec()
	SaveGateway.save_path = fixture_root.path_join("game.json")
	EncounterFlow.relic_board_path = fixture_root.path_join("empty-board.json")
	_check("isolated save loads", SaveGateway.load_current() == OK)
	var config: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/config/main_menu_new_run.json"))
	config["run_id"] = "event-result-confirmation"
	_check("real run starts", SaveGateway.start_new_run("event-result-confirmation", config) == OK)
	MapEvents.node_interaction_resolved.connect(func(_request_id: String, node_id: String, status: String): resolved.append(node_id + ":" + status))
	var view: Node = load(EncounterFlow.MAP_SCENE).instantiate()
	get_tree().root.add_child(view)
	get_tree().current_scene = view
	await _frames(8)
	var scene: Node = await _open_silver_event(view)
	if scene == null: return _finish_results()
	var run := SaveGateway.current_run()
	var first_request: Dictionary = scene.request.duplicate(true)
	var resources := _resources(run)
	var saved := FileAccess.get_sha256(SaveGateway.save_path)
	await get_tree().create_timer(2.5).timeout
	await _frames(2)
	var stays: bool = is_instance_valid(scene) and get_tree().current_scene == scene and RunRandomEvents.state(run, first_request).stage == "result"
	_check("result remains readable beyond the former two-second timer", stays)
	if not stays: return _finish_results()
	_check("result explains explicit return", not scene._status_text.contains("自动") and scene._status_text.contains("返回地图"))
	_check("result describes the current platform's node reward", scene._status_text.contains("完成结点额外获得") == (NODE_ELIXIR_REWARD > 0))
	_check("waiting does not settle, reward again or write the save", _resources(run) == resources and FileAccess.get_sha256(SaveGateway.save_path) == saved and not EncounterFlow.session.completed.has(first_request.node_id))
	scene._refresh()
	scene._refresh()
	await get_tree().create_timer(2.3).timeout
	_check("refresh does not start another dismissal timer", is_instance_valid(scene) and get_tree().current_scene == scene and RunRandomEvents.state(run, first_request).stage == "result")
	var button := scene._content.get_node("EventReturnNow") as Button
	button.pressed.emit()
	button.pressed.emit()
	await _frames(8)
	view = get_tree().current_scene
	_check("explicit return finishes and returns to the real map", view.scene_file_path == EncounterFlow.MAP_SCENE and RunRandomEvents.state(run, first_request).stage == "done" and view.session.completed.has(first_request.node_id))
	_check("double return settles exactly once", resolved.count(str(first_request.node_id) + ":completed") == 1 and int(run.inventory_state.elixir) == int(resources.elixir) + NODE_ELIXIR_REWARD and run.gold == int(resources.gold))
	var completed_resources := _resources(run)
	saved = FileAccess.get_sha256(SaveGateway.save_path)
	await get_tree().create_timer(2.3).timeout
	_check("freed result scene has no stale timer writes", get_tree().current_scene == view and FileAccess.get_sha256(SaveGateway.save_path) == saved and _resources(run) == completed_resources and resolved.count(str(first_request.node_id) + ":completed") == 1)
	# Suspend an already-paid result, then re-enter it without choosing or paying again.
	scene = await _open_silver_event(view)
	if scene == null: return _finish_results()
	var second_request: Dictionary = scene.request.duplicate(true)
	resources = _resources(run)
	_check("result retains the existing suspension affordance", scene._suspend_button.visible)
	scene._suspend()
	await _frames(8)
	view = get_tree().current_scene
	_check("suspension preserves the paid result and unfinished node", view.scene_file_path == EncounterFlow.MAP_SCENE and RunRandomEvents.state(run, second_request).stage == "result" and not view.session.completed.has(second_request.node_id) and _resources(run) == resources)
	var id := _approach_event(view)
	_check("same unfinished event can be re-entered", id == str(second_request.node_id))
	await _press_e()
	scene = get_tree().current_scene
	_check("re-entry restores the saved result", scene.scene_file_path == RandomEventCatalog.SCENE and RunRandomEvents.state(run, scene.request).stage == "result" and _resources(run) == resources)
	await get_tree().create_timer(2.3).timeout
	_check("restored result also waits for explicit input", is_instance_valid(scene) and get_tree().current_scene == scene and RunRandomEvents.state(run, scene.request).stage == "result")
	if not is_instance_valid(scene): return _finish_results()
	button = scene._content.get_node("EventReturnNow") as Button
	button.pressed.emit()
	await _frames(8)
	_check("restored result completes without paying twice", get_tree().current_scene.scene_file_path == EncounterFlow.MAP_SCENE and int(run.inventory_state.elixir) == int(resources.elixir) + NODE_ELIXIR_REWARD and run.gold == int(resources.gold) and run.items == resources.items and run.deck_cards == resources.deck and resolved.count(str(second_request.node_id) + ":completed") == 1)
	completed_resources = _resources(run)
	await get_tree().create_timer(2.3).timeout
	_check("restored completion leaves all resources stable", _resources(run) == completed_resources and resolved.count(str(second_request.node_id) + ":completed") == 1)
	_finish_results()

func _open_silver_event(view: Node) -> Node:
	var id := _approach_event(view)
	_check("reachable event fixture exists", not id.is_empty())
	if id.is_empty(): return null
	var run := SaveGateway.current_run()
	if not run.inventory_state.has("events"): run.inventory_state["events"] = {}
	run.inventory_state.events[view.session.map_id + "/" + id] = {"index": 4, "stage": "choice", "plays": 0, "inputs": [], "offers": [], "result": "", "finished": false}
	await _press_e()
	var scene: Node = get_tree().current_scene
	_check("real event scene opens", scene.scene_file_path == RandomEventCatalog.SCENE)
	if scene.scene_file_path != RandomEventCatalog.SCENE: return null
	var gold := run.gold
	scene._choose(0)
	await _frames(2)
	_check("real choice grants once and saves the result", run.gold == gold + 300 and RunRandomEvents.state(run, scene.request).stage == "result" and SaveGateway._read_json(SaveGateway.save_path).data.active_run.run_snapshot.inventory_state.events[RunRandomEvents.key(scene.request)].stage == "result")
	return scene

func _resources(run: RunStateMachine) -> Dictionary:
	return {"gold": run.gold, "items": run.items.duplicate(true), "elixir": int(run.inventory_state.elixir), "deck": run.deck_cards.duplicate(true)}

func _check(label: String, passed: bool) -> void:
	checks += 1
	if not passed: failures += 1
	print("%s %s" % ["PASS" if passed else "FAIL", label])

func _finish_results() -> void:
	print("EVENT_RESULT_CONFIRMATION_RESULT ", JSON.stringify({"checks": checks, "failures": failures, "resolved": resolved, "fixture_root": ProjectSettings.globalize_path(fixture_root)}))
	get_tree().quit(0 if failures == 0 else 1)
