extends "res://tests/event_suspend_chest_selftest.gd"
## 使用正式事件请求/背包事务；仅事件身份和每例重用节点属于隔离夹具。
## RED 仅判断界面入口，旧产品不静态引用新增恢复 API。
var _event_id := ""
var _event_request: Dictionary = {}
var _cases := 0

func _run() -> void:
	fixture_root = "user://event-material-recovery"
	DirAccess.make_dir_recursive_absolute(fixture_root)
	SaveGateway.save_path = fixture_root.path_join("game-%d.json" % Time.get_ticks_usec())
	_check("素材恢复隔离存档", SaveGateway.load_current() == OK)
	EncounterFlow.relic_board_path = fixture_root.path_join("empty-board.json")
	var config: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/config/main_menu_new_run.json"))
	config.run_id = "event-material-recovery"
	_check("素材恢复测试新局", SaveGateway.start_new_run("event-material-recovery", config) == OK)
	var view: Node = load(EncounterFlow.MAP_SCENE).instantiate()
	get_tree().root.add_child(view)
	get_tree().current_scene = view
	await _frames(10)
	_event_id = _approach_event(view)
	_check("找到实际事件交互节点", not _event_id.is_empty())
	if _event_id.is_empty(): get_tree().quit(1); return
	await _synthesis_case()
	await _upgrade_case()
	await _fragment_item_case(false)
	await _fragment_item_case(true)
	await _fragment_replaced_cell_case()
	_check("五种素材失效场景均已执行", _cases == 5)
	print("EVENT_MATERIAL_RECOVERY_RESULT cases=%d failures=%d" % [_cases, failures])
	get_tree().quit(failures)

func _new_case(index: int) -> Node:
	var view: Node = get_tree().current_scene
	var run := SaveGateway.current_run()
	# 一层真实地图只有两个事件。各例重用同一节点，不清理其他局内数据或奖励账本。
	view.session.completed.erase(_event_id)
	view.session.visits.erase(_event_id)
	if not run.inventory_state.has("events"): run.inventory_state.events = {}
	run.inventory_state.events["%s/%s" % [view.session.map_id, _event_id]] = _event(index)
	_check("EV-%03d事件夹具就绪" % (index + 1), _approach_id(view, _event_id))
	await _press_e()
	var scene: Node = get_tree().current_scene
	_event_request = scene.request.duplicate(true)
	_check("EV-%03d沿正式界面进入素材阶段" % (index + 1), RunRandomEvents.choose(run, scene.request, 0) == OK)
	scene._refresh()
	scene._close_deck_picker()
	_cases += 1
	return scene

func _suspend_scene(scene: Node) -> Node:
	scene._close_deck_picker()
	scene._close_upgrade_picker()
	scene._suspend()
	await _frames(8)
	return get_tree().current_scene

func _reenter(view: Node) -> Node:
	_check("悬置节点仍可再次进入", not view.session.completed.has(_event_id) and _approach_id(view, _event_id))
	await _press_e()
	return get_tree().current_scene

func _valid_source_cannot_reroll(scene: Node, label: String) -> void:
	if not scene.has_method("_reselect_inputs"): return
	var run := SaveGateway.current_run()
	var before := JSON.stringify(RunRandomEvents.state(run, scene.request))
	var resources := _resources(run)
	scene._reselect_inputs()
	_check(label + "有效素材不能免费重抽候选", JSON.stringify(RunRandomEvents.state(run, scene.request)) == before and _resources(run) == resources and _recovery_button(scene) == null)

func _recover(scene: Node, label: String) -> bool:
	var run := SaveGateway.current_run()
	var button := _recovery_button(scene)
	_check(label + "素材失效后显示重新选择素材入口", button != null)
	if button == null:
		await _suspend_scene(scene)
		return false
	var current := RunRandomEvents.state(run, scene.request)
	var resources := _resources(run)
	_check(label + "过期候选不能发奖或消耗新素材", RunRandomEvents.select(run, scene.request, [str(current.offers[0])]) != OK and RunRandomEvents.state(run, scene.request) == current and _resources(run) == resources)
	await _capture_event(label + "-stale.png")
	var old_error: Error = SaveGateway._load_error
	SaveGateway._load_error = ERR_CANT_OPEN
	button.pressed.emit()
	await _frames(2)
	_check(label + "重新选材保存失败完整回滚", RunRandomEvents.state(run, scene.request) == current and _resources(run) == resources and _recovery_button(scene) != null)
	SaveGateway._load_error = old_error
	scene._reselect_inputs()
	var reset := RunRandomEvents.state(run, scene.request)
	var cleared: bool = reset.stage == "inputs" and reset.inputs.is_empty() and reset.offers.is_empty()
	for field: String in ["selection_draft", "input_fragment", "upgrade_input_id", "upgrade_source_kind", "upgrade_source_label", "upgrade_offers"]:
		cleared = cleared and not reset.has(field)
	_check(label + "恢复只清除旧选择和候选，不发放物资", cleared and _resources(run) == resources)
	scene._close_deck_picker()
	return true

