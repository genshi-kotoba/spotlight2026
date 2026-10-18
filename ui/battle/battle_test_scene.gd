class_name BattleTestScene
extends Control

## 可在检查器调整的测试参数。
@export_range(0, 20, 1) var initial_draw_count := 12
@export_range(1, 20, 1) var play_limit := 10
@export_range(0, 20, 1) var per_turn_draw_count := 2
@export_range(0.05, 3.0, 0.05) var resolution_delay := 0.15
@export_range(0.05, 3.0, 0.05) var enemy_turn_delay := 0.75
@export_range(1.0, 2.0, 0.05) var hand_hover_multiplier := 1.5
## 悬停放大与回正时长：照 reference/card-and-dice 的 CardView（放大 HoverDuration=0.01 秒，
## 回正 ReturnDuration=0.18 秒，一快一慢）。
@export_range(0.0, 1.0, 0.01) var hand_hover_duration := 0.01
@export_range(0.0, 1.0, 0.01) var hand_hover_return_duration := 0.18
@export var relic_board_path := RelicBoard.SAVE_PATH
@export_range(1, 99999, 1) var enemy_starting_health := 3000

## 手牌悬停扇开，规则与取值参考 reference/card-and-dice 的 HandUIController.Hover：
## 距悬停卡 1/2/3 张分别外移大/中/小距离，手牌越多幅度越小（10 张时只剩 10%）。
@export_range(0.0, 120.0, 1.0) var fan_offset_long := 50.0
@export_range(0.0, 120.0, 1.0) var fan_offset_medium := 35.0
@export_range(0.0, 120.0, 1.0) var fan_offset_short := 15.0
@export_range(0.05, 1.0, 0.01) var fan_duration_in := 0.15
@export_range(0.05, 1.0, 0.01) var fan_duration_out := 0.18
## 按手牌张数缩放的扇开系数，下标即张数（1~10，0 位弃用）。
@export var fan_factor_by_count: Array[float] = [
	0.0, 0.6, 0.6, 0.6, 0.6, 0.6, 0.6, 0.6, 0.6, 0.6, 0.6,
]

const HAND_CARD_SCALE := 0.285
const PLAY_CARD_SCALE := 0.19
const PLAY_CARD_SIZE := Vector2(480.0, 818.0) * PLAY_CARD_SCALE
## 出牌列两列各 5 张，10 张一屏；每张露卡图与卡名，向上叠 140。
const PLAY_COLUMNS := 1
const PLAY_ROW_SIZE := Vector2(PLAY_CARD_SIZE.x + PLAY_POINTER_W, PLAY_CARD_SIZE.y)
const PLAY_ROWS_PER_COLUMN := 10
const PLAY_POINTER_W := 62.0
## 110 = 卡名带底边（0.696×155≈108）再留 2px，再小卡名就被下一张切掉了。
const PLAY_STEP := 110.0
const PLAY_COLUMN_GAP := 8.0
const PILE_CARD_SCALE := 0.40
const HAND_SLOT_COUNT := 10
const HAND_CARD_SIZE := Vector2(480.0, 818.0) * HAND_CARD_SCALE
## 手牌行的最小宽度：与手牌视口同宽，左右各留悬停生长余量。
const HAND_AREA_WIDTH := 1178.0
## 悬停放大时卡面向左右各生长 32.4，行首尾留出同样余量，避免贴边被视口裁掉。
const HAND_HOVER_MARGIN := 34.0
const HAND_AREA_HEIGHT := 332.0
const HAND_GAP := 6.0
## 手牌摆成扇形：以底边中点为轴往外旋，越靠边角度越大、位置略下沉；
## 牌多时压缩间距，最多 10 张也压在一屏里。
const HAND_ARC_SPREAD := 0.045
const HAND_ARC_RADIUS := 900.0
const HAND_MAX_WIDTH := 880.0
## 条内可填充宽度与左端起算位置：玩家条从 144 起、宽 250；Boss 条从 99 起、宽 781。
const PLAYER_BAR_LEFT := 144.0
const PLAYER_BAR_WIDTH := 250.0
const ENEMY_BAR_LEFT := 89.5
const ENEMY_BAR_WIDTH := 726.5
const BLOCK_MARKER_WIDTH := 16.0
const BUFF_ICON_REGION := Rect2(59, 62, 754, 754)
const BUFF_ICON_PATHS := {
	"poison": "res://assets/ui/UI-025/中毒.png",
	"strength": "res://assets/ui/UI-025/力量.png",
	"weak": "res://assets/ui/UI-025/虚弱.png",
}
const RELIC_BOOK_POSITION := Vector2(322, 132)
const RELIC_LOG_SIZE := Vector2(240, 72)
const CARD_SCENE := preload("res://ui/components/card/card_view.tscn")
const RUN_MENU := preload("res://ui/hud/run_menu_overlay.gd")
const VFX_SCRIPT := preload("res://ui/battle/vfx_playback.gd")
const FEEDBACK_SCRIPT := preload("res://ui/battle/combat_feedback.gd")
const BLOCK_SHIELD_SCRIPT := "res://ui/battle/block_shield.gd"
const ITEM_ICON_SCRIPT := "res://ui/components/item_icon.gd"
const HOVER_TIP_SCRIPT := "res://ui/components/hover_tip.gd"
const SETTINGS_BUTTON := preload("res://ui/components/settings_button.gd")
# 地图查看器是别的分支的历史遗留，可能不存在；这里只做存在性检查，不硬 preload，
# 免得拉不到那个文件时整个战斗场景解析失败。缺了就退化成菜单里的占位图。
const MAP_VIEWER_PATH := "res://ui/world_map/map_viewer.gd"
## 战斗里查看地图用的快照；正式跑图时改成读跑图状态里的地图。
const MAP_SNAPSHOT_PATH := "res://data/config/flat_2d/demo_map.json"
const MENU_SCENE := "res://ui/main_menu/main_menu.tscn"
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
@onready var hand_scroll: ScrollContainer = $HandScroll
@onready var play_scroll: ScrollContainer = $PlayScroll
@onready var play_cards: Control = %PlayCards
@onready var damage_preview: Control = $DamagePreview
@onready var draw_button: Button = %DrawPileButton
@onready var discard_button: Button = %DiscardPileButton
@onready var draw_pile_count: Label = $DrawPile/Count
@onready var discard_pile_count: Label = $DiscardPile/Count
@onready var cancel_button: Button = %CancelButton
@onready var play_button: Button = %PlayButton
@onready var pile_modal: Control = %PileModal
@onready var pile_title: Label = %PileTitle
@onready var pile_grid: GridContainer = %PileGrid
@onready var play_count_label: Label = $PlayCountLabel
@onready var hand_count_label: Label = $HandCountLabel
@onready var player_hp_fill: Control = $PlayerHPBar/Fill
@onready var player_hp_block: ColorRect = $PlayerHPBar/Block
@onready var player_hp_num: Label = $PlayerHPNum
@onready var enemy_hp_fill: Control = $EnemyHPBar/Fill
@onready var enemy_hp_block: ColorRect = $EnemyHPBar/Block
@onready var enemy_hp_num: Label = $EnemyHPNum
@onready var player_buff_row: HBoxContainer = $PlayerBuffRow
@onready var enemy_buff_row: HBoxContainer = $EnemyBuffRow

