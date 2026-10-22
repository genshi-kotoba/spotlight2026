extends "res://tests/death_restart_selftest.gd"
## Event costs must stay nonlethal; an external run death still owns settlement.
func _run() -> void:
	get_tree().current_scene = null
	get_window().size = Vector2i(1920, 1080)
	SaveGateway.save_path = "user://death-restart-event-scene-%d/game.json" % Time.get_ticks_usec()
	EncounterFlow.relic_board_path = SaveGateway.save_path.get_base_dir().path_join("empty-board.json")
	_check("isolated event fixture", SaveGateway.load_current() == OK)
	_check("menu request", SceneTransition.change_scene_to_file(MENU) == OK)
	if not await _wait_scene(MENU): return _finish()
	for cycle in 2:
		await _click(get_tree().current_scene.get_node("按钮列/新游戏"))
		if not await _wait_scene(MAP): return _finish()
		var map := get_tree().current_scene
		var run := SaveGateway.current_run()
		run_ids.append(run.run_id)
		var id := _approach(map, "event")
		_check("event node fixture", not id.is_empty())
		if id.is_empty(): return _finish()
		var event_key := "%s/%s" % [map.session.map_id, id]
		if not run.inventory_state.has("events"): run.inventory_state["events"] = {}
		run.inventory_state.events[event_key] = {"index": 0, "stage": "choice", "plays": 0,
			"inputs": [], "offers": [], "result": "", "finished": false}
		if not await preload("res://tests/support/presentation_test_helper.gd").route_ready(get_tree(), 60.0):
			_check("event route presentation ready", false)
			return _finish()
		if not await _wait_scene(MAP): return _finish()
		map._interact()
		if not await _wait_scene(RandomEventCatalog.SCENE): return _finish()
		var event_ui := get_tree().current_scene
		_check("one-health event fixture", run.set_health(1) == OK)
		await _click(event_ui._content.get_child(0))
		await get_tree().process_frame
		_check("lethal event cost is refused by current rules", run.active and run.health == 1 and RunRandomEvents.state(run, event_ui.request).stage == "choice" and not event_ui._status_text.is_empty())
		_check("external event-scene health loss ends run", run.change_health(-1) == OK)
		var deadline := Time.get_ticks_msec() + 20000
		while not is_instance_valid(RunResults.view) or not RunResults.view.detail_ready:
			if Time.get_ticks_msec() > deadline:
				_check("event settlement ready", false)
				return _finish()
			await get_tree().process_frame
		_check("event scene death saved once", not GlobalState.run_active and SaveGateway.current_run() == null and GlobalState.run_history.size() == cycle + 1)
		await _capture("event-scene-%d-settlement" % cycle)
		await _click(RunResults.view.confirm_button)
		if not await _wait_scene(MENU): return _finish()
	await _click(get_tree().current_scene.get_node("按钮列/新游戏"))
	if not await _wait_scene(MAP): return _finish()
	_check("new run responds after two event scene deaths", SaveGateway.current_run().active and SaveGateway.save_current() == OK)
	_finish()