func _finish_case(scene: Node, label: String) -> void:
	var run := SaveGateway.current_run()
	_check(label + "新素材可以真实完成事件", RunRandomEvents.state(run, scene.request).stage == "result")
	var resources := _resources(run)
	_check(label + "重复确认不能重复结算", RunRandomEvents.select(run, scene.request, ["stale-retry"]) != OK and _resources(run) == resources)
	scene._refresh()
	scene._finish()
	await _frames(8)
	var view: Node = get_tree().current_scene
	_check(label + "确认结果正常完成原节点", view.scene_file_path == EncounterFlow.MAP_SCENE and view.session.completed.has(_event_id) and view.session.pending.is_empty())

func _synthesis_case() -> void:
	var scene := await _new_case(9)
	var run := SaveGateway.current_run()
	var original := [str(run.deck_cards[0].copy_id), str(run.deck_cards[1].copy_id)]
	_check("EV010封存两张素材和奖励", RunRandomEvents.select(run, scene.request, original) == OK and RunRandomEvents.state(run, scene.request).stage == "reward")
	scene._refresh()
	_valid_source_cannot_reroll(scene, "EV010")
	var view := await _suspend_scene(scene)
	_check("EV010悬置后可合法删除已选副本", run.remove_card_at(0) == OK and SaveGateway.save_current() == OK)
	var old_offers: Array = RunRandomEvents.state(run, _event_request).offers.duplicate()
	var count := run.deck_cards.size()
	_check("EV010素材失效存档可冷读取", SaveGateway.load_current() == OK)
	get_tree().change_scene_to_file(EncounterFlow.MAP_SCENE)
	await _frames(8)
	view = get_tree().current_scene
	run = SaveGateway.current_run()
	scene = await _reenter(view)
	_check("EV010冷恢复不授予原奖励且保留旧候选", run.deck_cards.size() == count and RunRandomEvents.state(run, scene.request).offers == old_offers)
	if not await _recover(scene, "EV010"): return
	var fresh: Array[String] = []
	for card: Dictionary in run.deck_cards:
		if str(card.copy_id) not in original and fresh.size() < 2: fresh.append(str(card.copy_id))
	_check("EV010重新选择仍有效的两张素材", RunRandomEvents.select(run, scene.request, fresh) == OK)
	var selected := RunRandomEvents.state(run, scene.request)
	_check("EV010确认新候选后只消耗新选择", RunRandomEvents.select(run, scene.request, [str(selected.offers[0])]) == OK and run.deck_cards.size() == count - 1 and run.deck_cards.any(func(card: Dictionary): return str(card.copy_id) == original[1]) and not run.deck_cards.any(func(card: Dictionary): return str(card.copy_id) in fresh))
	await _finish_case(scene, "EV010")

func _upgrade_case() -> void:
	var run := SaveGateway.current_run()
	var lines: Array[String] = []
	RunRandomEvents.give(run, "common_pack", lines)
	var source := str(run.items.back().item_id)
	RunRandomEvents.give(run, "common_pack", lines)
	var fresh := str(run.items.back().item_id)
	var scene := await _new_case(10)
	_check("EV011普通卡包生成升级候选", RunRandomEvents.select(run, scene.request, [source]) == OK and RunRandomEvents.state(run, scene.request).stage == "reward")
	scene._refresh()
	_valid_source_cannot_reroll(scene, "EV011")
	var view := await _suspend_scene(scene)
	_check("EV011悬置期间可正常打开原卡包", RunRewards.open_pack(run, source) == OK and not RunRewards.item(run, source).options.is_empty())
	var opened := RunRewards.item(run, source)
	var count := run.items.size()
	scene = await _reenter(view)
	if not await _recover(scene, "EV011"): return
	_check("EV011新未开封卡包可重新生成候选", RunRandomEvents.select(run, scene.request, [fresh]) == OK and RunRandomEvents.state(run, scene.request).stage == "reward")
	var current := RunRandomEvents.state(run, scene.request)
	_check("EV011只消耗新卡包，旧已打开卡包不受影响", RunRandomEvents.select(run, scene.request, [str(current.offers[0])]) == OK and run.items.size() == count and RunRewards.item(run, source) == opened and RunRewards.item(run, fresh).is_empty())
	await _finish_case(scene, "EV011")