var _battle: BattleStateMachine
var _resolver: BattleEffectResolver
var _relics: RelicBattleSystem
var _relic_board := RelicBoard.new()
var _relic_catalog: Dictionary = {}
var _relic_book: RelicBookView
var _relic_log: Label
var _relic_events: Array[String] = []
var _fan_target: Control
var _fan_tween: Tween
var _hand_dragging := false
var _hand_drag_origin := 0.0
var _battle_result := ""
var _buff_icon_cache: Dictionary = {}
var _buff_text_by_id: Dictionary = {}
var _buff_tip: PanelContainer
var _buff_tip_label: Label
var player_block_shield: Control
var enemy_block_shield: Control
var _run_menu: RunMenuOverlay
var _settings_button: SettingsButton
var _menu_run: RunStateMachine
var _map_page_source: Control
var _selected_ids: Array[String] = []
var _selected_cards: Array[Dictionary] = []
var _discard_selection_ids: Array[String] = []
var _pending_discard_count := 0
var _pending_discard_card_id := ""
var _resolution_events: Array[Dictionary] = []
var _display_pointer_id := ""
var _settle_pointer: TextureRect
var _pointer_tween: Tween
var _resolve_preview: Control
var _resolve_view: CardView
var _peek_layer: Control
var _peek_view: CardView
var _busy := false
var _animating := false
var _refresh_queued := false
## 血量变化要能看见：记上一次的血量，差值用来飘伤害/治疗数字。
## 表现层：飘字、闪红、震动、特效，只吃战斗事件。
var _feedback: Node
## 出牌列上一次的行数，只在新增时播放入场，刷新时不会整列重放。
var _play_rows_shown := 0
var _play_insert_index := -1
var _drag_card_id := ""
var _drag_source := ""
var _drag_start := Vector2.ZERO
var _drag_active := false
var _drag_ghost: Control
var _drop_hint: Panel
var _turn_pop_text := ""
## 飞书资产 UI-012「结算指针」：黑三角金边，从左往右指。
const POINTER_TEXTURE := preload("res://assets/ui/UI-012/UI-012-银.png")
const RESOLVE_PREVIEW_POS := Vector2(1440.0, 250.0)
const RESOLVE_PREVIEW_SCALE := 0.5
## 结算节奏：指针滑行按距离配速，大图出现后停一下再结算，让玩家看清发生了什么。
const POINTER_GLIDE_SPEED := 1700.0
const POINTER_GLIDE_MIN := 0.14
const POINTER_GLIDE_MAX := 0.38
const PREVIEW_HOLD := 0.5
const PLAY_PLACEHOLDER_ALPHA := 0.55
const PEEK_CARD_SCALE := 0.79
const ENEMY_FLOAT_ANCHOR := Vector2(998.0, 330.0)
const PLAYER_FLOAT_ANCHOR := Vector2(300.0, 118.0)


func _ready() -> void:
	draw_button.pressed.connect(_on_draw_pile_pressed)
	discard_button.pressed.connect(_on_discard_pile_pressed)
	cancel_button.pressed.connect(_on_cancel_pressed)
	play_button.pressed.connect(_on_play_pressed)
	_run_menu = RUN_MENU.new()
	_run_menu.name = "RunMenuOverlay"
	add_child(_run_menu)
	$PlayerPortrait.gui_input.connect(_on_player_portrait_input)
	# 冒险菜单设置页的三个动作：战斗里也能存档、回主菜单、退出。
	_run_menu.abandon_requested.connect(_on_menu_abandon)
	_run_menu.return_to_menu_requested.connect(_on_menu_return)
	_run_menu.quit_requested.connect(_on_menu_quit)
	# 背包页里装配过典籍，书页要跟着变。
	_run_menu.relic_board_updated.connect(_on_relic_board_updated)
	_build_settings_button()
	hand_scroll.gui_input.connect(_on_hand_scroll_input)
	%ClosePileButton.pressed.connect(_close_pile_modal)
	%PileModalShade.gui_input.connect(_on_modal_shade_input)
	_bind_menu_run()
	_style_backpack_slots()
	_build_block_shields()
	_build_buff_tip()
	_build_relic_hud()
	_build_resolve_preview()
	_build_settle_pointer()
	_build_peek()
	_build_feedback()
	_start_test_battle()
	_refresh_coin()


func _build_feedback() -> void:
	_feedback = FEEDBACK_SCRIPT.new()
	_feedback.name = "CombatFeedback"
	add_child(_feedback)
	_feedback.setup(self, $PlayerPortrait, $EnemyPortrait,
		PLAYER_FLOAT_ANCHOR, ENEMY_FLOAT_ANCHOR)


func _bind_menu_run() -> void:
	# 战斗测试没有 GlobalState 跑图时，背包仍要能看到本场测试牌组。
	var global := get_node_or_null("/root/GlobalState") as GlobalStateMachine
	if global != null and global.current_run != null:
		return
	_menu_run = RunStateMachine.new()
	_menu_run.name = "BattleMenuRun"
	_menu_run.active = true
	_menu_run.max_health = 100
	_menu_run.health = 60
	_menu_run.gold = 128
	_menu_run.deck.assign(TEST_DECK_CARD_IDS)
	_menu_run.items.assign(["治疗药水", "力量药水", "格挡药剂", "干净绷带", "铜币袋", "火把", "面包"])
	add_child(_menu_run)
	_run_menu.set_run_override(_menu_run)


func _refresh_coin() -> void:
	var run: RunStateMachine = _menu_run
	var gateway := get_node_or_null("/root/SaveGateway")
	if gateway != null and gateway.current_run() != null:
		run = gateway.current_run()
	$Coin/Count.text = str(run.gold) if run != null else "0"
	$Elixir/Count.text = str(run.elixir) if run != null else "0"


func _start_test_battle() -> void:
	if SeedService.get_main_seed().is_empty():
		SeedService.begin_run("battle-effects-ui-test")

	_battle = BattleStateMachine.new()
	_battle.name = "BattleStateMachine"
	add_child(_battle)
	_battle.turn_started.connect(_on_turn_started)
	_battle.card_resolved.connect(_on_card_resolved)
	_battle.combatant_damaged.connect(_on_combatant_damaged)
	_battle.combatant_healed.connect(_on_combatant_healed)
	_battle.block_changed.connect(_on_block_changed)
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


func _build_settings_button() -> void:
	_settings_button = SETTINGS_BUTTON.new()
	_settings_button.name = "SettingsButton"
	_settings_button.position = Vector2(1848, 32)
	_settings_button.size = Vector2(48, 48)
	_settings_button.pressed.connect(func() -> void: _open_run_menu(2))
	add_child(_settings_button)
	# 齿轮压在背包和菜单浮层下面：弹层打开时不该露出入口。
	move_child(_settings_button, pile_modal.get_index())


func _build_relic_hud() -> void:
	# 美术稿里的典籍书：左上角，140×181，4×5 残片格。
	_relic_book = RelicBookView.new()
	_relic_book.name = "RelicBook"
	_relic_book.position = RELIC_BOOK_POSITION
	add_child(_relic_book)
	# 书在主角立绘后面，避免盖住人物。
	move_child(_relic_book, $HeroPortrait.get_index())

	# 残片格是斜的四边形，没有 Control 可当锚点，浮层单独一个。
	_relic_book.attach_tip(self, 120)

	_relic_log = Label.new()
	_relic_log.position = RELIC_BOOK_POSITION + Vector2(0, RelicBookView.BOOK_SIZE.y + 8.0)
	_relic_log.size = RELIC_LOG_SIZE
	_relic_log.text = "尚未配置残片。"
	_relic_log.add_theme_font_size_override("font_size", 16)
	_relic_log.add_theme_color_override("font_color", Color(0.749, 0.682, 0.553))
	_relic_log.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_relic_log.clip_text = true
	_relic_log.visible = false
	add_child(_relic_log)
	move_child(_relic_log, pile_modal.get_index())


func _build_block_shields() -> void:
	# 格挡不再用「格挡 N」文字，改在血条尾端盖一枚盾，盾面写数字。
	# 盾的大小按各自血条的高度走：Boss 条比玩家条高，盾和数字一起放大。
	var script := load(BLOCK_SHIELD_SCRIPT)
	player_block_shield = script.new()
	player_block_shield.name = "PlayerBlockShield"
	player_block_shield.position = Vector2(362, 28)
	player_block_shield.size = Vector2(58, 64)
	player_block_shield.set("number_px", 19)
	add_child(player_block_shield)
	enemy_block_shield = script.new()
	enemy_block_shield.name = "EnemyBlockShield"
	enemy_block_shield.position = Vector2(1344, 84)
	enemy_block_shield.size = Vector2(74, 82)
	enemy_block_shield.z_index = 13
	enemy_block_shield.set("number_px", 24)
	add_child(enemy_block_shield)


func _style_backpack_slots() -> void:
	# 和背包页同一套格子：深色底板 + UI-004 边框，只是 HUD 里更小。
	var slot_a := _atlas_texture("res://assets/ui/UI-004/物品边框1.png", Rect2(34, 28, 665, 665))
	var slot_b := _atlas_texture("res://assets/ui/UI-004/物品边框2.png", Rect2(12, 7, 708, 686))
	var index := 0
	for child: Node in $BackpackSlots.get_children():
		if not child is Panel:
			continue
		var panel := child as Panel
		var plate := StyleBoxFlat.new()
		plate.bg_color = Color(0.135, 0.112, 0.088, 0.95)
		plate.border_color = Color(0.910, 0.706, 0.333, 0.20)
		plate.set_border_width_all(1)
		plate.set_corner_radius_all(3)
		panel.add_theme_stylebox_override("panel", plate)
		var frame := Panel.new()
		frame.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var style := StyleBoxTexture.new()
		style.texture = slot_b if index % 2 == 1 else slot_a
		frame.add_theme_stylebox_override("panel", style)
		panel.add_child(frame)
		index += 1
	_refresh_backpack()


