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
@export var deck_card_ids: Array[String] = []
@export var test_player_health := 60
@export var test_player_max_health := 100
@export var test_silver := 0

const HAND_CARD_SCALE := 0.27
const PLAY_CARD_SCALE := HAND_CARD_SCALE * 0.5
const PILE_CARD_SCALE := 0.18
var _enchantment_hover: PanelContainer
var _enchantment_hover_id := ""
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
@onready var hand_cards: Control = %HandCards
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
var _pile_selection_ids: Array[String] = []
var _display_cards: Array[Dictionary] = []


@export_range(0.0, 1.0, 0.01) var hand_hover_return_duration := 0.18
@export_range(0.0, 120.0, 1.0) var fan_offset_long := 50.0
@export_range(0.0, 120.0, 1.0) var fan_offset_medium := 35.0
@export_range(0.0, 120.0, 1.0) var fan_offset_short := 15.0
@export_range(0.05, 1.0, 0.01) var fan_duration_in := 0.15
@export_range(0.05, 1.0, 0.01) var fan_duration_out := 0.18
@export var fan_factor_by_count: Array[float] = [
	0.0, 0.6, 0.6, 0.6, 0.6, 0.6, 0.6, 0.6, 0.6, 0.6, 0.6,
]
const HAND_CARD_SIZE := Vector2(480.0, 818.0) * HAND_CARD_SCALE
const HAND_AREA_WIDTH := 1490.0
const HAND_HOVER_MARGIN := 34.0
const HAND_AREA_HEIGHT := 332.0
const HAND_GAP := 6.0
const PLAYER_BAR_WIDTH := 240.0
const ENEMY_BAR_WIDTH := 700.0
const BLOCK_MARKER_WIDTH := 16.0
const RELIC_PANEL_POSITION := Vector2(24, 268)
const RELIC_PANEL_WIDTH := 240.0
const RELIC_CELL_SIZE := Vector2(45, 44)
const RELIC_GRID_ORIGIN := Vector2(21, 14)
const RELIC_GRID_SEPARATION := Vector2(6, 4)
const RELIC_LOG_SIZE := Vector2(240, 72)
const RUN_MENU := preload("res://ui/hud/run_menu_overlay.gd")
const MAP_VIEWER := preload("res://ui/world_map/map_viewer.gd")
const MAP_SNAPSHOT_PATH := "res://data/config/flat_2d/demo_map.json"
const MENU_SCENE := "res://ui/main_menu/main_menu.tscn"
@onready var hand_scroll: ScrollContainer = $HandScroll
@onready var play_count_label: Label = $PlayCountLabel
@onready var hand_count_label: Label = $HandCountLabel
@onready var player_hp_fill: ColorRect = $PlayerHPBar/Fill
@onready var player_hp_block: ColorRect = $PlayerHPBar/Block
@onready var player_hp_num: Label = $PlayerHPNum
@onready var enemy_hp_fill: ColorRect = $EnemyHPBar/Fill
@onready var enemy_hp_block: ColorRect = $EnemyHPBar/Block
@onready var enemy_hp_num: Label = $EnemyHPNum
@onready var player_buff_row: HBoxContainer = $PlayerBuffRow
@onready var enemy_buff_row: HBoxContainer = $EnemyBuffRow
var _fan_target: Control
var _fan_tween: Tween
var _hand_dragging := false
var _hand_drag_origin := 0.0
var _run_menu: RunMenuOverlay
var _map_page_source: Control


