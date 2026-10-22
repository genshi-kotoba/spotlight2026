extends "res://tests/random_event_flow_selftest.gd"
## 隔离真实地图与存档；事件夹具只替换身份/阶段，交互与事务使用正式实现。

func _run() -> void:
	fixture_root = "user://event-suspend-chest"
	DirAccess.make_dir_recursive_absolute(fixture_root)
	SaveGateway.save_path = fixture_root.path_join("game-%d.json" % Time.get_ticks_usec())
	_check("隔离档案", SaveGateway.load_current() == OK)
	EncounterFlow.relic_board_path = fixture_root.path_join("empty-board.json")
	var config: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/config/main_menu_new_run.json"))
	config.run_id = "event-suspend-chest"
	_check("建立新局", SaveGateway.start_new_run("event-suspend-chest", config) == OK)
	var view: Node = load(EncounterFlow.MAP_SCENE).instantiate()
	get_tree().root.add_child(view)
	get_tree().current_scene = view
	await _frames(10)
	var event_id := _approach_event(view)
	_check("找到事件节点", not event_id.is_empty())
	await _press_e()
	var scene: Node = get_tree().current_scene
	if scene.scene_file_path != RandomEventCatalog.SCENE:
		_check("打开正式事件界面", false); get_tree().quit(1); return
	var run := SaveGateway.current_run()
	var event_request: Dictionary = scene.request.duplicate(true)
	var event_key := RunRandomEvents.key(event_request)
	for index in 12:
		run.inventory_state.events[event_key] = _event(index)
		scene._refresh()
		_check("EV-%03d提供统一悬置入口" % (index + 1), scene.has_node("OptionsColumn/EventSuspend") and scene._suspend_button.visible)
	await _capture_event("suspend-choice.png")
	_check("悬置按钮固定在滚动区外且完整位于屏幕内", scene._suspend_button.get_parent() == scene.get_node("OptionsColumn") and scene._suspend_button.get_global_rect().end.y <= scene.size.y and scene._suspend_button.get_global_rect().end.x <= scene.size.x)
	# 不依赖新增 API 的 RED 检查：当前 UI 的 inputs“取消并离开”会永久改变阶段。
	run.inventory_state.events[event_key] = _event(9, "inputs")
	scene._refresh()
	scene._close_deck_picker()
	await _capture_event("suspend-inputs.png")
	if not scene.has_node("OptionsColumn/EventSuspend"):
		print("EVENT_SUSPEND_CHEST_RESULT failures=%d" % failures)
		get_tree().quit(failures); return
	scene = await _test_paid_event(scene, run, event_request)
	run.inventory_state.events[event_key] = _event(9, "inputs")
	scene._refresh()
	scene._close_deck_picker()
	await _test_suspend_stages(scene, run, event_request)
	view = get_tree().current_scene
	run = SaveGateway.current_run()
	await _test_chest_and_pile(view, run)
	print("EVENT_SUSPEND_CHEST_RESULT failures=%d" % failures)
	get_tree().quit(failures)

func _event(index: int, stage := "choice") -> Dictionary:
	return {"index":index, "stage":stage, "plays":0, "inputs":[], "offers":[], "result":"", "finished":false}

func _test_paid_event(scene: Node, run: RunStateMachine, original: Dictionary) -> Node:
	run.inventory_state.events[RunRandomEvents.key(original)] = _event(2)
	run.gold = 2000
	scene._refresh()
	var error := RunRandomEvents.choose(run, scene.request, 0)
	var paid := RunRandomEvents.state(run, original)
	var silver_awarded := 300 if str(paid.result).contains("获得300银币") else 500 if str(paid.result).contains("获得500银币") else 0
	_check("付费事件选择只扣一次", error == OK and paid.plays == 1 and run.gold == 1600 + silver_awarded)
	var items := JSON.stringify(run.items)
	var gold := run.gold
	scene._refresh()
	await _capture_event("suspend-paid-result.png")
	await _press_escape()
	await _frames(10)
	var view: Node = get_tree().current_scene
	_check("已付费结果悬置保留抽取次数和奖励", RunRandomEvents.state(run, original) == paid and run.gold == gold and JSON.stringify(run.items) == items and not view.session.completed.has(original.node_id))
	_approach_id(view, str(original.node_id))
	await _press_e()
	scene = get_tree().current_scene
	_check("付费结果重新进入不重扣不重发", RunRandomEvents.state(run, scene.request) == paid and run.gold == gold and JSON.stringify(run.items) == items)
	scene._gamble_again()
	_check("继续抽取回到原有次数的choice", RunRandomEvents.state(run, scene.request).stage == "choice" and RunRandomEvents.state(run, scene.request).plays == 1)
	scene._suspend()
	await _frames(10)
	view = get_tree().current_scene
	_check("choice悬置未完成且保留已投入费用", not view.session.completed.has(original.node_id) and run.gold == gold and RunRandomEvents.state(run, original).plays == 1)
	_approach_id(view, str(original.node_id))
	await _press_e()
	return get_tree().current_scene