func _refresh_backpack() -> void:
	# 战斗里这排格子只是背包页那 21 格的快捷栏，读的是同一份 run.items。
	for child: Node in $BackpackSlots.get_children():
		if not child is Panel:
			continue
		for extra: Node in child.get_children():
			if String(extra.name).begins_with("ItemIcon") or String(extra.name).begins_with("ItemName"):
				child.remove_child(extra)
				extra.queue_free()
	var items: Array = _menu_run.items if _menu_run != null else []
	var slots := $BackpackSlots.get_children()
	for index in mini(items.size(), slots.size()):
		var item: Variant = items[index]
		var text := ""
		if item is Dictionary:
			text = str(item.get("name", item.get("item_id", "")))
			if text.is_empty():
				text = str(item.get("item_id", ""))
		else:
			text = str(item)
		if text.is_empty():
			continue
		var record := _item_record(text, text)
		var icon_script := load(ITEM_ICON_SCRIPT)
		var icon: Control = icon_script.make(str(record.get("icon_path", "")), 26.0)
		icon.name = "ItemIcon"
		icon.position = Vector2(6, 6)
		(slots[index] as Control).add_child(icon)
		var slot_control := slots[index] as Control
		slot_control.mouse_filter = Control.MOUSE_FILTER_STOP
		var tip := _item_tooltip(text, record)
		slot_control.mouse_entered.connect(_show_buff_tip.bind(slot_control, tip))
		slot_control.mouse_exited.connect(_hide_buff_tip)



func _item_record(item_id: String, display: String = "") -> Dictionary:
	var catalog := get_node_or_null("/root/TextCatalog")
	if catalog == null:
		return {}
	var record: Dictionary = catalog.entry("items", item_id)
	if record.is_empty() and not display.is_empty():
		# 物品表按名称兜底：战斗里的 items 可能只带显示名。
		for entry: Dictionary in catalog.entries("items"):
			if str(entry.get("name", "")) == display:
				return entry
	return record


func _item_tooltip(item_id: String, record: Dictionary) -> String:
	var display := str(record.get("name", item_id))
	var effect := str(record.get("effect", ""))
	return display if effect.is_empty() else "%s\n%s" % [display, effect]


func _add_slot_icon(slot_index: int, path: String) -> void:
	var slot := $BackpackSlots.get_child(slot_index) as Control
	if slot == null:
		return
	var icon := TextureRect.new()
	icon.texture = _atlas_texture(path, Rect2(97, 95, 859, 1108))
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.position = Vector2(7, 3)
	icon.size = Vector2(24, 31)
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	slot.add_child(icon)


func _atlas_texture(path: String, region: Rect2) -> AtlasTexture:
	var atlas := AtlasTexture.new()
	atlas.atlas = load(path)
	atlas.region = region
	return atlas


func _refresh_relic_hud() -> void:
	if _relic_book != null:
		_relic_book.set_board(_relic_catalog, _relic_board)


## 背包页装配过典籍：就地重读棋盘，再刷书页。
## 实例不能换 —— RelicBattleSystem 拿着同一个 board 做邻接结算。
func _on_relic_board_updated() -> void:
	if _relic_board == null:
		return
	_relic_board.load_from_file(_relic_catalog, relic_board_path)
	_refresh_relic_hud()


func _on_relic_activated(trigger: int, effect: int, description: String) -> void:
	_relic_events.append("[%d→%d] %s" % [trigger + 1, effect + 1, description])
	if _relic_events.size() > 4:
		_relic_events.pop_front()
	_relic_log.text = "\n".join(_relic_events)
	if _relic_book != null:
		_relic_book.flash_cell(trigger)
		_relic_book.flash_cell(effect)


func _on_relic_chain_limited() -> void:
	_relic_log.text += "\n本条连锁已达到安全上限。"


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


func _on_combatant_damaged(side: StringName, _entity_id: String, damage: int,
		blocked: int, _health_after: int) -> void:
	_feedback.on_damaged(side, damage, blocked)


func _on_combatant_healed(side: StringName, _entity_id: String, amount: int,
		_health_after: int) -> void:
	_feedback.on_healed(side, amount)


func _on_block_changed(side: StringName, _entity_id: String, block: int) -> void:
	_feedback.on_block_changed(side, block)


func _on_discard_choice_requested(card: Dictionary, count: int,
		_candidates: Array[Dictionary]) -> void:
	_pending_discard_count = count
	_pending_discard_card_id = String(card.get("instance_id", ""))
	_discard_selection_ids.clear()
	_queue_refresh()


func _on_hand_card_pressed(instance_id: String) -> void:
	if not _battle.active:
		hint_label.text = "战斗已结束。"
		return
	if _pending_discard_count > 0:
		_select_card_to_discard(instance_id)
		return
	if _battle.phase != BattleStateMachine.Phase.PLAYER_ACTION:
		hint_label.text = "当前结算未完成，请完成弃牌选择。"
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
	hint_label.text = ""
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
	hint_label.text = ""
	_queue_refresh()


func _on_play_pressed() -> void:
	if _busy or not _battle.active or _selected_ids.is_empty():
		return
	_busy = true
	_resolution_events.clear()
	hint_label.text = ""
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
		phase_label.text = "玩家回合 · 指针位置 %d" % (int(event["pointer"]) + 1)
		hint_label.text = ""
		await _move_pointer_to(instance_id)
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
		hint_label.text = "战斗结束。"
		_queue_refresh()
		return

	_set_pointer("")
	phase_label.text = "怪物回合"
	hint_label.text = ""
	_refresh_combat_status()
	await get_tree().create_timer(enemy_turn_delay).timeout

	_selected_ids.clear()
	_selected_cards.clear()
	_busy = false
	_animating = false
	hint_label.text = ""
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
		var slot := _make_card_slot(card, PILE_CARD_SCALE, false)
		var card_id := String(card.get("card_id", ""))
		if not card_id.is_empty():
			var peek := Button.new()
			peek.flat = true
			peek.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
			peek.tooltip_text = ""
			peek.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
			peek.pressed.connect(_peek_card.bind(card_id))
			slot.add_child(peek)
		pile_grid.add_child(slot)
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


## —— 手牌拖拽：自己记按下 / 移动 / 松开，不依赖 Control 的 GUI 拖放 ——
## GUI 拖放在 ScrollContainer 里会先被滚动吞掉，表现是「怎么拖都没反应」。

func _input(event: InputEvent) -> void:
	if _busy or _battle == null or not _battle.active:
		return
	# 菜单开着的时候外面一律不接输入。浮层那层遮罩只挡得住 _gui_input，
	# 牌桌拖拽走的是 _input，不在这儿拦住就会隔着菜单把外面的手牌抓走。
	if _run_menu != null and _run_menu.is_open():
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			# 手牌可以拖进出牌列，出牌列里的牌可以拖动改顺序。
			_drag_card_id = _hand_card_at(event.position)
			_drag_source = "hand" if not _drag_card_id.is_empty() else ""
			if _drag_card_id.is_empty():
				_drag_card_id = _play_card_at(event.position)
				_drag_source = "play" if not _drag_card_id.is_empty() else ""
			_drag_start = event.position
			_drag_active = false
			return
		if _drag_active:
			var dragged := _drag_card_id
			var source := _drag_source
			var index := _play_drop_index(event.position)
			_finish_drag()
			if source == "play":
				_move_play_card(_selected_ids.find(dragged), index)
			elif not dragged.is_empty():
				_insert_selected_card(dragged, index)
			get_viewport().set_input_as_handled()
		_drag_card_id = ""
		_drag_source = ""
		return
	if event is InputEventMouseMotion and not _drag_card_id.is_empty():
		if not _drag_active:
			if event.position.distance_to(_drag_start) < 8.0:
				return
			_begin_drag()
		_move_drag_ghost(event.position)
		_update_drop_hint(event.position)
		_update_drag_preview(event.position)


