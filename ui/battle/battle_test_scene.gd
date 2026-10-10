class_name BattleTestScene
extends Control

## 可在检查器调整的测试参数。
@export_range(0, 20, 1) var initial_draw_count := 12
@export_range(1, 20, 1) var play_limit := 10
@export_range(0, 20, 1) var per_turn_draw_count := 2
@export_range(0.05, 3.0, 0.05) var resolution_delay := 0.5
@export_range(0.05, 3.0, 0.05) var enemy_turn_delay := 0.75
@export_range(1.0, 2.0, 0.05) var hand_hover_multiplier := 1.5
@export_range(0.1, 1.0, 0.01) var hand_hover_duration := 0.42
@export var relic_board_path := RelicBoard.SAVE_PATH
@export_range(1, 99999, 1) var enemy_starting_health := 3000

const HAND_CARD_SCALE := 0.27
const PLAY_CARD_SCALE := HAND_CARD_SCALE * 0.5
const PILE_CARD_SCALE := 0.18
const CARD_SCENE := preload("res://ui/components/card/card_view.tscn")
const POINTER_TEXTURE := preload("res://assets/battle_test/UI-017.png")
const TEST_CARD_DIR := "res://data/cards/test"
const TEST_DECK_CARD_IDS: Array[String] = [
	"test_damage_enemy", "test_damage_self", "test_block", "test_heal",
	"test_poison", "test_weak", "test_strength", "test_move_pointer",
	"test_draw", "test_discard_choice", "test_repeat_next",
	"test_damage_enemy", "test_block", "test_heal", "test_poison",
	"test_weak", "test_strength", "test_draw", "test_discard_choice",
	"test_repeat_next",
]

@onready var turn_label: Label = %TurnLabel
@onready var phase_label: Label = %PhaseLabel
@onready var count_label: Label = %CountLabel
@onready var hint_label: Label = %HintLabel
@onready var player_status: Label = %PlayerStatus
@onready var enemy_status: Label = %EnemyStatus
@onready var hand_cards: HBoxContainer = %HandCards
@onready var play_cards: VBoxContainer = %PlayCards
@onready var draw_button: Button = %DrawPileButton
@onready var discard_button: Button = %DiscardPileButton
@onready var cancel_button: Button = %CancelButton
@onready var play_button: Button = %PlayButton
@onready var pile_modal: Control = %PileModal
@onready var pile_title: Label = %PileTitle
@onready var pile_grid: GridContainer = %PileGrid

var _battle: BattleStateMachine
var _resolver: BattleEffectResolver
var _relics: RelicBattleSystem
var _relic_board := RelicBoard.new()
var _relic_catalog: Dictionary = {}
var _relic_cells: Array[Label] = []
var _relic_log: Label
var _relic_events: Array[String] = []
var _relic_edit_button: Button
var _relic_title: Label
var _restart_button: Button
var _battle_result := ""
var _selected_ids: Array[String] = []
var _selected_cards: Array[Dictionary] = []
var _discard_selection_ids: Array[String] = []
var _pending_discard_count := 0
var _pending_discard_card_id := ""
var _resolution_events: Array[Dictionary] = []
var _display_pointer_id := ""
var _busy := false
var _animating := false
var _refresh_queued := false


func _ready() -> void:
	draw_button.pressed.connect(_on_draw_pile_pressed)
	discard_button.pressed.connect(_on_discard_pile_pressed)
	cancel_button.pressed.connect(_on_cancel_pressed)
	play_button.pressed.connect(_on_play_pressed)
	%ClosePileButton.pressed.connect(_close_pile_modal)
	%PileModalShade.gui_input.connect(_on_modal_shade_input)
	_build_relic_hud()
	_start_test_battle()


