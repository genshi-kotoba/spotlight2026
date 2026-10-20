extends "res://tests/random_event_flow_selftest.gd"

func _run() -> void:
	fixture_root = "res://.godot/synthesis-picker-%d" % Time.get_ticks_usec()
	DirAccess.make_dir_recursive_absolute(fixture_root)
	SaveGateway.save_path = fixture_root.path_join("game.json")
	_check("合成选牌使用隔离存档", SaveGateway.load_current() == OK)
	var config: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/config/main_menu_new_run.json"))
	config.run_id = "synthesis-picker-test"
	_check("测试新局", SaveGateway.start_new_run("synthesis-picker-test", config) == OK)
	var run := SaveGateway.current_run()
	for index in 42: RunRandomEvents.add_card(run, str(index % 20 + 1))
	run.deck_cards[0].enchantments = ["damage_50"]
	var view: Node = load(EncounterFlow.MAP_SCENE).instantiate()
	get_tree().root.add_child(view)
	get_tree().current_scene = view
	await _frames(8)
	_check("找到真实事件交互点", not _approach_event(view).is_empty())
	await _press_e()
	var scene: Node = get_tree().current_scene
	if scene.scene_file_path != RandomEventCatalog.SCENE:
		_check("进入真实事件页面", false)
		get_tree().quit(1)
		return
	# 仅夹具指定素材合成身份，沿用真实节点请求、事务、场景与输入。
	var state := RunRandomEvents.state(run, scene.request)
	state.index = 9
	run.inventory_state.events[RunRandomEvents.key(scene.request)] = state
	scene._refresh()
	await _frames(3)
	await _click_control(scene._content.get_child(0))
	var picker: CanvasLayer = scene._deck_picker
	_check("选择合成后立即打开完整卡组弹窗", is_instance_valid(picker) and picker._grid.get_child_count() == run.deck_cards.size() and picker._hits.size() == 50)
	if not is_instance_valid(picker): get_tree().quit(1); return
	# 无窗口运行帧率较高，滚动布局需要等待延后的容器排序完成。
	await get_tree().create_timer(0.1).timeout
	_check("牌组可滚动且关闭底层选项交互", picker._scroll.get_v_scroll_bar().max_value > picker._scroll.size.y and scene._content.get_children().all(func(button: Button): return button.disabled))
	var first: String = str(run.deck_cards[0].copy_id)
	var second: String = str(run.deck_cards[1].copy_id)
	var third: String = str(run.deck_cards[2].copy_id)
	var deck_before := JSON.stringify(run.deck_cards)
	var seed_before := JSON.stringify(SeedService.capture_snapshot())
	_check("同名卡按独立副本显示", run.deck_cards[0].card_id == run.deck_cards[1].card_id and first != second and picker._hits.has(first) and picker._hits.has(second))
	var first_view: CardView = picker._grid.get_child(0).get_child(0).get_child(0)
	_check("复用正式卡面、文字与附魔符号", first_view._compact and not first_view.get_node("%附魔符号").text.is_empty())
	var last: String = str(run.deck_cards.back().copy_id)
	picker._scroll.scroll_vertical = 100000
	await _frames(3)
	await _click_control(picker._hits[last])
	_check("滚动后可以实际点击牌组最后一张", picker._selected == [last])
	await _click_control(picker._hits[last])
	picker._scroll.scroll_vertical = 0
	await _frames(3)
	await _click_control(picker._hits[first])
	_check("点击卡面选中且不足两张不能确认", picker._selected == [first] and picker._confirm_button.disabled and picker._hits[first].button_pressed)
	await _click_control(picker._hits[first])
	_check("再次点击取消选中", picker._selected.is_empty() and not picker._hits[first].button_pressed)
	await _click_control(picker._hits[first])
	await _click_control(picker._hits[second])
	await _click_control(picker._hits[third])
	_check("最多选择两张，拒绝第三张且允许同名副本", picker._selected == [first, second] and not picker._confirm_button.disabled and not picker._hits[third].button_pressed)
	_check("查看与勾选不消耗卡牌或玩法随机数", JSON.stringify(run.deck_cards) == deck_before and JSON.stringify(SeedService.capture_snapshot()) == seed_before)
	await _capture_event("01-deck-selection.png")
	await _click_control(picker._root.find_child("CloseDeckPicker", true, false))
	_check("关闭弹窗不消耗素材且恢复事件选项", scene._deck_picker == null and JSON.stringify(run.deck_cards) == deck_before and scene._content.get_children().all(func(button: Button): return not button.disabled))
	await _click_control(scene._content.get_child(0))
	picker = scene._deck_picker
	_check("重新打开保留本次勾选", picker._selected == [first, second])
	var old_error: Error = SaveGateway._load_error
	SaveGateway._load_error = ERR_CANT_OPEN
	await _click_control(picker._confirm_button)
	_check("保存失败保留弹窗与勾选，不消耗素材", scene._deck_picker == picker and picker._selected == [first, second] and not picker._confirm_button.disabled and picker._status.text.contains("选择未提交") and RunRandomEvents.state(run, scene.request).stage == "inputs" and JSON.stringify(run.deck_cards) == deck_before)
	SaveGateway._load_error = old_error
	await _click_control(picker._confirm_button)
	state = RunRandomEvents.state(run, scene.request)
	_check("确认后进入原有合成奖励流程", scene._deck_picker == null and state.stage == "reward" and state.inputs == [first, second] and state.offers.size() == 3 and JSON.stringify(run.deck_cards) == deck_before)
	_check("保存并重新进入事件保留已选素材和固定奖励", SaveGateway.save_current() == OK and SaveGateway.load_current() == OK)
	var request: Dictionary = scene.request.duplicate(true)
	get_tree().change_scene_to_file(RandomEventCatalog.SCENE)
	await _frames(6)
	scene = get_tree().current_scene
	run = SaveGateway.current_run()
	var restored := RunRandomEvents.state(run, scene.request)
	_check("冷恢复不重复打开素材选择、不重新抽奖励", scene._deck_picker == null and restored.inputs == state.inputs and restored.offers == state.offers)
	await _click_control(scene._content.get_child(0))
	await _click_control(scene._content.get_child(scene._content.get_child_count() - 1))
	_check("选定奖励只消耗选中的两张副本并增加一张牌", RunRandomEvents.state(run, request).stage == "result" and run.deck_cards.size() == 49 and not run.deck_cards.any(func(card: Dictionary): return str(card.copy_id) in [first, second]) and run.deck_cards.any(func(card: Dictionary): return str(card.copy_id) == third))
	print("素材合成全牌组选牌：全部通过" if failures == 0 else "素材合成全牌组选牌：失败%d项" % failures)
	get_tree().quit(failures)

func _click_control(control: Control) -> void:
	var point := control.get_global_rect().get_center()
	var motion := InputEventMouseMotion.new()
	motion.position = point
	get_viewport().push_input(motion, true)
	var click := InputEventMouseButton.new()
	click.position = point
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	get_viewport().push_input(click, true)
	await _frames(2)
	click = click.duplicate()
	click.pressed = false
	get_viewport().push_input(click, true)
	await _frames(4)
