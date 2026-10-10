extends Node

const FIXTURE_PATH := "res://.godot/hand_input_fixture.json"
var failures := 0


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	var catalog := RelicCatalog.load_definitions()
	var board := RelicBoard.new()
	board.cells.assign(["turn_strength", "on_card_gained", "gain_block", "deal_damage",
		"on_card_gained", "deal_damage", "on_enemy_damaged", "deal_damage",
		"", "gain_block", "gain_block", "turn_strength"])
	board.save_to_file(FIXTURE_PATH)
	var packed := load("res://ui/battle/battle_test_scene.tscn") as PackedScene
	var ended := packed.instantiate() as BattleTestScene
	ended.relic_board_path = FIXTURE_PATH
	ended.enemy_starting_health = 300
	add_child(ended)
	await get_tree().process_frame
	await get_tree().process_frame
	_check("复现首抽残片伤害在出牌前击杀 300 血敌人", not ended._battle.active and int(ended._battle.enemies[0].health) == 0)
	_check("首抽胜利明确显示终局与重开入口", ended.hint_label.text.contains("战斗胜利") and not ended._restart_button.disabled and ended.play_button.disabled)
	ended.free()

	var scene := packed.instantiate() as BattleTestScene
	scene.relic_board_path = FIXTURE_PATH
	add_child(scene)
	await get_tree().process_frame
	await get_tree().process_frame
	_check("提高测试生命后同样构筑可正常进入编排", scene._battle.active and scene._battle.hand.size() == scene.initial_draw_count)

	for index: int in [0, 3, 6]:
		var slot := scene.hand_cards.get_child(index) as Control
		var button := slot.get_child(1) as Button
		var before := slot.get_global_rect()
		var point := button.get_global_rect().get_center()
		var motion := InputEventMouseMotion.new()
		motion.position = point
		get_viewport().push_input(motion, true)
		await get_tree().create_timer(0.6).timeout
		_check("悬停放大保持底边固定 %d" % index, absf(slot.get_global_rect().end.y - before.end.y) < 1.0)
		await _click(point)
		_check("真实鼠标点击手牌 %d 加入出牌区" % index, scene._selected_ids.size() == 1 and scene.play_cards.get_child_count() == 1)
		if not scene._selected_ids.is_empty():
			var play_view := scene.play_cards.get_child(0).get_child(1).get_child(0) as Control
			_check("出牌区卡面保持手牌的一半", play_view.scale.is_equal_approx(Vector2.ONE * scene.PLAY_CARD_SCALE))
		scene.cancel_button.pressed.emit()
		await get_tree().process_frame
		await get_tree().process_frame
		_check("取消后回到手牌", scene._selected_ids.is_empty() and scene.hand_cards.get_child_count() == scene.initial_draw_count)

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
	await get_tree().process_frame
	_check("第一轮 UI 弃牌请求存在", scene._pending_discard_count == 1)
	scene._on_hand_card_pressed(String(scene._battle.hand[0].instance_id))
	await get_tree().process_frame
	await get_tree().process_frame
	_check("第一轮提交后保留第二轮 UI 弃牌请求", scene._pending_discard_count == 1 and scene._battle.has_pending_discard_choice())
	scene._on_hand_card_pressed(String(scene._battle.hand[0].instance_id))
	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().create_timer(scene.resolution_delay + scene.enemy_turn_delay + 0.1).timeout
	_check("第二轮提交后 UI 恢复可操作且队列不再等待", scene._pending_discard_count == 0 and not scene._busy and not scene._battle.rules.queue.paused)
	scene.free()
	DirAccess.remove_absolute(FIXTURE_PATH)
	print("手牌输入全部通过" if failures == 0 else "手牌输入失败 %d 项" % failures)
	get_tree().quit(failures)


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
