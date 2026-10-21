extends Node

const FIXTURE_PATH := "res://.godot/hand_input_fixture.json"
var failures := 0


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	SaveGateway.save_path = "res://.godot/hand-input-%d/game.json" % Time.get_ticks_usec()
	_check("手牌测试使用隔离存档", SaveGateway.load_current() == OK)
	# 此夹具覆盖十张手牌的扇形布局与交互弃牌，不依赖正式首抽默认值。
	EncounterFlow.test_rules = EncounterFlow.test_rules.duplicate(true)
	EncounterFlow.test_rules["initial_draw_count"] = 10
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
	# 规则队列清空时错峰发牌可能仍在播放；真实鼠标夹具应在牌落位后取坐标。
	await get_tree().create_timer(1.0).timeout

	# 手牌张数随构筑变，末位不能写死。
	for index: int in [0, 3, maxi(0, scene.hand_cards.get_child_count() - 1)]:
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

	# 出牌列拖回手牌区：把手牌撑开并在原位留出空位，松手牌立即落到空位。
	var back_id := str((scene.hand_cards.get_child(0) as Control).get_meta("instance_id", ""))
	scene._on_hand_card_pressed(back_id)
	# 先等新入场的出牌行播完 0.16s 的淡入补间，否则它会一直把出牌行的占位透明度改回 1.0。
	await _wait_frames(12)
	var row := scene.play_cards.get_child(0) as Control
	# 出牌列是叠放的，只有顶部 PLAY_STEP 高的一条真的露在外面，落点必须取在这条带子里。
	await _drag_start(Vector2(row.global_position.x + 8.0, row.global_position.y + 8.0))
	_check("出牌列的牌拖拽中保留半透明虚影",
		is_equal_approx((scene.play_cards.get_child(0) as CanvasItem).modulate.a,
			BattleTestScene.PLAY_PLACEHOLDER_ALPHA))
	await _drag_move(scene.hand_scroll.get_global_rect().get_center())
	await _wait_frames(14)
	var opened_slots := scene.hand_cards.get_child_count()
	var opened_xs := _hand_xs(scene)
	_check("结算区的牌拖回手牌同样撑开空位", scene._hand_gap_open)
	_check("撑开空位后出牌列的虚影不会变实心",
		is_equal_approx(_row_alpha(scene.play_cards.get_child(0) as Control),
			BattleTestScene.PLAY_PLACEHOLDER_ALPHA))
	await _drag_release(scene.hand_scroll.get_global_rect().get_center())
	_check("松手立即归位且其余手牌不动",
		scene.hand_cards.get_child_count() == opened_slots + 1 and not scene._hand_gap_open \
			and _same_xs(opened_xs, _hand_xs(scene)))
	_check("拖拽收手后不残留跟随鼠标的残影",
		not scene._drag_active and scene._drag_card_id.is_empty() \
			and (scene._drag_ghost == null or not scene._drag_ghost.visible))
	# 松手那一刻归位的牌正压在指针下，不该当场进入悬停；指针重新进去才恢复判定。
	_check("松手后归位的牌不进入悬停", _hand_hovered_count(scene) == 0)
	await _drag_move(scene.play_scroll.get_global_rect().get_center())
	await _drag_move((scene.hand_cards.get_child(0) as Control).get_global_rect().get_center())
	_check("指针重新进入手牌后悬停恢复", _hand_hovered_count(scene) == 1)

	# 手牌拖出即收扇、不留占位，且收扇有滑动时间；拖回扇面只撑开留空位、不补牌。
	var hand_size := scene.hand_cards.get_child_count()
	var drag_id := str((scene.hand_cards.get_child(0) as Control).get_meta("instance_id", ""))
	var pre_drag_xs := _hand_xs(scene)
	await _drag_start((scene.hand_cards.get_child(0) as Control).get_global_rect().get_center())
	_check("手牌拖出即收扇且不留半透明占位",
		not scene._hand_gap_open and scene.hand_cards.get_child_count() == hand_size - 1)
	# 起手还压在扇面上，这时挪一下不算「拖出去过」，扇面不该当场撑开。
	await _drag_move(scene.hand_scroll.get_global_rect().get_center() + Vector2(40.0, 0.0))
	_check("没出过扇面就不撑开", not scene._hand_gap_open)
	_check("拖动途中手牌不触发悬停", _hand_hovered_count(scene) == 0)
	var collapsing_x := (scene.hand_cards.get_child(4) as Control).position.x
	await _wait_frames(14)
	var collapsed_x := (scene.hand_cards.get_child(4) as Control).position.x
	_check("收扇是滑到位的，不是瞬跳", not is_equal_approx(collapsing_x, collapsed_x))
	# 拖到结算区：牌已出扇面，保持收扇。
	await _drag_move(scene.play_scroll.get_global_rect().get_center())
	_check("拖到结算区仍保持收扇",
		not scene._hand_gap_open and scene.hand_cards.get_child_count() == hand_size - 1)
	_check("拖动途中手牌不触发悬停", _hand_hovered_count(scene) == 0)
	# 拖回扇面：只把扇面撑开、原位留空，牌还在光标上，不补牌也不补抽牌动画。
	await _drag_move(scene.hand_scroll.get_global_rect().get_center())
	_check("拖回扇面撑开且原位留空不补牌",
		scene._hand_gap_open and scene.hand_cards.get_child_count() == hand_size - 1)
	await _wait_frames(14)
	_check("开扇也是滑到位的，不是瞬跳",
		not is_equal_approx(collapsed_x,
			(scene.hand_cards.get_child(4) as Control).position.x))
	var opened_hand_xs := _hand_xs(scene)
	await _drag_release(scene.hand_scroll.get_global_rect().get_center())
	var settled_xs := _hand_xs(scene)
	# 落回原位 = 与拖拽前同一个 x；若走了抽牌动画，这张牌会从抽牌堆飞出来、位置对不上。
	_check("松手卡牌立即落回空位且其余手牌不动",
		scene.hand_cards.get_child_count() == hand_size and not scene._hand_gap_open \
			and scene._selected_ids.is_empty() \
			and _same_xs(opened_hand_xs, settled_xs) \
			and settled_xs.has(drag_id) \
			and is_equal_approx(pre_drag_xs[drag_id], settled_xs[drag_id]))

	# 手牌拖出去、既没落到结算区也没拖回手牌：与点击等效，直接叠到出牌列末尾。
	var stray_id := str((scene.hand_cards.get_child(2) as Control).get_meta("instance_id", ""))
	var stray_from := (scene.hand_cards.get_child(2) as Control).get_global_rect().get_center()
	var stray_to := Vector2(stray_from.x, scene.play_scroll.get_global_rect().position.y - 60.0)
	await _drag(stray_from, stray_to)
	_check("手牌拖到空白处等同于点击叠放",
		scene._selected_ids.has(stray_id) and scene.play_cards.get_child_count() > 0)
	# 撤回这次叠放，后面的弃牌流程要用干净的出牌区。
	scene._on_play_card_pressed(stray_id)
	await _wait_frames(2)

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