func _start_test_battle() -> void:
	if SeedService.get_main_seed().is_empty():
		SeedService.begin_run("battle-effects-ui-test")

	_battle = BattleStateMachine.new()
	_battle.name = "BattleStateMachine"
	add_child(_battle)
	_battle.turn_started.connect(_on_turn_started)
	_battle.card_resolved.connect(_on_card_resolved)
	_battle.discard_choice_requested.connect(_on_discard_choice_requested)
	_battle.battle_ended.connect(_on_battle_ended)

	var deck: Array[Dictionary] = []
	for index in TEST_DECK_CARD_IDS.size():
		deck.append({
			"instance_id": "test-card-%02d" % (index + 1),
			"card_id": TEST_DECK_CARD_IDS[index],
		})

	var error := _battle.initialize_battle({
		"map_id": "battle-effects-ui-test",
		"node_id": "test-room",
		"battle_index": 0,
		# 首抽与每回合抽牌由本场景分别控制，状态机不额外自动抽牌。
		"draw_count": 0,
		"discard_hand_at_turn_end": false,
		"player": {
			"health": 60,
			"max_health": 100,
			"block": 0,
			"buffs": [],
		},
		"enemies": [{
			"enemy_id": "chr-025",
			"health": enemy_starting_health,
			"max_health": enemy_starting_health,
			"block": 0,
			"buffs": [],
			"actions": [{"action_id": "test-attack", "damage": 6}],
		}],
		"deck_instances": deck,
	})
	if error == OK:
		_resolver = BattleEffectResolver.new()
		_resolver.name = "BattleEffectResolver"
		add_child(_resolver)
		error = _resolver.attach_to_battle(_battle)
	if error == OK:
		_relic_catalog = RelicCatalog.load_definitions()
		var loaded := _relic_board.load_from_file(_relic_catalog, relic_board_path)
		if loaded != OK and loaded != ERR_FILE_NOT_FOUND:
			error = loaded
	if error == OK:
		_relics = RelicBattleSystem.new()
		_relics.name = "RelicBattleSystem"
		add_child(_relics)
		_relics.fragment_activated.connect(_on_relic_activated)
		_relics.chain_limited.connect(_on_relic_chain_limited)
		error = _relics.attach_to_battle(_battle, _relic_board, _relic_catalog, _resolver.buff_catalog)
		_refresh_relic_hud()
	if error == OK:
		error = _battle.start_battle()
	if error == OK and _battle.active:
		error = _battle.draw_cards(initial_draw_count)
	if error != OK:
		_busy = true
		hint_label.text = "战斗测试初始化失败：%d" % error
		push_error("BattleTestScene: initialization failed: %d" % error)
	_queue_refresh()


func _build_relic_hud() -> void:
	var panel := PanelContainer.new()
	panel.position = Vector2(24, 222)
	panel.size = Vector2(460, 350)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.06, 0.07, 0.1, 0.95)
	style.set_corner_radius_all(10)
	style.content_margin_left = 12
	style.content_margin_right = 12
	style.content_margin_top = 12
	style.content_margin_bottom = 12
	panel.add_theme_stylebox_override("panel", style)
	# 放在牌堆弹窗之前，保证弹窗仍遮挡战场 HUD。
	add_child(panel)
	move_child(panel, pile_modal.get_index())
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 8)
	panel.add_child(column)
	var row := HBoxContainer.new()
	column.add_child(row)
	_relic_title = Label.new()
	_relic_title.text = "典籍 · 0 次生效"
	_relic_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_relic_title.add_theme_font_size_override("font_size", 21)
	row.add_child(_relic_title)
	_relic_edit_button = Button.new()
	_relic_edit_button.text = "典籍页面"
	_relic_edit_button.pressed.connect(_return_to_relic_page)
	row.add_child(_relic_edit_button)
	_restart_button = Button.new()
	_restart_button.text = "重开战斗"
	_restart_button.pressed.connect(_restart_battle)
	row.add_child(_restart_button)
	var grid := GridContainer.new()
	grid.columns = RelicBoard.COLUMNS
	grid.add_theme_constant_override("h_separation", 6)
	grid.add_theme_constant_override("v_separation", 6)
	column.add_child(grid)
	for index in RelicBoard.CELL_COUNT:
		var label := Label.new()
		label.text = "—"
		label.custom_minimum_size = Vector2(102, 44)
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		label.add_theme_font_size_override("font_size", 18)
		_relic_cells.append(label)
		grid.add_child(label)
	_relic_log = Label.new()
	_relic_log.text = "尚未配置残片，点击典籍页面进行编排。"
	_relic_log.add_theme_font_size_override("font_size", 16)
	_relic_log.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(_relic_log)


