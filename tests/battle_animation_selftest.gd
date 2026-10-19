extends Node

var failures := 0
var fixture_root := ""


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	get_window().size = Vector2i(1920, 1080)
	fixture_root = "res://.godot/battle-animation-%d" % Time.get_ticks_usec()
	DirAccess.make_dir_recursive_absolute(fixture_root)
	SaveGateway.profile_path = fixture_root.path_join("profile.json")
	SaveGateway.slot_paths.assign([fixture_root.path_join("1.json"), fixture_root.path_join("2.json"), fixture_root.path_join("3.json")])
	SaveGateway._active_slot = 1
	_check("独立测试存档", SaveGateway._load_slot(1) == OK)
	var scene: BattleTestScene = load("res://ui/battle/battle_test_scene.tscn").instantiate()
	scene.relic_board_path = fixture_root.path_join("empty-board.json")
	scene.deck_card_ids.assign(["test_damage_enemy", "test_damage_enemy", "test_damage_enemy", "test_block", "test_heal"])
	scene.initial_draw_count = 5
	scene.enemy_starting_health = 31
	scene.resolution_delay = 0.35
	add_child(scene)
	await _frames(5)
	await _check_health(scene)
	await _check_transfers(scene)
	await _check_normal_turn(scene)
	await _check_lethal_sequence(scene)
	scene.queue_free()
	await _frames(3)
	print("血条与飞牌动画：全部通过" if failures == 0 else "血条与飞牌动画：失败%d项" % failures)
	get_tree().quit(failures)


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
	_check("选择立即生成独立飞牌，规则手牌不被表现层改写", scene._card_transfers.has(id) and scene._battle.hand.size() == hand_before)
	await _frames(5)
	var ghost: Control = scene._card_transfers[id].ghost
	ghost._flight.pause()
	ghost._flight.custom_step(0.07)
	_check("起飞缩小到过渡比例", ghost.scale.is_equal_approx(Vector2.ONE * scene.CARD_TRANSFER.TRAVEL_SCALE))
	var origin := ghost.position
	ghost._flight.custom_step(0.09)
	_check("缩小状态平滑移动，目标卡面隐藏避免重影", ghost.position.distance_to(origin) > 10.0 and is_zero_approx(scene._transfer_source(id, true).modulate.a))
	# 飞行中插入另一张牌并触发重建，原目标不能重现或失效。
	var other := str(scene._battle.hand[1].instance_id)
	scene._insert_selected_card(other, 0)
	await _frames(4)
	_check("重建与插牌后目标仍隐藏", is_zero_approx(scene._transfer_source(id, true).modulate.a))
	ghost._flight.custom_step(0.10)
	ghost._flight.custom_step(0.04)
	_check("落位快速放大到目标尺寸途中", ghost.scale.x > scene.CARD_TRANSFER.TRAVEL_SCALE and ghost.scale.x < scene.PLAY_CARD_SCALE)
	var center := ghost.position + ghost.pivot_offset
	_check("目标跟随插牌与滚动位置", center.distance_to(scene._card_transfer_target(id).center) < 1.0)
	await _capture("card-landing.png")
	ghost._flight.custom_step(0.2)
	await _frames(1)
	_check("落位后清理飞牌并恢复真实卡面", not scene._card_transfers.has(id) and is_equal_approx(scene._transfer_source(id, true).modulate.a, 1.0))
	scene._on_cancel_pressed()
	await _frames(4)
	_check("快速取消清理所有飞牌并还原手牌", scene._card_transfers.is_empty() and scene.hand_cards.get_child_count() == hand_before)
	# 逐张选择两张弃牌，第一张无需等到凑够数量才开始飞行。
	scene._busy = true
	scene._pending_discard_count = 2
	id = str(scene._battle.hand[0].instance_id)
	scene._select_card_to_discard(id)
	await _frames(5)
	_check("多张弃牌第一张立即播放飞行动画", scene._card_transfers.has(id) and scene._discard_selection_ids.size() == 1)
	ghost = scene._card_transfers[id].ghost
	ghost._flight.pause()
	ghost._flight.custom_step(0.25)
	ghost._flight.custom_step(0.045)
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
	var previous := float(scene.enemy_hp_fill.get("ratio"))
	var monotonic := true
	var snapshot_matches := true
	var saw_intermediate := false
	var deadline := Time.get_ticks_msec() + 10000
	scene._on_play_pressed()
	_check("逻辑已致死但血条仍保持初始表现血量", not scene._battle.active and is_equal_approx(float(scene.enemy_hp_fill.get("ratio")), previous))
	while scene._busy and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
		var current := float(scene.enemy_hp_fill.get("ratio"))
		monotonic = monotonic and current <= previous + 0.00001
		previous = current
		var presented := int(scene._presented_enemy.health)
		saw_intermediate = saw_intermediate or (presented > 0 and presented < 23)
		snapshot_matches = snapshot_matches and is_equal_approx(float(scene.enemy_hp_fill.get_meta("ratio")), float(scene._presented_enemy.health) / float(scene._presented_enemy.max_health))
	await get_tree().create_timer(0.35).timeout
	_check("致死连续伤害播放不先归零再恢复", monotonic and snapshot_matches and saw_intermediate and not scene._busy and is_zero_approx(float(scene.enemy_hp_fill.get("ratio"))))
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
