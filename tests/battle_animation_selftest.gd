extends Node

var failures := 0
var fixture_root := ""


## 观察真实 HandDeal 调用；不替换动画或向生产添加测试接口。
class ObservedBattleScene extends "res://ui/battle/battle_test_scene.gd":
	var deal_records: Array[Dictionary] = []
	var deal_tweens: Array[Tween] = []
	var pause_new_deals := false

	func _play_deal_animation(slots: Array[Control]) -> void:
		var drawn: Array[Dictionary] = []
		for slot: Control in slots:
			var id := str(slot.get_meta("instance_id"))
			if not _hand_ids_previous.has(id):
				drawn.append({"instance_id": id, "slot_ref": weakref(slot),
					"target_position": slot.position, "target_rotation": slot.rotation})
		var previous_tweens := get_tree().get_processed_tweens()
		super._play_deal_animation(slots)
		for tween: Tween in get_tree().get_processed_tweens():
			if tween not in previous_tweens:
				deal_tweens.append(tween)
				if pause_new_deals: tween.pause()
		var pile := get_node("DrawPile") as Control
		var origin := hand_cards.get_global_transform_with_canvas().affine_inverse() * (pile.get_global_transform_with_canvas() * (pile.size * 0.5))
		for index in drawn.size():
			var record: Dictionary = drawn[index]
			var slot := (record.slot_ref as WeakRef).get_ref() as Control
			record.merge({"start_position": slot.position, "start_rotation": slot.rotation,
				"start_scale": slot.scale, "start_alpha": slot.modulate.a,
				"pile_center": origin, "batch_index": index})
			deal_records.append(record)


func _new_observed_scene() -> ObservedBattleScene:
	var scene: BattleTestScene = load("res://ui/battle/battle_test_scene.tscn").instantiate()
	scene.set_script(ObservedBattleScene)
	return scene as ObservedBattleScene


func _add_draw_fixture(scene: ObservedBattleScene, opening: int, each_turn: int) -> void:
	# 场景 ready 会读取正式规则；只为本夹具短暂设定精确抽牌数，随后恢复原字典。
	var previous := EncounterFlow.test_rules
	EncounterFlow.test_rules = previous.duplicate(true)
	EncounterFlow.test_rules["initial_draw_count"] = opening
	EncounterFlow.test_rules["per_turn_draw_count"] = each_turn
	scene.initial_draw_count = opening
	scene.per_turn_draw_count = each_turn
	scene.test_enemy_count = 1
	add_child(scene)
	EncounterFlow.test_rules = previous
	_check("夹具已恢复正式抽牌规则", EncounterFlow.test_rules == previous)


func _step_deals(scene: ObservedBattleScene, seconds: float) -> void:
	for tween: Tween in scene.deal_tweens:
		if tween.is_valid(): tween.custom_step(seconds)


func _record_slot(record: Dictionary) -> Control:
	return (record.slot_ref as WeakRef).get_ref() as Control


func _wait_deals(scene: ObservedBattleScene) -> void:
	var deadline := Time.get_ticks_msec() + 5000
	while Time.get_ticks_msec() < deadline:
		var running := false
		for tween: Tween in scene.deal_tweens:
			if tween.is_valid() and tween.is_running(): running = true
		if not running: return
		await get_tree().process_frame
	_check("真实发牌动画按时完成", false)


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	get_window().size = Vector2i(1920, 1080)
	fixture_root = "res://.godot/battle-animation-%d" % Time.get_ticks_usec()
	DirAccess.make_dir_recursive_absolute(fixture_root)
	SaveGateway.save_path = fixture_root.path_join("game.json")
	_check("独立测试存档", SaveGateway.load_current() == OK)
	var scene := _new_observed_scene()
	scene.relic_board_path = fixture_root.path_join("empty-board.json")
	scene.deck_card_ids.assign(["test_damage_enemy", "test_damage_enemy", "test_damage_enemy", "test_block", "test_heal"])
	scene.pause_new_deals = true
	scene.enemy_starting_health = 31
	scene.resolution_delay = 0.35
	_add_draw_fixture(scene, 5, 2)
	await _check_opening_draw(scene)
	await _check_health(scene)
	await _check_transfers(scene)
	await _check_normal_turn(scene)
	await _check_lethal_sequence(scene)
	scene.queue_free()
	await _frames(3)
	await _check_effect_and_turn_draw()
	print("血条与飞牌动画：全部通过" if failures == 0 else "血条与飞牌动画：失败%d项" % failures)
	get_tree().quit(failures)