func _refresh_relic_hud() -> void:
	for index in _relic_cells.size():
		var data: RelicFragmentData = _relic_catalog.get(_relic_board.cells[index])
		var label := _relic_cells[index]
		label.text = "—" if data == null else "%s\n%s" % [data.kind_name(), data.display_name]
		label.tooltip_text = "空格" if data == null else data.description
		label.add_theme_color_override("font_color", Color("737b8b") if data == null else data.tint())
		var style := StyleBoxFlat.new()
		style.bg_color = Color("252936")
		style.set_corner_radius_all(5)
		label.add_theme_stylebox_override("normal", style)


func _on_relic_activated(trigger: int, effect: int, description: String) -> void:
	_relic_events.append("[%d→%d] %s" % [trigger + 1, effect + 1, description])
	if _relic_events.size() > 4:
		_relic_events.pop_front()
	_relic_log.text = "\n".join(_relic_events)
	_relic_title.text = "典籍 · %d 次生效" % _relics.activation_count
	for index: int in [trigger, effect]:
		var label := _relic_cells[index]
		var previous: Variant = label.get_meta("flash") if label.has_meta("flash") else null
		if previous is Tween and previous.is_valid():
			previous.kill()
		label.modulate = Color(1.8, 1.8, 1.8)
		var flash := label.create_tween()
		flash.tween_property(label, "modulate", Color.WHITE, 0.45).set_trans(Tween.TRANS_SPRING)
		label.set_meta("flash", flash)


func _on_relic_chain_limited() -> void:
	_relic_log.text += "\n本条连锁已达到安全上限。"


func _return_to_relic_page() -> void:
	if not _busy:
		var error := get_tree().change_scene_to_file("res://ui/relics/relic_test_scene.tscn")
		if error != OK:
			hint_label.text = "打开典籍页面失败：%d" % error


func _restart_battle() -> void:
	if not _busy:
		var error := get_tree().change_scene_to_file("res://ui/battle/battle_test_scene.tscn")
		if error != OK:
			hint_label.text = "重开战斗失败：%d" % error


func _on_battle_ended(result: Dictionary) -> void:
	_battle_result = String(result.status)
	_queue_refresh()


func _on_turn_started(turn_number: int) -> void:
	# 首回合在 start_battle 返回后按 initial_draw_count 抽牌；后续回合在
	# PLAYER_ACTION 信号期间同步调用，符合 BattleStateMachine 的接口约束。
	if turn_number > 1 and per_turn_draw_count > 0:
		var error := _battle.draw_cards(per_turn_draw_count)
		if error != OK:
			push_error("BattleTestScene: turn draw failed: %d" % error)


func _on_card_resolved(card: Dictionary, pointer: int) -> void:
	var enemy_snapshot: Dictionary = {}
	if not _battle.enemies.is_empty():
		enemy_snapshot = _battle.enemies[0].duplicate(true)
	_resolution_events.append({
		"instance_id": String(card.get("instance_id", "")),
		"pointer": pointer,
		"player": _battle.player.duplicate(true),
		"enemy": enemy_snapshot,
	})


func _on_discard_choice_requested(card: Dictionary, count: int,
		_candidates: Array[Dictionary]) -> void:
	_pending_discard_count = count
	_pending_discard_card_id = String(card.get("instance_id", ""))
	_discard_selection_ids.clear()
	_queue_refresh()


func _on_hand_card_pressed(instance_id: String) -> void:
	if not _battle.active:
		hint_label.text = "战斗已结束，请点击重开战斗；测试敌人生命可在检查器调整。"
		return
	if _pending_discard_count > 0:
		_select_card_to_discard(instance_id)
		return
	if _battle.phase != BattleStateMachine.Phase.PLAYER_ACTION:
		hint_label.text = "当前结算未完成，请完成弃牌选择或重开战斗。"
		return
	if _busy or _selected_ids.size() >= play_limit:
		if not _busy:
			hint_label.text = "出牌区已满（上限 %d 张）" % play_limit
		return
	if _selected_ids.has(instance_id):
		return
	var card := _find_card(_battle.hand, instance_id)
	if card.is_empty():
		return
	_selected_ids.append(instance_id)
	_selected_cards.append(card.duplicate(true))
	hint_label.text = "已编排 %d / %d 张；将按从上到下结算" % [
		_selected_ids.size(), play_limit,
	]
	_queue_refresh()