func _test_suspend_stages(scene: Node, run: RunStateMachine, original: Dictionary) -> void:
	var event_key := RunRandomEvents.key(original)
	var before_gold := run.gold
	var before_elixir := int(run.inventory_state.elixir)
	var before_deck := JSON.stringify(run.deck_cards)
	var first := str(run.deck_cards[0].copy_id)
	var second := str(run.deck_cards[1].copy_id)
	# 未确认选牌只保留勾选；确认后的素材和候选使用事件原有持久字段。
	scene._selected.assign([first, second])
	var current := RunRandomEvents.state(run, scene.request)
	var old_error: Error = SaveGateway._load_error
	SaveGateway._load_error = ERR_CANT_OPEN
	scene._suspend()
	_check("悬置保存失败回滚事件及请求，不消耗素材", get_tree().current_scene == scene and not EncounterFlow.session.pending.is_empty() and scene.request == EncounterFlow.session.pending and RunRandomEvents.state(run, scene.request) == current and JSON.stringify(run.deck_cards) == before_deck)
	SaveGateway._load_error = old_error
	scene._suspend()
	await _frames(10)
	var view: Node = get_tree().current_scene
	_check("inputs悬置回地图，节点未完成且不赠药", view.scene_file_path == EncounterFlow.MAP_SCENE and view.session.pending.is_empty() and not view.session.completed.has(original.node_id) and run.gold == before_gold and int(run.inventory_state.elixir) == before_elixir)
	_check("inputs悬置保留阶段和勾选", RunRandomEvents.state(run, original).stage == "inputs" and RunRandomEvents.state(run, original).selection_draft == [first, second])
	_check("悬置档案可冷读取", SaveGateway.load_current() == OK)
	get_tree().change_scene_to_file(EncounterFlow.MAP_SCENE)
	await _frames(10)
	view = get_tree().current_scene
	run = SaveGateway.current_run()
	_check("冷恢复留在地图，无自动完成或重新进入", view.scene_file_path == EncounterFlow.MAP_SCENE and view.session.pending.is_empty() and not view.session.completed.has(original.node_id))
	_approach_id(view, str(original.node_id))
	await _press_e()
	scene = get_tree().current_scene
	_check("重新进入同事件保留选牌并未重抽", RunRandomEvents.state(run, scene.request).stage == "inputs" and scene._deck_picker._selected == [first, second])
	scene._close_deck_picker()
	_check("确认合成素材生成候选", RunRandomEvents.select(run, scene.request, [first, second]) == OK)
	current = RunRandomEvents.state(run, scene.request)
	_check("合成候选阶段封存且未消耗素材", current.stage == "reward" and current.inputs == [first, second] and current.offers.size() == 3 and JSON.stringify(run.deck_cards) == before_deck)
	scene._refresh()
	await _capture_event("suspend-reward.png")
	scene._suspend()
	await _frames(10)
	view = get_tree().current_scene
	_approach_id(view, str(original.node_id))
	await _press_e()
	scene = get_tree().current_scene
	_check("reward重新进入保留相同投入和候选", RunRandomEvents.state(run, scene.request).inputs == current.inputs and RunRandomEvents.state(run, scene.request).offers == current.offers)
	_check("领取已生成候选", RunRandomEvents.select(run, scene.request, [str(current.offers[0])]) == OK)
	current = RunRandomEvents.state(run, scene.request)
	var awarded_deck := JSON.stringify(run.deck_cards)
	scene._refresh()
	scene._suspend()
	await _frames(10)
	view = get_tree().current_scene
	await get_tree().create_timer(2.2).timeout
	_check("result悬置使旧自动收尾失效且不重复奖励", get_tree().current_scene == view and not view.session.completed.has(original.node_id) and RunRandomEvents.state(run, original) == current and JSON.stringify(run.deck_cards) == awarded_deck)
	_approach_id(view, str(original.node_id))
	await _press_e()
	scene = get_tree().current_scene
	_check("result重新进入保留结果且不能重选", RunRandomEvents.state(run, scene.request).stage == "result" and JSON.stringify(run.deck_cards) == awarded_deck)
	scene._finish()
	await _frames(10)
	view = get_tree().current_scene
	_check("完成结果正常收尾且不额外赠药", view.session.completed.has(original.node_id) and int(run.inventory_state.elixir) == before_elixir and JSON.stringify(run.deck_cards) == awarded_deck)
	# 用第二个真实事件构造事件战斗保存失败留下的待结算结果。
	var pending_id := _approach_event(view)
	await _press_e()
	scene = get_tree().current_scene
	var pending := _event(6, "battle")
	pending.event_battle_index = 41
	pending.pending_outcome = {"status":"victory", "map_id":scene.request.map_id, "node_id":pending_id, "battle_index":41, "event_combat":{"kind":"stone", "event_key":RunRandomEvents.key(scene.request), "finished":true, "floor":1, "total_damage":0}}
	run.inventory_state.events[RunRandomEvents.key(scene.request)] = pending
	scene._refresh()
	var pending_request: Dictionary = scene.request.duplicate(true)
	scene._suspend()
	await _frames(10)
	view = get_tree().current_scene
	_check("待结算战斗悬置保留原结果且节点未完成", not view.session.completed.has(pending_id) and RunRandomEvents.state(run, pending_request) == pending and run.current_battle == null)
	_check("待结算战斗可冷恢复", SaveGateway.load_current() == OK)
	get_tree().change_scene_to_file(EncounterFlow.MAP_SCENE)
	await _frames(10)
	view = get_tree().current_scene
	run = SaveGateway.current_run()
	_approach_id(view, pending_id)
	await _press_e()
	scene = get_tree().current_scene
	var restored_pending := RunRandomEvents.state(run, scene.request)
	# JSON 读盘把整数变成 float；双方归一化后比较完整待结算内容。
	_check("待结算重新进入不重开战斗", JSON.stringify(JSON.parse_string(JSON.stringify(restored_pending))) == JSON.stringify(JSON.parse_string(JSON.stringify(pending))) and run.current_battle == null)
	scene._retry_event_settlement()
	_check("原战斗结果可重试结算", RunRandomEvents.state(run, scene.request).stage == "result" and RunRandomEvents.state(run, scene.request).settled_battle_index == 41)
	scene._finish()
	await _frames(10)