## 定帧推进：本测试以 --fixed-fps 60 跑，一帧固定 1/60 秒，用来跨过按时间走的入场补间。
func _wait_frames(count: int) -> void:
	for index: int in count:
		await get_tree().process_frame


## 按下并越过 8px 阈值把拖拽拉起来，停在这里，便于检查拖拽途中的状态。
## 走真实的按下 / 移动序列，途经 `_input` 里的自绘拖拽，而不是直接调内部方法。
func _drag_start(from: Vector2) -> void:
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.position = from
	press.pressed = true
	get_viewport().push_input(press, true)
	await get_tree().process_frame
	var motion := InputEventMouseMotion.new()
	motion.position = from + Vector2(20.0, 0.0)
	get_viewport().push_input(motion, true)
	await get_tree().process_frame
	await get_tree().process_frame


func _drag_release(at: Vector2) -> void:
	var motion := InputEventMouseMotion.new()
	motion.position = at
	get_viewport().push_input(motion, true)
	await get_tree().process_frame
	var release := InputEventMouseButton.new()
	release.button_index = MOUSE_BUTTON_LEFT
	release.position = at
	release.pressed = false
	get_viewport().push_input(release, true)
	await get_tree().process_frame
	await get_tree().process_frame


## 手牌里「牌 -> 基准 x」的对照表，用来核对某次拖拽前后其余牌有没有挪窝。
func _hand_xs(scene: Node) -> Dictionary:
	var xs := {}
	for slot: Control in scene.hand_cards.get_children():
		xs[str(slot.get_meta("instance_id", ""))] = slot.position.x
	return xs


## 前后两次采样里，同名的手牌都没挪窝。
func _same_xs(before: Dictionary, after: Dictionary) -> bool:
	for instance_id: String in before:
		if not after.has(instance_id) or not is_equal_approx(before[instance_id], after[instance_id]):
			return false
	return true


## 出牌行实际呈现的透明度：行自身与卡槽会叠乘，用来卡住「重复压半透」。
func _row_alpha(row: Control) -> float:
	var alpha := (row as CanvasItem).modulate.a
	for child in row.get_children():
		if child is CanvasItem:
			alpha *= (child as CanvasItem).modulate.a
			break
	return alpha


## 拖拽途中只挪鼠标，不松手，用来检查跨越扇面边界那一刻的收扇 / 开扇。
func _drag_move(to: Vector2) -> void:
	var motion := InputEventMouseMotion.new()
	motion.position = to
	get_viewport().push_input(motion, true)
	await get_tree().process_frame
	await get_tree().process_frame


## 手牌里当前处于悬停态的格数。
func _hand_hovered_count(scene: Node) -> int:
	var count := 0
	for slot: Control in scene.hand_cards.get_children():
		if bool(slot.get_meta("hovered", false)):
			count += 1
	return count


## 一整轮拖拽：按下拖起来、移到落点、松手。
func _drag(from: Vector2, to: Vector2) -> void:
	await _drag_start(from)
	await _drag_release(to)


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