func _on_play_card_hover(slot: Control, entered: bool, instance_id := "") -> void:
	# 拖拽期间不响应悬停：手里还抓着牌时不该有大图跟着鼠标跳。
	if not is_instance_valid(slot) or _drag_active:
		return
	slot.modulate = Color(1.18, 1.18, 1.18) if entered else Color.WHITE
	if entered:
		var card := _find_selected_card(instance_id)
		if not card.is_empty():
			_show_resolve_preview(String(card.get("card_id", "")))
	elif not _busy:
		_resolve_preview.visible = false
	else:
		# 结算中把大图交还给指针，避免悬停移开后结算大图消失。
		_refresh_resolve_preview(_display_pointer_id)


func _play_card_at(at: Vector2) -> String:
	# 出牌列是叠放的：一张牌真正露出来的只有 PLAY_STEP 高的一条，
	# 所以从后往前按可见带命中，最上面那张优先。
	var rows := play_cards.get_children()
	for index in range(rows.size() - 1, -1, -1):
		var row := rows[index] as Control
		var band := Rect2(row.global_position, Vector2(PLAY_ROW_SIZE.x, PLAY_STEP))
		if band.has_point(at):
			return String(row.get_meta("instance_id", ""))
	if rows.is_empty():
		return ""
	var last := rows[rows.size() - 1] as Control
	var full := Rect2(last.global_position,
		Vector2(PLAY_ROW_SIZE.x, PLAY_CARD_SIZE.y))
	if full.has_point(at):
		return String(last.get_meta("instance_id", ""))
	return ""


func _set_drag_source_alpha(instance_id: String, alpha: float) -> void:
	# 拖出处的牌压成半透明虚影：手牌槽位和出牌列槽位都要管。
	if instance_id.is_empty():
		return
	for slot: Node in hand_cards.get_children():
		if slot is CanvasItem and String(slot.get_meta("instance_id", "")) == instance_id:
			(slot as CanvasItem).modulate.a = alpha
	# 出牌列整行一起压：只压卡槽会被悬停提亮盖掉，看着就没有虚影。
	var index := _play_row_index(instance_id)
	if index >= 0:
		var row := play_cards.get_child(index) as CanvasItem
		if row != null:
			row.modulate.a = alpha


func _move_play_card(from_index: int, insert_index: int) -> void:
	if from_index < 0 or from_index >= _selected_cards.size():
		return
	var at := insert_index
	if at > from_index:
		at -= 1
	at = clampi(at, 0, _selected_cards.size() - 1)
	if at == from_index:
		return
	_selected_cards.insert(at, _selected_cards.pop_at(from_index))
	_selected_ids.insert(at, _selected_ids.pop_at(from_index))
	_play_insert_index = at
	hint_label.text = ""
	_queue_refresh()


func _card_by_instance(instance_id: String) -> Dictionary:
	var card := _find_hand_card(instance_id)
	if not card.is_empty():
		return card
	var at := _selected_ids.find(instance_id)
	if at >= 0 and at < _selected_cards.size():
		return _selected_cards[at]
	return {}


func _hand_card_at(at: Vector2) -> String:
	for slot: Node in hand_cards.get_children():
		if not slot is Control:
			continue
		if (slot as Control).get_global_rect().has_point(at):
			return String(slot.get_meta("instance_id", ""))
	return ""


func _begin_drag() -> void:
	_drag_active = true
	# 原位留半透明虚影：手牌和出牌列都一样，手上那一张是实体。
	_set_drag_source_alpha(_drag_card_id, PLAY_PLACEHOLDER_ALPHA)
	var card := _card_by_instance(_drag_card_id)
	if card.is_empty():
		return
	if _drag_ghost == null:
		_drag_ghost = Control.new()
		_drag_ghost.name = "HandDragGhost"
		_drag_ghost.z_index = 90
		_drag_ghost.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_drag_ghost.size = PLAY_CARD_SIZE
		add_child(_drag_ghost)
	_drag_ghost.visible = true
	_drag_ghost.modulate.a = 1.0
	for child in _drag_ghost.get_children():
		child.queue_free()
	var view: CardView = CARD_SCENE.instantiate()
	view.scale = Vector2.ONE * PLAY_CARD_SCALE
	view.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_drag_ghost.add_child(view)
	var data := _card_data(String(card.get("card_id", "")))
	if data != null:
		view.set_card(data)
	var drag_px := CardView.text_px_for(PLAY_CARD_SCALE)
	view.apply_compact_layout(PLAY_CARD_SCALE, drag_px.x, drag_px.y)


func _move_drag_ghost(at: Vector2) -> void:
	if _drag_ghost != null and _drag_ghost.visible:
		_drag_ghost.position = at - PLAY_CARD_SIZE * 0.5


func _update_drop_hint(at: Vector2) -> void:
	if _drop_hint == null:
		_drop_hint = Panel.new()
		_drop_hint.name = "DropHint"
		_drop_hint.z_index = 88
		_drop_hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var style := StyleBoxFlat.new()
		style.bg_color = Color(1.0, 0.85, 0.45, 0.95)
		style.set_corner_radius_all(2)
		_drop_hint.add_theme_stylebox_override("panel", style)
		add_child(_drop_hint)
	var inside := _play_area_rect().has_point(at)
	_drop_hint.visible = inside
	if not inside:
		return
	var index := _play_drop_index(at)
	var y := play_cards.global_position.y + float(index) * PLAY_STEP - 2.0
	_drop_hint.size = Vector2(PLAY_CARD_SIZE.x, 4.0)
	_drop_hint.position = Vector2(play_cards.global_position.x + PLAY_POINTER_W, y)


func _finish_drag() -> void:
	_drag_active = false
	_set_drag_source_alpha(_drag_card_id, 1.0)
	if not _busy and _resolve_preview != null:
		_resolve_preview.visible = false
	if _drag_ghost != null:
		_drag_ghost.visible = false
	if _drop_hint != null:
		_drop_hint.visible = false


func _update_drag_preview(at: Vector2) -> void:
	# 拖动出牌列的牌时，左侧大图改成「松手后会压在谁的下面就显示谁」：
	# 拖到最顶上是自己，往下压住哪张就显示哪张，和结算指针用的是同一张大图。
	if _resolve_preview == null:
		return
	if _drag_source == "hand":
		# 手牌拖到出牌区上方时，同样在左侧显示「松手会插在这一格之前」的那张牌：
		# 插入位置 index 上原本的牌会被顶下去，所以显示 _selected_ids[index]。
		if not _play_area_rect().has_point(at):
			if _resolve_preview != null:
				_resolve_preview.visible = false
			return
		var drop := _play_drop_index(at)
		if drop < _selected_ids.size():
			var under := _find_selected_card(String(_selected_ids[drop]))
			if not under.is_empty():
				_show_resolve_preview(String(under.get("card_id", "")))
		return
	if _drag_source != "play":
		return
	var index := _play_drop_index(at)
	var show_id := _drag_card_id
	if index >= 1 and index <= _selected_ids.size():
		var under := String(_selected_ids[clampi(index - 1, 0, _selected_ids.size() - 1)])
		if under != _drag_card_id:
			show_id = under
	var card := _find_selected_card(show_id)
	if card.is_empty():
		return
	_show_resolve_preview(String(card.get("card_id", "")))


func _play_area_rect() -> Rect2:
	return play_scroll.get_global_rect()


func _play_drop_index(at: Vector2) -> int:
	# 单列：鼠标落在第几格就插到第几格之前。
	var origin := play_cards.global_position
	var index := int(roundf((at.y - origin.y) / PLAY_STEP))
	return clampi(index, 0, _selected_cards.size())


func _insert_selected_card(instance_id: String, index: int) -> void:
	if instance_id.is_empty() or _selected_ids.has(instance_id):
		return
	var card := _find_hand_card(instance_id)
	if card.is_empty() or _selected_cards.size() >= play_limit:
		return
	var at := clampi(index, 0, _selected_cards.size())
	_selected_cards.insert(at, card)
	_selected_ids.insert(at, instance_id)
	_play_insert_index = at
	hint_label.text = ""
	_queue_refresh()


func _on_play_card_pressed(instance_id: String) -> void:
	if _busy or not _battle.active:
		return
	if not _selected_ids.has(instance_id):
		return
	var at := _selected_ids.find(instance_id)
	_selected_ids.remove_at(at)
	_selected_cards.remove_at(at)
	hint_label.text = ""
	_queue_refresh()