func _test_chest_and_pile(view: Node, run: RunStateMachine) -> void:
	var chest_id := _approach_kind(view, "chest")
	_check("找到宝箱节点", not chest_id.is_empty())
	var gold := run.gold
	var elixir := int(run.inventory_state.elixir)
	var items := run.items.size()
	var old_error: Error = SaveGateway._load_error
	SaveGateway._load_error = ERR_CANT_OPEN
	await _press_e()
	var popup: NodeLootPopup = view._node_loot_popup
	_check("宝箱自动领取失败回滚并保留重试", is_instance_valid(popup) and not popup._claimed and not view.session.pending.is_empty() and not view.session.completed.has(chest_id) and run.gold == gold and int(run.inventory_state.elixir) == elixir and run.items.size() == items)
	_check("宝箱失败不提供稍后领取", popup._close_button.disabled)
	SaveGateway._load_error = old_error
	popup._claim()
	_check("宝箱重试立即入包并完成", popup._claimed and view.session.completed.has(chest_id) and view.session.pending.is_empty() and int(run.inventory_state.elixir) == elixir)
	var record := RunNodeLoot.record(run, popup.request)
	_check("宝箱账本封存为已领且结果只读", record.claimed and popup._claim_button.disabled)
	await _capture_event("chest-collected.png")
	gold = run.gold; items = run.items.size(); elixir = int(run.inventory_state.elixir)
	popup._claim(); popup._claim()
	_check("重复点击不重复领取", run.gold == gold and run.items.size() == items and int(run.inventory_state.elixir) == elixir)
	popup._close()
	await _frames(3)
	_check("宝箱已领档案可冷读取", SaveGateway.load_current() == OK)
	get_tree().change_scene_to_file(EncounterFlow.MAP_SCENE)
	await _frames(10)
	view = get_tree().current_scene; run = SaveGateway.current_run()
	_check("宝箱冷恢复保持完成且无重复奖励", view.session.completed.has(chest_id) and run.gold == gold and run.items.size() == items and int(run.inventory_state.elixir) == elixir)
	# 本层只有一个宝箱。仅重置隔离夹具的该节点和账本，另测无故障首次交互。
	var next_chest := chest_id
	view.session.completed.erase(chest_id)
	view.session.visits.erase(chest_id)
	run.inventory_state.node_loot.erase(RunNodeLoot.key(view.session.map_id, chest_id))
	_check("重置隔离宝箱夹具用于首次交互", _approach_id(view, next_chest))
	var saves := [0]
	var count_save := func(): saves[0] += 1
	SaveGateway.save_changed.connect(count_save)
	await _press_e()
	SaveGateway.save_changed.disconnect(count_save)
	popup = view._node_loot_popup
	_check("首次地图交互宝箱立即领取且只保存一次", is_instance_valid(popup) and popup._claimed and view.session.completed.has(next_chest) and view.session.pending.is_empty() and saves[0] == 1 and int(run.inventory_state.elixir) == elixir)
	gold = run.gold; items = run.items.size(); elixir = int(run.inventory_state.elixir)
	popup._close()
	await _frames(3)
	var pile_id := _approach_kind(view, "pile")
	_check("找到残堆节点", not pile_id.is_empty())
	await _press_e()
	popup = view._node_loot_popup
	_check("残堆保留原有手动领取与稍后入口", is_instance_valid(popup) and not popup._claimed and not popup._close_button.disabled and not view.session.completed.has(pile_id) and int(run.inventory_state.elixir) == elixir)
	await _capture_event("pile-unchanged.png")
	popup._close()
	await _frames(3)
	_check("残堆稍后领取不完成不发奖", view.session.pending.is_empty() and not view.session.completed.has(pile_id) and run.gold == gold and run.items.size() == items and int(run.inventory_state.elixir) == elixir)