func _ready() -> void:
	pile_modal.z_index = 300
	draw_button.pressed.connect(_on_draw_pile_pressed)
	discard_button.pressed.connect(_on_discard_pile_pressed)
	cancel_button.pressed.connect(_on_cancel_pressed)
	play_button.pressed.connect(_on_play_pressed)
	_run_menu = RUN_MENU.new()
	_run_menu.name = "RunMenuOverlay"
	add_child(_run_menu)
	$PlayerPortrait.gui_input.connect(_on_player_portrait_input)
	_run_menu.abandon_requested.connect(_on_menu_abandon)
	_run_menu.return_to_menu_requested.connect(_on_menu_return)
	_run_menu.quit_requested.connect(_on_menu_quit)
	hand_scroll.gui_input.connect(_on_hand_scroll_input)
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
	_battle.pile_choice_requested.connect(_on_pile_choice_requested)
	_battle.battle_ended.connect(_on_battle_ended)

	var deck: Array[Dictionary] = []
	var chosen_deck: Array[String] = TEST_DECK_CARD_IDS if deck_card_ids.is_empty() else deck_card_ids
	for index in chosen_deck.size():
		deck.append({
			"instance_id": "test-card-%02d" % (index + 1),
			"card_id": chosen_deck[index],
		})

	var error := _battle.initialize_battle({
		"map_id": "battle-effects-ui-test",
		"node_id": "test-room",
		"battle_index": 0,
		# 首抽与每回合抽牌由本场景分别控制，状态机不额外自动抽牌。
		"draw_count": 0,
		"discard_hand_at_turn_end": false,
		"player": {
			"health": test_player_health,
			"max_health": test_player_max_health,
			"base_play_limit": play_limit,
			"silver": test_silver,
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
		error = _battle.draw_cards(initial_draw_count, BattleStateMachine.DrawReason.BATTLE_START)
	if error != OK:
		_busy = true
		hint_label.text = "战斗测试初始化失败：%d" % error
		push_error("BattleTestScene: initialization failed: %d" % error)
	_queue_refresh()


func _build_relic_hud() -> void:
	# 沿用 main 板面的行列数，不修改配置或存档。
	# UI-020（石板底框）与 UI-021（撕纸模板）到位后替换这里的纸面与格子样式。
	var book := Control.new()
	book.name = "RelicBook"
	book.position = RELIC_PANEL_POSITION
	# 版高随板面行数走，避免行列数与面板尺寸两处各写一份。
	var panel_height := RELIC_GRID_ORIGIN.y * 2.0 + RelicBoard.ROWS * RELIC_CELL_SIZE.y 		+ (RelicBoard.ROWS - 1) * RELIC_GRID_SEPARATION.y
	var panel_size := Vector2(RELIC_PANEL_WIDTH, panel_height)
	book.size = panel_size
	book.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# 放在牌堆弹窗之前，保证弹窗仍遮挡战场 HUD。
	add_child(book)
	move_child(book, pile_modal.get_index())

	var paper := Panel.new()
	paper.position = Vector2.ZERO
	paper.size = panel_size
	paper.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var paper_style := StyleBoxFlat.new()
	paper_style.bg_color = Color(0.851, 0.788, 0.639)
	paper_style.set_corner_radius_all(6)
	paper.add_theme_stylebox_override("panel", paper_style)
	book.add_child(paper)

	# _relic_cells 下标即 main 板面下标。
	_relic_title = Label.new()
	_relic_title.text = "典籍 · 0 次生效"
	_relic_title.position = Vector2(24, 242)
	_relic_title.size = Vector2(240, 24)
	_relic_title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_relic_title.add_theme_font_size_override("font_size", 16)
	add_child(_relic_title)
	move_child(_relic_title, pile_modal.get_index())
	var cells: Array[Label] = []
	cells.resize(RelicBoard.CELL_COUNT)
	var grid := GridContainer.new()
	grid.columns = RelicBoard.COLUMNS
	grid.position = RELIC_GRID_ORIGIN
	grid.add_theme_constant_override("h_separation", int(RELIC_GRID_SEPARATION.x))
	grid.add_theme_constant_override("v_separation", int(RELIC_GRID_SEPARATION.y))
	grid.mouse_filter = Control.MOUSE_FILTER_IGNORE
	book.add_child(grid)
	for index in RelicBoard.CELL_COUNT:
		var label := Label.new()
		label.text = "—"
		label.custom_minimum_size = RELIC_CELL_SIZE
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		label.clip_text = true
		label.add_theme_font_size_override("font_size", 16)
		cells[index] = label
		grid.add_child(label)
	_relic_cells.assign(cells)

	_relic_log = Label.new()
	_relic_log.position = Vector2(RELIC_PANEL_POSITION.x,
		RELIC_PANEL_POSITION.y + panel_size.y + 8.0)
	_relic_log.size = RELIC_LOG_SIZE
	_relic_log.text = "尚未配置残片，点击典籍页面进行编排。"
	_relic_log.add_theme_font_size_override("font_size", 16)
	_relic_log.add_theme_color_override("font_color", Color(0.749, 0.682, 0.553))
	_relic_log.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_relic_log.clip_text = true
	add_child(_relic_log)
	move_child(_relic_log, pile_modal.get_index())

	# 测试台入口：典籍页面与重开战斗，移到玩家血条下方。
	var button_style := StyleBoxFlat.new()
	button_style.bg_color = Color(0.141, 0.102, 0.075, 0.9)
	button_style.border_color = Color(0.909, 0.706, 0.333, 0.45)
	button_style.set_border_width_all(1)
	button_style.set_corner_radius_all(4)
	_relic_edit_button = _make_test_button(
		"典籍页面", button_style, Vector2(148, 94), _return_to_relic_page)
	_restart_button = _make_test_button(
		"重开战斗", button_style, Vector2(268, 94), _restart_battle)


func _refresh_relic_hud() -> void:
	for index in _relic_cells.size():
		var data: RelicFragmentData = _relic_catalog.get(_relic_board.cells[index])
		var label := _relic_cells[index]
		label.text = "—" if data == null else data.display_name
		label.tooltip_text = "空格" if data == null else "%s · %s" % [
			data.kind_name(), data.description,
		]
		label.add_theme_color_override("font_color",
			Color(0.66, 0.6, 0.49) if data == null else Color(0.165, 0.129, 0.094))
		var style := StyleBoxFlat.new()
		# 撕纸质感前的占位：有残片的格子偏白，空格稍暗。
		style.bg_color = Color(0.937, 0.886, 0.741) if data != null else Color(0.886, 0.831, 0.682)
		style.set_corner_radius_all(3)
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
		var error := get_tree().change_scene_to_file(scene_file_path)
		if error != OK:
			hint_label.text = "重开战斗失败：%d" % error


func _on_battle_ended(result: Dictionary) -> void:
	_battle_result = String(result.status)
	_queue_refresh()


func _on_turn_started(turn_number: int) -> void:
	# 首回合在 start_battle 返回后按 initial_draw_count 抽牌；后续回合在
	# PLAYER_ACTION 信号期间同步调用，符合 BattleStateMachine 的接口约束。
	if turn_number > 1 and per_turn_draw_count > 0:
		var error := _battle.draw_cards(per_turn_draw_count, BattleStateMachine.DrawReason.TURN_START)
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
		"play_zone": _battle.play_zone.duplicate(true),
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
	var card := _find_card(_battle.hand, instance_id)
	if _busy or (bool(card.get("occupies_slot", true)) and _used_slots() >= _battle.effective_play_limit()):
		if not _busy:
			hint_label.text = "出牌区已满（上限 %d 张）" % _battle.effective_play_limit()
		return
	if _selected_ids.has(instance_id):
		return
	if card.is_empty():
		return
	_selected_ids.append(instance_id)
	_selected_cards.append(card.duplicate(true))
	hint_label.text = "已编排 %d / %d 张；将按从上到下结算" % [
		_used_slots(), _battle.effective_play_limit(),
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
	if _busy or not _battle.active or (_selected_ids.is_empty() and _battle.play_zone.is_empty()):
		return
	_busy = true
	_display_cards.assign(_battle.play_zone)
	_display_cards.append_array(_selected_cards)
	_resolution_events.clear()
	hint_label.text = "开始结算……"
	_refresh_header()

	var sequence: Array[String] = _selected_ids.duplicate()
	var targets := {}
	for instance_id: String in sequence:
		targets[instance_id] = str(_battle.enemies[0].enemy_id)
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
		_display_cards.assign(event.get("play_zone", _selected_cards))
		_queue_refresh()
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
	if _battle.pending_pile_count() > 0:
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
	hint_label.text = "%s 行动；格挡在敌方回合末清零" % str(_battle.enemies[0].get("name", "CHR-025"))
	_refresh_combat_status()
	await get_tree().create_timer(enemy_turn_delay).timeout

	_selected_ids.clear()
	_selected_cards.clear()
	_display_cards.clear()
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
	if _battle != null and _battle.pending_pile_count() > 0:
		return
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
	_hide_enchantment_hover()
	_clear_children(hand_cards)
	_clear_children(play_cards)

	var hand_slots: Array[Control] = []
	_fan_target = null
	for card: Dictionary in _battle.hand:
		var instance_id := String(card["instance_id"])
		if not _selected_ids.has(instance_id) and not _discard_selection_ids.has(instance_id):
			var slot := _make_card_slot(card, HAND_CARD_SCALE, true)
			hand_cards.add_child(slot)
			hand_slots.append(slot)
	_layout_hand(hand_slots)
	hand_count_label.text = "%d 张" % hand_slots.size()

	if _busy:
		for card: Dictionary in _display_cards:
			play_cards.add_child(_make_play_row(card))
	else:
		var preview: Array[Dictionary] = _battle.play_zone.duplicate(true)
		for card: Dictionary in _selected_cards:
			var vacant := -1
			for index in preview.size():
				if bool(preview[index].get("slot_empty", false)):
					vacant = index
					break
			if vacant < 0:
				preview.append(card)
			else:
				preview[vacant] = card
		for card: Dictionary in preview:
			play_cards.add_child(_make_play_row(card))
	# 先前牌位显示在上层，避免负 z_index 落到战场背景后面。
	for index in play_cards.get_child_count():
		play_cards.get_child(index).z_index = play_cards.get_child_count() - index
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
			hint_label.text = "战斗%s，点击左侧重开战斗。效果抽牌仍可触发典籍。" % ("胜利" if _battle_result == "victory" else "结束")
	elif not _busy:
		phase_label.text = "玩家回合 · 编排阶段"
	count_label.text = "首抽 %d  |  每回合抽 %d  |  出牌上限 %d" % [
		initial_draw_count, per_turn_draw_count, _battle.effective_play_limit(),
	]
	draw_button.text = "抽牌堆\n%d" % _battle.draw_pile.size()
	discard_button.text = "弃牌堆\n%d" % _battle.discard_pile.size()
	draw_button.disabled = _busy
	discard_button.disabled = _busy
	cancel_button.disabled = _busy or _selected_ids.is_empty()
	play_button.disabled = _busy or not _battle.active or (_selected_ids.is_empty() and _battle.play_zone.is_empty()) \
		or _battle.phase != BattleStateMachine.Phase.PLAYER_ACTION
	var locked_count := 0
	for card: Dictionary in _battle.play_zone:
		if not bool(card.get("slot_empty", false)):
			locked_count += 1
	play_button.text = "结算 %d" % (_selected_ids.size() + locked_count)
	play_count_label.text = "%d/%d" % [_used_slots(), _battle.effective_play_limit()]
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
	_render_health(player_hp_fill, player_hp_block, player_hp_num, player_data, PLAYER_BAR_WIDTH)
	_render_health(enemy_hp_fill, enemy_hp_block, enemy_hp_num, enemy_data, ENEMY_BAR_WIDTH)
	_render_buffs(player_buff_row, player_data.get("buffs", []))
	_render_buffs(enemy_buff_row, enemy_data.get("buffs", []))
	player_status.text = "玩家  HP %d/%d  格挡 %d\nBuff：%s" % [
		int(player_data.get("health", 0)), int(player_data.get("max_health", 0)),
		int(player_data.get("block", 0)), _format_buffs(player_data.get("buffs", [])),
	]
	enemy_status.text = "%s  HP %d/%d  格挡 %d\nBuff：%s" % [
		str(enemy_data.get("name", "CHR-025")),
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
	# 轴心取卡面底边中点：放大时向上与左右生长。轴心在未缩放的局部坐标里，
	# 所以按基准缩放补偿偏移，否则卡面会被推离卡槽。
	view.pivot_offset = Vector2(view.custom_minimum_size.x * 0.5,
		view.custom_minimum_size.y)
	view.position = view.pivot_offset * (card_scale - 1.0)
	var data := _card_data(String(card.get("card_id", "")))
	if data != null:
		view.set_card(data)
	slot.add_child(view)
	slot.tooltip_text = CardEnchantments.describe(card)
	view.tooltip_text = slot.tooltip_text

	if clickable:
		var button := Button.new()
		button.flat = true
		button.disabled = not _can_click_hand()
		button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		button.tooltip_text = "点击选择：%s" % TextCatalog.display_name("cards", String(card.get("card_id", "")), data.card_name if data != null else "未知卡牌")
		button.tooltip_text += "\n\n" + CardEnchantments.describe(card)
		if not card.get("enchantments", []).is_empty():
			# 手牌位于底边，使用卡牌上方的内嵌提示，避免系统 tooltip 被窗口截断。
			button.tooltip_text = ""
			slot.tooltip_text = ""
			view.tooltip_text = ""
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
	var instance_id := str(slot.get_meta("instance_id", ""))
	if expanded:
		_show_enchantment_hover(slot, _find_card(_battle.hand, instance_id))
	elif _enchantment_hover_id == instance_id:
		_hide_enchantment_hover()
	var previous: Variant = slot.get_meta("hover_tween") if slot.has_meta("hover_tween") else null
	if previous is Tween and previous.is_valid():
		previous.kill()

	var base_scale := float(slot.get_meta("base_scale", HAND_CARD_SCALE))
	var multiplier := hand_hover_multiplier if expanded else 1.0
	var target_scale := Vector2.ONE * base_scale * multiplier
	slot.z_index = 100 if expanded else 0

	# 悬停卡绕底边中点放大（向上生长，不挤出屏幕），左右相邻卡扇开让位。
	var tween := slot.create_tween()
	tween.set_trans(Tween.TRANS_SPRING if expanded else Tween.TRANS_CUBIC)
	tween.set_ease(Tween.EASE_OUT)
	tween.tween_property(view, "scale", target_scale,
		hand_hover_duration if expanded else hand_hover_return_duration)
	slot.set_meta("hover_tween", tween)
	# A→B 切换时 Godot 先派发 A 的离开、再派发 B 的进入；这里延后一拍统一判定，
	# 避免中途先收扇再展开。
	call_deferred("_refresh_hand_fan")


func _hide_enchantment_hover() -> void:
	_enchantment_hover_id = ""
	if is_instance_valid(_enchantment_hover):
		_enchantment_hover.hide()


func _show_enchantment_hover(slot: Control, card: Dictionary) -> void:
	_hide_enchantment_hover()
	if card.get("enchantments", []).is_empty():
		return
	if not is_instance_valid(_enchantment_hover):
		_enchantment_hover = PanelContainer.new()
		_enchantment_hover.name = "EnchantmentHover"
		_enchantment_hover.z_index = 2000
		_enchantment_hover.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var style := StyleBoxFlat.new()
		style.bg_color = Color("211b16")
		style.border_color = Color("cba24d")
		style.set_border_width_all(2)
		style.set_corner_radius_all(8)
		style.content_margin_left = 16
		style.content_margin_right = 16
		style.content_margin_top = 12
		style.content_margin_bottom = 12
		_enchantment_hover.add_theme_stylebox_override("panel", style)
		var label := Label.new()
		label.custom_minimum_size.x = 420
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		label.add_theme_font_size_override("font_size", 22)
		label.add_theme_color_override("font_color", Color("ecd7ab"))
		label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_enchantment_hover.add_child(label)
		add_child(_enchantment_hover)
	var label: Label = _enchantment_hover.get_child(0)
	label.text = CardEnchantments.describe(card)
	_enchantment_hover_id = str(card.instance_id)
	_enchantment_hover.show()
	_enchantment_hover.reset_size()
	call_deferred("_position_enchantment_hover", slot, _enchantment_hover_id)


func _position_enchantment_hover(slot: Control, id: String) -> void:
	if not is_instance_valid(slot) or _enchantment_hover_id != id:
		return
	var rect := slot.get_global_rect()
	var bounds := get_viewport_rect().size
	var width := _enchantment_hover.size.x
	var height := _enchantment_hover.size.y
	_enchantment_hover.global_position = Vector2(
		clampf(rect.get_center().x - width * 0.5, 12, maxf(12, bounds.x - width - 12)),
		clampf(rect.position.y - rect.size.y * (hand_hover_multiplier - 1.0) - height - 16, 12, maxf(12, bounds.y - height - 12)))


func _make_play_row(card: Dictionary) -> Control:
	# 半叠：PlayCards 的 separation 取负值，后一张盖住前一张的上半，
	# 露出含名字带的下半。结算中的那张用金色高亮框标出，不再用箭头指针。
	var row := Control.new()
	var card_size := Vector2(480.0, 818.0) * PLAY_CARD_SCALE
	row.custom_minimum_size = card_size
	row.size = card_size
	row.set_meta("instance_id", String(card["instance_id"]))
	# 继续显示 UI-017 指针，并以新版高亮框标识当前结算卡。
	var pointer := TextureRect.new()
	pointer.name = "Pointer"
	pointer.position = Vector2(-40, card_size.y * 0.5 - 18)
	pointer.size = Vector2(36, 36)
	pointer.texture = POINTER_TEXTURE
	pointer.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	pointer.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	pointer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pointer.visible = false
	row.add_child(pointer)
	if bool(card.get("slot_empty", false)):
		var empty := Label.new()
		empty.text = "空牌位"
		empty.size = card_size
		empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		empty.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		empty.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(empty)
		return row
	row.add_child(_make_card_slot(card, PLAY_CARD_SCALE, false))

	var plate := Label.new()
	plate.name = "NamePlate"
	plate.text = _card_display_name(String(card["instance_id"]))
	plate.position = Vector2(0.0, card_size.y * 0.585)
	plate.size = Vector2(card_size.x, 20.0)
	plate.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	plate.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	plate.clip_text = true
	plate.mouse_filter = Control.MOUSE_FILTER_IGNORE
	plate.add_theme_font_size_override("font_size", 14)
	plate.add_theme_color_override("font_color", Color(0.949, 0.89, 0.776))
	# 只给字加投影，不铺底色，卡片保持原亮度。
	plate.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.95))
	plate.add_theme_constant_override("shadow_offset_x", 1)
	plate.add_theme_constant_override("shadow_offset_y", 1)
	row.add_child(plate)

	var highlight := Panel.new()
	highlight.name = "Highlight"
	highlight.position = Vector2(-2.0, -2.0)
	highlight.size = card_size + Vector2(4.0, 4.0)
	highlight.mouse_filter = Control.MOUSE_FILTER_IGNORE
	highlight.visible = false
	var highlight_style := StyleBoxFlat.new()
	highlight_style.draw_center = false
	highlight_style.set_border_width_all(2)
	highlight_style.border_color = Color(1.0, 0.85, 0.45, 0.95)
	highlight_style.set_corner_radius_all(4)
	highlight.add_theme_stylebox_override("panel", highlight_style)
	row.add_child(highlight)
	return row


func _set_pointer(instance_id: String) -> void:
	# 保留原方法名与调用点：现在只切换正在结算那张卡的高亮框。
	_display_pointer_id = instance_id
	for row: Node in play_cards.get_children():
		var pointer := row.get_node_or_null("Pointer") as TextureRect
		if pointer != null:
			pointer.visible = instance_id != "" and str(row.get_meta("instance_id", "")) == instance_id
		var highlight := row.get_node_or_null("Highlight") as Panel
		if highlight != null:
			highlight.visible = instance_id != "" \
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
		card = _find_card(_display_cards, instance_id)
	if card.is_empty():
		card = _find_card(_battle.play_zone, instance_id)
	if card.is_empty():
		return instance_id
	var data := _card_data(String(card.get("card_id", "")))
	return TextCatalog.display_name("cards", String(card.get("card_id", "")), data.card_name if data != null else String(card.get("card_id", instance_id)))


func _card_data(card_id: String) -> CardData:
	return _resolver.card_catalog.get(card_id) if _resolver != null else null


func _used_slots() -> int:
	var result := 0
	for zone: Array in [_selected_cards, _battle.play_zone]:
		for card: Dictionary in zone:
			if not bool(card.get("slot_empty", false)) and bool(card.get("occupies_slot", true)):
				result += 1
	return result


func _on_pile_choice_requested(count: int, candidates: Array[Dictionary]) -> void:
	_pile_selection_ids.clear()
	call_deferred("_show_pile_choice", count, candidates)


func _show_pile_choice(count: int, candidates: Array[Dictionary]) -> void:
	_display_cards.assign(_battle.play_zone)
	_queue_refresh()
	_open_pile("按顺序选择弃牌堆的 %d 张牌" % count, [])
	pile_title.text = "按顺序选择 %d 张牌（候选 %d 张）" % [count, candidates.size()]
	for card: Dictionary in candidates:
		var slot := _make_card_slot(card, PILE_CARD_SCALE, false)
		var button := Button.new()
		button.flat = true
		button.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		button.pressed.connect(_choose_pile_card.bind(str(card.instance_id), button))
		button.tooltip_text = CardEnchantments.describe(card)
		slot.add_child(button)
		pile_grid.add_child(slot)


func _choose_pile_card(id: String, button: Button) -> void:
	if _pile_selection_ids.has(id):
		return
	_pile_selection_ids.append(id)
	button.disabled = true
	button.text = str(_pile_selection_ids.size())
	if _pile_selection_ids.size() == _battle.pending_pile_count():
		call_deferred("_submit_pile_selection")


func _submit_pile_selection() -> void:
	var chosen: Array[String] = _pile_selection_ids.duplicate()
	_pile_selection_ids.clear()
	pile_modal.visible = false
	var error := _battle.submit_pile_choice(chosen)
	if error != OK:
		hint_label.text = "弃牌堆选择失败：%d" % error
	_queue_refresh()
	_drain_resolution_events()


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


func _make_test_button(text: String, style: StyleBoxFlat, position: Vector2,
		handler: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.position = position
	button.size = Vector2(112, 32)
	button.add_theme_font_size_override("font_size", 16)
	button.add_theme_color_override("font_color", Color(0.749, 0.682, 0.553))
	button.add_theme_stylebox_override("normal", style)
	button.add_theme_stylebox_override("hover", style)
	button.add_theme_stylebox_override("pressed", style)
	button.pressed.connect(handler)
	add_child(button)
	move_child(button, pile_modal.get_index())
	return button


func _render_health(fill: ColorRect, block: ColorRect, number: Label,
		data: Dictionary, bar_width: float) -> void:
	var health := int(data.get("health", 0))
	var max_health := maxi(int(data.get("max_health", 1)), 1)
	var block_layers := int(data.get("block", 0))
	var ratio := clampf(float(health) / float(max_health), 0.0, 1.0)
	fill.offset_left = 1.0
	fill.offset_right = 1.0 + (bar_width - 2.0) * ratio
	block.visible = block_layers > 0
	block.offset_left = fill.offset_right
	block.offset_right = minf(fill.offset_right + BLOCK_MARKER_WIDTH, bar_width - 1.0)
	number.text = "%d/%d" % [health, max_health]
	number.tooltip_text = "生命 %d/%d · 格挡 %d" % [health, max_health, block_layers]


func _render_buffs(row: HBoxContainer, buffs: Array) -> void:
	_clear_children(row)
	for buff: Dictionary in buffs:
		var buff_id := String(buff.get("buff_id", ""))
		var debuff := buff_id in ["poison", "weak", "vulnerable"]
		var chip := Label.new()
		chip.text = "%s %d" % [_buff_display_name(buff_id), int(buff.get("layers", 0))]
		chip.add_theme_font_size_override("font_size", 16)
		chip.add_theme_color_override("font_color",
			Color(0.81, 0.89, 0.66) if debuff else Color(0.949, 0.89, 0.776))
		var style := StyleBoxFlat.new()
		style.bg_color = Color(0.11, 0.078, 0.051, 0.78)
		style.set_corner_radius_all(13)
		style.set_border_width_all(1)
		style.border_color = Color(0.62, 0.75, 0.42, 0.6) if debuff \
			else Color(0.91, 0.71, 0.33, 0.45)
		style.content_margin_left = 9
		style.content_margin_right = 9
		style.content_margin_top = 3
		style.content_margin_bottom = 3
		chip.add_theme_stylebox_override("normal", style)
		row.add_child(chip)


func _layout_hand(slots: Array[Control]) -> void:
	# 手牌按固定步长排在中轴上；扇开时在基准位置上加偏移，基准不随动画漂移。
	var count := slots.size()
	if count == 0:
		hand_cards.custom_minimum_size = Vector2(HAND_AREA_WIDTH, 0.0)
		hand_cards.size = Vector2(HAND_AREA_WIDTH, HAND_AREA_HEIGHT)
		return
	var step := HAND_CARD_SIZE.x + HAND_GAP
	var total := step * (count - 1) + HAND_CARD_SIZE.x
	var row_width := maxf(total + HAND_HOVER_MARGIN * 2.0, HAND_AREA_WIDTH)
	if _fan_tween != null and _fan_tween.is_valid():
		_fan_tween.kill()
	hand_cards.custom_minimum_size = Vector2(row_width, 0.0)
	hand_cards.size = Vector2(row_width, HAND_AREA_HEIGHT)
	var start := (row_width - total) * 0.5
	for index in count:
		var slot := slots[index]
		slot.size = HAND_CARD_SIZE
		slot.position = Vector2(start + step * index, HAND_AREA_HEIGHT - HAND_CARD_SIZE.y)
		slot.set_meta("hand_index", index)
		slot.set_meta("base_x", slot.position.x)


func _fan_factor(count: int) -> float:
	if count >= 1 and count < fan_factor_by_count.size():
		return fan_factor_by_count[count]
	# 超过 10 张沿用最小幅度，保持有扇开动作但不会挤出牌区。
	return fan_factor_by_count[fan_factor_by_count.size() - 1] if count > 10 else 0.0


func _refresh_hand_fan() -> void:
	# 以当前真正处于悬停态的卡为准；一张都没有时才收扇。
	var target: Control = null
	for child in hand_cards.get_children():
		if bool(child.get_meta("hovered", false)):
			target = child
			break
	if target == _fan_target:
		return
	_fan_target = target
	_apply_hand_fan(target)


func _apply_hand_fan(hovered_slot: Control) -> void:
	# 参考 reference/card-and-dice 的 HandUIController.Hover：以悬停卡为中心，
	# 左右两侧按距离 1/2/3 分别外移大/中/小距离，手牌越多幅度越小；
	# 没有悬停卡时全部回基准位。
	var slots := hand_cards.get_children()
	var count := slots.size()
	var factor := _fan_factor(count)
	var hovered_index := -1
	if hovered_slot != null and is_instance_valid(hovered_slot):
		hovered_index = int(hovered_slot.get_meta("hand_index", -1))
	var duration := fan_duration_in if hovered_index >= 0 else fan_duration_out
	# 旧的扇开补间必须先杀掉：换卡时两条补间同时写 position:x 会互相打架，
	# 表现出来就是扇开中途回缩。
	if _fan_tween != null and _fan_tween.is_valid():
		_fan_tween.kill()
	var tween := create_tween()
	_fan_tween = tween
	tween.set_parallel(true)
	tween.set_trans(Tween.TRANS_CUBIC)
	tween.set_ease(Tween.EASE_OUT)
	for index in count:
		var slot: Control = slots[index]
		var base_x := float(slot.get_meta("base_x", slot.position.x))
		var offset := 0.0
		if hovered_index >= 0 and index != hovered_index:
			var magnitude := 0.0
			match absi(index - hovered_index):
				1: magnitude = fan_offset_long
				2: magnitude = fan_offset_medium
				3: magnitude = fan_offset_short
			if magnitude > 0.0:
				offset = magnitude * factor * (1.0 if index > hovered_index else -1.0)
		tween.tween_property(slot, "position:x", base_x + offset, duration)


func _input(event: InputEvent) -> void:
	# 与地图界面同一套：Esc 设置 / Tab 背包 / M 地图，再按一次退出。
	if _run_menu == null or not event is InputEventKey or event.is_echo():
		return
	if pile_modal.visible:
		if event.is_action_pressed("ui_cancel"):
			_close_pile_modal()
			get_viewport().set_input_as_handled()
		return
	var open := _run_menu.is_open()
	var page := _run_menu.current_page()
	if event.is_action_pressed("ui_cancel"):
		if open:
			_run_menu.close()
		else:
			_open_run_menu(2)
	elif event.is_action_pressed("ui_focus_next"):
		if open and page == 1:
			_run_menu.close()
		else:
			_open_run_menu(1)
	elif event.is_action_pressed("menu_map"):
		if open and page == 0:
			_run_menu.close()
		else:
			_open_run_menu(0)
	else:
		return
	get_viewport().set_input_as_handled()


func _on_player_portrait_input(event: InputEvent) -> void:
	# 战斗里也能看：点头像打开冒险菜单，地图页只查看不移动角色。
	if event is InputEventMouseButton and event.pressed \
			and event.button_index == MOUSE_BUTTON_LEFT:
		_open_run_menu()


func _on_menu_abandon() -> void:
	var gateway := get_node_or_null("/root/SaveGateway")
	if gateway != null:
		var error: Error = gateway.abandon_run()
		if error != OK:
			hint_label.text = "放弃本局失败：%d" % error
			return
	get_tree().change_scene_to_file(MENU_SCENE)


func _on_menu_return() -> void:
	var gateway := get_node_or_null("/root/SaveGateway")
	if gateway != null:
		var error: Error = gateway.save_current()
		if error != OK:
			hint_label.text = "保存失败，仍留在战斗：%d" % error
			return
	get_tree().change_scene_to_file(MENU_SCENE)


func _on_menu_quit() -> void:
	var gateway := get_node_or_null("/root/SaveGateway")
	if gateway != null:
		gateway.quit_game()
	else:
		get_tree().quit()


func _open_run_menu(page: int = 1) -> void:
	if _run_menu == null or _busy:
		return
	if _map_page_source == null:
		_map_page_source = _build_map_page_source()
	_run_menu.set_battle_context(_battle, _resolver.card_catalog, _relic_board)
	_run_menu.open(page)


func _build_map_page_source() -> Control:
	# 只查看的地图：真实渲染 + 滚轮缩放 + 拖动平移，不带角色位置。
	var data := _map_snapshot_data()
	if data.is_empty():
		return null
	# 先挂进浮层再喂数据，查看器内部节点在 _ready 里才建好。
	var viewer: Control = MAP_VIEWER.new()
	_run_menu.set_map_viewer(viewer)
	viewer.set_map(data, 60.0)
	return viewer


func _map_snapshot_data() -> Dictionary:
	# 战斗里没有跑图会话，按"全图已知"喂给查看器：地形与全部节点都看得见，
	# 方便战斗中规划路线。地图界面里改喂会话的已探索视图。
	if not FileAccess.file_exists(MAP_SNAPSHOT_PATH):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(MAP_SNAPSHOT_PATH))
	if not parsed is Dictionary:
		return {}
	var data: Dictionary = parsed
	for cell: Variant in data.get("cells", []):
		if cell is Dictionary:
			cell["known"] = true
	for node: Variant in data.get("nodes", []):
		if node is Dictionary:
			node["known"] = true
	return data


func _on_hand_scroll_input(event: InputEvent) -> void:
	# 空白处按住左键横拖即可翻看后面的牌；卡片自身的点击不受影响。
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		_hand_dragging = event.pressed
		if event.pressed:
			_hand_drag_origin = event.position.x + float(hand_scroll.scroll_horizontal)
	elif event is InputEventMouseMotion and _hand_dragging:
		hand_scroll.scroll_horizontal = int(_hand_drag_origin - event.position.x)


static func _buff_display_name(buff_id: String) -> String:
	return String({
		"poison": "中毒", "strength": "力量", "weak": "虚弱",
		"vulnerable": "易伤", "tenacity": "坚韧",
	}.get(buff_id, buff_id))
