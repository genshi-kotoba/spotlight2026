extends "res://tests/map_entry_input_selftest.gd"
var _request: Dictionary = {}

func _run() -> void:
	fixture_root = "res://.godot/event-flow-%d" % Time.get_ticks_usec()
	DirAccess.make_dir_recursive_absolute(fixture_root)
	SaveGateway.profile_path = fixture_root.path_join("profile.json")
	SaveGateway.slot_paths.assign([fixture_root.path_join("1.json"), fixture_root.path_join("2.json"), fixture_root.path_join("3.json")])
	SaveGateway._active_slot = 1
	_check("事件流隔离存档", SaveGateway._load_slot(1) == OK)
	var config: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/config/main_menu_new_run.json"))
	config.run_id = "event-flow-test"
	_check("事件流新局", SaveGateway.start_new_run("events-real-input", config) == OK)
	var view: Node = load(EncounterFlow.MAP_SCENE).instantiate()
	get_tree().root.add_child(view)
	get_tree().current_scene = view
	await _frames(8)
	var id := _approach_event(view)
	_check("地图有可交互事件节点", not id.is_empty())
	if id.is_empty(): get_tree().quit(1); return
	var run := SaveGateway.current_run()
	var expected := RandomEventCatalog.index_for_node(run.main_seed, view.session.map_id, id)
	var resources := ScenePreloader.node_status(view.session.map_id, id)
	_check("事件背景和专用场景已登记预加载", int(resources.total) >= 4)
	var seed_before := JSON.stringify(SeedService.capture_snapshot())
	await _press_e()
	var scene: Node = get_tree().current_scene
	_check("真实E打开独立随机事件场景", scene.scene_file_path == RandomEventCatalog.SCENE)
	if scene.scene_file_path != RandomEventCatalog.SCENE: get_tree().quit(1); return
	_request = scene.request.duplicate(true)
	var current := RunRandomEvents.state(run, _request)
	_check("背景编号严格对应设计顺序且不消费共享RNG", int(current.index) == expected and scene._background.texture.resource_path == RandomEventCatalog.background(expected) and JSON.stringify(SeedService.capture_snapshot()) == seed_before)
	await _capture_event("event-open.png")
	# 模拟关窗后的冷恢复，必须恢复原节点、同一事件及原有阶段。
	_check("事件中可以保存", SaveGateway.save_current() == OK)
	_check("冷启动载入档案", SaveGateway._load_slot(1) == OK)
	get_tree().change_scene_to_file(EncounterFlow.MAP_SCENE)
	await _frames(12)
	scene = get_tree().current_scene
	run = SaveGateway.current_run()
	_check("冷恢复自动进入同一随机事件而非Demo", scene.scene_file_path == RandomEventCatalog.SCENE and int(RunRandomEvents.state(run, scene.request).index) == expected)
	var gold := run.gold
	var options := RandomEventCatalog.choices(expected)
	var button := scene._content.get_child(options.size() - 1) as Button
	button.pressed.emit()
	await _frames(4)
	_check("离开选项进入结果展示并禁止重复领奖", RunRandomEvents.state(run, scene.request).stage == "result" and scene._content.get_child_count() == 0)
	await _capture_event("event-result.png")
	await get_tree().create_timer(2.3).timeout
	await _frames(8)
	view = get_tree().current_scene
	_check("结果展示后自动回地图并完成原节点", view.scene_file_path == EncounterFlow.MAP_SCENE and view.session.completed.has(id) and view.session.pending.is_empty() and run.gold == gold)
	_check("完成事件状态保留而不会重新生成奖励", run.inventory_state.events[RunRandomEvents.key(_request)].finished)
	print("随机事件地图交互与冷恢复：全部通过" if failures == 0 else "随机事件地图交互与冷恢复：失败%d项" % failures)
	get_tree().quit(failures)

func _approach_event(view: Node) -> String:
	for id: String in view.session.nodes:
		var node: Dictionary = view.session.nodes[id]
		if node.is_route_gate and node.type != "boss":
			view.session.completed[id] = true
			view.session.visits[id] = 1
	for cell: Dictionary in view._map_snapshot.cells: view.session.known[Session.key(Vector2i(cell.q, cell.r))] = true
	view._set_paused(false)
	for id: String in view.session.nodes:
		var node: Dictionary = view.session.nodes[id]
		if node.type != "event": continue
		for point: Array in node.footprint:
			for cell: Vector2i in Hex.neighbors(Session.coord(point)):
				var plane := Hex.to_plane(cell, 1.0)
				if view.session.can_stand(plane):
					view.session.actor_plane = plane
					view._sync_view(); view._sync_actor(false)
					view._selected = id; view._manual_selection = true; view._selection_origin = plane
					if id in view.session.nearby_nodes(): return id
	return ""

func _capture_event(name: String) -> void:
	if DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png(fixture_root.path_join(name))
