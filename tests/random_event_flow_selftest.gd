extends "res://tests/map_entry_input_selftest.gd"
var _request: Dictionary = {}

func _run() -> void:
	fixture_root = "res://.godot/event-flow-%d" % Time.get_ticks_usec()
	DirAccess.make_dir_recursive_absolute(fixture_root)
	SaveGateway.save_path = fixture_root.path_join("game.json")
	_check("事件流隔离存档", SaveGateway.load_current() == OK)
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
	var expected := RandomEventCatalog.index_for_map_node(run.main_seed, view.session.map_id, view.session.nodes[id])
	var resources := ScenePreloader.node_status(view.session.map_id, id)
	_check("事件背景和专用场景已登记预加载", int(resources.total) >= 4)
	var seed_before := JSON.stringify(SeedService.capture_snapshot())
	await _press_e()
	var scene: Node = get_tree().current_scene
	_check("真实E打开独立随机事件场景", scene.scene_file_path == RandomEventCatalog.SCENE)
	if scene.scene_file_path != RandomEventCatalog.SCENE: get_tree().quit(1); return
	_check("事件页无边框无全屏暗罩", scene.get_children().filter(func(node: Node): return node is Control).size() == 2 and scene.has_node("EventBackground") and scene.has_node("OptionsColumn"))
	_check("背景铺满，选项列位于右侧且不出屏", scene._background.get_rect().size.is_equal_approx(scene.size) and scene.get_node("OptionsColumn").position.x >= scene.size.x * 0.5 and scene.get_node("OptionsColumn").get_rect().end.x <= scene.size.x)
	_request = scene.request.duplicate(true)
	var current := RunRandomEvents.state(run, _request)
	_check("背景编号严格对应设计顺序且不消费共享RNG", int(current.index) == expected and scene._background.texture.resource_path == RandomEventCatalog.background(expected) and JSON.stringify(SeedService.capture_snapshot()) == seed_before)
	await _capture_event("event-open.png")
	# 模拟关窗后的冷恢复，必须恢复原节点、同一事件及原有阶段。
	_check("事件中可以保存", SaveGateway.save_current() == OK)
	_check("冷启动载入档案", SaveGateway.load_current() == OK)
	get_tree().change_scene_to_file(EncounterFlow.MAP_SCENE)
	await _frames(12)
	scene = get_tree().current_scene
	run = SaveGateway.current_run()
	_check("冷恢复自动进入同一随机事件而非Demo", scene.scene_file_path == RandomEventCatalog.SCENE and int(RunRandomEvents.state(run, scene.request).index) == expected)
	var gold := run.gold
	var elixir := int(run.inventory_state.elixir)
	var options := RandomEventCatalog.choices(expected)
	var button := scene._content.get_child(options.size() - 1) as Button
	button.pressed.emit()
	await _frames(4)
	_check("结果展示提供立即返回按钮且禁止重复选择奖励", RunRandomEvents.state(run, scene.request).stage == "result" and scene._content.get_child_count() == 1 and scene._content.has_node("EventReturnNow"))
	await _capture_event("event-result.png")
	await get_tree().create_timer(2.3).timeout
	await _frames(8)
	view = get_tree().current_scene
	_check("结果展示后自动回地图并完成原节点", view.scene_file_path == EncounterFlow.MAP_SCENE and view.session.completed.has(id) and view.session.pending.is_empty() and run.gold == gold)
	_check("完成事件状态保留而不会重新生成奖励", run.inventory_state.events[RunRandomEvents.key(_request)].finished)
	_check("随机事件完成不额外赠送万灵药", int(run.inventory_state.elixir) == elixir)
	var next_id := _approach_event(view)
	_check("还有另一个未完成事件用于测试立即返回", not next_id.is_empty() and next_id != id)
	await _press_e()
	scene = get_tree().current_scene
	var next_request: Dictionary = scene.request.duplicate(true)
	var next_state := RunRandomEvents.state(run, next_request)
	options = RandomEventCatalog.choices(int(next_state.index))
	button = scene._content.get_child(options.size() - 1) as Button
	button.pressed.emit()
	await _frames(4)
	var result_before := JSON.stringify(RunRandomEvents.state(run, next_request))
	button = scene._content.get_node("EventReturnNow") as Button
	button.pressed.emit()
	button.pressed.emit()
	await _frames(8)
	view = get_tree().current_scene
	_check("连续点击立即返回只完成一次原节点", view.scene_file_path == EncounterFlow.MAP_SCENE and view.session.completed.has(next_id) and view.session.pending.is_empty())
	var saved_after := FileAccess.get_file_as_string(SaveGateway.save_path)
	await get_tree().create_timer(2.3).timeout
	await _frames(3)
	_check("旧自动返回计时器不会重复提交或改写存档", get_tree().current_scene == view and FileAccess.get_file_as_string(SaveGateway.save_path) == saved_after and run.gold == gold and not result_before.is_empty())
	# 本层只配置两个事件；在隔离夹具中重置第二个节点，再走真实交互与死亡入口。
	view.session.completed.erase(next_id)
	view.session.visits.erase(next_id)
	run.inventory_state.events.erase(RunRandomEvents.key(next_request))
	var death_id := _approach_event(view)
	_check("另一个事件用于真实事件死亡结算", not death_id.is_empty())
	if death_id.is_empty(): get_tree().quit(1); return
	await _press_e()
	scene = get_tree().current_scene
	var death_name: String = RandomEventCatalog.NAMES[int(RunRandomEvents.state(run, scene.request).index)]
	_check("事件内生命归零终止对局", run.set_health(0) == OK)
	var deadline := Time.get_ticks_msec() + 18000
	while (not is_instance_valid(RunResults.view) or not RunResults.view.detail_ready) and Time.get_ticks_msec() < deadline: await get_tree().process_frame
	_check("事件死亡结算显示真实事件名称和该层战斗背景", is_instance_valid(RunResults.view) and RunResults.view.detail_ready and RunResults.view.record.location_name == death_name and RunResults.view.background.texture.resource_path == preload("res://ui/battle/battle_environment.gd").path_for_floor(1))
	if is_instance_valid(RunResults.view): RunResults.view.confirm_button.pressed.emit()
	deadline = Time.get_ticks_msec() + 8000
	while (is_instance_valid(RunResults.view) or SceneTransition.is_loading()) and Time.get_ticks_msec() < deadline: await get_tree().process_frame
	_check("事件死亡确认后返回主菜单并保存一次记录", get_tree().current_scene.scene_file_path == "res://ui/main_menu/main_menu.tscn" and GlobalState.run_history.size() == 1 and not GlobalState.run_active)
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
		if node.type != "event" or view.session.completed.has(id): continue
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
