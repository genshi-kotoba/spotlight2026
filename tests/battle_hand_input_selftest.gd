extends Node

const FIXTURE_PATH := "res://.godot/hand_input_fixture.json"
var failures := 0


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	var catalog := RelicCatalog.load_definitions()
	var board := RelicBoard.new()
	# 棋盘固定 4x5 共 20 格，`restore` 要求长度严格相等；前 12 格是连锁布局，其余留空。
	board.cells.assign(["turn_strength", "on_card_gained", "gain_block", "deal_damage",
		"on_card_gained", "deal_damage", "on_enemy_damaged", "deal_damage",
		"", "gain_block", "gain_block", "turn_strength",
		"", "", "", "", "", "", "", ""])
	# 布局占用了 3/7/11 号格，它们不在默认开放集里；整盘按测试约定开放 12 格，
	# 否则棋盘校验会以「内容落在封锁格」拒绝恢复。
	board.unlocked_cells.assign(range(12))
	board.save_to_file(FIXTURE_PATH)
	var packed := load("res://ui/battle/battle_test_scene.tscn") as PackedScene
	var ended := packed.instantiate() as BattleTestScene
	ended.relic_board_path = FIXTURE_PATH
	# 固定用测试牌组，不跟随 data/config/main_menu_new_run.json 的正式初始卡组，
	# 断言才对卡号、手牌张数与弃牌交互卡可控。
	ended.deck_card_ids = BattleTestScene.TEST_DECK_CARD_IDS.duplicate()
	ended.enemy_starting_health = 1
	add_child(ended)
	await get_tree().process_frame
	await get_tree().process_frame
	_check("自然首抽不触发残片，1血敌人仍存活", ended._battle.active and int(ended._battle.enemies[0].health) == 1 and ended._battle.hand.size() == _hand_limit(ended))
	# 手牌已到 10 张上限，效果抽牌没有入手空间；先弃一张留出空位，与跑图侧同一做法。
	ended._battle.discard_from_hand(str(ended._battle.hand[0].instance_id))
	await get_tree().process_frame
	var context := BattleEffectContext.new(ended._battle, str(ended._battle.enemies[0].enemy_id), ended._resolver.buff_catalog)
	context.draw(1)
	await get_tree().process_frame
	await preload("res://tests/support/presentation_test_helper.gd").battle_settled(ended)
	_check("效果抽牌仍可触发残片击败敌人", not ended._battle.active and int(ended._battle.enemies[0].health) == 0)
	_check("效果胜利明确显示终局与重开入口", ended.hint_label.text.contains("战斗胜利") and not ended._restart_button.disabled and ended.play_button.disabled)
	ended.free()

	var scene := packed.instantiate() as BattleTestScene
	scene.relic_board_path = FIXTURE_PATH
	scene.deck_card_ids = BattleTestScene.TEST_DECK_CARD_IDS.duplicate()
	add_child(scene)
	await get_tree().process_frame
	await get_tree().process_frame
	_check("同样构筑可正常进入编排", scene._battle.active and scene._battle.hand.size() == _hand_limit(scene))
	await preload("res://tests/support/presentation_test_helper.gd").battle_settled(scene)

	for index: int in [0, 3, 6]:
		var slot := scene.hand_cards.get_child(index) as Control
		var button := slot.get_child(1) as Button
		var before := slot.get_global_transform() * slot.pivot_offset
		var point := button.get_global_rect().get_center()
		var motion := InputEventMouseMotion.new()
		motion.position = point
		get_viewport().push_input(motion, true)
		await get_tree().create_timer(0.6).timeout
		var bottom := slot.get_global_transform() * slot.pivot_offset
		var view := slot.get_child(0) as CardView
		_check("扇形悬停放大保持底边中点固定 %d" % index, absf(bottom.y - before.y) < 1.0 and view.scale.is_equal_approx(Vector2.ONE * scene.HAND_CARD_SCALE * scene.hand_hover_multiplier))
		await _click(point)
		_check("真实鼠标点击手牌 %d 加入出牌区" % index, scene._selected_ids.size() == 1 and scene.play_cards.get_child_count() == 1)
		if not scene._selected_ids.is_empty():
			var play_view := scene.play_cards.get_child(0).get_child(0).get_child(0) as CardView
			_check("出牌区卡面保持手牌的一半", play_view.scale.is_equal_approx(Vector2.ONE * scene.PLAY_CARD_SCALE))
		scene.cancel_button.pressed.emit()
		await get_tree().process_frame
		await get_tree().process_frame
		_check("取消后回到手牌", scene._selected_ids.is_empty() and scene.hand_cards.get_child_count() == _hand_limit(scene))

	# 真实 UI 中连续两次弃牌：第一轮提交不能擦掉同步产生的第二轮请求。
	var discard_data: CardData = scene._resolver.card_catalog["test_discard_choice"].duplicate(true)
	var choice := CardEffectDiscardChoice.new()
	choice.count = 1
	var heal := CardEffectHeal.new()
	heal.amount = 5
	discard_data.effects.assign([choice, choice, heal])
	scene._resolver.card_catalog["test_discard_choice"] = discard_data
	var sequence_card := ""
	for card: Dictionary in scene._battle.hand:
		if card.card_id == "test_discard_choice":
			sequence_card = String(card.instance_id)
			break
	_check("测试手牌包含交互弃牌卡", not sequence_card.is_empty())
	scene._on_hand_card_pressed(sequence_card)
	scene._on_play_pressed()
	await _await_discard_prompt(scene)
	_check("第一轮 UI 弃牌请求存在", scene._pending_discard_count == 1)
	scene._on_hand_card_pressed(String(scene._battle.hand[0].instance_id))
	await _await_discard_prompt(scene)
	_check("第一轮提交后保留第二轮 UI 弃牌请求", scene._pending_discard_count == 1 and scene._battle.has_pending_discard_choice())
	scene._on_hand_card_pressed(String(scene._battle.hand[0].instance_id))
	await preload("res://tests/support/presentation_test_helper.gd").battle_settled(scene)
	_check("第二轮提交后 UI 恢复可操作且队列不再等待", scene._pending_discard_count == 0 and not scene._busy and not scene._battle.rules.queue.paused)
	scene.free()
	DirAccess.remove_absolute(FIXTURE_PATH)
	print("手牌输入全部通过" if failures == 0 else "手牌输入失败 %d 项" % failures)
	get_tree().quit(failures)