func _approach_kind(view: Node, kind: String) -> String:
	for id: String in view.session.nodes:
		if view.session.nodes[id].type == kind and not view.session.completed.has(id) and _approach_id(view, id): return id
	return ""

func _press_escape() -> void:
	await preload("res://tests/support/presentation_test_helper.gd").route_ready(get_tree())
	# 夹具刚关闭过自动选牌弹窗；等待 queue_free 生效，避免旧弹窗消费 Esc。
	await get_tree().process_frame
	var event := InputEventKey.new()
	event.keycode = KEY_ESCAPE
	event.physical_keycode = KEY_ESCAPE
	event.pressed = true
	get_viewport().push_input(event, true)
	event = event.duplicate()
	event.pressed = false
	get_viewport().push_input(event, true)

func _approach_id(view: Node, id: String) -> bool:
	view._set_paused(false)
	for point: Array in view.session.nodes[id].footprint:
		for cell: Vector2i in Hex.neighbors(Session.coord(point)):
			var plane := Hex.to_plane(cell, 1.0)
			if view.session.can_stand(plane):
				view.session.actor_plane = plane
				view._sync_view(); view._sync_actor(false)
				view._selected = id; view._manual_selection = true; view._selection_origin = plane
				if id in view.session.nearby_nodes(): return true
	return false