func _select_card_to_discard(instance_id: String) -> void:
	if _discard_selection_ids.has(instance_id) \
			or _find_card(_battle.hand, instance_id).is_empty():
		return
	_discard_selection_ids.append(instance_id)
	hint_label.text = "选择弃牌：%d / %d" % [
		_discard_selection_ids.size(), _pending_discard_count,
	]
	_queue_refresh()
	if _discard_selection_ids.size() == _pending_discard_count:
		call_deferred("_submit_discard_selection")


func _submit_discard_selection() -> void:
	var chosen: Array[String] = _discard_selection_ids.duplicate()
	var previous_count := _pending_discard_count
	var previous_card := _pending_discard_card_id
	# 恢复队列可能立即请求下一次弃牌，先清理本次选择，避免覆盖新请求。
	_pending_discard_count = 0
	_pending_discard_card_id = ""
	_discard_selection_ids.clear()
	var error := _battle.submit_discard_choice(chosen)
	if error != OK:
		_pending_discard_count = previous_count
		_pending_discard_card_id = previous_card
		_discard_selection_ids.assign(chosen)
		hint_label.text = "提交弃牌选择失败：%d" % error
		return
	_queue_refresh()
	_drain_resolution_events()


func _on_cancel_pressed() -> void:
	if _busy:
		return
	_selected_ids.clear()
	_selected_cards.clear()
	hint_label.text = "已取消编排，卡牌全部返回手牌"
	_queue_refresh()


func _on_play_pressed() -> void:
	if _busy or not _battle.active or _selected_ids.is_empty():
		return
	_busy = true
	_resolution_events.clear()
	hint_label.text = "开始结算……"
	_refresh_header()

	var sequence: Array[String] = _selected_ids.duplicate()
	var targets := {}
	for instance_id: String in sequence:
		targets[instance_id] = "chr-025"
	var error := _battle.commit_player_sequence(sequence, targets)
	if error != OK:
		_busy = false
		hint_label.text = "提交出牌序列失败：%d" % error
		_refresh_header()
		return
	_drain_resolution_events()


func _drain_resolution_events() -> void:
	if _animating:
		return
	_animating = true
	while not _resolution_events.is_empty():
		var event: Dictionary = _resolution_events.pop_front()
		var instance_id := String(event["instance_id"])
		_set_pointer(instance_id)
		phase_label.text = "玩家回合 · 指针位置 %d" % (int(event["pointer"]) + 1)
		hint_label.text = "UI-017 正在结算：%s" % _card_display_name(instance_id)
		_render_combat_snapshot(event["player"], event["enemy"])
		await get_tree().create_timer(resolution_delay).timeout

	if _battle.has_pending_discard_choice():
		_set_pointer(_pending_discard_card_id)
		phase_label.text = "玩家回合 · 等待弃牌"
		hint_label.text = "请点击手牌弃置 %d 张（已选 %d 张）" % [
			_pending_discard_count, _discard_selection_ids.size(),
		]
		_animating = false
		_queue_refresh()
		return
	if not _battle.active:
		_selected_ids.clear()
		_selected_cards.clear()
		_busy = false
		_animating = false
		_set_pointer("")
		hint_label.text = "战斗结束，可以返回典籍页面调整残片。"
		_queue_refresh()
		return

	_set_pointer("")
	phase_label.text = "怪物回合"
	hint_label.text = "CHR-025 攻击 6 点；格挡在敌方回合末清零"
	_refresh_combat_status()
	await get_tree().create_timer(enemy_turn_delay).timeout

	_selected_ids.clear()
	_selected_cards.clear()
	_busy = false
	_animating = false
	hint_label.text = "玩家回合开始：请选择手牌编排到右侧"
	_queue_refresh()


func _on_draw_pile_pressed() -> void:
	if not _busy:
		_open_pile("抽牌堆", _battle.draw_pile)


func _on_discard_pile_pressed() -> void:
	if not _busy:
		_open_pile("弃牌堆", _battle.discard_pile)


func _open_pile(title: String, cards: Array[Dictionary]) -> void:
	pile_title.text = "%s（%d 张）" % [title, cards.size()]
	_clear_children(pile_grid)
	for card: Dictionary in cards:
		pile_grid.add_child(_make_card_slot(card, PILE_CARD_SCALE, false))
	pile_modal.visible = true