func _find_hand_card(instance_id: String) -> Dictionary:
	if _battle == null:
		return {}
	for card: Dictionary in _battle.hand:
		if String(card.get("instance_id", "")) == instance_id:
			return card
	return {}


func _refresh_zones() -> void:
	_refresh_queued = false
	_refresh_damage_preview()
	var insert_at := _play_insert_index
	_play_insert_index = -1
	_clear_children(hand_cards)
	_clear_children(play_cards)

	var hand_slots: Array[Control] = []
	for card: Dictionary in _battle.hand:
		var instance_id := String(card["instance_id"])
		if not _selected_ids.has(instance_id) and not _discard_selection_ids.has(instance_id):
			var slot := _make_card_slot(card, HAND_CARD_SCALE, true)
			hand_cards.add_child(slot)
			hand_slots.append(slot)
	_layout_hand(hand_slots)

	# 出牌列向上叠：后出的牌压在前一张上沿，每张露出卡图与卡名（约 160px），
	# 最新一张完整显示在列底。z 递增，滚到列底对齐最新一张。
	for index in _selected_cards.size():
		var row: Control = _make_play_row(_selected_cards[index])
		row.z_index = index + 1
		play_cards.add_child(row)
	_layout_play_rows()
	_animate_play_insert(insert_at)
	_animate_new_play_row(_selected_cards.size())
	call_deferred("_scroll_play_to_latest")
	hand_count_label.text = "%d/%d" % [hand_slots.size(), HAND_SLOT_COUNT]
	_set_pointer(_display_pointer_id)

	_refresh_header()
	_refresh_combat_status()


func _animate_play_insert(index: int) -> void:
	if index < 0:
		return
	# 插入点之后的牌先让出一格，再滑回位，形成"让位"手感。
	for i in range(index + 1, play_cards.get_child_count()):
		var row := play_cards.get_child(i) as Control
		if row == null:
			continue
		var target := row.position
		row.position = target - Vector2(0.0, PLAY_STEP)
		var tween := row.create_tween()
		tween.tween_property(row, "position", target, 0.16) \
			.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)


func _scroll_play_to_latest() -> void:
	await get_tree().process_frame
	play_scroll.scroll_vertical = 1_000_000


func _animate_new_play_row(count: int) -> void:
	# 只有"又出了一张"才播入场：清空重排、结算刷新都不重放。
	if count <= _play_rows_shown:
		_play_rows_shown = count
		return
	_play_rows_shown = count
	var row := play_cards.get_child(count - 1) as Control
	if row == null:
		return
	row.modulate.a = 0.0
	row.scale = Vector2(0.9, 0.9)
	var tween := row.create_tween()
	tween.set_parallel(true)
	tween.tween_property(row, "modulate:a", 1.0, 0.16)
	tween.tween_property(row, "scale", Vector2.ONE, 0.2) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


func _refresh_header() -> void:
	if _battle == null:
		return
	var turn_text := "回合 %d" % _battle.turn_number
	if turn_text != _turn_pop_text:
		_turn_pop_text = turn_text
		turn_label.text = turn_text
		_pop_turn_label()
	else:
		turn_label.text = turn_text
	if not _battle.active:
		phase_label.text = "战斗胜利" if _battle.phase == BattleStateMachine.Phase.VICTORY else "战斗结束"
		if not _busy:
			hint_label.text = "战斗%s。" % ("胜利" if _battle_result == "victory" else "结束")
	elif not _busy:
		phase_label.text = "玩家回合 · 编排阶段"
	count_label.text = "首抽 %d  |  每回合抽 %d  |  出牌上限 %d" % [
		initial_draw_count, per_turn_draw_count, play_limit,
	]
	draw_pile_count.text = str(_battle.draw_pile.size())
	discard_pile_count.text = str(_battle.discard_pile.size())
	draw_button.disabled = _busy
	discard_button.disabled = _busy
	cancel_button.disabled = _busy or _selected_ids.is_empty()
	play_button.disabled = _busy or not _battle.active or _selected_ids.is_empty() \
		or _battle.phase != BattleStateMachine.Phase.PLAYER_ACTION
	play_button.text = "结算 %d" % _selected_ids.size()
	play_count_label.text = "%d/%d" % [_selected_ids.size(), play_limit]
	var can_click := _can_click_hand()
	for slot: Node in hand_cards.get_children():
		var view := slot.get_child(0) as CardView
		if view != null:
			# 不可出牌时整张卡压暗，照杀戮尖塔的可用/不可用区分。
			view.modulate = Color(1, 1, 1) if can_click else Color(0.58, 0.58, 0.58)
		var button := slot.get_child(1) as Button
		if button != null:
			button.disabled = not can_click


func _pop_turn_label() -> void:
	# 回合数变化时轻轻弹一下，让"换回合了"这件事有反馈。
	turn_label.pivot_offset = turn_label.size * 0.5
	turn_label.scale = Vector2(1.18, 1.18)
	turn_label.modulate = Color(1.0, 0.92, 0.72)
	var tween := turn_label.create_tween()
	tween.set_parallel(true)
	tween.tween_property(turn_label, "scale", Vector2.ONE, 0.24) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tween.tween_property(turn_label, "modulate", Color.WHITE, 0.3)


## 调试用：给怪物挂一层常驻格挡，方便在编辑器里看盾的位置。改成 0 即可关掉。
const DEBUG_ENEMY_BLOCK := 10


func _refresh_combat_status() -> void:
	if _battle == null or _battle.enemies.is_empty():
		return
	if DEBUG_ENEMY_BLOCK > 0 and int(_battle.enemies[0].get("block", 0)) == 0:
		_battle.enemies[0]["block"] = DEBUG_ENEMY_BLOCK
	_render_combat_snapshot(_battle.player, _battle.enemies[0])


func _render_combat_snapshot(player_data: Dictionary, enemy_data: Dictionary) -> void:
	_render_health(player_hp_fill, player_hp_block, player_hp_num, player_data,
		PLAYER_BAR_LEFT, PLAYER_BAR_WIDTH, &"player")
	_render_health(enemy_hp_fill, enemy_hp_block, enemy_hp_num, enemy_data,
		ENEMY_BAR_LEFT, ENEMY_BAR_WIDTH, &"enemy")
	_render_buffs(player_buff_row, player_data.get("buffs", []), 1.0)
	_render_buffs(enemy_buff_row, enemy_data.get("buffs", []), 1.0)
	player_status.text = "玩家  HP %d/%d  格挡 %d\nBuff：%s" % [
		int(player_data.get("health", 0)), int(player_data.get("max_health", 0)),
		int(player_data.get("block", 0)), _format_buffs(player_data.get("buffs", [])),
	]
	enemy_status.text = "CHR-025  HP %d/%d  格挡 %d\nBuff：%s" % [
		int(enemy_data.get("health", 0)), int(enemy_data.get("max_health", 0)),
		int(enemy_data.get("block", 0)), _format_buffs(enemy_data.get("buffs", [])),
	]


func _render_block_shield(side: StringName, block_layers: int) -> void:
	# 玩家的盾挂在玩家血条右端，敌人的挂在敌人血条右端。
	var shield: Control = player_block_shield if side == &"player" else enemy_block_shield
	if shield != null:
		shield.set("value", block_layers)


func _render_health(fill: Control, block: ColorRect, number: Label,
		data: Dictionary, left: float, bar_width: float, side: StringName) -> void:
	var health := int(data.get("health", 0))
	var max_health := maxi(int(data.get("max_health", 1)), 1)
	var block_layers := int(data.get("block", 0))
	var ratio := clampf(float(health) / float(max_health), 0.0, 1.0)
	# 条内左端起算：填充从金框内侧左端向右长，格挡段接在填充右端。
	# 右端斜切交给 HealthFill 自己画，格挡段跟着斜切量右移，贴住填充末端。
	fill.offset_left = left
	fill.offset_right = left + bar_width
	fill.set("ratio", ratio)
	var slant := float(fill.get("slant")) if fill.get("slant") != null else 0.0
	var fill_right := left + bar_width * ratio + slant * ratio
	var previous := float(fill.get_meta("ratio", ratio))
	fill.set_meta("ratio", ratio)
	if is_inside_tree() and absf(previous - ratio) > 0.001:
		# 血条不瞬移：短补间滑到新长度，格挡段跟着走，眼睛能追到掉了多少。
		var tween := create_tween()
		tween.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		tween.set_parallel(true)
		tween.tween_property(fill, "ratio", ratio, 0.3)
		tween.tween_property(block, "offset_left", fill_right, 0.3)
		tween.tween_property(block, "offset_right",
			minf(fill_right + BLOCK_MARKER_WIDTH, left + bar_width + slant), 0.3)
		fill.set_meta("tween", tween)
	else:
		block.offset_left = fill_right
		block.offset_right = minf(fill_right + BLOCK_MARKER_WIDTH, left + bar_width + slant)
	block.visible = false
	_render_block_shield(side, block_layers)
	number.text = "%d/%d" % [health, max_health]