func _check_opening_draw(scene: ObservedBattleScene) -> void:
	var deadline := Time.get_ticks_msec() + 5000
	while scene.deal_records.size() < 5 and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	_check("开局业务准确抽5张，真实发牌为5张分别建Tween", scene._battle.hand.size() == 5 and scene.deal_records.size() == 5 and scene.deal_tweens.size() == 5)
	if scene.deal_records.size() != 5: return
	var seed_before := JSON.stringify(SeedService.capture_snapshot())
	var starts_correct := true
	for record: Dictionary in scene.deal_records:
		var slot := _record_slot(record)
		if not is_instance_valid(slot):
			starts_correct = false
			continue
		var center: Vector2 = record.start_position + Vector2(slot.size.x * 0.5, slot.size.y * (1.0 - scene.HAND_DEAL_ANIM.START_SCALE * 0.5))
		starts_correct = starts_correct and center.distance_to(record.pile_center) < 1.0 and record.start_scale == Vector2.ONE * scene.HAND_DEAL_ANIM.START_SCALE and is_zero_approx(float(record.start_alpha)) and is_equal_approx(float(record.start_rotation), scene.HAND_DEAL_ANIM.START_ROTATION)
	_check("真实发牌从抽牌堆中心以45%尺寸、偏角和透明状态起飞", starts_correct)
	var first := _record_slot(scene.deal_records[0])
	var last := _record_slot(scene.deal_records[4])
	if not is_instance_valid(first) or not is_instance_valid(last):
		_check("发牌期间真实槽位保持存活", false)
		return
	_step_deals(scene, 0.15)
	_check("首张连续移动而末张仍等待错峰出发", first.position.distance_to(scene.deal_records[0].target_position) > 0.1 and first.position.distance_to(scene.deal_records[0].start_position) > 0.1 and first.modulate.a > 0.0 and first.modulate.a < 1.0 and is_zero_approx(last.modulate.a))
	_step_deals(scene, 0.25)
	_check("首张0.4秒精确落位，末张仍在飞入", first.position.distance_to(scene.deal_records[0].target_position) < 0.1 and first.scale.is_equal_approx(Vector2.ONE) and is_equal_approx(first.rotation, float(scene.deal_records[0].target_rotation)) and last.modulate.a > 0.0 and last.modulate.a < 1.0)
	await _capture("card-draw-landing.png")
	_step_deals(scene, 0.25)
	var landed := true
	for record: Dictionary in scene.deal_records:
		var slot := _record_slot(record)
		landed = landed and is_instance_valid(slot) and slot.position.distance_to(record.target_position) < 0.1 and slot.scale.is_equal_approx(Vector2.ONE) and is_equal_approx(slot.rotation, float(record.target_rotation)) and is_equal_approx(slot.modulate.a, 1.0)
	_check("错峰结束后所有卡面与实际布局落点一致", landed)
	scene.pause_new_deals = false
	var recorded := scene.deal_records.size()
	scene._refresh_zones()
	_check("同一手牌刷新不重复发牌，落位后允许操作", scene.deal_records.size() == recorded and scene.hand_cards.get_child_count() == 5 and scene._card_transfers.is_empty() and scene._can_click_hand())
	_check("抽牌表现与刷新不额外消耗随机流", JSON.stringify(SeedService.capture_snapshot()) == seed_before)
	await _wait_presentation(scene)

func _wait_presentation(scene: BattleTestScene) -> void:
	var deadline := Time.get_ticks_msec() + 15000
	while scene._presentation_pending() and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	_check("表现队列可正常收尾", not scene._presentation_pending())
	await _frames(3)