## 弃牌提示只在「结算表现收干净 + 请求已挂起」时才算真的可点：
## 表现未收时点手牌会被 `_animating` 挡掉，上一轮弃牌的飞牌还在飞时点下一张也会丢输入。
func _await_discard_prompt(battle_scene: BattleTestScene) -> void:
	var deadline := Time.get_ticks_msec() + 15000
	while is_instance_valid(battle_scene) and not _discard_ready(battle_scene):
		if Time.get_ticks_msec() >= deadline:
			push_error("测试等待弃牌提示出现超时")
			return
		await battle_scene.get_tree().create_timer(0.01).timeout


func _discard_ready(battle_scene: BattleTestScene) -> bool:
	return battle_scene._pending_discard_count > 0 and not battle_scene._animating \
		and battle_scene._card_transfers.is_empty() and battle_scene._resolution_events.is_empty()


func _hand_limit(battle_scene: BattleTestScene) -> int:
	# 首抽张数来自 rules，手牌上限另有 10 张封顶，实际入手取两者较小值。
	return mini(battle_scene.initial_draw_count, int(battle_scene._battle.player.get("hand_limit", 10)))


func _click(point: Vector2) -> void:
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.position = point
	press.pressed = true
	get_viewport().push_input(press, true)
	await get_tree().process_frame
	press = press.duplicate()
	press.pressed = false
	get_viewport().push_input(press, true)
	await get_tree().process_frame
	await get_tree().process_frame


func _check(label: String, passed: bool) -> void:
	if not passed:
		failures += 1
	print("%s %s" % ["通过" if passed else "失败", label])