func _render_buffs(row: HBoxContainer, buffs: Array, chip_scale := 1.0) -> void:
	_hide_buff_tip()
	_clear_children(row)
	for buff: Dictionary in buffs:
		var buff_id := String(buff.get("buff_id", ""))
		var debuff := buff_id in ["poison", "weak"]
		var layers := int(buff.get("layers", 0))
		var chip := Control.new()
		chip.custom_minimum_size = Vector2(36, 32) * chip_scale
		chip.mouse_filter = Control.MOUSE_FILTER_STOP
		# 悬停能看到这是什么、有什么用。自己画浮层，不用系统 tooltip。
		var tip_text := _buff_tooltip(buff_id, layers)
		chip.mouse_entered.connect(_show_buff_tip.bind(chip, tip_text))
		chip.mouse_exited.connect(_hide_buff_tip)
		var plate := Panel.new()
		plate.position = Vector2.ZERO
		plate.size = Vector2(32, 32) * chip_scale
		var plate_style := StyleBoxFlat.new()
		plate_style.bg_color = Color(0.08, 0.06, 0.05, 0.72)
		plate_style.set_corner_radius_all(6)
		plate_style.set_border_width_all(1)
		plate_style.border_color = Color(0.62, 0.5, 0.3, 0.55)
		plate.add_theme_stylebox_override("panel", plate_style)
		plate.mouse_filter = Control.MOUSE_FILTER_IGNORE
		chip.add_child(plate)
		var icon := TextureRect.new()
		icon.texture = _buff_icon(buff_id)
		icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon.position = Vector2(2, 2) * chip_scale
		icon.size = Vector2(28, 28) * chip_scale
		icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		chip.add_child(icon)
		var value := Label.new()
		value.text = str(layers)
		value.position = Vector2(15, 12) * chip_scale
		value.size = Vector2(16, 18) * chip_scale
		if icon.texture == null:
			# 没配图标的 buff：数字居中顶格显示，别留个空底板。
			value.position = Vector2.ZERO
			value.size = Vector2(32, 32) * chip_scale
			value.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			value.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		else:
			value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		value.add_theme_font_size_override("font_size", maxi(11, int(round(14.0 * chip_scale))))
		value.add_theme_color_override("font_color",
			Color(0.81, 0.89, 0.66) if debuff else Color(0.949, 0.89, 0.776))
		value.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.9))
		value.add_theme_constant_override("shadow_offset_x", 1)
		value.add_theme_constant_override("shadow_offset_y", 1)
		value.mouse_filter = Control.MOUSE_FILTER_IGNORE
		chip.add_child(value)
		row.add_child(chip)


func _build_buff_tip() -> void:
	# 和背包页共用同一个浮层组件。
	var tip_script := load(HOVER_TIP_SCRIPT)
	_buff_tip = tip_script.new()
	_buff_tip.name = "BuffTip"
	_buff_tip.z_index = 80
	add_child(_buff_tip)


func _show_buff_tip(anchor: Control, text: String) -> void:
	if _buff_tip == null or not is_instance_valid(anchor):
		return
	_buff_tip.show_for(anchor, text)


func _hide_buff_tip() -> void:
	if _buff_tip != null:
		_buff_tip.hide_tip()



func _buff_tooltip(buff_id: String, layers: int) -> String:
	var text := _buff_text(buff_id)
	var name := String(text.get("name", buff_id))
	var detail := String(text.get("description", ""))
	if detail.is_empty():
		return "%s ×%d" % [name, layers]
	return "%s ×%d\n%s" % [name, layers, detail]


## buff 的名称与说明只在 data/buffs/*.tres 里写一次，悬停提示从这里读。
func _buff_text(buff_id: String) -> Dictionary:
	if _buff_text_by_id.has(buff_id):
		return _buff_text_by_id[buff_id]
	var dir := DirAccess.open("res://data/buffs")
	if dir == null:
		return {}
	for file in dir.get_files():
		if not file.ends_with(".tres"):
			continue
		var data := load("res://data/buffs/%s" % file) as BuffData
		if data == null:
			continue
		_buff_text_by_id[String(data.buff_id)] = {
			"name": data.display_name,
			"description": data.description,
		}
	return _buff_text_by_id.get(buff_id, {})


func _buff_icon(buff_id: String) -> Texture2D:
	if _buff_icon_cache.has(buff_id):
		return _buff_icon_cache[buff_id]
	var path: String = BUFF_ICON_PATHS.get(buff_id, "")
	if path.is_empty():
		return null
	var atlas := _atlas_texture(path, BUFF_ICON_REGION)
	_buff_icon_cache[buff_id] = atlas
	return atlas


func _can_click_hand() -> bool:
	return _battle != null and _battle.active and (_pending_discard_count > 0 \
		or (not _busy and _battle.phase == BattleStateMachine.Phase.PLAYER_ACTION))


func _make_card_slot(card: Dictionary, card_scale: float, clickable: bool,
		title_px: int = 0, body_px: int = 0) -> Control:
	if title_px <= 0 or body_px <= 0:
		var px := CardView.text_px_for(card_scale)
		title_px = px.x
		body_px = px.y
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
	view.apply_compact_layout(card_scale, title_px, body_px)
	slot.add_child(view)

	if clickable:
		var button := Button.new()
		button.flat = true
		button.disabled = not _can_click_hand()
		button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		button.tooltip_text = ""
		button.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		button.pressed.connect(_on_hand_card_pressed.bind(String(card["instance_id"])))
		button.mouse_entered.connect(_on_hand_card_hover_changed.bind(slot, view, true))
		button.mouse_exited.connect(_on_hand_card_hover_changed.bind(slot, view, false))
		slot.add_child(button)
	return slot


func _layout_hand(slots: Array[Control]) -> void:
	# 手牌按固定步长排在中轴上；扇开时在基准位置上加偏移，基准不随动画漂移。
	var count := slots.size()
	if count == 0:
		hand_cards.custom_minimum_size = Vector2(HAND_AREA_WIDTH, 0.0)
		hand_cards.size = Vector2(HAND_AREA_WIDTH, HAND_AREA_HEIGHT)
		return
	var gap_step := HAND_CARD_SIZE.x + HAND_GAP
	var squeeze := (HAND_MAX_WIDTH - HAND_CARD_SIZE.x) / maxf(float(count - 1), 1.0)
	var step := minf(gap_step, squeeze)
	var total := step * (count - 1) + HAND_CARD_SIZE.x
	var row_width := maxf(total + HAND_HOVER_MARGIN * 2.0, HAND_AREA_WIDTH)
	if _fan_tween != null and _fan_tween.is_valid():
		_fan_tween.kill()
	hand_cards.custom_minimum_size = Vector2(row_width, 0.0)
	hand_cards.size = Vector2(row_width, HAND_AREA_HEIGHT)
	var start := (row_width - total) * 0.5
	var center := (count - 1) * 0.5
	var base_y := HAND_AREA_HEIGHT - HAND_CARD_SIZE.y
	for index in count:
		var slot := slots[index]
		slot.size = HAND_CARD_SIZE
		# 绕底边中点旋转，越靠边角度越大；同时沿弧线略微下沉，形成扇形。
		# 悬停的那张立正（角度归零、不再下沉），否则扇形会把字也转歪。
		var hovered := bool(slot.get_meta("hovered", false))
		var angle := 0.0 if hovered else (index - center) * HAND_ARC_SPREAD
		slot.set_meta("fan_rotation", angle)
		slot.pivot_offset = Vector2(HAND_CARD_SIZE.x * 0.5, HAND_CARD_SIZE.y)
		slot.rotation = angle
		slot.position = Vector2(start + step * index,
			base_y + (1.0 - cos(angle)) * HAND_ARC_RADIUS)
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