func _check_effect_and_turn_draw() -> void:
	var scene := _new_observed_scene()
	scene.relic_board_path = fixture_root.path_join("empty-board.json")
	for index in 12: scene.deck_card_ids.append("test_draw")
	scene.resolution_delay = 0.05
	scene.enemy_turn_delay = 0.05
	_add_draw_fixture(scene, 2, 1)
	await _wait_presentation(scene)
	await _wait_deals(scene)
	_check("效果抽牌夹具首抽准确为2张", scene._battle.hand.size() == 2 and scene.deal_records.size() == 2)
	scene.deal_records.clear()
	scene._on_hand_card_pressed(str(scene._battle.hand[0].instance_id))
	await get_tree().create_timer(0.45).timeout
	scene._on_play_pressed()
	await _wait_presentation(scene)
	await _wait_deals(scene)
	var drawn_ids := {}
	for record: Dictionary in scene.deal_records: drawn_ids[record.instance_id] = true
	_check("效果抽2张和次回合抽1张均走真实发牌且不重播", scene.deal_records.size() == 3 and drawn_ids.size() == 3 and scene._battle.turn_number == 2 and scene._battle.hand.size() == 4 and not scene._busy)
	# 独立补抽不在出牌/回合表现段中；显式请求正常刷新入口来显示这次真实规则结果。
	scene._battle.discard_pile.append_array(scene._battle.draw_pile)
	scene._battle.draw_pile.clear()
	var count := scene._battle.hand.size()
	scene.deal_records.clear()
	_check("洗牌后继续抽牌请求成功", scene._battle.draw_cards(20) == OK)
	scene._refresh_zones()
	await _wait_deals(scene)
	drawn_ids.clear()
	for record: Dictionary in scene.deal_records: drawn_ids[record.instance_id] = true
	_check("洗回抽牌遵守10张上限，仅为实际入手牌发牌", scene._battle.hand.size() == 10 and scene.hand_cards.get_child_count() == 10 and scene.deal_records.size() == 10 - count and drawn_ids.size() == 10 - count)
	# 再做一次真实弃牌/补抽，在新发牌Tween运行期间退出，验证绑定节点的清理。
	var last: Dictionary = scene._battle.hand.back().duplicate(true)
	_check("退出夹具真实弃置一张手牌", scene._battle.discard_from_hand(str(last.instance_id), &"animation_exit") == OK)
	await _wait_presentation(scene)
	var before := scene.deal_tweens.size()
	_check("退出夹具真实补抽一张牌", scene._battle.draw_cards(1) == OK)
	scene._refresh_zones()
	var active: Array[Tween] = []
	for tween: Tween in scene.deal_tweens.slice(before):
		if tween.is_valid(): active.append(tween)
	_check("退出前真实发牌动画已经启动", active.size() == 1)
	scene.queue_free()
	await _frames(4)
	var cleaned := not is_instance_valid(scene)
	for tween: Tween in active: cleaned = cleaned and not tween.is_valid()
	_check("飞行期间退出战斗清理真实槽位和绑定Tween", cleaned)

func _check_health(scene: BattleTestScene) -> void:
	var data := scene._battle.player.duplicate(true)
	var fill := scene.player_hp_fill
	data.health = 20
	var before := float(fill.get("ratio"))
	scene._render_health(fill, scene.player_hp_block, scene.player_hp_num, data, scene.PLAYER_BAR_LEFT, scene.PLAYER_BAR_WIDTH, &"player")
	var tween: Tween = fill.get_meta("tween")
	tween.pause()
	scene._render_health(fill, scene.player_hp_block, scene.player_hp_num, data, scene.PLAYER_BAR_LEFT, scene.PLAYER_BAR_WIDTH, &"player")
	_check("Tween尚未启动时同目标刷新不瞬移", is_equal_approx(float(fill.get("ratio")), before) and fill.get_meta("tween") == tween)
	tween.custom_step(0.15)
	var middle := float(fill.get("ratio"))
	_check("0.15秒仍在连续变化途中", middle < before and middle > 0.2)
	data.health = 10
	scene._render_health(fill, scene.player_hp_block, scene.player_hp_num, data, scene.PLAYER_BAR_LEFT, scene.PLAYER_BAR_WIDTH, &"player")
	_check("连续扣血从当前显示值接续", is_equal_approx(float(fill.get("ratio")), middle) and not tween.is_valid())
	tween = fill.get_meta("tween")
	tween.pause()
	tween.custom_step(0.299)
	_check("过渡窗口固定0.3秒", tween.is_valid() and is_equal_approx(scene.HEALTH_TRANSITION_TIME, 0.3))
	tween.custom_step(0.002)
	_check("0.3秒后精确落到新血量", is_equal_approx(float(fill.get("ratio")), 0.1))
	data.health = 80
	scene._render_health(fill, scene.player_hp_block, scene.player_hp_num, data, scene.PLAYER_BAR_LEFT, scene.PLAYER_BAR_WIDTH, &"player")
	tween = fill.get_meta("tween")
	tween.pause()
	tween.custom_step(0.15)
	_check("治疗同样平滑增加而非重置", float(fill.get("ratio")) > 0.1 and float(fill.get("ratio")) < 0.8)
	tween.custom_step(0.16)
	scene._refresh_combat_status()
	await get_tree().create_timer(0.35).timeout