func _close_pile_modal() -> void:
	pile_modal.visible = false


func _on_modal_shade_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		_close_pile_modal()


func _queue_refresh() -> void:
	if _refresh_queued:
		return
	_refresh_queued = true
	call_deferred("_refresh_zones")


func _refresh_zones() -> void:
	_refresh_queued = false
	_clear_children(hand_cards)
	_clear_children(play_cards)

	for card: Dictionary in _battle.hand:
		var instance_id := String(card["instance_id"])
		if not _selected_ids.has(instance_id) and not _discard_selection_ids.has(instance_id):
			hand_cards.add_child(_make_card_slot(card, HAND_CARD_SCALE, true))

	for card: Dictionary in _selected_cards:
		play_cards.add_child(_make_play_row(card))
	_set_pointer(_display_pointer_id)

	_refresh_header()
	_refresh_combat_status()


func _refresh_header() -> void:
	if _battle == null:
		return
	turn_label.text = "回合 %d" % _battle.turn_number
	if not _battle.active:
		phase_label.text = "战斗胜利" if _battle.phase == BattleStateMachine.Phase.VICTORY else "战斗结束"
		if not _busy:
			hint_label.text = "战斗%s，点击左侧重开战斗。典籍可在首抽时造成伤害。" % ("胜利" if _battle_result == "victory" else "结束")
	elif not _busy:
		phase_label.text = "玩家回合 · 编排阶段"
	count_label.text = "首抽 %d  |  每回合抽 %d  |  出牌上限 %d" % [
		initial_draw_count, per_turn_draw_count, play_limit,
	]
	draw_button.text = "抽牌堆\n%d" % _battle.draw_pile.size()
	discard_button.text = "弃牌堆\n%d" % _battle.discard_pile.size()
	draw_button.disabled = _busy
	discard_button.disabled = _busy
	cancel_button.disabled = _busy or _selected_ids.is_empty()
	play_button.disabled = _busy or not _battle.active or _selected_ids.is_empty() \
		or _battle.phase != BattleStateMachine.Phase.PLAYER_ACTION
	play_button.text = "结算 %d 张" % _selected_ids.size()
	_relic_edit_button.disabled = _busy
	_restart_button.disabled = _busy
	for slot: Node in hand_cards.get_children():
		var button := slot.get_child(1) as Button
		if button != null:
			button.disabled = not _can_click_hand()


func _refresh_combat_status() -> void:
	if _battle == null or _battle.enemies.is_empty():
		return
	_render_combat_snapshot(_battle.player, _battle.enemies[0])


func _render_combat_snapshot(player_data: Dictionary, enemy_data: Dictionary) -> void:
	player_status.text = "玩家  HP %d/%d  格挡 %d\nBuff：%s" % [
		int(player_data.get("health", 0)), int(player_data.get("max_health", 0)),
		int(player_data.get("block", 0)), _format_buffs(player_data.get("buffs", [])),
	]
	enemy_status.text = "CHR-025  HP %d/%d  格挡 %d\nBuff：%s" % [
		int(enemy_data.get("health", 0)), int(enemy_data.get("max_health", 0)),
		int(enemy_data.get("block", 0)), _format_buffs(enemy_data.get("buffs", [])),
	]


func _can_click_hand() -> bool:
	return _battle != null and _battle.active and (_pending_discard_count > 0 \
		or (not _busy and _battle.phase == BattleStateMachine.Phase.PLAYER_ACTION))


func _make_card_slot(card: Dictionary, card_scale: float, clickable: bool) -> Control:
	var slot := Control.new()
	var card_size := Vector2(480.0, 818.0) * card_scale
	slot.custom_minimum_size = card_size
	slot.size = card_size
	slot.set_meta("instance_id", String(card["instance_id"]))
	slot.set_meta("base_size", card_size)
	slot.set_meta("base_scale", card_scale)
	if clickable:
		# 手牌从底边向上生长，放大时不会向下挤出屏幕。
		slot.size_flags_vertical = Control.SIZE_SHRINK_END

	var view: CardView = CARD_SCENE.instantiate()
	view.scale = Vector2.ONE * card_scale
	var data := _card_data(String(card.get("card_id", "")))
	if data != null:
		view.set_card(data)
	slot.add_child(view)

	if clickable:
		var button := Button.new()
		button.flat = true
		button.disabled = not _can_click_hand()
		button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		button.tooltip_text = "点击选择：%s" % (data.card_name if data != null else "未知卡牌")
		button.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		button.pressed.connect(_on_hand_card_pressed.bind(String(card["instance_id"])))
		button.mouse_entered.connect(_on_hand_card_hover_changed.bind(slot, view, true))
		button.mouse_exited.connect(_on_hand_card_hover_changed.bind(slot, view, false))
		slot.add_child(button)
	return slot