func _on_hand_card_hover_changed(slot: Control, view: CardView, expanded: bool) -> void:
	if not is_instance_valid(slot) or not is_instance_valid(view):
		return
	slot.set_meta("hovered", expanded)
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

	# 立正：悬停时把扇形角度收回到 0，离开时回到该位置原本的角度。
	var previous_rotate: Variant = slot.get_meta("hover_rotate_tween") if slot.has_meta("hover_rotate_tween") else null
	if previous_rotate is Tween and previous_rotate.is_valid():
		previous_rotate.kill()
	var target_rotation := 0.0 if expanded else float(slot.get_meta("fan_rotation", 0.0))
	var rotate_tween := slot.create_tween()
	rotate_tween.set_trans(Tween.TRANS_CUBIC)
	rotate_tween.set_ease(Tween.EASE_OUT)
	rotate_tween.tween_property(slot, "rotation", target_rotation,
		hand_hover_duration if expanded else hand_hover_return_duration)
	slot.set_meta("hover_rotate_tween", rotate_tween)
	# A→B 切换时 Godot 先派发 A 的离开、再派发 B 的进入；这里延后一拍统一判定，
	# 避免中途先收扇再展开。
	call_deferred("_refresh_hand_fan")


func _layout_play_rows() -> void:
	# 单列：一列最多 PLAY_ROWS_PER_COLUMN 张，按 PLAY_STEP 向下叠，最新一张在列尾。
	var rows := play_cards.get_children()
	if rows.is_empty():
		play_cards.custom_minimum_size = PLAY_ROW_SIZE
		play_cards.size = PLAY_ROW_SIZE
		return
	var columns := maxi(1, ceili(float(rows.size()) / float(PLAY_ROWS_PER_COLUMN)))
	var per_column := mini(rows.size(), PLAY_ROWS_PER_COLUMN)
	var width := float(columns) * PLAY_ROW_SIZE.x + float(columns - 1) * PLAY_COLUMN_GAP
	var height := float(per_column - 1) * PLAY_STEP + PLAY_CARD_SIZE.y
	play_cards.custom_minimum_size = Vector2(width, height)
	play_cards.size = play_cards.custom_minimum_size
	for index in rows.size():
		var row := rows[index] as Control
		row.size = PLAY_ROW_SIZE
		row.position = Vector2(
			float(index / PLAY_ROWS_PER_COLUMN) * (PLAY_ROW_SIZE.x + PLAY_COLUMN_GAP),
			float(index % PLAY_ROWS_PER_COLUMN) * PLAY_STEP,
		)


func _make_play_row(card: Dictionary) -> Control:
	# 出牌列单列叠放：卡图与卡名都露，向下叠 PLAY_STEP，最新一张在列尾。
	var row := Control.new()
	var card_size := PLAY_CARD_SIZE
	row.custom_minimum_size = PLAY_ROW_SIZE
	row.size = PLAY_ROW_SIZE
	row.set_meta("instance_id", String(card["instance_id"]))
	var slot := _make_card_slot(card, PLAY_CARD_SCALE, false)
	slot.position = Vector2(PLAY_POINTER_W, 0.0)
	row.add_child(slot)

	# 点一下把牌拿回手牌。
	var button := Button.new()
	button.name = "TakeBack"
	button.flat = true
	button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	button.position = Vector2(PLAY_POINTER_W, 0.0)
	button.size = card_size
	button.pressed.connect(_on_play_card_pressed.bind(String(card["instance_id"])))
	# 悬停提亮：出牌区的牌子小，不给点提示很难看出能拖动、能点回。
	button.mouse_entered.connect(_on_play_card_hover.bind(slot, true, String(card["instance_id"])))
	button.mouse_exited.connect(_on_play_card_hover.bind(slot, false, String(card["instance_id"])))
	row.add_child(button)

	var highlight := Panel.new()
	highlight.name = "Highlight"
	highlight.position = Vector2(PLAY_POINTER_W - 2.0, -2.0)
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


func _make_card_backing(card_size: Vector2) -> Panel:
	# 叠放层的不透明底：颜色比卡面暗一档，边缘收在卡框里，只负责挡住下层。
	var backing := Panel.new()
	backing.name = "Backing"
	backing.position = Vector2(2.0, 2.0)
	backing.size = card_size - Vector2(4.0, 4.0)
	backing.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var backing_style := StyleBoxFlat.new()
	backing_style.bg_color = Color(0.07, 0.058, 0.05, 1.0)
	backing_style.set_corner_radius_all(12)
	backing.add_theme_stylebox_override("panel", backing_style)
	return backing


func _build_settle_pointer() -> void:
	# 结算指针做成一个全局节点而不是每行挂一个：这样能在两张牌之间滑过去。
	_settle_pointer = TextureRect.new()
	_settle_pointer.name = "SettlePointer"
	_settle_pointer.texture = POINTER_TEXTURE
	_settle_pointer.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_settle_pointer.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_settle_pointer.size = Vector2(56.0, 46.0)
	_settle_pointer.z_index = 60
	_settle_pointer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_settle_pointer.visible = false
	add_child(_settle_pointer)


func _play_row_index(instance_id: String) -> int:
	for index in play_cards.get_child_count():
		if String(play_cards.get_child(index).get_meta("instance_id", "")) == instance_id:
			return index
	return -1


## 出牌列超过一屏时要滚：指针要指的那张先滚进视野，否则箭头会停在屏幕外。
func _ensure_play_visible(instance_id: String) -> void:
	var index := _play_row_index(instance_id)
	if index < 0:
		return
	var top := float(index * int(PLAY_STEP))
	var view_height := play_scroll.size.y
	var scrolled := float(play_scroll.scroll_vertical)
	if top >= scrolled and top + PLAY_STEP <= scrolled + view_height:
		return
	var lowest := maxf(0.0, play_cards.size.y - view_height)
	var target := clampf(top - PLAY_STEP, 0.0, lowest)
	var tween := create_tween()
	tween.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	tween.tween_property(play_scroll, "scroll_vertical", int(target), 0.18)
	await tween.finished


func _pointer_target(instance_id: String) -> Vector2:
	for row: Node in play_cards.get_children():
		if String(row.get_meta("instance_id", "")) != instance_id:
			continue
		var row_control := row as Control
		return Vector2(row_control.global_position.x - 4.0,
			row_control.global_position.y + PLAY_CARD_SIZE.y * 0.5 - 23.0)
	return Vector2(-400.0, -400.0)


func _place_pointer(instance_id: String, animated: bool) -> void:
	if _settle_pointer == null:
		return
	if instance_id.is_empty():
		_settle_pointer.visible = false
		return
	var target := _pointer_target(instance_id)
	if not animated or not _settle_pointer.visible:
		_settle_pointer.position = target
		_settle_pointer.visible = true
		return
	if _pointer_tween != null and _pointer_tween.is_valid():
		_pointer_tween.kill()
	var duration := clampf(_settle_pointer.position.distance_to(target)
		/ POINTER_GLIDE_SPEED, POINTER_GLIDE_MIN, POINTER_GLIDE_MAX)
	_pointer_tween = create_tween()
	_pointer_tween.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	_pointer_tween.tween_property(_settle_pointer, "position", target, duration)
	await _pointer_tween.finished


func _set_pointer(instance_id: String) -> void:
	# 指针 = 结算到哪张牌：高亮框 + 箭头 + 左侧大图一起跟着走。
	_display_pointer_id = instance_id
	_refresh_pointer_marks(instance_id)
	_place_pointer(instance_id, false)
	_refresh_resolve_preview(instance_id)


func _refresh_pointer_marks(instance_id: String) -> void:
	for row: Node in play_cards.get_children():
		var pointed := instance_id != "" \
			and String(row.get_meta("instance_id", "")) == instance_id
		var highlight := row.get_node_or_null("Highlight") as Panel
		if highlight != null:
			highlight.visible = pointed


## 结算一张牌的三拍：指针滑过去 → 左侧大图顿一下 → 再放数值与特效。
func _move_pointer_to(instance_id: String) -> void:
	_display_pointer_id = instance_id
	_refresh_pointer_marks(instance_id)
	await _ensure_play_visible(instance_id)
	await _place_pointer(instance_id, true)
	if instance_id == _display_pointer_id:
		_refresh_resolve_preview(instance_id)
		await get_tree().create_timer(PREVIEW_HOLD).timeout