func _check_transfers(scene: BattleTestScene) -> void:
	var id := str(scene._battle.hand[0].instance_id)
	var seed_before := JSON.stringify(SeedService.capture_snapshot())
	var hand_before := scene._battle.hand.size()
	scene._on_hand_card_pressed(id)
	await _frames(5)
	_check("点手牌直接编排且不提前改变业务手牌", not scene._card_transfers.has(id) and scene._selected_ids.has(id) and scene.play_cards.get_child_count() >= 1 and scene.hand_cards.get_child_count() == hand_before - 1 and scene._battle.hand.size() == hand_before)
	scene._on_cancel_pressed()
	await _frames(4)
	_check("取消后手牌还原且无残留飞牌", scene._card_transfers.is_empty() and scene._selected_ids.is_empty() and scene.hand_cards.get_child_count() == hand_before)
	# 逐张选择两张弃牌，第一张无需等到凑够数量才开始飞行。
	scene._busy = true
	scene._pending_discard_count = 2
	id = str(scene._battle.hand[0].instance_id)
	scene._select_card_to_discard(id)
	await _frames(5)
	_check("多张弃牌第一张立即播放飞行动画", scene._card_transfers.has(id) and scene._discard_selection_ids.size() == 1)
	var ghost: Control = scene._card_transfers[id].ghost
	ghost._flight.pause()
	ghost._flight.custom_step(0.05)
	ghost._flight.custom_step(0.10)
	_check("弃牌到达牌堆后缩小并淡出", ghost.scale.x < scene.CARD_TRANSFER.TRAVEL_SCALE and ghost.modulate.a > 0.0 and ghost.modulate.a < 1.0)
	await _capture("card-discard.png")
	ghost._flight.custom_step(0.2)
	await _frames(2)
	_check("弃牌消失后没有残余节点", not scene._card_transfers.has(id) and not is_instance_valid(ghost))
	scene._pending_discard_count = 0
	scene._discard_selection_ids.clear()
	scene._busy = false
	scene._queue_refresh()
	await _frames(3)
	_check("动画不消耗玩法随机数", JSON.stringify(SeedService.capture_snapshot()) == seed_before)


func _check_normal_turn(scene: BattleTestScene) -> void:
	var played_id := ""
	for card: Dictionary in scene._battle.hand:
		if str(card.card_id) == "test_damage_enemy":
			played_id = str(card.instance_id)
			scene._on_hand_card_pressed(played_id)
			break
	await get_tree().create_timer(0.45).timeout
	scene._on_play_pressed()
	var saw_departure := false
	var deadline := Time.get_ticks_msec() + 10000
	while scene._busy and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
		if scene._card_transfers.has(played_id):
			var transfer: Dictionary = scene._card_transfers[played_id]
			saw_departure = saw_departure or (str(transfer.destination) == "discard" and bool(transfer.from_play))
	_check("正常回合已结算出牌飞入弃牌堆", saw_departure and not scene._busy and scene._card_transfers.is_empty())
	_check("怪物回合后恢复手牌操作和权威血量", scene._battle.turn_number == 2 and scene._battle.phase == BattleStateMachine.Phase.PLAYER_ACTION and scene.player_hp_num.text == "%d/%d" % [scene._battle.player.health, scene._battle.player.max_health])


func _check_lethal_sequence(scene: BattleTestScene) -> void:
	for card: Dictionary in scene._battle.hand:
		if str(card.card_id) == "test_damage_enemy":
			scene._on_hand_card_pressed(str(card.instance_id))
	await get_tree().create_timer(0.45).timeout
	var previous := float(scene.enemy_rack.slots[0].fill.get("ratio"))
	var monotonic := true
	var snapshot_matches := true
	var saw_intermediate := false
	var deadline := Time.get_ticks_msec() + 10000
	scene._on_play_pressed()
	_check("逻辑已致死但血条仍保持初始表现血量", not scene._battle.active and is_equal_approx(float(scene.enemy_rack.slots[0].fill.get("ratio")), previous))
	while scene._busy and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
		var current := float(scene.enemy_rack.slots[0].fill.get("ratio"))
		monotonic = monotonic and current <= previous + 0.00001
		previous = current
		var presented := int(scene._presented_enemies[0].health)
		saw_intermediate = saw_intermediate or (presented > 0 and presented < 23)
		snapshot_matches = snapshot_matches and is_equal_approx(float(scene.enemy_rack.slots[0].fill.get_meta("ratio")), float(scene._presented_enemies[0].health) / float(scene._presented_enemies[0].max_health))
	await get_tree().create_timer(0.35).timeout
	_check("致死连续伤害播放不先归零再恢复", monotonic and snapshot_matches and saw_intermediate and not scene._busy and is_zero_approx(float(scene.enemy_rack.slots[0].fill.get("ratio"))))
	_check("结算后出牌入弃动画收尾，不残留飞牌", scene._card_transfers.is_empty() and scene._resolved_discards.is_empty())
	await _capture("lethal-finished.png")


func _frames(count: int) -> void:
	for index in count:
		await get_tree().process_frame


func _capture(filename: String) -> void:
	if DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png(fixture_root.path_join(filename))


func _check(label: String, passed: bool) -> void:
	print(("PASS " if passed else "FAIL ") + label)
	if not passed:
		failures += 1
