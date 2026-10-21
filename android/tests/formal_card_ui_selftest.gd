extends Node

var failures := 0
var fixture_root := ""


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	fixture_root = "res://.godot/formal-ui-%d" % Time.get_ticks_usec()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(fixture_root))
	SeedService.begin_run("formal-card-ui")
	get_tree().root.set_meta("formal_card_test_group", 4)
	var page: BattleTestScene = load("res://ui/battle/formal_card_test_scene.tscn").instantiate()
	page.relic_board_path = fixture_root.path_join("empty-board.json")
	page.resolution_delay = 0.001
	page.enemy_turn_delay = 0.001
	add_child(page)
	await _frames(6)
	_check("分组测试入口实际装配31–40", page._battle.hand.size() == 10 and page.has_node("DeckGroup"))
	var b := page._battle
	var discard_id := _id(b.hand, "31")
	_check("布置弃牌堆", b.discard_from_hand(discard_id) == OK)
	page._queue_refresh()
	await _frames(3)
	await _hand_click(page, _id(b.hand, "37"))
	await _hand_click(page, _id(b.hand, "32"))
	_check("真实点击正式卡进入出牌区", page._selected_ids.size() == 2 and page.play_cards.get_child_count() == 2)
	await _click(page.play_button)
	await _frames(8)
	_check("37暂停原事件队列并打开弃牌堆选择", b.pending_pile_count() == 1 and page.pile_modal.visible and page.pile_grid.get_child_count() == 1)
	page._close_pile_modal()
	_check("不能误关待选牌弹窗", page.pile_modal.visible)
	await _capture("formal-pile-choice.png")
	var pile_button: Button = page.pile_grid.get_child(0).get_child(1)
	await _click(pile_button)
	await _frames(16)
	_check("选弃牌插入后继续到32交互弃手牌", b.has_pending_discard_choice() and b.pending_discard_count() == 1 and not page.pile_modal.visible)
	await _capture("formal-discard-choice.png")
	await _hand_click(page, str(b.hand[0].instance_id))
	await _frames(20)
	await preload("res://tests/support/presentation_test_helper.gd").battle_settled(page)
	_check("完成手牌弃置后继续下一回合", b.phase == BattleStateMachine.Phase.PLAYER_ACTION and not page._busy)
	_check("插入的31实际执行（随后可能被下回合抽回）", b.rules.queue.history.any(func(e: Dictionary): return e.type == "card.effect_requested" and str(e.payload.card.instance_id) == discard_id))
	_check("结算期间插入牌的UI快照已被消费", page._resolution_events.is_empty())
	page.queue_free()
	await _frames(3)
	get_tree().root.set_meta("formal_card_test_group", 2)
	page = load("res://ui/battle/formal_card_test_scene.tscn").instantiate()
	page.relic_board_path = fixture_root.path_join("empty-board.json")
	page.resolution_delay = 0.001
	page.enemy_turn_delay = 0.001
	add_child(page)
	await _frames(4)
	b = page._battle
	await _hand_click(page, _id(b.hand, "20"))
	await _hand_click(page, _id(b.hand, "19"))
	await _click(page.play_button)
	await _frames(20)
	await preload("res://tests/support/presentation_test_helper.gd").battle_settled(page)
	_check("20锁住19的原牌位，UI展示空位和锁牌", b.play_zone.size() == 2 and bool(b.play_zone[0].get("slot_empty", false)) and str(b.play_zone[1].card_id) == "19" and page.play_cards.get_child_count() == 2)
	_check("没有新手牌也可继续结算锁牌", not page.play_button.disabled)
	await _capture("formal-locked-card.png")
	await _click(page.play_button)
	await _frames(20)
	await preload("res://tests/support/presentation_test_helper.gd").battle_settled(page)
	_check("锁牌自动参与完毕后正常入弃", b.play_zone.is_empty() and b.turn_number == 3 and not page._busy)
	print("正式卡牌界面自测：全部通过" if failures == 0 else "正式卡牌界面自测：%d 项失败" % failures)
	get_tree().quit(0 if failures == 0 else 1)


func _id(cards: Array[Dictionary], card_id: String) -> String:
	for card: Dictionary in cards:
		if str(card.card_id) == card_id:
			return str(card.instance_id)
	return ""


func _hand_click(page: BattleTestScene, id: String) -> void:
	for slot: Control in page.hand_cards.get_children():
		if str(slot.get_meta("instance_id")) == id:
			await _click(slot.get_child(1))
			return
	_check("找到了手牌 " + id, false)


func _click(button: Button) -> void:
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.position = button.get_global_rect().get_center()
	press.pressed = true
	get_viewport().push_input(press, true)
	await get_tree().process_frame
	press = press.duplicate()
	press.pressed = false
	get_viewport().push_input(press, true)
	await _frames(4)


func _frames(count: int) -> void:
	for i in count:
		await get_tree().process_frame
	# 抽牌/指针表现按真实时间播放；固定帧数不代表已经可以点击。
	for child: Node in get_children():
		if child is BattleTestScene:
			var deadline := Time.get_ticks_msec() + 15000
			while is_instance_valid(child) and child._animating and Time.get_ticks_msec() < deadline:
				await get_tree().create_timer(0.01).timeout


func _capture(name: String) -> void:
	if DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png(fixture_root.path_join(name))


func _check(label: String, passed: bool) -> void:
	print(("PASS " if passed else "FAIL ") + label)
	if not passed:
		failures += 1