func _on_hand_card_hover_changed(slot: Control, view: CardView, expanded: bool) -> void:
	if not is_instance_valid(slot) or not is_instance_valid(view):
		return
	slot.set_meta("hovered", expanded)
	var previous: Variant = slot.get_meta("hover_tween") if slot.has_meta("hover_tween") else null
	if previous is Tween and previous.is_valid():
		previous.kill()

	var base_size: Vector2 = slot.get_meta("base_size", slot.custom_minimum_size)
	var base_scale := float(slot.get_meta("base_scale", HAND_CARD_SCALE))
	var multiplier := hand_hover_multiplier if expanded else 1.0
	var target_size := base_size * multiplier
	var target_scale := Vector2.ONE * base_scale * multiplier
	slot.z_index = 100 if expanded else 0

	# 卡槽与卡面使用同一弹簧曲线：卡槽真实变宽会驱动 HBoxContainer 每帧重排，
	# 因而相邻卡牌会平滑让位，而不是仅视觉放大后互相覆盖。
	var tween := slot.create_tween()
	tween.set_parallel(true)
	tween.set_trans(Tween.TRANS_SPRING)
	tween.set_ease(Tween.EASE_OUT)
	tween.tween_property(slot, "custom_minimum_size", target_size, hand_hover_duration)
	tween.tween_property(view, "scale", target_scale, hand_hover_duration)
	slot.set_meta("hover_tween", tween)


func _make_play_row(card: Dictionary) -> Control:
	var row := HBoxContainer.new()
	row.custom_minimum_size = Vector2(122.0, 116.0)
	row.set_meta("instance_id", String(card["instance_id"]))

	var pointer := TextureRect.new()
	pointer.name = "Pointer"
	pointer.custom_minimum_size = Vector2(46.0, 46.0)
	pointer.texture = POINTER_TEXTURE
	pointer.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	pointer.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	pointer.visible = false
	row.add_child(pointer)
	row.add_child(_make_card_slot(card, PLAY_CARD_SCALE, false))
	return row


func _set_pointer(instance_id: String) -> void:
	_display_pointer_id = instance_id
	for row: Node in play_cards.get_children():
		var pointer := row.get_node_or_null("Pointer") as TextureRect
		if pointer != null:
			pointer.visible = instance_id != "" \
				and String(row.get_meta("instance_id", "")) == instance_id


func _clear_children(container: Node) -> void:
	# queue_free 而不是 free，且所有点击后的刷新都经 call_deferred 进入这里；
	# 避免释放正在派发 pressed 信号的锁定对象。
	for child: Node in container.get_children():
		container.remove_child(child)
		child.queue_free()


func _card_display_name(instance_id: String) -> String:
	var card := _find_card(_selected_cards, instance_id)
	if card.is_empty():
		return instance_id
	var data := _card_data(String(card.get("card_id", "")))
	return data.card_name if data != null else String(card.get("card_id", instance_id))


static func _card_data(card_id: String) -> CardData:
	var resource: Resource = load("%s/%s.tres" % [TEST_CARD_DIR, card_id])
	return resource as CardData


static func _format_buffs(buffs: Array) -> String:
	if buffs.is_empty():
		return "无"
	var names: Array[String] = []
	for buff: Dictionary in buffs:
		var buff_id := String(buff.get("buff_id", ""))
		var display := String({
			"poison": "中毒", "strength": "力量", "weak": "虚弱",
		}.get(buff_id, buff_id))
		names.append("%s %d" % [display, int(buff.get("layers", 0))])
	return "、".join(names)


static func _find_card(cards: Array[Dictionary], instance_id: String) -> Dictionary:
	for card: Dictionary in cards:
		if String(card.get("instance_id", "")) == instance_id:
			return card
	return {}