func _fragment_item_case(move_to_board: bool) -> void:
	var run := SaveGateway.current_run()
	var label := "EV009-moved" if move_to_board else "EV009-discarded"
	var source := _add_fragment(run, label + "-source")
	var fragment := str(RunRewards.item(run, source).fragment_id)
	var fresh := "" if move_to_board else _add_fragment(run, label + "-fresh")
	var scene := await _new_case(8)
	_check(label + "物品身份生成交换候选", RunRandomEvents.select(run, scene.request, ["item:" + source]) == OK)
	scene._refresh()
	_valid_source_cannot_reroll(scene, label)
	var view := await _suspend_scene(scene)
	var error := RunRewards.equip_fragment(run, source, 1) if move_to_board else RunRewards.discard_item(run, source)
	_check(label + "悬置期间素材可合法装配或丢弃", error == OK and RunRewards.item(run, source).is_empty())
	var count := run.items.size()
	scene = await _reenter(view)
	if not await _recover(scene, label): return
	var token := "cell:1" if move_to_board else "item:" + fresh
	_check(label + "重新选择当前位置有效残片", RunRandomEvents.select(run, scene.request, [token]) == OK)
	var current := RunRandomEvents.state(run, scene.request)
	_check(label + "新候选只发一份残片", RunRandomEvents.select(run, scene.request, [str(current.offers[0])]) == OK and run.items.size() == count + (1 if move_to_board else 0) and RunRewards.item(run, source).is_empty() and (str(run.inventory_state.relic_board.cells[1]).is_empty() if move_to_board else RunRewards.item(run, fresh).is_empty()))
	if move_to_board: _check(label + "旧位置未被回滚复制", not run.items.any(func(item: Dictionary): return item.get("fragment_id") == fragment and item.get("item_id") == source))
	await _finish_case(scene, label)

func _fragment_replaced_cell_case() -> void:
	var run := SaveGateway.current_run()
	var source := _add_fragment(run, "cell-original")
	var original := str(RunRewards.item(run, source).fragment_id)
	var replacement := _add_fragment(run, "cell-replacement")
	var replacement_fragment := str(RunRewards.item(run, replacement).fragment_id)
	_check("EV009同格替换夹具残片不同", original != replacement_fragment and RunRewards.equip_fragment(run, source, 0) == OK)
	var scene := await _new_case(8)
	_check("EV009保存原格残片身份和候选", RunRandomEvents.select(run, scene.request, ["cell:0"]) == OK)
	scene._refresh()
	var view := await _suspend_scene(scene)
	_check("EV009悬置期间同一格可替换残片", RunRewards.equip_fragment(run, replacement, 0) == OK and str(run.inventory_state.relic_board.cells[0]) == replacement_fragment and str(RunRewards.item(run, replacement).fragment_id) == original)
	var count := run.items.size()
	scene = await _reenter(view)
	if not await _recover(scene, "EV009-cell-replaced"): return
	_check("EV009同格替换后必须重新确认新素材", RunRandomEvents.select(run, scene.request, ["cell:0"]) == OK)
	var current := RunRandomEvents.state(run, scene.request)
	_check("EV009仅在重选后消耗新格残片，原残片保留", RunRandomEvents.select(run, scene.request, [str(current.offers[0])]) == OK and str(run.inventory_state.relic_board.cells[0]).is_empty() and str(RunRewards.item(run, replacement).fragment_id) == original and run.items.size() == count + 1)
	await _finish_case(scene, "EV009-cell-replaced")

func _add_fragment(run: RunStateMachine, purpose: String) -> String:
	var rng := RandomEventCatalog.stream(str(run.main_seed), str(run.current_map_id), _event_id, purpose)
	var lines: Array[String] = []
	RunRandomEvents.give_fragment(run, RelicCatalog.generate(rng), lines)
	return str(run.items.back().item_id)

func _resources(run: RunStateMachine) -> String:
	return JSON.stringify({"items":run.items, "deck":run.deck_cards, "gold":run.gold, "elixir":run.inventory_state.elixir, "next_item":run.inventory_state.next_item})

func _recovery_button(scene: Node) -> Button:
	for button: Button in scene._content.find_children("*", "Button", true, false):
		if button.text == "重新选择素材": return button
	return null