func _build_resolve_preview() -> void:
	# 出牌区左侧的大图：结算到哪张就把那张放大摆出来，不用低头看小卡。
	_resolve_preview = Control.new()
	_resolve_preview.name = "ResolvePreview"
	_resolve_preview.position = RESOLVE_PREVIEW_POS
	_resolve_preview.size = Vector2(480.0, 818.0) * RESOLVE_PREVIEW_SCALE
	_resolve_preview.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_resolve_preview.z_index = 40
	_resolve_preview.visible = false
	add_child(_resolve_preview)
	_resolve_view = CARD_SCENE.instantiate()
	_resolve_view.scale = Vector2.ONE * RESOLVE_PREVIEW_SCALE
	_resolve_view.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_resolve_preview.add_child(_resolve_view)


func _build_peek() -> void:
	# 牌堆/卡组点一张看大图：整屏压暗 + 0.7 倍大卡，点任意处关闭。
	_peek_layer = Control.new()
	_peek_layer.name = "PeekLayer"
	_peek_layer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_peek_layer.mouse_filter = Control.MOUSE_FILTER_STOP
	_peek_layer.z_index = 70
	_peek_layer.visible = false
	add_child(_peek_layer)
	var shade := ColorRect.new()
	shade.color = Color(0.02, 0.018, 0.016, 0.72)
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	shade.mouse_filter = Control.MOUSE_FILTER_STOP
	shade.gui_input.connect(_on_peek_input)
	_peek_layer.add_child(shade)
	_peek_view = CARD_SCENE.instantiate()
	_peek_view.scale = Vector2.ONE * PEEK_CARD_SCALE
	_peek_view.position = (Vector2(1920.0, 1080.0) - Vector2(480.0, 818.0) * PEEK_CARD_SCALE) * 0.5
	_peek_view.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_peek_layer.add_child(_peek_view)


func _peek_card(card_id: String) -> void:
	if card_id.is_empty():
		return
	var data := _card_data(card_id)
	if data == null:
		return
	_peek_view.set_card(data)
	var peek_px := CardView.text_px_for(PEEK_CARD_SCALE)
	_peek_view.apply_compact_layout(PEEK_CARD_SCALE, peek_px.x, peek_px.y)
	_peek_layer.visible = true
	_peek_layer.modulate.a = 0.0
	_peek_layer.create_tween().tween_property(_peek_layer, "modulate:a", 1.0, 0.12)


func _on_peek_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		_peek_layer.visible = false
		get_viewport().set_input_as_handled()


func _refresh_resolve_preview(instance_id: String) -> void:
	if _resolve_preview == null or _resolve_view == null:
		return
	var card := _find_selected_card(instance_id)
	if card.is_empty() or not _busy:
		_resolve_preview.visible = false
		return
	_show_resolve_preview(String(card.get("card_id", "")))


## 把某张卡按结算大图的规格摆到左侧。结算指针与出牌列悬停共用这一份。
func _show_resolve_preview(card_id: String) -> void:
	if _resolve_preview == null or _resolve_view == null or card_id.is_empty():
		return
	var data := _card_data(card_id)
	if data == null:
		return
	_resolve_view.set_card(data)
	var resolve_px := CardView.text_px_for(RESOLVE_PREVIEW_SCALE)
	_resolve_view.apply_compact_layout(RESOLVE_PREVIEW_SCALE, resolve_px.x, resolve_px.y)
	if _resolve_preview.visible:
		_resolve_preview.modulate.a = 1.0
		return
	_resolve_preview.visible = true
	_resolve_preview.modulate.a = 0.0
	var tween := _resolve_preview.create_tween()
	tween.tween_property(_resolve_preview, "modulate:a", 1.0, 0.12)


func _find_selected_card(instance_id: String) -> Dictionary:
	if instance_id.is_empty():
		return {}
	for card: Dictionary in _selected_cards:
		if String(card.get("instance_id", "")) == instance_id:
			return card
	return {}


func _unhandled_key_input(event: InputEvent) -> void:
	# 与地图界面同一套：Esc 设置 / Tab 背包 / M 地图，再按一次退出。
	if _run_menu == null:
		return
	if pile_modal.visible and event.is_action_pressed("ui_cancel"):
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
		gateway.abandon_run()
	get_tree().change_scene_to_file(MENU_SCENE)


func _on_menu_return() -> void:
	var gateway := get_node_or_null("/root/SaveGateway")
	if gateway != null:
		gateway.save_current()
	get_tree().change_scene_to_file(MENU_SCENE)


func _on_menu_quit() -> void:
	var gateway := get_node_or_null("/root/SaveGateway")
	if gateway != null:
		gateway.quit_game()
	else:
		get_tree().quit()


func _open_run_menu(page: int = 1) -> void:
	if _run_menu == null:
		return
	# 手里还捏着一张牌就先把这次拖拽收掉，不然菜单关掉之后它还跟着鼠标。
	if _drag_active:
		_finish_drag()
	_drag_card_id = ""
	_drag_source = ""
	if _map_page_source == null:
		_map_page_source = _build_map_page_source()
	_run_menu.open(page)


func _build_map_page_source() -> Control:
	# 只查看的地图：真实渲染 + 滚轮缩放 + 拖动平移，不带角色位置。
	var data := _map_snapshot_data()
	if data.is_empty():
		return null
	# 先挂进浮层再喂数据，查看器内部节点在 _ready 里才建好。
	var viewer_script: Script = null
	if ResourceLoader.exists(MAP_VIEWER_PATH):
		viewer_script = load(MAP_VIEWER_PATH) as Script
	if viewer_script == null:
		return null
	var viewer: Control = viewer_script.new() as Control
	if viewer == null:
		return null
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


func _clear_children(container: Node) -> void:
	# queue_free 而不是 free，且所有点击后的刷新都经 call_deferred 进入这里；
	# 避免释放正在派发 pressed 信号的锁定对象。
	for child: Node in container.get_children():
		container.remove_child(child)
		child.queue_free()


static func _card_data(card_id: String) -> CardData:
	var resource: Resource = load("%s/%s.tres" % [TEST_CARD_DIR, card_id])
	return resource as CardData


static func _buff_display_name(buff_id: String) -> String:
	return String({
		"poison": "中毒", "strength": "力量", "weak": "虚弱",
	}.get(buff_id, buff_id))


static func _format_buffs(buffs: Array) -> String:
	if buffs.is_empty():
		return "无"
	var names: Array[String] = []
	for buff: Dictionary in buffs:
		var buff_id := String(buff.get("buff_id", ""))
		names.append("%s %d" % [_buff_display_name(buff_id), int(buff.get("layers", 0))])
	return "、".join(names)


static func _find_card(cards: Array[Dictionary], instance_id: String) -> Dictionary:
	for card: Dictionary in cards:
		if String(card.get("instance_id", "")) == instance_id:
			return card
	return {}


func _buff_layers(combatant: Dictionary, buff_id: String) -> int:
	for buff: Dictionary in combatant.get("buffs", []):
		if String(buff.get("buff_id", "")) == buff_id:
			return int(buff.get("layers", 0))
	return 0


func _refresh_damage_preview() -> void:
	if damage_preview == null or _battle == null:
		return
	# 力量/虚弱作用在「每次伤害」上，坚韧作用在「每次格挡」上，都是按层数加减。
	var damage_bonus := _buff_layers(_battle.player, "strength") - _buff_layers(_battle.player, "weak")
	var block_bonus := _buff_layers(_battle.player, "toughness")
	var damage := 0
	var block := 0
	for id: String in _selected_ids:
		var card := _card_by_instance(id)
		var data := _card_data(String(card.get("card_id", "")))
		if data == null:
			continue
		for effect: GameEffect in data.effects:
			if effect is CardEffectAttack:
				var attack := effect as CardEffectAttack
				damage += maxi(0, attack.amount + damage_bonus) * maxi(1, attack.times)
			elif effect is CardEffectBlock:
				var guarded := effect as CardEffectBlock
				block += maxi(0, guarded.amount + block_bonus)
	var lethal := false
	if not _battle.enemies.is_empty():
		lethal = damage >= int(_battle.enemies[0].get("health", 0))
	damage_preview.show_values(damage, block, lethal)
